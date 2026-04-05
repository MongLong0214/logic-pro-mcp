import Foundation

/// Mackie Control Universal protocol encoder/decoder.
/// Reference: PRD §4.5 MCU Protocol Specification.
struct MCUProtocol {

    // MARK: - Types

    enum LCDRow: Sendable {
        case upper  // offset 0x00-0x37
        case lower  // offset 0x38-0x6F
    }

    struct LCDUpdate: Sendable {
        let offset: UInt8
        let text: String
        let row: LCDRow
    }

    struct FaderState: Sendable {
        let track: Int        // 0-7 (strip), 8 = master
        let value: Double     // 0.0-1.0 normalized
    }

    enum ButtonFunction: UInt8, Sendable {
        // Channel strip buttons (offset per strip 0-7)
        case recArm = 0x00        // 0x00-0x07
        case solo = 0x08          // 0x08-0x0F
        case mute = 0x10          // 0x10-0x17
        case select = 0x18        // 0x18-0x1F

        // Banking
        case bankLeft = 0x2E
        case bankRight = 0x2F
        case channelLeft = 0x30
        case channelRight = 0x31

        // Assignment modes
        case assignTrack = 0x28
        case assignSend = 0x29
        case assignPan = 0x2A
        case assignPlugin = 0x2B
        case assignEQ = 0x2C
        case assignInstrument = 0x2D

        // Automation
        case automationRead = 0x4A
        case automationWrite = 0x4B
        case automationTrim = 0x4C
        case automationTouch = 0x4D
        case automationLatch = 0x4E

        // Transport
        case rewind = 0x5B
        case fastForward = 0x5C
        case stop = 0x5D
        case play = 0x5E
        case record = 0x5F
        case cycle = 0x56
        case drop = 0x57
        case replace = 0x58
        case click = 0x59
        case soloGlobal = 0x5A

        /// Whether this function uses strip offset (0-7)
        var isStripRelative: Bool {
            switch self {
            case .recArm, .solo, .mute, .select: return true
            default: return false
            }
        }
    }

    struct ButtonState: Sendable {
        let function: ButtonFunction
        let strip: Int    // 0-7 for strip-relative, 0 for global
        let on: Bool
    }

    enum TransportCommand: Sendable {
        case play, stop, record, rewind, fastForward, cycle, drop, replace, click, soloGlobal
    }

    enum VPotDirection: Sendable {
        case clockwise
        case counterClockwise
    }

    // MARK: - SysEx Constants

    static let sysExHeader: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14]

    // MARK: - Fader Encode/Decode

    /// Encode fader position: track(0-8) + value(0.0-1.0) → Pitch Bend bytes.
    static func encodeFader(track: Int, value: Double) -> [UInt8] {
        let channel = UInt8(min(max(track, 0), 8))
        let clamped = min(max(value, 0.0), 1.0)
        let intValue = UInt16(clamped * 16383.0)
        let lsb = UInt8(intValue & 0x7F)
        let msb = UInt8((intValue >> 7) & 0x7F)
        return [0xE0 | channel, lsb, msb]
    }

    /// Decode Pitch Bend feedback → FaderState.
    static func decodeFader(_ bytes: [UInt8]) -> FaderState? {
        guard bytes.count >= 3, bytes[0] & 0xF0 == 0xE0 else { return nil }
        let channel = Int(bytes[0] & 0x0F)
        let lsb = UInt16(bytes[1] & 0x7F)
        let msb = UInt16(bytes[2] & 0x7F)
        let raw = (msb << 7) | lsb
        let value = Double(raw) / 16383.0
        return FaderState(track: channel, value: value)
    }

    // MARK: - Button Encode/Decode

    /// Encode button press/release → Note On/Off bytes.
    static func encodeButton(_ function: ButtonFunction, strip: Int = 0, on: Bool) -> [UInt8] {
        let note: UInt8
        if function.isStripRelative {
            note = function.rawValue + UInt8(min(max(strip, 0), 7))
        } else {
            note = function.rawValue
        }
        return [0x90, note, on ? 0x7F : 0x00]
    }

    /// Decode Note On/Off feedback → ButtonState.
    static func decodeButton(_ bytes: [UInt8]) -> ButtonState? {
        guard bytes.count >= 3, bytes[0] == 0x90 else { return nil }
        let note = bytes[1]
        let velocity = bytes[2]
        let on = velocity > 0

        // Determine function and strip from note number
        let (function, strip) = identifyButton(note: note)
        guard let function else { return nil }

        return ButtonState(function: function, strip: strip, on: on)
    }

    private static func identifyButton(note: UInt8) -> (ButtonFunction?, Int) {
        // Strip-relative ranges
        if note >= 0x00 && note <= 0x07 { return (.recArm, Int(note - 0x00)) }
        if note >= 0x08 && note <= 0x0F { return (.solo, Int(note - 0x08)) }
        if note >= 0x10 && note <= 0x17 { return (.mute, Int(note - 0x10)) }
        if note >= 0x18 && note <= 0x1F { return (.select, Int(note - 0x18)) }

        // Global buttons
        if let function = ButtonFunction(rawValue: note) {
            return (function, 0)
        }
        return (nil, 0)
    }

    // MARK: - Transport

    /// Encode transport command → Note On bytes.
    static func encodeTransport(_ command: TransportCommand) -> [UInt8] {
        let function: ButtonFunction
        switch command {
        case .play: function = .play
        case .stop: function = .stop
        case .record: function = .record
        case .rewind: function = .rewind
        case .fastForward: function = .fastForward
        case .cycle: function = .cycle
        case .drop: function = .drop
        case .replace: function = .replace
        case .click: function = .click
        case .soloGlobal: function = .soloGlobal
        }
        return encodeButton(function, on: true)
    }

    // MARK: - V-Pot

    /// Encode V-Pot rotation → CC bytes.
    static func encodeVPot(strip: Int, direction: VPotDirection, speed: UInt8 = 1) -> [UInt8] {
        let cc = UInt8(0x10 + min(max(strip, 0), 7))
        let clampedSpeed = min(max(speed, 1), 15)
        let value: UInt8
        switch direction {
        case .clockwise: value = clampedSpeed
        case .counterClockwise: value = 0x40 | clampedSpeed
        }
        return [0xB0, cc, value]
    }

    // MARK: - Jog Wheel

    /// Encode jog wheel rotation → CC 0x3C bytes.
    static func encodeJog(direction: VPotDirection, clicks: UInt8 = 1) -> [UInt8] {
        let clampedClicks = min(max(clicks, 1), 15)
        let value: UInt8
        switch direction {
        case .clockwise: value = clampedClicks
        case .counterClockwise: value = 0x40 | clampedClicks
        }
        return [0xB0, 0x3C, value]
    }

    // MARK: - Handshake

    enum HandshakeResult: Sendable, Equatable {
        case success(firmwareVersion: [UInt8])  // Device responded with version info
        case failure(reason: String)             // Response received but malformed
        case noResponse                          // No response within timeout
        case timeout                             // Partial response, timed out
    }

    /// Encode MCU Device Query: F0 00 00 66 14 00 F7
    static func encodeDeviceQuery() -> [UInt8] {
        sysExHeader + [0x00, 0xF7]
    }

    /// Parse Device Response SysEx → HandshakeResult.
    static func parseDeviceResponse(_ bytes: [UInt8]) -> HandshakeResult {
        guard !bytes.isEmpty else { return .noResponse }
        guard bytes.count >= 7,
              bytes.starts(with: sysExHeader),
              bytes.last == 0xF7
        else { return .failure(reason: "Malformed SysEx: expected MCU header + F7") }

        guard bytes[5] == 0x01 else {
            return .failure(reason: "Unexpected sub-ID: 0x\(String(format: "%02X", bytes[5]))")
        }

        // Extract firmware version bytes (between sub-ID and F7)
        let firmware = Array(bytes[6..<(bytes.count - 1)])
        return .success(firmwareVersion: firmware)
    }

    /// Legacy convenience: Check if bytes are a Device Response.
    static func isDeviceResponse(_ bytes: [UInt8]) -> Bool {
        if case .success = parseDeviceResponse(bytes) { return true }
        return false
    }

    // MARK: - LCD SysEx Decode

    /// Decode LCD SysEx: F0 00 00 66 14 12 [offset] [chars...] F7
    static func decodeLCDSysEx(_ bytes: [UInt8]) -> LCDUpdate? {
        guard bytes.count >= 8,
              bytes.starts(with: sysExHeader),
              bytes[5] == 0x12,
              bytes.last == 0xF7
        else { return nil }

        let offset = bytes[6]
        let charBytes = bytes[7..<(bytes.count - 1)]
        let text = String(charBytes.map { Character(UnicodeScalar($0)) })
        let row: LCDRow = offset < 0x38 ? .upper : .lower

        return LCDUpdate(offset: offset, text: text, row: row)
    }

    // MARK: - SysEx Validation

    /// Validate SysEx bytes: must start with F0, end with F7, middle bytes < 0x80.
    static func isValidSysEx(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2,
              bytes.first == 0xF0,
              bytes.last == 0xF7
        else { return false }
        for i in 1..<(bytes.count - 1) {
            if bytes[i] >= 0x80 { return false }
        }
        return true
    }
}
