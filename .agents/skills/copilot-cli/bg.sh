#!/usr/bin/env bash
# /copilot-cli --bg — background CLI/JSONL run.
#
# Spawns runner.py detached via setsid so cancel.sh can take down the
# whole process group. Writes the same .status / .pid / .task / .jsonl
# files as the sync path, so check.sh and cancel.sh work unchanged.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$REPO_ROOT/.copilot-runs"

mkdir -p "$RUNS_DIR"

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: bg.sh \"<task>\"" >&2
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

# Same flag parsing as run.sh.
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
  echo "usage: bg.sh [--model id] [--effort lvl] \"<task>\"" >&2
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
PIDFILE="$RUNS_DIR/$RUN_ID.pid"
TASKFILE="$RUNS_DIR/$RUN_ID.task"

{
  echo "# copilot-cli run: $RUN_ID"
  echo
  echo "_Started: $(date -Iseconds) — background (CLI/JSONL mode)_"
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

# runner.py writes the .md transcript and .jsonl itself, so we MUST NOT
# also redirect stdout there — that would double-write every event.
# Send the runner's minimal stdout summary to a sibling .stdout file.
setsid python3 "$SKILL_DIR/runner.py" "$RUN_ID" "$TRANSCRIPT" "$STATUS" "$TASKFILE" \
  </dev/null >"$RUNS_DIR/$RUN_ID.stdout" 2>&1 &
RUNNER_PID=$!
echo "$RUNNER_PID" > "$PIDFILE"
disown "$RUNNER_PID" 2>/dev/null || true

# Mirror cleanup: when runner exits, remove pidfile. The runner itself
# doesn't unlink it (parent died, no trap window), so a tiny reaper helps.
(
  wait_pid="$RUNNER_PID"
  while kill -0 "$wait_pid" 2>/dev/null; do sleep 5; done
  rm -f "$PIDFILE"
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

echo "$RUN_ID"
echo "transcript: $TRANSCRIPT"
echo "status: $STATUS"
