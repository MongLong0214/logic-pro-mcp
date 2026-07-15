# Work Board: #285 ADR-002-a — Session-scoped Stable Target Reference (target kinds)

**Epic / issue**: [#285](https://github.com/MongLong0214/logic-pro-mcp/issues/285) — ADR-002: Session-scoped Stable Target Reference (OPEN, `epic`, `priority: p0`)
**Program**: [#308](https://github.com/MongLong0214/logic-pro-mcp/issues/308) — Train A, first step
**Branch**: `feat/adr002a-target-kinds-20260715`
**Baseline head at directive time**: `11f0985` (integrated Train-A head)
**Increment status**: Code-complete on this branch. All four first-class target kinds are wired: `track_ref`, `mixer_strip_ref`, `plugin_insert_ref` (slice a), and `project_ref` + project-epoch lifecycle invalidation (slice b). The #268 automatic plugin-editor acquisition fix (slot-verified identity, fail-closed write) is committed at `40844ac`. `project_ref` is scoped to stable-target operations only (schema == runtime parity). Remaining before merge: the exact-head full-suite / release-build checkpoint and the real-Logic-12.3 live qualification gate (H) — see the ledger below.

> Authoritative ADR-002 status summary: `docs/adr/README.md` §"ADR-002 — Session-scoped Stable Target Reference". This board is the active acceptance surface for the current ADR-002-a increment.

---

## CTO DIRECTIVE (binding) — #268 pulled forward into #285 ADR-002-a acceptance

**#268 must not be omitted.** It is pulled forward into the current Train A first step (#285 ADR-002-a) acceptance. The GitHub issues (#268, #285) already carry the pull-forward ordering.

**Related issue**: [#268](https://github.com/MongLong0214/logic-pro-mcp/issues/268) — `set_param_verified` fails to acquire Compressor editor window on Logic Pro 12.3 (OPEN, `bug`, `priority: p1`). NOTE: the earlier `docs/tickets/issue-268-plugin-window-opener/` pipeline (PR #271, including `f3fc857`) did land and is an ancestor of current main, but it did not resolve the reopened Logic 12.3 environment-specific regression. The remaining correction is now owned by this ADR-002-a step.

### Canonical insertion (do not reorder)

1. Finish the currently running #285 ADR-002-a full-suite checkpoint.
2. Before the release build, fix #268 automatic plugin editor acquisition.
3. On the #285 final exact head, run in order: focused tests → full suite → release build → real Logic 12.3 live qualification → CTO exhaustive review → CEO exact-head production-readiness gate.
4. Never defer #268 until after #285, and never push it to the final current-main debt pass.
5. After #285/#268 is verified and merged, stop before #286 and close PR #367's remaining production-readiness debt (`LPMCP-PRD-001`): independent exact-artifact live qualification, the approved Desktop en/ko managed-fixture matrix, semantic operation coverage or explicit bounded waivers, mutation/readback/restore/compensation evidence, independent verification/provenance, published immutable evidence, CTO review, and CEO exact-head PASS. Only then advance to #286.

### Root-cause boundary (#268)

- Logic 12.3 / v3.10.0: with the plugin editor **closed**, `set_param_verified` returns State C `window_open_failed`.
- Manually pre-opening the editor makes the same call return State A.
- The write / readback / parameter / tolerance path is sound. The defect boundary is **automatic editor acquisition / the opener**.
- Investigate whether `requested_window_title: "set_param_verified"` incorrectly uses the operation name as the window identity.

### Blocking acceptance (all required)

- **A.** Closed-editor `set_param_verified` automatically opens the correct plugin editor and returns State A verified.
- **B.** Manual-preopen still returns State A.
- **C.** Wrong plugin, wrong parameter, and ambiguous/wrong window identity fail closed with State C, `write_attempted: false`, and zero wrong-target write.
- **D.** Acquisition failure is fail-closed zero-write, never classified as success.
- **E.** Focused RED→GREEN evidence: the reproduction fails before the fix and passes after.
- **F.** Final exact-head full suite PASS.
- **G.** Final exact-head release build PASS.
- **H.** Exact-SHA release-binary live QA on Logic 12.3: closed-editor → A, manual-preopen → A, negative/fail-closed → zero-write; raw transcript captured.
- **I.** CTO exhaustive review PASS, then request the CEO exact-head review with the evidence bundle. **No merge before CEO PASS.**
- **J.** Public-safe technical evidence and the gate verdict recorded in #268 / #285 / #308 and the PR. Never publish model / session / routing / effort / local-path metadata.

---

## Verification Ledger

| Gate | Acceptance | Evidence | Status |
|------|------------|----------|--------|
| Target-kind wiring (a) | — | `mixer_strip_ref` / `plugin_insert_ref` emit + resolve + wrong-kind/stale fail-closed; deterministic tests `ADR002ATargetKindTests` (11) | Deterministic PASS |
| project_ref + epoch (b) | — | `project_ref` emit + resolve; project open/new/save_as/close route through centralized `bumpProjectEpoch`; stale project/track/mixer/plugin refs → `stale_target_reference`; deterministic tests `ADR002BProjectTargetTests` (9) | Deterministic PASS |
| project_ref scoping parity | — | `project_ref` in `allowedParams` only for `.requiresStableTarget` ops; schema == runtime; `SagaSurfaceTests` / `OperationCatalogTests` restored | Deterministic PASS |
| #268 RED reproduction | E | closed-editor opener path failed pre-fix on the fake-AX tree | Deterministic PASS |
| #268 GREEN (code) | A, E | closed-editor → auto-open → State A on fake-AX tree; `PluginSetParamVerifiedLiveTests` | Deterministic PASS |
| #268 negative / fail-closed | C, D | wrong plugin / wrong param / ambiguous window → State C, `write_attempted:false`, zero write; window+slider identity re-verified immediately before the AX write | Deterministic PASS |
| Adversarial hardening | — | 3 review rounds converged: plugin-insert delimiter injection, resource + `get_inventory` emission TOCTOU, resolve→write use-time epoch race, and `save_as` flag-off invariance all closed; final adversarial pass returned PROCEED with no new blockers | Deterministic PASS |
| Final exact-head full suite | F | env-neutral CI green (2750 tests) — two Logic-coupled tests fail only under a live degraded Logic locally and pass with no Logic | CI green |
| Final exact-head release build | G | `swift build -c release` | PASS |
| #268 live A / B | A, B | closed-editor → A, manual-preopen → A on Logic 12.3 | **Pending healthy Logic (env)** |
| #268 live negative | H | negative/ambiguous → zero-write; raw transcript | **Pending healthy Logic (env)** |
| ADR-002 live continuity | — | project switch / restart → prior refs `stale_target_reference` on live | **Pending healthy Logic (env)** |
| CTO exhaustive review | I | full code review + 3 adversarial rounds converged | Code PASS (live-gated part pending H) |
| CEO exact-head gate | I | production-readiness PASS (no merge before this) | Pending report |
| Evidence recorded | J | public-safe notes on #268 / #285 / #308 / PR | In progress |

### External Logic UI edit boundary

Direct track reorder/delete and plugin-slot replacement in Logic's UI are bounded by the state-cache polling interval: fingerprint drift fails closed after the next poll, while a stale cache can match during that latency window. Server-mediated mutations bump the relevant generation immediately; verified track rename also updates the cache before rebind, while other topology writes rely on the next poll after invalidation. Live H must explicitly cover UI reorder followed by stale-ref mutation and require `stale_target_reference`; it is not a deterministic or live pass until that case is observed.

The resolver also performs a final registry recheck immediately before returning a resolved mutation target, including `project_ref` validation. A residual non-atomic window remains between that return and the live AX write because registry validation and the external AX write cannot be one atomic operation; live H must switch projects in that window and require fail-closed `stale_target_reference` rather than treating the registry check as a write lock.

### CTO live-qualification note

The deterministic (fake-AX / registry) acceptance for all four target kinds, the project-epoch
lifecycle, the `project_ref` scoping parity, and the #268 opener + fail-closed write path are
implemented and pass headlessly. The behaviour is gated behind an off-by-default feature flag, so
the merged code is byte-invariant in the default production configuration (flag-off invariance is
asserted).

The live gates **A / B / H** and the live project-switch/restart continuity check require an
authoritative real-Logic-12.3 session. At the time of this checkpoint the local Logic environment
is degraded (startup project chooser plus a stale state poller reporting zero tracks), which is a
known source of false live results — running the live qualification against it would produce
untrustworthy evidence. These gates are therefore held **pending a healthy Logic session** and will
be executed as a batch with a raw transcript once the environment recovers, before the flag is
enabled in any release. No live gate is marked passed without its transcript.

### CTO exact-artifact live-QA attempt + F1 hardening (2026-07-15)

Exact-SHA release-binary live QA (flag on) against the running Logic 12.3 session could not
complete the mutation gates: arrange track-header AX enumeration returned zero
(`logic_tracks.select {index:*}` → `element_not_found` for every index; `logic://tracks` →
placeholder/unknown rows with per-poll identity churn; health cache `track_count:0`). Consequently
`insert_verified` fails closed with `track_selection_failed`, `write_attempted:false` — a genuine
live fail-closed zero-write observation, but no State-A mutation gate can be exercised. The mixer AX
subtree **is** reachable (inventory reveal read a real occupied insert), isolating the fault to
arrange track selection. Recovery attempts (app activation, cache re-poll, mixer reveal, verified
display awake/unlocked, server-mediated track create; no sheet/modal on the window) did not restore
enumeration. This matches the documented "degraded Logic" hold, not a defect in this PR. **Release
condition:** a healthy Logic 12.3 session where `logic_tracks.select {index:0}` succeeds and
`logic://tracks` returns non-placeholder tracks with stable refs; the batch then runs on the
F1-hardened head with a raw transcript.

The CTO exhaustive exact-head review (security / privacy / fail-closed / wrong-target / ambiguity /
timeout / partial-state / evidence-integrity), corroborated by an independent adversarial pass,
found the gated code fail-closed and free of a net-new wrong-target write, with one finding elevated
to fix-before-completion:

- **F1 (MEDIUM, flag-ON):** the `target_ref` → `set_param_verified` / `insert_verified` write trusted
  the positional `track` index into live AX without asserting the live header name equals the
  reference's *bound* track name. Under a stale state cache after an out-of-band UI track reorder,
  a same-index/same-plugin collision could land a State-A write on the wrong track during the
  cache-latency window (the same window the "External Logic UI edit boundary" documents). **Fixed on
  this branch:** the bound track name is threaded down as `expected_track_name` and the live AX
  header is required to match (trimmed, exact) before any selection/write; a mismatch or unreadable
  live name fails closed `stale_target_reference`, `write_attempted:false`. This makes the live AX
  read authoritative over the cache and renders the live-H UI-reorder gate deterministic rather than
  poll-timing-dependent. Deterministic RED→GREEN coverage added
  (`testExpectedTrackNameMismatchFailsClosedStaleAndDoesNotWrite` + match/absent invariance).
- **F2 / F3 (LOW):** out-of-band project switch keeping non-project bindings alive, and
  `target_fingerprint` naming a since-changed plugin on an otherwise-correct write — the same
  undetectable out-of-band class / evidence-accuracy only. F1's live-name cross-check substantially
  mitigates F2. Documented residuals, not merge blockers.

Head changes from the F1 fix trigger a full re-run (focused → full suite → release build →
binary hash → live → security → CTO → CEO → CI) before the CEO exact-head gate. No merge before CEO PASS.

### Exact-head re-binding — F1 committed (2026-07-15)

The F1 hardening is committed on this branch as fix-before-completion, so the prior deterministic
evidence bundle bound to head `c7d0cfa` (focused 102/102, full/CI 2750, release artifact SHA-256
`34f51d3d…8319e2c818c86…`) is **INVALIDATED / SUPERSEDED** and re-run against the F1-inclusive head.
Deterministic re-run results on the F1 head:

- **Focused F1 (E, C, D, byte-invariance):** `testExpectedTrackNameMismatchFailsClosedStaleAndDoesNotWrite`
  + `testExpectedTrackNameMatchStillReachesStateA` + `testAbsentExpectedTrackNameIsByteInvariant` →
  3/3 GREEN. Mismatch fails closed `stale_target_reference`, `write_attempted:false`, slider unchanged
  (zero wrong-target write); match reaches State A; absent = byte-invariant State A.
- **Full suite (F):** 2753 tests (2750 baseline + 3 F1). The **only** local non-pass is the
  documented environment-coupled false-RED
  `LogicProServerHandlerTests.testLogicProServerHandlersReadResourcesWithoutRegisteredTransport` —
  it read 58 `placeholder:1`/`type:unknown` rows from the degraded live Logic session instead of the
  expected empty set (the same arrange-enumeration degradation the live-QA note documents). This test
  does not exercise F1 (verified-plugin write path); it is CI env-neutral GREEN and would fail
  identically pre-F1. The release-binary QA test is skipped pending the release build (expected).
- **Release build (G) + artifact SHA-256:** built from the F1 head; the exact SHA-256 is recorded in
  the PR #370 CTO gate comment (docs are binary-invariant).

The live gates (A/B/H, reorder→stale-ref, project switch/restart continuity, independent readback,
restore/compensation, raw transcript) remain **env-blocked** on the degraded Logic 12.3 session and
are held pending an approved/managed healthy fixture, per the release condition above. No merge
before CEO exact-head PASS.
