# CodeQL Solidity

This project lets you query Solidity smart contracts with CodeQL. A Rust
extractor parses `.sol` files with tree-sitter into a CodeQL database — no
`solc`, no `npm`, no build system, just source text — and a QL library on top of
it exposes the AST, the call graph, inheritance, and taint tracking, so you can
write declarative queries that find bugs and vulnerability patterns across a
whole corpus of contracts at once.

Originally by @lucasamorimca, see https://github.com/lucasamorimca/codeql-solidity

[![Test](https://github.com/argotorg/codeql-solidity/actions/workflows/test.yml/badge.svg)](https://github.com/argotorg/codeql-solidity/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

## Setup

The only prerequisite is [Nix](https://nixos.org/download/) with flakes
enabled. Then:

```bash
git clone https://github.com/argotorg/codeql-solidity.git
cd codeql-solidity
nix develop
setup-extractor    # build the binary, generate the dbscheme & QL library
```

`setup-extractor` produces the gitignored build artifacts — the extractor binary
in `extractor-pack/tools/`, plus `solidity.dbscheme` and `TreeSitter.qll` — so
re-run it after touching the extractor or the grammar.

## Extract the sources into a database

```bash
codeql database create tests-db --language=solidity \
    --source-root=tests --search-path="$PWD" --overwrite
codeql dataset measure -j8 \
    -o tests-db/db-solidity/solidity.dbscheme.stats tests-db/db-solidity
```

Walks every `.sol` file under `--source-root` and runs the extractor over it,
writing `tests-db/`: the relational database (one table per AST node kind, per
`solidity.dbscheme`) plus a copy of the sources so results can point back at
lines.

## Run a query

Queries under `queries/analysis/` are **table queries**:

```bash
$ codeql query run queries/analysis/ReentrancyPatterns.ql \
    --database=tests-db --additional-packs="$PWD" --output=r.bqrs
$ codeql bqrs decode --format=text --result-set=externalCalls r.bqrs
|          contract           |        function         |   callType   | guarded |      node      |
+-----------------------------+-------------------------+--------------+---------+----------------+
| ReentrancyVulnerable        | withdraw                | call         | false   | CallExpression |
| ReentrancyTransfer          | withdraw                | transfer     | false   | CallExpression |
| ReentrancySend              | withdraw                | transfer     | false   | CallExpression |
...
```

The argument `--format=csv` writes the same table as CSV. For downstream tooling, decode to
JSON and ask for source spans:

```bash
$ codeql bqrs decode --format=json --entities=url,string \
    --result-set=externalCalls r.bqrs > externalCalls.json
```

Then you get:

```json
{
  "columns": [
    { "name": "contract", "kind": "String" },
    { "name": "function", "kind": "String" },
    { "name": "callType", "kind": "String" },
    { "name": "guarded",  "kind": "Boolean" },
    { "name": "node",     "kind": "Entity" }
  ],
  "tuples": [
    ["ReentrancyVulnerable", "withdraw", "call", false, {
      "label": "CallExpression",
      "url": {
        "uri": "file:///home/you/codeql-solidity/tests/fixtures/ReentrancyTest.sol",
        "startLine": 16, "startColumn": 28, "endLine": 16, "endColumn": 62
      }
    }]
  ]
}
```

## Example Queries

All queries live in [`queries/analysis/`](queries/analysis/).

| Query                            | Reports                                                  |
|----------------------------------|----------------------------------------------------------|
| `AssemblyAnalysis.ql`            | inline assembly blocks and what they touch                |
| `AssertInProductionCode.ql`      | `assert` outside test/fuzzing paths                       |
| `CallGraph.ql`                   | caller → callee edges, with the resolution kind           |
| `CalleeKinds.ql`                 | every call expression by callee kind                      |
| `DataFlowAnalysis.ql`            | taint from sources to sinks                               |
| `DeFiPatterns.ql`                | swap, oracle, and liquidity patterns                      |
| `ERCCompliance.ql`               | missing or mis-typed ERC-20/721 members                   |
| `EventPatterns.ql`               | events declared and emitted                               |
| `ExternalCallGraph.ql`           | calls that leave the contract                             |
| `ExternalCallsAnalysis.ql`       | external call sites with their value/gas modifiers        |
| `FunctionList.ql`                | every function with visibility, mutability, state access  |
| `InheritanceAnalysis.ql`         | inheritance edges and overrides                           |
| `ProxyPatterns.ql`               | `delegatecall` proxies and implementation slots           |
| `ReentrancyPatterns.ql`          | external call before the state update (CEI), 3 variants   |
| `RequireWithoutReason.ql`        | `require()` with no reason string                         |
| `StorageLayout.ql`               | state variables in declaration order                      |
| `TokenPatterns.ql`               | mint, burn, transfer, and allowance patterns              |
| `UnresolvedCalls.ql`             | calls whose target could not be resolved                  |


## Limitation: inline assembly

Control flow is modelled for Solidity bodies but not for Yul: on the `tests/`
corpus 579 of 601 function entries reach their exit, and the ~22 that do not
are assembly-heavy, with Yul nodes largely disconnected from the graph.
Anything a query concludes about code inside `assembly { … }` — reachability,
ordering, taint — is unreliable, so `AssemblyAnalysis.ql` reports assembly
blocks and their opcodes as plain facts rather than reasoning about them.

## Running against Sourcify dataset

[Sourcify](https://docs.sourcify.dev/docs/repository/download-dataset/) publishes
every verified contract as parquet shards, in two datasets that join on a hash:

```bash
cd sourcify
./download_parquet.py sources -n 632                     # hash -> content (17.4 GB)
./download_parquet.py compiled_contracts_sources -n 26   # id -> hash, path (1.4 GB)
```

Downloads are resumable and skip what's already there. `-n` caps shards,
`--list-only` dry-runs.

### One compilation

`extract_compilation.py` takes a `compilation_id` prefix, joins the two datasets
and reproduces that compilation's original directory layout:

```bash
./extract_compilation.py e4    # -> extracted/<compilation_id>/<path>
```

It holds the content of everything it matches in memory, so it suits a slice, not
the whole dataset. A longer prefix extracts fewer compilations.

### The whole corpus

`extract_all_sources.py` streams the sources shards and writes each *unique*
content once, so memory stays flat and no join is needed — the
`compiled_contracts_sources` download is optional:

```bash
./extract_all_sources.py -o ../corpus          # -> <xx>/<yy>/<hash>.sol
```

The 25.2M per-compilation file instances collapse to 6,301,900 distinct files, and
nothing is lost: this extractor never resolves imports (it parses each file
independently), so the duplicated per-compilation tree buys no analysis fidelity.

|                    | `e4` slice | per-compilation | deduplicated |
|--------------------|-----------:|----------------:|-------------:|
| files              |    101,663 |           25.2M |    6,301,900 |
| content bytes      |     766 MB |         ~270 GB |      103.6 GB |
| actually allocated |    1.38 GB |         ~485 GB |       ~121 GB |

Add `--solidity-only` to drop the ~0.02% of sources that are Vyper or junk; it
needs the compiled shards to know which hashes came from a `.sol` path. Without
it those are written as `.sol` and show up as extractor parse failures. Both
scripts are resumable — re-running skips what exists — and `-j` sets the worker
count.

### Building databases

A database runs several times the size of its sources, so the corpus is built as
one database per `<xx>` subdir rather than a single enormous one:

```bash
./build_dbs.py ../corpus ../dbs -j 8 --ram 8000     # creates 256 DB shards
```

The databases are kept. Building the corpus is the expensive part, and you want
to query it more than once. Each finished shard leaves a `.built` marker and is
skipped on re-run, so an interrupted pass resumes where it stopped.

### Querying them

```bash
./query_dbs.py ../dbs ../results                          # the whole queries/ pack
./query_dbs.py ../dbs ../fnlist -q analysis/FunctionList.ql   # one query
```

Results land in `<out>/<shard>/<query>.json`. Re-run it with a different `-q` as
often as you like — no re-extraction, and CodeQL reuses cached results per
database unless you pass `--rerun`.

### Threads and memory

`-j` is threaded through every stage: extraction, TRAP import, and query
evaluation. CodeQL forwards `database create -j` to the extractor as
`CODEQL_EXTRACTOR_SOLIDITY_THREADS`, which `autobuild.sh` turns into the
extractor's own `--threads`; without it rayon takes every core. Note that
`database create` and `run-queries` both default to a *single* thread when `-j`
is not given. `-w` runs whole shards concurrently, so total threads are roughly
`j * w`.

Memory is the binding constraint, and it scales with shard size and `-j`
together — query evaluation on a 4.4k-file shard at `-j 8` reached ~6 GB
resident. Set `--ram` and keep `-j` modest before reaching for `-w`. The
evaluator also spills to disk inside the database directory, so that filesystem
needs headroom beyond the database itself; putting it on a small tmpfs will fail
with `Disk quota exceeded` mid-query.


## License

Apache-2.0
