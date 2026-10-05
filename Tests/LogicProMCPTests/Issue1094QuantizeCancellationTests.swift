import Foundation
import Testing
@testable import LogicProMCP

@Suite("#1094 cancellation must stop the next quantize actuator")
struct Issue1094QuantizeCancellationTests {
    @Test func anAlreadyCancelledChildNeverOpensOrChoosesTheGrid() async throws {
        let fixture = QuantizeSafetyFixture()
        let child = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            #expect(Task.isCancelled)
            return await fixture.run()
        }
        let result = await child.value
        #expect(fixture.popupPresses == 0); #expect(fixture.leafPresses == 0)
        #expect(fixture.cleanups == 0); #expect(fixture.currentValue == "Off")
        #expect(!result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["state"] as? String == "C")
        #expect(object["quantize_refusal"] as? String == "cancelled")
        let written = try #require(object["write_attempted"] as? Bool); #expect(!written)
        let retry = try #require(object["safe_to_retry"] as? Bool); #expect(retry)
    }

    @Test func cancellationInsideTheOpenerStopsTheLeafAndCleansOnlyTheOwnedPopup() async throws {
        let fixture = QuantizeSafetyFixture()
        fixture.onOpen = {
            withUnsafeCurrentTask { task in task?.cancel() }
            #expect(Task.isCancelled)
        }
        let child = Task { await fixture.run() }
        let result = await child.value
        #expect(fixture.popupPresses == 1); #expect(fixture.leafPresses == 0)
        #expect(fixture.cleanups == 1); #expect(fixture.currentValue == "Off")
        #expect(fixture.runtime.ax.children(fixture.value).isEmpty)
        #expect(!result.isSuccess, "\(result.message)")
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["state"] as? String == "C")
        #expect(object["quantize_refusal"] as? String == "cancelled")
        let written = try #require(object["write_attempted"] as? Bool); #expect(written)
        let retry = try #require(object["safe_to_retry"] as? Bool); #expect(!retry)
    }
}
