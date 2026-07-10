@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private func regionTestAXPoint(_ x: CGFloat, _ y: CGFloat) -> AXValue {
    var point = CGPoint(x: x, y: y)
    return AXValueCreate(.cgPoint, &point)!
}

private func regionTestAXSize(_ width: CGFloat, _ height: CGFloat) -> AXValue {
    var size = CGSize(width: width, height: height)
    return AXValueCreate(.cgSize, &size)!
}

private func makeRegionRefreshChannel(
    builder: FakeAXRuntimeBuilder,
    app: AXUIElement
) -> AccessibilityChannel {
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app)
    )
    return AccessibilityChannel(runtime: runtime)
}

private func makeRegionRefreshFixture() -> (builder: FakeAXRuntimeBuilder, app: AXUIElement) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_200)
    let window = builder.element(1_201)
    let headerRail = builder.element(1_202)
    let trackHeader = builder.element(1_203)
    let contentGroup = builder.element(1_204)
    let region = builder.element(1_205)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [headerRail, contentGroup])
    builder.setAttribute(window, kAXPositionAttribute as String, regionTestAXPoint(0, 0))
    builder.setAttribute(window, kAXSizeAttribute as String, regionTestAXSize(1_200, 400))

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "Tracks header")
    builder.setChildren(headerRail, [trackHeader])

    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXPositionAttribute as String, regionTestAXPoint(0, 100))
    builder.setAttribute(trackHeader, kAXSizeAttribute as String, regionTestAXSize(200, 40))

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "Tracks contents")
    builder.setChildren(contentGroup, [region])

    builder.setAttribute(region, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(region, kAXDescriptionAttribute as String, "Live Region")
    builder.setAttribute(region, kAXHelpAttribute as String, "Region starts at 1 bars and ends at 2 bars, MIDI region.")
    builder.setAttribute(region, kAXPositionAttribute as String, regionTestAXPoint(240, 108))
    builder.setAttribute(region, kAXSizeAttribute as String, regionTestAXSize(320, 24))

    return (builder, app)
}

@Test func testProjectGetRegionsRefreshesRegionCache() async throws {
    let fixture = makeRegionRefreshFixture()
    let router = ChannelRouter()
    await router.register(makeRegionRefreshChannel(builder: fixture.builder, app: fixture.app))

    let cache = StateCache()
    await cache.updateRegions([
        RegionState(
            id: "stale",
            name: "stale region",
            trackIndex: 0,
            startPosition: "99 1 1 1",
            endPosition: "100 1 1 1",
            length: "1 0 0 0"
        )
    ], complete: true)

    let result = await ProjectDispatcher.handle(
        command: "get_regions",
        params: [:],
        router: router,
        cache: cache
    )

    let text = sharedToolText(result)
    let toolRegions = try RegionInfo.decodeToolPayload(text)
    #expect(toolRegions.count == 1)
    #expect(toolRegions[0].name == "Live Region")
    #expect(toolRegions[0].trackIndex == 0)

    let cached = await cache.getRegions()
    #expect(cached.count == 1)
    #expect(cached[0].name == "Live Region")
    #expect(cached[0].startPosition == "1 1 1 1")
    #expect(cached[0].endPosition == "2 1 1 1")
    #expect(!(await cache.getRegionsComplete()))
}

@Test func testTrackRegionsResourceRefreshesLiveScanWhenCacheIsStale() async throws {
    let fixture = makeRegionRefreshFixture()
    let router = ChannelRouter()
    await router.register(makeRegionRefreshChannel(builder: fixture.builder, app: fixture.app))

    let cache = StateCache()
    await cache.updateRegions([
        RegionState(
            id: "stale",
            name: "stale region",
            trackIndex: 0,
            startPosition: "99 1 1 1",
            endPosition: "100 1 1 1",
            length: "1 0 0 0"
        )
    ], complete: true)

    let result = try await ResourceHandlers.read(
        uri: "logic://tracks/0/regions",
        cache: cache,
        router: router
    )

    let regions = try JSONDecoder().decode([RegionState].self, from: Data(sharedResourceText(result).utf8))
    #expect(regions.count == 1)
    #expect(regions[0].name == "Live Region")
    #expect(regions[0].trackIndex == 0)
    #expect(regions[0].startPosition == "1 1 1 1")

    let cached = await cache.getRegions()
    #expect(cached.count == 1)
    #expect(cached[0].name == "Live Region")
    #expect(!(await cache.getRegionsComplete()))
}
