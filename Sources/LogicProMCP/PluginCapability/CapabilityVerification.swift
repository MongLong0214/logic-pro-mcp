enum ReadbackVerdict: Equatable, Sendable {
    case confirmed
    case mismatch(observed: Double, expected: Double, tolerance: Double)
    case unsupportedValueType
}

func verifyReadback(
    capability: VerifiedParameterCapability,
    written: Double,
    observed: Double
) -> ReadbackVerdict {
    guard written.isFinite, observed.isFinite,
          capability.tolerance.isFinite, capability.tolerance >= 0
    else {
        return .unsupportedValueType
    }

    let expected = normalized(written, for: capability.valueType)
    let actual = normalized(observed, for: capability.valueType)
    guard abs(actual - expected) <= capability.tolerance else {
        return .mismatch(
            observed: actual,
            expected: expected,
            tolerance: capability.tolerance
        )
    }
    return .confirmed
}

private func normalized(_ value: Double, for type: ParameterValueType) -> Double {
    switch type {
    case .boolean:
        value >= 0.5 ? 1 : 0
    case .enumerated:
        value.rounded()
    case .normalized, .decibels, .milliseconds, .hertz, .ratio:
        value
    }
}

struct ParameterSnapshot: Codable, Equatable, Sendable {
    let pluginIdentity: PluginIdentity
    let values: [ParameterID: Double]
}

func snapshotDiff(
    before: ParameterSnapshot,
    after: ParameterSnapshot
) -> [ParameterID: (before: Double, after: Double)] {
    guard before.pluginIdentity == after.pluginIdentity else { return [:] }

    var result: [ParameterID: (before: Double, after: Double)] = [:]
    for parameterID in Set(before.values.keys).intersection(after.values.keys) {
        guard let old = before.values[parameterID],
              let new = after.values[parameterID],
              old != new
        else {
            continue
        }
        result[parameterID] = (before: old, after: new)
    }
    return result
}

struct BatchApplyRequest: Sendable {
    let pluginIdentity: PluginIdentity
    let targets: [(ParameterID, Double)]
}

enum CapabilityError: Error, Equatable, Sendable {
    case unsupportedParameter(ParameterID)
    case valueOutOfRange(
        parameterID: ParameterID,
        value: Double,
        allowedRange: ClosedRange<Double>
    )
}

struct BatchApplyResult: Equatable, Sendable {
    let appliedVerified: [ParameterID]
    let failed: [(ParameterID, ReadbackVerdict)]
    let complete: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.appliedVerified == rhs.appliedVerified
            && lhs.complete == rhs.complete
            && lhs.failed.count == rhs.failed.count
            && zip(lhs.failed, rhs.failed).allSatisfy { left, right in
                left.0 == right.0 && left.1 == right.1
            }
    }
}

enum BatchApplyOutcome: Equatable, Sendable {
    case complete(BatchApplyResult)
    case partialFailure(BatchApplyResult)

    init(_ result: BatchApplyResult) {
        self = result.complete ? .complete(result) : .partialFailure(result)
    }

    var isSuccess: Bool {
        if case .complete = self { return true }
        return false
    }
}

func planBatchApply(
    _ request: BatchApplyRequest,
    registry: CapabilityRegistry
) -> Result<[VerifiedParameterCapability], CapabilityError> {
    var planned: [VerifiedParameterCapability] = []
    for (parameterID, value) in request.targets {
        guard let capability = registry.capability(
            pluginIdentity: request.pluginIdentity,
            parameterID: parameterID
        ) else {
            return .failure(.unsupportedParameter(parameterID))
        }
        if let allowedRange = capability.allowedRange,
           !allowedRange.contains(value) {
            return .failure(
                .valueOutOfRange(
                    parameterID: parameterID,
                    value: value,
                    allowedRange: allowedRange
                )
            )
        }
        planned.append(capability)
    }
    return .success(planned)
}
