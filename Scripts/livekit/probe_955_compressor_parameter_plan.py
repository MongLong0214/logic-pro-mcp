#!/usr/bin/env python3
"""Probe a bounded #955 Compressor parameter plan without applying it.

The receipt is a compact, non-visual native-plan record. It exercises the
public read-only plan over one exact insert and never calls a setter.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VERIFY = os.path.join(REPO, "Scripts", "verify")
if VERIFY not in sys.path:
    sys.path.insert(0, VERIFY)

from live.mcp import Server


PLUGIN_ID = "logic.stock.effect.compressor"
READ_STATUS = "read"
PARAMETERS = {
    "limiter_on": {"raw_unit": "boolean", "requested_unit": "boolean", "requested_value": 0.0},
    "threshold": {"raw_unit": "normalized", "requested_unit": "percent", "requested_value": 38.0},
}
EXPECTED_STAGES = {
    "refresh_cache",
    "project_info",
    "inspect_session",
    "before_inventory",
    "plan",
    "after_inventory",
}


def digest(value: object) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def scalar(value: object) -> float | None:
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        number = float(value)
        return number if math.isfinite(number) else None
    return None


def compressor_target(inventory: object, insert: int) -> tuple[str | None, dict | None]:
    if not isinstance(inventory, dict):
        return None, None
    matches = [
        row
        for row in inventory.get("plugins", [])
        if isinstance(row, dict)
        and row.get("insert") == insert
        and row.get("plugin_id") == PLUGIN_ID
        and row.get("read_status") == "ok"
        and isinstance(row.get("plugin_insert_ref"), str)
    ]
    if len(matches) != 1:
        return None, None
    return matches[0]["plugin_insert_ref"], matches[0]


def response_matches(
    response: object,
    *,
    param: str,
    unit: str,
    track: int,
    insert: int,
) -> bool:
    if not isinstance(response, dict):
        return False
    identity = response.get("target_identity")
    return (
        response.get("state") == "A"
        and response.get("success") is True
        and response.get("verified") is True
        and response.get("hc_schema") == 2
        and response.get("operation") == "logic_plugins.get_param_verified"
        and response.get("parameter_read_status") == READ_STATUS
        and response.get("observation_scope") == "current_insert_parameter"
        and response.get("verify_source") == "ax_plugin_window"
        and response.get("write_attempted") is False
        and response.get("plugin_view_restore_observed") is True
        and response.get("editor_close_observed") is True
        and response.get("param") == param
        and response.get("raw_unit") == unit
        and scalar(response.get("observed_raw")) is not None
        and isinstance(identity, dict)
        and identity.get("track_index") == track
        and identity.get("insert") == insert
        and identity.get("plugin_id") == PLUGIN_ID
    )


def entry_matches(entry: object, *, track: int, insert: int) -> bool:
    if not isinstance(entry, dict):
        return False
    param = entry.get("param")
    if param not in PARAMETERS:
        return False
    expected = PARAMETERS[param]
    requested = entry.get("requested")
    observations = entry.get("read_observations")
    if (
        entry.get("status") not in {"change", "unchanged"}
        or entry.get("raw_unit") != expected["raw_unit"]
        or not isinstance(requested, dict)
        or requested.get("param") != param
        or requested.get("unit") != expected["requested_unit"]
        or scalar(requested.get("value")) != expected["requested_value"]
        or scalar(entry.get("requested_value")) != expected["requested_value"]
        or not isinstance(observations, list)
        or len(observations) != 2
    ):
        return False
    responses: list[dict] = []
    for observation, expected_bookend in zip(observations, ("initial", "final")):
        if not isinstance(observation, dict) or observation.get("bookend") != expected_bookend:
            return False
        response = observation.get("response")
        if not response_matches(
            response,
            param=param,
            unit=expected["raw_unit"],
            track=track,
            insert=insert,
        ):
            return False
        responses.append(response)
    before = scalar(entry.get("observed_before"))
    initial = scalar(responses[0].get("observed_raw"))
    final = scalar(responses[1].get("observed_raw"))
    requested_value = expected["requested_value"]
    if before is None or before != initial or final != initial:
        return False
    if scalar(entry.get("delta")) != requested_value - before:
        return False
    expected_status = "unchanged" if requested_value == before else "change"
    return entry.get("status") == expected_status


def evaluate_plan(body: object, target_ref: str, track: int, insert: int) -> dict:
    body = body if isinstance(body, dict) else {}
    identity = body.get("target_identity")
    entries = body.get("entries")
    checks = {
        "state_a_verified": body.get("state") == "A"
        and body.get("success") is True
        and body.get("verified") is True
        and body.get("hc_schema") == 2,
        "read_only_scope": body.get("operation") == "logic_plugins.plan_parameter_changes"
        and body.get("complete") is True
        and body.get("observation_scope") == "requested_supported_subset"
        and body.get("atomic_snapshot") is False
        and body.get("application_authorized") is False
        and body.get("write_attempted") is False,
        "exact_target": body.get("target_ref") == target_ref
        and isinstance(identity, dict)
        and identity.get("track_index") == track
        and identity.get("insert") == insert
        and identity.get("plugin_id") == PLUGIN_ID,
        "exact_parameter_set": isinstance(entries, list)
        and len(entries) == len(PARAMETERS)
        and {entry.get("param") for entry in entries if isinstance(entry, dict)} == set(PARAMETERS),
        "stable_bookends": isinstance(entries, list)
        and all(entry_matches(entry, track=track, insert=insert) for entry in entries),
    }
    return {"checks": checks, "pass": all(checks.values())}


def evaluate_run(
    failure: object,
    plan_verdict: dict,
    project_matches: bool,
    before_inventory_state_a: bool,
    same_target_after: bool,
    timeouts: dict[str, object],
    stop: dict,
) -> dict:
    close_steps = [
        step
        for step in stop.get("steps", [])
        if isinstance(step, dict) and step.get("step") == "close_stdin"
    ]
    checks = {
        "project_matches": project_matches,
        "before_inventory_state_a": before_inventory_state_a,
        "plan": plan_verdict,
        "same_target_after": same_target_after,
        "all_stages_bounded_without_timeout": set(timeouts) == EXPECTED_STAGES
        and all(value is False for value in timeouts.values()),
        "server_stopped_cleanly": stop.get("returncode") == 0
        and stop.get("pid_gone") is True
        and stop.get("reader_finished") is True
        and len(close_steps) == 1
        and close_steps[0].get("exited") is True
        and close_steps[0].get("returncode") == 0,
    }
    passed = (
        failure is None
        and project_matches
        and before_inventory_state_a
        and plan_verdict.get("pass") is True
        and same_target_after
        and checks["all_stages_bounded_without_timeout"]
        and checks["server_stopped_cleanly"]
    )
    return {"checks": checks, "pass": passed}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("out")
    parser.add_argument("--project", required=True)
    parser.add_argument("--track", type=int, default=13)
    parser.add_argument("--insert", type=int, default=1)
    args = parser.parse_args()

    binary = os.path.realpath(args.binary)
    expected_project = os.path.realpath(args.project)
    server = Server(binary)
    calls: dict[str, dict] = {}
    target_ref = None
    target_row = None
    observed_project = None
    start = server.start()
    try:
        calls["refresh_cache"] = server.tool("logic_system", "refresh_cache", {}, 60)
        calls["project_info"] = server.resource("logic://project/info", 60)
        project = calls["project_info"].get("body") or {}
        observed_project = (project.get("data") or {}).get("filePath")
        if not isinstance(observed_project, str) or os.path.realpath(observed_project) != expected_project:
            raise RuntimeError(
                f"expected project {expected_project!r}, observed {observed_project!r}"
            )
        calls["inspect_session"] = server.tool(
            "logic_project",
            "inspect_session",
            {"scope": "whole_project", "domains": ["tracks", "strips"]},
            120,
        )
        calls["before_inventory"] = server.tool(
            "logic_plugins",
            "get_inventory",
            {"track": args.track, "reveal_mixer": False},
            120,
        )
        target_ref, target_row = compressor_target(
            calls["before_inventory"].get("body"), args.insert
        )
        if target_ref is None:
            raise RuntimeError("the requested insert was not one uniquely observed Compressor")
        calls["plan"] = server.tool(
            "logic_plugins",
            "plan_parameter_changes",
            {
                "target_ref": target_ref,
                "changes": [
                    {"param": "threshold", "value": 38, "unit": "percent"},
                    {"param": "limiter_on", "value": False, "unit": "boolean"},
                ],
            },
            180,
        )
        calls["after_inventory"] = server.tool(
            "logic_plugins",
            "get_inventory",
            {"track": args.track, "reveal_mixer": False},
            120,
        )
    except Exception as exc:
        failure = repr(exc)
    else:
        failure = None
    finally:
        stop = server.stop()

    bodies = {name: call.get("body") for name, call in calls.items()}
    after_ref, after_row = compressor_target(bodies.get("after_inventory"), args.insert)
    plan_verdict = evaluate_plan(bodies.get("plan"), target_ref or "", args.track, args.insert)
    timeouts = {name: call.get("timed_out") for name, call in calls.items()}
    verdict = evaluate_run(
        failure,
        plan_verdict,
        isinstance(observed_project, str)
        and os.path.realpath(observed_project) == expected_project,
        (bodies.get("before_inventory") or {}).get("state") == "A",
        target_ref is not None and after_ref == target_ref and after_row == target_row,
        timeouts,
        stop,
    )
    checks = verdict["checks"]
    passed = verdict["pass"]
    record = {
        "format": "logic-pro-mcp/native-parameter-plan-receipt-v1",
        "binary": binary,
        "binary_sha256": hashlib.sha256(open(binary, "rb").read()).hexdigest(),
        "expected_project": expected_project,
        "track": args.track,
        "insert": args.insert,
        "target_ref": target_ref,
        "failure": failure,
        "checks": checks,
        "pass": passed,
        "bodies": bodies,
        "sorted_json_sha256": {name: digest(body) for name, body in bodies.items()},
        "timeouts": timeouts,
        "server_start": {"spawned": start.get("spawned"), "pid": start.get("pid")},
        "server_stop": stop,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
