"""A stdio MCP client for one LogicProMCP binary, recording every byte both ways.

Protocol details kept from Scripts/livekit/evidence.py:750-956 (`Driver`), which learned them live:

- newline-delimited JSON-RPC 2.0; `initialize` with protocolVersion 2024-11-05, then the
  `notifications/initialized` notification (evidence.py:782-786);
- tool arguments nest as {"command", "params"} under `arguments` (evidence.py:872-884);
- a tool body is `structuredContent` when present, else the JSON in the text content
  (evidence.py:945-955); a resource body is the JSON text of `contents[0]` (evidence.py:886-891);
- the server's stderr goes to a FILE, not a pipe: nothing drains a pipe while the client waits on
  stdout, so a pipe deadlocks the server once full (evidence.py:762-768);
- LOG_LEVEL is pinned to info, not inherited (evidence.py:772-776).

What this adds, because the audit (audit-A-report.md section 2b) found evidence.py cutting it:

- The transcript: every line sent and every line received, raw and untruncated, each stamped with
  the monotonic clock. Lines that are not JSON are kept too, marked.
- A per-call timeout that is reported as `timed_out: True`, distinct from a reply that is an error
  and from a server that exited (`server_exited: True`). Replies are matched by id; a reply that
  arrives after its call timed out stays in the transcript as late.
- A stop that is verified: stdin closed, then terminate, then kill, each bounded, and the pid is
  checked gone afterwards (`pid_gone`).
"""

import json
import os
import queue
import subprocess
import tempfile
import threading

from . import obs

PROTOCOL_VERSION = "2024-11-05"
CLIENT_INFO = {"name": "lpm-verify", "version": "1"}


def body_of_tool_reply(reply):
    """The tool body a JSON-RPC reply carries (evidence.py:945-955); None fields stay visible."""
    if not isinstance(reply, dict) or "result" not in reply:
        return {"_no_result": reply}
    result = reply["result"] or {}
    if result.get("structuredContent") is not None:
        return result["structuredContent"]
    text = "".join(c.get("text", "") for c in result.get("content") or [] if isinstance(c, dict))
    try:
        return json.loads(text)
    except ValueError:
        return {"_text": text}


def body_of_resource_reply(reply):
    try:
        return json.loads(reply["result"]["contents"][0]["text"])
    except (KeyError, IndexError, TypeError, ValueError):
        return {"_no_contents": reply}


class Server:
    """One server process. Use `start()`, the calls, then `stop()` (also on failure)."""

    def __init__(self, binary, env=None, stderr_dir=None, argv=None):
        self.binary = binary
        self.argv = argv or [binary]
        self.extra_env = dict(env or {})
        self.stderr_dir = stderr_dir
        self.transcript = []
        self.proc = None
        self._next_id = 0
        self._inbox = queue.Queue()
        self._pending = {}
        self._reader = None
        self._lock = threading.Lock()
        self.stderr_path = None
        self.start_record = None
        self.stop_record = None

    # -- transport ------------------------------------------------------------------------------

    def _record(self, direction, raw):
        entry = {"t": obs.now(), "dir": direction, "raw": raw}
        try:
            entry["json"] = json.loads(raw)
        except ValueError:
            entry["not_json"] = True
        with self._lock:
            self.transcript.append(entry)
        return entry

    def _read_loop(self):
        stream = self.proc.stdout
        for line in iter(stream.readline, ""):
            text = line.rstrip("\n")
            if not text.strip():
                continue
            entry = self._record("recv", text)
            self._inbox.put(entry)
        self._inbox.put({"t": obs.now(), "dir": "eof"})

    def _write(self, message):
        raw = json.dumps(message, ensure_ascii=False)
        self._record("send", raw)
        self.proc.stdin.write(raw + "\n")
        self.proc.stdin.flush()

    # -- lifecycle ------------------------------------------------------------------------------

    def start(self, init_timeout_s=60.0):
        """Spawn, then initialize. Returns the raw start record (also kept as `start_record`)."""
        env = dict(os.environ, LOG_LEVEL="info")
        env.update(self.extra_env)
        handle = tempfile.NamedTemporaryFile(prefix="lpm-verify-server-", suffix=".stderr.log",
                                             dir=self.stderr_dir, delete=False)
        self.stderr_path = handle.name
        try:
            self.proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=handle, text=True, bufsize=1, env=env)
        except OSError as exc:
            handle.close()
            self.start_record = {"spawned": False, "cause": repr(exc), "argv": self.argv}
            return self.start_record
        handle.close()
        self._reader = threading.Thread(target=self._read_loop, name="mcp-reader", daemon=True)
        self._reader.start()
        init = self.request("initialize", {"protocolVersion": PROTOCOL_VERSION,
                                           "capabilities": {}, "clientInfo": CLIENT_INFO},
                            timeout_s=init_timeout_s)
        if init.get("reply") is not None and "result" in init["reply"]:
            self._write({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        self.start_record = {"spawned": True, "pid": self.proc.pid, "argv": self.argv,
                             "env_overrides": {"LOG_LEVEL": "info", **self.extra_env},
                             "stderr_path": self.stderr_path, "initialize": init}
        return self.start_record

    @property
    def pid(self):
        return self.proc.pid if self.proc else None

    def request(self, method, params=None, timeout_s=60.0):
        """One JSON-RPC request; the raw reply, or `timed_out` / `server_exited` saying why not."""
        if self.proc is None:
            return {"method": method, "sent": False, "cause": "server not started"}
        self._next_id += 1
        rid = self._next_id
        message = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}
        started = obs.now()
        try:
            self._write(message)
        except (BrokenPipeError, OSError) as exc:
            return {"id": rid, "method": method, "sent": False, "cause": repr(exc),
                    "server_exited": self.proc.poll() is not None}
        deadline = started + timeout_s
        while True:
            if rid in self._pending:
                entry = self._pending.pop(rid)
                return {"id": rid, "method": method, "sent": True, "reply": entry["json"],
                        "t_sent": started, "t_reply": entry["t"],
                        "elapsed_s": entry["t"] - started, "timed_out": False}
            remaining = deadline - obs.now()
            if remaining <= 0:
                return {"id": rid, "method": method, "sent": True, "reply": None,
                        "t_sent": started, "elapsed_s": obs.now() - started, "timed_out": True}
            try:
                entry = self._inbox.get(timeout=remaining)
            except queue.Empty:
                continue
            if entry["dir"] == "eof":
                self._inbox.put(entry)
                return {"id": rid, "method": method, "sent": True, "reply": None,
                        "t_sent": started, "elapsed_s": obs.now() - started, "timed_out": False,
                        "server_exited": True, "returncode": self.proc.poll()}
            payload = entry.get("json")
            if isinstance(payload, dict) and "id" in payload and (
                    "result" in payload or "error" in payload):
                self._pending[payload["id"]] = entry

    def tool(self, name, command, params=None, timeout_s=120.0):
        """tools/call with {"command", "params"}; the parsed body beside the raw request record."""
        arguments = {"command": command}
        if params is not None:
            arguments["params"] = params
        call = self.request("tools/call", {"name": name, "arguments": arguments}, timeout_s)
        call["body"] = body_of_tool_reply(call.get("reply")) if call.get("reply") else None
        return call

    def resource(self, uri, timeout_s=60.0):
        call = self.request("resources/read", {"uri": uri}, timeout_s)
        call["body"] = body_of_resource_reply(call.get("reply")) if call.get("reply") else None
        return call

    def stderr_text(self):
        if not self.stderr_path:
            return obs.unreadable("no stderr file")
        try:
            with open(self.stderr_path, "r", encoding="utf-8", errors="replace") as handle:
                return obs.readable(handle.read())
        except OSError as exc:
            return obs.unreadable(repr(exc))

    def stop(self, grace_s=5.0):
        """Close stdin, then terminate, then kill; verify the pid is gone. Returns the record."""
        if self.proc is None:
            self.stop_record = {"stopped": False, "cause": "never started"}
            return self.stop_record
        steps = []
        pid = self.proc.pid
        for step in ("close_stdin", "terminate", "kill"):
            if self.proc.poll() is not None:
                break
            try:
                if step == "close_stdin":
                    self.proc.stdin.close()
                elif step == "terminate":
                    self.proc.terminate()
                else:
                    self.proc.kill()
            except OSError as exc:
                steps.append({"step": step, "error": repr(exc)})
                continue
            try:
                self.proc.wait(timeout=grace_s)
                steps.append({"step": step, "exited": True, "returncode": self.proc.returncode})
            except subprocess.TimeoutExpired:
                steps.append({"step": step, "exited": False})
        if self._reader is not None:
            self._reader.join(timeout=grace_s)
        try:
            os.kill(pid, 0)
            gone = False
        except ProcessLookupError:
            gone = True
        except PermissionError:
            gone = False
        self.stop_record = {"pid": pid, "steps": steps, "returncode": self.proc.returncode,
                            "pid_gone": gone,
                            "reader_finished": self._reader is None or not self._reader.is_alive()}
        return self.stop_record

    def record(self):
        """Everything this server saw, raw: start, transcript, stderr, stop."""
        return {"binary": self.binary, "start": self.start_record, "transcript": self.transcript,
                "stderr": self.stderr_text(), "stop": self.stop_record}
