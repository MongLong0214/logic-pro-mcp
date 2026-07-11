import Foundation

struct CompressorStateSnapshot: Codable, Equatable, Sendable {
    let insertRef: TargetReference?
    let circuit: CompressorCircuitModel
    let values: [CompressorParameter: Double]
    let complete: Bool
    let partialReason: String?

    init(
        insertRef: TargetReference?,
        circuit: CompressorCircuitModel,
        values: [CompressorParameter: Double],
        complete: Bool,
        partialReason: String?
    ) {
        self.insertRef = insertRef
        self.circuit = circuit
        self.values = values
        self.complete = complete
        self.partialReason = complete ? nil : partialReason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            insertRef: try values.decodeIfPresent(TargetReference.self, forKey: .insertRef),
            circuit: try values.decode(CompressorCircuitModel.self, forKey: .circuit),
            values: try values.decode([CompressorParameter: Double].self, forKey: .values),
            complete: try values.decode(Bool.self, forKey: .complete),
            partialReason: try values.decodeIfPresent(String.self, forKey: .partialReason)
        )
    }
}

func compareOutcome(
    before: CompressorStateSnapshot,
    after: CompressorStateSnapshot,
    requested: [CompressorParameter: Double],
    tolerance: Double
) -> [CompressorParameter: (requested: Double, observed: Double, verified: Bool)] {
    guard before.insertRef == after.insertRef, before.circuit == after.circuit else {
        return [:]
    }

    var outcome: [
        CompressorParameter: (requested: Double, observed: Double, verified: Bool)
    ] = [:]
    for (parameter, requestedValue) in requested {
        guard let observed = after.values[parameter] else { continue }
        let verified = after.complete
            && tolerance.isFinite
            && tolerance >= 0
            && requestedValue.isFinite
            && observed.isFinite
            && abs(observed - requestedValue) <= tolerance
        outcome[parameter] = (requestedValue, observed, verified)
    }
    return outcome
}

struct SagaEligibility: Sendable {
    let eligible: Bool
    let missing: [String]
}

func sagaEligibility(
    beforeSnapshot: CompressorStateSnapshot?,
    readbackPresent: Bool,
    compensationVerified: Bool
) -> SagaEligibility {
    var missing: [String] = []
    if beforeSnapshot?.complete != true {
        missing.append("complete_before_snapshot")
    }
    if !readbackPresent {
        missing.append("requested_parameter_readback")
    }
    if !compensationVerified {
        missing.append("verified_compensation")
    }
    return SagaEligibility(eligible: missing.isEmpty, missing: missing)
}
