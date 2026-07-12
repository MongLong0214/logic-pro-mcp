func isValidTempoMap(_ snapshot: TempoMapSnapshot) -> Bool {
    guard snapshot.ppq > 0,
          let first = snapshot.events.first,
          first.tick == 0 else {
        return false
    }

    for (index, event) in snapshot.events.enumerated() {
        guard event.bpm.isFinite, event.bpm > 0 else { return false }
        if index > 0, event.tick <= snapshot.events[index - 1].tick {
            return false
        }
    }
    return true
}

func secondsAtTick(_ tick: Int64, map: TempoMapSnapshot) -> Double? {
    guard tick >= 0, isValidTempoMap(map), var current = map.events.first else {
        return nil
    }

    var seconds = 0.0
    for next in map.events.dropFirst() {
        if tick <= next.tick {
            return seconds + secondsBetweenTicks(tick - current.tick, event: current, ppq: map.ppq)
        }
        seconds += secondsBetweenTicks(next.tick - current.tick, event: current, ppq: map.ppq)
        current = next
    }
    return seconds + secondsBetweenTicks(tick - current.tick, event: current, ppq: map.ppq)
}

func tickAtSeconds(_ seconds: Double, map: TempoMapSnapshot) -> Int64? {
    guard seconds.isFinite,
          seconds >= 0,
          isValidTempoMap(map),
          var current = map.events.first else {
        return nil
    }

    var elapsed = 0.0
    for next in map.events.dropFirst() {
        let segmentSeconds = secondsBetweenTicks(next.tick - current.tick, event: current, ppq: map.ppq)
        if seconds <= elapsed + segmentSeconds {
            return interpolatedTick(
                seconds: seconds - elapsed,
                event: current,
                ppq: map.ppq
            )
        }
        elapsed += segmentSeconds
        current = next
    }
    return interpolatedTick(seconds: seconds - elapsed, event: current, ppq: map.ppq)
}

private func secondsBetweenTicks(_ ticks: Int64, event: TempoMapEvent, ppq: Int) -> Double {
    Double(ticks) / Double(ppq) * 60 / event.bpm
}

private func interpolatedTick(seconds: Double, event: TempoMapEvent, ppq: Int) -> Int64? {
    let tick = Double(event.tick) + seconds * event.bpm * Double(ppq) / 60
    guard tick.isFinite else { return nil }
    return Int64(exactly: tick.rounded())
}
