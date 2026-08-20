#!/usr/bin/env python3
"""Show a merged result set from merge_results.py as a terminal table.

Usage: ./show_results.py <merged-dir|csv> [SET] [-c COLS] [-w COL=VAL]...
                         [-g COLS] [-s COL] [-r] [-n N] [-e] [--csv]

With a directory and no SET, lists what is available. -w takes COL=VAL,
COL!=VAL or COL~REGEX. -g counts rows per group instead of listing them.
-e joins the Sourcify compiled_contracts_sources parquet onto the rows that
are actually displayed, adding how many compilations reuse each source and
what paths it is compiled under.
"""
import argparse
import csv
import os
import re
import sys
from collections import Counter, defaultdict

csv.field_size_limit(1 << 24)

HASH = re.compile(r"([0-9a-f]{64})")
HERE = os.path.dirname(os.path.abspath(__file__))
# a compilation is a verification event, not an on-chain deployment: this
# counts reuse of the source, not live instances (that needs contract_deployments)
ENRICH_COLS = ["ncomp", "npaths", "path"]


def lookup(hashes, compiled):
    """source_hash hex -> (n compilations, [paths, most common first])."""
    import pyarrow.compute as pc
    import pyarrow.dataset as ds

    want = [bytes.fromhex(h) for h in sorted(hashes)]
    tbl = ds.dataset(compiled, format="parquet").to_table(
        columns=["source_hash", "path", "compilation_id"],
        filter=pc.field("source_hash").isin(want))
    comps = defaultdict(set)
    paths = defaultdict(Counter)
    for h, p, c in zip(tbl["source_hash"].to_pylist(),
                       tbl["path"].to_pylist(),
                       tbl["compilation_id"].to_pylist()):
        hx = bytes(h).hex()
        comps[hx].add(c)
        paths[hx][p] += 1
    return {h: (len(comps[h]), [p for p, _ in paths[h].most_common()])
            for h in comps}


def enrich(header, rows, compiled, col):
    """Append ENRICH_COLS, resolving the source hash found in `col`."""
    if col:
        if col not in header:
            sys.exit(f"No column {col!r}; have: {', '.join(header)}")
    else:
        cands = [c for c in header if c.endswith("_file") or c == "del_file"]
        if not cands:
            sys.exit("No *_file column to take a source hash from; use --enrich-col")
        col = cands[0]
    i = header.index(col)

    found = {}
    for r in rows:
        m = HASH.search(r[i])
        if m:
            found[m.group(1)] = None
    if not found:
        sys.exit(f"No 64-hex source hash in column {col!r}")
    print(f"resolving {len(found)} source hash(es) against {compiled} ...",
          file=sys.stderr, flush=True)
    meta = lookup(found, compiled)
    miss = len(found) - len(meta)
    if miss:
        print(f"  {miss} hash(es) not in the compiled dataset", file=sys.stderr)

    out = []
    for r in rows:
        m = HASH.search(r[i])
        n, ps = meta.get(m.group(1), (0, [])) if m else (0, [])
        out.append(list(r) + [n, len(ps), ps[0] if ps else ""])
    return header + ENRICH_COLS, out, meta


def resolve(path, name):
    if os.path.isfile(path):
        return path
    sets = sorted(f for f in os.listdir(path) if f.endswith(".csv"))
    if not sets:
        sys.exit(f"No merged .csv in {path} — run merge_results.py first")
    if name:
        hits = ([f for f in sets if f[:-4] == name] or
                [f for f in sets if f[:-4].split("__")[-1] == name] or
                [f for f in sets if name in f])
        if len(hits) != 1:
            sys.exit(f"{'No' if not hits else 'Ambiguous'} set {name!r}; have:\n  " +
                     "\n  ".join(s[:-4] for s in sets))
        return os.path.join(path, hits[0])
    print("Available sets:")
    for s in sets:
        p = os.path.join(path, s)
        with open(p) as fh:
            n = sum(1 for _ in fh) - 1
        print(f"  {s[:-4]:<55} {n:>9} rows  ({os.path.getsize(p)/1e6:.1f} MB)")
    sys.exit(0)


def make_filter(exprs, header):
    tests = []
    for e in exprs:
        m = re.match(r"^([^=!~]+)(!=|=|~)(.*)$", e)
        if not m:
            sys.exit(f"Bad -w {e!r}; use COL=VAL, COL!=VAL or COL~REGEX")
        col, op, val = m.group(1).strip(), m.group(2), m.group(3)
        if col not in header:
            sys.exit(f"No column {col!r}; have: {', '.join(header)}")
        i = header.index(col)
        if op == "~":
            rx = re.compile(val)
            tests.append(lambda r, i=i, rx=rx: bool(rx.search(r[i])))
        elif op == "=":
            tests.append(lambda r, i=i, v=val: r[i] == v)
        else:
            tests.append(lambda r, i=i, v=val: r[i] != v)
    return lambda r: all(t(r) for t in tests)


def sortkey(v):
    try:
        return (0, float(v), "")
    except ValueError:
        return (1, 0.0, v)


def render(header, rows, maxw, total, shown_all):
    if not rows:
        print("(no rows)")
        return
    cells = [[str(c) for c in r] for r in rows]
    for r in cells:
        for i, c in enumerate(r):
            if len(c) > maxw:
                r[i] = c[:maxw - 1] + "…"
    w = [min(maxw, max(len(header[i]), *(len(r[i]) for r in cells)))
         for i in range(len(header))]
    num = [all(sortkey(r[i])[0] == 0 and r[i] != "" for r in cells)
           for i in range(len(header))]
    def line(vals):
        return "  ".join(v.rjust(w[i]) if num[i] else v.ljust(w[i])
                         for i, v in enumerate(vals))
    print(line(header))
    print("  ".join("-" * x for x in w))
    for r in cells:
        print(line(r))
    print(f"\n{len(rows)} of {total} row(s)" + ("" if shown_all else ", truncated"))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", help="merged dir, or a single merged .csv")
    ap.add_argument("set", nargs="?", help="set name (substring ok)")
    ap.add_argument("-c", "--cols", help="comma-separated columns to show")
    ap.add_argument("-w", "--where", action="append", default=[],
                    help="COL=VAL, COL!=VAL or COL~REGEX; repeatable")
    ap.add_argument("-g", "--group-by", help="count rows per group instead")
    ap.add_argument("-s", "--sort", help="column to sort by")
    ap.add_argument("-r", "--desc", action="store_true")
    ap.add_argument("-n", "--limit", type=int, default=40, help="0 for all")
    ap.add_argument("-e", "--enrich", action="store_true",
                    help="add compilation reuse counts and paths (displayed rows only)")
    ap.add_argument("--enrich-col", help="column holding the source hash "
                                         "(default: the first *_file column)")
    ap.add_argument("--compiled", default=os.path.join(HERE, "compiled_contracts_sources"),
                    help="Sourcify compiled_contracts_sources parquet dir")
    ap.add_argument("--max-enrich", type=int, default=500,
                    help="refuse to resolve more hashes than this")
    ap.add_argument("--max-width", type=int, default=48)
    ap.add_argument("--csv", action="store_true", help="emit csv, not a table")
    args = ap.parse_args()

    path = os.path.abspath(args.path)
    if args.enrich and not args.set and os.path.isdir(path):
        sys.exit("-e needs a set: ./show_results.py <dir> <SET> -e "
                 "(run without -e to list the sets)")
    path = resolve(path, args.set)
    with open(path, newline="") as fh:
        rd = csv.reader(fh)
        header = next(rd)
        keep = make_filter(args.where, header)

        if args.group_by:
            gcols = [c.strip() for c in args.group_by.split(",")]
            bad = [c for c in gcols if c not in header]
            if bad:
                sys.exit(f"No column(s) {bad}; have: {', '.join(header)}")
            idx = [header.index(c) for c in gcols]
            counts = Counter()
            total = 0
            for r in rd:
                if keep(r):
                    total += 1
                    counts[tuple(r[i] for i in idx)] += 1
            header = gcols + ["n"]
            rows = [list(k) + [n] for k, n in counts.most_common()]
            total = len(rows)
        else:
            rows, total = [], 0
            cap = args.limit if (args.limit and not args.sort) else 0
            for r in rd:
                if not keep(r):
                    continue
                total += 1
                if not cap or len(rows) < cap:
                    rows.append(r)

    if args.sort:
        if args.sort not in header:
            sys.exit(f"No column {args.sort!r}; have: {', '.join(header)}")
        i = header.index(args.sort)
        rows.sort(key=lambda r: sortkey(r[i]), reverse=args.desc)
    elif args.group_by and args.desc:
        rows.reverse()

    shown_all = True
    if args.limit and len(rows) > args.limit:
        rows, shown_all = rows[:args.limit], False

    meta = None
    if args.enrich:
        if not os.path.isdir(args.compiled):
            sys.exit(f"No such parquet dir: {args.compiled}\n"
                     f"Get it with ./download_parquet.py compiled_contracts_sources")
        if len(rows) > args.max_enrich:
            sys.exit(f"{len(rows)} rows to resolve; filter with -w/-n first "
                     f"or raise --max-enrich")
        header, rows, meta = enrich(header, rows, args.compiled, args.enrich_col)

    if args.cols:
        want = [c.strip() for c in args.cols.split(",")]
        bad = [c for c in want if c not in header]
        if bad:
            sys.exit(f"No column(s) {bad}; have: {', '.join(header)}")
        idx = [header.index(c) for c in want]
        header = want
        rows = [[r[i] for i in idx] for r in rows]

    if args.csv:
        w = csv.writer(sys.stdout)
        w.writerow(header)
        w.writerows(rows)
    else:
        render(header, rows, args.max_width, total, shown_all)
        if meta:
            print()
            for h, (n, ps) in sorted(meta.items(), key=lambda kv: -kv[1][0]):
                print(f"{h[:16]}…  {n} compilation(s), {len(ps)} path(s)")
                for p in ps[:8]:
                    print(f"    {p}")
                if len(ps) > 8:
                    print(f"    … {len(ps) - 8} more")


if __name__ == "__main__":
    sys.exit(main())
