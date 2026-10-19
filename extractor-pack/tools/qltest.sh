#!/usr/bin/env bash
# Extraction for `codeql test run`: indexes the test directory's .sol files.
set -eu
exec "${CODEQL_DIST}/codeql" database index-files \
    --prune="**/*.testproj" \
    --include-extension=.sol \
    --size-limit=5m \
    --language=solidity \
    --working-dir=. \
    "$CODEQL_EXTRACTOR_SOLIDITY_WIP_DATABASE"
