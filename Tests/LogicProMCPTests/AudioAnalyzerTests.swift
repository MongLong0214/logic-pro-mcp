import AVFoundation
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private func writeAudioFixture(
    named name: String,
    sampleRate: Double = 44_100,
    durationSeconds: Double = 0.1,
    channels: AVAudioChannelCount = 2,
    sample: (Int) -> Float
) throws -> URL {
    try writeAudioFixture(
        named: name,
        sampleRate: sampleRate,
        durationSeconds: durationSeconds,
        channels: channels
    ) { _, frame in sample(frame) }
}

/// Per-channel variant so tests can write asymmetric channel content (e.g. a loud
/// left and a silent right) and prove cross-channel RMS/peak handling.
private func writeAudioFixture(
    named name: String,
    sampleRate: Double = 44_100,
    durationSeconds: Double = 0.1,
    channels: AVAudioChannelCount = 2,
    perChannelSample: (Int, Int) -> Float
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let channelData = buffer.floatChannelData!
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(frameCount) {
            channelData[channel][frame] = perChannelSample(channel, frame)
        }
    }
    try file.write(from: buffer)
    return url
}

/// Loose policy that disables silence/peak gating so DSP value tests inspect the
/// measured numbers without a verification failure masking them.
private func measureOnlyPolicy() -> AudioAnalyzer.AnalysisPolicy {
    var policy = AudioAnalyzer.AnalysisPolicy.default
    policy.nearSilenceThresholdDbfs = -120
    policy.maximumSilenceRatio = 1.0
    return policy
}

@Test func testAudioAnalyzerValidWAVSchemaAndMeasurements() throws {
    let url = try writeAudioFixture(named: "tone.wav") { frame in
        Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / 44_100.0) * 0.5)
    }

    let result = AudioAnalyzer.analyzeFile(
        path: url.path,
        policy: .init(
            minimumDurationSeconds: 0.05,
            maximumDurationDriftSeconds: nil,
            expectedDurationSeconds: nil,
            minimumFileSizeBytes: 128,
            maximumPeakDbfs: -0.1,
            nearSilenceThresholdDbfs: -60,
            maximumSilenceRatio: 0.98,
            expectedSampleRate: 44_100,
            expectedChannelCount: 2,
            outputRoot: url.deletingLastPathComponent().path
        )
    )

    #expect(result.schema == "logic_pro_mcp_audio_analysis.v1")
    #expect(result.exists)
    #expect(result.format == "wav")
    #expect(result.sampleRate == 44_100)
    #expect(result.channelCount == 2)
    #expect(result.durationSeconds >= 0.09)
    #expect(result.loudnessMethod == "rms_estimate")
    #expect(result.verification.status == .pass)

    // Pin the dBFS formula numerically. A 0.5-amplitude sine peaks at 20·log10(0.5) =
    // -6.0206 dBFS and its RMS is 0.5/√2 → -9.031 dBFS. `< 0` would pass for any
    // non-clipped signal and would not catch a wrong base/coefficient.
    #expect(abs(result.peakDbfs - (-6.0206)) < 0.1)
    #expect(abs(result.rmsDbfs - (-9.031)) < 0.15)

    // Honesty contract: LUFS/true-peak/spectral stay unmeasured (null/empty); the
    // loudness estimate is exactly the RMS dBFS value, not a real LUFS measurement.
    #expect(result.truePeakDbfs == nil)
    #expect(result.spectralCentroidHz == nil)
    #expect(result.frequencyPeaks.isEmpty)
    #expect(result.loudnessEstimateLufs == result.rmsDbfs)

    // The remaining Result fields are populated for a real bounce.
    #expect(result.frameCount > 0)
    #expect(result.fileSizeBytes > 0)
    #expect(result.nonSilentDurationSeconds > 0)
}

@Test func testAudioAnalyzerRejectsUnsafeAndUnsupportedPaths() throws {
    let relative = AudioAnalyzer.analyzeFile(path: "relative.wav")
    #expect(relative.verification.status == .fail)
    #expect(relative.verification.reasons.contains("unsafe_path"))

    let traversal = AudioAnalyzer.analyzeFile(path: "/tmp/../evil.wav")
    #expect(traversal.verification.status == .fail)
    #expect(traversal.verification.reasons.contains("unsafe_path"))

    let iCloud = AudioAnalyzer.analyzeFile(path: "/Users/test/Library/Mobile Documents/song.wav")
    #expect(iCloud.verification.status == .fail)
    #expect(iCloud.verification.reasons.contains("unsafe_path"))

    let txtURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-\(UUID().uuidString).txt")
    try Data("not audio".utf8).write(to: txtURL)
    let unsupported = AudioAnalyzer.analyzeFile(path: txtURL.path)
    #expect(unsupported.verification.status == .fail)
    #expect(unsupported.verification.reasons.contains("unsupported_format"))
}

@Test func testAudioAnalyzerPolicyFlagsSilenceClippingAndDuration() throws {
    let silent = try writeAudioFixture(named: "silent.wav") { _ in 0.0 }
    let silentResult = AudioAnalyzer.analyzeFile(path: silent.path)
    #expect(silentResult.verification.status == .fail)
    #expect(silentResult.verification.reasons.contains("near_silent_output"))

    let clipped = try writeAudioFixture(named: "clipped.wav") { _ in 1.0 }
    let clippedResult = AudioAnalyzer.analyzeFile(
        path: clipped.path,
        policy: .init(
            minimumDurationSeconds: 1.0,
            maximumDurationDriftSeconds: nil,
            expectedDurationSeconds: nil,
            minimumFileSizeBytes: nil,
            maximumPeakDbfs: -0.1,
            nearSilenceThresholdDbfs: -60,
            maximumSilenceRatio: 0.98,
            expectedSampleRate: nil,
            expectedChannelCount: nil,
            outputRoot: nil
        )
    )
    #expect(clippedResult.verification.status == .fail)
    #expect(clippedResult.verification.reasons.contains("peak_above_threshold"))
    #expect(clippedResult.verification.reasons.contains("duration_below_minimum"))

    let quiet = try writeAudioFixture(named: "quiet.wav") { _ in 0.01 }
    let quietResult = AudioAnalyzer.analyzeFile(
        path: quiet.path,
        policy: .init(
            minimumDurationSeconds: nil,
            maximumDurationDriftSeconds: nil,
            expectedDurationSeconds: nil,
            minimumFileSizeBytes: nil,
            maximumPeakDbfs: nil,
            nearSilenceThresholdDbfs: -30,
            maximumSilenceRatio: 0.98,
            expectedSampleRate: nil,
            expectedChannelCount: nil,
            outputRoot: nil
        )
    )
    #expect(quietResult.silenceRatio == 1.0)
    #expect(quietResult.verification.reasons.contains("near_silent_output"))
}

@Test func testAudioAnalyzerRejectsOutputRootEscapesAndZeroLength() throws {
    let outside = try writeAudioFixture(named: "outside.wav") { _ in 0.25 }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-approved-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let escaped = AudioAnalyzer.analyzeFile(
        path: outside.path,
        policy: .init(
            minimumDurationSeconds: nil,
            maximumDurationDriftSeconds: nil,
            expectedDurationSeconds: nil,
            minimumFileSizeBytes: nil,
            maximumPeakDbfs: nil,
            nearSilenceThresholdDbfs: -60,
            maximumSilenceRatio: 0.98,
            expectedSampleRate: nil,
            expectedChannelCount: nil,
            outputRoot: root.path
        )
    )
    #expect(escaped.verification.status == .fail)
    #expect(escaped.verification.reasons.contains("unsafe_path"))

    let zero = root.appendingPathComponent("zero.wav")
    FileManager.default.createFile(atPath: zero.path, contents: Data())
    let zeroResult = AudioAnalyzer.analyzeFile(path: zero.path)
    #expect(zeroResult.verification.status == .fail)
    #expect(zeroResult.verification.reasons.contains("zero_length_file"))
}

@Test func testAudioAnalyzerRejectsFilesystemRootOutputRoot() throws {
    let outside = try writeAudioFixture(named: "outside-root.wav") { _ in 0.25 }
    let result = AudioAnalyzer.analyzeFile(
        path: outside.path,
        policy: .init(
            minimumDurationSeconds: nil,
            maximumDurationDriftSeconds: nil,
            expectedDurationSeconds: nil,
            minimumFileSizeBytes: nil,
            maximumPeakDbfs: nil,
            nearSilenceThresholdDbfs: -60,
            maximumSilenceRatio: 0.98,
            expectedSampleRate: nil,
            expectedChannelCount: nil,
            outputRoot: "/"
        )
    )

    #expect(result.verification.status == .fail)
    #expect(result.verification.reasons.contains("unsafe_path"))
}

@Test func testAudioAnalyzerRejectsSymlinkSwappedOutputRoot() throws {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-root-swap-\(UUID().uuidString)", isDirectory: true)
    let trustedRoot = workspace.appendingPathComponent("trusted", isDirectory: true)
    let escapedRoot = workspace.appendingPathComponent("escaped", isDirectory: true)
    try FileManager.default.createDirectory(at: trustedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)

    let fixture = try writeAudioFixture(named: "swap-tone.wav") { _ in 0.25 }
    let escapedFile = escapedRoot.appendingPathComponent("swap-tone.wav")
    try FileManager.default.moveItem(at: fixture, to: escapedFile)

    try FileManager.default.removeItem(at: trustedRoot)
    try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: escapedRoot)

    let result = AudioAnalyzer.analyzeFile(
        path: trustedRoot.appendingPathComponent("swap-tone.wav").path,
        policy: .init(
            minimumDurationSeconds: nil,
            maximumDurationDriftSeconds: nil,
            expectedDurationSeconds: nil,
            minimumFileSizeBytes: nil,
            maximumPeakDbfs: nil,
            nearSilenceThresholdDbfs: -60,
            maximumSilenceRatio: 0.98,
            expectedSampleRate: nil,
            expectedChannelCount: nil,
            outputRoot: trustedRoot.path
        )
    )

    #expect(result.verification.status == .fail)
    #expect(result.verification.reasons.contains("unsafe_path"))
}

@Test func testAudioAnalyzerRejectsInputsAboveConfiguredWorkCaps() throws {
    let oversizedRuntime = AudioAnalyzer.Runtime(
        fileExists: { _, isDirectory in
            isDirectory?.pointee = false
            return true
        },
        attributesOfItem: { _ in
            [.size: NSNumber(value: 2_048)]
        },
        resolveSymlinks: { $0 }
    )
    var sizePolicy = measureOnlyPolicy()
    sizePolicy.maximumInputFileSizeBytes = 1_024

    let oversized = AudioAnalyzer.analyzeFile(
        path: "/tmp/oversized.wav",
        policy: sizePolicy,
        runtime: oversizedRuntime
    )
    #expect(oversized.exists)
    #expect(oversized.verification.status == .fail)
    #expect(oversized.verification.reasons == ["analysis_limit_exceeded"])
    #expect((oversized.verification.detail?.contains("exceeds maximum"))!)

    let tone = try writeAudioFixture(named: "too-long.wav", durationSeconds: 0.2) { _ in 0.2 }
    var durationPolicy = measureOnlyPolicy()
    durationPolicy.maximumInputDurationSeconds = 0.05
    let tooLong = AudioAnalyzer.analyzeFile(path: tone.path, policy: durationPolicy)
    #expect(tooLong.verification.status == .fail)
    #expect(tooLong.verification.reasons == ["analysis_limit_exceeded"])
    #expect((tooLong.verification.detail?.contains("duration"))!)
}

@Test func testAudioDispatcherAnalyzeFileReturnsJSONAndErrorsOnFailedVerification() throws {
    let silent = try writeAudioFixture(named: "dispatcher-silent.wav") { _ in 0.0 }
    let result = AudioDispatcher.handle(
        command: "analyze_file",
        params: ["path": .string(silent.path)]
    )
    #expect(try #require(result.isError))
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(json["schema"] as? String == "logic_pro_mcp_audio_analysis.v1")
    let verification = try #require(json["verification"] as? [String: Any])
    #expect(verification["status"] as? String == "fail")
}

// MARK: - DSP value tests (pin the dBFS math, multichannel averaging)

@Test func testAudioAnalyzerConstantAmplitudePinsDbfsFormula() throws {
    // A constant 0.5 signal has peak == RMS == 0.5, so both must be exactly
    // 20·log10(0.5) = -6.0206 dBFS. This pins the base/coefficient with no √2 or
    // discretization ambiguity — a 10·log10 or natural-log formula would fail.
    let flat = try writeAudioFixture(named: "flat.wav") { _ in 0.5 }
    let result = AudioAnalyzer.analyzeFile(path: flat.path, policy: measureOnlyPolicy())
    #expect(result.verification.status == .pass)
    #expect(abs(result.peakDbfs - (-6.0206)) < 0.05)
    #expect(abs(result.rmsDbfs - (-6.0206)) < 0.05)
}

@Test func testAudioAnalyzerReportsTrueOverUnityPeakAboveZeroDbfs() throws {
    // Float PCM from a bounce can exceed full scale (digital overs). Peak must NOT be
    // clamped to 1.0 — a 1.5 sample is 20·log10(1.5) = +3.52 dBFS, and the
    // max_peak_dbfs gate must still flag it even with maximumPeakDbfs: 0.0.
    let hot = try writeAudioFixture(named: "over.wav") { _ in 1.5 }
    var policy = measureOnlyPolicy()
    policy.maximumPeakDbfs = 0.0
    let result = AudioAnalyzer.analyzeFile(path: hot.path, policy: policy)
    #expect(result.peakDbfs > 0)
    #expect(abs(result.peakDbfs - 3.5218) < 0.1)
    #expect(result.verification.status == .fail)
    #expect(result.verification.reasons.contains("peak_above_threshold"))
}

@Test func testAudioAnalyzerMonoRmsMatchesConstant() throws {
    let mono = try writeAudioFixture(named: "mono.wav", channels: 1) { _ in 0.5 }
    let result = AudioAnalyzer.analyzeFile(path: mono.path, policy: measureOnlyPolicy())
    #expect(result.channelCount == 1)
    #expect(abs(result.peakDbfs - (-6.0206)) < 0.05)
    #expect(abs(result.rmsDbfs - (-6.0206)) < 0.05)
}

@Test func testAudioAnalyzerAsymmetricChannelsAverageRmsAcrossChannels() throws {
    // Left = 0.5 constant, Right = silent. Per-frame peak across channels = 0.5 ->
    // -6.0206 dBFS. RMS sums squares over BOTH channels (0.25 + 0) / 2 samples =
    // 0.125 -> sqrt = 0.35355 -> -9.031 dBFS. A bug that only read channel 0 (or
    // double-counted) would not produce -9.031, so this proves cross-channel averaging.
    let asym = try writeAudioFixture(named: "asym.wav", channels: 2) { channel, _ in
        channel == 0 ? 0.5 : 0.0
    }
    let result = AudioAnalyzer.analyzeFile(path: asym.path, policy: measureOnlyPolicy())
    #expect(result.channelCount == 2)
    #expect(abs(result.peakDbfs - (-6.0206)) < 0.05)
    #expect(abs(result.rmsDbfs - (-9.031)) < 0.05)
}

// MARK: - Verification / failure reason coverage

@Test func testAudioAnalyzerVerificationReasonCodes() throws {
    let tone = try writeAudioFixture(named: "reasons-tone.wav") { frame in
        Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / 44_100.0) * 0.5)
    }

    var sampleRatePolicy = AudioAnalyzer.AnalysisPolicy.default
    sampleRatePolicy.expectedSampleRate = 48_000
    let sampleRateResult = AudioAnalyzer.analyzeFile(path: tone.path, policy: sampleRatePolicy)
    #expect(sampleRateResult.verification.reasons.contains("sample_rate_mismatch"))

    var channelPolicy = AudioAnalyzer.AnalysisPolicy.default
    channelPolicy.expectedChannelCount = 1
    let channelResult = AudioAnalyzer.analyzeFile(path: tone.path, policy: channelPolicy)
    #expect(channelResult.verification.reasons.contains("channel_count_mismatch"))

    var driftPolicy = AudioAnalyzer.AnalysisPolicy.default
    driftPolicy.expectedDurationSeconds = 10
    driftPolicy.maximumDurationDriftSeconds = 0.001
    let driftResult = AudioAnalyzer.analyzeFile(path: tone.path, policy: driftPolicy)
    #expect(driftResult.verification.reasons.contains("duration_drift_exceeded"))

    var sizePolicy = AudioAnalyzer.AnalysisPolicy.default
    sizePolicy.minimumFileSizeBytes = Int.max
    let sizeResult = AudioAnalyzer.analyzeFile(path: tone.path, policy: sizePolicy)
    #expect(sizeResult.verification.reasons.contains("file_size_below_minimum"))
}

@Test func testAudioAnalyzerErrorReasonCodes() throws {
    let missing = AudioAnalyzer.analyzeFile(path: "/private/var/nonexistent-\(UUID().uuidString).wav")
    #expect(missing.verification.status == .fail)
    #expect(missing.verification.reasons.contains("missing_file"))

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-dir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dirResult = AudioAnalyzer.analyzeFile(path: dir.path)
    #expect(dirResult.verification.status == .fail)
    #expect(dirResult.verification.reasons.contains("directory_path"))

    // Garbage bytes under a supported extension: AVAudioFile fails to open -> decoder_error.
    let garbageDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-garbage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: garbageDir, withIntermediateDirectories: true)
    let garbage = garbageDir.appendingPathComponent("corrupt.wav")
    try Data("this is not a real RIFF/WAVE payload at all".utf8).write(to: garbage)
    let garbageResult = AudioAnalyzer.analyzeFile(path: garbage.path)
    #expect(garbageResult.verification.status == .fail)
    #expect(garbageResult.verification.reasons.contains("decoder_error"))
}

@Test func testAudioAnalyzerReasonsAreCodeOnlyWithDetailOnErrorPath() throws {
    // The error path must emit a uniform machine-code list and carry the human sentence
    // in `detail`, not mix free text into reasons (v1 schema is a parseable contract).
    let txtURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-codeonly-\(UUID().uuidString).txt")
    try Data("not audio".utf8).write(to: txtURL)
    let unsupported = AudioAnalyzer.analyzeFile(path: txtURL.path)
    #expect(unsupported.verification.reasons == ["unsupported_format"])
    let detail = try #require(unsupported.verification.detail)
    #expect(detail.contains("Unsupported audio format"))
}

// MARK: - exists honesty per error kind

@Test func testAudioAnalyzerExistsHonestForPresentButUnanalyzableFiles() throws {
    // An existing unsupported file is present on disk: exists must be true even though
    // verification fails, so an agent does not wrongly conclude "no file produced".
    let txtURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-exists-\(UUID().uuidString).txt")
    try Data("not audio".utf8).write(to: txtURL)
    let unsupported = AudioAnalyzer.analyzeFile(path: txtURL.path)
    #expect(unsupported.exists)
    #expect(unsupported.verification.status == .fail)

    // Existing zero-length file: present, but fails.
    let zeroDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-zero-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: zeroDir, withIntermediateDirectories: true)
    let zero = zeroDir.appendingPathComponent("zero.wav")
    FileManager.default.createFile(atPath: zero.path, contents: Data())
    let zeroResult = AudioAnalyzer.analyzeFile(path: zero.path)
    #expect(zeroResult.exists)
    #expect(zeroResult.verification.status == .fail)

    // A directory input is present on disk (an item exists at that path), so exists is
    // true even though it is not an analyzable audio file.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-existsdir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dirResult = AudioAnalyzer.analyzeFile(path: dir.path)
    #expect(dirResult.exists)
    #expect(dirResult.verification.reasons.contains("directory_path"))

    // A genuinely missing path: exists false.
    let missing = AudioAnalyzer.analyzeFile(path: "/private/var/nonexistent-\(UUID().uuidString).wav")
    #expect(!missing.exists)

    // An unsafe (relative) path is rejected before any presence check: exists false.
    let unsafe = AudioAnalyzer.analyzeFile(path: "relative.wav")
    #expect(!unsafe.exists)
}

// MARK: - iCloud path matching (extension, not substring)

@Test func testAudioAnalyzerICloudMatchByExtensionNotSubstring() throws {
    // A legitimate local path that merely contains the text ".icloud" in a directory
    // component must NOT be rejected as unsafe — it should fall through to missing_file.
    let local = AudioAnalyzer.analyzeFile(path: "/Users/x/Music/my.icloud.backup/song.wav")
    #expect(local.verification.reasons.contains("missing_file"))
    #expect(!local.verification.reasons.contains("unsafe_path"))

    // A genuine `<name>.icloud` placeholder stub is still rejected as unsafe.
    let stub = AudioAnalyzer.analyzeFile(path: "/Users/x/Music/song.wav.icloud")
    #expect(stub.verification.status == .fail)
    #expect(stub.verification.reasons.contains("unsafe_path"))
}

// MARK: - format-field / case normalization / non-wav supported extension

@Test func testAudioAnalyzerAcceptsAiffAndNormalizesUppercaseExtension() throws {
    let aiff = try writeAudioFixture(named: "tone.aiff") { _ in 0.5 }
    let aiffResult = AudioAnalyzer.analyzeFile(path: aiff.path, policy: measureOnlyPolicy())
    #expect(aiffResult.verification.status == .pass)
    #expect(aiffResult.format == "aiff")

    let upper = try writeAudioFixture(named: "Tone.WAV") { _ in 0.5 }
    let upperResult = AudioAnalyzer.analyzeFile(path: upper.path, policy: measureOnlyPolicy())
    #expect(upperResult.format == "wav")
}

// MARK: - decode-path zero-frame guard (valid container, no PCM)

@Test func testAudioAnalyzerZeroFrameDecodableFileTripsDecodeGuard() throws {
    // A non-empty WAV with zero audio frames passes the byte-size guard but must fail at
    // the decode-frame guard (file.length == 0), exercising a path the 0-byte test cannot.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-audio-emptyframes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("empty-frames.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
    buffer.frameLength = 0
    try file.write(from: buffer)

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    #expect(size > 0)

    let result = AudioAnalyzer.analyzeFile(path: url.path)
    #expect(result.verification.status == .fail)
    #expect(result.verification.reasons.contains("zero_length_file"))
}

// MARK: - Dispatcher branch coverage

@Test func testAudioDispatcherEmptyPathReturnsError() throws {
    let result = AudioDispatcher.handle(command: "analyze_file", params: ["path": .string("")])
    #expect(try #require(result.isError))
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(json["verification"] != nil)
}

@Test func testAudioDispatcherUnknownCommandReturnsError() throws {
    let result = AudioDispatcher.handle(command: "bogus", params: [:])
    #expect(try #require(result.isError))
    #expect(sharedToolText(result).contains("Unknown audio command"))
}

@Test func testAudioDispatcherSuccessPathOnLoudTone() throws {
    let tone = try writeAudioFixture(named: "dispatcher-loud.wav") { frame in
        Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / 44_100.0) * 0.7)
    }
    let result = AudioDispatcher.handle(
        command: "analyze_file",
        params: ["path": .string(tone.path)]
    )
    #expect(!(try #require(result.isError)))
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    let verification = try #require(json["verification"] as? [String: Any])
    #expect(verification["status"] as? String == "pass")
}

@Test func testAudioDispatcherAliasParamsAreParsed() throws {
    let tone = try writeAudioFixture(named: "dispatcher-alias.wav") { frame in
        Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / 44_100.0) * 0.5)
    }
    // Drive the canonical alias keys: max_peak_dbfs (so the loud tone trips the peak gate)
    // and expected_sample_rate (so the 44_100 fixture trips the rate gate). If either alias
    // key were broken the corresponding reason would be absent.
    let result = AudioDispatcher.handle(
        command: "analyze_file",
        params: [
            "path": .string(tone.path),
            "max_peak_dbfs": .double(-30.0),
            "expected_sample_rate": .int(48_000),
        ]
    )
    #expect(try #require(result.isError))
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    let verification = try #require(json["verification"] as? [String: Any])
    let reasons = try #require(verification["reasons"] as? [String])
    #expect(reasons.contains("peak_above_threshold"))
    #expect(reasons.contains("sample_rate_mismatch"))
}

@Test func testAudioDispatcherOutputRootNonStringFailsClosed() throws {
    let tone = try writeAudioFixture(named: "dispatcher-confined.wav") { _ in 0.5 }

    // A present-but-non-string output_root must fail CLOSED as unsafe_path, never silently
    // drop the allowlist confinement.
    for malformed in [Value.int(123), Value.bool(true), Value.string("   ")] {
        let result = AudioDispatcher.handle(
            command: "analyze_file",
            params: ["path": .string(tone.path), "output_root": malformed]
        )
        #expect(try #require(result.isError))
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        let verification = try #require(json["verification"] as? [String: Any])
        let reasons = try #require(verification["reasons"] as? [String])
        #expect(reasons.contains("unsafe_path"))
    }
}

@Test func testAudioDispatcherClampsPositiveNearSilenceThreshold() throws {
    // near_silence_dbfs > 0 must be clamped to 0.0 so a full-scale tone is not falsely
    // flagged near-silent (positive dBFS would push the threshold above full scale).
    let full = try writeAudioFixture(named: "dispatcher-fullscale.wav") { _ in 1.0 }
    let result = AudioDispatcher.handle(
        command: "analyze_file",
        params: ["path": .string(full.path), "near_silence_dbfs": .double(6.0)]
    )
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    let silenceRatio = try #require(json["silence_ratio"] as? Double)
    #expect(silenceRatio < 1.0)
    let verification = try #require(json["verification"] as? [String: Any])
    let reasons = try #require(verification["reasons"] as? [String])
    #expect(!reasons.contains("near_silent_output"))
}
