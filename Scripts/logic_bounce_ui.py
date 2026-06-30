#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import subprocess
import time
from collections.abc import Callable
from typing import Final, Literal, NamedTuple, NoReturn, Optional, TypedDict, Union

from logic_ui_jxa import SAVE_PANEL_SNAPSHOT_SOURCE, parse_jxa_json_result, run_jxa


RunJxa = Callable[..., subprocess.CompletedProcess[str]]
RunOsa = Callable[[str, float], str]


OSA_TIMEOUT_SEC: Final = 8.0
CLICLICK_TIMEOUT_SEC: Final = 3.0
BOUNCE_CONFIRM_BUTTONS: Final[tuple[str, str]] = ("OK", "확인")
BOUNCE_DIALOG_KEYWORDS: Final[tuple[str, str]] = ("bounce", "바운스")
BOUNCE_SETTINGS_MARKERS: Final[tuple[str, ...]] = ("pcm", "realtime", "offline", "normalize", "audio tail", "실시간", "오프라인", "노멀라이즈")
SAVE_PANEL_CONFIRM_BUTTONS: Final[tuple[str, str]] = ("bounce", "바운스")
SAVE_PANEL_CANCEL_BUTTONS: Final[tuple[str, str]] = ("cancel", "취소")
SAVE_PANEL_NAME_LABELS: Final[tuple[str, str]] = ("save as:", "다른 이름으로 저장:", "이름으로 저장:")
TRUSTED_CLICLICK_DIRS: Final[tuple[str, ...]] = ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin")
TRUSTED_CLICLICK_CANDIDATES: Final[tuple[str, ...]] = (
    "/opt/homebrew/bin/cliclick",
    "/usr/local/bin/cliclick",
    "/usr/bin/cliclick",
)


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


# cliclick trust model (issue #210) — MUST stay in parity with the Swift resolver
# (ProjectExportExecutorBounceHelperResolution.swift) and the live-e2e mirror.
# Reason vocabulary is identical across all three implementations.
R_RESOLVED: Final = "resolved"
R_NOT_ABSOLUTE: Final = "not_absolute"
R_NOT_FOUND: Final = "not_found"
R_NOT_EXECUTABLE: Final = "not_executable"
R_PARENT_WRITABLE: Final = "parent_writable"
R_FILE_WRITABLE: Final = "file_writable"
R_OWNER_UNTRUSTED: Final = "owner_untrusted"
R_ANCESTOR_WRITABLE: Final = "ancestor_writable"
R_SHA256_MISMATCH: Final = "sha256_mismatch"


class CliclickCandidate(NamedTuple):
    path: str
    source: str  # "override" | "canonical"
    reason: str


class CliclickResolution(NamedTuple):
    resolved_path: Optional[str]
    candidates: list[CliclickCandidate]

    def diagnostic_summary(self) -> str:
        tried = (
            ", ".join(f"{c.path}={c.reason}" for c in self.candidates)
            if self.candidates
            else "no candidates"
        )
        return (
            f"tried: {tried}; fix: run `chmod g-w /opt/homebrew/bin` so the canonical cliclick "
            "resolves (note: its symlink target under /opt/homebrew/Cellar stays group-writable, so it "
            "remains swappable by admin-group users — for full isolation copy cliclick to a non-writable "
            "dir and set LOGIC_PRO_MCP_CLICLICK to it, optionally with LOGIC_PRO_MCP_CLICLICK_SHA256). "
            "See docs/SETUP.md#doctor-dependenciescliclick."
        )


def _trusted_owner(uid: int) -> bool:
    return uid == 0 or uid == os.getuid()


def _sha256_of(path: str) -> Optional[str]:
    try:
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def _validate_ancestry(real: str) -> Optional[str]:
    # Walk immediate parent … "/" inclusive. Any group/world-writable, non-{root,self}-owned,
    # or unreadable ancestor is untrusted (fail-closed).
    current = os.path.dirname(real)
    while True:
        try:
            stat_result = os.stat(current)
        except OSError:
            return R_ANCESTOR_WRITABLE
        if stat_result.st_mode & 0o022:
            return R_ANCESTOR_WRITABLE
        if not _trusted_owner(stat_result.st_uid):
            return R_ANCESTOR_WRITABLE
        parent = os.path.dirname(current)
        if parent == current:  # reached "/"
            break
        current = parent
    return None


def _evaluate_canonical(path: str) -> str:
    # Shipped rule (NG1): immediate-parent non-writable, NO symlink resolution.
    normalized = os.path.abspath(os.path.expanduser(path))
    parent = os.path.dirname(normalized)
    try:
        parent_mode = os.stat(parent).st_mode
    except OSError:
        return R_NOT_FOUND
    if parent_mode & 0o022:
        return R_PARENT_WRITABLE
    if not os.path.isfile(normalized):
        return R_NOT_FOUND
    if not os.access(normalized, os.X_OK):
        return R_NOT_EXECUTABLE
    return R_RESOLVED


def _evaluate_arbitrary(path: str, environ: "os._Environ[str] | dict[str, str]") -> tuple[str, Optional[str]]:
    # Strict, symlink-resolved, fail-closed. Returns (reason, resolved_real_path_or_None).
    trimmed = (path or "").strip()
    if not trimmed or "\0" in trimmed:
        return (R_NOT_FOUND, None)
    expanded = os.path.expanduser(trimmed)
    if not expanded.startswith("/"):
        return (R_NOT_ABSOLUTE, None)
    real = os.path.realpath(expanded)  # follows symlinks; does NOT raise on missing
    if not os.path.isfile(real):  # explicit existence check (realpath won't raise)
        return (R_NOT_FOUND, None)
    if not os.access(real, os.X_OK):
        return (R_NOT_EXECUTABLE, None)
    try:
        stat_result = os.stat(real)  # os.stat follows to the real file (NOT lstat)
    except OSError:
        return (R_NOT_FOUND, None)
    if stat_result.st_mode & 0o022:
        return (R_FILE_WRITABLE, None)
    if not _trusted_owner(stat_result.st_uid):
        return (R_OWNER_UNTRUSTED, None)
    ancestor_reason = _validate_ancestry(real)
    if ancestor_reason is not None:
        return (ancestor_reason, None)
    if "LOGIC_PRO_MCP_CLICLICK_SHA256" in environ:
        pin = environ["LOGIC_PRO_MCP_CLICLICK_SHA256"].strip().lower()
        actual = _sha256_of(real)
        if len(pin) != 64 or any(c not in "0123456789abcdef" for c in pin) or actual is None or actual != pin:
            return (R_SHA256_MISMATCH, None)
    return (R_RESOLVED, real)


def _classify_and_validate(
    path: str,
    environ: "os._Environ[str] | dict[str, str]",
) -> tuple[str, Optional[str]]:
    # Location classification (mirrors how the Swift side accepted a path): a canonical
    # path uses the canonical rule (no symlink follow); anything else is strict-arbitrary.
    normalized = os.path.abspath(os.path.expanduser(path)) if path else ""
    if normalized in TRUSTED_CLICLICK_CANDIDATES:
        reason = _evaluate_canonical(normalized)
        return (reason, normalized if reason == R_RESOLVED else None)
    return _evaluate_arbitrary(path, environ)


def cliclick_resolution(
    override: str | None = None,
    environ: "os._Environ[str] | dict[str, str] | None" = None,
) -> CliclickResolution:
    environ = os.environ if environ is None else environ
    candidates: list[CliclickCandidate] = []

    # 1) Explicit override arg (the --cliclick-path the Swift side already resolved) —
    #    validated by LOCATION classification so it matches Swift's accept decision exactly.
    if override and override.strip():
        reason, resolved = _classify_and_validate(override, environ)
        candidates.append(CliclickCandidate(os.path.abspath(os.path.expanduser(override)), "override", reason))
        if reason == R_RESOLVED and resolved is not None:
            return CliclickResolution(resolved, candidates)

    # 2) Operator env override (LOGIC_PRO_MCP_CLICLICK) — ALWAYS strict-arbitrary.
    env_override = environ.get("LOGIC_PRO_MCP_CLICLICK")
    if env_override and env_override.strip():
        reason, resolved = _evaluate_arbitrary(env_override, environ)
        candidates.append(CliclickCandidate(os.path.abspath(os.path.expanduser(env_override)), "override", reason))
        if reason == R_RESOLVED and resolved is not None:
            return CliclickResolution(resolved, candidates)

    # 3) Canonical candidates — shipped rule.
    for canonical in TRUSTED_CLICLICK_CANDIDATES:
        reason = _evaluate_canonical(canonical)
        candidates.append(CliclickCandidate(canonical, "canonical", reason))
        if reason == R_RESOLVED:
            return CliclickResolution(canonical, candidates)

    return CliclickResolution(None, candidates)


def trusted_cliclick_path(override: str | None = None) -> str | None:
    # Back-compat thin wrapper.
    return cliclick_resolution(override).resolved_path


# Resolve-once cache (issue #210 / R5): logic_bounce.py main validates the cliclick path once
# and records it here so per-click cliclick() calls do NOT re-resolve (closes the TOCTOU window
# multiplied by per-click re-resolution).
_RESOLVED_CLICLICK: Optional[str] = None


def set_resolved_cliclick(path: Optional[str]) -> None:
    global _RESOLVED_CLICLICK
    _RESOLVED_CLICLICK = path


def cliclick(*args: str) -> bool:
    executable = _RESOLVED_CLICLICK if _RESOLVED_CLICLICK is not None else trusted_cliclick_path()
    if executable is None:
        return False
    try:
        result = subprocess.run(
            [executable, *args],
            capture_output=True,
            text=True,
            timeout=CLICLICK_TIMEOUT_SEC,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


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
