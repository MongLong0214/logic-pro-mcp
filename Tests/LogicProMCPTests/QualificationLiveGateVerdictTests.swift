import Foundation
import Testing
@testable import LogicProMCP

/// The committed NOT_QUALIFIED list and its release-notes rendering.
enum QualificationNotQualifiedListFile {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var jsonURL: URL {
        repositoryRoot.appendingPathComponent("docs/qualification/not-qualified-logic13.json")
    }
    static var markdownURL: URL {
        repositoryRoot.appendingPathComponent("docs/qualification/NOT_QUALIFIED_ON_LOGIC13.md")
    }
    static func load() throws -> QualificationNotQualifiedList {
        try QualificationNotQualifiedList.parse(Data(contentsOf: jsonURL))
    }
}

/// DESIGN §1 and §4: the live gate's verdict function, driven from recorded and constructed
/// results, with no Logic. Every rule here has a source mutant (see the impl-gate evidence) that
/// turns it red.
///
/// NO `#expect(<Bool> == <Bool>)` (#393): booleans are asserted bare or negated.
@Suite("DESIGN §1 live-gate verdict")
struct QualificationLiveGateVerdictTests {
    static func spec(_ id: OperationID) -> OperationSpec {
        OperationRegistry.specs.first { $0.id == id }!
    }

    // MARK: result builders

    private static let envelope = #"{"source":"ax_live","cache_age_sec":1,"readable":true,"data":[{"name":"after"}]}"#

    /// A mutating probe refused fail-closed (the only thing a recipe-less operation produces).
    static func probeOnly(
        _ id: OperationID,
        record: QualificationMutationRestoreRecord? = nil,
        refusal: String? = nil
    ) -> QualificationOperationResult {
        let spec = spec(id)
        return QualificationOperationResult(
            operationID: id.rawValue, tool: spec.tool.rawValue, command: spec.command,
            mutability: spec.mutability, requestID: "probe",
            responseData: Data(#"{"success":false,"state":"C","error":"invalid_params"}"#.utf8),
            isError: true, state: "C", error: "invalid_params", hint: nil, writeAttempted: false,
            readbackSource: "logic://tracks", readbackRequestID: "readback",
            readbackData: Data(envelope.utf8),
            verification: spec.verification, deadline: spec.deadline, failureReason: nil,
            mutationRestore: record, mutationRestoreRefusal: refusal)
    }

    static func renameRecord(
        restoreReadback: String = #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"before"}]}"#
    ) -> QualificationMutationRestoreRecord {
        QualificationMutationRestoreRecord(
            operationID: OperationID.tracksRename.rawValue,
            preState: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"before"}]}"#,
            mutation: #"{"state":"A","success":true}"#,
            readback: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"after"}]}"#,
            restore: #"{"state":"A","success":true}"#,
            restoreReadback: restoreReadback)
    }

    /// A read whose oracle fixture passes; the readback is the oracle fixture's own.
    static func read(
        _ id: OperationID,
        response: Data? = nil,
        readback: Data? = nil,
        isError: Bool = false,
        source: String? = nil
    ) -> QualificationOperationResult {
        let spec = spec(id)
        let fixture = SemanticOracleFixtures.byOperationID[id]
        return QualificationOperationResult(
            operationID: id.rawValue, tool: spec.tool.rawValue, command: spec.command,
            mutability: spec.mutability, requestID: "read",
            responseData: response ?? fixture?.responseData, isError: isError, state: nil, error: nil,
            hint: nil, writeAttempted: false,
            readbackSource: source ?? QualificationTransport.readbackSource(for: spec),
            readbackRequestID: "readback", readbackData: readback ?? fixture?.readbackData,
            verification: spec.verification, deadline: spec.deadline, failureReason: nil)
    }

    /// The operations with a registered oracle whose recorded fixture passes and whose verdict
    /// DEPENDS on the readback (re-judged against a readback that cannot belong to it).
    static var readbackSensitiveOperations: [OperationID] {
        OperationRegistry.specs.filter { $0.mutability == .readOnly }.map(\.id).filter { id in
            guard SemanticOracleFixtures.byOperationID[id] != nil else { return false }
            let result = read(id)
            return result.status == .passed && QualificationLiveGateVerdict.readbackIsCompared(result)
        }
    }

    // MARK: exactly one verdict per registry operation

    @Test func everyRegistryOperationGetsExactlyOneVerdict() {
        let results = OperationRegistry.specs.map { spec in
            spec.mutability == .mutating ? Self.probeOnly(spec.id) : Self.read(spec.id)
        }
        let verdicts = QualificationLiveGateVerdict.verdicts(
            results: results, requested: OperationRegistry.specs, fixture: nil)
        #expect(OperationRegistry.specs.count == 138)
        #expect(verdicts.count == OperationRegistry.specs.count)
        #expect(Set(verdicts.map(\.operationID)).count == verdicts.count)
        #expect(Set(verdicts.map(\.operationID)) == Set(OperationRegistry.specs.map(\.id.rawValue)))
    }

    @Test func anOperationWithNoRecordedResultIsNeverExercised() {
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.transportPlay), result: nil, fixture: nil)
        #expect(evaluation.verdict == .notQualified(.missingResult))
        #expect(evaluation.violations.contains { $0.hasPrefix("transport.play:") })
    }

    // MARK: what is never EXERCISED

    @Test func aMutatingOperationWithOnlyTheProbeIsNotQualified() {
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.editCopy), result: Self.probeOnly(.editCopy), fixture: nil)
        #expect(evaluation.verdict == .notQualified(.unknownParamProbeOnly))
    }

    @Test func aRecipeThatRanAndRefusedIsNotQualified() {
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.tracksSelect),
            result: Self.probeOnly(.tracksSelect, refusal: "readback_mismatch observed 7"), fixture: nil)
        #expect(evaluation.verdict == .notQualified(.recipeRefused))
    }

    @Test func aRecipeOperationWithNeitherRecordNorRefusalIsNotQualified() {
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.tracksMute), result: Self.probeOnly(.tracksMute), fixture: nil)
        #expect(evaluation.verdict == .notQualified(.recipeRefused))
    }

    @Test func aVerifiedWriteCycleIsExercised() {
        let result = Self.probeOnly(.tracksRename, record: Self.renameRecord())
        #expect(result.status == .passed)
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.tracksRename), result: result, fixture: nil)
        #expect(evaluation.verdict == .exercised)
    }

    @Test func aWriteCycleWhoseRestoreReadbackDiffersIsNotExercised() {
        let result = Self.probeOnly(
            .tracksRename,
            record: Self.renameRecord(
                restoreReadback: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"after"}]}"#))
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.tracksRename), result: result, fixture: nil)
        #expect(evaluation.verdict == .notQualified(.restoreNotVerified))
    }

    @Test func aCycleWhoseRestoreReadbackDidNotHappenIsNotExercised() {
        let result = Self.probeOnly(
            .tracksRename,
            record: Self.renameRecord(restoreReadback: #"{"source":"ax_live","readable":false,"data":[]}"#))
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.tracksRename), result: result, fixture: nil)
        #expect(evaluation.verdict == .notQualified(.restoreNotVerified))
    }

    @Test func aRecordBesideARecipeRefusalIsNotExercised() {
        let result = Self.probeOnly(.tracksRename, record: Self.renameRecord(), refusal: "late refusal")
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.tracksRename), result: result, fixture: nil)
        #expect(evaluation.verdict == .notQualified(.restoreNotVerified))
    }

    @Test func recipesBehindTheKillSwitchAreNotQualifiedWhateverTheyRecord() {
        for id in [OperationID.tracksCreateAudio, .tracksCreateInstrument, .tracksDelete] {
            let evaluation = QualificationLiveGateVerdict.evaluate(
                spec: Self.spec(id), result: Self.probeOnly(id), fixture: nil)
            #expect(evaluation.verdict == .notQualified(.recipeDisabled), "\(id.rawValue)")
        }
    }

    @Test func consentFirstAndUnsupportedOperationsAreNotQualified() {
        for id in QualificationTransport.consentFirstMutationProbeOperationIDs {
            let evaluation = QualificationLiveGateVerdict.evaluate(
                spec: Self.spec(id), result: Self.probeOnly(id), fixture: nil)
            #expect(evaluation.verdict == .notQualified(.consentProbeOnly), "\(id.rawValue)")
        }
        for id in [OperationID.projectBounce, .transportSetCycleRange] {
            let evaluation = QualificationLiveGateVerdict.evaluate(
                spec: Self.spec(id), result: Self.probeOnly(id), fixture: nil)
            #expect(evaluation.verdict == .notQualified(.unsupportedByContract), "\(id.rawValue)")
        }
    }

    @Test func aReadThatRefusedIsNotQualified() {
        let id = OperationID.systemGetTrace
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(id), result: Self.read(id, isError: true), fixture: nil)
        #expect(evaluation.verdict == .notQualified(.refused))
    }

    @Test func anEnvironmentalPreconditionRefusalIsNotQualifiedAsSuch() throws {
        let id = OperationID.tracksScanPluginPresets
        let base = Self.read(id, response: Data("{}".utf8), readback: Data("{}".utf8), isError: true)
        let refused = QualificationOperationResult(
            operationID: base.operationID, tool: base.tool, command: base.command,
            mutability: base.mutability, requestID: base.requestID, responseData: base.responseData,
            isError: true, state: "C",
            error: HonestContract.FailureError.pluginWindowUnavailable.rawValue,
            hint: AccessibilityChannel.pluginWindowUnavailableHint, writeAttempted: false,
            readbackSource: base.readbackSource, readbackRequestID: base.readbackRequestID,
            readbackData: base.readbackData, verification: base.verification,
            deadline: base.deadline, failureReason: nil)
        #expect(refused.liveGateUnmetEnvironmentalPrecondition != nil)
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(id), result: refused, fixture: nil)
        #expect(evaluation.verdict == .notQualified(.envPrecondition))
    }

    @Test func aReadWhoseOracleNeverLooksAtItsReadbackIsNotExercised() throws {
        let ignoring = try #require(
            OperationRegistry.specs.filter { $0.mutability == .readOnly }.map(\.id).first { id in
                guard SemanticOracleFixtures.byOperationID[id] != nil,
                      QualificationLiveGateVerdict.staticReason(for: Self.spec(id), fixture: nil) == nil
                else { return false }
                let result = Self.read(id)
                return result.status == .passed && !QualificationLiveGateVerdict.readbackIsCompared(result)
            })
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(ignoring), result: Self.read(ignoring), fixture: nil)
        #expect(evaluation.verdict == .notQualified(.readbackNotCompared), "\(ignoring.rawValue)")
    }

    @Test func aReadWhoseOracleComparesItsReadbackIsExercised() throws {
        let sensitive = try #require(Self.readbackSensitiveOperations.first {
            QualificationLiveGateVerdict.staticReason(for: Self.spec($0), fixture: nil) == nil
        })
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(sensitive), result: Self.read(sensitive), fixture: nil)
        #expect(evaluation.verdict == .exercised, "\(sensitive.rawValue)")
    }

    @Test func aSameProducerEchoIsNotAnIndependentReadback() {
        let health = Data(SemanticOracleFixtures.health.utf8)
        let result = Self.read(.systemHealth, response: health, readback: health)
        #expect(result.status == .passed)
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.systemHealth), result: result, fixture: nil)
        #expect(evaluation.verdict == .notQualified(.readbackNotIndependent))
    }

    @Test func protocolSmokeAndValidatorUnavailableNeverCountAsExercised() throws {
        // Every read whose oracle declares an independent-readback deferral can reach protocolSmoke
        // at best. None of them may be EXERCISED, whatever the response says.
        var checked = 0
        for spec in OperationRegistry.specs where spec.mutability == .readOnly {
            guard QualificationLiveGateVerdict.staticReason(for: spec, fixture: nil)
                    == .semanticValidatorUnavailable else { continue }
            checked += 1
            let evaluation = QualificationLiveGateVerdict.evaluate(
                spec: spec, result: Self.read(spec.id), fixture: nil)
            #expect(evaluation.verdict == .notQualified(.semanticValidatorUnavailable), "\(spec.id.rawValue)")
        }
        #expect(checked >= 8, "the oracle table lost its deferral declarations")
    }

    @Test func aFailedOperationIsAViolationNamingIt() {
        var failed = Self.probeOnly(.tracksRename, record: Self.renameRecord())
        failed = QualificationOperationResult(
            operationID: failed.operationID, tool: failed.tool, command: failed.command,
            mutability: failed.mutability, requestID: failed.requestID, responseData: failed.responseData,
            isError: failed.isError, state: failed.state, error: failed.error, hint: failed.hint,
            writeAttempted: failed.writeAttempted, readbackSource: failed.readbackSource,
            readbackRequestID: failed.readbackRequestID, readbackData: failed.readbackData,
            verification: failed.verification, deadline: failed.deadline,
            failureReason: "ui_invariant: focus_moved", mutationRestore: failed.mutationRestore)
        let evaluation = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(.tracksRename), result: failed, fixture: nil)
        #expect(evaluation.verdict == .notQualified(.failed))
        #expect(evaluation.violations.contains { $0.hasPrefix("tracks.rename: failed") && $0.contains("focus_moved") })
    }

    // MARK: the committed list

    @Test func theCommittedListIsSoundAgainstTheRegistry() throws {
        let list = try QualificationNotQualifiedListFile.load()
        let found = QualificationLiveGateVerdict.listViolations(
            list: list, requested: OperationRegistry.specs, fixture: nil)
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
        #expect(list.entries.map(\.operation) == list.entries.map(\.operation).sorted(), "list must stay sorted")
    }

    /// The list must name every operation whose oracle ignores its readback: that fact is
    /// measurable from the recorded oracle fixtures, so a hand-written list cannot drift from it.
    @Test func theListNamesEveryReadWhoseOracleIgnoresItsReadback() throws {
        let list = try QualificationNotQualifiedListFile.load()
        let listed = Dictionary(list.entries.map { ($0.operation, $0) }, uniquingKeysWith: { first, _ in first })
        var insensitive: [String] = []
        for spec in OperationRegistry.specs where spec.mutability == .readOnly {
            guard SemanticOracleFixtures.byOperationID[spec.id] != nil,
                  QualificationLiveGateVerdict.staticReason(for: spec, fixture: nil) == nil else { continue }
            let result = Self.read(spec.id)
            guard result.status == .passed, !QualificationLiveGateVerdict.readbackIsCompared(result) else {
                continue
            }
            insensitive.append(spec.id.rawValue)
            #expect(listed[spec.id.rawValue] != nil, "\(spec.id.rawValue) ignores its readback and is not listed")
        }
        for entry in list.entries where entry.reason == "readback_not_compared" {
            #expect(insensitive.contains(entry.operation), "\(entry.operation) is listed readback_not_compared but its oracle compares")
        }
        #expect(!insensitive.isEmpty)
    }

    // MARK: both directions of the list (the owner's requirement)

    private static func list(_ entries: [(String, String, String)]) -> QualificationNotQualifiedList {
        QualificationNotQualifiedList(
            schema: 1, platform: "test",
            entries: entries.map { QualificationNotQualifiedEntry(operation: $0.0, reason: $0.1, detail: $0.2) })
    }

    @Test func aNewSilentGapFailsTheGateAndNamesTheOperation() throws {
        let committed = try QualificationNotQualifiedListFile.load()
        // The committed list minus edit.copy: edit.copy is NOT_QUALIFIED and now unlisted.
        let withoutCopy = QualificationNotQualifiedList(
            schema: 1, platform: "test", entries: committed.entries.filter { $0.operation != "edit.copy" })
        let found = QualificationLiveGateVerdict.violations(
            results: [Self.probeOnly(.editCopy)], requested: [Self.spec(.editCopy)],
            fixture: nil, list: withoutCopy)
        #expect(found.contains { $0.hasPrefix("edit.copy:") && $0.contains("not on the list") })
        #expect(found.contains { $0.hasPrefix("edit.copy:") && $0.contains("missing from the list") })
    }

    @Test func aStaleListEntryForAnExercisedOperationFailsTheGate() throws {
        let committed = try QualificationNotQualifiedListFile.load()
        let stale = QualificationNotQualifiedList(
            schema: 1, platform: "test",
            entries: committed.entries + [QualificationNotQualifiedEntry(
                operation: "tracks.rename", reason: "recipe_refused", detail: "was broken once")])
        let found = QualificationLiveGateVerdict.violations(
            results: [Self.probeOnly(.tracksRename, record: Self.renameRecord())],
            requested: [Self.spec(.tracksRename)], fixture: nil, list: stale)
        #expect(found.contains { $0.hasPrefix("tracks.rename:") && $0.contains("stale") })
    }

    @Test func aListedOperationWithAnotherObservedReasonIsDrift() {
        let found = QualificationLiveGateVerdict.violations(
            results: [Self.probeOnly(.tracksSelect, refusal: "x")], requested: [Self.spec(.tracksSelect)],
            fixture: nil,
            list: Self.list([("tracks.select", "unknown_param_probe_only", "wrong reason")]))
        #expect(found.contains { $0.hasPrefix("tracks.select:") && $0.contains("recipe_refused") })
    }

    @Test func aMatchingListedGapIsAccepted() {
        let found = QualificationLiveGateVerdict.violations(
            results: [Self.probeOnly(.tracksSelect, refusal: "x")], requested: [Self.spec(.tracksSelect)],
            fixture: nil, list: Self.list([("tracks.select", "recipe_refused", "selection broken")]))
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aListNamingAnUnknownOperationOrReasonIsRejected() {
        let found = QualificationLiveGateVerdict.listViolations(
            list: Self.list([
                ("edit.copy", "unknown_param_probe_only", "ok"),
                ("edit.imaginary", "unknown_param_probe_only", "no such op"),
                ("edit.cut", "made_up_reason", "bad code"),
                ("edit.delete", "failed", "a failure is never an expected gap"),
                ("edit.copy", "unknown_param_probe_only", "duplicate"),
                ("edit.join", "unknown_param_probe_only", "  "),
            ]),
            requested: [], fixture: nil)
        #expect(found.contains { $0.hasPrefix("edit.imaginary:") && $0.contains("not in the registry") })
        #expect(found.contains { $0.hasPrefix("edit.cut:") && $0.contains("unknown reason") })
        #expect(found.contains { $0.hasPrefix("edit.delete:") && $0.contains("never be an expected gap") })
        #expect(found.contains { $0.hasPrefix("edit.copy:") && $0.contains("more than once") })
        #expect(found.contains { $0.hasPrefix("edit.join:") && $0.contains("no detail") })
    }

    @Test func aListThatMissesAStaticallyUnexercisableOperationIsRejected() {
        let found = QualificationLiveGateVerdict.listViolations(
            list: Self.list([]), requested: OperationRegistry.specs, fixture: nil)
        for id in [OperationID.editCopy, .tracksDelete, .systemSetupArmKey, .projectBounce, .systemHealth] {
            #expect(found.contains { $0.hasPrefix("\(id.rawValue):") && $0.contains("missing from the list") },
                    "\(id.rawValue)")
        }
    }

    @Test func aListedStaticReasonThatDiffersFromTheCodeIsRejected() {
        let found = QualificationLiveGateVerdict.listViolations(
            list: Self.list([("edit.copy", "consent_probe_only", "wrong")]),
            requested: [Self.spec(.editCopy)], fixture: nil)
        #expect(found.contains { $0.hasPrefix("edit.copy:") && $0.contains("statically unknown_param_probe_only") })
    }

    // MARK: release notes

    @Test func theReleaseNotesRenderingMatchesTheList() throws {
        let list = try QualificationNotQualifiedListFile.load()
        let committed = try String(contentsOf: QualificationNotQualifiedListFile.markdownURL, encoding: .utf8)
        #expect(committed == list.markdown, "regenerate docs/qualification/NOT_QUALIFIED_ON_LOGIC13.md from the JSON")
        for entry in list.entries {
            #expect(committed.contains("`\(entry.operation)`"), "\(entry.operation) missing from the release notes")
        }
        #expect(committed.contains("Listed operations: \(list.entries.count)"))
    }

    @Test func theReleaseNotesRenderingChangesWhenTheListChanges() throws {
        let list = try QualificationNotQualifiedListFile.load()
        let shorter = QualificationNotQualifiedList(
            schema: list.schema, platform: list.platform, entries: Array(list.entries.dropFirst()))
        #expect(shorter.markdown != list.markdown)
    }

    // MARK: DESIGN §4 value checks

    private static let m4Empty = #"{"event_list_item_count_text":"0개의 이벤트","raw_rows":[],"selected_region_observation":{"end_bar":130,"kind":"midi","name":"Deluxe Classic","start_bar":129,"track_index":1},"state":"B"}"#
    private static func rows(_ pitches: [Int], countText: String) -> String {
        let rows = pitches.map { #"{"Num":{"slider_value":\#($0)},"Status":{"value_description":"노트"}}"# }
        return #"{"event_list_item_count_text":"\#(countText)","raw_rows":[\#(rows.joined(separator: ","))],"selected_region_observation":{"end_bar":130,"kind":"midi","name":"R","start_bar":129,"track_index":1},"state":"B"}"#
    }

    @Test func midiRowsMustEqualTheFixtureNoteCount() {
        // Measured M4: an empty row list next to "0개의 이벤트" is refused when N is 4.
        let m4 = QualificationLiveGateValueChecks.midiRowsViolations(
            responseData: Data(Self.m4Empty.utf8), expectedNoteCount: 4)
        #expect(m4.contains { $0.contains("raw_rows.count 0 != fixture N 4") })
        // Measured M5 shape with N = 2 is accepted.
        let m5 = QualificationLiveGateValueChecks.midiRowsViolations(
            responseData: Data(Self.rows([60, 60], countText: "2개의 이벤트").utf8), expectedNoteCount: 2,
            expectedPitches: [60, 60])
        #expect(m5.isEmpty, "\(m5)")
    }

    @Test func midiRowsMustAgreeWithTheCountText() {
        let found = QualificationLiveGateValueChecks.midiRowsViolations(
            responseData: Data(Self.rows([60, 62, 64, 67], countText: "5개의 이벤트").utf8),
            expectedNoteCount: 4)
        #expect(found.contains { $0.contains("says 5 but raw_rows.count is 4") })
        let unparseable = QualificationLiveGateValueChecks.midiRowsViolations(
            responseData: Data(Self.rows([60], countText: "Events: 1").utf8), expectedNoteCount: 1)
        #expect(unparseable.contains { $0.contains("no leading count") })
        let wrongPitches = QualificationLiveGateValueChecks.midiRowsViolations(
            responseData: Data(Self.rows([60, 62], countText: "2 Events").utf8), expectedNoteCount: 2,
            expectedPitches: [60, 64])
        #expect(wrongPitches.contains { $0.contains("pitches") })
    }

    /// The oracle fixture's own response (a shape the oracle accepts) with N rows.
    private static func midiBody(pitches: [Int]) -> Data {
        var body = try! JSONSerialization.jsonObject(
            with: SemanticOracleFixtures.byOperationID[.midiReadSelectedRegionEvents]!.responseData
        ) as! [String: Any]
        let template = (body["raw_rows"] as! [[String: Any]])[0]
        body["raw_rows"] = pitches.map { pitch -> [String: Any] in
            var row = template
            row["Num"] = ["slider_value": pitch]
            return row
        }
        body["event_list_item_count_text"] = "\(pitches.count) Events"
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func inventory(
        state: String = "A", complete: Bool = true, track: Int = 1, reason: String = "null",
        statuses: [String] = ["empty", "ok"]
    ) -> Data {
        let plugins = statuses.enumerated().map { #"{"insert":\#($0.offset),"read_status":"\#($0.element)","occupied":true}"# }
        return Data(#"{"success":true,"verified":true,"state":"\#(state)","hc_schema":2,"track":\#(track),"plugins_unknown_reason":\#(reason),"complete":\#(complete),"plugins":[\#(plugins.joined(separator: ","))]}"#.utf8)
    }

    @Test func theSoftwareInstrumentInventoryMustBeStateAAndComplete() {
        #expect(QualificationLiveGateValueChecks.siInventoryViolations(
            responseData: Self.inventory(), siTrackIndex: 1).isEmpty)
        let cases: [(Data, String)] = [
            (Self.inventory(state: "B"), "state is B"),
            (Self.inventory(complete: false), "complete is false"),
            (Self.inventory(track: 0), "not the SI track 1"),
            (Self.inventory(reason: #""ax_subtree_unreadable""#), "plugins_unknown_reason"),
            (Self.inventory(statuses: ["ok", "unreadable"]), "read_status unreadable"),
            (Self.inventory(statuses: ["unclassified"]), "read_status unclassified"),
        ]
        for (data, expected) in cases {
            let found = QualificationLiveGateValueChecks.siInventoryViolations(responseData: data, siTrackIndex: 1)
            #expect(found.contains { $0.contains(expected) }, "expected \(expected), got \(found)")
        }
    }

    @Test func theFixtureValueChecksDecideTheMidiAndInventoryVerdicts() {
        let id = OperationID.midiReadSelectedRegionEvents
        let good = Self.read(id, response: Self.midiBody(pitches: [60, 62, 64, 67]))
        let bad = Self.read(id, response: Self.midiBody(pitches: []))
        // The oracle accepts both shapes (measured M4: empty rows next to a zero count); only the
        // fixture-bound value check tells them apart.
        #expect(good.status == .protocolSmoke)
        #expect(bad.status == .protocolSmoke)
        func facts(inventory: Data = Self.inventory()) -> QualificationLiveGateFixtureFacts {
            QualificationLiveGateFixtureFacts(
                selectedRegionNoteCount: 4, selectedRegionPitches: [60, 62, 64, 67],
                siTrackIndex: 1, siInventoryResponse: inventory)
        }
        // Without fixture facts neither operation can ever be credited.
        #expect(QualificationLiveGateVerdict.evaluate(spec: Self.spec(id), result: good, fixture: nil).verdict
                == .notQualified(.needsFixtureValueCheck))
        #expect(QualificationLiveGateVerdict.evaluate(spec: Self.spec(id), result: good, fixture: facts()).verdict
                == .exercised)
        let rejected = QualificationLiveGateVerdict.evaluate(spec: Self.spec(id), result: bad, fixture: facts())
        #expect(rejected.verdict == .notQualified(.valueCheckFailed))
        #expect(rejected.violations.contains { $0.hasPrefix("midi.read_selected_region_events: value check:") })

        let inventoryID = OperationID.pluginsGetInventory
        let inventoryRead = Self.read(inventoryID)
        #expect(QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(inventoryID), result: inventoryRead, fixture: facts()).verdict == .exercised)
        let unreadable = QualificationLiveGateVerdict.evaluate(
            spec: Self.spec(inventoryID), result: inventoryRead,
            fixture: facts(inventory: Self.inventory(complete: false)))
        #expect(unreadable.verdict == .notQualified(.valueCheckFailed))
        #expect(unreadable.violations.contains { $0.hasPrefix("plugins.get_inventory: value check:") })
    }
}
