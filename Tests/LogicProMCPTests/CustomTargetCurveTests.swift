import AVFoundation
import CryptoKit
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Explicit spectral target curves")
struct CustomTargetCurveTests {
    @Test func registryAllowsTheCurveButNotForeignParameters() async throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_audio", command: "analyze_spectrum"))
        #expect(spec.allowedParams.contains("target_curve"))
        let result = await FeatureFlags.withAdr003StrictParamsForTests(true) {
            LogicProServer.strictParamValidationResult(tool: "logic_audio", command: "analyze_spectrum", params: [
                "path": .string("/tmp/curve-test.wav"), "target_curve": .array([point(20, -40), point(20_000, -10)]),
            ])
        }
        #expect(result == nil)
        let foreign = await FeatureFlags.withAdr003StrictParamsForTests(true) {
            LogicProServer.strictParamValidationResult(tool: "logic_audio", command: "analyze_spectrum", params: [
                "path": .string("/tmp/curve-test.wav"), "target_curv": .array([]),
            ])
        }
        #expect(foreign != nil)
    }

    @Test func theCurveBudgetIsBoundedByTheAnalysisGrid() throws {
        let maximum = AudioFeatureExtractionEngine.makeGrid().centers.count
        let points = (0...maximum).map { index in
            point(20 + 19_980 * Double(index) / Double(maximum), -40)
        }
        let result = AudioDispatcher.handle(command: "analyze_spectrum", params: [
            "path": .string("/tmp/curve-deliberately-absent.wav"), "target_curve": .array(points),
        ])
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "invalid_params")
        #expect(sharedToolText(result).contains("target_curve"))
    }

    @Test func malformedCurvesAreRefusedBeforeTryingAnArtifact() throws {
        let valid = point(20, -40)
        let invalid: [Value] = [
            .null, .int(1), .object([:]), .array([]), .array([valid]),
            .array([valid, valid]), .array([point(2_000, -40), point(20, -40)]),
            .array([point(0, -40), point(20_000, -10)]),
            .array([point(20, -81), point(20_000, -10)]),
            .array([point(20, -40), point(20_000, 1)]),
            .array([point(20, -40), point(20_001, -10)]),
            .array([valid, .object(["center_hz": .bool(true), "energy_dbfs": .double(-10)])]),
            .array([valid, .object(["center_hz": .double(20_000)])]),
            .array([valid, .object(["center_hz": .double(20_000), "energy_dbfs": .double(-10), "unit": .string("gain")])]),
            .array([point(.infinity, -40), point(20_000, -10)]),
            .array([point(20, .nan), point(20_000, -10)]),
        ]
        for curve in invalid {
            let result = AudioDispatcher.handle(command: "analyze_spectrum", params: [
                "path": .string("/tmp/curve-deliberately-absent.wav"), "target_curve": curve,
            ])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let isError = try #require(result.isError)
            #expect(isError)
            #expect(body["error"] as? String == "invalid_params")
            #expect(sharedToolText(result).contains("target_curve"))
        }
    }

    @Test func aNarrowCurveNeverExtrapolatesOrClaimsAllBandsComplete() throws {
        try withTone { path in
            let body = try evaluated(path, curve: .array([point(900, -30), point(1_200, -30)]))
            let bands = try #require(body["bands"] as? [[String: Any]])
            for band in bands {
                let hz = try #require(band["centerHz"] as? Double)
                if hz < 900 || hz > 1_200 {
                    #expect(band["unavailableReason"] as? String == "outside_target_span")
                    #expect(band["deltaDb"] == nil)
                    #expect(band["targetEnergyDbfs"] == nil)
                }
            }
            let complete = try #require(body["complete"] as? Bool)
            #expect(!complete)
        }
    }

    @Test func incompleteArtifactsRetainTheirMachineReadableFailure() throws {
        try withTone(frames: 100) { path in
            let result = AudioDispatcher.handle(command: "analyze_spectrum", params: [
                "path": .string(path.path), "target_curve": .array([point(20, -40), point(20_000, -10)]),
            ])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let isError = try #require(result.isError)
            #expect(isError)
            #expect(body["analysis_error"] as? String == "incomplete_input")
            let writeAttempted = try #require(body["write_attempted"] as? Bool)
            #expect(!writeAttempted)
            #expect(body["targetCurveComparison"] == nil)
        }
    }

    @Test func silenceAndFloorTargetsNeverAcquireAComputedGain() throws {
        try withTone(amplitude: 0) { path in
            let result = try evaluated(path, curve: .array([point(20, -40), point(20_000, -10)]))
            let bands = try #require(result["bands"] as? [[String: Any]])
            #expect(bands.allSatisfy { $0["deltaDb"] == nil })
            #expect(bands.contains { $0["unavailableReason"] as? String == "at_analysis_floor" })
            let complete = try #require(result["complete"] as? Bool)
            #expect(!complete)
        }
        try withTone { path in
            let result = try evaluated(path, curve: .array([point(20, -80), point(20_000, -80)]))
            let bands = try #require(result["bands"] as? [[String: Any]])
            #expect(bands.allSatisfy { $0["deltaDb"] == nil })
            #expect(bands.contains { $0["unavailableReason"] as? String == "target_at_analysis_floor" })
        }
    }

    @Test func evaluationIsDeterministicAndLegacyAnalysisKeepsItsFlatShape() throws {
        try withTone { path in
            let curve: Value = .array([point(20, -40), point(20_000, -10)])
            let first = try evaluated(path, curve: curve)
            let second = try evaluated(path, curve: curve)
            #expect(NSDictionary(dictionary: first).isEqual(to: second))
            let legacy = AudioDispatcher.handle(command: "analyze_spectrum", params: ["path": .string(path.path)])
            let body = try #require(sharedJSONObject(sharedToolText(legacy)))
            #expect(body["bands"] as? [[String: Any]] != nil)
            #expect(body["analysis"] == nil)
            #expect(body["targetCurveComparison"] == nil)
            #expect(body["artifactFingerprint"] as? String == "not_computed_by_dispatcher")
        }
    }

    @Test func publicCurveEvaluationInterpolatesAndBindsTheArtifact() throws {
        try withTone { path in
            let bytes = try Data(contentsOf: path)
            let curve: Value = .array([point(20, -40), point(20_000, -10)])
            let result = AudioDispatcher.handle(command: "analyze_spectrum", params: [
                "path": .string(path.path), "target_curve": curve,
            ])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let analysis = try #require(body["analysis"] as? [String: Any])
            let evaluation = try #require(body["targetCurveComparison"] as? [String: Any])
            let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(analysis["artifactFingerprint"] as? String == hash)
            let observed = try #require(analysis["bands"] as? [[String: Any]])
            let evaluated = try #require(evaluation["bands"] as? [[String: Any]])
            #expect(evaluated.count == observed.count)
            let index = try #require(observed.indices.min {
                abs((observed[$0]["centerHz"] as? Double ?? 0) - 1_000)
                    < abs((observed[$1]["centerHz"] as? Double ?? 0) - 1_000)
            })
            let frequency = try #require(observed[index]["centerHz"] as? Double)
            let energy = try #require(observed[index]["energyDb"] as? Double)
            let expected = -40 + 30 * log(frequency / 20) / log(1_000)
            #expect(abs(try #require(evaluated[index]["targetEnergyDbfs"] as? Double) - expected) < 1e-10)
            #expect(abs(try #require(evaluated[index]["deltaDb"] as? Double) - (expected - energy)) < 1e-10)
            #expect(evaluated.contains { $0["unavailableReason"] as? String == "unmeasured_band" })
            let complete = try #require(evaluation["complete"] as? Bool)
            #expect(!complete)
            #expect(try Data(contentsOf: path) == bytes)
            #expect(!body.keys.contains("applied"))
        }
    }

    private func point(_ hz: Double, _ energy: Double) -> Value {
        .object(["center_hz": .double(hz), "energy_dbfs": .double(energy)])
    }

    private func evaluated(_ path: URL, curve: Value) throws -> [String: Any] {
        let result = AudioDispatcher.handle(command: "analyze_spectrum", params: [
            "path": .string(path.path), "target_curve": curve,
        ])
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        return try #require(body["targetCurveComparison"] as? [String: Any])
    }

    private func withTone(frames: Int = 16_384, amplitude: Double = 0.4, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("target-curve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tone.wav")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let file = try AVAudioFile(forWriting: path, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channel = try #require(buffer.floatChannelData)[0]
            for frame in 0..<frames {
                channel[frame] = Float(amplitude * cos(2 * Double.pi * 1_001.953125 * Double(frame) / 48_000))
            }
            try file.write(from: buffer)
        }
        try body(path)
    }
}
