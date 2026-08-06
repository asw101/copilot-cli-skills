# `/copilot` skill family

Three sibling skills delegate work to GitHub Copilot CLI via different integration mechanisms. The `/copilot` umbrella routes to the default and provides comparison tooling.

## The three backends at a glance

| | `/copilot-cli` | `/copilot-acp` | `/copilot-sdk` |
|---|---|---|---|
| **Wire format** | JSONL on stdout | JSON-RPC over stdio | Native Go SDK |
| **Underlying call** | `copilot -p --output-format json` | `copilot --acp` | `github.com/github/copilot-sdk/go` |
| **Runner language** | Python | Python (hand-rolled JSON-RPC; planned: `pip install agent-client-protocol`) | Go (compiled binary built from `scripts/`) |
| **Type safety** | None (dict access) | None today; possible with ACP Python SDK | Strong (Go types from SDK) |
| **Per-turn token data** | Output only (`outputTokens` on `assistant.message`) | **None** — protocol doesn't surface it | Full (input / output / cache↑↓ / reasoning) |
| **Aggregate cost / duration** | ✓ (`result.usage.premiumRequests`, `sessionDurationMs`) | Duration only (wall clock) | ✓ (sum of `AssistantUsageData.cost` and `.duration`) |
| **Tool-call events** | ✓ (`assistant.message.toolRequests`) | ✓ (`session/update` with `tool_call`) | ✓ (`ToolExecutionStartData` / `…CompleteData`) |
| **Thinking / reasoning** | Hidden | ✓ as `agent_thought_chunk` deltas (very fine-grained) | ✓ as `AssistantReasoningData` |
| **Permission requests** | Auto-allow via `--allow-all-tools` flag | First-class `session/request_permission` (currently auto-approved) | First-class `PermissionRequestedData` (auto via `PermissionHandler.ApproveAll`) |
| **Native session resume** | ✓ (`--resume <id>`) | ✓ (`session/load`) | ✓ (`client.ResumeSession`) |
| **Reasoning effort levels** | `low/medium/high/xhigh` (full range) | `none/low/medium/high/xhigh/max` (probed live) | `low/medium/high/xhigh/max` (per SessionConfig docs) |
| **Context tier (1M window)** | yes — `--context long_context` | **no** — no such config option | yes — `SessionConfig.ContextTier` |
| **Cold-start dep** | `copilot` binary, Python | `copilot` binary, Python | `copilot` binary, Go toolchain (to build `bin/runner`) |
| **Binary size shipped** | 0 (runtime source) | 0 (runtime source) | ~7 MB (gitignored, rebuilt on demand) |

## When to use which

- **Default — `/copilot-cli`.** Simplest, smallest deps. JSONL is fully introspectable. Has the most mature usage tracking via the `result` event.
- **`/copilot-acp` when you want to intercept per-tool execution.** ACP gives you a real permission-request RPC you can route to a human or a policy engine. The wire is JSON-RPC, so building a type-safe client on top is straightforward (e.g. `pip install agent-client-protocol`).
- **`/copilot-sdk` for the deepest data and Go ergonomics.** The Go SDK surfaces token/cache/reasoning data per turn — the richest cost telemetry of the three. Pick this when you're integrating Copilot into a larger Go service or need exact billing visibility.

## Token consumption tracking

Every run writes `.copilot-runs/<run-id>.usage.json` with this shared schema:

```json
{
  "run_id": "...",
  "backend": "cli" | "acp" | "sdk",
  "model": "claude-opus-5",
  "exit_code": 0,
  "premium_requests": 7.5,
  "duration_s": 4.6,
  "input_tokens": 24222,
  "output_tokens": 6,
  "cache_read_tokens": 11280,
  "cache_write_tokens": 12936,
  "reasoning_tokens": 0,
  "...backend-specific extras..."
}
```

Fields not available from the chosen backend are `null`. The `usage.sh` helper walks all `.copilot-runs/*.usage.json` files and prints a per-task cost table.

**Key gap:** ACP today reports only wall-clock duration and the requested model; the protocol doesn't surface per-turn token counts. For exact billing, use `/copilot-sdk`.

## Standardized stdout summary

Every run's last stdout line follows this shape:

```
[exit 0 · cli/claude-opus-5 · premium 7.5 · in/out: 0/6 · 4.1s]
[exit 0 · acp/claude-opus-5 · 7.2s]
[exit 0 · sdk/claude-opus-5 · premium 7.50 · in/out: 24222/6 · cache: 11280↑/12936↓ · 4.6s]
```

Fields omitted when unavailable. The orchestrator sees only this line + the assistant's final answer.

## Comparison test (`compare.sh`)

```bash
bash .agents/skills/copilot/compare.sh "<task>"
```

Runs the same task through all three backends in parallel, prints each backend's summary line + final answer.

## Cost-tracking helper (`usage.sh`)

```bash
bash .agents/skills/copilot/usage.sh
```

Walks `.copilot-runs/*.usage.json` and prints a table (run-id, backend, model, premium, in/out tokens, duration). Pipe to `awk`/`column`/`jq` for filtering.

## Known asymmetries we haven't fixed

- **ACP thinking-delta verbosity.** ACP emits one `agent_thought_chunk` per *word*; the rendered transcript ends up with one `💭 _word_` line per word. Should buffer until the chunk completes. Tracked.
- **SDK tool-call rendering.** The SDK runner currently logs `ToolExecutionStartData` minimally; it could surface tool args + tool output as `/copilot-cli` does.
- **Context tier divergence.** `cli` and `sdk` can pin the 1M `long_context` window; `acp` cannot — its server exposes only `mode`, `model`, `reasoning_effort`, `allow_all`. A `--compare` run is therefore not window-matched across backends.
- **Effort.** All three accept `high`. The earlier claim that ACP/SDK cap at `high` is wrong: the live ACP server offers up to `max`, and the Go SDK documents `low/medium/high/xhigh/max`. The CLI runner keeps a `THINKING_INCAPABLE` denylist so non-thinking models don't crash.
- **ACP runner is hand-rolled.** Should migrate to `pip install agent-client-protocol` for typed payloads (Pydantic models, validated against the canonical schema).

## Layout

```
.agents/skills/
├── copilot/           # umbrella (this folder)
│   ├── SKILL.md
│   ├── README.md      # ← you are here
│   ├── route.sh       # dispatcher
│   ├── compare.sh     # run task across all three
│   └── usage.sh       # cost table from .copilot-runs/*.usage.json
├── copilot-cli/       # JSONL backend
├── copilot-acp/       # ACP backend
└── copilot-sdk/       # Go SDK backend (builds bin/runner on first use)
```
