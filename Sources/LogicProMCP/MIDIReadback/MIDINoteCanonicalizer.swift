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
                // Overflow-safe truncation: for adversarial (e.g. Int64.min/max)
                // expected notes the difference can overflow; keep the original
                // duration in that case rather than trapping.
                let (gap, subOverflow) = note.startTicks.subtractingReportingOverflow(previous.startTicks)
                canonical[previousIndex] = MIDINoteEvent(
                    pitch: previous.pitch,
                    startTicks: previous.startTicks,
                    durationTicks: subOverflow ? previous.durationTicks : max(0, gap),
                    velocity: previous.velocity,
                    channel: previous.channel
                )
            }
        }
        latestIndex[key] = index
    }
    return canonical.filter { $0.durationTicks > 0 }
}

/// Returns nil if any note cannot be scaled without Int64 overflow — a caller
/// must treat nil as unverifiable (fail-closed), never fall back to unscaled
/// values (which would compare wrong ticks).
func normalizePPQ(
    _ notes: [MIDINoteEvent],
    from sourcePPQ: Int,
    to destinationPPQ: Int
) -> [MIDINoteEvent]? {
    guard sourcePPQ > 0, destinationPPQ > 0, sourcePPQ != destinationPPQ else {
        return notes
    }
    var scaled: [MIDINoteEvent] = []
    scaled.reserveCapacity(notes.count)
    for note in notes {
        guard let start = scale(note.startTicks, from: sourcePPQ, to: destinationPPQ),
              let duration = scale(note.durationTicks, from: sourcePPQ, to: destinationPPQ) else {
            return nil
        }
        scaled.append(MIDINoteEvent(
            pitch: note.pitch,
            startTicks: start,
            durationTicks: duration,
            velocity: note.velocity,
            channel: note.channel
        ))
    }
    return scaled
}

private func scale(_ value: Int64, from sourcePPQ: Int, to destinationPPQ: Int) -> Int64? {
    let divisor = Int64(sourcePPQ)
    let (product, overflow) = value.multipliedReportingOverflow(by: Int64(destinationPPQ))
    guard !overflow else { return nil }

    let quotient = product / divisor
    let remainder = product % divisor
    let roundingThreshold = divisor / 2 + divisor % 2
    guard abs(remainder) >= roundingThreshold else { return quotient }
    return quotient + (product >= 0 ? 1 : -1)
}
