---
name: copilot-acp
description: Delegate to GitHub Copilot CLI via its Agent Client Protocol server. Built on the official agent-client-protocol Python SDK (Pydantic-typed messages). Sibling of /copilot-cli (JSONL) and /copilot-sdk (Go).
allowed-tools: Bash, Read, Write, Glob
---

You are the `/copilot-acp` skill. You delegate to GitHub Copilot CLI via the Agent Client Protocol (`copilot --acp`), using the official `agent-client-protocol` Python SDK (`pip install agent-client-protocol`). Every message is a Pydantic model — no hand-rolled JSON-RPC.

What ACP gives you over `--output-format json`:

- **Native session lifecycle.** `initialize` → `session/new` → `session/prompt`. Real session IDs that survive across the connection.
- **First-class permission requests.** When Copilot wants to run a tool, the server sends `session/request_permission`. The runner can route this to the user, auto-allow, or veto. Today the runner auto-allows for non-interactive operation.
- **Per-session config.** Model, reasoning effort, allow-all are session options, not CLI flags.
- **Session resume.** `session/load` is supported by the server (we capture sessionId in `.session`).

If you need maximum control over per-tool execution, prefer `/copilot-acp`. For sheer simplicity (just stream events from the CLI), use `/copilot-cli`. For the official wrapper, use `/copilot-sdk`.

## Invocation patterns

| User input | What to do |
|---|---|
| `/copilot-acp <task>` | Sync ACP run. Streams the agent message into the transcript. Minimal stdout. |
| `/copilot-acp --model claude-opus-4.7 <task>` | Override model. |
| `/copilot-acp --effort high <task>` | Override reasoning effort (ACP accepts low / medium / high). |
| `/copilot-acp-check <run-id>` | Use shared check.sh — same as `/copilot-cli-check`. |
| `/copilot-acp-cancel <run-id>` | Use shared cancel.sh — same as `/copilot-cli-cancel`. |

## On every invocation

1. **Bootstrap.** `bash .agents/skills/copilot-acp/run.sh --bootstrap` — delegates to `/copilot-cli/bootstrap.sh`.
2. **Sync.** `bash .agents/skills/copilot-acp/run.sh [--model X] [--effort L] "<task>"`.
3. **Check / cancel.** `bash .agents/skills/copilot-cli/check.sh` / `cancel.sh` — the shared run-files protocol means these work uniformly.

## Run files

Identical layout to `/copilot-cli`, run-id prefixed with `-acp-`:

- `.jsonl` — raw bidirectional JSON-RPC traffic. Every envelope wrapped in `{"_send": ...}` or `{"_recv": ...}` so client + server messages stay disambiguated.
- `.md` — rendered transcript (agent message chunks, tool calls, thoughts).
- `.session` — Copilot session id.
- `.status`, `.task`, `.ask`, `.answer`, `.pid` — same as `/copilot-cli`.

## Defaults

- **Model**: `claude-opus-4.7` (env: `COPILOT_MODEL`).
- **Reasoning effort**: `high` (ACP exposes low/medium/high — note: ACP server here doesn't surface `xhigh` as an option, unlike the CLI flag).
- **allow_all**: `on` (session option, applied at session/new).

## What's not built yet

- `bg.sh` (background): the ACP runner runs synchronously today. A background variant is straightforward (same `setsid` pattern as `/copilot-cli/bg.sh`) but not shipped in the first pass.
- `--multi` cross-model comparison: deliberately left to `/copilot-cli/multi.sh` for now.
- Per-tool human approval: the runner auto-allows `session/request_permission`. To route to the user, add a `.permission-request` file write + wait-for-answer loop similar to the `.ask`/`.answer` flow.
