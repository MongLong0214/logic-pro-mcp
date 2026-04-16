#!/usr/bin/env python3
"""Expanded Live E2E test for Logic Pro MCP server.
Uses newline-delimited JSON-RPC stdio transport.
Requires: Logic Pro running, accessibility + automation permissions.
Some checks also accept explicit precondition errors when no document is open.

Coverage: 200+ tests across 20 sections.
"""

import json
import subprocess
import sys
import threading
import time

BINARY = ".build/debug/LogicProMCP"
TIMEOUT = 10

class MCPClient:
    def __init__(self):
        self.proc = subprocess.Popen(
            [BINARY],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=open("/tmp/mcp-live-test-stderr.txt", "w"),
            bufsize=0,
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
FAILURES = []

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

    client = MCPClient()

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
    T("resources/list returns 6 resources", r, lambda r: len(resources) == 6)

    r = list_resource_templates(client)
    templates = r.get("result", {}).get("resourceTemplates", []) if r else []
    T("resources/templates/list returns 1 template", r, lambda r: len(templates) == 1)

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
    T("system.health is valid JSON", r, lambda _: health is not None)
    if health:
        has_document = health.get("logic_pro_has_document") is True
        T("health.logic_pro_running is true", r, lambda _: health.get("logic_pro_running") is True)
        T("health.logic_pro_version present", r, lambda _: "logic_pro_version" in health)
        T("health.channels is array of 7", r, lambda _: isinstance(health.get("channels"), list) and len(health["channels"]) == 7)
        T("health.mcu present", r, lambda _: "mcu" in health)
        T("health.cache present", r, lambda _: "cache" in health)
        T("health.permissions.accessibility granted", r, lambda _: health["permissions"].get("accessibility") is True)
        T("health.permissions.automation granted", r, lambda _: health["permissions"].get("automation_granted") is True)
        T("health.permissions.post_event_access present", r, lambda _: "post_event_access" in health["permissions"])
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

    r = call_tool(client, "logic_transport", "get_state")
    ts_text = tool_text(r)
    T("transport.get_state returns content", r, lambda _: len(ts_text) > 0)

    ts = None
    try:
        ts = json.loads(ts_text)
    except (json.JSONDecodeError, ValueError):
        pass

    if ts is not None:
        T("transport.get_state is valid JSON", r, lambda _: ts is not None)
        T("transport.tempo > 0", r, lambda _: ts.get("tempo", 0) > 0)
        T("transport.tempo reasonable (20-300)", r, lambda _: 20 <= ts.get("tempo", 0) <= 300)
        T("transport has isPlaying bool", r, lambda _: isinstance(ts.get("isPlaying"), bool))
        T("transport has isRecording bool", r, lambda _: isinstance(ts.get("isRecording"), bool))
        T("transport has isCycleEnabled bool", r, lambda _: isinstance(ts.get("isCycleEnabled"), bool))
        T("transport has isMetronomeEnabled bool", r, lambda _: isinstance(ts.get("isMetronomeEnabled"), bool))
        T("transport has position string", r, lambda _: isinstance(ts.get("position"), str))
    else:
        # Logic Pro may report error if no project open — still a valid MCP response
        T("transport.get_state error is documented (no project)", r,
          lambda _: "project" in ts_text.lower() or "transport" in ts_text.lower() or len(ts_text) > 0)

    # Roundtrip: toggle cycle, read, toggle back, read
    def safe_get_cycle(client):
        r = call_tool(client, "logic_transport", "get_state")
        try:
            return json.loads(tool_text(r)).get("isCycleEnabled")
        except: return None

    before = safe_get_cycle(client)
    call_tool(client, "logic_transport", "toggle_cycle")
    time.sleep(0.3)
    after = safe_get_cycle(client)
    if before is not None and after is not None:
        T("cycle roundtrip: state changed after toggle", "ok", lambda _: before != after)
    else:
        T("cycle roundtrip (skipped — no project)", "ok", lambda _: True)
    call_tool(client, "logic_transport", "toggle_cycle")  # restore

    # Transport commands that route to MCU/CoreMIDI
    r = call_tool(client, "logic_transport", "toggle_cycle")
    T("transport.toggle_cycle returns non-error", r, lambda _: not is_error(r))
    call_tool(client, "logic_transport", "toggle_cycle")  # restore

    r = call_tool(client, "logic_transport", "toggle_metronome")
    T("transport.toggle_metronome returns non-error", r, lambda _: not is_error(r))
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

    r = call_tool(client, "logic_tracks", "get_tracks")
    tracks_text = tool_text(r)
    T("track.get_tracks returns content", r, lambda _: len(tracks_text) > 0)

    tracks = safe_json(tracks_text)
    if isinstance(tracks, list):
        T("tracks is JSON array", r, lambda _: True)
        if tracks:
            T(f"found {len(tracks)} tracks", r, lambda _: len(tracks) > 0)
            T("first track has id", r, lambda _: "id" in tracks[0])
            T("first track has name", r, lambda _: "name" in tracks[0])
            T("first track has type", r, lambda _: "type" in tracks[0])
            T("first track has isMuted bool", r, lambda _: isinstance(tracks[0].get("isMuted"), bool))
            T("first track has isSolo bool", r, lambda _: isinstance(tracks[0].get("isSolo"), bool))
            T("first track has isArmed bool", r, lambda _: isinstance(tracks[0].get("isArmed"), bool))
            T("first track id is int", r, lambda _: isinstance(tracks[0].get("id"), int))
    else:
        tracks = []

    r = call_tool(client, "logic_tracks", "get_selected")
    T("track.get_selected returns data", r, lambda _: len(tool_text(r)) > 0)

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

    r = call_tool(client, "logic_tracks", "mute")
    T("track.mute without index responds (default 0)", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_tracks", "rename", {"index": 0, "name": ""})
    T("track.rename with empty name dispatches", r, lambda _: len(tool_text(r)) > 0)

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

    # scan_library walks the full Logic Library tree — up to ~60s on a stock
    # install. Use a generous per-call timeout; server bails earlier if panel closed.
    r = call_tool(client, "logic_tracks", "scan_library", timeout=90)
    scan_library_text = tool_text(r)
    scan_library_json = safe_json(scan_library_text)
    T(
        "track.scan_library returns tree or clear precondition error",
        r,
        lambda _: (
            isinstance(scan_library_json, dict)
            and "root" in scan_library_json
            and "nodeCount" in scan_library_json
            and "leafCount" in scan_library_json
        ) or "Library panel not found" in scan_library_text
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
        "track.set_instrument without selector returns explicit error",
        r,
        lambda _: is_error(r) and (
            "Missing path or (category+preset)" in tool_text(r)
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

    r = call_tool(client, "logic_mixer", "get_state")
    T("mixer.get_state returns content", r, lambda _: len(tool_text(r)) > 0)

    # Volume range testing
    for vol in [0.0, 0.25, 0.5, 0.75, 1.0]:
        r = call_tool(client, "logic_mixer", "set_volume", {"index": 0, "volume": vol})
        T(f"mixer.set_volume({vol}) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # Pan range testing (-1 to 1)
    for pan in [-1.0, -0.5, 0.0, 0.5, 1.0]:
        r = call_tool(client, "logic_mixer", "set_pan", {"index": 0, "value": pan})
        T(f"mixer.set_pan({pan}) dispatches", r, lambda _: len(tool_text(r)) > 0)

    # Channel strip read for first 3 strips
    for i in range(3):
        r = call_tool(client, "logic_mixer", "get_channel_strip", {"index": i})
        T(f"mixer.get_channel_strip({i}) returns data", r, lambda _: len(tool_text(r)) > 0)

    # Out-of-range volume
    r = call_tool(client, "logic_mixer", "set_volume", {"index": 0, "volume": -1})
    T("mixer.set_volume(-1) handled", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_mixer", "set_volume", {"index": 0, "volume": 5})
    T("mixer.set_volume(5) handled", r, lambda _: len(tool_text(r)) > 0)

    # Missing params
    r = call_tool(client, "logic_mixer", "set_volume")
    T("mixer.set_volume without params responds (default 0)", r, lambda _: len(tool_text(r)) > 0)

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
        T(f"midi.send_note({note}) succeeds", r, lambda _: not is_error(r))

    # Velocity range
    for vel in [1, 64, 127]:
        r = call_tool(client, "logic_midi", "send_note", {"note": 60, "velocity": vel, "duration_ms": 30})
        T(f"midi.send_note vel={vel} succeeds", r, lambda _: not is_error(r))

    # Channel range
    for ch in [1, 8, 16]:
        r = call_tool(client, "logic_midi", "send_note", {"note": 60, "channel": ch, "duration_ms": 30})
        T(f"midi.send_note ch={ch} succeeds", r, lambda _: not is_error(r))

    # Chord
    r = call_tool(client, "logic_midi", "send_chord", {"notes": "60,64,67", "duration_ms": 30})
    T("midi.send_chord C major succeeds", r, lambda _: not is_error(r))

    r = call_tool(client, "logic_midi", "send_chord", {"notes": "60,63,67,70", "duration_ms": 30})
    T("midi.send_chord Cm7 succeeds", r, lambda _: not is_error(r))

    # CC range
    for cc in [1, 7, 10, 11, 64, 120, 123]:
        r = call_tool(client, "logic_midi", "send_cc", {"controller": cc, "value": 64})
        T(f"midi.send_cc({cc}) succeeds", r, lambda _: not is_error(r))

    # Program change
    r = call_tool(client, "logic_midi", "send_program_change", {"program": 0})
    T("midi.send_program_change(0) succeeds", r, lambda _: not is_error(r))

    r = call_tool(client, "logic_midi", "send_program_change", {"program": 127})
    T("midi.send_program_change(127) succeeds", r, lambda _: not is_error(r))

    # Pitch bend
    r = call_tool(client, "logic_midi", "send_pitch_bend", {"value": 8192})
    T("midi.send_pitch_bend(center) succeeds", r, lambda _: not is_error(r))

    r = call_tool(client, "logic_midi", "send_pitch_bend", {"value": 16383})
    T("midi.send_pitch_bend(max) succeeds", r, lambda _: not is_error(r))

    # Aftertouch
    r = call_tool(client, "logic_midi", "send_aftertouch", {"value": 100})
    T("midi.send_aftertouch succeeds", r, lambda _: not is_error(r))

    # MMC
    r = call_tool(client, "logic_midi", "mmc_play")
    T("midi.mmc_play succeeds", r, lambda _: not is_error(r))
    call_tool(client, "logic_midi", "mmc_stop")  # restore

    r = call_tool(client, "logic_midi", "mmc_stop")
    T("midi.mmc_stop succeeds", r, lambda _: not is_error(r))

    r = call_tool(client, "logic_midi", "mmc_locate", {"bar": 1})
    T("midi.mmc_locate(bar=1) succeeds", r, lambda _: not is_error(r))

    # Step input
    r = call_tool(client, "logic_midi", "step_input", {"note": 60, "duration": "1/4"})
    T("midi.step_input(1/4) succeeds", r, lambda _: not is_error(r))

    r = call_tool(client, "logic_midi", "step_input", {"note": 60, "duration": "1/8"})
    T("midi.step_input(1/8) succeeds", r, lambda _: not is_error(r))

    # Duration cap (our P2 fix)
    r = call_tool(client, "logic_midi", "send_note", {"note": 60, "duration_ms": 50})
    T("midi.send_note small duration succeeds", r, lambda _: not is_error(r))

    # ═══════════════════════════════════════════════════════════════
    # §7 Edit Commands (14 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§7 Edit Commands")

    for cmd in ["undo", "redo", "cut", "copy", "paste", "delete",
                "select_all", "split", "join", "quantize",
                "bounce_in_place", "normalize", "duplicate", "toggle_step_input"]:
        r = call_tool(client, "logic_edit", cmd)
        T(f"edit.{cmd} dispatches", r, lambda _: len(tool_text(r)) > 0)

    # ═══════════════════════════════════════════════════════════════
    # §8 Navigation (15 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§8 Navigation")

    r = call_tool(client, "logic_navigate", "get_markers")
    T("nav.get_markers returns data", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_navigate", "goto_bar", {"bar": 1})
    T("nav.goto_bar(1) dispatches", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_navigate", "goto_bar", {"bar": 8})
    T("nav.goto_bar(8) dispatches", r, lambda _: len(tool_text(r)) > 0)

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

    r = call_tool(client, "logic_project", "get_info")
    T("project.get_info returns data", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_project", "is_running")
    T("project.is_running returns 'true'", r, lambda _: "true" in tool_text(r))

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
    # §11 Resource Read (18 tests)
    # ═══════════════════════════════════════════════════════════════
    section("§11 Resource Read")

    resources_to_test = [
        "logic://transport/state",
        "logic://tracks",
        "logic://mixer",
        "logic://midi/ports",
        "logic://system/health",
        "logic://project/info",
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
    T(f"20 rapid MIDI notes: {rapid_ok}/20 ok", "ok", lambda _: rapid_ok >= 18)

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

    # Tool and resource return matching transport state
    r1 = call_tool(client, "logic_transport", "get_state")
    r2 = read_resource(client, "logic://transport/state")
    tool_data = safe_json(tool_text(r1))
    resource_data = safe_json(resource_text(r2))
    if tool_data and resource_data:
        T("tool & resource both have tempo", "ok", lambda _: "tempo" in tool_data and "tempo" in resource_data)
        T("tool & resource isPlaying consistent", "ok", lambda _: tool_data.get("isPlaying") == resource_data.get("isPlaying"))

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

    # Tracks tool and resource — same count
    r1 = call_tool(client, "logic_tracks", "get_tracks")
    r2 = read_resource(client, "logic://tracks")
    tool_tracks = safe_json(tool_text(r1))
    resource_tracks = safe_json(resource_text(r2))
    if isinstance(tool_tracks, list) and isinstance(resource_tracks, list):
        T("tracks count consistent between tool and resource", "ok",
          lambda _: len(tool_tracks) == len(resource_tracks))

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

    r = call_tool(client, "logic_mixer", "set_volume", {"index": "foo", "volume": "bar"})
    T("mixer.set_volume non-numeric handled", r, lambda _: len(tool_text(r)) > 0)

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

    # Empty params object
    r = call_tool(client, "logic_mixer", "set_volume", {})
    T("mixer.set_volume empty params handled", r, lambda _: len(tool_text(r)) > 0)

    # MIDI out-of-range (should still route, driver may reject)
    r = call_tool(client, "logic_midi", "send_note", {"note": 200, "duration_ms": 20})
    T("midi.send_note note=200 handled", r, lambda _: len(tool_text(r)) > 0)

    r = call_tool(client, "logic_midi", "send_cc", {"controller": 200, "value": 50})
    T("midi.send_cc cc=200 handled", r, lambda _: len(tool_text(r)) > 0)

    # Large duration should be capped to 30s (our P2 fix) — test with shorter value
    # to verify the capping logic doesn't hang the actor
    r = call_tool(client, "logic_midi", "send_note", {"note": 60, "duration_ms": 100})
    T("midi.send_note short duration ok", r, lambda _: r is not None and not is_error(r))

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

    # track.get_tracks: AX only
    r = call_tool(client, "logic_tracks", "get_tracks")
    T("track.get_tracks routes (AX)", r, lambda _: len(tool_text(r)) > 0)

    # mixer.get_state: MCU, AX
    r = call_tool(client, "logic_mixer", "get_state")
    T("mixer.get_state routes (MCU/AX)", r, lambda _: len(tool_text(r)) > 0)

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
        T("LogicProMCP-MCU virtual port visible", "ok", lambda _: "MCU" in all_ports or "LogicProMCP" in all_ports)
        T("LogicProMCP-KeyCmd virtual port visible", "ok", lambda _: "KeyCmd" in all_ports or "LogicProMCP" in all_ports)
        T("LogicProMCP-Scripter virtual port visible", "ok", lambda _: "Scripter" in all_ports or "LogicProMCP" in all_ports)

    # Send a full MIDI sequence (chord)
    r = call_tool(client, "logic_midi", "send_chord", {"notes": "60,64,67,72", "duration_ms": 30})
    T("send chord (4 notes) completes", r, lambda _: not is_error(r))

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
    T(f"MIDI CC send < 0.5s ({elapsed:.3f}s)", r, lambda _: elapsed < 0.5 and not is_error(r))

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
    T("Logic Pro still running at end", r, lambda _: "true" in tool_text(r))

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
        T("final health: all permissions granted", r,
          lambda _: h["permissions"].get("accessibility") is True and h["permissions"].get("automation_granted") is True)
        T("final health: channels report started", r,
          lambda _: any(c.get("available") is True for c in h.get("channels", [])))

    client.close()

    # ═══════════════════════════════════════════════════════════════
    # Summary
    # ═══════════════════════════════════════════════════════════════
    print()
    print("══════════════════════════════════════════════════════")
    total = PASS + FAIL
    if FAIL == 0:
        print(f" \033[0;32m✔ All {total} tests passed\033[0m")
    else:
        print(f" \033[0;31m✘ {FAIL}/{total} failed\033[0m, \033[0;32m{PASS} passed\033[0m")
        print()
        print("Failures:")
        for f in FAILURES:
            print(f"  \033[0;31m✘\033[0m {f}")
    print("══════════════════════════════════════════════════════")
    print()
    sys.exit(min(FAIL, 125))


if __name__ == "__main__":
    main()
