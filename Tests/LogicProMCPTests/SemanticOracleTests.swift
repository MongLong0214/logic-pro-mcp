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

    @Test func lengthPrefixedEntryCountChecksUTF8BoundariesAndNumericCount() {
        let entryCount = OracleConstraint.lengthPrefixedEntryCountEquals(
            key: "positions", countKey: "marker_count", offset: 0
        )
        #expect(entryCount.isSatisfied(by: root(#"{"positions":"7:1.1.1.18:12.1.1.1","marker_count":2}"#)))
        #expect(entryCount.isSatisfied(by: root(#"{"positions":"2:é","marker_count":1}"#)))
        #expect(!entryCount.isSatisfied(by: root(#"{"positions":"7:1.1.1.18:12.1.1.1","marker_count":3}"#)))
        #expect(!entryCount.isSatisfied(by: root(#"{"positions":"8:5.1.1.1","marker_count":1}"#)))
        #expect(!entryCount.isSatisfied(by: root(#"{"positions":"7:1.1.1.1","marker_count":1.5}"#)))

        let survivors = OracleConstraint.lengthPrefixedEntryCountEquals(
            key: "positions", countKey: "marker_count_before", offset: -1
        )
        #expect(survivors.isSatisfied(by: root(#"{"positions":"7:1.1.1.1","marker_count_before":2}"#)))
        #expect(!survivors.isSatisfied(by: root(#"{"positions":"7:1.1.1.1","marker_count_before":3}"#)))
    }

    // MARK: - relational constraints (Phase B0)

    @Test func fieldsEqualHoldsWhenTwoKeyPathsAgreeAndFailsWhenTheyDiverge() {
        let object = root(#"{"requested":-6.0,"observed":-6.0,"other":-3.0}"#)
        #expect(OracleConstraint.fieldsEqual(keyA: "requested", keyB: "observed").isSatisfied(by: object))
        #expect(!OracleConstraint.fieldsEqual(keyA: "requested", keyB: "other").isSatisfied(by: object))
        // A missing side can never agree — corrupt inputs fail closed, not open.
        #expect(!OracleConstraint.fieldsEqual(keyA: "requested", keyB: "absent").isSatisfied(by: object))
        #expect(!OracleConstraint.fieldsEqual(keyA: "absent", keyB: "observed").isSatisfied(by: object))
    }

    @Test func readbackArrayExcludesResponseIdentityRequiresAReadableIndependentAbsence() {
        let constraint = OracleConstraint.readbackArrayExcludesResponseIdentity(
            responsePositionKey: "target_position",
            readbackArrayKey: "data",
            readbackPositionKey: "position"
        )
        let response = root(#"{"target_position":"5.1.1.1"}"#)
        let deleted = root(#"{"data":[{"position":"1.1.1.1"},{"position":"12.1.1.1"}]}"#)
        let survives = root(#"{"data":[{"position":"5.1.1.1"}]}"#)
        let renamedSurvivor = root(#"{"data":[{"id":0,"name":"Marker 1","position":"1.1.1.1"}]}"#)

        #expect(constraint.isSatisfied(by: response, readback: deleted))
        #expect(!constraint.isSatisfied(by: response, readback: survives))
        // Auto-rename reuses the target name at index 0; position identity still holds.
        #expect(constraint.isSatisfied(
            by: root(#"{"target_position":"2.1.1.1"}"#),
            readback: renamedSurvivor
        ))
        // A response claim cannot prove its own absence when the independent data records do not
        // answer the position field. An empty data array is not an answer of absence unless
        // the readback itself claims a verified empty list.
        #expect(!constraint.isSatisfied(by: response, readback: root(#"{"data":[{"id":1}]}"#)))
        #expect(!constraint.isSatisfied(by: response, readback: root(#"{"data":[]}"#)))
        #expect(!constraint.isSatisfied(by: response, readback: root(#"{"data":[],"verified_empty":false}"#)))
        #expect(constraint.isSatisfied(by: response, readback: root(#"{"data":[],"verified_empty":true}"#)))
        #expect(!constraint.isSatisfied(by: response, readback: nil))
    }

    /// The same bool-vs-number discipline valueEquals enforces: a requested
    /// boolean `true` must not be satisfied by an observed numeric `1`, or a
    /// mute/arm write's `requested == observed` invariant becomes forgeable.
    @Test func fieldsEqualDoesNotConflateBooleanAndNumericOne() {
        let object = root(#"{"reqBool":true,"obsOne":1,"reqTrue":true,"obsTrue":true}"#)
        #expect(!OracleConstraint.fieldsEqual(keyA: "reqBool", keyB: "obsOne").isSatisfied(by: object))
        #expect(OracleConstraint.fieldsEqual(keyA: "reqTrue", keyB: "obsTrue").isSatisfied(by: object))
    }

    @Test func fieldsEqualComparesStringsAndNestedStructuresPreservingTheDiscipline() {
        let strings = root(#"{"a":"Kick 1","b":"Kick 1","c":"Kick 2"}"#)
        #expect(OracleConstraint.fieldsEqual(keyA: "a", keyB: "b").isSatisfied(by: strings))
        #expect(!OracleConstraint.fieldsEqual(keyA: "a", keyB: "c").isSatisfied(by: strings))
        // Nested containers compare structurally; the bool≠1 rule holds at depth.
        let nested = root(#"{"x":{"v":1,"on":true},"y":{"v":1,"on":true},"z":{"v":1,"on":1}}"#)
        #expect(OracleConstraint.fieldsEqual(keyA: "x", keyB: "y").isSatisfied(by: nested))
        #expect(!OracleConstraint.fieldsEqual(keyA: "x", keyB: "z").isSatisfied(by: nested))
    }

    /// #373 B1 equality-matrix — pins the exact `.fieldsEqual` contract every
    /// safe-mutation oracle's requested==observed check relies on. It
    /// must accept `3`/`3.0` (JSON does not distinguish int/double), reject a
    /// number-vs-string `3`/`"3"`, and — crucially — never read an ABSENT key as
    /// agreement: `null`/missing and `""`/missing both fail closed.
    @Test func fieldsEqualEqualityMatrixPinsTheSafeMutationContract() {
        let eq = OracleConstraint.fieldsEqual(keyA: "a", keyB: "b")
        // 3 / 3.0 → pass.
        #expect(eq.isSatisfied(by: root(#"{"a":3,"b":3.0}"#)))
        // 3 / "3" → fail (a number is not the string "3").
        #expect(!eq.isSatisfied(by: root(#"{"a":3,"b":"3"}"#)))
        // null / missing → fail (a present null cannot agree with an absent key).
        #expect(!eq.isSatisfied(by: root(#"{"a":null}"#)))
        // "" / missing → fail (empty string present; other side absent).
        #expect(!eq.isSatisfied(by: root(#"{"a":""}"#)))
        // The boundary the matrix protects is ABSENCE and TYPE, not a blanket
        // rejection: two PRESENT equal leaves agree — including null==null.
        #expect(eq.isSatisfied(by: root(#"{"a":null,"b":null}"#)))
        #expect(eq.isSatisfied(by: root(#"{"a":"","b":""}"#)))
    }

    // MARK: - numericNear / emptyArray (Phase B1)

    /// The quantized-write invariant: `|observed − requested| ≤ ε`. Equal, within
    /// ε, and exactly on the boundary pass; beyond ε fails. Replaces the
    /// tautological `fieldsEqual(observed, observed_after)` for detent/echo writes.
    @Test func numericNearHoldsWithinToleranceAndFailsBeyondIt() {
        let near = OracleConstraint.numericNear(keyA: "observed", keyB: "requested", within: .absolute(6.0))
        #expect(near.isSatisfied(by: root(#"{"observed":50,"requested":50}"#)))
        #expect(near.isSatisfied(by: root(#"{"observed":48,"requested":50}"#)))
        #expect(near.isSatisfied(by: root(#"{"observed":56,"requested":50}"#)))   // |56−50|=6 ≤ 6
        #expect(!near.isSatisfied(by: root(#"{"observed":57,"requested":50}"#)))  // |57−50|=7 > 6
    }

    /// Same bool-vs-number discipline as the rest of the model: a bool is never
    /// "near" a number, and a non-number / missing key fails closed.
    @Test func numericNearRejectsBoolsNonNumbersAndMissingKeys() {
        let near = OracleConstraint.numericNear(keyA: "a", keyB: "b", within: .absolute(1.0))
        #expect(!near.isSatisfied(by: root(#"{"a":true,"b":1}"#)))
        #expect(!near.isSatisfied(by: root(#"{"a":1,"b":true}"#)))
        #expect(!near.isSatisfied(by: root(#"{"a":1,"b":"1"}"#)))
        #expect(!near.isSatisfied(by: root(#"{"a":1}"#)))
        #expect(!near.isSatisfied(by: root(#"{"b":1}"#)))
    }

    /// `.field` reads the tolerance from the payload's OWN key — the faithful
    /// choice for set_param_verified's per-parameter, unit-specific `tolerance`.
    /// A tighter tolerance fails the same gap; a missing/negative one fails closed.
    @Test func numericNearFieldBoundReadsToleranceFromThePayload() {
        let near = OracleConstraint.numericNear(
            keyA: "observed_normalized", keyB: "requested_normalized", within: .field("tolerance")
        )
        #expect(near.isSatisfied(by: root(#"{"observed_normalized":60.5,"requested_normalized":60,"tolerance":1.0}"#)))
        #expect(!near.isSatisfied(by: root(#"{"observed_normalized":62,"requested_normalized":60,"tolerance":1.0}"#)))
        #expect(!near.isSatisfied(by: root(#"{"observed_normalized":60.5,"requested_normalized":60,"tolerance":0.1}"#)))
        #expect(!near.isSatisfied(by: root(#"{"observed_normalized":60,"requested_normalized":60}"#)))
        #expect(!near.isSatisfied(by: root(#"{"observed_normalized":60,"requested_normalized":60,"tolerance":-1}"#)))
    }

    @Test func emptyArrayAcceptsEmptyAndRejectsNonEmptyMissingAndNonArrays() {
        #expect(OracleConstraint.emptyArray(key: "x").isSatisfied(by: root(#"{"x":[]}"#)))
        #expect(!OracleConstraint.emptyArray(key: "x").isSatisfied(by: root(#"{"x":[1]}"#)))
        #expect(!OracleConstraint.emptyArray(key: "x").isSatisfied(by: root(#"{"x":{}}"#)))
        #expect(!OracleConstraint.emptyArray(key: "x").isSatisfied(by: root(#"{"y":[]}"#)))
    }

    /// numericNear is a VALUE constraint (it asserts a concrete agreement between
    /// two observed numbers); emptyArray is a shape/cardinality check like
    /// nonEmptyArray, so the strength gate still bites on a presence-only oracle.
    @Test func numericNearIsValueBearingAndEmptyArrayIsNot() {
        #expect(OracleConstraint.numericNear(keyA: "a", keyB: "b", within: .absolute(1)).isValueConstraint)
        #expect(!OracleConstraint.emptyArray(key: "a").isValueConstraint)
    }

    // MARK: - booleanFlipped (Phase B2 — verified toggles)

    /// The verified-toggle invariant: `observed == !previous`. A genuine flip
    /// (true/false or false/true) passes; two equal bools fail; a missing side
    /// fails closed. This is what proves a toggle CHANGED state, not a no-op that
    /// still reported success.
    @Test func booleanFlippedHoldsForNegationAndFailsForEqualOrMissing() {
        let flip = OracleConstraint.booleanFlipped(keyA: "observed", keyB: "previous")
        #expect(flip.isSatisfied(by: root(#"{"observed":true,"previous":false}"#)))
        #expect(flip.isSatisfied(by: root(#"{"observed":false,"previous":true}"#)))
        // Two equal bools are not a flip — a no-op reporting success is caught.
        #expect(!flip.isSatisfied(by: root(#"{"observed":true,"previous":true}"#)))
        #expect(!flip.isSatisfied(by: root(#"{"observed":false,"previous":false}"#)))
        // A missing side can never be a negation — corrupt inputs fail closed.
        #expect(!flip.isSatisfied(by: root(#"{"observed":true}"#)))
        #expect(!flip.isSatisfied(by: root(#"{"previous":false}"#)))
    }

    /// Same CFBoolean discipline as the rest of the model: a numeric `0`/`1` is
    /// NOT the negation of a bool, so `observed:1` never satisfies the flip even
    /// though NSNumber bridges `1` and `true`. Otherwise every toggle's
    /// "it changed" proof would be forgeable with an integer.
    @Test func booleanFlippedRejectsNumericOneAsABoolean() {
        let flip = OracleConstraint.booleanFlipped(keyA: "observed", keyB: "previous")
        #expect(!flip.isSatisfied(by: root(#"{"observed":1,"previous":false}"#)))
        #expect(!flip.isSatisfied(by: root(#"{"observed":true,"previous":0}"#)))
        #expect(!flip.isSatisfied(by: root(#"{"observed":1,"previous":0}"#)))
    }

    /// booleanFlipped is VALUE-bearing (it asserts a concrete cross-field
    /// relation between two observed bools), so an oracle carrying only a
    /// booleanFlipped survives the anti-checkbox strength gate.
    @Test func booleanFlippedIsValueBearing() {
        #expect(OracleConstraint.booleanFlipped(keyA: "a", keyB: "b").isValueConstraint)
        let flipOnly = OperationOracle(
            .transportPlay,
            strength: .shapeAndDomain,
            constraints: [.booleanFlipped(keyA: "observed", keyB: "previous")]
        )
        #expect(flipOnly.isSemanticallyLoadBearing)
    }

    /// Every mutant the generic harness derives for a booleanFlipped (flip-same
    /// on either side, numeric-1 in place of a bool, and the generic key drop)
    /// MUST sink the oracle — the same proof the table-driven B2 toggle oracles
    /// rely on.
    @Test func booleanFlippedMutantsAreAllRejected() throws {
        let response = #"{"observed":true,"previous":false}"#
        let rootValue = try #require(JSONInspector.parse(Data(response.utf8)))
        let constraint = OracleConstraint.booleanFlipped(keyA: "observed", keyB: "previous")
        let oracle = OperationOracle(.transportPlay, strength: .shapeAndDomain, constraints: [constraint])

        let baseline = try #require(oracle.evaluate(
            responseData: Data(response.utf8), readbackData: Data("{}".utf8)))
        #expect(baseline)

        let mutants = JSONMutator.mutants(for: constraint, in: rootValue)
        #expect(mutants.count >= 3, "expected drop + flip-same + non-bool mutants, got \(mutants.count)")
        for mutant in mutants {
            let data = try #require(JSONMutator.encode(mutant.json))
            let survived: Bool = oracle.evaluate(
                responseData: data, readbackData: Data("{}".utf8)) == true
            #expect(!survived, "booleanFlipped survived mutant [\(mutant.label)]")
        }
    }

    @Test func crossCheckAgreesAcrossPayloadsAndFailsOnDivergenceOrMissingReadback() {
        let response = root(#"{"value":-6.0,"name":"Bass"}"#)
        let constraint = OracleConstraint.crossCheck(responseKey: "value", readbackKey: "observed_value")
        #expect(constraint.isSatisfied(by: response, readback: root(#"{"observed_value":-6.0}"#)))
        #expect(!constraint.isSatisfied(by: response, readback: root(#"{"observed_value":-3.0}"#)))
        // Fail closed: an absent readback is not a pass.
        #expect(!constraint.isSatisfied(by: response, readback: nil))
        // A readback missing the cross-checked key is a divergence, not a pass.
        #expect(!constraint.isSatisfied(by: response, readback: root(#"{"other":-6.0}"#)))
    }

    @Test func crossCheckDoesNotConflateBooleanAndNumericOneAcrossPayloads() {
        let response = root(#"{"flag":true}"#)
        let constraint = OracleConstraint.crossCheck(responseKey: "flag", readbackKey: "mirror")
        #expect(!constraint.isSatisfied(by: response, readback: root(#"{"mirror":1}"#)))
        #expect(constraint.isSatisfied(by: response, readback: root(#"{"mirror":true}"#)))
    }

    /// Through the full Data path: `evaluate` parses the readback, so an
    /// unparseable readback resolves to nil and `.crossCheck` fails closed rather
    /// than laundering an unverifiable read into a pass.
    @Test func crossCheckOracleFailsClosedWhenReadbackIsUnparseable() throws {
        let oracle = OperationOracle(
            .transportPlay,
            strength: .shapeAndDomain,
            constraints: [.crossCheck(responseKey: "value", readbackKey: "value")]
        )
        let agreed = try #require(oracle.evaluate(
            responseData: Data(#"{"value":1}"#.utf8),
            readbackData: Data(#"{"value":1}"#.utf8)
        ))
        #expect(agreed)
        let failedClosed: Bool = oracle.evaluate(
            responseData: Data(#"{"value":1}"#.utf8),
            readbackData: Data("not json".utf8)
        ) == true
        #expect(!failedClosed)
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

    /// The mirror image, generalized for the #373 B1 DUAL census: an oracle must
    /// map to a SUPPORTED spec — the fully-covered read-only surface UNION the
    /// mutating surface. An oracle outside that union is dead weight (no spec) or
    /// bound to an `.unsupported` spec, either of which would never run.
    @Test func everyOracleMapsToASupportedSpec() {
        let extra = Set(SemanticOracleTable.byOperationID.keys)
            .subtracting(SemanticOracleTable.supportedOracleSurface)
        #expect(
            extra.isEmpty,
            "oracles with no supported (read-only or mutating) spec: \(extra.map(\.rawValue).sorted())"
        )
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
    @Test func reconciledReadOnlySurfaceIsTwentyTwoOperations() {
        #expect(SemanticOracleTable.coveredSpecIDs.count == 22)
        #expect(!SemanticOracleTable.coveredSpecIDs.contains(.editSelectAll))
        #expect(SemanticOracleTable.coveredSpecIDs.contains(.systemClearTraces))

        let selectAll = OperationRegistry.specs.first { $0.id == .editSelectAll }
        #expect(selectAll?.mutability == .mutating)
        let clearTraces = OperationRegistry.specs.first { $0.id == .systemClearTraces }
        #expect(clearTraces?.mutability == .readOnly)
        let refreshCache = OperationRegistry.specs.first { $0.id == .systemRefreshCache }
        #expect(refreshCache?.mutability == .readOnly)
    }

    // MARK: - #373 Phase B1 — mutating-surface increment (dual census)

    /// The mutating oracles present are EXACTLY the declared increment (B1 UNION
    /// B2 UNION B3 UNION B4) — no accidental add or drop. Pinning the set (not just
    /// a count) is what makes the increment a deliberate, reviewable diff. B1, B2,
    /// B3 and B4 are each pinned by count so a premature or miscounted oracle in any
    /// fails here.
    /// B2 went 15 -> 16 and the total 48 -> 49 when `navigate.delete_marker` stopped being
    /// structurally unverifiable: its chain is accessibility-only, and that path reads the
    /// surviving marker set back, so it has a State A to pin and an oracle to pin it with.
    @Test func mutatingOraclesAreExactlyTheDeclaredIncrement() {
        let mutatingOracles = Set(SemanticOracleTable.byOperationID.keys)
            .intersection(SemanticOracleTable.mutatingSpecIDs)
        #expect(mutatingOracles == SemanticOracleTable.coveredMutatingOperationIDs)
        #expect(SemanticOracleTable.phaseB1MutatingOperationIDs.count == 12)
        #expect(SemanticOracleTable.phaseB2MutatingOperationIDs.count == 16)
        #expect(SemanticOracleTable.phaseB3MutatingOperationIDs.count == 15)
        #expect(SemanticOracleTable.phaseB4MutatingOperationIDs.count == 6)
        // B1, B2, B3 and B4 are PAIRWISE-DISJOINT increments — no op claimed twice.
        let increments = [
            SemanticOracleTable.phaseB1MutatingOperationIDs,
            SemanticOracleTable.phaseB2MutatingOperationIDs,
            SemanticOracleTable.phaseB3MutatingOperationIDs,
            SemanticOracleTable.phaseB4MutatingOperationIDs,
        ]
        for i in increments.indices {
            for j in increments.indices where j > i {
                #expect(
                    increments[i].isDisjoint(with: increments[j]),
                    "increments \(i + 1) and \(j + 1) overlap"
                )
            }
        }
        // 49 through B4, plus the one registered after the inventory closed (#575).
        #expect(SemanticOracleTable.coveredMutatingOperationIDs.count == 50)
    }

    /// #373 B4 — the mutating oracle inventory is CLOSED. Every supported
    /// (non-`.unsupported`) mutating spec is EITHER covered by an oracle OR carries
    /// an audited structural exclusion — the two partition the entire mutating
    /// surface, with no implicit residual. This is the ticket's terminal invariant:
    /// after B4 there is no mutating op left silently uncovered. (The two sets are
    /// proven disjoint here too, so an op can never be both covered and excluded.)
    @Test func everyMutatingSpecIsCoveredOrAuditedExcluded() {
        let covered = SemanticOracleTable.coveredMutatingOperationIDs
        let excluded = Set(SemanticOracleTable.structurallyUnverifiedMutatingOperationIDs.keys)
        #expect(covered.isDisjoint(with: excluded))
        #expect(covered.union(excluded) == SemanticOracleTable.mutatingSpecIDs)
        // The complement is empty: nothing supported-mutating is unaccounted for.
        let unaccounted = SemanticOracleTable.mutatingSpecIDs
            .subtracting(covered)
            .subtracting(excluded)
        #expect(
            unaccounted.isEmpty,
            "mutating specs neither covered nor excluded: \(unaccounted.map(\.rawValue).sorted())"
        )
    }

    /// Soundness of the increment: every id in B1..B4 is a REAL `.mutating`,
    /// non-`.unsupported` registry spec — a read-only id or a typo cannot
    /// masquerade as mutating coverage.
    @Test func everyCoveredMutatingIDIsARealMutatingSpec() {
        #expect(
            SemanticOracleTable.coveredMutatingOperationIDs
                .isSubset(of: SemanticOracleTable.mutatingSpecIDs)
        )
        for id in SemanticOracleTable.coveredMutatingOperationIDs {
            let spec = OperationRegistry.specs.first { $0.id == id }
            #expect(spec?.mutability == .mutating, "\(id.rawValue) is not mutating")
            #expect(spec?.availability != .unsupported, "\(id.rawValue) is unsupported")
        }
    }

    /// The COVERED set stays below parity with the mutating surface — and after B4
    /// that gap is PERMANENT, not future work: the complement is entirely audited
    /// structural exclusions (send-only / no-State-A ops), NOT ops awaiting an
    /// oracle. `everyMutatingSpecIsCoveredOrAuditedExcluded` proves covered ∪
    /// excluded == the whole surface, so this "covered < total" is the honest
    /// statement that some mutating ops are structurally unverifiable, never a TODO.
    /// If a currently-excluded op ever gains a State-A path (so covered could grow),
    /// that is a deliberate move of an id from the exclusion map into an increment.
    @Test func mutatingCoverageIsIncrementalNotYetComplete() {
        let covered = Set(SemanticOracleTable.byOperationID.keys)
            .intersection(SemanticOracleTable.mutatingSpecIDs)
        #expect(covered.count < SemanticOracleTable.mutatingSpecIDs.count)
        // mixer.set_plugin_param is the canonical structurally-excluded case: it is
        // a send-only State-B write (Scripter), so it has no State A to verify and
        // deliberately carries no verified-write oracle.
        #expect(!covered.contains(.mixerSetPluginParam))
        #expect(SemanticOracleTable.mutatingSpecIDs.contains(.mixerSetPluginParam))
        // And it is honestly accounted for in the exclusion map, not left implicit.
        #expect(SemanticOracleTable.structurallyUnverifiedMutatingOperationIDs[.mixerSetPluginParam] != nil)
    }

    /// FIX 5 — the structural-exclusion allowlist is EXPLICIT: every entry is a
    /// real mutating spec, is DISJOINT from the covered increment (B1 ∪ B2 ∪ B3 ∪
    /// B4), and carries a reason, so the uncovered surface is a reviewed decision,
    /// not implicit. B4 adds the 13 send-only edit ops with no State A.
    @Test func structuralExclusionsAreExplicitDisjointAndReasoned() {
        let exclusions = SemanticOracleTable.structurallyUnverifiedMutatingOperationIDs
        #expect(!exclusions.isEmpty)
        #expect(exclusions[.mixerSetPluginParam] != nil)
        // The four B2 send-only ops that structurally cannot reach State A.
        for id in [
            OperationID.transportRewind, .transportFastForward,
            .navigateZoomToFit, .navigateToggleView,
        ] {
            #expect(exclusions[id] != nil, "\(id.rawValue) missing its send-only exclusion reason")
        }
        #expect(exclusions[.navigateDeleteMarker] == nil)
        #expect(SemanticOracleTable.coveredMutatingOperationIDs.contains(.navigateDeleteMarker))
        // The B3 audited exclusions: project lifecycle ops with no State A
        // (new/open/close State-B ceiling, launch/quit prose), the send-only
        // tracks.duplicate, and the send-only midi surface (a representative
        // subset — the generic loop below validates all 38 entries).
        for id in [
            OperationID.projectNew, .projectOpen, .projectClose,
            .projectLaunch, .projectQuit, .tracksDuplicate,
            .midiSendNote, .midiSendChord, .midiSendCC, .midiSendProgramChange,
            .midiSendPitchBend, .midiSendAftertouch, .midiSendSysEx,
            .midiPlaySequence, .midiStepInput, .midiCreateVirtualPort,
            .midiMMCPlay, .midiMMCStop, .midiMMCRecord,
        ] {
            #expect(exclusions[id] != nil, "\(id.rawValue) missing its B3 exclusion reason")
        }
        // The 13 B4 send-only edit exclusions. edit.toggle_step_input is COVERED
        // (its AX chain reaches State A), so it must NOT appear in the exclusion map.
        for id in [
            OperationID.editUndo, .editRedo, .editCut, .editCopy, .editPaste,
            .editDelete, .editSelectAll, .editSplit, .editJoin, .editQuantize,
            .editBounceInPlace, .editNormalize, .editDuplicate,
        ] {
            #expect(exclusions[id] != nil, "\(id.rawValue) missing its B4 edit exclusion reason")
        }
        #expect(
            exclusions[.editToggleStepInput] == nil,
            "edit.toggle_step_input is covered, not excluded"
        )
        for (id, reason) in exclusions {
            #expect(SemanticOracleTable.mutatingSpecIDs.contains(id), "\(id.rawValue) is not a mutating spec")
            #expect(
                !SemanticOracleTable.coveredMutatingOperationIDs.contains(id),
                "\(id.rawValue) is both covered and excluded"
            )
            #expect(reason.count > 20, "\(id.rawValue) exclusion reason is too thin")
        }
    }

    /// set_cycle_range is excluded a level EARLIER than the structural list: it is
    /// registry `.unsupported`, so `mutatingSpecIDs` (which filters `.unsupported`)
    /// never surfaces it, and it can carry no oracle. Its exclusion is documented
    /// explicitly + reasoned, NOT left implicit in the availability filter.
    @Test func unsupportedExclusionsAreDocumentedAndFilteredOut() {
        let unsupported = SemanticOracleTable.unsupportedExcludedMutatingOperationIDs
        #expect(unsupported[.transportSetCycleRange] != nil)
        for (id, reason) in unsupported {
            let spec = OperationRegistry.specs.first { $0.id == id }
            // Registered mutating, but `.unsupported` — so filtered from the surface.
            #expect(spec?.mutability == .mutating, "\(id.rawValue) is not a mutating spec")
            #expect(spec?.availability == .unsupported, "\(id.rawValue) is not .unsupported")
            #expect(!SemanticOracleTable.mutatingSpecIDs.contains(id), "\(id.rawValue) leaked into the surface")
            #expect(!SemanticOracleTable.supportedOracleSurface.contains(id))
            #expect(SemanticOracleTable.byOperationID[id] == nil, "\(id.rawValue) must carry no oracle")
            #expect(reason.count > 20, "\(id.rawValue) exclusion reason is too thin")
        }
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

    /// Phase B0: the relational constraints are VALUE-bearing, so an oracle
    /// carrying only a `fieldsEqual` or `crossCheck` (and no `valueEquals`) still
    /// passes the anti-checkbox gate — the gate must not force a redundant
    /// constant onto a mutation oracle whose real check is the agreement.
    @Test func relationalConstraintsAreValueBearingAndSurviveTheStrengthGate() {
        #expect(OracleConstraint.fieldsEqual(keyA: "a", keyB: "b").isValueConstraint)
        #expect(OracleConstraint.crossCheck(responseKey: "a", readbackKey: "b").isValueConstraint)

        let fieldsEqualOnly = OperationOracle(
            .transportPlay,
            strength: .shapeAndDomain,
            constraints: [.fieldsEqual(keyA: "requested", keyB: "observed")]
        )
        #expect(fieldsEqualOnly.isSemanticallyLoadBearing)

        let crossCheckOnly = OperationOracle(
            .transportPlay,
            strength: .shapeAndDomain,
            constraints: [.crossCheck(responseKey: "value", readbackKey: "value")]
        )
        #expect(crossCheckOnly.isSemanticallyLoadBearing)

        // Shape-only constraints remain non-value-bearing — the gate still bites.
        #expect(!OracleConstraint.typedField(key: "a", type: .string).isValueConstraint)
        #expect(!OracleConstraint.nonEmptyArray(key: "a").isValueConstraint)
    }

    private static func isExactValue(_ constraint: OracleConstraint) -> Bool {
        if case .valueEquals = constraint { return true }
        return false
    }
}

// MARK: - fixtures + mutation harness

@Suite("#373 semantic oracle fixtures and mutation")
struct SemanticOracleMutationTests {
    @Test func pluginSetParamVerifiedOracleAcceptsCheckboxStateAWithoutWeakeningSliderStateA() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.pluginsSetParamVerified])
        let sliderFixture = try #require(SemanticOracleFixtures.byOperationID[.pluginsSetParamVerified])
        let sliderAccepted = try #require(oracle.evaluate(
            responseData: sliderFixture.responseData,
            readbackData: sliderFixture.readbackData
        ))
        let checkbox = Data(#"{"success":true,"verified":true,"state":"A","hc_schema":2,"operation":"logic_plugins.set_param_verified","target_identity":{"track":0,"insert":0,"plugin_id":"logic.stock.effect.compressor"},"param":"limiter_on","requested_normalized":1,"observed_normalized":1,"requested_boolean":true,"observed_boolean":true,"write_source":"ax_controls_view_checkbox","verify_source":"ax_controls_view_checkbox"}"#.utf8)
        let checkboxAccepted = try #require(oracle.evaluate(
            responseData: checkbox,
            readbackData: Data("{}".utf8)
        ))
        let sliderWithoutToleranceAccepted = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","hc_schema":2,"operation":"logic_plugins.set_param_verified","target_identity":{},"param":"threshold","requested_normalized":60,"observed_normalized":60,"display_unit":"%","write_source":"ax_plugin_window","verify_source":"ax_plugin_window"}"#.utf8),
            readbackData: Data("{}".utf8)
        ))
        let checkboxMismatchAccepted = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","hc_schema":2,"operation":"logic_plugins.set_param_verified","target_identity":{},"param":"limiter_on","requested_boolean":true,"observed_boolean":false,"write_source":"ax_controls_view_checkbox","verify_source":"ax_controls_view_checkbox"}"#.utf8),
            readbackData: Data("{}".utf8)
        ))
        let sliderStillRequiresTolerance = !sliderWithoutToleranceAccepted
        let checkboxRequiresMatchingBools = !checkboxMismatchAccepted
        #expect(sliderAccepted)
        #expect(checkboxAccepted)
        #expect(sliderStillRequiresTolerance)
        #expect(checkboxRequiresMatchingBools)
    }

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

    @Test("Solo keyboard State A passes qualification")
    func soloKeyboardStateAPassesQualification() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.tracksSolo])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.tracksSolo])
        #expect(oracle.evaluate(
            responseData: fixture.responseData,
            readbackData: fixture.readbackData
        )!)
    }

    /// #373 B2 — toggle_metronome is uniquely channel-INDEPENDENT: its verified
    /// State A arrives in two shapes with DISJOINT keys — AX-verified (flip on
    /// observed/previous, plus button/control/action) and dispatcher-verified via
    /// the keycmd/cgEvent fallback (flip on observed_enabled/previous_enabled +
    /// verification_source, and NO button/control/action). The relaxed oracle must
    /// accept BOTH — pinning button/control/action would FALSE-RED the keycmd-bound,
    /// AX-control-absent setup in the #284 matrix — while still rejecting a no-op
    /// (honest State B) and a failure (State C). This is what keeps the relaxed
    /// oracle non-vacuous: the toggle-changed proof is structural (neither shape
    /// reaches State A without a confirmed flip), and the envelope rejects every
    /// non-State-A result.
    @Test func metronomeOracleAcceptsBothChannelShapesYetRejectsNoOpOrFailure() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.transportToggleMetronome])

        // AX-verified State A: control-bar checkbox flipped (observed != previous).
        let axVerified = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","button":"Metronome","control":"메트로놈 클릭","observed":true,"previous":false,"action":"axpress","attempts":["axpress"]}"#.utf8),
            readbackData: Data("{}".utf8)))
        #expect(axVerified, "metronome oracle rejected the AX-verified State A shape")

        // Dispatcher-verified State A via the keycmd fallback (AX control absent):
        // NO button/control/action; the flip is on observed_enabled/previous_enabled.
        // This is the shape the former button/control/action pins false-RED'd.
        let keycmdVerified = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"transport.toggle_metronome","method":"midi_key_command","cc":98,"channel":16,"verification_source":"transport_state","previous_enabled":false,"requested_enabled":true,"observed_enabled":true}"#.utf8),
            readbackData: Data("{}".utf8)))
        #expect(keycmdVerified, "metronome oracle false-RED the dispatcher-verified keycmd State A")

        // No-op: finalize could not confirm a flip (observed_enabled == previous_enabled),
        // so it is honest State B — the envelope must reject it.
        let noOp: Bool = oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":false,"state":"B","reason":"readback_mismatch","operation":"transport.toggle_metronome","verification_source":"transport_state","previous_enabled":true,"requested_enabled":false,"observed_enabled":true}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!noOp, "metronome oracle accepted a no-op State B result")

        // Failure: State C must never launder into a semantic pass.
        let failure: Bool = oracle.evaluate(
            responseData: Data(#"{"success":false,"verified":false,"state":"C","error":"element_not_found"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!failure, "metronome oracle accepted a State C failure")
    }

    /// `nav.delete_marker` reaches State A only after the settled marker-list
    /// POSITION multiset equals the pre-write expectation with one instance of
    /// the target position removed. The envelope must bind that equality:
    /// otherwise stable reads, typed counts, and echoed target metadata can
    /// falsely certify a no-op or the deletion of a marker at another position.
    /// `recommend_eq`'s refusal branch, asserted positively — the same omission a review caught in
    /// the get_regions change, where ten negative mutants shipped without one positive case.
    ///
    /// `recommendEQ` declines on analysis_incomplete, confidence_below_minimum, and
    /// source_classification_unknown. It measured and judged the measurement insufficient to cut
    /// safely; declining IS the contract, which is why the handler returns it without `isError`.
    @Test func recommendEQOracleAcceptsASafeRefusalThatNamesItsReason() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.audioRecommendEQ])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.audioRecommendEQ])

        for reason in ["analysis_incomplete", "confidence_below_minimum", "source_classification_unknown"] {
            let refusal = "{\"bands\":[],\"reason\":\"\(reason)\"}"
            let accepted = try #require(oracle.evaluate(
                responseData: Data(refusal.utf8), readbackData: fixture.readbackData))
            #expect(accepted, "safe refusal \(reason) must qualify — declining is the contract")
        }

        // And the recommending branch still qualifies, so widening did not trade one for the other.
        let stillHonest = try #require(oracle.evaluate(
            responseData: fixture.responseData, readbackData: fixture.readbackData))
        #expect(stillHonest, "the recommending branch stopped qualifying")
    }

    /// The branch this oracle was widened FOR, asserted positively.
    ///
    /// A review pointed out that the change shipped seven negative mutants and never once showed
    /// that the response it exists to accept actually passes. Negatives alone are satisfied by an
    /// oracle that rejects everything, which is the opposite failure from the one being fixed.
    ///
    /// This payload is the shape measured live on Logic 12.3 against the empty fixture project:
    /// every region visible, so the read is complete, names the whole arrangement, and has no
    /// limitation to explain.
    @Test func getRegionsOracleAcceptsTheCompleteWholeArrangementBranch() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.projectGetRegions])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.projectGetRegions])

        let complete = """
            {"complete":true,"scope":"whole_arrangement","regions":[],"returned_count":0,\
            "_debug":{"layoutItems":0,"nonRegion":0,"track_headers":1,"track_headers_in_viewport":1}}
            """
        let accepted = try #require(oracle.evaluate(
            responseData: Data(complete.utf8), readbackData: fixture.readbackData))
        #expect(accepted, "the complete/whole_arrangement branch must qualify — it is why this oracle changed")

        // And the branch that already worked still does, so widening did not trade one for the other.
        let stillHonest = try #require(oracle.evaluate(
            responseData: fixture.responseData, readbackData: fixture.readbackData))
        #expect(stillHonest, "the viewport-limited branch stopped qualifying")
    }

    @Test func deleteMarkerOracleRequiresTheExactSettledPositionMultiset() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.navigateDeleteMarker])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.navigateDeleteMarker])

        let honest = try #require(oracle.evaluate(
            responseData: fixture.responseData, readbackData: fixture.readbackData))
        #expect(honest, "delete_marker rejected its honest settled position multiset")

        // Mutation: put the target-position entry back into observed positions.
        // A settled no-op must be rejected even though the rest of State-A's
        // envelope shape is intact.
        let noOp = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":1,"target_name":"Verse","target_position":"5.1.1.1","prewrite_marker_identities":["5:Intro7:1.1.1.1","5:Verse7:5.1.1.1","6:Chorus8:12.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":3,"write_attempted":true,"readback_settled":true,"marker_count_after":3,"expected_survivor_position_multiset":"7:1.1.1.18:12.1.1.1","observed_survivor_position_multiset":"7:1.1.1.17:5.1.1.18:12.1.1.1"}"#.utf8),
            readbackData: fixture.readbackData
        ))
        #expect(!noOp, "delete_marker accepted a settled State A whose position multiset lost no target occurrence")

        // Mutation: replace the expected 12.1.1.1 survivor with the target's
        // 5.1.1.1 position. Count-only validation would accept this wrong delete.
        let wrongPositions = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":1,"target_name":"Verse","target_position":"5.1.1.1","prewrite_marker_identities":["5:Intro7:1.1.1.1","5:Verse7:5.1.1.1","6:Chorus8:12.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":3,"write_attempted":true,"readback_settled":true,"marker_count_after":2,"expected_survivor_position_multiset":"7:1.1.1.18:12.1.1.1","observed_survivor_position_multiset":"7:1.1.1.17:5.1.1.1"}"#.utf8),
            readbackData: fixture.readbackData
        ))
        #expect(!wrongPositions, "delete_marker accepted a settled readback with wrong positions")

        // Mutation: every remaining default marker name shifted down by one after
        // deleting index 0, but their positions are exactly right. An honest
        // `data[]` still carries `{id:0, name:"Marker 1"}` after Logic auto-renames
        // the former Marker 2. Name+index identity treats that as target survival;
        // position identity must not.
        let namesShiftedReadback = Data(#"{"source":"ax_live","readable":true,"position_multiset":"7:1.1.1.17:1.1.1.17:5.1.1.1","positions_canonical":true,"data":[{"id":0,"name":"Marker 1","position":"1.1.1.1","position_source":"parser","is_canonical":true},{"id":1,"name":"Marker 2","position":"1.1.1.1","position_source":"parser","is_canonical":true},{"id":2,"name":"Marker 3","position":"5.1.1.1","position_source":"parser","is_canonical":true}]}"#.utf8)
        let namesShifted = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":0,"target_name":"Marker 1","target_position":"2.1.1.1","prewrite_marker_identities":["8:Marker 17:2.1.1.1","8:Marker 27:1.1.1.1","8:Marker 37:1.1.1.1","8:Marker 47:5.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":4,"write_attempted":true,"readback_settled":true,"marker_count_after":3,"observed_marker_count_before":4,"observed_marker_count_after":3,"expected_survivor_position_multiset":"7:1.1.1.17:1.1.1.17:5.1.1.1","observed_survivor_position_multiset":"7:1.1.1.17:1.1.1.17:5.1.1.1","expected_survivors":["8:Marker 27:1.1.1.1","8:Marker 37:1.1.1.1","8:Marker 47:5.1.1.1"],"observed_survivors":["8:Marker 17:1.1.1.1","8:Marker 27:1.1.1.1","8:Marker 37:5.1.1.1"]}"#.utf8),
            readbackData: namesShiftedReadback
        ))
        #expect(namesShifted, "delete_marker rejected correct positions solely because default names shifted")

        // Reproduction A: a forged target name whose (name, index) pair is absent
        // from the honest Intro/Chorus readback. Name+index identity treated that
        // absence as proof. Names are not identity — this envelope has the same
        // independent position disappearance as the honest Verse fixture, so it
        // cannot be rejected without also rejecting that fixture. Mutation proven:
        // restore name+index identity. The honest Marker 1 rename below then fails.
        var forgedNameObject = try #require(
            JSONSerialization.jsonObject(with: fixture.responseData) as? [String: Any]
        )
        forgedNameObject["target_name"] = "Nope"
        forgedNameObject["prewrite_marker_identities"] = [
            "5:Intro7:1.1.1.1", "4:Nope7:5.1.1.1", "6:Chorus8:12.1.1.1",
        ]
        let forgedNameData = try JSONSerialization.data(withJSONObject: forgedNameObject)
        let forgedName = try #require(oracle.evaluate(
            responseData: forgedNameData,
            readbackData: fixture.readbackData
        ))
        #expect(forgedName, "delete_marker used name+index identity; a forged name with a real position deletion must follow the position proof")

        // Reproduction B: honest delete of Marker 1 at index 0. Logic auto-renames
        // the former Marker 2 to Marker 1 at index 0. Name+index identity rejects
        // the honest delete.
        let honestRename = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":0,"target_name":"Marker 1","target_position":"2.1.1.1","prewrite_marker_identities":["8:Marker 17:2.1.1.1","8:Marker 27:1.1.1.1","8:Marker 37:1.1.1.1","8:Marker 47:5.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":4,"write_attempted":true,"readback_settled":true,"marker_count_after":3,"observed_marker_count_before":4,"observed_marker_count_after":3,"expected_survivor_position_multiset":"7:1.1.1.17:1.1.1.17:5.1.1.1","observed_survivor_position_multiset":"7:1.1.1.17:1.1.1.17:5.1.1.1"}"#.utf8),
            readbackData: namesShiftedReadback
        ))
        #expect(honestRename, "delete_marker rejected an honest delete because a renamed survivor reused the target name at index 0")

        // Mutation: both self-reported multisets carry the same valid wire value,
        // but it contains only one entry while both counts require two. Equality
        // alone would accept this shared arbitrary value.
        let selfReportedMultisets = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":1,"target_name":"Verse","target_position":"5.1.1.1","prewrite_marker_identities":["5:Intro7:1.1.1.1","5:Verse7:5.1.1.1","6:Chorus8:12.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":3,"write_attempted":true,"readback_settled":true,"marker_count_after":2,"expected_survivor_position_multiset":"7:arbitrary","observed_survivor_position_multiset":"7:arbitrary"}"#.utf8),
            readbackData: fixture.readbackData
        ))
        #expect(!selfReportedMultisets, "delete_marker accepted equal multiset fields whose entry counts contradict the marker counts")

        // Mutation applied once: remove `lengthPrefixedEntriesExclude` from the delete-marker
        // oracle. This envelope passes every other State-A check — including the independent
        // resource cross-check — while describing the survival of the requested 1.1.1.1 target.
        let targetSurvives = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":0,"target_name":"Intro","target_position":"1.1.1.1","prewrite_marker_identities":["5:Intro7:1.1.1.1","5:Verse7:5.1.1.1","6:Chorus8:12.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":3,"write_attempted":true,"readback_settled":true,"marker_count_after":2,"expected_survivor_position_multiset":"7:1.1.1.18:12.1.1.1","observed_survivor_position_multiset":"7:1.1.1.18:12.1.1.1"}"#.utf8),
            readbackData: fixture.readbackData
        ))
        #expect(!targetSurvives, "delete_marker accepted an internally consistent State A where the target position survived")

        // The settled positions prove that Verse at 5.1.1.1 disappeared, but this envelope claims
        // the request was index 0 / Intro. Before the binding below, the typed request fields were
        // unrelated to the observed disappearance and this otherwise well-formed envelope passed.
        let wrongClaimedIdentity = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":0,"target_name":"Intro","target_position":"5.1.1.1","prewrite_marker_identities":["5:Intro7:1.1.1.1","5:Verse7:5.1.1.1","6:Chorus8:12.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":3,"write_attempted":true,"readback_settled":true,"marker_count_after":2,"expected_survivor_position_multiset":"7:1.1.1.18:12.1.1.1","observed_survivor_position_multiset":"7:1.1.1.18:12.1.1.1"}"#.utf8),
            readbackData: fixture.readbackData
        ))
        #expect(!wrongClaimedIdentity, "delete_marker accepted a position deletion attributed to a different requested marker")

        // Mutation proven: remove `.readbackArrayExcludesResponseIdentity(...)` from the
        // delete-marker oracle. Every other field below is self-consistent, but the independent
        // `data[]` still contains the claimed target position. Without that one oracle line this
        // envelope evaluates true even though 5.1.1.1 survived independently.
        let wrongEnvelopeOnlyIdentity = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":1,"target_name":"Verse","target_position":"5.1.1.1","prewrite_marker_identities":["5:Intro7:1.1.1.1","5:Verse7:5.1.1.1","6:Chorus8:12.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":3,"write_attempted":true,"readback_settled":true,"marker_count_after":2,"expected_survivor_position_multiset":"7:1.1.1.18:12.1.1.1","observed_survivor_position_multiset":"7:1.1.1.18:12.1.1.1"}"#.utf8),
            readbackData: Data(#"{"source":"ax_live","readable":true,"verified_empty":false,"position_multiset":"7:1.1.1.18:12.1.1.1","positions_canonical":true,"data":[{"id":0,"name":"Intro","position":"1.1.1.1","position_source":"parser","is_canonical":true},{"id":1,"name":"Verse","position":"5.1.1.1","position_source":"parser","is_canonical":true}]}"#.utf8)
        ))
        #expect(!wrongEnvelopeOnlyIdentity, "delete_marker accepted a target position that the independent readback still contains")

        // Source mutation applied once: remove both `crossCheck` constraints from the
        // delete-marker oracle. This response is internally consistent and contains no target
        // position, but its reported survivor set is unrelated to the independent marker resource.
        let substitutedSurvivors = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"nav.delete_marker","requested_index":1,"target_name":"Verse","target_position":"5.1.1.1","prewrite_marker_identities":["5:Intro7:1.1.1.1","5:Verse7:5.1.1.1","6:Chorus8:12.1.1.1"],"target_position_unique":true,"position_evidence_canonical":true,"marker_count_before":3,"write_attempted":true,"readback_settled":true,"marker_count_after":2,"expected_survivor_position_multiset":"7:2.1.1.17:3.1.1.1","observed_survivor_position_multiset":"7:2.1.1.17:3.1.1.1"}"#.utf8),
            readbackData: fixture.readbackData
        ))
        #expect(!substitutedSurvivors, "delete_marker accepted a survivor multiset unrelated to its independent readback")

        let nonCanonicalReadback = Data(#"{"source":"ax_live","readable":true,"position_multiset":"7:1.1.1.18:12.1.1.1","positions_canonical":false,"data":[]}"#.utf8)
        let canonicalityWasOnlySelfReported = try #require(oracle.evaluate(
            responseData: fixture.responseData,
            readbackData: nonCanonicalReadback
        ))
        #expect(!canonicalityWasOnlySelfReported, "delete_marker accepted a self-reported canonicality flag contrary to readback")

        // #549 BLOCKER follow-up: `observed_marker_count_before`/`_after` were presence-only
        // (`.typedField`) — any count pair satisfied them. Mutation proven: drop
        // `.numericEqualsOffset` (the AFTER == BEFORE - 1 pin) from the oracle. Both envelopes
        // below evaluate true today with only `.typedField` in place; each carries the honest
        // fixture's `observed_marker_count_before: 3` but a corrupted after-count that either
        // claims no drop occurred (3, unchanged) or is disconnected from the before-count
        // entirely (99).
        var noDropCountsObject = try #require(
            JSONSerialization.jsonObject(with: fixture.responseData) as? [String: Any]
        )
        noDropCountsObject["observed_marker_count_after"] = 3
        let noDropCounts = try #require(oracle.evaluate(
            responseData: try JSONSerialization.data(withJSONObject: noDropCountsObject),
            readbackData: fixture.readbackData
        ))
        #expect(!noDropCounts, "delete_marker accepted an observed after-count equal to the before-count (no drop)")

        var wildCountsObject = try #require(
            JSONSerialization.jsonObject(with: fixture.responseData) as? [String: Any]
        )
        wildCountsObject["observed_marker_count_after"] = 99
        let wildCounts = try #require(oracle.evaluate(
            responseData: try JSONSerialization.data(withJSONObject: wildCountsObject),
            readbackData: fixture.readbackData
        ))
        #expect(!wildCounts, "delete_marker accepted an observed after-count unrelated to the before-count")

        // The companion pin — the pre-write witness must equal the table's own pre-write
        // inventory size — is symmetric: a producer could otherwise report ANY
        // `observed_marker_count_before`, as long as `_after` happens to be one less than IT,
        // and still pass every other State-A gate. Mutation proven: drop `.fieldsEqual(
        // observed_marker_count_before, marker_count_before)` from the oracle.
        var staleBeforeCountObject = try #require(
            JSONSerialization.jsonObject(with: fixture.responseData) as? [String: Any]
        )
        staleBeforeCountObject["observed_marker_count_before"] = 4
        staleBeforeCountObject["observed_marker_count_after"] = 3
        let staleBeforeCount = try #require(oracle.evaluate(
            responseData: try JSONSerialization.data(withJSONObject: staleBeforeCountObject),
            readbackData: fixture.readbackData
        ))
        #expect(!staleBeforeCount, "delete_marker accepted a pre-write witness that disagreed with the table's own pre-write inventory size")
    }

    /// #373 B3 — project.save_as is envelope-only because its
    /// [.accessibility, .appleScript] chain reaches State A in two shapes with
    /// DISJOINT non-envelope keys (AX-dialog: requested/observed/via; AppleScript:
    /// operation/method/path/observed). The oracle must accept BOTH yet reject a
    /// State B (write unconfirmed) and a State C (write failed) — the
    /// transport.stop / toggle_metronome precedent, proving the envelope-only
    /// oracle is not vacuous (its "the file was written" proof is the structural
    /// State-A gate, which both channels reach only after confirming the package
    /// on disk).
    @Test func saveAsOracleAcceptsBothChannelShapesYetRejectsUnverified() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.projectSaveAs])
        // AX-dialog State A (requested/observed/via; no operation/method).
        let axDialog = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","requested":"/x/Demo.logicx","observed":"/x/Demo.logicx","via":"save-dialog-with-ext"}"#.utf8),
            readbackData: Data("{}".utf8)))
        #expect(axDialog, "save_as oracle rejected the AX-dialog State A shape")
        // AppleScript State A (operation/method/path/observed; no requested/via).
        let appleScript = try #require(oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"project.save_as","method":"applescript","path":"/x/Demo.logicx","observed":"/x/Demo.logicx","observed_mtime":"1970-01-01T00:00:02Z"}"#.utf8),
            readbackData: Data("{}".utf8)))
        #expect(appleScript, "save_as oracle false-RED the AppleScript State A shape")
        // State B: the write landed but the package could not be confirmed.
        let stateB: Bool = oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":false,"state":"B","reason":"readback_mismatch","operation":"project.save_as"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!stateB, "save_as oracle accepted a State B result")
        // State C: the write failed outright.
        let stateC: Bool = oracle.evaluate(
            responseData: Data(#"{"success":false,"verified":false,"state":"C","error":"ax_write_failed"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!stateC, "save_as oracle accepted a State C failure")
    }

    /// #373 B3 — record_sequence is the one covered op that does NOT emit an
    /// `encodeStateA` envelope: its verified payload carries `success`+`verified`
    /// but no `state` field (hand-assembled via jsonToolTextResult). The oracle
    /// pins success+verified as the verified-write proof and the REGION-READBACK
    /// match (start/end bars == the expected envelope). A region that landed at
    /// the wrong bar envelope, or an unverified/failed import, must be rejected.
    @Test func recordSequenceOracleRejectsWrongRegionAndUnverifiedImport() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.tracksRecordSequence])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.tracksRecordSequence])
        let good = try #require(oracle.evaluate(
            responseData: fixture.responseData, readbackData: fixture.readbackData))
        #expect(good, "record_sequence oracle rejected its own verified fixture")
        // Region read back at the wrong end bar (end_bar 9 != expected_end_bar 3).
        let wrongEnd: Bool = oracle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"method":"smf_import","expected_start_bar":1,"expected_end_bar":3,"start_bar":1,"end_bar":9,"target_track_index":3,"created_track":3,"verify_source":"ax_region_delta","note_count":4,"region_name":"MIDI Region"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!wrongEnd, "record_sequence accepted a region at the wrong end bar")
        // A timing_mismatch failure payload (verified:false) must be rejected.
        let unverified: Bool = oracle.evaluate(
            responseData: Data(#"{"success":false,"verified":false,"error":"timing_mismatch","method":"smf_import","expected_start_bar":1,"expected_end_bar":3,"start_bar":1,"end_bar":9,"target_track_index":3,"created_track":3,"verify_source":"ax_region_delta","note_count":4,"region_name":"MIDI Region"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!unverified, "record_sequence accepted an unverified import")
    }

    /// #373 B3 — RED evidence for representative oracles: each REJECTS the
    /// semantically-wrong result it exists to catch. A VALUE-BEARING one
    /// (saga_execute rejects a saga that did NOT complete), COUNT ones
    /// (tracks.delete rejects a delete that did not reduce the count; create_audio
    /// rejects the wrong track type), and a STRUCTURAL one (export_support_bundle
    /// rejects an empty file manifest). The good-leg (each fixture passes) is the
    /// parameterized `oraclePassesItsRealisticFixture`; these are the bad-legs.
    @Test func phaseB3RepresentativeOraclesRejectSemanticMutations() throws {
        // VALUE-BEARING: saga_execute rejects a non-completed saga_state.
        let saga = try #require(SemanticOracleTable.byOperationID[.systemSagaExecute])
        let notCompleted: Bool = saga.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","journal_scope":"session","journal_survives_process_restart":false,"saga_state":"partiallyApplied","idempotency_key":"k","steps":[],"state_history":[]}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!notCompleted, "saga_execute accepted a non-completed saga_state")
        // COUNT: tracks.delete rejects a zero count-delta (nothing was deleted).
        let delete = try #require(SemanticOracleTable.byOperationID[.tracksDelete])
        let noDecrement: Bool = delete.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","menu_clicked":"트랙 삭제","track_count_before":3,"requested_delta":-1,"track_count_after":3,"observed_delta":0}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!noDecrement, "tracks.delete accepted a zero count-delta")
        // COUNT/TYPE: create_audio rejects a create that produced a drummer track.
        let createAudio = try #require(SemanticOracleTable.byOperationID[.tracksCreateAudio])
        let wrongType: Bool = createAudio.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","requested_delta":1,"verification_source":"track_count_delta","track_type_verification_source":"observed_header","observed_track_type":"drummer","observed_delta":1,"track_count_before":2,"track_count_after":3,"observed_track_index":2}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!wrongType, "create_audio accepted a drummer track type")
        // STRUCTURAL: export_support_bundle rejects an empty file manifest.
        let bundle = try #require(SemanticOracleTable.byOperationID[.systemExportSupportBundle])
        let emptyManifest: Bool = bundle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","bundle_path":"/x/b","files":[]}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!emptyManifest, "export_support_bundle accepted an empty file manifest")
    }

    /// #373 B4 — RED evidence for representative oracles: each REJECTS the
    /// semantically-wrong result it exists to catch. The good-leg (each fixture
    /// passes) is the parameterized `oraclePassesItsRealisticFixture`; the two
    /// explicit good-legs below make the RED→GREEN contrast self-contained for the
    /// value-bearing (insert_verified) and bespoke (export_run) representatives.
    @Test func phaseB4RepresentativeOraclesRejectSemanticMutations() throws {
        // VALUE-BEARING representative: plugins.insert_verified pins the
        // request↔readback identity. First the GREEN leg (its own fixture passes),
        // then the RED legs — the insert landed the WRONG plugin, and the WRONG slot.
        let insert = try #require(SemanticOracleTable.byOperationID[.pluginsInsertVerified])
        let insertFixture = try #require(SemanticOracleFixtures.byOperationID[.pluginsInsertVerified])
        let insertGreen = try #require(insert.evaluate(
            responseData: insertFixture.responseData, readbackData: insertFixture.readbackData))
        #expect(insertGreen, "insert_verified rejected its own verified fixture")
        // Requested Gain, but the readback observed Compressor at the slot — a false
        // verified insert. target_identity.plugin_id != observed_plugin_id.
        let wrongPlugin: Bool = insert.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","hc_schema":2,"operation":"logic_plugins.insert_verified","target_identity":{"track_index":0,"insert":1,"plugin_id":"logic.stock.effect.gain"},"observed_plugin_id":"logic.stock.effect.compressor","observed_plugin_name":"Compressor","observed_slot":1,"select_trace":{},"write_source":"ax_exact_slot_popup","verify_source":"ax_plugin_inventory"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!wrongPlugin, "insert_verified accepted a plugin that differs from the requested one")
        // Requested slot 1, but the readback saw the plugin at slot 2.
        let wrongSlot: Bool = insert.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","hc_schema":2,"operation":"logic_plugins.insert_verified","target_identity":{"track_index":0,"insert":1,"plugin_id":"logic.stock.effect.gain"},"observed_plugin_id":"logic.stock.effect.gain","observed_plugin_name":"Gain","observed_slot":2,"select_trace":{},"write_source":"ax_exact_slot_popup","verify_source":"ax_plugin_inventory"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!wrongSlot, "insert_verified accepted a slot that differs from the requested one")

        // BESPOKE representative: project.export_run pins the completed-run contract
        // (no HC state:"A" envelope — a run RECORD keyed on `status`). GREEN leg
        // first, then RED — a partial run (some artifact failed) is not a verified
        // execution, and a run that mislabels itself completed while carrying a
        // failed artifact is caught by the independent artifacts_failed guard.
        let run = try #require(SemanticOracleTable.byOperationID[.projectExportRun])
        let runFixture = try #require(SemanticOracleFixtures.byOperationID[.projectExportRun])
        let runGreen = try #require(run.evaluate(
            responseData: runFixture.responseData, readbackData: runFixture.readbackData))
        #expect(runGreen, "export_run rejected its own completed-run fixture")
        // status:"partial" — an honest partial run must not read as a verified pass.
        let partialRun: Bool = run.evaluate(
            responseData: Data(#"{"schema":"logic_pro_mcp_export_run.v1","run_id":"r","mode":"run","confirmed":true,"status":"partial","output_root":"/x","collision_policy":"fail_if_exists","project_count":1,"artifacts_total":2,"artifacts_verified":1,"artifacts_skipped":0,"artifacts_uncertain":0,"artifacts_failed":1,"projects":[{"index":0,"project_path":"/x/a.logicx","display_name":"a","observed_project_path":"/x/a.logicx","identity_verified":true,"opened":true,"artifacts":[]}],"next_safe_action":"review_then_export_resume"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!partialRun, "export_run accepted a partial run")
        // status forged "completed" while a failed artifact remains — the
        // artifacts_failed:0 guard is independent of status, so this is caught.
        let mislabelledCompleted: Bool = run.evaluate(
            responseData: Data(#"{"schema":"logic_pro_mcp_export_run.v1","run_id":"r","mode":"run","confirmed":true,"status":"completed","output_root":"/x","collision_policy":"fail_if_exists","project_count":1,"artifacts_total":2,"artifacts_verified":1,"artifacts_skipped":0,"artifacts_uncertain":0,"artifacts_failed":1,"projects":[{"index":0,"project_path":"/x/a.logicx","display_name":"a","observed_project_path":"/x/a.logicx","identity_verified":true,"opened":true,"artifacts":[]}],"next_safe_action":"verify_artifacts_with_logic_audio"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!mislabelledCompleted, "export_run accepted a completed status with a failed artifact")

        // TOGGLE representative: edit.toggle_step_input rejects a no-op — the window
        // open-state did not change (observed_open == previous_open), so it is not a
        // verified toggle even though the envelope claims State A.
        let toggle = try #require(SemanticOracleTable.byOperationID[.editToggleStepInput])
        let noOpToggle: Bool = toggle.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","operation":"edit.toggle_step_input","previous_open":true,"observed_open":true,"via":"window-menu"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!noOpToggle, "edit.toggle_step_input accepted a no-op (window state unchanged)")

        // DOMAIN representative: mixer.insert_plugin rejects a plugin outside the
        // insertable stock allowlist.
        let mixerInsert = try #require(SemanticOracleTable.byOperationID[.mixerInsertPlugin])
        let unknownPlugin: Bool = mixerInsert.evaluate(
            responseData: Data(#"{"success":true,"verified":true,"state":"A","track":0,"slot":1,"plugin_name":"Space Designer","observed_plugin_name":"Space Designer","verify_source":"ax_plugin_slot"}"#.utf8),
            readbackData: Data("{}".utf8)) == true
        #expect(!unknownPlugin, "mixer.insert_plugin accepted a plugin outside the stock allowlist")
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

    /// Wiring: the validator must actually consult the table, not just own it —
    /// for EVERY oracle it carries (read-only AND the B1 mutating oracles; the
    /// validator routes both, even though the offline runner only live-runs the
    /// read-only surface).
    @Test(arguments: SemanticOracleTable.all.map(\.operationID))
    func validatorRoutesEachOracleOperationToItsOracle(operationID: OperationID) throws {
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
        // A mutating op with no oracle stays honestly unvalidated here.
        // transport.rewind is the canonical B2 case: send-only (no State A), so it
        // is structurally excluded and carries no oracle — the validator must
        // return nil, not a verdict, so the runner records it as protocolSmoke.
        #expect(SemanticOracleTable.byOperationID[.transportRewind] == nil)
        let mutating: Bool = QualificationSemanticReadbackValidator.validate(
            operationID: OperationID.transportRewind.rawValue,
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

// MARK: - safe-mutation base (Phase B0)

@Suite("#373 Phase B0 safe-mutation oracle base")
struct SafeMutationOracleTests {
    private func passes(_ oracle: OperationOracle, _ response: String, readback: String = "{}") -> Bool {
        oracle.evaluate(responseData: Data(response.utf8), readbackData: Data(readback.utf8)) == true
    }

    /// A genuine State A verified write passes the base envelope; the honest
    /// non-verifications (B, C) do not, so "I couldn't verify" can never be
    /// laundered into a semantic pass.
    @Test func verifiedEnvelopePassesStateAAndRejectsStateBAndC() {
        let oracle = SafeMutationOracle.oracle(.transportPlay, semantics: [])
        #expect(passes(oracle, #"{"success":true,"verified":true,"state":"A"}"#))
        #expect(!passes(oracle, #"{"success":true,"verified":false,"state":"B","reason":"ax_readback_unavailable"}"#))
        #expect(!passes(oracle, #"{"success":false,"verified":false,"state":"C","error":"invalid_params"}"#))
    }

    /// Each envelope clause is independently load-bearing: forging or dropping
    /// any ONE must sink the verdict, so a single mislabeled field cannot pass a
    /// State B envelope off as a verified write.
    @Test func eachEnvelopeClauseIsIndependentlyLoadBearing() {
        let oracle = SafeMutationOracle.oracle(.transportPlay, semantics: [])
        // `state` forged to A while `verified` is still false (B wearing A's tag).
        #expect(!passes(oracle, #"{"success":true,"verified":false,"state":"A"}"#))
        // `verified` forged true while `state` is still B.
        #expect(!passes(oracle, #"{"success":true,"verified":true,"state":"B"}"#))
        // `success` false under an otherwise A-looking envelope.
        #expect(!passes(oracle, #"{"success":false,"verified":true,"state":"A"}"#))
        // A dropped field is absent → its valueEquals fails closed.
        #expect(!passes(oracle, #"{"verified":true,"state":"A"}"#))
    }

    /// The base composes: envelope FIRST, then the op's own invariant. A verified
    /// envelope whose requested≠observed is still not a semantic pass, and an
    /// unverified envelope fails before the invariant is even consulted.
    @Test func envelopeComposesWithASafeMutationInvariant() {
        let oracle = SafeMutationOracle.oracle(.transportPlay, semantics: [
            .fieldsEqual(keyA: "requested", keyB: "observed"),
        ])
        #expect(passes(oracle, #"{"success":true,"verified":true,"state":"A","requested":-6.0,"observed":-6.0}"#))
        // Verified write, but what landed is not what was asked for.
        #expect(!passes(oracle, #"{"success":true,"verified":true,"state":"A","requested":-6.0,"observed":-3.0}"#))
        // Unverified (State B) — fails on the envelope regardless of the invariant.
        #expect(!passes(oracle, #"{"success":true,"verified":false,"state":"B","requested":-6.0,"observed":-6.0}"#))
    }

    @Test func verifiedEnvelopeIsThreeValueConstraintsAndComposesLoadBearing() {
        #expect(SafeMutationOracle.verifiedEnvelope.count == 3)
        #expect(SafeMutationOracle.verifiedEnvelope.allSatisfy { $0.isValueConstraint })
        let composed = SafeMutationOracle.oracle(.transportPlay, semantics: [
            .fieldsEqual(keyA: "requested", keyB: "observed"),
        ])
        #expect(composed.isSemanticallyLoadBearing)
        #expect(composed.strength == .shapeAndDomain)
        #expect(composed.constraints.count == 4)
    }
}

// MARK: - relational mutation harness (Phase B0)

@Suite("#373 Phase B0 relational mutation")
struct SemanticOracleRelationalMutationTests {
    /// The relational constraints are load-bearing under the SAME generic
    /// mutation harness the B1 mutating oracles run through: every mutant the
    /// mutator derives for a `fieldsEqual` must sink the oracle. Kept as a focused
    /// engine-level proof on a synthetic oracle; the table-driven proof for the
    /// real B1 verified-write oracles is `everyConstraintRejectsItsMutants`.
    @Test func fieldsEqualMutantsAreAllRejected() throws {
        let response = #"{"requested":-6.0,"observed":-6.0}"#
        let root = try #require(JSONInspector.parse(Data(response.utf8)))
        let constraint = OracleConstraint.fieldsEqual(keyA: "requested", keyB: "observed")
        let oracle = OperationOracle(.transportPlay, strength: .shapeAndDomain, constraints: [constraint])

        // Guard: the pristine fixture passes, so a rejection below is the
        // mutation's doing, not a broken baseline.
        let baseline = try #require(oracle.evaluate(
            responseData: Data(response.utf8), readbackData: Data("{}".utf8)))
        #expect(baseline)

        let mutants = JSONMutator.mutants(for: constraint, in: root)
        #expect(mutants.count >= 3, "expected drop + two divergence mutants, got \(mutants.count)")
        for mutant in mutants {
            let data = try #require(JSONMutator.encode(mutant.json))
            let survived: Bool = oracle.evaluate(
                responseData: data, readbackData: Data("{}".utf8)) == true
            #expect(!survived, "fieldsEqual survived mutant [\(mutant.label)]")
        }
    }

    @Test func crossCheckResponseMutantsAndReadbackDivergenceAreRejected() throws {
        let response = #"{"value":-6.0}"#
        let readback = #"{"observed":-6.0}"#
        let root = try #require(JSONInspector.parse(Data(response.utf8)))
        let constraint = OracleConstraint.crossCheck(responseKey: "value", readbackKey: "observed")
        let oracle = OperationOracle(.transportPlay, strength: .shapeAndDomain, constraints: [constraint])

        let baseline = try #require(oracle.evaluate(
            responseData: Data(response.utf8), readbackData: Data(readback.utf8)))
        #expect(baseline)

        // Response-side mutants — exactly what the table-driven harness runs
        // (readback held fixed, response corrupted).
        let mutants = JSONMutator.mutants(for: constraint, in: root)
        #expect(mutants.count >= 2, "expected drop + divergence mutants, got \(mutants.count)")
        for mutant in mutants {
            let data = try #require(JSONMutator.encode(mutant.json))
            let survived: Bool = oracle.evaluate(
                responseData: data, readbackData: Data(readback.utf8)) == true
            #expect(!survived, "crossCheck survived response mutant [\(mutant.label)]")
        }

        // Readback-side divergence: pristine response, corrupted readback.
        let diverged: Bool = oracle.evaluate(
            responseData: Data(response.utf8),
            readbackData: Data(#"{"observed":-3.0}"#.utf8)) == true
        #expect(!diverged)
    }
}

// MARK: - read-only census non-regression (Phase B0 → B1)

@Suite("#373 read-only census non-regression")
struct SemanticOracleB0CensusTests {
    /// The read-only census is a STANDING invariant across phases. B0 added
    /// framework only; B1/B2/B3/B4 add mutating increments WITHOUT perturbing the
    /// fully-covered read-only surface. So the read-only census stays exactly 22,
    /// and the table's total is the read-only 22 plus the pinned B1 + B2 + B3 + B4
    /// increments — a premature or miscounted mutating oracle fails here.
    @Test func readOnlyCensusStaysTwentyTwoAndMutatingIncrementsAreAdditive() {
        #expect(SemanticOracleTable.coveredSpecIDs.count == 22)
        let readOnlyOracles = Set(SemanticOracleTable.byOperationID.keys)
            .intersection(SemanticOracleTable.coveredSpecIDs)
        #expect(readOnlyOracles.count == 22)
        #expect(
            SemanticOracleTable.all.count
                == 22
                + SemanticOracleTable.phaseB1MutatingOperationIDs.count
                + SemanticOracleTable.phaseB2MutatingOperationIDs.count
                + SemanticOracleTable.phaseB3MutatingOperationIDs.count
                + SemanticOracleTable.phaseB4MutatingOperationIDs.count
                // #575: B4 closed the inventory as it stood, and registering a new mutating
                // operation reopens it. The sum stays exact because the new entry joins a NAMED
                // set of its own rather than being back-dated into a phase that never contained it.
                + SemanticOracleTable.postClosureMutatingOperationIDs.count
        )
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
        if !key.isEmpty, let dropped = remove(root, keyPath: key) {
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
        case .lengthPrefixedEntryCountEquals(let wireKey, let countKey, _):
            // Corrupt the self-describing wire field and independently make its
            // declared numeric cardinality disagree. (`drop wireKey` is generic.)
            mutants.append(contentsOf: replacements(root, wireKey, [
                ("malformed length prefix", "not-a-length-prefixed-entry"),
            ]))
            if let current = JSONPath.resolve(root, keyPath: countKey),
               let count = JSONInspector.number(of: current) {
                mutants.append(contentsOf: replacements(root, countKey, [
                    ("wrong entry count", count + 1),
                ]))
            }
        case .lengthPrefixedEntriesExclude(let wireKey, let forbiddenEntryKey):
            // Add the forbidden payload as another well-formed wire entry. The
            // delete-marker regression below additionally proves this cannot be
            // hidden by another count constraint.
            if let forbidden = JSONPath.resolve(root, keyPath: forbiddenEntryKey) as? String,
               let wire = JSONPath.resolve(root, keyPath: wireKey) as? String {
                let forbiddenWire = "\(forbidden.lengthOfBytes(using: .utf8)):\(forbidden)"
                mutants.append(contentsOf: replacements(root, wireKey, [
                    ("contains forbidden entry", wire + forbiddenWire),
                ]))
            }
        case .lengthPrefixedIdentityAtIndexEquals(let entriesKey, let indexKey, let nameKey, let positionKey):
            // Break every component of the claimed pre-write identity relation: an index that
            // names another entry, or a name/position that no longer matches the selected entry.
            if let rawIndex = JSONPath.resolve(root, keyPath: indexKey),
               let index = JSONInspector.number(of: rawIndex) {
                mutants.append(contentsOf: replacements(root, indexKey, [
                    ("different identity index", index + 1),
                ]))
            }
            if let name = JSONPath.resolve(root, keyPath: nameKey) {
                mutants.append(contentsOf: replacements(root, nameKey, [
                    ("different identity name", divergent(from: name)),
                ]))
            }
            if let position = JSONPath.resolve(root, keyPath: positionKey) {
                mutants.append(contentsOf: replacements(root, positionKey, [
                    ("different identity position", divergent(from: position)),
                ]))
            }
            if let entries = JSONPath.resolve(root, keyPath: entriesKey) as? [Any], !entries.isEmpty {
                mutants.append(contentsOf: replacements(root, entriesKey, [
                    ("malformed identity entry", ["not-a-length-prefixed-identity"] as [Any]),
                ]))
            }
        case .readbackArrayExcludesResponseIdentity(let responsePositionKey, _, _):
            // Response-side mutations cannot be mistaken for corroboration: removing or
            // diverging the claimed target position must fail closed. The meaningful
            // readback-side survivor mutation is exercised directly by the delete-marker oracle
            // regression, where a surviving target position in data[] keeps every other gate
            // satisfied.
            if let position = JSONPath.resolve(root, keyPath: responsePositionKey) {
                mutants.append(contentsOf: replacements(root, responsePositionKey, [
                    ("different readback identity position", divergent(from: position)),
                ]))
            }
        case .fieldsEqual(let keyA, let keyB):
            // Break the equality by diverging EITHER side; each must sink the
            // oracle. (`drop keyA` is already added generically via `key`.)
            if let currentA = JSONPath.resolve(root, keyPath: keyA) {
                mutants.append(contentsOf: replacements(root, keyA, [("diverge", divergent(from: currentA))]))
            }
            if let currentB = JSONPath.resolve(root, keyPath: keyB) {
                mutants.append(contentsOf: replacements(root, keyB, [("diverge", divergent(from: currentB))]))
            }
        case .crossCheck(let responseKey, _):
            // The harness holds the readback fixed and mutates the response, so
            // diverging the response side breaks response==readback. (Readback-
            // side divergence is exercised directly in the engine unit tests.)
            if let current = JSONPath.resolve(root, keyPath: responseKey) {
                mutants.append(contentsOf: replacements(root, responseKey, [("diverge", divergent(from: current))]))
            }
        case .numericNear(let keyA, let keyB, let within):
            // Break nearness by pushing EITHER side clearly beyond the bound
            // (distance bound+1, so it exceeds even a tiny tolerance), plus a
            // non-number to exercise the numbers-only rule. (drop keyA is added
            // generically via `key`.)
            let bound: Double
            switch within {
            case .absolute(let value):
                bound = value
            case .field(let toleranceKey):
                bound = JSONPath.resolve(root, keyPath: toleranceKey)
                    .flatMap(JSONInspector.number(of:)) ?? 0
            }
            if let aValue = JSONPath.resolve(root, keyPath: keyA),
               let a = JSONInspector.number(of: aValue) {
                mutants.append(contentsOf: replacements(root, keyB, [("beyond-near", a + bound + 1.0)]))
                mutants.append(contentsOf: replacements(root, keyA, [("non-number", "not-a-number")]))
            }
            if let bValue = JSONPath.resolve(root, keyPath: keyB),
               let b = JSONInspector.number(of: bValue) {
                mutants.append(contentsOf: replacements(root, keyA, [("beyond-near", b + bound + 1.0)]))
            }
        case .emptyArray(let key):
            mutants.append(contentsOf: replacements(root, key, [("non-empty", [1] as [Any])]))
        case .booleanFlipped(let keyA, let keyB):
            // Break the negation three ways, each of which MUST sink the oracle:
            //   * same-value on EITHER side ⇒ not a flip (`a == b`);
            //   * a numeric 1 in place of a bool ⇒ CFBoolean discipline rejects it.
            // (`drop keyA` is already added generically via `key`.)
            if let aValue = JSONPath.resolve(root, keyPath: keyA),
               JSONInspector.isBoolean(aValue),
               let a = (aValue as? NSNumber)?.boolValue {
                mutants.append(contentsOf: replacements(root, keyB, [("flip-same", a)]))
                mutants.append(contentsOf: replacements(root, keyA, [("non-bool", 1)]))
            }
            if let bValue = JSONPath.resolve(root, keyPath: keyB),
               JSONInspector.isBoolean(bValue),
               let b = (bValue as? NSNumber)?.boolValue {
                mutants.append(contentsOf: replacements(root, keyA, [("flip-same", b)]))
            }
        case .numericEqualsOffset(let keyA, let keyB, let offset):
            // Break the exact delta by moving EITHER side off it by 1, plus a
            // non-number on keyA to exercise the numbers-only rule. (`drop keyA`
            // is already added generically via `key`.)
            if let bValue = JSONPath.resolve(root, keyPath: keyB),
               let b = JSONInspector.number(of: bValue) {
                mutants.append(contentsOf: replacements(root, keyA, [
                    ("off-by-one high", b + offset + 1),
                    ("off-by-one low", b + offset - 1),
                    ("non-number", "not-a-number"),
                ]))
            }
            if let aValue = JSONPath.resolve(root, keyPath: keyA),
               let a = JSONInspector.number(of: aValue) {
                mutants.append(contentsOf: replacements(root, keyB, [
                    ("keyB moved off delta", a - offset + 1),
                ]))
            }
        case let .anyOf(alternatives):
            for alternative in alternatives {
                for branchConstraint in alternative {
                    mutants.append(contentsOf: Self.mutants(for: branchConstraint, in: root))
                }
            }
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

    /// A value guaranteed to differ from `value` under `JSONInspector.leavesEqual`
    /// — used to break a relational constraint (fieldsEqual / crossCheck) by
    /// corrupting one side. Mirrors the type discipline: a bool flips, a number
    /// increments, a string is suffixed, a container/null becomes a sentinel.
    private static func divergent(from value: Any) -> Any {
        switch JSONInspector.type(of: value) {
        case .string: return (value as? String ?? "") + "__oracle_mutant__"
        case .number: return (JSONInspector.number(of: value) ?? 0) + 1
        case .bool: return !((value as? NSNumber)?.boolValue ?? false)
        case .array, .object, .null: return "__oracle_divergent__"
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
