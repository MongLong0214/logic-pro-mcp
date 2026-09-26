@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class PressedTitles: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String] = []

    func append(_ title: String) {
        lock.lock()
        titles.append(title)
        lock.unlock()
    }

    func current() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return titles
    }
}

/// The Track menu of a German Logic 12.3, as its AXTitles read on 2026-09-26 (#883).
///
/// Written with escapes because the characters are the point. Apple's row for the Session Player
/// leaf has U+00A0 after `Session` and before the ellipsis; the menu renders both as U+0020, and a
/// fixture typed from the row rather than from the menu would have agreed with the old policy.
/// `Neue Spuren …` is the New Tracks item, the one leaf the drummer route must not press even
/// though its title shares the word and the ellipsis.
private let germanTrackMenu: [String] = [
    "Neue Spuren\u{0020}\u{2026}",
    "Neue Audiospur",
    "Neue Spur f\u{00FC}r Software-Instrument",
    "Neue Session\u{0020}Player SI-Spur\u{0020}\u{2026}",
    "Neue externe MIDI-Spur",
]

@Suite("Issue #883 — track creation presses the control Logic draws, in the language it runs in")
struct Issue883TrackCreationAsRenderedTests {

    @Test(
        "a German Track menu gets the one leaf each operation asks for",
        arguments: [
            ("track.create_instrument", "Neue Spur f\u{00FC}r Software-Instrument"),
            ("track.create_audio", "Neue Audiospur"),
            ("track.create_drummer", "Neue Session\u{0020}Player SI-Spur\u{0020}\u{2026}"),
            ("track.create_external_midi", "Neue externe MIDI-Spur"),
        ]
    )
    func eachOperationPressesItsOwnLeaf(operation: String, leaf: String) async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(8830)
        let window = builder.element(8831)
        let menuBar = builder.element(8832)
        let trackMenu = builder.element(8833)
        let headers = builder.element(8834)
        let header = builder.element(8835)
        let items = germanTrackMenu.indices.map { builder.element(8840 + $0) }
        let pressed = PressedTitles()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [header])
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(header, kAXTitleAttribute as String, "Absolute Zero")
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Spur")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, items)
        for (item, title) in zip(items, germanTrackMenu) {
            builder.setAttribute(item, kAXTitleAttribute as String, title)
            builder.setAttribute(item, kAXSelectedAttribute as String, false)
        }

        let logicRuntime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == (kAXPressAction as String),
                      let index = items.firstIndex(where: { CFEqual($0, element) }) else { return false }
                pressed.append(germanTrackMenu[index])
                return true
            }
        )
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true },
            isLogicProRunning: { true },
            hasVisibleWindow: { true },
            logicRuntime: logicRuntime
        ))

        let result = await channel.execute(operation: operation, params: [:])

        // Before this change the drummer route matched only Apple's row, found no leaf in this menu,
        // pressed nothing and answered `Cannot find menu item` -- which the router then handed to a
        // key command that created no track. The other three are here so the four are told apart:
        // an operation that pressed a neighbour's leaf would fail this as surely as one that pressed
        // none.
        #expect(pressed.current() == [leaf], "\(operation) pressed \(pressed.current())")
        #expect(!result.message.contains("Cannot find menu item"), "\(operation): \(result.message)")
    }

    /// The New Track sheet `project.new` raises, in the shape the two languages read on 2026-09-26:
    /// a sheet under the window's children (Logic answers `-25205` for `AXSheets`), the description,
    /// the Create and Cancel titles, Cancel ENABLED, and a Help button that has only a description.
    /// A Spanish Logic titles Create `Crear`, which the cited row does not hold, so the reconciler
    /// pressed nothing and `project.new` left the sheet up.
    @Test(
        "the New Track sheet is confirmed through the Create button its language draws",
        arguments: [
            ("Nueva pista", "Crear", "Cancelar", "Ayuda"),
            ("Neue Spur", "Erzeugen", "Abbrechen", "Hilfe"),
        ]
    )
    func theSheetIsConfirmedThroughItsOwnCreate(
        description: String, create: String, cancel: String, help: String
    ) async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(8850)
        let window = builder.element(8851)
        let sheet = builder.element(8852)
        let group = builder.element(8853)
        let buttons = [create, cancel].indices.map { builder.element(8854 + $0) }
        let helpButton = builder.element(8856)
        let pressed = PressedTitles()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setChildren(window, [sheet])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, description)
        builder.setChildren(sheet, [group])
        builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setChildren(group, buttons + [helpButton])
        for (button, title) in zip(buttons, [create, cancel]) {
            builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(button, kAXTitleAttribute as String, title)
            builder.setAttribute(button, kAXEnabledAttribute as String, true)
        }
        builder.setAttribute(helpButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(helpButton, kAXDescriptionAttribute as String, help)

        let unsupported = AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { _, attribute in
                attribute == "AXSheets" ? .failure(unsupported) : nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == (kAXPressAction as String) else { return false }
                if CFEqual(element, helpButton) {
                    pressed.append(help)
                } else if let index = buttons.firstIndex(where: { CFEqual($0, element) }) {
                    pressed.append([create, cancel][index])
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

        #expect(outcome.kind == .mandatoryNewTrack)
        #expect(pressed.current() == [create], "pressed \(pressed.current())")
    }
}

/// The Spanish sheet read on 2026-09-26, with the one thing that failed that day put back: a Create
/// whose title the Create LabelSet does not hold. The description still names the sheet and Cancel
/// is enabled, as both languages read it.
private let unidentifiableCreate = "Crear pista"
private let spanishCancel = "Cancelar"

/// The sheet leaves only because Cancel was pressed: until then it is in the window's children and
/// its own AXRole reads; after, it is out of the children and its identity answers `-25202`. With
/// `dismissalRemovesSheet == false` the press is accepted and nothing changes, which is the case the
/// envelope must not call closed.
///
/// `afterCancel` is what Logic does to the project on `project.new`'s mandatory sheet, measured
/// 2026-09-26 in Korean from a cold launch: Cancel closes the untitled project. Its window's identity
/// then answers `-25202`, `AXMainWindow` reads `-25212` with no windows, and about half a second
/// later the project chooser, an ordinary non-modal standard window, is main.
private enum AfterCancel {
    case projectStays
    case noWindow
    case chooserIsMain
}

private final class OwnedSheetFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let menuBar: AXUIElement
    let headers: AXUIElement
    let existing: AXUIElement
    let sheet: AXUIElement
    let create: AXUIElement
    let cancel: AXUIElement
    let chooser: AXUIElement
    let pressed = PressedTitles()
    let dismissalRemovesSheet: Bool
    let afterCancel: AfterCancel

    init(base: Int, dismissalRemovesSheet: Bool, afterCancel: AfterCancel = .projectStays) {
        self.dismissalRemovesSheet = dismissalRemovesSheet
        self.afterCancel = afterCancel
        app = builder.element(base)
        window = builder.element(base + 1)
        menuBar = builder.element(base + 2)
        headers = builder.element(base + 3)
        existing = builder.element(base + 4)
        sheet = builder.element(base + 5)
        create = builder.element(base + 6)
        cancel = builder.element(base + 7)
        chooser = builder.element(base + 8)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setAttribute(window, kAXTitleAttribute as String, "Sin título 1 - Pistas")
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Audio 1")
        builder.setChildren(headers, [existing])
        builder.setChildren(menuBar, [])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "Nueva pista")
        builder.setChildren(sheet, [create, cancel])
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, unidentifiableCreate)
        builder.setAttribute(create, kAXEnabledAttribute as String, true)
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, spanishCancel)
        builder.setAttribute(cancel, kAXEnabledAttribute as String, true)
        builder.setAttribute(chooser, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(chooser, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        builder.setAttribute(chooser, kAXModalAttribute as String, false)
        builder.setAttribute(chooser, kAXTitleAttribute as String, "Seleccionar un proyecto")
        builder.setChildren(chooser, [])
    }

    var cancelPresses: Int { pressed.current().filter { $0 == spanishCancel }.count }
    var createPresses: Int { pressed.current().filter { $0 == unidentifiableCreate }.count }
    private var sheetDismissed: Bool { dismissalRemovesSheet && cancelPresses > 0 }
    private var projectClosed: Bool { sheetDismissed && afterCancel != .projectStays }

    func showSheet() {
        builder.setChildren(window, [headers, sheet])
    }

    /// `extraPress` lets a caller add a menu leaf; returning nil falls through to the sheet buttons.
    func runtime(extraPress: (@Sendable (AXUIElement) -> Bool?)? = nil) -> AXLogicProElements.Runtime {
        let unsupported = AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)
        let destroyed = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)
        let noValue = AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
        return builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { [self] element, attribute in
                if attribute == "AXSheets" { return .failure(unsupported) }
                if sheetDismissed, CFEqual(element, sheet) { return .failure(destroyed) }
                if projectClosed, CFEqual(element, window) { return .failure(destroyed) }
                if afterCancel == .noWindow, projectClosed, CFEqual(element, app),
                   attribute == (kAXMainWindowAttribute as String) {
                    return .failure(noValue)
                }
                return nil
            },
            // A destroyed element answers -25202 to every attribute, AXChildren included. Children
            // come through their own seam, so without this the dead window still lists its children
            // and a scan of it reads as complete.
            childrenResultHandler: { [self] element in
                if sheetDismissed, CFEqual(element, sheet) { return .failure(destroyed) }
                if projectClosed, CFEqual(element, window) { return .failure(destroyed) }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { [self] element, action in
                guard action == (kAXPressAction as String) else { return false }
                if let handled = extraPress?(element) { return handled }
                if CFEqual(element, create) {
                    pressed.append(unidentifiableCreate)
                    return true
                }
                if CFEqual(element, cancel) {
                    pressed.append(spanishCancel)
                    if dismissalRemovesSheet {
                        builder.setChildren(window, [headers])
                        switch afterCancel {
                        case .projectStays:
                            break
                        case .noWindow:
                            builder.setAttribute(app, kAXWindowsAttribute as String, [AXUIElement]())
                        case .chooserIsMain:
                            builder.setAttribute(app, kAXMainWindowAttribute as String, chooser)
                            builder.setAttribute(app, kAXWindowsAttribute as String, [chooser])
                        }
                    }
                    return true
                }
                return false
            }
        )
    }
}

private func decodeEnvelope(_ result: ChannelResult) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

@Suite("Issue #883 — a New Track sheet the operation gave up on is dismissed and re-read")
struct Issue883OwnedNewTrackSheetCleanupTests {

    @Test(
        "project.new dismisses its own sheet when Create cannot be identified, and reports the re-read",
        arguments: [true, false]
    )
    func projectNewDismissesItsSheet(dismissalRemovesSheet: Bool) async throws {
        let fixture = OwnedSheetFixture(base: 8870, dismissalRemovesSheet: dismissalRemovesSheet)
        fixture.showSheet()

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime(),
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0,
            newTrackSheetCleanupAttempts: 2
        )
        let envelope = try decodeEnvelope(result)
        let cleanup = try #require(
            envelope["new_track_sheet_cleanup"] as? [String: Any],
            "no cleanup was reported: \(result.message)"
        )

        #expect(!result.isSuccess)
        #expect(envelope["state"] as? String == "B")
        #expect(envelope["phase"] as? String == "mandatory_track_create_unconfirmed")
        #expect(fixture.createPresses == 0, "a Create the policy cannot identify must never be pressed")
        #expect(fixture.cancelPresses == 1)
        let dismissAttempted = try #require(cleanup["dismiss_attempted"] as? Bool)
        let boundSheetGone = try #require(cleanup["bound_sheet_gone"] as? Bool)
        #expect(dismissAttempted)
        #expect(cleanup["method"] as? String == "cancel_button")
        if dismissalRemovesSheet {
            #expect(cleanup["result"] as? String == "observed_closed")
            #expect(boundSheetGone)
            #expect(cleanup["post_cleanup_modal"] as? String == "none")
        } else {
            #expect(cleanup["result"] as? String == "not_observed_closed")
            #expect(!boundSheetGone)
            #expect(cleanup["post_cleanup_modal"] as? String == "mandatory_new_track")
            #expect(cleanup["polls"] as? Int == 2)
        }
    }

    @Test(
        "project.new's Cancel closes the untitled project, and the re-read follows the app, not the dead window",
        arguments: [AfterCancel.noWindow, AfterCancel.chooserIsMain]
    )
    fileprivate func projectNewCancelClosesTheProject(afterCancel: AfterCancel) async throws {
        let fixture = OwnedSheetFixture(base: 8880, dismissalRemovesSheet: true, afterCancel: afterCancel)
        fixture.showSheet()

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime(),
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0,
            newTrackSheetCleanupAttempts: 2
        )
        let envelope = try decodeEnvelope(result)
        let cleanup = try #require(
            envelope["new_track_sheet_cleanup"] as? [String: Any],
            "no cleanup was reported: \(result.message)"
        )

        #expect(!result.isSuccess)
        #expect(fixture.cancelPresses == 1)
        let boundSheetGone = try #require(cleanup["bound_sheet_gone"] as? Bool)
        #expect(boundSheetGone)
        #expect(cleanup["post_cleanup_observation"] as? String == "complete",
                "a read of the window Cancel destroyed is not a read of what is on screen: \(cleanup)")
        #expect(cleanup["post_cleanup_modal"] as? String == "none")
        #expect(cleanup["result"] as? String == "observed_closed")
    }

    @Test(
        "track.create dismisses the sheet its menu press opened when Create cannot be identified",
        arguments: [true, false]
    )
    func trackCreateDismissesTheSheetItOpened(dismissalRemovesSheet: Bool) async throws {
        let fixture = OwnedSheetFixture(base: 8880, dismissalRemovesSheet: dismissalRemovesSheet)
        let trackMenu = fixture.builder.element(8890)
        let leaf = fixture.builder.element(8891)
        fixture.builder.setChildren(fixture.window, [fixture.headers])
        fixture.builder.setChildren(fixture.menuBar, [trackMenu])
        fixture.builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Pista")
        fixture.builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        fixture.builder.setChildren(trackMenu, [leaf])
        fixture.builder.setAttribute(leaf, kAXTitleAttribute as String, "Nueva pista de audio")
        fixture.builder.setAttribute(leaf, kAXSelectedAttribute as String, false)

        let runtime = fixture.runtime(extraPress: { element in
            guard CFEqual(element, leaf) else { return nil }
            fixture.pressed.append("leaf")
            fixture.showSheet()
            return true
        })
        let result = await AccessibilityChannel.createTrackViaMenu(
            item: AXLocalePolicy.LabelSet(
                canonical: "New Audio Track",
                variants: ["Nueva pista de audio"],
                rationale: "fixture menu leaf"),
            expectedTrackType: .audio,
            runtime: runtime,
            dialogPollAttempts: 2,
            dialogPollDelayNanoseconds: 0,
            newTrackSheetCleanupAttempts: 2
        )
        let envelope = try decodeEnvelope(result)
        let cleanup = try #require(
            envelope["new_track_sheet_cleanup"] as? [String: Any],
            "no cleanup was reported: \(result.message)"
        )

        #expect(fixture.pressed.current().first == "leaf", "the menu press seam must fire first")
        #expect(envelope["state"] as? String == "B")
        let verified = try #require(envelope["verified"] as? Bool)
        let dismissAttempted = try #require(cleanup["dismiss_attempted"] as? Bool)
        let dialogPresent = try #require(envelope["dialog_present"] as? Bool)
        #expect(!verified)
        #expect(envelope["reconciled_modal_kind"] as? String == "mandatory_new_track")
        #expect(fixture.createPresses == 0)
        #expect(fixture.cancelPresses == 1)
        #expect(dismissAttempted)
        if dismissalRemovesSheet {
            #expect(cleanup["result"] as? String == "observed_closed")
            #expect(!dialogPresent)
            #expect(envelope["waiting_for_user"] == nil)
        } else {
            #expect(cleanup["result"] as? String == "not_observed_closed")
            #expect(dialogPresent)
            let waitingForUser = try #require(envelope["waiting_for_user"] as? Bool)
            #expect(waitingForUser)
        }
    }

    @Test("track.create does not dismiss a New Track sheet that was already up before its menu press")
    func trackCreateLeavesASheetItDidNotOpen() async throws {
        let fixture = OwnedSheetFixture(base: 8900, dismissalRemovesSheet: true)
        let trackMenu = fixture.builder.element(8910)
        let leaf = fixture.builder.element(8911)
        fixture.showSheet()
        fixture.builder.setChildren(fixture.menuBar, [trackMenu])
        fixture.builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Pista")
        fixture.builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        fixture.builder.setChildren(trackMenu, [leaf])
        fixture.builder.setAttribute(leaf, kAXTitleAttribute as String, "Nueva pista de audio")
        fixture.builder.setAttribute(leaf, kAXSelectedAttribute as String, false)

        let runtime = fixture.runtime(extraPress: { element in
            guard CFEqual(element, leaf) else { return nil }
            fixture.pressed.append("leaf")
            return true
        })
        let result = await AccessibilityChannel.createTrackViaMenu(
            item: AXLocalePolicy.LabelSet(
                canonical: "New Audio Track",
                variants: ["Nueva pista de audio"],
                rationale: "fixture menu leaf"),
            expectedTrackType: .audio,
            runtime: runtime,
            dialogPollAttempts: 2,
            dialogPollDelayNanoseconds: 0,
            newTrackSheetCleanupAttempts: 2
        )
        let envelope = try decodeEnvelope(result)

        #expect(fixture.pressed.current().contains("leaf"), "the menu press seam must fire")
        #expect(envelope["reconciled_modal_kind"] as? String == "mandatory_new_track")
        #expect(fixture.cancelPresses == 0, "a sheet this call did not open is not its to dismiss")
        #expect(envelope["new_track_sheet_cleanup"] == nil)
    }
}
