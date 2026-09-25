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
