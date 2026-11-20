#!/usr/bin/env python3
"""Compose the demo track as Standard MIDI Files (stdlib only, deterministic).

"Signal" -- 112 BPM, A minor, 36 bars (about 77 s). i - VI - III - VII (Am7 | Fmaj7 | Cmaj7 | G/B), one chord a bar,
with smooth voice leading: every upper voice moves by at most a tone between chords.

  bars  1-4   intro  : pad, then sparse keys arpeggio from bar 3
  bars  5-12  build  : + bass (bar 5), + drums (bar 9), snare fill into bar 13
  bars 13-28  drop   : full groove, lead hook (A phrase / B phrase, second pass an octave up)
  bars 29-36  outro  : drums out after bar 32, bass out after bar 34, last chord rings to bar 36

Humanisation is deterministic (seeded): +-timing in ticks, velocity accents per beat, note length variation.
Outputs, next to this file in ./out:
  arrangement.mid       one format-1 file, tempo track + 5 named tracks (import once into Logic)
  <track>.mid           one file per track
  arrangement.json      sections, entry bars, and the cue sheet the MCP driver follows
"""
import json
import os
import random
import struct

PPQ = 960
BEAT = PPQ
BAR = 4 * PPQ
BPM = 112
BARS = 36
SEED = 20260319

# Chord per bar (looped): Am7 | Fmaj7 | Cmaj7 | G/B ; upper voicing moves by step, bass roots listed separately.
VOICINGS = [
    [60, 64, 67, 71],  # Am7   C4 E4 G4 B4   (A in the bass)
    [60, 64, 69, 72],  # Fmaj7 C4 E4 A4 C5   (F in the bass)
    [60, 64, 67, 71],  # Cmaj7 C4 E4 G4 B4   (C in the bass)
    [59, 62, 67, 71],  # G/B   B3 D4 G4 B4   (G in the bass)
]
BASS_ROOTS = [33, 29, 36, 31]  # A1 F1 C2 G1

# Order matters: Logic gives MIDI-imported tracks default instruments in this order (Studio Grand first).
TRACKS = ["Keys", "Pad", "Bass", "Drums", "Lead"]

# Drum map (General MIDI / Logic Drum Kit Designer): kick 36, snare 38, clap 39, closed hat 42, open hat 46, crash 49, tom 45/47.
K, SN, CL, CH, OH, CR, T1, T2 = 36, 38, 39, 42, 46, 49, 45, 47

LEAD_P1 = [  # (beat, pitch, length, velocity) for 4 bars of Am | F | C | G
    [(0, 76, 1.5, 92), (1.5, 74, .5, 80), (2, 72, 1, 86), (3, 74, .5, 78), (3.5, 76, .5, 84)],
    [(0, 77, 1.5, 94), (1.5, 76, .5, 80), (2, 72, 2, 88)],
    [(0, 79, 1, 96), (1, 76, .5, 78), (1.5, 74, .5, 76), (2, 72, 1, 84), (3, 76, 1, 88)],
    [(0, 74, 1.5, 90), (1.5, 71, .5, 76), (2, 74, 1.5, 88), (3.5, 76, .5, 82)],
]
LEAD_P2 = [
    [(0, 69, .5, 80), (.5, 72, .5, 82), (1, 76, 1, 90), (2, 81, 1.5, 98), (3.5, 79, .5, 84)],
    [(0, 77, 1, 92), (1, 81, 1, 96), (2, 79, 1, 90), (3, 77, .5, 82), (3.5, 76, .5, 84)],
    [(0, 76, .75, 90), (.75, 79, .75, 88), (1.5, 84, 1, 100), (2.5, 83, .5, 86), (3, 79, 1, 90)],
    [(0, 74, 1, 90), (1, 79, 1, 92), (2, 71, .5, 80), (2.5, 74, .5, 82), (3, 76, 1, 92)],
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


def track_bytes(name, events, channel=0, tempo=None, program=None):
    """events: list of (tick, on, pitch, vel). Returns an MTrk chunk."""
    ev = []
    ev.append((0, 0, b"\xff\x03" + vlq(len(name)) + name.encode()))
    if tempo:
        ev.append((0, 0, b"\xff\x51\x03" + struct.pack(">I", int(60_000_000 / tempo))[1:]))
        ev.append((0, 0, b"\xff\x58\x04\x04\x02\x18\x08"))
    if program is not None:
        ev.append((0, 0, bytes([0xC0 | channel, program])))
    for tick, on, pitch, vel in events:
        status = (0x90 if on else 0x80) | channel
        # note-offs sort before note-ons at the same tick so re-struck pitches never overlap
        ev.append((tick, 1 if on else 0, bytes([status, pitch, vel if on else 0])))
    ev.sort(key=lambda e: (e[0], e[1]))
    data = bytearray()
    last = 0
    for tick, _, raw in ev:
        data += vlq(tick - last) + raw
        last = tick
    data += vlq(max(0, BARS * BAR - last)) + b"\xff\x2f\x00"
    return chunk(b"MTrk", bytes(data))


class Part:
    def __init__(self, rng, jitter, vel_jitter):
        self.rng, self.jitter, self.vj, self.ev = rng, jitter, vel_jitter, []

    def note(self, start, length, pitch, vel, tight=False):
        j = 0 if tight else int(self.rng.gauss(0, self.jitter))
        s = max(0, int(start + j))
        v = max(1, min(127, int(vel + self.rng.randint(-self.vj, self.vj))))
        e = s + max(30, int(length * (0.96 if not tight else 1.0)))
        self.ev.append((s, 1, pitch, v))
        self.ev.append((e, 0, pitch, 0))


def bar_start(bar):  # 1-based bar -> tick
    return (bar - 1) * BAR


def chord_of(bar):
    return (bar - 1) % 4


def compose():
    rng = random.Random(SEED)
    parts = {n: Part(rng, j, v) for n, j, v in
             [("Pad", 4, 4), ("Keys", 9, 8), ("Bass", 6, 6), ("Drums", 5, 7), ("Lead", 8, 5)]}

    # Pad: whole-bar chords, bars 1-36 (last chord rings 4 bars), voiced an octave below the keys.
    pad = parts["Pad"]
    for bar in range(1, 33):
        notes = [n - 12 for n in VOICINGS[chord_of(bar)]] + [BASS_ROOTS[chord_of(bar)] + 24]
        level = 46 if bar <= 4 else (56 if bar < 13 else 64)
        for n in notes:
            pad.note(bar_start(bar), BAR - 20, n, level)
    for n in [n - 12 for n in VOICINGS[0]] + [57]:
        pad.note(bar_start(33), 4 * BAR - 40, n, 58)

    # Keys: arpeggio (bars 3-12), syncopated chord stabs (13-28), arpeggio again (29-32), final chord (33).
    keys = parts["Keys"]
    arp_order = [0, 1, 2, 3, 2, 1, 2, 3]
    for bar in list(range(3, 13)) + list(range(29, 33)):
        ch = VOICINGS[chord_of(bar)]
        for i in range(8):
            accent = 14 if i % 4 == 0 else (4 if i % 2 == 0 else 0)
            base = 54 if bar < 5 else 62
            keys.note(bar_start(bar) + i * BEAT // 2, BEAT // 2 + 40, ch[arp_order[i]] + 12 * (i // 6), base + accent)
    stabs = [0, 0.75, 1.5, 2.5, 3.25]
    for bar in range(13, 29):
        ch = VOICINGS[chord_of(bar)]
        for si, pos in enumerate(stabs):
            vel = 84 if si in (0, 3) else 68
            ln = int((0.5 if si != 2 else 0.75) * BEAT)
            for n in ch:
                keys.note(bar_start(bar) + int(pos * BEAT), ln, n, vel + (6 if n == ch[-1] else 0))
    for n in VOICINGS[0]:
        keys.note(bar_start(33), 3 * BAR, n, 52)

    # Bass: quarters (5-12), groove (13-28), roots (29-34).
    bass = parts["Bass"]
    for bar in range(5, 35):
        r = BASS_ROOTS[chord_of(bar)]
        b0 = bar_start(bar)
        if bar < 13 or bar >= 29:
            for beat_pos, ln in [(0, 1.8), (2, 1.8)]:
                bass.note(b0 + int(beat_pos * BEAT), int(ln * BEAT), r, 84 if beat_pos == 0 else 72)
        else:
            groove = [(0, .75, r, 100), (1.5, .5, r, 80), (2, .75, r + 12, 88), (2.75, .25, r, 70), (3.5, .5, r + 7, 86)]
            for pos, ln, p, v in groove:
                bass.note(b0 + int(pos * BEAT), int(ln * BEAT), p, v)

    # Drums.
    d = parts["Drums"]
    sw = 0.06  # slight swing on the off-16ths
    for bar in range(9, 33):
        b0 = bar_start(bar)
        drop = 13 <= bar <= 28
        # kick: soft four-on-the-floor in the build, harder with a pickup in the drop
        for beat in range(4):
            d.note(b0 + beat * BEAT, 90, K, (100 if beat == 0 else 90) if drop else 78, tight=True)
        if drop:
            d.note(b0 + int(3.5 * BEAT), 90, K, 70)
            for beat in (1, 3):
                d.note(b0 + beat * BEAT, 150, CL, 96)
                d.note(b0 + beat * BEAT, 150, SN, 56)
        # hats: 16ths in the drop, off-8ths in the build
        steps = range(16) if drop else range(0, 16, 2)
        for s in steps:
            pos = s * BEAT // 4 + (int(sw * BEAT) if s % 2 else 0)
            if (not drop) and s % 4 != 2:
                continue
            vel = {0: 86, 1: 40, 2: 70, 3: 44}[s % 4] if drop else 62
            if drop and s % 4 == 2:
                d.note(b0 + pos, 100, OH if s in (6, 14) and bar % 2 == 0 else CH, vel)
            else:
                d.note(b0 + pos, 60, CH, vel)
        if bar in (13, 21, 29):
            d.note(b0, BAR, CR, 100, tight=True)
        # fills on the last bar of a phrase
        if bar in (12, 20, 28):
            for s, (p, v) in enumerate([(SN, 60), (SN, 66), (SN, 74), (SN, 82), (T1, 86), (T1, 92), (T2, 98), (SN, 108)]):
                d.note(b0 + 2 * BEAT + s * BEAT // 4 + (0 if s < 4 else 0), 100, p, v)
    d.note(bar_start(32) + 3 * BEAT, 2 * BEAT, CR, 90, tight=True)

    # Lead: bars 13-28, two passes (A then B phrase), second pass an octave up where it sits low.
    lead = parts["Lead"]
    for bar in range(13, 29):
        phrase = LEAD_P1 if ((bar - 13) // 4) % 2 == 0 else LEAD_P2
        second_pass = bar >= 21
        for beat, pitch, ln, vel in phrase[(bar - 1) % 4]:
            p = pitch + (12 if second_pass and pitch < 76 and bar not in (28,) else 0)
            lead.note(bar_start(bar) + int(beat * BEAT), int(ln * BEAT) - 24, p, min(120, vel + (6 if second_pass else 0)))
    lead.note(bar_start(29), 3 * BEAT, 76, 80)  # resolve on E5 over the last Am

    return parts


def write(parts, outdir):
    os.makedirs(outdir, exist_ok=True)
    conductor = track_bytes("Tempo", [], tempo=BPM)
    chunks = [conductor]
    for ch, name in enumerate(TRACKS):
        channel = 9 if name == "Drums" else ch
        t = track_bytes(name, parts[name].ev, channel=channel)
        chunks.append(t)
        header = chunk(b"MThd", struct.pack(">HHH", 1, 2, PPQ))
        with open(os.path.join(outdir, f"{name.lower()}.mid"), "wb") as f:
            f.write(header + track_bytes("Tempo", [], tempo=BPM) + t)
    header = chunk(b"MThd", struct.pack(">HHH", 1, len(chunks), PPQ))
    with open(os.path.join(outdir, "arrangement.mid"), "wb") as f:
        f.write(header + b"".join(chunks))


def plan(parts):
    spb = 60.0 / BPM * 4
    entry = {"Pad": 1, "Keys": 3, "Bass": 5, "Drums": 9, "Lead": 13}
    return {
        "title": "Signal", "bpm": BPM, "key": "A minor", "bars": BARS, "ppq": PPQ, "seed": SEED,
        "seconds_per_bar": spb, "duration_seconds": spb * BARS,
        "sections": [{"name": "intro", "from_bar": 1, "to_bar": 4}, {"name": "build", "from_bar": 5, "to_bar": 12},
                     {"name": "drop", "from_bar": 13, "to_bar": 28}, {"name": "outro", "from_bar": 29, "to_bar": 36}],
        "progression": ["Am7", "Fmaj7", "Cmaj7", "G/B"],
        "track_order": TRACKS,
        "tracks": [{"name": n, "entry_bar": entry[n], "notes": sum(1 for e in parts[n].ev if e[1])} for n in TRACKS],
    }


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "out")
    p = compose()
    write(p, out)
    with open(os.path.join(out, "arrangement.json"), "w") as f:
        json.dump(plan(p), f, indent=2)
    print(json.dumps(plan(p), indent=2))
