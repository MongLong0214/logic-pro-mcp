import Foundation

/// A musical-position component whose value was actually read from Logic's AX tree.
///
/// `TransportState.position` remains a display value for compatibility, but it is not by itself
/// evidence that every part of a four-component musical position was observable.  In particular,
/// Logic's Control Bar can expose only bar and beat sliders.
enum TransportPositionComponent: String, Sendable, Codable, CaseIterable {
    case bar
    case beat
    case subdivision
    case tick
}

/// The raw position text assembled from observed AX controls and the components it contains.
/// A missing value means the state reader did not observe a position at all; callers must not
/// promote `TransportState`'s defaults into a readback.
struct TransportPositionReadback: Sendable, Codable, Equatable {
    var value: String
    var observedComponents: [TransportPositionComponent]
}

/// Transport state from Logic Pro.
struct TransportState: Sendable, Codable {
    var isPlaying: Bool = false
    var isRecording: Bool = false
    var isPaused: Bool = false
    var isCycleEnabled: Bool = false
    var isMetronomeEnabled: Bool = false
    var tempo: Double = 120.0
    /// A display value only. Its legacy default is not an AX observation; consult
    /// `positionReadback` before treating it as evidence of a landed position.
    var position: String = "1.1.1.1"
    /// Which components of `position` came from an AX read. Optional preserves decoding of
    /// historical state payloads, whose `position` string had no observation provenance.
    var positionReadback: TransportPositionReadback? = nil
    /// A display value only. It has no independent readback provenance in the transport model.
    var timePosition: String = "00:00:00.000"
    var sampleRate: Int = 44100
    var lastUpdated: Date = .distantPast
}

/// Track types in Logic Pro.
enum TrackType: String, Sendable, Codable {
    case audio
    case softwareInstrument = "software_instrument"
    case drummer
    case externalMIDI = "external_midi"
    case aux
    case bus
    case master
    case unknown
}

/// A single track's state.
struct TrackState: Sendable, Codable, Identifiable {
    let id: Int          // 0-based index
    var name: String
    var type: TrackType
    var isMuted: Bool = false
    var isSoloed: Bool = false
    var isArmed: Bool = false
    var isSelected: Bool = false
    var volume: Double = 0.0   // dB, 0 = unity
    var pan: Double = 0.0      // -1.0 (L) to 1.0 (R)
    var automationMode: AutomationMode = .off
    var color: String?
    /// v3.1.8 (Issue #7) — true when this row was synthesised from
    /// MetaData.plist's `NumberOfTracks` because the AX walker returned
    /// empty. Names are placeholders ("Track 1", "Track 2", ...). Live
    /// rows from the AX scrape have this nil/absent (Codable backward
    /// compat: pre-v3.1.8 JSON snapshots lacking the field decode cleanly).
    var placeholder: Bool?
    var liveIdentityBacked: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, type, isMuted, isSoloed, isArmed, isSelected
        case volume, pan, automationMode, color, placeholder
    }
}

extension TrackState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(TrackType.self, forKey: .type)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        isSoloed = try container.decode(Bool.self, forKey: .isSoloed)
        isArmed = try container.decode(Bool.self, forKey: .isArmed)
        isSelected = try container.decode(Bool.self, forKey: .isSelected)
        volume = try container.decode(Double.self, forKey: .volume)
        pan = try container.decode(Double.self, forKey: .pan)
        automationMode = try container.decode(AutomationMode.self, forKey: .automationMode)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        placeholder = try container.decodeIfPresent(Bool.self, forKey: .placeholder)
        liveIdentityBacked = false
    }
}

/// Mixer channel strip state (extends track with routing info).
struct ChannelStripState: Sendable, Codable {
    var trackIndex: Int
    var volume: Double = 0.0
    var pan: Double = 0.0
    var sends: [SendState] = []
    var input: String?
    var output: String?
    var eqEnabled: Bool = false
    var plugins: [PluginSlotState] = []
    /// Provenance for `plugins`. `"ax"` means the insert chain was inspected
    /// and an empty array is an honest empty chain. `nil` means older payload
    /// or no plugin-read path was available.
    var pluginsSource: String?
    var pluginsReadError: String?

    enum CodingKeys: String, CodingKey {
        case trackIndex, volume, pan, sends, input, output, eqEnabled, plugins
        case pluginsSource = "plugins_source"
        case pluginsReadError = "plugins_read_error"
    }
}

/// A send on a channel strip.
struct SendState: Sendable, Codable {
    var index: Int
    var destination: String
    var level: Double
    var isPreFader: Bool
}

/// A plugin slot.
struct PluginSlotState: Sendable, Codable {
    var index: Int
    var name: String
    var isBypassed: Bool
}

/// Region info.
struct RegionState: Sendable, Codable, Identifiable {
    let id: String
    var name: String
    var trackIndex: Int
    var startPosition: String   // Bar.Beat
    var endPosition: String
    var length: String
    var isSelected: Bool = false
    var isLooped: Bool = false
}

/// Marker `position`의 출처.
/// - `.parser` — `parseMarkerListPosition` 성공 (canonical "bar.beat.div.tick").
/// - `.fallback` — parser 실패 → caller가 `\(index+1).1.1.1` 합성 (manufactured).
/// - `.unknown` — v3.1.x 이하 cache snapshot decode 결과 (provenance 정보 없음).
///   신규 marker는 항상 `.parser` 또는 `.fallback` 명시; `.unknown` 은 legacy 한정.
enum PositionSource: String, Sendable, Codable, CaseIterable {
    case parser
    case fallback
    case unknown

    /// canonical 여부 — wire schema의 `is_canonical` derived 필드와
    /// `goto_marker` uncertainty 분기 양쪽에서 단일 진실 소스로 사용한다.
    var isCanonical: Bool { self == .parser }
}

/// Marker 정보.
struct MarkerState: Sendable, Codable, Identifiable, Equatable {
    let id: Int
    var name: String
    var position: String
    var positionSource: PositionSource

    /// `positionSource` 기본값은 `.unknown` — 호출 site가 명시적으로 `.parser`/
    /// `.fallback` 을 지정하지 않으면 silent false provenance 발생을 방지한다.
    init(id: Int, name: String, position: String, positionSource: PositionSource = .unknown) {
        self.id = id
        self.name = name
        self.position = position
        self.positionSource = positionSource
    }

    // v3.2 — Codable backward compat. v3.1.x snapshot 에 positionSource field 없음 →
    // `.unknown` 으로 decode (false provenance 차단).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.position = try c.decode(String.self, forKey: .position)
        self.positionSource = try c.decodeIfPresent(PositionSource.self, forKey: .positionSource)
            ?? .unknown
    }

    /// AX walker 의 두 fallback site 공통 factory — `parsed != nil` → `.parser`,
    /// `nil` → `.fallback` + `\(ordinal+1).1.1.1` 합성. `ordinal` 은 0-based
    /// enumeration index (목록 N번째 의미).
    static func fromParsed(_ parsed: String?, ordinal: Int, name: String) -> MarkerState {
        MarkerState(
            id: ordinal,
            name: name,
            position: parsed ?? "\(ordinal + 1).1.1.1",
            positionSource: parsed != nil ? .parser : .fallback
        )
    }
}

/// Automation mode.
enum AutomationMode: String, Sendable, Codable {
    case off
    case read
    case trim
    case touch
    case latch
    case write
}

/// MCU connection state.
/// Codable (audit P2 #25) so `ResourceHandlers.readMCUState` can serialize it
/// directly instead of hand-mapping into a duplicate wire DTO.
struct MCUConnectionState: Sendable, Codable {
    var isConnected: Bool = false
    var registeredAsDevice: Bool = false
    var lastFeedbackAt: Date? = nil
    var portName: String = ""
}

extension MCUConnectionState {
    /// Age of the last inbound MCU feedback in milliseconds, clamped to ≥0 so a
    /// backwards system-clock adjustment cannot leak a negative age onto the
    /// wire. `nil` when no feedback has ever arrived. Shared by the MCU write
    /// envelope diagnostics (`MCUChannel.mcuConnectionExtras`) and the
    /// `logic://mixer` provenance (B1 / #11) so both surfaces report identical
    /// `mcu_last_feedback_age_ms` semantics.
    func lastFeedbackAgeMs(now: Date = Date()) -> Int? {
        guard let last = lastFeedbackAt else { return nil }
        return max(0, Int(now.timeIntervalSince(last) * 1000.0))
    }
}

/// MCU LCD display state.
/// Codable (audit P2 #25) — see `MCUConnectionState`.
struct MCUDisplayState: Sendable, Codable {
    var upperRow: String = String(repeating: " ", count: 56)  // 56 chars
    var lowerRow: String = String(repeating: " ", count: 56)
}

/// Project-level info.
struct ProjectInfo: Sendable, Codable {
    var name: String = ""
    var sampleRate: Int = 44100
    var bitDepth: Int = 24
    var tempo: Double = 120.0
    var timeSignature: String = "4/4"
    var trackCount: Int = 0
    var filePath: String?
    var lastUpdated: Date = .distantPast
    /// v3.1.8 (Issue #7) — provenance of the read. One of: "ax_live",
    /// "project_file", "cache", "default". Optional for forward/back compat
    /// (v3.1.7 envelopes deserialise with `source: nil`).
    var source: String?
    /// v3.1.8 (Issue #7) — set when sourced from project_file; mtime delta
    /// in seconds. Clamped to ≥ 0.
    var lastSavedAgeSec: Double?
}

/// A Logic arrange-area region (MIDI or audio) as exposed by AX.
///
/// `startBar` and `endBar` are 1-based bar numbers parsed from Logic's
/// AXHelp text ("리전은 N 마디 에서 시작하여 M 마디 에서 끝납니다." / English
/// equivalent). `trackIndex` is the 0-based track lane matched by the
/// region's vertical position to each track header's Y coordinate.
struct RegionInfo: Sendable, Codable {
    var name: String
    var trackIndex: Int
    var startBar: Int
    var endBar: Int
    var kind: String  // "midi" | "audio" | "drummer" | "unknown"
    var rawHelp: String?  // raw AXHelp text — preserved for debugging parser misses
}

struct RegionInventoryPayload: Codable, Sendable {
    struct Debug: Codable, Sendable {
        let layoutItems: Int
        let nonRegion: Int
        /// Every track in the project. Not viewport-limited, so it is the denominator a
        /// completeness claim needs (#576).
        let trackHeaders: Int?
        /// How many of those are inside the visible bounds. Equal to `trackHeaders` means the
        /// enumeration saw every track and an empty region result for any of them is genuine.
        let trackHeadersInViewport: Int?

        init(layoutItems: Int, nonRegion: Int, trackHeaders: Int? = nil, trackHeadersInViewport: Int? = nil) {
            self.layoutItems = layoutItems
            self.nonRegion = nonRegion
            self.trackHeaders = trackHeaders
            self.trackHeadersInViewport = trackHeadersInViewport
        }

        enum CodingKeys: String, CodingKey {
            case layoutItems
            case nonRegion
            case trackHeaders = "track_headers"
            case trackHeadersInViewport = "track_headers_in_viewport"
        }
    }

    let regions: [RegionInfo]
    let complete: Bool?
    let scope: String?
    let reason: String?
    let returnedCount: Int?
    let debug: Debug?

    /// An ABSENT completeness claim is not a completeness claim.
    ///
    /// This defaulted to `true`, which was harmless while `complete` was a hardcoded `false` that
    /// every producer set. It stopped being harmless the moment completeness began deciding whether
    /// an absent region is evidence (#576): a payload that says nothing about its own coverage —
    /// legacy, malformed, or from a producer that has not been taught to report it — would mark the
    /// cache exhaustively read. Two callers feed this straight into `cache.updateRegions(complete:)`.
    ///
    /// Fail closed instead. Silence is not coverage.
    var isComplete: Bool { complete ?? false }

    enum CodingKeys: String, CodingKey {
        case regions
        case complete
        case scope
        case reason
        case returnedCount = "returned_count"
        case debug = "_debug"
    }
}

extension RegionInfo {
    static func decodeInventoryPayload(_ text: String) throws -> RegionInventoryPayload {
        if let direct: [RegionInfo] = try? decodeJSON(text) {
            // A bare array is the legacy wire shape: a list of regions and nothing else. It makes no
            // statement about its own coverage, so this decoder must not make one on its behalf.
            //
            // It used to synthesise `complete: true, scope: "project"` here — the same fail-open the
            // `isComplete` default had, one layer down and hardcoded, so flipping that default alone
            // left this path still asserting a whole-project inventory for input that claimed
            // nothing. Both callers feed the result into `cache.updateRegions(complete:)`.
            return RegionInventoryPayload(
                regions: direct,
                complete: false,
                scope: nil,
                reason: "legacy_array_payload_declares_no_scope",
                returnedCount: direct.count,
                debug: nil
            )
        }
        return try decodeJSON(text)
    }

    static func decodeToolPayload(_ text: String) throws -> [RegionInfo] {
        try decodeInventoryPayload(text).regions
    }

    func asRegionState() -> RegionState {
        let safeName = name.isEmpty ? "region" : name
        let lengthBars = max(0, endBar - startBar)
        return RegionState(
            id: "\(trackIndex):\(startBar):\(endBar):\(safeName)",
            name: safeName,
            trackIndex: trackIndex,
            startPosition: "\(startBar) 1 1 1",
            endPosition: "\(endBar) 1 1 1",
            length: "\(lengthBars) 0 0 0"
        )
    }
}
