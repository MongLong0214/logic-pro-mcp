#!/usr/bin/env python3
"""Claude Code take -> motion/public/data/session.json (the v3 film's only data input).

  align_claude.py --tap out/claude-take.mcp.jsonl --prompts out/prompts.jsonl --meta raw/take.meta.json \
                  --take raw/take.mov --client raw/client.mov --audio raw/take.audio.wav \
                  --take-seq take --client-seq client --seq-start N --out motion/public/data/session.json

Everything on screen about a call is taken from the tap log (mcp_tap.py), which holds every JSON-RPC line between
Claude Code and the server with the wall-clock time the tap saw it. Times are put on one clock: seconds since the
first frame of the Logic capture. Values are shown as before -> after, where "before" is the server's own
`observed_before` (fader, pan) or, for the tempo, the tempo the server last read before the call. A write whose before
and after agree is flagged `noop` and is kept out of the latency statistics. stats.commands counts every command that
changed Logic (mixer and tempo writes plus play and stop); stats.realWrites keeps the mixer and tempo writes alone.
"""
import argparse
import datetime
import json
import statistics

from align import probe


def beat_grid_start(path, bpm, lo, hi, probe_win):
    """Footage seconds at which bar 1 sounded. The beat grid is fitted to the kick drum (on every beat) inside
    probe_win, then the first grid beat inside [lo + 0.2, hi + 0.6] = [play sent, play answered] is bar 1."""
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
    best = (-1.0, 0.0)
    for ph in np.arange(0, beat, 0.002):
        ks = np.arange(ph, probe_win[1], beat)
        idx = (ks[ks > probe_win[0]] / 0.005).astype(int)
        idx = idx[idx < len(flux) - 1]
        score = flux[idx].sum() + flux[idx + 1].sum()
        if score > best[0]:
            best = (score, ph)
    k = np.ceil((lo + 0.2 - best[1]) / beat)
    first = best[1] + k * beat
    return float(first) if first <= hi + 0.6 else float(lo), float(best[1])

TRACKS = ["Keys", "Pad", "Bass", "Drums", "Lead"]


def reply_text(msg):
    res = msg.get("result", {}) if isinstance(msg, dict) else {}
    for key in ("content", "contents"):
        if res.get(key):
            return res[key][0].get("text", "")
    if "error" in msg:
        return json.dumps(msg["error"])
    return ""


def parse(text):
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return None


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def pan_label(v):
    if v is None:
        return "?"
    p = round(v * 63.5 + 63.5) - 64  # the server's -1..1 is Logic's raw 0..127; Logic shows raw - 64, centre raw 64 as C
    return "C" if p == 0 else (f"L{-p}" if p < 0 else f"R{p}")


def tempo_of(d):
    if not isinstance(d, dict):
        return None
    if num(d.get("observed_tempo")) is not None:
        return d["observed_tempo"]
    st = (d.get("data") or {}).get("state") if isinstance(d.get("data"), dict) else None
    return num(st.get("tempo")) if isinstance(st, dict) else None


def track_values(rows):
    """Compact read-back of every track: name, fader, pan (Logic's own pan notation)."""
    out = []
    for t in rows:
        v, p = num(t.get("volume")), num(t.get("pan"))
        out.append(f"{t.get('name', '?')} {v:.2f} {pan_label(p)}" if v is not None and p is not None else str(t.get("name", "?")))
    return " · ".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tap", required=True)
    ap.add_argument("--prompts", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--take", required=True)
    ap.add_argument("--client", required=True)
    ap.add_argument("--audio", required=True)
    ap.add_argument("--take-seq", default="take")
    ap.add_argument("--client-seq", default="client")
    ap.add_argument("--seq-start", type=int, default=0, help="first frame number of both JPEG sequences")
    ap.add_argument("--reset-tempo", type=float, default=90.0, help="tempo the reset left (from out/reset.jsonl)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--version", default="3.19.0")
    ap.add_argument("--logic", default="13.0 (7801)")
    ap.add_argument("--macos", default="26.3")
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--client-name", default="Claude Code")
    ap.add_argument("--client-model", default="")
    ap.add_argument("--bpm", type=int, default=120)
    ap.add_argument("--keep-prompts", type=int, default=0,
                    help="end the film after this many requests: later requests and their calls are left out (and listed in session.json)")
    a = ap.parse_args()
    meta = json.load(open(a.meta))
    e0 = meta["take"]
    rows = [json.loads(l) for l in open(a.tap) if l.strip()]
    req, rep = {}, {}
    for r in rows:
        m = r.get("msg")
        if not isinstance(m, dict) or "id" not in m:
            continue
        (req if r["dir"] == "c2s" else rep)[m["id"]] = (r["t_epoch"], m)
    names = list(TRACKS)
    tempo_known = a.reset_tempo
    playing = False
    evs = []
    for mid, (t_send, m) in sorted(req.items(), key=lambda kv: kv[1][0]):
        if m.get("method") not in ("tools/call", "resources/read") or mid not in rep:
            continue
        t_rep, rm = rep[mid]
        text = reply_text(rm)
        d = parse(text)
        ev = {"t": round(t_send - e0, 3), "t_end": round(t_rep - e0, 3), "ms": round((t_rep - t_send) * 1000, 1)}
        if m["method"] == "resources/read":
            uri = m["params"]["uri"]
            ev.update(kind="read", call="read", target=uri.replace("logic://", ""), ok="error" not in rm)
            if uri == "logic://tracks" and isinstance(d, dict) and isinstance(d.get("data"), list) and d["data"]:
                names = [t.get("name", "?") for t in d["data"]]
                ev["summary"] = track_values(d["data"])
                ev["cache_age_s"] = d.get("cache_age_sec")
            elif uri == "logic://transport/state":
                t_ = tempo_of(d)
                if t_ is not None:
                    tempo_known = t_
                st = (d or {}).get("data", {}).get("state", {}) if isinstance(d, dict) else {}
                ev["summary"] = f"tempo {st.get('tempo')} · bar {st.get('position')} · {'playing' if st.get('isPlaying') else 'stopped'}"
                ev["metronome"] = st.get("isMetronomeEnabled")
            elif uri == "logic://mixer" and isinstance(d, dict) and "strips" in d:
                n_ = len(d["strips"] or [])
                ev["summary"] = f"{n_} strips returned · {str(d.get('data_source', '?')).replace('_', ' ')}"
            else:
                ev["summary"] = (text[:80] + "…") if len(text) > 80 else text
            evs.append(ev)
            continue
        args = m["params"].get("arguments", {})
        tool, cmd, params = m["params"]["name"], args.get("command", ""), args.get("params", {}) or {}
        d = d if isinstance(d, dict) else {}
        if d.get("read_only") is True:  # a read-only tool (e.g. logic_project.inspect_session): shown as a read, not a write
            rows_ = ((d.get("tracks") or {}).get("rows")) or []
            if rows_:
                names = [r_.get("name", "?") for r_ in sorted(rows_, key=lambda r_: r_.get("track_index", 0))]
            ev.update(kind="read", call=f"{tool}.{cmd}", target="session", ok="error" not in rm,
                      summary=(f"{len(rows_)} tracks: " + ", ".join(names)) if rows_ else cmd)
            evs.append(ev)
            continue
        state = d.get("state", "-")
        ok = not rm.get("result", {}).get("isError", False) and "error" not in rm and d.get("success") is not False
        ev.update(kind="tool", call=f"{tool}.{cmd}", params=params, state=state, ok=ok, verified=d.get("verified"))
        track = params.get("track", params.get("index"))
        ev["track"] = track
        ev["track_name"] = names[track] if isinstance(track, int) and 0 <= track < len(names) else None
        before = after = None
        if cmd in ("set_volume", "set_pan"):
            before, after = num(d.get("observed_before")), num(d.get("observed_after", d.get("observed")))
            fmt = (lambda v: f"{v:.2f}") if cmd == "set_volume" else pan_label
            ev["what"] = f"{ev['track_name']} {'fader' if cmd == 'set_volume' else 'pan'}"
            ev["before_after"] = f"{fmt(before) if before is not None else '?'} → {fmt(after) if after is not None else '?'}"
        elif cmd == "set_tempo":
            before, after = tempo_known, num(d.get("observed"))
            if after is not None:
                tempo_known = after
            ev["what"] = "Tempo"
            ev["before_after"] = f"{before:g} → {after:g}" if before is not None and after is not None else "?"
        elif cmd in ("play", "stop"):
            ob, oa = d.get("observed_before") or {}, d.get("observed_after") or {}
            was = ob.get("isPlaying", playing)  # stop's reply has no before: the last observed transport state
            now_ = oa.get("isPlaying", d.get("observed_isPlaying"))
            if isinstance(now_, bool):
                playing = now_
            ev["what"] = "Transport"
            after_txt = "not confirmed" if now_ is None else ("playing" if now_ else "stopped")
            ev["before_after"] = f"{'playing' if was else 'stopped'} → {after_txt}"
        ev["before"], ev["after"] = before, after
        ev["noop"] = before is not None and after is not None and abs(before - after) < 1e-3
        ev["result"] = f"State {state}" + (" · verified" if d.get("verified") else "") + (f" · {d.get('error')}" if d.get("error") else "")
        evs.append(ev)
    prompts = []
    for l in open(a.prompts):
        if l.strip():
            p = json.loads(l)
            prompts.append({"text": p["prompt"], "t_start": round(p["t_start"] - e0, 3), "t_enter": round(p["t_enter"] - e0, 3), "t_idle": round(p["t_idle"] - e0, 3)})
    omitted = []
    if a.keep_prompts and a.keep_prompts < len(prompts):
        cut = prompts[a.keep_prompts - 1]["t_idle"]
        omitted = [{"prompt": p["text"], "calls": [e["call"] + (f" ({e.get('state')})" if e.get("state") else "") for e in evs if e["t"] >= p["t_start"]]}
                   for p in prompts[a.keep_prompts:]]
        prompts = prompts[: a.keep_prompts]
        evs = [e for e in evs if e["t"] <= cut]
    tw, th, tdur = probe(a.take)
    cw, ch, cdur = probe(a.client)
    play = next((e for e in evs if e["kind"] == "tool" and e["call"].endswith(".play")), None)
    stop = next((e for e in evs if e["kind"] == "tool" and e["call"].endswith(".stop")), None)
    drums = next((e for e in evs if e["kind"] == "tool" and e["call"].endswith("set_volume") and e.get("track_name") == "Drums" and not e["noop"]), None)
    music = None
    if play:
        win = ((drums["t_end"] + 0.5) if drums else play["t"] + 2, (stop["t"] - 0.2) if stop else tdur - 1)
        music, phase = beat_grid_start(a.audio, a.bpm, play["t"], play["t_end"], win)
        music = round(music, 3)
    writes = [e for e in evs if e["kind"] == "tool" and not e["call"].endswith((".play", ".stop"))]
    real = [e for e in writes if not e["noop"] and e["ok"]]
    lat = sorted(e["ms"] for e in real)
    # every command Claude sent that changed Logic: the mixer and tempo writes plus play and stop (the proof card counts these)
    cmds = [e for e in evs if e["kind"] == "tool" and e["ok"] and not e["noop"]]
    clat = sorted(e["ms"] for e in cmds)
    out = {"film": {"fps": 60, "seqStart": a.seq_start,
                    "take": {"seq": a.take_seq, "width": tw, "height": th, "duration": tdur},
                    "client": {"seq": a.client_seq, "width": cw, "height": ch, "duration": cdur, "offset": round(meta["client"] - e0, 3)},
                    "events": evs, "prompts": prompts, "musicStart": music,
                    "playAt": play["t"] if play else None, "stopAt": stop["t_end"] if stop else None, "omitted": omitted},
           "stats": {"calls": len(evs), "writes": len(writes), "realWrites": len(real), "noopWrites": sum(1 for e in writes if e["noop"]),
                     "verifiedRealWrites": sum(1 for e in real if e.get("verified") is True and e.get("state") == "A"),
                     "commands": len(cmds), "commandsVerified": sum(1 for e in cmds if e.get("verified") is True and e.get("state") == "A"),
                     "commandsMedianMs": round(statistics.median(clat)) if clat else None,
                     "medianMs": round(statistics.median(lat)) if lat else None, "maxMs": round(lat[-1]) if lat else None,
                     "minMs": round(lat[0]) if lat else None},
           "meta": {"version": a.version, "logic": a.logic, "macos": a.macos, "locale": a.locale, "bpm": a.bpm,
                    "client": a.client_name, "model": a.client_model, "date": datetime.date.today().isoformat()}}
    json.dump(out, open(a.out, "w"), indent=1, ensure_ascii=False)
    s = out["stats"]
    print(f"wrote {a.out}: {s['calls']} calls, {s['writes']} writes ({s['noopWrites']} no-op), median of {s['realWrites']} real writes "
          f"{s['medianMs']} ms, music starts at {music}s, stop at {out['film']['stopAt']}")


if __name__ == "__main__":
    main()
