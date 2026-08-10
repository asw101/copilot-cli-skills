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

# Resolve the Copilot credential before doing anything else. An interactive
# profile is not sourced by cron, CI, or an agent's tool call, so without this a
# non-interactive run inherits no token and silently falls back to whatever
# `copilot login` last stored — possibly a different identity. Prefer
# COPILOT_GITHUB_TOKEN over GH_TOKEN: gh ignores it, so a Copilot-only token
# here cannot widen gh's access, and a broad gh token cannot leak into Copilot.
if [ -z "${COPILOT_GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  _token_file="${COPILOT_TOKEN_FILE:-$HOME/.config/copilot-token}"
  if [ -r "$_token_file" ]; then
    COPILOT_GITHUB_TOKEN="$(cat "$_token_file")"
    export COPILOT_GITHUB_TOKEN
  fi
  unset _token_file
fi

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
#   --model <id>   set COPILOT_MODEL for this run (default: claude-opus-5)
#   --effort <lv>  set COPILOT_REASONING_EFFORT (low|medium|high|xhigh; default: high)
#   --context <t>  set COPILOT_CONTEXT_TIER (default|long_context; default: long_context)
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
  echo "usage: run.sh [--model id] [--effort lvl] [--context tier] \"<task>\"" >&2
  exit 2
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
