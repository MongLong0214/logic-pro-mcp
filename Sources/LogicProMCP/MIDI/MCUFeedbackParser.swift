import Foundation

/// Parses MCU MIDI feedback events and updates StateCache.
/// Bank offset is applied to map strip 0-7 → actual track indices.
actor MCUFeedbackParser {
    private let cache: StateCache
    private var bankOffsetProvider: (@Sendable () async -> Int)?

    init(cache: StateCache) {
        self.cache = cache
    }

    /// Set the provider that returns current bank offset (bank * 8).
    func setBankOffsetProvider(_ provider: @escaping @Sendable () async -> Int) {
        self.bankOffsetProvider = provider
    }

    /// Current track offset based on bank position.
    private func trackOffset() async -> Int {
        let bank = await bankOffsetProvider?() ?? 0
        return bank * 8
    }

    /// Handle a single MIDI feedback event from Logic Pro.
    func handle(_ event: MIDIFeedback.Event) async {
        // Update connection state.
        //
        // In practice, Logic Pro does not always emit a discrete Device Response after the MCU
        // Device Query. Once we receive any well-formed feedback on the dedicated
        // LogicProMCP-MCU-Internal port, registration is operationally established even if the
        // explicit handshake response is absent.
        var conn = await cache.getMCUConnection()
        conn.lastFeedbackAt = Date()
        conn.isConnected = true
        if !conn.portName.isEmpty {
            conn.registeredAsDevice = true
        }
        await cache.updateMCUConnection(conn)

        let offset = await trackOffset()

        switch event {
        case .pitchBend(let channel, let value):
            // Fader position: channel 0-7 = strip → track = strip + bankOffset
            let trackIndex = Int(channel) + offset
            let normalized = Double(value) / 16383.0
            await cache.updateFader(strip: trackIndex, volume: normalized)

        case .noteOn(_, let note, let velocity):
            if let button = MCUProtocol.decodeButton([0x90, note, velocity]) {
                await handleButton(button, offset: offset)
            }

        case .noteOff(_, let note, _):
            if let button = MCUProtocol.decodeButton([0x90, note, 0x00]) {
                await handleButton(button, offset: offset)
            }

        case .sysEx(let bytes):
            if let lcd = MCUProtocol.decodeLCDSysEx(bytes) {
                await cache.updateMCUDisplayRow(
                    upper: lcd.row == .upper,
                    text: lcd.text,
                    offset: Int(lcd.offset)
                )
            }

        case .controlChange(_, _, _):
            break // V-Pot LED ring, timecode

        default:
            break
        }
    }

    private func handleButton(_ button: MCUProtocol.ButtonState, offset: Int) async {
        // Strip-relative buttons apply bank offset
        let trackIndex = button.function.isStripRelative ? button.strip + offset : button.strip

        switch button.function {
        case .mute:
            await cache.updateTrack(at: trackIndex) { $0.isMuted = button.on }
        case .solo:
            await cache.updateTrack(at: trackIndex) { $0.isSoloed = button.on }
        case .recArm:
            await cache.updateTrack(at: trackIndex) { $0.isArmed = button.on }
        case .select:
            await cache.updateTrack(at: trackIndex) { $0.isSelected = button.on }
        default:
            break
        }
    }
}
