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

## Example queries and tests

Create a DB out of the tests:

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

### Run a query against the tests

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

### Example Queries

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
./download_parquet.py compiled_contracts_sources -n 40   # id -> hash, path (1.4 GB)
./extract_all_sources.py -o ../corpus     # -> <xx>/<yy>/<hash>__Ownable.sol
```

Storage and compute needs:

|                    | only one slice (e.g. `e4`) | Total |
|--------------------|-----------:|----------------:|
| files              |    101,663 |           25.2M |
| content bytes      |     766 MB |         ~270 GB |
| actually allocated |    1.38 GB |         ~485 GB |

Both scripts are resumable — re-running skips what exists — and `-j` sets the
worker count.

### Building databases

A database runs several times the size of its sources, so the corpus is built as
one database per `<xx>` subdir rather than a single enormous one:

```bash
./build_dbs.py ../corpus ../dbs -j 8 -w 2 --ram 8000     # creates 256 DB shards
```

We recommend using tmux to run this, as it may take a long while:

| | |
|---|---|
| per shard | ~4.6 min, 1.2 GB |
| 256 shards, sequential | **~20 h** |
| with `-w 2` / `-w 4` | ~10 h / ~5 h |
| databases total | ~400 GB |

`-j` is threads within a shard, `-w` is shards built at once (~10 GB RAM each).

### Run a query on the DBs

```bash
./query_dbs.py ../dbs ../fnlist -q ../queries/analysis/FunctionList.ql
```

Results land in `<out>/<shard>/<query>.json`

### Displaying the results

`merge_results.py` folds the per-shard JSON into one CSV per result set:

```bash
./merge_results.py ../fnlist            # -> ../fnlist/merged/<query>__<set>.csv
```

Then enrich and display:

```bash
./show_results.py ../fnlist/merged NAME -e -c container,callable,ncomp,path
```

`-e` joins the `compiled_contracts_sources` parquet onto the rows being
displayed, adding `ncomp` (how many compilations reuse that source), `npaths`
and `path` — enough to tell project code from a vendored dependency. It runs
after filtering and limiting, so filter first; it refuses more than 50k rows.

### Triaging results

You can fetch the source code of a single contract in order examine it with
`fetch_source.py` It pulls individual sources straight out of the parquet, so
you do not need the extracted corpus on disk:

```bash
./fetch_source.py 05876f4c5b073da2560a3ef8adfb493a3fdb9f9f379e35f888d90b1911c94703
# -> ./05876f4...__HorseSales.sol
```

It takes a bare `source_hash` or anything containing one, so the corpus path or
`file://` URI from a result row can be pasted in unchanged, and it accepts
several at once:

```bash
./fetch_source.py <uri-from-a-result-row> <another-hash> -o /tmp/triage
```

Output filenames match what `extract_all_sources.py` would have written. The
name comes from `compiled_contracts_sources`; without that dataset you still
get the content, as a bare `<hash>.sol`. `--stdout` writes the content instead,
for piping:

```bash
./fetch_source.py <hash> --stdout | solc --ast-compact-json -
```

## Testing

Let's test on e4 slice. Every command needed to go from nothing to query results over the `e4` slice
(18,380 compilations, ~101k `.sol`). Each block assumes whatever is already there
is stale and removes it first.

```bash
rm -rf codeql-solidity
git clone https://github.com/argotorg/codeql-solidity.git
cd codeql-solidity
nix develop                # every command below runs inside this shell
setup-extractor
cd sourcify
rm -rf sources compiled_contracts_sources extracted
./download_parquet.py sources -n 632                     # 17.4 GB
./download_parquet.py compiled_contracts_sources -n 40   # 1.4 GB
./extract_compilation.py e4                              # -> extracted/<compilation_id>/<path>
cd ..
rm -rf dbs/e4
mkdir -p dbs
codeql database create dbs/e4 --language=solidity \
    --source-root=sourcify/extracted --search-path="$PWD" -j 8 --ram 8000
codeql dataset measure -j 8 \
    -o dbs/e4/db-solidity/solidity.dbscheme.stats dbs/e4/db-solidity
```

Query it:

```bash
codeql query run queries/analysis/ReentrancyPatterns.ql \
    --database=dbs/e4 --additional-packs="$PWD" --output=e4.bqrs
codeql bqrs decode --format=csv --result-set=externalCalls e4.bqrs > externalCalls.csv
```

## License

Apache-2.0
