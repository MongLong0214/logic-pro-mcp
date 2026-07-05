# Second-round deep audits (100% coverage, cap-free)

## audit-concurrency (DONE — codebase "unusually disciplined"; 2 real issues)

### MCU race CONFIRMED + SIBLING (was thought 1 site, actually 2):
- MCUChannel.swift:180 `Task { await self.receiveFeedback(event) }` AND LogicProServer.swift:1051 `for event in events { Task { await self?.onReceive?(event) } }` — production MCU path fans into unordered Tasks TWICE. Actor admits in arrival not creation order → e2 before e1.
- Order matters: pitchBend→updateFader last-write-wins (false State B echo_timeout OR false State A verified on intermediate); sysEx LCD positional; select→selectOnly wrong track.
- Severity P1 (not P0): set_volume/set_pan now [.accessibility]-primary w/ AX readback (insulated); only mixer.set_master_volume [.mcu] + get_state depend on echo. P0 only on MCU-control-surface setups.
- FIX (BOTH sites): ProductionMCUTransport yields events into AsyncStream continuation (synchronous .yield, FIFO) from CoreMIDI block; MCUChannel drains with ONE `for await event in stream { await receiveFeedback(event) }` task in start(), cancel in stop(). Mirror MIDIEngine.inboundMessages. Risk LOW-MED. Lifecycle tests (boomer #5): burst FIFO, start-stop-start, post-stop ignored, no leak. → WS-B.

### [MEDIUM] cooperative-pool blocking pervasive + inconsistent:
- On-actor sync sleeps: setTempo ~370ms (AccessibilityChannel:797-811), toggle usleep (1456/1474), rename usleep×5 (1567-1608), zoom usleep (3669/4070); runLiveScan Thread.sleep×11 ~50s (LibraryAccessor); AppleScript Task.detached still on pool (472); ProcessUtils ps/pgrep/osascript at top of EVERY execute (isLogicProRunning).
- Only setTrackInstrument offloads correctly (DispatchQueue.global, :3190).
- Mitigations keep it MEDIUM: LogicMutationGate serializes mutations; reads don't sleep; stdio on dedicated Thread; deadline on DispatchQueue.global. Server stays responsive. Starvation risk on 2-core CI.
- **DECISION: EXCLUDE from v3.8.0 (follow-up).** Same class as boomer's CGEvent-async exclusion: MEDIUM risk, wide, NOT correctness, AX-thread-consistency constraint, mitigations exist. Document as follow-up. Behavior-preserving + tight ≠ risky wide change.

### LOW: #3 MIDIEngine.inboundMessages produced never consumed (dead code + latent unbounded-buffer leak if sink ever receives) — remove or consume. Low risk → optional include. #4 withBanking continuation-semaphore fragile but CORRECT (no live bug). #5 MCUFeedbackParser conn RMW across awaits (fixed by #1 single-consumer). #6 ManualValidationStore flock spin (admin-CLI only). #7 ProcessUtils.runAppKit main.sync (guarded, never blocks in stdio server).

AUDITED SOUND (no action): DeadlineRace/gate scaffolding, SerializedStdioTransport (#220), StateCache, StatePoller, MIDIPortManager, ChannelRouter reentrancy (read-only), note-off Tasks (structured), Logger/ProcessUtils/JSONHelper statics (all NSLock-guarded), all 23 @unchecked Sendable (safe), AXUIElementSendable (immutable CF on AX actor), MainEntrypoint signal shutdown, MIDIEngine restart-safety.

---
(awaiting: audit-security, audit-completeness)

## audit-security (DONE — 0 Critical/High reachable by untrusted MCP client; 3 Medium + ~8 Low)

Crown-jewel sinks EXEMPLARY (arg-array exec never shell, backslash-first AppleScript escape, strict range/allowlist validation, mkdtemp, out-of-band privilege gating). Findings cluster in config/env + CI/supply-chain.

MEDIUM (must-fix before enterprise release):
- M1 [REAL VULN] .github/workflows/publish-mcp.yml:25 `VERSION="${{ github.event.release.tag_name }}"` no SemVer guard, interpolated into run: block; job has id-token:write + mcp-publisher login+publish. Malicious tag_name → arbitrary code in runner under OIDC identity. Reachable: release-publisher (not anon). FIX: env RELEASE_TAG then `VERSION="${RELEASE_TAG#v}"`. Risk none. **← INCLUDE, must-fix #1.** (owner: new WS-F extended to .github/workflows.)
- M2 install.sh:39 normalize_path (symlink-resolve) BEFORE validate_install_dir; install-common.sh:74 blocklist misses macOS /private trio (/etc→/private/etc etc). LOGIC_PRO_MCP_INSTALL_DIR=/etc → /private/etc passes → sudo mv. Reachable: operator/MDM env. FIX: blocklist realpath +/private/etc,/private/tmp,/private/var. Risk low. **← INCLUDE (WS-F).**
- M3 [by-design, documented] ADHOC releases: integrity yes (codesign verify+SHA256) authenticity no (adhoc sig anyone). hardened path fail-closed + out-of-band pin. FIX: ship notarized (path exists release.yml:99-137) OR document out-of-band-pin as sole enterprise path. **← Phase D doc + Phase E release decision.**

LOW (INCLUDE the cheap ones):
- L1 env-var exec (LOGIC_PRO_MCP_BOUNCE_HELPER, INSTALL_DIR) no ownership/allowlist — asymmetric vs library-inventory pattern (ResourceHandlers:1358-1403). FIX: apply ownership+location allowlist. **← INCLUDE (Swift, WS-D or WS-E owner TBD).**
- L2 /tmp/logic-library-click-debug.log symlink-follow (gated LOGIC_LIBRARY_CLICK_DEBUG). FIX: mkdtemp dir. Low. **← INCLUDE (WS-C, LibraryAccessor).**
- L3 bounce-helper path echo in error; L4 export output_root blocklist (mitigated by sanitize+.wav). Info.
- CI hardening: ci.yml:18 floating actions/checkout@v4 + no permissions block (others SHA-pin); release.yml:15-16 contents:write inherited by read-only validate-install job; release.yml:204 github.ref_name (sanitized, use env). **← INCLUDE CI least-privilege + pin (WS-F).**

Operational: .mcpregistry_*_token in repo root are gitignored + tarball uses explicit allowlist (not tar .) — confirmed NOT shipped. Dev-hygiene only.

CLEAN (coverage proof): all AppleScript via osascript arg-arrays (no NSAppleScript/do-shell-script); BoundedProcessRunner executableURL+arguments never shell; path traversal guards (output_root/library-inventory/LogicProjectFileReader/MIDI-import server-temp-only/SMFWriter mkdtemp/AudioAnalyzer); MCP boundary -32602 + MIDI byte 0-127/ch 1-16/sysex framed + index bounds + count==4-guarded splits; Logger stderr-only rate-capped; TCC fail-closed tri-state + CLI-only manual approvals + flock store. Fully read: Utilities/*, Channels/* (approval gates), Projects/* export, Dispatchers/MIDI, Accessibility/* (cliclick), Server, Resources inventory, MIDI/SMFWriter, all 11 scripts, Formula, 3 CI workflows.

Ranked must-fix: M1 publish-mcp injection → M2 /private bypass → L1 env exec allowlist → M3 notarize/doc → CI least-priv+pin → L2 /tmp → L3/L4/eval.

## audit-completeness (DONE — crash-surface ZERO fatalError/try!/print; new P0 + corrections)

Global baseline: fatalError/try!/print/assert/preconditionFailure = ZERO. All 7 as! CFGetTypeID-guarded. External-input indexing bounds-guarded. Crash-hardened.

### NEW P0
- SIGPIPE unhandled: SerializedStdioTransport.swift:143 + MainEntrypoint.swift:188 (only SIGTERM/SIGINT SIG_IGN'd). Raw Darwin.write to broken pipe (client disconnect mid-write, or `| head`) → SIGPIPE kills process BEFORE write() returns -1, bypassing #220 POSIXError path. EMPIRICALLY PROVEN fatal; `signal(SIGPIPE,SIG_IGN)` → EPIPE(32) survives. FIX: 1 line beside existing SIG_IGN. Risk L. **← INCLUDE (WS-D, Server/root owner).**

### NEW P1 (correctness/honesty)
- PermissionChecker.swift:187-203 runAutomationProbeViaShell returns Bool collapsing timedOut/spawnFailed/denial → false "Automation NOT GRANTED"; sibling :205-227 correctly tri-state (#188 never applied here). FIX: return CheckState. Risk M. **INCLUDE (WS-E, Utilities).**
- AXValueExtractors.swift:257-322 + ResourceProvider.swift:169 extractTrackState (only prod builder, backs logic://tracks) hardcodes volume:0.0/pan:0.0, never sets automationMode(.off)/sampleRate(44100); template advertises "including automation mode" → FABRICATED data on public resource = honesty breach. FIX: omit/nil or read. Risk M. **INCLUDE (WS-C, honesty-critical).**
- AXHelpers.swift:40 unsafeDowncast CFArray NO CFGetTypeID guard (getPosition/getSize 4 lines away have it) → UB. FIX: guard. Risk L. **INCLUDE (WS-C).**
- MIDIFeedback.swift:65-70,127-132 System Common/RT status (0xF1-0xFF≠0xF0) double-consumed (i+=1 at 70 AND 132) + corrupt runningStatus → drops next msg. FIX: handle explicitly. Risk L. **INCLUDE (WS-B or WS-E MIDI).**
- MCUFeedbackParser.swift:44-47 bank offset applied to bank-invariant master fader (ch8) → corrupts unrelated track volume + breaks set_master_volume echo. FIX: channel==8?8:Int(channel)+offset. Risk L. **INCLUDE (WS-B).**
- MCUFeedbackParser.swift:32-38 + StateCache:343 non-atomic conn get/mutate/set races start/stop (= concurrency #5). FIX: updateMCUConnection(mutator:). Risk L. **INCLUDE (WS-B, w/ MCU stream fix).**
- NavigateDispatcher.swift:262-283 create_marker fetches beforeMarkers AFTER mutating route → fragile count-delta verify → StateB-uncertain on success (fails toward uncertainty, not false-success). FIX: poll before route. Risk L. **INCLUDE (WS-D).**

### NEW P2 (selective — cheap/clear ones INCLUDE, rest FOLLOW-UP)
BoundedProcessRunner:108 String(data:.utf8) nils whole buffer on mid-multibyte cut→drops Korean stdout ("") → FIX String(decoding:as:UTF8.self) [INCLUDE cheap]; :90-101 zero logging in SIGTERM→SIGKILL [INCLUDE w/ BoundedProcessRunnerTests]. AppleScriptSafety no shared escapeForScript (dup'd 4 sites — injection risk) + projectURL no resolvingSymlinksInPath [INCLUDE: extract shared escape]. LogicProjectFileReader TOCTOU + 10MB cap after full read [P2, follow-up]. ManualValidationStore usleep on pool [defer w/ cooperative-pool]. DestructivePolicy raw-JSON [INCLUDE cheap]. AXMouseHelper surrogate-split + US-ANSI keycodes [P2 follow-up, locale]. productionMouseClick prefers cliclick over native (round-1 #10 inversion) [INCLUDE w/ WS-C mouse move]. AXValueExtractors slider fallback returns raw not fail-closed [INCLUDE]. ProjectExportExecutor:199 bypasses dialog preflight [P2]. PluginsDispatcher:142 nonEmptyString UNtrimmed contradicts doc [INCLUDE cheap]. DispatcherSupport:52-71 stringParam no alias-conflict check [INCLUDE cheap]. MMCCommands:146-220 strict locate tier DEAD [follow-up]. SMFWriter:126,153 Int(60M/bpm)+UInt8(numerator) traps unreachable [INCLUDE defensive w/ denominator fix]. StateModels:167-191 MCU structs non-Codable→dup mapping [INCLUDE w/ E]. SerializedStdioTransport:69-72 disconnect can't interrupt parked read [P2]. MCUProtocol:285-312 HandshakeResult DEAD.

### DEAD CODE confirmed (delete or wire): AccessibilityChannel:21 lastBothScan; DispatcherSupport:142 channelResultIsVerified (dead until round-1 #8 wires it — so WS-D #8 RESOLVES this); ProjectExportExecutorBounceHelperResolution commandExists; StateCache getPanValue/getFaderUpdatedAt/getProjectFetchedAt/getRegionsFetchedAt; MIDIFeedback Event.unknown+parse(packetList:); MMCCommands deferredPlay/reset/write; Logger 11/14 Subsystem cases; AXMouseHelper:121 pressDelete; AXValueExtractors:46 setNormalizedSliderValue(+taper trap); ResourceJSONHelpers:9 queryItemValue.

### JOB2 CORRECTIONS TO ROUND-1:
1. **Dead assertions ~172 → ACTUAL ~356** (2× undercount; #92 left non-optional survivors). Empirically re-confirmed at pinned revision. WS-G scope DOUBLES.
2. **AccessibilityChannel split ~21 → ~24 promotions**: +3 cross-boundary statics need internal: encodeResult(:5343, Transport/Tracks/Mixer/Regions/Project→+Shared or Core), menuItem(:2363, Plugins+Tracks), verifyTrackSelection(:1672, Tracks+Library). 0 stored-prop confirmed. 4 private instance scan methods stay Core. execute() stays Core. L-risk holds.
3. HC v1/v2 test-enforcement CONFIRMED (HonestContractV2Tests:25/45/66/151/157). Unify=BREAKING.
4. StockPluginCatalog data-driven CONFIRMED.
5. Cross-ownership CONFIRMED file-disjoint + 2 NOTES: (a) `extension LogicProServer` declared in MainEntrypoint.swift(root) → assign main.swift+MainEntrypoint.swift to Server owner (WS-D). (b) P2-3 edits HonestContract.swift AND Track/ProjectDispatcher → **SEQUENCE P1-1 (FailureError String-enum) BEFORE P2-3** to avoid enum collision.

### REFUTED (round-2 false positive killed): ProjectExportPlannerSupport /etc bypass — Foundation .resolvingSymlinksInPath strips /private back for /etc,/var,/tmp → /etc/out stays /etc/out → BLOCKED (test outputRootSymlinkedSystemLocationRejected passes). CORRECTED to P3: /var/db/foo spelling miss (Unix perms mitigate). Risk L.

### NON-FINDINGS (don't re-flag): ProcessUtils:84 main.sync (guarded); Logger rateMap (locked); MarkerState custom decoder (backcompat symmetric); MainEntrypoint teardown; MIDIEngine:82 baseAddress!; AXHelpers:45 as!/unsafeBitCast (standard CFArray idiom).

# ============ ALL ROUND-2 AUDITS COMPLETE ============
Round-1 headlines HOLD w/ 2 corrections (dead ≈356 not 172; split ~24 not 21). Highest-value new: P0 SIGPIPE (1-line), P1 PermissionChecker false-denial, P1 logic://tracks fabricated-data honesty gap. Parallel plan safe modulo: root entrypoints→Server owner; sequence P1-1 before P2-3.
