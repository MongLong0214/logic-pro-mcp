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

private actor Issue529DialogLockGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func entered() {
        started = true
        startWaiter?.resume()
        startWaiter = nil
    }

    func waitUntilEntered() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func waitForRelease() async {
        guard !releaseRequested else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        releaseRequested = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private func issue529SliderRuntime(
    sliderWrites: Issue529Counter,
    includeBeatSlider: Bool = false,
    executeAppleScript: @escaping @Sendable (String) async -> ChannelResult = { _ in
        .success(#"{"result":"MENU_NOT_FOUND"}"#)
    }
) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(5290)
    let window = builder.element(5291)
    let controlBar = builder.element(5292)
    let barSlider = builder.element(5293)
    let beatSlider = builder.element(5294)
    let playheadPosition = builder.element(5295)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [playheadPosition])
    builder.setAttribute(playheadPosition, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(playheadPosition, kAXDescriptionAttribute as String, "Playhead Position")
    builder.setChildren(playheadPosition, includeBeatSlider ? [barSlider, beatSlider] : [barSlider])
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
        performActionHandler: { _, _ in true },
        executeAppleScript: executeAppleScript
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
    @Test("locale is decided by non-actuating reads before one resolved leaf is issued")
    func localeIsDecidedBeforeSingleResolvedLeafIsIssued() throws {
        // Mutation this rejects: restore either intermediate menu-bar/submenu click, or replace
        // either full leaf path with an object selected by a prior click. Both let a menu-bar click
        // block the script before the Go To Position dialog can open.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let koreanDecision = try issue529Position(
            of: "if exists menu item \"위치…\"",
            in: script
        )
        let englishDecision = try issue529Position(
            of: "else if exists menu item \"Position…\"",
            in: script
        )
        let enabledRead = try issue529Position(
            of: "set menuItemEnabled to enabled of menu item \"위치…\"",
            in: script
        )
        let koreanLeaf = try issue529Position(
            of: "click menu item \"위치…\" of menu 1 of menu item \"이동\" of menu 1 of menu bar item \"탐색\" of menu bar 1",
            in: script
        )
        let englishLeaf = try issue529Position(
            of: "click menu item \"Position…\" of menu 1 of menu item \"Go To\" of menu 1 of menu bar item \"Navigate\" of menu bar 1",
            in: script
        )

        #expect(koreanDecision < englishDecision)
        #expect(englishDecision < enabledRead)
        #expect(enabledRead < koreanLeaf)
        #expect(koreanLeaf < englishLeaf)
        #expect(!script.contains("click menu bar item"))
        #expect(!script.contains("selectedMenuBarItem"))
        #expect(!script.contains("selectedSubmenuItem"))
        #expect(!script.contains("menuItemOpenedAfterClick"))
    }

    @Test("the dialog-ready poll remains the authority after the resolved leaf click")
    func resolvedLeafClickIsFollowedByDialogReadyPoll() throws {
        // Mutation this rejects: remove the bounded exact-dialog poll, or put dialog input before
        // it. The leaf can issue successfully while Logic has not rendered the modal yet.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let leafClick = try issue529Position(
            of: "click menu item \"위치…\" of menu 1 of menu item \"이동\" of menu 1 of menu bar item \"탐색\" of menu bar 1",
            in: script
        )
        let readyPoll = try issue529Position(
            of: "repeat 30 times",
            in: script
        )
        let input = try issue529Position(
            of: "keystroke \"529.1.1.1\"",
            in: script
        )

        #expect(leafClick < readyPoll)
        #expect(readyPoll < input)
    }

    @Test("entry cleanup runs before locale discovery or menu actuation")
    func entryTimeCleanupPrecedesMenuWork() throws {
        // Mutation this rejects: move entry cleanup below either locale resolution or the resolved
        // leaf click, allowing a stale menu to leak into this request's only menu actuation.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryCleanup = try issue529Position(
            of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)",
            in: script
        )
        let firstOperationalDelay = try issue529Position(of: "delay 0.2", in: script)
        let localeDecision = try issue529Position(of: "if exists menu item \"위치…\"", in: script)
        let leafClick = try issue529Position(
            of: "click menu item \"위치…\" of menu 1 of menu item \"이동\" of menu 1 of menu bar item \"탐색\" of menu bar 1",
            in: script
        )

        #expect(entryCleanup < firstOperationalDelay)
        #expect(entryCleanup < localeDecision)
        #expect(entryCleanup < leafClick)
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

    @Test("cleanup after the resolved leaf is marked as an attempted menu write")
    func resolvedLeafClickMarksSubsequentCleanupAsAttempted() throws {
        // Mutation this rejects: move the attempt marker after the leaf or remove it, which makes
        // a leaf-error cleanup claim the menu was never actuated.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let attempted = try issue529Position(of: "set menuActuationAttempted to true", in: script)
        let leafClick = try issue529Position(
            of: "click menu item \"위치…\" of menu 1 of menu item \"이동\" of menu 1 of menu bar item \"탐색\" of menu bar 1",
            in: script
        )
        let leafErrorHandlerEnd = try issue529Position(of: "-- Wait up to 3s for a new exact modal dialog", in: script)
        let leafErrorHandler = String(script[leafClick..<leafErrorHandlerEnd])
        let cleanupAfterMenuItemClick = try issue529Position(
            of: "set cleanupState to my dismissOpenMenu(logicProcess, true)", in: leafErrorHandler
        )
        let refusalContextAfterMenuItemClick = try issue529Position(
            of: "my menuCleanupActuationContext(menuActuationAttempted)", in: leafErrorHandler
        )

        #expect(attempted < leafClick)
        #expect(leafClick < leafErrorHandlerEnd)
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
        // Mutation this rejects: classify OPEN_UNKNOWN_SUBROLE cleanup as CLOSED (or otherwise
        // treat this leaf failure as clean navigation), letting an unrecognised titled modal fall
        // through to the slider while it remains open.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (OPEN_UNKNOWN_SUBROLE)"}"#)
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

    @Test("a clean leaf-only failure does not invent an AX slider route")
    func cleanLeafActuationFailureDoesNotInventSliderRoute() async throws {
        // Source mutation: restore `via:"slider"` or `error:.axWriteFailed` in the no-route
        // receipt. The dialog failure did not resolve or write a slider, so this must fail.
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
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["error"] as? String) == "not_supported")
        #expect(try #require(envelope["position_route"] as? String) == "unavailable")
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(envelope["via"] == nil)
        #expect(sliderWrites.value == 0)
    }

    @Test("a dead child after the durable leaf checkpoint is indeterminate and cannot select the slider")
    func deadChildAfterLeafCheckpointDoesNotClaimSubmissionOrReleaseSlider() async throws {
        // Mutations this rejects:
        // 1. Remove the parent-owned `LEAF_ARMED` ledger checkpoint or ignore it in the `.error`
        //    branch — this clean-reconciliation fixture falls through to the slider.
        // 2. Source mutation: set `dialog_submission_attempted:true` / `write_attempted:true`
        //    for LEAF_ARMED. The marker precedes the leaf click, so it cannot prove submission.
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
        let writeAttempted = envelope["write_attempted"] as? Bool
        let submissionAttempted = envelope["dialog_submission_attempted"] as? Bool
        #expect(writeAttempted == nil)
        #expect(submissionAttempted == nil)
        #expect(try #require(envelope["dialog_submission_indeterminate"] as? Bool))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(sliderWrites.value == 0)
    }

    @Test("a dead child with a corrupt dialog ledger reports possible global input")
    func deadChildWithUnknownLedgerDoesNotOmitGlobalInputReceipt() async throws {
        // Mutation this rejects: remove `.executionFailed(issuance: .unknown, ...)` from
        // `globalInputMayHaveOccurred`. A corrupt/truncated ledger cannot prove that Cmd+A or
        // position text was not sent, so its receipt must not claim `write_attempted:false`.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                try! "truncated-before-replacement".write(
                    toFile: ledgerPath,
                    atomically: false,
                    encoding: .utf8
                )
                return .error("osascript was killed while updating the issuance ledger")
            },
            reconcileAfterDialogExecutionFailure: { true }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "execution_failed_issuance_unknown_cleanup_closed_true")
        #expect(try #require(envelope["dialog_input_attempted"] as? Bool))
        #expect(try #require(envelope["dialog_input_boundary"] as? String) == "unknown")
        #expect(try #require(envelope["dialog_input_target"] as? String) == "unknown")
        #expect(try #require(envelope["write_attempted"] as? Bool))
        #expect(try #require(envelope["dialog_submission_indeterminate"] as? Bool))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(sliderWrites.value == 0)
    }

    @Test("default dead-child reconciliation stays on the injected runtime seam")
    func defaultDeadChildReconciliationUsesInjectedRuntime() async throws {
        // Source mutation: call `AppleScriptChannel.executeAppleScript` directly from
        // `observeAndClearStrayGoToPositionUI`. This fake runtime would see no reconciliation
        // script, proving the default failure path escaped the test/runtime seam.
        let sliderWrites = Issue529Counter()
        let reconciliationCalls = Issue529Counter()
        let runtime = issue529SliderRuntime(
            sliderWrites: sliderWrites,
            executeAppleScript: { _ in
                reconciliationCalls.bump()
                return .success(#"{"result":"CLOSED"}"#)
            }
        )
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: runtime,
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in .error("osascript timed out before any ledger boundary") }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "execution_failed_issuance_NOT_ISSUED_cleanup_closed_true")
        #expect(reconciliationCalls.value == 1)
        #expect(sliderWrites.value == 0)
    }

    @Test("an existing dialog or focus loss refuses before a position submission")
    func preexistingDialogAndFocusLossDoNotSubmitPosition() async throws {
        // Source mutations: classify DIALOG_PREEXISTING as a clean fallback, or classify
        // DIALOG_SUBMISSION_NOT_ISSUED as issued. Either lets another run's dialog receive a
        // position write or falsely reports that this focus-loss fixture submitted one.
        let preexisting = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: Issue529Counter()),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_PREEXISTING: fixture dialog belongs to another request"}"#)
            }
        )
        let preexistingEnvelope = try #require(issue529Envelope(preexisting))
        #expect(!preexisting.isSuccess)
        #expect(try #require(preexistingEnvelope["state"] as? String) == "C")
        #expect(try #require(preexistingEnvelope["fallback_unsafe"] as? Bool))
        let preexistingWrite = try #require(preexistingEnvelope["write_attempted"] as? Bool)
        #expect(!preexistingWrite)

        let focusLoss = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: Issue529Counter()),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_SUBMISSION_NOT_ISSUED: observed Go To Position dialog was not focused before typing (NOT_FOCUSED)"}"#)
            }
        )
        let focusLossEnvelope = try #require(issue529Envelope(focusLoss))
        #expect(!focusLoss.isSuccess)
        #expect(try #require(focusLossEnvelope["state"] as? String) == "C")
        let focusLossWrite = try #require(focusLossEnvelope["write_attempted"] as? Bool)
        #expect(!focusLossWrite)
        #expect(focusLossEnvelope["dialog_submission_attempted"] == nil)
    }

    @Test("a concurrent Go To Position request is refused before its leaf protocol begins")
    func concurrentDialogRequestCannotShareTheObservedModal() async throws {
        // Source mutation: remove GoToPositionDialogExecutionLock acquisition, or take it after
        // executing the dialog script. The contender then reaches its injected script instead of
        // refusing before any menu leaf can be issued.
        let gate = Issue529DialogLockGate()
        let firstScriptCalls = Issue529Counter()
        let contenderScriptCalls = Issue529Counter()
        let firstRuntime = issue529SliderRuntime(
            sliderWrites: Issue529Counter(),
            executeAppleScript: { _ in
                firstScriptCalls.bump()
                await gate.entered()
                await gate.waitForRelease()
                return .success(#"{"result":"MENU_NOT_FOUND"}"#)
            }
        )
        let contenderRuntime = issue529SliderRuntime(
            sliderWrites: Issue529Counter(),
            executeAppleScript: { _ in
                contenderScriptCalls.bump()
                return .success(#"{"result":"MENU_NOT_FOUND"}"#)
            }
        )

        async let first = AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"], runtime: firstRuntime,
            isFrontmost: { true }, activateLogic: { true }, sleepMicros: { _ in }
        )
        await gate.waitUntilEntered()
        let contender = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "530"], runtime: contenderRuntime,
            isFrontmost: { true }, activateLogic: { true }, sleepMicros: { _ in }
        )
        await gate.release()
        _ = await first

        let contenderEnvelope = try #require(issue529Envelope(contender))
        #expect(!contender.isSuccess)
        #expect(try #require(contenderEnvelope["error"] as? String) == "mutating_operation_in_progress")
        #expect(firstScriptCalls.value == 1)
        #expect(contenderScriptCalls.value == 0)
    }

    @Test("global-input and Return boundaries suppress a clean retry")
    func inputAndReturnIssuanceAreReportedAsUnsafe() async throws {
        // Source mutations: remove either SELECT_ALL_ARMED/POSITION_INPUT_ARMED checkpoint, or
        // classify DIALOG_INPUT_ISSUED as a clean non-submission failure. The first leaves a
        // timeout gap; the second returns State C with `write_attempted:false` after global input.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let selectAllLedger = try issue529Position(
            of: "recordDialogIssuance(\"SELECT_ALL_ARMED\"",
            in: script
        )
        let selectAll = try issue529Position(of: "keystroke \"a\" using command down", in: script)
        let positionInputLedger = try issue529Position(
            of: "recordDialogIssuance(\"POSITION_INPUT_ARMED\"",
            in: script
        )
        let positionInput = try issue529Position(of: "keystroke \"529.1.1.1\"", in: script)
        let returnLedger = try issue529Position(
            of: "recordDialogIssuance(\"RETURN_ARMED\"",
            in: script
        )
        let returnKey = try issue529Position(of: "keystroke return", in: script)
        #expect(selectAllLedger < selectAll)
        #expect(selectAll < positionInputLedger)
        #expect(positionInputLedger < positionInput)
        #expect(positionInput < returnLedger)
        #expect(returnLedger < returnKey)

        let preInputSliderWrites = Issue529Counter()
        let preInput = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: preInputSliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_SUBMISSION_NOT_ISSUED: observed Go To Position dialog was not focused before typing (NOT_FOCUSED)"}"#)
            }
        )
        let preInputEnvelope = try #require(issue529Envelope(preInput))
        #expect(!preInput.isSuccess)
        #expect(try #require(preInputEnvelope["state"] as? String) == "C")
        #expect(try #require(preInputEnvelope["position_route"] as? String) == "unavailable")
        let preInputWriteAttempted = try #require(preInputEnvelope["write_attempted"] as? Bool)
        #expect(!preInputWriteAttempted)
        #expect(preInputSliderWrites.value == 0)

        let inputSliderWrites = Issue529Counter()
        let input = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: inputSliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: position text may have been sent (AX error)"}"#)
            }
        )
        let inputEnvelope = try #require(issue529Envelope(input))
        #expect(input.isSuccess)
        #expect(try #require(inputEnvelope["state"] as? String) == "B")
        #expect(try #require(inputEnvelope["dialog_input_attempted"] as? Bool))
        #expect(try #require(inputEnvelope["dialog_input_boundary"] as? String) == "POSITION_INPUT_ARMED")
        #expect(try #require(inputEnvelope["dialog_input_target"] as? String) == "unknown")
        #expect(try #require(inputEnvelope["write_attempted"] as? Bool))
        #expect(!(try #require(inputEnvelope["safe_to_retry"] as? Bool)))
        #expect(try #require(inputEnvelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(inputEnvelope["dialog_submission_attempted"] as? Bool)))
        #expect(inputSliderWrites.value == 0)

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

    @Test("a menu-not-found dialog result does not issue the relative slider")
    func menuNotFoundDoesNotIssueRelativeSlider() async throws {
        // Mutation this rejects: restore the old slider AXValue write after `MENU_NOT_FOUND`, which
        // moves the playhead by one bar instead of expressing the requested absolute position, or
        // drop `dialog_route_outcome` and hide why the dialog did not drive.
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
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["error"] as? String) == "not_supported")
        #expect(try #require(envelope["position_route"] as? String) == "unavailable")
        #expect(try #require(envelope["dialog_route_outcome"] as? String) == "menu_not_found")
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(sliderWrites.value == 0)
    }

    @Test("a reachable bar and beat slider still cannot express an absolute position")
    func relativeSliderDoesNotCertifyOrIssueTheRequestedPosition() async throws {
        // Mutation this rejects: set `kAXValueAttribute` on either Playhead Position component.
        // The measured bar control increments relatively; no guessed mapping may turn it into an
        // absolute-position write, even when the `beat` slider is reachable.
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
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["requested"] as? String) == "529.4.1.1")
        let unobserved = try #require(envelope["unobserved_position_components"] as? [String])
        #expect(unobserved == ["bar", "beat", "subdivision", "tick"])
        let unexpressed = try #require(envelope["unexpressed_position_components"] as? [String])
        #expect(unexpressed == ["bar", "beat", "subdivision", "tick"])
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(try #require(envelope["position_route"] as? String) == "unavailable")
        #expect(sliderWrites.value == 0)
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
        // Mutations this rejects: move either persistent checkpoint after its corresponding click
        // or key event, or restore a direct `printf > ledgerPath` replacement. The former recreates
        // a no-record timeout window; the latter can truncate the prior conservative marker before
        // the replacement becomes durable.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(
            position: "529.4.1.1",
            issuanceLedgerPath: "/private/tmp/issue529-ledger"
        )
        let leafCheckpoint = try issue529Position(
            of: "recordDialogIssuance(\"LEAF_ARMED\"", in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item \"위치…\" of menu 1 of menu item \"이동\" of menu 1 of menu bar item \"탐색\" of menu bar 1",
            in: script
        )
        let returnCheckpoint = try issue529Position(
            of: "recordDialogIssuance(\"RETURN_ARMED\"", in: script
        )
        let returnKey = try issue529Position(of: "keystroke return", in: script)
        let ledgerHandlerStart = try issue529Position(
            of: "on recordDialogIssuance(stage, ledgerPath)", in: script
        )
        let ledgerHandlerEnd = try issue529Position(
            of: "end recordDialogIssuance", in: script
        )
        let ledgerHandler = String(script[ledgerHandlerStart..<ledgerHandlerEnd])
        let temporaryLedger = try issue529Position(of: "set temporaryLedgerPath to do shell script", in: ledgerHandler)
        let stagedWrite = try issue529Position(of: "quoted form of temporaryLedgerPath", in: ledgerHandler)
        let atomicRename = try issue529Position(of: "&& /bin/mv -f", in: ledgerHandler)

        #expect(leafCheckpoint < leafClick)
        #expect(returnCheckpoint < returnKey)
        #expect(temporaryLedger < stagedWrite)
        #expect(stagedWrite < atomicRename)
        #expect(ledgerHandler.contains("ledgerPath & \".tmp.XXXXXX\""))
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

/// Before this run issues its resolved leaf, an unreadable menu read must withhold Escape rather
/// than sending it into unknown focus. Locale discovery itself owns no menu actuation.
@Test("locale discovery stays unowned until the resolved leaf issuance boundary")
func dismissalContextKeepsLocaleReadsUnownedUntilResolvedLeafIssuance() throws {
    // Source mutations: change any of the AXEnabled-read, disabled-entry, or LEAF_ARMED-write
    // failure cleanups to `dismissOpenMenu(logicProcess, true)`. Each is before this run's leaf,
    // so UNREADABLE must withhold Escape from unrelated focus.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)

    // Entry, locale discovery, enabled/disabled handling, and a failed durable checkpoint are all
    // unowned until the resolved leaf is actually issued.
    #expect(issue529Positions(of: "my dismissOpenMenu(logicProcess, false)", in: script).count == 6)

    let leafCheckpoint = try issue529Position(
        of: "recordDialogIssuance(\"LEAF_ARMED\"",
        in: script
    )
    let resolvedLeaf = try issue529Position(
        of: "click menu item \"위치…\" of menu 1 of menu item \"이동\" of menu 1 of menu bar item \"탐색\" of menu bar 1",
        in: script
    )
    #expect(leafCheckpoint < resolvedLeaf)
    let preLeaf = String(script[..<resolvedLeaf])
    #expect(!preLeaf.contains("my dismissOpenMenu(logicProcess, true)"))
    #expect(!script.contains("click selectedMenuBarItem"))
    #expect(!script.contains("click selectedSubmenuItem"))

    // The handler itself only skips Escape when no menu has been established as this run's.
    #expect(script.contains("if menuState is \"UNREADABLE\" and not knownOpen then return \"UNREADABLE\""))
}

@Test("the Go To Position dialog is newly observed and focus-bound before global typing")
func gotoPositionDialogRequiresAppearanceTransitionAndFocusedBinding() throws {
    // Mutations this rejects: remove AXFloatingWindow or AXModal from the known input class,
    // collapse OPEN_UNKNOWN_SUBROLE to CLOSED, remove the global `frontmost` recheck, restore a
    // title/AXFocused fallback for AXFocusedWindow identity, or move any global key before its
    // post-marker focus guard. Any one either rejects the measured dialog or lets a stale,
    // non-modal, or newly frontmost application receive this request's input.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(position: "529.4.7.123")
    let preLeafObservation = try issue529Position(
        of: "set preLeafGoToPositionDialogState to my goToPositionDialogState(logicProcess)",
        in: script
    )
    let preLeafAbsenceGuard = try issue529Position(
        of: "if preLeafGoToPositionDialogState is not \"CLOSED\" then",
        in: script
    )
    let leafClick = try issue529Position(
        of: "click menu item \"위치…\" of menu 1 of menu item \"이동\" of menu 1 of menu bar item \"탐색\" of menu bar 1",
        in: script
    )
    let observedDialog = try issue529Position(
        of: "set observedGoToPositionDialog to my matchingGoToPositionDialog(logicProcess)",
        in: script
    )
    let selectAllLedger = try issue529Position(
        of: "recordDialogIssuance(\"SELECT_ALL_ARMED\"", in: script
    )
    let focusGuard = try issue529Position(
        of: "set dialogFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)",
        in: script
    )
    let focusRefusal = try issue529Position(
        of: "observed Go To Position dialog was not focused before typing",
        in: script
    )
    let selectAll = try issue529Position(of: "keystroke \"a\" using command down", in: script)
    let positionInputLedger = try issue529Position(
        of: "recordDialogIssuance(\"POSITION_INPUT_ARMED\"", in: script
    )
    let typingFocusGuard = try issue529Position(
        of: "set dialogTypingFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)",
        in: script
    )
    let positionInput = try issue529Position(of: "keystroke \"529.4.7.123\"", in: script)
    let returnLedger = try issue529Position(of: "recordDialogIssuance(\"RETURN_ARMED\"", in: script)
    let returnFocusGuard = try issue529Position(
        of: "set dialogReturnFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)",
        in: script
    )
    let returnKey = try issue529Position(of: "keystroke return", in: script)
    let focusHandlerStart = try issue529Position(
        of: "on observedGoToPositionDialogFocusState(theProcess, dialogWindow)", in: script
    )
    let focusHandlerEnd = try issue529Position(
        of: "end observedGoToPositionDialogFocusState", in: script
    )
    let focusHandler = String(script[focusHandlerStart..<focusHandlerEnd])
    let globalFocusRead = try issue529Position(of: "set logicIsFrontmost to frontmost", in: focusHandler)
    let focusedWindowRead = try issue529Position(
        of: "set processFocusedWindow to value of attribute \"AXFocusedWindow\"", in: focusHandler
    )
    let dialogStateHandlerStart = try issue529Position(of: "on goToPositionDialogState(theProcess)", in: script)
    let dialogStateHandlerEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
    let dialogStateHandler = String(script[dialogStateHandlerStart..<dialogStateHandlerEnd])

    #expect(preLeafObservation < preLeafAbsenceGuard)
    #expect(preLeafAbsenceGuard < leafClick)
    #expect(leafClick < observedDialog)
    #expect(observedDialog < selectAllLedger)
    #expect(selectAllLedger < focusGuard)
    #expect(focusGuard < focusRefusal)
    #expect(focusRefusal < selectAll)
    #expect(selectAll < positionInputLedger)
    #expect(positionInputLedger < typingFocusGuard)
    #expect(typingFocusGuard < positionInput)
    #expect(positionInput < returnLedger)
    #expect(returnLedger < returnFocusGuard)
    #expect(returnFocusGuard < returnKey)
    #expect(globalFocusRead < focusedWindowRead)
    #expect(focusHandler.contains("if logicIsFrontmost is not true then return \"NOT_FRONTMOST\""))
    #expect(focusHandler.contains("set dialogIsModal to value of attribute \"AXModal\" of dialogWindow"))
    #expect(focusHandler.contains("if processFocusedWindow is dialogWindow then return \"FOCUSED\""))
    #expect(!focusHandler.contains("name of processFocusedWindow"))
    #expect(!focusHandler.contains("if focused of dialogWindow"))
    #expect(dialogStateHandler.contains("if not my knownGoToPositionDialogSubrole(dialogSubrole) then return \"OPEN_UNKNOWN_SUBROLE\""))
    #expect(dialogStateHandler.contains("set dialogIsModal to value of attribute \"AXModal\" of dialogWindow"))
    #expect(dialogStateHandler.contains("return \"OPEN_UNVERIFIED_MODALITY\""))
}

@Test("an unreadable Cancel result re-observes the dialog before Escape")
func unreadableCancelDoesNotAuthoriseEscapeWithoutDialogObservation() throws {
    // Mutation this rejects: move `key code 53` directly after an `UNREADABLE` Cancel result,
    // bypassing either the fresh `goToPositionDialogState` observation or the immediate
    // frontmost-plus-AXFocusedWindow guard for the exact dialog.
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
    let cleanupDialogBinding = try issue529Position(
        of: "set cleanupDialogWindow to my matchingGoToPositionDialog(theProcess)", in: unreadableBranch
    )
    let cleanupFocusGuard = try issue529Position(
        of: "set cleanupDialogFocusState to my observedGoToPositionDialogFocusState(theProcess, cleanupDialogWindow)",
        in: unreadableBranch
    )
    let escape = try issue529Position(of: "key code 53", in: unreadableBranch)

    #expect(reobservation < closedGuard)
    #expect(closedGuard < unreadableGuard)
    #expect(unreadableGuard < stillOpenGuard)
    #expect(stillOpenGuard < cleanupDialogBinding)
    #expect(cleanupDialogBinding < cleanupFocusGuard)
    #expect(cleanupFocusGuard < escape)
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
    let helperStart = try #require(source.range(of: "private static func observeAndClearStrayGoToPositionUI("))
    let helperEnd = try #require(source.range(of: "// MARK: - Control-bar checkbox helpers"))
    let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
    let dialogObservation = try issue529Position(of: "on goToPositionDialogState(theProcess)", in: helper)
    let dialogCleanup = try issue529Position(of: "set dialogCleanupState to my dismissGoToPositionDialog(it)", in: helper)
    let menuLoop = try issue529Position(of: "repeat with menuBarItem in every menu bar item", in: helper)

    #expect(dialogObservation < dialogCleanup)
    #expect(dialogCleanup < menuLoop)
    #expect(!helper.contains("ProcessUtils.logicProPID"))
}
