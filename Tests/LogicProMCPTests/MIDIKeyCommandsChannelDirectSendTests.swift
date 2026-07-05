import Foundation
import Testing
@testable import LogicProMCP

// T6 (PRD Issue#1 §4.3 / AC-1.1) — MIDIKeyCommandsChannel direct-send path.
//
// MIDIKeyCommandsChannel.execute now handles 7 new "midi.*.keycmd" ops by
// composing MIDI wire bytes locally and pushing them through the KeyCmd
// virtual transport (no CoreMIDI engine). Because Logic's KeyCmd port is
// send-only and gives us no echo, every success is encoded as Honest
// Contract State B `readback_unavailable`.
//
// Conventions (per ticket §3.3 + Phase 4 Loop 1 review):
// • The `channel` param arriving here is the wire byte (0..15). The dispatcher
//   layer (T5) is responsible for the 1-based → 0-based conversion. These
//   tests pass wire-byte values directly.
// • `pitch_bend.value` is **0..16383 absolute, center=8192** — wire is split
//   LSB(value & 0x7F) + MSB(value >> 7).
// • `play_sequence.keycmd` uses NoteSequenceParser (T3) Result API — any
//   parse failure surfaces as `invalid_params` State C, never silently drops.

private func makeStartedChannel() async throws -> (MIDIKeyCommandsChannel, MockKeyCmdTransport) {
    let transport = MockKeyCmdTransport()
    let channel = MIDIKeyCommandsChannel(transport: transport)
    try await channel.start()
    return (channel, transport)
}

private func decodeEnvelope(_ message: String) -> [String: Any]? {
    guard let data = message.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data),
          let dict = raw as? [String: Any] else { return nil }
    return dict
}

// MARK: - 1. CC

@Test func testKeycmdChannelHandlesSendCCKeycmdOp() async throws {
    let (channel, transport) = try await makeStartedChannel()

    let result = await channel.execute(operation: "midi.send_cc.keycmd", params: [
        "controller": "64",
        "value": "100",
        "channel": "0",
    ])

    #expect(result.isSuccess)
    let sent = await transport.sentBytes
    #expect(sent.count == 1)
    let envelope = decodeEnvelope(result.message)
    #expect((envelope?["success"] as? Bool)!)
    #expect(!((envelope?["verified"] as? Bool)!))
    #expect(envelope?["reason"] as? String == "readback_unavailable")
    #expect(envelope?["via"] as? String == "midi-keycmd-direct-send")
}

@Test func testKeycmdSendCCWireBytesCorrect() async throws {
    let (channel, transport) = try await makeStartedChannel()

    // controller=64 (sustain), value=100, channel wire byte = 15 (= ch 16 1-based)
    _ = await channel.execute(operation: "midi.send_cc.keycmd", params: [
        "controller": "64",
        "value": "100",
        "channel": "15",
    ])

    let sent = await transport.sentBytes
    #expect(sent.count == 1)
    #expect(sent[0] == [0xBF, 64, 100])
}

// MARK: - 2. Note

@Test func testKeycmdSendNoteWireBytes() async throws {
    let (channel, transport) = try await makeStartedChannel()

    // note=60 (C4), velocity=100, channel=0, very short duration to keep the
    // test fast. Implementation pairs each note with a Note Off after dur_ms.
    _ = await channel.execute(operation: "midi.send_note.keycmd", params: [
        "note": "60",
        "velocity": "100",
        "channel": "0",
        "duration_ms": "1",
    ])

    let sent = await transport.sentBytes
    // First message is Note On (status byte 0x90 + ch 0).
    #expect(sent.count >= 1)
    #expect(sent[0] == [0x90, 60, 100])
    // Second is Note Off (status byte 0x80 + ch 0, vel 0).
    if sent.count >= 2 {
        #expect(sent[1] == [0x80, 60, 0])
    }
}

@Test func testKeycmdSendNoteNoteOffFailureReturnsStateC() async throws {
    let (channel, transport) = try await makeStartedChannel()
    await transport.setFailOnSendAttempts([2])

    let result = await channel.execute(operation: "midi.send_note.keycmd", params: [
        "note": "60",
        "velocity": "100",
        "channel": "0",
        "duration_ms": "1",
    ])

    #expect(!result.isSuccess)
    let envelope = decodeEnvelope(result.message)
    #expect(envelope?["error"] as? String == "ax_write_failed")
    #expect(envelope?["operation"] as? String == "midi.send_note.keycmd")
    #expect((envelope?["note_off_failed"] as? Bool)!)
    #expect((envelope?["note_on_sent"] as? Bool)!)
    // Note-on (attempt 1) succeeded; the reliable note-off (attempt 2) failed and
    // is reported as note_off_failed; the best-effort retry note-off (attempt 3)
    // then succeeds and is recorded, so the note is still silenced.
    #expect(await transport.sentBytes == [[0x90, 60, 100], [0x80, 60, 0]])
}

// MARK: - 3. Chord

@Test func testKeycmdSendChordMultipleNotes() async throws {
    let (channel, transport) = try await makeStartedChannel()

    _ = await channel.execute(operation: "midi.send_chord.keycmd", params: [
        "notes": "60,64,67",         // C major triad
        "velocity": "80",
        "channel": "0",
        "duration_ms": "1",
    ])

    let sent = await transport.sentBytes
    // First 3 sends are Note On for each chord tone.
    #expect(sent.count >= 3)
    #expect(sent[0] == [0x90, 60, 80])
    #expect(sent[1] == [0x90, 64, 80])
    #expect(sent[2] == [0x90, 67, 80])
}

// MARK: - 4. Program Change

@Test func testKeycmdSendProgramChangeWire() async throws {
    let (channel, transport) = try await makeStartedChannel()

    _ = await channel.execute(operation: "midi.send_program_change.keycmd", params: [
        "program": "42",
        "channel": "5",
    ])

    let sent = await transport.sentBytes
    #expect(sent.count == 1)
    // Program Change is 2 bytes: 0xC0 | ch, program
    #expect(sent[0] == [0xC5, 42])
}

// MARK: - 5. Pitch Bend

@Test func testKeycmdSendPitchBendWire() async throws {
    let (channel, transport) = try await makeStartedChannel()

    // value=8192 (center, 0..16383 absolute)
    _ = await channel.execute(operation: "midi.send_pitch_bend.keycmd", params: [
        "value": "8192",
        "channel": "0",
    ])

    let sent = await transport.sentBytes
    #expect(sent.count == 1)
    // Pitch bend wire encoding: status 0xE0 | ch, LSB (val & 0x7F), MSB (val >> 7)
    // 8192 = 0b0100000_0000000 → LSB=0, MSB=64
    #expect(sent[0] == [0xE0, 0, 64])
}

// MARK: - 6. Aftertouch

@Test func testKeycmdSendAftertouchWire() async throws {
    let (channel, transport) = try await makeStartedChannel()

    _ = await channel.execute(operation: "midi.send_aftertouch.keycmd", params: [
        "value": "100",
        "channel": "0",
    ])

    let sent = await transport.sentBytes
    #expect(sent.count == 1)
    // Channel pressure: 0xD0 | ch, pressure
    #expect(sent[0] == [0xD0, 100])
}

// MARK: - 7. Play Sequence (success path)

@Test func testKeycmdPlaySequenceCallsParser() async throws {
    let (channel, transport) = try await makeStartedChannel()

    // 3 notes: C, E, G with 0ms offsets to keep the test instantaneous.
    let result = await channel.execute(operation: "midi.play_sequence.keycmd", params: [
        "notes": "60,0,1,100,1;64,0,1,100,1;67,0,1,100,1",
    ])

    #expect(result.isSuccess)
    let sent = await transport.sentBytes
    // Expect at least 3 Note On sends (Note Off may or may not be captured
    // depending on the impl — we only require the parser to be called and
    // each note dispatched).
    #expect(sent.count >= 3)
    let noteOnCount = sent.filter { bytes in
        bytes.count == 3 && (bytes[0] & 0xF0) == 0x90 && bytes[2] > 0
    }.count
    #expect(noteOnCount == 3)

    let envelope = decodeEnvelope(result.message)
    #expect(envelope?["reason"] as? String == "readback_unavailable")
    #expect(envelope?["via"] as? String == "midi-keycmd-direct-send")
    #expect(envelope?["note_count"] as? Int == 3)
}

@Test func testKeycmdPlaySequenceNoteOffFailureReturnsStateC() async throws {
    let (channel, transport) = try await makeStartedChannel()
    await transport.setFailOnSendAttempts([2])

    let result = await channel.execute(operation: "midi.play_sequence.keycmd", params: [
        "notes": "60,0,1,100,1",
    ])

    #expect(!result.isSuccess)
    let envelope = decodeEnvelope(result.message)
    #expect(envelope?["error"] as? String == "ax_write_failed")
    #expect(envelope?["operation"] as? String == "midi.play_sequence.keycmd")
    #expect((envelope?["note_off_failed"] as? Bool)!)
    #expect(envelope?["failed_note_off_count"] as? Int == 1)
    #expect(envelope?["note_on_count"] as? Int == 1)
    #expect(await transport.sentBytes == [[0x90, 60, 100]])
}

// MARK: - 8. Play Sequence (parser failure)

@Test func testKeycmdPlaySequenceFailureReturnsInvalidParams() async throws {
    let (channel, transport) = try await makeStartedChannel()

    // pitch=200 is out of 0..127 → NoteSequenceParser rejects.
    let result = await channel.execute(operation: "midi.play_sequence.keycmd", params: [
        "notes": "200,0,100",
    ])

    #expect(!result.isSuccess)
    let envelope = decodeEnvelope(result.message)
    #expect(!((envelope?["success"] as? Bool)!))
    #expect(envelope?["error"] as? String == "invalid_params")

    // No notes should have been sent.
    let sent = await transport.sentBytes
    #expect(sent.isEmpty)
}

// MARK: - 9. State B envelope shape

@Test func testKeycmdSuccessReturnsStateBEnvelope() async throws {
    let (channel, _) = try await makeStartedChannel()

    let result = await channel.execute(operation: "midi.send_cc.keycmd", params: [
        "controller": "7",
        "value": "64",
        "channel": "0",
    ])

    #expect(result.isSuccess)
    let envelope = decodeEnvelope(result.message)
    #expect((envelope?["success"] as? Bool)!)
    #expect(!((envelope?["verified"] as? Bool)!))
    #expect(envelope?["reason"] as? String == "readback_unavailable")
    #expect(envelope?["operation"] as? String == "midi.send_cc.keycmd")
    #expect(envelope?["via"] as? String == "midi-keycmd-direct-send")
}

// MARK: - 10. mappingTable lookup regression

@Test func testKeycmdMappingTableLookupStillWorks() async throws {
    let (channel, transport) = try await makeStartedChannel()

    // edit.undo (CC 30) — pure mapping-table path, unchanged by T6.
    let result = await channel.execute(operation: "edit.undo", params: [:])
    #expect(result.isSuccess)

    let sent = await transport.sentBytes
    // Original mappingTable behaviour: CC + release, both on ch 16 (status 0xBF).
    #expect(sent.count == 2)
    #expect(sent[0] == [0xBF, 30, 0x7F])
    #expect(sent[1] == [0xBF, 30, 0x00])

    // Envelope should still mark this as the legacy keycmd path, not the
    // new direct-send path.
    let envelope = decodeEnvelope(result.message)
    #expect(envelope?["method"] as? String == "midi_key_command")
}

// MARK: - 11. Unknown keycmd op

@Test func testKeycmdUnknownKeycmdOpReturnsError() async throws {
    let (channel, transport) = try await makeStartedChannel()

    let result = await channel.execute(operation: "midi.unknown_op.keycmd", params: [:])
    #expect(!result.isSuccess)
    let sent = await transport.sentBytes
    #expect(sent.isEmpty)
}

// MARK: - 12. Invalid params guard

@Test func testKeycmdSendCCInvalidParamsReturnsStateC() async throws {
    let (channel, transport) = try await makeStartedChannel()

    // controller=200 is outside 0..127.
    let result = await channel.execute(operation: "midi.send_cc.keycmd", params: [
        "controller": "200",
        "value": "100",
        "channel": "0",
    ])

    #expect(!result.isSuccess)
    let envelope = decodeEnvelope(result.message)
    #expect(!((envelope?["success"] as? Bool)!))
    #expect(envelope?["error"] as? String == "invalid_params")

    let sent = await transport.sentBytes
    #expect(sent.isEmpty)
}

// MARK: - 13. Router-level portUnavailable when transport not started
//
// E7 / Phase 6 P1-1 — when the KeyCmd channel is registered but its
// transport has NOT been started (start() never called → MockKeyCmdTransport
// remains in `prepared:false` state), `healthCheck()` reports
// `available:false`. ChannelRouter recognises bypass ops (the 7
// `midi.*.keycmd` keys) and translates `available:false` into a terminal
// Honest Contract State C `port_unavailable` envelope rather than a silent
// "no fallback" fall-through. This test exercises the real channel + real
// router integration path (T1 + T4 + T6 wired together).
@Test func testKeyCmdChannelTransportNotPublishedReturnsPortUnavailable() async {
    let transport = MockKeyCmdTransport()
    // NOTE: intentionally do NOT call `channel.start()` — transport stays
    // unprepared, so readiness().available == false.
    let channel = MIDIKeyCommandsChannel(transport: transport)

    let router = ChannelRouter()
    await router.register(channel)

    let result = await router.route(operation: "midi.send_cc.keycmd", params: [
        "controller": "64",
        "value": "100",
        "channel": "0",
    ])

    #expect(!result.isSuccess, "unstarted KeyCmd channel must surface State C, not silent success")

    let envelope = decodeEnvelope(result.message)
    #expect(!((envelope?["success"] as? Bool)!))
    #expect(envelope?["error"] as? String == "port_unavailable")
    #expect(envelope?["operation"] as? String == "midi.send_cc.keycmd")
    // Hint must propagate the channel's health detail so the agent gets an
    // actionable diagnostic (see T1 / ChannelRouter §4.1 step 7).
    #expect(!(((envelope?["hint"] as? String)?.isEmpty)!))

    // The transport must NOT have received any bytes — bypass + unavailable
    // short-circuits before execute() is invoked.
    let sent = await transport.sentBytes
    #expect(sent.isEmpty, "no MIDI bytes should have been dispatched on portUnavailable")

    // Terminal classification: a downstream router that re-inspects this
    // envelope must treat it as terminal (no further fallback).
    #expect(HonestContract.isTerminalStateC(result.message))
}
