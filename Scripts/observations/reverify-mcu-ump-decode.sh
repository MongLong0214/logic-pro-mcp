#!/usr/bin/env bash
# Re-check 2026-09-08-mcu-feedback-is-decoded-as-if-it-were-midi-1.
# OFFLINE. It replays the captured trace through a faithful port of the shipped parser and through
# a UMP-correct read, and compares the event counts.
#
# This record is about a DEFECT, so the reverify passes while the defect is present and FAILS once
# the decode is fixed — at which point the record is superseded rather than stale, and the ticket
# it backs is done. A reverify that could only ever agree with itself would be worthless here.
set -uo pipefail
cd "$(dirname "$0")/../.."
python3 - docs/observations/evidence/2026-09-08-mcu-feedback-trace-en.json \
         Sources/LogicProMCP/Server/LogicProServer.swift <<'PY'
import json, sys, collections

trace = json.load(open(sys.argv[1]))
source = open(sys.argv[2], encoding="utf-8").read()
rx = [[int(b, 16) for b in line.split()] for line in trace["rx"]]

def parse_shipped(bs):
    """The shipped channel-voice branch, guards included, over raw memory bytes."""
    out, i, running = [], 0, 0
    while i < len(bs):
        b = bs[i]
        if b == 0xF0:
            running = 0
            try:
                j = bs.index(0xF7, i)
            except ValueError:
                out.append("sysex"); break
            out.append("sysex"); i = j + 1; continue
        if b >= 0xF8:
            i += 1; continue
        if b >= 0xF1:
            running = 0; i += 1 + {0xF1: 1, 0xF2: 2, 0xF3: 1}.get(b, 0); continue
        if b & 0x80:
            running = b; status = b & 0xF0; i += 1
        elif running:
            status = running & 0xF0
        else:
            i += 1; continue
        if status in (0x90, 0x80, 0xB0, 0xE0, 0xA0):
            if i + 1 < len(bs):
                out.append(hex(status)); i += 2; continue
            i += 1; continue                       # dropped: not enough data bytes
        if status in (0xC0, 0xD0):
            if i < len(bs):
                out.append(hex(status)); i += 1; continue
            break
        i += 1
    return out

def parse_ump(bs):
    """UMP words a correct reader turns into MIDI 1.0 messages — STRIDING by message type.

    This walked every fourth byte and asked whether it looked like message type 2, which counts the
    SECOND word of a 64-bit SysEx message as a channel-voice message. Measured 2026-09-08: that
    inflated the total from 112 to 121, and the nine extra carried status nibbles (0x50, 0x30, 0x20,
    0x00) that are not valid MIDI statuses at all. The record even noted nine odd nibbles and did not
    chase them; the cause was this missing stride. Found by a merge-gate inventory.
    """
    out = []
    words = [int.from_bytes(bs[k:k + 4], "little") for k in range(0, len(bs), 4)]
    i = 0
    while i < len(words):
        message_type = (words[i] >> 28) & 0xF
        if message_type in (0x1, 0x2):
            out.append(hex((words[i] >> 16) & 0xF0))
            i += 1
        elif message_type in (0x3, 0x4):
            i += 2
        elif message_type == 0x5:
            i += 4
        else:
            i += 1
    return out

shipped = collections.Counter(e for p in rx for e in parse_shipped(p))
correct = collections.Counter(e for p in rx for e in parse_ump(p))
print("  packets in the trace              %d" % len(rx))
print("  events the shipped read produces  %d  %s" % (sum(shipped.values()), dict(shipped)))
print("  events a UMP read would produce   %d" % sum(correct.values()))

still_slicing = "withUnsafeBytes(of: packetPtr.pointee.words)" in source
if not still_slicing:
    print("REVERIFY FAIL (in the good way): the callback no longer slices the words' memory image.")
    print("The decode has been changed. Re-measure and supersede this record — the defect it")
    print("describes may be gone, and a record that outlives its defect is worse than no record.")
    sys.exit(1)
for status, label in (("0xe0", "pitch bend / fader positions"), ("0xb0", "control change"), ("0x90", "note on")):
    if shipped.get(status):
        print("REVERIFY FAIL: the shipped read now produces %s (%s); the defect has changed shape"
              % (status, label))
        sys.exit(1)
if sum(shipped.values()) >= sum(correct.values()):
    print("REVERIFY FAIL: the two reads no longer disagree, so this record has nothing to say")
    sys.exit(1)
# WHAT THIS PASS MEANS, precisely. Everything above replays a frozen capture through a PORT of the
# shipped parser written in Python. It does not run the Swift, and the only thing tying it to the
# product is the substring check above. So a PASS says: the captured traffic, decoded the way the
# source still slices it, still yields 8 events instead of 112. It does NOT independently certify
# that today's binary behaves that way — a merge-gate inventory 2026-09-08 pointed out that the
# script claimed the stronger thing. The stronger claim needs the live harness, not this replay.
print("REVERIFY PASS — historical replay: the captured traffic still decodes to %d events instead of"
      % sum(shipped.values()))
print("  %d, and the callback still slices the words' memory image. This replays a frozen capture"
      % sum(correct.values()))
print("  through a PORT of the parser; it does not execute the shipped decoder.")
PY
