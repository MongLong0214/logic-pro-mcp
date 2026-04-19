<p align="center">
  <img src="https://img.shields.io/badge/Logic_Pro-MCP_Server-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Logic Pro MCP Server" />
</p>

<p align="center">
  <strong>The missing API for Logic Pro.</strong><br/>
  Natural-language control of Logic Pro from Claude and other MCP clients.
</p>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.0+-F05138.svg?style=flat-square" /></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14+-000000.svg?style=flat-square&logo=apple" /></a>
  <a href="https://modelcontextprotocol.io"><img src="https://img.shields.io/badge/MCP-0.10-blue.svg?style=flat-square" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" /></a>
  <img src="https://img.shields.io/badge/tests-690_passing-brightgreen.svg?style=flat-square" />
  <img src="https://img.shields.io/badge/version-2.3.1-blue.svg?style=flat-square" />
</p>

---

Logic Pro has no public API. This server bridges that gap by combining **7 native macOS control channels** into a single MCP interface — giving AI assistants bidirectional, deterministic control over transport, mixing, MIDI composition, plugins, automation, and project lifecycle.

```
You: "Make a 4-bar techno loop in A minor at 140 BPM"

Claude → logic_tracks.record_sequence {
  bar: 1, tempo: 140,
  notes: "45,0,95;57,107,95;45,214,95;..."
}
Claude → logic_tracks.set_instrument {
  index: 0, path: "Electronic Drums/Roland TR-909"
}

Logic Pro: region imported, TR-909 loaded, ready to play.
```

## Why this exists

Logic Pro ships without an AppleScript dictionary rich enough for composition workflows, without OSC, and without a first-party MCP server. Every existing "Logic automation" tool either:

1. Relies on screen-scraping via vanilla AppleScript (slow, fragile, breaks every Logic update)
2. Simulates keyboard shortcuts (no state awareness, no feedback)
3. Uses a single protocol like MCU alone (misses 80% of Logic's surface)

This server takes a different approach: **combine seven complementary channels**, route each operation to the channel best suited for it, and expose a clean MCP tool surface on top.

## What it does

**Mixer** — Control faders, pan, sends, plugin parameters with 14-bit MCU resolution. Bidirectional: state cache reflects what Logic actually did, not what you requested.

**Transport** — Play, stop, record, locate, cycle, tempo, metronome. Sub-millisecond CoreMIDI MMC path; AX dialog fallback for precise bar positioning that auto-extends the project length.

**MIDI composition** — `record_sequence` generates a Standard MIDI File server-side and imports it into a new track. Zero timing drift regardless of system load; notes land at the exact requested bar.

**Library & instruments** — Enumerate Logic's full instrument library (Electronic Drums, Synthesizer, Bass, etc.) and load presets by path. Tree-scan caches to disk for instant subsequent lookups.

**Plugins** — Deterministic plugin parameter control via a Scripter JS insert on the selected track.

**Navigation** — Goto bar, markers by name, zoom, view toggles.

**Project lifecycle** — New, open, save, save-as, close, bounce, quit — all with explicit destructive-operation confirmation.

## Quick Start

**Prerequisites**: macOS 14+, Logic Pro 12.0.1+, Apple Silicon.

```bash
LOGIC_PRO_MCP_SHA256=0ee51d21196ed8ca13091f8d73076288d698e1916d3b5aced179beaaaf0f7c8a \
LOGIC_PRO_MCP_TEAM_ID=ADHOC \
bash <(curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v2.3.1/Scripts/install.sh)
```

This installs the binary, verifies its SHA256, registers with Claude Code, and installs the Key Commands preset. It does **not** configure the MCU control surface or Scripter insert — see the [Setup Guide](docs/SETUP.md) for those two manual steps (~5 minutes).

Then test in Claude:

> "Check Logic Pro MCP health and show all ready channels."

Expected: all 7 channels `ready` (or 5 if you skipped Key Commands and Scripter).

## Architecture at a Glance

```
┌─ MCP Client (Claude / Desktop / Code) ─┐
│                                         │
│   logic_transport   logic_tracks        │
│   logic_mixer       logic_midi          │
│   logic_edit        logic_navigate      │
│   logic_project     logic_system        │
│                                         │
└─────────────────┬───────────────────────┘
                  │ stdio
┌─────────────────▼───────────────────────┐
│  LogicProMCP Server (Swift)             │
│                                         │
│  ┌─ ChannelRouter (130+ operations) ──┐ │
│  │  routes operation → best channel  │ │
│  └───────────────────┬───────────────┘ │
│                      │                  │
│  ┌──────┬──────┬─────▼─────┬──────┐    │
│  │ MCU  │ AX   │ AppleScript│CoreMIDI│ │
│  │      │      │            │        │ │
│  │ CGEvent      Scripter  KeyCmds   │ │
│  └──────┴──────┴───────────┴────────┘ │
│                      │                  │
└──────────────────────┼──────────────────┘
                       │ MIDI / AX / AppleScript
                ┌──────▼───────┐
                │   Logic Pro  │
                └──────────────┘
```

See [Architecture](docs/ARCHITECTURE.md) for deeper details on channel priorities and state flow.

## Documentation

| Document | Audience | Purpose |
|----------|----------|---------|
| [Setup Guide](docs/SETUP.md) | End users | One-page install + Logic Pro integration, ~10 min |
| [API Reference](docs/API.md) | End users, MCP clients | All 8 tools, 6 resources, 130+ operations |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | End users | Common failures and fixes |
| [Architecture](docs/ARCHITECTURE.md) | Contributors | Channel design, state flow, testing strategy |
| [Maintainer Guide](docs/MAINTAINERS.md) | Maintainers | Release, approvals, E2E checklist |
| [Security Policy](SECURITY.md) | Security reviewers | Threat model, reporting, hardening |
| [Changelog](CHANGELOG.md) | Everyone | Per-release changes |
| [Contributing](CONTRIBUTING.md) | Contributors | Dev setup, PR workflow |

## Status

**v2.3.1** (2026-04-19) — Production-ready, adhoc-signed pre-release.

Notarized (Apple-signed) release requires Apple Developer Program membership ($99/year). Until that's set up, the installer operates in ADHOC mode: SHA256 pin + `codesign --verify` still protect against tampering, but macOS Gatekeeper assessment is skipped and the installer strips the quarantine attribute so the binary runs without warnings.

See [SECURITY.md §Release types](SECURITY.md#release-types) for the trust model detail.

### Testing

- **690 unit + integration tests**, all passing
- **Live E2E verified** on Logic Pro 12.0.1 / macOS 26.3
- Three independent production-readiness reviews (code quality, security, architecture) converged to PROCEED

### Known limitations

- **Intel (x86_64)** builds are not shipped in the v2.3.1 release artifact. Intel users should build from source.
- **`transport.set_tempo`** currently requires the Logic tempo display to be accessible via AX; it returns an error if the control bar layout hides the BPM field. Workaround: set tempo manually in Logic once before calling MCP tempo operations.
- **MIDI File import cosmetics**: `record_sequence` regions start at bar 1 and extend to the target bar (padding CC technique). Note timing inside the region is exact; the leading padding is inaudible. If you need a tight region, trim after import via Logic's **Edit → Trim** menu.

## License

MIT. See [LICENSE](LICENSE).

## Contributing

Bug reports, PRs, and feature discussions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev workflow.

Security vulnerabilities: please do **not** open a public issue. See [SECURITY.md](SECURITY.md) for the private disclosure process.
