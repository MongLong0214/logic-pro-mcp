@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private func issue529Position(of fragment: String, in script: String) throws -> String.Index {
    let range = try #require(
        script.range(of: fragment),
        "Generated AppleScript must contain: \(fragment)"
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

private final class Issue529Counter: @unchecked Sendable {
    private(set) var value = 0

    func bump() {
        value += 1
    }
}

private func issue529SliderRuntime(sliderWrites: Issue529Counter) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(5290)
    let window = builder.element(5291)
    let controlBar = builder.element(5292)
    let barSlider = builder.element(5293)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [barSlider])
    builder.setAttribute(barSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(barSlider, kAXDescriptionAttribute as String, "Bar")
    builder.setAttribute(barSlider, kAXValueAttribute as String, NSNumber(value: 1))

    return builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { element, attribute, value in
            if element == barSlider, attribute == kAXValueAttribute as String {
                sliderWrites.bump()
            }
            builder.setAttribute(element, attribute, value)
            return true
        },
        performActionHandler: { _, _ in true }
    )
}

private func issue529Envelope(_ result: ChannelResult) -> [String: Any]? {
    let payload: String
    switch result {
    case let .success(text), let .error(text):
        payload = text
    }
    guard let data = payload.data(using: .utf8),
          let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return envelope
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

    /// Measured, not reasoned: refusing at entry on any non-CLOSED value sent 5 of 8 fresh server
    /// processes to the slider route, because the first menu-bar read on a cold System Events
    /// connection is frequently unreadable. Nothing has been opened at that point, so an unreadable
    /// menu bar is an absent observation rather than evidence of an open menu. After this run opens
    /// one, the same value IS a refusal — that asymmetry is the point.
    @Test("entry refuses only on an observed open menu, never on an unreadable one")
    func entryCleanupDoesNotRefuseOnAnUnreadableMenuBar() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryGuard = try issue529Position(of: "if entryMenuCleanup is \"OPEN\" then", in: script)
        let localeDecision = try issue529Position(of: "if exists menu item \"위치…\"", in: script)

        #expect(entryGuard < localeDecision)
        #expect(!script.contains("if entryMenuCleanup is not \"CLOSED\" then"))
        // The post-actuation refusals keep the strict form, so the asymmetry is asserted
        // rather than assumed.
        #expect(script.contains("if cleanupState is not \"CLOSED\" then"))
    }

    @Test("every refusal uses observed menu cleanup")
    func refusalPathsUseObservedMenuCleanup() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryCleanup = try issue529Position(
            of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess)",
            in: script
        )
        let entryRefusal = try issue529Position(
            of: "return \"MENU_PICK_FAILED: a menu was open at entry",
            in: script
        )
        let cleanupRefusalReturns = issue529Positions(of: "return \"", in: script).filter { position in
            let line = script[position...]
            return position > entryRefusal
                && line.hasPrefix("return \"MENU_PICK_FAILED: menu cleanup was not observed")
        }
        let escape = try issue529Position(of: "key code 53", in: script)
        let menuStateObservations = issue529Positions(
            of: "set menuState to my menuOpenState(theProcess)",
            in: script
        )

        #expect(cleanupRefusalReturns.count > 0)
        #expect(entryCleanup < entryRefusal)
        #expect(menuStateObservations.contains { escape < $0 })
        var previousRefusalReturn = entryRefusal
        for refusalReturn in cleanupRefusalReturns {
            let cleanupBetweenRefusals = issue529Positions(
                of: "set cleanupState to my dismissOpenMenu(logicProcess)",
                in: script
            ).contains { previousRefusalReturn < $0 && $0 < refusalReturn }
            #expect(cleanupBetweenRefusals)
            previousRefusalReturn = refusalReturn
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

    @Test("a menu that could not be closed returns State C without touching the slider")
    func menuCloseFailureDoesNotFallThroughToSlider() async throws {
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_PICK_FAILED: menu cleanup was not observed (OPEN)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["menu_state"] as? String) == "could_not_be_closed")
        let hint = try #require(envelope["hint"] as? String)
        #expect(hint.contains("could not be closed"))
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(sliderWrites.value == 0)
    }

    @Test("a menu-not-found dialog result still falls through to the slider")
    func menuNotFoundStillFallsThroughToSlider() async throws {
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_NOT_FOUND"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["via"] as? String) == "slider")
        #expect(sliderWrites.value > 0)
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
