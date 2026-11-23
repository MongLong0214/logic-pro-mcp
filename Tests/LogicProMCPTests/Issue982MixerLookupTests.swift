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

    static func runtime(
        observingLogicVersion version: String?, from base: AXLogicProElements.Runtime
    ) -> AXLogicProElements.Runtime {
        AXLogicProElements.Runtime(
            logicProPID: base.logicProPID,
            ax: base.ax,
            executeAppleScript: base.executeAppleScript,
            executeAppleScriptWithTimeout: base.executeAppleScriptWithTimeout,
            onScreenWindowList: { [] },
            postPopupMenuEscape: {},
            focusedApplicationPID: { nil },
            observeHost: { _ in .init(logicVersion: version, logicBuild: "fixture") }
        )
    }

    /// Logic 13's hidden Mixer is an observed negative result. The default read-only inventory
    /// must not descend an unrelated deep track tree before returning that result.
    @Test func logic13InventoryBoundsAHiddenMixerLookup() {
        let f = Self.fixture(.logic123, mixerShowing: false)
        let existing = f.builder.makeAXRuntime().children(f.window)
        let branch = (0...4).map { f.builder.element(9860 + $0) }
        for element in branch {
            f.builder.setAttribute(element, kAXRoleAttribute as String, kAXGroupRole as String)
        }
        for index in 0..<(branch.count - 1) {
            f.builder.setChildren(branch[index], [branch[index + 1]])
        }
        f.builder.setChildren(branch.last!, [])
        f.builder.setChildren(f.window, [branch[0]] + existing)
        let deepReads = MutableBox(0)
        let base = f.builder.makeLogicRuntime(
            appElement: f.app,
            childrenResultHandler: { element in
                if CFEqual(element, branch[4]) { deepReads.value += 1 }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let runtime = Self.runtime(observingLogicVersion: "13.0", from: base)

        #expect(AccessibilityChannel.mixerWithoutRevealForInventory(
            runtime: runtime, revealRequested: false) == nil)
        #expect(deepReads.value == 0, "the Logic 13 negative lookup descended past its bound")
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    /// Version uncertainty and an explicit reveal keep the complete legacy discovery. A bounded
    /// Logic 13 default read is the only path allowed to decide a shallow absence.
    @Test(arguments: [
        (nil, false), ("12.3", false), ("13.0", true), ("14.0", false),
    ] as [(String?, Bool)])
    func completeInventoryLookupRemainsForLegacyUnknownAndReveal(
        version: String?, revealRequested: Bool
    ) throws {
        let f = Self.fixture(.identified)
        let existing = f.builder.makeAXRuntime().children(f.window)
            .filter { !CFEqual($0, f.mixer) }
        let wrappers = (0...3).map { f.builder.element(9870 + $0) }
        for wrapper in wrappers {
            f.builder.setAttribute(wrapper, kAXRoleAttribute as String, kAXGroupRole as String)
        }
        for index in 0..<(wrappers.count - 1) {
            f.builder.setChildren(wrappers[index], [wrappers[index + 1]])
        }
        f.builder.setChildren(wrappers.last!, [f.mixer])
        f.builder.setChildren(f.window, existing + [wrappers[0]])
        let runtime = Self.runtime(
            observingLogicVersion: version,
            from: f.builder.makeLogicRuntime(appElement: f.app)
        )

        let found = try #require(AccessibilityChannel.mixerWithoutRevealForInventory(
            runtime: runtime, revealRequested: revealRequested)?.mixer)
        #expect(CFEqual(found, f.mixer))
    }

    @Test func logic13BoundedLookupPreservesUnreadMixerStatus() throws {
        let (f, failing) = try #require(Self.unidentified.first).fixture()
        let base = Self.runtime(f, failing: failing)
        let observed = try #require(AccessibilityChannel.mixerWithoutRevealForInventory(
            runtime: Self.runtime(observingLogicVersion: "13.0", from: base),
            revealRequested: false))
        #expect(observed.mixer == nil)
        #expect(observed.result.mixerChildrenUnread)
        #expect(!observed.result.attempted)
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
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
        builder.setRole(window,kAXWindowRole as String)
        builder.setAttribute(f.app,kAXWindowsAttribute as String,[window])
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
            params: ["track": "0", "reveal_mixer":"true"], runtime: runtime,
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

    @Test("#1262 window loss inside the menu helper stops every later actuation")
    func inventoryRevealRechecksWindowInsideMenuHelper() async throws {
        let (f,runtime,_,recorded) = Self.revealByKey(try #require(Self.unidentified.first))
        let b = f.builder, bar = b.element(126_280), item = b.element(126_281)
        b.setRole(bar,kAXMenuBarRole as String); b.setRole(item,kAXMenuBarItemRole as String)
        b.setAttribute(item,kAXTitleAttribute as String,"View")
        b.setChildren(bar,[item]); b.setChildren(item,[])
        b.setAttribute(f.app,kAXMenuBarAttribute as String,bar)
        let actuators = AccessibilityChannel.MenuClickActuators(
            activateLogic: {
                recorded.activations += 1
                if recorded.activations == 2 { b.setAttribute(f.app,kAXWindowsAttribute as String,[AXUIElement]()) }
                return true
            },postKeyEvent: { _,_,_ in Issue.record("Key after window loss"); return false },
            pressEscape: { Issue.record("Escape after window loss") },
            raiseMixerWindow: { Issue.record("Raise after window loss"); return false })
        let observed = await AccessibilityChannel.ensureMixerAreaVisibleForInventory(runtime:runtime,actuators:actuators)
        #expect(observed.mixer == nil)
        #expect(observed.result.windowUnavailable)
        #expect(recorded.activations == 2)
        #expect(b.actionCalls.isEmpty)
    }

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
