import Foundation
import Testing
@testable import LogicProMCP

@Suite("Issue290AtlasEvidence")
struct Issue290AtlasEvidenceTests {
    private var axis: QualificationAxis {
        QualificationAxis(variant: .desktop, locale: .koKR, profile: .core, cache: .cold, fixture: .empty)
    }

    private func pairs() throws -> [AtlasQualification.Pair] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/AX")
        return try ["logic-12.x-desktop-ko-track-headers.json", "logic-12.x-desktop-ko-control-bar.json"].map {
            let document = try JSONDecoder().decode(AXSnapshot.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent($0)))
            return AtlasQualification.Pair(scope: document.scope, baseline: document, current: document)
        }
    }

    private func retained(_ pairs: [AtlasQualification.Pair]? = nil,
        dropped: [String] = []) throws -> AtlasQualification.EvidenceCase {
        try #require(AtlasQualification.evidenceCaseFor(armed: true,
            pairs: try (pairs ?? self.pairs()), dropped: dropped, axis: axis,
            binarySHA256: String(repeating: "a", count: 64), traceID: "controlled-atlas-case"))
    }

    private func altered(_ evidence: CaseEvidence,
        _ edit: (inout [String: Any]) throws -> Void) throws -> CaseEvidence {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        try edit(&object)
        return try JSONDecoder().decode(CaseEvidence.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func aPassingComparisonMustRetainItsEvidence() throws {
        let result = try retained()
        #expect(result.qualificationCase.status == .passed)
        #expect(result.qualificationCase.verified)
        #expect(result.qualificationCase.evidenceFiles == ["evidence/atlas-drift-diff.json"])
        let bytes = try JSONEncoder().encode(result.evidence)
        let decoded = try JSONDecoder().decode(CaseEvidence.self, from: bytes)
        #expect(try #require(decoded.atlasComparison).pairs == self.pairs())
        #expect(QualificationRunner.evidence(decoded, binds: result.qualificationCase))
        #expect(QualificationRunner.evidenceShapeIsValid(decoded))
    }

    @Test(arguments: [QualificationLocale.enUS, .koKR])
    func requiredSelectedScopesCannotBeReplacedByAWholeWindow(locale: QualificationLocale) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/AX")
        let language = locale == .koKR ? "ko" : "en"
        let documents = try ["track-headers", "control-bar"].map {
            try JSONDecoder().decode(AXSnapshot.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent(
                    "logic-12.x-desktop-\(language)-\($0).json")))
        }
        let axis = QualificationAxis(variant: .desktop, locale: locale,
            profile: .core, cache: .cold, fixture: .empty)
        let pairs = documents.map { AtlasQualification.Pair(
            scope: $0.scope, baseline: $0, current: $0) }
        let positive = try #require(AtlasQualification.evidenceCaseFor(
            armed: true, pairs: pairs, axis: axis,
            binarySHA256: String(repeating: "a", count: 64), traceID: "selected-scopes"))
        #expect(positive.qualificationCase.status == .passed)
        #expect(positive.qualificationCase.verified)
        #expect(QualificationRunner.evidenceShapeIsValid(positive.evidence))

        // Keep both archived roots and all their controls. This is a synthetic composition,
        // not another native observation. Raw unit count is not the required-scope authority.
        let root = AXSnapshot.Node(role: "AXWindow", subrole: nil, description: nil,
            help: nil, identifier: nil, valueRange: nil, children: documents.map(\.root))
        let wholeWindow = AXSnapshot.Document(logicVersion: "12.x", locale: language,
            scope: "window", capturedFrom: "ax", root: root)
        let windowPair = AtlasQualification.Pair(scope: "window",
            baseline: wholeWindow, current: wholeWindow)
        // The existing ordinary diff can still reuse this unchanged tree.
        if case let .diffed(verdict, _, unmeasured, dropped) =
            AtlasQualification.outcome(armed: true, pairs: [windowPair]) {
            #expect(verdict == .reuseFull)
            #expect(unmeasured.isEmpty)
            #expect(dropped.isEmpty)
        } else {
            Issue.record("the ordinary whole-window comparison must actually run")
        }
        let refused = try #require(AtlasQualification.evidenceCaseFor(
            armed: true, pairs: [windowPair], axis: axis,
            binarySHA256: String(repeating: "a", count: 64), traceID: "missing-selected-scopes"))
        #expect(refused.qualificationCase.status == .failed)
        #expect(!refused.qualificationCase.verified)
        #expect(refused.qualificationCase.reason ==
            "required atlas scopes missing or ambiguous: trackHeaderRail, controlBar")
        #expect(refused.qualificationCase.evidenceFiles == ["evidence/atlas-drift-diff.json"])
        #expect(QualificationRunner.evidenceShapeIsValid(refused.evidence))
        // A surviving selected subset, or an extra whole-window packet, cannot replace
        // the exact two declared comparison packets or contribute favorable coverage.
        for incompleteOrExtra in [Array(pairs.prefix(1)), pairs + [windowPair]] {
            let invalid = try #require(AtlasQualification.evidenceCaseFor(
                armed: true, pairs: incompleteOrExtra, axis: axis,
                binarySHA256: String(repeating: "a", count: 64), traceID: "scope-contract"))
            #expect(invalid.qualificationCase.status == .failed)
            #expect(!invalid.qualificationCase.verified)
            #expect(invalid.qualificationCase.reason ==
                "required atlas scopes missing or ambiguous: trackHeaderRail, controlBar")
            #expect(QualificationRunner.evidenceShapeIsValid(invalid.evidence))
        }
    }

    @Test(arguments: [QualificationLocale.enUS, .koKR])
    func requiredScopeLabelsCannotAuthorizeRelabelledWindowRoots(locale: QualificationLocale) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/AX")
        let language = locale == .koKR ? "ko" : "en"
        let documents = try ["track-headers", "control-bar"].map {
            try JSONDecoder().decode(AXSnapshot.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent(
                    "logic-12.x-desktop-\(language)-\($0).json")))
        }
        let axis = QualificationAxis(variant: .desktop, locale: locale,
            profile: .core, cache: .cold, fixture: .empty)
        let legitimate = documents.map { AtlasQualification.Pair(
            scope: $0.scope, baseline: $0, current: $0) }
        let positive = try #require(AtlasQualification.evidenceCaseFor(armed: true,
            pairs: legitimate, axis: axis, binarySHA256: String(repeating: "a", count: 64),
            traceID: "legitimate-selected-roots"))
        #expect(positive.qualificationCase.status == .passed)
        #expect(positive.qualificationCase.verified)
        #expect(QualificationRunner.evidenceShapeIsValid(positive.evidence))

        // All selector-compatible children survive; only their selected-root authority is lost.
        let legitimateRail = try #require(legitimate.first { AXLocalePolicy.trackHeadersDescription
            .matches($0.scope, mode: .exactStrict) })
        for selector in AtlasDiff.selectors(for: legitimateRail.current) {
            let path = try #require(AtlasDiff.unitPath(in: legitimateRail.current, for: selector))
            #expect(path.isEmpty)
        }
        for wrapperRole in ["AXWindow", "AXGroup"] {
            for replacedScopes in [Set([documents[0].scope]), Set([documents[1].scope]), Set(documents.map(\.scope))] {
                for (changeBaseline, changeCurrent) in [(true, true), (true, false), (false, true)] {
                    let relabelled = documents.map { original -> AtlasQualification.Pair in
                        guard replacedScopes.contains(original.scope) else {
                            return .init(scope: original.scope, baseline: original, current: original)
                        }
                        // A scope-compatible group name/shape still cannot move the rail's units
                        // below a nested whole-window wrapper or supply nested transport controls.
                        let description = wrapperRole == "AXWindow" ? nil :
                            (AXLocalePolicy.controlBarGroupLabel.matches(original.scope, mode: .exactStrict)
                                ? original.scope : AXSnapshot.shape(of: original.scope))
                        let wrapper = AXSnapshot.Node(role: wrapperRole, subrole: nil, description: description,
                            help: nil, identifier: nil, valueRange: nil, children: documents.map(\.root))
                        let whole = AXSnapshot.Document(logicVersion: original.logicVersion,
                            locale: original.locale, scope: original.scope, capturedFrom: "ax", root: wrapper)
                        return .init(scope: original.scope,
                            baseline: changeBaseline ? whole : original,
                            current: changeCurrent ? whole : original)
                    }
                    if changeBaseline && changeCurrent {
                        let scores = relabelled.flatMap { AtlasDiff.confidences(in: $0.current).values }
                        #expect(scores.count == AtlasDiff.adoptedSelectors.count)
                        #expect(scores.allSatisfy { $0 == 1.0 })
                        let rail = try #require(relabelled.first { AXLocalePolicy.trackHeadersDescription
                            .matches($0.scope, mode: .exactStrict) })
                        if replacedScopes.contains(rail.scope) {
                            for selector in AtlasDiff.selectors(for: rail.current) {
                                let path = try #require(AtlasDiff.unitPath(in: rail.current, for: selector))
                                #expect(!path.isEmpty)
                            }
                        }
                        if case let .diffed(verdict, _, unmeasured, dropped) =
                            AtlasQualification.outcome(armed: true, pairs: relabelled) {
                            #expect(verdict == .reuseFull)
                            #expect(unmeasured.isEmpty)
                            #expect(dropped.isEmpty)
                        } else {
                            Issue.record("The relabelled whole-window ordinary diff must actually compare")
                        }
                    }
                    let comparison = AtlasQualification.ComparisonEvidence(
                        schema: "qualification-atlas-comparison/v1", binarySHA256: String(repeating: "a", count: 64),
                        axis: axis, pairs: relabelled, dropped: [])
                    if case let .noBaselines(reason) = comparison.outcome {
                        #expect(!reason.isEmpty)
                    } else {
                        Issue.record("Invalid baseline/current selected roots must refuse before scoring")
                    }
                    let refused = try #require(AtlasQualification.evidenceCaseFor(armed: true,
                        pairs: relabelled, axis: axis, binarySHA256: String(repeating: "a", count: 64),
                        traceID: "relabelled-window-roots"))
                    #expect(refused.qualificationCase.status == .failed)
                    #expect(!refused.qualificationCase.verified)
                    #expect(QualificationRunner.evidenceShapeIsValid(refused.evidence))
                }
            }
        }
        let restored = try #require(AtlasQualification.evidenceCaseFor(armed: true,
            pairs: legitimate, axis: axis, binarySHA256: String(repeating: "a", count: 64),
            traceID: "legitimate-selected-roots"))
        #expect(restored.qualificationCase == positive.qualificationCase)
        #expect(restored.qualificationCase.verified)
    }

    @Test func missingComparisonCannotSupportAPassingCase() throws {
        let result = try retained()
        let missing = try altered(result.evidence) { $0.removeValue(forKey: "atlas_comparison") }
        #expect(!QualificationRunner.evidenceShapeIsValid(missing))
    }

    @Test func comparisonCandidateAndAxisMustMatchTheirCase() throws {
        let result = try retained()
        let candidate = try altered(result.evidence) {
            var comparison = try #require($0["atlas_comparison"] as? [String: Any])
            comparison["binary_sha256"] = String(repeating: "b", count: 64)
            $0["atlas_comparison"] = comparison
        }
        #expect(!QualificationRunner.evidenceShapeIsValid(candidate))
        let differentAxis = try altered(result.evidence) {
            var comparison = try #require($0["atlas_comparison"] as? [String: Any])
            var axis = try #require(comparison["axis"] as? [String: Any])
            axis["locale"] = "en-US"
            comparison["axis"] = axis
            $0["atlas_comparison"] = comparison
        }
        #expect(!QualificationRunner.evidenceShapeIsValid(differentAxis))
    }

    @Test func alteredCaptureCannotKeepThePassingVerdict() throws {
        let result = try retained()
        var documents = try pairs()
        let first = documents[0]
        var text = String(decoding: try JSONEncoder().encode(first.current), as: UTF8.self)
        for label in AXLocalePolicy.sliderVolumeHint.labels {
            text = text.replacingOccurrences(of: label, with: String(repeating: "x", count: label.count), options: .caseInsensitive)
        }
        let changed = try JSONDecoder().decode(AXSnapshot.Document.self, from: Data(text.utf8))
        documents[0] = AtlasQualification.Pair(scope: first.scope, baseline: first.baseline, current: changed)
        let failed = try retained(documents)
        #expect(failed.qualificationCase.status == .failed)
        #expect(!failed.qualificationCase.verified)
        #expect(QualificationRunner.evidenceShapeIsValid(failed.evidence))
        let forged = try altered(result.evidence) {
            let replacement = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(failed.evidence)) as? [String: Any])
            $0["atlas_comparison"] = replacement["atlas_comparison"]
        }
        #expect(!QualificationRunner.evidenceShapeIsValid(forged))
    }

    @Test func wrongScopeAndLocaleAreRetainedFailures() throws {
        let documents = try pairs()
        let first = documents[0]
        let wrongScope = AtlasQualification.Pair(scope: "unobserved-scope", baseline: first.baseline, current: first.current)
        let scoped = try retained([wrongScope] + documents.dropFirst())
        #expect(scoped.qualificationCase.status == .failed)
        #expect(!scoped.qualificationCase.verified)
        #expect(QualificationRunner.evidenceShapeIsValid(scoped.evidence))
        let wrongLocale = AXSnapshot.Document(logicVersion: first.current.logicVersion, locale: "en",
            scope: first.scope, capturedFrom: first.current.capturedFrom, root: first.current.root)
        let localized = try retained([AtlasQualification.Pair(scope: first.scope, baseline: first.baseline, current: wrongLocale)] + documents.dropFirst())
        #expect(localized.qualificationCase.status == .failed)
        #expect(!localized.qualificationCase.verified)
        #expect(QualificationRunner.evidenceShapeIsValid(localized.evidence))
    }

    @Test func unobservedMetadataAndDroppedBaselinesCannotPass() throws {
        let documents = try pairs()
        let first = documents[0]
        let unknown = AXSnapshot.Document(logicVersion: "observed", locale: "observed",
            scope: first.scope, capturedFrom: "ax", root: first.current.root)
        let result = try retained([AtlasQualification.Pair(scope: first.scope, baseline: first.baseline, current: unknown)] + documents.dropFirst())
        #expect(result.qualificationCase.status == .failed)
        #expect(!result.qualificationCase.verified)
        #expect(!result.qualificationCase.evidenceFiles.isEmpty)
        #expect(QualificationRunner.evidenceShapeIsValid(result.evidence))
        let unsupportedSource = AXSnapshot.Document(logicVersion: first.current.logicVersion,
            locale: first.current.locale, scope: first.scope, capturedFrom: "unknown-source", root: first.current.root)
        let provenance = try retained([AtlasQualification.Pair(scope: first.scope, baseline: first.baseline, current: unsupportedSource)] + documents.dropFirst())
        #expect(provenance.qualificationCase.status == .failed)
        #expect(!provenance.qualificationCase.verified)
        let dropped = try retained(dropped: ["missing-baseline.json"])
        #expect(dropped.qualificationCase.status == .failed)
        #expect(!dropped.qualificationCase.verified)
        #expect(QualificationRunner.evidenceShapeIsValid(dropped.evidence))
        let empty = try retained([])
        #expect(empty.qualificationCase.status == .failed)
        #expect(!empty.qualificationCase.verified)
        #expect(QualificationRunner.evidenceShapeIsValid(empty.evidence))
    }

    @Test func unknownAndUnspecifiedVersionsCannotSupportAPassingCase() throws {
        let documents = try pairs()
        let first = documents[0]
        for version in ["unknown", "unspecified"] {
            for changeBaseline in [false, true] {
                let original = changeBaseline ? first.baseline : first.current
                let changed = AXSnapshot.Document(logicVersion: version, locale: original.locale,
                    scope: original.scope, capturedFrom: original.capturedFrom, root: original.root)
                let pair = AtlasQualification.Pair(scope: first.scope,
                    baseline: changeBaseline ? changed : first.baseline,
                    current: changeBaseline ? first.current : changed)
                let result = try retained([pair] + documents.dropFirst())
                #expect(result.qualificationCase.status == .failed)
                #expect(!result.qualificationCase.verified)
            }
        }
    }

    @Test func anUnarmedAdapterDoesNotCaptureOrEmitEvidence() throws {
        #expect(AtlasQualification.evidenceCaseFor(armed: false, pairs: try pairs(), axis: axis,
            binarySHA256: String(repeating: "a", count: 64), traceID: "unarmed") == nil)
    }

    @Test func atlasEvidenceDoesNotEarnLiveOperationCredit() throws {
        let result = try retained()
        #expect(!PromotionGate.operationIsLiveCredited(result.qualificationCase))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.qualificationCase)) as? [String: Any])
        object["readback"] = ["source": "controlled-test", "request_id": "control", "verified": true,
            "sha256": String(repeating: "a", count: 64)]
        let withReadback = try JSONDecoder().decode(QualificationCase.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(try #require(withReadback.readback).verified)
        #expect(!PromotionGate.operationIsLiveCredited(withReadback))
    }
}
