#!/usr/bin/env python3
"""Capture the STATIC wire surface (no live Logic) of a LogicProMCP binary → JSON snapshot dir.
Usage: golden_capture.py <binary> <outdir>
Captures: tools/list, resources/list, resources/templates/list, and a battery of
protocol/error envelopes (unknown tool, missing command, unknown command per tool,
invalid params, bogus cursor, unknown help category). Deterministic — safe to diff."""
import json, subprocess, sys, threading, time
from pathlib import Path

BINARY, OUTDIR = sys.argv[1], Path(sys.argv[2])
OUTDIR.mkdir(parents=True, exist_ok=True)


class Client:
    def __init__(self):
        self.p = subprocess.Popen([BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, bufsize=0)
        self.resp = {}
        threading.Thread(target=self._r, daemon=True).start()

    def _r(self):
        for line in self.p.stdout:
            line = line.decode().strip()
            if not line:
                continue
            try:
                m = json.loads(line)
                if m.get("id") is not None:
                    self.resp[m["id"]] = m
            except Exception:
                pass

    def send(self, msg, t=30):
        self.p.stdin.write((json.dumps(msg) + "\n").encode()); self.p.stdin.flush()
        i = msg.get("id")
        if i is None:
            return None
        end = time.time() + t
        while time.time() < end:
            if i in self.resp:
                return self.resp.pop(i)
            time.sleep(0.02)
        return None

    def close(self):
        try: self.p.stdin.close(); self.p.terminate(); self.p.wait(timeout=3)
        except Exception: self.p.kill()


def norm(obj):
    """Strip volatile fields (timestamps, ages) so diffs are deterministic."""
    if isinstance(obj, dict):
        return {k: ("<VOLATILE>" if k in {"plugins_fetched_at", "fetched_at", "last_feedback_at",
                                          "cache_age_sec", "transport_age_sec", "uptime_sec",
                                          "generated_at", "lastUpdated"} else norm(v))
                for k, v in sorted(obj.items())}
    if isinstance(obj, list):
        return [norm(x) for x in obj]
    return obj


def dump(name, resp):
    (OUTDIR / f"{name}.json").write_text(json.dumps(norm(resp), indent=1, ensure_ascii=False) + "\n")


_id = [1]
def nid():
    _id[0] += 1; return _id[0]


def call(c, tool, command, params=None):
    args = {"command": command}
    if params:
        args["params"] = params
    return c.send({"jsonrpc": "2.0", "id": nid(), "method": "tools/call",
                   "params": {"name": tool, "arguments": args}})


def main():
    c = Client()
    try:
        c.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                           "clientInfo": {"name": "golden", "version": "1"}}})
        c.send({"jsonrpc": "2.0", "method": "notifications/initialized"}); time.sleep(1)

        dump("tools_list", c.send({"jsonrpc": "2.0", "id": nid(), "method": "tools/list", "params": {}}))
        dump("resources_list", c.send({"jsonrpc": "2.0", "id": nid(), "method": "resources/list", "params": {}}))
        dump("resource_templates", c.send({"jsonrpc": "2.0", "id": nid(), "method": "resources/templates/list", "params": {}}))

        # protocol/error envelopes (deterministic, no live Logic needed)
        dump("err_unknown_tool", c.send({"jsonrpc": "2.0", "id": nid(), "method": "tools/call",
             "params": {"name": "logic_nonexistent", "arguments": {"command": "x"}}}))
        dump("err_bogus_cursor", c.send({"jsonrpc": "2.0", "id": nid(), "method": "resources/list",
             "params": {"cursor": "BOGUS_CURSOR"}}))
        tools = ["logic_transport", "logic_tracks", "logic_mixer", "logic_navigate", "logic_project",
                 "logic_system", "logic_edit", "logic_midi", "logic_plugins", "logic_audio"]
        for t in tools:
            dump(f"err_missing_cmd_{t}", c.send({"jsonrpc": "2.0", "id": nid(), "method": "tools/call",
                 "params": {"name": t, "arguments": {}}}))
            dump(f"err_unknown_cmd_{t}", call(c, t, "zzz_unknown_command"))
        dump("err_help_bogus_category", call(c, "logic_system", "help", {"category": "bogus"}))
        dump("err_invalid_track_index", call(c, "logic_tracks", "rename", {"index": "-5", "name": "x"}))
        dump("err_midi_bad_channel", call(c, "logic_midi", "send_cc",
             {"controller": "1", "value": "1", "channel": "99"}))
    finally:
        c.close()
    print(f"captured {len(list(OUTDIR.glob('*.json')))} snapshots → {OUTDIR}")


if __name__ == "__main__":
    main()
