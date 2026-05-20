# GitHub Copilot CLI Skills

A family of agent skills that delegate work to **GitHub Copilot CLI** through three different integration surfaces — pick one at runtime depending on what you need (simplest stream, per-tool permission control, or richest cost telemetry).

| Skill | Wire | Runner | Best for |
|---|---|---|---|
| [`/copilot-cli`](.agents/skills/copilot-cli/) | `copilot -p --output-format json` | Python (JSONL) | **Default.** Smallest deps, full event replay. |
| [`/copilot-acp`](.agents/skills/copilot-acp/) | `copilot --acp` (JSON-RPC stdio) | Python ([`agent-client-protocol`](https://pypi.org/project/agent-client-protocol/)) | Per-tool permission hooks, fine-grained thinking deltas. |
| [`/copilot-sdk`](.agents/skills/copilot-sdk/) | Native Go SDK | Go binary ([`github.com/github/copilot-sdk/go`](https://github.com/github/copilot-sdk)) | Exact billing visibility (per-turn token & cache data). |
| [`/copilot`](.agents/skills/copilot/) | umbrella | — | Routes to `/copilot-cli` by default; fans out across all three with `--compare`. |

The full backend comparison — what each can and can't track, when to choose which, known asymmetries — lives in [`.agents/skills/copilot/README.md`](.agents/skills/copilot/README.md).

## Quick start

```bash
# 1. Install the copilot CLI + Python ACP SDK + Go runner (all in one).
bash .agents/skills/copilot/route.sh --bootstrap

# 2. Run a task through the default backend (cli).
bash .agents/skills/copilot/route.sh "What's 7*9?"

# 3. Run the same task through all three in parallel.
bash .agents/skills/copilot/route.sh --compare "What's 7*9?"

# 4. Per-run cost table.
bash .agents/skills/copilot/route.sh --usage
```

Auth is via `GH_TOKEN` (or whatever the `copilot` CLI picks up from `gh auth`).

## Standardized stdout summary

Every run's last stdout line follows this shape — fields omitted when the backend doesn't surface them:

```
[exit 0 · cli/claude-opus-4.7 · premium 7.5 · in/out: 0/7 · 4.7s]
[exit 0 · acp/claude-opus-4.7 · 6.2s]
[exit 0 · sdk/claude-opus-4.7 · premium 7.50 · in/out: 22503/7 · cache: 11844↑/10659↓ · 2.7s]
```

Run artifacts land in `.copilot-runs/<run-id>.{jsonl,md,status,task,session,usage.json}` — raw event stream, rendered transcript, and a shared `usage.json` schema across all three backends. `check.sh` / `cancel.sh` from any backend work uniformly thanks to the shared protocol.

## Layout

```
.agents/skills/
├── copilot/        # umbrella: route.sh / compare.sh / usage.sh
├── copilot-cli/    # JSONL backend (default)
├── copilot-acp/    # Agent Client Protocol backend
└── copilot-sdk/    # official Go SDK backend (bin/runner built on first use)
```

Each subfolder has a `SKILL.md` (metadata + invocation patterns) and a `run.sh` entrypoint. The shell scripts compute `SKILLS_DIR` relative to their own location, so the parent skills folder can be named anything (`.agents/`, `.claude/`, etc.).
