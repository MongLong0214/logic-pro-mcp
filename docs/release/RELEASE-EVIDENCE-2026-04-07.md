# Release Evidence 2026-04-07

## Version

- Target tag: `v2.0.0`
- Date: `2026-04-07`
- Session type: local live Logic Pro validation

## Release Workflow

- GitHub release execution: not completed in this session
- `gh auth status`: token invalid for account `MongLong0214`
- Result: signed release execution remains blocked on fresh GitHub authentication and repository secrets

## Local Runtime Preconditions

- Logic Pro process visible in this session:
  - `/Applications/Logic Pro.app/Contents/MacOS/Logic Pro`
- `LogicProMCP --check-permissions`:
  - `Accessibility: granted`
  - `Automation (Logic Pro): granted`
- `LogicProMCP --list-approvals`:
  - `MIDIKeyCommands: approved at 2026-04-06T13:11:19Z`
  - `Scripter: approved at 2026-04-06T13:11:19Z`

## Logic Pro Manual Setup Evidence

- Opened `Logic Pro > 컨트롤 서피스 > 구성 설정…`
- Opened `신규 > 설치`
- Added `Mackie Control` (`Logic Control` module)
- Set:
  - output port = `LogicProMCP-MCU-Internal`
  - input port = `LogicProMCP-MCU-Internal`

## Captured Health

`logic_system.health` returned:

- `logic_pro_running = true`
- `logic_pro_version = "12.0.1"`
- `Accessibility.ready = true`
- `AppleScript.ready = true`
- `CGEvent.ready = true`
- `CoreMIDI.ready = true`
- `MIDIKeyCommands.ready = true`
- `Scripter.ready = true`
- `MCU.available = true`
- `MCU.ready = true`
- `mcu.connected = true`
- `mcu.registered_as_device = true`
- `mcu.port_name = "LogicProMCP-MCU-Internal"`

Interpretation:

- MCU device registration was confirmed in the live runtime payload
- MCU feedback is active and the channel is runtime-ready
- Live E2E closure for `T3` is complete

## Live Command Evidence

The following commands succeeded against the live Logic Pro session:

- `logic_transport play` -> `Transport: play`
- `logic_transport stop` -> `Transport: stop`
- `logic_transport record` -> `Transport: record`
- `logic_tracks select(index: 0)` -> `select off for track 0`
- `logic_tracks set_automation(index: 0, mode: trim)` -> `Automation mode: trim`
- `logic_mixer set_volume(track: 0, value: 0.7)` -> `Volume set to 0.7 on track 0`
- `logic_mixer set_pan(track: 0, value: 0.1)` -> `Pan set to 0.1 on track 0`
- `logic_mixer set_plugin_param(track: 0, insert: 0, param: 1, value: 0.5)` -> `Scripter param 1 set to 0.5 on insert 0 (CC 103 val 64)`
- `logic_edit undo` -> `Key command triggered: edit.undo (CC 30 CH 16)`

## Post-Fix Local Verification

- `swift build -c release` passed after the final documentation and runtime-hardening edits
- `swift test --skip-build --enable-code-coverage --no-parallel` emitted `Test run with 368 tests passed`
- xUnit output at `/tmp/logic-pro-tests.xml` recorded:
  - `tests="368"`
  - `failures="0"`
  - `errors="0"`
- Final local fixes in this session included:
  - isolating `ManualValidationStore` usage in `MIDIKeyCommands` and `Scripter` health tests
  - making `PermissionChecker` return `not_verifiable` when Logic Pro is not running, before probing Automation

## Remaining Blockers

- `T1` remains blocked by invalid GitHub authentication in this session
- The current working tree includes release-readiness changes beyond the existing local `v2.0.0` tag, so the final shipping tag/version must be chosen before official release execution
- `T2` remains blocked on `T1` because a real signed/notarized release artifact is still required before clean-machine validation
- `T4` remains open until release evidence is frozen after `T1` and `T2`

## Recommended Closeout Decision

Close `T3` as complete and carry forward only the operational release blockers:

1. Execute one real signed/notarized/stapled GitHub release (`T1`)
2. Validate installer/uninstaller on clean `arm64` and `x86_64` macOS machines (`T2`)
3. Freeze final release evidence and docs after those two steps (`T4`)
