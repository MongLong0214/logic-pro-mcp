#!/usr/bin/env python3
"""Pass-through stdio tap between an MCP client (Claude Code) and the LogicProMCP binary.

  mcp_tap.py --log take.jsonl -- /path/to/LogicProMCP [args...]

Bytes are forwarded unchanged in both directions, line by line (MCP stdio is newline-delimited JSON-RPC). Every line
is also written to the log with the wall-clock epoch at which the tap saw it, so the film can be aligned to the screen
capture and each call's round trip is measured at the server boundary, not inside the client. The tap never parses,
edits, delays, retries or answers anything itself; if the server exits, the tap exits with its code.
"""
import json
import subprocess
import sys
import threading
import time


def main():
    argv = sys.argv[1:]
    if "--log" not in argv or "--" not in argv:
        sys.exit("usage: mcp_tap.py --log FILE -- SERVER [ARGS...]")
    log_path = argv[argv.index("--log") + 1]
    cmd = argv[argv.index("--") + 1:]
    log = open(log_path, "a", buffering=1)
    lock = threading.Lock()

    def record(direction, raw):
        entry = {"t_epoch": time.time(), "dir": direction}
        try:
            entry["msg"] = json.loads(raw)
        except ValueError:
            entry["raw"] = raw.decode("utf-8", "replace")
        with lock:
            log.write(json.dumps(entry, ensure_ascii=False) + "\n")

    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    record("tap", json.dumps({"event": "start", "cmd": cmd, "pid": proc.pid}).encode())

    def upstream():  # client -> server
        try:
            for line in iter(sys.stdin.buffer.readline, b""):
                proc.stdin.write(line)
                proc.stdin.flush()
                record("c2s", line.strip())
        except (BrokenPipeError, OSError):
            pass
        try:
            proc.stdin.close()
        except OSError:
            pass

    threading.Thread(target=upstream, daemon=True).start()
    out = sys.stdout.buffer
    for line in iter(proc.stdout.readline, b""):
        out.write(line)
        out.flush()
        record("s2c", line.strip())
    code = proc.wait()
    record("tap", json.dumps({"event": "exit", "code": code}).encode())
    sys.exit(code)


if __name__ == "__main__":
    main()
