@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    @TaskLocal static var outputChangeObserver: (@Sendable (ChangedOutputObservation) -> Void)?

    /// Request-local native custody for one output leaf that was independently
    /// read back by the scalar. This is never reconstructed from its wire JSON.
    /// A later Saga read may retain the checked assignment only while this exact
    /// source, control, population, focus and displayed destination remain live.
    struct ChangedOutputObservation: @unchecked Sendable {
        let original: HeldSelectionAssociation.Pair
        let current: HeldSelectionAssociation.Pair
        let renewal: OriginalHeaderSourceRenewal?
        let control: AXUIElement
        let population: [AXUIElement]
        let before: OutputAssignment
        let after: OutputAssignment
        let label: String
        let focus: AXUIElement
        let sampledAt: String

        func permits(runtime: AXLogicProElements.Runtime) -> Bool {
            guard before != after,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  original.track.matches(current.track),
                  renewal.map({ source in
                      source.original.matches(original.strip)
                          && source.originalTrack.matches(original.track)
                          && source.pair.track.matches(current.track)
                          && source.pair.strip.matches(current.strip)
                          && source.permits(runtime: runtime)
                  }) ?? original.strip.matches(current.strip),
                  current.track.currentIndex() != nil,
                  current.strip.currentIndex(runtime: runtime) != nil,
                  current.track.document.utf8.elementsEqual(current.strip.document.utf8),
                  let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
                  let app = AXLogicProElements.appRoot(runtime: runtime),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: runtime.ax) as Bool? == true,
                  let currentFocus: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                  CFEqual(currentFocus, focus),
                  let main: AXUIElement = AXHelpers.getAttribute(app,
                    kAXMainWindowAttribute as String, runtime: runtime.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                  CFEqual(main, current.strip.window), CFEqual(focusedWindow, current.strip.window),
                  AXLogicProElements.readControlBarCheckboxValue(
                    matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false,
                  AXLogicProElements.readControlBarCheckboxValue(
                    matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false,
                  !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
                  AccessibilityChannel.checkedOutputPopupMenus(
                    in: current.strip.mixer, runtime: runtime.ax)?.isEmpty == true,
                  runtime.onScreenWindowList().map({
                      LogicOnScreenWindows.popupMenuCount($0, logicPID: pid) == 0
                  }) == true,
                  let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(
                    in: current.strip.mixer, runtime: runtime.ax)?.strips,
                  census.count == population.count,
                  zip(census, population).allSatisfy({ CFEqual($0, $1) }),
                  census.filter({ CFEqual($0, current.strip.strip) }).count == 1,
                  let firstControl = AXLogicProElements.outputSlotButton(
                    in: current.strip.strip, runtime: runtime.ax),
                  CFEqual(firstControl, control),
                  let firstLabel = AXLogicProElements.outputSlotDestination(
                    in: current.strip.strip, runtime: runtime.ax),
                  firstLabel.utf8.elementsEqual(label.utf8),
                  OutputAssignment.observed(slotLabel: firstLabel) == after,
                  let finalControl = AXLogicProElements.outputSlotButton(
                    in: current.strip.strip, runtime: runtime.ax),
                  CFEqual(finalControl, control),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(
                    current.strip.window, runtime: runtime),
                  document.utf8.elementsEqual(current.strip.document.utf8),
                  current.track.currentIndex() != nil,
                  current.strip.currentIndex(runtime: runtime) != nil,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }
    }

    /// Publish only to the in-process Saga observer that installed the scalar.
    /// Standalone callers retain the historical writer contract unchanged.
    static func recordOutputEffect(
        original: HeldSelectionAssociation.Pair?,
        current: HeldSelectionAssociation.Pair?,
        renewal: OriginalHeaderSourceRenewal?,
        control: AXUIElement?,
        population: [AXUIElement]?,
        before: OutputAssignment,
        after: OutputAssignment,
        label: String?,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let observer = outputChangeObserver else { return true }
        guard let original, let current, let control, let population, let label,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let focus: AXUIElement = AXHelpers.getAttribute(app,
                kAXFocusedUIElementAttribute as String, runtime: runtime.ax) else { return false }
        let proof = ChangedOutputObservation(original: original, current: current,
            renewal: renewal, control: control, population: population,
            before: before, after: after, label: label, focus: focus,
            sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
        guard proof.permits(runtime: runtime) else { return false }
        observer(proof)
        return true
    }
}
