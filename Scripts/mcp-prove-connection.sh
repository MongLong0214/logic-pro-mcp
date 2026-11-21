#!/usr/bin/env bash
# Prove Logic Pro MCP wiring: metadata on Linux; live stdio probe on macOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_JSON="${MCP_PROVE_JSON:-}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

emit_json() {
  if [[ -n "$OUT_JSON" ]]; then
    printf '%s\n' "$1" >"$OUT_JSON"
  fi
  printf '%s\n' "$1"
}

validate_mcp_json() {
  local path="$REPO_ROOT/.cursor/mcp.json"
  [[ -f "$path" ]] || fail "Missing $path — run Scripts/cursor-mcp-setup.sh on macOS"
  python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
servers = data.get("mcpServers", {})
lp = servers.get("logic-pro")
assert lp, "mcpServers.logic-pro missing"
cmd = lp.get("command")
assert cmd, "logic-pro.command missing"
print(json.dumps({"path": path, "logic_pro_command": cmd}))
PY
}

validate_registry() {
  local publisher="$REPO_ROOT/mcp-publisher"
  if [[ ! -x "$publisher" ]]; then
    local ver="${MCP_PUBLISHER_VERSION:-v1.7.9}"
    local asset=mcp-publisher_linux_amd64.tar.gz
    if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
      asset=mcp-publisher_linux_arm64.tar.gz
    fi
    curl -fsSLo "$REPO_ROOT/$asset" \
      "https://github.com/modelcontextprotocol/registry/releases/download/${ver}/${asset}"
    tar xzf "$REPO_ROOT/$asset" -C "$REPO_ROOT" mcp-publisher
    chmod +x "$publisher"
  fi
  (cd "$REPO_ROOT" && ./mcp-publisher validate)
}

OS="$(uname -s)"
MCP_CFG="$(validate_mcp_json)"

if [[ "$OS" != "Darwin" ]]; then
  validate_registry >/dev/null
  emit_json "$(MCP_CFG_JSON="$MCP_CFG" python3 - <<'PY'
import json, os
cfg = json.loads(os.environ["MCP_CFG_JSON"])
result = {
    "platform": "linux",
    "live_stdio_probe": False,
    "cursor_mcp_config": cfg,
    "registry_metadata": "valid",
    "message": "LogicProMCP stdio server requires macOS. Run this script on your Mac after brew install logic-pro-mcp.",
    "next_command": "bash Scripts/cursor-mcp-setup.sh && python3 logic_mcp_proxy.py",
}
print(json.dumps(result, indent=2))
PY
)"
  exit 0
fi

LOGIC_BIN="${LOGIC_PRO_MCP_BIN:-}"
if [[ -z "$LOGIC_BIN" ]]; then
  LOGIC_BIN="$(command -v LogicProMCP || true)"
fi
[[ -n "$LOGIC_BIN" ]] || fail "Install LogicProMCP (brew install logic-pro-mcp) or set LOGIC_PRO_MCP_BIN"

DOCTOR_JSON="$(mktemp)"
"$LOGIC_BIN" doctor --json --client cursor >"$DOCTOR_JSON"

PROBE_JSON="$(python3 "$REPO_ROOT/logic_mcp_proxy.py")"

emit_json "$(MCP_CFG_JSON="$MCP_CFG" DOCTOR_PATH="$DOCTOR_JSON" PROBE_JSON="$PROBE_JSON" python3 - <<'PY'
import json, os
doctor = json.load(open(os.environ["DOCTOR_PATH"]))
probe = json.loads(os.environ["PROBE_JSON"])
cfg = json.loads(os.environ["MCP_CFG_JSON"])
out = {
    "platform": "darwin",
    "live_stdio_probe": True,
    "cursor_mcp_config": cfg,
    "doctor": doctor,
    "stdio_probe": {
        "serverInfo": probe.get("serverInfo"),
        "tool_count": len(probe.get("tools", [])),
        "tool_names": [t["name"] for t in probe.get("tools", [])],
    },
}
print(json.dumps(out, indent=2))
PY
)"
rm -f "$DOCTOR_JSON"