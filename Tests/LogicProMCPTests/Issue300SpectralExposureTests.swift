import AVFoundation
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#300 ADR-012 spectral command exposure")
struct Issue300SpectralExposureTests {
    @Test("flag off refuses both registered spectral commands with the not-exposed envelope")
    func flagOffRefusesSpectralCommands() async throws {
        try await FeatureFlags.withAdr012SpectralEQForTests(false) {
            for command in ["analyze_spectrum", "recommend_eq"] {
                let result = AudioDispatcher.handle(
                    command: command,
                    params: ["path": .string("/tmp/issue300.wav")]
                )
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                let isError = try #require(result.isError)
                #expect(isError)
                #expect(body["state"] as? String == "C")
                #expect(body["error"] as? String == "command_not_exposed")
                let notExposed = try #require(body["not_exposed"] as? Bool)
                #expect(notExposed)
                let supported = try #require(body["supported"] as? Bool)
                #expect(!supported)
                #expect(body["operation"] as? String == "audio.\(command)")
                #expect(body["write_attempted"] == nil)
            }
        }
    }

    @Test("flag on refuses an empty path before spectral analysis")
    func emptyPathIsRefusedBeforeAnalysis() async throws {
        try await FeatureFlags.withAdr012SpectralEQForTests(true) {
            for command in ["analyze_spectrum", "recommend_eq"] {
                let result = AudioDispatcher.handle(command: command, params: ["path": .string(" ")])
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                let isError = try #require(result.isError)
                #expect(isError)
                #expect(body["state"] as? String == "C")
                #expect(body["error"] as? String == "invalid_params")
                #expect(body["analysis_error"] == nil)
                let writeAttempted = try #require(body["write_attempted"] as? Bool)
                #expect(!writeAttempted)
            }
        }
    }

    @Test("flag on returns typed failures for a nonexistent input")
    func nonexistentPathReturnsTypedFailure() async throws {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue300-missing-\(UUID().uuidString).wav").path

        try await FeatureFlags.withAdr012SpectralEQForTests(true) {
            for command in ["analyze_spectrum", "recommend_eq"] {
                let result = AudioDispatcher.handle(command: command, params: ["path": .string(nonexistent)])
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                let isError = try #require(result.isError)
                #expect(isError)
                #expect(body["state"] as? String == "C")
                #expect(body["error"] as? String == "spectral_analysis_failed")
                #expect(body["analysis_error"] as? String == "missing_file")
                let success = try #require(body["success"] as? Bool)
                #expect(!success)
            }
        }
    }

    @Test("recommend_eq returns a band for a temporary resonant WAV")
    func recommendEQReturnsBandForPureToneWAV() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue300-spectrum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("resonance.wav")
        try writePureToneWAV(at: fileURL, frequency: 5_001.953_125)

        try await FeatureFlags.withAdr012SpectralEQForTests(true) {
            let result = AudioDispatcher.handle(command: "recommend_eq", params: ["path": .string(fileURL.path)])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let isError = try #require(result.isError)
            #expect(!isError)
            let bands = try #require(body["bands"] as? [[String: Any]])
            #expect(!bands.isEmpty)
            let firstBand = try #require(bands.first)
            let centerHz = try #require(firstBand["centerHz"] as? Double)
            #expect(centerHz > 0)
            #expect(firstBand["reason"] as? String == "resonance_cut")
        }
    }

    private func writePureToneWAV(at url: URL, frequency: Double) throws {
        let sampleRate = 48_000.0
        let frameCount = 48_000
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<frameCount {
            samples[frame] = Float(cos(2.0 * Double.pi * frequency * Double(frame) / sampleRate))
        }
        try file.write(from: buffer)
    }
}
