@preconcurrency import ApplicationServices
import Foundation
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

    /// #590 — "blank" means no DOCUMENT, not no window.
    ///
    /// A freshly launched Logic shows "Choose a Project". Counting raw windows made that chooser an
    /// open document, so this route refused from the exact state Logic lands in at launch. Measured
    /// on 12.3 in English and Korean alike; and File > New driven with the chooser still on screen
    /// creates the project anyway, so the ambiguity the precondition guards against is not present.
    @Test("the project chooser is not a document")
    func chooserDoesNotCountAsAnOpenDocument() {
        let builder = FakeAXRuntimeBuilder()
        let chooser = builder.element(59_000)
        builder.setAttribute(chooser, kAXTitleAttribute as String, "Choose a Project")
        let koreanChooser = builder.element(59_001)
        builder.setAttribute(koreanChooser, kAXTitleAttribute as String, "프로젝트 선택")
        let document = builder.element(59_002)
        builder.setAttribute(document, kAXTitleAttribute as String, "Untitled 56 - Tracks")
        let runtime = builder.makeLogicRuntime()

        let choosersOnly = AccessibilityChannel.documentWindowCount(
            [chooser, koreanChooser], runtime: runtime
        )
        #expect(choosersOnly == 0)
        #expect(AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: choosersOnly))

        let withDocument = AccessibilityChannel.documentWindowCount(
            [chooser, document], runtime: runtime
        )
        #expect(withDocument == 1)
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: withDocument))

        // An unreadable window list is still not a blank application: "we could not look" must not
        // read as "there is nothing there".
        #expect(AccessibilityChannel.documentWindowCount(nil, runtime: runtime) == nil)
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(
            windowCount: AccessibilityChannel.documentWindowCount(nil, runtime: runtime)
        ))
    }
}

/// The refusal `project.new` gives when a document is already open.
///
/// The precondition itself is deliberate and stays — with a document open, a newly created project
/// cannot be told apart from the windows already on screen. What was wrong was everything the
/// operator was told about it. Measured on desktop Logic Pro 12.3, 2026-08-17, with one project
/// open:
///
///     {"error":"channels_exhausted",
///      "hint":"Creator Studio has a non-chooser window; refusing project.new", ...}
///
/// Two false statements in one envelope. The operator was not running Creator Studio, and
/// `channels_exhausted` is documented as "every channel in the chain reported itself unavailable" —
/// here the one channel ran and declined on purpose. The bare prose is what caused the second one:
/// `ChannelRouter` surfaces a single-channel State C verbatim only when it can recognise the string
/// as an envelope, and a sentence is not an envelope.
@Suite("#565 project.new says why it refused, in terms the operator can act on")
struct ProjectNewOpenDocumentRefusalTests {
    private func refusalMessage(windowCount: Int) async -> String {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(30_000)
        var windows: [AXUIElement] = []
        for index in 0..<windowCount {
            let window = builder.element(30_100 + index)
            builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Open Project \(index) - Tracks")
            windows.append(window)
        }
        builder.setAttribute(app, kAXWindowsAttribute as String, windows)
        builder.setChildren(app, windows)

        let result = await AccessibilityChannel.createEmptyProjectFromQualifiedState(
            runtime: builder.makeLogicRuntime(appElement: app)
        )
        #expect(!result.isSuccess)
        return result.message
    }

    private func refusalEnvelope(windowCount: Int) async throws -> [String: Any] {
        // The refusal must be a JSON envelope, not prose: prose is what the router cannot
        // recognise, and it relabels the whole thing `channels_exhausted`.
        try #require(
            JSONSerialization.jsonObject(
                with: Data(await refusalMessage(windowCount: windowCount).utf8)
            ) as? [String: Any]
        )
    }

    @Test("it is a State C envelope the router can surface verbatim")
    func refusalIsAnEnvelope() async throws {
        let envelope = try await refusalEnvelope(windowCount: 2)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(envelope["error"] as? String == "unsupported_state")
        // The router only bypasses the `channels_exhausted` wrapper for a string it recognises as a
        // State C envelope, so this is the property that keeps the classification honest.
        #expect(HonestContract.stateCErrorCode(await refusalMessage(windowCount: 2)) != nil)
    }

    @Test("it names the precondition and the observed state, not another product")
    func refusalNamesThePrecondition() async throws {
        let envelope = try await refusalEnvelope(windowCount: 2)
        let hint = try #require(envelope["hint"] as? String)
        // The operator is not necessarily running Creator Studio; the refusal must describe THEIR
        // Logic, not a product they may never have installed.
        #expect(!hint.contains("Creator Studio"))
        #expect(hint.contains("no open document"))
        #expect(envelope["observed_window_count"] as? Int == 2)
        #expect(envelope["failure_stage"] as? String == "precondition_open_document")
    }

    @Test("nothing was attempted, and it says so")
    func refusalIsPreWrite() async throws {
        let envelope = try await refusalEnvelope(windowCount: 1)
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        let retryable = try #require(envelope["safe_to_retry"] as? Bool)
        #expect(retryable)
        // The recovery action was driven end to end before being written down. `project.close`
        // on its own answers `confirmation_required`, so naming the bare command would have sent
        // the operator into a second refusal — the confirmation has to be in the instruction.
        let recovery = try #require(envelope["recovery_action"] as? String)
        #expect(recovery.contains("close"))
        #expect(recovery.contains("confirmed: true"))
    }
}
