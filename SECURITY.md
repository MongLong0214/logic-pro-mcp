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

The MCP server runs locally as a subprocess of an MCP host (Claude Code, Claude Desktop, Cursor, VS Code, Terminal, or a custom stdio client). Input flows from an authenticated MCP client -> the server -> Logic Pro.

### Trust boundary

| Source | Trust | Notes |
|--------|-------|-------|
| MCP client/host | Semi-trusted | Requests are from the user's AI assistant or automation host, but inputs may be influenced by external content |
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

v3.12.0 hardens filesystem-adjacent server paths: the trace-clear audit receipt and support-bundle publish are descriptor-relative, no-follow, identity-checked, and crash-durable (#417); saga execution runs under a single bounded lifecycle deadline with gate-ownership checks so a timed-out predecessor can never resume mutating (#412); session-stable `target_ref` writes carry live-identity cross-checks that fail closed on ambiguous or wrong-target resolution (#285); and the release pipeline adds an import-closure gate so a packaged Python helper can never ship without its transitive local modules (#427).

`logic_plugins` is the v3.6.0+ verified apply-back surface and remains unchanged as a security boundary in v3.12.0. Its mutating commands (`insert_verified`, `set_param_verified`) are scoped to `mode:"duplicate_applyback"` and require an explicit `project_expected_path`. The server reads the live front Logic project path at call time and returns State C `project_identity_mismatch` before any write if the document changed. `set_param_verified` may open the requested insert's plugin editor when it is closed, but it still returns State C with `write_attempted:false` if the acquired window does not expose the requested AX slider.

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

`--check-permissions`, `logic_system health`, and `doctor` report each TCC grant as a **three-state** value — `granted`, `not_granted`, or `not_verifiable` — rather than a Bool. The readiness set covers Accessibility, Automation to Logic Pro, Automation to System Events, and trusted PostEvent access. This is a deliberate fail-closed-vs-honest distinction: a probe that *ran and was denied* reports `not_granted`, but a probe that could not complete (it timed out or failed to spawn) reports `not_verifiable` — an infrastructure failure is **not** the same as a denial. Collapsing the latter into a false "Automation NOT GRANTED" (the pre-v3.8.0 behavior) would have misdirected an operator into re-granting an already-correct permission while hiding the real fault. Security posture: the readiness gate still refuses to report green for a capability the server cannot use, but it never fabricates a denial it did not observe.

### Graceful shutdown

SIGTERM / SIGINT are handled via `DispatchSource` in `MainEntrypoint`. The server releases virtual MIDI ports and stops channels before exit.

### Concurrency safety

All mutable state lives behind Swift actors (`ChannelRouter`, `StateCache`, `MIDIPortManager`, every channel). Swift 6 strict-concurrency mode is enforced at the compile level. Two explicitly-audited `@unchecked Sendable` surfaces exist:

- `LogicProServerRuntimeOverrides` — documented test-only injection seam
- `ServerRuntimePlan` — executed serially and immediately inside `start()`

The one `nonisolated(unsafe)` variable (`pidProcessListCache` in `ProcessUtils`) is protected by `NSLock`.

---

## Deployment security

Releases are built with Command Line Tools and published without an Apple signing or notarization
step. The release workflow packages the exact release build, verifies the archive manifest, checks
SHA256 again after artifact transfer, and installs the archive on supported macOS runners before
publication.

### Installer trust model

The Homebrew Formula pins the release URL and SHA256. The shell installer likewise requires
`LOGIC_PRO_MCP_SHA256` by default and verifies the archive before extraction or installation.
Operators should obtain that hash through a channel they trust:

```bash
curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/<release-tag>/Scripts/install.sh -o install.sh
# Inspect the script and obtain the archive hash independently.
LOGIC_PRO_MCP_SHA256=<known-good-archive-hash> bash install.sh
```

`LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1` is an explicit convenience mode that fetches
`SHA256SUMS.txt` from the same GitHub release as the archive. It detects transfer corruption but
does not protect against compromise of that release surface. Piping a remote installer directly
to a shell also executes it before any archive check; download and inspect it first for sensitive
deployments.

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
