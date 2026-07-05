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

`project.save_as` also performs a post-write readback before returning State A: the target `.logicx` package must exist, and an existing package's modification time must advance or be at least as new as the save start time. Missing or stale package readback returns State C `readback_mismatch`.

### MIDI import path boundary

`logic_midi.import_file` / `midi.import_file` drives Logic's MIDI File import dialog, so its path boundary is stricter than ordinary project paths. The requested path is rejected unless all of the following hold:

- No control characters
- Resolves, after symlink cleanup and standardization, to a `.mid` path
- Sits under `/tmp/LogicProMCP/`
- Exists as a regular file, not a directory

This prevents raw MCP callers from steering the AX open panel toward arbitrary user files.

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
| `midi.import_file.path` | Real `.mid` under `/tmp/LogicProMCP/` after symlink resolution | `AccessibilityChannel.validatedMIDIImportPath` |

Duration caps prevent an MCP client from hanging a channel actor with `UInt64.max` sleeps.

### MIDI packet bounds

`ProductionMCUTransport` processes incoming `MIDIEventList` packets. `wordCount` is bounded with `min(wordCount, 64)` (the declared `MIDIEventPacket.words` array length) before pointer arithmetic advances through the list. This prevents out-of-bounds reads if CoreMIDI delivers malformed UMP.

### MCP destructive operation policy

Destructive project operations (`quit`, `close`, `open`, `save_as`, `bounce`) require explicit `{ "confirmed": true }` in params. Without the flag they return a structured `confirmation_required` response. See `DestructivePolicy.swift`.

### Verified plugin apply-back gate

`logic_plugins` is the v3.6.0+ verified apply-back surface and remains unchanged as a security boundary in v3.8.0. Its mutating commands (`insert_verified`, `set_param_verified`) are scoped to `mode:"duplicate_applyback"` and require an explicit `project_expected_path`. The server reads the live front Logic project path at call time and returns State C `project_identity_mismatch` before any write if the document changed.

The insert path is fail-closed:

- target track selection must verify before the write boundary;
- `get_inventory` must report a complete, readable physical insert chain;
- the requested physical slot must be empty;
- the slot popup must be spatially anchored to the requested slot before any plugin leaf is clicked;
- State A is emitted only after post-write inventory readback observes the requested plugin at the requested slot.

Unknown plugin aliases, unsupported parameters, unreadable inventory, unanchored popups, wrong-slot mounts, and rollback failures all return HC v2 State C with `verified:false`. The router treats these codes as terminal and never falls back to Scripter, MCU, or a best-effort macro path.

### Manual-validation approval gate

MIDIKeyCommands and Scripter channels cannot be programmatically verified as wired up in Logic Pro. They require operator approval via CLI:

```bash
LogicProMCP --approve-channel MIDIKeyCommands
LogicProMCP --approve-channel Scripter
```

Approvals are persisted in `~/Library/Application Support/LogicProMCP/operator-approvals.json`. Without approval, `ChannelRouter` skips those channels (they report `manual_validation_required`) and falls back.

### Permission verification honesty (tri-state)

`--check-permissions`, `logic_system health`, and `doctor` report each TCC grant as a **three-state** value — `granted`, `not_granted`, or `not_verifiable` — rather than a Bool. This is a deliberate fail-closed-vs-honest distinction: a probe that *ran and was denied* reports `not_granted`, but a probe that could not complete (it timed out or failed to spawn) reports `not_verifiable` — an infrastructure failure is **not** the same as a denial. Collapsing the latter into a false "Automation NOT GRANTED" (the pre-v3.8.0 behavior) would have misdirected an operator into re-granting an already-correct permission while hiding the real fault. Security posture: the readiness gate still refuses to report green for a capability the server cannot use, but it never fabricates a denial it did not observe.

### Graceful shutdown

SIGTERM / SIGINT are handled via `DispatchSource` in `MainEntrypoint`. The server releases virtual MIDI ports and stops channels before exit.

### Concurrency safety

All mutable state lives behind Swift actors (`ChannelRouter`, `StateCache`, `MIDIPortManager`, every channel). Swift 6 strict-concurrency mode is enforced at the compile level. Two explicitly-audited `@unchecked Sendable` surfaces exist:

- `LogicProServerRuntimeOverrides` — documented test-only injection seam
- `ServerRuntimePlan` — executed serially and immediately inside `start()`

The one `nonisolated(unsafe)` variable (`pidProcessListCache` in `ProcessUtils`) is protected by `NSLock`.

---

## Deployment security

Release binaries ship in **ADHOC mode** unless Apple Developer Program credentials are explicitly configured for the workflow (see §Release types below). When Developer ID credentials are available, releases are:

1. Built on `macos-15` runners via GitHub Actions
2. Codesigned with a Developer ID Application certificate
3. Notarized via `notarytool` (Apple)
4. Stapled so they run without Gatekeeper prompts
5. Verified with `spctl` post-signing
6. Checksummed (SHA256) and published with `RELEASE-METADATA.json`

Without those credentials, ADHOC releases provide SHA256 + codesign verification while skipping Gatekeeper assessment.

See `.github/workflows/release.yml` and `CONTRIBUTING.md`.

### Installer trust model

Three supported install paths, in descending order of trust:

| Path | What signs the script | What signs the binary | Recommended for |
|------|----------------------|----------------------|-----------------|
| **Homebrew tap** | Homebrew's own signature chain over the formula | Formula pins both URL + SHA256 | Production |
| **Download-inspect-run** | You inspect the script locally before executing it | `LOGIC_PRO_MCP_SHA256` + TeamID env overrides | Security-sensitive deployments |
| **`bash <(curl ...)` one-liner** | ⚠️ No signature — script is fetched fresh on every run | `LOGIC_PRO_MCP_SHA256` + TeamID env overrides | Casual/single-user installs |

The env-var overrides (`LOGIC_PRO_MCP_SHA256`, `LOGIC_PRO_MCP_TEAM_ID`) protect the **downloaded binary** against tampering of the GitHub release surface. They do **not** cover the installer script itself when piped through `bash`. If the installer script in the repo is compromised, `bash <(curl ...)` will execute the compromised script before any pin check runs.

For hardened installs, prefer Homebrew (Option A in README) or the download-inspect-run pattern:

```bash
curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/<release-tag>/Scripts/install.sh -o install.sh
# inspect install.sh
shasum -a 256 install.sh    # cross-check against a trusted second channel
LOGIC_PRO_MCP_SHA256=<hex> LOGIC_PRO_MCP_TEAM_ID=ADHOC bash install.sh
```

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
5. Additionally verifies `codesign --verify --strict` and `spctl --assess --type execute` — UNLESS this is an **ADHOC release**, in which case `spctl` is skipped (see below).
6. Pins the expected `TeamIdentifier` against `RELEASE-METADATA.json`

### Release types

Two release modes exist depending on whether Apple Developer Program credentials are configured for the build:

| Mode | TeamID | codesign | spctl / Gatekeeper | SHA256 | Quarantine xattr |
|------|--------|----------|-------------------|--------|------------------|
| **Notarized** (optional) | Developer ID | strict check | assess required | pinned | not applied (stapled) |
| **ADHOC** (current) | `ADHOC` literal | strict check | skipped | pinned | stripped by installer |

ADHOC releases are signed with an ephemeral adhoc identity (`codesign --sign -`). They cannot pass Gatekeeper assessment because they are not notarized by Apple. The installer recognises `LOGIC_PRO_MCP_TEAM_ID=ADHOC` (or `team_id` in `RELEASE-METADATA.json`) and:

- Skips `spctl --assess`
- Still runs `codesign --verify --strict` (detects tampering post-signing)
- Still enforces SHA256 pin (detects tampering in transit)
- Strips `com.apple.quarantine` from the installed binary so it runs on first launch

**Trust model for ADHOC**: root of trust is the SHA256 hash published in `SHA256SUMS.txt` in the same GitHub release. A compromise of the release asset would change the hash and the installer would abort. Enterprise operators can supply a hash out-of-band via `LOGIC_PRO_MCP_SHA256=...`.

**Known residual risk**: A compromised GitHub release can tamper with the binary, SHA256SUMS.txt, and RELEASE-METADATA.json in lockstep (see the release workflow and `CONTRIBUTING.md`). Mitigate with **out-of-band verification**:

```bash
# Override with a hash obtained from a trusted second channel
# (Homebrew tap, maintainer's signed commit, corporate vault):
LOGIC_PRO_MCP_SHA256="<known-good-hash>" \
LOGIC_PRO_MCP_TEAM_ID="<expected-team-id>" \
bash Scripts/install.sh
```

For the strongest guarantee, enterprise deployments should pin the hash in a configuration management system (Jamf profile, Ansible vault, MDM), not trust the GitHub-hosted `SHA256SUMS.txt` as the root of trust.

### Notarization posture (M3)

An ADHOC release gives **integrity, not authenticity**. `codesign --verify --strict` plus the pinned SHA256 prove the binary was not altered after signing or in transit, but an adhoc signature (`codesign --sign -`) carries no Apple-verified identity — anyone can produce one, so it does not attest *who* built the artifact. Therefore, on the ADHOC line, the only enterprise-grade install is an **out-of-band-pinned** one: supply `LOGIC_PRO_MCP_SHA256` and `LOGIC_PRO_MCP_TEAM_ID` from a trusted second channel (Homebrew tap, corporate vault, MDM profile) so the root of trust is not the same GitHub release surface being verified. A notarized path exists in the release workflow and is used automatically when Apple Developer ID credentials are configured; when they are absent the project ships ADHOC by design. (The release-signing decision may be revisited in a future release-preparation pass.)

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
- `logic_plugins.set_param_verified` currently verifies only Compressor `threshold`; callers must treat unsupported-plugin/unsupported-param State C responses as hard failures rather than retrying through unverified channels.
