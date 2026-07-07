# T2: Automation / Control-Surface Feedback Spike

**PRD Ref**: `PRD-channel-eq-verified-params-vNext` §5.2 and §5.4
**Priority**: P2
**Status**: Todo
**Depends On**: None

## Objective

Evaluate Logic automation lanes and control-surface feedback as possible Channel EQ value read-back surfaces.

## Acceptance Criteria

- [ ] Automation-lane path records whether parameter names and values are exact, normalized, or display-only.
- [ ] MCU/OSC path records whether plugin parameter banking can target Channel EQ deterministically.
- [ ] Any write attempt is on a scratch duplicate and rolled back.
- [ ] No production claim if the surface cannot prove track/insert/param identity and numeric read-back.

## Red Tests

- `automationSurfaceRejectsDisplayOnlyReadback`
- `controlSurfaceRequiresFocusedPluginIdentity`
- `controlSurfaceStateBOnEchoTimeout`

## Implementation Boundary

Spike scripts and evidence only. No `MCUChannel` production changes unless a later ticket is created.

## Manual QA Gate

Capture both the parameter-targeting step and the read-back payload.
