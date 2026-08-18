#!/usr/bin/env bash
# CodeQL Solidity Index Files Script
#
# This script is invoked by the CodeQL CLI to extract specific files.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find the extractor binary
if [ -f "$SCRIPT_DIR/codeql-extractor-solidity" ]; then
    EXTRACTOR="$SCRIPT_DIR/codeql-extractor-solidity"
elif [ -f "$SCRIPT_DIR/bin/codeql-extractor-solidity" ]; then
    EXTRACTOR="$SCRIPT_DIR/bin/codeql-extractor-solidity"
else
    echo "Error: Could not find codeql-extractor-solidity binary" >&2
    exit 1
fi

# Run extraction
exec "$EXTRACTOR" extract \
    --file-list "$1" \
    --trap-dir "${CODEQL_EXTRACTOR_SOLIDITY_TRAP_DIR}" \
    --source-archive-dir "${CODEQL_EXTRACTOR_SOLIDITY_SOURCE_ARCHIVE_DIR}"
