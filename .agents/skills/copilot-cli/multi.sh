#!/usr/bin/env bash
# /copilot --multi — fan out the same task across multiple models in
# parallel, then print a comparison summary.
#
# Usage:
#   multi.sh <comma-separated-models> "<task>"
#
# Example:
#   multi.sh claude-opus-4.7,claude-haiku-4.5,gpt-5.2 "What is 7*9?"
#
# Each model runs as an independent sync invocation (run.sh --model X),
# writing its normal .copilot-runs/<id>.* set. We collect each run's
# final answer + summary line and print a table.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$REPO_ROOT/.copilot-runs"

if [ $# -lt 2 ]; then
  echo "usage: multi.sh <m1,m2,...> \"<task>\"" >&2
  exit 2
fi

MODELS="$1"
TASK="$2"

mkdir -p "$RUNS_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PIDS=()
declare -A MODEL_OF_PID
i=0
IFS=',' read -ra MODEL_LIST <<< "$MODELS"
for m in "${MODEL_LIST[@]}"; do
  m="$(echo "$m" | tr -d ' ')"
  [ -z "$m" ] && continue
  out="$TMP/$i.out"
  bash "$SKILL_DIR/run.sh" --model "$m" "$TASK" >"$out" 2>&1 &
  pid=$!
  PIDS+=("$pid")
  MODEL_OF_PID["$pid"]="$m|$out"
  i=$((i + 1))
done

# Wait for all in order; collect.
echo
echo "=== /copilot --multi: $i models, task=\"${TASK:0:60}$([ ${#TASK} -gt 60 ] && echo …)\" ==="
echo

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
  spec="${MODEL_OF_PID[$pid]}"
  model="${spec%%|*}"
  out="${spec##*|}"
  # The runner prints: [run-id: ...], [transcript: ...], <answer>, [exit ... · ...]
  run_id="$(grep -m1 '^\[run-id:' "$out" | sed -E 's/.*run-id: ([^]]*)\].*/\1/')"
  summary="$(grep -m1 '^\[exit' "$out" || echo '[no result line]')"
  # Final answer = lines between blank line after [transcript:] and the [exit] line
  answer="$(awk '
    /^\[transcript:/ { state=1; next }
    state==1 && /^$/ { state=2; next }
    state==2 && /^\[exit/ { state=3; next }
    state==2 { print }
  ' "$out")"
  echo "--- $model ($run_id) ---"
  [ -n "$answer" ] && printf '%s\n' "$answer"
  printf '%s\n\n' "$summary"
done
