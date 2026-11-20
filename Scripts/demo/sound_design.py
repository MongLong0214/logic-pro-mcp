#!/usr/bin/env python3
"""Procedural sound design for the film (numpy only, deterministic, royalty-free because it is generated here).

Hits are tuned to the song's key (A minor): dings are A5/E6, the boom is A1. The sound-design bus is mixed 14-18 dB
under the music bed, so it punctuates scene changes without masking the song.

  sound_design.py --cues cues.json --bed bed.wav --out mix.wav [--sr 48000] [--social]

cues.json is the output of motion/scripts/export-cues.mjs. bed.wav is Logic's own output of the song (take B),
already trimmed to start on the first note.
"""
import argparse
import json
import wave

import numpy as np

SR = 48000


def env(n, a, d):
    t = np.arange(n) / SR
    return np.minimum(1, t / max(a, 1e-4)) * np.exp(-t / d)


def lp(x, cutoff):
    """One-pole low-pass with a per-sample cutoff array (Hz)."""
    a = 1 - np.exp(-2 * np.pi * cutoff / SR)
    y = np.zeros_like(x)
    s = 0.0
    for i in range(len(x)):
        s += a[i] * (x[i] - s)
        y[i] = s
    return y


def stereo(x, spread=0.0):
    return np.stack([x, np.roll(x, int(spread * SR))], axis=1)


def whoosh(rng, dur=0.9):
    n = int(dur * SR)
    noise = rng.standard_normal(n)
    t = np.linspace(0, 1, n)
    cutoff = 250 * (28 ** np.sin(np.pi * t) ** 0.8)  # 250 Hz -> ~7 kHz -> back
    x = lp(lp(noise, cutoff), cutoff * 1.2)
    x -= lp(x, np.full(n, 140.0))  # remove the rumble
    shape = np.sin(np.pi * t) ** 2.2
    return stereo(x * shape * 0.9, 0.0007)


def tick(rng):
    n = int(0.09 * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * 2600 * t) * np.exp(-t / 0.012) + 0.4 * np.sin(2 * np.pi * 5200 * t) * np.exp(-t / 0.006)
    return stereo(x * 0.8)


def ding(rng):
    n = int(1.6 * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for f, g in ((880.0, 1.0), (1318.5, 0.5), (1760.0, 0.25), (2637.0, 0.12)):
        x += g * np.sin(2 * np.pi * f * t) * np.exp(-t / (0.55 / (1 + 0.5 * (f / 880 - 1))))
    x *= np.minimum(1, t / 0.003)
    return stereo(x * 0.45, 0.0004)


def riser(rng, dur=0.9):
    n = int(dur * SR)
    t = np.linspace(0, 1, n)
    noise = rng.standard_normal(n)
    cutoff = 300 + 9000 * t ** 2.2
    x = lp(noise, cutoff)
    x -= lp(x, np.full(n, 200.0))
    tone = np.sin(2 * np.pi * np.cumsum(220 * 2 ** (2 * t)) / SR) * 0.25
    return stereo((x * 0.8 + tone) * t ** 1.8 * 0.9, 0.0009)


def boom(rng):
    n = int(2.2 * SR)
    t = np.arange(n) / SR
    f = 55 * np.exp(-t * 1.1) + 33
    sub = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.7)
    burst = lp(rng.standard_normal(n), np.full(n, 900.0)) * np.exp(-t / 0.08) * 0.5
    return stereo((sub + burst) * 0.9)


KINDS = {"whoosh": (whoosh, -17.0), "tick": (tick, -20.0), "ding": (ding, -19.0), "riser": (riser, -18.0), "boom": (boom, -14.0)}


def main():
    global SR
    ap = argparse.ArgumentParser()
    ap.add_argument("--cues", required=True)
    ap.add_argument("--bed", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--sr", type=int, default=48000)
    ap.add_argument("--social", action="store_true", help="assemble the 26 s social cut from excerpts of the same song")
    a = ap.parse_args()
    SR = a.sr
    cues = json.load(open(a.cues))
    with wave.open(a.bed) as w:
        assert w.getframerate() == SR and w.getnchannels() == 2
        raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2).astype(np.float64) / 32768
    if a.social:
        soc = cues["social"]
        total = int(soc["total"] * SR)
        bed = np.zeros((total, 2))
        xf = int(0.35 * SR)
        for name in ("hook", "reveal", "drop", "close"):
            (v0, v1), a0 = soc[name]["v"], soc[name]["a"]
            i0, i1 = int(v0 * SR), int(v1 * SR)
            seg = raw[int(a0 * SR): int(a0 * SR) + (i1 - i0)].copy()
            seg = np.pad(seg, ((0, (i1 - i0) - len(seg)), (0, 0)))
            if v0 > 0:  # equal-power crossfade into the previous excerpt, which keeps playing underneath
                ramp = np.sin(np.linspace(0, np.pi / 2, xf))[:, None]
                seg[:xf] *= ramp
                bed[i0 - xf // 2: i0 - xf // 2 + xf] *= np.cos(np.linspace(0, np.pi / 2, xf))[:, None]
                seg_pre = raw[int(a0 * SR) - xf // 2: int(a0 * SR)] * ramp[: xf // 2]
                bed[i0 - xf // 2: i0] += seg_pre
            bed[i0:i1] = np.where(np.abs(bed[i0:i1]) > 0, bed[i0:i1] + seg, seg)
        cues = dict(cues, sfx=[[soc[n]["v"][0] - 0.05, "whoosh"] for n in ("reveal", "drop", "close")] + [[soc["reveal"]["v"][0] + 0.6, "boom"]])
    else:
        total = int(cues["total"] * SR)
        bed = np.zeros((total, 2))
        bed[: min(total, len(raw))] = raw[:total]
    # fade the bed's very end so the last ring decays to silence instead of cutting
    fade = int(1.8 * SR)
    bed[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 1.5
    rms = np.sqrt(np.mean(bed[: int(60 * SR)] ** 2) + 1e-12)
    rng = np.random.default_rng(7)
    fx = np.zeros_like(bed)
    for t, kind in cues["sfx"]:
        fn, db = KINDS[kind]
        s = fn(rng)
        s = s / (np.max(np.abs(s)) + 1e-9) * rms * 10 ** (db / 20) * 4.0
        i = int(max(0, t) * SR)
        end = min(total, i + len(s))
        fx[i:end] += s[: end - i]
    out = bed + fx
    peak = np.max(np.abs(out))
    if peak > 0.95:
        out *= 0.95 / peak
    pcm = (np.clip(out, -1, 1) * 32767).astype(np.int16)
    with wave.open(a.out, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    print(f"wrote {a.out}: {total / SR:.2f}s, bed rms {20 * np.log10(rms):.1f} dBFS, {len(cues['sfx'])} hits")


if __name__ == "__main__":
    main()
