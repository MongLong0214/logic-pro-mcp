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
        // #1029: Apple's U.S. preset binds no key to these three functions, so
        // CGEventChannel no longer posts the keys it used to guess (Delete, I,
        // Option-Command-I); their chains are [.midiKeyCommands, .cgEvent].
        "edit.delete",                    // logic_edit.delete
        "view.toggle_inspector",          // logic_navigate.toggle_view view=inspector
        "view.toggle_step_editor",        // logic_navigate.toggle_view view=step_editor
        "edit.duplicate",                 // logic_edit.duplicate
        "edit.normalize",                 // logic_edit.normalize
        "nav.goto_marker",                // logic_navigate.goto_marker (with index)
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

    @Test("MIDIKeyCommandsChannel health detail exactly enumerates keycmd-only ops")
    func healthDetailExactlyMatchesKeycmdOnlyOps() throws {
        let detail = MIDIKeyCommandsChannel.manualValidationDetailSuffix
        let effectivePrefix = "Effectively keycmd-only (no working non-keycmd fallback on Logic 12.2): "
        let effectiveSection = try #require(
            detail.components(separatedBy: effectivePrefix).dropFirst().first?
                .components(separatedBy: ". Other preset ops").first
        )
        let orphanPrefix = "Orphans (in mappingTable + routingTable but no MCP tool exposes a call path): "
        let orphanSection = try #require(
            detail.components(separatedBy: orphanPrefix).dropFirst().first?
                .components(separatedBy: ". Tracked in NG6 follow-up.").first
        )
        let declared = Set(
            (effectiveSection + "," + orphanSection)
                .split(separator: ",")
                .map { entry in
                    entry.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: " ").first ?? ""
                }
        )
        #expect(
            declared == Self.expectedKeycmdOnlyOps,
            "health detail's declared keycmd-only set must exactly match expectedKeycmdOnlyOps — declared: \(declared.sorted()), expected: \(Self.expectedKeycmdOnlyOps.sorted())"
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

    /// #1029 review round 1 (R-01): a pause rung must pause. Logic's Pause key (keypad Period)
    /// freezes the playhead with Play on. The Accessibility channel has no pause control and used
    /// to press Stop, and Logic ignores MMC pause (#138), so neither may follow a refused CGEvent.
    @Test("transport.pause routes to CGEvent alone")
    func pauseRoutesOnlyThroughTheCGEventPauseKey() throws {
        // Mutation killed: `.accessibility` or `.coreMIDI` put back in the pause route.
        let chain = try #require(ChannelRouter.routingTable["transport.pause"])
        #expect(chain == [.cgEvent], "transport.pause chain \(chain) may hold only the channel that posts Pause")
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

    @Test("transport stop prefers CGEvent before AX while already running")
    func stopLikeCommandsPreferCGEventBeforeAX() throws {
        let chain = try #require(ChannelRouter.routingTable["transport.stop"])
        let cgIndex = try #require(chain.firstIndex(of: .cgEvent))
        let axIndex = try #require(chain.firstIndex(of: .accessibility))
        #expect(cgIndex < axIndex, "transport.stop chain \(chain) must use CGEvent before AX once the dispatcher has confirmed transport is running")
    }

    @Test("transport.toggle_autopunch is AX-only and has no set_autopunch sibling")
    func autopunchRoutesOnlyThroughAXToggle() throws {
        #expect(try #require(ChannelRouter.routingTable["transport.toggle_autopunch"]) == [.accessibility])
        #expect(ChannelRouter.routingTable["transport.set_autopunch"] == nil)
    }
}
