#!/usr/bin/env bash
# /copilot-check — list / inspect / answer runs.
#
# Usage:
#   check.sh                              # list all runs with status
#   check.sh <run-id>                     # print the transcript (and surface .ask if present)
#   check.sh <run-id> --answer "<text>"   # write .answer to satisfy needs-input

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$REPO_ROOT/.copilot-runs"

if [ ! -d "$RUNS_DIR" ]; then
  echo "no runs yet ($RUNS_DIR does not exist)"
  exit 0
fi

list_runs() {
  shopt -s nullglob
  local found=0
  for st in "$RUNS_DIR"/*.status; do
    found=1
    local run_id status
    run_id="$(basename "$st" .status)"
    status="$(cat "$st" 2>/dev/null || echo unknown)"
    printf '%-12s  %s\n' "[$status]" "$run_id"
  done
  if [ "$found" -eq 0 ]; then
    echo "no runs yet"
  fi
}

show_run() {
  local run_id="$1"
  local transcript="$RUNS_DIR/$run_id.md"
  local status_file="$RUNS_DIR/$run_id.status"
  local askfile="$RUNS_DIR/$run_id.ask"

  if [ ! -f "$transcript" ]; then
    echo "no transcript for run-id: $run_id" >&2
    return 1
  fi

  echo "=== run: $run_id ==="
  if [ -f "$status_file" ]; then
    echo "status: $(cat "$status_file")"
  fi
  echo
  if [ -f "$askfile" ]; then
    echo "--- COPILOT IS ASKING ---"
    cat "$askfile"
    echo "--- (answer with: /copilot-check $run_id --answer \"...\") ---"
    echo
  fi
  echo "--- transcript (tail) ---"
  tail -n 80 "$transcript"
}

answer_run() {
  local run_id="$1"
  local answer="$2"
  local askfile="$RUNS_DIR/$run_id.ask"
  local answerfile="$RUNS_DIR/$run_id.answer"
  local status_file="$RUNS_DIR/$run_id.status"

  if [ ! -f "$askfile" ]; then
    echo "run $run_id is not waiting for input (.ask not present)" >&2
    return 1
  fi

  printf '%s\n' "$answer" > "$answerfile"
  echo "answer written: $answerfile"
  echo "supervisor will pick it up and flip status back to running"
  if [ -f "$status_file" ]; then
    echo "current status: $(cat "$status_file")"
  fi
}

main() {
  if [ $# -eq 0 ]; then
    list_runs
    return 0
  fi

  local run_id="$1"
  shift

  if [ $# -eq 0 ]; then
    show_run "$run_id"
    return $?
  fi

  if [ "$1" = "--answer" ]; then
    shift
    if [ $# -lt 1 ]; then
      echo "usage: check.sh <run-id> --answer \"<text>\"" >&2
      return 2
    fi
    answer_run "$run_id" "$1"
    return $?
  fi

  echo "unknown argument: $1" >&2
  echo "usage: check.sh [run-id [--answer \"text\"]]" >&2
  return 2
}

main "$@"
