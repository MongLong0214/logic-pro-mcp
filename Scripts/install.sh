#!/usr/bin/env bash
set -euo pipefail

REPO="MongLong0214/logic-pro-mcp"
BINARY_NAME="LogicProMCP"
INSTALL_DIR="/usr/local/bin"

echo "=== Logic Pro MCP Server — Install ==="
echo ""

# Detect if running from cloned repo or via curl
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/Package.swift" ]]; then
    echo "Building from source..."
    cd "$PROJECT_DIR"
    swift build -c release --arch arm64 --arch x86_64 2>&1
    BUILT_BINARY="$PROJECT_DIR/.build/apple/Products/Release/$BINARY_NAME"
    if [[ ! -f "$BUILT_BINARY" ]]; then
        # Fallback for single-arch build
        BUILT_BINARY="$PROJECT_DIR/.build/release/$BINARY_NAME"
    fi
    if [[ ! -f "$BUILT_BINARY" ]]; then
        echo "ERROR: Build failed — binary not found"
        exit 1
    fi
    sudo cp "$BUILT_BINARY" "$INSTALL_DIR/$BINARY_NAME"
else
    echo "Downloading latest release..."
    DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$BINARY_NAME"
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    if ! curl -fSL --progress-bar "$DOWNLOAD_URL" -o "$TMP_DIR/$BINARY_NAME"; then
        echo "ERROR: Download failed. Check https://github.com/$REPO/releases"
        exit 1
    fi
    sudo mv "$TMP_DIR/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"
fi

sudo chmod +x "$INSTALL_DIR/$BINARY_NAME"
echo "Installed to $INSTALL_DIR/$BINARY_NAME"

# Check permissions
echo ""
echo "Checking macOS permissions..."
"$INSTALL_DIR/$BINARY_NAME" --check-permissions 2>&1 || true

# Register with Claude Code if available
echo ""
if command -v claude &>/dev/null; then
    echo "Registering with Claude Code..."
    claude mcp add --scope user logic-pro -- "$INSTALL_DIR/$BINARY_NAME" 2>/dev/null && \
        echo "Registered." || echo "Registration skipped (may already exist)."
else
    echo "Register with Claude Code:"
    echo "  claude mcp add --scope user logic-pro -- $INSTALL_DIR/$BINARY_NAME"
fi

echo ""
echo "Claude Desktop config (~/Library/Application Support/Claude/claude_desktop_config.json):"
echo '  {"mcpServers":{"logic-pro":{"command":"'"$INSTALL_DIR/$BINARY_NAME"'","args":[]}}}'
echo ""
echo "Done. Ensure Accessibility + Automation permissions are granted."
