# PRD: Issue #210 — cliclick trust resolver (diagnosable + operator-approved path)

**Version**: 0.1
**Date**: 2026-07-01
**Status**: Draft
**Size**: L
**Branch**: `fix/issue-210-cliclick-trust`
**Issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/210

## 1. Problem
`logic_project export_run/export_resume` fails the bounce step with a bare
`bounce_helper_dependency_missing: cliclick` even when cliclick is installed at
`/opt/homebrew/bin/cliclick`, because the trust resolver rejects any candidate whose parent
dir is group/world-writable (`parent_mode & 0o022`) — and on Apple-Silicon Homebrew
`/opt/homebrew/bin` is commonly `775`. `/usr/local/bin` is often absent, `/usr/bin` is
SIP-protected, so there's no usable trusted location out of the box. The `LOGIC_PRO_MCP_CLICLICK`
override doesn't help: it still must point INTO one of the 3 hard-coded dirs and pass the same
parent-writable check. The failure is opaque (no indication the binary was found-but-rejected).

**Security intent is correct** (don't exec a binary an attacker could swap) — this is NOT a
request to weaken the check. We ADD diagnosis + a *stricter* operator-approved arbitrary path.

## 2. Goals / Non-Goals
### Goals
- G1: **Diagnosable failure.** The resolver returns, per candidate, WHY it was rejected
  (not_found / not_executable / parent_untrusted / parent_writable / file_writable /
  ancestor_writable / owner_untrusted / sha256_mismatch). Surfaced in: the bounce error string,
  `doctor` `dependencies.cliclick`, and `system.health`.
- G2: **Operator-approved arbitrary path.** `LOGIC_PRO_MCP_CLICLICK` may point at an absolute path
  OUTSIDE the 3 canonical dirs; it is trusted **only** when (validated against the symlink-resolved
  real path): the file is executable, the file is not group/world-writable, every ancestor dir up to
  `/` is not group/world-writable, the file is owned by root or the current uid, and — if
  `LOGIC_PRO_MCP_CLICLICK_SHA256` is set — the file's SHA-256 matches the pin.
- G3: **Parity** across the three resolvers (Swift `resolveTrustedCliclick`, Python
  `trusted_cliclick_path`, `Scripts/live-e2e-test.py` mirror) — identical accept/reject decisions.
- G4: **Docs.** Document the trust model + the `chmod g-w /opt/homebrew/bin` one-liner + the
  approved-path env vars in SETUP.

### Non-Goals
- NG1: Do not weaken/remove the existing canonical-path check (the 3 dirs + immediate-parent
  non-writable rule is preserved byte-for-byte for those candidates).
- NG2: No auto-`chmod` / no auto-install of cliclick. Diagnosis + documented remediation only.
- NG3: No change to how cliclick is invoked for clicks (still via the resolved trusted path).

## 3. User Stories & Acceptance Criteria

### US-1: Diagnosable rejection
- AC-1.1: `resolveCliclickDetailed` returns `(resolvedPath: String?, candidates: [(path, source, reason)])`
  where every candidate examined carries a typed reason; `resolveTrustedCliclick` == `.resolvedPath` (back-compat).
- AC-1.2: When cliclick at `/opt/homebrew/bin/cliclick` is rejected for a group-writable parent, the
  candidate reason is `parent_writable` (NOT `not_found`).
- AC-1.3: The bounce failure string (Swift `runBounceHelper` + Python `logic_bounce.py`) includes each
  tried path + reason + the remediation (`chmod g-w /opt/homebrew/bin` OR set `LOGIC_PRO_MCP_CLICLICK`),
  while keeping the `bounce_helper_dependency_missing: cliclick` / `cliclick_missing` prefix.
- AC-1.4: `doctor dependencies.cliclick` evidence lists the candidate reasons when unresolved; `pass`
  with the resolved path when resolved.
- AC-1.5: `system.health` reports a dependencies section: `cliclick` trusted bool + resolved path + a
  short trust/diagnosis string.

### US-2: Operator-approved arbitrary path (strict)
- AC-2.1: `LOGIC_PRO_MCP_CLICLICK=/approved/abs/cliclick` resolves (status resolved) when the
  symlink-resolved real file is executable, not group/world-writable, owned by root or current uid,
  and every real ancestor dir is not group/world-writable.
- AC-2.2: The same path is REJECTED with the specific reason when: file missing (`not_found`),
  not executable (`not_executable`), file group/world-writable (`file_writable`), any ancestor
  group/world-writable (`ancestor_writable`), or owner not root/current-uid (`owner_untrusted`).
- AC-2.3: When `LOGIC_PRO_MCP_CLICLICK_SHA256` is set, a content mismatch is rejected
  `sha256_mismatch`; a match (with all other checks passing) resolves. Hex compare is case-insensitive.
- AC-2.4: Symlink safety — validation uses the resolved REAL path's ancestry, so a symlink whose
  real target sits under a writable dir is rejected `ancestor_writable` (no symlink bypass).
- AC-2.5: An override pointing INTO a canonical dir still works (covered by either the strict path or
  the canonical path — both must accept a non-writable canonical install).

### US-3: Parity & back-compat
- AC-3.1: Swift, Python, and the live-e2e mirror produce identical accept/reject for the same inputs
  (canonical accept, writable-parent reject, arbitrary-approved accept, arbitrary-rejected reasons).
- AC-3.2: Existing accepted cases keep working: `/opt/homebrew/bin/cliclick` with a `755` parent →
  resolved; `/tmp/cliclick` (untrusted) → rejected.

## 4. Technical Design

### 4.1 Shared trust algorithm
`resolveCliclickDetailed(environment, isExecutable, attributesOfItem, realpath, sha256OfFile, currentUid)`:
1. If `environment["LOGIC_PRO_MCP_CLICLICK"]` set → evaluate as **approved-arbitrary** (strict). Record
   candidate (`source=override`). If resolved → return it.
2. For each of the 3 canonical candidates → evaluate as **canonical** (existing rule). Record candidate
   (`source=canonical`). First resolved → return it.
3. Return `(nil, candidates)`.

**canonical(path)** — preserves shipped behavior, now with a typed reason:
- parent = dirname(absLexical(path)); if parent ∉ {/opt/homebrew/bin,/usr/local/bin,/usr/bin} → `parent_untrusted`
- stat(parent) fails → `not_found`; parent mode & 0o022 → `parent_writable`
- not isfile(path) → `not_found`; not executable → `not_executable`; else → `resolved`

**approvedArbitrary(path)** — strict, symlink-resolved:
- real = realpath(absExpand(path)); if not isfile(real) → `not_found`; if not executable → `not_executable`
- stat(real).mode & 0o022 → `file_writable`
- owner(real) ∉ {0, currentUid} → `owner_untrusted`
- for each ancestor of real (parent … `/`): stat fails → `ancestor_writable` (treat unreadable as unsafe);
  mode & 0o022 → `ancestor_writable`
- if `LOGIC_PRO_MCP_CLICLICK_SHA256` set and sha256(real) != pin (case-insensitive) → `sha256_mismatch`
- else → `resolved`

Reason precedence is fixed/total (table above) so Swift & Python agree exactly.

### 4.2 Surfaces
- **Swift resolver** (`ProjectExportExecutorBounceHelperResolution.swift`): add `enum CliclickRejection`,
  `struct CliclickCandidate`, `struct CliclickResolution`, `resolveCliclickDetailed(...)`. Keep
  `resolveTrustedCliclick(...) -> String?` as `resolveCliclickDetailed(...).resolvedPath`. Inject
  `realpath` + `sha256` + `currentUid` (defaults real); `attributesOfItem` already injected.
- **Bounce error** (`ProjectExportExecutorBounceHelper.swift`): `resolveCliclick` seam returns
  `CliclickResolution`; on nil build `bounce_helper_dependency_missing: cliclick — <summary>`.
- **doctor** (`SetupDoctor.swift`): `Runtime.cliclickResolution: () -> ProjectExportExecutor.CliclickResolution`
  replaces `cliclickPath` (keep `cliclickPresentOnPath`). Evidence carries candidate reasons.
- **health** (`SystemDispatcher.swift`): add `DependenciesSection { cliclick: Bool; cliclickPath: String?; cliclickTrust: String }`.
- **Python** (`logic_bounce_ui.py`): `trusted_cliclick_resolution(override) -> Resolution` (dataclass-ish dict)
  + `trusted_cliclick_path(override)` wrapper. `logic_bounce.py` builds `error=cliclick_missing` + `reason=<summary>`.
- **live-e2e mirror** (`live-e2e-test.py`): update mirror to match (parity).
- **docs** (`SETUP.md`): trust-model section + `chmod g-w /opt/homebrew/bin` + `LOGIC_PRO_MCP_CLICLICK`
  (+`_SHA256`) approved-path instructions; expand the `#doctor-dependenciescliclick` anchor.

### 4.3 Key decisions
| Decision | Choice | Rationale |
|---|---|---|
| Override semantics | arbitrary path via STRICT validation (not a bypass) | satisfies G2 without weakening security (NG1) |
| Symlink handling | resolve real path, validate real ancestry | closes symlink-redirect bypass (AC-2.4) |
| Owner check | uid ∈ {0, getuid()} | non-owner can't swap a non-writable-ancestry file |
| SHA256 | optional `LOGIC_PRO_MCP_CLICLICK_SHA256` pin | strongest anti-swap guarantee, content-addressed |
| Canonical rule | unchanged | zero regression to shipped trust (NG1) |
| Return shape | detailed struct + thin `resolveTrustedCliclick` wrapper | minimal caller churn |

## 5. Edge Cases
| # | Scenario | Expected |
|---|---|---|
| E1 | `/opt/homebrew/bin` is 775 (group-writable), cliclick present | canonical→`parent_writable`; bounce error names it + remediation; doctor warn w/ reason |
| E2 | `LOGIC_PRO_MCP_CLICLICK` → file under a 777 dir | `ancestor_writable` |
| E3 | override → symlink whose real target is under a writable dir | `ancestor_writable` (real-path ancestry) |
| E4 | override → file owned by another non-root user | `owner_untrusted` |
| E5 | override file group/world-writable | `file_writable` |
| E6 | `_SHA256` set, content differs | `sha256_mismatch`; matches → resolved |
| E7 | override empty string / unset | treated as not provided (no candidate) |
| E8 | `/usr/local/bin` absent | canonical candidate → `not_found`, not a crash |
| E9 | all rejected | resolver returns nil + full candidate list; callers never crash |
| E10 | override INTO canonical non-writable dir | resolved (AC-2.5) |
| E11 | ancestor stat unreadable (EACCES) | `ancestor_writable` (fail-closed: unverifiable = untrusted) |
| E12 | realpath of a path with no parent (`/cliclick`) | parent=`/`; `/` is root-owned non-writable → ok if file ok |

## 6. Security
Trust model: only execute a cliclick that a non-root attacker on the same machine cannot swap.
Canonical: immediate-parent non-writable in a system bin dir. Arbitrary: full real-ancestry
non-writable + owner ∈ {root, self} + optional content pin. Fail-closed everywhere (any
stat/permission uncertainty → reject). No secret is logged; evidence/diagnosis carry only paths +
enumerated reasons (paths are the operator's own local paths, not credentials).

## 7. Testing
- Swift unit (`ProjectExportBounceHelperContractTests` + new): every reason in §4.1, parity of
  `resolveTrustedCliclick` vs `.resolvedPath`, E1–E12, sha256 match/mismatch, symlink real-ancestry.
- Python unit (`logic_bounce_ui_test`, `logic_bounce_main_test`): mirror the same reason matrix; the
  `logic_bounce.py` main error carries `reason`.
- doctor tests (`SetupDoctorEnterpriseTests`): cliclick check surfaces reasons; resolved → pass.
- health tests: dependencies section present + correct trust string.
- Real-usage (this machine genuinely has 775 `/opt/homebrew/bin`): live `doctor --json` shows the
  `parent_writable` reason; a real approved copy of cliclick under a non-writable dir resolves via the
  env override; `chmod g-w` makes the canonical path resolve.

## 8. Rollout
Single branch/PR `Fixes #210`. No migration. Revertable. Comment on the issue once the PR is up.

## 9. Design Review Resolutions (guardian security + boomer BOOMER-6) — NORMATIVE

These supersede §4 where they conflict. Implementation MUST follow this.

### 9.1 Normative reason vocabulary (TOTAL, identical Swift/Python/live-e2e)
`resolved, not_absolute, not_found, not_executable, file_writable, owner_untrusted, ancestor_writable, sha256_mismatch` (canonical reuses `not_found`, `parent_writable`, `not_executable`, `resolved`).

### 9.2 `evaluateCanonical(path)` — UNCHANGED shipped semantics (NG1), only called on the 3 hardcoded CANONICAL_PATHS, NO symlink resolution:
1. parent = dirname(absLexical(path)); stat(parent) fails → `not_found`; parent.mode & 0o022 → `parent_writable`
2. file exists+executable? no → `not_found`/`not_executable`; else → `resolved` (resolvedPath = lexical path, a symlink is fine — not followed)

### 9.3 `evaluateArbitrary(path, env)` — STRICT, symlink-resolved, fail-closed:
1. empty/whitespace → not a candidate (skip). contains NUL → `not_found`. not absolute (no leading `/`) → `not_absolute`.
2. real = **C realpath(3)** (Swift `Darwin.realpath`) / **os.path.realpath + explicit exists check** (Python). realpath fail / real missing → `not_found`.
3. not isfile(real) → `not_found`; not executable(real) → `not_executable`
4. stat(real).mode & 0o022 → `file_writable`
5. owner(real) ∉ {0, currentUid} → `owner_untrusted` (read/cast failure → `owner_untrusted`, never skip)
6. for each ancestor of real (immediate parent … `/` inclusive): stat fail → `ancestor_writable`; mode & 0o022 → `ancestor_writable`; owner ∉ {0, currentUid} → `ancestor_writable`
7. if env key `LOGIC_PRO_MCP_CLICLICK_SHA256` PRESENT (even blank): pin = value.strip().lower(); actual = sha256(real); read-fail or pin not 64-hex or pin != actual → `sha256_mismatch`
8. else → `resolved` (resolvedPath = **real** path)

### 9.4 `resolveCliclickDetailed(env)` ordering
1. env `LOGIC_PRO_MCP_CLICLICK` present+non-blank → `evaluateArbitrary` (ALWAYS arbitrary — R3). record. resolved → return real path. **A rejected override does NOT suppress canonical fallthrough** (S2-B).
2. each CANONICAL_PATH → `evaluateCanonical`. record. resolved → return.
3. return (nil, all candidates).

### 9.5 Parity of the Swift→Python `--cliclick-path` handoff (R5/R6)
- Swift resolves ONCE, passes the resolved path (real for arbitrary, lexical for canonical) as `--cliclick-path`.
- `logic_bounce.py` main validates `--cliclick-path` by **location classification**: if ∈ CANONICAL_PATHS → `evaluateCanonical` (no symlink follow → the chmod'd canonical symlink resolves); else → `evaluateArbitrary`. This matches how Swift accepted it → no divergence. On reject: `error=cliclick_missing`, `reason=<diagnostic summary>`.
- `cliclick()` resolves ONCE (cached module-level), no per-click re-resolution (R5 TOCTOU).

### 9.6 currentUid
Swift `getuid()`, Python `os.getuid()` (real uid; server is not setuid so real==effective). Identical both sides.

### 9.7 Honest remediation (R1 — verified live: `/opt/homebrew/bin` AND `/opt/homebrew/Cellar` are 775 on stock Apple-Silicon brew)
- **Simplest working fix:** `chmod g-w /opt/homebrew/bin` → the CANONICAL candidate resolves (canonical checks only the immediate parent, does not follow the symlink to the writable Cellar). Note brew may reset to 775 on upgrade.
- **Hardened approved path:** copy cliclick to a location whose file + every ancestor are non-group/world-writable and owned by root or you (e.g. a root-owned `/usr/local/bin` you control), then `export LOGIC_PRO_MCP_CLICLICK=/that/path` (+ optional `LOGIC_PRO_MCP_CLICLICK_SHA256`). On stock Homebrew, pointing the override at the brew cliclick is REJECTED (`ancestor_writable` at `/opt/homebrew/Cellar`) — documented honestly; do NOT claim the env override fixes stock Homebrew without a clean copy.
- Diagnosis names the exact failing candidate + reason so the operator knows which remediation applies.

### 9.8 doctor seam (R8) & health (B6)
- Replace `Runtime.cliclickPath: () -> String?` with `cliclickResolution: () -> ProjectExportExecutor.CliclickResolution` (clean break; update `doctorRuntime`/`enterpriseRuntime` test helpers). Keep `cliclickPresentOnPath` (orthogonal "installed at all" signal).
- `system.health` gains an ADDITIVE `dependencies` section (`cliclick: Bool`, `cliclickPath: String?`, `cliclickTrust: String`) — no existing field removed/renamed (additive MCP-surface change).

### 9.9 Added edge cases (E13–E19): realpath fail→not_found; relative override→not_absolute; NUL→not_found; sha256 non-hex/blank/unreadable→sha256_mismatch; ancestor owned by hostile non-root user→ancestor_writable (owner∈{0,self} on ancestors); Python owner check uses `os.stat` (follows to real file) not `lstat`; live-e2e mirror parity for arbitrary path.
