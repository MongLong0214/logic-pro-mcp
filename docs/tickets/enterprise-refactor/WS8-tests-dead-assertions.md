# WS8: Test integrity — ~356 dead-assertion sweep + coverage gaps (PHASE 2, after Phase-1 merges)

**PRD**: G4, §3.2 WS8, §5.3, §4 E2/E3
**Priority**: P1 | **Size**: L (mechanical volume high) | **Risk**: M (wrong transform can mask a real regression)
**Owns (EXCLUSIVE)**: EXISTING `Tests/*` + `docs/tickets/enterprise-refactor/DEAD-ASSERTION-LEDGER.md`, EXCLUDING the 7 Phase-1-created test files (SIGPIPERegressionTests, MCUFeedbackOrderingTests, MIDIFeedbackStatusByteTests, ExtractTrackStateHonestyTests, AXHelpersDowncastGuardTests, PermissionCheckerTriStateTests, SMFWriterDenominatorTests — those are owned by their WS and already follow the assertion rules). Runs ONLY after Phase-1 (WS1-7) is merged + green.
**Depends on**: WS1-7 merged.
**Structure (boomer ticket-R1 #5)**: 3 sub-units run SEQUENTIALLY by ONE agent (NOT parallel — test files cross-cut). Order: **WS8c → WS8a → WS8b**, full-suite green + commit after each.
- **WS8c** (first): FakeAXRuntimeBuilder AX-helper promotion (into AccessibilityTestSupport.swift) + JSON-helper clone removal (→ sharedToolText/sharedJSONObject). First, so shared helpers exist before the assertion sweep edits the same files.
- **WS8a** (second): the ~356 dead-assertion sweep + LEDGER + safety-critical flip-tests (AC1-AC4 below).
- **WS8b** (third): new safety coverage in NEW files (AC5).

## 1. Objective
Make the test suite actually assert. The `#expect` macro is DEAD (always-pass) whenever both operands are statically `Bool`/`Bool?` (empirically proven twice at Swift 6.2.4) — ~356 such assertions exist, including safety-critical fail-closed/honesty guards. Convert each to a live form with the correct optionality-dependent transform; add the two missing safety-critical test suites.

## 2. Acceptance Criteria
- AC1: ALL ~356 dead forms (`==true`/`==false`/`?? false`/`.some`/`!= true`/`boolVar==boolVar`) converted to live assertions. A **LEDGER** (committed as `docs/tickets/enterprise-refactor/DEAD-ASSERTION-LEDGER.md`) records every one: file:line, original expr, static type of LHS, nil-semantics rule applied, replacement.
- AC2: Transforms per §5.3 (NOT global sed):
  1. non-optional Bool: `x==true`→`#expect(x)`; `x==false`→`#expect(!x)`
  2. optional via `as? Bool`: `#expect((o["k"] as? Bool)!)` (a nil crash IS a real finding — investigate, don't paper)
  3. optional where nil should FAIL (verified/exists/selectionRestored): `#expect(x!)`
  4. optional where nil is VALID success (result.isError): bind `let e = x ?? false; #expect(e)`/`#expect(!e)` — NEVER force-unwrap, NEVER `?? false` in the #expect (also dead)
  5. tautologies `X==true || X==false`: delete or replace with a real assertion
- AC3: **Flip/fault-injection proof** for every safety-critical file (Issue136GotoDriftHonestTests:115, PluginInsertVerifiedTests:581/594/642, AXPluginInsertSlotsDriftTests:95/146, DispatcherTests:1117/1178/2978 success-guards): temporarily break the guarded behavior, confirm the NOW-live assertion FAILS, revert. Record the flip-test result in the ledger.
- AC4: Any assertion that goes RED when made live = a latent bug surfaced (E2) — STOP, report to orchestrator, do NOT paper over. (Expected mostly-green since the guarded behaviors are correct; the assertions just weren't checking.)
- AC5 (WS8b, new files): `MutationGateCompletenessTests` (per-tool: every command each dispatcher's `switch` accepts is EITHER in LogicProServer `mutatingCommandsByTool` OR on an explicit read-only allowlist — mirror validHelpCategories lockstep at SystemDispatcher:276; read-only test, no source edit); `BoundedProcessRunnerTests` (SIGTERM-ignoring child→prove SIGKILL; >64KB stdout→no pipe deadlock; timeout→.timedOut; normal→.completed); `StateModelsCodableTests` round-trip (wire-format lock). SIGPIPE regression is WS4-owned (SIGPIPERegressionTests) — WS8b does NOT duplicate it.
- AC6: FakeAXRuntimeBuilder AX helpers promoted (audit/round-1: axPoint/axSize/setFrame/setRole/setNamedContainer/setButton from Mixer123FixtureSupport → onto FakeAXRuntimeBuilder in AccessibilityTestSupport; collapses 1248 setAttribute/391 kAXRole spellings). JSON-helper clones (~20 files) → sharedToolText/sharedJSONObject (fixes the `.resource` envelope drift).
- AC7: `swift test --no-parallel` green (baseline post-Phase-1 + new tests). Test count RE-COUNTED for docs (WS9).

## 3. Verification
The suite green is necessary but NOT sufficient (a wrong transform can pass). The LEDGER + AC3 flip-tests are the real gate. Orchestrator spot-audits a random 10% of ledger entries against the transform rules.

## 4. Constraints
- Do NOT modify production Sources (WS8 is tests-only). If a test can only be made live by changing production behavior, that's a WS1-7 concern — report, don't cross the boundary.
- Do NOT edit the 7 Phase-1-created test files (single-owner rule).
- Preserve test intent: transform changes HOW it asserts, never WHAT scenario it covers.
- Batch commits by sub-unit (8c/8a/8b) with the ledger updated per batch.

## 5. Review Checklist
- [ ] WS8c: FakeAX helper promotion + JSON clone removal (done first); suite green
- [ ] WS8a: LEDGER complete (~356 entries, all 5 transform types); safety-critical flip-tested (documented FAIL-when-broken); any newly-RED assertion escalated (not papered)
- [ ] WS8b: mutation-gate completeness + BoundedProcessRunner + StateModels-Codable tests added & green (new files)
- [ ] Full suite green; production Sources untouched (git diff = Tests/ + DEAD-ASSERTION-LEDGER.md only); Phase-1 test files untouched
