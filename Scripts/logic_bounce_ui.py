#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import time
from ctypes import CDLL, POINTER, Structure, byref, c_bool, c_double, c_int64, c_size_t, c_uint16, c_uint32, c_uint64, c_void_p
from collections.abc import Callable
from typing import Final, Literal, NoReturn, Optional, TypedDict, Union

from logic_ui_jxa import SAVE_PANEL_SNAPSHOT_SOURCE, parse_jxa_json_result, run_jxa


RunJxa = Callable[..., subprocess.CompletedProcess[str]]
RunOsa = Callable[[str, float], str]


OSA_TIMEOUT_SEC: Final = 8.0
BOUNCE_CONFIRM_BUTTONS: Final[tuple[str, str]] = ("OK", "확인")
BOUNCE_DIALOG_KEYWORDS: Final[tuple[str, str]] = ("bounce", "바운스")
BOUNCE_SETTINGS_MARKERS: Final[tuple[str, ...]] = ("pcm", "realtime", "offline", "normalize", "audio tail", "실시간", "오프라인", "노멀라이즈")
SAVE_PANEL_CONFIRM_BUTTONS: Final[tuple[str, str]] = ("bounce", "바운스")
SAVE_PANEL_CANCEL_BUTTONS: Final[tuple[str, str]] = ("cancel", "취소")
SAVE_PANEL_NAME_LABELS: Final[tuple[str, str]] = ("save as:", "다른 이름으로 저장:", "이름으로 저장:")
KCG_HID_EVENT_TAP: Final = 0
KCG_EVENT_LEFT_MOUSE_DOWN: Final = 1
KCG_EVENT_LEFT_MOUSE_UP: Final = 2
KCG_EVENT_KEYBOARD_DOWN: Final = True
KCG_EVENT_KEYBOARD_UP: Final = False
KCG_MOUSE_BUTTON_LEFT: Final = 0
KCG_MOUSE_EVENT_CLICK_STATE: Final = 1
KCG_EVENT_FLAG_MASK_SHIFT: Final = 0x00020000
KCG_EVENT_FLAG_MASK_CONTROL: Final = 0x00040000
KCG_EVENT_FLAG_MASK_ALTERNATE: Final = 0x00080000
KCG_EVENT_FLAG_MASK_COMMAND: Final = 0x00100000
MODIFIER_FLAGS: Final[dict[str, int]] = {
    "cmd": KCG_EVENT_FLAG_MASK_COMMAND,
    "command": KCG_EVENT_FLAG_MASK_COMMAND,
    "shift": KCG_EVENT_FLAG_MASK_SHIFT,
    "alt": KCG_EVENT_FLAG_MASK_ALTERNATE,
    "option": KCG_EVENT_FLAG_MASK_ALTERNATE,
    "ctrl": KCG_EVENT_FLAG_MASK_CONTROL,
    "control": KCG_EVENT_FLAG_MASK_CONTROL,
}
KEY_CODES: Final[dict[str, int]] = {
    "a": 0x00,
    "delete": 0x33,
    "return": 0x24,
    "enter": 0x24,
    "escape": 0x35,
    "esc": 0x35,
    "space": 0x31,
    "tab": 0x30,
}


class SavePanelSnapshotOk(TypedDict):
    status: Literal["ok"]
    button_names: list[str]
    text_field_names: list[str]
    text_field_count: int
    static_texts: list[str]


class SavePanelSnapshotMissingFrontWindow(TypedDict):
    status: Literal["missing_front_window"]


class SavePanelSnapshotErrorBase(TypedDict):
    status: Literal["error"]


class SavePanelSnapshotError(SavePanelSnapshotErrorBase, total=False):
    reason: str
    stderr: str
    stdout: str


SavePanelSnapshot = Union[
    SavePanelSnapshotOk,
    SavePanelSnapshotMissingFrontWindow,
    SavePanelSnapshotError,
]


class BounceFocusDiagnostics(TypedDict):
    frontmost_app: Optional[str]
    logic_front_window: Optional[str]
    logic_front_sheet: Optional[str]
    logic_window_names: list[str]
    save_panel_snapshot: SavePanelSnapshot


class CGPoint(Structure):
    _fields_ = [("x", c_double), ("y", c_double)]


class NativeCGEventDriver:
    def __init__(self) -> None:
        app_services = CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        core_foundation = CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

        self._mouse_event = app_services.CGEventCreateMouseEvent
        self._mouse_event.argtypes = [c_void_p, c_uint32, CGPoint, c_uint32]
        self._mouse_event.restype = c_void_p

        self._keyboard_event = app_services.CGEventCreateKeyboardEvent
        self._keyboard_event.argtypes = [c_void_p, c_uint16, c_bool]
        self._keyboard_event.restype = c_void_p

        self._keyboard_unicode = app_services.CGEventKeyboardSetUnicodeString
        self._keyboard_unicode.argtypes = [c_void_p, c_size_t, POINTER(c_uint16)]
        self._keyboard_unicode.restype = None

        self._set_integer = app_services.CGEventSetIntegerValueField
        self._set_integer.argtypes = [c_void_p, c_uint32, c_int64]
        self._set_integer.restype = None

        self._set_flags = app_services.CGEventSetFlags
        self._set_flags.argtypes = [c_void_p, c_uint64]
        self._set_flags.restype = None

        self._post = app_services.CGEventPost
        self._post.argtypes = [c_uint32, c_void_p]
        self._post.restype = None

        self._release = core_foundation.CFRelease
        self._release.argtypes = [c_void_p]
        self._release.restype = None

        self._held_flags = 0

    def click(self, x: int, y: int) -> bool:
        point = CGPoint(float(x), float(y))
        return self._post_mouse(KCG_EVENT_LEFT_MOUSE_DOWN, point) and self._post_mouse(KCG_EVENT_LEFT_MOUSE_UP, point)

    def key_down(self, key: str) -> bool:
        flag = MODIFIER_FLAGS.get(key.lower())
        if flag is None:
            return self._post_key_name(key, key_down=True)
        self._held_flags |= flag
        return True

    def key_up(self, key: str) -> bool:
        flag = MODIFIER_FLAGS.get(key.lower())
        if flag is None:
            return self._post_key_name(key, key_down=False)
        self._held_flags &= ~flag
        return True

    def key_press(self, key: str) -> bool:
        return self._post_key_name(key, key_down=True) and self._post_key_name(key, key_down=False)

    def reset_modifiers(self) -> None:
        self._held_flags = 0

    def type_text(self, text: str) -> bool:
        for character in text:
            if self._held_flags:
                key_code = KEY_CODES.get(character.lower())
                if key_code is None:
                    return False
                if not self._post_key_code(key_code, key_down=True) or not self._post_key_code(key_code, key_down=False):
                    return False
                continue
            if not self._post_unicode_character(character):
                return False
        return True

    def _post_mouse(self, event_type: int, point: CGPoint) -> bool:
        event = self._mouse_event(None, event_type, point, KCG_MOUSE_BUTTON_LEFT)
        if not event:
            return False
        try:
            self._set_integer(event, KCG_MOUSE_EVENT_CLICK_STATE, 1)
            self._post(KCG_HID_EVENT_TAP, event)
            return True
        finally:
            self._release(event)

    def _post_key_name(self, key: str, *, key_down: bool) -> bool:
        key_code = KEY_CODES.get(key.lower())
        if key_code is None:
            return False
        return self._post_key_code(key_code, key_down=key_down)

    def _post_key_code(self, key_code: int, *, key_down: bool) -> bool:
        event = self._keyboard_event(None, c_uint16(key_code), key_down)
        if not event:
            return False
        try:
            self._set_flags(event, c_uint64(self._held_flags))
            self._post(KCG_HID_EVENT_TAP, event)
            return True
        finally:
            self._release(event)

    def _post_unicode_character(self, character: str) -> bool:
        encoded = character.encode("utf-16-le")
        units = (c_uint16 * (len(encoded) // 2)).from_buffer_copy(encoded)
        down = self._keyboard_event(None, 0, KCG_EVENT_KEYBOARD_DOWN)
        up = self._keyboard_event(None, 0, KCG_EVENT_KEYBOARD_UP)
        if not down or not up:
            if down:
                self._release(down)
            if up:
                self._release(up)
            return False
        try:
            self._keyboard_unicode(down, len(units), units)
            self._keyboard_unicode(up, len(units), units)
            self._post(KCG_HID_EVENT_TAP, down)
            self._post(KCG_HID_EVENT_TAP, up)
            return True
        finally:
            self._release(down)
            self._release(up)


_NATIVE_DRIVER: NativeCGEventDriver | None = None


def _native_driver() -> NativeCGEventDriver:
    global _NATIVE_DRIVER
    if _NATIVE_DRIVER is None:
        _NATIVE_DRIVER = NativeCGEventDriver()
    return _NATIVE_DRIVER


def send_ui_events(*commands: str, driver: NativeCGEventDriver | None = None) -> bool:
    event_driver = driver if driver is not None else _native_driver()
    try:
        for command in commands:
            prefix, separator, payload = command.partition(":")
            if separator != ":":
                return False
            if prefix == "c":
                try:
                    x_raw, y_raw = payload.split(",", 1)
                    if not event_driver.click(int(x_raw), int(y_raw)):
                        return False
                except ValueError:
                    return False
            elif prefix == "kd":
                if not event_driver.key_down(payload):
                    return False
            elif prefix == "ku":
                if not event_driver.key_up(payload):
                    return False
            elif prefix == "kp":
                if not event_driver.key_press(payload):
                    return False
            elif prefix == "t":
                if not event_driver.type_text(payload):
                    return False
            else:
                return False
        return True
    finally:
        event_driver.reset_modifiers()


def osa(script: str, timeout: float = OSA_TIMEOUT_SEC) -> str:
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip()


def _logic_front_container_name(container: str, run_osa: RunOsa = osa) -> str:
    return run_osa(
        f'''
        tell application "System Events"
            tell process "Logic Pro"
                try
                    return name of {container}
                on error
                    return ""
                end try
            end tell
        end tell
        ''',
        OSA_TIMEOUT_SEC,
    ).strip()


def logic_front_window_name(run_osa: RunOsa = osa) -> str: return _logic_front_container_name("front window", run_osa)


def logic_front_sheet_name(run_osa: RunOsa = osa) -> str: return _logic_front_container_name("sheet 1 of front window", run_osa)


def bounce_dialog_present(run_osa: RunOsa = osa) -> bool:
    hay = " ".join(
        name.lower()
        for name in (logic_front_window_name(run_osa), logic_front_sheet_name(run_osa))
        if name
    )
    return any(keyword in hay for keyword in BOUNCE_DIALOG_KEYWORDS)


def _string_items(values) -> list[str]:
    if isinstance(values, list):
        return [value.strip() for value in values if isinstance(value, str) and value.strip()]
    return []


def _unreachable_status(status: str) -> NoReturn: raise AssertionError(f"unexpected snapshot status: {status}")


def _coerce_save_panel_snapshot(raw_snapshot) -> SavePanelSnapshot:
    if not isinstance(raw_snapshot, dict):
        return {"status": "error", "reason": "invalid_snapshot_payload"}

    status = raw_snapshot.get("status")
    if status == "ok":
        text_field_count = raw_snapshot.get("text_field_count")
        return {
            "status": "ok",
            "button_names": _string_items(raw_snapshot.get("button_names")),
            "text_field_names": _string_items(raw_snapshot.get("text_field_names")),
            "text_field_count": text_field_count if isinstance(text_field_count, int) else 0,
            "static_texts": _string_items(raw_snapshot.get("static_texts")),
        }
    if status == "missing_front_window":
        return {"status": "missing_front_window"}
    if status == "error":
        snapshot: SavePanelSnapshotError = {"status": "error"}
        reason = raw_snapshot.get("reason")
        stderr = raw_snapshot.get("stderr")
        stdout = raw_snapshot.get("stdout")
        if isinstance(reason, str) and reason:
            snapshot["reason"] = reason
        if isinstance(stderr, str) and stderr:
            snapshot["stderr"] = stderr
        if isinstance(stdout, str) and stdout:
            snapshot["stdout"] = stdout
        return snapshot
    return {"status": "error", "reason": "invalid_snapshot_payload"}


def save_panel_snapshot(run_jxa_fn: RunJxa = run_jxa) -> SavePanelSnapshot:
    try:
        result = run_jxa_fn(SAVE_PANEL_SNAPSHOT_SOURCE)
    except (FileNotFoundError, subprocess.TimeoutExpired) as error:
        return {"status": "error", "reason": "jxa_probe_failed", "stderr": str(error)}
    return _coerce_save_panel_snapshot(parse_jxa_json_result(result))


def _normalized_strings(values: list[str]) -> list[str]:
    return [value.lower() for value in values]


def save_panel_present(run_jxa_fn: RunJxa = run_jxa) -> bool:
    snapshot = save_panel_snapshot(run_jxa_fn=run_jxa_fn)
    status = snapshot["status"]
    if status == "ok":
        button_names, text_field_names, static_texts, has_text_field = _snapshot_parts(snapshot)
        has_confirm = any(label in button_names for label in SAVE_PANEL_CONFIRM_BUTTONS)
        has_cancel = any(label in button_names for label in SAVE_PANEL_CANCEL_BUTTONS)
        save_name_labels = text_field_names + static_texts
        has_save_name_label = any(
            any(label == value for label in SAVE_PANEL_NAME_LABELS)
            for value in save_name_labels
        )
        return has_text_field and has_confirm and has_cancel and has_save_name_label
    if status == "error" or status == "missing_front_window":
        return False
    return _unreachable_status(status)


def _snapshot_parts(snapshot: SavePanelSnapshotOk) -> tuple[list[str], list[str], list[str], bool]:
    button_names = _normalized_strings(snapshot["button_names"])
    text_field_names = _normalized_strings(snapshot["text_field_names"])
    static_texts = _normalized_strings(snapshot["static_texts"])
    return button_names, text_field_names, static_texts, bool(text_field_names) or snapshot["text_field_count"] > 0


def bounce_settings_present(run_jxa_fn: RunJxa = run_jxa) -> bool:
    snapshot = save_panel_snapshot(run_jxa_fn=run_jxa_fn)
    status = snapshot["status"]
    if status == "ok":
        button_names, _, static_texts, has_text_field = _snapshot_parts(snapshot)
        has_confirm = any(label.lower() in button_names for label in BOUNCE_CONFIRM_BUTTONS)
        has_cancel = any(label in button_names for label in SAVE_PANEL_CANCEL_BUTTONS)
        has_marker = any(any(marker in text for marker in BOUNCE_SETTINGS_MARKERS) for text in static_texts)
        return not has_text_field and has_confirm and has_cancel and has_marker
    if status == "error" or status == "missing_front_window":
        return False
    return _unreachable_status(status)


def wait_for_bounce_dialog(run_osa: RunOsa = osa, sleep_fn: Callable[[float], None] = time.sleep) -> bool:
    for _ in range(10):
        if bounce_dialog_present(run_osa):
            return True
        sleep_fn(0.5)
    return False


def open_bounce_dialog_via_menu(run_osa: RunOsa = osa) -> bool:
    result = run_osa(
        '''
        tell application "System Events"
            tell process "Logic Pro"
                set frontmost to true
                try
                    click menu item 1 of menu 1 of menu item "바운스" of menu 1 of menu bar item "파일" of menu bar 1
                    return "ok"
                on error
                    try
                        click menu item 1 of menu 1 of menu item "Bounce" of menu 1 of menu bar item "File" of menu bar 1
                        return "ok"
                    on error
                        return ""
                    end try
                end try
            end tell
        end tell
        ''',
        OSA_TIMEOUT_SEC,
    )
    return result == "ok"


def bounce_focus_diagnostics(
    run_osa: RunOsa = osa,
    run_jxa_fn: RunJxa = run_jxa,
) -> BounceFocusDiagnostics:
    logic_window_names = run_osa(
        '''
        tell application "System Events"
            tell process "Logic Pro"
                try
                    set AppleScript's text item delimiters to linefeed
                    return name of windows as text
                on error
                    return ""
                end try
            end tell
        end tell
        ''',
        OSA_TIMEOUT_SEC,
    )
    frontmost_app = run_osa(
        '''
        tell application "System Events"
            try
                return name of first application process whose frontmost is true
            on error
                return ""
            end try
        end tell
        ''',
        OSA_TIMEOUT_SEC,
    ).strip()
    return {
        "frontmost_app": frontmost_app or None,
        "logic_front_window": logic_front_window_name(run_osa) or None,
        "logic_front_sheet": logic_front_sheet_name(run_osa) or None,
        "logic_window_names": [name for name in logic_window_names.splitlines() if name.strip()],
        "save_panel_snapshot": save_panel_snapshot(run_jxa_fn=run_jxa_fn),
    }


def open_bounce_dialog(run_osa: RunOsa = osa, sleep_fn: Callable[[float], None] = time.sleep) -> tuple[bool, list[str]]:
    strategies = ["key_command"]
    run_osa('tell application "Logic Pro" to activate')
    sleep_fn(0.8)
    run_osa('tell application "System Events" to tell process "Logic Pro" to key code 11 using {command down}')
    if wait_for_bounce_dialog(run_osa=run_osa, sleep_fn=sleep_fn):
        return True, strategies
    strategies.append("file_menu")
    if open_bounce_dialog_via_menu(run_osa) and wait_for_bounce_dialog(run_osa=run_osa, sleep_fn=sleep_fn):
        return True, strategies
    return False, strategies


def click_bounce_settings_confirm(
    labels: tuple[str, ...] = BOUNCE_CONFIRM_BUTTONS,
    run_osa: RunOsa = osa,
    run_jxa_fn: RunJxa = run_jxa,
) -> bool:
    if not bounce_settings_present(run_jxa_fn=run_jxa_fn):
        return False
    for container in ("sheet 1 of front window", "front window"):
        for label in labels:
            if not bounce_settings_present(run_jxa_fn=run_jxa_fn):
                return False
            result = run_osa(
                f'''
                tell application "System Events"
                    tell process "Logic Pro"
                        try
                            click button "{label}" of {container}
                            return "ok"
                        on error
                            return ""
                        end try
                    end tell
                end tell
                ''',
                OSA_TIMEOUT_SEC,
            )
            if result == "ok":
                return True
    return False
