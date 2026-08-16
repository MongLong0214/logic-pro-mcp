@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class TrackCreateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class TrackCreateFlag: @unchecked Sendable {
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

@Suite("Issue #538 — create observations are status- and identity-bound")
struct Issue538TrackCreationObservationTests {

    @Test("an unreadable pre-create rail is not flattened to zero and cannot certify State A")
    func createDoesNotTreatUnreadableBeforeRailAsZero() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(600)
        let window = builder.element(601)
        let menuBar = builder.element(602)
        let trackMenu = builder.element(603)
        let createItem = builder.element(604)
        let headers = builder.element(605)
        let existing = (0..<4).map { builder.element(606 + $0) }
        let menuWasClicked = TrackCreateFlag()
        let unreadableBeforeRailReads = TrackCreateCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, existing)
        for header in existing {
            builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            builder.setAttribute(header, kAXTitleAttribute as String, "Existing Track")
            builder.setAttribute(header, kAXDescriptionAttribute as String, "Audio Track")
        }
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenHandler: { element in
                guard CFEqual(element, headers), !menuWasClicked.get() else { return nil }
                unreadableBeforeRailReads.increment()
                return []
            },
            childrenResultHandler: { element in
                guard CFEqual(element, headers), !menuWasClicked.get() else { return nil }
                unreadableBeforeRailReads.increment()
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, createItem), action == (kAXPressAction as String) else { return false }
                menuWasClicked.set()
                return true
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        try #require(result.isSuccess, "expected an honest State B envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let verified = try #require(envelope["verified"] as? Bool)
        let beforeWasUnobserved = envelope["track_count_before"] is NSNull
        let deltaWasUnobserved = envelope["observed_delta"] is NSNull

        // Mutation `create-unreadable-before-flattened-to-zero`: restore the
        // old `allTrackHeaders()` enumeration for the pre-write read. Its empty
        // best-effort result makes the four pre-existing headers appear as a
        // delta of four and this fixture falsely encodes State A.
        #expect(!verified)
        #expect(beforeWasUnobserved)
        #expect(deltaWasUnobserved)
        #expect(menuWasClicked.get(), "the menu-action seam must run before the post-write headers appear")
        #expect(unreadableBeforeRailReads.current() > 0, "the pre-write unreadable-rail seam must fire")
    }

    @Test("observed_track_type is read from the newly observed header rather than requested menu type")
    func createPublishesObservedHeaderType() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(620)
        let window = builder.element(621)
        let menuBar = builder.element(622)
        let trackMenu = builder.element(623)
        let createItem = builder.element(624)
        let headers = builder.element(625)
        let existing = builder.element(626)
        let createdAudio = builder.element(627)
        let createPresses = TrackCreateCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Existing")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(createdAudio, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(createdAudio, kAXTitleAttribute as String, "Actually Audio")
        builder.setAttribute(createdAudio, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(createdAudio, kAXSelectedAttribute as String, true)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, createItem), action == (kAXPressAction as String) else { return false }
                createPresses.increment()
                builder.setChildren(headers, [existing, createdAudio])
                return true
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        try #require(result.isSuccess, "expected a verified creation envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let observedType = try #require(envelope["observed_track_type"] as? String)
        let typeSource = try #require(envelope["track_type_verification_source"] as? String)

        // Mutation `requested-type-published-as-observed`: restore
        // `expectedTrackType.rawValue` in the State-A extras. The clicked
        // software-instrument request then hides this newly read Audio header.
        let verified = try #require(envelope["verified"] as? Bool)
        let state = try #require(envelope["state"] as? String)
        #expect(verified)
        #expect(state == "A")
        #expect(observedType == "audio")
        #expect(typeSource == "observed_header")
        #expect(createPresses.current() == 1, "the count-increase seam must be caused by the requested menu press")
    }

    @Test("create confirmation presses the AX-read Create control and never invokes the unchecked Return seam")
    func createConfirmationUsesBoundCreateButton() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(640)
        let window = builder.element(641)
        let menuBar = builder.element(642)
        let trackMenu = builder.element(643)
        let createItem = builder.element(644)
        let headers = builder.element(645)
        let existing = builder.element(646)
        let created = builder.element(647)
        let sheet = builder.element(648)
        let create = builder.element(649)
        let cancel = builder.element(650)
        let menuWasClicked = TrackCreateFlag()
        let sheetWasCleared = TrackCreateFlag()
        let boundCreatePresses = TrackCreateCounter()
        let uncheckedReturnCalls = TrackCreateCounter()
        let sheetReads = TrackCreateCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Existing")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(created, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(created, kAXTitleAttribute as String, "Created Instrument")
        builder.setAttribute(created, kAXDescriptionAttribute as String, "Software Instrument Track")
        builder.setAttribute(created, kAXSelectedAttribute as String, true)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)
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
                sheetReads.increment()
                guard menuWasClicked.get(), !sheetWasCleared.get() else { return .some([] as NSArray) }
                return .some([sheet] as NSArray)
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == (kAXPressAction as String) else { return false }
                if CFEqual(element, createItem) {
                    menuWasClicked.set()
                    return true
                }
                if CFEqual(element, create) {
                    boundCreatePresses.increment()
                    sheetWasCleared.set()
                    builder.setChildren(headers, [existing, created])
                    return true
                }
                return false
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            confirmDialog: { uncheckedReturnCalls.increment() },
            runtime: runtime
        )
        try #require(result.isSuccess, "expected a bound-confirmation envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let action = try #require(envelope["reconciled_action"] as? String)

        // Mutation `unchecked-return-confirmation`: restore the deleted
        // `confirmDialog()` line after the 400 ms wait. The injected legacy
        // Return seam then fires despite the classifier having a direct Create
        // element to press.
        let verified = try #require(envelope["verified"] as? Bool)
        let state = try #require(envelope["state"] as? String)
        #expect(verified)
        #expect(state == "A")
        #expect(action == "click_create")
        #expect(boundCreatePresses.current() == 1)
        #expect(uncheckedReturnCalls.current() == 0)
        #expect(sheetReads.current() > 0, "the mandatory-sheet seam must be read before Create is pressed")
    }

    @Test("a New Track sheet classified before its Create control publishes is retried, not abandoned")
    func createTrackViaMenuRetriesADelayedCreateControl() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(660)
        let window = builder.element(661)
        let menuBar = builder.element(662)
        let trackMenu = builder.element(663)
        let createItem = builder.element(664)
        let headers = builder.element(665)
        let existing = builder.element(666)
        let created = builder.element(667)
        let sheet = builder.element(668)
        let create = builder.element(669)
        let cancel = builder.element(670)
        let menuWasClicked = TrackCreateFlag()
        let sheetWasCleared = TrackCreateFlag()
        let boundCreatePresses = TrackCreateCounter()
        let sheetChildReads = TrackCreateCounter()
        let sheetChildReadsWithoutCreate = TrackCreateCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Existing")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(created, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(created, kAXTitleAttribute as String, "Created Instrument")
        builder.setAttribute(created, kAXDescriptionAttribute as String, "Software Instrument Track")
        builder.setAttribute(created, kAXSelectedAttribute as String, true)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)

        // #538 counterexample: the sheet's AXDescription ("New Track") is
        // readable on the FIRST post-menu poll, but its Create control is not
        // yet published among the sheet's children — only Cancel is there.
        // Every poll AFTER that publishes both [Create, Cancel].
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                guard menuWasClicked.get(), !sheetWasCleared.get() else { return .some([] as NSArray) }
                return .some([sheet] as NSArray)
            },
            childrenHandler: { element in
                guard CFEqual(element, sheet) else { return nil }
                sheetChildReads.increment()
                if sheetChildReads.current() == 1 {
                    sheetChildReadsWithoutCreate.increment()
                    return [cancel]
                }
                return [create, cancel]
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == (kAXPressAction as String) else { return false }
                if CFEqual(element, createItem) {
                    menuWasClicked.set()
                    return true
                }
                if CFEqual(element, create) {
                    boundCreatePresses.increment()
                    sheetWasCleared.set()
                    builder.setChildren(headers, [existing, created])
                    return true
                }
                return false
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime,
            dialogPollDelayNanoseconds: 0
        )
        try #require(result.isSuccess, "expected a verified creation envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let verified = try #require(envelope["verified"] as? Bool)
        let state = try #require(envelope["state"] as? String)
        let action = try #require(envelope["reconciled_action"] as? String)

        // Mutation source 1 (retry removed): restore the single unconditional
        // `reconcileAfterMutation` call with no follow-up poll. The
        // description-only first pass would then be the operation's only
        // look at the sheet, Create is never pressed, and this becomes a
        // State B `dialog_present` envelope with the sheet still up.
        #expect(verified)
        #expect(state == "A")
        #expect(action == "click_create")
        // Mutation source 2 (once-only guard removed): let the retry loop
        // keep polling and pressing after `actionAttempted` is already true.
        // Create would then be pressed a second time on this fixture's next
        // poll, which is a double-create — worse than the original wedge.
        #expect(boundCreatePresses.current() == 1, "Create must be pressed exactly once")
        #expect(
            sheetChildReadsWithoutCreate.current() == 1,
            "the description-only, Create-not-yet-published poll seam must fire exactly once"
        )
        #expect(sheetChildReads.current() >= 2, "a later poll must re-read the sheet's now-published children")
    }

    @Test("the delayed-create retry never presses Create twice, even when a replacement sheet follows")
    func createTrackViaMenuNeverPressesCreateTwiceOnAReplacementSheet() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(680)
        let window = builder.element(681)
        let menuBar = builder.element(682)
        let trackMenu = builder.element(683)
        let createItem = builder.element(684)
        let headers = builder.element(685)
        let existing = builder.element(686)
        let sheet = builder.element(687)
        let create = builder.element(688)
        let cancel = builder.element(689)
        let replacementSheet = builder.element(690)
        let create2 = builder.element(691)
        let cancel2 = builder.element(692)
        let menuWasClicked = TrackCreateFlag()
        let actionIssued = TrackCreateFlag()
        let boundCreatePresses = TrackCreateCounter()
        let sheetChildReads = TrackCreateCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Existing")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setAttribute(replacementSheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(replacementSheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create2, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create2, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel2, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel2, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel2, kAXEnabledAttribute as String, false)
        builder.setChildren(replacementSheet, [create2, cancel2])

        // Same #538 shape as the delayed-create fixture above (Create absent
        // on the first read of `sheet`, published from the second read on),
        // but here a DIFFERENT, already-actionable "New Track" sheet is
        // attached from the very next `AXSheets` read after the first Create
        // press — reproducing the #538 replacement-sheet shape. If the
        // once-only latch is not honored, the retry loop presses `create2` on
        // this replacement exactly like it pressed `create`, doubling the
        // create.
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                guard menuWasClicked.get() else { return .some([] as NSArray) }
                guard !actionIssued.get() else { return .some([replacementSheet] as NSArray) }
                return .some([sheet] as NSArray)
            },
            childrenHandler: { element in
                guard CFEqual(element, sheet) else { return nil }
                sheetChildReads.increment()
                return sheetChildReads.current() == 1 ? [cancel] : [create, cancel]
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == (kAXPressAction as String) else { return false }
                if CFEqual(element, createItem) {
                    menuWasClicked.set()
                    return true
                }
                if CFEqual(element, create) {
                    boundCreatePresses.increment()
                    actionIssued.set()
                    return true
                }
                if CFEqual(element, create2) {
                    boundCreatePresses.increment()
                    return true
                }
                return false
            }
        )

        _ = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime,
            dialogPollDelayNanoseconds: 0
        )

        // Mutation source 2 (once-only guard removed): drop the
        // `if dialogReconcileOutcome.actionAttempted { break }` inside the
        // retry loop. The loop would then poll again after the first
        // successful press, find the replacement sheet's already-published
        // `create2`, and press it too — `boundCreatePresses` becomes 2.
        #expect(boundCreatePresses.current() == 1, "Create must never be pressed a second time on a replacement sheet")
        #expect(actionIssued.get(), "the first Create press seam must fire")
    }

    @Test("a create timeout with a still-present New Track sheet is State B, not a clean write failure")
    func createTimeoutNamesThePresentSheetInsteadOfReportingNoWindow() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(700)
        let window = builder.element(701)
        let menuBar = builder.element(702)
        let trackMenu = builder.element(703)
        let createItem = builder.element(704)
        let headers = builder.element(705)
        let existing = builder.element(706)
        let sheet = builder.element(707)
        let group = builder.element(708)
        let create = builder.element(709)
        let cancel = builder.element(710)
        let menuWasClicked = TrackCreateFlag()
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Audio 1")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Make")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(group, [create, cancel])
        builder.setChildren(sheet, [group])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, window), attribute == "AXSheets" {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
                }
                if CFEqual(element, sheet), attribute == (kAXModalAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, createItem), action == (kAXPressAction as String) else { return false }
                menuWasClicked.set()
                builder.setChildren(window, [headers, sheet])
                return true
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        try #require(result.isSuccess, "expected a State B envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let state = try #require(envelope["state"] as? String)
        let verified = try #require(envelope["verified"] as? Bool)
        let kind = try #require(envelope["reconciled_modal_kind"] as? String)

        #expect(!verified)
        #expect(state == "B")
        #expect(kind == "mandatory_new_track")
        #expect(menuWasClicked.get())
    }

    @Test("a count increase while the New Track sheet is still present cannot certify State A")
    func createDoesNotCertifyStateAWhileMandatorySheetRemains() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(720)
        let window = builder.element(721)
        let menuBar = builder.element(722)
        let trackMenu = builder.element(723)
        let createItem = builder.element(724)
        let headers = builder.element(725)
        let existing = builder.element(726)
        let created = builder.element(727)
        let sheet = builder.element(728)
        let create = builder.element(729)
        let cancel = builder.element(730)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Audio 1")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(created, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(created, kAXTitleAttribute as String, "Inst 1")
        builder.setAttribute(created, kAXDescriptionAttribute as String, "Software Instrument Track")
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Make")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(sheet, [create, cancel])

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, createItem), action == (kAXPressAction as String) else { return false }
                builder.setChildren(headers, [existing, created])
                builder.setChildren(window, [headers, sheet])
                return true
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        try #require(result.isSuccess, "expected a State B envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let state = try #require(envelope["state"] as? String)
        let verified = try #require(envelope["verified"] as? Bool)
        let kind = try #require(envelope["reconciled_modal_kind"] as? String)

        #expect(!verified)
        #expect(state == "B")
        #expect(kind == "mandatory_new_track")
    }

    @Test("State A does not name a track that was already selected before the write")
    func createDoesNotPublishAPreselectedTrackAsTheCreatedOne() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(740)
        let window = builder.element(741)
        let menuBar = builder.element(742)
        let trackMenu = builder.element(743)
        let createItem = builder.element(744)
        let headers = builder.element(745)
        let existing = builder.element(746)
        let created = builder.element(747)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Audio 1")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(existing, kAXSelectedAttribute as String, true)
        builder.setAttribute(created, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(created, kAXTitleAttribute as String, "Inst 1")
        builder.setAttribute(created, kAXDescriptionAttribute as String, "Software Instrument Track")
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, created), attribute == (kAXSelectedAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, createItem), action == (kAXPressAction as String) else { return false }
                builder.setChildren(headers, [existing, created])
                return true
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        try #require(result.isSuccess, "expected a verified creation envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let state = try #require(envelope["state"] as? String)
        let verified = try #require(envelope["verified"] as? Bool)
        let observedName = try #require(envelope["observed_track_name"] as? String)
        let observedType = try #require(envelope["observed_track_type"] as? String)
        let observedIndex = try #require(envelope["observed_track_index"] as? Int)

        #expect(verified)
        #expect(state == "A")
        #expect(observedName == "Inst 1")
        #expect(observedType == "software_instrument")
        #expect(observedIndex == 1)
    }

    @Test("a single clean-plus-increased poll does not certify State A; certification waits for a second consecutive clean poll")
    func createRequiresTwoConsecutiveCleanPollsBeforeCertifyingStateA() async throws {
        // #538 BLOCKER: after Create, Logic rebuilds — the bound sheet can invalidate,
        // `AXChildren`/`AXSheets` can read back clean for exactly one poll, and a
        // replacement New Track sheet can attach on the very next read. A single
        // clean+increased poll is therefore not settled absence. This fixture serves
        // clean on the FIRST post-menu poll, a REATTACHED blocking sheet on the
        // SECOND, then clean again after that — proving both halves: attempt 0 alone
        // must not certify, and the operation must still reach State A once absence
        // actually settles (two consecutive clean polls), rather than wedging forever.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(760)
        let window = builder.element(761)
        let menuBar = builder.element(762)
        let trackMenu = builder.element(763)
        let createItem = builder.element(764)
        let headers = builder.element(765)
        let existing = builder.element(766)
        let created = builder.element(767)
        let replacementSheet = builder.element(768)
        let menuWasClicked = TrackCreateFlag()
        let replacementSheetObserved = TrackCreateFlag()
        let sheetReadsSinceMenuClick = TrackCreateCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Audio 1")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(created, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(created, kAXTitleAttribute as String, "Inst 1")
        builder.setAttribute(created, kAXDescriptionAttribute as String, "Software Instrument Track")
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)
        builder.setAttribute(replacementSheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(replacementSheet, kAXDescriptionAttribute as String, "New Track")

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                guard menuWasClicked.get() else { return .some([] as NSArray) }
                sheetReadsSinceMenuClick.increment()
                // Read #1 is the post-menu dialog reconcile; read #2 is the verify
                // loop's first (attempt 0) poll — both clean. Read #3 (attempt 1)
                // is the reattached replacement sheet. Reads #4-5 (attempts 2-3)
                // are clean again, giving a genuine two-consecutive-clean streak.
                if sheetReadsSinceMenuClick.current() == 3 {
                    replacementSheetObserved.set()
                    return .some([replacementSheet] as NSArray)
                }
                return .some([] as NSArray)
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, createItem), action == (kAXPressAction as String) else { return false }
                menuWasClicked.set()
                builder.setChildren(headers, [existing, created])
                return true
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        try #require(result.isSuccess, "expected a verified creation envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let state = try #require(envelope["state"] as? String)
        let verified = try #require(envelope["verified"] as? Bool)

        // Mutation `create-single-poll-certifies-state-a`: restore certifying State A
        // off the first clean+increased poll (no streak requirement). This fixture's
        // reattached-sheet seam at read #3 would then never be reached, because the
        // operation would already have returned after read #2.
        #expect(
            replacementSheetObserved.get(),
            "the reattached-sheet seam must fire, or this test proves nothing about settling"
        )
        #expect(verified)
        #expect(state == "A")
        #expect(sheetReadsSinceMenuClick.current() == 5)
    }

    @Test("an unnamed created header does not publish the literal 'Untitled' placeholder as an observed name")
    func createDoesNotPublishUnreadPlaceholderNameAsObserved() async throws {
        // #538: `extractTrackName` returns the literal `("Untitled", false)` when no
        // title/description/text-field name was actually readable on the header.
        // Publishing that literal as `observed_track_name` claims the header named
        // itself when nothing was read — only a live-identity-backed name is an
        // observed effect.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(780)
        let window = builder.element(781)
        let menuBar = builder.element(782)
        let trackMenu = builder.element(783)
        let createItem = builder.element(784)
        let headers = builder.element(785)
        let existing = builder.element(786)
        let created = builder.element(787)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Audio 1")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        // `created` deliberately has no title, description, or text-field/static-text
        // child: every `extractTrackName` source is empty, so it falls through to the
        // unread placeholder.
        builder.setAttribute(created, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, createItem), action == (kAXPressAction as String) else { return false }
                builder.setChildren(headers, [existing, created])
                return true
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        try #require(result.isSuccess, "expected a verified creation envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let state = try #require(envelope["state"] as? String)
        let verified = try #require(envelope["verified"] as? Bool)

        // Mutation `unread-placeholder-published-as-observed`: publish
        // `observed_track_name` unconditionally instead of gating it on
        // `liveIdentityBacked`. This fixture's unnamed header would then report
        // `observed_track_name == "Untitled"` as though it were read.
        #expect(verified)
        #expect(state == "A")
        #expect(envelope["observed_track_name"] == nil)
        #expect(envelope["observed_track_index"] as? Int == 1)
    }

    @Test("a rejected Create press is not reported as an auto-confirmed dialog even when the track count later increases")
    func rejectedCreatePressIsNotPublishedAsAutoConfirmed() async throws {
        // #538: `actionAttempted` is true whenever AX press was ISSUED, including
        // when AX itself rejected it. `new_track_dialog_auto_confirmed: true` must
        // mean AX actually accepted the click, not merely that a press was tried.
        // Here the bound Create control's AXPress reports failure, yet the header
        // still appears — Logic's own AX return codes are not trustworthy causal
        // evidence (this repo's #538 finding), so a track can still land despite a
        // reported rejection. The envelope must not claim the dialog was
        // auto-confirmed off that rejected press.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(800)
        let window = builder.element(801)
        let menuBar = builder.element(802)
        let trackMenu = builder.element(803)
        let createItem = builder.element(804)
        let headers = builder.element(805)
        let existing = builder.element(806)
        let created = builder.element(807)
        let sheet = builder.element(808)
        let create = builder.element(809)
        let cancel = builder.element(810)
        let menuWasClicked = TrackCreateFlag()
        let sheetWasCleared = TrackCreateFlag()
        let rejectedCreatePresses = TrackCreateCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Existing")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(created, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(created, kAXTitleAttribute as String, "Created Instrument")
        builder.setAttribute(created, kAXDescriptionAttribute as String, "Software Instrument Track")
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)
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
                guard menuWasClicked.get(), !sheetWasCleared.get() else { return .some([] as NSArray) }
                return .some([sheet] as NSArray)
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == (kAXPressAction as String) else { return false }
                if CFEqual(element, createItem) {
                    menuWasClicked.set()
                    return true
                }
                if CFEqual(element, create) {
                    // AX reports rejection, but the header appears anyway — the
                    // same "return codes lie" shape #538 measured live for -25202.
                    rejectedCreatePresses.increment()
                    sheetWasCleared.set()
                    builder.setChildren(headers, [existing, created])
                    return false
                }
                return false
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        try #require(result.isSuccess, "expected a verified creation envelope, got: \(result.message)")
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let state = try #require(envelope["state"] as? String)
        let verified = try #require(envelope["verified"] as? Bool)

        // Mutation `attempted-press-published-as-auto-confirmed`: gate
        // `new_track_dialog_auto_confirmed` on `actionAttempted` instead of
        // `actionAccepted`. The rejected-but-effective press above would then
        // publish the field as true.
        #expect(verified)
        #expect(state == "A")
        #expect(envelope["new_track_dialog_auto_confirmed"] == nil)
        #expect(envelope["reconcile_action_error"] != nil)
        #expect(rejectedCreatePresses.current() == 1, "the rejected-press seam must fire")
    }

    @Test("an unreadable post-menu blocker scan is not published as an observed dialog")
    func unreadableModalScanIsNotPublishedAsDialogPresent() async throws {
        // #538: `dialog_present` / `waiting_for_user` must claim only what was
        // observed. `kind != .none` is a real blocker; an incomplete scan
        // (`kind == .none` but `!modalObservationIsComplete`) is a read that
        // never answered — it must not be reported as "a dialog is present",
        // which asserts a control that was never seen. This fixture's stray-menu
        // scan fails on every poll (a genuine read failure, not structural
        // absence) while the track count never changes, so the operation
        // exhausts its budget with `kind == .none` and an unreadable reason.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(830)
        let window = builder.element(831)
        let menuBar = builder.element(832)
        let trackMenu = builder.element(833)
        let createItem = builder.element(834)
        let headers = builder.element(835)
        let existing = builder.element(836)
        let menuBarReadFailures = TrackCreateCounter()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Existing")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            // Only the status-preserving read is intercepted — `clickTrackMenu`
            // resolves the menu path through the best-effort `getChildren`
            // helper (a separate handler), so the menu press itself still works.
            childrenResultHandler: { element in
                guard CFEqual(element, menuBar) else { return nil }
                menuBarReadFailures.increment()
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                // The press succeeds but never mutates the rail, so the count
                // never increases and the operation runs its full budget.
                CFEqual(element, createItem) && action == (kAXPressAction as String)
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            korean: "소프트웨어 악기",
            english: "Software Instrument",
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let state = try #require(envelope["state"] as? String)
        let dialogPresent = try #require(envelope["dialog_present"] as? Bool)

        // Mutation `unreadable-scan-published-as-dialog-present`: restore
        // `blockingOrUnreadable = kind != .none || !modalObservationIsComplete`
        // feeding both `dialog_present` and `waiting_for_user`. This fixture's
        // never-answering stray-menu scan would then publish both as true even
        // though no dialog was ever observed.
        #expect(result.isSuccess)
        #expect(state == "B")
        #expect(!dialogPresent)
        #expect(envelope["waiting_for_user"] == nil)
        #expect(envelope["reconciled_modal_observation"] as? String == "incomplete")
        #expect(menuBarReadFailures.current() > 0, "the unreadable stray-menu scan seam must fire")
    }
}
