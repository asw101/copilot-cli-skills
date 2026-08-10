#!/usr/bin/env bash
# /copilot-sdk — synchronous SDK run + bootstrap.
#
# Drives Copilot via the official github.com/github/copilot-sdk/go
# library. Source ships under scripts/; build.sh produces ./bin/runner.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(dirname "$SKILL_DIR")"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$REPO_ROOT/.copilot-runs"
SHARED_BOOTSTRAP="$SKILLS_DIR/copilot-cli/bootstrap.sh"
RUNNER="$SKILL_DIR/bin/runner"

mkdir -p "$RUNS_DIR"

# Resolve the Copilot credential before anything else; see copilot-cli/run.sh
# for why COPILOT_GITHUB_TOKEN is preferred over GH_TOKEN.
if [ -z "${COPILOT_GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  _token_file="${COPILOT_TOKEN_FILE:-$HOME/.config/copilot-token}"
  if [ -r "$_token_file" ]; then
    COPILOT_GITHUB_TOKEN="$(cat "$_token_file")"
    export COPILOT_GITHUB_TOKEN
  fi
  unset _token_file
fi

if [ "${1:-}" = "--bootstrap" ]; then
  bash "$SHARED_BOOTSTRAP" || true
  echo "---"
  bash "$SKILL_DIR/build.sh"
  exit $?
fi

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --model)  export COPILOT_MODEL="$2"; shift 2 ;;
    --effort) export COPILOT_REASONING_EFFORT="$2"; shift 2 ;;
    --context) export COPILOT_CONTEXT_TIER="$2"; shift 2 ;;
    --timeout) export COPILOT_TIMEOUT_S="$2"; shift 2 ;;
    --) shift; break ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: run.sh --bootstrap | run.sh [--model id] [--effort lvl] [--context tier] [--timeout s] \"<task>\"" >&2
  exit 2
fi

if [ ! -x "$RUNNER" ]; then
  echo "runner not built yet — building..."
  bash "$SKILL_DIR/build.sh"
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
RUN_ID="$(date +%Y-%m-%d-%H%M%S)-sdk-$SLUG-$RANDOM"
TRANSCRIPT="$RUNS_DIR/$RUN_ID.md"
STATUS="$RUNS_DIR/$RUN_ID.status"
TASKFILE="$RUNS_DIR/$RUN_ID.task"

{
  echo "# copilot-sdk run: $RUN_ID"
  echo
  echo "_Started: $(date -Iseconds) — sync (Go SDK mode)_"
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

exec "$RUNNER" "$RUN_ID" "$TRANSCRIPT" "$STATUS" "$TASKFILE"
