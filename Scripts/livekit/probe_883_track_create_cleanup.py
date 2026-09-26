#!/usr/bin/env python3
"""Drive the #883 track-create sheet cleanup on the fixture that is already open.

`live_883_each_track_type_in_every_locale.py` cannot reach this path with a binary that has no
Create: its `project.new` fails first, so no project exists for a track create to run in. This
probe starts from the open fixture instead and calls `track.create_drummer`, the one create that
raises the New Track sheet in every language, through such a binary. It records what the product
reported and what System Events counts afterwards.

    /usr/bin/python3 probe_883_track_create_cleanup.py <worktree> <no-create-binary> <out.json>

The binary is built with `createButton` emptied. Logic must be running with only the
lpm-locale-campaign fixture open and no sheet or dialog up; the probe refuses otherwise.
"""
import json, os, subprocess, sys, time
WT, BIN, OUT = sys.argv[1:4]
sys.path.insert(0, os.path.join(WT, "Scripts", "livekit"))
import evidence as E  # noqa: E402

def osa(script, timeout=20):
    r = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip() if r.returncode == 0 else None

def names():
    raw = osa('tell application "System Events" to tell process "Logic Pro" to get name of every window')
    return [] if not raw else [p.strip() for p in raw.split(", ")]

def blocking():
    raw = osa('''tell application "System Events" to tell process "Logic Pro"
  set n to 0
  repeat with w in every window
    set n to n + (count of sheets of w)
  end repeat
  return (n as string) & "," & ((count of (windows whose subrole is "AXDialog")) as string)
end tell''')
    try:
        return tuple(int(p) for p in raw.split(","))
    except Exception:
        return None

def cleanup(body):
    if isinstance(body.get("new_track_sheet_cleanup"), dict):
        return body["new_track_sheet_cleanup"]
    try:
        return (json.loads(body.get("hint") or "") or {}).get("new_track_sheet_cleanup")
    except Exception:
        return None

out = {"windows_before": names(), "blocking_before": blocking(),
       "language": subprocess.run(["defaults", "read", "com.apple.logic10", "AppleLanguages"],
                                  capture_output=True, text=True).stdout.split()}
assert all(n.startswith("lpm-locale-campaign - ") for n in out["windows_before"]), out
assert out["blocking_before"] == (0, 0), out
d = E.Driver(binary=BIN)
d.tool("logic_tracks", "select", {"index": 0})
before = d.resource("logic://tracks").get("data", []) or []
body = d.tool("logic_tracks", "create_drummer")
time.sleep(2.0)
out["blocking_after"] = blocking()
out["windows_after"] = names()
d.tool("logic_tracks", "select", {"index": 0})
after = d.resource("logic://tracks").get("data", []) or []
out["track_count"] = [len(before), len(after)]
out["body"] = body
out["cleanup"] = cleanup(body if isinstance(body, dict) else {})
d.close()
json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=1)
print(json.dumps({k: out[k] for k in ("blocking_before", "blocking_after", "track_count", "cleanup")}, ensure_ascii=False))
print(json.dumps({k: body.get(k) for k in ("state", "error", "reason", "failure_stage", "phase", "menu_clicked")} if isinstance(body, dict) else body, ensure_ascii=False)[:600])
