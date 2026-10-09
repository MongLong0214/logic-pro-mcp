@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Two explicit held-rail selections, not a name/ordinal join or a global census.
    /// Only a visible Mixer-strip starting focus and one exclusive selection qualify.
    final class HeldSelectionAssociation: @unchecked Sendable {
        struct Pair: @unchecked Sendable {
            let track: AXTrackBinding.Binding
            let strip: AXMixerStripBinding.Binding
        }
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
        let viewport: [(AXUIElement, Double)]
        private var expectedIndex: Int
        private var expectedFocus: AXUIElement
        private var lost = false
        private(set) var effects = SessionPopulationObservation.UIEffects()

        init?(window: AXUIElement, logic: AXLogicProElements.Runtime,
              expectedProject: TargetDescriptor?, requiresProjectReference: Bool) {
            // The existing foreground AX probe requires this CLI process's
            // window-server connection; a missing/foreign PID still refuses.
            _ = logic.onScreenWindowList()
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let pid = logic.logicProPID(), let app = AXLogicProElements.appRoot(runtime: logic),
                  let title = AXHelpers.getTitle(window, runtime: logic.ax),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  let url = URL(string: document), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  !requiresProjectReference || (
                    expectedProject?.projectName?.utf8.elementsEqual(AccessibilityChannel.projectName(fromWindowTitle: title).utf8) == true
                    && expectedProject?.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true),
                  let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: logic),
                  let railPath = Self.path(rail, to: window, ax: logic.ax),
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic),
                  headers.count > 1,
                  let selected = Self.exclusiveIndex(headers, ax: logic.ax),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  let mixer: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax),
                  let enumeration = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                  enumeration.strips.filter({ CFEqual($0, focus) }).count == 1,
                  let path = Self.path(mixer, to: window, ax: logic.ax),
                  let viewport = Self.viewport(window, ax: logic.ax),
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
            originalIndex = selected; originalFocus = focus; expectedIndex = selected; expectedFocus = focus
            transport = activity; self.viewport = viewport
            transportPaths = [playPath, recordPath]
            guard permitsRead(), AXHelpers.isAttributeSettable(rail, kAXSelectedChildrenAttribute as String,
                runtime: logic.ax) == true else { return nil }
        }

        private static func exclusiveIndex(_ headers: [AXUIElement], ax: AXHelpers.Runtime) -> Int? {
            let values = headers.map { AXValueExtractors.extractSelectedState($0, runtime: ax) }
            guard values.allSatisfy({ $0 != nil }), values.filter({ $0 == true }).count == 1 else { return nil }
            return values.firstIndex(where: { $0 == true })
        }

        private static func same(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { CFEqual($0, $1) }
        }

        private static func path(_ mixer: AXUIElement, to window: AXUIElement, ax: AXHelpers.Runtime) -> [AXUIElement]? {
            var path = [mixer]
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

        private static func viewport(_ window: AXUIElement, ax: AXHelpers.Runtime) -> [(AXUIElement, Double)]? {
            guard case .success(let census) = AXHelpers.censusDescendantResult(of: window, role: kAXScrollBarRole as String,
                maxDepth: 32, runtime: ax, requiresCompleteTraversal: true,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil }) else { return nil }
            var result: [(AXUIElement, Double)] = []
            for control in census.matches {
                guard case .success(.some(let value)) = AXHelpers.getAttributeResult(control, kAXValueAttribute as String,
                    runtime: ax) as Result<NSNumber?, AXHelpers.AXStatusError>, value.doubleValue.isFinite else { return nil }
                result.append((control, value.doubleValue))
            }
            return result
        }

        private func owned() -> Bool {
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: logic.ax) as Bool? == true,
                  case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(app, kAXWindowsAttribute as String, runtime: logic.ax),
                  windows.filter({ CFEqual($0, window) }).count == 1,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  document.utf8.elementsEqual(currentDocument.utf8), !AXLogicProElements.dialogPresent(runtime: logic),
                  let currentRailPath = Self.path(rail, to: window, ax: logic.ax), Self.same(railPath, currentRailPath),
                  case .success(let currentHeaders) = AXHelpers.childrenResult(rail, runtime: logic.ax),
                  Self.same(headers, currentHeaders),
                  let currentPath = Self.path(mixer, to: window, ax: logic.ax), Self.same(path, currentPath),
                  let currentStrips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: logic.ax),
                  Self.same(strips, currentStrips.strips),
                  transportPaths.allSatisfy({ held in
                      guard let control = held.first, let current = Self.path(control, to: window, ax: logic.ax),
                            Self.same(held, current),
                            AXHelpers.getRole(control, runtime: logic.ax) == kAXCheckBoxRole as String,
                            case .success(.some(let value)) = AXHelpers.getAttributeResult(control, kAXValueAttribute as String,
                                runtime: logic.ax) as Result<NSNumber?, AXHelpers.AXStatusError> else { return false }
                      return value == 0
                  }),
                  case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  document.utf8.elementsEqual(finalDocument.utf8), logic.logicProPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { lost = true; return false }
            return true
        }

        /// Only this explicit association observation uses this request-local focus scope.
        /// It does not itself read Help, and cannot admit an editor, key event or
        /// unheld strip. Requested-strip Help remains under its existing guard.
        func permitsRead() -> Bool {
            // Capability reads do not move focus. Validate complete ownership once,
            // after their bookend, rather than repeating the same population census
            // twice for every caller's guarded AX read. Selection writes also
            // require the final scoped action boundary in select().
            guard !lost, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(focus, expectedFocus), strips.filter({ CFEqual($0, focus) }).count == 1,
                  AXHelpers.getRole(focus, runtime: logic.ax) == kAXLayoutItemRole as String,
                  AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: logic.ax) == false else { lost = true; return false }
            for attribute in [kAXValueAttribute as String, kAXSelectedTextAttribute as String,
                              kAXNumberOfCharactersAttribute as String, kAXInsertionPointLineNumberAttribute as String] {
                let reading = AXHelpers.getAttributeResult(focus, attribute, runtime: logic.ax) as Result<AnyObject?, AXHelpers.AXStatusError>
                switch reading {
                case .failure(let error) where error.isDefinitiveAbsence: continue
                case .success(.some(let value)):
                    guard attribute == kAXNumberOfCharactersAttribute as String || attribute == kAXInsertionPointLineNumberAttribute as String,
                          CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber,
                          number.doubleValue == 0 else { lost = true; return false }
                default: lost = true; return false
                }
            }
            guard owned(), Self.exclusiveIndex(headers, ax: logic.ax) == expectedIndex,
                  let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(final, expectedFocus) else { lost = true; return false }
            return true
        }

        private func select(_ index: Int, stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard permitsRead(), !stop(), AXHelpers.isAttributeSettable(rail, kAXSelectedChildrenAttribute as String,
                runtime: logic.ax) == true, permitsRead(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  owned() else { return false }
            // R965-ASSOC-C001: the deciding focus/selection reads in permitsRead
            // can themselves coincide with a document/window switch. Revalidate
            // scoped ownership AFTER them, with no further AX read before write.
            let previousFocus = expectedFocus
            effects.navigationPerformed = true; effects.restoration = "not_restored"
            if !effects.attempted.contains("track_selection") { effects.attempted.append("track_selection") }
            let accepted = AXHelpers.setAttribute(rail, kAXSelectedChildrenAttribute as String, [headers[index]] as CFArray, runtime: logic.ax)
            for attempt in 0..<4 {
                guard owned() else { return false }
                let selectionChanged = Self.exclusiveIndex(headers, ax: logic.ax) == index
                if selectionChanged, !effects.changed.contains("track_selection") {
                    effects.changed.append("track_selection")
                }
                guard let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                      strips.filter({ CFEqual($0, focus) }).count == 1 else {
                    lost = true; return false
                }
                if selectionChanged, !CFEqual(focus, previousFocus) {
                    expectedIndex = index; expectedFocus = focus
                    return permitsRead() && !stop() && accepted
                }
                if attempt < 3 {
                    do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
                }
            }
            return false
        }

        func observe(referenceIsCurrent: @Sendable () async -> Bool,
                     stoppingWhen stop: @Sendable () -> Bool) async -> [Pair] {
            guard let challenge = headers.indices.first(where: { $0 != originalIndex }),
                  await referenceIsCurrent(), permitsRead(), !stop() else { return [] }
            let advanced = await select(challenge, stoppingWhen: stop)
            let challengeFocus = expectedFocus
            let restored: Bool
            if expectedIndex == originalIndex {
                restored = permitsRead() && CFEqual(expectedFocus, originalFocus)
            } else if await referenceIsCurrent() {
                restored = await select(originalIndex, stoppingWhen: stop) && CFEqual(expectedFocus, originalFocus)
            } else { restored = false }
            let currentViewport = Self.viewport(window, ax: logic.ax)
            let viewRestored = currentViewport.map { values in
                values.count == viewport.count && zip(values, viewport).allSatisfy { CFEqual($0.0, $1.0) && $0.1 == $1.1 }
            } ?? false
            guard restored, viewRestored, await referenceIsCurrent(), permitsRead(), !stop() else {
                effects.reason = "association_restoration_unverified"; return []
            }
            effects.restoration = "restored"
            guard advanced, !CFEqual(challengeFocus, originalFocus) else {
                effects.reason = "association_selection_unverified"; return []
            }
            return [(challenge, challengeFocus), (originalIndex, originalFocus)].map { index, strip in
                Pair(track: .init(window: window, header: headers[index], document: document, runtime: logic),
                     strip: .init(window: window, mixer: mixer, strip: strip, document: document))
            }
        }
    }
}
