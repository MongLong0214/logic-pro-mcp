# T3 — Presentation (renderer modes, TTY/color, headline, entrypoint flags)

**Size**: M
**Depends on**: T1
**PRD ACs**: G5, AC-3.3, AC-4.2, AC-4.3, AC-5.1–5.5, E8, E9, E14
**Files**: `Sources/LogicProMCP/Utilities/SetupDoctor.swift`, `Sources/LogicProMCP/MainEntrypoint.swift`,
`Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift`, `Tests/LogicProMCPTests/MainEntrypointDoctorTests.swift` (or existing entrypoint test file)

## Goal
Replace the single `renderHuman` with a 3-mode, TTY/color-aware renderer + a "next action" headline, and wire
`--verbose`/`--quiet`/`--check-updates` flags + `--json` precedence in `MainEntrypoint`.

## Design
- `enum OutputMode { default, verbose, quiet }`.
- `renderHuman(_ report:, mode: OutputMode, useColor: Bool) -> String`:
  - Header: `headline` line first; then `summary: N passed, M failed, K warning(s) (Tms)` (AC-3.3); then the
    existing `schema/status/version/install_source` block (kept for back-compat of the human shape).
  - Per-check line: symbol + id + " - " + summary. Symbol set TTY/color: ✓ (green) pass, ✗ (red) fail,
    ⚠ (yellow) warn, • manual, ∅/- skipped; plain fallback `[pass]`/`[fail]`/`[warn]`/`[manual]`/`[skipped]`.
  - default: per-check line + `  → remediation` only for non-pass.
  - verbose: + `    evidence: k=v` lines + `    duration_ms: N`.
  - quiet: headline + summary line + non-pass check lines only (no all-pass listing).
  - useColor=false → no ANSI escapes, plain `[status]` symbols (byte-clean for pipes/CI).
- `SYMBOLS`/ANSI helper kept internal; gated entirely by `useColor`.
- `MainEntrypoint`:
  - inject `isStdoutTTY: () -> Bool` (production `isatty(STDOUT_FILENO) != 0`) and
    `environment: [String:String]` (or a `noColor: () -> Bool`) so tests pin both branches.
  - `useColor = isStdoutTTY() && environment["NO_COLOR"] == nil`.
  - mode: `--verbose` → verbose; else `--quiet` → quiet; else default. `--verbose` wins over `--quiet` (E9).
  - **`--json` precedence (AC-5.5/E14):** if `--json` present, emit `encodeJSON(report)` regardless of
    verbosity/color — identical bytes. Else `renderHuman(report, mode, useColor)`.
  - `--check-updates` detection → pass a non-nil `latestReleaseLookup` into the doctor runtime (T4 supplies the
    production lookup; T3 only wires the flag plumbing + a no-op/injected lookup for tests).

## TDD — Red first
1. `test_default_render_shape`: contains headline, `summary:` line, per-check lines, `→` only on non-pass.
2. `test_verbose_render_adds_evidence_and_duration`: verbose output contains `evidence:` and `duration_ms`.
3. `test_quiet_render_only_nonpass`: quiet output excludes pass lines, includes headline + summary + fails.
4. `test_color_on_tty`: useColor=true → output contains an ANSI escape (`\u{1B}[`) and a unicode symbol.
5. `test_plain_when_not_tty` (E8): useColor=false → no `\u{1B}[`, uses `[pass]`-style tokens.
6. `test_entrypoint_no_color_env` : isStdoutTTY=true but NO_COLOR set → plain output.
7. `test_entrypoint_json_beats_verbose` (E14): args `doctor --json --verbose` → output == plain `doctor --json`
   bytes (parse both, assert equal); no ANSI.
8. `test_entrypoint_verbose_beats_quiet` (E9): `--verbose --quiet` → verbose shape.
9. `test_entrypoint_exit_code_verbosity_independent` (AC-1.3 spirit): a failing report exits 1 under default,
   `--quiet`, and `--verbose`.
10. `test_headline_render` (AC-4.2/4.3): non-pass → headline names highest-severity; all-pass → healthy line.
11. Regression: existing entrypoint doctor tests (JSON to stdout, does-not-start-server) still pass.

## Acceptance
- All render/entrypoint tests green `swift test --no-parallel`. JSON contract unchanged by verbosity/color.
