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
| Final exact-head full suite | F | `swift test --no-parallel` — env-neutral CI is authoritative | CI pending on final head |
| Final exact-head release build | G | `swift build -c release` | Pending exact-head confirm |
| #268 live A / B | A, B | closed-editor → A, manual-preopen → A on Logic 12.3 | **Pending healthy Logic (env)** |
| #268 live negative | H | negative/ambiguous → zero-write; raw transcript | **Pending healthy Logic (env)** |
| ADR-002 live continuity | — | project switch / restart → prior refs `stale_target_reference` on live | **Pending healthy Logic (env)** |
| CTO exhaustive review | I | code-side verdict + evidence bundle | Code PASS (live-gated part pending H) |
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
