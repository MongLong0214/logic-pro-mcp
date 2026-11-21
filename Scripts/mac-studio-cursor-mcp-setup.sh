#!/usr/bin/env bash
# Back-compat wrapper — prefer Scripts/cursor-mcp-setup.sh
# Canonical checkout: git@github.com:RolandGasparyan/logic-pro-mcp.git
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOGIC_PRO_MCP_GIT_URL="${LOGIC_PRO_MCP_GIT_URL:-git@github.com:RolandGasparyan/logic-pro-mcp.git}"
exec "$SCRIPT_DIR/cursor-mcp-setup.sh" "$@"
