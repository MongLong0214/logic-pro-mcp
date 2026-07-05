import Foundation
import Testing
@testable import LogicProMCP

// WS8b (AC5) — wire-format round-trip lock for the `State/StateModels.swift`
// Codable value types. Every model that crosses the JSON wire is encoded,
// decoded, and re-encoded; the two encodings must be byte-identical (a stable
// round-trip that needs no `Equatable`). This pins the wire shape so a field
// rename, a CodingKeys drift, or a custom (de)coder regression fails loudly.
// Also covers the two decode-time back-compat contracts (MarkerState omitted
// positionSource → .unknown; TrackState omitted placeholder → nil) and the
// snake_case CodingKeys on ChannelStripState.
@Suite("StateModels Codable round-trip")
struct StateModelsCodableTests {
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// encode(x) == encode(decode(encode(x))) — a stable wire round-trip without
    /// requiring the type to be Equatable.
    private func assertRoundTrips<T: Codable>(_ value: T, _ label: String) throws {
        let e = encoder()
        let first = try e.encode(value)
        let decoded = try decoder().decode(T.self, from: first)
        let second = try e.encode(decoded)
        #expect(first == second, "\(label): re-encoded wire bytes drifted across a decode round-trip")
    }

    private func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func transportStateRoundTrips() throws {
        try assertRoundTrips(
            TransportState(isPlaying: true, isRecording: false, tempo: 128.5, position: "5.2.1.1"),
            "TransportState"
        )
    }

    @Test func trackStateRoundTrips() throws {
        try assertRoundTrips(
            TrackState(id: 3, name: "Bass", type: .softwareInstrument, isMuted: true, volume: -3.0, color: "#FF0000"),
            "TrackState (real row)"
        )
        try assertRoundTrips(
            TrackState(id: 0, name: "Track 1", type: .audio, placeholder: true),
            "TrackState (placeholder row)"
        )
    }

    @Test func channelStripStateUsesSnakeCaseCodingKeys() throws {
        let strip = ChannelStripState(
            trackIndex: 2,
            volume: -6.0,
            pan: 0.25,
            sends: [SendState(index: 0, destination: "Bus 1", level: 0.5, isPreFader: false)],
            plugins: [PluginSlotState(index: 0, name: "Gain", isBypassed: false)],
            pluginsSource: "ax",
            pluginsReadError: nil
        )
        try assertRoundTrips(strip, "ChannelStripState")
        let wire = string(try encoder().encode(strip))
        // CodingKeys map two fields to snake_case; the wire must use them.
        #expect(wire.contains("\"plugins_source\""))
        #expect(!wire.contains("\"pluginsSource\""))
    }

    @Test func sendAndPluginSlotRoundTrip() throws {
        try assertRoundTrips(SendState(index: 1, destination: "Reverb", level: 0.8, isPreFader: true), "SendState")
        try assertRoundTrips(PluginSlotState(index: 2, name: "Channel EQ", isBypassed: true), "PluginSlotState")
    }

    @Test func regionStateRoundTrips() throws {
        try assertRoundTrips(
            RegionState(id: "0:1:2:Intro", name: "Intro", trackIndex: 0, startPosition: "1 1", endPosition: "2 1", length: "1 0", isLooped: true),
            "RegionState"
        )
    }

    @Test func regionInfoRoundTrips() throws {
        try assertRoundTrips(
            RegionInfo(name: "Imported MIDI", trackIndex: 1, startBar: 1, endBar: 2, kind: "midi", rawHelp: "raw"),
            "RegionInfo"
        )
    }

    @Test func projectInfoRoundTrips() throws {
        try assertRoundTrips(
            ProjectInfo(name: "Song", trackCount: 4, filePath: "/tmp/x.logicx", source: "project_file", lastSavedAgeSec: 12.0),
            "ProjectInfo"
        )
    }

    // MARK: - MCU structs made Codable in WS6/audit #25 (lock the new wire form)

    @Test func mcuConnectionStateRoundTrips() throws {
        try assertRoundTrips(
            MCUConnectionState(isConnected: true, registeredAsDevice: true, lastFeedbackAt: Date(timeIntervalSince1970: 1000), portName: "LogicProMCP-MCU-Internal"),
            "MCUConnectionState"
        )
        // nil lastFeedbackAt must round-trip too (no feedback yet).
        try assertRoundTrips(MCUConnectionState(), "MCUConnectionState (empty)")
    }

    @Test func mcuDisplayStateRoundTrips() throws {
        try assertRoundTrips(MCUDisplayState(upperRow: String(repeating: "A", count: 56), lowerRow: String(repeating: "B", count: 56)), "MCUDisplayState")
    }

    // MARK: - Enum raw-value wire lock

    @Test func enumRawValuesAreStableOnTheWire() throws {
        // The snake_case rawValues are the wire contract; a rename would break
        // every persisted snapshot and every consumer.
        #expect(TrackType.softwareInstrument.rawValue == "software_instrument")
        #expect(TrackType.externalMIDI.rawValue == "external_midi")
        #expect(AutomationMode.latch.rawValue == "latch")
        #expect(PositionSource.parser.rawValue == "parser")
    }

    // MARK: - Decode-time back-compat contracts

    @Test func markerStateOmittedPositionSourceDecodesAsUnknown() throws {
        // A v3.1.x snapshot has no positionSource field — it must decode to
        // .unknown (never a silent false .parser provenance).
        let legacy = #"{"id":2,"name":"Chorus","position":"5.1.1.1"}"#
        let marker = try decoder().decode(MarkerState.self, from: Data(legacy.utf8))
        #expect(marker.positionSource == .unknown)
        #expect(marker.id == 2)
        #expect(marker.name == "Chorus")
        // Full (new) form round-trips and preserves an explicit provenance.
        let modern = MarkerState(id: 2, name: "Chorus", position: "5.1.1.1", positionSource: .parser)
        let decoded = try decoder().decode(MarkerState.self, from: try encoder().encode(modern))
        #expect(decoded == modern)
        #expect(decoded.positionSource == .parser)
    }

    @Test func trackStateOmittedPlaceholderDecodesAsNil() throws {
        // Live AX rows omit `placeholder`; a pre-v3.1.8 snapshot lacking the
        // field must decode cleanly with placeholder == nil.
        let legacy = #"{"id":0,"name":"Drums","type":"audio","isMuted":false,"isSoloed":false,"isArmed":false,"isSelected":false,"volume":0,"pan":0,"automationMode":"off"}"#
        let track = try decoder().decode(TrackState.self, from: Data(legacy.utf8))
        #expect(track.placeholder == nil)
        #expect(track.type == .audio)
    }
}
