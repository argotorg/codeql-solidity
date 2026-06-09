#!/usr/bin/env python3
"""Download parquet shards of a Sourcify export dataset.

Reads the real bucket listing (https://export.sourcify.dev/?prefix=v2/<dataset>/)
rather than guessing range numbers, so it only ever requests files that exist,
in numeric order, and stops at whatever is available.

Datasets (see the listing for the full set):
  compiled_contracts_sources  compilation_id -> source_hash, path  (step 1000000)
  sources                     source_hash -> content               (step 10000)
  code                        creation/runtime bytecode            (step 100000)

Files are named <dataset>_<start>_<end>.parquet and downloaded into <outdir>
(default: a subdir named after the dataset). Downloads are resumable (HTTP Range
into a .part file, renamed on completion), skip files already present, and retry
transient network errors.

Examples:
  ./download_parquet.py                          # first 100 compiled_contracts_sources
  ./download_parquet.py sources                  # first 100 sources shards -> sources/
  ./download_parquet.py sources -n 519           # all sources shards
  ./download_parquet.py sources --list-only      # show what would be downloaded
  ./download_parquet.py code -n 10 -o /data/code # first 10 code shards into /data/code
"""
import argparse
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

DEFAULT_HOST = "https://export.sourcify.dev"


def human(n):
    """Human-readable byte count."""
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}B"
        n /= 1024


def _local(tag):
    """Strip an XML namespace from a tag name."""
    return tag.rsplit("}", 1)[-1]


def list_keys(host, prefix):
    """Page through the S3-style bucket listing, returning every parquet Key."""
    keys = []
    marker = ""
    while True:
        url = f"{host}/?prefix={prefix}&max-keys=1000"
        if marker:
            url += f"&marker={urllib.parse.quote(marker)}"
        with urllib.request.urlopen(url, timeout=60) as resp:
            body = resp.read()
        root = ET.fromstring(body)
        page = []
        truncated = False
        next_marker = None
        for el in root:
            tag = _local(el.tag)
            if tag == "Contents":
                for child in el:
                    if _local(child.tag) == "Key" and child.text and child.text.endswith(".parquet"):
                        page.append(child.text)
            elif tag == "IsTruncated":
                truncated = (el.text or "").strip().lower() == "true"
            elif tag == "NextMarker":
                next_marker = el.text
        keys.extend(page)
        if truncated and page:
            marker = next_marker or page[-1]
        else:
            break
    return keys


def shard_start(key, dataset):
    """Numeric start range from a key like .../<dataset>_<start>_<end>.parquet."""
    base = key.rsplit("/", 1)[-1]
    m = re.match(rf"{re.escape(dataset)}_(\d+)_\d+\.parquet$", base)
    return int(m.group(1)) if m else float("inf")


def download(url, out, retries, retry_delay):
    """Stream `url` to `out`, resuming a partial .part file, with retries.

    Returns True on success, False after exhausting retries.
    """
    part = out + ".part"
    for attempt in range(1, retries + 1):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        req = urllib.request.Request(url)
        if have:
            req.add_header("Range", f"bytes={have}-")
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                # If the server ignored Range (status 200), restart from scratch.
                if have and resp.status == 200:
                    have = 0
                mode = "ab" if have else "wb"
                total = None
                clen = resp.headers.get("Content-Length")
                if clen is not None:
                    total = have + int(clen)
                with open(part, mode) as f:
                    done = have
                    last = 0.0
                    while True:
                        chunk = resp.read(1 << 20)  # 1 MiB
                        if not chunk:
                            break
                        f.write(chunk)
                        done += len(chunk)
                        now = time.monotonic()
                        if now - last > 0.2:
                            last = now
                            if total:
                                pct = 100.0 * done / total
                                sys.stdout.write(
                                    f"\r    {human(done)}/{human(total)} ({pct:.0f}%)   ")
                            else:
                                sys.stdout.write(f"\r    {human(done)}   ")
                            sys.stdout.flush()
            sys.stdout.write("\r" + " " * 40 + "\r")
            sys.stdout.flush()
            os.replace(part, out)
            return True
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ConnectionError) as e:
            # A 416 means the .part is already complete (or stale) — drop it and retry.
            if isinstance(e, urllib.error.HTTPError) and e.code == 416:
                if os.path.exists(part):
                    os.remove(part)
            code = getattr(e, "code", None)
            if code in (403, 404):  # not retryable
                sys.stdout.write("\r")
                print(f"    HTTP {code}: {url}", file=sys.stderr)
                return False
            if attempt < retries:
                sys.stdout.write("\r")
                print(f"    attempt {attempt}/{retries} failed ({e}); retrying...",
                      file=sys.stderr)
                time.sleep(retry_delay)
            else:
                print(f"    giving up after {retries} attempts: {e}", file=sys.stderr)
                return False
    return False


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dataset", nargs="?", default="compiled_contracts_sources",
                    help="dataset name (default: %(default)s)")
    ap.add_argument("-n", "--count", type=int, default=100,
                    help="number of shards to download (default: %(default)s)")
    ap.add_argument("-o", "--outdir", default=None,
                    help="output directory (default: a subdir named after the dataset)")
    ap.add_argument("--host", default=DEFAULT_HOST,
                    help="export host (default: %(default)s)")
    ap.add_argument("--prefix", default=None,
                    help="bucket key prefix (default: v2/<dataset>/)")
    ap.add_argument("--retries", type=int, default=5,
                    help="retries per file on transient errors (default: %(default)s)")
    ap.add_argument("--retry-delay", type=float, default=2.0,
                    help="seconds between retries (default: %(default)s)")
    ap.add_argument("--list-only", action="store_true",
                    help="list the shards that would be downloaded, then exit")
    args = ap.parse_args()

    outdir = args.outdir or args.dataset
    prefix = args.prefix or f"v2/{args.dataset}/"

    print(f"Listing {args.host}/{prefix} ...")
    try:
        keys = list_keys(args.host, prefix)
    except (urllib.error.URLError, ET.ParseError) as e:
        sys.exit(f"Failed to list {prefix}: {e}")
    if not keys:
        sys.exit(f"No parquet files found under {prefix}")

    keys.sort(key=lambda k: shard_start(k, args.dataset))
    want = min(args.count, len(keys))
    selected = keys[:want]
    print(f"Found {len(keys)} shard(s); selecting first {want}.")

    if args.list_only:
        for k in selected:
            print(f"  {args.host}/{k}")
        return

    os.makedirs(outdir, exist_ok=True)
    ok = skip = fail = 0
    for i, key in enumerate(selected, 1):
        fname = key.rsplit("/", 1)[-1]
        out = os.path.join(outdir, fname)
        url = f"{args.host}/{key}"
        if os.path.exists(out) and os.path.getsize(out) > 0:
            print(f"[{i}/{want}] skip (exists): {fname}")
            skip += 1
            continue
        print(f"[{i}/{want}] {url}")
        if download(url, out, args.retries, args.retry_delay):
            ok += 1
        else:
            fail += 1

    print(f"Done: {ok} downloaded, {skip} already present, {fail} failed.")
    if fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
