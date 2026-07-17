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
// constraint (valueEquals / numericRange / enumMember) or be an explicitly
// reasoned `.custom` escape hatch.

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

    var key: String {
        switch self {
        case .valueEquals(let key, _),
             .numericRange(let key, _, _),
             .enumMember(let key, _),
             .nonEmptyArray(let key),
             .typedField(let key, _):
            return key
        }
    }

    /// VALUE constraints pin meaning; the others only pin shape. The strength
    /// meta-test uses this to forbid presence-only oracles.
    var isValueConstraint: Bool {
        switch self {
        case .valueEquals, .numericRange, .enumMember:
            return true
        case .nonEmptyArray, .typedField:
            return false
        }
    }

    func isSatisfied(by root: Any) -> Bool {
        guard let value = JSONPath.resolve(root, keyPath: key) else { return false }
        switch self {
        case .valueEquals(_, let expected):
            return JSONInspector.primitive(of: value) == expected
        case .numericRange(_, let min, let max):
            guard let number = JSONInspector.number(of: value) else { return false }
            return number >= min && number <= max
        case .enumMember(_, let allowed):
            guard let token = JSONInspector.enumToken(of: value) else { return false }
            return allowed.contains(token)
        case .nonEmptyArray:
            guard let array = value as? [Any] else { return false }
            return !array.isEmpty
        case .typedField(_, let type):
            return JSONInspector.type(of: value) == type
        }
    }
}

enum OracleStrength: String, Sendable {
    /// Every constraint is an exact fixture-pinned value.
    case value
    /// Mixes exact values with domain/shape constraints for the
    /// environment-dependent fields.
    case shapeAndDomain
    /// Escape hatch: the response is not key-addressable JSON, or the check is
    /// a response↔readback cross-check the constraint data model cannot express.
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
        return constraints.allSatisfy { $0.isSatisfied(by: root) }
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
