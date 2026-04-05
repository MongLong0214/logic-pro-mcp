#!/bin/bash
# LogicProMCP Full Uninstaller
# Rolls back all MCP server artifacts (PRD §9.3)
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
BINARY="/usr/local/bin/LogicProMCP"

echo "=== LogicProMCP Full Uninstaller ==="
echo ""

# 1. Remove binary
if [ -f "$BINARY" ]; then
    sudo rm "$BINARY"
    echo "✓ Removed binary: $BINARY"
else
    echo "Binary not found — skipped."
fi

# 2. Uninstall Key Commands
if [ -f "$SCRIPT_DIR/uninstall-keycmds.sh" ]; then
    echo ""
    bash "$SCRIPT_DIR/uninstall-keycmds.sh"
else
    echo "Key Commands uninstaller not found — skipped."
fi

# 3. Remove MCP registration (if registered)
echo ""
echo "Note: If registered with Claude Code, run:"
echo "  claude mcp remove logic-pro"
echo ""

# 4. Scripter reminder
echo "Note: Remove Scripter MIDI FX from Logic Pro channel strips manually."
echo "  (Logic Pro > Channel Strip > MIDI FX > remove LogicProMCP-Scripter)"
echo ""

# 5. MCU reminder
echo "Note: Remove MCU control surface from Logic Pro:"
echo "  Logic Pro > Control Surfaces > Setup > delete LogicProMCP-MCU device"
echo ""

echo "=== Uninstall complete ==="
