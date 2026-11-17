import Foundation
import Testing
@testable import LogicProMCP

/// `navigate.goto_bar` moves the playhead, so its independent readback is the transport resource.
/// Measured on Logic 13: reading the marker list for it answered `marker_list_not_open`
/// (`readable:false`, `source:"unreadable"`) while its restore cycle had verified, so the cycle
/// was filed restore_not_verified for want of an admissible readback.
@Suite("goto_bar qualification readback source")
struct QualificationGotoBarReadbackSourceTests {
    private func spec(_ id: OperationID) throws -> OperationSpec {
        try #require(OperationRegistry.specs.first { $0.id == id })
    }

    @Test func gotoBarIsReadBackFromTheTransportResource() throws {
        #expect(QualificationTransport.readbackSource(for: try spec(.navigateGotoBar))
            == "logic://transport/state")
    }

    @Test func theMarkerOperationsKeepTheMarkerList() throws {
        for id in [OperationID.navigateGotoMarker, .navigateCreateMarker, .navigateDeleteMarker,
                   .navigateRenameMarker] {
            #expect(QualificationTransport.readbackSource(for: try spec(id)) == "logic://markers", "\(id)")
        }
    }

    @Test func anUnreadableMarkerListStillRefusesTheMarkerOperations() {
        let refusal = Data(
            #"{"cache_age_sec":null,"readable":false,"source":"unreadable","data":[]}"#.utf8)
        let verdict = QualificationReadbackFreshness.verdict(
            for: refusal, uri: "logic://markers", verification: .readbackRequired, deadline: .short)
        #expect(!verdict.isAdmissible)
    }
}
