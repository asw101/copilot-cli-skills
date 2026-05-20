#!/usr/bin/env bash
# /copilot-cli — synchronous JSONL run + bootstrap.
#
# Drives the `copilot` binary with --output-format json and parses the
# event stream through a Python runner. Writes .copilot-runs/<id>.{
# jsonl,md,status,task,session} so background runs and check.sh /
# cancel.sh share state with the sibling skills (/copilot-acp,
# /copilot-sdk).

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$REPO_ROOT/.copilot-runs"

mkdir -p "$RUNS_DIR"

if [ "${1:-}" = "--bootstrap" ]; then
  exec bash "$SKILL_DIR/bootstrap.sh"
fi

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: run.sh --bootstrap | run.sh \"<task>\"" >&2
  exit 2
fi

if ! command -v copilot >/dev/null 2>&1; then
  echo "error: copilot CLI not installed. Run 'run.sh --bootstrap' first." >&2
  exit 127
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 required for /copilot-cli runner." >&2
  exit 127
fi

# Parse optional flags before the task. Recognized:
#   --model <id>   set COPILOT_MODEL for this run (default: claude-opus-4.7)
#   --effort <lv>  set COPILOT_REASONING_EFFORT (low|medium|high|xhigh; default: xhigh)
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --model)  export COPILOT_MODEL="$2"; shift 2 ;;
    --effort) export COPILOT_REASONING_EFFORT="$2"; shift 2 ;;
    --) shift; break ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: run.sh [--model id] [--effort lvl] \"<task>\"" >&2
  exit 2
fi

TASK="$1"

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-40 \
    | sed -E 's/-+$//'
}

SLUG="$(slugify "$TASK")"
[ -z "$SLUG" ] && SLUG="run"
RUN_ID="$(date +%Y-%m-%d-%H%M%S)-cli-$SLUG-$RANDOM"
TRANSCRIPT="$RUNS_DIR/$RUN_ID.md"
STATUS="$RUNS_DIR/$RUN_ID.status"
TASKFILE="$RUNS_DIR/$RUN_ID.task"

{
  echo "# copilot-cli run: $RUN_ID"
  echo
  echo "_Started: $(date -Iseconds) — sync (CLI/JSONL mode)_"
  echo
  echo "## Task"
  echo
  echo "$TASK"
  echo
  echo "## Events"
  echo
} > "$TRANSCRIPT"

printf '%s\n' "$TASK" > "$TASKFILE"
printf 'running\n' > "$STATUS"

echo "[run-id: $RUN_ID]"
echo "[transcript: $TRANSCRIPT]"
echo

exec python3 "$SKILL_DIR/runner.py" "$RUN_ID" "$TRANSCRIPT" "$STATUS" "$TASKFILE"
