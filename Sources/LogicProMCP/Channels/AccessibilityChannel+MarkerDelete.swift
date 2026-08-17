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
        guard case .success(let inventory) = AXLogicProElements.markerListInventoryFromListWindow(
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
        let before = inventory.markers
        // `index` names an entry in the one pre-write inventory above. Carry that exact row element
        // through selection; never map the ordinal onto a separately discovered row ordering.
        guard index < before.count, index < inventory.rows.count else {
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
        let target = before[index]
        let targetRow = inventory.rows[index]

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
        let prewriteMarkerIdentities = before.map {
            canonicalMarkerIdentity(name: $0.name, position: $0.position)
        }
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
            "prewrite_marker_identities": prewriteMarkerIdentities,
            "marker_count_before": before.count,
        ]
        // Settle the same way the after-count is settled below: a single unsynced read taken
        // right after `defaultOpenMarkerList` can catch Logic mid-render. This does not gate
        // the write — an unreadable or unsettled pre-write witness still lets the operation
        // proceed, exactly as an unreadable AFTER witness does not retroactively undo an
        // already-issued Delete. It only changes what gets compared against `before.count`
        // below, after the write.
        let prewriteItemCount = settledMarkerListItemCount(
            in: window, runtime: runtime.ax, mouse: mouse
        )
        addMarkerDeleteItemCountObservation(
            prewriteItemCount, phase: .before, to: &extras
        )

        guard let selection = selectMarkerRowForDeletion(
            targetRow, in: inventory.table, runtime: runtime.ax
        ) else {
            // The scoped menu route may proceed only when the selected row is confirmed in this
            // exact Marker List table.
            extras["selection_write_attempted"] = false
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
        extras["selection_write_attempted"] = selection.writeAttempted
        guard selection.confirmed else {
            // The AXSelected write may have landed even though AXSelectedRows could not confirm
            // it. The destructive menu route must not proceed, but the receipt must retain the
            // write attempt rather than claiming the visible selection was untouched.
            extras["write_attempted"] = false
            extras["safe_to_retry"] = true
            extras["fallback_unsafe"] = true
            if let confirmationError = selection.confirmationError {
                extras["selection_state"] = "unreadable"
                extras["selection_ax_status"] = Int(confirmationError.raw)
                return .error(HonestContract.encodeStateC(
                    error: .readbackUnavailable,
                    hint: "Marker index \(index) could not be selected because the Marker List selection could not be read, so nothing was pressed",
                    extras: extras
                ))
            }
            extras["selection_state"] = "not_confirmed"
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Marker index \(index) could not be selected, so nothing was pressed",
                extras: extras
            ))
        }
        // An unreadable pre-write selection is not evidence of either a change or no change.
        // Omit the optional field rather than reporting a Boolean guess.
        if let changedSelection = selection.changedSelection {
            extras["selection_changed"] = changedSelection
        }

        switch pickDeleteFromMarkerListEditMenu(
            in: window,
            targetRow: targetRow,
            selectionTable: inventory.table,
            runtime: runtime.ax,
            mouse: mouse
        ) {
        case .pickIssued(let menuCloseWasNotObserved):
            // `AXPick` status codes are not evidence of whether the menu action took effect. Once
            // issued, proceed directly to readback regardless of the return value.
            extras["write_attempted"] = true
            if menuCloseWasNotObserved {
                // Keep the unresolved menu state and unsafe-retry signal: a retry could reach
                // a still-open menu rather than a fresh Marker List. That observation says
                // nothing about the independently bound table inventory, however. Let the
                // settled survivor proof below determine whether the already-issued delete can
                // be verified.
                extras["safe_to_retry"] = false
                extras["fallback_unsafe"] = true
                extras["menu_state"] = "could_not_be_closed"
            }

        case .routeUnavailable(let failure, let axStatus, let menuState, let menuCancelActionState):
            extras["edit_menu_route_state"] = failure.state
            // "Unreadable" without the status tells a caller nothing it can act on, and cost two
            // rounds of guessing to diagnose live. Report which AX status stopped the route.
            switch failure {
            case .targetSelectionChangedBeforePick:
                extras["target_selection_before_pick"] = "changed"
            case .targetSelectionUnreadableBeforePick:
                extras["target_selection_before_pick"] = "unreadable"
            case .menuAbsent, .menuUnreadable, .exactDeleteEntryMissingOrDisabled:
                break
            }
            if let axStatus {
                switch failure {
                case .targetSelectionUnreadableBeforePick:
                    extras["target_selection_ax_status_before_pick"] = Int(axStatus)
                case .menuAbsent, .menuUnreadable, .exactDeleteEntryMissingOrDisabled,
                        .targetSelectionChangedBeforePick:
                    extras["edit_menu_route_ax_status"] = Int(axStatus)
                }
            }
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
                error: failure.error,
                hint: failure.hint + " No deletion was issued because no element-targeted Marker List route is available.",
                extras: extras
            ))
        }

        // The Marker List enumeration is not stable immediately after a write: measured live, two
        // reads taken back to back can disagree, and a blank row keeps rendering the previous row's
        // name. Verifying against a single read produced a State A for a marker that was still
        // there. So require two consecutive identical readings before believing either of them, and
        // report State B when they will not settle rather than certifying a guess.
        var settledReadback: MarkerDeleteSettledReadback?
        var previousObservation: (
            inventory: MarkerDeleteInventoryReadback,
            targetRowStillSelected: Bool,
            itemCount: MarkerListItemCountRead
        )?
        // Keep the inventory's settled ambiguity distinct from a failed selected-row read. The
        // latter prevents State A, but does not make two agreeing, readable inventories
        // unreadable. If those inventories already establish that a duplicate-position target
        // cannot be identified, State B must say that rather than launder the observation into
        // `readback_unavailable`.
        var previousInventoryReadback: MarkerDeleteInventoryReadback?
        var settledAmbiguousInventory: MarkerDeleteInventoryReadback?
        // A genuine AX rebuild failure voids the entire observation, regardless of whether it
        // arose from AXRows, structural corroboration, or a row cell. Keep the last one only so,
        // if it is still the final poll when the existing budget expires, State B reports that
        // exact site and status without re-resolving the already-bound table.
        var finalTransientReadbackFailure: AXLogicProElements.MarkerListReadFailure?
        // AXRows, AXChildren, and AXSelectedRows are all projections of the same table and can
        // omit the same pre-write row during one rebuild. A failure to read the selection retires
        // this whole poll; it never becomes an answer that the target left the selection. Absence
        // of that pre-write element from AXSelectedRows is not independent deletion evidence.
        var finalTargetSelectionReadbackFailure: AXHelpers.AXStatusError?
        for _ in 0..<6 {
            let reading: [MarkerState]
            switch AXLogicProElements.enumerateMarkersFromListTableWithReadFailure(
                inventory.table, runtime: runtime.ax
            ) {
            case .success(let observedMarkers):
                reading = observedMarkers
                finalTransientReadbackFailure = nil
            case .failure(let failure) where isTransientMarkerReadbackFailure(failure):
                // Every loop turn reads AXRows, structural children, and row cells afresh from
                // the already-bound table. Retiring this turn also retires the prior successful
                // reading, so a later State A still requires two fresh agreeing observations.
                finalTransientReadbackFailure = failure
                finalTargetSelectionReadbackFailure = nil
                previousObservation = nil
                previousInventoryReadback = nil
                settledAmbiguousInventory = nil
                mouse.sleepMicros(250_000)
                continue
            case .failure(let failure):
                extras["readback_settled"] = false
                extras["readback_unreadable"] = true
                addMarkerDeleteReadbackFailure(failure, to: &extras)
                return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
            }

            let inventoryReadback = MarkerDeleteInventoryReadback(
                survivorPositions: reading.map(\.position).map(canonicalMarkerPosition).sorted(),
                survivors: reading
                    .map { canonicalMarkerIdentity(name: $0.name, position: $0.position) }
                    .sorted(),
                positionEvidenceCanonical: !reading.isEmpty
                    && reading.allSatisfy { $0.positionSource == .parser },
                emptySurvivorSet: reading.isEmpty
            )
            if !targetPositionUnique,
               inventoryReadback.survivorPositions.count == before.count - 1,
               inventoryReadback.survivorPositions == expectedSurvivorPositions,
               let previousInventoryReadback,
               previousInventoryReadback.survivorPositions == inventoryReadback.survivorPositions {
                settledAmbiguousInventory = inventoryReadback
            } else {
                settledAmbiguousInventory = nil
            }
            previousInventoryReadback = inventoryReadback

            let targetRowStillSelected: Bool
            switch markerListTargetRowIsSelected(targetRow, in: inventory.table, runtime: runtime.ax) {
            case .success(let selected):
                targetRowStillSelected = selected
                finalTargetSelectionReadbackFailure = nil
            case .failure(let error):
                // A selection read that did not answer cannot be turned into evidence that the
                // deletion changed the selection. Discard the inventory reading too, so the next
                // State A still needs two complete, fresh, agreeing observations.
                finalTargetSelectionReadbackFailure = error
                previousObservation = nil
                mouse.sleepMicros(250_000)
                continue
            }

            let itemCountRead = readMarkerListItemCount(in: window, runtime: runtime.ax)
            if case .unreadable(let error) = itemCountRead, error.isTransientDuringRebuild {
                // Same rule as the inventory: a failed Number of Items read voids this poll,
                // not the already-issued delete.
                finalTransientReadbackFailure = AXLogicProElements.MarkerListReadFailure(
                    site: .itemCount,
                    status: error
                )
                finalTargetSelectionReadbackFailure = nil
                previousObservation = nil
                previousInventoryReadback = nil
                settledAmbiguousInventory = nil
                mouse.sleepMicros(250_000)
                continue
            }
            if case .unreadable(let error) = itemCountRead {
                extras["readback_settled"] = false
                extras["readback_unreadable"] = true
                extras["item_count_witness_state"] = itemCountRead.witnessState
                extras["readback_failure_site"] = AXLogicProElements.MarkerListReadFailureSite
                    .itemCount.rawValue
                extras["readback_ax_status"] = Int(error.raw)
                if let symbolicName = error.symbolicName {
                    extras["readback_ax_status_name"] = symbolicName
                }
                extras["reason_detail"] = itemCountRead.refusalDetail
                return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
            }
            finalTransientReadbackFailure = nil

            if let previousObservation,
               previousObservation.inventory.survivorPositions == inventoryReadback.survivorPositions,
               previousObservation.targetRowStillSelected == targetRowStillSelected,
               previousObservation.itemCount.agrees(with: itemCountRead) {
                settledReadback = MarkerDeleteSettledReadback(
                    inventory: inventoryReadback,
                    targetRowStillSelected: targetRowStillSelected,
                    itemCount: itemCountRead
                )
                break
            }
            previousObservation = (inventoryReadback, targetRowStillSelected, itemCountRead)
            mouse.sleepMicros(250_000)
        }
        let settleOutcome: MarkerDeleteSettleOutcome
        if let settledReadback {
            settleOutcome = .settled(settledReadback)
        } else if let settledAmbiguousInventory {
            settleOutcome = .ambiguousInventory(
                settledAmbiguousInventory,
                targetSelectionReadFailure: finalTargetSelectionReadbackFailure
            )
        } else if let finalTransientReadbackFailure {
            settleOutcome = .unreadableInventory(finalTransientReadbackFailure)
        } else if let finalTargetSelectionReadbackFailure {
            settleOutcome = .unreadableTargetSelection(finalTargetSelectionReadbackFailure)
        } else {
            settleOutcome = .unsettled
        }

        let observedReadback: MarkerDeleteSettledReadback
        switch settleOutcome {
        case .settled(let settledReadback):
            observedReadback = settledReadback
        case .ambiguousInventory(let inventoryReadback, let targetSelectionReadFailure):
            extras["readback_settled"] = false
            addMarkerDeleteInventoryReadback(inventoryReadback, prewritePositionEvidenceCanonical: prewritePositionEvidenceCanonical, to: &extras)
            extras["inventory_readback_state"] = "settled_ambiguous"
            if let targetSelectionReadFailure {
                extras["target_selection_readback_state"] = "unreadable"
                extras["readback_failure_site"] = "selected_rows"
                extras["readback_ax_status"] = Int(targetSelectionReadFailure.raw)
                if let symbolicName = targetSelectionReadFailure.symbolicName {
                    extras["readback_ax_status_name"] = symbolicName
                }
            } else {
                extras["target_selection_readback_state"] = "not_settled"
            }
            extras["reason_detail"] = ambiguousMarkerDeleteReasonDetail(
                targetPositionMatchCount: targetPositionMatchCount,
                targetPosition: target.position
            )
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        case .unreadableInventory(let failure):
            extras["readback_settled"] = false
            extras["readback_unreadable"] = true
            addMarkerDeleteReadbackFailure(failure, to: &extras)
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        case .unreadableTargetSelection(let failure):
            extras["readback_settled"] = false
            extras["readback_unreadable"] = true
            extras["target_selection_readback_state"] = "unreadable"
            extras["readback_failure_site"] = "selected_rows"
            extras["readback_ax_status"] = Int(failure.raw)
            if let symbolicName = failure.symbolicName {
                extras["readback_ax_status_name"] = symbolicName
            }
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        case .unsettled:
            extras["readback_settled"] = false
            // All six inventory reads answered successfully. Do not invent an AX status for a
            // convergence failure: publishing one here would falsely attribute a status that no
            // AX read returned.
            extras["readback_failure_site"] = AXLogicProElements.MarkerListReadFailureSite
                .settleLoop.rawValue
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        extras["readback_settled"] = true
        addMarkerDeleteInventoryReadback(
            observedReadback.inventory,
            prewritePositionEvidenceCanonical: prewritePositionEvidenceCanonical,
            to: &extras
        )
        extras["inventory_readback_state"] = "settled"
        extras["target_selection_readback_state"] = "settled"
        extras["target_row_still_selected_after_pick"] = observedReadback.targetRowStillSelected

        // This proves that precisely one position occurrence disappeared and that it was an
        // occurrence at the target's position. It cannot establish WHICH marker was removed when
        // multiple markers share that position; the position multiset contains no such identity.
        guard observedReadback.inventory.survivorPositions.count == before.count - 1,
              observedReadback.inventory.survivorPositions == expectedSurvivorPositions else {
            // Either the target position survived, or another position disappeared. The
            // name-carrying diagnostics make that mismatch useful to a human without making names
            // part of the stable State-A comparison.
            extras["observed_survivors"] = observedReadback.inventory.survivors
            extras["expected_survivors"] = expectedSurvivors
            extras["reason_detail"] = "The settled survivor set differs from the requested target; a different marker may have been deleted."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }

        // This inventory is readable and settled, but positions are a multiset rather than marker
        // identities. Report the ambiguity before the selection no-op diagnostic: the selection
        // guard still ran and still blocks State A, while this is the more exact State-B reason.
        guard targetPositionUnique else {
            extras["reason_detail"] = ambiguousMarkerDeleteReasonDetail(
                targetPositionMatchCount: targetPositionMatchCount,
                targetPosition: target.position
            )
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }

        // A surviving target selection is a direct observed no-op, even if AXRows and AXChildren
        // happened to agree on an omitted row. Never certify the deletion while the exact row
        // selected for Delete remains selected. This guard follows the two-reading settle so it
        // is based on a complete agreeing observation rather than one unstable poll.
        guard !observedReadback.targetRowStillSelected else {
            extras["reason_detail"] = "The exact target row remained selected after the Delete pick, so the settled row omission is not sufficient evidence of deletion."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        extras["expected_survivor_position_multiset"] = expectedSurvivorPositions.joined()
        extras["observed_survivor_position_multiset"] = observedReadback.inventory.survivorPositions.joined()
        guard prewritePositionEvidenceCanonical,
              observedReadback.inventory.emptySurvivorSet
                || observedReadback.inventory.positionEvidenceCanonical else {
            extras["reason_detail"] = "Delete was attempted and the marker count moved, but at "
                + "least one marker position came from an ordinal parse fallback; synthetic "
                + "positions cannot support a verified target identity."
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        // AXRows, AXChildren, and AXSelectedRows can all omit the pre-write row because the
        // table rebuilt. Logic's own Number of Items rendering is not a projection of that
        // table. State A needs both that independently-read count dropping by one and the
        // settled survivor multiset agreeing; neither witness is enough alone.
        addMarkerDeleteItemCountObservation(
            observedReadback.itemCount, phase: .after, to: &extras
        )
        guard let observedCountBefore = prewriteItemCount.parsedCount,
              let observedCountAfter = observedReadback.itemCount.parsedCount else {
            extras["reason_detail"] = observedReadback.itemCount.parsedCount == nil
                ? observedReadback.itemCount.refusalDetail
                : prewriteItemCount.refusalDetail
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        // The pre-write witness must corroborate the pre-write TABLE inventory, not merely be
        // present. Without this, a pre-write count that is already wrong (stale render, wrong
        // node, a decoy) combines with a rebuild that omits the target from the table's own
        // projections to certify a delete that never happened: the after-count would still
        // read exactly one less than the (wrong) before-count.
        guard observedCountBefore == before.count else {
            extras["reason_detail"] =
                "The Marker List Number of Items count before the delete (observed "
                + "\(observedCountBefore)) did not agree with the pre-write table inventory "
                + "(\(before.count) markers), so this independent witness cannot corroborate "
                + "the delete."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        guard observedCountAfter == observedCountBefore - 1 else {
            extras["reason_detail"] =
                "The Marker List Number of Items count did not drop by one (observed "
                + "\(observedCountBefore) → \(observedCountAfter)) while the settled table "
                + "inventory claimed the target left."
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    /// The inventory records only position occurrences. A duplicate position is a readable
    /// observation whose limitation is ambiguity, not an unavailable AX readback.
    private static func ambiguousMarkerDeleteReasonDetail(
        targetPositionMatchCount: Int,
        targetPosition: String
    ) -> String {
        "Delete was attempted and the marker count moved, but "
            + "\(targetPositionMatchCount) pre-write markers shared target position "
            + "\(targetPosition), so this readback cannot establish which marker was deleted."
    }

    /// One successfully enumerated post-write Marker List inventory. It deliberately has no
    /// selection result: the table inventory and AXSelectedRows are different measurements.
    private struct MarkerDeleteInventoryReadback {
        let survivorPositions: [String]
        let survivors: [String]
        let positionEvidenceCanonical: Bool
        let emptySurvivorSet: Bool
    }

    /// State-A requires a settled inventory, an agreeing selected-row observation, and
    /// Logic's independently rendered Number of Items count.
    private struct MarkerDeleteSettledReadback {
        let inventory: MarkerDeleteInventoryReadback
        let targetRowStillSelected: Bool
        let itemCount: MarkerListItemCountRead
    }

    /// One read of the Marker List window's own Number of Items node.
    ///
    /// A parsed integer is the only value that may be published as
    /// `observed_marker_count_*`. Missing, ambiguous, or unparseable text is an
    /// unreadable witness, not a count of zero.
    private enum MarkerListItemCountRead: Equatable {
        case parsed(Int, raw: String)
        case unparseable(raw: String)
        case missing
        case ambiguous
        case unreadable(AXHelpers.AXStatusError)

        static let unreadableWitnessDetail =
            "The Marker List Number of Items count was unreadable as an independent deletion witness."

        var refusalDetail: String {
            switch self {
            case .unparseable:
                return "The Marker List Number of Items count was unreadable: the value could not be parsed."
            case .missing, .ambiguous, .unreadable, .parsed:
                return Self.unreadableWitnessDetail
            }
        }

        var parsedCount: Int? {
            if case .parsed(let count, _) = self { return count }
            return nil
        }

        var rawText: String? {
            switch self {
            case .parsed(_, let raw), .unparseable(let raw):
                return raw
            case .missing, .ambiguous, .unreadable:
                return nil
            }
        }

        var witnessState: String {
            switch self {
            case .parsed:
                return "readable"
            case .unparseable:
                return "unparseable"
            case .missing, .ambiguous, .unreadable:
                return "unreadable"
            }
        }

        func agrees(with other: MarkerListItemCountRead) -> Bool {
            switch (self, other) {
            case (.parsed(let left, _), .parsed(let right, _)):
                return left == right
            case (.unparseable, .unparseable),
                 (.missing, .missing),
                 (.ambiguous, .ambiguous):
                return true
            default:
                return false
            }
        }
    }

    private enum MarkerListItemCountPhase {
        case before
        case after
    }

    private static func addMarkerDeleteItemCountObservation(
        _ observation: MarkerListItemCountRead,
        phase: MarkerListItemCountPhase,
        to extras: inout [String: Any]
    ) {
        let countKey: String
        let textKey: String
        let stateKey: String
        switch phase {
        case .before:
            countKey = "observed_marker_count_before"
            textKey = "observed_marker_count_text_before"
            stateKey = "item_count_witness_state_before"
        case .after:
            countKey = "observed_marker_count_after"
            textKey = "observed_marker_count_text_after"
            stateKey = "item_count_witness_state"
        }
        if let count = observation.parsedCount {
            extras[countKey] = count
        }
        if let raw = observation.rawText {
            extras[textKey] = raw
        }
        extras[stateKey] = observation.witnessState
    }

    /// Reads the Number of Items witness repeatedly until two consecutive reads agree, or a
    /// fixed budget is spent — the same settle discipline the post-write loop applies to the
    /// table inventory, selection, and this same witness. A momentary AX hiccup on ONE read
    /// must not certify (or falsely poison) a value that a second read would have confirmed
    /// or corrected. If the budget is spent without two agreeing reads, the LAST reading is
    /// returned rather than manufacturing a status the AX API never returned; a caller that
    /// needs the value to be trustworthy still requires `.parsedCount` downstream.
    private static func settledMarkerListItemCount(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> MarkerListItemCountRead {
        var previous: MarkerListItemCountRead?
        for _ in 0..<6 {
            let reading = readMarkerListItemCount(in: window, runtime: runtime)
            if let previous, previous.agrees(with: reading) {
                return reading
            }
            previous = reading
            mouse.sleepMicros(250_000)
        }
        return previous ?? .missing
    }

    /// Reads the Marker List's Number of Items static text by AXDescription, never
    /// by sibling position. The live node is under an AXGroup described "Marker";
    /// its value is Logic's own rendering (`"1 Marker"`, `"15 Markers"`).
    private static func readMarkerListItemCount(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> MarkerListItemCountRead {
        switch AXLogicProElements.markerListNumberOfItemsNodes(in: window, runtime: runtime) {
        case .failure(let error):
            return .unreadable(error)
        case .success(let nodes) where nodes.isEmpty:
            return .missing
        case .success(let nodes) where nodes.count > 1:
            return .ambiguous
        case .success(let nodes):
            let node = nodes[0]
            switch AXHelpers.getAttributeResult(
                node, kAXValueAttribute as String, runtime: runtime
            ) as Result<AnyObject?, AXHelpers.AXStatusError> {
            case .failure(let error):
                return .unreadable(error)
            case .success(let value):
                let raw: String
                if let string = value as? String {
                    raw = string
                } else if let number = value as? NSNumber {
                    raw = number.stringValue
                } else {
                    return .unparseable(raw: "")
                }
                guard let parsed = AXLogicProElements.parseMarkerListItemCount(raw) else {
                    return .unparseable(raw: raw)
                }
                return .parsed(parsed, raw: raw)
            }
        }
    }


    /// The terminal outcome of the fixed six-poll settle budget. Keeping these cases separate
    /// prevents a readable ambiguous inventory from being reported as an unreadable readback
    /// merely because the independent selected-row measurement did not settle.
    private enum MarkerDeleteSettleOutcome {
        case settled(MarkerDeleteSettledReadback)
        case ambiguousInventory(
            MarkerDeleteInventoryReadback,
            targetSelectionReadFailure: AXHelpers.AXStatusError?
        )
        case unreadableInventory(AXLogicProElements.MarkerListReadFailure)
        case unreadableTargetSelection(AXHelpers.AXStatusError)
        case unsettled
    }

    private static func addMarkerDeleteInventoryReadback(
        _ inventoryReadback: MarkerDeleteInventoryReadback,
        prewritePositionEvidenceCanonical: Bool,
        to extras: inout [String: Any]
    ) {
        extras["marker_count_after"] = inventoryReadback.survivorPositions.count
        extras["observed_position_evidence_canonical"] = inventoryReadback.positionEvidenceCanonical
        extras["observed_empty_survivor_set"] = inventoryReadback.emptySurvivorSet
        extras["position_evidence_canonical"] = prewritePositionEvidenceCanonical
            && (inventoryReadback.emptySurvivorSet || inventoryReadback.positionEvidenceCanonical)
    }

    /// A real AX failure during a rebuild makes this complete poll unreadable; the next poll must
    /// start over from the same bound table. The status classification intentionally lives on the
    /// AX result, not on a named marker-list site. A reader-created corroboration mismatch uses
    /// the same diagnostic status but is a failed observation, not an AX failure to retry.
    private static func isTransientMarkerReadbackFailure(
        _ failure: AXLogicProElements.MarkerListReadFailure
    ) -> Bool {
        failure.origin == .axRead && failure.status.isTransientDuringRebuild
    }

    /// Adds diagnostic-only detail to a post-write State-B receipt. Every value comes from the
    /// failed read that already determined the State-B outcome; no additional AX read is made.
    private static func addMarkerDeleteReadbackFailure(
        _ failure: AXLogicProElements.MarkerListReadFailure,
        to extras: inout [String: Any]
    ) {
        extras["readback_failure_site"] = failure.site.rawValue
        extras["readback_ax_status"] = Int(failure.status.raw)
        if let symbolicName = failure.status.symbolicName {
            extras["readback_ax_status_name"] = symbolicName
        }
        if let axRowsCount = failure.axRowsCount,
           let structuralChildrenCount = failure.structuralChildrenCount {
            extras["readback_ax_rows_count"] = axRowsCount
            extras["readback_structural_children_count"] = structuralChildrenCount
        }
        // A persistently-failing item-count witness (e.g. a subtree that never stops
        // answering -25200) exhausts the settle budget one poll at a time and surfaces here
        // rather than through the single-read `.unreadable` branch below. Either path is the
        // same observed fact — this witness could not be read — so both must publish the same
        // `item_count_witness_state` a caller can check without branching on which site failed.
        if failure.site == .itemCount {
            extras["item_count_witness_state"] = "unreadable"
        }
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
        let writeAttempted: Bool
        let confirmed: Bool
        let changedSelection: Bool?
        let confirmationError: AXHelpers.AXStatusError?
    }

    /// Selects the row and confirms the table agrees, since a write that reports success without
    /// changing the selection would leave the Edit-menu Delete command pointed at whatever was selected before.
    private static func selectMarkerRowForDeletion(
        _ targetRow: AXUIElement,
        in table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> MarkerRowSelection? {
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
                && CFEqual(selectedRows[0], targetRow)
        case .failure:
            // A failed read cannot establish whether selecting this row altered anything.
            wasAlreadyExactlyTheTarget = nil
        }
        _ = AXHelpers.setAttribute(
            targetRow, kAXSelectedAttribute as String, kCFBooleanTrue, runtime: runtime
        )
        switch AXHelpers.getAttributeResult(
            table, "AXSelectedRows", runtime: runtime
        ) as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
        case .success(let selectedRows):
            let selected = selectedRows ?? []
            guard selected.count == 1, CFEqual(selected[0], targetRow) else {
                return MarkerRowSelection(
                    writeAttempted: true,
                    confirmed: false,
                    changedSelection: nil,
                    confirmationError: nil
                )
            }
            return MarkerRowSelection(
                writeAttempted: true,
                confirmed: true,
                changedSelection: wasAlreadyExactlyTheTarget.map { !$0 },
                confirmationError: nil
            )
        case .failure(let error):
            // A failed post-write read is not an empty successful selection. The destructive
            // route must refuse with that distinction intact for the caller's receipt.
            return MarkerRowSelection(
                writeAttempted: true,
                confirmed: false,
                changedSelection: nil,
                confirmationError: error
            )
        }
    }

    /// Whether attempting the Marker List's own Edit → Delete menu path reached a destructive
    /// actuator. AX action status is deliberately absent from this outcome: an `AXPick` that
    /// reports failure can still delete the marker.
    private enum MarkerListEditMenuRouteFailure {
        case menuAbsent
        case menuUnreadable
        case exactDeleteEntryMissingOrDisabled
        case targetSelectionChangedBeforePick
        case targetSelectionUnreadableBeforePick

        var state: String {
            switch self {
            case .menuAbsent: "menu_absent"
            case .menuUnreadable: "menu_unreadable"
            case .exactDeleteEntryMissingOrDisabled: "exact_delete_entry_missing_or_disabled"
            case .targetSelectionChangedBeforePick: "target_selection_changed_before_pick"
            case .targetSelectionUnreadableBeforePick: "target_selection_unreadable_before_pick"
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
            case .targetSelectionChangedBeforePick:
                "The bound Marker List row was no longer the sole selection immediately before Delete, so it was not picked."
            case .targetSelectionUnreadableBeforePick:
                "The Marker List selection could not be read immediately before Delete, so it was not picked."
            }
        }

        var error: HonestContract.FailureError {
            switch self {
            case .targetSelectionUnreadableBeforePick:
                .readbackUnavailable
            case .menuAbsent, .menuUnreadable, .exactDeleteEntryMissingOrDisabled,
                    .targetSelectionChangedBeforePick:
                .axWriteFailed
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
        targetRow: AXUIElement,
        selectionTable: AXUIElement,
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
                under: control, question: .discovery, runtime: runtime, mouse: mouse
            ) {
            case .present(let observedMenu):
                menu = observedMenu
            case .absent:
                // `AXShowMenu` has already been issued. Two scoped absent reads establish only
                // that this opener does not currently vend a menu; they cannot establish that a
                // detached menu did not open elsewhere. Do not advertise a clean retry or claim
                // that there is no open menu on the strength of this scoped observation.
                return .routeUnavailable(.menuAbsent, menuState: "could_not_be_closed")
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
                let menuWasClosed = dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(
                    .exactDeleteEntryMissingOrDisabled,
                    menuState: menuWasClosed ? nil : "could_not_be_closed"
                )
            case .failure(let error):
                let menuWasClosed = dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(
                    .menuUnreadable,
                    axStatus: error.raw,
                    menuState: menuWasClosed ? nil : "could_not_be_closed"
                )
            }
            switch markerListMenuItemEnabledForActuation(entry, runtime: runtime) {
            case .enabled:
                break
            case .disabled:
                let menuWasClosed = dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(
                    .exactDeleteEntryMissingOrDisabled,
                    menuState: menuWasClosed ? nil : "could_not_be_closed"
                )
            case .unreadable(let error):
                let menuWasClosed = dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(
                    .menuUnreadable,
                    axStatus: error.raw,
                    menuState: menuWasClosed ? nil : "could_not_be_closed"
                )
            }

            // Delete acts on CURRENT selection, not on the row element carried from inventory.
            // Re-read the bound table immediately before the sole AXPick so an intervening user
            // or application selection change cannot redirect the destructive menu command. AX
            // offers no atomic select-and-pick, so a change after this read remains possible; the
            // settled survivor mismatch below is the only honest way to report that residual gap.
            switch markerListTargetRowIsSelected(targetRow, in: selectionTable, runtime: runtime) {
            case .success(true):
                break
            case .success(false):
                let menuWasClosed = dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(
                    .targetSelectionChangedBeforePick,
                    menuState: menuWasClosed ? nil : "could_not_be_closed"
                )
            case .failure(let error):
                let menuWasClosed = dismissMarkerListEditMenu(
                    menu, from: control, runtime: runtime, mouse: mouse
                )
                return .routeUnavailable(
                    .targetSelectionUnreadableBeforePick,
                    axStatus: error.raw,
                    menuState: menuWasClosed ? nil : "could_not_be_closed"
                )
            }

            // Do not use the return value to select another actuator. This one call is the write.
            _ = AXHelpers.performAction(entry, kAXPickAction as String, runtime: runtime)
            // AXPick normally closes a menu itself. Only a successful read that finds no menu is
            // twice in a row is proof of that disappearance; a present, unstable, or unreadable
            // child list is still open/unknown and requires cleanup before this run can proceed.
            let menuCloseWasNotObserved = !markerListEditMenuIsSettledClosed(
                under: control,
                relationshipWasObserved: true,
                runtime: runtime,
                mouse: mouse
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

    /// Confirms the exact row carried from the one pre-write inventory is still the sole selection
    /// just before the Delete actuator. A successful nil `AXSelectedRows` value is a readable empty
    /// selection; an AX failure remains unreadable and must not be flattened into that answer.
    private static func markerListTargetRowIsSelected(
        _ targetRow: AXUIElement,
        in table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<Bool, AXHelpers.AXStatusError> {
        switch AXHelpers.getAttributeResult(
            table, "AXSelectedRows", runtime: runtime
        ) as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
        case .success(let selectedRows):
            let selected = selectedRows ?? []
            return .success(selected.count == 1 && CFEqual(selected[0], targetRow))
        case .failure(let error):
            return .failure(error)
        }
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
    private enum MarkerListEditMenuQuestion {
        /// Before any menu is observed, absence says the opener does not currently vend one.
        case discovery
        /// After an exact menu was observed, absence asks whether that relationship disappeared.
        case observedMenuClosure
    }

    private static func markerListEditMenu(
        under control: AXUIElement,
        question: MarkerListEditMenuQuestion,
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
        case .failure(let error) where error.isDefinitiveAbsence:
            switch question {
            case .discovery:
                // Before a menu was seen, AXChildren absence answers the opener question: it has
                // no menu exposed on this poll.
                return .success(nil)
            case .observedMenuClosure:
                // Once this run saw a specific menu, an absent AXChildren attribute cannot prove
                // that menu disappeared. It only says the opener→menu relationship is unreadable.
                return .failure(error)
            }
        case .failure(let error):
            return .failure(error)
        }
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
        question: MarkerListEditMenuQuestion,
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
            switch markerListEditMenu(under: control, question: question, runtime: runtime) {
            case .success(let menu?):
                return .present(menu)
            case .success(nil):
                absentReadings += 1
                if absentReadings >= 2 { return .absent }
            case .failure(let error):
                // A failed read retires this poll and breaks the consecutive-absence run. The
                // next absence starts a fresh observation rather than completing an old one.
                absentReadings = 0
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
        relationshipWasObserved: Bool,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> Bool {
        if case .absent = settledMarkerListEditMenuObservation(
            under: control,
            question: relationshipWasObserved ? .observedMenuClosure : .discovery,
            runtime: runtime,
            mouse: mouse
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
    /// require a settled closed observation before reporting that cleanup restored the UI state.
    private static func dismissMarkerListEditMenuAfterUnknownDiscovery(
        from control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> MarkerListEditMenuUnknownDiscoveryCleanup {
        switch settledMarkerListEditMenuObservation(
            under: control, question: .discovery, runtime: runtime, mouse: mouse
        ) {
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
                        under: control,
                        relationshipWasObserved: false,
                        runtime: runtime,
                        mouse: mouse
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
    /// child list before treating cleanup as complete.
    private static func dismissMarkerListEditMenu(
        _ menu: AXUIElement,
        from control: AXUIElement,
        runtime: AXHelpers.Runtime,
        mouse: AXMouseHelper.Runtime
    ) -> Bool {
        _ = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime)
        return markerListEditMenuIsSettledClosed(
            under: control,
            relationshipWasObserved: true,
            runtime: runtime,
            mouse: mouse
        )
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
        var unreadable: AXHelpers.AXStatusError?
        for child in children {
            switch AXHelpers.getAttributeResult(
                child, kAXRoleAttribute as String, runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case .success(let role):
                guard role == (kAXMenuItemRole as String) else { continue }
            case .failure(let error) where error.isDefinitiveAbsence:
                continue
            case .failure(let error):
                // An unrelated separator or transient entry can fail its role read while a later
                // exact Delete item remains fully readable. Keep searching, but do not turn an
                // exhausted unreadable search into a definitive "missing" answer.
                unreadable = unreadable ?? error
                continue
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
                unreadable = unreadable ?? error
                continue
            }
        }
        if let unreadable { return .failure(unreadable) }
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
