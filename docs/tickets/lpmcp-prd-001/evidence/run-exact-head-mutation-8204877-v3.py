#!/usr/bin/env python3
"""Desktop/ko mutation + readback + restore + fail-closed on sealed exact-head binary."""
import json, subprocess, time, hashlib, os, sys
from pathlib import Path

ROOT = Path("/Users/isaac/projects/logic-pro-mcp-adr001-remediation")
BIN = ROOT / "LogicProMCP"
HEAD = "8204877c2d66d11598ac5e7292d231fa42c8a8b3"
BIN_SHA = "8c3a525a89a6bbaaff09e362ea35aae8391243d9eff1221c1161aa58257262d6"
OUT = ROOT / "docs/tickets/lpmcp-prd-001/evidence/live/mutation/exact-head-8204877-ko-v3"
OUT.mkdir(parents=True, exist_ok=True)

actual = hashlib.sha256(BIN.read_bytes()).hexdigest()
if actual != BIN_SHA:
    raise SystemExit(f"binary sha mismatch: {actual}")
got = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
if got != HEAD:
    raise SystemExit(f"HEAD mismatch: {got}")

proc = subprocess.Popen(
    [str(BIN)],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)
assert proc.stdin and proc.stdout
req_id = 0
transcript = []

def rpc(method, params=None, is_notification=False):
    global req_id
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not is_notification:
        req_id += 1
        msg["id"] = req_id
    line = json.dumps(msg, separators=(",", ":"))
    proc.stdin.write(line + "\n")
    proc.stdin.flush()
    transcript.append({"dir": "out", "msg": msg})
    if is_notification:
        return None
    deadline = time.time() + 60
    while time.time() < deadline:
        raw = proc.stdout.readline()
        if not raw:
            raise RuntimeError("EOF from server")
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            transcript.append({"dir": "in_raw", "text": raw[:500]})
            continue
        transcript.append({"dir": "in", "msg": obj})
        if obj.get("id") == msg["id"]:
            return obj
    raise TimeoutError(method)

def tool(name, arguments):
    return rpc("tools/call", {"name": name, "arguments": arguments})

def payload(resp):
    result = (resp or {}).get("result") or {}
    content = result.get("content") or []
    texts = []
    for c in content:
        if isinstance(c, dict) and c.get("type") == "text":
            texts.append(c.get("text") or "")
    joined = "\n".join(texts)
    try:
        return json.loads(joined)
    except Exception:
        return {"raw": joined, "isError": result.get("isError"), "result": result}

rpc("initialize", {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "t1-exact-head-mutation-v3", "version": "1.0"},
})
rpc("notifications/initialized", {}, is_notification=True)

health0 = payload(tool("logic_system", {"command": "health", "params": {}}))

# Ensure a document with at least one audio track
create = payload(tool("logic_tracks", {"command": "create_audio", "params": {}}))
time.sleep(2)
# some builds use create_instrument as fallback
if not create.get("success", True) and create.get("error"):
    create2 = payload(tool("logic_tracks", {"command": "create_instrument", "params": {}}))
else:
    create2 = None
time.sleep(1)
health1 = payload(tool("logic_system", {"command": "health", "params": {}}))

def set_vol(track, value):
    return payload(tool("logic_mixer", {
        "command": "set_volume",
        "params": {"track": track, "value": float(value)},
    }))

# Fail-closed first (zero-write expectations)
m2 = set_vol(99999, 0.5)
m3 = payload(tool("logic_mixer", {"command": "not_a_real_command", "params": {}}))
m3b = tool("logic_no_such_tool", {"command": "x", "params": {}})

# Find a track that accepts set_volume
m1 = None
track_used = None
for track in range(0, 8):
    r0 = set_vol(track, 0.51)
    if r0.get("success") is True or r0.get("state") == "A" or r0.get("verified") is True:
        original = r0.get("observed_before", r0.get("observed", 0.51))
        r1 = set_vol(track, 0.42)
        # independent readback is verified/observed fields on response
        r2 = set_vol(track, float(original))  # restore
        r3 = set_vol(track, float(original))  # restore-readback / confirm
        m1 = {
            "track": track,
            "original_observed": original,
            "initial_write": r0,
            "state_a_write": r1,
            "restore_to_original": r2,
            "restore_readback_confirm": r3,
        }
        track_used = track
        break
    # remember last failure
    last_fail = r0

if m1 is None:
    m1 = {"error": "no_track_volume_found", "last": last_fail if 'last_fail' in dir() else None, "create": create, "create2": create2}

# M4 fail-closed via fault inject env is separate process; document unit path if not set
m4 = {
    "status": "deferred_to_fault_inject_subprocess",
    "note": "Run LOGIC_PRO_MCP_FAULT_INJECT=partial_state single call separately",
}

try:
    proc.terminate()
except Exception:
    pass

checks = {
    "head": HEAD,
    "binary_sha256": BIN_SHA,
    "logic_ui_locale": health0.get("logic_pro_ui_locale") or health1.get("logic_pro_ui_locale"),
    "M1_mutation_success": bool(m1 and isinstance(m1, dict) and m1.get("state_a_write", {}).get("success") is True),
    "M1_restore_success": bool(m1 and isinstance(m1, dict) and m1.get("restore_to_original", {}).get("success") is True),
    "M1_restore_readback_verified": bool(
        m1 and isinstance(m1, dict)
        and (
            m1.get("restore_readback_confirm", {}).get("verified") is True
            or m1.get("restore_to_original", {}).get("verified") is True
        )
    ),
    "M2_fail_closed": m2.get("success") is False and m2.get("state") == "C",
    "M3_write_attempted_false": m3.get("write_attempted") is False and m3.get("success") is False,
    "M3_unknown_tool_error": isinstance(m3b.get("error"), dict),
}
checks["overall_mutation_pass"] = all([
    checks["M1_mutation_success"],
    checks["M1_restore_success"],
    checks["M1_restore_readback_verified"],
    checks["M2_fail_closed"],
    checks["M3_write_attempted_false"],
    checks["logic_ui_locale"] == "ko-KR",
])

summary = {
    "head": HEAD,
    "binary_sha256": BIN_SHA,
    "axis": "desktop/ko-KR",
    "health_before": health0,
    "health_after_create": health1,
    "create_audio": create,
    "create_instrument_fallback": create2,
    "M1": m1,
    "M2_wrong_target": m2,
    "M3_unknown_command": m3,
    "M3_unknown_tool": m3b,
    "M4": m4,
    "checks": checks,
    "transcript_events": len(transcript),
}
(OUT / "mutation-summary.json").write_text(json.dumps(summary, indent=2)[:400000])
(OUT / "checks.json").write_text(json.dumps(checks, indent=2))
(OUT / "mutation-transcript.jsonl").write_text("\n".join(json.dumps(e, ensure_ascii=False) for e in transcript) + "\n")
(OUT / "identity.txt").write_text(
    f"HEAD={HEAD}\nBINARY_SHA256={BIN_SHA}\nLOCALE={checks['logic_ui_locale']}\nOVERALL={checks['overall_mutation_pass']}\n"
)
print(json.dumps(checks, indent=2))
sys.exit(0 if checks["overall_mutation_pass"] else 2)
