# Compilation scoping plan

## Phase 1: compilation membership in the database

### Problem

The shard databases are built from `extract_all_sources.py` output: one deduplicated
source file per unique content hash, laid out `<xx>/<yy>/<hash>__<name>.sol`. The
per-compilation grouping is discarded.

A database therefore has no representation of which files belong together. Any query
that needs cross-file structure — a contract's bases, an import's target, a name
declared elsewhere in the same project — has no correct answer available. The only
sound scope is the single file.

Resolving names across a shard instead is both wrong and expensive: thousands of
unrelated declarations share names (`Ownable`, `Context`, `IERC20`), so name matching
fuses unrelated projects into one graph, and any transitive closure over that graph
grows with the square of the per-name declaration count.

Measured over the full Sourcify parquet set:

| | |
|---|---|
| compilations | 5,606,252 |
| (compilation, path) rows | 35,797,605 |
| unique sources (what is indexed today) | 6,223,392 |
| single-file compilations | 64.5% of compilations, 10.1% of paths |
| multi-file compilations | 1,989,224 — 32,180,577 paths |

Single-file compilations are unaffected: same-file resolution is already correct for
them. The limitation applies to the multi-file 35.5%, which holds 90% of all paths.

### Design

Shard by compilation id. Within a shard, store each unique source once. Record the
grouping in a manifest rather than in the directory layout:

```
<shard>/sources/<hash>__<name>.sol      deduplicated within the shard
<shard>/manifest                        (compilation_id, path) -> source_hash
```

The extractor reads the manifest and emits one table:

```
solidity_compilation_member(file, compilation, path)
```

Queries get `sameCompilation(f1, f2)`, and name resolution becomes "a declaration of
that name in a file sharing a compilation with me". Scope is then tens of files rather
than tens of thousands, and it is the scope the compiler actually used.

The AST — the expensive part — stays deduplicated. Only the membership rows are
duplicated, and they are flat integer tuples.

### Cost

Space scales with how many shards a source must be stored in. Expected sources stored,
for compilations assigned to shards at random:

| shards | sources stored | vs today | files per DB |
|---|---|---|---|
| 16 | 10,040,403 | 1.6× | 628k |
| 64 | 12,404,570 | 2.0× | 194k |
| 256 | 14,733,929 | 2.4× | 58k |
| 1024 | 17,190,284 | 2.8× | 17k |

Random assignment is the worst case; co-locating compilations that share
mid-frequency sources would reduce the duplication. Not required for a first build.

Disk, extrapolated from a 8,798-file sample (10.8 KB mean source, relations ≈ 3.2×
source bytes, `src.zip` ≈ 0.23×):

| | source | relations | src.zip | total |
|---|---|---|---|---|
| today (6.2M) | 67 GB | 215 GB | 15 GB | ~230 GB |
| 64 shards (12.4M) | 134 GB | 429 GB | 31 GB | ~460 GB |
| 256 shards (14.7M) | 159 GB | 509 GB | 37 GB | ~545 GB |

CPU scales with the same factor: a build that currently takes ~10 h becomes ~20 h at
64 shards, ~24 h at 256.

Query CPU per shard is unchanged relative to shard size — a source shared by a
thousand compilations is still analysed once, so the deduplication property of the
current corpus is preserved.

Note: query evaluation caches accumulate under `<db>/db-solidity/default/cache` and are
not part of the build output. They can reach several GB per database and are reclaimed
by `codeql database cleanup`.

### Work items

- [ ] Manifest format and corpus builder: shard by `compilation_id[:2]`, dedup sources
      within shard, emit manifest. Path sanitisation already exists in
      `extract_compilation.py` — lift it into a shared helper.
- [ ] Extractor: manifest flag, `solidity_compilation_member` table in
      `extractor/src/schema/mod.rs`, populated alongside the existing
      `solidity_declaration` / `solidity_type_info` side tables.
- [ ] Regenerate `solidity.dbscheme` and `TreeSitter.qll` via `setup-extractor`;
      install both extractor binary copies.
- [ ] `ql/lib`: `Compilation` class, `sameCompilation`, name resolution built on it.
- [ ] Build one shard first and check per-DB size, build time, and membership row
      counts against the manifest before committing to the full set.
- [ ] Add `--timeout` to `query_dbs.py` so one pathological shard cannot hold a worker
      indefinitely.

## Phase 2

`solidity_import`, `solidity_contract_base`, `solidity_linearization` — extractor
passes over the same manifest and layout. No corpus rebuild required.
