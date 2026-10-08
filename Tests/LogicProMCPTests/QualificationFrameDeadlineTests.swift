import Dispatch
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Qualification response deadlines")
struct QualificationFrameDeadlineTests {
    private let frame = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)

    @Test func queuedLateResponseDoesNotOutliveRequestDeadline() throws {
        let queue = QualificationFrameQueue()
        // The deadline is already past when the complete frame is received.
        let deadline = DispatchTime(uptimeNanoseconds: 0)
        try queue.append(frame)
        #expect(throws: QualificationTransportError.requestTimeout(phase: "handshake")) {
            _ = try queue.response(id: 1, phase: "handshake", deadline: deadline)
        }
    }

    @Test func queuedTimelyResponseSurvivesDelayedConsumer() throws {
        let queue = QualificationFrameQueue()
        try queue.append(frame)
        // Receipt preceded this deadline, but consumption follows it. Scheduling
        // delay must not turn an on-time response into a timeout.
        let response = try queue.response(
            id: 1, phase: "handshake", deadline: DispatchTime.now())
        #expect(response == frame)
    }

    @Test func expiredRequestWithoutMatchingResponseFailsClosed() throws {
        let queue = QualificationFrameQueue()
        try queue.append(frame)
        #expect(throws: QualificationTransportError.requestTimeout(phase: "readback")) {
            _ = try queue.response(
                id: 2, phase: "readback", deadline: DispatchTime(uptimeNanoseconds: 0)
            )
        }
    }

    @Test func closedQueueWithoutResponseRetainsClosedPipeFailure() {
        let queue = QualificationFrameQueue()
        queue.finish()
        #expect(throws: QualificationTransportError.closedPipe(phase: "handshake")) {
            _ = try queue.response(id: 1, phase: "handshake", deadline: .now() + 1)
        }
    }
}
