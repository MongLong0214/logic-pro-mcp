import Testing
@testable import LogicProMCP

private func issue529Position(of fragment: String, in script: String) throws -> String.Index {
    let range = try #require(
        script.range(of: fragment),
        "Generated AppleScript must contain: \(fragment)"
    )
    return range.lowerBound
}

private func issue529Position(
    of fragment: String,
    after start: String.Index,
    in script: String
) throws -> String.Index {
    let range = try #require(
        script.range(of: fragment, range: start..<script.endIndex),
        "Generated AppleScript must contain \(fragment) after the preceding guard"
    )
    return range.lowerBound
}

@Suite("Issue #529 — Go To Position menu validation")
struct Issue529MenuValidationTests {
    @Test("Korean menu chain opens before AXEnabled is read")
    func koreanMenuOpensBeforeEnabledRead() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let menuBarOpen = try issue529Position(
            of: "click menu bar item \"탐색\" of menu bar 1",
            in: script
        )
        let submenuOpen = try issue529Position(
            of: "click menu item \"이동\" of menu 1 of menu bar item \"탐색\" of menu bar 1",
            in: script
        )
        let enabledRead = try issue529Position(of: "enabled of mi", in: script)
        let englishMenuBarOpen = try issue529Position(
            of: "click menu bar item \"Navigate\" of menu bar 1",
            in: script
        )

        #expect(menuBarOpen < submenuOpen)
        #expect(submenuOpen < enabledRead)
        #expect(menuBarOpen < englishMenuBarOpen)
    }

    @Test("English fallback menu chain opens before AXEnabled is read")
    func englishMenuOpensBeforeEnabledRead() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let menuBarOpen = try issue529Position(
            of: "click menu bar item \"Navigate\" of menu bar 1",
            in: script
        )
        let submenuOpen = try issue529Position(
            of: "click menu item \"Go To\" of menu 1 of menu bar item \"Navigate\" of menu bar 1",
            in: script
        )
        let enabledRead = try issue529Position(of: "enabled of mi", in: script)

        #expect(menuBarOpen < submenuOpen)
        #expect(submenuOpen < enabledRead)
    }

    @Test("disabled menu path dismisses the open menu before refusing")
    func disabledMenuIsDismissedBeforeRefusal() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let disabledGuard = try issue529Position(of: "if not menuItemEnabled then", in: script)
        let dismissal = try issue529Position(of: "key code 53", after: disabledGuard, in: script)
        let disabledReturn = try issue529Position(
            of: "return \"MENU_DISABLED\"",
            after: disabledGuard,
            in: script
        )

        #expect(disabledGuard < dismissal)
        #expect(dismissal < disabledReturn)
    }
}
