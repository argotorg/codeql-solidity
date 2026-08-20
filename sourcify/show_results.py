#!/usr/bin/env python3
"""Show a merged result set from merge_results.py as a terminal table.

Usage: ./show_results.py <merged-dir|csv> [SET] [-c COLS] [-w COL=VAL]...
                         [-g COLS] [-s COL] [-r] [-n N] [--csv]

With a directory and no SET, lists what is available. -w takes COL=VAL,
COL!=VAL or COL~REGEX. -g counts rows per group instead of listing them.
"""
import argparse
import csv
import os
import re
import sys
from collections import Counter

csv.field_size_limit(1 << 24)


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
    ap.add_argument("--max-width", type=int, default=48)
    ap.add_argument("--csv", action="store_true", help="emit csv, not a table")
    args = ap.parse_args()

    path = resolve(os.path.abspath(args.path), args.set)
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

    if args.cols:
        want = [c.strip() for c in args.cols.split(",")]
        bad = [c for c in want if c not in header]
        if bad:
            sys.exit(f"No column(s) {bad}; have: {', '.join(header)}")
        idx = [header.index(c) for c in want]
        header = want
        rows = [[r[i] for i in idx] for r in rows]

    shown_all = True
    if args.limit and len(rows) > args.limit:
        rows, shown_all = rows[:args.limit], False

    if args.csv:
        w = csv.writer(sys.stdout)
        w.writerow(header)
        w.writerows(rows)
    else:
        render(header, rows, args.max_width, total, shown_all)


if __name__ == "__main__":
    sys.exit(main())
