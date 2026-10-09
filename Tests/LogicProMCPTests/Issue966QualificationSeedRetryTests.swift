import Foundation
import Testing
@testable import LogicProMCP

@Suite("Qualification seed fresh-read retry")
struct Issue966QualificationSeedRetryTests {
    private let refusal = #"{"state":"C","success":false,"error":"readback_unavailable","write_attempted":false,"navigation_performed":false,"ui_effects":{"attempted":[],"changed":[],"navigation_performed":false,"restoration":"not_applicable","reason":null}}"#

    @Test func oneRejectedReadCanSeedFromANewReadWithoutLosingTheRefusal() throws {
        var calls: [(Int, String)] = []
        let id = try QualificationTransport.sessionInspectionSeed(startingAt: 41) { requestID, phase in
            calls.append((requestID, phase))
            return calls.count == 1 ? (true, refusal) : (false, #"{"snapshot_id":"snap_fresh"}"#)
        }
        #expect(id == "snap_fresh")
        #expect(calls.map(\.0) == [41, 42])
        #expect(calls.map(\.1) == ["session_inspection_seed", "session_inspection_seed_retry"])
    }

    @Test func aSuccessfulFirstReadDoesNotRetry() throws {
        var count = 0
        let id = try QualificationTransport.sessionInspectionSeed(startingAt: 41) { _, _ in
            count += 1
            return (false, #"{"snapshot_id":"snap_first"}"#)
        }
        #expect(id == "snap_first")
        #expect(count == 1)
    }

    @Test func aSecondRejectedReadRemainsAFailure() {
        var count = 0
        #expect(throws: (any Error).self) {
            _ = try QualificationTransport.sessionInspectionSeed(startingAt: 41) { _, _ in
                count += 1
                return (true, refusal)
            }
        }
        #expect(count == 2)
    }

    @Test(arguments: [
        ("readback_unavailable", "operation_timeout"),
        ("readback_unavailable", "stale_snapshot"),
        ("readback_unavailable", "cancelled"),
        ("readback_unavailable", "wrong_target"),
        ("\"write_attempted\":false", "\"write_attempted\":true"),
        ("\"navigation_performed\":false", "\"navigation_performed\":true"),
        ("\"attempted\":[]", "\"attempted\":[\"track_selection\"]"),
        ("\"changed\":[]", "\"changed\":[\"track_selection\"]"),
        ("not_applicable", "restored"),
        ("\"reason\":null", "\"reason\":\"ownership_lost\""),
        ("\"state\":\"C\"", "\"state\":\"B\""),
        ("\"success\":false", "\"success\":true"),
        ("\"write_attempted\":false,", ""),
        ("\"write_attempted\":false", "\"write_attempted\":0"),
        ("\"success\":false", "\"success\":0"),
        ("\"attempted\":[],", ""),
        ("\"state\":\"C\"", "\"snapshot_id\":\"snap_old\",\"state\":\"C\""),
    ])
    func nonReadOnlyOrIncompleteRefusalsNeverRetry(_ replacement: (String, String)) {
        var count = 0
        let body = refusal.replacingOccurrences(of: replacement.0, with: replacement.1)
        #expect(throws: (any Error).self) {
            _ = try QualificationTransport.sessionInspectionSeed(startingAt: 41) { _, _ in
                count += 1
                return (true, body)
            }
        }
        #expect(count == 1)
    }

    @Test(arguments: ["{}", "not JSON", #"{"snapshot_id":""}"#])
    func malformedSuccessIsNotRetried(_ text: String) {
        var count = 0
        #expect(throws: (any Error).self) {
            _ = try QualificationTransport.sessionInspectionSeed(startingAt: 41) { _, _ in
                count += 1
                return (false, text)
            }
        }
        #expect(count == 1)
    }

    @Test func requestTimeoutIsNotRetried() {
        var count = 0
        #expect(throws: QualificationTransportError.requestTimeout(phase: "session_inspection_seed")) {
            _ = try QualificationTransport.sessionInspectionSeed(startingAt: 41) { _, phase in
                count += 1
                throw QualificationTransportError.requestTimeout(phase: phase)
            }
        }
        #expect(count == 1)
    }
}
