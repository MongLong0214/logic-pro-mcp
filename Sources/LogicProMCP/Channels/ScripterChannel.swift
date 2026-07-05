import Foundation

/// Scripter MIDI FX channel: sends CC 102-119 on Channel 16 to control plugin parameters
/// via Logic Pro's Scripter MIDI FX plugin (§4.7).
actor ScripterChannel: KeyCmdCCChannel {
    nonisolated let id = ChannelID.scripter

    let transport: any KeyCmdTransportProtocol
    let approvalStore: any ManualValidationStoring
    private static let ccBase: UInt8 = 102      // CC 102-119 = param 0-17

    init(
        transport: any KeyCmdTransportProtocol,
        approvalStore: any ManualValidationStoring = ManualValidationStore()
    ) {
        self.transport = transport
        self.approvalStore = approvalStore
    }

    /// Convert param index (0-17) to MIDI CC number (102-119).
    static func ccForParam(_ param: Int) -> UInt8? {
        guard param >= 0 && param < 18 else { return nil }
        return ccBase + UInt8(param)
    }

    /// Convert normalized value (0.0-1.0) to MIDI value (0-127).
    static func midiValue(for value: Double) -> UInt8 {
        UInt8((min(max(value, 0.0), 1.0) * 127.0).rounded())
    }

    func start() async throws {
        let readiness = try await prepareTransportForStart()
        Log.info(
            "Scripter channel started (CC \(Self.ccBase)-\(Self.ccBase + 17) on CH 16) — \(readiness.detail)",
            subsystem: "scripter"
        )
    }

    func stop() async {
        Log.info("Scripter channel stopped", subsystem: "scripter")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard operation == "plugin.set_param" || operation == "mixer.set_plugin_param" else {
            return .error(HonestContract.encodeStateC(
                error: .notImplemented,
                hint: "Scripter only handles plugin.set_param",
                extras: ["operation": operation]
            ))
        }

        let insert = Int(params["insert"] ?? "0") ?? 0
        guard insert == 0 else {
            return .error(HonestContract.encodeStateC(
                error: .notImplemented,
                hint: "Scripter only supports insert 0 on the selected track",
                extras: [
                    "operation": operation,
                    "insert": insert,
                ]
            ))
        }
        guard let paramRaw = params["param"], let paramIndex = Int(paramRaw) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "Scripter requires explicit integer 'param'",
                extras: ["operation": operation]
            ))
        }
        guard let valueRaw = params["value"], let value = Double(valueRaw) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "Scripter requires explicit numeric 'value'",
                extras: [
                    "operation": operation,
                    "param": paramIndex,
                ]
            ))
        }
        guard (0.0...1.0).contains(value) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "Scripter 'value' must be in 0.0..1.0 (got \(value))",
                extras: [
                    "operation": operation,
                    "insert": insert,
                    "param": paramIndex,
                    "requested": value,
                ]
            ))
        }

        guard let cc = Self.ccForParam(paramIndex) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "Param index out of range (0-17): \(paramIndex)",
                extras: [
                    "operation": operation,
                    "insert": insert,
                    "param": paramIndex,
                ]
            ))
        }

        let midiVal = Self.midiValue(for: value)
        let bytes: [UInt8] = [0xB0 | Self.midiChannel, cc, midiVal]
        do {
            try await transport.send(bytes)
        } catch {
            return .error(HonestContract.encodeStateC(
                error: .portUnavailable,
                hint: "Failed to send Scripter param \(paramIndex): \(error)",
                extras: [
                    "operation": operation,
                    "insert": insert,
                    "param": paramIndex,
                    "requested": value,
                    "cc": Int(cc),
                    "applied_midi_value": Int(midiVal),
                ]
            ))
        }

        var extras: [String: Any] = [
            "operation": operation,
            "insert": insert,
            "param": paramIndex,
            "requested": value,
            "cc": Int(cc),
            "applied_midi_value": Int(midiVal),
            "midi_channel": 16,
            "readback_source": "scripter_send_only",
        ]
        if let trackRaw = params["track"], let track = Int(trackRaw) {
            extras["track"] = track
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: extras
        ))
    }

    func healthCheck() async -> ChannelHealth {
        await manualValidationHealth(
            approval: .scripter,
            approvedDetail: { "\($0.detail). Scripter insertion approved by operator" },
            unapprovedDetail: { "\($0.detail). Scripter insertion is not verifiable programmatically. Run `LogicProMCP --approve-channel Scripter` after manual validation" }
        )
    }
}
