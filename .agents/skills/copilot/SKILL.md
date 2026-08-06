---
name: copilot
description: Umbrella for the three Copilot delegation skills (/copilot-cli JSONL, /copilot-acp ACP, /copilot-sdk Go SDK). Default routes to /copilot-cli. Use --compare to fan out across all three for evaluation. README.md in this folder explains the trade-offs.
allowed-tools: Bash, Read, Write, Glob
---

You are the `/copilot` umbrella skill. There are three backend skills that all delegate to GitHub Copilot via different mechanisms:

- **`/copilot-cli`** — `copilot -p --output-format json`. Python runner parses JSONL. **This is the default workhorse.**
- **`/copilot-acp`** — `copilot --acp`. Python client speaks JSON-RPC over stdio (Agent Client Protocol).
- **`/copilot-sdk`** — `github.com/github/copilot-sdk/go`. Go program built from `scripts/main.go`.

For routine work, use `/copilot` (which routes to `/copilot-cli`). For evaluation or comparison, use `/copilot --compare`. To force a specific backend, type the backend skill directly (`/copilot-acp ...`).

## Invocation patterns

| User input | What to do |
|---|---|
| `/copilot <task>` | Forward to `/copilot-cli`. Same flags pass through. |
| `/copilot --compare <task>` | Run the task through all three backends in parallel and print a comparison table (final answer + usage per backend). |
| `/copilot --backend acp <task>` | Force a specific backend (`cli` / `acp` / `sdk`). |
| `/copilot --usage` | Print a cost table across all `.copilot-runs/*.usage.json`. |

## On every invocation

Run `bash .agents/skills/copilot/route.sh <user-args...>`. `route.sh` does the dispatching:

- bare task → `/copilot-cli`
- `--backend acp|sdk|cli <task>` → that backend
- `--compare <task>` → all three in parallel via `compare.sh`
- `--usage` → cost table via `usage.sh`
- `--bootstrap` → run both shared installer + Go build

Pass stdout from the dispatcher straight back to the user; each backend already produces minimal stdout in the standardized format.

## Reading the comparison

`compare.sh` prints a row per backend with the standardized summary line. Each backend produces a `.copilot-runs/<id>.usage.json` so you can drill in later. See `README.md` for what each backend can and can't track.

## Defaults

- **Backend**: `cli`
- **Model**: `claude-opus-5` (override: `--model`, env `COPILOT_MODEL`)
- **Reasoning effort**: `high` on all three backends (ACP verified by config read-back; SDK accepts up to `max`)
- **Context tier**: `long_context` (1M) on `cli` and `sdk`. **Not available on `acp`** — the ACP server exposes only mode/model/reasoning_effort/allow_all, so ACP sessions always use the default window.

## Files

- `SKILL.md` — this file.
- `README.md` — full comparison of cli vs acp vs sdk (what each tracks, when to choose which, known gaps).
- `compare.sh` — runs a task across all three backends and prints a table.
- `usage.sh` — walks `.copilot-runs/*.usage.json` and prints a cost-per-run table.
- `route.sh` — the actual dispatcher; called by the skill on every invocation.
