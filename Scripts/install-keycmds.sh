#!/bin/bash
# LogicProMCP Key Commands Installer (v3.1.6)
#
# Backs up existing key commands and stages the legacy MCP preset reference.
#
# IMPORTANT: Logic Pro 12.2+ no longer accepts plist-based Key Commands
# Import. The .plist file is retained only as a CC→command mapping reference.
# Staging it cannot establish or verify Logic-side bindings.
#
# Most preset operations are now covered by logic_edit / logic_project /
# logic_navigate / logic_tracks / logic_transport without any binding.
# Channel-only mapped operations remain unattended_unavailable.
#
# Reference: PRD §6.3 (legacy) + PRD-issue1-keycmd-port-routing §3

set -euo pipefail

KEYCMD_DIR="${LOGIC_PRO_MCP_KEYCMD_DIR:-$HOME/Music/Audio Music Apps/Key Commands}"
BACKUP_DIR="$KEYCMD_DIR/backups"
PRESET_SRC="$(dirname "$0")/keycmd-preset.plist"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== LogicProMCP Key Commands Installer ==="
echo ""

# Verify preset file exists
if [ ! -f "$PRESET_SRC" ]; then
    echo "ERROR: Preset file not found: $PRESET_SRC"
    exit 1
fi

# Create directories
mkdir -p "$KEYCMD_DIR"
mkdir -p "$BACKUP_DIR"

# Backup existing key commands
# RB-6 (2026-05-08 enterprise review) closed in v3.4.0: pre-fix this glob
# matched only `*.plist` and `*.logickeycommands` and silently skipped
# `*.logikcs` (Logic 12.2+ binary format), so the v3.1.6 SETUP rewrite
# claimed binding-reference safety while the underlying installer could still
# clobber a Logic 12.2 user's bindings without backing them up. The
# `.logikcs` extension is now included so backup coverage matches the
# user-facing claim.
EXISTING_FILES=$(find "$KEYCMD_DIR" -maxdepth 1 \( -name "*.plist" -o -name "*.logickeycommands" -o -name "*.logikcs" \) 2>/dev/null | grep -v backups || true)
if [ -n "$EXISTING_FILES" ]; then
    echo "Backing up existing key commands to: $BACKUP_DIR/backup_$TIMESTAMP/"
    mkdir -p "$BACKUP_DIR/backup_$TIMESTAMP"
    echo "$EXISTING_FILES" | while read -r f; do
        cp "$f" "$BACKUP_DIR/backup_$TIMESTAMP/"
    done
    echo "  Backed up $(echo "$EXISTING_FILES" | wc -l | tr -d ' ') files."
else
    echo "No existing key commands found — clean install."
fi

# Check for CC conflicts (CC 20-93 on CH 16)
echo ""
echo "Checking for MIDI CC conflicts..."
# Logic Pro stores key commands in binary/proprietary format.
# We cannot establish live conflict state from this reference-only script.
echo "  Note: Logic 12.2+ does not import this .plist. Use it only as a"
echo "  CC→Command mapping reference. It does not qualify mapped execution."

# Stage preset reference (NOT importable on Logic 12.2+)
cp "$PRESET_SRC" "$KEYCMD_DIR/LogicProMCP-KeyCommands.plist"
echo ""
echo "✓ Mapping reference staged: $KEYCMD_DIR/LogicProMCP-KeyCommands.plist"
echo ""
echo "=== Result ==="
echo "Logic Pro 12.2+ does NOT accept this .plist via Import (the menu is gray)."
echo "The file is staged only as a CC→Command mapping reference."
echo "Mapped Logic operations remain unattended_unavailable because setup and"
echo "outcome readback cannot be verified programmatically."
echo "Most preset ops are already routed via logic_edit / logic_project /"
echo "logic_navigate / logic_tracks / logic_transport through verified alternatives."
echo "Any backup created by this reference-only staging remains in: $BACKUP_DIR"
