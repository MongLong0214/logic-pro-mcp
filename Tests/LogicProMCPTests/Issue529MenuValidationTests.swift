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

private final class Issue529StringBox: @unchecked Sendable {
    private(set) var value: String?

    func set(_ value: String) {
        self.value = value
    }
}

/// Bridges the real AX Go To Position route into ChannelRouter while retaining the script-result
/// seam. This lets the adversarial fixtures prove both that their script response was consumed and
/// that the router did not release CGEvent's `/` + position + Return sequence.
private actor Issue529DialogFixtureChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private let scriptResult: String
    private let scriptExecutions: Issue529Counter
    private let sliderWrites: Issue529Counter

    init(
        scriptResult: String,
        scriptExecutions: Issue529Counter,
        sliderWrites: Issue529Counter
    ) {
        self.scriptResult = scriptResult
        self.scriptExecutions = scriptExecutions
        self.sliderWrites = sliderWrites
    }

    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "dialog fixture") }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        let scriptResult = scriptResult
        let scriptExecutions = scriptExecutions
        return await AccessibilityChannel.gotoPositionViaBarSlider(
            params: params,
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                scriptExecutions.bump()
                return .success(#"{"result":"\#(scriptResult)"}"#)
            }
        )
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

private func issue529PreexistingDialogRuntime(
    reconciliationCalls: Issue529Counter
) -> (builder: FakeAXRuntimeBuilder, runtime: AXLogicProElements.Runtime, cancel: AXUIElement) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(52_901)
    let projectWindow = builder.element(52_902)
    let dialogWindow = builder.element(52_903)
    let cancel = builder.element(52_904)

    builder.setAttribute(app, kAXMainWindowAttribute as String, projectWindow)
    builder.setAttribute(app, kAXWindowsAttribute as String, [projectWindow, dialogWindow])
    builder.setAttribute(projectWindow, kAXModalAttribute as String, false)
    builder.setAttribute(dialogWindow, kAXTitleAttribute as String, "Go To Position")
    builder.setAttribute(dialogWindow, kAXSubroleAttribute as String, kAXFloatingWindowSubrole as String)
    builder.setAttribute(dialogWindow, kAXModalAttribute as String, true)
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setChildren(dialogWindow, [cancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: nil,
        executeAppleScript: { _ in
            reconciliationCalls.bump()
            return .success(#"{"result":"CLOSED"}"#)
        }
    )
    return (builder, runtime, cancel)
}

@Suite("Issue #529 — Go To Position menu validation")
struct Issue529MenuValidationTests {
    @Test("locale is decided by non-actuating reads before one resolved leaf is issued")
    func localeIsDecidedBeforeSingleResolvedLeafIsIssued() throws {
        // Mutation this rejects: restore either intermediate menu-bar/submenu click, or replace
        // either full leaf path with an object selected by a prior click. Both let a menu-bar click
        // block the script before the Go To Position dialog can open.
        //
        // #519: the bar/item/leaf names are each resolved from an AXLocalePolicy LabelSet
        // (canonical first, then variants) instead of a hard-coded EN/KO literal branch pair, so
        // the three read-only candidate loops below (bar, then "Go To", then "Position…") replace
        // the old koreanDecision/englishDecision two-branch check.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        // Candidate lists are derived from the LabelSets rather than spelled out: a measured label
        // added to AXLocalePolicy must not break an ordering test that is about ordering.
        func candidateList(_ set: AXLocalePolicy.LabelSet) -> String {
            "repeat with candidate in {" + set.labels.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        }
        let barResolution = try issue529Position(
            of: candidateList(AXLocalePolicy.navigateMenuBar),
            in: script
        )
        let itemResolution = try issue529Position(
            of: candidateList(AXLocalePolicy.goToMenuItem),
            in: script
        )
        let leafResolution = try issue529Position(
            of: candidateList(AXLocalePolicy.goToPositionMenuItem),
            in: script
        )
        let enabledRead = try issue529Position(
            of: "set menuItemEnabled to enabled of menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )

        #expect(barResolution < itemResolution)
        #expect(itemResolution < leafResolution)
        #expect(leafResolution < enabledRead)
        #expect(enabledRead < leafClick)
        #expect(!script.contains("click menu bar item"))
        #expect(!script.contains("selectedMenuBarItem"))
        #expect(!script.contains("selectedSubmenuItem"))
        #expect(!script.contains("menuItemOpenedAfterClick"))
    }

    @Test("the reviewed Japanese Go To Position title is an exact operable dialog title")
    func japaneseGoToPositionTitleIsCoveredInBothDialogObservers() throws {
        // Mutation this rejects: remove `dialogTitle is "位置の移動"` from either title predicate.
        // This issue covers the exact JA modal title plus its existing キャンセル dismissal path;
        // it does not claim Japanese Navigate-menu routing or a general locale policy (#519).
        let writeScript = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/LogicProMCPTests/Issue529MenuValidationTests.swift",
                with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Transport.swift"
            ),
            encoding: .utf8
        )
        let titlePredicateOccurrences = issue529Positions(
            of: "dialogTitle is \"位置の移動\"", in: source
        )

        #expect(writeScript.contains("dialogTitle is \"位置の移動\""))
        #expect(writeScript.contains("button \"キャンセル\""))
        #expect(titlePredicateOccurrences.count == 2, "write and timeout observers must agree on the exact JA title")
    }

    @Test("the dialog-ready poll remains the authority after the resolved leaf click")
    func resolvedLeafClickIsFollowedByDialogReadyPoll() throws {
        // Mutation this rejects: remove the bounded exact-dialog poll, or put dialog input before
        // it. The leaf can issue successfully while Logic has not rendered the modal yet.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
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
        let localeDecision = try issue529Position(
            of: "repeat with candidate in {"
                + AXLocalePolicy.navigateMenuBar.labels.map { "\"\($0)\"" }.joined(separator: ", ")
                + "}",
            in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
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
        let localeDecision = try issue529Position(
            of: "repeat with candidate in {"
                + AXLocalePolicy.navigateMenuBar.labels.map { "\"\($0)\"" }.joined(separator: ", ")
                + "}",
            in: script
        )

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
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
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

    @Test("a leaf click that may have opened an unidentified dialog never releases CGEvent")
    func leafActuationFailureAfterOpeningDialogDoesNotRouteToCGEvent() async throws {
        // Mutation this rejects: remove the `dialogActuationIssued(cleanupObservedClosed: false)`
        // unsafe-UI classification. The fixture is the leaf's AX error after the total-window
        // observation saw a new, unidentifiable dialog. Its reply must remain terminal: reaching
        // CGEvent would post `/`, the position text, and Return into that still-open dialog.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let leafFailureBlock = String(script[leafClick...])
        let leafError = try issue529Position(of: "on error errMsg", in: leafFailureBlock)
        let cleanup = try issue529Position(
            of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: leafFailureBlock
        )
        let cleanupRefusal = try issue529Position(
            of: "if dialogCleanupState is not \"CLOSED\" then", in: leafFailureBlock
        )
        let dialogStateStart = try issue529Position(
            of: "on goToPositionDialogState(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: script
        )
        let dialogStateEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
        let dialogState = String(script[dialogStateStart..<dialogStateEnd])
        #expect(leafError < cleanup)
        #expect(cleanup < cleanupRefusal)
        #expect(dialogState.contains("if dialogWindow is missing value then"))
        #expect(dialogState.contains("return my observedGoToPositionDialogClosure(theProcess, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)"))

        let scriptExecutions = Issue529Counter()
        let sliderWrites = Issue529Counter()
        let accessibility = Issue529DialogFixtureChannel(
            scriptResult: "DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (UNIDENTIFIED)",
            scriptExecutions: scriptExecutions,
            sliderWrites: sliderWrites
        )
        let cgEventRecorder = CGEventRecorder()
        let cgEvent = CGEventChannel(runtime: .init(
            isLogicProRunning: { true },
            logicProPID: { 529 },
            postKeyEvent: { keyCode, flags, pid in
                cgEventRecorder.post(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { _ in }
        ))
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.register(cgEvent)

        let result = await router.route(
            operation: "transport.goto_position",
            params: ["position": "529.1.1.1"]
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "dialog_actuation_issued_cleanup_closed_false")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the leaf-error reply")
        #expect(sliderWrites.value == 0)
        #expect(cgEventRecorder.snapshot().isEmpty, "CGEvent must not receive the fallback sequence")
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

    @Test("an unrecognised localized dialog title is terminal and cannot release another position route")
    func unidentifiedNewWindowDoesNotProduceRouterContinuableResult() async throws {
        // Mutation this rejects: treat an unmatched title as “not present”, restore the old `dialog
        // did not become ready` result, or remove this classification from the unsafe-UI refusal.
        // #519 still owns locale support; this fixture pins the narrower promise that a title we
        // cannot match is honestly reported as unidentified rather than absent.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        #expect(script.contains("on newWindowAppearedSince(theProcess, preLeafGoToPositionWindowCount)"))
        #expect(script.contains("return \"DIALOG_UNIDENTIFIED_NEW_WINDOW\""))

        let sliderWrites = Issue529Counter()
        let scriptExecutions = Issue529Counter()
        let accessibility = Issue529DialogFixtureChannel(
            scriptResult: "DIALOG_UNIDENTIFIED_NEW_WINDOW: localized title not in the measured whitelist",
            scriptExecutions: scriptExecutions,
            sliderWrites: sliderWrites
        )
        let cgEventRecorder = CGEventRecorder()
        let cgEvent = CGEventChannel(runtime: .init(
            isLogicProRunning: { true },
            logicProPID: { 529 },
            postKeyEvent: { keyCode, flags, pid in
                cgEventRecorder.post(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { _ in }
        ))
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.register(cgEvent)
        let result = await router.route(
            operation: "transport.goto_position",
            params: ["position": "529.1.1.1"]
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "dialog_unidentified_new_window")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
        #expect(HonestContract.isFallbackUnsafeStateC(result.message))
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the unrecognised-title reply")
        #expect(sliderWrites.value == 0)
        #expect(cgEventRecorder.snapshot().isEmpty, "CGEvent must not receive the localized-dialog fallback")
    }

    @Test("a menu result that never observed dialogs cannot release CGEvent")
    func uninspectedDialogPreflightFailuresDoNotRouteToCGEvent() async throws {
        // Mutation this rejects: change `if !performedDialogSafetyObservation { return true }`
        // to return false. Each script reply exits before either pre-leaf dialog/window count, so
        // it cannot answer that no modal is open. The recorder would otherwise receive `/`, digits,
        // and Return globally. Running all three proves every classifier seam reaches this gate.
        for (scriptResult, diagnostic) in [
            ("MENU_NOT_FOUND", "menu_not_found"),
            ("MENU_DISABLED", "menu_disabled"),
            ("MENU_STATE_UNREADABLE", "menu_state_unreadable"),
        ] {
            let scriptExecutions = Issue529Counter()
            let sliderWrites = Issue529Counter()
            let accessibility = Issue529DialogFixtureChannel(
                scriptResult: scriptResult,
                scriptExecutions: scriptExecutions,
                sliderWrites: sliderWrites
            )
            let cgEventRecorder = CGEventRecorder()
            let cgEvent = CGEventChannel(runtime: .init(
                isLogicProRunning: { true },
                logicProPID: { 529 },
                postKeyEvent: { keyCode, flags, pid in
                    cgEventRecorder.post(keyCode: keyCode, flags: flags, pid: pid)
                },
                sleepMicros: { _ in }
            ))
            let router = ChannelRouter()
            await router.register(accessibility)
            await router.register(cgEvent)
            let result = await router.route(
                operation: "transport.goto_position",
                params: ["position": "5.1.1.1"]
            )

            let envelope = try #require(issue529Envelope(result))
            #expect(!result.isSuccess, "\(scriptResult) must remain terminal")
            #expect(try #require(envelope["state"] as? String) == "C")
            #expect(try #require(envelope["dialog_route_outcome"] as? String) == diagnostic)
            #expect(try #require(envelope["fallback_unsafe"] as? Bool))
            #expect(!(try #require(envelope["write_attempted"] as? Bool)))
            #expect(scriptExecutions.value == 1, "fixture seam must deliver \(scriptResult)")
            #expect(sliderWrites.value == 0)
            #expect(cgEventRecorder.snapshot().isEmpty, "\(scriptResult) must not release CGEvent")
        }
    }

    @Test("an unreadable post-leaf total-window count is terminal rather than clean actuation")
    func unreadableDialogAppearanceDoesNotReleaseAnotherPositionRoute() async throws {
        // Mutation this rejects: restore the old DIALOG_ACTUATION_ISSUED “appearance became
        // unreadable” reply, which the classifier treated as cleanup observed closed. A failed
        // count did not answer whether the leaf opened a dialog, so no later route may type.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let unreadableRefusal = try issue529Position(
            of: "if dialogAppearanceUnreadable then return \"DIALOG_APPEARANCE_UNREADABLE\"",
            in: script
        )
        let cleanup = try #require(
            issue529Positions(of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(", in: script)
                .first(where: { unreadableRefusal < $0 })
        )
        #expect(unreadableRefusal < cleanup)

        let sliderWrites = Issue529Counter()
        let scriptExecutions = Issue529Counter()
        let accessibility = Issue529DialogFixtureChannel(
            scriptResult: "DIALOG_APPEARANCE_UNREADABLE",
            scriptExecutions: scriptExecutions,
            sliderWrites: sliderWrites
        )
        let cgEventRecorder = CGEventRecorder()
        let cgEvent = CGEventChannel(runtime: .init(
            isLogicProRunning: { true },
            logicProPID: { 529 },
            postKeyEvent: { keyCode, flags, pid in
                cgEventRecorder.post(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { _ in }
        ))
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.register(cgEvent)
        let result = await router.route(
            operation: "transport.goto_position",
            params: ["position": "529.1.1.1"]
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String) == "dialog_appearance_unreadable")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the unreadable-count reply")
        #expect(sliderWrites.value == 0)
        #expect(cgEventRecorder.snapshot().isEmpty, "CGEvent must not receive the unreadable-count fallback")
    }

    @Test("an unidentified post-Return dialog never emits the ordinary dialog State B")
    func postReturnUnidentifiedDialogCarriesUnsafeVerificationProvenance() async throws {
        // Mutation this rejects: let goToPositionDialogState return CLOSED for a missing reference,
        // `exists false`, or an unrecognised title. The post-Return cleanup reply then lacks the
        // unsafe marker and a coincident playhead can falsely certify State A downstream.
        let scriptExecutions = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["position": "5.1.1.1"],
            runtime: issue529SliderRuntime(sliderWrites: Issue529Counter()),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                scriptExecutions.bump()
                return .success(#"{"result":"DIALOG_SUBMISSION_ISSUED: dialog cleanup was not observed (UNIDENTIFIED)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "dialog_submission_issued_cleanup_closed_false")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(try #require(envelope["dialog_submission_attempted"] as? Bool))
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the post-Return reply")
    }

    @Test("an absent new window retains the clean pre-input State C")
    func noNewWindowStillProducesExistingCleanStateC() async throws {
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_ACTUATION_ISSUED: dialog did not become ready"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["error"] as? String) == "not_supported")
        #expect(try #require(envelope["safe_to_retry"] as? Bool))
        #expect(envelope["fallback_unsafe"] == nil)
        #expect(sliderWrites.value == 0)
    }

    @Test("a clean leaf-only failure does not invent an AX slider route")
    func cleanLeafActuationFailureDoesNotInventSliderRoute() async throws {
        // This requirement remains correct, but its fixture is deliberately narrow: “after
        // observed cleanup” means the post-leaf total-window check proved no new window remained.
        // If the click opened any window, the write script now returns unobserved cleanup instead
        // and the terminal test above applies. Source mutation: restore `via:"slider"` or
        // `error:.axWriteFailed` in the no-route receipt.
        let sliderWrites = Issue529Counter()
        let scriptExecutions = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                scriptExecutions.bump()
                return .success(#"{"result":"DIALOG_ACTUATION_ISSUED: AXPress reported failure after observed cleanup"}"#)
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
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the observed-cleanup reply")
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
        #expect(writeAttempted.map { $0 ? "true" : "false" } == nil)
        #expect(submissionAttempted.map { $0 ? "true" : "false" } == nil)
        #expect(try #require(envelope["dialog_submission_indeterminate"] as? Bool))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(sliderWrites.value == 0)
    }

    @Test("a spawn failure without a ledger reports global input as indeterminate")
    func spawnFailureWithoutLedgerDoesNotOverclaimAGlobalInputAttempt() async throws {
        // Mutation this rejects: return `.attempted` rather than `.indeterminate` for
        // `.executionFailed(issuance: .unknown, ...)`. With ledger creation intentionally failed,
        // this fixture's `spawnFailed` result proves no child or key event existed; uncertainty
        // still suppresses fallback, but must not be serialized as an asserted attempt.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in .error("osascript spawnFailed") },
            reconcileAfterDialogExecutionFailure: { true },
            createDialogIssuanceLedger: { nil }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "execution_failed_issuance_unknown_cleanup_closed_true")
        #expect(try #require(envelope["dialog_input_indeterminate"] as? Bool))
        #expect(try #require(envelope["dialog_input_boundary"] as? String) == "unknown")
        #expect(try #require(envelope["dialog_input_target"] as? String) == "unknown")
        #expect(try #require(envelope["write_attempted_indeterminate"] as? Bool))
        #expect(envelope["dialog_input_attempted"] == nil)
        #expect(envelope["write_attempted"] == nil)
        #expect(try #require(envelope["dialog_submission_indeterminate"] as? Bool))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(sliderWrites.value == 0)
    }

    @Test("parent ledger cleanup removes an orphaned randomized staging file")
    func parentLedgerCleanupRemovesOrphanedTemporaryFile() async throws {
        // Mutation this rejects: remove the sibling-prefix cleanup from
        // `DialogIssuanceLedger.remove()`. This fixture leaves a `.tmp.*` file behind exactly as a
        // killed child can after `mktemp`; the parent must remove it before returning.
        let orphanedTemporaryPath = Issue529StringBox()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: Issue529Counter()),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                let temporaryPath = ledgerPath + ".tmp.orphaned-test"
                try! Data("orphaned".utf8).write(to: URL(fileURLWithPath: temporaryPath))
                orphanedTemporaryPath.set(temporaryPath)
                return .error("osascript terminated after mktemp")
            },
            reconcileAfterDialogExecutionFailure: { true }
        )

        _ = result
        let temporaryPath = try #require(orphanedTemporaryPath.value)
        #expect(!FileManager.default.fileExists(atPath: temporaryPath))
    }

    @Test("a timeout without a pre-leaf snapshot does not run reconciliation")
    func unavailablePreLeafSnapshotDoesNotRunDefaultReconciliation() async throws {
        // Mutation this rejects: remove the `preLeafWindowSnapshotPath` guard in the default
        // reconciler. A killed child with no durable ownership snapshot must not run a cleanup
        // script whose Cancel branch could target another run's matching dialog.
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
            == "execution_failed_issuance_NOT_ISSUED_cleanup_closed_false")
        #expect(reconciliationCalls.value == 0)
        #expect(sliderWrites.value == 0)
    }

    @Test("the default reconciler never cancels a pre-existing dialog after LEAF_ARMED")
    func defaultReconcilerLeavesPreexistingDialogUntouchedAfterLeafTimeout() async throws {
        // Mutation this rejects: pass the ledger path through without requiring its READY
        // pre-leaf snapshot. The default reconciliation script would then be launched after this
        // LEAF_ARMED timeout and could press Cancel on the fixture's already-open dialog.
        let reconciliationCalls = Issue529Counter()
        let fixture = issue529PreexistingDialogRuntime(reconciliationCalls: reconciliationCalls)
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: fixture.runtime,
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                try! "LEAF_ARMED".write(toFile: ledgerPath, atomically: true, encoding: .utf8)
                return .error("osascript timed out after leaf click")
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(reconciliationCalls.value == 0)
        #expect(fixture.builder.actionCalls.isEmpty)
    }

    @Test("timeout reconciliation refuses an unrecognised modal rather than reporting closed")
    func timeoutReconcilerChecksTotalWindowCountBeforeWithholdingClosure() async throws {
        // Mutation this rejects: return CLOSED after the equal-count branch. A timeout process has
        // only serialized counts, not the in-process pre-leaf AX references, so equal totals cannot
        // distinguish a vanished target from a replacement paired with a different disappearance.
        // The fixture returns DIALOG_UNIDENTIFIED to prove the reconciliation seam ran.
        let reconciliationCalls = Issue529Counter()
        let reconciliationScript = Issue529StringBox()
        let runtime = issue529SliderRuntime(
            sliderWrites: Issue529Counter(),
            executeAppleScript: { script in
                reconciliationCalls.bump()
                reconciliationScript.set(script)
                return .success(#"{"result":"DIALOG_UNIDENTIFIED"}"#)
            }
        )
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: runtime,
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                try! "LEAF_ARMED".write(toFile: ledgerPath, atomically: true, encoding: .utf8)
                let snapshotPath = URL(fileURLWithPath: ledgerPath)
                    .appendingPathExtension("preleaf-windows").path
                try! "READY\n0\n1".write(toFile: snapshotPath, atomically: true, encoding: .utf8)
                return .error("osascript timed out after leaf click")
            }
        )

        let envelope = try #require(issue529Envelope(result))
        let script = try #require(reconciliationScript.value)
        let dialogStateStart = try issue529Position(
            of: "on goToPositionDialogState(theProcess, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)",
            in: script
        )
        let dialogStateEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
        let dialogState = String(script[dialogStateStart..<dialogStateEnd])
        let totalWindowCount = try issue529Position(
            of: "set currentGoToPositionWindowCount to my goToPositionWindowCount(theProcess)", in: dialogState
        )
        let unidentified = try issue529Position(
            of: "if currentGoToPositionWindowCount is not preLeafGoToPositionWindowCount then return \"UNIDENTIFIED\"",
            in: dialogState
        )
        let dialogCleanup = try issue529Position(
            of: "set dialogCleanupState to my dismissGoToPositionDialog(it, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)",
            in: script
        )
        let menuFocus = try issue529Position(of: "set menuFocusState to my menuEscapeFocusState(it)", in: script)

        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(reconciliationCalls.value == 1, "fixture seam must execute the timeout reconciler")
        #expect(totalWindowCount < unidentified)
        #expect(!dialogState.contains("return \"CLOSED\""))
        #expect(dialogCleanup < menuFocus)
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

    @Test("a menu-not-found result with no dialog observation is terminal and does not issue the slider")
    func menuNotFoundDoesNotIssueRelativeSlider() async throws {
        // Mutation this rejects: treat MENU_NOT_FOUND as a clean fallback. It occurs before a
        // dialog count, so it must be terminal even though no position write was attempted.
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
        #expect(try #require(envelope["error"] as? String) == "ax_write_failed")
        #expect(try #require(envelope["dialog_route_outcome"] as? String) == "menu_not_found")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
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
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_ACTUATION_ISSUED: dialog did not become ready"}"#)
            }
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
            of: "set dialogPostReturnState to my goToPositionDialogState(logicProcess, observedGoToPositionDialog, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: script
        )
        let postReturnClosedGate = try issue529Position(
            of: "if dialogPostReturnState is not \"CLOSED\" then", in: script
        )
        let ok = try issue529Position(of: "return \"OK\"", in: script)

        #expect(returnKey < postReturnObservation)
        #expect(postReturnObservation < postReturnClosedGate)
        #expect(postReturnClosedGate < ok)
    }

    @Test("post-Return closure preserves every pre-leaf window rather than trusting an equal count")
    func postReturnClosureRequiresStablePreLeafWindowReferences() throws {
        // Mutation this rejects: remove `if preLeafWindowsState is not "UNCHANGED" then return
        // "UNIDENTIFIED"`. In the separating state, the original dialog reference is absent, an
        // old unrelated window also disappeared, and an unnamed Go To Position modal remains. The
        // totals happen to match, but the missing pre-leaf reference proves that equality is not
        // an observed closure of this run's dialog.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let preLeafSnapshot = try issue529Position(
            of: "set preLeafGoToPositionWindows to every window as list", in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let stateStart = try issue529Position(
            of: "on goToPositionDialogState(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: script
        )
        let stateEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
        let state = String(script[stateStart..<stateEnd])
        let closureStart = try issue529Position(
            of: "on observedGoToPositionDialogClosure(theProcess, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: script
        )
        let closureEnd = try issue529Position(of: "end observedGoToPositionDialogClosure", in: script)
        let closure = String(script[closureStart..<closureEnd])
        let referenceRead = try issue529Position(
            of: "set preLeafWindowsState to my preLeafGoToPositionWindowsState(theProcess, preLeafGoToPositionWindows)",
            in: closure
        )
        let preservedGuard = try issue529Position(
            of: "if preLeafWindowsState is not \"UNCHANGED\" then return \"UNIDENTIFIED\"", in: closure
        )
        let currentCount = try issue529Position(
            of: "set currentGoToPositionWindowCount to my goToPositionWindowCount(theProcess)", in: closure
        )
        let countGuard = try issue529Position(
            of: "if currentGoToPositionWindowCount is not preLeafGoToPositionWindowCount then return \"UNIDENTIFIED\"", in: closure
        )
        let closed = try issue529Position(of: "return \"CLOSED\"", in: closure)

        #expect(preLeafSnapshot < leafClick)
        #expect(state.contains("if not (exists dialogWindow) then"))
        #expect(state.contains("return my observedGoToPositionDialogClosure(theProcess, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)"))
        #expect(referenceRead < preservedGuard)
        #expect(preservedGuard < currentCount)
        #expect(currentCount < countGuard)
        #expect(countGuard < closed)
    }

    @Test("durable issuance checkpoints precede the leaf and Return actuators")
    func durableIssuanceCheckpointsPrecedeActuators() throws {
        // Mutations this rejects: move either persistent checkpoint after its corresponding click
        // or key event, restore a direct `printf > ledgerPath` replacement, or omit cleanup after
        // a post-`mktemp` failure. The former recreates a no-record timeout window; the latter two
        // can respectively truncate the prior marker or leak a randomized staging file.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(
            position: "529.4.1.1",
            issuanceLedgerPath: "/private/tmp/issue529-ledger"
        )
        let leafCheckpoint = try issue529Position(
            of: "recordDialogIssuance(\"LEAF_ARMED\"", in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
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
        let cleanupGuard = try issue529Position(
            of: "if temporaryLedgerPath is not \"\" then", in: ledgerHandler
        )
        let temporaryCleanup = try issue529Position(of: "/bin/rm -f", in: ledgerHandler)

        #expect(leafCheckpoint < leafClick)
        #expect(returnCheckpoint < returnKey)
        #expect(temporaryLedger < stagedWrite)
        #expect(stagedWrite < atomicRename)
        #expect(atomicRename < cleanupGuard)
        #expect(cleanupGuard < temporaryCleanup)
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
    //
    // #519: locale discovery used to have two textually separate cleanup call sites — an explicit
    // "no candidate exists" branch and a catch-all `on error errMsg` handler — because the old
    // if/else-if chain distinguished "nothing matched" from "reading a candidate raised an AX
    // error". The candidate-loop resolution now raises the SAME kind of AppleScript `error` for
    // both ("not found" and "unreadable" are no longer distinguishable, which the old code did not
    // rely on either — both returned the same MENU_NOT_FOUND-prefixed refusal), so one shared
    // `on error errMsg` handler covers what used to be two call sites: 5 sites, not 6.
    #expect(issue529Positions(of: "my dismissOpenMenu(logicProcess, false)", in: script).count == 5)

    let leafCheckpoint = try issue529Position(
        of: "recordDialogIssuance(\"LEAF_ARMED\"",
        in: script
    )
    let resolvedLeaf = try issue529Position(
        of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
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

@Test("the newly opened Go To Position dialog is count-bound and bracket-focus-bound before global typing")
func gotoPositionDialogRequiresNewCountAndBracketedFocusedBinding() throws {
    // Mutations this rejects: remove AXFloatingWindow or AXModal from the known input class;
    // delete the pre-leaf readable count snapshot or its new-window predicate; remove the second
    // frontmost read after AXFocusedWindow; restore a title/AXFocused fallback; or move a global
    // key before its post-marker focus guard. Any one can select a same-titled plug-in window or
    // let a handoff during AX resolution authorise input for another application.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(position: "529.4.7.123")
    let preLeafSnapshot = try #require(
        script.range(
            of: "set preLeafGoToPositionDialogCount to my goToPositionDialogCount(logicProcess)",
            options: .backwards
        )
    ).lowerBound
    let preLeafSnapshotGuard = try #require(
        script.range(of: "if preLeafGoToPositionDialogCount is \"UNREADABLE\" then", options: .backwards)
    ).lowerBound
    let preexistingDialogGuard = try issue529Position(
        of: "if preLeafGoToPositionDialogCount is greater than 0 then",
        in: script
    )
    let leafClick = try issue529Position(
        of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
        in: script
    )
    let observedDialog = try issue529Position(
        of: "set observedGoToPositionDialog to my matchingGoToPositionDialog(logicProcess, preLeafGoToPositionDialogCount)",
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
    let firstFrontmostRead = try issue529Position(of: "set logicWasFrontmost to frontmost", in: focusHandler)
    let focusedWindowRead = try issue529Position(
        of: "set processFocusedWindow to value of attribute \"AXFocusedWindow\"", in: focusHandler
    )
    let finalFrontmostRead = try issue529Position(
        of: "set logicIsStillFrontmost to frontmost", in: focusHandler
    )
    let dialogStateHandlerStart = try issue529Position(
        of: "on goToPositionDialogState(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)", in: script
    )
    let dialogStateHandlerEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
    let dialogStateHandler = String(script[dialogStateHandlerStart..<dialogStateHandlerEnd])

    #expect(preLeafSnapshot < preLeafSnapshotGuard)
    #expect(preLeafSnapshotGuard < preexistingDialogGuard)
    #expect(preexistingDialogGuard < leafClick)
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
    #expect(firstFrontmostRead < focusedWindowRead)
    #expect(focusedWindowRead < finalFrontmostRead)
    #expect(focusHandler.contains("if logicWasFrontmost is not true then return \"NOT_FRONTMOST\""))
    #expect(focusHandler.contains("if logicIsStillFrontmost is not true then return \"NOT_FRONTMOST\""))
    #expect(focusHandler.contains("set dialogIsModal to value of attribute \"AXModal\" of dialogWindow"))
    #expect(focusHandler.contains("if processFocusedWindow is not dialogWindow then return \"NOT_FOCUSED\""))
    #expect(!focusHandler.contains("name of processFocusedWindow"))
    #expect(!focusHandler.contains("if focused of dialogWindow"))
    #expect(dialogStateHandler.contains("if not my knownGoToPositionDialogSubrole(dialogSubrole) then return \"OPEN_UNKNOWN_SUBROLE\""))
    #expect(dialogStateHandler.contains("if not my knownGoToPositionDialogTitle(dialogTitle) then return \"UNIDENTIFIED\""))
    #expect(dialogStateHandler.contains("return my observedGoToPositionDialogClosure(theProcess, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)"))
    #expect(dialogStateHandler.contains("set dialogIsModal to value of attribute \"AXModal\" of dialogWindow"))
    #expect(dialogStateHandler.contains("return \"OPEN_UNVERIFIED_MODALITY\""))
}

@Test("a pre-existing matching dialog refuses before this run's leaf click")
func gotoPositionDialogRefusesPreexistingMatchingDialogBeforeLeaf() throws {
    // Mutation this rejects: remove the readable count guard. Without it, an already-open matching
    // dialog could be used as the target of this run's global keystrokes.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    let snapshot = try issue529Position(
        of: "set preLeafGoToPositionDialogCount to my goToPositionDialogCount(logicProcess)", in: script
    )
    let preexistingGuard = try issue529Position(
        of: "if preLeafGoToPositionDialogCount is greater than 0 then", in: script
    )
    let leaf = try issue529Position(
        of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
        in: script
    )
    let matcherStart = try issue529Position(
        of: "on matchingGoToPositionDialog(theProcess, preLeafGoToPositionDialogCount)", in: script
    )
    let matcherEnd = try issue529Position(of: "end matchingGoToPositionDialog", in: script)
    let matcher = String(script[matcherStart..<matcherEnd])
    let countBasedPriorWindowGuard = try issue529Position(
        of: "set wasPresentBefore to my windowWasPresentBefore(currentGoToPositionDialogCount, preLeafGoToPositionDialogCount)",
        in: matcher
    )
    let exactNewCountGuard = try issue529Position(
        of: "if currentGoToPositionDialogCount is not (preLeafGoToPositionDialogCount + 1) then return missing value",
        in: matcher
    )

    #expect(snapshot < preexistingGuard)
    #expect(preexistingGuard < leaf)
    #expect(countBasedPriorWindowGuard < exactNewCountGuard)
}

@Test("an unreadable Cancel result re-observes the dialog before Escape")
func unreadableCancelDoesNotAuthoriseEscapeWithoutDialogObservation() throws {
    // Mutation this rejects: move `key code 53` directly after an `UNREADABLE` Cancel result,
    // bypassing either the fresh exact-dialog state observation or the bracketed
    // frontmost-plus-AXFocusedWindow guard for that exact dialog.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    let handlerStart = try issue529Position(
        of: "on dismissOpenGoToPositionDialog(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)", in: script
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
        of: "set dialogState to my goToPositionDialogState(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)", in: unreadableBranch
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
    let cleanupFocusGuard = try issue529Position(
        of: "set cleanupDialogFocusState to my observedGoToPositionDialogFocusState(theProcess, dialogWindow)",
        in: unreadableBranch
    )
    let escape = try issue529Position(of: "key code 53", in: unreadableBranch)

    #expect(reobservation < closedGuard)
    #expect(closedGuard < unreadableGuard)
    #expect(unreadableGuard < stillOpenGuard)
    #expect(stillOpenGuard < cleanupFocusGuard)
    #expect(cleanupFocusGuard < escape)
}

@Test("dead-child reconciliation targets the measured dialog before menu state")
func aDeadScriptReconcilesDialogBeforeMenuState() throws {
    // Mutations this rejects: restore the PID bypass, drop the durable pre-leaf count filter,
    // remove the final frontmost read after AXFocusedWindow, or send menu Escape after a single
    // frontmost read. Each would either cancel another run's dialog or let Escape reach a
    // different focused modal/app.
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
    let measuredSubrole = try issue529Position(of: "on knownGoToPositionDialogSubrole(dialogSubrole)", in: helper)
    let dialogObservation = try issue529Position(
        of: "on matchingGoToPositionDialog(theProcess, preLeafGoToPositionDialogCount)", in: helper
    )
    let snapshotParser = AccessibilityChannel.preLeafGoToPositionWindowSnapshotParserAppleScript()
    let dialogCleanup = try issue529Position(
        of: "set dialogCleanupState to my dismissGoToPositionDialog(it, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)",
        in: helper
    )
    let dialogStateStart = try issue529Position(
        of: "on goToPositionDialogState(theProcess, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)", in: helper
    )
    let dialogStateEnd = try issue529Position(of: "end goToPositionDialogState", in: helper)
    let dialogState = String(helper[dialogStateStart..<dialogStateEnd])
    let preexistingCountRefusal = try issue529Position(
        of: "if preLeafGoToPositionDialogCount is greater than 0 then return \"PREEXISTING\"", in: dialogState
    )
    let targetMatch = try issue529Position(
        of: "set dialogWindow to my matchingGoToPositionDialog(theProcess, preLeafGoToPositionDialogCount)",
        in: dialogState
    )
    let dismissHandlerStart = try issue529Position(
        of: "on dismissGoToPositionDialog(theProcess, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)", in: helper
    )
    let dismissHandlerEnd = try issue529Position(of: "end dismissGoToPositionDialog", in: helper)
    let dismissHandler = String(helper[dismissHandlerStart..<dismissHandlerEnd])
    let nonOpenRefusal = try issue529Position(
        of: "if dialogState is not \"OPEN\" then return dialogState", in: dismissHandler
    )
    let cancelAttempt = try issue529Position(of: "if exists button \"Cancel\" of dialogWindow then", in: dismissHandler)
    let focusedWindowRead = try issue529Position(
        of: "set processFocusedWindow to value of attribute \"AXFocusedWindow\"", in: helper
    )
    let finalFrontmostRead = try issue529Position(of: "set logicIsStillFrontmost to frontmost", in: helper)
    let menuFocus = try issue529Position(of: "set menuFocusState to my menuEscapeFocusState(it)", in: helper)
    let menuCleanupTail = String(helper[menuFocus...])
    let menuEscape = try issue529Position(of: "key code 53", in: menuCleanupTail)

    #expect(helper.contains("\\(preLeafGoToPositionWindowSnapshotParserAppleScript())"))
    #expect(snapshotParser.contains("on preLeafGoToPositionWindowSnapshot(snapshotPath)"))
    #expect(measuredSubrole < dialogObservation)
    #expect(dialogObservation < dialogCleanup)
    #expect(preexistingCountRefusal < targetMatch)
    #expect(nonOpenRefusal < cancelAttempt)
    #expect(focusedWindowRead < finalFrontmostRead)
    #expect(dialogCleanup < menuFocus)
    #expect(menuCleanupTail.startIndex < menuEscape)
    #expect(helper.contains("set dialogIsModal to value of attribute \"AXModal\" of dialogWindow"))
    #expect(helper.contains("if processFocusedWindow is not dialogWindow then return \"NOT_FOCUSED\""))
    #expect(!helper.contains("if frontmost then"))
    #expect(!helper.contains("ProcessUtils.logicProPID"))
}

@Test("the pre-leaf snapshot accepts only a readiness marker and canonical dialog/window counts")
func preLeafGoToPositionSnapshotIsUnambiguousAndNonInjectable() throws {
    // Mutation this rejects: weaken the count-format guard so a stale/truncated snapshot or a
    // title-shaped delimiter payload can reach timeout reconciliation as if it named this run.
    let ledger = try #require(AccessibilityChannel.DialogIssuanceLedger.create())
    defer { ledger.remove() }

    let snapshotURL = ledger.preLeafWindowSnapshotURL
    #expect(ledger.preLeafWindowSnapshotPath == nil)

    try "READY\n0\n1".write(to: snapshotURL, atomically: true, encoding: .utf8)
    #expect(ledger.preLeafWindowSnapshotPath == snapshotURL.path)

    for malformedSnapshot in [
        "READY",
        "READY\n",
        "READY\n01",
        "READY\n-1",
        "READY\n1|title=forged",
        "READY\n1\nextra",
        "READY\n0\n",
        "READY\n01\n1",
        "READY\n0\n01",
        "READY\n1\n0",
        "READY\n0\n1\nextra",
        "UNAVAILABLE",
    ] {
        try malformedSnapshot.write(to: snapshotURL, atomically: true, encoding: .utf8)
        #expect(ledger.preLeafWindowSnapshotPath == nil)
    }

    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    #expect(script.contains("set snapshotText to \"READY\" & linefeed & (matchingGoToPositionDialogCount as text) & linefeed & (totalWindowCount as text)"))
    #expect(!script.contains("id of contents of preLeafWindow"))
    #expect(!script.contains("AXIdentifier"))
}

@Test("the timeout parser accepts the LF snapshot through Foundation")
func timeoutSnapshotParserUsesFoundationPreservedDelimiter() throws {
    // Mutation this rejects: change the production parser's `text item delimiters to linefeed`
    // back to `return`. Foundation preserves the writer's LF, so the probe executes that same
    // boundary without touching System Events and would produce one item rather than the
    // required three.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("logic-pro-mcp-snapshot-parser-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshotURL = directory.appendingPathComponent("preleaf-windows")
    try "READY\n0\n1".write(to: snapshotURL, atomically: true, encoding: .utf8)

    let parser = AccessibilityChannel.preLeafGoToPositionWindowSnapshotParserAppleScript()
    let parserProbe = parser + "\nreturn preLeafGoToPositionWindowSnapshot(\"\(snapshotURL.path)\")"
    let probeResult = try runProcess(
        executable: "/usr/bin/osascript",
        arguments: ["-e", parserProbe],
        currentDirectoryURL: directory
    )

    let writer = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)

    #expect(probeResult.exitCode == 0)
    #expect(probeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0, 1")
    #expect(writer.contains("set snapshotText to \"READY\" & linefeed"))
    #expect(parser.contains("set AppleScript's text item delimiters to linefeed"))
    #expect(!parser.contains("set AppleScript's text item delimiters to return"))
}

@Test("the write script emits the unidentified-window refusal, and emits it before any dismissal")
func writeScriptRefusesAnUnidentifiedNewWindowBeforeDismissingAnything() throws {
    // The whole unidentified-new-window refusal rests on this one AppleScript return. Every Swift-side
    // test downstream of it starts from a reply string, so deleting this line leaves the parser, the
    // classifier and the envelope tests all green while the defect returns: a window this run opened but
    // could not name would again be reported CLOSED, the result would be router-continuable, and CGEvent
    // would type the position into the live dialog.
    //
    // Order is part of the contract, not decoration. The refusal must come BEFORE
    // `dismissOpenGoToPositionDialog`, or the script would cancel the window it just declined to identify
    // — which is the same wrong-target cancellation the reconciler was fixed to avoid.
    let source = try String(
        contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/LogicProMCPTests/Issue529MenuValidationTests.swift",
            with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Transport.swift"
        ),
        encoding: .utf8
    )
    // Scope to the not-ready block. An earlier dismissal exists in the leaf-click `on error` handler,
    // which is a different case and legitimately dismisses first.
    let scriptStart = try #require(source.range(of: "                if not dialogReady then"))
    let scriptEnd = try #require(source.range(of: "    struct DialogIssuanceLedger"))
    let script = String(source[scriptStart.lowerBound..<scriptEnd.lowerBound])

    let unidentifiedRefusal = try issue529Position(
        of: "if dialogAppearanceUnidentified then return \"DIALOG_UNIDENTIFIED_NEW_WINDOW\"", in: script
    )
    let dialogDismissal = try issue529Position(
        of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(", in: script
    )
    #expect(unidentifiedRefusal < dialogDismissal)
}

@Test("the write script records APPEARED before relying on the unidentified-window refusal")
func writeScriptMarksAnAppearedUnidentifiedWindow() throws {
    // The Swift classifier can only protect the result that AppleScript emits. Deleting this
    // assignment leaves `dialogAppearanceUnidentified` false, bypasses the terminal return below,
    // and turns a newly opened unknown-title window into a clean actuation failure. Keep the
    // APPEARED observation, assignment, terminal return, and no-dismissal order load-bearing.
    let source = try String(
        contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/LogicProMCPTests/Issue529MenuValidationTests.swift",
            with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Transport.swift"
        ),
        encoding: .utf8
    )
    let pollStart = try #require(source.range(of: "                repeat 30 times"))
    let scriptEnd = try #require(source.range(of: "    struct DialogIssuanceLedger"))
    let script = String(source[pollStart.lowerBound..<scriptEnd.lowerBound])
    let totalWindowObservation = try issue529Position(
        of: "set newWindowState to my newWindowAppearedSince(logicProcess, preLeafGoToPositionWindowCount)",
        in: script
    )
    let appearedGuard = try issue529Position(
        of: "if newWindowState is \"APPEARED\" or newWindowState is \"UNIDENTIFIED\" then",
        in: script
    )
    let appearedAssignment = try issue529Position(
        of: "set dialogAppearanceUnidentified to true", in: script
    )
    let unidentifiedRefusal = try issue529Position(
        of: "if dialogAppearanceUnidentified then return \"DIALOG_UNIDENTIFIED_NEW_WINDOW\"", in: script
    )
    let dialogDismissal = try issue529Position(
        of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(", in: script
    )

    #expect(totalWindowObservation < appearedGuard)
    #expect(appearedGuard < appearedAssignment)
    #expect(appearedAssignment < unidentifiedRefusal)
    #expect(unidentifiedRefusal < dialogDismissal)
}
