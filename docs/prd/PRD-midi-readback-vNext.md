# PRD: MIDI Read-Back vNext

**Version**: 0.1
**Author**: CEO/CTO planning rail (Fable role model, execution by Codex)
**Date**: 2026-07-07
**Status**: Draft-ready for ticket execution
**Size**: L

## 1. Problem Statement

T5a shipped the reusable `SMFReader` and `ExportTemporaryFiles` foundation, but T5b remains honest-deferred. The proven menu path can reach `File > Export > Selection as MIDI File`, and `record_sequence` can create a sentinel MIDI region with region identity, but Logic's Save MIDI File panel is an out-of-process NSSavePanel remote view whose inner controls are AX-opaque and whose keyboard focus does not accept synthetic input (`docs/spikes/midi-export-t0-evidence.md:9`, `docs/spikes/midi-export-t0-evidence.md:13`, `docs/spikes/midi-export-t0-evidence.md:18`, `docs/spikes/midi-export-t0-evidence.md:20`, `docs/spikes/midi-export-t0-evidence.md:21`).

The current repo therefore has a parser and private export-file registry, but no public `logic_midi.read_selection_notes` or `record_sequence verify_notes` State A surface. The release notes explicitly claim no public read-back command was shipped (`CHANGELOG.md:21`, `CHANGELOG.md:43`).

## 2. Goals

- Find at least one evidence-backed path that creates a controlled `.mid` artifact from the selected Logic region without the blocked NSSavePanel path.
- Keep the State A rule strict: controlled file creation, `SMFReader` parse, sentinel equality, and selected-region identity must all pass.
- Add `logic_midi.read_selection_notes` only after a live gate proves the selected-region export surface.
- Add `record_sequence verify_notes:true` only after deterministic created-region selection and export read-back are proven.
- Preserve the shipped v3.9.0 contract that no read-back command is claimed while the gate is unproven.

## 3. Non-Goals

- Do not weaken T5b into a "best effort" parser of uncontrolled exports.
- Do not read arbitrary user `.mid` files through this feature; user-supplied import/read is a separate security surface.
- Do not add a public resource for notes. Export/read-back is a side-effecting tool flow, not a read-only MCP resource.
- Do not promote operator-assisted/manual flows to default automation without an explicit profile or CLI flag.

## 4. Evidence Baseline

- Working: export-menu navigation under the exact `Export` parent and the `Selection as MIDI File` child (`docs/spikes/midi-export-t0-evidence.md:9`, `docs/spikes/midi-export-t0-evidence.md:11`, `docs/spikes/midi-export-t0-evidence.md:12`).
- Working: `record_sequence` sentinel import and `logic_project.get_regions` identity (`docs/spikes/midi-export-t0-evidence.md:13`).
- Blocked: NSSavePanel inner controls expose no actionable AX elements (`docs/spikes/midi-export-t0-evidence.md:20`).
- Blocked: synthetic keyboard input does not reach the panel, and mouse-only control cannot set a controlled directory/filename (`docs/spikes/midi-export-t0-evidence.md:21`, `docs/spikes/midi-export-t0-evidence.md:22`).
- Operational risk: menu/panel automation can wedge Logic and require force-termination (`docs/spikes/midi-export-t0-evidence.md:23`).
- Foundation: `SMFReader` supports format 0/1 and strict malformed-input errors (`Sources/LogicProMCP/MIDI/SMFReader.swift:29`, `Sources/LogicProMCP/MIDI/SMFReader.swift:35`, `Sources/LogicProMCP/MIDI/SMFReader.swift:41`, `Sources/LogicProMCP/MIDI/SMFReader.swift:127`).
- Foundation: `ExportTemporaryFiles` creates private registered export files and cleans owned directories (`Sources/LogicProMCP/MIDI/ExportTemporaryFiles.swift:36`, `Sources/LogicProMCP/MIDI/ExportTemporaryFiles.swift:48`, `Sources/LogicProMCP/MIDI/ExportTemporaryFiles.swift:53`).

## 5. State A Gate

State A is forbidden unless all four conditions are true:

1. The exported file path is pre-registered by `ExportTemporaryFiles`, absent before export, then present after export with positive size and fresh mtime.
2. `SMFReader.parse` succeeds and returns no partial result on malformed data.
3. The exported note set equals the sentinel/requested note set after tempo/time-signature normalization.
4. The selected region identity captured before export matches the exported region identity or the deterministic created-region identity.

Failure policy:

- Missing controlled file: State C `controlled_export_unavailable`.
- File exists but parse fails: State C `smf_parse_failed`.
- Identity unavailable before export: State B `selection_identity_unverified`.
- Notes mismatch: State C `readback_mismatch`.
- Modal/menu recovery required: State C `logic_modal_recovery_required`, no retry loop.

## 6. Candidate Surfaces

### 6.1 Region Drag-to-Finder Export

Hypothesis: dragging a selected MIDI region from Logic to a controlled Finder folder may create a `.mid` without the save panel. This is an unverified candidate.

Spike: create a scratch project and sentinel region, open a controlled temp Finder window, capture region bounds, drag to the temp folder with mouse-only HID, assert one new `.mid` under the registered directory, parse and compare.

Failure modes: region drag may create audio/alias/project data instead of MIDI; drag coordinates can hit the wrong region; Finder may rename files nondeterministically; **an errant drag that never leaves Logic's arrange area MOVES the region in the timeline — a destructive project mutation** (CTO). Recovery must close Finder, Escape any open menu/dialog, **and assert in-Logic rollback: Cmd+Z until the region's original position/identity reads back, and the scratch project is discarded without saving**. This candidate is scratch-project-only forever — never against a user project, even after activation (the production surface must create/duplicate its own export context).

Priority: P0. It directly bypasses the blocked keyboard path while preserving controlled-directory evidence.

### 6.2 Non-Panel Export Trigger

Hypothesis: Logic may expose a key command, AppleScript/JXA menu command, Shortcuts action, or hidden export route that writes Selection-as-MIDI without presenting NSSavePanel. This is an unverified candidate.

Spike: enumerate Logic Key Commands export actions, AppleScript dictionaries, and JXA menu events; attempt only read-only discovery first. Any write attempt must target a scratch project and `ExportTemporaryFiles` directory. **CTO note**: assigning a Logic key command is a manual operator step — Logic 12.2+ refuses programmatic key-command import (repo-established; `Scripts/install-keycmds.sh` documents the import refusal), so any keycmd-based route inherits the manual-validation/approval model and cannot be silently autonomous.

Failure modes: key command still opens the same panel; AppleScript may only click the menu; Shortcuts may not expose Logic document export.

Priority: P1. Lower fragility than drag if a real non-panel route exists.

### 6.3 Operator-Assisted Controlled Export

Hypothesis: an explicit operator-approved mode can ask the user to complete the save panel once while the server verifies the resulting file. This cannot be default automation.

Spike: server pre-registers a target path and displays it in a CLI/human prompt; operator saves to that exact path; server watches for file creation, parses, and verifies sentinel equality.

Failure modes: wrong path, wrong region, stale file, operator timeout. This must return State B/C unless the exact path and notes match.

Priority: P2. Useful for power users, but not agent-autonomous.

### 6.4 Logic Project/Package Event Reader

Hypothesis: selected MIDI region data may be recoverable from `.logicx` package internals or existing project readers without exporting. This is an unverified candidate.

Spike: on a scratch project with one sentinel region, save a copy, inspect package deltas and existing `LogicProjectFileReader` capabilities, and verify whether note events are accessible without private or unstable binary parsing.

Failure modes: proprietary chunk format, compressed opaque data, no selected-region mapping, project save side effects.

Priority: P1 if a stable package surface is found; otherwise defer.

### 6.5 Lower-Level Logic/AU/CoreMIDI APIs

Hypothesis: CoreMIDI, AU, or private Logic APIs may expose region contents. This is an unverified candidate and must not rely on private APIs in production without a separate distribution/security decision.

Spike: read-only investigation only; no private API linking in production code during this epic.

Priority: P3 unless public APIs prove sufficient.

### 6.6 Future Logic Build Gate

Hypothesis: a newer Logic build may expose the save panel or region export controls differently. This is a version-gated rerun of the T0 evidence, not an implementation ticket.

Spike: rerun `Scripts/spike-midi-export.py` against the new Logic version and append evidence before any activation.

Priority: ongoing gate.

## 7. Product Surface

When a State A surface is proven:

- Add `logic_midi.read_selection_notes` routed through Accessibility.
- Return HC envelope with `notes`, `selection_identity`, `export_evidence`, `smf_summary`, and `readback_source`.
- Add `verify_notes: Bool = false` to `logic_tracks.record_sequence`.
- Keep default `record_sequence` behavior unchanged when `verify_notes` is false.

## 8. Ticket Board

Execution tickets live under `docs/tickets/midi-readback-vNext/`:

- T0: Region drag-to-Finder export spike.
- T1: Project/package event-reader spike.
- T2: Operator-assisted export contract.
- T3: `read_selection_notes` implementation after a surface gate passes.
- T4: `record_sequence verify_notes` integration after T3.

Each implementation ticket is blocked until one T0/T1/T2 evidence gate produces a reproducible controlled export/read-back path.

## 9. Manual QA Gate

Manual QA requires a fresh scratch Logic project, a three-note sentinel region, a controlled temp export directory, and captured evidence showing no modal remains open after success or failure. A successful QA run must include both happy path and deliberate wrong-selection/wrong-file failure.

## 10. Open Questions

- Does region drag-to-Finder produce MIDI data or only arrange-region references?
- Can Logic's own Key Commands assign an export target without opening NSSavePanel?
- Is an operator-assisted mode acceptable as an explicitly non-default profile?
- Are `.logicx` internals stable enough to justify a read-only parser, or does that cross into brittle reverse engineering?
