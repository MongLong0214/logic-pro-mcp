import Foundation

/// Transport state from Logic Pro.
struct TransportState: Sendable, Codable {
    var isPlaying: Bool = false
    var isRecording: Bool = false
    var isPaused: Bool = false
    var isCycleEnabled: Bool = false
    var isMetronomeEnabled: Bool = false
    var tempo: Double = 120.0
    var position: String = "1.1.1.1"  // Bar.Beat.Division.Tick
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

/// Marker info.
struct MarkerState: Sendable, Codable, Identifiable {
    let id: Int
    var name: String
    var position: String
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
struct MCUConnectionState: Sendable {
    var isConnected: Bool = false
    var registeredAsDevice: Bool = false
    var lastFeedbackAt: Date? = nil
    var portName: String = ""
}

/// MCU LCD display state.
struct MCUDisplayState: Sendable {
    var upperRow: String = String(repeating: " ", count: 56)  // 56 chars
    var lowerRow: String = String(repeating: " ", count: 56)
}

/// Plugin parameter state.
struct PluginState: Sendable, Codable {
    var name: String = ""
    var parameters: [PluginParam] = []

    struct PluginParam: Sendable, Codable {
        var name: String
        var value: Double
    }
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
    var kind: String  // "midi" | "audio" | "unknown"
    var rawHelp: String?  // raw AXHelp text — preserved for debugging parser misses
}
