# Work Board: #285 ADR-002-a — Session-scoped Stable Target Reference (target kinds)

**Epic / issue**: [#285](https://github.com/MongLong0214/logic-pro-mcp/issues/285) — ADR-002: Session-scoped Stable Target Reference (OPEN, `epic`, `priority: p0`)
**Program**: [#308](https://github.com/MongLong0214/logic-pro-mcp/issues/308) — Train A, first step
**Branch**: `feat/adr002a-target-kinds-20260715`
**Baseline head at directive time**: `11f0985` (integrated Train-A head)
**Increment status**: In implementation — the ADR-002-a target-kind slice (first-class `mixer_strip_ref` / `plugin_insert_ref` target kinds + topology invalidation + the plugin-insert target-reference helper) is committed at head `2f9fbb9` on this branch. Remaining before release: finish the full-suite checkpoint, then the #268 automatic plugin-editor acquisition fix and the blocking acceptance gates below. The #268 fix is NOT yet in this branch.

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

## Verification Ledger (to be filled by the implementation worker)

| Gate | Acceptance | Evidence | Status |
|------|------------|----------|--------|
| ADR-002-a full-suite checkpoint | (step 1) | | Pending |
| #268 RED reproduction | E | closed-editor `set_param_verified` → State C `window_open_failed` before fix | Pending |
| #268 GREEN | A, E | closed-editor → State A verified after fix | Pending |
| Manual-preopen unchanged | B | State A | Pending |
| Negative / fail-closed | C, D | wrong plugin / wrong param / wrong-or-ambiguous window → State C, `write_attempted:false`, zero write | Pending |
| Final exact-head full suite | F | `swift test --no-parallel` PASS | Pending |
| Final exact-head release build | G | `swift build -c release` PASS | Pending |
| Exact-SHA live QA (Logic 12.3) | H | raw transcript: closed→A, preopen→A, negative→zero-write | Pending |
| CTO exhaustive review | I | verdict + evidence bundle | Pending |
| CEO exact-head gate | I | production-readiness PASS (no merge before this) | Pending |
| Evidence recorded | J | public-safe notes on #268 / #285 / #308 / PR | Pending |

**Continue canonical work without stopping.** Return only receipt/evidence to the CTO; do not claim implementation complete before the gates above are green.
