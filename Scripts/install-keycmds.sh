#!/bin/bash
# LogicProMCP Key Commands Installer
# Backs up existing key commands, then installs MCP preset.
# Reference: PRD §6.3

set -euo pipefail

KEYCMD_DIR="$HOME/Music/Audio Music Apps/Key Commands"
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
EXISTING_FILES=$(find "$KEYCMD_DIR" -maxdepth 1 -name "*.plist" -o -name "*.logickeycommands" 2>/dev/null | grep -v backups || true)
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
# We can only warn — actual conflict detection requires Logic Pro to be running.
echo "  Note: Install the preset via Logic Pro > Key Commands > Edit (⌥K)."
echo "  Use 'MIDI Learn' to verify no conflicts with CC 20-93 on Channel 16."

# Copy preset
cp "$PRESET_SRC" "$KEYCMD_DIR/LogicProMCP-KeyCommands.plist"
echo ""
echo "✓ Preset installed: $KEYCMD_DIR/LogicProMCP-KeyCommands.plist"
echo ""
echo "=== Next Steps ==="
echo "1. Open Logic Pro"
echo "2. Go to Logic Pro > Key Commands > Edit (⌥K)"
echo "3. Import the preset or manually assign MIDI CC 20-93 on Channel 16"
echo "4. Reference: Scripts/keycmd-preset.plist for CC→Command mapping"
echo ""
echo "To restore: Scripts/uninstall-keycmds.sh"
