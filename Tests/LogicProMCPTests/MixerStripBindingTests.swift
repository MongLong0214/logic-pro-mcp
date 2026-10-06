@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class PluginBindingFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    let rail: AXUIElement
    let mixer: AXUIElement
    let headers: [AXUIElement]
    let strips: [AXUIElement]

    init(headerNames: [String] = (0..<9).map { "Track \($0)" } + ["Bass"],
         stripNames: [String] = (0..<9).map { "Track \($0)" } + ["Aux 1", "Aux 2", "Bass"]) {
        let b = builder
        app = b.element(30000)
        window = b.element(30001)
        rail = b.element(30002)
        mixer = b.element(30003)
        headers = headerNames.enumerated().map { index, name in
            let header = b.element(30100 + index)
            let field = b.element(30200 + index)
            b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(field, kAXDescriptionAttribute as String, name)
            b.setAttribute(field, kAXValueAttribute as String, "0")
            b.setChildren(header, [field])
            return header
        }
        strips = stripNames.enumerated().map { index, name in
            let strip = b.element(30300 + index)
            let field = b.element(30400 + index)
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(strip, kAXDescriptionAttribute as String, "1008 40 \(index)")
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(field, kAXDescriptionAttribute as String, "이름")
            b.setAttribute(field, kAXValueAttribute as String, name)
            b.setChildren(strip, [field])
            return strip
        }
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        b.setAttribute(mixer, kAXRoleAttribute as String, kAXLayoutAreaRole as String)
        b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(rail, headers)
        b.setChildren(mixer, strips)
        b.setChildren(window, [rail, mixer])
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
    }

    var runtime: AXLogicProElements.Runtime { builder.makeLogicRuntime(appElement: app) }
    func resolve(_ track: Int = 9) -> AXPluginTrackBinding.Binding? {
        AXPluginTrackBinding.resolve(track: track, mixer: mixer, runtime: runtime)
    }
}

private final class PluginBindingReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

@Test(arguments: ["name", "children"])
func pluginTrackBindingWaitRecoversOnlyTheSameElementsAfterTransientReads(_ stage: String) async throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    let counter = PluginBindingReadCounter()
    let name = f.builder.element(30411)
    let failure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
    let runtime = f.builder.makeLogicRuntime(appElement: f.app,
        attributeValueResultHandler: { element, attribute in
            guard stage == "name", CFEqual(element, name), attribute == kAXValueAttribute as String else { return nil }
            return counter.next() == 1 ? .failure(failure) : nil
        }, childrenResultHandler: { element in
            guard stage == "children", CFEqual(element, binding.strip) else { return nil }
            return counter.next() == 1 ? .failure(failure) : nil
        }, setAttributeHandler: nil, performActionHandler: nil)

    #expect(await AXPluginTrackBinding.waitUntilStable(binding, runtime: runtime, intervalMs: 1))
    #expect(counter.count >= 2, "a failed observation must be followed by a fresh successful read")
    #expect(CFEqual(binding.header, f.headers[9]) && CFEqual(binding.strip, f.strips[11]))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["name", "children"])
func pluginTrackBindingWaitRefusesPersistentRequiredReadFailure(_ stage: String) async throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    let name = f.builder.element(30411)
    let failure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
    let runtime = f.builder.makeLogicRuntime(appElement: f.app,
        attributeValueResultHandler: { element, attribute in
            stage == "name" && CFEqual(element, name) && attribute == kAXValueAttribute as String
                ? .failure(failure) : nil
        }, childrenResultHandler: { element in
            stage == "children" && CFEqual(element, binding.strip) ? .failure(failure) : nil
        }, setAttributeHandler: nil, performActionHandler: nil)

    #expect(!(await AXPluginTrackBinding.waitUntilStable(binding, runtime: runtime, timeoutMs: 20, intervalMs: 1)))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["header", "strip"])
func pluginTrackBindingWaitRefusesSameNameElementReplacement(_ stage: String) async throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    let replacement = f.builder.element(30500)
    f.builder.setAttribute(replacement, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    if stage == "header" {
        f.builder.setChildren(replacement, [f.builder.element(30209)])
        f.builder.setChildren(f.rail, Array(f.headers.dropLast()) + [replacement])
    } else {
        f.builder.setChildren(replacement, [f.builder.element(30411)])
        f.builder.setChildren(f.mixer, Array(f.strips.dropLast()) + [replacement])
    }
    #expect(f.resolve()?.trackName == binding.trackName, "replacement retains the name but not the acquired CF identity")
    #expect(!(await AXPluginTrackBinding.waitUntilStable(binding, runtime: f.runtime, timeoutMs: 20, intervalMs: 1)))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test func pluginTrackBindingWaitRefusesCancellationEvenWithReadableOriginalElements() async throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    let task = Task {
        // Enter the helper only after cancellation, without scheduler or elapsed-time assertions.
        while !Task.isCancelled { await Task.yield() }
        return await AXPluginTrackBinding.waitUntilStable(binding, runtime: f.runtime, timeoutMs: 20, intervalMs: 1)
    }
    task.cancel()
    #expect(!(await task.value))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test func pluginTrackBindingJoinsArrangeNineToMixerElevenPastAuxes() throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    #expect(binding.trackIndex == 9)
    #expect(binding.trackName == "Bass")
    #expect(binding.mixerStripIndex == 11)
    #expect(CFEqual(binding.header, f.headers[9]))
    #expect(CFEqual(binding.strip, f.strips[11]))
    #expect(AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test func pluginTrackBindingAllowsRealStripReorderButNotSameNameReplacement() throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    let reordered = [f.strips[11]] + Array(f.strips.dropLast())
    f.builder.setChildren(f.mixer, reordered)
    #expect(f.resolve()?.mixerStripIndex == 0)
    #expect(AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
    let replacement = f.builder.element(30500)
    f.builder.setAttribute(replacement, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    f.builder.setChildren(replacement, [f.builder.element(30411)])
    f.builder.setChildren(f.mixer, [replacement] + Array(reordered.dropFirst()))
    #expect(!AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
}

@Test func pluginTrackBindingRetainsTheAcquiredMixerWhenAnotherMixerIsDiscoverable() throws {
    let f = PluginBindingFixture()
    // Multi-window Arrange discovery requires the real Group rail, not the legacy AXList
    // fixture that only worked through the single-window fallback.
    f.builder.setAttribute(f.rail, kAXRoleAttribute as String, kAXGroupRole as String)
    f.builder.setAttribute(f.rail, kAXDescriptionAttribute as String, "트랙 헤더")
    let floatingWindow = f.builder.element(30600)
    let floatingMixer = f.builder.element(30601)
    let floatingStrip = f.builder.element(30602)
    let name = f.builder.element(30603)
    f.builder.setAttribute(floatingWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    f.builder.setAttribute(floatingMixer, kAXRoleAttribute as String, kAXLayoutAreaRole as String)
    f.builder.setAttribute(floatingMixer, kAXDescriptionAttribute as String, "Mixer")
    f.builder.setAttribute(floatingStrip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    f.builder.setAttribute(name, kAXRoleAttribute as String, kAXTextFieldRole as String)
    f.builder.setAttribute(name, kAXDescriptionAttribute as String, "이름")
    f.builder.setAttribute(name, kAXValueAttribute as String, "Bass")
    f.builder.setChildren(floatingStrip, [name])
    f.builder.setChildren(floatingMixer, [floatingStrip])
    f.builder.setChildren(floatingWindow, [floatingMixer])
    f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [floatingWindow, f.window])
    let binding = try #require(AXPluginTrackBinding.resolve(track: 9, mixer: floatingMixer, runtime: f.runtime))
    let globallyDiscovered = try #require(AXLogicProElements.getMixerArea(runtime: f.runtime))
    #expect(CFEqual(globallyDiscovered, f.mixer), "global discovery still prefers Arrange's embedded Mixer")
    #expect(CFEqual(binding.mixer, floatingMixer))
    let owner = try #require(AXPluginTrackBinding.owningWindow(binding, runtime: f.runtime))
    #expect(CFEqual(owner, floatingWindow), "the owning window is not the globally preferred Arrange window")
    #expect(AXPluginTrackBinding.isStable(binding, runtime: f.runtime),
            "validation must stay within the acquired Mixer, not silently choose the embedded copy")
    f.builder.setAttribute(name, kAXValueAttribute as String, "Bass DI")
    #expect(!AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
}

@Test func pluginTrackBindingOwningWindowUsesReadableAXWindowAttribute() throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    f.builder.setAttribute(f.mixer, kAXWindowAttribute as String, f.window)
    let runtime = f.builder.makeLogicRuntime(appElement: f.app,
        attributeValueResultHandler: { element, attribute in
            CFEqual(element, f.mixer) && attribute == kAXParentAttribute as String
                ? .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)) : nil
        }, setAttributeHandler: nil, performActionHandler: nil)
    let owner = try #require(AXPluginTrackBinding.owningWindow(binding, runtime: runtime))
    #expect(CFEqual(owner, f.window), "readable AXWindow does not need the fallback parent read")
}

@Test func pluginTrackBindingOwningWindowRefusesMalformedWindowInsteadOfParentFallback() throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    f.builder.setAttribute(f.mixer, kAXWindowAttribute as String, "not an AXWindow")
    #expect(AXPluginTrackBinding.owningWindow(binding, runtime: f.runtime) == nil,
            "the valid parent cannot replace a malformed AXWindow observation")
}

@Test(arguments: [false, true])
func pluginTrackBindingOwningWindowRefusesMalformedWindowsArray(_ malformedMember: Bool) throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    if malformedMember {
        f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [f.window as Any, "not a window"])
    } else {
        f.builder.setAttribute(f.app, kAXWindowsAttribute as String, "not an array")
    }
    #expect(AXPluginTrackBinding.owningWindow(binding, runtime: f.runtime) == nil,
            "a readable owner appearing in a partially malformed window list is not membership proof")
}

@Test(arguments: ["window", "parent", "parent_role", "windows"])
func pluginTrackBindingOwningWindowRefusesFailedRequiredRead(_ stage: String) throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    let target = stage == "parent_role" ? f.window : stage == "windows" ? f.app : f.mixer
    let key = stage == "window" ? kAXWindowAttribute as String
        : stage == "parent" ? kAXParentAttribute as String
        : stage == "parent_role" ? kAXRoleAttribute as String : kAXWindowsAttribute as String
    let runtime = f.builder.makeLogicRuntime(appElement: f.app,
        attributeValueResultHandler: { element, attribute in
            CFEqual(element, target) && attribute == key
                ? .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)) : nil
        }, setAttributeHandler: nil, performActionHandler: nil)
    #expect(AXPluginTrackBinding.owningWindow(binding, runtime: runtime) == nil)
}

@Test func pluginTrackBindingOwningWindowRefusesDetachedWindowOrUnknownParent() throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    #expect(AXPluginTrackBinding.owningWindow(binding, runtime: f.runtime) != nil)
    f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [AXUIElement]())
    #expect(AXPluginTrackBinding.owningWindow(binding, runtime: f.runtime) == nil,
            "a retained parent/window element is not evidence that its window is still live")
    f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [f.window])
    let unknown = f.builder.element(30604)
    f.builder.setAttribute(f.mixer, kAXParentAttribute as String, unknown)
    #expect(AXPluginTrackBinding.owningWindow(binding, runtime: f.runtime) == nil)
    f.builder.setAttribute(unknown, kAXRoleAttribute as String, kAXGroupRole as String)
    f.builder.setAttribute(unknown, kAXParentAttribute as String, unknown)
    #expect(AXPluginTrackBinding.owningWindow(binding, runtime: f.runtime) == nil,
            "parent cycles cannot invent a window owner")
}

@Test func pluginTrackBindingRefusesDuplicateTargetEvenAtMatchingOrdinal() {
    #expect(PluginBindingFixture(headerNames: ["Bass", "Bass"], stripNames: ["Bass", "Bass"]).resolve(0) == nil)
    #expect(PluginBindingFixture(headerNames: ["Bass"], stripNames: ["Bass", "Bass"]).resolve(0) == nil)
    #expect(PluginBindingFixture(headerNames: ["Bass", "Bass"], stripNames: ["Bass"]).resolve(0) == nil)
    let unrelated = PluginBindingFixture(headerNames: ["Drums", "Drums", "Bass"], stripNames: ["Drums", "Drums", "Aux", "Bass"])
    #expect(unrelated.resolve(2)?.mixerStripIndex == 3)
}

@Test func pluginTrackBindingRefusesMissingTargetAndUnknownSiblingName() {
    #expect(PluginBindingFixture(headerNames: ["Bass"], stripNames: ["Bass DI"]).resolve(0) == nil)
    let f = PluginBindingFixture()
    f.builder.setAttribute(f.builder.element(30400), kAXDescriptionAttribute as String, "Unqualified")
    #expect(f.resolve() == nil, "an unnamed sibling might be a second Bass")
    #expect(f.resolve(-1) == nil)
    #expect(f.resolve(42) == nil)
}

@Test func pluginTrackBindingRefusesUnknownOrConflictingArrangeNames() {
    let f = PluginBindingFixture()
    f.builder.setChildren(f.headers[0], [])
    #expect(f.resolve() == nil, "an unnamed Arrange sibling might be a second Bass")
    // The existing Arrange reader also measures names quoted in a header's own description.
    f.builder.setAttribute(f.headers[0], kAXDescriptionAttribute as String, "1개의 ‘Track 0’ 트랙")
    #expect(f.resolve()?.mixerStripIndex == 11)
    let rival = f.builder.element(30502)
    f.builder.setAttribute(rival, kAXRoleAttribute as String, kAXTextFieldRole as String)
    f.builder.setAttribute(rival, kAXDescriptionAttribute as String, "Bass DI")
    f.builder.setAttribute(rival, kAXValueAttribute as String, "0")
    f.builder.setChildren(f.headers[9], [f.builder.element(30209), rival])
    #expect(f.resolve() == nil, "different header name fields cannot be resolved by tree order")
}

@Test func pluginTrackBindingPreservesTitleOnlyArrangeHeaderNames() {
    let f = PluginBindingFixture()
    f.builder.setChildren(f.headers[0], [])
    f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, "Track 0")
    #expect(f.resolve()?.mixerStripIndex == 11)
}

@Test func pluginTrackBindingPreservesTitleFallbackReadFailure() {
    let f = PluginBindingFixture()
    f.builder.setChildren(f.headers[0], [])
    f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, "Track 0")
    let runtime = f.builder.makeLogicRuntime(appElement: f.app,
        attributeValueResultHandler: { element, attribute in
            CFEqual(element, f.headers[0]) && attribute == kAXTitleAttribute as String
                ? .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)) : nil
        }, setAttributeHandler: nil, performActionHandler: nil)
    #expect(AXPluginTrackBinding.resolve(track: 9, mixer: f.mixer, runtime: runtime) == nil)
    guard case .failure = AXValueExtractors.extractTrackNameResult(from: f.headers[0], runtime: runtime.ax) else {
        Issue.record("the title fallback must preserve the AX error")
        return
    }
}

@Test(arguments: ["header_name", "strip_name", "strip_role", "mixer_children", "rail_children", "windows"])
func pluginTrackBindingRefusesFailedRequiredReads(_ stage: String) {
    let f = PluginBindingFixture()
    let target = stage == "header_name" ? f.builder.element(30200)
        : stage == "strip_name" ? f.builder.element(30400)
        : stage == "strip_role" ? f.strips[0] : f.app
    let key = stage == "header_name" ? kAXDescriptionAttribute as String
        : stage == "strip_name" ? kAXValueAttribute as String
        : stage == "strip_role" ? kAXRoleAttribute as String : kAXWindowsAttribute as String
    let failure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
    let runtime = f.builder.makeLogicRuntime(appElement: f.app,
        attributeValueResultHandler: { element, attribute in
            ["header_name", "strip_name", "strip_role", "windows"].contains(stage)
                && CFEqual(element, target) && attribute == key ? .failure(failure) : nil
        }, childrenResultHandler: { element in
            if stage == "mixer_children", CFEqual(element, f.mixer) { return .failure(failure) }
            if stage == "rail_children", CFEqual(element, f.rail) { return .failure(failure) }
            return nil
        }, setAttributeHandler: nil, performActionHandler: nil)
    #expect(AXPluginTrackBinding.resolve(track: 9, mixer: f.mixer, runtime: runtime) == nil)
}

@Test func pluginTrackBindingRejectsNameDriftAndReplacedArrangeHeader() throws {
    let f = PluginBindingFixture()
    let binding = try #require(f.resolve())
    f.builder.setAttribute(f.builder.element(30411), kAXValueAttribute as String, "Bass DI")
    #expect(!AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
    f.builder.setAttribute(f.builder.element(30411), kAXValueAttribute as String, "Bass")
    let replacement = f.builder.element(30501)
    f.builder.setAttribute(replacement, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    f.builder.setChildren(replacement, [f.builder.element(30209)])
    f.builder.setChildren(f.rail, Array(f.headers.dropLast()) + [replacement])
    #expect(!AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
}

// R1116-001: raw names are identity inputs, not display strings to trim or normalize.
@Test(arguments: [false, true])
func plugin1116PaddedBindingNeverChoosesUnpaddedDecoy(_ decoyFirst: Bool) {
    let names = decoyFirst ? ["Bass", " Bass "] : [" Bass ", "Bass"]
    let f = PluginBindingFixture(headerNames: [" Bass "], stripNames: names)
    if let binding = f.resolve(0) {
        let paddedIndex = decoyFirst ? 1 : 0
        #expect(CFEqual(binding.strip, f.strips[paddedIndex]))
        #expect(binding.mixerStripIndex == paddedIndex)
        #expect(Array(binding.trackName.utf8) == Array(" Bass ".utf8))
    }
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test func plugin1116SinglePaddedBindingRemainsUsable() throws {
    let f = PluginBindingFixture(headerNames: [" Bass "], stripNames: [" Bass "])
    let binding = try #require(f.resolve(0))
    #expect(CFEqual(binding.header, f.headers[0]))
    #expect(CFEqual(binding.strip, f.strips[0]))
    #expect(Array(binding.trackName.utf8) == Array(" Bass ".utf8))
    #expect(AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["padding", "unicode"], [false, true])
func plugin1116ByteDistinctNamesRemainUniqueAtBothSides(_ kind: String, _ reverse: Bool) throws {
    let names = kind == "padding" ? [" Bass ", "Bass"] : ["\u{00E9}", "e\u{0301}"]
    #expect(Array(names[0].utf8) != Array(names[1].utf8))
    let strips = reverse ? Array(names.reversed()) : names
    let f = PluginBindingFixture(headerNames: names, stripNames: strips)
    for track in names.indices {
        let binding = try #require(f.resolve(track))
        let stripIndex = reverse ? 1 - track : track
        #expect(CFEqual(binding.header, f.headers[track]))
        #expect(CFEqual(binding.strip, f.strips[stripIndex]))
        #expect(binding.mixerStripIndex == stripIndex)
        #expect(Array(binding.trackName.utf8) == Array(names[track].utf8))
    }
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["field", "static", "quoted", "title"])
func plugin1116ArrangeNameFallbackPreservesPaddedBytes(_ source: String) throws {
    let f = PluginBindingFixture(headerNames: [" Bass "], stripNames: [" Bass "])
    if source != "field" {
        f.builder.setChildren(f.headers[0], [])
        if source == "static" {
            let text = f.builder.element(30520)
            f.builder.setAttribute(text, kAXRoleAttribute as String, kAXStaticTextRole as String)
            f.builder.setAttribute(text, kAXValueAttribute as String, " Bass ")
            f.builder.setChildren(f.headers[0], [text])
        } else if source == "quoted" {
            f.builder.setAttribute(f.headers[0], kAXDescriptionAttribute as String, "1개의 ‘ Bass ’ 트랙")
        } else {
            f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, " Bass ")
        }
    }
    let name = try #require(try AXValueExtractors.extractTrackNameResult(
        from: f.headers[0], runtime: f.runtime.ax
    ).get())
    #expect(Array(name.utf8) == Array(" Bass ".utf8))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["padding", "unicode"])
func plugin1116RetainedBindingRefusesByteDistinctNameDrift(_ kind: String) throws {
    let original = kind == "padding" ? "Bass" : "\u{00E9}"
    let changed = kind == "padding" ? " Bass " : "e\u{0301}"
    let f = PluginBindingFixture(headerNames: [original], stripNames: [original])
    let binding = try #require(f.resolve(0))
    f.builder.setAttribute(f.builder.element(30200), kAXDescriptionAttribute as String, changed)
    f.builder.setAttribute(f.builder.element(30400), kAXValueAttribute as String, changed)
    #expect(!AXPluginTrackBinding.isStable(binding, runtime: f.runtime))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["padding", "unicode"])
func plugin1116ReferenceGuardRefusesByteDistinctName(_ kind: String) throws {
    let live = kind == "padding" ? " Bass " : "\u{00E9}"
    let expected = kind == "padding" ? "Bass" : "e\u{0301}"
    let f = PluginBindingFixture(headerNames: [live], stripNames: [live])
    let refusal = try #require(AccessibilityChannel.targetTrackNameGuard(
        operation: "logic_plugins.insert_verified", track: 0, expectedTrackName: expected,
        identity: [:], runtime: f.runtime
    ))
    let object = try #require(JSONSerialization.jsonObject(with: Data(refusal.message.utf8)) as? [String: Any])
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "stale_target_reference")
    let attempted = try #require(object["write_attempted"] as? Bool)
    #expect(!attempted)
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["padding", "unicode"])
func plugin1116ReferenceGuardAllowsSameByteName(_ kind: String) {
    let name = kind == "padding" ? " Bass " : "e\u{0301}"
    let f = PluginBindingFixture(headerNames: [name], stripNames: [name])
    #expect(AccessibilityChannel.targetTrackNameGuard(
        operation: "logic_plugins.insert_verified", track: 0, expectedTrackName: name,
        identity: [:], runtime: f.runtime
    ) == nil)
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["padding", "unicode"])
func plugin1116ReferenceGuardAllowsByteUniqueSiblings(_ kind: String) {
    let names = kind == "padding" ? [" Bass ", "Bass"] : ["\u{00E9}", "e\u{0301}"]
    let f = PluginBindingFixture(headerNames: names, stripNames: names)
    for track in names.indices {
        #expect(AccessibilityChannel.targetTrackNameGuard(
            operation: "logic_plugins.insert_verified", track: track, expectedTrackName: names[track],
            identity: [:], runtime: f.runtime
        ) == nil)
    }
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: [false, true])
func plugin1116InventoryNeverAttributesDecoySlotsToPaddedTrack(_ decoyFirst: Bool) async throws {
    let names = decoyFirst ? ["Bass", " Bass "] : [" Bass ", "Bass"]
    let f = PluginBindingFixture(headerNames: [" Bass "], stripNames: names)
    for index in f.strips.indices {
        let slot = f.builder.element(30530 + index * 10)
        let bypass = f.builder.element(30531 + index * 10)
        let open = f.builder.element(30532 + index * 10)
        f.builder.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
        f.builder.setAttribute(slot, kAXDescriptionAttribute as String,
                               names[index].utf8.elementsEqual(" Bass ".utf8) ? "Gain" : "Compressor")
        f.builder.setAttribute(slot, kAXPositionAttribute as String, axPoint(100 + CGFloat(index) * 100, 300))
        f.builder.setAttribute(slot, kAXSizeAttribute as String, axSize(58, 16))
        f.builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        f.builder.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
        f.builder.setAttribute(bypass, kAXValueAttribute as String, 0)
        f.builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
        f.builder.setAttribute(open, kAXDescriptionAttribute as String, "열기")
        f.builder.setChildren(slot, [bypass, open])
        f.builder.setChildren(f.strips[index], [f.builder.element(30400 + index), slot])
    }
    let visibleMixer = try #require(AccessibilityChannel.mixerWithoutReveal(runtime: f.runtime)?.mixer)
    try #require(CFEqual(visibleMixer, f.mixer), "the production reveal fallback must be unreachable")
    let result = await AccessibilityChannel.defaultGetPluginInventory(params: ["track": "0"], runtime: f.runtime)
    let object = try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
    if object["state"] as? String == "A" {
        #expect(object["mixer_strip_index"] as? Int == (decoyFirst ? 1 : 0))
        let name = try #require(object["track_name"] as? String)
        #expect(Array(name.utf8) == Array(" Bass ".utf8))
        let plugins = try #require(object["plugins"] as? [[String: Any]])
        #expect(plugins.first?["name"] as? String == "Gain")
    } else {
        #expect(object["state"] as? String == "B", "safe unread binding is permitted, wrong-strip State A is not")
    }
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test func plugin1116SinglePaddedInventoryRemainsUsable() async throws {
    let f = PluginBindingFixture(headerNames: [" Bass "], stripNames: [" Bass "])
    let slot = f.builder.element(30560)
    f.builder.setAttribute(slot, kAXRoleAttribute as String, kAXButtonRole as String)
    f.builder.setAttribute(slot, kAXDescriptionAttribute as String, "오디오 플러그인")
    f.builder.setAttribute(slot, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
    f.builder.setAttribute(slot, kAXPositionAttribute as String, axPoint(100, 300))
    f.builder.setAttribute(slot, kAXSizeAttribute as String, axSize(58, 16))
    f.builder.setChildren(f.strips[0], [f.builder.element(30400), slot])
    let visibleMixer = try #require(AccessibilityChannel.mixerWithoutReveal(runtime: f.runtime)?.mixer)
    try #require(CFEqual(visibleMixer, f.mixer), "the production reveal fallback must be unreachable")
    let result = await AccessibilityChannel.defaultGetPluginInventory(params: ["track": "0"], runtime: f.runtime)
    let object = try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
    #expect(object["state"] as? String == "A")
    let complete = try #require(object["complete"] as? Bool)
    #expect(complete)
    let name = try #require(object["track_name"] as? String)
    #expect(Array(name.utf8) == Array(" Bass ".utf8))
    let plugins = try #require(object["plugins"] as? [[String: Any]])
    #expect(plugins.count == 1)
    #expect(plugins.first?["read_status"] as? String == "empty")
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["field", "static"])
func plugin1116ArrangeCensusRefusesByteDistinctReadings(_ source: String) throws {
    let names = ["\u{00E9}", "e\u{0301}"]
    #expect(Array(names[0].utf8) != Array(names[1].utf8))
    let f = PluginBindingFixture(headerNames: [names[0]], stripNames: [names[0]])
    let readings = names.enumerated().map { index, name in
        let element = f.builder.element(30570 + index)
        f.builder.setAttribute(element, kAXRoleAttribute as String,
                               source == "field" ? kAXTextFieldRole as String : kAXStaticTextRole as String)
        if source == "field" {
            f.builder.setAttribute(element, kAXDescriptionAttribute as String, name)
            f.builder.setAttribute(element, kAXValueAttribute as String, "0")
        } else {
            f.builder.setAttribute(element, kAXValueAttribute as String, name)
        }
        return element
    }
    f.builder.setChildren(f.headers[0], readings)
    let name = try AXValueExtractors.extractTrackNameResult(from: f.headers[0], runtime: f.runtime.ax).get()
    #expect(name == nil, "canonically equal but byte-distinct readings cannot identify one name")
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}

@Test(arguments: ["field", "static"])
func plugin1116ArrangeCensusAllowsSameByteReadings(_ source: String) throws {
    let observed = "e\u{0301}"
    let f = PluginBindingFixture(headerNames: [observed], stripNames: [observed])
    let readings = (0..<2).map { index in
        let element = f.builder.element(30580 + index)
        f.builder.setAttribute(element, kAXRoleAttribute as String,
                               source == "field" ? kAXTextFieldRole as String : kAXStaticTextRole as String)
        if source == "field" {
            f.builder.setAttribute(element, kAXDescriptionAttribute as String, observed)
            f.builder.setAttribute(element, kAXValueAttribute as String, "0")
        } else {
            f.builder.setAttribute(element, kAXValueAttribute as String, observed)
        }
        return element
    }
    f.builder.setChildren(f.headers[0], readings)
    let name = try #require(try AXValueExtractors.extractTrackNameResult(
        from: f.headers[0], runtime: f.runtime.ax
    ).get())
    #expect(Array(name.utf8) == Array(observed.utf8))
    #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
}
