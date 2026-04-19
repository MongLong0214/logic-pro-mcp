# Maintainer Guide

Operator and maintainer reference. End users do not need to read this — start with [SETUP.md](SETUP.md) instead.

## Support Matrix

| Area | Supported |
|------|-----------|
| macOS | 14+ (Sonoma, Sequoia) |
| Logic Pro | 12.0.1+ |
| Architectures | Universal binary — `arm64` + `x86_64` in one fat artifact |
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
VERSION=v3.0.0
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
git tag v3.0.0
git push origin v3.0.0
```

`.github/workflows/release.yml` builds a universal binary, signs, notarizes, staples, and publishes to a GitHub release with full signature validation in a downstream install job.

### Post-tag steps (both release modes)

After the GitHub release is published, the Homebrew formula still points at the **old** tarball SHA256. Update it:

```bash
VERSION=v3.0.0
curl -fsSL "https://github.com/MongLong0214/logic-pro-mcp/releases/download/$VERSION/SHA256SUMS.txt" \
    | awk '$2 == "LogicProMCP-macOS-universal.tar.gz" {print $1}'
# copy the hex into Formula/logic-pro-mcp.rb `sha256 "…"`
```

Commit the formula update as a separate follow-up (it is not on the tag). Users installing via `brew install` against the tap will then resolve to the newly-published artifact.

If you also maintain a private Homebrew tap, publish the formula update there.

### Environment variables (runtime)

| Variable | Scope | Purpose |
|----------|-------|---------|
| `LOG_LEVEL` | Server | `debug`/`info`/`warn`/`error`. Default `info`. |
| `LOG_FORMAT` | Server | `json` for one-line structured logs (machine-parseable), otherwise plain text (default). |
| `LOGIC_PRO_MCP_LIBRARY_INVENTORY` | Server | Absolute path to a pre-scanned `library-inventory.json`. Overrides the `<CWD>/Resources/…` and `~/Library/Application Support/LogicProMCP/…` lookup order. Symlinks are resolved and validated (must be a regular `.json` file ≤ 64 MiB) before reading. |
| `LOGIC_PRO_MCP_SHA256` | Installer | Pin the expected binary SHA256 out-of-band (do not rely on same-origin `SHA256SUMS.txt`). |
| `LOGIC_PRO_MCP_TEAM_ID` | Installer | Pin the expected codesign Team Identifier (e.g. `ADHOC` or a 10-char Apple Team ID). |
| `LOGIC_PRO_MCP_VERSION` | Installer | Override the pinned release tag (default is the installer's baked-in version). |

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
