#!/usr/bin/env python3
"""Direct stdio proxy to the Logic Pro MCP server — bypasses Cursor's cached connection state."""
import subprocess
import json
import sys
import threading
import queue
import os
import shutil

def resolve_logic_server() -> str:
    override = os.environ.get("LOGIC_PRO_MCP_BIN", "").strip()
    if override:
        return override
    found = shutil.which("LogicProMCP")
    if found:
        return found
    return "LogicProMCP"

def main():
    logic_bin = resolve_logic_server()
    if logic_bin != "LogicProMCP" and not os.path.isfile(logic_bin):
        print(f"ERROR: LogicProMCP binary not found at {logic_bin}", file=sys.stderr)
        sys.exit(127)
    if logic_bin == "LogicProMCP" and shutil.which("LogicProMCP") is None:
        print(
            "ERROR: LogicProMCP not on PATH. Install with Homebrew or set LOGIC_PRO_MCP_BIN.",
            file=sys.stderr,
        )
        sys.exit(127)

    proc = subprocess.Popen(
        [logic_bin],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=os.environ.copy(),
    )

    request_id = 0
    def next_id():
        nonlocal request_id
        request_id += 1
        return request_id

    def send(msg):
        data = json.dumps(msg) + "\n"
        proc.stdin.write(data.encode())
        proc.stdin.flush()
        print(f">>> {json.dumps(msg)[:300]}", file=sys.stderr)

    def read_response():
        line = b""
        while True:
            ch = proc.stdout.read(1)
            if not ch:
                return None
            line += ch
            if ch == b"\n":
                try:
                    return json.loads(line.decode().strip())
                except json.JSONDecodeError:
                    continue

    def read_thread(q):
        while True:
            resp = read_response()
            if resp is None:
                break
            q.put(resp)

    resp_queue = queue.Queue()
    t = threading.Thread(target=read_thread, args=(resp_queue,), daemon=True)
    t.start()

    # --- Initialize ---
    send({
        "jsonrpc": "2.0",
        "id": next_id(),
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "proxy", "version": "1.0"}
        }
    })

    init_resp = None
    deadline = 0
    while init_resp is None and deadline < 30:
        try:
            msg = resp_queue.get(timeout=1.0)
            if "result" in msg or "error" in msg:
                init_resp = msg
                print(f"<<< {json.dumps(msg)[:500]}", file=sys.stderr)
            else:
                print(f"<<< (notif) {json.dumps(msg)[:300]}", file=sys.stderr)
        except queue.Empty:
            deadline += 1

    if init_resp is None:
        print("ERROR: No initialize response", file=sys.stderr)
        proc.kill()
        sys.exit(1)

    if "error" in init_resp:
        print(f"INITIALIZE ERROR: {json.dumps(init_resp['error'])}", file=sys.stderr)
        proc.kill()
        sys.exit(1)

    print(f"INITIALIZED: {json.dumps(init_resp.get('result', {}).get('serverInfo', {}))}", file=sys.stderr)

    # Send initialized notification
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    # --- List tools ---
    send({"jsonrpc": "2.0", "id": next_id(), "method": "tools/list"})

    tools_resp = None
    deadline = 0
    while tools_resp is None and deadline < 30:
        try:
            msg = resp_queue.get(timeout=1.0)
            if "result" in msg or "error" in msg:
                tools_resp = msg
                print(f"<<< tools/list response received", file=sys.stderr)
            else:
                print(f"<<< (notif) {json.dumps(msg)[:300]}", file=sys.stderr)
        except queue.Empty:
            deadline += 1

    if tools_resp is None:
        print("ERROR: No tools/list response", file=sys.stderr)
        proc.kill()
        sys.exit(1)

    tools = tools_resp.get("result", {}).get("tools", [])
    print(f"\n=== AVAILABLE TOOLS ({len(tools)}) ===", file=sys.stderr)
    for tool in tools:
        print(f"  - {tool['name']}: {tool.get('description', '')[:120]}", file=sys.stderr)

    # Output tools as JSON to stdout
    print(json.dumps({"tools": tools, "serverInfo": init_resp.get("result", {}).get("serverInfo", {})}))

    proc.kill()

if __name__ == "__main__":
    main()
