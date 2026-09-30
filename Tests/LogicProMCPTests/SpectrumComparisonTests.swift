import Foundation
import AVFoundation
import CryptoKit
import MCP
import Testing
@testable import LogicProMCP

@Suite("Artifact spectrum comparison")
struct SpectrumComparisonTests {
    @Test func comparisonIsReachableThroughTheAudioRegistry() {
        #expect(OperationRegistry.commands(for: .logicAudio).contains("compare_spectra"))
    }

    @Test func anUnmeasuredBandDoesNotBecomeAZeroDifference() {
        func analysis(_ measured: Bool) -> SpectralAnalysisResult {
            SpectralAnalysisResult(
                analysisRef: "fixture", bands: [SpectralBand(centerHz: 20, energyDb: -80, measured: measured)],
                resonances: [], classification: .unknown, levelConfidence: 0,
                complete: true, partialReason: nil
            )
        }
        #expect(compareSpectra(analysis(false), analysis(true)).isEmpty)
        #expect(compareSpectra(analysis(true), analysis(false)).isEmpty)
    }

    @Test func identicalArtifactsHaveBoundHashesAndOnlyMeasuredDeltas() throws {
        try withDirectory { directory in
            let path = try writeTone(directory, "same", amplitude: 0.4)
            let original = try Data(contentsOf: path)
            let comparison = try dispatchedComparison(path, path)
            let expected = "sha256:" + SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            #expect(comparison.before.artifactFingerprint == expected)
            #expect(comparison.after.artifactFingerprint == expected)
            #expect(comparison.before.analysisPolicy == comparison.after.analysisPolicy)
            #expect(comparison.bands.contains { $0.unavailableReason == "unmeasured_band" })
            #expect(!comparison.complete)
            let measured = comparison.bands.compactMap(\.deltaDb)
            #expect(!measured.isEmpty)
            #expect(measured.allSatisfy { abs($0) < 1e-9 })
            #expect(try Data(contentsOf: path) == original)
        }
    }

    @Test func gainAndChangedToneProduceSignedRawDifferences() throws {
        try withDirectory { directory in
            let before = try writeTone(directory, "before", amplitude: 0.2)
            let louder = try writeTone(directory, "louder", amplitude: 0.4)
            let shifted = try writeTone(directory, "shifted", amplitude: 0.2, frequency: 5_001.953125)
            let gain = try dispatchedComparison(before, louder)
            let band = try #require(gain.bands.min { abs($0.centerHz - 1_000) < abs($1.centerHz - 1_000) })
            let delta = try #require(band.deltaDb)
            #expect(abs(delta - 20 * log10(2.0)) < 0.1)
            #expect(gain.before.artifactFingerprint != gain.after.artifactFingerprint)
            let change = try dispatchedComparison(before, shifted)
            // Background energy is censored at the floor; strong tone bands either show
            // a signed difference or explicitly explain why one side cannot be measured.
            let low = try #require(change.bands.min { abs($0.centerHz - 1_000) < abs($1.centerHz - 1_000) })
            if let difference = low.deltaDb { #expect(difference < -20) }
            else { #expect(low.unavailableReason == "at_analysis_floor") }
            let high = try #require(change.bands.min { abs($0.centerHz - 5_000) < abs($1.centerHz - 5_000) })
            if let difference = high.deltaDb { #expect(difference > 20) }
            else { #expect(high.unavailableReason == "at_analysis_floor") }
        }
    }

    @Test func silenceIsCensoredAndStereoEnergyDoesNotCancel() throws {
        try withDirectory { directory in
            let silence = try writeTone(directory, "silence", amplitude: 0)
            let silent = try dispatchedComparison(silence, silence)
            #expect(silent.bands.allSatisfy { $0.deltaDb == nil })
            #expect(silent.bands.contains { $0.unavailableReason == "at_analysis_floor" })
            let stereo = try writeTone(directory, "stereo", amplitude: 0.4, channels: 2)
            let doubled = try writeTone(directory, "doubled", amplitude: 0.8, channels: 2)
            let result = try dispatchedComparison(stereo, doubled)
            #expect(result.before.channelMode == .stereoEnergyAverage)
            let band = try #require(result.bands.min { abs($0.centerHz - 1_000) < abs($1.centerHz - 1_000) })
            #expect(abs(try #require(band.deltaDb) - 20 * log10(2.0)) < 0.1)
        }
    }

    @Test func unequalDurationIsExplicitAndIncompatibleFormatsAreRefused() throws {
        try withDirectory { directory in
            let before = try writeTone(directory, "before", amplitude: 0.4)
            let longer = try writeTone(directory, "longer", amplitude: 0.4, frames: 24_000)
            #expect(try dispatchedComparison(before, longer).limitations.contains("unequal_temporal_coverage"))
            let stereo = try writeTone(directory, "stereo", amplitude: 0.4, channels: 2)
            let rate = try writeTone(directory, "rate", amplitude: 0.4, sampleRate: 44_100)
            for after in [stereo, rate] {
                try expectRefusal(before, after, code: "incompatible_analysis")
            }
        }
    }

    @Test func partialMalformedAndUnsafeInputsAreRefusedWithoutWrites() throws {
        try withDirectory { directory in
            let valid = try writeTone(directory, "valid", amplitude: 0.4)
            let short = try writeTone(directory, "short", amplitude: 0.4, frames: 100)
            try expectRefusal(valid, short, code: "incomplete_input")
            let malformed = directory.appendingPathComponent("malformed.wav")
            try Data("not audio".utf8).write(to: malformed)
            try expectRefusal(valid, malformed, code: "decode")
            try expectRefusal(valid, directory.appendingPathComponent("absent.wav"), code: "missing_file")
            try expectRefusal(valid, URL(fileURLWithPath: "relative.wav"),
                              params: ["after_path": .string("relative.wav")], code: "unsafe_path")
            try expectRefusal(valid, valid, params: ["output_root": .int(1)], code: "unsafe_path")
            let outsideRoot = directory.appendingPathComponent("restricted", isDirectory: true)
            try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
            try expectRefusal(valid, valid, params: ["output_root": .string(outsideRoot.path)], code: "unsafe_path")
            let fifo = directory.appendingPathComponent("pipe.wav")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            try expectRefusal(valid, fifo, code: "special_file")
        }
    }

    @Test func changedHeldFileCannotPublishItsOldFingerprint() throws {
        try withDirectory { directory in
            let path = try writeTone(directory, "changing", amplitude: 0.4)
            let probe = AudioFeatureExtractionEngine.IdentityProbe { path in
                // This callback runs after the descriptor has been hashed and decoder opened.
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0]))
                try handle.close()
                return try AudioFeatureExtractionEngine.IdentityProbe.production.statIdentity(path)
            }
            #expect(throws: AudioFeatureExtractionEngine.FeatureExtractionError.contentChanged) {
                try AudioFeatureExtractionEngine.analyzeFile(
                    path: path.path, analysisRef: "changing", artifactFingerprint: "caller label",
                    identityProbe: probe, computeArtifactFingerprint: true
                )
            }
        }
    }

    @Test func parentSymlinkSubstitutionAfterValidationCannotEscapeOutputRoot() throws {
        try withDirectory { directory in
            let approved = directory.appendingPathComponent("approved")
            let parent = approved.appendingPathComponent("sub")
            let outside = directory.appendingPathComponent("outside")
            let original = directory.appendingPathComponent("original")
            for folder in [parent, outside] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let inside = try writeTone(parent, "tone", amplitude: 0.2)
            let after = try writeTone(approved, "after", amplitude: 0.4)
            _ = try writeTone(outside, "tone", amplitude: 0.8)
            let production = AudioAnalyzer.Runtime.production
            let runtime = AudioAnalyzer.Runtime(
                fileExists: { path, isDirectory in
                    let exists = production.fileExists(path, isDirectory)
                    if path == inside.path, !FileManager.default.fileExists(atPath: original.path) {
                        do {
                            // The validator already resolved inside the root; replace a parent
                            // before the descriptor open, which must not follow this link.
                            try FileManager.default.moveItem(at: parent, to: original)
                            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
                        } catch { return false }
                    }
                    return exists
                },
                attributesOfItem: production.attributesOfItem,
                resolveSymlinks: production.resolveSymlinks
            )
            let result = AudioDispatcher.handle(command: "compare_spectra", params: [
                "before_path": .string(inside.path), "after_path": .string(after.path),
                "output_root": .string(approved.path)
            ], runtime: runtime)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(try #require(result.isError))
            #expect(body["analysis_error"] as? String == "path_identity_changed")
            #expect(!body.keys.contains("before"))
            #expect(!body.keys.contains("after"))
            #expect(!body.keys.contains("bands"))
        }
    }

    @Test func tiltedAndClippedFixturesDoNotBecomeQualityJudgments() throws {
        try withDirectory { directory in
            let before = try writeTone(directory, "balanced", amplitude: 0.2, highAmplitude: 0.2)
            let tilted = try writeTone(directory, "tilted", amplitude: 0.4, highAmplitude: 0.1)
            let result = try dispatchedComparison(before, tilted)
            let low = try #require(result.bands.min { abs($0.centerHz - 1_000) < abs($1.centerHz - 1_000) })
            let high = try #require(result.bands.min { abs($0.centerHz - 5_000) < abs($1.centerHz - 5_000) })
            #expect(abs(try #require(low.deltaDb) - 20 * log10(2.0)) < 0.2)
            #expect(abs(try #require(high.deltaDb) + 20 * log10(2.0)) < 0.2)
            let clipped = try writeTone(directory, "clipped", amplitude: 2, clip: true)
            let comparison = try dispatchedComparison(before, clipped)
            #expect(comparison.limitations.contains("no_musical_quality_or_applied_eq_claim"))
            #expect(!comparison.bands.compactMap(\.deltaDb).isEmpty)
            let body = try #require(sharedJSONObject(String(decoding: JSONEncoder().encode(comparison), as: UTF8.self)))
            #expect(!body.keys.contains("improved"))
            #expect(!body.keys.contains("applied"))
        }
    }

    @Test func truncatedFileAndComputeCapsCannotYieldAFullComparison() throws {
        try withDirectory { directory in
            let valid = try writeTone(directory, "valid", amplitude: 0.4)
            let truncated = directory.appendingPathComponent("truncated.wav")
            try Data(Data(contentsOf: valid).prefix(100)).write(to: truncated)
            let result = AudioDispatcher.handle(command: "compare_spectra", params: [
                "before_path": .string(valid.path), "after_path": .string(truncated.path)
            ])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(try #require(result.isError))
            let code = try #require(body["analysis_error"] as? String)
            #expect(["decode", "incomplete_input"].contains(code))
            var policy = AudioAnalyzer.AnalysisPolicy.default
            policy.maximumInputFileSizeBytes = 100
            let capped = try AudioFeatureExtractionEngine.analyzeFile(
                path: valid.path, analysisRef: "capped", artifactFingerprint: "", policy: policy,
                computeArtifactFingerprint: true
            )
            #expect(!capped.complete)
            #expect(capped.bands.isEmpty)
            #expect(capped.partialReason == "input_too_large")
            #expect(throws: SpectralComparisonResult.Failure.incompleteInput) {
                try SpectralComparisonResult(before: capped, after: capped)
            }
        }
    }

    @Test func legacyPolicyChangedPolicyAndDuplicateGridCannotBecomeCompatible() throws {
        func analysis(config: AudioFeatureExtractionEngine.Config = .default, dc: Bool = true) -> SpectralAnalysisResult {
            AudioFeatureExtractionEngine.analyze(
                channels: [[Double](repeating: 0.1, count: 16_384)], sampleRate: 48_000,
                analysisRef: "fixture", artifactFingerprint: "sha256:" + String(repeating: "a", count: 64),
                config: config, removeDC: dc
            )
        }
        let normal = analysis()
        var config = AudioFeatureExtractionEngine.Config.default
        config.floorDbfs = -70
        for incompatible in [analysis(config: config), analysis(dc: false)] {
            #expect(throws: SpectralComparisonResult.Failure.incompatibleAnalysis) {
                try SpectralComparisonResult(before: normal, after: incompatible)
            }
        }
        var json = try #require(sharedJSONObject(String(decoding: JSONEncoder().encode(normal), as: UTF8.self)))
        json.removeValue(forKey: "analysisPolicy")
        let legacy = try JSONDecoder().decode(SpectralAnalysisResult.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.analysisPolicy == nil)
        #expect(throws: SpectralComparisonResult.Failure.incompatibleAnalysis) {
            try SpectralComparisonResult(before: normal, after: legacy)
        }
        json = try #require(sharedJSONObject(String(decoding: JSONEncoder().encode(normal), as: UTF8.self)))
        let first = try #require((json["bands"] as? [[String: Any]])?.first)
        json["bands"] = [first, first]
        let duplicates = try JSONDecoder().decode(SpectralAnalysisResult.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: SpectralComparisonResult.Failure.invalidBands) {
            try SpectralComparisonResult(before: duplicates, after: duplicates)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("spectrum-comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writeTone(_ directory: URL, _ name: String, amplitude: Double,
                           frequency: Double = 1_001.953125, sampleRate: Double = 48_000,
                           channels: UInt32 = 1, frames: Int = 16_384,
                           highAmplitude: Double = 0, clip: Bool = false) throws -> URL {
        let path = directory.appendingPathComponent(name + ".wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let file = try AVAudioFile(forWriting: path, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                let phase = 2 * Double.pi * Double(frame) / sampleRate
                var value = amplitude * cos(phase * frequency) + highAmplitude * cos(phase * 5_001.953125)
                if clip { value = min(1, max(-1, value)) }
                samples[channel][frame] = Float(value * (channel % 2 == 0 ? 1 : -1))
            }
        }
        try file.write(from: buffer)
        return path
    }

    private func dispatchedComparison(_ before: URL, _ after: URL) throws -> SpectralComparisonResult {
        let result = AudioDispatcher.handle(command: "compare_spectra", params: [
            "before_path": .string(before.path), "after_path": .string(after.path)
        ])
        return try JSONDecoder().decode(SpectralComparisonResult.self, from: Data(sharedToolText(result).utf8))
    }

    private func expectRefusal(_ before: URL, _ after: URL, params: [String: Value] = [:], code: String) throws {
        var inputs: [String: Value] = ["before_path": .string(before.path), "after_path": .string(after.path)]
        inputs.merge(params, uniquingKeysWith: { _, new in new })
        let result = AudioDispatcher.handle(command: "compare_spectra", params: inputs)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let isError = try #require(result.isError)
        #expect(isError)
        #expect(body["analysis_error"] as? String == code)
        let writes = try #require(body["write_attempted"] as? Bool)
        #expect(!writes)
    }
}
