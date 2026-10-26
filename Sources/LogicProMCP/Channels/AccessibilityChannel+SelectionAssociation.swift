@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Explicit held-rail selections, not a name/ordinal join or a global census.
    /// A held passive focus plus this Mixer's actual selected-child relationship
    /// can also start an explicitly owned, exposed-header observation.
    final class HeldSelectionAssociation: @unchecked Sendable {
        struct Pair: @unchecked Sendable {
            let track: AXTrackBinding.Binding
            let strip: AXMixerStripBinding.Binding
            var source = "held_exclusive_selection_focus"
        }
        typealias ViewportControl = (element: AXUIElement, value: Double, zoomDescription: String?)
        let logic: AXLogicProElements.Runtime
        let app: AXUIElement
        let pid: pid_t
        let window: AXUIElement
        let document: String
        let title: String
        let rail: AXUIElement
        let railPath: [AXUIElement]
        let headers: [AXUIElement]
        let mixer: AXUIElement
        let strips: [AXUIElement]
        let path: [AXUIElement]
        let originalIndex: Int
        let originalFocus: AXUIElement
        let transport: AXLogicProElements.ObservedTransportActivity
        let transportPaths: [[AXUIElement]]
        let viewport: [ViewportControl]
        let viewportPaths: [[AXUIElement]]
        private var expectedViewport: [ViewportControl]
        private var expectedMixerViewport: MixerViewportGeometry?
        private var expectedIndex: Int
        private var expectedFocus: AXUIElement
        private var originalSelectedChild: AXUIElement?
        private var expectedSelectedChild: AXUIElement?
        private let originalRailFocus: AXUIElement?
        private let originalHeaderFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus?
        private let retainedTrackBindings: [AXTrackBinding.Binding]?
        private var lost = false
        private(set) var effects = SessionPopulationObservation.UIEffects()

        init?(window: AXUIElement, logic: AXLogicProElements.Runtime,
              expectedProject: TargetDescriptor?, requiresProjectReference: Bool,
              allowsSelectedChildRailEntry: Bool = false,
              retainedHeaderFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus? = nil,
              retainedTrackBindings: [AXTrackBinding.Binding]? = nil,
              restorationBaseline: HeldSelectionAssociation? = nil,
              retainedMixerSource: AXMixerStripBinding.Binding? = nil) {
            // The existing foreground AX probe requires this CLI process's
            // window-server connection; a missing/foreign PID still refuses.
            _ = logic.onScreenWindowList()
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let pid = logic.logicProPID(), let app = AXLogicProElements.appRoot(runtime: logic),
                  let title = AXHelpers.getTitle(window, runtime: logic.ax),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  let url = URL(string: document), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  retainedMixerSource.map({ CFEqual($0.window, window)
                      && $0.document.utf8.elementsEqual(document.utf8) }) ?? true,
                  !requiresProjectReference || (
                    expectedProject?.projectName?.utf8.elementsEqual(AccessibilityChannel.projectName(fromWindowTitle: title).utf8) == true
                    && expectedProject?.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true),
                  let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: logic),
                  let railPath = Self.path(rail, to: window, ax: logic.ax),
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic),
                  headers.count > 1,
                  retainedTrackBindings.map({ bindings in
                      bindings.count == headers.count && zip(bindings, headers).allSatisfy { binding, header in
                          CFEqual(binding.window, window) && CFEqual(binding.header, header)
                              && binding.document.utf8.elementsEqual(document.utf8)
                              && (binding.exposure?.isCurrent ?? true)
                      }
                  }) ?? true,
                  let selected = Self.exclusiveIndex(headers, ax: logic.ax),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  retainedHeaderFocus.map({ CFEqual($0.focus, focus) && CFEqual($0.window, window)
                      && CFEqual($0.rail, rail) && CFEqual($0.header, headers[selected]) && $0.permits() }) ?? true,
                  let mixer = Self.entryMixer(focus: focus, window: window, railPath: railPath,
                    logic: logic, allowsSelectedChildRailEntry: allowsSelectedChildRailEntry,
                    retainedHeaderFocus: retainedHeaderFocus, retainedMixer: retainedMixerSource?.mixer),
                  let enumeration = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                  enumeration.strips.filter({ CFEqual($0, focus) }).count == 1
                    || (allowsSelectedChildRailEntry && (railPath.contains { CFEqual($0, focus) }
                        || retainedHeaderFocus != nil)),
                  let path = Self.path(mixer, to: window, ax: logic.ax),
                  let viewport = Self.viewport(window, ax: logic.ax),
                  let viewportPaths = Self.viewportPaths(viewport, window: window, ax: logic.ax),
                  let activity = try? AXLogicProElements.observedTransportActivity(in: window, runtime: logic,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  !activity.isPlaying, !activity.isRecording,
                  let playPath = Self.path(activity.play, to: window, ax: logic.ax),
                  let recordPath = Self.path(activity.record, to: window, ax: logic.ax),
                  playPath.contains(where: { CFEqual($0, activity.controlBar) }),
                  recordPath.contains(where: { CFEqual($0, activity.controlBar) }) else { return nil }
            self.logic = logic; self.app = app; self.pid = pid; self.window = window
            self.title = title; self.document = document; self.rail = rail; self.railPath = railPath; self.headers = headers
            self.mixer = mixer; strips = enumeration.strips; self.path = path
            originalIndex = selected; originalFocus = restorationBaseline?.originalFocus ?? focus
            expectedIndex = selected; expectedFocus = focus
            originalRailFocus = enumeration.strips.contains { CFEqual($0, focus) } ? nil : focus
            originalHeaderFocus = retainedHeaderFocus
            self.retainedTrackBindings = retainedTrackBindings
            transport = activity; self.viewport = viewport
            self.viewportPaths = viewportPaths; expectedViewport = viewport
            transportPaths = [playPath, recordPath]
            if let baseline = restorationBaseline {
                // A verified caller-owned effect may end on another already
                // qualified passive focus. Keep the prior restoration duty,
                // never turn the new focus/viewport into the original baseline.
                guard !baseline.lost, baseline.expectedIndex == baseline.originalIndex,
                      baseline.originalIndex == selected, CFEqual(baseline.app, app), baseline.pid == pid,
                      CFEqual(baseline.window, window), baseline.document.utf8.elementsEqual(document.utf8),
                      baseline.title.utf8.elementsEqual(title.utf8), CFEqual(baseline.rail, rail),
                      CFEqual(baseline.mixer, mixer), Self.same(baseline.headers, headers), Self.same(baseline.strips, strips),
                      Self.same(baseline.railPath, railPath), Self.same(baseline.path, path),
                      Self.sameViewport(baseline.viewport, viewport),
                      Self.sameViewport(baseline.expectedViewport, viewport),
                      baseline.viewportPaths.count == viewportPaths.count,
                      zip(baseline.viewportPaths, viewportPaths).allSatisfy({ Self.same($0, $1) }),
                      baseline.transportPaths.count == transportPaths.count,
                      zip(baseline.transportPaths, transportPaths).allSatisfy({ Self.same($0, $1) }),
                      CFEqual(baseline.transport.play, activity.play), CFEqual(baseline.transport.record, activity.record),
                      baseline.transport.isPlaying == activity.isPlaying,
                      baseline.transport.isRecording == activity.isRecording else { return nil }
            }
            if originalRailFocus != nil {
                // A passive rail focus is never a fallback focus/strip pair.
                // This entry needs this exact Mixer's actual held relationship.
                guard case .observed(let child) = selectedChildRead() else { return nil }
                originalSelectedChild = child; expectedSelectedChild = child
            }
            guard permitsRead(), AXHelpers.isAttributeSettable(rail, kAXSelectedChildrenAttribute as String,
                runtime: logic.ax) == true else { return nil }
        }

        private static func entryMixer(focus: AXUIElement, window: AXUIElement,
                                       railPath: [AXUIElement], logic: AXLogicProElements.Runtime,
                                       allowsSelectedChildRailEntry: Bool,
                                       retainedHeaderFocus: OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus?,
                                       retainedMixer: AXUIElement?) -> AXUIElement? {
            guard allowsSelectedChildRailEntry,
                  railPath.contains(where: { CFEqual($0, focus) }) || retainedHeaderFocus != nil else {
                // Preserve scalar/default acquisition exactly: the focus's
                // original physical parent supplies its Mixer candidate.
                return AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax)
            }
            if let retainedMixer {
                // Renew this already-held native owner, not a whole-window Help
                // discovery through the old census after popup cleanup. The
                // constructor still proves its reciprocal path, complete current
                // strips, rail, selected child, viewport and stopped transport.
                guard Self.path(retainedMixer, to: window, ax: logic.ax) != nil else { return nil }
                return retainedMixer
            }
            guard case .found(let mixer) = (try? AXLogicProElements.mixerPopulationAreaLookup(
                in: window, runtime: logic, requiresCompleteAbsence: true,
                checking: { try SessionPopulationObservation.requireOwnedAcquisition() }))?.lookup else { return nil }
            return mixer
        }

        private static func exclusiveIndex(_ headers: [AXUIElement], ax: AXHelpers.Runtime) -> Int? {
            let values = headers.map { AXValueExtractors.extractSelectedState($0, runtime: ax) }
            guard values.allSatisfy({ $0 != nil }), values.filter({ $0 == true }).count == 1 else { return nil }
            return values.firstIndex(where: { $0 == true })
        }

        private static func same(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { CFEqual($0, $1) }
        }

        static func path(_ mixer: AXUIElement, to window: AXUIElement, ax: AXHelpers.Runtime) -> [AXUIElement]? {
            var path = [mixer]
            // Preserve the status-bearing childrenResult seam of older runtimes.
            guard ax.attributeValuesResult != nil else {
                while !CFEqual(path.last!, window) {
                    guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                          path.count < 32,
                          let parent: AXUIElement = AXHelpers.getAttribute(path.last!, kAXParentAttribute as String, runtime: ax),
                          !path.contains(where: { CFEqual($0, parent) }),
                          case .success(let children) = AXHelpers.childrenResult(parent, runtime: ax),
                          children.filter({ CFEqual($0, path.last!) }).count == 1 else { return nil }
                    path.append(parent)
                }
                return path
            }
            if CFEqual(mixer, window) { return path }
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let firstParent: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: ax) else { return nil }
            var parent = firstParent
            while !CFEqual(path.last!, window) {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      path.count < 32,
                      !path.contains(where: { CFEqual($0, parent) }) else { return nil }
                let atWindow = CFEqual(parent, window)
                // Fresh reciprocal witnesses on this original parent, not a
                // cached path or a second hierarchy/name/ordinal lookup. Help
                // remains outside the batch and under its full per-read guard.
                let attributes = atWindow ? [kAXChildrenAttribute as String]
                    : [kAXChildrenAttribute as String, kAXParentAttribute as String]
                let readings = AXHelpers.getNonHelpAttributes(parent, attributes, runtime: ax,
                    permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
                guard case .success(.some(let rawChildren)) = readings[0],
                      CFGetTypeID(rawChildren) == CFArrayGetTypeID(),
                      AXHelpers.decodeChildrenArray(rawChildren).filter({ CFEqual($0, path.last!) }).count == 1 else { return nil }
                path.append(parent)
                if !atWindow {
                    guard case .success(.some(let rawParent)) = readings[1],
                          CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return nil }
                    parent = unsafeBitCast(rawParent, to: AXUIElement.self)
                }
            }
            return path
        }

        private static func viewport(_ window: AXUIElement, ax: AXHelpers.Runtime,
                                     held: [ViewportControl]? = nil) -> [ViewportControl]? {
            var sliders: [AXUIElement] = []
            guard case .success(let census) = AXHelpers.censusDescendantResult(of: window, role: kAXScrollBarRole as String,
                maxDepth: 32, runtime: ax, requiresCompleteTraversal: true, batchingRoleAndChildren: true,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil },
                observingRole: { element, role in
                    if role == kAXSliderRole as String { sliders.append(element) }
                }) else { return nil }
            var controls: [(AXUIElement, String?)] = census.matches.map { ($0, nil) }
            let zoomLabels = AXLocalePolicy.horizontalZoomSlider.labels + AXLocalePolicy.verticalZoomSlider.labels
            // Discover own zoom controls before navigation. Inspector selection
            // may redraw unrelated sliders; their descriptions cannot revoke
            // custody of an original, reciprocally held viewport control.
            let zooms = held.map { $0.filter { $0.zoomDescription != nil }.map { ($0.element, $0.zoomDescription) } }
                ?? sliders.map { ($0, nil as String?) }
            for (slider, heldDescription) in zooms {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
                if heldDescription != nil {
                    // A role contradiction sampled by this fresh census is
                    // irreversible; a later role read cannot erase it.
                    guard sliders.filter({ CFEqual($0, slider) }).count == 1,
                          AXHelpers.getRole(slider, runtime: ax) == kAXSliderRole as String else { return nil }
                }
                switch AXHelpers.getAttributeResult(slider, kAXDescriptionAttribute as String,
                    runtime: ax) as Result<AnyObject?, AXHelpers.AXStatusError> {
                case .success(.some(let rawDescription)):
                    guard CFGetTypeID(rawDescription) == CFStringGetTypeID(),
                          let description = rawDescription as? String else { return nil }
                    if let heldDescription {
                        guard description.utf8.elementsEqual(heldDescription.utf8) else { return nil }
                        controls.append((slider, heldDescription))
                    } else if zoomLabels.contains(description) { controls.append((slider, description)) }
                case .success(.none): if heldDescription != nil { return nil }
                case .failure(let error) where error.isDefinitiveAbsence: if heldDescription != nil { return nil }
                default: return nil
                }
            }
            var result: [ViewportControl] = []
            for (control, description) in controls {
                guard case .success(.some(let value)) = AXHelpers.getAttributeResult(control, kAXValueAttribute as String,
                    runtime: ax) as Result<NSNumber?, AXHelpers.AXStatusError>, value.doubleValue.isFinite else { return nil }
                result.append((control, value.doubleValue, description))
            }
            return result
        }

        private static func viewportPaths(_ viewport: [ViewportControl], window: AXUIElement,
                                          ax: AXHelpers.Runtime) -> [[AXUIElement]]? {
            var paths: [[AXUIElement]] = []
            for (control, _, _) in viewport {
                guard let path = Self.path(control, to: window, ax: ax) else { return nil }
                paths.append(path)
            }
            return paths
        }

        private static func sameViewport(_ lhs: [ViewportControl], _ rhs: [ViewportControl],
                                         includingValues: Bool = true) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                CFEqual($0.0, $1.0) && $0.2 == $1.2 && (!includingValues || $0.1 == $1.1)
            }
        }

        private func currentViewport() -> [ViewportControl]? {
            guard let current = Self.viewport(window, ax: logic.ax, held: viewport),
                  Self.sameViewport(current, viewport, includingValues: false),
                  let paths = Self.viewportPaths(current, window: window, ax: logic.ax),
                  paths.count == viewportPaths.count,
                  zip(paths, viewportPaths).allSatisfy({ Self.same($0, $1) }) else {
                lost = true; return nil
            }
            return current
        }

        private func currentWindowScopeMatches() -> Bool {
            guard logic.ax.attributeValuesResult != nil else {
                guard AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                      case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic)
                else { return false }
                return document.utf8.elementsEqual(currentDocument.utf8)
            }
            // Fresh values from this exact held window, not an earlier scope
            // receipt. The separate final Document/PID/deadline bookend remains.
            let values = AXHelpers.getNonHelpAttributes(window,
                [kAXTitleAttribute, kAXDocumentAttribute] as [String], runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let rawTitle)) = values[0], CFGetTypeID(rawTitle) == CFStringGetTypeID(),
                  let currentTitle = rawTitle as? String, currentTitle.utf8.elementsEqual(title.utf8),
                  case .success(.some(let rawDocument)) = values[1], CFGetTypeID(rawDocument) == CFStringGetTypeID(),
                  let currentDocument = rawDocument as? String else { return false }
            return document.utf8.elementsEqual(currentDocument.utf8)
        }

        private func owned(checkingAssociation: Bool = true, ownedPopup: AXUIElement? = nil,
                           checkingStoppedTransport: Bool = true,
                           nativeOutputSource: AXMixerStripBinding.Binding? = nil) -> Bool {
            func railMatches() -> Bool {
                guard checkingAssociation else { return true }
                guard let currentRailPath = Self.path(rail, to: window, ax: logic.ax), Self.same(railPath, currentRailPath),
                      case .success(let currentHeaders) = AXHelpers.childrenResult(rail, runtime: logic.ax) else { return false }
                return Self.same(headers, currentHeaders)
            }
            func stripCustodyMatches() -> Bool {
                if checkingAssociation || originalRailFocus != nil {
                    // Inspect the same census used by the complete-read helper;
                    // diagnostics must not obtain a second, different sample.
                    guard let current = AXLogicProElements.stripEnumeration(in: mixer, runtime: logic.ax) else {
                        Log.info("Held Mixer census refused: children_unreadable", subsystem: "ax")
                        return false
                    }
                    guard current.unreadableChildren == 0 else {
                        Log.info("Held Mixer census refused: unreadable_roles=\(current.unreadableChildren), expected_count=\(strips.count), observed_count=\(current.strips.count)", subsystem: "ax")
                        return false
                    }
                    guard Self.same(strips, current.strips) else {
                        let missing = strips.indices.filter { index in
                            !current.strips.contains { CFEqual(strips[index], $0) }
                        }
                        let unexpected = current.strips.indices.filter { index in
                            !strips.contains { CFEqual(current.strips[index], $0) }
                        }
                        let reordered = strips.indices.filter { index in
                            index < current.strips.count && !CFEqual(strips[index], current.strips[index])
                        }
                        let original = originalSelectedChild ?? originalFocus
                        let originalCount = current.strips.filter { CFEqual($0, original) }.count
                        let expectedCount = current.strips.filter { CFEqual($0, expectedSelectedChild ?? expectedFocus) }.count
                        Log.info("Held Mixer census refused: population_mismatch, expected_count=\(strips.count), observed_count=\(current.strips.count), missing_indices=\(missing), unexpected_indices=\(unexpected), changed_positions=\(reordered), original_member_count=\(originalCount), expected_member_count=\(expectedCount)", subsystem: "ax")
                        return false
                    }
                    return true
                }
                // A focus-moving read is not a rail-selection capability.
                // Renew this exact focus's reciprocal Mixer membership only;
                // never adopt another strip by name or position.
                guard case .success(let children) = AXHelpers.childrenResult(mixer, runtime: logic.ax),
                      children.filter({ CFEqual($0, expectedFocus) }).count == 1,
                      let parent: AXUIElement = AXHelpers.getAttribute(expectedFocus, kAXParentAttribute as String, runtime: logic.ax) else { return false }
                return CFEqual(parent, mixer)
            }
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  retainedTrackBindings?.allSatisfy({ $0.exposure?.isCurrent ?? true }) ?? true,
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp) else {
                lost = true; return false
            }
            let application = AXHelpers.getNonHelpAttributes(app,
                [kAXFrontmostAttribute, kAXWindowsAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String],
                runtime: logic.ax, permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let frontmost)) = application[0], frontmost as? Bool == true,
                  case .success(.some(let windowValues)) = application[1],
                  case .success(let windows) = AXHelpers.projectChildrenStatus(.success, windowValues),
                  case .success(.some(let mainValue)) = application[2], CFGetTypeID(mainValue) == AXUIElementGetTypeID() else {
                let states = application.map { reading -> String in
                    switch reading {
                    case .success(.some(let value)): return "type:\(CFGetTypeID(value))"
                    case .success(.none): return "absent"
                    case .failure(let error): return "AX:\(error.raw)"
                    }
                }.joined(separator: ",")
                Log.info("Held association ownership refused: application window attributes [\(states)]", subsystem: "ax")
                lost = true; return false
            }
            let main = unsafeBitCast(mainValue, to: AXUIElement.self)
            let focusedWindowMatches: Bool
            if AccessibilityChannel.routingFocusedWindowMatches(application[3],
                window: window, ownedPopup: ownedPopup, mixer: mixer, runtime: logic.ax) {
                focusedWindowMatches = true
            } else if case .failure(let error) = application[3], error.raw == AXError.noValue.rawValue,
                      let root = ownedPopup, let source = nativeOutputSource {
                // Like the ordinary menu's measured AXNoValue, this exact
                // response needs a fresh reciprocal native popup/source proof.
                // Missing, unreadable and foreign windows gain no exception.
                focusedWindowMatches = nativeOutputPopupMatches(root, source: source)
            } else {
                focusedWindowMatches = false
            }
            guard
                  windows.filter({ CFEqual($0, window) }).count == 1,
                  CFEqual(main, window), focusedWindowMatches else {
                let focusedReading: String
                switch application[3] {
                case .failure(let error): focusedReading = "AX:\(error.raw)"
                case .success(.none): focusedReading = "absent"
                case .success(.some(let value)): focusedReading = "type:\(CFGetTypeID(value))"
                }
                Log.info("Held association ownership refused: window/dialog (main=\(CFEqual(main, window)), focused=\(focusedWindowMatches), reading=\(focusedReading))", subsystem: "ax")
                lost = true; return false
            }
            func refuseWindowScope(_ checkpoint: String) -> Bool {
                let acquisition: String
                do {
                    try SessionPopulationObservation.requireOwnedAcquisition()
                    acquisition = "current"
                } catch { acquisition = String(describing: error) }
                Log.info("Held association ownership refused: checkpoint=\(checkpoint), acquisition=\(acquisition)", subsystem: "ax")
                lost = true
                return false
            }
            guard currentWindowScopeMatches() else { return refuseWindowScope("window_scope") }
            // dialogPresent delegates to this same read. Preserve its existing
            // position after window scope, and retain the actual refusal reason.
            let dialogReason = AXLogicProElements.dialogPresenceReason(runtime: logic)
            guard !dialogReason.isBlocked else { return refuseWindowScope("dialog_" + dialogReason.rawValue) }
            guard railMatches() else {
                Log.info("Held association ownership refused: original rail census", subsystem: "ax")
                lost = true; return false
            }
            guard let currentPath = Self.path(mixer, to: window, ax: logic.ax), Self.same(path, currentPath) else {
                Log.info("Held association ownership refused: original Mixer path", subsystem: "ax")
                lost = true; return false
            }
            guard stripCustodyMatches() else {
                Log.info("Held association ownership refused: original Mixer strip census", subsystem: "ax")
                lost = true; return false
            }
            guard !checkingStoppedTransport || stoppedTransportPathsMatch() else {
                Log.info("Held association ownership refused: original transport path/value", subsystem: "ax")
                lost = true; return false
            }
            guard case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  document.utf8.elementsEqual(finalDocument.utf8), logic.logicProPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { lost = true; return false }
            return true
        }

        private func stoppedTransportPathsMatch() -> Bool {
            Self.stoppedTransportPathsMatch(transportPaths, activity: transport, window: window, logic: logic)
        }

        static func stoppedTransportPathsMatch(_ paths: [[AXUIElement]],
            activity: AXLogicProElements.ObservedTransportActivity, window: AXUIElement,
            logic: AXLogicProElements.Runtime) -> Bool {
            guard paths.count == 2, !CFEqual(activity.play, activity.record),
                  paths.allSatisfy({ (2...32).contains($0.count) && CFEqual($0[$0.count - 1], window)
                      && $0.contains(where: { CFEqual($0, activity.controlBar) }) }),
                  CFEqual(paths[0][0], activity.play), CFEqual(paths[1][0], activity.record) else { return false }
            do { try SessionPopulationObservation.requireOwnedAcquisition() }
            catch {
                Log.info("Routing transport acquisition refused: \(error)", subsystem: "ax")
                return false
            }
            var edges: [(child: AXUIElement, parent: AXUIElement)] = []
            var parents: [AXUIElement] = []
            for path in paths {
                for index in path.indices {
                    guard !path[..<index].contains(where: { CFEqual($0, path[index]) }) else { return false }
                    guard index + 1 < path.count else { continue }
                    let child = path[index], parent = path[index + 1]
                    if let prior = edges.first(where: { CFEqual($0.child, child) }) {
                        guard CFEqual(prior.parent, parent) else { return false }
                    } else { edges.append((child, parent)) }
                    if !parents.contains(where: { CFEqual($0, parent) }) { parents.append(parent) }
                }
            }
            func distanceToWindow(_ parent: AXUIElement) -> Int {
                paths.compactMap { path in
                    path.firstIndex(where: { CFEqual($0, parent) }).map { path.count - $0 }
                }.max() ?? 0
            }
            // Read each separate branch before its shared ancestors. Otherwise
            // a later branch read could invalidate an already sampled parent.
            parents.sort { distanceToWindow($0) > distanceToWindow($1) }
            func acquired() -> Bool { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil }
            func controlsCurrent() -> Bool {
                for held in paths {
                    let attributes = AXHelpers.getNonHelpAttributes(held[0],
                        [kAXRoleAttribute, kAXValueAttribute, kAXParentAttribute] as [String],
                        runtime: logic.ax, permittingRead: acquired)
                    guard case .success(.some(let role)) = attributes[0], role as? String == kAXCheckBoxRole as String,
                          case .success(.some(let rawValue)) = attributes[1], let value = rawValue as? NSNumber,
                          value == 0,
                          case .success(.some(let rawParent)) = attributes[2],
                          CFGetTypeID(rawParent) == AXUIElementGetTypeID(),
                          CFEqual(unsafeBitCast(rawParent, to: AXUIElement.self), held[1]) else { return false }
                }
                return acquired()
            }
            guard controlsCurrent() else { return false }
            // One fresh reciprocal census per shared ancestor, confined to this
            // decision. Neither a stored path nor a repeated Play/Record caption
            // grants membership. Every original edge must still agree, including
            // when reading the second control changed the first one's custody.
            for parent in parents {
                let children: [AXUIElement]
                let next: AXUIElement?
                if logic.ax.attributeValuesResult != nil {
                    let attributes = CFEqual(parent, window) ? [kAXChildrenAttribute as String]
                        : [kAXChildrenAttribute as String, kAXParentAttribute as String]
                    let reads = AXHelpers.getNonHelpAttributes(parent, attributes, runtime: logic.ax,
                        permittingRead: acquired)
                    guard case .success(.some(let rawChildren)) = reads[0],
                          case .success(let observed) = AXHelpers.projectChildrenStatus(.success, rawChildren)
                    else { return false }
                    children = observed
                    if CFEqual(parent, window) { next = nil }
                    else {
                        guard case .success(.some(let rawParent)) = reads[1],
                              CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return false }
                        next = unsafeBitCast(rawParent, to: AXUIElement.self)
                    }
                } else {
                    // Older injected runtimes retain their status-bearing
                    // childrenResult seam; do not bridge an unread to absence.
                    guard acquired(), case .success(let observed) = AXHelpers.childrenResult(parent, runtime: logic.ax) else { return false }
                    children = observed
                    if CFEqual(parent, window) { next = nil }
                    else {
                        guard acquired(), let observed: AXUIElement = AXHelpers.getAttribute(parent,
                            kAXParentAttribute as String, runtime: logic.ax) else { return false }
                        next = observed
                    }
                }
                guard edges.filter({ CFEqual($0.parent, parent) }).allSatisfy({ edge in
                    children.filter({ CFEqual($0, edge.child) }).count == 1
                }) else { return false }
                if !CFEqual(parent, window) {
                    guard let expected = edges.first(where: { CFEqual($0.child, parent) }),
                          let next, CFEqual(next, expected.parent) else { return false }
                }
            }
            // Parent/children reads may themselves change a leaf or its stopped
            // value. Corroborate both original controls after the deciding census.
            return controlsCurrent()
        }

        /// The coupled writer already owns its editor. Renew this proof's
        /// complete original source paths/census and stopped controls, never
        /// passive-focus permission, stored values or globally rediscovered rows.
        func permitsCoupledEditorTransportRead(pair: Pair) -> Bool {
            func originalSourceStillHeld() -> Bool {
                guard let role = AXHelpers.getRole(rail, runtime: logic.ax),
                      [kAXGroupRole, kAXListRole, kAXScrollAreaRole].contains(where: { role == $0 as String }),
                      case .read(let currentHeaders) = AXLogicProElements.enumerateTrackHeaderRows(
                    in: rail, runtime: logic.ax) else {
                    lost = true; pair.track.exposure?.end(); return false
                }
                // Feed the actual strict enumeration to the original exposures.
                // A sampled missing acquired header cannot recover on a reread.
                pair.track.exposure?.observeHeaders(currentHeaders)
                retainedTrackBindings?.forEach { $0.exposure?.observeHeaders(currentHeaders) }
                guard Self.same(headers, currentHeaders),
                      owned(checkingStoppedTransport: false) else {
                    lost = true; pair.track.exposure?.end(); return false
                }
                return true
            }
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  CFEqual(pair.track.window, window), CFEqual(pair.strip.window, window),
                  CFEqual(pair.strip.mixer, mixer),
                  pair.track.document.utf8.elementsEqual(document.utf8),
                  pair.strip.document.utf8.elementsEqual(document.utf8),
                  headers.filter({ CFEqual($0, pair.track.header) }).count == 1,
                  strips.filter({ CFEqual($0, pair.strip.strip) }).count == 1,
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  pair.track.runtime.logicProPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: pair.track.runtime), CFEqual(currentApp, app),
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  currentDocument.utf8.elementsEqual(document.utf8), stoppedTransportPathsMatch(),
                  // One fresh uniqueness census still rejects an added competing bar,
                  // including one appearing during the deciding Play/Record reads.
                  let currentBar = AXLogicProElements.getControlBar(in: window, runtime: logic.ax),
                  CFEqual(currentBar, transport.controlBar),
                  // Match the original editor guard's ordering: source custody
                  // is decided after the transport reads, not before them.
                  pair.track.exposure?.isCurrent ?? true,
                  originalSourceStillHeld(),
                  pair.track.exposure?.isCurrent ?? true,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }

        func retainsOriginalHeaderCarrier(_ binding: AXTrackBinding.Binding) -> Bool {
            !lost && CFEqual(binding.window, window)
                && binding.document.utf8.elementsEqual(document.utf8)
                && headers.filter({ CFEqual($0, binding.header) }).count == 1
        }

        /// Role metadata only; current membership still requires the original
        /// header's native bookends and the final passive permission check.
        func originalMixerRoleStillHeld() -> Bool {
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            guard AXLogicProElements.isMixerContainerRole(AXHelpers.getRole(mixer, runtime: logic.ax)) else {
                lost = true
                return false
            }
            return true
        }

        /// Fresh identity metadata for this already-admitted native Mixer only.
        /// It grants no Help, popup, selection, inverse or reference permission.
        func readOriginalMixerIndex(for binding: AXMixerStripBinding.Binding,
                                    ownedPopup: AXUIElement? = nil) -> Int? {
            guard !lost, CFEqual(binding.window, window), CFEqual(binding.mixer, mixer),
                  binding.document.utf8.elementsEqual(document.utf8),
                  strips.filter({ CFEqual($0, binding.strip) }).count == 1,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
            guard AXLogicProElements.isMixerContainerRole(AXHelpers.getRole(mixer, runtime: logic.ax)),
                  let railRole = AXHelpers.getRole(rail, runtime: logic.ax),
                  [kAXGroupRole, kAXListRole, kAXScrollAreaRole, kAXOutlineRole, kAXTableRole]
                    .contains(where: { railRole == $0 as String }),
                  case .read(let currentHeaders) = AXLogicProElements.enumerateTrackHeaderRows(in: rail,
                    runtime: logic.ax) else { lost = true; return nil }
            retainedTrackBindings?.forEach { $0.exposure?.observeHeaders(currentHeaders) }
            guard Self.same(headers, currentHeaders),
                  let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                  Self.same(strips, current.strips), owned(ownedPopup: ownedPopup),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                lost = true; return nil
            }
            let matching = current.strips.indices.filter { CFEqual(current.strips[$0], binding.strip) }
            return matching.count == 1 ? matching[0] : nil
        }

        /// Identity-only sampling of this already-observed native rail. It grants
        /// no Help, selection, popup, inverse or publication permission.
        func readOriginalHeaderPopulation(for binding: AXTrackBinding.Binding,
            requiringPassiveRead: Bool = false, ownedPopup: AXUIElement? = nil,
            observingPopulation: ([AXUIElement]) -> Void) -> [AXUIElement]? {
            guard !requiringPassiveRead || ownedPopup == nil, retainsOriginalHeaderCarrier(binding),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
            guard let role = AXHelpers.getRole(rail, runtime: logic.ax),
                  [kAXGroupRole, kAXListRole, kAXScrollAreaRole, kAXOutlineRole, kAXTableRole]
                    .contains(where: { role == $0 as String }),
                  case .read(let current) = AXLogicProElements.enumerateTrackHeaderRows(in: rail, runtime: logic.ax) else {
                lost = true; binding.exposure?.end(); return nil
            }
            // Consume the actual sample even when later ownership fails. A
            // restored census cannot revive a previously retired binding.
            observingPopulation(current)
            binding.exposure?.observeHeaders(current)
            retainedTrackBindings?.forEach { $0.exposure?.observeHeaders(current) }
            guard Self.same(headers, current),
                  // Only the final original-header identity bookend also
                  // requests passive permission. Close its binding window and
                  // document before the final full ownership/focus checks.
                  !requiringPassiveRead || (binding.currentWindowAndDocumentMatch() && passiveReadBegins()),
                  owned(ownedPopup: ownedPopup), !requiringPassiveRead || passiveReadEnds(),
                  binding.exposure?.isCurrent ?? true,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                lost = true; binding.exposure?.end(); return nil
            }
            return current
        }

        /// Only this explicit association observation uses this request-local focus scope.
        /// It does not itself read Help, and cannot admit an editor, key event or
        /// unheld strip. Requested-strip Help remains under its existing guard.
        func permitsRead() -> Bool {
            // Capability reads do not move focus. Validate complete ownership once,
            // after their bookend, rather than repeating the same population census
            // twice for every caller's guarded AX read. Selection writes also
            // require the final scoped action boundary in select().
            passiveReadBegins() && owned() && passiveReadEnds()
        }

        private func passiveReadBegins() -> Bool {
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  passiveFocusMatches() else { lost = true; return false }
            return true
        }

        private func passiveReadEnds() -> Bool {
            guard Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(final, expectedFocus), selectedChildCustodyMatches() else { lost = true; return false }
            return true
        }

        private func nativeOutputPopupMatches(_ root: AXUIElement, source: AXMixerStripBinding.Binding) -> Bool {
            guard AccessibilityChannel.checkedOutputPopupMenus(in: mixer, runtime: logic.ax)?.isEmpty == true,
                  CFEqual(source.window, window), CFEqual(source.mixer, mixer),
                  source.document.utf8.elementsEqual(document.utf8),
                  strips.filter({ CFEqual($0, source.strip) }).count == 1,
                  AccessibilityChannel.currentOutputMenuAssignment(in: root, runtime: logic.ax) == .noOutput,
                  let popup = AccessibilityChannel.NativeOutputReadPopup.read(
                    physical: source, app: app, pid: pid, runtime: logic),
                  CFEqual(popup.root, root) else { return false }
            return true
        }

        func permitsOwnedPopupRead(_ root: AXUIElement, nativeSource: AXMixerStripBinding.Binding? = nil) -> Bool {
            var stage = "original_selection_root_focus", accepted = false
            defer {
                if nativeSource != nil, !accepted {
                    Log.info("Native output popup read refused at \(stage)", subsystem: "ax")
                }
            }
            func popupMatches() -> Bool {
                guard let menus = AccessibilityChannel.checkedOutputPopupMenus(in: mixer, runtime: logic.ax) else { return false }
                if menus.count == 1 { return CFEqual(menus[0], root) }
                // The neutral output's native popup is not a Mixer AX child.
                // An explicit held source, its checked No Output and the existing
                // native window/hit/reciprocal-wrapper reader must all agree.
                guard menus.isEmpty, let source = nativeSource else { return false }
                return nativeOutputPopupMatches(root, source: source)
            }
            func heldRailChildMatches() -> Bool {
                guard originalRailFocus != nil else { return true }
                guard let expectedSelectedChild, case .observed(let child) = selectedChildRead(),
                      CFEqual(child, expectedSelectedChild),
                      Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex else { lost = true; return false }
                return true
            }
            // This is not a general editor exemption or a new association. Keep
            // the original complete census and exclusive selection; only allow
            // its reciprocal search field or the original app of a checked
            // native neutral popup, in addition to the original passive strip.
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  popupMatches(),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax)
            else {
                Log.info("Input popup ownership refused: original selection/root/focus", subsystem: "ax")
                lost = true; return false
            }
            stage = "original_passive_metadata"
            guard passiveAssociationFocusMatches(expectedFocus), heldRailChildMatches() else {
                Log.info("Input popup ownership refused: original passive association metadata", subsystem: "ax")
                return false
            }
            // Some owned popups keep the original passive strip focused. Its
            // existing full witness also handles native zero insertion metadata;
            // do not classify that qualified strip as an arbitrary editor.
            if CFEqual(focus, expectedFocus) {
                stage = "passive_focus_ownership"
                guard passiveFocusMatches(), owned(ownedPopup: root, nativeOutputSource: nativeSource),
                      Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                      let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      CFEqual(final, expectedFocus), heldRailChildMatches(), passiveAssociationFocusMatches(expectedFocus),
                      let afterChild: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      CFEqual(afterChild, expectedFocus),
                      nativeSource == nil || popupMatches() else { lost = true; return false }
                accepted = true
                return true
            }
            let focusRole = AXHelpers.getRole(focus, runtime: logic.ax)
            stage = "search_field_role_\(focusRole ?? "unread")"
            if nativeSource != nil, focusRole == kAXApplicationRole as String, CFEqual(focus, app) {
                // The native neutral popup can report its original application
                // as focused instead of an AX search field. Only this existing
                // checked native window/root/source proof qualifies that exact CF;
                // an arbitrary application or ordinary menu gains no exemption.
                stage = "native_application_focus"
                guard AccessibilityChannel.checkedOutputPopupMenus(in: mixer, runtime: logic.ax)?.isEmpty == true,
                      popupMatches() else { lost = true; return false }
            } else {
                guard focusRole == kAXTextFieldRole as String,
                      case .success(let rows) = AXHelpers.childrenResult(root, runtime: logic.ax),
                      let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax)
                else { lost = true; return false }
                if CFEqual(parent, root) {
                    stage = "direct_search_field_membership"
                    guard rows.filter({ CFEqual($0, focus) }).count == 1 else { lost = true; return false }
                } else {
                    stage = "nested_search_field_membership"
                    guard rows.filter({ CFEqual($0, parent) }).count == 1,
                          let role = AXHelpers.getRole(parent, runtime: logic.ax),
                          role == kAXGroupRole as String || role == "AXMenuItem",
                          let parentRoot: AXUIElement = AXHelpers.getAttribute(parent, kAXParentAttribute as String, runtime: logic.ax),
                          CFEqual(parentRoot, root),
                          case .success(let children) = AXHelpers.childrenResult(parent, runtime: logic.ax),
                          children.filter({ CFEqual($0, focus) }).count == 1 else { lost = true; return false }
                }
            }
            stage = "search_field_popup_bookend"
            guard popupMatches(),
                  let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(final, focus) else {
                Log.info("Input popup ownership refused: reciprocal focus/root", subsystem: "ax")
                lost = true; return false
            }
            stage = "complete_native_ownership"
            guard owned(ownedPopup: root, nativeOutputSource: nativeSource) else {
                Log.info("Input popup ownership refused: full association custody", subsystem: "ax")
                return false
            }
            stage = "final_native_focus"
            guard
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  heldRailChildMatches(), passiveAssociationFocusMatches(expectedFocus),
                  currentWindowScopeMatches(), logic.logicProPID() == pid,
                  logic.focusedApplicationPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let afterChild: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(afterChild, focus) else { lost = true; return false }
            accepted = true
            return true
        }

        /// Only ReadFocusScope uses this witness. Full exclusive-selection and
        /// population custody still authorize every association action, inverse
        /// and publication. Passive Help never acquires that authority.
        func permitsPassiveFocusRead() -> Bool {
            guard passiveFocusMatches(), owned(checkingAssociation: false) else { lost = true; return false }
            // Fresh final values from this original app, not owned()'s earlier
            // sample. Help still asks the complete proof before every real read.
            let finalApp = AXHelpers.getNonHelpAttributes(app,
                [kAXFocusedUIElementAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String],
                runtime: logic.ax, permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let rawFocus)) = finalApp[0], CFGetTypeID(rawFocus) == AXUIElementGetTypeID(),
                  case .success(.some(let rawMain)) = finalApp[1], CFGetTypeID(rawMain) == AXUIElementGetTypeID(),
                  case .success(.some(let rawWindow)) = finalApp[2], CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
                lost = true; return false
            }
            let final = unsafeBitCast(rawFocus, to: AXUIElement.self)
            let main = unsafeBitCast(rawMain, to: AXUIElement.self)
            let focusedWindow = unsafeBitCast(rawWindow, to: AXUIElement.self)
            guard
                  CFEqual(final, expectedFocus),
                  CFEqual(main, window),
                  CFEqual(focusedWindow, window),
                  case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  document.utf8.elementsEqual(finalDocument.utf8), logic.logicProPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { lost = true; return false }
            return true
        }

        private func passiveFocusMatches() -> Bool {
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(focus, expectedFocus) else { lost = true; return false }
            return passiveAssociationFocusMatches(focus)
        }

        private func passiveAssociationFocusMatches(_ focus: AXUIElement) -> Bool {
            if strips.contains(where: { CFEqual($0, focus) }) { return passiveStripMatches(focus) }
            if let originalHeaderFocus, CFEqual(focus, originalHeaderFocus.focus) {
                // This witness only corroborates the retained numeric name's
                // nonediting physical custody. Full rail/selection/relationship
                // ownership still governs every challenge and its inverse.
                guard originalRailFocus.map({ CFEqual($0, focus) }) == true,
                      expectedSelectedChild != nil, originalHeaderFocus.permits() else { lost = true; return false }
                return true
            }
            guard let originalRailFocus, CFEqual(focus, originalRailFocus), expectedSelectedChild != nil,
                  let role = AXHelpers.getRole(focus, runtime: logic.ax),
                  [kAXGroupRole as String, kAXListRole as String, kAXLayoutAreaRole as String].contains(role),
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: logic.ax) == false,
                  let currentPath = Self.path(rail, to: window, ax: logic.ax), Self.same(railPath, currentPath),
                  currentPath.contains(where: { CFEqual($0, focus) }) else { lost = true; return false }
            let attributes = [kAXValueAttribute, kAXSelectedTextAttribute,
                              kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String]
            let readings = AXHelpers.getNonHelpAttributes(focus, attributes, runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            // Unlike the already-qualified passive strip, a rail container gets
            // no zero-insertion/editor exception and no settable focus cleanup.
            guard readings.allSatisfy({ reading in
                if case .failure(let error) = reading { return error.isDefinitiveAbsence }
                return false
            }) else { lost = true; return false }
            return true
        }

        private func passiveStripMatches(_ focus: AXUIElement) -> Bool {
            guard strips.filter({ CFEqual($0, focus) }).count == 1,
                  AXHelpers.getRole(focus, runtime: logic.ax) == kAXLayoutItemRole as String,
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: logic.ax) == false else { lost = true; return false }
            let attributes = [kAXValueAttribute, kAXSelectedTextAttribute,
                              kAXNumberOfCharactersAttribute, kAXInsertionPointLineNumberAttribute] as [String]
            let readings = AXHelpers.getNonHelpAttributes(focus, attributes, runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            for (attribute, reading) in zip(attributes, readings) {
                switch reading {
                case .failure(let error) where error.isDefinitiveAbsence: continue
                case .success(.some(let value)):
                    guard attribute == kAXNumberOfCharactersAttribute as String || attribute == kAXInsertionPointLineNumberAttribute as String,
                          CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber,
                          number.doubleValue == 0 else { lost = true; return false }
                default: lost = true; return false
                }
            }
            return true
        }

        private enum SelectedChildRead {
            case unavailable, unverified
            case observed(AXUIElement)
        }

        /// A relationship supplied by this exact Mixer owner, not a strip ordinal
        /// or name join. Individual strip AXSelected booleans are not equivalent.
        private func selectedChildRead() -> SelectedChildRead {
            let values = AXHelpers.getNonHelpAttributes(mixer, [kAXSelectedChildrenAttribute as String],
                runtime: logic.ax, permittingRead: {
                    (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                })
            switch values[0] {
            case .failure(let error) where error.isDefinitiveAbsence: return .unavailable
            case .success(.none): return .unavailable
            case .success(.some(let raw)):
                guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return .unverified }
                let array = unsafeDowncast(raw, to: CFArray.self)
                guard CFArrayGetCount(array) == 1 else { return .unverified }
                let element = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFTypeRef.self)
                guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return .unverified }
                let child = unsafeBitCast(element, to: AXUIElement.self)
                // Renew reciprocal membership after the relationship read: a
                // retired child can retain its old parent and CF identity.
                guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                      Self.same(strips, current.strips),
                      current.strips.filter({ CFEqual($0, child) }).count == 1,
                      let parent: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String,
                        runtime: logic.ax), CFEqual(parent, mixer) else { return .unverified }
                return .observed(child)
            default: return .unverified
            }
        }

        private var associationStrip: AXUIElement { expectedSelectedChild ?? expectedFocus }

        private func railMetadataRetainsStripCustody() -> Bool {
            guard originalRailFocus != nil else { return true }
            // R965-RAIL-C001: the new rail metadata reads can retire an old
            // selected child while leaving its old parent/relationship readable.
            guard let current = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax) else { return false }
            return Self.same(strips, current.strips)
        }

        private func selectedChildCustodyMatches() -> Bool {
            guard let expectedSelectedChild else { return true }
            guard case .observed(let child) = selectedChildRead(), CFEqual(child, expectedSelectedChild),
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                    runtime: logic.ax), CFEqual(focus, expectedFocus), passiveAssociationFocusMatches(focus),
                  railMetadataRetainsStripCustody() else { lost = true; return false }
            // One fresh same-app window decision; retain the preceding rail
            // renewal and the following document/PID bookends independently.
            let windows = AXHelpers.getNonHelpAttributes(app,
                [kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [String], runtime: logic.ax,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            guard case .success(.some(let main)) = windows[0], CFGetTypeID(main) == AXUIElementGetTypeID(),
                  case .success(.some(let focusedWindow)) = windows[1], CFGetTypeID(focusedWindow) == AXUIElementGetTypeID(),
                  CFEqual(main, window), CFEqual(focusedWindow, window), currentWindowScopeMatches(),
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  // Window/document reads can themselves move focus. The rail's
                  // retained child is not permission for a later foreign focus.
                  let afterWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                    runtime: logic.ax), CFEqual(afterWindow, expectedFocus) else {
                lost = true; return false
            }
            return true
        }

        /// Layout is a restoration duty, never a replacement peer identity.
        struct MixerViewportGeometry: @unchecked Sendable {
            let window: AXUIElement
            let mixer: AXUIElement
            let headers: [AXUIElement]
            let document: String
            let frames: [CGRect]
            let horizontal: MixerViewportPosition?
            let vertical: MixerViewportPosition?

            func hasSameViewportPosition(as other: Self) -> Bool {
                frames == other.frames && Self.samePosition(horizontal, other.horizontal)
                    && Self.samePosition(vertical, other.vertical)
            }

            static func samePosition(_ lhs: MixerViewportPosition?, _ rhs: MixerViewportPosition?) -> Bool {
                switch (lhs, rhs) {
                case (.none, .none): return true
                case (.some(let lhs), .some(let rhs)):
                    return lhs.sameControlAndLayout(as: rhs) && lhs.value == rhs.value
                default: return false
                }
            }
        }

        struct MixerViewportPosition: @unchecked Sendable {
            let control: AXUIElement
            let owner: AXUIElement
            let value: Double
            let windowFrame: CGRect
            let mixerFrame: CGRect
            let ownerFrame: CGRect
            let controlFrame: CGRect

            func sameControlAndLayout(as other: Self) -> Bool {
                CFEqual(control, other.control) && CFEqual(owner, other.owner)
                    && windowFrame == other.windowFrame && mixerFrame == other.mixerFrame
                    && ownerFrame == other.ownerFrame && controlFrame == other.controlFrame
            }
        }

        private func mixerViewportPosition(horizontal: Bool) -> MixerViewportPosition? {
            // Owned geometry capture and its availability probe use this
            // non-Help sampler. Complete ownership checks bracket axis/value reads and
            // every strip frame as one decision; no observation survives a lost
            // scope. Repeating that full census inside each axis exhausted the
            // native acquisition deadline before the restored report could land.
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let hitTest = logic.ax.elementAtPosition else { return nil }
            func frame(_ element: AXUIElement) -> CGRect? {
                guard let point = AXHelpers.getPosition(element, runtime: logic.ax),
                      let size = AXHelpers.getSize(element, runtime: logic.ax),
                      point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return nil }
                return CGRect(origin: point, size: size)
            }
            guard let windowFrame = frame(window), let mixerFrame = frame(mixer),
                  let owner: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: logic.ax),
                  path.count > 1, CFEqual(owner, path[1]),
                  AXHelpers.getRole(owner, runtime: logic.ax) == kAXGroupRole as String,
                  let ownerFrame = frame(owner) else { return nil }
            let visible = windowFrame.intersection(mixerFrame)
            guard !visible.isNull, visible.width > (horizontal ? 0 : 17),
                  visible.height > (horizontal ? 17 : 0) else { return nil }
            // This point discovers a native object; its coordinates grant no
            // action authority. Logic omits this bar from its owner's children.
            let point = horizontal ? CGPoint(x: visible.midX, y: visible.maxY - 7)
                : CGPoint(x: visible.maxX - 7, y: visible.midY)
            let orientation = horizontal ? kAXHorizontalOrientationValue as String : kAXVerticalOrientationValue as String
            guard case .success(let hit?) = hitTest(app, point), let hitFrame = frame(hit), hitFrame.contains(point),
                  let hitWindow: AXUIElement = AXHelpers.getAttribute(hit, kAXWindowAttribute as String, runtime: logic.ax),
                  CFEqual(hitWindow, window) else { return nil }
            let control: AXUIElement
            if AXHelpers.getRole(hit, runtime: logic.ax) == kAXScrollBarRole as String { control = hit }
            else {
                guard AXHelpers.getRole(hit, runtime: logic.ax) == kAXValueIndicatorRole as String,
                      let parent: AXUIElement = AXHelpers.getAttribute(hit, kAXParentAttribute as String, runtime: logic.ax),
                      case .success(let children) = AXHelpers.childrenResult(parent, runtime: logic.ax),
                      children.filter({ CFEqual($0, hit) }).count == 1 else { return nil }
                control = parent
            }
            guard AXHelpers.getRole(control, runtime: logic.ax) == kAXScrollBarRole as String,
                  AXHelpers.getAttribute(control, kAXOrientationAttribute as String, runtime: logic.ax) as String? == orientation,
                  let parent: AXUIElement = AXHelpers.getAttribute(control, kAXParentAttribute as String, runtime: logic.ax),
                  CFEqual(parent, owner),
                  let controlWindow: AXUIElement = AXHelpers.getAttribute(control, kAXWindowAttribute as String, runtime: logic.ax),
                  CFEqual(controlWindow, window), let controlFrame = frame(control), controlFrame.contains(point)
            else { return nil }
            guard case .success(.some(let raw)) = AXHelpers.getAttributeResult(control, kAXValueAttribute as String,
                    runtime: logic.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                  CFGetTypeID(raw) == CFNumberGetTypeID(), let value = raw as? NSNumber,
                  value.doubleValue.isFinite, (0...1).contains(value.doubleValue),
                  AXHelpers.isAttributeSettable(control, kAXValueAttribute as String, runtime: logic.ax) == true
            else { return nil }
            guard case .success(let decidingHit?) = hitTest(app, point), CFEqual(decidingHit, hit),
                  frame(window) == windowFrame, frame(mixer) == mixerFrame, frame(owner) == ownerFrame,
                  frame(control) == controlFrame,
                  AXHelpers.getRole(control, runtime: logic.ax) == kAXScrollBarRole as String,
                  AXHelpers.getAttribute(control, kAXOrientationAttribute as String, runtime: logic.ax) as String? == orientation,
                  let decidingParent: AXUIElement = AXHelpers.getAttribute(control, kAXParentAttribute as String, runtime: logic.ax),
                  CFEqual(decidingParent, owner), !lost,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
            return .init(control: control, owner: owner, value: value.doubleValue,
                windowFrame: windowFrame, mixerFrame: mixerFrame, ownerFrame: ownerFrame, controlFrame: controlFrame)
        }

        func observedMixerViewportGeometry() -> MixerViewportGeometry? {
            guard permitsRead() else { return nil }
            let horizontalBefore = mixerViewportPosition(horizontal: true)
            let verticalBefore = mixerViewportPosition(horizontal: false)
            var frames: [CGRect] = []
            for strip in strips {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      let point = AXHelpers.getPosition(strip, runtime: logic.ax),
                      let size = AXHelpers.getSize(strip, runtime: logic.ax),
                      point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return nil }
                frames.append(CGRect(origin: point, size: size))
            }
            let horizontalAfter = mixerViewportPosition(horizontal: true)
            let verticalAfter = mixerViewportPosition(horizontal: false)
            guard MixerViewportGeometry.samePosition(horizontalBefore, horizontalAfter),
                  MixerViewportGeometry.samePosition(verticalBefore, verticalAfter) else { return nil }
            guard permitsRead() else { return nil }
            return .init(window: window, mixer: mixer, headers: headers, document: document,
                frames: frames, horizontal: horizontalAfter, vertical: verticalAfter)
        }

        private func mixerViewportIsExpected() -> Bool {
            guard let expectedMixerViewport else { return true }
            guard let current = observedMixerViewportGeometry(),
                  current.hasSameViewportPosition(as: expectedMixerViewport) else {
                lost = true
                return false
            }
            return true
        }

        private func retainMixerViewportAfterOwnedAction() -> Bool {
            guard expectedMixerViewport != nil else { return true }
            guard let current = observedMixerViewportGeometry() else { lost = true; return false }
            expectedMixerViewport = current
            return true
        }

        private func retainMixerViewportAfterOwnedRestore(of control: AXUIElement, value: Double) -> Bool {
            guard let expected = expectedMixerViewport else { return true }
            guard let current = observedMixerViewportGeometry() else { lost = true; return false }
            let horizontal = expected.horizontal.map { CFEqual($0.control, control) } ?? false
            let vertical = expected.vertical.map { CFEqual($0.control, control) } ?? false
            func positionMatches(_ before: MixerViewportPosition?, _ after: MixerViewportPosition?) -> Bool {
                guard let before, let after else {
                    return MixerViewportGeometry.samePosition(before, after)
                }
                if CFEqual(before.control, control) {
                    return before.sameControlAndLayout(as: after) && after.value == value
                }
                return MixerViewportGeometry.samePosition(before, after)
            }
            guard positionMatches(expected.horizontal, current.horizontal),
                  positionMatches(expected.vertical, current.vertical),
                  let before = expected.frames.first, let after = current.frames.first else {
                lost = true; return false
            }
            let dx = after.minX - before.minX, dy = after.minY - before.minY
            guard dx.isFinite, dy.isFinite, (horizontal || dx == 0), (vertical || dy == 0),
                  zip(expected.frames, current.frames).allSatisfy({ old, new in
                      old.size == new.size && new.minX - old.minX == dx && new.minY - old.minY == dy
                  }) else { lost = true; return false }
            // An exposed control can also be found by the native sampler. Only
            // this verified ordinary inverse may advance its native receipt;
            // the other axis and all unrelated positions remain unchanged.
            expectedMixerViewport = current
            return true
        }

        /// The installed Scroll To menu exposes existing physical rows without
        /// selecting a channel, synthesizing keys or changing a routing value.
        /// Success still requires the exact original layout and native census.
        func recoverMixerReadability(
            restoring original: MixerViewportGeometry,
            referenceIsCurrent: @Sendable () async -> Bool,
            stoppingWhen stop: @Sendable () -> Bool
        ) async -> Bool {
            var recoveryStage = "original_geometry", recovered = false
            defer {
                if !recovered { Log.info("Owned Mixer Scroll To recovery refused at \(recoveryStage)", subsystem: "ax") }
            }
            guard CFEqual(original.window, window), CFEqual(original.mixer, mixer),
                  original.document.utf8.elementsEqual(document.utf8),
                  Self.same(original.headers, headers), original.frames.count == strips.count,
                  !stop(), await referenceIsCurrent(), permitsRead() else { return false }
            recoveryStage = "owned_view_discovery"
            guard let parent: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: logic.ax),
                  let parentPath = Self.path(parent, to: window, ax: logic.ax),
                  case .success(let buttons) = AXHelpers.censusDescendantResult(of: parent,
                    role: kAXMenuButtonRole as String, maxDepth: 32, runtime: logic.ax,
                    requiresCompleteTraversal: true,
                    permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil })
            else { return false }
            var views: [AXUIElement] = []
            for button in buttons.matches {
                switch AXLocalePolicy.elementMatchesResult(button, AXLocalePolicy.viewMenuBar, runtime: logic.ax) {
                case .success(true): views.append(button)
                case .success(false): break
                case .failure: return false
                }
            }
            guard views.count == 1, let view = views.first,
                  let viewPath = Self.path(view, to: window, ax: logic.ax),
                  viewPath.contains(where: { CFEqual($0, parent) }), permitsRead() else { return false }
            func scopeHeld() -> Bool {
                guard !stop(), permitsRead(),
                      let currentParent: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: logic.ax),
                      CFEqual(currentParent, parent),
                      let currentParentPath = Self.path(parent, to: window, ax: logic.ax),
                      Self.same(currentParentPath, parentPath),
                      let currentViewPath = Self.path(view, to: window, ax: logic.ax),
                      Self.same(currentViewPath, viewPath) else { return false }
                // Path reads can themselves coincide with scope loss. Renew
                // native custody after those deciding reads, not before them.
                return permitsRead()
            }
            func childMenus(_ owner: AXUIElement) -> [AXUIElement]? {
                guard case .success(let children) = AXHelpers.childrenResult(owner, runtime: logic.ax) else {
                    Log.info("Owned Mixer menu children unreadable", subsystem: "ax"); return nil
                }
                var menus: [AXUIElement] = []
                for child in children {
                    guard let role = AXHelpers.getRole(child, runtime: logic.ax) else {
                        Log.info("Owned Mixer menu child role unreadable", subsystem: "ax"); return nil
                    }
                    if role == kAXMenuRole as String {
                        let parentRead: Result<AXUIElement?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                            child, kAXParentAttribute as String, runtime: logic.ax)
                        // Logic's Mixer View root is exposed in View's children,
                        // but its native parent is the exact original controls
                        // group two edges above View. Only this measured root
                        // shape qualifies; submenus retain their direct parent.
                        let retainedViewContainer: Bool
                        if case .success(.some(let reciprocal)) = parentRead,
                           CFEqual(owner, view), viewPath.count > 3,
                           CFEqual(reciprocal, viewPath[2]),
                           AXHelpers.getRole(reciprocal, runtime: logic.ax) == kAXGroupRole as String {
                            retainedViewContainer = true
                        } else { retainedViewContainer = false }
                        guard case .success(.some(let reciprocal)) = parentRead,
                              CFEqual(reciprocal, owner) || retainedViewContainer else {
                            switch parentRead {
                            case .success(.some(let actual)):
                                Log.info("Owned Mixer menu parent differs: role=\(AXHelpers.getRole(actual, runtime: logic.ax) ?? "unread"), original_app=\(CFEqual(actual, app)), mixer_parent=\(CFEqual(actual, parent)), view_ancestor_depth=\(viewPath.firstIndex(where: { CFEqual($0, actual) }) ?? -1)", subsystem: "ax")
                            case .success(.none): Log.info("Owned Mixer menu parent absent", subsystem: "ax")
                            case .failure(let error): Log.info("Owned Mixer menu parent failed AX:\(error.raw)", subsystem: "ax")
                            }
                            return nil
                        }
                        menus.append(child)
                    }
                }
                return menus
            }
            let timing = AccessibilityChannel.OutputAssignmentTiming.live
            func uniqueItem(in menu: AXUIElement, matching labels: AXLocalePolicy.LabelSet) -> AXUIElement? {
                guard case .success(let children) = AXHelpers.childrenResult(menu, runtime: logic.ax) else { return nil }
                var matches: [AXUIElement] = []
                for child in children {
                    guard AXHelpers.getRole(child, runtime: logic.ax) == kAXMenuItemRole as String,
                          let owner: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String, runtime: logic.ax),
                          CFEqual(owner, menu) else { return nil }
                    switch AXLocalePolicy.elementMatchesResult(child, labels, runtime: logic.ax) {
                    case .success(true): matches.append(child)
                    case .success(false): break
                    case .failure: return nil
                    }
                }
                return matches.count == 1 ? matches.first : nil
            }
            func cancelOwnedRoot(_ root: AXUIElement) async {
                guard scopeHeld(), let roots = childMenus(view), roots.count == 1,
                      roots.first.map({ CFEqual($0, root) }) == true,
                      logic.ax.actionNames(root).contains(kAXCancelAction as String), scopeHeld(),
                      await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return }
                _ = AXHelpers.performAction(root, kAXCancelAction as String, runtime: logic.ax)
                if childMenus(view)?.isEmpty == true, scopeHeld(),
                   let final = observedMixerViewportGeometry(), final.frames == original.frames,
                   let current = currentViewport(), Self.sameViewport(current, viewport),
                   await referenceIsCurrent() { effects.restoration = "restored" }
            }
            for (name, labels) in [("output", AXLocalePolicy.mixerScrollToOutputsMenuItem), ("audio", AXLocalePolicy.mixerTypeFilterAudio)] {
                recoveryStage = name + "_view_action"
                guard childMenus(view)?.isEmpty == true,
                      AXHelpers.getAttribute(view, kAXEnabledAttribute as String, runtime: logic.ax) as Bool? == true,
                      logic.ax.actionNames(view).contains(kAXPressAction as String), scopeHeld(),
                      await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                effects.navigationPerformed = true; effects.restoration = "not_restored"
                effects.attempted.append("mixer_scroll_to_" + name)
                let opened = AXHelpers.performAction(view, kAXPressAction as String, runtime: logic.ax)
                recoveryStage = name + "_owned_root"
                var roots: [AXUIElement]?
                let openDeadline = ContinuousClock.now.advanced(by: .milliseconds(timing.popupOpenTimeoutMs))
                repeat {
                    guard scopeHeld() else { recoveryStage = name + "_root_scope"; return false }
                    roots = childMenus(view)
                    if roots?.count == 1 { break }
                    guard roots?.isEmpty == true else { recoveryStage = name + "_root_ownership"; return false }
                    guard ContinuousClock.now < openDeadline else { recoveryStage = name + "_root_timeout"; return false }
                    do { try await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) } catch { return false }
                } while true
                guard let roots, roots.count == 1, let root = roots.first else { return false }
                // A failed AX acknowledgement does not prove no effect. Only
                // this original View's uniquely owned reciprocal root may close.
                guard opened else { await cancelOwnedRoot(root); return false }
                recoveryStage = name + "_scoped_leaf"
                guard let scrollTo = uniqueItem(in: root, matching: AXLocalePolicy.mixerScrollToMenuItem),
                      let submenus = childMenus(scrollTo), submenus.count == 1, let submenu = submenus.first,
                      let leaf = uniqueItem(in: submenu, matching: labels),
                      AXHelpers.getAttribute(leaf, kAXEnabledAttribute as String, runtime: logic.ax) as Bool? == true,
                      logic.ax.actionNames(leaf).contains(kAXPressAction as String),
                      let currentRoots = childMenus(view), currentRoots.count == 1,
                      currentRoots.first.map({ CFEqual($0, root) }) == true,
                      scopeHeld(),
                      await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                    await cancelOwnedRoot(root); return false
                }
                guard AXHelpers.performAction(leaf, kAXPressAction as String, runtime: logic.ax) else {
                    await cancelOwnedRoot(root); return false
                }
                recoveryStage = name + "_closed_root"
                let closeDeadline = ContinuousClock.now.advanced(by: .milliseconds(timing.popupCloseTimeoutMs))
                repeat {
                    guard scopeHeld() else { return false }
                    if childMenus(view)?.isEmpty == true { break }
                    guard ContinuousClock.now < closeDeadline else { await cancelOwnedRoot(root); return false }
                    do { try await Task.sleep(for: .milliseconds(timing.pollIntervalMs)) } catch { return false }
                } while true
                guard childMenus(view)?.isEmpty == true, scopeHeld() else { return false }
                effects.changed.append("mixer_scroll_to_" + name)
            }
            recoveryStage = "final_geometry_read"
            guard var final = observedMixerViewportGeometry() else { return false }
            // Scroll To may also reset the omitted native vertical bar. Restore
            // only sampled original controls; coordinates never drive an action.
            // Restore Y first so an owned two-axis displacement can then restore X.
            for horizontal in [false, true] {
                let beforePosition = horizontal ? original.horizontal : original.vertical
                let afterPosition = horizontal ? final.horizontal : final.vertical
                guard let before = beforePosition, let after = afterPosition,
                      before.value != after.value else { continue }
                recoveryStage = horizontal ? "horizontal_viewport_inverse" : "vertical_viewport_inverse"
                guard before.sameControlAndLayout(as: after),
                      let first = original.frames.first, let currentFirst = final.frames.first else { return false }
                let deltaX = currentFirst.minX - first.minX, deltaY = currentFirst.minY - first.minY
                if !horizontal, deltaX != 0 {
                    guard let originalHorizontal = original.horizontal, let currentHorizontal = final.horizontal,
                          originalHorizontal.sameControlAndLayout(as: currentHorizontal),
                          originalHorizontal.value != currentHorizontal.value else { return false }
                }
                guard deltaX.isFinite, deltaY.isFinite, (!horizontal || deltaY == 0),
                      zip(original.frames, final.frames).allSatisfy({ a, b in
                    a.size == b.size && b.minX - a.minX == deltaX && b.minY - a.minY == deltaY
                }), await referenceIsCurrent(),
                      let deciding = observedMixerViewportGeometry(), deciding.hasSameViewportPosition(as: final),
                      childMenus(view)?.isEmpty == true, scopeHeld(),
                      !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                let effect = horizontal ? "mixer_horizontal_viewport" : "mixer_vertical_viewport"
                effects.attempted.append(effect)
                let accepted = AXHelpers.setAttribute(before.control, kAXValueAttribute as String,
                    NSNumber(value: before.value), runtime: logic.ax)
                guard let restored = observedMixerViewportGeometry(),
                      let position = horizontal ? restored.horizontal : restored.vertical,
                      accepted, position.sameControlAndLayout(as: before), position.value == before.value,
                      MixerViewportGeometry.samePosition(horizontal ? restored.vertical : restored.horizontal,
                          horizontal ? final.vertical : final.horizontal),
                      zip(zip(original.frames, final.frames), restored.frames).allSatisfy({ prior, current in
                          let (baseline, previous) = prior
                          return current.size == previous.size && (horizontal
                              ? current.minX == baseline.minX && current.minY == previous.minY
                              : current.minY == baseline.minY && current.minX == previous.minX)
                      }), scopeHeld() else { return false }
                effects.changed.append(effect)
                final = restored
            }
            recoveryStage = "final_strip_frames"
            guard final.hasSameViewportPosition(as: original) else {
                let changed = zip(original.frames, final.frames).enumerated().compactMap { index, pair in
                    pair.0 == pair.1 ? nil : "\(index):\(pair.0)->\(pair.1)"
                }.joined(separator: ";")
                Log.info("Owned Mixer recovery layout differs: \(changed)", subsystem: "ax")
                return false
            }
            recoveryStage = "final_viewport_read"
            guard let current = currentViewport() else { return false }
            recoveryStage = "final_expected_viewport"
            guard Self.sameViewport(current, expectedViewport) else { return false }
            recoveryStage = "final_original_viewport"
            guard Self.sameViewport(current, viewport) else { return false }
            recoveryStage = "final_reference"
            guard await referenceIsCurrent() else { return false }
            recoveryStage = "final_native_custody"
            guard permitsRead() else { return false }
            effects.restoration = "restored"
            recovered = true
            return true
        }

        private func select(_ index: Int, referenceIsCurrent: @Sendable () async -> Bool,
                            stoppingWhen stop: @Sendable () -> Bool,
                            requiresNonStackHeader: Bool = false) async -> Bool {
            guard !lost, !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  AXHelpers.isAttributeSettable(rail, kAXSelectedChildrenAttribute as String,
                runtime: logic.ax) == true,
                  let beforeViewport = currentViewport(), Self.sameViewport(beforeViewport, expectedViewport),
                  permitsRead(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  owned(), selectedChildCustodyMatches(),
                  !requiresNonStackHeader || (AXValueExtractors.extractTrackStackState(from: headers[index],
                    runtime: logic.ax).isStackHeader == false && owned() && selectedChildCustodyMatches()) else { return false }
            // The selected-child read is a new deciding read. Renew the request
            // reference after it, then check the pure lease without another AX
            // read before the selection write.
            if expectedSelectedChild != nil {
                guard await referenceIsCurrent(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            }
            // A stop callback may itself read or move focus. Run it before the
            // final native proof, never after the selected-child proof alone.
            if expectedMixerViewport != nil {
                guard !stop(), await referenceIsCurrent(), mixerViewportIsExpected() else { return false }
            }
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            // R965-ASSOC-C001: the deciding focus/selection reads in permitsRead
            // can themselves coincide with a document/window switch. Revalidate
            // scoped ownership AFTER them, with no further AX read before write.
            effects.navigationPerformed = true; effects.restoration = "not_restored"
            if !effects.attempted.contains("track_selection") { effects.attempted.append("track_selection") }
            let precedingFocus = expectedFocus
            let precedingSelectedChild = expectedSelectedChild
            let accepted = AXHelpers.setAttribute(rail, kAXSelectedChildrenAttribute as String, [headers[index]] as CFArray, runtime: logic.ax)
            for attempt in 0..<4 {
                guard owned() else { return false }
                let selectionChanged = Self.exclusiveIndex(headers, ax: logic.ax) == index
                if selectionChanged, !effects.changed.contains("track_selection") {
                    effects.changed.append("track_selection")
                }
                guard let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      strips.filter({ CFEqual($0, focus) }).count == 1
                        || originalRailFocus.map({ CFEqual($0, focus) }) == true else {
                    lost = true; return false
                }
                if selectionChanged {
                    var selectedChild: AXUIElement?
                    if precedingSelectedChild != nil {
                        guard case .observed(let child) = selectedChildRead() else { lost = true; return false }
                        selectedChild = child
                    } else { selectedChild = nil }
                    // Selection and its Mixer relationship can settle on
                    // different host turns. Do not freeze the old strip as a pair.
                    // Only original held strips are admitted by the guard above.
                    let awaitingOwnFocus: Bool
                    if let selectedChild, let precedingSelectedChild, let originalSelectedChild {
                        awaitingOwnFocus = index == originalIndex
                            ? !CFEqual(selectedChild, originalSelectedChild) : CFEqual(selectedChild, precedingSelectedChild)
                    } else {
                        awaitingOwnFocus = index == originalIndex
                            ? !CFEqual(focus, originalFocus) : CFEqual(focus, precedingFocus)
                    }
                    if awaitingOwnFocus && attempt < 3 {
                        do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
                        continue
                    }
                    guard let afterViewport = currentViewport() else { return false }
                    // The viewport read may coincide with our selected child's
                    // delayed focus landing. Admit only that exact transition,
                    // not another held strip or an unrelated editor. Unchanged
                    // preceding focus remains valid when Logic retains it.
                    guard let settledFocus: AXUIElement = AXHelpers.getAttribute(app,
                        kAXFocusedUIElementAttribute as String, runtime: logic.ax) else {
                        lost = true; return false
                    }
                    if !CFEqual(settledFocus, focus) {
                        guard CFEqual(focus, precedingFocus),
                              let precedingSelectedChild,
                              case .observed(let currentSelectedChild) = selectedChildRead(),
                              !CFEqual(currentSelectedChild, precedingSelectedChild),
                              CFEqual(settledFocus, currentSelectedChild) else {
                            lost = true; return false
                        }
                        selectedChild = currentSelectedChild
                    } else if let priorChild = selectedChild, let precedingSelectedChild,
                              CFEqual(priorChild, precedingSelectedChild),
                              !CFEqual(settledFocus, precedingFocus) {
                        // Focus may settle before its selected-child relationship.
                        // Renew a child that lands during the viewport read only
                        // onto that already observed focus. Retaining the preceding
                        // child is still not a new association witness.
                        guard case .observed(let currentSelectedChild) = selectedChildRead(),
                              CFEqual(currentSelectedChild, priorChild)
                                || CFEqual(currentSelectedChild, settledFocus) else {
                            lost = true; return false
                        }
                        selectedChild = currentSelectedChild
                    }
                    // Logic can select our exact held header while retaining its
                    // original Mixer relationship. Retain that owned transition
                    // for inverse cleanup; observe() still requires a different
                    // challenge strip before publishing any association pair.
                    expectedIndex = index; expectedFocus = settledFocus
                    expectedSelectedChild = selectedChild
                    expectedViewport = afterViewport
                    guard retainMixerViewportAfterOwnedAction() else { return false }
                    return permitsRead() && !stop() && accepted
                }
                if attempt < 3 {
                    do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
                }
            }
            return false
        }

        /// UI focus may enter only the already observed original physical pair,
        /// never a strip chosen by label, ordinal or an initial selected flag.
        func permitsOriginalMixerFocusTarget(_ pair: Pair) -> Bool {
            guard let retainedTrackBindings, originalHeaderFocus != nil,
                  expectedIndex == originalIndex, pair.track.matches(retainedTrackBindings[originalIndex]),
                  CFEqual(pair.strip.window, window), CFEqual(pair.strip.mixer, mixer),
                  pair.strip.document.utf8.elementsEqual(document.utf8),
                  CFEqual(associationStrip, pair.strip.strip), permitsRead(),
                  passiveStripMatches(pair.strip.strip), owned(), selectedChildCustodyMatches(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            return true
        }

        /// Reverse only scroll/own-zoom values sampled immediately after our held-rail selections.
        /// A newer viewport, replacement control/path or scope loss ends cleanup authority.
        private func restoreViewport(referenceIsCurrent: @Sendable () async -> Bool,
                                     stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard let current = currentViewport(), Self.sameViewport(current, expectedViewport) else { return false }
            for index in viewport.indices where viewport[index].1 != expectedViewport[index].1 {
                let (control, original, _) = viewport[index]
                guard !stop(), await referenceIsCurrent(), permitsRead(),
                      (0...1).contains(original),
                      AXHelpers.isAttributeSettable(control, kAXValueAttribute as String, runtime: logic.ax) == true,
                      let decidingViewport = currentViewport(), Self.sameViewport(decidingViewport, expectedViewport),
                      permitsRead(), owned(), await referenceIsCurrent(), !stop(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                // R965-VIEW-C001: the deciding AX reads can retire the request's
                // reference without changing physical custody. Renew it last,
                // then require pure acquisition/cancellation authority before writing.
                if expectedMixerViewport != nil {
                    guard !stop(), await referenceIsCurrent(), mixerViewportIsExpected(),
                          (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
                }
                if !effects.attempted.contains("viewport") { effects.attempted.append("viewport") }
                let accepted = AXHelpers.setAttribute(control, kAXValueAttribute as String,
                    NSNumber(value: original), runtime: logic.ax)
                guard let after = currentViewport() else { return false }
                if after[index].1 == original, !effects.changed.contains("viewport") { effects.changed.append("viewport") }
                guard accepted, after[index].1 == original,
                      zip(after.indices, after).allSatisfy({ entry in
                          entry.0 == index || entry.1.1 == expectedViewport[entry.0].1
                      }), permitsRead(), owned(), !stop() else { return false }
                expectedViewport = after
                guard retainMixerViewportAfterOwnedRestore(of: control, value: original) else { return false }
            }
            return Self.sameViewport(expectedViewport, viewport)
        }

        /// Cleanup of an original passive focus is not an association challenge.
        /// Logic may restore the held selection while retaining the prior strip's
        /// focus; never publish a pair manufactured by this explicit inverse.
        private func restoreOriginalFocus(referenceIsCurrent: @Sendable () async -> Bool,
                                          stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard expectedIndex == originalIndex, !CFEqual(expectedFocus, originalFocus),
                  !stop(), await referenceIsCurrent(), passiveStripMatches(originalFocus),
                  let originalPath = Self.path(originalFocus, to: window, ax: logic.ax),
                  Self.same(originalPath, [originalFocus] + path),
                  AXHelpers.isAttributeSettable(originalFocus, kAXFocusedAttribute as String, runtime: logic.ax) == true,
                  let beforeViewport = currentViewport(), Self.sameViewport(beforeViewport, expectedViewport),
                  permitsRead(), !stop(), owned(),
                  // The final census may retire a reference or move focus while
                  // leaving document, population and transport intact. Renew the
                  // deciding focus, then scope and reference, after that census.
                  let decidingFocus: AXUIElement = AXHelpers.getAttribute(app,
                    kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(decidingFocus, expectedFocus),
                  Self.exclusiveIndex(headers, ax: logic.ax) == originalIndex,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window), currentWindowScopeMatches(),
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  await referenceIsCurrent(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            if expectedMixerViewport != nil {
                guard !stop(), await referenceIsCurrent(), mixerViewportIsExpected() else { return false }
            }
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            if !effects.attempted.contains("keyboard_focus_restoration") {
                effects.attempted.append("keyboard_focus_restoration")
            }
            guard AXHelpers.setAttribute(originalFocus, kAXFocusedAttribute as String,
                NSNumber(value: true), runtime: logic.ax) else { return false }
            let precedingFocus = expectedFocus
            for attempt in 0..<3 {
                // As in select(), renew our observed focus before consulting
                // the passive editing guard: it still holds the preceding focus
                // until then. owned() preserves cancellation, deadline, document,
                // transport and complete population custody during this inverse.
                guard owned(),
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                        runtime: logic.ax) else { return false }
                if CFEqual(focus, originalFocus) {
                    guard let afterViewport = currentViewport() else { return false }
                    expectedFocus = originalFocus; expectedViewport = afterViewport
                    guard retainMixerViewportAfterOwnedAction() else { return false }
                    guard permitsRead(), !stop(), await referenceIsCurrent() else { return false }
                    if !effects.changed.contains("keyboard_focus_restoration") {
                        effects.changed.append("keyboard_focus_restoration")
                    }
                    return true
                }
                guard CFEqual(focus, precedingFocus), attempt < 2 else { lost = true; return false }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
            }
            return false
        }

        /// Match the original strip focus or the original passive rail's exact
        /// selected child. These retained facts do not replace permitsRead().
        func hasOriginalSourceFocus(_ source: AXMixerStripBinding.Binding) -> Bool {
            guard !lost, expectedIndex == originalIndex, CFEqual(expectedFocus, originalFocus),
                  CFEqual(source.window, window), CFEqual(source.mixer, mixer),
                  source.document.utf8.elementsEqual(document.utf8),
                  strips.filter({ CFEqual($0, source.strip) }).count == 1 else { return false }
            if CFEqual(originalFocus, source.strip) { return true }
            guard let originalRailFocus, CFEqual(originalRailFocus, originalFocus),
                  originalSelectedChild.map({ CFEqual($0, source.strip) }) == true,
                  expectedSelectedChild.map({ CFEqual($0, source.strip) }) == true else { return false }
            return true
        }

        /// Used only by the post-verified owned-name continuation. The new
        /// owner has kept the old native baseline; these are the existing
        /// guarded inverses, not an assumed ACK or arbitrary focus adoption.
        func restoreCommittedFocus(source: AXMixerStripBinding.Binding, expectedName: String,
                                   transport focusTransport: ExactTrackNameAdapter.NameFocusTransport?,
                                   preservingFootprint: @Sendable () -> Bool,
                                   referenceIsCurrent: @Sendable () async -> Bool,
                                   stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard !stop(), await referenceIsCurrent(), permitsRead() else { return false }
            if !CFEqual(expectedFocus, originalFocus) {
                guard let focusTransport, CFEqual(source.strip, originalFocus), CFEqual(source.mixer, mixer),
                      CFEqual(source.window, window), source.document.utf8.elementsEqual(document.utf8),
                      expectedSelectedChild.map({ CFEqual($0, originalFocus) }) == true,
                      passiveStripMatches(originalFocus),
                      let originalPath = Self.path(originalFocus, to: window, ax: logic.ax),
                      Self.same(originalPath, [originalFocus] + path),
                      preservingFootprint(), !stop(), await referenceIsCurrent() else { return false }
                effects.attempted.append("keyboard_focus_restoration")
                let precedingFocus = expectedFocus
                guard AccessibilityChannel.clickOriginalMixerNamePlate(source: source,
                    expectedName: expectedName, expectedFocus: precedingFocus, runtime: logic,
                    transport: focusTransport, permittingClick: {
                        !stop() && self.permitsRead() && preservingFootprint()
                            && (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                    }) else { return false }
                // Same bounded landing observation as the existing inverse;
                // one click only, never another setter/action on a late landing.
                for attempt in 0..<3 {
                    guard owned(), let focus: AXUIElement = AXHelpers.getAttribute(app,
                        kAXFocusedUIElementAttribute as String, runtime: logic.ax) else { return false }
                    if CFEqual(focus, originalFocus) {
                        guard let afterViewport = currentViewport() else { return false }
                        expectedFocus = originalFocus; expectedViewport = afterViewport
                        guard permitsRead(), preservingFootprint(), !stop(), await referenceIsCurrent() else { return false }
                        effects.changed.append("keyboard_focus_restoration")
                        break
                    }
                    guard CFEqual(focus, precedingFocus), attempt < 2 else { lost = true; return false }
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
                }
            }
            guard await restoreViewport(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop),
                  CFEqual(expectedFocus, originalFocus), permitsRead(), !stop(), await referenceIsCurrent() else { return false }
            effects.restoration = "restored"
            return true
        }

        func observe(referenceIsCurrent: @Sendable () async -> Bool,
                     stoppingWhen stop: @Sendable () -> Bool,
                     allHeldHeaders: Bool = false,
                     narrowChallengeHeaders: [AXTrackBinding.Binding] = [],
                     prioritizingHeader: AXTrackBinding.Binding? = nil,
                     observingPeerHeaders: [AXTrackBinding.Binding]? = nil,
                     observingPeerStrips: [AXMixerStripBinding.Binding]? = nil,
                     populationReadDuration: Duration = .zero,
                     collectionNow: @Sendable () -> ContinuousClock.Instant = { .now }) async -> [Pair] {
            var preferredIndex: Int?
            if let prioritizingHeader {
                guard allHeldHeaders, CFEqual(prioritizingHeader.window, window),
                      prioritizingHeader.document.utf8.elementsEqual(document.utf8),
                      prioritizingHeader.exposure?.hasEnded != true,
                      headers.filter({ CFEqual($0, prioritizingHeader.header) }).count == 1 else {
                    effects.reason = "association_selection_unverified"; return []
                }
                preferredIndex = headers.firstIndex { CFEqual($0, prioritizingHeader.header) }
            }
            var eligibleChallenges = headers.indices.filter { index in
                guard index != originalIndex else { return false }
                return allHeldHeaders || narrowChallengeHeaders.filter { binding in
                    CFEqual(binding.header, headers[index]) && CFEqual(binding.window, window)
                        && binding.document.utf8.elementsEqual(document.utf8)
                        && binding.exposure?.hasEnded != true
                }.count == 1
            }
            if let observingPeerHeaders {
                let requested = Set(headers.indices.filter { index in
                    observingPeerHeaders.contains { peer in
                        CFEqual(peer.window, window) && peer.document.utf8.elementsEqual(document.utf8)
                            && peer.exposure?.hasEnded != true && CFEqual(peer.header, headers[index])
                            && headers.filter({ CFEqual($0, peer.header) }).count == 1
                    }
                })
                eligibleChallenges = eligibleChallenges.filter { requested.contains($0) }
                    + eligibleChallenges.filter { !requested.contains($0) }
            }
            if let preferredIndex, preferredIndex != originalIndex {
                eligibleChallenges.removeAll { $0 == preferredIndex }
                eligibleChallenges.insert(preferredIndex, at: 0)
            }
            let firstChallenge = eligibleChallenges.first
            guard let firstChallenge else {
                effects.reason = "association_selection_unverified"; return []
            }
            guard await referenceIsCurrent(), permitsRead(), !stop(), mixerViewportIsExpected() else { return [] }
            // The ordinary viewport census already owns exposed scrollbars.
            // Add the omitted native Mixer axes only when positively discovered;
            // their presence requires a complete, stable geometry baseline.
            let horizontal = mixerViewportPosition(horizontal: true)
            let vertical = mixerViewportPosition(horizontal: false)
            let originalMixerViewport: MixerViewportGeometry?
            if horizontal != nil || vertical != nil {
                guard let geometry = observedMixerViewportGeometry(),
                      MixerViewportGeometry.samePosition(horizontal, geometry.horizontal),
                      MixerViewportGeometry.samePosition(vertical, geometry.vertical) else {
                    effects.reason = "association_restoration_unverified"
                    return []
                }
                originalMixerViewport = geometry
                expectedMixerViewport = geometry
            } else {
                guard expectedMixerViewport == nil, permitsRead() else { lost = true; return [] }
                originalMixerViewport = nil
            }
            switch selectedChildRead() {
            case .observed(let child):
                originalSelectedChild = child; expectedSelectedChild = child
                guard permitsRead(), !stop() else { return [] }
            case .unavailable: break
            case .unverified:
                effects.reason = "association_selection_unverified"; return []
            }
            let originalAssociationStrip = originalSelectedChild ?? originalFocus
            // The retained source must not fall behind optional peer discovery
            // when the existing collection reserve ends. Priority changes only
            // order: every challenge retains full census and inverse custody.
            let challenges = allHeldHeaders ? eligibleChallenges : [firstChallenge]
            // Whole-held pairs are optional partial observations. Do not spend
            // the entire owned deadline on more challenges: the original inverse
            // and final fresh population still need that same deadline. This is
            // not an extension or a guarantee that a busy host will restore.
            let collectionEnd: ContinuousClock.Instant?
            if allHeldHeaders, let deadline = OperationTraceContext.current?.deadline {
                let start = collectionNow()
                let remaining = start.duration(to: deadline)
                // Use the initial fresh population's observed cost, not just a
                // fraction of the deadline. With insufficient recheck time,
                // preserve the initial snapshot without starting UI navigation.
                let reserve = max(.zero, populationReadDuration) * 2
                guard remaining > reserve else { return [] }
                // An actual measured reserve already bounds the available
                // work. Keep the conservative fraction only without a sample;
                // do not truncate otherwise qualified original-header pairs.
                collectionEnd = start.advanced(by: reserve > .zero ? remaining - reserve : remaining / 4)
            } else { collectionEnd = nil }
            var observed: [(Int, AXUIElement)] = []
            func requestedPeersWereObserved() -> Bool {
                guard allHeldHeaders, !observed.isEmpty,
                      observingPeerHeaders != nil || observingPeerStrips != nil else { return false }
                if let preferredIndex, preferredIndex != originalIndex,
                   !observed.contains(where: { $0.0 == preferredIndex }) { return false }
                let headersObserved = observingPeerHeaders?.allSatisfy { peer in
                    guard CFEqual(peer.window, window),
                          peer.document.utf8.elementsEqual(document.utf8), peer.exposure?.hasEnded != true,
                          headers.filter({ CFEqual($0, peer.header) }).count == 1,
                          let index = headers.firstIndex(where: { CFEqual($0, peer.header) }) else { return false }
                    // The original relationship still needs its actual changed-
                    // strip return below. This only ends optional discovery;
                    // no pair survives a failed full-custody inverse or viewport.
                    return index == originalIndex || observed.contains(where: { $0.0 == index })
                } ?? true
                guard headersObserved else { return false }
                return observingPeerStrips?.allSatisfy { peer in
                    guard CFEqual(peer.window, window), CFEqual(peer.mixer, mixer),
                          peer.document.utf8.elementsEqual(document.utf8),
                          strips.filter({ CFEqual($0, peer.strip) }).count == 1 else { return false }
                    // Captured physical receivers are expected candidates only.
                    // Their actual singleton header relationships must have
                    // been observed; the original still needs its inverse below.
                    return CFEqual(peer.strip, originalAssociationStrip)
                        || observed.filter({ CFEqual($0.1, peer.strip) }).count == 1
                } ?? true
            }
            var restored = true
            var selectionsVerified = true
            // An initially selected header and passive focus are not a pair
            // witness. Whole-held collection needs its own changed-strip return
            // to that header, just as it does for every challenged header.
            var originalPairVerified = !allHeldHeaders && originalRailFocus == nil
            func selectedChildRestored() -> Bool {
                guard let originalSelectedChild, let expectedSelectedChild else { return true }
                return CFEqual(originalSelectedChild, expectedSelectedChild)
            }
            for challenge in challenges {
                if let collectionEnd, collectionNow() >= collectionEnd { break }
                // select() renews selection/focus and the complete scoped
                // ownership after its deciding viewport reads and immediately
                // before the action. Do not repeat that census here.
                guard await referenceIsCurrent(), !stop() else { restored = false; break }
                let precedingStrip = associationStrip
                let advanced = await select(challenge, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop,
                    requiresNonStackHeader: !allHeldHeaders)
                let challengeStrip = associationStrip
                if allHeldHeaders {
                    guard advanced else { selectionsVerified = false; break }
                    if !CFEqual(challengeStrip, precedingStrip) {
                        // The exclusive header and a changed Mixer relationship
                        // are renewed together under full held census
                        // custody. Intermediate proofs need no inverse action.
                        observed.append((challenge, challengeStrip))
                    } else if !CFEqual(precedingStrip, originalAssociationStrip) {
                        // An unchanged relationship is not alias evidence. Challenge that
                        // header again from the original strip; if it still does
                        // not change strip, leave just this association unknown.
                        guard await referenceIsCurrent(),
                              await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) else {
                            selectionsVerified = false; break
                        }
                        if !CFEqual(associationStrip, originalAssociationStrip) {
                            // The original selection can retain a still-owned
                            // preceding strip. That is no fresh baseline or pair
                            // proof, but it does not contradict earlier pairs.
                            originalPairVerified = false
                            continue
                        }
                        originalPairVerified = true
                        guard await referenceIsCurrent(),
                              await select(challenge, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) else {
                            selectionsVerified = false; break
                        }
                        if !CFEqual(associationStrip, originalAssociationStrip) { observed.append((challenge, associationStrip)) }
                    }
                    if requestedPeersWereObserved() { break }
                    continue
                }
                if expectedIndex == originalIndex {
                    restored = permitsRead() && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else if await referenceIsCurrent() {
                    restored = await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                        && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else { restored = false }
                if !restored, !lost, expectedIndex == originalIndex, selectedChildRestored() {
                    // As in whole-held collection, restore only our original
                    // passive focus; the inverse itself is never a pair witness.
                    if originalSelectedChild == nil { originalPairVerified = false }
                    restored = await restoreOriginalFocus(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                        && selectedChildRestored()
                }
                // Each proof starts at the same original selection/focus. A
                // previous challenge's passive focus cannot identify this header.
                guard restored else { break }
                guard advanced, !CFEqual(challengeStrip, originalAssociationStrip) else {
                    selectionsVerified = false; break
                }
                // A passive rail's selected-child hint becomes a pair only
                // after this actual changed-strip challenge and exact return.
                if originalSelectedChild != nil, CFEqual(associationStrip, originalAssociationStrip) {
                    originalPairVerified = true
                }
                observed.append((challenge, challengeStrip))
            }
            if allHeldHeaders {
                if expectedIndex == originalIndex {
                    restored = permitsRead() && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else if await referenceIsCurrent() {
                    let precedingStrip = associationStrip
                    let returned = await select(originalIndex, referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                    if returned, CFEqual(associationStrip, originalAssociationStrip),
                       !CFEqual(precedingStrip, originalAssociationStrip) { originalPairVerified = true }
                    restored = returned && CFEqual(expectedFocus, originalFocus) && selectedChildRestored()
                } else { restored = false }
                if !restored, !lost, expectedIndex == originalIndex {
                    if originalSelectedChild == nil { originalPairVerified = false }
                    restored = await restoreOriginalFocus(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                        && selectedChildRestored()
                }
            }
            let inverseVerified: Bool
            if restored { inverseVerified = await restoreViewport(referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop) }
            else { inverseVerified = false }
            let sampledViewport = currentViewport()
            let viewRestored = inverseVerified && (sampledViewport.map { values in
                Self.sameViewport(values, viewport)
            } ?? false)
            guard restored, viewRestored, await referenceIsCurrent(), permitsRead(), !stop() else {
                effects.reason = "association_restoration_unverified"; return []
            }
            if let originalMixerViewport {
                let mixerRestored: Bool
                if mixerViewportIsExpected(), let currentMixerViewport = expectedMixerViewport {
                    if currentMixerViewport.hasSameViewportPosition(as: originalMixerViewport) { mixerRestored = true }
                    else {
                        mixerRestored = await recoverMixerReadability(restoring: originalMixerViewport,
                            referenceIsCurrent: referenceIsCurrent, stoppingWhen: stop)
                    }
                } else { mixerRestored = false }
                guard mixerRestored else {
                    effects.restoration = "not_restored"
                    effects.reason = "association_mixer_viewport_restoration_unverified"
                    return []
                }
                expectedMixerViewport = originalMixerViewport
            }
            effects.restoration = expectedMixerViewport == nil ? "restored" : "not_restored"
            guard selectionsVerified, !observed.isEmpty else {
                effects.reason = "association_selection_unverified"; return []
            }
            guard let railRole = AXHelpers.getRole(rail, runtime: logic.ax),
                  [kAXGroupRole, kAXListRole, kAXScrollAreaRole, kAXOutlineRole, kAXTableRole]
                    .contains(where: { railRole == $0 as String }),
                  case .read(let publicationHeaders) = AXLogicProElements.enumerateTrackHeaderRows(in: rail,
                    runtime: logic.ax) else {
                lost = true; effects.reason = "association_selection_unverified"; return []
            }
            retainedTrackBindings?.forEach { $0.exposure?.observeHeaders(publicationHeaders) }
            guard Self.same(headers, publicationHeaders), await referenceIsCurrent(), permitsRead(), !stop() else {
                effects.reason = "association_selection_unverified"; return []
            }
            // A narrow challenge corroborates the requested selection; it does
            // not authorize later routing acquisition on that unselected peer.
            let pairs = ((allHeldHeaders ? observed : []) + (originalPairVerified ? [(originalIndex, originalAssociationStrip)] : [])).map { index, strip in
                Pair(track: retainedTrackBindings?[index]
                        ?? .init(window: window, header: headers[index], document: document, runtime: logic,
                            observedHeaders: publicationHeaders),
                     strip: .init(window: window, mixer: mixer, strip: strip, document: document),
                     source: originalSelectedChild == nil ? "held_exclusive_selection_focus" : "held_exclusive_selection_selected_child")
            }
            // Constructing a binding reads its native header shape. Renew this
            // same complete scope after those deciding reads before publishing.
            guard let first = pairs.first, await referenceIsCurrent(),
                  let finalHeaders = readOriginalHeaderPopulation(for: first.track, observingPopulation: { _ in }),
                  Self.same(publicationHeaders, finalHeaders), permitsRead(),
                  await referenceIsCurrent(), !stop() else {
                effects.reason = "association_selection_unverified"; return []
            }
            // Reference/stop callbacks and binding construction above can read
            // or move the omitted native axes. Prove the original presentation
            // after those final reads, without adopting a newer position.
            if expectedMixerViewport != nil {
                guard mixerViewportIsExpected(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                    effects.reason = "association_mixer_viewport_restoration_unverified"
                    return []
                }
            }
            effects.restoration = "restored"
            return pairs
        }
    }
}
