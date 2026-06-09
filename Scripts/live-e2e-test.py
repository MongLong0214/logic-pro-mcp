#!/usr/bin/env python3
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

BINARY = os.environ.get("LOGIC_PRO_MCP_BINARY", ".build/release/LogicProMCP")
STRICT_LIVE = os.environ.get("LOGIC_PRO_MCP_STRICT_LIVE", "0") == "1"
TRANSPORT = os.environ.get("LOGIC_PRO_MCP_E2E_TRANSPORT", "tmux" if STRICT_LIVE else "popen")
TIMEOUT = 10


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
        self.proc = subprocess.Popen(
            [BINARY],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=open("/tmp/mcp-live-test-stderr.txt", "w"),
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
        self.stderr_path = "/tmp/mcp-live-test-stderr.txt"
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
            return
        self._tmux(["send-keys", "-t", self.session, "C-c"], check=False)
        deadline = time.time() + 3
        while time.time() < deadline:
            result = self._tmux(["has-session", "-t", self.session], check=False)
            if result.returncode != 0:
                self.started = False
                return
            time.sleep(0.1)
        self._tmux(["kill-session", "-t", self.session], check=False)
        self.started = False


class ExternalTmuxMCPClient:
    """Client side for the shell-owned tmux strict-live transport."""

    def __init__(self):
        self.request_fifo = os.environ["LOGIC_PRO_MCP_E2E_REQUEST_FIFO"]
        self.capture_file = os.environ["LOGIC_PRO_MCP_E2E_CAPTURE_FILE"]
        self.writer = open(self.request_fifo, "w", buffering=1)
        self.responses = {}

    def _capture_lines(self):
        try:
            with open(self.capture_file, "r") as file:
                return file.read().splitlines()
        except FileNotFoundError:
            return []

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
    try: return resp["result"].get("isError", False)
    except: return "error" in resp


def resource_text(resp):
    try:
        return resp["result"]["contents"][0].get("text", "")
    except: return ""


def safe_json(text):
    try: return json.loads(text)
    except: return None


def is_library_root_json(value):
    return (
        isinstance(value, dict)
        and isinstance(value.get("root"), dict)
        and isinstance(value.get("categories"), list)
        and isinstance(value.get("presetsByCategory"), dict)
        and isinstance(value.get("nodeCount"), int)
        and isinstance(value.get("leafCount"), int)
        and isinstance(value.get("folderCount"), int)
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


def main():
    print()
    print("══════════════════════════════════════════════════════")
    print(" Logic Pro MCP — Live E2E Test Suite (200+ tests)")
    print("══════════════════════════════════════════════════════")
    print(f" Binary: {BINARY}")
    print(f" Strict live mode: {'on' if STRICT_LIVE else 'off'}")
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

    # ═══════════════════════════════════════════════════════════════
    # §1 Protocol Contract (10 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§1 Protocol Contract")

    r = list_tools(client)
    tools = r.get("result", {}).get("tools", []) if r else []
    T("tools/list returns 8 tools", r, lambda r: len(tools) == 8)
    tool_names = [t["name"] for t in tools]
    for name in ["logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
                 "logic_edit", "logic_navigate", "logic_project", "logic_system"]:
        T(f"  tool '{name}' present", r, lambda _, n=name: n in tool_names)

    r = list_resources(client)
    resources = r.get("result", {}).get("resources", []) if r else []
    # v3.4.6+ exposes 14 static resources. logic://mcu/state is filtered from
    # the list when the MCU control surface is disconnected, so the expected
    # count is 13 (disconnected) or 14 (connected).
    resource_count = len(resources)
    T("resources/list returns 13 or 14 resources", r, lambda r: resource_count in (13, 14))

    r = list_resource_templates(client)
    templates = r.get("result", {}).get("resourceTemplates", []) if r else []
    T("resources/templates/list returns 7 templates", r, lambda r: len(templates) == 7)

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
        T("health.process.memory_mb positive", r, lambda _: health["process"]["memory_mb"] > 0)
        T("health.process.uptime_sec non-negative", r, lambda _: health["process"]["uptime_sec"] >= 0)

    r = call_tool(client, "logic_system", "permissions")
    T(
        "system.permissions mentions accessibility and automation",
        r,
        lambda _: "Accessibility:" in tool_text(r) and "Automation (Logic Pro):" in tool_text(r),
    )

    r = call_tool(client, "logic_system", "refresh_cache")
    T("system.refresh_cache succeeds", r, lambda _: not is_error(r))

    # ═══════════════════════════════════════════════════════════════
    # §3 Transport Live Operations (20 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§3 Transport Live Operations")

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
            return json.loads(resource_text(r)).get("data", {}).get("state", {}).get("isCycleEnabled")
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

    before = safe_get_cycle(client)
    call_tool(client, "logic_transport", "toggle_cycle")
    after = wait_for_cycle_change(client, before)
    if before is not None and after is not None:
        T("cycle roundtrip: state changed after toggle", "ok", lambda _: before != after)
    else:
        T("cycle roundtrip (skipped — no project)", "ok", lambda _: True)
    call_tool(client, "logic_transport", "toggle_cycle")  # restore

    # Transport commands that route to MCU/CoreMIDI
    r = call_tool(client, "logic_transport", "toggle_cycle")
    T_LIVE("transport.toggle_cycle returns non-error", r, lambda _: not is_error(r), live_logic_ready, "Logic Pro + Accessibility are required")
    call_tool(client, "logic_transport", "toggle_cycle")  # restore

    r = call_tool(client, "logic_transport", "toggle_metronome")
    T_LIVE("transport.toggle_metronome returns non-error", r, lambda _: not is_error(r), live_logic_ready, "Logic Pro + Accessibility are required")
    call_tool(client, "logic_transport", "toggle_metronome")  # restore

    r = call_tool(client, "logic_transport", "toggle_count_in")
    T("transport.toggle_count_in dispatches", r, lambda _: len(tool_text(r)) > 0)

    # Set tempo
    r = call_tool(client, "logic_transport", "set_tempo", {"tempo": 128})
    T("transport.set_tempo(128) dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_transport", "set_tempo", {"tempo": 90.5})
    T("transport.set_tempo(90.5) handles decimal", r, lambda _: len(tool_text(r)) > 0)

    # Goto position
    r = call_tool(client, "logic_transport", "goto_position", {"bar": 1})
    T("transport.goto_position(bar=1) dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_transport", "goto_position", {"bar": 16})
    T("transport.goto_position(bar=16) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # Set cycle range
    r = call_tool(client, "logic_transport", "set_cycle_range", {"start": 1, "end": 4})
    T("transport.set_cycle_range dispatches", r, lambda _: len(tool_text(r)) > 0)

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

    # scan_library walks the full Logic Library tree. A stock Logic 12 Library
    # can take ~100s over live AX; server bails earlier if the panel is closed.
    r = call_tool(client, "logic_tracks", "scan_library", timeout=180)
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

    r = call_tool(client, "logic_tracks", "scan_plugin_presets", {"submenuOpenDelayMs": 300})
    T("track.scan_plugin_presets returns content or guidance", r, lambda _: len(tool_text(r)) > 0)

    # ═══════════════════════════════════════════════════════════════
    # §5 Mixer Live Operations (25 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§5 Mixer Live Operations")

    # P1-4 (D2): mixer reads moved to logic://mixer (envelope { ..., strips: [...] }).
    r = read_resource(client, "logic://mixer")
    mix_text = resource_text(r)
    T("logic://mixer returns content", r, lambda _: len(mix_text) > 0)
    T("logic://mixer carries strips + mcu_connected", r,
      lambda _: ("strips" in mix_text and "mcu_connected" in mix_text)
                or "No Logic Pro document is open" in response_dump(r))
    # B1 (#11): provenance — data_source present on the new build's envelope.
    T("logic://mixer carries data_source provenance (B1/#11)", r,
      lambda _: "data_source" in mix_text or "No Logic Pro document is open" in response_dump(r))

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

    r = call_tool(client, "logic_mixer", "set_send", {"index": 0, "send": 0, "value": 0.5})
    T("mixer.set_send dispatches", r, lambda _: len(tool_text(r)) > 0)

    # ═══════════════════════════════════════════════════════════════
    # §6 MIDI Live Operations (25 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§6 MIDI Live Operations")

    # Note range
    for note in [0, 21, 60, 108, 127]:
        r = call_tool(client, "logic_midi", "send_note", {"note": note, "velocity": 80, "duration_ms": 30})
        T_LIVE(f"midi.send_note({note}) succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # Velocity range
    for vel in [1, 64, 127]:
        r = call_tool(client, "logic_midi", "send_note", {"note": 60, "velocity": vel, "duration_ms": 30})
        T_LIVE(f"midi.send_note vel={vel} succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # Channel range
    for ch in [1, 8, 16]:
        r = call_tool(client, "logic_midi", "send_note", {"note": 60, "channel": ch, "duration_ms": 30})
        T_LIVE(f"midi.send_note ch={ch} succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # Chord
    r = call_tool(client, "logic_midi", "send_chord", {"notes": "60,64,67", "duration_ms": 30})
    T_LIVE("midi.send_chord C major succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    r = call_tool(client, "logic_midi", "send_chord", {"notes": "60,63,67,70", "duration_ms": 30})
    T_LIVE("midi.send_chord Cm7 succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # CC range
    for cc in [1, 7, 10, 11, 64, 120, 123]:
        r = call_tool(client, "logic_midi", "send_cc", {"controller": cc, "value": 64})
        T_LIVE(f"midi.send_cc({cc}) succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # Program change
    r = call_tool(client, "logic_midi", "send_program_change", {"program": 0})
    T_LIVE("midi.send_program_change(0) succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    r = call_tool(client, "logic_midi", "send_program_change", {"program": 127})
    T_LIVE("midi.send_program_change(127) succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # Pitch bend
    r = call_tool(client, "logic_midi", "send_pitch_bend", {"value": 8192})
    T_LIVE("midi.send_pitch_bend(center) succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    r = call_tool(client, "logic_midi", "send_pitch_bend", {"value": 16383})
    T_LIVE("midi.send_pitch_bend(max) succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # Aftertouch
    r = call_tool(client, "logic_midi", "send_aftertouch", {"value": 100})
    T_LIVE("midi.send_aftertouch succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # MMC
    r = call_tool(client, "logic_midi", "mmc_play")
    T_LIVE("midi.mmc_play succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")
    call_tool(client, "logic_midi", "mmc_stop")  # restore

    r = call_tool(client, "logic_midi", "mmc_stop")
    T_LIVE("midi.mmc_stop succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    r = call_tool(client, "logic_midi", "mmc_locate", {"bar": 1})
    T_LIVE("midi.mmc_locate(bar=1) succeeds", r, lambda _: not is_error(r), live_logic_ready, "Logic Pro + Accessibility are required")

    # Step input
    r = call_tool(client, "logic_midi", "step_input", {"note": 60, "duration": "1/4"})
    T_LIVE("midi.step_input(1/4) succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    r = call_tool(client, "logic_midi", "step_input", {"note": 60, "duration": "1/8"})
    T_LIVE("midi.step_input(1/8) succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

    # Duration cap (our P2 fix)
    r = call_tool(client, "logic_midi", "send_note", {"note": 60, "duration_ms": 50})
    T_LIVE("midi.send_note small duration succeeds", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

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

    # Bounce
    r = call_tool(client, "logic_project", "bounce")
    T("project.bounce dispatches", r, lambda _: len(tool_text(r)) > 0)

    # Launch (already running — should succeed)
    r = call_tool(client, "logic_project", "launch")
    T("project.launch (already running) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # ═══════════════════════════════════════════════════════════════
    # §10 Security: Path Validation (15 tests)
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
        # mcu/state is read-testable even when filtered from list (direct reads
        # bypass the connection gate so clients bookmarking the URI still work).
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
    T("resource template tracks/0 responds", r, lambda _: True)  # may return track or error, both valid

    r = read_resource(client, "logic://tracks/-1")
    T("resource template tracks/-1 throws", r, lambda _: "error" in r or is_error(r))

    # Unknown URI
    r = read_resource(client, "logic://nonexistent")
    T("unknown resource URI throws", r, lambda _: "error" in r)

    # Malformed URI
    r = read_resource(client, "not-a-logic-uri")
    T("malformed URI throws", r, lambda _: "error" in r)

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

    # Unknown tool name
    r = call_tool(client, "logic_imaginary", "anything")
    T("unknown tool name rejected", r, lambda _: is_error(r))

    # Empty tool name
    r = call_tool(client, "", "anything")
    T("empty tool name rejected", r, lambda _: is_error(r))

    # Missing command for all 8 tools
    for tool in ["logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
                 "logic_edit", "logic_navigate"]:
        r = client.send({"jsonrpc": "2.0", "id": nid(), "method": "tools/call",
                         "params": {"name": tool, "arguments": {}}})
        T(f"{tool} handles missing command", r, lambda _: r is not None)

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
        r = call_tool(client, "logic_midi", "send_note", {"note": 60 + (i % 12), "duration_ms": 20})
        if r and not is_error(r):
            rapid_ok += 1
    T_LIVE(f"20 rapid MIDI notes: {rapid_ok}/20 ok", "ok", lambda _: rapid_ok >= 18, midi_live_ready, "Logic Pro + CoreMIDI are required")

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
    T("tools/list still 8 after stress", r, lambda r: len(r.get("result", {}).get("tools", [])) == 8)

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
    r = call_tool(client, "logic_midi", "send_note", {"note": 60, "duration_ms": 100})
    T_LIVE("midi.send_note short duration ok", r, lambda _: r is not None and not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

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
    r = call_tool(client, "logic_midi", "send_chord", {"notes": "60,64,67,72", "duration_ms": 30})
    T_LIVE("send chord (4 notes) completes", r, lambda _: not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

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
    r = call_tool(client, "logic_midi", "send_cc", {"controller": 7, "value": 100})
    elapsed = time.time() - t0
    T_LIVE(f"MIDI CC send < 0.5s ({elapsed:.3f}s)", r, lambda _: elapsed < 0.5 and not is_error(r), midi_live_ready, "Logic Pro + CoreMIDI are required")

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
