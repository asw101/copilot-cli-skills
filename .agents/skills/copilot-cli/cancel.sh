#!/usr/bin/env bash
# /copilot-cancel — SIGTERM the subprocess for a run, escalate to SIGKILL
# after 10s if it doesn't wind down. Flip status to 'cancelled'.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$REPO_ROOT/.copilot-runs"

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: cancel.sh <run-id>" >&2
  exit 2
fi

RUN_ID="$1"
PIDFILE="$RUNS_DIR/$RUN_ID.pid"
STATUS="$RUNS_DIR/$RUN_ID.status"
TRANSCRIPT="$RUNS_DIR/$RUN_ID.md"

if [ ! -f "$PIDFILE" ]; then
  echo "no pidfile for $RUN_ID (already finished?)"
  [ -f "$STATUS" ] && echo "status: $(cat "$STATUS")"
  exit 0
fi

PID="$(cat "$PIDFILE")"

if ! kill -0 "$PID" 2>/dev/null; then
  echo "pid $PID no longer running"
  rm -f "$PIDFILE"
  [ -f "$STATUS" ] && [ "$(cat "$STATUS")" = "running" ] && printf 'failed\n' > "$STATUS"
  exit 0
fi

# bg.sh launches the supervisor via setsid, so PID is also the PGID.
# Signal the whole process group (negative PID) to take down copilot
# and any of its children together with the supervisor.
echo "sending SIGTERM to process group $PID..."
kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

if kill -0 "$PID" 2>/dev/null; then
  echo "still running after 10s, sending SIGKILL to process group..."
  kill -KILL -- "-$PID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null || true
fi

printf 'cancelled\n' > "$STATUS"
rm -f "$PIDFILE"
{
  echo
  echo "_Cancelled: $(date -Iseconds)_"
} >> "$TRANSCRIPT" 2>/dev/null || true
echo "cancelled: $RUN_ID"
