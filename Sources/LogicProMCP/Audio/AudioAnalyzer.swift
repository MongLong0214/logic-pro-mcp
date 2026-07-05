import AVFoundation
import Foundation

enum AudioAnalyzer {
    enum AnalysisError: Error, Equatable, Sendable {
        case unsafePath(String)
        case missingFile
        case directoryPath
        case unsupportedFormat(String)
        case unreadableMetadata(String)
        case zeroLengthFile
        case analysisLimitExceeded(String)
        case decoderError(String)

        var code: String {
            switch self {
            case .unsafePath: return "unsafe_path"
            case .missingFile: return "missing_file"
            case .directoryPath: return "directory_path"
            case .unsupportedFormat: return "unsupported_format"
            case .unreadableMetadata: return "unreadable_metadata"
            case .zeroLengthFile: return "zero_length_file"
            case .analysisLimitExceeded: return "analysis_limit_exceeded"
            case .decoderError: return "decoder_error"
            }
        }

        var message: String {
            switch self {
            case .unsafePath(let reason): return reason
            case .missingFile: return "Audio file does not exist."
            case .directoryPath: return "Path resolves to a directory, not an audio file."
            case .unsupportedFormat(let ext): return "Unsupported audio format: \(ext.isEmpty ? "<none>" : ext)."
            case .unreadableMetadata(let reason): return reason
            case .zeroLengthFile: return "Audio file has zero bytes."
            case .analysisLimitExceeded(let reason): return reason
            case .decoderError(let reason): return reason
            }
        }

        /// Honest disk-presence for the `exists` contract field. `directoryPath`,
        /// `zeroLengthFile`, `unsupportedFormat`, `unreadableMetadata`, and
        /// `decoderError` are all reached only after the path was confirmed present
        /// (an addressable item exists on disk), so reporting exists:false for those
        /// would lie about a file an agent may otherwise needlessly re-export.
        /// `unsafePath` is rejected before any existence check; `missingFile` is the
        /// genuine not-present case.
        var pathExists: Bool {
            switch self {
            case .unsafePath, .missingFile:
                return false
            case .directoryPath, .zeroLengthFile, .unsupportedFormat, .unreadableMetadata,
                 .analysisLimitExceeded, .decoderError:
                return true
            }
        }
    }

    enum VerificationStatus: String, Codable, Sendable {
        case pass
        case warn
        case fail
    }

    struct Verification: Codable, Equatable, Sendable {
        let status: VerificationStatus
        let reasons: [String]
        /// Optional human-readable message for the error path. `reasons` is always a
        /// uniform list of stable machine codes; `detail` is the only place a free-text
        /// sentence appears, so consumers can parse codes without special-casing.
        let detail: String?

        init(status: VerificationStatus, reasons: [String], detail: String? = nil) {
            self.status = status
            self.reasons = reasons
            self.detail = detail
        }
    }

    struct FrequencyPeak: Codable, Equatable, Sendable {
        let frequencyHz: Double
        let magnitude: Double

        enum CodingKeys: String, CodingKey {
            case frequencyHz = "frequency_hz"
            case magnitude
        }
    }

    static let defaultMaximumInputFileSizeBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let defaultMaximumInputDurationSeconds: Double = 2 * 60 * 60
    static let defaultMaximumDecodedFrames: Int64 = 192_000 * 60 * 60 * 2

    struct AnalysisPolicy: Equatable, Sendable {
        var minimumDurationSeconds: Double?
        var maximumDurationDriftSeconds: Double?
        var expectedDurationSeconds: Double?
        var minimumFileSizeBytes: Int?
        var maximumInputFileSizeBytes: Int64?
        var maximumInputDurationSeconds: Double?
        var maximumDecodedFrames: Int64?
        var maximumPeakDbfs: Double?
        var nearSilenceThresholdDbfs: Double
        var maximumSilenceRatio: Double
        var expectedSampleRate: Int?
        var expectedChannelCount: Int?
        var outputRoot: String?

        init(
            minimumDurationSeconds: Double? = nil,
            maximumDurationDriftSeconds: Double? = nil,
            expectedDurationSeconds: Double? = nil,
            minimumFileSizeBytes: Int? = nil,
            maximumInputFileSizeBytes: Int64? = AudioAnalyzer.defaultMaximumInputFileSizeBytes,
            maximumInputDurationSeconds: Double? = AudioAnalyzer.defaultMaximumInputDurationSeconds,
            maximumDecodedFrames: Int64? = AudioAnalyzer.defaultMaximumDecodedFrames,
            maximumPeakDbfs: Double? = nil,
            nearSilenceThresholdDbfs: Double = -60.0,
            maximumSilenceRatio: Double = 0.98,
            expectedSampleRate: Int? = nil,
            expectedChannelCount: Int? = nil,
            outputRoot: String? = nil
        ) {
            self.minimumDurationSeconds = minimumDurationSeconds
            self.maximumDurationDriftSeconds = maximumDurationDriftSeconds
            self.expectedDurationSeconds = expectedDurationSeconds
            self.minimumFileSizeBytes = minimumFileSizeBytes
            self.maximumInputFileSizeBytes = maximumInputFileSizeBytes
            self.maximumInputDurationSeconds = maximumInputDurationSeconds
            self.maximumDecodedFrames = maximumDecodedFrames
            self.maximumPeakDbfs = maximumPeakDbfs
            self.nearSilenceThresholdDbfs = nearSilenceThresholdDbfs
            self.maximumSilenceRatio = maximumSilenceRatio
            self.expectedSampleRate = expectedSampleRate
            self.expectedChannelCount = expectedChannelCount
            self.outputRoot = outputRoot
        }

        /// Every argument in the previous explicit form equalled `init`'s own
        /// default, so `.default` is exactly `AnalysisPolicy()` (round-1 #11).
        static let `default` = AnalysisPolicy()
    }

    struct Result: Codable, Equatable, Sendable {
        let schema: String
        let path: String
        let exists: Bool
        let format: String
        let durationSeconds: Double
        let sampleRate: Int
        let channelCount: Int
        let frameCount: Int64
        let fileSizeBytes: Int64
        let rmsDbfs: Double
        let peakDbfs: Double
        let truePeakDbfs: Double?
        let loudnessEstimateLufs: Double?
        let loudnessMethod: String
        let silenceRatio: Double
        let nonSilentDurationSeconds: Double
        let spectralCentroidHz: Double?
        let frequencyPeaks: [FrequencyPeak]
        let verification: Verification

        enum CodingKeys: String, CodingKey {
            case schema
            case path
            case exists
            case format
            case durationSeconds = "duration_seconds"
            case sampleRate = "sample_rate"
            case channelCount = "channel_count"
            case frameCount = "frame_count"
            case fileSizeBytes = "file_size_bytes"
            case rmsDbfs = "rms_dbfs"
            case peakDbfs = "peak_dbfs"
            case truePeakDbfs = "true_peak_dbfs"
            case loudnessEstimateLufs = "loudness_estimate_lufs"
            case loudnessMethod = "loudness_method"
            case silenceRatio = "silence_ratio"
            case nonSilentDurationSeconds = "non_silent_duration_seconds"
            case spectralCentroidHz = "spectral_centroid_hz"
            case frequencyPeaks = "frequency_peaks"
            case verification
        }
    }

    struct Runtime: @unchecked Sendable {
        let fileExists: (String, UnsafeMutablePointer<ObjCBool>?) -> Bool
        let attributesOfItem: (String) throws -> [FileAttributeKey: Any]
        let resolveSymlinks: (String) -> String

        static let production = Runtime(
            fileExists: { path, isDirectory in
                FileManager.default.fileExists(atPath: path, isDirectory: isDirectory)
            },
            attributesOfItem: { path in
                try FileManager.default.attributesOfItem(atPath: path)
            },
            resolveSymlinks: { path in
                URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            }
        )
    }

    static let schema = "logic_pro_mcp_audio_analysis.v1"
    private static let supportedExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "m4a", "mp3"]

    static func analyzeFile(
        path rawPath: String,
        policy: AnalysisPolicy = .default,
        runtime: Runtime = .production
    ) -> Result {
        do {
            let safeURL = try validatedURL(rawPath, policy: policy, runtime: runtime)
            let attributes = try runtime.attributesOfItem(safeURL.path)
            let fileSize = Int64((attributes[.size] as? NSNumber)?.int64Value ?? 0)
            guard fileSize > 0 else {
                throw AnalysisError.zeroLengthFile
            }
            if let maximumFileSize = policy.maximumInputFileSizeBytes,
               maximumFileSize > 0,
               fileSize > maximumFileSize {
                throw AnalysisError.analysisLimitExceeded(
                    "Audio file size \(fileSize) bytes exceeds maximum \(maximumFileSize) bytes"
                )
            }

            let ext = normalizedExtension(safeURL.path)
            guard supportedExtensions.contains(ext) else {
                throw AnalysisError.unsupportedFormat(ext)
            }

            let measurements = try measureAudio(
                url: safeURL,
                fileSizeBytes: fileSize,
                policy: policy,
                silenceThresholdDbfs: policy.nearSilenceThresholdDbfs
            )
            let verification = evaluate(measurements, policy: policy)
            return measurements.withVerification(verification)
        } catch let error as AnalysisError {
            return failureResult(path: rawPath, error: error)
        } catch {
            return failureResult(path: rawPath, error: .decoderError(error.localizedDescription))
        }
    }

    private static func validatedURL(
        _ rawPath: String,
        policy: AnalysisPolicy,
        runtime: Runtime
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw AnalysisError.unsafePath("relative paths are rejected")
        }
        guard !pathContainsTraversal(trimmed) else {
            throw AnalysisError.unsafePath("path traversal components are rejected")
        }
        guard !isICloudPath(trimmed) else {
            throw AnalysisError.unsafePath("iCloud paths are rejected for local export verification")
        }

        let resolvedPath = runtime.resolveSymlinks(trimmed)
        var isDirectory = ObjCBool(false)
        guard runtime.fileExists(resolvedPath, &isDirectory) else {
            throw AnalysisError.missingFile
        }
        guard !isDirectory.boolValue else {
            throw AnalysisError.directoryPath
        }

        if let outputRoot = policy.outputRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !outputRoot.isEmpty {
            guard outputRoot.hasPrefix("/") else {
                throw AnalysisError.unsafePath("output_root must be absolute")
            }
            guard !pathContainsTraversal(outputRoot) else {
                throw AnalysisError.unsafePath("output_root traversal components are rejected")
            }
            guard !isICloudPath(outputRoot) else {
                throw AnalysisError.unsafePath("iCloud output roots are rejected")
            }
            // SECURITY: do NOT symlink-resolve the root. The root is compared as
            // its literal standardized path while the file path IS fully
            // symlink-resolved, so a symlink-swapped output_root (a trusted-named
            // symlink repointed at an escaped directory) fails containment and is
            // rejected — see testAudioAnalyzerRejectsSymlinkSwappedOutputRoot and
            // the export-guardrail symlink-swap test. (This is intentional, not
            // the false-reject it superficially resembles.)
            let standardizedRoot = URL(fileURLWithPath: outputRoot).standardizedFileURL.path
            guard standardizedRoot != "/" else {
                throw AnalysisError.unsafePath("output_root must not be the filesystem root")
            }
            guard resolvedPath == standardizedRoot || resolvedPath.hasPrefix(standardizedRoot + "/") else {
                throw AnalysisError.unsafePath("resolved file path escapes output_root")
            }
        }

        return URL(fileURLWithPath: resolvedPath)
    }

    private static func measureAudio(
        url: URL,
        fileSizeBytes: Int64,
        policy: AnalysisPolicy,
        silenceThresholdDbfs: Double
    ) throws -> Result {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AnalysisError.decoderError(error.localizedDescription)
        }

        let processingFormat = file.processingFormat
        let sampleRate = processingFormat.sampleRate
        let channelCount = Int(processingFormat.channelCount)
        let frameCount = file.length
        guard sampleRate > 0, channelCount > 0 else {
            throw AnalysisError.unreadableMetadata("sample rate or channel count is zero")
        }
        guard frameCount > 0 else {
            throw AnalysisError.zeroLengthFile
        }
        if let maximumFrames = policy.maximumDecodedFrames,
           maximumFrames > 0,
           frameCount > maximumFrames {
            throw AnalysisError.analysisLimitExceeded(
                "Audio frame count \(frameCount) exceeds maximum \(maximumFrames)"
            )
        }
        let declaredDuration = Double(frameCount) / sampleRate
        if let maximumDuration = policy.maximumInputDurationSeconds,
           maximumDuration > 0,
           declaredDuration > maximumDuration {
            throw AnalysisError.analysisLimitExceeded(
                "Audio duration \(rounded(declaredDuration))s exceeds maximum \(rounded(maximumDuration))s"
            )
        }

        let thresholdAmplitude = dbfsToAmplitude(silenceThresholdDbfs)
        let frameCapacity: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCapacity) else {
            throw AnalysisError.decoderError("could not allocate PCM buffer")
        }

        var remaining = frameCount
        var sampleCount = 0
        var framesProcessed: Int64 = 0
        var silentFrames = 0
        var sumSquares = 0.0
        var peak = 0.0

        while remaining > 0 {
            let framesToRead = AVAudioFrameCount(min(Int64(frameCapacity), remaining))
            do {
                try file.read(into: buffer, frameCount: framesToRead)
            } catch {
                throw AnalysisError.decoderError(error.localizedDescription)
            }
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }
            remaining -= Int64(framesRead)
            framesProcessed += Int64(framesRead)

            guard let channelData = buffer.floatChannelData else {
                throw AnalysisError.decoderError("decoded audio is not float PCM")
            }

            for frame in 0..<framesRead {
                var framePeak = 0.0
                for channel in 0..<channelCount {
                    // Measure the raw magnitude — do NOT clamp to 1.0. Float PCM from a
                    // bounce can legitimately exceed full scale (digital/inter-sample overs),
                    // and clamping would make true overs report as exactly 0 dBFS, hiding
                    // destructive clipping from the max_peak_dbfs gate.
                    let absValue = abs(Double(channelData[channel][frame]))
                    framePeak = max(framePeak, absValue)
                    peak = max(peak, absValue)
                    sumSquares += absValue * absValue
                    sampleCount += 1
                }
                if framePeak < thresholdAmplitude {
                    silentFrames += 1
                }
            }
        }

        guard sampleCount > 0, framesProcessed > 0 else {
            throw AnalysisError.zeroLengthFile
        }

        // Duration and silenceRatio are derived from frames ACTUALLY decoded, not the
        // header frame count. A truncated/short-data-chunk file (header claims more frames
        // than the data contains) otherwise reports overstated duration and understated
        // silenceRatio, letting a missing-audio export pass near-silence/duration checks.
        let duration = Double(framesProcessed) / sampleRate
        let rms = sqrt(sumSquares / Double(sampleCount))
        let rmsDbfs = amplitudeToDbfs(rms)
        let peakDbfs = amplitudeToDbfs(peak)
        let silenceRatio = min(max(Double(silentFrames) / Double(framesProcessed), 0.0), 1.0)
        let nonSilentDuration = duration * (1.0 - silenceRatio)
        let truncated = framesProcessed != frameCount

        return Result(
            schema: schema,
            path: url.path,
            exists: true,
            format: normalizedExtension(url.path),
            durationSeconds: rounded(duration),
            sampleRate: Int(sampleRate.rounded()),
            channelCount: channelCount,
            frameCount: framesProcessed,
            fileSizeBytes: fileSizeBytes,
            rmsDbfs: rounded(rmsDbfs),
            peakDbfs: rounded(peakDbfs),
            truePeakDbfs: nil,
            loudnessEstimateLufs: rounded(rmsDbfs),
            loudnessMethod: "rms_estimate",
            silenceRatio: rounded(silenceRatio),
            nonSilentDurationSeconds: rounded(nonSilentDuration),
            spectralCentroidHz: nil,
            frequencyPeaks: [],
            // Seed truncation as a verification reason so evaluate() can fail-close when
            // the decoder yielded fewer frames than the header declared.
            verification: Verification(status: .pass, reasons: truncated ? ["truncated_or_short_data"] : [])
        )
    }

    private static func evaluate(_ result: Result, policy: AnalysisPolicy) -> Verification {
        // Carry forward any measurement-time reasons (e.g. truncated_or_short_data) so a
        // truncated file cannot pass even when every policy check is satisfied.
        var reasons: [String] = result.verification.reasons

        if let minimumFileSizeBytes = policy.minimumFileSizeBytes,
           result.fileSizeBytes < Int64(minimumFileSizeBytes) {
            reasons.append("file_size_below_minimum")
        }
        if let minimumDurationSeconds = policy.minimumDurationSeconds,
           result.durationSeconds < minimumDurationSeconds {
            reasons.append("duration_below_minimum")
        }
        if let expectedDuration = policy.expectedDurationSeconds,
           let drift = policy.maximumDurationDriftSeconds,
           abs(result.durationSeconds - expectedDuration) > drift {
            reasons.append("duration_drift_exceeded")
        }
        if let maximumPeakDbfs = policy.maximumPeakDbfs,
           result.peakDbfs > maximumPeakDbfs {
            reasons.append("peak_above_threshold")
        }
        if result.peakDbfs <= policy.nearSilenceThresholdDbfs || result.silenceRatio >= policy.maximumSilenceRatio {
            reasons.append("near_silent_output")
        }
        if let expectedSampleRate = policy.expectedSampleRate,
           result.sampleRate != expectedSampleRate {
            reasons.append("sample_rate_mismatch")
        }
        if let expectedChannelCount = policy.expectedChannelCount,
           result.channelCount != expectedChannelCount {
            reasons.append("channel_count_mismatch")
        }

        return Verification(status: reasons.isEmpty ? .pass : .fail, reasons: reasons)
    }

    private static func failureResult(path: String, error: AnalysisError) -> Result {
        Result(
            schema: schema,
            path: path,
            exists: error.pathExists,
            format: normalizedExtension(path).isEmpty ? "unknown" : normalizedExtension(path),
            durationSeconds: 0,
            sampleRate: 0,
            channelCount: 0,
            frameCount: 0,
            fileSizeBytes: 0,
            rmsDbfs: -120.0,
            peakDbfs: -120.0,
            truePeakDbfs: nil,
            loudnessEstimateLufs: nil,
            loudnessMethod: "none",
            silenceRatio: 1.0,
            nonSilentDurationSeconds: 0,
            spectralCentroidHz: nil,
            frequencyPeaks: [],
            // reasons stays a uniform machine-code list (v1 schema contract); the human
            // sentence goes in the optional `detail` field so a client parsing reasons
            // never hits free text on the error path.
            verification: Verification(status: .fail, reasons: [error.code], detail: error.message)
        )
    }

    private static func pathContainsTraversal(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isICloudPath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        // Genuine iCloud placeholder stubs use the `<name>.icloud` extension; match by
        // extension, not an unanchored substring, so a legitimate local path that merely
        // contains the literal text ".icloud" in a directory component is not rejected.
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return lowercased.contains("/mobile documents/")
            || ext == "icloud"
            || lowercased.contains("/icloud drive/")
    }

    private static func normalizedExtension(_ path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    private static func amplitudeToDbfs(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return -120.0 }
        return max(20.0 * log10(amplitude), -120.0)
    }

    private static func dbfsToAmplitude(_ dbfs: Double) -> Double {
        pow(10.0, dbfs / 20.0)
    }

    private static func rounded(_ value: Double) -> Double {
        guard value.isFinite else { return -120.0 }
        return (value * 1000.0).rounded() / 1000.0
    }
}

private extension AudioAnalyzer.Result {
    func withVerification(_ verification: AudioAnalyzer.Verification) -> AudioAnalyzer.Result {
        AudioAnalyzer.Result(
            schema: schema,
            path: path,
            exists: exists,
            format: format,
            durationSeconds: durationSeconds,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            fileSizeBytes: fileSizeBytes,
            rmsDbfs: rmsDbfs,
            peakDbfs: peakDbfs,
            truePeakDbfs: truePeakDbfs,
            loudnessEstimateLufs: loudnessEstimateLufs,
            loudnessMethod: loudnessMethod,
            silenceRatio: silenceRatio,
            nonSilentDurationSeconds: nonSilentDurationSeconds,
            spectralCentroidHz: spectralCentroidHz,
            frequencyPeaks: frequencyPeaks,
            verification: verification
        )
    }
}
