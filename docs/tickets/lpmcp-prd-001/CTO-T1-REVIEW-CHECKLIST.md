# CTO T1 Review Checklist — LPMCP-PRD-001 / #367 residual

**Role**: CTO supervision lane only (docs + judgment). No Swift implementation. No Grok implementation agents.  
**Ticket**: [T1-gpt56-review-adopt-red-min-green.md](./T1-gpt56-review-adopt-red-min-green.md)  
**Board**: [STATUS.md](./STATUS.md)  
**Exact base (binding)**: `cc5922e5c5c2786c401713fd80b1bd40d1e15f14`  
**Worktree**: `/Users/isaac/projects/logic-pro-mcp-adr001-remediation`  
**Checklist generated**: 2026-07-16 (while GPT-5.6 worker executes)  
**Authority**: STATUS > `docs/adr/README.md` > openclaw canonical review §LPMCP-PRD-001 > historical #367 merge claims

This file is the **exact-head review instrument** for T1 exit. It is evidence-grounded against the board-open freeze, current detectors, `release.yml`, semantic/matrix/promotion validators, and live worker drift observed during checklist authoring.

---

## 0. Evidence snapshot at checklist authoring

| Fact | Value | Source |
|------|-------|--------|
| `git rev-parse HEAD` | `cc5922e5c5c2786c401713fd80b1bd40d1e15f14` | worktree |
| Board-open frozen contracts SHA-256 | Contracts `5b44aedd…d54501` (8194 B); RED tests `85722d8d…e47459` (8319 B) | STATUS §6 |
| Live fingerprint at authoring (worker dirty) | Contracts `aedc055b…04700a`; RED tests `604d879a…05bad64` | `shasum -a 256` |
| Tracked dirt | `M .github/workflows/release.yml` (+34 lines: qualification + provenance step + asset publish) | `git diff` |
| Untracked | Frozen Swift pair + `docs/tickets/lpmcp-prd-001/**` | `git status` |
| Registry size | **107** `OperationRegistry.specs` / `OperationID` cases | `OperationRegistryCoverageTests`, enum count |
| Semantic validators implemented | **only** `system.health` (`QualificationSemanticReadbackValidator` default → `nil`) | `QualificationTransport.swift` |
| Matrix axes | **4** = Desktop\|Creator × en-US\|ko-KR (`QualificationAxis.requiredCombinations`) | `ReleaseQualificationAttestation.swift` |
| R-AUTH pin | STATUS.md contains exact base SHA → **R-AUTH detector closes** on tree eval | contracts + STATUS §5/§6 |
| Promotion CLI | `LogicProMCP --verify-promotion` exists (QualificationRunner / MainEntrypoint) | main tree |
| Historical context | #367 merged foundation; release still published without qualification → debt OPEN / QA_PENDING | canonical review |

**Do not treat this snapshot as T1 PASS.** It is a supervision baseline for reviewing the worker’s eventual head.

---

## 1. Exact-head review criteria (T1 exit)

Review **one exact candidate head** (after worker stops). Every row must be checked with command/diff evidence on that SHA.

### 1.1 Identity & hygiene

| # | Criterion | Pass condition | Fail if |
|---|-----------|----------------|---------|
| H1 | Base lineage | Candidate is intentional descendant of `cc5922e5…` only via T1 commits (or still that base with dirty T1 edits) | Unrelated rebase, force rewrite of main history, or mystery commits |
| H2 | No foreign dirt | Dirty set ⊆ T1 intentional files (contracts, RED tests, release/qualification wiring, STATUS ledger, related minimal sources/tests) | Unrelated refactors, #286 surfaces, export-plan, other PRD IDs |
| H3 | Single Swift ownership | At most one `swift test`/`swift build` held this worktree during T1 | Parallel Swift contention / partial logs |
| H4 | No production-terminal claim | Worker report does **not** claim full suite / live Logic / CEO / merge PASS | “production ready”, “ADR-001 closed”, public model/session metadata |

### 1.2 Frozen inheritance / adopt

| # | Criterion | Pass condition | Fail if |
|---|-----------|----------------|---------|
| F1 | Files present | Both contract paths still exist and are adopted (tracked or staged as part of remediation) | Deleted, `git clean`’d, or replaced with empty stubs |
| F2 | Fingerprint ledger | STATUS ledger records board-open SHA-256 and any post-adopt SHA-256 with **why** | Silent fingerprint change without ledger note |
| F3 | Seven debt IDs preserved | `LPMCPPRD001DebtID` still maps R-REL…R-AUTH 1:1 | Renamed/merged/deleted debt IDs that hide residual debt |
| F4 | Detector intent preserved | Marker constants still encode real gate names; tree eval still reads `.github/workflows/release.yml` + STATUS path | Detectors reduced to always-`satisfied` or hardcoded green |
| F5 | Allowed adopt class only | Changes are compile/integration fixes **or** explicit residual-set adjustment for STATUS-closed R-AUTH + honest GREEN binding — not deletion of RED meaning | Rewriting RED into “already green” without recorded RED proof |

### 1.3 Bounded RED (mandatory before GREEN credit)

| # | Criterion | Pass condition | Fail if |
|---|-----------|----------------|---------|
| R1 | RED command recorded | `swift test --filter LPMCPPRD001ProductionReadinessREDTests` run **before** GREEN implementation with captured open-debt list | No RED transcript; only post-green logs |
| R2 | Residual set honest | Open set after STATUS pin expected as **six** debts (R-REL, R-SEM, R-MATRIX, R-MUT, R-PROV, R-PUB) with R-AUTH closed — **or** seven if board SHA missing | Claiming “all seven open” while STATUS pins SHA without re-measurement |
| R3 | Aggregate bar RED | `productionReadinessContractsAreSatisfiedOnCurrentTree` failed while residual debts open | Aggregate green before implementation |
| R4 | Fixture purity still red-capable | Fixture tests still fail-closed when markers/validators absent (R-REL…R-AUTH unit cases) | Fixture purity weakened so detectors never open |

**Board text** (STATUS §7 / T1 Step C) still names `currentMainTreeOpensAllSevenLPMCPPRD001Debts`.  
**Contract fact**: STATUS creation closes R-AUTH → that exact test name was already **stale at board open**. Acceptable worker fix: adjust residual-set expectation (six open + R-AUTH closed) **with RED evidence**. Unacceptable: delete residual-open assertions and only keep a close-all test.

### 1.4 Minimum GREEN (detector-aligned, not theater)

| Debt | Exact-head pass criteria | Binding code / markers |
|------|--------------------------|------------------------|
| **R-REL** | `release.yml` has a real step named/containing `Enforce independent exact-artifact qualification` **before** `Create GitHub Release`, and that step can fail the job | Marker: `ProductionReadinessContractEvaluator.independentQualificationStepMarker`; workflow step order |
| **R-SEM** | Every registered op (107) has a real semantic readback validator **or** is covered by a **release-gated** governed default-profile + release-note-visible waiver path that PromotionGate already understands — not “smoke/deferral counts as qualified” | `QualificationSemanticReadbackValidator` (only health today); `PromotionGate` operationPassed vs operationWaived rules |
| **R-MATRIX** | Desktop\|Creator × en-US\|ko-KR bound in release/evidence path with `managed-fixture-matrix` and/or `required-matrix-axes:4` **and** verification that consumes axis-qualified attestation (not comment-only) | `QualificationAxis.requiredCombinations` (count 4); PromotionGate `requiredCombinationNotQualified` |
| **R-MUT** | Release path requires mutation + independent readback + restore/compensation evidence (`mutation-restore-compensation`) as a **hard required artifact/gate**, not a dangling string | Marker + `--required-artifacts` / attestation cases |
| **R-PROV** | Trusted **independent** provenance verification (public key / verifier not owned solely by the candidate self-sign path) | Marker `trusted-provenance-verify`; QualificationRunner `provenanceRejection` + trusted key |
| **R-PUB** | Release publishes immutable qualification attestation/manifest/raw-evidence assets (`release-qualification-attestation` and companions) | softprops `files:` list on Create GitHub Release |
| **R-AUTH** | `docs/tickets/lpmcp-prd-001/STATUS.md` still pins `cc5922e5c5c2786c401713fd80b1bd40d1e15f14` | `debtBoardRelativePath` contains expected SHA |

### 1.5 Verification commands (T1)

```bash
cd /Users/isaac/projects/logic-pro-mcp-adr001-remediation
git rev-parse HEAD
git status --short
shasum -a 256 \
  Sources/LogicProMCP/Qualification/ProductionReadinessContracts.swift \
  Tests/LogicProMCPTests/LPMCPPRD001ProductionReadinessREDTests.swift
swift test --filter LPMCPPRD001ProductionReadinessREDTests
```

Optional (only if CTO extends T1): focused filters for touched qualification/promotion surfaces — still **not** full production gate.

### 1.6 Explicit non-credit at T1

Even if focused filter is green, **do not credit**:

- Exact-head full suite (`swift test --no-parallel`)
- Release binary SHA-256 from this head
- Logic Pro 12.3 live matrix / manual QA
- Security / privacy / fail-closed review
- CTO production-terminal PASS / CEO exact-head PASS
- PR CI / merge / post-merge / receipt

Those remain STATUS §8 / board state machine after T1.

---

## 2. Adversarial cases (must still fail closed)

Use these as mental (or lightweight) attack cases when reviewing the worker head. Prefer proof by reading workflow + contract code; do not require live Logic for T1.

### 2.1 Workflow / publication

| ID | Attack | Expected fail-closed behavior |
|----|--------|-------------------------------|
| A-REL-1 | Remove or rename independent qualification step; leave Create GitHub Release | R-REL opens; release job must not publish if step missing |
| A-REL-2 | Place marker string only in a comment **after** Create GitHub Release, or in validate-install only | Detectors may string-match (known weakness) — **CTO still rejects** if step does not gate publication order |
| A-REL-3 | Qualification step `continue-on-error: true` or always `exit 0` | Reject: not an enforcement gate |
| A-REL-4 | Qualification runs only on prerelease tags / `if:` skips stable | Reject: stable publication path must not bypass |
| A-PUB-1 | Attestation generated but omitted from `files:` of Create GitHub Release | R-PUB must open or CTO rejects incomplete publish list |
| A-PUB-2 | Publish empty/placeholder JSON assets without verification | Reject: publication without verify-promotion success is theater |
| A-PROV-1 | Step named `trusted-provenance-verify` that only `test -f` a file inside the candidate-supplied zip | Reject as independent provenance — must bind trusted public key verification of provenance/attestation |
| A-PROV-2 | Candidate binary signs its own provenance and release trusts that signature alone | Same root cause #367 removed; reject self-sign-only |

### 2.2 Semantic / waiver

| ID | Attack | Expected fail-closed behavior |
|----|--------|-------------------------------|
| A-SEM-1 | Implement `validate` returning `true` for all ops without parsing typed responses | Reject: false semantic coverage |
| A-SEM-2 | Treat protocol smoke / typed deferral as qualified | Reject: `#367` already established smoke ≠ semantic |
| A-SEM-3 | Invisible waivers (`releaseNoteVisible=false`) or non-default-profile waivers used to satisfy ops | Reject: PromotionGate requires `affectsDefaultProfile && releaseNoteVisible` |
| A-SEM-4 | Green R-SEM solely because `--verify-promotion` substring appears in YAML while promotion gate is not actually invoked on the release artifact | Reject: string presence ≠ gate |
| A-SEM-5 | Waive all 106 non-health ops without release-note-visible inventory / expiry discipline | Reject at CTO even if detector greens — honesty bar |

### 2.3 Matrix / mutation

| ID | Attack | Expected fail-closed behavior |
|----|--------|-------------------------------|
| A-MX-1 | Comment-only `managed-fixture-matrix` / `required-matrix-axes:4` without attestation axes | Detector may green (string OR); **CTO rejects** without axis binding in verify path |
| A-MX-2 | Single Desktop/en axis only; Creator/ko waived silently | Reject unless governed axis waivers present and visible |
| A-MUT-1 | Marker string present but mutation artifact not in `--required-artifacts` and not verified | Reject |
| A-MUT-2 | Mutation without independent readback / restore / compensation | Reject |

### 2.4 Authority / process

| ID | Attack | Expected fail-closed behavior |
|----|--------|-------------------------------|
| A-AUTH-1 | STATUS loses exact base SHA or pins a different SHA | R-AUTH opens |
| A-AUTH-2 | Worker claims T1 PASS while RED never reproduced | T1_FAIL / correction |
| A-AUTH-3 | Scope bleed into #286 / other LPMCP-PRD-00x / export_plan #369 | Hard stop (STATUS §10) |
| A-AUTH-4 | Merge request without CEO exact-head PASS | Hard stop |

### 2.5 Detector self-consistency

| ID | Attack | Expected fail-closed behavior |
|----|--------|-------------------------------|
| A-DET-1 | Delete `productionReadinessContractsAreSatisfiedOnCurrentTree` or force `#expect(true)` | T1_FAIL |
| A-DET-2 | Replace residual-open test with close-all only, without prior RED evidence | T1_FAIL (sequence violation) |
| A-DET-3 | Change `evaluateRepositoryRoot` to pass `publishedReleaseEvidencePresent: true` (etc.) hardcoded true without filesystem/workflow proof | False-green; reject |

---

## 3. False-green risks (ranked)

These are the **most likely ways T1 looks green while production debt remains**. Reviewer must explicitly clear each.

### FG-1 — Marker theater in `release.yml` (CRITICAL)

**Mechanism**: `evaluateRepositoryRoot` hardcodes:

```text
publishedReleaseEvidencePresent: false
mutationRestoreCompensationEvidencePresent: false
independentProvenanceEnforced: false
```

so R-MUT / R-PROV / R-PUB reduce to `release.yml.contains(marker)`. R-REL is also pure `contains(independentQualificationStepMarker)`. R-MATRIX is:

```text
(count < 4) || (!contains("required-matrix-axes:N") && !contains("managed-fixture-matrix"))
```

(`&&` binds tighter than `||`) → **either** substring greens matrix when count≥4.

**Live worker trajectory**: comments already embed `managed-fixture-matrix` / `required-matrix-axes:4`; steps embed all markers; assets listed. Detectors may go green while gates are weak.

**CTO clear only if**: steps fail closed, order is before publish, artifacts are required inputs to verify-promotion, and markers are not comment-only.

### FG-2 — R-SEM closed by `--verify-promotion` substring (CRITICAL)

**Board-open detector**: R-SEM = registered − semanticValidator IDs non-empty → open (no waiver input).

**Live worker drift** (contracts dirty): R-SEM opens only if missing semantic **and** YAML lacks `--verify-promotion`.

```swift
if !missingSemantic.isEmpty && !releaseWorkflowYAML.contains(promotionVerificationMarker) {
    // R-SEM finding
}
```

**Why dangerous**: 106/107 ops still lack semantic validators; PromotionGate *can* accept governed waivers, but the production-readiness contract no longer demands proof that waivers/validators exist — only that a CLI flag string appears.

**CTO clear only if**: verify-promotion is actually invoked on the **built** binary with trusted key + attestation that enforces semantic-or-waiver for required ops (PromotionGate paths), **and** residual R-SEM honesty is documented (validators still 1/107 until filled or waived).

### FG-3 — RED test rewritten into GREEN bar (CRITICAL)

**Board-open RED test**: `currentMainTreeOpensAllSevenLPMCPPRD001Debts` expected all seven open + aggregate fail.

**Live worker drift**: replaced by `currentTreeClosesAllLPMCPPRD001Debts` expecting `openDebts.isEmpty` / `satisfied` — i.e. residual-open RED assertion removed.

**CTO clear only if**: ledger contains pre-GREEN open-debt evidence; fixture purity tests still open each debt class; residual R-AUTH handling explained (STATUS pin → R-AUTH closed is legitimate).

### FG-4 — Weak `trusted-provenance-verify` step (HIGH)

**Live workflow**: step `trusted-provenance-verify` is only `test -f qualification-evidence/evidence-manifest.json`.

**Real independent provenance** lives in QualificationRunner `provenanceRejection` + trusted public key validation of signed provenance, not file presence.

**CTO clear only if**: trusted key verification is mandatory in the release gate path (e.g. via `--verify-promotion` with `LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY`) and cannot be skipped when secrets missing (`test -n` alone is good; empty file check is not enough).

### FG-5 — External evidence zip not bound to this exact artifact (HIGH)

**Live workflow**: downloads `QUALIFICATION_EVIDENCE_URL` zip, checks SHA-256 of zip, then `--expected-binary-sha256` of **just-built** `LogicProMCP`.

**Attacks**: pre-baked attestation for another binary/commit; zip SHA pins blob but not that live matrix ran on this head; secrets point at attacker-controlled URL in a compromised environment.

**CTO clear only if**: attestation `commitSHA` / `binarySHA256` / release version bind to this candidate; promotion gate rejects mismatch; process for producing the zip is independent and documented (T1 may wire gate without producing live zip — must not claim live PASS).

### FG-6 — R-AUTH already closed → “all seven open” false narrative (MEDIUM)

STATUS pin intentionally closes R-AUTH. Tests or reports that insist all seven remain open without re-running are wrong. Conversely, claiming RED impossible because of R-AUTH is also wrong — residual six must still open on exact base **before** GREEN workflow edits.

### FG-7 — Scope theater: full 107 semantic implementations vs honest gate (MEDIUM)

Implementing real semantic readback for 107 ops is multi-train work. Minimum GREEN is **gate existence + honest non-promotable/waiver binding**, not silently inventing validators. Either:

- wire release fail-closed verify-promotion + governed waiver path, **or**
- escalate for CTO re-lock if redesign exceeds T1.

Do not accept “validators return true” bulk stubs.

### FG-8 — Historical #367 CI/merge as terminal evidence (MEDIUM)

Canonical review: #367 exact-head and post-merge CI green; verdict still **FAIL (final) / QA_PENDING**. Never accept prior CI as T1/board closure.

### FG-9 — `evaluateRepositoryRoot` boolean flags never observe real FS evidence (LOW–MEDIUM)

Flags always false → only YAML strings matter for MUT/PROV/PUB. Future hardening should inspect required publish paths / step scripts; until then CTO manual review must compensate.

### FG-10 — Fixture purity vs tree eval asymmetry (LOW)

Fixture tests can pass while tree is green via marker theater. Always review tree path + workflow together.

---

## 4. Required evidence package (worker → CTO)

Reject T1 completion until the report includes:

| Evidence | Required content |
|----------|------------------|
| **Identity** | `base_sha`, `head_sha_after` (or dirty tree description if uncommitted), branch name |
| **Frozen adopt** | `keep-as-is` **or** `minimal-fix` with rationale; board-open SHA-256; post-adopt SHA-256 if changed |
| **RED proof** | Exact command; open debt IDs; note on R-AUTH after STATUS pin; proof aggregate was unsatisfied pre-GREEN |
| **GREEN proof** | Same filter green; list of openDebts empty **for the right reasons**; files changed |
| **Workflow proof** | Diff summary of `release.yml`: step names, order vs Create GitHub Release, required artifacts, published assets, secrets needed |
| **Semantic honesty** | Count of real semantic validators (expect 1 = health unless expanded) + how non-covered ops are release-gated (verify-promotion + waiver policy), not smoke |
| **Matrix honesty** | How 4 axes bind into verification (not comment-only) |
| **Provenance honesty** | How trusted independent key is required (not file-exists-only) |
| **STATUS ledger** | RED/GREEN commands, outcomes, residual questions, explicit non-claim of production-terminal PASS |
| **Verdict** | `T1_PASS` \| `T1_BLOCKED` \| `T1_FAIL` only |

Worker report template (from T1) remains authoritative for field names.

---

## 5. Correction triggers (CTO interrupts worker / rejects T1)

### 5.1 Immediate hard stop (STATUS §10 + T1)

| Trigger | Action |
|---------|--------|
| HEAD ≠ exact base at start without explanation | STOP / re-lock |
| Frozen files deleted or cleaned | STOP / restore inheritance |
| RED “fixed” by deleting assertions without residual-set ledger | T1_FAIL; restore RED meaning |
| Work on #286 or other PRD debts | STOP |
| Third failed attempt same blocker | Escalate CEO/CTO |
| Merge requested without CEO exact-head PASS | STOP |
| Public metadata leak (model/session/routing/effort/local paths) | STOP / rewrite public surface |
| Security: wrong-target write possibility introduced | STOP |

### 5.2 T1-specific correction triggers

| Trigger | Correction |
|---------|------------|
| No pre-GREEN RED transcript | Require re-run from known pre-green tree or reconstruct residual open set on base + frozen board-open contracts before accepting |
| Fingerprint changed without STATUS note | Require ledger amend |
| R-SEM greened only via `--verify-promotion` string while CLI not in release job / not failing closed | Require real invoke + fail-closed secrets/`set -e` behavior |
| `trusted-provenance-verify` is file-existence only and verify-promotion does not enforce trusted provenance | Require binding to trusted key path or reopen R-PROV |
| Matrix markers only in comments | Require verification path that rejects missing axes |
| Aggregate green but fixture purity no longer opens R-REL/R-SEM/… when inputs stripped | Restore purity tests |
| Worker claims production-terminal / live Logic PASS | Correct report; keep board QA_PENDING |
| Broad semantic stubbing (`return true`) | Reject; demand real validators or governed waivers |
| Weakening PromotionGate / QualificationRunner to force promotable | Out of T1 honesty; escalate |

### 5.3 Acceptable corrections (not automatic fail)

| Situation | Acceptable path |
|-----------|-----------------|
| R-AUTH closed by STATUS pin | Adjust residual-open expectation to six debts; keep R-AUTH fixture purity |
| Compile/integration fix on adopt | Smallest fix; preserve debt IDs and markers; document |
| Minimum GREEN is gate wiring without live matrix execution | Allowed for T1 **if** release fails closed without evidence and worker does **not** claim live PASS |
| `--verify-promotion` used as release gate | Allowed if it exercises PromotionGate + trusted provenance; document remaining 1/107 semantic coverage honesty |

---

## 6. Live worker trajectory notes (supervision, not PASS)

Observed during checklist authoring (subject to further change):

1. **Contracts dirty**: added `promotionVerificationMarker = "--verify-promotion"`; R-SEM now bypassable when that substring exists in YAML.
2. **RED tests dirty**: residual-open suite test renamed/repurposed to close-all; aggregate green test retained.
3. **`release.yml` dirty**: independent qualification step before Create GitHub Release; downloads external evidence zip; runs `./LogicProMCP --verify-promotion` with trusted key env; weak separate provenance file check; publishes attestation/manifest/transcript/mutation assets.

**Preliminary CTO stance (not a verdict)**: direction of fail-closed release gating is aligned with R-REL/R-PUB intent; **FG-2/FG-3/FG-4/FG-5 remain open** until evidence package clears them. Do not mark T1_PASS from this checklist alone.

---

## 7. Post-T1 handoff (out of T1; do not confuse)

After T1_PASS only:

1. Focused tests for all touched surfaces  
2. Exact-head full suite  
3. Release artifact + SHA-256  
4. Exact-artifact Logic 12.3 live matrix (or approved live N/A with CEO-visible bound)  
5. Security / privacy / evidence-integrity  
6. CTO exact-head PASS → CEO independent exact-head PASS  
7. PR CI → merge → post-merge → public-safe receipt  

State machine: STATUS §2. Historical #367 never substitutes for these steps.

---

## 8. CTO review sign-off block (fill at exact head)

```text
CTO T1 exact-head review
- candidate_sha:
- base_sha_ok: yes/no
- frozen_adopt_ok: yes/no
- red_proven_ok: yes/no
- residual_open_set_recorded:
- false_green_cleared: FG-1..FG-10 (list cleared / residual)
- green_honest_ok: yes/no
- status_ledger_ok: yes/no
- scope_ok: yes/no (#286 untouched)
- production_terminal_claimed: yes/no (must be no)
- verdict: T1_PASS | T1_BLOCKED | T1_FAIL
- correction_triggers_fired:
- next_transition:
```

---

## 9. File / symbol index (review anchors)

| Path | Why it matters |
|------|----------------|
| `docs/tickets/lpmcp-prd-001/STATUS.md` | Board, R-AUTH pin, ledger, stop conditions |
| `docs/tickets/lpmcp-prd-001/T1-gpt56-review-adopt-red-min-green.md` | T1 sequence + spawn constraints |
| `Sources/LogicProMCP/Qualification/ProductionReadinessContracts.swift` | Seven detectors + tree eval |
| `Tests/LogicProMCPTests/LPMCPPRD001ProductionReadinessREDTests.swift` | Fixture purity + tree RED/GREEN bar |
| `.github/workflows/release.yml` | Publication path; must gate before Create GitHub Release |
| `Sources/LogicProMCP/Qualification/QualificationTransport.swift` | `QualificationSemanticReadbackValidator` (health-only) |
| `Sources/LogicProMCP/Qualification/ReleaseQualificationAttestation.swift` | Axes, waivers, attestation schema |
| `Sources/LogicProMCP/Qualification/PromotionGate.swift` | Semantic-or-waiver, axis, provenance rejections |
| `Sources/LogicProMCP/Qualification/QualificationRunner.swift` | `--qualify` / `--verify-promotion`, provenance sign/verify |
| `Sources/LogicProMCP/Server/OperationRegistry.swift` | 107 registered ops |
| Canonical review §LPMCP-PRD-001 | Historical #367 FAIL / debt root cause |

---

**End of checklist.** CTO does not implement Swift here; worker remains sole implementation owner until T1 report. This document must remain consistent with STATUS/T1 text; if STATUS/T1 are later amended under CTO re-lock, update this checklist in a follow-up supervision step.
