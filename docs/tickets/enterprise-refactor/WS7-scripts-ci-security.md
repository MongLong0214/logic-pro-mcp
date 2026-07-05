# WS7: Scripts + CI + Formula — security M1/M2 + release hardening

**PRD**: G1 (security), §3.2 WS7
**Priority**: P1 (M1 injection) | **Size**: M | **Risk**: L-M
**Owns (EXCLUSIVE)**: `Scripts/*.sh` + `.github/workflows/*.yml` + `Formula/*`. No Swift. No overlap with any WS.
**Parallel-safe with**: all (no shared files).

## 1. Objective
Close the supply-chain / install-security findings and harden the release path — no Swift, no wire surface.

## 2. Acceptance Criteria
- **AC1 [M1, security must-fix #1]**: `.github/workflows/publish-mcp.yml:25` — `VERSION` no longer interpolates `${{ github.event.release.tag_name }}` directly into `run:`. Use env indirection: `env: RELEASE_TAG: ${{ github.event.release.tag_name }}` then `VERSION="${RELEASE_TAG#v}"` + a SemVer guard (mirror release.yml). Closes the OIDC-identity arbitrary-code injection.
- **AC2 [M2]**: install-common.sh `validate_share_dir` (:80-87) gains the same protected-path `case` as `validate_install_dir` (:70-78) INCLUDING the macOS `/private` trio (`/private/etc`, `/private/tmp`, `/private/var` minus allowed subtrees) — blocklist evaluated on the realpath (install.sh:39 normalizes symlinks before validation, so `/etc`→`/private/etc` currently slips through → sudo `mv`/`rm -rf`).
- AC3: `release.sh` Formula sha256 verify (audit Scripts P1) — after the `mv`, assert `grep -Fq "$TARBALL_SHA" Formula/logic-pro-mcp.rb || exit 1` (else format drift → stale hash → all `brew install` fail checksum, #22-class). Guard `git commit` no-op re-run under `set -e` (`git diff --cached --quiet ||`).
- AC4: CI least-privilege + pin: `ci.yml:18` SHA-pin `actions/checkout@v4` + add a `permissions:` block (others already pin); `release.yml:15-16` `contents:write` not inherited by the read-only `validate-install` job (scope per-job); `release.yml:204` use the existing `$LOGIC_PRO_MCP_VERSION` env instead of `${{ github.ref_name }}` in `run:`.
- AC5: `swift test --no-parallel` unaffected (no Swift). CI workflows lint clean (`actionlint` if available); a dry `workflow_dispatch` on the branch where safe.

## 3. Verification
- M1: actionlint on publish-mcp.yml; manually trace that a malicious `tag_name` can no longer reach a shell metachar (env-indirected + SemVer-guarded).
- M2: a shell unit assertion — `LOGIC_PRO_MCP_INSTALL_DIR=/etc` (→ /private/etc) is now REJECTED; a legit `~/.local/...` still passes; the existing install-script contract tests stay green.
- release.sh: dry-run the Formula-sha grep against a known tarball; confirm it exits non-zero on a deliberately-wrong hash.

## 4. Constraints
- Do NOT change install/uninstall behavior for legit paths (only tighten the blocklist + add the checksum assertion).
- M3 notarization is NOT in this WS — it's an Isaac/release decision at Phase E (ship notarized OR document out-of-band-pin as sole enterprise path).
- Scripts already have `set -euo pipefail` + guarded `rm -rf` — preserve.

## 5. Review Checklist
- [ ] M1 publish-mcp env-indirection + SemVer guard (actionlint clean)
- [ ] M2 validate_share_dir symmetry incl. /private trio (realpath-based); reject-test passes
- [ ] release.sh Formula-sha grep assertion + no-op-commit guard
- [ ] CI checkout pin + per-job permissions
- [ ] Install-script contract tests green; no legit-path regression
