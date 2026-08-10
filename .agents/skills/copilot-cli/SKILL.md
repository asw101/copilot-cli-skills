---
name: copilot-cli
description: Delegate to GitHub Copilot CLI via its `--output-format json` stream. Python runner parses JSONL events into a structured transcript with full event replay. Default model gpt-5.6-sol + high reasoning + long_context (1M) window. Pass --model / --effort / --context to override; --multi to fan out across models.
allowed-tools: Bash, Read, Write, Glob
---

You are the `/copilot-cli` skill. You delegate work to GitHub Copilot CLI from inside the current agent host by spawning the `copilot` binary with `--output-format json`, then parsing the JSONL event stream through a Python runner.

Two sibling skills exist for comparison:
- **`/copilot-acp`** — drives `copilot --acp` (Agent Client Protocol, JSON-RPC stdio). Different pause/permission semantics.
- **`/copilot-sdk`** — uses the official `github/copilot-sdk` library (Go-based runner here).

If you're not sure which to use, use `/copilot-cli` — it's the workhorse.

## Invocation patterns

| User input | What to do |
|---|---|
| `/copilot-cli <task>` | Sync run. Block until done. Minimal stdout. |
| `/copilot-cli --model claude-opus-5 <task>` | Override model for this run. |
| `/copilot-cli --effort high <task>` | Override reasoning effort. |
| `/copilot-cli --multi opus,haiku,gpt-5.2 <task>` | Fan out: run the task against each model in parallel. |
| `/copilot-cli --bg <task>` | Background run. Return run-id. |
| `/copilot-cli-check` | List runs. |
| `/copilot-cli-check <run-id>` | Print transcript tail. For the full event stream, read `.copilot-runs/<run-id>.jsonl`. |
| `/copilot-cli-check <run-id> --answer "..."` | Resume a paused run. |
| `/copilot-cli-cancel <run-id>` | Kill the process group. |

## On every invocation

1. **Bootstrap.** Run `bash .agents/skills/copilot-cli/run.sh --bootstrap`. Installs `copilot` if missing (official tarball at `https://gh.io/copilot-install`, lands in `~/.local/bin` for non-root), reports version, and confirms auth. Auth is via `COPILOT_GITHUB_TOKEN` — see Auth below.
2. **Dispatch.**
   - Sync: `bash .agents/skills/copilot-cli/run.sh [--model X] [--effort L] "<task>"`.
   - Multi: `bash .agents/skills/copilot-cli/multi.sh <comma-models> "<task>"`.
   - Background: `bash .agents/skills/copilot-cli/bg.sh [--model X] [--effort L] "<task>"`.
   - Check / answer / cancel: the matching `check.sh` / `cancel.sh` in this folder.

## Defaults

- **Model**: `gpt-5.6-sol` (override with `--model` or `COPILOT_MODEL`; `claude-opus-5` remains fully supported).
- **Reasoning effort**: `high` (override: `--effort`, `COPILOT_REASONING_EFFORT`). Auto-skipped when the model doesn't support it (Haiku).
- **Context tier**: `long_context` — the 1M window (override: `--context`, `COPILOT_CONTEXT_TIER`; `default` for the standard window). The CLI validates the value and errors on anything but `default`/`long_context`.
- **Tool approval**: `--allow-all-tools` (required for non-interactive). Pause-for-input via the wrapper-prompt `.ask` protocol.

## Run-files protocol (`.copilot-runs/<run-id>.*`)

Shared across all three sibling skills so `check.sh` / `cancel.sh` work uniformly. Run-ids are prefixed by backend: `…-cli-…`, `…-acp-…`, `…-sdk-…`.

| Suffix | Meaning |
|---|---|
| `.jsonl` | **Raw event stream.** Full fidelity: thinking deltas, every tool call, every assistant delta. Source of truth for replay. |
| `.md` | Human-readable rendered transcript. |
| `.status` | `running` / `needs-input` / `done` / `failed` / `cancelled`. |
| `.pid` | Runner PID (background only). |
| `.task` | Original prompt. |
| `.ask` / `.answer` | Pause-for-input protocol. |
| `.session` | Copilot session id (enables native `--resume`). |
| `.stdout` | Background runner's minimal stdout summary. |

## What this skill gives the orchestrator

- **Minimal stdout.** You see only the final assistant message + a one-line summary `[exit 0 · premium 7.5 · 4.8s]`. Token cost to the orchestrator is bounded.
- **Full replay on demand.** Read `<run-id>.jsonl` for thinking deltas, tool args, raw events. Read `<run-id>.md` for a readable rendered view.
- **Native resume.** Pause/answer/resume uses `copilot --resume <sessionId>`; Copilot keeps its full prior context.
- **Cross-model comparison.** `--multi` runs the same task against several models in parallel and surfaces the deltas.

## What this skill does NOT do

- Doesn't keep the host agent warm. Bound background runs to minutes-to-hours; the host environment may reclaim on inactivity.
- Doesn't proxy GitHub credentials. Copilot inherits its token directly from the env, so whatever that token can reach, a run can reach. Prefer `COPILOT_GITHUB_TOKEN` (see Auth) — with `GH_TOKEN` the same credential is shared with `gh`.
- Doesn't intercept individual tool executions (binary auto-approves under `--allow-all-tools`). For per-tool approval, see `/copilot-acp`.
