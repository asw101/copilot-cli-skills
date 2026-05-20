---
name: copilot-sdk
description: Delegate to Copilot via the official Go SDK (github.com/github/copilot-sdk/go). Source ships under scripts/; first invocation builds bin/runner. Sibling of /copilot-cli (JSONL) and /copilot-acp (ACP).
allowed-tools: Bash, Read, Write, Glob
---

You are the `/copilot-sdk` skill. You delegate to GitHub Copilot using the official Go SDK (`github.com/github/copilot-sdk/go`).

Why this skill exists alongside `/copilot-cli` and `/copilot-acp`:

- The SDK is the **officially supported integration surface**. It shields you from CLI flag churn.
- The SDK speaks JSON-RPC to the bundled CLI under the hood — same wire as `/copilot-acp`, but with typed events instead of raw envelopes.
- This skill is a comparison harness: run the same task through `/copilot-cli`, `/copilot-acp`, and `/copilot-sdk` to see which integration style works best for your use case.

## Source distribution

The Go source lives in `scripts/`:

```
.agents/skills/copilot-sdk/
├── SKILL.md
├── run.sh           # entrypoint
├── build.sh         # builds scripts/main.go → bin/runner
├── scripts/
│   ├── go.mod
│   └── main.go      # imports github.com/github/copilot-sdk/go
└── bin/runner       # built on first use (gitignored)
```

`bin/runner` is built on first invocation via `go build`. Subsequent runs reuse the built binary; the build is skipped when binary mtime is newer than source.

## Invocation patterns

| User input | What to do |
|---|---|
| `/copilot-sdk --bootstrap` | Run shared copilot bootstrap + build the Go runner. |
| `/copilot-sdk <task>` | Sync SDK run. |
| `/copilot-sdk --model claude-opus-4.7 <task>` | Override model. |
| `/copilot-sdk-check <run-id>` | Use shared check.sh (same as `/copilot-cli-check`). |
| `/copilot-sdk-cancel <run-id>` | Use shared cancel.sh. |

## On every invocation

1. **Bootstrap.** `bash .agents/skills/copilot-sdk/run.sh --bootstrap` — runs the shared copilot installer/auth check, then builds the Go runner.
2. **Sync.** `bash .agents/skills/copilot-sdk/run.sh [--model X] "<task>"`. If the binary isn't built yet, run.sh auto-builds.
3. **Check / cancel.** Use `bash .agents/skills/copilot-cli/check.sh` and `cancel.sh` — the shared run-files protocol means they work uniformly.

## Run files

Identical layout to the sibling skills, run-id prefixed with `-sdk-`:

- `.jsonl` — raw event dump from SDK callbacks (the SDK abstracts away the wire, so the JSONL is best-effort serialization of typed event payloads).
- `.md` — rendered transcript.
- `.session` — Copilot session id.
- `.status`, `.task` — shared protocol.

## Defaults

- **Model**: `claude-opus-4.7` (env: `COPILOT_MODEL`, flag: `--model`).
- **Permission handler**: `PermissionHandler.ApproveAll` (auto-approves tool requests). Swap this in `scripts/main.go` if you want manual control.
- **Reasoning effort**: `xhigh` (env: `COPILOT_REASONING_EFFORT`, flag: `--effort`). The SDK passes this through `SessionConfig.ReasoningEffort`; the upstream server caps per-model and may reject unsupported values.
- **Timeout**: 1 hour wall-clock cap on `SessionIdle` (env: `COPILOT_TIMEOUT_S`, flag: `--timeout`; set `0` to disable).

## Status: public preview

The `copilot-sdk` is GitHub's official public preview as of this writing. Expect API churn. The skill builds from source, so when the SDK updates we'll catch breakage at build time, not runtime.
