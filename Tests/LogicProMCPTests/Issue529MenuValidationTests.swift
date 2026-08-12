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

private func issue529LedgerPath(from script: String, stage: String) throws -> String {
    let prefix = "recordDialogIssuance(\"\(stage)\", \""
    let start = try #require(script.range(of: prefix))
    let tail = script[start.upperBound...]
    let end = try #require(tail.firstIndex(of: "\""))
    return String(tail[..<end])
}

private final class Issue529Counter: @unchecked Sendable {
    private(set) var value = 0

    func bump() {
        value += 1
    }
}

private func issue529SliderRuntime(
    sliderWrites: Issue529Counter,
    includeBeatSlider: Bool = false
) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(5290)
    let window = builder.element(5291)
    let controlBar = builder.element(5292)
    let barSlider = builder.element(5293)
    let beatSlider = builder.element(5294)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, includeBeatSlider ? [barSlider, beatSlider] : [barSlider])
    builder.setAttribute(barSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(barSlider, kAXDescriptionAttribute as String, "Bar")
    builder.setAttribute(barSlider, kAXValueAttribute as String, NSNumber(value: 1))
    if includeBeatSlider {
        builder.setAttribute(beatSlider, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(beatSlider, kAXDescriptionAttribute as String, "Beat")
        builder.setAttribute(beatSlider, kAXValueAttribute as String, NSNumber(value: 1))
    }

    return builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { element, attribute, value in
            if (element == barSlider || element == beatSlider), attribute == kAXValueAttribute as String {
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
        let menuBarOpened = try issue529Position(
            of: "set menuBarOpenState to my menuItemOpenedAfterClick(selectedMenuBarItem)",
            in: script
        )
        let submenuOpen = try issue529Position(of: "click selectedSubmenuItem", in: script)
        let submenuOpened = try issue529Position(
            of: "set submenuOpenState to my menuItemOpenedAfterClick(selectedSubmenuItem)",
            in: script
        )
        let enabledRead = try issue529Position(of: "enabled of mi", in: script)

        #expect(koreanDecision < englishDecision)
        #expect(englishDecision < menuBarOpen)
        #expect(menuBarOpen < menuBarOpened)
        #expect(menuBarOpened < submenuOpen)
        #expect(menuBarOpen < submenuOpen)
        #expect(submenuOpen < submenuOpened)
        #expect(submenuOpened < enabledRead)
        #expect(submenuOpen < enabledRead)
        #expect(!script.contains("click menu bar item"))
        #expect(issue529Positions(of: "click selectedMenuBarItem", in: script).count == 1)
        #expect(issue529Positions(of: "click selectedSubmenuItem", in: script).count == 1)
    }

    @Test("the leaf click requires the selected submenu's own open observation")
    func leafClickRequiresSelectedSubmenuToOpen() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let submenuClick = try issue529Position(of: "click selectedSubmenuItem", in: script)
        let submenuOpened = try issue529Position(
            of: "set submenuOpenState to my menuItemOpenedAfterClick(selectedSubmenuItem)",
            in: script
        )
        let submenuNotOpen = try issue529Position(
            of: "if submenuOpenState is not \"OPEN\" then",
            in: script
        )
        let submenuRefusal = try issue529Position(
            of: "return \"MENU_PICK_FAILED: selected submenu item did not open (\"",
            in: script
        )
        let leafClick = try issue529Position(of: "click mi", in: script)

        #expect(submenuClick < submenuOpened)
        #expect(submenuOpened < submenuNotOpen)
        #expect(submenuNotOpen < submenuRefusal)
        #expect(submenuRefusal < leafClick)
    }

    @Test("an unrelated open menu cannot satisfy the submenu observation")
    func submenuObservationIsBoundToTheClickedItem() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let observationStart = try issue529Position(
            of: "on menuItemOpenedAfterClick(theMenuItem)",
            in: script
        )
        let observationEnd = try issue529Position(of: "end menuItemOpenedAfterClick", in: script)
        let observation = String(script[observationStart..<observationEnd])
        _ = try #require(
            observation.range(of: "if selected of theMenuItem then return \"OPEN\"")
        )

        #expect(!observation.contains("menuOpenState("))
        #expect(!observation.contains("theProcess"))
    }

    @Test("the healthy submenu path still clicks the leaf")
    func healthySubmenuPathStillClicksLeaf() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let submenuOpened = try issue529Position(
            of: "set submenuOpenState to my menuItemOpenedAfterClick(selectedSubmenuItem)",
            in: script
        )
        let leafClick = try issue529Position(of: "click mi", in: script)

        #expect(submenuOpened < leafClick)
    }

    @Test("entry cleanup runs before locale discovery or menu actuation")
    func entryTimeCleanupPrecedesMenuWork() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryCleanup = try issue529Position(
            of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)",
            in: script
        )
        let firstOperationalDelay = try issue529Position(of: "delay 0.2", in: script)
        let localeDecision = try issue529Position(of: "if exists menu item \"위치…\"", in: script)
        let menuBarOpen = try issue529Position(of: "click selectedMenuBarItem", in: script)

        #expect(entryCleanup < firstOperationalDelay)
        #expect(entryCleanup < localeDecision)
        #expect(entryCleanup < menuBarOpen)
    }

    @Test("entry refuses an unreadable menu bar before any transport actuation")
    func entryCleanupRefusesAnUnreadableMenuBar() throws {
        // Mutation this rejects: restore the `OPEN || OPEN_UNREADABLE` guard, which treats an
        // unreadable entry read as safe enough to start the menu/slider route.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryGuard = try issue529Position(
            of: "if entryMenuCleanup is not \"CLOSED\" then",
            in: script
        )
        let localeDecision = try issue529Position(of: "if exists menu item \"위치…\"", in: script)

        #expect(entryGuard < localeDecision)
        #expect(script.contains("if menuState is \"UNREADABLE\" and not knownOpen then return \"UNREADABLE\""))
    }

    /// Script fixture: the entry menu read is unreadable. Because this run has not opened a menu,
    /// it must refuse without manufacturing an Escape into an unknown focus target.
    @Test("unreadable entry state refuses without Escape")
    func entryCleanupRefusesUnreadableAfterObservedOpen() async throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let dismissalStart = try issue529Position(of: "on dismissOpenMenu(theProcess, knownOpen)", in: script)
        let dismissalEnd = try issue529Position(of: "end dismissOpenMenu", in: script)
        let dismissal = String(script[dismissalStart..<dismissalEnd])
        let unreadableGuard = try issue529Position(
            of: "if menuState is \"UNREADABLE\" and not knownOpen then return \"UNREADABLE\"",
            in: dismissal
        )
        let escape = try issue529Position(of: "key code 53", in: dismissal)
        let entryGuard = try issue529Position(
            of: "if entryMenuCleanup is not \"CLOSED\" then",
            in: script
        )

        #expect(unreadableGuard < escape)

        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_PICK_FAILED: menu state was not observed closed at entry (UNREADABLE)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(sliderWrites.value == 0)
    }

    @Test("every refusal uses observed menu cleanup")
    func refusalPathsUseObservedMenuCleanup() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryCleanup = try issue529Position(
            of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)",
            in: script
        )
        let entryRefusal = try issue529Position(
            of: "return \"MENU_PICK_FAILED: menu state was not observed closed at entry",
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
                of: "set cleanupState to my dismissOpenMenu(logicProcess,",
                in: script
            ).contains { previousRefusalReturn < $0 && $0 < refusalReturn }
            #expect(cleanupBetweenRefusals)
            previousRefusalReturn = refusalReturn
        }
    }

    @Test("cleanup after click mi is marked as an attempted menu write")
    func menuItemClickMarksSubsequentCleanupAsAttempted() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let attempted = try issue529Position(of: "set menuActuationAttempted to true", in: script)
        let menuBarClick = try issue529Position(of: "click selectedMenuBarItem", in: script)
        let menuItemClick = try issue529Position(of: "click mi", in: script)
        let leafErrorHandlerEnd = try issue529Position(of: "-- Wait up to 3s for the dialog window", in: script)
        let leafErrorHandler = String(script[menuItemClick..<leafErrorHandlerEnd])
        let cleanupAfterMenuItemClick = try issue529Position(
            of: "set cleanupState to my dismissOpenMenu(logicProcess, true)", in: leafErrorHandler
        )
        let refusalContextAfterMenuItemClick = try issue529Position(
            of: "my menuCleanupActuationContext(menuActuationAttempted)", in: leafErrorHandler
        )

        #expect(attempted < menuBarClick)
        #expect(menuBarClick < menuItemClick)
        #expect(menuItemClick < leafErrorHandlerEnd)
        #expect(cleanupAfterMenuItemClick < refusalContextAfterMenuItemClick)
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

    @Test("a pre-actuation menu close failure returns State C without touching the slider")
    func preActuationMenuCloseFailureDoesNotFallThroughToSlider() async throws {
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
        #expect(hint.contains("not observed closed"))
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(!(try #require(envelope["menu_actuation_attempted"] as? Bool)))
        #expect(HonestContract.isFallbackUnsafeStateC(result.message))
        #expect(sliderWrites.value == 0)
    }

    @Test("a post-click menu close failure records menu navigation, not a position write")
    func postClickMenuCloseFailureRefusesBeforePositionWrite() async throws {
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_PICK_FAILED: menu cleanup was not observed after menu actuation (UNREADABLE)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["menu_actuation_attempted"] as? Bool))
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(HonestContract.isFallbackUnsafeStateC(result.message))
        #expect(sliderWrites.value == 0)
    }

    @Test("an issued leaf AX failure with unobserved cleanup stays State C and never selects the slider")
    func issuedLeafActuationFailureWithUnobservedCleanupDoesNotSelectSlider() async throws {
        // Mutation this rejects: treat a leaf failure with no cleanup observation as a clean
        // navigation-only failure, letting this result fall through to the slider.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (OPEN_UNREADABLE)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        let submissionAttempted = try #require(envelope["dialog_submission_attempted"] as? Bool)
        let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)
        #expect(!writeAttempted)
        #expect(!submissionAttempted)
        #expect(fallbackUnsafe)
        #expect(sliderWrites.value == 0)
    }

    @Test("a clean leaf-only failure permits the slider fallback")
    func cleanLeafActuationFailureAllowsSliderFallback() async throws {
        // Mutation this rejects: make every `.dialogActuationIssued` result block the slider,
        // even after the script observed dialog/menu cleanup and proved it never reached Return.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_ACTUATION_ISSUED: AXPress reported failure after observed cleanup"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["via"] as? String) == "slider")
        #expect(sliderWrites.value > 0)
    }

    @Test("a dead child after the durable leaf checkpoint is State B and cannot select the slider")
    func deadChildAfterLeafCheckpointDoesNotReleaseSlider() async throws {
        // Mutations this rejects:
        // 1. Remove the parent-owned `LEAF_ARMED` ledger checkpoint or ignore it in the `.error`
        //    branch — this clean-reconciliation fixture falls through to the slider.
        // 2. Report `write_attempted:false` for the durable checkpoint — the receipt assertion fails.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                try! "LEAF_ARMED".write(toFile: ledgerPath, atomically: true, encoding: .utf8)
                return .error("osascript timed out after leaf click")
            },
            reconcileAfterDialogExecutionFailure: { true }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["write_attempted"] as? Bool))
        #expect(try #require(envelope["dialog_submission_attempted"] as? Bool))
        #expect(sliderWrites.value == 0)
    }

    @Test("only the post-Return branch is submission-issued")
    func preReturnFailuresFallThroughWhilePostReturnFailuresAreStateB() async throws {
        // Mutations this rejects:
        // 1. Move `keystroke return` into the pre-Return error scope or delete it — the generated
        //    script ordering assertions fail.
        // 2. Classify `DIALOG_SUBMISSION_NOT_ISSUED` as issued — the pre-Return run stops using the
        //    slider and fails the first behavioral assertion.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let inputFailure = try issue529Position(
            of: "return \"DIALOG_SUBMISSION_NOT_ISSUED: dialog input failed before Return",
            in: script
        )
        let returnLedger = try issue529Position(
            of: "recordDialogIssuance(\"RETURN_ARMED\"",
            in: script
        )
        let returnKey = try issue529Position(of: "keystroke return", in: script)
        #expect(inputFailure < returnLedger)
        #expect(returnLedger < returnKey)

        let preReturnSliderWrites = Issue529Counter()
        let preReturn = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: preReturnSliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_SUBMISSION_NOT_ISSUED: dialog input failed before Return (AX error)"}"#)
            }
        )
        let preReturnEnvelope = try #require(issue529Envelope(preReturn))
        #expect(try #require(preReturnEnvelope["via"] as? String) == "slider")
        #expect(preReturnSliderWrites.value > 0)

        let postReturnSliderWrites = Issue529Counter()
        let postReturn = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: postReturnSliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_SUBMISSION_ISSUED: Return may have been sent (AX error)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(postReturn))
        #expect(postReturn.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        let submissionAttempted = try #require(envelope["dialog_submission_attempted"] as? Bool)
        let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)
        #expect(writeAttempted)
        #expect(submissionAttempted)
        #expect(fallbackUnsafe)
        #expect(postReturnSliderWrites.value == 0)
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

    @Test("partial slider evidence for an explicit beat remains State B")
    func partialSliderEvidenceDoesNotCertifyTheRequestedPosition() async throws {
        // Mutations this rejects:
        // 1. Return `encodeStateA` after bar/beat read-back — the State-B assertion fails.
        // 2. Reset `targetBeat` to 1 or rebuild `requested` as `.1.1.1` — the exact request and
        //    observed bar/beat assertions fail.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["position": "529.4.1.1"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites, includeBeatSlider: true),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in .success(#"{"result":"MENU_NOT_FOUND"}"#) }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["requested"] as? String) == "529.4.1.1")
        let observed = try #require(envelope["observed"] as? String)
        #expect(observed == "529.4")
        let unobserved = try #require(envelope["unobserved_position_components"] as? [String])
        #expect(unobserved == ["subdivision", "tick"])
        let unexpressed = try #require(envelope["unexpressed_position_components"] as? [String])
        #expect(unexpressed == ["subdivision", "tick"])
        #expect(sliderWrites.value > 0)
    }

    @Test("the dialog receives the complete requested musical position")
    func dialogTypesTheFullRequestedPosition() throws {
        // Mutation this rejects: replace the dialog input with the bar number or reconstruct it as
        // `.1.1.1`, silently discarding the request's beat/subdivision/tick components.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(position: "529.4.7.123")
        #expect(script.contains("keystroke \"529.4.7.123\""))
    }

    @Test("successful dialog submission observes modal closure before OK")
    func successfulDialogSubmissionObservesClosureBeforeOK() throws {
        // Mutation this rejects: return `OK` immediately after `keystroke return`, without reading
        // `goToPositionDialogState` and handling a dialog Logic ignored.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let returnKey = try issue529Position(of: "keystroke return", in: script)
        let postReturnObservation = try issue529Position(
            of: "set dialogPostReturnState to my goToPositionDialogState(logicProcess)", in: script
        )
        let ok = try issue529Position(of: "return \"OK\"", in: script)

        #expect(returnKey < postReturnObservation)
        #expect(postReturnObservation < ok)
    }

    @Test("durable issuance checkpoints precede the leaf and Return actuators")
    func durableIssuanceCheckpointsPrecedeActuators() throws {
        // Mutation this rejects: move either persistent checkpoint after its corresponding click or
        // key event, recreating the timeout window in which osascript dies with no durable record.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(
            position: "529.4.1.1",
            issuanceLedgerPath: "/private/tmp/issue529-ledger"
        )
        let leafCheckpoint = try issue529Position(
            of: "recordDialogIssuance(\"LEAF_ARMED\"", in: script
        )
        let leafClick = try issue529Position(of: "click mi", in: script)
        let returnCheckpoint = try issue529Position(
            of: "recordDialogIssuance(\"RETURN_ARMED\"", in: script
        )
        let returnKey = try issue529Position(of: "keystroke return", in: script)

        #expect(leafCheckpoint < leafClick)
        #expect(returnCheckpoint < returnKey)
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

/// Before this run opens its selected chain, an unreadable menu read must withhold Escape rather
/// than sending it into unknown focus. Once the run has clicked that chain, cleanup can use Escape.
@Test("unowned cleanup never marks a menu known-open before the selected chain click")
func dismissalContextKeepsLocaleReadsUnownedUntilMenuActuation() throws {
    // Mutation this rejects: change either locale-resolution cleanup call back to
    // `dismissOpenMenu(logicProcess, true)`, which authorises Escape after an unreadable read.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)

    // Entry plus the two locale-resolution exits are unowned reads.
    #expect(script.contains("my dismissOpenMenu(logicProcess, false)"))
    #expect(issue529Positions(of: "my dismissOpenMenu(logicProcess, false)", in: script).count == 3)

    let selectedChainClick = try issue529Position(of: "click selectedMenuBarItem", in: script)
    let firstKnownOpenCleanup = try #require(
        issue529Positions(of: "my dismissOpenMenu(logicProcess, true)", in: script).first
    )
    #expect(selectedChainClick < firstKnownOpenCleanup)

    // The handler itself only skips Escape when no menu has been established as this run's.
    #expect(script.contains("if menuState is \"UNREADABLE\" and not knownOpen then return \"UNREADABLE\""))
}

@Test("an unreadable Cancel result re-observes the dialog before Escape")
func unreadableCancelDoesNotAuthoriseEscapeWithoutDialogObservation() throws {
    // Mutation this rejects: move `key code 53` directly after an `UNREADABLE` Cancel result,
    // bypassing the fresh `goToPositionDialogState` observation.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    let handlerStart = try issue529Position(
        of: "on dismissOpenGoToPositionDialog(theProcess)", in: script
    )
    let handlerEnd = try issue529Position(of: "end dismissOpenGoToPositionDialog", in: script)
    let handler = String(script[handlerStart..<handlerEnd])
    let unreadableBranchStart = try issue529Position(
        of: "if cancelOutcome is \"NO_BUTTON\" or cancelOutcome is \"UNREADABLE\" then", in: handler
    )
    let unreadableBranch = String(handler[unreadableBranchStart...])
    // Every operand is the first occurrence in the same fixed branch slice. Unlike the former
    // `.first { before < $0 && $0 < escape }` form, none is selected using the ordering asserted
    // below, so moving Escape before a guard makes the test fail.
    let reobservation = try issue529Position(
        of: "set dialogState to my goToPositionDialogState(theProcess)", in: unreadableBranch
    )
    let closedGuard = try issue529Position(
        of: "if dialogState is \"CLOSED\" then return \"CLOSED\"", in: unreadableBranch
    )
    let unreadableGuard = try issue529Position(
        of: "if dialogState is \"UNREADABLE\" then return \"OPEN_UNREADABLE\"", in: unreadableBranch
    )
    let stillOpenGuard = try issue529Position(
        of: "if dialogState is not \"OPEN\" then return dialogState", in: unreadableBranch
    )
    let escape = try issue529Position(of: "key code 53", in: unreadableBranch)

    #expect(reobservation < closedGuard)
    #expect(closedGuard < unreadableGuard)
    #expect(unreadableGuard < stillOpenGuard)
    #expect(stillOpenGuard < escape)
}

@Test("dead-child reconciliation observes the named dialog before menu state")
func aDeadScriptReconcilesDialogBeforeMenuState() throws {
    // Mutations this rejects: restore the PID bypass (which skips cleanup), or reduce the recovery
    // helper to menu-only observation. Either source relationship below fails.
    let source = try String(
        contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/LogicProMCPTests/Issue529MenuValidationTests.swift",
            with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Transport.swift"
        ),
        encoding: .utf8
    )
    let helperStart = try #require(source.range(of: "private static func observeAndClearStrayGoToPositionUI()"))
    let helperEnd = try #require(source.range(of: "// MARK: - Control-bar checkbox helpers"))
    let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
    let dialogObservation = try issue529Position(of: "on goToPositionDialogState(theProcess)", in: helper)
    let dialogCleanup = try issue529Position(of: "set dialogCleanupState to my dismissGoToPositionDialog(it)", in: helper)
    let menuLoop = try issue529Position(of: "repeat with menuBarItem in every menu bar item", in: helper)

    #expect(dialogObservation < dialogCleanup)
    #expect(dialogCleanup < menuLoop)
    #expect(!helper.contains("ProcessUtils.logicProPID"))
}
