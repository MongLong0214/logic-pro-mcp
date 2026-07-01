#!/usr/bin/env python3
# SIZE_OK: Shared live/demo bootstrap keeps localized Logic AX/JXA probes in one audited helper.
"""Reusable fresh-session bootstrap helper for Logic Pro live/demo runs.

This helper prefers MCP-visible truth for project/document state, but falls
back to a direct Logic document probe when cached close state lags. It uses a
native AX/NSWorkspace probe for UI readiness signals such as frontmost app,
window titles, and menu language. It never relies on coordinate clicks.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

LOGIC_APP_NAME = "Logic Pro"
PROJECT_PICKER_MARKERS = (
    "choose a project",
    "choose project",
    "new from template",
    "프로젝트 선택",
)
PROJECT_PICKER_CHOOSE_BUTTONS = (
    "Choose",
    "선택",
)
NEW_TRACK_DIALOG_MARKERS = (
    "new tracks",
    "create tracks",
    "create new track",
    "새로운 트랙 생성",
    "트랙 생성",
)
SAVE_DIALOG_MARKERS = (
    "save",
    "save as",
    "저장",
    "다른 이름으로 저장",
    "이름으로 저장",
)
SAVE_DIALOG_CANCEL_BUTTONS = (
    "Cancel",
    "취소",
)
SAFE_DISMISS_DIALOG_MARKERS = (
    "import",
    "open",
    "bounce",
    "export",
    "save",
    "choose file",
    "choose a file",
    "select file",
    "가져오기",
    "열기",
    "바운스",
    "내보내기",
    "저장",
)
PROJECT_WINDOW_MARKERS = (
    " - tracks",
    " — tracks",
    " - 트랙",
    " — 트랙",
)
LANGUAGE_MENU_MARKERS = {
    "en": frozenset({"File", "Edit", "Track"}),
    "ko": frozenset({"파일", "편집", "트랙"}),
}


def _safe_json(text: str) -> Any:
    try:
        return json.loads(text)
    except Exception:
        return None


def _bool_env(env: Mapping[str, str], name: str, default: bool) -> bool:
    raw = env.get(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off", ""}


def _int_env(env: Mapping[str, str], name: str, default: int) -> int:
    raw = env.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _float_env(env: Mapping[str, str], name: str, default: float) -> float:
    raw = env.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _string_list_env(env: Mapping[str, str], name: str) -> tuple[str, ...]:
    raw = env.get(name, "")
    values = [item.strip() for item in raw.split(",")]
    return tuple(item for item in values if item)


@dataclass(frozen=True)
class BootstrapConfig:
    expected_language: str | None
    hide_apps: tuple[str, ...]
    max_tracks: int
    allow_launch: bool
    allow_new_project: bool
    force_new_project: bool
    confirm_new_track_dialog: bool
    timeout_sec: float
    poll_interval_sec: float

    @classmethod
    def from_env(cls, strict_live: bool, env: Mapping[str, str] | None = None) -> "BootstrapConfig":
        env = env or os.environ
        expected_language = env.get("LOGIC_PRO_MCP_BOOTSTRAP_LANGUAGE", "en").strip().lower()
        if expected_language in {"", "any", "auto"}:
            expected_language = None
        return cls(
            expected_language=expected_language,
            hide_apps=_string_list_env(env, "LOGIC_PRO_MCP_BOOTSTRAP_HIDE_APPS"),
            max_tracks=max(0, _int_env(env, "LOGIC_PRO_MCP_BOOTSTRAP_MAX_TRACKS", 1)),
            allow_launch=_bool_env(env, "LOGIC_PRO_MCP_BOOTSTRAP_ALLOW_LAUNCH", True),
            allow_new_project=_bool_env(env, "LOGIC_PRO_MCP_BOOTSTRAP_ALLOW_NEW_PROJECT", strict_live),
            force_new_project=_bool_env(env, "LOGIC_PRO_MCP_BOOTSTRAP_FORCE_NEW", False),
            confirm_new_track_dialog=_bool_env(
                env, "LOGIC_PRO_MCP_BOOTSTRAP_CONFIRM_NEW_TRACK_DIALOG", True
            ),
            timeout_sec=max(1.0, _float_env(env, "LOGIC_PRO_MCP_BOOTSTRAP_TIMEOUT_SEC", 8.0)),
            poll_interval_sec=max(0.1, _float_env(env, "LOGIC_PRO_MCP_BOOTSTRAP_POLL_SEC", 0.35)),
        )


@dataclass(frozen=True)
class UISnapshot:
    frontmost_app: str | None
    logic_window_names: list[str]
    logic_menu_items: list[str]
    detected_language: str | None
    system_events_error: str | None
    project_picker_visible: bool
    new_track_dialog_visible: bool
    blocking_dialog_present: bool = False


@dataclass(frozen=True)
class FreshSessionAssessment:
    ok: bool
    reason: str | None = None
    hint: str | None = None
    inferred_track_count: int = 0
    placeholder_count: int = 0
    region_count: int = 0


@dataclass
class BootstrapResult:
    ok: bool
    reason: str | None = None
    hint: str | None = None
    actions: list[str] = field(default_factory=list)
    ui: dict[str, Any] = field(default_factory=dict)
    health: dict[str, Any] = field(default_factory=dict)
    project: dict[str, Any] = field(default_factory=dict)
    tracks: dict[str, Any] = field(default_factory=dict)
    regions: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "reason": self.reason,
            "hint": self.hint,
            "actions": list(self.actions),
            "ui": self.ui,
            "health": self.health,
            "project": self.project,
            "tracks": self.tracks,
            "regions": self.regions,
        }


def detect_language(menu_items: Sequence[str]) -> str | None:
    menu_set = {item.strip() for item in menu_items if item and item.strip()}
    for language, required_items in LANGUAGE_MENU_MARKERS.items():
        if required_items.issubset(menu_set):
            return language
    return None


def _contains_marker(window_names: Sequence[str], markers: Sequence[str]) -> bool:
    haystack = [name.lower() for name in window_names]
    for marker in markers:
        marker_lc = marker.lower()
        if any(marker_lc in name for name in haystack):
            return True
    return False


def _arrange_window_visible(window_names: Sequence[str]) -> bool:
    return _contains_marker(window_names, PROJECT_WINDOW_MARKERS)


def _project_info_data(project_payload: Any) -> dict[str, Any]:
    if isinstance(project_payload, dict):
        data = project_payload.get("data")
        if isinstance(data, dict):
            return data
    return {}


def _track_rows(tracks_payload: Any) -> list[dict[str, Any]]:
    if isinstance(tracks_payload, dict):
        data = tracks_payload.get("data")
        if isinstance(data, list):
            return [row for row in data if isinstance(row, dict)]
    return []


def _health_cache_summary(health: dict[str, Any]) -> dict[str, Any]:
    cache = health.get("cache", {}) if isinstance(health, dict) else {}
    return cache if isinstance(cache, dict) else {}


def _fallback_project_payload(health: dict[str, Any]) -> dict[str, Any] | None:
    cache = _health_cache_summary(health)
    project_name = cache.get("project")
    track_count = cache.get("track_count")
    if not isinstance(project_name, str) and not isinstance(track_count, int):
        return None
    return {
        "source": "health_cache",
        "data": {
            "name": project_name if isinstance(project_name, str) else "",
            "trackCount": track_count if isinstance(track_count, int) else 0,
            "source": "health_cache",
        },
    }


def _nonblocking_project_picker_has_live_track(
    ui: UISnapshot,
    *,
    health: dict[str, Any] | None = None,
    inferred_track_count: int | None = None,
) -> bool:
    if not ui.project_picker_visible or ui.blocking_dialog_present or ui.new_track_dialog_visible:
        return False
    if not _arrange_window_visible(ui.logic_window_names):
        return False
    if inferred_track_count is not None:
        return inferred_track_count > 0
    if not isinstance(health, dict):
        return False
    if health.get("logic_pro_has_document") is not True or health.get("logic_pro_has_window") is not True:
        return False
    cached_track_count = _health_cache_summary(health).get("track_count")
    return isinstance(cached_track_count, int) and cached_track_count > 0


def _fresh_project_ui_ready(ui: UISnapshot, health: dict[str, Any]) -> bool:
    if health.get("logic_pro_has_document") is not True or health.get("logic_pro_has_window") is not True:
        return False
    if ui.project_picker_visible:
        return _nonblocking_project_picker_has_live_track(ui, health=health)
    if ui.new_track_dialog_visible or ui.blocking_dialog_present:
        return False
    if _arrange_window_visible(ui.logic_window_names):
        return True
    cached_project = _health_cache_summary(health).get("project")
    return isinstance(cached_project, str) and _arrange_window_visible([cached_project])


def _fresh_project_blank_shell(ui: UISnapshot, health: dict[str, Any]) -> bool:
    if health.get("logic_pro_has_document") is not True or health.get("logic_pro_has_window") is not True:
        return False
    if ui.project_picker_visible or ui.new_track_dialog_visible or ui.blocking_dialog_present:
        return False
    return not _fresh_project_ui_ready(ui, health)


def _first_track_create_retry_needed(ui: UISnapshot, health: dict[str, Any]) -> bool:
    if _fresh_project_ui_ready(ui, health):
        return False
    cached_track_count = _health_cache_summary(health).get("track_count")
    if isinstance(cached_track_count, int) and cached_track_count > 0:
        return False
    return (
        ui.project_picker_visible
        or ui.new_track_dialog_visible
        or ui.blocking_dialog_present
        or _fresh_project_blank_shell(ui, health)
    )


def evaluate_fresh_session(
    ui: UISnapshot,
    health: dict[str, Any],
    project_payload: Any,
    tracks_payload: Any,
    region_count: int,
    config: BootstrapConfig,
) -> FreshSessionAssessment:
    permissions = health.get("permissions", {}) if isinstance(health, dict) else {}

    if health.get("logic_pro_running") is not True:
        return FreshSessionAssessment(False, "logic_not_running", "Launch Logic Pro before continuing.")
    if permissions.get("accessibility") is not True:
        return FreshSessionAssessment(
            False,
            "missing_accessibility",
            "Grant Accessibility access to this session before running live automation.",
        )
    if health.get("logic_pro_has_window") is not True:
        return FreshSessionAssessment(
            False,
            "logic_window_not_visible",
            "Bring a Logic Pro document window on-screen before continuing.",
        )
    if ui.system_events_error:
        return FreshSessionAssessment(
            False,
            "system_events_unavailable",
            f"System Events UI probe failed; grant Automation access to this harness runner. {ui.system_events_error}",
        )
    if ui.blocking_dialog_present:
        return FreshSessionAssessment(
            False,
            "blocking_dialog_present",
            "Dismiss the blocking Logic dialog or sheet before continuing.",
        )
    if ui.frontmost_app != LOGIC_APP_NAME:
        return FreshSessionAssessment(
            False,
            "logic_not_frontmost",
            "Logic Pro must be the frontmost app so modal/readback state is trustworthy.",
        )
    if config.expected_language:
        if ui.detected_language is None:
            return FreshSessionAssessment(
                False,
                "language_unrecognized",
                "Could not infer the Logic Pro UI language from the menu bar.",
            )
        if ui.detected_language != config.expected_language:
            return FreshSessionAssessment(
                False,
                "language_mismatch",
                f"Expected a {config.expected_language} Logic UI but detected {ui.detected_language}.",
            )
    if ui.new_track_dialog_visible:
        return FreshSessionAssessment(
            False,
            "new_track_dialog_visible",
            "Logic's new-track dialog is still open; the empty project is not ready yet.",
        )
    if health.get("logic_pro_has_document") is not True:
        return FreshSessionAssessment(
            False,
            "no_document_open",
            "No Logic project document is currently open.",
        )

    project_data = _project_info_data(project_payload)
    project_source = None
    if isinstance(project_payload, dict):
        project_source = project_payload.get("source")
    if not project_source:
        project_source = project_data.get("source")
    if not project_data or project_source == "default":
        return FreshSessionAssessment(
            False,
            "project_info_unavailable",
            "Project metadata never advanced beyond the default envelope.",
        )

    track_rows = _track_rows(tracks_payload)
    placeholder_count = sum(1 for row in track_rows if row.get("placeholder") is True)
    if isinstance(tracks_payload, dict) and tracks_payload.get("ax_occluded") is True:
        return FreshSessionAssessment(
            False,
            "ax_occluded",
            "The Logic AX tree is occluded by a modal or floating window.",
        )
    if placeholder_count > 0:
        return FreshSessionAssessment(
            False,
            "tracks_not_live",
            "Track readback is still in placeholder mode instead of a live arrange-window read.",
            placeholder_count=placeholder_count,
        )

    project_track_count = project_data.get("trackCount")
    if not isinstance(project_track_count, int):
        project_track_count = 0
    inferred_track_count = max(project_track_count, len(track_rows))
    if ui.project_picker_visible and not _nonblocking_project_picker_has_live_track(
        ui,
        health=health,
        inferred_track_count=inferred_track_count,
    ):
        return FreshSessionAssessment(
            False,
            "project_picker_visible",
            "The Choose Project picker is still visible; do not continue into a polluted session.",
        )
    if inferred_track_count > config.max_tracks:
        return FreshSessionAssessment(
            False,
            "polluted_session",
            f"Expected at most {config.max_tracks} fresh track(s), observed {inferred_track_count}.",
            inferred_track_count=inferred_track_count,
            placeholder_count=placeholder_count,
        )
    if region_count > 0:
        return FreshSessionAssessment(
            False,
            "existing_regions_present",
            f"Expected an empty project, but observed {region_count} region(s) on track 0.",
            inferred_track_count=inferred_track_count,
            placeholder_count=placeholder_count,
            region_count=region_count,
        )

    return FreshSessionAssessment(
        True,
        inferred_track_count=inferred_track_count,
        placeholder_count=placeholder_count,
        region_count=region_count,
    )


@dataclass(frozen=True)
class AppleScriptProbe:
    output: str | None
    error: str | None


def _run_osascript_probe(lines: Sequence[str], timeout_sec: float = 3.0) -> AppleScriptProbe:
    args = ["/usr/bin/osascript"]
    for line in lines:
        args.extend(["-e", line])
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
    except FileNotFoundError:
        return AppleScriptProbe(None, "osascript_not_found")
    except subprocess.TimeoutExpired:
        return AppleScriptProbe(None, "osascript_timeout")
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        if len(detail) > 240:
            detail = detail[:237] + "..."
        suffix = f": {detail}" if detail else ""
        return AppleScriptProbe(None, f"osascript_exit_{result.returncode}{suffix}")
    return AppleScriptProbe(result.stdout.strip(), None)


def _run_osascript(lines: Sequence[str], timeout_sec: float = 3.0) -> str | None:
    return _run_osascript_probe(lines, timeout_sec=timeout_sec).output


def _split_lines(output: str | None) -> list[str]:
    if not output:
        return []
    return [line.strip() for line in output.splitlines() if line.strip()]


def _activate_logic() -> bool:
    if _run_osascript([f'tell application "{LOGIC_APP_NAME}" to activate'], timeout_sec=2.0) is not None:
        return True
    try:
        result = subprocess.run(
            ["/usr/bin/open", "-a", LOGIC_APP_NAME],
            capture_output=True,
            text=True,
            timeout=2.0,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _hide_application(name: str) -> bool:
    escaped = name.replace("\\", "\\\\").replace('"', '\\"')
    output = _run_osascript(
        [
            f'tell application "{escaped}"',
            "if it is running then hide",
            "end tell",
        ],
        timeout_sec=2.0,
    )
    return output is not None


def _send_key_event(key_name: str, fallback_script_lines: Sequence[str]) -> bool:
    native_key_script = Path(__file__).with_name("logic_key_event.swift")
    if native_key_script.exists():
        try:
            result = subprocess.run(
                ["/usr/bin/swift", str(native_key_script), key_name],
                capture_output=True,
                text=True,
                timeout=5.0,
                check=False,
            )
            if result.returncode == 0:
                return True
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

    output = _run_osascript(list(fallback_script_lines), timeout_sec=2.0)
    return output is not None


def _send_return_key() -> bool:
    return _send_key_event("return", ['tell application "System Events" to key code 36'])


def _send_escape_key() -> bool:
    return _send_key_event("escape", ['tell application "System Events" to key code 53'])


def _click_dialog_button(window_markers: Sequence[str], button_labels: Sequence[str]) -> bool:
    native_script = Path(__file__).with_name("logic_ax_button_press.swift")
    if native_script.exists():
        try:
            native = subprocess.run(
                ["/usr/bin/swift", str(native_script)],
                input=json.dumps(
                    {
                        "windowMarkers": list(window_markers),
                        "buttonLabels": list(button_labels),
                    },
                    ensure_ascii=False,
                ),
                capture_output=True,
                text=True,
                timeout=6.0,
                check=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            native = None
        if native is not None and native.returncode == 0:
            payload = _safe_json(native.stdout.strip())
            if isinstance(payload, dict) and payload.get("ok") is True:
                time.sleep(0.5)
                return True

    window_markers_json = json.dumps(list(window_markers), ensure_ascii=False)
    button_labels_json = json.dumps(list(button_labels), ensure_ascii=False)
    script = f"""
const windowMarkers = {window_markers_json};
const buttonLabels = {button_labels_json};

function safe(fn, fallback) {{
  try {{
    return fn();
  }} catch (error) {{
    return fallback;
  }}
}}

function str(value) {{
  return value === undefined || value === null ? "" : String(value);
}}

function containsMarker(value, markers) {{
  const haystack = str(value).toLowerCase();
  return markers.some((marker) => haystack.includes(str(marker).toLowerCase()));
}}

function findButton(node, depth) {{
  if (depth > 4) return null;
  const role = str(safe(() => node.role(), ""));
  const name = str(safe(() => node.name(), ""));
  if (role === "AXButton" && buttonLabels.includes(name)) {{
    return node;
  }}
  const children = safe(() => node.uiElements(), []);
  for (let index = 0; index < children.length; index += 1) {{
    const found = findButton(children[index], depth + 1);
    if (found !== null) {{
      return found;
    }}
  }}
  return null;
}}

const se = Application("System Events");
const proc = se.processes.byName("Logic Pro");
const windows = safe(() => proc.windows(), []);
let targetWindow = null;
for (let index = 0; index < windows.length; index += 1) {{
  const candidate = windows[index];
  if (containsMarker(safe(() => candidate.name(), ""), windowMarkers)) {{
    targetWindow = candidate;
    break;
  }}
}}
if (targetWindow === null) {{
  JSON.stringify({{ ok: false, reason: "missing_window" }});
}} else {{
  const button = findButton(targetWindow, 0);
  if (button === null) {{
    JSON.stringify({{ ok: false, reason: "missing_button" }});
  }} else {{
    button.actions.byName("AXPress").perform();
    delay(0.5);
    JSON.stringify({{ ok: true }});
  }}
}}
"""
    _activate_logic()
    time.sleep(0.1)
    for _ in range(2):
        try:
            result = subprocess.run(
                ["/usr/bin/osascript", "-l", "JavaScript"],
                input=script,
                capture_output=True,
                text=True,
                timeout=10.0,
                check=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            time.sleep(0.25)
            continue
        if result.returncode == 0:
            payload = _safe_json(result.stdout.strip())
            if isinstance(payload, dict) and payload.get("ok") is True:
                return True
            latest_ui = collect_ui_snapshot()
            if not _contains_marker(latest_ui.logic_window_names, window_markers):
                return True
        time.sleep(0.25)
    return False


def _click_dialog_cancel_button(window_markers: Sequence[str]) -> bool:
    return _click_dialog_button(window_markers, SAVE_DIALOG_CANCEL_BUTTONS)


def _click_save_dialog_cancel_button() -> bool:
    return _click_dialog_cancel_button(SAVE_DIALOG_MARKERS)


def _click_safe_dialog_cancel_button() -> bool:
    return _click_dialog_cancel_button(SAFE_DISMISS_DIALOG_MARKERS)


def _click_project_picker_choose_button() -> bool:
    return _click_dialog_button(PROJECT_PICKER_MARKERS, PROJECT_PICKER_CHOOSE_BUTTONS)


def _frontmost_application_probe() -> tuple[str | None, str | None]:
    result = _run_osascript_probe(
        ['tell application "System Events" to get name of first application process whose frontmost is true'],
        timeout_sec=2.0,
    )
    return result.output, result.error


def _logic_document_open_probe(timeout_sec: float = 2.0) -> tuple[bool | None, str | None]:
    result = _run_osascript_probe(
        [
            f'tell application "{LOGIC_APP_NAME}"',
            "return count of documents as text",
            "end tell",
        ],
        timeout_sec=timeout_sec,
    )
    if result.error:
        return None, result.error
    raw = (result.output or "").strip()
    try:
        return int(raw) > 0, None
    except ValueError:
        return None, f"document_count_invalid:{raw!r}"


def _remaining_timeout(deadline: float, cap: float, floor: float = 0.1) -> float:
    remaining = deadline - time.time()
    if remaining <= floor:
        return floor
    return min(cap, remaining)


def _logic_window_names_probe() -> tuple[list[str], str | None]:
    result = _run_osascript_probe(
        [
            'tell application "System Events"',
            f'if not (exists application process "{LOGIC_APP_NAME}") then return ""',
            f'tell application process "{LOGIC_APP_NAME}"',
            "set AppleScript's text item delimiters to linefeed",
            "return (name of windows) as text",
            "end tell",
            "end tell",
        ],
        timeout_sec=2.0,
    )
    return _split_lines(result.output), result.error


def _logic_menu_items_probe() -> tuple[list[str], str | None]:
    result = _run_osascript_probe(
        [
            'tell application "System Events"',
            f'tell application process "{LOGIC_APP_NAME}"',
            "set AppleScript's text item delimiters to linefeed",
            "return (name of menu bar items of menu bar 1) as text",
            "end tell",
            "end tell",
        ],
        timeout_sec=2.0,
    )
    return _split_lines(result.output), result.error


def _ui_snapshot_from_native_payload(payload: Any) -> UISnapshot | None:
    if not isinstance(payload, dict):
        return None
    frontmost_app = payload.get("frontmost_app")
    frontmost_bundle_id = payload.get("frontmost_bundle_id")
    window_names = payload.get("logic_window_names")
    menu_items = payload.get("logic_menu_items")
    blocking_dialog_present = payload.get("blocking_dialog_present", False)
    if frontmost_app is not None and not isinstance(frontmost_app, str):
        return None
    if frontmost_bundle_id is not None and not isinstance(frontmost_bundle_id, str):
        return None
    if not isinstance(blocking_dialog_present, bool):
        return None
    if frontmost_bundle_id == "com.apple.logic10":
        frontmost_app = LOGIC_APP_NAME
    if not isinstance(window_names, list) or not all(isinstance(item, str) for item in window_names):
        return None
    if not isinstance(menu_items, list) or not all(isinstance(item, str) for item in menu_items):
        return None
    error = payload.get("error")
    if error is not None and not isinstance(error, str):
        return None
    return UISnapshot(
        frontmost_app=frontmost_app,
        logic_window_names=window_names,
        logic_menu_items=menu_items,
        detected_language=detect_language(menu_items),
        system_events_error=error,
        project_picker_visible=_contains_marker(window_names, PROJECT_PICKER_MARKERS),
        new_track_dialog_visible=_contains_marker(window_names, NEW_TRACK_DIALOG_MARKERS),
        blocking_dialog_present=blocking_dialog_present,
    )


def _native_ui_snapshot() -> tuple[UISnapshot | None, str | None]:
    script = Path(__file__).with_name("logic_ui_snapshot.swift")
    if not script.exists():
        return None, "native_snapshot_script_missing"
    try:
        result = subprocess.run(
            ["/usr/bin/swift", str(script)],
            capture_output=True,
            text=True,
            timeout=5.0,
            check=False,
        )
    except FileNotFoundError:
        return None, "swift_not_found"
    except subprocess.TimeoutExpired:
        return None, "native_snapshot_timeout"
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        if len(detail) > 240:
            detail = detail[:237] + "..."
        if detail:
            return None, f"native_snapshot_exit_{result.returncode}: {detail}"
        return None, f"native_snapshot_exit_{result.returncode}"
    payload = _safe_json(result.stdout.strip())
    snapshot = _ui_snapshot_from_native_payload(payload)
    if snapshot is None:
        return None, "native_snapshot_invalid_json"
    return snapshot, None


_BLOCKING_DIALOG_SUBROLE_JXA = "\n".join([
    'function safe(fn, fallback) { try { return fn(); } catch (e) { return fallback; } }',
    'function str(v) { return v === undefined || v === null ? "" : String(v); }',
    'const se = Application("System Events");',
    'const proc = safe(() => se.processes.byName("Logic Pro"), null);',
    'if (!proc) { JSON.stringify({status: "no_process"}); }',
    'else {',
    '  const wins = safe(() => proc.windows(), []);',
    '  let blocking = false;',
    '  for (let i = 0; i < wins.length; i += 1) {',
    '    const sr = str(safe(() => wins[i].subrole(), ""));',
    '    if (sr === "AXDialog" || sr === "AXSystemDialog") { blocking = true; break; }',
    '  }',
    '  JSON.stringify({status: "ok", blocking: blocking});',
    '}',
])


def _jxa_blocking_dialog_probe() -> bool | None:
    """Mirror the native AX-subrole blocking-dialog check (AXDialog /
    AXSystemDialog) in the AppleScript fallback so a generic modal that is
    neither the project picker nor the new-track dialog is still detected.

    Returns None when the JXA probe is unavailable or fails, so the caller
    degrades to marker-only detection rather than reporting a false negative.
    """
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-l", "JavaScript"],
            input=_BLOCKING_DIALOG_SUBROLE_JXA,
            text=True,
            capture_output=True,
            check=False,
            timeout=5.0,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    payload = _safe_json(result.stdout.strip())
    if not isinstance(payload, dict) or payload.get("status") != "ok":
        return None
    blocking = payload.get("blocking")
    return blocking if isinstance(blocking, bool) else None


def collect_ui_snapshot() -> UISnapshot:
    native_snapshot, native_error = _native_ui_snapshot()
    if native_snapshot is not None:
        return native_snapshot

    window_names, window_error = _logic_window_names_probe()
    menu_items, menu_error = _logic_menu_items_probe()
    frontmost_app, frontmost_error = _frontmost_application_probe()
    probe_errors = [error for error in (native_error, window_error, menu_error, frontmost_error) if error]
    # Fallback parity with the native snapshot: also detect generic blocking
    # modals (alerts/sheets) via an AX-subrole probe, not just the project
    # picker / new-track dialog markers. Degrades to marker-only when the JXA
    # probe is unavailable so it never reports a false negative.
    generic_blocking = _jxa_blocking_dialog_probe()
    return UISnapshot(
        frontmost_app=frontmost_app,
        logic_window_names=window_names,
        logic_menu_items=menu_items,
        detected_language=detect_language(menu_items),
        system_events_error="; ".join(probe_errors) if probe_errors else None,
        project_picker_visible=_contains_marker(window_names, PROJECT_PICKER_MARKERS),
        new_track_dialog_visible=_contains_marker(window_names, NEW_TRACK_DIALOG_MARKERS),
        blocking_dialog_present=(
            _contains_marker(window_names, PROJECT_PICKER_MARKERS)
            or _contains_marker(window_names, NEW_TRACK_DIALOG_MARKERS)
            or generic_blocking is True
        ),
    )


def _response_is_error(response: Any) -> bool:
    try:
        return bool(response["result"].get("isError", False))
    except Exception:
        return True


def _response_payload(response: Any, tool_text: Callable[[Any], str]) -> Any:
    return _safe_json(tool_text(response))


def _response_is_uncertain_success(response: Any, tool_text: Callable[[Any], str]) -> bool:
    if not _response_is_error(response):
        return False
    payload = _response_payload(response, tool_text)
    return (
        isinstance(payload, dict)
        and payload.get("success") is True
        and payload.get("verified") is False
    )


def _response_requires_first_track_creation_ui_wait(
    response: Any,
    tool_text: Callable[[Any], str],
    ui: UISnapshot,
    health: dict[str, Any],
) -> bool:
    if not _response_is_error(response) or not _fresh_project_blank_shell(ui, health):
        return False
    payload = _response_payload(response, tool_text)
    if not isinstance(payload, dict):
        return False
    if payload.get("operation") != "track.create_instrument":
        return False
    if payload.get("error") != "channels_exhausted":
        return False
    for key in ("hint", "last_error"):
        value = payload.get(key)
        if isinstance(value, str) and "logic pro is not running" in value.lower():
            return True
    return False


def _tool_json(
    call_tool: Callable[[str, str, dict[str, Any] | None, float | None], Any],
    tool_text: Callable[[Any], str],
    tool: str,
    command: str,
    params: dict[str, Any] | None = None,
    timeout: float | None = None,
) -> tuple[Any, str, Any]:
    response = call_tool(tool, command, params or None, timeout)
    text = tool_text(response)
    return response, text, _safe_json(text)


def _resource_json(
    read_resource: Callable[[str], Any],
    resource_text: Callable[[Any], str],
    uri: str,
) -> tuple[Any, str, Any]:
    response = read_resource(uri)
    text = resource_text(response)
    return response, text, _safe_json(text)


def bootstrap_fresh_logic_session(
    *,
    call_tool: Callable[[str, str, dict[str, Any] | None, float | None], Any],
    read_resource: Callable[[str], Any],
    tool_text: Callable[[Any], str],
    resource_text: Callable[[Any], str],
    strict_live: bool,
    log: Callable[[str], None] = print,
    env: Mapping[str, str] | None = None,
) -> BootstrapResult:
    config = BootstrapConfig.from_env(strict_live=strict_live, env=env)
    actions: list[str] = []

    def blocked(
        reason: str,
        hint: str,
        *,
        health: dict[str, Any] | None = None,
        project: dict[str, Any] | None = None,
        tracks: dict[str, Any] | None = None,
        regions: dict[str, Any] | None = None,
        ui: UISnapshot | None = None,
    ) -> BootstrapResult:
        return BootstrapResult(
            ok=False,
            reason=reason,
            hint=hint,
            actions=actions,
            ui=asdict(ui) if ui else {},
            health=health or {},
            project=project or {},
            tracks=tracks or {},
            regions=regions or {},
        )

    def fetch_health(timeout_sec: float | None = None) -> tuple[Any, dict[str, Any] | None]:
        effective_timeout_sec = config.timeout_sec if timeout_sec is None else timeout_sec
        response, text, parsed = _tool_json(
            call_tool,
            tool_text,
            "logic_system",
            "health",
            timeout=effective_timeout_sec,
        )
        if _response_is_error(response) or not isinstance(parsed, dict):
            log(f"  [bootstrap] system.health unavailable: {text or response!r}")
            return response, None
        return response, parsed

    def clear_hidden_blocking_dialog(
        ui_local: UISnapshot,
        health_local: dict[str, Any],
        action_label: str,
    ) -> tuple[UISnapshot, dict[str, Any], bool] | BootstrapResult:
        if not ui_local.blocking_dialog_present:
            return ui_local, health_local, False
        permissions = health_local.get("permissions", {})
        if permissions.get("post_event_access") is not True:
            return blocked(
                "post_event_access_denied",
                "Need CGEvent post-event access to confirm Logic's blocking dialog.",
                health=health_local,
                ui=ui_local,
            )
        if not _send_return_key():
            return blocked(
                "blocking_dialog_clear_failed",
                "Return key dispatch failed while trying to dismiss Logic's blocking dialog.",
                health=health_local,
                ui=ui_local,
            )
        actions.append(action_label)
        call_tool("logic_system", "refresh_cache", None, 5.0)
        actions.append("logic_system.refresh_cache")
        time.sleep(config.poll_interval_sec)
        _, latest_health = fetch_health()
        if latest_health is not None:
            health_local = latest_health
        ui_local = collect_ui_snapshot()
        return ui_local, health_local, True

    def dismiss_safe_blocking_dialog(
        ui_local: UISnapshot,
        health_local: dict[str, Any],
        action_label: str,
    ) -> tuple[UISnapshot, dict[str, Any], bool] | BootstrapResult:
        if not ui_local.blocking_dialog_present:
            return ui_local, health_local, False
        if not _contains_marker(ui_local.logic_window_names, SAFE_DISMISS_DIALOG_MARKERS):
            return ui_local, health_local, False
        permissions = health_local.get("permissions", {})
        if permissions.get("post_event_access") is not True:
            return blocked(
                "post_event_access_denied",
                "Need CGEvent post-event access to dismiss Logic's import/open dialog.",
                health=health_local,
                ui=ui_local,
            )
        method = "cancel_button"
        dismissed = _click_safe_dialog_cancel_button()
        if not dismissed:
            method = "escape"
            dismissed = _send_escape_key()
        if not dismissed:
            return blocked(
                "safe_dialog_dismiss_failed",
                "Cancel button and Escape key dispatch both failed while trying to dismiss Logic's import/open dialog.",
                health=health_local,
                ui=ui_local,
            )
        actions.append(f"{action_label}:{method}")
        call_tool("logic_system", "refresh_cache", None, 5.0)
        actions.append("logic_system.refresh_cache")
        time.sleep(config.poll_interval_sec)
        _, latest_health = fetch_health()
        if latest_health is not None:
            health_local = latest_health
        ui_local = collect_ui_snapshot()
        if ui_local.blocking_dialog_present and _contains_marker(
            ui_local.logic_window_names,
            SAFE_DISMISS_DIALOG_MARKERS,
        ):
            return blocked(
                "safe_dialog_dismiss_failed",
                "Logic's import/open dialog remained visible after pressing Escape.",
                health=health_local,
                ui=ui_local,
            )
        return ui_local, health_local, True

    def settle_initial_blocking_ui(
        ui_local: UISnapshot,
        health_local: dict[str, Any],
    ) -> tuple[UISnapshot, dict[str, Any]] | BootstrapResult:
        deadline = time.time() + config.timeout_sec
        while True:
            dismissed_save = dismiss_visible_save_dialog(
                ui_local,
                health_local,
                "dismiss_save_dialog:cancel_button",
            )
            if isinstance(dismissed_save, BootstrapResult):
                return dismissed_save
            ui_local, health_local, did_dismiss_save = dismissed_save
            if not ui_local.blocking_dialog_present:
                return ui_local, health_local
            if did_dismiss_save:
                if time.time() >= deadline:
                    break
                continue
            dismissed_safe = dismiss_safe_blocking_dialog(
                ui_local,
                health_local,
                "dismiss_safe_blocking_dialog",
            )
            if isinstance(dismissed_safe, BootstrapResult):
                return dismissed_safe
            ui_local, health_local, did_dismiss_safe = dismissed_safe
            if not ui_local.blocking_dialog_present:
                return ui_local, health_local
            if did_dismiss_safe:
                if time.time() >= deadline:
                    break
                continue
            if ui_local.project_picker_visible or ui_local.new_track_dialog_visible:
                return ui_local, health_local

            cleared = clear_hidden_blocking_dialog(ui_local, health_local, "clear_initial_blocking_dialog:return")
            if isinstance(cleared, BootstrapResult):
                return cleared
            ui_local, health_local, did_clear = cleared
            if not ui_local.blocking_dialog_present:
                return ui_local, health_local
            if not did_clear or time.time() >= deadline:
                return blocked(
                    "blocking_dialog_clear_failed",
                    "Logic's blocking dialog remained visible after confirmation.",
                    health=health_local,
                    ui=ui_local,
                )

    def dismiss_visible_save_dialog(
        ui_local: UISnapshot,
        health_local: dict[str, Any],
        action_label: str,
    ) -> tuple[UISnapshot, dict[str, Any], bool] | BootstrapResult:
        if not ui_local.blocking_dialog_present:
            return ui_local, health_local, False
        if not _contains_marker(ui_local.logic_window_names, SAVE_DIALOG_MARKERS):
            return ui_local, health_local, False
        permissions = health_local.get("permissions", {})
        if permissions.get("accessibility") is not True:
            return blocked(
                "accessibility_denied",
                "Need Accessibility access to dismiss Logic's Save dialog.",
                health=health_local,
                ui=ui_local,
            )
        _click_save_dialog_cancel_button()
        actions.append(action_label)
        call_tool("logic_system", "refresh_cache", None, 5.0)
        actions.append("logic_system.refresh_cache")
        time.sleep(config.poll_interval_sec)
        _, latest_health = fetch_health()
        if latest_health is not None:
            health_local = latest_health
        ui_local = collect_ui_snapshot()
        # #187: Logic's Save prompt can expose buttons with no AX name, so the
        # Cancel marker match is a no-op and the prompt stays visible. Fall back
        # to the Escape key — which cancels the save sheet without saving or
        # discarding — but ONLY after attempting Cancel (Cancel-before-Escape).
        escape_attempted = False
        if ui_local.blocking_dialog_present and _contains_marker(
            ui_local.logic_window_names, SAVE_DIALOG_MARKERS
        ):
            escape_attempted = _send_escape_key()
            if escape_attempted:
                actions.append("dismiss_save_dialog:escape_fallback")
                call_tool("logic_system", "refresh_cache", None, 5.0)
                actions.append("logic_system.refresh_cache")
                time.sleep(config.poll_interval_sec)
                _, latest_health = fetch_health()
                if latest_health is not None:
                    health_local = latest_health
                ui_local = collect_ui_snapshot()
        if ui_local.blocking_dialog_present and _contains_marker(ui_local.logic_window_names, SAVE_DIALOG_MARKERS):
            # Report only what was actually attempted (the Escape key is skipped
            # when _send_escape_key() can't post, e.g. post-event access denied).
            attempted = "Cancel and Escape" if escape_attempted else "Cancel"
            return blocked(
                "save_dialog_dismiss_failed",
                f"Logic's Save dialog remained visible after pressing {attempted}.",
                health=health_local,
                ui=ui_local,
            )
        return ui_local, health_local, True

    def settle_first_track_creation_ui(
        ui_local: UISnapshot,
        health_local: dict[str, Any],
    ) -> tuple[UISnapshot, dict[str, Any]] | BootstrapResult:
        deadline = time.time() + config.timeout_sec
        max_deadline = deadline + config.timeout_sec

        def extend_deadline() -> None:
            nonlocal deadline
            deadline = min(max_deadline, time.time() + config.timeout_sec)

        while time.time() < deadline:
            if ui_local.frontmost_app != LOGIC_APP_NAME and (
                ui_local.project_picker_visible
                or ui_local.new_track_dialog_visible
                or ui_local.blocking_dialog_present
            ):
                ui_local, activated = ensure_logic_frontmost()
                if activated:
                    actions.append("activate:Logic Pro")
                    extend_deadline()
                if ui_local.frontmost_app != LOGIC_APP_NAME:
                    time.sleep(config.poll_interval_sec)
                    _, latest_health = fetch_health()
                    if latest_health is not None:
                        health_local = latest_health
                    ui_local = collect_ui_snapshot()
                continue

            dismissed_save = dismiss_visible_save_dialog(
                ui_local,
                health_local,
                "dismiss_save_dialog:cancel_button",
            )
            if isinstance(dismissed_save, BootstrapResult):
                return dismissed_save
            ui_local, health_local, did_dismiss_save = dismissed_save
            if did_dismiss_save:
                extend_deadline()
                continue

            dismissed_safe = dismiss_safe_blocking_dialog(
                ui_local,
                health_local,
                "dismiss_safe_blocking_dialog",
            )
            if isinstance(dismissed_safe, BootstrapResult):
                return dismissed_safe
            ui_local, health_local, did_dismiss_safe = dismissed_safe
            if did_dismiss_safe:
                extend_deadline()
                continue

            if ui_local.project_picker_visible:
                ui_local, activated = ensure_logic_frontmost(force_activate=True)
                if activated:
                    actions.append("activate:Logic Pro")
                    extend_deadline()
                if ui_local.frontmost_app != LOGIC_APP_NAME:
                    time.sleep(config.poll_interval_sec)
                    _, latest_health = fetch_health()
                    if latest_health is not None:
                        health_local = latest_health
                    ui_local = collect_ui_snapshot()
                    continue
                permissions = health_local.get("permissions", {})
                if permissions.get("post_event_access") is not True:
                    return blocked(
                        "post_event_access_denied",
                        "Need CGEvent post-event access to confirm Logic's project picker.",
                        health=health_local,
                        ui=ui_local,
                    )
                if _click_project_picker_choose_button():
                    actions.append("confirm_project_picker:choose_button")
                else:
                    if not _send_return_key():
                        return blocked(
                            "project_picker_confirm_failed",
                            "Choose button click and Return key dispatch both failed while trying to confirm Logic's project picker.",
                            health=health_local,
                            ui=ui_local,
                        )
                    actions.append("confirm_project_picker:return")
                extend_deadline()
            elif ui_local.new_track_dialog_visible:
                ui_local, activated = ensure_logic_frontmost(force_activate=True)
                if activated:
                    actions.append("activate:Logic Pro")
                    extend_deadline()
                if ui_local.frontmost_app != LOGIC_APP_NAME:
                    time.sleep(config.poll_interval_sec)
                    _, latest_health = fetch_health()
                    if latest_health is not None:
                        health_local = latest_health
                    ui_local = collect_ui_snapshot()
                    continue
                permissions = health_local.get("permissions", {})
                if permissions.get("post_event_access") is not True:
                    return blocked(
                        "post_event_access_denied",
                        "Need CGEvent post-event access to confirm Logic's new-track dialog.",
                        health=health_local,
                        ui=ui_local,
                    )
                if not _send_return_key():
                    return blocked(
                        "new_track_dialog_confirm_failed",
                        "Return key dispatch failed while trying to confirm Logic's new-track dialog.",
                        health=health_local,
                        ui=ui_local,
                    )
                actions.append("confirm_new_track_dialog:return")
                extend_deadline()
            else:
                cleared = clear_hidden_blocking_dialog(
                    ui_local,
                    health_local,
                    "confirm_hidden_blocking_dialog:return",
                )
                if isinstance(cleared, BootstrapResult):
                    return cleared
                ui_local, health_local, did_clear = cleared
                if did_clear:
                    extend_deadline()
                    continue
                return ui_local, health_local

            call_tool("logic_system", "refresh_cache", None, 5.0)
            actions.append("logic_system.refresh_cache")
            time.sleep(config.poll_interval_sec)
            _, latest_health = fetch_health()
            if latest_health is not None:
                health_local = latest_health
            ui_local = collect_ui_snapshot()
        return blocked(
            "fresh_track_ui_not_ready",
            "Logic kept the project picker or blocking dialog open before first track creation.",
            health=health_local,
            ui=ui_local,
        )

    def wait_for_first_track_creation_ui_signal(
        ui_local: UISnapshot,
        health_local: dict[str, Any],
    ) -> tuple[UISnapshot, dict[str, Any]]:
        if not _fresh_project_blank_shell(ui_local, health_local):
            return ui_local, health_local

        deadline = time.time() + min(
            6.0,
            max(config.poll_interval_sec * 6.0, config.timeout_sec * 0.75),
        )
        while time.time() < deadline:
            time.sleep(config.poll_interval_sec)
            _activate_logic()
            call_tool("logic_system", "refresh_cache", None, 5.0)
            actions.append("logic_system.refresh_cache")
            _, latest_health = fetch_health(_remaining_timeout(deadline, config.timeout_sec))
            if latest_health is not None:
                health_local = latest_health
            ui_local = collect_ui_snapshot()
            if not _fresh_project_blank_shell(ui_local, health_local):
                break
        return ui_local, health_local

    def prime_first_track_creation_ui(
        ui_local: UISnapshot,
        health_local: dict[str, Any],
    ) -> tuple[UISnapshot, dict[str, Any]] | BootstrapResult:
        if ui_local.frontmost_app != LOGIC_APP_NAME and (
            ui_local.project_picker_visible
            or ui_local.new_track_dialog_visible
            or ui_local.blocking_dialog_present
        ):
            ui_local, activated = ensure_logic_frontmost()
            if activated:
                actions.append("activate:Logic Pro")

        dismissed_save = dismiss_visible_save_dialog(
            ui_local,
            health_local,
            "dismiss_save_dialog:cancel_button",
        )
        if isinstance(dismissed_save, BootstrapResult):
            return dismissed_save
        ui_local, health_local, did_dismiss_save = dismissed_save

        dismissed_safe = dismiss_safe_blocking_dialog(
            ui_local,
            health_local,
            "dismiss_safe_blocking_dialog",
        )
        if isinstance(dismissed_safe, BootstrapResult):
            return dismissed_safe
        ui_local, health_local, did_dismiss_safe = dismissed_safe

        if ui_local.project_picker_visible:
            ui_local, activated = ensure_logic_frontmost(force_activate=True)
            if activated:
                actions.append("activate:Logic Pro")
            if ui_local.frontmost_app != LOGIC_APP_NAME:
                return ui_local, health_local
            permissions = health_local.get("permissions", {})
            if permissions.get("post_event_access") is not True:
                return blocked(
                    "post_event_access_denied",
                    "Need CGEvent post-event access to confirm Logic's project picker.",
                    health=health_local,
                    ui=ui_local,
                )
            if _click_project_picker_choose_button():
                actions.append("confirm_project_picker:choose_button")
            else:
                if not _send_return_key():
                    return blocked(
                        "project_picker_confirm_failed",
                        "Choose button click and Return key dispatch both failed while trying to confirm Logic's project picker.",
                        health=health_local,
                        ui=ui_local,
                    )
                actions.append("confirm_project_picker:return")
        elif ui_local.new_track_dialog_visible:
            ui_local, activated = ensure_logic_frontmost(force_activate=True)
            if activated:
                actions.append("activate:Logic Pro")
            if ui_local.frontmost_app != LOGIC_APP_NAME:
                return ui_local, health_local
            permissions = health_local.get("permissions", {})
            if permissions.get("post_event_access") is not True:
                return blocked(
                    "post_event_access_denied",
                    "Need CGEvent post-event access to confirm Logic's new-track dialog.",
                    health=health_local,
                    ui=ui_local,
                )
            if not _send_return_key():
                return blocked(
                    "new_track_dialog_confirm_failed",
                    "Return key dispatch failed while trying to confirm Logic's new-track dialog.",
                    health=health_local,
                    ui=ui_local,
                )
            actions.append("confirm_new_track_dialog:return")
        elif ui_local.blocking_dialog_present:
            cleared = clear_hidden_blocking_dialog(
                ui_local,
                health_local,
                "confirm_hidden_blocking_dialog:return",
            )
            if isinstance(cleared, BootstrapResult):
                return cleared
            ui_local, health_local, did_clear = cleared
            if not did_clear and not did_dismiss_save and not did_dismiss_safe:
                return ui_local, health_local
        elif not did_dismiss_save and not did_dismiss_safe:
            return ui_local, health_local

        call_tool("logic_system", "refresh_cache", None, 5.0)
        actions.append("logic_system.refresh_cache")
        time.sleep(config.poll_interval_sec)
        _, latest_health = fetch_health()
        if latest_health is not None:
            health_local = latest_health
        ui_local = collect_ui_snapshot()
        return ui_local, health_local

    def ensure_logic_frontmost(
        timeout_sec: float = 2.0,
        *,
        force_activate: bool = False,
    ) -> tuple[UISnapshot, bool]:
        ui_local = collect_ui_snapshot()
        if ui_local.frontmost_app == LOGIC_APP_NAME and not force_activate:
            return ui_local, False

        deadline = time.time() + timeout_sec
        activated = False
        focus_settle_sec = min(0.2, max(0.05, config.poll_interval_sec))
        while time.time() < deadline:
            if _activate_logic():
                activated = True
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            time.sleep(min(focus_settle_sec, remaining))
            ui_local = collect_ui_snapshot()
            if ui_local.frontmost_app == LOGIC_APP_NAME:
                return ui_local, activated
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            time.sleep(min(config.poll_interval_sec, remaining))
        return collect_ui_snapshot(), activated

    _, health = fetch_health()
    if health is None:
        return blocked("health_unavailable", "Could not read logic_system.health from the MCP server.")

    if health.get("logic_pro_running") is not True:
        if not config.allow_launch:
            return blocked(
                "logic_not_running",
                "Logic Pro is not running and auto-launch is disabled.",
                health=health,
            )
        log("  [bootstrap] launching Logic Pro")
        response = call_tool("logic_project", "launch", None, 10.0)
        actions.append("logic_project.launch")
        if _response_is_error(response):
            return blocked(
                "logic_launch_failed",
                tool_text(response) or "logic_project.launch failed",
                health=health,
            )
        launch_observed = False
        launch_health = health
        deadline = time.time() + config.timeout_sec
        while time.time() < deadline:
            _, latest = fetch_health(_remaining_timeout(deadline, config.timeout_sec))
            if latest is not None:
                launch_health = latest
                if latest.get("logic_pro_running") is True:
                    launch_observed = True
                    break
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            time.sleep(min(config.poll_interval_sec, remaining))
        if not launch_observed:
            return blocked(
                "logic_launch_timeout",
                "Logic Pro did not reach a running state after launch.",
                health=launch_health or health,
            )
        health = launch_health

    for app_name in config.hide_apps:
        if _hide_application(app_name):
            actions.append(f"hide:{app_name}")

    _activate_logic()
    actions.append("activate:Logic Pro")
    time.sleep(min(0.2, max(0.05, config.poll_interval_sec)))

    ui = collect_ui_snapshot()
    if ui.frontmost_app != LOGIC_APP_NAME:
        ui, activated = ensure_logic_frontmost()
        if activated:
            actions.append("activate:Logic Pro")
    cleared = settle_initial_blocking_ui(ui, health)
    if isinstance(cleared, BootstrapResult):
        return cleared
    ui, health = cleared

    if config.force_new_project and health.get("logic_pro_has_document") is not True:
        if _arrange_window_visible(ui.logic_window_names):
            health = dict(health)
            health["logic_pro_has_document"] = True
        else:
            direct_has_document, direct_probe_error = _logic_document_open_probe()
            if direct_has_document is True:
                health = dict(health)
                health["logic_pro_has_document"] = True
            elif direct_has_document is False:
                health = dict(health)
                health["logic_pro_has_document"] = False
            else:
                probe_hint = "Could not confirm whether a Logic document is already open before forcing a fresh project."
                if direct_probe_error:
                    probe_hint = f"{probe_hint} ({direct_probe_error})"
                return blocked(
                    "fresh_project_state_unconfirmed",
                    probe_hint,
                    health=health,
                    ui=ui,
                )

    needs_new_project = (
        config.force_new_project
        or health.get("logic_pro_has_document") is not True
        or ui.project_picker_visible
    )
    if needs_new_project:
        if not config.allow_new_project:
            reason = (
                "force_new_project_disabled"
                if config.force_new_project
                else "project_picker_visible"
                if ui.project_picker_visible
                else "no_document_open"
            )
            hint = (
                "Fresh project creation was requested but auto-new-project is disabled."
                if config.force_new_project
                else
                "The Choose Project picker is visible and auto-new-project is disabled."
                if ui.project_picker_visible
                else "No Logic document is open and auto-new-project is disabled."
            )
            return blocked(
                reason,
                hint,
                health=health,
                ui=ui,
            )
        if config.force_new_project and health.get("logic_pro_has_document") is True:
            dismissed_save = dismiss_visible_save_dialog(ui, health, "dismiss_save_dialog:cancel_button")
            if isinstance(dismissed_save, BootstrapResult):
                return dismissed_save
            ui, health, did_dismiss_save = dismissed_save
            if did_dismiss_save:
                direct_has_document, _ = _logic_document_open_probe(min(config.timeout_sec, 1.0))
                if direct_has_document is not None:
                    health = dict(health)
                    health["logic_pro_has_document"] = direct_has_document
            if health.get("logic_pro_has_document") is not True:
                ui, activated = ensure_logic_frontmost()
                if activated:
                    actions.append("activate:Logic Pro")
            else:
                log("  [bootstrap] closing current Logic document without saving")
                response = call_tool(
                    "logic_project",
                    "close",
                    {"saving": "no", "confirmed": True},
                    10.0,
                )
                actions.append("logic_project.close:saving=no")
                close_error = _response_is_error(response)
                call_tool("logic_system", "refresh_cache", None, 5.0)
                actions.append("logic_system.refresh_cache")
                close_observed = False
                close_probe_error: str | None = None
                deadline = time.time() + config.timeout_sec
                while time.time() < deadline:
                    time.sleep(config.poll_interval_sec)
                    _, latest_health = fetch_health(_remaining_timeout(deadline, config.timeout_sec))
                    if latest_health is not None:
                        health = latest_health
                    direct_has_document, close_probe_error = _logic_document_open_probe(
                        _remaining_timeout(deadline, 2.0)
                    )
                    if direct_has_document is False:
                        health = dict(health)
                        health["logic_pro_has_document"] = False
                        close_observed = True
                        break
                    if (
                        latest_health is not None
                        and latest_health.get("logic_pro_has_document") is False
                        and direct_has_document is not True
                    ):
                        close_observed = True
                        break
                ui, activated = ensure_logic_frontmost()
                if activated:
                    actions.append("activate:Logic Pro")
                if not close_observed:
                    close_hint = tool_text(response) or "Logic document stayed open after close."
                    if close_probe_error:
                        close_hint = f"{close_hint} (document probe: {close_probe_error})"
                    return blocked(
                        "fresh_project_close_failed" if close_error else "fresh_project_close_timeout",
                        close_hint,
                        health=health,
                        ui=ui,
                    )
        log("  [bootstrap] creating a fresh Logic document")
        response = call_tool("logic_project", "new", None, 10.0)
        actions.append("logic_project.new")
        if _response_is_error(response):
            return blocked(
                "new_project_failed",
                tool_text(response) or "logic_project.new failed",
                health=health,
                ui=ui,
            )
        call_tool("logic_system", "refresh_cache", None, 5.0)
        actions.append("logic_system.refresh_cache")

        deadline = time.time() + config.timeout_sec
        max_deadline = deadline + (config.timeout_sec * 2.0)

        def extend_deadline() -> None:
            nonlocal deadline
            deadline = min(max_deadline, time.time() + config.timeout_sec)

        blank_shell_started_at: float | None = None
        blank_shell_grace_sec = min(
            6.0,
            max(config.poll_interval_sec * 6.0, config.timeout_sec * 0.75),
        )

        def fresh_project_ready_observed() -> bool:
            nonlocal blank_shell_started_at
            if _fresh_project_ui_ready(ui, health):
                blank_shell_started_at = None
                return True
            if not _fresh_project_blank_shell(ui, health):
                blank_shell_started_at = None
                return False
            observed_at = time.time()
            if blank_shell_started_at is None:
                blank_shell_started_at = observed_at
                return False
            return (observed_at - blank_shell_started_at) >= blank_shell_grace_sec

        sent_project_picker_return = False
        sent_new_track_return = False
        while time.time() < deadline:
            time.sleep(config.poll_interval_sec)
            _activate_logic()
            _, latest_health = fetch_health(_remaining_timeout(deadline, config.timeout_sec))
            if latest_health is not None:
                health = latest_health
            if health is None:
                continue
            ui = collect_ui_snapshot()
            dismissed_save = dismiss_visible_save_dialog(ui, health, "dismiss_save_dialog:cancel_button")
            if isinstance(dismissed_save, BootstrapResult):
                return dismissed_save
            ui, health, did_dismiss_save = dismissed_save
            if did_dismiss_save:
                extend_deadline()
                if fresh_project_ready_observed():
                    break
                if ui.project_picker_visible:
                    sent_project_picker_return = False
                if ui.new_track_dialog_visible:
                    sent_new_track_return = False
                continue
            if ui.project_picker_visible:
                sent_project_picker_return = False
            if ui.new_track_dialog_visible:
                sent_new_track_return = False
            if fresh_project_ready_observed():
                break
            if (
                ui.project_picker_visible
                and config.confirm_new_track_dialog
                and not sent_project_picker_return
            ):
                ui, activated = ensure_logic_frontmost(force_activate=True)
                if activated:
                    actions.append("activate:Logic Pro")
                    extend_deadline()
                if ui.frontmost_app != LOGIC_APP_NAME:
                    continue
                permissions = health.get("permissions", {})
                if permissions.get("post_event_access") is not True:
                    return blocked(
                        "post_event_access_denied",
                        "Need CGEvent post-event access to confirm Logic's project picker.",
                        health=health,
                        ui=ui,
                )
                if _click_project_picker_choose_button():
                    actions.append("confirm_project_picker:choose_button")
                    sent_project_picker_return = True
                    extend_deadline()
                    call_tool("logic_system", "refresh_cache", None, 5.0)
                    actions.append("logic_system.refresh_cache")
                    continue
                if _send_return_key():
                    actions.append("confirm_project_picker:return")
                    sent_project_picker_return = True
                    extend_deadline()
                    call_tool("logic_system", "refresh_cache", None, 5.0)
                    actions.append("logic_system.refresh_cache")
                    continue

            if (
                ui.new_track_dialog_visible
                and config.confirm_new_track_dialog
                and not sent_new_track_return
            ):
                ui, activated = ensure_logic_frontmost(force_activate=True)
                if activated:
                    actions.append("activate:Logic Pro")
                    extend_deadline()
                if ui.frontmost_app != LOGIC_APP_NAME:
                    continue
                permissions = health.get("permissions", {})
                if permissions.get("post_event_access") is not True:
                    return blocked(
                        "post_event_access_denied",
                        "Need CGEvent post-event access to confirm Logic's new-track dialog.",
                        health=health,
                        ui=ui,
                )
                if _send_return_key():
                    actions.append("confirm_new_track_dialog:return")
                    sent_new_track_return = True
                    extend_deadline()
                    call_tool("logic_system", "refresh_cache", None, 5.0)
                    actions.append("logic_system.refresh_cache")
                    continue

            if (
                ui.blocking_dialog_present
                and config.confirm_new_track_dialog
                and not ui.project_picker_visible
                and not ui.new_track_dialog_visible
                and not sent_new_track_return
            ):
                cleared = clear_hidden_blocking_dialog(ui, health, "confirm_hidden_blocking_dialog:return")
                if isinstance(cleared, BootstrapResult):
                    return cleared
                ui, health, did_clear = cleared
                if did_clear:
                    extend_deadline()
                    sent_new_track_return = True
                    continue

            if fresh_project_ready_observed():
                break
        else:
            return blocked(
                "fresh_project_not_ready",
                "Logic did not settle into a usable fresh project before timeout.",
                health=health or {},
                ui=ui,
            )

    call_tool("logic_system", "refresh_cache", None, 5.0)
    if "logic_system.refresh_cache" not in actions:
        actions.append("logic_system.refresh_cache")
    time.sleep(config.poll_interval_sec)

    _, health = fetch_health()
    if health is None:
        return blocked("health_unavailable", "Could not read health after bootstrap actions.", ui=ui)
    ui = collect_ui_snapshot()

    _, _, project_payload = _resource_json(read_resource, resource_text, "logic://project/info")
    _, _, tracks_payload = _resource_json(read_resource, resource_text, "logic://tracks")
    if not isinstance(project_payload, dict):
        project_payload = _fallback_project_payload(health)
        if project_payload is not None:
            actions.append("fallback:system.health.cache.project")
        else:
            return blocked(
                "project_info_unavailable",
                "logic://project/info did not return JSON and no cache fallback was available.",
                health=health,
                ui=ui,
            )
    if not isinstance(tracks_payload, dict):
        cached_track_count = _health_cache_summary(health).get("track_count")
        if isinstance(cached_track_count, int) and cached_track_count > config.max_tracks:
            return blocked(
                "polluted_session",
                f"Expected at most {config.max_tracks} fresh track(s), observed {cached_track_count} in the cached session state.",
                health=health,
                project=project_payload,
                tracks={
                    "source": "health_cache",
                    "count": cached_track_count,
                },
                ui=ui,
            )
        return blocked(
            "tracks_unavailable",
            "logic://tracks did not return JSON.",
            health=health,
            project=project_payload,
            ui=ui,
        )

    if not _track_rows(tracks_payload) and config.allow_new_project:
        settled_ui = settle_first_track_creation_ui(ui, health)
        if isinstance(settled_ui, BootstrapResult):
            return settled_ui
        ui, health = settled_ui
        ui, activated = ensure_logic_frontmost()
        if activated:
            actions.append("activate:Logic Pro")
        if ui.frontmost_app != LOGIC_APP_NAME:
            return blocked(
                "logic_not_frontmost",
                "Could not restore Logic Pro to the foreground before creating the first track.",
                health=health,
                project=project_payload,
                tracks=tracks_payload,
                ui=ui,
            )
        log("  [bootstrap] creating one fresh software-instrument track")
        create_attempt_limit = 3
        create_attempts = 0
        while create_attempts < create_attempt_limit:
            if create_attempts > 0:
                ui, activated = ensure_logic_frontmost()
                if activated:
                    actions.append("activate:Logic Pro")
                if ui.frontmost_app != LOGIC_APP_NAME:
                    return blocked(
                        "logic_not_frontmost",
                        "Could not restore Logic Pro to the foreground before creating the first track.",
                        health=health,
                        project=project_payload,
                        tracks=tracks_payload,
                        ui=ui,
                    )

            response = call_tool("logic_tracks", "create_instrument", None, 10.0)
            actions.append("logic_tracks.create_instrument")
            create_attempts += 1

            if _response_is_uncertain_success(response, tool_text):
                uncertain_ui = collect_ui_snapshot()
                primed_after_uncertain = prime_first_track_creation_ui(uncertain_ui, health)
                if isinstance(primed_after_uncertain, BootstrapResult):
                    return primed_after_uncertain
                ui, health = primed_after_uncertain
                if create_attempts < create_attempt_limit and _first_track_create_retry_needed(ui, health):
                    continue
                break

            if _response_is_error(response):
                retry_ui = collect_ui_snapshot()
                if _response_requires_first_track_creation_ui_wait(response, tool_text, retry_ui, health):
                    retry_ui, health = wait_for_first_track_creation_ui_signal(retry_ui, health)
                    primed_retry_ui = prime_first_track_creation_ui(retry_ui, health)
                    if isinstance(primed_retry_ui, BootstrapResult):
                        return primed_retry_ui
                    retry_ui, health = primed_retry_ui
                else:
                    settled_retry_ui = settle_first_track_creation_ui(retry_ui, health)
                    if isinstance(settled_retry_ui, BootstrapResult):
                        return settled_retry_ui
                    retry_ui, health = settled_retry_ui

                ui = retry_ui
                if create_attempts < create_attempt_limit:
                    continue
                return blocked(
                    "fresh_track_create_failed",
                    tool_text(response) or "logic_tracks.create_instrument failed",
                    health=health,
                    project=project_payload,
                    tracks=tracks_payload,
                    ui=retry_ui,
                )
            break
        deadline = time.time() + config.timeout_sec
        while time.time() < deadline:
            call_tool("logic_system", "refresh_cache", None, 5.0)
            actions.append("logic_system.refresh_cache")
            time.sleep(config.poll_interval_sec)
            _, health_latest = fetch_health(_remaining_timeout(deadline, config.timeout_sec))
            if health_latest is not None:
                health = health_latest
            ui = collect_ui_snapshot()
            _, _, project_latest = _resource_json(read_resource, resource_text, "logic://project/info")
            if isinstance(project_latest, dict):
                project_payload = project_latest
            _, _, tracks_latest = _resource_json(read_resource, resource_text, "logic://tracks")
            if isinstance(tracks_latest, dict):
                tracks_payload = tracks_latest
                if _track_rows(tracks_payload):
                    break
        else:
            recovery_ui, activated = ensure_logic_frontmost(force_activate=True)
            if activated:
                actions.append("activate:Logic Pro")
            recovered = prime_first_track_creation_ui(recovery_ui, health)
            if isinstance(recovered, BootstrapResult):
                return recovered
            ui, health = recovered
            call_tool("logic_tracks", "create_instrument", None, 10.0)
            actions.append("logic_tracks.create_instrument:recovery")
            recovery_deadline = time.time() + min(config.timeout_sec, 10.0)
            while time.time() < recovery_deadline:
                call_tool("logic_system", "refresh_cache", None, 5.0)
                actions.append("logic_system.refresh_cache")
                time.sleep(config.poll_interval_sec)
                _, health_latest = fetch_health(_remaining_timeout(recovery_deadline, config.timeout_sec))
                if health_latest is not None:
                    health = health_latest
                ui = collect_ui_snapshot()
                _, _, project_latest = _resource_json(read_resource, resource_text, "logic://project/info")
                if isinstance(project_latest, dict):
                    project_payload = project_latest
                _, _, tracks_latest = _resource_json(read_resource, resource_text, "logic://tracks")
                if isinstance(tracks_latest, dict):
                    tracks_payload = tracks_latest
                    if _track_rows(tracks_payload):
                        break
            else:
                return blocked(
                    "fresh_track_unavailable",
                    "The fresh project did not expose a live track after track creation.",
                    health=health,
                    project=project_payload,
                    tracks=tracks_payload,
                    ui=ui,
                )

    region_count = 0
    if _track_rows(tracks_payload):
        _, _, regions_payload = _resource_json(read_resource, resource_text, "logic://tracks/0/regions")
        if isinstance(regions_payload, list):
            region_count = len(regions_payload)

    assessment = evaluate_fresh_session(
        ui=ui,
        health=health,
        project_payload=project_payload,
        tracks_payload=tracks_payload,
        region_count=region_count,
        config=config,
    )

    result = BootstrapResult(
        ok=assessment.ok,
        reason=assessment.reason,
        hint=assessment.hint,
        actions=actions,
        ui=asdict(ui),
        health=health,
        project={
            "source": project_payload.get("source"),
            "data": _project_info_data(project_payload),
        },
        tracks={
            "source": tracks_payload.get("source"),
            "ax_occluded": tracks_payload.get("ax_occluded"),
            "count": len(_track_rows(tracks_payload)),
            "placeholder_count": assessment.placeholder_count,
        },
        regions={"track0_count": region_count},
    )
    return result
