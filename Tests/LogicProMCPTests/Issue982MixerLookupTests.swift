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

    /// The inventory's reveal up to the point where it would actuate. Past it, the production reveal
    /// would press View > Show Mixer or post key 7 to the running Logic; a test that goes further
    /// injects `MenuClickActuators`, as the tests below do.
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
        let failingReads = MutableBox(0)
        let runtime = Self.runtime(f, failing: failing, failingReads: failingReads)
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

        // After a reveal, the poll ends on its first look at an unread Mixer: it is there, so
        // waiting for it to appear cannot help, and the next strategy could toggle it closed.
        // Counted rather than timed (#804): one lookup reads the failing element a fixed number
        // of times, and a poll that kept going to its 2.5 s deadline would read it about 25 times
        // that. Load can only make that loop turn fewer times, never make one look into two.
        failingReads.value = 0
        _ = AXLogicProElements.mixerAreaLookup(runtime: runtime)
        let readsPerLookup = failingReads.value
        #expect(readsPerLookup > 0, "control: a lookup reads the failing element")
        failingReads.value = 0
        let polled = await AccessibilityChannel.pollMixerAreaVisible(runtime: runtime, timeoutMs: 2_500)
        #expect(polled.childrenUnread, "\(polled)")
        #expect(failingReads.value == readsPerLookup, "the poll looked more than once")
    }

    // MARK: - The reveal after it has actuated

    /// What the reveal would have done to the running Logic. Nothing here reaches it.
    final class RecordedActuations: @unchecked Sendable {
        var activations = 0
        var keys: [(key: CGKeyCode, pid: pid_t)] = []
        /// Activations, Escapes and window raises after key 7. The menu retry that follows the
        /// key starts with an activation, so a nonzero count means the reveal went on.
        var actuationsAfterKey = 0
    }

    static func actuators(
        _ recorded: RecordedActuations, onKey: @escaping @Sendable () -> Void
    ) -> AccessibilityChannel.MenuClickActuators {
        AccessibilityChannel.MenuClickActuators(
            activateLogic: {
                if !recorded.keys.isEmpty { recorded.actuationsAfterKey += 1 }
                recorded.activations += 1
                return true
            },
            postKeyEvent: { key, _, pid in
                recorded.keys.append((key, pid))
                onKey()
                return true
            },
            pressEscape: { if !recorded.keys.isEmpty { recorded.actuationsAfterKey += 1 } },
            raiseMixerWindow: {
                if !recorded.keys.isEmpty { recorded.actuationsAfterKey += 1 }
                return true
            }
        )
    }

    /// The Mixer is not showing, and key 7 brings it up with children that do not read. The fixture
    /// has no menu bar, so the menu strategy finds nothing and the key is what reveals it.
    static func revealByKey(_ unread: UnreadMixer)
        -> (f: Fixture, runtime: AXLogicProElements.Runtime, actuators: AccessibilityChannel.MenuClickActuators,
            recorded: RecordedActuations)
    {
        let (f, failing) = unread.fixture()
        let builder = f.builder, window = f.window, mixer = f.mixerPath[0]
        let inspector = builder.element(9850)
        builder.setChildren(window, [inspector])
        let recorded = RecordedActuations()
        let actuators = Self.actuators(recorded) { builder.setChildren(window, [inspector, mixer]) }
        return (f, Self.runtime(f, failing: failing), actuators, recorded)
    }

    /// After an actuation, the reveal returns on an unread Mixer and reports what it did. It does
    /// not go on to the menu retry, which could toggle the Mixer closed.
    @Test(arguments: unidentified)
    func anUnreadMixerAfterTheKeyEndsTheReveal(_ unread: UnreadMixer) async throws {
        let (f, runtime, actuators, recorded) = Self.revealByKey(unread)
        #expect(AccessibilityChannel.mixerWithoutReveal(runtime: runtime) == nil,
                "control: no Mixer before the reveal")

        let revealed = await AccessibilityChannel.ensureMixerAreaVisibleForInventory(
            runtime: runtime, actuators: actuators)
        #expect(revealed.mixer == nil)
        #expect(revealed.result.mixerChildrenUnread)
        #expect(revealed.result.attempted)
        #expect(revealed.result.keySent)
        #expect(!revealed.result.menuClicked)
        #expect(!revealed.result.mixerVisible)
        #expect(revealed.result.strategies == ["cgevent_x"])
        #expect(recorded.keys.map(\.key) == [7])
        #expect(recorded.keys.map(\.pid) == [4242])
        #expect(recorded.activations > 0, "control: the actuators are the ones the reveal called")
        #expect(recorded.actuationsAfterKey == 0, "the reveal went on after the Mixer was found unread")
        #expect(f.builder.actionCalls.isEmpty)
    }

    /// The same reveal through `get_inventory`: the receipt says the Mixer did not read and that the
    /// reveal ran, and names the strategy.
    @Test(arguments: unidentified)
    func getInventoryReportsTheRevealThatFoundAnUnreadMixer(_ unread: UnreadMixer) async throws {
        let (_, runtime, actuators, recorded) = Self.revealByKey(unread)
        let obj = try Self.object(await AccessibilityChannel.defaultGetPluginInventory(
            params: ["track": "0"], runtime: runtime,
            revealMixer: { await AccessibilityChannel.ensureMixerAreaVisibleForInventory(runtime: $0, actuators: actuators) }))
        #expect(obj["state"] as? String == "B")
        #expect(obj["plugins_unknown_reason"] as? String == "ax_subtree_unreadable")
        #expect(obj["what_was_observed"] as? String == "the mixer's children did not read")
        #expect(try #require(obj["mixer_reveal_attempted"] as? Bool))
        #expect(obj["mixer_reveal_strategies"] as? [String] == ["cgevent_x"])
        #expect(try #require(obj["what_was_attempted"] as? String).hasPrefix("reveal the mixer"))
        #expect(recorded.keys.map(\.key) == [7])
        #expect(recorded.actuationsAfterKey == 0)
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
