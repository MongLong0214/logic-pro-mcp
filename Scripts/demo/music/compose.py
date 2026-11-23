#!/usr/bin/env python3
"""Compose the demo track as Standard MIDI Files (stdlib only, deterministic).

"Signal" v3 -- 120 BPM, A minor, 48 bars (96 s). Bars are exactly 2.0 s.

The film is driven by a real AI client (Claude Code), so nobody can promise on which bar a request lands. Every part is
therefore written from bar 1 to the end and the session starts with every fader down: a part becomes audible the moment
Claude raises its fader, whenever that is, and the harmony is a four-bar loop so any entrance point works.

  bars  1-16   A  : Am7 | Fmaj7 | Cmaj7 | G   (x4), lead hook P1/P2
  bars 17-24   B  : Fmaj7 | G | Em7 | Am7 (x2), higher answer melody, drums keep the groove
  bars 25-40   A' : as A
  bars 41-48   B' : as B, last chord rings through bar 48

Registers are kept apart so the parts read separately on small speakers: bass A1-E2 roots with fifths (never above
B2), pad voiced from E3 up (open, stepwise), keys an octave above the pad, lead on top. Humanisation is seeded:
Gaussian timing offsets (about 5-13 ms), velocity accents plus scatter, varied note lengths, a sustain pedal (CC 64)
on the keys. Outputs in ./out: arrangement.mid (format 1, tempo track + 5 named tracks), one .mid per track, and
arrangement.json.
"""
import json
import os
import random
import struct

PPQ = 960
BEAT = PPQ
BAR = 4 * PPQ
BPM = 120
BARS = 48
SEED = 20261120
MS = PPQ * BPM / 60000.0  # ticks per millisecond

A_PROG = ["Am7", "Fmaj7", "Cmaj7", "G"]
B_PROG = ["Fmaj7", "G", "Em7", "Am7"]


def section(bar):
    return "B" if (17 <= bar <= 24 or 41 <= bar <= 48) else "A"


CHORD_OF_BAR = [(B_PROG if section(b) == "B" else A_PROG)[(b - 1) % 4] for b in range(1, BARS + 1)]

# pad from E3 up (lowest 52), keys an octave above, bass below A2: no shared register between bass and pad
PAD_V = {"Am7": [57, 60, 64, 67], "Fmaj7": [53, 57, 60, 64], "Cmaj7": [55, 59, 60, 64], "G": [55, 59, 62, 67], "Em7": [52, 55, 59, 62]}
KEYS_V = {"Am7": [69, 72, 76, 79], "Fmaj7": [69, 72, 76, 77], "Cmaj7": [67, 71, 72, 76], "G": [67, 71, 74, 79], "Em7": [67, 71, 74, 76]}
BASS_ROOT = {"Am7": 33, "Fmaj7": 29 + 12, "Cmaj7": 36, "G": 31 + 12, "Em7": 40}  # A1 F2 C2 G2 E2

TRACKS = ["Keys", "Pad", "Bass", "Drums", "Lead"]
ENTRY = {n: 1 for n in TRACKS}  # all parts are written from bar 1; the fader decides when each is heard
K, SN, CL, CH, OH, CR, T1, T2 = 36, 38, 39, 42, 46, 49, 45, 47

# lead melodies: (beat, pitch, length, velocity) per bar
P1 = [  # over Am7 F C G
    [(0, 76, 1.5, 104), (1.5, 74, .5, 92), (2, 72, 1, 98), (3, 74, .5, 90), (3.5, 76, .5, 96)],
    [(0, 77, 1.5, 106), (1.5, 76, .5, 92), (2, 72, 2, 100)],
    [(0, 79, 1, 108), (1, 76, .5, 90), (1.5, 74, .5, 88), (2, 72, 1, 96), (3, 76, 1, 100)],
    [(0, 74, 1.5, 102), (1.5, 71, .5, 88), (2, 74, 1.5, 100), (3.5, 76, .5, 94)],
]
P2 = [
    [(0, 69, .5, 92), (.5, 72, .5, 94), (1, 76, 1, 102), (2, 81, 1.5, 110), (3.5, 79, .5, 96)],
    [(0, 77, 1, 104), (1, 81, 1, 108), (2, 79, 1, 102), (3, 77, .5, 94), (3.5, 76, .5, 96)],
    [(0, 76, .75, 102), (.75, 79, .75, 100), (1.5, 84, 1, 112), (2.5, 83, .5, 98), (3, 79, 1, 102)],
    [(0, 74, 1, 102), (1, 79, 1, 104), (2, 71, .5, 92), (2.5, 74, .5, 94), (3, 76, 1, 104)],
]
B1 = [  # over Fmaj7 G Em7 Am7 (higher answer)
    [(0, 81, 1.5, 106), (1.5, 79, .5, 94), (2, 77, 1, 100), (3, 76, 1, 96)],
    [(0, 83, 1.5, 108), (1.5, 81, .5, 96), (2, 79, 2, 102)],
    [(0, 79, 1, 104), (1, 76, 1, 98), (2, 79, .5, 94), (2.5, 81, .5, 96), (3, 83, 1, 106)],
    [(0, 84, 2, 110), (2, 81, 1, 100), (3, 76, 1, 96)],
]
B2 = [
    [(0, 84, 1, 110), (1, 81, 1, 102), (2, 84, 1, 108), (3, 86, 1, 112)],
    [(0, 86, 1.5, 112), (1.5, 83, .5, 98), (2, 79, 2, 102)],
    [(0, 83, 1, 106), (1, 79, 1, 100), (2, 76, 2, 98)],
    [(0, 81, 4, 108)],
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
    P = {n: Part(rng, t, v) for n, t, v in [("Keys", 11, 7), ("Pad", 8, 4), ("Bass", 7, 5), ("Drums", 5, 6), ("Lead", 10, 5)]}
    last = BARS  # the final bar holds one chord

    pad = P["Pad"]
    for bar in range(1, last):
        for n in PAD_V[CHORD_OF_BAR[bar - 1]]:
            pad.note(b0(bar), BAR + 120, n, 70, legato=(0.98, 1.02))  # overlap into the next bar: no gap between chords
    for n in PAD_V["Am7"]:
        pad.note(b0(last), BAR, n, 66, legato=(0.97, 1.0))

    keys = P["Keys"]
    arp = [0, 1, 2, 3, 2, 1, 2, 3]
    stabs = [0, 0.75, 1.5, 2.5, 3.25]
    for bar in range(1, last):
        ch = KEYS_V[CHORD_OF_BAR[bar - 1]]
        keys.cc(b0(bar) + 20, 64, 127)  # pedal down on the chord, up just before the next
        if section(bar) == "A":
            for i in range(8):
                acc = 16 if i % 4 == 0 else (6 if i % 2 == 0 else 0)
                keys.note(b0(bar) + i * BEAT // 2, BEAT, ch[arp[i]] + (12 if i == 6 else 0), 74 + acc)
        else:
            for si, pos in enumerate(stabs):
                vel = 92 if si in (0, 3) else 76
                for n in ch:
                    keys.note(b0(bar) + int(pos * BEAT), int((0.6 if si != 2 else 0.9) * BEAT), n, vel)
        keys.cc(b0(bar) + BAR - 60, 64, 0)
    keys.cc(b0(last) + 10, 64, 127)
    for n in KEYS_V["Am7"]:
        keys.note(b0(last), BAR, n, 70)
    keys.cc(b0(last) + BAR - 20, 64, 0)

    bass = P["Bass"]
    for bar in range(1, last):
        r = BASS_ROOT[CHORD_OF_BAR[bar - 1]]
        for pos, ln, p, v in [(0, .75, r, 104), (1.5, .5, r, 84), (2, .75, r + 7, 92), (2.75, .25, r, 74), (3.5, .5, r + 7, 88)]:
            bass.note(b0(bar) + int(pos * BEAT), int(ln * BEAT), p, v)
    bass.note(b0(last), 3 * BEAT, BASS_ROOT["Am7"], 96)

    d = P["Drums"]
    sw = 0.07
    for bar in range(1, last):
        base = b0(bar)
        for beat in range(4):
            d.note(base + beat * BEAT, 90, K, 106 if beat == 0 else 96, tight=True)
        d.note(base + int(3.5 * BEAT), 90, K, 76)
        for beat in (1, 3):
            d.note(base + beat * BEAT, 150, CL, 100)
            d.note(base + beat * BEAT, 150, SN, 62)
        for s in range(16):
            pos = s * BEAT // 4 + (int(sw * BEAT) if s % 2 else 0)
            vel = {0: 96, 1: 52, 2: 82, 3: 56}[s % 4]
            open_hat = s in (6, 14) and bar % 2 == 0
            d.note(base + pos, 100 if open_hat else 60, OH if open_hat else CH, vel + (6 if open_hat else 0))
        if bar % 8 == 1:
            d.note(base, BAR, CR, 100, tight=True)
        if bar % 8 == 0:
            for s, (p, v) in enumerate([(SN, 60), (SN, 66), (SN, 74), (SN, 82), (T1, 86), (T1, 92), (T2, 98), (SN, 108)]):
                d.note(base + 2 * BEAT + s * BEAT // 4, 100, p, v)
    d.note(b0(last), 2 * BEAT, CR, 96, tight=True)
    d.note(b0(last), 90, K, 104, tight=True)

    lead = P["Lead"]

    def phrase(bars, phr, shift=0):
        for i, bar in enumerate(bars):
            for beat, pitch, ln, vel in phr[i % len(phr)]:
                lead.note(b0(bar) + int(beat * BEAT), int(ln * BEAT) - 30, pitch + shift, min(120, vel))
    for start in (1, 25):
        phrase(range(start, start + 4), P1)
        phrase(range(start + 4, start + 8), P2)
        phrase(range(start + 8, start + 12), P1)
        phrase(range(start + 12, start + 16), P2)
    phrase(range(17, 21), B1)
    phrase(range(21, 25), B2)
    phrase(range(41, 45), B1)
    phrase(range(45, 49), B2)
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
        "sections": [{"name": n, "from_bar": a, "to_bar": b} for n, a, b in [("A", 1, 16), ("B", 17, 24), ("A2", 25, 40), ("B2", 41, 48)]],
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
