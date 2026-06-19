<p align="center">
  <img src="https://img.shields.io/badge/Logic_Pro-MCP_Server-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Logic Pro MCP Server" />
</p>

<p align="center">
  <strong>The missing agent control plane for Logic Pro.</strong><br/>
  A production-oriented MCP server that lets Claude, Cursor, and custom MCP agents operate Logic Pro with state, provenance, and fail-closed safety gates.
</p>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.0+-F05138.svg?style=flat-square" /></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14+-000000.svg?style=flat-square&logo=apple" /></a>
  <a href="https://modelcontextprotocol.io"><img src="https://img.shields.io/badge/MCP-0.10-blue.svg?style=flat-square" /></a>
  <a href="https://github.com/MongLong0214/logic-pro-mcp/actions/workflows/ci.yml"><img src="https://github.com/MongLong0214/logic-pro-mcp/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" /></a>
  <img src="https://img.shields.io/badge/tests-1396_passing-brightgreen.svg?style=flat-square" />
  <img src="https://img.shields.io/badge/stable-v3.6.0-blue.svg?style=flat-square" />
</p>

<p align="center">
  <a href="docs/media/logic-pro-mcp-demo.mp4">
    <img src="docs/media/logic-pro-mcp-demo.gif" alt="6 second actual Logic Pro 12.2 screen capture showing live playback, moving playhead, meters, MCP-created MIDI regions, and live track headers" width="920" />
  </a>
</p>

<p align="center">
  Actual Logic Pro 12.2 capture, cropped from a live playback recording.<br/>
  <a href="docs/media/logic-pro-mcp-demo.mp4">6 sec MP4</a> ·
  <a href="docs/media/logic-pro-mcp-thumbnail.png">social thumbnail</a>
</p>

---

Logic Pro does not ship a first-party API for agentic composition, session setup, mixer operations, or live project readback. Logic Pro MCP fills that gap by combining **7 native macOS control channels** behind one MCP interface, then wrapping every high-risk operation in explicit state, confirmation, and verification contracts.

The result is not "screen automation with prompts." It is a structured server for DAW agents: tools mutate, resources read, evidence is labeled, and uncertain outcomes stay uncertain instead of being reported as success.

```
You: "Make a 4-bar techno loop in A minor at 140 BPM"

MCP client → logic_tracks.record_sequence {
  bar: 1, tempo: 140,
  notes: "45,0,95;57,107,95;45,214,95;..."
}
MCP client → logic_tracks.set_instrument {
  index: 0, path: "Electronic Drums/Roland TR-909"
}

Logic Pro MCP: region imported, instrument routed, readback exposed through resources.
```

## At a Glance

| Surface | Current source tree |
|---------|---------------------|
| MCP tools | 9 tools covering transport, tracks, mixer, MIDI, edit, navigation, project lifecycle, system health, and verified plugin apply-back |
| Read resources | 14 static resources for health, transport, tracks, mixer, markers, project metadata, MIDI ports, MCU state, library inventory, stock plugin intelligence, and workflow skills |
| Resource templates | 7 templates for track, region, mixer-strip, stock plugin detail/search, and workflow detail/search lookup |
| Control channels | MCU, Accessibility, AppleScript, CoreMIDI, CGEvent, Scripter, MIDI Key Commands |
| Verification line | v3.6.0 release tree: `1396` Swift tests, release build, targeted Logic Pro 12.2 exact-slot plugin insert proof, strict live E2E, and live tracks-resource readback |
| Release state | Published stable `v3.6.0`; previous stable `v3.5.0` remains available for pinned installs |

If this project helps you make music with Claude, Cursor, or any MCP client, star the repo. It helps the project reach more Logic Pro users and maintainers.

## Why It Exists

Most Logic Pro automation attempts fall into one of three traps:

1. **Prompt-only recipes** that drift away from the real tool surface.
2. **Keyboard macro automation** that can click the wrong target and still look successful.
3. **Single-channel control** that can write to Logic but cannot reliably read what Logic actually did.

Logic Pro MCP uses a different model. It routes each operation to the strongest available channel, exposes live state through MCP resources, and forces callers to handle three outcomes: confirmed, uncertain, or failed.

## What It Controls

| Area | What agents can do | Safety/readback model |
|------|--------------------|-----------------------|
| Transport | Play, stop, record, locate, cycle, metronome, tempo | CoreMIDI/AX routing with live `logic://transport/state` readback |
| Tracks | Create, delete, duplicate, select, rename, mute, solo, arm, set instruments | Mutating targets require explicit index/name; uncertain selection fails closed before writes |
| MIDI composition | Generate SMF server-side, import MIDI, send notes/CC/MMC, create virtual ports | `.mid` imports are constrained to `/tmp/LogicProMCP/` and must create a live track |
| Mixer | Volume, pan, plugin snapshots, guarded stock plugin insertion | MCU writes plus AX readback/provenance; occupied plugin slots refuse replacement |
| Library | Scan Logic's instrument library and load patches by path | Disk/AX inventory is cached and path-allowlisted |
| Navigation | Bars, markers, zoom, view toggles | Marker navigation is target-faithful; cold-cache misses return failure instead of "next marker" |
| Project lifecycle | New, open, save, save-as, close, bounce, quit | Destructive operations require confirmation; saves verify package existence/mtime |

## Agent-Grade Surfaces

**Tools are for actions.** The public write surface is intentionally small: `logic_transport`, `logic_tracks`, `logic_mixer`, `logic_plugins`, `logic_midi`, `logic_edit`, `logic_navigate`, `logic_project`, and `logic_system`.

**Resources are for state.** Clients should read `logic://transport/state`, `logic://tracks`, `logic://mixer`, `logic://project/info`, `logic://midi/ports`, and related resources instead of burning tool calls on polling.

**Evidence is separated from claims.** The README points to release evidence, current-main verification, and live media artifacts instead of implying that a successful command equals a verified Logic state.

## Trust Model

- **Honest Contract envelopes**: mutating operations return State A confirmed, State B uncertain with a reason, or State C failure with an error.
- **Verified plugin apply-back**: `logic_plugins.*` uses HC v2 (`hc_schema: 2`) and returns State A only after project identity, target track, physical insert slot, plugin identity, and readback all agree.
- **Fail-closed targets**: dangerous mixer, marker, track, MIDI import, and plugin operations require explicit targets and validation.
- **Confirmation levels**: destructive/project and plugin insertion flows require explicit confirmation metadata before execution.
- **Provenance labels**: read surfaces expose source, freshness, and evidence labels instead of forcing clients to guess.
- **Installer hardening**: Homebrew pins SHA256; the shell installer refuses to run without explicit hash/team pins unless same-origin provenance is explicitly allowed.
- **Release honesty**: published `v3.6.0` is the current stable install line, and README claims stay tied to shipped artifacts, release-tree tests, or explicitly linked live evidence.

## Quick Start

**Prerequisites**: macOS 14+, Logic Pro 12.0.1+, and an MCP client that can launch a stdio server. Published GitHub Actions/Homebrew assets are universal (`arm64` + `x86_64`) and do not require Xcode.

The package manifest uses Swift tools 6.0 for compatibility. Current source verification uses Xcode 16.4 / Swift 6.2 in CI.

The current published stable release is `v3.6.0` (2026-06-19 KST). It ships ADHOC-signed universal artifacts when Apple Developer ID credentials are absent, plus `SHA256SUMS.txt` and `RELEASE-METADATA.json` for pinned installs. It includes the PR #24 verified plugin apply-back surface and the Logic 12.2 track/transport AX readback fixes.

### 1. Install

```bash
brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp
brew trust monglong0214/logic-pro-mcp   # Homebrew 6.0+ requires trusting third-party taps
brew install logic-pro-mcp
```

The Homebrew formula pins both the release tarball URL and its SHA256; Homebrew itself is a trusted delivery channel with its own signature chain. This is the hardened path for production installs. (On Homebrew older than 6.0 the `brew trust` step does not exist — skip it.)

For source-tree development, build locally:

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
```

### 2. Register with an MCP client

Claude Code:

```bash
claude mcp add --scope user logic-pro -- LogicProMCP
```

Generic MCP client config:

```json
{
  "mcpServers": {
    "logic-pro": {
      "command": "LogicProMCP"
    }
  }
}
```

If you built from source, point the command at `.build/release/LogicProMCP`.

### 3. Complete Logic Pro setup

Run the local checks:

```bash
LogicProMCP --check-permissions
```

Then complete the two Logic-side setup steps in [docs/SETUP.md](docs/SETUP.md):

- Register the `LogicProMCP-MCU-Internal` MCU control surface.
- Add the bundled Scripter insert if you need plugin-parameter writes.

Logic 12.2+ does not auto-import the legacy Key Commands plist; the bundled preset is staged as a Manual MIDI Learn reference.

### 4. Test from your agent

Ask the client:

> Check Logic Pro MCP health and show all ready channels.

Expected: all 7 channels `ready` after full setup, or 5 if you intentionally skipped Key Commands and Scripter.

### Pinned shell installer

The installer is **fail-closed**: it refuses to run without explicit `LOGIC_PRO_MCP_SHA256` + `LOGIC_PRO_MCP_TEAM_ID` env pins. Inspect the script first, then execute with the pins copied from the release's `SHA256SUMS.txt`:

```bash
curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v3.6.0/Scripts/install.sh -o install.sh
# inspect install.sh, then:
LOGIC_PRO_MCP_SHA256=<paste from release SHA256SUMS.txt> \
LOGIC_PRO_MCP_TEAM_ID=<paste team_id from RELEASE-METADATA.json> \
bash install.sh
```

If you knowingly accept same-origin provenance (hash + Team ID fetched from the same release as the binary), opt in explicitly:

```bash
LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1 \
bash <(curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v3.6.0/Scripts/install.sh)
```

See [SECURITY.md §Installer trust model](SECURITY.md#installer-trust-model) for the trust tiers and threat model.

## Architecture at a Glance

<p align="center">
  <img src="docs/media/logic-pro-mcp-architecture.svg" alt="Logic Pro MCP architecture diagram showing MCP clients, the Swift server, tools, resources, state cache, ChannelRouter, native macOS channels, and Logic Pro" width="920" />
</p>

See [Architecture](docs/ARCHITECTURE.md) for channel priorities, state flow, cache freshness, and live E2E topology.

## Documentation

| Document | Audience | Purpose |
|----------|----------|---------|
| [Setup Guide](docs/SETUP.md) | End users | One-page install + Logic Pro integration, ~10 min |
| [API Reference](docs/API.md) | End users, MCP clients | All 9 tools, 14 resources, 7 templates, 130+ operations |
| [Verified Apply-Back Guide](docs/guides/verified-apply-back.md) | Agent workflow authors | `logic_plugins` inventory, exact-slot insertion, Compressor threshold write/readback, HC v2 failure handling |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | End users | Common failures and fixes |
| [Architecture](docs/ARCHITECTURE.md) | Contributors | Channel design, state flow, testing strategy |
| [Maintainer Guide](docs/MAINTAINERS.md) | Maintainers | Release, approvals, E2E checklist |
| [Live Verify v3.6.0](docs/live-verify-v3.6.0.md) | Maintainers, QA | Release-tree evidence for PR #24 + Logic 12.2 AX readback fixes |
| [Live Verify v3.5.0](docs/live-verify-v3.5.0.md) | Maintainers, QA | Previous stable deterministic, coverage, release-build, packaging, and fresh Logic Pro 12.2 strict live E2E evidence |
| [Security Policy](SECURITY.md) | Security reviewers | Threat model, reporting, hardening |
| [Changelog](CHANGELOG.md) | Everyone | Per-release changes |
| [Contributing](CONTRIBUTING.md) | Contributors | Dev setup, PR workflow |

## Status

**Published stable**: `v3.6.0` is available as a GitHub Release and Homebrew install. It ships PR #24 (`logic_plugins` verified plugin apply-back) plus the PR #54 / issue #59 Logic 12.2 AX readback hardening. Published metadata remains `team_id:"ADHOC"` / `signing:"adhoc"` when Developer ID credentials are absent, with universal `x86_64` + `arm64` artifacts produced by GitHub Actions.

**Previous stable**: `v3.5.0` remains available as a pinned GitHub Release for clients that need the Issue #14/#15 stock-plugin intelligence and workflow-skills surface without the new `logic_plugins` apply-back tool.

## Verification

| Gate | Current evidence |
|------|------------------|
| Full deterministic suite | v3.6.0 release tree: `swift test --no-parallel` -> `1396` passed, `0` failed |
| Release build | v3.6.0 release tree: `swift build -c release` passed |
| Python E2E syntax | PR #24 verification: `python3 -m py_compile Scripts/live-e2e-test.py` passed |
| Targeted live plugin proof | Logic Pro 12.2: `logic_plugins.insert_verified track=6 insert=6 plugin=Gain` returned State A with `observed_slot:6`, `write_source:"ax_exact_slot_popup"`, and independent `get_inventory` readback |
| Track/transport readback proof | Logic Pro 12.2: `logic://tracks` returned `source:"ax_live"`, real names, `placeholder_count:0`, `unknown_type_count:0`; cycle toggle/resource roundtrip reflected live UI state |
| Strict live Logic Pro 12.2 | v3.6.0 release tree: `314` passed, `0` skipped, `0` failed; see [docs/live-verify-v3.6.0.md](docs/live-verify-v3.6.0.md) |
| README media evidence | Actual Logic Pro 12.2 capture derivatives regenerate from `docs/media/logic-pro-mcp-demo.mp4`; `docs/media/render-demo.py` contains no synthetic DAW renderer |
| v3.6.0 release evidence | [docs/live-verify-v3.6.0.md](docs/live-verify-v3.6.0.md) |
| v3.5.0 previous release evidence | [docs/live-verify-v3.5.0.md](docs/live-verify-v3.5.0.md) |

Live E2E defaults to the release binary. Protocol/security assertions run on any host; Logic/CoreMIDI-dependent checks skip unless a real Logic Pro session is visible. Strict mode converts live-gated skips to failures, treats missing project state as a failed cycle roundtrip precondition, and launches the MCP server under a trusted shell/tmux parent so macOS TCC evaluates the same parent context used by live client flows.

## API Contracts That Matter

- **Honest Contract envelope** — every mutating op returns State A confirmed, State B uncertain with `reason`, or State C hard failure with `error`. See [docs/HONEST-CONTRACT.md](docs/HONEST-CONTRACT.md).
- **HC v2 plugin apply-back** — `logic_plugins.get_inventory`, `set_param_verified`, and `insert_verified` add `state` + `hc_schema: 2`; State C always carries `verified:false`, `write_attempted`, retry safety, and target identity where relevant.
- **Fail-closed mutation targets** — mixer faders, plugin params, marker delete/rename, track delete/duplicate, and MIDI imports require explicit target parameters.
- **Exact-slot plugin insertion** — `logic_plugins.insert_verified` targets the physical insert index returned by `get_inventory`, verifies the popup is anchored to that slot, and confirms success only by post-write inventory diff.
- **Target-faithful navigation** — `goto_marker` returns `element_not_found` on a cold cache instead of advancing to the next marker.
- **1-based MIDI channel** — `send_note`, `send_cc`, and `record_sequence` `ch` values accept 1..16 to match Logic's UI.
- **Audit phase split** — audit logs distinguish rejected calls, confirmation prompts, and executed route invocations.
- **Verified project saves** — `project.save_as` verifies the target `.logicx` package exists and that existing packages advance modification time.
- **Live project metadata** — `logic://project/info` promotes live transport tempo/sample-rate when available and falls back per-field to saved project metadata.
- **Side-effect-free reads** — resources expose state, metadata, and cached inventory without mutating Logic.

## Release & Distribution

Stable production tags use the GitHub Actions release workflow. `RELEASE-METADATA.json` records the exact signing mode, Team ID, and architectures for each artifact. When Developer ID credentials are absent, releases publish ADHOC artifacts with SHA256 metadata and install validation rather than pretending to be notarized.

Per-release detail lives in [CHANGELOG.md](CHANGELOG.md). Security and installer trust tiers are documented in [SECURITY.md](SECURITY.md).

## Known Limitations

- **Tempo typing**: `transport.set_tempo` falls back to slider increments when Logic's tempo display cannot accept text input; sub-10-BPM precision may require setting tempo manually once in Logic.
- **MIDI region padding**: `record_sequence` regions start at bar 1 and extend to the target bar using inaudible padding; note timing inside the region is exact, but the region can look longer than the phrase.
- **MIDI Key Commands**: Logic 12.2 does not accept the legacy `.plist` Key Commands import; manual MIDI Learn remains required for keycmd-only operations.
- **Markers**: `logic://markers` returns `[]` honestly when the Marker List window is closed on Logic 12.2; auto-opening that window is not shipped because it changes focus.
- **Plugin parameter readback**: `logic_plugins.set_param_verified` live-verifies Compressor `threshold` through the open plugin window; arbitrary plugin parameters remain future work and fail closed with `unsupported_param_readback`.
- **Plugin window opening**: parameter apply-back still needs the target plugin window already open in Logic Pro; exact-slot plugin insertion itself does not require a pre-opened plugin window.

## Development

Source builds require Xcode 16.4+ / Swift 6.2 for the current verified toolchain.

```bash
swift test --no-parallel
swift build -c release
python3 -m py_compile Scripts/live-e2e-test.py
```

For live attestation on a configured Logic Pro host:

```bash
LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh
```

## License

MIT. See [LICENSE](LICENSE).

## Contributing

Bug reports, PRs, and feature discussions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev workflow.

Security vulnerabilities: please do **not** open a public issue. See [SECURITY.md](SECURITY.md) for the private disclosure process.
