#!/usr/bin/env python3
"""Scripted MCP client for the launch video. Real stdio JSON-RPC against the real LogicProMCP binary.

It plays the part of an AI client: the same `tools/call` and `resources/read` requests an agent would send,
issued on a schedule, with every request/response and its wall-clock latency written to a JSONL log. The video
transcript, the on-screen timers and the "verified" captions are rendered from that log, never typed by hand.

Honest by construction:
  * no call is faked or retried; a call that fails is logged as it failed;
  * latencies are the measured ones (monotonic clock around the round trip), never edited or sped up;
  * only operations in docs/qualification (the 17 not listed in not-qualified-logic13.json) plus read-only
    resource reads are used (set_tempo, set_volume, set_pan, play, stop, goto_position). `--list-ops` prints exactly which.

Usage:
  driver.py --scenario reset  --log out/reset.jsonl     # not filmed: tempo 90, every fader down
  driver.py --scenario setup  --log out/setup.jsonl     # take A: read state, tempo, place and level the mix
  driver.py --scenario play   --log out/play.jsonl      # take B: bring each part in on cue while Logic plays
  driver.py --scenario setup --mock ...                 # no Logic: canned responses, for plumbing tests

Env: LOGIC_PRO_MCP_BINARY (default: the published v3.19.0 binary fetched by fetch-binary.sh).
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLAN = json.load(open(os.path.join(HERE, "music", "out", "arrangement.json"))) if os.path.exists(
    os.path.join(HERE, "music", "out", "arrangement.json")) else None
TRACKS = PLAN["track_order"] if PLAN else ["Keys", "Pad", "Bass", "Drums", "Lead"]

# The only mutating operations this driver may issue (all in the 17 live-qualified on Logic Pro 13.0).
QUALIFIED = {
    ("logic_transport", "play"), ("logic_transport", "stop"), ("logic_transport", "pause"),
    ("logic_transport", "set_tempo"), ("logic_transport", "goto_position"), ("logic_transport", "toggle_cycle"),
    ("logic_transport", "toggle_metronome"), ("logic_transport", "toggle_count_in"),
    ("logic_navigate", "goto_bar"), ("logic_mixer", "set_volume"), ("logic_mixer", "set_pan"),
    ("logic_tracks", "mute"), ("logic_tracks", "solo"), ("logic_tracks", "rename"), ("logic_tracks", "arm"),
    ("logic_midi", "list_ports"),
}


class Client:
    def __init__(self, binary, log, mock=False):
        self.mock, self.log, self.n = mock, open(log, "w"), 0
        self.proc = None
        if not mock:
            self.proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "logic-pro-mcp-demo-driver", "version": "1"}}, log=False)
        self._notify("notifications/initialized")

    def _notify(self, method):
        if self.proc:
            self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
            self.proc.stdin.flush()

    def rpc(self, method, params, log=True, label=None):
        self.n += 1
        t_epoch = time.time()
        t0 = time.monotonic()
        if self.mock:
            time.sleep(0.12)
            reply = {"result": {"content": [{"type": "text", "text": json.dumps({"state": "A", "verified": True, "mock": True})}]}}
        else:
            self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
            self.proc.stdin.flush()
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    raise RuntimeError("server closed stdout")
                reply = json.loads(line)
                if reply.get("id") == self.n:
                    break
        ms = (time.monotonic() - t0) * 1000
        if log:
            self.log.write(json.dumps({"seq": self.n, "t_epoch": t_epoch, "t_end_epoch": time.time(), "ms": round(ms, 1),
                                       "method": method, "params": params, "label": label, "reply": reply}) + "\n")
            self.log.flush()
        return reply, ms

    def tool(self, tool, command, params=None, label=None):
        if (tool, command) not in QUALIFIED:
            raise SystemExit(f"refusing {tool}.{command}: not one of the live-qualified operations")
        return self.rpc("tools/call", {"name": tool, "arguments": {"command": command, "params": params or {}}}, label=label)

    def read(self, uri, label=None):
        return self.rpc("resources/read", {"uri": uri}, label=label)

    def close(self):
        self.log.close()
        if self.proc:
            self.proc.terminate()


def text_of(reply):
    try:
        return reply["result"]["contents"][0]["text"]
    except (KeyError, IndexError, TypeError):
        try:
            return reply["result"]["content"][0]["text"]
        except (KeyError, IndexError, TypeError):
            return json.dumps(reply)


def scenario_setup(c, a):
    """Take A, transport stopped. Read the session, set the tempo, then place and level every track."""
    c.read("logic://system/health", label="read: health")
    c.read("logic://transport/state", label="read: transport")
    time.sleep(2.0)  # the server's track poller needs one cycle after the first read; reading earlier returns an empty cache
    c.read("logic://tracks", label="read: tracks")
    c.tool("logic_transport", "set_tempo", {"tempo": a["tempo"]}, label="set tempo")
    c.read("logic://transport/state", label="read: tempo readback")
    mix_t0 = time.monotonic()
    n = 0
    for i, (vol, pan) in enumerate(a["mix"]):
        c.tool("logic_mixer", "set_pan", {"track": i, "value": pan}, label=f"mix: pan {TRACKS[i]}")
        c.tool("logic_mixer", "set_volume", {"track": i, "value": vol}, label=f"mix: volume {TRACKS[i]}")
        n += 2
    c.log.write(json.dumps({"marker": "mix_batch", "writes": n, "seconds": round(time.monotonic() - mix_t0, 3), "t_epoch": time.time()}) + "\n")
    c.read("logic://tracks", label="read: tracks after mix")


def scenario_play(c, a):
    """Take B: every fader starts at zero; the client brings each part in on cue while Logic plays the song.

    Mute/solo/arm/rename act only on the selected track on Logic 13 and `tracks.select` is not qualified, so the
    entrances are fader moves (`mixer.set_volume`, qualified): each call moves the fader through its detents while
    the call runs, which is the fade-in you hear.
    """
    spb = PLAN["seconds_per_bar"]
    entry = {t["name"]: t["entry_bar"] for t in PLAN["tracks"]}
    lead = a.get("lead_seconds", 0.45)
    t0 = time.monotonic()
    t_epoch0 = time.time()
    c.tool("logic_transport", "play", label="play")
    c.log.write(json.dumps({"marker": "play_started", "t_epoch": t_epoch0, "spb": spb}) + "\n")
    cues = []
    for name in TRACKS:
        idx = TRACKS.index(name)
        at = (entry[name] - 1) * spb - lead
        cues.append((max(at, 0.0), "logic_mixer", "set_volume", {"track": idx, "value": a["mix"][idx][0]}, f"bring in {name}"))
    for bar, tool, command, params, label in a.get("rides", []):
        cues.append(((bar - 1) * spb - lead, tool, command, params, label))
    cues.sort(key=lambda x: x[0])
    for at, tool, command, params, label in cues:
        wait = at - (time.monotonic() - t0)
        if wait > 0:
            time.sleep(wait)
        c.tool(tool, command, params, label=label)
    end = PLAN["duration_seconds"] + 0.2
    wait = end - (time.monotonic() - t0)
    if wait > 0:
        time.sleep(wait)
    c.tool("logic_transport", "stop", label="stop")
    c.read("logic://transport/state", label="read: transport")


def scenario_reset(c, a):
    """Not filmed. Put the session back to the starting state both takes assume: tempo 90, every fader down."""
    c.tool("logic_transport", "stop", label="reset: stop")
    c.tool("logic_transport", "set_tempo", {"tempo": a["reset_tempo"]}, label="reset: tempo")
    for i in range(len(TRACKS)):
        c.tool("logic_mixer", "set_pan", {"track": i, "value": 0.0}, label=f"reset: pan {TRACKS[i]}")
        c.tool("logic_mixer", "set_volume", {"track": i, "value": a["start_volume"]}, label=f"reset: volume {TRACKS[i]}")
    c.tool("logic_navigate", "goto_bar", {"bar": 1}, label="reset: bar 1")


ARGS = {
    "reset_tempo": 90,  # take A starts at 90 and sets 112 on camera; reset before B uses 112 (--reset-tempo)
    "start_volume": 0.0,
    "tempo": 112,
    # per track in project order (Keys, Pad, Bass, Drums, Lead): (volume 0..1, pan -1..1)
    "mix": [(0.66, -0.25), (0.56, 0.0), (0.72, 0.0), (0.70, 0.0), (0.64, 0.30)],
    "lead_seconds": 0.45,
    "rides": [],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", choices=["setup", "play", "reset"])
    ap.add_argument("--log")
    ap.add_argument("--mock", action="store_true")
    ap.add_argument("--list-ops", action="store_true")
    ap.add_argument("--lead-seconds", type=float)
    ap.add_argument("--reset-tempo", type=float)
    a = ap.parse_args()
    if a.list_ops:
        for t, cmd in sorted(QUALIFIED):
            print(f"{t}.{cmd}")
        return
    if not a.scenario or not a.log:
        ap.error("--scenario and --log are required")
    if a.reset_tempo:
        ARGS["reset_tempo"] = a.reset_tempo
    if a.lead_seconds:
        ARGS["lead_seconds"] = a.lead_seconds
    binary = os.environ.get("LOGIC_PRO_MCP_BINARY", os.path.join(HERE, ".cache", "release", "LogicProMCP"))
    c = Client(binary, a.log, mock=a.mock)
    try:
        {"setup": scenario_setup, "play": scenario_play, "reset": scenario_reset}[a.scenario](c, ARGS)
    finally:
        c.close()


if __name__ == "__main__":
    main()
