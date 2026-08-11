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

private func issue529Position(
    of fragment: String,
    before end: String.Index,
    in script: String
) throws -> String.Index {
    let range = try #require(
        script.range(of: fragment, options: .backwards, range: script.startIndex..<end),
        "Generated AppleScript must contain \(fragment) before the refusal"
    )
    return range.lowerBound
}

private func issue529Positions(of fragment: String, in script: String) -> [String.Index] {
    var positions: [String.Index] = []
    var searchStart = script.startIndex
    while let range = script.range(of: fragment, range: searchStart..<script.endIndex) {
        positions.append(range.lowerBound)
        searchStart = range.upperBound
    }
    return positions
}

@Suite("Issue #529 — Go To Position menu validation")
struct Issue529MenuValidationTests {
    @Test("locale is decided by non-actuating reads before one selected chain opens")
    func localeIsDecidedBeforeSingleMenuChainOpens() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let koreanDecision = try issue529Position(
            of: "if exists menu item \"위치…\"",
            in: script
        )
        let englishDecision = try issue529Position(
            of: "else if exists menu item \"Position…\"",
            in: script
        )
        let menuBarOpen = try issue529Position(of: "click selectedMenuBarItem", in: script)
        let submenuOpen = try issue529Position(of: "click selectedSubmenuItem", in: script)
        let enabledRead = try issue529Position(of: "enabled of mi", in: script)

        #expect(koreanDecision < englishDecision)
        #expect(englishDecision < menuBarOpen)
        #expect(menuBarOpen < submenuOpen)
        #expect(submenuOpen < enabledRead)
        #expect(!script.contains("click menu bar item"))
        #expect(issue529Positions(of: "click selectedMenuBarItem", in: script).count == 1)
        #expect(issue529Positions(of: "click selectedSubmenuItem", in: script).count == 1)
    }

    @Test("entry cleanup runs before locale discovery or menu actuation")
    func entryTimeCleanupPrecedesMenuWork() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryCleanup = try issue529Position(
            of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess)",
            in: script
        )
        let firstOperationalDelay = try issue529Position(of: "delay 0.2", in: script)
        let localeDecision = try issue529Position(of: "if exists menu item \"위치…\"", in: script)
        let menuBarOpen = try issue529Position(of: "click selectedMenuBarItem", in: script)

        #expect(entryCleanup < firstOperationalDelay)
        #expect(entryCleanup < localeDecision)
        #expect(entryCleanup < menuBarOpen)
    }

    @Test("every refusal uses observed menu cleanup")
    func refusalPathsUseObservedMenuCleanup() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryCleanup = try issue529Position(
            of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess)",
            in: script
        )
        let entryRefusal = try issue529Position(
            of: "return \"MENU_PICK_FAILED: entry menu cleanup",
            in: script
        )
        let refusalReturns = issue529Positions(of: "return \"", in: script).filter { position in
            let line = script[position...]
            return position > entryRefusal
                && (line.hasPrefix("return \"MENU_") || line.hasPrefix("return \"DIALOG_NOT_READY"))
        }
        let escape = try issue529Position(of: "key code 53", in: script)
        let observation = try issue529Position(
            of: "set menuState to my menuOpenState(theProcess)",
            after: escape,
            in: script
        )

        #expect(refusalReturns.count > 0)
        #expect(entryCleanup < entryRefusal)
        #expect(escape < observation)
        for refusalReturn in refusalReturns {
            let cleanup = try issue529Position(
                of: "set cleanupState to my dismissOpenMenu(logicProcess)",
                before: refusalReturn,
                in: script
            )
            #expect(cleanup < refusalReturn)
        }
    }

    @Test("JSON-wrapped menu-not-found result refuses the dialog route")
    func jsonWrappedMenuNotFoundRefusesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"MENU_NOT_FOUND: Navigate menu missing"}"#
        )

        #expect(classification == .failure(.menuNotFound))
    }

    @Test("JSON-wrapped menu-pick-failed result refuses the dialog route")
    func jsonWrappedMenuPickFailedRefusesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"MENU_PICK_FAILED: AXPress failed"}"#
        )

        #expect(classification == .failure(.menuPickFailed))
    }

    @Test("JSON-wrapped disabled and not-ready sentinels still refuse the dialog route")
    func jsonWrappedExistingSentinelsRefuseDialogRoute() {
        let disabled = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"MENU_DISABLED"}"#
        )
        let notReady = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"DIALOG_NOT_READY"}"#
        )

        #expect(disabled == .failure(.menuDisabled))
        #expect(notReady == .failure(.dialogNotReady))
    }

    @Test("only JSON-wrapped OK counts as driving the dialog route")
    func jsonWrappedOKDrivesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"OK"}"#
        )

        #expect(classification == .driven)
    }

    @Test("malformed result payload refuses the dialog route")
    func malformedPayloadRefusesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult("MENU_NOT_FOUND: unwrapped")

        #expect(classification == .failure(.malformedPayload))
    }
}
