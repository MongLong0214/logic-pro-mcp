import Foundation

/// Scripter MIDI FX channel: sends CC 102-119 on Channel 16 to control plugin parameters
/// via Logic Pro's Scripter MIDI FX plugin (§4.7).
actor ScripterChannel: Channel {
    nonisolated let id = ChannelID.scripter

    private let transport: any KeyCmdTransportProtocol
    private let approvalStore: any ManualValidationStoring
    private static let midiChannel: UInt8 = 15 // zero-indexed = channel 16
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
        try await transport.prepare()
        let readiness = await transport.readiness()
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
            return .error("Scripter only handles plugin.set_param, got: \(operation)")
        }

        let insert = Int(params["insert"] ?? "0") ?? 0
        guard insert == 0 else {
            return .error("Scripter only supports insert 0 on the selected track")
        }
        let paramIndex = Int(params["param"] ?? "0") ?? 0
        let value = Double(params["value"] ?? "0") ?? 0.0

        guard let cc = Self.ccForParam(paramIndex) else {
            return .error("Param index out of range (0-17): \(paramIndex)")
        }

        let midiVal = Self.midiValue(for: value)
        let bytes: [UInt8] = [0xB0 | Self.midiChannel, cc, midiVal]
        do {
            try await transport.send(bytes)
        } catch {
            return .error("Failed to send Scripter param \(paramIndex): \(error)")
        }

        return .success("Scripter param \(paramIndex) set to \(value) on insert \(insert) (CC \(cc) val \(midiVal))")
    }

    func healthCheck() async -> ChannelHealth {
        let readiness = await transport.readiness()
        guard readiness.available else {
            return .unavailable(readiness.detail)
        }
        if await approvalStore.isApproved(.scripter) {
            return .healthy(
                detail: "\(readiness.detail). Scripter insertion approved by operator",
                verificationStatus: .runtimeReady
            )
        }
        return .healthy(
            detail: "\(readiness.detail). Scripter insertion is not verifiable programmatically. Run `LogicProMCP --approve-channel Scripter` after manual validation",
            verificationStatus: .manualValidationRequired
        )
    }
}
