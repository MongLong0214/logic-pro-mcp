#!/usr/bin/env python3
"""Objective audio checks on a finished mix: loudness, true peak, clipping, silence gaps, discontinuities.

  qa_audio.py final.wav [--entrances t1,t2,...] [--lra 6,8] [--end-guard 1.5]   -> JSON report, exit 1 if a check fails

Checks (all measured, none assumed):
  * integrated loudness (EBU R128) and true peak via ffmpeg ebur128 (target -14 LUFS, true peak <= -1.0 dBTP)
  * clipping: count of samples at full scale (must be 0)
  * loudness range (EBU R128 LRA); with --lra LO,HI it must fall inside that range
  * silence gaps: any run below -60 dBFS longer than 0.35 s anywhere from the first sample (no opening exemption);
    only the last --end-guard seconds (the intentional closing fade) are exempt
  * entrance steps: with --entrances t[:t_done],..., the RMS level of the 2 s from t_done (the server confirmed the fader at its
    value; t_done = t if omitted) minus the 2 s before t, when the request was sent (must be >= 3 dB)
  * clicks: sample-to-sample jumps far outside the signal's own distribution (reported, must be 0 over 6 sigma-of-diff x 40)
"""
import json
import re
import subprocess
import sys
import wave

import numpy as np


def opt(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    path = sys.argv[1]
    end_guard = float(opt("--end-guard", "1.5"))
    entrances = [tuple(float(u) for u in v.split(":")) if ":" in v else (float(v), float(v)) for v in opt("--entrances", "").split(",") if v.strip()]
    lra_range = [float(v) for v in opt("--lra").split(",")] if opt("--lra") else None
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True)
    tail = r.stderr[r.stderr.rfind("Summary:"):]
    lufs = float(re.search(r"I:\s+(-?[0-9.]+) LUFS", tail).group(1))
    lra = float(re.search(r"LRA:\s+(-?[0-9.]+) LU", tail).group(1))
    tp = float(re.search(r"Peak:\s+(-?[0-9.]+) dBFS", tail).group(1))
    with wave.open(path) as w:
        sr, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    dt = {2: np.int16, 4: np.int32}[sw] if sw in (2, 4) else None
    if sw == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        x = ((b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16)) << 8 >> 8).astype(np.float64) / 2 ** 23
        x = x.reshape(-1, ch)
    else:
        x = np.frombuffer(raw, dtype=dt).reshape(-1, ch).astype(np.float64) / np.iinfo(dt).max
    clipped = int(np.sum(np.abs(x) >= 0.9999))
    mono = np.abs(x).max(axis=1)
    win = int(0.05 * sr)
    n = len(mono) // win
    rms_db = 20 * np.log10(np.sqrt((mono[: n * win].reshape(n, win) ** 2).mean(axis=1)) + 1e-9)
    quiet = rms_db < -60
    gaps, run = [], 0
    for i, q in enumerate(quiet):
        run = run + 1 if q else 0
        if run * 0.05 > 0.35 and (i + 1 == n or not quiet[i + 1]):
            gaps.append(round((i - run + 1) * 0.05, 2))
    gaps = [g for g in gaps if g < len(x) / sr - end_guard]  # only the closing fade may reach silence
    d = np.abs(np.diff(x, axis=0)).max(axis=1)
    thr = 40 * (np.std(d) + 1e-9)
    clicks = int(np.sum(d > max(thr, 0.5)))
    def rms(a, b):
        seg = x[max(0, int(a * sr)): max(0, int(b * sr))]
        return 20 * np.log10(np.sqrt(np.mean(seg ** 2)) + 1e-9) if len(seg) else -120.0
    steps = [{"t": t, "t_done": td, "before_db": round(rms(t - 2, t), 1), "after_db": round(rms(td, td + 2), 1),
              "step_db": round(rms(td, td + 2) - rms(t - 2, t), 1)} for t, td in entrances]
    rep = {"integrated_lufs": lufs, "loudness_range_lu": lra, "true_peak_dbtp": tp, "clipped_samples": clipped,
           "silence_gaps_start_s": gaps, "end_guard_s": end_guard, "click_candidates": clicks, "duration_s": round(len(x) / sr, 2),
           "entrance_steps": steps}
    ok = abs(lufs + 14) <= 1.0 and tp <= -1.0 and clipped == 0 and not gaps and clicks == 0
    ok = ok and all(s_["step_db"] >= 3.0 for s_ in steps)
    if lra_range:
        rep["lra_range"] = lra_range
        ok = ok and lra_range[0] <= lra <= lra_range[1]
    rep["pass"] = bool(ok)
    print(json.dumps(rep, indent=1))
    sys.exit(0 if rep["pass"] else 1)


if __name__ == "__main__":
    main()
