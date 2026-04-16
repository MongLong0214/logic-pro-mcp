# Installer supply-chain hardening — Status

**Opened**: 2026-04-16 (carved out of the v2.2 census-cleanup review)
**Priority**: P1 (security)
**Size**: L
**Status**: Spec
**Depends On**: Release infrastructure decisions (Isaac)

## Problem

`Scripts/install.sh:73-95` resolves three verification-critical
values from the *same* GitHub release artefact directory:

- binary: `$DOWNLOAD_URL`
- checksum manifest: `$SHA_URL` (`SHA256SUMS.txt`)
- Team ID: `$METADATA_URL` (`RELEASE-METADATA.json`)

If that release is tampered with (GitHub account compromise, malicious
maintainer PR, supply-chain attack on the release pipeline), the
checksum and TeamID are replaced in lockstep with the binary, and
`codesign --verify` / `spctl --assess` still pass because the attacker
signs with their own key and publishes a matching TeamID.

## Required decisions (Isaac)

Pick the verification root that is *out-of-band* from the release
artefacts:

1. **Pinned in binary** — bake a minimum SHA256 / TeamID into the
   installer at compile time and enforce them over the release-hosted
   values. Requires a versioned installer per release.
2. **Second authenticated source** — publish metadata to a separate
   channel (Homebrew core formula, `.well-known/LogicProMCP.json` on
   a controlled domain, npm registry) and cross-check.
3. **Sigstore / cosign** — require a cosign-signed bundle and verify
   against a public transparency log; unrelated to GitHub release
   integrity.

## Open tickets (to be fleshed out once Isaac picks the root)

- `T1-verification-root-decision.md` — Isaac decides which option.
- `T2-installer-enforcement.md` — update install.sh + release workflow.
- `T3-docs-and-regression.md` — SECURITY.md, CONTRIBUTING.md, contract tests.

## References

- `Scripts/install.sh:73-95`
- `SECURITY.md`
- `.github/workflows/release.yml`
- census review: `[H-8]` finding
