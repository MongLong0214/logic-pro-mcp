# Security Policy

This document describes the security posture of Logic Pro MCP Server, how to report vulnerabilities, and the security controls implemented in the codebase.

---

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Email security reports to the maintainer. Include:

1. Description of the vulnerability
2. Reproduction steps (including any sample input or MCP JSON-RPC payloads)
3. Impact assessment — what an attacker could accomplish
4. Your contact information

You should expect an initial response within 5 business days and a remediation plan within 30 days for P0/P1 issues.

---

## Threat Model

The MCP server runs locally as a subprocess of an MCP host (Claude Code, Claude Desktop). Input flows from an authenticated MCP client → the server → Logic Pro.

### Trust boundary

| Source | Trust | Notes |
|--------|-------|-------|
| MCP client (Claude) | Semi-trusted | Requests are from the user's AI assistant, but inputs may be influenced by external content |
| Logic Pro | Trusted | Apple-signed application |
| Virtual MIDI wire | Trusted | No external network path |

### Out of scope

- Network-level attacks: the server uses stdio transport only. There is no listening socket.
- macOS privilege escalation: the server runs with the same privileges as the MCP host. It cannot gain more.
- Logic Pro bugs: the server invokes documented Logic Pro features; we do not harden against Logic Pro's own vulnerabilities.

---

## Security Controls

### Path validation — `AppleScriptSafety`

All file paths passed to `project.open` and `project.save_as` must satisfy:

- Absolute path (begins with `/`)
- `.logicx` extension
- No control characters (`\n`, `\r`, `\t`, `\0`)
- Not under `/dev/`
- For `open`: directory must exist and contain `Resources/ProjectInformation.plist` and `Alternatives/*/ProjectData`

Validation occurs **before** any AppleScript or AX dialog interaction. See `Sources/LogicProMCP/Utilities/AppleScriptSafety.swift`.

### AppleScript injection prevention

- `project.open` uses `NSWorkspace.open(URL)` instead of AppleScript string interpolation. No user-controlled string reaches a script template.
- `project.close` / `project.save_as` / verification scripts interpolate the already-validated path and additionally strip `\n`, `\r` after escaping `\\` and `"`.
- `ServerConfig.logicProProcessName` and `logicProBundleID` are escaped before interpolation in `ProcessUtils.logicProPIDViaSystemEvents` and `PermissionChecker.runAutomationProbeViaShell`.
- `PermissionChecker` invokes `/usr/bin/osascript -e <script>` directly — no shell, no nested quoting.

### Input size caps

| Input | Cap | Location |
|-------|-----|----------|
| `midi.send_note.duration_ms` | 30,000 ms | `CoreMIDIChannel.swift` |
| `midi.send_chord.duration_ms` | 30,000 ms | `CoreMIDIChannel.swift` |
| `midi.step_input.duration_ms` | 30,000 ms | `CoreMIDIChannel.stepInputDurationMs` |
| `track.rename.name` | 255 chars | `AccessibilityChannel.defaultRenameTrack` |
| `midi.create_virtual_port.name` | 63 chars, newlines/nulls stripped | `CoreMIDIChannel.swift` |

Duration caps prevent an MCP client from hanging a channel actor with `UInt64.max` sleeps.

### MIDI packet bounds

`ProductionMCUTransport` processes incoming `MIDIEventList` packets. `wordCount` is bounded with `min(wordCount, 64)` (the declared `MIDIEventPacket.words` array length) before pointer arithmetic advances through the list. This prevents out-of-bounds reads if CoreMIDI delivers malformed UMP.

### MCP destructive operation policy

Destructive project operations (`quit`, `close`, `open`, `save_as`, `bounce`) require explicit `{ "confirmed": true }` in params. Without the flag they return a structured `confirmation_required` response. See `DestructivePolicy.swift`.

### Manual-validation approval gate

MIDIKeyCommands and Scripter channels cannot be programmatically verified as wired up in Logic Pro. They require operator approval via CLI:

```bash
LogicProMCP --approve-channel MIDIKeyCommands
LogicProMCP --approve-channel Scripter
```

Approvals are persisted in `~/Library/Application Support/LogicProMCP/operator-approvals.json`. Without approval, `ChannelRouter` skips those channels (they report `manual_validation_required`) and falls back.

### Graceful shutdown

SIGTERM / SIGINT are handled via `DispatchSource` in `MainEntrypoint`. The server releases virtual MIDI ports and stops channels before exit.

### Concurrency safety

All mutable state lives behind Swift actors (`ChannelRouter`, `StateCache`, `MIDIPortManager`, every channel). Swift 6 strict-concurrency mode is enforced at the compile level. Two explicitly-audited `@unchecked Sendable` surfaces exist:

- `LogicProServerRuntimeOverrides` — documented test-only injection seam
- `ServerRuntimePlan` — executed serially and immediately inside `start()`

The one `nonisolated(unsafe)` variable (`pidProcessListCache` in `ProcessUtils`) is protected by `NSLock`.

---

## Deployment security

Release binaries are:

1. Built on `macos-15` runners via GitHub Actions
2. Codesigned with a Developer ID Application certificate
3. Notarized via `notarytool` (Apple)
4. Stapled so they run without Gatekeeper prompts
5. Verified with `spctl` post-signing
6. Checksummed (SHA256) and published with `RELEASE-METADATA.json`

See `.github/workflows/release.yml` and `docs/release/RELEASE-RUNBOOK.md`.

### Installation verification

Users can verify the signature:

```bash
codesign --verify --verbose=4 /usr/local/bin/LogicProMCP
spctl --assess --type execute --verbose /usr/local/bin/LogicProMCP
shasum -a 256 /usr/local/bin/LogicProMCP
```

### Supply-chain hardening (v2.3.0+)

`Scripts/install.sh` enforces **pinned SHA256** verification by default:

1. Downloads the binary from `releases/download/$VERSION/LogicProMCP`
2. Fetches `SHA256SUMS.txt` from the same release
3. Recomputes SHA256 of the downloaded binary
4. **Aborts on mismatch** before writing anything to the install path
5. Additionally verifies `codesign --verify --strict` and `spctl --assess --type execute`
6. Pins the expected `TeamIdentifier` against `RELEASE-METADATA.json`

**Known residual risk**: A compromised GitHub release can tamper with the binary, SHA256SUMS.txt, and RELEASE-METADATA.json in lockstep (see `docs/tickets/installer-supply-chain/STATUS.md`). Mitigate with **out-of-band verification**:

```bash
# Override with a hash obtained from a trusted second channel
# (Homebrew tap, maintainer's signed commit, corporate vault):
LOGIC_PRO_MCP_SHA256="<known-good-hash>" \
LOGIC_PRO_MCP_TEAM_ID="<expected-team-id>" \
bash Scripts/install.sh
```

For the strongest guarantee, enterprise deployments should pin the hash in a configuration management system (Jamf profile, Ansible vault, MDM), not trust the GitHub-hosted `SHA256SUMS.txt` as the root of trust.

---

## Security Audit History

| Date | Scope | Findings | Outcome |
|------|-------|----------|---------|
| 2026-04-11 | Full codebase — channels, dispatchers, state, utilities | P0: 1, P1: 3, P2: 5 | All 9 issues remediated in v2.1.0 |

See `CHANGELOG.md` v2.1.0 entry for per-finding details.

---

## Known limitations

- The server trusts the MCP host's identity — there is no authentication between the MCP client and server beyond the stdio pipe.
- The destructive-operation gate protects against accidental calls but is not a security control against a malicious MCP host that sets `confirmed: true` directly.
- AX-based reads of track/project data may surface arbitrary UI text (track names are user-controlled). Callers rendering that text should apply their own output escaping.
