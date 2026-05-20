#!/usr/bin/env bash
# Run the same task through all three backends in parallel and print
# each backend's final answer + standardized summary line.
#
# Usage:
#   compare.sh "<task>"
#
# Each backend produces its normal .copilot-runs/<id>.* artifacts; this
# script just collects stdout from each and presents it side by side.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(dirname "$SKILL_DIR")"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"

# #2: accept --model / --effort and pass them through to every backend so
# cross-backend comparisons aren't stuck at defaults.
FLAGS=()
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --model)  FLAGS+=(--model "$2"); shift 2 ;;
    --effort) FLAGS+=(--effort "$2"); shift 2 ;;
    --) shift; break ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: compare.sh [--model id] [--effort lvl] \"<task>\"" >&2
  exit 2
fi

TASK="$1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash "$SKILLS_DIR/copilot-cli/run.sh" "${FLAGS[@]}" "$TASK" >"$TMP/cli.out" 2>&1 &
PID_CLI=$!
bash "$SKILLS_DIR/copilot-acp/run.sh" "${FLAGS[@]}" "$TASK" >"$TMP/acp.out" 2>&1 &
PID_ACP=$!
bash "$SKILLS_DIR/copilot-sdk/run.sh" "${FLAGS[@]}" "$TASK" >"$TMP/sdk.out" 2>&1 &
PID_SDK=$!

echo
echo "=== /copilot --compare: 3 backends, task=\"${TASK:0:60}$([ ${#TASK} -gt 60 ] && echo …)\" ==="
echo

wait "$PID_CLI" "$PID_ACP" "$PID_SDK"

for backend in cli acp sdk; do
  out="$TMP/$backend.out"
  run_id="$(grep -m1 '^\[run-id:' "$out" | sed -E 's/.*run-id: ([^]]*)\].*/\1/')"
  summary="$(grep -m1 '^\[exit' "$out" || echo '[no summary]')"
  answer="$(awk '
    /^\[transcript:/ { state=1; next }
    state==1 && /^$/  { state=2; next }
    state==2 && /^\[exit/ { state=3; next }
    state==2          { print }
  ' "$out")"
  echo "--- $backend ($run_id) ---"
  [ -n "$answer" ] && printf '%s\n' "$answer"
  printf '%s\n\n' "$summary"
done
