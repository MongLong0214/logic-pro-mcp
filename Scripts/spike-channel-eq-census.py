#!/usr/bin/env python3
# SIZE_OK: Live census harness centralizes MCP setup, read-only AX crawl, and cleanup for one ordered run.
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///

# --- How to run ---
# 1. Build the release server binary first, or set LOGIC_PRO_MCP_BINARY.
# 2. Run: python3 Scripts/spike-channel-eq-census.py
# 3. The script prints newline-delimited JSON progress and parameter records.
# ------------------

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Dict, List, Optional


BINARY = os.environ.get("LOGIC_PRO_MCP_BINARY", ".build/release/LogicProMCP")
TIMEOUT = float(os.environ.get("LOGIC_PRO_MCP_CHANNEL_EQ_CENSUS_TIMEOUT", "30"))
RESOURCE_READY_TIMEOUT_SECONDS = 12.0
RESOURCE_READY_INTERVAL_SECONDS = 1.0
CHANNEL_EQ_PLUGIN = "Channel EQ"

ESCAPE_SCRIPT = 'tell application "System Events" to key code 53'

CURRENT_DOCUMENT_PATH_SCRIPT = r'''
tell application "Logic Pro"
    try
        return POSIX path of (path of front document as alias)
    on error
        try
            return path of front document as text
        on error
            return ""
        end try
    end try
end tell
'''

OPEN_CHANNEL_EQ_EDITOR_SCRIPT = r'''
on cleanText(value)
    try
        if value is missing value then return ""
        return value as text
    on error
        return ""
    end try
end cleanText

on attrText(item, attrName)
    try
        return my cleanText(value of attribute attrName of item)
    on error
        return ""
    end try
end attrText

on pressChannelEQOpenButton(item, depth)
    if depth > 12 then return false
    set itemRole to my attrText(item, "AXRole")
    set itemDescription to my attrText(item, "AXDescription")
    if itemRole is "AXGroup" and itemDescription contains "Channel EQ" then
        try
            repeat with childElement in UI elements of item
                set childRole to my attrText(childElement, "AXRole")
                if childRole is "AXButton" then
                    click childElement
                    return true
                end if
            end repeat
        end try
    end if
    try
        repeat with childElement in UI elements of item
            if my pressChannelEQOpenButton(childElement, depth + 1) then return true
        end repeat
    end try
    return false
end pressChannelEQOpenButton

tell application "Logic Pro" to activate
delay 0.2
tell application "System Events"
    key code 53
    delay 0.1
    tell process "Logic Pro"
        set frontmost to true
        repeat with targetWindow in windows
            if my pressChannelEQOpenButton(targetWindow, 0) then
                delay 0.5
                key code 53
                return "OPEN" & tab & "clicked"
            end if
        end repeat
    end tell
    key code 53
end tell
return "OPEN" & tab & "missing"
'''

CHANNEL_EQ_PARAM_CENSUS_SCRIPT = r'''
set outputLines to {}

on cleanText(value)
    try
        if value is missing value then return ""
        return value as text
    on error
        return ""
    end try
end cleanText

on attrText(item, attrName)
    try
        return my cleanText(value of attribute attrName of item)
    on error
        return ""
    end try
end attrText

on appendInspectable(item, depth, windowTitle)
    global outputLines
    if depth > 12 then return
    set itemRole to my attrText(item, "AXRole")
    if itemRole is "AXSlider" or itemRole is "AXCheckBox" or itemRole is "AXPopUpButton" then
        set fields to {"PARAM", windowTitle, itemRole, my attrText(item, "AXDescription"), my attrText(item, "AXTitle"), my attrText(item, "AXValue"), my attrText(item, "AXValueDescription"), my attrText(item, "AXMinValue"), my attrText(item, "AXMaxValue")}
        set AppleScript's text item delimiters to tab
        copy (fields as text) to end of outputLines
    end if
    try
        repeat with childElement in UI elements of item
            my appendInspectable(childElement, depth + 1, windowTitle)
        end repeat
    end try
end appendInspectable

tell application "Logic Pro" to activate
delay 0.2
tell application "System Events"
    key code 53
    delay 0.1
    tell process "Logic Pro"
        set frontmost to true
        set inspectedDialog to false
        repeat with targetWindow in windows
            set windowSubrole to my attrText(targetWindow, "AXSubrole")
            if windowSubrole contains "Dialog" then
                set inspectedDialog to true
                my appendInspectable(targetWindow, 0, my attrText(targetWindow, "AXTitle"))
            end if
        end repeat
        if inspectedDialog is false and exists window 1 then
            my appendInspectable(window 1, 0, my attrText(window 1, "AXTitle"))
        end if
    end tell
    key code 53
end tell
set AppleScript's text item delimiters to linefeed
return outputLines as text
'''


@dataclass(frozen=True)
class OsascriptResult:
    returncode: int
    stdout_lines: List[str]
    stderr: str
    timed_out: bool


class MCPClient:
    def __init__(self) -> None:
        stderr_dir = tempfile.TemporaryDirectory(prefix="logic-mcp-channel-eq-census.")
        self._stderr_dir = stderr_dir
        self._stderr_file = open(Path(stderr_dir.name) / "stderr.txt", "w")
        self.proc = subprocess.Popen(
            [BINARY],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr_file,
            bufsize=0,
            env=os.environ.copy(),
        )
        self.responses: Dict[int, Dict[str, Any]] = {}
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self) -> None:
        if self.proc.stdout is None:
            return
        for raw_line in self.proc.stdout:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            message_id = message.get("id")
            if isinstance(message_id, int) and ("result" in message or "error" in message):
                self.responses[message_id] = message

    def send(self, message: Dict[str, Any], timeout: Optional[float] = None) -> Optional[Dict[str, Any]]:
        if self.proc.stdin is None:
            return None
        try:
            self.proc.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            self.proc.stdin.flush()
        except BrokenPipeError:
            return None
        message_id = message.get("id")
        if not isinstance(message_id, int):
            return None
        deadline = time.time() + (timeout if timeout is not None else TIMEOUT)
        while time.time() < deadline:
            if message_id in self.responses:
                return self.responses.pop(message_id)
            time.sleep(0.02)
        return None

    def notify(self, message: Dict[str, Any]) -> None:
        if self.proc.stdin is None:
            return
        try:
            self.proc.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            self.proc.stdin.flush()
        except BrokenPipeError:
            return

    def close(self) -> None:
        if self.proc.stdin is not None:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self._stderr_file.close()
        self._stderr_dir.cleanup()


_NEXT_ID = 1


def next_id() -> int:
    global _NEXT_ID
    request_id = _NEXT_ID
    _NEXT_ID += 1
    return request_id


def emit(record_type: str, status: str, **fields: Any) -> None:
    payload: Dict[str, Any] = {
        "record_type": record_type,
        "ok": status not in {"blocked", "failed", "missing", "timeout"},
        "status": status,
    }
    payload.update(fields)
    print(json.dumps(payload, sort_keys=True), flush=True)


def run_osascript(step: str, script: str, timeout: float = 8.0) -> OsascriptResult:
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            check=False,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout.decode("utf-8", errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
        stderr = error.stderr.decode("utf-8", errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
        lines = [line for line in stdout.splitlines() if line]
        emit("osascript", "timeout", step=step, stdout=lines, stderr=stderr, timeout_seconds=timeout)
        return OsascriptResult(124, lines, stderr, True)
    lines = [line for line in result.stdout.splitlines() if line]
    emit("osascript", "ok" if result.returncode == 0 else "failed", step=step, stdout=lines, stderr=result.stderr)
    return OsascriptResult(result.returncode, lines, result.stderr, False)


def send_escape(label: str) -> None:
    run_osascript(label, ESCAPE_SCRIPT, timeout=4.0)


def initialize(client: MCPClient) -> bool:
    response = client.send({
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "channel-eq-census-spike", "version": "1"},
        },
    })
    ok = isinstance(response, dict) and "result" in response
    emit("initialize", "ok" if ok else "failed", response=response)
    if ok:
        client.notify({"jsonrpc": "2.0", "method": "notifications/initialized"})
        time.sleep(1.0)
    return ok


def call_tool(
    client: MCPClient,
    tool: str,
    command: str,
    params: Optional[Dict[str, Any]] = None,
    timeout: Optional[float] = None,
) -> Optional[Dict[str, Any]]:
    arguments: Dict[str, Any] = {"command": command}
    if params is not None:
        arguments["params"] = params
    return client.send({
        "jsonrpc": "2.0",
        "id": next_id(),
        "method": "tools/call",
        "params": {"name": tool, "arguments": arguments},
    }, timeout=timeout)


def read_resource(client: MCPClient, uri: str, timeout: Optional[float] = None) -> Optional[Dict[str, Any]]:
    return client.send({
        "jsonrpc": "2.0",
        "id": next_id(),
        "method": "resources/read",
        "params": {"uri": uri},
    }, timeout=timeout)


def parsed_json_text(text: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def response_text(response: Optional[Dict[str, Any]], key: str) -> str:
    try:
        entries = response["result"][key]
    except (KeyError, TypeError):
        return ""
    if not isinstance(entries, list):
        return ""
    for entry in entries:
        if isinstance(entry, dict) and entry.get("type") == "text":
            return str(entry.get("text", ""))
    return ""


def tool_json(response: Optional[Dict[str, Any]]) -> Any:
    return parsed_json_text(response_text(response, "content"))


def resource_envelope(response: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not isinstance(response, dict) or "error" in response:
        return None
    result = response.get("result")
    if not isinstance(result, dict):
        return None
    contents = result.get("contents")
    if not isinstance(contents, list) or not contents:
        return None
    first = contents[0]
    if not isinstance(first, dict):
        return None
    text = first.get("text")
    if not isinstance(text, str):
        return None
    parsed = parsed_json_text(text)
    if not isinstance(parsed, dict):
        return None
    data = parsed.get("data")
    if isinstance(data, (list, dict)):
        return parsed
    return None


def resource_json(response: Optional[Dict[str, Any]]) -> Any:
    envelope = resource_envelope(response)
    return envelope["data"] if envelope is not None else None


def wait_for_resource_ready(client: MCPClient, uri: str = "logic://tracks") -> bool:
    deadline = time.time() + RESOURCE_READY_TIMEOUT_SECONDS
    last_response: Optional[Dict[str, Any]] = None
    while time.time() < deadline:
        last_response = read_resource(client, uri, timeout=RESOURCE_READY_INTERVAL_SECONDS)
        if resource_envelope(last_response) is not None:
            emit("resource_ready", "ok", uri=uri)
            return True
        time.sleep(RESOURCE_READY_INTERVAL_SECONDS)
    emit("resource_ready", "timeout", uri=uri, response=last_response)
    return False


def tracks_snapshot(client: MCPClient) -> Optional[List[Dict[str, Any]]]:
    tracks = resource_json(read_resource(client, "logic://tracks"))
    return tracks if isinstance(tracks, list) else None


def current_document_path(client: MCPClient) -> Optional[str]:
    project_info = resource_json(read_resource(client, "logic://project/info"))
    if isinstance(project_info, dict):
        raw = project_info.get("file_path") or project_info.get("filePath")
        if isinstance(raw, str) and raw.strip():
            return raw
    result = run_osascript("front_document_path", CURRENT_DOCUMENT_PATH_SCRIPT, timeout=5.0)
    if result.returncode == 0 and result.stdout_lines:
        path = result.stdout_lines[0].strip()
        return path if path else None
    return None


def created_track_index(before: List[Dict[str, Any]], after: List[Dict[str, Any]], create_payload: Any) -> Optional[int]:
    if isinstance(create_payload, dict):
        raw = create_payload.get("observed_track_index")
        if isinstance(raw, int):
            return raw
    before_ids = {track.get("id") for track in before if isinstance(track.get("id"), int)}
    for track in after:
        raw_id = track.get("id")
        if isinstance(raw_id, int) and raw_id not in before_ids:
            return raw_id
    return len(after) - 1 if len(after) == len(before) + 1 else None


def first_empty_insert(client: MCPClient, track_index: int) -> Optional[int]:
    response = call_tool(client, "logic_plugins", "get_inventory", {"track": track_index}, timeout=20)
    payload = tool_json(response)
    emit("plugin_inventory", "ok" if isinstance(payload, dict) else "failed", track=track_index, response=payload or response)
    if not isinstance(payload, dict) or payload.get("state") != "A":
        return None
    plugins = payload.get("plugins")
    if not isinstance(plugins, list):
        return None
    for item in plugins:
        if not isinstance(item, dict):
            continue
        if item.get("read_status") == "empty" and item.get("occupied") is False and isinstance(item.get("insert"), int):
            return item["insert"]
    return None


def create_audio_track(client: MCPClient) -> Optional[int]:
    send_escape("pre_create_audio_escape")
    before = tracks_snapshot(client)
    if before is None:
        emit("create_audio_track", "blocked", reason="logic://tracks unavailable before create")
        return None
    response = call_tool(client, "logic_tracks", "create_audio", {}, timeout=30)
    payload = tool_json(response)
    send_escape("post_create_audio_escape")
    after = tracks_snapshot(client)
    if after is None:
        emit("create_audio_track", "failed", reason="logic://tracks unavailable after create", response=payload or response)
        return None
    index = created_track_index(before, after, payload)
    emit("create_audio_track", "ok" if index is not None else "failed", index=index, response=payload or response)
    return index


def live_track_name(client: MCPClient, track_index: int) -> Optional[str]:
    """PRD-007: the live name at a track index, for corroborating the seed-set
    ops (insert_verified / delete) that no longer accept a bare index."""
    tracks = tracks_snapshot(client)
    if not isinstance(tracks, list):
        return None
    for track in tracks:
        if isinstance(track, dict) and track.get("id") == track_index:
            name = track.get("name")
            if isinstance(name, str) and name.strip():
                return name
    return None


def insert_channel_eq(client: MCPClient, track_index: int, insert_index: int, project_path: str) -> bool:
    send_escape("pre_insert_escape")
    params = {
        "track": track_index,
        "insert": insert_index,
        "plugin": CHANNEL_EQ_PLUGIN,
        "mode": "duplicate_applyback",
        "project_expected_path": project_path,
    }
    # PRD-007 index binding: insert_verified is `.corroborated`, so a bare track
    # index is refused. Corroborate against the live header name of the track we
    # created earlier in this spike.
    expected_name = live_track_name(client, track_index)
    if expected_name is not None:
        params["expected_name"] = expected_name
    response = call_tool(client, "logic_plugins", "insert_verified", params, timeout=60)
    payload = tool_json(response)
    send_escape("post_insert_escape")
    ok = isinstance(payload, dict) and payload.get("state") == "A"
    emit("insert_channel_eq", "ok" if ok else "failed", params=params, response=payload or response)
    return ok


def cleanup_created_track(client: MCPClient, track_index: Optional[int]) -> None:
    send_escape("cleanup_pre_escape")
    if track_index is None:
        emit("cleanup_track_delete", "missing", reason="no created track index")
        send_escape("cleanup_post_escape")
        return
    # PRD-007 index binding: tracks.delete is `.corroborated` — corroborate the
    # index against the live header name before the irreversible delete.
    delete_params: Dict[str, Any] = {"index": track_index}
    expected_name = live_track_name(client, track_index)
    if expected_name is not None:
        delete_params["expected_name"] = expected_name
    response = call_tool(client, "logic_tracks", "delete", delete_params, timeout=30)
    payload = tool_json(response)
    emit("cleanup_track_delete", "ok" if isinstance(payload, dict) and payload.get("state") == "A" else "failed", index=track_index, response=payload or response)
    send_escape("cleanup_post_escape")


def parse_number(raw: str) -> Optional[float]:
    try:
        return float(raw)
    except ValueError:
        return None


def unit_from_value_description(value_description: str) -> Optional[str]:
    stripped = value_description.strip()
    if not stripped:
        return None
    match = re.search(r"[-+]?\d+(?:\.\d+)?\s*([^0-9\s].*)$", stripped)
    if match is None:
        return None
    unit = match.group(1).strip()
    return unit or None


def canonical_id_for(index: int, role: str, description: str, title: str) -> str:
    seed = description.strip() or title.strip() or role.strip() or "parameter"
    slug = re.sub(r"[^a-z0-9]+", "_", seed.lower()).strip("_")
    if not slug:
        slug = "parameter"
    return "census_%03d_%s" % (index, slug)


def emit_parameter_records(lines: List[str]) -> int:
    count = 0
    for line in lines:
        parts = line.split("\t")
        if len(parts) < 9 or parts[0] != "PARAM":
            continue
        count += 1
        window_title, role, description, title, raw_value, value_description, raw_min, raw_max = parts[1:9]
        unit = unit_from_value_description(value_description)
        print(json.dumps({
            "record_type": "channel_eq_parameter",
            "canonical_id": canonical_id_for(count, role, description, title),
            "canonical_id_source": "census_candidate_from_ax_description",
            "ax_role": role or None,
            "ax_description": description or None,
            "ax_title": title or None,
            "editor_window_title": window_title or None,
            "current_value": parse_number(raw_value),
            "current_value_raw": raw_value or None,
            "current_unit": unit,
            "ax_value_description": value_description or None,
            "ax_min": parse_number(raw_min),
            "ax_max": parse_number(raw_max),
        }, sort_keys=True), flush=True)
    emit("parameter_census", "ok" if count else "missing", count=count)
    return count


def run_census() -> int:
    client = MCPClient()
    created_index: Optional[int] = None
    try:
        if not initialize(client):
            return 2
        if not wait_for_resource_ready(client):
            return 2
        project_path = current_document_path(client)
        if project_path is None:
            emit("project_path", "blocked", reason="front document path unavailable")
            return 2
        emit("project_path", "ok", project_expected_path=project_path)
        created_index = create_audio_track(client)
        if created_index is None:
            return 2
        insert_index = first_empty_insert(client, created_index)
        if insert_index is None:
            emit("empty_insert", "blocked", track=created_index)
            return 2
        if not insert_channel_eq(client, created_index, insert_index, project_path):
            return 2
        open_result = run_osascript("open_channel_eq_editor", OPEN_CHANNEL_EQ_EDITOR_SCRIPT, timeout=10.0)
        opened = any(line == "OPEN\tclicked" for line in open_result.stdout_lines)
        emit("open_channel_eq_editor", "ok" if opened else "failed", stdout=open_result.stdout_lines)
        if not opened:
            return 2
        census_result = run_osascript("channel_eq_param_census", CHANNEL_EQ_PARAM_CENSUS_SCRIPT, timeout=10.0)
        if census_result.returncode != 0:
            emit("parameter_census", "failed", stderr=census_result.stderr)
            return 2
        return 0 if emit_parameter_records(census_result.stdout_lines) > 0 else 2
    finally:
        cleanup_created_track(client, created_index)
        client.close()


def main() -> int:
    return run_census()


if __name__ == "__main__":
    sys.exit(main())
