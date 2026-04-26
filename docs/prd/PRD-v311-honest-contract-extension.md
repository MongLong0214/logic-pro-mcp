# PRD — v3.1.1 Honest Contract Extension + GUI-Click Elimination

**Status**: Draft v0.2 (post-strategist REVISE)
**Author**: Isaac (via Claude orchestrator)
**Date**: 2026-04-25
**Size**: L (28-34h, multi-channel, 22 ops + 1 envelope + 1 V-Pot decoder)
**Predecessor**: v3.1.0 shipped 2026-04-25 (4 PRD-scope ops in 3-state Honest Contract)
**Strategist gate**: REVISE (v0.1) → addressed (v0.2)

---

## 1. Why

v3.1.0 introduced the 3-state Honest Contract for **4** ops only. Strategist v0.1 audit confirmed **22 mutating `.success("…")` ad-hoc shapes** remain in `AccessibilityChannel.swift` plus the MCU-routed `track.set_automation`. Same false-success class as v3.0.5–v3.0.9. Until every mutating op converges to the contract, an LLM caller cannot trust *any* mutation — they have to second-guess each response shape.

Isaac's north star (`memory/user_north_star.md`): **CoreMIDI > AppleScript > Scripter > AX > CGEvent**. v3.1.1 doubles as the "blind GUI click → deterministic verifiable code" enforcement project per that ladder.

## 2. Scope

### 2.1 In-scope (22 ops, grouped by current channel)

#### A. Track lifecycle (AX channel)
- `track.rename`
- `track.set_mute`, `track.set_solo`, `track.set_arm`
- `track.create_audio`, `track.create_instrument`, `track.create_drummer`, `track.create_external_midi`
- `track.delete`, `track.duplicate`

#### B. Transport (AX channel, dual-path goto)
- `transport.toggle_cycle`, `transport.toggle_metronome`, `transport.toggle_count_in`
- `transport.play`, `transport.stop`, `transport.record`
- `transport.set_tempo`
- `transport.goto_position` (slider path + dialog path, both must converge)

#### C. Region (AppleScript path)
- `region.move_to_playhead`
- `region.select_last`

#### D. MIDI / Project (mixed)
- `midi.import_file`
- `project.save_as`

#### E. Mixer fallback (AC channel, when MCU unavailable)
- `defaultSetMixerValue` → drift fix to `HonestContract.encodeStateA/B`

#### F. MCU button (separate group from Track lifecycle)
- `track.set_automation` — MCU-routed (`ChannelRouter.swift:74` `[.mcu]`), not AX

#### G. Mixer pan State A enabler
- V-Pot CC 0x30..0x37 (LED-ring **readout**, absolute position) decoder + `StateCache.panUpdatedAt` plumbing → `mixer.set_pan` returns State A within 500ms echo

#### H. Resource envelope unification
- `logic://transport/state` → `{cache_age_sec, fetched_at, data: ...}` matching `tracks` / `inventory`

### 2.2 Explicitly out-of-scope

| Op | Reason |
|----|--------|
| `track.set_color` | Hardcoded `.error("Track color setting not supported via AX")` at `AccessibilityChannel.swift:223-224`. Implementing color-set is a separate L-sized feature, not a contract migration. |
| `transport.pause` | No switch case. Logic's transport has no pause op (play toggles play↔stop). |
| Plugin parameter automation curves | Point-set only today; curves are v3.1.2+ |
| Multi-track batch atomic ops | v3.1.2+ |

## 3. Acceptance Criteria

| # | AC | Verifier |
|---|----|----------|
| a | All 22 scoped ops + V-Pot pan + transport envelope return one of `{State A, State B, State C}` per `HonestContract.encodeState*`. Encoder enforces required fields. | Per-op test in `HonestContractOpTests.swift` (extend) |
| b | `mixer.set_pan` returns State A when V-Pot LED-ring CC 0x30..0x37 echo arrives within 500ms; State B `echo_timeout_500ms` otherwise | Live + new MCUChannel pan-echo test |
| c | `logic://transport/state` carries `cache_age_sec`, `fetched_at`, `data` keys with same shape as `tracks` / `inventory` | Resource schema test |
| d | `defaultSetMixerValue` (AC fallback) emits Honest Contract envelope (no ad-hoc `verified` field) | Unit test: simulate MCU unavailable → assert State B `echo_timeout` shape |
| e | `verified:false` ⇒ `reason ∈ UncertainReason`; `success:false` ⇒ `error ∈ FailureError` | Encoder type-system enforcement (already enforced) |
| f | Live verification ≥ 3 cycles per scoped op against real Logic Pro 12.0.1 (66 cycles total) | Live harness extension |
| g | Build 3종 clean + full test suite passes (target: 821 → ≥870) | `swift test` |
| h | README + CHANGELOG: v3.1.1 section, 22 ops promoted from v3.1.0 backlog list, breaking-change wire-format audit (down-stream MCP clients) | Doc review |
| i | No regression vs v3.1.0 — all 821 v3.1.0 tests still pass | Full suite |
| **j** | `track.set_color` + `transport.pause` explicitly listed as out-of-scope in CHANGELOG (no silent omission) | Doc review |
| **k** | V-Pot LED-ring decoder unit-tested: CC 0x30..0x37 → mode bits + position(1-11) → 0..1 normalized pan value, with edge cases (mode=center, position=0=no LEDs, position=11=full) | New unit test |
| **l** | `midi.import_file` Honest Contract uses real track-count + region-count delta (pre/post snapshot via `allTrackHeaders.count` + new track region scan), not just osascript "OK" | Unit + live test |
| **m** | Wire-format compat audit: existing internal callers (e.g., `record_sequence` chain, `Tests/EndToEndTests.swift` track-count assertions) updated to read new envelope keys; no silent breakage | Test pass + grep audit |
| **n** | Mixer AC fallback trigger condition explicit: `cache.getMCUConnection().isConnected == false` OR `getMCUConnection().feedbackStale == true` | Code + doc |
| **o** | `track.set_automation` MCU read-back via MCU button LED feedback, not AX/Inventory | New MCU test |

## 4. Architecture Decisions

### 4.1 Read-back source per op (corrected per strategist)

| Op | Read-back source | Notes |
|----|------------------|-------|
| `track.rename` | AX `AXValue` of name field after setAttribute | inline (no Inventory dependency) |
| `track.set_mute/solo/arm` | AX `AXValue` of mute/solo/arm button (already partial — wrap in HC) | already strategy-ladder verified |
| `track.create_*` | `allTrackHeaders.count` delta (already partial — wrap in HC) | 4×1s polling already; cap at 4s State B `retry_exhausted` |
| `track.delete` | `allTrackHeaders.count` decrement | symmetric to create |
| `track.duplicate` | `allTrackHeaders.count` increment + new track at end with `Original Copy` suffix |
| `transport.goto_position` | StateCache.transport.position OR slider AXValue read-back, normalize to bar.beat.sub.tick | force refresh post-write |
| `transport.set_tempo` | slider `AXValue` inline (already done at L538), wrap in HC | StateCache uninvolved → no race |
| `transport.toggle_cycle/metronome/count_in/play/stop/record` | AX checkbox `AXValue` boolean (existing partial) | wrap in HC |
| `region.move_to_playhead` | **region.startBar pre/post diff** (NOT count — count is invariant). Use `parseRegionBars` (`AccessibilityChannel.swift:2351-`) | new code |
| `region.select_last` | AX `AXSelected` of last layout-item | replace osascript-only confirmation |
| `midi.import_file` | `allTrackHeaders.count` delta + region count on new track index via `defaultGetRegions` | new pre/post snapshot |
| `project.save_as` | `FileManager.fileExists` (already done) + size > 0 — wrap in HC envelope | only shape change |
| `defaultSetMixerValue` (AC) | `pollFaderEcho` analogue via AX slider read OR fall through to State B `echo_timeout` | mirror MCU path |
| `track.set_automation` (MCU) | MCU button LED feedback (note-off LED state for `ButtonFunction.read/write/touch/latch/trim/off`) | new |
| `mixer.set_pan` | V-Pot LED-ring CC 0x30..0x37 readout (mode bits + position → 0..1 normalized) | new |

**Race policy** (Risk R6): **All mutating-op read-backs MUST query AX directly OR force-refresh StateCache before reading.** Never trust StatePoller's background cadence. (Existing `executeSetTempo` slider read is inline-AX → safe.)

### 4.2 V-Pot CC mapping (corrected per strategist)

| CC range | Direction | Semantics |
|----------|-----------|-----------|
| **0x10-0x17** | Surface → Logic (TX) | V-Pot rotation as relative encoder. `0x40 \| speed` = CCW, `0x00 \| speed` = CW. Already implemented at `MCUProtocol.swift:180-189` (`encodeVPot`). |
| **0x30-0x37** | Logic → Surface (RX) | V-Pot **LED ring display readout**. Mode bits (0x00-0x60: dot/boost/cut/spread/wrap) + position (1-11). Currently NO decoder exists. |

**v3.1.1 work**:
1. New `decodeVPotLED(value: UInt8) -> (mode: VPotMode, position: Int)` in `MCUProtocol.swift`.
2. New `MCUFeedbackParser` dispatch for `.controlChange(channel: 0, cc: 0x30..0x37, value: ...)` (currently L68 wildcard match — no-op).
3. Map LED position (1-11) to pan -1..0..+1 (center is mode=center / position=6; left = mode=spread + position decreasing; right = position increasing).
4. New `StateCache.panValues: [Int: Float]` + `panUpdatedAt: [Int: Date]`.
5. New `pollPanEcho(strip:target:timeoutMs:requireFreshAfter:)` analogous to `pollFaderEcho`.
6. `executeSetPan` captures `sendAt = Date()`, sends V-Pot rotation via existing `encodeVPot`, polls until echo or 500ms.

### 4.3 GUI-click ladder (5-step, per Isaac north star)

```
CoreMIDI > AppleScript > Scripter > AX > CGEvent
```

**T-2 audit deliverable**: per-op channel choice table. Where MCU CoreMIDI exists, prefer it over AX. Examples to evaluate:
- `transport.play/stop` — currently AX checkbox; MCU `MCUProtocol.encodeTransport` exists at L160+ → migrate?
- `track.set_mute/solo/arm` — currently AX strategy ladder; MCU `ButtonFunction.recArm/solo/mute` (L27-29) absolute encoding exists → migrate?
- `track.set_automation` — already MCU; keep.
- Library category click — `LibraryAccessor.swift:131` `productionMouseClick` → AX-only alternative search.
- New Track dialog Return key — `AccessibilityChannel.swift:1224` `sendReturnKey` → AX `AXPress` of OK button alternative.

**Retain policy** (per strategist R8):
- rec-arm 5-step strategy ladder mouse-click fallback (L946-960) — *intentional*, retain.
- Document in CHANGELOG which click sites are kept-by-design vs replaced.

### 4.4 Wire-format compatibility (R9)

22 ops migrating to envelope = breaking change for any caller depending on bare `{tempo:120, via:"slider"}`-style shapes. Audit:
- Internal callers: `record_sequence` chain inside `AccessibilityChannel.swift`, internal helper `verifyTrackCreation`. Update.
- Test callers: grep `Tests/` for op response key-set assertions. Update.
- External callers: Claude Desktop / Cursor — they consume opaque JSON, low risk if they pass-through. CHANGELOG must call out shape change explicitly.

## 5. Risks

| # | Risk | Mitigation |
|---|------|------------|
| 1 | Inventory refresh latency (rename → read) | Inline AX read-back, no Inventory dependency |
| 2 | StateCache transport tempo poll cadence vs settle | All read-backs use inline AX or force-refresh — never passive cache |
| 3 | V-Pot LED mode-bit ambiguity (Mackie spec interpretation) | Unit-test against captured fixture from real Logic; State B `readback_unavailable` if undecodable |
| 4 | Region count delta is invariant for `move_to_playhead` | Use startBar diff, not count |
| 5 | Test count growth (~50 new tests) | Acceptable; v3.1.0 added 31 |
| **6** | **Race**: AX channel actor vs StateCache actor cross-actor read | Direct AX read OR force-refresh policy (§4.1) |
| **7** | **Cumulative timeout**: chained op settle (4s create + 500ms tempo + 600ms select) approaches 30s LLM timeout | Per-op cap + early State B `retry_exhausted` fall-through |
| **8** | **CGEvent residual sites** (6 identified): postMouseClickAt L991, sendReturnKey L1224, productionMouseClick LibraryAccessor:131/684/955, AXLogicProElements:350 | T-2 audit categorizes retain (rec-arm fallback) vs replace (AX-direct alternative) |
| **9** | **Wire-format breaking** for 22 ops | §4.4 audit + CHANGELOG explicit + internal-caller migration |

## 6. Implementation Plan (15 tickets, 28-34h)

| T# | Title | Owner | Estimate |
|----|-------|-------|----------|
| **T-0** | PRD v0.2 boomer/guardian gate (post-revise) | boomer + guardian | 30m |
| T-1 | Audit: 22 mutating .success() sites + envelope drift map | strategist | 1h |
| T-2 | CGEvent audit + retain/replace policy (5-step ladder) | strategist | 1h |
| T-3 | track.rename / set_mute/solo/arm — HC + tests | backend | 2h |
| T-4a | track.create_*/delete/duplicate (AX) — HC + tests | backend | 2-3h |
| T-4b | track.set_automation (MCU) — HC + tests | backend | 1h |
| T-5 | transport.goto_position / set_tempo / toggle_* — HC + tests (6 ops) | backend | 3-4h |
| T-6 | region.* (startBar diff) / midi.import_file (delta snapshot) / project.save_as — HC + tests | backend | 3-4h |
| T-7 | mixer AC fallback HC wrap | backend | 30m |
| T-8 | V-Pot LED-ring decoder + StateCache pan plumbing + mixer.set_pan State A path | backend | 4-6h |
| T-9 | logic://transport/state envelope + ResourceHandler test | backend | 45m |
| T-10 | Live-verify harness expansion + 3-cycle × 22 ops = 66 cycles | tester + manual | 3h |
| T-11 | Guardian + Boomer iter1 review | guardian + boomer | 1h |
| T-12 | Iter1 fix loop | backend | 2-4h |
| T-13 | Iter2 review + fix | guardian + boomer + lead | 1-2h |
| T-14 | README + CHANGELOG + version bump → v3.1.1 | docs | 30m |
| T-15 | Release: tag + tarball + Formula sha sync via `Scripts/release.sh` | release | 15m |

**Total**: 28-34h. L size, multi-channel, no XL trigger.

## 7. Memory / Backlog Disposition

- v3.1.1 ship complete → update `memory/project_v310_shipped.md` to reflect v3.1.1 closure of HC-extension scope.
- Update `docs/HONEST-CONTRACT.md` §추가 예정 → §완료 (22 ops promoted).
- Move retained CGEvent sites to a documented "intentional ladder fallback" section.

## 8. Out-of-scope deferred to v3.1.2+

- `track.set_color` (no-op today, separate L feature).
- `transport.pause` (Logic doesn't expose).
- Plugin parameter automation curves.
- Multi-track batch atomic ops with rollback.
- Cycle locator AX text-field exposure (Logic-side limitation).
