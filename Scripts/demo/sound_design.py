#!/usr/bin/env python3
"""The film's soundtrack: Logic's own output from the take, plus procedural sound design (numpy only, deterministic,
royalty-free because it is generated here).

  sound_design.py --cues work/cues.json --take raw/take.audio.wav --out work/mix.wav [--social]

The bed is the take's audio at 1.0x from the film's first frame, so every change heard happens when it is seen.
Logic plays nothing until Claude starts playback, and nothing after Claude stops it, so two generated layers keep the
film from ever going silent, both in the song's key (A minor):
  * an ambient bed (A2/E3/C4/E4) under the opening, fading out as Logic's own pad comes up;
  * an outro swell (Am7) from the stop into the end card, fading to silence at the very end.
Hits: ticks when Logic answers a call (very low), a riser into the drop, whooshes into the cards, a boom on the end
card. The sound-design bus sits 14-26 dB under the music.
"""
import argparse
import json
import wave

import numpy as np

SR = 48000


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
    t = np.linspace(0, 1, n)
    cutoff = 250 * (28 ** np.sin(np.pi * t) ** 0.8)
    x = lp(lp(rng.standard_normal(n), cutoff), cutoff * 1.2)
    x -= lp(x, np.full(n, 140.0))
    return stereo(x * np.sin(np.pi * t) ** 2.2 * 0.9, 0.0007)


def tick(rng):
    n = int(0.07 * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * 2200 * t) * np.exp(-t / 0.010)
    return stereo(x * 0.6)


def riser(rng, dur=0.9):
    n = int(dur * SR)
    t = np.linspace(0, 1, n)
    x = lp(rng.standard_normal(n), 300 + 9000 * t ** 2.2)
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


def chord(rng, dur, notes, attack, release_at, release):
    """A soft detuned-saw pad, low-passed: the generated layers that fill where Logic is silent."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for k, midi in enumerate(notes):
        f = 440.0 * 2 ** ((midi - 69) / 12)
        for det in (-0.06, 0.0, 0.07):
            ph = rng.uniform(0, 1)
            x += ((f * (1 + det / 100) * t + ph) % 1.0 * 2 - 1) / (1 + k * 0.3)
    x = lp(x, np.full(n, 1400.0) + 400 * np.sin(2 * np.pi * 0.11 * t))
    env = np.minimum(1, t / max(attack, 1e-3))
    if release_at is not None:
        env *= np.clip(1 - (t - release_at) / release, 0, 1) ** 1.6
    x = x * env
    return np.stack([x, np.roll(x, int(0.011 * SR))], axis=1)


def place(fx, s, t, total):
    i = int(max(0, t) * SR)
    end = min(total, i + len(s))
    if end > i:
        fx[i:end] += s[: end - i]


def read_wav(path):
    with wave.open(path) as w:
        assert w.getframerate() == SR and w.getnchannels() == 2, "take audio must be 48 kHz stereo"
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2).astype(np.float64) / 32768


def film_mix(cues, take, rng):
    """The full film on its own clock (tau)."""
    total = int(cues["total"] * SR)
    off = int(cues["F0"] * SR)
    sess = int(cues["sessionEnd"] * SR)
    bed = np.zeros((total, 2))
    # film tau 0 may fall before the capture's first sample (F0 < 0): that stretch stays empty and the ambient bed fills it
    lead = max(0, -off)
    n = min(sess, len(take) - off) - lead
    if n > 0:
        bed[lead: lead + n] = take[off + lead: off + lead + n]
    # whatever Logic still rings after the session (its reverb tail) keeps playing under the end card
    tail = min(total - sess, len(take) - off - sess)
    if tail > 0:
        bed[sess: sess + tail] = take[off + sess: off + sess + tail]
    loud = bed[np.sqrt((bed ** 2).mean(axis=1)) > 1e-4]
    rms = np.sqrt(np.mean(loud ** 2)) if len(loud) else 0.05
    gen = np.zeros_like(bed)
    # ambient bed: from frame 0 until Logic's pad has come up
    pad_in = next((e["tau"] for e in cues["entrances"] if e["track"] == "Pad"), cues.get("musicTau") or 4.0)
    amb = chord(rng, pad_in + 3.0, [45, 52, 60, 64], 0.05, pad_in + 0.2, 2.6)
    place(gen, amb / (np.max(np.abs(amb)) + 1e-9) * rms * 0.5, 0.0, total)
    # outro: from the stop through the end card, fading to silence at the end
    st = cues.get("stopTau") or cues["sessionEnd"]
    out_len = cues["total"] - st
    outro = chord(rng, out_len, [45, 57, 60, 64, 67], 0.25, out_len - 2.2, 2.2)
    place(gen, outro / (np.max(np.abs(outro)) + 1e-9) * rms * 0.55, st, total)
    mix = bed + gen
    fx = np.zeros_like(mix)
    for t, kind in cues["sfx"]:
        fn, db = KINDS[kind]
        s = fn(rng)
        place(fx, s / (np.max(np.abs(s)) + 1e-9) * rms * 10 ** (db / 20) * 4.0, t, total)
    mix = mix + fx
    fade = int(0.04 * SR)
    mix[:fade] *= np.linspace(0, 1, fade)[:, None]
    return mix


KINDS = {"whoosh": (whoosh, -18.0), "tick": (tick, -32.0), "riser": (riser, -20.0), "boom": (boom, -16.0)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cues", required=True)
    ap.add_argument("--take", required=True, help="wav of Logic's output for the whole take (48 kHz stereo)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--social", action="store_true", help="assemble the social/vertical cut from the film's own mix")
    a = ap.parse_args()
    cues = json.load(open(a.cues))
    take = read_wav(a.take)
    mix = film_mix(cues, take, np.random.default_rng(7))
    if a.social:
        segs = cues["social"]["segments"]
        total = int(round(cues["social"]["total"] * SR))
        out = np.zeros((total, 2))
        xf = int(0.03 * SR)  # 30 ms equal-power joins: cuts land on bar lines or on the generated beds, never mid-note
        for seg in segs:
            s0, n, src0 = int(round(seg["s0"] * SR)), int(round(seg["len"] * SR)), int(round(seg["tau0"] * SR))
            piece = mix[src0: src0 + n + xf].copy()
            piece = np.pad(piece, ((0, n + xf - len(piece)), (0, 0)))
            ramp = np.sin(np.linspace(0, np.pi / 2, xf)) ** 2
            if s0 > 0:
                piece[:xf] *= ramp[:, None]
            piece[n:] *= ramp[::-1][:, None]
            end = min(total, s0 + n + xf)
            out[s0:end] += piece[: end - s0]
        mix = out
    peak = np.max(np.abs(mix))
    if peak > 0.95:
        mix *= 0.95 / peak
    pcm = (np.clip(mix, -1, 1) * 32767).astype(np.int16)
    with wave.open(a.out, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    print(f"wrote {a.out}: {len(mix) / SR:.2f}s")


if __name__ == "__main__":
    main()
