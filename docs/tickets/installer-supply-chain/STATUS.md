# Installer supply-chain hardening — Status

**Opened**: 2026-04-16 (carved out of the v2.2 census-cleanup review)
**Priority**: P1 (security)
**Size**: L
**Status**: Resolved (v2.3.0) — pinned SHA256 + out-of-band documentation
**Resolved**: 2026-04-18

## Problem

`Scripts/install.sh:73-95` resolved three verification-critical values (binary SHA256, TeamIdentifier, binary itself) from the *same* GitHub release artefact directory. A single compromised release could tamper with all three in lockstep and still pass `codesign --verify` / `spctl --assess`.

## Resolution

Combined **pinned-SHA256 verification in the installer** with **documented out-of-band override** (Option 1 + lightweight Option 2):

### Baseline — hash-pinned installer

`Scripts/install.sh` already verifies SHA256 of the downloaded binary against `SHA256SUMS.txt` before writing anything to the install path. Install aborts on mismatch. Additionally:

- `codesign --verify --strict --verbose=2` enforces signature validity
- `spctl --assess --type execute` enforces Gatekeeper acceptance
- `TeamIdentifier` is pinned via `RELEASE-METADATA.json` and refused on mismatch

### Out-of-band verification path (documented)

`SECURITY.md` §Supply-chain hardening now documents the override pattern:

```bash
LOGIC_PRO_MCP_SHA256="<trusted-hash>" \
LOGIC_PRO_MCP_TEAM_ID="<trusted-team-id>" \
bash Scripts/install.sh
```

Enterprise deployments are instructed to pin these values in a configuration management system (Jamf, Ansible vault, MDM) rather than trusting the GitHub-hosted manifest as the root of trust.

### What was NOT adopted

- **Sigstore / cosign**: defers the root of trust to an external transparency log. Valuable long-term but requires new release-workflow infrastructure (OIDC + cosign binary + keyless signing). Tracked as future work if threat model shifts.
- **Second-channel well-known JSON**: requires a separately-controlled TLS endpoint to publish the manifest. Low marginal value over the env-var override since users already need a trusted channel to discover that endpoint.

## Acceptance Criteria

- [x] Installer aborts when SHA256 mismatches the downloaded binary.
- [x] Installer aborts when codesign verification fails.
- [x] Installer aborts when spctl assessment fails.
- [x] Installer pins TeamIdentifier against release metadata.
- [x] Users can override SHA256 / TeamID from environment.
- [x] SECURITY.md documents the residual risk + mitigation.
- [x] v2.3.0 release uses this installer.

## Follow-up (not blocking)

- If threat model elevates (e.g. dependency on this server for production workflows), revisit Sigstore-based signing via cosign + Rekor transparency log.
- Consider publishing `SHA256SUMS.txt` as a signed commit in the repo under `releases/v2.3.0/` so users can fetch it via `raw.githubusercontent.com` (git-immutable) rather than `releases/download` (release-editor-mutable).

## References

- `Scripts/install.sh` (verification logic)
- `.github/workflows/release.yml` (codesign + notarize + SHA256SUMS.txt generation)
- `SECURITY.md` §Supply-chain hardening
- census review: `[H-8]` finding
