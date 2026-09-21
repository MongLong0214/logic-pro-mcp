# Contributing to Logic Pro MCP

Thanks for your interest. Logic Pro MCP is a Swift 6 actor-based macOS binary that bridges Logic Pro to the Model Context Protocol.

You do not need a full Logic Pro setup for many contributions. Docs, examples, issue reproduction notes, parser tests, validation tests, and CLI message improvements can usually be completed with Swift and the normal unit test suite.

Start here:

- Review the [open issues](https://github.com/MongLong0214/logic-pro-mcp/issues?q=is%3Aissue%20is%3Aopen) and choose a narrow, already-scoped change.
- Comment on the issue before starting if the issue has ambiguity about scope or acceptance criteria.
- Keep each PR narrow. One issue, one behavioral change, one verification story.

## Who does what

**You do not need to run every repository-wide check locally before opening a pull request.**
Run the checks that are relevant to your change, and write down in the description exactly what you
ran, what it printed, and what you could not verify. "I did not run this, and here is why" is a
usable answer; presenting something unverified as verified is not.

| | |
|---|---|
| **You** | the change, the tests that cover it, the evidence you can actually produce, and an honest list of what you could not |
| **CI** | the full applicable regression suite, the coverage floors, and every repository guard — before anything merges |
| **Maintainers** | approving workflow runs on a first-time contribution, repository configuration, live Logic verification you have no way to do, and attributing CI failures that are not yours |

Open a **draft** pull request when the remaining verification needs a maintainer — a live Logic
observation, a release dry run, a permission you do not have. That is what drafts are for.

### Local evidence, by kind of change

| Change | What to prepare locally | Who finally verifies it |
|---|---|---|
| Ordinary Markdown and examples | `git diff --check`; a factual claim still needs whatever evidence backs it | normal CI and review — no blanket Logic install requirement |
| Package or build declarations | the relevant build, `swift package describe` for a product change, and a consumer smoke build where one applies | the existing full regression suite and guards, in CI |
| Narrow parser or validation behaviour | the targeted test and a relevant build | CI regression and coverage |
| Shared state, routing or safety | focused evidence; the full local suite when that is feasible for you | CI, plus focused review of the evidence |
| Logic-facing readback or write | focused tests and whatever observation you can make — say so if you have no live access | live evidence, coordinated before acceptance rather than before you open a draft |
| CI or workflow changes | the guard and condition tests for what you touched, and any lint you can run | how the checks actually behave on a representative Actions run, plus existing CI |

A small contribution is meant to stay small. [#944](https://github.com/MongLong0214/logic-pro-mcp/issues/944)
is the shape: a product declaration, the documentation around it, `swift package describe`, and a
build from a consumer package are the relevant local evidence for it. A full local regression run is
not a precondition for submitting that.

## Citing Logic's own data

A change that states a fact about Logic cites Logic. `docs/canon/README.md` is the design; this is
what you need to do.

**You do not need Logic installed for most of it.** The corpus is committed under `docs/canon/`, so
these work anywhere:

```
Scripts/logic_canon.py resolve <ref>              # what value does this reference name?
Scripts/logic_canon.py check '<ref>=<value>'      # does this quote hold?
Scripts/logic_canon.py absent <source> <locale> '<string>'   # prove a string is not in the corpus
Scripts/check-canon-citations.py                  # the gate CI runs
```

**You do need Logic to pin a key nobody has cited yet.** `resolve` reads the committed index, and
only `Scripts/logic_canon.py build` on a machine with Logic can add to it. If you need a key that
is not there, say so in the pull request and a maintainer will pin it — do not work around it by
quoting a value the index cannot check.

**If your change states nothing about Logic**, write the sentence `docs/canon/README.md` gives
under *The opt-out*, with the reason. It is refused for a change that edits a Logic-facing path,
because what a change touches decides that, not what it says about itself.


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

## Development Loop

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp

swift build              # debug
swift test               # the unit and integration suite on the current source tree
swift build -c release   # release binary at .build/release/LogicProMCP
```

The suite is large and grows with every change, so this guide does not quote a test count — one
written down here is wrong by the following week, and a number nobody re-measures is the kind of
claim this project asks contributors not to make. `swift test 2>&1 | tail -5` reports what the
current tree actually ran.

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

Tests/LogicProMCPTests/  the Swift test target
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

## Before you ask for review

The local-evidence table above is the whole pre-submission obligation. What follows is not a list
of commands to run before submitting — it is what a change of a particular kind still needs before
it can be merged, and most of it is CI's job or a maintainer's.

- New behaviour is covered by at least one test.
- CI holds the coverage floors (`region >= 70%`, `line >= 78%`). You do not have to measure them
  locally; a high-risk Logic-facing change aims at roughly 90% line coverage on the surface it
  touches, or explains what live evidence stands in for direct measurement.
- Public API change → a `CHANGELOG.md` entry under `[Unreleased]`; a new MCP tool also needs README
  and `docs/API.md`.
- New dependency → say why, in the description.
- Security-sensitive change → update `SECURITY.md`.
- Logic-facing write or readback change → update `docs/API.md`, `docs/TROUBLESHOOTING.md` and
  `CHANGELOG.md` when the public behaviour or the live evidence changes.
- Release version change → leave published install URLs pinned to the existing stable tag until a
  real release exists. Publishing bumps `ServerConfig`, the manifest, the Formula, the installer
  default, the tests, README, SETUP, API and CHANGELOG together, and that is maintainer work.

If a gate is one you cannot run, say so in the description and say why. Do not mark unverified live
behaviour as verified.

## Security Reports

Do **not** open a public issue for vulnerabilities. See [SECURITY.md](SECURITY.md) for the private disclosure process.

## Questions

For real-time help, coordination, and contributor chat, join the official Logic Pro MCP Discord: [https://discord.gg/4M3s79DBzz](https://discord.gg/4M3s79DBzz).

For anything that should stay searchable, open a GitHub Discussion or Issue with the `question` label.
