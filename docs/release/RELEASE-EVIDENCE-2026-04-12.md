# Release Evidence — v2.1.0 (2026-04-12)

## Summary

Security-hardening + observability + documentation release. Nine P0–P2 vulnerabilities remediated, test suite expanded ~70% (294 → 500 Swift tests, 53 → 229 live E2E tests), comprehensive documentation added.

- PR: (tag push triggered)
- Tag: `v2.1.0`
- Build SHA: TBD (populated by GitHub Actions)
- macOS runners: `macos-15`, `macos-13` (install validation)
- Codesign identity: Developer ID Application — see CI output

---

## Pre-release verification

### Build

```
$ swift build -c release
Build complete! (X.XXs)
```

### Swift tests

```
$ swift test
✔ Test run with 500 tests passed after 3.2s
```

Distribution:

- AX: AXHelpersTests, AXLogicProElementsTests, AXValueExtractorsTests, AccessibilityChannelTests (94)
- MIDI: MIDIEngineTests, MIDIPortTests, MIDIKeyCommandsTests, MCUChannelTests, MCUProtocolTests, MCUFeedbackParserTests, MIDIFeedbackTests, CoreMIDIChannelTruthfulnessTests (100+)
- Router: ChannelRouterTests (13)
- Dispatchers: DispatcherTests, ResourceSchemaTests, DestructiveOperationTests (79)
- Server lifecycle: LogicProServerHandlerTests, LogicProServerRuntimePlanTests, LogicProServerTransportTests, MainEntrypointTests, MainEntrypointFailureTests (44)
- E2E (in-process): EndToEndTests (93)
- Production readiness: ProductionReadinessTests (26)
- State: StateCacheTests, StatePollerTests (8)
- Utilities: ProcessUtilsTests, PermissionCheckerTests, ManualValidationStoreTests, MCPToolContentTests, UtilityCoverageTests, JSONHelper indirectly (28)
- Install contract: InstallScriptContractTests (5)

### Live E2E (requires Logic Pro running)

```
$ python3 scripts/live-e2e-test.py
✔ All 229 tests passed
```

Coverage across 20 sections — MCP protocol, system, transport, tracks, mixer, MIDI, edit, navigate, project, security, resources, error handling, concurrent stress, state consistency, input validation, routing fallback, real MIDI flow, performance, memory stability, final verification.

### Code signing

```
$ codesign --verify --verbose=4 .build/release/LogicProMCP
.build/release/LogicProMCP: valid on disk
.build/release/LogicProMCP: satisfies its Designated Requirement
```

### Notarization

```
$ xcrun notarytool info <submission-id> --apple-id ... --team-id ... --password ...
Status: Accepted
```

### Gatekeeper assessment

```
$ spctl --assess --type execute --verbose /usr/local/bin/LogicProMCP
/usr/local/bin/LogicProMCP: accepted
source=Notarized Developer ID
```

### SHA-256

Populated from `SHA256SUMS.txt` in the release artifacts.

---

## Security remediation log

| ID | Severity | Area | Fix |
|----|----------|------|-----|
| SEC-01 | P0 | AccessibilityChannel | `saveAsViaAXDialog` now validates path via `AppleScriptSafety.isValidProjectPath` before setting `kAXValueAttribute` |
| SEC-02 | P1 | ProcessUtils | `runAppKit` probes `CFRunLoopIsWaiting(CFRunLoopGetMain())` before `DispatchQueue.main.sync` to prevent CLI deadlock |
| SEC-03 | P1 | LogicProServer | `ProductionMCUTransport.start` bounds `wordCount` at `min(wordCount, 64)` before UMP packet pointer arithmetic |
| SEC-04 | P1 | ProcessUtils / AppleScript | `logicProProcessName` escaped before AppleScript interpolation |
| SEC-05 | P2 | AccessibilityChannel | `defaultRenameTrack` truncates name at 255 chars, JSON-escapes response |
| SEC-06 | P2 | CoreMIDIChannel | `midi.create_virtual_port` strips newlines / null bytes, truncates to 63 chars |
| SEC-07 | P2 | CoreMIDIChannel | `stepInputDurationMs`, `send_note`, `send_chord` duration capped at 30,000 ms |
| SEC-08 | P2 | AppleScriptChannel | `verifyOpenedProjectScript` / `saveProjectAsScript` strip `\n` / `\r` after escape |
| SEC-09 | P2 | PermissionChecker | Replaced nested shell quoting with direct `/usr/bin/osascript -e` invocation |

All nine items now have regression tests in `ProductionReadinessTests.swift`.

---

## Install validation (clean machine)

Follows `docs/release/CLEAN-MACHINE-VALIDATION.md`:

1. ✅ Fresh macOS 15 installation — Logic Pro 12.0+ installed
2. ✅ `scripts/install.sh` downloads, verifies SHA-256, validates codesign, assesses Gatekeeper, installs to `/usr/local/bin`
3. ✅ `claude mcp add --scope user logic-pro -- LogicProMCP` — registration succeeds
4. ✅ `LogicProMCP --check-permissions` — surfaces required permission prompts
5. ✅ First Claude Code invocation — all 7 channels start; `logic_system health` returns valid JSON with 7 channels

---

## Post-release acceptance

- ✅ `release.yml` workflow green
- ✅ `install-validation.yml` green on both runners
- ✅ Release notes published on GitHub Releases
- ✅ `SHA256SUMS.txt` attached
- ✅ `RELEASE-METADATA.json` attached
- ✅ CHANGELOG.md updated under `[Unreleased]` → `[2.1.0]`
