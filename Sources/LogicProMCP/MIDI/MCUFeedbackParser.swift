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
        // v3.8.0 (WS6 / AC3, audit #7) — atomic RMW so a concurrent start()/
        // stop() can't lose this connection update across an await boundary.
        await cache.updateMCUConnection { conn in
            conn.lastFeedbackAt = Date()
            conn.isConnected = true
            if !conn.portName.isEmpty {
                conn.registeredAsDevice = true
            }
        }

        let offset = await trackOffset()

        switch event {
        case .pitchBend(let channel, let value):
            // Fader position. Channels 0-7 are the per-strip faders and follow
            // the bank offset. Channel 8 is the MASTER fader, which is
            // bank-invariant (audit #6): adding the offset to it wrote the
            // master volume onto an unrelated banked track (8 + offset) and
            // broke set_master_volume's echo verification.
            let trackIndex = channel == 8 ? 8 : Int(channel) + offset
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

        case .controlChange(_, let cc, let value):
            // v3.1.3 (#1) — V-Pot LED ring (CC 0x30..0x37) carries the
            // current pan position for strips 0..7 within the active bank.
            // Decode and persist the normalised pan so `MCUChannel.pollPanEcho`
            // can flip `mixer.set_pan` from State B `readback_unavailable` to
            // State A `verified:true` when Logic echoes a matching position.
            if let led = MCUProtocol.decodeVPotLEDRing(cc: cc, value: value) {
                let trackIndex = led.strip + offset
                let pan = MCUProtocol.vpotPositionToPan(led.position)
                await cache.updatePan(strip: trackIndex, value: pan)
                break
            }
            // Other CC frames (timecode @ 0x40..0x49, jog wheel @ 0x3C, etc.)
            // are not yet plumbed into StateCache.
            break

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
            // Logic Pro enforces single-track selection. A strip going
            // "on" implicitly deselects every other strip; we model that
            // by clearing all flags before setting this one. Strip going
            // "off" just clears that one strip.
            if button.on {
                await cache.selectOnly(trackAt: trackIndex)
            } else {
                await cache.updateTrack(at: trackIndex) { $0.isSelected = false }
            }
        default:
            break
        }
    }
}
