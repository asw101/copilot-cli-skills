#!/usr/bin/env bash
# /copilot dispatcher. Forwards to the chosen backend skill.
#
# Usage:
#   route.sh [--backend cli|acp|sdk] [--model X] [--effort L] "<task>"
#
# Default backend: cli. Pass --compare instead to run all three.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(dirname "$SKILL_DIR")"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"

BACKEND="cli"
PASSTHROUGH=()

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --backend)
      BACKEND="$2"; shift 2 ;;
    --compare)
      shift
      exec bash "$SKILL_DIR/compare.sh" "$@" ;;
    --usage)
      exec bash "$SKILL_DIR/usage.sh" ;;
    --bootstrap)
      bash "$SKILLS_DIR/copilot-cli/run.sh" --bootstrap
      echo "---"
      bash "$SKILLS_DIR/copilot-acp/run.sh" --bootstrap
      echo "---"
      bash "$SKILLS_DIR/copilot-sdk/run.sh" --bootstrap
      exit 0 ;;
    --) shift; break ;;
    *)
      PASSTHROUGH+=("$1"); shift ;;
  esac
done

case "$BACKEND" in
  cli) exec bash "$SKILLS_DIR/copilot-cli/run.sh" "${PASSTHROUGH[@]}" ;;
  acp) exec bash "$SKILLS_DIR/copilot-acp/run.sh" "${PASSTHROUGH[@]}" ;;
  sdk) exec bash "$SKILLS_DIR/copilot-sdk/run.sh" "${PASSTHROUGH[@]}" ;;
  *) echo "unknown backend: $BACKEND (expected cli|acp|sdk)" >&2; exit 2 ;;
esac
