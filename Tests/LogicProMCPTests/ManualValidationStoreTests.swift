import Darwin
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

    #expect(!(await store.isApproved(.scripter)))
    #expect(await store.approval(for: .scripter) == nil)
    #expect(await store.list().isEmpty)
}

@Test func testManualValidationStoreWritesOwnerOnlyPermissions() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("approval-perms-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("operator-approvals.json")
    let store = ManualValidationStore(fileURL: fileURL)

    try await store.approve(.midiKeyCommands, note: "validated")

    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    let fileMode = try #require(
        FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    #expect(directoryMode == 0o700)
    #expect(fileMode == 0o600)
}

private actor BlockingApprovalSaveProbe {
    private var hasEntered = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if hasEntered {
            return
        }

        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func unblock() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func block() async {
        hasEntered = true
        let continuations = enteredContinuations
        enteredContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }

        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }
}

@Test func testManualValidationStoreSerializesConcurrentWritersAcrossStoreInstances() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("approval-race-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("operator-approvals.json")
    let probe = BlockingApprovalSaveProbe()
    let firstStore = ManualValidationStore(
        fileURL: fileURL,
        runtime: .init(beforeSaveWhileLocked: { await probe.block() })
    )
    let secondStore = ManualValidationStore(fileURL: fileURL)

    let firstTask = Task {
        try await firstStore.approve(.midiKeyCommands, note: nil)
    }
    await probe.waitUntilEntered()
    let lockPath = fileURL.appendingPathExtension("lock").path

    let secondTask = Task {
        try await secondStore.approve(.scripter, note: nil)
    }

    #expect(!(try canAcquireExclusiveLockNonblocking(atPath: lockPath)))

    await probe.unblock()
    try await firstTask.value
    try await secondTask.value

    let approvals = await secondStore.list()
    #expect(approvals[.midiKeyCommands] != nil)
    #expect(approvals[.scripter] != nil)
}

private func canAcquireExclusiveLockNonblocking(atPath path: String) throws -> Bool {
    let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        throw POSIXError(code)
    }
    defer { _ = close(descriptor) }

    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        _ = flock(descriptor, LOCK_UN)
        return true
    }

    if errno == EWOULDBLOCK {
        return false
    }

    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
    throw POSIXError(code)
}
