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

    final class Fixture: @unchecked Sendable {
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

        init(showing: Bool, cache: StateCache = StateCache(), journal: SagaJournal = SagaJournal(),
             fileReader: (@Sendable (Issue969MixerVisibilitySetterTests.Fixture) -> LogicProjectFileReader.Runtime)? = nil) throws {
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
            let projectFileReader = fileReader?(view) ?? .unavailable
            dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: channel, cache: cache,
                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: projectFileReader,
                                   keyboardFocus: { .notTextEditing })),
                dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                mutationGate: gate,
                projectLifecycleExecute: { _ in .init(executionError: "forbidden", timedOut: false,
                                                     terminationStatus: 1, stderrOutput: "") },
                liveTrackNames: { [:] }, projectFileReader: projectFileReader)
        }

        deinit { try? FileManager.default.removeItem(at: bundle) }

        func call(_ command: String, params: [String: Value], lifecycleDeadline: ContinuousClock.Instant? = nil,
                  afterHandler: (@Sendable () async -> Void)? = nil) async throws -> [String: Any] {
            let result = try await callResult(command, params: params, lifecycleDeadline: lifecycleDeadline,
                                              afterHandler: afterHandler)
            return try #require(sharedJSONObject(sharedToolText(result)))
        }

        func callResult(_ command: String, params: [String: Value], lifecycleDeadline: ContinuousClock.Instant? = nil,
                        afterHandler: (@Sendable () async -> Void)? = nil) async throws -> CallTool.Result {
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
            return response
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

        func installNameHeaders(_ names: [String]) -> [AXUIElement] {
            let headers = names.enumerated().map { index, name in
                let header = view.builder.element(971_900 + index)
                view.builder.setRole(header, kAXLayoutItemRole as String)
                view.builder.setAttribute(header, kAXTitleAttribute as String, name)
                view.builder.setAttribute(header, kAXSelectedAttribute as String, false)
                view.builder.setChildren(header, [])
                return header
            }
            view.builder.setChildren(view.rail, headers)
            return headers
        }

        func namesPlan(_ names: [String], approvedNames: [String]? = nil,
                       policyExtras: [String: Value] = [:], includeMixerObservation: Bool = true) async throws -> [String: Any] {
            // A composed Mixer goal needs a guarded presentation observation;
            // the requested domains alone neither prove nor disprove visibility.
            let hasMixerGoal = policyExtras["presentation"]?.objectValue?["mixer_visible"]?.boolValue != nil
            let domains: [Value] = hasMixerGoal && includeMixerObservation
                ? [.string("tracks"), .string("strips")] : [.string("tracks")]
            let report = try await call("inspect_session", params: ["domains": .array(domains)])
            let snapshot = try #require(report["snapshot_id"] as? String)
            let rows = try #require((report["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
            #expect(rows.count == names.count)
            let project = try #require(report["project"] as? [String: Any])
            let projectRef = try #require(project["project_ref"] as? String)
            let targets = try rows.enumerated().map { index, row -> Value in
                let observed = try #require(row["name"] as? String)
                #expect(observed.utf8.elementsEqual(names[index].utf8))
                return .object(["handle": .string("t\(index)"),
                    "track_ref": .string(try #require(row["track_ref"] as? String))])
            }
            let approved: [Value] = (approvedNames ?? names).enumerated().map { index, name in
                .object(["target": .string("t\(index)"), "name": .string(name)])
            }
            var policy: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                "project_ref": .string(projectRef), "targets": .array(targets)]
            policy.merge(policyExtras) { _, new in new }
            return try await call("plan_session_repair", params: ["snapshot_id": .string(snapshot),
                "policy": .object(policy), "names": .array(approved)])
        }
    }

    @Test
    func approvedMatchingNamesAreIndependentlyVerifiedWithoutWriting() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "  e\u{301}, \"Lead\"  "]
                let headers = names.enumerated().map { index, name in
                    let header = f.view.builder.element(971_800 + index)
                    f.view.builder.setRole(header, kAXLayoutItemRole as String)
                    f.view.builder.setAttribute(header, kAXTitleAttribute as String, name)
                    f.view.builder.setAttribute(header, kAXSelectedAttribute as String, false)
                    f.view.builder.setChildren(header, [])
                    return header
                }
                f.view.builder.setChildren(f.view.rail, headers)
                let report = try await f.call("inspect_session", params: ["domains": .array([.string("tracks")])])
                let section = try #require(report["tracks"] as? [String: Any])
                let rows = try #require(section["rows"] as? [[String: Any]])
                #expect(rows.count == names.count)
                let refs = try rows.enumerated().map { index, row in
                    let observed = try #require(row["name"] as? String)
                    #expect(observed.utf8.elementsEqual(names[index].utf8))
                    return try #require(row["track_ref"] as? String)
                }
                let snapshot = try #require(report["snapshot_id"] as? String)
                let retained = try #require(await f.cache.retainedInspection(id: snapshot))
                #expect(retained.capture.tracks.allSatisfy { $0.physicalBinding != nil })
                let project = try #require(report["project"] as? [String: Any])
                let projectRef = try #require(project["project_ref"] as? String)
                let targets: [Value] = refs.enumerated().map { index, ref in
                    .object(["handle": .string("t\(index)"), "track_ref": .string(ref)])
                }
                let approved: [Value] = names.enumerated().map { index, name in
                    .object(["target": .string("t\(index)"), "name": .string(name)])
                }
                let plan = try await f.call("plan_session_repair", params: ["snapshot_id": .string(snapshot),
                    "policy": .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                        "project_ref": .string(projectRef), "targets": .array(targets)]),
                    "names": .array(approved)])
                let executable = try #require(plan["executable"] as? Bool)
                #expect(executable)
                let plannedSteps = try #require(plan["steps"] as? [Any])
                #expect(plannedSteps.isEmpty)
                #expect((plan["unchanged_tasks"] as? [String])?.count == names.count)
                let reads = headers.map { _ in DecidingMixerReplacement() }
                f.view.attributeReadObserver = { element, attribute in
                    if let index = headers.firstIndex(where: { CFEqual($0, element) }), attribute == kAXTitleAttribute as String {
                        reads[index].originalDecidingReads += 1
                    }
                }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "matching-names"))
                #expect(outcome["saga_state"] as? String == "completed")
                let verified = outcome["verified"] as? Bool ?? false
                #expect(verified)
                for counter in reads { #expect(counter.originalDecidingReads > 0) }
                #expect(f.view.events.isEmpty)
                let attempted = try #require(outcome["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(outcome["writes_performed"] as? Int == 0)
                let evidence = try #require(outcome["goal_evidence"] as? [[String: Any]])
                #expect(evidence.count == names.count)
                for (index, item) in evidence.enumerated() {
                    #expect(item["target_ref"] as? String == refs[index])
                    let read = try #require(item["read"] as? [String: Any])
                    #expect(read["read_source"] as? String == "ax_track_name")
                    #expect(read["provenance"] as? String == "live_independent")
                    let observed = try #require(read["observed"] as? String)
                    #expect(observed.utf8.elementsEqual(names[index].utf8))
                }
                guard case .completed(let stored)? = await f.journal.record(for: "matching-names") else {
                    Issue.record("the verified zero-write result must use the existing journal")
                    return
                }
                #expect(sharedJSONObject(stored.body)?["saga_state"] as? String == "completed")
            }
        }
    }

    @Test
    func namesOnlyOracleDescribesActualZeroWriteGoalEvidence() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                f.installNameHeaders(["Bass", "e\u{301}"])
                let plan = try await f.namesPlan(["Bass", "e\u{301}"])
                let body = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "oracle-matching-names"))
                let oracle = try #require(SemanticOracleTable.byOperationID[.projectApplySessionRepair])
                let readback = Data("{}".utf8)
                let accepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: body), readbackData: readback))
                #expect(accepted)
                #expect(f.view.events.isEmpty)
                for key in ["steps", "goal_evidence", "write_attempted", "writes_performed", "verified", "state", "digest"] {
                    var missing = body
                    missing.removeValue(forKey: key)
                    let missingAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: missing), readbackData: readback))
                    #expect(!missingAccepted, "missing \(key) is not a verified zero-write goal")
                }
                for (key, value) in [("goal_evidence", [] as Any), ("write_attempted", true as Any),
                                     ("write_attempted", 0 as Any), ("writes_performed", 1 as Any),
                                     ("state", "B" as Any), ("state", "C" as Any)] {
                    var mutant = body
                    mutant[key] = value
                    let mutantAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: mutant), readbackData: readback))
                    #expect(!mutantAccepted)
                }
                for (key, value) in [("read_source", "cached"), ("provenance", "cached"),
                                     ("field", "volume"), ("observed", "Different")] {
                    var mutant = body
                    var evidence = try #require(body["goal_evidence"] as? [[String: Any]])
                    var read = try #require(evidence[0]["read"] as? [String: Any])
                    read[key] = value
                    evidence[0]["read"] = read
                    mutant["goal_evidence"] = evidence
                    let mutantAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: mutant), readbackData: readback))
                    #expect(!mutantAccepted)
                }
            }
        }
    }

    @Test
    func endedNameExposureBlocksPlanningWithoutNewHostReads() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                _ = f.installNameHeaders(["Bass"])
                let report = try await f.call("inspect_session", params: ["domains": .array([.string("tracks")])])
                let snapshot = try #require(report["snapshot_id"] as? String)
                let inspection = try #require(await f.cache.retainedInspection(id: snapshot))
                let original = inspection.capture
                var rows = original.tracks
                let binding = try #require(rows.first?.physicalBinding)
                let reference = try #require(original.issued?.byRow.first ?? nil)
                guard case .issued(let project)? = original.projectIssuance else {
                    Issue.record("fixture must issue its project reference"); return
                }
                // A process-local scope is controlled here, not a claim that a native disclosure
                // was acquired. Its terminal fact can be read without probing AX during planning.
                let scope = AXTrackBinding.Exposure(header: binding.header,
                    disclosure: f.view.builder.element(971_990), runtime: binding.runtime)
                rows[0].physicalBinding = .init(window: binding.window, header: binding.header,
                    document: binding.document, runtime: binding.runtime, exposure: scope)
                let captured = SessionPopulationObservation.Capture(before: original.before, after: original.after,
                    projectEpoch: original.projectEpoch, project: original.project, tracks: rows,
                    tracksFetchedAt: original.tracksFetchedAt, channelStrips: original.channelStrips,
                    mixerFetchedAt: original.mixerFetchedAt, fileTrackCount: original.fileTrackCount,
                    projectFileNotBound: original.projectFileNotBound, requestedProjectMatches: original.requestedProjectMatches,
                    referencesEnabled: original.referencesEnabled, targetSnapshot: original.targetSnapshot,
                    issued: original.issued, projectIssuance: original.projectIssuance,
                    beganAt: original.beganAt, endedAt: original.endedAt, captureID: original.captureID,
                    freshPopulation: original.freshPopulation, mixerReferences: original.mixerReferences)
                let raw: [String: Value] = ["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(project.rawValue), "targets": .array([.object([
                        "handle": .string("bass"), "track_ref": .string(reference.rawValue)])])]
                guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy(raw) else {
                    Issue.record("valid fixture policy rejected"); return
                }
                let names = [ProjectSessionAudit.ApprovedName(target: "bass", name: "Bass")]
                f.view.attributeReadObserver = { _, _ in Issue.record("planning must not read the host") }
                func build() throws -> [String: Value] {
                    let plan = try ProjectSessionAudit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw),
                        names: names, capture: captured, request: inspection.request, snapshotCurrent: true)
                    return try #require(JSONDecoder().decode(Value.self, from: Data(plan.json.utf8)).objectValue)
                }
                let before = try build()
                let available = try #require(before["executable"]?.boolValue as Bool?)
                #expect(available)
                scope.end()
                let after = try build()
                let endedAvailable = try #require(after["executable"]?.boolValue as Bool?)
                #expect(!endedAvailable)
                #expect(after["unchanged_tasks"] == before["unchanged_tasks"])
                #expect(after["approved_names"] == before["approved_names"])
                #expect(after["steps"] == before["steps"])
                #expect(after["digest"] != before["digest"])
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test
    func namesOnlyOracleRejectsCorruptionInEveryObservedGoal() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                f.installNameHeaders(["Bass", "Piano"])
                let plan = try await f.namesPlan(["Bass", "Piano"])
                let body = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "oracle-every-matching-name"))
                let evidence = try #require(body["goal_evidence"] as? [[String: Any]])
                #expect(evidence.count == 2)
                let oracle = try #require(SemanticOracleTable.byOperationID[.projectApplySessionRepair])
                for index in evidence.indices {
                    for (key, value) in [("read_source", "cached"), ("provenance", "cached"), ("observed", "Different")] {
                        var mutant = body
                        var rows = evidence
                        var read = try #require(rows[index]["read"] as? [String: Any])
                        read[key] = value
                        rows[index]["read"] = read
                        mutant["goal_evidence"] = rows
                        let accepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: mutant), readbackData: Data("{}".utf8)))
                        #expect(!accepted, "corrupted \(key) in goal \(index) cannot be credited")
                    }
                }
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test(arguments: [0, 1], ["nfd", "nfc"])
    func namesOnlyOracleRequiresExactUTF8InEitherGoal(row: Int, encoding: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let original = encoding == "nfd" ? "e\u{301}" : "\u{e9}"
                let equivalent = encoding == "nfd" ? "\u{e9}" : "e\u{301}"
                #expect(original == equivalent)
                #expect(!original.utf8.elementsEqual(equivalent.utf8))
                var names = ["Bass", "Piano"]
                names[row] = original
                let f = try Fixture(showing: false)
                f.installNameHeaders(names)
                let plan = try await f.namesPlan(names)
                let body = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "oracle-name-bytes"))
                let rows = try #require(body["goal_evidence"] as? [[String: Any]])
                #expect(rows.count == 2)
                let before = try #require(rows[row]["before"] as? [String: Any])
                let read = try #require(rows[row]["read"] as? [String: Any])
                #expect((try #require(before["observed"] as? String)).utf8.elementsEqual(original.utf8))
                #expect((try #require(read["observed"] as? String)).utf8.elementsEqual(original.utf8))
                let oracle = try #require(SemanticOracleTable.byOperationID[.projectApplySessionRepair])
                let readback = Data("{}".utf8)
                let identicalAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: body), readbackData: readback))
                #expect(identicalAccepted)
                var alteredRows = rows
                var alteredRead = read
                alteredRead["observed"] = equivalent
                alteredRows[row]["read"] = alteredRead
                var altered = body
                altered["goal_evidence"] = alteredRows
                let changedBytesAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: altered), readbackData: readback))
                #expect(!changedBytesAccepted)
                for side in ["before", "read"] {
                    for invalid: Any? in [nil, 1, false, NSNull()] {
                        var malformedRows = rows
                        var evidence = try #require(rows[row][side] as? [String: Any])
                        evidence["observed"] = invalid
                        malformedRows[row][side] = evidence
                        var malformed = body
                        malformed["goal_evidence"] = malformedRows
                        let malformedAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: malformed), readbackData: readback))
                        #expect(!malformedAccepted)
                    }
                }
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test
    func disabledSagaBlocksNamesOnlyPlanningAndApply() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(false) {
                let f = try Fixture(showing: false)
                f.installNameHeaders(["Bass", "Piano"])
                let plan = try await f.namesPlan(["Bass", "Piano"])
                let executable = try #require(plan["executable"] as? Bool)
                #expect(!executable)
                let reasons = try #require(plan["reasons"] as? [String])
                #expect(reasons.contains("mutation_saga_unavailable"))
                let steps = try #require(plan["steps"] as? [Any])
                #expect(steps.isEmpty)
                #expect((plan["unchanged_tasks"] as? [String])?.count == 2)
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "disabled-matching-names"))
                #expect(outcome["state"] as? String == "C")
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test(arguments: ["second_name", "unicode_bytes", "replacement", "document", "unread", "last_read_document"])
    func namesOnlyVerificationRefusesChangedHeldEvidenceWithoutWriting(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "e\u{301}"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names)
                let hook = DecidingMixerReplacement()
                switch kind {
                case "second_name": f.view.builder.setAttribute(headers[1], kAXTitleAttribute as String, "User edit")
                case "unicode_bytes": f.view.builder.setAttribute(headers[1], kAXTitleAttribute as String, "é")
                case "replacement":
                    let replacement = f.view.builder.element(971_950)
                    f.view.builder.setRole(replacement, kAXLayoutItemRole as String)
                    f.view.builder.setAttribute(replacement, kAXTitleAttribute as String, names[1])
                    f.view.builder.setAttribute(replacement, kAXSelectedAttribute as String, false)
                    f.view.builder.setChildren(replacement, [])
                    f.view.builder.setChildren(f.view.rail, [headers[0], replacement])
                case "document": f.view.builder.setAttribute(f.view.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                case "unread": f.view.failedMetadata = (headers[1], kAXTitleAttribute as String)
                case "last_read_document":
                    f.view.attributeReadObserver = { element, attribute in
                        if CFEqual(element, headers[1]), attribute == kAXTitleAttribute as String, !hook.replaced {
                            hook.replaced = true
                            f.view.builder.setAttribute(f.view.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                        }
                    }
                default: Issue.record("unknown name observation fault")
                }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "changed-names"))
                if kind == "last_read_document" { #expect(hook.replaced) }
                #expect(outcome["state"] as? String == "C")
                let attempted = try #require(outcome["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(outcome["writes_performed"] as? Int == 0)
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                #expect(f.view.events.isEmpty)
                guard case .completed(let stored)? = await f.journal.record(for: "changed-names") else {
                    Issue.record("the zero-write refusal must terminalize the existing claim"); return
                }
                #expect(sharedJSONObject(stored.body)?["state"] as? String == "C")
            }
        }
    }

    @Test(arguments: ["raw_name", "physical_header"])
    func aLaterNameReadCannotCertifyAnEarlierChangedTrack(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names)
                let hook = DecidingMixerReplacement()
                f.view.attributeReadObserver = { element, attribute in
                    if CFEqual(element, headers[1]), attribute == kAXTitleAttribute as String, !hook.replaced {
                        hook.replaced = true
                        if kind == "raw_name" {
                            f.view.builder.setAttribute(headers[0], kAXTitleAttribute as String, "User edit")
                        } else {
                            let replacement = f.view.builder.element(971_951)
                            f.view.builder.setRole(replacement, kAXLayoutItemRole as String)
                            f.view.builder.setAttribute(replacement, kAXTitleAttribute as String, names[0])
                            f.view.builder.setAttribute(replacement, kAXSelectedAttribute as String, false)
                            f.view.builder.setChildren(replacement, [])
                            f.view.builder.setChildren(f.view.rail, [replacement, headers[1]])
                        }
                    }
                    if CFEqual(element, headers[0]), attribute == kAXTitleAttribute as String {
                        hook.originalDecidingReads += 1
                    }
                }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "inter-goal-edit"))
                #expect(hook.replaced)
                #expect(hook.originalDecidingReads > 0)
                #expect(outcome["state"] as? String == "C")
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                let attempted = try #require(outcome["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(outcome["writes_performed"] as? Int == 0)
                #expect(f.view.events.isEmpty)
                let project = await f.cache.getProject()
                #expect(project.filePath == f.bundle.path)
                #expect(f.view.builder.attributeValue(f.view.window, kAXDocumentAttribute as String) as? String == f.bundle.absoluteString)
                guard case .completed(let stored)? = await f.journal.record(for: "inter-goal-edit") else {
                    Issue.record("the independently refused goal must have a terminal journal result"); return
                }
                #expect(sharedJSONObject(stored.body)?["state"] as? String == "C")
            }
        }
    }

    @Test
    func namesVerificationCancellationDuringTheDecidingReadIsTerminalAndReplayable() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names)
                let blocked = BlockedRead()
                defer { blocked.unblock() }
                let hook = DecidingMixerReplacement()
                f.view.attributeReadObserver = { element, attribute in
                    if CFEqual(element, headers[0]), attribute == kAXTitleAttribute as String, !hook.armed {
                        hook.armed = true
                        Task {
                            if await f.journal.cancel(idempotencyKey: "cancel-names") == .requested { hook.replaced = true }
                            blocked.unblock()
                        }
                        blocked.blockOnce()
                    }
                }
                let params = try f.applyParameters(plan, key: "cancel-names")
                let outcome = try await f.call("apply_session_repair", params: params,
                    lifecycleDeadline: .now.advanced(by: .seconds(1)))
                #expect(hook.armed)
                #expect(hook.replaced)
                #expect(blocked.entered)
                #expect(outcome["state"] as? String == "C")
                let attempted = try #require(outcome["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.view.events.isEmpty)
                guard case .cancelled(let stored, let verified)? = await f.journal.record(for: "cancel-names") else {
                    Issue.record("no-write cancellation must be terminal, not pending"); return
                }
                #expect(verified)
                #expect(sharedJSONObject(stored.body)?["state"] as? String == "C")
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["state"] as? String == "C")
                let duplicate = try #require(replay["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test
    func namesVerificationReadWedgeHasTheSharedDeadlineWinnerAndNoLateEffects() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names)
                let blocked = BlockedRead()
                defer { blocked.unblock() }
                f.view.attributeReadObserver = { element, attribute in
                    if CFEqual(element, headers[0]), attribute == kAXTitleAttribute as String { blocked.blockOnce() }
                }
                let params = try f.applyParameters(plan, key: "wedged-names")
                let outcome = try await f.call("apply_session_repair", params: params,
                    lifecycleDeadline: .now.advanced(by: .seconds(1)))
                #expect(blocked.entered)
                #expect(outcome["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
                #expect(f.view.events.isEmpty)
                let successor = try #require(f.gate.tryAcquire(operation: "names-successor", now: .distantFuture))
                defer { f.gate.release(successor) }
                blocked.unblock()
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["error"] as? String == outcome["error"] as? String)
                #expect(f.gate.stillOwns(successor))
                #expect(f.view.events.isEmpty)
                guard case .completed(let stored)? = await f.journal.record(for: "wedged-names") else {
                    Issue.record("the deadline must remain the journal winner"); return
                }
                #expect(sharedJSONObject(stored.body)?["error"] as? String == outcome["error"] as? String)
            }
        }
    }

    @Test
    func composedMixerGoalCannotInventAbsenceAcrossUnreadPresentationDescendants() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                _ = f.installNameHeaders(names)
                // Unread children can hide a Mixer. Unavailable exclusion-only
                // Help instead includes all positively typed descendants.
                f.view.unreadNestedGroup = f.view.extraWindowChildren[0]
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(true)])],
                    includeMixerObservation: false)
                let executable = try #require(plan["executable"] as? Bool)
                #expect(!executable)
                let reasons = try #require(plan["reasons"] as? [String])
                #expect(reasons.contains("mixer_visibility_unobserved"))
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test
    func composedMixerGoalUsesIndependentPresentationEvidenceInATracksOnlySnapshot() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                _ = f.installNameHeaders(names)
                let report = try await f.call("inspect_session", params: ["domains": .array([.string("tracks")])])
                let observation = try #require(report["presentation_observation"] as? [String: Any])
                let visible = try #require(observation["mixer_visible"] as? Bool)
                #expect(!visible)
                let snapshot = try #require(report["snapshot_id"] as? String)
                let retained = try #require(await f.cache.retainedInspection(id: snapshot))
                #expect(retained.capture.freshPopulation?.presentationBinding != nil)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(true)])],
                    includeMixerObservation: false)
                let executable = try #require(plan["executable"] as? Bool)
                #expect(executable)
                let steps = try #require(plan["steps"] as? [[String: Any]])
                #expect(steps.count == 1)
                let before = try #require(steps.first?["before"] as? [String: Any])
                let beforeVisible = try #require(before["visible"] as? Bool)
                #expect(!beforeVisible)
                #expect(f.view.events.isEmpty)
                #expect(!f.view.showing)
            }
        }
    }

    @Test
    func registeredMatchingNamesAndMixerVisibilityExecuteAllApprovedGoals() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let names = ["Bass", "  e\u{301}, \"Lead\"  "]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(true)])])
                let executable = try #require(plan["executable"] as? Bool)
                #expect(executable)
                let planned = try #require(plan["steps"] as? [[String: Any]])
                #expect(planned.count == 1)
                #expect(planned.first?["kind"] as? String == "mixer_visibility")
                #expect((plan["approved_names"] as? [[String: Any]])?.count == names.count)
                #expect((plan["unchanged_tasks"] as? [String])?.count == names.count)
                #expect(f.view.events.isEmpty)
                let reads = headers.map { _ in DecidingMixerReplacement() }
                f.view.attributeReadObserver = { element, attribute in
                    if attribute == kAXTitleAttribute as String,
                       let index = headers.firstIndex(where: { CFEqual($0, element) }) {
                        reads[index].originalDecidingReads += 1
                    }
                }
                let params = try f.applyParameters(plan, key: "matching-names-and-view")
                let outcome = try await f.call("apply_session_repair", params: params)
                #expect(outcome["saga_state"] as? String == "completed")
                let verified = outcome["verified"] as? Bool ?? false
                #expect(verified)
                #expect(f.view.events == ["open_view", "show_mixer"])
                #expect(f.view.showing)
                for counter in reads { #expect(counter.originalDecidingReads > 0) }
                let actions = f.view.events
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["saga_state"] as? String == "completed")
                let duplicate = replay["duplicate"] as? Bool ?? false
                #expect(duplicate)
                #expect(f.view.events == actions)
                guard case .completed(let stored)? = await f.journal.record(for: "matching-names-and-view") else {
                    Issue.record("the composed approval must use the same existing journal"); return
                }
                let storedBody = try #require(sharedJSONObject(stored.body))
                #expect(storedBody["saga_state"] as? String == "completed")
                let evidence = try #require(outcome["goal_evidence"] as? [[String: Any]])
                #expect(evidence.count == names.count)
                for (index, item) in evidence.enumerated() {
                    let before = try #require(item["before"] as? [String: Any])
                    let read = try #require(item["read"] as? [String: Any])
                    for sample in [before, read] {
                        #expect(sample["read_source"] as? String == SagaReadSource.axTrackName.rawValue)
                        #expect(sample["provenance"] as? String == SagaProvenance.liveIndependent.rawValue)
                        let observed = try #require(sample["observed"] as? String)
                        #expect(observed.utf8.elementsEqual(names[index].utf8))
                    }
                }
                #expect(HonestContract.jsonString(["goal_evidence": storedBody["goal_evidence"] as Any])
                    == HonestContract.jsonString(["goal_evidence": evidence]))
                let steps = try #require(outcome["steps"] as? [[String: Any]])
                let viewEvidence = try #require(steps.first?["evidence"] as? [String: Any])
                let before = try #require(viewEvidence["before_state"] as? [String: Any])
                let verification = try #require(viewEvidence["verification"] as? [String: Any])
                let readback = try #require(verification["readback"] as? [String: Any])
                let wasVisible = try #require(before["observed"] as? Bool)
                let isVisible = try #require(readback["observed"] as? Bool)
                #expect(!wasVisible)
                #expect(isVisible)
                #expect(readback["read_source"] as? String == SagaReadSource.axProjectMixerVisibility.rawValue)
            }
        }
    }

    @Test
    func aMixerTaskCannotSilentlyDiscardTheSamePlansApprovedNames() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(false)])])
                let steps = try #require(plan["steps"] as? [[String: Any]])
                #expect(steps.count == 1)
                #expect(steps.first?["kind"] as? String == "mixer_visibility")
                #expect((plan["unchanged_tasks"] as? [String])?.count == 2)
                f.view.builder.setAttribute(headers[0], kAXTitleAttribute as String, "User edit")
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "mixed-name-view"))
                #expect(outcome["state"] as? String == "C")
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                let attempted = try #require(outcome["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func composedMatchingNamesKeepBothViewDirectionsAndNoOpReceipts(initial: Bool, desired: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: initial)
                await f.router.register(f.view.channel())
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(desired)])])
                let beforeReads = headers.map { _ in DecidingMixerReplacement() }
                let afterReads = headers.map { _ in DecidingMixerReplacement() }
                f.view.attributeReadObserver = { element, attribute in
                    if attribute == kAXTitleAttribute as String,
                       let index = headers.firstIndex(where: { CFEqual($0, element) }) {
                        let counters = f.view.events.isEmpty ? beforeReads : afterReads
                        counters[index].originalDecidingReads += 1
                    }
                }
                let params = try f.applyParameters(plan, key: "composed-directions")
                let outcome = try await f.call("apply_session_repair", params: params)
                #expect(outcome["saga_state"] as? String == "completed")
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(verified)
                for counter in beforeReads { #expect(counter.originalDecidingReads > 0) }
                if initial != desired {
                    for counter in afterReads { #expect(counter.originalDecidingReads > 0) }
                    #expect(f.view.events == ["open_view", desired ? "show_mixer" : "hide_mixer"])
                } else { #expect(f.view.events.isEmpty) }
                let matches = f.view.showing == desired
                #expect(matches)
                let steps = try #require(outcome["steps"] as? [[String: Any]])
                let result = try #require(steps.first?["result"] as? [String: Any])
                #expect(result["state"] as? String == "A")
                let crossed = try #require(result["write_boundary_crossed"] as? Bool)
                let matchesBoundary = crossed == (initial != desired)
                #expect(matchesBoundary)
                let evidence = try #require(outcome["goal_evidence"] as? [[String: Any]])
                #expect(evidence.count == names.count)
                for (index, item) in evidence.enumerated() {
                    for field in ["before", "read"] {
                        let read = try #require(item[field] as? [String: Any])
                        let observed = try #require(read["observed"] as? String)
                        #expect(observed.utf8.elementsEqual(names[index].utf8))
                    }
                }
                let events = f.view.events
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["saga_state"] as? String == "completed")
                #expect(f.view.events == events)
            }
        }
    }

    @Test(arguments: ["after_forward", "during_final_set", "cancel_after_forward", "no_op_goal_loss"])
    func composedViewNeverOverwritesOrCertifiesAHumanNameEdit(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let noOp = kind == "no_op_goal_loss"
                let f = try Fixture(showing: noOp)
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let hook = DecidingMixerReplacement()
                let beforeReads = headers.map { _ in DecidingMixerReplacement() }
                let afterReads = headers.map { _ in DecidingMixerReplacement() }
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal,
                    cancel: kind == "cancel_after_forward", afterExecution: {
                        if !hook.armed {
                            hook.armed = true
                            if kind != "during_final_set" {
                                hook.replaced = true
                                f.view.builder.setAttribute(headers[1], kAXTitleAttribute as String, "Human edit")
                            }
                        }
                    })
                await f.router.register(channel)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(true)])])
                f.view.attributeReadObserver = { element, attribute in
                    guard attribute == kAXTitleAttribute as String,
                          let index = headers.firstIndex(where: { CFEqual($0, element) }) else { return }
                    if !hook.armed {
                        beforeReads[index].originalDecidingReads += 1
                        return
                    }
                    afterReads[index].originalDecidingReads += 1
                    if kind == "during_final_set", index == 1, !hook.replaced {
                        hook.replaced = true
                        f.view.builder.setAttribute(headers[0], kAXTitleAttribute as String, "Human edit")
                    }
                }
                let params = try f.applyParameters(plan, key: "cancel-approved-view")
                let outcome = try await f.call("apply_session_repair", params: params)
                #expect(hook.armed)
                #expect(hook.replaced)
                for counter in beforeReads { #expect(counter.originalDecidingReads > 0) }
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                #expect(outcome["state"] as? String == "C")
                if noOp {
                    // Existing Saga A/no-op reconciliation verifies an event-free
                    // inverse, so its truthful terminal is fullyCompensated.
                    #expect(outcome["saga_state"] as? String == "fullyCompensated")
                    #expect(f.view.events.isEmpty)
                    #expect(f.view.showing)
                } else {
                    #expect(await channel.verifiedForwards == 1)
                    #expect(outcome["saga_state"] as? String == "fullyCompensated")
                    #expect(f.view.events == ["open_view", "show_mixer", "open_view", "hide_mixer"])
                    #expect(!f.view.showing)
                }
                if kind != "cancel_after_forward" {
                    for counter in afterReads { #expect(counter.originalDecidingReads > 0) }
                    #expect(outcome["goal_verification_failure"] as? String == "approved_name_or_mixer_goal_unverified")
                } else { #expect(await channel.cancelResult == .requested) }
                let editedIndex = kind == "during_final_set" ? 0 : 1
                #expect(f.view.builder.attributeValue(headers[editedIndex], kAXTitleAttribute as String) as? String == "Human edit")
                let events = f.view.events
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["saga_state"] as? String == outcome["saga_state"] as? String)
                #expect(f.view.events == events)
            }
        }
    }

    @Test
    func composedNameEditAtTheMenuLeafDeniesTheForwardWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(true)])])
                let hook = DecidingMixerReplacement()
                f.view.attributeReadObserver = { element, attribute in
                    if CFEqual(element, f.view.toggle), attribute == kAXEnabledAttribute as String,
                       f.view.events == ["open_view"], !hook.replaced {
                        hook.replaced = true
                        f.view.builder.setAttribute(headers[1], kAXTitleAttribute as String, "Human edit")
                    }
                }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "composed-leaf-loss"))
                #expect(hook.replaced)
                #expect(f.view.events == ["open_view", "cancel_view"])
                #expect(!f.view.showing)
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                #expect(outcome["saga_state"] as? String == "partiallyApplied")
                let steps = try #require(outcome["steps"] as? [[String: Any]])
                let result = try #require(steps.first?["result"] as? [String: Any])
                #expect(result["state"] as? String == "B")
                let attempted = try #require(result["write_boundary_crossed"] as? Bool)
                #expect(attempted)
            }
        }
    }

    @Test(arguments: ["changed_second", "raw_bytes", "replacement", "unread", "project"])
    func composedPreflightRequiresEveryOriginalNameAndPhysicalTarget(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                await f.router.register(f.view.channel())
                let names = ["e\u{301}", "Lead"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(true)])])
                switch kind {
                case "changed_second": f.view.builder.setAttribute(headers[1], kAXTitleAttribute as String, "Human edit")
                case "raw_bytes": f.view.builder.setAttribute(headers[0], kAXTitleAttribute as String, "é")
                case "replacement":
                    let replacement = f.view.builder.element(971_950)
                    f.view.builder.setRole(replacement, kAXLayoutItemRole as String)
                    f.view.builder.setAttribute(replacement, kAXTitleAttribute as String, names[1])
                    f.view.builder.setAttribute(replacement, kAXSelectedAttribute as String, false)
                    f.view.builder.setChildren(replacement, [])
                    f.view.builder.setChildren(f.view.rail, [headers[0], replacement])
                case "unread": f.view.failedMetadata = (headers[1], kAXTitleAttribute as String)
                case "project": f.view.builder.setAttribute(f.view.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                default: Issue.record("unknown composed preflight control"); return
                }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "composed-preflight"))
                #expect(outcome["state"] as? String == "C")
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                let attempted = try #require(outcome["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test
    func composedFinalNameReadUsesTheSharedDeadlineAndCannotActLate() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let hook = DecidingMixerReplacement()
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal,
                    cancel: false, afterVerified: { hook.armed = true })
                await f.router.register(channel)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(true)])])
                let blocked = BlockedRead()
                defer { blocked.unblock() }
                f.view.attributeReadObserver = { element, attribute in
                    if hook.armed, CFEqual(element, headers[0]), attribute == kAXTitleAttribute as String {
                        hook.replaced = true
                        blocked.blockOnce()
                    }
                }
                let params = try f.applyParameters(plan, key: "composed-wedged-final")
                let outcome = try await f.call("apply_session_repair", params: params,
                    lifecycleDeadline: .now.advanced(by: .seconds(1)))
                #expect(hook.armed)
                #expect(hook.replaced)
                #expect(blocked.entered)
                #expect(await channel.verifiedForwards == 1)
                #expect(outcome["error"] as? String == HonestContract.FailureError.operationTimeout.rawValue)
                #expect(f.view.events == ["open_view", "show_mixer"])
                let events = f.view.events
                let successor = try #require(f.gate.tryAcquire(operation: "composed-successor", now: .distantFuture))
                defer { f.gate.release(successor) }
                blocked.unblock()
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["error"] as? String == outcome["error"] as? String)
                #expect(f.gate.stillOwns(successor))
                #expect(f.view.events == events)
                guard case .completed(let stored)? = await f.journal.record(for: "composed-wedged-final") else {
                    Issue.record("the shared deadline must remain the journal winner"); return
                }
                #expect(sharedJSONObject(stored.body)?["error"] as? String == outcome["error"] as? String)
            }
        }
    }

    @Test(arguments: ["declined_leaf", "lost_readback"])
    func composedViewRefusalCannotCertifyTheWholeApprovedGoal(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let hook = DecidingMixerReplacement()
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal,
                    cancel: false, afterVerified: {
                        if kind == "lost_readback" {
                            hook.replaced = true
                            f.view.unknownWindowChildren = true
                        }
                    })
                await f.router.register(channel)
                let plan = try await f.namesPlan(names,
                    policyExtras: ["presentation": .object(["mixer_visible": .bool(true)])])
                if kind == "declined_leaf" {
                    f.view.leafAcknowledged = false
                    f.view.leafChangesVisibility = false
                    f.view.attributeReadObserver = { element, attribute in
                        if CFEqual(element, f.view.toggle), attribute == kAXTitleAttribute as String,
                           f.view.events == ["open_view"],
                           f.view.builder.attributeValue(element, attribute) as? String == AXLocalePolicy.showMixerMenuItem.canonical {
                            hook.armed = true
                        }
                    }
                }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "composed-view-refused"))
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                if kind == "declined_leaf" {
                    #expect(hook.armed)
                    // This fixture labels a leaf by its resulting visibility.
                    // The declined Show still leaves false, hence "hide_mixer";
                    // exactly one leaf and no inverse were dispatched.
                    #expect(f.view.events == ["open_view", "hide_mixer"])
                    #expect(await channel.verifiedForwards == 0)
                    #expect(outcome["saga_state"] as? String == "partiallyApplied")
                    #expect(outcome["state"] as? String == "C")
                    #expect(!f.view.showing)
                } else {
                    #expect(f.view.events == ["open_view", "show_mixer"])
                    #expect(hook.replaced)
                    #expect(await channel.verifiedForwards == 1)
                    #expect(outcome["saga_state"] as? String == "rollbackUncertain")
                    #expect(outcome["state"] as? String == "B")
                    #expect(f.view.showing)
                }
                for (index, header) in headers.enumerated() {
                    #expect(f.view.builder.attributeValue(header, kAXTitleAttribute as String) as? String == names[index])
                }
            }
        }
    }

    @Test(arguments: ["empty", "unaccounted_target", "changed_name", "role", "receiver", "unknown_policy", "unknown_presentation"])
    func namesOnlyApprovalDoesNotDropUnaccountedOrUnsupportedIntent(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                _ = f.installNameHeaders(names)
                let approved: [String]?
                let extra: [String: Value]
                switch kind {
                case "empty": approved = []; extra = [:]
                case "unaccounted_target": approved = [names[0]]; extra = [:]
                case "changed_name": approved = [names[0], "Changed"]; extra = [:]
                case "role": approved = nil; extra = ["roles": .array([.object([
                    "role": .string("lead"), "members": .array([.object(["handle": .string("t0"), "accepted": .bool(true)])])])])]
                case "receiver": approved = nil; extra = ["receivers": .array([.object(["bus": .int(1), "aux": .string("none")])])]
                case "unknown_policy": approved = nil; extra = ["unapproved_goal": .bool(true)]
                case "unknown_presentation": approved = nil; extra = ["presentation": .object(["sort": .object([:])])]
                default: Issue.record("unknown unsupported-policy control"); return
                }
                let plan = try await f.namesPlan(names, approvedNames: approved, policyExtras: extra)
                if kind == "unknown_policy" || kind == "unknown_presentation" {
                    #expect(plan["state"] as? String == "C")
                    #expect(f.view.events.isEmpty)
                    return
                }
                if kind == "changed_name" {
                    let reasons = try #require(plan["reasons"] as? [String])
                    #expect(reasons.contains("naming_preservation_adapter_unavailable"))
                }
                if ["empty", "unaccounted_target", "role"].contains(kind) {
                    let executable = try #require(plan["executable"] as? Bool)
                    #expect(!executable, "the retained adapter cannot verify this whole approved scope")
                    let reasons = try #require(plan["reasons"] as? [String])
                    #expect(!reasons.isEmpty)
                }
                let outcome = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: "unsupported-names"))
                #expect(outcome["state"] as? String == "C")
                let attempted = try #require(outcome["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test(arguments: ["target_refs_disabled", "saga_disabled", "gate_busy"])
    func namesVerificationRequiresTheExistingOptInsAndMutationClaim(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let names = ["Bass", "Lead"]
                _ = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names)
                let params = try f.applyParameters(plan, key: "names-availability")
                let outcome: [String: Any]
                switch kind {
                case "target_refs_disabled":
                    outcome = try await FeatureFlags.withAdr002TargetRefForTests(false) {
                        try await f.call("apply_session_repair", params: params)
                    }
                case "saga_disabled":
                    outcome = try await FeatureFlags.withAdr004MutationSagaForTests(false) {
                        try await f.call("apply_session_repair", params: params)
                    }
                case "gate_busy":
                    let claim = try #require(f.gate.tryAcquire(operation: "human-operation"))
                    defer { f.gate.release(claim) }
                    outcome = try await f.call("apply_session_repair", params: params)
                    #expect(f.gate.stillOwns(claim))
                    #expect(outcome["error"] as? String == HonestContract.FailureError.mutatingOperationInProgress.rawValue)
                default: Issue.record("unknown availability control"); return
                }
                #expect(outcome["state"] as? String == "C")
                let attempted = try #require(outcome["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test(arguments: ["ttl_replay", "body_eviction", "never_begun_expiry", "restart", "changed_id", "changed_digest"])
    func namesVerificationUsesTheSameCompactCanonicalReplayIdentity(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let clock = Clock()
                let f = try Fixture(showing: false, cache: StateCache(sessionCaptureNow: { clock.now() }),
                    journal: SagaJournal(maxRecords: 1))
                let names = ["Bass", "Lead"]
                let headers = f.installNameHeaders(names)
                let plan = try await f.namesPlan(names)
                var params = try f.applyParameters(plan, key: "historical-names")
                if kind != "never_begun_expiry" && kind != "restart" {
                    #expect(try await f.call("apply_session_repair", params: params)["saga_state"] as? String == "completed")
                }
                if kind == "body_eviction" {
                    let second = try await f.namesPlan(names)
                    #expect(try await f.call("apply_session_repair", params: f.applyParameters(second, key: "newer-names"))["saga_state"] as? String == "completed")
                    #expect(await f.journal.record(for: "historical-names") == .outcomeEvicted(terminal: .completed))
                }
                if kind == "ttl_replay" || kind == "never_begun_expiry" {
                    clock.advance(.seconds(StateCache.sessionCaptureLifetimeSeconds))
                }
                if kind == "changed_id" { params["plan_id"] = .string("plan_different") }
                if kind == "changed_digest" { params["digest"] = .string(String(repeating: "0", count: 64)) }
                f.view.builder.setAttribute(headers[0], kAXTitleAttribute as String, "New user edit")
                let reads = DecidingMixerReplacement()
                f.view.attributeReadObserver = { element, attribute in
                    if headers.contains(where: { CFEqual($0, element) }), attribute == kAXTitleAttribute as String {
                        reads.originalDecidingReads += 1
                    }
                }
                let result: [String: Any]
                if kind == "restart" {
                    let restarted = try Fixture(showing: false)
                    result = try await restarted.call("apply_session_repair", params: params)
                    #expect(restarted.view.events.isEmpty)
                } else { result = try await f.call("apply_session_repair", params: params) }
                switch kind {
                case "ttl_replay":
                    #expect(result["saga_state"] as? String == "completed")
                    let duplicate = try #require(result["duplicate"] as? Bool)
                    #expect(duplicate)
                    let evidence = try #require(result["goal_evidence"] as? [[String: Any]])
                    #expect((evidence.first?["read"] as? [String: Any])?["observed"] as? String == names[0])
                case "body_eviction": #expect(result["error"] as? String == HonestContract.FailureError.sagaOutcomeUnavailable.rawValue)
                case "changed_id", "changed_digest": #expect(result["error"] as? String == HonestContract.FailureError.idempotencyKeyConflict.rawValue)
                default: #expect(result["state"] as? String == "C")
                }
                #expect(reads.originalDecidingReads == 0)
                #expect(f.view.events.isEmpty)
            }
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

    @Test
    func supportedSortIntentRetainsItsWholeRequestWithoutPromotingPartialPopulation() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let fixture = try Fixture(showing: false)
                let observedNames = ["Piano", "Bass"]
                let headers = observedNames.enumerated().map { index, name in
                    let header = fixture.view.builder.element(971_100 + index)
                    fixture.view.builder.setRole(header, kAXLayoutItemRole as String)
                    fixture.view.builder.setAttribute(header, kAXTitleAttribute as String, name)
                    fixture.view.builder.setAttribute(header, kAXSelectedAttribute as String, false)
                    fixture.view.builder.setChildren(header, [])
                    return header
                }
                fixture.view.builder.setChildren(fixture.view.rail, headers)
                let report = try await fixture.call("inspect_session", params: [
                    "domains": .array([.string("tracks"), .string("strips")])])
                let snapshot = try #require(report["snapshot_id"] as? String)
                let project = try #require(report["project"] as? [String: Any])
                let projectRef = try #require(project["project_ref"] as? String)
                let tracks = try #require(report["tracks"] as? [String: Any])
                #expect(tracks["coverage"] as? String == "partial")
                let rows = try #require(tracks["rows"] as? [[String: Any]])
                #expect(rows.compactMap { $0["name"] as? String } == observedNames)
                let originalOrder = try rows.map { try #require($0["track_ref"] as? String) }
                #expect(originalOrder.count == 2)
                #expect(Set(originalOrder).count == 2)
                let expectedOrder = Array(originalOrder.reversed())
                let policy: Value = .object([
                    "schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "project_ref": .string(projectRef), "targets": .array([]),
                    "roles": .array([]), "outputs": .array([]),
                    "presentation": .object(["sort": .object([
                        "criterion": .string("track_name"),
                        "expected_order": .array(expectedOrder.map(Value.string)),
                        "inverse_criterion": .string("creation_date")])])])
                let plan = try await fixture.call("plan_session_repair", params: [
                    "snapshot_id": .string(snapshot), "policy": policy])
                #expect(plan["schema"] as? String == ProjectSessionAudit.sessionRepairPlanSchema)
                let steps = try #require(plan["steps"] as? [[String: Any]])
                #expect(steps.count == 1)
                let step = try #require(steps.first)
                #expect(step["kind"] as? String == "track_sort")
                #expect(step["target_ref"] as? String == projectRef)
                let before = try #require(step["before"] as? [String: Any])
                let after = try #require(step["after"] as? [String: Any])
                let inverse = try #require(step["inverse"] as? [String: Any])
                #expect(before["order"] as? [String] == originalOrder)
                #expect(after["criterion"] as? String == "track_name")
                #expect(after["order"] as? [String] == expectedOrder)
                #expect(inverse["criterion"] as? String == "creation_date")
                #expect(inverse["expected_order"] as? [String] == originalOrder)
                let executable = try #require(plan["executable"] as? Bool)
                #expect(!executable)
                let reasons = try #require(plan["reasons"] as? [String])
                #expect(reasons.contains("track_population_incomplete"))
                let preview = try #require(plan["preview"] as? [[String: Any]])
                #expect(NSDictionary(dictionary: ["steps": steps]) == NSDictionary(dictionary: ["steps": preview]))
                let id = try #require(plan["plan_id"] as? String)
                let digest = try #require(plan["digest"] as? String)
                let retained = try await fixture.call("plan_session_repair", params: [
                    "plan_id": .string(id), "digest": .string(digest)])
                #expect(NSDictionary(dictionary: retained) == NSDictionary(dictionary: plan))
                #expect(fixture.view.events.isEmpty)
            }
        }
    }

    private func observedSortInput(_ fixture: Fixture) async throws -> (snapshot: String, project: String, order: [String]) {
        let names = ["Piano", "Bass"]
        let headers = names.enumerated().map { index, name in
            let header = fixture.view.builder.element(971_100 + index)
            fixture.view.builder.setRole(header, kAXLayoutItemRole as String)
            fixture.view.builder.setAttribute(header, kAXTitleAttribute as String, name)
            fixture.view.builder.setAttribute(header, kAXSelectedAttribute as String, false)
            fixture.view.builder.setChildren(header, [])
            return header
        }
        fixture.view.builder.setChildren(fixture.view.rail, headers)
        let report = try await fixture.call("inspect_session", params: ["domains": .array([.string("tracks"), .string("strips")])])
        let tracks = try #require(report["tracks"] as? [String: Any])
        #expect(tracks["coverage"] as? String == "partial")
        let rows = try #require(tracks["rows"] as? [[String: Any]])
        #expect(rows.compactMap { $0["name"] as? String } == names)
        let order = try rows.map { try #require($0["track_ref"] as? String) }
        try #require(order.count == names.count)
        return (try #require(report["snapshot_id"] as? String),
                try #require((report["project"] as? [String: Any])?["project_ref"] as? String),
                order)
    }

    private func sortPolicy(project: String, presentation: Value) -> Value {
        .object(["schema": .string(ProjectSessionAudit.intentPolicySchema), "project_ref": .string(project),
            "targets": .array([]), "roles": .array([]), "outputs": .array([]), "presentation": presentation])
    }

    @Test(arguments: ["missing_inverse", "unsupported_forward", "unsupported_inverse", "wrong_inverse_type",
                      "missing_order", "wrong_order_type", "empty_order", "duplicate_order", "non_track_ref",
                      "unknown_sort_key", "empty_presentation", "unknown_presentation_key"])
    func invalidSortIntentRefusesTheWholeDraftBeforeAnyViewAction(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let fixture = try Fixture(showing: false)
                let input = try await observedSortInput(fixture)
                var sort: [String: Value] = ["criterion": .string("track_name"),
                    "expected_order": .array(input.order.reversed().map(Value.string)),
                    "inverse_criterion": .string("creation_date")]
                switch kind {
                case "missing_inverse": sort.removeValue(forKey: "inverse_criterion")
                case "unsupported_forward": sort["criterion"] = .string("arbitrary")
                case "unsupported_inverse": sort["inverse_criterion"] = .string("previous")
                case "wrong_inverse_type": sort["inverse_criterion"] = .int(1)
                case "missing_order": sort.removeValue(forKey: "expected_order")
                case "wrong_order_type": sort["expected_order"] = .string("Piano,Bass")
                case "empty_order": sort["expected_order"] = .array([])
                case "duplicate_order": sort["expected_order"] = .array([.string(input.order[0]), .string(input.order[0])])
                case "non_track_ref": sort["expected_order"] = .array([.string(input.project)])
                case "unknown_sort_key": sort["allow_partial"] = .bool(true)
                case "empty_presentation", "unknown_presentation_key": break
                default: Issue.record("unknown fixture case")
                }
                var presentation: [String: Value] = ["mixer_visible": .bool(true), "sort": .object(sort)]
                if kind == "empty_presentation" { presentation = [:] }
                if kind == "unknown_presentation_key" { presentation["arbitrary_order"] = .array([]) }
                let result = try await fixture.call("plan_session_repair", params: ["snapshot_id": .string(input.snapshot),
                    "policy": sortPolicy(project: input.project, presentation: .object(presentation))])
                #expect(result["state"] as? String == "C")
                #expect(result["plan_id"] == nil)
                #expect(fixture.view.events.isEmpty)
                #expect(!fixture.view.showing)
            }
        }
    }

    @Test(arguments: ["foreign", "missing", "extra"])
    func aSortOrderMustBeTheCapturedReferencePermutationWithoutDroppingTheViewTask(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let fixture = try Fixture(showing: false)
                await fixture.router.register(fixture.view.channel())
                let input = try await observedSortInput(fixture)
                let requested: [String]
                switch kind {
                case "foreign": requested = [input.order[0], "trk_other_capture"]
                case "missing": requested = [input.order[0]]
                case "extra": requested = input.order + ["trk_other_capture"]
                default: throw CocoaError(.coderInvalidValue)
                }
                let plan = try await fixture.call("plan_session_repair", params: ["snapshot_id": .string(input.snapshot),
                    "policy": sortPolicy(project: input.project, presentation: .object([
                        "mixer_visible": .bool(true), "sort": .object(["criterion": .string("track_name"),
                            "expected_order": .array(requested.map(Value.string)), "inverse_criterion": .string("creation_date")])]))])
                let executable = try #require(plan["executable"] as? Bool)
                #expect(!executable)
                let steps = try #require(plan["steps"] as? [[String: Any]])
                #expect(steps.compactMap { $0["kind"] as? String } == ["track_sort", "mixer_visibility"])
                let step = try #require(steps.first)
                #expect((step["before"] as? [String: Any])?["order"] as? [String] == input.order)
                #expect((step["before"] as? [String: Any])?["coverage"] as? String == "partial")
                #expect((step["after"] as? [String: Any])?["order"] as? [String] == requested)
                let blocked = try #require(step["blocked_reasons"] as? [String])
                #expect(blocked.contains("sort_expected_order_not_capture_permutation"))
                let result = try await fixture.call("apply_session_repair", params: fixture.applyParameters(plan, key: "invalid-sort-view"))
                #expect(result["state"] as? String == "C")
                #expect(await fixture.journal.record(for: "invalid-sort-view") == nil)
                #expect(fixture.view.events.isEmpty)
                #expect(!fixture.view.showing)
            }
        }
    }

    @Test
    func explicitSortInverseChangesTheCanonicalDigestButCannotTurnPartialCurrentOrderIntoExecutable() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let fixture = try Fixture(showing: false)
                let input = try await observedSortInput(fixture)
                var digests: [String] = []
                for inverse in ["creation_date", "track_name"] {
                    let plan = try await fixture.call("plan_session_repair", params: ["snapshot_id": .string(input.snapshot),
                        "policy": sortPolicy(project: input.project, presentation: .object(["sort": .object([
                            "criterion": .string("track_name"), "expected_order": .array(input.order.map(Value.string)),
                            "inverse_criterion": .string(inverse)])]))])
                    let executable = try #require(plan["executable"] as? Bool)
                    #expect(!executable)
                    let step = try #require((plan["steps"] as? [[String: Any]])?.first)
                    #expect((step["before"] as? [String: Any])?["coverage"] as? String == "partial")
                    #expect((step["inverse"] as? [String: Any])?["criterion"] as? String == inverse)
                    let blocked = try #require(step["blocked_reasons"] as? [String])
                    #expect(blocked.contains("sort_locale_measurement_unavailable"))
                    #expect(blocked.contains("sort_coupled_footprint_unavailable"))
                    #expect(blocked.contains("sort_preservation_adapter_unavailable"))
                    digests.append(try #require(plan["digest"] as? String))
                }
                #expect(digests[0] != digests[1])
                #expect(fixture.view.events.isEmpty)
            }
        }
    }

    @Test(arguments: ["ko-KR", "en-US", "ja-JP"])
    func capturedMenuLocaleDistinguishesMeasuredSortFromAnUnsupportedLanguage(locale: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let fixture = try Fixture(showing: false)
                let titlesByLocale = [
                    "ko-KR": ["파일", "편집", "트랙"],
                    "en-US": ["File", "Edit", "Track"],
                    "ja-JP": ["ファイル", "編集", "トラック"],
                ]
                let titles = try #require(titlesByLocale[locale])
                let menus = titles.enumerated().map { index, title in
                    let menu = fixture.view.builder.element(971_200 + index)
                    fixture.view.builder.setRole(menu, kAXMenuBarItemRole as String)
                    fixture.view.builder.setAttribute(menu, kAXTitleAttribute as String, title)
                    fixture.view.builder.setChildren(menu, [])
                    return menu
                }
                fixture.view.builder.setChildren(fixture.view.menuBar, menus + [fixture.view.view])
                let input = try await observedSortInput(fixture)
                let retained = try #require(await fixture.cache.retainedInspection(id: input.snapshot))
                #expect(retained.capture.freshPopulation != nil)
                let json = try #require(await fixture.cache.retainedSessionReport(id: input.snapshot))
                let report = try #require(sharedJSONObject(json))
                let observed = try #require(report["presentation_observation"] as? [String: Any])
                #expect(observed["ui_locale"] as? String == locale)
                let plan = try await fixture.call("plan_session_repair", params: ["snapshot_id": .string(input.snapshot),
                    "policy": sortPolicy(project: input.project, presentation: .object(["sort": .object([
                        "criterion": .string("track_name"), "expected_order": .array(input.order.reversed().map(Value.string)),
                        "inverse_criterion": .string("creation_date")])]))])
                let blocked = try #require(((plan["steps"] as? [[String: Any]])?.first)?["blocked_reasons"] as? [String])
                let localeBlockedAsExpected = blocked.contains("sort_locale_measurement_unavailable") == (locale == "ja-JP")
                #expect(localeBlockedAsExpected)
                #expect(blocked.contains("track_population_incomplete"))
                #expect(blocked.contains("sort_coupled_footprint_unavailable"))
                #expect(blocked.contains("sort_preservation_adapter_unavailable"))
                let executable = try #require(plan["executable"] as? Bool)
                #expect(!executable)
                #expect(fixture.view.events.isEmpty)
            }
        }
    }

    @discardableResult
    private static func installLocaleMenus(_ view: Issue969MixerVisibilitySetterTests.Fixture,
                                           titles: [String]) -> [AXUIElement] {
        let menus = titles.enumerated().map { index, title in
            let menu = view.builder.element(971_200 + index)
            view.builder.setRole(menu, kAXMenuBarItemRole as String)
            view.builder.setAttribute(menu, kAXTitleAttribute as String, title)
            view.builder.setChildren(menu, [])
            return menu
        }
        view.builder.setChildren(view.menuBar, menus + [view.view])
        return menus
    }

    @Test(arguments: ["absent", "unread_title", "ambiguous"])
    func unknownMenuLocaleBlocksOnlySortCapability(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let fixture = try Fixture(showing: false)
                if kind != "absent" {
                    let titles = kind == "ambiguous" ? ["파일", "편집", "트랙", "File", "Edit", "Track"] : ["파일", "편집", "트랙"]
                    let menus = Self.installLocaleMenus(fixture.view, titles: titles)
                    if kind == "unread_title" { fixture.view.failedMetadata = (menus[0], kAXTitleAttribute as String) }
                }
                let input = try await observedSortInput(fixture)
                let retained = try #require(await fixture.cache.retainedInspection(id: input.snapshot))
                let fresh = try #require(retained.capture.freshPopulation)
                #expect(fresh.presentationObservation?.uiLocale == nil)
                #expect(fresh.presentationBinding != nil)
                let plan = try await fixture.call("plan_session_repair", params: ["snapshot_id": .string(input.snapshot),
                    "policy": sortPolicy(project: input.project, presentation: .object(["sort": .object([
                        "criterion": .string("track_name"), "expected_order": .array(input.order.reversed().map(Value.string)),
                        "inverse_criterion": .string("creation_date")])]))])
                let blocked = try #require(((plan["steps"] as? [[String: Any]])?.first)?["blocked_reasons"] as? [String])
                #expect(blocked.contains("sort_locale_measurement_unavailable"))
                #expect(blocked.contains("track_population_incomplete"))
                #expect(fixture.view.events.isEmpty)
            }
        }
    }

    private final class LocaleChange: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var count: Int { lock.withLock { reads } }
        func consume() { lock.withLock { reads += 1 } }
    }

    @Test
    func localeDriftBetweenActualPopulationReadsRetainsTracksButNotSortLocale() async throws {
        let hook = LocaleChange()
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let fixture = try Fixture(showing: false, fileReader: { view in
                    Self.installLocaleMenus(view, titles: ["파일", "편집", "트랙"])
                    return .init(currentDocumentPath: { nil }, now: Date.init, readPlistData: { _ in nil },
                        mtime: { _ in
                            hook.consume()
                            Self.installLocaleMenus(view, titles: ["File", "Edit", "Track"])
                            return nil
                        }, sleep: { _ in })
                })
                let input = try await observedSortInput(fixture)
                #expect(hook.count == 1)
                let retained = try #require(await fixture.cache.retainedInspection(id: input.snapshot))
                let fresh = try #require(retained.capture.freshPopulation)
                #expect(fresh.stable)
                #expect(fresh.presentationObservation?.uiLocale == nil)
                let binding = try #require(fresh.presentationBinding)
                #expect(binding.uiLocale == nil)
                let plan = try await fixture.call("plan_session_repair", params: ["snapshot_id": .string(input.snapshot),
                    "policy": sortPolicy(project: input.project, presentation: .object(["sort": .object([
                        "criterion": .string("track_name"), "expected_order": .array(input.order.reversed().map(Value.string)),
                        "inverse_criterion": .string("creation_date")])]))])
                let blocked = try #require(((plan["steps"] as? [[String: Any]])?.first)?["blocked_reasons"] as? [String])
                #expect(blocked.contains("sort_locale_measurement_unavailable"))
                #expect(fixture.view.events.isEmpty)
            }
        }
    }

    @Test(arguments: [false, true])
    func temporaryNavigationLocaleDriftDoesNotInvalidateApprovedMixerCustody(drift: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let fixture = try Fixture(showing: false)
                Self.installLocaleMenus(fixture.view, titles: ["파일", "편집", "트랙"])
                let hook = LocaleChange()
                fixture.view.afterVisibilityChange = { [view = fixture.view] in
                    if view.showing, drift {
                        hook.consume()
                        Self.installLocaleMenus(view, titles: ["File", "Edit", "Track"])
                    }
                }
                let report = try await fixture.call("inspect_session", params: ["domains": .array([.string("strips")]),
                    "allow_ui_navigation": .bool(true)])
                #expect(hook.count == (drift ? 1 : 0))
                let observed = try #require(report["presentation_observation"] as? [String: Any])
                if drift { #expect(observed["ui_locale"] is NSNull) }
                else { #expect(observed["ui_locale"] as? String == "ko-KR") }
                let visible = try #require(observed["mixer_visible"] as? Bool)
                let playing = try #require(observed["is_playing"] as? Bool)
                let recording = try #require(observed["is_recording"] as? Bool)
                #expect(!visible)
                #expect(!playing)
                #expect(!recording)
                #expect(!fixture.view.showing)
                #expect(fixture.view.events.filter { $0 == "show_mixer" || $0 == "hide_mixer" } == ["show_mixer", "hide_mixer"])
                #expect((report["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
                let snapshot = try #require(report["snapshot_id"] as? String)
                let retained = try #require(await fixture.cache.retainedInspection(id: snapshot))
                let binding = try #require(retained.capture.freshPopulation?.presentationBinding)
                #expect(binding.uiLocale == "ko-KR")
                let project = try #require((report["project"] as? [String: Any])?["project_ref"] as? String)
                let plan = try await fixture.call("plan_session_repair", params: ["snapshot_id": .string(snapshot),
                    "policy": sortPolicy(project: project, presentation: .object(["mixer_visible": .bool(true)]))])
                let executable = try #require(plan["executable"] as? Bool)
                #expect(executable)
                fixture.view.afterVisibilityChange = nil
                await fixture.router.register(fixture.view.channel())
                let result = try await fixture.call("apply_session_repair", params: fixture.applyParameters(plan, key: "locale-drift-view"))
                #expect(result["saga_state"] as? String == "completed")
                #expect(fixture.view.showing)
                #expect(fixture.view.events.filter { $0 == "show_mixer" || $0 == "hide_mixer" } == ["show_mixer", "hide_mixer", "show_mixer"])
            }
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

    @Test(arguments: [false, true])
    func cancellationAtTheActualVisibilityLeafRetainsItsOwnedInverse(initial: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: initial)
                await f.router.register(f.view.channel())
                let plan = try await f.plan(desired: !initial)
                let blocked = BlockedRead()
                defer { blocked.unblock() }
                let hook = DecidingMixerReplacement()
                let key = "cancel-at-visibility-leaf"
                f.view.afterVisibilityChange = {
                    guard !hook.armed else { return }
                    hook.armed = true
                    Task {
                        if await f.journal.cancel(idempotencyKey: key) == .requested { hook.replaced = true }
                        blocked.unblock()
                    }
                    blocked.blockOnce()
                }
                let params = try f.applyParameters(plan, key: key)
                let outcome = try await f.call("apply_session_repair", params: params)
                #expect(hook.armed)
                #expect(hook.replaced)
                #expect(blocked.entered)
                #expect(outcome["saga_state"] as? String == "fullyCompensated")
                let restored = f.view.showing == initial
                #expect(restored)
                #expect(f.view.events == ["open_view", initial ? "hide_mixer" : "show_mixer",
                                          "open_view", initial ? "show_mixer" : "hide_mixer"])
                let compensation = try #require(outcome["compensation"] as? [String: Any])
                let fullyCompensated = try #require(compensation["fully_compensated"] as? Bool)
                #expect(fullyCompensated)
                let summary = try #require(compensation["journal_summary"] as? [String: Any])
                #expect(summary["forward_write_boundary_count"] as? Int == 1)
                #expect(summary["compensation_write_boundary_count"] as? Int == 1)
                #expect(summary["failed_compensation_count"] as? Int == 0)
                #expect(summary["uncertain_compensation_count"] as? Int == 0)
                guard case .cancelled(_, verified: true)? = await f.journal.record(for: key) else {
                    Issue.record("cancellation at the actual leaf must verify its own conditional inverse"); return
                }
                let events = f.view.events
                let replay = try await f.call("apply_session_repair", params: params)
                #expect(replay["saga_state"] as? String == "fullyCompensated")
                #expect(f.view.events == events)
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

    private final class DecidingMixerReplacement: @unchecked Sendable {
        var armed = false
        var originalDecidingReads = 0
        var replaced = false
        var replacementReads = 0
    }

    private final class PublishedMixerReplacement: @unchecked Sendable {
        var replaced = false
        var replacementReads = 0
        var readsBeforeCancellation = 0
    }

    @Test
    func aPostVerificationReplacementCannotBecomeOwnedInverseCustody() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: false)
                let replacement = f.view.builder.element(971_602)
                f.view.builder.setRole(replacement, kAXGroupRole as String)
                f.view.builder.setAttribute(replacement, kAXIdentifierAttribute as String, "Mixer")
                f.view.builder.setChildren(replacement, [])
                let probe = PublishedMixerReplacement()
                f.view.afterVisibilityChange = {
                    guard f.view.events == ["open_view", "show_mixer"] else { return }
                    // Start at the actual Show effect. The setter next reads M1
                    // in its poll and final lookup, with the acquired menu closed.
                    f.view.afterFinalFocusRead = {
                        probe.replaced = true
                        f.view.builder.setChildren(f.view.window,
                            f.view.extraWindowChildren + [f.view.rail, replacement])
                    }
                }
                f.view.attributeReadObserver = { element, attribute in
                    if CFEqual(element, f.view.app), attribute == kAXFocusedUIElementAttribute as String,
                       f.view.finalMixerReads == 2, f.view.finalFocusReads == 4 {
                        // The existing final-focus fixture identifies the setter's
                        // last sameFocus after owned() and its retained final M1 lookup.
                        f.view.finalFocusArmed = true
                    }
                    if probe.replaced, CFEqual(element, replacement),
                       attribute == kAXIdentifierAttribute as String {
                        probe.replacementReads += 1
                    }
                }
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal,
                    cancel: true, afterVerified: {
                        // This runs only after the real base setter returned A and
                        // perform completed its separate ownership-publication read.
                        probe.readsBeforeCancellation = probe.replacementReads
                    })
                await f.router.register(channel)
                let plan = try await f.plan(desired: true)
                let outcome = try await f.call("apply_session_repair",
                    params: f.applyParameters(plan, key: "cancel-approved-view"))
                #expect(probe.replaced)
                #expect(f.view.afterFinalFocusRead == nil)
                #expect(f.view.focusReadAtLoss == 5)
                #expect(f.view.finalMixerReads == 2)
                #expect(probe.readsBeforeCancellation > 0, "the post-result ownership read must actually observe M2 before cancellation")
                #expect(await channel.verifiedForwards == 1)
                #expect(await channel.cancelResult == .requested)
                #expect(!f.view.events.contains("hide_mixer"))
                #expect(f.view.events == ["open_view", "show_mixer"])
                #expect(f.view.showing)
                let children = try AXHelpers.childrenResult(f.view.window, runtime: f.view.builder.makeAXRuntime()).get()
                #expect(children.contains { CFEqual($0, replacement) })
                #expect(!children.contains { CFEqual($0, f.view.mixer) })
                #expect(outcome["state"] as? String == "B")
                #expect(outcome["saga_state"] as? String == "compensationFailed")
                #expect(f.view.builder.attributeValue(f.view.window, kAXDocumentAttribute as String) as? String == f.bundle.absoluteString)
                #expect(f.view.builder.attributeValue(f.view.window, kAXTitleAttribute as String) as? String == "Visibility fixture - Tracks")
                #expect(f.view.logicPID == 4242)
                let focus: AXUIElement? = AXHelpers.getAttribute(f.view.app,
                    kAXFocusedUIElementAttribute as String, runtime: f.view.builder.makeAXRuntime())
                #expect(CFEqual(try #require(focus), f.view.rail))
                #expect(f.view.builder.attributeValue(f.play, kAXValueAttribute as String) as? Int == 0)
                #expect(f.view.builder.attributeValue(f.record, kAXValueAttribute as String) as? Int == 0)
                #expect(try AXHelpers.childrenResult(f.view.rail, runtime: f.view.builder.makeAXRuntime()).get().isEmpty)
            }
        }
    }

    @Test
    func healthyVerifiedHideRetainsItsConditionalShowInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Fixture(showing: true)
                let channel = AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal, cancel: true)
                await f.router.register(channel)
                let plan = try await f.plan(desired: false)
                let outcome = try await f.call("apply_session_repair",
                    params: f.applyParameters(plan, key: "cancel-approved-view"))
                #expect(await channel.verifiedForwards == 1)
                #expect(await channel.cancelResult == .requested)
                #expect(f.view.events == ["open_view", "hide_mixer", "open_view", "show_mixer"])
                #expect(f.view.showing)
                #expect(outcome["saga_state"] as? String == "fullyCompensated")
                let steps = try #require(outcome["steps"] as? [[String: Any]])
                let result = try #require(steps.first?["result"] as? [String: Any])
                #expect(result["state"] as? String == "A")
                let crossed = try #require(result["write_boundary_crossed"] as? Bool)
                #expect(crossed)
                let compensation = try #require(steps.first?["compensation"] as? [String: Any])
                #expect(compensation["disposition"] as? String == "verified")
                let readback = try #require(compensation["readback"] as? [String: Any])
                let visible = try #require(readback["observed"] as? Bool)
                #expect(visible)
                #expect(readback["read_source"] as? String == SagaReadSource.axProjectMixerVisibility.rawValue)
                let children = try AXHelpers.childrenResult(f.view.window, runtime: f.view.builder.makeAXRuntime()).get()
                #expect(children.contains { CFEqual($0, f.view.mixer) })
                #expect(f.view.builder.attributeValue(f.view.window, kAXDocumentAttribute as String) as? String == f.bundle.absoluteString)
                #expect(f.view.builder.attributeValue(f.view.window, kAXTitleAttribute as String) as? String == "Visibility fixture - Tracks")
                #expect(f.view.logicPID == 4242)
                let focus: AXUIElement? = AXHelpers.getAttribute(f.view.app,
                    kAXFocusedUIElementAttribute as String, runtime: f.view.builder.makeAXRuntime())
                #expect(CFEqual(try #require(focus), f.view.rail))
                #expect(f.view.builder.attributeValue(f.play, kAXValueAttribute as String) as? Int == 0)
                #expect(f.view.builder.attributeValue(f.record, kAXValueAttribute as String) as? Int == 0)
                #expect(try AXHelpers.childrenResult(f.view.rail, runtime: f.view.builder.makeAXRuntime()).get().isEmpty)
                guard case .cancelled(_, verified: true)? = await f.journal.record(for: "cancel-approved-view") else {
                    Issue.record("the healthy Hide inverse must retain verified cancellation evidence"); return
                }
            }
        }
    }

    @Test(arguments: ["forward_hide", "owned_inverse_hide"])
    func replacementObservedByTheFinalPermissionCannotAuthorizeHide(kind: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let inverse = kind == "owned_inverse_hide"
                let f = try Fixture(showing: !inverse)
                let replacement = f.view.builder.element(971_601)
                f.view.builder.setRole(replacement, kAXGroupRole as String)
                f.view.builder.setAttribute(replacement, kAXIdentifierAttribute as String, "Mixer")
                f.view.builder.setChildren(replacement, [])
                let probe = DecidingMixerReplacement()
                let arm: @Sendable () -> Void = {
                    f.view.afterDecisiveMixerRead = {
                        probe.originalDecidingReads += 1
                        probe.armed = true
                    }
                    f.view.attributeReadObserver = { element, attribute in
                        // Direction reads occur after the deciding lookup has retained M1,
                        // before its CF check and the independent approval callback lookup.
                        if probe.armed, CFEqual(element, f.view.toggle),
                           attribute == kAXTitleAttribute as String {
                            probe.armed = false
                            probe.replaced = true
                            f.view.builder.setChildren(f.view.window,
                                f.view.extraWindowChildren + [f.view.rail, replacement])
                        }
                        if probe.replaced, CFEqual(element, replacement),
                           attribute == kAXIdentifierAttribute as String {
                            probe.replacementReads += 1
                        }
                    }
                }
                if inverse {
                    await f.router.register(AfterVerifiedSetterChannel(base: f.view.channel(), journal: f.journal,
                        cancel: true, afterVerified: { arm() }))
                } else {
                    await f.router.register(f.view.channel())
                }
                let plan = try await f.plan(desired: inverse)
                if !inverse { arm() }
                let outcome = try await f.call("apply_session_repair",
                    params: f.applyParameters(plan, key: inverse ? "cancel-approved-view" : "replacement-permission-hide"))
                #expect(probe.originalDecidingReads == 1)
                #expect(probe.replaced)
                #expect(!probe.armed)
                #expect(probe.replacementReads > 0, "the independent permission lookup must actually observe M2")
                #expect(!f.view.events.contains("hide_mixer"))
                #expect(f.view.showing)
                #expect(f.view.events == (inverse
                    ? ["open_view", "show_mixer", "open_view", "cancel_view"]
                    : ["open_view", "cancel_view"]))
                let children = try AXHelpers.childrenResult(f.view.window, runtime: f.view.builder.makeAXRuntime()).get()
                #expect(children.contains { CFEqual($0, replacement) })
                #expect(!children.contains { CFEqual($0, f.view.mixer) })
                #expect(f.view.builder.attributeValue(f.view.window, kAXDocumentAttribute as String) as? String == f.bundle.absoluteString)
                #expect(f.view.builder.attributeValue(f.view.window, kAXTitleAttribute as String) as? String == "Visibility fixture - Tracks")
                #expect(f.view.logicPID == 4242)
                let readFocus: AXUIElement? = AXHelpers.getAttribute(f.view.app,
                    kAXFocusedUIElementAttribute as String, runtime: f.view.builder.makeAXRuntime())
                let focus = try #require(readFocus)
                #expect(CFEqual(focus, f.view.rail))
                #expect(f.view.builder.attributeValue(f.play, kAXValueAttribute as String) as? Int == 0)
                #expect(f.view.builder.attributeValue(f.record, kAXValueAttribute as String) as? Int == 0)
                #expect(try AXHelpers.childrenResult(f.view.rail, runtime: f.view.builder.makeAXRuntime()).get().isEmpty)
                if inverse {
                    #expect(outcome["state"] as? String == "B")
                    #expect(outcome["saga_state"] as? String == "compensationFailed")
                } else {
                    // The scalar attempted refusal is B. The existing Saga reports
                    // its independently reconciled, unapplied goal as aggregate C.
                    #expect(outcome["state"] as? String == "C")
                    #expect(outcome["saga_state"] as? String == "partiallyApplied")
                    #expect(outcome["error"] as? String == "saga_execution_failed")
                    let steps = try #require(outcome["steps"] as? [[String: Any]])
                    let result = try #require(steps.first?["result"] as? [String: Any])
                    #expect(result["state"] as? String == "B")
                    let attempted = try #require(result["write_boundary_crossed"] as? Bool)
                    #expect(attempted)
                    let compensation = try #require(outcome["compensation"] as? [String: Any])
                    #expect(compensation["status"] as? String == "not_needed")
                    let summary = try #require(compensation["journal_summary"] as? [String: Any])
                    #expect(summary["forward_write_boundary_count"] as? Int == 1)
                    #expect(summary["compensation_write_boundary_count"] as? Int == 0)
                    let evidence = try #require(steps.first?["evidence"] as? [String: Any])
                    let verification = try #require(evidence["verification"] as? [String: Any])
                    #expect(verification["disposition"] as? String == "notApplied")
                    let readback = try #require(verification["readback"] as? [String: Any])
                    let stillVisible = try #require(readback["observed"] as? Bool)
                    #expect(stillVisible)
                }
                let verified = try #require(outcome["verified"] as? Bool)
                #expect(!verified)
                let menuSelected = try #require(f.view.builder.attributeValue(f.view.view, kAXSelectedAttribute as String) as? Bool)
                #expect(!menuSelected)
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
