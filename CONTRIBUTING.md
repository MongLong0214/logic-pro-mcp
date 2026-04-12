# Contributing to Logic Pro MCP

Thanks for your interest. This is a Swift 6 actor-based macOS binary that bridges Logic Pro to the Model Context Protocol. Below is what you need to know to run, test, and contribute code.

---

## Prerequisites

- macOS 14+ (Sonoma)
- Swift 6.0+ (Xcode 16+ or Command Line Tools)
- Logic Pro 12.0+ (only required for live testing — unit tests run anywhere)
- Accessibility + Automation permissions granted to your terminal

---

## Quick Loop

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp

swift build                    # debug build
swift test                     # 500 unit/integration tests
swift build -c release         # release binary at .build/release/LogicProMCP
```

For live testing against Logic Pro, launch Logic Pro and then:

```bash
python3 scripts/live-e2e-test.py    # 229 tests against the real app
```

---

## Project Layout

```
Sources/LogicProMCP/
├── Channels/              7 communication channels (MCU, KeyCmd, Scripter, CoreMIDI, AX, CGEvent, AppleScript)
├── Dispatchers/           8 MCP tool handlers
├── MIDI/                  Protocol layer (MCU, MMC, parser, feedback, port manager)
├── State/                 StateCache actor + StatePoller + models
├── Resources/             MCP resource handlers + provider
├── Server/                LogicProServer + ServerConfig
├── Utilities/             DestructivePolicy, AppleScriptSafety, Logger, PermissionChecker, etc.
└── MainEntrypoint.swift   CLI arg parsing + signal handling

Tests/LogicProMCPTests/    35 test files, 500 tests
scripts/                   install / uninstall / live E2E / keycmd preset
docs/                      API, ARCHITECTURE, MCU-SETUP, TROUBLESHOOTING, release runbooks
```

See `docs/ARCHITECTURE.md` for a deep dive into request flow, actor boundaries, and design decisions.

---

## Coding Conventions

### Language

- **Swift 6 strict concurrency.** All mutable state lives behind actors. Compiler warnings about isolation are errors.
- `@unchecked Sendable` is allowed only with a justifying comment and narrow scope (see `LogicProServerRuntimeOverrides`).
- `nonisolated(unsafe)` is allowed only when protected by an explicit lock (see `ProcessUtils.pidProcessListCache`).
- Prefer `async`/`await` over `DispatchQueue.main.sync` — the main-runloop path is guarded in `ProcessUtils.runAppKit`.

### Channel protocol contract

Every communication channel conforms to `Channel`:

```swift
protocol Channel: Actor {
    nonisolated var id: ChannelID { get }
    func start() async throws
    func stop() async
    func execute(operation: String, params: [String: String]) async -> ChannelResult
    func healthCheck() async -> ChannelHealth
}
```

Channels **must not** throw from `execute()` — return `ChannelResult.error(message)` instead. The router aggregates errors across fallback chains.

### Dispatcher contract

Dispatchers are stateless `struct`s. They parse `[String: Value]` MCP arguments, route through `ChannelRouter`, and wrap results in `CallTool.Result`. No direct channel references.

### Dependency injection

Most leaf types expose a `Runtime` struct with closure fields for testing. Real code uses `.production`; tests construct custom `Runtime` values. Avoid adding test-only code paths in production types — inject instead.

### Logging

Use `Log.info / warn / error / debug` with a subsystem tag. Subsystems in use: `server`, `router`, `mcu`, `midi`, `keycmd`, `scripter`, `cgEvent`, `ax`, `appleScript`, `poller`, `main`, `validation`, `project`.

Logs go to stderr. stdout is reserved for MCP JSON-RPC.

---

## Testing

### Running tests

```bash
swift test                                    # all tests
swift test --filter MCUChannelTests           # one file
swift test --filter testMCULoopback           # one test
```

### Writing tests

- Use Swift Testing (`@Test`, `#expect`). XCTest is not used.
- Tests live in `Tests/LogicProMCPTests/`.
- Shared helpers (`sharedToolText`, `sharedResourceText`, `SharedServerStartRecorder`) live in `SharedTestHelpers.swift`. Do not duplicate them per-file.
- Prefer behavior tests over mock-only tests. Use `FakeAXRuntimeBuilder` (in `AccessibilityTestSupport.swift`) to simulate the AX tree.
- For tests that actually invoke MCP handler flow end-to-end, use patterns from `EndToEndTests.swift`.

### TDD expectations

If you are adding a new operation or fixing a bug:

1. Add a failing test first (Red).
2. Implement the minimum code to pass (Green).
3. Refactor with tests still passing.

See `docs/release/LOGIC-PRO-E2E-CHECKLIST.md` for live validation expectations before merging behavior changes.

---

## Adding a new operation

1. **Routing** — add to `ChannelRouter.v2RoutingTable` with a priority chain of `ChannelID`.
2. **Channel handler** — implement the operation in the primary channel's `execute(operation:params:)` switch.
3. **Dispatcher** — add a `case` in the appropriate dispatcher that parses MCP args and calls `router.route(...)`.
4. **Resource (if readable)** — if the operation exposes state, add a URI handler in `ResourceHandlers`.
5. **Tests** — unit tests for the channel handler; dispatcher test in `DispatcherTests.swift`; E2E test in `EndToEndTests.swift`.
6. **API doc** — update `docs/API.md` with command name, params, channel chain.
7. **If destructive** — classify in `DestructivePolicy`.

---

## Pull Requests

- Rebase on `main` before opening.
- All 500 tests must pass: `swift test`
- Release build must succeed: `swift build -c release`
- For changes touching channels, state, or security — include the output of `python3 scripts/live-e2e-test.py` from a machine with Logic Pro.
- Update `CHANGELOG.md` under `[Unreleased]`.
- Tag PR with the appropriate label: `security`, `feature`, `bug`, `docs`, `test`, `refactor`.

### Commit messages

Prefix with a type (`fix:`, `feat:`, `docs:`, `test:`, `refactor:`). Reference the affected module in lowercase (e.g. `fix(ax): guard save-as path validation`).

---

## Security

See `SECURITY.md`. Never open a public issue for a security vulnerability.

---

## License

MIT. See `LICENSE`. By contributing, you agree that your contributions are licensed under the same terms.
