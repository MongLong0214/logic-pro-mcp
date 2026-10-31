#!/bin/bash
# LogicProMCP Key Commands Uninstaller
# Removes only the staged mapping reference. Existing bindings and backups are
# preserved because current setup never imports or replaces Logic key commands.

set -euo pipefail

KEYCMD_DIR="${LOGIC_PRO_MCP_KEYCMD_DIR:-$HOME/Music/Audio Music Apps/Key Commands}"
BACKUP_DIR="$KEYCMD_DIR/backups"
MCP_PRESET="$KEYCMD_DIR/LogicProMCP-KeyCommands.plist"

terminal_receipt() {
    echo "terminal=true"
    echo "human_intervention_required=false"
    echo "human_intervention_requests=0"
}

fail_keycmd_uninstall() {
    echo "Error: $1"
    terminal_receipt
    exit 1
}

echo "=== LogicProMCP Key Commands Uninstaller ==="
echo ""

if [ -e "$MCP_PRESET" ] || [ -L "$MCP_PRESET" ]; then
    if rm -f "$MCP_PRESET"; then
        :
    elif [ -e "$MCP_PRESET" ] || [ -L "$MCP_PRESET" ]; then
        fail_keycmd_uninstall "Key-command mapping reference removal failed."
    fi
    if [ -e "$MCP_PRESET" ] || [ -L "$MCP_PRESET" ]; then
        fail_keycmd_uninstall "Key-command mapping reference remains after removal."
    fi
    echo "✓ Removed mapping reference: $MCP_PRESET"
else
    echo "Mapping reference not found — skipped."
fi

if [ -d "$BACKUP_DIR" ]; then
    echo "Existing key-command backups preserved: $BACKUP_DIR"
else
    echo "No key-command backup directory found."
fi

if [ -n "${LOGIC_PRO_MCP_KEYCMD_AUTO_RESTORE:-}" ] || [ -n "${LOGIC_PRO_MCP_KEYCMD_RESTORE_FROM:-}" ]; then
    echo "Legacy restore override ignored: reference-only uninstall never replaces current bindings from a backup."
fi

echo "Existing Logic key-command bindings were not modified."
terminal_receipt
