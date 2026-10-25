@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    @TaskLocal static var sendRemovalObserver: (@Sendable (RemovedSendObservation) -> Void)?
    @TaskLocal static var sendChangeObserver: (@Sendable (ChangedSendObservation) -> Void)?

    /// Finite occupied-route changes that can publish an actual native inverse capsule.
    /// A typed pair alone grants no action or ownership; the native boundary proves both.
    static func supportsOccupiedSendChange(before: OutputAssignment, after: OutputAssignment) -> Bool {
        switch (before, after) {
        case (.stereoOutput, .bus), (.stereoOutput, .physical), (.physical, .stereoOutput),
             (.bus, .stereoOutput): true
        case (.bus(let original), .bus(let requested)): original != requested
        default: false
        }
    }

    /// Native occupied-slot custody after one independently verified change.
    /// The prior checked destination is inverse data, not permission to act.
    struct ChangedSendObservation: @unchecked Sendable {
        let source: OriginalHeaderSourceRenewal
        let control: AXLogicProElements.AssignedSendMenuControl
        let footprint: [SendSlotObservation]
        let checkedBefore: OutputAssignment
        let checkedAfter: OutputAssignment
        let nonRoutingChecks: [String]
        let population: [AXUIElement]

        static func protectedSlots(_ slots: [SendSlotObservation], ordinal: Int) -> [SendSlotObservation] {
            slots.map { slot in
                var result = slot
                if result.ordinal == ordinal { result.destinationDisplay = nil }
                return result
            }
        }

        /// Continue only the already-verified effect through its owned Input
        /// read. Checked destination/mode remain historical expectations, not
        /// a fresh observation: the deciding inverse popup must corroborate
        /// both before any leaf action. The caller retains this current capsule
        /// before the Input read; labels, ordinals and read custody cannot create it.
        func continuingForDecidingInverse(after renewal: OriginalHeaderSourceRenewal,
                        control current: AXLogicProElements.AssignedSendMenuControl,
                        slots: [SendSlotObservation], runtime: AXLogicProElements.Runtime) -> Self? {
            guard case .bus = checkedBefore,
                  AccessibilityChannel.supportsOccupiedSendChange(before: checkedBefore, after: checkedAfter),
                  renewal.original.matches(source.pair.strip), renewal.originalTrack.matches(source.pair.track),
                  renewal.observation.effects.restoration == "restored", renewal.permits(runtime: runtime),
                  current.ordinal == control.ordinal,
                  slots.count == 2, slots.filter({ $0.state == .occupiedUnknownDestination }).count == 1,
                  slots.filter({ $0.state == .observedEmpty }).count == 1,
                  Self.protectedSlots(slots, ordinal: control.ordinal)
                    == Self.protectedSlots(footprint, ordinal: control.ordinal) else { return nil }
            let continued = Self(source: renewal, control: current, footprint: slots,
                checkedBefore: checkedBefore, checkedAfter: checkedAfter, nonRoutingChecks: nonRoutingChecks,
                population: renewal.observation.strips)
            return continued.permits(runtime: runtime) ? continued : nil
        }

        func permits(runtime: AXLogicProElements.Runtime, ownedPopup: AXUIElement? = nil) -> Bool {
            // Role/Children samples inside the control scan can observe scope
            // loss. Its later bookend cannot authorize intervening Help reads.
            let outer = AXHelpers.HelpReadGuard.current
            return AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: {
                outer?.permits() == false || !(ownedPopup.map {
                    source.observation.permitsOwnedPopupRead($0)
                } ?? source.observation.permitsRead())
            })) {
                var controls: [AXLogicProElements.AssignedSendMenuControl] = []
                guard source.permits(runtime: runtime, ownedPopup: ownedPopup),
                      // One complete current walk supplies both the physical
                      // control and its protected values; neither is an old receipt.
                      let slots = AXLogicProElements.sendSlotObservations(in: source.pair.strip.strip,
                        runtime: runtime.ax, observingAssignedGroup: { controls.append($0) }),
                      slots.indices.contains(control.ordinal), slots[control.ordinal].ordinal == control.ordinal,
                      slots[control.ordinal].state == .occupiedUnknownDestination,
                      controls.filter({ $0.ordinal == control.ordinal }).count == 1,
                      let current = controls.first(where: { $0.ordinal == control.ordinal }),
                      controls.filter({ CFEqual($0.list, current.list) }).count == 1, control.matches(current),
                      Self.protectedSlots(slots, ordinal: control.ordinal)
                        == Self.protectedSlots(footprint, ordinal: control.ordinal),
                      let census = removalCensus(source.pair.strip, runtime: runtime), census.count == population.count,
                      zip(census, population).allSatisfy({ CFEqual($0, $1) }) else { return false }
                return source.permits(runtime: runtime, ownedPopup: ownedPopup)
            }
        }
    }

    static func restoreChangedSendObservation(_ changed: ChangedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        await restoreAssignedSendThroughRetainedOccupied(changed, runtime: runtime, timing: timing)
    }

    /// Immutable native handles for the source/control actually recreated by
    /// the owned inverse. Neither JSON nor a newly found singleton can recreate it.
    struct RestoredSendObservation: @unchecked Sendable {
        let source: OriginalHeaderSourceRenewal
        let control: AXLogicProElements.AssignedSendMenuControl
        let population: [AXUIElement]

        func permits(runtime: AXLogicProElements.Runtime) -> Bool {
            let outer = AXHelpers.HelpReadGuard.current
            return AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: {
                outer?.permits() == false || !source.observation.permitsRead()
            })) {
                guard source.permits(runtime: runtime),
                      let current = AXLogicProElements.assignedSendMenuControl(in: source.pair.strip.strip,
                        ordinal: control.ordinal, runtime: runtime.ax), control.matches(current),
                      let census = removalCensus(source.pair.strip, runtime: runtime), census.count == population.count,
                      zip(census, population).allSatisfy({ CFEqual($0, $1) }) else { return false }
                return source.permits(runtime: runtime)
            }
        }
    }

    /// Immutable native handles confined to the existing owned request's
    /// lifetime. Sendability is not action authority: every use must renew the
    /// source and exact empty control. No JSON receipt can construct this proof.
    struct RemovedSendObservation: @unchecked Sendable {
        let source: OriginalHeaderSourceRenewal
        let empty: AXLogicProElements.EmptySendMenuControl
        let before: SendSlotObservation
        let checkedDestination: OutputAssignment
        let nonRoutingChecks: [String]
        let population: [AXUIElement]

        func permits(runtime: AXLogicProElements.Runtime) -> Bool {
            guard source.permits(runtime: runtime),
                  let current = soleEmptySend(in: source.pair.strip.strip, runtime: runtime.ax),
                  empty.matches(current),
                  let currentPopulation = removalCensus(source.pair.strip, runtime: runtime),
                  currentPopulation.count == population.count,
                  zip(currentPopulation, population).allSatisfy({ CFEqual($0, $1) }) else { return false }
            return source.permits(runtime: runtime)
        }
    }

    /// Explicit internal inverse consumes a native request-local removal proof,
    /// never a freshly published reference or a caller's JSON assertion.
    static func restoreRemovedSendObservation(_ removed: RemovedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        await restoreAssignedSendThroughRetainedEmpty(removed, runtime: runtime, timing: timing)
    }

    static func isSendRemovalTitle(_ title: String) -> Bool { ["No Send", "센드 없음"].contains(title) }
    static func soleEmptySend(in strip: AXUIElement, runtime: AXHelpers.Runtime)
        -> AXLogicProElements.EmptySendMenuControl? {
        var controls: [AXLogicProElements.EmptySendMenuControl] = []
        guard let slots = AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime,
            observingEmptySlot: { controls.append($0) }), slots.count == 1,
              slots[0].state == .observedEmpty, controls.count == 1 else { return nil }
        return controls[0]
    }

    /// A complete singleton occupied→empty transition under one owned leaf.
    /// No old slot ordinal is rebound and no inverse is inferred from this receipt.
    static func finishSendRemoval(original: AXMixerStripBinding.Binding, before: [SendSlotObservation],
        checkedBefore: OutputAssignment, nonRoutingChecks: [String],
        population: [AXUIElement], extras initial: [String: Any], runtime: AXLogicProElements.Runtime)
        async -> CheckedOutputReading {
        var extras = initial
        func uncertain(_ hint: String) -> CheckedOutputReading {
            extras["hint"] = hint
            return .init(result: .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras)), assignment: nil)
        }
        guard before.count == 2, before.filter({ $0.state == .observedEmpty }).count == 1,
              before.filter({ $0.state == .occupiedUnknownDestination }).count == 1,
              let occupiedBefore = before.first(where: { $0.state == .occupiedUnknownDestination }),
              let pair = AXMixerStripBinding.outputAssociation, pair.strip.matches(original),
              let census = removalCensus(original, runtime: runtime) else {
            return uncertain("Removal has no complete singleton footprint and retained-original-header renewal authority.")
        }
        let originalCount = census.filter { CFEqual($0, original.strip) }.count
        guard originalCount <= 1, originalCount == 0 || original.currentIndex(runtime: runtime) != nil else {
            return uncertain("Removal lost unique current custody of its surviving original physical source.")
        }
        // No Send may retire the occupied controls without retiring their strip.
        // Re-observe the retained original header with the same owned inverse;
        // a surviving source must still be that exact original CF/path.
        let renewal = await renewSourceThroughOriginalHeader(pair, original: original, runtime: runtime,
            selectedHeaderRequired: false,
            sourceDisposition: originalCount == 1 ? .survivingOriginal : .retiredOriginal)
        extras["ui_effects"] = ["navigation_performed": renewal.effects.navigationPerformed,
            "attempted": renewal.effects.attempted, "changed": renewal.effects.changed,
            "restoration": renewal.effects.restoration, "reason": renewal.effects.reason as Any? ?? NSNull()]
        guard let source = renewal.source, source.permits(runtime: runtime),
              originalCount == 0 || source.pair.strip.matches(original),
              let empty = soleEmptySend(in: source.pair.strip.strip, runtime: runtime.ax) else {
            return uncertain("Removed source did not independently renew to exactly one completely observed empty send.")
        }
        let expected = population.map { CFEqual($0, original.strip) ? source.pair.strip.strip : $0 }
        guard let finalPopulation = removalCensus(original, runtime: runtime),
              finalPopulation.count == expected.count,
              zip(finalPopulation, expected).allSatisfy({ CFEqual($0, $1) }),
              let finalEmpty = soleEmptySend(in: source.pair.strip.strip, runtime: runtime.ax),
              empty.matches(finalEmpty), source.permits(runtime: runtime) else {
            return uncertain("Empty anchor, complete physical population or original source changed after removal.")
        }
        extras["after"] = ["state": "observed_empty"]
        extras["changed"] = true; extras["strip_count_after"] = finalPopulation.count
        extras["source_renewal"] = source.pair.source; extras["reference_reread_required"] = true
        extras["source_index_after"] = source.index
        extras["original_source_survived"] = originalCount == 1
        extras["verify_source"] = "ax_complete_send_census"; extras["snapshot_atomic"] = false
        let proof = RemovedSendObservation(source: source, empty: finalEmpty,
            before: occupiedBefore,
            checkedDestination: checkedBefore, nonRoutingChecks: nonRoutingChecks, population: finalPopulation)
        guard proof.permits(runtime: runtime) else {
            return uncertain("The removal proof lost its current native empty binding before publication.")
        }
        sendRemovalObserver?(proof)
        return .init(result: .success(HonestContract.encodeStateA(extras: extras)), assignment: nil,
            removedSend: proof)
    }

    private static func removalCensus(_ source: AXMixerStripBinding.Binding,
        runtime: AXLogicProElements.Runtime) -> [AXUIElement]? {
        AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: source.mixer, runtime: runtime.ax)?.strips
    }

    /// Fresh creation starts from native empty custody, not inverse data. A
    /// complete singleton after-census supplies its new control/ordinal; none
    /// of the new send's level, bypass or mode is inferred from the empty slot.
    static func finishFreshSendCreation(original: AXMixerStripBinding.Binding,
        population: [AXUIElement], peerSlots: [[SendSlotObservation]], extras initial: [String: Any],
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming) async -> CheckedOutputReading {
        var extras = initial
        func uncertain(_ hint: String) -> CheckedOutputReading {
            extras["hint"] = hint
            return .init(result: .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras)), assignment: nil)
        }
        guard let pair = AXMixerStripBinding.outputAssociation, pair.strip.matches(original),
              let census = removalCensus(original, runtime: runtime), peerSlots.count == population.count else {
            return uncertain("Fresh creation lost its original-header or complete physical census.")
        }
        let surviving = census.filter { CFEqual($0, original.strip) }.count
        guard surviving <= 1, surviving == 0 || original.currentIndex(runtime: runtime) != nil else {
            return uncertain("Fresh creation lost unique original source custody.")
        }
        let renewal = await renewSourceThroughOriginalHeader(pair, original: original, runtime: runtime,
            selectedHeaderRequired: false, sourceDisposition: surviving == 0 ? .retiredOriginal : .survivingOriginal)
        extras["ui_effects"] = ["navigation_performed": renewal.effects.navigationPerformed,
            "attempted": renewal.effects.attempted, "changed": renewal.effects.changed,
            "restoration": renewal.effects.restoration, "reason": renewal.effects.reason as Any? ?? NSNull()]
        guard let source = renewal.source, source.permits(runtime: runtime) else {
            return uncertain("Fresh creation failed exact original-header source renewal or restoration.")
        }
        func occupied() -> (AXLogicProElements.AssignedSendMenuControl, [SendSlotObservation])? {
            var controls: [AXLogicProElements.AssignedSendMenuControl] = []
            guard let slots = AXLogicProElements.sendSlotObservations(in: source.pair.strip.strip,
                runtime: runtime.ax, observingAssignedGroup: { controls.append($0) }), slots.count == 2,
                  slots.filter({ $0.state == .observedEmpty }).count == 1, controls.count == 1,
                  let slot = slots.first(where: { $0.state == .occupiedUnknownDestination }),
                  slot.ordinal == controls[0].ordinal, slot.bypassed != nil, slot.levelRaw?.isFinite == true,
                  let knob = controls[0].level else { return nil }
            let raw: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(knob,
                kAXValueAttribute as String, runtime: runtime.ax)
            guard case .success(.some(let value)) = raw, CFGetTypeID(value) == CFNumberGetTypeID(),
                  let number = value as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue == slot.levelRaw else { return nil }
            return (controls[0], slots)
        }
        let expectedPopulation = population.map { CFEqual($0, original.strip) ? source.pair.strip.strip : $0 }
        func populationAndPeersHeld() -> Bool {
            guard let current = removalCensus(original, runtime: runtime), current.count == expectedPopulation.count,
                  zip(current, expectedPopulation).allSatisfy({ CFEqual($0, $1) }) else { return false }
            for index in current.indices where !CFEqual(current[index], source.pair.strip.strip) {
                guard let slots = AXLogicProElements.sendSlotObservations(in: current[index], runtime: runtime.ax) else { return false }
                if slots == peerSlots[index] { continue }
                // Native first-assignment padding: one previously empty Send
                // row may become two empty rows. No occupied/protected value or
                // arbitrary count change is accepted by this specific case.
                guard peerSlots[index] == [.init(ordinal: 0, state: .observedEmpty)],
                      slots == [.init(ordinal: 0, state: .observedEmpty), .init(ordinal: 1, state: .observedEmpty)] else { return false }
            }
            return source.permits(runtime: runtime)
        }
        guard let (control, slots) = occupied(), populationAndPeersHeld() else {
            return uncertain("Fresh occupied control, complete physical population or protected peer Sends were not observed.")
        }
        let after = await AXMixerStripBinding.$current.withValue(source.pair.strip) {
            await getOutputObservation(runtime: runtime, sendOrdinal: control.ordinal, timing: timing,
                observingSendMode: sendCreationObserver != nil)
        }
        guard after.assignment == .stereoOutput, let checks = after.sendNonRoutingChecks, !checks.isEmpty,
              populationAndPeersHeld(),
              let (final, finalSlots) = occupied(), control.matches(final), slots == finalSlots,
              source.permits(runtime: runtime) else {
            return uncertain("Fresh creation lost its independent checked Stereo destination or native protected after-state.")
        }
        extras["after"] = OutputAssignment.stereoOutput.json; extras["changed"] = true
        extras["send_ordinal_after"] = final.ordinal
        if let slot = finalSlots.first(where: { $0.ordinal == final.ordinal }) {
            extras["level_raw"] = slot.levelRaw; extras["level_description"] = slot.levelDescription
            extras["bypassed"] = slot.bypassed
        }
        extras["protected_nonrouting_titles"] = checks; extras["strip_count_after"] = expectedPopulation.count
        extras["source_renewal"] = source.pair.source; extras["reference_reread_required"] = true
        extras["source_index_after"] = source.index; extras["verify_source"] = "ax_send_menu_checkmark"
        extras["snapshot_atomic"] = false
        if let observer = sendCreationObserver {
            guard let mode = after.sendMode else {
                return uncertain("Fresh creation has no complete native default-mode evidence for compensation.")
            }
            let peerReads = expectedPopulation.map { AXLogicProElements.sendSlotObservations(in: $0, runtime: runtime.ax) }
            guard peerReads.allSatisfy({ $0 != nil }) else {
                return uncertain("Fresh creation lost its complete native peer Send after-state.")
            }
            let proof = CreatedSendObservation(source: source, control: final, footprint: finalSlots,
                nonRoutingChecks: checks, mode: mode, population: expectedPopulation,
                beforePeers: peerSlots, afterPeers: peerReads.compactMap { $0 })
            guard proof.permits(runtime: runtime) else {
                return uncertain("Fresh creation lost native control, mode, level, bypass or peer custody before publication.")
            }
            observer(proof)
        }
        return .init(result: .success(HonestContract.encodeStateA(extras: extras)), assignment: .stereoOutput,
            sendNonRoutingChecks: checks)
    }

    static func finishSendRestoration(_ removed: RemovedSendObservation, original: AXMixerStripBinding.Binding,
        population: [AXUIElement], extras initial: [String: Any], runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming) async -> CheckedOutputReading {
        var extras = initial
        func uncertain(_ hint: String) -> CheckedOutputReading {
            extras["hint"] = hint
            return .init(result: .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras)), assignment: nil)
        }
        // Only this native capsule's current source/header, never a caller's
        // ordinal or destination label, supplies renewal after its one inverse leaf.
        guard removed.source.pair.strip.matches(original),
              let census = removalCensus(original, runtime: runtime),
              !census.contains(where: { CFEqual($0, original.strip) }) else {
            return uncertain("Explicit inverse has no observed original-source retirement and native renewal authority.")
        }
        let renewal = await renewSourceThroughOriginalHeader(removed.source.pair, original: original,
            runtime: runtime, selectedHeaderRequired: false)
        extras["ui_effects"] = ["navigation_performed": renewal.effects.navigationPerformed,
            "attempted": renewal.effects.attempted, "changed": renewal.effects.changed,
            "restoration": renewal.effects.restoration, "reason": renewal.effects.reason as Any? ?? NSNull()]
        guard let source = renewal.source, source.permits(runtime: runtime) else {
            return uncertain("Explicit inverse failed its exact original-header renewal or restoration.")
        }
        func restoredControl() -> AXLogicProElements.AssignedSendMenuControl? {
            var controls: [AXLogicProElements.AssignedSendMenuControl] = []
            guard let slots = AXLogicProElements.sendSlotObservations(in: source.pair.strip.strip, runtime: runtime.ax,
                observingAssignedGroup: { controls.append($0) }), slots.count == 2,
                  slots.filter({ $0.state == .observedEmpty }).count == 1, controls.count == 1,
                  let occupied = slots.first(where: { $0.state == .occupiedUnknownDestination }),
                  occupied.levelRaw == removed.before.levelRaw, occupied.bypassed == removed.before.bypassed else { return nil }
            return controls.first
        }
        guard let control = restoredControl(), source.permits(runtime: runtime) else {
            return uncertain("Restored occupancy or protected level/bypass was not independently observed; no further inverse was attempted.")
        }
        let after = await AXMixerStripBinding.$current.withValue(source.pair.strip) {
            await getOutputObservation(runtime: runtime, sendOrdinal: control.ordinal, timing: timing)
        }
        if let data = after.result.message.data(using: .utf8), let receipt = try? JSONSerialization.jsonObject(with: data) {
            extras["after_acquisition"] = receipt
        }
        let expectedPopulation = population.map { CFEqual($0, original.strip) ? source.pair.strip.strip : $0 }
        guard after.assignment == removed.checkedDestination, after.sendNonRoutingChecks == removed.nonRoutingChecks,
              let final = restoredControl(), control.matches(final),
              let finalPopulation = removalCensus(original, runtime: runtime), finalPopulation.count == expectedPopulation.count,
              zip(finalPopulation, expectedPopulation).allSatisfy({ CFEqual($0, $1) }), source.permits(runtime: runtime) else {
            return uncertain("The explicit inverse lost its checked destination, raw mode/protected state, control or complete population.")
        }
        extras["after"] = removed.checkedDestination.json
        extras["changed"] = true; extras["strip_count_after"] = finalPopulation.count
        extras["source_renewal"] = source.pair.source; extras["reference_reread_required"] = true
        extras["source_index_after"] = source.index; extras["verify_source"] = "ax_send_menu_checkmark"
        extras["snapshot_atomic"] = false
        return .init(result: .success(HonestContract.encodeStateA(extras: extras)), assignment: after.assignment,
            sendNonRoutingChecks: after.sendNonRoutingChecks,
            restoredSend: .init(source: source, control: final, population: finalPopulation))
    }
}
