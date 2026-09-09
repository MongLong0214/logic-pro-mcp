#!/usr/bin/env python3
"""A reference decode of the captured MCU trace, so #736's ticket can be checked before it is built.

Deliberately NOT named `check-*` or `test_*`: `run-repo-guards.py` discovers those and runs them as
guards, and this is not a guard. It is an ORACLE — the numbers a correct UMP-to-MIDI-1.0 conversion
must produce from `docs/observations/evidence/2026-09-08-mcu-feedback-trace-en.json`, so an
implementer can diff their Swift against something that already ran rather than against a number
someone wrote in a ticket.

    $ python3 Scripts/mcu-ump-reference-decode.py
    events after conversion   112   {'0xd0': 8, '0xb0': 20, '0x90': 73, '0xe0': 11}
    unconverted words          96
    pitch bends               ch0..ch8 = 12443, ch9 = 0, ch0 = 8192

WHAT IT IS NOT. It is not a second implementation to keep in sync with the product — it reads one
frozen capture and will not be updated when the Swift changes. If the two disagree, the capture and
the UMP layout decide which is wrong, not this file. Its whole life is the interval between the
ticket being written and the ticket being closed; delete it then.
"""
import collections
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRACE = os.path.join(REPO, "docs", "observations", "evidence",
                     "2026-09-08-mcu-feedback-trace-en.json")

# How many data bytes a MIDI 1.0 status byte carries. The product's converter needs the same table,
# and getting `0xD0` wrong here is what let a misparsed meter message look like a real reading.
def data_byte_count(status):
    high = status & 0xF0
    if high in (0x80, 0x90, 0xA0, 0xB0, 0xE0):
        return 2
    if high in (0xC0, 0xD0):
        return 1
    if high == 0xF0:
        return {0xF1: 1, 0xF3: 1, 0xF2: 2}.get(status, 0)
    return 2


def word_count(message_type):
    """How many 32-bit words a UMP message of this type occupies.

    The stride is the UMP size table, not one. Advancing a single word past a multi-word message
    reads its continuation as a header, which FABRICATES a message whenever that continuation looks
    like channel voice. This oracle carried the one-word default until 2026-09-09, which is to say
    it encoded the same defect it exists to catch, and its `unconverted` counted MESSAGES while
    calling them words.
    """
    if message_type in (0x0, 0x1, 0x2, 0x6, 0x7):
        return 1
    if message_type in (0x3, 0x4, 0x8, 0x9, 0xA):
        return 2
    if message_type in (0xB, 0xC):
        return 3
    return 4                                          # 0x5, 0xD, 0xE, 0xF


def midi1_bytes(words):
    """UMP words -> a MIDI 1.0 byte stream, plus the count of words this does not convert.

    A word is (0x2 << 28) | (group << 24) | (status << 16) | (data1 << 8) | data2, so the bytes are
    read OUT of the word rather than out of its memory image. The stride matters as much as the
    order: advancing one word past a 64-bit message reads its second word as a header, which turns a
    missing event into a fabricated one.
    """
    out, unconverted, i = [], 0, 0
    while i < len(words):
        word = words[i]
        message_type = (word >> 28) & 0xF
        size = word_count(message_type)
        if i + size > len(words):                     # a message whose words are not all here
            unconverted += len(words) - i
            break
        if message_type == 0x0:                       # utility: no MIDI 1.0 message, none lost
            pass
        elif message_type in (0x1, 0x2):              # system, and MIDI 1.0 channel voice
            status = (word >> 16) & 0xFF
            data1 = (word >> 8) & 0xFF
            data2 = word & 0xFF
            count = data_byte_count(status)
            framing_in_the_wrong_type = message_type == 0x1 and status in (0xF0, 0xF7)
            if framing_in_the_wrong_type:
                unconverted += size
            elif count == 0:
                out += [status]
            elif count == 1 and data1 < 0x80:
                out += [status, data1]
            elif count == 2 and data1 < 0x80 and data2 < 0x80:
                out += [status, data1, data2]
            else:                                     # a data byte with bit 7 set is not a data byte
                unconverted += size
        else:
            unconverted += size
        i += size
    return out, unconverted


def parse_bytes(stream):
    """A faithful port of `MIDIFeedback.parseBytes`' channel-voice branch, guards included."""
    out, i, running = [], 0, 0
    while i < len(stream):
        b = stream[i]
        if b == 0xF0:
            running = 0
            try:
                j = stream.index(0xF7, i)
            except ValueError:
                out.append("sysex")
                break
            out.append("sysex")
            i = j + 1
            continue
        if b >= 0xF8:
            i += 1
            continue
        if b >= 0xF1:
            running = 0
            i += 1 + {0xF1: 1, 0xF2: 2, 0xF3: 1}.get(b, 0)
            continue
        if b & 0x80:
            running = b
            status = b & 0xF0
            i += 1
        elif running:
            status = running & 0xF0
        else:
            i += 1
            continue
        if status in (0x90, 0x80, 0xB0, 0xE0, 0xA0):
            if i + 1 < len(stream):
                out.append(hex(status))
                i += 2
                continue
            i += 1
            continue
        if status in (0xC0, 0xD0):
            if i < len(stream):
                out.append(hex(status))
                i += 1
                continue
            break
        i += 1
    return out


def main():
    trace = json.load(open(TRACE, encoding="utf-8"))
    packets = [[int(b, 16) for b in line.split()] for line in trace["rx"]]

    events = collections.Counter()
    unconverted = 0
    bends = []
    for packet in packets:
        words = [int.from_bytes(packet[k:k + 4], "little") for k in range(0, len(packet), 4)]
        stream, skipped = midi1_bytes(words)
        unconverted += skipped
        for event in parse_bytes(stream):
            events[event] += 1
        i = 0
        while i < len(stream):
            if stream[i] & 0xF0 == 0xE0 and i + 2 < len(stream):
                bends.append((stream[i] & 0x0F, stream[i + 1] | (stream[i + 2] << 7)))
                i += 3
            else:
                i += 1

    print("packets in the capture     %d" % len(packets))
    print("events after conversion    %d   %s" % (sum(events.values()), dict(events)))
    print("unconverted words          %d" % unconverted)
    print("pitch bends                %s" % (bends,))

    # The ticket's acceptance criteria, ASSERTED. The pitch-bend payloads were printed and not
    # checked until a merge-gate inventory observed that an oracle which only prints a value cannot
    # disagree about it — the same defect class as a test that cannot fail, in the file whose job is
    # to be the thing the implementation is checked against.
    EXPECTED_BENDS = [(0, 12443), (1, 12443), (2, 12443), (3, 12443), (4, 12443), (5, 12443),
                      (6, 12443), (7, 12443), (8, 12443), (9, 0), (0, 8192)]
    if bends != EXPECTED_BENDS:
        print("ORACLE DISAGREES: decoded pitch-bend payloads are %s, expected %s"
              % (bends, EXPECTED_BENDS), file=sys.stderr)
        return 1
    expected = {"0xd0": 8, "0xb0": 20, "0x90": 73, "0xe0": 11}
    if dict(events) != expected:
        print("ORACLE DISAGREES with the ticket: expected %s" % expected, file=sys.stderr)
        return 1
    # EXACTLY 96, not "more than zero". A `> 0` assertion cannot see a wrong word STRIDE: advancing
    # one word past a 64-bit message makes its second word look like a header, and in this capture
    # those continuation words carry a message type nothing converts — so they land in `unconverted`
    # and the EVENT counts do not move at all. Measured while mutation-testing this file: the stride
    # bug the ticket calls load-bearing passed a `> 0` check and fails an exact one.
    #
    # The stride is still not fully covered here — this capture contains no 64-bit message whose
    # second word would decode as a plausible channel-voice header, which is the case that fabricates
    # an event rather than miscounting one. The ticket covers that with a synthetic packet; this
    # oracle covers only what the capture can see, and says so rather than implying more.
    # 192, not 96, and the change is a UNIT rather than a measurement: every unconverted message in
    # this capture is a 64-bit SysEx7 packet, so 96 messages are 192 words. The old figure came from
    # a loop that counted messages while its own name and its caller said words — the same defect
    # the product carried, in the oracle written to catch it.
    #
    # The event side is unchanged by the correction: 112 events, the same
    # {0xd0: 8, 0xb0: 20, 0x90: 73, 0xe0: 11} split and the same eleven pitch bends. That is what
    # says the stricter reading drops no valid feedback — it refuses only what was already
    # unconverted.
    if unconverted != 192:
        print("ORACLE DISAGREES: expected 192 unconverted words, got %d" % unconverted,
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
