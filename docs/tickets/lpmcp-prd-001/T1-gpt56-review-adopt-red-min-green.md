# T1 — GPT-5.6 worker: review/adopt frozen contracts → bounded RED → minimum GREEN → verification

**Board**: [STATUS.md](./STATUS.md)
**Debt**: `LPMCP-PRD-001` / historical PR [#367](https://github.com/MongLong0214/logic-pro-mcp/pull/367) residual
**Owning issue**: [#284](https://github.com/MongLong0214/logic-pro-mcp/issues/284) (ADR-001); program [#308](https://github.com/MongLong0214/logic-pro-mcp/issues/308)
**Exact base**: `cc5922e5c5c2786c401713fd80b1bd40d1e15f14`
**Worktree**: `/Users/isaac/projects/logic-pro-mcp-adr001-remediation`
**Branch**: `fix/adr001-production-readiness-20260716`
**Assignee**: **first GPT-5.6 implementation worker only** (not CTO, not Grok implementation agents)
**Decision status**: **ACTIVE — §15 RE-LOCK** (CTO re-locked residual-RED baseline; worker executes residual RED then min GREEN)

---

## Goal


## CTO correction 2026-07-16 (§15 re-lock)

- Board-open frozen hashes are **void / unrestorable**.
- **Preserve** dirty contracts, RED tests, `release.yml`, Runner, RunnerTests.
- Re-locked digests and residual-RED requirements: `STATUS.md` §15 + `artifacts/cto-t1-handoff-relock-20260716.md`.
- **Immediate work:** restore residual-open RED assertion; close R-SEM/R-MATRIX false-green holes; capture RED transcript; then minimum GREEN; focused re-run.
- Invariant name is now `releaseWorkflowRequiresTrustedIndependentQualificationBeforePublication` (trusted public key + verify-promotion) — do not regress to candidate self-sign.


On the locked exact base, with frozen inheritance preserved:

1. **Review and adopt** the two inherited untracked Swift contract files.
2. **Reproduce bounded RED** (all seven `LPMCP-PRD-001` debts open; aggregate production bar fails for the right reasons).
3. Implement the **minimum GREEN** that satisfies the seven contract detectors without false-green shortcuts.
4. Run **verification** for this ticket’s exit criteria and update the STATUS ledger.

This ticket ends at **focused minimum GREEN + recorded evidence**. Full production gate (exact-head full suite → release artifact → Logic live → security → CTO/CEO) remains on the board after T1 unless the same worker is explicitly extended by CTO.

---

## Frozen inherited input (do not destroy)

| Path | SHA-256 at board open |
|------|------------------------|
| `Sources/LogicProMCP/Qualification/ProductionReadinessContracts.swift` | `5b44aedd2d35c1765c99a318ba7fe9fecfe277601799f803f4ef81a686d54501` |
| `Tests/LogicProMCPTests/LPMCPPRD001ProductionReadinessREDTests.swift` | `85722d8db04e3657b81d0f1d3544a5b632e986e41e48673ef390919f28e47459` |

Also present and binding: `docs/tickets/lpmcp-prd-001/STATUS.md` (pins exact base; path is `ProductionReadinessContractEvaluator.debtBoardRelativePath`).

---

## Acceptance (T1 exit)

- [ ] HEAD is still based on `cc5922e5c5c2786c401713fd80b1bd40d1e15f14` (or an intentional descendant only of T1 commits); no unrelated dirt.
- [ ] Frozen files reviewed; adopt decision recorded (keep-as-is **or** minimal compile/integration fix with rationale). Fingerprint change only if fix is justified in ledger.
- [ ] Bounded RED reproduced **before** GREEN implementation:
  - `swift test --filter LPMCPPRD001ProductionReadinessREDTests`
  - `currentMainTreeOpensAllSevenLPMCPPRD001Debts` observes the open set (re-check after STATUS pin whether R-AUTH alone closed).
  - `productionReadinessContractsAreSatisfiedOnCurrentTree` fails while debts remain.
- [ ] Minimum GREEN: same filter is green because the seven detectors are satisfied by real release-path / semantic / matrix / mutation / provenance / publication / authority bindings — **not** by deleting tests or hardcoding green flags.
- [ ] No #286 work; no scope expansion into other `LPMCP-PRD-00x` debts unless compile-blocking.
- [ ] STATUS.md verification ledger updated (RED proven, GREEN status, commands, SHAs).
- [ ] Single Swift build/test ownership respected.
- [ ] No merge; no claim of production-terminal PASS; no public model/session metadata.

---

## Required work sequence (binding)

### Step A — Preflight

```bash
cd /Users/isaac/projects/logic-pro-mcp-adr001-remediation
git rev-parse HEAD   # must be cc5922e5c5c2786c401713fd80b1bd40d1e15f14 at start
git status --short   # only expected untracked/docs + later intentional T1 edits
```

If HEAD differs or unexpected tracked dirt exists → **STOP** and report.

### Step B — Review / adopt frozen files

1. Read both Swift files end-to-end against STATUS §1 / §7 and canonical review §LPMCP-PRD-001.
2. Confirm they encode R-REL … R-AUTH and evaluate `release.yml`, semantic validators, matrix markers, mutation/provenance/publication markers, and STATUS path.
3. **Adopt**: keep files; `git add` only when ready to include them in the remediation commit set (worker may commit **only if** explicitly allowed by the spawn operator; default under this ticket: implement + verify; **prefer no force-push**; never discard inheritance).
4. If compile fails against current main APIs, apply the **smallest** fix that preserves detector semantics; document before/after.

### Step C — Reproduce bounded RED

```bash
swift test --filter LPMCPPRD001ProductionReadinessREDTests
```

Capture: which debts open, whether R-AUTH closed after STATUS pin, and that the aggregate satisfied test is still RED if any of R-REL…R-PUB remain.

Do **not** start GREEN implementation until RED evidence is recorded.

### Step D — Minimum GREEN

Implement the smallest change set that makes `ProductionReadinessContractEvaluator.evaluateRepositoryRoot` return `satisfied == true` on this tree, aligned with real production intent:

| ID | Direction of minimum fix |
|----|---------------------------|
| R-REL | Release workflow gains an enforced independent exact-artifact qualification step **before** publication (`Enforce independent exact-artifact qualification`) |
| R-SEM | Expand semantic validators and/or introduce explicit release-note-visible default-profile waivers so every registered operation is covered honestly (smoke/deferral ≠ qualified) |
| R-MATRIX | Bind managed-fixture matrix (Desktop/Creator × en/ko) in release/evidence path |
| R-MUT | Require mutation/readback/restore/compensation evidence on release path |
| R-PROV | Enforce trusted independent provenance verification (not candidate self-sign alone) |
| R-PUB | Publish immutable qualification attestation/manifest/raw-evidence assets from release |
| R-AUTH | Keep STATUS.md pin of exact base `cc5922e5c5c2786c401713fd80b1bd40d1e15f14` |

Prefer honest fail-closed release gating over claiming live Logic PASS without evidence. If a full live matrix cannot run in this ticket, wire **enforcement + honest non-promotable / waiver** paths so detectors green only when the **gate exists and binds**, not when Logic is silently skipped.

### Step E — Verification (T1)

```bash
swift test --filter LPMCPPRD001ProductionReadinessREDTests
# optional if time-boxed by CTO extension:
# swift test --filter <touched_related_filters>
```

Update `STATUS.md` ledger: RED command output summary, GREEN command output summary, files touched, open questions, stop if any hard stop condition hit.

### Explicit non-goals for T1

- Exact-head full suite / release binary / live Logic / CEO gate (board §8 — later transitions)
- Opening or merging the remediation PR unless CTO extends
- Any work on #286
- Weakening RED tests to force green

---

## Authority to re-read (worker)

1. `docs/tickets/lpmcp-prd-001/STATUS.md`
2. `docs/adr/README.md` (ADR-001 + execution-order override)
3. `/Users/isaac/.openclaw/workspace/runbooks/logic-pro-mcp-308-canonical-execution.md`
4. `/Users/isaac/.openclaw/workspace/reviews/logic-pro-mcp-pr315-363-production-readiness-review-2026-07-13.md` §LPMCP-PRD-001
5. Predecessor: `docs/tickets/adr-002a-target-kinds/STATUS.md` (terminal; do not reopen)

---

## Stop conditions (worker)

Same as STATUS §10. Additionally stop if:

- Another process already holds Swift build/test in this worktree
- Minimum GREEN appears to require multi-ADR redesign beyond release/qualification enforcement — escalate for CTO scope re-lock rather than inventing #286 work

---

## Spawn instruction (exact)

Operator/CTO spawns **one** GPT-5.6 worker in this worktree. Do not use Grok implementation agents.

```bash
cd /Users/isaac/projects/logic-pro-mcp-adr001-remediation && \
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" codex exec \
  -m gpt-5.6-sol \
  -c 'model_reasoning_effort="xhigh"' \
  -c 'approval_policy="never"' \
  --ephemeral \
  "$(cat <<'EOF'
You are the first GPT-5.6 implementation worker for logic-pro-mcp debt LPMCP-PRD-001 / historical PR #367 residual remediation.

HARD CONSTRAINTS
- Worktree only: /Users/isaac/projects/logic-pro-mcp-adr001-remediation
- Exact base at start: cc5922e5c5c2786c401713fd80b1bd40d1e15f14 (git rev-parse HEAD must match before edits)
- Read and follow: docs/tickets/lpmcp-prd-001/STATUS.md and docs/tickets/lpmcp-prd-001/T1-gpt56-review-adopt-red-min-green.md
- Preserve frozen inherited untracked Swift inputs until review/adopt:
  - Sources/LogicProMCP/Qualification/ProductionReadinessContracts.swift
  - Tests/LogicProMCPTests/LPMCPPRD001ProductionReadinessREDTests.swift
- Do NOT work on #286 or any other train item.
- Do NOT discard/clean the frozen files.
- Max one swift build/test process.
- Do NOT merge. Do NOT claim production-terminal PASS.
- Do NOT put model/provider/agent/session/routing/effort/local-path metadata on GitHub.
- Public-safe technical evidence only.

MANDATORY SEQUENCE
1) Preflight: rev-parse HEAD, git status, confirm exact base and frozen files present.
2) Review/adopt the two frozen Swift files (smallest compile fix only if required; preserve R-REL…R-AUTH semantics).
3) Reproduce bounded RED: swift test --filter LPMCPPRD001ProductionReadinessREDTests
   Record which of the seven debts are open. Do not implement GREEN before RED evidence.
4) Minimum GREEN: smallest real changes so ProductionReadinessContractEvaluator.evaluateRepositoryRoot is satisfied (release independent qualification step, semantic coverage or honest waivers, managed-fixture matrix binding, mutation-restore-compensation requirement, trusted-provenance-verify, release-qualification-attestation publication, STATUS exact-base pin). No deleting/weakening RED to fake green.
5) Re-run the same filter green; update docs/tickets/lpmcp-prd-001/STATUS.md verification ledger with commands and outcomes.
6) Stop at T1 exit criteria. Report: SHA, dirty summary, RED evidence, GREEN evidence, files changed, blockers, next board transition.

Authority if conflict: STATUS.md > docs/adr/README.md > openclaw canonical review/runbook > historical #367 merge claims.
EOF
)"
```

### Spawn checklist

| Check | Value |
|-------|--------|
| CWD | `/Users/isaac/projects/logic-pro-mcp-adr001-remediation` |
| Model | `gpt-5.6-sol` |
| Reasoning | `xhigh` (not `max`) |
| Parallel Swift | none already running |
| Ticket | this file |
| Board | `STATUS.md` |

---

## Report template (worker → CTO)

```text
T1 report
- base_sha:
- head_sha_after:
- frozen_adopt: keep-as-is | minimal-fix (+ why)
- red_command:
- red_open_debts:
- green_command:
- green_result:
- files_changed:
- status_ledger_updated: yes/no
- blockers:
- next_transition:
- verdict: T1_PASS | T1_BLOCKED | T1_FAIL
```
