#!/usr/bin/env bash
# Download the PUBLISHED release binary the film is recorded with, and verify it against the release's SHA256SUMS.
# usage: fetch-binary.sh [tag]   (default v3.19.0)  -> .cache/release/LogicProMCP
set -euo pipefail
TAG="${1:-v3.19.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/.cache/release"
mkdir -p "$DEST"
cd "$DEST"
gh release download "$TAG" -R MongLong0214/logic-pro-mcp -p 'LogicProMCP-macOS-universal.tar.gz' -p SHA256SUMS.txt --clobber
grep ' LogicProMCP-macOS-universal.tar.gz$' SHA256SUMS.txt | shasum -a 256 -c -
tar xzf LogicProMCP-macOS-universal.tar.gz
./LogicProMCP --version
