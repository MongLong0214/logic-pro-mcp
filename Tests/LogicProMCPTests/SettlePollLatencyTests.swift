@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// `edit.move_to_playhead` used to sleep a fixed 350 ms before its single post-read, whatever Logic's
// real latency. It now polls the same readback on a bounded schedule and stops at the first
// reading that already proves the move landed (`moveLanded`, which is the State A condition and
// nothing weaker); a reading that never satisfies it is still taken after the whole 350 ms.
//
// Logic is modelled as NON-INSTANT: the write lands only once a virtual clock, advanced by the
// settle waits themselves, reaches the stage's latency. Nothing here sleeps for real.

/// A UI whose state changes at virtual times. `advance` is the injected settle wait.
private final class VirtualLogic: @unchecked Sendable {
    private let lock = NSLock()
    private var clock: UInt64 = 0
    private var stages: [(at: UInt64, apply: () -> Void)]
    init(stages: [(at: UInt64, apply: () -> Void)]) { self.stages = stages.sorted { $0.at < $1.at } }
    /// Fire every stage whose time has come. Called after the menu "click" and after every wait.
    private func fireDue() {
        while let first = stages.first, first.at <= clock {
            stages.removeFirst()
            first.apply()
        }
    }
    func click() { lock.lock(); defer { lock.unlock() }; fireDue() }
    func advance(_ ns: UInt64) { lock.lock(); defer { lock.unlock() }; clock += ns; fireDue() }
    var waitedNanoseconds: UInt64 { lock.lock(); defer { lock.unlock() }; return clock }
}

private let ms: UInt64 = 1_000_000

private func help(bar: Int) -> String {
    "리전은 \(bar) 마디 에서 시작하여 \(bar + 2) 마디 에서 끝납니다., MIDI 리전."
}

private struct MoveRun {
    let json: [String: Any]
    let waitedNanoseconds: UInt64
}

private func runMove(
    stages stageSpec: [(latencyMs: UInt64, bar: Int)],
    playheadBar: Int = 9,
    schedule: SettleSchedule = .regionMove
) async -> MoveRun {
    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(name: "RegionA", help: help(bar: 1), pos: axPoint(240, 108),
                   size: axSize(320, 24), selected: true)],
        playheadPosition: "\(playheadBar).1.1.1"
    )
    let logic = VirtualLogic(stages: stageSpec.map { spec in
        (at: spec.latencyMs * ms, apply: {
            fixture.builder.setAttribute(fixture.builder.element(3_000), kAXHelpAttribute as String, help(bar: spec.bar))
        })
    })
    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in logic.click(); return .success("OK") },
        settleSchedule: schedule,
        settle: { logic.advance($0) }
    )
    let object = (try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any] ?? [:]
    return MoveRun(json: object, waitedNanoseconds: logic.waitedNanoseconds)
}

/// What the fixed 350 ms sleep did: one wait, then judge.
private let legacyFixedSettle = SettleSchedule(waitsNanoseconds: [350 * ms])

@Suite struct SettlePollLatencyTests {
    @Test func theScheduleSpendsExactlyTheOldWindowInShortSteps() {
        let schedule = SettleSchedule.regionMove
        #expect(schedule.windowNanoseconds == 350 * ms)
        #expect(schedule.waitsNanoseconds.allSatisfy { $0 <= 100 * ms && $0 > 0 })
        #expect(schedule.waitsNanoseconds.first == 10 * ms)
    }

    /// RED against the fixed sleep (every row waited 350 ms), GREEN with the poll: Logic that
    /// answers in L ms is charged the first checkpoint at or after L, never the whole window.
    @Test(arguments: [0, 5, 10, 25, 90, 200, 340, 350] as [UInt64])
    func aMoveThatLandsInLMillisecondsIsChargedNoMoreThanTheNextCheckpoint(latencyMs: UInt64) async throws {
        let run = await runMove(stages: [(latencyMs, 9)])
        #expect(run.json["verified"] as? Bool == true)
        #expect(run.json["observed"] as? Int == 9)
        var cumulative: UInt64 = 0
        var checkpoints: [UInt64] = [0]
        for wait in SettleSchedule.regionMove.waitsNanoseconds { cumulative += wait; checkpoints.append(cumulative) }
        let expected = try #require(checkpoints.first { $0 >= latencyMs * ms })
        #expect(run.waitedNanoseconds == expected)
        if latencyMs <= 90 { #expect(run.waitedNanoseconds < 350 * ms / 2) }
    }

    /// The gate is not weakened: Logic slower than the old window is judged exactly as the fixed
    /// sleep judged it, on a reading taken after the whole 350 ms.
    @Test(arguments: [351, 400, 5_000] as [UInt64])
    func aMoveSlowerThanTheWindowIsStillRefusedAfterTheWholeWindow(latencyMs: UInt64) async {
        let polled = await runMove(stages: [(latencyMs, 9)])
        let legacy = await runMove(stages: [(latencyMs, 9)], schedule: legacyFixedSettle)
        #expect(polled.waitedNanoseconds == 350 * ms)
        #expect(polled.json["verified"] as? Bool == false)
        #expect(polled.json["reason"] as? String == "readback_mismatch")
        #expect(polled.json["reason"] as? String == legacy.json["reason"] as? String)
        #expect(polled.json["verified"] as? Bool == legacy.json["verified"] as? Bool)
    }

    /// An intermediate reading that shows the region somewhere ELSE must not end the poll: a stop on
    /// "it moved" instead of "it landed on the playhead" would certify bar 5 here.
    @Test func aRegionThatMovedToTheWrongBarDoesNotEndThePoll() async {
        let wrongThenRight = await runMove(stages: [(40, 5), (200, 9)])
        #expect(wrongThenRight.json["verified"] as? Bool == true)
        #expect(wrongThenRight.json["observed"] as? Int == 9)
        #expect(wrongThenRight.waitedNanoseconds >= 200 * ms)

        let wrongForever = await runMove(stages: [(40, 5)])
        #expect(wrongForever.json["verified"] as? Bool == false)
        #expect(wrongForever.json["reason"] as? String == "readback_mismatch")
        #expect(wrongForever.json["post_start_bar"] as? Int == 5)
        #expect(wrongForever.waitedNanoseconds == 350 * ms)
    }

    /// Whatever the latency, the polled verdict equals the fixed-sleep verdict.
    @Test(arguments: [0, 15, 120, 349, 350, 351, 800] as [UInt64])
    func theVerdictNeverDiffersFromTheFixedSleepVerdict(latencyMs: UInt64) async {
        let polled = await runMove(stages: [(latencyMs, 9)])
        let legacy = await runMove(stages: [(latencyMs, 9)], schedule: legacyFixedSettle)
        #expect(polled.json["verified"] as? Bool == legacy.json["verified"] as? Bool)
        #expect(polled.json["reason"] as? String == legacy.json["reason"] as? String)
        #expect(polled.waitedNanoseconds <= legacy.waitedNanoseconds)
    }

    // MARK: Control Bar checkbox readback (play, record, cycle, metronome, count-in, autopunch)

    /// The loop this replaces slept 50 ms, read, and repeated for 12 reads: a latency of L ms was
    /// seen at max(50, ceil(L / 50) * 50) ms and nothing slower than 600 ms was seen at all.
    private static func oldCheckboxDetection(latencyMs: Int) -> Int? {
        let at = max(50, (latencyMs + 49) / 50 * 50)
        return at <= 600 ? at : nil
    }

    @Test func theCheckboxScheduleContainsEveryReadingOfTheOldLoopAndStartsImmediately() {
        let schedule = SettleSchedule.controlBarCheckbox
        #expect(schedule.windowNanoseconds == 600 * ms)
        let checkpoints = Set(schedule.checkpointsNanoseconds)
        for step in stride(from: UInt64(50), through: 600, by: 50) { #expect(checkpoints.contains(step * ms)) }
        #expect(schedule.checkpointsNanoseconds.first == 10 * ms)
    }

    /// The property that makes the change a pure shrink: for every latency in 1 ms steps, the new
    /// schedule sees what the old loop saw, no later, and sees nothing the old loop missed.
    @Test func noLatencyIsSeenLaterOrMissedComparedWithTheFixedLoop() {
        var checkpoints = [UInt64(0)] + SettleSchedule.controlBarCheckbox.checkpointsNanoseconds
        checkpoints.sort()
        var fasterCount = 0
        for latency in 0...700 {
            let new = checkpoints.first { $0 >= UInt64(latency) * ms }.map { Int($0 / ms) }
            let old = Self.oldCheckboxDetection(latencyMs: latency)
            if let old {
                #expect(new != nil, "latency \(latency) ms was seen by the old loop and must still be seen")
                if let new {
                    #expect(new <= old, "latency \(latency) ms: new \(new) vs old \(old)")
                    if new < old { fasterCount += 1 }
                }
            } else {
                #expect(new == nil, "latency \(latency) ms is beyond the old 600 ms window and must stay unseen")
            }
        }
        #expect(fasterCount >= 30)
    }

    private func checkbox(latencyMs: UInt64) -> (read: (UInt64) -> Bool?, waited: () -> UInt64) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(25_904)
        let window = builder.element(25_905)
        let element = builder.element(25_907)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [element])
        builder.setAttribute(element, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: false))
        let logic = VirtualLogic(stages: [(at: latencyMs * ms, apply: {
            builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: true))
        })])
        logic.click()
        let runtime = builder.makeLogicRuntime(appElement: app)
        return (
            read: { _ in
                AccessibilityChannel.waitForControlBarCheckboxValue(
                    element, runtime: runtime, wait: { logic.advance($0) }, matching: { $0 == true })
            },
            waited: { logic.waitedNanoseconds }
        )
    }

    @Test(arguments: [0, 3, 10, 25, 50, 60, 180, 599, 600] as [UInt64])
    func aCheckboxThatFlipsInLMillisecondsIsChargedNoMoreThanTheNextCheckpoint(latencyMs: UInt64) {
        let probe = checkbox(latencyMs: latencyMs)
        #expect(probe.read(0) == true)
        let expected = ([UInt64(0)] + SettleSchedule.controlBarCheckbox.checkpointsNanoseconds).first { $0 >= latencyMs * ms }
        #expect(probe.waited() == expected)
        if let old = Self.oldCheckboxDetection(latencyMs: Int(latencyMs)) { #expect(probe.waited() <= UInt64(old) * ms) }
        if latencyMs <= 10 { #expect(probe.waited() <= 10 * ms) }
    }

    @Test(arguments: [601, 700, 10_000] as [UInt64])
    func aCheckboxThatNeverFlipsInTimeIsStillReportedUnreadAfterTheWholeWindow(latencyMs: UInt64) {
        let probe = checkbox(latencyMs: latencyMs)
        #expect(probe.read(0) == nil)
        #expect(probe.waited() == 600 * ms)
    }
}
