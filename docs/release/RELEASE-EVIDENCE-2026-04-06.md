# Release Evidence 2026-04-06

## Version

- Tag: `v2.0.0-rc.1`
- Commit: local workspace snapshot
- Date: `2026-04-06`

## Build Evidence

- `swift build -c release`: PASS
- `swift test`: PASS (`360` tests)
- `swift test --enable-code-coverage --no-parallel`: PASS (`360` tests)
- Coverage: `95.28%` for `Sources/LogicProMCP` (`5011 / 5259` lines)

## Local Machine Baseline

- macOS: `26.3` (`25D125`)
- Architecture: `arm64`
- Logic Pro: `12.0.1` (`6590`)

## Release Workflow

- Codesign: configured in workflow, not executed from this local session
- Notarization: configured in workflow, not executed from this local session
- Stapling: configured in workflow, not executed from this local session
- `spctl` verification: pending real signed release

## Install Validation

- `macos-15`: encoded in `.github/workflows/release.yml`, not yet executed in this session
- `macos-13`: encoded in `.github/workflows/release.yml`, not yet executed in this session

## Logic Pro E2E

- Accessibility: `NOT GRANTED`
- Automation: `NOT VERIFIABLE`
- MCU registered: not validated in this session
- Key Commands approved: not validated in this session
- Scripter approved: not validated in this session
- `logic_system.health`: blocked by missing live Logic Pro runtime

## Local E2E Attempt Notes

- `/Applications/Logic Pro.app` exists and reports `12.0.1 (6590)`.
- `open '/Applications/Logic Pro.app'` returned success from this session.
- `ps -axo pid,ppid,lstart,command` still showed no `Logic Pro` process after launch attempts.
- `./.build/release/LogicProMCP --check-permissions` reported:
  - `Accessibility: NOT GRANTED`
  - `Automation (Logic Pro): NOT VERIFIABLE (Logic Pro not running)`

## Residual Risks

- Live Logic Pro E2E remains blocked until the terminal process has Accessibility permission and Logic Pro stays visibly running in the same macOS session.
- Real signed/notarized release is still blocked by missing live GitHub release execution from this session.
