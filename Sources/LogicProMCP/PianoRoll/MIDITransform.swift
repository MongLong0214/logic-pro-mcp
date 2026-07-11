enum QuantizeGrid: String, Codable, Sendable {
    case thirtySecond
    case sixteenth
    case eighth
    case quarter
    case half
    case whole

    func ticks(ppq: Int) -> Int64 {
        guard ppq > 0 else { return 0 }
        let base = Int64(ppq)
        switch self {
        case .thirtySecond:
            return max(1, base / 8)
        case .sixteenth:
            return max(1, base / 4)
        case .eighth:
            return max(1, base / 2)
        case .quarter:
            return base
        case .half:
            let result = base.multipliedReportingOverflow(by: 2)
            return result.overflow ? 0 : result.partialValue
        case .whole:
            let result = base.multipliedReportingOverflow(by: 4)
            return result.overflow ? 0 : result.partialValue
        }
    }
}

enum MIDITransform: Codable, Equatable, Sendable {
    case transpose(semitones: Int)
    case setVelocity(Int)
    case scaleVelocity(factor: Double, pivot: Int)
    case quantize(grid: QuantizeGrid, strength: Double, swing: Double)
    case humanize(timingTicks: Int, velocity: Int, seed: UInt64)
}

func applyTransform(
    _ transform: MIDITransform,
    to notes: [MIDINoteEvent],
    ppq: Int
) -> [MIDINoteEvent] {
    switch transform {
    case .transpose(let semitones):
        return notes.map { note in
            let (pitch, overflow) = Int(note.pitch).addingReportingOverflow(semitones)
            return replacing(note, pitch: midiPitch(overflow ? semitones.signum() * 128 : pitch))
        }
    case .setVelocity(let velocity):
        return notes.map { replacing($0, velocity: midiVelocity(velocity)) }
    case .scaleVelocity(let factor, let pivot):
        guard factor.isFinite else { return notes }
        return notes.map { note in
            let scaled = Double(pivot) + (Double(note.velocity) - Double(pivot)) * factor
            guard scaled.isFinite else { return note }
            return replacing(note, velocity: midiVelocity(Int(scaled.rounded())))
        }
    case .quantize(let grid, let strength, let swing):
        return quantized(notes, grid: grid, strength: strength, swing: swing, ppq: ppq)
    case .humanize(let timingTicks, let velocity, let seed):
        return notes.enumerated().map { index, note in
            let timing = symmetricOffset(
                limit: timingTicks,
                random: deterministicWord(seed: seed, index: index, lane: 0)
            )
            let velocityOffset = symmetricOffset(
                limit: velocity,
                random: deterministicWord(seed: seed, index: index, lane: 1)
            )
            let (shiftedStart, overflow) = note.startTicks.addingReportingOverflow(timing)
            let start = overflow ? (timing < 0 ? 0 : Int64.max) : max(0, shiftedStart)
            return replacing(
                note,
                startTicks: start,
                velocity: midiVelocity(Int(note.velocity) + Int(velocityOffset))
            )
        }
    }
}

private func quantized(
    _ notes: [MIDINoteEvent],
    grid: QuantizeGrid,
    strength: Double,
    swing: Double,
    ppq: Int
) -> [MIDINoteEvent] {
    let gridTicks = grid.ticks(ppq: ppq)
    guard gridTicks > 0 else { return notes }
    let appliedStrength = strength.isFinite ? min(max(strength, 0), 1) : 0
    let appliedSwing = swing.isFinite ? min(max(swing, -1), 1) : 0

    return notes.map { note in
        let gridIndex = roundedQuotient(note.startTicks, divisor: gridTicks)
        let (baseTarget, baseOverflow) = gridIndex.multipliedReportingOverflow(by: gridTicks)
        guard !baseOverflow else { return note }

        let swingOffset = gridIndex % 2 == 0
            ? 0
            : roundedInt64(Double(gridTicks) * appliedSwing / 2)
        let (swungTarget, swingOverflow) = baseTarget.addingReportingOverflow(swingOffset)
        guard !swingOverflow else { return note }

        let interpolated = Double(note.startTicks)
            + (Double(swungTarget) - Double(note.startTicks)) * appliedStrength
        return replacing(note, startTicks: roundedInt64(interpolated))
    }
}

private func roundedQuotient(_ value: Int64, divisor: Int64) -> Int64 {
    let quotient = value / divisor
    let remainder = value % divisor
    let threshold = divisor / 2 + divisor % 2
    guard abs(remainder) >= threshold else { return quotient }
    return quotient + (value >= 0 ? 1 : -1)
}

private func roundedInt64(_ value: Double) -> Int64 {
    guard value.isFinite else { return 0 }
    if value >= Double(Int64.max) { return Int64.max }
    if value <= Double(Int64.min) { return Int64.min }
    return Int64(value.rounded())
}

private func deterministicWord(seed: UInt64, index: Int, lane: UInt64) -> UInt64 {
    var word = seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15 &+ lane
    word = (word ^ (word >> 30)) &* 0xBF58_476D_1CE4_E5B9
    word = (word ^ (word >> 27)) &* 0x94D0_49BB_1331_11EB
    return word ^ (word >> 31)
}

private func symmetricOffset(limit: Int, random: UInt64) -> Int64 {
    let magnitude = min(UInt64(limit.magnitude), UInt64(Int64.max / 2))
    guard magnitude > 0 else { return 0 }
    return Int64(random % (magnitude * 2 + 1)) - Int64(magnitude)
}

private func midiPitch(_ value: Int) -> UInt8 {
    UInt8(min(max(value, 0), 127))
}

private func midiVelocity(_ value: Int) -> UInt8 {
    UInt8(min(max(value, 1), 127))
}

private func replacing(
    _ note: MIDINoteEvent,
    pitch: UInt8? = nil,
    startTicks: Int64? = nil,
    velocity: UInt8? = nil
) -> MIDINoteEvent {
    MIDINoteEvent(
        pitch: pitch ?? note.pitch,
        startTicks: startTicks ?? note.startTicks,
        durationTicks: note.durationTicks,
        velocity: velocity ?? note.velocity,
        channel: note.channel
    )
}
