# T5 — Docs (SETUP.md anchors, API.md v2 fields)

**Size**: S
**Depends on**: T1–T4
**PRD ACs**: G6 (doc the schema bump), §9.1
**Files**: `docs/SETUP.md`, `docs/API.md`

## Goal
Document the v2 report and the new checks so remediation anchors resolve and operators understand the new fields.

## Design / changes
- `docs/SETUP.md`:
  - Add anchored sections for new check IDs so `remediationAnchorsByCheckID` resolves:
    `#doctor-permissionsautomation-system-events`, `#doctor-dependenciescliclick`, `#doctor-systemmacos-version`,
    `#doctor-updateslatest-release`.
  - Document `--verbose` / `--quiet` / `--check-updates` flags + that color is TTY/`NO_COLOR`-gated.
  - Note `brew install cliclick` is required for bounce/export.
- `docs/API.md`:
  - Document `logic_pro_mcp_doctor.v2`: the new `summary` block, per-check `category`/`severity`/`duration_ms`,
    `headline`; state it is a field-superset of v1 and consumers should prefix-match the schema string.

## TDD / verification
- Style/text change — no Red test. Verify by:
  - grep that every `remediationAnchorsByCheckID` value's `#anchor` exists as a heading in `docs/SETUP.md`
    (add a contract test `test_all_remediation_anchors_documented` if cheap: parse the dict, assert each anchor
    substring appears in SETUP.md — hermetic file read from repo root via `#filePath`).
- Markdown lints clean; links resolve.

## Acceptance
- Docs build/lint clean; anchor-existence test green; no broken links.
