# GitHub Actions Secrets

The `release.yml` workflow requires 7 encrypted secrets. Without them the release job fails during signature validation.

**Current status (2026-04-12):** ❌ No secrets configured. Workflow will fail on next tag push.

---

## Required secrets

| Name | Purpose | Source |
|------|---------|--------|
| `MACOS_CERT_BASE64` | Base64-encoded `.p12` export of Developer ID Application cert + private key | Keychain Access → Export |
| `MACOS_CERT_PASSWORD` | Password used when exporting the `.p12` | Chosen by operator |
| `MACOS_SIGNING_IDENTITY` | The identity string passed to `codesign -s` | e.g. `Developer ID Application: Your Name (TEAMID12)` |
| `MACOS_KEYCHAIN_PASSWORD` | Password for the CI-created temporary keychain | Any strong random string |
| `APPLE_NOTARY_APPLE_ID` | Apple ID used for notarization | `your-email@example.com` |
| `APPLE_NOTARY_TEAM_ID` | Developer team identifier | e.g. `TEAMID12` |
| `APPLE_NOTARY_APP_PASSWORD` | App-specific password for notarytool | https://appleid.apple.com/account/manage |

---

## One-time setup

### 1. Export the Developer ID Application certificate

```bash
# In Keychain Access, right-click the "Developer ID Application: Your Name (TEAMID12)" item
# → Export → file.p12 → choose a password
base64 -i file.p12 | pbcopy
# The base64 string is now in your clipboard
```

### 2. Create an app-specific password for notarization

1. Sign in at https://appleid.apple.com/account/manage
2. Security → App-Specific Passwords → Generate
3. Label it `logic-pro-mcp-notary`
4. Save the generated password

### 3. Write secrets via `gh`

```bash
export REPO=MongLong0214/logic-pro-mcp

pbpaste | gh secret set MACOS_CERT_BASE64 --repo $REPO
gh secret set MACOS_CERT_PASSWORD --repo $REPO   # prompts
gh secret set MACOS_SIGNING_IDENTITY --repo $REPO --body "Developer ID Application: Your Name (TEAMID12)"
gh secret set MACOS_KEYCHAIN_PASSWORD --repo $REPO --body "$(openssl rand -base64 32)"
gh secret set APPLE_NOTARY_APPLE_ID --repo $REPO --body "your-email@example.com"
gh secret set APPLE_NOTARY_TEAM_ID --repo $REPO --body "TEAMID12"
gh secret set APPLE_NOTARY_APP_PASSWORD --repo $REPO --body "xxxx-xxxx-xxxx-xxxx"
```

### 4. Verify

```bash
gh secret list --repo $REPO
```

You should see all 7 secrets listed.

---

## Rotation policy

- **App-specific password** — rotate annually or when the Apple ID password changes
- **Developer ID certificate** — rotate when it expires (valid 5 years from issuance)
- **Keychain password** — rotate any time; no impact outside CI

Rotate by re-running the relevant `gh secret set` command.

---

## Local release dry-run

If you want to verify signing + notarization locally before configuring CI:

```bash
# 1. Build release
swift build -c release

# 2. Codesign
codesign --sign "Developer ID Application: Your Name (TEAMID12)" \
         --options runtime \
         --timestamp \
         .build/release/LogicProMCP

# 3. Package + notarize
ditto -c -k --keepParent .build/release/LogicProMCP /tmp/LogicProMCP.zip
xcrun notarytool submit /tmp/LogicProMCP.zip \
    --apple-id "your-email@example.com" \
    --team-id TEAMID12 \
    --password "xxxx-xxxx-xxxx-xxxx" \
    --wait

# 4. Staple
xcrun stapler staple .build/release/LogicProMCP

# 5. Verify
codesign --verify --verbose=4 .build/release/LogicProMCP
spctl --assess --type execute --verbose .build/release/LogicProMCP
```
