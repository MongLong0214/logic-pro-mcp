import ApplicationServices
import AppKit
import Foundation

/// Project/document surface: project info, Save As via AX dialog, and marker reads.
extension AccessibilityChannel {
    // MARK: - Creator Studio New Project chooser

    static func blankApplicationCanRevealChooser(windowCount: Int?) -> Bool {
        windowCount == 0
    }

    /// How many of Logic's windows are DOCUMENTS, which is what the open-document precondition is
    /// really asking about (#590).
    ///
    /// A freshly launched Logic shows "Choose a Project". Counting raw windows made that chooser an
    /// open document, so `project.new` refused from the exact state Logic lands in at launch — the
    /// state every first-time caller is in, needing no unusual configuration at all. The classifier
    /// this needs already existed and is already used by `getTrackHeaders` for the same reason.
    ///
    /// The precondition's own reasoning is untouched and still sound: with a real document open, a
    /// newly created project's window cannot be told apart from the ones already on screen. A
    /// chooser does not create that ambiguity — it is titled, it is not a project, and driving
    /// File > New with it still on screen was measured to create the project anyway.
    static func documentWindowCount(
        _ windows: [AXUIElement]?,
        runtime: AXLogicProElements.Runtime
    ) -> Int? {
        guard let windows else { return nil }
        return windows.filter { !isPositivelyTheProjectChooser($0, runtime: runtime) }.count
    }

    /// A window is excluded from the document count only when BOTH signals say chooser.
    ///
    /// The title alone is not safe in the direction that matters. `isProjectPickerWindow` matches
    /// the title by CONTAINMENT, so a real project the user named "Choose a Project" produces the
    /// arrange window "Choose a Project - Tracks" and would stop being counted — and then
    /// `project.new` would proceed with a genuine document open, which is the ambiguity the
    /// precondition exists to prevent. The old defect refused too often; a fix that accepts too
    /// often is worse.
    ///
    /// So the title is paired with a structural signal. Measured on Logic Pro 12.3:
    ///
    ///     [Untitled 56 - Tracks]  AXDocument = file:///…/Untitled%2056.logicx/
    ///     [Choose a Project]      AXDocument = missing value
    ///
    /// A document window carries `AXDocument`; the chooser does not. Every uncertain case falls to
    /// "this is a document": an unreadable title, an unreadable `AXDocument`, or a title that does
    /// not match all count as documents, so a failure to identify the chooser costs a refusal rather
    /// than an ambiguous creation.
    static func isPositivelyTheProjectChooser(
        _ window: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard AXLogicProElements.isProjectPickerWindow(window, runtime: runtime) else { return false }
        let document: String? = AXHelpers.getAttribute(
            window, kAXDocumentAttribute as String, runtime: runtime.ax
        )
        return document == nil
    }

    static func createEmptyProjectFromQualifiedState(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        if exactEmptyProjectChooserIsVisible(runtime: runtime) {
            return await createEmptyProjectFromChooser(runtime: runtime)
        }

        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .logicNotRunning,
                hint: "Logic Pro's accessibility root is unavailable, so no project could be created.",
                extras: ["operation": "project.new", "write_attempted": false]
            ))
        }
        let windows: [AXUIElement]? = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        )
        let documentWindows = documentWindowCount(windows, runtime: runtime)
        guard blankApplicationCanRevealChooser(windowCount: documentWindows) else {
            // A DESIGNED precondition, not a failure to try: with a document already open, a second
            // project's window cannot be told apart from the ones already on screen, so this route
            // refuses rather than certify an ambiguous creation
            // (`Issue516DirectProjectCreationTests.onlyFromZeroWindows`).
            //
            // What it used to say was "Creator Studio has a non-chooser window" — a claim about a
            // product the operator is probably not running (measured on desktop Logic Pro 12.3,
            // 2026-08-17), delivered as bare prose that the router could not recognise as a State C
            // envelope and therefore relabelled `channels_exhausted`. That code means "every channel
            // in the chain reported itself unavailable"; here the one channel ran and declined on
            // purpose. Two false statements about the caller's situation, in one refusal.
            let count = documentWindows
            var extras: [String: Any] = [
                "operation": "project.new",
                "write_attempted": false,
                "safe_to_retry": true,
                "failure_stage": "precondition_open_document",
                // Both numbers, so a reader can see that a chooser on screen was NOT the reason
                // (#590). When they differ, the difference is chooser windows.
                "observed_all_window_count": windows?.count ?? NSNull(),
                // Driven end to end on 2026-08-17 before being written down. `project.close` alone
                // answers `confirmation_required` (it is L3-gated), so a recovery action naming the
                // bare command would send the operator into a second refusal. With the confirmation
                // supplied the chain does work: close -> zero windows -> project.new creates
                // `Untitled 56 - Tracks`.
                "recovery_action": "Close the open project with "
                    + "logic_project(\"close\", {confirmed: true}) — the bare close is refused as "
                    + "confirmation_required — so Logic has no document window, then retry "
                    + "project.new.",
            ]
            if let count { extras["observed_window_count"] = count }
            return .error(HonestContract.encodeStateC(
                error: .unsupportedState,
                hint: count.map {
                    "project.new requires Logic to have no open document; \($0) window(s) are open. "
                        + "With a document already open a newly created project cannot be told apart "
                        + "from the windows already on screen, so nothing was attempted."
                } ?? "project.new could not read Logic's window list, so it cannot establish that no "
                    + "document is open; nothing was attempted.",
                extras: extras
            ))
        }

        // Drive the menu through AX with locale-resolved titles instead of an AppleScript that
        // names the English menu. Measured on a Korean Logic: the bar item is `파일` and the entry is
        // `신규`, so the previous script returned EXACT_NEW_NOT_FOUND and project.new failed in 2.8 s
        // without ever reaching either creation branch (#519). This also drops the System Events
        // dependency, which needs its own Automation grant and raises a prompt this process cannot
        // dismiss.
        guard let menuBarAny = AXHelpers.getAttribute(app, "AXMenuBar", runtime: runtime.ax) as AXUIElement?,
              let fileItem = AXLocalePolicy.findMenuBarItem(
                  in: menuBarAny, matching: AXLocalePolicy.fileMenuBar, runtime: runtime.ax
              )
        else {
            // A locale gap is a missing target, not an exhausted channel chain. As bare prose these
            // two were relabelled `channels_exhausted`, which tells the operator to look at channel
            // health when what is actually missing is a measured label for their language.
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "The File menu could not be resolved in this Logic's language. Measured names: "
                    + AXLocalePolicy.fileMenuBar.labels.joined(separator: ", ") + ".",
                extras: [
                    "operation": "project.new",
                    "write_attempted": false,
                    "failure_stage": "file_menu_resolution",
                    "known_labels": AXLocalePolicy.fileMenuBar.labels,
                ]
            ))
        }
        guard let newItem = AXLocalePolicy.findMenuItem(
            under: fileItem, matching: AXLocalePolicy.newProjectMenuItem, runtime: runtime.ax
        ) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "The New entry under the File menu could not be resolved in this Logic's "
                    + "language. Measured names: "
                    + AXLocalePolicy.newProjectMenuItem.labels.joined(separator: ", ") + ".",
                extras: [
                    "operation": "project.new",
                    "write_attempted": false,
                    "failure_stage": "new_menu_item_resolution",
                    "known_labels": AXLocalePolicy.newProjectMenuItem.labels,
                ]
            ))
        }
        // Press the bar item first so the menu materialises, then the entry. The return codes are
        // not consulted: on Logic 12.3 a press that works can still report failure, so the observed
        // window below is the only thing that decides.
        _ = AXHelpers.performAction(fileItem, kAXPressAction as String, runtime: runtime.ax)
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = AXHelpers.performAction(newItem, kAXPickAction as String, runtime: runtime.ax)

        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if exactEmptyProjectChooserIsVisible(runtime: runtime) {
                return await createEmptyProjectFromChooser(runtime: runtime)
            }
            // Logic does not always answer File > New with the chooser. Where the chooser is skipped
            // it creates the untitled project immediately and presents only the mandatory New Track
            // sheet — measured live: the arrange window read "Untitled 56 - Tracks" while this loop
            // was still waiting for a chooser that was never coming, and the operation then reported
            // failure for a project it had just created. A created project IS the requested outcome,
            // so accept it here rather than timing out beside it.
            if exactCreatedProjectWindow(runtime: runtime) != nil {
                return await observeProjectCreationOutcome(runtime: runtime, selection: "direct")
            }
        }
        return .error(
            "Exact File > New exposed neither the Creator Studio chooser nor a created project window"
        )
    }

    static func exactEmptyProjectChooserIsVisible(
        runtime: AXLogicProElements.Runtime = .production
    ) -> Bool {
        exactEmptyProjectChooserWindow(runtime: runtime) != nil
    }

    private static func exactEmptyProjectChooserWindow(
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        let enumerated: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        let candidates: [AXUIElement]
        if enumerated.isEmpty,
           let main: AXUIElement = AXHelpers.getAttribute(
               app, kAXMainWindowAttribute as String, runtime: runtime.ax
           ) {
            candidates = [main]
        } else {
            // The Creator Studio chooser can be exposed as a dialog. The
            // generic mainWindow helper intentionally excludes dialogs to
            // protect arrange reads, so this chooser-only classifier must
            // inspect every AX window and still require one exact match.
            candidates = enumerated
        }
        let matches = candidates.filter { window in
            let emptyProjectLabels = AXHelpers.findAllDescendants(
                of: window, role: kAXStaticTextRole as String, maxDepth: 12, runtime: runtime.ax
            ).filter {
                let value = AXHelpers.getValue($0, runtime: runtime.ax) as? String
                return isExactEmptyProjectLabel(
                    title: AXHelpers.getTitle($0, runtime: runtime.ax), value: value
                )
            }
            let chooseButtons = AXHelpers.findAllDescendants(
                of: window, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
            ).filter { AXHelpers.getTitle($0, runtime: runtime.ax) == "Choose" }
            let chooseEnabled: Bool = chooseButtons.first.flatMap {
                AXHelpers.getAttribute($0, kAXEnabledAttribute as String, runtime: runtime.ax)
            } ?? false
            return chooserSelectionIsUnambiguous(
                windowTitle: AXHelpers.getTitle(window, runtime: runtime.ax),
                emptyProjectLabelCount: emptyProjectLabels.count,
                chooseButtonCount: chooseButtons.count,
                chooseEnabled: chooseEnabled
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func chooserSelectionIsUnambiguous(
        windowTitle: String?,
        emptyProjectLabelCount: Int,
        chooseButtonCount: Int,
        chooseEnabled: Bool
    ) -> Bool {
        windowTitle == "Choose a Project"
            && emptyProjectLabelCount == 1
            && chooseButtonCount == 1
            && chooseEnabled
    }

    static func isExactEmptyProjectLabel(title: String?, value: String?) -> Bool {
        title == "Empty Project" || value == "Empty Project"
    }

    static func isCreatedProjectWindowTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The suffix is localized. Measured live: `Untitled 55 - Tracks` in English,
        // `Untitled 55 - 트랙` in Korean. Hard-coding the English form made project.new report
        // failure for a project it had just created on every non-English Logic.
        for label in AXLocalePolicy.arrangeWindowTitleSuffix.labels {
            let suffix = " - " + label
            if normalized.hasSuffix(suffix), normalized.count > suffix.count {
                return true
            }
        }
        return false
    }

    static func createdProjectWindowSelectionIsUnambiguous(
        windowTitle: String?,
        windowRole: String?,
        windowSubrole: String?
    ) -> Bool {
        windowRole == (kAXWindowRole as String)
            && windowSubrole == (kAXStandardWindowSubrole as String)
            && isCreatedProjectWindowTitle(windowTitle)
    }

    /// A mandatory sheet disappearing is an input to verification, not a fact
    /// about the Project. Only a subsequent positive track-count observation
    /// permits the response to say that the mandatory track was created.
    static func mandatoryTrackCreationWasObserved(
        sheetGoneObserved: Bool,
        observedTrackCount: Int
    ) -> Bool {
        sheetGoneObserved && observedTrackCount > 0
    }

    private static func exactCreatedProjectWindow(
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        var candidates: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        if candidates.isEmpty,
           let main: AXUIElement = AXHelpers.getAttribute(
               app, kAXMainWindowAttribute as String, runtime: runtime.ax
           ) {
            candidates = [main]
        }
        let matches = candidates.filter { window in
            createdProjectWindowSelectionIsUnambiguous(
                windowTitle: AXHelpers.getTitle(window, runtime: runtime.ax),
                windowRole: AXHelpers.getRole(window, runtime: runtime.ax),
                windowSubrole: AXHelpers.getAttribute(
                    window, kAXSubroleAttribute as String, runtime: runtime.ax
                )
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// `nil` means `AXWindows` was never successfully read — a non-array
    /// payload or a failed call — and that is not the same fact as "the app
    /// currently vends zero windows". Collapsing the two into `[]` made a
    /// pending-project receipt claim an empty window list when the read
    /// simply never happened.
    private static func observedWindowTitles(
        runtime: AXLogicProElements.Runtime
    ) -> [String]? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        switch AXHelpers.getAXUIElementArrayRead(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) {
        case .success(.elements(let windows)):
            return windows.compactMap { AXHelpers.getTitle($0, runtime: runtime.ax) }
        case .success(.absent):
            // A successful absent value is a legitimate zero-windows answer
            // for this best-effort receipt field.
            return []
        case .success(.malformed), .failure:
            return nil
        }
    }

    static func projectNewPendingReadbackEnvelope(
        mandatoryTrackCreated: Bool,
        observedWindowTitles: [String]?,
        observationBudgetMs: Int,
        witnessSummary: ModalReconcileWitnessSummary? = nil,
        modalUnreadableReason: ModalReadFailure? = nil,
        modalSheetScanFailureDetail: ModalSheetScanFailureDetail? = nil
    ) -> String {
        var extras: [String: Any] = [
            "operation": "project.new",
            "method": "accessibility",
            "selection": "Empty Project",
            "phase": "created_project_window_pending",
            "mandatory_track_created": mandatoryTrackCreated,
            "observation_budget_ms": observationBudgetMs,
            "write_attempted": true,
            "safe_to_retry": false,
        ]
        if let observedWindowTitles {
            extras["observed_window_titles"] = observedWindowTitles
        } else {
            // The window list was never successfully read. Say so explicitly
            // rather than omitting it silently, so this is distinguishable
            // from a caller who simply forgot to check for the key.
            extras["observed_window_titles_unread"] = true
        }
        if let witnessSummary {
            extras["modal_reconciliation_witness"] = witnessSummary.envelopeValue
        }
        if let modalUnreadableReason {
            // This is an incomplete observation, not a discovered unknown
            // sheet. Reissuing project.new remains unsafe after its write
            // boundary, but the bounded observer retried this read throughout
            // its budget.
            extras["modal_observation"] = "incomplete"
            modalUnreadableReason.apply(to: &extras)
            // See mergeReconcileExtras: a sheet-scan failure carrying no companion detail says so
            // rather than omitting the field, because an omitted field reads as "no unreadable node".
            if let modalSheetScanFailureDetail {
                extras["reconciled_modal_unreadable_node"] = modalSheetScanFailureDetail.envelopeValue
            } else if modalUnreadableReason.originatesInSheetScan {
                extras["reconciled_modal_unreadable_node"] = ModalSheetScanFailureDetail.unrecordedEnvelopeValue
            }
        }
        return HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: extras
        )
    }

    static func createEmptyProjectFromChooser(
        runtime: AXLogicProElements.Runtime = .production,
        observationAttempts: Int = 80,
        observationDelayNanoseconds: UInt64 = 250_000_000
    ) async -> ChannelResult {
        guard let window = exactEmptyProjectChooserWindow(runtime: runtime) else {
            return .error("Creator Studio project chooser is not visible")
        }
        let chooseButtons = AXHelpers.findAllDescendants(
            of: window, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter { AXHelpers.getTitle($0, runtime: runtime.ax) == "Choose" }
        let chooseEnabled: Bool = chooseButtons.first.flatMap {
            AXHelpers.getAttribute($0, kAXEnabledAttribute as String, runtime: runtime.ax)
        } ?? false

        guard chooseButtons.count == 1, chooseEnabled, let chooseButton = chooseButtons.first else {
            return .error("Creator Studio chooser is not the exact enabled Empty Project selection")
        }
        guard AXHelpers.performAction(chooseButton, kAXPressAction as String, runtime: runtime.ax) else {
            return .error("Failed to press the exact Creator Studio Choose button")
        }
        return await observeProjectCreationOutcome(
            runtime: runtime,
            selection: "Empty Project",
            observationAttempts: observationAttempts,
            observationDelayNanoseconds: observationDelayNanoseconds
        )
    }

    /// Watch for the project a `project.new` was asked to create, from whichever route produced it.
    ///
    /// Split out of `createEmptyProjectFromChooser` so the direct-creation route can reuse it. Logic
    /// does not always answer `File ▸ New` with the template chooser: on a machine where the chooser
    /// is skipped it creates the untitled project immediately and presents only the mandatory New
    /// Track sheet. That is the SAME outcome the chooser route reaches one step later, and it needs
    /// the same handling — the sheet reconciliation, the arrange-window witness, and the honest
    /// State B that leaves the independent Project-resource readback to the caller.
    static func observeProjectCreationOutcome(
        runtime: AXLogicProElements.Runtime,
        selection: String,
        observationAttempts: Int = 80,
        observationDelayNanoseconds: UInt64 = 250_000_000
    ) async -> ChannelResult {
        // Some Creator Studio builds open a zero-track Project directly, while
        // others expose Logic's mandatory New Track sheet. Reuse the existing
        // structural classifier for the sheet path: it only clicks Create when
        // the sheet is identified as mandatoryNewTrack; unknown sheets fail
        // closed. In either path, an exact English arrange-window title is the
        // bounded AX witness that the exact Empty Project selection completed.
        // The caller still performs independent Project-resource readback
        // before saving.
        // A stale bound-sheet reference does not establish project causation.
        // Keep the sheet-disappearance observation separate until a subsequent
        // AX track count positively observes the mandatory track.
        var mandatoryTrackSheetGone = false
        var createdTrack = false
        var witnessSummary: ModalReconcileWitnessSummary?
        // A mandatory New Track description can arrive before its Create
        // control is published. Keep polling in that state, but once a direct
        // Create press has been issued, do not press that modal kind again.
        // Subsequent passes are observations only; this preserves the
        // per-modal-kind action latch while leaving the delayed-control path
        // a chance to become actionable.
        var mandatoryTrackCreateActionAttempted = false
        var mandatoryTrackCreateActionFailure: AXHelpers.AXActionError?
        var lastModalUnreadableReason: ModalReadFailure?
        // #549: mirrors `lastModalUnreadableReason` at every site that sets/
        // clears it, so the unknown-sheet envelope below can also name the
        // exact node/scan behind the failure.
        var lastModalSheetScanFailureDetail: ModalSheetScanFailureDetail?
        let attempts = max(1, observationAttempts)
        for attempt in 0..<attempts {
            try? await Task.sleep(nanoseconds: observationDelayNanoseconds)
            let outcome: ModalReconcileOutcome
            if mandatoryTrackCreateActionAttempted {
                outcome = observeModalAfterMutation(isDeleteContext: false, runtime: runtime)
            } else {
                outcome = await reconcileAfterMutation(isDeleteContext: false, runtime: runtime)
            }

            // A no-modal classifier result is clean only when all modal sources
            // were readable. In particular, a failed auxiliary sheet-host scan
            // must poll again rather than becoming an invented `unknownSheet` or
            // allowing the project-window path to certify a clean blocker set.
            if !outcome.modalObservationIsComplete {
                if let unreadableReason = outcome.unreadableReason {
                    lastModalUnreadableReason = unreadableReason
                    lastModalSheetScanFailureDetail = outcome.sheetScanFailureDetail
                }
                continue
            }
            // Do not carry a transient, already-resolved scan failure into a
            // later complete observation's final envelope.
            lastModalUnreadableReason = nil
            lastModalSheetScanFailureDetail = nil

            switch outcome.kind {
            case .mandatoryNewTrack:
                if let observedWitnessSummary = outcome.witnessSummary {
                    witnessSummary = observedWitnessSummary
                }
                if let actionFailure = outcome.actionFailure {
                    mandatoryTrackCreateActionFailure = actionFailure
                }
                if outcome.actionAttempted {
                    mandatoryTrackCreateActionAttempted = true
                }
                // Two facts, and neither alone is the conclusion. `observedGone` says the sheet THIS
                // run captured is gone — an invalidated element is the only signal macOS gives for a
                // destroyed one. `blockerSetClear` says no blocker is present NOW, which a scan can
                // report without ever having seen our sheet leave. Latching on the second alone
                // certifies a dismissal this run cannot attribute to itself; latching on the first
                // alone ignores a different sheet that arrived in its place.
                if outcome.witnessSummary?.observedGone == true
                    && outcome.witnessSummary?.blockerSetClear == true {
                    mandatoryTrackSheetGone = true
                } else if attempt + 1 == attempts {
                    var extras: [String: Any] = [
                        "operation": "project.new",
                        "method": "accessibility",
                        "selection": selection,
                        "phase": "mandatory_track_create_unconfirmed",
                        "write_attempted": true,
                        "safe_to_retry": false,
                    ]
                    if let witnessSummary {
                        extras["modal_reconciliation_witness"] = witnessSummary.envelopeValue
                    }
                    if let actionFailure = mandatoryTrackCreateActionFailure {
                        extras["reconcile_action_error"] = actionFailure.diagnosticLabel
                    }
                    return .error(HonestContract.encodeStateB(
                        reason: .readbackUnavailable,
                        extras: extras
                    ))
                } else {
                    // This poll's own classification just read `.mandatoryNewTrack` — a blocker is
                    // present RIGHT NOW, whether it is the same sheet still lingering or a genuine
                    // replacement. A latch set by an EARLIER poll's gone+clear pair is a memory, not
                    // an observation, and it cannot outrank what this poll just saw. Reset it so the
                    // fallthrough below never certifies a live blocker as absent; only a poll that
                    // itself proves gone+clear (above) may set it true again.
                    mandatoryTrackSheetGone = false
                }
                if !mandatoryTrackSheetGone {
                    // A description-only classification is safe, but it does
                    // not prove that Create has appeared yet. Do not turn that
                    // no-op pass into a terminal State B; another bounded
                    // observation may resolve the direct element and press it
                    // exactly once.
                    continue
                }
            case .unknownSheet:
                // A fail-closed modal read with an unreadable cause must not
                // certify the project as clean, but it is also not evidence
                // that a future poll cannot identify the mandatory sheet.
                // Keep the bounded observer alive; a persistent unknown sheet
                // still ends in State B below without any unchecked action.
                if let unreadableReason = outcome.unreadableReason {
                    lastModalUnreadableReason = unreadableReason
                    lastModalSheetScanFailureDetail = outcome.sheetScanFailureDetail
                }
                guard attempt + 1 == attempts else { continue }
                var extras: [String: Any] = [
                    "operation": "project.new",
                    "method": "accessibility",
                    "selection": selection,
                    "phase": "unexpected_blocking_sheet",
                    "sheet_kind": String(describing: outcome.kind),
                    "write_attempted": true,
                    "safe_to_retry": false,
                ]
                if let lastModalUnreadableReason {
                    lastModalUnreadableReason.apply(to: &extras)
                }
                // See mergeReconcileExtras: an omitted field would read as "no unreadable node".
                if let lastModalSheetScanFailureDetail {
                    extras["reconciled_modal_unreadable_node"] = lastModalSheetScanFailureDetail.envelopeValue
                } else if lastModalUnreadableReason?.originatesInSheetScan == true {
                    extras["reconciled_modal_unreadable_node"] = ModalSheetScanFailureDetail.unrecordedEnvelopeValue
                }
                return .error(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras
                ))
            case .deleteConfirm:
                return .error(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "operation": "project.new",
                        "method": "accessibility",
                        "selection": selection,
                        "phase": "unexpected_blocking_sheet",
                        "sheet_kind": String(describing: outcome.kind),
                        "write_attempted": true,
                        "safe_to_retry": false,
                    ]
                ))
            case .informationalAlert, .strayMenu:
                // This poll OBSERVED a live blocker. `reconcileAfterMutation`
                // above may have just attempted to acknowledge/escape it, but
                // an attempted action is not proof it closed — the very next
                // read could still see the same alert or a replacement one.
                // Falling through here would let a still-open one-button
                // warning or contextual menu certify the arrange window /
                // track count as if nothing were blocking. Only a later
                // `.none` observation may do that; keep polling until one
                // arrives, or report the persistent blocker honestly once the
                // observation budget is exhausted.
                guard attempt + 1 == attempts else { continue }
                var extras: [String: Any] = [
                    "operation": "project.new",
                    "method": "accessibility",
                    "selection": selection,
                    "phase": "blocking_dialog_unconfirmed",
                    "write_attempted": true,
                    "safe_to_retry": false,
                ]
                mergeReconcileExtras(
                    &extras,
                    kind: outcome.kind,
                    action: attemptedReconcileActionLabel(outcome),
                    newTrackAutoConfirmed: false,
                    witnessSummary: outcome.witnessSummary,
                    refusal: outcome.refusal,
                    actionFailure: outcome.actionFailure,
                    unreadableReason: outcome.unreadableReason,
                    sheetScanFailureDetail: outcome.sheetScanFailureDetail
                )
                return .error(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras
                ))
            case .none:
                break
            }
            // `allTrackHeaders` is the project-level fact we can safely report:
            // do not promote a successful Create request or a stale sheet alone
            // into `mandatory_track_created`.
            let observedTrackCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
            if mandatoryTrackCreationWasObserved(
                sheetGoneObserved: mandatoryTrackSheetGone,
                observedTrackCount: observedTrackCount
            ) {
                createdTrack = true
            }
            // When this route exposed the mandatory sheet, the positive count
            // is the observable gate for its track fact. Keep polling while it
            // settles rather than turning the absence of `performed` into an
            // immediate hard failure before the count can be read.
            if mandatoryTrackSheetGone, !createdTrack {
                guard attempt + 1 == attempts else { continue }
                var extras: [String: Any] = [
                    "operation": "project.new",
                    "method": "accessibility",
                    "selection": selection,
                    "phase": "mandatory_track_count_unconfirmed",
                    "write_attempted": true,
                    "safe_to_retry": false,
                ]
                if let witnessSummary {
                    extras["modal_reconciliation_witness"] = witnessSummary.envelopeValue
                }
                return .error(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras
                ))
            }
            if let current = exactCreatedProjectWindow(runtime: runtime) {
                var extras: [String: Any] = [
                    "operation": "project.new",
                    "method": "accessibility",
                    "selection": selection,
                    "phase": "created_project_window_observed",
                    "window_title": AXHelpers.getTitle(current, runtime: runtime.ax) ?? "",
                    "mandatory_track_created": createdTrack,
                    "observation_elapsed_ms": (attempt + 1) * Int(observationDelayNanoseconds / 1_000_000),
                    "write_attempted": true,
                    "safe_to_retry": false,
                ]
                if let witnessSummary {
                    extras["modal_reconciliation_witness"] = witnessSummary.envelopeValue
                }
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras
                ))
            }
        }
        // The exact Choose press already crossed the write boundary. Creator
        // Studio may publish the generated Project bundle before its standard
        // arrange window stabilizes in AX. Report an honest State B and let the
        // qualification orchestrator perform its independent, run-owned
        // Project-resource readback; never misclassify this as a pre-write C or
        // trigger another project.new attempt.
        return .success(projectNewPendingReadbackEnvelope(
            mandatoryTrackCreated: createdTrack,
            observedWindowTitles: observedWindowTitles(runtime: runtime),
            observationBudgetMs: attempts * Int(observationDelayNanoseconds / 1_000_000),
            witnessSummary: witnessSummary,
            modalUnreadableReason: lastModalUnreadableReason,
            modalSheetScanFailureDetail: lastModalSheetScanFailureDetail
        ))
    }

    // MARK: - Save As via AX Dialog

    static func saveAsDialogSelectionIsUnambiguous(
        containerRole: String?,
        containerSubrole: String?,
        windowTitle: String?,
        filenameFieldCount: Int,
        saveButtonCount: Int,
        saveEnabled: Bool,
        cancelButtonCount: Int,
        packageRadioCount: Int,
        folderRadioCount: Int
    ) -> Bool {
        let exactContainer = containerRole == (kAXSheetRole as String)
            || (containerRole == (kAXWindowRole as String)
                && containerSubrole == (kAXDialogSubrole as String))
        return exactContainer
            && windowTitle == "Save"
            && filenameFieldCount == 1
            && saveButtonCount == 1
            && saveEnabled
            && cancelButtonCount == 1
            && packageRadioCount == 1
            && folderRadioCount == 1
    }

    private static func exactSaveAsDialog(
        runtime: AXLogicProElements.Runtime
    ) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        var candidates: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        if let main = AXLogicProElements.mainWindow(runtime: runtime) {
            for child in AXHelpers.getChildren(main, runtime: runtime.ax) {
                let role = AXHelpers.getRole(child, runtime: runtime.ax)
                guard role == (kAXSheetRole as String) || role == (kAXWindowRole as String) else {
                    continue
                }
                if !candidates.contains(where: { CFEqual($0, child) }) {
                    candidates.append(child)
                }
            }
        }

        let matches = candidates.filter { candidate in
            let filenameFields = AXHelpers.findAllDescendants(
                of: candidate, role: kAXTextFieldRole as String, maxDepth: 12, runtime: runtime.ax
            ).filter { AXHelpers.getDescription($0, runtime: runtime.ax) == "text field" }
            let buttons = AXHelpers.findAllDescendants(
                of: candidate, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
            )
            let saveButtons = buttons.filter {
                AXLocalePolicy.elementMatches($0, AXLocalePolicy.saveConfirmationButton, runtime: runtime.ax)
            }
            let cancelButtons = buttons.filter {
                AXLocalePolicy.elementMatches($0, AXLocalePolicy.cancelButton, runtime: runtime.ax)
            }
            let saveEnabled: Bool = saveButtons.first.flatMap {
                AXHelpers.getAttribute($0, kAXEnabledAttribute as String, runtime: runtime.ax)
            } ?? false
            let radios = AXHelpers.findAllDescendants(
                of: candidate, role: kAXRadioButtonRole as String, maxDepth: 12, runtime: runtime.ax
            )
            return saveAsDialogSelectionIsUnambiguous(
                containerRole: AXHelpers.getRole(candidate, runtime: runtime.ax),
                containerSubrole: AXHelpers.getAttribute(
                    candidate, kAXSubroleAttribute as String, runtime: runtime.ax
                ),
                windowTitle: AXHelpers.getTitle(candidate, runtime: runtime.ax),
                filenameFieldCount: filenameFields.count,
                saveButtonCount: saveButtons.count,
                saveEnabled: saveEnabled,
                cancelButtonCount: cancelButtons.count,
                packageRadioCount: radios.filter {
                    AXHelpers.getTitle($0, runtime: runtime.ax) == "Package"
                }.count,
                folderRadioCount: radios.filter {
                    AXHelpers.getTitle($0, runtime: runtime.ax) == "Folder"
                }.count
            )
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func saveAsViaAXDialog(
        path: String,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        // Validate path before setting it into the AX dialog
        guard AppleScriptSafety.isValidProjectPath(path, requireExisting: false) else {
            return .error("save_as requires an absolute .logicx project path")
        }

        // Step 1: Trigger Save As via menu click
        let koreanResult = clickMenuItem("다른 이름으로 저장…", menuName: "파일", runtime: runtime)
        let triggered = koreanResult.isSuccess
            || clickMenuItem("Save As…", menuName: "File", runtime: runtime).isSuccess

        guard triggered else {
            return .error("Failed to open Save As dialog via menu")
        }

        // Creator Studio 12.3 exposes this panel as a top-level AXDialog rather
        // than a child sheet. Accept either representation, but only after the
        // exact structural classifier finds one unambiguous Save As surface.
        var dialog: AXUIElement?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            dialog = exactSaveAsDialog(runtime: runtime)
            if dialog != nil { break }
        }

        guard let saveDialog = dialog else {
            return .error("Exact Save As dialog did not appear within 3 seconds")
        }

        // Helper: dismiss dialog on failure (press Escape to avoid blocking UI)
        func dismissDialog() {
            let cancelButtons = AXHelpers.findAllDescendants(of: saveDialog, role: "AXButton", runtime: runtime.ax)
            for btn in cancelButtons {
                if AXLocalePolicy.elementMatches(btn, AXLocalePolicy.cancelButton, runtime: runtime.ax) {
                    AXHelpers.performAction(btn, kAXPressAction, runtime: runtime.ax)
                    return
                }
            }
        }

        // Step 3: Find filename text field and set full path
        let filenameFields = AXHelpers.findAllDescendants(
            of: saveDialog, role: kAXTextFieldRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter { AXHelpers.getDescription($0, runtime: runtime.ax) == "text field" }
        guard filenameFields.count == 1, let filenameField = filenameFields.first else {
            dismissDialog()
            return .error("Cannot resolve the exact filename field in Save As dialog")
        }

        guard AXHelpers.setAttribute(
            filenameField, kAXValueAttribute, path as CFTypeRef, runtime: runtime.ax
        ) else {
            dismissDialog()
            return .error("Cannot set the exact Save As filename field")
        }
        // Confirm the text entry so the save panel updates its internal path state
        AXHelpers.performAction(filenameField, kAXConfirmAction, runtime: runtime.ax)
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for panel to process

        // Step 4: Find and click Save button
        let saveButtons = AXHelpers.findAllDescendants(
            of: saveDialog, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax
        ).filter {
            AXLocalePolicy.elementMatches($0, AXLocalePolicy.saveConfirmationButton, runtime: runtime.ax)
        }
        guard saveButtons.count == 1,
              let saveButton = saveButtons.first,
              AXHelpers.performAction(saveButton, kAXPressAction, runtime: runtime.ax) else {
            dismissDialog()
            return .error("Cannot press the exact Save button in Save As dialog")
        }

        // Step 5: Verify file exists (up to 5s)
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if FileManager.default.fileExists(atPath: path) {
                return .success(HonestContract.encodeStateA(
                    extras: ["requested": path, "observed": path, "via": "save-dialog"]
                ))
            }
        }

        let pathWithExt = path.hasSuffix(".logicx") ? path : path + ".logicx"
        if FileManager.default.fileExists(atPath: pathWithExt) {
            return .success(HonestContract.encodeStateA(
                extras: ["requested": path, "observed": pathWithExt, "via": "save-dialog-with-ext"]
            ))
        }

        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "Save As dialog completed but no file appeared at requested path within 5s",
            extras: ["requested": path]
        ))
    }

    static func openBounceDialogViaMenu(
        systemEventsAuthorized: @Sendable () -> Bool = { PermissionChecker.checkSystemEventsAutomation() },
        executeScript: @escaping @Sendable (String) async -> ChannelResult = {
            await AppleScriptChannel.executeAppleScript($0)
        }
    ) async -> ChannelResult {
        guard systemEventsAuthorized() else {
            return .error(HonestContract.encodeStateC(
                error: .systemEventsAutomationDenied,
                hint: AppleScriptErrorClassifier.systemEventsAutomationDeniedHint,
                extras: [
                    "operation": "project.bounce",
                    "failure_stage": "preflight_system_events_permission",
                    "write_attempted": false,
                    "safe_to_retry": false,
                ]
            ))
        }

        let processTarget = LogicProTarget.appleScriptTarget().systemEventsProcessTarget
        // #519: bar ("File") and item ("Bounce") names are resolved from AXLocalePolicy's
        // LabelSets instead of hard-coded EN/KO literals — this also makes the already-recorded
        // Japanese "ファイル" variant reachable, which the old hard-coded pair could not reach.
        // The "Project or Section…" leaf keeps trying every recorded ellipsis rendering, now
        // sourced from AXLocalePolicy.projectOrSectionMenuItem instead of a separate inline list.
        let barResolution = AppleScriptMenuResolution.menuBarItem(
            AXLocalePolicy.fileMenuBar,
            variableName: "barName",
            notFoundError: "BOUNCE_MENU_ITEM_NOT_FOUND"
        )
        let itemResolution = AppleScriptMenuResolution.menuItem(
            AXLocalePolicy.bounceMenuItem,
            under: "menu bar item barName of menu bar 1",
            variableName: "itemName",
            notFoundError: "BOUNCE_MENU_ITEM_NOT_FOUND"
        )
        let projectOrSectionLiterals = AXLocalePolicy.projectOrSectionMenuItem.labels
            .map { "\"\(AppleScriptSafety.escapeForScript($0))\"" }
            .joined(separator: ", ")
        let script = """
        tell application "System Events"
            tell \(processTarget)
                set frontmost to true
                set menuClicked to false
                try
                    \(barResolution)
                    \(itemResolution)
                on error
                    return "BOUNCE_MENU_ITEM_NOT_FOUND"
                end try
                repeat with targetName in {\(projectOrSectionLiterals)}
                    if menuClicked is false then
                        try
                            click menu item (targetName as text) of menu 1 of menu item itemName of menu 1 of menu bar item barName of menu bar 1
                            set menuClicked to true
                        end try
                    end if
                end repeat
                -- #519 review: every failure path after a menu is OPEN must close it. The click above
                -- walks File > Bounce, so both menus are on screen by the time the leaf can fail; the
                -- bare `try` swallows that and returning here left Logic sitting with the File menu
                -- open, and a wedged menu turns every later operation into a refusal. Escape first.
                if menuClicked is false then
                    key code 53
                    delay 0.1
                    return "BOUNCE_MENU_ITEM_NOT_FOUND"
                end if
                repeat 10 times
                    set bounceName to ""
                    try
                        set bounceName to name of front window
                    end try
                    try
                        set bounceName to bounceName & " " & name of sheet 1 of front window
                    end try
                    if bounceName contains "Bounce" or bounceName contains "바운스" then
                        return "BOUNCE_DIALOG_OPENED"
                    end if
                    delay 0.2
                end repeat
                return "BOUNCE_DIALOG_NOT_FOUND"
            end tell
        end tell
        """

        let result = await executeScript(script)
        guard result.isSuccess else {
            if HonestContract.stateCErrorCode(result.message)
                == HonestContract.FailureError.systemEventsAutomationDenied.rawValue {
                return result
            }
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "File > Bounce menu execution failed",
                extras: [
                    "operation": "project.bounce",
                    "failure_stage": "open_bounce_menu",
                    "write_attempted": true,
                    "safe_to_retry": true,
                    "cause": result.message,
                ]
            ))
        }

        if result.message.contains("BOUNCE_DIALOG_OPENED") {
            return .success(HonestContract.encodeStateA(extras: [
                "operation": "project.bounce",
                "requested": "bounce_dialog_open",
                "observed": "bounce_dialog_open",
                "dialog_opened": true,
                "bounce_fired": false,
                "via": "file-menu",
                "next_action": "Review the Bounce settings in Logic, then confirm and choose the destination.",
            ]))
        }
        if result.message.contains("BOUNCE_MENU_ITEM_NOT_FOUND") {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "File > Bounce > Project or Section menu item was not found",
                extras: [
                    "operation": "project.bounce",
                    "failure_stage": "locate_bounce_menu_item",
                    "write_attempted": false,
                    "safe_to_retry": true,
                ]
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .dialogNotFound,
            hint: "File > Bounce menu was clicked but the Bounce dialog did not appear within 2 seconds",
            extras: [
                "operation": "project.bounce",
                "failure_stage": "verify_bounce_dialog",
                "write_attempted": true,
                "safe_to_retry": true,
            ]
        ))
    }

    private static func clickMenuItem(
        _ itemTitle: String,
        menuName: String,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let item = AXLogicProElements.menuItem(path: [menuName, itemTitle], runtime: runtime) else {
            return .error("Cannot find menu item: \(menuName) > \(itemTitle)")
        }
        guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to click: \(menuName) > \(itemTitle)")
        }
        return .success("{\"menu_clicked\":\"\(itemTitle)\"}")
    }

    // MARK: - Project

    static func defaultGetProjectInfo(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .error("Cannot locate Logic Pro main window")
        }
        let title = AXHelpers.getTitle(window, runtime: runtime.ax) ?? "Unknown"
        var info = ProjectInfo()
        info.name = title
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    // MARK: - Markers

    /// v3.1.9 (Issue #8) — Logic 12.2 marker subtree path.
    ///
    /// Single delegating wrapper around `AXLogicProElements.enumerateMarkers`
    /// (when the arrangement area exists) or its in-window scrape helper
    /// (when 12.2 has dropped the arrangement-area identifier). Pre-v3.1.9
    /// this function did its own copy of the marker-list-window strategy
    /// AND then called `enumerateMarkers(in:)` which redundantly retried
    /// the same lookup.
    /// v3.1.9-final puts strategy ordering in `enumerateMarkers` and uses
    /// the in-window helper directly only when there is no arrangement
    /// area to pass.
    ///
    /// Behaviour matrix:
    ///
    /// | arrange area | marker list window | strategy |
    /// |--------------|--------------------|----------|
    /// | non-nil      | open / closed      | `enumerateMarkers(in: area)` runs all 3 strategies |
    static func defaultGetMarkers(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        if let listWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) {
            switch AXLogicProElements.enumerateMarkersFromListWindow(listWindow, runtime: runtime.ax) {
            case .success(let markers):
                return encodeResult(markers)
            case .failure:
                return .error(HonestContract.encodeStateC(
                    error: .readbackUnavailable,
                    hint: "Marker List rows could not be read."
                ))
            }
        }
        if let area = AXLogicProElements.getArrangementArea(runtime: runtime) {
            let legacyMarkers = AXLogicProElements.enumerateMarkers(in: area, runtime: runtime)
            if !legacyMarkers.isEmpty {
                return encodeResult(legacyMarkers)
            }
        }
        return .error(HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "Open Navigate > Open Marker List so Logic Pro can expose marker rows to Accessibility.",
            extras: ["reason": "marker_list_not_open"]
        ))
    }

}
