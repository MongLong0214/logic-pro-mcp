# PRD: Channel EQ Verified Params + rename_marker vNext

**Version**: 0.1
**Author**: CEO/CTO planning rail (Fable role model, execution by Codex)
**Date**: 2026-07-07
**Status**: Draft-ready for ticket execution
**Size**: L

## 1. Problem Statement

Channel EQ insertion is live-verified, but Channel EQ parameter read/write is not. The live census proved `logic_plugins.insert_verified "Channel EQ"` reaches State A, and the plugin editor opens with view-mode controls (`docs/spikes/channel-eq-census.md:18`, `docs/spikes/channel-eq-census.md:20`, `docs/spikes/channel-eq-census.md:21`). It also proved that the Editor view exposes only a custom AX canvas, the Controls view returns zero traversable elements, and no per-band slider/value read-back is reachable via standard GUI AX (`docs/spikes/channel-eq-census.md:25`, `docs/spikes/channel-eq-census.md:27`, `docs/spikes/channel-eq-census.md:28`).

The current verified-param path only activates Compressor `threshold`; other params fail closed as `unsupported_param_readback` (`docs/spikes/channel-eq-census.md:29`, `Sources/LogicProMCP/Channels/AccessibilityChannel+VerifiedPlugins.swift:508`, `Sources/LogicProMCP/Channels/AccessibilityChannel+VerifiedPlugins.swift:510`). The stock catalog keeps Channel EQ insert-only and explicitly says the parameter registry is census-gated (`Sources/LogicProMCP/Plugins/StockPluginCatalog.swift:891`, `Sources/LogicProMCP/Plugins/StockPluginCatalog.swift:895`, `Sources/LogicProMCP/Plugins/StockPluginCatalog.swift:896`).

`rename_marker` is similarly honest-deferred. The dispatcher validates index/name, routes `nav.rename_marker`, but the API docs and spike state that Logic 12.x has no verified AX text-edit path and returns State C `not_implemented` (`Sources/LogicProMCP/Dispatchers/NavigateDispatcher.swift:157`, `Sources/LogicProMCP/Dispatchers/NavigateDispatcher.swift:173`, `docs/API.md:170`, `docs/spikes/channel-eq-census.md:47`, `docs/spikes/channel-eq-census.md:49`).

## 2. Goals

- Find a non-GUI-AX or version-gated GUI path that can produce a real Channel EQ parameter census.
- Activate Channel EQ parameters only from measured canonical id, source, unit, range, tolerance, write method, and read-back method.
- Keep unknown Channel EQ params fail-closed with `unsupported_param_readback`.
- Prove or reject a `rename_marker` State A path with marker identity, editable surface, write, read-back, and rollback.

## 3. Non-Goals

- Do not infer Channel EQ band ids, units, ranges, or tolerances from UI labels alone.
- Do not register inert/TODO params as production-writable.
- Do not use visual pixel matching as a read-back source.
- Do not change marker rename from `not_implemented` unless a live write/read-back/rollback gate passes.

## 4. Non-Negotiable Gates

### Channel EQ State A Gate

No registry activation without a census artifact containing:

- canonical plugin id and parameter id
- source surface (`audio_unit_api`, `automation_lane`, `preset_roundtrip`, `control_surface_feedback`, or `gui_ax`)
- unit and value range
- write method and read-back method
- tolerance and normalization mapping
- Logic version and locale
- live write/read-back proof on a duplicate/scratch project

### rename_marker State A Gate

No implementation without:

- marker list/global-track surface visible
- marker identity captured before write
- AX or other deterministic editable text path
- post-write marker list read-back
- rollback to original marker name with read-back

## 5. Candidate Surfaces

### 5.1 AudioUnit Parameter API

Hypothesis: Channel EQ parameters may be enumerated and read/written through AU parameter APIs rather than Logic's hosted GUI. This is an unverified candidate.

Main risk: the plugin instance lives inside Logic's process; an external MCP process may not get an `AudioUnit` handle to the loaded insert. If only standalone AU factory metadata is available, it can inform ids/ranges but not prove write/read-back against Logic's active instance.

Priority: P0, because the spike evidence names AU parameter enumeration as the most promising non-GUI path (`docs/spikes/channel-eq-census.md:42`, `docs/spikes/channel-eq-census.md:44`).

### 5.2 Plugin Automation Parameter Surface

Hypothesis: Logic automation lanes may expose plugin parameters with readable names and values even when the plugin window is AX-opaque. This is an unverified candidate.

Risk: automation lane writes may alter project automation data rather than current plugin state; read-back may be lane text rather than parameter value. Must use a scratch duplicate and rollback/delete automation.

Priority: P1.

### 5.3 Logic Project / Preset State Introspection

Hypothesis: saving a Channel EQ setting, plugin preset, or scratch project could expose parameter state in `.aupreset`, plist, or package data.

Risk: preset save may invoke another modal save panel; project chunks may be opaque; values may be serialized but not tied to selected track/insert identity. **CTO cross-reference**: Logic's save panels are the same AX-opaque remote-view class that blocked MIDI export (`docs/spikes/midi-export-t0-evidence.md` — NSSavePanel wall; see `PRD-midi-readback-vNext` §1). Do NOT re-discover this wall — the preset-save spike must first check whether the preset save path presents that panel class, and if so, either reuse the MIDI epic's non-panel findings or route around it (e.g. Logic's channel-strip-setting save that writes to a known directory without a panel, if proven).

Priority: P1 for read-only census, P2 for write/read-back.

### 5.4 Control-Surface / MIDI Feedback

Hypothesis: Logic's control-surface parameter pages may expose Channel EQ values through MCU/OSC feedback.

Risk: plugin parameter page focus and banking are nondeterministic; feedback may be display text rather than exact numeric read-back; writes may require controller assignment state.

Priority: P2.

### 5.5 GUI AX Only-If-Proven

Hypothesis: a future Logic version, a different host context, or a specific view mode may expose per-band controls.

Gate: rerun the census script; activation remains forbidden unless the artifact contains actual `AXSlider`/value elements and write/read-back proof.

Priority: continuous version gate.

### 5.6 rename_marker Marker-List Surface

Hypothesis: Marker List or the global Marker track may provide an editable text field with post-write read-back.

Spike: show Marker global track/list, create a scratch marker, capture marker list before state, attempt rename in a duplicate/scratch project, read back list, rollback original name.

Priority: P1. If the list remains empty or no editable text path appears, keep `not_implemented`.

## 6. Product Surface

Channel EQ activation extends the existing `logic_plugins.set_param_verified` contract. It must not add a parallel API unless the verified-param model cannot represent the proven surface.

`rename_marker` keeps its existing command name and validation rules. If implemented, it returns HC State A only after marker read-back; otherwise it remains State C `not_implemented`.

## 7. Ticket Board

Execution tickets live under `docs/tickets/channel-eq-verified-params-vNext/`:

- T0: AudioUnit parameter API census spike.
- T1: Preset/project-state census spike.
- T2: Control-surface/automation feedback spike.
- T3: Channel EQ registry activation after a census gate passes.
- T4: `rename_marker` live gate and optional implementation split.

## 8. Testing Strategy

- Unit: registry lookup, canonical id aliases, tolerance math, unsupported param fail-closed.
- Integration: mock write/read-back surface for the proven method.
- Live E2E: one Channel EQ State A write/read-back case on a scratch duplicate; one unsupported param State C case.
- Marker E2E: scratch marker rename, read-back, rollback, and no-marker failure.

## 9. Open Questions

- Can the external process obtain active Logic insert parameter handles, or only factory metadata?
- Does Logic automation lane text expose exact numeric values or display-only labels?
- Can preset save/export be driven without another blocked save panel?
- Does Marker List become AX-editable only when a specific global track/list window is open?
