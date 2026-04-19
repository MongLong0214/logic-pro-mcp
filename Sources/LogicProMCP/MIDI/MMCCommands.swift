import Foundation

/// MIDI Machine Control (MMC) SysEx command builder.
///
/// MMC messages follow: `F0 7F <device-id> 06 <command> [args…] F7`
/// where `device-id` 0x7F is reserved as the broadcast address.
///
/// This builder exposes two tiers of API:
/// - Legacy `[UInt8]`-returning helpers (`play`, `stop`, `locate`, …) retained
///   for byte-layout stability against existing tests and channel callsites.
/// - Strict, throwing variants (`locateStrict`, `goto`) that validate inputs
///   per the MMC spec so unreachable hardware behaviour is caught at the
///   server boundary instead of silently going out on the wire.
enum MMCCommands {

    // MARK: - Errors

    /// Validation failures surfaced by the strict command builders.
    enum MMCError: Error, Equatable, CustomStringConvertible {
        case hoursOutOfRange(UInt8)
        case minutesOutOfRange(UInt8)
        case secondsOutOfRange(UInt8)
        case framesOutOfRange(UInt8, max: UInt8)
        case subframesOutOfRange(UInt8)
        case deviceIDOutOfRange(UInt8)
        case targetOutOfRange(UInt8)

        var description: String {
            switch self {
            case .hoursOutOfRange(let v): return "hours \(v) out of range (0..23)"
            case .minutesOutOfRange(let v): return "minutes \(v) out of range (0..59)"
            case .secondsOutOfRange(let v): return "seconds \(v) out of range (0..59)"
            case .framesOutOfRange(let v, let max): return "frames \(v) out of range (0..\(max))"
            case .subframesOutOfRange(let v): return "subframes \(v) out of range (0..99)"
            case .deviceIDOutOfRange(let v): return "deviceID 0x\(String(v, radix: 16)) out of range (0..0x7F)"
            case .targetOutOfRange(let v): return "target 0x\(String(v, radix: 16)) out of range (0..0x7F)"
            }
        }
    }

    // MARK: - SMPTE frame rate

    /// SMPTE frame rates encoded in the top bits of the MMC hours byte
    /// (spec bits 5-6). See MMC 1.0 §4.2.2.3.
    enum FrameRate: Sendable, Equatable, CaseIterable {
        case fps24
        case fps25
        case fps29_97df
        case fps30

        /// Value to OR into the hours byte's bits 5-6.
        var encoding: UInt8 {
            switch self {
            case .fps24: return 0b0000_0000
            case .fps25: return 0b0010_0000
            case .fps29_97df: return 0b0100_0000
            case .fps30: return 0b0110_0000
            }
        }

        /// Highest valid frame index (inclusive) at this rate.
        var maxFrame: UInt8 {
            switch self {
            case .fps24: return 23
            case .fps25: return 24
            case .fps29_97df: return 29
            case .fps30: return 29
            }
        }

        /// Nominal frames per second for bar/beat → SMPTE conversion.
        var fps: Double {
            switch self {
            case .fps24: return 24.0
            case .fps25: return 25.0
            case .fps29_97df: return 30_000.0 / 1_001.0
            case .fps30: return 30.0
            }
        }
    }

    // MARK: - Simple transport commands (byte layout preserved)

    static func play(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x02)
    }

    static func stop(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x01)
    }

    static func recordStrobe(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x06)
    }

    static func recordExit(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x07)
    }

    static func pause(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x09)
    }

    static func fastForward(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x04)
    }

    static func rewind(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x05)
    }

    // MARK: - Extended transport commands

    /// DEFERRED PLAY (0x03): begin playback at the next lockable boundary.
    static func deferredPlay(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x03)
    }

    /// RESET (0x0D): return the device to its default power-on state.
    static func reset(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x0D)
    }

    /// WRITE (0x40): enter write/arm mode on the receiver.
    static func write(deviceID: UInt8 = ServerConfig.mmcDeviceID) -> [UInt8] {
        sysEx(deviceID: deviceID, command: 0x40)
    }

    // MARK: - LOCATE

    /// Legacy LOCATE (0x44 06 01 …) — preserves byte layout for existing callsites.
    /// Prefer `locateStrict` in new code for input validation + frame-rate encoding.
    static func locate(
        hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8,
        subframes: UInt8 = 0, deviceID: UInt8 = ServerConfig.mmcDeviceID
    ) -> [UInt8] {
        [
            0xF0, 0x7F, deviceID, 0x06, 0x44, 0x06, 0x01,
            hours, minutes, seconds, frames, subframes, 0xF7,
        ]
    }

    /// LOCATE with full SMPTE validation and frame-rate encoding.
    /// Throws `MMCError` for any out-of-range component so the wire never
    /// carries values the receiver would interpret as undefined.
    static func locateStrict(
        hours: UInt8,
        minutes: UInt8,
        seconds: UInt8,
        frames: UInt8,
        subframes: UInt8 = 0,
        frameRate: FrameRate = .fps30,
        deviceID: UInt8 = ServerConfig.mmcDeviceID
    ) throws -> [UInt8] {
        try validateDeviceID(deviceID)
        guard hours <= 23 else { throw MMCError.hoursOutOfRange(hours) }
        guard minutes <= 59 else { throw MMCError.minutesOutOfRange(minutes) }
        guard seconds <= 59 else { throw MMCError.secondsOutOfRange(seconds) }
        guard frames <= frameRate.maxFrame else {
            throw MMCError.framesOutOfRange(frames, max: frameRate.maxFrame)
        }
        guard subframes <= 99 else { throw MMCError.subframesOutOfRange(subframes) }

        let encodedHours = hours | frameRate.encoding
        return [
            0xF0, 0x7F, deviceID, 0x06, 0x44, 0x06, 0x01,
            encodedHours, minutes, seconds, frames, subframes, 0xF7,
        ]
    }

    /// Memory-LOCATE (`0x44 01 <target>`): jump to a stored memory location ID.
    static func goto(target: UInt8, deviceID: UInt8 = ServerConfig.mmcDeviceID) throws -> [UInt8] {
        try validateDeviceID(deviceID)
        guard target <= 0x7F else { throw MMCError.targetOutOfRange(target) }
        return [0xF0, 0x7F, deviceID, 0x06, 0x44, 0x01, target, 0xF7]
    }

    // MARK: - Bar/beat → SMPTE conversion

    /// Convert a musical position to SMPTE time components.
    /// - Parameters:
    ///   - bar: 1-indexed bar number.
    ///   - beat: 1-indexed beat within the bar (fractional allowed, e.g. 2.5).
    ///   - tempo: BPM (must be > 0).
    ///   - beatsPerBar: numerator of the time signature (must be > 0).
    ///   - frameRate: SMPTE frame rate used to quantise frames + cap maxFrame.
    /// - Returns: SMPTE components, or `nil` if the inputs are invalid or the
    ///   resulting time exceeds the 24-hour MMC wall-clock limit.
    static func barBeatToSMPTE(
        bar: Int,
        beat: Double,
        tempo: Double,
        beatsPerBar: Int,
        frameRate: FrameRate = .fps30
    ) -> (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8, subframes: UInt8)? {
        guard bar >= 1, beat >= 1.0, tempo > 0, beatsPerBar > 0 else { return nil }
        let totalBeats = Double(bar - 1) * Double(beatsPerBar) + (beat - 1.0)
        let totalSeconds = totalBeats * 60.0 / tempo
        guard totalSeconds.isFinite, totalSeconds >= 0, totalSeconds < 86_400 else { return nil }

        let wholeSeconds = Int(totalSeconds.rounded(.down))
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds / 60) % 60
        let seconds = wholeSeconds % 60

        let fractionalSecond = totalSeconds - Double(wholeSeconds)
        let framesDouble = fractionalSecond * frameRate.fps
        let wholeFrames = Int(framesDouble.rounded(.down))
        let cappedFrames = min(wholeFrames, Int(frameRate.maxFrame))
        let subframesDouble = (framesDouble - Double(wholeFrames)) * 100
        let subframes = min(max(Int(subframesDouble.rounded()), 0), 99)

        return (
            hours: UInt8(hours),
            minutes: UInt8(minutes),
            seconds: UInt8(seconds),
            frames: UInt8(cappedFrames),
            subframes: UInt8(subframes)
        )
    }

    // MARK: - Private

    private static func validateDeviceID(_ deviceID: UInt8) throws {
        guard deviceID <= 0x7F else { throw MMCError.deviceIDOutOfRange(deviceID) }
    }

    private static func sysEx(deviceID: UInt8, command: UInt8) -> [UInt8] {
        [0xF0, 0x7F, deviceID, 0x06, command, 0xF7]
    }
}
