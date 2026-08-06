// /copilot-sdk runner — drives Copilot via the official Go SDK
// (github.com/github/copilot-sdk/go). Same arg contract as the Python
// runners in /copilot-cli and /copilot-acp:
//
//	runner <run_id> <transcript_md> <status> <taskfile>
//
// Writes <id>.jsonl (raw event dump), <id>.md (rendered transcript),
// <id>.session, and minimal stdout (final answer + summary).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	copilot "github.com/github/copilot-sdk/go"
)

func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	if len(os.Args) < 5 {
		fmt.Fprintln(os.Stderr, "usage: runner <run_id> <transcript_md> <status> <taskfile>")
		os.Exit(2)
	}
	runID := os.Args[1]
	transcriptPath := os.Args[2]
	statusPath := os.Args[3]
	taskfilePath := os.Args[4]

	runsDir := filepath.Dir(transcriptPath)
	jsonlPath := filepath.Join(runsDir, runID+".jsonl")
	sessionPath := filepath.Join(runsDir, runID+".session")
	askPath := filepath.Join(runsDir, runID+".ask")
	answerPath := filepath.Join(runsDir, runID+".answer")

	taskBytes, err := os.ReadFile(taskfilePath)
	if err != nil {
		log.Fatalf("read task: %v", err)
	}
	task := strings.TrimRight(string(taskBytes), "\n")

	md, err := os.OpenFile(transcriptPath, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		log.Fatalf("open transcript: %v", err)
	}
	defer md.Close()
	jl, err := os.OpenFile(jsonlPath, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		log.Fatalf("open jsonl: %v", err)
	}
	defer jl.Close()

	writeStatus := func(s string) { _ = os.WriteFile(statusPath, []byte(s+"\n"), 0644) }

	// SIGTERM = cancel.sh path. Flip status, emit a transcript line.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM)
	go func() {
		<-sigs
		writeStatus("cancelled")
		fmt.Fprintln(md, "\n_cancelled by signal_")
		os.Exit(143)
	}()

	model := envDefault("COPILOT_MODEL", "claude-opus-5")
	effort := envDefault("COPILOT_REASONING_EFFORT", "high")
	// Context window tier: "long_context" is the 1M window, "default" the
	// standard one. SessionConfig.ContextTier is a plain string type, so an
	// unknown value is passed through and rejected upstream rather than here.
	contextTier := envDefault("COPILOT_CONTEXT_TIER", string(copilot.ContextTierLongContext))

	// #16: timeout configurable via COPILOT_TIMEOUT_S (default 1 hour; 0 = unlimited).
	timeoutS := 3600
	if v := os.Getenv("COPILOT_TIMEOUT_S"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			timeoutS = n
		}
	}

	client := copilot.NewClient(&copilot.ClientOptions{LogLevel: "error"})
	if err := client.Start(context.Background()); err != nil {
		writeStatus("failed")
		fmt.Fprintf(md, "\n_client start failed: %v_\n", err)
		log.Fatalf("client.Start: %v", err)
	}
	defer client.Stop()

	session, err := client.CreateSession(context.Background(), &copilot.SessionConfig{
		Model:               model,
		ReasoningEffort:     effort,
		ContextTier:         copilot.ContextTier(contextTier),
		OnPermissionRequest: copilot.PermissionHandler.ApproveAll,
	})
	if err != nil {
		writeStatus("failed")
		fmt.Fprintf(md, "\n_create session failed: %v_\n", err)
		log.Fatalf("CreateSession: %v", err)
	}
	defer session.Disconnect()

	if sid := session.SessionID; sid != "" {
		_ = os.WriteFile(sessionPath, []byte(sid+"\n"), 0644)
		fmt.Fprintf(md, "_session: %s_\n", sid)
	}

	var (
		mu        sync.Mutex
		finalText strings.Builder
		// Per-turn aggregation from AssistantUsageData.
		totalIn, totalOut, totalCacheR, totalCacheW, totalReason int64
		usageDurationMs                                          int64
		// #12: premium-request-equivalent count. AssistantUsageData.Cost is
		// NOT USD — it's a premium-request count per turn. SessionShutdownData
		// provides an authoritative total that supersedes the per-turn sum.
		premiumRequests float64
		modelSeen       string = model
		turnCount       int
	)
	done := make(chan struct{})
	startTime := time.Now()

	resetDone := func() {
		mu.Lock()
		done = make(chan struct{})
		mu.Unlock()
	}

	session.On(func(event copilot.SessionEvent) {
		dump := map[string]any{"kind": fmt.Sprintf("%T", event.Data)}
		if b, err := json.Marshal(event.Data); err == nil {
			_ = json.Unmarshal(b, &dump)
			dump["_kind"] = fmt.Sprintf("%T", event.Data)
		}
		raw, _ := json.Marshal(dump)
		fmt.Fprintln(jl, string(raw))

		switch d := event.Data.(type) {
		case *copilot.AssistantMessageData:
			mu.Lock()
			finalText.Reset()
			finalText.WriteString(d.Content)
			mu.Unlock()
			fmt.Fprintln(md, d.Content)
		case *copilot.AssistantUsageData:
			mu.Lock()
			turnCount++
			if d.Cost != nil {
				premiumRequests += *d.Cost
			}
			if d.InputTokens != nil {
				totalIn += *d.InputTokens
			}
			if d.OutputTokens != nil {
				totalOut += *d.OutputTokens
			}
			if d.CacheReadTokens != nil {
				totalCacheR += *d.CacheReadTokens
			}
			if d.CacheWriteTokens != nil {
				totalCacheW += *d.CacheWriteTokens
			}
			// #13: ReasoningTokens — actually wire it up.
			if d.ReasoningTokens != nil {
				totalReason += *d.ReasoningTokens
			}
			if d.Duration != nil {
				usageDurationMs += *d.Duration
			}
			if d.Model != "" {
				modelSeen = d.Model
			}
			mu.Unlock()
		case *copilot.SessionShutdownData:
			// #12: premium-request count lives here, NOT in AssistantUsageData.Cost.
			mu.Lock()
			if d.TotalPremiumRequests != nil {
				premiumRequests = *d.TotalPremiumRequests
			}
			if d.TotalAPIDurationMs > 0 {
				usageDurationMs = d.TotalAPIDurationMs
			}
			mu.Unlock()
		case *copilot.ToolExecutionStartData:
			// #15: render the actual tool name + args, not the Go type name.
			argPreview := ""
			if d.Arguments != nil {
				if b, err := json.Marshal(d.Arguments); err == nil {
					s := string(b)
					if len(s) > 160 {
						s = s[:160] + "…"
					}
					argPreview = " `" + s + "`"
				}
			}
			fmt.Fprintf(md, "\n  ↳ tool call: **%s**%s\n", d.ToolName, argPreview)
		case *copilot.ToolExecutionCompleteData:
			if !d.Success {
				fmt.Fprintf(md, "  ↳ tool result: _(error)_\n")
			}
		case *copilot.SessionIdleData:
			mu.Lock()
			select {
			case <-done:
			default:
				close(done)
			}
			mu.Unlock()
		}
	})

	sendPrompt := func(p string) error {
		_, err := session.Send(context.Background(), copilot.MessageOptions{Prompt: p})
		return err
	}

	waitForIdle := func() error {
		mu.Lock()
		d := done
		mu.Unlock()
		if timeoutS <= 0 {
			<-d
			return nil
		}
		select {
		case <-d:
			return nil
		case <-time.After(time.Duration(timeoutS) * time.Second):
			return fmt.Errorf("timed out waiting for SessionIdle after %ds", timeoutS)
		}
	}

	waitForAnswer := func() string {
		// Poll for answer file (24h cap).
		for i := 0; i < 17280; i++ {
			if b, err := os.ReadFile(answerPath); err == nil {
				return strings.TrimRight(string(b), "\n")
			}
			time.Sleep(5 * time.Second)
		}
		return ""
	}

	if err := sendPrompt(task); err != nil {
		writeStatus("failed")
		fmt.Fprintf(md, "\n_send failed: %v_\n", err)
		log.Fatalf("session.Send: %v", err)
	}

	if err := waitForIdle(); err != nil {
		writeStatus("failed")
		fmt.Fprintf(md, "\n_%s_\n", err.Error())
		os.Exit(1)
	}

	// #18: pause-for-input loop. If the task created an .ask file, wait for
	// the .answer file, then resume the same session with the answer.
	for {
		if _, err := os.Stat(askPath); err != nil {
			break
		}
		writeStatus("needs-input")
		fmt.Fprintf(md, "\n_paused — waiting on %s_\n", answerPath)
		answer := waitForAnswer()
		if answer == "" {
			writeStatus("failed")
			fmt.Fprintln(md, "\n_timed out waiting for answer_")
			os.Exit(1)
		}
		_ = os.Remove(askPath)
		_ = os.Remove(answerPath)
		writeStatus("running")
		fmt.Fprintf(md, "\n_resumed with answer: %s_\n", answer)

		resetDone()
		resume := "The user has answered your question:\n" + answer + "\n\nContinue."
		if err := sendPrompt(resume); err != nil {
			writeStatus("failed")
			fmt.Fprintf(md, "\n_resume send failed: %v_\n", err)
			os.Exit(1)
		}
		if err := waitForIdle(); err != nil {
			writeStatus("failed")
			fmt.Fprintf(md, "\n_%s_\n", err.Error())
			os.Exit(1)
		}
	}

	writeStatus("done")
	mu.Lock()
	final := finalText.String()
	durationS := time.Since(startTime).Seconds()
	apiDurS := float64(usageDurationMs) / 1000.0
	usage := map[string]any{
		"run_id":             runID,
		"backend":            "sdk",
		"model":              modelSeen,
		"exit_code":          0,
		"premium_requests":   premiumRequests, // #12: premium-request-equivalent count
		"cost_usd":           nil,             // USD not surfaced by SDK v1.0.9
		"duration_s":         durationS,
		"duration_kind":      "wall_clock",
		"input_tokens":       int(totalIn),
		"output_tokens":      int(totalOut),
		"cache_read_tokens":  int(totalCacheR),
		"cache_write_tokens": int(totalCacheW),
		"reasoning_tokens":   int(totalReason),
		"turns":              turnCount,
		"api_duration_s":     apiDurS,
	}
	mu.Unlock()
	usagePath := filepath.Join(runsDir, runID+".usage.json")
	if b, err := json.MarshalIndent(usage, "", "  "); err == nil {
		_ = os.WriteFile(usagePath, append(b, '\n'), 0644)
	}
	summary := sdkSummaryLine(usage)
	fmt.Fprintf(md, "\n## Usage\n\n```\n%s\n```\n", summary)
	if final != "" {
		fmt.Println(final)
	}
	fmt.Println(summary)
}

func sdkSummaryLine(u map[string]any) string {
	parts := []string{
		fmt.Sprintf("exit %v", u["exit_code"]),
		fmt.Sprintf("sdk/%v", u["model"]),
	}
	if c, ok := u["premium_requests"].(float64); ok && c > 0 {
		parts = append(parts, fmt.Sprintf("premium %.2f", c))
	}
	if in, ok := u["input_tokens"].(int); ok {
		out, _ := u["output_tokens"].(int)
		parts = append(parts, fmt.Sprintf("in/out: %d/%d", in, out))
	}
	if cr, ok := u["cache_read_tokens"].(int); ok && cr > 0 {
		cw, _ := u["cache_write_tokens"].(int)
		parts = append(parts, fmt.Sprintf("cache: %d↑/%d↓", cr, cw))
	}
	if r, ok := u["reasoning_tokens"].(int); ok && r > 0 {
		parts = append(parts, fmt.Sprintf("reasoning: %d", r))
	}
	if d, ok := u["duration_s"].(float64); ok {
		parts = append(parts, fmt.Sprintf("%.1fs", d))
	}
	return "[" + strings.Join(parts, " · ") + "]"
}
