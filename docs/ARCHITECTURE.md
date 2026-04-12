# Architecture

Logic Pro MCP Server is a Swift 6 actor-based system that multiplexes **7 native macOS control surfaces** behind a single MCP interface. This document describes how requests flow through the system, how state is maintained, and which design trade-offs were made.

---

## System Overview

```
┌───────────────────────────────────────────────────────────────────────┐
│                       MCP Client (Claude, etc.)                       │
└───────────────────────────────┬───────────────────────────────────────┘
                                │  JSON-RPC over stdio (line-delimited)
┌───────────────────────────────▼───────────────────────────────────────┐
│                    MCP Server (swift-sdk transport)                   │
│            initialize • tools/list • tools/call • resources/read      │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                       LogicProServer (actor)                          │
│   makeHandlers() → { listTools, callTool, listResources, readResource,│
│                      listResourceTemplates }                          │
└──────┬──────────────────┬───────────────────┬────────────────────┬────┘
       │                  │                   │                    │
       │                  │                   │                    │
┌──────▼────────┐  ┌──────▼────────┐  ┌───────▼────────┐  ┌────────▼──────┐
│  Dispatchers  │  │ ResourceHandlers │ │   StateCache   │  │  StatePoller  │
│ (8 tools)     │  │  (6 + template) │ │   (actor)      │  │ (5s AX poll)  │
└──────┬────────┘  └──────┬────────┘  └───────▲────────┘  └────────┬──────┘
       │                  │                   │                    │
       │                  │                   │                    │
┌──────▼──────────────────▼───────────────────┴────────────────────▼──────┐
│                       ChannelRouter (actor)                            │
│   ~90 operation → [ChannelID] priority chain                           │
│   Skips unavailable / manual_validation_required channels              │
│   Aggregates errors: "All channels exhausted for {op}. Last: ..."      │
└───┬──────┬──────┬──────┬──────┬──────┬──────┬─────────────────────────┘
    │      │      │      │      │      │      │
┌───▼──┐┌──▼───┐┌─▼───┐┌─▼───┐┌─▼───┐┌─▼───┐┌─▼────────┐
│ MCU  ││KeyCmd││Scrip││Core ││ AX  ││ CG  ││AppleScrip│
│<2ms  ││<2ms  ││<5ms ││MIDI ││~15ms││Evnt ││ ~200ms    │
│ ↕    ││  ↓   ││ ↓   ││<1ms ││ ↑   ││<2ms ││   ↓       │
│      ││      ││     ││ ↕   ││     ││ ↓   ││           │
└───┬──┘└──────┘└─────┘└──┬──┘└─────┘└─────┘└───────────┘
    │                     │
    │ UMP feedback        │ CoreMIDI in/out
┌───▼─────────────────────▼────────────────────────────────────────────┐
│                        Logic Pro (macOS app)                         │
└──────────────────────────────────────────────────────────────────────┘
```

Legend — `↕` bidirectional, `↑` read, `↓` write.

---

## Layered Architecture

| Layer | Responsibility | Type | Isolation |
|-------|---------------|------|-----------|
| **Transport** | MCP JSON-RPC framing via `swift-sdk` | stdio | Task-isolated |
| **Server** | `LogicProServer` — composition root, handler wiring, lifecycle | `actor` | Actor |
| **Dispatchers** | 8 MCP tool structs — argument coercion, destructive-policy gating | `struct` | Immutable |
| **Routing** | `ChannelRouter` — priority chain selection, fallback, health checks | `actor` | Actor |
| **Channels** | 7 communication channels, each wrapping one macOS API | `actor` | Actor per channel |
| **State** | `StateCache` (store) + `StatePoller` (5s AX refresh) | `actor` | Actor |
| **Resources** | `ResourceHandlers` — URI routing, JSON serialization | `struct` | Pure |
| **Utilities** | `AppleScriptSafety`, `DestructivePolicy`, `PermissionChecker`, `Logger` | mixed | Pure / `enum` |

---

## Request Lifecycle

### Tool Call Path

```
1. Claude sends: tools/call { name: "logic_transport", arguments: { command: "play" } }
2. LogicProServer.callTool routes by name to TransportDispatcher.handle
3. TransportDispatcher maps "play" → operation "transport.play"
4. ChannelRouter.route("transport.play") looks up [.mcu, .coreMIDI, .cgEvent]
5. For each channel in order:
     a. channel.healthCheck() — skip if unavailable or manual_validation_required
     b. channel.execute(operation, params)
     c. Return first .success; accumulate errors
6. If all fail: .error("All channels exhausted for transport.play. Last error: ...")
7. Result wrapped in CallTool.Result and returned to Claude
```

### Resource Read Path

```
1. Claude sends: resources/read { uri: "logic://tracks" }
2. LogicProServer.readResource → ResourceHandlers.read
3. ResourceHandlers inspects URI, queries StateCache
4. StateCache returns current snapshot (event-driven from MCU + 5s AX poll)
5. Serialized as JSON in ReadResource.Result
```

---

## Channel Catalog

Each channel conforms to the `Channel` protocol:

```swift
protocol Channel: Actor {
    nonisolated var id: ChannelID { get }
    func start() async throws
    func stop() async
    func execute(operation: String, params: [String: String]) async -> ChannelResult
    func healthCheck() async -> ChannelHealth
}
```

| Channel | Medium | Primary Use | State Feedback |
|---------|--------|-------------|----------------|
| **MCU** | Virtual MIDI (UMP, bidirectional) | Mixer (fader/pan/mute/solo/arm), transport, plugins | ✅ Fader positions, LEDs, LCD, transport |
| **MIDIKeyCommands** | Virtual MIDI (CC on CH 16) | 60 keyboard shortcuts → MIDI CC | ✖ Write-only |
| **Scripter** | Virtual MIDI FX plugin (CC 102-119 on CH 16) | Per-plugin parameter automation | ✖ Write-only |
| **CoreMIDI** | CoreMIDI native | Note/chord/CC/PC/PB/AT/SysEx, MMC | Bidirectional (port listing) |
| **Accessibility** | macOS AX API | Track metadata, regions, markers, project info | ✅ Read-only |
| **CGEvent** | Keyboard event injection | Last-resort shortcut fallback | ✖ Write-only |
| **AppleScript** | `NSWorkspace.open()` + `NSAppleScript` | Project lifecycle (open/save/close) | ✖ Write-only |

---

## Channel Routing Table (Abbreviated)

The complete table is `ChannelRouter.v2RoutingTable` (90+ entries). Excerpt:

| Operation | Primary | Fallback chain | Notes |
|-----------|---------|----------------|-------|
| `transport.play` | MCU | CoreMIDI → CGEvent | Bidirectional MCU preferred |
| `transport.stop` | MCU | CoreMIDI → CGEvent → AppleScript | AppleScript whitelisted |
| `mixer.set_volume` | **MCU** | *(none)* | **Requires MCU registration** |
| `mixer.set_pan` | MCU | *(none)* | MCU-only |
| `mixer.get_state` | MCU | Accessibility | AX fallback for read |
| `track.get_tracks` | Accessibility | *(none)* | AX only |
| `track.set_mute` | MCU | Accessibility → CGEvent | Full fallback |
| `edit.undo` | MIDIKeyCommands | CGEvent | KeyCmd preferred if approved |
| `midi.send_note` | CoreMIDI | *(none)* | CoreMIDI exclusive |
| `project.open` | AppleScript | *(none)* | Uses `NSWorkspace.open()` |
| `project.save_as` | Accessibility | AppleScript | AX dialog primary |

---

## State Management

```
┌──────────────────────────────────────────┐
│          StateCache (actor)              │
│                                          │
│  • TransportState (tempo, position, ...)│
│  • [TrackState] (name, mute, solo, arm) │
│  • [ChannelStripState] (volume, pan)    │
│  • ProjectInfo (name, version)          │
│  • MCUConnectionState (isConnected, ...)│
│  • MCUDisplayState (upper/lower LCD)    │
│  • [RegionState], [MarkerState]         │
│  • lastToolAccessAt, lastUpdated        │
└──┬──────────────────────────────┬────────┘
   │                              │
   │ event-driven writes          │ periodic writes (5s)
   │                              │
┌──▼──────────┐              ┌────▼────────┐
│  MCU        │              │ StatePoller │
│  Channel    │              │             │
│  (feedback) │              │  — project  │
└─────────────┘              │    info only│
                             └─────────────┘
```

**Update priority:**
1. **MCU feedback** is authoritative for mixer/transport/tracks — applied synchronously in channel feedback handler.
2. **AX poller** writes are skipped for fields MCU already owns to prevent stale overwrites.

**Why not "live AX poll everything"?**
AX reads are ~15-50ms and Logic Pro's AX tree changes per locale (Korean vs English) and per Logic version. MCU is more stable, faster, and matches the real DAW state exactly.

---

## Concurrency Model

All mutable state lives behind Swift actors:

| Actor | Mutable State |
|-------|--------------|
| `LogicProServer` | References to all channels + router + cache |
| `ChannelRouter` | Registered channels dictionary |
| `StateCache` | All cached state |
| `StatePoller` | Background polling task |
| `MIDIPortManager` | Virtual MIDI port refs |
| `AccessibilityChannel` | AX runtime |
| `AppleScriptChannel` | AppleScript runtime |
| `CoreMIDIChannel` | MIDI engine |
| `MCUChannel` | Transport, feedback handler, banking state |
| `MIDIKeyCommandsChannel` | Transport, approval store |
| `ScripterChannel` | Transport, approval store |
| `CGEventChannel` | Event poster state |
| `ManualValidationStore` | Persisted approval file |

**Non-isolated surfaces:**
- Stateless `struct` dispatchers (pure argument coercion)
- `enum AppleScriptSafety` (pure validation)
- `enum DestructivePolicy` (pure classification)
- `enum Logger` (writes to stderr, which is thread-safe at the OS level)

---

## Error Propagation

```
Channel.execute → ChannelResult
  .success(String)   — JSON or human-readable text
  .error(String)     — typed error message

ChannelRouter aggregates:
  if all channels fail:
    .error("All channels exhausted for {op}. Last error: {msg}")

Dispatchers wrap:
  → CallTool.Result with isError flag

Server emits:
  { "jsonrpc": "2.0", "id": N,
    "result": { "content": [...], "isError": true/false } }
```

**MCP errors** (vs tool errors) are thrown only from `ResourceHandlers` via `MCPError.invalidParams` for unknown URIs.

---

## Security Boundaries

| Boundary | Threat | Mitigation |
|----------|--------|-----------|
| MCP tool arguments → AppleScript | Command injection | `AppleScriptSafety.isValidProjectPath` — rejects control chars, `/dev/`, relative paths, non-`.logicx` |
| MCP path → AX Save-As dialog | Unchecked path to AX attribute | `AppleScriptSafety.isValidProjectPath` guard added in `saveAsViaAXDialog` |
| MCP name → AX rename | Unbounded string → UI corruption | `String(name.prefix(255))` truncation |
| MCP name → Virtual MIDI port | Newlines / null bytes → CoreMIDI property corruption | `.filter { !$0.isNewline && $0 != "\0" }.prefix(63)` |
| MCP duration → actor | DoS via `UInt64.max` sleep | `min(duration_ms, 30_000)` cap on step_input/send_note/send_chord |
| Config → AppleScript | Interpolation with uncontrolled config | `logicProProcessName` + `logicProBundleID` escaped before interpolation |
| Main runloop → CLI | `DispatchQueue.main.sync` deadlock in CLI without AppKit | `CFRunLoopIsWaiting(main)` guard returning nil |
| MIDI wordCount → packet traversal | OOB pointer arithmetic on malicious UMP | `min(wordCount, 64)` bound |
| Shell → osascript | Nested shell quoting fragility | Direct `/usr/bin/osascript -e` in `PermissionChecker` |
| Process signal | SIGTERM → OS kill without cleanup | `DispatchSource` signal handler with orderly shutdown |

---

## Destructive Operation Policy

`DestructivePolicy` classifies project lifecycle commands:

| Level | Commands | Gate |
|-------|----------|------|
| **L3** Critical | `project.quit`, `project.close` | `{ "confirmed": true }` required |
| **L2** High | `project.save_as`, `project.bounce`, `project.open` | `{ "confirmed": true }` required |
| **L1** Normal | `project.save`, `project.new`, `project.launch` | Logged only |
| **L0** Safe | Everything else | Immediate execution |

Without `confirmed: true`, the dispatcher returns a structured `confirmation_required` response including risk and reason.

---

## Manual Validation Approval Gate

Channels that cannot be automatically verified require a one-time operator approval:

```bash
LogicProMCP --approve-channel MIDIKeyCommands
LogicProMCP --approve-channel Scripter
```

Approvals are persisted to `~/Library/Application Support/LogicProMCP/operator-approvals.json`. Without approval, `ChannelRouter` skips those channels (they report `manual_validation_required`) and falls back to the next channel in the chain.

Revoke with `--revoke-channel` and inspect with `--list-approvals`.

---

## Observability

- **Structured stderr logging** via `Logger.swift` with subsystems: `server`, `router`, `mcu`, `midi`, `keycmd`, `scripter`, `cgEvent`, `ax`, `appleScript`, `poller`, `main`.
- `LOG_LEVEL` environment variable — `DEBUG`, `INFO` (default), `WARN`, `ERROR`.
- `logic_system health` tool returns a comprehensive health JSON with:
  - `logic_pro_running`, `logic_pro_version`
  - `channels[]` — each channel's available/ready/latency/verification status
  - `mcu` — connection state, registered-as-device, last feedback age
  - `cache` — poll mode, transport age, track count, project name
  - `permissions` — accessibility + automation grant state
  - `process` — memory_mb, cpu_percent, uptime_sec

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| DAW control surface | MCU over OSC | Logic Pro has no native OSC. MCU is bidirectional with 14-bit resolution. |
| Keyboard shortcut mechanism | MIDI CC over CGEvent | Locale-independent, no window focus required. |
| Plugin parameter control | Scripter MIDI FX | Deterministic CC-to-parameter mapping per track. |
| State reading | MCU feedback primary + AX polling supplementary | Event-driven; AX covers project metadata only. |
| Project file operations | `NSWorkspace.open()` | Eliminates AppleScript string interpolation. |
| Concurrency | Swift actors everywhere | Compiler-enforced data isolation. |
| Approval mechanism | File-persisted operator approvals | Enterprise change-management compatible. |
| Error model | Typed `ChannelResult` + aggregated router errors | Clear attribution across fallback chains. |
