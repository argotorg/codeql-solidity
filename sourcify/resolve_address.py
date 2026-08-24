#!/usr/bin/env python3
"""Resolve a source_hash to the chain and address of contracts built from it.

Usage: ./resolve_address.py <hash|path>... [--verify] [--chain N]
                            [--compiled DIR] [--verified DIR] [--deployments DIR]

Takes a bare 64-hex source_hash or anything containing one, like fetch_source.py,
and walks compiled_contracts_sources -> verified_contracts -> contract_deployments.
--verify re-fetches the sources from Sourcify and checks that one of them hashes
back to the input, so a printed link is proven rather than inferred.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import defaultdict

HASH = re.compile(r"([0-9a-f]{64})")
HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://sourcify.dev/server/v2/contract/{chain}/{address}?fields=sources"
REPO = "https://repo.sourcify.dev/{chain}/{address}/"


def pick(patterns):
    out = []
    for p in patterns:
        if not os.path.isabs(p):
            p = os.path.join(HERE, p)
        out.extend(glob.glob(os.path.join(p, "*.parquet")))
    return sorted(set(out))


def lookup(files, key, want, cols, binary_key=False):
    """Rows of `files` whose `key` is in `want`, as a list of dicts.

    The isin goes into the dataset scan so only matching rows are materialised;
    these tables are billions of rows and will not fit otherwise.
    """
    import pyarrow.compute as pc
    import pyarrow.dataset as ds

    keys = [bytes.fromhex(w) for w in want] if binary_key else list(want)
    tbl = ds.dataset(files, format="parquet").to_table(
        columns=cols, filter=pc.field(key).isin(keys))
    return tbl.to_pylist()


def sourcify_sources(chain, address, timeout=30):
    """The verified source contents Sourcify holds for a contract, or None."""
    url = API.format(chain=chain, address=address)
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            body = json.load(r)
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
        print(f"    verify: cannot reach Sourcify ({e})", file=sys.stderr)
        return None
    srcs = body.get("sources") or {}
    return [v.get("content", "") for v in srcs.values() if isinstance(v, dict)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hashes", nargs="+", metavar="HASH|PATH")
    ap.add_argument("--verify", action="store_true",
                    help="confirm each address really serves the input source")
    ap.add_argument("--chain", type=int, help="only report this chain id")
    ap.add_argument("--compiled", default="compiled_contracts_sources")
    ap.add_argument("--verified", default="verified_contracts")
    ap.add_argument("--deployments", default="contract_deployments")
    args = ap.parse_args()

    wanted = []
    for a in args.hashes:
        m = HASH.search(a.lower())
        if not m:
            sys.exit(f"No 64-hex source hash in: {a}")
        if m.group(1) not in wanted:
            wanted.append(m.group(1))

    for name, d in (("compiled_contracts_sources", args.compiled),
                    ("verified_contracts", args.verified),
                    ("contract_deployments", args.deployments)):
        if not pick([d]):
            sys.exit(f"No parquet in {d}\nDownload it with\n"
                     f"  ./download_parquet.py {name} -n 48")

    print(f"compiled_contracts_sources: {len(wanted)} hash(es) ...", file=sys.stderr)
    rows = lookup(pick([args.compiled]), "source_hash", wanted,
                  ["source_hash", "compilation_id"], binary_key=True)
    comp_to_hash = defaultdict(set)
    for r in rows:
        comp_to_hash[r["compilation_id"]].add(bytes(r["source_hash"]).hex())
    if not comp_to_hash:
        sys.exit("no compilation uses any of those sources")

    print(f"verified_contracts: {len(comp_to_hash)} compilation(s) ...", file=sys.stderr)
    rows = lookup(pick([args.verified]), "compilation_id", comp_to_hash.keys(),
                  ["compilation_id", "deployment_id", "runtime_match", "creation_match"])
    dep_to_meta = {}
    for r in rows:
        dep_to_meta[r["deployment_id"]] = (r["compilation_id"],
                                           r["runtime_match"], r["creation_match"])
    if not dep_to_meta:
        sys.exit("those compilations are not linked to any deployment")

    print(f"contract_deployments: {len(dep_to_meta)} deployment(s) ...", file=sys.stderr)
    rows = lookup(pick([args.deployments]), "id", dep_to_meta.keys(),
                  ["id", "chain_id", "address"])

    found = defaultdict(list)
    for r in rows:
        comp, rt, cr = dep_to_meta[r["id"]]
        for h in comp_to_hash[comp]:
            found[h].append((r["chain_id"], "0x" + bytes(r["address"]).hex(), rt, cr))

    rc = 0
    for h in wanted:
        hits = sorted(set(found.get(h, [])))
        if args.chain is not None:
            hits = [x for x in hits if x[0] == args.chain]
        print(f"\n{h}")
        if not hits:
            print("  no deployment found")
            rc = 1
            continue
        for chain, address, rt, cr in hits:
            match = "runtime" if rt else ""
            match += ("+" if match and cr else "") + ("creation" if cr else "")
            print(f"  chain {chain}  {address}  [{match or 'no match flags'}]")
            print(f"  {REPO.format(chain=chain, address=address)}")
            if args.verify:
                srcs = sourcify_sources(chain, address)
                if srcs is None:
                    rc = 1
                elif any(hashlib.sha256(s.encode()).hexdigest() == h for s in srcs):
                    print(f"    verified: Sourcify serves this exact source")
                else:
                    print(f"    MISMATCH: none of {len(srcs)} source(s) hash to {h[:16]}…")
                    rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
