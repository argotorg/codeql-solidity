#!/usr/bin/env python3
"""Run queries over the shard databases built by build_dbs.py.

Usage: ./query_dbs.py <db-dir> <out-dir> [-q QUERY]... [-w N] [-j N] [--ram MB] [prefix...]

Re-runnable: point -q at a different .ql, suite or directory and it queries the
same databases again. Results land in <out-dir>/<shard>/<query>.json. Without -q
it runs the repo's whole queries/ pack.

Parallelism defaults to one single-threaded evaluator per core across shards,
which scales far better than one many-threaded evaluator per shard, capped so
the workers fit in memory. Each worker is a separate JVM that would otherwise
size its heap from *total* machine RAM, so -w and --ram are chosen together.
"""
import argparse
import os
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor


def run(cmd, env):
    p = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])} failed ({p.returncode}):\n"
                           f"{p.stdout[-1500:]}\n{p.stderr[-1500:]}")
    return p.stdout


def resolve_queries(queries, root, env):
    """Absolute .ql paths the given query args expand to."""
    out = subprocess.run(["codeql", "resolve", "queries"] + queries +
                         [f"--additional-packs={root}"],
                         env=env, capture_output=True, text=True, check=True).stdout
    return [l.strip() for l in out.splitlines() if l.strip().endswith(".ql")]


MEM_FRACTION = 0.6   # rest is page cache for the mmapped relations
MB_PER_WORKER = 5000  # steady-state working set of one shard evaluator


def total_ram_mb():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) // 1024
    except OSError:
        pass
    return 0


def plan(workers, ram, cores):
    """Pick -w/--ram so the JVMs together fit in MEM_FRACTION of RAM."""
    budget = int(total_ram_mb() * MEM_FRACTION)
    if not budget:
        return workers or cores, ram
    if not workers:
        workers = max(1, min(cores, budget // (ram or MB_PER_WORKER)))
    return workers, ram or max(2048, budget // workers)


def query(job):
    prefix, dbdir, out, root, queries, jobs, ram, rerun, wanted = job
    db = os.path.join(dbdir, prefix)
    dest = os.path.join(out, prefix)
    if not os.path.exists(os.path.join(db, ".built")):
        return (prefix, 0, 0.0, "no database")

    env = dict(os.environ,
               CODEQL_EXTRACTOR_SOLIDITY_ROOT=os.path.join(root, "extractor-pack"))
    ram_args = ["--ram", str(ram)] if ram else []
    t0 = time.monotonic()
    try:
        os.makedirs(dest, exist_ok=True)
        cmd = ["codeql", "database", "run-queries", db] + queries + [
            f"--additional-packs={root}", "--threads", str(jobs)] + ram_args
        if rerun:
            cmd.append("--rerun")
        run(cmd, env)

        # decode only what was asked for: <db>/results also holds bqrs cached
        # by earlier runs of other queries
        sets = 0
        for dp, _, fs in os.walk(os.path.join(db, "results")):
            for f in fs:
                if not f.endswith(".bqrs") or f[:-5] not in wanted:
                    continue
                js = run(["codeql", "bqrs", "decode", "--format=json",
                          "--entities=url,string", os.path.join(dp, f)], env)
                with open(os.path.join(dest, f[:-5] + ".json"), "w") as fh:
                    fh.write(js)
                sets += 1
    except Exception as e:
        return (prefix, 0, time.monotonic() - t0, f"FAILED: {e}")
    return (prefix, sets, time.monotonic() - t0, "ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dbdir")
    ap.add_argument("out")
    ap.add_argument("prefixes", nargs="*", help="default: every built database")
    ap.add_argument("-q", "--query", action="append", default=[],
                    help="a .ql, .qls or directory; repeatable (default: queries/)")
    ap.add_argument("-j", "--jobs", type=int, default=8,
                    help="evaluator threads per shard (default: 1)")
    ap.add_argument("-w", "--workers", type=int, default=5,
                    help="shards queried concurrently (default: one per core, "
                         "capped to what fits in RAM)")
    ap.add_argument("--ram", type=int,
                    help="MB, per worker (default: the memory budget split "
                         "across -w)")
    ap.add_argument("--rerun", action="store_true",
                    help="ignore cached results in the database")
    args = ap.parse_args()
    args.workers, args.ram = plan(args.workers, args.ram, os.cpu_count())

    root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, check=True).stdout.strip()
    dbdir, out = os.path.abspath(args.dbdir), os.path.abspath(args.out)
    queries = [os.path.abspath(q) for q in args.query] or [os.path.join(root, "queries")]
    prefixes = args.prefixes or sorted(
        d for d in os.listdir(dbdir)
        if os.path.exists(os.path.join(dbdir, d, ".built")))
    os.makedirs(out, exist_ok=True)
    print(f"{len(prefixes)} database(s) x {len(queries)} query path(s), "
          f"{args.workers}w x {args.jobs}j, {args.ram}MB each -> {out}", flush=True)

    env = dict(os.environ,
               CODEQL_EXTRACTOR_SOLIDITY_ROOT=os.path.join(root, "extractor-pack"))
    wanted = {os.path.basename(q)[:-3] for q in resolve_queries(queries, root, env)}
    if not wanted:
        sys.exit(f"No queries resolved from: {queries}")
    print(f"{len(wanted)} query/queries: {', '.join(sorted(wanted)[:5])}"
          f"{'...' if len(wanted) > 5 else ''}", flush=True)

    jobs = [(p, dbdir, out, root, queries, args.jobs, args.ram, args.rerun, wanted)
            for p in prefixes]
    ok = failed = 0
    t0 = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.workers) as ex:
        for i, (p, sets, dt, status) in enumerate(ex.map(query, jobs), 1):
            if status == "ok":
                ok += 1
                print(f"[{i}/{len(prefixes)}] {p}: {sets} result sets, {dt:.0f}s", flush=True)
            else:
                failed += 1
                print(f"[{i}/{len(prefixes)}] {p}: {status}", file=sys.stderr, flush=True)

    print(f"\n{ok} queried, {failed} failed, {(time.monotonic()-t0)/60:.1f} min.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
