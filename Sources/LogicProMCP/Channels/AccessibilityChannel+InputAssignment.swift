@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Bounded bus-to-bus input replacement on an exact physical-output sink
    /// with no occupied sends. This grants no general partial-graph write,
    /// physical-input, aux creation, or input-format conversion authority.
    static func setInputBusVerified(params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        timing: OutputAssignmentTiming? = nil,
        ownedInverse: ChangedInputObservation? = nil,
        ownedCreation: OwnedAuxLifecycle.InputInitializationProof? = nil) async -> ChannelResult {
        let timing = OutputAssignmentTiming.resolving(timing, for: runtime)
        let operation = "mixer.set_input_bus_verified"
        var extras: [String: Any] = ["operation": operation, "write_attempted": false,
            "navigation_attempted": false]
        func refusal(_ error: HonestContract.FailureError, _ hint: String) -> ChannelResult {
            .error(HonestContract.encodeStateC(error: error, hint: hint, extras: extras))
        }
        func uncertain(_ reason: HonestContract.UncertainReason, _ hint: String) -> ChannelResult {
            Log.info("Input verification uncertain: \(hint)", subsystem: "ax")
            extras["hint"] = hint
            return .success(HonestContract.encodeStateB(reason: reason, extras: extras))
        }
        func recordRead(_ read: CheckedOutputReading, key: String) {
            if let data = read.result.message.data(using: .utf8),
               let receipt = try? JSONSerialization.jsonObject(with: data) {
                extras[key] = receipt
                if let summary = receipt as? [String: Any], summary["state"] as? String != "A" {
                    let effects = summary["ui_effects"] as? [String: Any]
                    let status = ["state", "error", "popup_menu_state", "focus_restoration", "source_custody_after_cleanup"]
                        .map { "\($0)=\(summary[$0].map(String.init(describing:)) ?? "unavailable")" }.joined(separator: ",")
                    Log.info("Input acquisition unavailable: stage=\(key),\(status),restoration=\(effects?["restoration"] as? String ?? "unavailable"),reason=\(effects?["reason"] as? String ?? "none")", subsystem: "ax")
                }
                // The final acquisition may navigate after an earlier writer inverse restored.
                // Merge receipts only; no decoded field supplies source or write authority.
                if key == "after_acquisition",
                   let incoming = (receipt as? [String: Any])?["ui_effects"] as? [String: Any],
                   let navigated = incoming["navigation_performed"] as? Bool, navigated {
                    var effects = extras["ui_effects"] as? [String: Any] ?? [:]
                    effects["navigation_performed"] = true
                    for field in ["attempted", "changed"] {
                        let prior = effects[field] as? [String] ?? []
                        effects[field] = prior + (incoming[field] as? [String] ?? []).filter { !prior.contains($0) }
                    }
                    if let restoration = incoming["restoration"] as? String,
                       restoration != "restored" || effects["restoration"] == nil { effects["restoration"] = restoration }
                    if let reason = incoming["reason"] as? String, effects["reason"] as? String == nil { effects["reason"] = reason }
                    extras["ui_effects"] = effects
                }
            }
        }
        guard params.keys.allSatisfy({ ["destination", "expected_current", "replace_existing"].contains($0) }),
              params["replace_existing"] == "true",
              let rawDestination = params["destination"], case .bus(let destination)? = OutputAssignment(token: rawDestination),
              let original = AXMixerStripBinding.current, original.currentIndex(runtime: runtime) != nil else {
            return refusal(.invalidParams,
                "A current physical Mixer reference, Bus 1..256 destination and expected_current, and replace_existing:true are required.")
        }
        let expected: InputAssignment
        if let ownedCreation {
            guard ownedInverse == nil, params["expected_current"] == nil,
                  ownedCreation.destination == destination, ownedCreation.permitsBefore(original) else {
                return refusal(.staleTargetReference, "The original creation does not authorize this exact initialization.")
            }
            expected = ownedCreation.before
        } else {
            guard let raw = params["expected_current"], case .bus(let number)? = OutputAssignment(token: raw) else {
                return refusal(.invalidParams, "Ordinary input replacement requires a checked Bus expected_current.")
            }
            expected = .bus(number)
        }
        guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
            return refusal(.staleTargetReference, "The operation no longer owns its mutation gate or deadline.")
        }
        extras["destination"] = OutputAssignment.bus(destination).json
        extras["navigation_attempted"] = true
        // This display-only preflight grants no write authority. The one checked
        // output acquisition below must corroborate it on the input's current owner.
        guard let outputLabel = AXLogicProElements.outputSlotDestination(in: original.strip, runtime: runtime.ax),
              let sink = OutputAssignment.observed(slotLabel: outputLabel), sink == .stereoOutput || {
            if case .physical = sink { return true }; return false
        }(), original.currentIndex(runtime: runtime) != nil else {
            return refusal(.routingDependencyUnknown, "Only a checked physical-output sink is supported; no input destination was pressed.")
        }
        if let ownedInverse {
            guard ownedInverse.current.strip.matches(original), ownedInverse.before == .bus(destination),
                  expected == .bus(ownedInverse.after), ownedInverse.creation == nil,
                  ownedInverse.sink == sink, ownedInverse.permits() else {
                return refusal(.staleTargetReference, "The original changed input no longer authorizes this inverse.")
            }
        }
        let before: CheckedOutputReading
        if let ownedCreation {
            guard let checked = ownedCreation.retainedCheckedRead() else {
                return refusal(.staleTargetReference, "The actual created input observation is no longer current.")
            }
            before = checked; recordRead(before, key: "retained_created_input_acquisition")
        } else if let ownedInverse {
            guard let checked = ownedInverse.retainedCheckedRead() else {
                return refusal(.staleTargetReference, "The independently checked changed input is no longer current.")
            }
            before = checked
            recordRead(before, key: "retained_before_acquisition")
        } else {
            before = await getInputBusObservation(runtime: runtime, timing: timing,
                requiringOriginalInputControl: InputBusSagaAdapter.requiredInputControl)
            recordRead(before, key: "before_acquisition")
        }
        let observed = before.inputAssignment ?? before.assignment.flatMap { value -> InputAssignment? in
            if case .bus(let number) = value { return .bus(number) }; return nil
        }
        guard let observed, ownedCreation != nil || observed.busOutputAssignment != nil else {
            return refusal(.readbackUnavailable, "The current input did not have agreeing checked-bus evidence; no destination was pressed.")
        }
        if case .bus(let number) = observed { extras["before"] = OutputAssignment.bus(number).json }
        else { extras["creation_owned_initialization"] = true; extras["initial_input"] = String(describing: observed) }
        guard observed == expected else {
            return refusal(.staleSnapshot, "expected_current does not match the checked input; no destination was pressed.")
        }
        let owner = before.inputRenewal?.pair.strip ?? original
        let pair = before.inputRenewal?.pair ?? AXMixerStripBinding.outputAssociation
        // An inverse uses the already-owned retained read, not a new acquisition.
        // Its historical renewal has already been consumed by the name owner.
        if ownedInverse == nil, let source = before.inputRenewal, let observer = InputBusSagaAdapter.sourceRenewalObserver,
           !(await observer(source)) {
            return refusal(.staleTargetReference, "Owned name continuity ended during input acquisition; no destination was pressed.")
        }
        if before.inputRenewal != nil {
            extras["reference_reread_required"] = true
            extras["source_renewal"] = before.inputRenewal?.pair.source
        }
        guard let heldInput = before.inputSlot, heldInput.owner.matches(owner),
              let population = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: owner.mixer, runtime: runtime.ax) else {
            return refusal(.staleTargetReference, "The checked input has no current physical source/control binding.")
        }
        extras["strip_count_before"] = population.strips.count
        let inverseProtection: ChangedInputObservation?
        if let ownedInverse {
            guard ownedInverse.current.strip.matches(owner), ownedInverse.control.matches(heldInput),
                  ownedInverse.sink == sink, ownedInverse.permits() else {
                return refusal(.staleTargetReference, "The original changed input control is no longer current.")
            }
            inverseProtection = ownedInverse
        } else { inverseProtection = nil }
        func checkedSink(_ source: AXMixerStripBinding.Binding) async -> CheckedOutputReading {
            await AXMixerStripBinding.$current.withValue(source) {
                await getOutputObservation(runtime: runtime, timing: timing)
            }
        }
        let renewedOutput = await checkedSink(owner)
        recordRead(renewedOutput, key: "output_acquisition")
        recordRead(renewedOutput, key: "output_before_write")
        guard renewedOutput.assignment == sink else {
            return refusal(.routingDependencyUnknown, "The current receiver's checked physical output changed during input acquisition.")
        }
        @Sendable func sinkStillCurrent(_ source: AXMixerStripBinding.Binding) -> Bool {
            guard let label = AXLogicProElements.outputSlotDestination(in: source.strip, runtime: runtime.ax),
                  OutputAssignment.observed(slotLabel: label) == sink,
                  let sends = AXLogicProElements.sendSlotObservations(in: source.strip, runtime: runtime.ax),
                  sends.allSatisfy({ $0.state == .observedEmpty }) else { return false }
            return true
        }
        @Sendable func inverseStillCurrent(ownedPopup: AXUIElement?) -> Bool {
            guard let inverseProtection else { return true }
            guard inverseProtection.current.strip.matches(owner), inverseProtection.control.matches(heldInput),
                  inverseProtection.sink == sink,
                  inverseProtection.renewal.map({ $0.permits(runtime: runtime, ownedPopup: ownedPopup) }) ?? true,
                  let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: owner.mixer, runtime: runtime.ax)?.strips,
                  census.count == inverseProtection.population.count,
                  zip(census, inverseProtection.population).allSatisfy({ CFEqual($0, $1) }),
                  sinkStillCurrent(owner) else { return false }
            let input = AXLogicProElements.inputSlotRead(in: owner.strip, runtime: runtime.ax)
            guard case .source(let label) = input.reading, let control = input.control else { return false }
            return inverseProtection.control.matches(.init(owner: owner, control: control, source: label))
        }
        @Sendable func ownerStillCurrent(ownedPopup: AXUIElement? = nil) -> Bool {
            let currentInput = AXLogicProElements.inputSlotRead(in: owner.strip, runtime: runtime.ax)
            guard case .source(let label) = currentInput.reading, let control = currentInput.control,
                  heldInput.matches(.init(owner: owner, control: control, source: label)) else {
                Log.info("Input writer custody refused: input control/source", subsystem: "ax"); return false
            }
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  before.inputRenewal.map({ $0.permits(runtime: runtime, ownedPopup: ownedPopup) }) != false else {
                Log.info("Input writer custody refused: original association/gate", subsystem: "ax"); return false
            }
            guard inverseStillCurrent(ownedPopup: ownedPopup) else { return false }
            if let permission = InputBusSagaAdapter.writePermission {
                guard let pair, pair.strip.matches(owner),
                      permission(pair, before.inputRenewal, heldInput, ownedPopup) else { return false }
            }
            guard
                  sinkStillCurrent(owner),
                  AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false,
                  AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false,
                  !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
                  let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
                  let app = AXLogicProElements.appRoot(runtime: runtime),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, owner.window),
                  routingFocusedWindowMatches(AXHelpers.getAttributeResult(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                      window: owner.window, ownedPopup: ownedPopup, mixer: owner.mixer, runtime: runtime.ax),
                  owner.currentIndex(runtime: runtime) != nil,
                  case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime), CFEqual(window, owner.window),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(owner.window, runtime: runtime),
                  document.utf8.elementsEqual(owner.document.utf8),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                Log.info("Input writer custody refused: sink/transport/window/document", subsystem: "ax"); return false
            }
            return true
        }
        guard ownerStillCurrent() else {
            return refusal(.routingDependencyUnknown, "The source must remain a stopped physical-output sink with every send observed empty.")
        }
        if observed == .bus(destination) {
            extras["after"] = OutputAssignment.bus(destination).json; extras["changed"] = false
            extras["verify_source"] = "ax_input_menu_checkmark"
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        guard let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList(),
              LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0,
              checkedOutputPopupMenus(in: owner.mixer, runtime: runtime.ax)?.isEmpty == true,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let originalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
              before.inputRenewal.map({ $0.permits(runtime: runtime) })
                ?? (readLogicKeyboardFocus(of: originalFocus, runtime: runtime) == .notTextEditing
                    || InputBusSagaAdapter.writePermission != nil),
              // The canonical context's exact held passive-focus proof is
              // renewed by ownerStillCurrent; default scalar focus is unchanged.
              ownerStillCurrent() else { return refusal(.staleTargetReference, "Original input custody changed before its popup opened.") }
        let press = AXHelpers.performActionResult(heldInput.control, kAXPressAction as String, runtime: runtime.ax)
        let pressSucceeded: Bool
        if case .success = press { pressSucceeded = true } else { pressSucceeded = false }
        extras["popup_press_succeeded"] = pressSucceeded
        let deadline = Date().addingTimeInterval(Double(timing.popupOpenTimeoutMs) / 1_000)
        var menus: [AXUIElement]?
        repeat {
            menus = checkedOutputPopupMenus(in: owner.mixer, runtime: runtime.ax)
            if menus == nil || !(menus?.isEmpty ?? true) || !ownerStillCurrent() { break }
            if timing.pollIntervalMs > 0 { try? await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) }
        } while !Task.isCancelled && Date() < deadline
        guard let menus, menus.count == 1, let root = menus.first else {
            extras["popup_menu_state"] = menus?.isEmpty == true ? "not_observed" : "unknown"
            return refusal(.readbackUnavailable, "The original input did not expose one owned popup; no destination was pressed.")
        }
        @Sendable func popupOwned() -> Bool {
            guard let current = checkedOutputPopupMenus(in: owner.mixer, runtime: runtime.ax),
                  current.count == 1, CFEqual(current[0], root),
                  runtime.logicProPID() == pid, runtime.focusedApplicationPID() == pid else { return false }
            // Stable sources have no renewal object. They still need the same
            // exact popup focus boundary: unchanged non-editor focus, or this
            // root's actual reciprocal search field, never a foreign editor.
            guard let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) else { return false }
            if CFEqual(focus, originalFocus) {
                guard before.inputRenewal.map({ $0.permits(runtime: runtime, ownedPopup: root) })
                    ?? (readLogicKeyboardFocus(of: focus, runtime: runtime) == .notTextEditing
                        || InputBusSagaAdapter.writePermission != nil) else { return false }
            } else {
                guard AXHelpers.getRole(focus, runtime: runtime.ax) == kAXTextFieldRole as String,
                      case .success(let rows) = AXHelpers.childrenResult(root, runtime: runtime.ax),
                      let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: runtime.ax) else { return false }
                if CFEqual(parent, root) {
                    guard rows.filter({ CFEqual($0, focus) }).count == 1 else { return false }
                } else {
                    guard rows.filter({ CFEqual($0, parent) }).count == 1,
                          let role = AXHelpers.getRole(parent, runtime: runtime.ax),
                          role == kAXGroupRole as String || role == "AXMenuItem",
                          let parentRoot: AXUIElement = AXHelpers.getAttribute(parent, kAXParentAttribute as String, runtime: runtime.ax),
                          CFEqual(parentRoot, root),
                          case .success(let children) = AXHelpers.childrenResult(parent, runtime: runtime.ax),
                          children.filter({ CFEqual($0, focus) }).count == 1 else { return false }
                }
            }
            guard let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(finalFocus, focus) else { return false }
            return ownerStillCurrent(ownedPopup: root)
        }
        func closeOwnedPopup(waitForSelfClose: Bool) async -> [String: Any] {
            let result = await closeOutputPopup(runtime: runtime, timing: timing,
                waitForSelfClose: waitForSelfClose, cleaner: { runtime in
                    // The generic popup cleaner can traverse unrelated menus.
                    // This inverse acts only on the exact held root, with renewed
                    // source/document custody after its deciding capability read.
                    guard popupOwned(),
                          case .success(let actions) = AXHelpers.getActionNamesResult(root, runtime: runtime.ax),
                          actions.contains(kAXCancelAction as String), popupOwned() else {
                        return .couldNotDismiss(initialPopupCount: 1, remainingPopupCount: 1)
                    }
                    _ = AXHelpers.performActionResult(root, kAXCancelAction as String, runtime: runtime.ax)
                    guard checkedOutputPopupMenus(in: owner.mixer, runtime: runtime.ax)?.isEmpty == true,
                          let windows = runtime.onScreenWindowList(),
                          LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 else {
                        return .couldNotDismiss(initialPopupCount: 1, remainingPopupCount: 1)
                    }
                    return .dismissed
                }, permittingCleanup: popupOwned)
            guard checkedOutputPopupMenus(in: owner.mixer, runtime: runtime.ax)?.isEmpty == true,
                  let windows = runtime.onScreenWindowList(),
                  LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0 else {
                return ["popup_menu_state": popupOwned() ? "not_restored" : "custody_lost"]
            }
            return result
        }
        func refuseAndClose(_ error: HonestContract.FailureError, _ hint: String) async -> ChannelResult {
            extras.merge(await closeOwnedPopup(waitForSelfClose: false)) { _, new in new }
            return refusal(error, hint)
        }
        // AXPress can report failure after Logic actually opens the menu. The
        // observed owned root and agreeing checked values, not its ACK, decide.
        guard popupOwned(), currentInputMenuAssignment(in: root, runtime: runtime.ax) == expected,
              popupOwned(), currentInputMenuAssignment(in: root, runtime: runtime.ax) == expected else {
            return await refuseAndClose(.staleSnapshot, "Checked current input changed with the popup open; nothing was selected.")
        }
        let choice = outputMenuChoice(for: .bus(destination), in: root, runtime: runtime.ax, receiverArrow: "←")
        guard case .item(let item, let path) = choice else {
            extras["destination_choice_failure"] = choice.failureLabel
            return await refuseAndClose(.elementNotFound, "No uniquely offered input bus was observed; nothing was selected.")
        }
        guard AXHelpers.getAttribute(item, kAXEnabledAttribute as String, runtime: runtime.ax) as Bool? == true,
              case .success(let actions) = AXHelpers.getActionNamesResult(item, runtime: runtime.ax),
              actions.contains(kAXPressAction as String), popupOwned(),
              case .item(let finalItem, let finalPath) = outputMenuChoice(for: .bus(destination),
                  in: root, runtime: runtime.ax, receiverArrow: "←"),
              CFEqual(finalItem, item), finalPath == path, popupOwned(),
              ownedCreation.map({ $0.permitsBefore(owner, popup: root) }) ?? true,
              popupOwned() else {
            return await refuseAndClose(.staleTargetReference, "Original source/menu action custody changed; nothing was selected.")
        }
        extras["write_attempted"] = true; extras["menu_path"] = path
        _ = AXHelpers.performActionResult(item, kAXPressAction as String, runtime: runtime.ax)
        let cleanup = await closeOwnedPopup(waitForSelfClose: true)
        extras.merge(cleanup) { _, new in new }
        guard cleanup["popup_menu_state"] as? String == "closed" || cleanup["popup_menu_state"] as? String == "dismissed" else {
            return uncertain(.readbackUnavailable, "The input was pressed but its popup did not close under original custody; stop dependent writes.")
        }
        var afterOwner = owner
        var afterPair = pair
        var writerRenewal: OriginalHeaderSourceRenewal?
        if owner.currentIndex(runtime: runtime) == nil {
            guard let pair, pair.strip.matches(owner) else {
                return uncertain(.readbackUnavailable, "The physical source retired without an original held header pair; reread before any inverse.")
            }
            let renewal = await renewSourceThroughOriginalHeader(pair, original: owner, runtime: runtime)
            extras["ui_effects"] = ["navigation_performed": renewal.effects.navigationPerformed,
                "attempted": renewal.effects.attempted, "changed": renewal.effects.changed,
                "restoration": renewal.effects.restoration]
            guard let source = renewal.source, source.permits(runtime: runtime) else {
                return uncertain(.readbackUnavailable, "The source retired and no verified original-header renewal survived; stop dependent writes.")
            }
            afterOwner = source.pair.strip; afterPair = source.pair
            writerRenewal = source
            if let observer = InputBusSagaAdapter.sourceRenewalObserver, !(await observer(source)) {
                return uncertain(.readbackUnavailable, "Owned name continuity ended after input actuation; stop dependent writes.")
            }
            extras["source_renewal"] = source.pair.source
            extras["reference_reread_required"] = true
        }
        // Finish output popup acquisition before the input's final original-header
        // witness: another popup can invalidate that request-local relationship.
        // The final same-owner output/send/control checks below still bookend it.
        let finalOutput = await checkedSink(afterOwner)
        recordRead(finalOutput, key: "output_after_write")
        let after = await AXMixerStripBinding.$current.withValue(afterOwner) {
            await AXMixerStripBinding.$outputAssociation.withValue(afterPair) {
                await getInputBusObservation(runtime: runtime, timing: timing)
            }
        }
        recordRead(after, key: "after_acquisition")
        let finalOwner = after.inputRenewal?.pair.strip ?? afterOwner
        if let source = after.inputRenewal, let observer = InputBusSagaAdapter.sourceRenewalObserver,
           !(await observer(source)) {
            return uncertain(.readbackUnavailable, "Owned name continuity ended during final input acquisition; stop dependent writes.")
        }
        if after.inputRenewal != nil {
            extras["reference_reread_required"] = true
            extras["source_renewal"] = after.inputRenewal?.pair.source
        }
        guard let finalPopulation = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: finalOwner.mixer, runtime: runtime.ax) else {
            return uncertain(.readbackUnavailable, "Final population could not be independently read; stop dependent writes.")
        }
        extras["strip_count_after"] = finalPopulation.strips.count
        guard finalPopulation.strips.count == population.strips.count else {
            return refusal(.unexpectedSideEffect, "Input selection changed the strip population; no cleanup or inverse was attempted.")
        }
        guard case .bus(let actual)? = after.assignment, let finalSlot = after.inputSlot,
              finalSlot.owner.matches(finalOwner) else {
            return uncertain(.readbackUnavailable, "The same receiver's committed input did not have checked after-evidence; stop dependent writes.")
        }
        guard sinkStillCurrent(finalOwner), finalOutput.assignment == sink else {
            return uncertain(.readbackUnavailable, "The receiver's physical output or observed-empty sends changed after checked input readback; stop dependent writes.")
        }
        guard (after.inputRenewal ?? writerRenewal ?? before.inputRenewal).map({ $0.permits(runtime: runtime) }) != false else {
            return uncertain(.readbackUnavailable, "Original-header renewal custody ended after checked input readback; stop dependent writes.")
        }
        guard finalOwner.currentIndex(runtime: runtime) != nil else {
            return uncertain(.readbackUnavailable, "The checked receiver retired after final output readback; stop dependent writes.")
        }
        let finalInput = AXLogicProElements.inputSlotRead(in: finalOwner.strip, runtime: runtime.ax)
        guard case .source(let finalLabel) = finalInput.reading, let finalControl = finalInput.control,
              finalSlot.matches(.init(owner: finalOwner, control: finalControl, source: finalLabel)),
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
              checkedOutputPopupMenus(in: finalOwner.mixer, runtime: runtime.ax)?.isEmpty == true,
              let finalPID = runtime.logicProPID(), runtime.focusedApplicationPID() == finalPID,
              let finalWindows = runtime.onScreenWindowList(),
              LogicOnScreenWindows.popupMenuCount(finalWindows, logicPID: finalPID) == 0,
              (after.inputRenewal ?? writerRenewal ?? before.inputRenewal).map({ $0.permits(runtime: runtime) }) != false,
              AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false,
              AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false,
              !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
              let finalApp = AXLogicProElements.appRoot(runtime: runtime),
              AXHelpers.getAttribute(finalApp, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
              let main: AXUIElement = AXHelpers.getAttribute(finalApp, kAXMainWindowAttribute as String, runtime: runtime.ax),
              let focused: AXUIElement = AXHelpers.getAttribute(finalApp, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
              CFEqual(main, finalOwner.window), CFEqual(focused, finalOwner.window),
              finalOwner.currentIndex(runtime: runtime) != nil,
              case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(finalOwner.window, runtime: runtime),
              finalDocument.utf8.elementsEqual(finalOwner.document.utf8),
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
            extras["popup_menu_state"] = "unknown"
            return uncertain(.readbackUnavailable, "Final control or popup custody changed after checked readback; stop dependent writes.")
        }
        extras["popup_menu_state"] = "closed"
        extras["after"] = OutputAssignment.bus(actual).json
        extras["changed"] = InputAssignment.bus(actual) != observed
        extras["verify_source"] = "ax_input_menu_checkmark"
        guard actual == destination else {
            return uncertain(.readbackMismatch, "The committed checked input differs from the request; no inverse was attempted.")
        }
        guard recordInputEffect(original: AXMixerStripBinding.outputAssociation, current: after.inputRenewal?.pair ?? afterPair,
            renewal: after.inputRenewal ?? writerRenewal ?? before.inputRenewal,
            control: finalSlot, population: finalPopulation.strips, sink: sink,
            before: observed, after: actual, checkedAfter: after, runtime: runtime, creation: ownedCreation) else {
            return uncertain(.readbackUnavailable, "The input changed but native effect custody could not be retained; stop dependent writes.")
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }
}
