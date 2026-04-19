# Maintainer Guide

Operator and maintainer reference. End users do not need to read this — start with [SETUP.md](SETUP.md) instead.

## Support Matrix

| Area | Supported |
|------|-----------|
| macOS | 14+ (Sonoma, Sequoia) |
| Logic Pro | 12.0.1+ |
| Architectures | `arm64` (primary), `x86_64` (from source) |
| MCP clients | Claude Code, Claude Desktop |

## Manual-validation Channels

Two channels (`MIDIKeyCommands`, `Scripter`) cannot be verified programmatically — Logic Pro's preset import and Scripter insertion are not introspectable. They start as `manual_validation_required` and are excluded from routing until explicitly approved.

Approve after manual validation:

```bash
LogicProMCP --approve-channel MIDIKeyCommands --approval-note "Imported preset in Logic Pro"
LogicProMCP --approve-channel Scripter --approval-note "Validated Scripter insertion"
```

List / revoke:

```bash
LogicProMCP --list-approvals
LogicProMCP --revoke-channel MIDIKeyCommands
LogicProMCP --revoke-channel Scripter
```

Revoke whenever the preset is removed, the Scripter instance is removed, or the Logic template is reset.

## Release Process

### Adhoc release (no Apple Developer Program)

```bash
swift build -c release
codesign --force --sign - .build/release/LogicProMCP
VERSION=v2.3.1
shasum -a 256 .build/release/LogicProMCP | awk '{print $1"  LogicProMCP"}' > SHA256SUMS.txt
echo '{"version":"'$VERSION'","team_id":"ADHOC","signing":"adhoc"}' > RELEASE-METADATA.json

gh release create $VERSION \
  .build/release/LogicProMCP \
  SHA256SUMS.txt \
  RELEASE-METADATA.json
```

The installer recognises `team_id: ADHOC` and skips Gatekeeper assessment while keeping SHA256 + codesign verification.

### Notarized release (requires Apple Developer Program, $99/year)

Preconditions — GitHub Actions secrets configured:

- `MACOS_CERT_BASE64` — Developer ID Application certificate, .p12 → base64
- `MACOS_CERT_PASSWORD` — .p12 unlock password
- `MACOS_SIGNING_IDENTITY` — e.g. `Developer ID Application: Your Name (TEAMID)`
- `MACOS_KEYCHAIN_PASSWORD` — random, used for the ephemeral build keychain
- `APPLE_NOTARY_APPLE_ID` — Apple ID email
- `APPLE_NOTARY_TEAM_ID` — 10-character Team ID
- `APPLE_NOTARY_APP_PASSWORD` — app-specific password from appleid.apple.com

Release:

```bash
git tag v2.3.1
git push origin v2.3.1
```

`.github/workflows/release.yml` builds a universal binary, signs, notarizes, staples, and publishes to a GitHub release with full signature validation in a downstream install job.

## E2E Validation Checklist

After any release, exercise these against live Logic Pro 12:

1. `logic_system.health` — all 7 channels `ready`
2. `logic_transport.play` / `.stop`
3. `logic_tracks.select` / `.record_sequence` → verify region at expected bar
4. `logic_mixer.set_volume` / `.set_pan` / `.set_plugin_param`
5. `logic_edit.undo` / `.redo`
6. `logic_project.open` (with `confirmed: true`)
7. `logic_navigate.goto_bar` / `.goto_marker` by name
8. `logic_system.health` — recheck after operations

Evidence to capture for a release:

- Screen recording of Logic Pro showing expected region placement
- `LogicProMCP --check-permissions` output
- `LogicProMCP --list-approvals` output
- `logic_system.health` JSON payload

## Destructive Operation Policy

Operations that can lose work (`quit`, `close`, `open`, `save_as`, `bounce`) require `{ "confirmed": true }` in the MCP call. Without the flag they return a structured `confirmation_required` response. See `Sources/LogicProMCP/Utilities/DestructivePolicy.swift`.
