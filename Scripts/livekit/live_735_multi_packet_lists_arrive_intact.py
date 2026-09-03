#!/usr/bin/env python3
"""Drive CoreMIDI's real packet-list callback at the release server's MIDI-In endpoint (#735).

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_735_multi_packet_lists_arrive_intact.py <worktree> <full-40-char-head-sha>

The harness starts the release artifact, waits for its read-only ``logic_system health`` reply (the
startup readback; it is not a timed guess), then compiles a bare CoreMIDI client outside the worktree.
That client finds the PRODUCT's ``LogicProMCP-MIDI-In`` virtual destination and uses
``MIDIPacketListInit``/``MIDIPacketListAdd`` plus ``MIDISend`` to submit three independently-built
64-packet lists.  Their packet lengths rotate through 3, 4, 5, and 6 bytes, so the list both crosses
the imported ~266-byte value-copy window and cannot accidentally look correct to a fixed-stride walk.
Each successful send is followed by a product health read; no sleep is used as synchronisation.

WHAT THIS DOES NOT PROVE
------------------------
The product has no externally readable received-MIDI stream: ``MIDIEngine.inboundMessages`` is
declared but has no production subscriber, and ``MIDIFeedback.parse(packetList:into:)`` has no
production caller.  Consequently a live client cannot assert that all 192 packet byte arrays reached
the stream in order without adding an injected/debug read surface, which this harness intentionally
does not do.  It records every exact byte array it submitted, proves that CoreMIDI accepted each list
for the real product destination, and proves that the release server kept answering after each one.
Exact receipt/order for both traversal helpers remains covered by the #735 unit tests.

MUTATION CONTROL
----------------
The production callback at ``MIDIEngine.swift:48`` must call the pointer-backed
``MIDIEngine.receivePackets(from:onBytes:)`` while CoreMIDI owns the original buffer.  I actually
reverted that line to the former stack value-copy traversal, rebuilt a release artifact, and re-ran
this harness on 2026-09-02.  It did *not* go red: all three 64-packet ``MIDISend`` calls returned
``noErr`` and all following health reads answered.  That is consistent with CoreMIDI splitting a send
across callbacks on this host, but the product's missing received-MIDI read surface means the callback
shape is not observable; this harness therefore does **not** claim it detects the historical traversal
regression live.

The real ``mutation_claimed`` is narrower: replacing line 48 with
``fatalError("#735 callback reachability mutation")``, rebuilding release, and re-running made the
server exit on the first submitted list and the next health request raise ``BrokenPipeError``.  This
proves the list reaches that real production callback and makes the survival assertion fail.  It does
not turn the unavailable exact-receipt readback into a claim.
"""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402


# This literal declaration is consumed by harness_evidence_coverage.py without importing this file.
# The server's CoreMIDI destination callback is in MIDIEngine; MIDIFeedback's pointer parser has no
# production caller, a limitation the module docstring makes explicit rather than hiding.
COVERS = [
    "Sources/LogicProMCP/MIDI/MIDIEngine.swift",
    "Sources/LogicProMCP/MIDI/MIDIFeedback.swift",
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

# Declared, not inferred (#754): this path terminates inside the server, so there is no indicator,
# note, region or Event List row that can move, and a capture would photograph nothing that the
# change touched. The gate asks a non_ui document for a counterexample control instead — see
# `prove()` below, which supplies one per check — so the zeros here are earned, not waived.
ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")
checks = []
DESTINATION_NAME = "LogicProMCP-MIDI-In"
LIST_COUNT = 3
PACKETS_PER_LIST = 64
SENDER_SOURCE = r'''import CoreMIDI
import Foundation

let destinationName = "LogicProMCP-MIDI-In"
let requestedListIndex = Int(CommandLine.arguments.dropFirst().first ?? "-1") ?? -1

func emit(_ value: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

func endpointName(_ endpoint: MIDIEndpointRef) -> String? {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &value) == noErr,
          let value else { return nil }
    return value.takeRetainedValue() as String
}

func packets(for listIndex: Int) -> [[UInt8]] {
    (0..<64).map { packetIndex in
        let marker = UInt8((listIndex * 64 + packetIndex) & 0x7f)
        switch packetIndex % 4 {
        case 0: return [0x90, marker, 0x40]
        case 1: return [0xf0, 0x7d, marker, 0xf7]
        case 2: return [0xf0, 0x7d, 0x01, marker, 0xf7]
        default: return [0xf0, 0x7d, 0x01, 0x02, marker, 0xf7]
        }
    }
}

guard (0..<3).contains(requestedListIndex) else {
    emit(["ok": false, "error": "list index must be 0...2", "list_index": requestedListIndex])
}

var client: MIDIClientRef = 0
let clientStatus = MIDIClientCreateWithBlock("LogicProMCP #735 packet-list harness" as CFString, &client) { _ in }
guard clientStatus == noErr else {
    emit(["ok": false, "error": "MIDIClientCreateWithBlock failed", "client_status": Int(clientStatus)])
}
defer { MIDIClientDispose(client) }

var outputPort: MIDIPortRef = 0
let outputPortStatus = MIDIOutputPortCreate(client, "LogicProMCP #735 output" as CFString, &outputPort)
guard outputPortStatus == noErr else {
    emit(["ok": false, "error": "MIDIOutputPortCreate failed", "output_port_status": Int(outputPortStatus)])
}
defer { MIDIPortDispose(outputPort) }

let destination = (0..<MIDIGetNumberOfDestinations())
    .map(MIDIGetDestination)
    .first { endpointName($0) == destinationName }
guard let destination else {
    emit(["ok": false, "error": "product MIDI destination not found", "destination_name": destinationName,
          "destination_count": Int(MIDIGetNumberOfDestinations())])
}

let packetBytes = packets(for: requestedListIndex)
let payloadSize = packetBytes.reduce(0) { partial, packet in
    partial + max(MemoryLayout<MIDIPacket>.size, packet.count)
}
let bufferSize = max(1024, MemoryLayout<MIDIPacketList>.size + payloadSize)
var buffer = [UInt8](repeating: 0, count: bufferSize)
let sendStatus: OSStatus = buffer.withUnsafeMutableBytes { rawBuffer in
    let packetList = rawBuffer.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
    var currentPacket = MIDIPacketListInit(packetList)
    for bytes in packetBytes {
        bytes.withUnsafeBufferPointer { bytesBuffer in
            guard let base = bytesBuffer.baseAddress else { return }
            currentPacket = MIDIPacketListAdd(packetList, bufferSize, currentPacket, 0, bytes.count, base)
        }
    }
    return MIDISend(outputPort, destination, packetList)
}

emit([
    "ok": sendStatus == noErr,
    "client_status": Int(clientStatus),
    "destination_name": destinationName,
    "destination_found": true,
    "list_index": requestedListIndex,
    "packet_count": packetBytes.count,
    "packet_lengths": packetBytes.map(\.count),
    "packets": packetBytes.map { $0.map(Int.init) },
    "send_status": Int(sendStatus),
])
'''


def prove(tag, predicate, observation, counterexample, expected, mutation):
    """Record a testable assertion and an explicit same-shape wrong expectation."""
    passed = ev.falsifiable(tag, predicate, observation, counterexample, expected, mutation)
    checks.append(passed)
    return passed


def finish():
    summary = ev.write()
    print(json.dumps(summary, indent=1))
    return 0 if E.is_clean(summary) else 1


def compile_sender():
    """Compile the standalone CoreMIDI driver outside the worktree, once per evidence run."""
    source = Path(ev.dir) / "live_735_packet_list_sender.swift"
    tool = Path(ev.dir) / "live_735_packet_list_sender"
    source.write_text(SENDER_SOURCE, encoding="utf-8")
    result = subprocess.run(["swiftc", "-O", str(source), "-o", str(tool)],
                            capture_output=True, text=True)
    return tool, {
        "compiled": result.returncode == 0,
        "returncode": result.returncode,
        "stderr": (result.stderr or "")[:800],
    }


def send_packet_list(sender, list_index):
    """Ask the bare CoreMIDI client to build and submit one real 64-packet list."""
    result = subprocess.run([str(sender), str(list_index)], capture_output=True, text=True)
    try:
        payload = json.loads(result.stdout)
    except (TypeError, ValueError):
        payload = {
            "ok": False,
            "error": "sender did not emit one JSON object",
            "stdout": (result.stdout or "")[:800],
            "stderr": (result.stderr or "")[:800],
        }
    if not isinstance(payload, dict):
        payload = {"ok": False, "error": "sender emitted a non-object", "raw": repr(payload)[:800]}
    payload["returncode"] = result.returncode
    return payload


def health_is_live(reply):
    return isinstance(reply, dict) and "_transport_error" not in reply


def health_read(driver):
    """Turn a callback-induced broken pipe into the observable that this harness asserts on."""
    try:
        return driver.tool("logic_system", "health", {})
    except Exception as exc:  # noqa: BLE001 - product death is the observation, not a harness crash
        return {"_transport_error": repr(exc)}


def submitted_lists_are_accepted_and_server_survives(observation):
    """The consciously weaker live assertion available without a received-MIDI read surface."""
    if not isinstance(observation, dict):
        return False
    sends = observation.get("sends")
    health_reads = observation.get("health_after_each_send")
    if not (isinstance(sends, list) and len(sends) == LIST_COUNT
            and isinstance(health_reads, list) and len(health_reads) == LIST_COUNT):
        return False
    for expected_index, send in enumerate(sends):
        if not isinstance(send, dict):
            return False
        packets = send.get("packets")
        lengths = send.get("packet_lengths")
        if not (send.get("ok") is True and send.get("returncode") == 0
                and send.get("client_status") == 0 and send.get("send_status") == 0
                and send.get("destination_found") is True
                and send.get("destination_name") == DESTINATION_NAME
                and send.get("list_index") == expected_index
                and send.get("packet_count") == PACKETS_PER_LIST
                and isinstance(packets, list) and len(packets) == PACKETS_PER_LIST
                and isinstance(lengths, list) and len(lengths) == PACKETS_PER_LIST
                and lengths == [len(packet) for packet in packets]
                and set(lengths) == {3, 4, 5, 6}):
            return False
    return all(health_is_live(reply) for reply in health_reads)


def wrong_packet_count_counterexample(observation):
    """Retain the real sender record but make one claimed list one packet short."""
    counterexample = copy.deepcopy(observation)
    sends = counterexample.get("sends") if isinstance(counterexample, dict) else None
    if isinstance(sends, list) and sends and isinstance(sends[0], dict):
        sends[0]["packet_count"] = PACKETS_PER_LIST - 1
    return counterexample


sender, sender_build = compile_sender()
ev.note("735/bare-coremidi-sender-build", sender_build)
sender_ready = prove(
    "735/precondition-bare-coremidi-sender-compiles",
    lambda observed: observed.get("compiled") is True and observed.get("returncode") == 0,
    sender_build,
    {"compiled": False, "returncode": 1, "stderr": "compiler rejected the sender"},
    "a standalone CoreMIDI client can be compiled outside the product worktree",
    None,
)
if not sender_ready:
    sys.exit(finish())

driver = E.Driver()
try:
    startup_health = health_read(driver)
    startup_observation = {
        "health": startup_health,
        "server_pid": driver.proc.pid,
        "destination_expected": DESTINATION_NAME,
    }
    ev.note("735/startup-health-before-coremidi-drive", startup_observation)
    ready = prove(
        "735/precondition-release-server-answers-before-coremidi-drive",
        lambda observed: health_is_live(observed.get("health")),
        startup_observation,
        {**startup_observation, "health": {"_transport_error": "server did not answer"}},
        "the release artifact has completed enough startup to answer a read-only product health request",
        None,
    )
    if not ready:
        sys.exit(finish())

    sends = []
    health_after_each_send = []
    for list_index in range(LIST_COUNT):
        sends.append(send_packet_list(sender, list_index))
        # This product readback synchronises the next step: it catches a callback crash without
        # guessing a scheduler delay, and is intentionally done after EACH independently built list.
        health_after_each_send.append(health_read(driver))

    observation = {
        "sends": sends,
        "health_after_each_send": health_after_each_send,
        "packet_lists_requested": LIST_COUNT,
        "packets_per_list_requested": PACKETS_PER_LIST,
    }
    ev.note("735/coremidi-packet-lists-submitted", observation)
    prove(
        "735/all-64-packet-lists-are-accepted-and-release-server-keeps-answering",
        submitted_lists_are_accepted_and_server_survives,
        observation,
        wrong_packet_count_counterexample(observation),
        "three MIDIPacketListInit/MIDIPacketListAdd-built 64-packet lists with variable 3/4/5/6-byte "
        "packets are accepted by the PRODUCT's MIDI-In endpoint and every following health read answers",
        "replace MIDIEngine.swift:48's `MIDIEngine.receivePackets(from:onBytes:)` callback call with "
        "`fatalError(\"#735 callback reachability mutation\")`: verified 2026-09-02 by a rebuilt "
        "release artifact; its first received list terminated the server and the following health "
        "read was a BrokenPipeError",
    )
finally:
    driver.close()

sys.exit(finish())
