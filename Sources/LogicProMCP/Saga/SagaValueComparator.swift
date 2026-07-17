import Foundation
import MCP

/// How a saga decides that an observed value matches an expected one.
///
/// LPMCP-PRD-004: saga classification used to be EXACT `==` on doubles that
/// Logic only exposes to AX in quantized detents (the mixer fader moves in
/// ~10-raw-unit steps). A verified write of `0.7` reads back as `0.699…`, and
/// exact equality then called it `notApplied` — a false rollback of a write
/// that actually landed. Comparison is therefore per-operation: exact where the
/// domain is discrete (strings, bools), absolute-epsilon where the surface
/// quantizes (volume, pan).
enum SagaComparator: String, Codable, Equatable, Sendable {
    case exact
    case absoluteEpsilon = "abs_eps"
}

/// The comparison contract for one operation.
///
/// The epsilon is ABSOLUTE, never relative: both quantized fields are already
/// normalized (volume 0...1, pan -1...1), so a relative epsilon would shrink to
/// nothing near zero — exactly where a pan detent still spans 0.05 — and a
/// centred pan could never verify.
struct SagaTolerance: Codable, Equatable, Sendable {
    let comparator: SagaComparator
    let epsilon: Double?

    static let exact = SagaTolerance(comparator: .exact, epsilon: nil)

    static func absoluteEpsilon(_ epsilon: Double) -> SagaTolerance {
        SagaTolerance(comparator: .absoluteEpsilon, epsilon: epsilon)
    }
}

/// Serialized proof of HOW a saga decision was reached, so an operator reading
/// the journal can tell an epsilon-tolerated match from an exact one.
struct SagaComparisonEvidence: Codable, Equatable, Sendable {
    let comparator: SagaComparator
    let epsilon: Double?
    let desired: Value?
    let observed: Value?
    let delta: Double?
    let equal: Bool
}

/// The single decision point for saga value equality.
///
/// Used by State-B/C classification and compensation verification ONLY. A
/// State-A step is already live-verified by the dispatcher and is NOT
/// re-decided here (see `MutationSaga.classifyVerifiedWrite`).
enum SagaValueComparator {
    /// The declared tolerance for `op`. Unknown operations fall back to
    /// `exact` — fail-closed: an operation nobody declared a tolerance for
    /// must not silently inherit a permissive epsilon.
    static func tolerance(for op: OperationID) -> SagaTolerance {
        MutationSaga.tolerance(for: op) ?? .exact
    }

    static func equals(observed: Value, expected: Value, op: OperationID) -> Bool {
        let tolerance = tolerance(for: op)
        switch tolerance.comparator {
        case .exact:
            return observed == expected
        case .absoluteEpsilon:
            // Fail closed on a missing epsilon or a non-numeric value: a
            // quantized field that arrives as a string/bool is a contract
            // violation, not a match.
            guard let epsilon = tolerance.epsilon,
                  let observedNumber = numeric(observed),
                  let expectedNumber = numeric(expected),
                  observedNumber.isFinite,
                  expectedNumber.isFinite else {
                return false
            }
            return abs(observedNumber - expectedNumber) <= epsilon
        }
    }

    /// Absolute difference between two numeric values, or nil when either side
    /// is absent/non-numeric (string and bool fields have no meaningful delta).
    static func delta(observed: Value?, expected: Value?) -> Double? {
        guard let observed,
              let expected,
              let observedNumber = numeric(observed),
              let expectedNumber = numeric(expected),
              observedNumber.isFinite,
              expectedNumber.isFinite else {
            return nil
        }
        return abs(observedNumber - expectedNumber)
    }

    static func evidence(
        observed: Value?,
        desired: Value?,
        op: OperationID
    ) -> SagaComparisonEvidence {
        let tolerance = tolerance(for: op)
        let equal: Bool
        if let observed, let desired {
            equal = equals(observed: observed, expected: desired, op: op)
        } else {
            equal = false
        }
        return SagaComparisonEvidence(
            comparator: tolerance.comparator,
            epsilon: tolerance.epsilon,
            desired: desired,
            observed: observed,
            delta: delta(observed: observed, expected: desired),
            equal: equal
        )
    }

    private static func numeric(_ value: Value) -> Double? {
        switch value {
        case .double(let double): double
        case .int(let int): Double(int)
        default: nil
        }
    }
}
