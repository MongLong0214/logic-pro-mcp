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
///
/// #1041: there is no `isPaused`. It was declared here and never set by anything that reads
/// Logic, so the resource answered `false` for a paused transport. Measured 2026-09-28 in ko: all
/// 17 control-bar checkboxes read the same playing and paused (Play on in both), and a depth-9
/// walk of the arrange window (336 elements) found none whose title, description or help names a
/// pause. The playhead across two reads a beat apart is the only
/// thing that tells them apart, and one snapshot cannot carry a sequence.
struct TransportState: Sendable, Codable {
    var isPlaying: Bool = false
    var isRecording: Bool = false
    var isCycleEnabled: Bool = false
    /// Nil means the metronome control was absent or its AX value could not be read.
    var isMetronomeEnabled: Bool? = nil
    var tempo: Double = 120.0
    /// The control bar's raw key-signature display value (#1117), not a parsed musical key.
    /// Nil means absent, ambiguous or unreadable; historical payloads decode without this field.
    var keySignature: String? = nil
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
    /// Mute, Solo and Record Enable as the track header's checkboxes read (#1040).
    ///
    /// `nil` means the control was not found on the header, or its value would not read, or read as
    /// something other than 0 or 1. It is not "off": until #1040 the header read ended in `?? false`,
    /// so `logic://tracks` published `false` for a control nobody had read. A `nil` field is left out
    /// of the JSON, the way `is_stack_header` is.
    ///
    /// A row built without a header read starts at `nil` too. The rows MCU feedback creates are served
    /// as `source: "ax_live"` with nothing in the JSON marking them (`liveIdentityBacked` is not
    /// encoded), and MCU feedback never writes `isArmed` (a Rec LED blinks, #1020). With a `false`
    /// default, `logic://tracks` answered `isArmed: false` for a track whose Record Enable checkbox
    /// read 1: measured 2026-09-28 in ko on Logic 12.3, in the read taken right after arming, when
    /// the refresh had not replaced the MCU-created rows (#1040's ten-locale observation records).
    ///
    /// MCU feedback does not write `isMuted` either: Logic lights the MCU Mute LED on every strip a
    /// solo silences, so the LED said "muted" for a track whose checkbox read 0 (es-ES, 2026-09-28).
    /// `isSoloed` is the one toggle an MCU LED still writes.
    var isMuted: Bool?
    var isSoloed: Bool?
    var isArmed: Bool?
    /// Input Monitoring as the track header's checkbox reads (#1040), found by
    /// `AXLocalePolicy.trackInputMonitoringButton`. `nil` means unread, as for the three above, and it
    /// is also where a row built without a header read starts: nothing else in the server reads this
    /// control, so there is no `false` to default to.
    var isInputMonitoring: Bool?
    var isSelected: Bool = false
    var volume: Double = 0.0   // dB, 0 = unity
    var pan: Double = 0.0      // -1.0 (L) to 1.0 (R)
    var automationMode: AutomationMode = .off
    /// Never populated. Logic exposes no colour observable to read it from: measured 2026-09-09
    /// over 1406 elements to depth 16, including the palette opened via View > Colors, there is no
    /// attribute of colour type and no value naming a colour
    /// (`docs/observations/2026-09-09-no-attribute-value-anywhere-carries-a-track-colour`).
    ///
    /// Kept rather than removed so a future reader — the project file is the one route that record
    /// does not close — can populate it without a schema change. Anything comparing tracks must not
    /// treat this as a colour that happens to be unset. #448.
    var color: String?
    /// v3.1.8 (Issue #7) — true when this row was synthesised from
    /// MetaData.plist's `NumberOfTracks` because the AX walker returned
    /// empty. Names are placeholders ("Track 1", "Track 2", ...). Live
    /// rows from the AX scrape have this nil/absent (Codable backward
    /// compat: pre-v3.1.8 JSON snapshots lacking the field decode cleanly).
    var placeholder: Bool?
    var liveIdentityBacked: Bool = true
    /// Typed AX observation only. Codable/MCU/placeholder rows cannot import this authority.
    var physicalBinding: AXTrackBinding.Binding? = nil
    /// Whether this row is the main track of a track stack (#448).
    ///
    /// Read from the presence of the header's `AXDisclosureTriangle`, which Logic describes as
    /// "Track stack disclosure arrow. Show or hide subtracks." — measured on Logic 12.3, where
    /// exactly one of 21 headers carried it. `nil` means the header could not be examined, which is
    /// not the same as "not a stack".
    var isStackHeader: Bool?
    /// Whether that stack is collapsed, from the disclosure triangle's `AXValue` (#448).
    ///
    /// `nil` on any row that is not a stack header, and on one that could not be read. Measured
    /// live: disclosing the stack through Logic's own menu moved the arrangement 21 -> 44 -> 21
    /// headers with the arrow's value tracking 0 -> 1 -> 0 and this field following it, so this is
    /// a readback, not an inference.
    var stackCollapsed: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, type, isMuted, isSoloed, isArmed, isInputMonitoring, isSelected
        case volume, pan, automationMode, color, placeholder
        case isStackHeader = "is_stack_header"
        case stackCollapsed = "stack_collapsed"
    }
}

extension TrackState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(TrackType.self, forKey: .type)
        // Absent is how an unread control is written (#1040), so absent decodes as unread.
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted)
        isSoloed = try container.decodeIfPresent(Bool.self, forKey: .isSoloed)
        isArmed = try container.decodeIfPresent(Bool.self, forKey: .isArmed)
        isInputMonitoring = try container.decodeIfPresent(Bool.self, forKey: .isInputMonitoring)
        isSelected = try container.decode(Bool.self, forKey: .isSelected)
        volume = try container.decode(Double.self, forKey: .volume)
        pan = try container.decode(Double.self, forKey: .pan)
        automationMode = try container.decode(AutomationMode.self, forKey: .automationMode)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        isStackHeader = try container.decodeIfPresent(Bool.self, forKey: .isStackHeader)
        stackCollapsed = try container.decodeIfPresent(Bool.self, forKey: .stackCollapsed)
        placeholder = try container.decodeIfPresent(Bool.self, forKey: .placeholder)
        liveIdentityBacked = false
    }
}

/// Mixer channel strip state (extends track with routing info).
struct ChannelStripState: Sendable, Codable {
    var trackIndex: Int
    /// Retained by typed AX producers/cache only; JSON fallback has no physical write authority.
    var physicalBinding: AXMixerStripBinding.Binding? = nil
    /// Original bytes from the strip's displayed semantic Name field, when observed.
    var name: String?
    /// An attempted name read was unidentified, ambiguous, or failed; nil with no name is not read.
    var nameReadError: String?
    var volume: Double = 0.0
    var pan: Double = 0.0
    /// The strip's sends, when they have been READ (#291).
    ///
    /// This was `[SendState] = []`, so every strip of every project serialised `"sends": []` — and
    /// nothing has ever populated it. A consumer reading that saw "this strip has no sends" when the
    /// truth was "nobody looked", which is the same absence-as-claim the rest of this model refuses.
    ///
    /// It stays absent for now on purpose. Measured on Logic Pro 12.3, an empty send slot is an
    /// `AXButton` described only as "send button" with no `AXValue`, no `AXValueDescription` and no
    /// `AXTitle`, so there is nothing to read a destination from — and a send list cannot be
    /// published until there is.
    var sends: [SendState]?
    /// Per-slot send OCCUPANCY, when the strip's descendants were read (#291).
    ///
    /// Three answers, kept apart on the wire. Key absent: nobody could look — a children read
    /// below the strip failed with a status that is not an answer, or a role or help read that
    /// decides whether an element is a send slot at all did. `[]`: the strip was read and
    /// carries no send slot. A list: one entry per send slot in the reader's walk. An empty slot
    /// is a send-slot button. An assigned send, dumped live on 2026-09-27 in Korean and English,
    /// is a group whose next sibling is the send-level knob, and the reader takes that group as an
    /// occupied slot (`AXLogicProElements.sendSlotObservations`). The group's description names
    /// the destination, but that was read for one bus in two languages and is not read here, so
    /// this is occupancy and not a send list, and `sends` above stays absent.
    var sendSlots: [SendSlotObservation]?
    var input: String?
    /// The existing input-slot reader's result. Nil means not read (including legacy/MCU data),
    /// not absence. A source is the slot's display bytes, never a bus/port/aux identity.
    var inputObservation: InputSlotObservation?
    var output: String?
    var eqEnabled: Bool = false
    var plugins: [PluginSlotState] = []
    /// Provenance for `plugins`. `"ax"` means the insert chain was inspected
    /// and an empty array is an honest empty chain. `nil` means older payload
    /// or no plugin-read path was available.
    var pluginsSource: String?
    /// Why the chain was not read when a read was attempted, for example a strip whose children
    /// did not read (#982). `plugins` is then empty because nobody saw it, not because it is.
    var pluginsReadError: String?

    enum CodingKeys: String, CodingKey {
        case trackIndex, name, volume, pan, sends, input, output, eqEnabled, plugins
        case nameReadError = "name_read_error"
        case sendSlots = "send_slots"
        case inputObservation = "input_observation"
        case pluginsSource = "plugins_source"
        case pluginsReadError = "plugins_read_error"
    }
}

enum InputSlotObservationState: String, Sendable, Codable {
    case observedSource = "observed_source"
    case noSlot = "no_slot"
    case unreadable
}

/// A local input-slot observation, not a routing edge or channel-strip type observation.
struct InputSlotObservation: Sendable, Codable, Equatable {
    let state: InputSlotObservationState
    let source: String?
}

/// A send on a channel strip.
struct SendState: Sendable, Codable {
    var index: Int
    var destination: String
    var level: Double
    var isPreFader: Bool
}

/// What one send slot was seen to be (#291, ADR-008 section 5's endpoint-and-edge-observations requirement).
///
/// `occupiedKnownDestination` is declared and produced by nothing this increment: the destination
/// an assigned send's group names is not read, so a consumer that later learns one can say so
/// without the unknown case silently changing meaning. `unreadable` is a slot whose button was
/// found but whose successor would not say whether it is the send knob — unknown for that slot
/// alone, not for the strip. A successor whose role will not read may be a slot of its own, and
/// then the strip's whole list is unknown.
enum SendSlotState: String, Sendable, Codable {
    case observedEmpty = "observed_empty"
    case occupiedUnknownDestination = "occupied_unknown_destination"
    case occupiedKnownDestination = "occupied_known_destination"
    case unreadable = "unreadable"
}

/// One send slot on a channel strip, by its position among the strip's send slots in the reader's walk.
///
/// `levelRaw` is the knob's `AXValue` when it read as a finite number and `levelDescription` its
/// `AXValueDescription` when readable. Neither decides `state`: a send at minus infinity or under
/// automation is still a send, and minus infinity cannot be written as JSON, so it is carried as
/// no raw level beside whatever the description says.
struct SendSlotObservation: Sendable, Codable, Equatable {
    var ordinal: Int
    var state: SendSlotState
    var levelRaw: Double?
    var levelDescription: String?

    enum CodingKeys: String, CodingKey {
        case ordinal, state
        case levelRaw = "level_raw"
        case levelDescription = "level_description"
    }
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

    /// The position a marker's cell could not be read as.
    ///
    /// It used to be the marker's 0-based place in the list written in bar.beat.division.tick.
    /// That is a WELL-FORMED position, and `goto_marker` fed it straight to
    /// `transport.goto_position`, so a marker whose cell this build cannot parse moved the playhead
    /// to a bar number that was really its row number. `positionSource: .fallback` travelled beside
    /// it, but provenance a caller has to read is not a substitute for not inventing the number:
    /// the value looked exactly like an answer.
    ///
    /// The cell shapes `parseMarkerListPosition` accepts were measured on ko-KR and en-US, and the
    /// Marker List window binds in ten languages, so the six locales with no live reading are
    /// precisely where a fabricated bar would have been published.
    ///
    /// One shared string on purpose. `AccessibilityChannel+Markers` and `+MarkerDelete` use
    /// position EQUALITY as a marker identity; two unreadable markers must not look like one
    /// marker seen twice, and with a shared sentinel those uniqueness gates see a count greater
    /// than one and refuse, which is the honest answer.
    static let unreadablePosition = "unreadable"

    /// AX walker 의 두 fallback site 공통 factory — `parsed != nil` → `.parser`,
    /// `nil` → `.fallback` + `\(ordinal+1).1.1.1` 합성. `ordinal` 은 0-based
    /// enumeration index (목록 N번째 의미).
    static func fromParsed(_ parsed: String?, ordinal: Int, name: String) -> MarkerState {
        MarkerState(
            id: ordinal,
            name: name,
            position: parsed ?? MarkerState.unreadablePosition,
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
    var isConnected: Bool
    var registeredAsDevice: Bool
    var lastFeedbackAt: Date?
    var portName: String
    var portCensus: VirtualMIDIEndpointCensus

    init(
        isConnected: Bool = false,
        registeredAsDevice: Bool = false,
        lastFeedbackAt: Date? = nil,
        portName: String = "",
        portCensus: VirtualMIDIEndpointCensus = .none
    ) {
        self.isConnected = isConnected
        self.registeredAsDevice = registeredAsDevice
        self.lastFeedbackAt = lastFeedbackAt
        self.portName = portName
        self.portCensus = portCensus
    }

    enum CodingKeys: String, CodingKey {
        case isConnected
        case registeredAsDevice
        case lastFeedbackAt
        case portName
        case portCensus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isConnected = try values.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
        registeredAsDevice = try values.decodeIfPresent(Bool.self, forKey: .registeredAsDevice) ?? false
        lastFeedbackAt = try values.decodeIfPresent(Date.self, forKey: .lastFeedbackAt)
        portName = try values.decodeIfPresent(String.self, forKey: .portName) ?? ""
        portCensus = try values.decodeIfPresent(VirtualMIDIEndpointCensus.self, forKey: .portCensus) ?? .none
    }
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

    /// How long inbound MCU feedback may be silent before the connection counts
    /// as stale.
    static let feedbackStaleAfter: TimeInterval = 5.0

    /// Whether inbound MCU feedback has gone silent.
    ///
    /// The rule used to be written twice — `MCUChannel.health` computed
    /// `age > 5.0` after an early return on `!isConnected`, and
    /// `SystemDispatcher` computed `isConnected && age > 5.0` inline for the
    /// `feedback_stale` wire field. The two agreed, but only because one of them
    /// hoisted the guard the other spelled out; nothing made them agree, and the
    /// threshold itself lived as a bare literal in two files. Whoever moved one
    /// would have had to know to move the other.
    ///
    /// Kept in `TimeInterval` rather than derived from `lastFeedbackAgeMs`: that
    /// function truncates to whole milliseconds, so routing through it would move
    /// the boundary for ages in (5.0, 5.001) seconds. This predicate is the same
    /// comparison both sites already made.
    ///
    /// A connection that has never received feedback is stale, not fresh — both
    /// former sites spelled that `?? .infinity`.
    func isFeedbackStale(now: Date = Date()) -> Bool {
        guard isConnected else { return false }
        guard let last = lastFeedbackAt else { return true }
        return now.timeIntervalSince(last) > Self.feedbackStaleAfter
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
