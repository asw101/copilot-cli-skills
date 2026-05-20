#!/usr/bin/env bash
# Walk .copilot-runs/*.usage.json and print a per-task cost table.
#
# Usage:
#   usage.sh             # all runs
#   usage.sh --since 2026-05-16   # filter by date prefix in run-id

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$REPO_ROOT/.copilot-runs"

SINCE=""
if [ "${1:-}" = "--since" ] && [ -n "${2:-}" ]; then
  SINCE="$2"
fi

python3 - "$RUNS_DIR" "$SINCE" <<'PY'
import json
import os
import sys
from pathlib import Path

runs_dir = Path(sys.argv[1])
since = sys.argv[2] or ""

rows = []
if runs_dir.is_dir():
    for p in sorted(runs_dir.glob("*.usage.json")):
        rid = p.stem.rsplit(".usage", 1)[0]
        if since and rid < since:
            continue
        try:
            u = json.loads(p.read_text())
        except Exception:
            continue
        rows.append(u)

if not rows:
    print("no .usage.json files found in", runs_dir)
    sys.exit(0)

def fmt(v, w):
    if v is None:
        s = "—"
    elif isinstance(v, float):
        s = f"{v:.1f}"
    else:
        s = str(v)
    return s.rjust(w)

header = f"{'backend':<6} {'model':<22} {'prem':>5} {'cost$':>7} {'in':>7} {'out':>6} {'cache↑':>7} {'cache↓':>7} {'time':>7}  run-id"
print(header)
print("-" * len(header))

total_premium = 0.0
total_cost = 0.0
total_in = total_out = total_cr = total_cw = 0
total_time = 0.0
n = 0
for u in rows:
    dur = u.get("duration_s")
    dkind = u.get("duration_kind") or ""
    tsuffix = {"wall_clock": "w", "api": "a", "session": "s"}.get(dkind, "")
    print(
        f"{(u.get('backend') or '—'):<6} "
        f"{(u.get('model') or '—'):<22} "
        f"{fmt(u.get('premium_requests'), 5)} "
        f"{fmt(u.get('cost_usd'), 7)} "
        f"{fmt(u.get('input_tokens'), 7)} "
        f"{fmt(u.get('output_tokens'), 6)} "
        f"{fmt(u.get('cache_read_tokens'), 7)} "
        f"{fmt(u.get('cache_write_tokens'), 7)} "
        f"{fmt(dur, 6)}{tsuffix or 's':>1}  "
        f"{u.get('run_id', '?')}"
    )
    n += 1
    total_premium += u.get("premium_requests") or 0.0
    total_cost += u.get("cost_usd") or 0.0
    total_in += u.get("input_tokens") or 0
    total_out += u.get("output_tokens") or 0
    total_cr += u.get("cache_read_tokens") or 0
    total_cw += u.get("cache_write_tokens") or 0
    total_time += u.get("duration_s") or 0.0

print("-" * len(header))
print(
    f"TOTAL ({n} runs):"
    f"  premium={total_premium:.1f}"
    f"  cost=${total_cost:.4f}"
    f"  in={total_in} out={total_out}"
    f"  cache_read={total_cr} cache_write={total_cw}"
    f"  duration={total_time:.1f}s"
)
PY
