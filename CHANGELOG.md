# Changelog

All notable changes to Logic Pro MCP Server are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project uses [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

## [2.3.0] — 2026-04-18

### Added

- **`logic_tracks.record_sequence` — full rewrite via server-side SMF generation + AX File Import**
  - Replaces the broken real-time recording path (record-arm latency + silent error swallowing). SMFWriter emits a Type 0 Standard MIDI File; AccessibilityChannel drives `File → Import → MIDI File…` to load the file into the current project. Note timing is now byte-exact with zero drift regardless of system load.
  - **Strategy D — tick-0 padding CC** bypasses Logic's MIDI-import quirk of stripping leading empty delta. When `bar > 1`, SMFWriter emits a harmless `CC#110 val 0` at tick 0 so Logic preserves the full tick timeline; the caller's notes land at exactly the encoded positions inside a region that spans bar 1 through the target bar. Verified live on Logic Pro 12: `bar=50` request produces a region explicitly described by Logic as "1 마디에서 시작하여 51 마디에서 끝납니다".
  - Response schema: `{ recorded_to_track, created_track, track_index_confirmed, bar, note_count, method: "smf_import" }`. `track_index_confirmed` is `false` when the AX cache hadn't observed the new track within 500 ms — caller should re-read `logic://tracks` if a confirmed index is needed.
  - Hard upper limit lifted from 256 → 1024 notes (bounded by SMFWriter). Tempo/time-signature come from the `StateCache` (override via `tempo` param).
- **`logic_tracks.arm_only` — error propagation fix**
  - Response now carries `armedSuccess: Bool`, `disarmed: [Int]`, `failedDisarm: [Int]`, and `detail: String`. `armed` kept as the int target index for backward compatibility. Closes H-4 finding.
- **`logic_navigate.goto_bar` — real channel**
  - Delegates to `transport.goto_position` (AX bar-slider); the dead `nav.goto_bar` route (`[.mcu, .cgEvent]` with no handler) is removed.
- **`logic_navigate.goto_marker { name: ... }` — now works**
  - `StatePoller` calls a new `AccessibilityChannel.nav.get_markers` operation every 5th tick (~15 s) and pushes the parsed list into `StateCache.updateMarkers`. Name-based lookup now has a populated cache to consult.
- **`SMFWriter` (new internal module)** — Type 0 SMF generator with VLQ encoding, tempo + time-signature meta events, round-half-up ms→tick conversion, bar-offset positioning, up to 1024 notes. No public MCP surface — internal helper for `record_sequence`.
- **`SMFWriter.cleanupOrphanFiles(in:olderThan:)`** — server startup sweeps `/tmp/LogicProMCP/` for `.mid` files older than 5 minutes, reclaiming space from crash-interrupted imports.
- **New operations in the routing table**: `midi.import_file` (AX), `region.move_to_playhead` (AX), `region.select_last` (AX). `midi.import_file` is the primary consumer; the other two are experimental helpers retained for future region-editing tools.

### Changed

- `StatePoller` marker polling now runs every 5th transport tick rather than every cycle. Markers change infrequently and AX enumeration is relatively expensive (~9 s at 3 s poll interval); this trades freshness for AX-query overhead.
- Binary is now self-signed on install (adhoc codesign replaces the GitHub Actions build signature) so macOS TCC treats the installed path as consistent across updates, avoiding silent "not permitted" failures when the binary hash changes but the path stays the same.

### Fixed

- `get_regions` used to return `[]` with `_debug.layoutItems: 0` when regions existed under certain AX tree shapes. Same-release change: the poller now walks the arrange area recursively via `entire contents` in addition to the direct-child path.
- `record_sequence` no longer silently swallows mid-step failures. Every step (`select` → `arm_only` → `SMFWriter.generate` → file write → `midi.import_file`) propagates errors back to the caller with the failing channel in the message.

### Removed

- The real-time CoreMIDI recording path previously used by `record_sequence` (goto → record → sleep → play_sequence → stop) is gone. `midi.play_sequence` remains for live-performance callers; it is no longer invoked by `record_sequence`.
- `nav.goto_bar` entry in `ChannelRouter.v2RoutingTable` (no channel implemented it; clients now hit `transport.goto_position` via `NavigateDispatcher`).

### Documentation

- `docs/prd/PRD-record-sequence-smf-import.md` (v0.4) — full PRD with 3 Phase-2 review rounds, 2 Phase-6 Ralph iterations, and live OQ-1/OQ-2/OQ-3 probe results embedded.
- `docs/tickets/record-sequence-smf-import/` — 7 dev tickets (T1-T7) with TDD specs.
- `docs/tickets/navigate-redesign/STATUS.md` — marked Done with T1/T2/T3 evidence.
- `docs/tickets/installer-supply-chain/` — resolution: pinned SHA256 hash in `Scripts/install.sh` (implemented in 2.3.0). See §Security below.

### Security

- `Scripts/install.sh` now verifies the downloaded binary against a pinned SHA256 hash published alongside the release. Install aborts on mismatch. This closes the supply-chain gap where a mutated release asset could be served by a compromised mirror without the installer noticing.
- `AccessibilityChannel.midi.import_file` uses the same `AppleScriptSafety.openFile` (NSWorkspace) injection-safe path as `project.open` — no shell interpolation reaches the file dialog.

### Testing

- +2 SMFWriter tests (`testSMFWriterEmitsPaddingCCWhenBarOffsetIsNonZero`, `testSMFWriterNoPaddingWhenBarIsOne`)
- +2 SMFWriter orphan-cleanup tests
- +5 TrackDispatcher tests (`arm_only` partial-failure visibility + `record_sequence` SMF-import happy path + error chain + invalid notes + hasDocument guard)
- +3 StatePoller marker-polling tests
- +2 NavigateDispatcher `goto_bar` delegation tests
- **Total**: 668 → 690 tests (+22). All pass.

## [2.2.0] — 2026-04-16

### Added

- `logic_project.get_regions` — read-only AX scan of the arrange area, parses Logic's AXHelp bar-position strings into `[RegionInfo]` JSON (English + Korean locales). Enables programmatic verification of `record_sequence` region placement without screenshots.
- `logic_tracks.arm_only` — composite "disarm every track, then arm exactly one", closing the multi-armed duplicate-record hole.
- `logic_tracks.record_sequence` — composite `select → arm_only → record → play → stop` for one-shot natural-language recording (⚠️ still subject to the record-arm latency bug tracked in `record_sequence sync bug` memory; use `send_chord`/`send_note` for reliable demos).
- `logic_mixer.set_plugin_param` — deterministic plugin-parameter control via Scripter on the currently-selected track.
- `logic_tracks.set_instrument`, `list_library`, `scan_library`, `resolve_path`, `scan_plugin_presets` — Library-panel enumeration + preset loading via AX.
- `StateCache.selectOnly(trackAt:)` actor mutator — preserves Logic's single-selection model when MCU select events arrive.

### Changed

- `logic://transport/state` resource now returns a wrapper object:
  `{ state: TransportState, has_document: Bool, transport_age_sec: Double }`.
  Clients can detect "no project open" / "stale snapshot" without cross-referencing `logic://system/health`. **Breaking** for clients reading top-level `tempo`, `isPlaying`, etc. — they now live under `.state`.
- `logic_project.close` now honours the documented `saving: "yes" | "no" | "ask"` parameter (previously always coerced to `"yes"`). Invalid values return an explicit error instead of silently saving.
- `StateCache.clearProjectState()` now also resets `transport` so the resource stops reporting the previous project's playback state after close.
- `MCUFeedbackParser` enforces single-track selection on every "select on" event, preventing multiple tracks from appearing selected simultaneously.
- Distribution version aligned at **2.2.0** across `ServerConfig.serverVersion` (SSOT), `Formula/logic-pro-mcp.rb`, `manifest.json`, `Scripts/install.sh`. `VersionConsistencyTests` pins this going forward.
- `Formula/logic-pro-mcp.rb` now installs helper assets (`docs/MCU-SETUP.md`, `Scripts/install-keycmds.sh` + siblings, `Scripts/LogicProMCP-Scripter.js`) into `pkgshare`; release workflow packs them into the tarball.
- `docs/API.md` + `README.md` synced with the shipped surface (record_sequence/arm_only/get_regions documented with known-limitation callouts, navigate gaps disclosed, insert/bypass_plugin marked removed, poll interval corrected to 3 s).

### Removed

- `logic_mixer.insert_plugin`, `logic_mixer.bypass_plugin` — had no channel with a working implementation; every call produced a dressed-up error. Use `set_plugin_param` on the selected track via Scripter instead. Router entries and AX stub branches pruned so there is no side-channel resurrection path.
- `plugin.insert`, `plugin.bypass`, `plugin.remove` router-table entries.
- `StateModels.PluginState` + nested `PluginParam` (unreferenced).
- `ServerConfig.channelHealthCheckTimeout` (unreferenced since initial commit).
- `AXValueExtractors.extractCheckboxState` + companion test assertions (referenced only by its own unit test; production callers use `extractButtonState`).

### Moved

- `Scripts/library-ax-probe.swift`, `plugin-detective.swift`, `plugin-menu-ax-probe.swift`, `setting-popup-probe.swift` → `Scripts/probes/`. Developer-only investigation scripts are isolated from operational install/uninstall/e2e scripts. SwiftPM target unaffected.

### Documentation

- New ticket drafts:
  - `docs/tickets/navigate-redesign/` — T1 (goto_bar real channel), T2 (marker cache population), T3 (contract alignment).
  - `docs/tickets/installer-supply-chain/` — same-release verification root mitigation options (awaiting Isaac's decision).

## [2.1.0] — 2026-04-12

### Security

Nine vulnerabilities identified and fixed during the production-readiness review.

- **P0** — AX Save-As dialog accepted unvalidated paths. `saveAsViaAXDialog` now guards with `AppleScriptSafety.isValidProjectPath` before writing into the dialog (`AccessibilityChannel.swift`).
- **P1** — `DispatchQueue.main.sync` could deadlock in a CLI process without an active AppKit runloop. `ProcessUtils.runAppKit` now probes `CFRunLoopIsWaiting(CFRunLoopGetMain())` and returns `nil` when the main runloop is unavailable, letting callers fall back to the subprocess path.
- **P1** — MIDI packet traversal used raw pointer arithmetic without bounding `wordCount`. Added `min(wordCount, 64)` bound in `ProductionMCUTransport` before indexing into the UMP packet buffer.
- **P1** — `ServerConfig.logicProProcessName` was interpolated into AppleScript without escaping. Added `\\` and `"` escaping before interpolation in `ProcessUtils.logicProPIDViaSystemEvents`.
- **P2** — Track rename accepted unbounded names. Truncated to 255 chars with JSON-escaped response.
- **P2** — Virtual MIDI port names passed newlines/null bytes to CoreMIDI. Filter newlines/nulls and truncate to 63 chars in `midi.create_virtual_port`.
- **P2** — `stepInputDurationMs`, `send_note.duration_ms`, and `send_chord.duration_ms` were unbounded. Capped at 30,000 ms to prevent actor DoS.
- **P2** — `verifyOpenedProjectScript` and `saveProjectAsScript` incomplete escaping. Added `\n` / `\r` stripping.
- **P2** — `PermissionChecker.runAutomationProbeViaShell` used nested shell quoting. Replaced with direct `/usr/bin/osascript -e` invocation.

### Added

- **Graceful shutdown** — SIGTERM and SIGINT handlers installed in `MainEntrypoint.run` via `DispatchSource` so the server exits cleanly (channels stopped, MIDI ports released) instead of being killed with resources held.
- **Configurable state polling interval** — new `ServerConfig.statePollingIntervalNs` (default 3 s; initially introduced at 5 s and tightened to 3 s in the v2.2 census sync) replaces the previously hardcoded value in `StatePoller`.
- **E2E test suite** — `EndToEndTests.swift` (93 tests) covering tool → dispatcher → router → channel chains, resource reads, lifecycle, concurrency, and input validation.
- **Production readiness tests** — `ProductionReadinessTests.swift` (26 tests) verifying all security fixes, duration caps, path validation, port name sanitization.
- **Live E2E test runner** — `scripts/live-e2e-test.py` drives the actual binary against a running Logic Pro instance (229 tests across 20 sections).
- **Comprehensive documentation** — new `docs/ARCHITECTURE.md`, `docs/API.md`, `docs/MCU-SETUP.md`, `docs/TROUBLESHOOTING.md`.
- **Launch agent template** — `scripts/com.logicpro.mcp.plist.template` for operators who need the MCP server available outside Claude Code sessions.

### Changed

- **`StatePoller.stop()` is now `async`** and awaits in-flight poll cycles before returning, avoiding races where the cancelled poll loop could still touch the cache after `stop()` returned.
- **`ProcessUtils.runAppKit<T>` returns `T?`** instead of `T`. Callers must unwrap or fall back. This is a breaking change at the Swift API level but internal-only.
- **`StatePoller` decoder** now uses `dateDecodingStrategy = .iso8601` to match the encoder, fixing a silent decode failure on `lastUpdated` that caused project/transport polls to be dropped.

### Removed

Dead code cleanup — ~43 lines of production code and ~40 lines of duplicated test helpers.

- `MCUChannel.executePluginParam` (orphaned method, routing sends `mixer.set_plugin_param` to Scripter).
- `ProcessUtils.logicProRunningViaAppleScript` (private, never called).
- `AppleScriptSafety.shouldUseNSWorkspaceForOpen` (dead marker constant).
- `MIDIEngine.sendPolyAftertouch` (production never sent polyphonic aftertouch).
- `MCUProtocol.isDeviceResponse` (test-only wrapper over `parseDeviceResponse`).
- 11 operations in `MIDIKeyCommandsChannel.mappingTable` that had no entry in `ChannelRouter.v2RoutingTable` (`automation.off/read/touch/latch`, `edit.force_legato`, `edit.remove_overlaps`, `edit.trim_at_playhead`, `project.export_midi`, `transport.toggle_click`, `view.toggle_list_editors`, `view.toggle_score`).

### Tests

- Total: **500 Swift tests** + **229 live E2E tests** passing.
- New consolidated `SharedTestHelpers.swift` eliminates duplicate `toolText`, `resourceText`, and `ServerStartRecorder` helpers across 5 test files.

---

## [2.0.0] — 2026-04-06

Initial production release of the v2 architecture:

- 7 communication channels (MCU, MIDIKeyCommands, Scripter, CoreMIDI, Accessibility, CGEvent, AppleScript).
- 8 MCP tool dispatchers.
- 6 resources + 1 template.
- 90+ routed operations with fallback chains.
- Manual-validation approval gate for MIDIKeyCommands and Scripter channels.
- Signed and notarized macOS binary via GitHub Actions release workflow.

---

## [0.1.0] — 2025-12-xx

Initial prototype.
