import ApplicationServices
import Foundation
import MCP

/// #968: exact-local Arrange naming, including one producer-observed coupled
/// pair, with earlier canonical effects carried only by this adapter's owned receipts.
enum ExactTrackNameAdapter {
    @TaskLocal private static var coupledWriteBoundary: (@Sendable (Bool, AXUIElement?) -> Bool)?
    @TaskLocal private static var coupledFootprintFocusBookends = false
    @TaskLocal private static var coupledMenuRail: MenuRailCustody?
    @TaskLocal private static var coupledMenuEditor: MenuEditorIdentity?
    @TaskLocal private static var coupledNameFocusTransport: NameFocusTransportCapture?

    /// Configured native transport only, never source or inverse authority.
    struct NameFocusTransport: Sendable {
        let mouse: AXMouseHelper.Runtime
        let canPostEvents: @Sendable () -> Bool
    }

    /// Data sampled after this writer's verified effect, not target or write authority.
    struct VerifiedNameEffect: Sendable {
        fileprivate let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let trackName: String
        let stripName: String

        fileprivate init(pair: AccessibilityChannel.HeldSelectionAssociation.Pair, trackName: String, stripName: String) {
            self.pair = pair; self.trackName = trackName; self.stripName = stripName
        }

        func matches(_ other: AccessibilityChannel.HeldSelectionAssociation.Pair) -> Bool {
            pair.track.matches(other.track) && pair.strip.matches(other.strip)
        }
    }
    typealias PostVerifiedWrite = @Sendable (NameFocusTransport?, VerifiedNameEffect?) async -> Bool
    private final class NameFocusTransportCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var transport: NameFocusTransport?
        func record(_ value: NameFocusTransport) { lock.withLock { if transport == nil { transport = value } } }
        var value: NameFocusTransport? { lock.withLock { transport } }
    }
    static func recordCoupledNameFocusTransport(mouse: AXMouseHelper.Runtime,
                                                canPostEvents: @escaping @Sendable () -> Bool) {
        coupledNameFocusTransport?.record(.init(mouse: mouse, canPostEvents: canPostEvents))
    }

    static func coupledWritePermitted(allowOwnPreview: Bool = false, ownedEditor: AXUIElement? = nil) -> Bool {
        coupledWriteBoundary?(allowOwnPreview, ownedEditor) ?? true
    }

    /// Only the existing writer's successfully opened Rename menu supplies this
    /// exact editor. This scope cannot discover or adopt another focused field.
    static func coupledMenuWritePermitted(allowOwnPreview: Bool = false, ownedEditor: AXUIElement) -> Bool {
        $coupledMenuEditor.withValue(MenuEditorIdentity(editor: ownedEditor)) {
            coupledWritePermitted(allowOwnPreview: allowOwnPreview, ownedEditor: ownedEditor)
        }
    }

    // A retained CF identity only, like the existing native bindings. Every
    // consuming read independently rechecks the same request's focus/custody.
    private struct MenuEditorIdentity: @unchecked Sendable { let editor: AXUIElement }

    /// Immutable native handles held before the Rename menu is actuated. Logic's
    /// menu editor reports this rail as Parent without joining its exported children.
    private struct MenuRailCustody: @unchecked Sendable {
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let rail: AXUIElement
        let headers: [AXUIElement]

        init?(_ mirror: CoupledMirror) {
            let pair = mirror.pair
            let runtime = pair.track.runtime
            let sources = [pair.track] + mirror.preservedTracks.compactMap(\.physicalBinding)
            guard operationPermitted(), pair.track.currentIndex() != nil,
                  let rail: AXUIElement = AXHelpers.getAttribute(pair.track.header, kAXParentAttribute as String, runtime: runtime.ax),
                  let heldRail = AXLogicProElements.uniqueTrackHeaderRail(in: pair.track.window, runtime: runtime),
                  CFEqual(heldRail, rail),
                  case .success(let headers) = AXHelpers.childrenResult(rail, runtime: runtime.ax),
                  headers.count == sources.count, sources.count == mirror.preservedTracks.count + 1,
                  headers.allSatisfy({ header in sources.filter { CFEqual($0.header, header) }.count == 1 }),
                  headers.allSatisfy({ AXValueExtractors.extractSelectedState($0, runtime: runtime.ax)
                    == CFEqual($0, pair.track.header) }), operationPermitted() else { return nil }
            self.pair = pair; self.rail = rail; self.headers = headers
        }

        func permits(parent: AXUIElement, children: [AXUIElement], pair: AccessibilityChannel.HeldSelectionAssociation.Pair) -> Bool {
            guard self.pair.track.matches(pair.track), self.pair.strip.matches(pair.strip), CFEqual(parent, rail),
                  children.count == headers.count, zip(children, headers).allSatisfy({ CFEqual($0, $1) }),
                  let currentParent: AXUIElement = AXHelpers.getAttribute(pair.track.header, kAXParentAttribute as String,
                    runtime: pair.track.runtime.ax), CFEqual(currentParent, rail),
                  children.filter({ CFEqual($0, pair.track.header) }).count == 1,
                  children.allSatisfy({ AXValueExtractors.extractSelectedState($0, runtime: pair.track.runtime.ax)
                    == CFEqual($0, pair.track.header) }), operationPermitted() else { return false }
            return true
        }
    }

    /// Ordinary callers keep their existing behavior. The composed footprint
    /// captures its already-qualified focus before heavy reads, not a new owner.
    static func captureCoupledWriteFocus(runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        guard coupledFootprintFocusBookends, let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        return AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax)
    }

    static func coupledWriteFocusMatches(_ expected: AXUIElement?, runtime: AXLogicProElements.Runtime) -> Bool {
        guard let expected else { return !coupledFootprintFocusBookends }
        guard operationPermitted(), let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
              CFEqual(focus, expected), operationPermitted() else { return false }
        return true
    }
    struct Action: Sendable {
        let projectReference: TargetReference
        let targetReference: TargetReference
        let expectedBefore: String
        let desiredAfter: String
    }

    enum Status: String, Sendable {
        case applied
        case alreadySatisfied = "already_satisfied"
        case rejectedBeforeWrite = "rejected_before_write"
        case attemptedUnverified = "attempted_unverified"
    }

    /// Only this adapter can construct an inverse; a caller's JSON/status cannot grant ownership.
    /// Retains the actual registry/cache, rather than importing authority into a different session.
    struct OwnedInverse: Sendable {
        fileprivate let project: TargetReference
        fileprivate let target: TargetReference
        fileprivate let before: String
        fileprivate let written: String
        fileprivate let registry: TargetRegistry
        fileprivate let cache: StateCache
        fileprivate var mirror: CoupledMirror?
        fileprivate var selectionOrigin: AXTrackBinding.Binding? = nil
        fileprivate var stripBefore: String? = nil
        fileprivate var restoresMixerFocus = false
    }

    /// A read-only continuation of the original capture, never an owned write
    /// or inverse. Only an actual original-header acquisition can advance it.
    struct CapturedCoupledRead: Sendable {
        fileprivate let action: Action
        fileprivate let registry: TargetRegistry
        fileprivate let mirror: CoupledMirror
    }

    private static func capturedNameMirror(_ action: Action, capture: SessionPopulationObservation.Capture,
        source: AXTrackBinding.Binding, registry: TargetRegistry, read: CapturedCoupledRead?) -> CoupledMirror? {
        guard let original = capturedMirror(action, capture: capture, source: source) else { return nil }
        guard let read else { return original }
        guard read.registry === registry, read.action.projectReference == action.projectReference,
              read.action.targetReference == action.targetReference,
              read.action.expectedBefore.utf8.elementsEqual(action.expectedBefore.utf8),
              read.action.desiredAfter.utf8.elementsEqual(action.desiredAfter.utf8),
              read.mirror.snapshot == original.snapshot, read.mirror.reference == original.reference,
              read.mirror.pair.track.matches(original.pair.track),
              (read.mirror.registryStrip ?? read.mirror.pair.strip).matches(original.pair.strip) else { return nil }
        return read.mirror
    }

    static func renewingCapturedCoupledRead(_ action: Action, capture: SessionPopulationObservation.Capture,
        registry: TargetRegistry, prior: CapturedCoupledRead?,
        through source: AccessibilityChannel.OriginalHeaderSourceRenewal) async -> CapturedCoupledRead? {
        guard let track = await registry.resolve(action.targetReference)?.physicalTrack,
              let mirror = capturedNameMirror(action, capture: capture, source: track, registry: registry, read: prior),
              mirror.pair.track.matches(source.originalTrack), mirror.pair.strip.matches(source.original),
              (source.pair.strip.matches(source.original)
                ? source.original.currentIndex(runtime: mirror.pair.track.runtime) == source.index
                : source.original.currentIndex(runtime: mirror.pair.track.runtime) == nil),
              source.permits(runtime: mirror.pair.track.runtime) else { return nil }
        let renewed = CoupledMirror(pair: source.pair, reference: mirror.reference, snapshot: mirror.snapshot,
            preservedTracks: mirror.preservedTracks, preservedStrips: mirror.preservedStrips,
            registryStrip: mirror.registryStrip ?? mirror.pair.strip, renewal: source)
        guard await readHeldCoupledName(renewed, project: action.projectReference, target: action.targetReference,
                  registry: registry, expectedName: action.expectedBefore) != nil,
              source.permits(runtime: mirror.pair.track.runtime) else { return nil }
        return .init(action: action, registry: registry, mirror: renewed)
    }

    static func recordedNameEffect(_ proof: OwnedInverse) -> VerifiedNameEffect? {
        guard let mirror = proof.mirror, let name = mirror.retainedStripName else { return nil }
        return .init(pair: mirror.pair, trackName: proof.written, stripName: name)
    }

    struct Receipt: Sendable {
        let status: Status
        let before: String?
        let after: String?
        let survivingReference: TargetReference?
        let inverse: OwnedInverse?
        let result: CallTool.Result
    }

    static func operationPermitted() -> Bool {
        guard !Task.isCancelled else { return false }
        if let context = OperationTraceContext.current {
            guard !context.cancellationRequested(), context.ownsGate() else { return false }
            if let deadline = context.deadline, ContinuousClock.now >= deadline { return false }
        }
        return true
    }

    static func apply(
        _ action: Action, router: ChannelRouter, cache: StateCache, registry: TargetRegistry,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?
    ) async -> Receipt {
        await applyChecked(action, router: router, cache: cache, registry: registry,
            liveTrackName: liveTrackName, liveTrackNames: liveTrackNames, mirror: nil)
    }

    /// One producer-observed track/strip pair. This is additive local coupling
    /// qualification, not an arbitrary canonical plan's preservation footprint.
    /// A decoded report, equal names or matching ordinals cannot supply the pair.
    static func applyCoupled(
        _ action: Action, capture: SessionPopulationObservation.Capture,
        router: ChannelRouter, cache: StateCache, registry: TargetRegistry,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?,
        capturedRead: CapturedCoupledRead? = nil,
        ownedPeerEffects: [OwnedInverse] = [], selectionOrigin: AXTrackBinding.Binding? = nil,
        preservingFootprint: (@Sendable (Bool, AXUIElement?) -> Bool)? = nil,
        afterVerifiedWrite: PostVerifiedWrite? = nil,
        restoringMixerFocus: Bool = false
    ) async -> Receipt {
        func reject() -> Receipt {
            .init(status: .rejectedBeforeWrite, before: nil, after: nil, survivingReference: nil, inverse: nil,
                result: TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: "track.rename"))
        }
        guard let snapshot = capture.targetSnapshot, await registry.currentSnapshot == snapshot,
              let target = await registry.resolve(action.targetReference), let source = target.physicalTrack,
              target.kind == .track,
              let captured = capturedNameMirror(action, capture: capture, source: source, registry: registry, read: capturedRead),
              let mirror = captured.acknowledging(ownedPeerEffects, project: action.projectReference,
                  target: action.targetReference, registry: registry) else { return reject() }
        return await applySelecting(action, router: router, cache: cache, registry: registry,
            liveTrackName: liveTrackName, liveTrackNames: liveTrackNames, mirror: mirror,
            selectionOrigin: selectionOrigin, preservingFootprint: preservingFootprint, afterVerifiedWrite: afterVerifiedWrite,
            restoringMixerFocus: restoringMixerFocus)
    }

    /// Pure availability over the retained producer capture, not permission to
    /// act. Canonical execution repeats the native/registry proof above.
    static func hasCapturedCoupledFootprint(_ action: Action, capture: SessionPopulationObservation.Capture) -> Bool {
        guard TrackDispatcher.renameNameFailure(action.desiredAfter) == nil,
              let issued = capture.issued,
              case .located(let index) = ProjectSessionAudit.locate(action.targetReference, in: issued) else { return false }
        let rows = capture.tracks.filter { $0.id == index }
        guard rows.count == 1, let source = rows.first?.physicalBinding else { return false }
        return capturedMirror(action, capture: capture, source: source) != nil
    }

    private static func capturedMirror(_ action: Action, capture: SessionPopulationObservation.Capture,
                                      source: AXTrackBinding.Binding) -> CoupledMirror? {
        guard capture.before == capture.after, capture.referencesEnabled, !capture.referencesStale,
              let fresh = capture.freshPopulation, fresh.stable, fresh.uiEffects.restoration == "restored",
              let snapshot = capture.targetSnapshot,
              case .issued(let project)? = capture.projectIssuance, project == action.projectReference else { return nil }
        let pairs = fresh.selectionAssociations.filter { $0.track.matches(source) }
        guard pairs.count == 1, let pair = pairs.first,
              fresh.selectionAssociations.filter({ $0.strip.matches(pair.strip) }).count == 1,
              capture.tracks.filter({ $0.physicalBinding?.matches(source) == true }).count == 1,
              capture.tracks.first(where: { $0.physicalBinding?.matches(source) == true })?.name
                .utf8.elementsEqual(action.expectedBefore.utf8) == true else { return nil }
        let rows = capture.channelStrips.indices.filter { capture.channelStrips[$0].physicalBinding?.matches(pair.strip) == true }
        guard rows.count == 1, let row = rows.first, let stripRef = capture.mixerReference(at: row),
              capture.channelStrips[row].name?.utf8.elementsEqual(action.expectedBefore.utf8) == true else { return nil }
        return CoupledMirror(pair: pair, reference: stripRef, snapshot: snapshot,
            preservedTracks: capture.tracks.filter { $0.physicalBinding?.matches(pair.track) != true },
            preservedStrips: capture.channelStrips.filter { $0.physicalBinding?.matches(pair.strip) != true })
    }

    static func readCapturedCoupledName(_ action: Action, capture: SessionPopulationObservation.Capture,
                                       registry: TargetRegistry, preserveCurrentPeers: Bool = false,
                                       capturedRead: CapturedCoupledRead? = nil,
                                       ownedPeerEffects: [OwnedInverse] = []) async -> String? {
        guard let target = await registry.resolve(action.targetReference), target.kind == .track,
              let source = target.physicalTrack,
              let captured = capturedNameMirror(action, capture: capture, source: source, registry: registry, read: capturedRead),
              var mirror = captured.acknowledging(ownedPeerEffects, project: action.projectReference,
                  target: action.targetReference, registry: registry) else { return nil }
        if preserveCurrentPeers {
            guard let renewed = mirror.withCurrentPeerNames() else { return nil }
            mirror = renewed
        }
        return await readHeldCoupledName(mirror, project: action.projectReference,
            target: action.targetReference, registry: registry)
    }

    /// Read the exact footprint that the actual inverse preserved. An old
    /// capture or a newly sampled baseline cannot certify an inverse's effects.
    static func readOwnedCoupledName(_ proof: OwnedInverse, preserveCurrentPeers: Bool = false,
                                     ownedPeerEffects: [OwnedInverse] = []) async -> String? {
        guard var mirror = proof.mirror else { return nil }
        if preserveCurrentPeers {
            guard let current = mirror.withCurrentPeerNames() else { return nil }
            mirror = current
        } else {
            guard let current = mirror.acknowledging(ownedPeerEffects, project: proof.project,
                target: proof.target, registry: proof.registry) else { return nil }
            mirror = current
        }
        return await readHeldCoupledName(mirror, project: proof.project,
            target: proof.target, registry: proof.registry, expectedName: proof.written)
    }

    /// The writer supplies its already-held editor, never a discovered focus.
    /// This qualifies footprint reads only; it grants no key or setter action.
    static func permitsCoupledEditorRead(_ editor: AXUIElement,
        pair: AccessibilityChannel.HeldSelectionAssociation.Pair, names: [String],
        transportProof: AccessibilityChannel.HeldSelectionAssociation? = nil
    ) -> Bool {
        let runtime = pair.track.runtime
        // This is itself used by the enclosing Help read's stop predicate.
        // Its custody reads must neither read Help in an editor nor recurse
        // into that enclosing predicate through a locator's Help fallback.
        return AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: false, stop: { !operationPermitted() })) {
        guard operationPermitted(), let pid = runtime.logicProPID(), runtime.focusedApplicationPID() == pid,
              let app = AXLogicProElements.appRoot(runtime: runtime),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
              CFEqual(focus, editor), AXHelpers.getRole(editor, runtime: runtime.ax) == kAXTextFieldRole as String,
              AXHelpers.isAttributeSettable(editor, kAXValueAttribute as String, runtime: runtime.ax) == true,
              case .success(.some(let value)) = AXHelpers.getAttributeResult(editor, kAXValueAttribute as String,
                runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError>,
              names.contains(where: { value.utf8.elementsEqual($0.utf8) }),
              let window: AXUIElement = AXHelpers.getAttribute(editor, kAXWindowAttribute as String, runtime: runtime.ax),
              CFEqual(window, pair.track.window),
              let parent: AXUIElement = AXHelpers.getAttribute(editor, kAXParentAttribute as String, runtime: runtime.ax),
              case .success(let siblings) = AXHelpers.childrenResult(parent, runtime: runtime.ax),
              siblings.filter({ CFEqual($0, editor) }).count == 1
                || (siblings.allSatisfy { !CFEqual($0, editor) }
                    && coupledMenuEditor.map { CFEqual($0.editor, editor) } == true
                    && coupledMenuRail?.permits(parent: parent, children: siblings, pair: pair) == true),
              let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
              CFEqual(focusedWindow, pair.track.window), !AXLogicProElements.dialogPresent(runtime: runtime),
              transportProof.map({ $0.permitsCoupledEditorTransportRead(pair: pair) })
                ?? (AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false
                    && AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false),
              // The held proof above freshly renews the complete original
              // native paths/census. Do not repeat global Mixer discovery for each
              // guarded Help read; unowned callers keep both original checks.
              transportProof != nil || (pair.track.currentIndex() != nil && pair.strip.currentIndex(runtime: runtime) != nil),
              let final: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
              CFEqual(final, editor), operationPermitted() else { return false }
        return true
        }
    }

    /// Continue only an already-owned name effect through this same plan's
    /// original-header output renewal. The issued Mixer reference stays bound
    /// to its original strip; the native replacement is request-local custody.
    static func renewingOwnedCoupledName(_ proof: OwnedInverse,
        through source: AccessibilityChannel.OriginalHeaderSourceRenewal
    ) async -> OwnedInverse? {
        let originalIndices = source.observation.strips.indices.filter {
            CFEqual(source.observation.strips[$0], source.original.strip)
        }
        func refusal(_ checkpoint: String) -> OwnedInverse? {
            // Observe the existing cutoff only after refusal. No additional
            // native read or permission is introduced by this diagnostic.
            let acquisition: String
            do {
                try SessionPopulationObservation.requireOwnedAcquisition()
                acquisition = "current"
            } catch { acquisition = String(describing: error) }
            Log.info("Owned name renewal refused: checkpoint=\(checkpoint), acquisition=\(acquisition)", subsystem: "ax")
            return nil
        }
        // Preserve the original short-circuit order; a refused earlier condition
        // never evaluates a later native or registry read just for diagnosis.
        guard let mirror = proof.mirror else { return refusal("mirror") }
        guard mirror.pair.track.matches(source.originalTrack) else { return refusal("original_track") }
        guard mirror.pair.strip.matches(source.original) else { return refusal("original_strip") }
        guard CFEqual(source.original.window, source.observation.window) else { return refusal("original_window") }
        guard CFEqual(source.original.mixer, source.observation.mixer) else { return refusal("original_mixer") }
        guard source.original.document.utf8.elementsEqual(source.observation.document.utf8) else { return refusal("original_document") }
        guard source.permits(runtime: mirror.pair.track.runtime) else { return refusal("source_custody") }
        // A peer can redraw while this exact source survives. Retain its
        // observed ordinal in that case; a different renewed source still
        // requires retirement of the original in this freshly authenticated
        // complete native census, never label-based rebinding or discovery.
        guard source.pair.strip.matches(source.original)
            ? originalIndices == [source.index] : originalIndices.isEmpty else { return refusal("original_retirement") }
        guard await proof.registry.resolve(mirror.reference)?.physicalMixerStrip?.matches(mirror.registryStrip ?? mirror.pair.strip) == true
        else { return refusal("original_registry") }
        var retainedStripName = mirror.retainedStripName
        if retainedStripName?.utf8.elementsEqual(proof.before.utf8) == true {
            // The verified rename can precede its Mixer label propagation.
            // Only this owned Send renewal may advance the old name to the
            // exact name already written; arbitrary changed labels stay refused.
            let observed: String? = AXHelpers.HelpReadGuard.$current.withValue(
                .init(allowHelpReads: false, stop: { !operationPermitted() })) {
                    guard operationPermitted(),
                          case .success(.some(let name)) = AXPluginInstanceIdentity.stripNameResult(
                            source.pair.strip.strip, runtime: mirror.pair.track.runtime.ax) else { return nil }
                    return name
                }
            if observed?.utf8.elementsEqual(proof.written.utf8) == true {
                retainedStripName = proof.written
            }
        }
        var updated = proof
        updated.mirror = CoupledMirror(pair: source.pair, reference: mirror.reference, snapshot: mirror.snapshot,
            preservedTracks: mirror.preservedTracks, preservedStrips: mirror.preservedStrips,
            registryStrip: mirror.registryStrip ?? mirror.pair.strip, renewal: source,
            retainedStripName: retainedStripName)
        guard let renewed = updated.mirror else { return refusal("renewed_mirror") }
        guard await renewed.isCurrent(name: proof.written, project: proof.project, target: proof.target, registry: proof.registry)
        else { return refusal("renewed_names_or_registry") }
        guard source.permits(runtime: mirror.pair.track.runtime) else { return refusal("final_source_custody") }
        return updated
    }

    private static func readHeldCoupledName(_ mirror: CoupledMirror, project: TargetReference,
                                           target: TargetReference, registry: TargetRegistry,
                                           expectedName: String? = nil) async -> String? {
        let guardHelp = AXHelpers.HelpReadGuard(allowHelpReads: false, stop: { !operationPermitted() })
        return await AXHelpers.HelpReadGuard.$current.withValue(guardHelp) {
            guard operationPermitted(), let index = mirror.pair.track.currentIndex(),
                  case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(
                    from: mirror.pair.track.header, runtime: mirror.pair.track.runtime.ax),
                  expectedName.map({ name.utf8.elementsEqual($0.utf8) }) ?? true,
                  await mirror.isCurrent(name: name, project: project, target: target, registry: registry),
                  case .success(.some(let finalName)) = AXValueExtractors.extractTrackNameResult(
                    from: mirror.pair.track.header, runtime: mirror.pair.track.runtime.ax),
                  finalName.utf8.elementsEqual(name.utf8), mirror.pair.track.currentIndex() == index,
                  operationPermitted() else { return nil }
            return finalName
        }
    }

    fileprivate struct CoupledMirror: Sendable {
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let reference: TargetReference
        let snapshot: TargetRegistrySnapshot
        // Only names on already observed physical peers. This is not a new
        // population scan or a claim about hidden/unobserved host effects.
        var preservedTracks: [TrackState] = []
        var preservedStrips: [ChannelStripState] = []
        var registryStrip: AXMixerStripBinding.Binding? = nil
        var renewal: AccessibilityChannel.OriginalHeaderSourceRenewal? = nil
        var retainedStripName: String? = nil

        func permitsStripName(_ name: String, before: String, after: String?) -> Bool {
            let expected = retainedStripName ?? before
            let accepted = name.utf8.elementsEqual(expected.utf8)
                || (expected.utf8.elementsEqual(before.utf8) && after.map { name.utf8.elementsEqual($0.utf8) } == true)
            if !accepted {
                Log.info("Owned name mirror refused: retained strip name changed (matches track name: \(name.utf8.elementsEqual(before.utf8)))", subsystem: "ax")
            }
            return accepted
        }

        /// Only adapter-issued earlier effects can revise this capture's peers.
        /// The normal fresh pair/membership reads still corroborate these exact bytes.
        func acknowledging(_ effects: [OwnedInverse], project: TargetReference,
                           target: TargetReference, registry: TargetRegistry) -> CoupledMirror? {
            var updated = self
            guard Set(effects.map(\.target)).count == effects.count else { return nil }
            for effect in effects where effect.target != target {
                guard effect.project == project, effect.registry === registry,
                      let peer = effect.mirror, peer.snapshot == snapshot else { return nil }
                let tracks = updated.preservedTracks.indices.filter {
                    updated.preservedTracks[$0].physicalBinding?.matches(peer.pair.track) == true
                }
                let strips = updated.preservedStrips.indices.filter {
                    updated.preservedStrips[$0].physicalBinding?.matches(peer.pair.strip) == true
                }
                guard tracks.count == 1, strips.count == 1,
                      let track = tracks.first, let strip = strips.first,
                      let stripBefore = effect.stripBefore, let stripAfter = peer.retainedStripName else { return nil }
                let before = updated.preservedTracks[track].name.utf8.elementsEqual(effect.before.utf8)
                    && updated.preservedStrips[strip].name?.utf8.elementsEqual(stripBefore.utf8) == true
                let alreadyRecorded = updated.preservedTracks[track].name.utf8.elementsEqual(effect.written.utf8)
                    && updated.preservedStrips[strip].name?.utf8.elementsEqual(stripAfter.utf8) == true
                guard before || alreadyRecorded else { return nil }
                updated.preservedTracks[track].name = effect.written
                updated.preservedStrips[strip].name = stripAfter
            }
            return updated
        }

        /// An inverse preserves peers' current names, never the old capture's
        /// names. Original physical sources still decide membership/ownership.
        func withCurrentPeerNames() -> CoupledMirror? {
            let guardHelp = AXHelpers.HelpReadGuard(allowHelpReads: false, stop: { !operationPermitted() })
            return AXHelpers.HelpReadGuard.$current.withValue(guardHelp) {
                readCurrentPeerNames()
            }
        }

        private func readCurrentPeerNames() -> CoupledMirror? {
            var renewed = self
            guard pair.track.currentIndex() != nil, pair.strip.currentIndex(runtime: pair.track.runtime) != nil,
                  membershipStillHeld() else {
                // A coalesced early owner failure must not bypass the old
                // exposed peers' irreversible lifetime cutoff.
                for row in preservedTracks { row.physicalBinding?.exposure?.end() }
                return nil
            }
            for index in preservedTracks.indices {
                guard operationPermitted(), let source = preservedTracks[index].physicalBinding,
                      source.document.utf8.elementsEqual(pair.track.document.utf8),
                      CFEqual(source.window, pair.track.window) else { return nil }
                let ordinal = source.exposure == nil ? nil : source.currentIndex()
                guard source.exposure == nil || ordinal != nil,
                      case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(
                        from: source.header, runtime: source.runtime.ax),
                      source.exposure == nil || source.currentIndex() == ordinal else { return nil }
                renewed.preservedTracks[index].name = name
            }
            if renewal != nil {
                guard let names = renewedPeerStripNames(), names.count == preservedStrips.count else { return nil }
                // Aggregate preservation only. Historical peer bindings are not
                // rebound to these rows or granted any mutation authority.
                for index in preservedStrips.indices { renewed.preservedStrips[index].name = names[index] }
            } else { for index in preservedStrips.indices {
                guard operationPermitted(), let source = preservedStrips[index].physicalBinding,
                      source.document.utf8.elementsEqual(pair.strip.document.utf8),
                      CFEqual(source.window, pair.strip.window), CFEqual(source.mixer, pair.strip.mixer),
                      case .success(.some(let name)) = AXPluginInstanceIdentity.stripNameResult(
                        source.strip, runtime: pair.track.runtime.ax) else { return nil }
                renewed.preservedStrips[index].name = name
            } }
            guard renewed.peerNamesStillHeld() else { return nil }
            guard pair.strip.currentIndex(runtime: pair.track.runtime) != nil,
                  pair.track.currentIndex() != nil, operationPermitted() else {
                for row in preservedTracks { row.physicalBinding?.exposure?.end() }
                return nil
            }
            return renewed
        }

        private func membershipStillHeld(ownedEditor: AXUIElement? = nil) -> Bool {
            let trackSources = [pair.track] + preservedTracks.compactMap(\.physicalBinding)
            let stripSources = [pair.strip] + preservedStrips.compactMap(\.physicalBinding)
            func stripMembership(_ current: [AXUIElement]) -> Bool {
                guard let renewal else {
                    return current.allSatisfy { strip in stripSources.filter { CFEqual(strip, $0.strip) }.count == 1 }
                }
                // This output's original-header receipt owns the entire new
                // census. It does not establish continuity of individual peers.
                let held = renewal.observation.strips
                return renewal.pair.strip.matches(pair.strip) && held.count == current.count
                    && held.filter({ CFEqual($0, pair.strip.strip) }).count == 1
                    && zip(held, current).allSatisfy { CFEqual($0, $1) }
            }
            guard operationPermitted(), ownedEditor != nil || (renewal.map({ $0.permits(runtime: pair.track.runtime) }) ?? true),
                  trackSources.count == preservedTracks.count + 1,
                  stripSources.count == preservedStrips.count + 1,
                  case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(
                    in: pair.track.window, runtime: pair.track.runtime),
                  headers.count == trackSources.count,
                  headers.allSatisfy({ header in trackSources.filter { CFEqual(header, $0.header) }.count == 1 }),
                  let enumeration = AXLogicProElements.mixerChannelStripsIfCompletelyRead(
                    in: pair.strip.mixer, runtime: pair.track.runtime.ax),
                  enumeration.strips.count == stripSources.count,
                  stripMembership(enumeration.strips),
                  operationPermitted() else { return false }
            return ownedEditor != nil || (renewal.map({ $0.permits(runtime: pair.track.runtime) }) ?? true)
        }

        private func renewedPeerStripNames(ownedEditor: AXUIElement? = nil) -> [String]? {
            guard membershipStillHeld(ownedEditor: ownedEditor),
                  let names = readRenewedPeerStripNames(),
                  membershipStillHeld(ownedEditor: ownedEditor), operationPermitted() else { return nil }
            return names
        }

        /// Pure name reads only. Callers bracket the whole read group with
        /// fresh complete membership checks; this helper grants no custody.
        private func readRenewedPeerStripNames() -> [String]? {
            guard let renewal else { return nil }
            var names: [String] = []
            for strip in renewal.observation.strips where !CFEqual(strip, pair.strip.strip) {
                guard operationPermitted(),
                      case .success(.some(let name)) = AXPluginInstanceIdentity.stripNameResult(strip,
                        runtime: pair.track.runtime.ax) else { return nil }
                names.append(name)
            }
            guard names.count == preservedStrips.count, operationPermitted() else { return nil }
            return names
        }

        private func peerNamesStillHeld(ownedEditor: AXUIElement? = nil) -> Bool {
            // These pure name reads share fresh complete CF membership
            // bookends and the caller's deciding original-pair owner checks.
            guard membershipStillHeld(ownedEditor: ownedEditor), peerNameValuesStillHeld() else { return false }
            return membershipStillHeld(ownedEditor: ownedEditor) && operationPermitted()
        }

        private func peerNameValuesStillHeld() -> Bool {
            // Exposed headers retain their individual lifetime/ordinal proof.
            for row in preservedTracks {
                guard operationPermitted(), let source = row.physicalBinding,
                      source.document.utf8.elementsEqual(pair.track.document.utf8),
                      CFEqual(source.window, pair.track.window) else { return false }
                let index = source.exposure == nil ? nil : source.currentIndex()
                guard source.exposure == nil || index != nil,
                      case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(
                        from: source.header, runtime: source.runtime.ax),
                      name.utf8.elementsEqual(row.name.utf8),
                      source.exposure == nil || source.currentIndex() == index else { return false }
            }
            if renewal != nil {
                // Track and strip names form one pure read group, already
                // bracketed here. Do not nest another complete census pair.
                guard let names = readRenewedPeerStripNames(), names.count == preservedStrips.count,
                      zip(names, preservedStrips).allSatisfy({ name, row in
                          row.name.map { name.utf8.elementsEqual($0.utf8) } == true
                      }) else { return false }
            } else { for row in preservedStrips {
                guard operationPermitted(), let source = row.physicalBinding, let expected = row.name,
                      source.document.utf8.elementsEqual(pair.strip.document.utf8),
                      CFEqual(source.window, pair.strip.window), CFEqual(source.mixer, pair.strip.mixer),
                      case .success(.some(let name)) = AXPluginInstanceIdentity.stripNameResult(
                        source.strip, runtime: pair.track.runtime.ax),
                      name.utf8.elementsEqual(expected.utf8) else { return false }
            } }
            return operationPermitted()
        }

        private func renewedNamesStillHeld(before: String, after: String?,
            source: AccessibilityChannel.OriginalHeaderSourceRenewal) -> Bool {
            let trackSources = [pair.track] + preservedTracks.compactMap(\.physicalBinding)
            guard source.pair.track.matches(pair.track), source.originalTrack.matches(pair.track),
                  source.pair.strip.matches(pair.strip),
                  trackSources.count == preservedTracks.count + 1,
                  preservedStrips.compactMap(\.physicalBinding).count == preservedStrips.count,
                  source.observation.headers.count == trackSources.count,
                  source.observation.headers.allSatisfy({ header in
                      trackSources.filter { CFEqual(header, $0.header) }.count == 1
                  }),
                  source.observation.strips.count == preservedStrips.count + 1,
                  source.observation.strips.filter({ CFEqual($0, pair.strip.strip) }).count == 1 else { return false }
            // The actual renewal rechecks complete current native membership,
            // source lifetime, selection, document and stopped transport at both
            // ends of this pure value group. Its checks grant no write authority.
            guard operationPermitted(), source.permits(runtime: pair.track.runtime),
                  peerNameValuesStillHeld(),
                  case .success(.some(let stripName)) = AXPluginInstanceIdentity.stripNameResult(pair.strip.strip,
                    runtime: pair.track.runtime.ax), permitsStripName(stripName, before: before, after: after),
                  case .success(.some(let trackName)) = AXValueExtractors.extractTrackNameResult(
                    from: pair.track.header, runtime: pair.track.runtime.ax),
                  trackName.utf8.elementsEqual(before.utf8)
                    || after.map({ trackName.utf8.elementsEqual($0.utf8) }) == true,
                  source.permits(runtime: pair.track.runtime), operationPermitted() else { return false }
            return true
        }

        func namesStillHeld(before: String, after: String? = nil, ownedEditor: AXUIElement? = nil) -> Bool {
            let guardHelp = AXHelpers.HelpReadGuard(allowHelpReads: false, stop: { !operationPermitted() })
            return AXHelpers.HelpReadGuard.$current.withValue(guardHelp) {
                if ownedEditor == nil, let renewal {
                    return renewedNamesStillHeld(before: before, after: after, source: renewal)
                }
                func matches(_ name: String) -> Bool {
                    name.utf8.elementsEqual(before.utf8) || after.map { name.utf8.elementsEqual($0.utf8) } == true
                }
                let names = [before] + (after.map { [$0] } ?? [])
                guard ownedEditor.map({ permitsCoupledEditorRead($0, pair: pair, names: names) }) ?? true,
                      operationPermitted(), membershipStillHeld(ownedEditor: ownedEditor), pair.track.currentIndex() != nil,
                      pair.strip.currentIndex(runtime: pair.track.runtime) != nil,
                      // Peer reads can redraw or change the pair. Its deciding
                      // native name/custody reads must follow the last peer read.
                      peerNamesStillHeld(ownedEditor: ownedEditor),
                      case .success(.some(let stripName)) = AXPluginInstanceIdentity.stripNameResult(pair.strip.strip,
                        runtime: pair.track.runtime.ax), permitsStripName(stripName, before: before, after: after),
                      case .success(.some(let trackName)) = AXValueExtractors.extractTrackNameResult(
                        from: pair.track.header, runtime: pair.track.runtime.ax), matches(trackName),
                      pair.strip.currentIndex(runtime: pair.track.runtime) != nil,
                      pair.track.currentIndex() != nil, operationPermitted(),
                      ownedEditor.map({ permitsCoupledEditorRead($0, pair: pair, names: names) }) ?? true else { return false }
                return true
            }
        }

        func isCurrent(name: String, project: TargetReference, target: TargetReference,
                       registry: TargetRegistry) async -> Bool {
            guard operationPermitted(), await registry.currentSnapshot == snapshot,
                  let projectBinding = await registry.resolveCurrentProject(project),
                  let path = projectBinding.descriptor.projectFilePath,
                  pair.strip.projectPath?.utf8.elementsEqual(path.utf8) == true,
                  pair.track.document.utf8.elementsEqual(pair.strip.document.utf8),
                  await registry.resolve(target)?.physicalTrack?.matches(pair.track) == true,
                  await registry.resolve(reference)?.physicalMixerStrip?.matches(registryStrip ?? pair.strip) == true else {
                Log.info("Owned name mirror refused: operation or registry snapshot", subsystem: "ax")
                return false
            }
            let read = namesStillHeld(before: name)
            if !read { Log.info("Owned name mirror refused: native names or membership", subsystem: "ax") }
            guard read, await registry.currentSnapshot == snapshot,
                  await registry.resolveCurrentProject(project)?.descriptor == projectBinding.descriptor,
                  // Actor bookends cannot replace the later native pair read.
                  namesStillHeld(before: name), operationPermitted() else {
                Log.info("Owned name mirror refused: final name or registry bookend", subsystem: "ax")
                return false
            }
            return true
        }
    }

    private static func applySelecting(
        _ action: Action, router: ChannelRouter, cache: StateCache, registry: TargetRegistry,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?, mirror: CoupledMirror?,
        selectionOrigin: AXTrackBinding.Binding?, preservingFootprint: (@Sendable (Bool, AXUIElement?) -> Bool)? = nil,
        afterVerifiedWrite: PostVerifiedWrite? = nil, expectedStripAfter: String? = nil,
        restoringMixerFocus: Bool = false
    ) async -> Receipt {
        guard let origin = selectionOrigin, let mirror else {
            return await applyChecked(action, router: router, cache: cache, registry: registry,
                liveTrackName: liveTrackName, liveTrackNames: liveTrackNames, mirror: mirror, preservingFootprint: preservingFootprint, afterVerifiedWrite: afterVerifiedWrite, expectedStripAfter: expectedStripAfter,
                restoringMixerFocus: restoringMixerFocus)
        }
        let source = mirror.pair.track
        func exclusive(_ binding: AXTrackBinding.Binding) -> Bool {
            guard let index = binding.currentIndex(),
                  AccessibilityChannel.selectionIsExclusive(index: index, runtime: binding.runtime) else { return false }
            return binding.currentIndex() == index
        }
        var allowWrittenName = false
        var passiveFocusProofs: [AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus] = []
        var originalMixerFocus: AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus?
        var sampledOriginalFocus = false
        var originalMixerFocusLost = false
        func focusPermitted() -> Bool {
            var permitted = false
            defer { if !permitted { originalMixerFocusLost = true } }
            guard let pid = source.runtime.logicProPID(),
                  source.runtime.focusedApplicationPID() == pid else { return false }
            switch AccessibilityChannel.readLogicKeyboardFocus(runtime: source.runtime) {
            case .notTextEditing: sampledOriginalFocus = true
            case .textEditing:
                guard let app = AXLogicProElements.appRoot(runtime: source.runtime),
                      let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                        runtime: source.runtime.ax) else { return false }
                if !sampledOriginalFocus {
                    sampledOriginalFocus = true
                    let captured = [mirror.pair.strip] + mirror.preservedStrips.compactMap(\.physicalBinding)
                    if captured.filter({ CFEqual($0.strip, focus) && CFEqual($0.window, source.window)
                        && CFEqual($0.mixer, mirror.pair.strip.mixer)
                        && $0.document.utf8.elementsEqual(source.document.utf8) }).count == 1,
                       let observed = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveMixerReadFocus(
                        window: source.window, logic: source.runtime, acquisitionPermitted: { operationPermitted() }),
                       CFEqual(observed.focus, focus), CFEqual(observed.binding.mixer, mirror.pair.strip.mixer),
                       observed.document.utf8.elementsEqual(source.document.utf8) {
                        originalMixerFocus = observed
                    }
                }
                // Zero insertion metadata on the original immutable Mixer strip
                // is not an editor. Reuse only that captured read witness; target,
                // pair, selection and writer authority still come from held().
                if let proof = originalMixerFocus, CFEqual(proof.focus, focus) {
                    guard !originalMixerFocusLost, proof.permits() else { return false }
                } else if let proof = passiveFocusProofs.first(where: { CFEqual($0.focus, focus) }) {
                    guard proof.permits() else { return false }
                } else {
                    guard let proof = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope.PassiveHeaderReadFocus(
                        window: source.window, logic: source.runtime),
                        CFEqual(proof.header, origin.header) || CFEqual(proof.header, source.header) else { return false }
                    passiveFocusProofs.append(proof)
                }
            case .unreadable: return false
            }
            permitted = source.runtime.logicProPID() == pid && source.runtime.focusedApplicationPID() == pid
            return permitted
        }
        func held() -> Bool {
            origin.currentIndex() != nil && source.currentIndex() != nil
                && focusPermitted()
                && mirror.namesStillHeld(before: action.expectedBefore,
                    after: allowWrittenName ? action.desiredAfter : nil)
                && focusPermitted()
        }
        guard await mirror.isCurrent(name: action.expectedBefore, project: action.projectReference,
                target: action.targetReference, registry: registry), held(), exclusive(origin), held() else {
            return .init(status: .rejectedBeforeWrite, before: nil, after: nil,
                survivingReference: nil, inverse: nil,
                result: TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: "track.rename"))
        }
        let needsSelection = !source.matches(origin)
        var selectionAttempted = false
        var selectionChanged = false
        let acquired: Bool
        if needsSelection, let index = source.currentIndex() {
            acquired = AccessibilityChannel.confirmExclusiveSelection(index: index, runtime: source.runtime,
                heldHeader: source.header, permittingWrite: {
                    held() && (exclusive(origin) || exclusive(source)) && held()
                }, willWrite: { selectionAttempted = true }) && exclusive(source) && held()
            selectionChanged = exclusive(source)
        } else { acquired = !needsSelection }
        let receipt: Receipt
        if acquired {
            receipt = await applyChecked(action, router: router, cache: cache, registry: registry,
                liveTrackName: liveTrackName, liveTrackNames: liveTrackNames, mirror: mirror, preservingFootprint: preservingFootprint, afterVerifiedWrite: afterVerifiedWrite, expectedStripAfter: expectedStripAfter,
                restoringMixerFocus: restoringMixerFocus)
        } else {
            receipt = .init(status: .rejectedBeforeWrite, before: nil, after: nil,
                survivingReference: nil, inverse: nil,
                result: TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: "track.rename"))
        }
        allowWrittenName = decodedJSONObject(sharedText(receipt.result))?["write_attempted"] as? Bool == true
        var restored = exclusive(origin) && held()
        var restorationAttempted = false
        if !restored, selectionAttempted, exclusive(source), held(), let index = origin.currentIndex() {
            restored = AccessibilityChannel.confirmExclusiveSelection(index: index, runtime: origin.runtime,
                heldHeader: origin.header, permittingWrite: {
                    held() && (exclusive(source) || exclusive(origin)) && held()
                }, willWrite: { restorationAttempted = true }) && exclusive(origin) && held()
        }
        let effects: [String: Any] = [
            "attempted": (selectionAttempted ? ["track_selection"] : [])
                + (restorationAttempted ? ["track_selection_restoration"] : []),
            "changed": (selectionChanged ? ["track_selection"] : [])
                + (restorationAttempted && restored ? ["track_selection_restoration"] : []),
            "restoration": restored ? "restored" : "not_restored"
        ]
        var body = decodedJSONObject(sharedText(receipt.result)) ?? [:]
        body["track_selection_effects"] = effects
        guard restored else {
            body["hint"] = "The original physical track selection could not be verified restored."
            for key in ["state", "verified", "error", "reason"] { body.removeValue(forKey: key) }
            return .init(status: .attemptedUnverified, before: receipt.before, after: receipt.after,
                survivingReference: nil, inverse: nil,
                result: toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: body), isError: true))
        }
        var inverse = receipt.inverse
        inverse?.selectionOrigin = origin
        let result = toolTextResult(HonestContract.jsonString(body), isError: receipt.result.isError ?? false)
        return .init(status: receipt.status, before: receipt.before, after: receipt.after,
            survivingReference: receipt.survivingReference, inverse: inverse, result: result)
    }

    private static func groupNameAliases(_ mirror: CoupledMirror) -> [String]? {
        guard operationPermitted() else { return nil }
        let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as [String]
        let readings = AXHelpers.getNonHelpAttributes(mirror.pair.strip.strip, attributes,
            runtime: mirror.pair.track.runtime.ax, permittingRead: { operationPermitted() })
        var names: [String] = []
        for (attribute, reading) in zip(attributes, readings) {
            switch reading {
            case .success(.none): continue
            case .failure(let error) where error.isDefinitiveAbsence: continue
            case .success(.some(let raw)):
                if CFGetTypeID(raw) == CFStringGetTypeID(), let name = raw as? String {
                    names.append(name)
                } else if attribute == kAXValueAttribute as String,
                          CFGetTypeID(raw) == CFNumberGetTypeID() || CFGetTypeID(raw) == CFBooleanGetTypeID() {
                    // A scalar group value is not a name alias.
                    continue
                } else { return nil }
            case .failure: return nil
            }
        }
        return operationPermitted() ? names : nil
    }

    private static func applyChecked(
        _ action: Action, router: ChannelRouter, cache: StateCache, registry: TargetRegistry,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?, mirror: CoupledMirror?,
        preservingFootprint: (@Sendable (Bool, AXUIElement?) -> Bool)? = nil,
        afterVerifiedWrite: PostVerifiedWrite? = nil, expectedStripAfter: String? = nil,
        restoringMixerFocus: Bool = false
    ) async -> Receipt {
        if let failure = TrackDispatcher.renameNameFailure(action.desiredAfter) {
            return Receipt(status: .rejectedBeforeWrite, before: nil, after: nil,
                           survivingReference: nil, inverse: nil, result: failure)
        }
        guard preservingFootprint?(false, nil) ?? true else {
            return .init(status: .rejectedBeforeWrite, before: nil, after: nil, survivingReference: nil, inverse: nil,
                result: TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: "track.rename"))
        }
        if let mirror, !(await mirror.isCurrent(name: action.expectedBefore, project: action.projectReference,
                                               target: action.targetReference, registry: registry)) {
            return .init(status: .rejectedBeforeWrite, before: nil, after: nil, survivingReference: nil, inverse: nil,
                result: TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: "track.rename"))
        }
        // An owned Send renewal also carries a focus-bound observation. Its
        // inverse must validate the writer's exact editor, not the observation's
        // preceding passive focus, while the ordinary Rename menu is open.
        let holdsEditorCustody = preservingFootprint != nil || mirror?.renewal != nil
        let prewrite: (@Sendable (Bool, AXUIElement?) -> Bool)?
        if let mirror {
            prewrite = { allowPreview, editor in
                let activeEditor: AXUIElement?
                if holdsEditorCustody, let editor,
                   let app = AXLogicProElements.appRoot(runtime: mirror.pair.track.runtime),
                   let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                        runtime: mirror.pair.track.runtime.ax), CFEqual(focus, editor) {
                    activeEditor = editor
                } else { activeEditor = nil }
                return mirror.namesStillHeld(before: action.expectedBefore, after: allowPreview ? action.desiredAfter : nil,
                    ownedEditor: activeEditor)
                    && (preservingFootprint?(allowPreview, activeEditor) ?? true)
            }
        } else { prewrite = nil }
        let menuRail = !holdsEditorCustody ? nil : mirror.flatMap { mirror in
            AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: false, stop: { !operationPermitted() })) {
                MenuRailCustody(mirror)
            }
        }
        // The first name in a Bus Send plan precedes its routing renewal.
        // Capture its actual original-source focus now, before the Rename
        // commit can move it to the rail. The option supplies no native proof.
        let initialFocus: AccessibilityChannel.HeldSelectionAssociation?
        if restoringMixerFocus, afterVerifiedWrite == nil, mirror?.renewal == nil {
            guard let pair = mirror?.pair,
                  let held = AccessibilityChannel.HeldSelectionAssociation(window: pair.track.window,
                    logic: pair.track.runtime, expectedProject: nil, requiresProjectReference: false,
                    allowsSelectedChildRailEntry: true,
                    retainedMixerSource: pair.strip),
                  held.hasOriginalSourceFocus(pair.strip), CFEqual(held.mixer, pair.strip.mixer),
                  CFEqual(held.headers[held.originalIndex], pair.track.header), held.permitsRead() else {
                return .init(status: .rejectedBeforeWrite, before: nil, after: nil, survivingReference: nil, inverse: nil,
                    result: TargetRefResolver.staleTargetReferenceResult(action.targetReference.rawValue, operation: "track.rename"))
            }
            initialFocus = held
        } else { initialFocus = nil }
        // Every name leaf and inverse owns a fresh capture; nothing is reused
        // across invocations or reconstructed from the dispatcher JSON.
        let focusBaseline = mirror?.renewal?.observation ?? initialFocus
        let restoresRenewedFocus = afterVerifiedWrite == nil && focusBaseline != nil
        let focusTransport = afterVerifiedWrite == nil && !restoresRenewedFocus ? nil : NameFocusTransportCapture()
        let result = await $coupledNameFocusTransport.withValue(focusTransport) {
          await $coupledWriteBoundary.withValue(prewrite) {
          await $coupledFootprintFocusBookends.withValue(holdsEditorCustody) {
            await $coupledMenuRail.withValue(menuRail) {
            await TrackDispatcher.handle(
            command: "rename",
            params: ["project_ref": .string(action.projectReference.rawValue),
                     "target_ref": .string(action.targetReference.rawValue),
                     "expected_name": .string(action.expectedBefore), "name": .string(action.desiredAfter)],
            router: router, cache: cache, targetRegistry: registry,
            liveTrackName: liveTrackName, liveTrackNames: liveTrackNames
            )
            }
          }
          }
        }
        let body = decodedJSONObject(sharedText(result))
        let before = body?["before"] as? String
        let after = body?["observed"] as? String
        let rejected = body?["state"] as? String == "C" && body?["write_attempted"] as? Bool == false
        func unverified() -> Receipt {
            let response: CallTool.Result
            if body?["state"] as? String == "A" {
                // The writer's earlier observation is not this adapter's later
                // custody proof. Retain actual effects without claiming current A.
                var extras = body ?? [:]
                for key in ["state", "verified", "reason", "error"] { extras.removeValue(forKey: key) }
                extras["hint"] = "The writer completed, but the adapter could not retain the exact-source proof. Reread before another action."
                response = toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras), isError: true)
            } else {
                response = result
            }
            return Receipt(status: rejected ? .rejectedBeforeWrite : .attemptedUnverified,
                           before: before, after: after, survivingReference: nil, inverse: nil, result: response)
        }
        guard body?["state"] as? String == "A", body?["verified"] as? Bool == true,
              let before, before.utf8.elementsEqual(action.expectedBefore.utf8),
              let after, after.utf8.elementsEqual(action.desiredAfter.utf8),
              let binding = await registry.resolve(action.targetReference), binding.kind == .track,
              binding.descriptor.trackName.utf8.elementsEqual(after.utf8),
              await registry.resolveCurrentProject(action.projectReference) != nil, operationPermitted() else {
            return unverified()
        }
        let wrote = body?["write_attempted"] as? Bool == true
        let noOp = body?["via"] as? String == "no-op" && body?["write_attempted"] as? Bool == false
        guard wrote || noOp else {
            return unverified()
        }
        // A committed writer/rebound descriptor is historical evidence. Before
        // granting an inverse, corroborate the retained physical header again;
        // a same-name replacement or a newer edit is not our written state.
        if let source = binding.physicalTrack {
            guard source.currentIndex() != nil,
                  case .success(.some(let currentName)) = AXValueExtractors.extractTrackNameResult(
                    from: source.header, runtime: source.runtime.ax),
                  currentName.utf8.elementsEqual(after.utf8),
                  source.currentIndex() != nil else { return unverified() }
        }
        var verifiedMirror = mirror
        var effect: VerifiedNameEffect?
        if var held = mirror {
            let observed: String? = AXHelpers.HelpReadGuard.$current.withValue(
                .init(allowHelpReads: false, stop: { !operationPermitted() })) {
                    guard case .success(.some(let name)) = AXPluginInstanceIdentity.stripNameResult(
                        held.pair.strip.strip, runtime: held.pair.track.runtime.ax) else { return nil }
                    return name
                }
            guard let observed, held.permitsStripName(observed, before: before, after: after),
                  expectedStripAfter.map({ observed.utf8.elementsEqual($0.utf8) }) ?? true else { return unverified() }
            held.retainedStripName = observed
            // The existing cleanup renews its own changed focus before the
            // deciding native/registry bookends below. Consulting a prior
            // output renewal in that temporary focus would end it, not renew it.
            verifiedMirror = held
            effect = .init(pair: held.pair, trackName: after, stripName: observed)
        }
        // Only a real A, rebound reference and deciding native after-name can
        // run the composed caller's exact original-custody restoration.
        if let afterVerifiedWrite, !(await afterVerifiedWrite(focusTransport?.value, effect)) { return unverified() }
        if restoresRenewedFocus, var held = verifiedMirror, let focusBaseline {
            let pair = held.pair
            // A verified menu commit can land on the original rail. Renew that
            // owned UI effect without querying (and invalidating) its old focus
            // proof. The existing initializer preserves every original native
            // path, ordered census, transport and viewport restoration baseline.
            guard let renewed = AccessibilityChannel.HeldSelectionAssociation(window: pair.track.window,
                logic: pair.track.runtime, expectedProject: nil, requiresProjectReference: false,
                allowsSelectedChildRailEntry: true, restorationBaseline: focusBaseline),
                CFEqual(renewed.headers[renewed.originalIndex], pair.track.header),
                CFEqual(renewed.mixer, pair.strip.mixer),
                renewed.document.utf8.elementsEqual(pair.track.document.utf8),
                renewed.strips.filter({ CFEqual($0, pair.strip.strip) }).count == 1,
                renewed.permitsRead() else {
                Log.info("Owned name renewal refused: committed-focus baseline", subsystem: "ax")
                return unverified()
            }
            if let source = held.renewal {
                held.renewal = .init(pair: source.pair, index: source.index, original: source.original,
                    originalTrack: source.originalTrack, observation: renewed)
            }
            let restoredMirror = held
            guard await restoredMirror.isCurrent(name: after, project: action.projectReference,
                target: action.targetReference, registry: registry),
                await renewed.restoreCommittedFocus(source: pair.strip, expectedName: held.retainedStripName ?? after,
                    transport: focusTransport?.value,
                    preservingFootprint: { restoredMirror.namesStillHeld(before: after) },
                    referenceIsCurrent: {
                        await restoredMirror.isCurrent(name: after, project: action.projectReference,
                            target: action.targetReference, registry: registry)
                    }, stoppingWhen: { !operationPermitted() }) else {
                Log.info("Owned name renewal refused: committed-focus restoration", subsystem: "ax")
                return unverified()
            }
            verifiedMirror = restoredMirror
        }
        guard preservingFootprint?(true, nil) ?? true else { return unverified() }
        if let mirror = verifiedMirror, !(await mirror.isCurrent(name: after, project: action.projectReference,
                                               target: action.targetReference, registry: registry)) { return unverified() }
        var inverse = wrote ? OwnedInverse(project: action.projectReference, target: action.targetReference,
                                          before: before, written: after, registry: registry, cache: cache, mirror: verifiedMirror,
                                          stripBefore: mirror.map { $0.retainedStripName ?? before }) : nil
        inverse?.restoresMixerFocus = restoringMixerFocus
        if restoringMixerFocus, let owned = inverse, let current = owned.mirror,
           let stripName = current.retainedStripName {
            let previousStripName = mirror?.retainedStripName ?? before
            if !previousStripName.utf8.elementsEqual(stripName.utf8) {
                guard let aliases = groupNameAliases(current),
                      await current.isCurrent(name: after, project: action.projectReference,
                        target: action.targetReference, registry: registry) else {
                    Log.info("Owned name presentation refused: aliases or current names", subsystem: "ax")
                    return unverified()
                }
                if aliases.contains(where: { $0.utf8.elementsEqual(previousStripName.utf8) }) {
                    // The actual owned name field has changed, but Logic can
                    // retain its preceding name on the same physical group.
                    // Reuse the original-header excursion, not another popup
                    // or name write; optional peer associations are unnecessary.
                    Log.info("Owned name presentation requires original-header refresh", subsystem: "ax")
                    let pair = current.pair
                    let refreshed = await AccessibilityChannel.renewSourceThroughOriginalHeader(pair,
                        original: pair.strip, runtime: pair.track.runtime,
                        sourceDisposition: .survivingOriginal, observingPeerHeaders: [])
                    guard let source = refreshed.source, source.pair.strip.matches(pair.strip),
                          source.originalTrack.matches(pair.track), source.permits(runtime: pair.track.runtime),
                          let renewed = await renewingOwnedCoupledName(owned, through: source),
                          let renewedMirror = renewed.mirror else {
                        Log.info("Owned name presentation refused: original-header refresh", subsystem: "ax")
                        return unverified()
                    }
                    guard let aliases = groupNameAliases(renewedMirror),
                          aliases.contains(where: { $0.utf8.elementsEqual(stripName.utf8) }),
                          !aliases.contains(where: { $0.utf8.elementsEqual(previousStripName.utf8) }),
                          await renewedMirror.isCurrent(name: after, project: action.projectReference,
                            target: action.targetReference, registry: registry),
                          source.permits(runtime: pair.track.runtime), preservingFootprint?(true, nil) ?? true else {
                        Log.info("Owned name presentation refused: refreshed aliases or custody", subsystem: "ax")
                        return unverified()
                    }
                    inverse = renewed
                }
            }
        }
        return Receipt(status: wrote ? .applied : .alreadySatisfied, before: before, after: after,
                       survivingReference: action.targetReference, inverse: inverse, result: result)
    }

    static func inverse(
        _ proof: OwnedInverse, router: ChannelRouter,
        liveTrackName: @escaping @Sendable (Int) -> String?,
        liveTrackNames: @escaping @Sendable () -> [Int: String]?,
        preservingFootprint: (@Sendable (Bool, AXUIElement?) -> Bool)? = nil,
        afterVerifiedWrite: PostVerifiedWrite? = nil
    ) async -> Receipt {
        // Only this pair is restored. Observe newer peers as the preservation
        // baseline, rather than overwriting them or dropping their proof.
        let mirror: CoupledMirror?
        if let original = proof.mirror {
            guard let current = original.withCurrentPeerNames() else {
                return .init(status: .rejectedBeforeWrite, before: nil, after: nil,
                    survivingReference: nil, inverse: nil,
                    result: TargetRefResolver.staleTargetReferenceResult(proof.target.rawValue, operation: "track.rename"))
            }
            mirror = current
        } else { mirror = nil }
        return await applySelecting(Action(projectReference: proof.project, targetReference: proof.target,
                           expectedBefore: proof.written, desiredAfter: proof.before),
                    router: router, cache: proof.cache, registry: proof.registry,
                    liveTrackName: liveTrackName, liveTrackNames: liveTrackNames, mirror: mirror,
                    selectionOrigin: proof.selectionOrigin, preservingFootprint: preservingFootprint, afterVerifiedWrite: afterVerifiedWrite,
                    expectedStripAfter: proof.stripBefore, restoringMixerFocus: proof.restoresMixerFocus)
    }

    private static func sharedText(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }
}
