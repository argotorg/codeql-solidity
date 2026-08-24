#!/usr/bin/env python3
"""Write out single sources from the sources parquet, by hash.

Usage: ./fetch_source.py <hash|path>... [-o outdir] [--stdout]
                         [--sources 'sources/*.parquet']

Takes a bare 64-hex source_hash or anything containing one, so a corpus path or
a `file://` URI copied straight out of a query result works as-is.
"""
import argparse
import glob
import os
import re
import sys

HASH = re.compile(r"([0-9a-f]{64})")
DEFAULT_SOURCES = ["sources/*.parquet"]
DEFAULT_COMPILED = ["compiled_contracts_sources/*.parquet"]

BAD = re.compile(r"[^A-Za-z0-9._-]")


def resolve(patterns, base):
    out = []
    for p in patterns:
        if not os.path.isabs(p):
            p = os.path.join(base, p)
        out.extend(glob.glob(p))
    return sorted(set(out))


def safe_name(path):
    base = re.split(r"[\\/]+", path)[-1]
    base = BAD.sub("_", base).lstrip(".")
    if not base.lower().endswith(".sol"):
        return None
    return base[:96] + ".sol" if len(base) > 100 else base


def contents(sources, hashes):
    """source_hash hex -> content, for the wanted hashes only.

    The `isin` goes into the dataset scan so the 17 GB of content stays on disk;
    reading a shard and filtering afterwards does not fit in memory.
    """
    import pyarrow.compute as pc
    import pyarrow.dataset as ds

    want = [bytes.fromhex(h) for h in sorted(hashes)]
    tbl = ds.dataset(sources, format="parquet").to_table(
        columns=["source_hash", "content"],
        filter=pc.field("source_hash").isin(want))
    return {bytes(h).hex(): c
            for h, c in zip(tbl["source_hash"].to_pylist(),
                            tbl["content"].to_pylist())}


def names(compiled, hashes):
    """source_hash hex -> most common basename, for whatever can be named."""
    import pyarrow.compute as pc
    import pyarrow.dataset as ds

    want = [bytes.fromhex(h) for h in sorted(hashes)]
    tbl = ds.dataset(compiled, format="parquet").to_table(
        columns=["source_hash", "path"],
        filter=pc.field("source_hash").isin(want))
    ranked = tbl.group_by(["source_hash", "path"]).aggregate([([], "count_all")])

    best = {}
    for h, p, n in zip(ranked["source_hash"].to_pylist(),
                       ranked["path"].to_pylist(),
                       ranked["count_all"].to_pylist()):
        h = bytes(h).hex()
        name = safe_name(p)
        if name and n > best.get(h, (0, None))[0]:
            best[h] = (n, name)
    return {h: name for h, (_, name) in best.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hashes", nargs="+", metavar="HASH|PATH")
    ap.add_argument("-o", "--outdir", default=".")
    ap.add_argument("--stdout", action="store_true",
                    help="write content to stdout instead of files")
    ap.add_argument("--sources", nargs="+", default=DEFAULT_SOURCES)
    ap.add_argument("--compiled", nargs="+", default=DEFAULT_COMPILED,
                    help="only used to name the output files")
    args = ap.parse_args()

    wanted = []
    for a in args.hashes:
        m = HASH.search(a.lower())
        if not m:
            sys.exit(f"No 64-hex source hash in: {a}")
        if m.group(1) not in wanted:
            wanted.append(m.group(1))

    here = os.path.dirname(os.path.abspath(__file__))
    sources = resolve(args.sources, here)
    if not sources:
        sys.exit(f"No sources parquet matched: {args.sources}\n"
                 f"Download it with\n"
                 f"  ./download_parquet.py sources -n 632")

    found = contents(sources, wanted)
    if args.stdout:
        for h in wanted:
            if h in found:
                sys.stdout.write(found[h])
    else:
        compiled = resolve(args.compiled, here)
        named = names(compiled, found) if compiled else {}
        os.makedirs(args.outdir, exist_ok=True)
        for h in wanted:
            if h not in found:
                continue
            stem = f"{h}__{named[h]}" if h in named else f"{h}.sol"
            path = os.path.join(args.outdir, stem)
            with open(path, "w") as f:
                f.write(found[h])
            print(f"{path} ({len(found[h])} bytes)")

    missing = [h for h in wanted if h not in found]
    for h in missing:
        print(f"not in the sources dataset: {h}", file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
