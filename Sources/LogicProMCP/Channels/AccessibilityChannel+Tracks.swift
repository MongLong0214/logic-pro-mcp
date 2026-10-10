import ApplicationServices
import AppKit
// Carbon, only for the Text Input Source services: there is no modern replacement for reading
// which keyboard input source is active, and that reading is what explains a synthetic key
// arriving as a different character than it was posted as.
import Carbon
import Foundation

/// Track surface: enumerate/select tracks, mute/solo/arm/rename toggles, track creation via menu, and deletion.
extension AccessibilityChannel {
    // MARK: - Tracks

    static func defaultGetTracks(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let states = defaultGetTrackStates(runtime: runtime) else {
            return .error("Track population unavailable: the Arrange track rail could not be read.")
        }
        return encodeResult(states)
    }

    static func defaultGetTrackStates(runtime: AXLogicProElements.Runtime = .production) -> [TrackState]? {
        defaultGetTrackStates(runtime: runtime, stoppingWhen: { false }).states
    }

    /// #1079: the same walk, asking `stop` before each header and again inside it, right before
    /// the header's AXHelp reads (`extractTrackState(stoppingBeforeHelp:)`). Once it answers true
    /// the walk ends there: `yielded` is true and no states are returned, since a partial list
    /// would read as a project with fewer tracks. Help reads already under way run to their end.
    static func defaultGetTrackStates(
        runtime: AXLogicProElements.Runtime = .production, stoppingWhen stop: () -> Bool
    ) -> (states: [TrackState]?, yielded: Bool) {
        // Keep acquisition failure distinct from a successfully observed empty rail.
        // The shared reader tolerates unrelated loading subtrees, but rejects an
        // unreadable rail or row role rather than shifting the remaining row indices.
        guard case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
              case .read(let headers) = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        else { return (nil, false) }
        return readTrackStates(from: headers, in: window, runtime: runtime, stoppingWhen: stop)
    }

    /// Read the retained rail, rather than rediscovering a possibly different window.
    static func readTrackStates(
        from headers: [AXUIElement], in window: AXUIElement? = nil,
        runtime: AXLogicProElements.Runtime, exposure: AXTrackBinding.Exposure? = nil,
        readingTypeHelp: Bool = true, stoppingWhen stop: () -> Bool
    ) -> (states: [TrackState]?, yielded: Bool) {
        let document: String?
        if let window, case .success(let observed?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime) {
            document = observed
        } else { document = nil }
        var states: [TrackState] = []
        states.reserveCapacity(headers.count)
        for (index, header) in headers.enumerated() {
            if stop() { return (nil, true) }
            guard var state = AXValueExtractors.extractTrackState(
                from: header, index: index, runtime: runtime.ax,
                observingStackChildren: { exposure?.observeDisclosureChildren(header: header, children: $0, selected: $1) },
                observingExposure: exposure,
                readingTypeHelp: readingTypeHelp,
                stoppingBeforeHelp: stop
            ) else { return (nil, true) }
            exposure?.observeStackState(header: header, isStackHeader: state.isStackHeader, collapsed: state.stackCollapsed)
            if let window, let document, state.liveIdentityBacked, state.placeholder != true {
                // Baseline rows were already exposed and keep ordinary custody. Only
                // newly acquired headers depend on this temporary disclosure's lifetime.
                let scope = exposure.flatMap { value in
                    value.originalHeaders.contains(where: { CFEqual($0, header) }) ? nil : value
                }
                let binding = AXTrackBinding.Binding(window: window, header: header, document: document, runtime: runtime, exposure: scope)
                if binding.projectPath != nil { state.physicalBinding = binding }
            }
            states.append(state)
        }
        return (states, false)
    }

    /// One request's observed disclosure. No selection, viewport or musical
    /// writes recover custody. Only its still-owned original workspace focus
    /// may be restored after all acquired disclosures have been reversed.
    // One mutation-gate-owned request mutates this navigation. The request-local
    // reader below only corroborates retained AX facts; it never actuates UI.
    final class OwnedTrackStackObservationNavigation: @unchecked Sendable {
        final class ReadFocusScope: @unchecked Sendable {
            private let lock = NSLock()
            private var navigation: OwnedTrackStackObservationNavigation?
            private var passiveMixer: PassiveMixerReadFocus?
            private var association: HeldSelectionAssociation?
            func retain(_ navigation: OwnedTrackStackObservationNavigation?) {
                lock.withLock { self.navigation = navigation; passiveMixer = nil; association = nil }
            }
            func retainAssociation(_ observation: HeldSelectionAssociation) {
                lock.withLock { association = observation }
            }
            func retainPassiveMixer(in window: AXUIElement, logic: AXLogicProElements.Runtime) {
                let candidate = PassiveMixerReadFocus(window: window, logic: logic)
                lock.withLock { passiveMixer = candidate }
            }
            func permits() -> Bool {
                let held = lock.withLock { (navigation, passiveMixer, association) }
                return held.0?.permitsHeldPassiveHeaderFocus() == true || held.1?.permits() == true
                    || held.2?.permitsRead() == true
            }

            /// A passive strip exposes a zero insertion sentinel on Logic 12.3.
            /// This witness grants only its caller's bounded semantic read:
            /// no-navigation track acquisition or an owned routing-popup read.
            /// It never grants Help, keyboard commands or musical write permission.
            struct PassiveMixerReadFocus {
                private let acquisitionPermitted: @Sendable () -> Bool
                let logic: AXLogicProElements.Runtime
                let pid: pid_t
                let app: AXUIElement
                let window: AXUIElement
                let title: String
                let document: String
                let focus: AXUIElement
                let binding: AXLogicProElements.MixerAreaBinding

                init?(window: AXUIElement, logic: AXLogicProElements.Runtime,
                      acquisitionPermitted: @escaping @Sendable () -> Bool = {
                          (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                      }) {
                    guard acquisitionPermitted(),
                          let pid = logic.logicProPID(),
                          let app = AXLogicProElements.appRoot(runtime: logic),
                          let title = AXHelpers.getTitle(window, runtime: logic.ax),
                          case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                          let url = URL(string: document), url.isFileURL,
                          url.host == nil || url.host == "" || url.host == "localhost",
                          let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                          let mixer: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax),
                          AXHelpers.getRole(mixer, runtime: logic.ax) == kAXLayoutAreaRole as String,
                          AXLocalePolicy.mixerNamedElement.containsNormalized(AXHelpers.getDescription(mixer, runtime: logic.ax)),
                          let outer: AXUIElement = AXHelpers.getAttribute(mixer, kAXParentAttribute as String, runtime: logic.ax),
                          AXHelpers.getRole(outer, runtime: logic.ax) == kAXGroupRole as String,
                          AXLocalePolicy.mixerNamedElement.containsNormalized(AXHelpers.getDescription(outer, runtime: logic.ax))
                    else { return nil }
                    // Do not rediscover Mixer via its Help-reading candidate census:
                    // no-navigation inspection must not query any focus-moving Help.
                    var reversePath = [mixer]
                    while !CFEqual(reversePath.last!, window) {
                        guard reversePath.count < 12,
                              let parent: AXUIElement = AXHelpers.getAttribute(reversePath.last!, kAXParentAttribute as String, runtime: logic.ax),
                              !reversePath.contains(where: { CFEqual($0, parent) }) else { return nil }
                        reversePath.append(parent)
                    }
                    let binding = AXLogicProElements.MixerAreaBinding(mixer: mixer, owners: [], path: reversePath.reversed())
                    self.acquisitionPermitted = acquisitionPermitted
                    self.logic = logic; self.pid = pid; self.app = app; self.window = window
                    self.title = title; self.document = document; self.focus = focus; self.binding = binding
                    guard permits() else { return nil }
                }

                private func zeroNumber(_ attribute: String) -> Bool {
                    guard case .success(.some(let value)) = AXHelpers.getAttributeResult(focus, attribute,
                        runtime: logic.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                        CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber else { return false }
                    return number.doubleValue == 0
                }

                private func noValue(_ attribute: String) -> Bool {
                    guard case .failure(let error) = AXHelpers.getAttributeResult(focus, attribute,
                        runtime: logic.ax) as Result<AnyObject?, AXHelpers.AXStatusError> else { return false }
                    return error == .init(raw: AXError.noValue.rawValue)
                }

                func permits() -> Bool {
                    guard acquisitionPermitted(),
                          logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                          let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp),
                          AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: logic.ax) as Bool? == true,
                          let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                          let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                          CFEqual(main, window), CFEqual(focusedWindow, window),
                          AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                          case .success(.some(let doc)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                          doc.utf8.elementsEqual(document.utf8),
                          let currentFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                          CFEqual(currentFocus, focus),
                          AXHelpers.getRole(focus, runtime: logic.ax) == kAXLayoutItemRole as String,
                          AXHelpers.isAttributeSettable(focus, kAXValueAttribute as String, runtime: logic.ax) == false,
                          noValue(kAXValueAttribute as String), noValue(kAXSelectedTextAttribute as String),
                          zeroNumber(kAXNumberOfCharactersAttribute as String), zeroNumber(kAXInsertionPointLineNumberAttribute as String),
                          AXHelpers.getRole(binding.mixer, runtime: logic.ax) == kAXLayoutAreaRole as String,
                          AXLocalePolicy.mixerNamedElement.containsNormalized(AXHelpers.getDescription(binding.mixer, runtime: logic.ax)),
                          let first = binding.path.first, CFEqual(first, window),
                          let last = binding.path.last, CFEqual(last, binding.mixer) else { return false }
                    for (parent, child) in zip(binding.path, binding.path.dropFirst()) {
                        guard case .success(let children) = AXHelpers.childrenResult(parent, runtime: logic.ax),
                              children.filter({ CFEqual($0, child) }).count == 1,
                              let observedParent: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String, runtime: logic.ax),
                              CFEqual(parent, observedParent) else { return false }
                    }
                    guard let strips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: binding.mixer, runtime: logic.ax),
                          strips.strips.filter({ CFEqual($0, focus) }).count == 1,
                          let parent: AXUIElement = AXHelpers.getAttribute(focus, kAXParentAttribute as String, runtime: logic.ax),
                          CFEqual(parent, binding.mixer),
                          let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                          CFEqual(finalFocus, focus),
                          case .success(.some(let finalDoc)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                          finalDoc.utf8.elementsEqual(document.utf8) else { return false }
                    return true
                }
            }
        }
        let logic: AXLogicProElements.Runtime
        let mouse: AXMouseHelper.Runtime
        let pid: pid_t
        let app: AXUIElement
        let window: AXUIElement
        let title: String
        let document: String
        let rail: AXUIElement
        let header: AXUIElement
        let disclosure: AXUIElement
        private let hiddenControl: AXUIElement?
        private let hiddenMenuPath: [AXUIElement]?
        private let originalSelectionPresentation: [[Data]]?
        let originalHeaders: [AXUIElement]
        let originalFocus: AXUIElement
        private let originalWorkspacePath: [AXUIElement]?
        let selected: [AXUIElement]
        let transport: AXLogicProElements.ObservedTransportActivity
        let referenceIsCurrent: @Sendable () async -> Bool
        private struct Viewport { let control: AXUIElement; let value: Double }
        private typealias Disclosure = (header: AXUIElement, disclosure: AXUIElement)
        private struct AcquiredDisclosure {
            let target: Disclosure
            let beforeHeaders: [AXUIElement]
            let afterHeaders: [AXUIElement]
        }
        private let viewport: [Viewport]
        private var observedFocus: AXUIElement
        private var expandedHeaders: [AXUIElement]?
        private var releaseUnverified = false
        private struct PassiveFocusControl {
            let element: AXUIElement
            let role: String
        }
        private var completedClickFocus: (target: Disclosure, controls: [PassiveFocusControl])?
        private var acceptedPassiveClickFocus: (target: Disclosure, controls: [PassiveFocusControl])?
        private var restorationStarted = false
        private var acquired: [AcquiredDisclosure] = []
        private var pending: [Disclosure]
        private(set) var exposure: AXTrackBinding.Exposure?
        private(set) var effects = SessionPopulationObservation.UIEffects()

        init?(window: AXUIElement, logic: AXLogicProElements.Runtime, mouse: AXMouseHelper.Runtime,
              expectedProject: TargetDescriptor?, requiresProjectReference: Bool,
              referenceIsCurrent: @escaping @Sendable () async -> Bool) {
            // The system-wide focused-application AX read needs this process's
            // window-server connection first; an unread/foreign PID still refuses.
            _ = logic.onScreenWindowList()
            guard let pid = logic.logicProPID() else {
                Log.info("Population navigation acquisition unavailable: process identity", subsystem: "ax"); return nil
            }
            guard let app = AXLogicProElements.appRoot(runtime: logic),
                  let title = AXHelpers.getTitle(window, runtime: logic.ax),
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  let url = URL(string: document), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else {
                Log.info("Population navigation acquisition unavailable: project identity", subsystem: "ax"); return nil
            }
            guard let rail = AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: logic),
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic) else {
                Log.info("Population navigation acquisition unavailable: header rail", subsystem: "ax"); return nil
            }
            guard
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  let selected = Self.selectedHeaders(headers, ax: logic.ax) else {
                Log.info("Population navigation acquisition unavailable: focus or selection", subsystem: "ax"); return nil
            }
            guard let viewport = Self.readViewport(window, ax: logic.ax) else {
                Log.info("Population navigation acquisition unavailable: viewport", subsystem: "ax"); return nil
            }
            guard let transport = try? AXLogicProElements.observedTransportActivity(in: window, runtime: logic,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  !transport.isPlaying, !transport.isRecording else {
                Log.info("Population navigation acquisition unavailable: stopped transport", subsystem: "ax"); return nil
            }
            if requiresProjectReference {
                guard expectedProject?.projectName?.utf8.elementsEqual(AccessibilityChannel.projectName(fromWindowTitle: title).utf8) == true,
                      expectedProject?.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true else { return nil }
            }
            guard let collapsed = Self.collapsedDisclosures(in: headers, runtime: logic) else { return nil }
            let hiddenView = AXLogicProElements.hiddenTrackViewRead(headers: headers, in: window, runtime: logic)
            let hiddenControl = hiddenView?.shown == false ? hiddenView?.control : nil
            let hiddenMenuPath = hiddenControl == nil ? nil : Self.hiddenMenuPath(in: app, runtime: logic)
            let focusedPID = logic.focusedApplicationPID()
            guard hiddenMenuPath != nil || focusedPID == pid else {
                Log.info("Population navigation acquisition unavailable: foreground process identity", subsystem: "ax"); return nil
            }
            let targets = (hiddenControl.flatMap { control in headers.first.map { [($0, control)] } } ?? []) + collapsed
            guard let first = targets.first else {
                Log.info("Population navigation acquisition unavailable: no held exposure control", subsystem: "ax"); return nil
            }
            self.logic = logic; self.mouse = mouse; self.pid = pid; self.app = app
            self.window = window; self.title = title; self.document = document; self.rail = rail
            header = first.0; disclosure = first.1; originalHeaders = headers
            self.hiddenControl = hiddenControl
            self.hiddenMenuPath = hiddenMenuPath
            pending = targets
            originalFocus = focus; observedFocus = focus; self.selected = selected
            originalSelectionPresentation = hiddenMenuPath == nil ? nil
                : Self.selectionPresentation(selected, headers: headers, ax: logic.ax)
            originalWorkspacePath = Self.workspacePath(focus, in: window, ax: logic.ax, permitsContainer: hiddenControl != nil)
            if hiddenControl != nil {
                guard originalWorkspacePath != nil,
                      AXHelpers.isAttributeSettable(focus, kAXFocusedAttribute as String, runtime: logic.ax) == true else {
                    Log.info("Population navigation acquisition unavailable: original focus restoration", subsystem: "ax"); return nil
                }
            }
            self.transport = transport; self.viewport = viewport; self.referenceIsCurrent = referenceIsCurrent
        }

        /// The bound AX leaf does not dispatch an input event to the system's
        /// keyboard owner. Hold and reread its entire physical menu path; this
        /// cannot authorize the global mouse route used by stack disclosures.
        private static func hiddenMenuPath(in app: AXUIElement, runtime: AXLogicProElements.Runtime) -> [AXUIElement]? {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  case .success(.some(let bar)) = AXHelpers.getAttributeResult(app, kAXMenuBarAttribute as String,
                    runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError>,
                  AXHelpers.getRole(bar, runtime: runtime.ax) == kAXMenuBarRole as String,
                  case .success(let bars) = AXHelpers.childrenResult(bar, runtime: runtime.ax) else { return nil }
            func unique(_ children: [AXUIElement], role: String, labels: AXLocalePolicy.LabelSet?) -> AXUIElement? {
                var matches: [AXUIElement] = []
                for child in children {
                    guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                          case .success(.some(let actualRole)) = AXHelpers.getAttributeResult(child, kAXRoleAttribute as String,
                            runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError> else { return nil }
                    guard actualRole == role else { continue }
                    if let labels {
                        guard case .success(let title) = AXHelpers.getAttributeResult(child, kAXTitleAttribute as String,
                            runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError> else { return nil }
                        guard labels.matches(title) else { continue }
                    }
                    matches.append(child)
                }
                return matches.count == 1 ? matches[0] : nil
            }
            guard let track = unique(bars, role: kAXMenuBarItemRole as String, labels: AXLocalePolicy.trackMenuBar),
                  case .success(let tracks) = AXHelpers.childrenResult(track, runtime: runtime.ax),
                  let menu = unique(tracks, role: kAXMenuRole as String, labels: nil),
                  case .success(let leaves) = AXHelpers.childrenResult(menu, runtime: runtime.ax),
                  let leaf = unique(leaves, role: kAXMenuItemRole as String, labels: AXLocalePolicy.toggleHideViewMenuItem),
                  case .success(.some(true)) = AXHelpers.getAttributeResult(leaf, kAXEnabledAttribute as String,
                    runtime: runtime.ax) as Result<Bool?, AXHelpers.AXStatusError>,
                  case .success(let actions) = AXHelpers.getActionNamesResult(leaf, runtime: runtime.ax),
                  actions.contains(kAXPressAction as String) else { return nil }
            return [bar, track, menu, leaf]
        }

        private func isBoundHiddenMenuTarget(_ target: Disclosure) -> Bool {
            guard let hiddenControl, let held = hiddenMenuPath, CFEqual(target.disclosure, hiddenControl),
                  let current = Self.hiddenMenuPath(in: app, runtime: logic) else { return false }
            return same(held, current)
        }

        /// Track's menu is application-global. Its final reread cannot by itself
        /// bind AXPress to the document whose view was acquired. Finish stop
        /// callbacks before the final scope sample; they can themselves read AX
        /// focus and must not leave an already sampled document authorizing Press.
        private func hiddenMenuActionBoundary(stoppingWhen stop: @Sendable () -> Bool) -> Bool {
            guard !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  logic.logicProPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp),
                  !stop(), logic.logicProPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(focus, observedFocus),
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  currentDocument.utf8.elementsEqual(document.utf8) else { return false }
            return true
        }

        private static func workspacePath(_ focus: AXUIElement, in window: AXUIElement,
                                          ax: AXHelpers.Runtime, permitsContainer: Bool = false) -> [AXUIElement]? {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let role = AXHelpers.getRole(focus, runtime: ax),
                  role == "AXLayoutArea" || role == kAXGroupRole as String
                    || (permitsContainer && role == kAXListRole as String),
                  let owner: AXUIElement = AXHelpers.getAttribute(focus, kAXWindowAttribute as String, runtime: ax),
                  CFEqual(owner, window) else { return nil }
            var path = [focus]
            for _ in 0..<32 {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      let child = path.last else { return nil }
                if CFEqual(child, window) { return path }
                guard let parent: AXUIElement = AXHelpers.getAttribute(child, kAXParentAttribute as String, runtime: ax),
                      !path.contains(where: { CFEqual($0, parent) }),
                      case .success(let children) = AXHelpers.childrenResult(parent, runtime: ax),
                      children.filter({ CFEqual($0, child) }).count == 1 else { return nil }
                path.append(parent)
            }
            return nil
        }

        /// Reuse the same status-preserving direct-child shape at every revealed rail.
        /// Newly observed peer membership is not parent/depth evidence.
        private static func collapsedDisclosures(in headers: [AXUIElement], runtime logic: AXLogicProElements.Runtime) -> [Disclosure]? {
            var collapsed: [Disclosure] = []
            for header in headers {
                guard case .success(let children) = AXHelpers.childrenResult(header, runtime: logic.ax) else { return nil }
                var triangles: [AXUIElement] = []
                for child in children {
                    guard case .success(.some(let role)) = AXHelpers.getAttributeResult(
                        child, kAXRoleAttribute as String, runtime: logic.ax) as Result<String?, AXHelpers.AXStatusError> else { return nil }
                    if role == kAXDisclosureTriangleRole as String { triangles.append(child) }
                }
                guard triangles.count <= 1 else { return nil }
                if let triangle = triangles.first {
                    guard case .success(.some(let value)) = AXHelpers.getAttributeResult(
                        triangle, kAXValueAttribute as String, runtime: logic.ax) as Result<NSNumber?, AXHelpers.AXStatusError>,
                          value == 0 || value == 1 else { return nil }
                    if value == 0 {
                        // Two rows cannot authorize two gestures on one physical control.
                        guard !collapsed.contains(where: {
                            CFEqual($0.header, header) || CFEqual($0.disclosure, triangle)
                        }) else { return nil }
                        collapsed.append((header, triangle))
                    }
                }
            }
            return collapsed
        }

        private static func selectedHeaders(_ headers: [AXUIElement], ax: AXHelpers.Runtime) -> [AXUIElement]? {
            var selected: [AXUIElement] = []
            for header in headers {
                let reading = AXHelpers.getAttributeResult(header, kAXSelectedAttribute as String,
                    runtime: ax) as Result<Bool?, AXHelpers.AXStatusError>
                guard case .success(.some(let value)) = reading else {
                    return nil
                }
                if value { selected.append(header) }
            }
            return selected
        }

        /// A byte-exact, unique presentation envelope, never a TrackBinding or
        /// semantic identity. It can permit only the already-held Hide View inverse.
        private static func selectionPresentation(_ selected: [AXUIElement], headers: [AXUIElement],
                                                  ax: AXHelpers.Runtime) -> [[Data]]? {
            var names: [Data] = []
            for header in headers {
                guard case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(from: header, runtime: ax),
                      !name.isEmpty else { return nil }
                names.append(Data(name.utf8))
            }
            var result: [[Data]] = []
            for header in selected {
                guard let index = headers.firstIndex(where: { CFEqual($0, header) }),
                      names.filter({ $0 == names[index] }).count == 1,
                      case .success(.some(let role)) = AXHelpers.getAttributeResult(header, kAXRoleAttribute as String,
                        runtime: ax) as Result<String?, AXHelpers.AXStatusError>,
                      case .success(.some(let description)) = AXHelpers.getAttributeResult(header, kAXDescriptionAttribute as String,
                        runtime: ax) as Result<String?, AXHelpers.AXStatusError>, !description.isEmpty else { return nil }
                result.append([Data(role.utf8), names[index], Data(description.utf8)])
            }
            return result
        }

        private func selectedTracksRemainVisible(_ selected: [AXUIElement]) -> Bool {
            for header in selected {
                guard case .success(let children) = AXHelpers.childrenResult(header, runtime: logic.ax) else { return false }
                var matches: [AXUIElement] = []
                for child in children {
                    guard case .success(.some(let role)) = AXHelpers.getAttributeResult(child, kAXRoleAttribute as String,
                        runtime: logic.ax) as Result<String?, AXHelpers.AXStatusError> else { return false }
                    guard role == kAXCheckBoxRole as String else { continue }
                    guard case .success(let description) = AXHelpers.getAttributeResult(child, kAXDescriptionAttribute as String,
                        runtime: logic.ax) as Result<String?, AXHelpers.AXStatusError> else { return false }
                    if AXLocalePolicy.trackHideControl.matches(description) { matches.append(child) }
                }
                guard matches.count == 1, let control = matches.first,
                      let owner: AXUIElement = AXHelpers.getAttribute(control, kAXWindowAttribute as String, runtime: logic.ax),
                      CFEqual(owner, window),
                      case .success(.some(let flag)) = AXHelpers.getAttributeResult(control, kAXValueAttribute as String,
                        runtime: logic.ax) as Result<NSNumber?, AXHelpers.AXStatusError>, flag.doubleValue == 0 else { return false }
            }
            return true
        }

        private static func readViewport(_ rail: AXUIElement, ax: AXHelpers.Runtime,
                                         exposure: AXTrackBinding.Exposure? = nil) -> [Viewport]? {
            guard case .success(let census) = AXHelpers.censusDescendantResult(of: rail, role: kAXScrollBarRole as String,
                maxDepth: 32, runtime: ax, requiresCompleteTraversal: true,
                observingRole: { exposure?.observeRole(element: $0, role: $1) },
                observingChildren: { exposure?.observeChildren(element: $0, children: $1) }) else { return nil }
            var values: [Viewport] = []
            for control in census.matches {
                guard case .success(.some(let value)) = AXHelpers.getAttributeResult(
                    control, kAXValueAttribute as String, runtime: ax) as Result<NSNumber?, AXHelpers.AXStatusError>,
                      value.doubleValue.isFinite else { return nil }
                values.append(.init(control: control, value: value.doubleValue))
            }
            return values
        }

        private func same(_ a: [AXUIElement], _ b: [AXUIElement]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { CFEqual($0, $1) }
        }

        private func value(_ target: Disclosure) -> Int? {
            let observed: Int?
            if hiddenControl.map({ CFEqual($0, target.disclosure) }) == true {
                if case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic),
                   let view = AXLogicProElements.hiddenTrackViewRead(headers: headers, in: window, runtime: logic),
                   CFEqual(view.control, target.disclosure) { observed = view.shown ? 1 : 0 }
                else { observed = nil }
            } else {
                observed = AXLogicProElements.heldTrackDisclosureValue(header: target.header, disclosure: target.disclosure, runtime: logic)
            }
            if !restorationStarted, acquired.contains(where: {
                CFEqual($0.target.header, target.header) && CFEqual($0.target.disclosure, target.disclosure)
            }) {
                exposure?.observeValue(header: target.header, disclosure: target.disclosure, value: observed)
            }
            return observed
        }

        private var forwardExposure: AXTrackBinding.Exposure? {
            restorationStarted || acquired.isEmpty ? nil : exposure
        }

        private func acquiredHeadersRemainOwned(_ headers: [AXUIElement]) -> Bool {
            guard let forwardExposure else { return true }
            forwardExposure.observeHeaders(headers)
            return !forwardExposure.hasObservedLoss
        }

        private func owned(target: Disclosure, expectedHeaders: [AXUIElement]?, expectedValue: Int?,
                           hiddenViewCleanup: Bool = false, stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            guard !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  await referenceIsCurrent(), logic.logicProPID() == pid,
                  isBoundHiddenMenuTarget(target) || logic.focusedApplicationPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp),
                  case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(app, kAXWindowsAttribute as String, runtime: logic.ax),
                  windows.filter({ CFEqual($0, window) }).count == 1,
                  isBoundHiddenMenuTarget(target) || AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: logic.ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  restorationStarted || acquired.isEmpty || exposure?.isCurrent == true,
                  AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                  case .success(.some(let doc)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  doc.utf8.elementsEqual(document.utf8), !AXLogicProElements.dialogPresent(runtime: logic),
                  AXLogicProElements.uniqueTrackHeaderRail(in: window, runtime: logic,
                    observingExposure: forwardExposure).map({ CFEqual($0, rail) }) == true,
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic,
                    observingExposure: forwardExposure),
                  acquiredHeadersRemainOwned(headers),
                  headers.filter({ CFEqual($0, target.header) }).count == 1,
                  acquired.allSatisfy({ entry in
                      headers.filter({ CFEqual($0, entry.target.header) }).count == 1
                          && (CFEqual(entry.target.disclosure, target.disclosure) || value(entry.target) == 1)
                  }),
                  same(headers.filter { row in originalHeaders.contains { CFEqual($0, row) } }, originalHeaders),
                  expectedHeaders.map({ same(headers, $0) }) ?? true else {
                Log.info("Population navigation ownership unavailable: process, project or held rail membership", subsystem: "ax"); return false
            }
            let sampledSelection = Self.selectedHeaders(headers, ax: logic.ax)
            guard let currentSelection = sampledSelection else { return false }
            if hiddenViewCleanup {
                guard restorationStarted, acquired.isEmpty, isBoundHiddenMenuTarget(target),
                      let originalSelectionPresentation,
                      Self.selectionPresentation(currentSelection, headers: headers, ax: logic.ax) == originalSelectionPresentation,
                      expectedValue == 0 ? same(currentSelection, selected) : selectedTracksRemainVisible(currentSelection) else { return false }
            } else if !same(currentSelection, selected) {
                Log.info("Population navigation ownership unavailable: selection", subsystem: "ax"); return false
            }
            guard let currentValue = value(target), expectedValue.map({ $0 == currentValue }) ?? true else {
                Log.info("Population navigation ownership unavailable: held control value", subsystem: "ax"); return false
            }
            let sampledViewport = Self.readViewport(window, ax: logic.ax, exposure: forwardExposure)
            guard let currentViewport = sampledViewport, currentViewport.count == viewport.count,
                  zip(currentViewport, viewport).allSatisfy({ CFEqual($0.control, $1.control) && $0.value == $1.value }) else {
                Log.info("Population navigation ownership unavailable: viewport", subsystem: "ax"); return false
            }
            guard let currentTransport = try? AXLogicProElements.observedTransportActivity(in: window, runtime: logic,
                    observingExposure: forwardExposure,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  CFEqual(currentTransport.controlBar, transport.controlBar), CFEqual(currentTransport.play, transport.play),
                  CFEqual(currentTransport.record, transport.record), !currentTransport.isPlaying, !currentTransport.isRecording else {
                Log.info("Population navigation ownership unavailable: transport", subsystem: "ax"); return false
            }
            guard let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(focus, observedFocus), !stop(), logic.logicProPID() == pid,
                  isBoundHiddenMenuTarget(target) || logic.focusedApplicationPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                Log.info("Population navigation ownership unavailable: final focus or process", subsystem: "ax"); return false
            }
            return true
        }

        private func frame(_ target: Disclosure) -> CGRect? {
            guard case .success(let position) = AXHelpers.getAttributeResult(target.disclosure, kAXPositionAttribute as String, runtime: logic.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                  case .success(let size) = AXHelpers.getAttributeResult(target.disclosure, kAXSizeAttribute as String, runtime: logic.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                  let point = AXHelpers.point(fromRawAttribute: position), let extent = AXHelpers.size(fromRawAttribute: size),
                  point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
                  extent.width > 0, extent.height > 0 else { return nil }
            return CGRect(origin: point, size: extent)
        }

        private func noEditingAttribute(_ field: AXUIElement, _ attribute: String) -> Bool {
            let reading = AXHelpers.getAttributeResult(field, attribute, runtime: logic.ax)
                as Result<AnyObject?, AXHelpers.AXStatusError>
            switch reading {
            case .success(nil): return true
            case .failure(let error) where error.isDefinitiveAbsence: return true
            default: return false
            }
        }

        private func isPassiveFocusControl(_ field: AXUIElement, expectedRole: String) -> Bool {
            guard let role = AXHelpers.getRole(field, runtime: logic.ax),
                  role == expectedRole,
                  role == kAXTextFieldRole as String || role == kAXRadioButtonRole as String,
                  AXHelpers.isAttributeSettable(field, kAXValueAttribute as String, runtime: logic.ax) == false,
                  case .success(.some(let value)) = AXHelpers.getAttributeResult(
                    field, kAXValueAttribute as String, runtime: logic.ax) as Result<NSNumber?, AXHelpers.AXStatusError>,
                  value.doubleValue == (role == kAXRadioButtonRole as String ? 1 : 0),
                  noEditingAttribute(field, kAXInsertionPointLineNumberAttribute as String),
                  noEditingAttribute(field, kAXSelectedTextRangeAttribute as String),
                  let owner: AXUIElement = AXHelpers.getAttribute(field, kAXWindowAttribute as String, runtime: logic.ax),
                  CFEqual(owner, window) else { return false }
            return true
        }

        private func passiveFocusControls(_ target: Disclosure) -> [PassiveFocusControl] {
            guard case .success(let children) = AXHelpers.childrenResult(target.header, runtime: logic.ax) else { return [] }
            var controls: [PassiveFocusControl] = []
            var roles = Set<String>()
            for child in children {
                guard let role = AXHelpers.getRole(child, runtime: logic.ax) else { return [] }
                if role == kAXTextFieldRole as String || role == kAXRadioButtonRole as String {
                    guard roles.insert(role).inserted else { return [] }
                    if isPassiveFocusControl(child, expectedRole: role) { controls.append(.init(element: child, role: role)) }
                }
            }
            return controls
        }

        /// A completed click can focus its pre-held passive name or selected radio.
        /// Their role/value and unique child identity remain required; this read
        /// exception grants no radio action, selection setter or keyboard command.
        func permitsHeldPassiveHeaderFocus() -> Bool {
            guard !releaseUnverified,
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  let completed = passiveClickFocus(matching: focus),
                  let held = completed.controls.first(where: { CFEqual($0.element, focus) }),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(currentApp, app),
                  AXHelpers.getAttribute(app, kAXFrontmostAttribute as String, runtime: logic.ax) as Bool? == true,
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  case .success(.some(let doc)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  doc.utf8.elementsEqual(document.utf8),
                  case .success(let rows) = AXHelpers.childrenResult(rail, runtime: logic.ax),
                  rows.filter({ CFEqual($0, completed.target.header) }).count == 1,
                  same(rows.filter { row in originalHeaders.contains { CFEqual($0, row) } }, originalHeaders),
                  let currentSelection = Self.selectedHeaders(rows, ax: logic.ax), same(currentSelection, selected),
                  completed.controls.filter({ CFEqual($0.element, focus) }).count == 1,
                  AXHelpers.getRole(focus, runtime: logic.ax) == held.role,
                  isPassiveFocusControl(focus, expectedRole: held.role),
                  case .success(let children) = AXHelpers.childrenResult(completed.target.header, runtime: logic.ax),
                  children.filter({ CFEqual($0, focus) }).count == 1,
                  passiveFocusControls(completed.target).contains(where: { CFEqual($0.element, focus) && $0.role == held.role }),
                  AXLogicProElements.heldTrackDisclosureValue(header: completed.target.header,
                    disclosure: completed.target.disclosure, runtime: logic) != nil,
                  let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(finalFocus, focus) else { return false }
            return true
        }

        private func passiveClickFocus(matching focus: AXUIElement) -> (target: Disclosure, controls: [PassiveFocusControl])? {
            if let completed = completedClickFocus,
               completed.controls.filter({ CFEqual($0.element, focus) }).count == 1 { return completed }
            // A nested owned click can leave focus on the outer control. Retain
            // only the exact already accepted focus, not arbitrary past labels.
            guard let accepted = acceptedPassiveClickFocus, CFEqual(focus, observedFocus),
                  accepted.controls.filter({ CFEqual($0.element, focus) }).count == 1 else { return nil }
            return accepted
        }

        private func click(target: Disclosure, expectedHeaders: [AXUIElement]?, expectedValue: Int?, stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            if let held = hiddenMenuPath, hiddenControl.map({ CFEqual($0, target.disclosure) }) == true {
                guard await owned(target: target, expectedHeaders: expectedHeaders, expectedValue: expectedValue, stoppingWhen: stop),
                      isBoundHiddenMenuTarget(target), let leaf = held.last,
                      !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      hiddenMenuActionBoundary(stoppingWhen: stop) else { return false }
                effects.navigationPerformed = true; effects.restoration = "not_restored"
                if !effects.attempted.contains("hidden_track_view") { effects.attempted.append("hidden_track_view") }
                // ACK is not the outcome. The caller still requires independent
                // held-control value, membership, focus and custody readback.
                _ = AXHelpers.performAction(leaf, kAXPressAction as String, runtime: logic.ax)
                completedClickFocus = (target, [])
                return true
            }
            guard await owned(target: target, expectedHeaders: expectedHeaders, expectedValue: expectedValue, stoppingWhen: stop),
                  let frame = frame(target),
                  let pair = mouse.prepareMouseClick(CGPoint(x: frame.midX, y: frame.midY), 1) else { return false }
            let controls = passiveFocusControls(target)
            guard
                  let hitTest = logic.ax.elementAtPosition,
                  case .success(.some(let hit)) = hitTest(app, CGPoint(x: frame.midX, y: frame.midY)), CFEqual(hit, target.disclosure),
                  await owned(target: target, expectedHeaders: expectedHeaders, expectedValue: expectedValue, stoppingWhen: stop),
                  !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  !stop(), logic.logicProPID() == pid, logic.focusedApplicationPID() == pid,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  self.frame(target) == frame,
                  case .success(.some(let finalHit)) = hitTest(app, CGPoint(x: frame.midX, y: frame.midY)), CFEqual(finalHit, target.disclosure),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax), CFEqual(focus, observedFocus),
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax), CFEqual(main, window),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax), CFEqual(focusedWindow, window),
                  AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                  case .success(.some(let doc)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  doc.utf8.elementsEqual(document.utf8) else { return false }
            // Deciding callbacks precede the final physical/scope sample. Nothing
            // reads AX or calls stop between this document proof and paired input.
            effects.navigationPerformed = true; effects.restoration = "not_restored"
            let effect = hiddenControl.map({ CFEqual($0, target.disclosure) }) == true ? "hidden_track_view" : "stack_disclosure"
            if !effects.attempted.contains(effect) { effects.attempted.append(effect) }
            guard pair.postDown() else { return false }
            releaseUnverified = true
            // Complete only this preconstructed click. An AX read, await, sleep,
            // or another authorization here can strand Down inside Logic's loop.
            guard pair.postUp() else { return false }
            releaseUnverified = false
            completedClickFocus = (target, controls)
            return true
        }

        /// Posting the paired events does not mean Logic has processed them.
        /// Observe only the same held disclosure, with at most three attempts;
        /// subsequent capture/inverse authorization still requires full custody.
        private func observeCompletedClick(target: Disclosure, expectedValue: Int,
                                           stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            for attempt in 0..<3 {
                guard !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      let observed = value(target) else { return false }
                if observed == expectedValue { return true }
                guard attempt < 2 else { return false }
                do { try await Task.sleep(for: .milliseconds(25)) }
                catch { return false }
            }
            return false
        }

        func expand(stoppingWhen stop: @Sendable () -> Bool) async {
            exposure = .init(header: header, disclosure: disclosure, runtime: logic, originalHeaders: originalHeaders,
                hiddenViewWindow: hiddenControl == nil ? nil : window)
            var beforeHeaders = originalHeaders
            while let target = pending.first {
                guard await click(target: target, expectedHeaders: beforeHeaders, expectedValue: 0, stoppingWhen: stop) else {
                    effects.reason = releaseUnverified ? "stack_mouse_release_unverified" : "stack_expansion_unverified"
                    return
                }
                guard await observeCompletedClick(target: target, expectedValue: 1, stoppingWhen: stop),
                      case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic,
                        observingExposure: forwardExposure),
                      same(headers.filter { row in beforeHeaders.contains { CFEqual($0, row) } }, beforeHeaders) else {
                    effects.reason = "stack_expansion_unverified"; return
                }
                guard acceptHeldGestureFocus(target),
                      await owned(target: target, expectedHeaders: headers, expectedValue: 1, stoppingWhen: stop) else {
                    exposure?.end()
                    effects.reason = "stack_navigation_ownership_lost"; return
                }
                if !acquired.isEmpty,
                   exposure?.retainAcquiredDisclosure(header: target.header, disclosure: target.disclosure) != true {
                    effects.reason = "stack_navigation_ownership_lost"; return
                }
                acquired.append(.init(target: target, beforeHeaders: beforeHeaders, afterHeaders: headers))
                pending.removeFirst()
                expandedHeaders = headers
                let effect = hiddenControl.map({ CFEqual($0, target.disclosure) }) == true ? "hidden_track_view" : "stack_disclosure"
                if !effects.changed.contains(effect) { effects.changed.append(effect) }
                let newlyExposed = headers.filter { row in !beforeHeaders.contains { CFEqual($0, row) } }
                guard let collapsed = Self.collapsedDisclosures(in: newlyExposed, runtime: logic) else {
                    effects.reason = "stack_disclosure_unreadable"; return
                }
                guard collapsed.allSatisfy({ next in
                    !pending.contains(where: { CFEqual($0.header, next.header) || CFEqual($0.disclosure, next.disclosure) })
                        && !acquired.contains(where: { CFEqual($0.target.header, next.header) || CFEqual($0.target.disclosure, next.disclosure) })
                }) else {
                    effects.reason = "stack_navigation_ownership_lost"; return
                }
                pending.append(contentsOf: collapsed)
                beforeHeaders = headers
            }
        }

        func restore(stoppingWhen stop: @Sendable () -> Bool) async -> SessionPopulationObservation.UIEffects {
            // Captured descendant authority ends before the first inverse gesture.
            // Cleanup is guarded by the separate held navigation facts below.
            exposure?.end()
            restorationStarted = true
            guard effects.navigationPerformed else { return effects }
            // Do not start another gesture while the earlier release is unverified.
            guard !releaseUnverified else { return effects }
            guard exposure?.hasObservedLoss != true else {
                effects.reason = effects.reason ?? "stack_navigation_ownership_lost"; return effects
            }
            if acquired.isEmpty, hiddenMenuPath != nil, let hiddenControl,
               effects.attempted.contains("hidden_track_view"), value((header, hiddenControl)) == 1 {
                if !effects.changed.contains("hidden_track_view") { effects.changed.append("hidden_track_view") }
                let target: Disclosure = (header, hiddenControl)
                guard case .read(let currentHeaders) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: logic),
                      await owned(target: target, expectedHeaders: currentHeaders, expectedValue: 1,
                        hiddenViewCleanup: true, stoppingWhen: stop),
                      isBoundHiddenMenuTarget(target), let leaf = hiddenMenuPath?.last,
                      !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      hiddenMenuActionBoundary(stoppingWhen: stop) else { return effects }
                // This ends no earlier loss and revives no row or snapshot.
                // Only presentation is inversed; no selection setter is used.
                _ = AXHelpers.performAction(leaf, kAXPressAction as String, runtime: logic.ax)
                guard await observeCompletedClick(target: target, expectedValue: 0, stoppingWhen: stop),
                      await owned(target: target, expectedHeaders: originalHeaders, expectedValue: 0,
                        hiddenViewCleanup: true, stoppingWhen: stop),
                      CFEqual(observedFocus, originalFocus) else { return effects }
                effects.restoration = "restored"
                return effects
            }
            guard expandedHeaders != nil, !acquired.isEmpty else {
                effects.reason = effects.reason ?? "stack_navigation_ownership_lost"; return effects
            }
            while let entry = acquired.last {
                guard await owned(target: entry.target, expectedHeaders: entry.afterHeaders, expectedValue: 1, stoppingWhen: stop) else {
                    effects.reason = "stack_navigation_ownership_lost"; return effects
                }
                if acquired.count == 1, hiddenControl.map({ CFEqual($0, entry.target.disclosure) }) == true,
                   !CFEqual(observedFocus, originalFocus) {
                    // Hide View recycles header labels. Restore the original
                    // workspace while the accepted passive label is still held,
                    // after every stack inverse and before that final view inverse.
                    guard await restoreOriginalWorkspaceFocus(beforeHiddenViewInverse: true, stoppingWhen: stop) else {
                        effects.reason = effects.reason ?? "keyboard_focus_not_restored"; return effects
                    }
                }
                guard await click(target: entry.target, expectedHeaders: entry.afterHeaders, expectedValue: 1, stoppingWhen: stop) else {
                    effects.reason = releaseUnverified ? "stack_mouse_release_unverified" : "stack_restoration_unverified"
                    return effects
                }
                guard await observeCompletedClick(target: entry.target, expectedValue: 0, stoppingWhen: stop),
                      acceptHeldGestureFocus(entry.target),
                      await owned(target: entry.target, expectedHeaders: entry.beforeHeaders, expectedValue: 0, stoppingWhen: stop) else {
                    effects.reason = "stack_restoration_unverified"; return effects
                }
                acquired.removeLast()
            }
            let focusRestored: Bool
            if CFEqual(observedFocus, originalFocus) { focusRestored = true }
            else { focusRestored = await restoreOriginalWorkspaceFocus(stoppingWhen: stop) }
            effects.restoration = focusRestored ? "restored" : "partially_restored"
            if !focusRestored { effects.reason = effects.reason ?? "keyboard_focus_not_restored" }
            return effects
        }

        private func restoreOriginalWorkspaceFocus(beforeHiddenViewInverse: Bool = false,
                                                   stoppingWhen stop: @Sendable () -> Bool) async -> Bool {
            let target: Disclosure
            let expectedHeaders: [AXUIElement]
            let expectedValue: Int
            if beforeHiddenViewInverse {
                guard restorationStarted, acquired.count == 1, let entry = acquired.first,
                      hiddenControl.map({ CFEqual($0, entry.target.disclosure) }) == true,
                      isBoundHiddenMenuTarget(entry.target), same(entry.beforeHeaders, originalHeaders) else { return false }
                target = entry.target; expectedHeaders = entry.afterHeaders; expectedValue = 1
            } else {
                guard acquired.isEmpty else { return false }
                target = (header, disclosure); expectedHeaders = originalHeaders; expectedValue = 0
            }
            guard !releaseUnverified, let originalWorkspacePath,
                  permitsHeldFocusRestoration(),
                  await owned(target: target, expectedHeaders: expectedHeaders, expectedValue: expectedValue, stoppingWhen: stop),
                  let path = Self.workspacePath(originalFocus, in: window, ax: logic.ax, permitsContainer: hiddenControl != nil), same(path, originalWorkspacePath),
                  logic.ax.attributeIsSettable(originalFocus, kAXFocusedAttribute as String) == true,
                  let current: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(current, observedFocus), permitsHeldFocusRestoration(), !stop(),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  focusRestorationActionBoundary(stoppingWhen: stop) else { return false }
            // This is the original physical workspace, not a key, coordinate or
            // a newly discovered focus target. Never overwrite foreign/editor focus.
            if !effects.attempted.contains("keyboard_focus_restoration") { effects.attempted.append("keyboard_focus_restoration") }
            guard AXHelpers.setAttribute(originalFocus, kAXFocusedAttribute as String,
                                         NSNumber(value: true), runtime: logic.ax) else { return false }
            for attempt in 0..<3 {
                guard !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax)
                else { return false }
                if CFEqual(focus, originalFocus) {
                    observedFocus = focus
                    guard await owned(target: target, expectedHeaders: expectedHeaders, expectedValue: expectedValue, stoppingWhen: stop),
                          let path = Self.workspacePath(originalFocus, in: window, ax: logic.ax, permitsContainer: hiddenControl != nil), same(path, originalWorkspacePath)
                    else { effects.reason = effects.reason ?? "stack_navigation_ownership_lost"; return false }
                    return true
                }
                guard CFEqual(focus, observedFocus), attempt < 2 else { return false }
                do { try await Task.sleep(for: .milliseconds(25)) }
                catch { return false }
            }
            return false
        }

        private func focusRestorationActionBoundary(stoppingWhen stop: @Sendable () -> Bool) -> Bool {
            // Even the stop callback consults held focus. Sample the document
            // and windows after every deciding callback/read, with no further
            // AX read or stop callback between this boundary and the setter.
            guard !stop(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  logic.logicProPID() == pid,
                  let currentApp = AXLogicProElements.appRoot(runtime: logic), CFEqual(app, currentApp),
                  let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(focus, observedFocus),
                  let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: logic.ax),
                  let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: logic.ax),
                  CFEqual(main, window), CFEqual(focusedWindow, window),
                  AXHelpers.getTitle(window, runtime: logic.ax)?.utf8.elementsEqual(title.utf8) == true,
                  case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: logic),
                  currentDocument.utf8.elementsEqual(document.utf8) else { return false }
            return true
        }

        private func permitsHeldFocusRestoration() -> Bool {
            if permitsHeldPassiveHeaderFocus() { return true }
            // The final paired inverse can leave focus on its exact disclosure,
            // not a label. Admit only that completed, accepted, collapsed target
            // for restoring the original workspace; owned() and the final action
            // boundary still verify the full scope before the focus setter.
            if !releaseUnverified, restorationStarted, acquired.isEmpty, hiddenControl == nil,
               let completed = completedClickFocus,
               CFEqual(completed.target.header, header), CFEqual(completed.target.disclosure, disclosure),
               let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
               CFEqual(focus, observedFocus), CFEqual(focus, disclosure),
               AXHelpers.getRole(focus, runtime: logic.ax) == kAXDisclosureTriangleRole as String,
               AXLogicProElements.heldTrackDisclosureValue(header: header, disclosure: disclosure, runtime: logic) == 0,
               let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
               CFEqual(finalFocus, focus) { return true }
            guard let hiddenControl, completedClickFocus.map({ CFEqual($0.target.disclosure, hiddenControl) }) == true,
                  let current: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax)
            else { return false }
            return CFEqual(current, hiddenControl) && CFEqual(observedFocus, hiddenControl)
        }

        /// A completed click may focus its held target. Corroborate that limited
        /// effect before accepting capture or authorizing another click.
        private func acceptHeldGestureFocus(_ target: Disclosure) -> Bool {
            guard let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: logic.ax),
                  CFEqual(focus, observedFocus) || CFEqual(focus, originalFocus)
                    || CFEqual(focus, target.disclosure) || CFEqual(focus, target.header)
                    || (completedClickFocus.map { CFEqual($0.target.header, target.header)
                        && CFEqual($0.target.disclosure, target.disclosure) } == true
                        && permitsHeldPassiveHeaderFocus()) else { return false }
            if let completed = completedClickFocus,
               completed.controls.filter({ CFEqual($0.element, focus) }).count == 1, permitsHeldPassiveHeaderFocus() {
                acceptedPassiveClickFocus = completed
            } else if !CFEqual(focus, observedFocus) {
                acceptedPassiveClickFocus = nil
            }
            if !CFEqual(focus, observedFocus), !effects.changed.contains("keyboard_focus") { effects.changed.append("keyboard_focus") }
            observedFocus = focus
            return true
        }

        func matchesRestoredTracks(_ tracks: [TrackState]?) -> Bool {
            guard let tracks, tracks.count == originalHeaders.count else { return false }
            return zip(tracks, originalHeaders).allSatisfy { row, header in
                row.physicalBinding.map { CFEqual($0.header, header) && $0.exposure == nil } == true
            }
        }
    }

    // MARK: - Verified track sort (#448)

    /// How many times the post-sort arrangement is read before the loop gives up waiting for it to
    /// move, and how long it waits before each read — including the first, which is the part #757
    /// was about. Four reads at 75 ms is 300 ms of watching, which covered every landing observed
    /// on an idle machine; the one drive that missed was under a full test suite.
    private static let trackSortSettleAttempts = 4
    private static let trackSortSettlePollMicroseconds: UInt32 = 75_000

    /// Whether an observation of the post-sort order may be accepted as settled.
    ///
    /// Two conditions, and the first is the one #757 was missing. An order still equal to the
    /// pre-sort order has not landed yet — `TrackSortVerifier.execute` refuses
    /// `beforeOrder == expectedOrder` as unobservable, so wherever State A is reachable the
    /// arrangement must move, and "unchanged" can never be the settled answer to a sort that is
    /// going to succeed. The second is the original rule: two consecutive identical reads.
    ///
    /// `internal` rather than folded into the loop because a rule that decides the verdict and
    /// cannot be reached from a test is how the previous one survived to a live drive.
    static func trackSortObservationIsSettled(
        current: [String],
        previous: [String]?,
        before: [String]
    ) -> Bool {
        current != before && previous == current
    }

    /// Drives the measured Track > Sort Tracks By leaf and verifies the complete
    /// post-write arrangement order. This path must not reuse the cache: the
    /// poller can legitimately still hold the pre-sort rail while this mutation
    /// needs the two reads that bracket its own menu press.
    static func defaultSortTracks(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let criterionRaw = params["criterion"],
              let criterion = TrackSortCriterion(rawValue: criterionRaw) else {
            return trackSortStateC(
                .invalidParams,
                criterion: params["criterion"],
                reason: "unknown_sort_criterion",
                hint: "sort_verified requires one of: \(TrackSortCriterion.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        guard let expectedOrder = decodeTrackSortExpectedOrder(params["expected_order_json"]) else {
            return trackSortStateC(
                .invalidParams,
                criterion: criterion.rawValue,
                reason: "expected_order_invalid",
                hint: "sort_verified requires expected_order as a non-empty array of unique track_ref values."
            )
        }
        guard !Task.isCancelled else {
            return trackSortRefusal(.cancelled, criterion: criterion, extras: [:])
        }

        var beforeTracks: [TrackState]?
        var afterTracks: [TrackState]?
        var afterReferences: [String]?
        var actuatedMenuItem: TrackSortVerifier.ActuatedMenuItem?
        var menuPressReportedSuccess: Bool?
        let beforeRead: TrackSortStateRead
        switch strictTrackSortStateRead(runtime: runtime) {
        case .read(let read):
            beforeRead = read
        case .unavailable:
            return trackSortStateC(
                .readbackUnavailable,
                criterion: criterion.rawValue,
                reason: "before_order_unreadable",
                hint: "sort_verified refused before the menu action because the full track order could not be read."
            )
        case .unreadable(let stage, let status):
            return trackSortStateC(
                .readbackUnavailable,
                criterion: criterion.rawValue,
                reason: "before_order_read_failed",
                hint: "sort_verified refused before the menu action because \(stage) could not be read (\(status)).",
                extras: ["read_failure_stage": stage, "read_failure_status": status]
            )
        case .stackStateUnreadable(let index, let name):
            return trackSortStateC(
                .readbackUnavailable,
                criterion: criterion.rawValue,
                reason: "track_stack_state_unreadable",
                hint: "sort_verified refused before the menu action because track \(index) ('\(name)') could not prove whether its stack is expanded.",
                extras: ["unreadable_stack": ["index": index, "name": name]]
            )
        case .collapsedStack(let index, let name):
            return trackSortStateC(
                .invalidParams,
                criterion: criterion.rawValue,
                reason: "collapsed_track_stack",
                hint: "sort_verified refused before the menu action because track \(index) ('\(name)') is a collapsed stack; expand it and re-read logic://tracks so the complete track order can be checked.",
                extras: ["collapsed_stack": ["index": index, "name": name]]
            )
        }
        beforeTracks = beforeRead.tracks
        let beforeOrder = trackSortBeforeOrder(
            tracks: beforeRead.tracks,
            expectedOrder: expectedOrder
        )
        guard case .matched(let beforeReferences) = beforeOrder else {
            switch beforeOrder {
            case .missing(let missing):
                return trackSortStateC(
                    .staleTargetReference,
                    criterion: criterion.rawValue,
                    reason: "expected_order_track_refs_not_in_before_order",
                    hint: "sort_verified expected_order names track references that are not in the current pre-sort order: \(missing.joined(separator: ", ")). Re-read logic://tracks and retry with its current track_ref values.",
                    extras: ["missing_track_refs": missing]
                )
            case .ambiguous(let references):
                return trackSortStateC(
                    .staleTargetReference,
                    criterion: criterion.rawValue,
                    reason: "duplicate_name_reference_identity_unprovable",
                    hint: "sort_verified refused before the menu action because duplicate track names have no issued per-track identity beyond index and name. Rename duplicates and re-read logic://tracks before sorting.",
                    extras: ["ambiguous_track_refs": references]
                )
            case .matched:
                preconditionFailure("The matched case is handled by the guard")
            }
        }
        let outcome = TrackSortVerifier.execute(
            criterion: criterion,
            expectedOrder: expectedOrder.map(\.reference),
            before: {
                .read(beforeReferences)
            },
            actuate: {
                let locale: String
                switch AXLogicProElements.logicUILocaleIdentifierRead(runtime: runtime) {
                case .locale(let observed):
                    locale = observed
                case .absent:
                    return .unmeasuredLocale("unknown")
                case .unreadable(let stage, let status):
                    return .menuReadFailed(stage: stage, status: status)
                }
                guard let measuredLabel = criterion.measuredLabel(for: locale) else {
                    return .unmeasuredLocale(locale)
                }
                let item: AXUIElement
                switch AXLogicProElements.menuItemRead(
                    labelPath: [
                        AXLocalePolicy.sortTracksMenuPath.bar,
                        AXLocalePolicy.sortTracksMenuPath.item,
                        criterion.label,
                    ],
                    runtime: runtime
                ) {
                case .found(let found):
                    item = found
                case .absent:
                    return .criterionLabelMissing(measuredLabel)
                case .unreadable(let stage, let status):
                    return .menuReadFailed(stage: stage, status: status)
                }
                let observedLabel: String
                switch AXHelpers.getAttributeResult(
                    item, kAXTitleAttribute as String, runtime: runtime.ax
                ) as Result<String?, AXHelpers.AXStatusError> {
                case .success(.some(let title)) where !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    observedLabel = title
                case .success(.some), .success(.none):
                    return .criterionUnverified("unknown")
                case .failure(let error) where error.isDefinitiveAbsence:
                    return .criterionUnverified("unknown")
                case .failure(let error):
                    return .menuReadFailed(stage: "AXMenuItem.AXTitle", status: error.diagnosticLabel)
                }
                guard let observedCriterion = TrackSortCriterion.measuredCriterion(
                    forObservedMenuItemLabel: observedLabel,
                    localeIdentifier: locale
                ) else {
                    return .criterionUnverified(observedLabel)
                }
                let observedItem = TrackSortVerifier.ActuatedMenuItem(
                    localizedLabel: observedLabel,
                    criterion: observedCriterion
                )
                guard observedCriterion == criterion else {
                    return .criterionMismatch(observedItem)
                }
                switch AXHelpers.getAttributeResult(
                    item, kAXEnabledAttribute as String, runtime: runtime.ax
                ) as Result<Bool?, AXHelpers.AXStatusError> {
                case .success(.some(true)):
                    break
                case .success(.some(false)):
                    return .disabledMenuItem(observedLabel)
                case .success(.none):
                    return .enabledStateUnavailable(observedLabel)
                case .failure(let error) where error.isDefinitiveAbsence:
                    return .enabledStateUnavailable(observedLabel)
                case .failure(let error):
                    return .menuReadFailed(stage: "AXMenuItem.AXEnabled", status: error.diagnosticLabel)
                }
                guard !Task.isCancelled else { return .cancelled }
                // The menu leaf does not expose a persistent "selected sort"
                // attribute. Its own title is therefore the only trustworthy
                // criterion witness: we record the title and its measured mapping
                // from this exact element before sending AXPress.
                actuatedMenuItem = observedItem
                let pressSucceeded = AXHelpers.performAction(
                    item, kAXPressAction as String, runtime: runtime.ax
                )
                menuPressReportedSuccess = pressSucceeded
                return pressSucceeded ? .actuated(observedItem) : .pressReportedFailure(observedItem)
            },
            after: {
                // #757. The previous loop took its first read with NO delay and accepted the first
                // pair of equal observations, so a sort landing slower than the poll had its own
                // PRE-sort order reported as settled. Measured live 2026-09-03: 1 of 5 drives, under
                // load, produced a receipt whose `after_tracks` were sorted beside an `after_order`
                // that was not — the two halves came from different reads.
                //
                // What makes the rule decidable is upstream: `TrackSortVerifier.execute` refuses
                // `beforeOrder == expectedOrder` as `alreadySortedCommandUnobservable`, so wherever
                // State A is reachable at all the arrangement MUST move. An observation still equal
                // to the before-order is therefore "has not landed", not "settled", and the loop
                // keeps watching. Once it differs, two consecutive equal reads settle it.
                //
                // If the budget expires with nothing having moved, the unchanged order is returned
                // rather than `.unavailable`: "the command produced no observable change" is an
                // answer, and `execute` turns it into a mismatch. Reporting it as unreadable would
                // claim the arrangement could not be read when it was read four times.
                var previousOrder: [String]?
                var settledOrder: [String]?
                for _ in 0..<trackSortSettleAttempts {
                    usleep(trackSortSettlePollMicroseconds)
                    guard case .read(let afterRead) = strictTrackSortStateRead(runtime: runtime) else {
                        return .unavailable
                    }
                    afterTracks = afterRead.tracks
                    guard let resolvedAfterReferences = trackSortAfterOrder(
                        afterNames: afterRead.tracks.map(\.name),
                        beforeNames: beforeRead.tracks.map(\.name),
                        beforeReferences: beforeReferences
                    ) else {
                        return .unavailable
                    }
                    afterReferences = resolvedAfterReferences
                    settledOrder = resolvedAfterReferences
                    if trackSortObservationIsSettled(
                        current: resolvedAfterReferences,
                        previous: previousOrder,
                        before: beforeReferences
                    ) {
                        return .read(resolvedAfterReferences)
                    }
                    previousOrder = resolvedAfterReferences
                }
                guard let settledOrder else { return .unavailable }
                return .read(settledOrder)
            }
        )

        let evidence = trackSortEvidence(
            criterion: criterion,
            expectedOrder: expectedOrder.map(\.reference),
            beforeOrder: beforeReferences,
            afterOrder: afterReferences,
            before: beforeTracks,
            after: afterTracks,
            actuatedMenuItem: actuatedMenuItem,
            menuPressReportedSuccess: menuPressReportedSuccess
        )
        switch outcome {
        case .verified:
            return .success(HonestContract.encodeStateA(extras: evidence))
        case .refused(let refusal):
            return trackSortRefusal(refusal, criterion: criterion, extras: evidence)
        case .uncertain(let uncertainty):
            return trackSortUncertain(uncertainty, extras: evidence)
        }
    }

    /// `allTrackHeaders()` intentionally returns an empty array for historic
    /// best-effort readers. A verified mutation cannot collapse unavailable or
    /// unreadable into that same empty value, so it uses the status-preserving
    /// rail reader and requires every row's identity to be readable.
    private struct TrackSortStateRead {
        let headers: [AXUIElement]
        let tracks: [TrackState]
    }

    private enum StrictTrackSortStateRead {
        case read(TrackSortStateRead)
        case unavailable
        case unreadable(stage: String, status: String)
        case stackStateUnreadable(index: Int, name: String)
        case collapsedStack(index: Int, name: String)
    }

    private enum TrackSortBeforeOrder {
        case matched([String])
        case missing([String])
        case ambiguous([String])
    }

    private static func strictTrackSortStateRead(
        runtime: AXLogicProElements.Runtime
    ) -> StrictTrackSortStateRead {
        let window: AXUIElement
        switch AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime) {
        case .found(let resolved):
            window = resolved
        case .absent:
            return .unavailable
        case .unreadable(let stage, let status):
            return .unreadable(stage: stage, status: status)
        }
        let headers: [AXUIElement]
        switch AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime) {
        case .read(let read):
            headers = read
        case .unavailable:
            return .unavailable
        case .unreadable(let stage, let status):
            return .unreadable(stage: stage, status: status)
        }
        let tracks = headers.enumerated().map { index, header in
            AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
        }
        for track in tracks {
            guard track.liveIdentityBacked,
                  !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unreadable(stage: "track_identity", status: "unreadable")
            }
            guard let isStackHeader = track.isStackHeader else {
                return .stackStateUnreadable(index: track.id, name: track.name)
            }
            guard !isStackHeader || track.stackCollapsed != nil else {
                return .stackStateUnreadable(index: track.id, name: track.name)
            }
            if isStackHeader, track.stackCollapsed == true {
                return .collapsedStack(index: track.id, name: track.name)
            }
        }
        return .read(TrackSortStateRead(headers: headers, tracks: tracks))
    }

    private static func decodeTrackSortExpectedOrder(_ raw: String?) -> [TrackSortExpectedTrack]? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TrackSortExpectedTrack].self, from: data),
              !decoded.isEmpty,
              decoded.allSatisfy({
                  !$0.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.beforeIndex >= 0
                      && !$0.beforeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              Set(decoded.map(\.reference)).count == decoded.count else {
            return nil
        }
        return decoded
    }

    /// TargetDescriptor currently issues only `(index, name)` for a track. That
    /// is not an identity when any name is duplicated: an out-of-band swap or
    /// delete/recreate can leave both fields unchanged. Refuse those projects
    /// rather than silently rebind a reference to whichever same-named header
    /// now occupies its old index.
    private static func trackSortBeforeOrder(
        tracks: [TrackState],
        expectedOrder: [TrackSortExpectedTrack]
    ) -> TrackSortBeforeOrder {
        guard expectedOrder.count == tracks.count else {
            return .missing(expectedOrder.map(\.reference))
        }
        let duplicateNames = Set(
            Dictionary(grouping: tracks, by: \.name)
                .filter { $0.value.count > 1 }
                .keys
        )
        if !duplicateNames.isEmpty {
            return .ambiguous(expectedOrder.compactMap {
                duplicateNames.contains($0.beforeName) ? $0.reference : nil
            })
        }
        var order = Array(repeating: "", count: tracks.count)
        var missing: [String] = []
        for expected in expectedOrder {
            guard expected.beforeIndex < tracks.count,
                  tracks[expected.beforeIndex].name.utf8.elementsEqual(expected.beforeName.utf8),
                  order[expected.beforeIndex].isEmpty else {
                missing.append(expected.reference)
                continue
            }
            order[expected.beforeIndex] = expected.reference
        }
        let unmatched = order.filter(\.isEmpty)
        guard missing.isEmpty, unmatched.isEmpty else {
            return .missing(missing.isEmpty ? expectedOrder.map(\.reference) : missing)
        }
        return .matched(order)
    }

    /// Recovers which reference each row holds AFTER the sort, by track name.
    ///
    /// This used to join on `AXUIElement` identity, guarded by a comment that called that an
    /// unmeasured assumption and predicted the failure would be Logic REPLACING a header object,
    /// costing us the identity and yielding State B. Driven live on Logic Pro 12.3 on 2026-09-03,
    /// the assumption fails the other way, which is worse: across a sort that demonstrably moved
    /// the rows, every after-element was `CFEqual` to the before-element at the SAME index while
    /// the names moved between them. Logic keeps the objects in place and swaps their content.
    ///
    /// An identity join therefore returns the identity permutation for every sort, `after_order`
    /// always equals `before_order`, and the comparison against the caller's expected order can
    /// only fail — so `sort_verified` could never award State A for any criterion.
    ///
    /// Names carry the join instead. That is sound here and only here: this operation has already
    /// refused a project whose track names are not unique, before any AX work. A duplicate name
    /// reaching this point means that guard did not hold, and is answered with `nil` (the caller's
    /// "unreadable") rather than an arbitrary pick.
    /// `internal`, not `private`: joining on names rather than element handles is what makes this
    /// decidable from values, and a rule that decides the verdict with no test is how the identity
    /// join survived to a live drive. See `Issue448TrackSortAfterOrderTests`.
    static func trackSortAfterOrder(
        afterNames: [String],
        beforeNames: [String],
        beforeReferences: [String]
    ) -> [String]? {
        guard afterNames.count == beforeNames.count,
              beforeReferences.count == beforeNames.count,
              Set(beforeNames).count == beforeNames.count else {
            return nil
        }
        var referenceByName: [Data: String] = [:]
        referenceByName.reserveCapacity(beforeNames.count)
        for (name, reference) in zip(beforeNames, beforeReferences) {
            guard referenceByName.updateValue(reference, forKey: Data(name.utf8)) == nil else {
                return nil
            }
        }
        var order: [String] = []
        order.reserveCapacity(afterNames.count)
        for name in afterNames {
            guard let reference = referenceByName[Data(name.utf8)] else {
                return nil
            }
            order.append(reference)
        }
        return order
    }

    private static func trackSortEvidence(
        criterion: TrackSortCriterion,
        expectedOrder: [String],
        beforeOrder: [String]?,
        afterOrder: [String]?,
        before: [TrackState]?,
        after: [TrackState]?,
        actuatedMenuItem: TrackSortVerifier.ActuatedMenuItem?,
        menuPressReportedSuccess: Bool?
    ) -> [String: Any] {
        [
            "operation": "track.sort_verified",
            "criterion": criterion.rawValue,
            "actuated_criterion": actuatedMenuItem?.criterion.rawValue ?? NSNull(),
            "actuated_menu_item_label": actuatedMenuItem?.localizedLabel ?? NSNull(),
            "menu_press_reported_success": menuPressReportedSuccess ?? NSNull(),
            "write_attempted": actuatedMenuItem != nil,
            "expected_order": expectedOrder,
            "before_order": beforeOrder ?? NSNull(),
            "after_order": afterOrder ?? NSNull(),
            // Preserve the full public order read, not just its name projection.
            // `id` is the observed arrangement index, and the remaining fields
            // are the stable `logic://tracks` row shape that accompanied it.
            "before_tracks": before.map(trackSortTrackList) ?? NSNull(),
            "after_tracks": after.map(trackSortTrackList) ?? NSNull(),
            "before_track_count": before?.count ?? NSNull(),
            "after_track_count": after?.count ?? NSNull(),
        ]
    }

    private static func trackSortTrackList(_ tracks: [TrackState]) -> [[String: Any]] {
        tracks.map { track in
            [
                "id": track.id,
                "name": track.name,
                "type": track.type.rawValue,
                "is_stack_header": track.isStackHeader ?? NSNull(),
                "stack_collapsed": track.stackCollapsed ?? NSNull(),
            ]
        }
    }

    private static func trackSortStateC(
        _ error: HonestContract.FailureError,
        criterion: String?,
        reason: String,
        hint: String,
        extras: [String: Any] = [:]
    ) -> ChannelResult {
        var details = extras
        details["operation"] = "track.sort_verified"
        details["criterion"] = criterion ?? NSNull()
        details["reason"] = reason
        details["write_attempted"] = false
        return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: details))
    }

    private static func trackSortRefusal(
        _ refusal: TrackSortVerifier.Refusal,
        criterion: TrackSortCriterion,
        extras: [String: Any]
    ) -> ChannelResult {
        switch refusal {
        case .cancelled:
            return trackSortStateC(
                .readbackUnavailable,
                criterion: criterion.rawValue,
                reason: "cancelled",
                hint: "sort_verified cancelled before the criterion menu action; no AXPress was sent.",
                extras: extras
            )
        case .beforeOrderUnreadable:
            return trackSortStateC(
                .readbackUnavailable,
                criterion: criterion.rawValue,
                reason: "before_order_unreadable",
                hint: "sort_verified refused before the menu action because the full track order could not be read.",
                extras: extras
            )
        case .expectedOrderIsNotBeforeOrder:
            return trackSortStateC(
                .invalidParams,
                criterion: criterion.rawValue,
                reason: "expected_order_not_full_before_order",
                hint: "sort_verified expected_order must name each current track reference exactly once, so an unrelated order cannot certify a wrong sort.",
                extras: extras
            )
        case .unmeasuredLocale(let locale):
            return trackSortStateC(
                .elementNotFound,
                criterion: criterion.rawValue,
                reason: "unmeasured_locale_missing_sort_menu_measurement",
                hint: "sort_verified has no measured Track > Sort Tracks By labels for Logic UI locale '\(locale)'; measure that locale before enabling this command.",
                extras: extras
            )
        case .criterionLabelMissing(let label):
            return trackSortStateC(
                .elementNotFound,
                criterion: criterion.rawValue,
                reason: "measured_criterion_label_absent",
                hint: "sort_verified expected the measured criterion label '\(label)' in the current Track > Sort Tracks By menu, but it was absent.",
                extras: extras
            )
        case .criterionUnverified(let label):
            return trackSortStateC(
                .elementNotFound,
                criterion: criterion.rawValue,
                reason: "actuated_criterion_unverified",
                hint: "sort_verified refused because the menu leaf title '\(label)' could not be mapped to a measured sort criterion.",
                extras: extras
            )
        case .criterionMismatch(let actual, let label):
            return trackSortStateC(
                .elementNotFound,
                criterion: criterion.rawValue,
                reason: "actuated_criterion_did_not_match_requested_criterion",
                hint: "sort_verified refused because menu leaf '\(label)' maps to '\(actual.rawValue)', not requested criterion '\(criterion.rawValue)'.",
                extras: extras
            )
        case .disabledMenuItem(let label):
            return trackSortStateC(
                .axWriteFailed,
                criterion: criterion.rawValue,
                reason: "sort_menu_item_disabled",
                hint: "sort_verified refused because the measured menu item '\(label)' was disabled; AXPress on a disabled item is not an action.",
                extras: extras
            )
        case .enabledStateUnavailable(let label):
            return trackSortStateC(
                .readbackUnavailable,
                criterion: criterion.rawValue,
                reason: "sort_menu_item_enabled_state_unreadable",
                hint: "sort_verified refused because the enabled state of menu item '\(label)' was unavailable; no AXPress was sent.",
                extras: extras
            )
        case .menuReadFailed(let stage, let status):
            return trackSortStateC(
                .readbackUnavailable,
                criterion: criterion.rawValue,
                reason: "sort_menu_read_failed",
                hint: "sort_verified refused because \(stage) could not be read (\(status)); no AXPress was sent.",
                extras: extras
            )
        }
    }

    private static func trackSortUncertain(
        _ uncertainty: TrackSortVerifier.Uncertainty,
        extras: [String: Any]
    ) -> ChannelResult {
        var details = extras
        details["write_attempted"] = true
        details["safe_to_retry"] = false
        switch uncertainty {
        case .afterOrderUnreadable:
            details["detail"] = "after_order_unreadable"
            details["project_state"] = "unknown"
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: details))
        case .afterOrderMismatch:
            details["detail"] = "after_order_did_not_match_requested_criterion"
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: details))
        case .alreadySortedCommandUnobservable:
            // The arrangement was read, four times, and matched the request. What cannot be read is
            // whether the menu command did anything, because a correct sort of a sorted project is
            // a no-op. `readbackUnavailable` said the opposite of what happened (#448).
            details["detail"] = "already_sorted_command_unobservable"
            return .success(HonestContract.encodeStateB(reason: .noopUnobservable, extras: details))
        }
    }

    static func defaultGetSelectedTrack(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.extractSelectedState(header, runtime: runtime.ax) == true {
                let track = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    static func defaultSelectTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
            // v3.1.0 (T3) — missing track is a hard failure; no retry will
            // help. Keep legacy error-string path for ChannelResult.error so
            // existing callers that look at .isSuccess still see a failure,
            // but encode the structured envelope.
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) not found",
                extras: ["requested": index]
            ))
        }
        // v3.0.3+ — activate Logic so the frontmost-dependent AX selection can
        // land, then go through the AX-native selection ladder (ADR-001: no
        // coordinate fallback — fail closed if every AX step is rejected).
        _ = ProcessUtils.Runtime.production.activateLogicPro()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to select track \(index) via the AX selection ladder",
                extras: ["requested": index]
            ))
        }

        // v3.1.0 (T3) — verifyTrackSelection already retries 6× at 100ms
        // intervals internally (see TrackSelectionVerification). We surface
        // the outcome as a 3-state Honest Contract response rather than the
        // legacy free-form text. Existing `verified:true/false` JSON path
        // stays valid because the new envelope still contains those keys.
        let verification = await verifyTrackSelection(index: index, runtime: runtime)
        let base: [String: Any] = ["requested": index, "selected": index]
        switch verification {
        case .verified:
            return .success(HonestContract.encodeStateA(extras: base.merging([
                "observed": index
            ]) { _, new in new }))
        case .selectionMetadataUnavailable:
            // Ralph-2 / W1 (guardian iter2) — retry budget exhausted: the
            // read-back metadata never surfaced across 6×100ms attempts.
            // Docs (README, CHANGELOG, API.md, PRD) consistently
            // promise `retry_exhausted` for this case; emitting
            // `readback_unavailable` here would make the enum an orphan.
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: base.merging(["observed": NSNull()]) { _, new in new }
            ))
        case .mismatch(let selectedIndex):
            // v3.1.0 (Ralph-2 / P2-2) — read-back succeeded but returned a
            // different index. That's the textbook `readback_mismatch` case
            // per docs/API.md (State B taxonomy).
            // `retry_exhausted` stays reserved for
            // `.selectionMetadataUnavailable` — read-back metadata never
            // appeared across the retry budget. Clients switching on
            // `reason` can now pick accept-and-diverge (mismatch) vs.
            // back-off-and-refetch (retry_exhausted) correctly.
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: base.merging([
                    "observed": selectedIndex as Any? ?? NSNull()
                ]) { _, new in new }
            ))
        case .notExclusive(let alsoSelected, let unreadable):
            // #1097: the target is selected, and other rows are too or did not read. delete and
            // duplicate refuse anything but State A, so they do not act on those rows as well.
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: base.merging([
                    "observed": index,
                    "also_selected": alsoSelected,
                    "selection_unreadable": unreadable,
                ]) { _, new in new }
            ))
        case .trackDisappeared:
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) disappeared during selection verification",
                extras: base
            ))
        }
    }

    static func defaultSetTrackToggle(
        params: [String: String],
        button buttonName: String,
        runtime: AXLogicProElements.Runtime = .production,
        keyRuntime: AXMouseHelper.Runtime = .production,
        processRuntime: ProcessUtils.Runtime = .production,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": { AXLogicProElements.findTrackMuteButton(trackIndex: $0, runtime: runtime) }
        case "Solo": { AXLogicProElements.findTrackSoloButton(trackIndex: $0, runtime: runtime) }
        case "Record": { AXLogicProElements.findTrackArmButton(trackIndex: $0, runtime: runtime) }
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        let desired: Bool = (params["enabled"] ?? "true") == "true"
        let baseExtras: [String: Any] = [
            "track": index,
            "button": buttonName,
            "requested": desired,
            "verification_source": "ax_value"
        ]

        // Success is judged ONLY by re-reading this checkbox AXValue (the
        // observed effect), NEVER by an AX action's return code: on real Logic
        // 12.x the track-header M/S/R actions return non-zero even when they
        // no-op (#106 sites-6/7), so trusting the return would fabricate a
        // State A on a control that never moved.
        func readValue() -> Bool? {
            guard let v = AXHelpers.getValue(button, runtime: runtime.ax) else { return nil }
            if let n = v as? NSNumber { return n.boolValue }
            if let b = v as? Bool { return b }
            if let i = v as? Int { return i != 0 }
            if let s = v as? String {
                switch s.lowercased() {
                case "1", "true": return true
                case "0", "false": return false
                default: return nil
                }
            }
            return nil
        }

        // Toggle-from-read: already at the desired state → verified no-op. No
        // rung runs, so no keyboard/coordinate event is ever fired.
        if let current = readValue(), current == desired {
            return .success(HonestContract.encodeStateA(extras: baseExtras.merging([
                "observed": desired,
                "action": "no-op"
            ]) { _, new in new }))
        }

        func pollMatched(deadlineMs: Int) -> Bool {
            let deadline = Date().addingTimeInterval(Double(deadlineMs) / 1000.0)
            repeat {
                if let after = readValue(), after == desired { return true }
                usleep(40_000)
            } while Date() < deadline
            return false
        }

        // #106 / ADR-001: coordinate-free per-op actuator ladder. Every rung
        // actuates WITHOUT any mouse/coordinate primitive (the former HID-click
        // last resort is deleted). Live-verified on Logic 12.3: SOLO flips on
        // AXPress; MUTE needs exclusive-select + key 'm'; ARM needs
        // exclusive-select + the configurable "Toggle Track Record Enable" key
        // chord. The read-back — not each rung's return value — decides State A.
        //
        // ARM honesty baseline: capture whether transport is ALREADY recording
        // (nil = UNREADABLE, kept distinct from readable-false) so a mis-assigned
        // arm key that instead triggers transport Record is caught by the guard
        // below, and an unreadable transport can never be coerced to "not
        // recording" under an arm State-A claim (#2).
        let recordingBaselineState: Bool? =
            (buttonName == "Record") ? transportRecordingState(runtime: runtime) : nil

        let outcome = runTrackToggleLadder(
            rungs: trackToggleLadder(
                button: button,
                buttonName: buttonName,
                index: index,
                desired: desired,
                readValue: readValue,
                runtime: runtime,
                keyRuntime: keyRuntime,
                processRuntime: processRuntime,
                environment: environment
            ),
            desired: desired,
            readValue: readValue,
            pollMatched: { pollMatched(deadlineMs: $0) }
        )

        switch outcome {
        case .refused(let refusal):
            // A refused rung posted NO key, so our action caused no transport
            // side effect — return the distinct fail-closed reason directly.
            return .error(HonestContract.encodeStateC(
                error: refusal.error,
                hint: refusal.hint,
                extras: baseExtras.merging(refusal.extras) { _, new in new }
            ))

        case .landed(let action):
            // ARM honesty guard — only when we would otherwise claim State A.
            if buttonName == "Record" {
                guard let post = transportRecordingState(runtime: runtime) else {
                    // Transport Record UNREADABLE post-actuate: we cannot prove the
                    // arm key did not instead start transport recording, so never
                    // claim a clean arm (#2). Fail closed, distinct from State A.
                    return .error(HonestContract.encodeStateC(
                        error: .transportStateUnknown,
                        hint: armTransportUnknownHint(index: index),
                        extras: baseExtras.merging(["transport_state": "unknown"]) { _, new in new }
                    ))
                }
                if post, recordingBaselineState != true {
                    // A mis-assigned key started transport Record instead of
                    // record-enable — fail closed even if the checkbox reads armed.
                    return .error(HonestContract.encodeStateC(
                        error: .axWriteFailed,
                        hint: armRecordingStartedHint(index: index),
                        extras: baseExtras.merging(["recording_started": true]) { _, new in new }
                    ))
                }
                if recordingBaselineState == true, !post {
                    return .error(HonestContract.encodeStateC(
                        error: .readbackMismatch,
                        hint: armRecordingStoppedHint(index: index),
                        extras: baseExtras.merging(["recording_stopped": true]) { _, new in new }
                    ))
                }
            }
            return .success(HonestContract.encodeStateA(extras: baseExtras.merging([
                "observed": desired,
                "action": action
            ]) { _, new in new }))

        case .exhausted:
            // Even a FAILED arm may have started transport Record via a
            // mis-assigned key — surface that distinctly when it is readable.
            if buttonName == "Record",
               let post = transportRecordingState(runtime: runtime),
               post, recordingBaselineState != true {
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: armRecordingStartedHint(index: index),
                    extras: baseExtras.merging(["recording_started": true]) { _, new in new }
                ))
            }
            // Fail closed — NEVER a coordinate fallback.
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: trackToggleFailHint(buttonName: buttonName, index: index, desired: desired),
                extras: baseExtras
            ))
        }
    }

    // MARK: - Ladder runner (#3 double-toggle halt barrier)

    enum RungOutcome {
        case actuated
        case alreadyLanded
        case landed
        case refused(RungRefusal)
        case exhausted
    }

    /// A fail-closed refusal from a rung: a distinct Honest-Contract error, an
    /// operator-facing hint, and structured extras merged into the State C body.
    struct RungRefusal {
        let error: HonestContract.FailureError
        let hint: String
        let extras: [String: Any]
    }

    /// Terminal result of running the actuator ladder.
    enum LadderOutcome {
        case landed(action: String)
        case refused(RungRefusal)
        case exhausted
    }

    /// Run the actuator ladder with a HALT BARRIER between rungs (#3). Every rung
    /// is a TOGGLE, not a set: if an earlier rung actually flipped the control but
    /// its AXValue published only AFTER that rung's poll window closed, firing the
    /// next toggle rung would flip it straight BACK. So BEFORE actuating each rung
    /// (which includes re-reading after a prior rung's poll failed) we re-read the
    /// live value; if it ALREADY equals `desired`, we STOP and report State A
    /// attributed to the rung that actually moved it — never actuating again.
    /// `readValue` / `pollMatched` are injected so the barrier is unit-testable
    /// without live timing.
    static func runTrackToggleLadder(
        rungs: [TrackToggleRung],
        desired: Bool,
        readValue: () -> Bool?,
        pollMatched: (Int) -> Bool
    ) -> LadderOutcome {
        var lastActuated: String?
        for rung in rungs {
            // #3 halt barrier — re-read before EVERY actuation.
            if let current = readValue(), current == desired {
                return .landed(action: lastActuated ?? rung.name)
            }
            switch rung.actuate(pollMatched) {
            case .refused(let refusal):
                return .refused(refusal)
            case .alreadyLanded:
                return .landed(action: lastActuated ?? rung.name)
            case .landed:
                return .landed(action: rung.name)
            case .exhausted:
                return .exhausted
            case .actuated:
                lastActuated = rung.name
                if pollMatched(rung.pollMs) {
                    return .landed(action: rung.name)
                }
            }
        }
        return .exhausted
    }

    // MARK: - Coordinate-free track-toggle actuator (#106 / ADR-001)

    /// `kVK_ANSI_M` (46) — Logic's default "Mute selected tracks" key command.
    /// With the target track exclusively selected, pressing it flips that
    /// track-header Mute checkbox (live-verified on Logic 12.3); AXPress on the
    /// checkbox itself is a no-op.
    static let trackMuteKeyCode: CGKeyCode = 46

    /// `kVK_ANSI_S` (1) — Logic's default "Solo selected tracks" key command.
    /// AXPress on the track-header Solo checkbox is a live no-op on Logic 12.3.
    static let trackSoloKeyCode: CGKeyCode = 1

    static let logicFrontmostPollIntervalMicros: useconds_t = 100_000
    static let logicFrontmostStabilityPollCount = 4
    static let logicFrontmostStabilityTimeoutMicros: useconds_t = 2_000_000
    static let logicKeyWindowSettleMicros: useconds_t = 800_000
    static let syntheticKeyRetryAttempts = 3
    static let syntheticKeyRetryPollMs = 600
    static let syntheticKeyRetrySettleMicros: useconds_t = 200_000

    /// `kVK_ANSI_R` (15) — bare 'r' IS transport Record. NEVER post it for arm
    /// (it would start recording instead of toggling record-enable).
    static let transportRecordKeyCode: CGKeyCode = 15

    /// Default key CHORD for the record-ARM key command: Ctrl+Shift+E
    /// (`kVK_ANSI_E` (14) + control + shift). Live-confirmed target: Logic's
    /// "Toggle Track Record Enable" command, which toggles record-enable on the
    /// SELECTED track (distinct from transport Record). It ships UNASSIGNED, so
    /// the operator assigns it to this chord (or overrides via
    /// `LOGIC_PRO_MCP_ARM_KEYCODE` / `LOGIC_PRO_MCP_ARM_KEY_MODIFIERS`).
    static let defaultArmKeyCode: CGKeyCode = 14
    static let defaultArmModifiers: CGEventFlags = [.maskControl, .maskShift]

    /// Environment override keys for the record-arm chord.
    static let armKeyCodeEnvVar = "LOGIC_PRO_MCP_ARM_KEYCODE"
    static let armKeyModifiersEnvVar = "LOGIC_PRO_MCP_ARM_KEY_MODIFIERS"

    /// Outcome of resolving the record-arm key chord from the environment. A
    /// PRESENT-but-unparseable override is a CONFIGURATION ERROR — surfaced so the
    /// arm path fails closed with `arm_key_config_invalid` instead of silently
    /// falling back to the default chord or dropping unknown modifier tokens (#7).
    /// An ABSENT override still uses the built-in default.
    enum ArmChordResolution: Equatable {
        case resolved(code: CGKeyCode, flags: CGEventFlags)
        case invalidKeyCode(String)
        case invalidModifierToken(String)
    }

    /// Resolve the record-arm chord. `LOGIC_PRO_MCP_ARM_KEYCODE` (decimal virtual
    /// keycode) and `LOGIC_PRO_MCP_ARM_KEY_MODIFIERS` (comma list of
    /// control/shift/option/command) override the Ctrl+Shift+E default:
    ///   - ABSENT var → the built-in default (correct, silent).
    ///   - present + valid → parsed value.
    ///   - present keycode that does not parse → `.invalidKeyCode` (NO silent
    ///     fallback to 14).
    ///   - present modifiers with an unknown token → `.invalidModifierToken` (NO
    ///     silently dropped token).
    ///   - present-but-EMPTY modifiers → `.resolved` with no flags (a bare key),
    ///     which the arm path then refuses as unsafe.
    /// Injectable environment for deterministic tests.
    static func resolveArmChord(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ArmChordResolution {
        let code: CGKeyCode
        if let raw = environment[armKeyCodeEnvVar] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let parsed = UInt16(trimmed) else { return .invalidKeyCode(trimmed) }
            code = CGKeyCode(parsed)
        } else {
            code = defaultArmKeyCode
        }

        let flags: CGEventFlags
        if let raw = environment[armKeyModifiersEnvVar] {
            var parsed: CGEventFlags = []
            for token in raw.split(separator: ",") {
                let name = token.trimmingCharacters(in: .whitespaces).lowercased()
                if name.isEmpty { continue }
                switch name {
                case "control", "ctrl": parsed.insert(.maskControl)
                case "shift": parsed.insert(.maskShift)
                case "option", "opt", "alt": parsed.insert(.maskAlternate)
                case "command", "cmd": parsed.insert(.maskCommand)
                default: return .invalidModifierToken(name)
                }
            }
            flags = parsed
        } else {
            flags = defaultArmModifiers
        }
        return .resolved(code: code, flags: flags)
    }

    /// Single source of truth for arm-chord modifier validity: a bare key (no
    /// modifiers) is unsafe as an arm chord — bare 'r' IS transport Record and any
    /// bare key triggers a global command. Both the runtime arm actuator and the
    /// consent-based key-command auto-setup (#413) refuse such a chord.
    static func armChordModifiersAreUnsafe(_ flags: CGEventFlags) -> Bool {
        flags.isEmpty
    }

    /// Read whether Logic's transport is currently RECORDING (control-bar Record
    /// checkbox), returning nil when it is UNREADABLE. The arm honesty guard MUST
    /// keep nil DISTINCT from a readable `false`: coercing nil→false would let an
    /// unreadable transport masquerade as "not recording" under a State-A arm
    /// claim (#2).
    static func transportRecordingState(runtime: AXLogicProElements.Runtime) -> Bool? {
        AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportRecordControl, runtime: runtime
        )
    }

    /// Ground-truth verification for the arm-key auto-setup (#413): drive a real
    /// record-arm on track 0 through ONLY the given key chord and report whether
    /// record-enable actually flipped — then restore the arm state, the prior
    /// track selection, and the transport recording state, verifying each restore
    /// by read-back.
    ///
    /// The actuation is pinned to the CGEvent key chord alone — never AXPress and
    /// never the fallback toggle ladder. This is load-bearing: the ladder's other
    /// rungs (and a live control surface such as a virtual MCU port) can move
    /// record-enable WITHOUT the key command, which would let the verify pass on a
    /// host where the chord is unmapped and report a false "already configured".
    /// A flip observed here therefore proves the key command specifically is bound
    /// to the record-arm command. The typed result separates a cleanly UNMAPPED
    /// chord (no flip, nothing left mutated — safe to proceed to GUI assignment)
    /// from a PARTIAL restore (a flip or restore failed, host left dirty — must
    /// fail closed), a POST failure, and an unavailable environment, so a partially
    /// mutated host never receives further mutations.
    /// Functional arm-chord verification: flip record-enable with ONLY the chord,
    /// then restore it with the SAME chord, observing both transitions by AX
    /// read-back.
    ///
    /// #415 verify-causality: `.verified` requires TWO opposite chord-correlated
    /// transitions — the flip leg AND the restore leg — each gated by an
    /// arm-not-yet-at-target read immediately before a SUCCESSFUL post (see
    /// `postArmChordAndObserveFlip`). The restore leg IS the "second confirming
    /// flip" #415 asked to consider: a SINGLE external record-enable change
    /// landing inside one observation window (or a settle gap) can at most
    /// satisfy one leg, so with an unmapped chord it degrades to
    /// `.partialRestore` (fail-closed — never GUI assignment, never a false
    /// `.verified`); before any post it is never credited at all. The residual
    /// is DOUBLE external interference — two opposite flips, each landing inside
    /// its own ≤3×600ms window, mimicking both legs — which is observationally
    /// indistinguishable from the chord by AX read-back and is accepted as
    /// irreducible for this surface (a stricter single-attempt window would not
    /// remove it and costs live reliability against slow CGEvent delivery).
    static func armSetupVerify(
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        runtime: AXLogicProElements.Runtime = .production,
        keyRuntime: AXMouseHelper.Runtime = .production,
        processRuntime: ProcessUtils.Runtime = .production,
        // Once the command deadline fires this returns true; no verification chord
        // (flip or restore) is posted after it (#413).
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ArmKeyCommandSetup.VerifyResult {
        // No verification chord after the deadline — post ZERO keys.
        if isCancelled() { return .couldNotPost }
        guard let priorTransport = transportRecordingState(runtime: runtime) else { return .environmentUnavailable }
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        let priorSelection = headers.map {
            AXValueExtractors.extractSelectedState($0, runtime: runtime.ax)
        }
        guard !headers.isEmpty, priorSelection.allSatisfy({ $0 != nil }),
              let trackHeaders = AXLogicProElements.getTrackHeaders(runtime: runtime) else {
            return .environmentUnavailable
        }
        let selectedHeaders = priorSelection.enumerated().compactMap { offset, selected in
            selected == true ? headers[offset] : nil
        }
        guard let armButton = AXLogicProElements.findTrackArmButton(trackIndex: 0, runtime: runtime),
              let curNum = AXHelpers.getValue(armButton, runtime: runtime.ax) as? NSNumber else {
            return .environmentUnavailable
        }
        let current = curNum.intValue != 0

        // Chord-ONLY flip to the opposite arm state.
        let flip = postArmChordAndObserveFlip(
            armButton: armButton, expected: !current,
            keyCode: keyCode, modifiers: modifiers,
            runtime: runtime, keyRuntime: keyRuntime, processRuntime: processRuntime,
            isCancelled: isCancelled
        )

        // If the chord flipped arm, restore it via the SAME chord and confirm.
        var armRestoreFailed = false
        if flip == .flipped {
            if isCancelled() {
                // The deadline fired after the flip — do NOT post a restore chord
                // (no new key after the deadline). Arm is left flipped; report it
                // honestly as a partial restore rather than claiming success.
                armRestoreFailed = true
            } else {
                armRestoreFailed = postArmChordAndObserveFlip(
                    armButton: armButton, expected: current,
                    keyCode: keyCode, modifiers: modifiers,
                    runtime: runtime, keyRuntime: keyRuntime, processRuntime: processRuntime,
                    isCancelled: isCancelled
                ) != .flipped
            }
        }

        // Restore the user's prior track selection (the drive exclusive-selected
        // track 0) and the transport recording state — AX-only, posts no key.
        let selectionRestored = restoreTrackSelection(
            headers: headers, priorSelection: priorSelection,
            selectedHeaders: selectedHeaders, trackHeaders: trackHeaders, runtime: runtime
        )
        let transportRestored = restoreTransportRecordingState(priorTransport, runtime: runtime)

        switch flip {
        case .flipped:
            if armRestoreFailed {
                return .partialRestore(detail: "record-enable was flipped to test the chord but could not be restored")
            }
            if !selectionRestored { return .partialRestore(detail: "the prior track selection could not be restored") }
            if !transportRestored { return .partialRestore(detail: "the transport recording state could not be restored") }
            return .verified
        case .postedNoFlip:
            // Nothing on the arm moved (unmapped), but the selection/transport the
            // drive touched must restore — otherwise the host is left dirty.
            if !selectionRestored { return .partialRestore(detail: "the prior track selection could not be restored") }
            if !transportRestored { return .partialRestore(detail: "the transport recording state could not be restored") }
            return .unmapped
        case .couldNotPost:
            if !selectionRestored { return .partialRestore(detail: "the prior track selection could not be restored") }
            if !transportRestored { return .partialRestore(detail: "the transport recording state could not be restored") }
            return .couldNotPost
        }
    }

    /// Restore the exact prior track selection captured before an exclusive-select
    /// side effect. AX-only (AXSelectedChildren + per-header AXSelected), posts no
    /// key. Returns whether the observed selection matches the captured prior.
    private static func restoreTrackSelection(
        headers: [AXUIElement],
        priorSelection: [Bool?],
        selectedHeaders: [AXUIElement],
        trackHeaders: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        _ = AXHelpers.setAttribute(
            trackHeaders, kAXSelectedChildrenAttribute, selectedHeaders as CFArray, runtime: runtime.ax
        )
        for (offset, header) in headers.enumerated() {
            _ = AXHelpers.setAttribute(
                header, kAXSelectedAttribute,
                priorSelection[offset] == true ? kCFBooleanTrue : kCFBooleanFalse,
                runtime: runtime.ax
            )
        }
        for attempt in 0..<4 {
            let observed = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
            if observed == priorSelection { return true }
            if attempt < 3 { usleep(80_000) }
        }
        return false
    }

    /// Exclusive-select track 0, confirm a safe keyboard focus, then post ONLY the
    /// CGEvent key chord (no AXPress, no other rung) and observe the arm read-back
    /// reach `expected`. The selection/focus gates are AX-only and observational,
    /// so they post no key and cannot themselves move arm — the only actuation is
    /// the chord, which is what makes an observed flip prove the key command.
    ///
    /// Success requires a CHORD-CAUSED transition: arm must read NOT-yet-`expected`
    /// immediately before a SUCCESSFUL post, then reach `expected` after it. An arm
    /// already at `expected` before any post is never credited — otherwise an
    /// external flip (a live control surface, another agent) could fabricate a pass
    /// for an unmapped chord. Only a post whose `postFlaggedKeyEvent` returned true
    /// enables the late-published double-toggle credit, so a FAILED post plus an
    /// external transition is never mistaken for chord causality. The result
    /// distinguishes a flip, a posted-but-no-flip (unmapped), and a could-not-post.
    private enum ChordFlipResult { case flipped, postedNoFlip, couldNotPost }

    private static func postArmChordAndObserveFlip(
        armButton: AXUIElement,
        expected: Bool,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        runtime: AXLogicProElements.Runtime,
        keyRuntime: AXMouseHelper.Runtime,
        processRuntime: ProcessUtils.Runtime,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ChordFlipResult {
        func armValue() -> Bool? {
            (AXHelpers.getValue(armButton, runtime: runtime.ax) as? NSNumber)?.boolValue
        }
        // No chord after the command deadline — post ZERO keys.
        if isCancelled() { return .couldNotPost }
        // The arm key command acts on the SELECTED track: exclusively select track
        // 0 and prove Logic is stably frontmost before any post.
        if confirmExclusiveSelectionRefusal(
            index: 0, runtime: runtime, processRuntime: processRuntime,
            sleepMicros: keyRuntime.sleepMicros
        ) != nil { return .couldNotPost }

        var anyPosted = false
        for attempt in 0..<syntheticKeyRetryAttempts {
            // Double-toggle guard: a SUCCESSFUL post THIS call already happened and
            // its flip published late — credit it without re-posting.
            if anyPosted, armValue() == expected { return .flipped }
            guard processRuntime.logicIsFrontmost(),
                  selectionIsExclusive(index: 0, runtime: runtime) else {
                return anyPosted ? .postedNoFlip : .couldNotPost
            }
            if syntheticKeyFocusRefusal(runtime: runtime) != nil {
                return anyPosted ? .postedNoFlip : .couldNotPost
            }
            // Causality: arm must be NOT-yet-`expected` right before the post, so an
            // arm already at `expected` (an external flip) is never chord-credited.
            guard armValue() != expected else {
                return anyPosted ? .postedNoFlip : .couldNotPost
            }
            // No new key after the deadline (checkpoint immediately before the post).
            if isCancelled() { return anyPosted ? .postedNoFlip : .couldNotPost }
            // Only a SUCCESSFUL post can be credited for a subsequent transition.
            let posted = keyRuntime.postFlaggedKeyEvent(keyCode, modifiers)
            anyPosted = anyPosted || posted
            guard posted else {
                if attempt < syntheticKeyRetryAttempts - 1 {
                    keyRuntime.sleepMicros(syntheticKeyRetrySettleMicros)
                    continue
                }
                return anyPosted ? .postedNoFlip : .couldNotPost
            }
            let deadline = Date().addingTimeInterval(Double(syntheticKeyRetryPollMs) / 1000.0)
            repeat {
                if armValue() == expected { return .flipped }   // transition observed after the post
                usleep(40_000)
            } while Date() < deadline
            if attempt < syntheticKeyRetryAttempts - 1 {
                keyRuntime.sleepMicros(syntheticKeyRetrySettleMicros)
            }
        }
        return anyPosted ? .postedNoFlip : .couldNotPost
    }

    /// Restore Logic's transport recording state to `prior`, verifying by
    /// read-back. Used by `armSetupVerify` so a mis-assigned arm chord that instead
    /// toggled transport Record can never be left recording.
    private static func restoreTransportRecordingState(
        _ prior: Bool,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let current = transportRecordingState(runtime: runtime) else { return false }
        if current != prior {
            guard let record = AXLogicProElements.findControlBarCheckbox(
                named: AXLocalePolicy.transportRecordControl, runtime: runtime
            ) else { return false }
            _ = AXHelpers.performAction(record, kAXPressAction, runtime: runtime.ax)
        }
        for attempt in 0..<4 {
            if transportRecordingState(runtime: runtime) == prior { return true }
            if attempt < 3 { usleep(80_000) }
        }
        return false
    }

    typealias TrackToggleRung = (
        name: String,
        pollMs: Int,
        actuate: (_ pollMatched: (Int) -> Bool) -> RungOutcome
    )

    /// Per-op coordinate-free ladder. AXPress is always the natural primary
    /// (cheap; its return code is ignored and only read-back decides success).
    /// Mute/solo/arm add an exclusive-select-then-keyboard rung whose
    /// synthetic key is gated by: exclusive selection re-confirmed ATOMICALLY
    /// before the post (#4/#5), a safe keyboard focus (#6), and — for arm — a
    /// valid, non-bare key chord (#7). Any gate failing ⇒ the rung REFUSES (fails
    /// closed) without posting a key.
    static func trackToggleLadder(
        button: AXUIElement,
        buttonName: String,
        index: Int,
        desired: Bool,
        readValue: @escaping () -> Bool?,
        runtime: AXLogicProElements.Runtime,
        keyRuntime: AXMouseHelper.Runtime,
        processRuntime: ProcessUtils.Runtime,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [TrackToggleRung] {
        let pressRung: TrackToggleRung = ("press", 250, { _ in
            _ = AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax)
            return .actuated
        })

        func retryingKeyOutcome(
            pollMatched: (Int) -> Bool,
            postKey: () -> Void
        ) -> RungOutcome {
            if let refusal = syntheticKeyFocusRefusal(runtime: runtime) {
                return .refused(refusal)
            }
            if let refusal = confirmExclusiveSelectionRefusal(
                index: index,
                runtime: runtime,
                processRuntime: processRuntime,
                sleepMicros: keyRuntime.sleepMicros
            ) { return .refused(refusal) }

            for attempt in 0..<syntheticKeyRetryAttempts {
                // Fresh live halt barrier before EVERY post: a late read-back
                // must never turn a successful toggle into a second toggle.
                if readValue() == desired {
                    return attempt == 0 ? .alreadyLanded : .landed
                }
                guard processRuntime.logicIsFrontmost() else {
                    return .refused(logicNotFrontmostRefusal(index: index))
                }
                guard selectionIsExclusive(index: index, runtime: runtime) else {
                    return .refused(selectionNotExclusiveRefusal(index: index))
                }
                if let refusal = syntheticKeyFocusRefusal(runtime: runtime) {
                    return .refused(refusal)
                }
                postKey()
                if pollMatched(syntheticKeyRetryPollMs) { return .landed }
                if attempt < syntheticKeyRetryAttempts - 1 {
                    keyRuntime.sleepMicros(syntheticKeyRetrySettleMicros)
                }
            }
            return .exhausted
        }

        switch buttonName {
        case "Solo":
            let keyRung: TrackToggleRung = ("keyboard-solo", syntheticKeyRetryPollMs, { poll in
                retryingKeyOutcome(pollMatched: poll) {
                    _ = keyRuntime.postKeyEvent(trackSoloKeyCode)
                }
            })
            return [pressRung, keyRung]
        case "Mute":
            let keyRung: TrackToggleRung = ("keyboard-mute", syntheticKeyRetryPollMs, { poll in
                retryingKeyOutcome(pollMatched: poll) {
                    _ = keyRuntime.postKeyEvent(trackMuteKeyCode)
                }
            })
            return [pressRung, keyRung]
        case "Record":
            let keyRung: TrackToggleRung = ("keyboard-arm", syntheticKeyRetryPollMs, { poll in
                // #7 configurable chord — a present-but-invalid override is a
                // config error, never a silent fallback to the default chord.
                let code: CGKeyCode
                let flags: CGEventFlags
                switch resolveArmChord(environment: environment) {
                case .resolved(let resolvedCode, let resolvedFlags):
                    code = resolvedCode
                    flags = resolvedFlags
                case .invalidKeyCode(let bad):
                    return .refused(armConfigInvalidRefusal(
                        reason: "\(armKeyCodeEnvVar)=\"\(bad)\" is not a valid decimal virtual keycode"
                    ))
                case .invalidModifierToken(let bad):
                    return .refused(armConfigInvalidRefusal(
                        reason: "\(armKeyModifiersEnvVar) contains an unknown modifier token \"\(bad)\""
                    ))
                }
                // A bare (no-modifier) arm key is unsafe: bare 'r' IS transport
                // Record, and any bare key is a global single-key command. Refuse
                // it — the default chord (Ctrl+Shift+E) carries modifiers, so only
                // an explicit empty-modifier override reaches here.
                if armChordModifiersAreUnsafe(flags) {
                    return .refused(armConfigInvalidRefusal(
                        reason: "a bare arm key with no modifiers is unsafe (bare 'r' starts transport "
                            + "recording; any bare key triggers a global command) — configure a modifier chord"
                    ))
                }
                return retryingKeyOutcome(pollMatched: poll) {
                    _ = keyRuntime.postFlaggedKeyEvent(code, flags)
                }
            })
            return [pressRung, keyRung]
        default:
            return [pressRung]
        }
    }

    /// Exclusive single-track selection guard. Keyboard mute/solo/arm act on the
    /// SELECTED track, so before posting any key we (1) activate Logic, (2) drive
    /// the AX `AXSelectedChildren` selection path, and (3) READ BACK that the target —
    /// and ONLY the target — is selected. Returns false (⇒ the key is NOT
    /// posted, so a wrong/multi selection can never toggle the wrong track)
    /// until exclusivity is confirmed within a bounded settle budget.
    static func confirmExclusiveSelection(
        index: Int,
        runtime: AXLogicProElements.Runtime,
        heldHeader: AXUIElement? = nil,
        permittingWrite: (() -> Bool)? = nil,
        willWrite: (() -> Void)? = nil
    ) -> Bool {
        _ = AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime,
            heldHeader: heldHeader, permittingWrite: permittingWrite, willWrite: willWrite)
        for attempt in 0..<4 {
            guard permittingWrite?() ?? true else { return false }
            if selectionIsExclusive(index: index, runtime: runtime) { return true }
            if attempt < 3 { usleep(80_000) }
        }
        return false
    }

    /// Read-only exclusivity predicate: the target — and ONLY the target — is
    /// selected. #5 fail-closed on uncertainty: EVERY non-target header must
    /// report a DEFINITIVE `AXSelected == false`; any nil/unreadable non-target
    /// selection state means we cannot PROVE it is unselected, so exclusivity is
    /// treated as UNPROVEN (returns false) rather than optimistically ignored. The
    /// target itself must read a definitive `true`.
    static func selectionIsExclusive(
        index: Int,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        guard index >= 0, index < headers.count else { return false }
        let states = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
        guard states[index] == true else { return false }
        return states.enumerated().allSatisfy { offset, state in
            offset == index || state == false
        }
    }

    /// Confirm exclusive selection with an ATOMIC re-check immediately before the
    /// key post (#4 TOCTOU): a second `confirmExclusiveSelection` right before the
    /// caller posts the key. Returns a distinct `selection_not_exclusive` refusal
    /// (#9) — NOT the generic write-fail hint — when exclusivity cannot be
    /// (re)proven, so the key is never posted onto a wrong/multi selection.
    /// nil ⇒ safe to post.
    static func confirmExclusiveSelectionRefusal(
        index: Int,
        runtime: AXLogicProElements.Runtime,
        processRuntime: ProcessUtils.Runtime,
        sleepMicros: (useconds_t) -> Void
    ) -> RungRefusal? {
        _ = ProcessUtils.activateLogicPro(runtime: processRuntime)

        var stablePolls = 0
        var elapsedMicros: useconds_t = 0
        var frontmostSettled = false
        while elapsedMicros < logicFrontmostStabilityTimeoutMicros {
            stablePolls = processRuntime.logicIsFrontmost() ? stablePolls + 1 : 0
            sleepMicros(logicFrontmostPollIntervalMicros)
            elapsedMicros += logicFrontmostPollIntervalMicros
            if stablePolls == logicFrontmostStabilityPollCount {
                guard processRuntime.logicIsFrontmost() else {
                    stablePolls = 0
                    continue
                }
                sleepMicros(logicKeyWindowSettleMicros)
                frontmostSettled = processRuntime.logicIsFrontmost()
                if frontmostSettled { break }
                stablePolls = 0
            }
        }
        guard frontmostSettled else { return logicNotFrontmostRefusal(index: index) }
        guard confirmExclusiveSelection(index: index, runtime: runtime) else {
            return selectionNotExclusiveRefusal(index: index)
        }
        // Re-confirm atomically right before the key — selection can change
        // between the first confirm and the post (multi-select, user shift-click,
        // Logic reselection). If it no longer holds, fail closed without posting.
        guard confirmExclusiveSelection(index: index, runtime: runtime) else {
            return selectionNotExclusiveRefusal(index: index)
        }
        guard processRuntime.logicIsFrontmost() else {
            return logicNotFrontmostRefusal(index: index)
        }
        return nil
    }

    /// What Logic's keyboard focus is, as far as AX can tell.
    ///
    /// One reading with two consumers: `syntheticKeyFocusRefusal` posts a key only on
    /// `.notTextEditing`, and the background `StatePoller` loop yields its tick on `.textEditing`
    /// (#1079). The rule lives here once so the two cannot disagree about what a text field is.
    enum LogicKeyboardFocus: Equatable, Sendable {
        /// Where the reading stopped. A stage that did not read says nothing about the focus.
        enum UnreadableStage: Equatable, Sendable, CaseIterable {
            case appRoot
            case focusedElement
            case role
        }

        /// The focused element edits text. `byInsertionPoint` is false when its role is an
        /// editable one and true when only a text insertion point gave it away.
        case textEditing(role: String, byInsertionPoint: Bool)
        /// The focused element and its role were read, and it does not edit text.
        case notTextEditing
        case unreadable(UnreadableStage)
    }

    /// Reads Logic's focused UI element (the application element's `AXFocusedUIElement`) and
    /// classifies it: an editable text surface (rename field, Notes, search/combo box) by role, or
    /// any element exposing a text insertion point, since that marks an editable surface even when
    /// the role is unusual.
    static func readLogicKeyboardFocus(runtime: AXLogicProElements.Runtime) -> LogicKeyboardFocus {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unreadable(.appRoot)
        }
        guard let focused: AXUIElement = AXHelpers.getAttribute(
            app, kAXFocusedUIElementAttribute, runtime: runtime.ax
        ) else {
            return .unreadable(.focusedElement)
        }
        return readLogicKeyboardFocus(of: focused, runtime: runtime)
    }

    /// Classify this retained focus witness, not a second app-focused lookup.
    static func readLogicKeyboardFocus(
        of focused: AXUIElement, runtime: AXLogicProElements.Runtime
    ) -> LogicKeyboardFocus {
        guard let role = AXHelpers.getRole(focused, runtime: runtime.ax) else {
            return .unreadable(.role)
        }
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        if editableRoles.contains(role) {
            return .textEditing(role: role, byInsertionPoint: false)
        }
        if let _: NSNumber = AXHelpers.getAttribute(
            focused, kAXInsertionPointLineNumberAttribute, runtime: runtime.ax
        ) {
            return .textEditing(role: role, byInsertionPoint: true)
        }
        return .notTextEditing
    }

    /// #6 — refuse a synthetic global command key when Logic's keyboard focus is
    /// NOT known-safe: a modal/sheet is present, the focus does not read, or the
    /// focused element is an editable text surface (`readLogicKeyboardFocus`).
    /// Posting 'm', 's', or the arm chord into such focus would type text or
    /// trigger the wrong command. Returns a refusal (⇒ do NOT post the key);
    /// nil ⇒ the focus read and is not a text surface.
    /// Mute, Solo, and arm all use this gate before their synthetic key rung.
    static func syntheticKeyFocusRefusal(
        runtime: AXLogicProElements.Runtime
    ) -> RungRefusal? {
        if AXLogicProElements.dialogPresent(runtime: runtime) {
            return unsafeFocusRefusal(reason: "a modal dialog or sheet is present", focus: "modal")
        }
        switch readLogicKeyboardFocus(runtime: runtime) {
        case .unreadable(.appRoot):
            return unsafeFocusRefusal(
                reason: "the Logic application root is unreadable — focus safety cannot be proven",
                focus: "app_root_unreadable"
            )
        case .unreadable(.focusedElement):
            return unsafeFocusRefusal(
                reason: "Logic's focused element is unreadable — focus safety cannot be proven",
                focus: "focus_unreadable"
            )
        case .unreadable(.role):
            return unsafeFocusRefusal(
                reason: "the focused element's role is unreadable — focus safety cannot be proven",
                focus: "role_unreadable"
            )
        case .textEditing(let role, byInsertionPoint: false):
            return unsafeFocusRefusal(
                reason: "an editable text field is focused (role \(role))", focus: role
            )
        case .textEditing(let role, byInsertionPoint: true):
            return unsafeFocusRefusal(
                reason: "a text-editing surface with an insertion point is focused",
                focus: role
            )
        case .notTextEditing:
            return nil
        }
    }

    /// The active macOS keyboard input source, or nil when it cannot be read.
    ///
    /// Load-bearing for every rung that posts a synthetic key. Measured 2026-09-14: with
    /// `com.apple.inputmethod.Korean.2SetKorean` active, a chord posted as virtual key 14 with
    /// control+shift arrives at Logic as `⌃⇧ㄷ` — the Hangul character on that physical key — and
    /// matches no key command. Logic's own Learn records it the same way, writing `⌃⇧ㄷ` into the
    /// key field. The keystroke is DELIVERED (a bare spacebar toggles play under the same source);
    /// it is the character it carries that changes. Four operations moved from refusing to
    /// qualifying between two sweeps that differed in nothing else.
    static func activeInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Whether `id` is a plain Latin keyboard LAYOUT rather than an input METHOD.
    ///
    /// Deliberately narrow: `com.apple.keylayout.*` is a layout that delivers the character its key
    /// carries, and anything else — every `inputmethod` — composes. A Latin layout that REMAPS
    /// letters (Dvorak, AZERTY) is still `keylayout` and is not flagged here, because it was not
    /// measured and guessing at it would put a wrong sentence in a hint.
    static func inputSourceDeliversLatinKeys(_ id: String?) -> Bool {
        guard let id else { return true }
        return id.hasPrefix("com.apple.keylayout.")
    }

    /// The sentence appended to a synthetic-key failure when the input source can explain it.
    /// Empty when the source is a Latin layout or could not be read — an unread source is not
    /// evidence of anything and must not be blamed.
    static func inputSourceHintSuffix(_ id: String? = activeInputSourceID()) -> String {
        guard let id, !inputSourceDeliversLatinKeys(id) else { return "" }
        return " The active macOS input source is '\(id)', which composes characters: a synthetic "
            + "key carrying a letter reaches Logic as that source's character (Ctrl+Shift+E arrives "
            + "as ⌃⇧ㄷ under 2-set Korean) and matches no key command. Switch to a Latin keyboard "
            + "layout and retry."
    }

    /// Fail-closed hint (read-back never flipped). Arm points the operator at
    /// the required "Toggle Track Record Enable" key-command assignment — the
    /// only coordinate-free arm path on Logic 12.x.
    static func trackToggleFailHint(buttonName: String, index: Int, desired: Bool) -> String {
        trackToggleFailHintBody(buttonName: buttonName, index: index, desired: desired)
            + inputSourceHintSuffix()
    }

    private static func trackToggleFailHintBody(
        buttonName: String, index: Int, desired: Bool
    ) -> String {
        switch buttonName {
        case "Record":
            return "arm requires the Logic key command 'Toggle Track Record Enable' assigned to the "
                + "configured key (default Ctrl+Shift+E); assign it in Logic ▸ Key Commands, or set "
                + "LOGIC_PRO_MCP_ARM_KEYCODE/_MODIFIERS to your chosen key."
        case "Mute":
            return "track \(index) Mute=\(desired): read-back never matched after AXPress + "
                + "exclusive-select then key 'm' (coordinate-free actuators only)."
        case "Solo":
            return "track \(index) Solo=\(desired): read-back never matched after AXPress + "
                + "exclusive-select then key 's' (coordinate-free actuators only)."
        default:
            return "track \(index) \(buttonName)=\(desired): read-back never matched after AXPress "
                + "on the checkbox (coordinate-free actuators only)."
        }
    }

    /// Arm fail-closed hint for the mis-assignment case: the configured key
    /// started transport RECORDING instead of toggling record-enable.
    static func armRecordingStartedHint(index: Int) -> String {
        "arm aborted: the configured key started transport recording instead of arming track "
            + "\(index) — it is not assigned to 'Toggle Track Record Enable'. Stop the recording, then "
            + "assign that command (default Ctrl+Shift+E) in Logic ▸ Key Commands, or set "
            + "LOGIC_PRO_MCP_ARM_KEYCODE/_MODIFIERS to your chosen key."
    }

    static func armRecordingStoppedHint(index: Int) -> String {
        "arm aborted: the configured key stopped active transport recording instead of only arming track "
            + "\(index) — it is not assigned to 'Toggle Track Record Enable'. Restore recording as needed, then "
            + "assign that command (default Ctrl+Shift+E) in Logic ▸ Key Commands, or set "
            + "LOGIC_PRO_MCP_ARM_KEYCODE/_MODIFIERS to your chosen key."
    }

    /// #2 — arm fail-closed hint when the transport Record state is UNREADABLE at
    /// the post-actuate check, so a clean arm cannot be honestly claimed.
    static func armTransportUnknownHint(index: Int) -> String {
        "arm could not be confirmed for track \(index): the transport Record state was UNREADABLE, so "
            + "the server cannot prove the arm key did not instead start transport recording. Fail-closed "
            + "(no State A) — make Logic's control bar (with the Record button) visible, then retry."
    }

    /// #5/#9 — fail closed when exclusive selection cannot be proven.
    static func selectionNotExclusiveRefusal(index: Int) -> RungRefusal {
        RungRefusal(
            error: .selectionNotExclusive,
            hint: "track \(index) could not be exclusively selected before the key command "
                + "(another track is selected, or a header's selection state was unreadable). "
                + "Deselect other tracks and retry — the key was NOT posted.",
            extras: ["selection_error": "selection_not_exclusive"]
        )
    }

    static func logicNotFrontmostRefusal(index: Int) -> RungRefusal {
        RungRefusal(
            error: .logicNotFrontmost,
            hint: "track \(index) is exclusively selected, but Logic could not be confirmed frontmost. "
                + "Bring Logic frontmost and retry — the key was NOT posted.",
            extras: ["frontmost_error": "logic_not_frontmost"]
        )
    }

    /// #6 — refusal when Logic's keyboard focus is not known-safe for a synthetic
    /// global command key. The key was never posted.
    static func unsafeFocusRefusal(reason: String, focus: String) -> RungRefusal {
        RungRefusal(
            error: .unsafeFocusForSyntheticKey,
            hint: "refused to post the track key command: \(reason). Click the arrange/tracks area "
                + "(or dismiss the dialog) so keyboard focus is safe, then retry — the key was NOT posted.",
            extras: ["focus_guard": focus]
        )
    }

    /// #7 — refusal when the record-arm key override is present but invalid
    /// (unparseable keycode, unknown modifier token, or a bare no-modifier key).
    /// The key was never posted.
    static func armConfigInvalidRefusal(reason: String) -> RungRefusal {
        RungRefusal(
            error: .armKeyConfigInvalid,
            hint: "record-arm key configuration is invalid: \(reason). Fix "
                + "\(armKeyCodeEnvVar)/\(armKeyModifiersEnvVar) (or unset them to use the default "
                + "Ctrl+Shift+E) — the key was NOT posted.",
            extras: ["arm_key_config": "invalid"]
        )
    }

    static func defaultRenameTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production,
        processRuntime: ProcessUtils.Runtime = .production
    ) -> ChannelResult {
        // #968: the exact-local adapter is additive; the legacy scalar/menu route below
        // retains its existing behavior. Never retry an attempted exact write via a menu.
        if params["expected_name"] != nil {
            return exactRenameTrack(params: params, runtime: runtime,
                mouseRuntime: mouseRuntime, processRuntime: processRuntime)
        }
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "track.rename requires 'index' (Int) and 'name' (String)"
            ))
        }
        let truncatedName = String(name.prefix(255))
        let baseExtras: [String: Any] = ["track": index, "requested": truncatedName]

        func observedTrackName() -> String? {
            AXLogicProElements.trackName(at: index, runtime: runtime)
        }

        func verifiedResult(via: String) -> ChannelResult? {
            guard let observed = observedTrackName(), observed.utf8.elementsEqual(truncatedName.utf8) else { return nil }
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": observed,
                    "via": via
                ]) { _, new in new }
            ))
        }

        if let currentName = observedTrackName(), currentName.utf8.elementsEqual(truncatedName.utf8) {
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": currentName,
                    "via": "no-op"
                ]) { _, new in new }
            ))
        }

        guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) not found",
                extras: baseExtras
            ))
        }

        // #1097: Logic renames every selected track. With rows [0, 1] selected, renaming track 0
        // to "LPM-KDUP 55348" renamed track 1 to "LPM-KDUP 55349" (Korean, 2026-10-04,
        // lpm-evidence/1029/probe-kc-ko.json). When the headers carry selection state and another
        // row is not read as unselected, the target is selected alone before anything is written,
        // under the rule the key rungs use; when that cannot be shown, nothing is renamed.
        // All-unread is still unknown, not a reason to bypass this multi-track guard.
        let selectionStates = AXLogicProElements.allTrackHeaders(runtime: runtime)
            .map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
        let otherRowsNotUnselected = selectionStates.enumerated()
            .contains { $0.offset != index && $0.element != false }
        if otherRowsNotUnselected {
            let hasSelectionMetadata = selectionStates.contains(where: { $0 != nil })
            if hasSelectionMetadata { _ = ProcessUtils.activateLogicPro(runtime: processRuntime) }
            guard hasSelectionMetadata, confirmExclusiveSelection(index: index, runtime: runtime) else {
                let states = AXLogicProElements.allTrackHeaders(runtime: runtime)
                    .map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
                return .error(HonestContract.encodeStateC(
                    error: .selectionNotExclusive,
                    hint: "track \(index) could not be made the only selected track, and Logic renames every "
                        + "selected track. Nothing was renamed. Deselect the other tracks and retry.",
                    extras: baseExtras.merging([
                        "also_selected": states.enumerated().compactMap { $0.offset != index && $0.element == true ? $0.offset : nil },
                        "selection_unreadable": states.enumerated().compactMap { $0.offset != index && $0.element == nil ? $0.offset : nil },
                        "write_attempted": false,
                    ]) { _, new in new }
                ))
            }
        }

        if let field = AXLogicProElements.findTrackNameField(trackIndex: index, runtime: runtime) {
            AXHelpers.performAction(field, kAXPressAction, runtime: runtime.ax)
            AXHelpers.setAttribute(field, kAXValueAttribute, truncatedName as CFTypeRef, runtime: runtime.ax)
            AXHelpers.performAction(field, kAXConfirmAction, runtime: runtime.ax)
            usleep(50_000)
            if let verified = verifiedResult(via: "ax_set_value") {
                return verified
            }
        }

        _ = ProcessUtils.activateLogicPro(runtime: processRuntime)
        guard selectTrackForRename(index: index, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to select track \(index) before rename",
                extras: baseExtras
            ))
        }
        raiseTrackWindowForRename(index: index, runtime: runtime)

        let click = clickTrackMenu(
            AXLocalePolicy.renameTrackMenuItem.labels,
            runtime: runtime
        )
        guard click.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track > Rename Track menu item not found / not pressable",
                extras: baseExtras
            ))
        }

        usleep(150_000)
        let typing = typeRenameName(
            truncatedName,
            focus: { readLogicKeyboardFocus(runtime: runtime) },
            mouseRuntime: mouseRuntime
        )
        if typing != .typed {
            return renameTypingFailure(typing, baseExtras: baseExtras, observed: observedTrackName())
        }
        usleep(150_000)

        if let verified = verifiedResult(via: "track_menu") {
            return verified
        }

        AXMouseHelper.pressEscape(runtime: mouseRuntime)
        usleep(50_000)
        let observed = observedTrackName()
        return .success(HonestContract.encodeStateB(
            reason: observed == nil ? .readbackUnavailable : .readbackMismatch,
            extras: baseExtras.merging([
                "observed": observed as Any? ?? NSNull(),
                "via": "track_menu"
            ]) { _, new in new }
        ))
    }

    private static func exactRenameTrack(
        params: [String: String], runtime: AXLogicProElements.Runtime,
        mouseRuntime: AXMouseHelper.Runtime, processRuntime: ProcessUtils.Runtime
    ) -> ChannelResult {
        let expected = params["expected_name"]
        let physical = AXTrackBinding.current
        let ordinaryAcquisition = physical != nil && AXTrackBinding.ordinaryRenameAcquisition
        // A physical exact adapter may open the existing name editor only while
        // its original target is already exclusively selected. It never selects
        // another track; that compatibility acquisition remains scalar-only.
        let acquire = physical != nil
        var actualBefore: String?
        var attempted = false
        func refusal(_ hint: String) -> ChannelResult {
            let extras: [String: Any] = [
                "before": actualBefore as Any? ?? NSNull(),
                "write_attempted": attempted,
            ]
            if attempted {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable, extras: extras.merging(["hint": hint]) { _, new in new }
                ))
            }
            return .error(HonestContract.encodeStateC(error: .staleTargetReference, hint: hint, extras: extras))
        }
        guard let indexString = params["index"], let index = Int(indexString), index >= 0,
              let desired = params["name"], let expected,
              let projectPath = params["expected_project_path"],
              TrackDispatcher.renameNameFailure(desired) == nil,
              let window = physical?.window ?? AXLogicProElements.mainWindow(runtime: runtime),
              let header = physical?.header ?? AXLogicProElements.findTrackHeader(at: index, runtime: runtime) else {
            return refusal("Exact rename requires an observed project and a held track name field")
        }
        func nameField() -> AXUIElement? {
            guard let candidate = AXLogicProElements.trackNameField(in: header, runtime: runtime),
                  AXHelpers.getRole(candidate, runtime: runtime.ax) == kAXTextFieldRole as String else { return nil }
            // Logic may expose the header name as a noneditable numeric-zero label.
            // It cannot accept the direct String setter. Ordinary acquisition uses
            // the existing held-target menu/editor route instead, before any press
            // on that label. Exact adapters use the same editor only under their
            // original physical target's observed exclusive selection.
            if acquire,
               AXHelpers.isAttributeSettable(candidate, kAXValueAttribute as String, runtime: runtime.ax) == false,
               case .success(.some(let value)) = AXHelpers.getAttributeResult(
                candidate, kAXValueAttribute as String, runtime: runtime.ax) as Result<NSNumber?, AXHelpers.AXStatusError>,
               value.doubleValue == 0 { return nil }
            return candidate
        }
        var field = nameField()
        guard acquire || field != nil else { return refusal("Exact rename requires a held track name field") }
        let heldPID = acquire ? runtime.logicProPID() : nil
        let heldApp = acquire ? AXLogicProElements.appRoot(runtime: runtime) : nil

        func targetStillHeld(requiringExclusiveSelection: Bool = false) -> Bool {
            let position = physical?.currentIndex() ?? (physical == nil ? index : nil)
            guard ExactTrackNameAdapter.operationPermitted(),
                  let position,
                  AXTrackBinding.corroboratedIndex.map({ $0 == position }) ?? true,
                  let currentWindow = AXLogicProElements.mainWindow(runtime: runtime), CFEqual(currentWindow, window),
                  case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  let documentURL = URL(string: document), documentURL.isFileURL,
                  documentURL.host == nil || documentURL.host == "" || documentURL.host == "localhost",
                  documentURL.standardizedFileURL.path.utf8.elementsEqual(
                    URL(fileURLWithPath: projectPath).standardizedFileURL.path.utf8),
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
                  headers.indices.contains(position), CFEqual(headers[position], header),
                  headers.filter({ CFEqual($0, header) }).count == 1 else { return false }
            if let field, nameField().map({ CFEqual($0, field) }) != true { return false }
            // Do not actuate selection, or authorize renaming other selected/unread rows.
            if requiringExclusiveSelection {
                guard headers.enumerated().allSatisfy({
                    AXValueExtractors.extractSelectedState($0.element, runtime: runtime.ax) == ($0.offset == position)
                }) else { return false }
                // Current trk_ continuity cannot distinguish an intentional duplicate or swap.
                // Expose that missing provider before actuation, not after creating the collision.
                for (row, other) in headers.enumerated() where physical == nil && row != position {
                    guard case .success(.some(let otherName)) = AXValueExtractors.extractTrackNameResult(
                        from: other, runtime: runtime.ax), !otherName.utf8.elementsEqual(desired.utf8) else { return false }
                }
            }
            return ExactTrackNameAdapter.operationPermitted()
        }
        func readHeldName() -> String? {
            guard targetStillHeld(),
                  case .success(let name?) = AXValueExtractors.extractTrackNameResult(from: header, runtime: runtime.ax),
                  targetStillHeld() else { return nil }
            return name
        }
        actualBefore = readHeldName()
        guard let before = actualBefore, before.utf8.elementsEqual(expected.utf8) else {
            return refusal("Observed track name no longer matches the exact expected-before bytes")
        }
        if before.utf8.elementsEqual(desired.utf8) {
            return .success(HonestContract.encodeStateA(extras: [
                "before": before, "observed": before, "via": "no-op", "write_attempted": false,
            ]))
        }
        if ordinaryAcquisition, !targetStillHeld(requiringExclusiveSelection: true) {
            guard let position = physical?.currentIndex(), targetStillHeld() else {
                return refusal("Ordinary rename lost its held target before selection")
            }
            guard confirmExclusiveSelection(index: position, runtime: runtime, heldHeader: header,
                permittingWrite: {
                    guard physical?.currentIndex() == position,
                          let current = readHeldName(), current.utf8.elementsEqual(expected.utf8) else { return false }
                    return true
                }, willWrite: { attempted = true }) else {
                    return refusal("Ordinary rename could not acquire exclusive held-track selection")
                }
        }
        if acquire, field == nil { field = nameField() }
        if acquire, field == nil {
            // The legacy acquisition remains available, but its menu action is bound to the
            // retained track before actuation; never retry after an uncertain name write.
            let menu = clickTrackMenu(AXLocalePolicy.renameTrackMenuItem.labels, runtime: runtime,
                permittingWrite: {
                    guard targetStillHeld(requiringExclusiveSelection: true),
                          let current = readHeldName(), current.utf8.elementsEqual(expected.utf8) else { return false }
                    attempted = true
                    return true
                })
            guard menu.isSuccess else { return refusal("Ordinary rename could not open its held name field") }
            usleep(150_000)
        }
        if acquire, field == nil { field = nameField() }
        if acquire, field == nil {
            // The existing menu route may focus an editor outside the header. Keep its
            // identity and owning window, not merely the fact that some text has focus.
            guard let heldApp, let heldPID,
                  let editor: AXUIElement = AXHelpers.getAttribute(
                    heldApp, kAXFocusedUIElementAttribute, runtime: runtime.ax),
                  let initialValue: String = AXHelpers.getAttribute(editor, kAXValueAttribute, runtime: runtime.ax),
                  initialValue.utf8.elementsEqual(expected.utf8) else {
                return refusal("Ordinary rename menu did not expose its observed name editor")
            }
            func editorIsHeld(allowOwnNamePreview: Bool = false) -> Bool {
                guard runtime.logicProPID() == heldPID, runtime.focusedApplicationPID() == heldPID,
                      processRuntime.logicIsFrontmost(),
                      let app = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, heldApp),
                      let focused: AXUIElement = AXHelpers.getAttribute(
                        app, kAXFocusedUIElementAttribute, runtime: runtime.ax), CFEqual(focused, editor),
                      let editorWindow: AXUIElement = AXHelpers.getAttribute(editor, kAXWindowAttribute, runtime: runtime.ax),
                      CFEqual(editorWindow, window), targetStillHeld(requiringExclusiveSelection: true),
                      let current = readHeldName(),
                      current.utf8.elementsEqual(expected.utf8)
                        || (allowOwnNamePreview && current.utf8.elementsEqual(desired.utf8)),
                      let finalFocus: AXUIElement = AXHelpers.getAttribute(
                        app, kAXFocusedUIElementAttribute, runtime: runtime.ax), CFEqual(finalFocus, editor) else { return false }
                return ExactTrackNameAdapter.operationPermitted()
            }
            if AXHelpers.isAttributeSettable(editor, kAXValueAttribute as String, runtime: runtime.ax) == true {
                guard editorIsHeld(),
                      let value: String = AXHelpers.getAttribute(editor, kAXValueAttribute as String, runtime: runtime.ax),
                      value.utf8.elementsEqual(expected.utf8),
                      case .textEditing = readLogicKeyboardFocus(runtime: runtime),
                      ExactTrackNameAdapter.coupledWritePermitted(), editorIsHeld() else {
                    return refusal("Ordinary rename lost its held editor before the value setter")
                }
                attempted = true
                // Use the actual String-valued editor, never the passive header label.
                // No typing fallback follows an attempted setter or lost ownership.
                guard AXHelpers.setAttribute(editor, kAXValueAttribute as String, desired as CFTypeRef, runtime: runtime.ax) else {
                    return refusal("Ordinary rename editor value was attempted but its committed readback is unavailable")
                }
                if !editorIsHeld(allowOwnNamePreview: true) {
                    // Logic can commit the String setter and close its editor itself.
                    // Never send Return into a different focus. Verify the original
                    // physical target and coupled footprint instead; an ack, preview,
                    // newer name or lost project/selection/gate cannot satisfy this.
                    guard physical != nil,
                          runtime.logicProPID() == heldPID, runtime.focusedApplicationPID() == heldPID,
                          processRuntime.logicIsFrontmost(),
                          let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(currentApp, heldApp),
                          let committedFocus: AXUIElement = AXHelpers.getAttribute(
                            heldApp, kAXFocusedUIElementAttribute, runtime: runtime.ax),
                          case .notTextEditing = readLogicKeyboardFocus(of: committedFocus, runtime: runtime),
                          targetStillHeld(requiringExclusiveSelection: true),
                          let after = readHeldName(), after.utf8.elementsEqual(desired.utf8),
                          ExactTrackNameAdapter.coupledWritePermitted(allowOwnPreview: true),
                          targetStillHeld(requiringExclusiveSelection: true),
                          let finalName = readHeldName(), finalName.utf8.elementsEqual(after.utf8),
                          let finalFocus: AXUIElement = AXHelpers.getAttribute(
                            heldApp, kAXFocusedUIElementAttribute, runtime: runtime.ax), CFEqual(finalFocus, committedFocus),
                          case .notTextEditing = readLogicKeyboardFocus(of: finalFocus, runtime: runtime),
                          runtime.logicProPID() == heldPID, runtime.focusedApplicationPID() == heldPID,
                          processRuntime.logicIsFrontmost() else {
                        return refusal("Ordinary rename editor closed without a verified held-target commit")
                    }
                    return .success(HonestContract.encodeStateA(extras: [
                        "before": before, "observed": finalName, "via": "track_menu_ax_set_value_committed", "write_attempted": true,
                        "track_index": physical?.currentIndex() ?? index,
                    ]))
                }
                guard let value: String = AXHelpers.getAttribute(editor, kAXValueAttribute as String, runtime: runtime.ax),
                      value.utf8.elementsEqual(desired.utf8),
                      case .textEditing = readLogicKeyboardFocus(runtime: runtime),
                      ExactTrackNameAdapter.coupledWritePermitted(allowOwnPreview: true),
                      editorIsHeld(allowOwnNamePreview: true), mouseRuntime.postKeyEvent(0x24),
                      targetStillHeld(requiringExclusiveSelection: true),
                      let after = readHeldName(), after.utf8.elementsEqual(desired.utf8) else {
                    return refusal("Ordinary rename editor value was attempted but its committed readback is unavailable")
                }
                return .success(HonestContract.encodeStateA(extras: [
                    "before": before, "observed": after, "via": "track_menu_ax_set_value", "write_attempted": true,
                    "track_index": physical?.currentIndex() ?? index,
                ]))
            }
            // Opening the menu is a UI attempt, not ownership of a name preview.
            // The first name input must still match both original before names.
            var nameInputStarted = false
            let typing = typeRenameName(desired,
                focus: {
                    guard editorIsHeld() else { return .unreadable(.focusedElement) }
                    let reading = readLogicKeyboardFocus(runtime: runtime)
                    return editorIsHeld() ? reading : .unreadable(.focusedElement)
                },
                mouseRuntime: mouseRuntime,
                permittingPost: {
                    guard editorIsHeld(), case .textEditing = readLogicKeyboardFocus(runtime: runtime),
                          ExactTrackNameAdapter.coupledWritePermitted(allowOwnPreview: nameInputStarted),
                          editorIsHeld() else { return false }
                    nameInputStarted = true
                    attempted = true
                    return true
                })
            guard typing == .typed, targetStillHeld(requiringExclusiveSelection: true),
                  let after = readHeldName(), after.utf8.elementsEqual(desired.utf8) else {
                return refusal("Ordinary rename typing was attempted but its held-target readback is unavailable")
            }
            return .success(HonestContract.encodeStateA(extras: [
                "before": before, "observed": after, "via": "track_menu", "write_attempted": true,
                "track_index": physical?.currentIndex() ?? index,
            ]))
        }
        guard let field, ExactTrackNameAdapter.coupledWritePermitted(),
              targetStillHeld(requiringExclusiveSelection: true) else {
            return refusal("Held name field could not be opened")
        }
        attempted = true
        guard AXHelpers.performAction(field, kAXPressAction, runtime: runtime.ax) else {
            return refusal("Held name field opening was attempted but unverified")
        }
        // Opening the editor is not proof that its target or raw value survived.
        // This deciding live read precedes the setter, including the early no-op path above.
        guard let boundaryName = readHeldName(), boundaryName.utf8.elementsEqual(expected.utf8),
              ExactTrackNameAdapter.coupledWritePermitted(),
              targetStillHeld(requiringExclusiveSelection: true) else { return refusal("Exact rename precondition changed before the setter") }
        actualBefore = boundaryName
        attempted = true
        guard AXHelpers.setAttribute(field, kAXValueAttribute, desired as CFTypeRef, runtime: runtime.ax),
              ExactTrackNameAdapter.coupledWritePermitted(allowOwnPreview: true),
              targetStillHeld(requiringExclusiveSelection: true),
              AXHelpers.performAction(field, kAXConfirmAction, runtime: runtime.ax),
              let after = readHeldName(), after.utf8.elementsEqual(desired.utf8) else {
            return refusal("Exact rename was attempted but its held-target readback is unavailable")
        }
        return .success(HonestContract.encodeStateA(extras: [
            "before": boundaryName, "observed": after, "via": "ax_set_value", "write_attempted": true,
            "track_index": physical?.currentIndex() ?? index,
        ]))
    }

    /// How typing a name into Logic's rename field ended.
    enum RenameTypingOutcome: Equatable {
        /// Every code unit and the confirming Return were posted while a text field had the focus.
        case typed
        /// The rename field never read as focused: nothing was posted.
        case textFocusNotReached(LogicKeyboardFocus)
        /// The focus left the text field after `sentCodeUnits`: nothing after it was posted,
        /// neither the rest of the name nor Return.
        case textFocusLost(sentCodeUnits: Int, focus: LogicKeyboardFocus)
        /// Posting a code unit, or the confirming Return, failed after `sentCodeUnits` code units
        /// were posted: nothing after it was posted.
        case postFailed(sentCodeUnits: Int)
    }

    /// The menu item that opens the field, by its pinned row:
    /// logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Rename%20Track#value
    /// en: "Rename Track"
    ///
    /// Types `name` into the rename field Track > Rename Track opened, one code unit at a time,
    /// and only while Logic's keyboard focus reads as text editing (`readLogicKeyboardFocus`, the
    /// rule the key-command guard and the #1079 poll yield use).
    ///
    /// A synthetic key that reaches Logic outside a text field is a key command: measured on Logic
    /// 12.3.1 (German UI), a rename to "MCP Test" left the name at "MCP T", and the track came out
    /// soloed with the editor open, which is what `s` and `e` do as key commands. So the focus is
    /// read before every code
    /// unit and before Return, and anything other than `.textEditing` stops the typing there,
    /// unreadable included. Nothing is posted after the stop, not even Escape: with the field gone,
    /// Escape is a key command as well.
    static func typeRenameName(
        _ name: String,
        focus: () -> LogicKeyboardFocus,
        mouseRuntime: AXMouseHelper.Runtime,
        focusWaitAttempts: Int = 10,
        focusWaitMicros: useconds_t = 50_000,
        permittingPost: (() -> Bool)? = nil
    ) -> RenameTypingOutcome {
        func isTextEditing(_ reading: LogicKeyboardFocus) -> Bool {
            if case .textEditing = reading { return true }
            return false
        }

        // Only a readable "not text editing" is waited out: the field takes a moment to take the
        // focus after the menu item. A focus that cannot be read stops the rename at once, before
        // anything is posted (#1102: "If the focus is lost, or cannot be read, the rename stops
        // fail-closed"; #1103 review R2, F1: the wait retried an unreadable reading).
        var reading = focus()
        var attempt = 1
        while case .notTextEditing = reading, attempt < focusWaitAttempts {
            mouseRuntime.sleepMicros(focusWaitMicros)
            reading = focus()
            attempt += 1
        }
        guard isTextEditing(reading) else { return .textFocusNotReached(reading) }

        // `sent` counts posts that went through, not attempts (#1103 review R2): a post that
        // fails stops the typing and is reported as itself, not as focus loss.
        var sent = 0
        for codeUnit in name.utf16 {
            let now = focus()
            guard isTextEditing(now) else { return .textFocusLost(sentCodeUnits: sent, focus: now) }
            guard permittingPost?() ?? true,
                  mouseRuntime.postUnicodeScalar(codeUnit) else { return .postFailed(sentCodeUnits: sent) }
            sent += 1
            mouseRuntime.sleepMicros(12_000)
        }

        mouseRuntime.sleepMicros(50_000)
        let beforeReturn = focus()
        guard isTextEditing(beforeReturn) else {
            return .textFocusLost(sentCodeUnits: sent, focus: beforeReturn)
        }
        // The confirming Return is a post like the others: one that fails is not a typed name
        // (#1103 review R2, F2).
        guard permittingPost?() ?? true,
              mouseRuntime.postKeyEvent(0x24) else { return .postFailed(sentCodeUnits: sent) }
        return .typed
    }

    /// The State C a rename answers when its typing stopped for focus. Never State A: the name was
    /// not confirmed, and a field left open or a partial name is a write nobody can vouch for.
    static func renameTypingFailure(
        _ outcome: RenameTypingOutcome,
        baseExtras: [String: Any],
        observed: String?
    ) -> ChannelResult {
        func describe(_ reading: LogicKeyboardFocus) -> String {
            switch reading {
            case .textEditing(let role, _): return role
            case .notTextEditing: return "not_text_editing"
            case .unreadable(let stage): return "unreadable_\(stage)"
            }
        }

        let precondition: String
        let hint: String
        let sent: Int
        let reading: LogicKeyboardFocus?
        var error = HonestContract.FailureError.unsafeFocusForSyntheticKey
        switch outcome {
        case .typed:
            return .error(HonestContract.encodeStateC(
                error: .unsafeFocusForSyntheticKey,
                hint: "track.rename: a completed typing was reported as a focus failure",
                extras: baseExtras
            ))
        case .textFocusNotReached(let focus):
            precondition = "text_focus_not_reached"
            sent = 0
            reading = focus
            hint = "the rename field never took Logic's keyboard focus — no character, Return or "
                + "Escape was posted. Click the track area so Logic has the keyboard, then retry."
        case .textFocusLost(let count, let focus):
            precondition = "text_focus_lost"
            sent = count
            reading = focus
            hint = "Logic's keyboard focus left the rename field after \(count) code unit(s) — "
                + "typing stopped and no Return or Escape was posted, so the rest of the name did "
                + "not reach Logic as key commands. The field may still be open; `observed` is the "
                + "name read afterwards."
        case .postFailed(let count):
            precondition = "key_post_failed"
            sent = count
            reading = nil
            error = .axWriteFailed
            hint = "posting a key to Logic failed after \(count) code unit(s) — typing stopped and no "
                + "Return or Escape was posted. The field may still be open; `observed` is the name "
                + "read afterwards."
        }
        return .error(HonestContract.encodeStateC(
            error: error,
            hint: hint,
            extras: baseExtras.merging([
                "via": "track_menu",
                "precondition": precondition,
                "sent_code_units": sent,
                "keyboard_focus": reading.map(describe) as Any? ?? NSNull(),
                "observed": observed as Any? ?? NSNull(),
                "write_attempted": sent > 0
            ]) { _, new in new }
        ))
    }

    private static func raiseTrackWindowForRename(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) {
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime),
              let window: AXUIElement = AXHelpers.getAttribute(header, kAXWindowAttribute, runtime: runtime.ax)
        else {
            return
        }
        _ = AXHelpers.performAction(window, kAXRaiseAction, runtime: runtime.ax)
        usleep(50_000)
    }

    private static func selectTrackForRename(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) -> Bool {
        let initialHeaders = AXLogicProElements.allTrackHeaders(runtime: runtime)
        guard index >= 0 && index < initialHeaders.count else { return false }
        if AXValueExtractors.extractSelectedState(initialHeaders[index], runtime: runtime.ax) == true {
            return true
        }

        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return false
        }

        var sawSelectionMetadata = false
        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            guard index < headers.count else { return false }

            let selectionStates = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
            if selectionStates.contains(where: { $0 != nil }) {
                sawSelectionMetadata = true
            }
            if selectionStates[index] == true {
                return true
            }
            if attempt < 5 {
                usleep(100_000)
            }
        }
        return !sawSelectionMetadata
    }

    enum TrackSelectionVerification: Equatable {
        case verified
        case selectionMetadataUnavailable
        case mismatch(selectedIndex: Int?)
        /// #1097: the target reads selected, and `alsoSelected` read selected too or `unreadable`
        /// did not read. A write that acts on the selection could act on those rows as well.
        case notExclusive(alsoSelected: [Int], unreadable: [Int])
        case trackDisappeared
    }

    /// Verified only when `selectionIsExclusive` holds: the target, and only the target, reads
    /// selected, the rule the keyboard mute/solo/arm rungs already require before their key (#1097).
    /// Before, a target selected alongside another row was verified: after the CGEvent rung's
    /// Option-Command-S, Logic added the next AX selection to the one it had, select index 0 read
    /// rows [0, 1] while answering State A, and a rename of track 0 then renamed track 1 as well
    /// (Korean, 2026-10-04, lpm-evidence/1029/probe-kc-ko.json). The rows are read up to six
    /// times, 100 ms apart, so a deselection Logic publishes late is waited for.
    static func verifyTrackSelection(
        index: Int,
        runtime: AXLogicProElements.Runtime
    ) async -> TrackSelectionVerification {
        var sawSelectionMetadata = false
        var targetSelected = false
        var alsoSelected: [Int] = []
        var unreadable: [Int] = []

        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            guard index >= 0 && index < headers.count else {
                return .trackDisappeared
            }

            let states = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
            if states.contains(where: { $0 != nil }) {
                sawSelectionMetadata = true
            }
            if selectionIsExclusive(index: index, runtime: runtime) {
                return .verified
            }
            targetSelected = states[index] == true
            alsoSelected = states.enumerated().compactMap { $0.offset != index && $0.element == true ? $0.offset : nil }
            unreadable = states.enumerated().compactMap { $0.offset != index && $0.element == nil ? $0.offset : nil }

            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard sawSelectionMetadata else {
            return .selectionMetadataUnavailable
        }
        if targetSelected {
            return .notExclusive(alsoSelected: alsoSelected, unreadable: unreadable)
        }

        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        let selectedIndex = headers.enumerated().first {
            AXValueExtractors.extractSelectedState($0.element, runtime: runtime.ax) == true
        }?.offset
        return .mismatch(selectedIndex: selectedIndex)
    }

    /// The title `clickTrackMenu` reports it actually pressed, or nil when it did not say.
    ///
    /// The receipt names the spelling Logic rendered, not the one the caller asked for, which is
    /// the only way a reader can tell WHICH language the menu was in.
    private static func clickedTitle(from result: ChannelResult) -> String? {
        let parsed = (try? JSONSerialization.jsonObject(with: Data(result.message.utf8)))
        return (parsed as? [String: String])?["menu_clicked"]
    }

    // MARK: - Track Creation via Menu

    /// The menu leaf, as a LabelSet rather than a Korean string and an English one.
    ///
    /// `(korean:, english:)` tried the Korean spelling and fell back to the English, which is two
    /// of the ten languages Logic ships: on a German, Spanish, French, Italian, Portuguese or
    /// Chinese Logic neither matched and the operation answered `Cannot find menu item` about a
    /// menu that was there. That is #883.
    static func createTrackViaMenu(
        item: AXLocalePolicy.LabelSet,
        expectedTrackType: TrackType,
        // Retained for channel-runtime compatibility. The create route no
        // longer invokes this unchecked keyboard fallback.
        confirmDialog: @escaping @Sendable () -> Void = { sendReturnKey() },
        runtime: AXLogicProElements.Runtime = .production,
        // #538: total post-menu reconcile passes budgeted for the mandatory
        // New Track sheet, including the first. Tests override the delay to
        // 0 to stay fast; production keeps a real gap so a delayed AX publish
        // has time to land.
        dialogPollAttempts: Int = 5,
        dialogPollDelayNanoseconds: UInt64 = 200_000_000,
        // The pre-write rail read gets its own budget, because it answers a different question
        // than the New Track sheet poll does and failing it costs the whole verdict. Tests set it
        // to 1 to keep a single attempt.
        railReadAttempts: Int = 5,
        // #883: polls after dismissing an owned New Track sheet on the give-up path, spaced by
        // `dialogPollDelayNanoseconds`.
        newTrackSheetCleanupAttempts: Int = 10
    ) async -> ChannelResult {
        guard AXLogicProElements.mainWindow(runtime: runtime) != nil else {
            return .error("No document open for track creation")
        }

        // #348: clear a stray blocking modal BEFORE driving the Track menu — a
        // single-OK top-level alert (audio-interface warning on fresh-document /
        // first-track creation) otherwise wedges the create. Scoped with
        // `clearMandatoryNewTrack: false` so preflight NEVER clicks "Create": the
        // classifier-bound post-menu reconciliation below owns that, and doing
        // both would double-create. Acknowledges alerts + escapes stray
        // menus only; a no-op AX read when nothing is blocking.
        let reconcileOutcome = await reconcilePreflight(clearMandatoryNewTrack: false, runtime: runtime)

        // A mutation witness needs the same status-preserving rail read as the
        // delete path. The historic flattening enumerator turns a failed
        // pre-write read into `[]`, which makes tracks that were already there
        // look like the result of this menu click.
        // A rail read that failed ONCE is not evidence about the rail. Measured 2026-09-15 on a
        // just-created project: this read came back nil, and because `beforeTracks == nil` forces
        // State B `retry_exhausted` no matter what happens afterwards, `create_audio`,
        // `create_instrument` and `delete` all reported an unverified write for a track that had
        // demonstrably appeared or gone. The window and its header rail need a moment to publish
        // after a document opens; one attempt catches that moment only by luck.
        var arrangeWindow = AXLogicProElements.arrangeWindowRead(runtime: runtime)
        var beforeTracks = observedTrackStates(in: arrangeWindow, runtime: runtime)
        if beforeTracks == nil {
            for _ in 1..<max(railReadAttempts, 1) {
                try? await Task.sleep(nanoseconds: dialogPollDelayNanoseconds)
                arrangeWindow = AXLogicProElements.arrangeWindowRead(runtime: runtime)
                beforeTracks = observedTrackStates(in: arrangeWindow, runtime: runtime)
                if beforeTracks != nil { break }
            }
        }

        // RAISE THE WINDOW THIS OPERATION ALREADY RESOLVED, before driving the menu.
        //
        // Logic's Track menu acts on the front window, and this code resolved the arrange window
        // for its READS while clicking the menu without raising it. Measured 2026-09-15 on a
        // disposable project: with only the arrange window open, `create_audio` answers State A and
        // the count rises; after `navigate.create_marker` opens the Marker List the same call
        // answers State B and the count does not move AT ALL; raising the arrange window by name
        // makes it land again. The qualification sweep drives operations sorted by id, so every
        // `navigate.*` runs before every `tracks.*` — which is why a track create that works when
        // driven alone fails inside a sweep, and why seventy read-only operations beforehand change
        // nothing. Traffic was never the cause; a window in front was.
        //
        // This raises a window the operation has already identified as its target, not an arbitrary
        // one, and only on the path that is about to act on that window.
        if case .found(let window) = arrangeWindow {
            _ = AXHelpers.performAction(window, kAXRaiseAction as String, runtime: runtime.ax)
        }

        // Every spelling the policy knows, in one pass. The old shape tried Korean and then
        // English, which made the operation's reach the size of that pair rather than the size of
        // the LabelSet -- and a LabelSet that learns a language could not reach this call site.
        let result = clickTrackMenu(item.labels, runtime: runtime)
        guard result.isSuccess else { return result }
        let menuClickedTitle = Self.clickedTitle(from: result) ?? item.canonical

        // Logic may publish a mandatory New Track dialog after the menu click.
        // Reconcile it through the classifier-bound AX Create element; Return
        // would actuate whichever default control happens to be focused and was
        // never read as this operation's target.
        try? await Task.sleep(nanoseconds: 400_000_000)
        var dialogReconcileOutcome = await reconcileAfterMutation(
            isDeleteContext: false,
            runtime: runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )
        // #538 BLOCKER: `reconcileAfterMutation` can classify the sheet from its
        // AXDescription before the sheet's Create control is published in the
        // tree — the executor then no-ops (`createButton == nil`,
        // `actionAttempted == false`) and this single pass presses nothing. The
        // mandatory sheet's only exit is Create, so stopping here after one
        // description-only pass leaves Logic wedged on it. Poll again, mirroring
        // `observeProjectCreationOutcome`'s `mandatoryTrackCreateActionAttempted`
        // latch: keep re-reconciling ONLY while no pass has yet issued the press
        // AND the sheet is still classified `.mandatoryNewTrack`, and stop the
        // instant one pass does — so a later-published Create control is
        // pressed exactly once, never twice.
        if !dialogReconcileOutcome.actionAttempted {
            let extraAttempts = max(0, dialogPollAttempts - 1)
            for _ in 0..<extraAttempts {
                guard dialogReconcileOutcome.kind == .mandatoryNewTrack else { break }
                try? await Task.sleep(nanoseconds: dialogPollDelayNanoseconds)
                dialogReconcileOutcome = await reconcileAfterMutation(
                    isDeleteContext: false,
                    runtime: runtime,
                    witnessAttempts: 1,
                    witnessDelayNanoseconds: 0
                )
                if dialogReconcileOutcome.actionAttempted { break }
            }
        }
        let dialogConfirmationAttempted = dialogReconcileOutcome.actionAttempted
        let verificationReconcileOutcome = dialogReconcileOutcome.kind == .none
            && dialogReconcileOutcome.modalObservationIsComplete
            ? reconcileOutcome
            : dialogReconcileOutcome
        // #883: a New Track sheet seen after the menu press is this operation's own only when the
        // complete preflight read saw no sheet before it. Anything else might be a sheet somebody
        // else raised, and the give-up path must not dismiss that.
        let newTrackSheetIsOwned = reconcileOutcome.modalObservationIsComplete
            && !kindIsSheetShaped(reconcileOutcome.kind)

        return await verifyTrackCreation(
            title: menuClickedTitle,
            expectedTrackType: expectedTrackType,
            beforeTracks: beforeTracks,
            arrangeWindow: arrangeWindow,
            dialogConfirmationAttempted: dialogConfirmationAttempted,
            reconcileOutcome: verificationReconcileOutcome,
            newTrackSheetIsOwned: newTrackSheetIsOwned,
            newTrackSheetCleanupAttempts: newTrackSheetCleanupAttempts,
            newTrackSheetCleanupDelayNanoseconds: dialogPollDelayNanoseconds,
            runtime: runtime
        )
    }

    /// Legacy keyboard fallback retained for injected runtime compatibility.
    /// Track creation deliberately does not call it: Return has no AX-bound
    /// target and can activate an unrelated default button.
    static func sendReturnKey() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let returnVK: CGKeyCode = 0x24
        if let down = CGEvent(keyboardEventSource: src, virtualKey: returnVK, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: returnVK, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }

    private static func verifyTrackCreation(
        title: String,
        expectedTrackType: TrackType,
        beforeTracks: [TrackState]?,
        arrangeWindow: AXLogicProElements.ArrangeWindowRead,
        dialogConfirmationAttempted: Bool,
        reconcileOutcome: ModalReconcileOutcome,
        newTrackSheetIsOwned: Bool,
        newTrackSheetCleanupAttempts: Int,
        newTrackSheetCleanupDelayNanoseconds: UInt64,
        runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let beforeCount = beforeTracks?.count
        var lastObservedCount: Int?

        var extras: [String: Any] = [
            "menu_clicked": title,
            "track_count_before": beforeCount ?? NSNull(),
            "requested_delta": 1,
            "requested_track_type": expectedTrackType.rawValue,
            "dialog_confirmation_attempted": dialogConfirmationAttempted,
            "verification_source": "track_count_delta"
        ]
        // #348: note any pre-create reconciliation (alert acknowledged / stray
        // menu escaped). No-op when nothing was blocking, so the clean create
        // path stays byte-identical.
        mergeReconcileExtras(
            &extras,
            kind: reconcileOutcome.kind,
            action: attemptedReconcileActionLabel(reconcileOutcome),
            newTrackAutoConfirmed: reconcileOutcome.kind == .mandatoryNewTrack && reconcileOutcome.actionAccepted,
            witnessSummary: reconcileOutcome.witnessSummary,
            refusal: reconcileOutcome.refusal,
            actionFailure: reconcileOutcome.actionFailure,
            unreadableReason: reconcileOutcome.unreadableReason,
            sheetScanFailureDetail: reconcileOutcome.sheetScanFailureDetail
        )

        var lastModal = reconcileOutcome
        // #538 BLOCKER: a single clean+increased poll is not settled absence.
        // After Create, Logic rebuilds — the bound sheet invalidates
        // (`.gone`), `AXChildren` can read back a successful `[]` for one
        // poll, and a replacement New Track sheet can attach on the very next
        // read. Mirror the delete path's requirement of two CONSECUTIVE clean
        // observations (`deletionCleanObservationStreakIsSettled`) instead of
        // certifying State A off attempt 0 alone.
        var consecutiveCleanIncreasedObservations = 0
        for attempt in 0..<4 {
            let currentTracks = observedTrackStates(in: arrangeWindow, runtime: runtime)
            let currentCount = currentTracks?.count
            if let currentCount {
                lastObservedCount = currentCount
            }
            let modal = observeModalAfterMutation(
                isDeleteContext: false,
                arrangeWindow: arrangeWindow,
                runtime: runtime
            )
            lastModal = modal
            let countIncreased = beforeTracks.map { before in
                currentTracks.map { $0.count > before.count } ?? false
            } ?? false
            let settledClean = deletionModalObservationIsSettledClean(
                modal,
                arrangeWindowWasRead: {
                    if case .found = arrangeWindow { return true }
                    return false
                }()
            )
            if countIncreased, settledClean {
                consecutiveCleanIncreasedObservations += 1
            } else {
                consecutiveCleanIncreasedObservations = 0
            }
            if let beforeTracks,
               let currentTracks,
               deletionCountCanCertifyStateA(
                   observedTrackCountDecreased: countIncreased,
                   settledCleanModalObservation: deletionCleanObservationStreakIsSettled(
                       consecutiveCleanIncreasedObservations
                   )
               ) {
                var merged = extras.merging([
                    "track_count_after": currentTracks.count,
                    "observed_delta": currentTracks.count - beforeTracks.count
                ]) { _, new in new }
                if let observedTrack = observedCreatedTrack(before: beforeTracks, after: currentTracks) {
                    merged["observed_track_index"] = observedTrack.id
                    // `extractTrackName` returns the literal placeholder "Untitled"
                    // with `liveIdentityBacked == false` when no title/description/
                    // text-field name was actually readable. Publishing that literal
                    // as `observed_track_name` would claim the header named itself
                    // when nothing was read. Only a live-identity-backed name is an
                    // observed effect.
                    if observedTrack.liveIdentityBacked {
                        merged["observed_track_name"] = observedTrack.name
                    }
                    // #766 — the header aggregate cannot tell the types apart, so it answers
                    // `unknown`; the inspector channel strip CAN, for two of them. The strip is
                    // the one the inspector rebuilt for the track just created, which is the
                    // selected one, so this costs no selection change — and it is only consulted
                    // when the name it has to agree with was actually read, because the
                    // placeholder "Untitled" would match whatever strip happened to carry it.
                    // The strip is identified by NAME, so a name shared by more than one track
                    // cannot identify anything: the inspector shows one strip at a time, so
                    // "exactly one strip carries this name" is trivially true even when the strip
                    // belongs to the OTHER track of that name. Counting strips does not close this
                    // — counting TRACKS does, and the caller is the only place that can. Found by
                    // review 2026-09-09, which pointed out that the strip-side check was answering
                    // a different question than the one the hazard asks.
                    let nameIsUnique = currentTracks.filter { $0.name == observedTrack.name }.count == 1
                    let stripReading = (observedTrack.liveIdentityBacked && nameIsUnique)
                        // #866 — THE CALLER'S RUNTIME. This read defaulted to `.production` while
                        // every other AX read on this path went through the injected one, so a test
                        // that built a complete fake tree still had its verdict decided by the real
                        // Logic inspector. It produced a false GREEN in the ship gate, not a false
                        // red: the same test passed the full suite half an hour before it started
                        // failing, with no change to anything it touches — what differed was which
                        // track the live session had selected. CI never saw it because CI has no
                        // Logic, so the read finds nothing there and falls through to the header.
                        ? AXLogicProElements.inspectorStripReading(
                            expectedName: observedTrack.name, runtime: runtime
                          )
                        : .undetermined
                    switch stripReading {
                    case let .type(readType):
                        merged["observed_track_type"] = readType.rawValue
                        merged["track_type_verification_source"] = "inspector_channel_strip"
                    case .instrumentFamily:
                        // The strip WAS read and its answer is a family this read cannot narrow —
                        // a drummer's strip and a software instrument's are identical. The type
                        // stays `unknown`, and the source says which of the two unknowns this is:
                        // a read that answered a family, not a read that did not happen.
                        merged["observed_track_type"] = TrackType.unknown.rawValue
                        merged["track_type_verification_source"] = "inspector_channel_strip_instrument_family"
                    case .undetermined:
                        merged["observed_track_type"] = observedTrack.type.rawValue
                        merged["track_type_verification_source"] = "observed_header"
                    }
                }
                return .success(HonestContract.encodeStateA(extras: merged))
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        var merged = extras
        merged["track_count_after"] = lastObservedCount ?? NSNull()
        if let beforeCount, let lastObservedCount {
            merged["observed_delta"] = lastObservedCount - beforeCount
        } else {
            merged["observed_delta"] = NSNull()
        }
        mergeReconcileExtras(
            &merged,
            kind: lastModal.kind,
            action: attemptedReconcileActionLabel(lastModal),
            newTrackAutoConfirmed: lastModal.kind == .mandatoryNewTrack && lastModal.actionAccepted,
            witnessSummary: lastModal.witnessSummary,
            refusal: lastModal.refusal,
            actionFailure: lastModal.actionFailure,
            unreadableReason: lastModal.unreadableReason,
            sheetScanFailureDetail: lastModal.sheetScanFailureDetail
        )
        // #883: every exit below gives up, and giving up used to leave this operation's New Track
        // sheet on screen for the next call to be refused on. Dismiss it and report the re-read.
        // The verdict below still keys on `lastModal`: Create may have landed, so the state stays B.
        var cleanup: NewTrackSheetCleanup?
        if newTrackSheetIsOwned, lastModal.kind == .mandatoryNewTrack {
            let result = await dismissOwnedNewTrackSheet(
                runtime: runtime,
                observationAttempts: newTrackSheetCleanupAttempts,
                observationDelayNanoseconds: newTrackSheetCleanupDelayNanoseconds
            )
            merged["new_track_sheet_cleanup"] = result.envelopeValue
            cleanup = result
        }
        // Without a successful pre-write rail read, a later count cannot tell
        // whether the tracks existed before the menu action. The write may have
        // happened, but State A is unavailable rather than a zero-count guess.
        guard beforeTracks != nil else {
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: merged
            ))
        }
        // `dialog_present` / `waiting_for_user` must claim only what was
        // actually observed. `kind != .none` is a real blocker: something is
        // genuinely on screen waiting for the user. An incomplete scan
        // (`!modalObservationIsComplete` while `kind == .none`) is a read
        // that did not answer — it must not be reported as "a dialog is
        // present", which is a claim about a control that was never seen.
        // `mergeReconcileExtras` above already records the honest
        // `reconciled_modal_observation: "incomplete"` for that case; this
        // flag must not contradict it.
        let realBlockerPresent = lastModal.kind != .none
        // After a cleanup the latest observation is its re-read, and these two flags describe
        // that, not the sheet it dismissed.
        let blockerStillPresent = cleanup.map { $0.postCleanupKind != .none } ?? realBlockerPresent
        merged["dialog_present"] = blockerStillPresent
        if realBlockerPresent {
            if blockerStillPresent {
                merged["waiting_for_user"] = true
            }
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: merged
            ))
        }
        guard lastModal.modalObservationIsComplete else {
            // No dialog was observed, but the blocker-set scan itself never
            // completed. Neither "clean" nor "blocked" is an honest claim;
            // stay in the safe, retryable State B rather than asserting a
            // dialog that was never seen or a write failure that was never
            // confirmed.
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: merged
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "track count did not increase after '\(title)' click within 4×1s budget",
            extras: merged
        ))
    }

    private static func observedTrackStates(
        in arrangeWindow: AXLogicProElements.ArrangeWindowRead,
        runtime: AXLogicProElements.Runtime = .production
    ) -> [TrackState]? {
        guard case .found(let window) = arrangeWindow,
              case .read(let headers) = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        else { return nil }
        return headers.enumerated().map { index, header in
            AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
        }
    }

    private static func observedCreatedTrack(
        before: [TrackState],
        after: [TrackState]
    ) -> TrackState? {
        let beforeSignatures = Set(before.map(trackCreationSignature))
        let newTracks = after.filter { !beforeSignatures.contains(trackCreationSignature($0)) }
        if newTracks.count == 1 {
            return newTracks[0]
        }
        guard after.count == before.count + 1 else { return nil }
        var prefix = 0
        while prefix < before.count,
              trackCreationSignature(before[prefix]) == trackCreationSignature(after[prefix]) {
            prefix += 1
        }
        guard prefix < after.count else { return nil }
        return after[prefix]
    }

    private static func trackCreationSignature(_ track: TrackState) -> String {
        [
            track.name,
            track.type.rawValue,
            // An unread toggle (#1040) is its own value here, never folded into "false".
            track.isMuted.map { String($0) } ?? "unread",
            track.isSoloed.map { String($0) } ?? "unread",
            track.isArmed.map { String($0) } ?? "unread",
            // ALWAYS EMPTY, and kept deliberately. Nothing populates `TrackState.color`, so this
            // component cannot move and a recoloured track produces an identical fingerprint — a
            // consumer comparing fingerprints will not see the change. That is not an oversight to
            // be fixed here: measured 2026-09-09 across 1406 elements to depth 16, including the
            // colour palette opened through View > Colors, Logic exposes no attribute of colour
            // type and no value naming one, so there is nothing for a reader to read
            // (`docs/observations/2026-09-09-no-attribute-value-anywhere-carries-a-track-colour`).
            //
            // The component stays rather than being deleted so that a future colour reader lights
            // it up without changing this string's shape, and the silence is written down here so
            // the next reader does not have to re-derive it. #448.
            track.color ?? ""
        ].joined(separator: "|")
    }

    /// Delete the currently-selected track via the `트랙 → 트랙 삭제` menu and
    /// verify the track count decremented by 1 within a 4×1s budget. Returns
    /// State A on confirmed delta, State B `retry_exhausted` if AX poll never
    /// catches the decrement, State C if the menu click itself fails.
    ///
    /// A deletion count is State A only after a *subsequent*, clean modal
    /// observation. Every non-`none` reconcile kind is still a blocker here,
    /// even if its action was accepted: a successful action is evidence of an
    /// attempted recovery, not proof that the modal set is now settled clean.
    static func deletionCountCanCertifyStateA(
        observedTrackCountDecreased: Bool,
        settledCleanModalObservation: Bool
    ) -> Bool {
        observedTrackCountDecreased && settledCleanModalObservation
    }

    /// A reconciliation is settled clean only after a read that finds no
    /// blocking modal at all. A witnessed action is deliberately insufficient:
    /// its close witness concerns the action's target, while State A needs a
    /// fresh observation of the complete blocker set.
    static func deletionModalObservationIsSettledClean(
        _ outcome: ModalReconcileOutcome,
        arrangeWindowWasRead: Bool
    ) -> Bool {
        // The modal read answers "no blocker", which is truthful even when there is no main window
        // to hold one — during `project.new` there genuinely is not one yet. A track deletion is
        // different: the count it just read comes FROM the arrange window, so a decrement observed
        // while that window cannot be resolved is a transient AX failure wearing the shape of a
        // successful delete. Require the window here, where the requirement actually belongs,
        // rather than making every caller of the modal read pretend absence is unreadable.
        outcome.kind == .none
            && outcome.modalObservationIsComplete
            && arrangeWindowWasRead
    }

    /// Two complete clean reads make the delete State-A gate temporal rather
    /// than a single racy snapshot. The delete poll cadence is one second, so
    /// a decrement pays one additional ~1s observation interval before State A
    /// can be certified.
    static func deletionCleanObservationStreakIsSettled(
        _ consecutiveCleanObservationCount: Int
    ) -> Bool {
        consecutiveCleanObservationCount >= 2
    }

    static func defaultDeleteTrack(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        // Resolve the arrange window once for the entire destructive envelope.
        // The before and after counts must describe this same AX element; a
        // best-effort `mainWindow()` read can otherwise flatten an unreadable
        // rail to zero or silently switch windows between the two observations.
        let arrangeWindow = AXLogicProElements.arrangeWindowRead(runtime: runtime)
        let beforeTrackRead: AXLogicProElements.TrackHeaderRead
        switch arrangeWindow {
        case .found(let window):
            beforeTrackRead = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        case .absent:
            beforeTrackRead = .unavailable
        case .unreadable:
            beforeTrackRead = .unreadable
        }
        let beforeCount: Int?
        switch beforeTrackRead {
        case .read(let headers):
            beforeCount = headers.count
        case .unavailable, .unreadable:
            beforeCount = nil
        }
        let click = clickTrackMenu(
            // `トラックを削除` measured 2026-08-17 (Logic 12.3, AppleLanguages=ja). EXACT matching is
            // load-bearing here: the same menu also carries `使用されていないトラックを削除`
            // (Delete Unused Tracks), which ENDS WITH the same string — a suffix or containment match
            // would reach a different destructive command that deletes tracks the caller never named.
            AXLocalePolicy.deleteTrackMenuItem.labels,
            runtime: runtime
        )
        guard click.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track > \(AXLocalePolicy.deleteTrackMenuItem.canonical) menu item not found / not pressable",
                extras: ["track_count_before": beforeCount ?? NSNull()]
            ))
        }

        let menuClicked = (
            (try? JSONSerialization.jsonObject(with: Data(click.message.utf8))) as? [String: String]
        )?["menu_clicked"] ?? AXLocalePolicy.deleteTrackMenuItem.canonical

        var extras: [String: Any] = [
            "menu_clicked": menuClicked,
            "track_count_before": beforeCount ?? NSNull(),
            "requested_delta": -1
        ]

        // #346: a channel-strip delete raises a "delete channel strips…" confirm
        // sheet, and a delete that empties the project raises the mandatory New
        // Track sheet (Cancel disabled, Escape inert) — both wedge Logic until
        // reconciled. Each sheet KIND receives at most one direct action while
        // it remains visible; a sequential delete-confirm → mandatory-New-Track
        // transition can therefore reconcile both without double-pressing either.
        // Reconciliation is ADDITIVE:
        // State A below still requires a real decrement, so auto-Creating a
        // replacement track on delete-to-zero correctly stays an honest State B
        // rather than a fabricated success.
        var reconcileKind = ModalReconciliation.BlockingModalKind.none
        var reconcileAction = "none"
        // #453: an acknowledgement the executor declined must reach the envelope.
        // Kept beside kind/action so a refusal on any attempt survives to the
        // result, rather than being overwritten by a later clean pass.
        var reconcileRefusal: AlertAcknowledgeRefusal?
        var reconcileActionFailure: AXHelpers.AXActionError?
        var reconcileWitnessSummary: ModalReconcileWitnessSummary?
        var reconcileUnreadableReason: ModalReadFailure?
        // #549: which exact node/scan the sheet scan gave up on, mirrored
        // beside `reconcileUnreadableReason` at every site that sets/clears it.
        var reconcileSheetScanFailureDetail: ModalSheetScanFailureDetail?
        // #1077: the one-action-per-kind rule lives in `ModalActionLatch`, shared
        // with the MCU automation watch. It also keeps what was done about each
        // kind, so a kind seen again after a different one still reports its
        // own action.
        var modalLatch = ModalActionLatch()
        var mandatoryNewTrackReconciliationPerformed = false
        var consecutiveCleanModalObservations = 0

        // Absorbs one modal reading into the envelope's provenance. A poll
        // passes its observation and then, when the executor ran, the
        // executor's own read, in the order they were taken (#1077): a blocker
        // the observation saw is kept even when the fresh read then fails or
        // finds nothing.
        func absorbModalReading(_ outcome: ModalReconcileOutcome) {
            if outcome.kind != .none {
                reconcileKind = outcome.kind
                // Never claim a decision label as an action when no direct
                // press/key event was issued. A kind something acted on keeps
                // its own action and witness whenever it is seen again; a kind
                // nothing acted on reports `none` and does not inherit another
                // kind's witness.
                if let acted = modalLatch.action(on: outcome.kind) {
                    reconcileAction = reconcileActionLabel(acted.decision)
                    reconcileWitnessSummary = acted.witnessSummary
                } else {
                    reconcileAction = "none"
                    reconcileWitnessSummary = outcome.witnessSummary
                }
                if let refusal = outcome.refusal { reconcileRefusal = refusal }
                if let actionFailure = outcome.actionFailure { reconcileActionFailure = actionFailure }
                if let unreadableReason = outcome.unreadableReason {
                    reconcileUnreadableReason = unreadableReason
                    reconcileSheetScanFailureDetail = outcome.sheetScanFailureDetail
                }
                // `mandatoryNewTrackReconciliationPerformed` feeds both
                // `mandatory_track_reconciliation_performed` and
                // `new_track_dialog_auto_confirmed` below. `actionAttempted`
                // is true even when AX rejected the press (e.g. -25202 on a
                // stale Create button); only `actionAccepted` means AX itself
                // took the click.
                if outcome.kind == .mandatoryNewTrack, outcome.actionAccepted {
                    mandatoryNewTrackReconciliationPerformed = true
                }
            } else if outcome.modalObservationIsComplete {
                // A complete clean pass proves the prior visible kinds closed,
                // so a later instance is eligible for one fresh direct action.
                modalLatch.reopen()
                reconcileUnreadableReason = nil
                reconcileSheetScanFailureDetail = nil
            } else if let unreadableReason = outcome.unreadableReason {
                // An incomplete no-modal answer is neither a blocker nor a
                // clean pass. Preserve its diagnostic and leave the action
                // latch intact until a later complete observation settles it.
                reconcileUnreadableReason = unreadableReason
                reconcileSheetScanFailureDetail = outcome.sheetScanFailureDetail
            }
        }

        // `nil` means no post-delete rail read succeeded. Do not initialize this
        // from `beforeCount`: serialising that pre-delete number as "after" makes
        // four unreadable polls externally indistinguishable from four observed
        // no-delta polls.
        var lastObservedCount: Int?
        for attempt in 0..<4 {
            try? await Task.sleep(nanoseconds: 250_000_000)

            // Carry the operation's one resolved arrange candidate into every
            // post-delete header and modal read. A failed header traversal is
            // deliberately not `0`: only `.read([])` is an observed empty rail,
            // so a transient AX failure cannot resemble a successful delete.
            let currentTrackRead: AXLogicProElements.TrackHeaderRead
            switch arrangeWindow {
            case .found(let window):
                currentTrackRead = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
            case .absent:
                currentTrackRead = .unavailable
            case .unreadable:
                currentTrackRead = .unreadable
            }
            let currentCount: Int?
            switch currentTrackRead {
            case .read(let headers):
                currentCount = headers.count
                lastObservedCount = headers.count
            case .unavailable, .unreadable:
                currentCount = nil
            }
            // Observe first, then action only once for that visible sheet kind.
            // This bounds a Create press without globally wedging a later,
            // different blocker in the same delete operation. The executor's
            // fresh read is handed the kinds already acted on and declines
            // them, so finding one of those again does not press it again.
            let step = await modalLatch.poll(
                observe: {
                    observeModalAfterMutation(
                        isDeleteContext: true,
                        arrangeWindow: arrangeWindow,
                        runtime: runtime
                    )
                },
                reconcile: { withholding in
                    await reconcileAfterMutation(
                        isDeleteContext: true,
                        withholding: withholding,
                        runtime: runtime
                    )
                }
            )
            let observed = step.observed
            absorbModalReading(observed)
            if let reconciled = step.reconciled { absorbModalReading(reconciled) }
            let observedTrackCountDecreased = beforeCount.flatMap { beforeCount in
                currentCount.map { $0 < beforeCount }
            } ?? false
            if observedTrackCountDecreased,
               deletionModalObservationIsSettledClean(
                   // The direct recovery path may perform a fresh read in
                   // order to bind an action to its classifier. That later
                   // read is not this poll's sheet observation, so it cannot
                   // turn a sheet we just saw on `arrangeWindow` into clean.
                   // Only `observed` shares the count's resolved window.
                   observed,
                   arrangeWindowWasRead: currentCount != nil
               ) {
                consecutiveCleanModalObservations += 1
            } else {
                consecutiveCleanModalObservations = 0
            }
            if let beforeCount,
               let currentCount,
               deletionCountCanCertifyStateA(
                observedTrackCountDecreased: observedTrackCountDecreased,
                settledCleanModalObservation: deletionCleanObservationStreakIsSettled(
                    consecutiveCleanModalObservations
                )
            ) {
                extras["track_count_after"] = currentCount
                extras["observed_delta"] = currentCount - beforeCount
                mergeReconcileExtras(
                    &extras,
                    kind: reconcileKind,
                    action: reconcileAction,
                    newTrackAutoConfirmed: mandatoryNewTrackReconciliationPerformed,
                    witnessSummary: reconcileWitnessSummary,
                    refusal: reconcileRefusal,
                    actionFailure: reconcileActionFailure,
                    unreadableReason: reconcileUnreadableReason,
                    sheetScanFailureDetail: reconcileSheetScanFailureDetail
                )
                return .success(HonestContract.encodeStateA(extras: extras))
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        extras["track_count_after"] = lastObservedCount ?? NSNull()
        if let beforeCount, let lastObservedCount {
            extras["observed_delta"] = lastObservedCount - beforeCount
        } else {
            extras["observed_delta"] = NSNull()
        }
        if reconcileKind == .mandatoryNewTrack {
            extras["mandatory_track_reconciliation_performed"] = mandatoryNewTrackReconciliationPerformed
        }
        mergeReconcileExtras(
            &extras,
            kind: reconcileKind,
            action: reconcileAction,
            newTrackAutoConfirmed: mandatoryNewTrackReconciliationPerformed,
            witnessSummary: reconcileWitnessSummary,
            refusal: reconcileRefusal,
            actionFailure: reconcileActionFailure,
            unreadableReason: reconcileUnreadableReason,
            sheetScanFailureDetail: reconcileSheetScanFailureDetail
        )
        return .success(HonestContract.encodeStateB(
            reason: .retryExhausted,
            extras: extras
        ))
    }

    private static func clickTrackMenu(
        _ menuItemTitle: String,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        clickTrackMenu([menuItemTitle], runtime: runtime)
    }

    /// The bar comes from `AXLocalePolicy.trackMenuBar` and nowhere else.
    ///
    /// It used to default to `menuName: "트랙", englishMenuName: "Track"` and put those two ahead
    /// of the policy's labels so "an explicit override wins". No caller ever overrode them, the
    /// policy already carried both, and the pair was the last Korean literal on this path -- while
    /// the LabelSet it shadowed now holds all ten languages Logic ships.
    private static func clickTrackMenu(
        _ menuItemTitles: [String],
        runtime: AXLogicProElements.Runtime = .production,
        permittingWrite: (() -> Bool)? = nil
    ) -> ChannelResult {
        // #519: the menu-bar spellings live in AXLocalePolicy now rather than in this array. The
        // Japanese `トラック` was measured on Logic 12.3 with `AppleLanguages=ja` and is a third
        // spelling, not a variant of either of the others; without it every menu-driven track
        // operation returned `element_not_found` on a Japanese Logic. That measurement is preserved
        // in `AXLocalePolicy.trackMenuBar`, where a fourth measured language can join it instead of
        // becoming a fourth element in a literal here.
        //
        // The caller-supplied names still come first so an explicit override wins, and the policy's
        // labels are appended rather than replacing them.
        for menuTitle in AXLocalePolicy.trackMenuBar.labels {
            for itemTitle in menuItemTitles {
                guard let item = AXLogicProElements.menuItem(path: [menuTitle, itemTitle], runtime: runtime) else {
                    continue
                }
                guard permittingWrite?() ?? true else { return .error("Track menu target changed before actuation") }
                guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
                    return .error("Failed to click menu item: \(itemTitle)")
                }
                return .success("{\"menu_clicked\":\"\(itemTitle)\"}")
            }
        }
        let joinedTitles = menuItemTitles.joined(separator: " | ")
        return .error("Cannot find menu item: \(AXLocalePolicy.trackMenuBar.canonical) > \(joinedTitles)")
    }

}
