import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#291 public assigned-send checked read", .serialized)
struct Issue291PublicSendReadTests {
    @Test("Checked bus choices use the existing legal bus domain", arguments:[257,999999])
    func outOfDomainCheckedBusIsUnknown(_ number: Int) {
        #expect(OutputAssignment.busNumber(ofMenuItemTitle:"Bus \(number) → Aux 1") == nil)
        #expect(OutputAssignment.busNumber(ofMenuItemTitle:"Bus 256 → Aux 1") == 256)
    }
    @Test func stalePublicSendReadWithholdsDataAndKeepsEffects() throws {
        let read = ChannelResult.success(HonestContract.encodeStateA(extras:[
            "current_destination":["kind":"bus","number":1],"send_ordinal":1,
            "navigation_attempted":true,"popup_menu_state":"closed","focus_restoration":"not_restored",
        ]))
        let refused = AccessibilityChannel.outputReadContextFailure(read,operation:"mixer.get_send_destination_verified")
        let body = try #require(sharedJSONObject(refused.message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        #expect(body["send_ordinal"] as? Int == 1)
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(body["focus_restoration"] as? String == "not_restored")
        let navigationAttempted = try #require(body["navigation_attempted"] as? Bool)
        #expect(navigationAttempted)
    }
    @Test func registeredReadOnlyPhysicalSendContract() throws {
        let spec = try #require(OperationRegistry.spec(tool:"logic_mixer",command:"get_send_destination_verified"))
        #expect(spec.mutability == .readOnly)
        #expect(spec.allowedParams == Set(["target_ref","project_ref","ordinal"]))
        #expect(ChannelRouter.v2RoutingTable["mixer.get_send_destination_verified"] == [.accessibility])
        let commands = try #require(WorkflowSkillCatalog.publicCommands["logic_mixer"])
        #expect(commands.contains("get_send_destination_verified"))
    }
    @Test("Malformed ordinals never reach a channel", arguments:[Value.int(-1),.double(1.5),.string("1.5"),.bool(true),.null])
    func invalidOrdinalHasNoAction(_ ordinal: Value) async throws {
        let result = await MixerDispatcher.handle(command:"get_send_destination_verified",
            params:["target_ref":.string("mix_unknown"),"ordinal":ordinal],router:ChannelRouter(),cache:StateCache())
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "invalid_params")
    }
    @Test("Legacy indices and write parameters cannot enter the send reader", arguments:["track","index","value","destination","slot"])
    func extraInputsRefused(_ key: String) async throws {
        let result = await MixerDispatcher.handle(command:"get_send_destination_verified",
            params:["target_ref":.string("mix_unknown"),"ordinal":.int(1),key:.int(1)],router:ChannelRouter(),cache:StateCache())
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "invalid_params")
    }
}
