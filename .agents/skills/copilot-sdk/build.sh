#!/usr/bin/env bash
# Build the /copilot-sdk Go runner from source under scripts/.
#
# Output: .agents/skills/copilot-sdk/bin/runner
# Idempotent — skips the build if the binary is newer than every .go file.

set -eu

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SKILL_DIR/scripts"
BIN_DIR="$SKILL_DIR/bin"
BIN="$BIN_DIR/runner"

mkdir -p "$BIN_DIR"

if [ -x "$BIN" ]; then
  newest_src="$(ls -t "$SRC_DIR"/*.go "$SRC_DIR"/go.mod 2>/dev/null | head -1)"
  if [ -n "$newest_src" ] && [ "$BIN" -nt "$newest_src" ]; then
    echo "runner: up-to-date ($BIN)"
    exit 0
  fi
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: go toolchain not installed (required to build /copilot-sdk runner)" >&2
  exit 127
fi

echo "building /copilot-sdk runner..."
cd "$SRC_DIR"
if [ ! -f go.sum ] || ! grep -q copilot-sdk go.sum 2>/dev/null; then
  go mod tidy
fi
go build -o "$BIN" .
echo "built: $BIN"
