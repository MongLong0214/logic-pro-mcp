@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    @TaskLocal private static var interruptedOutputPopupInverse = false
    static var restoringInterruptedOutputPopup: Bool { interruptedOutputPopupInverse }

    /// A passive Arrange name is not an editable field despite its AXTextField
    /// role. This retained witness grants only this reader's semantic popup
    /// press, never a keyboard command, selection change, or parameter write.
    struct PassiveRoutingReadFocus {
        let pid: pid_t
        let app: AXUIElement
        let window: AXUIElement
        let document: String
        let rail: AXUIElement
        let header: AXUIElement
        let focus: AXUIElement

        init?(window: AXUIElement, document: String, runtime: AXLogicProElements.Runtime) {
            guard let pid = runtime.logicProPID(), let app = AXLogicProElements.appRoot(runtime: runtime),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  let header: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: runtime.ax),
                  let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: runtime) else { return nil }
            self.pid = pid; self.app = app; self.window = window; self.document = document
            self.rail = rail; self.header = header; self.focus = focus
            guard permits(runtime: runtime) else { return nil }
        }

        func permits(runtime: AXLogicProElements.Runtime) -> Bool {
            guard !Task.isCancelled, runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(currentApp, app),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  let currentFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(currentFocus, focus),
                  let currentRail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: runtime), CFEqual(currentRail, rail),
                  case .success(let rows) = AXHelpers.childrenResult(rail, runtime: runtime.ax),
                  rows.filter({ CFEqual($0, header) }).count == 1,
                  AXHelpers.getRole(header, runtime: runtime.ax) == kAXLayoutItemRole as String,
                  case .success(let children) = AXHelpers.childrenResult(header, runtime: runtime.ax),
                  children.filter({ CFEqual($0, focus) }).count == 1,
                  AXHelpers.getRole(focus, runtime: runtime.ax) == kAXTextFieldRole as String,
                  let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: runtime.ax),
                  CFEqual(parent, header),
                  let owner: AXUIElement = AXHelpers.getAttribute(focus, kAXWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(owner, window),
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: runtime.ax) == false,
                  case .success(.some(let raw)) = AXHelpers.getAttributeResult(focus, kAXValueAttribute as String,
                    runtime: runtime.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                  CFGetTypeID(raw) == CFNumberGetTypeID(), let value = raw as? NSNumber, value.doubleValue == 0 else { return false }
            for attribute in [kAXInsertionPointLineNumberAttribute, kAXSelectedTextRangeAttribute,
                              kAXSelectedTextAttribute, kAXNumberOfCharactersAttribute] {
                switch AXHelpers.getAttributeResult(focus, attribute as String, runtime: runtime.ax)
                    as Result<AnyObject?, AXHelpers.AXStatusError> {
                case .success(nil): break
                case .failure(let error) where error.isDefinitiveAbsence: break
                default: return false
                }
            }
            guard let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  currentDocument.utf8.elementsEqual(document.utf8), runtime.logicProPID() == pid,
                  let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(finalFocus, focus) else { return false }
            return true
        }
    }
    /// Bus-only input acquisition behind the physical-reference public reader;
    /// this does not qualify a routing graph edge or independent native readback.
    static func getInputBusVerified(
        runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming = .live
    ) async -> ChannelResult {
        (await getCheckedRoutingDestination(params: [:], sendOrdinal: nil, inputBusOnly: true,
            runtime: runtime, timing: timing, observingPeerHeaders: [])).result
    }
    /// A checked assigned-send choice, not a routing-graph completeness claim.
    static func getAssignedSendVerified(
        ordinal: Int, runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming = .live
    ) async -> ChannelResult {
        (await getCheckedRoutingDestination(params: [:], sendOrdinal: ordinal, runtime: runtime, timing: timing)).result
    }
    /// Read-only output-popup acquisition on a retained physical source. No routing leaf is
    /// pressed, and a successful observation does not claim focus/viewport restoration.
    static func getOutputVerified(
        params: [String: String], runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming = .live
    ) async -> ChannelResult {
        (await getCheckedRoutingDestination(params: params, sendOrdinal: nil, runtime: runtime, timing: timing)).result
    }

    struct CheckedOutputReading: Sendable {
        let result: ChannelResult
        let assignment: OutputAssignment?
        /// Internal independently checked input fact; not a public Bus result.
        var inputAssignment: InputAssignment? = nil
        var inputRenewal: OriginalHeaderSourceRenewal? = nil
        var inputSlot: AXMixerInputSlotBinding? = nil
        /// Actual original-header navigation, including a failed selection inverse.
        /// An earlier popup focus receipt cannot replace this restoration duty.
        var renewalEffects: SessionPopulationObservation.UIEffects? = nil
        /// Raw checked non-routing root entries: preservation witness only,
        /// never a typed mode, destination or endpoint identity.
        var sendNonRoutingChecks: [String]? = nil
        /// Request-local native proof only; never decoded from the wire receipt.
        var removedSend: RemovedSendObservation? = nil
        var restoredSend: RestoredSendObservation? = nil
        var changedSend: ChangedSendObservation? = nil
        /// Opt-in typed native mode evidence for this scalar writer only.
        var sendMode: SendModeState? = nil
        /// Two agreeing complete Bus menu inventories on this retained source.
        /// Not namespace availability, consumer completeness, or write authority.
        var observedBusNumbers: [Int]? = nil
        /// Process-local original control, retained only after owned cleanup and fresh custody.
        var sendControl: AXLogicProElements.AssignedSendMenuControl? = nil
    }

    struct SendBypassSnapshot {
        let physical: AXMixerStripBinding.Binding
        let control: AXLogicProElements.AssignedSendMenuControl
        let slots: [SendSlotObservation]
        let population: [AXUIElement]
        let focus: AXUIElement
        let value: Bool
        let assignment: OutputAssignment
        let checks: [String]
    }

    private static func sendBypassCustody(_ held: SendBypassSnapshot,
        runtime: AXLogicProElements.Runtime, allowingChangedBypass: Bool = false) -> Bool {
        guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
              let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
              let app = AXLogicProElements.appRoot(runtime: runtime), held.physical.currentIndex(runtime: runtime) != nil,
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
              CFEqual(focus, held.focus) || CFEqual(focus, held.control.bypass),
              let control = AXLogicProElements.assignedSendMenuControl(in: held.physical.strip,
                ordinal: held.control.ordinal, runtime: runtime.ax), held.control.matches(control),
              let slots = AXLogicProElements.sendSlotObservations(in: held.physical.strip, runtime: runtime.ax),
              let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: held.physical.mixer, runtime: runtime.ax)?.strips,
              census.count == held.population.count, zip(census, held.population).allSatisfy({ CFEqual($0, $1) }) else { return false }
        var expected = held.slots
        var current = slots
        if allowingChangedBypass {
            for index in expected.indices where expected[index].ordinal == held.control.ordinal { expected[index].bypassed = nil }
            for index in current.indices where current[index].ordinal == held.control.ordinal { current[index].bypassed = nil }
        }
        return current == expected
            && (allowingChangedBypass || AXLogicProElements.observedSendBypass(
                group: held.control.group, control: held.control.bypass, runtime: runtime.ax) == held.value)
            && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
    }

    static func readSendBypassSnapshot(ordinal: Int, runtime: AXLogicProElements.Runtime) async -> SendBypassSnapshot? {
        guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
              let physical = AXMixerStripBinding.current, let app = AXLogicProElements.appRoot(runtime: runtime),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
              let slots = AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax),
              let slot = slots.first(where: { $0.ordinal == ordinal }), let value = slot.bypassed,
              slot.levelRaw?.isFinite == true,
              let population = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax)?.strips else { return nil }
        let reading = await getOutputObservation(runtime: runtime, sendOrdinal: ordinal)
        guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
              let assignment = reading.assignment, let checks = reading.sendNonRoutingChecks, !checks.isEmpty,
              let control = reading.sendControl else { return nil }
        let held = SendBypassSnapshot(physical: physical, control: control, slots: slots, population: population,
            focus: focus, value: value, assignment: assignment, checks: checks)
        return sendBypassCustody(held, runtime: runtime) ? held : nil
    }

    static func sendBypassVerified(params: [String: String], writing: Bool,
        runtime: AXLogicProElements.Runtime = .production) async -> ChannelResult {
        let operation = writing ? "mixer.set_send_bypass_verified" : "mixer.get_send_bypass_verified"
        var extras: [String: Any] = ["operation": operation, "write_attempted": false, "snapshot_atomic": false]
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint, extras: extras))
        }
        let allowed = writing ? ["ordinal", "bypassed", "expected_current"] : ["ordinal"]
        guard params.keys.allSatisfy({ allowed.contains($0) }), let ordinal = params["ordinal"].flatMap(Int.init), ordinal >= 0,
              !writing || (["true", "false"].contains(params["bypassed"] ?? "")
                && ["true", "false"].contains(params["expected_current"] ?? "")) else {
            return refuse(.invalidParams, "An exact occupied-send census ordinal and literal Boolean request are required.")
        }
        extras["send_ordinal"] = ordinal
        guard let before = await readSendBypassSnapshot(ordinal: ordinal, runtime: runtime) else {
            return refuse(.readbackUnavailable, "The original checkbox, raw send state, checked route or protected source did not remain observed.")
        }
        extras["before"] = before.value; extras["bypassed"] = before.value
        extras["checked_destination"] = before.assignment.json
        extras["protected_nonrouting_titles"] = before.checks
        let actions = AXHelpers.getActionNamesResult(before.control.bypass, runtime: runtime.ax)
        switch actions {
        case .success(let names): extras["ax_action_names"] = names; extras["ax_action_names_status"] = 0
        case .failure(let error): extras["ax_action_names"] = NSNull(); extras["ax_action_names_status"] = error.raw
        }
        guard sendBypassCustody(before, runtime: runtime) else {
            return refuse(.staleSnapshot, "The deciding checkbox capability read lost its original source or control.")
        }
        if !writing {
            extras["verify_source"] = "ax_owned_send_checkbox"
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        let desired = params["bypassed"] == "true", expected = params["expected_current"] == "true"
        guard expected == before.value else { return refuse(.staleSnapshot, "The actual bypass does not agree with expected_current.") }
        if desired == before.value {
            extras["changed"] = false; extras["verify_source"] = "ax_owned_send_checkbox"
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        let playing: Bool? = AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime)
        let recording: Bool? = AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime)
        guard let playing, let recording else { return refuse(.transportStateUnknown, "Stopped transport must be observed.") }
        guard !playing && !recording else { return refuse(.unsupportedState, "Bypass changes require stopped transport.") }
        guard case .success(let names) = actions, names.contains(kAXPressAction as String),
              let deciding = await readSendBypassSnapshot(ordinal: ordinal, runtime: runtime),
              before.control.matches(deciding.control), before.slots == deciding.slots,
              before.assignment == deciding.assignment, before.checks == deciding.checks,
              sendBypassCustody(before, runtime: runtime),
              case .success(let finalActions) = AXHelpers.getActionNamesResult(before.control.bypass, runtime: runtime.ax),
              finalActions.contains(kAXPressAction as String), sendBypassCustody(before, runtime: runtime) else {
            return refuse(.staleSnapshot, "No supported AXPress and unchanged original send survived the final protected read.")
        }
        // Popup/capability reads can outlive the earlier stopped observation.
        let finalPlaying: Bool? = AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime)
        let finalRecording: Bool? = AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime)
        guard let finalPlaying, let finalRecording else { return refuse(.transportStateUnknown, "Stopped transport must remain observed at the action boundary.") }
        guard !finalPlaying && !finalRecording,
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
            return refuse(.unsupportedState, "Bypass changes require stopped transport at the action boundary.")
        }
        guard sendBypassCustody(before, runtime: runtime) else {
            return refuse(.staleSnapshot, "The final transport read lost the original source or checkbox custody.")
        }
        extras["write_attempted"] = true
        let pressed = AXHelpers.performActionResult(before.control.bypass, kAXPressAction as String, runtime: runtime.ax)
        if case .success = pressed { extras["press_succeeded"] = true; extras["press_status"] = 0 }
        else if case .failure(let error) = pressed {
            extras["press_succeeded"] = false; extras["press_error"] = error.diagnosticLabel
            if case .status(let status) = error { extras["press_status"] = status.raw }
            else { extras["press_status"] = NSNull() }
        }
        var settled = await readSendBypassSnapshot(ordinal: ordinal, runtime: runtime)
        // One owned AXPress can acknowledge before its bit lands during the
        // awaited menu read. Re-read once only while every non-bypass fact and
        // the exact original control remain held; never repeat the press.
        if settled == nil, sendBypassCustody(before, runtime: runtime, allowingChangedBypass: true) {
            settled = await readSendBypassSnapshot(ordinal: ordinal, runtime: runtime)
        }
        guard let after = settled,
              before.control.matches(after.control), before.assignment == after.assignment, before.checks == after.checks,
              sendBypassCustody(before, runtime: runtime, allowingChangedBypass: true),
              sendBypassCustody(after, runtime: runtime) else {
            extras["bypassed"] = NSNull()
            extras["hint"] = "The one attempted checkbox press lost independent protected readback; no inverse was guessed."
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        extras["bypassed"] = after.value
        guard after.value == desired else {
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        extras["changed"] = true; extras["verify_source"] = "ax_owned_send_checkbox"
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    static func setAssignedSendOutputVerified(params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming = .live) async -> ChannelResult {
        func isSink(_ assignment: OutputAssignment) -> Bool {
            switch assignment { case .stereoOutput, .physical, .bus: true; default: false }
        }
        let creating = params["replace_existing"] == "false" && params["expected_current"] == "no_send"
            && params["destination"] == OutputAssignment.stereoOutput.token
        let expected = params["expected_current"].flatMap(OutputAssignment.init(token:))
        guard params.keys.allSatisfy({ ["destination", "expected_current", "replace_existing", "send_ordinal"].contains($0) }),
              creating || params["replace_existing"] == "true", let ordinal = params["send_ordinal"].flatMap(Int.init), ordinal >= 0,
              params["destination"] == "no_send" || params["destination"].flatMap(OutputAssignment.init(token:)).map(isSink) == true,
              creating || expected.map(isSink) == true,
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
            return .error(HonestContract.encodeStateC(error: .invalidParams,
                hint: "An occupied physical send, explicit replacement, checked physical/stereo/bus before and destination, and owned acquisition are required.",
                extras: ["operation": "mixer.set_send_output_verified", "write_attempted": false]))
        }
        let creation: FreshSendCreation?
        if creating {
            guard let source = AXMixerStripBinding.current, let pair = AXMixerStripBinding.outputAssociation,
                  pair.strip.matches(source), let observed = soleEmptySend(in: source.strip, runtime: runtime.ax), ordinal == 0 else {
                return .error(HonestContract.encodeStateC(error: .staleSnapshot,
                    hint: "Fresh creation requires a complete sole-empty source and its exact original-header association.",
                    extras: ["operation": "mixer.set_send_output_verified", "write_attempted": false]))
            }
            guard let population = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: source.mixer, runtime: runtime.ax)?.strips else {
                return .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: "Fresh creation requires a complete peer census.", extras: ["write_attempted": false]))
            }
            let reads = population.map { AXLogicProElements.sendSlotObservations(in: $0, runtime: runtime.ax) }
            guard reads.allSatisfy({ $0 != nil }) else {
                return .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: "Fresh creation requires complete peer Send footprints.", extras: ["write_attempted": false]))
            }
            creation = .init(empty: observed, population: population, peerSlots: reads.compactMap { $0 })
        } else { creation = nil }
        return await getCheckedRoutingDestination(params: [:], sendOrdinal: ordinal,
            runtime: runtime, timing: timing, sendReplacement: .init(expected: expected,
                destination: params["destination"].flatMap(OutputAssignment.init(token:)), creation: creation),
            observingPeerHeaders: SendRemovalSagaAdapter.checkedReadPeerHeaders,
            readingOriginalScope: SendRemovalSagaAdapter.checkedReadRenewal?.observation).result
    }

    /// Invocation-local immutable AX handles. Sendability grants no action
    /// authority: every use checks this exact census, empty CF/path and values.
    private struct FreshSendCreation: @unchecked Sendable {
        let empty: AXLogicProElements.EmptySendMenuControl
        let population: [AXUIElement]
        let peerSlots: [[SendSlotObservation]]
    }

    private struct SendReplacement: Sendable {
        var expected: OutputAssignment?
        /// nil is the explicitly scoped No Send action, never a No Output routing endpoint.
        var destination: OutputAssignment?
        var restoration: RemovedSendObservation? = nil
        var occupiedInverse: ChangedSendObservation? = nil
        var createdRemoval: CreatedSendObservation? = nil
        /// Fresh current native empty control, not a removed-send capsule.
        var creation: FreshSendCreation? = nil
        var modeChange: SendModeChange? = nil
    }

    private struct SendModeChange: Sendable {
        let expected: SendMode
        let desired: SendMode
    }

    static func setSendModeVerified(params: [String: String], runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming = .live) async -> ChannelResult {
        guard params.keys.allSatisfy({ ["ordinal", "mode", "expected_current"].contains($0) }),
              let ordinal = params["ordinal"].flatMap(Int.init), ordinal >= 0,
              let desired = params["mode"].flatMap(SendMode.init(rawValue:)),
              let expected = params["expected_current"].flatMap(SendMode.init(rawValue:)),
              let source = AXMixerStripBinding.current, let pair = AXMixerStripBinding.outputAssociation,
              pair.strip.matches(source), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
            return .error(HonestContract.encodeStateC(error: .invalidParams,
                hint: "An exact retained occupied Send and explicit post_pan/post_fader/pre_fader current and desired modes are required.",
                extras: ["operation": "mixer.set_send_mode_verified", "write_attempted": false]))
        }
        return await getCheckedRoutingDestination(params: [:], sendOrdinal: ordinal, runtime: runtime, timing: timing,
            sendReplacement: .init(expected: nil, destination: nil, modeChange: .init(expected: expected, desired: desired)),
            observingSendMode: true).result
    }

    static func readRestoredSendObservation(_ restored: CheckedOutputReading,
        original: AXMixerStripBinding.Binding, runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        guard let held = restored.restoredSend else {
            return .init(result: .error(HonestContract.encodeStateC(error: .staleTargetReference,
                hint: "The exact restored source and occupied send control are no longer current.",
                extras: ["write_attempted": false])), assignment: nil)
        }
        return await readOccupiedSendObservation(held, original: original, runtime: runtime, timing: timing)
    }

    static func readCreatedSendObservation(_ created: CreatedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading? {
        guard created.permits(runtime: runtime) else { return nil }
        let reading = await AXMixerStripBinding.$current.withValue(created.source.pair.strip) {
            await getOutputObservation(runtime: runtime, sendOrdinal: created.control.ordinal,
                timing: timing, observingSendMode: true)
        }
        guard created.permits(runtime: runtime), reading.assignment == .stereoOutput,
              reading.sendNonRoutingChecks == created.nonRoutingChecks, reading.sendMode == created.mode else { return nil }
        return reading
    }

    static func removeCreatedSendObservation(_ created: CreatedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        guard created.permits(runtime: runtime) else {
            return .init(result: .error(HonestContract.encodeStateC(error: .staleSnapshot,
                hint: "The exact created Send is no longer owned.", extras: ["write_attempted": false])), assignment: nil)
        }
        return await AXMixerStripBinding.$current.withValue(created.source.pair.strip) {
            await AXMixerStripBinding.$outputAssociation.withValue(created.source.pair) {
                await getCheckedRoutingDestination(params: [:], sendOrdinal: created.control.ordinal,
                    runtime: runtime, timing: timing,
                    sendReplacement: .init(expected: .stereoOutput, destination: nil, createdRemoval: created),
                    observingSendMode: true)
            }
        }
    }

    static func readChangedSendObservation(_ changed: ChangedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        guard changed.permits(runtime: runtime) else {
            return .init(result: .error(HonestContract.encodeStateC(error: .staleTargetReference,
                hint: "The exact changed source and occupied send control are no longer current.",
                extras: ["write_attempted": false])), assignment: nil)
        }
        let reading = await readOccupiedSendObservation(.init(source: changed.source, control: changed.control,
            population: changed.population), original: changed.source.original, runtime: runtime, timing: timing)
        guard changed.permits(runtime: runtime), reading.sendNonRoutingChecks == changed.nonRoutingChecks else {
            return .init(result: outputReadContextFailure(reading.result, operation: "mixer.get_send_destination_verified"), assignment: nil)
        }
        return reading
    }

    private static func readOccupiedSendObservation(_ held: RestoredSendObservation,
        original: AXMixerStripBinding.Binding, runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming) async -> CheckedOutputReading {
        let outer = AXHelpers.HelpReadGuard.current
        let readFocus = OwnedTrackStackObservationNavigation.ReadFocusScope()
        return await AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: {
            outer?.permits() == false || (!readFocus.permits() && !held.source.observation.permitsRead())
        })) {
            guard held.source.original.matches(original), held.permits(runtime: runtime),
                  let before = AXLogicProElements.sendSlotObservations(in: held.source.pair.strip.strip, runtime: runtime.ax) else {
                return .init(result: .error(HonestContract.encodeStateC(error: .staleTargetReference,
                    hint: "The exact restored source and occupied send control are no longer current.",
                    extras: ["write_attempted": false])), assignment: nil)
            }
            let reading = await AXMixerStripBinding.$current.withValue(held.source.pair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(held.source.pair) {
                    await getOutputObservation(runtime: runtime, sendOrdinal: held.control.ordinal, timing: timing,
                        readingOriginalScope: held.source.observation,
                        observingPopupFocus: { readFocus.retainRoutingPopupFocus($0) })
                }
            }
            guard held.permits(runtime: runtime),
                  AXLogicProElements.sendSlotObservations(in: held.source.pair.strip.strip, runtime: runtime.ax) == before,
                  held.permits(runtime: runtime) else {
                return .init(result: outputReadContextFailure(reading.result, operation: "mixer.get_send_destination_verified"),
                    assignment: nil)
            }
            return reading
        }
    }

    static func restoreAssignedSendThroughRetainedEmpty(_ removed: RemovedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming) async -> CheckedOutputReading {
        guard removed.permits(runtime: runtime) else {
            return .init(result: .error(HonestContract.encodeStateC(error: .staleTargetReference,
                hint: "The original request's removed-send empty binding is no longer current.",
                extras: ["write_attempted": false])), assignment: nil)
        }
        return await AXMixerStripBinding.$current.withValue(removed.source.pair.strip) {
            await AXMixerStripBinding.$outputAssociation.withValue(removed.source.pair) {
                await getCheckedRoutingDestination(params: [:], sendOrdinal: 0,
                    runtime: runtime, timing: timing, sendReplacement: .init(expected: removed.checkedDestination,
                        destination: removed.checkedDestination, restoration: removed))
            }
        }
    }

    static func restoreAssignedSendThroughRetainedOccupied(_ changed: ChangedSendObservation,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming) async -> CheckedOutputReading {
        guard changed.permits(runtime: runtime) else {
            return .init(result: .error(HonestContract.encodeStateC(error: .staleTargetReference,
                hint: "The exact changed occupied send is no longer owned.", extras: ["write_attempted": false])), assignment: nil)
        }
        return await AXMixerStripBinding.$current.withValue(changed.source.pair.strip) {
            await AXMixerStripBinding.$outputAssociation.withValue(changed.source.pair) {
                await getCheckedRoutingDestination(params: [:], sendOrdinal: changed.control.ordinal,
                    runtime: runtime, timing: timing, sendReplacement: .init(expected: changed.checkedAfter,
                        destination: changed.checkedBefore, occupiedInverse: changed),
                    readingOriginalScope: changed.source.observation)
            }
        }
    }

    static func removeAssignedSendObservation(ordinal: Int, expected: OutputAssignment,
        runtime: AXLogicProElements.Runtime, timing: OutputAssignmentTiming = .live) async -> CheckedOutputReading {
        guard ordinal >= 0, expected != .noOutput,
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
            return .init(result: .error(HonestContract.encodeStateC(error: .invalidParams,
                hint: "Owned acquisition and an occupied checked send are required.",
                extras: ["write_attempted": false])), assignment: nil)
        }
        return await getCheckedRoutingDestination(params: [:], sendOrdinal: ordinal,
            runtime: runtime, timing: timing, sendReplacement: .init(expected: expected, destination: nil))
    }

    /// A bijection between two singleton occupied sets is not an ordinal/name
    /// lookup. The complete empty footprint and protected state still decide
    /// whether this same logical slot survived an owned one-leaf replacement.
    private static func soleAssignedSend(in strip: AXUIElement, runtime: AXHelpers.Runtime)
        -> (slots: [SendSlotObservation], control: AXLogicProElements.AssignedSendMenuControl)? {
        var controls: [AXLogicProElements.AssignedSendMenuControl] = []
        guard let slots = AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime,
            observingAssignedGroup: { controls.append($0) }),
              slots.allSatisfy({ $0.state == .observedEmpty || $0.state == .occupiedUnknownDestination }),
              slots.filter({ $0.state == .occupiedUnknownDestination }).count == 1,
              controls.count == 1, let control = controls.first,
              slots.first(where: { $0.state == .occupiedUnknownDestination })?.ordinal == control.ordinal else { return nil }
        return (slots, control)
    }

    /// Typed input evidence from the same owned reader, never from a wire receipt.
    static func getInputBusObservation(runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming = .live,
        requiringOriginalInputControl: AXMixerInputSlotBinding? = nil,
        restoringMixerGeometry: HeldSelectionAssociation.MixerViewportGeometry? = nil,
        observingPopupFocus: @escaping @Sendable ((@Sendable () -> Bool)?) -> Void = { _ in },
        observingRenewedFocus: @escaping @Sendable (HeldSelectionAssociation) -> Void = { _ in },
        refreshingOriginalSourceAfterCleanup: Bool = false,
        observingPeerHeaders: [AXTrackBinding.Binding]? = nil,
        readingOriginalScope: HeldSelectionAssociation? = nil,
        recoveringRetiredFocusFrom focusBaseline: HeldSelectionAssociation.OriginalHeaderFocusBaseline? = nil
    ) async -> CheckedOutputReading {
        await getCheckedRoutingDestination(params: [:], sendOrdinal: nil, inputBusOnly: true,
            runtime: runtime, timing: timing, restoringMixerGeometry: restoringMixerGeometry,
            observingPopupFocus: observingPopupFocus,
            observingRenewedFocus: observingRenewedFocus,
            requiringOriginalInputControl: requiringOriginalInputControl,
            refreshingOriginalSourceAfterCleanup: refreshingOriginalSourceAfterCleanup,
            observingPeerHeaders: observingPeerHeaders,
            readingOriginalScope: readingOriginalScope,
            recoveringRetiredFocusFrom: focusBaseline)
    }

    static func getCheckedInputObservation(runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming = .live,
        restoringMixerGeometry: HeldSelectionAssociation.MixerViewportGeometry? = nil,
        observingPopupFocus: @escaping @Sendable ((@Sendable () -> Bool)?) -> Void = { _ in },
        observingRenewedFocus: @escaping @Sendable (HeldSelectionAssociation) -> Void = { _ in },
        refreshingOriginalSourceAfterCleanup: Bool = false,
        observingPeerHeaders: [AXTrackBinding.Binding]? = nil,
        readingOriginalScope: HeldSelectionAssociation? = nil,
        recoveringRetiredFocusFrom focusBaseline: HeldSelectionAssociation.OriginalHeaderFocusBaseline? = nil
    ) async -> CheckedOutputReading {
        await getCheckedRoutingDestination(params: [:], sendOrdinal: nil, inputBusOnly: true,
            includingNonBusInputs: true, runtime: runtime, timing: timing,
            restoringMixerGeometry: restoringMixerGeometry,
            observingPopupFocus: observingPopupFocus, observingRenewedFocus: observingRenewedFocus,
            refreshingOriginalSourceAfterCleanup: refreshingOriginalSourceAfterCleanup,
            observingPeerHeaders: observingPeerHeaders,
            readingOriginalScope: readingOriginalScope,
            recoveringRetiredFocusFrom: focusBaseline)
    }

    /// Shares the exact owned reader; wire receipt decoding never supplies graph identity.
    static func getOutputObservation(runtime: AXLogicProElements.Runtime, sendOrdinal: Int? = nil,
                                     timing: OutputAssignmentTiming = .live,
                                     observingSendMode: Bool = false,
                                     requiringSendMode: Bool = true,
                                     requiringOriginalSendControl: AXLogicProElements.AssignedSendMenuControl? = nil,
                                     readingOriginalScope: HeldSelectionAssociation? = nil,
                                     observingPopupFocus: @escaping @Sendable ((@Sendable () -> Bool)?) -> Void = { _ in }) async -> CheckedOutputReading {
        await getCheckedRoutingDestination(params: [:], sendOrdinal: sendOrdinal, runtime: runtime, timing: timing,
            observingPopupFocus: observingPopupFocus, observingSendMode: observingSendMode,
            requiringSendMode: requiringSendMode, requiringOriginalSendControl: requiringOriginalSendControl,
            readingOriginalScope: readingOriginalScope)
    }

    private static func getCheckedRoutingDestination(
        params: [String: String], sendOrdinal: Int?, inputBusOnly: Bool = false,
        includingNonBusInputs: Bool = false, runtime: AXLogicProElements.Runtime,
        timing: OutputAssignmentTiming,
        restoringMixerGeometry: HeldSelectionAssociation.MixerViewportGeometry? = nil,
        observingPopupFocus: @escaping @Sendable ((@Sendable () -> Bool)?) -> Void = { _ in },
        observingRenewedFocus: @escaping @Sendable (HeldSelectionAssociation) -> Void = { _ in },
        sendReplacement: SendReplacement? = nil, observingSendMode: Bool = false,
        requiringSendMode: Bool = true,
        requiringOriginalSendControl: AXLogicProElements.AssignedSendMenuControl? = nil,
        requiringOriginalInputControl: AXMixerInputSlotBinding? = nil,
        refreshingOriginalSourceAfterCleanup: Bool = false,
        observingPeerHeaders: [AXTrackBinding.Binding]? = nil,
        readingOriginalScope: HeldSelectionAssociation? = nil,
        recoveringRetiredFocusFrom focusBaseline: HeldSelectionAssociation.OriginalHeaderFocusBaseline? = nil
    ) async -> CheckedOutputReading {
        let operation = sendReplacement?.modeChange != nil ? "mixer.set_send_mode_verified" : sendReplacement != nil ? "mixer.set_send_output_verified" :
            (inputBusOnly ? "mixer.get_input_bus_verified" : (sendOrdinal == nil ? "mixer.get_output_verified" : "mixer.get_send_destination_verified"))
        var extras: [String: Any] = ["operation": operation, "write_attempted": false,
                                   "navigation_attempted": false, "popup_menu_state": "not_opened"]
        final class MixerChildCleanupDiagnostic: @unchecked Sendable {
            var checkpoint = "not_attempted"
            var initialScope = false
            var scopeReads = 0
            var scopeMatches = 0
            var topLevelRead = false
            var topLevelEmpty = false
            var directRootRead = false
            var directRootCount = 0
            var directRootSame = false
            var parentMatched = false
            var cgRead = false
            var cgTotalCount = 0
            var heldCGCount = 0
            var actionNamesReads = 0
            var cancelPresentReads = 0
            var actionScope = false
            var performAction = "not_attempted"
            var closure = "not_checked"

            func snapshot() -> [String: Any] {
                ["checkpoint": checkpoint, "initial_scope": initialScope,
                 "scope_reads": scopeReads, "scope_matches": scopeMatches,
                 "top_level_read": topLevelRead, "top_level_empty": topLevelEmpty,
                 "direct_root_read": directRootRead, "direct_root_count": directRootCount,
                 "direct_root_same": directRootSame, "parent_matched": parentMatched,
                 "cg_read": cgRead, "cg_total_count": cgTotalCount,
                 "held_cg_count": heldCGCount, "action_names_reads": actionNamesReads,
                 "cancel_present_reads": cancelPresentReads, "action_scope": actionScope,
                 "perform_action": performAction, "closure": closure]
            }
        }
        let mixerChildCleanupDiagnostic = MixerChildCleanupDiagnostic()
        final class MixerChildAcquisitionDiagnostic: @unchecked Sendable {
            var checkpoint = "not_attempted"
            var pressBoundaryEligible = false
            var scopeCurrent = false
            var topLevelRead = false
            var topLevelCount = 0
            var directRootRead = false
            var directRootCount = 0
            var directRootSame = false
            var parentMatched = false
            var cgRead = false
            var cgTotalCount = 0
            var waitingForCG = false
            var pendingRecheckRead = false
            var pendingRecheckCount = 0
            var pendingRecheckSame = false
            var tokenAcquired = false

            func snapshot() -> [String: Any] {
                ["checkpoint": checkpoint,
                 "press_boundary_eligible": pressBoundaryEligible,
                 "scope_current": scopeCurrent,
                 "top_level_read": topLevelRead, "top_level_count": topLevelCount,
                 "direct_root_read": directRootRead, "direct_root_count": directRootCount,
                 "direct_root_same": directRootSame, "parent_matched": parentMatched,
                 "cg_read": cgRead, "cg_total_count": cgTotalCount,
                 "waiting_for_cg": waitingForCG,
                 "pending_recheck_read": pendingRecheckRead,
                 "pending_recheck_count": pendingRecheckCount,
                 "pending_recheck_same": pendingRecheckSame,
                 "token_acquired": tokenAcquired]
            }
        }
        let mixerChildAcquisitionDiagnostic = MixerChildAcquisitionDiagnostic()
        var renewalEffects: SessionPopulationObservation.UIEffects?
        func refuse(_ error: HonestContract.FailureError, _ hint: String) -> CheckedOutputReading {
            .init(result: .error(HonestContract.encodeStateC(error: error, hint: hint, extras: extras)),
                assignment: nil, renewalEffects: renewalEffects)
        }
        guard params.isEmpty, sendOrdinal.map({ $0 >= 0 }) != false, let physical = AXMixerStripBinding.current else {
            return refuse(.invalidParams, "A current physical Mixer target_ref is required; no write inputs or indices are accepted.")
        }
        if let readingOriginalScope {
            guard physical.currentIndex(in: readingOriginalScope) != nil else {
                return refuse(.staleTargetReference, "The original read scope no longer contains this physical source.")
            }
        } else {
            guard physical.currentIndex(runtime: runtime) != nil else {
                return refuse(.staleTargetReference, "The original physical source is no longer in its bound project/window.")
            }
        }
        @Sendable func currentPhysicalMembership(ownedPopup: AXUIElement? = nil)
            -> (index: Int?, checkedInHeldScope: Bool) {
            if let readingOriginalScope {
                if inputBusOnly {
                    // The original scope qualifies a popup-free main window or
                    // one reciprocal ordinary Mixer popup. Native Input windows
                    // retain their existing reader; neutral Output custody is
                    // never an Input-popup capability (including NoValue focus).
                    let menus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)
                    if let ownedPopup, let menus, menus.count == 1, CFEqual(menus[0], ownedPopup) {
                        return (physical.currentIndex(in: readingOriginalScope, ownedPopup: ownedPopup), true)
                    }
                    guard menus?.isEmpty == true, let pid = runtime.logicProPID(),
                          runtime.onScreenWindowList().map({ LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 }) == true else {
                        return (physical.currentIndex(runtime: runtime), false)
                    }
                    return (physical.currentIndex(in: readingOriginalScope), true)
                }
                return (physical.currentIndex(in: readingOriginalScope, ownedPopup: ownedPopup), true)
            }
            return (physical.currentIndex(runtime: runtime), false)
        }
        if refreshingOriginalSourceAfterCleanup {
            let association = AXMixerStripBinding.outputAssociation
            let associationPresent = association != nil
            let associationMatches = association?.strip.matches(physical) == true
            guard inputBusOnly, let pair = association,
                  associationMatches, pair.track.currentIndex() != nil,
                  CFEqual(pair.track.window, physical.window),
                  pair.track.document.utf8.elementsEqual(physical.document.utf8) else {
                extras["input_source_renewal"] = [
                    "source_needs_renewal": false, "data_owned": false,
                    "checked_evidence_agrees": false,
                    "original_association_present": associationPresent,
                    "original_association_matches": associationMatches,
                ]
                return refuse(.staleTargetReference,
                    "Fresh post-cleanup input acquisition requires its original held header and physical source; no menu was opened.")
            }
        }
        let passiveFocus = readLogicKeyboardFocus(runtime: runtime) == .notTextEditing ? nil
            : PassiveRoutingReadFocus(window: physical.window, document: physical.document, runtime: runtime)
        let passiveMixerFocus = readLogicKeyboardFocus(runtime: runtime) == .notTextEditing ? nil
            : OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus(
                window: physical.window, logic: runtime, acquisitionPermitted: { !Task.isCancelled })
        @Sendable func focusAllowsAcquisition() -> Bool {
            if let passiveFocus {
                let permitted = passiveFocus.permits(runtime: runtime)
                if !permitted, sendReplacement != nil { Log.info("Routing focus refused: retained routing focus", subsystem: "ax") }
                return permitted
            }
            if let passiveMixerFocus {
                let permitted = passiveMixerFocus.permits()
                if !permitted, sendReplacement != nil { Log.info("Routing focus refused: retained Mixer focus", subsystem: "ax") }
                return permitted
            }
            let permitted = readLogicKeyboardFocus(runtime: runtime) == .notTextEditing
            if !permitted, sendReplacement != nil { Log.info("Routing focus refused: keyboard observation", subsystem: "ax") }
            return permitted
        }
        guard focusAllowsAcquisition(),
              !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked else {
            return refuse(.readbackUnavailable, "Cannot acquire an output menu while focus or modal state is unsafe or unreadable.")
        }
        guard let playing = AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime),
              let recording = AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) else {
            return refuse(.transportStateUnknown, "Play and Record must read before menu acquisition.")
        }
        guard !playing, !recording else { return refuse(.unsupportedState, "Output-menu acquisition requires stopped transport.") }
        let routingTransport = HeldRoutingReadTransport.capture(window: physical.window, runtime: runtime)
        @Sendable func transportStillStopped() -> Bool {
            if let routingTransport { return routingTransport.stillStopped(runtime: runtime) }
            return AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false
                && AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false
        }
        @Sendable func assignedControl() -> AXLogicProElements.AssignedSendMenuControl? {
            guard let sendOrdinal else { return nil }
            return AXLogicProElements.assignedSendMenuControl(in: physical.strip,
                ordinal: sendOrdinal, runtime: runtime.ax)
        }
        let assigned = assignedControl()
        let requiredSendControl = sendReplacement != nil ? SendRemovalSagaAdapter.requiredSendControl : requiringOriginalSendControl
        guard requiredSendControl.map({ captured in assigned.map(captured.matches) == true }) ?? true else {
            return refuse(.staleTargetReference, "The previewed native Send control is no longer current; nothing was pressed.")
        }
        let restoringEmpty = sendReplacement?.restoration?.empty ?? sendReplacement?.creation?.empty
        guard sendOrdinal == nil || assigned != nil || restoringEmpty != nil else {
            return refuse(.readbackUnavailable, "The requested ordinal has no uniquely qualified assigned-send list control; nothing was pressed.")
        }
        @Sendable func selectedControl() -> AXUIElement? {
            if let empty = sendReplacement?.creation?.empty {
                guard let current = soleEmptySend(in: physical.strip, runtime: runtime.ax), empty.matches(current) else { return nil }
                return current.control
            }
            if let restoration = sendReplacement?.restoration {
                guard let current = soleEmptySend(in: physical.strip, runtime: runtime.ax),
                      restoration.empty.matches(current) else { return nil }
                return current.control
            }
            if inputBusOnly {
                let read = AXLogicProElements.inputSlotRead(in: physical.strip, runtime: runtime.ax)
                guard case .source = read.reading, let control = read.control else {
                    Log.info("Routing input control unavailable: reading=\(read.reading), help_guard_stopped=\(AXHelpers.HelpReadGuard.current?.stopped == true)", subsystem: "ax")
                    return nil
                }
                return control
            }
            if let assigned {
                guard let current = assignedControl(), assigned.matches(current),
                      AXHelpers.getRole(current.group, runtime: runtime.ax) == kAXGroupRole as String,
                      AXHelpers.getRole(current.bypass, runtime: runtime.ax) == kAXCheckBoxRole as String,
                      AXHelpers.getRole(current.list, runtime: runtime.ax) == kAXButtonRole as String else { return nil }
                return current.list
            }
            return AXLogicProElements.outputSlotButton(in: physical.strip, runtime: runtime.ax)
        }
        func acquisitionRefusal(_ checkpoint: String) -> CheckedOutputReading {
            if inputBusOnly {
                extras["acquisition_checkpoint"] = checkpoint
                extras["help_read_guard_stopped"] = AXHelpers.HelpReadGuard.current?.stopped == true
                do {
                    try SessionPopulationObservation.requireOwnedAcquisition()
                    extras["acquisition_at_refusal"] = "current"
                } catch { extras["acquisition_at_refusal"] = String(describing: error) }
            }
            return refuse(.readbackUnavailable, "A unique output slot and absence of existing popups must be observed; nothing was pressed.")
        }
        // Preserve the original short-circuit read order. Checkpoints inspect
        // only an already refused read; they add no native call or permission.
        guard let pid = runtime.logicProPID() else { return acquisitionRefusal("logic_pid") }
        guard let windows = runtime.onScreenWindowList() else { return acquisitionRefusal("on_screen_windows") }
        guard LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 else { return acquisitionRefusal("native_popup_absence") }
        guard let beforeMenus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax) else { return acquisitionRefusal("mixer_popup_read") }
        guard beforeMenus.isEmpty else { return acquisitionRefusal("mixer_popup_absence") }
        guard let slot = selectedControl() else { return acquisitionRefusal("original_slot") }
        guard case .success(.some(let originalLabel)) = AXHelpers.getAttributeResult(slot,
            kAXDescriptionAttribute as String, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError> else {
            return acquisitionRefusal("original_slot_label")
        }
        guard requiringOriginalInputControl.map({ $0.matches(.init(owner: physical, control: slot, source: originalLabel)) }) ?? true else {
            return refuse(.staleTargetReference, "The previewed input control is no longer current; nothing was pressed.")
        }
        // Deciding reads may themselves observe a host transition. Recheck the
        // held physical membership, then the exact current main window/document
        // after those reads. AX still offers no atomic compare-and-act primitive.
        @Sendable func ownerBoundaryStillCurrent(ownedPopup: AXUIElement? = nil) -> Bool {
            guard !Task.isCancelled, runtime.logicProPID() == pid else { return false }
            let membership = currentPhysicalMembership(ownedPopup: ownedPopup)
            guard membership.index != nil else { return false }
            // The actual held-scope read just renewed its main/focused window,
            // original native paths and complete rail/Mixer membership. Keep the
            // ordinary/native fallback's global window check; a second hierarchy
            // discovery adds no identity to that already checked held window.
            if !membership.checkedInHeldScope {
                guard case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                      CFEqual(window, physical.window) else { return false }
            }
            guard case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(
                    physical.window, runtime: runtime),
                  document.utf8.elementsEqual(physical.document.utf8) else { return false }
            return true
        }
        @Sendable func sourceFactsCurrent(
            preservingOriginalLabel: Bool = true,
            requiringStoppedTransport: Bool = true
        ) -> Bool {
            guard !Task.isCancelled, runtime.logicProPID() == pid else { return false }
            guard let current = selectedControl(), CFEqual(current, slot) else {
                if sendReplacement != nil { Log.info("Routing source facts refused: original control", subsystem: "ax") }
                return false
            }
            guard case .success(.some(let label)) = AXHelpers.getAttributeResult(slot, kAXDescriptionAttribute as String, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError>,
                  (!preservingOriginalLabel || label.utf8.elementsEqual(originalLabel.utf8)) else {
                if sendReplacement != nil { Log.info("Routing source facts refused: original label", subsystem: "ax") }
                return false
            }
            guard !requiringStoppedTransport || transportStillStopped() else {
                if sendReplacement != nil { Log.info("Routing source facts refused: stopped transport", subsystem: "ax") }
                return false
            }
            guard !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked else {
                if sendReplacement != nil { Log.info("Routing source facts refused: modal state", subsystem: "ax") }
                return false
            }
            return true
        }
        func sourceOwned(ownedPopup: AXUIElement? = nil) -> Bool {
            // Input Cancel may retire its owner after an earlier census. Do not
            // enter the old controls' guarded Help scan before renewing native
            // membership; a latched ownership refusal cannot be undone by the
            // later original-header observation. Keep the deciding bookend too.
            (!inputBusOnly || ownerBoundaryStillCurrent(ownedPopup: ownedPopup))
                && sourceFactsCurrent() && ownerBoundaryStillCurrent(ownedPopup: ownedPopup)
        }
        func sendBusFailure() -> (HonestContract.FailureError, String, [String: Any])? {
            guard let request = sendReplacement, case .bus(let number) = request.destination else { return nil }
            guard let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax),
                  census.strips.filter({ CFEqual($0, physical.strip) }).count == 1,
                  let index = census.strips.firstIndex(where: { CFEqual($0, physical.strip) }) else {
                return (.staleTargetReference, "The bus check lost its original physical source and complete population", [:])
            }
            switch busCheck(into: number, from: index, strips: census.strips, runtime: runtime.ax) {
            case .receivers(let receivers):
                extras["bus_receivers"] = receivers
                return nil
            case .refused(let error, let hint, let facts): return (error, hint, facts)
            }
        }
        let app = AXLogicProElements.appRoot(runtime: runtime)
        let originalFocus: AXUIElement? = app.flatMap { AXHelpers.getAttribute($0, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) }
        guard sourceFactsCurrent() else { return refuse(.staleTargetReference, "Source custody changed before acquisition; nothing was pressed.") }
        if sendOrdinal != nil || inputBusOnly
            || (sendReplacement == nil && OutputAssignment.observed(slotLabel: originalLabel) == .noOutput) {
            guard case .success(let actions) = AXHelpers.getActionNamesResult(slot, runtime: runtime.ax),
                  actions.contains(kAXPressAction as String), sourceFactsCurrent() else {
                return refuse(.readbackUnavailable, "The held routing control does not advertise a current press capability; nothing was pressed.")
            }
            extras["send_ordinal"] = sendOrdinal
        }
        // The last focus read can itself observe a project transition. Renew
        // original source/document custody afterward, before any menu action.
        if let (error, hint, facts) = sendBusFailure() {
            extras.merge(facts) { _, new in new }
            return refuse(error, hint + "; nothing was pressed.")
        }
        if inputBusOnly, includingNonBusInputs
            || AXLocalePolicy.unassignedInputSlotLabel.matches(originalLabel, mode: .exact)
            || InputAssignment.classifiedMenuTitle(originalLabel)?.busOutputAssignment != nil {
            // A foreign system alert can own the keyboard while Logic still
            // reports AXFrontmost. Refuse before opening a native popup that
            // the same keyboard-ownership boundary would forbid us to acquire.
            guard let app, let windows = runtime.onScreenWindowList(),
                  runtime.focusedApplicationPID() == pid,
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 else {
                return refuse(.readbackUnavailable, "The input read requires current Logic keyboard ownership; nothing was pressed.")
            }
        }
        let sendMixerGeometry: HeldSelectionAssociation.MixerViewportGeometry?
        if sendReplacement?.destination != nil, assigned != nil,
           let pair = AXMixerStripBinding.outputAssociation, pair.strip.matches(physical),
           let proof = HeldSelectionAssociation(window: physical.window, logic: runtime,
                expectedProject: nil, requiresProjectReference: false, allowsSelectedChildRailEntry: true),
           CFEqual(proof.mixer, physical.mixer), proof.document.utf8.elementsEqual(physical.document.utf8),
           proof.headers.filter({ CFEqual($0, pair.track.header) }).count == 1 {
            // Presentation restoration duty only, sampled before our popup.
            // A transient post-press layout cannot become the original baseline
            // and this geometry supplies no source or Send-control identity.
            sendMixerGeometry = proof.observedMixerViewportGeometry()
        } else { sendMixerGeometry = nil }
        guard focusAllowsAcquisition() else {
            return refuse(.readbackUnavailable, "Focus or source custody changed before the routing-popup press; nothing was pressed. Checkpoint: focus before source facts.")
        }
        guard sourceFactsCurrent() else {
            return refuse(.readbackUnavailable, "Focus or source custody changed before the routing-popup press; nothing was pressed. Checkpoint: source facts.")
        }
        guard focusAllowsAcquisition() else {
            return refuse(.readbackUnavailable, "Focus or source custody changed before the routing-popup press; nothing was pressed. Checkpoint: focus after source facts.")
        }
        guard sourceOwned() else {
            return refuse(.readbackUnavailable, "Focus or source custody changed before the routing-popup press; nothing was pressed. Checkpoint: original source custody.")
        }
        guard sourceFactsCurrent() else {
            return refuse(.readbackUnavailable, "Focus or source custody changed before the routing-popup press; nothing was pressed. Checkpoint: final source facts.")
        }
        // The deciding AX reads can outlive the request. Renew its existing
        // cancellation, deadline and acquired gate at the actual press boundary;
        // a stopped read must not acquire a popup it can no longer restore.
        guard !Task.isCancelled, OperationTraceContext.current.map({ context in
            !context.cancellationRequested()
                && (context.deadline.map { ContinuousClock.now < $0 } ?? true)
                && (!context.mutationGateAcquired || context.ownsGate())
        }) ?? true else {
            return refuse(.readbackUnavailable, "The routing read request stopped before popup acquisition; nothing was pressed.")
        }
        let capturedPopupEligibleAtPressBoundary: Bool
        if sendOrdinal == nil, !inputBusOnly, sendReplacement == nil {
            guard sourceOwned(), let app,
                  Self.checkedTopLevelOutputPopupMenus(in: app, runtime: runtime.ax)?.isEmpty == true,
                  checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true,
                  let finalWindows = runtime.onScreenWindowList(),
                  Self.checkedLogicOutputPopupWindows(finalWindows, logicPID: pid)?.isEmpty == true,
                  sourceOwned() else {
                return refuse(.readbackUnavailable,
                    "A fresh top-level Logic popup absence could not be proved at the routing press boundary; nothing was pressed.")
            }
            guard !Task.isCancelled, OperationTraceContext.current.map({ context in
                !context.cancellationRequested()
                    && (context.deadline.map { ContinuousClock.now < $0 } ?? true)
                    && (!context.mutationGateAcquired || context.ownsGate())
                    && (!context.mutationGateAcquired
                        || (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil)
            }) ?? true else {
                return refuse(.readbackUnavailable,
                    "The routing read request lost cancellation, deadline or gate custody at the final press boundary; nothing was pressed.")
            }
            capturedPopupEligibleAtPressBoundary = true
        } else {
            capturedPopupEligibleAtPressBoundary = false
        }
        extras["navigation_attempted"] = true
        let press = AXHelpers.performActionResult(slot, kAXPressAction as String, runtime: runtime.ax)
        if case .success = press { extras["popup_press_succeeded"] = true }
        else { extras["popup_press_succeeded"] = false }
        let deadline = Date().addingTimeInterval(Double(timing.popupOpenTimeoutMs) / 1_000)
        defer { observingPopupFocus(nil) }
        if inputBusOnly, sendReplacement == nil, let app, let passiveMixerFocus,
           let popup = NativeOutputReadPopup.read(physical: physical, app: app, pid: pid, runtime: runtime),
           nativePopupScope(popup.root) {
            let source = AXMixerInputSlotBinding(owner: physical, control: slot, source: originalLabel)
            observingPopupFocus {
                // Establish this exact native read's temporary focus before
                // ordinary source rediscovery can query Help. The original
                // passive strip, source control and native popup remain fresh;
                // no association or action permission is renewed here.
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      let current = NativeOutputReadPopup.read(physical: physical, app: app, pid: pid, runtime: runtime),
                      current.matches(popup), nativePopupScope(current.root) else { return false }
                return passiveMixerFocus.permits(nativeInputPopup: current, nativeInputSource: source)
            }
        }
        @Sendable func exactTopLevelWindowScope() -> Bool {
            guard sendOrdinal == nil, !inputBusOnly, sendReplacement == nil,
                  !Task.isCancelled, runtime.logicProPID() == pid,
                  runtime.focusedApplicationPID() == pid, let app,
                  let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(currentApp, app),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String,
                    runtime: runtime.ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app,
                    kAXMainWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, physical.window),
                  case .success(.elements(let appWindows)) = AXHelpers.getAXUIElementArrayRead(
                    app, kAXWindowsAttribute as String, runtime: runtime.ax),
                  appWindows.filter({ CFEqual($0, physical.window) }).count == 1,
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(
                    physical.window, runtime: runtime),
                  document.utf8.elementsEqual(physical.document.utf8),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }
        @Sendable func exactCapturedMixerPopupScope() -> Bool {
            guard sendOrdinal == nil, !inputBusOnly, sendReplacement == nil,
                  !Task.isCancelled, runtime.logicProPID() == pid,
                  runtime.focusedApplicationPID() == pid, let app,
                  let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(currentApp, app),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String,
                    runtime: runtime.ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app,
                    kAXMainWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, physical.window),
                  case .success(.elements(let appWindows)) = AXHelpers.getAXUIElementArrayRead(
                    app, kAXWindowsAttribute as String, runtime: runtime.ax),
                  appWindows.filter({ CFEqual($0, physical.window) }).count == 1,
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(
                    physical.window, runtime: runtime),
                  document.utf8.elementsEqual(physical.document.utf8),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  OperationTraceContext.current.map({ context in
                    !context.cancellationRequested()
                        && (context.deadline.map { ContinuousClock.now < $0 } ?? true)
                        && (!context.mutationGateAcquired || context.ownsGate())
                        && (!context.mutationGateAcquired
                            || (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil)
                  }) ?? true else { return false }
            return true
        }
        @Sendable func capturedPopupActionScopeCurrent() -> Bool {
            guard !Task.isCancelled,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  OperationTraceContext.current.map({ context in
                    !context.cancellationRequested()
                        && (context.deadline.map { ContinuousClock.now < $0 } ?? true)
                        && (!context.mutationGateAcquired || context.ownsGate())
                  }) ?? true else { return false }
            return true
        }
        @Sendable func mixerChildParentMatches(_ root: AXUIElement) -> Bool {
            let parent: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                root, kAXParentAttribute as String, runtime: runtime.ax)
            guard case .success(.some(let rawParent)) = parent,
                  CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return false }
            return CFEqual(unsafeDowncast(rawParent, to: AXUIElement.self), physical.mixer)
        }
        @Sendable func capturedMixerChildPopupState(
            _ held: HeldMixerChildOutputPopup
        ) -> [AXUIElement]? {
            guard exactCapturedMixerPopupScope(), let app,
                  Self.checkedTopLevelOutputPopupMenus(in: app, runtime: runtime.ax)?.isEmpty == true,
                  let menus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax),
                  let windows = runtime.onScreenWindowList(),
                  let popups = Self.checkedLogicOutputPopupWindows(windows, logicPID: pid) else { return nil }
            if menus.isEmpty && popups.isEmpty {
                return exactCapturedMixerPopupScope()
                    && Self.checkedTopLevelOutputPopupMenus(in: app, runtime: runtime.ax)?.isEmpty == true ? [] : nil
            }
            guard menus.count == 1, CFEqual(menus[0], held.root),
                  popups.count == 1,
                  popups[0].number == held.window.number,
                  popups[0].layer == held.window.layer,
                  mixerChildParentMatches(held.root),
                  exactCapturedMixerPopupScope(),
                  Self.checkedTopLevelOutputPopupMenus(in: app, runtime: runtime.ax)?.isEmpty == true,
                  let finalMenus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax),
                  finalMenus.count == 1, CFEqual(finalMenus[0], held.root),
                  let finalWindows = runtime.onScreenWindowList(),
                  let finalPopups = Self.checkedLogicOutputPopupWindows(finalWindows, logicPID: pid),
                  finalPopups.count == 1,
                  finalPopups[0].number == held.window.number,
                  finalPopups[0].layer == held.window.layer else { return nil }
            return [held.root]
        }
        @Sendable func capturedMixerChildPopupCleanupOwned(
            _ held: HeldMixerChildOutputPopup
        ) -> Bool {
            @Sendable func heldCGIdentityOccursOnce(
                _ popups: [LogicOnScreenWindows.Entry]
            ) -> Bool {
                popups.filter {
                    $0.number == held.window.number && $0.layer == held.window.layer
                }.count == 1
            }
            mixerChildCleanupDiagnostic.checkpoint = "initial_scope"
            let initialScope = exactCapturedMixerPopupScope()
            mixerChildCleanupDiagnostic.scopeReads += 1
            if initialScope { mixerChildCleanupDiagnostic.scopeMatches += 1 }
            if mixerChildCleanupDiagnostic.scopeReads == 1 {
                mixerChildCleanupDiagnostic.initialScope = initialScope
            }
            guard initialScope, let app else { return false }
            mixerChildCleanupDiagnostic.checkpoint = "top_level_read"
            guard let topLevel = Self.checkedTopLevelOutputPopupMenus(in: app, runtime: runtime.ax) else {
                return false
            }
            mixerChildCleanupDiagnostic.topLevelRead = true
            mixerChildCleanupDiagnostic.topLevelEmpty = topLevel.isEmpty
            mixerChildCleanupDiagnostic.checkpoint = "top_level_empty"
            guard topLevel.isEmpty else { return false }
            mixerChildCleanupDiagnostic.checkpoint = "direct_root_read"
            guard let menus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax) else {
                return false
            }
            mixerChildCleanupDiagnostic.directRootRead = true
            mixerChildCleanupDiagnostic.directRootCount = menus.count
            mixerChildCleanupDiagnostic.checkpoint = "direct_root_unique"
            guard menus.count == 1 else { return false }
            mixerChildCleanupDiagnostic.directRootSame = CFEqual(menus[0], held.root)
            mixerChildCleanupDiagnostic.checkpoint = "direct_root_same"
            guard mixerChildCleanupDiagnostic.directRootSame else { return false }
            mixerChildCleanupDiagnostic.parentMatched = mixerChildParentMatches(held.root)
            mixerChildCleanupDiagnostic.checkpoint = "parent_match"
            guard mixerChildCleanupDiagnostic.parentMatched else { return false }
            mixerChildCleanupDiagnostic.checkpoint = "cg_read"
            guard let windows = runtime.onScreenWindowList(),
                  let popups = Self.checkedLogicOutputPopupWindows(windows, logicPID: pid) else { return false }
            mixerChildCleanupDiagnostic.cgRead = true
            mixerChildCleanupDiagnostic.cgTotalCount = popups.count
            mixerChildCleanupDiagnostic.heldCGCount = popups.filter {
                $0.number == held.window.number && $0.layer == held.window.layer
            }.count
            mixerChildCleanupDiagnostic.checkpoint = "held_cg_count"
            guard heldCGIdentityOccursOnce(popups) else { return false }
            let finalScope = exactCapturedMixerPopupScope()
            mixerChildCleanupDiagnostic.scopeReads += 1
            if finalScope { mixerChildCleanupDiagnostic.scopeMatches += 1 }
            mixerChildCleanupDiagnostic.checkpoint = "scope_bookend"
            guard finalScope else { return false }
            mixerChildCleanupDiagnostic.checkpoint = "top_level_read"
            guard let finalTopLevel = Self.checkedTopLevelOutputPopupMenus(
                in: app, runtime: runtime.ax) else { return false }
            mixerChildCleanupDiagnostic.topLevelRead = true
            mixerChildCleanupDiagnostic.topLevelEmpty = finalTopLevel.isEmpty
            mixerChildCleanupDiagnostic.checkpoint = "top_level_empty"
            guard finalTopLevel.isEmpty else { return false }
            mixerChildCleanupDiagnostic.checkpoint = "direct_root_read"
            guard let finalMenus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax) else {
                return false
            }
            mixerChildCleanupDiagnostic.directRootRead = true
            mixerChildCleanupDiagnostic.directRootCount = finalMenus.count
            mixerChildCleanupDiagnostic.checkpoint = "direct_root_unique"
            guard finalMenus.count == 1 else { return false }
            mixerChildCleanupDiagnostic.directRootSame = CFEqual(finalMenus[0], held.root)
            mixerChildCleanupDiagnostic.checkpoint = "direct_root_same"
            guard mixerChildCleanupDiagnostic.directRootSame else { return false }
            mixerChildCleanupDiagnostic.parentMatched = mixerChildParentMatches(held.root)
            mixerChildCleanupDiagnostic.checkpoint = "parent_match"
            guard mixerChildCleanupDiagnostic.parentMatched else { return false }
            mixerChildCleanupDiagnostic.checkpoint = "cg_read"
            guard let finalWindows = runtime.onScreenWindowList(),
                  let finalPopups = Self.checkedLogicOutputPopupWindows(
                    finalWindows, logicPID: pid) else { return false }
            mixerChildCleanupDiagnostic.cgRead = true
            mixerChildCleanupDiagnostic.cgTotalCount = finalPopups.count
            mixerChildCleanupDiagnostic.heldCGCount = finalPopups.filter {
                $0.number == held.window.number && $0.layer == held.window.layer
            }.count
            mixerChildCleanupDiagnostic.checkpoint = "held_cg_count"
            guard heldCGIdentityOccursOnce(finalPopups) else { return false }
            mixerChildCleanupDiagnostic.checkpoint = "root_current"
            return true
        }
        @Sendable func mixerChildPopupAcquisition(
            _ root: AXUIElement
        ) -> (held: HeldMixerChildOutputPopup?, waitingForCG: Bool) {
            mixerChildAcquisitionDiagnostic.checkpoint = "press_boundary"
            mixerChildAcquisitionDiagnostic.pressBoundaryEligible = capturedPopupEligibleAtPressBoundary
            guard capturedPopupEligibleAtPressBoundary else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.checkpoint = "scope"
            let scopeCurrent = exactCapturedMixerPopupScope()
            mixerChildAcquisitionDiagnostic.scopeCurrent = scopeCurrent
            guard scopeCurrent, let app else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.checkpoint = "top_level_read"
            guard let topLevel = Self.checkedTopLevelOutputPopupMenus(
                in: app, runtime: runtime.ax) else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.topLevelRead = true
            mixerChildAcquisitionDiagnostic.topLevelCount = topLevel.count
            mixerChildAcquisitionDiagnostic.checkpoint = "top_level_empty"
            guard topLevel.isEmpty else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.checkpoint = "direct_root_read"
            guard let menus = checkedOutputPopupMenus(
                in: physical.mixer, runtime: runtime.ax) else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.directRootRead = true
            mixerChildAcquisitionDiagnostic.directRootCount = menus.count
            mixerChildAcquisitionDiagnostic.checkpoint = "direct_root_unique"
            guard menus.count == 1 else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.directRootSame = CFEqual(menus[0], root)
            mixerChildAcquisitionDiagnostic.checkpoint = "direct_root_same"
            guard mixerChildAcquisitionDiagnostic.directRootSame else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.parentMatched = mixerChildParentMatches(root)
            mixerChildAcquisitionDiagnostic.checkpoint = "parent_match"
            guard mixerChildAcquisitionDiagnostic.parentMatched else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.checkpoint = "cg_read"
            guard let windows = runtime.onScreenWindowList(),
                  let popups = Self.checkedLogicOutputPopupWindows(
                    windows, logicPID: pid) else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.cgRead = true
            mixerChildAcquisitionDiagnostic.cgTotalCount = popups.count
            if popups.isEmpty {
                mixerChildAcquisitionDiagnostic.checkpoint = "cg_wait_scope"
                guard exactCapturedMixerPopupScope() else { return (nil, false) }
                mixerChildAcquisitionDiagnostic.checkpoint = "cg_wait_top_level_read"
                guard Self.checkedTopLevelOutputPopupMenus(
                    in: app, runtime: runtime.ax)?.isEmpty == true else { return (nil, false) }
                mixerChildAcquisitionDiagnostic.checkpoint = "cg_wait_direct_root_read"
                guard let finalMenus = checkedOutputPopupMenus(
                    in: physical.mixer, runtime: runtime.ax) else { return (nil, false) }
                mixerChildAcquisitionDiagnostic.directRootRead = true
                mixerChildAcquisitionDiagnostic.directRootCount = finalMenus.count
                mixerChildAcquisitionDiagnostic.checkpoint = "cg_wait_direct_root_unique"
                guard finalMenus.count == 1 else { return (nil, false) }
                mixerChildAcquisitionDiagnostic.directRootSame = CFEqual(finalMenus[0], root)
                mixerChildAcquisitionDiagnostic.checkpoint = "cg_wait_direct_root_same"
                guard mixerChildAcquisitionDiagnostic.directRootSame else { return (nil, false) }
                mixerChildAcquisitionDiagnostic.parentMatched = mixerChildParentMatches(root)
                mixerChildAcquisitionDiagnostic.checkpoint = "cg_wait_parent_match"
                guard mixerChildAcquisitionDiagnostic.parentMatched else { return (nil, false) }
                mixerChildAcquisitionDiagnostic.waitingForCG = true
                mixerChildAcquisitionDiagnostic.checkpoint = "waiting_for_cg"
                return (nil, true)
            }
            mixerChildAcquisitionDiagnostic.checkpoint = "cg_unique"
            guard popups.count == 1 else { return (nil, false) }
            let held = HeldMixerChildOutputPopup(root: root, window: popups[0])
            mixerChildAcquisitionDiagnostic.checkpoint = "token_state"
            guard capturedMixerChildPopupState(held).map({
                $0.count == 1 && CFEqual($0[0], root)
            }) == true else { return (nil, false) }
            mixerChildAcquisitionDiagnostic.tokenAcquired = true
            mixerChildAcquisitionDiagnostic.checkpoint = "token_acquired"
            return (held, false)
        }
        @Sendable func capturedTopLevelPopupState(
            _ held: HeldOrdinaryOutputPopup
        ) -> [AXUIElement]? {
            guard exactTopLevelWindowScope(), let app,
                  let menus = Self.checkedTopLevelOutputPopupMenus(in: app, runtime: runtime.ax),
                  checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true,
                  let windows = runtime.onScreenWindowList() else { return nil }
            guard let popups = Self.checkedLogicOutputPopupWindows(windows, logicPID: pid) else { return nil }
            if menus.isEmpty && popups.isEmpty {
                return exactTopLevelWindowScope() ? [] : nil
            }
            guard menus.count == 1, CFEqual(menus[0], held.root),
                  popups.count == 1, popups[0] == held.window,
                  let frame = held.window.bounds, !frame.isNull, !frame.isInfinite,
                  frame.width > 0, frame.height > 0,
                  AXHelpers.getPosition(held.root, runtime: runtime.ax) == frame.origin,
                  AXHelpers.getSize(held.root, runtime: runtime.ax) == frame.size,
                  exactTopLevelWindowScope(),
                  let finalMenus = Self.checkedTopLevelOutputPopupMenus(in: app, runtime: runtime.ax),
                  finalMenus.count == 1, CFEqual(finalMenus[0], held.root),
                  checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true,
                  let finalWindows = runtime.onScreenWindowList(),
                  Self.checkedLogicOutputPopupWindows(finalWindows, logicPID: pid) == popups else { return nil }
            return [held.root]
        }
        @Sendable func newlyAcquiredTopLevelPopup() -> HeldOrdinaryOutputPopup? {
            guard capturedPopupEligibleAtPressBoundary,
                  exactTopLevelWindowScope(), let app,
                  let menus = Self.checkedTopLevelOutputPopupMenus(in: app, runtime: runtime.ax),
                  menus.count == 1, let root = menus.first,
                  let windows = runtime.onScreenWindowList() else { return nil }
            guard let popups = Self.checkedLogicOutputPopupWindows(windows, logicPID: pid),
                  popups.count == 1, let frame = popups[0].bounds,
                  !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0,
                  AXHelpers.getPosition(root, runtime: runtime.ax) == frame.origin,
                  AXHelpers.getSize(root, runtime: runtime.ax) == frame.size else { return nil }
            let held = HeldOrdinaryOutputPopup(root: root, window: popups[0])
            guard capturedTopLevelPopupState(held).map({
                $0.count == 1 && CFEqual($0[0], root)
            }) == true else { return nil }
            return held
        }
        var opened: [AXUIElement]?
        var acquiredTopLevelPopup: HeldOrdinaryOutputPopup?
        var acquiredMixerChildPopup: HeldMixerChildOutputPopup?
        var pendingMixerChildRoot: AXUIElement?
        repeat {
            opened = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)
            if let pendingMixerChildRoot {
                mixerChildAcquisitionDiagnostic.pendingRecheckRead = opened != nil
                mixerChildAcquisitionDiagnostic.pendingRecheckCount = opened?.count ?? 0
                mixerChildAcquisitionDiagnostic.pendingRecheckSame = opened.map {
                    $0.count == 1 && CFEqual($0[0], pendingMixerChildRoot)
                } == true
                guard let opened, opened.count == 1,
                      CFEqual(opened[0], pendingMixerChildRoot) else {
                    // Once AX R0 was the sole root awaiting its CG identity,
                    // disappearance or replacement cannot be reclassified as
                    // a fresh ordinary/top-level popup from this same press.
                    mixerChildAcquisitionDiagnostic.checkpoint = "pending_root_changed"
                    opened = nil
                    break
                }
            }
            if pendingMixerChildRoot == nil, opened?.isEmpty == true,
               let held = newlyAcquiredTopLevelPopup() {
                acquiredTopLevelPopup = held
                opened = [held.root]
                break
            }
            if let opened, opened.count == 1 {
                let root = opened[0]
                let acquisition = mixerChildPopupAcquisition(root)
                if let held = acquisition.held {
                    acquiredMixerChildPopup = held
                    break
                }
                if acquisition.waitingForCG {
                    pendingMixerChildRoot = root
                    if timing.pollIntervalMs > 0 {
                        try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs))
                    }
                    continue
                }
            }
            if opened == nil || !(opened?.isEmpty ?? true) || !sourceOwned() { break }
            if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
        } while !Task.isCancelled && Date() < deadline
        if mixerChildAcquisitionDiagnostic.checkpoint != "not_attempted" {
            extras["output_popup_acquisition"] = mixerChildAcquisitionDiagnostic.snapshot()
        }
        let topLevelPopup = acquiredTopLevelPopup
        let mixerChildPopup = acquiredMixerChildPopup
        func publishMixerChildCleanupDiagnostic() {
            if mixerChildPopup != nil {
                extras["output_popup_cleanup"] = mixerChildCleanupDiagnostic.snapshot()
            }
        }
        // Native input and neutral-output menus may be absent from Mixer AXChildren. This
        // read-only alternate discovery is scoped to our own just-issued press,
        // absent pre-existing AX/CG popups and the unchanged original source.
        let nativePopup: NativeOutputReadPopup?
        @Sendable func nativePopupScope(_ root: AXUIElement) -> Bool {
            if inputBusOnly {
                if includingNonBusInputs {
                    guard let input = currentInputMenuAssignment(in: root, runtime: runtime.ax) else { return false }
                    return input != .noInput || hasCheckedNoInputMenu(in: root, runtime: runtime.ax)
                }
                if InputAssignment.classifiedMenuTitle(originalLabel)?.busOutputAssignment != nil {
                    // The label only selects this existing reader. Agreeing live
                    // root/leaf checks, never the label, establish the Bus value.
                    return currentInputMenuBusAssignment(in: root, runtime: runtime.ax) != nil
                }
                return AXLocalePolicy.unassignedInputSlotLabel.matches(originalLabel, mode: .exact)
                    && hasCheckedNoInputMenu(in: root, runtime: runtime.ax)
            }
            return OutputAssignment.observed(slotLabel: originalLabel) == .noOutput
        }
        if sendOrdinal == nil, sendReplacement == nil,
           (inputBusOnly
                ? (AXLocalePolicy.unassignedInputSlotLabel.matches(originalLabel, mode: .exact)
                    || InputAssignment.classifiedMenuTitle(originalLabel)?.busOutputAssignment != nil
                    || (includingNonBusInputs && InputAssignment.classifiedMenuTitle(originalLabel) != nil))
                : OutputAssignment.observed(slotLabel: originalLabel) == .noOutput),
           opened?.isEmpty == true, let app, sourceOwned(),
           let observed = NativeOutputReadPopup.read(physical: physical, app: app, pid: pid, runtime: runtime),
           nativePopupScope(observed.root),
           sourceOwned() {
            nativePopup = observed
            opened = [observed.root]
        } else { nativePopup = nil }
        @Sendable func currentPopupMenus() -> [AXUIElement]? {
            if let topLevelPopup { return capturedTopLevelPopupState(topLevelPopup) }
            if let mixerChildPopup { return capturedMixerChildPopupState(mixerChildPopup) }
            guard let ordinary = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax) else { return nil }
            guard let nativePopup else { return ordinary }
            guard ordinary.isEmpty, let app, let windows = runtime.onScreenWindowList() else { return nil }
            if LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 { return [] }
            guard let current = NativeOutputReadPopup.read(physical: physical, app: app, pid: pid, runtime: runtime),
                  current.matches(nativePopup), nativePopupScope(current.root) else { return nil }
            return [nativePopup.root]
        }
        if nativePopup == nil, let opened, opened.count == 1, let root = opened.first {
            observingPopupFocus {
                // Permit guarded reads for this exact menu's search field, not arbitrary
                // text focus. This uses no Help, and the ordinary source/menu checks still
                // decide every read and Cancel action.
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
                      let app = AXLogicProElements.appRoot(runtime: runtime),
                      AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                      let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
                      CFEqual(main, physical.window),
                      let strips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax),
                      strips.strips.filter({ CFEqual($0, physical.strip) }).count == 1,
                      let menus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax),
                      menus.count == 1, CFEqual(menus[0], root),
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                      AXHelpers.getRole(focus, runtime: runtime.ax) == kAXTextFieldRole as String,
                      case .success(let rows) = AXHelpers.childrenResult(root, runtime: runtime.ax) else { return false }
                // Follow the actual focused parent, not every unrelated destination
                // submenu on every Help read. Positively renew both directions of
                // this original root/search path; no cached permission is retained.
                guard let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: runtime.ax) else { return false }
                if CFEqual(parent, root) {
                    guard rows.filter({ CFEqual($0, focus) }).count == 1 else { return false }
                } else {
                    guard rows.filter({ CFEqual($0, parent) }).count == 1,
                          let parentRole = AXHelpers.getRole(parent, runtime: runtime.ax),
                          parentRole == kAXGroupRole as String || parentRole == "AXMenuItem",
                          let parentRoot: AXUIElement = AXHelpers.getAttribute(parent, kAXParentAttribute as String, runtime: runtime.ax),
                          CFEqual(parentRoot, root),
                          case .success(let children) = AXHelpers.childrenResult(parent, runtime: runtime.ax),
                          children.filter({ CFEqual($0, focus) }).count == 1 else { return false }
                }
                guard
                      let currentFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                      CFEqual(currentFocus, focus),
                      case .success(.some(let doc)) = AXLogicProElements.projectPickerDocumentRead(physical.window, runtime: runtime),
                      doc.utf8.elementsEqual(physical.document.utf8),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                return true
            }
        }
        guard let opened, opened.count == 1, let root = opened.first else {
            extras["popup_menu_state"] = opened?.isEmpty == true ? "not_observed" : "unknown"
            return refuse(.readbackUnavailable, "The press did not establish one popup owned by the unchanged source; no destination was selected and no unowned cleanup was attempted.")
        }
        func interrupted() -> Bool {
            Task.isCancelled || OperationTraceContext.current?.cancellationRequested() == true
        }
        // A retired element can remain in AXFocusedUIElement. Pointer equality
        // is not restoration unless that exact focus still has its current
        // reciprocal path in the original focused window. These receipt reads
        // grant no assignment or cleanup authority.
        @Sendable func focusRestorationProved() -> Bool {
            guard let originalFocus, let app,
                  let currentFocus: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(originalFocus, currentFocus),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(focusedWindow, physical.window),
                  case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(app,
                    kAXWindowsAttribute as String, runtime: runtime.ax),
                  windows.filter({ CFEqual($0, physical.window) }).count == 1,
                  HeldSelectionAssociation.path(currentFocus, to: physical.window, ax: runtime.ax) != nil,
                  let finalFocus: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(finalFocus, currentFocus),
                  let finalWindow: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(finalWindow, physical.window) else { return false }
            return true
        }
        // Cleanup renews the exact already-acquired output control without Help.
        // A stopped reading stays stopped: no checkmark, scan result or assignment
        // is recovered or published by this private cancellation inverse.
        @Sendable func cleanupSourceOwned() -> Bool {
            guard sendOrdinal == nil, !inputBusOnly,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
                  let app, AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  physical.currentIndex(runtime: runtime) != nil,
                  case .success(let children) = AXHelpers.childrenResult(physical.strip, runtime: runtime.ax),
                  children.filter({ CFEqual($0, slot) }).count == 1,
                  AXHelpers.getRole(slot, runtime: runtime.ax) == kAXButtonRole as String,
                  case .success(.some(let label)) = AXHelpers.getAttributeResult(slot,
                    kAXDescriptionAttribute as String, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError>,
                  label.utf8.elementsEqual(originalLabel.utf8),
                  transportStillStopped(),
                  !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked else { return false }
            return ownerBoundaryStillCurrent()
                && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }
        @Sendable func cleanupMenuOwned() -> Bool {
            guard cleanupSourceOwned(), let current = currentPopupMenus(),
                  current.count == 1, CFEqual(current[0], root) else { return false }
            return cleanupSourceOwned()
        }
        @Sendable func exactOrdinaryOutputOwner() -> Bool {
            guard sendOrdinal == nil, !inputBusOnly, sendReplacement == nil,
                  !Task.isCancelled, runtime.logicProPID() == pid,
                  runtime.focusedApplicationPID() == pid, let app,
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String,
                    runtime: runtime.ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app,
                    kAXMainWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, physical.window),
                  case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(app,
                    kAXWindowsAttribute as String, runtime: runtime.ax),
                  windows.filter({ CFEqual($0, physical.window) }).count == 1,
                  routingFocusedWindowMatches(AXHelpers.getAttributeResult(app,
                    kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                    window: physical.window, ownedPopup: root, mixer: physical.mixer,
                    runtime: runtime.ax),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(
                    physical.window, runtime: runtime),
                  document.utf8.elementsEqual(physical.document.utf8),
                  case .found(let mixer) = AXLogicProElements.mixerAreaLookup(
                    in: physical.window, runtime: runtime), CFEqual(mixer, physical.mixer),
                  let strips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(
                    in: physical.mixer, runtime: runtime.ax),
                  strips.strips.filter({ CFEqual($0, physical.strip) }).count == 1,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }
        @Sendable func exactOrdinaryOutputMenu() -> Bool {
            guard exactOrdinaryOutputOwner(), let menus = currentPopupMenus(),
                  menus.count == 1, CFEqual(menus[0], root) else { return false }
            return exactOrdinaryOutputOwner()
        }
        @Sendable func exactOrdinaryOutputReadCustody() -> Bool {
            if let topLevelPopup {
                return capturedTopLevelPopupState(topLevelPopup).map {
                    $0.count == 1 && CFEqual($0[0], root)
                } == true
            }
            if let mixerChildPopup {
                return capturedMixerChildPopupState(mixerChildPopup).map {
                    $0.count == 1 && CFEqual($0[0], root)
                } == true
            }
            guard exactOrdinaryOutputMenu(),
                  case .success(let children) = AXHelpers.childrenResult(
                    physical.strip, runtime: runtime.ax),
                  children.filter({ CFEqual($0, slot) }).count == 1,
                  AXHelpers.getRole(slot, runtime: runtime.ax) == kAXButtonRole as String,
                  case .success(.some(let label)) = AXHelpers.getAttributeResult(slot,
                    kAXDescriptionAttribute as String,
                    runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError>,
                  label.utf8.elementsEqual(originalLabel.utf8), transportStillStopped(),
                  !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked else { return false }
            return exactOrdinaryOutputMenu()
        }
        func cleanupExactOrdinaryOutputRoot() -> (accepted: Bool, closed: Bool) {
            if topLevelPopup != nil || mixerChildPopup != nil {
                defer { publishMixerChildCleanupDiagnostic() }
                func currentRoot() -> Bool {
                    if let topLevelPopup {
                        return capturedTopLevelPopupState(topLevelPopup).map {
                            $0.count == 1 && CFEqual($0[0], root)
                        } == true
                    }
                    guard let mixerChildPopup else { return false }
                    return capturedMixerChildPopupCleanupOwned(mixerChildPopup)
                }
                guard currentRoot() else { return (false, false) }
                mixerChildCleanupDiagnostic.checkpoint = "action_names_first_read"
                guard case .success(let firstActions) = AXHelpers.getActionNamesResult(
                    root, runtime: runtime.ax) else { return (false, false) }
                mixerChildCleanupDiagnostic.actionNamesReads += 1
                guard firstActions.contains(kAXCancelAction as String) else {
                    mixerChildCleanupDiagnostic.checkpoint = "cancel_first_present"
                    return (false, false)
                }
                mixerChildCleanupDiagnostic.cancelPresentReads += 1
                guard currentRoot() else { return (false, false) }
                mixerChildCleanupDiagnostic.checkpoint = "action_names_second_read"
                guard case .success(let secondActions) = AXHelpers.getActionNamesResult(
                    root, runtime: runtime.ax) else { return (false, false) }
                mixerChildCleanupDiagnostic.actionNamesReads += 1
                guard secondActions.contains(kAXCancelAction as String) else {
                    mixerChildCleanupDiagnostic.checkpoint = "cancel_second_present"
                    return (false, false)
                }
                mixerChildCleanupDiagnostic.cancelPresentReads += 1
                guard currentRoot() else { return (false, false) }
                let actionScope = capturedPopupActionScopeCurrent()
                mixerChildCleanupDiagnostic.actionScope = actionScope
                mixerChildCleanupDiagnostic.checkpoint = "action_scope"
                guard actionScope else { return (false, false) }
                let accepted: Bool
                if case .success = AXHelpers.performActionResult(
                    root, kAXCancelAction as String, runtime: runtime.ax) { accepted = true }
                else { accepted = false }
                mixerChildCleanupDiagnostic.performAction = accepted ? "accepted" : "failed"
                mixerChildCleanupDiagnostic.checkpoint = "perform_action"
                let closed = topLevelPopup.map { capturedTopLevelPopupState($0)?.isEmpty == true }
                    ?? mixerChildPopup.map { capturedMixerChildPopupState($0)?.isEmpty == true }
                    ?? false
                if accepted {
                    mixerChildCleanupDiagnostic.closure = closed ? "immediate" : "pending"
                    mixerChildCleanupDiagnostic.checkpoint = "closure"
                } else {
                    mixerChildCleanupDiagnostic.closure = closed ? "closed_without_acceptance" : "not_closed"
                }
                guard accepted, closed else {
                    return (accepted, false)
                }
                mixerChildCleanupDiagnostic.checkpoint = "closed"
                return (true, true)
            }
            guard exactOrdinaryOutputMenu(),
                  runtime.ax.actionNames(root).contains(kAXCancelAction as String),
                  exactOrdinaryOutputMenu() else { return (false, false) }
            let accepted: Bool
            if case .success = AXHelpers.performActionResult(
                root, kAXCancelAction as String, runtime: runtime.ax) { accepted = true }
            else { accepted = false }
            guard accepted, exactOrdinaryOutputOwner(),
                  checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true,
                  runtime.onScreenWindowList().map({
                    LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0
                  }) == true else { return (accepted, false) }
            return (accepted, exactOrdinaryOutputOwner())
        }
        func cancelledReading(priorCancelSucceeded: Bool = false) async -> CheckedOutputReading {
            let cleanup = await Task { @Sendable in
                Self.$interruptedOutputPopupInverse.withValue(true) {
                    let noHelp = AXHelpers.HelpReadGuard(allowHelpReads: false,
                        stop: { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil })
                    return AXHelpers.HelpReadGuard.$current.withValue(noHelp) { () -> (Bool, Bool, Bool) in
                        if cleanupSourceOwned(),
                           checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true,
                           runtime.onScreenWindowList().map({ LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 }) == true {
                            return (false, true, focusRestorationProved())
                        }
                        guard cleanupMenuOwned(), runtime.ax.actionNames(root).contains(kAXCancelAction as String),
                              cleanupMenuOwned() else { return (false, false, focusRestorationProved()) }
                        let accepted: Bool
                        if case .success = AXHelpers.performActionResult(root, kAXCancelAction as String, runtime: runtime.ax) {
                            accepted = true
                        } else { accepted = false }
                        let closed = cleanupSourceOwned()
                            && checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true
                            && runtime.onScreenWindowList().map { LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 } == true
                        return (accepted, closed, focusRestorationProved())
                    }
                }
            }.value
            extras["popup_cancel_succeeded"] = priorCancelSucceeded || cleanup.0
            extras["popup_menu_state"] = cleanup.1 ? "closed" : "not_restored"
            extras["focus_restoration"] = cleanup.2 ? "restored" : "not_restored"
            return refuse(.cancelled, "The output reading was cancelled; no assignment is published and only its still-owned popup may be reversed.")
        }
        if interrupted() { return await cancelledReading() }
        guard sourceOwned(ownedPopup: root) || exactOrdinaryOutputReadCustody() else {
            if interrupted() { return await cancelledReading() }
            let cleanup = cleanupExactOrdinaryOutputRoot()
            extras["popup_cancel_succeeded"] = cleanup.accepted
            extras["popup_menu_state"] = cleanup.closed ? "closed" : "not_restored"
            return refuse(.readbackUnavailable,
                "The acquired popup lost source read custody; only its exact cleanup-owned root was eligible for cancellation.")
        }
        @Sendable func menuOwned(preservingOriginalLabel: Bool = true) -> Bool {
            if let topLevelPopup {
                return capturedTopLevelPopupState(topLevelPopup).map {
                    $0.count == 1 && CFEqual($0[0], root)
                } == true
            }
            if let mixerChildPopup {
                return capturedMixerChildPopupState(mixerChildPopup).map {
                    $0.count == 1 && CFEqual($0[0], root)
                } == true
            }
            // Renew source facts and root membership before the one deciding
            // complete physical/window/document boundary. Neither grants action
            // authority on its own, and no earlier census is reused as permission.
            if preservingOriginalLabel, exactOrdinaryOutputReadCustody() { return true }
            guard sourceFactsCurrent(preservingOriginalLabel: preservingOriginalLabel),
                  let current = currentPopupMenus() else { return false }
            return current.count == 1 && CFEqual(current[0], root) && ownerBoundaryStillCurrent(ownedPopup: root)
        }
        // Two agreeing reads bracketed by the same source/menu, not an atomic graph snapshot.
        func checkedChoice(observingBusNumbers: (([Int]) -> Void)? = nil) -> OutputAssignment? {
            if let mixerChildPopup,
               capturedMixerChildPopupState(mixerChildPopup).map({
                   $0.count == 1 && CFEqual($0[0], root)
               }) != true { return nil }
            if inputBusOnly { return currentInputMenuBusAssignment(in: root, runtime: runtime.ax).map(OutputAssignment.bus) }
            return currentOutputMenuAssignment(in: root, runtime: runtime.ax,
                observingBusNumbers: sendOrdinal == nil ? observingBusNumbers : nil)
        }
        var firstBusNumbers: [Int]?
        var secondBusNumbers: [Int]?
        let firstInput = includingNonBusInputs ? currentInputMenuAssignment(in: root, runtime: runtime.ax) : nil
        let first = includingNonBusInputs ? firstInput?.busOutputAssignment : checkedChoice(observingBusNumbers: { firstBusNumbers = $0 })
        let secondOwned = menuOwned()
        let secondInput = includingNonBusInputs && secondOwned ? currentInputMenuAssignment(in: root, runtime: runtime.ax) : nil
        let second = includingNonBusInputs ? secondInput?.busOutputAssignment : (secondOwned ? checkedChoice(observingBusNumbers: { secondBusNumbers = $0 }) : nil)
        let inputFactsAgree = firstInput != nil && secondInput == firstInput
        let sendChecks = sendOrdinal == nil ? nil : sendMenuNonRoutingChecks(in: root, runtime: runtime.ax)
        let firstMode = observingSendMode ? currentSendMode(in: root, runtime: runtime.ax) : nil
        let secondMode = observingSendMode && menuOwned() ? currentSendMode(in: root, runtime: runtime.ax) : nil
        let modeEvidence = firstMode != nil && firstMode == secondMode ? firstMode : nil
        let dataOwned = menuOwned()
        if let initialRequest = sendReplacement, let sendOrdinal {
            var effective = initialRequest
            if effective.modeChange != nil {
                effective.expected = first
                effective.destination = first
            }
            let request = effective
            func sameOriginalSendControl() -> Bool {
                if let assigned {
                    return assignedControl().map { current in
                        assigned.matches(current) && (requiredSendControl.map { $0.matches(current) } ?? true)
                    } == true
                }
                if let restoringEmpty {
                    return soleEmptySend(in: physical.strip, runtime: runtime.ax).map { restoringEmpty.matches($0) } == true
                }
                return false
            }
            func expectedCheckedBefore(fresh: Bool = false) -> Bool {
                if let mode = request.modeChange {
                    guard let modeEvidence, modeEvidence.mode == mode.expected,
                          first != nil, first != .noOutput, first == second, !fresh || checkedChoice() == first,
                          currentSendMode(in: root, runtime: runtime.ax) == modeEvidence else { return false }
                    return true
                }
                if request.creation != nil {
                    return checkedRemovedSendMenu(in: root, nonRoutingChecks: [], runtime: runtime.ax)
                }
                if let restoration = request.restoration {
                    return checkedRemovedSendMenu(in: root, nonRoutingChecks: restoration.nonRoutingChecks,
                        runtime: runtime.ax)
                }
                if let inverse = request.occupiedInverse {
                    guard inverse.source.pair.strip.matches(physical),
                          inverse.permits(runtime: runtime, ownedPopup: root),
                          assigned.map({ inverse.control.matches($0) }) == true,
                          sendChecks == inverse.nonRoutingChecks else { return false }
                }
                if let created = request.createdRemoval {
                    guard created.source.pair.strip.matches(physical),
                          created.permits(runtime: runtime, ownedPopup: root),
                          assigned.map({ created.control.matches($0) }) == true,
                          sendChecks == created.nonRoutingChecks, modeEvidence == created.mode,
                          currentSendMode(in: root, runtime: runtime.ax) == created.mode else { return false }
                }
                return first == request.expected && second == first && (!fresh || checkedChoice() == request.expected)
            }
            func normalized(_ slots: [SendSlotObservation]) -> [SendSlotObservation] {
                if request.modeChange != nil { return slots }
                return slots.map { slot in
                    var result = slot
                    if result.ordinal == sendOrdinal { result.destinationDisplay = nil }
                    return result
                }
            }
            func protectedChecksAfter(_ after: CheckedOutputReading) -> Bool {
                guard let mode = request.modeChange else { return after.sendNonRoutingChecks == sendChecks }
                guard let before = modeEvidence, let current = after.sendMode else { return false }
                return current.mode == mode.desired && current.independentPan == before.independentPan
                    && current.otherChecks == before.otherChecks
            }
            let population = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax)?.strips
            let protectedSends = AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax)
            let singleton = soleAssignedSend(in: physical.strip, runtime: runtime.ax)
            let modePeerFootprints: [[SendSlotObservation]]?
            if request.modeChange != nil, let population {
                let reads = population.map { AXLogicProElements.sendSlotObservations(in: $0, runtime: runtime.ax) }
                modePeerFootprints = reads.allSatisfy({ $0 != nil }) ? reads.compactMap { $0 } : nil
            } else { modePeerFootprints = nil }
            func modePeersHeld(_ current: [AXUIElement], currentSource: AXUIElement? = nil) -> Bool {
                guard request.modeChange != nil else { return true }
                guard let population, let before = modePeerFootprints, current.count == population.count,
                      before.count == population.count else { return false }
                let expected = population.map { CFEqual($0, physical.strip) ? currentSource ?? physical.strip : $0 }
                guard zip(current, expected).allSatisfy({ CFEqual($0, $1) }) else { return false }
                for index in current.indices where !CFEqual(population[index], physical.strip) {
                    guard AXLogicProElements.sendSlotObservations(in: current[index], runtime: runtime.ax) == before[index] else { return false }
                }
                return true
            }
            func modeRawHeld(_ control: AXLogicProElements.AssignedSendMenuControl?, slots: [SendSlotObservation]?) -> Bool {
                guard request.modeChange != nil else { return true }
                guard let control, let knob = control.level,
                      let slot = slots?.first(where: { $0.ordinal == control.ordinal }) else { return false }
                let reading: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(knob,
                    kAXValueAttribute as String, runtime: runtime.ax)
                guard case .success(.some(let value)) = reading, CFGetTypeID(value) == CFNumberGetTypeID(),
                      let number = value as? NSNumber, number.doubleValue.isFinite else { return false }
                return number.doubleValue == slot.levelRaw
            }
            @Sendable func writerContextCurrent(ownedPopup: AXUIElement? = nil,
                preservingOriginalLabel: Bool = true) -> Bool {
                guard sourceFactsCurrent(preservingOriginalLabel: preservingOriginalLabel), ownerBoundaryStillCurrent(ownedPopup: ownedPopup),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      runtime.focusedApplicationPID() == pid, let app,
                      AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                      let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
                      CFEqual(main, physical.window),
                      routingFocusedWindowMatches(AXHelpers.getAttributeResult(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                          window: physical.window, ownedPopup: ownedPopup, mixer: physical.mixer, runtime: runtime.ax),
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) else { return false }
                let focusAllowed: Bool
                if originalFocus.map({ CFEqual($0, focus) }) == true { focusAllowed = focusAllowsAcquisition() }
                else if let ownedPopup,
                        AXHelpers.getRole(focus, runtime: runtime.ax) == kAXTextFieldRole as String,
                        case .success(let rows) = AXHelpers.childrenResult(ownedPopup, runtime: runtime.ax),
                        let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: runtime.ax) {
                    if CFEqual(parent, ownedPopup) {
                        focusAllowed = rows.filter { CFEqual($0, focus) }.count == 1
                    } else {
                        let role = AXHelpers.getRole(parent, runtime: runtime.ax)
                        let parentRoot: AXUIElement? = AXHelpers.getAttribute(parent, kAXParentAttribute as String, runtime: runtime.ax)
                        let children = try? AXHelpers.childrenResult(parent, runtime: runtime.ax).get()
                        focusAllowed = rows.filter { CFEqual($0, parent) }.count == 1
                            && (role == kAXGroupRole as String || role == kAXMenuItemRole as String)
                            && parentRoot.map { CFEqual($0, ownedPopup) } == true
                            && children?.filter { CFEqual($0, focus) }.count == 1
                    }
                } else { focusAllowed = false }
                guard focusAllowed,
                      let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                      CFEqual(focus, finalFocus), sourceFactsCurrent(preservingOriginalLabel: preservingOriginalLabel), ownerBoundaryStillCurrent(ownedPopup: ownedPopup),
                      runtime.focusedApplicationPID() == pid,
                      AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true else { return false }
                return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
            }
            @Sendable func writerMenuOwned(preservingOriginalLabel: Bool = true) -> Bool {
                menuOwned(preservingOriginalLabel: preservingOriginalLabel)
                    && writerContextCurrent(ownedPopup: root, preservingOriginalLabel: preservingOriginalLabel)
                    && menuOwned(preservingOriginalLabel: preservingOriginalLabel)
                    && writerContextCurrent(ownedPopup: root, preservingOriginalLabel: preservingOriginalLabel)
            }
            func writeBoundary() -> Bool {
                guard writerMenuOwned(), let population, let protectedSends,
                      let fresh = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax)?.strips,
                      fresh.count == population.count, zip(fresh, population).allSatisfy({ CFEqual($0, $1) }),
                      AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax) == protectedSends,
                      sameOriginalSendControl() else { return false }
                if request.modeChange != nil {
                    guard modePeersHeld(fresh),
                          AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax) == protectedSends,
                          sameOriginalSendControl(), modeRawHeld(assigned, slots: protectedSends) else { return false }
                }
                if let creation = request.creation {
                    guard creation.population.count == population.count,
                          zip(creation.population, population).allSatisfy({ CFEqual($0, $1) }),
                          creation.peerSlots.count == population.count,
                          zip(population, creation.peerSlots).allSatisfy({
                            AXLogicProElements.sendSlotObservations(in: $0.0, runtime: runtime.ax) == $0.1
                          }) else { return false }
                }
                if let restoration = request.restoration,
                   !restoration.source.permits(runtime: runtime, ownedPopup: root) { return false }
                if let inverse = request.occupiedInverse {
                    guard inverse.permits(runtime: runtime, ownedPopup: root),
                          checkedChoice() == inverse.checkedAfter,
                          sendMenuNonRoutingChecks(in: root, runtime: runtime.ax) == inverse.nonRoutingChecks,
                          inverse.permits(runtime: runtime, ownedPopup: root) else { return false }
                }
                if let created = request.createdRemoval {
                    guard created.permits(runtime: runtime, ownedPopup: root), checkedChoice() == .stereoOutput,
                          sendMenuNonRoutingChecks(in: root, runtime: runtime.ax) == created.nonRoutingChecks,
                          currentSendMode(in: root, runtime: runtime.ax) == created.mode,
                          created.permits(runtime: runtime, ownedPopup: root) else { return false }
                }
                if let nameHeld = SendRemovalSagaAdapter.requiredNameCheck, !nameHeld(physical) { return false }
                return writerMenuOwned()
            }
            func closeBeforeRefusal(_ error: HonestContract.FailureError, _ hint: String) -> CheckedOutputReading {
                if writerMenuOwned(), runtime.ax.actionNames(root).contains(kAXCancelAction as String), writerMenuOwned() {
                    _ = AXHelpers.performActionResult(root, kAXCancelAction as String, runtime: runtime.ax)
                }
                extras["popup_menu_state"] = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true
                    && runtime.onScreenWindowList().map({ LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 }) == true ? "closed" : "not_restored"
                return refuse(error, hint)
            }
            guard dataOwned, expectedCheckedBefore() else {
                return closeBeforeRefusal(.staleSnapshot, "Checked current send did not agree with expected_current; no destination was pressed.")
            }
            let slotState = request.restoration?.before ?? protectedSends?.first(where: { $0.ordinal == sendOrdinal })
            guard let population, let protectedSends,
                  request.creation != nil || (slotState?.bypassed != nil && slotState?.levelRaw?.isFinite == true),
                  let sendChecks, request.creation != nil || !sendChecks.isEmpty,
                  modeRawHeld(assigned, slots: protectedSends), writeBoundary() else {
                return closeBeforeRefusal(.readbackUnavailable, "The exact occupied send, protected level/bypass/checkmarks or write boundary did not remain observed; nothing was selected.")
            }
            if let required = SendRemovalSagaAdapter.requiredBeforeState,
               required.footprint != protectedSends || required.nonRoutingChecks != sendChecks {
                return closeBeforeRefusal(.staleSnapshot,
                    "The independently observed Send footprint or checked mode no longer agrees at the deciding popup; nothing was selected.")
            }
            if request.restoration != nil || request.creation != nil { extras["before"] = ["state": "observed_empty"] }
            else { extras["before"] = request.expected?.json }
            extras["destination"] = request.destination?.json ?? ["kind": "no_send"]
            if let mode = request.modeChange {
                extras["before"] = mode.expected.rawValue; extras["mode"] = mode.desired.rawValue
                extras["checked_destination"] = first?.json
                extras["level_raw"] = slotState?.levelRaw; extras["bypassed"] = slotState?.bypassed
                extras["independent_pan"] = modeEvidence?.independentPan
                extras["protected_nonrouting_titles"] = modeEvidence?.otherChecks
            }
            extras["strip_count_before"] = population.count
            if request.restoration == nil, let assigned,
               request.modeChange.map({ $0.expected == $0.desired }) ?? (request.expected == request.destination) {
                // Reapplying an already checked destination can retire Logic's
                // controls. A no-op closes only its owned popup; it never presses
                // a destination or borrows mutation-time label-change authority.
                guard writerMenuOwned(),
                      case .success(let actions) = AXHelpers.getActionNamesResult(root, runtime: runtime.ax),
                      actions.contains(kAXCancelAction as String), writeBoundary() else {
                    return closeBeforeRefusal(.readbackUnavailable,
                        "The matching send lost its owned popup before cleanup; nothing was selected.")
                }
                let cancelled = AXHelpers.performActionResult(root, kAXCancelAction as String, runtime: runtime.ax)
                if case .success = cancelled { extras["popup_cancel_succeeded"] = true }
                else { extras["popup_cancel_succeeded"] = false }
                // Cancel acknowledges the action before the native popup has
                // necessarily disappeared. Observe its bounded settlement;
                // never send a second action or turn an unreadable into absence.
                let closeDeadline = Date().addingTimeInterval(Double(timing.popupCloseTimeoutMs) / 1_000)
                var closed = false
                repeat {
                    guard !interrupted(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                          runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
                          let menus = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax),
                          menus.isEmpty || (menus.count == 1 && CFEqual(menus[0], root)),
                          let windows = runtime.onScreenWindowList() else { break }
                    closed = menus.isEmpty && LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0
                    if closed || Date() >= closeDeadline { break }
                    if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
                } while Date() < closeDeadline
                extras["popup_menu_state"] = closed ? "closed" : "not_restored"
                guard closed, writerContextCurrent(),
                      let finalControl = assignedControl(), assigned.matches(finalControl),
                      AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax) == protectedSends,
                      let finalPopulation = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax)?.strips,
                      finalPopulation.count == population.count,
                      zip(finalPopulation, population).allSatisfy({ CFEqual($0, $1) }),
                      writerContextCurrent() else {
                    return refuse(.readbackUnavailable,
                        "The matching send lost its original source or protected state during cleanup; nothing was selected.")
                }
                if let mode = request.modeChange { extras["after"] = mode.desired.rawValue }
                else { extras["after"] = request.expected?.json }
                extras["changed"] = false
                extras["strip_count_after"] = population.count
                extras["verify_source"] = "ax_send_menu_checkmark"
                extras["snapshot_atomic"] = false
                return .init(result: .success(HonestContract.encodeStateA(extras: extras)),
                    assignment: request.expected, sendNonRoutingChecks: sendChecks)
            }
            // Observe retained-original identifiers for diagnosis only. Neither
            // a repeated identifier nor its absence changes CF/action authority.
            var identifiers: [String: Any] = [:]
            var identifierStatuses: [String: Int32] = [:]
            let originals = assigned.map { [("strip", physical.strip), ("send_group", $0.group),
                ("send_list", $0.list), ("send_bypass", $0.bypass)] } ?? [("strip", physical.strip), ("empty_send", slot)]
            for (key, original) in originals {
                let reading: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                    original, kAXIdentifierAttribute as String, runtime: runtime.ax)
                switch reading {
                case .success(let value):
                    identifiers[key] = value as Any? ?? NSNull()
                    identifierStatuses[key] = 0
                case .failure(let error):
                    identifiers[key] = NSNull()
                    identifierStatuses[key] = error.raw
                }
            }
            extras["pre_press_source_identifiers"] = identifiers
            extras["pre_press_identifier_read_status"] = identifierStatuses
            func destinationChoice() -> OutputMenuChoice {
                if let mode = request.modeChange { return sendModeMenuChoice(mode.desired, in: root, runtime: runtime.ax) }
                return request.destination.map { sendMenuChoice(for: $0, in: root, runtime: runtime.ax) }
                    ?? sendRemovalMenuChoice(in: root, runtime: runtime.ax)
            }
            let choice = destinationChoice()
            guard case .item(let item, let path) = choice,
                  AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime.ax) as Bool? == true,
                  case .success(let actions) = AXHelpers.getActionNamesResult(item, runtime: runtime.ax),
                  actions.contains(kAXPressAction as String), writeBoundary(),
                  expectedCheckedBefore(fresh: true), sendMenuNonRoutingChecks(in: root, runtime: runtime.ax) == sendChecks,
                  case .item(let finalItem, let finalPath) = destinationChoice(),
                  CFEqual(item, finalItem), path == finalPath, writeBoundary() else {
                extras["destination_choice_failure"] = choice.failureLabel
                return closeBeforeRefusal(.staleTargetReference, "No unique offered send destination survived the final source/menu/action checks; nothing was selected.")
            }
            // The offered-leaf/action lookup may have changed a bus receiver.
            // Renew the existing loop/receiver proof after it, then the source
            // and owned write boundary before the single destination action.
            if case .bus = request.destination {
                if let (error, hint, facts) = sendBusFailure() {
                    extras.merge(facts) { _, new in new }
                    return closeBeforeRefusal(error, hint + "; read with the popup open, nothing was selected.")
                }
                guard writeBoundary() else {
                    return closeBeforeRefusal(.staleTargetReference, "Source or protected state changed after the final bus check; nothing was selected.")
                }
            }
            if assigned != nil {
                // Final destination and receiver reads may observe a mode or
                // Independent Pan edit on any occupied Send. Renew its exact
                // checked before-state after those reads, before the action.
                guard expectedCheckedBefore(fresh: true),
                      sendMenuNonRoutingChecks(in: root, runtime: runtime.ax) == sendChecks,
                      writerMenuOwned() else {
                    return closeBeforeRefusal(.staleSnapshot, "Checked Send mode or protected pan state changed at the final boundary; no Send leaf was pressed.")
                }
            }
            extras["write_attempted"] = true; extras["menu_path"] = path
            _ = AXHelpers.performActionResult(item, kAXPressAction as String, runtime: runtime.ax)
            // Only the attempted destination press may change this display label.
            // Original CF control/path custody, readable label, transport and owner
            // guards still apply; a fresh checked destination decides the effect.
            let cleanup = await closeOutputPopup(runtime: runtime, timing: timing, waitForSelfClose: true,
                cleaner: { runtime in
                    guard writerMenuOwned(preservingOriginalLabel: false),
                          runtime.ax.actionNames(root).contains(kAXCancelAction as String),
                          writerMenuOwned(preservingOriginalLabel: false) else {
                        return .couldNotDismiss(initialPopupCount: 1, remainingPopupCount: 1)
                    }
                    _ = AXHelpers.performActionResult(root, kAXCancelAction as String, runtime: runtime.ax)
                    return checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true ? .dismissed
                        : .couldNotDismiss(initialPopupCount: 1, remainingPopupCount: 1)
                }, permittingCleanup: { writerMenuOwned(preservingOriginalLabel: false) })
            extras.merge(cleanup) { _, new in new }
            func uncertain(_ hint: String, checkpoint: String? = nil) -> CheckedOutputReading {
                let acquisition: String
                do {
                    try SessionPopulationObservation.requireOwnedAcquisition()
                    acquisition = "current"
                } catch {
                    acquisition = String(describing: error)
                }
                if let checkpoint { extras["verification_checkpoint"] = checkpoint }
                extras["acquisition_at_refusal"] = acquisition
                Log.info("Occupied Send verification refused: checkpoint=\(checkpoint ?? "unspecified"), acquisition=\(acquisition): \(hint)", subsystem: "ax")
                extras["hint"] = hint
                return .init(result: .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras)), assignment: nil)
            }
            let contextAfterPress = writerContextCurrent(preservingOriginalLabel: false)
            let observedControl = assignedControl()
            let controlAfterPress = assigned.flatMap { original in observedControl.map { original.matches($0) } } == true
            if let assigned, let current = observedControl {
                extras["post_press_control_identity"] = ["observed": true,
                    "ordinal": assigned.ordinal == current.ordinal,
                    "group": CFEqual(assigned.group, current.group),
                    "list": CFEqual(assigned.list, current.list),
                    "bypass": CFEqual(assigned.bypass, current.bypass),
                    "parent_proxy": CFEqual(assigned.parentProxy, current.parentProxy),
                    "source_path": assigned.sourcePath.count == current.sourcePath.count
                        && zip(assigned.sourcePath, current.sourcePath).allSatisfy { CFEqual($0, $1) }]
            } else {
                extras["post_press_control_identity"] = ["observed": false]
            }
            let axPopupAbsent = checkedOutputPopupMenus(in: physical.mixer, runtime: runtime.ax)?.isEmpty == true
            let cgPopupAbsent = runtime.onScreenWindowList().map({ LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 }) == true
            extras["post_press_custody"] = ["context_current": contextAfterPress,
                "original_send_control_current": controlAfterPress,
                "ax_popup_absent": axPopupAbsent, "cg_popup_absent": cgPopupAbsent]
            Log.info("Send post-press custody: context=\(contextAfterPress), control=\(controlAfterPress), ax_popup_absent=\(axPopupAbsent), cg_popup_absent=\(cgPopupAbsent)", subsystem: "ax")
            if let restoration = request.restoration {
                guard axPopupAbsent, cgPopupAbsent else {
                    return uncertain("The explicit inverse did not close its owned popup; no further action was attempted.")
                }
                return await finishSendRestoration(restoration, original: physical, population: population,
                    extras: extras, runtime: runtime, timing: timing)
            }
            if let creation = request.creation {
                guard axPopupAbsent, cgPopupAbsent,
                      request.destination == .stereoOutput else {
                    return uncertain("Fresh creation lost its original empty control or owned popup absence.")
                }
                return await finishFreshSendCreation(original: physical, population: population, peerSlots: creation.peerSlots,
                    extras: extras, runtime: runtime, timing: timing)
            }
            if request.destination == nil {
                guard axPopupAbsent, cgPopupAbsent, let assigned, let singleton, let expected = request.expected,
                      singleton.control.matches(assigned), singleton.slots == protectedSends else {
                    return uncertain("Send removal lost popup absence or its complete original singleton census.")
                }
                return await finishSendRemoval(original: physical, before: protectedSends,
                    checkedBefore: expected, nonRoutingChecks: sendChecks,
                    population: population, extras: extras, runtime: runtime)
            }
            guard let assigned else { return uncertain("The original occupied-send control is unavailable.") }
            let observingChange = request.occupiedInverse != nil || (sendChangeObserver != nil
                && request.expected.flatMap { before in request.destination.map {
                    supportsOccupiedSendChange(before: before, after: $0)
                } } == true)
            // A successful stable-control write needs the same native effect capsule as
            // a retired-source write. Renew its original header without adopting a
            // replacement Send on a surviving source.
            let survivingDestination = observingChange && contextAfterPress && controlAfterPress
                && axPopupAbsent && cgPopupAbsent && sameOriginalSendControl()
            if observingChange || !(contextAfterPress && controlAfterPress && axPopupAbsent && cgPopupAbsent) {
                // Diagnostic reads of the retained originals only; a readable
                // replacement or a zero AX status never restores action authority.
                func roleStatus(_ original: AXUIElement) -> Int32 {
                    let read: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                        original, kAXRoleAttribute as String, runtime: runtime.ax)
                    switch read { case .success: return 0; case .failure(let error): return error.raw }
                }
                func childrenStatus(_ original: AXUIElement) -> Int32 {
                    switch AXHelpers.childrenResult(original, runtime: runtime.ax) {
                    case .success: return 0
                    case .failure(let error): return error.raw
                    }
                }
                extras["post_press_source_read_status"] = ["strip_role": roleStatus(physical.strip),
                    "strip_children": childrenStatus(physical.strip), "send_group_role": roleStatus(assigned.group),
                    "send_group_children": childrenStatus(assigned.group), "send_list_role": roleStatus(assigned.list),
                    "send_bypass_role": roleStatus(assigned.bypass)]
                // Only the source's previously observed original-header pair
                // can renew source/control retirement. No old ref or send CF is rebound.
                guard axPopupAbsent, cgPopupAbsent, let singleton,
                      singleton.control.matches(assigned), singleton.slots == protectedSends,
                      let originalPair = AXMixerStripBinding.outputAssociation,
                      originalPair.strip.matches(physical),
                      let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                    return uncertain("The retired send has no unique complete occupied-slot correspondence and original-header renewal authority.")
                }
                let originalCount = census.strips.filter { CFEqual($0, physical.strip) }.count
                // A mode leaf may replace only the Send controls. Renew the
                // exact surviving source through the same original-header
                // observation/inverse; presence alone never adopts a new Send.
                // A destination write may retain its exact original source AND controls;
                // replaced controls on a surviving destination source still refuse.
                guard originalCount == 0 || ((request.modeChange != nil || survivingDestination) && originalCount == 1
                    && physical.currentIndex(runtime: runtime) != nil) else {
                    return uncertain("The original mode source is not uniquely current; no replacement control is adopted.")
                }
                // An inverse needs its source's changed-strip return. A forward
                // may use its actual checked receiver headers as discovery hints.
                // Complete census, viewport inverse and final source custody
                // still decide whether that return can be published.
                let renewal = await renewSourceThroughOriginalHeader(originalPair, original: physical,
                    runtime: runtime, selectedHeaderRequired: false,
                    sourceDisposition: originalCount == 0 ? .retiredOriginal : .survivingOriginal,
                    restoringMixerGeometry: sendMixerGeometry,
                    observingPeerHeaders: request.occupiedInverse != nil ? [] : observingPeerHeaders)
                extras["ui_effects"] = ["navigation_performed": renewal.effects.navigationPerformed,
                    "attempted": renewal.effects.attempted, "changed": renewal.effects.changed,
                    "restoration": renewal.effects.restoration, "reason": renewal.effects.reason as Any? ?? NSNull()]
                guard let source = renewal.source, source.permits(runtime: runtime) else {
                    return uncertain("The retired source did not renew through its exact original header with a verified inverse.")
                }
                let renewedOwner = source.pair.strip
                var verifiedPopulation: [AXUIElement]?
                func populationPreserved() -> Bool {
                    guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer,
                        runtime: runtime.ax)?.strips else { return false }
                    let expected = population.map { CFEqual($0, physical.strip) ? renewedOwner.strip : $0 }
                    guard current.count == expected.count && zip(current, expected).allSatisfy({ CFEqual($0, $1) }),
                          modePeersHeld(current, currentSource: renewedOwner.strip) else { return false }
                    verifiedPopulation = current
                    return true
                }
                guard let renewed = soleAssignedSend(in: renewedOwner.strip, runtime: runtime.ax) else {
                    return uncertain("Renewal did not observe exactly one occupied Send with a complete empty-slot footprint.",
                        checkpoint: "renewed_singleton")
                }
                guard !survivingDestination || (renewedOwner.matches(physical) && renewed.control.matches(assigned)) else {
                    return uncertain("Renewal did not retain the exact surviving source and Send controls.",
                        checkpoint: "surviving_control")
                }
                guard normalized(renewed.slots) == normalized(singleton.slots) else {
                    return uncertain("Renewal's complete slot/protected-state projection did not match its original.",
                        checkpoint: "protected_footprint")
                }
                guard populationPreserved() else {
                    return uncertain("Renewal did not observe the original ordered physical population and protected peers.",
                        checkpoint: "physical_population")
                }
                guard source.permits(runtime: runtime) else {
                    return uncertain("Renewal did not corroborate its current original-header source custody.",
                        checkpoint: "renewed_source_custody")
                }
                // The fresh checked reader observes this unique occupied group;
                // its census ordinal is only the already proved footprint coordinate.
                let after = await AXMixerStripBinding.$current.withValue(renewedOwner) {
                    await getOutputObservation(runtime: runtime, sendOrdinal: renewed.control.ordinal, timing: timing,
                        observingSendMode: request.modeChange != nil,
                        readingOriginalScope: source.observation)
                }
                if let data = after.result.message.data(using: .utf8), let receipt = try? JSONSerialization.jsonObject(with: data) {
                    extras["after_acquisition"] = receipt
                }
                guard after.assignment == request.destination, protectedChecksAfter(after),
                      let final = soleAssignedSend(in: renewedOwner.strip, runtime: runtime.ax),
                      renewed.control.matches(final.control), normalized(final.slots) == normalized(singleton.slots),
                      populationPreserved(), source.permits(runtime: runtime) else {
                    return uncertain("Fresh checked destination, unique occupied slot or protected source facts did not survive renewal and the deciding read.")
                }
                if request.modeChange != nil {
                    guard let deciding = soleAssignedSend(in: renewedOwner.strip, runtime: runtime.ax),
                          final.control.matches(deciding.control), deciding.slots == singleton.slots,
                          modeRawHeld(deciding.control, slots: deciding.slots), source.permits(runtime: runtime) else {
                        return uncertain("The renewed mode target lost its deciding protected state after peer verification.")
                    }
                }
                extras["source_renewal"] = source.pair.source
                extras["reference_reread_required"] = true
                extras["source_index_after"] = source.index
                if let mode = request.modeChange { extras["after"] = mode.desired.rawValue }
                else { extras["after"] = after.assignment?.json }
                extras["strip_count_after"] = population.count
                extras["changed"] = true
                extras["verify_source"] = "ax_send_menu_checkmark"; extras["snapshot_atomic"] = false
                let change: ChangedSendObservation?
                if observingChange, let checkedAfter = after.assignment, let checkedBefore = request.expected, let verifiedPopulation {
                    let proof = ChangedSendObservation(source: source, control: final.control, footprint: final.slots,
                        checkedBefore: checkedBefore, checkedAfter: checkedAfter,
                        nonRoutingChecks: sendChecks, population: verifiedPopulation)
                    guard proof.permits(runtime: runtime) else {
                        return uncertain("The occupied change lost native custody before publication.")
                    }
                    change = proof
                    if request.occupiedInverse == nil { sendChangeObserver?(proof) }
                } else { change = nil }
                if request.modeChange != nil,
                   !recordSendModeEffect(original: AXMixerStripBinding.outputAssociation, renewal: source,
                    control: final.control, footprint: final.slots, population: verifiedPopulation,
                    peerFootprints: modePeerFootprints, destination: after.assignment,
                    before: modeEvidence, after: after.sendMode, runtime: runtime) {
                    return uncertain("The changed mode lost its request-local native effect custody before publication.")
                }
                return .init(result: .success(HonestContract.encodeStateA(extras: extras)),
                    assignment: after.assignment, sendNonRoutingChecks: after.sendNonRoutingChecks,
                    restoredSend: request.occupiedInverse == nil ? nil : change.map {
                        .init(source: $0.source, control: $0.control, population: $0.population)
                    }, changedSend: change)
            }
            let after = await getOutputObservation(runtime: runtime, sendOrdinal: sendOrdinal, timing: timing,
                observingSendMode: request.modeChange != nil)
            if let data = after.result.message.data(using: .utf8), let receipt = try? JSONSerialization.jsonObject(with: data) {
                extras["after_acquisition"] = receipt
            }
            guard after.assignment == request.destination, protectedChecksAfter(after),
                  let slotsAfter = AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax),
                  normalized(slotsAfter) == normalized(protectedSends),
                  let populationAfter = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax)?.strips,
                  populationAfter.count == population.count, zip(populationAfter, population).allSatisfy({ CFEqual($0, $1) }),
                  modePeersHeld(populationAfter),
                  sameOriginalSendControl(),
                  writerContextCurrent(preservingOriginalLabel: false) else {
                return uncertain("Checked destination, protected send state or original population did not survive the press and fresh read; no automatic inverse was attempted.")
            }
            if request.modeChange != nil {
                guard AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax) == protectedSends,
                      sameOriginalSendControl(), modeRawHeld(assigned, slots: protectedSends),
                      writerContextCurrent(preservingOriginalLabel: false) else {
                    return uncertain("The mode target lost its deciding protected state after peer verification.")
                }
            }
            if let mode = request.modeChange { extras["after"] = mode.desired.rawValue }
            else { extras["after"] = request.destination?.json }
            extras["strip_count_after"] = population.count
            extras["changed"] = request.modeChange.map({ $0.expected != $0.desired }) ?? (request.expected != request.destination)
            extras["verify_source"] = "ax_send_menu_checkmark"; extras["snapshot_atomic"] = false
            if request.modeChange != nil,
               !recordSendModeEffect(original: AXMixerStripBinding.outputAssociation, renewal: nil,
                control: assigned, footprint: protectedSends, population: populationAfter,
                peerFootprints: modePeerFootprints, destination: after.assignment,
                before: modeEvidence, after: after.sendMode, runtime: runtime) {
                return uncertain("The changed mode lost its request-local native effect custody before publication.")
            }
            return .init(result: .success(HonestContract.encodeStateA(extras: extras)), assignment: request.destination,
                sendNonRoutingChecks: after.sendNonRoutingChecks)
        }
        var cancelSucceeded = false
        if topLevelPopup == nil, mixerChildPopup == nil, dataOwned,
           runtime.ax.actionNames(root).contains(kAXCancelAction as String), menuOwned(), !interrupted() {
            if case .success = AXHelpers.performActionResult(root, kAXCancelAction as String, runtime: runtime.ax) { cancelSucceeded = true }
        }
        var cleanupOnlyClosed = false
        if !cancelSucceeded, !interrupted() {
            let cleanup = cleanupExactOrdinaryOutputRoot()
            cancelSucceeded = cleanup.accepted
            cleanupOnlyClosed = cleanup.closed
        }
        if interrupted() { return await cancelledReading(priorCancelSucceeded: cancelSucceeded) }
        if cancelSucceeded, timing.popupCloseTimeoutMs > 0 {
            // Cancel can acknowledge before the native menu and its CG window disappear.
            // Observe only this acquired root (or absence), without another action or Help.
            // The ordinary source/document/focus checks below still decide publication.
            let closeDeadline = Date().addingTimeInterval(Double(timing.popupCloseTimeoutMs) / 1_000)
            repeat {
                guard !interrupted(), runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
                      let menus = currentPopupMenus(),
                      menus.isEmpty || (menus.count == 1 && CFEqual(menus[0], root)),
                      let windows = runtime.onScreenWindowList() else { break }
                if OperationTraceContext.current != nil,
                   (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil { break }
                if menus.isEmpty && LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 {
                    if (topLevelPopup != nil || mixerChildPopup != nil),
                       capturedPopupActionScopeCurrent() {
                        cleanupOnlyClosed = true
                        if mixerChildPopup != nil {
                            mixerChildCleanupDiagnostic.closure = "closed_after_poll"
                            mixerChildCleanupDiagnostic.checkpoint = "closed"
                            publishMixerChildCleanupDiagnostic()
                        }
                    }
                    break
                }
                if Date() >= closeDeadline { break }
                if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
            } while Date() < closeDeadline
        }
        if mixerChildPopup != nil {
            if mixerChildCleanupDiagnostic.closure == "pending" && !cleanupOnlyClosed {
                mixerChildCleanupDiagnostic.closure = "not_closed"
            }
            publishMixerChildCleanupDiagnostic()
        }
        if interrupted() { return await cancelledReading(priorCancelSucceeded: cancelSucceeded) }
        // Absence in the held Mixer's complete non-Help census prevents reading
        // a retired object's old controls. Presence alone grants no authority:
        // the ordinary complete source/window/document proof remains decisive.
        func originalSourcePresent() -> Bool {
            AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: physical.mixer, runtime: runtime.ax)?
                .strips.filter { CFEqual($0, physical.strip) }.count == 1
        }
        let currentFocus: AXUIElement? = app.flatMap { AXHelpers.getAttribute($0, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) }
        let focusRestored = originalFocus.flatMap { old in currentFocus.map { CFEqual(old, $0) } } == true
        // Observe the receipt before the ordinary deciding source/menu checks.
        let restoredFocusReceipt = focusRestorationProved()
        // Cancel can move focus to the renewed strip before the Mixer census
        // retires its old entry. Do not touch the old input's guarded Help in
        // that gap. Focus agreement only permits the ordinary source checks;
        // a mismatch still requires the full original-header renewal below.
        let originalInputFocusCurrent = !inputBusOnly || focusRestored
        // Popup absence is an observation of the original window/Mixer, not
        // assignment authority over a strip that Cancel may have retired.
        // Keep sourceAfter independent and strict: a closed popup cannot renew it.
        func popupAbsenceObserved() -> Bool {
            guard !interrupted(), runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid,
                  case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(window, physical.window),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  document.utf8.elementsEqual(physical.document.utf8),
                  let lookup = try? AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: runtime,
                    requiresCompleteAbsence: true, checking: {
                        if interrupted() { throw SessionPopulationObservation.AcquisitionError.cancelled }
                    }),
                  case .found(let mixer) = lookup.lookup, CFEqual(mixer, physical.mixer),
                  (topLevelPopup != nil || mixerChildPopup != nil
                    ? currentPopupMenus()?.isEmpty == true
                    : checkedOutputPopupMenus(in: mixer, runtime: runtime.ax)?.isEmpty == true),
                  runtime.onScreenWindowList().map({ LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 }) == true,
                  case .found(let finalWindow) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(finalWindow, window),
                  case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  finalDocument.utf8.elementsEqual(physical.document.utf8),
                  runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid, !interrupted() else { return false }
            return true
        }
        // A fresh input observation must not scan the old owner's Help between
        // Cancel and its actual original-header re-observation. Popup absence
        // is a cleanup receipt, never replacement-source authority.
        let popupClosed = !refreshingOriginalSourceAfterCleanup
            && originalSourcePresent() && originalInputFocusCurrent && sourceOwned()
            && currentPopupMenus()?.isEmpty == true
            && runtime.onScreenWindowList().map { LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 } == true
        extras["popup_cancel_succeeded"] = cancelSucceeded
        extras["focus_restoration"] = restoredFocusReceipt ? "restored" : "not_restored"
        var sourceAfter = !refreshingOriginalSourceAfterCleanup
            && originalSourcePresent() && originalInputFocusCurrent && sourceOwned()
        // The window-server census above may be the last read that observes
        // a project change. Reuse the existing subsequent source proof before
        // reporting closure in the original scope; no additional read is needed.
        var closed = (popupClosed && sourceAfter) || cleanupOnlyClosed
        if (topLevelPopup != nil || mixerChildPopup != nil), !(cancelSucceeded && cleanupOnlyClosed) {
            // Checkmarks from the captured root remain observations, but a
            // vanished root or failed Cancel acknowledgement is not a verified
            // inverse. Top-level publication requires both acceptance and the
            // exact AX+CG+Mixer absence proof from cleanup.
            closed = false
        }
        extras["popup_menu_state"] = closed ? "closed" : "not_restored"
        var inputRenewal: OriginalHeaderSourceRenewal?
        var inputSlot: AXMixerInputSlotBinding?
        var inputRenewalReceipt: [String: Any] = [
            "source_needs_renewal": false, "data_owned": false,
            "checked_evidence_agrees": false,
            "original_association_present": false,
            "original_association_matches": false,
            "eligibility": "not_eligible", "popup_absence": "not_checked",
            "census": "not_checked", "old_source_absent": false,
            "pid_match": false, "focus_match": false,
            "window_read": "not_checked", "window_match": false,
            "document_read": "not_checked", "document_match": false,
            "acquisition": "not_checked", "attempted": false,
            "source_observed": false, "replacement_source": false,
            "restoration": "not_attempted", "reason": "none",
            "permitted": false, "renewed_control_stage": "not_attempted",
        ]
        let sourceNeedsRenewal = !sourceAfter
        let checkedEvidenceAgrees = (first != nil && second == first) || inputFactsAgree
        let originalAssociation = AXMixerStripBinding.outputAssociation
        let originalAssociationPresent = originalAssociation != nil
        let originalAssociationMatches = originalAssociation?.strip.matches(physical) == true
        inputRenewalReceipt["source_needs_renewal"] = sourceNeedsRenewal
        inputRenewalReceipt["data_owned"] = dataOwned
        inputRenewalReceipt["checked_evidence_agrees"] = checkedEvidenceAgrees
        inputRenewalReceipt["original_association_present"] = originalAssociationPresent
        inputRenewalReceipt["original_association_matches"] = originalAssociationMatches
        if inputBusOnly, sourceNeedsRenewal, dataOwned, checkedEvidenceAgrees,
           let originalPair = originalAssociation, originalAssociationMatches {
            inputRenewalReceipt["eligibility"] = "eligible"
            func popupAbsent() -> Bool {
                !interrupted()
                    && currentPopupMenus()?.isEmpty == true
                    && runtime.onScreenWindowList().map { LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0 } == true
            }
            func renewalPreconditionsCurrent() -> Bool {
                let popupIsAbsent = popupAbsent()
                inputRenewalReceipt["popup_absence"] = popupIsAbsent ? "observed" : "failed"
                guard popupIsAbsent else { return false }
                guard let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(
                    in: physical.mixer, runtime: runtime.ax) else {
                    inputRenewalReceipt["census"] = "unreadable"
                    return false
                }
                inputRenewalReceipt["census"] = "read"
                let oldSourceAbsent = !census.strips.contains { CFEqual($0, physical.strip) }
                inputRenewalReceipt["old_source_absent"] = oldSourceAbsent
                guard refreshingOriginalSourceAfterCleanup || oldSourceAbsent else { return false }
                let pidMatches = runtime.logicProPID() == pid
                inputRenewalReceipt["pid_match"] = pidMatches
                guard pidMatches else { return false }
                let focusMatches = runtime.focusedApplicationPID() == pid
                inputRenewalReceipt["focus_match"] = focusMatches
                guard focusMatches else { return false }
                guard case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime) else {
                    inputRenewalReceipt["window_read"] = "not_found"
                    return false
                }
                inputRenewalReceipt["window_read"] = "found"
                let windowMatches = CFEqual(window, physical.window)
                inputRenewalReceipt["window_match"] = windowMatches
                guard windowMatches else { return false }
                guard case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(
                    physical.window, runtime: runtime) else {
                    inputRenewalReceipt["document_read"] = "unreadable"
                    return false
                }
                inputRenewalReceipt["document_read"] = "read"
                let documentMatches = document.utf8.elementsEqual(physical.document.utf8)
                inputRenewalReceipt["document_match"] = documentMatches
                guard documentMatches else { return false }
                do {
                    try SessionPopulationObservation.requireOwnedAcquisition()
                    inputRenewalReceipt["acquisition"] = "current"
                    return true
                } catch {
                    inputRenewalReceipt["acquisition"] = "not_current"
                    return false
                }
            }
            // Cancel may retire the physical source. Only the previously captured
            // original-header pair can renew it, after observed popup absence;
            // display text is a stability fact, never the checked bus authority.
            if renewalPreconditionsCurrent() {
                // This reader need not select its target before opening the popup.
                // Only an actually re-observed original-header pair can renew it;
                // the helper still inverses the selection it found on entry.
                let retiredFocusBaseline: HeldSelectionAssociation.OriginalHeaderFocusBaseline?
                if let baseline = focusBaseline,
                   let focus: AXUIElement = AXHelpers.getAttribute(baseline.app,
                        kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                   CFEqual(focus, baseline.focus) {
                    retiredFocusBaseline = baseline
                } else {
                    retiredFocusBaseline = nil
                }
                inputRenewalReceipt["attempted"] = true
                let observed = await renewSourceThroughOriginalHeader(originalPair, original: physical,
                    runtime: runtime, selectedHeaderRequired: false,
                    sourceDisposition: refreshingOriginalSourceAfterCleanup ? .readObservation : .retiredOriginal,
                    restoringMixerGeometry: restoringMixerGeometry, observingReadFocus: observingRenewedFocus,
                    observingPeerHeaders: observingPeerHeaders,
                    recoveringRetiredFocusFrom: retiredFocusBaseline)
                renewalEffects = observed.effects
                extras["ui_effects"] = ["navigation_performed": observed.effects.navigationPerformed,
                    "attempted": observed.effects.attempted, "changed": observed.effects.changed,
                    "restoration": observed.effects.restoration, "reason": observed.effects.reason as Any? ?? NSNull()]
                inputRenewalReceipt["source_observed"] = observed.source != nil
                inputRenewalReceipt["restoration"] = ["restored", "not_restored"].contains(
                    observed.effects.restoration) ? observed.effects.restoration : "other"
                let diagnosticReasons: Set<String> = [
                    "association_selection_unverified", "association_restoration_unverified",
                    "association_mixer_viewport_restoration_unverified",
                    "mixer_focus_reacquisition_unverified", "mixer_focus_acquisition_unverified",
                    "navigation_ownership_lost",
                ]
                inputRenewalReceipt["reason"] = observed.effects.reason.map {
                    diagnosticReasons.contains($0) ? $0 : "other"
                } ?? "none"
                let permittedSource = observed.source.flatMap { source -> OriginalHeaderSourceRenewal? in
                    let permitted = source.permits(runtime: runtime)
                    inputRenewalReceipt["permitted"] = permitted
                    inputRenewalReceipt["replacement_source"] = !source.pair.strip.matches(physical)
                    return permitted ? source : nil
                }
                if let source = permittedSource {
                    // Hand off only the newly proved passive focus witness before
                    // guarded Help reads. This is not assignment/publication authority.
                    observingRenewedFocus(source.observation)
                    let input = AXLogicProElements.inputSlotRead(in: source.pair.strip.strip, runtime: runtime.ax)
                    func inputControlStillCurrent(_ control: AXUIElement) -> Bool {
                        let current = AXLogicProElements.inputSlotRead(in: source.pair.strip.strip, runtime: runtime.ax)
                        guard case .source(let label) = current.reading, let currentControl = current.control,
                              CFEqual(currentControl, control) else { return false }
                        return label.utf8.elementsEqual(originalLabel.utf8)
                    }
                    let renewedControl: AXUIElement? = {
                        var stage = "input_slot", accepted = false
                        defer {
                            inputRenewalReceipt["renewed_control_stage"] = accepted ? "accepted" : stage
                            if !accepted {
                                Log.info("Renewed checked input refused at \(stage): \(input.reading), help_stopped=\(AXHelpers.HelpReadGuard.current?.stopped == true)", subsystem: "ax")
                            }
                        }
                        guard case .source = input.reading, let control = input.control else { return nil }
                        stage = "input_description"
                        guard case .success(.some(let label)) = AXHelpers.getAttributeResult(control,
                            kAXDescriptionAttribute as String, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError>,
                              label.utf8.elementsEqual(originalLabel.utf8) else { return nil }
                        stage = "input_control_bookend"
                        guard inputControlStillCurrent(control) else { return nil }
                        stage = "popup_absence"
                        guard popupAbsent() else { return nil }
                        stage = "source_bookend"
                        guard source.permits(runtime: runtime) else { return nil }
                        accepted = true
                        return control
                    }()
                    if let control = renewedControl {
                        sourceAfter = true
                        extras["popup_menu_state"] = "closed"
                        extras["source_renewal"] = source.pair.source
                        extras["reference_reread_required"] = true
                        extras["source_index_after"] = source.index
                        inputRenewal = source
                        inputSlot = .init(owner: source.pair.strip, control: control, source: originalLabel)
                    }
                } else {
                    Log.info("Checked input original-header renewal is not current: observed=\(observed.source != nil)", subsystem: "ax")
                }
            }
        }
        if inputBusOnly { extras["input_source_renewal"] = inputRenewalReceipt }
        var inputTransportReceipt: [String: Any] = [
            "held_transport_captured": routingTransport != nil,
            "held_transport_matched": false,
            "fallback_attempted": false,
            "renewal_present": inputRenewal != nil,
            "first_failed_checkpoint": "none",
            "attempt_count": 0,
            "exit_reason": "not_attempted",
        ]
        var freshTransportFallbackAccepted: Bool?
        var freshTransportFallbackRetryable = false
        func exactInputSourceWithFreshStoppedTransport() -> Bool {
            if let freshTransportFallbackAccepted { return freshTransportFallbackAccepted }
            freshTransportFallbackRetryable = false
            inputTransportReceipt["fallback_attempted"] = true
            inputTransportReceipt["attempt_count"] = (inputTransportReceipt["attempt_count"] as? Int ?? 0) + 1
            func fail(_ checkpoint: String) -> Bool {
                if inputTransportReceipt["first_failed_checkpoint"] as? String == "none" {
                    inputTransportReceipt["first_failed_checkpoint"] = checkpoint
                }
                freshTransportFallbackAccepted = false
                return false
            }
            guard inputBusOnly, inputRenewal == nil else {
                return fail(inputRenewal == nil ? "source_present" : "renewal_present")
            }
            let sourcePresent = !refreshingOriginalSourceAfterCleanup && originalSourcePresent()
            inputTransportReceipt["source_present"] = sourcePresent
            guard sourcePresent else {
                // Logic can briefly omit the same retained physical strip from
                // its first post-Cancel census. Only the already captured CF
                // source may recover on the next complete census; the retry
                // still repeats every control, owner, transport and popup
                // bookend below and never adopts a name or ordinal replacement.
                freshTransportFallbackRetryable = true
                return fail("source_present")
            }
            inputTransportReceipt["focus_current"] = originalInputFocusCurrent
            guard originalInputFocusCurrent else { return fail("focus_current") }
            let sourceControlCurrent = sourceFactsCurrent(requiringStoppedTransport: false)
            inputTransportReceipt["source_control_current"] = sourceControlCurrent
            guard sourceControlCurrent else { return fail("source_control_current") }
            let ownerBeforeTransport = ownerBoundaryStillCurrent()
            inputTransportReceipt["owner_before_transport"] = ownerBeforeTransport
            guard ownerBeforeTransport else { return fail("owner_before_transport") }
            guard let activity = try? AXLogicProElements.observedTransportActivity(
                in: physical.window, runtime: runtime,
                checking: { try SessionPopulationObservation.requireOwnedAcquisition() }) else {
                inputTransportReceipt["fresh_transport"] = "unreadable"
                // This API deliberately collapses a transient native AX status
                // to nil. It is the only retryable checkpoint: every source,
                // owner, popup, gate and semantic transport result below stays
                // terminal for this acquisition attempt.
                freshTransportFallbackRetryable = true
                return fail("fresh_transport")
            }
            if activity.isPlaying {
                inputTransportReceipt["fresh_transport"] = "playing"
                return fail("fresh_transport")
            }
            if activity.isRecording {
                inputTransportReceipt["fresh_transport"] = "recording"
                return fail("fresh_transport")
            }
            inputTransportReceipt["fresh_transport"] = "stopped"
            let sourceAfterTransport = sourceFactsCurrent(requiringStoppedTransport: false)
            inputTransportReceipt["source_after_transport_1"] = sourceAfterTransport
            guard sourceAfterTransport else { return fail("source_after_transport_1") }
            let ownerAfterTransport = ownerBoundaryStillCurrent()
            inputTransportReceipt["owner_1"] = ownerAfterTransport
            guard ownerAfterTransport else { return fail("owner_1") }
            let popupAbsent = popupAbsenceObserved()
            inputTransportReceipt["popup_absent"] = popupAbsent
            guard popupAbsent else { return fail("popup_absent") }
            let sourceBookend = sourceFactsCurrent(requiringStoppedTransport: false)
            inputTransportReceipt["source_2"] = sourceBookend
            guard sourceBookend else { return fail("source_2") }
            let ownerBookend = ownerBoundaryStillCurrent()
            inputTransportReceipt["owner_2"] = ownerBookend
            guard ownerBookend else { return fail("owner_2") }
            freshTransportFallbackAccepted = true
            return true
        }
        func exactInputSourceWithSettledFreshStoppedTransport() async -> Bool {
            let deadline = Date().addingTimeInterval(Double(timing.readbackTimeoutMs) / 1_000)
            func stopped(_ reason: String) -> Bool {
                inputTransportReceipt["exit_reason"] = reason
                return false
            }
            while true {
                if exactInputSourceWithFreshStoppedTransport() {
                    inputTransportReceipt["exit_reason"] = "accepted"
                    return true
                }
                guard freshTransportFallbackRetryable else { return stopped("nonretryable") }
                guard timing.readbackTimeoutMs > 0, Date() < deadline else { return stopped("deadline") }
                guard !interrupted() else { return stopped("interrupted") }
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                    return stopped("acquisition")
                }
                guard popupAbsenceObserved() else { return stopped("popup_absence") }
                guard Date() < deadline else { return stopped("deadline") }
                guard !interrupted() else { return stopped("interrupted") }
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                    return stopped("acquisition")
                }
                if timing.pollIntervalMs > 0 {
                    try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs))
                } else {
                    await Task.yield()
                }
                guard Date() < deadline else { return stopped("deadline") }
                guard !interrupted() else { return stopped("interrupted") }
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                    return stopped("acquisition")
                }
                guard popupAbsenceObserved() else { return stopped("popup_absence") }
                guard Date() < deadline else { return stopped("deadline") }
                guard !interrupted() else { return stopped("interrupted") }
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                    return stopped("acquisition")
                }
                freshTransportFallbackAccepted = nil
            }
        }
        func freshTransportFallbackPublicationCurrent() -> Bool {
            guard freshTransportFallbackAccepted == true,
                  sourceFactsCurrent(requiringStoppedTransport: false),
                  ownerBoundaryStillCurrent(), popupAbsenceObserved(),
                  sourceFactsCurrent(requiringStoppedTransport: false),
                  ownerBoundaryStillCurrent() else { return false }
            return true
        }
        // The temporary menu can make either the held batch capture or its
        // post-close identity unavailable. A missing held capture is not a
        // defaulted stopped state: only this same ordered fresh observation can
        // recover a source that the ordinary post-close proof did not retain.
        let heldTransportStillMatches = routingTransport?.matchesClosedWindow(runtime: runtime) ?? false
        inputTransportReceipt["held_transport_matched"] = heldTransportStillMatches
        if heldTransportStillMatches {
            let retainedSourceStillCurrent = inputRenewal.map { $0.permits(runtime: runtime) }
                ?? sourceOwned()
            sourceAfter = sourceAfter && retainedSourceStillCurrent
            if !sourceAfter {
                if await exactInputSourceWithSettledFreshStoppedTransport() {
                    sourceAfter = true
                    closed = true
                    extras["popup_menu_state"] = "closed"
                }
            }
        } else if routingTransport != nil || !sourceAfter {
            if await exactInputSourceWithSettledFreshStoppedTransport() {
                sourceAfter = true
                closed = true
                extras["popup_menu_state"] = "closed"
            } else {
                sourceAfter = false
            }
        }
        if inputBusOnly { extras["input_transport_fallback"] = inputTransportReceipt }
        extras["source_custody_after_cleanup"] = sourceAfter
        extras["menu_custody_at_read"] = dataOwned
        extras["output_checkmark_reads_observed"] = (first == nil ? 0 : 1) + (second == nil ? 0 : 1)
        extras["output_checkmark_reads_agree"] = first != nil && second == first
        // Do not add fresh window census reads to the original-header renewal
        // interval. Observe closure only after renewal has already failed;
        // this receipt cannot repair sourceAfter or publish an assignment.
        if inputBusOnly, !sourceAfter, !closed, popupAbsenceObserved() {
            extras["popup_menu_state"] = "closed"
        }
        // Only the internal inspection reader retains this independently checked
        // fact, after the original source (or existing original-header renewal)
        // and its exact current input control survive cleanup. Its wire result
        // stays bus-only; a non-Bus fact grants no scalar or inverse authority.
        var checkedInputFact: InputAssignment?
        if includingNonBusInputs, inputFactsAgree, dataOwned, sourceAfter,
           extras["popup_menu_state"] as? String == "closed", let firstInput {
            if inputSlot == nil {
                let current = AXLogicProElements.inputSlotRead(in: physical.strip, runtime: runtime.ax)
                if case .source(let label) = current.reading, let control = current.control,
                   CFEqual(control, slot), label.utf8.elementsEqual(originalLabel.utf8),
                   sourceOwned() || freshTransportFallbackPublicationCurrent(), closed {
                    inputSlot = .init(owner: physical, control: control, source: label)
                }
            }
            if inputSlot != nil {
                checkedInputFact = firstInput
                if firstInput.busOutputAssignment == nil {
                    let unsupported = refuse(.unsupportedState,
                        "The checked non-Bus input is outside the bus-only wire result; its internal observation grants no write authority.")
                    return .init(result: unsupported.result, assignment: nil, inputAssignment: firstInput,
                        inputRenewal: inputRenewal, inputSlot: inputSlot, renewalEffects: renewalEffects)
                }
            }
        }
        // Logic can report a failed AXPress after actually opening this popup. The
        // acknowledgement is a receipt, not read authority: require the newly
        // observed, unchanged source/menu and two agreeing checked choices instead.
        guard dataOwned, sourceAfter,
              (sendOrdinal != nil || extras["popup_menu_state"] as? String == "closed"),
              let first, second == first else {
            return refuse(.readbackUnavailable, "The checked output was unreadable, contradictory, or lost its original source/menu custody; no destination was selected.")
        }
        guard !observingSendMode || !requiringSendMode || modeEvidence != nil else {
            return refuse(.readbackUnavailable, "The complete checked Send mode census was missing, ambiguous or changed.")
        }
        guard sendOrdinal == nil || first != .noOutput else {
            return refuse(.readbackUnavailable, "An output-only No Output marker is not an assigned-send destination.")
        }
        if inputBusOnly, inputSlot == nil {
            let current = AXLogicProElements.inputSlotRead(in: physical.strip, runtime: runtime.ax)
            guard case .source(let label) = current.reading, let control = current.control,
                  CFEqual(control, slot), label.utf8.elementsEqual(originalLabel.utf8),
                  sourceOwned() || freshTransportFallbackPublicationCurrent(), closed else {
                return refuse(.readbackUnavailable, "The checked input's original control did not survive cleanup.")
            }
            inputSlot = .init(owner: physical, control: control, source: label)
        }
        extras[inputBusOnly ? "current_input" : (sendOrdinal == nil ? "current_output" : "current_destination")] = first.json
        extras["verify_source"] = inputBusOnly ? "ax_input_menu_checkmark" : (sendOrdinal == nil ? "ax_output_menu_checkmark" : "ax_send_menu_checkmark")
        if inputBusOnly { extras["input_scope"] = "bus_only" }
        extras["snapshot_atomic"] = false
        let observedBusNumbers = !inputBusOnly && sendOrdinal == nil && closed
            && firstBusNumbers != nil && firstBusNumbers == secondBusNumbers ? firstBusNumbers : nil
        if let observedBusNumbers {
            extras["observed_bus_namespace"] = ["bus_numbers": observedBusNumbers,
                "source": "ax_output_bus_menu", "namespace_availability": "not_observed"]
        }
        return .init(result: .success(HonestContract.encodeStateA(extras: extras)), assignment: first,
            inputAssignment: checkedInputFact, inputRenewal: inputRenewal, inputSlot: inputSlot,
            renewalEffects: renewalEffects,
            sendNonRoutingChecks: sendChecks, sendMode: modeEvidence, observedBusNumbers: observedBusNumbers,
            sendControl: sendOrdinal != nil && closed && sourceAfter ? assigned : nil)
    }

    static func outputReadContextFailure(_ result: ChannelResult, operation: String) -> ChannelResult {
        var extras: [String: Any] = ["operation": operation, "write_attempted": false]
        let receiptKeys: Set<String> = ["navigation_attempted", "popup_menu_state", "popup_cancel_succeeded",
            "focus_restoration", "popup_press_succeeded", "source_custody_after_cleanup",
            "menu_custody_at_read", "output_checkmark_reads_observed", "output_checkmark_reads_agree", "send_ordinal",
            "ui_effects", "source_renewal", "reference_reread_required", "source_index_after"]
        if let data = result.message.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object where receiptKeys.contains(key) { extras[key] = value }
        }
        return .error(HonestContract.encodeStateC(error: .staleTargetReference,
            hint: "The original target/project context ended; the output is withheld and known UI effects are preserved.", extras: extras))
    }

    /// Logic reports AXNoValue for FocusedWindow while its routing menu owns
    /// keyboard focus. Only that exact response and a reciprocal original
    /// Mixer/menu path qualify; absent/unreadable/foreign windows still refuse.
    static func routingFocusedWindowMatches(
        _ reading: Result<AnyObject?, AXHelpers.AXStatusError>, window: AXUIElement,
        ownedPopup: AXUIElement?, mixer: AXUIElement, runtime: AXHelpers.Runtime
    ) -> Bool {
        if case .success(.some(let value)) = reading, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return CFEqual(unsafeBitCast(value, to: AXUIElement.self), window)
        }
        guard case .failure(let error) = reading, error.raw == AXError.noValue.rawValue,
              let root = ownedPopup,
              let menus = checkedOutputPopupMenus(in: mixer, runtime: runtime),
              menus.count == 1, CFEqual(menus[0], root),
              let parent: AXUIElement = AXHelpers.getAttribute(root, kAXParentAttribute as String, runtime: runtime),
              CFEqual(parent, mixer) else { return false }
        return true
    }

    static func checkedOutputPopupMenus(in mixer: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        guard case .success(let children) = AXHelpers.childrenResult(mixer, runtime: runtime) else { return nil }
        var menus: [AXUIElement] = []
        for child in children {
            let read: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(child, kAXRoleAttribute as String, runtime: runtime)
            guard case .success(.some(let role)) = read else { return nil }
            if role == kAXMenuRole as String { menus.append(child) }
        }
        return menus
    }

    /// Direct application children only. Descendant submenus are menu content,
    /// never independently acquired popup roots. Every role/parent read is
    /// status-preserving so a partial census cannot become cleanup authority.
    static func checkedTopLevelOutputPopupMenus(
        in app: AXUIElement, runtime: AXHelpers.Runtime
    ) -> [AXUIElement]? {
        guard case .success(let children) = AXHelpers.childrenResult(app, runtime: runtime) else { return nil }
        var menus: [AXUIElement] = []
        for child in children {
            let role: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                child, kAXRoleAttribute as String, runtime: runtime)
            guard case .success(.some(let role)) = role else { return nil }
            guard role == kAXMenuRole as String else { continue }
            let parent: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                child, kAXParentAttribute as String, runtime: runtime)
            guard case .success(.some(let raw)) = parent,
                  CFGetTypeID(raw) == AXUIElementGetTypeID(),
                  CFEqual(unsafeBitCast(raw, to: AXUIElement.self), app) else { return nil }
            menus.append(child)
        }
        return menus
    }

    static func checkedLogicOutputPopupWindows(
        _ windows: [[String: Any]], logicPID: pid_t
    ) -> [LogicOnScreenWindows.Entry]? {
        func exactIntegral(_ value: Any?) -> Int64? {
            guard let object = value as? NSNumber,
                  CFGetTypeID(object) == CFNumberGetTypeID(),
                  CFGetTypeID(object) != CFBooleanGetTypeID() else { return nil }
            let number = unsafeBitCast(object, to: CFNumber.self)
            guard !CFNumberIsFloatType(number) else { return nil }
            var value: Int64 = 0
            guard CFNumberGetValue(number, .sInt64Type, &value),
                  NSNumber(value: value).compare(object) == .orderedSame else { return nil }
            return value
        }
        var popups: [LogicOnScreenWindows.Entry] = []
        for row in windows {
            guard let owner = exactIntegral(row[kCGWindowOwnerPID as String]),
                  owner > 0, owner <= Int64(Int32.max) else { return nil }
            guard pid_t(owner) == logicPID else { continue }
            guard let number = exactIntegral(row[kCGWindowNumber as String]),
                  number > 0, number <= Int64(UInt32.max),
                  let layer = exactIntegral(row[kCGWindowLayer as String]),
                  layer >= Int64(Int32.min), layer <= Int64(Int32.max) else { return nil }
            guard Int(layer) == LogicOnScreenWindows.popupMenuLevel else { continue }
            guard let dictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  !bounds.isNull, !bounds.isInfinite,
                  bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0 else { return nil }
            popups.append(.init(number: Int(number), layer: Int(layer), bounds: bounds,
                name: row[kCGWindowName as String] as? String))
        }
        return popups
    }

    struct HeldOrdinaryOutputPopup: @unchecked Sendable {
        let root: AXUIElement
        let window: LogicOnScreenWindows.Entry
    }

    struct HeldMixerChildOutputPopup: @unchecked Sendable {
        let root: AXUIElement
        let window: LogicOnScreenWindows.Entry
    }

    /// Request-local transport custody for read-only input/output popups.
    /// Only the existing stopped controls and their reciprocal original paths
    /// are read while the popup is open. No destination or musical write uses it.
    /// Send reads and destination writers retain their existing transport path.
    struct HeldRoutingReadTransport: @unchecked Sendable {
        let activity: AXLogicProElements.ObservedTransportActivity
        let window: AXUIElement
        let paths: [[AXUIElement]]

        static func capture(window: AXUIElement, runtime: AXLogicProElements.Runtime) -> Self? {
            guard runtime.ax.attributeValuesResult != nil,
                  let activity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  !activity.isPlaying, !activity.isRecording,
                  let play = HeldSelectionAssociation.path(activity.play, to: window, ax: runtime.ax),
                  let record = HeldSelectionAssociation.path(activity.record, to: window, ax: runtime.ax) else { return nil }
            let held = Self(activity: activity, window: window, paths: [play, record])
            return held.stillStopped(runtime: runtime) ? held : nil
        }

        func stillStopped(runtime: AXLogicProElements.Runtime) -> Bool {
            HeldSelectionAssociation.stoppedTransportPathsMatch(paths, activity: activity, window: window, logic: runtime)
        }

        func matchesClosedWindow(runtime: AXLogicProElements.Runtime) -> Bool {
            guard let current = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  CFEqual(current.controlBar, activity.controlBar), CFEqual(current.play, activity.play),
                  CFEqual(current.record, activity.record), !current.isPlaying, !current.isRecording else { return false }
            return stillStopped(runtime: runtime)
        }
    }

    /// Measured native No Output wrapper. A hit-test only obtains an object;
    /// the original Mixer/window path, reciprocal root and matching CG frame
    /// must independently agree. No coordinates are used to perform an action.
    struct NativeOutputReadPopup: @unchecked Sendable {
        let root: AXUIElement
        let wrapper: AXUIElement
        let window: LogicOnScreenWindows.Entry

        func matches(_ other: Self) -> Bool {
            CFEqual(root, other.root) && CFEqual(wrapper, other.wrapper) && window == other.window
        }

        static func read(physical: AXMixerStripBinding.Binding, app: AXUIElement, pid: pid_t,
                         runtime: AXLogicProElements.Runtime) -> Self? {
            // The focused-application AX read needs the current CG census first
            // (ProcessUtils.focusedApplicationPID); unread/foreign focus still refuses.
            guard !Task.isCancelled, runtime.logicProPID() == pid,
                  let windows = runtime.onScreenWindowList(), runtime.focusedApplicationPID() == pid,
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true else { return nil }
            let popups = LogicOnScreenWindows.logicOwned(windows, logicPID: pid)
                .filter { $0.layer == LogicOnScreenWindows.popupMenuLevel }
            guard popups.count == 1, let frame = popups[0].bounds,
                  !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0,
                  let hitTest = runtime.ax.elementAtPosition,
                  case .success(.some(let hit)) = hitTest(app, CGPoint(x: frame.midX, y: frame.midY)),
                  AXHelpers.getRole(hit, runtime: runtime.ax) == kAXMenuItemRole as String,
                  let root: AXUIElement = AXHelpers.getAttribute(hit, kAXParentAttribute as String, runtime: runtime.ax),
                  AXHelpers.getRole(root, runtime: runtime.ax) == kAXMenuRole as String,
                  case .success(let rows) = AXHelpers.childrenResult(root, runtime: runtime.ax),
                  rows.filter({ CFEqual($0, hit) }).count == 1,
                  AXHelpers.getPosition(root, runtime: runtime.ax) == frame.origin,
                  AXHelpers.getSize(root, runtime: runtime.ax) == frame.size,
                  let wrapper: AXUIElement = AXHelpers.getAttribute(root, kAXParentAttribute as String, runtime: runtime.ax),
                  AXHelpers.getRole(wrapper, runtime: runtime.ax) == kAXPopUpButtonRole as String,
                  case .success(let roots) = AXHelpers.childrenResult(wrapper, runtime: runtime.ax),
                  roots.count == 1, CFEqual(roots[0], root),
                  let mixer: AXUIElement = AXHelpers.getAttribute(wrapper, kAXParentAttribute as String, runtime: runtime.ax),
                  CFEqual(mixer, physical.mixer),
                  let owner: AXUIElement = AXHelpers.getAttribute(wrapper, kAXWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(owner, physical.window),
                  let finalWindows = runtime.onScreenWindowList(),
                  LogicOnScreenWindows.logicOwned(finalWindows, logicPID: pid)
                    .filter({ $0.layer == LogicOnScreenWindows.popupMenuLevel }) == popups,
                  !Task.isCancelled, runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid else { return nil }
            return .init(root: root, wrapper: wrapper, window: popups[0])
        }
    }
}
