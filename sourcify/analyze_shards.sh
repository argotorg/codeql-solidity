#!/usr/bin/env bash
# Build+analyze one CodeQL db per <xx> corpus subdir, keeping only the JSON results.
# Usage: ./analyze_shards.sh <corpus-dir> <out-dir> [prefix...]
set -euo pipefail

CORPUS=${1:?corpus dir}
OUT=${2:?out dir}
shift 2 || true
ROOT=$(git rev-parse --show-toplevel)
export CODEQL_EXTRACTOR_SOLIDITY_ROOT="$ROOT/extractor-pack"

mapfile -t PREFIXES < <(if [ $# -gt 0 ]; then printf '%s\n' "$@"; else
  find "$CORPUS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; fi)

mkdir -p "$OUT"
for p in "${PREFIXES[@]}"; do
  dest=$OUT/$p
  # a finished shard leaves .done; anything else is a partial run to redo
  if [ -f "$dest/.done" ]; then echo "skip $p (done)"; continue; fi
  n=$(find "$CORPUS/$p" -name '*.sol' | wc -l)
  echo "=== $p: $n files ==="
  rm -rf "$dest" "$OUT/db-$p"; mkdir -p "$dest"

  codeql database create "$OUT/db-$p" --language=solidity \
    --source-root="$CORPUS/$p" --search-path="$ROOT" --overwrite
  codeql dataset measure -j"$(nproc)" \
    -o "$OUT/db-$p/db-solidity/solidity.dbscheme.stats" "$OUT/db-$p/db-solidity"
  codeql database run-queries "$OUT/db-$p" "$ROOT/queries" \
    --additional-packs="$ROOT" --threads=0 --rerun

  find "$OUT/db-$p/results" -name '*.bqrs' | while read -r bqrs; do
    codeql bqrs decode --format=json --entities=url,string "$bqrs" \
      > "$dest/$(basename "$bqrs" .bqrs).json"
  done

  # the db is ~4x the sources; keeping 256 of them would not fit
  rm -rf "$OUT/db-$p"
  touch "$dest/.done"
  echo "=== $p done: $(ls "$dest"/*.json | wc -l) result sets ==="
done
