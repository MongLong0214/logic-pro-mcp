#!/usr/bin/env python3
"""Live proof that the running server publishes no inbound MIDI destination, and still a source.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_755_no_inbound_destination_is_published.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
The server published `LogicProMCP-MIDI-In`, accepted everything sent to it, parsed it, and dropped
it: `inboundMessages` had no production consumer. A client sending to that port got no error and no
effect and could not tell "delivered and ignored" from "delivered and acted on" — the worst of the
three available states (#755).

WHY THIS IS A HARNESS AND NOT A UNIT TEST
-----------------------------------------
A unit test can assert that `startResources` no longer calls `createDestination`. It cannot say what
CoreMIDI shows other processes, which is the entire subject: the complaint was about a port on the
system, and the fix is that the port is not there. So this asks CoreMIDI, from a separate process,
while the product is running.

The absence is measured against a POSITIVE control in the same reading. `LogicProMCP-MIDI-Internal`
must still be published as a source — otherwise "the destination is gone" is also satisfied by a
server that failed to start, by a CoreMIDI client that saw nothing, and by an enumerator that
returned an empty list. That pairing is what makes the zero mean something.

This is a `non_ui` run: there is no rectangle to photograph, and #754 is the affordance that lets a
change with no UI surface prove itself. `is_clean` requires a counterexample for that class, which
is right — with no visual evidence, the falsifiable check is the whole instrument.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


# What this harness proves, for `harness_evidence_coverage.py`.
COVERS = [
    "Sources/LogicProMCP/MIDI/MIDIEngine.swift",
    "Sources/LogicProMCP/Server/ServerConfig.swift",
]

SINK = "LogicProMCP-MIDI-In"
SOURCE = "LogicProMCP-MIDI-Internal"

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

# A bare CoreMIDI client in its own process. It must not be the product's: asking the server what
# it published would be asking the accused, and a server that never created the endpoint and one
# that forgot it exists give the same answer.
ENUMERATOR_SOURCE = r'''import CoreMIDI
import Foundation

func name(_ endpoint: MIDIEndpointRef) -> String? {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &value) == noErr,
          let value else { return nil }
    return value.takeRetainedValue() as String
}

var client: MIDIClientRef = 0
let status = MIDIClientCreateWithBlock("LogicProMCP #755 endpoint census" as CFString, &client) { _ in }
guard status == noErr else {
    let payload: [String: Any] = ["ok": false, "error": "client creation failed", "status": Int(status)]
    FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))
    exit(0)
}
defer { MIDIClientDispose(client) }

let destinations = (0..<MIDIGetNumberOfDestinations()).compactMap { name(MIDIGetDestination($0)) }
let sources = (0..<MIDIGetNumberOfSources()).compactMap { name(MIDIGetSource($0)) }
let payload: [String: Any] = ["ok": true, "destinations": destinations, "sources": sources]
FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8))
'''


def compile_enumerator():
    """Build the census tool outside the worktree, so the run leaves no artefact in the repo."""
    source = Path(ev.dir) / "live_755_endpoint_census.swift"
    tool = Path(ev.dir) / "live_755_endpoint_census"
    source.write_text(ENUMERATOR_SOURCE, encoding="utf-8")
    result = subprocess.run(["swiftc", "-O", str(source), "-o", str(tool)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"cannot run: the endpoint census did not compile\n{result.stderr[:800]}")
    return tool


def census(tool):
    result = subprocess.run([str(tool)], capture_output=True, text=True)
    try:
        return json.loads(result.stdout or "{}")
    except ValueError:
        return {"ok": False, "error": "census emitted no JSON", "stdout": result.stdout[:400]}


enumerator = compile_enumerator()

# Read BEFORE the server exists, so the after-reading has something to be different from. A port
# absent both times proves nothing about this change on a host that never had it.
before = census(enumerator)

d = E.Driver()
time.sleep(5)
# Touch the product so the receipt records a run that drove something, and so the reading below is
# taken while the MIDI engine is up rather than during startup. A tool call rather than a resource
# read on purpose: `logic://health` is served from the poller cache, and the framework rightly
# records that as a cached read presented as live, which invalidates the run.
d.tool("logic_system", "refresh_cache")
after = census(enumerator)

ev.falsifiable(
    "755/no-inbound-destination-is-published-while-a-source-is",
    lambda o: SINK not in o["destinations"] and SOURCE in o["sources"],
    after,
    {"ok": True, "destinations": [SINK], "sources": [SOURCE]},
    f"CoreMIDI shows no {SINK} destination while the server is running, and does show its "
    f"{SOURCE} source — the second half is the positive control: without it the absence is also "
    f"satisfied by a server that never started and by an enumerator that read nothing",
    mutation="restore the `runtime.createDestination` call in `MIDIEngine.startResources`",
)

ev.check("755/the-source-was-published-by-this-run",
         SOURCE not in (before.get("sources") or []) and SOURCE in (after.get("sources") or []),
         "the source is absent before the server starts and present after, so the reading is about "
         "this process rather than about whatever the host already had",
         f"before={before.get('sources')!r} after={after.get('sources')!r}", None)

ev.check("755/the-census-itself-answered",
         bool(before.get("ok")) and bool(after.get("ok")),
         "the CoreMIDI client was created and both readings are answers rather than failures — an "
         "instrument that could not look is not evidence of absence",
         f"before_ok={before.get('ok')!r} after_ok={after.get('ok')!r}", None)

d.close()
out = ev.write()
print(json.dumps(out, indent=1))
sys.exit(0 if E.is_clean(out) else 1)
