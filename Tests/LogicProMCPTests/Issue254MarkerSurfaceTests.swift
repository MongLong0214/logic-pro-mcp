@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private func issue254Envelope(_ result: ReadResource.Result) throws -> [String: Any] {
    let text = try #require(result.contents.first?.text)
    return try #require(
        JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    )
}

@Test func issue254CreateMarkerRoutesAccessibilityFirst() {
    let route = ChannelRouter.routingTable["nav.create_marker"]
    #expect(route?.first == .accessibility)
}

@Test func issue254CreateMarkerRejectsUnsafeNamesBeforeRouting() async {
    for name in [String(repeating: "x", count: 251), "unsafe\nname"] {
        let result = await NavigateDispatcher.handle(
            command: "create_marker",
            params: ["name": .string(name)],
            router: ChannelRouter(),
            cache: StateCache()
        )
        #expect(result.isError == true)
    }
}

@Test func issue254ClosedMarkerListIsUnreadableRatherThanVerifiedEmpty() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_400)
    builder.setAttribute(app, kAXWindowsAttribute as String, [AXUIElement]())

    let result = AccessibilityChannel.defaultGetMarkers(
        runtime: builder.makeLogicRuntime(appElement: app)
    )

    #expect(!result.isSuccess)
    #expect(result.message.contains("marker_list_not_open"))
}

@Test func issue254OpenEmptyMarkerListIsVerifiedEmpty() throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_410)
    let window = builder.element(25_411)
    let table = builder.element(25_412)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
    builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "Issue254 - Marker List")
    builder.setAttribute(window, kAXDocumentAttribute as String, "/Issue254.logicx")
    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(table, "AXRows", [AXUIElement]())
    builder.setChildren(window, [table])

    let result = AccessibilityChannel.defaultGetMarkers(
        runtime: builder.makeLogicRuntime(appElement: app)
    )

    #expect(result.isSuccess)
    let markers = try JSONDecoder().decode([MarkerState].self, from: Data(result.message.utf8))
    #expect(markers.isEmpty)
}

@Test func issue254MarkerResourceRefreshesFromLiveAX() async throws {
    let marker = MarkerState(id: 0, name: "Marker 1", position: "1.1.1.1")
    let cache = StateCache()
    await cache.updateMarkers([marker])

    let result = try await ResourceHandlers.read(
        uri: "logic://markers",
        cache: cache,
        router: ChannelRouter()
    )
    let envelope = try issue254Envelope(result)
    let data = try #require(envelope["data"] as? [[String: Any]])

    #expect(envelope["source"] as? String == "ax_live")
    #expect(envelope["readable"] as? Bool == true)
    #expect(envelope["verified_empty"] as? Bool == false)
    #expect((data.first?["name"] as? String) == "Marker 1")
    #expect(await cache.getMarkers().first?.name == "Marker 1")
}

@Test func issue254MarkerResourcePreservesCacheWhenLiveAXIsUnreadable() async throws {
    let cached = MarkerState(id: 0, name: "Cached Marker", position: "1.1.1.1")
    let cache = StateCache()
    await cache.updateMarkers([cached])
    await cache.markMarkersUnreadable()

    let result = try await ResourceHandlers.read(
        uri: "logic://markers",
        cache: cache,
        router: ChannelRouter()
    )
    let envelope = try issue254Envelope(result)
    let data = try #require(envelope["data"] as? [[String: Any]])

    #expect(envelope["source"] as? String == "cache")
    #expect(envelope["readable"] as? Bool == false)
    #expect(envelope["reason"] as? String == "marker_list_not_open")
    #expect((data.first?["name"] as? String) == "Cached Marker")
    #expect(await cache.getMarkers().first?.name == "Cached Marker")
}
