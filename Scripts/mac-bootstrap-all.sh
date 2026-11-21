#!/usr/bin/env bash
# Full Mac Studio bootstrap: Cursor Agent CLI, HTTPS git sync, LogicProMCP + Cursor MCP connect.
# Safe to re-run. Does not store secrets. You must approve macOS permission dialogs locally.
set -euo pipefail

REPO_URL="${LOGIC_PRO_MCP_GIT_URL:-https://github.com/RolandGasparyan/logic-pro-mcp.git}"
DEST="${LOGIC_PRO_MCP_SOURCE:-$HOME/logic-pro-mcp}"
WORKER_NAME="${CURSOR_WORKER_NAME:-mac-studio-logic}"

log() { printf '\n== %s ==\n' "$*"; }

ensure_agent_cli() {
  export PATH="$HOME/.local/bin:$PATH"
  if command -v agent >/dev/null 2>&1; then
    log "Cursor Agent CLI: $(agent --version 2>/dev/null || echo installed)"
    return 0
  fi
  log "Installing Cursor Agent CLI"
  curl -fsSL https://cursor.com/install | bash
  export PATH="$HOME/.local/bin:$PATH"
  command -v agent >/dev/null 2>&1 || {
    printf 'ERROR: agent not on PATH after install. Add to ~/.zshrc:\n  export PATH="$HOME/.local/bin:$PATH"\n' >&2
    exit 1
  }
}

ensure_zshrc_path() {
  local line='export PATH="$HOME/.local/bin:$PATH"'
  if [[ -f "$HOME/.zshrc" ]] && grep -q '.local/bin' "$HOME/.zshrc"; then
    return 0
  fi
  log "Persisting ~/.local/bin in ~/.zshrc"
  printf '\n%s\n' "$line" >>"$HOME/.zshrc"
}

ensure_repo() {
  if [[ ! -d "$DEST/.git" ]]; then
    log "Cloning $REPO_URL → $DEST"
    git clone "$REPO_URL" "$DEST"
  fi
  cd "$DEST"
  local origin
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" == git@github.com:* ]] || [[ "$origin" != "$REPO_URL" ]]; then
    log "Setting origin to HTTPS: $REPO_URL"
    git remote set-url origin "$REPO_URL"
  fi
  git fetch origin main
  git checkout -f main 2>/dev/null || git checkout -f -B main
  git pull --ff-only origin main
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || {
    printf 'ERROR: Run on macOS only.\n' >&2
    exit 1
  }
  ensure_agent_cli
  ensure_zshrc_path
  ensure_repo
  log "Running full Logic Pro MCP + Cursor connect"
  bash "$DEST/Scripts/mac-full-mcp-connect.sh"
  log "Optional — cloud agents on this Mac (new Terminal tab, keep open):"
  printf '  export PATH="$HOME/.local/bin:$PATH"\n'
  printf '  agent login\n'
  printf '  cd %q\n' "$DEST"
  printf '  agent worker start --name %q\n' "$WORKER_NAME"
}

main "$@"