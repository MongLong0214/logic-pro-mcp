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
}
