import Foundation

/// T-A1 (#10) — opt-in raw-MIDI trace for the MCU bidirectional port.
///
/// thomas-doesburg confirmed (registration/bank/timeout all excluded) that
/// Logic Pro 12.2 returns no fader pitch-bend / V-Pot echo after a *host*
/// write, leaving `set_volume`/`set_pan` permanently at State B
/// `echo_timeout`. The connection-snapshot triplet shows the connection is
/// healthy; what it cannot show is whether Logic emits *any* inbound frame at
/// all after a write. `MCU_TRACE=1` dumps every TX/RX MIDI frame so the raw
/// byte stream can confirm the regression definitively.
///
/// Design notes:
/// - Writes straight to **stderr** (or an injected handle). stdout is reserved
///   for the JSON-RPC stream and must stay byte-clean.
/// - Bypasses `Log`'s rate limiter on purpose: at the 25ms echo-poll cadence a
///   collapsed trace is useless, so frames go directly to the handle.
/// - RX frames are traced *before* `MIDIFeedback.parseBytes`, so frames that do
///   not decode into a known event are still visible (the whole point — proving
///   "nothing came back", not "nothing we recognised came back").
enum MCUTrace {
    enum Direction: String {
        case tx = "TX"
        case rx = "RX"
    }

    /// Pure, deterministic formatter — `"MCU TX: e0 0c 7f"`. Empty byte arrays
    /// render `"MCU TX:"` (no trailing space).
    static func formatLine(_ direction: Direction, _ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return hex.isEmpty ? "MCU \(direction.rawValue):" : "MCU \(direction.rawValue): \(hex)"
    }

    /// Trace is enabled only when `MCU_TRACE` is exactly `"1"`. Any other value
    /// (absent, `"0"`, `"true"`, …) keeps it off. Pure over an injected env so
    /// the gate is unit-testable.
    static func shouldTrace(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["MCU_TRACE"] == "1"
    }

    /// Evaluated once at process start — the env does not change at runtime, so
    /// the hot TX/RX paths pay a single env read rather than one per frame.
    static let isEnabled: Bool = shouldTrace()

    /// Emit one trace line if enabled. `enabled`/`to` are injectable for tests;
    /// production callers use the defaults (process gate + stderr).
    static func emit(
        _ direction: Direction,
        _ bytes: [UInt8],
        enabled: Bool = MCUTrace.isEnabled,
        to handle: FileHandle = .standardError
    ) {
        guard enabled else { return }
        guard let data = (formatLine(direction, bytes) + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    /// A one-line note on the same gate as `emit`.
    ///
    /// It exists so the receive callback can say how much of a packet it did not read WITHOUT
    /// doing I/O on the default path. CoreMIDI documents that block as real-time and non-blocking,
    /// and an unconditional `Log.info` there takes locks and writes to stderr synchronously — a
    /// backpressured stderr then stalls the callback and delays the valid feedback in the SAME
    /// packet. Found by review 2026-09-09, in code added to make a silent gap visible.
    static func note(
        _ text: String,
        enabled: Bool = MCUTrace.isEnabled,
        to handle: FileHandle = .standardError
    ) {
        guard enabled else { return }
        guard let data = ("MCU NOTE: " + text + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }
}
