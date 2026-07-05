# Enterprise Review Findings (issue #234 follow-on full sweep)

Baseline: main 7bb8bf3, v3.7.4, 1980 tests green. All reviewers read-only.
Constraint: behavior-preserving + test-green only; no wire/surface changes; redesigns = HIGH RISK/defer.

## Reviewer 1: Dispatchers/Server/Resources/State (DONE — 16 findings, 0 correctness bugs)

Framing: mature; DispatcherSupport + HonestContract + MCPToolContent already ARE the shared decode/encode layer — most fixes are "route stragglers through existing helpers."

P1:
- #1 [SAFETY] LogicProServer.swift:651 `mutatingCommandsByTool` hand-maintained, can drift from dispatcher switches → mutation-gate bypass (2 AX writes interleave). Only transport has a completeness guard. FIX: drift-proof per-tool completeness test (mirror validHelpCategories lockstep at SystemDispatcher:276). Risk L (test-only). Size M. **← top pick, safety.**
- #2 ResourceHandlers.swift God object 1466 LOC/~8 responsibilities. FIX: split into same-type extensions (+CacheEnvelope/+CatalogRouting 297-753/+StateReaders/+LibraryInventory). Pure move. Risk L. Size L.

P2:
- #3 MIDIDispatcher.invalidParamsResult reached 50× from 6 files for non-MIDI rejections; thin re-export of toolInvalidParamsResult. FIX: replace 50 sites w/ canonical free fn, delete re-export. Risk L. Size S.
- #4 ResourceHandlers 297-521: 5 near-identical catalog URI routers. FIX: parseCatalogURI(host,namedSegments)->CatalogRoute enum. Risk M (URI security-validation surface — port every guard). Size M.
- #5 TrackDispatcher record_sequence SMF block ~620 LOC = 50% of file. FIX: move to TrackDispatcher+RecordSequence.swift. Pure move. Risk L. Size M.
- #6 TrackDispatcher:75-101 4 byte-identical create_* bodies. FIX: command→operation map. Risk L. Size S.
- #7 TrackDispatcher:221-304 mute/solo/arm near-identical ×3. FIX: handleToggle helper (preserve error hints verbatim). Risk L. Size S.
- #8 TrackDispatcher:127,166 + MixerDispatcher:197 inline verified==true parse dup of channelResultIsVerified (DispatcherSupport:142). FIX: use existing predicate. Risk L. Size S.
- #9 TransportDispatcher:543,647 + ResourceHandlers:228 three interchangeable transport-state readers. Risk M (decode-strictness divergence — manual is lenient vs Codable whole-decode-fail). Size M. **← verify parity before collapsing.**
- #10 LogicProServer:518-582/617-649 runWithDeadline/runResourceReadWithDeadline + DeadlineRace/ResourceDeadlineRace near-dup. FIX: generic SingleWinnerRace<T>. Risk M (load-bearing concurrency backstop #112/#199 — own commit, last). Size M.

P3: #11 StatePoller 5 poll* fns→generic; #12 LogicProServer.stop() re-impl runtimePlan teardown; #13 runtimePlan ?? default; #14 readMixer/readMixerStrip cache-envelope formatting dup; #15 ~14 catalog readers share envelope shape (low value, fields differ); #16 SystemDispatcher helpText re-documents commands → doc drift (Phase D).

INTENTIONAL DO-NOT-FIX: ProjectDispatcher:40-76 per-case audit gate (documented diff-review safety); per-route 5-step guards (intentional non-abstraction); wrapWithCacheEnvelope manual JSON splicing (byte-identical envelope).

---
(awaiting: review-channels, review-ax, review-workflows, review-tests-docs)

## Reviewer 2: Accessibility/Plugins/Audio (DONE — 14 findings, 0 correctness; concurrency clean)

All AXLocalePolicy "bypasses" are read-only classifiers/locators (none gate State-A) → consistency defects not bugs.

P1:
- #1 AXLogicProElements.swift God object 1799 LOC/9 responsibilities. FIX: same-type extensions (+Transport/+Tracks/+Mixer/+PluginSlots/+Markers/+Menu). Risk L (pure move). Size M. **← matches my pre-analysis; do alongside AccessibilityChannel split.**
- #2 PluginInspector.swift:497-685 "Live AX helpers" bypass AXHelpers (19 raw AXUIElementCopyAttributeValue), not runtime-injectable/untestable, centerPoint:539 dups point/size(fromRawAttribute:). FIX: route through AXHelpers. Risk M (live-only, thin coverage). Size M.

P2:
- #3 LibraryAccessor:521,534,544 ↔ LibraryDiskScanner:598,614,580 triplicate flattenPresetsByCategory/collectLeaves/countNodes (byte-identical, LDS comments "Mirrors"). FIX: hoist to extension LibraryNode. Risk L. Size S. **← easy win.**
- #4 [DEAD] AXLogicProElements:543-562 findTrackOutline zero refs (superseded v3.0.3). FIX: delete. Risk L. Size S. **← easy win.**
- #5 LibraryAccessor:1166,1182 hardcoded "라이브러리"/"library". FIX: AXLocalePolicy.libraryBrowserLabel. Risk L. Size S.
- #6 AXValueExtractors:460-461 inline KO track-type tokens (오디오/악기) while peers moved to policy (#60). FIX: track-type LabelSets, EN-only for unverified. Risk L. Size S.
- #7 AXLogicProElements:1540,1621 two 13-locale tables (markerListWindowSuffixes/markerCellPlaceholders) outside AXLocalePolicy. FIX: relocate to policy. Risk L. Size S.

P3: #8 cancelMarkers inline; #9 findControlBarCheckbox ko/en params ×7 callers (Risk M); #10 productionMouseClick/postCliclick misplaced in LibraryAccessor→AXMouseHelper (Risk M, live cliclick); #11 AnalysisPolicy.default restates defaults; #12 StockPluginCatalog.capabilities()->[String:Any] untyped (Risk M wire); #14 spectralCentroidHz/frequencyPeaks always nil — RESERVED wire contract, DO NOT remove.

CATALOG QUESTION ANSWERED (#13): StockPluginCatalog 1163 is ALREADY data-driven (Seed array + factories). DO NOT externalize to JSON — loses compile-time safety + zero-dep deploy for nothing. Optional: split +Types/+Validator/+Seeds/+Probe.

NON-ISSUES confirmed: pluginSlots vs audioPluginInsertSlots coexist by design; VerifiedPluginCatalog/StockInstrumentCatalog cross-ref not dup.

## Reviewer 3: Workflows/Utilities/MIDI (DONE — 14 findings, 0 reachable P0)

Headline: mature, HonestContract adoption strong (253 encoder call-sites vs 3 hand-rolled). Big Workflow files NOT God-objects (already declarative).

P1:
- P1-1 HonestContract.swift:176-221 FailureError ~45 assoc-value-free cases w/ 45-line manual rawValue switch (2 driftable places). FIX: String-backed enum (case axWriteFailed="ax_write_failed"), delete switch. Keep UncertainReason manual (has echoTimeout(ms:)). Risk L (literals byte-identical, HonestContractTests pins). Size S. **← best effort:value, highest-leverage file.**
- P1-2 ProjectSessionAudit.swift:433-732 deterministicFindings one ~300-line method (15+ append blocks). FIX: extract systemFindings/trackFindings/exportFindings/markerFindings/mixerFindings → concat → existing id-sort:382. Risk L. Size M.

P2:
- P2-1 [LATENT CORRECTNESS] SMFWriter.swift:31 barOffsetTicks ignores timeSignature.denominator (6/8 → 2× too large). UNREACHABLE today (sole caller TrackDispatcher:761 hardcodes (4,4), bar defaults 1) but landmine on reuse. FIX: ticksPerBeat=ticksPerQuarter*4/denominator. Risk M (verify no test pins wrong value). Size S. **← only real correctness defect; fix cheaply.**
- P2-2 SetupDoctor:27-57 ↔ SetupLifecycle:36-46,145-158,576-583 duplicated RemediationType/Remediation/anchors (SetupLifecycle:34 "Mirrors SetupDoctor"). FIX: hoist shared (SetupDoctor has extra systemSettings case). Risk M (both JSON wire contracts). Size M.
- P2-3 TrackDispatcher:826,852,892 + ProjectDispatcher:697 bespoke error strings (import_failure/import_unverified/audibility_unverified/export_readiness_blocked) bypass FailureError. Documented+terminal → consistency only not bug. FIX: add to FailureError + encodeStateC. Risk M. Size M.
- P2-4 SetupDoctor:402,423,474,509 4× repeated binary-resolve guard. FIX: requireBinary() helper. Risk L. Size S.

P3: P3-1 dead sanitize Bool/Int/Double cases; P3-2 addExtras skips sanitize (silent no-merge on unencodable); P3-3 velocity 0=silent note (parser accepts, SMF emits note-off); P3-4 tempoMetaEvent no bpm<=0 guard (unreachable); P3-5 ProjectSessionAudit:958-960 pointless sort within group; P3-6 logicNotRunning absent from terminalErrorCodes (confirm intentional — relaunch channel); P3-7 positional magic args ~30 sites (toolStep bare Bool/String?); P3-8 SetupDoctor 1194 optional split (low value, check factory already DRY).

HC consistency verdict: uniform (253 sites), only 3 documented terminal dispatcher composites bypass (P2-3). No hand-rolled State A/B classification.
MIDI encoders (MCU fader/button, MMC SMPTE, NoteSequenceParser) verified correct.

## Reviewer 4: Channels (DONE — 20 findings, 1 REAL P0 concurrency bug)

### ⭐ P0 [CONCURRENCY BUG — probable MCU echo flake root cause, PR #153]
- MCUChannel.swift:180 every feedback event does `Task { await self.receiveFeedback(event) }`; unstructured Tasks have NO FIFO on the actor → pitch-bend/CC echo bytes reach MCUFeedbackParser out of order. FIX: single AsyncStream consumed by one long-lived task. Risk M-H (timing change; verify parser tests). Size M. **← CONFIRMED CANDIDATE per memory "MCU echo flake". MUST FIX.**

### ⭐ VERDICT: split AccessibilityChannel.swift = YES (L risk). 8 cross-file extensions:
+Transport (603-990,992-1280,3633-3760,3849-4078), +Tracks (1282-1710,1830-2074), +Mixer (2075-2131,4079-4217), +Plugins (2132-2418), +Library (2419-3630), +Regions (4218-4482,5024-5277), +MIDIImport (4495-5023), +Project (4482,5278-5318).
PROMOTION ACCOUNTING: 89 private → only ~21 need private→internal (the execute/Runtime.axBacked/healthCheck-referenced statics); ~64 stay private; ~40 already internal (0 change); **0 stored-prop promotions** — HARD CONSTRAINT: cross-file ext can't see actor private stored state, so keep 13-14 stored props + 4 private scan-orchestrators (runLiveScan/runDiskScan/runBothScan/setLastScan + seedLastScanForTest) in CORE. Core shrinks 5369→~700-900. Risk L (compiler-verified; 29 test-pinned funcs resolve file-agnostic). Size L.

P1:
- #3 monster funcs → phase extract: +VerifiedPlugins:1022 defaultInsertVerified (465), :4617 defaultImportMIDIFile (418), :3206 setTrackInstrument (380), +VerifiedPlugins:648 performVerifiedParamWrite (209). Risk M. Size L.
- #4 blocking sleeps ×18 (Thread.sleep/usleep at 797-811,1456,1567-1659,3669,4070,4170…) + CGEventChannel:252 usleep stall cooperative pool (+VerifiedPlugins already does await Task.sleep right). FIX: CGEvent tractable (async postShortcutSequence), AX-main systemic. Risk M(CGEvent)/H(AX-main). Size M/L. **← do CGEvent only; AX-main defer (H, systemic).**
- #5 MCUChannel:682 withBanking fast-path race (bypasses isBanking, currentBank late-updated). Risk M (confirm vs server mutation-gate). Size S.
- #6 CoreMIDIChannel:159+ channel/velocity param-parse dup ×11. FIX: parseChannel/parseVelocity→Result (MUST return .error not throw — outer catch@503 re-wraps=wire change; strings test-pinned). Risk M. Size M.
- #7 catch-block dup MIDIKeyCommandsChannel:235,375,405,435 (×6) + MCUChannel:314,376,430,505,538 (×5). FIX: failSend/runValidated. Risk L. Size M.
- #8 AppleScriptChannel:679-721 byte-identical static+instance dup (projectPathsMatch/normalizedProjectPath). FIX: instance delegates to static. Risk L. Size S.

P2: #9 two near-identical JSON encoders (:3048,:5343, 0 tests assert strings — safe merge); #10 DEAD write-only prop lastBothScan (:21, written 2511 never read); #11 State-C idiom ×68 inline (port typed helpers from +VerifiedPlugins); #12 shared scanInProgress conflates library.scan_all+plugin.scan_presets (:323,353→two flags); #13 AppleScript HC-wrap boilerplate ×4; #14 CoreMIDI 414-line execute god-method; #15 CoreMIDI transport/mmc arms dup; #16 MCU pollFaderEcho/pollPanEcho identical; #17 Scripter/MIDIKeyCommands dup (midiChannel=15/start/healthCheck→shared protocol, mind RoutingAuditInvariantTests log strings); #18 ChannelRouter 248-line routing-table literal→RoutingTable.swift.

P3: #19 AppleScript iso8601String per-call formatter alloc→static; #20 ChannelRouter route State-C fall-through→classifyStateCOutcome.

SYSTEMIC HIGH-RISK OUT-OF-SCOPE (flag only, DO NOT TOUCH): HC surface inconsistency (CoreMIDI/MCU free-form strings vs AppleScript HC envelopes) = wire change dozens of ops; same-failure-two-codes (.axWriteFailed vs .portUnavailable) = wire change.
NON-FINDINGS: as! AXUIElement guarded by CFGetTypeID (safe); HC v1 (main,118×) vs v2 (+VerifiedPlugins,36×) INTENTIONAL/test-enforced (unify=BREAKING).

## Reviewer 5: Tests/Scripts/Docs (DONE — headline: dead assertions ~172 not ~31)

### SUB-TASK 1 — DEAD ASSERTIONS (my framing was WRONG, proven empirically)
Reviewer built a throwaway swift-testing package (Swift 6.2.4, same as repo) and ran it:
- `Bool(true) == false` NON-OPTIONAL → PASS (DEAD). The #expect macro renders ==/!= dead whenever BOTH operands are statically Bool or Bool?. Int/String/enum/`== nil` stay LIVE.
- Only bare `#expect(x)` / `#expect(!x)` / `#expect(x!)` actually assert.
- **VERIFIED-DEAD TOTAL ≈ 172**: 157 in-scope (==true/false/??false/.some) + 14 that grep MISSES (`isError != true` success guards) + 1 `boolVar==boolVar` (MarkerProvenanceTests:115, parameterized→dead all cases).
- ~126 of the 157 are NON-OPTIONAL Bool == true/false — the #92 sweep (2021) left these thinking they were live; DISPROVEN. That's the bulk.

P1 SAFETY-CRITICAL dead guards (false-green on the exact fail-closed/honesty behaviors the project sells):
- Issue136GotoDriftHonestTests:115 `result.isError == true` (drifted goto must surface isError) — DEAD
- PluginInsertVerifiedTests:581,594,642 `succeeded == false` (unverifiable removal never succeeded:true) — DEAD
- AXPluginInsertSlotsDriftTests:95,146 `slots[1].isEmpty == false` (AC21 occupied-unreadable NOT write-safe) — DEAD
- DispatcherTests:1117,1178,2978 `isError != true` success guards — DEAD

EXACT TRANSFORMS (optionality-dependent, NOT one-size):
1. non-optional Bool: `x==true`→`#expect(x)`; `x==false`→`#expect(!x)`
2. `as? Bool` optional: force-unwrap `#expect((o["k"] as? Bool)!)` (nil crash IS a real finding)
3. optional flag where nil should FAIL (verified/exists/selectionRestored): `#expect(x!)`
4. optional where nil is VALID success (result.isError): NO force-unwrap, NO `?? false` (also dead) → bind `let e = result.isError ?? false; #expect(e)`/`#expect(!e)`
5. tautologies `X==true || X==false` (CGEventChannelTests:221, PermissionCheckerTests:129-132, ProcessUtilsTests:262): delete/replace.
Risk M (test-only, high volume, each transform re-run to surface newly-live failures). Size L.
Worst files: MCUFeedbackParserTests 13, MCUChannelTests 9, ProcessUtilsTests 8, LibraryAccessorResolvePathTests 8, PluginInsertVerifiedTests 7, DispatcherTests 7, AccessibilityChannelTests 7, ResourceSchemaTests 6, Production/CommercialReadiness 6 each.

### SUB-TASK 2 — TESTS
- P1 AX-tree helpers file-private in Mixer123FixtureSupport:24-69 (axPoint/axSize/setFrame/setRole/setNamedContainer/setButton) → 24 files re-spell raw kAX (1248 setAttribute, 391 kAXRole; AccessibilityChannelTests alone 127). FIX: promote onto FakeAXRuntimeBuilder in AccessibilityTestSupport. Risk L. Size L.
- P2 JSON/text micro-helpers cloned ~20 files despite SharedTestHelpers; local text() clones silently return "" for .resource envelopes (drift). FIX: use sharedToolText/sharedJSONObject. Risk L. Size S-M.
- P2 [COVERAGE HOLE] BoundedProcessRunner.swift (150 LOC) ZERO direct tests — safety-critical SIGTERM→0.2s→SIGKILL + concurrent drain, 12+ call sites. Regression dropping SIGKILL passes CI. FIX: BoundedProcessRunnerTests (SIGTERM-ignoring child→SIGKILL; >64KB stdout→no deadlock; timeout→.timedOut; normal→.completed). Risk M. Size M. **← genuine safety gap.**
- P3 test target auto-globs (no sources: list) → safe git-mv into subdirs; 166 flat files, naming inconsistent; StateModels no Codable round-trip test.

### SUB-TASK 3 — SCRIPTS/DOCS
Ground truth VERIFIED: v3.7.4 ✓, 10 tools/18 resources/11 templates ✓, logic:// ✓, all 10 scripts set -euo pipefail ✓, rm -rf guarded ✓. Well-hardened.
- Scripts P1 release.sh:168-173 Formula sha256 awk rewrite UNVERIFIED → format drift → stale hash → all brew install fail checksum (#22-class). FIX: after mv, `grep -Fq "$TARBALL_SHA" Formula/logic-pro-mcp.rb || exit 1`. Risk M-H. Size S. (Mitigant: primary path is release-stable.sh→CI; this is local/legacy.)
- Scripts P2 install-common.sh:80-87 validate_share_dir asymmetric vs validate_install_dir:70-78 (no /System /usr/bin reject) before uninstall.sh:89 rm -rf w/ sudo. FIX: same protected-path case. Risk M. Size S.
- Scripts P2 install.sh:23-36 eval copy of install-common.sh (curl|bash path), 2 copies no parity test.
- Scripts P3: install.sh:244 curl 2>/dev/null hides errors; release.sh:47-52 eval "$@" vs release-stable "$@"; release.sh:176 git commit aborts on no-op re-run; release-stable.sh:66 unwrapped rev-parse breaks DRY_RUN; :94 hardcoded py_compile list.

DOCS P2 (real staleness):
1. Mixer "send" wrongly = MCU write: README:91 + TROUBLESHOOTING:100. Code: set_send NOT exposed → State C command_not_exposed (MixerDispatcher:65-69); only set_master_volume live MCU. FIX: drop "send".
2. CONTRIBUTING:118 channel table "MCU | Mixer writes (fader/pan/send)" stale pre-#83; fader/pan→.accessibility (ChannelRouter:108-109). FIX.
3. Test counts stale+inconsistent: README:17/60/233 say 1933; CONTRIBUTING:55/98/161 say 1846; reality ~1980. FIX: recount, sync 6 sites.
DOCS P3: README:60/238 strict E2E "352/352"→ HEAD #234 records 369/370; SECURITY.md:99 "v3.7.0" anchor at v3.7.4.

---
# ============ ALL 5 REVIEWS COMPLETE ============
