# Contributing

Thanks for your interest. Logic Pro MCP is a Swift 6 actor-based macOS binary that bridges Logic Pro to the Model Context Protocol.

## Prerequisites

- macOS 14+
- Swift 6.0+ (Xcode 16 or Command Line Tools)
- Logic Pro 12.0.1+ (only for live E2E testing — unit tests run without it)

## Development Loop

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp

swift build              # debug
swift test               # 690 unit + integration tests
swift build -c release   # release binary at .build/release/LogicProMCP
```

For a faster local iteration:

```bash
# After making changes to source + tests:
swift test --filter <testName>
```

## Live E2E Testing

With Logic Pro launched and the MCP server registered, run the live test script:

```bash
python3 Scripts/live-e2e-test.py
```

This exercises every tool against a real Logic Pro instance. Requires:
- Logic Pro 12+ running with a blank project
- MCU Control Surface registered (see [docs/SETUP.md](docs/SETUP.md))
- Accessibility + Automation permissions granted

## Project Layout

```
Sources/LogicProMCP/
├── Channels/          7 native channels (MCU, AX, AppleScript, CoreMIDI, CGEvent, MIDIKeyCmds, Scripter)
├── Dispatchers/       8 MCP tool handlers (Transport, Tracks, Mixer, MIDI, Edit, Navigate, Project, System)
├── MIDI/              Protocol layer (MCU, MMC, SMF, NoteSequenceParser)
├── Accessibility/     AX helpers (AXHelpers, AXLogicProElements, AXValueExtractors)
├── State/             StateCache actor + StatePoller + models
├── Resources/         MCP resource handlers
├── Server/            LogicProServer + ServerConfig
└── Utilities/         DestructivePolicy, AppleScriptSafety, Logger, PermissionChecker

Tests/LogicProMCPTests/  690 tests across ~40 files
Scripts/                 install / uninstall / live E2E / Scripter JS
docs/                    SETUP, API, ARCHITECTURE, TROUBLESHOOTING, MAINTAINERS
```

## Channel Priority

When adding a new operation, assign it to the channel with the best protocol support:

| Priority | Channel | Use for |
|----------|---------|---------|
| 1 | **CoreMIDI** | Any operation that has a documented MIDI protocol (MMC locate, virtual port send, Scripter CC) |
| 2 | **AppleScript** | Project lifecycle (`open`, `close`, `save`). Logic's scripting dictionary is narrow but stable for these. |
| 3 | **MCU** | Mixer writes (fader/pan/send). 14-bit, bidirectional. No fallback. |
| 4 | **MIDIKeyCommands** | Edit menu shortcuts (undo, quantize, split, etc.) via virtual MIDI CC. |
| 5 | **Scripter** | Plugin parameter control via a user-installed JS insert. |
| 6 | **Accessibility** | Last-resort UI queries (track enumeration, marker reading, region probing). |
| 7 | **CGEvent** | Avoid — synthetic keyboard events. Only used as ultimate fallback. |

Register the operation in `ChannelRouter.v2RoutingTable` as an ordered list; the router tries each channel in turn.

## Pull Request Checklist

- [ ] `swift build` clean
- [ ] `swift test` green (all 690 tests)
- [ ] New behavior covered by at least one unit test
- [ ] Public API change → `CHANGELOG.md` entry under `[Unreleased]`
- [ ] New dependency → justification in PR description
- [ ] Security-sensitive change → update `SECURITY.md`

## Security Reports

Do **not** open a public issue for vulnerabilities. See [SECURITY.md](SECURITY.md) for the private disclosure process.

## Questions

Open a GitHub Discussion or Issue with the `question` label.
