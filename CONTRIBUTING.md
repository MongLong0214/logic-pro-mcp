# Contributing to Logic Pro MCP

Thanks for your interest. Logic Pro MCP is a Swift 6 actor-based macOS binary that bridges Logic Pro to the Model Context Protocol.

You do not need a full Logic Pro setup for many contributions. Docs, examples, issue reproduction notes, parser tests, validation tests, and CLI message improvements can usually be completed with Swift and the normal unit test suite.

Start here:

- Review the [open issues](https://github.com/MongLong0214/logic-pro-mcp/issues?q=is%3Aissue%20is%3Aopen) and choose a narrow, already-scoped change.
- Comment on the issue before starting if the issue has ambiguity about scope or acceptance criteria.
- Keep each PR narrow. One issue, one behavioral change, one verification story.

## Prerequisites

- macOS 14+
- Swift 6.0+ (Xcode 16 or Command Line Tools)
- Logic Pro — latest release prioritized (currently 12.3), works down to the 12.0.1 floor best-effort (only for live E2E testing — unit tests run without it). Live-verify against the newest Logic Pro version you have; that is the first-class target.

## Low-Risk PRs

Low-risk PRs are intentionally narrow and reviewable:

- Documentation examples in `README.md`, `docs/SETUP.md`, `docs/API.md`, or `docs/TROUBLESHOOTING.md`
- New unit tests around validation, JSON envelopes, parser edge cases, permission summaries, or resource schemas
- Clearer CLI or error output that does not change the public contract
- Reproduction notes for an existing issue, especially with exact Logic Pro/macOS versions
- Small refactors that remove duplication without changing routing, safety, or fallback behavior

Avoid these unless the issue explicitly asks for them:

- New automation fallbacks
- Logic-facing write behavior
- Release, signing, Homebrew, or installer trust changes
- Broad rewrites across multiple channel/router surfaces
- Claims that something is "verified" without independent readback evidence

## Do I Need Logic Pro?

| Work type | Logic Pro required? | Expected verification |
|-----------|---------------------|-----------------------|
| Docs-only changes | No | `git diff --check` |
| Unit tests, parser tests, schema tests | No | `swift test --filter <testName>` and relevant full-suite evidence when practical |
| CLI text or non-Logic validation | No | Focused tests plus `swift build` |
| MCP resource contract changes | Usually no | Focused resource tests and JSON envelope assertions |
| Channel routing or write/readback changes | Yes for final evidence | Unit tests plus live Logic Pro evidence |
| Release, installer, signing, Homebrew | No Logic needed, but maintainer review required | Release workflow or documented dry-run evidence |

## Development Loop

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp

swift build              # debug
swift test               # 2077 unit + integration tests on the current source tree
swift build -c release   # release binary at .build/release/LogicProMCP
```

For a faster local iteration:

```bash
# After making changes to source + tests:
swift test --filter <testName>
```

Use `swift test --no-parallel` before asking for review when the change touches shared routing, state, resource envelopes, or safety-sensitive behavior.

## Live E2E Testing

With Logic Pro launched and the MCP server registered, run the live test script:

```bash
Scripts/live-e2e-test.py
# Strict live release-tree attestation:
LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh
```

This exercises every tool against a real Logic Pro instance. Requires:
- Logic Pro 12+ running with a blank project
- MCU Control Surface registered (see [docs/SETUP.md](docs/SETUP.md))
- Accessibility + Automation permissions granted

Live E2E is not required for docs-only PRs or unit-test-only PRs. If an issue requires live evidence, include the exact command, Logic Pro version, macOS version, and the observed State A/B/C result in the PR description.

## Project Layout

```
Sources/LogicProMCP/
├── Channels/          7 native channels (MCU, AX, AppleScript, CoreMIDI, CGEvent, MIDIKeyCmds, Scripter)
├── Dispatchers/       10 MCP tool handlers (Transport, Tracks, Mixer, Plugins, MIDI, Edit, Navigate, Project, Audio, System)
├── MIDI/              Protocol layer (MCU, MMC, SMF, NoteSequenceParser)
├── Accessibility/     AX helpers (AXHelpers, AXLogicProElements, AXValueExtractors)
├── State/             StateCache actor + StatePoller + models
├── Resources/         MCP resource handlers
├── Server/            LogicProServer + ServerConfig
└── Utilities/         DestructivePolicy, AppleScriptSafety, Logger, PermissionChecker

Tests/LogicProMCPTests/  2077 tests across the Swift test target on the current source tree
Scripts/                 install / uninstall / live E2E / Scripter JS
docs/                    public setup, API, troubleshooting, README media, and public issue PRDs/tickets
artifacts/               generated local artifacts; only explicitly published fixtures belong in git
```

## Documentation Policy

Keep `docs/` intentionally public-facing. Default end-user docs are `SETUP.md`, `API.md`, and `TROUBLESHOOTING.md`; README media is limited to the demo GIF/MP4 plus the registry/social thumbnail. Public issue PRDs and ticket checklists may live under `docs/prd/` and `docs/tickets/` when they explain active or shipped user-visible remediation. Release detail belongs in `CHANGELOG.md` or GitHub Releases, maintainer process belongs in `CONTRIBUTING.md`, and architecture summaries belong in README/API unless they become too large.

Do not commit internal PRDs, private ticket boards, spike notes, private reviews, session handoffs, local workspace paths, personal identifiers, chat transcripts, or community-user provenance.

## Channel Priority

When adding a new operation, assign it to the channel with the best protocol support:

| Priority | Channel | Use for |
|----------|---------|---------|
| 1 | **CoreMIDI** | Any operation that has a documented MIDI protocol (MMC locate, virtual port send, Scripter CC) |
| 2 | **AppleScript** | Project lifecycle (`open`, `close`, `save`). Logic's scripting dictionary is narrow but stable for these. |
| 3 | **MCU** | Master volume (`set_master_volume`) and mixer state feedback. 14-bit, bidirectional. No fallback. Fader/pan writes now route to Accessibility (since #83); `set_send` is not exposed. |
| 4 | **MIDIKeyCommands** | Edit menu shortcuts (undo, quantize, split, etc.) via virtual MIDI CC. |
| 5 | **Scripter** | Plugin parameter control via a user-installed JS insert. |
| 6 | **Accessibility** | Last-resort UI queries (track enumeration, marker reading, region probing). |
| 7 | **CGEvent** | Avoid — synthetic keyboard events. Only used as ultimate fallback. |

Register the operation in `ChannelRouter.v2RoutingTable` as an ordered list; the router tries each channel in turn.

When adding or changing routes, do not add quiet fallback chains. If a fallback is necessary, make the condition, reason, and verification boundary visible in the response or logs.

## Branch and PR Workflow

1. Create a branch from current `main`.
2. Link exactly one issue unless the issue explicitly groups related work.
3. Add or update tests before changing production behavior.
4. Keep generated media, local Logic projects, and temporary artifacts out of the PR.
5. Open a PR with the template filled in, including exact commands run.
6. Do not push directly to `main`.

Use this branch naming style:

```bash
git switch -c docs/setup-cursor-example
git switch -c test/note-sequence-parser-invalid-channel
git switch -c fix/permission-summary-automation-copy
```

## Verification Matrix

| Change | Minimum local evidence |
|--------|------------------------|
| Markdown/docs only | `git diff --check` |
| Python scripts | `python3 -m py_compile <script>` |
| Swift parser/validation tests | `swift test --filter <testName>` |
| Public MCP envelope/resource changes | Focused tests plus JSON assertions |
| Shared routing/state changes | `swift test --no-parallel` |
| Logic-facing write/readback changes | Focused tests, full suite, and live Logic Pro evidence |

If you cannot run a required gate, say so in the PR and explain why. Do not mark unverified live behavior as verified.

## Pull Request Checklist

- [ ] `swift build` clean
- [ ] `swift test` green (all 2077 tests on the current source tree)
- [ ] New behavior covered by at least one unit test
- [ ] Changed production code keeps the global coverage floor green (`region >=70%`, `line >=78%`); high-risk Logic-facing changes target about 90% line coverage on the touched surface or document the live/manual evidence that substitutes for direct measurement
- [ ] Public API change → `CHANGELOG.md` entry under `[Unreleased]`; new MCP tools also require README and `docs/API.md` updates
- [ ] New dependency → justification in PR description
- [ ] Security-sensitive change → update `SECURITY.md`
- [ ] Logic-facing write/readback change → update `docs/API.md`, `docs/TROUBLESHOOTING.md`, and `CHANGELOG.md` when public behavior or live evidence changes
- [ ] Release version change → keep published install URLs pinned to the existing stable tag until a real release exists; when publishing, bump `ServerConfig`, manifest, Formula, installer default, tests, README, SETUP, API, and CHANGELOG together

## Security Reports

Do **not** open a public issue for vulnerabilities. See [SECURITY.md](SECURITY.md) for the private disclosure process.

## Questions

For real-time help, coordination, and contributor chat, join the official Logic Pro MCP Discord: [https://discord.gg/4M3s79DBzz](https://discord.gg/4M3s79DBzz).

For anything that should stay searchable, open a GitHub Discussion or Issue with the `question` label.
