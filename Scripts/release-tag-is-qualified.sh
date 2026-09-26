#!/bin/bash
#
# Scripts/release-tag-is-qualified.sh — refuse release tags without the live qualification record (#985).
#
# GitHub Actions runners cannot run a permissioned Logic Pro, so the release scripts record the commit they
# qualified locally in the annotated tag. Only the Formula's sha256 line may change after that commit.
# This checks the recorded commit and allowed diff; a forged Live-qualified line is out of scope and belongs to #816.
#
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Error: expected one release tag (#985)." >&2
    exit 1
fi

tag="$1"
tag_ref="refs/tags/$tag"
if [ "$(git cat-file -t "$tag_ref" 2>/dev/null || true)" != "tag" ]; then
    echo "Error: $tag must be an annotated tag (#985)." >&2
    exit 1
fi

if ! message=$(git tag -l --format='%(contents)' "$tag" 2>/dev/null); then
    echo "Error: cannot read the message for $tag (#985)." >&2
    exit 1
fi

qualified=""
matches=0
while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^Live-qualified:\ ([0-9a-f]{40})$ ]]; then
        qualified="${BASH_REMATCH[1]}"
        matches=$((matches + 1))
    fi
done <<< "$message"
if [ "$matches" -ne 1 ]; then
    echo "Error: $tag needs exactly one Live-qualified commit line (#985)." >&2
    exit 1
fi

if ! git cat-file -e "$qualified^{commit}" 2>/dev/null; then
    if ! git fetch --quiet --no-tags --depth=1 origin "$qualified" 2>/dev/null; then
        echo "Error: cannot fetch qualified commit $qualified (#985)." >&2
        exit 1
    fi
    if ! git cat-file -e "$qualified^{commit}" 2>/dev/null; then
        echo "Error: qualified commit $qualified is unavailable (#985)." >&2
        exit 1
    fi
fi

if ! changed=$(git diff --name-only "$qualified" "$tag_ref^{commit}" 2>/dev/null); then
    echo "Error: cannot compare $tag with qualified commit $qualified (#985)." >&2
    exit 1
fi
if [ -n "$changed" ] && [ "$changed" != "Formula/logic-pro-mcp.rb" ]; then
    echo "Error: $tag changes files beyond Formula/logic-pro-mcp.rb after qualification (#985)." >&2
    exit 1
fi

# Scripts/release.sh rewrites only the Formula's `sha256 "..."` literal after qualification, so every changed line
# in that file must be one; any other Formula edit after the live run is a change nobody qualified.
if [ -n "$changed" ]; then
    if ! formula_diff=$(git diff -U0 "$qualified" "$tag_ref^{commit}" -- Formula/logic-pro-mcp.rb 2>/dev/null); then
        echo "Error: cannot read the Formula change in $tag (#985)." >&2
        exit 1
    fi
    while IFS= read -r line; do
        case "$line" in
            "" | "+++ "* | "--- "* | "diff "* | "index "* | "@@"*) continue ;;
        esac
        if ! [[ "$line" =~ ^[-+][[:space:]]*sha256\ \"[0-9a-f]{64}\"[[:space:]]*$ ]]; then
            echo "Error: $tag changes Formula/logic-pro-mcp.rb beyond its sha256 line after qualification (#985)." >&2
            exit 1
        fi
    done <<< "$formula_diff"
fi

echo "$tag: qualified at $qualified"
