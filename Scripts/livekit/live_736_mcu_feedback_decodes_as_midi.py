#!/usr/bin/env python3
"""Live proof that MCU feedback reaches the parser as MIDI 1.0 bytes, not as UMP memory image.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo MCU_TRACE=1 \
        python3 live_736_mcu_feedback_decodes_as_midi.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
The MCU port is created `MIDIDestinationCreateWithProtocol(..., ._1_0, ...)`, so CoreMIDI delivers
MIDI 1.0 messages wrapped in 32-bit UMP words. The callback sliced those words' little-endian MEMORY
IMAGE and handed it to a byte-stream parser. A word is

    (0x2 << 28) | (group << 24) | (status << 16) | (data1 << 8) | data2

and its bytes in memory are `[data2, data1, status, 0x20|group]` -- reversed. Measured 2026-09-08:
161 packets from Logic produced 8 events instead of 112, because a four-byte packet leaves one byte
after the status and every two-data-byte message failed its guard. Every fader echo was dropped,
which is what `echo_timeout_500ms` was (#736).

WHY THIS IS A HARNESS AND NOT A UNIT TEST
-----------------------------------------
`MIDIFeedbackUMPConversionTests` asserts the conversion against words written out by hand. It cannot
say what CoreMIDI actually hands this callback on this host, and that is the entire subject: the
defect was invisible to unit tests for a year because the fixture was built the way the code READ
rather than the way CoreMIDI WRITES. So this reads what the running product traced from a real
Logic, from outside the product.

THE COUNTEREXAMPLE
------------------
A MIDI 1.0 frame begins with a status byte, which has bit 7 set. The UMP memory image begins with
`data2`, which is a 7-bit value and so has bit 7 CLEAR. That single bit separates the two readings,
and the pre-fix trace shows it directly: `00 00 d0 20` began with `0x00`.

The absence of the broken shape is measured against a POSITIVE control in the same reading -- the
trace must contain frames at all. Without that, "no frame starts with a data byte" is also satisfied
by a server that traced nothing, by a Logic that sent nothing, and by a surface with no MCU binding.
That pairing is what makes the zero mean something.

This is a `non_ui` run: there is no rectangle to photograph.
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


COVERS = [
    "Sources/LogicProMCP/MIDI/MIDIFeedback.swift",
    "Sources/LogicProMCP/Server/LogicProServer.swift",
]

WT = sys.argv[1] if len(sys.argv) > 1 else ""
HEAD = sys.argv[2] if len(sys.argv) > 2 else ""
if not WT or not HEAD:
    sys.exit(__doc__)

E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
missing = E.have_tools()
if missing:
    sys.exit(f"cannot run: missing {missing}")

ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")

# The trace is gated on this in the product, and the harness must set it before the server starts
# rather than assume the operator did.
os.environ["MCU_TRACE"] = "1"

d = E.Driver()
# Logic answers the device query within a second on a bound surface; the extra time is for the
# state burst that follows it (meters, LCD, fader positions).
time.sleep(8)
# `refresh_cache`, not `health`: health is served from the poller cache, and the framework records
# a cached read presented as live — which invalidates the run, correctly. The call is here to touch
# the product so the receipt records a run that drove something, not to read MCU state; the MCU
# state this harness is about comes from the trace, which the callback writes as packets arrive.
d.tool("logic_system", "refresh_cache")
time.sleep(2)
stderr = open(d._stderr_path, encoding="utf-8", errors="replace").read()

rx = [m.group(1).split() for m in re.finditer(r"MCU RX: ([0-9a-f ]+)", stderr)]
tx = [m.group(1).split() for m in re.finditer(r"MCU TX: ([0-9a-f ]+)", stderr)]
first_bytes = [int(f[0], 16) for f in rx if f]
data_first = [f for f in rx if f and int(f[0], 16) < 0x80]

reading = {
    "rx_frames": len(rx),
    "tx_frames": len(tx),
    "frames_starting_with_a_data_byte": len(data_first),
    "first_bytes_seen": sorted({hex(b) for b in first_bytes})[:12],
    "sample_frames": [" ".join(f) for f in rx[:4]],
}

ev.falsifiable(
    "736/traced-mcu-frames-start-with-a-status-byte",
    lambda o: o["rx_frames"] > 0 and o["frames_starting_with_a_data_byte"] == 0,
    reading,
    {"rx_frames": 4, "tx_frames": 1, "frames_starting_with_a_data_byte": 4,
     "first_bytes_seen": ["0x0"], "sample_frames": ["00 00 d0 20"]},
    "every frame the callback handed the parser begins with a byte whose bit 7 is set, which is a "
    "MIDI status byte -- and none begins with a 7-bit data byte, which is what the UMP memory image "
    "produced. The counterexample is the pre-fix reading verbatim: `00 00 d0 20`, four frames, all "
    "starting 0x00",
    mutation="restore `Array(raw.prefix(wordCount * 4))` in the MCU receive callback",
)

ev.check("736/the-trace-carried-frames-at-all",
         len(rx) > 0,
         "frames were traced, so 'none starts with a data byte' is a reading rather than the "
         "silence of a server that traced nothing or a Logic that sent nothing",
         f"rx={len(rx)} tx={len(tx)}", None)

ev.check("736/the-server-transmitted-as-well-as-received",
         len(tx) > 0,
         "the device query went out, so the MCU channel started and the port exists -- without this "
         "an empty RX set could mean the channel never came up",
         f"tx_frames={len(tx)}", None)

# CLOSE AFTER the checks, not before. Each check records a blocking-modal snapshot, and the detector
# reads the running application — with the driver already closed every snapshot came back `unknown`,
# which `is_clean` refuses and rightly so: a check recorded while nothing could be inspected is not a
# check taken under known conditions.
d.close()

out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
