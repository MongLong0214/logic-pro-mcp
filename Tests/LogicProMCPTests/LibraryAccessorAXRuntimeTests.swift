@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

/// Typed @Sendable "load observed" stub for commit tests that exercise the
/// selection/ladder MECHANISM. In production the channel layer injects the real
/// channel-strip instrument delta; the LibraryAccessor default is fail-closed.
/// Named (not an inline `{ true }`) so it survives the `#expect` macro's
/// @Sendable inference.
private let loadObserved: @Sendable () -> Bool = { true }

private func libraryAXPoint(_ x: CGFloat, _ y: CGFloat) -> AXValue {
    var point = CGPoint(x: x, y: y)
    return AXValueCreate(.cgPoint, &point)!
}

private func libraryAXSize(_ width: CGFloat, _ height: CGFloat) -> AXValue {
    var size = CGSize(width: width, height: height)
    return AXValueCreate(.cgSize, &size)!
}

private final class LibraryEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func makeLibraryPanelFixture() -> (
    builder: FakeAXRuntimeBuilder,
    app: AXUIElement,
    window: AXUIElement,
    browser: AXUIElement,
    runtime: AXLogicProElements.Runtime,
    categoryList: AXUIElement,
    presetList: AXUIElement,
    horizontalScrollBar: AXUIElement
) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(10_000)
    let window = builder.element(10_001)
    let browser = builder.element(10_002)
    let categoryList = builder.element(10_003)
    let presetList = builder.element(10_004)
    let bass = builder.element(10_005)
    let drums = builder.element(10_006)
    let sub = builder.element(10_007)
    let funky = builder.element(10_008)
    let horizontalScrollBar = builder.element(10_009)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [browser])
    builder.setAttribute(browser, kAXRoleAttribute as String, kAXBrowserRole as String)
    builder.setAttribute(browser, kAXDescriptionAttribute as String, "Library")
    builder.setAttribute(browser, kAXParentAttribute as String, window)
    builder.setChildren(browser, [categoryList, presetList, horizontalScrollBar])

    builder.setAttribute(categoryList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setChildren(categoryList, [bass, drums])
    builder.setAttribute(presetList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setChildren(presetList, [sub, funky])
    builder.setAttribute(horizontalScrollBar, kAXRoleAttribute as String, kAXScrollBarRole as String)
    builder.setAttribute(horizontalScrollBar, kAXOrientationAttribute as String, kAXHorizontalOrientationValue as String)
    builder.setAttribute(horizontalScrollBar, kAXValueAttribute as String, NSNumber(value: 1))

    for (element, value, x, y, parent) in [
        (bass, "Bass", CGFloat(100), CGFloat(100), categoryList),
        (drums, "Drums", CGFloat(100), CGFloat(130), categoryList),
        (sub, "Sub", CGFloat(260), CGFloat(100), presetList),
        (funky, "Funky", CGFloat(260), CGFloat(130), presetList),
    ] {
        builder.setAttribute(element, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(element, kAXValueAttribute as String, value)
        builder.setAttribute(element, kAXPositionAttribute as String, libraryAXPoint(x, y))
        builder.setAttribute(element, kAXSizeAttribute as String, libraryAXSize(80, 20))
        builder.setAttribute(element, kAXParentAttribute as String, parent)
    }

    builder.setAttribute(categoryList, kAXSelectedChildrenAttribute as String, [bass])
    builder.setAttribute(presetList, kAXSelectedChildrenAttribute as String, [sub])

    let runtime = builder.makeLogicRuntime(appElement: app)
    return (builder, app, window, browser, runtime, categoryList, presetList, horizontalScrollBar)
}

@Test func libraryAccessorEnumerateUsesInjectedAXRuntimeForColumnsAndSelection() {
    let fixture = makeLibraryPanelFixture()

    let inventory = LibraryAccessor.enumerate(runtime: fixture.runtime)

    #expect(inventory?.categories == ["Bass", "Drums"])
    #expect(inventory?.presetsByCategory["Bass"] == ["Sub", "Funky"])
    #expect(inventory?.currentCategory == "Bass")
    #expect(inventory?.currentPreset == "Sub")
    #expect(LibraryAccessor.currentPresets(runtime: fixture.runtime) == ["Sub", "Funky"])
    #expect(LibraryAccessor.isLibraryPanelOpen(runtime: fixture.runtime))
}

@Test func libraryAccessorEnumerateReadsRightmostSelectedPresetForDeepColumns() {
    let fixture = makeLibraryPanelFixture()
    let leafList = fixture.builder.element(10_010)
    let acid = fixture.builder.element(10_011)

    fixture.builder.setChildren(
        fixture.browser,
        [fixture.categoryList, fixture.presetList, leafList, fixture.horizontalScrollBar]
    )
    fixture.builder.setAttribute(leafList, kAXRoleAttribute as String, kAXListRole as String)
    fixture.builder.setChildren(leafList, [acid])
    fixture.builder.setAttribute(acid, kAXRoleAttribute as String, kAXStaticTextRole as String)
    fixture.builder.setAttribute(acid, kAXValueAttribute as String, "Acid Etched Bass")
    fixture.builder.setAttribute(acid, kAXPositionAttribute as String, libraryAXPoint(420, 100))
    fixture.builder.setAttribute(acid, kAXSizeAttribute as String, libraryAXSize(120, 20))
    fixture.builder.setAttribute(acid, kAXParentAttribute as String, leafList)
    fixture.builder.setAttribute(fixture.presetList, kAXSelectedChildrenAttribute as String, [
        fixture.builder.element(10_007),
    ])
    fixture.builder.setAttribute(leafList, kAXSelectedChildrenAttribute as String, [acid])

    let inventory = LibraryAccessor.enumerate(runtime: fixture.runtime)

    #expect(inventory?.currentCategory == "Bass")
    #expect(inventory?.currentPreset == "Acid Etched Bass")
}

@Test func libraryAccessorSegmentVisibleDetectsRowInVisibleBrowser() {
    // #135 — selectPath's segment-timing hardening polls for the next
    // segment's AXStaticText. `segmentIsVisible` is the read-only primitive
    // that poll uses: present rows → true, absent rows → false.
    let fixture = makeLibraryPanelFixture()

    #expect(LibraryAccessor.segmentIsVisible(named: "Sub", runtime: fixture.runtime))
    #expect(LibraryAccessor.segmentIsVisible(named: "Bass", runtime: fixture.runtime))
    #expect(!LibraryAccessor.segmentIsVisible(named: "Acid Etched Bass", runtime: fixture.runtime))
}

@Test func libraryAccessorSegmentVisibleCanRequireRightmostColumn() {
    let fixture = makeLibraryPanelFixture()

    #expect(LibraryAccessor.segmentIsVisible(named: "Bass", runtime: fixture.runtime))
    #expect(!LibraryAccessor.segmentIsVisible(
        named: "Bass",
        rightmostColumnOnly: true,
        runtime: fixture.runtime
    ))
    #expect(LibraryAccessor.segmentIsVisible(
        named: "Sub",
        rightmostColumnOnly: true,
        runtime: fixture.runtime
    ))
}

@Test func libraryAccessorWaitForSegmentReturnsPromptlyWhenAlreadyVisible() {
    // Already-visible row must not burn the full timeout.
    let fixture = makeLibraryPanelFixture()
    let start = Date()
    LibraryAccessor.waitForSegmentVisible(
        named: "Sub", timeout: 1.0, pollInterval: 0.02, runtime: fixture.runtime
    )
    #expect(Date().timeIntervalSince(start) < 0.5)
}

@Test func libraryAccessorWaitForRightmostSegmentIgnoresSameNamedLeftColumn() {
    let fixture = makeLibraryPanelFixture()
    let start = Date()

    LibraryAccessor.waitForSegmentVisible(
        named: "Bass",
        timeout: 0.12,
        pollInterval: 0.02,
        rightmostColumnOnly: true,
        runtime: fixture.runtime
    )

    #expect(Date().timeIntervalSince(start) >= 0.10)
}

@Test func libraryAccessorSelectionUsesInjectedSetAttributeAndActionRuntime() {
    // Coord-free selection wires AXSelectedChildren (on the containing AXList)
    // + AXPress. No mouse primitive exists anymore (compile-time guarantee:
    // there is no `library:` parameter and no post-mouse field to inject).
    let fixture = makeLibraryPanelFixture()

    #expect(LibraryAccessor.selectCategory(named: "Bass", runtime: fixture.runtime))
    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        runtime: fixture.runtime,
        observeCommitted: loadObserved
    ))
    #expect(LibraryAccessor.setInstrument(
        category: "Bass",
        preset: "Sub",
        settleDelay: 0,
        runtime: fixture.runtime,
        observeCommitted: loadObserved
    ))

    #expect(fixture.builder.setCalls.contains { $0.attribute == kAXSelectedChildrenAttribute as String })
    #expect(fixture.builder.actionCalls.contains { $0.action == kAXPressAction as String })
}

@Test func libraryAccessorPresetMatchesAXTextWithFilesystemPadding() {
    let fixture = makeLibraryPanelFixture()
    let padded = fixture.builder.element(10_008)
    fixture.builder.setAttribute(padded, kAXValueAttribute as String, "Padded Sub ")

    #expect(LibraryAccessor.selectPreset(
        named: "Padded Sub",
        runtime: fixture.runtime,
        observeCommitted: loadObserved
    ))
}

@Test func libraryAccessorCategoryResetsHorizontalBrowserScrollBeforeSelection() {
    let fixture = makeLibraryPanelFixture()

    #expect(
        (fixture.builder.attributeValue(
            fixture.horizontalScrollBar,
            kAXValueAttribute as String
        ) as? NSNumber)?.intValue == 1
    )
    #expect(LibraryAccessor.selectCategory(named: "Bass", runtime: fixture.runtime))
    #expect(
        (fixture.builder.attributeValue(
            fixture.horizontalScrollBar,
            kAXValueAttribute as String
        ) as? NSNumber)?.intValue == 0
    )
}

@Test func libraryAccessorCategoryResetsHorizontalSiblingScrollBeforeSelection() {
    let fixture = makeLibraryPanelFixture()
    let siblingScrollBar = fixture.builder.element(10_010)

    fixture.builder.setChildren(fixture.window, [fixture.browser, siblingScrollBar])
    fixture.builder.setAttribute(siblingScrollBar, kAXRoleAttribute as String, kAXScrollBarRole as String)
    fixture.builder.setAttribute(siblingScrollBar, kAXOrientationAttribute as String, kAXHorizontalOrientationValue as String)
    fixture.builder.setAttribute(siblingScrollBar, kAXValueAttribute as String, NSNumber(value: 1))

    #expect(LibraryAccessor.selectCategory(named: "Bass", runtime: fixture.runtime))
    #expect(
        (fixture.builder.attributeValue(
            siblingScrollBar,
            kAXValueAttribute as String
        ) as? NSNumber)?.intValue == 0
    )
}

@Test func libraryAccessorPresetDoesNotSelectSameNamedLeftColumnCategory() {
    // A left-column category name ("Bass") must NOT be selectable as a preset
    // (which prefers the right-most active column), even when the two AXList
    // frames overlap.
    let fixture = makeLibraryPanelFixture()
    fixture.builder.setAttribute(fixture.categoryList, kAXPositionAttribute as String, libraryAXPoint(80, 80))
    fixture.builder.setAttribute(fixture.categoryList, kAXSizeAttribute as String, libraryAXSize(360, 180))
    fixture.builder.setAttribute(fixture.presetList, kAXPositionAttribute as String, libraryAXPoint(80, 80))
    fixture.builder.setAttribute(fixture.presetList, kAXSizeAttribute as String, libraryAXSize(360, 180))

    #expect(!(LibraryAccessor.selectPreset(
        named: "Bass",
        runtime: fixture.runtime
    )))
}

@Test func libraryAccessorPresetRequiresASecondVisibleColumn() {
    let fixture = makeLibraryPanelFixture()
    fixture.builder.setChildren(fixture.browser, [fixture.categoryList, fixture.horizontalScrollBar])

    #expect(!(LibraryAccessor.selectPreset(
        named: "Bass",
        commit: false,
        runtime: fixture.runtime
    )))
}

@Test func libraryAccessorPresetSearchesRightmostColumnWithVerticalScroll() {
    // The vertical scroll-to-realize (scrollbar AXValue write) is coord-free and
    // still needed to bring an off-screen row into the AX tree before selection.
    let fixture = makeLibraryPanelFixture()
    let verticalScrollBar = fixture.builder.element(10_010)
    let festivalDrop = fixture.builder.element(10_011)
    let events = LibraryEventRecorder()

    fixture.builder.setChildren(
        fixture.browser,
        [fixture.categoryList, fixture.presetList, fixture.horizontalScrollBar, verticalScrollBar]
    )
    fixture.builder.setAttribute(verticalScrollBar, kAXRoleAttribute as String, kAXScrollBarRole as String)
    fixture.builder.setAttribute(verticalScrollBar, kAXOrientationAttribute as String, kAXVerticalOrientationValue as String)
    fixture.builder.setAttribute(verticalScrollBar, kAXValueAttribute as String, NSNumber(value: 0))
    fixture.builder.setAttribute(verticalScrollBar, kAXPositionAttribute as String, libraryAXPoint(360, 90))
    fixture.builder.setAttribute(verticalScrollBar, kAXSizeAttribute as String, libraryAXSize(16, 240))

    fixture.builder.setAttribute(festivalDrop, kAXRoleAttribute as String, kAXStaticTextRole as String)
    fixture.builder.setAttribute(festivalDrop, kAXValueAttribute as String, "Festival Drop")
    fixture.builder.setAttribute(festivalDrop, kAXPositionAttribute as String, libraryAXPoint(260, 160))
    fixture.builder.setAttribute(festivalDrop, kAXSizeAttribute as String, libraryAXSize(120, 20))
    fixture.builder.setAttribute(festivalDrop, kAXParentAttribute as String, fixture.presetList)

    let runtime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { element, attribute, value in
            if fixture.builder.elementID(element) == fixture.builder.elementID(verticalScrollBar),
               attribute == kAXValueAttribute as String,
               let number = value as? NSNumber,
               number.doubleValue >= 0.2 {
                events.record("vertical-scroll")
                fixture.builder.setChildren(fixture.presetList, [festivalDrop])
            }
            fixture.builder.setAttribute(element, attribute, value)
            return true
        },
        performActionHandler: { _, _ in true }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Festival Drop",
        runtime: runtime,
        observeCommitted: loadObserved
    ))
    #expect(events.events().contains("vertical-scroll"))
}

@Test func libraryAccessorPresetCanSelectIntermediateFolderWithoutCommit() {
    let fixture = makeLibraryPanelFixture()

    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        commit: false,
        runtime: fixture.runtime
    ))
}

// MARK: - Coord-free honesty + commit-ladder coverage (ADR-001)

@Test func libraryAccessorSelectionIsObservedEffectGatedNotDispatchGated() {
    // Honesty fix for the former `clicked || selectedChildrenOK || pressOK`
    // false-success: a DROPPED AXSelectedChildren write (the set "succeeds" and
    // AXPress dispatches) must still return FALSE because the selection
    // read-back never shows the target. Selecting "Drums" while the initial
    // selection stays "Bass" must fail closed.
    let fixture = makeLibraryPanelFixture()
    let runtime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, _, _ in true },   // writes "succeed" but store nothing
        performActionHandler: { _, _ in true }        // AXPress "succeeds"
    )

    #expect(!(LibraryAccessor.selectCategory(named: "Drums", runtime: runtime)))
}

@Test func libraryAccessorCommitLadderFiresCoordFreeRungsAndFailsClosed() {
    // observeCommitted:false → the LOAD is never observed, so the coord-free
    // ladder fires its universal action (AXPress) and then FAILS CLOSED. Live
    // 12.3: no coord-free action loads a preset. The disruptive AXConfirm and
    // the no-op Return are NOT in the ladder.
    let fixture = makeLibraryPanelFixture()

    let ok = LibraryAccessor.selectPreset(
        named: "Sub",
        runtime: fixture.runtime,
        observeCommitted: { false }
    )

    #expect(!ok)
    #expect(fixture.builder.actionCalls.contains { $0.action == kAXPressAction as String })
    // AXConfirm is deliberately excluded (opens Controller Assignments on 12.3).
    #expect(!fixture.builder.actionCalls.contains { $0.action == kAXConfirmAction as String })
}

@Test func libraryAccessorCommitSucceedsOnlyWhenLoadObserverWitnessesTheLoad() {
    // observeCommitted:true → the (simulated) instrument delta IS witnessed after
    // the fired action, so the ladder returns true. Proves the observer→State-A
    // wiring works WHEN a real load is observed (the channel layer supplies the
    // real delta in production).
    let fixture = makeLibraryPanelFixture()

    let ok = LibraryAccessor.selectPreset(
        named: "Sub",
        runtime: fixture.runtime,
        observeCommitted: { true }
    )

    #expect(ok)
    #expect(fixture.builder.actionCalls.contains { $0.action == kAXPressAction as String })
}

@Test func libraryAccessorCommitLadderFiresAdvertisedAXPickFirst() {
    // When the row advertises AXPick it is fired FIRST (before the universal
    // AXPress). With an observed load, the ladder short-circuits at AXPick.
    let fixture = makeLibraryPanelFixture()
    let sub = fixture.builder.element(10_007)
    let runtime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: nil,
        performActionHandler: nil,
        actionNamesHandler: { element in
            fixture.builder.elementID(element) == fixture.builder.elementID(sub)
                ? [kAXPressAction as String, kAXPickAction as String]
                : []
        }
    )

    let ok = LibraryAccessor.selectPreset(
        named: "Sub",
        runtime: runtime,
        observeCommitted: { true }
    )

    #expect(ok)
    #expect(fixture.builder.actionCalls.contains { $0.action == kAXPickAction as String })
}

@Test func libraryAccessorCommitFailsClosedWithoutLoadObserver() {
    // grok #1 + live wall: with NO injected load observer, a commit:true
    // selectPreset MUST fail closed. No coord-free action loads a preset, and
    // panel selection cannot witness a load, so returning true would be a false
    // State A. The ladder still fires its coord-free action (AXPress, no mouse),
    // but the honest return is false — the caller then reports State C.
    let fixture = makeLibraryPanelFixture()

    let ok = LibraryAccessor.selectPreset(named: "Sub", runtime: fixture.runtime)

    #expect(!ok)   // fail closed — no load observed
    #expect(fixture.builder.actionCalls.contains { $0.action == kAXPressAction as String })
}
