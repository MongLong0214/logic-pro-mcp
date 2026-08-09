import Testing
@testable import LogicProMCP

/// Programmatic audit guarding the **routingTable ⇄ CGEventChannel.keyMap ⇄
/// MIDIKeyCommandsChannel.mappingTable ⇄ keycmd-only declared list** invariant.
///
/// v3.1.6 SETUP.md §4.1 shipped an incorrect "audited coverage matrix" that
/// listed only `transport.capture_recording` as effectively-keycmd-only. The
/// v3.7.x's effective list is the seven ops below plus nine orphans. The list
/// removes `nav.set_zoom_level` because `logic_navigate.set_zoom` now has an
/// Accessibility slider path.
///
/// `expectedKeycmdOnlyOps` is the single source of truth for:
/// - SETUP.md §4.1 "Effectively-keycmd-only" enumeration
/// - `MIDIKeyCommandsChannel.manualValidationDetailSuffix` health string
///
/// The invariants below catch the four most common drift modes:
/// 1. Op declared keycmd-only but cgEvent now has a shortcut for it (lift it out).
/// 2. Op declared keycmd-only but mappingTable doesn't actually carry it
///    (the keycmd path can't fire it either — broken declaration).
/// 3. Op declared keycmd-only but routingTable doesn't list midiKeyCommands
///    in its chain (router would never reach the keycmd channel).
/// 4. Health-detail string drifts from the declared set.
@Suite("Routing audit — keycmd-only invariants")
struct RoutingAuditInvariantTests {
    /// Ops where the routing chain contains `.midiKeyCommands` and **no other
    /// channel in the chain has a working handler**, so manual MIDI Learn is
    /// the only way the op can fire on Logic 12.2.
    ///
    /// **If you add a new op to `routingTable` whose only working path is
    /// keycmd, also add it here and to the SETUP.md §4.1 matrix + the health
    /// detail suffix. Conversely, if you wire up a working non-keycmd path
    /// for one of these ops (e.g. add a `CGEventChannel.keyMap` shortcut or
    /// an AccessibilityChannel handler), remove it from this set.**
    static let expectedKeycmdOnlyOps: Set<String> = [
        // Reachable from MCP tools — manual MIDI Learn binding is the only
        // path that fires these on Logic 12.2.
        "edit.duplicate",                 // logic_edit.duplicate
        "edit.normalize",                 // logic_edit.normalize
        "nav.goto_marker",                // logic_navigate.goto_marker (with index)
        "nav.delete_marker",              // logic_navigate.delete_marker
        // Channel-only router op — no public MCP tool command exposes it, but
        // it remains a real mappingTable/routingTable path if a future surface
        // promotes it.
        "transport.capture_recording",

        // Orphans — present in mappingTable + routingTable but no MCP tool
        // currently routes to them. They stay here so the moment a future
        // tool starts routing, the docs/health-detail invariant still holds.
        "automation.set_mode",
        "note.up_semitone",
        "note.down_semitone",
        "note.up_octave",
        "note.down_octave",
        "view.toggle_smart_controls",
        "view.toggle_plugin_windows",
        "view.toggle_automation",
        "track.create_stack",
    ]

    @Test("Each declared keycmd-only op has NO CGEventChannel.keyMap shortcut")
    func keycmdOnlyOpsHaveNoCgEventShortcut() {
        let leaked = Self.expectedKeycmdOnlyOps
            .filter { CGEventChannel.keyMap[$0] != nil }
            .sorted()
        #expect(
            leaked.isEmpty,
            "Op declared keycmd-only but CGEventChannel.keyMap actually has a shortcut for it — remove it from expectedKeycmdOnlyOps and update SETUP.md §4.1: \(leaked)"
        )
    }

    @Test("Each declared keycmd-only op IS present in MIDIKeyCommandsChannel.mappingTable")
    func keycmdOnlyOpsAreInMappingTable() {
        let missing = Self.expectedKeycmdOnlyOps
            .filter { MIDIKeyCommandsChannel.mappingTable[$0] == nil }
            .sorted()
        #expect(
            missing.isEmpty,
            "Op declared keycmd-only but the keycmd channel has no mappingTable entry — there is no way to fire it: \(missing)"
        )
    }

    @Test("Each declared keycmd-only op routes via .midiKeyCommands in routingTable")
    func keycmdOnlyOpsRouteViaKeyCommands() {
        let unrouted = Self.expectedKeycmdOnlyOps
            .filter { op in
                guard let chain = ChannelRouter.routingTable[op] else { return true }
                return !chain.contains(.midiKeyCommands)
            }
            .sorted()
        #expect(
            unrouted.isEmpty,
            "Op declared keycmd-only but its routingTable chain does not include .midiKeyCommands — the router would never reach the keycmd channel: \(unrouted)"
        )
    }

    @Test("MIDIKeyCommandsChannel health detail enumerates every keycmd-only op")
    func healthDetailMentionsEveryKeycmdOnlyOp() {
        let detail = MIDIKeyCommandsChannel.manualValidationDetailSuffix
        let missing = Self.expectedKeycmdOnlyOps
            .filter { !detail.contains($0) }
            .sorted()
        #expect(
            missing.isEmpty,
            "expectedKeycmdOnlyOps has ops the health detail does not mention — SETUP.md §4.1 and the runtime health string would disagree: \(missing)"
        )
    }

    @Test("Every mappingTable op has a routingTable entry")
    func mappingTableOpsAreAllRouted() {
        let mappingOps = Set(MIDIKeyCommandsChannel.mappingTable.keys)
        let routedOps = Set(ChannelRouter.routingTable.keys)
        let unrouted = mappingOps.subtracting(routedOps).sorted()
        #expect(
            unrouted.isEmpty,
            "MIDIKeyCommandsChannel mappingTable ops missing from ChannelRouter.routingTable: \(unrouted)"
        )
    }

    @Test("Health detail stays under the 1 KB UTF-8 budget the code comment promises")
    func healthDetailFitsUnderOneKilobyte() {
        let detail = MIDIKeyCommandsChannel.manualValidationDetailSuffix
        let bytes = detail.utf8.count
        #expect(bytes < 1024, "manualValidationDetailSuffix is \(bytes) UTF-8 bytes; the surrounding comment claims < 1 KB.")
    }

    /// #138 regression: Logic 12.x silently ignores MMC "pause", so a verified
    /// transport.pause that routed CoreMIDI first always failed closed. The
    /// pause chain must prefer a channel that actually halts the playhead
    /// (AX Stop button / spacebar) BEFORE the no-op MMC fallback.
    @Test("transport.pause routes a working stop channel before MMC")
    func pausePrefersWorkingChannelOverMMC() throws {
        let chain = try #require(ChannelRouter.routingTable["transport.pause"])
        let mmcIndex = try #require(chain.firstIndex(of: .coreMIDI))
        let axIndex = chain.firstIndex(of: .accessibility)
        let cgIndex = chain.firstIndex(of: .cgEvent)
        let firstWorking = [axIndex, cgIndex].compactMap { $0 }.min()
        let working = try #require(firstWorking)
        #expect(working < mmcIndex,
                "transport.pause chain \(chain) must try AX/cgEvent before MMC; MMC pause is ignored by Logic 12.x")
    }

    @Test("transport play prefers AppleScript before send-only fallbacks")
    func playPrefersAppleScriptBeforeSendOnlyFallbacks() throws {
        let chain = try #require(ChannelRouter.routingTable["transport.play"])
        let appleScriptIndex = try #require(chain.firstIndex(of: .appleScript))
        for channel in [ChannelID.coreMIDI, .cgEvent] {
            let sendOnlyIndex = try #require(chain.firstIndex(of: channel))
            #expect(appleScriptIndex < sendOnlyIndex,
                    "transport.play chain \(chain) must try AppleScript before send-only \(channel)")
        }
    }

    @Test("transport stop and pause prefer CGEvent before AX while already running")
    func stopLikeCommandsPreferCGEventBeforeAX() throws {
        for operation in ["transport.stop", "transport.pause"] {
            let chain = try #require(ChannelRouter.routingTable[operation])
            let cgIndex = try #require(chain.firstIndex(of: .cgEvent))
            let axIndex = try #require(chain.firstIndex(of: .accessibility))
            #expect(cgIndex < axIndex, "\(operation) chain \(chain) must use CGEvent before AX once the dispatcher has confirmed transport is running")
        }
    }

    @Test("transport.toggle_autopunch is AX-only and has no set_autopunch sibling")
    func autopunchRoutesOnlyThroughAXToggle() throws {
        #expect(try #require(ChannelRouter.routingTable["transport.toggle_autopunch"]) == [.accessibility])
        #expect(ChannelRouter.routingTable["transport.set_autopunch"] == nil)
    }
}
