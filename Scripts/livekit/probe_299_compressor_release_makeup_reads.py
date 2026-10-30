#!/usr/bin/env python3
"""Probe bounded #299 Compressor Release and Make Up reads without setters.

This writes a compact non-visual read receipt, not an ``evidence.Evidence``
document. It is deliberately named ``probe_*``: ``live_*`` is reserved for
harnesses that satisfy the repository's visual capture and recording contract.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if REPO not in sys.path:
    sys.path.insert(0, REPO)

from Scripts.livekit.probe_299_compressor_knee_read import compressor_target, digest
from Scripts.verify.live.mcp import Server


READ_STATUS = "read"
PARAMETERS = ("release", "makeup")


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
    candidate_head = subprocess.check_output(
        ["git", "-C", REPO, "rev-parse", "HEAD"], text=True
    ).strip()
    candidate_tree = subprocess.check_output(
        ["git", "-C", REPO, "rev-parse", "HEAD^{tree}"], text=True
    ).strip()
    server = Server(binary)
    calls: dict[str, dict] = {}
    start = server.start()
    target_ref = None
    target_row = None
    failure = None
    try:
        calls["refresh_cache"] = server.tool("logic_system", "refresh_cache", {}, 60)
        calls["project_info"] = server.resource("logic://project/info", 60)
        project = calls["project_info"].get("body") or {}
        observed_project = ((project.get("data") or {}).get("filePath"))
        if not isinstance(observed_project, str) or os.path.realpath(observed_project) != expected_project:
            raise RuntimeError(
                f"expected project {expected_project!r}, observed {observed_project!r}"
            )
        calls["before_inventory"] = server.tool(
            "logic_plugins", "get_inventory",
            {"track": args.track, "reveal_mixer": False}, 120,
        )
        target_ref, target_row = compressor_target(
            calls["before_inventory"].get("body"), args.insert
        )
        if target_ref is None:
            raise RuntimeError("the requested insert was not one uniquely observed Compressor")
        for parameter in PARAMETERS:
            calls[f"{parameter}_read"] = server.tool(
                "logic_plugins", "get_param_verified",
                {"target_ref": target_ref, "param": parameter}, 120,
            )
        calls["after_inventory"] = server.tool(
            "logic_plugins", "get_inventory",
            {"track": args.track, "reveal_mixer": False}, 120,
        )
    except Exception as exc:
        failure = repr(exc)
    finally:
        stop = server.stop()

    bodies = {name: call.get("body") for name, call in calls.items()}
    after_ref, after_row = compressor_target(bodies.get("after_inventory"), args.insert)
    checks = {
        "project_matches": failure is None,
        "before_inventory_state_a": (bodies.get("before_inventory") or {}).get("state") == "A",
        "same_target_after": target_ref is not None
        and after_ref == target_ref
        and after_row == target_row,
        "no_timeout": all(call.get("timed_out") is False for call in calls.values()),
        "server_pid_gone": stop.get("pid_gone") is True,
    }
    for parameter in PARAMETERS:
        read = bodies.get(f"{parameter}_read") or {}
        observed_raw = read.get("observed_raw")
        checks.update({
            f"{parameter}_state_a": read.get("state") == "A",
            f"{parameter}_verified": read.get("verified") is True,
            f"{parameter}_raw_is_finite_number": isinstance(observed_raw, (int, float))
            and not isinstance(observed_raw, bool)
            and math.isfinite(observed_raw),
            f"{parameter}_raw_unit_is_opaque": read.get("raw_unit") == "raw_ax_value",
            f"{parameter}_display_is_nonempty": isinstance(read.get("observed_display"), str)
            and bool(read.get("observed_display", "").strip()),
            f"{parameter}_parameter_read_status": read.get("parameter_read_status") == READ_STATUS,
            f"{parameter}_write_not_attempted": read.get("write_attempted") is False,
            f"{parameter}_view_restored": read.get("plugin_view_restore_observed") is True,
            f"{parameter}_new_editor_closed": read.get("editor_close_observed") is True,
        })

    passed = all(checks.values())
    record = {
        "format": "logic-pro-mcp/native-read-receipt-v1",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "candidate_head": candidate_head,
        "candidate_tree": candidate_tree,
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
        "timeouts": {name: call.get("timed_out") for name, call in calls.items()},
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
