#!/bin/bash
# LogicProMCP Full Uninstaller
# Rolls back all MCP server artifacts (PRD §9.3)
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
INSTALL_DIR="${LOGIC_PRO_MCP_INSTALL_DIR:-/usr/local/bin}"
BINARY="$INSTALL_DIR/LogicProMCP"
SKIP_SUDO="${LOGIC_PRO_MCP_SKIP_SUDO:-0}"
APPROVAL_STORE="${LOGIC_PRO_MCP_APPROVAL_STORE:-$HOME/Library/Application Support/LogicProMCP/operator-approvals.json}"

echo "=== LogicProMCP Full Uninstaller ==="
echo ""

# 1. Remove operator approvals
if [ -f "$APPROVAL_STORE" ]; then
    rm "$APPROVAL_STORE"
    echo "✓ Removed operator approvals: $APPROVAL_STORE"
else
    echo "Operator approvals not found — skipped."
fi

# 2. Remove binary
if [ -f "$BINARY" ]; then
    if [ "$SKIP_SUDO" = "1" ] || [ -w "$INSTALL_DIR" ]; then
        rm "$BINARY"
    else
        sudo rm "$BINARY"
    fi
    echo "✓ Removed binary: $BINARY"
else
    echo "Binary not found — skipped."
fi

# 3. Uninstall Key Commands
if [ -f "$SCRIPT_DIR/uninstall-keycmds.sh" ]; then
    echo ""
    bash "$SCRIPT_DIR/uninstall-keycmds.sh"
else
    echo "Key Commands uninstaller not found — skipped."
fi

# 4. Remove MCP registration
echo ""
if command -v claude >/dev/null 2>&1; then
    claude mcp remove logic-pro >/dev/null 2>&1 && echo "✓ Removed Claude Code registration: logic-pro" || echo "Claude Code registration not present — skipped."
else
    echo "Claude Code CLI not found — skipped MCP deregistration."
    echo "  Manual command: claude mcp remove logic-pro"
fi
echo ""

# 5. Scripter reminder
echo "Note: Remove Scripter MIDI FX from Logic Pro channel strips manually."
echo "  (Logic Pro > Channel Strip > MIDI FX > remove LogicProMCP-Scripter)"
echo ""

# 6. MCU reminder
echo "Note: Remove MCU control surface from Logic Pro:"
echo "  Logic Pro > Control Surfaces > Setup > delete LogicProMCP-MCU device"
echo ""

echo "=== Uninstall complete ==="
