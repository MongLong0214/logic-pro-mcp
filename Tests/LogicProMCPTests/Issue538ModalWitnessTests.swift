@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private enum AuxiliarySheetScanMode: CaseIterable, Equatable {
    case incomplete
    case unreadable
}

private enum AXSheetsNonPositiveRead: CaseIterable {
    case absent
    case empty
    case unsupported
    case genericFailure
    case malformed
}

@Suite("Issue #538 — identity-bound modal witness")
struct Issue538ModalWitnessTests {

    @Test("the captured sheet is present while its AX identity remains readable")
    func boundSheetIsPresent() {
        let builder = FakeAXRuntimeBuilder()
        let sheet = builder.element(1)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        let runtime = builder.makeLogicRuntime(setAttributeHandler: nil, performActionHandler: nil)

        let observed = AccessibilityChannel.boundSheetWitnessObservation(sheet, runtime: runtime)

        #expect(
            observed == .present,
            "Mutation caught: replace the captured-sheet role read with an unconditional gone result; a readable bound sheet must remain present."
        )
    }

    @Test("invalidUIElement on the captured sheet is observed gone")
    func invalidCapturedSheetIsObservedGone() {
        let builder = FakeAXRuntimeBuilder()
        let sheet = builder.element(2)
        let invalid = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, sheet), attribute == (kAXRoleAttribute as String) else { return nil }
                return .failure(invalid)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.boundSheetWitnessObservation(sheet, runtime: runtime)

        #expect(
            observed == .gone,
            "Mutation caught: keep invalidUIElement mapped to .unreadable(.sheet); -25202 on the bound element IS macOS's only closure signal for that exact element and must be .gone."
        )
    }

    @Test("a non-staleness failure of the captured sheet is unreadable")
    func nonStaleCapturedSheetIsUnreadable() {
        let builder = FakeAXRuntimeBuilder()
        let sheet = builder.element(3)
        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, sheet), attribute == (kAXRoleAttribute as String) else { return nil }
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.boundSheetWitnessObservation(sheet, runtime: runtime)

        #expect(
            observed == .unreadable(.sheet(cannotComplete)),
            "A failed identity read retires this poll. cannotComplete is not sheet absence."
        )
    }

    @Test("polling stops as soon as the bound sheet's identity is invalidated")
    func pollingReportsPresentThenGone() async {
        let builder = FakeAXRuntimeBuilder()
        let sheet = builder.element(4)
        let reads = LockedCounter()
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, sheet), attribute == (kAXRoleAttribute as String) else { return nil }
                return reads.next() == 1
                    ? .success(kAXSheetRole as NSString)
                    : .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let polls = await AccessibilityChannel.pollBoundSheetWitness(
            sheet,
            runtime: runtime,
            observationAttempts: 4,
            observationDelayNanoseconds: 0
        )

        // Prove the seam actually fired: the fake must have been read exactly
        // twice (present, then invalidUIElement) for the assertions below to
        // mean anything.
        #expect(reads.current() == 2, "Fixture seam did not fire as expected — the attribute handler was not read twice.")
        #expect(
            polls.map(\.observation) == [
                .present,
                .gone,
            ],
            "Mutation caught: keep polling past invalidUIElement instead of breaking on .gone; -25202 on the bound element is the sheet's closure signal and must stop the poll."
        )
        #expect(
            polls.map(\.index) == [1, 2],
            "Polling must stop at the poll where the bound sheet's identity was invalidated."
        )
    }

    @Test("AXSheets unsupported and childless noValue remain structural absence answers")
    func structuralAbsenceStatusesRemainClean() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(10)
        let window = builder.element(11)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let signals = AccessibilityChannel.readModalSignals(runtime: runtime)

        #expect(
            !signals.sheetPresent,
            "Mutation caught: classify AXSheets -25205 or childless AXChildren -25212 as unreadable; both are structural absence answers."
        )
    }

    @Test("every uninformative AXSheets outcome falls through to its AXChildren sheet")
    func uninformativeAXSheetsOutcomesReachDescendantSheet() {
        for outcome in AXSheetsNonPositiveRead.allCases {
            let builder = FakeAXRuntimeBuilder()
            let app = builder.element(1_000)
            let window = builder.element(1_001)
            let sheet = builder.element(1_002)
            let sheetReads = LockedCounter()
            let childrenReads = LockedCounter()

            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
            builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
            builder.setChildren(window, [sheet])

            let runtime = builder.makeLogicRuntime(
                appElement: app,
                attributeValueResultHandler: { element, attribute in
                    guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                    _ = sheetReads.next()
                    switch outcome {
                    case .absent:
                        return .success(nil)
                    case .empty:
                        return .success([] as NSArray)
                    case .unsupported:
                        return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
                    case .genericFailure:
                        return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                    case .malformed:
                        return .success("not an AX element array" as NSString)
                    }
                },
                childrenResultHandler: { element in
                    guard CFEqual(element, window) else { return nil }
                    _ = childrenReads.next()
                    return .success([sheet])
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            )

            let kind = ModalReconciliation.classify(
                AccessibilityChannel.readModalSignals(runtime: runtime)
            )

            // Mutation `axsheet-nonpositive-veto`: restore the old failure or
            // malformed payload return from `firstSheetLookup`. The
            // unsupported, generic-failure, and malformed cases stop before
            // this descendant seam; this shared assertion fails for each.
            #expect(kind == .mandatoryNewTrack)
            #expect(sheetReads.current() == 1, "each AXSheets noise seam must fire")
            #expect(childrenReads.current() == 1, "each AXSheets noise value must reach AXChildren")
        }
    }

    @Test("a generic AXSheets failure still discovers the measured AXChildren New Track sheet and binds Create")
    func genericAXSheetsFailureChildSheetBindsCreate() async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(12)
        let markerWindow = builder.element(13)
        let tracksWindow = builder.element(14)
        let markerGroup = builder.element(15)
        let sheet = builder.element(16)
        let buttonGroup = builder.element(17)
        let create = builder.element(18)
        let cancel = builder.element(19)
        let markerSheetReads = LockedCounter()
        let tracksSheetReads = LockedCounter()
        let tracksChildrenReads = LockedCounter()
        let buttonGroupChildrenReads = LockedCounter()
        let createPresses = LockedCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, markerWindow)
        builder.setAttribute(app, kAXWindowsAttribute as String, [markerWindow, tracksWindow])
        builder.setAttribute(markerWindow, kAXModalAttribute as String, false)
        builder.setAttribute(tracksWindow, kAXModalAttribute as String, false)
        builder.setAttribute(markerGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setChildren(markerWindow, [markerGroup])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(buttonGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(create, kAXEnabledAttribute as String, true)
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(tracksWindow, [sheet])
        builder.setChildren(sheet, [buttonGroup])
        builder.setChildren(buttonGroup, [create, cancel])

        let genericFailure = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard attribute == "AXSheets" else { return nil }
                if CFEqual(element, markerWindow) {
                    _ = markerSheetReads.next()
                    return .failure(genericFailure)
                }
                if CFEqual(element, tracksWindow) {
                    _ = tracksSheetReads.next()
                    return .failure(genericFailure)
                }
                return nil
            },
            childrenHandler: { element in
                guard CFEqual(element, buttonGroup) else { return nil }
                _ = buttonGroupChildrenReads.next()
                return [create, cancel]
            },
            childrenResultHandler: { element in
                if CFEqual(element, tracksWindow) {
                    _ = tracksChildrenReads.next()
                    return .success([sheet])
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
                _ = createPresses.next()
                return true
            }
        )

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `axsheet-failure-veto`: restore
        // `guard axStatusIsDefinitiveAbsence(error) else { return
        // .unreadable(.windowSheetReadFailed(error)) }` in
        // `firstSheetLookup`. The Tracks host is then never traversed, so this
        // positive classification and bound Create expectation fail:
        #expect(outcome.kind == .mandatoryNewTrack)
        #expect(outcome.decision == .clickCreate)
        #expect(outcome.actionAttempted)
        #expect(markerSheetReads.current() > 0, "the Marker List AXSheets -25200 seam must fire")
        #expect(tracksSheetReads.current() > 0, "the Tracks AXSheets -25200 seam must fire")
        #expect(tracksChildrenReads.current() > 0, "the Tracks AXChildren sheet seam must fire")
        #expect(buttonGroupChildrenReads.current() > 0, "the AXGroup button-child seam must fire")
        #expect(createPresses.current() == 1, "the classified Create element must be pressed exactly once")
    }

    @Test("the measured eleven-child arrange window finds its direct New Track sheet before sibling descent")
    func measuredDirectChildSheetWithFailingSiblingsBindsCreate() async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(30)
        let window = builder.element(31)
        let unreadableNodes = (0..<5).map { builder.element(32 + $0) }
        let readableSiblingGroups = (0..<5).map { builder.element(37 + $0) }
        let sheet = builder.element(42)
        let group = builder.element(43)
        let create = builder.element(44)
        let cancel = builder.element(45)
        let sheetReads = LockedCounter()
        let windowChildrenReads = LockedCounter()
        let roleReadFailures = LockedCounter()
        let readableSiblingDescents = LockedCounter()
        let createPresses = LockedCounter()
        let genericFailure = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let unsupported = AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)

        // Measured live shape: AXSheets is unsupported (-25205), AXChildren
        // has eleven direct children, several siblings reject AXRole (-25200),
        // and exactly one direct child is the New Track AXSheet.
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, readableSiblingGroups + unreadableNodes + [sheet])
        for sibling in readableSiblingGroups {
            builder.setAttribute(sibling, kAXRoleAttribute as String, kAXGroupRole as String)
        }
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(create, kAXEnabledAttribute as String, true)
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(sheet, [group])
        builder.setChildren(group, [create, cancel])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, window), attribute == "AXSheets" {
                    _ = sheetReads.next()
                    return .failure(unsupported)
                }
                if attribute == (kAXRoleAttribute as String),
                   unreadableNodes.contains(where: { CFEqual(element, $0) }) {
                    _ = roleReadFailures.next()
                    return .failure(genericFailure)
                }
                return nil
            },
            childrenResultHandler: { element in
                if CFEqual(element, window) {
                    _ = windowChildrenReads.next()
                    return .success(readableSiblingGroups + unreadableNodes + [sheet])
                }
                if readableSiblingGroups.contains(where: { CFEqual(element, $0) }) {
                    _ = readableSiblingDescents.next()
                    return .failure(genericFailure)
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
                _ = createPresses.next()
                return true
            }
        )

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `direct-children-after-descend`: restore the former DFS that
        // descends below each readable sibling before inspecting later direct
        // children. The opaque sibling descent seam fires before the direct
        // AXSheet is considered; this fixture catches the traversal order even
        // though the sheet is only one level below its host.
        #expect(outcome.kind == .mandatoryNewTrack)
        #expect(outcome.decision == .clickCreate)
        #expect(outcome.actionAttempted)
        #expect(sheetReads.current() == 2, "classify plus the post-action confirmation scan must each consume AXSheets")
        #expect(windowChildrenReads.current() == 2, "classify plus the confirmation scan must each read the eleven-child host")
        #expect(roleReadFailures.current() == 10, "every failing direct sibling role must be visited on each host scan")
        #expect(readableSiblingDescents.current() == 0, "a direct AXSheet must win before any sibling subtree is traversed")
        #expect(createPresses.current() == 1, "the classifier-bound Create element must be pressed exactly once")
    }

    @Test("the measured no-sheet sibling failure is incomplete and retries without becoming unknown_sheet")
    func measuredNoSheetSiblingFailureRetriesWithoutInventingBlocker() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(39)
        let window = builder.element(40)
        let unreadableNodes = (0..<5).map { builder.element(41 + $0) }
        let readableSiblingGroups = (0..<6).map { builder.element(46 + $0) }
        let sheetReads = LockedCounter()
        let windowChildrenReads = LockedCounter()
        let roleReadFailures = LockedCounter()
        let readableSiblingDescents = LockedCounter()
        let presses = LockedCounter()
        let genericFailure = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let unsupported = AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, unreadableNodes + readableSiblingGroups)
        for sibling in readableSiblingGroups {
            builder.setAttribute(sibling, kAXRoleAttribute as String, kAXGroupRole as String)
        }

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, window), attribute == "AXSheets" {
                    _ = sheetReads.next()
                    return .failure(unsupported)
                }
                if attribute == (kAXRoleAttribute as String),
                   unreadableNodes.contains(where: { CFEqual(element, $0) }) {
                    _ = roleReadFailures.next()
                    return .failure(genericFailure)
                }
                return nil
            },
            childrenResultHandler: { element in
                if CFEqual(element, window) {
                    _ = windowChildrenReads.next()
                    return .success(unreadableNodes + readableSiblingGroups)
                }
                if readableSiblingGroups.contains(where: { CFEqual(element, $0) }) {
                    _ = readableSiblingDescents.next()
                    return .failure(genericFailure)
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { _, _ in
                _ = presses.next()
                return true
            }
        )

        let immediate = AccessibilityChannel.observeModalAfterMutation(
            isDeleteContext: false,
            runtime: runtime
        )

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: runtime,
            selection: "Empty Project",
            observationAttempts: 2,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )

        // Mutation `partial-sheet-scan-as-unknown`: restore
        // `unreadableModalSignals(reason: sheetScanFailure)`. The direct
        // observation becomes unknownSheet and the project observer exits via
        // `unexpected_blocking_sheet` instead of consuming its full polling
        // budget. This locks the distinction between incomplete and blocking.
        #expect(immediate.kind == .none)
        #expect(!immediate.modalObservationIsComplete)
        #expect(immediate.unreadableReason == .windowSheetReadFailed(genericFailure))
        #expect(!immediate.actionAttempted)
        #expect(result.isSuccess)
        #expect(envelope["state"] as? String == "B")
        #expect(envelope["phase"] as? String == "created_project_window_pending")
        #expect(envelope["modal_observation"] as? String == "incomplete")
        #expect(envelope["sheet_kind"] == nil)
        #expect(envelope["reconciled_modal_kind"] == nil)
        #expect(envelope["reconciled_modal_unreadable_reason"] as? String == "window_sheet_read_failed")
        #expect(envelope["reconciled_modal_unreadable_ax_status"] as? Int == Int(genericFailure.raw))
        #expect(sheetReads.current() == 3, "the direct read plus every bounded retry must consume AXSheets -25205")
        #expect(windowChildrenReads.current() == 3, "the eleven-child AXChildren seam must fire on every poll")
        #expect(roleReadFailures.current() == 15, "every poll must visit all five failing sibling roles")
        #expect(readableSiblingDescents.current() == 18, "no-sheet polls must retain the unreadable descendant evidence")
        #expect(presses.current() == 0, "an incomplete no-sheet search must not authorize an action")
    }

    @Test("an AXSheets-unsupported host with no AXSheet child is absent, not unreadable")
    func measuredAXSheetsUnsupportedWithoutChildSheetIsAbsent() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(20)
        let window = builder.element(21)
        let group = builder.element(22)
        let sheetReads = LockedCounter()
        let childrenReads = LockedCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setChildren(window, [group])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                _ = sheetReads.next()
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                _ = childrenReads.next()
                return .success([group])
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(ModalReconciliation.classify(read.signals) == .none)
        #expect(read.unreadableReason == nil)
        #expect(sheetReads.current() > 0, "the AXSheets -25205 seam must fire")
        #expect(childrenReads.current() > 0, "the AXChildren no-sheet seam must fire")
    }

    @Test("an unavailable AXChildren branch does not hide a later AXSheets-unsupported sheet host")
    func unavailableWindowDoesNotHideLaterChildSheet() async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(23)
        let unreadableHost = builder.element(24)
        let unreadableChild = builder.element(25)
        let sheetHost = builder.element(26)
        let sheet = builder.element(27)
        let create = builder.element(28)
        let cancel = builder.element(29)
        let unreadableChildRoleReads = LockedCounter()
        let laterHostChildrenReads = LockedCounter()
        let createPresses = LockedCounter()
        let unsupported = AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)
        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)

        // No AXMainWindow deliberately routes this through the all-window
        // scanner. The first host proves that -25205 fell through to AXChildren
        // by failing only on a descendant role read; the second exposes New
        // Track through the same -25205 → AXChildren route.
        builder.setAttribute(app, kAXWindowsAttribute as String, [unreadableHost, sheetHost])
        builder.setAttribute(unreadableHost, kAXModalAttribute as String, false)
        builder.setAttribute(sheetHost, kAXModalAttribute as String, false)
        builder.setChildren(unreadableHost, [unreadableChild])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(sheetHost, [sheet])
        builder.setChildren(sheet, [create, cancel])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if (CFEqual(element, unreadableHost) || CFEqual(element, sheetHost)),
                   attribute == "AXSheets" {
                    return .failure(unsupported)
                }
                if CFEqual(element, unreadableChild), attribute == (kAXRoleAttribute as String) {
                    _ = unreadableChildRoleReads.next()
                    return .failure(cannotComplete)
                }
                return nil
            },
            childrenResultHandler: { element in
                if CFEqual(element, sheetHost) {
                    _ = laterHostChildrenReads.next()
                    return .success([sheet])
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
                _ = createPresses.next()
                return true
            }
        )

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `unavailable-window-stops-scan`: revert the single
        // `unreadableReason = unreadableReason ?? reason` line in
        // `anyWindowSheetLookup` to `return .unreadable(reason)`. The first
        // host then blocks the second host and this expectation fails:
        #expect(outcome.kind == .mandatoryNewTrack)
        #expect(outcome.actionAttempted)
        #expect(unreadableChildRoleReads.current() > 0, "the first host must fall through -25205 into AXChildren")
        #expect(laterHostChildrenReads.current() > 0, "the later host AXChildren sheet seam must fire")
        #expect(createPresses.current() == 1)
    }

    @Test("a sheet deeper than the old bound is classified, not treated as clean")
    func deepSheetIsClassified() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(20)
        let window = builder.element(21)
        let groups = (0..<5).map { builder.element(22 + $0) }
        let sheet = builder.element(30)
        let create = builder.element(31)
        let cancel = builder.element(32)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(window, [groups[0]])
        for index in 0..<(groups.count - 1) {
            builder.setChildren(groups[index], [groups[index + 1]])
        }
        builder.setChildren(groups[groups.count - 1], [sheet])
        builder.setChildren(sheet, [create, cancel])
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
        let kind = ModalReconciliation.classify(read.signals)

        #expect(
            kind == .mandatoryNewTrack,
            "Mutation caught: restore the former depth-four absence result; the unvisited deep subtree would hide this mandatory sheet."
        )
    }

    @Test("a reached sheet-search depth cap is not a clean observation")
    func depthCapIsFailClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(35)
        let window = builder.element(36)
        let groups = (0..<33).map { builder.element(37 + $0) }
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [groups[0]])
        for index in 0..<(groups.count - 1) {
            builder.setChildren(groups[index], [groups[index + 1]])
        }
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
        let kind = ModalReconciliation.classify(read.signals)

        #expect(kind == .none)
        #expect(
            !read.modalObservationIsComplete,
            "Mutation caught: treat the capped tree as clean; an unvisited subtree must remain a retryable incomplete observation."
        )
        #expect(
            read.unreadableReason == .descendantTraversalDepthCap,
            "Mutation `depth-cap-reason-flattened`: replace the capped traversal reason with a generic sheet failure; the receipt must identify the depth cap."
        )
        #expect(
            !AccessibilityChannel.freshCompleteModalReadIsClear(in: window, runtime: runtime),
            "classify == .none with an unreadable reason is not a clear blocker set."
        )
    }

    @Test("a malformed successful children payload blocks clean classification")
    func malformedChildrenAreFailClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(40)
        let window = builder.element(41)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                return .failure(.malformedChildren)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
        let kind = ModalReconciliation.classify(read.signals)

        #expect(kind == .none)
        #expect(
            !read.modalObservationIsComplete,
            "Mutation caught: flatten malformed AXChildren to an empty success; an undecodable subtree must remain incomplete."
        )
    }

    @Test("a sheet on a non-modal window is seen even when AXMainWindow is absent")
    func sheetOnAXWindowsIsSeenWithoutAMainWindow() {
        // A sheet lives in its parent's `AXSheets`; the parent is an ordinary window and reports
        // `AXModal == false`, because the modality belongs to the sheet. Routing an absent
        // `AXMainWindow` to a scan that only asks each window "are you modal?" therefore walks past
        // the mandatory New Track sheet entirely and calls the observation clean.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(70)
        let window = builder.element(71)
        let sheet = builder.element(72)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, "Untitled 1 - Tracks")
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setAttribute(window, "AXSheets", [sheet])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        let runtime = builder.makeLogicRuntime(
            appElement: app, setAttributeHandler: nil, performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation: route an absent `AXMainWindow` straight to the top-level modal scan without
        // looking for sheets on the windows that are present; this becomes `.none`.
        // `!= .none` cannot tell a real New Track sheet from an invented unknown_sheet.
        #expect(kind == .mandatoryNewTrack)
    }

    @Test("a mandatory sheet on another non-modal host blocks delete even when AXMainWindow is found")
    func sheetOnAnotherWindowIsSeenWithAMainWindow() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(430)
        let arrange = builder.element(431)
        let sheetHost = builder.element(432)
        let menuBar = builder.element(433)
        let trackMenu = builder.element(434)
        let deleteItem = builder.element(435)
        let headers = builder.element(436)
        let header = builder.element(437)
        let sheet = builder.element(438)
        let create = builder.element(439)
        let cancel = builder.element(440)
        let otherHostSheetReads = LockedCounter()
        let createPresses = LockedCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, sheetHost])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(sheetHost, kAXModalAttribute as String, false)
        builder.setChildren(arrange, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [header])
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [deleteItem])
        builder.setAttribute(deleteItem, kAXTitleAttribute as String, "Delete Track")
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(sheet, [create, cancel])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard CFEqual(element, sheetHost), attribute == "AXSheets" else { return nil }
                _ = otherHostSheetReads.next()
                return .some([sheet] as NSArray)
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == (kAXPressAction as String) else { return false }
                if CFEqual(element, deleteItem) {
                    builder.setChildren(headers, [])
                    return true
                }
                if CFEqual(element, create) {
                    _ = createPresses.next()
                    return true
                }
                return false
            }
        )

        let result = await AccessibilityChannel.defaultDeleteTrack(runtime: runtime)
        try #require(result.isSuccess, "delete must complete its observation path: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let verified = try #require(envelope["verified"] as? Bool)

        // Mutation `auxiliary-found-as-clean`: replace the `.found` branch's
        // `return readModalSignals(from: sheet, runtime: runtime)` with
        // `auxiliarySheetScanIsClean = true`. The non-main host sheet then
        // disappears, two decrement polls look clean, and this fixture
        // incorrectly encodes State A.
        #expect(!verified)
        let reconciledKind = try #require(envelope["reconciled_modal_kind"] as? String)
        #expect(reconciledKind == "mandatory_new_track")
        #expect(otherHostSheetReads.current() > 0, "the non-main host seam must be queried")
        #expect(createPresses.current() == 1, "the classified host sheet must reach its direct Create action")
    }

    @Test("an unclean auxiliary sheet scan gates only the no-blocker conclusion")
    func incompleteOrUnreadableAuxiliarySheetScanDoesNotPreemptPositiveBlocker() async {
        for mode in AuxiliarySheetScanMode.allCases {
            let builder = FakeAXRuntimeBuilder()
            let app = builder.element(450)
            let arrange = builder.element(451)
            let auxiliaryHost = builder.element(452)
            let topLevelNewTrack = builder.element(453)
            let create = builder.element(454)
            let cancel = builder.element(455)
            let auxiliaryGroups = (0..<32).map { builder.element(456 + $0) }
            let auxiliarySheetReads = LockedCounter()
            let auxiliaryTraversalReads = LockedCounter()
            let createPresses = LockedCounter()
            let auxiliaryGroupIDs = Set(auxiliaryGroups.map(builder.elementID))

            builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
            builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, auxiliaryHost, topLevelNewTrack])
            builder.setAttribute(arrange, kAXModalAttribute as String, false)
            builder.setAttribute(auxiliaryHost, kAXModalAttribute as String, false)
            builder.setAttribute(topLevelNewTrack, kAXRoleAttribute as String, kAXWindowRole as String)
            builder.setAttribute(topLevelNewTrack, kAXModalAttribute as String, false)
            builder.setAttribute(topLevelNewTrack, kAXDescriptionAttribute as String, "New Track")
            builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(create, kAXTitleAttribute as String, "Create")
            builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
            builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
            builder.setChildren(topLevelNewTrack, [create, cancel])

            if mode == .incomplete {
                builder.setChildren(auxiliaryHost, [auxiliaryGroups[0]])
                for index in 0..<(auxiliaryGroups.count - 1) {
                    builder.setAttribute(auxiliaryGroups[index], kAXRoleAttribute as String, kAXGroupRole as String)
                    builder.setChildren(auxiliaryGroups[index], [auxiliaryGroups[index + 1]])
                }
                builder.setAttribute(auxiliaryGroups[auxiliaryGroups.count - 1], kAXRoleAttribute as String, kAXGroupRole as String)
            }

            let runtime = builder.makeLogicRuntime(
                appElement: app,
                attributeValueResultHandler: { element, attribute in
                    if CFEqual(element, auxiliaryHost), attribute == "AXSheets" {
                        _ = auxiliarySheetReads.next()
                        switch mode {
                        case .incomplete:
                            return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
                        case .unreadable:
                            return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                        }
                    }
                    if mode == .incomplete,
                       auxiliaryGroupIDs.contains(builder.elementID(element)),
                       attribute == (kAXRoleAttribute as String) {
                        _ = auxiliaryTraversalReads.next()
                    }
                    return nil
                },
                childrenResultHandler: { element in
                    guard mode == .unreadable, CFEqual(element, auxiliaryHost) else { return nil }
                    _ = auxiliaryTraversalReads.next()
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                },
                setAttributeHandler: nil,
                performActionHandler: { element, action in
                    guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
                    _ = createPresses.next()
                    return true
                }
            )

            let uncleanRead = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
            let uncleanKind = ModalReconciliation.classify(uncleanRead.signals)
            builder.setAttribute(topLevelNewTrack, kAXModalAttribute as String, true)
            let outcome = await AccessibilityChannel.reconcileAfterMutation(
                isDeleteContext: false,
                runtime: runtime,
                witnessAttempts: 1,
                witnessDelayNanoseconds: 0
            )

            // Mutation `auxiliary-sheet-failure-preempts-read`: replace
            // `auxiliarySheetScanIsClean = false` with a clean no-modal
            // return. The unclean empty pass would then certify a blocker set
            // it did not fully read; the positive New Track pass still proves
            // that independent discovery and its bound Create action survive.
            #expect(uncleanKind == .none)
            #expect(!uncleanRead.modalObservationIsComplete)
            #expect(outcome.kind == .mandatoryNewTrack)
            #expect(outcome.decision == .clickCreate)
            #expect(outcome.actionAttempted)
            #expect(createPresses.current() == 1)
            #expect(auxiliarySheetReads.current() > 0, "the auxiliary AXSheets failure seam must fire")
            if mode == .incomplete {
                #expect(auxiliaryTraversalReads.current() > 0, "the incomplete auxiliary descendant traversal must reach the depth cap")
            } else {
                #expect(auxiliaryTraversalReads.current() > 0, "the unreadable auxiliary AXChildren traversal seam must fire")
            }
        }
    }

    @Test("an absent main window is an answer for the modal read, not an unknown blocker")
    func absentMainWindowIsAnAnswer() {
        // There is no main-window sheet when there is no main window, and during `project.new`
        // there genuinely is not one between choosing a template and Logic publishing the arrange
        // window. Calling that unreadable made project creation report an unknown blocking sheet
        // during the exact phase it exists to describe. The other two blocker kinds are still read
        // below it, so this remains a complete observation. What a track deletion additionally
        // needs — the window its count came from — is required at that call site instead.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(50)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation: treat an absent `AXMainWindow` as unreadable again; this becomes `.unknownSheet`.
        #expect(kind == .none)
    }

    @Test("an unreadable top-level dialog scan cannot certify a clean blocker set")
    func unreadableTopLevelDialogFailsClosed() {
        for status in [AXError.cannotComplete.rawValue, AXError.attributeUnsupported.rawValue] {
            let builder = FakeAXRuntimeBuilder()
            let app = builder.element(51)
            let window = builder.element(52)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            let runtime = builder.makeLogicRuntime(
                appElement: app,
                attributeValueResultHandler: { element, attribute in
                    guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                    return .failure(AXHelpers.AXStatusError(raw: status))
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            )

            let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
            let kind = ModalReconciliation.classify(read.signals)

            // An unreadable AXWindows list is not a sheet that was seen.
            #expect(kind == .none)
            #expect(!read.modalObservationIsComplete)
            #expect(
                read.unreadableReason == .axWindowsReadFailed(AXHelpers.AXStatusError(raw: status)),
                "the exact AXWindows failure status must survive the modal read"
            )
        }
    }

    @Test("a successful malformed AXWindows payload cannot become no blocking window")
    func malformedSuccessfulAXWindowsFailsClosed() {
        for payload in [MalformedAXWindowsPayload.nilValue, .string] {
            let builder = FakeAXRuntimeBuilder()
            let app = builder.element(441)
            let window = builder.element(442)
            let windowsReads = LockedCounter()
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setAttribute(window, kAXModalAttribute as String, false)
            let runtime = builder.makeLogicRuntime(
                appElement: app,
                attributeValueResultHandler: { element, attribute in
                    guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                    let read = windowsReads.next()
                    if read != 1 { return .success([window] as NSArray) }
                    switch payload {
                    case .nilValue: return .success(nil)
                    case .string: return .success("not-an-array" as NSString)
                    }
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            )

            let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
            let kind = ModalReconciliation.classify(read.signals)

            // Mutation `malformed-axwindows-as-absent`: restore
            // `.success(nil) -> .absent` in `anyWindowSheetLookup`. A typed
            // successful nil / NSString payload then becomes a clean pass.
            #expect(kind == .none)
            #expect(!read.modalObservationIsComplete)
            #expect(read.unreadableReason == .axWindowsPayloadUninterpretable)
            #expect(windowsReads.current() > 0, "the malformed AXWindows seam must be read")
        }
    }

    @Test("a malformed AXWindows payload during the top-level scan is unreadable")
    func malformedSuccessfulTopLevelAXWindowsFailsClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(443)
        let window = builder.element(444)
        let windowsReads = LockedCounter()
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                let read = windowsReads.next()
                return read == 1 ? .success([window] as NSArray) : .success("not-an-array" as NSString)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
        let kind = ModalReconciliation.classify(read.signals)

        // A malformed AXWindows payload is an unreadable scan, not a sheet.
        #expect(kind == .none)
        #expect(!read.modalObservationIsComplete)
        #expect(read.unreadableReason == .axWindowsPayloadUninterpretable)
        #expect(windowsReads.current() > 1, "the top-level AXWindows seam must be reached after the sheet scan")
    }

    @Test("a raw AXWindows CFArray reaches a positively identified New Track modal")
    func rawAXWindowsArrayStillAllowsBoundCreate() async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(445)
        let arrange = builder.element(446)
        let modal = builder.element(447)
        let create = builder.element(448)
        let cancel = builder.element(449)
        let windowsReads = LockedCounter()
        let createPresses = LockedCounter()
        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(modal, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(modal, kAXModalAttribute as String, true)
        builder.setAttribute(modal, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(modal, [create, cancel])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                _ = windowsReads.next()
                return .success([arrange, modal] as NSArray)
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
                _ = createPresses.next()
                return true
            }
        )

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `raw-axwindows-array-as-uninterpretable`: return
        // `.malformed` instead of `.elements` from the raw array decoder. This
        // positively identified modal becomes unknown and its bound Create is
        // never pressed.
        #expect(outcome.kind == .mandatoryNewTrack)
        #expect(outcome.decision == .clickCreate)
        #expect(outcome.actionAttempted)
        #expect(outcome.unreadableReason == nil)
        #expect(windowsReads.current() >= 2, "both the sheet and top-level scans must consume the raw AXWindows seam")
        #expect(createPresses.current() == 1)
    }

    @Test("a generic AXSheets failure defers to an unreadable descendant traversal")
    func genericWindowSheetFailureUsesTraversalFailure() async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(450)
        let window = builder.element(451)
        let sheetReads = LockedCounter()
        let childrenReads = LockedCounter()
        let presses = LockedCounter()
        let genericFailure = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let traversalFailure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                _ = sheetReads.next()
                return .failure(genericFailure)
            },
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                _ = childrenReads.next()
                return .failure(traversalFailure)
            },
            setAttributeHandler: nil,
            performActionHandler: { _, _ in
                _ = presses.next()
                return true
            }
        )

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `axsheet-failure-veto`: restore the AXSheets failure guard.
        // The descendant seam does not fire and the receipt reports
        // `genericFailure` rather than the traversal's cannot-complete status.
        #expect(outcome.kind == .none)
        #expect(!outcome.modalObservationIsComplete)
        #expect(outcome.unreadableReason == .windowSheetReadFailed(traversalFailure))
        #expect(!outcome.actionAttempted)
        #expect(sheetReads.current() == 1, "the AXSheets -25200 seam must fire")
        #expect(childrenReads.current() == 1, "the failed AXChildren traversal seam must fire")
        #expect(presses.current() == 0, "an unreadable traversal must not authorize any action")
    }

    @Test("a missing Logic app root names its receipt cause")
    func appRootFailureIsObservable() {
        let builder = FakeAXRuntimeBuilder()
        let runtime = builder.makeLogicRuntime(
            pid: nil,
            appElement: builder.element(452),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(ModalReconciliation.classify(read.signals) == .none)
        #expect(!read.modalObservationIsComplete)
        #expect(read.unreadableReason == .appRootUnavailable)
    }

    @Test("unreadable modal receipt reasons are stable and status-bearing")
    func unreadableModalReasonsReachReceiptExtras() {
        let status = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let cases: [(AccessibilityChannel.ModalReadFailure, String, Int?)] = [
            (.appRootUnavailable, "app_root_unavailable", nil),
            (.axWindowsPayloadUninterpretable, "axwindows_payload_uninterpretable", nil),
            (.axWindowsReadFailed(status), "axwindows_read_failed", Int(status.raw)),
            (.windowSheetReadFailed(status), "window_sheet_read_failed", Int(status.raw)),
            (.descendantTraversalDepthCap, "descendant_traversal_depth_cap", nil),
        ]

        for (failure, expectedReason, expectedStatus) in cases {
            var extras: [String: Any] = [:]
            AccessibilityChannel.mergeReconcileExtras(
                &extras,
                kind: .unknownSheet,
                action: "none",
                newTrackAutoConfirmed: false,
                unreadableReason: failure
            )

            // Mutation `modal-unreadable-reason-flattened`: emit a generic
            // `unknown_sheet` reason for every failure. These distinct expected
            // values make a wrong diagnostic cause externally detectable.
            #expect(extras["reconciled_modal_unreadable_reason"] as? String == expectedReason)
            if let expectedStatus {
                #expect(extras["reconciled_modal_unreadable_ax_status"] as? Int == expectedStatus)
                // `symbolicName` carries Apple's own constant spelling, which is what a field named
                // `..._status_name` should say; the snake_case form is `diagnosticLabel`, a different
                // property. The two met at the main merge and this expectation was the older one.
                #expect(extras["reconciled_modal_unreadable_ax_status_name"] as? String == "cannotComplete")
            } else {
                #expect(extras["reconciled_modal_unreadable_ax_status"] == nil)
                #expect(extras["reconciled_modal_unreadable_ax_status_name"] == nil)
            }
        }
    }

    @Test("project creation retries an unreadable AXWindows pass until New Track is readable")
    func projectCreationRetriesUnreadableModalObservation() async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(453)
        let window = builder.element(454)
        let sheet = builder.element(455)
        let create = builder.element(456)
        let cancel = builder.element(457)
        let windowsReads = LockedCounter()
        let sheetReads = LockedCounter()
        let createPresses = LockedCounter()
        let createWasPressed = LockedFlag()
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setAttribute(window, kAXTitleAttribute as String, "Untitled 55 - Tracks")
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(sheet, [create, cancel])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                let read = sheetReads.next()
                if createWasPressed.get() { return .some([] as NSArray) }
                return read == 1 ? .some([] as NSArray) : .some([sheet] as NSArray)
            },
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, sheet),
                   attribute == (kAXRoleAttribute as String),
                   createWasPressed.get() {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
                }
                guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                return windowsReads.next() == 1
                    ? .success("not-an-array" as NSString)
                    : .success([window] as NSArray)
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
                _ = createPresses.next()
                createWasPressed.set()
                return true
            }
        )

        _ = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: runtime,
            selection: "Empty Project",
            observationAttempts: 3,
            observationDelayNanoseconds: 0
        )

        // Mutation `project-new-unreadable-terminal`: restore the former
        // immediate State-B return for `.unknownSheet`. The second poll never
        // reads this mandatory sheet and the bound Create seam stays at zero.
        #expect(windowsReads.current() >= 2, "the unreadable AXWindows fixture must be retried")
        #expect(sheetReads.current() >= 2, "the later mandatory-sheet fixture must be reached")
        #expect(createPresses.current() == 1)
    }

    @Test("generic AXSheets failures retire only polls when descendant traversal is temporarily unreadable")
    func projectCreationRetriesGenericAXSheetsFailureTraversal() async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(458)
        let window = builder.element(459)
        let sheet = builder.element(460)
        let group = builder.element(461)
        let create = builder.element(462)
        let cancel = builder.element(463)
        let sheetReads = LockedCounter()
        let traversalReads = LockedCounter()
        let failedPolls = LockedCounter()
        let failedPollsBeforeAnyAction = LockedCounter()
        let createPresses = LockedCounter()
        let createWasPressed = LockedFlag()
        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let genericFailure = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(create, kAXEnabledAttribute as String, true)
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(window, [sheet])
        builder.setChildren(sheet, [group])
        builder.setChildren(group, [create, cancel])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, window), attribute == "AXSheets" {
                    _ = sheetReads.next()
                    return .failure(genericFailure)
                }
                if CFEqual(element, sheet),
                   attribute == (kAXRoleAttribute as String),
                   createWasPressed.get() {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
                }
                return nil
            },
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                let read = traversalReads.next()
                if read <= 3 {
                    _ = failedPolls.next()
                    if createPresses.current() == 0 {
                        _ = failedPollsBeforeAnyAction.next()
                    }
                    return .failure(cannotComplete)
                }
                return .success([sheet])
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
                _ = createPresses.next()
                createWasPressed.set()
                return true
            }
        )

        _ = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: runtime,
            selection: "Empty Project",
            observationAttempts: 4,
            observationDelayNanoseconds: 0
        )

        // Mutation `axsheet-failure-veto`: restore the former AXSheets
        // failure return in `firstSheetLookup`. AXChildren never fires, so the
        // positive sheet cannot be found on the fourth poll and these
        // expectations fail. This also proves the first three unreadable
        // traversal polls did not authorize an action or terminate the
        // operation.
        #expect(createPresses.current() == 1)
        #expect(failedPolls.current() == 3, "all three unreadable AXChildren polls must retire only their polls")
        #expect(failedPollsBeforeAnyAction.current() == 3, "an unreadable traversal must not press before it becomes readable")
        #expect(sheetReads.current() > 3, "each retry must consume the AXSheets -25200 seam")
        #expect(traversalReads.current() > 3, "the fourth poll must reach the readable AXChildren fallback")
    }

    @Test("an AXSystemDialog remains a blocker instead of becoming no alert")
    func systemDialogFailsClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(53)
        let window = builder.element(54)
        let systemDialog = builder.element(55)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window, systemDialog])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setAttribute(systemDialog, kAXModalAttribute as String, true)
        builder.setAttribute(systemDialog, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)
        let runtime = builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: nil)

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation `system-modal-attribute-omission`: remove AXModal from the
        // scan; this AXSystemDialog would be omitted and the pass would look clean.
        #expect(kind == .unknownSheet)
    }

    @Test("an AXModal floating window blocks a clean modal observation")
    func floatingModalWindowFailsClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(56)
        let arrange = builder.element(57)
        let goToPosition = builder.element(58)
        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, goToPosition])
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(goToPosition, kAXSubroleAttribute as String, "AXFloatingWindow")
        builder.setAttribute(goToPosition, kAXModalAttribute as String, true)

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: builder.makeLogicRuntime(appElement: app)
        ))

        // Mutation `floating-modal-attribute-omission`: restore the former
        // AXDialog/AXSystemDialog allowlist. The known Go To Position shape then
        // disappears and the complete scan falsely returns `.none`.
        #expect(kind == .unknownSheet)
    }

    @Test("the complete scan retains its status-preserving AXDialog subrole")
    func observedDialogSubroleIsNotRereadBestEffort() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(59)
        let arrange = builder.element(60)
        let dialog = builder.element(61)
        let subroleReads = LockedCounter()
        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, dialog])
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(dialog, kAXModalAttribute as String, true)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, dialog), attribute == (kAXSubroleAttribute as String) else {
                    return nil
                }
                return subroleReads.next() == 1
                    ? .success(kAXDialogSubrole as NSString)
                    : .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation `observed-subrole-reread`: call the best-effort dialog
        // helper without the captured subrole. Its second, failed read makes an
        // already-observed AXDialog vanish from the complete blocker set.
        #expect(kind == .unknownSheet)
        #expect(subroleReads.current() == 1)
    }

    @Test("an unreadable menu scan cannot certify a clean blocker set")
    func unreadableStrayMenuFailsClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(56)
        let window = builder.element(57)
        let menuBar = builder.element(58)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, menuBar) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
        let kind = ModalReconciliation.classify(read.signals)

        // A failed menu-child read is not a sheet that was seen.
        #expect(kind == .none)
        #expect(!read.modalObservationIsComplete)
        #expect(read.unreadableReason == .strayMenuReadFailed)
    }

    @Test("missing or malformed AXModal is not a clean non-modal answer")
    func indeterminateAXModalFailsClosed() {
        let unsupportedKind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: makeIndeterminateModalRuntime(.unsupported)
        ))
        let noValueKind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: makeIndeterminateModalRuntime(.noValue)
        ))
        let malformedKind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: makeIndeterminateModalRuntime(.malformed)
        ))

        // Each of these windows must stop a State-A clean observation, without
        // being serialized as a sheet that was never seen.
        #expect(unsupportedKind == .none)
        #expect(noValueKind == .none)
        #expect(malformedKind == .none)
        #expect(!AccessibilityChannel.readModalSignalsAndAlertTarget(
            runtime: makeIndeterminateModalRuntime(.unsupported)
        ).modalObservationIsComplete)
        #expect(!AccessibilityChannel.readModalSignalsAndAlertTarget(
            runtime: makeIndeterminateModalRuntime(.noValue)
        ).modalObservationIsComplete)
        #expect(!AccessibilityChannel.readModalSignalsAndAlertTarget(
            runtime: makeIndeterminateModalRuntime(.malformed)
        ).modalObservationIsComplete)
    }

    @Test("an alert replacement is retained in the bound witness receipt")
    func boundAlertWitnessSeesReplacementBlocker() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(70)
        let arrange = builder.element(71)
        let alert = builder.element(72)
        let acknowledge = builder.element(73)
        let replacement = builder.element(74)
        let pressed = LockedFlag()

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(alert, kAXModalAttribute as String, true)
        builder.setAttribute(alert, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(acknowledge, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(acknowledge, kAXTitleAttribute as String, "OK")
        builder.setChildren(alert, [acknowledge])
        builder.setAttribute(replacement, kAXModalAttribute as String, true)
        builder.setAttribute(replacement, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                return .some((pressed.get() ? [arrange, replacement] : [arrange, alert]) as NSArray)
            },
            attributeValueResultHandler: { element, attribute in
                guard pressed.get(),
                      CFEqual(element, alert),
                      attribute == (kAXModalAttribute as String)
                else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, acknowledge), action == (kAXPressAction as String) else { return false }
                pressed.set()
                return true
            }
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )
        let summary = try #require(outcome.witnessSummary)
        let blockerSetClear = try #require(summary.blockerSetClear as Bool?)

        // Mutation `alert-bound-complete-witness`: restore the old unbound
        // AXDialog-only witness and causal `performed` conjunction. The bound
        // alert element itself is invalidated (correctly observed gone, #538),
        // but the AXSystemDialog replacement still blocks — `performed` must
        // stay false and the complete blocker-set scan must stay unclear.
        #expect(outcome.kind == .informationalAlert)
        #expect(outcome.actionAttempted)
        #expect(!outcome.performed)
        #expect(
            summary.observedGone,
            "#538: invalidUIElement on the bound alert element IS its closure signal and must be observed gone."
        )
        #expect(!blockerSetClear)
    }

    @Test("a menu replacement is retained in the bound witness receipt")
    func boundMenuWitnessSeesReplacementBlocker() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(80)
        let arrange = builder.element(81)
        let menuBar = builder.element(82)
        let selectedMenu = builder.element(83)
        let replacement = builder.element(84)
        let escaped = LockedFlag()

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setChildren(menuBar, [selectedMenu])
        builder.setAttribute(replacement, kAXModalAttribute as String, true)
        builder.setAttribute(replacement, kAXSubroleAttribute as String, kAXFloatingWindowSubrole as String)

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                if CFEqual(element, app), attribute == (kAXWindowsAttribute as String) {
                    return .some((escaped.get() ? [arrange, replacement] : [arrange]) as NSArray)
                }
                if CFEqual(element, selectedMenu), attribute == (kAXSelectedAttribute as String) {
                    return .some(NSNumber(value: !escaped.get()))
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil,
            executeAppleScript: { _ in
                escaped.set()
                return .success("escaped")
            }
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )
        let summary = try #require(outcome.witnessSummary)
        let blockerSetClear = try #require(summary.blockerSetClear as Bool?)

        // Mutation `menu-bound-complete-witness`: restore the old menu-bar-wide
        // gone scan and causal `performed` conjunction. Its classified item is
        // deselected, yet the modal floating replacement still blocks.
        #expect(outcome.kind == .strayMenu)
        #expect(outcome.actionAttempted)
        #expect(!outcome.performed)
        #expect(summary.observedGone)
        #expect(!blockerSetClear)
    }

    @Test("an accepted Create with a gone bound sheet reports observations, not causation")
    func acceptedCreateGoneSheetIsNotPerformed() async throws {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: true, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: false)
        let witness = try #require(outcome.witnessSummary)

        // Mutation `sheet-close-causation-create`: restore a causal `performed`
        // conjunction. A user-close between AX accepting the press and this
        // witness is indistinguishable, so only the press and gone observation
        // may be reported — never promoted to `performed`.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
        #expect(
            witness.observedGone,
            "#538: invalidUIElement on the bound sheet element IS its closure signal and must be observed gone."
        )
        #expect(try #require(witness.blockerSetClear))
        #expect(
            !fixture.ordinalFallbackUsed.get(),
            "Mutation caught: replace the bound Create press with an ordinal fallback; only the captured Create element may produce this success."
        )
    }

    @Test("a replacement sheet after invalidation is not attributed to the Create press")
    func acceptedCreateWithReplacementSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: true, postAction: .replaced)

        let outcome = await reconcile(fixture, isDeleteContext: false)

        // Mutation source: remove the fresh complete modal scan from Create's
        // `performed` conjunction; the stale bound reference alone would make
        // this replacement sheet look like a created track.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
    }

    @Test("accepted Create with a persistent sheet is not performed")
    func acceptedCreatePersistentSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: true, postAction: .present)

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            !outcome.performed,
            "Mutation caught: replace `action.accepted && summary.observedGone` with `action.accepted`; an accepted Create while the bound sheet persists would become performed."
        )
    }

    @Test("rejected Create with a gone sheet is not performed")
    func rejectedCreateGoneSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: false, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            !outcome.performed,
            "Mutation caught: remove `action.accepted &&` and use only `summary.observedGone`; a rejected Create with an independently gone sheet would become performed."
        )
    }

    @Test("an accepted delete confirmation with a gone bound sheet reports observations, not causation")
    func acceptedDeleteGoneSheetIsNotPerformed() async throws {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: true, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: true)
        let witness = try #require(outcome.witnessSummary)

        // Mutation `sheet-close-causation-delete`: restore a causal `performed`
        // conjunction. The action was directly attempted and the target is gone,
        // but those observations cannot establish who closed the sheet — never
        // promoted to `performed`.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
        #expect(
            witness.observedGone,
            "#538: invalidUIElement on the bound sheet element IS its closure signal and must be observed gone."
        )
        #expect(try #require(witness.blockerSetClear))
        #expect(
            !fixture.ordinalFallbackUsed.get(),
            "Mutation caught: replace the bound delete press with an ordinal fallback; only the captured destructive button may produce this success."
        )
    }

    @Test("a replacement sheet after delete confirmation is not attributed to the Delete press")
    func acceptedDeleteWithReplacementSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: true, postAction: .replaced)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        // Mutation source: remove the fresh complete modal scan from delete's
        // `performed` conjunction; the stale bound reference would mark the
        // Delete press performed while another sheet is still blocking.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
    }

    @Test("accepted delete confirmation with a persistent sheet is not performed")
    func acceptedDeletePersistentSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: true, postAction: .present)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        #expect(
            !outcome.performed,
            "Mutation caught: replace `action.accepted && summary.observedGone` with `action.accepted`; an accepted delete press while its bound sheet persists would become performed."
        )
    }

    @Test("rejected delete confirmation with a gone sheet is not performed")
    func rejectedDeleteGoneSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: false, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        #expect(
            !outcome.performed,
            "Mutation caught: remove either conjunct from `action.accepted && summary.observedGone`; a rejected delete press with an independently gone sheet would become performed."
        )
    }

    @Test("the witness remains on the classified sheet when AXMainWindow changes")
    func boundWitnessIgnoresRawMainWindowDrift() async {
        let fixture = makeBoundSheetFixture(
            action: .create,
            actionAccepted: true,
            postAction: .present,
            rawMainWindowDriftsToAuxiliary: true
        )

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            !outcome.performed,
            "Mutation caught: replace the bound-sheet witness with a fresh kAXMainWindow lookup; the auxiliary window has no sheet and would falsely report gone."
        )
        #expect(
            outcome.sheetWitness.map(\.observation) == [.present],
            "Mutation caught: observe a different window instead of the classifier-bound sheet; the original sheet must remain visible to this witness."
        )
        #expect(
            !fixture.ordinalFallbackUsed.get(),
            "Mutation caught: invoke an ordinal fallback while the captured sheet is still present; the witness test must remain direct-element-only."
        )
    }

    @Test("the confirmation scan stays on the original sheet host when AXMainWindow drifts")
    func confirmationScanUsesOriginalSheetHost() async throws {
        let fixture = makeBoundSheetFixture(
            action: .create,
            actionAccepted: true,
            postAction: .replaced,
            rawMainWindowDriftsToAuxiliary: true
        )

        let outcome = await reconcile(fixture, isDeleteContext: false)
        let summary = try #require(outcome.witnessSummary)
        let clear = try #require(summary.blockerSetClear as Bool?)

        // Mutation `confirmation-main-window-reresolution`: change the actual
        // post-action complete scan to resolve AXMainWindow again. The auxiliary
        // window has no sheet and would hide the replacement still attached to
        // the arrange window, producing a false clean production receipt.
        #expect(!clear)
    }

    @Test("a failed native press does not trigger an ordinal fallback")
    func rejectedNativePressDoesNotFallbackToOrdinalWindow() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: false, postAction: .present)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        #expect(
            !outcome.performed,
            "Mutation caught: promote a rejected direct AXPress to performed; this rejected press must stay unperformed."
        )
        #expect(
            !fixture.ordinalFallbackUsed.get(),
            "Mutation caught: invoke the former ordinal AppleScript fallback after a failed native press; this fixture observes that injected AppleScript seam."
        )
    }

    @Test("a native action status is retained for diagnostics")
    func staleActionStatusIsRetained() async {
        let stale = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)
        let fixture = makeBoundSheetFixture(
            action: .create,
            actionAccepted: false,
            postAction: .present,
            actionFailure: stale
        )

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            outcome.actionFailure == .status(stale),
            "Mutation caught: flatten AXUIElementPerformAction's invalidUIElement status to false; the stale captured-button diagnostic would be lost."
        )
    }

    @Test("a native action status is surfaced in reconciliation extras")
    func staleActionStatusReachesExtras() throws {
        let stale = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)
        var extras: [String: Any] = [:]

        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .mandatoryNewTrack,
            action: AccessibilityChannel.reconcileActionLabel(.clickCreate),
            newTrackAutoConfirmed: false,
            actionFailure: .status(stale)
        )

        let diagnostic = try #require(extras["reconcile_action_error"] as? String)
        #expect(
            diagnostic == "ax_\(AXError.invalidUIElement.rawValue)",
            "Mutation caught: remove `actionFailure` from `mergeReconcileExtras`; the raw invalidUIElement rejection would not reach callers."
        )
    }

    @Test("only a none reconciliation is a settled clean modal observation")
    func deletionCleanObservationRequiresNoModalKind() {
        let cases: [(kind: ModalReconciliation.BlockingModalKind, performed: Bool, expected: Bool)] = [
            (.none, false, true),
            (.mandatoryNewTrack, true, false),
            (.deleteConfirm, false, false),
            (.informationalAlert, false, false),
            (.strayMenu, true, false),
            (.unknownSheet, false, false),
        ]

        // Asserted per row, not through a labelled-tuple comparison in a loop: that form was
        // measured not to fail when the function under test was hard-coded.
        for testCase in cases {
            let outcome = AccessibilityChannel.ModalReconcileOutcome(
                kind: testCase.kind,
                decision: .noAction,
                performed: testCase.performed
            )
            let actual = AccessibilityChannel.deletionModalObservationIsSettledClean(
                outcome, arrangeWindowWasRead: true
            )
            if testCase.expected {
                #expect(actual)
            } else {
                #expect(!actual)
            }
        }

        // The arrange window is where the track count came from. A decrement observed while it
        // cannot be resolved is a transient AX failure shaped like a successful delete, so no
        // modal outcome may certify it clean.
        // Mutation: drop `arrangeWindowWasRead` from the conjunction; this assertion becomes true.
        #expect(!AccessibilityChannel.deletionModalObservationIsSettledClean(
            AccessibilityChannel.ModalReconcileOutcome(kind: .none, decision: .noAction, performed: false),
            arrangeWindowWasRead: false
        ))
    }

    @Test("State A gate truth table requires both a decrement and a settled clean observation")
    func deletionStateAGateTruthTable() {
        // Written as four separate bindings rather than a loop over labelled tuples. The loop form
        // was measured NOT to detect its own mutation: with the gate hard-coded to `false`, every
        // row still passed while a plain `#expect(Bool(false))` in the same test failed. A gate
        // this load-bearing has to be asserted in a form that was watched to fail.
        let neither = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: false, settledCleanModalObservation: false
        )
        let cleanOnly = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: false, settledCleanModalObservation: true
        )
        let countOnly = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: true, settledCleanModalObservation: false
        )
        let both = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: true, settledCleanModalObservation: true
        )

        // Mutation: drop `settledCleanModalObservation` from the conjunction — `countOnly` becomes
        // true. Drop `observedTrackCountDecreased` — `cleanOnly` becomes true. Hard-code either
        // constant — `both` or the three negatives break.
        #expect(!neither)
        #expect(!cleanOnly)
        #expect(!countOnly)
        #expect(both)
    }

    @Test("State A waits for two consecutive complete clean modal observations")
    func deletionCleanObservationStreakRequiresTwoPasses() {
        let oneCleanObservation = AccessibilityChannel.deletionCleanObservationStreakIsSettled(1)
        let twoCleanObservations = AccessibilityChannel.deletionCleanObservationStreakIsSettled(2)

        // Mutation source: change the threshold from `>= 2` to `>= 1`; the
        // first binding becomes true and exposes the single-snapshot race.
        #expect(!oneCleanObservation)
        #expect(twoCleanObservations)
    }

    @Test("a mandatory sheet on the AXWindows arrange target cannot be skipped by AXMainWindow absence")
    func deleteBindsSheetReadToResolvedArrangeWindow() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(120)
        let arrange = builder.element(121)
        let menuBar = builder.element(122)
        let trackMenu = builder.element(123)
        let deleteItem = builder.element(124)
        let headers = builder.element(125)
        let header = builder.element(126)
        let sheet = builder.element(127)
        let create = builder.element(128)
        let cancel = builder.element(129)

        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setChildren(arrange, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [header])
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setChildren(trackMenu, [deleteItem])
        builder.setAttribute(deleteItem, kAXTitleAttribute as String, "Delete Track")
        // Production shape: the sheet is modal, its HOST window is not. Leaving AXModal unset made
        // the fake answer success(nil), which classifies as unreadable — a state the real app does
        // not produce, and one that hides whether the act path can see the sheet at all.
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(arrange, "AXSheets", [sheet])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(sheet, [create, cancel])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXMainWindowAttribute as String) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, deleteItem), action == (kAXPressAction as String) else { return false }
                builder.setChildren(headers, [])
                return true
            }
        )

        let result = await AccessibilityChannel.defaultDeleteTrack(runtime: runtime)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let verified = try #require(envelope["verified"] as? Bool)

        // Mutation: replace the poll's bound `arrangeWindow` modal read with the
        // direct AXMainWindow read. It classifies -25205 as absent, skips this
        // attached mandatory sheet, and incorrectly returns State A after two
        // clean-looking count polls.
        // The ACT path must see the same sheet the observation did. It goes through
        // `reconcileAfterMutation`, which resolves the host itself — so before the any-window sheet
        // lookup existed, the observation blocked State A while the action never pressed Create and
        // the envelope named no modal at all. Logic was left on a sheet whose Cancel is disabled.
        let reconciledKind: String = envelope["reconciled_modal_kind"] as? String ?? "ABSENT"
        let reconciledAction: String = envelope["reconciled_action"] as? String ?? "ABSENT"
        #expect(reconciledKind == "mandatory_new_track")
        #expect(reconciledAction == "click_create")
        #expect(!verified)
    }

    @Test("a failed header traversal is not an observed zero count for delete verification")
    func deleteDoesNotTreatUnreadableTrackTraversalAsEmptyRail() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(140)
        let window = builder.element(141)
        let menuBar = builder.element(142)
        let trackMenu = builder.element(143)
        let deleteItem = builder.element(144)
        let headers = builder.element(145)
        let header = builder.element(146)
        let deleted = LockedFlag()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        // Keep a normal non-dialog top-level window in the complete modal scan,
        // so this fixture isolates the header traversal error from an unrelated
        // empty-AXWindows read.
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [header])
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setChildren(trackMenu, [deleteItem])
        builder.setAttribute(deleteItem, kAXTitleAttribute as String, "Delete Track")

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenHandler: { element in
                CFEqual(element, headers) && deleted.get() ? [] : nil
            },
            childrenResultHandler: { element in
                guard CFEqual(element, headers), deleted.get() else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, deleteItem), action == (kAXPressAction as String) else { return false }
                deleted.set()
                return true
            }
        )

        let result = await AccessibilityChannel.defaultDeleteTrack(runtime: runtime)
        let postDeleteHeaderRead = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        let traversalWasUnreadable: Bool
        if case .unreadable = postDeleteHeaderRead {
            traversalWasUnreadable = true
        } else {
            traversalWasUnreadable = false
        }
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let verified = try #require(envelope["verified"] as? Bool)
        let trackCountAfterWasUnobserved = envelope["track_count_after"] is NSNull
        let observedDeltaWasUnobserved = envelope["observed_delta"] is NSNull

        // Mutation `unreadable-after-count-echo`: restore `beforeCount` as the
        // post-delete fallback. Four unreadable reads would then masquerade as a
        // successfully observed no-delta result.
        #expect(traversalWasUnreadable)
        #expect(!verified)
        #expect(trackCountAfterWasUnobserved)
        #expect(observedDeltaWasUnobserved)
    }

    @Test("a readable empty Track Headers rail ignores an unrelated unreadable subtree")
    func readableTrackHeadersIgnoreUnrelatedUnreadableSubtree() {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(150)
        let headers = builder.element(151)
        let unrelatedInspector = builder.element(152)
        builder.setChildren(window, [headers, unrelatedInspector])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [])
        builder.setAttribute(unrelatedInspector, kAXRoleAttribute as String, kAXGroupRole as String)
        let runtime = builder.makeLogicRuntime(
            childrenResultHandler: { element in
                guard CFEqual(element, unrelatedInspector) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        let observedEmptyRail: Bool
        if case .read(let headers) = read {
            observedEmptyRail = headers.isEmpty
        } else {
            observedEmptyRail = false
        }

        // Mutation `whole-window-strict-track-traversal`: make an unrelated
        // child failure abort candidate discovery. The readable empty rail then
        // becomes `.unreadable` even though its own children were read.
        #expect(observedEmptyRail)
    }

    @Test("the complete modal scan ignores a plug-in editor AXDialog")
    func pluginEditorDoesNotBlockCleanModalRead() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(160)
        let arrange = builder.element(161)
        let editor = builder.element(162)
        let close = builder.element(163)
        let bypass = builder.element(164)

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(editor, kAXModalAttribute as String, true)
        builder.setAttribute(editor, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(editor, kAXCloseButtonAttribute as String, close)
        builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(bypass, kAXDescriptionAttribute as String, "bypass")
        builder.setChildren(editor, [bypass])

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: builder.makeLogicRuntime(appElement: app)
        ))

        // Mutation `plugin-editor-exclusion-after-axmodal`: skip the shared
        // plug-in-editor exclusion after AXModal confirms modality. This editor
        // becomes unknownSheet and no successful delete can accumulate a clean
        // streak.
        #expect(kind == .none)
    }

    @Test("the complete modal scan ignores the Drummer Smart Controls AXDialog")
    func smartControlsDoesNotBlockCleanModalRead() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(170)
        let arrange = builder.element(171)
        let controls = builder.element(172)
        let toggle = builder.element(173)

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [controls, arrange])
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(controls, kAXModalAttribute as String, true)
        builder.setAttribute(controls, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(controls, kAXTitleAttribute as String, "")
        builder.setAttribute(toggle, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(toggle, kAXDescriptionAttribute as String, "Smart Controls")
        builder.setChildren(controls, [toggle])

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: builder.makeLogicRuntime(appElement: app)
        ))

        // Mutation `smart-controls-exclusion-after-axmodal`: bypass the shared Smart Controls exclusion in the complete
        // scan. This ordinary pane is then promoted to unknownSheet.
        #expect(kind == .none)
    }

    @Test("a refused reconciliation does not serialize an unattempted decision as an action")
    func unattemptedReconcileDecisionUsesNoneActionLabel() {
        let outcome = AccessibilityChannel.ModalReconcileOutcome(
            kind: .informationalAlert,
            decision: .acknowledgeAlert,
            performed: false,
            actionAttempted: false,
            refusal: .targetGone
        )
        var extras: [String: Any] = [:]
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: outcome.kind,
            action: AccessibilityChannel.attemptedReconcileActionLabel(outcome),
            newTrackAutoConfirmed: false,
            refusal: outcome.refusal
        )

        // Mutation: return `reconcileActionLabel(outcome.decision)` without the
        // `actionAttempted` guard. A successful creation would then publish
        // `acknowledge_alert` beside `alert_target_gone` despite no press.
        #expect(extras["reconciled_action"] as? String == "none")
        #expect(extras["reconcile_refused"] as? String == "alert_target_gone")
    }

    @Test("mandatory-track creation requires a positive post-action track count")
    func mandatoryTrackCreationRequiresTrackCount() {
        let sheetGoneWithoutTrack = AccessibilityChannel.mandatoryTrackCreationWasObserved(
            sheetGoneObserved: true,
            observedTrackCount: 0
        )
        let sheetGoneWithTrack = AccessibilityChannel.mandatoryTrackCreationWasObserved(
            sheetGoneObserved: true,
            observedTrackCount: 1
        )

        // Mutation `mandatory-track-positive-count`: drop `observedTrackCount > 0`; an invalidated sheet
        // with no project-level track read would become `mandatory_track_created`.
        #expect(!sheetGoneWithoutTrack)
        #expect(sheetGoneWithTrack)
    }

    @Test("project.new does not report a mandatory track without a post-Create track count")
    func projectNewDoesNotPromoteCreateToTrackFact() async throws {
        let fixture = makeProjectNewPerformedCreateWithoutTrackFixture()

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime,
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        // Mutation `project-new-sheet-close-causation`: restore the former
        // causal `performed` result for an accepted Create followed by sheet
        // disappearance. Without an independently observed track, project.new
        // must not publish a `mandatory_track_created` fact at all.
        #expect(!result.isSuccess)
        #expect(envelope["mandatory_track_created"] == nil)
    }

    @Test("project.new observes the mandatory sheet close and positive track count through production reconciliation")
    func projectNewReachesMandatoryTrackVerification() async throws {
        let fixture = makeProjectNewPerformedCreateWithTrackFixture()

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime,
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let mandatoryTrackCreated = try #require(envelope["mandatory_track_created"] as? Bool)

        // Mutation `project-new-production-performed-gate`: restore the former
        // `guard outcome.performed` before the real post-sheet track read. Sheet
        // actions intentionally never claim causation, so this production path
        // must instead reach the positive count verification below it.
        #expect(result.isSuccess)
        #expect(mandatoryTrackCreated)
        #expect(fixture.createPresses.current() == 1)
    }

    @Test("project.new does not latch mandatory-track completion when the blocker scan is clear but the bound sheet is still readable")
    func projectNewDoesNotLatchWhenBlockerScanClearsWithoutBoundSheetGone() async throws {
        // #538: `blockerSetClear == true` alone is not the sheet-gone conclusion. Here the
        // follow-up full scan reports no blocker (AXSheets == []) while the sheet THIS run
        // captured never became invalid — its AXRole keeps reading back successfully. If the
        // consumer regresses to `blockerSetClear == true` alone, this fixture publishes
        // `mandatory_track_created`.
        let fixture = makeProjectNewPerformedCreateWithTrackFixture(
            boundSheetStaysReadableAfterAction: true
        )

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime,
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )

        #expect(!result.isSuccess)
        #expect(envelope["mandatory_track_created"] == nil)
        #expect(fixture.createPresses.current() == 1, "the Create press seam must have fired")
        #expect(
            fixture.divergentBoundReadObserved.get(),
            "the still-readable-after-action seam must have fired at least once, or this test proves nothing"
        )
    }

    @Test("project.new does not latch mandatory-track completion when the bound sheet is gone but the blocker scan finds a replacement")
    func projectNewDoesNotLatchWhenBoundSheetGoneWithoutBlockerScanClear() async throws {
        // #538: `observedGone == true` alone is not the sheet-gone conclusion either. Here the
        // bound sheet this run pressed Create on is invalidated, but a fresh full scan finds a
        // different New Track sheet still attached to the arrange window. If the consumer
        // regresses to `observedGone == true` alone, this fixture publishes
        // `mandatory_track_created` off the back of a different sheet's presence.
        let fixture = makeProjectNewPerformedCreateWithTrackFixture(
            blockerScanFindsReplacementAfterAction: true
        )

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime,
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )

        #expect(!result.isSuccess)
        #expect(envelope["mandatory_track_created"] == nil)
        #expect(fixture.createPresses.current() == 1, "the Create press seam must have fired")
        #expect(
            fixture.divergentScanObserved.get(),
            "the replacement-sheet scan seam must have fired at least once, or this test proves nothing"
        )
    }

    @Test("project.new does not certify the arrange window while a live informational alert was just observed")
    func projectNewDoesNotCertifyWindowWhileInformationalAlertObserved() async throws {
        // #538: `case .none, .informationalAlert, .strayMenu: break` let a poll that
        // OBSERVED a live one-button alert fall straight through to the arrange-window
        // check, as if `.informationalAlert` were the same as `.none`. With a single
        // observation attempt, the alert is still up on the only poll this run gets —
        // an attempted acknowledgement is not proof it closed. The fixed behaviour must
        // report the persistent blocker honestly instead of certifying
        // `created_project_window_observed` off an alert-carrying poll.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(920)
        let arrange = builder.element(921)
        let alert = builder.element(922)
        let acknowledge = builder.element(923)

        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, alert])
        builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(arrange, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        builder.setAttribute(arrange, kAXTitleAttribute as String, "Untitled 1 - Tracks")
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(alert, kAXModalAttribute as String, true)
        builder.setAttribute(alert, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(acknowledge, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(acknowledge, kAXTitleAttribute as String, "OK")
        builder.setChildren(alert, [acknowledge])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                CFEqual(element, acknowledge) && action == (kAXPressAction as String)
            }
        )

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: runtime,
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let phase = try #require(envelope["phase"] as? String)

        // Mutation `project-new-alert-break-through`: restore
        // `case .none, .informationalAlert, .strayMenu: break`. The exact-title
        // arrange window this fixture already exposes then certifies on the
        // very poll that observed the alert.
        #expect(!result.isSuccess)
        #expect(phase != "created_project_window_observed")
        #expect(envelope["window_title"] == nil)
    }

    @Test("a delete-confirm followed by New Track presses each classifier-bound action once")
    func sequentialDeleteAndMandatorySheetEachReceiveOneAction() async throws {
        let fixture = makeSequentialDeleteSheetFixture()

        let result = await AccessibilityChannel.defaultDeleteTrack(runtime: fixture.runtime)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let action = try #require(envelope["reconciled_action"] as? String)
        let autoConfirmed = (envelope["new_track_dialog_auto_confirmed"] as? Bool) ?? false

        // Mutation source: restore the former operation-wide action latch; the
        // delete confirm still presses, but the later mandatory Create count is
        // zero while its decision label would be falsely reported as a press.
        #expect(fixture.deleteConfirmPresses.get() == 1)
        #expect(fixture.createPresses.get() == 1)
        #expect(action == "click_create")
        // Mutation `new-track-auto-confirmed-performed-gate`: restore
        // `mandatoryNewTrackReconciliationPerformed = outcome.performed`.
        // Sheet actions intentionally never claim causal performance, so this
        // direct Create press would lose its auto-confirmation receipt.
        #expect(autoConfirmed)
    }

    @Test("project.new preserves a stale Create status in its unconfirmed envelope")
    func projectNewUnconfirmedCreatePreservesActionError() async throws {
        let fixture = makeProjectNewStaleCreateFixture()

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime,
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let actionError = try #require(envelope["reconcile_action_error"] as? String)

        // Mutation source: remove `outcome.actionFailure` from the mandatory
        // create-unconfirmed extras; the direct stale Create status disappears.
        #expect(!result.isSuccess)
        #expect(actionError == "ax_\(AXError.invalidUIElement.rawValue)")
    }

    @Test("project.new retries a description-only New Track pass until Create is published")
    func projectNewWaitsForDelayedCreateControl() async throws {
        let fixture = makeProjectNewDelayedCreateFixture()

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime,
            selection: "Empty Project",
            observationAttempts: 2,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let mandatoryTrackCreated = try #require(envelope["mandatory_track_created"] as? Bool)

        // Mutation `project-new-terminal-description-only-pass`: restore the
        // former unconditional unconfirmed return after the first mandatory
        // classification. The second pass never sees the newly published Create
        // element, so this becomes a State B error with zero direct presses.
        #expect(result.isSuccess)
        #expect(mandatoryTrackCreated)
        #expect(fixture.createPresses.current() == 1)
    }

    @Test("a top-level modal New Track host is classified and presses its direct Create element")
    func topLevelModalNewTrackHostIsActionable() async {
        let fixture = makeTopLevelModalNewTrackFixture(matchesNewTrack: true)

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `top-level-modal-new-track-as-generic-blocker`: remove the
        // top-level contents read before the generic blocking return. This host
        // is then unknownSheet and its resolved Create control is never pressed.
        #expect(outcome.kind == .mandatoryNewTrack)
        #expect(outcome.actionAttempted)
        #expect(fixture.createPresses.current() == 1)
    }

    @Test("a non-New-Track top-level modal stays fail-closed")
    func unrelatedTopLevelModalStaysUnknown() async {
        let fixture = makeTopLevelModalNewTrackFixture(matchesNewTrack: false)

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `top-level-modal-unrelated-host-autocreate`: classify every
        // AXModal window with a Create-labelled button as New Track. This
        // unrelated, cancelable modal would receive an unauthorized direct press.
        #expect(outcome.kind == .unknownSheet)
        #expect(!outcome.actionAttempted)
        #expect(fixture.createPresses.current() == 0)
    }

    @Test("an unreadable pre-delete rail is serialized as an unobserved count")
    func deleteDoesNotReportUnreadableBeforeCountAsZero() async throws {
        let runtime = makeUnreadableDeleteCountRuntime()

        let result = await AccessibilityChannel.defaultDeleteTrack(runtime: runtime)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let verified = try #require(envelope["verified"] as? Bool)
        let trackCountBeforeWasUnobserved = envelope["track_count_before"] is NSNull
        let trackCountAfterWasUnobserved = envelope["track_count_after"] is NSNull
        let observedDeltaWasUnobserved = envelope["observed_delta"] is NSNull

        // Mutation `unreadable-before-count-zero`: restore
        // `allTrackHeaders().count` for the before read. This unreadable rail is
        // then serialized as the unobserved number zero rather than null.
        #expect(!verified)
        #expect(trackCountBeforeWasUnobserved)
        #expect(trackCountAfterWasUnobserved)
        #expect(observedDeltaWasUnobserved)
    }

    @Test("invalidUIElement on the captured sheet is gone, but that is not absence of the sheet kind")
    func invalidIdentityIsNotSheetAbsenceWhenReplacementRemains() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(800)
        let window = builder.element(801)
        let captured = builder.element(802)
        let replacement = builder.element(803)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [replacement])
        builder.setAttribute(replacement, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(replacement, kAXDescriptionAttribute as String, "New Track")
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, window), attribute == "AXSheets" {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
                }
                if CFEqual(element, captured), attribute == (kAXRoleAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let identity = AccessibilityChannel.boundSheetWitnessObservation(captured, runtime: runtime)
        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        // Fact 1: the bound element this run pressed Create on is gone.
        #expect(
            identity == .gone,
            "Mutation caught: keep invalidUIElement mapped to .unreadable; -25202 on the bound element is that element's closure signal."
        )
        // Fact 2 (a SEPARATE fresh scan, not derived from fact 1): a
        // replacement sheet is still present. Conflating fact 1 with fact 2 —
        // treating the bound element's closure as proof no sheet exists — is
        // exactly the #538 bug this witness must not reintroduce.
        #expect(
            ModalReconciliation.classify(read.signals) == .mandatoryNewTrack,
            "A gone bound identity must never be read as 'no sheet of this kind exists'; the fresh scan still finds the replacement sheet."
        )
    }

    @Test("a gone bound sheet plus an incomplete follow-up scan is not a clean/settled conclusion")
    func goneIdentityPlusDepthCapIsNotBlockerSetClear() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(810)
        let window = builder.element(811)
        let sheet = builder.element(812)
        let create = builder.element(813)
        let cancel = builder.element(814)
        let groups = (0..<33).map { builder.element(820 + $0) }
        let pressed = LockedFlag()
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [sheet])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(sheet, [create, cancel])
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, window), attribute == "AXSheets" {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
                }
                if pressed.get(), CFEqual(element, sheet), attribute == (kAXRoleAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
                }
                return nil
            },
            childrenResultHandler: { element in
                guard pressed.get() else { return nil }
                if CFEqual(element, window) {
                    return .success([groups[0]])
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
                pressed.set()
                builder.setChildren(window, [groups[0]])
                for index in 0..<(groups.count - 1) {
                    builder.setChildren(groups[index], [groups[index + 1]])
                }
                return true
            }
        )

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )
        let summary = try #require(outcome.witnessSummary)
        let clear = try #require(summary.blockerSetClear)

        #expect(outcome.actionAttempted)
        // The bound sheet's own identity read came back invalidUIElement
        // after the press, so the witness correctly observes it gone...
        #expect(
            summary.observedGone,
            "Mutation caught: keep invalidUIElement mapped to .unreadable; the bound sheet's own identity read must be observed gone here."
        )
        // ...but the SEPARATE complete blocker-set scan hit the descendant
        // depth cap and came back incomplete, so it must not be certified
        // clear. A gone bound sheet plus an unread/incomplete scan of the
        // rest of the modal surface is NOT a clean desk — this is the pairing
        // that must hold before any caller treats the outcome as settled.
        #expect(
            !clear,
            "A gone bound sheet must not make the complete blocker-set scan clear on its own; the incomplete depth-capped scan must still gate this false."
        )
        #expect(!AccessibilityChannel.freshCompleteModalReadIsClear(in: window, runtime: runtime))
    }

    @Test("AXWindows unsupported is not an empty list of other hosts")
    func axWindowsUnsupportedIsNotNoOtherHosts() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(850)
        let window = builder.element(851)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(ModalReconciliation.classify(read.signals) == .none)
        #expect(!read.modalObservationIsComplete)
        #expect(
            read.unreadableReason == .axWindowsReadFailed(
                AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)
            )
        )
        #expect(!AccessibilityChannel.freshCompleteModalReadIsClear(in: window, runtime: runtime))
    }

    @Test("AXWindows noValue is not proof that no other sheet host exists")
    func axWindowsNoValueIsNotNoOtherHosts() {
        // #538: `noValue` (-25212) on `AXWindows` used to be treated as "the app
        // currently has zero windows", certifying an empty search space with no
        // fallback tree to search (unlike `AXSheets`, which always falls through
        // to a descendant traversal). AX statuses can lie during a Logic rebuild,
        // so a real window — holding a real sheet — can exist behind a
        // transiently unreadable `AXWindows` call. This must stay unreadable.
        //
        // No `AXMainWindow` is set, so this isolates the FIRST `AXWindows` read
        // site: `anyWindowSheetLookup(runtime:)` (no `excluding` window). That
        // read fails with `noValue`; the SECOND, independent read
        // (`topLevelDialogRead`, reached afterward regardless) is served a
        // genuine clean empty array so it cannot mask the first site's mutation.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(880)
        let windowsReads = LockedCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                return windowsReads.next() == 1
                    ? .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
                    : .success([] as NSArray)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        // Mutation `axwindows-novalue-is-no-other-hosts`: restore
        // `case .failure(let error) where error.raw == AXError.noValue.rawValue:
        // return .absent` in `anyWindowSheetLookup`. A transiently unreadable
        // excluding-scan would then certify no other sheet host exists, and the
        // second (clean) read would let the whole observation look complete.
        #expect(ModalReconciliation.classify(read.signals) == .none)
        #expect(!read.modalObservationIsComplete)
        #expect(
            read.unreadableReason == .axWindowsReadFailed(
                AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
            )
        )
        #expect(
            windowsReads.current() == 2,
            "both the excluding-scan and the top-level-dialog scan must fire, or this test proves nothing"
        )
    }

    @Test("AXWindows noValue is not proof that no top-level modal window exists")
    func axWindowsNoValueIsNotNoTopLevelModal() {
        // Isolates the SECOND `AXWindows` read site: `topLevelDialogRead`, reached
        // only after the excluding sheet-host scan came back genuinely clean (a
        // real empty array, not a failure). That scan's read succeeds; the
        // independent top-level-dialog scan's read is the one that returns
        // `noValue`, and it alone must not certify "no modal window exists".
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(882)
        let window = builder.element(883)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        let windowsReads = LockedCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                return windowsReads.next() == 1
                    ? .success([] as NSArray)
                    : .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        // Mutation `axwindows-novalue-is-no-modal`: restore
        // `case .failure(let error) where error.raw == AXError.noValue.rawValue:
        // return .none` in `topLevelDialogRead(runtime:)`. A noValue here would
        // then certify a clean no-modal answer instead of staying unreadable.
        #expect(ModalReconciliation.classify(read.signals) == .none)
        #expect(!read.modalObservationIsComplete)
        #expect(
            read.unreadableReason == .axWindowsReadFailed(
                AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
            )
        )
        #expect(windowsReads.current() == 2, "both AXWindows read sites must have fired, or this test proves nothing")
    }

    @Test("an AXSheets member is a candidate only when its role is AXSheet")
    func axSheetsFirstElementIsNotTrustedWithoutSheetRole() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(860)
        let window = builder.element(861)
        let decoy = builder.element(862)
        let sheet = builder.element(863)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [sheet])
        builder.setAttribute(decoy, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .success([decoy] as NSArray)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        #expect(kind == .mandatoryNewTrack)
    }

    @Test("invalidUIElement on the captured alert is observed gone")
    func invalidAlertIdentityIsObservedGone() {
        let builder = FakeAXRuntimeBuilder()
        let alert = builder.element(870)
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, alert), attribute == (kAXModalAttribute as String) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.boundTopLevelAlertWitnessObservation(alert, runtime: runtime)

        #expect(
            observed == .gone,
            "Mutation caught: keep invalidUIElement mapped to .unreadable(.alertModal); -25202 on the bound alert element is that element's closure signal, same shape as the sheet witness."
        )
    }

    @Test("cannotComplete on the captured alert stays unreadable")
    func nonStaleCapturedAlertIsUnreadable() {
        let builder = FakeAXRuntimeBuilder()
        let alert = builder.element(872)
        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, alert), attribute == (kAXModalAttribute as String) else { return nil }
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.boundTopLevelAlertWitnessObservation(alert, runtime: runtime)

        #expect(
            observed == .unreadable(.alertModal(cannotComplete)),
            "A read that did not answer must retire this poll as unreadable, not gone."
        )
    }

    @Test("invalidUIElement on the captured menu item is observed gone")
    func invalidMenuIdentityIsObservedGone() {
        let builder = FakeAXRuntimeBuilder()
        let item = builder.element(871)
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, item), attribute == (kAXSelectedAttribute as String) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.boundStrayMenuWitnessObservation(item, runtime: runtime)

        #expect(
            observed == .gone,
            "Mutation caught: keep invalidUIElement mapped to .unreadable(.menuItemSelected); -25202 on the bound menu item is that element's closure signal, same shape as the sheet witness."
        )
    }

    @Test("cannotComplete on the captured menu item stays unreadable")
    func nonStaleCapturedMenuIsUnreadable() {
        let builder = FakeAXRuntimeBuilder()
        let item = builder.element(873)
        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, item), attribute == (kAXSelectedAttribute as String) else { return nil }
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.boundStrayMenuWitnessObservation(item, runtime: runtime)

        #expect(
            observed == .unreadable(.menuItemSelected(cannotComplete)),
            "A read that did not answer must retire this poll as unreadable, not gone."
        )
    }
}

private enum BoundSheetAction {
    case create
    case delete
}

private enum IndeterminateModalRead: Sendable {
    case unsupported
    case noValue
    case malformed
}

private enum MalformedAXWindowsPayload: Sendable {
    case nilValue
    case string
}

private func makeIndeterminateModalRuntime(
    _ read: IndeterminateModalRead
) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(65)
    let window = builder.element(66)
    let menuBar = builder.element(67)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(menuBar, [])
    return builder.makeLogicRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            guard CFEqual(element, window), attribute == (kAXModalAttribute as String) else {
                return nil
            }
            switch read {
            case .unsupported:
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            case .noValue:
                return .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
            case .malformed:
                return .success("not a Boolean" as NSString)
            }
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )
}

private enum BoundSheetPostAction {
    case gone
    case present
    case replaced
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedActionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct BoundSheetFixture {
    let runtime: AXLogicProElements.Runtime
    let arrangeWindow: AXUIElement
    let ordinalFallbackUsed: LockedFlag
}

private func reconcile(
    _ fixture: BoundSheetFixture,
    isDeleteContext: Bool
) async -> AccessibilityChannel.ModalReconcileOutcome {
    await AccessibilityChannel.reconcileAfterMutation(
        isDeleteContext: isDeleteContext,
        runtime: fixture.runtime,
        witnessAttempts: 1,
        witnessDelayNanoseconds: 0
    )
}

private func makeBoundSheetFixture(
    action: BoundSheetAction,
    actionAccepted: Bool,
    postAction: BoundSheetPostAction,
    rawMainWindowDriftsToAuxiliary: Bool = false,
    actionFailure: AXHelpers.AXStatusError? = nil
) -> BoundSheetFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(100)
    let auxiliaryWindow = builder.element(101)
    let arrangeWindow = builder.element(102)
    let trackHeaders = builder.element(103)
    let sheet = builder.element(104)
    let primary = builder.element(105)
    let cancel = builder.element(106)
    let replacementSheet = builder.element(107)
    let actionIssued = LockedFlag()
    let ordinalFallbackUsed = LockedFlag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, arrangeWindow)
    builder.setAttribute(auxiliaryWindow, kAXModalAttribute as String, false)
    builder.setAttribute(arrangeWindow, kAXModalAttribute as String, false)
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, action == .create ? "New Track" : "Delete Tracks")
    builder.setAttribute(primary, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(
        primary,
        kAXTitleAttribute as String,
        action == .create ? "Create" : "Delete Tracks and Content"
    )
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, action != .create)
    builder.setChildren(sheet, [primary, cancel])
    builder.setAttribute(replacementSheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(replacementSheet, kAXDescriptionAttribute as String, "New Track")

    if rawMainWindowDriftsToAuxiliary {
        builder.setAttribute(app, kAXWindowsAttribute as String, [auxiliaryWindow, arrangeWindow])
        builder.setAttribute(auxiliaryWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(arrangeWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(trackHeaders, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(trackHeaders, kAXDescriptionAttribute as String, "Track headers")
        builder.setChildren(arrangeWindow, [trackHeaders])
    }

    let attributeValueHandler: (@Sendable (AXUIElement, String) -> AnyObject??) = { element, attribute in
        if CFEqual(element, arrangeWindow), attribute == "AXSheets" {
            if actionIssued.get(), postAction == .gone {
                return .some([] as NSArray)
            }
            if actionIssued.get(), postAction == .replaced {
                return .some([replacementSheet] as NSArray)
            }
            return .some([sheet] as NSArray)
        }
        if rawMainWindowDriftsToAuxiliary,
           actionIssued.get(),
           CFEqual(element, app),
           attribute == (kAXMainWindowAttribute as String) {
            return .some(auxiliaryWindow)
        }
        return nil
    }
    let attributeValueResultHandler: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?) = { element, attribute in
        guard actionIssued.get(),
              postAction == .gone || postAction == .replaced,
              CFEqual(element, sheet),
              attribute == (kAXRoleAttribute as String)
        else { return nil }
        return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
    }
    let press: @Sendable (AXUIElement, String) -> Bool = { element, actionName in
        guard CFEqual(element, primary), actionName == (kAXPressAction as String) else { return false }
        actionIssued.set()
        return actionAccepted
    }
    var pressResult: (@Sendable (AXUIElement, String) -> Result<Void, AXHelpers.AXStatusError>)?
    if let failure = actionFailure {
        pressResult = { element, actionName -> Result<Void, AXHelpers.AXStatusError> in
            guard CFEqual(element, primary), actionName == (kAXPressAction as String) else {
                return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
            }
            actionIssued.set()
            return .failure(failure)
        }
    }
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: attributeValueHandler,
        attributeValueResultHandler: attributeValueResultHandler,
        setAttributeHandler: nil,
        performActionHandler: press,
        performActionResultHandler: pressResult,
        executeAppleScript: { _ in
            ordinalFallbackUsed.set()
            return .success("ordinal fallback")
        }
    )

    return BoundSheetFixture(
        runtime: runtime,
        arrangeWindow: arrangeWindow,
        ordinalFallbackUsed: ordinalFallbackUsed
    )
}

private enum SequentialDeleteSheetStage {
    case noSheet
    case deleteConfirm
    case mandatoryNewTrack
}

private final class SequentialDeleteSheetState: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: SequentialDeleteSheetStage = .noSheet

    func set(_ next: SequentialDeleteSheetStage) {
        lock.lock()
        stage = next
        lock.unlock()
    }

    func get() -> SequentialDeleteSheetStage {
        lock.lock()
        defer { lock.unlock() }
        return stage
    }
}

private struct SequentialDeleteSheetFixture {
    let runtime: AXLogicProElements.Runtime
    let deleteConfirmPresses: LockedActionCount
    let createPresses: LockedActionCount
}

private func makeSequentialDeleteSheetFixture() -> SequentialDeleteSheetFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(200)
    let window = builder.element(201)
    let menuBar = builder.element(202)
    let trackMenu = builder.element(203)
    let deleteMenuItem = builder.element(204)
    let trackHeaders = builder.element(205)
    let trackHeader = builder.element(206)
    let deleteSheet = builder.element(207)
    let deletePrimary = builder.element(208)
    let deleteCancel = builder.element(209)
    let mandatorySheet = builder.element(210)
    let createPrimary = builder.element(211)
    let createCancel = builder.element(212)
    let state = SequentialDeleteSheetState()
    let deleteConfirmPresses = LockedActionCount()
    let createPresses = LockedActionCount()

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(window, [trackHeaders])
    builder.setAttribute(trackHeaders, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackHeaders, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackHeaders, [trackHeader])
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
    builder.setChildren(trackMenu, [deleteMenuItem])
    builder.setAttribute(deleteMenuItem, kAXTitleAttribute as String, "Delete Track")

    builder.setAttribute(deleteSheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(deleteSheet, kAXDescriptionAttribute as String, "Delete Tracks")
    builder.setAttribute(deletePrimary, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(deletePrimary, kAXTitleAttribute as String, "Delete Tracks and Content")
    builder.setAttribute(deleteCancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(deleteCancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(deleteCancel, kAXEnabledAttribute as String, true)
    builder.setChildren(deleteSheet, [deletePrimary, deleteCancel])

    builder.setAttribute(mandatorySheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(mandatorySheet, kAXDescriptionAttribute as String, "New Track")
    builder.setAttribute(createPrimary, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(createPrimary, kAXTitleAttribute as String, "Create")
    builder.setAttribute(createCancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(createCancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(createCancel, kAXEnabledAttribute as String, false)
    builder.setChildren(mandatorySheet, [createPrimary, createCancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
            switch state.get() {
            case .noSheet: return .some([] as NSArray)
            case .deleteConfirm: return .some([deleteSheet] as NSArray)
            case .mandatoryNewTrack: return .some([mandatorySheet] as NSArray)
            }
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard action == (kAXPressAction as String) else { return false }
            if CFEqual(element, deleteMenuItem) {
                state.set(.deleteConfirm)
                return true
            }
            if CFEqual(element, deletePrimary) {
                deleteConfirmPresses.increment()
                builder.setChildren(trackHeaders, [])
                state.set(.mandatoryNewTrack)
                return true
            }
            if CFEqual(element, createPrimary) {
                createPresses.increment()
                return true
            }
            return false
        }
    )
    return SequentialDeleteSheetFixture(
        runtime: runtime,
        deleteConfirmPresses: deleteConfirmPresses,
        createPresses: createPresses
    )
}

private struct ProjectNewStaleCreateFixture {
    let runtime: AXLogicProElements.Runtime
}

private struct ProjectNewPerformedCreateWithoutTrackFixture {
    let runtime: AXLogicProElements.Runtime
}

private struct ProjectNewPerformedCreateWithTrackFixture {
    let runtime: AXLogicProElements.Runtime
    let createPresses: LockedCounter
    /// Set when the fixture's "bound sheet AXRole keeps reading back successfully after the
    /// Create press" seam actually ran. A test that asserts on `blockerSetClear` alone without
    /// checking this could pass even if the seam was never armed.
    let divergentBoundReadObserved: LockedFlag
    /// Set when the fixture's "the follow-up scan finds a replacement sheet" seam actually ran.
    let divergentScanObserved: LockedFlag
}

private struct ProjectNewDelayedCreateFixture {
    let runtime: AXLogicProElements.Runtime
    let createPresses: LockedCounter
}

private func makeProjectNewDelayedCreateFixture() -> ProjectNewDelayedCreateFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(320)
    let window = builder.element(321)
    let sheet = builder.element(322)
    let create = builder.element(323)
    let cancel = builder.element(324)
    let trackHeaders = builder.element(325)
    let track = builder.element(326)
    let sheetChildReads = LockedCounter()
    let createPresses = LockedCounter()
    let actionIssued = LockedFlag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
    builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
    // Production shape: the sheet is modal; its host window explicitly reports
    // AXModal false. An unset value would be an unreadable fake-only shape.
    builder.setAttribute(window, kAXModalAttribute as String, false)
    builder.setAttribute(window, kAXTitleAttribute as String, "Untitled 1 - Tracks")
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
    builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(create, kAXTitleAttribute as String, "Create")
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
    builder.setAttribute(trackHeaders, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackHeaders, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackHeaders, [track])
    builder.setChildren(window, [trackHeaders])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
            return actionIssued.get() ? .some([] as NSArray) : .some([sheet] as NSArray)
        },
        attributeValueResultHandler: { element, attribute in
            guard actionIssued.get(),
                  CFEqual(element, sheet),
                  attribute == (kAXRoleAttribute as String)
            else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
        },
        childrenHandler: { element in
            guard CFEqual(element, sheet) else { return nil }
            return sheetChildReads.next() == 1 ? [cancel] : [create, cancel]
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
            _ = createPresses.next()
            actionIssued.set()
            return true
        }
    )
    return ProjectNewDelayedCreateFixture(runtime: runtime, createPresses: createPresses)
}

private struct TopLevelModalNewTrackFixture {
    let runtime: AXLogicProElements.Runtime
    let createPresses: LockedCounter
}

private func makeTopLevelModalNewTrackFixture(
    matchesNewTrack: Bool
) -> TopLevelModalNewTrackFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(330)
    let modal = builder.element(331)
    let create = builder.element(332)
    let cancel = builder.element(333)
    let createPresses = LockedCounter()
    let actionIssued = LockedFlag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, modal)
    builder.setAttribute(app, kAXWindowsAttribute as String, [modal])
    builder.setAttribute(modal, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(modal, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
    builder.setAttribute(modal, kAXModalAttribute as String, true)
    builder.setAttribute(modal, kAXDescriptionAttribute as String, matchesNewTrack ? "New Track" : "Save Changes")
    builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(create, kAXTitleAttribute as String, "Create")
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, !matchesNewTrack)
    builder.setChildren(modal, [create, cancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            guard actionIssued.get(),
                  CFEqual(element, modal),
                  attribute == (kAXRoleAttribute as String)
            else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
            _ = createPresses.next()
            actionIssued.set()
            return true
        }
    )
    return TopLevelModalNewTrackFixture(runtime: runtime, createPresses: createPresses)
}

private func makeUnreadableDeleteCountRuntime() -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(340)
    let window = builder.element(341)
    let menuBar = builder.element(342)
    let trackMenu = builder.element(343)
    let deleteItem = builder.element(344)
    let trackHeaders = builder.element(345)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setAttribute(window, kAXModalAttribute as String, false)
    builder.setChildren(window, [trackHeaders])
    builder.setAttribute(trackHeaders, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackHeaders, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
    builder.setChildren(trackMenu, [deleteItem])
    builder.setAttribute(deleteItem, kAXTitleAttribute as String, "Delete Track")

    return builder.makeLogicRuntime(
        appElement: app,
        childrenResultHandler: { element in
            guard CFEqual(element, trackHeaders) else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            CFEqual(element, deleteItem) && action == (kAXPressAction as String)
        }
    )
}

private func makeProjectNewPerformedCreateWithoutTrackFixture() -> ProjectNewPerformedCreateWithoutTrackFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(280)
    let window = builder.element(281)
    let menuBar = builder.element(282)
    let sheet = builder.element(283)
    let create = builder.element(284)
    let cancel = builder.element(285)
    let actionIssued = LockedFlag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(menuBar, [])
    builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "Untitled 1 - Tracks")
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
    builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(create, kAXTitleAttribute as String, "Create")
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
    builder.setChildren(sheet, [create, cancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
            return actionIssued.get() ? .some([] as NSArray) : .some([sheet] as NSArray)
        },
        attributeValueResultHandler: { element, attribute in
            guard actionIssued.get(),
                  CFEqual(element, sheet),
                  attribute == (kAXRoleAttribute as String)
            else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
            actionIssued.set()
            return true
        }
    )
    return ProjectNewPerformedCreateWithoutTrackFixture(runtime: runtime)
}

/// - Parameters:
///   - boundSheetStaysReadableAfterAction: When true, the sheet this run captured keeps
///     reading its AXRole back successfully after the Create press (never invalidates), while
///     the independent post-action AXSheets scan still clears to empty. This decouples
///     `observedGone` (false) from `blockerSetClear` (true) — #538 case 1.
///   - blockerScanFindsReplacementAfterAction: When true, the bound sheet still invalidates
///     (its AXRole read fails) after the Create press, but the independent post-action
///     AXSheets scan finds a different, still-attached "New Track" sheet instead of clearing.
///     This decouples `observedGone` (true) from `blockerSetClear` (false) — #538 case 2.
///     Mutually exclusive with `boundSheetStaysReadableAfterAction`; combining both is not a
///     coherent AX state and is not exercised here.
private func makeProjectNewPerformedCreateWithTrackFixture(
    boundSheetStaysReadableAfterAction: Bool = false,
    blockerScanFindsReplacementAfterAction: Bool = false
) -> ProjectNewPerformedCreateWithTrackFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(290)
    let window = builder.element(291)
    let sheet = builder.element(292)
    let create = builder.element(293)
    let cancel = builder.element(294)
    let trackHeaders = builder.element(295)
    let track = builder.element(296)
    let replacementSheet = builder.element(297)
    let actionIssued = LockedFlag()
    let createPresses = LockedCounter()
    let divergentBoundReadObserved = LockedFlag()
    let divergentScanObserved = LockedFlag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
    builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
    builder.setAttribute(window, kAXModalAttribute as String, false)
    builder.setAttribute(window, kAXTitleAttribute as String, "Untitled 1 - Tracks")
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
    builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(create, kAXTitleAttribute as String, "Create")
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
    builder.setChildren(sheet, [create, cancel])
    builder.setAttribute(replacementSheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(replacementSheet, kAXDescriptionAttribute as String, "New Track")
    builder.setAttribute(trackHeaders, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackHeaders, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackHeaders, [track])
    builder.setChildren(window, [trackHeaders])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
            guard actionIssued.get() else { return .some([sheet] as NSArray) }
            if blockerScanFindsReplacementAfterAction {
                divergentScanObserved.set()
                return .some([replacementSheet] as NSArray)
            }
            return .some([] as NSArray)
        },
        attributeValueResultHandler: { element, attribute in
            guard actionIssued.get(),
                  CFEqual(element, sheet),
                  attribute == (kAXRoleAttribute as String)
            else { return nil }
            if boundSheetStaysReadableAfterAction {
                // Fall through to the still-set dictionary value (kAXSheetRole) instead of
                // reporting invalidUIElement: the bound sheet handle stays valid even though
                // the independent AXSheets scan above has already cleared.
                divergentBoundReadObserved.set()
                return nil
            }
            return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
            _ = createPresses.next()
            actionIssued.set()
            return true
        }
    )
    return ProjectNewPerformedCreateWithTrackFixture(
        runtime: runtime,
        createPresses: createPresses,
        divergentBoundReadObserved: divergentBoundReadObserved,
        divergentScanObserved: divergentScanObserved
    )
}

private func makeProjectNewStaleCreateFixture() -> ProjectNewStaleCreateFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(300)
    let window = builder.element(301)
    let sheet = builder.element(302)
    let create = builder.element(303)
    let cancel = builder.element(304)
    let stale = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
    builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(create, kAXTitleAttribute as String, "Create")
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
    builder.setChildren(sheet, [create, cancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
            return .some([sheet] as NSArray)
        },
        setAttributeHandler: nil,
        performActionHandler: { _, _ in false },
        performActionResultHandler: { element, action in
            guard CFEqual(element, create), action == (kAXPressAction as String) else {
                return .failure(stale)
            }
            return .failure(stale)
        }
    )
    return ProjectNewStaleCreateFixture(runtime: runtime)
}
