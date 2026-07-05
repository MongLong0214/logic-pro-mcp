# WS2: Other Channels — dedup + Result-based param parse (behavior-preserving)

**PRD**: G3, §3.2 WS2
**Priority**: P2 | **Size**: M | **Risk**: L-M
**Owns (EXCLUSIVE)**: `Channels/{AppleScriptChannel, CoreMIDIChannel, MIDIKeyCommandsChannel, ScripterChannel, CGEventChannel, ChannelRouter, Channel}.swift` + new `RoutingTable.swift`. MUST NOT touch AccessibilityChannel* (WS1) or MCUChannel (WS6).
**Parallel-safe with**: WS1/3/4/5/6/7.

## 1. Objective
Route the reviewed Channels-layer duplication through helpers, extract the routing-table literal — all wire-preserving.

## 2. Acceptance Criteria
- AC1: CoreMIDI channel/velocity param-parse (×11, :159+) → `parseChannel`/`parseVelocity` returning `Result<_, ValidationFailure>` — **MUST return `.error`, NOT throw** (the outer catch@503 would re-wrap into State C = wire change; error strings are test-pinned). Byte-identical output.
- AC2: Catch-block dedup: MIDIKeyCommandsChannel:235/375/405/435 (×6) + (NON-MCU) shared `failSend`/`runValidated` helpers. Preserve every error string.
- AC3: AppleScriptChannel:679-721 byte-identical static+instance duplicate (`projectPathsMatch`/`normalizedProjectPath`) → instance delegates to static. `iso8601String` per-call formatter → hoisted `static let` (audit P3/round-1 #19).
- AC4: ChannelRouter 248-line routing-table `static let` literal → `RoutingTable.swift` (keep the exact name/type; pure relocation). Route State-C fall-through (round-1 #20) → `classifyStateCOutcome` helper (optional, only if wire-identical).
- AC5: Scripter/MIDIKeyCommands shared keycmd bits (midiChannel=15/start/healthCheck → shared protocol ext) — **PRESERVE byte-identical log strings** (RoutingAuditInvariantTests pins them).
- AC6: `swift test --no-parallel` green; golden-snapshot diff = 0 (route table, CoreMIDI success/error strings, keycmd logs).

## 3. Verification
Golden snapshots: ChannelRouter full route map + CoreMIDI op success/error envelopes + keycmd log lines, captured BEFORE, diff = 0 AFTER. RoutingAuditInvariantTests must stay green (they pin log strings).

## 4. Constraints
- INTENTIONAL, DO NOT unify (NG1/NG3): CoreMIDI/MCU free-form success strings vs AppleScript HC envelopes; `.axWriteFailed` vs `.portUnavailable`. Leave.
- CGEventChannel: NG10 — do NOT convert its blocking sleep to async (actor reentrancy). Touch only if a non-sleep dedup applies.
- Commit per file-cluster.

## 5. Review Checklist
- [ ] CoreMIDI parse helpers return .error (not throw); strings identical
- [ ] catch/AppleScript/keycmd dedup preserves every string (RoutingAuditInvariant green)
- [ ] RoutingTable.swift relocation (same name/type)
- [ ] Full suite green; golden route/string diff = 0
