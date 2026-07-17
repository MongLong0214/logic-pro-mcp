# LPMCP-PRD-001 production-readiness remediation

## Scope

- Program: #308
- Owning ADR issue: #284
- Historical foundation PR: #367
- Remediation branch: `fix/adr001-production-readiness-20260716`
- Exact base: `cc5922e5c5c2786c401713fd80b1bd40d1e15f14`
- Blocked successor: #286

This slice closes the remaining release-qualification debt before the roadmap advances.

## Acceptance

The candidate is production-terminal only after all of the following are bound to one immutable commit:

1. The seven production-readiness contracts are proven RED on the exact base and GREEN on the candidate.
2. Current-source focused tests pass.
3. The exact candidate full suite passes.
4. A universal release artifact is built and its SHA-256 is recorded.
5. The exact artifact passes Logic Pro Desktop en-US and ko-KR qualification.
6. Mutation, independent readback, restore, wrong-target, ambiguity, timeout, and partial-state boundaries are verified.
7. Creator axes have live evidence or a bounded environment waiver.
8. Security, privacy, fail-closed, and evidence-integrity review passes.
9. Independent technical review and CEO exact-head review pass.
10. Exact-head PR CI passes.
11. Merge commit, post-merge main CI, and the completion receipt are verified.

Any missing or stale lane yields `QA_PENDING` and blocks merge and #286.

## Production-readiness contracts

- R-REL: release publication is blocked on independent qualification.
- R-SEM: each registered operation has semantic evidence or a governed release-visible waiver.
- R-MATRIX: Desktop and Creator en-US/ko-KR axes are explicit.
- R-MUT: mutation, readback, restore, and compensation evidence is required.
- R-PROV: trusted independent provenance is verified.
- R-PUB: immutable qualification evidence is published with the release.
- R-AUTH: this board binds the authority base and execution order.

## Current gate

The working candidate has passed focused tests, the full suite, universal build, Desktop/ko live mutation and fail-closed checks, and promotion verification. Those results must be rerun after the candidate is committed because commit identity is part of the qualification evidence.

No merge or successor work is allowed until the committed exact-head gate is complete.


---

## 33. CEO correction HEAD 8204877c — suite/mutation/promotion + CTO PASS (2026-07-16)

- Invalidated: cc5922e dirty-base CTO packets / suite eda1c7e6 (2777). See `evidence/CEO-CORRECTION-INVALIDATION-8204877.md`.
- HEAD: `8204877c2d66d11598ac5e7292d231fa42c8a8b3`
- Artifact: `8c3a525a89a6bbaaff09e362ea35aae8391243d9eff1221c1161aa58257262d6`
- Suite sealed: `exact-head-full-suite-8204877-sealed.log` SHA `44f236bf…` — 2779 PASS; raw log embeds HEAD + binary
- Desktop/ko mutation v3: PASS (ko-KR, M1 restore+readback, M2/M3 fail-closed)
- M4 partial inject qualify: write_attempted=false
- verify-promotion rerun: **promotable=true**
- CTO: `evidence/t1-cto-exact-head-review-8204877.md` — **PASS** draft-PR eligible
- Merge / #285 / #286: **BLOCKED**. Draft PR only.


---

## 34. CEO mandatory re-review PR #372 @ 7ac8812 — **FAIL** (2026-07-16)

- PR head binding: `7ac8812274320b4cc1c0738eab08f154ccc58a61` (not 8204877c)
- Diff: 1043 files, +120364/−20; **98.0%** generated_raw_evidence
- Prior CTO PASS on 8204877 evidence packet: **RETRACTED**
- Verdict: **FAIL** — `evidence/CEO-MANDATORY-REREVIEW-PR372-7ac8812.md`
- Blockers: exact-head mismatch; evidence bloat in git; blanket 109 waivers (known-limitation / 99.0.0); provenance step theater; axis verified weakening
- **No merge. No #286.**


---

## 35. CEO debate response — F4 corrected; FAIL retained (2026-07-16)

- F4 downgraded: Step A `--verify-promotion` + `provenanceRejection` Ed25519 is real; Step B `trusted-provenance-verify` is redundant/misleading marker only.
- F3 confirmed: 106 in-process waivers outside Creator-only LIVE_NA; evaluator closes missingSemantic on waiver presence.
- Mutation matrix: live restore path = `mixer.set_volume` only (1 op).
- F2 split: raw evidence = hygiene P1; acceptance needs head rebind not git bulk.
- F8 public diff: 5831 `/Users/isaac` matches; 0 private keys.
- Verdict remains **FAIL**. Evidence: `evidence/CEO-DEBATE-RESPONSE-PR372-7ac8812.md`.
- **No merge. No #286.**

---

## 36. Finalization under owner authority — blanket waivers removed, R-SEM opened (2026-07-17)

- Governance: the prior independent-review lane is no longer available; the repository owner directed finalization. Merge gating moved to the mechanical branch ruleset: PR required + required `build` status check (strict), force-push/deletion blocked, no bypass actors. Direct push to `main` remains rejected (verified earlier, GH013).
- B0 closed honestly: all 106 blanket `known-limitation` waivers REMOVED (`.github/qualification/waivers.json` → `[]`). Blanket coverage-by-waiver is forbidden by test (`waivers.isEmpty`); any future waiver must be individually governed with a bounded expiry.
- **R-SEM (semantic coverage) is an OPEN, tracked debt**: only `system.health` has a semantic validator. The aggregate contract test now pins `openDebts == [R-SEM]` exactly — any other debt opening fails CI, and closing R-SEM forces the assertion flip.
- Release consequence (intended): `PromotionGate` rejects every uncovered operation (`requiredOperationNotSatisfied`) — no release promotes until the coverage program (A:20 read-only → B:51 safe-mutation → C-live:35 disposable-fixture) lands real evidence. Tracked in the successor issue.
- step-4 ops landed with verified State-A readback after an adversarial hardening round (wrong-target selection, marker identity continuity, two-phase cancel journal, write-boundary cancellation recheck). `transport.set_cycle_range` remains a documented Logic 12 platform wall (typed State C).
- Base SHA pin unchanged: cc5922e5c5c2786c401713fd80b1bd40d1e15f14.

---

## 37. Contract self-attestation removed — R-MATRIX and R-PUB re-opened honestly (2026-07-17)

- An independent receipt audit found the R-MATRIX and R-PUB repository contracts closing on **workflow text**, not reality: an `echo "required-matrix-axes:4"` marker satisfied R-MATRIX while no managed fixture exists, and listing release assets satisfied R-PUB while GitHub release assets remain owner-replaceable (no immutable/transparency-bound publication). Same self-attestation class this remediation purged elsewhere.
- Fixed: R-MATRIX now additionally requires managed fixtures to exist as **content** (a fixture manifest whose entries carry relative paths + 64-hex SHA-256 and whose files exist — `Fixtures/qualification/fixture-manifest.json`); R-PUB now opens whenever no immutability mechanism exists, regardless of the asset list (the list only refines the finding detail).
- The aggregate contract bar now pins **three** open debts exactly: `R-MATRIX`, `R-PUB`, `R-SEM`. Any other debt opening fails CI; closing any of the three forces the honest assertion flip.
- Closure paths: R-MATRIX — author + SHA-bind the managed empty/medium/large fixtures (wiring these SHAs into an attestation fixture-SHA field is deferred until that field exists); R-PUB — establish a non-replaceable/transparency-bound evidence publication; R-SEM — #373 coverage program.

---

## 38. Qualification matrix reduced to desktop-only ship scope (2026-07-17)

- Owner product decision: Logic Pro Creator Studio (`com.apple.mobilelogic`) is permanently out of scope — never installed, never supported. Desktop Logic Pro is the only ship surface.
- Modeling (grok-reviewed, Option A): the required same-artifact matrix is derived from an explicit `QualificationAxis.shipVariants = [.desktop]` allowlist → `desktop × {en-US, ko-KR}` = 2 required axes. Creator is NOT expressed as a perpetual waiver (waivers are for temporary inability on ship claims, never product scope). The `LogicVariant.creatorStudio` case remains as world-model/health-reporting truth; a contract test pins the exact 2-axis set so a variant re-entering or a locale dropping fails CI. Release workflow marker updated to `required-matrix-axes:2`.
- Consequence: the ADR-001 live matrix is now 2 axes (desktop en/ko), both live-bound. PRD-020 (non-EN plugin-editor blocking) is the current blocker for the ko axis.

---

## 39. R-MATRIX repository-content half closed — managed fixtures SHA-bound (2026-07-18)

- Scope closed (honest, exact): the **repository-content half** of R-MATRIX. Managed desktop x {en-US, ko-KR} fixture descriptors now exist under `Fixtures/qualification/` (empty/medium/large sizes), and `fixture-manifest.json` SHA-256-binds each one. The closer `ProductionReadinessContractEvaluator.managedFixturesPresent` was hardened to recompute every fixture's SHA-256 and require digest equality **and** to require that every ship-required axis key (`QualificationAxis.requiredCombinations` = desktop x {en-US, ko-KR}, empty) is covered by a fixture whose SHA-bound descriptor declares that key. Any byte drift, missing file, malformed digest, unsafe path, or missing required axis fails closed, keeping R-MATRIX OPEN — the contract itself, not a side test, now guarantees identity + coverage.
- NOT claimed: a live/consumed matrix load. These files are canonical, reproducible fixture **descriptors** (a consumer that drives them through a live Logic Pro session does not exist yet). Driving them end-to-end belongs to the ADR-001 live-matrix program, not to this repository-content debt; nothing here implies it is done.
- Aggregate contract bar now pins **two** open debts exactly: `R-PUB`, `R-SEM`. `productionReadinessContractsAreSatisfiedOnCurrentTree` flips accordingly; closing either remaining debt forces the next honest flip.
- Base SHA pin unchanged: cc5922e5c5c2786c401713fd80b1bd40d1e15f14.
