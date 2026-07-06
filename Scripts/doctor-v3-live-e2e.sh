#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-"$ROOT/.omo/evidence/doctor-v3-live-e2e-$(date -u +%Y%m%dT%H%M%SZ)"}"
mkdir -p "$OUT_DIR"

cd "$ROOT"
swift build -c release > "$OUT_DIR/swift-build-release.log" 2>&1

BIN="$ROOT/.build/release/LogicProMCP"
USER_TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"

snapshot_sidecars() {
  python3 - "$USER_TCC" "$SYSTEM_TCC" <<'PY'
import json
import pathlib
import sys
paths = []
for label, raw in (("user_tcc_db", sys.argv[1]), ("system_tcc_db", sys.argv[2])):
    base = pathlib.Path(raw)
    for suffix in ("-wal", "-shm", "-journal"):
        p = pathlib.Path(str(base) + suffix)
        paths.append({"label": f"{label}{suffix}", "exists": p.exists()})
print(json.dumps(paths, sort_keys=True))
PY
}

snapshot_sidecars > "$OUT_DIR/tcc-sidecars-before.json"

set +e
"$BIN" doctor --json > "$OUT_DIR/doctor.json" 2> "$OUT_DIR/doctor.stderr"
doctor_rc=$?
"$BIN" doctor --strict --json > "$OUT_DIR/doctor-strict.json" 2> "$OUT_DIR/doctor-strict.stderr"
strict_rc=$?
set -e

snapshot_sidecars > "$OUT_DIR/tcc-sidecars-after.json"

python3 - "$OUT_DIR" "$doctor_rc" "$strict_rc" <<'PY'
import json
import pathlib
import sys
out = pathlib.Path(sys.argv[1])
doctor_rc = int(sys.argv[2])
strict_rc = int(sys.argv[3])
report = json.loads((out / "doctor.json").read_text())
strict_report = json.loads((out / "doctor-strict.json").read_text())
checks = {c["id"]: c for c in report["checks"]}
expected_strict = {"ok": 0, "failed": 1, "manual_action_required": 2, "degraded": 3}[report["status"]]
assert doctor_rc in (0, 1), doctor_rc
assert strict_rc == expected_strict, (strict_rc, expected_strict)
assert strict_report["schema"] == report["schema"] == "logic_pro_mcp_doctor.v3"
assert len(report["checks"]) == 26, len(report["checks"])
assert report["summary"]["total"] == 26
assert report["summary"]["total"] == sum(report["summary"][k] for k in ("passed", "failed", "warnings", "manual", "skipped"))
assert "fix_plan" in report
if report["fix_plan"]:
    assert f"[{report['fix_plan'][0]}]" in report["headline"]
for key in ("install.binary_inventory", "install.share_dir", "permissions.post_event_access", "permissions.launch_context", "permissions.tcc_cross_context", "logic.installation", "logic.version_support", "logic.blocking_dialog", "channels.keycmd_reference", "channels.mcu_wiring_hint", "dependencies.click_fallback"):
    assert key in checks, key
assert checks["install.binary_inventory"]["status"] == "warn", checks["install.binary_inventory"]
assert checks["install.binary_inventory"]["evidence"].get("stale") == "true", checks["install.binary_inventory"]
assert checks["permissions.launch_context"]["status"] == "pass"
assert checks["permissions.tcc_cross_context"]["status"] != "skipped", checks["permissions.tcc_cross_context"]
before = json.loads((out / "tcc-sidecars-before.json").read_text())
after = json.loads((out / "tcc-sidecars-after.json").read_text())
assert before == after, (before, after)
try:
    evidence_dir = str(out.resolve().relative_to(pathlib.Path.cwd().resolve()))
except ValueError:
    evidence_dir = out.name
summary = {
    "status": report["status"],
    "strict_exit": strict_rc,
    "check_count": len(report["checks"]),
    "binary_inventory": checks["install.binary_inventory"]["status"],
    "tcc_cross_context": checks["permissions.tcc_cross_context"]["status"],
    "evidence_dir": evidence_dir,
}
(out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, sort_keys=True))
PY
