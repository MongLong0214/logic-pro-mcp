@preconcurrency import ApplicationServices
import Carbon
import Foundation

/// One native, request-owned aux creator/inverse. No public command, bus allocator,
/// planner or journal is introduced here. Native control bindings are not Codable.
enum OwnedAuxLifecycle {
    enum Field: CaseIterable, Hashable, Sendable {
        case format, input, output, volume, pan, mute, solo, automationMode
        case automationEnabled, eqEnabled, gainReductionEnabled

        var numeric: Bool {
            switch self {
            case .volume, .pan, .automationEnabled: true
            default: false
            }
        }
        var attribute: String {
            switch self {
            case .input, .output, .automationMode: kAXDescriptionAttribute
            default: kAXValueAttribute
            }
        }
        var role: String {
            switch self {
            case .volume, .pan: kAXSliderRole as String
            case .automationMode: kAXGroupRole as String
            case .automationEnabled: kAXCheckBoxRole as String
            default: kAXButtonRole as String
            }
        }
    }

    enum Value: Equatable, Sendable {
        case text(String), number(Double)
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.text(let a), .text(let b)): a.utf8.elementsEqual(b.utf8)
            case (.number(let a), .number(let b)): a.isFinite && b.isFinite && a == b
            default: false
            }
        }
    }
    enum Status: Equatable, Sendable {
        case rejectedBeforeWrite, pending, created, configurationPartial, residual, removed
    }
    struct OwnedInverse: @unchecked Sendable {
        fileprivate let owner: UUID
        fileprivate let strip: AXUIElement
        fileprivate let footprint: [Node]
    }
    enum TrackStatus: Sendable { case rejectedBeforeWrite, pending, appended, readFocusPrepared, configurationPartial }
    struct TrackReceipt: Sendable {
        let status: TrackStatus
        /// Retained even when later preservation fails; not a deletion capability.
        let track: AXTrackBinding.Binding?
        let diagnostic: String?
        let uiEffects: SessionPopulationObservation.UIEffects
    }
    enum InputStatus: Sendable { case rejectedBeforeWrite, initialized, configurationPartial }
    struct InputReceipt: Sendable {
        let status: InputStatus
        let effect: AccessibilityChannel.ChangedInputObservation?
        let result: ChannelResult?
        let diagnostic: String?
        let uiEffects: SessionPopulationObservation.UIEffects
    }

    /// Minted only by the original creation Context after a real selected
    /// association and independent checked input. Never decoded from parameters.
    struct InputInitializationProof: @unchecked Sendable {
        fileprivate let owner: UUID
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let before: InputAssignment
        let destination: Int
        private let checked: AccessibilityChannel.CheckedOutputReading
        private let permitting: @Sendable (AXUIElement?) -> Bool

        fileprivate init(owner: UUID, pair: AccessibilityChannel.HeldSelectionAssociation.Pair,
                         before: InputAssignment, destination: Int,
                         checked: AccessibilityChannel.CheckedOutputReading,
                         permitting: @escaping @Sendable (AXUIElement?) -> Bool) {
            self.owner = owner; self.pair = pair; self.before = before
            self.destination = destination; self.checked = checked; self.permitting = permitting
        }
        func permitsBefore(_ source: AXMixerStripBinding.Binding, popup: AXUIElement? = nil) -> Bool {
            guard pair.strip.matches(source), pair.track.currentIndex() != nil,
                  case .physical = before, checked.inputAssignment == before,
                  checked.inputSlot?.owner.matches(source) == true,
                  checked.inputRenewal.map({ $0.permits(runtime: pair.track.runtime, ownedPopup: popup) }) ?? true else { return false }
            return permitting(popup)
        }
        func retainedCheckedRead() -> AccessibilityChannel.CheckedOutputReading? {
            permitsBefore(pair.strip) ? checked : nil
        }
        func authorizes(original: AccessibilityChannel.HeldSelectionAssociation.Pair,
                        current: AccessibilityChannel.HeldSelectionAssociation.Pair,
                        before: InputAssignment, after: Int) -> Bool {
            self.before == before && destination == after && pair.track.matches(original.track)
                && pair.strip.matches(original.strip) && pair.track.matches(current.track)
        }
    }

    private final class InputCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AccessibilityChannel.ChangedInputObservation?
        func record(_ effect: AccessibilityChannel.ChangedInputObservation) { lock.withLock { value = effect } }
        func read() -> AccessibilityChannel.ChangedInputObservation? { lock.withLock { value } }
    }
    struct Receipt: @unchecked Sendable {
        let status: Status
        let created: AXUIElement?
        let defaults: [Field: Value]?
        let inverse: OwnedInverse?
        let diagnostic: String?
        let uiEffects: SessionPopulationObservation.UIEffects
        init(status: Status, created: AXUIElement?, defaults: [Field: Value]?, inverse: OwnedInverse?, diagnostic: String? = nil,
             uiEffects: SessionPopulationObservation.UIEffects = .init()) {
            self.status = status; self.created = created; self.defaults = defaults
            self.inverse = inverse; self.diagnostic = diagnostic
            self.uiEffects = uiEffects
        }
    }

    struct Node: @unchecked Sendable {
        let element: AXUIElement
        let children: [AXUIElement]
        let fields: [String: Value]

        func matches(_ other: Self) -> Bool {
            CFEqual(element, other.element) && fields == other.fields
                && children.count == other.children.count
                && zip(children, other.children).allSatisfy { CFEqual($0, $1) }
        }
    }

    /// An owned input change can make the selected Aux ineligible for a dormant
    /// control-bar utility (native Tuner). This is availability/help metadata,
    /// not permission to change any checkbox value or to restore that utility.
    /// Keep exact objects/children and every other field; allow only one leaf's
    /// measured enabled -> disabled transition under the original control bar.
    static func preservesInputInitializationOutside(_ before: [Node], _ after: [Node]?,
                                                    controlBar: AXUIElement?) -> Bool {
        guard let after, before.count == after.count else { return false }
        if zip(before, after).allSatisfy({ $0.matches($1) }) { return true }
        guard let controlBar, before.filter({ CFEqual($0.element, controlBar) }).count == 1,
              let bar = before.first(where: { CFEqual($0.element, controlBar) }),
              bar.fields[kAXRoleAttribute] == .text(kAXGroupRole as String) else { return false }
        var descendants: [AXUIElement] = [], pending = bar.children
        while let element = pending.popLast() {
            guard descendants.count < before.count,
                  !descendants.contains(where: { CFEqual($0, element) }),
                  let node = before.first(where: { CFEqual($0.element, element) }) else { return false }
            descendants.append(element); pending.append(contentsOf: node.children)
        }
        var deactivated = 0
        for (old, current) in zip(before, after) where !old.matches(current) {
            guard CFEqual(old.element, current.element), old.children.isEmpty, current.children.isEmpty,
                  descendants.contains(where: { CFEqual($0, old.element) }),
                  old.fields[kAXRoleAttribute] == .text(kAXCheckBoxRole as String),
                  current.fields[kAXRoleAttribute] == .text(kAXCheckBoxRole as String),
                  old.fields[kAXValueAttribute] == .number(0), current.fields[kAXValueAttribute] == .number(0),
                  old.fields[kAXEnabledAttribute] == .number(1), current.fields[kAXEnabledAttribute] == .number(0) else { return false }
            var a = old.fields, b = current.fields
            for field in [kAXEnabledAttribute, kAXHelpAttribute] { a.removeValue(forKey: field); b.removeValue(forKey: field) }
            guard a == b else { return false }
            deactivated += 1
            guard deactivated == 1 else { return false }
        }
        return deactivated == 1
    }

    /// Operation state only: callers must retain this same context to reconcile an
    /// uncertain receipt. It is not a second lifecycle journal or a serializable token.
    actor Context {
        private struct TrackBaseline {
            let headers: [AXUIElement]
            let radios: [AXUIElement]
            let outside: [Node]
            let strips: [[Node]]
            let rail: AXUIElement
        }
        private let owner = UUID()
        private let bindings: [AXMixerStripBinding.Binding]
        private let options: AXUIElement
        private let edit: AXUIElement
        private let acceptedDefaults: [Field: Value]
        private let runtime: AXLogicProElements.Runtime
        private let mouse: AXMouseHelper.Runtime
        private let topologyNavigation: AccessibilityChannel.OwnedMixerObservationNavigation?
        private let initialControls: (@Sendable (AXUIElement) -> [Field: AXUIElement]?)?
        private let samples: Int
        private let waitForNextSample: @Sendable () async throws -> Void
        private var issued = false
        private var deleteIssued = false
        private var before: [[Node]]?
        private var preservationPeers: [AXUIElement]
        private var outsideMixer: [Node]?
        private var held: Receipt?
        private var observedCreated: AXUIElement?
        private var createdSelectionPending = false
        private var createdSelectionIssued = false
        private var topologyRefreshAttempted = false
        private var trackAppendIssued = false
        private var trackBaseline: TrackBaseline?
        private var observedTrack: AXTrackBinding.Binding?
        private var createdReadFocusBefore: (population: [AXUIElement], selected: AXUIElement)?
        private var inputInitializationDestination: Int?
        private var inputInitializationInProgress = false
        private var inputInitializationReceipt: InputReceipt?
        private var inputInitializationAfter: (outside: [Node], strips: [[Node]])?
        private var uiEffects = SessionPopulationObservation.UIEffects()
        private var ownedMenu: (control: AXUIElement, reportedParent: AXUIElement,
                                popupParent: AXUIElement, attachmentParent: AXUIElement,
                                ancestor: Node?, children: [AXUIElement], menu: AXUIElement)?

        fileprivate init(bindings: [AXMixerStripBinding.Binding], options: AXUIElement,
                         edit: AXUIElement, acceptedDefaults: [Field: Value],
                         runtime: AXLogicProElements.Runtime, mouse: AXMouseHelper.Runtime,
                         topologyNavigation: AccessibilityChannel.OwnedMixerObservationNavigation?,
                         initialControls: (@Sendable (AXUIElement) -> [Field: AXUIElement]?)?,
                         samples: Int, waitForNextSample: @escaping @Sendable () async throws -> Void) {
            self.bindings = bindings; self.options = options; self.edit = edit
            preservationPeers = bindings.map(\.strip)
            self.acceptedDefaults = acceptedDefaults; self.runtime = runtime
            self.mouse = mouse
            self.topologyNavigation = topologyNavigation
            self.initialControls = initialControls; self.samples = samples
            self.waitForNextSample = waitForNextSample
        }

        private func receipt(_ status: Status, strip: AXUIElement? = nil,
                             defaults: [Field: Value]? = nil, inverse: OwnedInverse? = nil,
                             diagnostic: String? = nil) -> Receipt {
            // TEMP: expose the existing receipt path omitted by the manual
            // pending harness. No new observation or authority is introduced.
            if status == .pending {
                Log.info("Owned Aux click receipt: status=pending,diagnostic=\(diagnostic ?? "none"),issued=\(issued),created_retained=\(observedCreated != nil),original_count=\(bindings.count)", subsystem: "ax")
            }
            return .init(status: status, created: strip, defaults: defaults, inverse: inverse, diagnostic: diagnostic, uiEffects: uiEffects)
        }

        private func ownsNativeKeyboard(_ pid: pid_t) -> Bool {
            // AX focus alone can still name Logic beneath a foreign modal.
            // Reuse the existing window-server observation; absent evidence is
            // not permission and a same-bundle different PID is not this target.
            guard let observation = runtime.observeFrontmost?(), observation.isReady,
                  observation.keyboardOwnerPID == pid else { return false }
            return runtime.focusedApplicationPID() == pid
        }

        private func permitted() -> Bool {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let pid = runtime.logicProPID(), ownsNativeKeyboard(pid),
                  case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                  CFEqual(window, bindings[0].window),
                  case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime),
                  document.utf8.elementsEqual(bindings[0].document.utf8),
                  let discovery = try? AXLogicProElements.mixerPopulationAreaLookup(in: window, runtime: runtime,
                      requiresCompleteAbsence: true, checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  let binding = discovery.binding, CFEqual(binding.mixer, bindings[0].mixer),
                  let presentation = try? AXLogicProElements.mixerPresentationRead(binding: binding, runtime: runtime.ax,
                      checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  presentation.presentation.mode == "all", presentation.presentation.typeFilters.count == 8,
                  presentation.presentation.typeFilters.values.allSatisfy({ $0 == true }),
                  menuBound(options, presentation: presentation), menuBound(edit, presentation: presentation),
                  let transport = try? AXLogicProElements.observedTransportActivity(in: window, runtime: runtime,
                      checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
                  !transport.isPlaying, !transport.isRecording else { return false }
            return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }

        private func menuBound(_ control: AXUIElement, presentation: AXLogicProElements.MixerPresentationRead) -> Bool {
            guard presentation.elements.filter({ CFEqual($0, control) }).count == 1,
                  AXHelpers.getRole(control, runtime: runtime.ax) == kAXMenuButtonRole as String,
                  case .success(let parent?) = AXHelpers.getAttributeResult(control, kAXParentAttribute,
                      runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError>,
                  presentation.elements.filter({ CFEqual($0, parent) }).count == 1,
                  case .success(let children) = AXHelpers.childrenResult(parent, runtime: runtime.ax),
                  children.filter({ CFEqual($0, control) }).count == 1 else { return false }
            return true
        }

        /// Renew the held document after heavyweight observations and check the
        /// request's existing permission immediately before a new native action.
        private func actionContextCurrent() -> Bool {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  let pid = runtime.logicProPID(),
                  case .success(let document?) = AXLogicProElements.projectPickerDocumentRead(bindings[0].window, runtime: runtime),
                  document.utf8.elementsEqual(bindings[0].document.utf8), ownsNativeKeyboard(pid) else { return false }
            return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }

        private func focusedOn(_ strip: AXUIElement, allowing menu: AXUIElement? = nil) -> Bool {
            guard let app = AXLogicProElements.appRoot(runtime: runtime),
                  case .success(let focus?) = AXHelpers.getAttributeResult(app, kAXFocusedUIElementAttribute,
                      runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError> else { return false }
            if CFEqual(focus, strip) { return true }
            // Native Mixer-only Aux selection can leave keyboard focus on the
            // containing Mixer. Its exact identity is necessary but insufficient:
            // the independently read selection must still be this sole strip.
            if ownsMixerFocus(focus, app: app) { return selectedOnly(strip) }
            guard let menu, let nodes = footprint(menu) else { return false }
            return nodes.contains(where: { CFEqual($0.element, focus) })
        }

        private func ownsMixerFocus(_ focus: AXUIElement, app: AXUIElement) -> Bool {
            if CFEqual(focus, bindings[0].mixer) { return true }
            // Logic 12.3 focuses the enclosing Mixer group rather than its
            // inner strip area. Reuse discovery's real owner path, not a name
            // match or arbitrary ancestor, and keep its held child identity.
            if let outsideMixer,
               let heldOwner = outsideMixer.first(where: { CFEqual($0.element, focus) }),
               let discovery = try? AXLogicProElements.mixerPopulationAreaLookup(in: bindings[0].window,
                    runtime: runtime, requiresCompleteAbsence: true,
                    checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
               let binding = discovery.binding, CFEqual(binding.mixer, bindings[0].mixer),
               binding.owners.filter({ CFEqual($0, focus) }).count == 1,
               unchangedGroup(heldOwner),
               case .success(let finalFocus?) = AXHelpers.getAttributeResult(app, kAXFocusedUIElementAttribute,
                    runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError>,
               CFEqual(focus, finalFocus) { return true }
            return false
        }

        private func mixerIsFocused() -> Bool {
            guard let app = AXLogicProElements.appRoot(runtime: runtime),
                  case .success(let focus?) = AXHelpers.getAttributeResult(app, kAXFocusedUIElementAttribute,
                    runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError> else { return false }
            return ownsMixerFocus(focus, app: app)
        }

        private func creatorFrame(_ leaf: AXUIElement) -> CGRect? {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  case .success(let rawPoint?) = AXHelpers.getAttributeResult(leaf, kAXPositionAttribute,
                    runtime: runtime.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                  case .success(let rawSize?) = AXHelpers.getAttributeResult(leaf, kAXSizeAttribute,
                    runtime: runtime.ax) as Result<AnyObject?, AXHelpers.AXStatusError>,
                  let point = AXHelpers.point(fromRawAttribute: rawPoint),
                  let size = AXHelpers.size(fromRawAttribute: rawSize),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 1, size.height > 1 else { return nil }
            let frame = CGRect(origin: point, size: size)
            guard frame.midX.isFinite, frame.midY.isFinite else { return nil }
            return frame
        }

        private func originalsInOrder(_ current: [AXUIElement]) -> Bool {
            same(current.filter { element in preservationPeers.contains(where: { CFEqual($0, element) }) }, preservationPeers)
        }

        private func census() -> [AXUIElement]? {
            guard permitted(), let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(
                in: bindings[0].mixer, runtime: runtime.ax) else { return nil }
            for index in census.strips.indices {
                if census.strips[..<index].contains(where: { CFEqual($0, census.strips[index]) }) { return nil }
            }
            return census.strips
        }

        private func same(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { CFEqual($0, $1) }
        }

        private func sameRetainedPeers(_ expected: [AXUIElement], _ current: [AXUIElement]) -> Bool {
            same(expected, current.filter { element in expected.contains(where: { CFEqual($0, element) }) })
        }

        private func menus(_ control: AXUIElement) -> [AXUIElement]? {
            guard case .success(let result) = AXHelpers.censusDescendantResult(of: control,
                role: kAXMenuRole, maxDepth: 4, runtime: runtime.ax, requiresCompleteTraversal: true,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil }) else { return nil }
            return result.matches
        }

        private func parent(_ control: AXUIElement) -> AXUIElement? {
            guard case .success(let parent?) = AXHelpers.getAttributeResult(control, kAXParentAttribute,
                runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError> else { return nil }
            return parent
        }

        private func unchangedGroup(_ node: Node) -> Bool {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  AXHelpers.getRole(node.element, runtime: runtime.ax) == kAXGroupRole as String,
                  case .success(let children) = AXHelpers.childrenResult(node.element, runtime: runtime.ax),
                  same(node.children, children) else { return false }
            return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }

        private func retainOpenedMenu(_ control: AXUIElement, parent: AXUIElement,
                                      beforeNodes: [Node], beforeControlChildren: [AXUIElement]) -> Bool {
            guard let observed = menus(control), observed.count == 1,
                  let currentParent = self.parent(control), CFEqual(currentParent, parent),
                  !beforeControlChildren.contains(where: { CFEqual($0, observed[0]) }),
                  !beforeNodes.contains(where: { node in
                      CFEqual(node.element, observed[0]) || node.children.contains(where: { CFEqual($0, observed[0]) })
                  }),
                  let menuParent = self.parent(observed[0]),
                  case .success(let peers) = AXHelpers.childrenResult(parent, runtime: runtime.ax),
                  peers.filter({ CFEqual($0, control) }).count == 1 else { return false }
            let beforeChildren: [AXUIElement]
            let attachmentParent: AXUIElement
            let ancestor: Node?
            if CFEqual(menuParent, control) {
                beforeChildren = beforeControlChildren
                attachmentParent = control; ancestor = nil
            } else {
                // Reported popup AXParent can be one held group above the actual
                // insertion owner. Accept only the measured unique BEFORE path
                // group -> reported control-parent group -> held control, or the
                // existing direct edge; never an arbitrary ancestor/group/name.
                let owners = beforeNodes.filter { CFEqual($0.element, menuParent) }
                guard owners.count == 1, let owner = owners.first,
                      owner.fields[kAXRoleAttribute] == .text(kAXGroupRole as String) else { return false }
                if owner.children.filter({ CFEqual($0, control) }).count == 1 {
                    beforeChildren = owner.children; attachmentParent = owner.element; ancestor = nil
                } else {
                    let intermediates = beforeNodes.filter { node in
                        node.fields[kAXRoleAttribute] == .text(kAXGroupRole as String)
                            && owner.children.filter({ CFEqual($0, node.element) }).count == 1
                            && node.children.filter({ CFEqual($0, control) }).count == 1
                    }
                    guard intermediates.count == 1, let intermediate = intermediates.first,
                          CFEqual(intermediate.element, parent), unchangedGroup(owner) else { return false }
                    beforeChildren = intermediate.children; attachmentParent = intermediate.element; ancestor = owner
                }
            }
            let expectedRole = CFEqual(attachmentParent, control) ? kAXMenuButtonRole : kAXGroupRole
            guard AXHelpers.getRole(attachmentParent, runtime: runtime.ax) == expectedRole as String,
                  case .success(let attached) = AXHelpers.childrenResult(attachmentParent, runtime: runtime.ax),
                  attached.filter({ CFEqual($0, observed[0]) }).count == 1,
                  sameRetainedPeers(beforeChildren, attached) else { return false }
            ownedMenu = (control, parent, menuParent, attachmentParent, ancestor, beforeChildren, observed[0])
            return true
        }

        /// The host exposes the owned popup via its button while also attaching
        /// that same CF as a sibling under the held group. Only that retained,
        /// newly opened object is transient; other menus/nodes remain protected.
        private func ownedMenuExclusion(requiringPreservedChildren: Bool = true) -> [AXUIElement]? {
            guard let ownedMenu else { return [] }
            if let ancestor = ownedMenu.ancestor, !unchangedGroup(ancestor) { return nil }
            let expectedRole = CFEqual(ownedMenu.attachmentParent, ownedMenu.control) ? kAXMenuButtonRole : kAXGroupRole
            guard let currentParent = parent(ownedMenu.control), CFEqual(currentParent, ownedMenu.reportedParent),
                  case .success(let peers) = AXHelpers.childrenResult(ownedMenu.reportedParent, runtime: runtime.ax),
                  peers.filter({ CFEqual($0, ownedMenu.control) }).count == 1,
                  AXHelpers.getRole(ownedMenu.attachmentParent, runtime: runtime.ax) == expectedRole as String,
                  case .success(let attached) = AXHelpers.childrenResult(ownedMenu.attachmentParent, runtime: runtime.ax),
                  sameRetainedPeers(ownedMenu.children, attached),
                  let observed = menus(ownedMenu.control) else { return nil }
            if requiringPreservedChildren,
               !same(ownedMenu.children, attached.filter({ !CFEqual($0, ownedMenu.menu) })) { return nil }
            if observed.isEmpty {
                return attached.contains(where: { CFEqual($0, ownedMenu.menu) }) ? nil : []
            }
            guard observed.count == 1, CFEqual(observed[0], ownedMenu.menu),
                  let menuParent = parent(ownedMenu.menu),
                  CFEqual(menuParent, ownedMenu.popupParent),
                  attached.filter({ CFEqual($0, ownedMenu.menu) }).count == 1 else { return nil }
            return [ownedMenu.menu]
        }

        private func closeOwnedMenu() -> Bool {
            // Restoring only our owned popup does not authorize the payload or
            // erase a peer drift. Preserve every current peer across that Cancel;
            // the creator/inverse still require the exact original footprint.
            guard let ownedMenu, permitted(),
                  let current = ownedMenuExclusion(requiringPreservedChildren: false) else { return false }
            if current.isEmpty { return true }
            guard case .success(let actions) = AXHelpers.getActionNamesResult(ownedMenu.menu, runtime: runtime.ax),
                  actions.contains(kAXCancelAction as String),
                  case .success(let beforeChildren) = AXHelpers.childrenResult(ownedMenu.attachmentParent, runtime: runtime.ax),
                  let deciding = ownedMenuExclusion(requiringPreservedChildren: false), same(deciding, current),
                  case .success(let decidingChildren) = AXHelpers.childrenResult(ownedMenu.attachmentParent, runtime: runtime.ax),
                  same(beforeChildren, decidingChildren),
                  actionContextCurrent() else { return false }
            _ = AXHelpers.performAction(ownedMenu.menu, kAXCancelAction as String, runtime: runtime.ax)
            guard let after = ownedMenuExclusion(requiringPreservedChildren: false), after.isEmpty,
                  case .success(let afterChildren) = AXHelpers.childrenResult(ownedMenu.attachmentParent, runtime: runtime.ax),
                  same(beforeChildren.filter({ !CFEqual($0, ownedMenu.menu) }), afterChildren),
                  actionContextCurrent() else { return false }
            return true
        }

        private func menuRefusal(_ status: Status, strip: AXUIElement? = nil) -> Receipt {
            guard ownedMenu != nil else { return receipt(status, strip: strip, diagnostic: "owned_menu_ownership_unavailable") }
            return receipt(status, strip: strip,
                diagnostic: closeOwnedMenu() ? nil : "owned_menu_restoration_unverified")
        }

        /// A bounded raw, status-preserving preservation footprint, not the lossy
        /// selector atlas snapshot. Unknown reads refuse rather than become zero/empty.
        private func footprint(_ root: AXUIElement, excluding: [AXUIElement] = [],
                               ignoringTransientMenus: [AXUIElement] = []) -> [Node]? {
            Self.footprint(root, excluding: excluding, ignoringTransientMenus: ignoringTransientMenus, runtime: runtime)
        }

        private nonisolated static func footprint(_ root: AXUIElement, excluding: [AXUIElement] = [],
                               ignoringTransientMenus: [AXUIElement] = [], runtime: AXLogicProElements.Runtime) -> [Node]? {
            var result: [Node] = []
            var visits: [(AXUIElement, Int)] = [(root, 0)]
            while let (element, depth) = visits.popLast() {
                guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                      depth <= 32, result.count < 4096,
                      !result.contains(where: { CFEqual($0.element, element) }) else { return nil }
                let children: [AXUIElement]
                switch AXHelpers.childrenResult(element, runtime: runtime.ax) {
                case .success(let observed): children = observed
                case .failure(let error) where error.source == .axStatus && error.isDefinitiveAbsence:
                    // Reuse the shared strict traversal's native absence semantics.
                    // No value/unsupported is not an unread or malformed branch.
                    children = []
                case .failure: return nil
                }
                var values: [String: Value] = [:]
                // Optional opaque Subrole metadata is not lifecycle state or
                // custody. Keep current Role, control values and exact CF children.
                for attribute in [kAXRoleAttribute, kAXTitleAttribute,
                                  kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute,
                                  kAXValueAttribute, kAXEnabledAttribute] {
                    // A structural scroll/layout container's presentation text is not
                    // musical state or endpoint identity. Its actual role/children
                    // and valued controls remain protected; real control descriptions
                    // (including output and automation) keep their strict reads.
                    if (values[kAXRoleAttribute] == .text(kAXScrollAreaRole as String)
                        || values[kAXRoleAttribute] == .text(kAXLayoutAreaRole as String)),
                       [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute].contains(attribute) {
                        continue
                    }
                    let read: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                        element, attribute, runtime: runtime.ax)
                    switch read {
                    case .success(nil): break
                    case .success(let raw?):
                        // CFBoolean also bridges to NSNumber. A Boolean slider
                        // value must not become a numeric default or authorize
                        // deletion; enabled attributes and checkboxes are binary.
                        if attribute == kAXValueAttribute,
                           values[kAXRoleAttribute] == .text(kAXSliderRole as String),
                           CFGetTypeID(raw) == CFBooleanGetTypeID() { return nil }
                        if CFGetTypeID(raw) == CFStringGetTypeID(), let text = raw as? String {
                            values[attribute] = .text(text)
                        } else if let number = raw as? NSNumber, number.doubleValue.isFinite {
                            values[attribute] = .number(number.doubleValue)
                        } else { return nil }
                    case .failure(let error) where error.isDefinitiveAbsence: break
                    case .failure: return nil
                    }
                }
                let preservedChildren = children.filter { child in
                    !ignoringTransientMenus.contains(where: { CFEqual($0, child) })
                }
                result.append(.init(element: element, children: preservedChildren, fields: values))
                for child in preservedChildren.reversed() where !excluding.contains(where: { CFEqual(child, $0) }) {
                    visits.append((child, depth + 1))
                }
            }
            return result
        }

        private func matches(_ expected: [Node], _ current: [Node]?) -> Bool {
            guard let current, current.count == expected.count else { return false }
            return zip(expected, current).allSatisfy { $0.matches($1) }
        }

        private func sameValues(_ first: [Node], _ second: [Node]) -> Bool {
            first.count == second.count && zip(first, second).allSatisfy {
                $0.fields == $1.fields && $0.children.count == $1.children.count
            }
        }

        private func invalidated(_ strip: AXUIElement) -> Bool {
            guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
            let role: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                strip, kAXRoleAttribute, runtime: runtime.ax)
            guard case .failure(let error) = role, error.source == .axStatus,
                  error.raw == AXError.invalidUIElement.rawValue else { return false }
            return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
        }

        private func preserved() -> Bool {
            guard let before, let outsideMixer, let excluded = ownedMenuExclusion(),
                  matches(outsideMixer, footprint(bindings[0].window, excluding: [bindings[0].mixer, options, edit],
                      ignoringTransientMenus: excluded)),
                  zip(preservationPeers, before).allSatisfy({ matches($1, footprint($0)) }),
                  let bookend = ownedMenuExclusion(), same(excluded, bookend) else { return false }
            return true
        }

        /// A creator may replace the entire native Mixer census. Compare the
        /// complete protected value trees only to establish aggregate peer
        /// preservation, never to rebind an old reference or actuate a peer.
        /// There must be exactly one possible addition before selection/focus
        /// is considered: those observations cannot disambiguate identical trees.
        /// Retain its new CF before configuration validation can fail; all later
        /// checks use exact native identity again.
        private func retainCreationAfterWholeRedraw(_ current: [AXUIElement]) -> Bool {
            guard issued, !deleteIssued, observedCreated == nil,
                  same(preservationPeers, bindings.map(\.strip)),
                  current.count == bindings.count + 1,
                  bindings.allSatisfy({ original in !current.contains { CFEqual($0, original.strip) } }),
                  let before, before.count == bindings.count,
                  let outsideMixer, let excluded = ownedMenuExclusion(), excluded.isEmpty,
                  matches(outsideMixer, footprint(bindings[0].window,
                    excluding: [bindings[0].mixer, options, edit])) else { return false }
            var trees: [[Node]] = []
            for strip in current {
                guard let tree = footprint(strip) else { return false }
                trees.append(tree)
            }
            var candidates: [Int] = []
            for index in current.indices {
                let peerTrees = trees.enumerated().filter { $0.offset != index }.map(\.element)
                guard peerTrees.count == before.count,
                      zip(before, peerTrees).allSatisfy({ sameValues($0, $1) }) else { continue }
                candidates.append(index)
            }
            guard candidates.count == 1, let index = candidates.first,
                  let bookend = census(), same(current, bookend),
                  zip(current, trees).allSatisfy({ matches($1, footprint($0)) }),
                  matches(outsideMixer, footprint(bindings[0].window,
                    excluding: [bindings[0].mixer, options, edit])) else { return false }
            let candidate = current[index]
            let needsSelection: Bool
            if selectedOnly(candidate), focusedOn(candidate) { needsSelection = false }
            else {
                guard selectionIsEmpty(), mixerIsFocused() else { return false }
                needsSelection = true
            }
            guard let final = census(), same(current, final), actionContextCurrent() else { return false }
            preservationPeers = current.enumerated().filter { $0.offset != index }.map(\.element)
            self.before = trees.enumerated().filter { $0.offset != index }.map(\.element)
            observedCreated = candidate
            createdSelectionPending = needsSelection
            return true
        }

        private func selectionIsEmpty() -> Bool {
            guard case .success(.elements(let selected)) = AXHelpers.getAXUIElementArrayRead(
                bindings[0].mixer, kAXSelectedChildrenAttribute, runtime: runtime.ax) else { return false }
            return selected.isEmpty
        }

        private func permitsTopologyRefreshActuation() -> Bool {
            issued && !deleteIssued && observedCreated == nil && actionContextCurrent()
        }

        private func refreshLatentCreation(_ current: [AXUIElement]) async -> Bool {
            guard !topologyRefreshAttempted, permitsTopologyRefreshActuation(),
                  current.count == bindings.count,
                  bindings.allSatisfy({ original in !current.contains { CFEqual($0, original.strip) } }),
                  let before, before.count == current.count, let topologyNavigation,
                  let outsideMixer, let menus = ownedMenuExclusion(), menus.isEmpty,
                  matches(outsideMixer, footprint(bindings[0].window,
                    excluding: [bindings[0].mixer, options, edit])) else { return false }
            for (expected, peer) in zip(before, current) {
                guard let tree = footprint(peer), sameValues(expected, tree) else { return false }
            }
            guard let bookend = census(), same(current, bookend), permitsTopologyRefreshActuation() else { return false }
            topologyRefreshAttempted = true
            let refreshed = await topologyNavigation.refreshAfterIssuedCreation(expectedMixer: bindings[0].mixer,
                permittingActuation: { [self] in permitsTopologyRefreshActuation() },
                stoppingWhen: { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil })
            uiEffects = topologyNavigation.effects
            return refreshed
        }

        /// Select only the already retained, structurally unique creation. An
        /// empty Mixer selection may be acquired once; another selection is not
        /// ours to replace. Lost/late acknowledgement never permits a new setter.
        private func acquireCreatedSelection(_ current: [AXUIElement]) -> Bool {
            guard let strip = observedCreated,
                  current.filter({ CFEqual($0, strip) }).count == 1 else { return false }
            if selectedOnly(strip), focusedOn(strip) {
                createdSelectionPending = false
                return true
            }
            guard !createdSelectionIssued, selectionIsEmpty(), mixerIsFocused(),
                  AXHelpers.isAttributeSettable(bindings[0].mixer, kAXSelectedChildrenAttribute,
                    runtime: runtime.ax) == true,
                  preserved(), let bookend = census(), same(current, bookend),
                  selectionIsEmpty(), mixerIsFocused(), actionContextCurrent(),
                  selectionIsEmpty(), actionContextCurrent() else { return false }
            createdSelectionIssued = true
            uiEffects.navigationPerformed = true; uiEffects.restoration = "not_restored"
            uiEffects.attempted.append("created_aux_selection")
            _ = AXHelpers.setAttribute(bindings[0].mixer, kAXSelectedChildrenAttribute,
                [strip] as CFArray, runtime: runtime.ax)
            guard selectedOnly(strip), focusedOn(strip),
                  let after = census(), same(current, after), preserved(), actionContextCurrent() else { return false }
            createdSelectionPending = false
            uiEffects.changed.append("created_aux_selection")
            return true
        }

        /// Terminal observation only, after the one issued deletion. New peer
        /// objects acquire no reference rebinding or permission for another write.
        private func removedAfterWholePeerRedraw(_ current: [AXUIElement], strip: AXUIElement) -> Bool {
            guard deleteIssued, current.count == preservationPeers.count,
                  !current.contains(where: { CFEqual($0, strip) }),
                  preservationPeers.allSatisfy({ peer in !current.contains { CFEqual($0, peer) } }),
                  let before, before.count == current.count,
                  let outsideMixer, let excluded = ownedMenuExclusion(), excluded.isEmpty,
                  invalidated(strip),
                  matches(outsideMixer, footprint(bindings[0].window,
                    excluding: [bindings[0].mixer, options, edit])) else { return false }
            var trees: [[Node]] = []
            for peer in current {
                guard let tree = footprint(peer) else { return false }
                trees.append(tree)
            }
            guard zip(before, trees).allSatisfy({ sameValues($0, $1) }),
                  let bookend = census(), same(current, bookend),
                  zip(current, trees).allSatisfy({ matches($1, footprint($0)) }),
                  matches(outsideMixer, footprint(bindings[0].window,
                    excluding: [bindings[0].mixer, options, edit])),
                  let final = census(), same(current, final),
                  invalidated(strip), actionContextCurrent() else { return false }
            return true
        }

        private func selectedOnly(_ strip: AXUIElement) -> Bool {
            guard case .success(.elements(let selected)) = AXHelpers.getAXUIElementArrayRead(
                bindings[0].mixer, kAXSelectedChildrenAttribute, runtime: runtime.ax),
                  selected.count == 1, CFEqual(selected[0], strip) else { return false }
            return true
        }

        private func leaf(_ button: AXUIElement, creator: Bool, appendingTrack: Bool = false) -> AXUIElement? {
            // The corpus-derived creator title supplies only semantic discovery,
            // never CF ownership or all-locale native qualification. The inverse is
            // the actual Mixer Edit menu's semantic delete: leaf, not Remove Selected.
            guard case .success(let menu) = AXHelpers.censusDescendantResult(of: button,
                role: kAXMenuItemRole, maxDepth: 4, runtime: runtime.ax,
                requiresCompleteTraversal: true,
                permittingRead: { (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil }) else { return nil }
            var matches: [AXUIElement] = []
            for element in menu.matches {
                // Native separators are disabled AXMenuItems with no semantic
                // identifier. Only an observed disabled state excludes them;
                // unread/malformed enablement cannot hide a possible competitor.
                let enabled: Result<NSNumber?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(element, kAXEnabledAttribute, runtime: runtime.ax)
                guard case .success(let value?) = enabled, value == 0 || value == 1 else { return nil }
                if value == 0 { continue }
                let attribute = creator ? kAXTitleAttribute : kAXIdentifierAttribute
                let text: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(element, attribute, runtime: runtime.ax)
                // An unread/absent/malformed possible competitor cannot be omitted
                // from the uniqueness proof. Only a known nonmatch may be skipped.
                guard case .success(let raw?) = text, CFGetTypeID(raw) == CFStringGetTypeID(),
                      let actual = raw as? String else { return nil }
                let semanticMatch = creator ? (appendingTrack ? AXLocalePolicy.mixerAppendTracksForSelectedStrips : AXLocalePolicy.mixerCreateAuxiliaryChannelStrip).matches(actual, mode: .exactStrict)
                    : actual.utf8.elementsEqual("delete:".utf8)
                if !semanticMatch { continue }
                guard case .success(let children) = AXHelpers.childrenResult(element, runtime: runtime.ax) else { return nil }
                if !children.isEmpty { continue }
                matches.append(element)
            }
            return matches.count == 1 ? matches[0] : nil
        }

        private func defaults(_ strip: AXUIElement) -> [Field: Value]? {
            guard let tree = footprint(strip),
                  let controls = initialControls?(strip) ?? nativeControls(strip, tree: tree),
                  controls.count == Field.allCases.count,
                  let sends = AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime.ax),
                  // The native empty presentation can expose one anchor; the
                  // existing two-anchor shape remains supported. Neither count
                  // substitutes for a complete read of every slot's empty state.
                  (1...2).contains(sends.count), sends.allSatisfy({ $0.state == .observedEmpty }),
                  let plugins = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: runtime.ax),
                  plugins.count == 1, plugins.allSatisfy(\.isEmpty) else { return nil }
            var observed: [Field: Value] = [:]
            for field in Field.allCases {
                guard let control = controls[field],
                      let node = tree.first(where: { CFEqual($0.element, control) }),
                      node.fields[kAXRoleAttribute] == .text(field.role),
                      let value = node.fields[field.attribute],
                      value == acceptedDefaults[field] else { return nil }
                switch (field.numeric, value) {
                case (true, .number), (false, .text): break
                default: return nil
                }
                for other in Field.allCases where other != field {
                    if let peer = controls[other], CFEqual(control, peer),
                       Set([field, other]) != Set([Field.automationMode, .automationEnabled]) { return nil }
                }
                observed[field] = value
            }
            guard let mode = controls[.automationMode], let enabled = controls[.automationEnabled],
                  let group = tree.first(where: { CFEqual($0.element, mode) }),
                  group.children.filter({ CFEqual($0, enabled) }).count == 1 else { return nil }
            return observed
        }

        private func nativeControls(_ strip: AXUIElement, tree: [Node]) -> [Field: AXUIElement]? {
            // Measured native EN/KO shapes, not CUA's switch vocabulary. Derived
            // labels do not qualify lifecycle behavior in unobserved locales.
            // Numeric values remain raw CFNumber values; no 0.0 compatibility fallback.
            func unique(_ field: Field, matching: (Node) -> Bool) -> AXUIElement? {
                let candidates = tree.filter { $0.fields[kAXRoleAttribute] == .text(field.role) && matching($0) }
                return candidates.count == 1 ? candidates[0].element : nil
            }
            func description(_ node: Node) -> String? {
                guard case .text(let value)? = node.fields[kAXDescriptionAttribute] else { return nil }
                return value
            }
            func named(_ field: Field, _ label: String) -> AXUIElement? {
                unique(field) { description($0)?.utf8.elementsEqual(label.utf8) == true }
            }
            guard let format = unique(.format, matching: { AXLocalePolicy.mixerChannelModeControl.matches(description($0), mode: .exactStrict) }),
                  let mute = unique(.mute, matching: { AXLocalePolicy.trackMuteButton.matches(description($0), mode: .exactStrict) }),
                  let solo = unique(.solo, matching: { AXLocalePolicy.trackSoloButton.matches(description($0), mode: .exactStrict) }),
                  let eq = named(.eqEnabled, "EQ"),
                  let gain = unique(.gainReductionEnabled, matching: { AXLocalePolicy.mixerGainReductionMeterControl.matches(description($0), mode: .exactStrict) }),
                  let mode = unique(.automationMode, matching: {
                      AXLocalePolicy.pluginAutomationLabelSubstring.containsAny(in: description($0) ?? "")
                  }),
                  let enabled = unique(.automationEnabled, matching: {
                      AXLocalePolicy.automationModeContext.matches(description($0), mode: .exactStrict)
                  }),
                  let volume = AXLogicProElements.findVolumeFader(in: strip, runtime: runtime.ax, requireUnique: true),
                  let pan = AXLogicProElements.findPanControl(in: strip, runtime: runtime.ax, requireUnique: true),
                  let input = AXLogicProElements.inputSlotRead(in: strip, runtime: runtime.ax).control,
                  let output = AXLogicProElements.outputSlotButton(in: strip, runtime: runtime.ax) else { return nil }
            return [.format: format, .mute: mute, .solo: solo, .eqEnabled: eq, .gainReductionEnabled: gain,
                    .automationMode: mode, .automationEnabled: enabled, .volume: volume, .pan: pan,
                    .input: input, .output: output]
        }

        private func trackReceipt(_ status: TrackStatus, _ diagnostic: String? = nil) -> TrackReceipt {
            .init(status: status, track: observedTrack, diagnostic: diagnostic, uiEffects: uiEffects)
        }

        private func headerSelection(_ headers: [AXUIElement], selectedLast: Bool) -> Bool {
            for (index, header) in headers.enumerated() {
                guard AXValueExtractors.extractSelectedState(header, runtime: runtime.ax)
                    == (selectedLast && index == headers.count - 1) else { return false }
            }
            return true
        }

        private func appendOutsidePreserved(_ baseline: TrackBaseline, track: AXUIElement) -> Bool {
            guard let addedTree = footprint(track), let headerDescription = addedTree.first?.fields[kAXDescriptionAttribute],
                  let menus = ownedMenuExclusion(), menus.isEmpty,
                  let current = footprint(bindings[0].window, excluding: [bindings[0].mixer, options, edit]) else { return false }
            func node(_ element: AXUIElement, in nodes: [Node]) -> Node? {
                let found = nodes.filter { CFEqual($0.element, element) }
                return found.count == 1 ? found.first : nil
            }
            var extra = current.filter { actual in
                !baseline.outside.contains { CFEqual($0.element, actual.element) }
                    && !addedTree.contains { CFEqual($0.element, actual.element) }
            }
            let canvases = baseline.outside.filter {
                $0.fields[kAXRoleAttribute] == .text(kAXGroupRole as String) && {
                    guard case .text(let description)? = $0.fields[kAXDescriptionAttribute] else { return false }
                    return AXLocalePolicy.trackContentExplicit.matches(description, mode: .exact)
                }($0)
            }
            var activatedScrollbar: AXUIElement?
            if canvases.count == 1, let oldCanvas = canvases.first {
                // A new empty row can make its existing viewport scrollable.
                // Recognize only that canvas's exact sibling scrollbar, not a
                // global scroll-value exemption or authority to move a viewport.
                let parents = baseline.outside.filter { $0.children.contains { CFEqual($0, oldCanvas.element) } }
                if parents.count == 1, let parent = parents.first,
                   parent.fields[kAXRoleAttribute] == .text(kAXScrollAreaRole as String) {
                    let candidates = baseline.outside.filter { candidate in
                        parent.children.contains(where: { CFEqual($0, candidate.element) })
                    }
                    for old in candidates where old.fields[kAXRoleAttribute] == .text(kAXScrollBarRole as String)
                        && old.fields[kAXEnabledAttribute] == .number(0)
                        && (old.fields[kAXValueAttribute] == .number(0) || old.fields[kAXValueAttribute] == .number(1))
                        && old.children.isEmpty {
                        guard let actual = node(old.element, in: current) else { return false }
                        if old.matches(actual) { continue }
                        guard activatedScrollbar == nil, actual.children.count == 5,
                              actual.fields[kAXEnabledAttribute] == .number(1), actual.fields[kAXValueAttribute] == .number(0) else { return false }
                        var a = old.fields, b = actual.fields
                        for field in [kAXEnabledAttribute, kAXValueAttribute] { a.removeValue(forKey: field); b.removeValue(forKey: field) }
                        guard a == b else { return false }
                        let subroles = [kAXIncrementArrowSubrole, kAXDecrementArrowSubrole, kAXIncrementPageSubrole, kAXDecrementPageSubrole]
                        for (index, child) in actual.children.enumerated() {
                            guard let control = node(child, in: extra), control.children.isEmpty,
                                  control.fields[kAXRoleAttribute] == .text((index == 0 ? kAXValueIndicatorRole : kAXButtonRole) as String) else { return false }
                            if index == 0 {
                                guard control.fields[kAXValueAttribute] == .number(0) else { return false }
                            } else {
                                let subrole: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(child, kAXSubroleAttribute, runtime: runtime.ax)
                                guard case .success(let observed?) = subrole, observed == subroles[index - 1] as String else { return false }
                            }
                        }
                        extra.removeAll { candidate in actual.children.contains { CFEqual($0, candidate.element) } }
                        activatedScrollbar = old.element
                    }
                }
            }
            var canvas: AXUIElement?, placeholder: AXUIElement?, retitledPlaceholder = false
            var redrawnEmptyRows: [AXUIElement] = []
            if !extra.isEmpty {
                // Appending an empty Track either inserts its empty canvas row
                // before the old blank row, or consumes that row and adds an
                // identical blank. This read-only classifier grants no actuation.
                guard canvases.count == 1,
                      let oldCanvas = canvases.first, let blank = oldCanvas.children.last,
                      let oldBlank = node(blank, in: baseline.outside), oldBlank.children.isEmpty,
                      oldBlank.fields[kAXValueAttribute] == .number(0),
                      oldBlank.fields[kAXDescriptionAttribute] == nil || oldBlank.fields[kAXDescriptionAttribute] == .text(""),
                      let newCanvas = node(oldCanvas.element, in: current), let newBlank = node(blank, in: current) else { return false }
                let oldRows = oldCanvas.children.dropLast().compactMap { node($0, in: baseline.outside) }
                let newRows = newCanvas.children.dropLast().compactMap { node($0, in: current) }
                if oldRows.count == oldCanvas.children.count - 1, !oldRows.isEmpty,
                   oldRows.allSatisfy({ old in !current.contains { CFEqual($0.element, old.element) } }) {
                    // Native append redraws every existing empty canvas row,
                    // but retains the original blank and header prefix. Compare
                    // only a complete zero-valued leaf population. This neither
                    // rebinds retired rows nor permits writes through their rank.
                    guard oldBlank.fields[kAXRoleAttribute] == .text(kAXLayoutAreaRole as String),
                          oldBlank.matches(newBlank), CFEqual(newCanvas.children.last, blank),
                          newRows.count == oldRows.count + 1, extra.count == newRows.count,
                          same(extra.map(\.element), newRows.map(\.element)),
                          (oldRows + newRows).allSatisfy({ $0.children.isEmpty && $0.fields == oldBlank.fields }) else { return false }
                    redrawnEmptyRows = oldRows.map(\.element)
                    canvas = oldCanvas.element
                } else {
                    guard extra.count == 1, extra[0].children.isEmpty else { return false }
                    var oldFields = oldBlank.fields, newFields = newBlank.fields, extraFields = extra[0].fields
                    oldFields.removeValue(forKey: kAXDescriptionAttribute)
                    newFields.removeValue(forKey: kAXDescriptionAttribute)
                    extraFields.removeValue(forKey: kAXDescriptionAttribute)
                    guard oldFields == newFields, oldFields == extraFields else { return false }
                    if extra[0].fields == oldBlank.fields, newBlank.fields[kAXDescriptionAttribute] == headerDescription,
                       same(newCanvas.children, oldCanvas.children + [extra[0].element]) {
                        retitledPlaceholder = true
                    } else {
                        guard newBlank.fields == oldBlank.fields, extra[0].fields[kAXDescriptionAttribute] == headerDescription,
                              same(newCanvas.children, Array(oldCanvas.children.dropLast()) + [extra[0].element, blank]) else { return false }
                    }
                    canvas = oldCanvas.element; placeholder = blank
                }
            }
            for expected in baseline.outside {
                if redrawnEmptyRows.contains(where: { CFEqual($0, expected.element) }) { continue }
                guard let actual = node(expected.element, in: current) else { return false }
                var a = expected.fields, b = actual.fields
                if baseline.radios.contains(where: { CFEqual($0, expected.element) }) {
                    guard b[kAXValueAttribute] == .number(0) else { return false }
                    a.removeValue(forKey: kAXValueAttribute); b.removeValue(forKey: kAXValueAttribute)
                }
                if retitledPlaceholder, let placeholder, CFEqual(expected.element, placeholder) {
                    a.removeValue(forKey: kAXDescriptionAttribute); b.removeValue(forKey: kAXDescriptionAttribute)
                }
                if let activatedScrollbar, CFEqual(expected.element, activatedScrollbar) {
                    a.removeValue(forKey: kAXEnabledAttribute); b.removeValue(forKey: kAXEnabledAttribute)
                    a.removeValue(forKey: kAXValueAttribute); b.removeValue(forKey: kAXValueAttribute)
                }
                guard a == b else { return false }
                if CFEqual(expected.element, baseline.rail) {
                    guard same(actual.children, expected.children + [track]) else { return false }
                } else if let canvas, CFEqual(expected.element, canvas) {
                    // Exact expected canvas child insertion was checked above.
                    continue
                } else if let activatedScrollbar, CFEqual(expected.element, activatedScrollbar) {
                    // Its exact new primitive children were checked above.
                    continue
                } else if !same(expected.children, actual.children) { return false }
            }
            if activatedScrollbar != nil, !uiEffects.changed.contains("arrange_track_scrollbar") {
                uiEffects.changed.append("arrange_track_scrollbar")
            }
            return true
        }

        /// One explicit optional Track stage on this Context's actual creation.
        /// Its native proof cannot be reconstructed from a public allow flag.
        /// No Aux-only inverse is usable once this extra creation is issued.
        func appendArrangeTrack(for proof: OwnedInverse) async -> TrackReceipt {
            guard proof.owner == owner, !deleteIssued, let held, let strip = held.created,
                  CFEqual(proof.strip, strip) else { return trackReceipt(.rejectedBeforeWrite, "owned_aux_proof_required") }
            if !trackAppendIssued {
                guard permitted(), let current = census(), current.count == bindings.count + 1,
                      current.filter({ CFEqual($0, strip) }).count == 1, originalsInOrder(current), preserved(),
                      matches(proof.footprint, footprint(strip)), focusedOn(strip), selectedOnly(strip),
                      let rail = AXLogicProElements.uniqueTrackHeaderRail(in: bindings[0].window, runtime: runtime),
                      case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: bindings[0].window, runtime: runtime),
                      !headers.isEmpty, headerSelection(headers, selectedLast: true),
                      let outside = footprint(bindings[0].window, excluding: [bindings[0].mixer, options, edit]) else {
                    return trackReceipt(.rejectedBeforeWrite, "track_append_before_changed")
                }
                var radios: [AXUIElement] = []
                for (index, header) in headers.enumerated() {
                    guard let tree = footprint(header), let root = tree.first else { return trackReceipt(.rejectedBeforeWrite) }
                    let candidates = tree.filter { node in
                        root.children.contains { CFEqual($0, node.element) } && node.fields[kAXRoleAttribute] == .text(kAXRadioButtonRole as String)
                    }
                    guard candidates.count == 1, let radio = candidates.first,
                          radio.fields[kAXValueAttribute] == .number(index == headers.count - 1 ? 1 : 0) else {
                        return trackReceipt(.rejectedBeforeWrite, "header_focus_state_unverified")
                    }
                    radios.append(radio.element)
                }
                let strips = current.compactMap { footprint($0) }
                guard strips.count == current.count, let parent = parent(options), menus(options)?.isEmpty == true,
                      case .success(let children) = AXHelpers.childrenResult(options, runtime: runtime.ax),
                      actionContextCurrent() else { return trackReceipt(.rejectedBeforeWrite) }
                ownedMenu = nil
                _ = AXHelpers.performAction(options, kAXPressAction, runtime: runtime.ax)
                guard retainOpenedMenu(options, parent: parent, beforeNodes: outside + strips.flatMap({ $0 }), beforeControlChildren: children),
                      let choice = leaf(options, creator: true, appendingTrack: true),
                      let frame = creatorFrame(choice), let app = AXLogicProElements.appRoot(runtime: runtime),
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute, runtime: runtime.ax),
                      let click = mouse.prepareMouseClick(CGPoint(x: frame.midX, y: frame.midY), 1), let hit = runtime.ax.elementAtPosition,
                      case .success(let firstHit?) = hit(app, CGPoint(x: frame.midX, y: frame.midY)), CFEqual(firstHit, choice),
                      permitted(), preserved(), matches(proof.footprint, footprint(strip)),
                      case .read(let decidingHeaders) = AXLogicProElements.allTrackHeadersVerifiedRead(in: bindings[0].window, runtime: runtime),
                      same(headers, decidingHeaders), headerSelection(headers, selectedLast: true),
                      let finalChoice = leaf(options, creator: true, appendingTrack: true), CFEqual(finalChoice, choice),
                      creatorFrame(choice) == frame,
                      case .success(let finalHit?) = hit(app, CGPoint(x: frame.midX, y: frame.midY)), CFEqual(finalHit, choice),
                      let currentFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute, runtime: runtime.ax), CFEqual(focus, currentFocus),
                      let decidingMenu = ownedMenuExclusion(), decidingMenu.count == 1,
                      permitted(), preserved(), matches(proof.footprint, footprint(strip)),
                      let finalCensus = census(), same(current, finalCensus),
                      headerSelection(headers, selectedLast: true), selectedOnly(strip), actionContextCurrent() else {
                    _ = closeOwnedMenu(); return trackReceipt(.rejectedBeforeWrite, "track_append_dispatch_refused")
                }
                trackBaseline = .init(headers: headers, radios: radios, outside: outside, strips: strips, rail: rail)
                trackAppendIssued = true
                uiEffects.navigationPerformed = true; uiEffects.restoration = "not_restored"
                uiEffects.attempted.append("arrange_track_append")
                guard mouse.postMouseEvent(.mouseMoved, CGPoint(x: frame.midX, y: frame.midY), 0) else {
                    return trackReceipt(.pending, "track_append_pointer_unverified")
                }
                guard click.postDown() else { return trackReceipt(.pending, "track_append_down_unverified") }
                let released = click.postUp()
                guard released else { return trackReceipt(.pending, "track_append_release_unverified") }
            }
            guard let baseline = trackBaseline else { return trackReceipt(.pending) }
            for _ in 0..<samples {
                do { try await waitForNextSample() } catch { return trackReceipt(.pending) }
                guard permitted(), case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: bindings[0].window, runtime: runtime),
                      headers.count >= baseline.headers.count,
                      same(Array(headers.prefix(baseline.headers.count)), baseline.headers) else { return trackReceipt(.configurationPartial, "original_headers_changed") }
                let added = headers.filter { candidate in !baseline.headers.contains { CFEqual($0, candidate) } }
                if added.isEmpty { continue }
                guard added.count == 1, headers.count == baseline.headers.count + 1 else {
                    return trackReceipt(.configurationPartial, "track_append_ambiguous")
                }
                if let observedTrack {
                    guard CFEqual(observedTrack.header, added[0]) else { return trackReceipt(.configurationPartial, "observed_track_replaced") }
                } else {
                    // Keep the observed native object before later preservation
                    // or configuration can fail; this grants no delete proof.
                    observedTrack = .init(window: bindings[0].window, header: added[0], document: bindings[0].document, runtime: runtime)
                }
                guard headerSelection(baseline.headers, selectedLast: false),
                      AXValueExtractors.extractSelectedState(added[0], runtime: runtime.ax) == true else {
                    return trackReceipt(.configurationPartial, "track_append_selection_unverified")
                }
                guard appendOutsidePreserved(baseline, track: added[0]) else {
                    return trackReceipt(.configurationPartial, "track_append_outside_preservation_unverified")
                }
                guard let current = census(), current.count == baseline.strips.count else {
                    return trackReceipt(.configurationPartial, "track_append_population_unverified")
                }
                let trees = current.compactMap { footprint($0) }
                guard trees.count == baseline.strips.count,
                      zip(baseline.strips, trees).allSatisfy({ sameValues($0, $1) }),
                      case .read(let bookend) = AXLogicProElements.allTrackHeadersVerifiedRead(in: bindings[0].window, runtime: runtime),
                      same(headers, bookend), headerSelection(baseline.headers, selectedLast: false),
                      AXValueExtractors.extractSelectedState(added[0], runtime: runtime.ax) == true,
                      appendOutsidePreserved(baseline, track: added[0]), actionContextCurrent() else {
                    return trackReceipt(.configurationPartial, "track_append_preservation_unverified")
                }
                if !uiEffects.changed.contains("arrange_track_append") { uiEffects.changed.append("arrange_track_append") }
                uiEffects.reason = "owned_arrange_track_focus_unverified"
                return trackReceipt(.appended)
            }
            return trackReceipt(.pending, "track_append_unobserved")
        }

        /// Prepare only this creation's held Track for the existing selected
        /// association reader. Track creation can retire every Mixer object;
        /// this stage therefore grants no Aux binding or assignment authority.
        /// The single Tab is never retried, including an unacknowledged effect.
        func prepareCreatedTrackReadFocus(for proof: OwnedInverse) async -> TrackReceipt {
            guard proof.owner == owner, !deleteIssued, trackAppendIssued,
                  let created = held?.created, CFEqual(proof.strip, created),
                  let baseline = trackBaseline, let track = observedTrack,
                  await appendArrangeTrack(for: proof).status == .appended, track.currentIndex() != nil else {
                return trackReceipt(.rejectedBeforeWrite, "created_track_proof_required")
            }
            func currentFocus() -> (element: AXUIElement, onRail: Bool)? {
                guard !AXLogicProElements.dialogPresent(runtime: runtime),
                      let app = AXLogicProElements.appRoot(runtime: runtime),
                      let main: AXUIElement = AXHelpers.getAttribute(app, kAXMainWindowAttribute, runtime: runtime.ax),
                      let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute, runtime: runtime.ax),
                      CFEqual(main, bindings[0].window), CFEqual(focusedWindow, main),
                      let rail = AXLogicProElements.uniqueTrackHeaderRail(in: main, runtime: runtime), CFEqual(rail, baseline.rail),
                      let path = AccessibilityChannel.HeldSelectionAssociation.path(rail, to: main, ax: runtime.ax),
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute, runtime: runtime.ax),
                      case .notTextEditing = AccessibilityChannel.readLogicKeyboardFocus(of: focus, runtime: runtime) else { return nil }
                return (focus, path.dropLast().contains { CFEqual($0, focus) })
            }
            if createdReadFocusBefore == nil {
                guard permitted(), let current = census(),
                      let index = baseline.strips.firstIndex(where: { $0.first.map { CFEqual($0.element, created) } == true }),
                      current.indices.contains(index), selectedOnly(current[index]),
                      let focus = currentFocus(), focus.onRail || mixerIsFocused(),
                      let bookend = census(), same(current, bookend),
                      let decidingFocus = currentFocus(), CFEqual(focus.element, decidingFocus.element),
                      selectedOnly(current[index]),
                      actionContextCurrent() else {
                    return trackReceipt(.rejectedBeforeWrite, "created_track_read_focus_before_changed")
                }
                // The ordinal is a refusal-only UI bookend, not an Aux identity
                // join. Only the existing fresh association may issue that pair.
                createdReadFocusBefore = (current, current[index])
                if !focus.onRail {
                    uiEffects.navigationPerformed = true; uiEffects.restoration = "not_restored"
                    uiEffects.attempted.append("created_track_read_focus")
                    _ = mouse.postKeyEvent(CGKeyCode(kVK_Tab))
                }
            }
            guard let before = createdReadFocusBefore else { return trackReceipt(.pending) }
            for _ in 0..<samples {
                do { try await waitForNextSample() } catch { return trackReceipt(.pending) }
                guard await appendArrangeTrack(for: proof).status == .appended,
                      let current = census(), same(before.population, current), selectedOnly(before.selected),
                      let focus = currentFocus(), actionContextCurrent() else {
                    return trackReceipt(.configurationPartial, "created_track_read_focus_preservation_unverified")
                }
                guard focus.onRail else { continue }
                if uiEffects.attempted.contains("created_track_read_focus"),
                   !uiEffects.changed.contains("created_track_read_focus") {
                    uiEffects.changed.append("created_track_read_focus")
                }
                uiEffects.reason = nil
                return trackReceipt(.readFocusPrepared)
            }
            return trackReceipt(.pending, "created_track_read_focus_unobserved")
        }

        /// One explicit input initialization on this Context's actual creation.
        /// The canonical caller still supplies consent/allocation; this is not a
        /// public command or a general physical-input replacement permission.
        func initializeInputBus(for proof: OwnedInverse, destination: Int) async -> InputReceipt {
            let runtime = self.runtime
            func rejected(_ reason: String) -> InputReceipt {
                .init(status: .rejectedBeforeWrite, effect: nil, result: nil, diagnostic: reason, uiEffects: uiEffects)
            }
            guard proof.owner == owner, !deleteIssued, (1...256).contains(destination),
                  let created = held?.created, CFEqual(created, proof.strip), let track = observedTrack else {
                return rejected("owned_created_track_required")
            }
            // Reserve before acquisition can suspend. Actor isolation alone does
            // not keep another caller from entering while these reads await.
            guard !inputInitializationInProgress else { return rejected("initialization_in_progress") }
            inputInitializationInProgress = true
            defer { inputInitializationInProgress = false }
            if let issued = inputInitializationDestination {
                guard issued == destination else { return rejected("initialization_destination_conflict") }
                guard let cached = inputInitializationReceipt, cached.status == .initialized,
                      let effect = cached.effect, effect.permits(), let after = inputInitializationAfter,
                      matches(after.outside, footprint(bindings[0].window, excluding: [bindings[0].mixer, options, edit])),
                      let current = census(), current.count == after.strips.count,
                      zip(after.strips, current).allSatisfy({ matches($0, footprint($1)) }), actionContextCurrent() else {
                    return .init(status: .configurationPartial, effect: inputInitializationReceipt?.effect,
                        result: inputInitializationReceipt?.result, diagnostic: "initialization_not_reissued", uiEffects: uiEffects)
                }
                return cached
            }
            guard await prepareCreatedTrackReadFocus(for: proof).status == .readFocusPrepared else {
                return rejected("created_track_read_focus_required")
            }
            let stop: @Sendable () -> Bool = { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil }
            let guardian = AXHelpers.HelpReadGuard(allowHelpReads: true, stop: stop)
            let population: SessionPopulationObservation.FreshPopulation
            do {
                population = try await AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                    try await AccessibilityChannel(runtime: .axBacked(logicRuntime: runtime, observationMouseRuntime: mouse))
                        .readFreshSessionPopulation(request: .init(scope: .selection,
                            domains: [.tracks, .strips, .associations], allowUINavigation: true),
                            fileReader: .production,
                            readFocusScope: AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope(),
                            stoppingBeforeAXRead: { stop() || guardian.stopped }, stoppingWhen: { stop() || guardian.stopped })
                }
            } catch { return rejected("created_association_unavailable") }
            guard population.selectionAssociations.count == 1, let pair = population.selectionAssociations.first,
                  pair.track.matches(track) else { return rejected("created_track_association_changed") }
            let checked = await AXMixerStripBinding.$current.withValue(pair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                    await AccessibilityChannel.getCheckedInputObservation(runtime: runtime)
                }
            }
            let currentPair = checked.inputRenewal?.pair ?? pair
            guard currentPair.track.matches(track), let beforeInput = checked.inputAssignment,
                  case .physical = beforeInput, let slot = checked.inputSlot, slot.owner.matches(currentPair.strip),
                  checked.inputRenewal.map({ $0.permits(runtime: runtime) }) ?? true,
                  await appendArrangeTrack(for: proof).status == .appended,
                  let current = census(), let index = current.firstIndex(where: { CFEqual($0, currentPair.strip.strip) }),
                  let outside = footprint(bindings[0].window, excluding: [bindings[0].mixer, options, edit]) else {
                return rejected("created_checked_physical_input_required")
            }
            let trees = current.compactMap { footprint($0) }
            guard trees.count == current.count,
                  let inputIndex = trees[index].firstIndex(where: { CFEqual($0.element, slot.control) }),
                  actionContextCurrent() else { return rejected("created_input_preservation_unavailable") }
            let window = bindings[0].window, mixer = bindings[0].mixer
            let controlBar = AXLogicProElements.getControlBar(in: window, runtime: runtime.ax)
            let excluded = [mixer, options, edit]
            let authorization = InputInitializationProof(owner: owner, pair: currentPair, before: beforeInput,
                destination: destination, checked: checked, permitting: { popup in
                    guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                          let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: runtime.ax)?.strips,
                          census.count == current.count, zip(census, current).allSatisfy({ CFEqual($0, $1) }),
                          let latestOutside = Self.footprint(window, excluding: excluded, runtime: runtime),
                          latestOutside.count == outside.count, zip(outside, latestOutside).allSatisfy({ $0.matches($1) }) else { return false }
                    for (expected, strip) in zip(trees, current) {
                        guard let actual = Self.footprint(strip, ignoringTransientMenus: popup.map { [$0] } ?? [], runtime: runtime),
                              expected.count == actual.count, zip(expected, actual).allSatisfy({ $0.matches($1) }) else { return false }
                    }
                    return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                })
            guard authorization.permitsBefore(currentPair.strip) else { return rejected("created_input_changed") }
            // Record the one configuration attempt before awaiting its writer.
            // An uncertain outcome can be observed later, never re-dispatched.
            inputInitializationDestination = destination
            let capture = InputCapture(), upstream = AccessibilityChannel.inputChangeObserver
            let result = await AXMixerStripBinding.$current.withValue(currentPair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(currentPair) {
                    await AccessibilityChannel.$inputChangeObserver.withValue({ effect in capture.record(effect); upstream?(effect) }) {
                        await AccessibilityChannel.setInputBusVerified(params: ["destination": "bus:\(destination)", "replace_existing": "true"],
                            runtime: runtime, ownedCreation: authorization)
                    }
                }
            }
            let effect = capture.read()
            var completed = false
            if let effect, effect.creation?.owner == owner, effect.before == beforeInput, effect.after == destination,
               effect.current.track.matches(track), effect.permits(),
               let after = census(), after.count == current.count,
               after.indices.contains(index), CFEqual(after[index], effect.current.strip.strip),
               let afterOutside = footprint(window, excluding: excluded),
               OwnedAuxLifecycle.preservesInputInitializationOutside(outside, afterOutside, controlBar: controlBar) {
                if !matches(outside, afterOutside) {
                    uiEffects.restoration = "not_restored"
                    if !uiEffects.changed.contains("control_bar_checkbox_availability") {
                        uiEffects.changed.append("control_bar_checkbox_availability")
                    }
                }
                let afterTrees = after.compactMap { footprint($0) }
                completed = afterTrees.count == trees.count && trees.indices.allSatisfy { offset in
                    if offset != index { return sameValues(trees[offset], afterTrees[offset]) }
                    let old = trees[offset], new = afterTrees[offset]
                    guard old.count == new.count, new.indices.contains(inputIndex),
                          CFEqual(new[inputIndex].element, effect.control.control) else { return false }
                    return old.indices.allSatisfy { node in
                        var a = old[node].fields, b = new[node].fields
                        if node == inputIndex { a.removeValue(forKey: kAXDescriptionAttribute); b.removeValue(forKey: kAXDescriptionAttribute) }
                        return a == b && old[node].children.count == new[node].children.count
                    }
                }
                if completed, let finalOutside = footprint(window, excluding: excluded),
                   OwnedAuxLifecycle.preservesInputInitializationOutside(outside, finalOutside, controlBar: controlBar),
                   effect.permits(), actionContextCurrent() {
                    inputInitializationAfter = (finalOutside, afterTrees)
                } else { completed = false }
            }
            let receipt = InputReceipt(status: completed ? .initialized : .configurationPartial,
                effect: effect, result: result, diagnostic: completed ? nil : "created_input_effect_or_preservation_unverified", uiEffects: uiEffects)
            inputInitializationReceipt = receipt
            return receipt
        }

        func create() async -> Receipt {
            if trackAppendIssued { return receipt(.configurationPartial, strip: observedCreated, diagnostic: "owned_arrange_track_configuration_pending") }
            if let held, let proof = held.inverse {
                if deleteIssued { return await remove(proof) }
                guard let current = census(), current.contains(where: { CFEqual($0, proof.strip) }),
                      preserved(), matches(proof.footprint, footprint(proof.strip)) else { return receipt(.residual, strip: proof.strip) }
                return held
            }
            guard permitted() else { return receipt(issued ? .pending : .rejectedBeforeWrite, strip: observedCreated) }
            if !issued {
                guard let current = census(), same(current, bindings.map(\.strip)),
                      let outside = footprint(bindings[0].window, excluding: [bindings[0].mixer, options, edit]) else { return receipt(.rejectedBeforeWrite) }
                let original = bindings.compactMap { footprint($0.strip) }
                guard original.count == bindings.count,
                      AXHelpers.getRole(options, runtime: runtime.ax) == kAXMenuButtonRole as String,
                      let parent = parent(options), let previousMenus = menus(options), previousMenus.isEmpty,
                      case .success(let previousChildren) = AXHelpers.childrenResult(options, runtime: runtime.ax),
                      let previousOwnedMenu = ownedMenuExclusion(), previousOwnedMenu.isEmpty,
                      permitted(), actionContextCurrent() else { return receipt(.rejectedBeforeWrite) }
                ownedMenu = nil
                let opened = AXHelpers.performAction(options, kAXPressAction, runtime: runtime.ax)
                guard retainOpenedMenu(options, parent: parent, beforeNodes: outside + original.flatMap({ $0 }),
                                       beforeControlChildren: previousChildren) else { return menuRefusal(.rejectedBeforeWrite) }
                guard opened,
                      let creator = leaf(options, creator: true),
                      permitted(), let finalBefore = census(), same(finalBefore, current) else { return menuRefusal(.rejectedBeforeWrite) }
                before = original; outsideMixer = outside
                guard preserved(), permitted(),
                      let decidingMenu = ownedMenuExclusion(), decidingMenu.count == 1,
                      actionContextCurrent() else { return menuRefusal(.rejectedBeforeWrite) }
                // Both advertised Press and Pick acknowledged without observed
                // creation on the native fixture. Its independently successful
                // mouse selection is a separate, sole dispatch, never a fallback.
                // Reuse the shared prepared pair and exact native-CF hit test.
                guard let currentCreator = leaf(options, creator: true), CFEqual(currentCreator, creator),
                      let app = AXLogicProElements.appRoot(runtime: runtime),
                      case .success(let focus?) = AXHelpers.getAttributeResult(app, kAXFocusedUIElementAttribute,
                        runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError>,
                      let frame = creatorFrame(currentCreator),
                      let pair = mouse.prepareMouseClick(CGPoint(x: frame.midX, y: frame.midY), 1),
                      let hitTest = runtime.ax.elementAtPosition,
                      case .success(.some(let hit)) = hitTest(app, CGPoint(x: frame.midX, y: frame.midY)),
                      CFEqual(hit, currentCreator), permitted(), preserved(),
                      let finalCreator = leaf(options, creator: true), CFEqual(finalCreator, currentCreator),
                      creatorFrame(currentCreator) == frame,
                      case .success(.some(let finalHit)) = hitTest(app, CGPoint(x: frame.midX, y: frame.midY)),
                      CFEqual(finalHit, currentCreator),
                      let decidingCreator = leaf(options, creator: true), CFEqual(decidingCreator, currentCreator),
                      let finalMenu = ownedMenuExclusion(), same(finalMenu, decidingMenu), finalMenu.count == 1,
                      case .success(let currentFocus?) = AXHelpers.getAttributeResult(app, kAXFocusedUIElementAttribute,
                        runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError>, CFEqual(currentFocus, focus),
                      case .success(let main?) = AXHelpers.getAttributeResult(app, kAXMainWindowAttribute,
                        runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError>, CFEqual(main, bindings[0].window),
                      case .success(let focusedWindow?) = AXHelpers.getAttributeResult(app, kAXFocusedWindowAttribute,
                        runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError>, CFEqual(focusedWindow, bindings[0].window),
                      permitted(),
                      actionContextCurrent() else { return menuRefusal(.rejectedBeforeWrite) }
                // Mark BEFORE sending the creator. A failed AX return can still create
                // later: zero delta never permits reissue (observed delayed host behavior).
                issued = true
                // TEMP: held facts only; no new AX reads or input.
                Log.info("Owned Aux prepared click: phase=before,leaf_cf_hash=\(CFHash(currentCreator)),menu_cf_hash=\(CFHash(finalMenu[0])),point_x=\(frame.midX),point_y=\(frame.midY),original_count=\(bindings.count),last_census_count=\(finalBefore.count)", subsystem: "ax")
                // Native menu tracking needs the observed pointer move before
                // this one prepared click. No read or await separates its input.
                guard mouse.postMouseEvent(.mouseMoved, CGPoint(x: frame.midX, y: frame.midY), 0) else {
                    return receipt(.pending, diagnostic: "creator_pointer_move_unverified")
                }
                let downPosted = pair.postDown()
                guard downPosted else {
                    Log.info("Owned Aux prepared click: phase=after,down_returned=false,up_attempted=false", subsystem: "ax")
                    return receipt(.pending, diagnostic: "creator_click_down_unverified")
                }
                // Complete only this prepared click. No AX read, permission
                // callback or await may strand Down in the host's tracking loop.
                let upPosted = pair.postUp()
                // Logging occurs AFTER both calls, never between their halves.
                Log.info("Owned Aux prepared click: phase=after,down_returned=\(downPosted),up_attempted=true,up_returned=\(upPosted)", subsystem: "ax")
                guard upPosted else { return receipt(.pending, diagnostic: "creator_click_release_unverified") }
            }
            for _ in 0..<samples {
                do { try await waitForNextSample() } catch { return receipt(.pending, strip: observedCreated) }
                guard var current = census() else { return receipt(.pending, strip: observedCreated, diagnostic: "source_unavailable") }
                if !originalsInOrder(current), await refreshLatentCreation(current) {
                    guard let refreshed = census() else { return receipt(.pending, diagnostic: "created_population_refresh_unverified") }
                    current = refreshed
                }
                if !originalsInOrder(current), !retainCreationAfterWholeRedraw(current) {
                    return receipt(.pending, strip: observedCreated, diagnostic: "population_changed_after_creation")
                }
                let new = current.filter { element in !preservationPeers.contains(where: { CFEqual($0, element) }) }
                guard current.count == bindings.count + new.count,
                      originalsInOrder(current) else { return receipt(.pending, strip: observedCreated) }
                if let observedCreated {
                    guard new.count == 1, CFEqual(new[0], observedCreated) else {
                        return receipt(.residual, strip: observedCreated, diagnostic: "created_identity_changed")
                    }
                } else if new.count == 1 {
                    // Retain the first observed CF even if its configuration is
                    // partial. A later replacement never acquires inverse authority.
                    observedCreated = new[0]
                }
                guard preserved() else { return receipt(.pending, strip: observedCreated, diagnostic: "preservation_changed") }
                if createdSelectionPending, !acquireCreatedSelection(current) {
                    return receipt(.pending, strip: observedCreated, diagnostic: "created_selection_unverified")
                }
                if new.count == 1 {
                    let strip = new[0]
                    guard let actual = defaults(strip), let initial = footprint(strip),
                          let bookend = census(), same(current, bookend), preserved(),
                          matches(initial, footprint(strip)) else { return receipt(.configurationPartial, strip: strip) }
                    let proof = OwnedInverse(owner: owner, strip: strip, footprint: initial)
                    let result = receipt(.created, strip: strip, defaults: actual, inverse: proof)
                    held = result
                    return result
                }
                if new.count > 1 { return receipt(.pending) }
            }
            return receipt(.pending, strip: observedCreated)
        }

        func remove(_ proof: OwnedInverse) async -> Receipt {
            if trackAppendIssued { return receipt(.residual, strip: observedCreated, diagnostic: "owned_arrange_track_inverse_unavailable") }
            guard proof.owner == owner, let held, let strip = held.created,
                  CFEqual(proof.strip, strip) else { return receipt(.residual) }
            if !deleteIssued {
                guard permitted(), let current = census(), current.count == bindings.count + 1,
                      current.contains(where: { CFEqual($0, strip) }), originalsInOrder(current), preserved(),
                      matches(proof.footprint, footprint(strip)), defaults(strip) == acceptedDefaults,
                      focusedOn(strip), AXHelpers.getRole(edit, runtime: runtime.ax) == kAXMenuButtonRole as String,
                      let parent = parent(edit), let previousMenus = menus(edit), previousMenus.isEmpty,
                      case .success(let previousChildren) = AXHelpers.childrenResult(edit, runtime: runtime.ax),
                      let outsideMixer, let before,
                      let previousOwnedMenu = ownedMenuExclusion(), previousOwnedMenu.isEmpty,
                      permitted(), actionContextCurrent(), selectedOnly(strip), actionContextCurrent(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return receipt(.residual, strip: strip) }
                ownedMenu = nil
                let opened = AXHelpers.performAction(edit, kAXPressAction, runtime: runtime.ax)
                guard retainOpenedMenu(edit, parent: parent,
                                       beforeNodes: outsideMixer + before.flatMap({ $0 }) + proof.footprint,
                                       beforeControlChildren: previousChildren) else { return menuRefusal(.residual, strip: strip) }
                guard opened,
                      let delete = leaf(edit, creator: false), permitted(),
                      let final = census(), same(current, final), preserved(),
                      matches(proof.footprint, footprint(strip)), focusedOn(strip, allowing: edit),
                      permitted(), let decidingMenu = ownedMenuExclusion(), decidingMenu.count == 1,
                      actionContextCurrent(), selectedOnly(strip), actionContextCurrent(),
                      (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return menuRefusal(.residual, strip: strip) }
                deleteIssued = true
                _ = AXHelpers.performAction(delete, kAXPressAction, runtime: runtime.ax)
            }
            for _ in 0..<samples {
                do { try await waitForNextSample() } catch { return receipt(.residual, strip: strip) }
                guard let current = census() else { return receipt(.residual, strip: strip) }
                if removedAfterWholePeerRedraw(current, strip: strip) { return receipt(.removed, strip: strip) }
                if !preserved() {
                    // A whole peer redraw can retire the original observations
                    // before the deleted object's invalidation settles. Spend
                    // only the remaining read-only samples; the full terminal
                    // preservation/invalidation proof above is unchanged.
                    guard current.count == preservationPeers.count,
                          !current.contains(where: { CFEqual($0, strip) }),
                          preservationPeers.allSatisfy({ peer in !current.contains { CFEqual($0, peer) } })
                    else { return receipt(.residual, strip: strip) }
                    continue
                }
                if same(current, preservationPeers),
                   let bookend = census(), same(current, bookend), preserved() {
                    // A transient full AX census can equal the original baseline.
                    // That is not removal while the exact owned native object still
                    // reads live. Unknown failures are not deletion certificates.
                    guard invalidated(strip) else { continue }
                    // This says only that the owned object was removed. Focus/selection
                    // restoration and the existing Saga journal are not qualified here.
                    return receipt(.removed, strip: strip)
                }
            }
            return receipt(.residual, strip: strip)
        }
    }

    static func prepare(
        population: SessionPopulationObservation.FreshPopulation,
        options: AXUIElement, edit: AXUIElement, acceptedDefaults: [Field: Value],
        runtime: AXLogicProElements.Runtime, mouse: AXMouseHelper.Runtime = .production,
        initialControls: (@Sendable (AXUIElement) -> [Field: AXUIElement]?)? = nil,
        settleSamples: Int = 30,
        waitForNextSample: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) -> Context? {
        guard population.stable, population.hiddenTracksShown == true,
              population.uiEffects.restoration == "restored",
              population.mixerPresentation?.mode == "all",
              let filters = population.mixerPresentation?.typeFilters,
              ["audio", "instrument", "aux", "bus", "input", "output", "master_vca", "midi"].allSatisfy({ filters[$0] == .some(true) }),
              let bindings = population.ownedMixerSelectedPopulation, !bindings.isEmpty,
              bindings.allSatisfy({ CFEqual($0.window, bindings[0].window) && CFEqual($0.mixer, bindings[0].mixer)
                  && $0.document.utf8.elementsEqual(bindings[0].document.utf8)
                  && $0.projectPath?.utf8.elementsEqual(population.project?.filePath?.utf8 ?? "".utf8) == true }),
              acceptedDefaults.count == Field.allCases.count, settleSamples > 0, settleSamples <= 120 else { return nil }
        return Context(bindings: bindings, options: options, edit: edit, acceptedDefaults: acceptedDefaults,
            runtime: runtime, mouse: mouse,
            topologyNavigation: population.presentationBinding.flatMap { binding in
                guard CFEqual(binding.window, bindings[0].window), let mixer = binding.mixer,
                      CFEqual(mixer, bindings[0].mixer), binding.document.utf8.elementsEqual(bindings[0].document.utf8) else { return nil }
                return binding.navigationBaseline
            }, initialControls: initialControls, samples: settleSamples, waitForNextSample: waitForNextSample)
    }
}
