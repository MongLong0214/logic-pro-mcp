@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #982, the lookup. Logic 12.2 and 12.3 give the Mixer no identifier, so `getMixerArea` finds it
/// by reading its strips. A failed read there used to make the Mixer "not locatable": the readers
/// said "Cannot locate mixer", the writers "mixer area was not locatable", and `get_inventory`
/// went on to reveal a Mixer that may already have been showing.
extension Issue982UnreadChildrenTests {
    static func isNotFound(_ lookup: AXLogicProElements.MixerAreaLookup) -> Bool {
        if case .notFound = lookup { return true }
        return false
    }

    static let unidentified = UnreadMixer.all.filter { $0.layout != .identified }

    @Test(arguments: [Layout.logic122, .logic123])
    func theMixerIsFoundWithoutAnIdentifier(_ layout: Layout) throws {
        let f = Self.fixture(layout)
        let found = try #require(AXLogicProElements.mixerAreaLookup(runtime: Self.runtime(f)).mixer)
        #expect(CFEqual(found, f.mixer), "the Mixer, not the Inspector's two-strip one")
    }

    @Test(arguments: unidentified)
    func anUnreadMixerIsUnreadNotAbsent(_ unread: UnreadMixer) {
        let (f, failing) = unread.fixture()
        let lookup = AXLogicProElements.mixerAreaLookup(runtime: Self.runtime(f, failing: failing))
        #expect(lookup.childrenUnread, "\(lookup)")
        #expect(lookup.mixer == nil, "the Inspector's readable Mixer is not taken instead")
        #expect(AXLogicProElements.getMixerArea(runtime: Self.runtime(f, failing: failing)) == nil)
    }

    /// The Inspector's Mixer never stands in for the Mixer, and its own failed read says nothing
    /// about the Mixer.
    @Test(arguments: Layout.allCases)
    func anUnreadInspectorMixerDoesNotHideTheMixer(_ layout: Layout) throws {
        let f = Self.fixture(layout)
        let lookup = AXLogicProElements.mixerAreaLookup(runtime: Self.runtime(f, failing: f.inspectorMixer))
        let found = try #require(lookup.mixer)
        #expect(CFEqual(found, f.mixer))
    }

    @Test func aHiddenMixerIsNotFoundWhenOnlyTheInspectorsMixerFailsToRead() {
        let f = Self.fixture(.logic123, mixerShowing: false)
        #expect(Self.isNotFound(AXLogicProElements.mixerAreaLookup(runtime: Self.runtime(f))),
                "control: the Inspector's Mixer is not the Mixer")
        let lookup = AXLogicProElements.mixerAreaLookup(runtime: Self.runtime(f, failing: f.inspectorMixer))
        #expect(Self.isNotFound(lookup), "\(lookup)")
    }

    /// 12.3's toolbar is a Mixer-named container too. Its failed read does not hide a Mixer that
    /// reads beside it.
    @Test func anUnreadToolbarDoesNotHideTheMixerBesideIt() throws {
        let f = Self.fixture(.logic123)
        let toolbar = try #require(f.toolbar)
        let found = try #require(AXLogicProElements.mixerAreaLookup(runtime: Self.runtime(f, failing: toolbar)).mixer)
        #expect(CFEqual(found, f.mixer))
    }

    // MARK: - get_inventory does not reveal over an unread Mixer

    /// The inventory's reveal up to the point where it would actuate. Past it, a test would press
    /// View > Show Mixer or post key 7 to the running Logic.
    static let revealWithoutActuating: AccessibilityChannel.MixerRevealAction = { runtime in
        if let found = AccessibilityChannel.mixerWithoutReveal(runtime: runtime) { return found }
        Issue.record("the reveal would actuate")
        return (nil, AccessibilityChannel.MixerRevealResult(
            attempted: true, alreadyVisible: false, strategies: [], menuItemFound: false,
            menuClicked: false, keySent: false, mixerVisible: false))
    }

    @Test(arguments: UnreadMixer.all)
    func getInventoryReportsAnUnreadMixerAsUnreadAndRevealsNothing(_ unread: UnreadMixer) async throws {
        let (control, _) = unread.fixture()
        let whole = try Self.object(await AccessibilityChannel.defaultGetPluginInventory(
            params: ["track": "0"], runtime: Self.runtime(control), revealMixer: Self.revealWithoutActuating))
        #expect(whole["state"] as? String == "A", "control: the chain reads")

        let (f, failing) = unread.fixture()
        let runtime = Self.runtime(f, failing: failing)
        let obj = try Self.object(await AccessibilityChannel.defaultGetPluginInventory(
            params: ["track": "0"], runtime: runtime, revealMixer: Self.revealWithoutActuating))
        #expect(obj["state"] as? String == "B")
        #expect(obj["reason"] as? String == "readback_unavailable")
        #expect(obj["plugins_unknown_reason"] as? String == "ax_subtree_unreadable")
        #expect(obj["what_was_observed"] as? String == "the mixer's children did not read")
        #expect(!(try #require(obj["mixer_reveal_attempted"] as? Bool)))
        #expect(f.builder.actionCalls.isEmpty)
    }

    /// The production reveal starts with the step above. It is called only once that step has
    /// answered, so a regression here cannot reach the menu or key 7.
    @Test(arguments: unidentified)
    func theRevealStopsAtAnUnreadMixer(_ unread: UnreadMixer) async throws {
        let (f, failing) = unread.fixture()
        let runtime = Self.runtime(f, failing: failing)
        let first = try #require(AccessibilityChannel.mixerWithoutReveal(runtime: runtime),
                                 "nil lets View > Show Mixer or key 7 run over a Mixer that may be showing")
        #expect(first.mixer == nil)
        #expect(first.result.mixerChildrenUnread)
        #expect(!first.result.attempted)

        let revealed = await AccessibilityChannel.ensureMixerAreaVisibleForInventory(runtime: runtime)
        #expect(revealed.mixer == nil)
        #expect(revealed.result.mixerChildrenUnread)
        #expect(!revealed.result.attempted)
        #expect(revealed.result.strategies.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)

        // After a reveal, the poll ends at once on an unread Mixer: it is there, so waiting for it
        // to appear cannot help, and the next strategy could hide it again.
        let clock = ContinuousClock()
        let start = clock.now
        let polled = await AccessibilityChannel.pollMixerAreaVisible(runtime: runtime, timeoutMs: 2_500)
        #expect(polled.childrenUnread, "\(polled)")
        #expect(clock.now - start < .seconds(1))
    }

    // MARK: - Census

    @Test(arguments: unidentified)
    func theCensusNamesAnUnreadMixerAsUnreadable(_ unread: UnreadMixer) throws {
        let (f, failing) = unread.fixture()
        f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [f.window] as [AXUIElement])
        f.builder.setChildren(f.app, [f.window])
        let whole = try AXPluginInstanceIdentity.census(
            pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12, runtime: Self.runtime(f))
        #expect(whole.diagnostics.mixerFound, "control: the census finds this Mixer")

        let snapshot = try AXPluginInstanceIdentity.census(
            pluginName: "SN8K", identifierPrefix: "sn8k.instance:", maxDepth: 12,
            runtime: Self.runtime(f, failing: failing))
        #expect(snapshot.strips.isEmpty)
        #expect(!snapshot.stripsReadWhole)
        #expect(snapshot.diagnostics.note == "mixer-children-unreadable")
    }
}
