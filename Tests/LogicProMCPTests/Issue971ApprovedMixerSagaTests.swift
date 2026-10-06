@preconcurrency import ApplicationServices
import CryptoKit
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Reuses the scalar setter's actual AX fixture, not an executor that echoes a goal.
@Suite("#971 approved Mixer view through the existing Saga", .serialized)
struct Issue971ApprovedMixerSagaTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
    }

    private actor DelayedSetter {
        private(set) var entered = false
        private var release: CheckedContinuation<Void, Never>?
        private var finished = false
        private var finishWaiter: CheckedContinuation<Void, Never>?
        func block() async {
            entered = true
            await withCheckedContinuation { release = $0 }
        }
        func unblock() { release?.resume(); release = nil }
        func noteFinished() { finished = true; finishWaiter?.resume(); finishWaiter = nil }
        func waitForFinish() async {
            if !finished { await withCheckedContinuation { finishWaiter = $0 } }
        }
    }
    /// A synchronous injected AX read cannot be cancelled while blocked.
    /// The test always releases it, including assertion/require failures.
    private final class BlockedRead: @unchecked Sendable {
        private let condition = NSCondition()
        private var didEnter = false
        private var released = false
        var entered: Bool { condition.withLock { didEnter } }
        func blockOnce() {
            condition.lock()
            defer { condition.unlock() }
            guard !didEnter else { return }
            didEnter = true
            while !released { condition.wait() }
        }
        func unblock() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }
    /// The production setter runs first. Only its actual verified receipt can
    /// consume this post-forward fault; its response is forwarded unchanged.
    private actor AfterVerifiedSetterChannel: Channel {
        nonisolated let id: ChannelID = .accessibility
        let base: AccessibilityChannel
        let journal: SagaJournal
        let cancel: Bool
        let cancelBeforeForward: Bool
        let afterVerified: (@Sendable () async -> Void)?
        let beforeForward: (@Sendable () async -> Void)?
        let afterExecution: (@Sendable () async -> Void)?
        var entered = false
        var verifiedForwards = 0
        var cancelResult: SagaJournal.CancelResult?

        init(base: AccessibilityChannel, journal: SagaJournal, cancel: Bool,
             cancelBeforeForward: Bool = false, afterVerified: (@Sendable () async -> Void)? = nil,
             beforeForward: (@Sendable () async -> Void)? = nil, afterExecution: (@Sendable () async -> Void)? = nil) {
            self.base = base; self.journal = journal; self.cancel = cancel
            self.cancelBeforeForward = cancelBeforeForward; self.afterVerified = afterVerified
            self.beforeForward = beforeForward; self.afterExecution = afterExecution
        }
        func start() async throws { Issue.record("the injected test must not start a channel") }
        func stop() async {}
        func healthCheck() async -> ChannelHealth { await base.healthCheck() }
        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            if operation == "view.set_mixer_visibility", !entered {
                entered = true
                if cancelBeforeForward { cancelResult = await journal.cancel(idempotencyKey: "cancel-approved-view") }
                await beforeForward?()
            }
            let result = await base.execute(operation: operation, params: params)
            if operation == "view.set_mixer_visibility", verifiedForwards == 0,
               case .success(let text) = result, let receipt = sharedJSONObject(text),
               receipt["state"] as? String == "A", receipt["verified"] as? Bool == true,
               receipt["write_attempted"] as? Bool == true {
                verifiedForwards += 1
                await afterVerified?()
                if cancel { cancelResult = await journal.cancel(idempotencyKey: "cancel-approved-view") }
            }
            await afterExecution?()
            return result
        }
    }

    private final class Fixture: @unchecked Sendable {
        let view: Issue969MixerVisibilitySetterTests.Fixture
        let cache: StateCache
        let registry = TargetRegistry()
        let router = ChannelRouter()
        let journal: SagaJournal
        let gate = LogicMutationGate()
        let bundle: URL
        let play: AXUIElement
        let record: AXUIElement
        let dependencies: HandlerDependencies

        init(showing: Bool, cache: StateCache = StateCache(), journal: SagaJournal = SagaJournal()) throws {
            self.cache = cache; self.journal = journal
            view = .init(showing: showing)
            bundle = FileManager.default.temporaryDirectory
                .appendingPathComponent("ApprovedMixer-\(UUID().uuidString).logicx", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            view.builder.setAttribute(view.window, kAXDocumentAttribute as String, bundle.absoluteString)
            let transport = view.builder.element(971_001)
            play = view.builder.element(971_002)
            record = view.builder.element(971_003)
            view.builder.setRole(transport, kAXGroupRole as String)
            view.builder.setAttribute(transport, kAXDescriptionAttribute as String,
                                      AXLocalePolicy.controlBarGroupLabel.canonical)
            for (element, labels) in [(play, AXLocalePolicy.transportPlayControl),
                                       (record, AXLocalePolicy.transportRecordControl)] {
                view.builder.setRole(element, kAXCheckBoxRole as String)
                view.builder.setAttribute(element, kAXDescriptionAttribute as String, labels.canonical)
                view.builder.setAttribute(element, kAXValueAttribute as String, 0)
                view.builder.setChildren(element, [])
            }
            view.builder.setChildren(transport, [play, record])
            view.extraWindowChildren = [transport]
            view.updateVisibility()
            let channel = view.channel()
            dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: channel, cache: cache,
                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                                   keyboardFocus: { .notTextEditing })),
                dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                mutationGate: gate,
                projectLifecycleExecute: { _ in .init(executionError: "forbidden", timedOut: false,
                                                     terminationStatus: 1, stderrOutput: "") },
                liveTrackNames: { [:] }, projectFileReader: .unavailable)
        }

        deinit { try? FileManager.default.removeItem(at: bundle) }

        func call(_ command: String, params: [String: Value], lifecycleDeadline: ContinuousClock.Instant? = nil,
                  afterHandler: (@Sendable () async -> Void)? = nil) async throws -> [String: Any] {
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: command))
            if LogicProServer.strictParamValidationResult(tool: "logic_project", command: command, params: params) != nil {
                Issue.record("the registered request must satisfy its existing strict schema")
                throw CocoaError(.coderInvalidValue)
            }
            let control = LogicProServer.sagaControlBypassesGlobalMutationGate(tool: "logic_project", command: command)
            let execution = LogicProServer.sagaExecutionOwnsLifecycle(tool: "logic_project", command: command)
            let lifecycle = execution ? lifecycleDeadline ?? ContinuousClock.now.advanced(by: .seconds(
                LogicProServer.commandDeadlineSeconds(tool: "logic_project", command: command))) : nil
            let dispatchDependencies = lifecycle.map { dependencies.withSagaLifecycleDeadline($0) } ?? dependencies
            // The server's detached work intentionally drops caller TaskLocals.
            // Reapply only this fixture's explicit configured feature values.
            let configuredTargetRefs = FeatureFlags.adr002TargetRef
            let configuredSaga = FeatureFlags.adr004MutationSaga
            let response = await LogicProServer.runWithDeadline(tool: "logic_project", command: command,
                commandParams: params,
                outerAbsoluteDeadline: lifecycle.map { LogicProServer.sagaOuterAbsoluteDeadline(lifecycleDeadline: $0) },
                mutationGate: control ? nil : gate, externallyManagedMutation: execution) {
                    await FeatureFlags.withAdr002TargetRefForTests(configuredTargetRefs) {
                        await FeatureFlags.withAdr004MutationSagaForTests(configuredSaga) {
                            let result = await handler(dispatchDependencies, params)
                            await afterHandler?()
                            return result
                        }
                    }
                }
            return try #require(sharedJSONObject(sharedToolText(response)))
        }

        func plan(desired: Bool) async throws -> [String: Any] {
            let report = try await call("inspect_session", params: ["domains": .array([.string("strips")])])
            let snapshot = try #require(report["snapshot_id"] as? String)
            let project = try #require(report["project"] as? [String: Any])
            let reference = try #require(project["project_ref"] as? String)
            return try await call("plan_session_repair", params: ["snapshot_id": .string(snapshot),
                "policy": .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(reference), "targets": .array([]), "roles": .array([]),
                    "outputs": .array([]), "presentation": .object(["mixer_visible": .bool(desired)])])])
        }

        func applyParameters(_ plan: [String: Any], key: String) throws -> [String: Value] {
            ["plan_id": .string(try #require(plan["plan_id"] as? String)),
             "digest": .string(try #require(plan["digest"] as? String)),
             "confirmed": .bool(true), "idempotency_key": .string(key)]
        }
    }

    @Test(arguments: [false, true])
    func freshRegisteredCaptureCarriesActualViewAndTransportBaseline(showing: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(showing: showing)
            let body = try await fixture.call("inspect_session", params: ["domains": .array([.string("strips")])])
            let observation = try #require(body["presentation_observation"] as? [String: Any])
            let observedVisibility = try #require(observation["mixer_visible"] as? Bool)
            let visibilityMatches = observedVisibility == showing
            #expect(visibilityMatches)
            let playing = try #require(observation["is_playing"] as? Bool)
            let recording = try #require(observation["is_recording"] as? Bool)
            #expect(!playing)
            #expect(!recording)
            #expect(fixture.view.events.isEmpty)
            let snapshot = try #require(body["snapshot_id"] as? String)
            let retained = try #require(await fixture.cache.retainedInspection(id: snapshot))
            #expect(retained.capture.freshPopulation != nil)
            #expect(retained.capture.project.filePath == fixture.bundle.path)
        }
    }

    @Test(arguments: ["missing_record", "unread_record", "wrong_value", "duplicate_play", "foreign_bar", "depth", "cycle"])
    func consentTransportDoesNotUseMissingAmbiguousOrTruncatedControls(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(showing: false)
            let bar = f.view.builder.element(971_001)
            switch kind {
            case "missing_record": f.view.builder.setChildren(bar, [f.play])
            case "unread_record": f.view.failedMetadata = (f.record, kAXValueAttribute as String)
            case "wrong_value": f.view.builder.setAttribute(f.record, kAXValueAttribute as String, "false")
            case "duplicate_play":
                let duplicate = f.view.builder.element(971_004)
                f.view.builder.setRole(duplicate, kAXCheckBoxRole as String)
                f.view.builder.setAttribute(duplicate, kAXDescriptionAttribute as String, AXLocalePolicy.transportPlayControl.canonical)
                f.view.builder.setAttribute(duplicate, kAXValueAttribute as String, 0)
                f.view.builder.setChildren(duplicate, [])
                f.view.builder.setChildren(bar, [f.play, f.record, duplicate])
            case "foreign_bar":
                let other = f.view.builder.element(971_005)
                f.view.builder.setRole(other, kAXGroupRole as String)
                f.view.builder.setAttribute(other, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
                f.view.builder.setChildren(other, [f.play, f.record])
                f.view.extraWindowChildren.append(other); f.view.updateVisibility()
            case "depth":
                var children = [f.play, f.record]
                for index in 0..<5 {
                    let group = f.view.builder.element(971_100 + index)
                    f.view.builder.setRole(group, kAXGroupRole as String)
                    f.view.builder.setChildren(group, children); children = [group]
                }
                f.view.builder.setChildren(bar, children)
            case "cycle": f.view.builder.setChildren(bar, [f.play, f.record, bar])
            default: Issue.record("unknown fixture variant")
            }
            let body = try await f.call("inspect_session", params: ["domains": .array([.string("strips")])])
            let observation = try #require(body["presentation_observation"] as? [String: Any])
            #expect(observation["is_playing"] is NSNull)
            #expect(observation["is_recording"] is NSNull)
            #expect(f.view.events.isEmpty)
        }
    }

    @Test(arguments: ["play", "record"])
    func observedActiveTransportIsNotDefaultedToStopped(control: String) async throws {
        let f = try Fixture(showing: false)
        f.view.builder.setAttribute(control == "play" ? f.play : f.record, kAXValueAttribute as String, 1)
        let body = try await f.call("inspect_session", params: ["domains": .array([.string("strips")])])
        let observation = try #require(body["presentation_observation"] as? [String: Any])
        let active = try #require(observation[control == "play" ? "is_playing" : "is_recording"] as? Bool)
        #expect(active)
        #expect(f.view.events.isEmpty)
    }

    @Test
    func temporaryRevealDoesNotBecomeTheApprovedBeforeVisibility() async throws {
        let f = try Fixture(showing: false)
        let body = try await f.call("inspect_session", params: ["domains": .array([.string("strips")]), "allow_ui_navigation": .bool(true)])
        let observation = try #require(body["presentation_observation"] as? [String: Any])
        let visible = try #require(observation["mixer_visible"] as? Bool)
        #expect(!visible)
        #expect(!f.view.showing)
        #expect(f.view.events.contains("show_mixer"))
        #expect(f.view.events.contains("hide_mixer"))
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(effects["restoration"] as? String == "restored")
    }

    @Test
    func sameValuedTransportReplacementAfterRestorationDoesNotRetainOldCustody() async throws {
        let f = try Fixture(showing: false)
        let replacementBar = f.view.builder.element(971_201)
        let replacementPlay = f.view.builder.element(971_202)
        let replacementRecord = f.view.builder.element(971_203)
        f.view.builder.setRole(replacementBar, kAXGroupRole as String)
        f.view.builder.setAttribute(replacementBar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
        for (element, labels) in [(replacementPlay, AXLocalePolicy.transportPlayControl),
                                  (replacementRecord, AXLocalePolicy.transportRecordControl)] {
            f.view.builder.setRole(element, kAXCheckBoxRole as String)
            f.view.builder.setAttribute(element, kAXDescriptionAttribute as String, labels.canonical)
            f.view.builder.setAttribute(element, kAXValueAttribute as String, 0)
            f.view.builder.setChildren(element, [])
        }
        f.view.builder.setChildren(replacementBar, [replacementPlay, replacementRecord])
        f.view.afterVisibilityChange = {
            if !f.view.showing {
                f.view.extraWindowChildren = [replacementBar]
                f.view.updateVisibility()
            }
        }
        let body = try await f.call("inspect_session", params: ["domains": .array([.string("strips")]), "allow_ui_navigation": .bool(true)])
        #expect(f.view.extraWindowChildren.count == 1)
        #expect(CFEqual(f.view.extraWindowChildren[0], replacementBar))
        let snapshot = try #require(body["snapshot_id"] as? String)
        let retained = try #require(await f.cache.retainedInspection(id: snapshot))
        #expect(retained.capture.freshPopulation?.presentationBinding == nil)
        let observation = try #require(body["presentation_observation"] as? [String: Any])
        #expect(observation["is_playing"] is NSNull)
        #expect(observation["is_recording"] is NSNull)
        #expect(!f.view.showing)
    }

    @Test(arguments: [false, true], [false, true])
    func retainedCanonicalMixerPlanExecutesThroughTheExistingSaga(initial: Bool, desired: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: initial)
                await f.router.register(f.view.channel())
                let report = try await f.call("inspect_session", params: ["domains": .array([.string("strips")])])
                let snapshot = try #require(report["snapshot_id"] as? String)
                let project = try #require(report["project"] as? [String: Any])
                let reference = try #require(project["project_ref"] as? String)
                let plan = try await f.call("plan_session_repair", params: ["snapshot_id": .string(snapshot),
                    "policy": .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                        "project_ref": .string(reference), "targets": .array([]), "roles": .array([]),
                        "outputs": .array([]), "presentation": .object(["mixer_visible": .bool(desired)])])])
                let planID = try #require(plan["plan_id"] as? String)
                let digest = try #require(plan["digest"] as? String)
                let executable = try #require(plan["executable"] as? Bool)
                #expect(executable)
                #expect(f.view.events.isEmpty)
                let params: [String: Value] = ["plan_id": .string(planID), "digest": .string(digest),
                    "confirmed": .bool(true), "idempotency_key": .string("approved-view")]
                let outcome = try await f.call("apply_session_repair", params: params)
                if outcome["saga_state"] as? String != "completed" {
                    print("approved Mixer actual outcome: \(HonestContract.jsonString(outcome))")
                }
                #expect(outcome["saga_state"] as? String == "completed")
                #expect(outcome["plan_id"] as? String == planID)
                #expect(outcome["digest"] as? String == digest)
                let steps = try #require(outcome["steps"] as? [[String: Any]])
                #expect(steps.count == 1)
                let result = try #require(steps.first?["result"] as? [String: Any])
                #expect(result["state"] as? String == "A")
                let crossed = try #require(result["write_boundary_crossed"] as? Bool)
                let boundaryMatches = crossed == (initial != desired)
                #expect(boundaryMatches)
                let evidence = try #require(steps.first?["evidence"] as? [String: Any])
                let before = try #require(evidence["before_state"] as? [String: Any])
                let verification = try #require(evidence["verification"] as? [String: Any])
                let readback = try #require(verification["readback"] as? [String: Any])
                let observedBefore = try #require(before["observed"] as? Bool)
                let beforeMatches = observedBefore == initial
                #expect(beforeMatches)
                let observedAfter = try #require(readback["observed"] as? Bool)
                let afterMatches = observedAfter == desired
                #expect(afterMatches)
                #expect(before["read_source"] as? String == SagaReadSource.axProjectMixerVisibility.rawValue)
                #expect(readback["read_source"] as? String == SagaReadSource.axProjectMixerVisibility.rawValue)
                #expect(before["project_ref"] as? String == reference)
                #expect(readback["project_ref"] as? String == reference)
                let finalMatches = f.view.showing == desired
                #expect(finalMatches)
                let actions = f.view.events
                if initial == desired { #expect(actions.isEmpty) }
                else { #expect(actions.contains(desired ? "show_mixer" : "hide_mixer")) }
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["saga_state"] as? String == "completed")
                #expect(f.view.events == actions)
                guard case .completed(let stored)? = await f.journal.record(for: "approved-view") else {
                    Issue.record("the existing SagaJournal must own the outcome"); return
                }
                let storedBody = try #require(sharedJSONObject(stored.body))
                #expect(storedBody["plan_id"] as? String == planID)
                #expect(storedBody["digest"] as? String == digest)
                let storedSteps = try #require(storedBody["steps"] as? [[String: Any]])
                #expect(HonestContract.jsonString(["steps": storedSteps]) == HonestContract.jsonString(["steps": steps]))
            }
        }
    }

    @Test(arguments: [false, true])
    func cancellationAfterTheActualVerifiedForwardRestoresOnlyOwnedVisibility(cancel: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal, cancel: cancel)
                await f.router.register(channel)
                let report = try await f.call("inspect_session", params: ["domains": .array([.string("strips")])])
                let snapshot = try #require(report["snapshot_id"] as? String)
                let project = try #require(report["project"] as? [String: Any])
                let reference = try #require(project["project_ref"] as? String)
                let plan = try await f.call("plan_session_repair", params: ["snapshot_id": .string(snapshot),
                    "policy": .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                        "project_ref": .string(reference), "targets": .array([]), "roles": .array([]),
                        "outputs": .array([]), "presentation": .object(["mixer_visible": .bool(true)])])])
                let planID = try #require(plan["plan_id"] as? String)
                let digest = try #require(plan["digest"] as? String)
                let outcome = try await f.call("apply_session_repair", params: ["plan_id": .string(planID),
                    "digest": .string(digest), "confirmed": .bool(true), "idempotency_key": .string("cancel-approved-view")])
                #expect(await channel.verifiedForwards == 1)
                #expect(f.view.events.contains("show_mixer"))
                if cancel {
                    #expect(await channel.cancelResult == .requested)
                    #expect(!f.view.showing)
                    #expect(f.view.events == ["open_view", "show_mixer", "open_view", "hide_mixer"])
                    #expect(outcome["saga_state"] as? String == "fullyCompensated")
                    let compensation = try #require(outcome["compensation"] as? [String: Any])
                    #expect(compensation["status"] as? String == "fully_compensated")
                    let events = f.view.events
                    let replay = try await f.call("apply_session_repair", params: ["plan_id": .string(planID),
                        "digest": .string(digest), "confirmed": .bool(true), "idempotency_key": .string("cancel-approved-view")])
                    #expect(replay["saga_state"] as? String == "fullyCompensated")
                    let duplicate = try #require(replay["duplicate"] as? Bool)
                    #expect(duplicate)
                    #expect(f.view.events == events)
                    guard case .cancelled(let stored, verified: true)? = await f.journal.record(for: "cancel-approved-view") else {
                        Issue.record("owned inverse must be verified before cancellation terminalizes"); return
                    }
                    #expect(sharedJSONObject(stored.body)?["saga_state"] as? String == "fullyCompensated")
                } else {
                    #expect(await channel.cancelResult == nil)
                    #expect(f.view.showing)
                    #expect(outcome["saga_state"] as? String == "completed")
                    #expect(f.view.events == ["open_view", "show_mixer"])
                }
            }
        }
    }

    @Test
    func disabledSagaIsUnavailableInTheActualCanonicalPlanAndApply() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(false) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: true)
                let executable = try #require(plan["executable"] as? Bool)
                #expect(!executable)
                let steps = try #require(plan["steps"] as? [[String: Any]])
                let blockedReasons = try #require(steps.first?["blocked_reasons"] as? [String])
                #expect(blockedReasons.contains("mutation_saga_unavailable"))
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "disabled-view"))
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
                #expect(!f.view.showing)
            }
        }
    }

    @Test(arguments: ["play", "record", "missing_record", "unknown_mixer"])
    func unknownOrActiveRequiredObservablesBlockTheWholePlanWithoutEvents(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                switch kind {
                case "play": f.view.builder.setAttribute(f.play, kAXValueAttribute as String, 1)
                case "record": f.view.builder.setAttribute(f.record, kAXValueAttribute as String, 1)
                case "missing_record": f.view.builder.setChildren(f.view.builder.element(971_001), [f.play])
                case "unknown_mixer":
                    let group = f.view.builder.element(971_301)
                    f.view.builder.setRole(group, kAXGroupRole as String)
                    f.view.extraWindowChildren.append(group); f.view.unreadNestedGroup = group; f.view.updateVisibility()
                default: Issue.record("unknown negative fixture")
                }
                let plan = try await f.plan(desired: true)
                let executable = try #require(plan["executable"] as? Bool)
                #expect(!executable)
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "unavailable-view"))
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
                #expect(!f.view.showing)
            }
        }
    }

    @Test(arguments: ["digest", "confirmation", "document", "cache_project", "visibility", "transport"])
    func approvalDoesNotReplaceMissingConsentOrChangedProjectBeforeState(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: true)
                var params = try f.applyParameters(plan, key: "stale-approval")
                switch kind {
                case "digest": params["digest"] = .string(String(repeating: "0", count: 64))
                case "confirmation": params["confirmed"] = .bool(false)
                case "document": f.view.builder.setAttribute(f.view.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                case "cache_project": await f.cache.updateProject(.init(name: "Other", filePath: "/tmp/Other.logicx"))
                case "visibility": f.view.showing = true; f.view.updateVisibility()
                case "transport": f.view.builder.setAttribute(f.play, kAXValueAttribute as String, 1)
                default: Issue.record("unknown changed authority fixture")
                }
                let outcome = try await f.call("apply_session_repair", params: params)
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test
    func existingJournalIdentityReplaysAfterBaselineTTLAndConflictsWithAnotherPlan() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let clock = Clock()
                let f = try Fixture(showing: false, cache: StateCache(sessionCaptureNow: { clock.now() }))
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: true)
                let params = try f.applyParameters(plan, key: "ttl-view")
                let first = try await f.call("apply_session_repair", params: params)
                #expect(first["saga_state"] as? String == "completed")
                let actions = f.view.events
                clock.advance(.seconds(StateCache.sessionCaptureLifetimeSeconds))
                #expect(await f.cache.retainedRepairPlan(id: plan["plan_id"] as? String ?? "", digest: nil) == nil)
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["saga_state"] as? String == "completed")
                let duplicate = try #require(replay["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.view.events == actions)
                var conflicting = params; conflicting["plan_id"] = .string("plan_different")
                let conflict = try await f.call("apply_session_repair", params: conflicting)
                #expect(conflict["error"] as? String == HonestContract.FailureError.idempotencyKeyConflict.rawValue)
                #expect(f.view.events == actions)
                conflicting = params; conflicting["digest"] = .string(String(repeating: "0", count: 64))
                let digestConflict = try await f.call("apply_session_repair", params: conflicting)
                #expect(digestConflict["error"] as? String == HonestContract.FailureError.idempotencyKeyConflict.rawValue)
                #expect(f.view.events == actions)
            }
        }
    }

    @Test
    func bodyEvictionRetainsCanonicalReplayProtectionWithoutRefiring() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false, journal: SagaJournal(maxRecords: 1))
                await f.router.register(f.view.channel())
                let firstPlan = try await f.plan(desired: true)
                let firstParams = try f.applyParameters(firstPlan, key: "evicted-view")
                #expect(try await f.call("apply_session_repair", params: firstParams)["saga_state"] as? String == "completed")
                let secondPlan = try await f.plan(desired: false)
                #expect(try await f.call("apply_session_repair", params: f.applyParameters(secondPlan, key: "retained-view"))["saga_state"] as? String == "completed")
                #expect(await f.journal.record(for: "evicted-view") == .outcomeEvicted(terminal: .completed))
                let actions = f.view.events
                let replay = try await f.call("apply_session_repair", params: firstParams)
                #expect(replay["error"] as? String == HonestContract.FailureError.sagaOutcomeUnavailable.rawValue)
                #expect(f.view.events == actions)
            }
        }
    }

    @Test
    func evictedCancellationAndANewServerContextCannotRefireTheOldApproval() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false, journal: SagaJournal(maxRecords: 1))
                await f.router.register(AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal, cancel: true))
                let plan = try await f.plan(desired: true)
                let params = try f.applyParameters(plan, key: "cancel-approved-view")
                #expect(try await f.call("apply_session_repair", params: params)["saga_state"] as? String == "fullyCompensated")
                await f.router.register(f.view.channel())
                let newPlan = try await f.plan(desired: true)
                #expect(try await f.call("apply_session_repair", params: f.applyParameters(newPlan, key: "second-view"))["saga_state"] as? String == "completed")
                #expect(await f.journal.record(for: "cancel-approved-view") == .outcomeEvicted(terminal: .cancelled))
                let events = f.view.events
                let evicted = try await f.call("apply_session_repair", params: params)
                #expect(evicted["error"] as? String == HonestContract.FailureError.sagaOutcomeUnavailable.rawValue)
                #expect(f.view.events == events)
                let newContext = try Fixture(showing: false)
                await newContext.router.register(newContext.view.channel())
                let unavailable = try await newContext.call("apply_session_repair", params: params)
                #expect(unavailable["state"] as? String == "C")
                #expect(newContext.view.events.isEmpty)
                #expect(await newContext.journal.record(for: "cancel-approved-view") == nil)
            }
        }
    }

    @Test
    func neverBegunExpiredPlanRefusesRatherThanGeneratingAReplacement() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let clock = Clock()
                let f = try Fixture(showing: false, cache: StateCache(sessionCaptureNow: { clock.now() }))
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: true)
                clock.advance(.seconds(StateCache.sessionCaptureLifetimeSeconds))
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "expired-view"))
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
                #expect(await f.journal.record(for: "expired-view") == nil)
            }
        }
    }

    @Test
    func invalidLaterCanonicalTaskDoesNotDropTheTaskOrRunAnEarlierViewChange() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let first = try await f.plan(desired: true)
                let originalID = try #require(first["plan_id"] as? String)
                let digest = try #require(first["digest"] as? String)
                let retained = try #require(await f.cache.retainedRepairSource(id: originalID, digest: digest))
                let id = "plan_invalid_later_" + UUID().uuidString
                var object = try #require(try JSONDecoder().decode(Value.self, from: Data(retained.0.json.utf8)).objectValue)
                var steps = try #require(object["steps"]?.arrayValue)
                steps.append(.object(["kind": .string("preserve_coupled_names"), "blocked_reasons": .array([])]))
                object["steps"] = .array(steps); object["preview"] = .array(steps)
                object.removeValue(forKey: "plan_id"); object.removeValue(forKey: "digest")
                let raw = try encodeJSONStrict(Value.object(object), compact: true)
                let changedDigest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
                object["plan_id"] = .string(id); object["digest"] = .string(changedDigest)
                let body = try encodeJSONStrict(Value.object(object), compact: true)
                // Seed the existing native retention seam, not a caller-provided
                // JSON authority token. The whole retained task array must fail.
                #expect(await f.cache.retainRepairPlan(.init(id: id, digest: changedDigest, json: body),
                    snapshotID: retained.1.capture.captureID))
                let changedSource = try #require(await f.cache.retainedRepairSource(id: id, digest: changedDigest))
                #expect(try JSONDecoder().decode(Value.self, from: Data(changedSource.0.json.utf8)).objectValue?["steps"]?.arrayValue?.count == 2)
                let outcome = try await f.call("apply_session_repair", params: ["plan_id": .string(id),
                    "digest": .string(changedDigest), "confirmed": .bool(true), "idempotency_key": .string("invalid-later-view")])
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
                #expect(await f.journal.record(for: "invalid-later-view") == nil)
            }
        }
    }

    @Test
    func journalCancellationBeforeTheForwardSetterSendsNoAction() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal,
                    cancel: false, cancelBeforeForward: true)
                await f.router.register(channel)
                let plan = try await f.plan(desired: true)
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "cancel-approved-view"))
                #expect(await channel.entered)
                #expect(await channel.cancelResult == .requested)
                #expect(await channel.verifiedForwards == 0)
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
                #expect(!f.view.showing)
            }
        }
    }

    @Test(arguments: ["external_visibility", "replacement_mixer", "document", "readback", "task_cancel"])
    func cancellationNeverOverwritesNewerStateOrActsAfterCustodyLoss(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let replacement = f.view.builder.element(971_401)
                f.view.builder.setRole(replacement, kAXGroupRole as String)
                f.view.builder.setAttribute(replacement, kAXIdentifierAttribute as String, "Mixer")
                f.view.builder.setChildren(replacement, [])
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal, cancel: true,
                    afterVerified: {
                        switch kind {
                        case "external_visibility": f.view.showing = false; f.view.updateVisibility()
                        case "replacement_mixer": f.view.builder.setChildren(f.view.window, f.view.extraWindowChildren + [f.view.rail, replacement])
                        case "document": f.view.builder.setAttribute(f.view.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                        case "readback": f.view.unknownWindowChildren = true
                        case "task_cancel": withUnsafeCurrentTask { $0?.cancel() }
                        default: Issue.record("unknown post-forward fixture")
                        }
                    })
                await f.router.register(channel)
                let plan = try await f.plan(desired: true)
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "cancel-approved-view"))
                #expect(await channel.verifiedForwards == 1)
                #expect(await channel.cancelResult == .requested)
                #expect(f.view.events == ["open_view", "show_mixer"])
                #expect(outcome["state"] as? String != "A")
                if kind == "external_visibility" { #expect(!f.view.showing) }
                else { #expect(f.view.showing) }
                if kind == "replacement_mixer" {
                    let children = try AXHelpers.childrenResult(f.view.window, runtime: f.view.builder.makeAXRuntime()).get()
                    #expect(children.contains { CFEqual($0, replacement) })
                    #expect(!children.contains { CFEqual($0, f.view.mixer) })
                }
            }
        }
    }

    @Test
    func cancellationAtTheDecisiveLeafReadPreventsTheLeafPress() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: true)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: false)
                f.view.afterDecisiveMixerRead = { withUnsafeCurrentTask { $0?.cancel() } }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "leaf-cancel-view"))
                #expect(f.view.afterDecisiveMixerRead == nil)
                #expect(f.view.events == ["open_view"])
                #expect(f.view.showing)
                #expect(outcome["state"] as? String == "B")
            }
        }
    }

    @Test
    func anotherMutationGateOwnerBlocksAllApprovedViewEvents() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: true)
                let claim = try #require(f.gate.tryAcquire(operation: "other-operation"))
                defer { f.gate.release(claim) }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "gate-view"))
                #expect(outcome["error"] as? String == HonestContract.FailureError.mutatingOperationInProgress.rawValue)
                #expect(f.view.events.isEmpty)
                #expect(f.gate.stillOwns(claim))
            }
        }
    }

    @Test
    func replacingTheApprovedTransportControlsWithStoppedLookalikesCannotAuthorizeAWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: true)
                let bar = f.view.builder.element(971_501)
                f.view.builder.setRole(bar, kAXGroupRole as String)
                f.view.builder.setAttribute(bar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
                var controls: [AXUIElement] = []
                for (index, labels) in [AXLocalePolicy.transportPlayControl, AXLocalePolicy.transportRecordControl].enumerated() {
                    let control = f.view.builder.element(971_502 + index)
                    f.view.builder.setRole(control, kAXCheckBoxRole as String)
                    f.view.builder.setAttribute(control, kAXDescriptionAttribute as String, labels.canonical)
                    f.view.builder.setAttribute(control, kAXValueAttribute as String, 0)
                    f.view.builder.setChildren(control, []); controls.append(control)
                }
                f.view.builder.setChildren(bar, controls)
                f.view.extraWindowChildren = [bar]; f.view.updateVisibility()
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "replaced-controls-view"))
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
                #expect(!f.view.showing)
            }
        }
    }

    @Test(arguments: ["before_forward", "after_verified_forward"])
    func theSharedDeadlineRetainsItsOutcomeAndPreventsLateActionsAfterOwnershipTransfers(phase: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let delayed = DelayedSetter()
                let before: (@Sendable () async -> Void)?
                let after: (@Sendable () async -> Void)?
                if phase == "before_forward" {
                    before = { await delayed.block() }; after = nil
                } else {
                    before = nil; after = { await delayed.block() }
                }
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal, cancel: false,
                    afterVerified: after, beforeForward: before, afterExecution: { await delayed.noteFinished() })
                await f.router.register(channel)
                let plan = try await f.plan(desired: true)
                let params = try f.applyParameters(plan, key: "late-view")
                let outcome = try await f.call("apply_session_repair", params: params,
                    lifecycleDeadline: .now.advanced(by: .seconds(1)))
                #expect(outcome["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                let entered = await delayed.entered
                #expect(entered, "the actual setter must have reached the controlled delayed phase")
                guard entered else { return }
                // Exercise the existing time-injected grace reclamation; no sleep,
                // timeout enlargement, new gate, or callback claims ownership.
                let successor = try #require(f.gate.tryAcquire(operation: "successor-operation", now: .distantFuture))
                defer { f.gate.release(successor) }
                let eventsAtDeadline = f.view.events
                if phase == "before_forward" { #expect(eventsAtDeadline.isEmpty) }
                else { #expect(eventsAtDeadline == ["open_view", "show_mixer"]) }
                await delayed.unblock()
                await delayed.waitForFinish()
                #expect(f.view.events == eventsAtDeadline)
                #expect(f.gate.stillOwns(successor))
                guard case .completed(let stored)? = await f.journal.record(for: "late-view") else {
                    Issue.record("the shared lifecycle timeout must remain the journal winner"); return
                }
                let terminal = try #require(sharedJSONObject(stored.body))
                #expect(terminal["error"] as? String == outcome["error"] as? String)
                let terminalVerified = try #require(terminal["verified"] as? Bool)
                let verificationMatches = terminalVerified == verified
                #expect(verificationMatches)
                let stopped = try #require(terminal["underlying_operation_stopped"] as? Bool)
                #expect(!stopped)
            }
        }
    }

    @Test
    func anAvailabilityReadWedgeUsesTheSameTerminalJournalAndOwnershipDeadline() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: true)
                let params = try f.applyParameters(plan, key: "availability-wedge")
                let blocked = BlockedRead()
                let finished = DelayedSetter()
                defer { blocked.unblock() }
                f.view.attributeReadObserver = { element, attribute in
                    if CFEqual(element, f.play), attribute == kAXValueAttribute as String,
                       f.gate.currentOperation() != nil {
                        blocked.blockOnce()
                    }
                }
                let outcome = try await f.call("apply_session_repair", params: params,
                    lifecycleDeadline: .now.advanced(by: .seconds(1)),
                    afterHandler: { await finished.noteFinished() })
                #expect(blocked.entered, "the actual post-claim availability read must consume the barrier")
                #expect(outcome["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
                #expect(f.view.events.isEmpty)
                if case .completed(let stored)? = await f.journal.record(for: "availability-wedge") {
                    let body = try #require(sharedJSONObject(stored.body))
                    #expect(body["error"] as? String == outcome["error"] as? String)
                } else {
                    Issue.record("the public deadline must already have terminalized the claimed journal")
                }
                let successor = f.gate.tryAcquire(operation: "availability-successor", now: .distantFuture)
                #expect(successor != nil, "the timed-out availability owner must use the existing grace-reclaim disposition")
                defer { if let successor { f.gate.release(successor) } }
                blocked.unblock()
                await finished.waitForFinish()
                #expect(f.view.events.isEmpty)
                if let successor { #expect(f.gate.stillOwns(successor)) }
                if case .completed(let stored)? = await f.journal.record(for: "availability-wedge") {
                    let body = try #require(sharedJSONObject(stored.body))
                    #expect(body["error"] as? String == outcome["error"] as? String)
                } else {
                    Issue.record("late availability completion must not replace or reopen the terminal outcome")
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func genericSagaWireCannotDeserializeCanonicalViewApproval(includeCanonicalMetadata: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: true)
                let steps = try #require(plan["steps"] as? [[String: Any]])
                let projectRef = try #require(steps.first?["target_ref"] as? String)
                var params: [String: Value] = ["idempotency_key": .string("generic-view"),
                    "steps": .array([.object(["operation_id": .string(OperationID.navigateToggleView.rawValue),
                        "target_ref": .string(projectRef), "params": .object(["view": .string("mixer"), "visible": .bool(true)]),
                        "expected_inverse": .object(["operation_id": .string(OperationID.navigateToggleView.rawValue),
                            "value_parameter": .string("visible")])])])]
                if includeCanonicalMetadata {
                    params["canonical_plan_id"] = .string(try #require(plan["plan_id"] as? String))
                    params["canonical_digest"] = .string(try #require(plan["digest"] as? String))
                }
                let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_system", command: "saga_execute"))
                let requestParams = params
                let lifecycle = ContinuousClock.now.advanced(by: .seconds(LogicProServer.commandDeadlineSeconds(tool: "logic_system", command: "saga_execute")))
                let response = await LogicProServer.runWithDeadline(tool: "logic_system", command: "saga_execute", commandParams: params,
                    outerAbsoluteDeadline: LogicProServer.sagaOuterAbsoluteDeadline(lifecycleDeadline: lifecycle),
                    externallyManagedMutation: LogicProServer.sagaExecutionOwnsLifecycle(tool: "logic_system", command: "saga_execute")) {
                        await FeatureFlags.withAdr002TargetRefForTests(true) {
                            await FeatureFlags.withAdr004MutationSagaForTests(true) {
                                await handler(f.dependencies.withSagaLifecycleDeadline(lifecycle), requestParams)
                            }
                        }
                    }
                let outcome = try #require(sharedJSONObject(sharedToolText(response)))
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
                #expect(!f.view.showing)
            }
        }
    }

    @Test
    func callerSuppliedPlanOrObservationJSONCannotReplaceTheRetainedNativeSource() async throws {
        let f = try Fixture(showing: false)
        let invalid = try #require(LogicProServer.strictParamValidationResult(tool: "logic_project", command: "apply_session_repair",
            params: ["plan_id": .string("plan_unknown"), "digest": .string(String(repeating: "0", count: 64)),
                "confirmed": .bool(true), "idempotency_key": .string("json-view"),
                "plan": .object(["executable": .bool(true)]), "presentation_observation": .object(["mixer_visible": .bool(false)])]))
        #expect(sharedJSONObject(sharedToolText(invalid))?["state"] as? String == "C")
        let unavailable = try await f.call("apply_session_repair", params: ["plan_id": .string("plan_unknown"),
            "digest": .string(String(repeating: "0", count: 64)), "confirmed": .bool(true), "idempotency_key": .string("json-view")])
        #expect(unavailable["state"] as? String == "C")
        #expect(f.view.events.isEmpty)
        #expect(await f.journal.record(for: "json-view") == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func theApprovedFacadeOracleDescribesItsActualStoredOutcome(initial: Bool, desired: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: initial)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: desired)
                let body = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "oracle-approved-view"))
                let oracle = try #require(SemanticOracleTable.byOperationID[.projectApplySessionRepair])
                let readback = Data("{}".utf8)
                let accepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: body), readbackData: readback))
                #expect(accepted)
                for key in ["plan_id", "digest", "idempotency_key", "steps", "state_history", "saga_state", "journal_scope", "state", "verified"] {
                    var missing = body
                    missing.removeValue(forKey: key)
                    let missingAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: missing), readbackData: readback))
                    #expect(!missingAccepted, "a missing \(key) cannot be credited")
                }
                for (key, value) in [("plan_id", 1 as Any), ("digest", false as Any), ("steps", [] as Any),
                                     ("saga_state", "inProgress" as Any), ("state", "B" as Any), ("state", "C" as Any)] {
                    var mutant = body
                    mutant[key] = value
                    let mutantAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: mutant), readbackData: readback))
                    #expect(!mutantAccepted, "invalid \(key) cannot be credited")
                }
            }
        }
    }
}
