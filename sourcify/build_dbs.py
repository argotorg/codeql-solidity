#!/usr/bin/env python3
"""Build one CodeQL database per <xx> corpus subdir, and keep it.

Usage: ./build_dbs.py <corpus-dir> <db-dir> [-j N] [-w N] [--ram MB] [prefix...]

Databases are kept so you can query them repeatedly; run queries over them with
query_dbs.py. Budget ~4x the corpus size. A finished database keeps a .built
marker and is skipped on re-run, so an interrupted pass resumes.

Memory scales with shard size and -j together; on a small machine lower -j and
set --ram before reaching for -w.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor


def run(cmd, env):
    p = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])} failed ({p.returncode}):\n"
                           f"{p.stdout[-1500:]}\n{p.stderr[-1500:]}")


def build(job):
    prefix, corpus, dbdir, root, jobs, ram = job
    src = os.path.join(corpus, prefix)
    db = os.path.join(dbdir, prefix)
    marker = os.path.join(db, ".built")

    if os.path.exists(marker):
        return (prefix, 0, 0.0, 0, "skipped")
    n = sum(len([f for f in fs if f.endswith(".sol")]) for _, _, fs in os.walk(src))
    if n == 0:
        return (prefix, 0, 0.0, 0, "empty")

    env = dict(os.environ,
               CODEQL_EXTRACTOR_SOLIDITY_ROOT=os.path.join(root, "extractor-pack"))
    ram_args = ["--ram", str(ram)] if ram else []
    t0 = time.monotonic()
    try:
        shutil.rmtree(db, ignore_errors=True)
        run(["codeql", "database", "create", db, "--language=solidity",
             f"--source-root={src}", f"--search-path={root}", "--overwrite",
             "-j", str(jobs)] + ram_args, env)
        # the query compiler needs this; without it every query fails on the
        # missing solidity.dbscheme.stats
        run(["codeql", "dataset", "measure", "-j", str(jobs),
             "-o", os.path.join(db, "db-solidity", "solidity.dbscheme.stats"),
             os.path.join(db, "db-solidity")], env)
    except Exception as e:
        shutil.rmtree(db, ignore_errors=True)
        return (prefix, n, time.monotonic() - t0, 0, f"FAILED: {e}")

    size = sum(os.path.getsize(os.path.join(dp, f))
               for dp, _, fs in os.walk(db) for f in fs)
    open(marker, "w").close()
    return (prefix, n, time.monotonic() - t0, size, "ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("corpus")
    ap.add_argument("dbdir")
    ap.add_argument("prefixes", nargs="*", help="default: every subdir of <corpus>")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
    ap.add_argument("-w", "--workers", type=int, default=1,
                    help="shards built concurrently (total threads = j*w)")
    ap.add_argument("--ram", type=int, help="MB, per database build")
    args = ap.parse_args()

    root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, check=True).stdout.strip()
    corpus, dbdir = os.path.abspath(args.corpus), os.path.abspath(args.dbdir)
    prefixes = args.prefixes or sorted(
        d for d in os.listdir(corpus) if os.path.isdir(os.path.join(corpus, d)))
    os.makedirs(dbdir, exist_ok=True)
    print(f"{len(prefixes)} shard(s), {args.workers}w x {args.jobs}j -> {dbdir}", flush=True)

    jobs = [(p, corpus, dbdir, root, args.jobs, args.ram) for p in prefixes]
    built = failed = files = total = 0
    t0 = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.workers) as ex:
        for i, (p, n, dt, size, status) in enumerate(ex.map(build, jobs), 1):
            if status.startswith("FAILED"):
                failed += 1
                print(f"[{i}/{len(prefixes)}] {p}: {status}", file=sys.stderr, flush=True)
            elif status == "ok":
                built += 1; files += n; total += size
                el = time.monotonic() - t0
                eta = el / built * (len(prefixes) - i)
                print(f"[{i}/{len(prefixes)}] {p}: {n} files, {dt:.0f}s, "
                      f"{size/1e9:.1f} GB  (eta {eta/3600:.1f}h)", flush=True)
            else:
                print(f"[{i}/{len(prefixes)}] {p}: {status}", flush=True)

    print(f"\nBuilt {built} databases, {files} files, {total/1e9:.1f} GB, "
          f"{failed} failed, {(time.monotonic()-t0)/60:.1f} min.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
