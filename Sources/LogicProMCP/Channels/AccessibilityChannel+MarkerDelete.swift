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
    /// This operation uses only that scoped AX menu route. A global key cannot be authenticated to
    /// the Marker List and can instead mutate whichever application owns the keyboard, so unavailable
    /// menu routes refuse before a destructive write is attempted.
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
        let before = AXLogicProElements.enumerateMarkersFromListWindow(window, runtime: runtime.ax)
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
        let prewritePositionEvidenceCanonical = before.allSatisfy { $0.positionSource == .parser }
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
            // A weaker key-command channel cannot answer an indexed delete: it ignores `index`
            // and fires CC 45 blindly, without proving which marker would be removed.
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

        case .routeUnavailable(let failure):
            // The only alternate route is an indexed-blind MIDI command, so preserve the router's
            // fallback prohibition while making the no-delete outcome honestly retryable.
            extras["write_attempted"] = false
            extras["safe_to_retry"] = true
            extras["fallback_unsafe"] = true
            extras["edit_menu_route_state"] = failure.state
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: failure.hint,
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
        var settled = false
        var previousPositions: [String]?
        for _ in 0..<6 {
            let reading = AXLogicProElements.enumerateMarkersFromListWindow(
                afterBinding.window, runtime: runtime.ax
            )
            let positions = reading.map(\.position).map(canonicalMarkerPosition).sorted()
            if let previousPositions, previousPositions == positions {
                observedSurvivorPositions = positions
                observedSurvivors = reading
                    .map { canonicalMarkerIdentity(name: $0.name, position: $0.position) }
                    .sorted()
                observedPositionEvidenceCanonical = reading.allSatisfy {
                    $0.positionSource == .parser
                }
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
        extras["position_evidence_canonical"] = prewritePositionEvidenceCanonical
            && observedPositionEvidenceCanonical

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
        guard prewritePositionEvidenceCanonical, observedPositionEvidenceCanonical else {
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
        return MarkerRowSelection(changedSelection: wasAlreadyExactlyTheTarget.map { !$0 })
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
                "The Marker List Edit menu could not be read after opening, so its Delete entry was not picked."
            case .exactDeleteEntryMissingOrDisabled:
                "The Marker List Edit menu's exact Delete entry was missing or disabled, so it was not picked."
            }
        }
    }

    private enum MarkerListEditMenuDeleteOutcome {
        /// `AXPick` was sent to the exact enabled Delete menu item, whatever AX returned. The
        /// associated Boolean is true when this call could not prove the menu later closed.
        case pickIssued(menuCloseWasNotObserved: Bool)
        case routeUnavailable(MarkerListEditMenuRouteFailure)
    }

    /// Use the Marker List's own menu rather than a keyboard Delete. The bottom `Edit` button and the
    /// toolbar `Edit` menu button have the same localized label in Logic 12.3, but only the latter
    /// advertises `AXShowMenu`; inspect action names before deciding which control may be actuated.
    private static func pickDeleteFromMarkerListEditMenu(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> MarkerListEditMenuDeleteOutcome {
        let controls = AXHelpers.findAllDescendants(
            of: window, role: kAXMenuButtonRole as String, maxDepth: 12, runtime: runtime
        ) + AXHelpers.findAllDescendants(
            of: window, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime
        )
        for control in controls {
            guard AXLocalePolicy.elementMatches(
                control, AXLocalePolicy.markerListEditMenuButton,
                mode: .exactStrict, runtime: runtime
            ) else { continue }

            // This is intentionally action discovery, not a press ladder. A live Marker List's
            // bottom Edit AXButton offers AXPress only; pressing it is not a reliable route to its
            // menu. The toolbar AXMenuButton offers AXShowMenu.
            guard AXHelpers.getActionNames(control, runtime: runtime).contains(kAXShowMenuAction as String)
            else { continue }

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
            case .unknown:
                // AXShowMenu may have succeeded even though its scoped child reads failed or
                // disagreed. Attempt AX-only cleanup before honestly reporting unreadable state.
                _ = dismissMarkerListEditMenuAfterUnknownDiscovery(
                    from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(.menuUnreadable)
            }

            guard let entry = markerListDeleteMenuItem(in: menu, runtime: runtime) else {
                _ = dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(.exactDeleteEntryMissingOrDisabled)
            }
            guard markerListMenuItemEnabledForActuation(entry, runtime: runtime) else {
                _ = dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(.exactDeleteEntryMissingOrDisabled)
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
        return .routeUnavailable(.menuAbsent)
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
            return .success(children.first {
                (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuRole as String)
            })
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
        case unknown
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
        var absentReadings = 0
        for _ in 0..<6 {
            switch markerListEditMenu(under: control, runtime: runtime) {
            case .success(let menu?):
                return .present(menu)
            case .success(nil):
                absentReadings += 1
                if absentReadings >= 2 { return .absent }
            case .failure:
                return .unknown
            }
            mouse.sleepMicros(250_000)
        }
        return .unknown
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

    /// Discovery was unknown before it yielded an AXMenu that can receive AXCancel. Re-observe in
    /// case the menu settles; otherwise leave the UI untouched rather than posting a global key.
    private static func dismissMarkerListEditMenuAfterUnknownDiscovery(
        from control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> Bool {
        switch settledMarkerListEditMenuObservation(under: control, runtime: runtime, mouse: mouse) {
        case .present(let menu):
            return dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse)
        case .absent:
            return true
        case .unknown:
            break
        }

        return false
    }

    /// Dismiss the exact menu this run observed, then prove it disappeared from the opener's
    /// child list. This is deliberately AX-only: delete_marker never posts a global key.
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
    ) -> AXUIElement? {
        AXHelpers.getChildren(menu, runtime: runtime).first {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuItemRole as String)
                && AXLocalePolicy.elementMatches(
                    $0, AXLocalePolicy.markerListDeleteMenuItem,
                    mode: .exactStrict, runtime: runtime
                )
        }
    }

    /// A destructive menu pick needs a readable positive enablement signal. Live Logic 12.3
    /// exposes AXEnabled on every Marker List Edit-menu item, so an unreadable value is not a
    /// reason to guess that a command will act.
    private static func markerListMenuItemEnabledForActuation(
        _ item: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let enabled: Bool? = AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime)
        return enabled == true
    }
}
