@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// AXPluginInstanceIdentity (#972): a host finds its OWN plug-in instances —
// strips whose insert slot names the plug-in, plus the kAXIdentifier each open
// editor window advertises. Read-only; composes the existing readers. Three
// outcomes are kept apart: empty (a note), partial (stripsReadWhole false),
// failed (thrown, never an empty array).

private func occupiedSlot(_ b: FakeAXRuntimeBuilder, _ id: Int, name: String) -> AXUIElement {
    let group = b.element(id)
    let bypass = b.element(id * 10 + 1)
    let open = b.element(id * 10 + 2)
    b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
    b.setAttribute(group, kAXDescriptionAttribute as String, name)
    b.setChildren(group, [bypass, open])
    b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
    b.setAttribute(bypass, kAXValueAttribute as String, 0)
    b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(open, kAXDescriptionAttribute as String, "열기")
    return group
}

private func strip(_ b: FakeAXRuntimeBuilder, _ id: Int, name: String, inserts: [String]) -> AXUIElement {
    let strip = b.element(id)
    b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    let nameField = b.element(id * 10 + 9)
    b.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    b.setAttribute(nameField, kAXValueAttribute as String, name)
    var children: [AXUIElement] = [nameField]
    for (i, insert) in inserts.enumerated() { children.append(occupiedSlot(b, id * 100 + i, name: insert)) }
    b.setChildren(strip, children)
    return strip
}

/// A plug-in editor window as `pluginEditorWindows` classifies it: AXDialog
/// subrole, a close button, a direct bypass toggle; our identifier nested deep.
private func editorWindow(_ b: FakeAXRuntimeBuilder, _ id: Int, title: String, identifier: String?) -> AXUIElement {
    let window = b.element(id)
    b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    b.setAttribute(window, kAXTitleAttribute as String, title)
    let close = b.element(id * 10 + 1)
    b.setAttribute(close, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(window, kAXCloseButtonAttribute as String, close)
    let bypass = b.element(id * 10 + 2)
    b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(bypass, kAXDescriptionAttribute as String, "Bypass")
    let remote = b.element(id * 10 + 3)
    b.setAttribute(remote, kAXRoleAttribute as String, kAXGroupRole as String)
    let root = b.element(id * 10 + 4)
    b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
    if let identifier { b.setAttribute(root, kAXIdentifierAttribute as String, identifier) }
    b.setChildren(remote, [root])
    b.setChildren(window, [bypass, remote])
    return window
}

/// App → main window → Mixer group with three strips (one hosting "SN8K",
/// one hosting the truncated label Logic writes); `windows` are added by the caller.
private func mixerFixture(_ b: FakeAXRuntimeBuilder) -> (app: AXUIElement, main: AXUIElement, mixer: AXUIElement, strips: [AXUIElement]) {
    let app = b.element(1)
    let main = b.element(2)
    b.setAttribute(main, kAXRoleAttribute as String, kAXWindowRole as String)
    let mixer = b.element(3)
    b.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
    b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
    let kick = strip(b, 10, name: "Kick", inserts: ["Compressor"])
    let snare = strip(b, 11, name: "Snare", inserts: ["SN8K"])
    let bass = strip(b, 12, name: "Bass", inserts: ["Channel EQ", "SN8KExtens"])   // Logic truncates the AU component name (measured 12.3.1)
    b.setChildren(mixer, [kick, snare, bass])
    b.setChildren(main, [mixer])
    b.setAttribute(app, kAXMainWindowAttribute as String, main)
    return (app, main, mixer, [kick, snare, bass])
}

private func windows(_ b: FakeAXRuntimeBuilder, _ app: AXUIElement, _ list: [AXUIElement]) {
    b.setAttribute(app, kAXWindowsAttribute as String, list as [AXUIElement])
    b.setChildren(app, list)
}

// MARK: - Whole read

@Test func censusFindsHostingStripsAndWindowIdentifiers() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    let w1 = editorWindow(b, 20, title: "Snare", identifier: "sn8k.instance:AAAA")
    let w2 = editorWindow(b, 21, title: "Bass", identifier: nil)
    windows(b, f.app, [f.main, w1, w2])

    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: b.makeLogicRuntime(appElement: f.app))

    #expect(snapshot.strips.map(\.ordinal) == [1, 2])
    #expect(snapshot.strips.map(\.name) == ["Snare", "Bass"])
    #expect(snapshot.strips.map(\.insertSlots) == [[0], [1]], "physical slot positions preserved")
    #expect(snapshot.stripsReadWhole)
    #expect(snapshot.windows.count == 2)
    #expect(snapshot.windows.first { $0.title == "Snare" }?.identifier == "sn8k.instance:AAAA")
    #expect(snapshot.windows.first { $0.title == "Bass" }?.identifier == nil, "no identifier is nil, never invented")
    #expect(snapshot.diagnostics.mixerFound && snapshot.diagnostics.mainWindowFound)
    #expect(snapshot.diagnostics.axWindowCount == 3 && !snapshot.diagnostics.windowsReadRetried)
    #expect(snapshot.diagnostics.note == nil)
}

// MARK: - Partial strip read: ordinals cannot be trusted, and the snapshot says so

@Test func censusReportsAPartialStripRead() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    let unreadable = f.strips[0]   // its role read fails: one Mixer child is unreadable
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: b.makeLogicRuntime(
            appElement: f.app,
            attributeValueHandler: { element, attribute in
                (CFEqual(element, unreadable) && attribute == kAXRoleAttribute as String) ? .some(nil) : nil
            },
            setAttributeHandler: nil, performActionHandler: nil))
    #expect(!snapshot.stripsReadWhole, "a child that refused its role makes the read PARTIAL")
    #expect(snapshot.strips.map(\.ordinal) == [0, 1], "the readable strips are still listed, at their enumeration ordinal")
    #expect(snapshot.strips.map(\.name) == ["Snare", "Bass"])
}

// MARK: - Failed windows read: thrown, carrying what was read, never an empty array

private final class ReadCounter: @unchecked Sendable { var reads = 0 }

@Test func censusThrowsWhenTheWindowsReadFails() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    let counter = ReadCounter()
    let runtime = b.makeLogicRuntime(
        appElement: f.app,
        attributeValueResultHandler: { element, attribute in
            guard CFEqual(element, f.app), attribute == kAXWindowsAttribute as String else { return nil }
            counter.reads += 1
            return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        },
        setAttributeHandler: nil, performActionHandler: nil)
    do {
        _ = try AXPluginInstanceIdentity.census(pluginName: "SN8K", identifierPrefix: "sn8k.instance:",
                                                maxDepth: 12, runtime: runtime)
        Issue.record("a failed windows read must THROW, never return an empty snapshot")
    } catch let AXPluginInstanceIdentity.CensusError.windowsReadFailed(status, strips, whole, diagnostics) {
        #expect(status == AXError.cannotComplete.rawValue)
        #expect(strips.map { $0.ordinal } == [1, 2], "the Mixer half that was read rides the error")
        #expect(whole)
        #expect(diagnostics.windowsReadRetried, "-25204 on the first app-level read was re-read once (#608 rule)")
        #expect(diagnostics.axWindowCount == nil, "a failed read is not a count")
        #expect(counter.reads >= 2, "one re-read, then the enumeration's own read")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

// MARK: - Plug-in present with no window; empty read is named

@Test func censusListsAHostingStripWithNoWindow() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: b.makeLogicRuntime(appElement: f.app))
    #expect(snapshot.strips.map(\.ordinal) == [1, 2])
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.stripsReadWhole)
    #expect(snapshot.diagnostics.note == nil, "something was found: no note")
}

/// The strip name is a census, not a first match (#976 review guard,
/// `check-ax-locator-census.py`): two distinct text-field readings on one strip
/// are an ambiguity the read-only census refuses (the strip keeps its ordinal,
/// name nil); a numeric readout beside the name field is not a reading.
@Test func censusRefusesAStripNameWithTwoDistinctReadings() throws {
    let b = FakeAXRuntimeBuilder()
    // A strip with two DIFFERENT text fields, one with the name field plus a
    // numeric level readout, and the plain shape the fixture uses everywhere.
    let twoReadings = strip(b, 20, name: "Kick", inserts: [])
    let rival = b.element(9001)
    b.setAttribute(rival, kAXRoleAttribute as String, kAXTextFieldRole as String)
    b.setAttribute(rival, kAXValueAttribute as String, "Kick 2")
    b.setChildren(twoReadings, [b.element(209), rival])            // 209 = strip 20's name field
    let withReadout = strip(b, 21, name: "Snare", inserts: [])
    let readout = b.element(9002)
    b.setAttribute(readout, kAXRoleAttribute as String, kAXStaticTextRole as String)
    b.setAttribute(readout, kAXValueAttribute as String, "-6.0")
    b.setChildren(withReadout, [b.element(219), readout])
    let plain = strip(b, 22, name: "Bass", inserts: [])
    // Two text fields that AGREE are one reading, not an ambiguity.
    let twin = strip(b, 23, name: "Hats", inserts: [])
    let echo = b.element(9003)
    b.setAttribute(echo, kAXRoleAttribute as String, kAXTextFieldRole as String)
    b.setAttribute(echo, kAXValueAttribute as String, "Hats")
    b.setChildren(twin, [b.element(239), echo])
    let ax = b.makeAXRuntime()
    #expect(AXPluginInstanceIdentity.stripName(twin, runtime: ax) == "Hats",
            "agreeing readings are one reading")
    #expect(AXPluginInstanceIdentity.stripName(twoReadings, runtime: ax) == nil,
            "two distinct readings: refused, not resolved by tree order")
    #expect(AXPluginInstanceIdentity.stripName(withReadout, runtime: ax) == "Snare",
            "a numeric readout beside the name field is not a reading")
    #expect(AXPluginInstanceIdentity.stripName(plain, runtime: ax) == "Bass")
}

@Test func censusNamesAnEmptyRead() throws {
    let b = FakeAXRuntimeBuilder()
    let app = b.element(1)
    let main = b.element(2)
    b.setAttribute(main, kAXRoleAttribute as String, kAXWindowRole as String)   // no Mixer inside
    b.setAttribute(app, kAXMainWindowAttribute as String, main)
    windows(b, app, [main])
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: b.makeLogicRuntime(appElement: app))
    #expect(snapshot.strips.isEmpty && snapshot.windows.isEmpty)
    #expect(!snapshot.diagnostics.mixerFound)
    #expect(snapshot.diagnostics.note == "mixer-not-found", "empty is NAMED, never silent")
}

@Test func censusThrowsWithoutLogic() {
    let b = FakeAXRuntimeBuilder()
    #expect(throws: AXPluginInstanceIdentity.CensusError.logicNotRunning) {
        try AXPluginInstanceIdentity.census(pluginName: "SN8K", identifierPrefix: "sn8k.instance:",
                                            maxDepth: 12, runtime: b.makeLogicRuntime(pid: nil))
    }
}

@Test func slotNameMatchesTruncatedComponentNames() {
    #expect(AXPluginInstanceIdentity.slotNameMatches("SN8KExtens", pluginName: "SN8K"))
    #expect(AXPluginInstanceIdentity.slotNameMatches("SN8K", pluginName: "SN8KExtension"))
    #expect(AXPluginInstanceIdentity.slotNameMatches(" sn8k ", pluginName: "SN8K"))
    #expect(!AXPluginInstanceIdentity.slotNameMatches("Compressor", pluginName: "SN8K"))
    #expect(!AXPluginInstanceIdentity.slotNameMatches(nil, pluginName: "SN8K"))
    #expect(!AXPluginInstanceIdentity.slotNameMatches("SN", pluginName: "SN8K"), "a 2-char label is not evidence")
}

// MARK: - A failed read is not a strip that hosts nothing (#976 review R-972-01)

/// Production answers one AX failure through both seams: `getChildren` gives [] and
/// `childrenResult` gives the status. A fixture failing only one of them would not be the
/// failure the census meets, so every case here fails both.
private func runtimeFailingChildren(
    of failing: AXUIElement, _ b: FakeAXRuntimeBuilder, app: AXUIElement
) -> AXLogicProElements.Runtime {
    b.makeLogicRuntime(
        appElement: app,
        childrenHandler: { CFEqual($0, failing) ? [] : nil },
        childrenResultHandler: { element in
            CFEqual(element, failing) ? .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)) : nil
        },
        setAttributeHandler: nil, performActionHandler: nil)
}

@Test func censusDoesNotReportAnUnreadMixerAsWhole() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: runtimeFailingChildren(of: f.mixer, b, app: f.app))
    #expect(snapshot.strips.isEmpty)
    #expect(!snapshot.stripsReadWhole, "the Mixer's children did not read: nothing is known about its strips")
    #expect(snapshot.diagnostics.mixerFound)
    #expect(snapshot.diagnostics.note == "mixer-children-unreadable")
}

@Test func censusDoesNotReportAnUnreadStripAsWhole() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: runtimeFailingChildren(of: f.strips[1], b, app: f.app))
    #expect(snapshot.strips.map(\.ordinal) == [2], "the strip that read is still listed")
    #expect(!snapshot.stripsReadWhole, "Snare's inserts did not read, so it may host the plug-in")
}

@Test func censusDoesNotReportAnUnreadInsertNameAsWhole() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    b.setAttribute(b.element(1000), kAXDescriptionAttribute as String, "")   // Kick's occupied insert 0
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: b.makeLogicRuntime(appElement: f.app))
    #expect(snapshot.strips.map(\.ordinal) == [1, 2])
    #expect(!snapshot.stripsReadWhole, "an occupied insert with no readable name may be the plug-in")
}

@Test func censusDoesNotReportAnInsertGroupItCouldNotReadAsWhole() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: runtimeFailingChildren(of: b.element(1100), b, app: f.app))   // 1100 = Snare's SN8K insert
    #expect(snapshot.strips.map(\.ordinal) == [2], "the insert could not be classified, so Snare is not listed")
    #expect(!snapshot.stripsReadWhole, "an insert group whose children did not read may be the plug-in")
}

@Test func censusDoesNotReportAnInsertWhoseRoleDidNotReadAsWhole() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    let insert = b.element(1100)   // Snare's SN8K insert
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: b.makeLogicRuntime(
            appElement: f.app,
            attributeValueHandler: { element, attribute in
                (CFEqual(element, insert) && attribute == kAXRoleAttribute as String) ? .some(nil) : nil
            },
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, insert), attribute == kAXRoleAttribute as String else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil, performActionHandler: nil))
    #expect(snapshot.strips.map(\.ordinal) == [2])
    #expect(!snapshot.stripsReadWhole, "an insert whose role did not read may be the plug-in")
}

@Test func censusTakesAnUnsupportedAttributeInAnInsertAsAnAnswer() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main])
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: b.makeLogicRuntime(
            appElement: f.app,
            attributeValueResultHandler: { _, attribute in
                attribute == kAXHelpAttribute as String
                    ? .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)) : nil
            },
            setAttributeHandler: nil, performActionHandler: nil))
    #expect(snapshot.strips.map(\.ordinal) == [1, 2])
    #expect(snapshot.stripsReadWhole, "-25205 says an element has no help text; it is not a failed read")
}

@Test func censusSaysWhenAWindowsIdentifierWalkWasNotWhole() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    let plain = editorWindow(b, 21, title: "Bass", identifier: nil)
    let unread = editorWindow(b, 22, title: "Hats", identifier: "sn8k.instance:BBBB")
    windows(b, f.app, [f.main, plain, unread])
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: runtimeFailingChildren(of: b.element(223), b, app: f.app))   // 223 = Hats' remote view group
    let bass = try #require(snapshot.windows.first { $0.title == "Bass" })
    let hats = try #require(snapshot.windows.first { $0.title == "Hats" })
    #expect(bass.identifier == nil)
    #expect(bass.identifierReadWhole, "walked whole and found none: absent")
    #expect(hats.identifier == nil)
    #expect(!hats.identifierReadWhole, "the view's children did not read: unknown, not absent")
}

@Test func censusSaysWhenTheIdentifierIsDeeperThanTheWalk() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main, editorWindow(b, 20, title: "Snare", identifier: "sn8k.instance:AAAA")])
    let runtime = b.makeLogicRuntime(appElement: f.app)
    let shallow = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 1, runtime: runtime)
    let window = try #require(shallow.windows.first)
    #expect(window.identifier == nil)
    #expect(!window.identifierReadWhole, "the view root sits below maxDepth, so it was never looked at")
    let deep = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 2, runtime: runtime)
    #expect(deep.windows.first?.identifier == "sn8k.instance:AAAA")
}

@Test func censusRefusesAnEmptyIdentifierPrefix() {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main, editorWindow(b, 20, title: "Snare", identifier: "anything:1")])
    #expect(throws: AXPluginInstanceIdentity.CensusError.emptyIdentifierPrefix) {
        try AXPluginInstanceIdentity.census(pluginName: "SN8K", identifierPrefix: "", maxDepth: 12,
                                            runtime: b.makeLogicRuntime(appElement: f.app))
    }
}

/// The stem direction a host relies on (`SN8K` against `SN8KExtens`, measured) matches any
/// label that begins with the stem. That is why a strip is a candidate and the window's
/// identifier is the identity.
@Test func slotNameMatchIsACandidateNotAnIdentity() {
    #expect(AXPluginInstanceIdentity.slotNameMatches("SN8KOther", pluginName: "SN8K"))
}

@Test func censusSaysWhenAnIdentifierReadFailed() throws {
    let b = FakeAXRuntimeBuilder()
    let f = mixerFixture(b)
    windows(b, f.app, [f.main, editorWindow(b, 20, title: "Snare", identifier: "sn8k.instance:AAAA")])
    let root = b.element(204)   // Snare's view root, the node carrying the identifier
    let snapshot = try AXPluginInstanceIdentity.census(
        pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
        runtime: b.makeLogicRuntime(
            appElement: f.app,
            attributeValueHandler: { element, attribute in
                (CFEqual(element, root) && attribute == kAXIdentifierAttribute as String) ? .some(nil) : nil
            },
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, root), attribute == kAXIdentifierAttribute as String else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil, performActionHandler: nil))
    let window = try #require(snapshot.windows.first)
    #expect(window.identifier == nil)
    #expect(!window.identifierReadWhole, "the identifier read failed: unknown, not absent")
}
