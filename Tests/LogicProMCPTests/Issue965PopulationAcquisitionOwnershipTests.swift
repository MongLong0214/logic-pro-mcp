import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#965 fresh population acquisition owns exclusive Logic access")
struct Issue965PopulationAcquisitionOwnershipTests {
    @Test func freshInspectionCannotEnterDuringAMutation() async throws {
        let gate = LogicMutationGate()
        let predecessor = try #require(gate.tryAcquire(operation: "logic_tracks.rename"))
        defer { gate.release(predecessor) }

        let result = await LogicProServer.runWithDeadline(
            tool: "logic_project", command: "inspect_session", mutationGate: gate
        ) {
            toolTextResult("acquisition entered")
        }

        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "mutating_operation_in_progress")
        #expect(!((try #require(body["write_attempted"] as? Bool))))
        #expect(gate.stillOwns(predecessor))
        #expect(gate.currentOperation() == "logic_tracks.rename")
    }

    @Test func freshInspectionCarriesARealClaimAndReleasesIt() async throws {
        let gate = LogicMutationGate()
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_project", command: "inspect_session", mutationGate: gate
        ) {
            let context = OperationTraceContext.current
            return toolTextResult(encodeJSON(Value.object([
                "acquired": .bool(context?.mutationGateAcquired ?? false),
                "owns": .bool(context?.ownsGate() ?? false),
                "active": .string(gate.currentOperation() ?? "none"),
            ])))
        }

        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(try #require(body["acquired"] as? Bool))
        #expect(try #require(body["owns"] as? Bool))
        #expect(body["active"] as? String == "logic_project.inspect_session")
        #expect(gate.currentOperation() == nil)
        // Inspection remains observational, not a project or audio mutation.
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_project", command: "inspect_session"))
    }

    @Test func historicalLookupDoesNotAcquireLogicAccess() async throws {
        let gate = LogicMutationGate()
        let predecessor = try #require(gate.tryAcquire(operation: "logic_tracks.rename"))
        defer { gate.release(predecessor) }
        let server = LogicProServer(pollerRuntime: .fastTest, mutationGate: gate)
        let handlers = await server.makeHandlers()
        let result = await handlers.callTool(.init(name: "logic_project", arguments: [
            "command": .string("inspect_session"),
            "params": .object(["snapshot_id": .string("unretained_snapshot")]),
        ]))
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "stale_snapshot",
                "historical lookup is a cache read, not a fresh acquisition or a mutation")
        #expect(gate.stillOwns(predecessor))
    }

    @Test func dispatchedFreshReadWithoutNavigationStillExcludesMutations() async throws {
        let gate = LogicMutationGate()
        let predecessor = try #require(gate.tryAcquire(operation: "logic_tracks.rename"))
        defer { gate.release(predecessor) }
        let server = LogicProServer(pollerRuntime: .fastTest, mutationGate: gate)
        let handlers = await server.makeHandlers()
        let result = await handlers.callTool(.init(name: "logic_project", arguments: [
            "command": .string("inspect_session"),
            "params": .object(["allow_ui_navigation": .bool(false)]),
        ]))
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "mutating_operation_in_progress")
        #expect(gate.stillOwns(predecessor))
    }

    @Test func navigationDisabledTimeoutDoesNotImplyAnUnknownWrite() async throws {
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_project", command: "inspect_session",
            commandParams: ["allow_ui_navigation": .bool(false)],
            deadlineOverride: 0.03, mutationGate: LogicMutationGate()
        ) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return toolTextResult("late read")
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "operation_timeout")
        #expect(!((try #require(body["write_attempted"] as? Bool))))
        #expect(try #require(body["safe_to_retry"] as? Bool))
        #expect(!((try #require(body["navigation_performed"] as? Bool))))
    }
}
