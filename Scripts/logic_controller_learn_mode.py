#!/usr/bin/env python3
"""Detect Logic Pro Controller Assignments Learn Mode before live MIDI QA."""

from __future__ import annotations

import json
import subprocess
import sys
from copy import deepcopy
from typing import Any

from logic_ui_jxa import parse_jxa_json_result, run_jxa, ui_prelude
from logic_variants import jxa_find_process_snippet

DEFAULT_CONTROLLER_LEARN_MODE_POLICY: dict[str, Any] = {
    "policy_id": "controller_assignments_learn_mode_guard",
    "candidate_markers": [
        "Controller Assignments",
        "Control Surfaces",
        "Learn Mode",
        "This control is already assigned",
        "already assigned",
        "컨트롤러 할당",
        "컨트롤 표면",
        "학습 모드",
        "이미 할당",
    ],
    "assignment_prompt_markers": [
        "This control is already assigned",
        "already assigned",
        "assigned to another parameter",
        "control is assigned",
        "이미 할당",
    ],
    "learn_mode_markers": [
        "Learn Mode",
        "학습 모드",
    ],
}


def _normalize_label(value: Any) -> str:
    return " ".join(str(value).replace("…", "...").replace("\u00a0", " ").split()).casefold()


def _is_truthy(value: Any) -> bool:
    return _normalize_label(value) in {"1", "true", "yes", "on", "selected", "checked"}


def _marker_matches(value: Any, markers: list[str]) -> bool:
    normalized = _normalize_label(value)
    return any(_normalize_label(marker) in normalized for marker in markers)


def _list_values(snapshot: dict[str, Any], key: str) -> list[Any]:
    value = snapshot.get(key, [])
    return value if isinstance(value, list) else []


def _snapshot_labels(snapshot: dict[str, Any]) -> list[str]:
    labels: list[str] = []
    title = snapshot.get("title")
    if isinstance(title, str) and title:
        labels.append(title)
    for key in ("static_texts", "buttons", "menu_items"):
        for item in _list_values(snapshot, key):
            if isinstance(item, str) and item:
                labels.append(item)
            elif isinstance(item, dict) and isinstance(item.get("name"), str):
                labels.append(item["name"])
    for control in _snapshot_controls(snapshot):
        name = control.get("name")
        if isinstance(name, str) and name:
            labels.append(name)
    return labels


def _snapshot_controls(snapshot: dict[str, Any]) -> list[dict[str, Any]]:
    controls: list[dict[str, Any]] = []
    for key in ("checkboxes", "radio_buttons", "controls"):
        for item in _list_values(snapshot, key):
            if isinstance(item, str):
                controls.append({"name": item, "value": ""})
            elif isinstance(item, dict) and isinstance(item.get("name"), str):
                controls.append(item)
    return controls


def classify_controller_learn_mode(
    snapshot: dict[str, Any],
    policy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    active_policy = deepcopy(policy or DEFAULT_CONTROLLER_LEARN_MODE_POLICY)
    status = snapshot.get("status", "error")
    base: dict[str, Any] = {"policy_id": active_policy["policy_id"]}

    if status in {"not_present", "inactive"}:
        return {**base, "status": "inactive", "reason": status}
    if status == "error":
        result = {**base, "status": "error", "reason": snapshot.get("reason", "detect_error")}
        if snapshot.get("stderr"):
            result["stderr"] = snapshot["stderr"]
        return result

    labels = _snapshot_labels(snapshot)
    prompt_labels = [
        label for label in labels
        if _marker_matches(label, active_policy["assignment_prompt_markers"])
    ]
    if status == "active" or prompt_labels:
        return {
            **base,
            "status": "active",
            "reason": snapshot.get("reason", "assignment_prompt_present"),
            "evidence": {
                "labels": prompt_labels or labels,
                "title": snapshot.get("title", ""),
            },
        }

    for control in _snapshot_controls(snapshot):
        if _marker_matches(control.get("name", ""), active_policy["learn_mode_markers"]) and _is_truthy(
            control.get("value", "")
        ):
            return {
                **base,
                "status": "active",
                "reason": "learn_mode_enabled",
                "evidence": {
                    "control": control,
                    "labels": labels,
                    "title": snapshot.get("title", ""),
                },
            }

    return {
        **base,
        "status": "inactive",
        "reason": "no_active_learn_mode_evidence",
        "evidence": {
            "labels": labels,
            "controls": _snapshot_controls(snapshot),
            "title": snapshot.get("title", ""),
        },
    }


class SystemEventsControllerLearnModeRunner:
    """Read Logic's Controller Assignments UI via System Events JXA."""

    def __init__(
        self,
        policy: dict[str, Any] | None = None,
        run=subprocess.run,
    ) -> None:
        self.policy = deepcopy(policy or DEFAULT_CONTROLLER_LEARN_MODE_POLICY)
        self._run = run

    def _osascript(self, source: str, timeout: float = 12.0) -> subprocess.CompletedProcess[str]:
        return run_jxa(source, timeout=timeout, run=self._run)

    def _jxa_source(self) -> str:
        find_process = jxa_find_process_snippet(se_binding="systemEvents", proc_var="process")
        return ui_prelude(
            marker_constant="CANDIDATE_MARKERS",
            markers=self.policy["candidate_markers"],
            include_menu_items=True,
        ) + f"""
function snapshot(container, kind, title) {{
  return {{
    status: "present",
    kind,
    title,
    buttons: namesOf(collection(container, "button")),
    checkboxes: namedStates(collection(container, "checkbox")),
    radio_buttons: namedStates(collection(container, "radio button")),
    static_texts: namesOf(collection(container, "static text")),
    menu_items: namesOf(collection(container, "menu item")),
  }};
}}

function labelsFor(candidate) {{
  return [candidate.title].concat(
    candidate.buttons,
    candidate.static_texts,
    candidate.menu_items,
    candidate.checkboxes.map((item) => item.name),
    candidate.radio_buttons.map((item) => item.name)
  );
}}

function findCandidate() {{
  const systemEvents = Application("System Events");
  {find_process}
  if (process === null) return {{ status: "not_present", reason: "logic_not_running" }};
  if (!safe(() => process.exists(), false)) return {{ status: "not_present", reason: "logic_not_running" }};
  const windows = safe(() => process.windows(), []);
  for (let windowIndex = 0; windowIndex < windows.length; windowIndex += 1) {{
    const win = windows[windowIndex];
    const title = str(safe(() => win.name(), ""));
    const sheets = safe(() => win.sheets(), []);
    for (let sheetIndex = 0; sheetIndex < sheets.length; sheetIndex += 1) {{
      const sheet = sheets[sheetIndex];
      const sheetTitle = str(safe(() => sheet.name(), title)) || title;
      const sheetSnapshot = snapshot(sheet, "sheet", sheetTitle);
      if (containsMarker(labelsFor(sheetSnapshot))) return sheetSnapshot;
    }}

    const windowSnapshot = snapshot(win, "window", title);
    if (containsMarker(labelsFor(windowSnapshot))) return windowSnapshot;
  }}
  return {{ status: "not_present" }};
}}

JSON.stringify(findCandidate());
"""

    def _json_result(self, result: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        return parse_jxa_json_result(result)

    def detect(self) -> dict[str, Any]:
        try:
            result = self._osascript(self._jxa_source())
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            return {"status": "error", "reason": "osascript_failed", "stderr": str(error)}
        if result.returncode != 0:
            return {
                "status": "error",
                "reason": "osascript_failed",
                "stderr": (result.stderr or "").strip(),
            }
        return self._json_result(result)


def detect_controller_learn_mode(
    runner: SystemEventsControllerLearnModeRunner | None = None,
    policy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    active_policy = deepcopy(policy or DEFAULT_CONTROLLER_LEARN_MODE_POLICY)
    snapshot = (runner or SystemEventsControllerLearnModeRunner(active_policy)).detect()
    classified = classify_controller_learn_mode(snapshot, active_policy)
    classified["snapshot"] = snapshot
    return classified


def guard_controller_learn_mode(
    runner: SystemEventsControllerLearnModeRunner | None = None,
    policy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    active_policy = deepcopy(policy or DEFAULT_CONTROLLER_LEARN_MODE_POLICY)
    snapshot = (runner or SystemEventsControllerLearnModeRunner(active_policy)).detect()
    classified = classify_controller_learn_mode(snapshot, active_policy)
    result: dict[str, Any] = {
        "policy_id": active_policy["policy_id"],
        "before": snapshot,
        "classification": classified,
        "human_intervention_required": False,
        "human_intervention_requests": 0,
        "human_dependent_transitions": 0,
        "write_attempted": False,
    }

    if classified.get("status") == "inactive":
        result["status"] = "clear"
        result["reason"] = classified.get("reason", "inactive")
        result["terminal"] = False
    elif classified.get("status") == "active":
        result["status"] = "failed"
        result["reason"] = classified.get("reason", "active")
        result["terminal"] = True
        result["terminal_scope"] = "mcp_request_only"
        result["safe_to_retry"] = False
        if isinstance(classified.get("evidence"), dict):
            result["evidence"] = classified["evidence"]
    else:
        result["status"] = "failed"
        result["reason"] = classified.get("reason", "detect_error")
        result["terminal"] = True
        result["terminal_scope"] = "mcp_request_only"
        result["safe_to_retry"] = False
        if classified.get("stderr"):
            result["stderr"] = classified["stderr"]
    return result


def _main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "guard"
    if command == "detect":
        payload = detect_controller_learn_mode()
    elif command == "guard":
        payload = guard_controller_learn_mode()
    else:
        print("usage: logic_controller_learn_mode.py [detect|guard]", file=sys.stderr)
        return 2
    successful = payload.get("status") in {"clear", "inactive"}
    payload = dict(payload)
    payload.setdefault("human_intervention_required", False)
    payload.setdefault("human_intervention_requests", 0)
    payload.setdefault("human_dependent_transitions", 0)
    payload.setdefault("write_attempted", False)
    if successful:
        payload.setdefault("terminal", False)
    else:
        prior_status = payload.get("status", "unknown")
        if prior_status != "failed":
            payload["classification_status"] = prior_status
            payload["status"] = "failed"
        payload.setdefault("terminal", True)
        payload.setdefault("terminal_scope", "mcp_request_only")
        payload.setdefault("safe_to_retry", False)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if successful else 1


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
