#!/bin/bash
set -euo pipefail

REPO="MongLong0214/logic-pro-mcp"
BINARY="LogicProMCP"
INSTALL_DIR="${LOGIC_PRO_MCP_INSTALL_DIR:-/usr/local/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${LOGIC_PRO_MCP_VERSION:-v2.2.0}"
SHA256="${LOGIC_PRO_MCP_SHA256:-}"
EXPECTED_TEAM_ID="${LOGIC_PRO_MCP_TEAM_ID:-}"
REGISTER_CLAUDE="${LOGIC_PRO_MCP_REGISTER_CLAUDE:-1}"
INSTALL_KEYCMDS="${LOGIC_PRO_MCP_INSTALL_KEYCMDS:-1}"
SKIP_SUDO="${LOGIC_PRO_MCP_SKIP_SUDO:-0}"

verify_signature() {
    local binary_path="$1"

    if ! command -v codesign >/dev/null 2>&1; then
        echo "  Error: codesign not available for signature verification."
        return 1
    fi

    echo "  Verifying code signature..."
    if ! codesign --verify --strict --verbose=2 "$binary_path" >/dev/null 2>&1; then
        echo "  Error: code signature verification failed."
        return 1
    fi

    if [ -n "$EXPECTED_TEAM_ID" ]; then
        local actual_team_id
        actual_team_id=$(codesign -dv --verbose=4 "$binary_path" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
        if [ "$actual_team_id" != "$EXPECTED_TEAM_ID" ]; then
            echo "  Error: TeamIdentifier mismatch."
            echo "    expected: $EXPECTED_TEAM_ID"
            echo "    actual:   ${actual_team_id:-<none>}"
            return 1
        fi
    fi
}

verify_gatekeeper() {
    local binary_path="$1"

    if ! command -v spctl >/dev/null 2>&1; then
        echo "  Error: spctl not available for Gatekeeper assessment."
        return 1
    fi

    echo "  Verifying Gatekeeper assessment..."
    if ! spctl --assess --type execute "$binary_path" >/dev/null 2>&1; then
        echo "  Error: Gatekeeper assessment failed. Binary is not notarized/stapled for this machine."
        return 1
    fi
}

echo ""
echo "  Logic Pro MCP Server — Installer"
echo ""

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86_64" ]; then
    echo "  Error: Unsupported macOS architecture: $ARCH"
    exit 1
fi

if [ "$VERSION" = "latest" ]; then
    echo "  Error: mutable 'latest' installs are not allowed in enterprise mode."
    echo "    Set LOGIC_PRO_MCP_VERSION to a pinned tag, e.g. v2.2.0."
    exit 1
fi

echo "  Downloading release $VERSION..."
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$BINARY"
SHA_URL="https://github.com/$REPO/releases/download/$VERSION/SHA256SUMS.txt"
METADATA_URL="https://github.com/$REPO/releases/download/$VERSION/RELEASE-METADATA.json"

if [ -z "$SHA256" ]; then
    echo "  Fetching release SHA256 manifest..."
    SHA256=$(curl -fsSL "$SHA_URL" | awk '$2 == "LogicProMCP" {print $1}')
    if [ -z "$SHA256" ]; then
        echo "  Error: could not resolve SHA256 for $BINARY from release manifest."
        exit 1
    fi
fi

if [ -z "$EXPECTED_TEAM_ID" ]; then
    echo "  Fetching release metadata..."
    EXPECTED_TEAM_ID=$(curl -fsSL "$METADATA_URL" | awk -F'"' '/"team_id"[[:space:]]*:/ {print $4; exit}')
    if [ -z "$EXPECTED_TEAM_ID" ]; then
        echo "  Error: could not resolve TeamIdentifier from release metadata."
        echo "    Expected signed release metadata at: $METADATA_URL"
        exit 1
    fi
fi

TMP=$(mktemp)
if curl -fsSL "$DOWNLOAD_URL" -o "$TMP" 2>/dev/null; then
    echo "  Verifying SHA256..."
    ACTUAL_SHA256=$(shasum -a 256 "$TMP" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$SHA256" ]; then
        echo "  Error: SHA256 mismatch."
        echo "    expected: $SHA256"
        echo "    actual:   $ACTUAL_SHA256"
        rm -f "$TMP"
        exit 1
    fi
    verify_signature "$TMP"
    verify_gatekeeper "$TMP"
    chmod +x "$TMP"
    echo "  Installing to $INSTALL_DIR/$BINARY..."
    if [ "$SKIP_SUDO" = "1" ] || [ -w "$(dirname "$INSTALL_DIR")" ] || [ -w "$INSTALL_DIR" ]; then
        mkdir -p "$INSTALL_DIR"
        mv "$TMP" "$INSTALL_DIR/$BINARY"
    else
        sudo mkdir -p "$INSTALL_DIR"
        sudo mv "$TMP" "$INSTALL_DIR/$BINARY"
    fi
    echo "  Done."
else
    echo "  Error: failed to download pinned release artifact."
    rm -f "$TMP"
    exit 1
fi

echo ""

# Register with Claude by default when available.
if [ "$REGISTER_CLAUDE" = "1" ] && command -v claude &>/dev/null; then
    echo "  Registering with Claude Code..."
    claude mcp add --scope user logic-pro -- "$INSTALL_DIR/$BINARY" 2>/dev/null && echo "  Registered." || echo "  Already registered."
else
    echo "  Claude registration skipped."
    echo "    Manual command: claude mcp add --scope user logic-pro -- $INSTALL_DIR/$BINARY"
fi

echo ""

if [ -f "$SCRIPT_DIR/install-keycmds.sh" ]; then
    if [ "$INSTALL_KEYCMDS" = "1" ]; then
        echo "  Installing Key Commands preset..."
        if bash "$SCRIPT_DIR/install-keycmds.sh"; then
            echo "  Key Commands preset installed."
        else
            echo "  Warning: Key Commands preset install did not complete cleanly."
        fi
    else
        echo "  Key Commands preset install skipped."
        echo "    Manual command: bash $SCRIPT_DIR/install-keycmds.sh"
    fi
    echo ""
fi

# Check permissions
echo "  Checking permissions..."
if ! "$INSTALL_DIR/$BINARY" --check-permissions 2>&1 | sed 's/^/    /'; then
    echo "  Warning: required Logic Pro permissions are not granted yet."
fi

echo ""
echo "  Manual Logic Pro setup required before production use:"
echo "    1. Open Logic Pro"
echo "    2. Logic Pro > Control Surfaces > Setup"
echo "    3. New > Install > Mackie Control > Add"
echo "    4. Set MIDI In/Out to: LogicProMCP-MCU-Internal"
echo "    5. Insert MIDI FX > Scripter and load: $SCRIPT_DIR/LogicProMCP-Scripter.js"
echo "    6. Import the LogicProMCP Key Commands preset inside Logic Pro"
echo "    7. Approve verified manual channels:"
echo "       $INSTALL_DIR/$BINARY --approve-channel MIDIKeyCommands"
echo "       $INSTALL_DIR/$BINARY --approve-channel Scripter"
echo ""
echo "  Installation complete. Health will remain manual_validation_required"
echo "  for Key Commands and Scripter until those Logic Pro steps are done."
echo ""
