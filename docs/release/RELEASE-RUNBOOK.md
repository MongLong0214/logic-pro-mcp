# Release Runbook

## Preconditions

- GitHub Actions secrets configured:
  - `MACOS_CERT_BASE64`
  - `MACOS_CERT_PASSWORD`
  - `MACOS_SIGNING_IDENTITY`
  - `MACOS_KEYCHAIN_PASSWORD`
  - `APPLE_NOTARY_APPLE_ID`
  - `APPLE_NOTARY_TEAM_ID`
  - `APPLE_NOTARY_APP_PASSWORD`
- `main` is green on CI.
- `swift build -c release`
- `swift test`
- `swift test --enable-code-coverage --no-parallel`

## Release Steps

1. Update versioned release notes.
2. Push the release commit to `main`.
3. Create and push a signed tag:

```bash
git tag v2.0.0
git push origin v2.0.0
```

4. Wait for `.github/workflows/release.yml` to finish.
5. Verify release assets:
   - `LogicProMCP`
   - `LogicProMCP-macOS-universal.tar.gz`
   - `RELEASE-METADATA.json`
   - `SHA256SUMS.txt`
6. Confirm post-release install validation job passed on:
   - `macos-15`
   - `macos-13`

## Acceptance

- Release job passed with codesign, notarization, stapling, and `spctl` verification.
- Install validation job passed on both runner families.
- Evidence captured in [RELEASE-EVIDENCE-TEMPLATE.md](/Users/isaac/projects/logic-pro-mcp/docs/release/RELEASE-EVIDENCE-TEMPLATE.md).
