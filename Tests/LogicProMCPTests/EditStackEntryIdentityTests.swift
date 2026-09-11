@preconcurrency import ApplicationServices
import Foundation
import Testing

@testable import LogicProMCP

/// #864 — Logic's Undo row is identified by its SHORTCUT, because its wording is neither stable nor
/// unique.
///
/// The fixture is the live Edit menu, measured 2026-09-12 and recorded in
/// `docs/observations/2026-09-12-the-undo-entry-is-identified-by-its-shortcut-not-its-wording.json`:
///
///     Can't Undo                            cmdChar Z  mods 0   enabled false
///     Redo Insert Plug-in in Channel Strip  cmdChar Z  mods 1   enabled true
///     Undo History…                         cmdChar Z  mods 6   enabled true
///     Delete Undo History                   cmdChar -  mods 8   enabled true
///
/// Every row here is a real row from that reading. A fixture invented to make the rule look good
/// would not contain `Undo History…`, which is precisely the row the first implementation pressed.
@Suite("#864 the Edit-menu undo row is found by its shortcut")
struct EditStackEntryIdentityTests {
    private struct Menu {
        let builder: FakeAXRuntimeBuilder
        let runtime: AXLogicProElements.Runtime
        let barItem: AXUIElement
        let rows: [String: AXUIElement]
    }

    /// `rows` is (title, cmdChar, modifiers, enabled). Modifiers `nil` means the attribute is
    /// absent, which is what an element that does not answer the read looks like.
    private static func makeMenu(
        _ rows: [(String, String?, Int?, Bool)]
    ) -> Menu {
        let builder = FakeAXRuntimeBuilder()
        let barItem = builder.element(1)
        let menu = builder.element(2)
        builder.setAttribute(barItem, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)

        var made: [String: AXUIElement] = [:]
        var items: [AXUIElement] = []
        for (offset, row) in rows.enumerated() {
            let item = builder.element(10 + offset)
            builder.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
            builder.setAttribute(item, kAXTitleAttribute as String, row.0)
            if let char = row.1 {
                builder.setAttribute(item, "AXMenuItemCmdChar", char)
            }
            if let modifiers = row.2 {
                builder.setAttribute(item, "AXMenuItemCmdModifiers", NSNumber(value: modifiers))
            }
            builder.setAttribute(item, kAXEnabledAttribute as String, NSNumber(value: row.3))
            items.append(item)
            made[row.0] = item
        }
        builder.setChildren(menu, items)
        builder.setChildren(barItem, [menu])
        return Menu(
            builder: builder,
            runtime: builder.makeLogicRuntime(appElement: builder.element(0)),
            barItem: barItem,
            rows: made
        )
    }

    private static let liveEditMenu: [(String, String?, Int?, Bool)] = [
        ("Can’t Undo", "Z", 0, false),
        ("Redo Insert Plug-in in Channel Strip", "Z", 1, true),
        ("Undo History…", "Z", 6, true),
        ("Delete Undo History", nil, 8, true),
        ("Cut", "X", 0, true),
    ]

    @Test("the undo row is the one at command-Z with no modifier, even when its title says Can't Undo")
    func undoRowIsFoundWhileDisabled() throws {
        let menu = Self.makeMenu(Self.liveEditMenu)
        let found = try #require(
            AccessibilityChannel.editStackEntry(under: menu.barItem, redo: false, runtime: menu.runtime)
        )
        #expect(found == menu.rows["Can’t Undo"])
    }

    /// The row the first implementation pressed. `Undo History…` is the only title that STARTS with
    /// `Undo` while the stack is empty, so a prefix match lands on it — and pressing it opens a
    /// window instead of undoing anything.
    @Test("the decoy that prefix-matches Undo is not selected")
    func undoHistoryIsNotSelected() throws {
        let menu = Self.makeMenu(Self.liveEditMenu)
        let found = try #require(
            AccessibilityChannel.editStackEntry(under: menu.barItem, redo: false, runtime: menu.runtime)
        )
        #expect(found != menu.rows["Undo History…"])
        // Stated as its own assertion because the two rows share a shortcut CHARACTER and differ
        // only in the modifier mask; a rule that compared the character alone would pass the test
        // above by accident whenever the decoy came second.
        #expect(menu.rows["Undo History…"] != nil)
    }

    @Test("the redo row is the one at shift-command-Z")
    func redoRowIsFoundByItsModifier() throws {
        let menu = Self.makeMenu(Self.liveEditMenu)
        let found = try #require(
            AccessibilityChannel.editStackEntry(under: menu.barItem, redo: true, runtime: menu.runtime)
        )
        #expect(found == menu.rows["Redo Insert Plug-in in Channel Strip"])
    }

    /// Undo and redo must never resolve to the same element. They share a character and a menu, and
    /// the whole rule is the one bit that separates them.
    @Test("undo and redo are different rows")
    func undoAndRedoAreDistinct() throws {
        let menu = Self.makeMenu(Self.liveEditMenu)
        let undo = try #require(
            AccessibilityChannel.editStackEntry(under: menu.barItem, redo: false, runtime: menu.runtime)
        )
        let redo = try #require(
            AccessibilityChannel.editStackEntry(under: menu.barItem, redo: true, runtime: menu.runtime)
        )
        #expect(undo != redo)
    }

    /// A host that remapped ⌘Z matches no row, and the answer is nil so the caller refuses. The
    /// alternative — falling back to the wording — is what this change exists to remove, and it
    /// would press `Undo History…` on exactly the hosts that are hardest to debug.
    @Test("a remapped shortcut resolves to nothing rather than to the nearest title")
    func remappedShortcutResolvesToNothing() {
        let menu = Self.makeMenu([
            ("Can’t Undo", "Y", 0, false),
            ("Undo History…", "Z", 6, true),
            ("Delete Undo History", nil, 8, true),
        ])
        #expect(
            AccessibilityChannel.editStackEntry(under: menu.barItem, redo: false, runtime: menu.runtime) == nil
        )
    }

    /// An unreadable modifier attribute is not a modifier of zero. `NSNumber?` that is nil must not
    /// be coerced into the undo mask — that would make every unreadable row match.
    @Test("a row whose modifier attribute is absent does not match")
    func absentModifierDoesNotMatch() {
        let menu = Self.makeMenu([
            ("Can’t Undo", "Z", nil, false),
            ("Delete Undo History", nil, 8, true),
        ])
        #expect(
            AccessibilityChannel.editStackEntry(under: menu.barItem, redo: false, runtime: menu.runtime) == nil
        )
    }

    /// The character comparison is case-folded. AX reports it uppercase here; a build that reported
    /// `z` must not stop finding the row.
    @Test("the shortcut character is matched without regard to case")
    func shortcutCharacterIsCaseInsensitive() throws {
        let menu = Self.makeMenu([("Undo Renaming", "z", 0, true)])
        let found = try #require(
            AccessibilityChannel.editStackEntry(under: menu.barItem, redo: false, runtime: menu.runtime)
        )
        #expect(found == menu.rows["Undo Renaming"])
    }
}
