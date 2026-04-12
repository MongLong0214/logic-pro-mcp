# Changelog

All notable changes to Logic Pro MCP Server are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project uses [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

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
- **Configurable state polling interval** — new `ServerConfig.statePollingIntervalNs` (default 5 s) replaces the previously hardcoded value in `StatePoller`.
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
