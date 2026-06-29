#!/usr/bin/env bash
# build-client.sh — regenerate the browser-side Shen validator.
#
# Pipeline:
#   1. concatenate rules.shen + client.glue.shen into one program
#   2. Ratatoskr (Shen tree-shaker) shakes it to a minimal KLambda slice
#      (~100 kernel defuns instead of the full ~2500), eval-stripped
#   3. build-client.mjs compiles that slice with ShenScript's compiler and
#      emits public/vendor/shen-rules.client.js — a self-contained ES module
#      (~140 KB, ~20 ms to init in the browser vs ~2.3 s for the full kernel)
#
# The committed shen-rules.client.js is the output of this script; rerun it
# whenever rules.shen changes so the client and server can't drift.
#
# Requires (siblings of this repo, override via env):
#   RATATOSKR      the ratatoskr binary   (default ../../ratatoskr/ratatoskr)
#   SHENSCRIPT_DIR a ShenScript checkout  (default ../../ShenScript)
#   plus luajit (for the shen-lua shake host) and node 20+.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
example="$(cd "$here/.." && pwd)"
repo="$(cd "$example/../.." && pwd)"

RATATOSKR="${RATATOSKR:-$repo/../ratatoskr/ratatoskr}"
SHENSCRIPT_DIR="${SHENSCRIPT_DIR:-$repo/../ShenScript}"
out="$example/public/vendor/shen-rules.client.js"

[ -x "$RATATOSKR" ]  || { echo "ratatoskr not found/executable at $RATATOSKR (set RATATOSKR)"; exit 1; }
[ -d "$SHENSCRIPT_DIR" ] || { echo "ShenScript not found at $SHENSCRIPT_DIR (set SHENSCRIPT_DIR)"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. one program = the shared rules + the browser marshaling glue
cat "$example/rules.shen" "$here/client.glue.shen" > "$tmp/client-prog.shen"

# 2. shake (host = shen-lua's launcher; shake output is host-independent)
"$RATATOSKR" shake "$tmp/client-prog.shen" "$tmp/slice" \
  --host "$repo/bin/shen" --eval-style positional

# 3. compile the slice to a self-contained browser ES module
mkdir -p "$(dirname "$out")"
SHENSCRIPT_DIR="$SHENSCRIPT_DIR" node "$here/build-client.mjs" "$tmp/slice" "$out"
echo "wrote $out"
