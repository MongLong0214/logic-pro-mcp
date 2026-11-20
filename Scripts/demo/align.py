#!/usr/bin/env python3
"""Turn driver logs + capture metadata into motion/public/data/session.json (the film's only data input).

  align.py --a-log out/setup.jsonl --a-meta raw/A.meta.json --a-video motion/public/footage/A.mp4 \
           --b-log out/play.jsonl  --b-meta raw/B.meta.json --b-video motion/public/footage/B.mp4 \
           [--b-audio raw/B.audio.wav] --out motion/public/data/session.json

meta.json holds {"first_frame_epoch": <epoch of footage t=0>} printed by LogicCapture on start. Everything the
video shows about timing is derived here from wall-clock stamps written at the moment of each call.
"""
import argparse
import json
import re
import subprocess
import statistics
import datetime


def probe(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "stream=width,height:format=duration", "-of", "json", path])
    d = json.loads(out)
    return d["streams"][0]["width"], d["streams"][0]["height"], float(d["format"]["duration"])


def audio_onset(path, threshold_db=-50.0):
    """Seconds into `path` where the music starts (first sample above threshold)."""
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", f"silencedetect=n={threshold_db}dB:d=0.2", "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.search(r"silence_end: ([0-9.]+)", r.stderr)
    starts_silent = re.search(r"silence_start: (-?[0-9.]+)", r.stderr)
    if starts_silent and float(starts_silent.group(1)) <= 0.01 and m:
        return float(m.group(1))
    return 0.0


def play_start(path, bpm, lo, hi, probe=(30.0, 70.0)):
    """Footage seconds at which bar 1 begins. The beat grid is fitted to the drum transients of the full groove
    (kicks sit on every beat), then taken as the first grid position inside [lo, hi+0.25] = [play call sent, play call
    answered]. Needs numpy; falls back to `lo` plus half the call time without it."""
    try:
        import wave
        import numpy as np
    except ImportError:
        return (lo + hi) / 2
    w = wave.open(path)
    sr = w.getframerate()
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, w.getnchannels()).astype(float).mean(axis=1) / 32768
    hop = int(0.005 * sr)
    xh = np.diff(x, prepend=0)
    e = np.sqrt((xh[: len(xh) // hop * hop].reshape(-1, hop) ** 2).mean(axis=1))
    flux = np.maximum(np.diff(np.log(e + 1e-6), prepend=0), 0)
    beat = 60.0 / bpm
    best = (-1, 0.0)
    for ph in np.arange(0, beat, 0.002):
        ks = np.arange(ph, probe[1], beat)
        idx = (ks[ks > probe[0]] / 0.005).astype(int)
        score = flux[idx].sum() + flux[np.clip(idx + 1, 0, len(flux) - 1)].sum()
        if score > best[0]:
            best = (score, ph)
    cands = [best[1] + k * beat for k in range(0, 12)]
    inside = [c for c in cands if lo + 0.2 <= c <= hi + 0.4]  # Logic starts after the call is sent (measured: about 0.5 s in)
    return min(inside) if inside else lo


def one_line(text, n=96):
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= n else text[: n - 1] + "…"


def interpret(reply):
    """Best-effort one-line summary of a tools/call or resources/read reply (the log keeps the full reply)."""
    if "error" in reply:
        return "-", False, None, one_line(reply["error"].get("message", "error"))
    res = reply.get("result", {})
    text = ""
    if "contents" in res:
        text = res["contents"][0].get("text", "")
    elif "content" in res:
        text = res["content"][0].get("text", "")
    state, verified, ok = "-", None, not res.get("isError", False)
    try:
        d = json.loads(text)
    except ValueError:
        return state, ok, verified, one_line(text)
    if isinstance(d, dict):
        for k in ("state", "honest_state", "contract_state"):
            if isinstance(d.get(k), str):
                state = d[k]
        hc = d.get("honest_contract") or d.get("contract") or {}
        if isinstance(hc, dict) and isinstance(hc.get("state"), str):
            state = hc["state"]
        if "verified" in d and isinstance(d["verified"], bool):
            verified = d["verified"]
        if d.get("success") is False or d.get("ok") is False or d.get("isError"):
            ok = False
    return state, ok, verified, d


def pretty(d, uri=None):
    """One honest line for the on-screen transcript, built only from fields the server returned."""
    if not isinstance(d, dict):
        return one_line(str(d))
    inner = d.get("data")
    if uri == "logic://system/health":
        ch = [c for c in d.get("channels", []) if c.get("ready")]
        return f"{len(ch)} channels ready: " + ", ".join(c["channel"] for c in ch[:3])
    if uri == "logic://tracks" and isinstance(inner, list):
        names = ", ".join(t.get("name", "?") for t in inner[:3])
        return f"{len(inner)} tracks: {names}…"
    if uri == "logic://transport/state" and isinstance(inner, dict):
        st = inner.get("state", {})
        return f"tempo {st.get('tempo')} · bar {st.get('position')} · {'playing' if st.get('isPlaying') else 'stopped'}"
    parts = []
    if d.get("state"):
        parts.append(f"State {d['state']}")
    if d.get("verified") is True:
        parts.append("verified")
    elif d.get("verified") is False:
        parts.append("not verified")
    if "requested" in d and "observed" in d:
        def f(v):
            return f"{v:.2f}" if isinstance(v, float) else str(v)
        parts.append(f"{f(d['requested'])} → {f(d['observed'])}")
    if d.get("error"):
        parts.append(str(d["error"]))
    return " · ".join(parts) if parts else one_line(json.dumps(d))


def events_from(path, epoch0):
    evs, markers = [], {}
    for line in open(path):
        r = json.loads(line)
        if "marker" in r:
            markers[r["marker"]] = r["t_epoch"] - epoch0
            if r["marker"] == "mix_batch":
                markers["mix_batch_seconds"] = r["seconds"]
                markers["mix_batch_writes"] = r["writes"]
            continue
        p = r["params"]
        if r["method"] == "tools/call":
            call = f'{p["name"]}.{p["arguments"]["command"]}'
            args = json.dumps(p["arguments"].get("params", {}), separators=(",", ":"))
            kind = "tool"
        elif r["method"] == "resources/read":
            call, args, kind = "read", p["uri"], "read"
        else:
            continue
        state, ok, verified, d = interpret(r["reply"])
        evs.append({"t": r["t_epoch"] - epoch0, "ms": r["ms"], "kind": kind, "call": call, "args": args, "label": r.get("label") or "",
                    "state": state, "ok": ok, "verified": verified,
                    "result": d if isinstance(d, str) else pretty(d, p.get("uri")), "_raw": d if isinstance(d, dict) else None})
    return evs, markers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--video", required=True, help="the raw capture, for probing size and duration")
    ap.add_argument("--audio", required=True, help="wav extracted from the capture")
    ap.add_argument("--seq", required=True, help="footage frame sequence directory name under the footage server root")
    ap.add_argument("--seq-start", type=int, required=True, help="absolute frame number of the first image in the sequence")
    ap.add_argument("--out", required=True)
    ap.add_argument("--version", default="3.19.0")
    ap.add_argument("--logic", default="13.0 (7801)")
    ap.add_argument("--macos", default="26.3")
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--bpm", type=int, default=120)
    ap.add_argument("--bars", type=int, default=24)
    a = ap.parse_args()
    meta = json.load(open(a.meta))
    w, h, dur = probe(a.video)
    evs, markers = events_from(a.log, meta["first_frame_epoch"])
    for e in evs:
        e.pop("_raw", None)
    play = next(e for e in evs if e["call"].endswith(".play"))
    music_start = round(play_start(a.audio, a.bpm, play["t"], play["t"] + play["ms"] / 1000, probe=(20.0, 40.0)), 3)
    writes = [e for e in evs if e["kind"] == "tool" and not e["call"].endswith((".play", ".stop"))]
    lat = sorted(e["ms"] for e in writes)
    out = {"film": {"seq": a.seq, "seqStart": a.seq_start, "fps": 60, "width": w, "height": h, "durationSeconds": dur,
                    "events": evs, "markers": markers, "musicStart": music_start},
           "stats": {"writes": len(writes), "verifiedWrites": sum(1 for e in writes if e["verified"] is True),
                     "medianMs": round(statistics.median(lat), 0), "maxMs": round(lat[-1], 0), "totalCalls": len(evs)},
           "meta": {"version": a.version, "logic": a.logic, "macos": a.macos, "locale": a.locale, "bpm": a.bpm, "bars": a.bars,
                    "date": datetime.date.today().isoformat()}}
    json.dump(out, open(a.out, "w"), indent=1, ensure_ascii=False)
    print(f"wrote {a.out}: {len(evs)} calls, {len(writes)} writes, median {out['stats']['medianMs']} ms, music starts at {music_start}s")


if __name__ == "__main__":
    main()
