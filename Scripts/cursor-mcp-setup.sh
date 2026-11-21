#!/usr/bin/env bash
# Install Logic Pro MCP (if needed), register it with Cursor, and run doctor.
# Run on macOS in Terminal — not on Linux Cloud Agent VMs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_USER_JSON="${CURSOR_MCP_USER_JSON:-$HOME/.cursor/mcp.json}"
MCP_PROJECT_JSON="$REPO_ROOT/.cursor/mcp.json"
REPORT_DIR="${TMPDIR:-/tmp}/logic-pro-mcp-cursor-setup-$$"
mkdir -p "$REPORT_DIR"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "This script must run on macOS (Logic Pro MCP is not available on Linux)."

LOGIC_BIN="${LOGIC_PRO_MCP_BIN:-}"
if [[ -n "$LOGIC_BIN" && -x "$LOGIC_BIN" ]]; then
  :
elif command -v LogicProMCP >/dev/null 2>&1; then
  LOGIC_BIN="$(command -v LogicProMCP)"
elif [[ -x "$REPO_ROOT/.build/release/LogicProMCP" ]]; then
  LOGIC_BIN="$REPO_ROOT/.build/release/LogicProMCP"
elif command -v brew >/dev/null 2>&1 && brew list logic-pro-mcp >/dev/null 2>&1; then
  LOGIC_BIN="$(brew --prefix logic-pro-mcp)/bin/LogicProMCP" 2>/dev/null || true
fi

if [[ -z "${LOGIC_BIN}" || ! -x "${LOGIC_BIN}" ]]; then
  log "LogicProMCP not found; installing via Homebrew..."
  command -v brew >/dev/null 2>&1 || fail "Homebrew is required. Install from https://brew.sh"
  brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp
  brew trust monglong0214/logic-pro-mcp 2>/dev/null || true
  brew install logic-pro-mcp
  LOGIC_BIN="$(command -v LogicProMCP)"
fi

[[ -n "$LOGIC_BIN" && -x "$LOGIC_BIN" ]] || fail "LogicProMCP still not found after install."

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
servers["logic-pro"] = {"command": command}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(path)
PY
}

USER_CFG="$(register_mcp_json "$MCP_USER_JSON")"
log "Updated Cursor user MCP config: $USER_CFG"

PROJ_CFG="$(register_mcp_json "$MCP_PROJECT_JSON")"
log "Updated project MCP config: $PROJ_CFG"

log "=== LogicProMCP --check-permissions ==="
"$LOGIC_BIN" --check-permissions | tee "$REPORT_DIR/check-permissions.txt"

log "=== LogicProMCP doctor --json --client cursor ==="
"$LOGIC_BIN" doctor --json --client cursor | tee "$REPORT_DIR/doctor-cursor.json"

log ""
log "=== Next steps ==="
log "1. System Settings → Privacy & Security → Accessibility: enable Cursor."
log "2. Automation: allow Cursor to control Logic Pro and System Events."
log "3. Logic Pro → Control Surfaces → Setup: Mackie Control on LogicProMCP-MCU-Internal (in + out)."
log "4. Restart Cursor (or Settings → MCP → reload logic-pro)."
log "5. Ask: \"Check Logic Pro MCP health and show all ready channels.\""
log ""
log "Binary: $LOGIC_BIN"
log "Reports: $REPORT_DIR"