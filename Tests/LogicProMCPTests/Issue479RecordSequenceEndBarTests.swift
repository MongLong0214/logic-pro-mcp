import Foundation
import Testing

@testable import LogicProMCP

/// #479 — a sequence ending exactly on a bar line was reported `timing_mismatch`.
///
/// Every expectation here is pinned to a live measurement on Logic 12.3 at 120 BPM 4/4, where one bar
/// is 2000 ms and a quarter note is 480 ticks. Four quarter notes fill bar 1 exactly; Logic reports
/// that region as bars 1 to 2, while the old calculation expected 3 and failed the write. Shortening
/// the last note by 100 ms made the identical sequence verify, which is what isolated the boundary.
@Suite("#479 record_sequence end-bar expectation")
struct Issue479RecordSequenceEndBarTests {
    private func notes(_ spans: [(offset: Int, duration: Int)]) -> [SMFWriter.NoteEvent] {
        spans.map {
            SMFWriter.NoteEvent(
                pitch: 60, offsetTicks: $0.offset, durationTicks: $0.duration, velocity: 100, channel: 0
            )
        }
    }

    @Test("four quarter notes fill bar 1 and end at bar 2, not bar 3")
    func exactBarBoundaryEndsOnTheLine() {
        let events = notes([(0, 480), (480, 480), (960, 480), (1440, 480)])
        #expect(TrackDispatcher.recordSequenceExpectedEndBar(for: events, requestedBar: 1) == 2)
    }

    @Test("the same sequence 100ms shorter also ends at bar 2 — the fix must not move this case")
    func justInsideTheBarStillEndsAtTwo() {
        // 400 ms at 120 BPM is 384 ticks, so the last note stops short of the line.
        let events = notes([(0, 480), (480, 480), (960, 480), (1440, 384)])
        #expect(TrackDispatcher.recordSequenceExpectedEndBar(for: events, requestedBar: 1) == 2)
    }

    @Test("a sequence filling two whole bars ends at bar 3")
    func twoFullBarsEndAtThree() {
        let events = notes([(0, 1920), (1920, 1920)])
        #expect(TrackDispatcher.recordSequenceExpectedEndBar(for: events, requestedBar: 1) == 3)
    }

    @Test("spilling one tick past a bar line pushes the end into the following bar")
    func oneTickPastTheLineTakesTheNextBar() {
        let events = notes([(0, 1921)])
        #expect(TrackDispatcher.recordSequenceExpectedEndBar(for: events, requestedBar: 1) == 3)
    }

    @Test("requestedBar shifts the whole span")
    func startBarOffsetsTheResult() {
        let events = notes([(0, 480), (480, 480), (960, 480), (1440, 480)])
        // Starting at bar 5, one full bar of notes ends on the bar-6 line.
        #expect(TrackDispatcher.recordSequenceExpectedEndBar(for: events, requestedBar: 5) == 6)
    }

    @Test("an empty sequence keeps the minimum of two rather than collapsing to one")
    func emptySequenceKeepsTheFloor() {
        #expect(TrackDispatcher.recordSequenceExpectedEndBar(for: [], requestedBar: 1) == 2)
    }

    @Test("a non-4/4 signature is measured in its own bar length")
    func threeFourIsMeasuredInThreeQuarterBars() {
        // Three quarter notes fill a 3/4 bar exactly.
        let events = notes([(0, 480), (480, 480), (960, 480)])
        #expect(
            TrackDispatcher.recordSequenceExpectedEndBar(
                for: events, requestedBar: 1, timeSignatureNumerator: 3
            ) == 2
        )
    }
}
