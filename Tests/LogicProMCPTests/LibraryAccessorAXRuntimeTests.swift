@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

private func libraryAXPoint(_ x: CGFloat, _ y: CGFloat) -> AXValue {
    var point = CGPoint(x: x, y: y)
    return AXValueCreate(.cgPoint, &point)!
}

private func libraryAXSize(_ width: CGFloat, _ height: CGFloat) -> AXValue {
    var size = CGSize(width: width, height: height)
    return AXValueCreate(.cgSize, &size)!
}

private final class LibraryDoubleClickRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CGPoint] = []

    func record(_ point: CGPoint) -> Bool {
        lock.lock()
        storage.append(point)
        lock.unlock()
        return true
    }

    func points() -> [CGPoint] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LibraryClickRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CGPoint] = []

    func record(_ point: CGPoint) -> Bool {
        lock.lock()
        storage.append(point)
        lock.unlock()
        return true
    }

    func points() -> [CGPoint] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
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
    library: LibraryAccessor.Runtime,
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
    let library = LibraryAccessor.Runtime(
        ax: runtime.ax,
        postMouseClick: { _ in true },
        postMouseDoubleClick: { _ in true }
    )
    return (builder, app, window, browser, runtime, library, categoryList, presetList, horizontalScrollBar)
}

@Test func libraryAccessorEnumerateUsesInjectedAXRuntimeForColumnsAndSelection() {
    let fixture = makeLibraryPanelFixture()

    let inventory = LibraryAccessor.enumerate(runtime: fixture.runtime)

    #expect(inventory?.categories == ["Bass", "Drums"])
    #expect(inventory?.presetsByCategory["Bass"] == ["Sub", "Funky"])
    #expect(inventory?.currentCategory == "Bass")
    #expect(inventory?.currentPreset == "Sub")
    #expect(LibraryAccessor.currentPresets(runtime: fixture.runtime) == ["Sub", "Funky"])
    #expect(LibraryAccessor.isLibraryPanelOpen(runtime: fixture.runtime) == true)
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
    let fixture = makeLibraryPanelFixture()

    #expect(LibraryAccessor.selectCategory(
        named: "Bass",
        runtime: fixture.runtime,
        library: fixture.library
    ) == true)
    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        runtime: fixture.runtime,
        library: fixture.library
    ) == true)
    #expect(LibraryAccessor.setInstrument(
        category: "Bass",
        preset: "Sub",
        settleDelay: 0,
        runtime: fixture.runtime,
        library: fixture.library
    ) == true)

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
        library: fixture.library
    ) == true)
}

@Test func libraryAccessorCategoryUsesNativeClickAfterAXSelection() {
    let fixture = makeLibraryPanelFixture()
    let clicks = LibraryClickRecorder()
    let library = LibraryAccessor.Runtime(
        ax: fixture.runtime.ax,
        postMouseClick: { point in
            clicks.record(point)
        },
        postMouseDoubleClick: { _ in false }
    )

    #expect(LibraryAccessor.selectCategory(
        named: "Bass",
        runtime: fixture.runtime,
        library: library
    ) == true)
    #expect(clicks.points().count == 1)
}

@Test func libraryAccessorCategoryResetsHorizontalBrowserScrollBeforeSelection() {
    let fixture = makeLibraryPanelFixture()

    #expect(
        (fixture.builder.attributeValue(
            fixture.horizontalScrollBar,
            kAXValueAttribute as String
        ) as? NSNumber)?.intValue == 1
    )
    #expect(LibraryAccessor.selectCategory(
        named: "Bass",
        runtime: fixture.runtime,
        library: fixture.library
    ) == true)
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

    #expect(LibraryAccessor.selectCategory(
        named: "Bass",
        runtime: fixture.runtime,
        library: fixture.library
    ) == true)
    #expect(
        (fixture.builder.attributeValue(
            siblingScrollBar,
            kAXValueAttribute as String
        ) as? NSNumber)?.intValue == 0
    )
}

@Test func libraryAccessorPresetFallsBackToNativeDoubleClickWhenAXPressCannotComplete() {
    let fixture = makeLibraryPanelFixture()
    let doubleClicks = LibraryDoubleClickRecorder()
    let runtime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: nil,
        performActionHandler: { _, action in
            action != kAXPressAction as String
        }
    )
    let library = LibraryAccessor.Runtime(
        ax: runtime.ax,
        postMouseClick: { _ in false },
        postMouseDoubleClick: { point in
            doubleClicks.record(point)
        }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        runtime: runtime,
        library: library
    ) == true)
    #expect(doubleClicks.points().count == 1)
}

@Test func libraryAccessorPresetCommitsWithNativeDoubleClickAfterAXSelection() {
    let fixture = makeLibraryPanelFixture()
    let doubleClicks = LibraryDoubleClickRecorder()
    let library = LibraryAccessor.Runtime(
        ax: fixture.runtime.ax,
        postMouseClick: { _ in false },
        postMouseDoubleClick: { point in
            doubleClicks.record(point)
        }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        runtime: fixture.runtime,
        library: library
    ) == true)
    #expect(doubleClicks.points().count == 1)
}

@Test func libraryAccessorPresetDoesNotClickSameNamedLeftColumnCategory() {
    let fixture = makeLibraryPanelFixture()
    let clicks = LibraryClickRecorder()
    let doubleClicks = LibraryDoubleClickRecorder()
    fixture.builder.setAttribute(fixture.categoryList, kAXPositionAttribute as String, libraryAXPoint(80, 80))
    fixture.builder.setAttribute(fixture.categoryList, kAXSizeAttribute as String, libraryAXSize(360, 180))
    fixture.builder.setAttribute(fixture.presetList, kAXPositionAttribute as String, libraryAXPoint(80, 80))
    fixture.builder.setAttribute(fixture.presetList, kAXSizeAttribute as String, libraryAXSize(360, 180))
    let library = LibraryAccessor.Runtime(
        ax: fixture.runtime.ax,
        postMouseClick: { point in
            clicks.record(point)
        },
        postMouseDoubleClick: { point in
            doubleClicks.record(point)
        }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Bass",
        runtime: fixture.runtime,
        library: library
    ) == false)
    #expect(clicks.points().isEmpty)
    #expect(doubleClicks.points().isEmpty)
}

@Test func libraryAccessorPresetRequiresASecondVisibleColumn() {
    let fixture = makeLibraryPanelFixture()
    let clicks = LibraryClickRecorder()
    let doubleClicks = LibraryDoubleClickRecorder()
    fixture.builder.setChildren(fixture.browser, [fixture.categoryList, fixture.horizontalScrollBar])
    let library = LibraryAccessor.Runtime(
        ax: fixture.runtime.ax,
        postMouseClick: { point in
            clicks.record(point)
        },
        postMouseDoubleClick: { point in
            doubleClicks.record(point)
        }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Bass",
        commit: false,
        runtime: fixture.runtime,
        library: library
    ) == false)
    #expect(clicks.points().isEmpty)
    #expect(doubleClicks.points().isEmpty)
}

@Test func libraryAccessorPresetSearchesRightmostColumnWithVerticalScroll() {
    let fixture = makeLibraryPanelFixture()
    let verticalScrollBar = fixture.builder.element(10_010)
    let festivalDrop = fixture.builder.element(10_011)
    let doubleClicks = LibraryDoubleClickRecorder()
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
    let library = LibraryAccessor.Runtime(
        ax: runtime.ax,
        postMouseClick: { _ in false },
        postMouseDoubleClick: { point in
            doubleClicks.record(point)
        }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Festival Drop",
        runtime: runtime,
        library: library
    ) == true)
    #expect(events.events().contains("vertical-scroll"))
    #expect(doubleClicks.points().count == 1)
}

@Test func libraryAccessorPresetCanSelectIntermediateFolderWithoutDoubleClickCommit() {
    let fixture = makeLibraryPanelFixture()
    let doubleClicks = LibraryDoubleClickRecorder()
    let library = LibraryAccessor.Runtime(
        ax: fixture.runtime.ax,
        postMouseClick: { _ in false },
        postMouseDoubleClick: { point in
            doubleClicks.record(point)
        }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        commit: false,
        runtime: fixture.runtime,
        library: library
    ) == true)
    #expect(doubleClicks.points().isEmpty)
}

@Test func libraryAccessorIntermediateFolderUsesNativeClickWithoutDoubleClickCommit() {
    let fixture = makeLibraryPanelFixture()
    let clicks = LibraryClickRecorder()
    let doubleClicks = LibraryDoubleClickRecorder()
    let library = LibraryAccessor.Runtime(
        ax: fixture.runtime.ax,
        postMouseClick: { point in
            clicks.record(point)
        },
        postMouseDoubleClick: { point in
            doubleClicks.record(point)
        }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        commit: false,
        runtime: fixture.runtime,
        library: library
    ) == true)
    #expect(clicks.points().count == 1)
    #expect(doubleClicks.points().isEmpty)
}

@Test func libraryAccessorPresetClickUsesPointCapturedBeforeAXMutation() {
    let fixture = makeLibraryPanelFixture()
    let sub = fixture.builder.element(10_007)
    let clicks = LibraryClickRecorder()
    let runtime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, attribute, _ in
            if attribute == kAXSelectedChildrenAttribute as String {
                fixture.builder.setAttribute(sub, kAXPositionAttribute as String, libraryAXPoint(100, 100))
            }
            return true
        },
        performActionHandler: { _, _ in
            fixture.builder.setAttribute(sub, kAXPositionAttribute as String, libraryAXPoint(100, 100))
            return true
        }
    )
    let library = LibraryAccessor.Runtime(
        ax: runtime.ax,
        postMouseClick: { point in
            clicks.record(point)
        },
        postMouseDoubleClick: { _ in false }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        commit: false,
        runtime: runtime,
        library: library
    ) == true)
    #expect(clicks.points() == [CGPoint(x: 300, y: 110)])
}

@Test func libraryAccessorIntermediateFolderClicksBeforeAXSelectionCanSlideColumn() {
    let fixture = makeLibraryPanelFixture()
    let events = LibraryEventRecorder()
    let runtime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, attribute, _ in
            if attribute == kAXSelectedChildrenAttribute as String {
                events.record("set")
            }
            return true
        },
        performActionHandler: { _, action in
            if action == kAXPressAction as String {
                events.record("press")
            }
            return true
        }
    )
    let library = LibraryAccessor.Runtime(
        ax: runtime.ax,
        postMouseClick: { _ in
            events.record("click")
            return true
        },
        postMouseDoubleClick: { _ in false }
    )

    #expect(LibraryAccessor.selectPreset(
        named: "Sub",
        commit: false,
        runtime: runtime,
        library: library
    ) == true)
    #expect(events.events().first == "click")
}
