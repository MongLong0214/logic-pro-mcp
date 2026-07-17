import Foundation
import MCP

struct AudioDispatcher {
    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicAudio)

    /// Non-absolute marker assigned to outputRoot when the caller sent a present-but-malformed
    /// output_root. validatedURL rejects it (does not begin with "/") so confinement fails
    /// closed as unsafe_path instead of being silently disabled.
    static let invalidOutputRootSentinel = "__invalid_output_root__"

    static let tool = commandTool(
        name: "logic_audio",
        description: "Read-only audio artifact analysis for post-bounce/export verification. Commands: analyze_file. Params: analyze_file -> { path: absolute audio file path, output_root?: absolute allowlist root, min_duration_seconds?: number, expected_duration_seconds?: number, max_duration_drift_seconds?: number, min_file_size_bytes?: int, max_input_file_size_bytes?: int, max_input_duration_seconds?: number, max_decoded_frames?: int, max_peak_dbfs?: number, near_silence_dbfs?: number, max_silence_ratio?: number, expected_sample_rate?: int, expected_channel_count?: int }. Returns schema logic_pro_mcp_audio_analysis.v1 and never mutates files or Logic Pro.",
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

        default:
            return toolTextResult(
                "Unknown audio command: \(command). Available: analyze_file",
                isError: true
            )
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
