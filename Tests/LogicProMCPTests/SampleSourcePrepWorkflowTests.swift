import AVFoundation
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Sample source preparation workflow")
struct SampleSourcePrepWorkflowTests {
    private let workflowID = "logic.workflow.audio.sample_source_prep"

    private func workflow() throws -> WorkflowSkill {
        try #require(WorkflowSkillCatalog.defaultWorkflows().first { $0.id == workflowID })
    }

    @Test("lints clean and stays read-only")
    func lintsCleanAndReadOnly() throws {
        let workflow = try workflow()
        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.isEmpty, "unexpected lint issues: \(issues)")
        #expect(workflow.mutationKind == .readOnly)
        #expect(workflow.steps.allSatisfy { !$0.mutates })
        #expect(workflow.allowedTools == ["logic_audio"])
        #expect(workflow.requiredConfirmations.isEmpty)
    }

    @Test("every declared response field is present in the real dispatcher reply")
    func declaredFieldsMatchDispatcherReplies() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-source-prep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tone.wav")
        try writeToneWAV(at: fileURL)

        for step in try workflow().steps {
            let command = try #require(step.command)
            let result = AudioDispatcher.handle(command: command, params: ["path": .string(fileURL.path)])
            let isError = try #require(result.isError)
            #expect(!isError, "\(command) failed on a valid WAV")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            for field in step.expectedResponseFields {
                #expect(body[field] != nil, "\(command) reply lacks declared field \(field)")
            }
        }
    }

    @Test("a missing file fails the first step instead of reporting success")
    func missingFileFailsFirstStep() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-source-prep-missing-\(UUID().uuidString).wav").path
        let result = AudioDispatcher.handle(command: "analyze_file", params: ["path": .string(missing)])
        let isError = try #require(result.isError)
        #expect(isError)
    }

    private func writeToneWAV(at url: URL) throws {
        let sampleRate = 48_000.0
        let frameCount = 48_000
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<frameCount {
            samples[frame] = Float(0.5 * sin(2.0 * Double.pi * 440.0 * Double(frame) / sampleRate))
        }
        try file.write(from: buffer)
    }
}
