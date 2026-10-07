@preconcurrency import ApplicationServices
import CryptoKit
import Foundation
import MCP

/// The native counterpart of one retained canonical view task. It is not a wire
/// token: only the retained capture supplies its process-local AX custody.
final class ApprovedSessionRepair: @unchecked Sendable {
    struct ApplyRequest: Sendable {
        let planID: String
        let digest: String
        let key: String

        private init(planID: String, digest: String, key: String) {
            self.planID = planID; self.digest = digest; self.key = key
        }

        static func parse(_ params: [String: Value]) -> ApplyRequest? {
            guard Set(params.keys) == ["plan_id", "digest", "confirmed", "idempotency_key"],
                  case .bool(true)? = params["confirmed"],
                  let id = params["plan_id"]?.stringValue, !id.isEmpty,
                  let digest = params["digest"]?.stringValue, digest.utf8.count == 64,
                  let key = try? SagaWire.idempotencyKey(from: ["idempotency_key": params["idempotency_key"] ?? .null]) else { return nil }
            return .init(planID: id, digest: digest, key: key)
        }

        static func refusal() -> CallTool.Result {
            toolInvalidParamsResult("apply_session_repair requires the exact retained plan_id and digest, confirmed:true, and an idempotency_key", extras: ["write_attempted": false])
        }
    }

    @TaskLocal static var current: ApprovedSessionRepair?
    private struct MixerTask: Sendable {
        let before: Bool
        let desired: Bool
        let binding: SessionPopulationObservation.PresentationBinding
    }
    private struct NameGoal: Sendable {
        let reference: TargetReference
        let name: String
        let binding: AXTrackBinding.Binding
    }
    let plan: SagaPlan
    let projectRef: TargetReference
    private let mixerTask: MixerTask?
    private let nameGoals: [NameGoal]
    private let document: String
    private let cache: StateCache
    private let registry: TargetRegistry
    private let journal: SagaJournal
    private let projectEpoch: UInt64
    private var ran = false
    private var ownedVisibility: Bool?
    private var ownedMixer: AXUIElement?

    private init(plan: SagaPlan, projectRef: TargetReference, document: String,
                 mixerTask: MixerTask? = nil, nameGoals: [NameGoal] = [], projectEpoch: UInt64,
                 cache: StateCache, registry: TargetRegistry, journal: SagaJournal) {
        self.plan = plan; self.projectRef = projectRef; self.document = document
        self.mixerTask = mixerTask; self.nameGoals = nameGoals; self.projectEpoch = projectEpoch
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
              let steps = object["steps"]?.arrayValue,
              object["preview"]?.arrayValue == steps else { return nil }
        object.removeValue(forKey: "plan_id"); object.removeValue(forKey: "digest")
        guard let encoded = try? encodeJSONStrict(Value.object(object), compact: true),
              SHA256.hash(data: Data(encoded.utf8)).map({ String(format: "%02x", $0) }).joined() == digest else { return nil }
        if steps.isEmpty {
            guard let policyObject = object["approved_policy"]?.objectValue,
                  policyObject["presentation"] == nil,
                  case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(policyObject),
                  policy.mixerVisible == nil, policy.roles.isEmpty, policy.outputs.isEmpty, policy.receivers.isEmpty,
                  let names = ProjectSessionAudit.parseApprovedNames(object["approved_names"], policy: policy),
                  !names.isEmpty, names.count == policy.targets.count,
                  ["reasons", "questions", "receiver_questions", "findings", "new_object_inventory"].allSatisfy({
                      object[$0]?.arrayValue?.isEmpty == true
                  }),
                  let unchanged = object["unchanged_tasks"]?.arrayValue,
                  unchanged.count == names.count,
                  Set(unchanged.compactMap(\.stringValue)) == Set(names.map { "name_" + $0.target }),
                  case .issued(let issued)? = source.capture.projectIssuance, policy.projectRef == issued,
                  source.request.domains.contains(.tracks),
                  SessionPopulationObservation.trackRowReadbackReasons(capture: source.capture).isEmpty,
                  let references = source.capture.issued,
                  let projectPath = source.capture.project.filePath,
                  source.capture.freshPopulation?.stable == true else { return nil }
            var goals: [NameGoal] = []
            for name in names {
                guard let target = policy.targets.first(where: { $0.handle == name.target }),
                      case .located(let index) = ProjectSessionAudit.locate(target.trackRef, in: references) else { return nil }
                let rows = source.capture.tracks.filter { $0.id == index }
                guard rows.count == 1, let row = rows.first,
                      row.name.utf8.elementsEqual(name.name.utf8), let binding = row.physicalBinding,
                      let current = await registry.resolve(target.trackRef), current.kind == .track,
                      current.physicalTrack?.matches(binding) == true,
                      binding.projectPath?.utf8.elementsEqual(projectPath.utf8) == true,
                      goals.allSatisfy({ !CFEqual($0.binding.header, binding.header) }) else { return nil }
                goals.append(.init(reference: target.trackRef, name: name.name, binding: binding))
            }
            guard let document = goals.first?.binding.document,
                  goals.allSatisfy({ $0.binding.document.utf8.elementsEqual(document.utf8)
                      && CFEqual($0.binding.window, goals[0].binding.window) }) else { return nil }
            return .init(plan: .init(steps: [], idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest),
                projectRef: issued, document: document, nameGoals: goals, projectEpoch: source.capture.projectEpoch,
                cache: cache, registry: registry, journal: journal)
        }
        guard steps.count == 1,
              let step = steps[0].objectValue, step["kind"]?.stringValue == "mixer_visibility",
              step["blocked_reasons"]?.arrayValue?.isEmpty == true,
              let rawRef = step["target_ref"]?.stringValue,
              case .issued(let issued)? = source.capture.projectIssuance, issued.rawValue == rawRef,
              let before = step["before"]?.objectValue?["visible"]?.boolValue,
              let desired = step["after"]?.objectValue?["visible"]?.boolValue,
              let policyObject = object["approved_policy"]?.objectValue,
              case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(policyObject),
              policy.projectRef == issued, policy.mixerVisible == desired,
              policy.targets.isEmpty, policy.roles.isEmpty, policy.outputs.isEmpty, policy.receivers.isEmpty,
              policyObject["presentation"]?.objectValue.map({ Set($0.keys) == ["mixer_visible"] }) == true,
              object["approved_names"]?.arrayValue?.isEmpty == true,
              object["unchanged_tasks"]?.arrayValue?.isEmpty == true,
              let fresh = source.capture.freshPopulation, fresh.stable,
              fresh.presentationObservation?.mixerVisible == before,
              fresh.presentationObservation?.isPlaying == false,
              fresh.presentationObservation?.isRecording == false,
              let binding = fresh.presentationBinding,
              binding.navigationBaseline != nil, binding.transport != nil,
              binding.pid != nil, binding.app != nil, binding.focus != nil
        else { return nil }
        let saga = SagaPlan(steps: [.init(operationID: .navigateToggleView, targetRef: issued,
            params: ["view": .string("mixer"), "visible": .bool(desired)],
            expectedInverse: .init(operationID: .navigateToggleView, valueParameter: "visible"))],
            idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
        return .init(plan: saga, projectRef: issued, document: binding.document,
            mixerTask: .init(before: before, desired: desired, binding: binding),
            projectEpoch: source.capture.projectEpoch, cache: cache, registry: registry, journal: journal)
    }

    func supports(_ step: SagaStep) -> Bool {
        mixerTask != nil && step.operationID == .navigateToggleView && step.targetRef == projectRef
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
              let url = URL(string: document), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              target.descriptor.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true,
              await cache.getProject().filePath?.utf8.elementsEqual(url.path.utf8) == true,
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
        return true
    }

    private func navigation(runtime: AXLogicProElements.Runtime, allowPendingCancellation: Bool = false) async -> AccessibilityChannel.OwnedMixerObservationNavigation? {
        guard let binding = mixerTask?.binding,
              await projectIsCurrent(allowPendingCancellation: allowPendingCancellation), let pid = binding.pid, runtime.logicProPID() == pid,
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
        guard let binding = mixerTask?.binding else { return nil }
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

    var verifiesMatchingNamesOnly: Bool { !nameGoals.isEmpty && mixerTask == nil && plan.steps.isEmpty }

    /// No scalar operation is dispatched: every approved value is read from its
    /// issued object, then corroborated again after the deciding AX read.
    func verifyMatchingNames() async -> SagaJournal.StoredOutcome {
        func refusal(_ hint: String) -> SagaJournal.StoredOutcome {
            SagaWire.storedOutcome(from: SagaWire.scopedStateC(.staleTargetReference, hint: hint,
                extras: ["idempotency_key": plan.idempotencyKey,
                    "plan_id": plan.canonicalPlanID as Any, "digest": plan.canonicalDigest as Any,
                    "write_attempted": false, "writes_performed": 0]))
        }
        guard verifiesMatchingNamesOnly, FeatureFlags.adr004MutationSaga,
              await projectIsCurrent(), await registry.resolveCurrentProject(projectRef) != nil else {
            return refusal("The retained names-only verification or its project custody is unavailable.")
        }
        func independentRead(_ goal: NameGoal) async -> SagaReadEvidence? {
            guard await projectIsCurrent(),
                  let target = await registry.resolve(goal.reference), target.kind == .track,
                  target.physicalTrack?.matches(goal.binding) == true,
                  target.descriptor.trackName.utf8.elementsEqual(goal.name.utf8),
                  let index = goal.binding.currentIndex(),
                  case .success(let name?) = AXValueExtractors.extractTrackNameResult(
                    from: goal.binding.header, runtime: goal.binding.runtime.ax),
                  name.utf8.elementsEqual(goal.name.utf8),
                  goal.binding.currentIndex() == index,
                  let after = await registry.resolve(goal.reference), after.physicalTrack?.matches(goal.binding) == true,
                  await projectIsCurrent() else {
                return nil
            }
            return SagaReadEvidence(readSource: .axTrackName, provenance: .liveIndependent,
                trackIndex: index, projectReference: projectRef.rawValue, field: "name",
                observed: .string(name), sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
        }
        // Bookend the entire approved set, not just each row: a later deciding
        // read must not silently invalidate an earlier row's name or object.
        var before: [SagaReadEvidence] = []
        for goal in nameGoals {
            guard let read = await independentRead(goal) else {
                return refusal("An approved name or its originally issued track could not be independently verified.")
            }
            before.append(read)
        }
        var evidence: [[String: Any]] = []
        for (offset, goal) in nameGoals.enumerated() {
            guard let read = await independentRead(goal),
                  let first = before[offset].observed.stringValue,
                  read.observed.stringValue?.utf8.elementsEqual(first.utf8) == true else {
                return refusal("The approved name set or its held track custody changed between independent readings.")
            }
            guard let data = try? JSONEncoder().encode(read),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let beforeData = try? JSONEncoder().encode(before[offset]),
                  let beforeObject = try? JSONSerialization.jsonObject(with: beforeData) else {
                return refusal("The independent name observation could not be encoded.")
            }
            evidence.append(["target_ref": goal.reference.rawValue, "before": beforeObject, "read": object])
        }
        guard await projectIsCurrent(), await registry.resolveCurrentProject(projectRef) != nil else {
            return refusal("The names-only verification lost its project or operation ownership.")
        }
        let outcome = SagaOutcome(idempotencyKey: plan.idempotencyKey, state: .completed, complete: true,
            journal: [], stateHistory: [.validated, .running, .completed], preflightIssues: [])
        let stored = SagaWire.storedOutcome(plan: plan, outcome: outcome)
        guard var body = decodedJSONObject(stored.body) else { return refusal("The verification receipt is unavailable.") }
        body["write_attempted"] = false
        body["writes_performed"] = 0
        body["goal_evidence"] = evidence
        return .init(body: HonestContract.jsonString(body), isError: stored.isError)
    }

    func perform(_ desired: Bool, runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        guard let task = mixerTask else {
            return .error(HonestContract.encodeStateC(error: .unsupportedState, extras: ["write_attempted": false]))
        }
        let before = task.before, binding = task.binding
        let ownedInverse = ran && ownedVisibility != nil && desired == before
        let expected: Bool?
        let expectedMixer: AXUIElement?
        if !ran { expected = before; expectedMixer = binding.mixer }
        else { expected = ownedVisibility ?? (before == task.desired ? before : nil); expectedMixer = ownedMixer ?? binding.mixer }
        guard let expected, desired == task.desired || desired == before,
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

    static func apply(request: ApplyRequest, dependencies: HandlerDependencies) async -> CallTool.Result {
        let id = request.planID, digest = request.digest, key = request.key
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
                hint: "The exact retained plan, required native goal evidence, or its original project is unavailable; no replacement plan was generated.",
                extras: ["write_attempted": false, "verified": false])
        }
        return await SystemDispatcher.handle(command: "saga_execute", params: [:], router: dependencies.router,
            cache: dependencies.cache, targetRegistry: dependencies.targetRegistry,
            dialogPresent: dependencies.dialogPresent, sagaJournal: dependencies.sagaJournal,
            mutationGate: dependencies.mutationGate, sagaRefreshAfterWrite: {},
            sagaLifecycleDeadline: dependencies.sagaLifecycleDeadline, approvedSessionRepair: approval)
    }
}
