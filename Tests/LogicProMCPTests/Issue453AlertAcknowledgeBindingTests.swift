@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #453 — the classifier's decision must survive to the click
//
// `ModalReconciliation.classify` treats a top-level `AXDialog` as safe to
// acknowledge only when it carries EXACTLY ONE titled button; two or more means
// a choice, and choices are never auto-answered.
//
// That decision used not to reach the click. The executor re-resolved `first
// window whose subrole is "AXDialog"` in AppleScript, so a dialog that arrived
// between classification and click was clicked though it was never classified,
// and a failed title lookup fell through to `click button 1` with no count check
// at all — on that path the safety discriminator did not participate.
//
// The fix binds the click to the classified ELEMENT and re-checks the count from
// that element immediately before pressing. These tests drive the real
// `reconcilePreflight` entry point against a fake AX tree, and the AX tree is
// allowed to CHANGE between the classify read and the click read — which is the
// only way to exercise the window the old code left open.
//
// Both directions are locked. A gate that never acknowledges would be as wrong
// as one that always does: a genuine single-button alert would then block the
// server forever, so the success path is asserted too, along with WHICH element
// was pressed.

/// A value that changes between AX reads, switched at a CALIBRATED boundary.
///
/// The point of these tests is the gap between the classify read and the click
/// read, so the fixture has to flip state exactly once, after classification and
/// before the executor looks. How many AX reads classification performs is an
/// implementation detail — `mainWindow`, the dialog filter and the button scan
/// each read — so hard-coding "switch after the first read" encodes a guess that
/// silently rots the moment a read is added or removed, and a stale guess makes
/// the test pass for the wrong reason.
///
/// Instead the fixture runs a calibration pass first, counts the reads
/// classification actually performs, and switches immediately after that count.
private final class PhasedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var switchAfter: Int?
    private let before: T
    private let after: T

    init(before: T, after: T) {
        self.before = before
        self.after = after
    }

    func next() -> T {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        guard let switchAfter else { return before }
        return reads > switchAfter ? after : before
    }

    /// Freeze the current read count as the switch boundary and rewind, so the
    /// measured run starts from zero with the boundary set where classification
    /// actually ended.
    func calibrate() {
        lock.lock()
        defer { lock.unlock() }
        switchAfter = reads
        reads = 0
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var boundary: Int {
        lock.lock()
        defer { lock.unlock() }
        return switchAfter ?? 0
    }
}

private final class AlertDismissal: @unchecked Sendable {
    private let lock = NSLock()
    private var dismissed = false

    func markDismissed() {
        lock.lock()
        dismissed = true
        lock.unlock()
    }

    func isDismissed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return dismissed
    }
}

private struct AlertFixture {
    let builder: FakeAXRuntimeBuilder
    let runtime: AXLogicProElements.Runtime
    let buttonIDs: [Int]
    let windows: PhasedValue<[AXUIElement]>
    let dialogChildren: PhasedValue<[AXUIElement]>
    let buttonTitle: PhasedValue<String>

    var pressedElementIDs: [Int] {
        builder.actionCalls.filter { $0.action == (kAXPressAction as String) }.map(\.elementID)
    }
}

/// Build a Logic app root with a readable sheet host plus a top-level dialog.
/// A clean read now requires the main window even when the actionable blocker
/// is an alert, so this fixture models the ordinary arrange+dialog topology.
private func makeAlertFixture(
    initialButtonTitles: [String],
    laterButtonTitles: [String]? = nil,
    reuseInitialButtonForLaterTitle: Bool = false,
    replaceDialogAfterClassification: Bool = false,
    removeDialogAfterClassification: Bool = false,
    pressSucceeds: Bool = true,
    dismissesWhenAccepted: Bool = true,
    disappearsWhenRejected: Bool = false
) -> AlertFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let dialog = builder.element(2)
    let otherDialog = builder.element(3)
    let arrange = builder.element(4)

    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXModalAttribute as String, false)
    builder.setAttribute(dialog, kAXModalAttribute as String, true)
    builder.setAttribute(otherDialog, kAXModalAttribute as String, true)
    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(otherDialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)

    var buttonIDs: [Int] = []
    func buttons(_ titles: [String], startingAt base: Int) -> [AXUIElement] {
        titles.enumerated().map { offset, title in
            let button = builder.element(base + offset)
            builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(button, kAXTitleAttribute as String, title)
            buttonIDs.append(builder.elementID(button))
            return button
        }
    }

    let initialButtons = buttons(initialButtonTitles, startingAt: 100)
    builder.setChildren(dialog, initialButtons)
    // The substitute dialog is itself a legitimate single-button alert. If only
    // the button count were re-checked it would be acknowledged happily, so this
    // is what forces the identity check to carry the test.
    builder.setChildren(otherDialog, buttons(["OK"], startingAt: 200))

    let laterWindows: [AXUIElement]
    if removeDialogAfterClassification {
        laterWindows = [arrange]
    } else if replaceDialogAfterClassification {
        laterWindows = [arrange, otherDialog]
    } else {
        laterWindows = [arrange, dialog]
    }
    let windows = PhasedValue(before: [arrange, dialog], after: laterWindows)
    let dismissal = AlertDismissal()
    let dialogChildren = PhasedValue(
        before: initialButtons,
        after: reuseInitialButtonForLaterTitle
            ? initialButtons
            : laterButtonTitles.map { buttons($0, startingAt: 300) } ?? initialButtons
    )
    let buttonTitle = PhasedValue(
        before: initialButtonTitles.first ?? "",
        after: laterButtonTitles?.first ?? initialButtonTitles.first ?? ""
    )

    // `nil` means "not handled, fall through to the builder"; `.some(x)` means
    // "handled, here is x" — the double optional is load-bearing.
    let windowsHandler: (@Sendable (AXUIElement, String) -> AnyObject??) = { element, attribute in
        guard attribute == (kAXWindowsAttribute as String), CFEqual(element, app) else { return nil }
        if dismissal.isDismissed() {
            return AnyObject??.some([] as NSArray)
        }
        let list: [AXUIElement] = windows.next()
        return AnyObject??.some(list as AnyObject)
    }

    let base = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: windowsHandler,
        setAttributeHandler: nil,
        performActionHandler: nil
    )
    let dynamicTitle: (@Sendable (AXUIElement, String) -> AnyObject??) = { element, attribute in
        guard reuseInitialButtonForLaterTitle,
              initialButtons.count == 1,
              CFEqual(element, initialButtons[0]),
              attribute == (kAXTitleAttribute as String)
        else { return nil }
        return .some(buttonTitle.next() as NSString)
    }
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { 4242 },
        ax: AXHelpers.Runtime(
            axApp: base.ax.axApp,
            attributeValue: { element, attribute in
                if let title = dynamicTitle(element, attribute) { return title }
                return base.ax.attributeValue(element, attribute)
            },
            setAttributeValue: base.ax.setAttributeValue,
            children: { element in
                CFEqual(element, dialog) ? dialogChildren.next() : base.ax.children(element)
            },
            performAction: { element, action in
                let isClassifiedButton = action == (kAXPressAction as String)
                    && initialButtons.contains(where: { CFEqual($0, element) })
                guard pressSucceeds else {
                    if isClassifiedButton, disappearsWhenRejected {
                        dismissal.markDismissed()
                    }
                    return false
                }
                let accepted = base.ax.performAction(element, action)
                if accepted, isClassifiedButton, dismissesWhenAccepted {
                    dismissal.markDismissed()
                }
                return accepted
            },
            childCount: base.ax.childCount,
            childrenResult: { element in
                if CFEqual(element, dialog) {
                    return .success(dialogChildren.next())
                }
                return base.ax.childrenResult!(element)
            },
            attributeValueResult: { element, attribute in
                if let title = dynamicTitle(element, attribute) { return .success(title) }
                if dismissal.isDismissed(),
                   CFEqual(element, dialog),
                   attribute == (kAXModalAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
                }
                return base.ax.attributeValueResult!(element, attribute)
            },
            performActionResult: base.ax.performActionResult
        ),
        executeAppleScript: base.executeAppleScript
    )

    // Calibration pass: read-only, presses nothing, and establishes exactly where
    // classification stops so the flip lands in the gap the executor must survive.
    _ = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
    windows.calibrate()
    dialogChildren.calibrate()
    buttonTitle.calibrate()

    return AlertFixture(
        builder: builder,
        runtime: runtime,
        buttonIDs: buttonIDs,
        windows: windows,
        dialogChildren: dialogChildren,
        buttonTitle: buttonTitle
    )
}

@Suite("Issue #453 — alert acknowledgement binds to the classified dialog")
struct Issue453AlertAcknowledgeBindingTests {
    /// The gate must release, or a real single-button alert blocks the server.
    @Test("a stable single-button alert is acknowledged by pressing that button")
    func stableSingleButtonAlertIsAcknowledged() async {
        let fixture = makeAlertFixture(initialButtonTitles: ["OK"])

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `informational-alert-axmodal-omission`: ignore AXModal in
        // the complete scan. This genuine single-button alert would not reach
        // its classifier-bound acknowledgement path.
        #expect(outcome.kind == .informationalAlert)
        #expect(outcome.decision == .acknowledgeAlert)
        // Mutation `alert-close-causation`: restore the old accepted-press plus
        // gone-witness `performed` conjunction. The bound alert may disappear
        // because of another actor, so this receipt reports observations only.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
        #expect(outcome.refusal == nil)

        #expect(fixture.pressedElementIDs.count == 1, "exactly one control may be actuated")
        #expect(
            fixture.pressedElementIDs.first == fixture.buttonIDs.first,
            "the press must land on the classified dialog's own button"
        )
    }

    @Test("an accepted alert press with a persistent alert is not performed")
    func acceptedPersistentAlertIsNotPerformed() async {
        let fixture = makeAlertFixture(
            initialButtonTitles: ["OK"],
            dismissesWhenAccepted: false
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(
            !outcome.performed,
            "Mutation caught: replace `result.pressed && summary.observedGone` with `result.pressed`; an accepted press while the alert persists would become performed."
        )
    }

    @Test("a rejected alert press with a gone alert is not performed")
    func rejectedGoneAlertIsNotPerformed() async {
        let fixture = makeAlertFixture(
            initialButtonTitles: ["OK"],
            pressSucceeds: false,
            disappearsWhenRejected: true
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(
            !outcome.performed,
            "Mutation caught: remove `result.pressed &&` and use only `summary.observedGone`; a rejected press with an independently gone alert would become performed."
        )
    }

    /// The regression: a different dialog came forward between classify and click.
    /// The substitute here is itself a valid single-button alert, so only an
    /// identity check can reject it — a count check alone would wave it through.
    @Test("a dialog swapped in after classification is not clicked")
    func replacedDialogIsRefused() async {
        let fixture = makeAlertFixture(
            initialButtonTitles: ["OK"],
            replaceDialogAfterClassification: true
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(outcome.decision == .acknowledgeAlert, "the classifier still authorized the action")
        #expect(!outcome.performed)
        #expect(outcome.refusal == .targetChanged)
        #expect(
            fixture.pressedElementIDs.isEmpty,
            "no control may be actuated on a dialog that was never classified"
        )
        #expect(
            fixture.windows.readCount > fixture.windows.boundary,
            "the executor must re-read past the calibrated classification boundary, or the swap never reached it"
        )
    }

    /// A dialog that closed itself between the two reads must not be chased.
    @Test("an alert that disappears after classification is not clicked")
    func vanishedDialogIsRefused() async {
        let fixture = makeAlertFixture(
            initialButtonTitles: ["OK"],
            removeDialogAfterClassification: true
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(!outcome.performed)
        #expect(outcome.refusal == .targetGone)
        #expect(fixture.pressedElementIDs.isEmpty)
    }

    /// The sharpest case: the SAME dialog grows a second button after being
    /// classified as single-button. It is now a choice, and the old executor
    /// would have clicked it anyway through the `click button 1` fallback.
    @Test("a dialog that gains a second button after classification is not clicked")
    func buttonCountGrowthIsRefused() async {
        let fixture = makeAlertFixture(
            initialButtonTitles: ["OK"],
            laterButtonTitles: ["Save", "Don't Save"]
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(outcome.decision == .acknowledgeAlert)
        #expect(!outcome.performed)
        #expect(outcome.refusal == .buttonCountChanged)
        #expect(
            fixture.pressedElementIDs.isEmpty,
            "a two-button dialog is a choice and must never be answered automatically"
        )
    }

    /// A count-only recheck is insufficient: a single harmless button can be
    /// relabelled to a destructive action while retaining both its dialog and
    /// one-button shape. The live button must still be the identity and title
    /// that produced `topLevelAlertPrimaryButton` during classification.
    @Test("a single alert button whose title changes after classification is not clicked")
    func buttonTitleChangeIsRefused() async {
        let fixture = makeAlertFixture(
            initialButtonTitles: ["OK"],
            laterButtonTitles: ["Don't Save"],
            reuseInitialButtonForLaterTitle: true
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `alert-button-title-identity-omission`: remove the title
        // comparison from the identity guard. The re-read still has exactly one
        // button, so the unchecked executor presses the new Don't Save action.
        #expect(outcome.refusal == .targetChanged)
        #expect(fixture.pressedElementIDs.isEmpty)
        #expect(
            fixture.dialogChildren.readCount > fixture.dialogChildren.boundary,
            "the title-switch seam must be read after classification before this refusal is trusted"
        )
        #expect(
            fixture.buttonTitle.readCount > fixture.buttonTitle.boundary,
            "the same button's title must be re-read across the calibrated switch"
        )
    }

    /// A dialog whose buttons all vanished is equally unactionable — zero is not
    /// one, and "press whatever is left" is the failure mode being removed.
    @Test("a dialog left with no titled button is not clicked")
    func zeroButtonsIsRefused() async {
        let fixture = makeAlertFixture(
            initialButtonTitles: ["OK"],
            laterButtonTitles: []
        )

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(!outcome.performed)
        #expect(outcome.refusal == .buttonCountChanged)
        #expect(fixture.pressedElementIDs.isEmpty)
    }

    /// A press that the AX layer rejects is reported as a refusal, not silently
    /// counted as success — the alert is still on screen either way.
    @Test("a failed press is reported rather than claimed")
    func failedPressIsReported() async {
        let fixture = makeAlertFixture(initialButtonTitles: ["OK"], pressSucceeds: false)

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(!outcome.performed)
        #expect(outcome.refusal == .pressFailed)
    }

    /// Refusal reasons travel into operation extras and logs, so they must be
    /// fixed structural tokens. A reason carrying dialog text or a button title
    /// would publish UI content the server is not allowed to emit.
    @Test("refusal reasons carry no dialog or button content")
    func refusalReasonsAreStructuralOnly() {
        let reasons: [AccessibilityChannel.AlertAcknowledgeRefusal] = [
            .targetUnavailable, .targetGone, .targetChanged, .buttonCountChanged, .pressFailed,
        ]
        #expect(Set(reasons.map(\.rawValue)).count == reasons.count, "reasons must be distinguishable")
        for reason in reasons {
            #expect(reason.rawValue.hasPrefix("alert_"))
            #expect(reason.rawValue.allSatisfy { $0.isLowercase || $0 == "_" })
        }
    }

    /// The refusal has to reach the envelope; a value recorded but never merged
    /// would leave the caller unable to tell a declined click from no click.
    @Test("a refusal is merged into operation extras")
    func refusalReachesExtras() {
        var extras: [String: Any] = [:]
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .informationalAlert,
            action: AccessibilityChannel.reconcileActionLabel(.acknowledgeAlert),
            newTrackAutoConfirmed: false,
            refusal: .targetChanged
        )
        #expect(extras["reconcile_refused"] as? String == "alert_target_changed")

        var clean: [String: Any] = [:]
        AccessibilityChannel.mergeReconcileExtras(
            &clean,
            kind: .informationalAlert,
            action: AccessibilityChannel.reconcileActionLabel(.acknowledgeAlert),
            newTrackAutoConfirmed: false
        )
        #expect(clean["reconcile_refused"] == nil, "a clean acknowledgement must not report a refusal")
    }
}
