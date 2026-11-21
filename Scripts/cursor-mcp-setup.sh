#!/usr/bin/env bash
# Install Logic Pro MCP (if needed), register it with Cursor, and run doctor.
# Run on macOS in Terminal — not on Linux Cloud Agent VMs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_GIT_URL="${LOGIC_PRO_MCP_GIT_URL:-https://github.com/RolandGasparyan/logic-pro-mcp.git}"
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ "$(uname -s)" == "Darwin" ]] || fail "This script must run on macOS (Logic Pro MCP is not available on Linux)."
fi

if [[ -n "${LOGIC_PRO_MCP_SOURCE:-}" ]]; then
  REPO_ROOT="$LOGIC_PRO_MCP_SOURCE"
elif [[ -f "$SCRIPT_REPO/Package.swift" ]]; then
  REPO_ROOT="$SCRIPT_REPO"
else
  REPO_ROOT="${HOME}/logic-pro-mcp"
fi

if [[ ! -f "$REPO_ROOT/Package.swift" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would clone $REPO_GIT_URL into $REPO_ROOT"
  else
    log "Cloning $REPO_GIT_URL into $REPO_ROOT"
    mkdir -p "$(dirname "$REPO_ROOT")"
    git clone "$REPO_GIT_URL" "$REPO_ROOT"
  fi
fi

MCP_USER_JSON="${CURSOR_MCP_USER_JSON:-$HOME/.cursor/mcp.json}"
MCP_PROJECT_JSON="$REPO_ROOT/.cursor/mcp.json"
REPORT_DIR="${TMPDIR:-/tmp}/logic-pro-mcp-cursor-setup-$$"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Source checkout: $REPO_ROOT"
  log "Git URL: $REPO_GIT_URL"
  log "User MCP: $MCP_USER_JSON"
  log "Project MCP: $MCP_PROJECT_JSON"
  exit 0
fi

mkdir -p "$REPORT_DIR"

LOGIC_BIN="${LOGIC_PRO_MCP_BIN:-}"
if [[ -n "$LOGIC_BIN" && -x "$LOGIC_BIN" ]]; then
  :
elif command -v LogicProMCP >/dev/null 2>&1; then
  LOGIC_BIN="$(command -v LogicProMCP)"
elif [[ -x "$REPO_ROOT/.build/release/LogicProMCP" ]]; then
  LOGIC_BIN="$REPO_ROOT/.build/release/LogicProMCP"
elif command -v brew >/dev/null 2>&1 && brew list logic-pro-mcp >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix logic-pro-mcp 2>/dev/null || true)"
  if [[ -n "$BREW_PREFIX" && -x "$BREW_PREFIX/bin/LogicProMCP" ]]; then
    LOGIC_BIN="$BREW_PREFIX/bin/LogicProMCP"
  fi
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
log "Source checkout: $REPO_ROOT"
log "Git URL: $REPO_GIT_URL"
log "Reports: $REPORT_DIR"