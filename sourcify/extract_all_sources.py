#!/usr/bin/env python3
"""Extract every unique Sourcify source as <outdir>/<xx>/<yy>/<hash>__<name>.sol.

Usage: ./extract_all_sources.py [-o corpus] [-j N] [--solidity-only] [--limit N]
                                [--sources 'sources/*.parquet']

Unlike extract_compilation.py this does no join over compilations: it streams the
sources shards and writes each unique content once, so memory stays flat and the
output is the ~6.3M distinct files rather than the ~25M duplicated per-compilation
instances. The extractor never resolves imports, so the per-compilation tree buys
no analysis fidelity.

The compiled shards are read once to recover a filename per hash, so results say
Ownable.sol rather than a bare hash; both datasets are therefore required.
Basenames are not unique (2794 distinct sources are called Token.sol), hence the
hash prefix. A source no compilation references falls back to a bare hash.
"""
import argparse
import glob
import multiprocessing
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor

import pyarrow.parquet as pq

DEFAULT_SOURCES = ["sources/*.parquet"]
DEFAULT_COMPILED = ["compiled_contracts_sources/*.parquet"]

# ~1.7 GB for the full dataset; shared copy-on-write via the fork start method
# rather than passed per job, which would pickle it once per shard
NAMES = {}
ONLY_SOL = False

BAD = re.compile(r"[^A-Za-z0-9._-]")


def resolve(patterns, base):
    out = []
    for p in patterns:
        if not os.path.isabs(p):
            p = os.path.join(base, p)
        out.extend(glob.glob(p))
    return sorted(set(out))


def safe_name(path):
    """A filesystem-safe basename for a Sourcify compiler-input path, or None.

    Sourcify paths are arbitrary compiler input: absolute, `..`-laden, Windows
    drive letters, control characters. Keep only the last component, allowlist
    the characters, and drop leading dots so `.`/`..` cannot survive.
    """
    base = re.split(r"[\\/]+", path)[-1]
    base = BAD.sub("_", base).lstrip(".")
    if not base.lower().endswith(".sol"):
        return None
    if len(base) > 100:
        base = base[:96] + ".sol"
    if os.sep in base or base in (".", ".."):  # unreachable; cheap to assert
        return None
    return base


def build_names(files, only_sol):
    """hash -> basename, from the compiled-sources shards."""
    names = {}
    for i, f in enumerate(files, 1):
        cols = set(pq.read_schema(f).names)
        if not {"source_hash", "path"} <= cols:
            continue
        t = pq.read_table(f, columns=["source_hash", "path"])
        for h, p in zip(t["source_hash"].to_pylist(), t["path"].to_pylist()):
            hb = bytes(h)
            if hb in names:
                continue
            n = safe_name(p)
            if n is None and only_sol:
                continue
            if n is not None:
                names[hb] = n
        print(f"  [{i}/{len(files)}] {os.path.basename(f)}: {len(names)} named",
              flush=True)
    return names


def do_shard(job):
    path, outdir = job
    cols = set(pq.read_schema(path).names)
    if not {"source_hash", "content"} <= cols:
        return (path, 0, 0, 0)

    written = skipped = failed = 0
    made = set()
    pf = pq.ParquetFile(path)
    for batch in pf.iter_batches(batch_size=512, columns=["source_hash", "content"]):
        for h, content in zip(batch.column("source_hash").to_pylist(),
                              batch.column("content").to_pylist()):
            if content is None:
                failed += 1
                continue
            hb = bytes(h)
            name = NAMES.get(hb)
            if name is None and ONLY_SOL:
                skipped += 1
                continue
            hx = hb.hex()
            d = os.path.join(outdir, hx[:2], hx[2:4])
            if d not in made:
                os.makedirs(d, exist_ok=True)
                made.add(d)
            final = os.path.join(d, f"{hx}__{name}" if name else f"{hx}.sol")
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
    global NAMES, ONLY_SOL
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sources", nargs="+", default=DEFAULT_SOURCES)
    ap.add_argument("--compiled", nargs="+", default=DEFAULT_COMPILED)
    ap.add_argument("-o", "--outdir", default="corpus")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--solidity-only", action="store_true",
                    help="drop the ~0.02%% of sources whose path is not .sol")
    ap.add_argument("--limit", type=int, help="only process the first N sources shards")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    files = resolve(args.sources, here)
    if not files:
        sys.exit(f"No sources parquet matched: {args.sources}")
    if args.limit:
        files = files[:args.limit]

    ONLY_SOL = args.solidity_only
    compiled = resolve(args.compiled, here)
    if not compiled:
        sys.exit(f"No compiled parquet matched: {args.compiled}\n"
                 f"Filenames come from that dataset — download it with\n"
                 f"  ./download_parquet.py compiled_contracts_sources -n 40")
    print(f"Indexing filenames from {len(compiled)} compiled shard(s)...")
    NAMES = build_names(compiled, ONLY_SOL)
    print(f"{len(NAMES)} hashes named")

    outdir = os.path.abspath(args.outdir)
    os.makedirs(outdir, exist_ok=True)
    print(f"{len(files)} shard(s) -> {outdir} with {args.jobs} worker(s)")

    tw = ts = tf = 0
    jobs = [(f, outdir) for f in files]
    # fork so workers inherit NAMES copy-on-write; 3.14 defaults to forkserver,
    # which would re-import this module and lose it
    ctx = multiprocessing.get_context("fork")
    with ProcessPoolExecutor(max_workers=args.jobs, mp_context=ctx) as ex:
        for i, (path, w, s, f) in enumerate(ex.map(do_shard, jobs), 1):
            tw += w; ts += s; tf += f
            print(f"[{i}/{len(files)}] {os.path.basename(path)}: "
                  f"+{w} written, {s} skipped, {f} failed (total {tw})", flush=True)

    print(f"\nDone: {tw} written, {ts} skipped, {tf} failed.")
    return 1 if tf else 0


if __name__ == "__main__":
    sys.exit(main())
