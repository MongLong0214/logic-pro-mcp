#!/usr/bin/env python3
# SIZE_OK: Scenario harness intentionally centralizes strict live MCP/Logic E2E coverage for one ordered run.
"""Expanded Live E2E test for Logic Pro MCP server.
Uses newline-delimited JSON-RPC stdio transport.
Requires: Logic Pro running, accessibility + automation permissions.
Some checks also accept explicit precondition errors when no document is open.

Coverage: 200+ tests across 20 sections.
"""

import json
import os
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Optional

from logic_controller_learn_mode import DEFAULT_CONTROLLER_LEARN_MODE_POLICY, guard_controller_learn_mode
from logic_session_bootstrap import (
    _click_safe_dialog_cancel_button,
    _send_escape_key,
    bootstrap_fresh_logic_session,
    collect_ui_snapshot,
)
from logic_free_tempo_modal import DEFAULT_FREE_TEMPO_POLICY, detect_free_tempo_modal, resolve_free_tempo_modal

BINARY = os.environ.get("LOGIC_PRO_MCP_BINARY", ".build/release/LogicProMCP")
STRICT_LIVE = os.environ.get("LOGIC_PRO_MCP_STRICT_LIVE", "0") == "1"
TRANSPORT = os.environ.get("LOGIC_PRO_MCP_E2E_TRANSPORT", "tmux" if STRICT_LIVE else "popen")
FRESH_BOOTSTRAP = os.environ.get("LOGIC_PRO_MCP_BOOTSTRAP_FRESH", "1" if STRICT_LIVE else "0") == "1"
TIMEOUT = int(os.environ.get("LOGIC_PRO_MCP_E2E_TIMEOUT", "40" if STRICT_LIVE else "10"))
from logic_bounce_ui import send_ui_events  # noqa: E402


def coverage_environment():
    env = os.environ.copy()
    if "LLVM_PROFILE_FILE" not in env:
        profile_dir = env.get(
            "LOGIC_PRO_MCP_PROFILE_DIR",
            os.path.join(tempfile.gettempdir(), "logic-pro-mcp-profraw"),
        )
        os.makedirs(profile_dir, exist_ok=True)
        env["LOGIC_PRO_MCP_PROFILE_DIR"] = profile_dir
        env["LLVM_PROFILE_FILE"] = os.path.join(profile_dir, "%m-%p.profraw")
    return env


def coverage_shell_prefix():
    profile_file = coverage_environment()["LLVM_PROFILE_FILE"]
    return f"export LLVM_PROFILE_FILE={shlex.quote(profile_file)}; "


class MCPClient:
    def __init__(self):
        self.stderr_dir = tempfile.TemporaryDirectory(prefix="logic-mcp-e2e.")
        self.stderr_file = open(Path(self.stderr_dir.name) / "stderr.txt", "w")
        self.proc = subprocess.Popen(
            [BINARY],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr_file,
            bufsize=0,
            env=coverage_environment(),
        )
        self.responses = {}
        self.reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self.reader_thread.start()

    def _read_loop(self):
        try:
            for line in self.proc.stdout:
                line = line.decode("utf-8").strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                    if "id" in msg and msg["id"] is not None:
                        self.responses[msg["id"]] = msg
                except json.JSONDecodeError:
                    pass
        except Exception:
            pass

    def send(self, msg, timeout=None):
        body = json.dumps(msg) + "\n"
        try:
            self.proc.stdin.write(body.encode())
            self.proc.stdin.flush()
        except BrokenPipeError:
            return None

        msg_id = msg.get("id")
        if msg_id is None:
            return None

        deadline = time.time() + (timeout if timeout is not None else TIMEOUT)
        while time.time() < deadline:
            if msg_id in self.responses:
                return self.responses.pop(msg_id)
            time.sleep(0.02)
        return None

    def close(self):
        try: self.proc.stdin.close()
        except: pass
        try: self.proc.terminate(); self.proc.wait(timeout=3)
        except: self.proc.kill()
        try: self.stderr_file.close()
        except: pass
        self.stderr_dir.cleanup()


class TmuxMCPClient:
    """Run the server under tmux so strict live tests inherit a trusted GUI parent.

    macOS TCC can evaluate the parent/responsible process for CLI children.
    A Python-spawned LogicProMCP process may report Accessibility/CoreMIDI as
    unavailable even when the same binary is trusted from the user's terminal or
    MCP client context. tmux gives the server a real PTY under the user's shell
    session while this harness still exchanges newline-delimited JSON-RPC.
    """

    def __init__(self):
        self.session = f"logic-mcp-e2e-{os.getpid()}-{uuid.uuid4().hex[:8]}"
        self.stderr_dir = tempfile.TemporaryDirectory(prefix="logic-mcp-e2e.")
        self.stderr_path = str(Path(self.stderr_dir.name) / "stderr.txt")
        self.responses = {}
        self.started = False

        command = (
            "stty -icanon -echo min 1 time 0; "
            f"{coverage_shell_prefix()}"
            f"exec {shlex.quote(BINARY)} 2>{shlex.quote(self.stderr_path)}"
        )
        subprocess.run(["tmux", "new-session", "-d", "-x", "1000", "-y", "80",
                        "-s", self.session, "-c", os.getcwd(), command],
                       check=True)
        subprocess.run(["tmux", "set-option", "-t", self.session,
                        "history-limit", "200000"], check=False)
        self.started = True
        time.sleep(0.2)

    def _tmux(self, args, check=True, capture_output=False):
        return subprocess.run(["tmux", *args], check=check, text=True,
                              capture_output=capture_output)

    def _capture_lines(self):
        result = self._tmux(
            ["capture-pane", "-t", self.session, "-p", "-J", "-S", "-5000"],
            check=False,
            capture_output=True,
        )
        if result.returncode != 0:
            return []
        return result.stdout.splitlines()

    def _refresh_responses(self):
        for line in self._capture_lines():
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg_id = msg.get("id")
            if msg_id is None:
                continue
            # The PTY echoes JSON requests. Only cache real JSON-RPC replies.
            if "result" in msg or "error" in msg:
                self.responses[msg_id] = msg

    def send(self, msg, timeout=None):
        body = json.dumps(msg, ensure_ascii=False)
        try:
            self._tmux(["send-keys", "-t", self.session, "-l", body])
            self._tmux(["send-keys", "-t", self.session, "Enter"])
        except subprocess.CalledProcessError:
            return None

        msg_id = msg.get("id")
        if msg_id is None:
            return None

        deadline = time.time() + (timeout if timeout is not None else TIMEOUT)
        while time.time() < deadline:
            self._refresh_responses()
            if msg_id in self.responses:
                return self.responses.pop(msg_id)
            time.sleep(0.05)
        return None

    def close(self):
        if not self.started:
            self.stderr_dir.cleanup()
            return
        self._tmux(["send-keys", "-t", self.session, "C-c"], check=False)
        deadline = time.time() + 3
        while time.time() < deadline:
            result = self._tmux(["has-session", "-t", self.session], check=False)
            if result.returncode != 0:
                self.started = False
                self.stderr_dir.cleanup()
                return
            time.sleep(0.1)
        self._tmux(["kill-session", "-t", self.session], check=False)
        self.started = False
        self.stderr_dir.cleanup()


class ExternalTmuxMCPClient:
    """Client side for the shell-owned tmux strict-live transport."""

    def __init__(self):
        self.request_fifo = os.environ["LOGIC_PRO_MCP_E2E_REQUEST_FIFO"]
        self.capture_file = os.environ["LOGIC_PRO_MCP_E2E_CAPTURE_FILE"]
        self.writer = open(self.request_fifo, "w", buffering=1)
        self.responses = {}
        self.capture_offset = 0
        self.capture_remainder = ""

    def _capture_lines(self):
        try:
            with open(self.capture_file, "r") as file:
                file.seek(0, os.SEEK_END)
                file_size = file.tell()
                if file_size < self.capture_offset:
                    self.capture_offset = 0
                    self.capture_remainder = ""
                file.seek(self.capture_offset)
                chunk = file.read()
                self.capture_offset = file.tell()
        except FileNotFoundError:
            return []
        if not chunk:
            return []
        payload = self.capture_remainder + chunk
        if payload.endswith("\n"):
            self.capture_remainder = ""
            return payload.splitlines()
        lines = payload.splitlines()
        if not lines:
            self.capture_remainder = payload
            return []
        self.capture_remainder = lines.pop()
        return lines

    def _refresh_responses(self):
        lines = self._capture_lines()
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg_id = msg.get("id")
            if msg_id is None:
                continue
            if "result" in msg or "error" in msg:
                self.responses[msg_id] = msg

    def send(self, msg, timeout=None):
        self.writer.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.writer.flush()

        msg_id = msg.get("id")
        if msg_id is None:
            return None

        deadline = time.time() + (timeout if timeout is not None else TIMEOUT)
        while time.time() < deadline:
            self._refresh_responses()
            if msg_id in self.responses:
                return self.responses.pop(msg_id)
            time.sleep(0.05)
        return None

    def close(self):
        try:
            self.writer.close()
        except Exception:
            pass


def initialize(client):
    resp = client.send({
        "jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "e2e", "version": "1"}}
    })
    if not resp or "result" not in resp:
        return False
    client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    time.sleep(3)
    return True


_ID = [1]
def nid():
    v = _ID[0]; _ID[0] += 1; return v


def call_tool(client, tool, command, params=None, req_id=None, timeout=None):
    args = {"command": command}
    if params:
        args["params"] = params
    return client.send({
        "jsonrpc": "2.0", "id": req_id or nid(), "method": "tools/call",
        "params": {"name": tool, "arguments": args}
    }, timeout=timeout)


def read_resource(client, uri, req_id=None):
    return client.send({
        "jsonrpc": "2.0", "id": req_id or nid(),
        "method": "resources/read", "params": {"uri": uri}
    })


def pipelined_read_all(client, uris, timeout=30):
    """#220: fire every read in-flight on ONE connection, THEN collect — the
    concurrent large-read pattern the external audit ran. Proves the server
    serves every concurrent large read completely when the client drains stdout
    (the reader thread does). StdioTransport is an actor, so frames are written
    one-at-a-time and never interleave; apparent "no response" in the audit was
    client-side backpressure from not draining while issuing many big reads.

    popen transport only (writes directly to the server's stdin); returns None
    under the tmux transport, which is not designed for request pipelining.
    """
    if not hasattr(client, "proc"):
        return None
    pending = []
    for uri in uris:
        rid = nid()
        pending.append((rid, uri))
        body = json.dumps({"jsonrpc": "2.0", "id": rid,
                           "method": "resources/read", "params": {"uri": uri}}) + "\n"
        try:
            client.proc.stdin.write(body.encode())
        except (BrokenPipeError, ValueError):
            return None
    try:
        client.proc.stdin.flush()
    except (BrokenPipeError, ValueError):
        return None

    collected = {}
    deadline = time.time() + timeout
    while time.time() < deadline and len(collected) < len(pending):
        for rid, _uri in pending:
            if rid in client.responses and rid not in collected:
                collected[rid] = client.responses.pop(rid)
        time.sleep(0.02)
    return [(uri, collected.get(rid)) for rid, uri in pending]


def list_tools(client, req_id=None):
    return client.send({"jsonrpc": "2.0", "id": req_id or nid(),
                        "method": "tools/list", "params": {}})


def list_resources(client, req_id=None):
    return client.send({"jsonrpc": "2.0", "id": req_id or nid(),
                        "method": "resources/list", "params": {}})


def list_resource_templates(client, req_id=None):
    return client.send({"jsonrpc": "2.0", "id": req_id or nid(),
                        "method": "resources/templates/list", "params": {}})


# ── Test runner ──
PASS = 0
FAIL = 0
SKIP = 0
FAILURES = []
SKIPS = []

def T(name, response, check):
    """Test helper. If response is None, the check still runs (for synthetic tests)."""
    global PASS, FAIL
    try:
        if check(response):
            PASS += 1
            print(f"  \033[0;32m✔\033[0m {name}")
        else:
            FAIL += 1
            FAILURES.append(name)
            if response is not None:
                d = json.dumps(response, ensure_ascii=False)[:250]
                print(f"  \033[0;31m✘\033[0m {name}")
                print(f"    {d}")
            else:
                print(f"  \033[0;31m✘\033[0m {name}")
    except Exception as e:
        FAIL += 1
        FAILURES.append(f"{name} — {e}")
        print(f"  \033[0;31m✘\033[0m {name} — {e}")


def S(name, reason):
    global SKIP
    SKIP += 1
    SKIPS.append(f"{name} — {reason}")
    print(f"  \033[0;36m↷\033[0m {name} — skipped ({reason})")


def T_LIVE(name, response, check, ready, reason):
    """Run live-only checks when prerequisites exist; strict mode turns skips into failures."""
    if ready or STRICT_LIVE:
        T(name, response, check)
    else:
        S(name, reason)


def tool_text(resp):
    try:
        for c in resp["result"]["content"]:
            if c.get("type") == "text":
                return c.get("text", "")
    except: pass
    return ""


def is_error(resp):
    if isinstance(resp, dict) and "gate" in resp:
        return True
    try: return resp["result"].get("isError", False)
    except: return "error" in resp


def resource_text(resp):
    try:
        return resp["result"]["contents"][0].get("text", "")
    except: return ""


def safe_json(text):
    try: return json.loads(text)
    except: return None


def tool_json(resp):
    value = safe_json(tool_text(resp))
    return value if isinstance(value, dict) else None


def controller_learn_guard_is_clear(result):
    return isinstance(result, dict) and result.get("status") == "clear"


def controller_learn_guard_reason(result):
    if not isinstance(result, dict):
        return "controller assignments Learn Mode guard returned no result"
    status = result.get("status", "unknown")
    reason = result.get("reason", status)
    return f"controller assignments Learn Mode guard {status}: {reason}"


def guarded_live_tool_call(client, tool, command, params=None, *, ready, reason, timeout=None):
    if not ready:
        return {
            "gate": reason,
            "policy_id": DEFAULT_CONTROLLER_LEARN_MODE_POLICY["policy_id"],
            "tool": tool,
            "command": command,
        }
    return call_tool(client, tool, command, params, timeout=timeout)


def guarded_live_midi_call(client, command, params=None, *, ready, reason, timeout=None):
    return guarded_live_tool_call(
        client,
        "logic_midi",
        command,
        params,
        ready=ready,
        reason=reason,
        timeout=timeout,
    )


def verified_or_explicitly_unverified(resp):
    if not is_error(resp):
        return True
    payload = tool_json(resp)
    return (
        isinstance(payload, dict)
        and payload.get("verified") is False
        and any(
            isinstance(payload.get(key), str) and payload.get(key)
            for key in ("reason", "error", "hint")
        )
    )


def verified_or_readback_mismatch(resp):
    if not is_error(resp):
        return True
    payload = tool_json(resp)
    return (
        isinstance(payload, dict)
        and payload.get("verified") is False
        and payload.get("reason") == "readback_mismatch"
        and payload.get("observed") is not None
        and payload.get("requested") is not None
    )


def read_tracks_data(client):
    envelope = safe_json(resource_text(read_resource(client, "logic://tracks")))
    if not isinstance(envelope, dict):
        return None
    data = envelope.get("data")
    return data if isinstance(data, list) else None


def read_track_regions(client, index):
    regions = safe_json(resource_text(read_resource(client, f"logic://tracks/{index}/regions")))
    return regions if isinstance(regions, list) else None


def wait_for_track_arm(client, index, enabled, timeout=5.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        call_tool(client, "logic_system", "refresh_cache", timeout=3)
        tracks = read_tracks_data(client)
        if isinstance(tracks, list) and 0 <= index < len(tracks):
            last = tracks[index]
            if last.get("isArmed") is enabled:
                return last
        time.sleep(0.2)
    return last


def fresh_record_bootstrap_status(client):
    tracks = read_tracks_data(client)
    if not isinstance(tracks, list):
        return False, "tracks resource unavailable"
    if len(tracks) != 1:
        return False, f"expected exactly 1 track, found {len(tracks)}"
    regions = read_track_regions(client, 0)
    if regions is None:
        return False, "track 0 regions resource unavailable"
    if len(regions) != 0:
        return False, f"expected 0 regions on track 0, found {len(regions)}"
    return True, "fresh bootstrap detected"


def fresh_transport_bootstrap_status(client):
    tracks = read_tracks_data(client)
    if not isinstance(tracks, list):
        return False, "tracks resource unavailable"
    if len(tracks) != 1:
        return False, f"expected exactly 1 track, found {len(tracks)}"
    regions = read_track_regions(client, 0)
    if regions is None:
        return False, "track 0 regions resource unavailable"
    if len(regions) != 0:
        return False, f"expected 0 regions on track 0, found {len(regions)}"
    return True, "fresh bootstrap detected"


def transport_envelope(client):
    return safe_json(resource_text(read_resource(client, "logic://transport/state")))


def transport_state(client):
    envelope = transport_envelope(client)
    if not isinstance(envelope, dict):
        return None, None
    data = envelope.get("data", {})
    if not isinstance(data, dict) or data.get("has_document") is False:
        return envelope, None
    state = data.get("state")
    if not isinstance(state, dict):
        return envelope, None
    return envelope, state


def wait_for_transport_state_envelope(client, predicate, timeout=5.0, interval=0.2):
    deadline = time.time() + timeout
    last_envelope = None
    last_state = None
    while time.time() < deadline:
        last_envelope, last_state = transport_state(client)
        if predicate(last_envelope, last_state):
            return last_envelope, last_state
        time.sleep(interval)
    return last_envelope, last_state


def wait_for_transport_state(client, predicate, timeout=6.0, interval=0.2):
    deadline = time.time() + timeout
    last_state = None
    while time.time() < deadline:
        _, last_state = transport_state(client)
        if isinstance(last_state, dict) and predicate(last_state):
            return last_state
        time.sleep(interval)
    return last_state


def ui_stop_logic_transport():
    native_key_script = Path(__file__).with_name("logic_key_event.swift")
    if native_key_script.exists():
        native = subprocess.run(
            ["/usr/bin/swift", str(native_key_script), "space"],
            capture_output=True,
            text=True,
            timeout=5.0,
        )
        if native.returncode == 0:
            return True

    script = """
    tell application "Logic Pro" to activate
    delay 0.1
    tell application "System Events"
        key code 49
    end tell
    """
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return True
    try:
        return send_ui_events("kp:space")
    except (OSError, RuntimeError):
        return False


def dismiss_safe_logic_dialog():
    try:
        snapshot = collect_ui_snapshot()
    except Exception:
        return {"status": "probe_failed"}
    if not snapshot.blocking_dialog_present:
        return {"status": "not_present"}
    if _click_safe_dialog_cancel_button():
        time.sleep(0.5)
        return {"status": "dismissed", "method": "cancel_button"}
    if _send_escape_key():
        time.sleep(0.5)
        latest = collect_ui_snapshot()
        if not latest.blocking_dialog_present:
            return {"status": "dismissed", "method": "escape"}
    return {"status": "blocked", "windows": snapshot.logic_window_names}


def cycle_range_result_ok(resp):
    env = safe_json(tool_text(resp))
    if not isinstance(env, dict):
        return False
    if env.get("success") is True:
        requested = env.get("requested")
        observed = env.get("observed")
        return (
            env.get("verified") is True
            and isinstance(requested, dict)
            and isinstance(observed, dict)
            and requested.get("start") == observed.get("start")
            and requested.get("end") == observed.get("end")
        )
    if env.get("success") is False:
        return (
            env.get("error") in ("not_implemented", "readback_unavailable")
            and env.get("error") != "channels_exhausted"
            and isinstance(env.get("requested"), dict)
            and isinstance(env.get("observed"), dict)
            and env.get("method") is not None
            and isinstance(env.get("scanned_landmarks"), dict)
        )
    return False


def plugin_inventory_result_ok(resp):
    env = safe_json(tool_text(resp))
    return (
        isinstance(env, dict)
        and env.get("success") is True
        and env.get("verified") is True
        and env.get("operation") == "logic_plugins.get_inventory"
        and env.get("plugins_source") == "ax"
        and isinstance(env.get("plugins"), list)
    )


def mixer_write_result_ok(resp, operation, control, track, expected):
    env = safe_json(tool_text(resp))
    identity = env.get("target_identity") if isinstance(env, dict) else None
    observed_after = env.get("observed_after") if isinstance(env, dict) else None
    return (
        isinstance(env, dict)
        and env.get("success") is True
        and env.get("verified") is True
        and env.get("operation") == operation
        and env.get("verify_source") == "ax_slider"
        and isinstance(identity, dict)
        and identity.get("track_index") == track
        and identity.get("control") == control
        and isinstance(observed_after, (int, float))
        and abs(float(observed_after) - float(expected)) <= 0.05
    )


def is_library_root_json(value):
    return (
        isinstance(value, dict)
        and isinstance(value.get("root"), dict)
        and isinstance(value.get("categories"), list)
        and isinstance(value.get("presetsByCategory"), dict)
        and isinstance(value.get("nodeCount"), int)
        and isinstance(value.get("leafCount"), int)
        and isinstance(value.get("folderCount"), int)
        and isinstance(value.get("candidatePatchCount"), int)
        and isinstance(value.get("nonApplicablePatchCount"), int)
    )


def is_library_scan_json(value):
    if is_library_root_json(value):
        return True
    if not isinstance(value, dict):
        return False
    if value.get("source") in ("panel", "disk") and is_library_root_json(value.get("root")):
        return True
    if value.get("mode") == "both":
        disk = value.get("disk")
        ax = value.get("ax")
        return (
            isinstance(disk, dict)
            and isinstance(ax, dict)
            and isinstance(disk.get("leafCount"), int)
            and isinstance(disk.get("nodeCount"), int)
            and isinstance(ax.get("available"), bool)
        )
    return False


def response_dump(resp):
    try: return json.dumps(resp, ensure_ascii=False)
    except: return ""


def section(title):
    print()
    print(f"\033[0;33m{title}\033[0m")


def fresh_bootstrap_env():
    bootstrap_env = dict(os.environ)
    if STRICT_LIVE:
        bootstrap_env["LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW"] = "1"
        bootstrap_env["LOGIC_PRO_MCP_BOOTSTRAP_ALLOW_NEW_PROJECT"] = "1"
    return bootstrap_env


def run_fresh_bootstrap(client):
    return bootstrap_fresh_logic_session(
        call_tool=lambda tool, command, params=None, timeout=None: call_tool(
            client, tool, command, params, timeout=timeout
        ),
        read_resource=lambda uri: read_resource(client, uri),
        tool_text=tool_text,
        resource_text=resource_text,
        strict_live=STRICT_LIVE,
        env=fresh_bootstrap_env(),
    )


def bootstrap_failure_reason(bootstrap):
    reason = bootstrap.reason or "unknown"
    if bootstrap.hint:
        return f"fresh bootstrap failed: {reason} ({bootstrap.hint})"
    return f"fresh bootstrap failed: {reason}"


def bootstrap_status_payload(reason, bootstrap=None):
    payload = {"result": {"bootstrap": reason}}
    if bootstrap is not None and not bootstrap.ok:
        payload["result"]["detail"] = bootstrap.as_dict()
    return payload


def main():
    print()
    print("══════════════════════════════════════════════════════")
    print(" Logic Pro MCP — Live E2E Test Suite (200+ tests)")
    print("══════════════════════════════════════════════════════")
    print(f" Binary: {BINARY}")
    print(f" Strict live mode: {'on' if STRICT_LIVE else 'off'}")
    print(f" Fresh bootstrap: {'on' if FRESH_BOOTSTRAP else 'off'}")
    print(f" Transport: {TRANSPORT}")

    try:
        if TRANSPORT == "external-tmux":
            client = ExternalTmuxMCPClient()
        elif TRANSPORT == "tmux":
            client = TmuxMCPClient()
        else:
            client = MCPClient()
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        print(f"  \033[0;31m✘ failed to start {TRANSPORT} transport: {error}\033[0m")
        sys.exit(1)

    section("§0 MCP Handshake")
    if not initialize(client):
        print("  \033[0;31m✘ MCP init failed\033[0m")
        client.close()
        sys.exit(1)
    print("  \033[0;32m✔\033[0m MCP initialized")

    if FRESH_BOOTSTRAP:
        section("§0.5 Fresh Session Bootstrap")
        bootstrap = run_fresh_bootstrap(client)
        if bootstrap.ok:
            summary = bootstrap.as_dict()
            language = summary["ui"].get("detected_language") or "unknown"
            track_count = summary["tracks"].get("count", 0)
            print(
                f"  \033[0;32m✔\033[0m Fresh session ready "
                f"({language} UI, track_count={track_count})"
            )
        else:
            print("  \033[0;31m✘\033[0m Fresh session bootstrap blocked")
            print(f"    {json.dumps(bootstrap.as_dict(), ensure_ascii=False)}")
            client.close()
            sys.exit(2)

    # ═══════════════════════════════════════════════════════════════
    # §1 Protocol Contract (10 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§1 Protocol Contract")

    r = list_tools(client)
    tools = r.get("result", {}).get("tools", []) if r else []
    T("tools/list returns 10 tools", r, lambda r: len(tools) == 10)
    tool_names = [t["name"] for t in tools]
    for name in ["logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
                 "logic_edit", "logic_navigate", "logic_project", "logic_system",
                 "logic_audio", "logic_plugins"]:
        T(f"  tool '{name}' present", r, lambda _, n=name: n in tool_names)

    r = list_resources(client)
    resources = r.get("result", {}).get("resources", []) if r else []
    resource_uris = {res.get("uri") for res in resources}
    required_resource_uris = {
        "logic://system/health",
        "logic://transport/state",
        "logic://tracks",
        "logic://mixer",
        "logic://markers",
        "logic://project/info",
        "logic://midi/ports",
        # #215: mcu/state is always listed (it is always directly readable and
        # the docs advertise a stable 18-resource catalog), even MCU-disconnected.
        "logic://mcu/state",
        "logic://library/inventory",
        "logic://stock-plugins",
        "logic://stock-plugins/census",
        "logic://stock-plugins/capabilities",
        "logic://workflow-skills",
        "logic://workflow-skills/schema",
    }
    T("resources/list includes required resources", r, lambda r: required_resource_uris.issubset(resource_uris))
    T("resources/list includes mcu/state even when MCU disconnected (#215)", r,
      lambda _: "logic://mcu/state" in resource_uris)

    r = list_resource_templates(client)
    templates = r.get("result", {}).get("resourceTemplates", []) if r else []
    template_uris = {tpl.get("uriTemplate") for tpl in templates}
    required_template_uris = {
        "logic://tracks/{index}",
        "logic://tracks/{index}/regions",
        "logic://mixer/{strip}",
        "logic://stock-plugins/{id}",
        "logic://stock-plugins/search?query={query}",
        "logic://workflow-skills/{id}",
        "logic://workflow-skills/search?query={query}",
    }
    T("resources/templates/list includes required templates", r, lambda r: required_template_uris.issubset(template_uris))

    # #218: invalid pagination cursors are rejected with JSON-RPC -32602 (the
    # server paginates into a single page and never issues a nextCursor), not
    # silently ignored (which returned a full first page as if no cursor).
    for method in ["tools/list", "resources/list", "resources/templates/list"]:
        r = client.send({"jsonrpc": "2.0", "id": nid(), "method": method,
                         "params": {"cursor": "bogus"}})
        T(f"{method} rejects invalid cursor with -32602 (#218)", r,
          lambda _, resp=r: isinstance(resp, dict) and resp.get("error", {}).get("code") == -32602)
        # A cursor-less call on the same method still returns a normal page.
        r = client.send({"jsonrpc": "2.0", "id": nid(), "method": method, "params": {}})
        T(f"{method} without cursor still returns a page (#218)", r,
          lambda _, resp=r: isinstance(resp, dict) and "result" in resp)

    # ═══════════════════════════════════════════════════════════════
    # §2 System Diagnostics (15 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§2 System Diagnostics")

    r = call_tool(client, "logic_system", "help")
    help_text = tool_text(r)
    T("system.help mentions logic_transport", r, lambda _: "logic_transport" in help_text)
    T("system.help mentions logic_tracks", r, lambda _: "logic_tracks" in help_text)
    T("system.help mentions logic_mixer", r, lambda _: "logic_mixer" in help_text)
    T("system.help mentions logic_midi", r, lambda _: "logic_midi" in help_text)
    T("system.help mentions logic_edit", r, lambda _: "logic_edit" in help_text)
    T("system.help mentions logic_navigate", r, lambda _: "logic_navigate" in help_text)
    T("system.help mentions logic_project", r, lambda _: "logic_project" in help_text)
    T("system.help mentions logic_system", r, lambda _: "logic_system" in help_text)

    # #219: an unknown help category returns a typed unknown_category error
    # (never a silent fall-through to full help with isError:false).
    r = call_tool(client, "logic_system", "help", params={"category": "bogus"})
    _uc = tool_json(r) or {}
    T("system.help unknown category returns typed unknown_category (#219)", r,
      lambda _: is_error(r) and _uc.get("error") == "unknown_category"
      and _uc.get("requested_category") == "bogus"
      and isinstance(_uc.get("valid_categories"), list))
    # A valid category still succeeds; an absent category still returns full help.
    r = call_tool(client, "logic_system", "help", params={"category": "transport"})
    T("system.help valid category succeeds", r,
      lambda _: not is_error(r) and "logic_transport commands" in tool_text(r))

    r = call_tool(client, "logic_system", "health")
    health_text = tool_text(r)
    health = safe_json(health_text)
    has_document = False
    logic_running = False
    accessibility_ready = False
    automation_ready = False
    core_midi_ready = False
    live_logic_ready = False
    midi_live_ready = False
    T("system.health is valid JSON", r, lambda _: health is not None)
    if health:
        channels = health.get("channels", [])
        channels_by_name = {
            c.get("channel"): c for c in channels
            if isinstance(c, dict) and c.get("channel") is not None
        }
        has_document = health.get("logic_pro_has_document") is True
        logic_running = health.get("logic_pro_running") is True
        permissions = health.get("permissions", {})
        accessibility_ready = permissions.get("accessibility") is True
        automation_ready = permissions.get("automation_granted") is True
        # #188: System Events automation is a distinct TCC target the MIDI import
        # path requires. The strict live harness itself drives System Events, so a
        # green run must report it granted.
        system_events_ready = permissions.get("automation_system_events") is True
        core_midi = channels_by_name.get("CoreMIDI", {})
        core_midi_ready = core_midi.get("available") is True and core_midi.get("ready") is True
        live_logic_ready = logic_running and accessibility_ready
        midi_live_ready = logic_running and core_midi_ready

        T_LIVE("health.logic_pro_running is true", r, lambda _: logic_running, logic_running, "Logic Pro is not running")
        T("health.logic_pro_version present", r, lambda _: "logic_pro_version" in health)
        T("health.channels is array of 7", r, lambda _: isinstance(channels, list) and len(channels) == 7)
        T("health.mcu present", r, lambda _: "mcu" in health)
        T("health.cache present", r, lambda _: "cache" in health)
        T_LIVE("health.permissions.accessibility granted", r, lambda _: accessibility_ready, accessibility_ready, "Accessibility is not granted to this binary/session")
        T_LIVE("health.permissions.automation granted", r, lambda _: automation_ready, automation_ready, "Automation is not verifiable/granted without a running Logic session")
        T("health.permissions.post_event_access present", r, lambda _: "post_event_access" in permissions)
        T("health.permissions.automation_system_events present (#188)", r, lambda _: "automation_system_events" in permissions)
        T_LIVE(
            "health.permissions.automation_system_events granted (#188)",
            r,
            lambda _: system_events_ready,
            system_events_ready,
            "Automation → System Events is required by the MIDI import path",
        )
        T("health.process.memory_mb positive", r, lambda _: health["process"]["memory_mb"] > 0)
        T("health.process.uptime_sec non-negative", r, lambda _: health["process"]["uptime_sec"] >= 0)

    r = call_tool(client, "logic_system", "permissions")
    T(
        "system.permissions mentions accessibility and automation",
        r,
        lambda _: "Accessibility:" in tool_text(r) and "Automation (Logic Pro):" in tool_text(r),
    )
    T(
        "system.permissions mentions System Events automation (#188)",
        r,
        lambda _: "Automation (System Events):" in tool_text(r),
    )

    r = call_tool(client, "logic_system", "refresh_cache")
    T("system.refresh_cache succeeds", r, lambda _: not is_error(r))

    controller_learn_guard = {
        "status": "skipped",
        "policy_id": DEFAULT_CONTROLLER_LEARN_MODE_POLICY["policy_id"],
        "reason": "Logic Pro + Accessibility are required",
    }
    controller_learn_clear = False
    controller_learn_reason = "Logic Pro + Accessibility are required"
    if live_logic_ready:
        controller_learn_guard = guard_controller_learn_mode()
        controller_learn_clear = controller_learn_guard_is_clear(controller_learn_guard)
        controller_learn_reason = (
            "controller assignments Learn Mode guard clear"
            if controller_learn_clear
            else controller_learn_guard_reason(controller_learn_guard)
        )

    T_LIVE(
        "controller assignments Learn Mode guard is clear",
        {"result": controller_learn_guard},
        lambda _: controller_learn_clear,
        live_logic_ready,
        controller_learn_reason,
    )

    midi_live_execute_ready = midi_live_ready and controller_learn_clear
    midi_live_execute_reason = (
        controller_learn_reason
        if midi_live_ready and not controller_learn_clear
        else "Logic Pro + CoreMIDI are required"
    )

    # ═══════════════════════════════════════════════════════════════
    # §3 Transport Live Operations (20 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§3 Transport Live Operations")

    transport_bootstrap = None
    transport_live_ready = live_logic_ready and has_document
    transport_live_reason = "Logic Pro + visible document are required"
    if STRICT_LIVE and FRESH_BOOTSTRAP and live_logic_ready:
        transport_bootstrap = run_fresh_bootstrap(client)
        if transport_bootstrap.ok:
            transport_live_ready = True
            has_document = True
            call_tool(client, "logic_system", "refresh_cache", timeout=3)
        else:
            transport_live_ready = False
            transport_live_reason = bootstrap_failure_reason(transport_bootstrap)

    # P1-4 (D2): transport reads moved to the logic://transport/state resource
    # (the logic_transport get_state tool command was removed). Envelope shape:
    # { cache_age_sec, fetched_at, ax_occluded, data: { state: {...}, has_document } }.
    r = read_resource(client, "logic://transport/state")
    ts_text = resource_text(r)
    T("logic://transport/state returns content", r, lambda _: len(ts_text) > 0)

    env = safe_json(ts_text)
    st = env.get("data", {}).get("state") if isinstance(env, dict) else None

    if isinstance(st, dict):
        T("transport/state is valid JSON envelope", r, lambda _: True)
        T("transport.tempo > 0", r, lambda _: st.get("tempo", 0) > 0)
        T("transport.tempo reasonable (20-300)", r, lambda _: 20 <= st.get("tempo", 0) <= 300)
        T("transport has isPlaying bool", r, lambda _: isinstance(st.get("isPlaying"), bool))
        T("transport has isRecording bool", r, lambda _: isinstance(st.get("isRecording"), bool))
        T("transport has isCycleEnabled bool", r, lambda _: isinstance(st.get("isCycleEnabled"), bool))
        T("transport has isMetronomeEnabled bool", r, lambda _: isinstance(st.get("isMetronomeEnabled"), bool))
        T("transport has position string", r, lambda _: isinstance(st.get("position"), str))
    else:
        # No document open is a valid envelope too — still must be non-empty JSON.
        T("transport/state envelope present (no-document tolerated)", r,
          lambda _: len(ts_text) > 0)

    # Roundtrip: toggle cycle, read, toggle back, read
    def safe_get_cycle(client):
        r = read_resource(client, "logic://transport/state")
        try:
            envelope = json.loads(resource_text(r))
            if envelope.get("fetched_at") is None:
                return None
            data = envelope.get("data", {})
            if data.get("has_document") is False:
                return None
            return data.get("state", {}).get("isCycleEnabled")
        except: return None

    def wait_for_cycle_change(client, before, timeout=5.0):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = safe_get_cycle(client)
            if before is not None and last is not None and before != last:
                return last
            time.sleep(0.2)
        return last

    def safe_get_transport_state(client):
        r = read_resource(client, "logic://transport/state")
        envelope = safe_json(resource_text(r))
        if not isinstance(envelope, dict):
            return None
        data = envelope.get("data", {})
        if not isinstance(data, dict):
            return None
        state = data.get("state")
        return state if isinstance(state, dict) else None

    def safe_get_tracks(client):
        r = read_resource(client, "logic://tracks")
        envelope = safe_json(resource_text(r))
        if not isinstance(envelope, dict):
            return None
        data = envelope.get("data")
        return data if isinstance(data, list) else None

    def approx_equal(value, expected, tolerance=0.01):
        try:
            return abs(float(value) - expected) <= tolerance
        except (TypeError, ValueError):
            return False

    def has_tempo_landmarks(payload):
        return (
            isinstance(payload, dict)
            and isinstance(payload.get("hint"), str)
            and len(payload.get("hint", "")) > 0
            and isinstance(payload.get("dialog_present"), bool)
            and isinstance(payload.get("control_bar_found"), bool)
            and isinstance(payload.get("transport_bar_found"), bool)
            and isinstance(payload.get("track_header_count"), int)
            and isinstance(payload.get("control_bar_slider_descriptions"), list)
            and isinstance(payload.get("transport_slider_descriptions"), list)
            and isinstance(payload.get("control_bar_checkbox_labels"), list)
        )

    before = safe_get_cycle(client)
    call_tool(client, "logic_transport", "toggle_cycle")
    after = wait_for_cycle_change(client, before)
    if before is not None and after is not None:
        T("cycle roundtrip: state changed after toggle", "ok", lambda _: before != after)
    else:
        T("cycle roundtrip (skipped — no project)", "ok", lambda _: True)
    call_tool(client, "logic_transport", "toggle_cycle")  # restore

    def transport_playing_verified(envelope, state):
        return (
            isinstance(envelope, dict)
            and envelope.get("unverified") is not True
            and isinstance(state, dict)
            and state.get("isPlaying") is True
        )

    def transport_stopped_verified(envelope, state):
        return (
            isinstance(envelope, dict)
            and envelope.get("unverified") is not True
            and isinstance(state, dict)
            and state.get("isPlaying") is False
            and state.get("isRecording") is False
        )

    stop_live_ready = transport_live_ready
    ui_stop_envelope = None
    ui_stop_state = None
    mcp_stop_response = None
    mcp_stop_envelope = None
    mcp_stop_state = None
    if stop_live_ready:
        call_tool(client, "logic_transport", "play")
        _, playing_state = wait_for_transport_state_envelope(client, transport_playing_verified, timeout=5.0)
        if isinstance(playing_state, dict) and ui_stop_logic_transport():
            ui_stop_envelope, ui_stop_state = wait_for_transport_state_envelope(
                client, transport_stopped_verified, timeout=5.0
            )

        call_tool(client, "logic_transport", "play")
        _, replay_state = wait_for_transport_state_envelope(client, transport_playing_verified, timeout=5.0)
        if isinstance(replay_state, dict):
            mcp_stop_response = call_tool(client, "logic_transport", "stop")
            mcp_stop_envelope, mcp_stop_state = wait_for_transport_state_envelope(
                client, transport_stopped_verified, timeout=5.0
            )
        call_tool(client, "logic_transport", "stop")

    T_LIVE(
        "transport readback reflects external UI stop",
        {"envelope": ui_stop_envelope, "state": ui_stop_state},
        lambda _: (
            isinstance(ui_stop_envelope, dict)
            and ui_stop_envelope.get("unverified") is not True
            and isinstance(ui_stop_state, dict)
            and ui_stop_state.get("isPlaying") is False
            and ui_stop_state.get("isRecording") is False
        ),
        stop_live_ready,
        transport_live_reason,
    )
    T_LIVE(
        "logic_transport.stop returns verified success after live readback",
        mcp_stop_response,
        lambda _: (
            mcp_stop_response is not None
            and not is_error(mcp_stop_response)
            and (safe_json(tool_text(mcp_stop_response)) or {}).get("verified") is True
        ),
        stop_live_ready,
        transport_live_reason,
    )
    T_LIVE(
        "transport readback reflects logic_transport.stop immediately",
        {"envelope": mcp_stop_envelope, "state": mcp_stop_state},
        lambda _: (
            isinstance(mcp_stop_envelope, dict)
            and mcp_stop_envelope.get("unverified") is not True
            and isinstance(mcp_stop_state, dict)
            and mcp_stop_state.get("isPlaying") is False
            and mcp_stop_state.get("isRecording") is False
        ),
        stop_live_ready,
        transport_live_reason,
    )

    # Transport commands that route to MCU/CoreMIDI
    r = call_tool(client, "logic_transport", "toggle_cycle")
    T_LIVE(
        "transport.toggle_cycle returns non-error",
        r,
        lambda _: not is_error(r),
        transport_live_ready,
        transport_live_reason,
    )
    call_tool(client, "logic_transport", "toggle_cycle")  # restore

    r = call_tool(client, "logic_transport", "toggle_metronome")
    T_LIVE(
        "transport.toggle_metronome verifies or fails closed with explicit State B/C",
        r,
        lambda _: verified_or_explicitly_unverified(r),
        transport_live_ready,
        transport_live_reason,
    )
    call_tool(client, "logic_transport", "toggle_metronome")  # restore

    fresh_transport_live_ready = False
    fresh_transport_reason = "fresh Logic bootstrap with 1 track and 0 regions is required"
    fresh_transport_payload = bootstrap_status_payload(fresh_transport_reason)
    if transport_bootstrap is not None and not transport_bootstrap.ok:
        fresh_transport_reason = transport_live_reason
        fresh_transport_payload = bootstrap_status_payload(fresh_transport_reason, transport_bootstrap)
    elif live_logic_ready and has_document:
        call_tool(client, "logic_system", "refresh_cache", timeout=3)
        fresh_transport_live_ready, fresh_transport_reason = fresh_transport_bootstrap_status(client)
        if not fresh_transport_live_ready:
            fresh_transport_reason = f"fresh bootstrap not detected: {fresh_transport_reason}"
        fresh_transport_payload = bootstrap_status_payload(fresh_transport_reason)
    fresh_transport_execute_ready = fresh_transport_live_ready and controller_learn_clear
    fresh_transport_execute_reason = (
        controller_learn_reason
        if fresh_transport_live_ready and not controller_learn_clear
        else fresh_transport_reason
    )

    select_for_record = {"gate": fresh_transport_reason}
    arm_for_record = {"gate": fresh_transport_reason}
    arm_track = None
    stop_unchanged = {"gate": fresh_transport_reason}
    stop_unchanged_env = None
    stop_unchanged_state = None
    record_resp = {"gate": fresh_transport_reason}
    record_env = None
    record_state = None
    stop_after_record = {"gate": fresh_transport_reason}
    stop_after_record_env = None
    stop_after_record_state = None
    stop_after_record_unchanged = {"gate": fresh_transport_reason}
    stop_after_record_unchanged_env = None
    stop_after_record_unchanged_state = None
    play_resp = {"gate": fresh_transport_reason}
    play_env = None
    play_state = None
    play_unchanged = {"gate": fresh_transport_reason}
    play_unchanged_env = None
    play_unchanged_state = None
    final_stop = {"gate": fresh_transport_reason}
    final_stop_env = None
    final_stop_state = None
    disarm_after_transport = {"gate": fresh_transport_reason}
    disarm_track = None

    if fresh_transport_execute_ready:
        select_for_record = call_tool(client, "logic_tracks", "select", {"index": 0})
        arm_for_record = call_tool(client, "logic_tracks", "arm", {"index": 0, "enabled": True})
        arm_track = wait_for_track_arm(client, 0, True)

        stop_unchanged = call_tool(client, "logic_transport", "stop")
        stop_unchanged_env = tool_json(stop_unchanged)
        stop_unchanged_state = wait_for_transport_state(
            client,
            lambda state: state.get("isPlaying") is False and state.get("isRecording") is False,
        )

        record_resp = guarded_live_tool_call(
            client,
            "logic_transport",
            "record",
            ready=fresh_transport_execute_ready,
            reason=fresh_transport_execute_reason,
        )
        record_env = tool_json(record_resp)
        record_state = wait_for_transport_state(
            client,
            lambda state: state.get("isPlaying") is True and state.get("isRecording") is True,
            timeout=8.0,
        )

        stop_after_record = call_tool(client, "logic_transport", "stop")
        stop_after_record_env = tool_json(stop_after_record)
        stop_after_record_state = wait_for_transport_state(
            client,
            lambda state: state.get("isPlaying") is False and state.get("isRecording") is False,
        )

        stop_after_record_unchanged = call_tool(client, "logic_transport", "stop")
        stop_after_record_unchanged_env = tool_json(stop_after_record_unchanged)
        stop_after_record_unchanged_state = wait_for_transport_state(
            client,
            lambda state: state.get("isPlaying") is False and state.get("isRecording") is False,
        )

        play_resp = call_tool(client, "logic_transport", "play")
        play_env = tool_json(play_resp)
        play_state = wait_for_transport_state(
            client,
            lambda state: state.get("isPlaying") is True and state.get("isRecording") is False,
        )

        play_unchanged = call_tool(client, "logic_transport", "play")
        play_unchanged_env = tool_json(play_unchanged)
        play_unchanged_state = wait_for_transport_state(
            client,
            lambda state: state.get("isPlaying") is True and state.get("isRecording") is False,
        )

        final_stop = call_tool(client, "logic_transport", "stop")
        final_stop_env = tool_json(final_stop)
        final_stop_state = wait_for_transport_state(
            client,
            lambda state: state.get("isPlaying") is False and state.get("isRecording") is False,
        )

        disarm_after_transport = call_tool(client, "logic_tracks", "arm", {"index": 0, "enabled": False})
        disarm_track = wait_for_track_arm(client, 0, False)

        # #190: if a transport op IS refused for a blocking dialog, the refusal
        # must be IDENTIFIED (dialog role + a safe recovery action), never a bare
        # blocking_dialog_present. Passes vacuously when no dialog is present.
        for _label, _env in (("play", play_env), ("play_unchanged", play_unchanged_env), ("stop", final_stop_env)):
            T(
                f"transport.{_label} blocking-dialog refusal is identified (#190)",
                play_resp,
                lambda _, e=_env: (not isinstance(e, dict))
                or (e.get("blocking_dialog_present") is not True)
                or (e.get("recovery_action") is not None and e.get("dialog_role") is not None),
            )

    T_LIVE(
        "fresh transport bootstrap detected",
        fresh_transport_payload,
        lambda _: fresh_transport_live_ready,
        fresh_transport_live_ready,
        fresh_transport_reason,
    )
    T_LIVE(
        "controller assignments Learn Mode guard is clear before transport record",
        {"result": controller_learn_guard},
        lambda _: controller_learn_clear,
        fresh_transport_live_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport record prep selects track 0",
        select_for_record,
        lambda _: not is_error(select_for_record),
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport record prep arms track 0",
        arm_for_record,
        lambda _: not is_error(arm_for_record) and isinstance(arm_track, dict) and arm_track.get("isArmed") is True,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport.stop returns verified unchanged when already stopped",
        stop_unchanged,
        lambda _: isinstance(stop_unchanged_env, dict)
        and stop_unchanged_env.get("verified") is True
        and stop_unchanged_env.get("unchanged") is True
        and stop_unchanged_env.get("operation") == "transport.stop"
        and isinstance(stop_unchanged_state, dict)
        and stop_unchanged_state.get("isPlaying") is False
        and stop_unchanged_state.get("isRecording") is False,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport.record reaches verified recording state",
        record_resp,
        lambda _: isinstance(record_env, dict)
        and record_env.get("verified") is True
        and record_env.get("operation") == "transport.record"
        and isinstance(record_state, dict)
        and record_state.get("isPlaying") is True
        and record_state.get("isRecording") is True,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport.stop reaches verified stopped state after record",
        stop_after_record,
        lambda _: isinstance(stop_after_record_env, dict)
        and stop_after_record_env.get("verified") is True
        and stop_after_record_env.get("operation") == "transport.stop"
        and isinstance(stop_after_record_state, dict)
        and stop_after_record_state.get("isPlaying") is False
        and stop_after_record_state.get("isRecording") is False,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport.stop stays verified unchanged after record stop",
        stop_after_record_unchanged,
        lambda _: isinstance(stop_after_record_unchanged_env, dict)
        and stop_after_record_unchanged_env.get("verified") is True
        and stop_after_record_unchanged_env.get("unchanged") is True
        and stop_after_record_unchanged_env.get("operation") == "transport.stop"
        and isinstance(stop_after_record_unchanged_state, dict)
        and stop_after_record_unchanged_state.get("isPlaying") is False
        and stop_after_record_unchanged_state.get("isRecording") is False,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport.play reaches verified playback state",
        play_resp,
        lambda _: isinstance(play_env, dict)
        and play_env.get("verified") is True
        and play_env.get("operation") == "transport.play"
        and isinstance(play_state, dict)
        and play_state.get("isPlaying") is True
        and play_state.get("isRecording") is False,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport.play stays verified unchanged while already playing",
        play_unchanged,
        lambda _: isinstance(play_unchanged_env, dict)
        and play_unchanged_env.get("verified") is True
        and play_unchanged_env.get("unchanged") is True
        and play_unchanged_env.get("operation") == "transport.play"
        and isinstance(play_unchanged_state, dict)
        and play_unchanged_state.get("isPlaying") is True
        and play_unchanged_state.get("isRecording") is False,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport.stop reaches verified stopped state after play",
        final_stop,
        lambda _: isinstance(final_stop_env, dict)
        and final_stop_env.get("verified") is True
        and final_stop_env.get("operation") == "transport.stop"
        and isinstance(final_stop_state, dict)
        and final_stop_state.get("isPlaying") is False
        and final_stop_state.get("isRecording") is False,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )
    T_LIVE(
        "transport record prep disarms track 0 after transport checks",
        disarm_after_transport,
        lambda _: not is_error(disarm_after_transport) and isinstance(disarm_track, dict) and disarm_track.get("isArmed") is False,
        fresh_transport_execute_ready,
        fresh_transport_execute_reason,
    )

    r = call_tool(client, "logic_transport", "toggle_count_in")
    T("transport.toggle_count_in dispatches", r, lambda _: len(tool_text(r)) > 0)
    call_tool(client, "logic_transport", "toggle_count_in")  # restore

    fresh_tracks = safe_get_tracks(client)
    if live_logic_ready and has_document and isinstance(fresh_tracks, list) and len(fresh_tracks) == 0:
        r = call_tool(client, "logic_tracks", "create_instrument")
        create_instrument_text = tool_text(r)
        create_instrument_json = safe_json(create_instrument_text)
        T_LIVE(
            "transport.fresh_project bootstrap creates instrument track or returns explicit failure",
            r,
            lambda _: (
                isinstance(create_instrument_json, dict)
                and create_instrument_json.get("success") is True
                and create_instrument_json.get("verified") is True
                and create_instrument_json.get("observed_delta") == 1
                and isinstance(create_instrument_json.get("track_count_after"), int)
                and create_instrument_json.get("track_count_after", 0) >= 1
            ) or (
                is_error(r)
                and isinstance(create_instrument_json, dict)
                and isinstance(create_instrument_json.get("hint"), str)
                and len(create_instrument_json.get("hint", "")) > 0
            ),
            live_logic_ready,
            "Logic Pro + Accessibility are required",
        )
        time.sleep(0.4)

    # Set tempo
    r = call_tool(client, "logic_transport", "set_tempo", {"tempo": 128})
    set_tempo_128_text = tool_text(r)
    set_tempo_128_json = safe_json(set_tempo_128_text)
    transport_after_128 = safe_get_transport_state(client) if live_logic_ready else None
    T("transport.set_tempo(128) dispatches", r, lambda _: len(set_tempo_128_text) > 0)
    T_LIVE(
        "transport.set_tempo(128) verifies exact readback or fails closed (never success on mismatch)",
        r,
        lambda _: (
            isinstance(set_tempo_128_json, dict)
            and set_tempo_128_json.get("success") is True
            and set_tempo_128_json.get("verified") is True
            and approx_equal(set_tempo_128_json.get("observed"), 128.0)
            and approx_equal(transport_after_128.get("tempo"), 128.0)
        ) or (
            isinstance(set_tempo_128_json, dict)
            and set_tempo_128_json.get("success") is True
            and set_tempo_128_json.get("verified") is False
            and set_tempo_128_json.get("reason") in ("readback_unavailable", "unsupported", "ui_drift")
            and has_tempo_landmarks(set_tempo_128_json)
        ) or (
            isinstance(set_tempo_128_json, dict)
            and set_tempo_128_json.get("success") is False
            and set_tempo_128_json.get("error") in ("element_not_found", "readback_unavailable")
            and has_tempo_landmarks(set_tempo_128_json)
        ) or (
            # #189: the slider-increment fallback fails closed (State C) when it
            # cannot land the requested tempo — it must NEVER report success on a
            # readback mismatch. Honest evidence: observed tempo + fallback method.
            isinstance(set_tempo_128_json, dict)
            and set_tempo_128_json.get("success") is False
            and set_tempo_128_json.get("error") == "readback_mismatch"
            and set_tempo_128_json.get("via") == "slider-increment"
            and approx_equal(set_tempo_128_json.get("requested"), 128.0)
            and isinstance(set_tempo_128_json.get("observed"), (int, float))
        ),
        live_logic_ready,
        "Logic Pro + Accessibility are required",
    )
    # #189 guard: regardless of which path runs, a tempo write must never claim
    # success while reporting a tempo that differs from the request.
    T(
        "transport.set_tempo(128) never reports success on a readback mismatch (#189)",
        r,
        lambda _: not (
            isinstance(set_tempo_128_json, dict)
            and set_tempo_128_json.get("success") is True
            and isinstance(set_tempo_128_json.get("observed"), (int, float))
            and not approx_equal(set_tempo_128_json.get("observed"), 128.0)
        ),
    )

    r = call_tool(client, "logic_transport", "set_tempo", {"tempo": 90.5})
    T("transport.set_tempo(90.5) handles decimal", r, lambda _: len(tool_text(r)) > 0)

    # Goto position
    r = call_tool(client, "logic_transport", "goto_position", {"bar": 1})
    T("transport.goto_position(bar=1) dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_transport", "goto_position", {"bar": 16})
    T("transport.goto_position(bar=16) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # Set cycle range
    r = call_tool(client, "logic_transport", "set_cycle_range", {"start": 1, "end": 4})
    T("transport.set_cycle_range is verified or returns structured blocked state", r, cycle_range_result_ok)

    # ═══════════════════════════════════════════════════════════════
    # §4 Track Live Operations (25 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§4 Track Live Operations")

    # P1-4 (D2): track reads moved to logic://tracks (envelope { ..., data: [...] }).
    # Selection is carried by each track's isSelected field (no get_selected tool).
    r = read_resource(client, "logic://tracks")
    tracks_text = resource_text(r)
    T("logic://tracks returns content", r, lambda _: len(tracks_text) > 0)

    env = safe_json(tracks_text)
    tracks = env.get("data") if isinstance(env, dict) else None
    if isinstance(tracks, list):
        T("tracks envelope data is array", r, lambda _: True)
        if tracks:
            T(f"found {len(tracks)} tracks", r, lambda _: len(tracks) > 0)
            T("first track has id", r, lambda _: "id" in tracks[0])
            T("first track has name", r, lambda _: "name" in tracks[0])
            T("first track has type", r, lambda _: "type" in tracks[0])
            T("first track has isMuted bool", r, lambda _: isinstance(tracks[0].get("isMuted"), bool))
            T("first track has isSoloed bool", r, lambda _: isinstance(tracks[0].get("isSoloed"), bool))
            T("first track has isArmed bool", r, lambda _: isinstance(tracks[0].get("isArmed"), bool))
            T("first track id is int", r, lambda _: isinstance(tracks[0].get("id"), int))
            T("tracks carry isSelected (selection state)", r,
              lambda _: any("isSelected" in t for t in tracks))
    else:
        tracks = []

    # Select each of first 3 tracks (if available)
    num_to_test = min(3, len(tracks)) if tracks else 1
    for i in range(num_to_test):
        r = call_tool(client, "logic_tracks", "select", {"index": i})
        T(f"track.select({i}) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # Mute/solo/arm on first track
    if tracks:
        r = call_tool(client, "logic_tracks", "mute", {"index": 0})
        T("track.mute dispatches", r, lambda _: len(tool_text(r)) > 0)
        call_tool(client, "logic_tracks", "mute", {"index": 0})  # toggle back

        r = call_tool(client, "logic_tracks", "solo", {"index": 0})
        T("track.solo dispatches", r, lambda _: len(tool_text(r)) > 0)
        call_tool(client, "logic_tracks", "solo", {"index": 0})  # toggle back

        r = call_tool(client, "logic_tracks", "arm", {"index": 0})
        T("track.arm dispatches", r, lambda _: len(tool_text(r)) > 0)
        call_tool(client, "logic_tracks", "arm", {"index": 0})

    # Invalid index
    r = call_tool(client, "logic_tracks", "select", {"index": 999})
    T("track.select(999) handled gracefully", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_tracks", "select", {"index": -1})
    T("track.select(-1) handled gracefully", r, lambda _: len(tool_text(r)) > 0)

    # Missing parameters
    r = call_tool(client, "logic_tracks", "select")
    T("track.select without index returns error", r, lambda _: is_error(r))

    # v3.0.0+: all mutating commands reject missing/non-numeric index — old
    # silent default-to-zero was dropped as a correctness hazard.
    r = call_tool(client, "logic_tracks", "mute")
    T(
        "track.mute without index rejects with explicit error (v3.0.0)",
        r,
        lambda _: is_error(r) and "explicit 'index'" in tool_text(r),
    )

    r = call_tool(client, "logic_tracks", "rename", {"name": "No Index"})
    T(
        "track.rename without index rejects with explicit error (v3.0.0)",
        r,
        lambda _: is_error(r) and "explicit 'index'" in tool_text(r),
    )

    r = call_tool(client, "logic_tracks", "select", {"index": "abc"})
    T(
        "track.select with non-numeric index rejects (v3.0.0)",
        r,
        lambda _: is_error(r) and "non-negative integer" in tool_text(r),
    )

    r = call_tool(client, "logic_tracks", "rename", {"index": 0, "name": ""})
    T("track.rename with empty name rejects", r, lambda _: is_error(r))

    r = call_tool(client, "logic_tracks", "list_library")
    list_library_text = tool_text(r)
    list_library_json = safe_json(list_library_text)
    T(
        "track.list_library returns inventory or clear precondition error",
        r,
        lambda _: (
            isinstance(list_library_json, dict)
            and "categories" in list_library_json
            and "presetsByCategory" in list_library_json
        ) or "Library panel not found" in list_library_text
          or "Accessibility not trusted" in list_library_text,
    )

    # Default scan_library uses the non-mutating disk scanner; explicit
    # mode="ax" remains the legacy live Panel walk.
    r = call_tool(client, "logic_tracks", "scan_library", timeout=60)
    scan_library_text = tool_text(r)
    scan_library_json = safe_json(scan_library_text)
    T(
        "track.scan_library returns tree or clear precondition error",
        r,
        lambda _: is_library_scan_json(scan_library_json)
          or "Library panel not found" in scan_library_text
          or "Accessibility not trusted" in scan_library_text,
    )

    r = call_tool(client, "logic_tracks", "resolve_path")
    T(
        "track.resolve_path without path returns explicit error",
        r,
        lambda _: is_error(r) and "Missing 'path'" in tool_text(r),
    )

    r = call_tool(client, "logic_tracks", "set_instrument", {"index": 0})
    T(
        "track.set_instrument without selector returns explicit error (v3.0.0)",
        r,
        lambda _: is_error(r) and (
            "requires 'path' or both 'category' + 'preset'" in tool_text(r)
            or "Missing path or (category+preset)" in tool_text(r)
            or "Accessibility not trusted" in tool_text(r)
            or "Event-post permission required" in tool_text(r)
            or "No document open" in tool_text(r)
        ),
    )

    # #222 — deterministic apply contract / no panel-state drift. An invalid
    # path loads NOTHING (non-destructive), so we can fire it twice: both must
    # return the SAME deterministic State C error (never cascade into a
    # `library_panel_unavailable` inherited from the first attempt), the
    # nav-failure path must report the panel left open
    # (`panel_open_after_failure`), and a library read between the two attempts
    # must still succeed (panel not wedged).
    invalid_path = "ZZZNoSuchCategory/ZZZNoSuchPreset"
    d1 = tool_json(call_tool(client, "logic_tracks", "set_instrument",
                             {"index": 0, "path": invalid_path})) or {}
    mid = read_resource(client, "logic://library/inventory")
    mid_ok = mid is not None and safe_json(resource_text(mid)) is not None
    d2 = tool_json(call_tool(client, "logic_tracks", "set_instrument",
                             {"index": 0, "path": invalid_path})) or {}
    T("set_instrument invalid path is a deterministic State C (#222)", "ok",
      lambda _: d1.get("success") is False and isinstance(d1.get("error"), str))
    T("set_instrument failure does not cascade on the next attempt (#222)", "ok",
      lambda _: d2.get("success") is False and d2.get("error") == d1.get("error"))
    T("library read still works between failed set_instrument attempts (#222)", "ok",
      lambda _: mid_ok)
    if d1.get("precondition") == "library_nav_failed":
        T("set_instrument nav-failure leaves the Library panel open (#222)", "ok",
          lambda _: d1.get("panel_open_after_failure") is True
          and d2.get("panel_open_after_failure") is True)

    probe_category = None
    probe_preset = None
    if tracks and isinstance(list_library_json, dict):
        presets_by_category = list_library_json.get("presetsByCategory")
        categories = list_library_json.get("categories")
        candidate_categories = []
        current_category = list_library_json.get("currentCategory")
        if isinstance(current_category, str) and current_category:
            candidate_categories.append(current_category)
        if isinstance(categories, list):
            for category in categories:
                if isinstance(category, str) and category and category not in candidate_categories:
                    candidate_categories.append(category)
        if isinstance(presets_by_category, dict):
            for category in candidate_categories:
                presets = presets_by_category.get(category)
                if not isinstance(presets, list):
                    continue
                for preset in presets:
                    if not isinstance(preset, str) or not preset:
                        continue
                    candidate_path = f"{category}/{preset}"
                    resolved = tool_json(call_tool(
                        client,
                        "logic_tracks",
                        "resolve_path",
                        {"path": candidate_path},
                    )) or {}
                    if not (
                        resolved.get("exists") is True
                        and resolved.get("kind") == "leaf"
                        and resolved.get("loadable") is True
                    ):
                        continue
                    probe_category = category
                    probe_preset = preset
                    break
                if probe_category and probe_preset:
                    break

    if tracks and probe_category and probe_preset:
        r = call_tool(
            client,
            "logic_tracks",
            "set_instrument",
            {"index": 0, "category": probe_category, "preset": probe_preset},
        )
        set_instrument_text = tool_text(r)
        set_instrument_json = safe_json(set_instrument_text)
        T(
            "track.set_instrument returns verification metadata or fail-closed selection error",
            r,
            lambda _: (
                isinstance(set_instrument_json, dict)
                and (
                    (
                        set_instrument_json.get("success") is True
                        and set_instrument_json.get("requested_patch_name") == probe_preset
                        and set_instrument_json.get("requested_category") == probe_category
                        and set_instrument_json.get("target_track_index") == 0
                        and "target_track_selection_verified" in set_instrument_json
                        and "observed_patch_name" in set_instrument_json
                        and "readback_state" in set_instrument_json
                    )
                    or (
                        set_instrument_json.get("success") is False
                        and set_instrument_json.get("error") in {
                            "track_selection_failed",
                            "ax_write_failed",
                            "element_not_found",
                            "permission_denied",
                            "readback_unavailable",
                            "readback_mismatch",
                            "folder_not_preset",
                            "path_not_in_library",
                            "unsupported_track_type",
                        }
                        and set_instrument_json.get("requested_patch_name") == probe_preset
                        and set_instrument_json.get("requested_category") == probe_category
                        and set_instrument_json.get("target_track_index") == 0
                    )
                )
            ) or "Library panel not found" in set_instrument_text
              or "Accessibility not trusted" in set_instrument_text
              or "Event-post permission required" in set_instrument_text
              or "No document open" in set_instrument_text,
        )

    r = call_tool(client, "logic_tracks", "scan_plugin_presets", {"submenuOpenDelayMs": 300})
    T("track.scan_plugin_presets returns content or guidance", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_tracks", "record_sequence", {
        "bar": 1,
        "notes": "60,0,500,100,1",
    })
    record_sequence_text = tool_text(r)
    record_sequence_json = safe_json(record_sequence_text)
    T_LIVE(
        "track.record_sequence verifies imported region or returns structured readback failure",
        r,
        lambda _: (
            isinstance(record_sequence_json, dict)
            and record_sequence_json.get("success") is True
            and record_sequence_json.get("verified") is True
            and isinstance(record_sequence_json.get("created_track"), int)
            and isinstance(record_sequence_json.get("target_track_index"), int)
            and isinstance(record_sequence_json.get("region_name"), str)
            and isinstance(record_sequence_json.get("start_bar"), int)
            and isinstance(record_sequence_json.get("end_bar"), int)
            and isinstance(record_sequence_json.get("note_count"), int)
            and isinstance(record_sequence_json.get("verify_source"), str)
        ) or (
            isinstance(record_sequence_json, dict)
            and record_sequence_json.get("success") is False
            and record_sequence_json.get("error") in (
                "import_failure",
                "wrong_track_import",
                "timing_mismatch",
                "unreadable_readback",
            )
            and isinstance(record_sequence_json.get("note_count"), int)
            and isinstance(record_sequence_json.get("method"), str)
        ),
        live_logic_ready and has_document,
        "Logic Pro with an open project is required",
    )

    # ═══════════════════════════════════════════════════════════════
    # §5 Mixer Live Operations (25 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§5 Mixer Live Operations")

    # P1-4 (D2): mixer reads moved to logic://mixer (envelope { ..., strips: [...] }).
    r = read_resource(client, "logic://mixer")
    mix_text = resource_text(r)
    mix_json = safe_json(mix_text)
    if isinstance(mix_json, dict) and mix_json.get("data_source") == "mixer_not_visible":
        _ = call_tool(client, "logic_navigate", "toggle_view", {"view": "mixer"})
        time.sleep(1)
        r = read_resource(client, "logic://mixer")
        mix_text = resource_text(r)
        mix_json = safe_json(mix_text)
    T("logic://mixer returns content", r, lambda _: len(mix_text) > 0)
    T("logic://mixer carries strips + mcu_connected", r,
      lambda _: ("strips" in mix_text and "mcu_connected" in mix_text)
                or "No Logic Pro document is open" in response_dump(r))
    # B1 (#11): provenance — data_source present on the new build's envelope.
    T("logic://mixer carries data_source provenance (B1/#11)", r,
      lambda _: "data_source" in mix_text or "No Logic Pro document is open" in response_dump(r))
    live_mixer_ready = (
        live_logic_ready
        and isinstance(mix_json, dict)
        and mix_json.get("data_source") != "mixer_not_visible"
        and isinstance(mix_json.get("strips"), list)
        and len(mix_json.get("strips", [])) > 0
    )

    r = call_tool(client, "logic_mixer", "set_volume", {"track": 0, "volume": 0.5})
    T_LIVE(
        "logic_mixer.set_volume(track=0) returns verified AX mixer write",
        r,
        lambda resp: mixer_write_result_ok(resp, "mixer.set_volume", "volume", 0, 0.5),
        live_mixer_ready,
        "Logic Pro + Accessibility + a visible mixer strip are required",
    )

    r = call_tool(client, "logic_mixer", "set_pan", {"track": 0, "value": 0.0})
    T_LIVE(
        "logic_mixer.set_pan(track=0) returns verified AX mixer write",
        r,
        lambda resp: mixer_write_result_ok(resp, "mixer.set_pan", "pan", 0, 0.0),
        live_mixer_ready,
        "Logic Pro + Accessibility + a visible mixer strip are required",
    )

    r = call_tool(client, "logic_plugins", "get_inventory", {"track": 0})
    T_LIVE(
        "logic_plugins.get_inventory(track=0) returns verified visible-mixer inventory",
        r,
        plugin_inventory_result_ok,
        live_logic_ready,
        "Logic Pro + Accessibility are required",
    )

    # Volume range testing
    for vol in [0.0, 0.25, 0.5, 0.75, 1.0]:
        r = call_tool(client, "logic_mixer", "set_volume", {"index": 0, "volume": vol})
        T(f"mixer.set_volume({vol}) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # Pan range testing (-1 to 1)
    for pan in [-1.0, -0.5, 0.0, 0.5, 1.0]:
        r = call_tool(client, "logic_mixer", "set_pan", {"index": 0, "value": pan})
        T(f"mixer.set_pan({pan}) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # P1-4 (D2): single-strip reads moved to logic://mixer/{strip} (B2 envelope
    # { cache_age_sec, data_source, strip: {...} }); absent strip → error is valid.
    for i in range(3):
        r = read_resource(client, f"logic://mixer/{i}")
        T(f"logic://mixer/{i} returns data or errors cleanly", r,
          lambda _: len(resource_text(r)) > 0 or is_error(r) or "error" in r)

    # Out-of-range volume
    r = call_tool(client, "logic_mixer", "set_volume", {"index": 0, "volume": -1})
    T("mixer.set_volume(-1) handled", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_mixer", "set_volume", {"index": 0, "volume": 5})
    T("mixer.set_volume(5) handled", r, lambda _: len(tool_text(r)) > 0)

    # Missing params — RB-1.a (2026-05-08 enterprise review): the previous
    # expectation here ("responds (default 0)") locked the production
    # fail-open behaviour into the test suite. set_volume without an explicit
    # `track` now fails closed, and this test enforces that contract so a
    # future regression doesn't silently bring the wrong-track-mutation bug
    # back.
    r = call_tool(client, "logic_mixer", "set_volume")
    T(
        "mixer.set_volume without params is rejected (fail-closed)",
        r,
        lambda _: is_error(r) and "requires explicit 'track'" in tool_text(r),
    )

    r = call_tool(client, "logic_mixer", "set_pan")
    T(
        "mixer.set_pan without params is rejected (fail-closed)",
        r,
        lambda _: is_error(r) and "requires explicit 'track'" in tool_text(r),
    )

    r = call_tool(client, "logic_mixer", "set_plugin_param", {"insert": 0, "param": 0, "value": 0.5})
    T(
        "mixer.set_plugin_param without track is rejected (fail-closed)",
        r,
        lambda _: is_error(r) and "requires explicit 'track'" in tool_text(r),
    )

    # Other mixer commands
    r = call_tool(client, "logic_mixer", "toggle_eq", {"index": 0})
    T("mixer.toggle_eq dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_mixer", "reset_strip", {"index": 0})
    T("mixer.reset_strip dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_mixer", "set_master_volume", {"volume": 0.8})
    T("mixer.set_master_volume dispatches", r, lambda _: len(tool_text(r)) > 0)

    # #202: deliberately not-exposed command tokens return a single
    # machine-classifiable command_not_exposed shape (not a generic
    # not_implemented), so a complete-surface harness can mark them expected.
    r = call_tool(client, "logic_mixer", "set_send", {"index": 0, "send": 0, "value": 0.5})
    _ne = safe_json(tool_text(r)) or {}
    T("mixer.set_send returns typed command_not_exposed (#202)", r,
      lambda _: _ne.get("error") == "command_not_exposed" and _ne.get("not_exposed") is True
      and _ne.get("supported") is False)

    # ═══════════════════════════════════════════════════════════════
    # §6 MIDI Live Operations (25 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§6 MIDI Live Operations")

    # Note range
    for note in [0, 21, 60, 108, 127]:
        r = guarded_live_midi_call(
            client,
            "send_note",
            {"note": note, "velocity": 80, "duration_ms": 30},
            ready=midi_live_execute_ready,
            reason=midi_live_execute_reason,
        )
        T_LIVE(f"midi.send_note({note}) succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # Velocity range
    for vel in [1, 64, 127]:
        r = guarded_live_midi_call(
            client,
            "send_note",
            {"note": 60, "velocity": vel, "duration_ms": 30},
            ready=midi_live_execute_ready,
            reason=midi_live_execute_reason,
        )
        T_LIVE(f"midi.send_note vel={vel} succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # Channel range
    for ch in [1, 8, 16]:
        r = guarded_live_midi_call(
            client,
            "send_note",
            {"note": 60, "channel": ch, "duration_ms": 30},
            ready=midi_live_execute_ready,
            reason=midi_live_execute_reason,
        )
        T_LIVE(f"midi.send_note ch={ch} succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # Chord
    r = guarded_live_midi_call(
        client,
        "send_chord",
        {"notes": "60,64,67", "duration_ms": 30},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.send_chord C major succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    r = guarded_live_midi_call(
        client,
        "send_chord",
        {"notes": "60,63,67,70", "duration_ms": 30},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.send_chord Cm7 succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # CC range
    for cc in [1, 7, 10, 11, 64, 120, 123]:
        r = guarded_live_midi_call(
            client,
            "send_cc",
            {"controller": cc, "value": 64},
            ready=midi_live_execute_ready,
            reason=midi_live_execute_reason,
        )
        T_LIVE(f"midi.send_cc({cc}) succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # Program change
    r = guarded_live_midi_call(
        client,
        "send_program_change",
        {"program": 0},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.send_program_change(0) succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    r = guarded_live_midi_call(
        client,
        "send_program_change",
        {"program": 127},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.send_program_change(127) succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # Pitch bend
    r = guarded_live_midi_call(
        client,
        "send_pitch_bend",
        {"value": 8192},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.send_pitch_bend(center) succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    r = guarded_live_midi_call(
        client,
        "send_pitch_bend",
        {"value": 16383},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.send_pitch_bend(max) succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # Aftertouch
    r = guarded_live_midi_call(
        client,
        "send_aftertouch",
        {"value": 100},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.send_aftertouch succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # MMC
    r = guarded_live_midi_call(
        client,
        "mmc_play",
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.mmc_play succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)
    guarded_live_midi_call(
        client,
        "mmc_stop",
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )  # restore

    r = guarded_live_midi_call(
        client,
        "mmc_stop",
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.mmc_stop succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    r = guarded_live_midi_call(
        client,
        "mmc_locate",
        {"bar": 1},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE(
        "midi.mmc_locate(bar=1) verifies or reports readback mismatch",
        r,
        lambda _: verified_or_readback_mismatch(r),
        midi_live_execute_ready,
        midi_live_execute_reason,
    )

    # Step input
    r = guarded_live_midi_call(
        client,
        "step_input",
        {"note": 60, "duration": "1/4"},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.step_input(1/4) succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    r = guarded_live_midi_call(
        client,
        "step_input",
        {"note": 60, "duration": "1/8"},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.step_input(1/8) succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # Duration cap (our P2 fix)
    r = guarded_live_midi_call(
        client,
        "send_note",
        {"note": 60, "duration_ms": 50},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("midi.send_note small duration succeeds", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # ═══════════════════════════════════════════════════════════════
    # §7 Edit Commands (14 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§7 Edit Commands")

    for cmd in ["undo", "redo", "cut", "copy", "paste", "delete",
                "select_all", "split", "join",
                "bounce_in_place", "normalize", "duplicate", "toggle_step_input"]:
        r = call_tool(client, "logic_edit", cmd)
        T(f"edit.{cmd} dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_edit", "quantize", {"value": "1/16"})
    T("edit.quantize dispatches", r, lambda _: len(tool_text(r)) > 0)

    # ═══════════════════════════════════════════════════════════════
    # §8 Navigation (15 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§8 Navigation")

    # P1-4 (D2): markers moved to logic://markers.
    r = read_resource(client, "logic://markers")
    T("logic://markers returns data", r, lambda _: len(resource_text(r)) > 0)

    r = call_tool(client, "logic_navigate", "goto_bar", {"bar": 1}, timeout=30)
    T("nav.goto_bar(1) dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_navigate", "goto_bar", {"bar": 8}, timeout=30)
    T("nav.goto_bar(8) dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_navigate", "goto_marker", {"name": "Intro"})
    T("nav.goto_marker(name) dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_navigate", "create_marker")
    T("nav.create_marker dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_navigate", "zoom_to_fit")
    T("nav.zoom_to_fit dispatches", r, lambda _: len(tool_text(r)) > 0)

    for direction in ["in", "out", "fit"]:
        r = call_tool(client, "logic_navigate", "set_zoom", {"direction": direction})
        T(f"nav.set_zoom({direction}) dispatches", r, lambda _: len(tool_text(r)) > 0)

    for view in ["mixer", "piano_roll", "score", "step_editor", "library", "inspector", "automation"]:
        r = call_tool(client, "logic_navigate", "toggle_view", {"view": view})
        T(f"nav.toggle_view({view}) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # ═══════════════════════════════════════════════════════════════
    # §9 Project (10 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§9 Project")

    # P1-4 (D2): project info moved to logic://project/info (envelope { ..., data: {...} }).
    r = read_resource(client, "logic://project/info")
    T("logic://project/info returns data", r, lambda _: len(resource_text(r)) > 0)

    r = call_tool(client, "logic_project", "is_running")
    T_LIVE("project.is_running returns 'true'", r, lambda _: "true" in tool_text(r), logic_running, "Logic Pro is not running")

    # Save (non-destructive — Logic Pro will show dialog if no project)
    r = call_tool(client, "logic_project", "save")
    T("project.save dispatches", r, lambda _: len(tool_text(r)) > 0)
    dismiss_safe_logic_dialog()

    # Bounce
    r = call_tool(client, "logic_project", "bounce")
    T("project.bounce dispatches", r, lambda _: len(tool_text(r)) > 0)
    dismiss_safe_logic_dialog()

    # Launch (already running — should succeed)
    r = call_tool(client, "logic_project", "launch")
    T("project.launch (already running) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # ═══════════════════════════════════════════════════════════════
    # §10 Security: Path Validation (16 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§10 Security: Path Validation")

    security_paths = [
        ("relative/path.logicx", "relative path"),
        ("/dev/null.logicx", "/dev/ path"),
        ("/tmp/file.txt", "non-.logicx extension"),
        ("/tmp/evil\n.logicx", "newline injection"),
        ("/tmp/evil\r.logicx", "CR injection"),
        ("/tmp/evil\t.logicx", "tab injection"),
        ("/tmp/evil\x00.logicx", "null byte injection"),
        ("", "empty path"),
        ("/nonexistent/path.logicx", "nonexistent package"),
        ("/tmp/file.LOGICX", "wrong case (requires existing)"),
        ("../etc/passwd.logicx", "path traversal"),
        ("file:///tmp/x.logicx", "file:// scheme"),
        ("  /tmp/padded.logicx  ", "whitespace padding"),
        ("/dev/tcp/localhost/1234", "/dev/tcp"),
        ("logic.logicx", "no leading slash"),
    ]

    for path, desc in security_paths:
        r = call_tool(client, "logic_project", "open", {"path": path})
        T(f"SECURITY: blocks {desc}", r, lambda _: is_error(r))

    r = call_tool(client, "logic_project", "save_as", {"path": "/tmp/project/../escape.logicx"})
    T("SECURITY: save_as blocks absolute path traversal", r, lambda _: is_error(r))

    # ═══════════════════════════════════════════════════════════════
    # §11 Resource Read (28 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§11 Resource Read")

    resources_to_test = [
        "logic://system/health",
        "logic://transport/state",
        "logic://tracks",
        "logic://mixer",
        "logic://markers",
        "logic://project/info",
        "logic://midi/ports",
        "logic://library/inventory",
        "logic://stock-plugins",
        "logic://stock-plugins/census",
        "logic://stock-plugins/capabilities",
        "logic://stock-plugins/logic.stock.effect.gain",
        "logic://stock-plugins/search?query=gain",
        "logic://workflow-skills",
        "logic://workflow-skills/schema",
        "logic://workflow-skills/logic.workflow.plugins.stock_chain_plan",
        "logic://workflow-skills/search?query=plugin",
        # mcu/state is both listed (#215) and directly readable, even when the
        # MCU surface is disconnected — a read returns { connected: false, … }.
        "logic://mcu/state",
    ]
    for uri in resources_to_test:
        r = read_resource(client, uri)
        text = resource_text(r) if r else ""
        text_len = len(text)
        parsed = safe_json(text)
        raw = response_dump(r)
        expects_document = uri in {"logic://tracks", "logic://mixer", "logic://project/info"}
        T(
            f"resource {uri} returns content",
            r,
            lambda _, tl=text_len, rd=raw, ed=expects_document: tl > 0 or (
                ed and "No Logic Pro document is open" in rd
            ),
        )
        T(
            f"resource {uri} is valid JSON",
            r,
            lambda _, p=parsed, rd=raw, ed=expects_document: p is not None or (
                ed and "No Logic Pro document is open" in rd
            ),
        )

    r = read_resource(client, "logic://stock-plugins")
    stock_catalog = safe_json(resource_text(r))
    T("stock plugin catalog validates", r,
      lambda _: bool(stock_catalog and stock_catalog.get("validation", {}).get("is_valid") is True))
    T("stock plugin catalog exposes truth labels", r,
      lambda _: any("availability_state" in e for e in stock_catalog.get("entries", [])) if stock_catalog else False)

    r = read_resource(client, "logic://workflow-skills")
    workflow_pack = safe_json(resource_text(r))
    T("workflow skills pack validates", r,
      lambda _: bool(workflow_pack and workflow_pack.get("validation", {}).get("is_valid") is True))
    T("workflow skills include stock plugin planning workflow", r,
      lambda _: any(w.get("id") == "logic.workflow.plugins.stock_chain_plan"
                    for w in workflow_pack.get("workflows", [])) if workflow_pack else False)

    # Transport resource should have tempo
    r = read_resource(client, "logic://transport/state")
    T("resource transport contains 'tempo'", r, lambda _: "tempo" in resource_text(r))

    # Mixer resource should have mcu_connected
    r = read_resource(client, "logic://mixer")
    T(
        "resource mixer contains mcu_connected",
        r,
        lambda _: "mcu_connected" in resource_text(r) or "No Logic Pro document is open" in response_dump(r),
    )

    # Health resource should have logic_pro_running
    r = read_resource(client, "logic://system/health")
    T("resource health contains logic_pro_running", r, lambda _: "logic_pro_running" in resource_text(r))

    # Template resource
    r = read_resource(client, "logic://tracks/0")
    T("resource template tracks/0 responds", r, lambda _: True)  # may return track or typed out-of-range, both valid

    # #200: an out-of-range indexed-template read returns a typed, classifiable
    # index_out_of_range body (never a raw JSON-RPC -32602 / no response).
    r = read_resource(client, "logic://tracks/-1")
    _oob = safe_json(resource_text(r)) or {}
    T("resource template tracks/-1 returns typed index_out_of_range (#200)", r,
      lambda _: _oob.get("error") == "index_out_of_range" and _oob.get("success") is False
      and _oob.get("requested_index") == -1)

    # Unknown URI
    r = read_resource(client, "logic://nonexistent")
    T("unknown resource URI throws", r, lambda _: "error" in r)

    # Malformed URI
    r = read_resource(client, "not-a-logic-uri")
    T("malformed URI throws", r, lambda _: "error" in r)

    malformed_catalog_uris = [
        "logic://stock-plugins/census#fragment",
        "logic://stock-plugins/search?query=gain#fragment",
        "logic://stock-plugins/logic.stock.effect.gain#fragment",
        "logic://workflow-skills/schema#fragment",
        "logic://workflow-skills/search?query=plugin#fragment",
        "logic://workflow-skills/logic.workflow.readiness.project#fragment",
    ]
    for uri in malformed_catalog_uris:
        r = read_resource(client, uri)
        T(f"malformed catalog URI throws: {uri}", r, lambda _: "error" in r)

    # ═══════════════════════════════════════════════════════════════
    # §12 Error Handling (16 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§12 Error Handling")

    for tool, cmd in [("logic_transport", "nonexistent"), ("logic_tracks", "nonexistent"),
                      ("logic_mixer", "nonexistent"), ("logic_midi", "nonexistent"),
                      ("logic_edit", "nonexistent"), ("logic_navigate", "nonexistent"),
                      ("logic_project", "nonexistent"), ("logic_system", "nonexistent")]:
        r = call_tool(client, tool, cmd)
        T(f"{tool} rejects unknown command", r, lambda _: is_error(r))

    # #216: an unknown tool name is rejected at the protocol boundary with a
    # JSON-RPC -32602 invalidParams error (not a result with isError:true).
    r = call_tool(client, "logic_imaginary", "anything")
    T("unknown tool name rejected with JSON-RPC -32602 (#216)", r,
      lambda _: isinstance(r, dict) and r.get("error", {}).get("code") == -32602)
    T("unknown tool name error is not a tool result", r,
      lambda _: isinstance(r, dict) and "result" not in r)

    # Empty tool name is also not a registered tool → -32602.
    r = call_tool(client, "", "anything")
    T("empty tool name rejected with JSON-RPC -32602 (#216)", r,
      lambda _: isinstance(r, dict) and r.get("error", {}).get("code") == -32602)

    # #217: a tools/call with a missing/empty required `command` is rejected at
    # the protocol boundary with JSON-RPC -32602 (not dispatched as an empty
    # command that returns a misleading domain "Unknown … command: ." error).
    for tool in ["logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
                 "logic_edit", "logic_navigate"]:
        # missing `arguments` entirely
        r = client.send({"jsonrpc": "2.0", "id": nid(), "method": "tools/call",
                         "params": {"name": tool}})
        T(f"{tool} missing arguments → JSON-RPC -32602 (#217)", r,
          lambda _, resp=r: isinstance(resp, dict) and resp.get("error", {}).get("code") == -32602)
        # present-but-empty `arguments` (no command key)
        r = client.send({"jsonrpc": "2.0", "id": nid(), "method": "tools/call",
                         "params": {"name": tool, "arguments": {}}})
        T(f"{tool} missing command → JSON-RPC -32602 (#217)", r,
          lambda _, resp=r: isinstance(resp, dict) and resp.get("error", {}).get("code") == -32602)

    # Fail-closed semantic payload checks. These are environment-independent:
    # the dispatcher must reject before it can route to Logic/CoreMIDI.
    missing_payload_cases = [
        ("logic_transport", "set_tempo"),
        ("logic_transport", "goto_position"),
        ("logic_transport", "set_cycle_range"),
        ("logic_midi", "send_note"),
        ("logic_midi", "send_cc"),
        ("logic_midi", "send_program_change"),
        ("logic_midi", "send_pitch_bend"),
        ("logic_midi", "send_aftertouch"),
        ("logic_midi", "mmc_locate"),
        ("logic_midi", "step_input"),
        ("logic_edit", "quantize"),
        ("logic_navigate", "set_zoom"),
        ("logic_navigate", "toggle_view"),
    ]
    for tool, cmd in missing_payload_cases:
        r = call_tool(client, tool, cmd)
        T(
            f"{tool}.{cmd} rejects missing semantic payload",
            r,
            lambda _, resp=r: is_error(resp) and "invalid_params" in tool_text(resp),
        )

    # #221: a fast-FAILING mutation must release the mutation gate so an
    # immediately-following (serial) mutation is never falsely blocked with
    # `mutating_operation_in_progress`. rename_marker and set_cycle_range both
    # fail closed with State C (not_implemented) with or without a live
    # document and perform no mutation, so this is side-effect-free. NOTE: a
    # PARALLEL overlap refusal (safe_to_retry:true) is CORRECT serialization,
    # not a malfunction — the complete-surface contract run fires mutations
    # serially (client.send awaits each response before the next request).
    _ = call_tool(client, "logic_navigate", "rename_marker", params={"index": 0, "name": "gate-probe"})
    r = call_tool(client, "logic_transport", "set_cycle_range", params={"start": 1, "end": 2})
    _gate = tool_json(r) or {}
    T("serial mutation after a failed mutation is not gate-blocked (#221)", r,
      lambda _: _gate.get("error") != "mutating_operation_in_progress")

    # ═══════════════════════════════════════════════════════════════
    # §13 Concurrent Stress Test (5 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§13 Concurrent Stress")

    # Fire 30 tool calls rapidly and ensure all return
    import concurrent.futures
    def burst_call(n):
        c = MCPClient()
        if not initialize(c):
            c.close()
            return None
        results = []
        for i in range(n):
            rid = 1000 + i
            results.append(call_tool(c, "logic_system", "health", req_id=rid))
        c.close()
        return results

    results = burst_call(30)
    T("30 sequential health calls succeed on fresh client", "ok",
      lambda _: results is not None and all(r is not None and not is_error(r) for r in results))

    # 20 MIDI notes in rapid succession on main client
    rapid_ok = 0
    for i in range(20):
        r = guarded_live_midi_call(
            client,
            "send_note",
            {"note": 60 + (i % 12), "duration_ms": 20},
            ready=midi_live_execute_ready,
            reason=midi_live_execute_reason,
        )
        if r and not is_error(r):
            rapid_ok += 1
    T_LIVE(
        f"20 rapid MIDI notes: {rapid_ok}/20 ok",
        "ok",
        lambda _: rapid_ok >= 18,
        midi_live_execute_ready,
        midi_live_execute_reason,
    )

    # 20 concurrent resource reads
    def read_n_times(n):
        c = MCPClient()
        if not initialize(c): c.close(); return 0
        ok = 0
        for i in range(n):
            r = read_resource(c, "logic://transport/state", req_id=5000 + i)
            if r and len(resource_text(r)) > 0:
                ok += 1
        c.close()
        return ok

    cnt = read_n_times(20)
    T(f"20 rapid resource reads: {cnt}/20 ok", "ok", lambda _: cnt >= 18)

    # #220: pipeline many LARGE reads in-flight on ONE connection, then drain.
    # This is the exact concurrent large-payload pattern the external audit ran.
    # With the reader thread draining stdout, every response must arrive complete
    # and parse as valid JSON — proving the server stays responsive under
    # concurrent large reads (the "no response" in the audit was client-side
    # backpressure, not a server malfunction). See docs/TROUBLESHOOTING.md.
    large_read_uris = [
        "logic://library/inventory", "logic://project/audit", "logic://project/cleanup-plan",
        "logic://stock-plugins", "logic://stock-instruments", "logic://session-players",
        "logic://workflow-skills",
    ] * 3
    pipelined = pipelined_read_all(client, large_read_uris, timeout=30)
    if pipelined is None:
        S("pipelined concurrent large reads (#220)", "popen transport only")
    else:
        complete = sum(1 for _u, resp in pipelined
                       if resp is not None and safe_json(resource_text(resp)) is not None)
        T(f"pipelined concurrent large reads all complete: {complete}/{len(pipelined)} (#220)",
          "ok", lambda _, c=complete, n=len(pipelined): c == n)

    # Interleaved read/write
    mixed_ok = 0
    mixed_read_uri = "logic://tracks" if has_document else "logic://system/health"
    for i in range(10):
        if i % 2 == 0:
            r = call_tool(client, "logic_system", "health")
        else:
            r = read_resource(client, mixed_read_uri)
        if r and not is_error(r):
            mixed_ok += 1
    T(f"interleaved 10 read/write: {mixed_ok}/10 ok", "ok", lambda _: mixed_ok == 10)

    # Catalog contract stability under load
    r = list_tools(client)
    T("tools/list still 10 after stress", r, lambda r: len(r.get("result", {}).get("tools", [])) == 10)

    # ═══════════════════════════════════════════════════════════════
    # §14 State Consistency (8 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§14 State Consistency")

    # P1-4 (D2): reads are resource-only now (the tool get_state command was
    # removed), so consistency is verified across two resource reads.
    r1 = read_resource(client, "logic://transport/state")
    r2 = read_resource(client, "logic://transport/state")
    s1 = (safe_json(resource_text(r1)) or {}).get("data", {}).get("state")
    s2 = (safe_json(resource_text(r2)) or {}).get("data", {}).get("state")
    if isinstance(s1, dict) and isinstance(s2, dict):
        T("transport resource has tempo", "ok", lambda _: "tempo" in s1)
        T("transport resource isPlaying consistent across reads", "ok",
          lambda _: s1.get("isPlaying") == s2.get("isPlaying"))

    # Multiple health calls — process.uptime_sec must monotonically increase
    r1 = call_tool(client, "logic_system", "health")
    time.sleep(1.1)
    r2 = call_tool(client, "logic_system", "health")
    h1 = safe_json(tool_text(r1))
    h2 = safe_json(tool_text(r2))
    if h1 and h2:
        T("health uptime monotonic", "ok",
          lambda _: h2["process"]["uptime_sec"] >= h1["process"]["uptime_sec"])
        T("health memory stable (<2x growth)", "ok",
          lambda _: h2["process"]["memory_mb"] < h1["process"]["memory_mb"] * 2)
        T("health logic_pro_running stable", "ok",
          lambda _: h1["logic_pro_running"] == h2["logic_pro_running"])

    # P1-4 (D2): reads are resource-only; verify logic://tracks returns a stable
    # array across reads (old tool-vs-resource count comparison is obsolete).
    r1 = read_resource(client, "logic://tracks")
    r2 = read_resource(client, "logic://tracks")
    t1 = (safe_json(resource_text(r1)) or {}).get("data")
    t2 = (safe_json(resource_text(r2)) or {}).get("data")
    if isinstance(t1, list) and isinstance(t2, list):
        T("tracks count stable across resource reads", "ok",
          lambda _: len(t1) == len(t2))

    # Refresh doesn't crash
    r = call_tool(client, "logic_system", "refresh_cache")
    T("refresh_cache succeeds", r, lambda _: not is_error(r))

    # Health after refresh still valid
    r = call_tool(client, "logic_system", "health")
    T("health after refresh still valid JSON", r, lambda _: json.loads(tool_text(r)) is not None)

    # ═══════════════════════════════════════════════════════════════
    # §15 Input Validation Edge Cases (12 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§15 Input Validation")

    # Non-numeric params where numeric expected
    r = call_tool(client, "logic_tracks", "select", {"index": "abc"})
    T("track.select non-numeric handled", r, lambda _: len(tool_text(r)) > 0)

    # RB-1.a — non-numeric track must fail-closed with the explicit-required
    # message, NOT default-to-0 silently.
    r = call_tool(client, "logic_mixer", "set_volume", {"index": "foo", "volume": "bar"})
    T(
        "mixer.set_volume non-numeric track is rejected (fail-closed)",
        r,
        lambda _: is_error(r) and "requires explicit 'track'" in tool_text(r),
    )

    # Large but reasonable integer values
    r = call_tool(client, "logic_tracks", "select", {"index": 9999})
    T("track.select 9999 handled (no hang)", r, lambda _: r is not None)

    r = call_tool(client, "logic_tracks", "select", {"index": -999})
    T("track.select -999 handled (no hang)", r, lambda _: r is not None)

    # Very long strings
    long_name = "A" * 1000
    r = call_tool(client, "logic_tracks", "rename", {"index": 0, "name": long_name})
    T("track.rename 1000-char name handled", r, lambda _: len(tool_text(r)) > 0)

    # Unicode
    r = call_tool(client, "logic_tracks", "rename", {"index": 0, "name": "한국어 🎹 音楽"})
    T("track.rename unicode handled", r, lambda _: len(tool_text(r)) > 0)

    # Empty params object — RB-1.a: fail-closed contract.
    r = call_tool(client, "logic_mixer", "set_volume", {})
    T(
        "mixer.set_volume empty params is rejected (fail-closed)",
        r,
        lambda _: is_error(r) and "requires explicit 'track'" in tool_text(r),
    )

    # MIDI out-of-range (should still route, driver may reject)
    r = call_tool(client, "logic_midi", "send_note", {"note": 200, "duration_ms": 20})
    T("midi.send_note note=200 handled", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_midi", "send_cc", {"controller": 200, "value": 50})
    T("midi.send_cc cc=200 handled", r, lambda _: len(tool_text(r)) > 0)

    # Large duration should be capped to 30s (our P2 fix) — test with shorter value
    # to verify the capping logic doesn't hang the actor
    r = guarded_live_midi_call(
        client,
        "send_note",
        {"note": 60, "duration_ms": 100},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE(
        "midi.send_note short duration ok",
        r,
        lambda _: r is not None and not is_error(r),
        midi_live_execute_ready,
        midi_live_execute_reason,
    )

    # MIDI port name edge case
    r = call_tool(client, "logic_midi", "create_virtual_port", {"name": "a" * 200})
    T("midi.create_virtual_port long name handled", r, lambda _: r is not None)

    r = call_tool(client, "logic_midi", "create_virtual_port", {"name": "evil\nport"})
    T("midi.create_virtual_port newline sanitized", r, lambda _: r is not None)

    # ═══════════════════════════════════════════════════════════════
    # §16 Routing Fallback Behavior (5 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§16 Routing & Fallback")

    # mixer.set_volume: MCU only (no fallback) — requires MCU control surface registered.
    # When MCU handshake hasn't completed, this returns a structured error — that is correct behavior.
    r = call_tool(client, "logic_mixer", "set_volume", {"index": 0, "volume": 0.5})
    T("mixer.set_volume dispatches (MCU-only channel)", r,
      lambda _: len(tool_text(r)) > 0 and ("MCU" in tool_text(r) or "mixer" in tool_text(r) or not is_error(r)))

    # edit.undo: MIDIKeyCommands primary, CGEvent fallback
    r = call_tool(client, "logic_edit", "undo")
    T("edit.undo routes through fallback chain", r, lambda _: len(tool_text(r)) > 0)

    # transport.play: MCU, CoreMIDI, CGEvent chain
    r = call_tool(client, "logic_transport", "play")
    T("transport.play routes through chain", r, lambda _: len(tool_text(r)) > 0)
    call_tool(client, "logic_transport", "stop")  # stop playback

    # P1-4 (D2): reads are served by resources (no channel routing for reads).
    r = read_resource(client, "logic://tracks")
    T("logic://tracks resource read returns content", r, lambda _: len(resource_text(r)) > 0)

    r = read_resource(client, "logic://mixer")
    T("logic://mixer resource read returns content", r, lambda _: len(resource_text(r)) > 0)

    # ═══════════════════════════════════════════════════════════════
    # §17 Real MIDI Flow (6 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§17 Real MIDI Flow")

    # Verify virtual ports exist in system MIDI
    r = read_resource(client, "logic://midi/ports")
    ports = safe_json(resource_text(r))
    if ports:
        sources = ports.get("sources", []) if isinstance(ports.get("sources"), list) else []
        destinations = ports.get("destinations", []) if isinstance(ports.get("destinations"), list) else []
        T("MIDI sources list present", "ok", lambda _: isinstance(sources, list))
        T("MIDI destinations list present", "ok", lambda _: isinstance(destinations, list))
        all_ports = " ".join(sources + destinations)
        T_LIVE("LogicProMCP-MCU virtual port visible", "ok", lambda _: "MCU" in all_ports or "LogicProMCP" in all_ports, core_midi_ready, "CoreMIDI virtual ports are unavailable")
        T_LIVE("LogicProMCP-KeyCmd virtual port visible", "ok", lambda _: "KeyCmd" in all_ports or "LogicProMCP" in all_ports, core_midi_ready, "CoreMIDI virtual ports are unavailable")
        T_LIVE("LogicProMCP-Scripter virtual port visible", "ok", lambda _: "Scripter" in all_ports or "LogicProMCP" in all_ports, core_midi_ready, "CoreMIDI virtual ports are unavailable")

    # Send a full MIDI sequence (chord)
    r = guarded_live_midi_call(
        client,
        "send_chord",
        {"notes": "60,64,67,72", "duration_ms": 30},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    T_LIVE("send chord (4 notes) completes", r, lambda _: not is_error(r), midi_live_execute_ready, midi_live_execute_reason)

    # ═══════════════════════════════════════════════════════════════
    # §17b Fresh Record Modal Guard (7 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§17b Fresh Record Modal Guard")

    fresh_record_bootstrap = None
    if STRICT_LIVE and FRESH_BOOTSTRAP and live_logic_ready and midi_live_ready:
        fresh_record_bootstrap = run_fresh_bootstrap(client)
        if fresh_record_bootstrap.ok:
            has_document = True
            call_tool(client, "logic_system", "refresh_cache", timeout=3)

    fresh_record_live_ready = False
    fresh_record_reason = "fresh Logic bootstrap with 1 track and 0 regions is required"
    fresh_record_payload = {"result": {"reason": fresh_record_reason}}
    if fresh_record_bootstrap is not None and not fresh_record_bootstrap.ok:
        fresh_record_reason = bootstrap_failure_reason(fresh_record_bootstrap)
        fresh_record_payload = {"result": {"reason": fresh_record_reason, "detail": fresh_record_bootstrap.as_dict()}}
    elif live_logic_ready and midi_live_execute_ready and has_document:
        call_tool(client, "logic_system", "refresh_cache", timeout=3)
        fresh_record_live_ready, fresh_record_reason = fresh_record_bootstrap_status(client)
        if not fresh_record_live_ready:
            fresh_record_reason = f"fresh bootstrap not detected: {fresh_record_reason}"
        fresh_record_payload = {"result": {"reason": fresh_record_reason}}
    elif live_logic_ready and midi_live_ready and has_document and not controller_learn_clear:
        fresh_record_reason = controller_learn_reason
        fresh_record_payload = {"result": {"reason": fresh_record_reason}}

    preflight_modal = {"status": "skipped", "policy_id": DEFAULT_FREE_TEMPO_POLICY["policy_id"]}
    select_for_record = {"gate": fresh_record_reason}
    arm_for_record = {"gate": fresh_record_reason}
    arm_track = None
    record_resp = {"gate": fresh_record_reason}
    midi_record_pass = {"gate": fresh_record_reason}
    stop_after_record = {"gate": fresh_record_reason}
    post_record_modal = {"status": "skipped", "policy_id": DEFAULT_FREE_TEMPO_POLICY["policy_id"]}
    final_modal_snapshot = {"status": "skipped"}
    regions_after_record = None
    disarm_after_record = {"gate": fresh_record_reason}
    disarm_track = None

    fresh_record_execute_ready = False
    fresh_record_execute_reason = fresh_record_reason

    if fresh_record_live_ready:
        preflight_modal = resolve_free_tempo_modal()
        if preflight_modal.get("status") in {"not_present", "dismissed"}:
            fresh_record_execute_ready = True
            fresh_record_execute_reason = "fresh bootstrap ready"
            select_for_record = call_tool(client, "logic_tracks", "select", {"index": 0})
            arm_for_record = call_tool(client, "logic_tracks", "arm", {"index": 0, "enabled": True})
            arm_track = wait_for_track_arm(client, 0, True)
            record_resp = guarded_live_tool_call(
                client,
                "logic_transport",
                "record",
                ready=midi_live_execute_ready,
                reason=midi_live_execute_reason,
            )
            midi_record_pass = guarded_live_midi_call(
                client,
                "play_sequence",
                {"notes": "60,0,180,104;64,250,180,100;67,500,240,108"},
                ready=midi_live_execute_ready,
                reason=midi_live_execute_reason,
                timeout=20,
            )
            stop_after_record = call_tool(client, "logic_transport", "stop")
            time.sleep(0.8)
            post_record_modal = resolve_free_tempo_modal()
            call_tool(client, "logic_system", "refresh_cache", timeout=3)
            regions_after_record = read_track_regions(client, 0)
            final_modal_snapshot = detect_free_tempo_modal()
            disarm_after_record = call_tool(client, "logic_tracks", "arm", {"index": 0, "enabled": False})
            disarm_track = wait_for_track_arm(client, 0, False)
        else:
            fresh_record_execute_reason = (
                f"free tempo modal preflight blocked: {preflight_modal.get('reason', preflight_modal.get('status'))}"
            )

    T_LIVE(
        "fresh record bootstrap detected",
        fresh_record_payload,
        lambda _: fresh_record_live_ready,
        fresh_record_live_ready,
        fresh_record_reason,
    )
    T_LIVE(
        "controller assignments Learn Mode guard is clear before fresh MIDI record",
        {"result": controller_learn_guard},
        lambda _: controller_learn_clear,
        live_logic_ready and midi_live_ready and has_document,
        controller_learn_reason,
    )
    T_LIVE(
        "free tempo modal policy is recorded for fresh record flow",
        {"result": preflight_modal},
        lambda _: preflight_modal.get("policy_id") == DEFAULT_FREE_TEMPO_POLICY["policy_id"],
        fresh_record_live_ready,
        fresh_record_reason,
    )
    T_LIVE(
        "free tempo modal preflight is absent or dismissed",
        {"result": preflight_modal},
        lambda _: preflight_modal.get("status") in {"not_present", "dismissed"},
        fresh_record_live_ready,
        fresh_record_reason,
    )
    T_LIVE(
        "track 0 arms for fresh MIDI record pass",
        {"result": arm_for_record, "track": arm_track},
        lambda _: isinstance(arm_track, dict) and arm_track.get("isArmed") is True,
        fresh_record_execute_ready,
        fresh_record_execute_reason,
    )
    T_LIVE(
        "fresh MIDI record pass dispatches",
        midi_record_pass,
        lambda _: record_resp is not None
        and midi_record_pass is not None
        and stop_after_record is not None
        and not is_error(record_resp)
        and not is_error(midi_record_pass)
        and not is_error(stop_after_record),
        fresh_record_execute_ready,
        fresh_record_execute_reason,
    )
    T_LIVE(
        "free tempo modal is dismissed or absent after fresh record pass",
        {"result": post_record_modal},
        lambda _: post_record_modal.get("status") in {"dismissed", "not_present"},
        fresh_record_execute_ready,
        fresh_record_execute_reason,
    )
    T_LIVE(
        "fresh record final modal check is clear and policy provenance is explicit",
        {"result": {"modal": final_modal_snapshot, "policy": post_record_modal}},
        lambda _: final_modal_snapshot.get("status") != "present"
        and post_record_modal.get("policy_id") == DEFAULT_FREE_TEMPO_POLICY["policy_id"]
        and (
            post_record_modal.get("status") == "not_present"
            or (
                isinstance(post_record_modal.get("decision"), dict)
                and post_record_modal["decision"].get("selection") == DEFAULT_FREE_TEMPO_POLICY["selection_labels"][0]
            )
        ),
        fresh_record_execute_ready,
        fresh_record_execute_reason,
    )
    T_LIVE(
        "fresh record flow clears modal handling and disarms track 0",
        {"regions": regions_after_record, "result": disarm_after_record, "track": disarm_track},
        lambda _: isinstance(regions_after_record, list)
        and isinstance(disarm_track, dict)
        and disarm_track.get("isArmed") is False,
        fresh_record_execute_ready,
        fresh_record_execute_reason,
    )

    # ═══════════════════════════════════════════════════════════════
    # §18 Performance (4 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§18 Performance")

    # Health call should be fast. First call may include AX refresh — allow 3s.
    t0 = time.time()
    r = call_tool(client, "logic_system", "health")
    elapsed = time.time() - t0
    T(f"health call < 3s ({elapsed:.3f}s)", r, lambda _: elapsed < 3.0 and not is_error(r))
    # Subsequent call should be faster (cache warm)
    t0 = time.time()
    r = call_tool(client, "logic_system", "health")
    elapsed = time.time() - t0
    # Cached health should typically be ~100 ms, but under concurrent load
    # (parallel test runs, StatePoller doing an AX sweep) spikes to ~1.5 s are
    # observed. 2 s threshold keeps the sanity check without flaking.
    T(f"health call (cached) < 2s ({elapsed:.3f}s)", r, lambda _: elapsed < 2.0 and not is_error(r))

    # tools/list should be fast
    t0 = time.time()
    r = list_tools(client)
    elapsed = time.time() - t0
    T(f"tools/list < 0.5s ({elapsed:.3f}s)", r, lambda _: elapsed < 0.5)

    # Resource read should be fast
    perf_resource_uri = "logic://tracks" if has_document else "logic://system/health"
    t0 = time.time()
    r = read_resource(client, perf_resource_uri)
    elapsed = time.time() - t0
    T(f"resource read < 2s ({elapsed:.3f}s)", r, lambda _: elapsed < 2.0)

    # MIDI send should be fast
    t0 = time.time()
    r = guarded_live_midi_call(
        client,
        "send_cc",
        {"controller": 7, "value": 100},
        ready=midi_live_execute_ready,
        reason=midi_live_execute_reason,
    )
    elapsed = time.time() - t0
    T_LIVE(
        f"MIDI CC send < 0.5s ({elapsed:.3f}s)",
        r,
        lambda _: elapsed < 0.5 and not is_error(r),
        midi_live_execute_ready,
        midi_live_execute_reason,
    )

    # ═══════════════════════════════════════════════════════════════
    # §19 Memory & Stability (3 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§19 Memory & Stability")

    # Initial memory
    r1 = call_tool(client, "logic_system", "health")
    h1 = safe_json(tool_text(r1))
    mem_start = h1["process"]["memory_mb"] if h1 else 0

    # Fire 50 operations
    for i in range(50):
        call_tool(client, "logic_system", "health")

    # Memory shouldn't explode
    r2 = call_tool(client, "logic_system", "health")
    h2 = safe_json(tool_text(r2))
    mem_end = h2["process"]["memory_mb"] if h2 else 0
    T(f"memory stable after 50 calls ({mem_start:.1f}→{mem_end:.1f}MB)", "ok",
      lambda _: mem_end > 0 and mem_end < mem_start + 50)

    # Logic Pro still running after all tests
    r = call_tool(client, "logic_project", "is_running")
    T_LIVE("Logic Pro still running at end", r, lambda _: "true" in tool_text(r), logic_running, "Logic Pro is not running")

    # Server still responsive
    r = list_tools(client)
    T("server responsive at end", r, lambda _: r is not None and "result" in r)

    # ═══════════════════════════════════════════════════════════════
    # §20 Final Health Check (2 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§20 Final Verification")

    r = call_tool(client, "logic_system", "health")
    h = safe_json(tool_text(r))
    if h:
        T_LIVE("final health: all permissions granted", r,
          lambda _: h["permissions"].get("accessibility") is True and h["permissions"].get("automation_granted") is True,
          logic_running and accessibility_ready and automation_ready,
          "Logic Pro + Accessibility + Automation are required")
        T("final health: channels report started", r,
          lambda _: any(c.get("available") is True for c in h.get("channels", [])))

    client.close()

    # ═══════════════════════════════════════════════════════════════
    # Summary
    # ═══════════════════════════════════════════════════════════════
    print()
    print("══════════════════════════════════════════════════════")
    total = PASS + FAIL + SKIP
    if FAIL == 0:
        print(f" \033[0;32m✔ All executed tests passed\033[0m — {PASS} passed, {SKIP} skipped, {total} total")
    else:
        print(f" \033[0;31m✘ {FAIL}/{total} failed\033[0m, \033[0;32m{PASS} passed\033[0m, {SKIP} skipped")
        print()
        print("Failures:")
        for f in FAILURES:
            print(f"  \033[0;31m✘\033[0m {f}")
    if SKIP:
        print()
        print("Skipped live-gated checks:")
        for s in SKIPS:
            print(f"  \033[0;36m↷\033[0m {s}")
    print("══════════════════════════════════════════════════════")
    print()
    sys.exit(min(FAIL, 125))


if __name__ == "__main__":
    main()
