import Foundation
import MCP

struct MIDIDispatcher {
    private static let maxSysExBytes = 1024
    private static let maxSysExTextCharacters = maxSysExBytes * 5

    static let tool = commandTool(
        name: "logic_midi",
        description: "MIDI operations in Logic Pro. Commands: send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, play_sequence, import_file, list_ports, create_virtual_port, step_input, mmc_play, mmc_stop, mmc_record, mmc_locate. Params: send_note/send_chord -> MIDI note payloads; send_cc/program_change/pitch_bend/aftertouch -> controller payloads; send_sysex -> { bytes: [Int] } or { data: String } (≤1024 bytes); play_sequence -> { notes: \"pitch,offsetMs,durMs[,vel[,ch]];...\" } (≤256 events, tight server-side timing); import_file -> { path: server-managed LogicProMCP temp .mid } and wait for verified:true before issuing the next import; list_ports -> {} (same data as logic://midi/ports; prefer the resource for polling); mmc_locate -> { bar: Int } or { time: \"HH:MM:SS:FF\" }; create_virtual_port -> { name: String }. The 7 send-style ops (send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, play_sequence) accept an optional { port: \"midi\"|\"keycmd\" } selector — default \"midi\" routes to the CoreMIDI virtual port; \"keycmd\" routes to the MIDIKeyCommands KeyCmd virtual port (requires one-time MIDI Learn in Logic). Channel is 1-based (1..16). All other ops reject `port` with invalid_params.",
        commandDescription: "MIDI command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "send_note":
            let note: Int
            switch midiData7Param(params, "note", requiredBy: "send_note") {
            case .success(let parsed): note = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            let velocity: Int
            switch optionalMidiData7Param(params, "velocity", default: 100, requiredBy: "send_note") {
            case .success(let parsed): velocity = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            let durationMs: Int
            switch optionalDurationMsParam(params, "duration_ms", default: 500, requiredBy: "send_note") {
            case .success(let parsed): durationMs = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await dispatchSendOp(
                baseOp: "midi.send_note",
                params: params,
                additionalParams: [
                    "note": String(note),
                    "velocity": String(velocity),
                    "duration_ms": String(durationMs),
                ],
                router: router
            )

        case "send_chord":
            let notes: String
            switch midiData7ListParam(params, "notes", requiredBy: "send_chord") {
            case .success(let parsed): notes = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            let velocity: Int
            switch optionalMidiData7Param(params, "velocity", default: 100, requiredBy: "send_chord") {
            case .success(let parsed): velocity = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            let durationMs: Int
            switch optionalDurationMsParam(params, "duration_ms", default: 500, requiredBy: "send_chord") {
            case .success(let parsed): durationMs = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await dispatchSendOp(
                baseOp: "midi.send_chord",
                params: params,
                additionalParams: [
                    "notes": notes,
                    "velocity": String(velocity),
                    "duration_ms": String(durationMs),
                ],
                router: router
            )

        case "play_sequence":
            // Tight-rhythm sequencer. `notes` is a raw string of
            // "pitch,offsetMs,durMs[,vel[,ch]]" events separated by ';'.
            // Per-event channel lives inside the notes string and is parsed
            // by `NoteSequenceParser` (T3) — there is no top-level channel,
            // so we skip `validateMidiChannel` and only validate `port`.
            guard params["channel"] == nil else {
                return toolInvalidParamsResult(
                    "play_sequence does not support top-level 'channel'; use the optional per-event channel field in notes"
                )
            }
            guard let notes = params["notes"]?.stringValue, !notes.isEmpty else {
                return toolInvalidParamsResult("play_sequence requires 'notes' as a non-empty string")
            }
            switch NoteSequenceParser.parse(notes) {
            case .success(let events):
                guard !events.isEmpty, events.count <= 256 else {
                    return toolInvalidParamsResult("play_sequence 'notes' count must be 1..256")
                }
                if let violation = NoteSequenceParser.realtimeTimingViolation(in: events) {
                    return toolInvalidParamsResult("play_sequence: \(violation)")
                }
            case .failure(let error):
                return toolInvalidParamsResult("play_sequence: \(error.hint)")
            }
            switch validatePort(params) {
            case .failure(let msg):
                return toolInvalidParamsResult(msg.message)
            case .success(let port):
                let opKey = port == "midi" ? "midi.play_sequence" : "midi.play_sequence.\(port)"
                return await routedTextResult(router, operation: opKey, params: [
                    "notes": notes,
                ])
            }

        case "send_cc":
            let controller: Int
            switch midiData7Param(params, "controller", requiredBy: "send_cc") {
            case .success(let parsed): controller = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            let value: Int
            switch midiData7Param(params, "value", requiredBy: "send_cc") {
            case .success(let parsed): value = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await dispatchSendOp(
                baseOp: "midi.send_cc",
                params: params,
                additionalParams: [
                    "controller": String(controller),
                    "value": String(value),
                ],
                router: router
            )

        case "send_program_change":
            let program: Int
            switch midiData7Param(params, "program", requiredBy: "send_program_change") {
            case .success(let parsed): program = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await dispatchSendOp(
                baseOp: "midi.send_program_change",
                params: params,
                additionalParams: [
                    "program": String(program),
                ],
                router: router
            )

        case "send_pitch_bend":
            let value: Int
            switch pitchBendParam(params, "value", requiredBy: "send_pitch_bend") {
            case .success(let parsed): value = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await dispatchSendOp(
                baseOp: "midi.send_pitch_bend",
                params: params,
                additionalParams: [
                    "value": String(value),
                ],
                router: router
            )

        case "send_aftertouch":
            let value: Int
            switch midiData7Param(params, "value", requiredBy: "send_aftertouch") {
            case .success(let parsed): value = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await dispatchSendOp(
                baseOp: "midi.send_aftertouch",
                params: params,
                additionalParams: [
                    "value": String(value),
                ],
                router: router
            )

        case "send_sysex":
            // Accept three input shapes so callers can use whichever is ergonomic:
            //   bytes: [0xF0, 0x7E, ..., 0xF7]           (array of ints)
            //   bytes: "F0 7E 7F 06 01 F7"               (hex string, space-sep)
            //   data:  "F0 7E 7F 06 01 F7"               (hex string alias)
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            let data: String
            switch sysexDataParam(params) {
            case .success(let parsed): data = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await routedTextResult(router, operation: "midi.send_sysex", params: ["data": data])

        case "import_file":
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            let path: String
            switch importFilePathParam(params) {
            case .success(let parsed): path = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await routedTextResult(router, operation: "midi.import_file", params: [
                "path": path,
            ])

        case "create_virtual_port":
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            return await routedTextResult(router, operation: "midi.create_virtual_port", params: [
                "name": stringParam(params, "name", default: "Virtual Port"),
            ])

        case "list_ports":
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            return await routedTextResult(router, operation: "midi.list_ports")

        case "mmc_play":
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            return await routedTextResult(router, operation: "mmc.play")

        case "mmc_stop":
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            return await routedTextResult(router, operation: "mmc.stop")

        case "mmc_record":
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            return await routedTextResult(router, operation: "mmc.record_strobe")

        case "mmc_locate":
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            guard params["bar"] != nil || params["time"] != nil else {
                return toolInvalidParamsResult("mmc_locate requires explicit 'bar' or 'time'")
            }
            // Prefer `bar` (int) → expand to bar.beat.sub.tick, else SMPTE `time`.
            // intParam handles int/double/string coercion, so a stringified bar
            // ("5") is accepted too.
            if params["bar"] != nil {
                guard let bar = intParamOrNil(params, "bar") else {
                    return toolInvalidParamsResult("mmc_locate 'bar' must be an integer in 1..9999")
                }
                guard (1...9999).contains(bar) else {
                    return toolInvalidParamsResult("mmc_locate 'bar' must be in 1..9999 (got \(bar))")
                }
                // #108: bar-based locate drives the same Go-To-Position path as
                // transport.goto_position, so finalize it through the identical
                // transport-state read-back verification. Previously mmc_locate
                // returned the raw channel State B and could only ever report
                // `verified:false` — it never confirmed the playhead landed.
                let position = "\(bar).1.1.1"
                let result = await router.route(
                    operation: "transport.goto_position",
                    params: ["position": position]
                )
                return await TransportDispatcher.finalizeGotoPositionResult(
                    result,
                    requestedPosition: position,
                    router: router,
                    cache: cache
                )
            }
            guard let time = params["time"]?.stringValue, isValidSMPTE(time) else {
                return toolInvalidParamsResult("mmc_locate 'time' must be HH:MM:SS:FF")
            }
            return await routedTextResult(router, operation: "mmc.locate", params: [
                "time": time,
            ])

        case "step_input":
            if let reject = rejectIfPortPresent(params, command: command) {
                return reject
            }
            guard params["note"] != nil, params["duration"] != nil else {
                return toolInvalidParamsResult("step_input requires explicit 'note' and 'duration'")
            }
            let note: Int
            switch midiData7Param(params, "note", requiredBy: "step_input") {
            case .success(let parsed): note = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            let duration: String
            switch stepDurationParam(params, "duration", requiredBy: "step_input") {
            case .success(let parsed): duration = parsed
            case .failure(let msg): return toolInvalidParamsResult(msg.message)
            }
            return await routedTextResult(router, operation: "midi.step_input", params: [
                "note": String(note),
                "duration": duration,
            ])

        default:
            return toolTextResult(
                "Unknown MIDI command: \(command). Available: send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, play_sequence, import_file, list_ports, create_virtual_port, step_input, mmc_play, mmc_stop, mmc_record, mmc_locate",
                isError: true
            )
        }
    }

    // MARK: - Send-op dispatch helper (T5)

    /// Common pre-flight + routing path for the 7 `midi.send_*` / `play_sequence`
    /// commands. Validates `port` (default `"midi"`, optional `"keycmd"`) and the
    /// 1-based `channel` (1..16, encoded to wire byte `channel-1`), then forwards
    /// to the operation key `midi.<op>` or `midi.<op>.<port>` so the
    /// ChannelRouter can pick the right transport. `play_sequence` does NOT use
    /// this helper because its per-event channels live inside the notes string;
    /// it inlines just the `validatePort` half above.
    private static func dispatchSendOp(
        baseOp: String,
        params: [String: Value],
        additionalParams: [String: String],
        router: ChannelRouter
    ) async -> CallTool.Result {
        switch validatePort(params) {
        case .failure(let msg):
            return toolInvalidParamsResult(msg.message)
        case .success(let port):
            switch validateMidiChannel(params) {
            case .failure(let msg):
                return toolInvalidParamsResult(msg.message)
            case .success(let wireChannel):
                let opKey = port == "midi" ? baseOp : "\(baseOp).\(port)"
                var allParams = additionalParams
                allParams["channel"] = String(wireChannel)
                return await routedTextResult(router, operation: opKey, params: allParams)
            }
        }
    }

    /// Returns an `invalid_params` result if `params["port"]` is set on a
    /// command that does not support port routing. Used by `mmc_*`,
    /// `send_sysex`, `step_input`, and `create_virtual_port` — these ops live
    /// only on CoreMIDI / MCU / AX, so silently dropping a `port` argument
    /// would mask a setup mistake by the caller.
    private static func rejectIfPortPresent(
        _ params: [String: Value],
        command: String
    ) -> CallTool.Result? {
        guard params["port"] != nil else { return nil }
        return toolInvalidParamsResult(
            "port parameter not supported for \(command)"
        )
    }

    // MARK: - Validation Helpers (T2)
    // Internal visibility (not private) so `@testable import LogicProMCP` tests
    // can exercise them directly. Production callers stay within this file.

    /// Wraps a validation error message as a Swift `Error`.
    /// Enables `Result<T, ValidationFailure>` while preserving concise
    /// `.failure(...)` call sites. Tests read `.message` for
    /// substring assertions; `description` mirrors `message` for logging.
    struct ValidationFailure: Error, Equatable, CustomStringConvertible, ExpressibleByStringLiteral {
        let message: String
        init(_ message: String) { self.message = message }
        init(stringLiteral value: String) { self.message = value }
        var description: String { message }
    }

    private static func strictInt(_ raw: Value?) -> Int? {
        guard let raw else { return nil }
        switch raw {
        case .int(let n):
            return n
        case .double(let f):
            guard f.isFinite else { return nil }
            return Int(exactly: f)
        case .string(let s):
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func midiData7Param(
        _ params: [String: Value],
        _ key: String,
        requiredBy command: String
    ) -> Result<Int, ValidationFailure> {
        guard params[key] != nil else {
            return .failure(ValidationFailure("\(command) requires explicit '\(key)'"))
        }
        guard let value = strictInt(params[key]), (0...127).contains(value) else {
            return .failure(ValidationFailure("\(command) '\(key)' must be an integer in 0..127"))
        }
        return .success(value)
    }

    private static func optionalMidiData7Param(
        _ params: [String: Value],
        _ key: String,
        default defaultValue: Int,
        requiredBy command: String
    ) -> Result<Int, ValidationFailure> {
        guard params[key] != nil else { return .success(defaultValue) }
        guard let value = strictInt(params[key]), (0...127).contains(value) else {
            return .failure(ValidationFailure("\(command) '\(key)' must be an integer in 0..127"))
        }
        return .success(value)
    }

    private static func optionalDurationMsParam(
        _ params: [String: Value],
        _ key: String,
        default defaultValue: Int,
        requiredBy command: String
    ) -> Result<Int, ValidationFailure> {
        guard params[key] != nil else { return .success(defaultValue) }
        guard let value = strictInt(params[key]), (1...30_000).contains(value) else {
            return .failure(ValidationFailure("\(command) '\(key)' must be an integer in 1..30000"))
        }
        return .success(value)
    }

    private static func midiData7ListParam(
        _ params: [String: Value],
        _ key: String,
        requiredBy command: String
    ) -> Result<String, ValidationFailure> {
        guard let raw = params[key] else {
            return .failure(ValidationFailure("\(command) requires explicit '\(key)'"))
        }

        let values: [Int]?
        if let array = raw.arrayValue {
            values = array.map { strictInt($0) }
                .reduce(into: Optional<[Int]>([])) { partial, value in
                    guard partial != nil, let value else {
                        partial = nil
                        return
                    }
                    partial?.append(value)
                }
        } else if let string = raw.stringValue {
            let tokens = string.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            values = tokens.map { Int($0) }
                .reduce(into: Optional<[Int]>([])) { partial, value in
                    guard partial != nil, let value else {
                        partial = nil
                        return
                    }
                    partial?.append(value)
                }
        } else {
            values = nil
        }

        guard let values, (1...24).contains(values.count),
              values.allSatisfy({ (0...127).contains($0) }) else {
            return .failure(ValidationFailure("\(command) '\(key)' must contain 1..24 MIDI notes, each integer 0..127"))
        }
        return .success(values.map(String.init).joined(separator: ","))
    }

    private static func pitchBendParam(
        _ params: [String: Value],
        _ key: String,
        requiredBy command: String
    ) -> Result<Int, ValidationFailure> {
        guard params[key] != nil else {
            return .failure(ValidationFailure("\(command) requires explicit '\(key)'"))
        }
        guard let value = strictInt(params[key]),
              (0...16_383).contains(value) else {
            return .failure(ValidationFailure("\(command) '\(key)' must be an integer in 0..16383 (center=8192)"))
        }
        return .success(value)
    }

    private static func sysexDataParam(
        _ params: [String: Value]
    ) -> Result<String, ValidationFailure> {
        let bytes: [Int]?
        if let arr = params["bytes"]?.arrayValue {
            guard arr.count <= maxSysExBytes else {
                return .failure(ValidationFailure("send_sysex payload exceeds \(maxSysExBytes)-byte limit"))
            }
            var parsed: [Int] = []
            for item in arr {
                guard let value = strictInt(item), (0...255).contains(value) else {
                    return .failure(ValidationFailure("send_sysex 'bytes' array must contain only integers 0..255"))
                }
                parsed.append(value)
            }
            bytes = parsed
        } else if let s = params["bytes"]?.stringValue, !s.isEmpty {
            guard s.count <= maxSysExTextCharacters else {
                return .failure(ValidationFailure("send_sysex payload exceeds \(maxSysExBytes)-byte limit"))
            }
            bytes = parseSysexHexBytes(s)
        } else if let s = params["data"]?.stringValue, !s.isEmpty {
            guard s.count <= maxSysExTextCharacters else {
                return .failure(ValidationFailure("send_sysex payload exceeds \(maxSysExBytes)-byte limit"))
            }
            bytes = parseSysexHexBytes(s)
        } else {
            bytes = nil
        }

        guard let bytes, bytes.count <= maxSysExBytes else {
            return .failure(ValidationFailure("send_sysex payload exceeds \(maxSysExBytes)-byte limit"))
        }
        guard bytes.count >= 3, bytes.first == 0xF0, bytes.last == 0xF7 else {
            return .failure(ValidationFailure("send_sysex requires bytes/data starting with F0, ending with F7, and at least one data byte"))
        }
        let interior = bytes.dropFirst().dropLast()
        guard !interior.contains(0xF0), !interior.contains(0xF7) else {
            return .failure(ValidationFailure("send_sysex bytes must not contain internal F0/F7 delimiters"))
        }
        guard interior.allSatisfy({ (0...0x7F).contains($0) }) else {
            return .failure(ValidationFailure("send_sysex bytes must use a 7-bit body; only the first F0 and final F7 may be status bytes"))
        }
        return .success(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    private static func parseSysexHexBytes(_ raw: String) -> [Int]? {
        let tokens = raw
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        var bytes: [Int] = []
        for token in tokens {
            guard let value = Int(token, radix: 16), (0...255).contains(value) else {
                return nil
            }
            bytes.append(value)
        }
        return bytes
    }

    private static func isValidSMPTE(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m),
              let sec = Int(parts[2]), (0...59).contains(sec),
              let f = Int(parts[3]), (0...99).contains(f) else {
            return false
        }
        return true
    }

    private static func stepDurationParam(
        _ params: [String: Value],
        _ key: String,
        requiredBy command: String
    ) -> Result<String, ValidationFailure> {
        guard let raw = params[key] else {
            return .failure(ValidationFailure("\(command) requires explicit '\(key)'"))
        }
        let allowedDurations: Set<String> = ["1/1", "1/2", "1/4", "1/8", "1/16", "1/32"]
        if let s = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if allowedDurations.contains(s) { return .success(s) }
            if let ms = Int(s), (1...30_000).contains(ms) { return .success(String(ms)) }
            return .failure(ValidationFailure("\(command) '\(key)' must be one of \(allowedDurations.sorted().joined(separator: ", ")) or integer milliseconds 1..30000"))
        }
        if let ms = strictInt(raw), (1...30_000).contains(ms) {
            return .success(String(ms))
        }
        return .failure(ValidationFailure("\(command) '\(key)' must be one of \(allowedDurations.sorted().joined(separator: ", ")) or integer milliseconds 1..30000"))
    }

    /// Validates the `port` parameter for MIDI routing.
    /// - Returns: `.success("midi")` if missing (default for backward compat),
    ///   `.success("midi"|"keycmd")` if explicitly set to a supported value,
    ///   `.failure(...)` for any other string (including `""`, `"scripter"`).
    private static let validPorts: Set<String> = ["midi", "keycmd"]

    internal static func validatePort(_ params: [String: Value]) -> Result<String, ValidationFailure> {
        // Empty string `""` is explicitly rejected (does not fall through to default).
        guard let rawValue = params["port"] else {
            return .success("midi") // missing = default
        }
        guard let raw = rawValue.stringValue else {
            return .failure(ValidationFailure("port must be a string and one of: midi, keycmd"))
        }
        guard Self.validPorts.contains(raw) else {
            return .failure(ValidationFailure("port must be one of: midi, keycmd"))
        }
        return .success(raw)
    }

    private static func importFilePathParam(
        _ params: [String: Value]
    ) -> Result<String, ValidationFailure> {
        guard let raw = params["path"] else {
            return .failure(ValidationFailure("import_file requires explicit 'path'"))
        }
        guard let path = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return .failure(ValidationFailure("import_file 'path' must be a non-empty string"))
        }
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            return .failure(ValidationFailure("import_file 'path' must not contain control characters"))
        }

        guard let normalized = AccessibilityChannel.validatedMIDIImportPath(path) else {
            return .failure(ValidationFailure("import_file 'path' must be a server-managed LogicProMCP temp .mid"))
        }
        return .success(normalized)
    }

    /// Validates 1-based MIDI channel input and converts to wire byte (0..15).
    /// - Accepts: `.int(1...16)`, `.double(whole 1.0...16.0)`, `.string` containing strict integer.
    /// - Rejects: `.bool`, fractional/NaN/Infinity doubles, fractional strings,
    ///   out-of-range, and non-numeric kinds (`.array`, `.object`, `.data`, `.null`).
    /// - Missing key returns `.success(0)` (default Ch 1).
    internal static func validateMidiChannel(_ params: [String: Value]) -> Result<UInt8, ValidationFailure> {
        guard let raw = params["channel"] else {
            return .success(0) // default Ch 1 (wire 0)
        }
        let intCandidate: Int? = {
            switch raw {
            case .int(let n): return n
            case .double(let f): return Int(exactly: f)
            case .string(let s):
                // Strict integer parsing — rejects "1.5", "abc", "" etc.
                return Int(s)
            default:
                // .bool, .array, .object, .data, .null → reject
                return nil
            }
        }()
        guard let v = intCandidate else {
            return .failure(ValidationFailure("channel must be integer 1..16 (1-based)"))
        }
        guard (1...16).contains(v) else {
            return .failure(ValidationFailure("channel must be integer 1..16 (1-based)"))
        }
        return .success(UInt8(v - 1))
    }
}
