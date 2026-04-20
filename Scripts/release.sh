#!/bin/bash
#
# Scripts/release.sh — one-command ADHOC release.
#
# Produces a v-tagged GitHub release with the arm64-native binary, aliased
# `universal` / `arm64` tarballs, SHA256SUMS.txt, and RELEASE-METADATA.json.
# Commits the Formula sha256 sync *before* pushing the tag so `brew install`
# against `git checkout <tag>` resolves correctly.
#
# Usage:
#   Scripts/release.sh v3.0.1            # adhoc release
#   DRY_RUN=1 Scripts/release.sh v3.0.1  # print steps without executing
#
# Preconditions:
#   - Working tree clean (or only the version-bump commit staged)
#   - `gh` CLI authenticated
#   - Tag does not already exist on remote
#
set -euo pipefail

VERSION="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN="${DRY_RUN:-0}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 vMAJOR.MINOR.PATCH[-prerelease]"
    exit 1
fi
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "Error: VERSION '$VERSION' must be strict SemVer, e.g. v3.0.1 or v3.1.0-rc1"
    exit 1
fi

run() {
    echo "→ $*"
    if [ "$DRY_RUN" != "1" ]; then
        eval "$@"
    fi
}

cd "$REPO_ROOT"

echo ""
echo "  Logic Pro MCP — ADHOC release automation"
echo "  version: $VERSION"
echo "  dry-run: $DRY_RUN"
echo ""

# 1. Verify working tree + tag availability
if [ -n "$(git status --porcelain)" ]; then
    echo "Error: working tree is not clean. Commit or stash first."
    git status --short
    exit 1
fi
if git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
    echo "Error: tag $VERSION already exists locally."
    exit 1
fi
if git ls-remote --tags origin "$VERSION" | grep -q "$VERSION"; then
    echo "Error: tag $VERSION already exists on origin."
    exit 1
fi

# 2. Build + adhoc-sign
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

run "swift build -c release"
run "codesign --force --sign - .build/release/LogicProMCP"

# 3. Stage artifacts
run "cp .build/release/LogicProMCP '$STAGE_DIR/'"
run "cp docs/SETUP.md '$STAGE_DIR/'"
run "cp Scripts/install-keycmds.sh Scripts/uninstall-keycmds.sh Scripts/keycmd-preset.plist Scripts/LogicProMCP-Scripter.js '$STAGE_DIR/'"

if [ "$DRY_RUN" = "1" ]; then
    BINARY_SHA="<dry-run-binary-sha>"
    TARBALL_SHA="<dry-run-tarball-sha>"
else
    (cd "$STAGE_DIR" && tar -czf "LogicProMCP-macOS-arm64.tar.gz" \
        LogicProMCP SETUP.md install-keycmds.sh uninstall-keycmds.sh keycmd-preset.plist LogicProMCP-Scripter.js)
    cp "$STAGE_DIR/LogicProMCP-macOS-arm64.tar.gz" "$STAGE_DIR/LogicProMCP-macOS-universal.tar.gz"

    BINARY_SHA=$(shasum -a 256 "$STAGE_DIR/LogicProMCP" | awk '{print $1}')
    TARBALL_SHA=$(shasum -a 256 "$STAGE_DIR/LogicProMCP-macOS-arm64.tar.gz" | awk '{print $1}')

    cat > "$STAGE_DIR/SHA256SUMS.txt" <<EOF
$BINARY_SHA  LogicProMCP
$TARBALL_SHA  LogicProMCP-macOS-arm64.tar.gz
$TARBALL_SHA  LogicProMCP-macOS-universal.tar.gz
EOF
    cat > "$STAGE_DIR/RELEASE-METADATA.json" <<EOF
{"version":"$VERSION","team_id":"ADHOC","signing":"adhoc"}
EOF
fi

echo ""
echo "  Binary  SHA: $BINARY_SHA"
echo "  Tarball SHA: $TARBALL_SHA"
echo ""

# 4. Patch Formula + commit BEFORE tag push (per round-5 review: tag must have the correct Formula SHA)
if [ "$DRY_RUN" != "1" ]; then
    # Replace any existing sha256 literal on the Formula line.
    # Using awk to match only the sha256 line to avoid touching comments.
    awk -v new="$TARBALL_SHA" '
        /^[[:space:]]*sha256 "/ { sub(/"[0-9a-f]+"/, "\"" new "\"") }
        { print }
    ' Formula/logic-pro-mcp.rb > Formula/logic-pro-mcp.rb.tmp
    mv Formula/logic-pro-mcp.rb.tmp Formula/logic-pro-mcp.rb
fi

run "git add Formula/logic-pro-mcp.rb"
run "git commit -m 'release: $VERSION Formula sha256 sync

Pre-tag Formula update so \`git checkout $VERSION\` resolves to the
published universal tarball SHA.

sha256: $TARBALL_SHA
'"

# 5. Tag + push
run "git tag $VERSION -m 'Release $VERSION'"
run "git push origin main"
run "git push origin $VERSION"

# 6. Create GitHub release (tag push already triggered CI; this attaches artifacts)
NOTES_FILE="$STAGE_DIR/release-notes.md"
if [ "$DRY_RUN" != "1" ]; then
    cat > "$NOTES_FILE" <<EOF
## $VERSION — ADHOC release

arm64-native binary ($BINARY_SHA). Intel Macs run under Rosetta 2.
Tarballs \`-arm64\` and \`-universal\` are bit-identical aliases ($TARBALL_SHA)
for Homebrew-tap backward compatibility.

### Install

\`\`\`
brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp
brew install logic-pro-mcp
\`\`\`

Or manual:
\`\`\`
LOGIC_PRO_MCP_SHA256=$BINARY_SHA \\
LOGIC_PRO_MCP_TEAM_ID=ADHOC \\
bash <(curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/$VERSION/Scripts/install.sh)
\`\`\`

See CHANGELOG.md for the full change list.
EOF
fi

run "gh release create $VERSION \
    --title '$VERSION' \
    --target main \
    --notes-file '$NOTES_FILE' \
    '$STAGE_DIR/LogicProMCP' \
    '$STAGE_DIR/LogicProMCP-macOS-universal.tar.gz' \
    '$STAGE_DIR/LogicProMCP-macOS-arm64.tar.gz' \
    '$STAGE_DIR/SHA256SUMS.txt' \
    '$STAGE_DIR/RELEASE-METADATA.json'"

echo ""
echo "  ✓ Released: https://github.com/MongLong0214/logic-pro-mcp/releases/tag/$VERSION"
echo ""
