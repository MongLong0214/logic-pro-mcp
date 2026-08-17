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

@Test func issue254CreateMarkerRejectsUnsafeNamesBeforeRouting() async throws {
    for name in [String(repeating: "x", count: 251), "unsafe\nname"] {
        let result = await NavigateDispatcher.handle(
            command: "create_marker",
            params: ["name": .string(name)],
            router: ChannelRouter(),
            cache: StateCache()
        )
        let v1 = try #require(result.isError)
        #expect(v1)
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
    let v1 = try #require(envelope["readable"] as? Bool)
    #expect(v1)
    let v2 = try #require(envelope["verified_empty"] as? Bool)
    #expect(!v2)
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
    let v1 = try #require(envelope["readable"] as? Bool)
    #expect(!v1)
    #expect(envelope["reason"] as? String == "marker_list_not_open")
    #expect((data.first?["name"] as? String) == "Cached Marker")
    #expect(await cache.getMarkers().first?.name == "Cached Marker")
}

/// Before the first marker poll, `readable` is still its initial `false` — nobody has looked at
/// the Marker List yet. Reporting `marker_list_not_open` there states a cause that was never
/// observed. Measured live on 2026-08-17: a read four seconds into a process said the list was
/// not open while the window was open and the channel path read it without trouble. The poller
/// visits markers every fifth tick, so that window is ordinary, not exotic.
@Test func markerResourceDoesNotBlameAClosedListBeforeTheFirstPoll() async throws {
    let cache = StateCache()

    let result = try await ResourceHandlers.read(
        uri: "logic://markers",
        cache: cache,
        router: ChannelRouter()
    )
    let envelope = try issue254Envelope(result)

    let readable = try #require(envelope["readable"] as? Bool)
    #expect(!readable)
    #expect(envelope["reason"] as? String == "markers_not_polled_yet")
}

/// `nav.delete_marker` must work on a default install.
///
/// It used to route only to `[.midiKeyCommands, .cgEvent]`, so it did nothing at all until the
/// operator installed the key-command preset and performed a manual MIDI Learn inside Logic. Until
/// then the CC went out, Logic had nothing bound to it, the marker survived, and the caller was told
/// `readback_unavailable` — a setup prerequisite reported as a readback problem.
@Suite("nav.delete_marker has a target-faithful route")
struct MarkerDeleteRoutingTests {
    @Test("only AX can delete the requested marker index")
    func deleteMarkerRoutesOnlyThroughAccessibility() throws {
        let route = try #require(ChannelRouter.v2RoutingTable["nav.delete_marker"])
        #expect(route == [.accessibility])
    }

    @Test("the marker-list rungs the AX path depends on are all AX-routed")
    func supportingMarkerOperationsAreAXRouted() throws {
        for operation in ["nav.open_marker_list", "nav.get_markers"] {
            let route = try #require(ChannelRouter.v2RoutingTable[operation])
            #expect(route.contains(.accessibility))
        }
    }
}
