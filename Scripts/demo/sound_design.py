#!/usr/bin/env python3
"""Procedural sound design for the film (numpy only, deterministic, royalty-free because it is generated here).

Hits are tuned to the song's key (A minor): dings are A5/E6, the boom is A1. The sound-design bus is mixed 14-18 dB
under the music bed, so it punctuates scene changes without masking the song.

  sound_design.py --cues cues.json --bed bed.wav --out mix.wav [--social]

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


KINDS = {"whoosh": (whoosh, -17.0), "tick": (tick, -26.0), "ding": (ding, -19.0), "riser": (riser, -20.0), "boom": (boom, -17.0)}


def place(fx, s, t, total):
    i = int(max(0, t) * SR)
    end = min(total, i + len(s))
    if end > i:
        fx[i:end] += s[: end - i]


def main():
    global SR
    ap = argparse.ArgumentParser()
    ap.add_argument("--cues", required=True)
    ap.add_argument("--bed", required=True, help="wav of Logic's output starting on bar 1")
    ap.add_argument("--out", required=True)
    ap.add_argument("--sr", type=int, default=48000)
    ap.add_argument("--social", action="store_true", help="assemble the social cut from bar-line excerpts of the same song")
    a = ap.parse_args()
    SR = a.sr
    cues = json.load(open(a.cues))
    P = cues["P"]
    with wave.open(a.bed) as w:
        assert w.getframerate() == SR and w.getnchannels() == 2
        raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2).astype(np.float64) / 32768
    rng = np.random.default_rng(7)
    sfx = cues["sfx"]
    if a.social:
        segs = cues["social"]["segments"]
        total = int(cues["social"]["total"] * SR)
        bed = np.zeros((total, 2))
        keep = []
        for seg in segs:
            s0 = int(seg["s0"] * SR)
            if seg["kind"] == "song":
                n = int(seg["len"] * SR)
                src = raw[int(seg["from"] * SR): int(seg["from"] * SR) + n].copy()
                src = np.pad(src, ((0, n - len(src)), (0, 0)))
                f = int(0.012 * SR)  # 12 ms edge fades: bar-line cuts, no clicks
                src[:f] *= np.linspace(0, 1, f)[:, None]
                src[-f:] *= np.linspace(1, 0, f)[:, None]
                bed[s0: s0 + n] += src
            lo, hi = (0, P) if seg["kind"] == "pre" else (P + seg["from"], P + seg["from"] + seg["len"])
            keep += [[seg["s0"] + (t - lo), k] for t, k in sfx if lo <= t < hi]
        keep += [[seg["s0"] - 0.05, "whoosh"] for seg in segs[1:]]
        sfx = keep
        bed[-int(1.0 * SR):] *= np.linspace(1, 0, int(1.0 * SR))[:, None] ** 1.5
    else:
        total = int(cues["total"] * SR)
        bed = np.zeros((total, 2))
        off = int(P * SR)
        n = min(total - off, len(raw))
        bed[off: off + n] = raw[:n]
        fade = int(1.8 * SR)
        bed[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 1.5
    rms = np.sqrt(np.mean(raw[int(8 * SR): int(40 * SR)] ** 2) + 1e-12)
    fx = np.zeros_like(bed)
    for t, kind in sfx:
        fn, db = KINDS[kind]
        sound = fn(rng)
        sound = sound / (np.max(np.abs(sound)) + 1e-9) * rms * 10 ** (db / 20) * 4.0
        place(fx, sound, t, total)
    out = bed + fx
    peak = np.max(np.abs(out))
    if peak > 0.95:
        out *= 0.95 / peak
    pcm = (np.clip(out, -1, 1) * 32767).astype(np.int16)
    with wave.open(a.out, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    print(f"wrote {a.out}: {total / SR:.2f}s, bed rms {20 * np.log10(rms):.1f} dBFS, {len(sfx)} hits")


if __name__ == "__main__":
    main()
