#!/usr/bin/env python3
"""Live proof that a client which stops draining stdout no longer parks the whole server.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_683_a_stalled_reader_does_not_park_the_writer.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`SerializedStdioTransport` wrote each frame on one serial queue with a blocking write that had no
deadline. Reproduced on the release binary 2026-09-08 with stdout on a FIFO whose reader never
reads: `sample` showed **1539 of 1539** samples parked in `writeAll` -> `Darwin.write`. The process
stayed alive and answered nothing — and because the queue is serial, replies AND the 25s
`operation_timeout` envelopes queued behind that one write. That is why "no response, ever, not even
a timeout" was the reported signature rather than a puzzle (#683).

WHY THIS IS A HARNESS AND NOT A UNIT TEST
-----------------------------------------
`SerializedStdioTransportStallTests` drives the transport directly with an injected 0.2s deadline.
It cannot say what the SHIPPED binary does with its compiled-in 30s deadline against a real pipe
that a real client stopped draining — and that is the whole subject: the defect was a property of
the running process, observed with `sample`, not of a type in isolation.

THE COUNTEREXAMPLE
------------------
The pre-fix reading verbatim: every sample of the write thread inside `writeAll`. The check is that
after the deadline has passed, the write queue is NOT parked there. A server that exited, or one
whose thread is idle, both satisfy that — so the reading also records whether the process is alive,
and the run drives it first so a dead server cannot pass by having never started.

This is a `non_ui` run: there is no rectangle to photograph.
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

COVERS = ["Sources/LogicProMCP/Server/SerializedStdioTransport.swift"]

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

# FIRST, drive the product normally. Two reasons, and the second is the one that matters:
#   1. `is_clean` requires `operations_driven > 0` — a run that only watched a process has not
#      driven the subject, and this harness spawns its second server directly.
#   2. It is the positive control for the whole reading. "The write queue is not parked" is also
#      true of a binary that cannot serve anything at all; a normal request answered normally, from
#      this same binary, is what rules that out before the stall is set up.
control = E.Driver()
control.tool("logic_system", "refresh_cache")
control.close()

work = ev.dir
sin, sout = os.path.join(work, "683.in"), os.path.join(work, "683.out")
for p in (sin, sout):
    if os.path.exists(p):
        os.unlink(p)
    os.mkfifo(p)

# A reader that OPENS stdout and never reads it: the shape of a client that stopped draining.
holder = subprocess.Popen(["/bin/sh", "-c", f'exec 3> "{sin}"; exec 4< "{sout}"; sleep 180'])
server = subprocess.Popen([E.BIN], stdin=open(sin, "r"), stdout=open(sout, "w"),
                          stderr=subprocess.DEVNULL)
time.sleep(5)

with open(sin, "w") as f:
    f.write('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05",'
            '"capabilities":{},"clientInfo":{"name":"p","version":"1"}}}\n')
    f.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    f.flush()
    # Well past a 64KB pipe buffer: tools/list carries ten tools with full schemas.
    for i in range(2, 41):
        f.write('{"jsonrpc":"2.0","id":%d,"method":"tools/list","params":{}}\n' % i)
    f.flush()

# The shipped deadline is 30s and is not injectable into the binary, so the wait is real.
time.sleep(38)

alive = server.poll() is None

# ALIVE IS NOT ANSWERING, and the earlier version of this harness recorded the first and claimed the
# second. A process that is up and a write queue that is not parked are both true of a server that
# has stopped serving; the defect's own signature was "no response, ever". So the reader starts
# draining, a fresh request goes in, and its reply is read back BY ITS ID. Found by review 2026-09-09.
answered = False
answer_note = "not attempted"
if alive:
    try:
        drain = os.open(sout, os.O_RDONLY | os.O_NONBLOCK)
        with open(sin, "w") as f:
            f.write('{"jsonrpc":"2.0","id":9001,"method":"tools/list","params":{}}\n')
            f.flush()
        buf, until = b"", time.time() + 45
        while time.time() < until:
            try:
                chunk = os.read(drain, 65536)
            except BlockingIOError:
                chunk = b""
            except OSError as exc:
                answer_note = f"read failed: {exc}"
                break
            if chunk:
                buf += chunk
                # A COMPLETE object, not the substring. `b'"id":9001' in buf` is satisfied by a
                # reply that arrived half-written — which is the very thing a stalled writer
                # produces, so the check could have been met by the defect it is testing for.
                # Demonstrated by review 2026-09-09 on the literal `{"jsonrpc":"2.0","id":9001`.
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(message, dict) and message.get("id") == 9001:
                        answered = True
                        break
                if answered:
                    break
            else:
                time.sleep(0.2)
        os.close(drain)
        answer_note = answer_note if answer_note.startswith("read failed") else (
            f"reply to id 9001 {'parsed as a complete object' if answered else 'never arrived'}")
    except Exception as exc:            # noqa: BLE001 - the note carries the reason into the document
        answer_note = f"could not drain: {exc}"

sample_path = os.path.join(work, "683.sample.txt")
subprocess.run(["sample", str(server.pid), "2", "-mayDie", "-file", sample_path],
               capture_output=True)
text = open(sample_path, encoding="utf-8", errors="replace").read() if os.path.exists(sample_path) else ""
block = re.search(r"logic-pro-mcp\.stdio\.write.*?(?=\n\n)", text, re.S)
parked = bool(block and "writeAll" in block.group(0) and "Darwin.write" in block.group(0))

reading = {
    "server_alive_after_deadline": alive,
    "write_queue_parked_in_writeAll": parked,
    "answered_after_the_stall": answered,
    "sample_bytes": len(text),
}

ev.falsifiable(
    "683/a-stalled-reader-does-not-park-the-write-queue",
    lambda o: (o["sample_bytes"] > 0
               and not o["write_queue_parked_in_writeAll"]
               and o["server_alive_after_deadline"]
               and o["answered_after_the_stall"]),
    reading,
    {"server_alive_after_deadline": True, "write_queue_parked_in_writeAll": True,
     "answered_after_the_stall": False, "sample_bytes": 495662},
    "after the write deadline has passed the serial write queue is not parked in `writeAll`, the "
    "process is still up, and it ANSWERS a fresh request once the reader drains — the counterexample "
    "is the pre-fix reading, where 1539 of 1539 samples were inside one frame and nothing was "
    "answered for as long as it was watched. Alive and unparked are both true of a server that has "
    "stopped serving, so the reply is read back by its id rather than inferred",
    mutation="remove the `waitUntilWritable` guard from `SerializedStdioTransport.send`",
)

ev.check("683/the-sampler-actually-read-the-process",
         len(text) > 0,
         "`sample` produced output, so 'not parked' is a reading rather than the silence of a "
         "sampler that could not attach",
         f"sample_bytes={len(text)}", None)

ev.check("683/the-stalled-server-still-answers",
         answered,
         "a request sent AFTER the stall was answered once the reader drained, so the process is "
         "serving rather than merely running. `pid > 0` stood here before and is true of a process "
         "that answers nothing — a check that cannot fail for the reason it names",
         answer_note, None)

for p in (server, holder):
    try:
        p.kill()
    except Exception:
        pass
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
