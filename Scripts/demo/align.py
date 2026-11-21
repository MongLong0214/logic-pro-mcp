#!/usr/bin/env python3
"""Turn the driver log + capture metadata into motion/public/data/session.json (the film's only data input).

  align.py --log out/film.jsonl --meta raw/film.meta.json --video raw/film.mov --audio raw/film.audio.wav \
           --seq film --frames N --out motion/public/data/session.json

meta.json holds {"first_frame_epoch": <epoch of footage t=0>} printed by LogicCapture on start. Everything the film
shows about timing is derived from wall-clock stamps written at the moment of each call, on the take clock (seconds
from the first captured frame). Before -> after values come from what the server itself reported (`observed_before`
and `observed` on every mixer write; the transport read just before the tempo write), never from what was requested.
"""
import argparse
import datetime
import json
import re
import statistics
import subprocess


def probe(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "stream=width,height:format=duration", "-of", "json", path])
    d = json.loads(out)
    return d["streams"][0]["width"], d["streams"][0]["height"], float(d["format"]["duration"])


def bar_one(path, bpm, lo, hi, probe_window):
    """Take seconds at which bar 1 begins: the beat grid is fitted to the drum transients of the full groove (kicks sit
    on every beat), then taken as the first grid position inside [play call sent, play call answered + 0.4]."""
    import wave
    import numpy as np
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
        ks = np.arange(ph, probe_window[1], beat)
        idx = (ks[ks > probe_window[0]] / 0.005).astype(int)
        score = flux[idx].sum() + flux[np.clip(idx + 1, 0, len(flux) - 1)].sum()
        if score > best[0]:
            best = (score, ph)
    cands = [best[1] + k * beat for k in range(0, 40)]
    inside = [c for c in cands if lo + 0.2 <= c <= hi + 0.4]  # Logic starts after the call is sent (about 0.5 s in)
    return min(inside) if inside else lo + 0.5


def one_line(text, n=96):
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= n else text[: n - 1] + "…"


def reply_json(reply):
    res = reply.get("result", {})
    text = ""
    if "contents" in res:
        text = res["contents"][0].get("text", "")
    elif "content" in res:
        text = res["content"][0].get("text", "")
    try:
        return json.loads(text), text, bool(res.get("isError"))
    except ValueError:
        return None, text, bool(res.get("isError"))


def fnum(v):
    if isinstance(v, bool) or v is None:
        return v
    return round(float(v), 2) if isinstance(v, (int, float)) else v


def build_events(path, epoch0, tracks):
    evs, markers, last_tempo = [], {}, None
    for line in open(path):
        r = json.loads(line)
        if "marker" in r:
            markers[r["marker"]] = r["t_epoch"] - epoch0
            continue
        p = r["params"]
        d, text, is_err = reply_json(r["reply"])
        d = d if isinstance(d, dict) else {}
        label = r.get("label") or ""
        e = {"t": r["t_epoch"] - epoch0, "t_end": r["t_end_epoch"] - epoch0, "ms": r["ms"], "label": label, "ok": not is_err and "error" not in r["reply"],
             "state": "-", "verified": None, "target": None, "track": None, "track_name": None, "what": None,
             "before": None, "after": None, "requested": None, "noop": False, "summary": "", "result": ""}
        if r["method"] == "tools/call":
            tool, cmd = p["name"], p["arguments"]["command"]
            args = p["arguments"].get("params", {})
            e.update(kind="tool", call=f"{tool}.{cmd}", params=args)
            e["state"] = d.get("state", "-")
            e["verified"] = d.get("verified")
            e["ok"] = e["ok"] and d.get("success", True) is not False
            if tool == "logic_mixer":
                idx = args["track"]
                e["track"], e["track_name"] = idx, tracks[idx]
                ctl = d.get("control") or ("volume" if cmd == "set_volume" else "pan")
                e["what"] = f"{tracks[idx]} {'fader' if ctl == 'volume' else 'pan'}"
                e["requested"] = args.get("value")
                e["before"], e["after"] = fnum(d.get("observed_before")), fnum(d.get("observed"))
                e["noop"] = e["before"] is not None and e["after"] is not None and abs(e["after"] - e["before"]) < 0.015
                e["summary"] = f"{ctl} {e['before']} → {e['after']}"
            elif cmd == "set_tempo":
                e["what"] = "Tempo"
                e["requested"] = args.get("tempo")
                e["before"], e["after"] = last_tempo, fnum(d.get("observed"))
                e["summary"] = f"tempo {e['before']} → {e['after']}"
            elif cmd in ("play", "stop"):
                e["what"] = "Transport"
                if cmd == "play":
                    b, a = d.get("observed_before", {}), d.get("observed_after", {})
                    e["summary"] = f"isPlaying {b.get('isPlaying')} → {a.get('isPlaying')}"
                else:
                    e["summary"] = f"isPlaying → {d.get('observed_isPlaying')}, position {d.get('observed_position')}"
            e["result"] = one_line(f"State {e['state']}" + (" · verified" if e["verified"] else ""))
        else:
            uri = p["uri"]
            e.update(kind="read", call="read", params={"uri": uri}, target=uri.replace("logic://", ""))
            data = d.get("data")
            if uri == "logic://tracks" and isinstance(data, list):
                e["summary"] = f"{len(data)} tracks: " + ", ".join(t.get("name", "?") for t in data)
                e["tracks"] = [{"name": t.get("name"), "volume": fnum(t.get("volume")), "pan": fnum(t.get("pan")), "armed": t.get("isArmed")} for t in data]
                e["cache_age_sec"] = d.get("cache_age_sec")
                e["readable"] = d.get("readable")
            elif uri == "logic://transport/state" and isinstance(data, dict):
                st = data.get("state", {})
                last_tempo = st.get("tempo", last_tempo)
                e["summary"] = f"tempo {st.get('tempo')} · {'playing' if st.get('isPlaying') else 'stopped'}"
                e["tempo"] = st.get("tempo")
            elif uri == "logic://system/health":
                e["summary"] = "channels ready"
            e["result"] = e["summary"]
        evs.append(e)
    return evs, markers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--video", required=True, help="the raw capture, for probing size and duration")
    ap.add_argument("--audio", required=True, help="wav extracted from the capture")
    ap.add_argument("--seq", required=True, help="footage frame sequence directory name under the footage server root")
    ap.add_argument("--frames", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--arrangement", default="music/out/arrangement.json")
    ap.add_argument("--version", default="3.19.0")
    ap.add_argument("--logic", default="13.0 (7801)")
    ap.add_argument("--macos", default="26.3")
    ap.add_argument("--locale", default="en-US")
    a = ap.parse_args()
    meta = json.load(open(a.meta))
    arr = json.load(open(a.arrangement))
    w, h, dur = probe(a.video)
    evs, markers = build_events(a.log, meta["first_frame_epoch"], arr["track_order"])
    play = next(e for e in evs if e["call"].endswith(".play"))
    stop = next(e for e in evs if e["call"].endswith(".stop"))
    # drums enter at bar 7 (12 s after bar 1) and play to the stop: fit the grid inside that stretch
    music_start = round(bar_one(a.audio, arr["bpm"], play["t"], play["t"] + play["ms"] / 1000, (play["t"] + 14.0, stop["t"] - 1.0)), 3)
    writes = [e for e in evs if e["kind"] == "tool" and not e["call"].endswith((".play", ".stop"))]
    real = [e for e in writes if not e["noop"]]
    lat = sorted(e["ms"] for e in real)
    final_read = [e for e in evs if e["kind"] == "read" and e["target"] == "tracks" and e["label"].startswith("read: tracks after")][-1]
    # what the last write to each control reported vs what the independent read-back says
    check = []
    for ti, name in enumerate(arr["track_order"]):
        row = next(t for t in final_read["tracks"] if t["name"] == name)
        for ctl, key in (("volume", "volume"), ("pan", "pan")):
            ws = [e for e in writes if e["track"] == ti and e["call"].endswith("set_volume" if ctl == "volume" else "set_pan")]
            if ws:
                check.append({"track": name, "control": ctl, "written": ws[-1]["after"], "read": row[key], "match": abs(ws[-1]["after"] - row[key]) < 0.015})
    out = {"film": {"seq": a.seq, "fps": 60, "width": w, "height": h, "durationSeconds": dur, "frames": a.frames,
                    "events": evs, "markers": markers, "musicStart": music_start, "playAt": play["t"], "stopAt": stop["t_end"]},
           "readback": {"at": final_read["t"], "tracks": final_read["tracks"], "ageSec": final_read.get("cache_age_sec"), "checks": check},
           "stats": {"calls": len(evs), "writes": len(writes), "realWrites": len(real), "noopWrites": len(writes) - len(real),
                     "verifiedRealWrites": sum(1 for e in real if e["verified"] is True),
                     "medianMs": round(statistics.median(lat)), "maxMs": round(lat[-1]), "minMs": round(lat[0])},
           "meta": {"version": a.version, "logic": a.logic, "macos": a.macos, "locale": a.locale, "bpm": arr["bpm"], "bars": arr["bars"],
                    "date": datetime.date.today().isoformat()}}
    json.dump(out, open(a.out, "w"), indent=1, ensure_ascii=False)
    print(f"wrote {a.out}: {len(evs)} calls, {len(real)} real writes ({len(writes) - len(real)} no-ops), median {out['stats']['medianMs']} ms, "
          f"bar 1 at {music_start}s, readback matches {sum(c['match'] for c in check)}/{len(check)}")


if __name__ == "__main__":
    main()
