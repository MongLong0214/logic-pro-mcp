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
    /// TX (host → Logic): MCU V-Pot rotate uses CC 0x10..0x17 (strip 0..7).
    /// Value byte: bit 6 (0x40) = direction (0 CW, 1 CCW), bits 0..3 = speed 1..15.
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

    // MARK: - V-Pot LED Ring (RX from Logic)

    /// LED-ring display mode bits (value byte bits 4..5). The MCU surface
    /// shows the V-Pot's current value through one of four ring patterns.
    /// We expose the mode for diagnostic completeness even though pan
    /// decode only needs the position.
    enum VPotRingMode: Sendable, Equatable {
        case singleDot   // 0x00 — one LED lit at `position`
        case boostCut    // 0x10 — symmetric around centre, "VU" style
        case wrap        // 0x20 — fills 0..position
        case spread      // 0x30 — symmetric spread from centre

        static func from(bits: UInt8) -> VPotRingMode {
            switch bits & 0x30 {
            case 0x00: return .singleDot
            case 0x10: return .boostCut
            case 0x20: return .wrap
            case 0x30: return .spread
            default:   return .singleDot
            }
        }
    }

    /// Decoded V-Pot LED ring state.
    struct VPotLEDState: Sendable, Equatable {
        let strip: Int      // 0..7 within the current bank
        let position: Int   // 0..11 (LED ring index; 6 = centre)
        let center: Bool    // bit 6 of value byte — centre LED on
        let mode: VPotRingMode
    }

    /// Decode an MCU V-Pot LED-ring CC frame from Logic.
    /// RX: CC 0x30..0x37 carries the ring state for strips 0..7.
    /// Value byte layout: bit 6 = centre LED, bits 4..5 = mode, bits 0..3 = position 0..11.
    static func decodeVPotLEDRing(cc: UInt8, value: UInt8) -> VPotLEDState? {
        guard (0x30...0x37).contains(cc) else { return nil }
        let strip = Int(cc - 0x30)
        let position = Int(value & 0x0F)
        // Position is documented as 0..11; clamp anything beyond 11 (some
        // Logic builds emit 0x0C/0x0D briefly during boot) so the decoder
        // never produces an out-of-range index for callers.
        let clampedPos = min(max(position, 0), 11)
        let center = (value & 0x40) != 0
        let mode = VPotRingMode.from(bits: value)
        return VPotLEDState(strip: strip, position: clampedPos, center: center, mode: mode)
    }

    /// Convert a V-Pot LED ring `position` (0..11, centre=6) to a normalised
    /// pan in [-1.0, +1.0]. Mirrors the API surface of `executeSetPan`.
    /// The MCU ring is asymmetric (6 left LEDs vs 5 right LEDs); we map each
    /// half independently so position 0 → -1.0, 6 → 0.0, 11 → +1.0.
    static func vpotPositionToPan(_ position: Int) -> Double {
        let p = min(max(position, 0), 11)
        if p == 6 { return 0.0 }
        if p < 6 {
            // 0..5 → -1.0 .. -1/6
            return Double(p - 6) / 6.0
        } else {
            // 7..11 → +1/5 .. +1.0
            return Double(p - 6) / 5.0
        }
    }

    /// Inverse mapping for tests / round-trip checks. Discrete: returns the
    /// LED position closest to the given normalised pan value.
    static func panToVPotPosition(_ pan: Double) -> Int {
        let clamped = min(max(pan, -1.0), 1.0)
        if clamped == 0 { return 6 }
        if clamped < 0 {
            // -1.0 .. 0 → 0 .. 6
            return min(max(Int((clamped * 6.0).rounded() + 6.0), 0), 6)
        } else {
            // 0 .. +1.0 → 6 .. 11
            return min(max(Int((clamped * 5.0).rounded() + 6.0), 6), 11)
        }
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

    // v3.8.0 (WS6 follow-up / AC5, audit #29) — `HandshakeResult` +
    // `parseDeviceResponse` were unused by production (Logic doesn't reliably
    // emit a discrete Device Response; MCUChannel treats ANY well-formed feedback
    // on the dedicated port as registration) and were retained only to pin a
    // decode contract for a code path that never runs. Both are now deleted; the
    // Device Query we still send on start is the only handshake artifact left.

    /// Encode MCU Device Query: F0 00 00 66 14 00 F7
    static func encodeDeviceQuery() -> [UInt8] {
        sysExHeader + [0x00, 0xF7]
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
