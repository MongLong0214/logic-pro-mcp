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
    ///   * with the row selected AND keyboard focus inside the Marker table, a Delete key removes it.
    ///
    /// That last condition is the whole safety story. The same keystroke sent while focus sits in the
    /// arrange area deletes the selected REGION or TRACK instead. So focus is verified to be inside
    /// the marker table immediately before the key is posted, and the operation refuses otherwise
    /// rather than pressing Delete somewhere unknown.
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

        // Selecting a row is itself an AX write and moves the visible selection.  `write_attempted`
        // remains scoped to the destructive Delete key, but a refusal after this point must disclose
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

        var menuCloseWasNotObserved = false
        var menuDiscoveryWasUnreadable = false
        switch pickDeleteFromMarkerListEditMenu(
            in: window,
            runtime: runtime.ax,
            mouse: mouse,
            menuCloseWasNotObserved: &menuCloseWasNotObserved,
            menuDiscoveryWasUnreadable: &menuDiscoveryWasUnreadable
        ) {
        case .pickIssued:
            // `AXPick` status codes are not evidence of whether the menu action took effect. Once
            // issued, a Delete key would be a second destructive actuator, so proceed directly to
            // readback regardless of the return value.
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

        case .menuUnavailable, .exactEntryNotFound, .entryNotActuable:
            guard !menuDiscoveryWasUnreadable else {
                // AXShowMenu was issued, but the exact opener's child list could not be read.
                // Even if cleanup subsequently observed closure, that failed discovery is not
                // permission to aim a weaker Delete actuator at the UI that just held a menu.
                extras["write_attempted"] = false
                extras["fallback_unsafe"] = true
                if menuCloseWasNotObserved {
                    extras["safe_to_retry"] = false
                    extras["menu_state"] = "could_not_be_closed"
                    return .error(HonestContract.encodeStateC(
                        error: .axWriteFailed,
                        hint: "The Marker List Edit menu could not be closed, so Delete was not pressed.",
                        extras: extras
                    ))
                }
                extras["safe_to_retry"] = true
                extras["menu_state"] = "closed_after_unreadable_discovery"
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "The Marker List Edit menu could not be read after opening; it was dismissed and Delete was not pressed.",
                    extras: extras
                ))
            }
            guard !menuCloseWasNotObserved else {
                // No Delete actuator has been sent on this path, but a key fallback could land in
                // the still-open menu. This is therefore not a clean, retryable focus refusal.
                extras["write_attempted"] = false
                extras["safe_to_retry"] = false
                extras["fallback_unsafe"] = true
                extras["menu_state"] = "could_not_be_closed"
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "The Marker List Edit menu could not be closed, so Delete was not pressed.",
                    extras: extras
                ))
            }
            guard markerTableHasKeyboardFocus(
                table: selection.table,
                in: binding.window,
                runtime: runtime
            ) else {
                // Refusing here is the point: the same keystroke elsewhere deletes a region or a track.
                // Nothing was deleted, so a caller may retry after restoring Marker List focus.
                extras["write_attempted"] = false
                extras["safe_to_retry"] = true
                extras["fallback_unsafe"] = true
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "The Marker List did not hold keyboard focus, so Delete was not pressed — "
                        + "the same key deletes a region or a track when focus is in the arrange area.",
                    extras: extras
                ))
            }

            extras["write_attempted"] = true
            _ = mouse.postKeyEvent(0x33)  // kVK_Delete
            mouse.sleepMicros(400_000)
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

    /// Selects the row and confirms the table agrees, since a write that reports success without
    /// changing the selection would leave Delete pointed at whatever was selected before.
    private static func selectMarkerRowForDeletion(
        _ index: Int,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> (table: AXUIElement, changedSelection: Bool?)? {
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
        return (table: table, changedSelection: wasAlreadyExactlyTheTarget.map { !$0 })
    }

    /// True only when focus lives in the exact table selected above, in the exact Marker List
    /// window that was bound to the active project.  A label/type test is insufficient: two open
    /// projects can both have a table that looks like a Marker List, while Delete acts on whichever
    /// one actually owns keyboard focus.
    private static func markerTableHasKeyboardFocus(
        table: AXUIElement,
        in window: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let focused: AXUIElement = AXHelpers.getAttribute(
                  app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax
              ) else { return false }
        var current: AXUIElement? = focused
        var focusedTable: AXUIElement?
        var hops = 0
        while let element = current, hops < 12 {
            if (AXHelpers.getRole(element, runtime: runtime.ax) ?? "") == (kAXTableRole as String) {
                focusedTable = element
                break
            }
            current = AXHelpers.getAttribute(
                element, kAXParentAttribute as String, runtime: runtime.ax
            )
            hops += 1
        }
        guard let focusedTable, CFEqual(focusedTable, table) else { return false }

        current = focusedTable
        hops = 0
        while let element = current, hops < 12 {
            if (AXHelpers.getRole(element, runtime: runtime.ax) ?? "") == (kAXWindowRole as String) {
                return CFEqual(element, window)
            }
            current = AXHelpers.getAttribute(
                element, kAXParentAttribute as String, runtime: runtime.ax
            )
            hops += 1
        }
        return false
    }

    private static func ancestryMentionsMarker(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < 6 {
            let description = AXHelpers.getAttribute(
                node, kAXDescriptionAttribute as String, runtime: runtime
            ) as String? ?? ""
            if AXLocalePolicy.markerContainerKeywords.matches(description, mode: .contains) { return true }
            current = AXHelpers.getAttribute(node, kAXParentAttribute as String, runtime: runtime)
            hops += 1
        }
        return false
    }

    /// Whether attempting the Marker List's own Edit → Delete menu path reached a destructive
    /// actuator. AX action status is deliberately absent from this outcome: an `AXPick` that
    /// reports failure can still delete the marker, and a second actuator after it would be unsafe.
    private enum MarkerListEditMenuDeleteOutcome {
        /// `AXPick` was sent to the exact enabled Delete menu item, whatever AX returned.
        case pickIssued
        /// The Edit menu could not be observed after an eligible opener was asked to show it.
        case menuUnavailable
        /// An observed menu did not contain the exact Delete command.
        case exactEntryNotFound
        /// The exact command was present but cannot safely be picked.
        case entryNotActuable
    }

    /// Prefer the Marker List's own menu over a keyboard Delete. The bottom `Edit` button and the
    /// toolbar `Edit` menu button have the same localized label in Logic 12.3, but only the latter
    /// advertises `AXShowMenu`; inspect action names before deciding which control may be actuated.
    private static func pickDeleteFromMarkerListEditMenu(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime,
        menuCloseWasNotObserved: inout Bool,
        menuDiscoveryWasUnreadable: inout Bool
    ) -> MarkerListEditMenuDeleteOutcome {
        let controls = AXHelpers.findAllDescendants(
            of: window, role: kAXMenuButtonRole as String, maxDepth: 12, runtime: runtime
        ) + AXHelpers.findAllDescendants(
            of: window, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime
        )
        var observedMenu = false

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
            // after issuing AXShowMenu; without an observed menu, no deletion action has been sent.
            _ = AXHelpers.performAction(control, kAXShowMenuAction as String, runtime: runtime)
            let menu: AXUIElement
            switch markerListEditMenu(under: control, runtime: runtime) {
            case .success(let observedMenu?):
                menu = observedMenu
            case .success(nil):
                continue
            case .failure:
                // AXShowMenu may have succeeded even though its scoped child read failed. Clean
                // up what may be open, but never let this unknown state reach the Delete fallback.
                menuDiscoveryWasUnreadable = true
                menuCloseWasNotObserved = !dismissMarkerListEditMenuAfterUnreadableDiscovery(
                    from: control, runtime: runtime, mouse: mouse
                )
                return .menuUnavailable
            }
            observedMenu = true

            guard let entry = markerListDeleteMenuItem(in: menu, runtime: runtime) else {
                menuCloseWasNotObserved = !dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .exactEntryNotFound
            }
            guard markerListMenuItemEnabledForActuation(entry, runtime: runtime) else {
                menuCloseWasNotObserved = !dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .entryNotActuable
            }

            // Do not use the return value to select another actuator. This one call is the write.
            _ = AXHelpers.performAction(entry, kAXPickAction as String, runtime: runtime)
            // AXPick normally closes a menu itself. Only a successful read that finds no menu is
            // proof of that disappearance; an unreadable child list is still open/unknown and
            // requires cleanup before this run can proceed.
            if markerListEditMenuClosureState(under: control, runtime: runtime) != .closed {
                menuCloseWasNotObserved = !dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
            }
            return .pickIssued
        }
        return observedMenu ? .exactEntryNotFound : .menuUnavailable
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
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The only state that authorises a fallthrough is an AX children read that succeeds and finds
    /// no menu below the exact opener. A failed read is open-or-unknown, never closed.
    private enum MarkerListEditMenuClosureState {
        case closed
        case openOrUnknown
    }

    private static func markerListEditMenuClosureState(
        under control: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> MarkerListEditMenuClosureState {
        switch markerListEditMenu(under: control, runtime: runtime) {
        case .success(let menu):
            return menu == nil ? .closed : .openOrUnknown
        case .failure:
            return .openOrUnknown
        }
    }

    /// Discovery failed before it yielded an AXMenu that can receive AXCancel. Re-read once in
    /// case the failure was transient; if the menu becomes observable, dismiss it normally.
    /// Otherwise, bounded Escape is the only available coordinate-free dismissal and every try is
    /// followed by a status-preserving closure observation.
    private static func dismissMarkerListEditMenuAfterUnreadableDiscovery(
        from control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> Bool {
        switch markerListEditMenu(under: control, runtime: runtime) {
        case .success(let menu?):
            return dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse)
        case .success(nil):
            return true
        case .failure:
            break
        }

        for _ in 0..<3 {
            AXMouseHelper.pressEscape(runtime: mouse)
            mouse.sleepMicros(100_000)
            switch markerListEditMenu(under: control, runtime: runtime) {
            case .success(nil):
                return true
            case .success(let menu?):
                return dismissMarkerListEditMenu(menu, from: control, runtime: runtime, mouse: mouse)
            case .failure:
                continue
            }
        }
        return false
    }

    /// Dismiss the exact menu this run observed, then prove it disappeared from the opener's
    /// child list. AXCancel is only the first mechanism: like transport's `dismissOpenMenu`, use
    /// a bounded Escape escalation and observe after every attempt.
    private static func dismissMarkerListEditMenu(
        _ menu: AXUIElement,
        from control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> Bool {
        _ = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime)
        if markerListEditMenuClosureState(under: control, runtime: runtime) == .closed {
            return true
        }

        for _ in 0..<3 {
            AXMouseHelper.pressEscape(runtime: mouse)
            mouse.sleepMicros(100_000)
            if markerListEditMenuClosureState(under: control, runtime: runtime) == .closed {
                return true
            }
        }
        return false
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
