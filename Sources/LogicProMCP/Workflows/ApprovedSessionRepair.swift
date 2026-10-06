@preconcurrency import ApplicationServices
import CryptoKit
import Foundation
import MCP

/// The native counterpart of one retained canonical view task. It is not a wire
/// token: only the retained capture supplies its process-local AX custody.
final class ApprovedSessionRepair: @unchecked Sendable {
    @TaskLocal static var current: ApprovedSessionRepair?
    let plan: SagaPlan
    let before: Bool
    let desired: Bool
    let projectRef: TargetReference
    let binding: SessionPopulationObservation.PresentationBinding
    private let cache: StateCache
    private let registry: TargetRegistry
    private let journal: SagaJournal
    private let projectEpoch: UInt64
    private var ran = false
    private var ownedVisibility: Bool?
    private var ownedMixer: AXUIElement?

    private init(plan: SagaPlan, before: Bool, desired: Bool, projectRef: TargetReference,
                 binding: SessionPopulationObservation.PresentationBinding, projectEpoch: UInt64,
                 cache: StateCache, registry: TargetRegistry, journal: SagaJournal) {
        self.plan = plan; self.before = before; self.desired = desired; self.projectRef = projectRef
        self.binding = binding; self.projectEpoch = projectEpoch
        self.cache = cache; self.registry = registry; self.journal = journal
    }

    static func retained(id: String, digest: String, key: String, cache: StateCache,
                         registry: TargetRegistry, journal: SagaJournal) async -> ApprovedSessionRepair? {
        guard FeatureFlags.adr002TargetRef,
              let (canonical, source) = await cache.retainedRepairSource(id: id, digest: digest),
              await cache.inspectionIsCurrent(source.capture),
              let data = canonical.json.data(using: .utf8),
              var object = try? JSONDecoder().decode(Value.self, from: data).objectValue,
              object["executable"]?.boolValue == true,
              object["plan_id"]?.stringValue == id, object["digest"]?.stringValue == digest,
              let steps = object["steps"]?.arrayValue, steps.count == 1,
              object["preview"]?.arrayValue == steps,
              let step = steps[0].objectValue, step["kind"]?.stringValue == "mixer_visibility",
              step["blocked_reasons"]?.arrayValue?.isEmpty == true,
              let rawRef = step["target_ref"]?.stringValue,
              case .issued(let issued)? = source.capture.projectIssuance, issued.rawValue == rawRef,
              let before = step["before"]?.objectValue?["visible"]?.boolValue,
              let desired = step["after"]?.objectValue?["visible"]?.boolValue,
              let fresh = source.capture.freshPopulation, fresh.stable,
              fresh.presentationObservation?.mixerVisible == before,
              fresh.presentationObservation?.isPlaying == false,
              fresh.presentationObservation?.isRecording == false,
              let binding = fresh.presentationBinding,
              binding.navigationBaseline != nil, binding.transport != nil,
              binding.pid != nil, binding.app != nil, binding.focus != nil
        else { return nil }
        object.removeValue(forKey: "plan_id"); object.removeValue(forKey: "digest")
        guard let encoded = try? encodeJSONStrict(Value.object(object), compact: true),
              SHA256.hash(data: Data(encoded.utf8)).map({ String(format: "%02x", $0) }).joined() == digest else { return nil }
        let saga = SagaPlan(steps: [.init(operationID: .navigateToggleView, targetRef: issued,
            params: ["view": .string("mixer"), "visible": .bool(desired)],
            expectedInverse: .init(operationID: .navigateToggleView, valueParameter: "visible"))],
            idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
        return .init(plan: saga, before: before, desired: desired, projectRef: issued, binding: binding,
            projectEpoch: source.capture.projectEpoch, cache: cache, registry: registry, journal: journal)
    }

    func supports(_ step: SagaStep) -> Bool {
        step.operationID == .navigateToggleView && step.targetRef == projectRef
            && Set(step.params.keys) == ["view", "visible"] && step.params["view"] == .string("mixer")
            && step.params["visible"]?.boolValue != nil
            && step.expectedInverse.operationID == .navigateToggleView && step.expectedInverse.valueParameter == "visible"
    }

    private func projectIsCurrent(allowPendingCancellation: Bool = false) async -> Bool {
        guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
        if !allowPendingCancellation, await journal.record(for: plan.idempotencyKey) == .cancellationRequested {
            return false
        }
        guard let target = await registry.resolve(projectRef), target.kind == .project,
              target.projectEpoch == projectEpoch,
              let url = URL(string: binding.document), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              target.descriptor.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true,
              await cache.getProject().filePath?.utf8.elementsEqual(url.path.utf8) == true,
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
        return true
    }

    private func navigation(runtime: AXLogicProElements.Runtime, allowPendingCancellation: Bool = false) async -> AccessibilityChannel.OwnedMixerObservationNavigation? {
        guard await projectIsCurrent(allowPendingCancellation: allowPendingCancellation), let pid = binding.pid, runtime.logicProPID() == pid,
              let app = binding.app, let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, currentApp),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
              let originalFocus = binding.focus, CFEqual(focus, originalFocus),
              let target = await registry.resolve(projectRef),
              let original = binding.navigationBaseline,
              let navigation = AccessibilityChannel.OwnedMixerObservationNavigation(window: binding.window, runtime: runtime,
                expectedProject: target.descriptor, requiresProjectReference: true,
                referenceIsCurrent: { [self] in await projectIsCurrent(allowPendingCancellation: allowPendingCancellation) }),
              navigation.title.utf8.elementsEqual(binding.title.utf8), navigation.document.utf8.elementsEqual(binding.document.utf8),
              navigation.headers.count == original.headers.count,
              zip(navigation.headers, original.headers).allSatisfy({ CFEqual($0, $1) }),
              navigation.selected == original.selected,
              await projectIsCurrent(allowPendingCancellation: allowPendingCancellation) else { return nil }
        return navigation
    }

    private func stop(runtime: AXLogicProElements.Runtime) -> Bool {
        (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil
            || StatePoller.backgroundTickYields(to: AccessibilityChannel.readLogicKeyboardFocus(runtime: runtime))
    }

    private func reading() async -> (Bool, AXUIElement?)? {
        let runtime = binding.runtime
        // Pending journal cancellation must not suppress the independent reads
        // needed to verify a forward effect or conditionally restore our own one.
        guard let navigation = await navigation(runtime: runtime, allowPendingCancellation: true) else { return nil }
        return await navigation.approvedVisibility(expectedTransport: binding.transport,
            stoppingWhen: { [self] in stop(runtime: runtime) })
    }

    func readState(_ step: SagaStep) async -> ObservedState? {
        guard supports(step), let (value, _) = await reading() else { return nil }
        let evidence = SagaReadEvidence(readSource: .axProjectMixerVisibility, provenance: .liveIndependent,
            trackIndex: nil, projectReference: projectRef.rawValue, field: "mixer_visible",
            observed: .bool(value), sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
        return .init(value: .bool(value), evidence: evidence.summary, read: evidence)
    }

    func perform(_ desired: Bool, runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let ownedInverse = ran && ownedVisibility != nil && desired == before
        let expected: Bool?
        let expectedMixer: AXUIElement?
        if !ran { expected = before; expectedMixer = binding.mixer }
        else { expected = ownedVisibility ?? (before == self.desired ? before : nil); expectedMixer = ownedMixer ?? binding.mixer }
        guard let expected, desired == self.desired || desired == before,
              let navigation = await navigation(runtime: runtime, allowPendingCancellation: ownedInverse) else {
            return .error(HonestContract.encodeStateC(error: .staleTargetReference,
                hint: "The retained view custody or conditional inverse is unavailable.", extras: ["write_attempted": false]))
        }
        let result = await navigation.setFinalVisibility(desired, expectedBefore: expected,
            expectedMixer: expectedMixer, permittingVisibilityChange: { [self] in
                guard await projectIsCurrent(allowPendingCancellation: ownedInverse) else { return false }
                guard let observed = await navigation.approvedVisibility(expectedTransport: binding.transport,
                    stoppingWhen: { [self] in stop(runtime: runtime) }), observed.0 == expected else { return false }
                if expected {
                    guard let mixer = observed.1, let expectedMixer,
                          CFEqual(mixer, expectedMixer) else { return false }
                }
                return true
            }, stoppingWhen: { [self] in stop(runtime: runtime) })
        ran = true
        if case .success(let text) = result, let body = decodedJSONObject(text), body["state"] as? String == "A",
           body["write_attempted"] as? Bool == true, body["before_visible"] as? Bool != desired,
           body["after_visible"] as? Bool == desired,
           let observed = await navigation.approvedVisibility(expectedTransport: binding.transport,
               stoppingWhen: { [self] in stop(runtime: runtime) }), observed.0 == desired {
            if desired {
                guard let mixer = observed.1, let verifiedMixer = navigation.revealedMixer,
                      CFEqual(mixer, verifiedMixer) else { return result }
            }
            ownedVisibility = desired; ownedMixer = observed.1
        }
        return result
    }

    static func apply(params: [String: Value], dependencies: HandlerDependencies) async -> CallTool.Result {
        guard Set(params.keys) == ["plan_id", "digest", "confirmed", "idempotency_key"],
              case .bool(true)? = params["confirmed"],
              let id = params["plan_id"]?.stringValue, !id.isEmpty,
              let digest = params["digest"]?.stringValue, digest.utf8.count == 64,
              let key = try? SagaWire.idempotencyKey(from: ["idempotency_key": params["idempotency_key"] ?? .null]) else {
            return toolInvalidParamsResult("apply_session_repair requires the exact retained plan_id and digest, confirmed:true, and an idempotency_key")
        }
        if let replay = await dependencies.sagaJournal.canonicalReplay(key: key, planID: id, digest: digest) {
            switch replay {
            case .completed(let outcome):
                let duplicate = SagaWire.duplicateOutcome(outcome)
                return toolTextResult(duplicate.body, isError: duplicate.isError)
            case .conflict: return SagaWire.idempotencyConflict(key)
            case .outcomeEvicted(let terminal): return SagaWire.outcomeUnavailable(key, terminal: terminal)
            default: return SagaWire.scopedStateC(.sagaInProgress,
                hint: "This immutable plan key is already running, cancelling or cancelled; it cannot be re-executed.",
                extras: ["idempotency_key": key, "write_attempted": false])
            }
        }
        guard let approval = await retained(id: id, digest: digest, key: key, cache: dependencies.cache,
            registry: dependencies.targetRegistry, journal: dependencies.sagaJournal) else {
            return toolStateCResult(.staleTargetReference,
                hint: "The exact retained plan, required native view/transport evidence, or its original project is unavailable; no replacement plan was generated.",
                extras: ["write_attempted": false])
        }
        return await SystemDispatcher.handle(command: "saga_execute", params: [:], router: dependencies.router,
            cache: dependencies.cache, targetRegistry: dependencies.targetRegistry,
            dialogPresent: dependencies.dialogPresent, sagaJournal: dependencies.sagaJournal,
            mutationGate: dependencies.mutationGate, sagaRefreshAfterWrite: {},
            sagaLifecycleDeadline: dependencies.sagaLifecycleDeadline, approvedSessionRepair: approval)
    }
}
