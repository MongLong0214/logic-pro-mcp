# Changelog

All notable changes to Logic Pro MCP Server are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project uses [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

## [3.0.1] — 2026-04-20

Release-path and docs-honesty hotfix on top of v3.0.0. **No runtime behavior changes** — same 8 tools, 9 resources, 3 templates. Upgrade is a docs + CI + packaging refresh.

### Fixed

- **Architecture claims match reality.** Locally-built ADHOC releases are `arm64`-native (produced by `swift build -c release` without Xcode); Intel Macs run the binary under Rosetta 2. The v3.0.0 release asset named `…-universal.tar.gz` was bit-identical to `…-arm64.tar.gz` — technically arm64 masquerading as universal. v3.0.1 keeps both tarball names for Homebrew-tap backward compatibility but `manifest.json`, `README.md`, `docs/SETUP.md`, `docs/MAINTAINERS.md`, and `Formula/logic-pro-mcp.rb` now all state `arm64` native + Intel via Rosetta. CI with full Xcode still produces a genuine fat binary.
- **`release.yml` is dual-mode (notarized + ADHOC).** Previously the workflow hard-required `MACOS_CERT_BASE64` and 6 other Apple-Developer secrets, so every tag push failed visibly (red X on every release since v2.3.0). v3.0.1 detects secret presence at runtime: notarized path when present, ADHOC (`codesign --sign -`) when absent. Both paths publish `RELEASE-METADATA.json` with correct `signing` field (`notarized`|`adhoc`). CI `validate-install` matrix now runs end-to-end on every release.
- **README test-count unified.** Badge, body paragraph, and release notes now consistently cite **760 passing** (was drifting between 700 badge / 759 body / 760 notes).
- **Migration guidance expanded.** CHANGELOG §Migration now includes before/after examples for `set_instrument` (empty-call rejection) and `goto_position` (`time` alias removed).

### Added

- `Scripts/release.sh` — one-command ADHOC release that (1) builds + adhoc-codesigns the binary, (2) computes SHAs, (3) patches `Formula/logic-pro-mcp.rb` + commits Formula sync, (4) creates tag, (5) creates GitHub release with artifacts — in the right order. Prevents the v3.0.0 issue where the Formula SHA commit landed on `main` *after* the tag, leaving the tag with a stale sha256.
- `docs/MAINTAINERS.md` now documents both release modes, the `Scripts/release.sh` wrapper, and the post-tag Homebrew SHA-sync step more clearly.

### Security

- No security changes in v3.0.1. The round-4/5 hardening (fail-closed installer, symlink validation, JSON validation, rate-limit cap, ISO 8601 alignment, Logger/JSON thread-safety) remains in place from v3.0.0.

## [3.0.0] — 2026-04-19

> Renumbered from 2.4.0 to 3.0.0 to honor SemVer — the changes below break
> the track-mutation and `record_sequence` contracts, which is a major bump.
> The v2.4.0 tag was a pre-release and should be considered yanked in favor
> of v3.0.0.

### Breaking Changes

- **All mutating `logic_tracks` commands now require explicit `index`**. Previously `index` defaulted to `0` when missing, which silently mutated track 0 on malformed caller requests. Commands affected: `select`, `delete`, `duplicate`, `rename`, `mute`, `solo`, `arm`, `arm_only`, `set_automation`, `set_instrument`. Requests missing or with non-numeric `index` now return `isError: true`.
- **`arm_only` no longer buries failures in a success payload**. If the primary arm fails, or if any disarm fails, the command returns `isError: true` with detail. The structured JSON payload (`{armed, armedSuccess, disarmed, failedDisarm, detail}`) is reserved for complete success.
- **`record_sequence` no longer returns `track_index_confirmed`**. The dispatcher now polls the AX cache for up to 2 seconds and returns `isError: true` if the new track never appears — the fallback value (`false` + last-known-index) was a silent correctness hazard. On success, `created_track` is always the real new track index.
- **`record_sequence` hard-fails when `transport.goto_position bar=1` fails**. Logic Pro anchors imported regions at the playhead; a failed pre-reset would silently place notes at the wrong bar. The step is now a blocking precondition.
- **`set_instrument` requires `path` OR both `category` + `preset`**. Empty calls (only `index`) are rejected instead of silently dispatching with no instrument target.
- **`goto_position` canonicalises the position key**. Only `{ bar }` or `{ position }` are accepted — the undocumented `time` alias was removed so the API contract, tool description, and runtime now all agree on a single key. Both `B.B.S.S` and `HH:MM:SS:FF` formats remain supported.
- **`logic_system.health.logic_pro_running` now uses the same source of truth as `logic_project.is_running`**. Previously `health` OR-ed an AppleScript availability flag into the bit, which could disagree with `is_running`'s PID-based check. AppleScript status remains surfaced separately in the `channels` array.

### Added

- **`select` now fail-closes on malformed `index`**. A request like `{"index":"abc"}` is rejected with a clear error instead of silently selecting track 0.
- **Explicit-index regression tests** for every mutating command (8 new tests in `DispatcherTests.swift`).
- **Universal + arm64 release tarballs**. The release workflow now publishes both `LogicProMCP-macOS-universal.tar.gz` and `LogicProMCP-macOS-arm64.tar.gz` (same fat binary, two names) so existing Homebrew taps and arm64-only users both resolve cleanly.
- **GitHub Actions pin to commit SHA**. `actions/checkout` and `softprops/action-gh-release` are now pinned to immutable commit hashes instead of mutable tags, closing a supply-chain gap in the release workflow.

### Fixed

- `docs/API.md` now matches runtime behavior: `arm_only` error paths, `record_sequence` success schema (no `track_index_confirmed`), `set_automation` full mode enum (incl. `trim`), `set_instrument` required-field semantics.
- `Scripts/live-e2e-test.py` updated to reflect v3.0.0 contract: rejects-without-index assertions, new `set_instrument` error messages, softer environment gates.

### Security

- Release workflow dependencies pinned to commit SHA (supply-chain hardening).
- **Release tag trigger narrowed to strict SemVer** (`v[0-9]+.[0-9]+.[0-9]+` with optional pre-release suffix). Arbitrary `v*` tags no longer unlock signing secrets in GitHub Actions.
- **Installer warns when provenance is fetched from the same release surface.** `Scripts/install.sh` now prints a hardening recommendation when `LOGIC_PRO_MCP_SHA256` / `LOGIC_PRO_MCP_TEAM_ID` aren't passed out-of-band.
- **Installer trust model documented.** `README.md` now leads with Homebrew as the hardened path and marks `bash <(curl ...)` as a convenience path that does **not** protect the installer script itself. `SECURITY.md §Installer trust model` lays out three trust tiers.
- **`logic://mcu/state` uses `JSONEncoder`** instead of a hand-rolled escaper, so MCU LCD bytes and port names carrying control characters (`\n`/`\r`/`\t`/U+0000-U+001F) now produce valid JSON instead of breaking parsers.
- **`JSONHelper` shared encoders are lock-gated** — concurrent MCP tool handlers can't race on `JSONEncoder` internal state.
- **`Logger` rate-limit map has a 1024-entry cap** with expired-window sweep + oldest-eviction, preventing a long-running daemon from inflating memory via user-controlled log strings.
- **`logic://library/inventory` resolves through three candidate paths** (`LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override → repo-relative → `~/Library/Application Support/LogicProMCP/`) and emits a `Log.warn` on miss, so daemon launches where CWD=`/` no longer silently report an empty library.

### Fixed — drift from prior review

- `docs/API.md` header now advertises **9 resources + 3 templates** (was 6 + 1).
- `docs/API.md` `select` entry now documents the actual matching semantics (`localizedCaseInsensitiveContains`, not case-sensitive-first-match).
- `logic_system.help` default section matches the new resource/template counts.
- `Scripts/live-e2e-test.py` resource-list assertions updated to the v3.0.0 surface (9 resources, 3 templates, MCU filtered when disconnected).
- `manifest.json` and `docs/{MAINTAINERS,SETUP}.md` now advertise the universal binary consistently with `Formula/logic-pro-mcp.rb` and `release.yml` (no more arm64-vs-universal drift).

### Fixed — round 5 (final hardening pass)

- **`release.yml` tag trigger is now valid glob, not regex.** Previous pattern used `[0-9]+` which GitHub Actions treats as literal `+` (not repetition), so the `v3.0.0` tag would not have triggered the workflow and the notarized/signed release path would have been unreachable. Replaced with `v[0-9]*.[0-9]*.[0-9]*` (+ pre-release variant) and added a step-level strict-SemVer regex guard that fails the workflow before any secret-using step.
- **Installer is fail-closed by default.** `Scripts/install.sh` now refuses to run unless `LOGIC_PRO_MCP_SHA256` + `LOGIC_PRO_MCP_TEAM_ID` are both supplied. Opting into the same-origin (provenance fetched from the same release as the binary) path requires an explicit `LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1`. The CI `validate-install` job now resolves pins from the freshly-published `SHA256SUMS.txt` and `RELEASE-METADATA.json`, so it exercises the hardened path end-to-end.
- **`README.md` and `docs/SETUP.md` lead with Homebrew.** The one-line `bash <(curl ...)` path is demoted to "download-inspect-run" with explicit `LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN` opt-in guidance.
- **Testing claims match fresh evidence.** README no longer says "700+ tests all passing, Live E2E verified"; it reports the actual `swift test` count (759) and clarifies that live E2E assertions are split between environment-independent (pass cleanly) and Logic-Pro-gated (require a live session).
- **`logic://library/inventory` now validates JSON before serving.** `ResourceHandlers.readLibraryInventory` parses the file with `JSONSerialization` and falls through to the next candidate on malformed input, so a corrupt or attacker-shaped cache file can't be returned under the `application/json` mimetype.
- **Public contract surfaces converged.** `docs/API.md` Resource Catalog lists all 9 resources + 3 templates, `set_tempo` range (5–999) matches runtime in API.md, tool description, and `logic_system help`. `docs/TROUBLESHOOTING.md` startup-banner example reflects v3.0.0 counts. `README.md` documentation table lists "9 resources, 3 templates" instead of the stale "6 resources".

### Fixed — round 4 (production-readiness pass)

- **ISO 8601 fractional-second precision is preserved across the wire.** Shared `JSONEncoder`/`JSONDecoder` now use a custom date strategy matching `Logger`'s `[.withInternetDateTime, .withFractionalSeconds]` formatter, so `logic://mcu/state.connection.lastFeedbackAt` and every other `Date` field stay aligned with the log timestamp format. Previously `JSONEncoder.iso8601` silently truncated sub-second precision.
- **`LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override now resists symlink abuse.** `validateLibraryInventoryPath` resolves symlinks, refuses anything that isn't a regular `.json` file ≤ 64 MiB, and logs the resolved path on rejection. Removes the "hostile daemon-env var points MCP at `/etc/passwd`" class of attacks.
- **`goto_position` now fails closed on unknown param keys.** Previously a caller sending the legacy `{ "time": "…" }` alias would silently seek to `"1.1.1.1"`; now the dispatcher returns an explicit error naming the removed key and the allowed set (`bar`, `position`).
- **`encodeJSON` fallback path uses a full JSON escape helper** (`jsonStringEscape`) covering `"`, `\`, `\b`, `\f`, `\n`, `\r`, `\t`, and U+0000-U+001F. Previous escaping missed control characters, which would have produced invalid JSON if a future Foundation error message carried them.
- **`StatePoller.Runtime` gains an injectable `sleep` closure.** Tests can now drive the poll loop at 1 µs cadence instead of waiting out the production 3 s interval. The two lifecycle tests (`testStatePollerStartStopLifecycle` and `testLogicProServerStartCoversDefaultPortAndPollerLifecyclePaths`) used to take ~2 000 s each and were excluded from CI; with the injectable sleep + `.fastTest` runtime (which also short-circuits `hasVisibleWindow` to avoid live AX calls) they now complete in ≤ 20 ms each and are included in the default test run.
- `docs/MAINTAINERS.md` now documents the runtime env matrix (`LOG_LEVEL`, `LOG_FORMAT`, `LOGIC_PRO_MCP_LIBRARY_INVENTORY`, installer pins) and the post-tag Homebrew `sha256` sync step.

### Migration from v2.3.x

Replace every mutating `logic_tracks.*` call with an explicit `index`:

```diff
- logic_tracks rename { "name": "Lead Vox" }
+ logic_tracks rename { "index": 0, "name": "Lead Vox" }

- logic_tracks mute { "enabled": true }
+ logic_tracks mute { "index": 3, "enabled": true }
```

For `arm_only` and `record_sequence`, check `isError` before parsing the JSON payload. Previous `armedSuccess: false` / `track_index_confirmed: false` responses are now returned as structured errors.

#### `set_instrument` now requires a selector

```diff
- logic_tracks set_instrument { "index": 0 }
+ logic_tracks set_instrument { "index": 0, "path": "Electronic Drums/Roland TR-909" }
# or
+ logic_tracks set_instrument { "index": 0, "category": "Synthesizer", "preset": "Vintage Mono" }
```

#### `goto_position` renames `time` → `position`

```diff
- logic_transport goto_position { "time": "00:00:10:12" }
+ logic_transport goto_position { "position": "00:00:10:12" }

- logic_transport goto_position { "time": "9.1.1.1" }
+ logic_transport goto_position { "position": "9.1.1.1" }
# or
+ logic_transport goto_position { "bar": 9 }
```

Sending `{ "time": ... }` in v3.0.0+ returns an explicit error naming the removed key.

## [2.3.1] — 2026-04-19

### Fixed

- **`record_sequence` now places regions at the requested bar reliably.** Live verification revealed that Logic Pro's MIDI File Import anchors the imported region to the current playhead position — a bar=1 request on a session whose playhead had drifted to bar 129 produced a region at bar 129. The fix forces the playhead to bar 1 before every import via the `탐색 → 이동 → 위치…` dialog (auto-extends project length; slider path was silently clamping). Strategy D padding CC continues to position notes within the region at the requested bar.
- **`transport.goto_position` no longer silently clamps to project length.** Previous implementation used the 마디 slider whose value is clipped to the active project's end bar. A `goto_position bar=50` on an 8-bar project stopped at bar 8 with a success response. The new implementation uses the dialog (which auto-extends the project) as the primary path and falls back to slider only when the dialog is disabled (empty project).
- **Dialog-keystroke race eliminated.** The previous `delay 0.5` assumed the Go-to-Position dialog would render within 500 ms. On slow machines the Cmd+A keystroke reached the arrange area instead, silently triggering "Select All Regions." The dialog-ready state is now polled with a 3-second timeout.

### Security

- `midi.import_file` now restricts its `path` parameter to `/tmp/LogicProMCP/*.mid`. The only legitimate producer is `TrackDispatcher.record_sequence` (UUID-generated temp paths); external MCP callers cannot point the AX file dialog at arbitrary filesystem locations.

### Testing

- `testRecordSequenceSMFImportHappyPath` now asserts that `transport.goto_position` with `bar=1` is routed BEFORE `midi.import_file`. Catches silent regression of the v2.3.1 bar-positioning invariant.

### Documentation

- `docs/API.md`: documented the dialog-path latency for `transport.goto_position` (~800 ms), and marked `recorded_to_track` as a legacy alias for `created_track`.
- `ChannelRouter.swift`: inline comment on `region.select_last` / `region.move_to_playhead` clarifying they are reserved for a future region-editor tool (record_sequence does not use them).

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
