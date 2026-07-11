private struct MIDIOverlapKey: Hashable {
    let pitch: UInt8
    let channel: UInt8
}

func canonicalize(_ notes: [MIDINoteEvent], ppq: Int) -> [MIDINoteEvent] {
    guard ppq > 0 else { return [] }

    var canonical = notes.enumerated()
        .filter { $0.element.velocity > 0 && $0.element.durationTicks > 0 }
        .sorted { left, right in
            let lhs = left.element
            let rhs = right.element
            if lhs.startTicks != rhs.startTicks { return lhs.startTicks < rhs.startTicks }
            if lhs.pitch != rhs.pitch { return lhs.pitch < rhs.pitch }
            if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
            if lhs.velocity != rhs.velocity { return lhs.velocity < rhs.velocity }
            return left.offset < right.offset
        }
        .map(\.element)

    var latestIndex: [MIDIOverlapKey: Int] = [:]
    for index in canonical.indices {
        let note = canonical[index]
        let key = MIDIOverlapKey(pitch: note.pitch, channel: note.channel)
        if let previousIndex = latestIndex[key] {
            let previous = canonical[previousIndex]
            let (previousEnd, overflow) = previous.startTicks.addingReportingOverflow(
                previous.durationTicks
            )
            if overflow || previousEnd > note.startTicks {
                canonical[previousIndex] = MIDINoteEvent(
                    pitch: previous.pitch,
                    startTicks: previous.startTicks,
                    durationTicks: max(0, note.startTicks - previous.startTicks),
                    velocity: previous.velocity,
                    channel: previous.channel
                )
            }
        }
        latestIndex[key] = index
    }
    return canonical.filter { $0.durationTicks > 0 }
}

func normalizePPQ(
    _ notes: [MIDINoteEvent],
    from sourcePPQ: Int,
    to destinationPPQ: Int
) -> [MIDINoteEvent] {
    guard sourcePPQ > 0, destinationPPQ > 0, sourcePPQ != destinationPPQ else {
        return notes
    }
    return notes.map { note in
        MIDINoteEvent(
            pitch: note.pitch,
            startTicks: scale(note.startTicks, from: sourcePPQ, to: destinationPPQ),
            durationTicks: scale(note.durationTicks, from: sourcePPQ, to: destinationPPQ),
            velocity: note.velocity,
            channel: note.channel
        )
    }
}

private func scale(_ value: Int64, from sourcePPQ: Int, to destinationPPQ: Int) -> Int64 {
    let divisor = Int64(sourcePPQ)
    let (product, overflow) = value.multipliedReportingOverflow(by: Int64(destinationPPQ))
    guard !overflow else { return value }

    let quotient = product / divisor
    let remainder = product % divisor
    let roundingThreshold = divisor / 2 + divisor % 2
    guard abs(remainder) >= roundingThreshold else { return quotient }
    return quotient + (product >= 0 ? 1 : -1)
}
