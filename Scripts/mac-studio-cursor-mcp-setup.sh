#!/usr/bin/env bash
# Logic Pro MCP + Cursor setup for Roland's Mac Studio.
# Run in Terminal.app on macOS (not on the Linux cloud agent VM).
set -euo pipefail

SOURCE_BUILD_ROOT="${LOGIC_PRO_MCP_SOURCE:-$HOME/tempoproj/higgsfield-studio/logic-pro-mcp}"
MCP_USER_JSON="${HOME}/.cursor/mcp.json"
MCP_PROJECT_JSON=""
REPORT_DIR="${TMPDIR:-/tmp}/logic-pro-mcp-setup-$$"
mkdir -p "$REPORT_DIR"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "This script must run on macOS."

LOGIC_BIN=""
if command -v LogicProMCP >/dev/null 2>&1; then
  LOGIC_BIN="$(command -v LogicProMCP)"
elif brew list logic-pro-mcp >/dev/null 2>&1; then
  LOGIC_BIN="$(brew --prefix logic-pro-mcp)/bin/LogicProMCP 2>/dev/null || true)"
fi

if [[ -z "${LOGIC_BIN}" || ! -x "${LOGIC_BIN}" ]]; then
  log "LogicProMCP not installed; installing via Homebrew..."
  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is required. Install from https://brew.sh"
  fi
  brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp
  brew trust monglong0214/logic-pro-mcp 2>/dev/null || true
  brew install logic-pro-mcp
  LOGIC_BIN="$(command -v LogicProMCP)"
fi

[[ -n "$LOGIC_BIN" && -x "$LOGIC_BIN" ]] || fail "LogicProMCP still not found after install."

if [[ -d "$SOURCE_BUILD_ROOT" && -f "$SOURCE_BUILD_ROOT/Package.swift" ]]; then
  log "Source tree present at $SOURCE_BUILD_ROOT (using brew/binary: $LOGIC_BIN)"
fi

register_mcp_json() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  python3 - "$target" "$LOGIC_BIN" <<'PY'
import json, os, sys
path, command = sys.argv[1], sys.argv[2]
data = {"mcpServers": {}}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
servers = data.setdefault("mcpServers", {})
servers["logic-pro"] = {
    "command": command if os.path.isabs(command) else "LogicProMCP",
}
if command != "LogicProMCP" and os.path.isabs(command):
    servers["logic-pro"]["command"] = command
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(path)
PY
}

USER_CFG="$(register_mcp_json "$MCP_USER_JSON")"
log "Updated Cursor user MCP config: $USER_CFG"

if [[ -d "$SOURCE_BUILD_ROOT/.cursor" ]] || [[ -f "$SOURCE_BUILD_ROOT/.cursor/mcp.json" ]]; then
  MCP_PROJECT_JSON="$SOURCE_BUILD_ROOT/.cursor/mcp.json"
  PROJ_CFG="$(register_mcp_json "$MCP_PROJECT_JSON")"
  log "Updated project MCP config: $PROJ_CFG"
fi

log "=== LogicProMCP --check-permissions ==="
"$LOGIC_BIN" --check-permissions | tee "$REPORT_DIR/check-permissions.txt"

log "=== LogicProMCP doctor --json --client cursor ==="
"$LOGIC_BIN" doctor --json --client cursor | tee "$REPORT_DIR/doctor-cursor.json"

log ""
log "=== Summary paths ==="
log "Binary: $LOGIC_BIN"
log "User MCP: $MCP_USER_JSON"
[[ -n "$MCP_PROJECT_JSON" ]] && log "Project MCP: $MCP_PROJECT_JSON"
log "Reports: $REPORT_DIR"

log ""
log "=== Manual steps still required (doctor will list gaps) ==="
log "1. System Settings → Privacy & Security → Accessibility: enable Cursor (and Terminal if you launched from there)."
log "2. Automation: allow Cursor to control Logic Pro and System Events."
log "3. Logic Pro → Control Surfaces → Setup: add Mackie Control on LogicProMCP-MCU-Internal (input + output)."
log "4. Restart Cursor → Settings → MCP → reload logic-pro."
log "5. In Cursor, ask: \"Check Logic Pro MCP health and show all ready channels.\""