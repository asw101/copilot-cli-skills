#!/usr/bin/env bash
# /copilot-acp — synchronous ACP run + bootstrap.
#
# Drives `copilot --acp` (Agent Client Protocol over JSON-RPC stdio)
# through a Python runner. Writes .copilot-runs/<id>.{jsonl,md,status,
# task,session}. Shares check.sh / cancel.sh with /copilot-cli.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(dirname "$SKILL_DIR")"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$REPO_ROOT/.copilot-runs"
SHARED_BOOTSTRAP="$SKILLS_DIR/copilot-cli/bootstrap.sh"

mkdir -p "$RUNS_DIR"

if [ "${1:-}" = "--bootstrap" ]; then
  bash "$SHARED_BOOTSTRAP"
  echo "---"
  echo "installing ACP Python SDK..."
  # #11: PEP-668 ("externally-managed-environment") safe install. The SDK
  # must be importable by the bare `python3` that runs runner.py, so it
  # goes into the system environment (`uv pip --system`), never an
  # isolated tool venv. Both paths retry with --break-system-packages
  # because a global install is what --bootstrap is asking for.
  if command -v uv >/dev/null 2>&1; then
    echo "  using uv"
    if ! uv pip install --quiet --system -r "$SKILL_DIR/requirements.txt" 2>/dev/null; then
      uv pip install --quiet --system --break-system-packages -r "$SKILL_DIR/requirements.txt"
    fi
  else
    echo "  using pip (uv not found)"
    if ! python3 -m pip install --quiet -r "$SKILL_DIR/requirements.txt" 2>/dev/null; then
      python3 -m pip install --quiet --break-system-packages -r "$SKILL_DIR/requirements.txt"
    fi
  fi
  python3 -c "import acp; print(f'acp: ok ({acp.__file__})')"
  exit $?
fi

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --model)  export COPILOT_MODEL="$2"; shift 2 ;;
    --effort) export COPILOT_REASONING_EFFORT="$2"; shift 2 ;;
    --context) export COPILOT_CONTEXT_TIER="$2"; shift 2 ;;
    --) shift; break ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: run.sh --bootstrap | run.sh [--model id] [--effort lvl] [--context tier] \"<task>\"" >&2
  exit 2
fi

if ! command -v copilot >/dev/null 2>&1; then
  echo "error: copilot CLI not installed. Run 'run.sh --bootstrap' first." >&2
  exit 127
fi

TASK="$1"

slugify() {
  # Flatten newlines first: sed is line-oriented, so a multi-line task would
  # otherwise yield a multi-line slug and an unusable filename.
  printf '%s' "$1" | tr '\n\r' '  ' | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-40 \
    | sed -E 's/-+$//'
}

SLUG="$(slugify "$TASK")"
[ -z "$SLUG" ] && SLUG="run"
RUN_ID="$(date +%Y-%m-%d-%H%M%S)-acp-$SLUG-$RANDOM"
TRANSCRIPT="$RUNS_DIR/$RUN_ID.md"
STATUS="$RUNS_DIR/$RUN_ID.status"
TASKFILE="$RUNS_DIR/$RUN_ID.task"

{
  echo "# copilot-acp run: $RUN_ID"
  echo
  echo "_Started: $(date -Iseconds) — sync (ACP mode)_"
  echo
  echo "## Task"
  echo
  echo "$TASK"
  echo
  echo "## Stream"
  echo
} > "$TRANSCRIPT"

printf '%s\n' "$TASK" > "$TASKFILE"
printf 'running\n' > "$STATUS"

echo "[run-id: $RUN_ID]"
echo "[transcript: $TRANSCRIPT]"
echo

exec python3 "$SKILL_DIR/runner.py" "$RUN_ID" "$TRANSCRIPT" "$STATUS" "$TASKFILE"
