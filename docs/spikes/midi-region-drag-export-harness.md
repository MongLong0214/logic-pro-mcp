# MIDI Region Drag Export Harness Evidence

Date: 2026-07-07

## Scope

This PR adds a guarded live harness for `PRD-midi-readback-vNext` T0. It does **not**
claim a State A selected-region read-back surface.

## Harness

- Script: `Scripts/spike-midi-region-drag-export.swift`
- Default behavior: refuses to post mouse events unless
  `LOGIC_PRO_MCP_ARM_REGION_DRAG=1` is set.
- Required armed arguments: `--source x,y`, `--destination x,y`, optional
  `--export-dir <path>`.
- Controlled file gate: snapshots `.mid` files in the export directory before drag,
  then reports only a newly modified positive-size `.mid`.

## Verified Dry Run

Command:

```bash
swift Scripts/spike-midi-region-drag-export.swift
```

Observed result:

```json
{"record_type":"region_drag_preflight","status":"blocked","note":"Refusing live drag until LOGIC_PRO_MCP_ARM_REGION_DRAG=1 is set; this prevents accidental timeline mutation."}
```

Exit code: `2` as expected for an unarmed hazardous operation.

## Remaining Gate

Live Logic QA is still required before T3/T4 can start:

- scratch project only
- known sentinel MIDI region
- verified source/destination screen coordinates
- post-drag `.mid` parse via `SMFReader`
- sentinel equality
- in-Logic rollback verification if no controlled file appears
