#!/usr/bin/env python3
"""Merge the per-shard JSON written by query_dbs.py into one file per result set.

Usage: ./merge_results.py <out-dir> [-o merged-dir] [--format csv|jsonl|both]
                          [--sum SET]... [-q QUERY]... [--full-paths]

Reads <out-dir>/<shard>/<query>.json and writes
<merged>/<query>__<set>.csv (and/or .jsonl), streaming one shard at a time.
Entity columns are flattened to <col>, <col>_file, <col>_line. A leading
`shard` column records which database each row came from.
"""
import argparse
import csv
import json
import os
import sys
from collections import defaultdict

NUMERIC = {"Integer", "Float"}


def scalar(v):
    """csv.writer would render Python bools as True/False, not true/false."""
    return {True: "true", False: "false"}.get(v, v) if isinstance(v, bool) else v


def flatten_columns(columns, keep_path):
    """Header names for one result set, expanding Entity columns to three."""
    out = []
    for c in columns:
        out.append(c["name"])
        if c["kind"] == "Entity":
            out += [c["name"] + "_file", c["name"] + "_line"]
    return out


def flatten_row(tuple_, columns, shard, keep_path):
    row = [shard]
    for val, col in zip(tuple_, columns):
        if col["kind"] != "Entity":
            row.append(scalar(val))
            continue
        if not isinstance(val, dict):
            row += [val, "", ""]
            continue
        url = val.get("url") or {}
        uri = url.get("uri", "")
        if uri.startswith("file://"):
            uri = uri[7:]
        if not keep_path and "/corpus/" in uri:
            uri = uri.split("/corpus/", 1)[1]
        row += [val.get("label", ""), uri, url.get("startLine", "")]
    return row


def shard_files(outdir, wanted):
    """(shard, query, path) for every per-shard result file, in shard order."""
    for shard in sorted(d for d in os.listdir(outdir)
                        if os.path.isdir(os.path.join(outdir, d))
                        and not d.startswith("_")):
        sd = os.path.join(outdir, shard)
        for f in sorted(os.listdir(sd)):
            if f.endswith(".json") and (not wanted or f[:-5] in wanted):
                yield shard, f[:-5], os.path.join(sd, f)


class SetWriter:
    """Appends rows for one (query, result set) to csv and/or jsonl."""

    def __init__(self, merged, query, name, columns, fmt, keep_path):
        self.header = ["shard"] + flatten_columns(columns, keep_path)
        self.columns = columns
        self.rows = 0
        base = os.path.join(merged, f"{query}__{name}")
        self.csv = self.jsonl = None
        if fmt in ("csv", "both"):
            self.csv_fh = open(base + ".csv", "w", newline="")
            self.csv = csv.writer(self.csv_fh)
            self.csv.writerow(self.header)
        if fmt in ("jsonl", "both"):
            self.jsonl = open(base + ".jsonl", "w")

    def write(self, row):
        self.rows += 1
        if self.csv:
            self.csv.writerow(row)
        if self.jsonl:
            self.jsonl.write(json.dumps(dict(zip(self.header, row))) + "\n")

    def close(self):
        if self.csv:
            self.csv_fh.close()
        if self.jsonl:
            self.jsonl.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir")
    ap.add_argument("-o", "--merged", help="default: <out-dir>/_merged")
    ap.add_argument("--format", choices=["csv", "jsonl", "both"], default="csv")
    ap.add_argument("--sum", action="append", default=None, metavar="SET",
                    help="aggregate this set instead of concatenating, summing "
                         "its numeric columns (default: stats)")
    ap.add_argument("-q", "--query", action="append", default=[],
                    help="only merge this query's files; repeatable")
    ap.add_argument("--full-paths", action="store_true",
                    help="keep absolute source paths, not corpus-relative")
    args = ap.parse_args()

    outdir = os.path.abspath(args.outdir)
    merged = os.path.abspath(args.merged or os.path.join(outdir, "_merged"))
    summed = set(args.sum if args.sum is not None else ["stats"])
    wanted = {os.path.basename(q)[:-3] if q.endswith(".ql") else q
              for q in args.query}
    os.makedirs(merged, exist_ok=True)

    files = list(shard_files(outdir, wanted))
    if not files:
        sys.exit(f"No per-shard .json under {outdir}")
    print(f"{len(files)} shard file(s) -> {merged}", flush=True)

    writers = {}                      # (query, set) -> SetWriter
    totals = defaultdict(lambda: defaultdict(int))   # (query, set) -> key -> sums
    keycols = {}
    empty = skipped = 0

    for n, (shard, query, path) in enumerate(files, 1):
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (OSError, ValueError) as e:
            print(f"  {shard}/{query}: unreadable ({e})", file=sys.stderr)
            skipped += 1
            continue
        for name, rs in data.items():
            cols, tuples = rs.get("columns", []), rs.get("tuples", [])
            if not tuples:
                empty += 1
            if name in summed:
                num = [i for i, c in enumerate(cols) if c["kind"] in NUMERIC]
                key = [i for i in range(len(cols)) if i not in num]
                keycols[(query, name)] = ([cols[i]["name"] for i in key],
                                          [cols[i]["name"] for i in num])
                for t in tuples:
                    k = tuple(t[i] for i in key)
                    acc = totals[(query, name)]
                    for j, i in enumerate(num):
                        acc[k + (j,)] += t[i]
                continue
            w = writers.get((query, name))
            if w is None:
                w = writers[(query, name)] = SetWriter(
                    merged, query, name, cols, args.format, args.full_paths)
            for t in tuples:
                w.write(flatten_row(t, cols, shard, args.full_paths))
        if n % 32 == 0 or n == len(files):
            print(f"  [{n}/{len(files)}] {shard}", flush=True)

    for (query, name), w in sorted(writers.items()):
        w.close()
        print(f"{query}__{name}: {w.rows} rows")

    for (query, name), acc in sorted(totals.items()):
        kn, nn = keycols[(query, name)]
        path = os.path.join(merged, f"{query}__{name}.csv")
        with open(path, "w", newline="") as fh:
            wr = csv.writer(fh)
            wr.writerow(kn + nn)
            keys = sorted({k[:-1] for k in acc})
            for k in keys:
                wr.writerow(list(k) + [acc[k + (j,)] for j in range(len(nn))])
        print(f"{query}__{name}: {len(keys)} rows (summed across shards)")

    if empty:
        print(f"({empty} empty per-shard result set(s))")
    if skipped:
        print(f"{skipped} file(s) skipped", file=sys.stderr)
    return 1 if skipped else 0


if __name__ == "__main__":
    sys.exit(main())
