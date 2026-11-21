#!/usr/bin/env bash
# One-shot Mac connect: install, Cursor MCP registration, permission prompts, live MCP proof.
# Run in Terminal.app or iTerm on the Mac Studio while you approve TCC dialogs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { printf '\n== %s ==\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Run on macOS only."

ensure_repo_checkout() {
  local url="${LOGIC_PRO_MCP_GIT_URL:-https://github.com/RolandGasparyan/logic-pro-mcp.git}"
  local dest="${LOGIC_PRO_MCP_SOURCE:-$HOME/logic-pro-mcp}"
  if [[ -f "$REPO_ROOT/Package.swift" ]]; then
    return 0
  fi
  log "This folder is not a full logic-pro-mcp checkout (no Package.swift)."
  if [[ -f "$dest/Package.swift" && -x "$dest/Scripts/mac-full-mcp-connect.sh" ]]; then
    log "Re-running from $dest"
    exec "$dest/Scripts/mac-full-mcp-connect.sh" "$@"
  fi
  log "Cloning via HTTPS (no GitHub SSH key required): $url"
  mkdir -p "$(dirname "$dest")"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" remote set-url origin "$url" 2>/dev/null || true
    git -C "$dest" fetch origin main
    git -C "$dest" checkout -f main
    git -C "$dest" pull origin main
  else
    rm -rf "$dest"
    git clone "$url" "$dest"
  fi
  exec "$dest/Scripts/mac-full-mcp-connect.sh" "$@"
}

ensure_repo_checkout

open_privacy_panes() {
  log "Opening Privacy & Security (enable Terminal + Cursor: Accessibility & Automation)"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
  sleep 1
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation" 2>/dev/null || true
}

launch_logic() {
  log "Launching Logic Pro (approve Automation if prompted)"
  if [[ -d "/Applications/Logic Pro.app" ]]; then
    open -a "Logic Pro"
  elif [[ -d "/Applications/Logic Pro Creator Studio.app" ]]; then
    open -a "Logic Pro Creator Studio"
  else
    log "Logic Pro not found in /Applications — open a project manually before MCP mix/write tests"
  fi
}

wait_for_live_mcp() {
  local logic_bin="$1"
  local attempts="${MCP_PERMISSION_WAIT_ATTEMPTS:-36}"
  local sleep_s="${MCP_PERMISSION_WAIT_SECS:-5}"
  export LOGIC_PRO_MCP_BIN="$logic_bin"

  log "Waiting for live MCP (up to $((attempts * sleep_s))s) — approve prompts as they appear"
  local i=1
  while (( i <= attempts )); do
    set +e
    PROBE="$(python3 "$REPO_ROOT/logic_mcp_proxy.py" 2>/dev/null)"
    set -e
    if [[ -n "$PROBE" ]]; then
      count="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1]).get('tools',[])))" "$PROBE")"
      if [[ "${count:-0}" -ge 10 ]]; then
        log "Live MCP OK — $count tools"
        return 0
      fi
    fi
    log "Attempt $i/$attempts — enable Terminal/Cursor in Accessibility; allow Automation for Logic Pro + System Events; wait ${sleep_s}s..."
    sleep "$sleep_s"
    ((i++)) || true
  done
  fail "Live tools/list did not succeed in time. Run: LOGIC_PRO_MCP_BIN='$logic_bin' python3 logic_mcp_proxy.py"
}

main() {
  log "1/5 Homebrew + Cursor MCP registration"
  bash "$SCRIPT_DIR/cursor-mcp-setup.sh"

  LOGIC_BIN="$(command -v LogicProMCP)"
  [[ -n "$LOGIC_BIN" ]] || fail "LogicProMCP missing after setup"

  log "2/5 System Settings + Logic Pro"
  open_privacy_panes
  launch_logic

  log "3/5 Permission gate + live tools/list"
  wait_for_live_mcp "$LOGIC_BIN"

  log "4/5 Write connection proof JSON"
  export LOGIC_PRO_MCP_BIN="$LOGIC_BIN"
  PROOF_JSON="$REPO_ROOT/mcp-connection-proof.json"
  MCP_PROVE_JSON="$PROOF_JSON" bash "$SCRIPT_DIR/mcp-prove-connection.sh" | tee "$PROOF_JSON"

  log "5/5 Cursor MCP"
  log "In Cursor: Settings → MCP → enable logic-pro (or restart Cursor)."
  log "Open a LOCAL chat in $REPO_ROOT and ask: Check Logic Pro MCP health and show all ready channels."
  log ""
  log "Proof written: $PROOF_JSON"
  if command -v open >/dev/null && [[ -d "/Applications/Cursor.app" ]]; then
    open -a "Cursor" "$REPO_ROOT" 2>/dev/null || true
  fi
}

main "$@"