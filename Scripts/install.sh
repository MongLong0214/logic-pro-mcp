#!/bin/bash
set -euo pipefail

REPO="MongLong0214/logic-pro-mcp"
BINARY="LogicProMCP"
INSTALL_DIR="/usr/local/bin"

echo ""
echo "  Logic Pro MCP Server — Installer"
echo ""

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "  Error: Only Apple Silicon (arm64) supported. Got: $ARCH"
    exit 1
fi

# Download latest release binary
echo "  Downloading latest release..."
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$BINARY"
TMP=$(mktemp)
if curl -fsSL "$DOWNLOAD_URL" -o "$TMP" 2>/dev/null; then
    chmod +x "$TMP"
    echo "  Installing to $INSTALL_DIR/$BINARY..."
    sudo mv "$TMP" "$INSTALL_DIR/$BINARY"
    echo "  Done."
else
    echo "  Release not found. Building from source..."
    rm -f "$TMP"

    # Check Swift
    if ! command -v swift &>/dev/null; then
        echo "  Error: Swift not found. Install Xcode Command Line Tools:"
        echo "    xcode-select --install"
        exit 1
    fi

    # Clone + build
    TMPDIR=$(mktemp -d)
    git clone --depth 1 "https://github.com/$REPO.git" "$TMPDIR" 2>/dev/null
    cd "$TMPDIR"
    swift build -c release 2>&1 | tail -1
    sudo cp ".build/release/$BINARY" "$INSTALL_DIR/$BINARY"
    rm -rf "$TMPDIR"
    echo "  Built and installed."
fi

echo ""

# Register with Claude (if available)
if command -v claude &>/dev/null; then
    echo "  Registering with Claude Code..."
    claude mcp add --scope user logic-pro -- "$BINARY" 2>/dev/null && echo "  Registered." || echo "  Already registered."
else
    echo "  Claude Code not found. Register manually:"
    echo "    claude mcp add --scope user logic-pro -- $BINARY"
fi

echo ""

# Check permissions
echo "  Checking permissions..."
"$INSTALL_DIR/$BINARY" --check-permissions 2>&1 | sed 's/^/    /'

echo ""
echo "  Setup Logic Pro:"
echo "    1. Open Logic Pro"
echo "    2. Logic Pro > Control Surfaces > Setup"
echo "    3. New > Install > Mackie Control > Add"
echo "    4. Set MIDI In/Out to: LogicProMCP-MCU-Internal"
echo ""
echo "  Ready. Ask Claude to control Logic Pro."
echo ""
