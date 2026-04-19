import Foundation
import MCP

struct TransportDispatcher {
    static let tool = Tool(
        name: "logic_transport",
        description: "Control Logic Pro transport. Commands: play, stop, record, pause, rewind, fast_forward, toggle_cycle, toggle_metronome, set_tempo, goto_position, set_cycle_range, toggle_count_in. Params: set_tempo -> { tempo: Float } (5.0-999.0); goto_position -> { bar: Int (1..9999) } or { position: String } where String is bar.beat.sub.tick (e.g. \"9.1.1.1\") or HH:MM:SS:FF SMPTE (e.g. \"00:00:08:12\"); set_cycle_range -> { start: Int, end: Int }; others -> {}.",
        inputSchema: commandParamsToolSchema(commandDescription: "Transport command to execute")
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "play":
            let result = await router.route(operation: "transport.play")
            return toolTextResult(result)

        case "stop":
            let result = await router.route(operation: "transport.stop")
            return toolTextResult(result)

        case "record":
            let result = await router.route(operation: "transport.record")
            return toolTextResult(result)

        case "pause":
            let result = await router.route(operation: "transport.pause")
            return toolTextResult(result)

        case "rewind":
            let result = await router.route(operation: "transport.rewind")
            return toolTextResult(result)

        case "fast_forward":
            let result = await router.route(operation: "transport.fast_forward")
            return toolTextResult(result)

        case "toggle_cycle":
            let result = await router.route(operation: "transport.toggle_cycle")
            return toolTextResult(result)

        case "toggle_metronome":
            let result = await router.route(operation: "transport.toggle_metronome")
            return toolTextResult(result)

        case "toggle_count_in":
            let result = await router.route(operation: "transport.toggle_count_in")
            return toolTextResult(result)

        case "set_tempo":
            let tempo = doubleParam(params, "tempo", "bpm", default: 120.0)
            // Logic Pro's tempo range is 5..990 BPM; the schema documents 20..999.
            // Accept a slightly-wider 5..999 to match Logic's actual behavior,
            // reject anything clearly absurd so a typo doesn't silently pass.
            guard (5.0...999.0).contains(tempo) else {
                return toolTextResult(
                    "set_tempo 'tempo' must be in 5..999 (got \(tempo))",
                    isError: true
                )
            }
            let result = await router.route(
                operation: "transport.set_tempo",
                params: ["bpm": String(tempo)]
            )
            return toolTextResult(result)

        case "goto_position":
            // Reject unknown keys before falling back to defaults. Prior to
            // v3.0.0 a legacy `time` alias was silently accepted; callers that
            // never updated their schema would silently seek to bar 1. Now the
            // tool fails closed and surfaces exactly which key was wrong.
            let allowedKeys: Set<String> = ["bar", "position"]
            let unknownKeys = params.keys.filter { !allowedKeys.contains($0) }
            if !unknownKeys.isEmpty {
                let sorted = unknownKeys.sorted().joined(separator: ", ")
                return toolTextResult(
                    "goto_position got unknown param(s): \(sorted). Allowed: bar, position. The legacy 'time' alias was removed in v3.0.0.",
                    isError: true
                )
            }
            // intParam coerces int/double/string so `{"bar":"5"}` works too.
            if params["bar"] != nil {
                let bar = intParam(params, "bar", default: 1)
                guard (1...9999).contains(bar) else {
                    return toolTextResult(
                        "goto_position 'bar' must be in 1..9999 (got \(bar))",
                        isError: true
                    )
                }
                let result = await router.route(
                    operation: "transport.goto_position",
                    params: ["position": "\(bar).1.1.1"]
                )
                return toolTextResult(result)
            }
            let time = stringParam(params, "position", default: "1.1.1.1")
            // Validate position format before routing. Accept:
            //   Bar/beat: "N.N.N.N" with bar 1..9999, beat 1..16, sub 1..16, tick 1..999
            //   SMPTE:    "HH:MM:SS:FF" with HH 0..23, MM/SS 0..59, FF 0..99
            guard TransportDispatcher.isValidPositionString(time) else {
                return toolTextResult(
                    "goto_position 'position' must be bar.beat.sub.tick (e.g. 1.1.1.1) or HH:MM:SS:FF (got '\(time)')",
                    isError: true
                )
            }
            let result = await router.route(
                operation: "transport.goto_position",
                params: ["position": time]
            )
            return toolTextResult(result)

        case "set_cycle_range":
            let start = intParam(params, "start", default: 1)
            let end = intParam(params, "end", default: 5)
            // Bounds: same window as goto_position.bar (1..9999).
            // Enforce start <= end so a swapped-argument typo surfaces early.
            guard (1...9999).contains(start), (1...9999).contains(end) else {
                return toolTextResult(
                    "set_cycle_range 'start' and 'end' must be in 1..9999 (got \(start)..\(end))",
                    isError: true
                )
            }
            guard start <= end else {
                return toolTextResult(
                    "set_cycle_range 'start' (\(start)) must be <= 'end' (\(end))",
                    isError: true
                )
            }
            let result = await router.route(
                operation: "transport.set_cycle_range",
                params: ["start": "\(start).1.1.1", "end": "\(end).1.1.1"]
            )
            return toolTextResult(result)

        default:
            return toolTextResult(
                "Unknown transport command: \(command). Available: play, stop, record, pause, rewind, fast_forward, toggle_cycle, toggle_metronome, set_tempo, goto_position, set_cycle_range, toggle_count_in",
                isError: true
            )
        }
    }

    /// Accept "bar.beat.sub.tick" (each positive) or "HH:MM:SS:FF" (with
    /// each field within its canonical range). Anything else — including
    /// empty string and malformed tokens like "99:99:99:99" — is rejected.
    static func isValidPositionString(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }

        // Bar/beat format.
        let dots = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if dots.count == 4 {
            guard let bar = Int(dots[0]), (1...9999).contains(bar),
                  let beat = Int(dots[1]), (1...16).contains(beat),
                  let sub = Int(dots[2]), (1...16).contains(sub),
                  let tick = Int(dots[3]), (1...999).contains(tick) else {
                return false
            }
            return true
        }

        // SMPTE format.
        let colons = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if colons.count == 4 {
            guard let h = Int(colons[0]), (0...23).contains(h),
                  let m = Int(colons[1]), (0...59).contains(m),
                  let sec = Int(colons[2]), (0...59).contains(sec),
                  let f = Int(colons[3]), (0...99).contains(f) else {
                return false
            }
            return true
        }

        return false
    }
}
