import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite(.serialized)
struct Issue373SameHandlerReadbackCreditTests {
    private static let ports = #"{"sources":["fabricated source"],"destinations":["fabricated destination"]}"#

    @Test func sameHandlerMIDIPortEchoIsProtocolSmokeNotSemanticCredit() async throws {
        let cache = StateCache()
        let router = ChannelRouter()
        let channel = MockChannel(id: .coreMIDI, successEnvelope: Self.ports)
        await router.register(channel)
        let tool = await MIDIDispatcher.handle(
            command: "list_ports", params: [:], router: router, cache: cache
        )
        let resource = try await ResourceHandlers.read(
            uri: "logic://midi/ports", cache: cache, router: router
        )
        let operations = await channel.executedOps
        #expect(operations.map(\.0) == ["midi.list_ports", "midi.list_ports"])
        let toolIsError = try #require(tool.isError as Bool?)
        #expect(!toolIsError)
        let first = try #require(tool.content.first)
        guard case .text(let response, _, _) = first else {
            Issue.record("Expected actual routed tool text")
            return
        }
        let readback = try #require(resource.contents.first?.text)
        #expect(response == Self.ports)
        #expect(readback == Self.ports)
        let result = try Self.result(
            .midiListPorts, response: Data(response.utf8), readback: Data(readback.utf8),
            source: "logic://midi/ports"
        )
        #expect(result.status == .protocolSmoke)
        #expect(!result.verified)
        #expect(result.verificationKind == .protocolSmoke)
        #expect(result.deferral?.code == .semanticValidatorUnavailable)
        let sameHandlerDetail = try #require(result.deferral?.detail.contains("same handler"))
        #expect(sameHandlerDetail)
        #expect(result.liveGateFailureReason == nil)
        let verified = try #require(result.readback?.verified as Bool?)
        #expect(!verified)
    }

    @Test func separateHostCoreMIDIPortCensusCanEarnSemanticCredit() throws {
        let result = try Self.result(
            .midiListPorts,
            response: Data(Self.ports.utf8),
            readback: Data(Self.ports.utf8),
            source: "host://coremidi/ports"
        )

        #expect(result.status == .passed)
        #expect(result.verified)
        #expect(result.verificationKind == .semanticReadback)
        #expect(result.deferral == nil)
    }

    @Test func divergentHostCoreMIDIPortCensusCannotEarnSemanticCredit() throws {
        let result = try Self.result(
            .midiListPorts,
            response: Data(Self.ports.utf8),
            readback: Data(#"{"sources":["different"],"destinations":["fabricated destination"]}"#.utf8),
            source: "host://coremidi/ports"
        )

        #expect(result.status == .notQualified)
        #expect(!result.verified)
        #expect(result.verificationKind == .typedDeferral)
        #expect(result.deferral?.code == .semanticMismatch)
    }


    @Test func echoOracleRetainsProtocolVerdictWithoutIndependentSemanticVerdict() throws {
        let data = Data(Self.ports.utf8)
        let consistency = try #require(SemanticOracleTable.midiListPorts.evaluate(
            responseData: data, readbackData: data
        ))
        #expect(consistency)
        let independentVerdict: Bool? = QualificationSemanticReadbackValidator.validate(
            operationID: "midi.list_ports", responseData: data, readbackData: data
        )
        let declined = independentVerdict == nil
        #expect(declined)
    }

    @Test(arguments: [
        #"{"sources":["different"],"destinations":["fabricated destination"]}"#,
        #"{"sources":false,"destinations":[]}"#,
        #"{"error":"unavailable"}"#
    ])
    func echoOracleStillRejectsDivergentAndMalformedReadback(readback: String) throws {
        let result = try Self.result(
            .midiListPorts, response: Data(Self.ports.utf8), readback: Data(readback.utf8),
            source: "logic://midi/ports"
        )
        let protocolVerdict = try #require(SemanticOracleTable.midiListPorts.evaluate(
            responseData: Data(Self.ports.utf8), readbackData: Data(readback.utf8)
        ))
        #expect(!protocolVerdict)
        let routedVerdict = try #require(QualificationSemanticReadbackValidator.validate(
            operationID: "midi.list_ports", responseData: Data(Self.ports.utf8),
            readbackData: Data(readback.utf8)
        ))
        #expect(!routedVerdict)
        #expect(result.status == .notQualified)
        #expect(result.deferral?.code == .semanticMismatch)
        #expect(!result.verified)
    }

    @Test func cachedLibraryInventoryEchoIsProtocolSmokeNotSemanticCredit() throws {
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.tracksListLibrary])
        let result = try Self.result(
            .tracksListLibrary, response: fixture.responseData, readback: fixture.readbackData,
            source: "logic://library/inventory"
        )
        #expect(result.status == .protocolSmoke)
        #expect(!result.verified)
        #expect(result.verificationKind == .protocolSmoke)
        #expect(result.deferral?.code == .semanticValidatorUnavailable)
        let verified = try #require(result.readback?.verified as Bool?)
        #expect(!verified)
    }

    @Test func separateHostLibraryPanelCensusCanCreditTheObservedOneColumnShape() throws {
        let inventory = Data(
            #"{"categories":["Aux","Bass","Drums","Effects","Guitar","Keys","Mix Bus","Vocal"],"presetsByCategory":{}}"#.utf8
        )
        let result = try Self.result(
            .tracksListLibrary,
            response: inventory,
            readback: inventory,
            source: QualificationSemanticReadbackValidator.libraryPanelReadbackSource
        )

        #expect(result.status == .passed)
        #expect(result.verified)
        #expect(result.verificationKind == .semanticReadback)
        #expect(result.deferral == nil)
    }

    @Test func oneColumnDuplicateLabelsRemainCreditableWithoutOwnershipClaim() throws {
        let inventory = Data(
            #"{"categories":["Bass","Bass"],"presetsByCategory":{}}"#.utf8
        )
        let result = try Self.result(
            .tracksListLibrary,
            response: inventory,
            readback: inventory,
            source: QualificationSemanticReadbackValidator.libraryPanelReadbackSource
        )

        #expect(result.status == .passed)
        #expect(result.verified)
    }

    @Test func separateHostLibraryPanelCensusAcceptsDeepSelectionOutsideImmediateList() throws {
        let inventory = Data(
            #"{"categories":["Bass","Drums"],"presetsByCategory":{"Bass":["Sub","Funky"]},"currentCategory":"Bass","currentPreset":"Acid Etched Bass"}"#.utf8
        )
        let result = try Self.result(
            .tracksListLibrary,
            response: inventory,
            readback: inventory,
            source: QualificationSemanticReadbackValidator.libraryPanelReadbackSource
        )

        #expect(result.status == .passed)
        #expect(result.verified)
    }

    @Test func ambiguousDuplicateSelectedCategoryCannotEarnSemanticCredit() throws {
        let inventory = Data(
            #"{"categories":["Bass","Bass"],"presetsByCategory":{"Bass":["Sub"]},"currentCategory":"Bass","currentPreset":"Sub"}"#.utf8
        )
        let result = try Self.result(
            .tracksListLibrary,
            response: inventory,
            readback: inventory,
            source: QualificationSemanticReadbackValidator.libraryPanelReadbackSource
        )

        #expect(result.status == .notQualified)
        #expect(result.deferral?.code == .semanticMismatch)
        #expect(!result.verified)
    }

    @Test func divergentHostLibraryPanelCensusCannotEarnSemanticCredit() throws {
        let response = Data(
            #"{"categories":["Bass"],"presetsByCategory":{"Bass":["Sub"]},"currentCategory":"Bass","currentPreset":"Sub"}"#.utf8
        )
        let readback = Data(
            #"{"categories":["Bass"],"presetsByCategory":{"Bass":["Funky"]},"currentCategory":"Bass","currentPreset":"Funky"}"#.utf8
        )
        let result = try Self.result(
            .tracksListLibrary,
            response: response,
            readback: readback,
            source: QualificationSemanticReadbackValidator.libraryPanelReadbackSource
        )

        #expect(result.status == .notQualified)
        #expect(result.deferral?.code == .semanticMismatch)
        #expect(!result.verified)
    }

    @Test func nearMatchLibraryPanelSourceCannotEarnSemanticCredit() throws {
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.tracksListLibrary])
        let result = try Self.result(
            .tracksListLibrary,
            response: fixture.responseData,
            readback: fixture.readbackData,
            source: "host://accessibility/library-panel/cache"
        )

        #expect(result.status == .protocolSmoke)
        #expect(!result.verified)
    }

    @Test func unavailableHostLibraryPanelSentinelCannotEarnSemanticCredit() throws {
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.tracksListLibrary])
        let result = try Self.result(
            .tracksListLibrary,
            response: fixture.responseData,
            readback: Data(
                #"{"available":false,"reason":"explicit_library_panel_unavailable"}"#.utf8
            ),
            source: QualificationSemanticReadbackValidator.libraryPanelReadbackSource
        )

        #expect(result.status == .notQualified)
        #expect(result.deferral?.code == .semanticMismatch)
        #expect(!result.verified)
    }

    @Test(arguments: [OperationID.pluginsGetParamVerified, .pluginsGetChannelEQStateVerified])
    func pluginResponseShapeDoesNotEarnIndependentReadbackCredit(_ id: OperationID) throws {
        let fixture = try #require(SemanticOracleFixtures.byOperationID[id])
        let oracle = try #require(SemanticOracleTable.byOperationID[id])
        let protocolVerdict = try #require(oracle.evaluate(responseData: fixture.responseData,
            readbackData: fixture.readbackData))
        #expect(protocolVerdict)
        let independent = QualificationSemanticReadbackValidator.validate(operationID: id.rawValue,
            responseData: fixture.responseData, readbackData: Data("unrelated readback".utf8))
        let declined = independent == nil
        #expect(declined)
        let result = try Self.result(id, response: fixture.responseData,
            readback: fixture.readbackData, source: "logic://system/health")
        #expect(result.status == .protocolSmoke)
        #expect(!result.verified)
        #expect(result.verificationKind == .protocolSmoke)
        #expect(result.deferral?.code == .semanticValidatorUnavailable)
        let readbackVerified = try #require(result.readback?.verified as Bool?)
        #expect(!readbackVerified)
        let malformed = try #require(QualificationSemanticReadbackValidator.validate(
            operationID: id.rawValue, responseData: Data("{}".utf8), readbackData: fixture.readbackData))
        #expect(!malformed)
    }


    private static func result(
        _ id: OperationID, response: Data, readback: Data, source: String
    ) throws -> QualificationOperationResult {
        let spec = try #require(OperationRegistry.specs.first { $0.id == id })
        let payload = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
        return QualificationOperationResult(
            operationID: id.rawValue, tool: spec.tool.rawValue, command: spec.command,
            mutability: .readOnly, requestID: "tool-response", responseData: response,
            isError: false, state: payload?["state"] as? String, error: nil, hint: nil, writeAttempted: false,
            readbackSource: source, readbackRequestID: "resource-readback",
            readbackData: readback, failureReason: nil
        )
    }

}
