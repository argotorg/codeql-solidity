#!/usr/bin/env python3
"""Extract every unique Sourcify source as <outdir>/<xx>/<yy>/<hash>.sol.

Usage: ./extract_all_sources.py [--sources 'sources/*.parquet'] [-o extracted-all]
                                [-j N] [--solidity-only] [--limit N]

Unlike extract_compilation.py this does no join: it streams the sources shards
and writes each unique content once, so memory stays flat and the output is the
~6.3M distinct files rather than the ~25M duplicated per-compilation instances.
The extractor never resolves imports, so the per-compilation tree buys nothing.
"""
import argparse
import glob
import os
import sys
from concurrent.futures import ProcessPoolExecutor

import pyarrow.parquet as pq

DEFAULT_SOURCES = ["sources/*.parquet"]
DEFAULT_COMPILED = ["compiled_contracts_sources/*.parquet"]


def resolve(patterns, base):
    out = []
    for p in patterns:
        if not os.path.isabs(p):
            p = os.path.join(base, p)
        out.extend(sorted(glob.glob(p)))
    return sorted(set(out))


def solidity_hashes(files):
    """Hashes whose path ends in .sol, from the compiled-sources shards."""
    import pyarrow.compute as pc
    keep = set()
    for f in files:
        names = set(pq.read_schema(f).names)
        if not {"source_hash", "path"} <= names:
            continue
        t = pq.read_table(f, columns=["source_hash", "path"])
        lowered = pc.utf8_lower(t["path"])
        mask = pc.ends_with(lowered, pattern=".sol")
        for h in t["source_hash"].filter(mask).to_pylist():
            keep.add(bytes(h))
        print(f"  indexed {os.path.basename(f)}: {len(keep)} .sol hashes", flush=True)
    return keep


def do_shard(job):
    path, outdir, allow = job
    names = set(pq.read_schema(path).names)
    if not {"source_hash", "content"} <= names:
        return (path, 0, 0, 0)

    written = skipped = failed = 0
    made = set()
    pf = pq.ParquetFile(path)
    for batch in pf.iter_batches(batch_size=512, columns=["source_hash", "content"]):
        hashes = batch.column("source_hash").to_pylist()
        contents = batch.column("content").to_pylist()
        for h, content in zip(hashes, contents):
            if content is None:
                failed += 1
                continue
            hb = bytes(h)
            if allow is not None and hb not in allow:
                skipped += 1
                continue
            hx = hb.hex()
            d = os.path.join(outdir, hx[:2], hx[2:4])
            if d not in made:
                os.makedirs(d, exist_ok=True)
                made.add(d)
            final = os.path.join(d, hx + ".sol")
            if os.path.exists(final):
                skipped += 1
                continue
            # tmp+rename so an interrupted run never leaves a half file that
            # the resume check would then treat as complete
            tmp = final + ".part"
            try:
                with open(tmp, "w", encoding="utf-8", errors="replace") as fh:
                    fh.write(content)
                os.replace(tmp, final)
                written += 1
            except OSError as e:
                print(f"  ERROR {hx}: {e}", file=sys.stderr, flush=True)
                if os.path.exists(tmp):
                    os.unlink(tmp)
                failed += 1
    return (path, written, skipped, failed)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sources", nargs="+", default=DEFAULT_SOURCES)
    ap.add_argument("--compiled", nargs="+", default=DEFAULT_COMPILED)
    ap.add_argument("-o", "--outdir", default="extracted-all")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--solidity-only", action="store_true",
                    help="drop non-.sol sources (~0.02%%); needs the compiled shards")
    ap.add_argument("--limit", type=int, help="only process the first N shards")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    files = resolve(args.sources, here)
    if not files:
        sys.exit(f"No sources parquet matched: {args.sources}")
    if args.limit:
        files = files[:args.limit]

    allow = None
    if args.solidity_only:
        compiled = resolve(args.compiled, here)
        if not compiled:
            sys.exit(f"No compiled parquet matched: {args.compiled}")
        print(f"Indexing .sol hashes from {len(compiled)} compiled shard(s)...")
        allow = solidity_hashes(compiled)
        print(f"{len(allow)} .sol hashes")

    outdir = os.path.abspath(args.outdir)
    os.makedirs(outdir, exist_ok=True)
    print(f"{len(files)} shard(s) -> {outdir} with {args.jobs} worker(s)")

    tw = ts = tf = 0
    jobs = [(f, outdir, allow) for f in files]
    with ProcessPoolExecutor(max_workers=args.jobs) as ex:
        for i, (path, w, s, f) in enumerate(ex.map(do_shard, jobs), 1):
            tw += w; ts += s; tf += f
            print(f"[{i}/{len(files)}] {os.path.basename(path)}: "
                  f"+{w} written, {s} skipped, {f} failed "
                  f"(total {tw} written)", flush=True)

    print(f"\nDone: {tw} written, {ts} skipped, {tf} failed.")
    return 1 if tf else 0


if __name__ == "__main__":
    sys.exit(main())
