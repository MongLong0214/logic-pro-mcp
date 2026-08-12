import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Delete a marker through the Marker List itself, so the operation works on a default install.
    ///
    /// `nav.delete_marker` previously routed only to `[.midiKeyCommands, .cgEvent]`, which means it
    /// does nothing until the operator has installed the key-command preset AND performed a manual
    /// MIDI Learn inside Logic. Until then the CC goes out, Logic has nothing bound to it, the marker
    /// survives, and the caller is told `readback_unavailable` — a setup prerequisite reported as a
    /// readback problem. Deleting a marker should not require a hand-configured MIDI binding.
    ///
    /// Measured on Logic 12.3 while building this path:
    ///   * each Marker List row carries a custom `Delete` action, and performing it does **nothing** —
    ///     the return code says success and the marker stays. Only the observed effect counts.
    ///   * selecting the row does work: the table reports it in `AXSelectedRows`.
    ///   * the Marker List toolbar's Edit menu exposes an exact enabled Delete entry that can receive
    ///     `AXPick`.
    ///
    /// The scoped AX menu route is the only deletion actuator. A synthetic Delete key cannot be
    /// bound to this table at delivery time: focus can move to another Logic responder between an
    /// AX focus check and the post. Refuse when the exact menu item is unavailable rather than risk
    /// deleting a region, track, or dialog control.
    static func defaultDeleteMarker(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production,
        mouse: AXMouseHelper.Runtime = .production
    ) async -> ChannelResult {
        guard index >= 0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "nav.delete_marker requires an index >= 0",
                extras: ["operation": "nav.delete_marker", "write_attempted": false]
            ))
        }

        let openResult = await defaultOpenMarkerList(runtime: runtime)
        guard openResult.isSuccess else { return openResult }

        guard let binding = AXLogicProElements.markerListBinding(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "The Marker List could not be bound after opening.",
                extras: ["operation": "nav.delete_marker", "requested_index": index, "write_attempted": false]
            ))
        }
        let window = binding.window
        guard case .success(let before) = AXLogicProElements.enumerateMarkersFromListWindow(
            window, runtime: runtime.ax
        ) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "Marker List rows could not be read before deleting a marker.",
                extras: [
                    "operation": "nav.delete_marker",
                    "requested_index": index,
                    "write_attempted": false,
                ]
            ))
        }
        guard let target = before.first(where: { $0.id == index }) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Marker index \(index) was not found in the Marker List",
                extras: [
                    "operation": "nav.delete_marker",
                    "requested_index": index,
                    "marker_count": before.count,
                    "write_attempted": false,
                ]
            ))
        }

        // Indices renumber when a row disappears, so comparing them after the write would prove
        // nothing. Instead, expect the pre-write POSITION multiset with exactly one instance of
        // the target's position removed. Position entries are length-prefixed before sorting and
        // joining, so their concatenation has unambiguous boundaries.
        let expectedSurvivorMarkers = before.filter { $0.id != index }
        let expectedSurvivorPositions = expectedSurvivorMarkers
            .map(\.position)
            .map(canonicalMarkerPosition)
            .sorted()
        // Names are deliberately not part of the State-A proof: Logic renumbers its generated
        // marker names after a delete. Retain unambiguous name/position identities for a State-B
        // mismatch diagnostic, where they help a human understand what was read back.
        let expectedSurvivors = expectedSurvivorMarkers
            .map { canonicalMarkerIdentity(name: $0.name, position: $0.position) }
            .sorted()
        let targetPositionMatchCount = before.filter { $0.position == target.position }.count
        let targetPositionUnique = targetPositionMatchCount == 1
        // A parse fallback manufactures `ordinal + 1.1.1.1`, which can happen to equal a
        // different marker's parsed position. Do not let a synthetic position participate in a
        // State-A identity proof, even if it happens not to collide in this particular reading.
        let prewritePositionEvidenceCanonical = !before.isEmpty
            && before.allSatisfy { $0.positionSource == .parser }
        var extras: [String: Any] = [
            "operation": "nav.delete_marker",
            "requested_index": index,
            "target_name": target.name,
            "target_position": target.position,
            "target_position_unique": targetPositionUnique,
            "prewrite_position_evidence_canonical": prewritePositionEvidenceCanonical,
            "marker_count_before": before.count,
        ]

        guard let selection = selectMarkerRowForDeletion(index, in: window, runtime: runtime.ax) else {
            // The scoped menu route may proceed only when the selected row is confirmed in this
            // exact Marker List table.
            extras["write_attempted"] = false
            extras["safe_to_retry"] = true
            extras["fallback_unsafe"] = true
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Marker index \(index) could not be selected, so nothing was pressed",
                extras: extras
            ))
        }

        // Selecting a row is itself an AX write and moves the visible selection. `write_attempted`
        // remains scoped to the destructive Delete menu pick, but a refusal after this point must disclose
        // that the caller's selection was changed.
        // `selection_write_attempted` is what this call did; `selection_changed` is what it
        // actually altered. A row that was already the sole selection is not a change, and saying
        // so would be the same over-claim this refusal exists to remove.
        extras["selection_write_attempted"] = true
        // An unreadable pre-write selection is not evidence of either a change or no change.
        // Omit the optional field rather than reporting a Boolean guess.
        if let changedSelection = selection.changedSelection {
            extras["selection_changed"] = changedSelection
        }

        switch pickDeleteFromMarkerListEditMenu(
            in: window,
            runtime: runtime.ax,
            mouse: mouse
        ) {
        case .pickIssued(let menuCloseWasNotObserved):
            // `AXPick` status codes are not evidence of whether the menu action took effect. Once
            // issued, proceed directly to readback regardless of the return value.
            extras["write_attempted"] = true
            guard !menuCloseWasNotObserved else {
                // AXPick may already have deleted the marker, so this cannot be State C. But a
                // menu that remains open means the UI was not restored to a state in which a
                // verified result is safe to report or retry.
                extras["safe_to_retry"] = false
                extras["fallback_unsafe"] = true
                extras["menu_state"] = "could_not_be_closed"
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras
                ))
            }

        case .routeUnavailable(let failure, let axStatus, let menuState, let menuCancelActionState):
            extras["edit_menu_route_state"] = failure.state
            // "Unreadable" without the status tells a caller nothing it can act on, and cost two
            // rounds of guessing to diagnose live. Report which AX status stopped the route.
            if let axStatus { extras["edit_menu_route_ax_status"] = Int(axStatus) }
            if let menuState {
                // AXShowMenu may have left an unobservable menu on screen. This is not a table
                // focus failure, and no other deletion actuator may be attempted.
                extras["write_attempted"] = false
                extras["safe_to_retry"] = false
                extras["fallback_unsafe"] = true
                extras["menu_state"] = menuState
                if let menuCancelActionState {
                    extras["menu_cancel_action_state"] = menuCancelActionState
                }
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: failure.hint + " The Edit menu could not be confirmed closed, so no deletion was issued.",
                    extras: extras
                ))
            }
            // Selection changed state is disclosed above. Do not turn an unavailable localized
            // element route into a key post: a PID only identifies Logic, not its current key
            // responder, so the input could delete an unrelated Logic object.
            extras["write_attempted"] = false
            extras["safe_to_retry"] = true
            extras["fallback_unsafe"] = true
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: failure.hint + " No deletion was issued because no element-targeted Marker List route is available.",
                extras: extras
            ))
        }

        guard let afterBinding = AXLogicProElements.markerListBinding(runtime: runtime),
              afterBinding.projectDocument == binding.projectDocument,
              CFEqual(afterBinding.window, binding.window) else {
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        // The Marker List enumeration is not stable immediately after a write: measured live, two
        // reads taken back to back can disagree, and a blank row keeps rendering the previous row's
        // name. Verifying against a single read produced a State A for a marker that was still
        // there. So require two consecutive identical readings before believing either of them, and
        // report State B when they will not settle rather than certifying a guess.
        var observedSurvivorPositions: [String] = []
        var observedSurvivors: [String] = []
        var observedPositionEvidenceCanonical = false
        var observedEmptySurvivorSet = false
        var settled = false
        var previousPositions: [String]?
        for _ in 0..<6 {
            let reading: [MarkerState]
            switch AXLogicProElements.enumerateMarkersFromListWindow(
                afterBinding.window, runtime: runtime.ax
            ) {
            case .success(let observedMarkers):
                reading = observedMarkers
            case .failure:
                extras["readback_settled"] = false
                extras["readback_unreadable"] = true
                return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
            }
            let positions = reading.map(\.position).map(canonicalMarkerPosition).sorted()
            if let previousPositions, previousPositions == positions {
                observedSurvivorPositions = positions
                observedSurvivors = reading
                    .map { canonicalMarkerIdentity(name: $0.name, position: $0.position) }
                    .sorted()
                // An empty successful survivor set has no observed positions to parse. Treat it
                // explicitly as a successfully read empty set rather than accepting
                // `[].allSatisfy` as canonical-position evidence.
                observedEmptySurvivorSet = reading.isEmpty
                observedPositionEvidenceCanonical = !reading.isEmpty
                    && reading.allSatisfy { $0.positionSource == .parser }
                settled = true
                break
            }
            previousPositions = positions
            mouse.sleepMicros(250_000)
        }
        guard settled else {
            extras["readback_settled"] = false
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        extras["readback_settled"] = true
        extras["marker_count_after"] = observedSurvivorPositions.count
        extras["observed_position_evidence_canonical"] = observedPositionEvidenceCanonical
        extras["observed_empty_survivor_set"] = observedEmptySurvivorSet
        extras["position_evidence_canonical"] = prewritePositionEvidenceCanonical
            && (observedEmptySurvivorSet || observedPositionEvidenceCanonical)

        // This proves that precisely one position occurrence disappeared and that it was an
        // occurrence at the target's position. It cannot establish WHICH marker was removed when
        // multiple markers share that position; the position multiset contains no such identity.
        guard observedSurvivorPositions.count == before.count - 1,
              observedSurvivorPositions == expectedSurvivorPositions else {
            // Either the target position survived, or another position disappeared. The
            // name-carrying diagnostics make that mismatch useful to a human without making names
            // part of the stable State-A comparison.
            extras["observed_survivors"] = observedSurvivors
            extras["expected_survivors"] = expectedSurvivors
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        // Bind the request-derived position-multiset expectation to the independently read-back
        // position multiset in State A. Names are not exposed here because Logic may renumber them.
        extras["expected_survivor_position_multiset"] = expectedSurvivorPositions.joined()
        extras["observed_survivor_position_multiset"] = observedSurvivorPositions.joined()
        guard targetPositionUnique else {
            extras["reason_detail"] = "Delete was attempted and the marker count moved, but "
                + "\(targetPositionMatchCount) pre-write markers shared target position "
                + "\(target.position), so this readback cannot establish which marker was deleted."
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        guard prewritePositionEvidenceCanonical,
              observedEmptySurvivorSet || observedPositionEvidenceCanonical else {
            extras["reason_detail"] = "Delete was attempted and the marker count moved, but at "
                + "least one marker position came from an ordinal parse fallback; synthetic "
                + "positions cannot support a verified target identity."
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    /// An unambiguous element of a position multiset.
    ///
    /// The wire form is `<position UTF-8 byte count>:<position>`. Sorting these elements and
    /// concatenating them creates an unambiguous multiset encoding without trusting a delimiter.
    private static func canonicalMarkerPosition(_ position: String) -> String {
        "\(position.lengthOfBytes(using: .utf8)):\(position)"
    }

    /// An unambiguous, stable marker identity for survivor-set comparison and reporting.
    ///
    /// The wire form is `<name UTF-8 byte count>:<name><position UTF-8 byte count>:<position>`.
    /// Because the two payload strings are length-prefixed, concatenating sorted entries cannot
    /// be forged by putting a former joining character (such as `@`) in a marker name.
    private static func canonicalMarkerIdentity(name: String, position: String) -> String {
        "\(name.lengthOfBytes(using: .utf8)):\(name)\(position.lengthOfBytes(using: .utf8)):\(position)"
    }

    private struct MarkerRowSelection {
        let changedSelection: Bool?
    }

    /// Selects the row and confirms the table agrees, since a write that reports success without
    /// changing the selection would leave the Edit-menu Delete command pointed at whatever was selected before.
    private static func selectMarkerRowForDeletion(
        _ index: Int,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> MarkerRowSelection? {
        guard let table = AXHelpers.findAllDescendants(
            of: window, role: kAXTableRole as String, maxDepth: 12, runtime: runtime
        ).first else { return nil }
        let rows = AXHelpers.findAllDescendants(
            of: table, role: kAXRowRole as String, maxDepth: 4, runtime: runtime
        )
        guard index >= 0, index < rows.count else { return nil }
        // Read the selection BEFORE writing. A post-write read proves the target is selected NOW,
        // not that this call changed anything — if the row was already selected, reporting a
        // selection change would assert an effect that did not happen.
        let before: Result<[AXUIElement]?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            table, "AXSelectedRows", runtime: runtime
        )
        let wasAlreadyExactlyTheTarget: Bool?
        switch before {
        case .success(let selectedRows):
            let selectedRows = selectedRows ?? []
            wasAlreadyExactlyTheTarget = selectedRows.count == 1
                && CFEqual(selectedRows[0], rows[index])
        case .failure:
            // A failed read cannot establish whether selecting this row altered anything.
            wasAlreadyExactlyTheTarget = nil
        }
        _ = AXHelpers.setAttribute(
            rows[index], kAXSelectedAttribute as String, kCFBooleanTrue, runtime: runtime
        )
        let selected: [AXUIElement] = AXHelpers.getAttribute(
            table, "AXSelectedRows", runtime: runtime
        ) ?? []
        guard selected.count == 1, CFEqual(selected[0], rows[index]) else { return nil }
        return MarkerRowSelection(
            changedSelection: wasAlreadyExactlyTheTarget.map { !$0 }
        )
    }

    /// Whether attempting the Marker List's own Edit → Delete menu path reached a destructive
    /// actuator. AX action status is deliberately absent from this outcome: an `AXPick` that
    /// reports failure can still delete the marker.
    private enum MarkerListEditMenuRouteFailure {
        case menuAbsent
        case menuUnreadable
        case exactDeleteEntryMissingOrDisabled

        var state: String {
            switch self {
            case .menuAbsent: "menu_absent"
            case .menuUnreadable: "menu_unreadable"
            case .exactDeleteEntryMissingOrDisabled: "exact_delete_entry_missing_or_disabled"
            }
        }

        var hint: String {
            switch self {
            case .menuAbsent:
                "The Marker List Edit menu was not available, so its Delete entry was not picked."
            case .menuUnreadable:
                "The Marker List Edit menu route could not be read, so its Delete entry was not picked."
            case .exactDeleteEntryMissingOrDisabled:
                "The Marker List Edit menu's exact Delete entry was missing or disabled, so it was not picked."
            }
        }
    }

    private enum MarkerListEditMenuDeleteOutcome {
        /// `AXPick` was sent to the exact enabled Delete menu item, whatever AX returned. The
        /// associated Boolean is true when this call could not prove the menu later closed.
        case pickIssued(menuCloseWasNotObserved: Bool)
        case routeUnavailable(
            MarkerListEditMenuRouteFailure,
            axStatus: Int32? = nil,
            menuState: String? = nil,
            menuCancelActionState: String? = nil
        )
    }

    /// Use the Marker List's own menu rather than a keyboard Delete. The bottom `Edit` button and the
    /// toolbar `Edit` menu button have the same localized label in Logic 12.3, but only the latter
    /// advertises `AXShowMenu`; inspect action names before deciding which control may be actuated.
    private static func pickDeleteFromMarkerListEditMenu(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> MarkerListEditMenuDeleteOutcome {
        let search = markerListEditMenuControls(in: window, runtime: runtime)
        let controls = search.controls
        var unreadable = search.unreadable
        for control in controls {
            switch markerListElementMatches(
                control, labels: AXLocalePolicy.markerListEditMenuButton,
                mode: .exactStrict, runtime: runtime
            ) {
            case .success(true):
                break
            case .success(false):
                continue
            case .failure(let error):
                // This control did not answer; it is neither a usable Edit candidate nor a final
                // verdict. A later toolbar Edit control may be fully readable.
                unreadable = unreadable ?? error
                continue
            }

            // This is intentionally action discovery, not a press ladder. A live Marker List's
            // bottom Edit AXButton offers AXPress only; pressing it is not a reliable route to its
            // menu. The toolbar AXMenuButton offers AXShowMenu.
            switch AXHelpers.getActionNamesResult(control, runtime: runtime) {
            case .success(let actions):
                guard actions.contains(kAXShowMenuAction as String) else { continue }
            case .failure(let error):
                unreadable = unreadable ?? error
                continue
            }

            // As with AXPick, the return code does not prove the UI state. Read the scoped AX tree
            // after issuing AXShowMenu. Logic may expose that menu asynchronously, so settle
            // absence before reporting the route unavailable.
            _ = AXHelpers.performAction(control, kAXShowMenuAction as String, runtime: runtime)
            let menu: AXUIElement
            switch settledMarkerListEditMenuObservation(
                under: control, runtime: runtime, mouse: mouse
            ) {
            case .present(let observedMenu):
                menu = observedMenu
            case .absent:
                continue
            case .unknown(let observationError):
                // AXShowMenu may have succeeded even though its scoped child reads failed or
                // disagreed. Attempt AX-only cleanup before honestly reporting unreadable state.
                let cleanup = dismissMarkerListEditMenuAfterUnknownDiscovery(
                    from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(
                    .menuUnreadable,
                    axStatus: observationError?.raw ?? cleanup.axStatus,
                    menuState: cleanup.wasClosed ? nil : "could_not_be_closed",
                    menuCancelActionState: cleanup.cancelActionState
                )
            }

            let entry: AXUIElement
            switch markerListDeleteMenuItem(in: menu, runtime: runtime) {
            case .success(let observedEntry?):
                entry = observedEntry
            case .success(nil):
                _ = dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse)
                return .routeUnavailable(.exactDeleteEntryMissingOrDisabled)
            case .failure(let error):
                _ = dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse)
                return .routeUnavailable(.menuUnreadable, axStatus: error.raw)
            }
            switch markerListMenuItemEnabledForActuation(entry, runtime: runtime) {
            case .enabled:
                break
            case .disabled:
                _ = dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse)
                return .routeUnavailable(.exactDeleteEntryMissingOrDisabled)
            case .unreadable(let error):
                _ = dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse)
                return .routeUnavailable(.menuUnreadable, axStatus: error.raw)
            }

            // Do not use the return value to select another actuator. This one call is the write.
            _ = AXHelpers.performAction(entry, kAXPickAction as String, runtime: runtime)
            // AXPick normally closes a menu itself. Only a successful read that finds no menu is
            // twice in a row is proof of that disappearance; a present, unstable, or unreadable
            // child list is still open/unknown and requires cleanup before this run can proceed.
            let menuCloseWasNotObserved = !markerListEditMenuIsSettledClosed(
                under: control, runtime: runtime, mouse: mouse
            ) && !dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse)
            return .pickIssued(menuCloseWasNotObserved: menuCloseWasNotObserved)
        }
        // Nothing matched. Whether that means "there is no Edit control" or "there is one and part
        // of the tree would not answer" is exactly the distinction a caller needs, so keep it.
        if let unreadable {
            return .routeUnavailable(
                .menuUnreadable, axStatus: unreadable.raw
            )
        }
        return .routeUnavailable(.menuAbsent)
    }

    /// Finds candidate Edit controls without collapsing a failed child/tree read to no controls.
    /// The result deliberately includes only controls whose role was read successfully; a failed
    /// role observation makes the discovery unreadable rather than quietly declaring no menu route.
    private static func markerListEditMenuControls(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> MarkerListEditMenuControlSearch {
        // A search is not a readback, and conflating the two broke this route live. An individual
        // node that will not answer cannot be a CANDIDATE — it is not proof that the search as a
        // whole failed, and aborting on it means one uncooperative element anywhere in a twelve-deep
        // Marker List tree hides the Edit control that is sitting right there. Measured on Logic
        // 12.3: some nodes answer -25200 mid-walk while marker enumeration on the same call
        // succeeds, so the API is plainly not disabled.
        //
        // So: skip what cannot answer, remember that something could not, and let the caller
        // distinguish "no Edit control exists" from "no Edit control was found and part of the tree
        // was unreadable".
        var controls: [AXUIElement] = []
        var unreadable: AXHelpers.AXStatusError?
        var parents = [window]
        for _ in 0..<12 {
            var next: [AXUIElement] = []
            for parent in parents {
                let children: [AXUIElement]
                switch AXHelpers.childrenResult(parent, runtime: runtime) {
                case .success(let observedChildren):
                    children = observedChildren
                case .failure(let error) where error.isDefinitiveAbsence:
                    // A leaf answers "no children"; that is an answer, and a real Marker List tree
                    // is full of them.
                    children = []
                case .failure(let error):
                    unreadable = unreadable ?? error
                    children = []
                }
                for child in children {
                    switch AXHelpers.getAttributeResult(
                        child, kAXRoleAttribute as String, runtime: runtime
                    ) as Result<String?, AXHelpers.AXStatusError> {
                    case .success(let role):
                        if role == (kAXMenuButtonRole as String) || role == (kAXButtonRole as String) {
                            controls.append(child)
                        }
                    case .failure(let error) where error.isDefinitiveAbsence:
                        break
                    case .failure(let error):
                        unreadable = unreadable ?? error
                    }
                    next.append(child)
                }
            }
            parents = next
        }
        return MarkerListEditMenuControlSearch(controls: controls, unreadable: unreadable)
    }

    /// What a control search found, and whether any part of the tree refused to answer. Kept
    /// together so "found nothing" and "found nothing and could not see everything" stay distinct.
    private struct MarkerListEditMenuControlSearch {
        let controls: [AXUIElement]
        let unreadable: AXHelpers.AXStatusError?
    }

    /// Label discovery participates in the menu-route diagnosis. A failed Title or Description
    /// read is not proof that the control or menu item has a different localized label.
    private static func markerListElementMatches(
        _ element: AXUIElement,
        labels: AXLocalePolicy.LabelSet,
        mode: AXLocalePolicy.MatchMode,
        runtime: AXHelpers.Runtime
    ) -> Result<Bool, AXHelpers.AXStatusError> {
        switch AXHelpers.getAttributeResult(
            element, kAXTitleAttribute as String, runtime: runtime
        ) as Result<String?, AXHelpers.AXStatusError> {
        case .success(let title):
            if labels.matches(title, mode: mode) { return .success(true) }
        case .failure(let error) where error.isDefinitiveAbsence:
            // Not vending AXTitle is an answer, not a failed read; fall through to AXDescription.
            break
        case .failure(let error):
            return .failure(error)
        }
        switch AXHelpers.getAttributeResult(
            element, kAXDescriptionAttribute as String, runtime: runtime
        ) as Result<String?, AXHelpers.AXStatusError> {
        case .success(let description):
            return .success(labels.matches(description, mode: mode))
        case .failure(let error) where error.isDefinitiveAbsence:
            return .success(false)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// An observed menu must belong to the exact Edit control that was asked to show it. A menu
    /// elsewhere in the window could be stale or belong to another control, so its presence cannot
    /// authorise an AXPick here.
    private static func markerListEditMenu(
        under control: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<AXUIElement?, AXHelpers.AXStatusError> {
        switch AXHelpers.childrenResult(control, runtime: runtime) {
        case .success(let children):
            for child in children {
                switch AXHelpers.getAttributeResult(
                    child, kAXRoleAttribute as String, runtime: runtime
                ) as Result<String?, AXHelpers.AXStatusError> {
                case .success(let role):
                    if role == (kAXMenuRole as String) { return .success(child) }
                case .failure(let error):
                    return .failure(error)
                }
            }
            return .success(nil)
        case .failure(let error) where markerListEditMenuAbsenceStatus(error):
            // AXChildren on an AXMenuButton may answer `attributeUnsupported` or `noValue`
            // instead of giving an empty child list. Both are a readable absence here, not an
            // unreadable observation that could never settle.
            return .success(nil)
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func markerListEditMenuAbsenceStatus(_ error: AXHelpers.AXStatusError) -> Bool {
        error.raw == AXError.attributeUnsupported.rawValue || error.raw == AXError.noValue.rawValue
    }

    /// The Marker List can make an AXMenu visible after AXShowMenu returns. Require two absent
    /// scoped reads before declaring the Edit-menu route unavailable; anything that remains
    /// unstable within the bound, or any genuine read failure, stays unreadable.
    private enum MarkerListEditMenuObservation {
        case present(AXUIElement)
        case absent
        case unknown(AXHelpers.AXStatusError?)
    }

    private static func settledMarkerListEditMenuObservation(
        under control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> MarkerListEditMenuObservation {
        // The two claims are not symmetric, and treating them the same broke the operation.
        //
        // PRESENCE is actionable the moment it is seen: the menu is open now, and an AXPick aimed at
        // it is valid now. Measured on Logic 12.3, a menu opened by AXShowMenu can close on its own
        // within 250 ms, so requiring two consecutive sightings made presence never settle and every
        // delete refused while the menu was plainly there.
        //
        // ABSENCE is the claim that needs settling, because Logic can expose the menu
        // asynchronously — a single "no menu" read is not enough to name the route unavailable.
        // An UNREADABLE reading is not an answer either, and taking the first one as final made the
        // route refuse intermittently on a Marker List whose menu was open. Measured on Logic 12.3,
        // a scoped child read can come back -25200 on one poll and answer normally on the next while
        // other reads in the same call succeed. So a failure retires that poll, not the observation.
        var absentReadings = 0
        var unreadable: AXHelpers.AXStatusError?
        for _ in 0..<6 {
            switch markerListEditMenu(under: control, runtime: runtime) {
            case .success(let menu?):
                return .present(menu)
            case .success(nil):
                absentReadings += 1
                if absentReadings >= 2 { return .absent }
            case .failure(let error):
                unreadable = unreadable ?? error
                break
            }
            mouse.sleepMicros(250_000)
        }
        // Every poll was spent without two agreeing absences and without ever seeing the menu.
        return .unknown(unreadable)
    }

    private static func markerListEditMenuIsSettledClosed(
        under control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> Bool {
        if case .absent = settledMarkerListEditMenuObservation(
            under: control, runtime: runtime, mouse: mouse
        ) {
            return true
        }
        return false
    }

    private struct MarkerListEditMenuUnknownDiscoveryCleanup {
        let wasClosed: Bool
        let cancelActionState: String?
        let axStatus: Int32?
    }

    /// Discovery was unknown before it yielded an AXMenu. Re-observe in case the menu settles;
    /// otherwise only send AXCancel to the opener if it expressly advertises that action, then
    /// require a settled closed observation before permitting a focused-key fallback.
    private static func dismissMarkerListEditMenuAfterUnknownDiscovery(
        from control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> MarkerListEditMenuUnknownDiscoveryCleanup {
        switch settledMarkerListEditMenuObservation(under: control, runtime: runtime, mouse: mouse) {
        case .present(let menu):
            return MarkerListEditMenuUnknownDiscoveryCleanup(
                wasClosed: dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse),
                cancelActionState: nil,
                axStatus: nil
            )
        case .absent:
            return MarkerListEditMenuUnknownDiscoveryCleanup(
                wasClosed: true, cancelActionState: nil, axStatus: nil
            )
        case .unknown:
            // AXShowMenu was already issued, so a menu may be open on screen even though this run
            // cannot read it. AXCancel is generic rather than a "close this opener" action, so do
            // not send it speculatively: first prove the bound control advertises it.
            switch AXHelpers.getActionNamesResult(control, runtime: runtime) {
            case .success(let actions) where actions.contains(kAXCancelAction as String):
                _ = AXHelpers.performAction(control, kAXCancelAction as String, runtime: runtime)
                return MarkerListEditMenuUnknownDiscoveryCleanup(
                    wasClosed: markerListEditMenuIsSettledClosed(
                        under: control, runtime: runtime, mouse: mouse
                    ),
                    cancelActionState: "advertised_and_issued",
                    axStatus: nil
                )
            case .success:
                return MarkerListEditMenuUnknownDiscoveryCleanup(
                    wasClosed: false,
                    cancelActionState: "not_advertised",
                    axStatus: nil
                )
            case .failure(let error):
                return MarkerListEditMenuUnknownDiscoveryCleanup(
                    wasClosed: false,
                    cancelActionState: "unreadable",
                    axStatus: error.raw
                )
            }
        }
    }

    /// Dismiss the exact menu this run observed, then prove it disappeared from the opener's
    /// child list before any focused-key fallback can be considered.
    private static func dismissMarkerListEditMenu(
        _ menu: AXUIElement,
        from control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> Bool {
        _ = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime)
        return markerListEditMenuIsSettledClosed(under: control, runtime: runtime, mouse: mouse)
    }

    /// Only direct entries of the observed Marker List Edit menu are candidates. In particular,
    /// `Delete Undo History` and the Japanese undo-history entry must not be reached through a
    /// prefix or containment search.
    private static func markerListDeleteMenuItem(
        in menu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<AXUIElement?, AXHelpers.AXStatusError> {
        let children: [AXUIElement]
        switch AXHelpers.childrenResult(menu, runtime: runtime) {
        case .success(let observedChildren):
            children = observedChildren
        case .failure(let error):
            return .failure(error)
        }
        for child in children {
            switch AXHelpers.getAttributeResult(
                child, kAXRoleAttribute as String, runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case .success(let role):
                guard role == (kAXMenuItemRole as String) else { continue }
            case .failure(let error):
                return .failure(error)
            }
            switch markerListElementMatches(
                child, labels: AXLocalePolicy.markerListDeleteMenuItem,
                mode: .exactStrict, runtime: runtime
            ) {
            case .success(true):
                return .success(child)
            case .success(false):
                continue
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(nil)
    }

    /// A destructive menu pick needs a readable positive enablement signal. Live Logic 12.3
    /// exposes AXEnabled on every Marker List Edit-menu item, so an unreadable value is not a
    /// reason to guess that a command will act.
    private static func markerListMenuItemEnabledForActuation(
        _ item: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> MarkerListMenuItemEnablement {
        switch AXHelpers.getAttributeResult(
            item, kAXEnabledAttribute as String, runtime: runtime
        ) as Result<Bool?, AXHelpers.AXStatusError> {
        case .success(.some(true)):
            return .enabled
        case .success:
            return .disabled
        case .failure(let error):
            return .unreadable(error)
        }
    }

    private enum MarkerListMenuItemEnablement {
        case enabled
        case disabled
        case unreadable(AXHelpers.AXStatusError)
    }
}
