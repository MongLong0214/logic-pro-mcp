# PRD: Issue #210 - Native CGEvent bounce backend

**Status**: Superseded by the native CGEvent backend
**PR**: #211

## Current Decision

Bounce/export must not depend on any third-party click binary. The Swift export path launches the packaged
`Scripts/logic_bounce.py` helper directly, and that helper posts mouse/keyboard events through ApplicationServices
CGEvent APIs.

## Acceptance Criteria

- `project.bounce` and export helper execution never resolve, require, or invoke a third-party click binary.
- `doctor` does not emit a compatibility dependency check for the removed tool.
- `system.health` does not expose compatibility dependency fields for the removed tool.
- Install, Homebrew, release workflow, and setup docs contain no install or remediation path for the removed tool.
- Repo text search for the removed binary name returns zero source/documentation hits.

## Verification

- Swift contract tests cover `runBounceHelper` launching `logic_bounce.py` directly.
- Python unit tests cover `send_ui_events` through the native event driver abstraction.
- Release gate runs `swift test --no-parallel`, Python helper tests, and a repo text search guard.
