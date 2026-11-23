#!/usr/bin/env python3
"""The film's soundtrack: Logic's own output from the take, plus procedural sound design (numpy only, deterministic,
royalty-free because it is generated here).

  sound_design.py --cues work/cues.json --take raw/take.audio.wav --out work/mix.wav [--social]

The bed is the take's audio at 1.0x from the film's first frame, so every change heard happens when it is seen.
Logic plays nothing until Claude starts playback, and nothing after Claude stops it, so two generated layers keep the
film from ever going silent, both in the song's key (A minor):
  * an ambient bed (A2/E3/C4/E4) under the opening, fading out as Logic's own pad comes up;
  * an outro swell (Am7) from the stop into the end card, fading to silence at the very end.
Hits: ticks when Logic answers a call (very low), a short panned note for each pan and a falling or rising note for each
fader adjustment (so a move can be heard on a plateau where Logic itself barely changes), a riser into the drop, whooshes
into the cards, a boom on the end card. The sound-design bus sits 14-26 dB under the music.

Level of the opening bed: it is set from a K-weighted measurement of Logic's own first sound (the Pad, the 2 s after the
server confirmed its fader), BED_UNDER_PAD_LU under it, flat up to the request that brings the Pad in and faded out
over that request. There is no dip before the entrance, so the Pad's step is measured against the bed's real level.
"""
import argparse
import json
import os
import re
import subprocess
import tempfile
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


def kw_lufs(x, eq):
    """K-weighted loudness (EBU R128 integrated, so gated) of a stereo float array, after the master EQ."""
    fd, path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        with wave.open(path, "wb") as w:
            w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())
        r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", (eq + "," if eq else "") + "ebur128", "-f", "null", "-"], capture_output=True, text=True)
        m = re.search(r"I:\s+(-?[0-9.]+) LUFS", r.stderr[r.stderr.rfind("Summary:"):])
        return float(m.group(1)) if m else -70.0
    finally:
        os.unlink(path)


def note(freqs, dur=0.42, glide=None):
    """A soft bell-like note (fundamental + fifth), short decay; glide=(f0, f1) bends the pitch."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    if glide:
        f = glide[0] * (glide[1] / glide[0]) ** (t / dur)
        ph = 2 * np.pi * np.cumsum(f) / SR
        x = np.sin(ph) + 0.35 * np.sin(1.5 * ph)
    else:
        x = sum(np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * 1.5 * f * t) for f in freqs)
    env = np.minimum(1, t / 0.004) * np.exp(-t / 0.11)
    return x * env


def ping(rng, pan=0.0):
    """A pan write: one note, placed in the stereo field where the pan now is (exaggerated so a small pan is still heard)."""
    x = note([880.0])
    p = float(np.clip(pan * 3.0, -1, 1))
    gl, gr = np.cos((p + 1) * np.pi / 4), np.sin((p + 1) * np.pi / 4)
    return np.stack([x * gl, x * gr], axis=1) * 1.2


def down(rng, arg=0.0):
    return stereo(note(None, 0.5, glide=(988.0, 659.0)))


def up(rng, arg=0.0):
    return stereo(note(None, 0.5, glide=(659.0, 988.0)))


def place(fx, s, t, total):
    i = int(max(0, t) * SR)
    end = min(total, i + len(s))
    if end > i:
        fx[i:end] += s[: end - i]


def read_wav(path):
    with wave.open(path) as w:
        assert w.getframerate() == SR and w.getnchannels() == 2, "take audio must be 48 kHz stereo"
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2).astype(np.float64) / 32768


def film_mix(cues, take, rng, eq=""):
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
    # ambient bed: from frame 0 while Logic is silent (the requests before playback). It sits AMB_DB under the music's
    # average level and thins out over the last seconds before the first part comes in, so that entrance is a step up.
    ent = cues["entrances"][0] if cues["entrances"] else None
    pad_in = ent["tau"] if ent else (cues.get("musicTau") or 4.0)
    pad_done = ent["tauEnd"] if ent else pad_in + 0.5
    # flat until the request that brings the Pad in, then faded out across that request (it ends as the server confirms)
    amb = chord(rng, pad_done + 0.5, [45, 52, 60, 64], 0.05, pad_in, (pad_done - pad_in) + 0.3)
    amb = amb / (np.max(np.abs(amb)) + 1e-9) * 0.5  # raw saws are far above full scale: bring them into range before anything is measured
    sustain = amb[int(0.5 * SR): int(max(0.6, pad_in) * SR)]
    if ent and len(sustain):
        # Logic's first sound: the 2 s after the Pad's fader was confirmed (the bed is silent there), K-weighted
        a0 = int(pad_done * SR)  # `bed` is already on the film clock (tau)
        pad_lufs = kw_lufs(bed[a0: a0 + 2 * SR], eq)
        gain = 10 ** ((pad_lufs - BED_UNDER_PAD_LU - kw_lufs(sustain, eq)) / 20)
        print(f"opening bed: Pad entry {pad_lufs:.1f} LUFS, bed {pad_lufs - BED_UNDER_PAD_LU:.1f} LUFS (K-weighted, after the master EQ)")
        place(gen, amb * gain, 0.0, total)
    else:
        amb_rms = np.sqrt(np.mean(sustain ** 2)) if len(sustain) else 1.0
        place(gen, amb / (amb_rms + 1e-9) * rms * 10 ** (AMB_DB / 20), 0.0, total)
    st = cues.get("stopTau")
    if st is not None:
        # Logic was stopped on camera: an outro swell (Am7) carries the end card, fading to silence at the very end
        out_len = cues["total"] - st
        outro = chord(rng, out_len, [45, 57, 60, 64, 67], 0.25, out_len - 2.2, 2.2)
        place(gen, outro / (np.max(np.abs(outro)) + 1e-9) * rms * 0.55, st, total)
    else:
        # the film ends before any stop: Logic's own music plays on under the end card and fades out with it
        f0 = int(cues["end"]["from"] * SR)
        n_f = total - f0
        if n_f > 0:
            bed[f0:] *= (np.cos(np.linspace(0, np.pi / 2, n_f)) ** 2)[:, None]
    mix = bed + gen
    fx = np.zeros_like(mix)
    ref = bed + gen  # what is playing, without the effects: the level the adjustment notes are set against
    for t, kind, *arg in cues["sfx"]:
        fn, db = KINDS[kind]
        s = fn(rng, *arg) if arg else fn(rng)
        if kind in ADJUST:
            # peak of the note = the local programme's RMS (1 dB under once music plays; 3 dB over on the bare opening bed,
            # where it is still no louder than the Pad that follows)
            seg = ref[max(0, int((t - 1.5) * SR)): max(1, int((t - 0.05) * SR))]
            local = np.sqrt(np.mean(seg ** 2)) if len(seg) else rms
            music = cues.get("musicTau") is not None and t > cues["musicTau"]
            place(fx, s / (np.max(np.abs(s)) + 1e-9) * local * 10 ** ((-1.0 if music else 3.0) / 20), t, total)
        else:
            place(fx, s / (np.max(np.abs(s)) + 1e-9) * rms * 10 ** (db / 20) * 4.0, t, total)
    mix = mix + fx
    fade = int(0.04 * SR)
    mix[:fade] *= np.linspace(0, 1, fade)[:, None]
    return mix


AMB_DB = -5.0  # fallback only (no entrance in the cues): opening bed level against the music's average RMS
BED_UNDER_PAD_LU = 4.0  # set against the Pad in the pre-master mix; after the master's compression the bed measures about 7 LU under the Pad's entry (the requirement is 6)
KINDS = {"whoosh": (whoosh, -18.0), "tick": (tick, -32.0), "riser": (riser, -20.0), "boom": (boom, -16.0),
         "ping": (ping, 0.0), "down": (down, 0.0), "up": (up, 0.0)}
ADJUST = ("ping", "down", "up")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cues", required=True)
    ap.add_argument("--take", required=True, help="wav of Logic's output for the whole take (48 kHz stereo)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--eq", default="", help="the master EQ chain (ffmpeg filters), so the bed is levelled the way it will be heard")
    ap.add_argument("--social", action="store_true", help="assemble the social/vertical cut from the film's own mix")
    a = ap.parse_args()
    cues = json.load(open(a.cues))
    take = read_wav(a.take)
    mix = film_mix(cues, take, np.random.default_rng(7), a.eq)
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
