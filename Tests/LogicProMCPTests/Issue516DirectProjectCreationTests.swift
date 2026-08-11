import Testing
@testable import LogicProMCP

/// `project.new` used to succeed only if Logic answered `File ▸ New` with the template chooser.
/// Measured live on 2026-08-11: Logic can skip the chooser entirely, create the untitled project
/// immediately and present only its mandatory New Track sheet. The operation then polled ten seconds
/// for a chooser that was never coming and reported `channels_exhausted` — for a project it had just
/// created. The arrange window read `Untitled 56 - Tracks` the whole time.
///
/// These lock the pieces that decide whether that outcome is recognised. The end-to-end behaviour is
/// covered by the live run recorded on #516, because which of the two routes Logic takes is a
/// property of the host's settings and cannot be produced from a unit test.
@Suite("#516 direct project creation")
struct Issue516DirectProjectCreationTests {
    @Test("an arrange window title is accepted as the created-project witness")
    func arrangeTitleIsTheWitness() {
        // The exact title observed live when the chooser was skipped.
        #expect(AccessibilityChannel.isCreatedProjectWindowTitle("Untitled 56 - Tracks"))
        #expect(AccessibilityChannel.createdProjectWindowSelectionIsUnambiguous(
            windowTitle: "Untitled 56 - Tracks",
            windowRole: "AXWindow",
            windowSubrole: "AXStandardWindow"
        ))
    }

    @Test("the chooser window itself is never mistaken for a created project")
    func chooserIsNotAProject() {
        #expect(!AccessibilityChannel.isCreatedProjectWindowTitle("Choose a Project"))
        // A dialog carrying an arrange-shaped title must still be refused on its subrole, so a sheet
        // or panel cannot stand in for the document window.
        #expect(!AccessibilityChannel.createdProjectWindowSelectionIsUnambiguous(
            windowTitle: "Untitled 56 - Tracks",
            windowRole: "AXWindow",
            windowSubrole: "AXDialog"
        ))
        #expect(!AccessibilityChannel.createdProjectWindowSelectionIsUnambiguous(
            windowTitle: "Untitled 56 - Tracks",
            windowRole: "AXSheet",
            windowSubrole: "AXStandardWindow"
        ))
    }

    @Test("File > New is only driven from a blank application")
    func onlyFromZeroWindows() {
        // The precondition that keeps this route from acting on a session that already has a
        // document open — the case where a second, ambiguous project could be created.
        #expect(AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: 0))
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: 1))
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: nil))
    }
}
