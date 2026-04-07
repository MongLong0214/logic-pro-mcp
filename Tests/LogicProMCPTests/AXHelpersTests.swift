@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

@Test func testAXHelpersReadAndWriteThroughInjectedRuntime() {
    let builder = FakeAXRuntimeBuilder()
    let root = builder.element(1)

    builder.setAttribute(root, kAXTitleAttribute as String, "Session")
    builder.setAttribute(root, kAXDescriptionAttribute as String, "Mixer")

    let runtime = builder.makeAXRuntime()

    #expect(AXHelpers.getTitle(root, runtime: runtime) == "Session")
    #expect(AXHelpers.getDescription(root, runtime: runtime) == "Mixer")
    #expect(AXHelpers.setAttribute(root, kAXValueAttribute as String, "99" as CFTypeRef, runtime: runtime))
    #expect(AXHelpers.performAction(root, kAXPressAction as String, runtime: runtime))
    #expect(builder.setCalls.count == 1)
    #expect(builder.actionCalls.count == 1)
}

@Test func testAXHelpersFindChildAndDescendantsRespectFiltersAndDepth() {
    let builder = FakeAXRuntimeBuilder()
    let root = builder.element(1)
    let group = builder.element(2)
    let button = builder.element(3)
    let nestedButton = builder.element(4)

    builder.setChildren(root, [group])
    builder.setChildren(group, [button])
    builder.setChildren(button, [nestedButton])

    builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(group, kAXIdentifierAttribute as String, "Transport")
    builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(button, kAXTitleAttribute as String, "Play")
    builder.setAttribute(nestedButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(nestedButton, kAXTitleAttribute as String, "Stop")

    let runtime = builder.makeAXRuntime()

    #expect(AXHelpers.findChild(of: root, role: kAXGroupRole, identifier: "Transport", runtime: runtime) == group)
    #expect(AXHelpers.findDescendant(of: root, role: kAXButtonRole, title: "Stop", maxDepth: 2, runtime: runtime) == nil)
    #expect(AXHelpers.findDescendant(of: root, role: kAXButtonRole, title: "Stop", maxDepth: 3, runtime: runtime) == nestedButton)
    #expect(AXHelpers.findAllDescendants(of: root, role: kAXButtonRole, maxDepth: 4, runtime: runtime) == [button, nestedButton])
}

@Test func testAXHelpersGetChildCountAndValueUseInjectedRuntime() {
    let builder = FakeAXRuntimeBuilder()
    let root = builder.element(1)
    let slider = builder.element(2)

    builder.setChildren(root, [slider])
    builder.setAttribute(slider, kAXValueAttribute as String, 0.75)
    builder.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)

    let runtime = builder.makeAXRuntime()

    #expect(AXHelpers.getChildCount(root, runtime: runtime) == 1)
    #expect((AXHelpers.getValue(slider, runtime: runtime) as? NSNumber)?.doubleValue == 0.75)
    #expect(AXHelpers.getRole(slider, runtime: runtime) == kAXSliderRole as String)
}

@Test func testAXHelpersReturnNilForMissingOrMismatchedAttributesAndRespectZeroDepth() {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(0)
    let root = builder.element(1)
    let child = builder.element(2)

    builder.setChildren(root, [child])
    builder.setAttribute(child, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(child, kAXIdentifierAttribute as String, "ChildID")
    builder.setAttribute(child, kAXValueAttribute as String, "not-a-number")

    let runtime = builder.makeAXRuntime(appElement: app)

    #expect(AXHelpers.axApp(pid: 999, runtime: runtime) == app)
    #expect(AXHelpers.getIdentifier(child, runtime: runtime) == "ChildID")
    #expect((AXHelpers.getAttribute(child, kAXValueAttribute as String, runtime: runtime) as NSNumber?) == nil)
    #expect(AXHelpers.findDescendant(of: root, role: kAXButtonRole, maxDepth: 0, runtime: runtime) == nil)
    #expect(AXHelpers.findAllDescendants(of: root, role: kAXButtonRole, maxDepth: 0, runtime: runtime).isEmpty)
    #expect(AXHelpers.findChild(of: root, role: kAXButtonRole, title: "Missing", runtime: runtime) == nil)
}

@Test func testAXHelpersProductionRuntimeHandlesSystemWideAndDetachedElementsSafely() {
    let runtime = AXHelpers.Runtime.production
    let systemWide = AXUIElementCreateSystemWide()
    let detachedApp = AXHelpers.axApp(pid: 0, runtime: runtime)

    let role = AXHelpers.getAttribute(systemWide, kAXRoleAttribute as String, runtime: runtime) as String?
    #expect(role == nil || !role!.isEmpty)

    let children = AXHelpers.getChildren(detachedApp, runtime: runtime)
    let childCount = AXHelpers.getChildCount(detachedApp, runtime: runtime)
    #expect(children.isEmpty)
    #expect(childCount == nil || childCount == children.count)

    let setResult = AXHelpers.setAttribute(
        detachedApp,
        kAXValueAttribute as String,
        "x" as CFTypeRef,
        runtime: runtime
    )
    let actionResult = AXHelpers.performAction(detachedApp, kAXPressAction as String, runtime: runtime)
    #expect(setResult == false)
    #expect(actionResult == false)
}
