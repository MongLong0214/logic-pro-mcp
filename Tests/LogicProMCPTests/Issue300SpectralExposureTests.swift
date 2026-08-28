import AVFoundation
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#300 ADR-012 spectral command exposure")
struct Issue300SpectralExposureTests {
    @Test("the spectral commands are exposed, and setting the retired flag off does not hide them")
    func spectralCommandsAreExposed() async throws {
        // The inverse of what this case used to assert. It pinned the gate as the contract: with
        // `LOGIC_MCP_ADR012_SPECTRAL_EQ` unset the commands answered `command_not_exposed`.
        //
        // Promoted 2026-08-28, and the flag is gone rather than defaulted on — a flag nothing reads
        // is a trap for whoever sets it next. Setting the environment variable to `0` is the
        // strongest available check that it was removed rather than merely flipped: if the guard
        // were still there and only its default had changed, this would refuse.
        setenv("LOGIC_MCP_ADR012_SPECTRAL_EQ", "0", 1)
        defer { unsetenv("LOGIC_MCP_ADR012_SPECTRAL_EQ") }

        for command in ["analyze_spectrum", "recommend_eq"] {
            let result = AudioDispatcher.handle(
                command: command,
                params: ["path": .string("/tmp/issue300.wav")]
            )
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String != "command_not_exposed",
                    "\(command) is still gated")
            #expect(body["not_exposed"] == nil)
        }
    }

    @Test("flag on refuses an empty path before spectral analysis")
    func emptyPathIsRefusedBeforeAnalysis() throws {
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

    @Test("flag on returns typed failures for a nonexistent input")
    func nonexistentPathReturnsTypedFailure() throws {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue300-missing-\(UUID().uuidString).wav").path

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

    @Test("recommend_eq returns a band for a temporary resonant WAV")
    func recommendEQReturnsBandForPureToneWAV() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue300-spectrum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("resonance.wav")
        try writePureToneWAV(at: fileURL, frequency: 5_001.953_125)

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
