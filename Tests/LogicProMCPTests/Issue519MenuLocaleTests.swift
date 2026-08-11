import Testing
@testable import LogicProMCP

/// Ten menu drives named the English menu-bar item, so every operation routed through them failed on
/// a Logic running in another language. Measured live on 2026-08-11 with Logic in Korean:
/// `project.new` returned `channels_exhausted` in 2.8 s with
/// `"Could not reveal Creator Studio chooser through exact File > New"` — it never reached either
/// creation branch, because the File menu is `파일` and its New entry is `신규`.
///
/// The variants here are read from the live menu bar, never translated: a hand translation would have
/// produced `새로 만들기`, which is not what Logic shows.
@Suite("#519 menu and window titles are localized")
struct Issue519MenuLocaleTests {
    @Test("the File menu and its New entry carry the measured Korean titles")
    func fileAndNewAreLocalized() {
        #expect(AXLocalePolicy.fileMenuBar.labels.contains("File"))
        #expect(AXLocalePolicy.fileMenuBar.labels.contains("파일"))
        #expect(AXLocalePolicy.newProjectMenuItem.labels.contains("New"))
        #expect(AXLocalePolicy.newProjectMenuItem.labels.contains("신규"))
        // The plausible mistranslation must NOT be what the policy carries, so a future edit that
        // "corrects" it fails here instead of failing on a user's machine.
        #expect(!AXLocalePolicy.newProjectMenuItem.labels.contains("새로 만들기"))
    }

    @Test("the arrange window witness accepts every locale Logic actually produces")
    func arrangeWitnessIsLocalized() {
        // English and Korean, both read off the live window title.
        #expect(AccessibilityChannel.isCreatedProjectWindowTitle("Untitled 56 - Tracks"))
        #expect(AccessibilityChannel.isCreatedProjectWindowTitle("무제 30 - 트랙"))
        // A bare suffix with nothing before it is not a project.
        #expect(!AccessibilityChannel.isCreatedProjectWindowTitle(" - 트랙"))
        #expect(!AccessibilityChannel.isCreatedProjectWindowTitle("트랙"))
        #expect(!AccessibilityChannel.isCreatedProjectWindowTitle("Choose a Project"))
    }
}
