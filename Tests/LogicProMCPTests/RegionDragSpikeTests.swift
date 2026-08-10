import Foundation
import Testing

private struct RegionDragSpikeRun {
    let status: Int32
    let output: String
}

private func regionDragSpikeRepositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func runRegionDragSpike(
    exportDir: String,
    source: String? = "10,10",
    destination: String? = "20,20"
) throws -> RegionDragSpikeRun {
    let root = regionDragSpikeRepositoryRootURL()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.currentDirectoryURL = root
    process.arguments = [
        root.appendingPathComponent("Scripts/spike-midi-region-drag-export.swift").path,
    ]
    if let source {
        process.arguments?.append(contentsOf: ["--source", source])
    }
    if let destination {
        process.arguments?.append(contentsOf: ["--destination", destination])
    }
    process.arguments?.append(contentsOf: ["--export-dir", exportDir])
    process.environment = ProcessInfo.processInfo.environment.merging([
        "LOGIC_PRO_MCP_ARM_REGION_DRAG": "1",
    ]) { _, new in new }

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    return RegionDragSpikeRun(
        status: process.terminationStatus,
        output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
}

private func regionDragSpikeRecords(_ output: String) throws -> [[String: Any]] {
    try output
        .split(separator: "\n")
        .map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(object as? [String: Any])
        }
}

private func assertRegionDragSpikeBlocked(
    exportDir: String,
    noteContains expectedNoteFragment: String,
    source: String? = nil,
    destination: String? = nil
) throws {
    let run = try runRegionDragSpike(exportDir: exportDir, source: source, destination: destination)
    #expect(run.status == 2)

    let record = try #require(try regionDragSpikeRecords(run.output).first)
    #expect(record["record_type"] as? String == "region_drag_preflight")
    #expect(record["status"] as? String == "blocked")
    let note = try #require(record["note"] as? String)
    #expect(note.contains(expectedNoteFragment))
}

@Test func regionDragSpikeBlocksEmptyAndWhitespaceArmedExportDir() throws {
    for exportDir in ["", " \t "] {
        let run = try runRegionDragSpike(exportDir: exportDir)
        #expect(run.status == 2)

        let record = try #require(try regionDragSpikeRecords(run.output).first)
        #expect(record["record_type"] as? String == "region_drag_preflight")
        #expect(record["status"] as? String == "blocked")
        let note = try #require(record["note"] as? String)
        #expect(note.contains("non-empty"))
    }
}

@Test func regionDragSpikeBlocksRelativeArmedExportDir() throws {
    let run = try runRegionDragSpike(exportDir: "relative/dir")
    #expect(run.status == 2)

    let record = try #require(try regionDragSpikeRecords(run.output).first)
    #expect(record["record_type"] as? String == "region_drag_preflight")
    #expect(record["status"] as? String == "blocked")
    let note = try #require(record["note"] as? String)
    #expect(note.contains("absolute path"))
}

@Test func regionDragSpikeBlocksTraversalEscapeOutsideScratchRoot() throws {
    try assertRegionDragSpikeBlocked(
        exportDir: "/tmp/../Users/isaac/x",
        noteContains: "controlled_scratch_root"
    )
}

@Test func regionDragSpikeBlocksLogicProMCPBasenameOutsideScratchRoot() throws {
    try assertRegionDragSpikeBlocked(
        exportDir: "/Users/isaac/LogicProMCP",
        noteContains: "controlled_scratch_root"
    )
}

@Test func regionDragSpikeBlocksHomeAndRootExportDirs() throws {
    try assertRegionDragSpikeBlocked(
        exportDir: FileManager.default.homeDirectoryForCurrentUser.path,
        noteContains: "controlled_scratch_root"
    )
    try assertRegionDragSpikeBlocked(
        exportDir: "$HOME",
        noteContains: "absolute path"
    )
    try assertRegionDragSpikeBlocked(
        exportDir: "/",
        noteContains: "controlled_scratch_root"
    )
}

/// The positive twin is `regionDragSpikeAcceptsControlledTmpExportDirBeforeCoordinateGate`,
/// which already asserts that a scratch-root path gets past this gate — so this rejection
/// test cannot be passing merely because everything is rejected.
@Test func regionDragSpikeBlocksAnExportDirOutsideTheScratchRoot() throws {
    try assertRegionDragSpikeBlocked(
        exportDir: NSHomeDirectory(),
        noteContains: "controlled_scratch_root"
    )
}


@Test func regionDragSpikeBlocksTmpSymlinkEscapeOutsideScratchRoot() throws {
    let link = URL(fileURLWithPath: "/tmp/LogicProMCP-region-drag-spike-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
    )
    defer { try? FileManager.default.removeItem(at: link) }

    try assertRegionDragSpikeBlocked(
        exportDir: link.appendingPathComponent("LogicProMCP-\(UUID().uuidString)").path,
        noteContains: "controlled_scratch_root"
    )
}

@Test func regionDragSpikeAcceptsTmpSymlinkStayingInsideScratchRoot() throws {
    let target = URL(fileURLWithPath: "/tmp/LogicProMCP-region-drag-spike-target-\(UUID().uuidString)")
    let link = URL(fileURLWithPath: "/tmp/LogicProMCP-region-drag-spike-link-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    defer {
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.removeItem(at: target)
    }

    let trailingDirectory = "LogicProMCP-\(UUID().uuidString)"
    let run = try runRegionDragSpike(
        exportDir: link.appendingPathComponent(trailingDirectory).path,
        source: nil,
        destination: nil
    )
    #expect(run.status == 2)

    let records = try regionDragSpikeRecords(run.output)
    let armedRecord = try #require(records.first)
    #expect(armedRecord["record_type"] as? String == "region_drag_preflight")
    #expect(armedRecord["status"] as? String == "armed")
    #expect(
        armedRecord["export_dir"] as? String
            == target.resolvingSymlinksInPath().appendingPathComponent(trailingDirectory).path
    )
}

@Test func regionDragSpikeAcceptsControlledTmpExportDirBeforeCoordinateGate() throws {
    let exportDir = "/tmp/LogicProMCP-region-drag-spike-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: exportDir) }

    let run = try runRegionDragSpike(exportDir: exportDir, source: nil, destination: nil)
    #expect(run.status == 2)

    let records = try regionDragSpikeRecords(run.output)
    let armedRecord = try #require(records.first)
    #expect(armedRecord["record_type"] as? String == "region_drag_preflight")
    #expect(armedRecord["status"] as? String == "armed")

    let coordinateRecord = try #require(records.dropFirst().first)
    #expect(coordinateRecord["status"] as? String == "blocked")
    let note = try #require(coordinateRecord["note"] as? String)
    #expect(note.contains("Both --source"))
}
