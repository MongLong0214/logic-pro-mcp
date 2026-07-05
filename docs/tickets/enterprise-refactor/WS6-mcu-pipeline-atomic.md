# WS6: MCU feedback pipeline — fix 2-site ordering race (ATOMIC across 3 dirs)

**PRD**: G1, §3.2 WS6, §4 E5/E5b
**Priority**: P1 (concurrency correctness) | **Size**: M | **Risk**: L-M
**Owns (EXCLUSIVE)**: `Channels/MCUChannel.swift` + `Server/LogicProServer.swift` (MCU fan-out only — WS6 owns ALL of this file so WS4 never touches it) + `MIDI/{MCUFeedbackParser.swift, MIDIFeedback.swift, MCUProtocol.swift}` + `State/StateCache.swift` (boomer ticket-R1 #1 — AC3 adds `updateMCUConnection(mutator:)`; **WS4 MUST NOT touch StateCache.swift**) + new test files `Tests/LogicProMCPTests/{MCUFeedbackOrderingTests,MIDIFeedbackStatusByteTests}.swift` (WS6-created, excluded from WS8). MUST NOT touch other MIDI/ files (→ WS5), other Channels (→ WS1/WS2), or existing test files.
**Parallel-safe with**: WS1/2/3/4/5/7 (LogicProServer & the 3 MIDI files are WS6-exclusive).

## 1. Objective
Replace BOTH per-event unstructured `Task{}` fan-outs (MCUChannel:180 + LogicProServer:1051) with ONE ordered single-consumer stream, so MCU feedback (fader/pan/LCD/select) is processed in arrival order — fixing the false State A/B on MCU-verified ops (probable historical "MCU echo flake", PR #153).

## 2. Acceptance Criteria
- AC1: `ProductionMCUTransport` yields parsed events into an `AsyncStream` continuation (synchronous `.yield`, FIFO-preserving) from the CoreMIDI callback; MCUChannel drains with ONE long-lived `for await event in stream { await receiveFeedback(event) }` task created in `start()`, cancelled in `stop()`. Both old `Task{}` fan-outs removed. Buffer `.unbounded` (no dropped echoes). Mirror the existing `MIDIEngine.inboundMessages` design.
- AC2: MCUFeedbackParser bank-offset fix (audit #6): master fader (ch 8) is bank-invariant → `channel==8 ? 8 : Int(channel)+offset` (was corrupting an unrelated track's cached volume + breaking set_master_volume echo).
- AC3: MCUFeedbackParser conn get/mutate/set made atomic (audit #7): add `StateCache.updateMCUConnection(mutator:)`; the #1 single-consumer already serializes this, but make it structurally safe.
- AC4: MIDIFeedback System Common/Real-Time status bytes (0xF1-0xF6/0xF8-0xFF ≠ 0xF0) handled explicitly (audit #5): currently double-consumed (i+=1 at both :70 and :132) + corrupt runningStatus → silently drops next message. `[0xF8,0x90,0x3C,0x64]` must yield the note-on event, not 0 events.
- AC5: Dead MCUProtocol HandshakeResult/parseDeviceResponse + unconstructable `.timeout` (audit #29) deleted.
- AC6: `swift test --no-parallel` green + NEW parser/lifecycle tests (below). Severity note: this is P1 not P0 — set_volume/set_pan are [.accessibility]-primary with AX readback (insulated); only mixer.set_master_volume [.mcu] + get_state depend on the echo.

## 3. TDD / Verification (boomer PRD-R2 #5 + R2 #3 REQUIRED before merge)
NEW tests, RED-first:
- MCU stream lifecycle (E5): **burst FIFO ordering** (feed e1,e2,e3 rapidly → parser sees them in order); **start-stop-start** (no crash, fresh stream); **post-stop feedback ignored** (events after stop() don't mutate cache); **no parser task leak** (task cancelled on stop).
- MIDIFeedback status-byte (E5b): **realtime interleaving** (0xF8/0xFA mid-message must not corrupt running status); **System Common consumption** (0xF1-0xF6 consumed without dropping the following channel-voice event); the `[0xF8,0x90,0x3C,0x64]`→note-on trace.
- Bank offset: master-fader (ch8) update does NOT shift with bank; a banked track fader does.
Flip-test the ordering test: with the old `Task{}` fan-out, the FIFO test must FAIL (proves it catches the race).

## 4. Constraints
- Wire-preserving: the MCU-verified op RESPONSES (set_master_volume echo State A/B) must keep their exact shape; only the internal ordering changes. Golden-snapshot the MCU op envelopes pre/post = 0 diff.
- LogicProServer.swift: touch ONLY the MCU fan-out region (~1051) + whatever the stream wiring needs; do NOT touch deadline-race scaffolding (NG12) or other server logic.
- Commit: `fix(#WS6): serialize MCU feedback via single ordered consumer (2-site Task{} race)`.

## 5. Review Checklist
- [ ] Both fan-out sites replaced by ONE ordered consumer; start/stop lifecycle correct
- [ ] FIFO/start-stop/post-stop/no-leak tests (FIFO flip-test fails on old code)
- [ ] MIDIFeedback status-byte tests (realtime + System Common)
- [ ] bank-offset master-fader fix + test
- [ ] Full suite green; MCU op golden envelopes diff = 0; LogicProServer non-MCU logic untouched
