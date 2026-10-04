@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

// Native 86765165 recorded a same-read -25200 child failure at AXTextField path 8.1.48.0.0.
// These pure discovery witnesses isolate that leaf role; a field subtree is not rail authority.
private enum HeaderTextFieldReadFault: Sendable, Equatable {
    case none, siblingChildren, siblingRole, railChildren, railRole, headerName
}

private struct HeaderTextFieldReadFixture {
    let builder: FakeAXRuntimeBuilder
    let runtime: AXLogicProElements.Runtime
    let window: AXUIElement
    let row: AXUIElement
}

private func makeHeaderTextFieldReadFixture(
    siblingRole: String? = kAXTextFieldRole as String,
    fault: HeaderTextFieldReadFault = .siblingChildren,
    fieldFirst: Bool = false,
    railInsideField: Bool = false
) -> HeaderTextFieldReadFixture {
    let b = FakeAXRuntimeBuilder()
    let app = b.element(810_100)
    let window = b.element(810_101)
    let rail = b.element(810_102)
    let row = b.element(810_103)
    let name = b.element(810_104)
    let sibling = b.element(810_105)
    b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
    b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
    b.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setAttribute(name, kAXRoleAttribute as String, kAXTextFieldRole as String)
    b.setAttribute(name, kAXDescriptionAttribute as String, "Bass")
    b.setChildren(row, [name])
    b.setChildren(rail, [row])
    if let siblingRole { b.setAttribute(sibling, kAXRoleAttribute as String, siblingRole) }
    if railInsideField {
        b.setChildren(sibling, [rail])
        b.setChildren(window, [sibling])
    } else {
        b.setChildren(sibling, [])
        b.setChildren(window, fieldFirst ? [sibling, rail] : [rail, sibling])
    }
    b.setChildren(app, [window])
    b.setAttribute(app, kAXWindowsAttribute as String, [window])
    let runtime = b.makeLogicRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            if fault == .headerName, CFEqual(element, name),
               attribute == kAXValueAttribute as String {
                return .failure(AXHelpers.AXStatusError(raw: -25200))
            }
            guard attribute == kAXRoleAttribute as String else { return nil }
            if (fault == .siblingRole && CFEqual(element, sibling))
                || (fault == .railRole && CFEqual(element, rail)) {
                return .failure(AXHelpers.AXStatusError(raw: -25200))
            }
            return nil
        },
        childrenResultHandler: { element in
            if (fault == .siblingChildren && CFEqual(element, sibling))
                || (fault == .railChildren && CFEqual(element, rail)) {
                return .failure(AXHelpers.AXStatusError(raw: -25200))
            }
            return nil
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )
    return HeaderTextFieldReadFixture(builder: b, runtime: runtime, window: window, row: row)
}

private func expectNoHeaderTextFieldActuation(_ fixture: HeaderTextFieldReadFixture) {
    #expect(fixture.builder.actionCalls.isEmpty)
    #expect(fixture.builder.setCalls.isEmpty)
}

@Test(arguments: [false, true])
func testPluginTrackHeaderReadIgnoresUnreadKnownTextFieldOutsideRail(_ fieldFirst: Bool) {
    let fixture = makeHeaderTextFieldReadFixture(fieldFirst: fieldFirst)
    let result = AXLogicProElements.allTrackHeadersVerifiedRead(in: fixture.window, runtime: fixture.runtime)
    expectNoHeaderTextFieldActuation(fixture)
    switch result {
    case .read(let rows):
        #expect(rows.count == 1)
        #expect(rows.contains { CFEqual($0, fixture.row) },
                "the actual original rail row must survive, not a fabricated or rebound row")
        if let row = rows.first {
            switch AXValueExtractors.extractTrackNameResult(from: row, runtime: fixture.runtime.ax) {
            case .success(let name): #expect(name == "Bass")
            case .failure: #expect(Bool(false), "the retained rail name must remain readable")
            }
        }
    default:
        #expect(Bool(false), "known text-field children cannot supply or invalidate a separately readable rail")
    }
    expectNoHeaderTextFieldActuation(fixture)
}

@Test(arguments: [false, true], ["AXGroup", "unclassified"])
func testPluginTrackHeaderReadRefusesUnreadUnclassifiedSibling(_ fieldFirst: Bool, _ role: String) {
    let fixture = makeHeaderTextFieldReadFixture(
        siblingRole: role == "unclassified" ? nil : kAXGroupRole as String,
        fieldFirst: fieldFirst
    )
    let result = AXLogicProElements.allTrackHeadersVerifiedRead(in: fixture.window, runtime: fixture.runtime)
    expectNoHeaderTextFieldActuation(fixture)
    switch result {
    case .unreadable(let stage, let status):
        #expect(stage == "track_header_candidate_children")
        #expect(status == "-25200")
    default: #expect(Bool(false), "unclassified unread scope must not be skipped after finding a rail")
    }
}

@Test(arguments: [HeaderTextFieldReadFault.railChildren, .railRole, .siblingRole])
private func testPluginTrackHeaderReadRefusesUnreadRailOrRole(_ fault: HeaderTextFieldReadFault) {
    let fixture = makeHeaderTextFieldReadFixture(fault: fault)
    let result = AXLogicProElements.allTrackHeadersVerifiedRead(in: fixture.window, runtime: fixture.runtime)
    expectNoHeaderTextFieldActuation(fixture)
    switch result {
    case .unreadable(let stage, let status):
        #expect(stage == (fault == .railChildren
            ? "track_header_candidate_children" : "track_header_candidate_role"))
        #expect(status == "-25200")
    default: #expect(Bool(false), "a rail or unobserved text-field role is never an ignorable read failure")
    }
}

@Test func testPluginTrackHeaderReadDoesNotUseRailInsideTextField() {
    let fixture = makeHeaderTextFieldReadFixture(fault: .none, railInsideField: true)
    let result = AXLogicProElements.allTrackHeadersVerifiedRead(in: fixture.window, runtime: fixture.runtime)
    expectNoHeaderTextFieldActuation(fixture)
    if case .unavailable = result {
        // There is no rail outside the text field; no row or track authority may be minted.
    } else {
        #expect(Bool(false), "a Track Headers lookalike inside a text field is not an Arrange rail")
    }
}

@Test func testPluginTrackHeaderTextFieldIsolationPreservesUnreadActualHeaderNameRefusal() {
    let fixture = makeHeaderTextFieldReadFixture(fault: .headerName)
    let headerRead = AXLogicProElements.allTrackHeadersVerifiedRead(in: fixture.window, runtime: fixture.runtime)
    let nameRead = AXValueExtractors.extractTrackNameResult(from: fixture.row, runtime: fixture.runtime.ax)
    expectNoHeaderTextFieldActuation(fixture)
    if case .read(let rows) = headerRead {
        #expect(rows.count == 1)
        #expect(rows.contains { CFEqual($0, fixture.row) })
    } else {
        #expect(Bool(false), "rail discovery alone remains readable")
    }
    if case .failure(let error) = nameRead {
        #expect(error.diagnosticLabel == "-25200")
    } else {
        #expect(Bool(false), "the real header name read must retain its failure")
    }
}
