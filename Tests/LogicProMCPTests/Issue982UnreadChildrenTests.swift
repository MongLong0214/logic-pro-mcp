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
    /// How the Mixer is found. Logic 12.2 and 12.3 give it no identifier, so `getMixerArea` finds
    /// it as a Mixer-named container with strip children (#234). Older builds carry
    /// `AXIdentifier="Mixer"`.
    enum Layout: String, CaseIterable, CustomStringConvertible {
        /// window > AXGroup(id Mixer) > strips
        case identified
        /// window > AXGroup(desc Mixer) > AXLayoutArea(desc Mixer) > strips
        case logic122
        /// window > AXGroup(desc Mixer) > [toolbar AXGroup(desc Mixer), AXGroup > AXLayoutArea(desc Mixer) > strips]
        case logic123

        var description: String { rawValue }
    }

    struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let app: AXUIElement
        let window: AXUIElement
        /// The element whose children are the strips.
        let mixer: AXUIElement
        /// Every element from the outermost Mixer-named container down to `mixer`. A failed
        /// children read at any of them hides the strips.
        let mixerPath: [AXUIElement]
        let strips: [AXUIElement]
        /// 12.3's Mixer toolbar, a Mixer-named sibling of the strips' branch.
        let toolbar: AXUIElement?
        /// The Inspector's own two-strip Mixer. It always reads, and it must never be taken for
        /// the Mixer.
        let inspectorMixer: AXUIElement
    }

    /// Two strips. The first hosts one occupied insert and an empty slot, the second one empty
    /// slot. The window also holds the Inspector with its two-strip Mixer, as Logic's does; with
    /// `mixerShowing: false` it holds only the Inspector.
    static func fixture(_ layout: Layout = .identified, mixerShowing: Bool = true) -> Fixture {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(9820)
        let window = b.element(9821)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)

        let first = b.element(9830)
        let second = b.element(9831)
        for strip in [first, second] {
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        }
        b.setChildren(first, [occupiedSlot(b, 9840, name: "Compressor"), emptySlot(b, 9841)])
        b.setChildren(second, [emptySlot(b, 9842)])

        let mixer = b.element(9822)
        b.setChildren(mixer, [first, second])
        var mixerPath: [AXUIElement] = [mixer]
        var toolbar: AXUIElement?
        if layout == .identified {
            b.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
        } else {
            b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
            b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
            let outer = b.element(9823)
            b.setAttribute(outer, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(outer, kAXDescriptionAttribute as String, "Mixer")
            if layout == .logic122 {
                b.setChildren(outer, [mixer])
                mixerPath = [outer, mixer]
            } else {
                let bar = b.element(9824)
                let barButton = b.element(9825)
                b.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
                b.setAttribute(bar, kAXDescriptionAttribute as String, "Mixer")
                b.setAttribute(barButton, kAXRoleAttribute as String, kAXButtonRole as String)
                b.setChildren(bar, [barButton])
                let content = b.element(9826)
                b.setAttribute(content, kAXRoleAttribute as String, kAXGroupRole as String)
                b.setChildren(content, [mixer])
                b.setChildren(outer, [bar, content])
                mixerPath = [outer, content, mixer]
                toolbar = bar
            }
        }

        let inspector = b.element(9850)
        let inspectorWrapper = b.element(9851)
        let inspectorMixer = b.element(9852)
        b.setAttribute(inspector, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(inspector, kAXDescriptionAttribute as String, "Inspector")
        b.setAttribute(inspectorWrapper, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(inspectorWrapper, kAXDescriptionAttribute as String, "Mixer")
        b.setAttribute(inspectorMixer, kAXRoleAttribute as String, "AXLayoutArea")
        b.setAttribute(inspectorMixer, kAXDescriptionAttribute as String, "Mixer")
        let inspectorStrips = [b.element(9853), b.element(9854)]
        for strip in inspectorStrips {
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        }
        b.setChildren(inspectorMixer, inspectorStrips)
        b.setChildren(inspectorWrapper, [inspectorMixer])
        b.setChildren(inspector, [inspectorWrapper])

        b.setChildren(window, mixerShowing ? [inspector, mixerPath[0]] : [inspector])
        return Fixture(builder: b, app: app, window: window, mixer: mixer, mixerPath: mixerPath,
                       strips: [first, second], toolbar: toolbar, inspectorMixer: inspectorMixer)
    }

    /// One case per element whose failed children read hides the strips, in every layout.
    struct UnreadMixer: CustomStringConvertible, Sendable {
        let layout: Layout
        let depth: Int
        var description: String { "\(layout) depth \(depth)" }

        static let all: [UnreadMixer] = Layout.allCases.flatMap { layout in
            Issue982UnreadChildrenTests.fixture(layout).mixerPath.indices.map { UnreadMixer(layout: layout, depth: $0) }
        }

        func fixture() -> (Fixture, failing: AXUIElement) {
            let f = Issue982UnreadChildrenTests.fixture(layout)
            return (f, f.mixerPath[depth])
        }
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

    /// In 12.2 and 12.3 an unread Mixer used to be "Cannot locate mixer": the lookup found the
    /// Mixer by reading its strips and dropped it when they did not read.
    @Test(arguments: UnreadMixer.all)
    func mixerStateDoesNotReportAnUnreadMixerAsEmpty(_ unread: UnreadMixer) throws {
        let (f, failing) = unread.fixture()
        let whole = try Self.strips(AccessibilityChannel.defaultGetMixerState(runtime: Self.runtime(f)))
        #expect(whole[0]["plugins_source"] as? String == "ax", "control: the fixture reads as this Mixer")

        let result = AccessibilityChannel.defaultGetMixerState(runtime: Self.runtime(f, failing: failing))
        #expect(!result.isSuccess)
        #expect(result.message == AccessibilityChannel.mixerChildrenUnreadMessage)
    }

    @Test(arguments: UnreadMixer.all)
    func channelStripDoesNotReportAnUnreadMixerAsOutOfRange(_ unread: UnreadMixer) {
        let (f, failing) = unread.fixture()
        let whole = AccessibilityChannel.defaultGetChannelStrip(params: ["index": "1"], runtime: Self.runtime(f))
        #expect(whole.isSuccess, "control: strip 1 exists")

        let result = AccessibilityChannel.defaultGetChannelStrip(
            params: ["index": "1"], runtime: Self.runtime(f, failing: failing))
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
    @Test(arguments: Layout.allCases)
    func fullStripInventoryDoesNotSnapshotAnUnreadStripAsEmpty(_ layout: Layout) {
        let f = Self.fixture(layout)
        let whole = AccessibilityChannel.fullStripInventory(track: 0, runtime: Self.runtime(f))
        #expect(whole?.count == 1, "control: one occupied insert")

        #expect(AccessibilityChannel.fullStripInventory(track: 0, runtime: Self.runtime(f, failing: f.strips[0])) == nil)
        for failing in f.mixerPath {
            #expect(AccessibilityChannel.fullStripInventory(track: 0, runtime: Self.runtime(f, failing: failing)) == nil)
        }
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
    @Test(arguments: UnreadMixer.all)
    func insertPluginRefusesAnUnreadMixerForThatReason(_ unread: UnreadMixer) async {
        let control = unread.fixture().0
        let whole = await Self.insertPlugin(Self.runtime(control))
        #expect(whole.message.contains("slot_occupied"), "control: the fixture reaches the slot")

        let (f, failing) = unread.fixture()
        let mixer = await Self.insertPlugin(Self.runtime(f, failing: failing))
        #expect(!mixer.isSuccess)
        #expect(mixer.message.contains("\"mixer_children_unread\":true"), "\(mixer.message)")
        #expect(!mixer.message.contains("visible_strips"))
        #expect(!mixer.message.contains("Cannot locate"))
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test func insertPluginRefusesAnUnreadStripForThatReason() async {
        let stripFixture = Self.fixture()
        let strip = await Self.insertPlugin(Self.runtime(stripFixture, failing: stripFixture.strips[0]))
        #expect(!strip.isSuccess)
        #expect(strip.message.contains("\"strip_children_unread\":true"))
        #expect(!strip.message.contains("visible_slots"))
        #expect(stripFixture.builder.actionCalls.isEmpty)
    }
}
