#!/usr/bin/env python3
"""Compose the demo track as Standard MIDI Files (stdlib only, deterministic).

"Signal" -- 120 BPM, A minor, 24 bars (48 s). Bars are exactly 2.0 s, so every entrance lands on a round second.

  bars  1-4    intro    : pad (bar 1), keys arpeggio (bar 3)
  bars  5-8    build    : bass (bar 5), drums (bar 7) with a fill into bar 9
  bars  9-16   A        : Am7 | Fmaj7 | Cmaj7 | G/B ; lead hook (bar 9), full groove
  bars 17-24   B        : contrast -- Fmaj7 | G | Em7 | Am7 twice, half-time drums, a new, higher melody, keys on pedal,
                          full groove again from bar 21, last chord rings through bar 24

Pad and keys voicings are open (no minor second below middle C) and move by step. Humanisation is seeded:
Gaussian timing offsets (about 8-14 ms), velocity accents plus scatter, varied note lengths, and a sustain pedal
(CC 64) on the keys. Outputs in ./out: arrangement.mid (format 1, tempo track + 5 named tracks), one .mid per track,
arrangement.json (entry bars and the cue sheet the MCP driver follows).
"""
import json
import os
import random
import struct

PPQ = 960
BEAT = PPQ
BAR = 4 * PPQ
BPM = 120
BARS = 24
SEED = 20261120
MS = PPQ * BPM / 60000.0  # ticks per millisecond

# chord per bar
A_PROG = ["Am7", "Fmaj7", "Cmaj7", "G"]
B_PROG = ["Fmaj7", "G", "Em7", "Am7"]
CHORD_OF_BAR = [A_PROG[(b - 1) % 4] for b in range(1, 17)] + [B_PROG[(b - 17) % 4] for b in range(17, 25)]

KEYS_V = {"Am7": [60, 64, 67, 71], "Fmaj7": [60, 64, 69, 72], "Cmaj7": [60, 64, 67, 71], "G": [59, 62, 67, 71], "Em7": [59, 64, 67, 71]}
PAD_V = {"Am7": [45, 52, 55, 60], "Fmaj7": [41, 48, 52, 57], "Cmaj7": [48, 55, 59, 64], "G": [43, 50, 55, 59], "Em7": [40, 47, 50, 55]}
BASS_ROOT = {"Am7": 45, "Fmaj7": 41, "Cmaj7": 48, "G": 43, "Em7": 40}  # A2 F2 C3 G2 E2: audible on small speakers

TRACKS = ["Keys", "Pad", "Bass", "Drums", "Lead"]
ENTRY = {"Pad": 1, "Keys": 3, "Bass": 5, "Drums": 7, "Lead": 9}
K, SN, CL, CH, OH, CR, T1, T2 = 36, 38, 39, 42, 46, 49, 45, 47

# lead melodies: (beat, pitch, length, velocity) per bar
P1 = [  # over Am7 F C G
    [(0, 76, 1.5, 92), (1.5, 74, .5, 80), (2, 72, 1, 86), (3, 74, .5, 78), (3.5, 76, .5, 84)],
    [(0, 77, 1.5, 94), (1.5, 76, .5, 80), (2, 72, 2, 88)],
    [(0, 79, 1, 96), (1, 76, .5, 78), (1.5, 74, .5, 76), (2, 72, 1, 84), (3, 76, 1, 88)],
    [(0, 74, 1.5, 90), (1.5, 71, .5, 76), (2, 74, 1.5, 88), (3.5, 76, .5, 82)],
]
P2 = [
    [(0, 69, .5, 80), (.5, 72, .5, 82), (1, 76, 1, 90), (2, 81, 1.5, 98), (3.5, 79, .5, 84)],
    [(0, 77, 1, 92), (1, 81, 1, 96), (2, 79, 1, 90), (3, 77, .5, 82), (3.5, 76, .5, 84)],
    [(0, 76, .75, 90), (.75, 79, .75, 88), (1.5, 84, 1, 100), (2.5, 83, .5, 86), (3, 79, 1, 90)],
    [(0, 74, 1, 90), (1, 79, 1, 92), (2, 71, .5, 80), (2.5, 74, .5, 82), (3, 76, 1, 92)],
]
B1 = [  # over Fmaj7 G Em7 Am7 (new, higher)
    [(0, 81, 1.5, 94), (1.5, 79, .5, 82), (2, 77, 1, 88), (3, 76, 1, 84)],
    [(0, 83, 1.5, 96), (1.5, 81, .5, 84), (2, 79, 2, 90)],
    [(0, 79, 1, 92), (1, 76, 1, 86), (2, 79, .5, 82), (2.5, 81, .5, 84), (3, 83, 1, 94)],
    [(0, 84, 2, 98), (2, 81, 1, 88), (3, 76, 1, 84)],
]
B2 = [
    [(0, 84, 1, 98), (1, 81, 1, 90), (2, 84, 1, 96), (3, 86, 1, 100)],
    [(0, 86, 1.5, 100), (1.5, 83, .5, 86), (2, 79, 2, 90)],
    [(0, 83, 1, 94), (1, 79, 1, 88), (2, 76, 2, 86)],
    [(0, 81, 4, 96)],
]


def vlq(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    return bytes(reversed(out))


def chunk(tag, data):
    return tag + struct.pack(">I", len(data)) + data


def track_bytes(name, events, channel=0, tempo=None):
    """events: (tick, kind, a, b): kind 0 note-off, 1 note-on (a=pitch, b=vel), 2 control change (a=cc, b=value)."""
    ev = [(0, 0, b"\xff\x03" + vlq(len(name)) + name.encode())]
    if tempo:
        ev.append((0, 0, b"\xff\x51\x03" + struct.pack(">I", int(60_000_000 / tempo))[1:]))
        ev.append((0, 0, b"\xff\x58\x04\x04\x02\x18\x08"))
        ev.append((0, 0, b"\xff\x59\x02\x00\x01"))  # key signature: A minor (no sharps/flats, minor)
    for tick, kind, a, b in events:
        if kind == 2:
            ev.append((tick, 1, bytes([0xB0 | channel, a, b])))
        elif kind == 1:
            ev.append((tick, 2, bytes([0x90 | channel, a, b])))
        else:
            ev.append((tick, 0, bytes([0x80 | channel, a, 0])))
    ev.sort(key=lambda e: (e[0], e[1]))
    data, last = bytearray(), 0
    for tick, _, raw in ev:
        data += vlq(tick - last) + raw
        last = tick
    data += vlq(max(0, BARS * BAR - last)) + b"\xff\x2f\x00"
    return chunk(b"MTrk", bytes(data))


class Part:
    def __init__(self, rng, timing_ms, vel_sd):
        self.rng, self.t_sd, self.v_sd, self.ev = rng, timing_ms * MS, vel_sd, []

    def note(self, start, length, pitch, vel, tight=False, legato=(0.86, 1.0)):
        j = 0 if tight else int(self.rng.gauss(0, self.t_sd))
        s = max(0, int(start + j))
        v = max(1, min(127, int(vel + self.rng.gauss(0, self.v_sd))))
        e = s + max(40, int(length * self.rng.uniform(*legato)))
        self.ev += [(s, 1, pitch, v), (e, 0, pitch, 0)]

    def cc(self, tick, cc, val):
        self.ev.append((max(0, int(tick)), 2, cc, val))


def b0(bar):
    return (bar - 1) * BAR


def compose():
    rng = random.Random(SEED)
    P = {n: Part(rng, t, v) for n, t, v in [("Keys", 13, 9), ("Pad", 9, 4), ("Bass", 8, 6), ("Drums", 5, 7), ("Lead", 12, 6)]}

    pad = P["Pad"]
    for bar in range(1, 24):
        level = 58 if bar < 5 else 66
        for n in PAD_V[CHORD_OF_BAR[bar - 1]]:
            pad.note(b0(bar), BAR + 120, n, level, legato=(0.98, 1.02))  # overlap into the next bar: no gap between chords
    for n in PAD_V["Am7"]:
        pad.note(b0(24), BAR, n, 64, legato=(0.97, 1.0))

    keys = P["Keys"]
    arp = [0, 1, 2, 3, 2, 1, 2, 3]
    for bar in list(range(3, 9)) + list(range(21, 24)):
        ch = KEYS_V[CHORD_OF_BAR[bar - 1]]
        keys.cc(b0(bar) + 20, 64, 127)  # pedal down on the chord, up just before the next
        for i in range(8):
            acc = 14 if i % 4 == 0 else (5 if i % 2 == 0 else 0)
            keys.note(b0(bar) + i * BEAT // 2, BEAT, ch[arp[i]] + (12 if i == 6 else 0), (58 if bar < 5 else 66) + acc)
        keys.cc(b0(bar) + BAR - 60, 64, 0)
    stabs = [0, 0.75, 1.5, 2.5, 3.25]
    for bar in range(9, 17):
        ch = KEYS_V[CHORD_OF_BAR[bar - 1]]
        keys.cc(b0(bar) + 20, 64, 127)
        for si, pos in enumerate(stabs):
            vel = 86 if si in (0, 3) else 70
            for n in ch:
                keys.note(b0(bar) + int(pos * BEAT), int((0.6 if si != 2 else 0.9) * BEAT), n, vel + (6 if n == ch[-1] else 0))
        keys.cc(b0(bar) + BAR - 60, 64, 0)
    for bar in range(17, 21):  # contrast: long pedalled chords, high sparkle on the offbeat
        ch = KEYS_V[CHORD_OF_BAR[bar - 1]]
        keys.cc(b0(bar) + 10, 64, 127)
        for n in ch:
            keys.note(b0(bar), int(3.6 * BEAT), n, 62)
        keys.note(b0(bar) + int(2.5 * BEAT), BEAT, ch[-1] + 12, 56)
        keys.cc(b0(bar) + BAR - 50, 64, 0)
    keys.cc(b0(24) + 10, 64, 127)
    for n in KEYS_V["Am7"]:
        keys.note(b0(24), 3 * BAR, n, 60)
    keys.cc(b0(24) + 4 * BAR - 20, 64, 0)

    bass = P["Bass"]
    for bar in range(5, 24):
        r = BASS_ROOT[CHORD_OF_BAR[bar - 1]]
        if bar < 9 or 17 <= bar <= 20:
            for pos, ln in [(0, 1.8), (2, 1.8)]:
                bass.note(b0(bar) + int(pos * BEAT), int(ln * BEAT), r, 84 if pos == 0 else 72)
        else:
            for pos, ln, p, v in [(0, .75, r, 100), (1.5, .5, r, 80), (2, .75, r + 12, 88), (2.75, .25, r, 70), (3.5, .5, r + 7, 86)]:
                bass.note(b0(bar) + int(pos * BEAT), int(ln * BEAT), p, v)
    bass.note(b0(24), 3 * BEAT, BASS_ROOT["Am7"], 84)

    d = P["Drums"]
    sw = 0.07
    for bar in range(7, 24):
        base = b0(bar)
        full = 9 <= bar <= 16 or bar >= 21
        half = 17 <= bar <= 20
        for beat in range(4):
            if half and beat not in (0, 2):
                continue
            d.note(base + beat * BEAT, 90, K, (104 if beat == 0 else 92) if (full or half) else 80, tight=True)
        if full:
            d.note(base + int(3.5 * BEAT), 90, K, 72)
        if full:
            for beat in (1, 3):
                d.note(base + beat * BEAT, 150, CL, 98)
                d.note(base + beat * BEAT, 150, SN, 58)
        if half:
            d.note(base + 2 * BEAT, 150, SN, 96)
        # hats: 16ths in the groove (brighter accents), 8ths in the half-time section, off-8ths in the build
        steps = range(16) if full else (range(0, 16, 2) if half else range(2, 16, 4))
        for s in steps:
            pos = s * BEAT // 4 + (int(sw * BEAT) if s % 2 else 0)
            vel = {0: 96, 1: 52, 2: 82, 3: 56}[s % 4] if full else 74
            open_hat = full and s in (6, 14) and bar % 2 == 0
            d.note(base + pos, 100 if open_hat else 60, OH if open_hat else CH, vel + (6 if open_hat else 0))
        if bar in (9, 17, 21):
            d.note(base, BAR, CR, 100, tight=True)
        if bar in (8, 16, 20):
            for s, (p, v) in enumerate([(SN, 60), (SN, 66), (SN, 74), (SN, 82), (T1, 86), (T1, 92), (T2, 98), (SN, 108)]):
                d.note(base + 2 * BEAT + s * BEAT // 4, 100, p, v)
    d.note(b0(23) + 3 * BEAT, 2 * BEAT, CR, 90, tight=True)

    lead = P["Lead"]
    def phrase(bars, phr, shift=0):
        for i, bar in enumerate(bars):
            for beat, pitch, ln, vel in phr[i % len(phr)]:
                lead.note(b0(bar) + int(beat * BEAT), int(ln * BEAT) - 30, pitch + shift, min(120, vel))
    phrase(range(9, 13), P1)
    phrase(range(13, 17), P2)
    phrase(range(17, 21), B1)
    phrase(range(21, 25), B2)
    return P


def write(P, outdir):
    os.makedirs(outdir, exist_ok=True)
    chunks = [track_bytes("Tempo", [], tempo=BPM)]
    for ch, name in enumerate(TRACKS):
        channel = 9 if name == "Drums" else ch
        t = track_bytes(name, P[name].ev, channel=channel)
        chunks.append(t)
        with open(os.path.join(outdir, f"{name.lower()}.mid"), "wb") as f:
            f.write(chunk(b"MThd", struct.pack(">HHH", 1, 2, PPQ)) + track_bytes("Tempo", [], tempo=BPM) + t)
    with open(os.path.join(outdir, "arrangement.mid"), "wb") as f:
        f.write(chunk(b"MThd", struct.pack(">HHH", 1, len(chunks), PPQ)) + b"".join(chunks))


def plan(P):
    spb = 60.0 / BPM * 4
    return {
        "title": "Signal", "bpm": BPM, "key": "A minor", "bars": BARS, "ppq": PPQ, "seed": SEED,
        "seconds_per_bar": spb, "duration_seconds": spb * BARS, "track_order": TRACKS,
        "sections": [{"name": "intro", "from_bar": 1, "to_bar": 4}, {"name": "build", "from_bar": 5, "to_bar": 8},
                     {"name": "A", "from_bar": 9, "to_bar": 16}, {"name": "B", "from_bar": 17, "to_bar": 24}],
        "progression": {"A": A_PROG, "B": B_PROG},
        "tracks": [{"name": n, "entry_bar": ENTRY[n], "notes": sum(1 for e in P[n].ev if e[1] == 1)} for n in TRACKS],
    }


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "out")
    p = compose()
    write(p, out)
    with open(os.path.join(out, "arrangement.json"), "w") as f:
        json.dump(plan(p), f, indent=2)
    print(json.dumps(plan(p)["tracks"]))
