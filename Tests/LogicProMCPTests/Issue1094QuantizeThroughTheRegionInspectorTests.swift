import Foundation
import Testing
@testable import LogicProMCP

// Retains the original requested-grid/press-return/readback witnesses with a fully owned AX census.
@Suite("#1094 edit.quantize through the Region inspector")
struct Issue1094QuantizeThroughTheRegionInspectorTests {
    @Test func theRequestedGridIsChosenAndReadBack() async throws {
        let f = QuantizeSafetyFixture(); let result = await f.run()
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 1); #expect(f.currentValue == "1/16 Note")
        #expect(result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["before"] as? String == "Off"); #expect(object["after"] as? String == "1/16 Note")
    }
    @Test func aPressThatAnswersAnErrorButOpensTheMenuStillChoosesTheGrid() async throws {
        let f = QuantizeSafetyFixture(); f.pressReturns = false
        let result = await f.run(grid: "1/8")
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 1); #expect(f.currentValue == "1/8 Note")
        #expect(result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message))
        let popupReturned = try #require(object["popup_press_returned"] as? Bool)
        let itemReturned = try #require(object["item_press_returned"] as? Bool)
        #expect(!popupReturned); #expect(!itemReturned)
    }
    @Test func noSelectedRegionPressesNothing() async throws {
        let f = QuantizeSafetyFixture(selected: 0); let result = await f.run()
        #expect(f.popupPresses == 0); #expect(f.leafPresses == 0); #expect(f.currentValue == "Off")
        #expect(!result.isSuccess)
        let object = try #require(sharedJSONObject(result.message))
        let attempted = try #require(object["write_attempted"] as? Bool); #expect(!attempted)
    }
    @Test func aGridTheMenuDoesNotOfferIsRefusedAndTheMenuClosed() async throws {
        let f = QuantizeSafetyFixture(titles: ["Off", "1/8 Note"]); let result = await f.run()
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 0); #expect(f.cleanups == 1); #expect(f.currentValue == "Off")
        #expect(!result.isSuccess)
        let object = try #require(sharedJSONObject(result.message)); #expect(object["matching_items"] as? Int == 0)
    }
    @Test func aChoiceThatDidNotLandIsAMismatch() async throws {
        let f = QuantizeSafetyFixture(); f.choiceLands = false; let result = await f.run()
        #expect(f.popupPresses == 1); #expect(f.leafPresses == 1); #expect(f.currentValue == "Off")
        #expect(!result.isSuccess)
        let object = try #require(sharedJSONObject(result.message)); #expect(object["error"] as? String == "readback_mismatch")
    }
    @Test func theGridAlreadyShownIsUnchangedWithoutAPress() async throws {
        let f = QuantizeSafetyFixture(); f.b.setAttribute(f.value, "AXValue", "1/16 Note")
        let result = await f.run()
        #expect(f.popupPresses == 0); #expect(f.leafPresses == 0); #expect(result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message)); let changed = try #require(object["changed"] as? Bool)
        #expect(!changed)
    }
    @Test func noRowOrTwoRowsPressNothing() async throws {
        for rows in [0, 2] {
            let f = QuantizeSafetyFixture(rows: max(rows, 1))
            if rows == 0 { f.b.setAttribute(f.mode, "AXValue", "Q-Swing") }
            let result = await f.run()
            #expect(f.popupPresses == 0); #expect(f.leafPresses == 0); #expect(!result.isSuccess)
            let object = try #require(sharedJSONObject(result.message)); let attempted = try #require(object["write_attempted"] as? Bool)
            #expect(!attempted)
        }
    }
    @Test func aGridOutsideTheToolsListIsRefused() async throws {
        let f = QuantizeSafetyFixture(); let result = await f.run(grid: "1/3")
        #expect(f.popupPresses == 0); #expect(f.leafPresses == 0); #expect(!result.isSuccess)
        let object = try #require(sharedJSONObject(result.message)); #expect(object["error"] as? String == "invalid_params")
    }
    @Test func everyToolGridHasALabel() {
        #expect(Set(AXLocalePolicy.quantizeGridLabels.keys) == Set(EditDispatcher.validQuantizeGrids))
    }
    @Test func quantizeRoutesThroughAccessibilityAlone() {
        #expect(ChannelRouter.v2RoutingTable["edit.quantize"] == [.accessibility])
        #expect(MIDIKeyCommandsChannel.mappingTable["edit.quantize"] == nil)
        #expect(CGEventChannel.keyMap["edit.quantize"] == nil)
    }
}
