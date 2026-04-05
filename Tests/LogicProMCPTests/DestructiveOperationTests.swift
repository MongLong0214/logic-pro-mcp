import Testing
@testable import LogicProMCP

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
    #expect(AppleScriptSafety.isValidFilePath("/dev/null") == true) // valid path, Logic Pro will handle
}
