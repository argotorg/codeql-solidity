#!/usr/bin/env bash
# Autobuild script for Solidity extractor
# This script is called by CodeQL to extract Solidity files

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Determine platform
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        PLATFORM="darwin-arm64"
        ;;
    Darwin-x86_64)
        PLATFORM="darwin-x64"
        ;;
    Linux-x86_64)
        PLATFORM="linux64"
        ;;
    Linux-aarch64)
        PLATFORM="linux-arm64"
        ;;
    *)
        echo "Unsupported platform: $(uname -s)-$(uname -m)"
        exit 1
        ;;
esac

EXTRACTOR="$SCRIPT_DIR/$PLATFORM/extractor"

if [ ! -x "$EXTRACTOR" ]; then
    echo "Extractor not found: $EXTRACTOR"
    exit 1
fi

# Find all .sol files
SOURCE_ROOT="${LGTM_SRC:-.}"

# Create file list
FILE_LIST=$(mktemp)
find "$SOURCE_ROOT" -name "*.sol" -type f > "$FILE_LIST"

if [ ! -s "$FILE_LIST" ]; then
    echo "No Solidity files found in $SOURCE_ROOT"
    rm "$FILE_LIST"
    exit 0
fi

# Set up directories
TRAP_DIR="${CODEQL_EXTRACTOR_SOLIDITY_TRAP_DIR:-trap}"
SRC_ARCHIVE="${CODEQL_EXTRACTOR_SOLIDITY_SOURCE_ARCHIVE_DIR:-src-archive}"

mkdir -p "$TRAP_DIR" "$SRC_ARCHIVE"

# CodeQL passes -j through as this; it also allows 0 (all cores) and -N
# (leave N free), neither of which the extractor's usize --threads accepts.
THREAD_ARGS=()
if [[ "${CODEQL_EXTRACTOR_SOLIDITY_THREADS:-0}" =~ ^[0-9]+$ ]] \
   && [ "${CODEQL_EXTRACTOR_SOLIDITY_THREADS:-0}" -gt 0 ]; then
    THREAD_ARGS=(--threads "$CODEQL_EXTRACTOR_SOLIDITY_THREADS")
fi

# Run extractor
"$EXTRACTOR" extract \
    --file-list "$FILE_LIST" \
    --trap-dir "$TRAP_DIR" \
    --source-archive-dir "$SRC_ARCHIVE" \
    "${THREAD_ARGS[@]}"

rm "$FILE_LIST"
echo "Extraction complete"
