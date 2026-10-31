#!/usr/bin/env python3
# noqa: SIZE_OK  — modal policy matching and JXA interaction stay co-located for one audited live Logic guard.
"""Detect and deterministically resolve Logic Pro's Free Tempo Recording modal."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from copy import deepcopy
from typing import Any

from logic_ui_jxa import parse_jxa_json_result, run_jxa, ui_prelude
from logic_variants import jxa_find_process_snippet

MODAL_MARKERS = (
    "Free Tempo Recording",
    "프리 템포 녹음",
    "analyze region tempo",
    "project tempo",
    "Don't show again",
    "리전 템포",
    "프로젝트 템포",
    "다시 표시 안 함",
)

DEFAULT_FREE_TEMPO_POLICY: dict[str, Any] = {
    "policy_id": "keep_project_tempo_no_analysis",
    "selection_labels": [
        "Don't analyze region tempo or change project tempo",
        "리전 템포를 분석하거나 프로젝트 템포를 변경하지 않음",
    ],
    "selection_fragment_sets": [
        ("don't analyze region tempo", "change project tempo"),
        ("리전 템포", "프로젝트 템포", "변경하지 않음"),
    ],
    "suppress_future_prompt_labels": ["Don't show again", "다시 표시 안 함"],
    "confirm_button_labels": ["OK", "Done", "Confirm", "Continue", "확인"],
}


def _with_local_terminal_receipt(payload: dict[str, Any]) -> dict[str, Any]:
    result = dict(payload)
    result["terminal"] = result.get("status") in {"blocked", "error"}
    result["human_intervention_required"] = False
    result["human_intervention_requests"] = 0
    result["human_dependent_transitions"] = 0
    if "write_attempted" not in result:
        actions = result.get("actions")
        if isinstance(actions, list) and actions:
            attempt_evidence = [
                action.get("write_attempted")
                for action in actions
                if isinstance(action, dict) and isinstance(action.get("write_attempted"), bool)
            ]
            if any(attempt_evidence):
                result["write_attempted"] = True
            elif len(attempt_evidence) == len(actions):
                result["write_attempted"] = False
        elif not actions:
            result["write_attempted"] = False
    return result


def _normalize_label(value: str) -> str:
    return " ".join(value.replace("…", "...").replace("\u00a0", " ").split()).casefold()


def _is_truthy(value: str) -> bool:
    return _normalize_label(str(value)) in {"1", "true", "yes", "on", "selected"}


def _match_named_control(
    items: list[Any],
    exact_labels: list[str],
    fragment_sets: list[tuple[str, ...]] | None = None,
) -> dict[str, Any] | None:
    fragment_sets = fragment_sets or []
    normalized_exact = {_normalize_label(label): label for label in exact_labels}
    named_items: list[dict[str, Any]] = []
    for item in items:
        if isinstance(item, str):
            named_items.append({"name": item})
        elif isinstance(item, dict) and isinstance(item.get("name"), str):
            named_items.append(item)

    for item in named_items:
        normalized_name = _normalize_label(item["name"])
        if normalized_name in normalized_exact:
            return item

    for item in named_items:
        normalized_name = _normalize_label(item["name"])
        for fragments in fragment_sets:
            if all(fragment in normalized_name for fragment in fragments):
                return item
    return None


def _build_action_plan(snapshot: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    decision: dict[str, Any] = {"policy_id": policy["policy_id"]}
    steps: list[dict[str, Any]] = []

    selection = _match_named_control(
        snapshot.get("radio_buttons", []),
        policy.get("selection_labels", []),
        policy.get("selection_fragment_sets", []),
    )
    selection_role = "radio button"
    if selection is None:
        selection = _match_named_control(
            snapshot.get("checkboxes", []),
            policy.get("selection_labels", []),
            policy.get("selection_fragment_sets", []),
        )
        selection_role = "checkbox"
    if selection is None:
        selection = _match_named_control(
            snapshot.get("buttons", []),
            policy.get("selection_labels", []),
            policy.get("selection_fragment_sets", []),
        )
        selection_role = "button"
    if selection is None:
        return {
            "status": "blocked",
            "reason": "selection_control_missing",
            "decision": decision,
        }

    decision["selection"] = selection["name"]
    decision["selection_role"] = selection_role
    selection_value = selection.get("value", "")
    decision["selection_already_active"] = _is_truthy(selection_value)
    if selection_role != "button" and not decision["selection_already_active"]:
        steps.append(
            {
                "role": selection_role,
                "name": selection["name"],
                "purpose": "select_keep_project_tempo_no_analysis",
            }
        )

    suppress_checkbox = _match_named_control(
        snapshot.get("checkboxes", []),
        policy.get("suppress_future_prompt_labels", []),
    )
    if suppress_checkbox is None:
        decision["suppress_future_prompts"] = "checkbox_unavailable"
    elif _is_truthy(suppress_checkbox.get("value", "")):
        decision["suppress_future_prompts"] = "already_enabled"
    else:
        decision["suppress_future_prompts"] = "requested"
        steps.append(
            {
                "role": "checkbox",
                "name": suppress_checkbox["name"],
                "purpose": "suppress_future_prompt",
            }
        )

    if selection_role == "button":
        decision["confirm"] = selection["name"]
        decision["confirm_strategy"] = "selection_button"
        steps.append(
            {
                "role": "button",
                "name": selection["name"],
                "purpose": "confirm_modal_policy",
            }
        )
        return {"status": "actionable", "decision": decision, "steps": steps}

    confirm_button = _match_named_control(
        snapshot.get("buttons", []),
        policy.get("confirm_button_labels", []),
    )
    if confirm_button is None:
        buttons = snapshot.get("buttons", [])
        if len(buttons) == 1:
            confirm_button = {"name": buttons[0]}
            decision["confirm_strategy"] = "single_button_fallback"
        else:
            return {
                "status": "blocked",
                "reason": "confirm_button_missing",
                "decision": decision,
            }
    else:
        decision["confirm_strategy"] = "named_button"

    decision["confirm"] = confirm_button["name"]
    steps.append(
        {
            "role": "button",
            "name": confirm_button["name"],
            "purpose": "confirm_modal_policy",
        }
    )
    return {"status": "actionable", "decision": decision, "steps": steps}


class SystemEventsFreeTempoModalRunner:
    """Drive Logic's modal via System Events osascript UI scripting."""

    def __init__(
        self,
        markers: tuple[str, ...] = MODAL_MARKERS,
        run=subprocess.run,
    ) -> None:
        self.markers = markers
        self._run = run

    def _osascript(self, source: str, timeout: float = 12.0) -> subprocess.CompletedProcess[str]:
        return run_jxa(source, timeout=timeout, run=self._run)

    def _jxa_prelude(self) -> str:
        find_process = jxa_find_process_snippet(se_binding="systemEvents", proc_var="process")
        return ui_prelude(marker_constant="MODAL_MARKERS", markers=self.markers) + f"""
function findModal() {{
  const systemEvents = Application("System Events");
  {find_process}
  if (process === null) return null;
  if (!safe(() => process.exists(), false)) return null;
  const windows = safe(() => process.windows(), []);
  for (let windowIndex = 0; windowIndex < windows.length; windowIndex += 1) {{
    const win = windows[windowIndex];
    const title = str(safe(() => win.name(), ""));
    if (containsMarker([title])) {{
      return {{ kind: "window", title, container: win }};
    }}

    const sheets = safe(() => win.sheets(), []);
    for (let sheetIndex = 0; sheetIndex < sheets.length; sheetIndex += 1) {{
      const sheet = sheets[sheetIndex];
      const labels = [title].concat(
        namesOf(collection(sheet, "static text")),
        namesOf(collection(sheet, "button")),
        namesOf(collection(sheet, "checkbox")),
        namesOf(collection(sheet, "radio button"))
      );
      if (containsMarker(labels)) {{
        const sheetTitle = str(safe(() => sheet.name(), title)) || title;
        return {{ kind: "sheet", title: sheetTitle, container: sheet }};
      }}
    }}

    const windowLabels = [title].concat(
      namesOf(collection(win, "static text")),
      namesOf(collection(win, "button")),
      namesOf(collection(win, "checkbox")),
      namesOf(collection(win, "radio button"))
    );
    if (containsMarker(windowLabels)) {{
      return {{ kind: "window", title, container: win }};
    }}
  }}
  return null;
}}
"""

    def _json_result(self, result: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        return parse_jxa_json_result(result)

    def detect(self) -> dict[str, Any]:
        script = self._jxa_prelude() + """
const target = findModal();
if (!target) {
  JSON.stringify({ status: "not_present" });
} else {
  JSON.stringify({
    status: "present",
    kind: target.kind,
    title: target.title,
    buttons: namesOf(collection(target.container, "button")),
    checkboxes: namedStates(collection(target.container, "checkbox")),
    radio_buttons: namedStates(collection(target.container, "radio button")),
    static_texts: namesOf(collection(target.container, "static text")),
  });
}
"""
        try:
            result = self._osascript(script)
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            return {"status": "error", "reason": "osascript_failed", "stderr": str(error)}
        if result.returncode != 0:
            return {
                "status": "error",
                "reason": "osascript_failed",
                "stderr": (result.stderr or "").strip(),
            }
        return self._json_result(result)

    def click(self, role: str, name: str) -> dict[str, Any]:
        script = self._jxa_prelude() + f"""
const targetRole = {json.dumps(role, ensure_ascii=False)};
const targetName = {json.dumps(name, ensure_ascii=False)};
const target = findModal();

if (!target) {{
  JSON.stringify({{ status: "not_present", write_attempted: false }});
}} else {{
  const candidates = collection(target.container, targetRole);
  let matched = null;
  for (let index = 0; index < candidates.length; index += 1) {{
    if (safeName(candidates[index]) === targetName) {{
      matched = candidates[index];
      break;
    }}
  }}

  if (!matched) {{
    JSON.stringify({{ status: "error", message: "control not found", write_attempted: false }});
  }} else {{
    try {{
      matched.click();
      JSON.stringify({{ status: "clicked", write_attempted: true }});
    }} catch (clickError) {{
      try {{
        const actions = safe(() => matched.actions(), []);
        if (actions.length > 0) {{
          actions[0].perform();
          JSON.stringify({{ status: "clicked", write_attempted: true }});
        }} else {{
          JSON.stringify({{ status: "error", message: str(clickError), write_attempted: true }});
        }}
      }} catch (fallbackError) {{
        JSON.stringify({{ status: "error", message: str(fallbackError), write_attempted: true }});
      }}
    }}
  }}
}}
"""
        try:
            result = self._osascript(script)
        except FileNotFoundError as error:
            return {
                "status": "error",
                "role": role,
                "name": name,
                "reason": "osascript_failed",
                "message": str(error),
                "write_attempted": False,
            }
        except subprocess.TimeoutExpired as error:
            return {
                "status": "error",
                "role": role,
                "name": name,
                "reason": "osascript_failed",
                "message": str(error),
            }
        parsed = self._json_result(result)
        payload = {
            "status": parsed.get("status", "error"),
            "role": role,
            "name": name,
        }
        if "message" in parsed:
            payload["message"] = parsed["message"]
        if isinstance(parsed.get("write_attempted"), bool):
            payload["write_attempted"] = parsed["write_attempted"]
        if result.returncode != 0 and payload["status"] == "error":
            payload["message"] = (result.stderr or "").strip() or payload.get("message", "")
        return payload


def detect_free_tempo_modal(
    runner: SystemEventsFreeTempoModalRunner | None = None,
) -> dict[str, Any]:
    return (runner or SystemEventsFreeTempoModalRunner()).detect()


def resolve_free_tempo_modal(
    runner: SystemEventsFreeTempoModalRunner | None = None,
    policy: dict[str, Any] | None = None,
    pause=time.sleep,
) -> dict[str, Any]:
    active_runner = runner or SystemEventsFreeTempoModalRunner()
    active_policy = deepcopy(policy or DEFAULT_FREE_TEMPO_POLICY)
    before = active_runner.detect()
    result: dict[str, Any] = {
        "policy_id": active_policy["policy_id"],
        "before": before,
        "actions": [],
        "decision": {},
    }

    if before.get("status") != "present":
        result["status"] = before.get("status", "error")
        if before.get("reason"):
            result["reason"] = before["reason"]
        return _with_local_terminal_receipt(result)

    plan = _build_action_plan(before, active_policy)
    result["decision"] = plan.get("decision", {})
    if plan.get("status") != "actionable":
        result["status"] = "blocked"
        result["reason"] = plan.get("reason", "plan_blocked")
        return _with_local_terminal_receipt(result)

    for step in plan["steps"]:
        click_result = active_runner.click(step["role"], step["name"])
        click_result["purpose"] = step["purpose"]
        result["actions"].append(click_result)
        if click_result.get("status") != "clicked":
            result["status"] = "blocked"
            result["reason"] = "click_failed"
            result["after"] = active_runner.detect()
            return _with_local_terminal_receipt(result)
        pause(0.2)

    after = active_runner.detect()
    result["after"] = after
    if after.get("status") == "present":
        result["status"] = "blocked"
        result["reason"] = "modal_still_visible"
    elif after.get("status") == "error":
        result["status"] = "error"
        result["reason"] = after.get("reason", "postcheck_failed")
    else:
        result["status"] = "dismissed"
    return _with_local_terminal_receipt(result)


def _main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "detect"
    if command == "detect":
        payload = detect_free_tempo_modal()
    elif command == "resolve":
        payload = resolve_free_tempo_modal()
    else:
        print("usage: logic_free_tempo_modal.py [detect|resolve]", file=sys.stderr)
        return 2
    payload = _with_local_terminal_receipt(payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 1 if payload["terminal"] else 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
