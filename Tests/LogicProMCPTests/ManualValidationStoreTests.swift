import Foundation
import Testing
@testable import LogicProMCP

@Test func testManualValidationChannelParseSupportsAliases() {
    #expect(ManualValidationChannel.parse("Scripter") == .scripter)
    #expect(ManualValidationChannel.parse("key cmd") == .midiKeyCommands)
    #expect(ManualValidationChannel.parse("unknown-channel") == nil)
}

@Test func testManualValidationSummaryHandlesEmptyAndNoteLessApprovals() {
    #expect(
        ManualValidationStore.summary(for: [:]) ==
        "No manual-validation channels have been approved."
    )

    let summary = ManualValidationStore.summary(
        for: [
            .scripter: ManualValidationApproval(
                approvedAt: Date(timeIntervalSince1970: 0),
                note: nil
            )
        ]
    )

    #expect(summary.contains("Scripter: approved at 1970-01-01T00:00:00Z"))
    #expect(!summary.contains("—"))
}

@Test func testManualValidationStoreTreatsInvalidJSONAsEmptyState() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("approval-invalid-\(UUID().uuidString)")
        .appendingPathExtension("json")
    try Data("not-json".utf8).write(to: fileURL, options: .atomic)

    let store = ManualValidationStore(fileURL: fileURL)

    #expect(await store.isApproved(.scripter) == false)
    #expect(await store.approval(for: .scripter) == nil)
    #expect(await store.list().isEmpty)
}
