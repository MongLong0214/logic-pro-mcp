import Testing
@testable import LogicProMCP

/// `nav.delete_marker` reported `success: true, state: B` while the marker stayed in the project.
/// The server log showed why:
///
///     [router] nav.delete_marker failed via Accessibility:
///       {"error":"ax_write_failed",
///        "hint":"The Marker List did not hold keyboard focus, so Delete was not pressed …",
///        "write_attempted":false,"state":"C"}, trying next
///     [router] nav.delete_marker succeeded via MIDIKeyCommands
///
/// The accessibility path's safety guard refused — correctly, since the same keystroke deletes a
/// region or a track when focus is elsewhere — and the router treated that deliberate
/// `write_attempted: false` refusal as a failure, fell through to the MIDI key-command channel, and
/// that channel fired a CC nothing is bound to and answered success.
///
/// Acting through the Marker List window's own Edit ▸ Delete removes the reason to be in that
/// position: the menu entry is aimed at this list and needs no keyboard focus. Verified live —
/// `state A`, `verified true`, 15 markers to 14, confirmed on screen.
@Suite("#523 marker delete acts through the list's own menu")
struct Issue523MarkerDeleteMenuTests {
    @Test("the Delete entry is addressed exactly, never by prefix")
    func deleteIsMatchedExactly() {
        // The same menu offers `Delete Undo History`. A prefix match reaches it first — that is not
        // hypothetical: it ran during this investigation and discarded a project's undo history.
        #expect(AXLocalePolicy.deleteMenuItem.canonical == "Delete")
        #expect(!AXLocalePolicy.deleteMenuItem.labels.contains("Delete Undo History"))
        #expect(!AXLocalePolicy.deleteMenuItem.matches("Delete Undo History", mode: .exactStrict))
        #expect(AXLocalePolicy.deleteMenuItem.matches("Delete", mode: .exactStrict))
    }

    @Test("the Korean variant is carried, and is the measured one")
    func koreanVariantIsPresent() {
        #expect(AXLocalePolicy.deleteMenuItem.labels.contains("삭제"))
    }

    @Test("the Edit menu is addressed by the existing policy entry")
    func editMenuLabelIsShared() {
        // The window's own Edit menu button and the application Edit menu answer to the same name,
        // so one policy entry serves both; what this change altered is where it is looked for.
        #expect(AXLocalePolicy.editMenuBar.labels.contains("Edit"))
        #expect(AXLocalePolicy.editMenuBar.labels.contains("편집"))
    }
}
