import Foundation
import MCP

struct AudioDispatcher: OperationTraceDispatching {
    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicAudio)

    /// Non-absolute marker assigned to outputRoot when the caller sent a present-but-malformed
    /// output_root. validatedURL rejects it (does not begin with "/") so confinement fails
    /// closed as unsafe_path instead of being silently disabled.
    static let invalidOutputRootSentinel = "__invalid_output_root__"

    static let tool = commandTool(
        name: "logic_audio",
        description: "Read-only audio artifact analysis for post-bounce/export verification. Commands: analyze_file, analyze_spectrum, recommend_eq. Params: analyze_file -> { path: absolute audio file path, output_root?: absolute allowlist root, min_duration_seconds?: number, expected_duration_seconds?: number, max_duration_drift_seconds?: number, min_file_size_bytes?: int, max_input_file_size_bytes?: int, max_input_duration_seconds?: number, max_decoded_frames?: int, max_peak_dbfs?: number, near_silence_dbfs?: number, max_silence_ratio?: number, expected_sample_rate?: int, expected_channel_count?: int }; analyze_spectrum -> { path: absolute audio file path }; recommend_eq -> { path: absolute audio file path, minimum_level?: number }. analyze_spectrum returns per-band energy; a band whose edges enclose no FFT bin at the file's sample rate is marked measured:false and its energyDb is the floor sentinel, not a reading. `classification` is a coarse advisory heuristic — it reads white noise as drums and a pure tone as vocal — and `levelConfidence` is a loudness figure, not a measure of how sure that classification is. Returns analysis/recommendation JSON and never mutates files or Logic Pro.",
        commandDescription: "Audio command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        runtime: AudioAnalyzer.Runtime = .production
    ) -> CallTool.Result {
        switch command {
        case "analyze_file":
            let path = stringParam(params, "path")
            guard !path.isEmpty else {
                let result = AudioAnalyzer.analyzeFile(path: "", policy: .default, runtime: runtime)
                return toolTextResult(encodeJSON(result), isError: true)
            }

            let policy = policy(from: params)
            let result = AudioAnalyzer.analyzeFile(path: path, policy: policy, runtime: runtime)
            return toolTextResult(
                encodeJSON(result),
                isError: result.verification.status == .fail
            )

        // Promoted 2026-08-28. What the flag was holding back was measured and fixed first: bands
        // whose edges enclose no FFT bin no longer report the floor as a reading, the edge
        // accumulators are no longer picked as resonances — which is what produced a recommended
        // cut at 20 Hz on material with nothing wrong at 20 Hz — and the number called `confidence`
        // is named `levelConfidence`, because it is a loudness gate and never said anything about
        // the classification.
        //
        // What is NOT fixed and is stated in the description instead: the classifier is coarse. It
        // reads white noise as `drums` and a pure sine as `vocal`. Advisory is what it is, so
        // advisory is what it says.
        case "analyze_spectrum":
            return spectralAnalysisResult(command: command, params: params)

        case "recommend_eq":
            return eqRecommendationResult(command: command, params: params)

        default:
            return Self.unhandledCommandResult(command, label: "audio")
        }
    }

    /// ADR-012's public commands deliberately expose no write surface: they
    /// only decode the supplied artifact and return analysis/advice. The result
    /// keeps the engine's Codable schema rather than translating it into a
    /// lossy dispatcher-specific representation.
    private static func spectralAnalysisResult(
        command: String,
        params: [String: Value]
    ) -> CallTool.Result {
        switch spectralInput(command: command, params: params) {
        case .refusal(let result):
            return result
        case .input(let input):
            do {
                return toolTextResult(encodeJSON(try analyzeSpectrum(path: input.path, command: command)))
            } catch {
                return spectralAnalysisFailureResult(error, operation: "audio.\(command)")
            }
        }
    }

    private static func eqRecommendationResult(
        command: String,
        params: [String: Value]
    ) -> CallTool.Result {
        switch spectralInput(command: command, params: params) {
        case .refusal(let result):
            return result
        case .input(let input):
            let minimumLevel: Double
            if params["minimum_level"] == nil {
                minimumLevel = 0.6
            } else if let value = doubleParamOrNil(params, "minimum_level") {
                minimumLevel = value
            } else {
                return toolInvalidParamsResult(
                    "recommend_eq 'minimum_level' must be a finite number",
                    extras: ["operation": "audio.recommend_eq", "write_attempted": false]
                )
            }
            do {
                let analysis = try analyzeSpectrum(path: input.path, command: command)
                switch recommendEQ(analysis, minimumLevel: minimumLevel) {
                case .recommendation(let bands):
                    return toolTextResult(encodeJSON(EQRecommendationResponse(bands: bands)))
                case .noSafeRecommendation(let reason):
                    return toolTextResult(encodeJSON(EQRecommendationResponse(bands: [], reason: reason)))
                }
            } catch {
                return spectralAnalysisFailureResult(error, operation: "audio.\(command)")
            }
        }
    }

    private static func spectralInput(
        command: String,
        params: [String: Value]
    ) -> SpectralInputResult {
        let path = stringParam(params, "path").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return .refusal(toolInvalidParamsResult(
                "\(command) requires non-empty string 'path'",
                extras: ["operation": "audio.\(command)", "write_attempted": false]
            ))
        }
        return .input(SpectralInput(path: path))
    }

    private static func analyzeSpectrum(path: String, command: String) throws -> SpectralAnalysisResult {
        try AudioFeatureExtractionEngine.analyzeFile(
            path: path,
            analysisRef: "audio.\(command)",
            artifactFingerprint: "not_computed_by_dispatcher"
        )
    }

    private static func spectralAnalysisFailureResult(
        _ error: Error,
        operation: String
    ) -> CallTool.Result {
        let failure = spectralFailureDetails(error)
        return toolStateCResult(
            .spectralAnalysisFailed,
            hint: "Spectral analysis failed: \(failure.detail)",
            extras: [
                "operation": operation,
                "analysis_error": failure.code,
                "write_attempted": false,
            ]
        )
    }

    private static func spectralFailureDetails(_ error: Error) -> (code: String, detail: String) {
        if let error = error as? AudioAnalyzer.AnalysisError {
            return (error.code, error.message)
        }
        if let error = error as? AudioFeatureExtractionEngine.FeatureExtractionError {
            switch error {
            case .specialFile(let detail): return ("special_file", detail)
            case .unreadable(let detail): return ("unreadable", detail)
            case .unsupportedFormat(let detail): return ("unsupported_format", detail)
            case .decode(let detail): return ("decode", detail)
            case .pathIdentityChanged: return ("path_identity_changed", "path identity changed during analysis")
            }
        }
        return ("unknown", error.localizedDescription)
    }

    private struct SpectralInput {
        let path: String
    }

    private enum SpectralInputResult {
        case input(SpectralInput)
        case refusal(CallTool.Result)
    }

    private struct EQRecommendationResponse: Encodable {
        let bands: [EQBandRecommendation]
        let reason: String?

        init(bands: [EQBandRecommendation], reason: String? = nil) {
            self.bands = bands
            self.reason = reason
        }
    }

    private static func policy(from params: [String: Value]) -> AudioAnalyzer.AnalysisPolicy {
        var policy = AudioAnalyzer.AnalysisPolicy.default
        policy.minimumDurationSeconds = doubleParamOrNil(params, "min_duration_seconds", "minimum_duration_seconds")
        policy.expectedDurationSeconds = doubleParamOrNil(params, "expected_duration_seconds")
        policy.maximumDurationDriftSeconds = doubleParamOrNil(params, "max_duration_drift_seconds", "maximum_duration_drift_seconds")
        policy.minimumFileSizeBytes = intParamOrNil(params, "min_file_size_bytes", "minimum_file_size_bytes")
        if let maxInputFileSize = intParamOrNil(params, "max_input_file_size_bytes", "maximum_input_file_size_bytes"),
           maxInputFileSize > 0 {
            policy.maximumInputFileSizeBytes = Int64(maxInputFileSize)
        }
        if let maxInputDuration = doubleParamOrNil(params, "max_input_duration_seconds", "maximum_input_duration_seconds"),
           maxInputDuration > 0 {
            policy.maximumInputDurationSeconds = maxInputDuration
        }
        if let maxDecodedFrames = intParamOrNil(params, "max_decoded_frames", "maximum_decoded_frames"),
           maxDecodedFrames > 0 {
            policy.maximumDecodedFrames = Int64(maxDecodedFrames)
        }
        policy.maximumPeakDbfs = doubleParamOrNil(params, "max_peak_dbfs", "maximum_peak_dbfs")
        policy.expectedSampleRate = intParamOrNil(params, "expected_sample_rate")
        policy.expectedChannelCount = intParamOrNil(params, "expected_channel_count")
        // output_root is a security confinement param. Fail CLOSED: if the key is present
        // but not a usable non-empty string, force a sentinel that validatedURL rejects as
        // unsafe_path rather than silently dropping the allowlist (raw .stringValue would
        // return nil for any non-string JSON, disabling confinement without an error).
        if let raw = params["output_root"] {
            if let s = raw.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                policy.outputRoot = s
            } else {
                policy.outputRoot = invalidOutputRootSentinel
            }
        }

        if let nearSilence = doubleParamOrNil(params, "near_silence_dbfs", "near_silence_threshold_dbfs"),
           nearSilence <= 0.0 {
            // dBFS thresholds are <= 0 by definition. A positive value would push the
            // silence threshold to/above full scale and flag every valid bounce as silent,
            // so an out-of-range value is ignored and the safe default is kept rather than
            // silently flipping a good export to near_silent_output.
            policy.nearSilenceThresholdDbfs = nearSilence
        }
        if let maxSilenceRatio = doubleParamOrNil(params, "max_silence_ratio", "maximum_silence_ratio") {
            policy.maximumSilenceRatio = min(max(maxSilenceRatio, 0.0), 1.0)
        }
        return policy
    }
}
