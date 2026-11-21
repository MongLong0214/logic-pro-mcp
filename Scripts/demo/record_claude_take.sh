#!/usr/bin/env bash
# The v3 film's take: a real Claude Code session, with the release LogicProMCP as its only MCP server, driving Logic
# while ScreenCaptureKit records Logic's window (with Logic's audio) and the client's Terminal window at the same time.
#
#   record_claude_take.sh prepare     build the capture tools, write the client dir, its MCP config and the Terminal profile
#   record_claude_take.sh launch      start Claude Code in tmux session `lpmdemo` and open the on-camera Terminal window
#   record_claude_take.sh start       start both captures (Logic + client); prints their first-frame epochs
#   record_claude_take.sh stop        stop both captures
#   record_claude_take.sh teardown    end the Claude session (and its server) and close the client window
#
# Run every subcommand from the terminal that holds Screen Recording and Accessibility (tmux -L logic-aqua). The
# requests are typed by typist.py; Claude chooses the tool calls. mcp_tap.py logs every JSON-RPC line unchanged.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
DEMO_DIR="${DEMO_DIR:-/private/tmp/logic-demo}"      # neutral path: the client's banner shows its working directory
SESSION="${SESSION:-lpmdemo}"
TITLE="Logic Pro MCP demo"
BIN="${LOGIC_PRO_MCP_BINARY:-$HERE/.cache/release/LogicProMCP}"
TMUX_CMD=(tmux -L logic-aqua)
mkdir -p raw out .cache

case "${1:?usage: record_claude_take.sh prepare|launch|start|stop|teardown}" in
prepare)
  [ -x .cache/LogicCapture ] || swiftc -O -parse-as-library -swift-version 5 -o .cache/LogicCapture capture/LogicCapture.swift
  [ -x .cache/TerminalProfile ] || swiftc -O -swift-version 5 -o .cache/TerminalProfile capture/TerminalProfile.swift
  mkdir -p "$DEMO_DIR"
  PY="$(command -v python3)"
  python3 - "$DEMO_DIR/mcp.json" "$PY" "$HERE/mcp_tap.py" "$HERE/out/claude-take.mcp.jsonl" "$BIN" <<'PY'
import json, sys
out, py, tap, log, binary = sys.argv[1:]
json.dump({"mcpServers": {"logic-pro": {"type": "stdio", "command": py, "args": [tap, "--log", log, "--", binary]}}},
          open(out, "w"), indent=2)
PY
  .cache/TerminalProfile --out "$DEMO_DIR/client.terminal" --command "tmux -L logic-aqua attach -t $SESSION" \
    --font-size "${FONT_SIZE:-30}" --cols "${COLS:-58}" --rows "${ROWS:-22}" --name "$TITLE"
  # Client chrome kept off camera (project settings; the launch line reads only these): no prompt suggestions (the grey
  # ghost text after a turn), no spinner tips, no update banner. No --permission-mode is passed, so the "don't ask on"
  # footer line is not shown either; the MCP tools are allowed and every built-in tool is denied instead.
  mkdir -p "$DEMO_DIR/.claude"
  cat > "$DEMO_DIR/.claude/settings.json" <<'JSON'
{
  "promptSuggestionEnabled": false,
  "spinnerTipsEnabled": false,
  "autoUpdatesChannel": "stable",
  "env": {
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "false",
    "DISABLE_AUTOUPDATER": "1",
    "DISABLE_UPDATES": "1"
  },
  "permissions": {
    "defaultMode": "default",
    "allow": ["mcp__logic-pro", "ListMcpResourcesTool", "ReadMcpResourceTool"],
    "deny": ["Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "WebSearch", "Task", "NotebookEdit"]
  }
}
JSON
  uuidgen | tr 'A-Z' 'a-z' > "$DEMO_DIR/session-id"
  echo "client dir $DEMO_DIR, session $(cat "$DEMO_DIR/session-id")"
  ;;
launch)
  SID="$(cat "$DEMO_DIR/session-id")"
  # Only the logic-pro server (--strict-mcp-config), no user settings, hooks or plugins (--setting-sources project),
  # and no permission prompts: the MCP tools and the two MCP resource tools are allowed, everything else is denied
  # (settings.json written by `prepare`). Suggestions, tips and the update banner are off (see `prepare`).
  CMD="cd $DEMO_DIR && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false DISABLE_AUTOUPDATER=1 exec claude --session-id $SID -n 'Logic Pro session' --strict-mcp-config --mcp-config $DEMO_DIR/mcp.json \
--setting-sources project --permission-mode default --allowedTools 'mcp__logic-pro,ListMcpResourcesTool,ReadMcpResourceTool' \
--model ${CLIENT_MODEL:-sonnet} --append-system-prompt 'You are working in a Logic Pro session through the logic-pro MCP server. Answer in one short sentence.'"
  "${TMUX_CMD[@]}" new-session -d -s "$SESSION" -x "${COLS:-58}" -y "${ROWS:-22}" "$CMD"
  "${TMUX_CMD[@]}" set-option -t "$SESSION" status off
  open "$DEMO_DIR/client.terminal"
  echo "launched $SESSION"
  ;;
start)
  rm -f raw/take.mov.stop raw/client.mov.stop
  # one after the other: two ScreenCaptureKit sessions starting at the same moment hang or fail with -3805
  .cache/LogicCapture --bundle com.apple.logic10 --out raw/take.mov --fps 60 --max-seconds "${MAX_SECONDS:-420}" > raw/take.capture.log 2>&1 &
  for _ in $(seq 1 150); do grep -q first_frame_epoch raw/take.capture.log 2>/dev/null && break; sleep 0.1; done
  .cache/LogicCapture --bundle com.apple.Terminal --title "${CLIENT_TITLE:-attach -t $SESSION}" --no-audio --out raw/client.mov --fps 60 --max-seconds "${MAX_SECONDS:-420}" > raw/client.capture.log 2>&1 &
  for _ in $(seq 1 150); do grep -q first_frame_epoch raw/client.capture.log 2>/dev/null && break; sleep 0.1; done
  python3 - <<'PY'
import json, re, sys
meta = {}
for name in ("take", "client"):
    for line in open(f"raw/{name}.capture.log"):
        m = re.search(r'"first_frame_epoch":([0-9.]+)', line)
        if m:
            meta[name] = float(m.group(1))
    if name not in meta:
        sys.exit(f"{name} capture did not start: " + open(f"raw/{name}.capture.log").read()[-400:])
json.dump(meta, open("raw/take.meta.json", "w"))
print(json.dumps(meta))
PY
  ;;
stop)
  touch raw/take.mov.stop raw/client.mov.stop
  for _ in $(seq 1 100); do
    grep -q '"finished"' raw/take.capture.log 2>/dev/null && grep -q '"finished"' raw/client.capture.log 2>/dev/null && break
    sleep 0.2
  done
  tail -n 1 raw/take.capture.log raw/client.capture.log
  ;;
teardown)
  "${TMUX_CMD[@]}" kill-session -t "$SESSION" 2>/dev/null || true
  sleep 1
  pkill -f "$DEMO_DIR/mcp.json" 2>/dev/null || true
  pkill -f "mcp_tap.py --log $HERE/out/claude-take.mcp.jsonl" 2>/dev/null || true
  pkill -xf "$BIN" 2>/dev/null || true
  pgrep -fl "$DEMO_DIR" || echo "no client processes left"
  ;;
*) echo "usage: record_claude_take.sh prepare|launch|start|stop|teardown" >&2; exit 2 ;;
esac
