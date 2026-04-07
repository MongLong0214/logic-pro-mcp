#!/bin/bash
# LogicProMCP Key Commands Uninstaller
# Removes MCP preset and optionally restores from backup.
# Reference: PRD §6.3, §9.3

set -euo pipefail

KEYCMD_DIR="${LOGIC_PRO_MCP_KEYCMD_DIR:-$HOME/Music/Audio Music Apps/Key Commands}"
BACKUP_DIR="$KEYCMD_DIR/backups"
MCP_PRESET="$KEYCMD_DIR/LogicProMCP-KeyCommands.plist"
AUTO_RESTORE="${LOGIC_PRO_MCP_KEYCMD_AUTO_RESTORE:-0}"

echo "=== LogicProMCP Key Commands Uninstaller ==="
echo ""

# Remove MCP preset
if [ -f "$MCP_PRESET" ]; then
    rm "$MCP_PRESET"
    echo "✓ Removed: $MCP_PRESET"
else
    echo "MCP preset not found — nothing to remove."
fi

# List available backups
if [ -d "$BACKUP_DIR" ]; then
    BACKUPS=$(ls -d "$BACKUP_DIR"/backup_* 2>/dev/null || true)
    if [ -n "$BACKUPS" ]; then
        echo ""
        echo "Available backups:"
        echo "$BACKUPS" | while read -r b; do
            echo "  - $(basename "$b") ($(ls "$b" | wc -l | tr -d ' ') files)"
        done

        # Restore latest backup
        LATEST=$(echo "$BACKUPS" | sort -r | head -1)
        echo ""
        if [ "$AUTO_RESTORE" = "1" ]; then
            cp "$LATEST"/* "$KEYCMD_DIR/" 2>/dev/null || true
            echo "✓ Restored from: $(basename "$LATEST")"
        else
            read -p "Restore from $(basename "$LATEST")? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cp "$LATEST"/* "$KEYCMD_DIR/" 2>/dev/null || true
                echo "✓ Restored from: $(basename "$LATEST")"
            else
                echo "Skipped restore."
            fi
        fi
    else
        echo "No backups found."
    fi
else
    echo "No backup directory found."
fi

echo ""
echo "Done. Restart Logic Pro to apply changes."
