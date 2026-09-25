@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #982. `getChildren` answers a failed `kAXChildrenAttribute` read with [], so the strip and
/// insert enumerations read a Mixer they could not see as a Mixer with no strips, and a strip they
/// could not see as a strip with no inserts. They now answer nil for a failed read.
///
/// Production answers one AX failure through both seams: `children` gives [] and `childrenResult`
/// gives the status. A fixture failing only one of them is not the failure the code meets, so
/// every failing case here fails both.
@Suite("Issue #982 — a failed children read is not an empty Mixer or an empty insert chain")
struct Issue982UnreadChildrenTests {
    struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let app: AXUIElement
        let mixer: AXUIElement
        let strips: [AXUIElement]
    }

    /// Two strips. The first hosts one occupied insert and an empty slot, the second one empty slot.
    static func fixture() -> Fixture {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(9820)
        let window = b.element(9821)
        let mixer = b.element(9822)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setChildren(window, [mixer])
        // Located by identifier: `getMixerArea`'s other path finds a Mixer by reading its strip
        // children, so it never returns one whose children did not read.
        b.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
        let first = b.element(9830)
        let second = b.element(9831)
        for strip in [first, second] {
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        }
        b.setChildren(first, [occupiedSlot(b, 9840, name: "Compressor"), emptySlot(b, 9841)])
        b.setChildren(second, [emptySlot(b, 9842)])
        b.setChildren(mixer, [first, second])
        return Fixture(builder: b, app: app, mixer: mixer, strips: [first, second])
    }

    static func emptySlot(_ b: FakeAXRuntimeBuilder, _ id: Int) -> AXUIElement {
        let el = b.element(id)
        b.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(el, kAXDescriptionAttribute as String, "오디오 플러그인")
        b.setAttribute(el, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
        return el
    }

    static func occupiedSlot(_ b: FakeAXRuntimeBuilder, _ id: Int, name: String) -> AXUIElement {
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

    /// The children read of `failing` fails through both seams with `status`.
    static func runtime(
        _ f: Fixture, failing: AXUIElement? = nil, status: AXError = .cannotComplete
    ) -> AXLogicProElements.Runtime {
        f.builder.makeLogicRuntime(
            appElement: f.app,
            childrenHandler: { element in
                guard let failing, CFEqual(element, failing) else { return nil }
                return []
            },
            childrenResultHandler: { element in
                guard let failing, CFEqual(element, failing) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: status.rawValue))
            },
            setAttributeHandler: nil, performActionHandler: nil)
    }

    // MARK: - The enumerations

    @Test func aMixerThatReadsIsEnumerated() {
        let f = Self.fixture()
        let ax = Self.runtime(f).ax
        let enumeration = AXLogicProElements.stripEnumeration(in: f.mixer, runtime: ax)
        #expect(enumeration?.strips.count == 2)
        #expect(enumeration?.unreadableChildren == 0)
        #expect(AXLogicProElements.audioPluginInsertSlots(in: f.strips[0], runtime: ax)?.count == 2)
    }

    @Test func aMixerWhoseChildrenDidNotReadHasNoEnumeration() {
        let f = Self.fixture()
        let ax = Self.runtime(f, failing: f.mixer).ax
        #expect(AXLogicProElements.stripEnumeration(in: f.mixer, runtime: ax) == nil)
        #expect(AXLogicProElements.mixerChannelStrips(in: f.mixer, runtime: ax) == nil)
        #expect(AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: f.mixer, runtime: ax) == nil)
    }

    @Test func aStripWhoseChildrenDidNotReadHasNoInsertSlots() {
        let f = Self.fixture()
        let ax = Self.runtime(f, failing: f.strips[0]).ax
        #expect(AXLogicProElements.audioPluginInsertSlots(in: f.strips[0], runtime: ax) == nil)
        #expect(AXLogicProElements.audioPluginInsertSlots(in: f.strips[1], runtime: ax)?.count == 1,
                "the strip that read is still enumerated")
    }

    /// -25205 and -25212 are answers that the element has no children, not failures.
    @Test(arguments: [AXError.attributeUnsupported, AXError.noValue])
    func aDefinitiveAbsenceIsAnEmptyList(_ status: AXError) throws {
        let f = Self.fixture()
        let mixerRuntime = Self.runtime(f, failing: f.mixer, status: status).ax
        let enumeration = try #require(AXLogicProElements.stripEnumeration(in: f.mixer, runtime: mixerRuntime))
        #expect(enumeration.strips.isEmpty)
        #expect(enumeration.unreadableChildren == 0)
        let stripRuntime = Self.runtime(f, failing: f.strips[0], status: status).ax
        let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: f.strips[0], runtime: stripRuntime))
        #expect(slots.isEmpty)
    }

    // MARK: - Readers report unknown

    @Test func mixerStateDoesNotReportAnUnreadMixerAsEmpty() throws {
        let f = Self.fixture()
        let whole = AccessibilityChannel.defaultGetMixerState(runtime: Self.runtime(f))
        #expect(whole.isSuccess, "control: the fixture reads as a Mixer")

        let result = AccessibilityChannel.defaultGetMixerState(runtime: Self.runtime(f, failing: f.mixer))
        #expect(!result.isSuccess)
        #expect(result.message == AccessibilityChannel.mixerChildrenUnreadMessage)
    }

    @Test func channelStripDoesNotReportAnUnreadMixerAsOutOfRange() {
        let f = Self.fixture()
        let whole = AccessibilityChannel.defaultGetChannelStrip(params: ["index": "1"], runtime: Self.runtime(f))
        #expect(whole.isSuccess, "control: strip 1 exists")

        let result = AccessibilityChannel.defaultGetChannelStrip(
            params: ["index": "1"], runtime: Self.runtime(f, failing: f.mixer))
        #expect(!result.isSuccess)
        #expect(result.message == AccessibilityChannel.mixerChildrenUnreadMessage)
    }

    static func object(_ result: ChannelResult) throws -> [String: Any] {
        try #require(result.isSuccess, "\(result.message)")
        return try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
    }

    static func strips(_ result: ChannelResult) throws -> [[String: Any]] {
        try #require(result.isSuccess, "\(result.message)")
        let strips = try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [[String: Any]])
        try #require(strips.count == 2)
        return strips
    }

    /// A Mixer that reads, with one strip that does not. Both readers used to publish that strip's
    /// chain as `plugins: []` with `plugins_source: "ax"`, which the model defines as a chain that
    /// was inspected and is empty.
    @Test func mixerReadersDoNotCertifyAnUnreadStripsChainAsEmpty() throws {
        let f = Self.fixture()
        let whole = try Self.strips(AccessibilityChannel.defaultGetMixerState(runtime: Self.runtime(f)))
        #expect(whole[0]["plugins_source"] as? String == "ax", "control: the chain reads")
        let wholePlugins = try #require(whole[0]["plugins"] as? [[String: Any]])
        #expect(wholePlugins.map { $0["name"] as? String } == ["Compressor"])

        let unread = Self.runtime(f, failing: f.strips[0])
        let state = try Self.strips(AccessibilityChannel.defaultGetMixerState(runtime: unread))
        #expect(state[0]["plugins_source"] == nil)
        #expect(state[0]["plugins_read_error"] as? String == AccessibilityChannel.stripChildrenUnreadMessage)
        #expect(state[1]["plugins_source"] as? String == "ax", "the strip that read keeps its provenance")
        #expect(state[1]["plugins_read_error"] == nil)

        let strip = try Self.object(AccessibilityChannel.defaultGetChannelStrip(params: ["index": "0"], runtime: unread))
        #expect(strip["plugins_source"] == nil)
        #expect(strip["plugins_read_error"] as? String == AccessibilityChannel.stripChildrenUnreadMessage)
    }

    /// The insert snapshot the verified insert diffs against. A strip whose children did not read
    /// used to snapshot as a strip hosting nothing.
    @Test func fullStripInventoryDoesNotSnapshotAnUnreadStripAsEmpty() {
        let f = Self.fixture()
        let whole = AccessibilityChannel.fullStripInventory(track: 0, runtime: Self.runtime(f))
        #expect(whole?.count == 1, "control: one occupied insert")

        #expect(AccessibilityChannel.fullStripInventory(track: 0, runtime: Self.runtime(f, failing: f.strips[0])) == nil)
        #expect(AccessibilityChannel.fullStripInventory(track: 0, runtime: Self.runtime(f, failing: f.mixer)) == nil)
    }

    // MARK: - insert_plugin refuses for the reason

    static func insertPlugin(_ runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        await AccessibilityChannel.defaultInsertPlugin(
            params: ["track": "0", "slot": "0", "plugin_name": "Gain"],
            runtime: runtime,
            selectPlugin: { _, _, _, _ in
                Issue.record("an unread mixer or strip must be refused before any menu selection")
                return .rootMenuNotFound
            })
    }

    /// Slot 0 of strip 0 is occupied, so a run that reads everything stops at `slot_occupied`
    /// without writing. Before #982 an unread Mixer reached the ordinal check as a Mixer with
    /// `visible_strips: 0`, and an unread strip reached the slot check as a strip whose insert
    /// section is not enumerable.
    @Test func insertPluginRefusesAnUnreadMixerOrStripForThatReason() async {
        let control = Self.fixture()
        let whole = await Self.insertPlugin(Self.runtime(control))
        #expect(whole.message.contains("slot_occupied"), "control: the fixture reaches the slot")

        let mixerFixture = Self.fixture()
        let mixer = await Self.insertPlugin(Self.runtime(mixerFixture, failing: mixerFixture.mixer))
        #expect(!mixer.isSuccess)
        #expect(mixer.message.contains("\"mixer_children_unread\":true"))
        #expect(!mixer.message.contains("visible_strips"))
        #expect(mixerFixture.builder.actionCalls.isEmpty)

        let stripFixture = Self.fixture()
        let strip = await Self.insertPlugin(Self.runtime(stripFixture, failing: stripFixture.strips[0]))
        #expect(!strip.isSuccess)
        #expect(strip.message.contains("\"strip_children_unread\":true"))
        #expect(!strip.message.contains("visible_slots"))
        #expect(stripFixture.builder.actionCalls.isEmpty)
    }
}
