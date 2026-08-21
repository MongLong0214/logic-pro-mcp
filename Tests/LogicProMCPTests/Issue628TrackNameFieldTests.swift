@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #628, first converted call site. The caller WRITES to whatever this returns — press, set
/// `AXValue`, confirm — so a blind first match does not read the wrong element, it renames it.
///
/// Chosen first because refusing is cheap here: `AccessibilityChannel+Tracks` falls through to
/// select-then-menu when this returns nil, and verifies either way. A site where nil breaks the
/// operation would need its own answer to ambiguity before it could be converted.
///
/// Measured 2026-08-21 on Logic 12.3, `--probe-locator-census AXTextField --probe-locator-from
/// "Tracks header"`: one text field in the whole rail — only the selected track renders one — so
/// per header the live set is 0 or 1 and this changes nothing in the state it was measured in.
/// These cases are about the state nobody has seen.
@Suite("Issue #628 — the track name field is counted, not taken first")
struct Issue628TrackNameFieldTests {

    private func header(_ b: FakeAXRuntimeBuilder, _ id: Int, children: [(Int, String)]) -> AXUIElement {
        let node = b.element(id)
        var kids: [AXUIElement] = []
        for (childID, role) in children {
            let child = b.element(childID)
            b.setAttribute(child, kAXRoleAttribute as String, role)
            kids.append(child)
        }
        b.setChildren(node, kids)
        return node
    }

    @Test("one text field is returned")
    func oneFieldIsReturned() throws {
        let b = FakeAXRuntimeBuilder()
        let h = header(b, 7001, children: [(7002, kAXTextFieldRole as String),
                                           (7003, kAXButtonRole as String)])
        let found = try #require(AXLogicProElements.trackNameField(
            in: h, runtime: b.makeLogicRuntime()))
        #expect(CFEqual(found, b.element(7002)))
    }

    /// The case this conversion exists for. Two fields used to return whichever the walk reached
    /// first, and the caller would have typed the track's new name into it.
    @Test("two text fields return NOTHING rather than the first one")
    func twoFieldsRefuse() throws {
        let b = FakeAXRuntimeBuilder()
        let h = header(b, 7101, children: [(7102, kAXTextFieldRole as String),
                                           (7103, kAXTextFieldRole as String)])
        #expect(AXLogicProElements.trackNameField(in: h, runtime: b.makeLogicRuntime()) == nil)

        // The blind form still answers, which is what this site used to do.
        #expect(AXHelpers.findDescendant(
            of: h, role: kAXTextFieldRole, maxDepth: 4, runtime: b.makeAXRuntime()) != nil)
    }

    /// Ambiguity must NOT fall through to the static-text fallback. Doing so would answer a
    /// "which field" question with a different element and write the name into that instead —
    /// the same defect wearing the fallback's clothes.
    @Test("ambiguity does not fall through to the static-text fallback")
    func ambiguityDoesNotFallThrough() throws {
        let b = FakeAXRuntimeBuilder()
        let h = header(b, 7201, children: [(7202, kAXTextFieldRole as String),
                                           (7203, kAXTextFieldRole as String),
                                           (7204, kAXStaticTextRole as String)])
        #expect(AXLogicProElements.trackNameField(in: h, runtime: b.makeLogicRuntime()) == nil)
    }

    /// Zero text fields still reaches the fallback. It is measured dead on this Logic — zero
    /// `AXStaticText` under `Tracks header` — and kept because zero is a fact about one layout.
    @Test("no text field falls back to static text, which is kept though measured dead")
    func zeroFieldsFallBack() throws {
        let b = FakeAXRuntimeBuilder()
        let h = header(b, 7301, children: [(7302, kAXStaticTextRole as String)])
        let found = try #require(AXLogicProElements.trackNameField(
            in: h, runtime: b.makeLogicRuntime()))
        #expect(CFEqual(found, b.element(7302)))
    }

    @Test("nothing usable on the header returns nil")
    func nothingReturnsNil() throws {
        let b = FakeAXRuntimeBuilder()
        let h = header(b, 7401, children: [(7402, kAXButtonRole as String)])
        #expect(AXLogicProElements.trackNameField(in: h, runtime: b.makeLogicRuntime()) == nil)
    }
}
