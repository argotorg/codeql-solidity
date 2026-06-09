#!/usr/bin/env python3
"""Extract the Solidity source files for a Sourcify compilation.

Joins two sets of parquet files:
  - compiled_contracts_sources_*.parquet : (compilation_id, source_hash, path)
  - sources_*.parquet                    : (source_hash, content)

Given a compilation_id (or just a prefix of one), finds every matching
compilation and writes each of its source files to disk under
<outdir>/<compilation_id>/<path>.

Both --compiled and --sources accept multiple paths and/or glob patterns, so a
compilation whose rows or source contents are spread across several parquet
shards is handled: all shards are scanned and the join spans them.

Usage:
  ./extract_compilation.py e47e45b1-05e9-45d4-b8a6
  ./extract_compilation.py e47e45b1 \
      --compiled 'compiled_contracts_sources_*.parquet' \
      --sources  'sources_*.parquet'
  ./extract_compilation.py e47e45b1 --sources sources_0_10000.parquet sources_10000_20000.parquet
"""
import argparse
import glob
import os
import re
import sys

import pyarrow as pa
import pyarrow.parquet as pq
import pyarrow.compute as pc

# Defaults are glob patterns so newly-downloaded shards are picked up
# automatically without changing the command line.
DEFAULT_COMPILED = ["compiled_contracts_sources/*.parquet"]
DEFAULT_SOURCES = ["sources/*.parquet"]


def safe_join(base, *parts):
    """Join `parts` under `base`, guaranteeing the result stays inside `base`.

    Sourcify `path` values are arbitrary compiler-input paths: they may be
    absolute (`/Users/.../Foo.sol`), contain `..`, Windows drive letters, or a
    leading slash. We split every part on both slash kinds and drop anything
    that could escape — empty / `.` / `..` components and bare drive letters —
    so the output can never land outside `base`. A final realpath containment
    check is belt-and-suspenders.

    Returns the absolute path on success, or None if (after sanitizing) nothing
    is left to write, or the result would somehow still escape `base`.
    """
    base = os.path.abspath(base)
    cleaned = []
    for part in parts:
        for comp in re.split(r"[\\/]+", part):
            comp = comp.strip()
            if comp in ("", ".", ".."):
                continue
            if re.fullmatch(r"[A-Za-z]:", comp):  # drop Windows drive (e.g. "C:")
                continue
            # strip any character that has no business in a path segment
            comp = comp.replace("\x00", "")
            cleaned.append(comp)
    if not cleaned:
        return None
    full = os.path.abspath(os.path.join(base, *cleaned))
    # Containment check against the real (symlink-resolved) base.
    real_base = os.path.realpath(base)
    real_full = os.path.realpath(full)
    if real_full != real_base and os.path.commonpath([real_base, real_full]) != real_base:
        return None
    return full


def resolve_files(patterns, base):
    """Expand a list of paths/globs (relative to `base`) into concrete files."""
    files = []
    for pat in patterns:
        p = pat if os.path.isabs(pat) else os.path.join(base, pat)
        hits = sorted(glob.glob(p))
        if hits:
            files.extend(hits)
        elif os.path.exists(p):
            files.append(p)
    # de-dup while preserving order
    seen = set()
    out = []
    for f in files:
        if f not in seen:
            seen.add(f)
            out.append(f)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("compilation_id",
                    help="full compilation_id or a leading prefix of one")
    ap.add_argument("--compiled", nargs="+", default=DEFAULT_COMPILED,
                    help="compiled_contracts_sources parquet file(s)/glob(s) "
                         "(default: %(default)s)")
    ap.add_argument("--sources", nargs="+", default=DEFAULT_SOURCES,
                    help="sources parquet file(s)/glob(s) (default: %(default)s)")
    ap.add_argument("--outdir", default="extracted",
                    help="output directory (default: %(default)s)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    compiled_files = resolve_files(args.compiled, here)
    sources_files = resolve_files(args.sources, here)

    if not compiled_files:
        sys.exit(f"No compiled parquet files matched: {args.compiled}")
    if not sources_files:
        sys.exit(f"No sources parquet files matched: {args.sources}")

    print(f"Scanning {len(compiled_files)} compiled shard(s), "
          f"{len(sources_files)} sources shard(s).")

    # 1. Across all compiled shards, collect rows whose compilation_id starts
    #    with the given prefix. Skip files that aren't compiled-sources shards
    #    (e.g. a stray sources_*.parquet caught by a loose glob).
    matched = []
    for f in compiled_files:
        names = set(pq.read_schema(f).names)
        if not {"compilation_id", "source_hash", "path"} <= names:
            print(f"  skip (not a compiled-sources shard): {os.path.basename(f)}")
            continue
        t = pq.read_table(f, columns=["compilation_id", "source_hash", "path"])
        t = t.filter(pc.starts_with(t["compilation_id"], args.compilation_id))
        if t.num_rows:
            matched.append(t)
    if not matched:
        sys.exit(f"No compilation_id matching prefix {args.compilation_id!r} "
                 f"found in any compiled shard.")
    cs = pa.concat_tables(matched)

    matched_cids = pc.unique(cs["compilation_id"]).to_pylist()
    print(f"Matched {len(matched_cids)} compilation_id(s), {cs.num_rows} source file(s):")
    for c in matched_cids:
        print(f"  {c}")

    # 2. Build a source_hash -> content lookup, but only for the hashes we
    #    actually need, scanning every sources shard. (Avoids holding all
    #    contents in memory when shards are large.)
    needed = set(bytes(h) for h in cs["source_hash"].to_pylist())
    content_by_hash = {}
    for f in sources_files:
        # Skip files that aren't sources shards (e.g. the compiled-sources
        # parquet caught by a loose glob like *sources*.parquet).
        names = set(pq.read_schema(f).names)
        if not {"source_hash", "content"} <= names:
            print(f"  skip (not a sources shard): {os.path.basename(f)}")
            continue
        src = pq.read_table(f, columns=["source_hash", "content"])
        for h, c in zip(src["source_hash"].to_pylist(), src["content"].to_pylist()):
            hb = bytes(h)
            if hb in needed and hb not in content_by_hash:
                content_by_hash[hb] = c
        if len(content_by_hash) == len(needed):
            break  # found everything; no need to scan further shards

    # 3. Write each matched file. The output root is always resolved against
    #    the current working directory; every file is written through
    #    safe_join() so a malicious/absolute `path` can never escape it.
    out_root = os.path.abspath(args.outdir)
    written = 0
    missing = 0
    unsafe = 0
    for cid, h, path in zip(cs["compilation_id"].to_pylist(),
                            cs["source_hash"].to_pylist(),
                            cs["path"].to_pylist()):
        content = content_by_hash.get(bytes(h))
        if content is None:
            print(f"  MISSING content (hash {bytes(h).hex()}): {path}")
            missing += 1
            continue
        full = safe_join(out_root, cid, path)
        if full is None:
            print(f"  SKIP unsafe path (would escape {out_root}): {path!r}")
            unsafe += 1
            continue
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as fh:
            fh.write(content)
        # show the path relative to the output root for readability
        print(f"  wrote {os.path.relpath(full, out_root)} ({len(content)} bytes)")
        written += 1

    print(f"\nDone: {written} written, {missing} missing content "
          f"(hash not found in any sources shard), {unsafe} skipped (unsafe path).")
    if missing or unsafe:
        sys.exit(1)


if __name__ == "__main__":
    main()
