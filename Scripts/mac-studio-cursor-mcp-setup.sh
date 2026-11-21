#!/usr/bin/env bash
# Back-compat wrapper — prefer Scripts/cursor-mcp-setup.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOGIC_PRO_MCP_SOURCE="${LOGIC_PRO_MCP_SOURCE:-$HOME/tempoproj/higgsfield-studio/logic-pro-mcp}"
exec "$SCRIPT_DIR/cursor-mcp-setup.sh"