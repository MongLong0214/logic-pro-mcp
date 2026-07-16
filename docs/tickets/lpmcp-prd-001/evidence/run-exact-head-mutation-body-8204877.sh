cd /Users/isaac/projects/logic-pro-mcp-adr001-remediation
set -euo pipefail
BIN="$PWD/LogicProMCP"
test "$(shasum -a 256 "$BIN" | awk '{print $1}')" = 8c3a525a89a6bbaaff09e362ea35aae8391243d9eff1221c1161aa58257262d6
EV=docs/tickets/lpmcp-prd-001/evidence
OUT=$EV/live/mutation/exact-head-8204877-ko
mkdir -p "$OUT"
printf 'WORKING: mutation NO-THRASH MCP driver\n' | tee "$EV/worker-A-heartbeat.txt"

python3 - <<'PY'
import json, subprocess, time, hashlib, os
from pathlib import Path

BIN = Path("/Users/isaac/projects/logic-pro-mcp-adr001-remediation/LogicProMCP")
OUT = Path("/Users/isaac/projects/logic-pro-mcp-adr001-remediation/docs/tickets/lpmcp-prd-001/evidence/live/mutation/exact-head-8204877-ko")
OUT.mkdir(parents=True, exist_ok=True)
BIN_SHA = "8c3a525a89a6bbaaff09e362ea35aae8391243d9eff1221c1161aa58257262d6"

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
    # read until matching id
    while True:
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

def tool(name, arguments):
    return rpc("tools/call", {"name": name, "arguments": arguments})

# initialize
init = rpc("initialize", {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "t1-live-mutation", "version": "1.0"},
})
rpc("notifications/initialized", {}, is_notification=True)

# health
health = tool("logic_system", {"command": "health", "params": {}})

# list tracks via resources if available, else mixer via set_volume probe
# Prefer logic_mixer set_volume on track 0 after reading via resources/list
resources = rpc("resources/list", {})
tracks_uri = None
for r in (resources.get("result") or {}).get("resources") or []:
    uri = r.get("uri") or ""
    if "tracks" in uri:
        tracks_uri = uri
        break
tracks = None
if tracks_uri:
    tracks = rpc("resources/read", {"uri": tracks_uri})

# choose track index 2 if exists else 0
track = 2
orig = None
# try read volume via set_volume identity? Better: use tools to get_mixer if any.
# Use set_volume readback by writing same after reading health project track_count.

def set_vol(track, value):
    return tool("logic_mixer", {"command": "set_volume", "params": {"track": track, "value": float(value)}})

# Probe original: attempt mild get by reading resource content
# Fallback: set to known and restore from response readback fields.

# M3 ambiguity / zero-write: duplicate name path not available in API — use wrong track index huge
m2 = set_vol(99999, 0.5)
m3 = tool("logic_mixer", {"command": "not_a_real_command", "params": {}})
m3b = tool("logic_no_such_tool", {"command": "x", "params": {}})

# M1: mutation on track 0 (safest index)
# Capture before by setting a first read: many builds return current in error? 
# Strategy: set_volume to 0.55, readback; set to 0.65; restore 0.55 if first was accepted.
# First get baseline via two-step: try set_volume 0.51 and capture readback original if present.

r0 = set_vol(0, 0.51)
# parse response content
def payload(resp):
    result = (resp or {}).get("result") or {}
    content = result.get("content") or []
    texts = []
    for c in content:
        if isinstance(c, dict) and c.get("type") == "text":
            texts.append(c.get("text") or "")
    if not texts and "structuredContent" in result:
        return result.get("structuredContent")
    joined = "\n".join(texts)
    try:
        return json.loads(joined)
    except Exception:
        return {"raw": joined, "isError": result.get("isError"), "result": result}

p0 = payload(r0)
# Attempt restore value from response fields
orig = None
for key in ("previous_value", "original", "before", "prior_value"):
    if isinstance(p0, dict) and key in p0:
        orig = p0[key]
if orig is None and isinstance(p0, dict):
    # if State A with value
    orig = p0.get("value") if p0.get("success") is False else None
# If first write succeeded, treat 0.51 as current and use 0.42 as state A then restore 0.51
state_a = 0.42
if isinstance(p0, dict) and (p0.get("success") is True or p0.get("state") in ("A", "B") or p0.get("verified") is True):
    baseline = 0.51
    r1 = set_vol(0, state_a)
    p1 = payload(r1)
    r2 = set_vol(0, baseline)  # restore
    p2 = payload(r2)
    m1 = {"baseline_write": p0, "state_a_write": p1, "restore_write": p2, "baseline": baseline, "state_a": state_a}
else:
    # try track 1
    r0b = set_vol(1, 0.51)
    p0b = payload(r0b)
    r1 = set_vol(1, state_a)
    p1 = payload(r1)
    r2 = set_vol(1, 0.51)
    p2 = payload(r2)
    m1 = {"baseline_write": p0b, "state_a_write": p1, "restore_write": p2, "track": 1, "note": "track0 failed or not success", "track0": p0}

# M4 timeout: skip with documented non-exercise if no hang API
m4 = {"status": "not_exercised", "reason": "no safe hang injection API on sealed binary without product change"}

# shutdown
try:
    proc.terminate()
except Exception:
    pass

summary = {
    "binary_sha256": BIN_SHA,
    "health": payload(health),
    "tracks_resource": tracks,
    "M1": m1,
    "M2_wrong_target": payload(m2),
    "M3_unknown_command": payload(m3),
    "M3_unknown_tool": m3b,
    "M4": m4,
    "transcript_events": len(transcript),
}
(OUT / "mutation-summary.json").write_text(json.dumps(summary, indent=2)[:200000])
(OUT / "mutation-transcript.jsonl").write_text("\n".join(json.dumps(e) for e in transcript) + "\n")
print(json.dumps({"ok": True, "events": len(transcript), "summary_path": str(OUT / "mutation-summary.json")}, indent=2))
PY
