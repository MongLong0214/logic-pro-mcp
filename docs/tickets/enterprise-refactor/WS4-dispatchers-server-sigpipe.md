# WS4: Dispatchers/Resources/State/Server/Projects/entrypoints — SIGPIPE P0 + splits + dedup

**PRD**: G1/G2/G3, §3.2 WS4
**Priority**: P0 (SIGPIPE) | **Size**: L | **Risk**: mixed (SIGPIPE L; splits L; dedup L-M)
**Owns (EXCLUSIVE)**: `Sources/LogicProMCP/{Dispatchers/*, Projects/*}` + `State/{StatePoller.swift, StateModels.swift}` (**NOT StateCache.swift → WS6**, boomer ticket-R1 #1) + `Resources/*` EXCEPT `ResourceProvider.swift` (→ WS3) + `Server/{ServerConfig.swift, SerializedStdioTransport.swift}` + `main.swift` + `MainEntrypoint.swift` + new test file `Tests/LogicProMCPTests/SIGPIPERegressionTests.swift` (WS4-created, excluded from WS8). MUST NOT touch `Server/LogicProServer.swift` (→ WS6), `ResourceProvider.swift` (→ WS3), `State/StateCache.swift` (→ WS6), or existing test files.
**Parallel-safe with**: WS1/2/3/5/6/7.

## 1. Objective
Fix the P0 SIGPIPE crash, split ResourceHandlers + record_sequence, and route dispatcher dedup through existing helpers — all behavior-preserving.

## 2. Acceptance Criteria
- **AC1 [P0] SIGPIPE**: add `signal(SIGPIPE, SIG_IGN)` beside the existing SIGTERM/SIGINT SIG_IGN in `MainEntrypoint.swift:188` (and confirm SerializedStdioTransport raw `Darwin.write` path is covered). New regression test: a broken-pipe `write` returns EPIPE(32) and the process survives (does not signal-kill). Verified empirically by audit — replicate the proof as a test.
- AC2: ResourceHandlers.swift (1466) → 4 same-type extensions (`+CacheEnvelope`, `+CatalogRouting` 297-753, `+StateReaders`, `+LibraryInventory` 1257-1444). Pure move. NOTE: `wrapWithCacheEnvelope` manual JSON splicing is INTENTIONAL (byte-identical) — keep.
- AC3: TrackDispatcher record_sequence SMF block (~620, `handleRecordSequenceSMF` + ~12 helpers) → `TrackDispatcher+RecordSequence.swift`. TrackDispatcher drops to ~630.
- AC4: create_audio/instrument/drummer/external_midi (4 byte-identical bodies) → command→operation map + shared handler; mute/solo/arm (~28 LOC ×3) → `handleToggle` helper (PRESERVE per-command error hint strings verbatim). Inline `verified==true` parse (TrackDispatcher:127/166, MixerDispatcher:197) → existing `channelResultIsVerified` (resolves that currently-dead helper). 50× `MIDIDispatcher.invalidParamsResult` cross-dispatcher calls → canonical `toolInvalidParamsResult`; delete the re-export. StatePoller 5 poll* → generic `poll<T>`.
- AC5: NavigateDispatcher create_marker: fetch `beforeMarkers` BEFORE the mutating route (audit P1 #8 — currently after, making count-delta verify fragile→StateB even on success). Fixes toward reliability; still fail-closed.
- AC6: PluginsDispatcher `nonEmptyString` returns TRIMMED value (audit P2 #20 — contradicts doc, forwards padded input). DispatcherSupport `stringParam` gains the alias-conflict fail-closed check its int/double siblings have (audit P2 #21). StateModels MCUConnectionState/MCUDisplayState → Codable (audit P2 #25; removes ResourceHandlers hand-mapping). Projects: bounce-helper `/usr/bin/python3`→PATH-resolved (audit P2 #19), BOUNCE_HELPER env L1 ownership+location allowlist matching the library-inventory pattern (security L1), export batch-open dialog preflight (audit P2 #18).
- AC7: `swift test --no-parallel` green; golden-snapshot diff = 0 (all wire-preserving; INTENTIONAL non-abstraction — ProjectDispatcher:40-76 per-case audit gate, per-route 5-step guards — MUST be left as-is).

## 3. TDD / Verification
- SIGPIPE: new `SIGPIPERegressionTests` (broken-pipe write survives). RED first (or document the empirical proof and add the guard + test together — this is a crash-fix, flip-test by removing the guard confirms the test catches it).
- Golden snapshots: capture unknown-command/invalid-param error envelopes + resource URIs + route table BEFORE, diff = 0 AFTER (esp. the 50-site invalidParamsResult reroute and ResourceHandlers URI routing).
- record_sequence/create/toggle: existing tests green (pure move + helper extraction preserving strings).

## 4. Constraints
- Wire shapes byte-identical (error strings, envelopes, route selection, resource URIs). Verify the 50-site reroute produces identical output (both paths already go through `toolStateCResult(.invalidParams)`).
- Do NOT touch LogicProServer.swift (WS6) — including its mutation-gate `mutatingCommandsByTool`; the completeness TEST is WS8's.
- Commit per logical unit (SIGPIPE separate, splits separate, dedup separate) for reviewability.

## 5. Review Checklist
- [ ] SIGPIPE guard + regression test (flip-test proves it catches)
- [ ] ResourceHandlers 4-ext + record_sequence ext (pure moves)
- [ ] helper reroutes byte-identical (golden diff = 0)
- [ ] Projects/* changes (python3 PATH, BOUNCE_HELPER allowlist, dialog preflight)
- [ ] Full suite green; LogicProServer.swift + ResourceProvider.swift UNTOUCHED (git diff confirms)
