import Testing
@testable import LogicProMCP

/// `kCGWindowOwnerName` for Logic Pro is locale-dependent.
///
/// Measured on macOS 15 with Logic Pro 12.3 on 2026-08-17, in both directions, by switching
/// `defaults write com.apple.logic10 AppleLanguages` and restarting:
///
///     English   "Logic Pro"      U+0020
///     Japanese  "Logic Pro"      U+0020
///     Korean    "Logic\u{00A0}Pro"   NO-BREAK SPACE
///
/// `manifest.json` declares `"process_name": "Logic Pro"` with an ordinary space, so an exact
/// compare found ZERO Logic windows on a Korean-UI Mac. The harness hit the identical bug first —
/// every capture in a Korean run recorded `window: null` while Logic was plainly on screen.
@Suite("#567 the window-owner name survives a localized separator")
struct Issue567LocalizedOwnerNameTests {
    /// The exact string CoreGraphics returned under a Korean UI.
    private static let koreanOwnerName = "Logic\u{00A0}Pro"

    @Test("the measured Korean owner name is recognised")
    func koreanOwnerNameMatches() {
        #expect(LogicProTarget.isLogicProcessName(Self.koreanOwnerName))
        // The premise: it is genuinely a different string, so this is not a tautology.
        #expect(Self.koreanOwnerName != "Logic Pro")
    }

    @Test("the ordinary-space name keeps matching")
    func englishOwnerNameStillMatches() {
        #expect(LogicProTarget.isLogicProcessName("Logic Pro"))
        #expect(LogicProTarget.isLogicProcessName("Logic Pro Creator Studio"))
    }

    /// Any separator macOS localises to has to work, but a name with the separator REMOVED is a
    /// different application name and must stay unmatched — otherwise the fix would be "ignore
    /// spacing", which is a wider claim than the measurement supports.
    @Test("other whitespace separators match, a removed separator does not")
    func separatorHandlingIsNarrow() {
        #expect(LogicProTarget.isLogicProcessName("Logic\u{202F}Pro"))
        #expect(!LogicProTarget.isLogicProcessName("LogicPro"))
        #expect(!LogicProTarget.isLogicProcessName("Logic Pro X"))
        #expect(!LogicProTarget.isLogicProcessName("Not Logic Pro"))
    }

    @Test("the window-list resolver finds Logic under a Korean owner name")
    func windowListResolverAcceptsTheKoreanName() throws {
        // The one caller, exercised end to end: without the normalisation this returns nil and the
        // visible-window PID route contributes nothing on a Korean Mac.
        let pid = ProcessUtils.logicProPID(fromWindowList: [[
            "kCGWindowOwnerName": Self.koreanOwnerName,
            "kCGWindowOwnerPID": 4242,
            "kCGWindowBounds": ["Width": 1920, "Height": 1050],
        ]])
        #expect(try #require(pid) == 4242)
    }
}

/// #575: three table entries named a channel that does not implement them.
///
/// `mixer.set_output_volume` routed to `.mcu`, `mixer.get_bus_routing` and
/// `automation.get_parameter` to `.accessibility`. Neither channel has a case for any of them, so
/// each falls to its `default` arm — `Unknown MCU operation` / `Unsupported AX operation` — and a
/// caller who found one would have reached an exhausted chain.
///
/// That is a stronger case for removal than the two system entries retired earlier, which at least
/// named a channel that would have answered. Verified live before removal: every one answers
/// `invalid_params` under each plausible tool spelling.
@Suite("#575 the table names no operation its channels refuse")
struct Issue575RetiredUnimplementedRoutesTests {
    @Test("the three unimplemented entries are gone")
    func retiredEntriesAreAbsent() {
        for operation in [
            "mixer.set_output_volume",
            "mixer.get_bus_routing",
            "automation.get_parameter",
        ] {
            #expect(ChannelRouter.v2RoutingTable[operation] == nil)
        }
    }

    /// The neighbours that share their prefixes must be untouched — the removal was of three named
    /// entries, not of a family.
    @Test("their neighbours still route")
    func neighboursSurvive() throws {
        for operation in [
            "mixer.set_master_volume",
            "mixer.set_send",
            "mixer.get_state",
            "automation.set_mode",
            "automation.get_mode",
        ] {
            let chain = try #require(ChannelRouter.v2RoutingTable[operation])
            #expect(!chain.isEmpty)
        }
    }
}
