import Foundation

// #373 Phase A — data-driven semantic oracles for the read-only (class A)
// operation surface.
//
// WHY: `QualificationSemanticReadbackValidator` shipped with a single bespoke
// case (system.health). Every other read-only operation fell through to `nil`,
// which the runner honestly records as `protocolSmoke` — "the transport worked,
// nobody checked the meaning". PromotionGate requires every operation
// passed-or-waived, so the read-only surface could never qualify.
//
// This file gives each read-only spec an oracle: a declarative set of
// constraints over the operation's ACTUAL response shape (derived by reading
// each dispatcher handler, not by guessing). The oracle table is census-tested
// against the registry so the two cannot drift, and every oracle is
// mutation-tested so an oracle that cannot fail a corrupted payload fails CI.
//
// Presence-only oracles are FORBIDDEN: an oracle must carry at least one VALUE
// constraint (valueEquals / numericRange / enumMember / fieldsEqual /
// crossCheck) or be an explicitly reasoned `.custom` escape hatch.
//
// #373 Phase B0 — extends the model with two RELATIONAL constraints so the
// safe-mutation surface can be expressed declaratively: `.fieldsEqual` pins the
// `requested == observed` invariant of a verified write, and `.crossCheck` pins
// response↔independent-readback agreement (previously only a `.custom` closure
// could). The 50 concrete safe-mutation oracles land in Phase B1–B3; this file
// only carries the reusable framework they build on (see `SafeMutationOracle`).

/// A JSON leaf value an oracle can pin exactly.
enum JSONPrimitive: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

/// The JSON type an oracle can require of a field.
enum JSONType: String, Sendable, Equatable {
    case string
    case number
    case bool
    case array
    case object
    case null
}

/// How `.numericNear` bounds the gap between its two keys.
///
/// `.absolute` is right where the handler's convergence tolerance is a HARD-CODED
/// constant — the mixer AX-slider detent gate (`|observed_raw − target_raw| ≤ 6`)
/// and the MCU 14-bit echo tolerance (`2/16383`). `.field` reads the bound from
/// the payload's OWN tolerance key, which is the only faithful choice where the
/// handler's tolerance is DATA-DRIVEN and unit-specific: `set_param_verified`
/// carries a per-parameter `tolerance` in the parameter's own unit (0..1 for some
/// controls, 0..100 for others), so no single constant could bound it soundly.
enum NearnessBound: Sendable, Equatable {
    case absolute(Double)
    case field(String)
}

/// One declarative check against an operation's response payload.
///
/// `key` is a dotted key path resolved against the parsed response:
/// `""` addresses the root value (used by operations whose whole body is a
/// bare JSON scalar), `"a.b"` descends objects, and `"a.0"` indexes arrays.
enum OracleConstraint: Sendable {
    /// Fixture-pinned exact value. The strongest form — use wherever the
    /// handler emits a literal constant (schema tags, hardcoded honesty flags).
    case valueEquals(key: String, expected: JSONPrimitive)
    /// Environment-dependent number confined to a semantically legal domain.
    case numericRange(key: String, min: Double, max: Double)
    /// Environment-dependent number with a real lower bound and no invented
    /// upper bound. Booleans, missing values and non-numbers fail closed.
    case numericMinimum(key: String, min: Double)
    /// Environment-dependent JSON integer with a real lower bound. Conversion
    /// is exact across NSNumber's signed domain; fractional, Boolean and
    /// out-of-Int values fail closed instead of rounding through Double.
    case integerMinimum(key: String, min: Int)
    /// Field must be one of a closed set of legal tokens.
    case enumMember(key: String, allowed: [String])
    /// Field must be an array with at least one element.
    case nonEmptyArray(key: String)
    /// Field must be present with the given JSON type.
    case typedField(key: String, type: JSONType)
    /// Field must be one exact public `OutputAssignment` tagged-union object:
    /// bus 1...256, two ascending physical ports, or a fieldless named output.
    /// Missing members, fractional numbers, extra members and unknown kinds
    /// fail closed rather than receiving routing semantic credit.
    case outputAssignment(key: String)
    /// A joined `<utf8-byte-count>:<entry>` wire field contains exactly the
    /// number of entries declared by another numeric field, plus `offset`.
    /// The empty string is the canonical zero-entry encoding. Malformed prefixes,
    /// fractional/negative counts, and byte-length overruns fail closed.
    case lengthPrefixedEntryCountEquals(key: String, countKey: String, offset: Int)
    /// A JSON array contains exactly the number of elements declared by another numeric field,
    /// plus `offset`. Fractional/negative counts, booleans, missing keys, non-arrays and integer
    /// overflow all fail closed.
    case arrayCountEquals(key: String, countKey: String, offset: Int)
    /// A non-empty ordered string array records a change at every step, beginning at the string
    /// named by `initialKey`. The first element must differ from the initial value and every later
    /// element must differ from its immediate predecessor. Missing/non-string values fail closed.
    case orderedStringArrayChanges(key: String, initialKey: String)
    /// The requested bank windows must be the requested positions in the full MCU trace, not
    /// ambiguity-probe traffic relabelled as caller work. Right-bank probes are exact
    /// `[requested, different, requested]` triples; left-bank walks contain no probes. Press and
    /// write counts must also cover the complete trace, and its final requested row must be the
    /// reported final window.
    case bankRequestedWindowWitness(
        traceKey: String,
        requestedKey: String,
        directionKey: String,
        disambiguatedCountKey: String,
        pressesKey: String,
        writesKey: String,
        finalKey: String
    )
    /// A joined `<utf8-byte-count>:<entry>` wire field must not contain the exact
    /// string named by another field. Both the wire and the comparison value must
    /// be readable strings; malformed entries and missing values fail closed.
    case lengthPrefixedEntriesExclude(key: String, forbiddenEntryKey: String)
    /// The ordered pre-write identity at `indexKey` must encode exactly the claimed name and
    /// position. This binds a delete receipt's requested index/name to the position whose
    /// disappearance is proved by the survivor-position constraints.
    case lengthPrefixedIdentityAtIndexEquals(
        entriesKey: String, indexKey: String, nameKey: String, positionKey: String
    )
    /// The independent readback array must NOT still contain the claimed target POSITION.
    /// Name+index is not identity here: Logic auto-renames generated markers, so an absent
    /// name+index pair is forgeable and an honest delete of "Marker 1" at index 0 is rejected
    /// when a survivor is renamed to "Marker 1" at index 0. Positions do not rename.
    /// Missing or malformed positions fail closed rather than becoming an answer of absence.
    case readbackArrayExcludesResponseIdentity(
        responsePositionKey: String,
        readbackArrayKey: String,
        readbackPositionKey: String
    )
    /// Two key paths WITHIN THE SAME payload resolve to equal leaf values. The
    /// load-bearing safe-mutation invariant: a verified write echoes what was
    /// requested as what was observed, so `requested == observed` proves the
    /// value that LANDED is the value that was ASKED FOR — not merely that some
    /// value is present. Bool-vs-number safe: a requested `true` is not
    /// satisfied by an observed `1`.
    case fieldsEqual(keyA: String, keyB: String)
    /// Two key paths WITHIN THE SAME payload must resolve to different leaf
    /// values. Used when the independent before/after witness is meaningful only
    /// if it changed, such as a freshly redrawn MCU bank window.
    case fieldsDiffer(keyA: String, keyB: String)
    /// Two actual strings agree byte-for-byte, for domains where canonical Unicode equivalence
    /// is not identity. Missing/nonstring values refuse; generic `fieldsEqual` remains unchanged.
    case utf8StringsEqual(keyA: String, keyB: String)
    /// A key path in the RESPONSE equals a key path in the INDEPENDENT readback.
    /// Makes response↔readback agreement declarative instead of a bespoke
    /// closure. Fails closed when the readback is absent or unparseable — an
    /// unverifiable cross-check is not a pass. Bool-vs-number safe on both sides.
    case crossCheck(responseKey: String, readbackKey: String)
    /// Two numeric key paths WITHIN THE SAME payload agree to within a tolerance:
    /// `|value(keyA) − value(keyB)| ≤ bound`. The honest form of "the write landed
    /// near what was requested" for QUANTIZED writes, where an exact `fieldsEqual`
    /// would false-reject a legitimate verified write: an AX fader converges to
    /// the nearest ~10-raw-unit detent, an MCU echo to 14-bit resolution, a plugin
    /// slider to a per-parameter tolerance. NUMBERS ONLY, with the same
    /// bool-vs-number discipline as the rest of the model — a bool is never "near"
    /// a number (`number(of:)` rejects booleans) — and fails closed on a missing
    /// key, a non-number, or (for `.field`) a missing/negative tolerance.
    case numericNear(keyA: String, keyB: String, within: NearnessBound)
    /// Field must be an array with EXACTLY zero elements. The mirror of
    /// `.nonEmptyArray`, for pinning a "nothing went wrong" gate in the payload —
    /// e.g. a multi-step op that reaches State A only when its failure/uncertainty
    /// lists are empty. Fails closed on a missing key or a non-array.
    case emptyArray(key: String)
    /// Two boolean key paths WITHIN THE SAME payload are logical negations:
    /// `value(keyA) == !value(keyB)`. The load-bearing invariant of a verified
    /// TOGGLE — a control-bar checkbox flip reaches State A only when the AX
    /// read-back `observed` is the negation of the `previous` value, so
    /// `observed == !previous` proves the toggle CHANGED state rather than a no-op
    /// that still reported success. This is genuinely value-bearing: it relates
    /// two INDEPENDENTLY-READ observations (the before-read and the after-read),
    /// not one value to itself, so it is never a same-source echo. BOOLS ONLY,
    /// with the same CFBoolean discipline as the rest of the model — a numeric
    /// `0`/`1` must NOT satisfy it (`1` is not the negation of `false`) — and a
    /// missing key, a non-bool, or two EQUAL bools all fail closed.
    case booleanFlipped(keyA: String, keyB: String)
    /// Two numeric key paths WITHIN THE SAME payload satisfy `value(keyA) == value(keyB) +
    /// offset` EXACTLY (no tolerance). The honest form of "this count is derived from that
    /// count by a fixed delta" — e.g. an independently-read after-count that must be exactly
    /// one less than the independently-read before-count. Unlike `.numericNear`, there is no
    /// slack: a producer that reports a drop of zero, two, or any value other than `offset`
    /// fails. NUMBERS ONLY, with the same bool-vs-number discipline as the rest of the model,
    /// and fails closed on a missing key or a non-number on either side.
    case numericEqualsOffset(keyA: String, keyB: String, offset: Double)
    /// At least one complete response shape must satisfy all of its constraints.
    /// This keeps a versioned operation's mutually exclusive verified write
    /// planes explicit: accepting a checkbox envelope must not relax any slider
    /// invariant, and vice versa.
    indirect case anyOf([[OracleConstraint]])
    /// Every element of a readable array satisfies the same clauses, relative to that element.
    /// Pair with `nonEmptyArray` when an empty array cannot establish the operation's evidence.
    indirect case arrayElements(key: String, constraints: [OracleConstraint])

    /// The primary RESPONSE-side key path — the one the generic mutator drops
    /// and error messages cite. For the relational cases it is the response side
    /// (`keyA` / `responseKey`); the second key is reached case-locally.
    var key: String {
        switch self {
        case .valueEquals(let key, _),
             .numericRange(let key, _, _),
             .numericMinimum(let key, _),
             .integerMinimum(let key, _),
             .enumMember(let key, _),
             .nonEmptyArray(let key),
             .typedField(let key, _),
             .outputAssignment(let key),
             .lengthPrefixedEntryCountEquals(let key, _, _),
             .arrayCountEquals(let key, _, _),
             .orderedStringArrayChanges(let key, _),
             .bankRequestedWindowWitness(let key, _, _, _, _, _, _),
             .lengthPrefixedEntriesExclude(let key, _),
             .lengthPrefixedIdentityAtIndexEquals(let key, _, _, _),
             .readbackArrayExcludesResponseIdentity(let key, _, _),
             .fieldsEqual(let key, _),
             .fieldsDiffer(let key, _),
             .utf8StringsEqual(let key, _),
             .crossCheck(let key, _),
             .numericNear(let key, _, _),
             .emptyArray(let key),
             .booleanFlipped(let key, _),
             .numericEqualsOffset(let key, _, _),
             .arrayElements(let key, _):
            return key
        case .anyOf:
            // Alternatives have no single response key. Mutators recurse into
            // their actual clauses instead of fabricating a root-level field.
            return ""
        }
    }

    /// VALUE constraints pin meaning; the others only pin shape. The strength
    /// meta-test uses this to forbid presence-only oracles. The relational cases
    /// are value-bearing: `fieldsEqual`/`crossCheck` assert a concrete agreement
    /// between two OBSERVED values, which is stronger than presence — so an
    /// oracle carrying one is never a checkbox oracle.
    var isValueConstraint: Bool {
        switch self {
        case .valueEquals, .numericRange, .numericMinimum, .integerMinimum, .enumMember, .outputAssignment,
             .lengthPrefixedEntryCountEquals,
             .arrayCountEquals,
             .orderedStringArrayChanges,
             .bankRequestedWindowWitness,
             .lengthPrefixedEntriesExclude, .lengthPrefixedIdentityAtIndexEquals,
             .readbackArrayExcludesResponseIdentity, .fieldsEqual, .utf8StringsEqual, .crossCheck, .numericNear,
             .fieldsDiffer, .booleanFlipped, .numericEqualsOffset:
            return true
        case let .anyOf(alternatives):
            return alternatives.allSatisfy { branch in
                branch.contains { $0.isValueConstraint }
            }
        case let .arrayElements(_, constraints):
            return constraints.contains { $0.isValueConstraint }
        case .nonEmptyArray, .typedField, .emptyArray:
            return false
        }
    }

    /// `readback` is the parsed INDEPENDENT readback payload, read only by the
    /// response↔readback constraints; every other case ignores it. Defaulting it to nil keeps the
    /// single-payload call sites (and the engine unit tests) unchanged.
    func isSatisfied(by root: Any, readback: Any? = nil) -> Bool {
        switch self {
        case .valueEquals(let key, let expected):
            guard let value = JSONPath.resolve(root, keyPath: key) else { return false }
            return JSONInspector.primitive(of: value) == expected
        case .numericRange(let key, let min, let max):
            guard let value = JSONPath.resolve(root, keyPath: key),
                  let number = JSONInspector.number(of: value) else { return false }
            return number >= min && number <= max
        case .numericMinimum(let key, let min):
            guard let value = JSONPath.resolve(root, keyPath: key),
                  let number = JSONInspector.number(of: value) else { return false }
            return number >= min
        case .integerMinimum(let key, let min):
            guard let value = JSONPath.resolve(root, keyPath: key),
                  let integer = JSONInspector.integer(of: value) else { return false }
            return integer >= min
        case .enumMember(let key, let allowed):
            guard let value = JSONPath.resolve(root, keyPath: key),
                  let token = JSONInspector.enumToken(of: value) else { return false }
            return allowed.contains(token)
        case .nonEmptyArray(let key):
            guard let array = JSONPath.resolve(root, keyPath: key) as? [Any] else { return false }
            return !array.isEmpty
        case .typedField(let key, let type):
            guard let value = JSONPath.resolve(root, keyPath: key) else { return false }
            return JSONInspector.type(of: value) == type
        case .outputAssignment(let key):
            guard let value = JSONPath.resolve(root, keyPath: key) else { return false }
            return Self.isExactOutputAssignment(value)
        case .lengthPrefixedEntryCountEquals(let key, let countKey, let offset):
            guard let wire = JSONPath.resolve(root, keyPath: key) as? String,
                  let rawCount = JSONPath.resolve(root, keyPath: countKey),
                  let count = JSONInspector.integer(of: rawCount), count >= 0,
                  let entryCount = Self.lengthPrefixedEntryCount(in: wire) else { return false }
            let (expected, overflow) = count.addingReportingOverflow(offset)
            return !overflow && expected >= 0 && entryCount == expected
        case .arrayCountEquals(let key, let countKey, let offset):
            guard let array = JSONPath.resolve(root, keyPath: key) as? [Any],
                  let rawCount = JSONPath.resolve(root, keyPath: countKey),
                  let count = JSONInspector.integer(of: rawCount), count >= 0 else { return false }
            let (expected, overflow) = count.addingReportingOverflow(offset)
            return !overflow && expected >= 0 && array.count == expected
        case .orderedStringArrayChanges(let key, let initialKey):
            guard let initial = JSONPath.resolve(root, keyPath: initialKey) as? String,
                  let raw = JSONPath.resolve(root, keyPath: key) as? [Any],
                  !raw.isEmpty else { return false }
            var previous = initial
            for value in raw {
                guard let current = value as? String, current != previous else { return false }
                previous = current
            }
            return true
        case .bankRequestedWindowWitness(
            let traceKey, let requestedKey, let directionKey, let disambiguatedCountKey,
            let pressesKey, let writesKey, let finalKey
        ):
            guard let trace = JSONPath.resolve(root, keyPath: traceKey) as? [String],
                  let requested = JSONPath.resolve(root, keyPath: requestedKey) as? [String],
                  !requested.isEmpty,
                  let direction = JSONPath.resolve(root, keyPath: directionKey) as? String,
                  direction == "left" || direction == "right",
                  let disambiguatedRaw = JSONPath.resolve(root, keyPath: disambiguatedCountKey),
                  let disambiguated = JSONInspector.integer(of: disambiguatedRaw),
                  disambiguated >= 0, disambiguated <= requested.count,
                  let pressesRaw = JSONPath.resolve(root, keyPath: pressesKey),
                  let presses = JSONInspector.integer(of: pressesRaw), presses == trace.count,
                  let writesRaw = JSONPath.resolve(root, keyPath: writesKey),
                  let writes = JSONInspector.integer(of: writesRaw), writes >= trace.count,
                  let final = JSONPath.resolve(root, keyPath: finalKey) as? String,
                  requested.last == final else { return false }
            return Self.bankTrace(
                trace,
                matchesRequested: requested,
                direction: direction,
                disambiguatedCount: disambiguated
            )
        case .lengthPrefixedEntriesExclude(let key, let forbiddenEntryKey):
            guard let wire = JSONPath.resolve(root, keyPath: key) as? String,
                  let forbidden = JSONPath.resolve(root, keyPath: forbiddenEntryKey) as? String,
                  let entries = Self.lengthPrefixedEntries(in: wire) else { return false }
            return entries.allSatisfy { $0 != forbidden }
        case .lengthPrefixedIdentityAtIndexEquals(let entriesKey, let indexKey, let nameKey, let positionKey):
            guard let rawEntries = JSONPath.resolve(root, keyPath: entriesKey) as? [Any],
                  let rawIndex = JSONPath.resolve(root, keyPath: indexKey),
                  let index = JSONInspector.integer(of: rawIndex), index >= 0,
                  rawEntries.indices.contains(index),
                  let identity = rawEntries[index] as? String,
                  let name = JSONPath.resolve(root, keyPath: nameKey) as? String,
                  let position = JSONPath.resolve(root, keyPath: positionKey) as? String,
                  let identityEntries = Self.lengthPrefixedEntries(in: identity) else { return false }
            return identityEntries == [name, position]
        case .readbackArrayExcludesResponseIdentity(
            let responsePositionKey,
            let readbackArrayKey,
            let readbackPositionKey
        ):
            // Envelope-provided target metadata cannot corroborate itself. The post-write marker
            // records must be readable enough to tell whether that claimed target position remains.
            // A missing `data[]` is not an answer of absence: empty-array hiding made name+index
            // identity look like it accepted honest auto-renames.
            guard let targetPosition = JSONPath.resolve(root, keyPath: responsePositionKey) as? String,
                  !targetPosition.isEmpty,
                  let readback,
                  let entries = JSONPath.resolve(readback, keyPath: readbackArrayKey) as? [Any] else {
                return false
            }
            if entries.isEmpty {
                // Empty data[] is an answer of absence only when the independent readback
                // itself claims a verified empty list. A names-shifted test once hid both
                // a forged identity and an honest auto-rename behind `data: []`.
                guard let verifiedEmpty = JSONPath.resolve(readback, keyPath: "verified_empty") as? Bool else {
                    return false
                }
                return verifiedEmpty
            }
            for entry in entries {
                guard let entryPosition = JSONPath.resolve(entry, keyPath: readbackPositionKey) as? String else {
                    return false
                }
                if entryPosition == targetPosition { return false }
            }
            return true
        case .fieldsEqual(let keyA, let keyB):
            guard let a = JSONPath.resolve(root, keyPath: keyA),
                  let b = JSONPath.resolve(root, keyPath: keyB) else { return false }
            return JSONInspector.leavesEqual(a, b)
        case .fieldsDiffer(let keyA, let keyB):
            guard let a = JSONPath.resolve(root, keyPath: keyA),
                  let b = JSONPath.resolve(root, keyPath: keyB) else { return false }
            return !JSONInspector.leavesEqual(a, b)
        case .utf8StringsEqual(let keyA, let keyB):
            guard let a = JSONPath.resolve(root, keyPath: keyA) as? String,
                  let b = JSONPath.resolve(root, keyPath: keyB) as? String else { return false }
            return a.utf8.elementsEqual(b.utf8)
        case .crossCheck(let responseKey, let readbackKey):
            // Fail closed: no readback means nothing to cross-check against,
            // which is an unverified read — never a pass.
            guard let readback,
                  let a = JSONPath.resolve(root, keyPath: responseKey),
                  let b = JSONPath.resolve(readback, keyPath: readbackKey) else { return false }
            return JSONInspector.leavesEqual(a, b)
        case .numericNear(let keyA, let keyB, let within):
            // NUMBERS ONLY: `number(of:)` rejects booleans, so a bool is never
            // "near" a number. A missing key, a non-number, or (for `.field`) a
            // missing/negative tolerance all fail closed.
            guard let aValue = JSONPath.resolve(root, keyPath: keyA),
                  let bValue = JSONPath.resolve(root, keyPath: keyB),
                  let a = JSONInspector.number(of: aValue),
                  let b = JSONInspector.number(of: bValue) else { return false }
            let bound: Double
            switch within {
            case .absolute(let value):
                bound = value
            case .field(let toleranceKey):
                guard let raw = JSONPath.resolve(root, keyPath: toleranceKey),
                      let tolerance = JSONInspector.number(of: raw),
                      tolerance >= 0 else { return false }
                bound = tolerance
            }
            return abs(a - b) <= bound
        case .emptyArray(let key):
            guard let array = JSONPath.resolve(root, keyPath: key) as? [Any] else { return false }
            return array.isEmpty
        case .booleanFlipped(let keyA, let keyB):
            // BOOLS ONLY: both sides must be genuine CFBooleans — a numeric 0/1
            // fails closed (`isBoolean` gates it) — and they must be logical
            // negations. A missing key, a non-bool, or two EQUAL bools all fail.
            guard let aValue = JSONPath.resolve(root, keyPath: keyA),
                  let bValue = JSONPath.resolve(root, keyPath: keyB),
                  JSONInspector.isBoolean(aValue), JSONInspector.isBoolean(bValue),
                  let a = (aValue as? NSNumber)?.boolValue,
                  let b = (bValue as? NSNumber)?.boolValue else { return false }
            return a != b
        case .numericEqualsOffset(let keyA, let keyB, let offset):
            // NUMBERS ONLY: `number(of:)` rejects booleans. A missing key or a non-number on
            // either side fails closed rather than treating an absent witness as satisfied.
            guard let aValue = JSONPath.resolve(root, keyPath: keyA),
                  let bValue = JSONPath.resolve(root, keyPath: keyB),
                  let a = JSONInspector.number(of: aValue),
                  let b = JSONInspector.number(of: bValue) else { return false }
            return a == b + offset
        case let .anyOf(alternatives):
            return alternatives.contains { alternative in
                alternative.allSatisfy { $0.isSatisfied(by: root, readback: readback) }
            }
        case let .arrayElements(key, constraints):
            guard let array = JSONPath.resolve(root, keyPath: key) as? [Any], !constraints.isEmpty else { return false }
            return array.allSatisfy { element in
                constraints.allSatisfy { $0.isSatisfied(by: element, readback: readback) }
            }
        }
    }

    private static func isExactOutputAssignment(_ value: Any) -> Bool {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else {
            return false
        }
        func integer(_ value: Any?) -> Int? {
            guard let value else { return nil }
            return JSONInspector.integer(of: value)
        }
        switch kind {
        case "bus":
            guard Set(object.keys) == Set(["kind", "number"]),
                  let number = integer(object["number"]) else { return false }
            return OutputAssignment.busNumbers.contains(number)
        case "physical":
            guard Set(object.keys) == Set(["kind", "ports"]),
                  let ports = object["ports"] as? [Any], ports.count == 2,
                  let first = integer(ports[0]), let second = integer(ports[1]) else { return false }
            return first >= 1 && first < second
        case "stereo_output", "no_output":
            return Set(object.keys) == Set(["kind"])
        default:
            return false
        }
    }

    private struct BankTraceCursor: Hashable {
        let traceIndex: Int
        let probes: Int
    }

    /// Match the exact trace grammar emitted by `MCUChannel.executeBank`. A requested step always
    /// contributes one row. A successfully disambiguated right step immediately contributes two
    /// more rows: a different probe row and the requested row again after the inverse press.
    private static func bankTrace(
        _ trace: [String],
        matchesRequested requested: [String],
        direction: String,
        disambiguatedCount: Int
    ) -> Bool {
        if direction == "left" {
            return disambiguatedCount == 0 && trace == requested
        }

        var cursors: Set<BankTraceCursor> = [BankTraceCursor(traceIndex: 0, probes: 0)]
        for (requestedIndex, requestedRow) in requested.enumerated() {
            var next: Set<BankTraceCursor> = []
            for cursor in cursors where trace.indices.contains(cursor.traceIndex)
                && trace[cursor.traceIndex] == requestedRow {
                next.insert(BankTraceCursor(traceIndex: cursor.traceIndex + 1, probes: cursor.probes))
                let probeIndex = cursor.traceIndex + 1
                let returnIndex = cursor.traceIndex + 2
                // The final requested right step may be clamped to Logic's last bank. Its one
                // settlement probe redraws the same requested row and the handler can still
                // truthfully report that the requested step moved. Earlier same-row probes stop
                // the walk in State B, so this two-row shape is legal only at the requested tail.
                if requestedIndex == requested.count - 1,
                   trace.indices.contains(probeIndex),
                   trace[probeIndex] == requestedRow {
                    next.insert(BankTraceCursor(traceIndex: cursor.traceIndex + 2, probes: cursor.probes))
                }
                if trace.indices.contains(returnIndex),
                   trace[probeIndex] != requestedRow,
                   trace[returnIndex] == requestedRow {
                    next.insert(BankTraceCursor(traceIndex: cursor.traceIndex + 3, probes: cursor.probes + 1))
                }
            }
            cursors = next
            if cursors.isEmpty { return false }
        }
        return cursors.contains(BankTraceCursor(traceIndex: trace.count, probes: disambiguatedCount))
    }

    /// Counts concatenated `<utf8-byte-count>:<entry>` records without decoding
    /// the entries themselves. That keeps the parser faithful to the wire rule:
    /// lengths measure UTF-8 bytes, rather than Swift character counts.
    private static func lengthPrefixedEntryCount(in wire: String) -> Int? {
        lengthPrefixedEntries(in: wire)?.count
    }

    /// Decodes concatenated `<utf8-byte-count>:<entry>` records. Decoding every
    /// entry (rather than merely skipping its bytes) lets exclusion constraints
    /// compare exact UTF-8 payload strings without accepting split code points.
    private static func lengthPrefixedEntries(in wire: String) -> [String]? {
        let bytes = Array(wire.utf8)
        var offset = 0
        var entries: [String] = []
        while offset < bytes.count {
            var length = 0
            let lengthStart = offset
            while offset < bytes.count, bytes[offset] >= 48, bytes[offset] <= 57 {
                let digit = Int(bytes[offset] - 48)
                guard length <= (Int.max - digit) / 10 else { return nil }
                length = length * 10 + digit
                offset += 1
            }
            guard offset > lengthStart,
                  offset < bytes.count,
                  bytes[offset] == 58,
                  length > 0 else { return nil }
            offset += 1
            guard length <= bytes.count - offset else { return nil }
            guard let entry = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) else {
                return nil
            }
            offset += length
            entries.append(entry)
        }
        return entries
    }
}

enum OracleStrength: String, Sendable {
    /// Every constraint is an exact fixture-pinned value.
    case value
    /// Mixes exact values with domain/shape constraints for the
    /// environment-dependent fields.
    case shapeAndDomain
    /// Escape hatch: the response is not key-addressable JSON (prose bodies,
    /// bare scalars), or the check is a conditional the constraint model cannot
    /// express. Response↔readback cross-checks are NO LONGER a reason to reach
    /// for this — `.crossCheck` (Phase B0) expresses them declaratively.
    case custom
}

struct OperationOracle: Sendable {
    let operationID: OperationID
    let strength: OracleStrength
    let constraints: [OracleConstraint]
    /// Required for `.custom`: why the declarative constraints cannot express
    /// this operation's check. Enforced by the strength meta-test.
    let customReason: String?
    /// Escape hatch. Receives the raw response and the raw independent readback.
    /// Returns nil only if the oracle cannot render a verdict at all.
    let custom: (@Sendable (Data, Data) -> Bool?)?
    /// A useful response/protocol check may not establish independent after-state.
    /// Nil preserves the existing qualification policy; a declaration withholds that credit.
    let independentReadbackDeferral: QualificationDeferral?

    init(
        _ operationID: OperationID,
        strength: OracleStrength,
        constraints: [OracleConstraint],
        independentReadbackDeferral: QualificationDeferral? = nil
    ) {
        self.operationID = operationID
        self.strength = strength
        self.constraints = constraints
        customReason = nil
        custom = nil
        self.independentReadbackDeferral = independentReadbackDeferral
    }

    init(
        custom operationID: OperationID,
        reason: String,
        independentReadbackDeferral: QualificationDeferral? = nil,
        evaluate: @escaping @Sendable (Data, Data) -> Bool?
    ) {
        self.operationID = operationID
        strength = .custom
        constraints = []
        customReason = reason
        custom = evaluate
        self.independentReadbackDeferral = independentReadbackDeferral
    }

    /// The oracle carries real meaning (not just presence checks).
    var isSemanticallyLoadBearing: Bool {
        if strength == .custom {
            return custom != nil && customReason?.isEmpty == false
        }
        return constraints.contains { $0.isValueConstraint }
    }

    func evaluate(responseData: Data, readbackData: Data) -> Bool? {
        if let custom {
            return custom(responseData, readbackData)
        }
        guard let root = JSONInspector.parse(responseData) else { return false }
        // A missing/unparseable readback is nil; every response↔readback constraint fails closed
        // on nil. Every non-relational constraint ignores the readback, so their verdicts are
        // byte-for-byte unchanged.
        let readback = JSONInspector.parse(readbackData)
        return constraints.allSatisfy { $0.isSatisfied(by: root, readback: readback) }
    }
}

// MARK: - Safe-mutation composition

/// The base every Phase-B *safe-mutation* oracle composes with.
///
/// A read-only oracle pins what a query returned; a mutation oracle must first
/// prove the write was GENUINELY verified before it inspects what changed. The
/// HonestContract tri-state makes that precise: only State A ("write + read-back
/// matched") is a verified success. State B ("write landed, could not confirm")
/// and State C ("write failed") are honest non-verifications and must never be
/// laundered into a semantic pass.
///
/// The envelope is expressed as ordinary declarative constraints — not a bespoke
/// closure — so each clause is mutation-tested like any other, and a mutation
/// oracle is just `verifiedEnvelope + <its own invariant>` (typically a
/// `.fieldsEqual(requested, observed)`). The 50 concrete oracles land in #373
/// Phase B1–B3; this is only the reusable base they build on.
enum SafeMutationOracle {
    /// State A + verified + success, triple-guarded so no single dropped or
    /// forged field can pass a State B / State C envelope off as a verified
    /// write. `state == "A"` alone already excludes B and C; `verified == true`
    /// and `success == true` are kept as independent guards so a handler that
    /// mislabels its `state` cannot launder an unverified write on one typo.
    static let verifiedEnvelope: [OracleConstraint] = [
        .valueEquals(key: "state", expected: .string("A")),
        .valueEquals(key: "verified", expected: .bool(true)),
        .valueEquals(key: "success", expected: .bool(true)),
    ]

    /// Compose the verified envelope with an operation's own semantic clauses.
    /// The envelope is always FIRST, so a mutation oracle can never assert what
    /// changed without first proving the change was verified.
    static func oracle(
        _ operationID: OperationID,
        strength: OracleStrength = .shapeAndDomain,
        semantics: [OracleConstraint]
    ) -> OperationOracle {
        OperationOracle(
            operationID,
            strength: strength,
            constraints: verifiedEnvelope + semantics
        )
    }
}

// MARK: - JSON access

enum JSONInspector {
    /// `.fragmentsAllowed`: `project.is_running` answers with a bare `true` /
    /// `false` literal, which is a legal JSON fragment but not an object.
    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// NSNumber bridges to both Bool and Double in Swift, so `as? Bool` cannot
    /// distinguish `true` from `1`. CoreFoundation's type id can.
    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func type(of value: Any) -> JSONType {
        if value is NSNull { return .null }
        if isBoolean(value) { return .bool }
        if value is NSNumber { return .number }
        if value is String { return .string }
        if value is [Any] { return .array }
        if value is [String: Any] { return .object }
        return .null
    }

    static func number(of value: Any) -> Double? {
        guard !isBoolean(value), let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    /// Exact host-sized integer conversion. `Double(Int.max)` is not a safe upper bound because
    /// it rounds to 2^63 on 64-bit hosts; `Int(exactly:)` rejects that value instead of trapping.
    static func integer(of value: Any) -> Int? {
        guard !isBoolean(value), let number = value as? NSNumber else { return nil }
        return Int(exactly: number)
    }

    static func primitive(of value: Any) -> JSONPrimitive? {
        switch type(of: value) {
        case .null: return .null
        case .bool: return .bool((value as? NSNumber)?.boolValue ?? false)
        case .number: return number(of: value).map { .number($0) }
        case .string: return (value as? String).map { .string($0) }
        case .array, .object: return nil
        }
    }

    /// Enum membership is checked against the token's string form. Booleans are
    /// rendered as `true`/`false` so a bare-scalar body can be domain-checked.
    static func enumToken(of value: Any) -> String? {
        switch type(of: value) {
        case .string: return value as? String
        case .bool: return ((value as? NSNumber)?.boolValue ?? false) ? "true" : "false"
        default: return nil
        }
    }

    /// Leaf/structural equality with the SAME bool-vs-number discipline as
    /// `primitive(of:)`: a `true` never equals a `1`, because the two are
    /// distinguished by CFBooleanGetTypeID before any numeric bridge can conflate
    /// them. Arrays and objects compare recursively so the discipline holds at
    /// every depth. Used by the relational constraints (`fieldsEqual` /
    /// `crossCheck`) — the load-bearing safe-mutation checks.
    static func leavesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        let lhsType = type(of: lhs)
        guard lhsType == type(of: rhs) else { return false }
        switch lhsType {
        case .bool:
            return (lhs as? NSNumber)?.boolValue == (rhs as? NSNumber)?.boolValue
        case .number:
            guard let lhsNumber = lhs as? NSNumber, let rhsNumber = rhs as? NSNumber else {
                return false
            }
            return lhsNumber.compare(rhsNumber) == .orderedSame
        case .string:
            return (lhs as? String) == (rhs as? String)
        case .null:
            return true
        case .array:
            guard let la = lhs as? [Any], let ra = rhs as? [Any], la.count == ra.count else {
                return false
            }
            return zip(la, ra).allSatisfy { leavesEqual($0, $1) }
        case .object:
            guard let lo = lhs as? [String: Any], let ro = rhs as? [String: Any],
                  lo.count == ro.count else { return false }
            return lo.allSatisfy { key, value in
                guard let other = ro[key] else { return false }
                return leavesEqual(value, other)
            }
        }
    }
}

enum JSONPath {
    /// Resolves a dotted key path. `""` is the root. Numeric components index
    /// arrays. Returns nil when any component is absent — an absent key can
    /// never satisfy a constraint, which is what makes drop-the-key mutations
    /// fail closed.
    static func resolve(_ root: Any, keyPath: String) -> Any? {
        guard !keyPath.isEmpty else { return root }
        var current: Any = root
        for component in keyPath.split(separator: ".") {
            if let object = current as? [String: Any], let next = object[String(component)] {
                current = next
            } else if let array = current as? [Any],
                      let index = Int(component),
                      index >= 0,
                      index < array.count {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }
}
