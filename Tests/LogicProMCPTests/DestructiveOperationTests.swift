import Foundation
import Testing
@testable import LogicProMCP

private final class AppleScriptOpenHarness: @unchecked Sendable {
    var openedURLs: [URL] = []
    var result = true

    func runtime() -> AppleScriptSafety.Runtime {
        AppleScriptSafety.Runtime(
            openFileURL: { url in
                self.openedURLs.append(url)
                return self.result
            }
        )
    }
}

@Test func testDestructiveLevelClassification() {
    #expect(DestructivePolicy.level(for: "quit") == .l3)
    #expect(DestructivePolicy.level(for: "close") == .l3)
    #expect(DestructivePolicy.level(for: "save_as") == .l2)
    #expect(DestructivePolicy.level(for: "bounce") == .l2)
    #expect(DestructivePolicy.level(for: "open") == .l2)
    #expect(DestructivePolicy.level(for: "save") == .l1)
    #expect(DestructivePolicy.level(for: "new") == .l1)
    #expect(DestructivePolicy.level(for: "launch") == .l1)
    #expect(DestructivePolicy.level(for: "play") == .l0)
    #expect(DestructivePolicy.level(for: "set_volume") == .l0)
}

@Test func testL3RequiresConfirmation() {
    let response = DestructivePolicy.confirmationResponse(command: "quit")
    #expect(response != nil)
    #expect(response!.contains("confirmation_required"))
    #expect(response!.contains("\"level\":\"L3\""))
}

@Test func testL2RequiresConfirmation() {
    let response = DestructivePolicy.confirmationResponse(command: "save_as")
    #expect(response != nil)
    #expect(response!.contains("\"level\":\"L2\""))
}

@Test func testL1NoConfirmation() {
    let response = DestructivePolicy.confirmationResponse(command: "save")
    #expect(response == nil) // L1 executes immediately
}

@Test func testTransportWhitelist() {
    #expect(AppleScriptSafety.isAllowedTransportAction("play") == true)
    #expect(AppleScriptSafety.isAllowedTransportAction("stop") == true)
    #expect(AppleScriptSafety.isAllowedTransportAction("record") == true)
    #expect(AppleScriptSafety.isAllowedTransportAction("pause") == true)
    #expect(AppleScriptSafety.isAllowedTransportAction("rm -rf") == false)
    #expect(AppleScriptSafety.isAllowedTransportAction("\" & do shell script") == false)
}

@Test func testOpenProjectSafety() {
    // NSWorkspace.open doesn't use AppleScript string interpolation
    // so any path is safe — verify the approach
    let safetyCheck = AppleScriptSafety.shouldUseNSWorkspaceForOpen
    #expect(safetyCheck == true)
}

@Test func testSaveAsPathValidation() {
    #expect(AppleScriptSafety.isValidFilePath("/Users/test/song.logicx") == true)
    #expect(AppleScriptSafety.isValidFilePath("") == false)
    #expect(AppleScriptSafety.isValidFilePath("/dev/null") == false)
    #expect(AppleScriptSafety.isValidFilePath("relative/song.logicx") == false)
    #expect(AppleScriptSafety.isValidProjectPath("/Users/test/song.logicx", requireExisting: false) == true)
    #expect(AppleScriptSafety.isValidProjectPath("/Users/test/song.txt", requireExisting: false) == false)
}

@Test func testAppleScriptSafetyRejectsControlCharactersAndMissingExistingProjects() {
    #expect(AppleScriptSafety.isValidFilePath("/Users/test/song\n.logicx") == false)

    let missingPath = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("logicx")
        .path
    #expect(AppleScriptSafety.projectURL(from: missingPath, requireExisting: true) == nil)
}

@Test func testAppleScriptOpenFileRejectsMissingAndNonProjectTargets() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory

    let missingProject = temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("logicx")
        .path
    #expect(AppleScriptSafety.openFile(at: missingProject) == false)

    let textFileURL = temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("txt")
    try Data().write(to: textFileURL)
    defer { try? FileManager.default.removeItem(at: textFileURL) }

    #expect(AppleScriptSafety.openFile(at: textFileURL.path) == false)
}

@Test func testAppleScriptOpenFileRejectsMalformedLogicPackage() throws {
    let malformedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("logicx")
    try FileManager.default.createDirectory(at: malformedURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: malformedURL) }

    let alternativesURL = malformedURL.appendingPathComponent("Alternatives/4294967295", isDirectory: true)
    try FileManager.default.createDirectory(at: alternativesURL, withIntermediateDirectories: true)
    try Data("undo".utf8).write(to: alternativesURL.appendingPathComponent("Undo Data.nosync"))

    #expect(AppleScriptSafety.openFile(at: malformedURL.path) == false)
    #expect(AppleScriptSafety.isValidProjectPath(malformedURL.path, requireExisting: true) == false)
}

private func makeExistingLogicProjectPackage() throws -> URL {
    let projectURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("logicx")
    let resourcesURL = projectURL.appendingPathComponent("Resources", isDirectory: true)
    let alternativeURL = projectURL.appendingPathComponent("Alternatives/000", isDirectory: true)
    try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: alternativeURL, withIntermediateDirectories: true)
    try Data("plist".utf8).write(to: resourcesURL.appendingPathComponent("ProjectInformation.plist"))
    try Data("project".utf8).write(to: alternativeURL.appendingPathComponent("ProjectData"))
    return projectURL
}

@Test func testAppleScriptOpenFileUsesInjectedRuntimeForExistingProject() throws {
    let harness = AppleScriptOpenHarness()
    let projectURL = try makeExistingLogicProjectPackage()
    defer { try? FileManager.default.removeItem(at: projectURL) }

    let opened = AppleScriptSafety.openFile(at: projectURL.path, runtime: harness.runtime())

    #expect(opened == true)
    #expect(harness.openedURLs.count == 1)
    #expect(harness.openedURLs[0] == projectURL.standardizedFileURL)
}

@Test func testAppleScriptOpenFilePropagatesInjectedOpenFailure() throws {
    let harness = AppleScriptOpenHarness()
    harness.result = false
    let projectURL = try makeExistingLogicProjectPackage()
    defer { try? FileManager.default.removeItem(at: projectURL) }

    let opened = AppleScriptSafety.openFile(at: projectURL.path, runtime: harness.runtime())

    #expect(opened == false)
    #expect(harness.openedURLs.count == 1)
}

@Test func testAppleScriptSafetyProductionRuntimeHandlesMissingFileURL() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("logicx")

    let opened = AppleScriptSafety.Runtime.production.openFileURL(url)

    #expect(opened == false)
}
