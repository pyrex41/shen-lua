#!/bin/sh
# scripts/coverage.sh — run the port specs under LuaCov and emit a report.
#
# Best-effort: if luacov is not installed (or no Lua interpreter with the
# luacov module can be found), print a clear message and exit 0 so a plain
# build / CI step is never broken by a missing optional tool.
#
# Usage:  sh scripts/coverage.sh
#         LUA=lua sh scripts/coverage.sh
set -e

# Resolve repo root from this script's location.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Pick an interpreter: $LUA, else luajit, else lua.
LUA="${LUA:-}"
if [ -z "$LUA" ]; then
  if command -v luajit >/dev/null 2>&1; then LUA=luajit
  elif command -v lua >/dev/null 2>&1; then LUA=lua
  else
    echo "coverage: no lua/luajit interpreter found — skipping (not a failure)."
    exit 0
  fi
fi

# Is the luacov module importable by this interpreter?
if ! "$LUA" -e 'require("luacov.runner")' >/dev/null 2>&1; then
  echo "coverage: luacov not installed for '$LUA' — skipping (not a failure)."
  echo "          install with:  luarocks install luacov"
  exit 0
fi

echo "coverage: running port specs under luacov ($LUA) ..."

# Remove any stale stats so the report reflects only this run.
rm -f luacov.stats.out luacov.report.out

# Run every spec with the luacov runner auto-loaded. Each spec os.exit()s, but
# the luacov runner installs an atexit hook that flushes stats on exit, so the
# per-spec stats accumulate into luacov.stats.out.
for spec in test/*_spec.lua; do
  echo "  - $spec"
  # -lluacov loads the coverage hook before the spec runs. We tolerate a
  # nonzero spec exit here (coverage is about measurement, not pass/fail);
  # `make test` is the gate that fails on a red spec.
  "$LUA" -lluacov "$spec" >/dev/null 2>&1 || true
done

# Generate the human-readable report.
if command -v luacov >/dev/null 2>&1; then
  luacov
elif "$LUA" -e 'require("luacov")' >/dev/null 2>&1; then
  "$LUA" -e 'require("luacov.runner").run_report()' 2>/dev/null || true
fi

if [ -f luacov.report.out ]; then
  echo "coverage: report written to luacov.report.out"
  echo "----- summary (tail) -----"
  tail -n 25 luacov.report.out || true
else
  echo "coverage: stats collected (luacov.stats.out); run 'luacov' to format a report."
fi
