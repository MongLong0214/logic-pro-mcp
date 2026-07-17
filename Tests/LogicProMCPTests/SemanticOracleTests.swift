import Foundation
import Testing
@testable import LogicProMCP

// #373 Phase A — engine unit tests, census meta-tests, the anti-checkbox
// strength gate, and the mutation harness.

@Suite("#373 semantic oracle engine")
struct SemanticOracleEngineTests {
    private func root(_ json: String) -> Any {
        JSONInspector.parse(Data(json.utf8))!
    }

    // MARK: - constraint semantics

    @Test func valueEqualsMatchesEachPrimitiveAndRejectsMismatches() {
        let object = root(#"{"s":"x","n":4,"b":true,"z":null}"#)
        #expect(OracleConstraint.valueEquals(key: "s", expected: .string("x")).isSatisfied(by: object))
        #expect(OracleConstraint.valueEquals(key: "n", expected: .number(4)).isSatisfied(by: object))
        #expect(OracleConstraint.valueEquals(key: "b", expected: .bool(true)).isSatisfied(by: object))
        #expect(OracleConstraint.valueEquals(key: "z", expected: .null).isSatisfied(by: object))

        #expect(!OracleConstraint.valueEquals(key: "s", expected: .string("y")).isSatisfied(by: object))
        #expect(!OracleConstraint.valueEquals(key: "n", expected: .number(5)).isSatisfied(by: object))
        #expect(!OracleConstraint.valueEquals(key: "b", expected: .bool(false)).isSatisfied(by: object))
        #expect(!OracleConstraint.valueEquals(key: "missing", expected: .string("x")).isSatisfied(by: object))
    }

    /// NSNumber bridges booleans and numbers alike; an oracle that pinned
    /// `true` must not be satisfied by `1`, or every boolean honesty flag in the
    /// table becomes forgeable.
    @Test func valueEqualsDoesNotConflateBooleanAndNumericOne() {
        let object = root(#"{"flag":1,"real":true}"#)
        #expect(!OracleConstraint.valueEquals(key: "flag", expected: .bool(true)).isSatisfied(by: object))
        #expect(OracleConstraint.valueEquals(key: "flag", expected: .number(1)).isSatisfied(by: object))
        #expect(!OracleConstraint.valueEquals(key: "real", expected: .number(1)).isSatisfied(by: object))
        #expect(OracleConstraint.typedField(key: "real", type: .bool).isSatisfied(by: object))
        #expect(!OracleConstraint.typedField(key: "flag", type: .bool).isSatisfied(by: object))
        #expect(!OracleConstraint.typedField(key: "real", type: .number).isSatisfied(by: object))
    }

    @Test func numericRangeIsInclusiveAndRejectsOutOfDomainAndNonNumbers() {
        let object = root(#"{"low":0,"high":10,"mid":5,"text":"5","flag":true}"#)
        #expect(OracleConstraint.numericRange(key: "low", min: 0, max: 10).isSatisfied(by: object))
        #expect(OracleConstraint.numericRange(key: "high", min: 0, max: 10).isSatisfied(by: object))
        #expect(OracleConstraint.numericRange(key: "mid", min: 0, max: 10).isSatisfied(by: object))

        #expect(!OracleConstraint.numericRange(key: "high", min: 0, max: 9).isSatisfied(by: object))
        #expect(!OracleConstraint.numericRange(key: "low", min: 1, max: 10).isSatisfied(by: object))
        #expect(!OracleConstraint.numericRange(key: "text", min: 0, max: 10).isSatisfied(by: object))
        // A boolean is not a number in range, however NSNumber bridges it.
        #expect(!OracleConstraint.numericRange(key: "flag", min: 0, max: 10).isSatisfied(by: object))
        #expect(!OracleConstraint.numericRange(key: "missing", min: 0, max: 10).isSatisfied(by: object))
    }

    @Test func enumMemberAcceptsLegalTokensAndRejectsOutsiders() {
        let object = root(#"{"status":"ok","flag":false,"n":1}"#)
        #expect(OracleConstraint.enumMember(key: "status", allowed: ["ok", "bad"]).isSatisfied(by: object))
        #expect(!OracleConstraint.enumMember(key: "status", allowed: ["bad"]).isSatisfied(by: object))
        #expect(OracleConstraint.enumMember(key: "flag", allowed: ["true", "false"]).isSatisfied(by: object))
        // Numbers have no enum token — they must not be coerced into one.
        #expect(!OracleConstraint.enumMember(key: "n", allowed: ["1"]).isSatisfied(by: object))
        #expect(!OracleConstraint.enumMember(key: "missing", allowed: ["ok"]).isSatisfied(by: object))
    }

    @Test func nonEmptyArrayRejectsEmptyMissingAndNonArrays() {
        let object = root(#"{"full":[1],"empty":[],"object":{}}"#)
        #expect(OracleConstraint.nonEmptyArray(key: "full").isSatisfied(by: object))
        #expect(!OracleConstraint.nonEmptyArray(key: "empty").isSatisfied(by: object))
        #expect(!OracleConstraint.nonEmptyArray(key: "object").isSatisfied(by: object))
        #expect(!OracleConstraint.nonEmptyArray(key: "missing").isSatisfied(by: object))
    }

    @Test func typedFieldDiscriminatesEveryJSONType() {
        let object = root(#"{"s":"x","n":1,"b":true,"a":[],"o":{},"z":null}"#)
        #expect(OracleConstraint.typedField(key: "s", type: .string).isSatisfied(by: object))
        #expect(OracleConstraint.typedField(key: "n", type: .number).isSatisfied(by: object))
        #expect(OracleConstraint.typedField(key: "b", type: .bool).isSatisfied(by: object))
        #expect(OracleConstraint.typedField(key: "a", type: .array).isSatisfied(by: object))
        #expect(OracleConstraint.typedField(key: "o", type: .object).isSatisfied(by: object))
        #expect(OracleConstraint.typedField(key: "z", type: .null).isSatisfied(by: object))

        #expect(!OracleConstraint.typedField(key: "s", type: .number).isSatisfied(by: object))
        #expect(!OracleConstraint.typedField(key: "a", type: .object).isSatisfied(by: object))
        #expect(!OracleConstraint.typedField(key: "missing", type: .string).isSatisfied(by: object))
    }

    // MARK: - key paths

    @Test func keyPathsResolveNestingIndexingAndTheRoot() {
        let object = root(#"{"a":{"b":[{"c":7}]},"list":[1,2]}"#)
        #expect(OracleConstraint.valueEquals(key: "a.b.0.c", expected: .number(7)).isSatisfied(by: object))
        #expect(OracleConstraint.valueEquals(key: "list.1", expected: .number(2)).isSatisfied(by: object))
        #expect(!OracleConstraint.valueEquals(key: "list.9", expected: .number(2)).isSatisfied(by: object))
        #expect(!OracleConstraint.valueEquals(key: "a.b.0.missing", expected: .number(7)).isSatisfied(by: object))
        // The empty key path addresses the root value.
        #expect(OracleConstraint.typedField(key: "", type: .object).isSatisfied(by: object))
        #expect(OracleConstraint.typedField(key: "", type: .bool).isSatisfied(by: root("true")))
    }

    @Test func nonJSONResponseFailsDeclarativeOraclesRatherThanPassingVacuously() {
        let oracle = OperationOracle(
            .projectAudit,
            strength: .shapeAndDomain,
            constraints: [.valueEquals(key: "read_only", expected: .bool(true))]
        )
        // Verdicts are reduced to a plain Bool OUTSIDE the macro: this repo has
        // a history of `#expect(optionalBool == true)` expanding to a dead
        // assertion that always passes (issue #92).
        let verdict: Bool = oracle.evaluate(
            responseData: Data("not json".utf8),
            readbackData: Data()
        ) == true
        #expect(!verdict)
    }

    /// An oracle with no constraints would pass everything. `allSatisfy` over an
    /// empty list is vacuously true, so the strength gate — not the engine — is
    /// what keeps this from shipping; assert the hazard exists so the gate's
    /// purpose stays legible.
    @Test func constraintlessDeclarativeOracleIsVacuousAndSoIsRejectedByTheStrengthGate() {
        let vacuous = OperationOracle(.projectAudit, strength: .shapeAndDomain, constraints: [])
        let passesAnything: Bool = vacuous.evaluate(
            responseData: Data("{}".utf8),
            readbackData: Data()
        ) == true
        #expect(passesAnything)
        #expect(!vacuous.isSemanticallyLoadBearing)
    }
}

// MARK: - census

@Suite("#373 semantic oracle census")
struct SemanticOracleCensusTests {
    /// The registry is truth. If a spec flips to read-only, or a new read-only
    /// op lands, this fails until the table covers it — the oracle set can never
    /// silently under-cover the surface.
    @Test func everyReadOnlySpecHasAnOracle() {
        let missing = SemanticOracleTable.coveredSpecIDs
            .subtracting(SemanticOracleTable.byOperationID.keys)
        #expect(missing.isEmpty, "read-only specs with no oracle: \(missing.map(\.rawValue).sorted())")
    }

    /// The mirror image: an oracle for something that is not a qualifying
    /// read-only spec is dead weight that would never run.
    @Test func everyOracleMapsToAReadOnlySpec() {
        let extra = Set(SemanticOracleTable.byOperationID.keys)
            .subtracting(SemanticOracleTable.coveredSpecIDs)
        #expect(extra.isEmpty, "oracles with no read-only spec: \(extra.map(\.rawValue).sorted())")
    }

    @Test func healthKeepsItsBespokeValidatorAndIsNotInTheTable() {
        #expect(SemanticOracleTable.byOperationID[.systemHealth] == nil)
        #expect(!SemanticOracleTable.coveredSpecIDs.contains(.systemHealth))
    }

    @Test func tableHasNoDuplicateEntries() {
        #expect(SemanticOracleTable.all.count == SemanticOracleTable.byOperationID.count)
    }

    /// Pins the reconciled surface. The C1 classification named 20 ops but two
    /// of its names disagree with the registry: `edit.select_all` is registered
    /// MUTATING (so it is out), and `system.clear_traces` is registered
    /// read-only (so it is in). Both were reconciled toward the registry.
    @Test func reconciledReadOnlySurfaceIsTwentyOperations() {
        #expect(SemanticOracleTable.coveredSpecIDs.count == 20)
        #expect(!SemanticOracleTable.coveredSpecIDs.contains(.editSelectAll))
        #expect(SemanticOracleTable.coveredSpecIDs.contains(.systemClearTraces))

        let selectAll = OperationRegistry.specs.first { $0.id == .editSelectAll }
        #expect(selectAll?.mutability == .mutating)
        let clearTraces = OperationRegistry.specs.first { $0.id == .systemClearTraces }
        #expect(clearTraces?.mutability == .readOnly)
        let refreshCache = OperationRegistry.specs.first { $0.id == .systemRefreshCache }
        #expect(refreshCache?.mutability == .readOnly)
    }
}

// MARK: - strength (anti-checkbox gate)

@Suite("#373 semantic oracle strength")
struct SemanticOracleStrengthTests {
    /// Presence-only oracles are forbidden. Every oracle must pin meaning: at
    /// least one VALUE constraint, or an explicitly reasoned escape hatch.
    @Test func noOracleIsPresenceOnly() {
        let weak = SemanticOracleTable.all
            .filter { !$0.isSemanticallyLoadBearing }
            .map(\.operationID.rawValue)
        #expect(weak.isEmpty, "presence-only oracles: \(weak.sorted())")
    }

    @Test func declarativeOraclesCarryAValueConstraintAndNoHatch() {
        for oracle in SemanticOracleTable.all where oracle.strength != .custom {
            let hasValueConstraint = oracle.constraints.contains(where: { $0.isValueConstraint })
            #expect(hasValueConstraint, "\(oracle.operationID.rawValue) has no value constraint")
            let hasHatch = oracle.custom != nil
            #expect(!hasHatch, "\(oracle.operationID.rawValue) is not .custom but has a hatch")
        }
    }

    @Test func customOraclesAreExactlyTheSanctionedSetAndEachDocumentsWhy() {
        let actual = Set(SemanticOracleTable.customOracles.map(\.operationID))
        #expect(actual == SemanticOracleTable.sanctionedCustomOperationIDs)
        for oracle in SemanticOracleTable.customOracles {
            let hasHatch = oracle.custom != nil
            #expect(hasHatch, "\(oracle.operationID.rawValue) is .custom with no closure")
            #expect(oracle.constraints.isEmpty)
            // A reason is what separates a documented hatch from a shrug.
            let reason = oracle.customReason ?? ""
            #expect(reason.count > 40, "\(oracle.operationID.rawValue) reason is too thin")
        }
    }

    @Test func strengthValueMeansEveryConstraintIsExact() {
        for oracle in SemanticOracleTable.all where oracle.strength == .value {
            let allExact = oracle.constraints.allSatisfy(Self.isExactValue)
            #expect(allExact, "\(oracle.operationID.rawValue) claims .value strength inexactly")
        }
    }

    private static func isExactValue(_ constraint: OracleConstraint) -> Bool {
        if case .valueEquals = constraint { return true }
        return false
    }
}

// MARK: - fixtures + mutation harness

@Suite("#373 semantic oracle fixtures and mutation")
struct SemanticOracleMutationTests {
    @Test func everyOracleHasAFixture() {
        let missing = Set(SemanticOracleTable.byOperationID.keys)
            .subtracting(SemanticOracleFixtures.byOperationID.keys)
        #expect(missing.isEmpty, "oracles with no fixture: \(missing.map(\.rawValue).sorted())")
    }

    /// Happy path: a realistic payload from the real handler shape passes.
    @Test(arguments: SemanticOracleTable.all.map(\.operationID))
    func oraclePassesItsRealisticFixture(operationID: OperationID) throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[operationID])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[operationID])
        // #require unwraps the Bool? verdict, so the assertion below is over a
        // plain Bool — never a dead `optional == true` comparison (issue #92).
        let verdict = try #require(oracle.evaluate(
            responseData: fixture.responseData,
            readbackData: fixture.readbackData
        ))
        #expect(verdict, "\(operationID.rawValue) rejected its own realistic fixture")
    }

    /// The anti-checkbox tool. For every constraint of every declarative oracle,
    /// corrupt the fixture the way that constraint exists to catch (drop the
    /// key, push the value out of domain, wrong-type it) and require the oracle
    /// to FAIL. A constraint whose mutants still pass is decoration.
    @Test(arguments: SemanticOracleTable.all.map(\.operationID))
    func everyConstraintRejectsItsMutants(operationID: OperationID) throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[operationID])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[operationID])
        guard oracle.strength != .custom else { return }
        let root = try #require(JSONInspector.parse(fixture.responseData))

        for constraint in oracle.constraints {
            let mutants = JSONMutator.mutants(for: constraint, in: root)
            #expect(
                !mutants.isEmpty,
                "\(operationID.rawValue): no mutant generated for \(constraint.key)"
            )
            for mutant in mutants {
                let data = try #require(JSONMutator.encode(mutant.json))
                let survived: Bool = oracle.evaluate(
                    responseData: data,
                    readbackData: fixture.readbackData
                ) == true
                #expect(
                    !survived,
                    "\(operationID.rawValue): oracle survived mutant [\(mutant.label)] — constraint on '\(constraint.key)' is not load-bearing"
                )
            }
        }
    }

    /// `.custom` oracles cannot be mutated generically, so each ships explicit
    /// corruptions. An escape hatch with no failing mutant is unfalsifiable.
    ///
    /// Counting mutants would be gameable — four garbage strings "cover" an
    /// oracle while proving only that it rejects noise. So the KINDS are
    /// required: every custom oracle must reject a payload that parses fine and
    /// is merely wrong, and every cross-checking oracle must reject a response
    /// whose readback disagrees with it.
    @Test(arguments: SemanticOracleTable.customOracles.map(\.operationID))
    func customOraclesRejectEachRequiredMutantKind(operationID: OperationID) throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[operationID])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[operationID])
        let kinds = Set(fixture.customMutants.map(\.kind))

        #expect(
            kinds.contains(.malformed),
            "\(operationID.rawValue): needs a malformed mutant"
        )
        #expect(
            kinds.contains(.wellFormedButWrong),
            "\(operationID.rawValue): needs a well-formed-but-semantically-wrong mutant — rejecting garbage alone proves nothing"
        )
        if Self.crossCheckingOperationIDs.contains(operationID) {
            #expect(
                kinds.contains(.readbackDivergence),
                "\(operationID.rawValue): cross-checking oracle needs a readback-divergence mutant"
            )
        }

        for mutant in fixture.customMutants {
            let readback = mutant.readbackOverride.map { Data($0.utf8) } ?? fixture.readbackData
            let survived: Bool = oracle.evaluate(
                responseData: Data(mutant.response.utf8),
                readbackData: readback
            ) == true
            #expect(
                !survived,
                "\(operationID.rawValue): custom oracle survived \(mutant.kind.rawValue) mutant [\(mutant.response.prefix(60))]"
            )
        }
    }

    /// The oracles whose check compares the response against the readback. Only
    /// these can meaningfully be given a divergence mutant.
    static let crossCheckingOperationIDs: Set<OperationID> = [.midiListPorts, .tracksListLibrary]

    /// A custom oracle that returns nil on a good payload would silently
    /// downgrade its operation to protocolSmoke — an escape hatch declining to
    /// render a verdict at all. Every oracle must commit on its own fixture.
    @Test(arguments: SemanticOracleTable.all.map(\.operationID))
    func everyOracleRendersAVerdictOnItsFixture(operationID: OperationID) throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[operationID])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[operationID])
        let declined: Bool = oracle.evaluate(
            responseData: fixture.responseData,
            readbackData: fixture.readbackData
        ) == nil
        #expect(!declined, "\(operationID.rawValue) declined to render a verdict on its own fixture")
    }

    /// Wiring: the validator must actually consult the table, not just own it.
    @Test(arguments: SemanticOracleTable.all.map(\.operationID))
    func validatorRoutesEachReadOnlyOperationToItsOracle(operationID: OperationID) throws {
        let fixture = try #require(SemanticOracleFixtures.byOperationID[operationID])
        let routed = try #require(QualificationSemanticReadbackValidator.validate(
            operationID: operationID.rawValue,
            responseData: fixture.responseData,
            readbackData: fixture.readbackData
        ))
        #expect(routed, "\(operationID.rawValue) is not routed to its oracle")
        // And a corrupted payload must not be waved through as "no validator":
        // a nil here would silently downgrade the op to protocolSmoke.
        let corrupt = try #require(QualificationSemanticReadbackValidator.validate(
            operationID: operationID.rawValue,
            responseData: Data(#"{"__corrupt__":true}"#.utf8),
            readbackData: fixture.readbackData
        ))
        #expect(!corrupt, "\(operationID.rawValue) passed a corrupt payload")
    }

    @Test func validatorStillReturnsNilForOperationsWithNoOracle() {
        // A mutating op has no oracle; it must stay honestly unvalidated here.
        let mutating: Bool = QualificationSemanticReadbackValidator.validate(
            operationID: OperationID.transportPlay.rawValue,
            responseData: Data("{}".utf8),
            readbackData: Data("{}".utf8)
        ) == nil
        #expect(mutating)
        let unknown: Bool = QualificationSemanticReadbackValidator.validate(
            operationID: "not.an.operation",
            responseData: Data("{}".utf8),
            readbackData: Data("{}".utf8)
        ) == nil
        #expect(unknown)
    }

    @Test func healthRetainsItsBespokeFullPayloadEquality() throws {
        let health = Data(SemanticOracleFixtures.health.utf8)
        let matches = try #require(QualificationSemanticReadbackValidator.validate(
            operationID: OperationID.systemHealth.rawValue,
            responseData: health,
            readbackData: health
        ))
        #expect(matches)
        let drifted = Data(
            SemanticOracleFixtures.health
                .replacingOccurrences(
                    of: "\"logic_pro_running\":true",
                    with: "\"logic_pro_running\":false"
                )
                .utf8
        )
        let mismatch = try #require(QualificationSemanticReadbackValidator.validate(
            operationID: OperationID.systemHealth.rawValue,
            responseData: health,
            readbackData: drifted
        ))
        #expect(!mismatch)
    }
}

// MARK: - mutator

enum JSONMutator {
    struct Mutant {
        let label: String
        let json: Any
    }

    static func encode(_ json: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
    }

    /// Derives, from the constraint itself, the corruptions it claims to catch.
    static func mutants(for constraint: OracleConstraint, in root: Any) -> [Mutant] {
        let key = constraint.key
        var mutants: [Mutant] = []
        if let dropped = remove(root, keyPath: key) {
            mutants.append(Mutant(label: "drop \(key)", json: dropped))
        }
        switch constraint {
        case .valueEquals(_, let expected):
            mutants.append(contentsOf: replacements(root, key, [("alien value", alien(of: expected))]))
        case .numericRange(_, let min, let max):
            mutants.append(contentsOf: replacements(root, key, [
                ("above max", max + 1),
                ("below min", min - 1),
                ("not a number", "not-a-number"),
            ]))
        case .enumMember:
            mutants.append(contentsOf: replacements(root, key, [
                ("outside enum", "__not_a_member__"),
            ]))
        case .nonEmptyArray:
            mutants.append(contentsOf: replacements(root, key, [("emptied", [Any]())]))
        case .typedField(_, let type):
            mutants.append(contentsOf: replacements(root, key, [("wrong type", wrongTyped(type))]))
        }
        return mutants
    }

    private static func replacements(
        _ root: Any,
        _ key: String,
        _ values: [(String, Any)]
    ) -> [Mutant] {
        values.compactMap { label, value in
            set(root, keyPath: key, to: value).map { Mutant(label: "\(label) at \(key)", json: $0) }
        }
    }

    private static func alien(of primitive: JSONPrimitive) -> Any {
        switch primitive {
        case .string(let value): return value + "__oracle_mutant__"
        case .number(let value): return value + 1
        case .bool(let value): return !value
        case .null: return "no longer null"
        }
    }

    private static func wrongTyped(_ type: JSONType) -> Any {
        switch type {
        case .string: return 42
        case .number: return "42"
        case .bool: return "true"
        case .array: return [String: Any]()
        case .object: return [Any]()
        case .null: return 1
        }
    }

    static func set(_ root: Any, keyPath: String, to value: Any) -> Any? {
        transform(root, components: keyPath.split(separator: ".").map(String.init)) { _ in value }
    }

    static func remove(_ root: Any, keyPath: String) -> Any? {
        transform(root, components: keyPath.split(separator: ".").map(String.init)) { _ in nil }
    }

    /// Walks the key path and applies `leaf` at the end. Returns nil when the
    /// path does not exist, which keeps a typo'd fixture key from silently
    /// producing a no-op "mutant" that the oracle would rightly pass.
    private static func transform(
        _ current: Any,
        components: [String],
        leaf: (Any) -> Any?
    ) -> Any? {
        guard let head = components.first else { return leaf(current) }
        let tail = Array(components.dropFirst())
        if var object = current as? [String: Any] {
            guard let child = object[head] else { return nil }
            if tail.isEmpty {
                if let replacement = leaf(child) {
                    object[head] = replacement
                } else {
                    object.removeValue(forKey: head)
                }
            } else {
                guard let updated = transform(child, components: tail, leaf: leaf) else { return nil }
                object[head] = updated
            }
            return object
        }
        if var array = current as? [Any], let index = Int(head), index >= 0, index < array.count {
            if tail.isEmpty {
                if let replacement = leaf(array[index]) {
                    array[index] = replacement
                } else {
                    array.remove(at: index)
                }
            } else {
                guard let updated = transform(array[index], components: tail, leaf: leaf) else {
                    return nil
                }
                array[index] = updated
            }
            return array
        }
        return nil
    }
}
