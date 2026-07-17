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
    /// Field must be one of a closed set of legal tokens.
    case enumMember(key: String, allowed: [String])
    /// Field must be an array with at least one element.
    case nonEmptyArray(key: String)
    /// Field must be present with the given JSON type.
    case typedField(key: String, type: JSONType)
    /// Two key paths WITHIN THE SAME payload resolve to equal leaf values. The
    /// load-bearing safe-mutation invariant: a verified write echoes what was
    /// requested as what was observed, so `requested == observed` proves the
    /// value that LANDED is the value that was ASKED FOR — not merely that some
    /// value is present. Bool-vs-number safe: a requested `true` is not
    /// satisfied by an observed `1`.
    case fieldsEqual(keyA: String, keyB: String)
    /// A key path in the RESPONSE equals a key path in the INDEPENDENT readback.
    /// Makes response↔readback agreement declarative instead of a bespoke
    /// closure. Fails closed when the readback is absent or unparseable — an
    /// unverifiable cross-check is not a pass. Bool-vs-number safe on both sides.
    case crossCheck(responseKey: String, readbackKey: String)

    /// The primary RESPONSE-side key path — the one the generic mutator drops
    /// and error messages cite. For the relational cases it is the response side
    /// (`keyA` / `responseKey`); the second key is reached case-locally.
    var key: String {
        switch self {
        case .valueEquals(let key, _),
             .numericRange(let key, _, _),
             .enumMember(let key, _),
             .nonEmptyArray(let key),
             .typedField(let key, _),
             .fieldsEqual(let key, _),
             .crossCheck(let key, _):
            return key
        }
    }

    /// VALUE constraints pin meaning; the others only pin shape. The strength
    /// meta-test uses this to forbid presence-only oracles. The relational cases
    /// are value-bearing: `fieldsEqual`/`crossCheck` assert a concrete agreement
    /// between two OBSERVED values, which is stronger than presence — so an
    /// oracle carrying one is never a checkbox oracle.
    var isValueConstraint: Bool {
        switch self {
        case .valueEquals, .numericRange, .enumMember, .fieldsEqual, .crossCheck:
            return true
        case .nonEmptyArray, .typedField:
            return false
        }
    }

    /// `readback` is the parsed INDEPENDENT readback payload, read only by
    /// `.crossCheck`; every other case ignores it. Defaulting it to nil keeps the
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
        case .fieldsEqual(let keyA, let keyB):
            guard let a = JSONPath.resolve(root, keyPath: keyA),
                  let b = JSONPath.resolve(root, keyPath: keyB) else { return false }
            return JSONInspector.leavesEqual(a, b)
        case .crossCheck(let responseKey, let readbackKey):
            // Fail closed: no readback means nothing to cross-check against,
            // which is an unverified read — never a pass.
            guard let readback,
                  let a = JSONPath.resolve(root, keyPath: responseKey),
                  let b = JSONPath.resolve(readback, keyPath: readbackKey) else { return false }
            return JSONInspector.leavesEqual(a, b)
        }
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

    init(
        _ operationID: OperationID,
        strength: OracleStrength,
        constraints: [OracleConstraint]
    ) {
        self.operationID = operationID
        self.strength = strength
        self.constraints = constraints
        customReason = nil
        custom = nil
    }

    init(
        custom operationID: OperationID,
        reason: String,
        evaluate: @escaping @Sendable (Data, Data) -> Bool?
    ) {
        self.operationID = operationID
        strength = .custom
        constraints = []
        customReason = reason
        custom = evaluate
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
        // A missing/unparseable readback is nil; only `.crossCheck` reads it (and
        // it fails closed on nil). Every non-relational constraint ignores the
        // readback, so their verdicts are byte-for-byte unchanged.
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
            return number(of: lhs) == number(of: rhs)
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
