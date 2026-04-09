# T3: Live Logic Pro E2E Validation

**PRD Ref**: `PRD-production-hardening` > US-3  
**Priority**: P0  
**Size**: M  
**Status**: Complete  
**Depends On**: None

---

## Objective

Validate one real Logic Pro session end-to-end using the supported operator workflow:
- grant Accessibility and Automation
- register MCU manually in Logic Pro
- insert Scripter manually
- import Key Commands preset manually
- approve manual-validation channels only after verification

## Current Known Progress

- Local live validation completed on `2026-04-07`:
  - `LogicProMCP --check-permissions` reported Accessibility granted and Automation granted
  - `LogicProMCP --list-approvals` showed approved `MIDIKeyCommands` and `Scripter`
  - Logic Pro Control Surfaces setup was opened and `Mackie Control` was added manually
  - MCU input/output were both set to `LogicProMCP-MCU-Internal`
  - `logic_system.health` reported:
    - `MCU.available = true`
    - `MCU.ready = true`
    - `mcu.connected = true`
    - `mcu.registered_as_device = true`
  - Live commands succeeded:
    - `logic_transport.play`
    - `logic_transport.stop`
    - `logic_transport.record`
    - `logic_tracks.select`
    - `logic_tracks.set_automation` with `trim`
    - `logic_mixer.set_volume`
    - `logic_mixer.set_pan`
    - `logic_mixer.set_plugin_param`
    - `logic_edit.undo`
- Final closeout:
  - `MCU device registration confirmed, feedback active` was captured in live `logic_system.health`
  - `mcu.port_name = "LogicProMCP-MCU-Internal"` was present in the runtime payload

## Acceptance Criteria

- [x] `LogicProMCP --check-permissions` reports Accessibility granted and Automation granted
- [x] MCU device is registered in Logic Pro with `LogicProMCP-MCU-Internal`
- [x] Scripter is inserted and verified on the target track
- [x] Key Commands preset is imported and verified
- [x] `LogicProMCP --list-approvals` shows approved `MIDIKeyCommands` and `Scripter`
- [x] `logic_system.health` shows expected runtime-ready channels, including MCU connected/registered
- [x] Live execution evidence exists for:
  - `logic_transport.play`
  - `logic_transport.stop`
  - `logic_transport.record`
  - `logic_tracks.select`
  - `logic_tracks.set_automation` with `trim`
  - `logic_mixer.set_volume`
  - `logic_mixer.set_pan`
  - `logic_mixer.set_plugin_param`
  - `logic_edit.undo`

## Evidence

- `LogicProMCP --check-permissions`
- `LogicProMCP --list-approvals`
- captured `logic_system.health`
- screenshot or recording of Logic Pro setup
- command transcript or test log for live operations
- [RELEASE-EVIDENCE-2026-04-07.md](/Users/isaac/projects/logic-pro-mcp/docs/release/RELEASE-EVIDENCE-2026-04-07.md)

## Invalid Work To Avoid

- Do not replace the operator workflow with brittle UI automation and call it “production-ready”
- Do not approve `MIDIKeyCommands` or `Scripter` before actual Logic Pro validation
- Do not mark MCU ready unless `logic_system.health` confirms it
