# Verification Evidence - Issue #15 Hardening Round (2026-06-10)

Date: 2026-06-10 KST
Branch: `feature/issue-15-workflow-skills-pack`
Scope: post-review hardening of the workflow skills pack, Logic Pro 12.2 host.

## Review Inputs

- Adversarial review: Codex gpt-5.5 (`model_reasoning_effort=xhigh`), verdict on the pre-hardening branch: FAIL (2 P1 / 3 P2 / 1 P3).
- Cross-check: 2026-06-08/09 full-repo enterprise review.
- Dispatcher-source evidence motivating R3: the pre-hardening pack referenced `midi_import`, which exists in no dispatcher; the real command is `logic_midi.import_file`, and `record_sequence` lives on `logic_tracks`.

## Findings → Fixes

| Finding (severity) | Fix |
|---|---|
| Phantom stock URIs hardcoded into the lint surface (P1) | Hardcoded union removed. Template-aware resolution against the real `ResourceProvider` surface; unresolvable refs must be declared per-workflow in `depends_on` or lint fails (`unknown_resource`). Served workflows expose computed `dependencies_resolved` + `unresolved_resources`. |
| Commands not validated; stale `midi_import`/generic marker refs (P1) | `WorkflowStep.command` + per-tool `publicCommands` census linting (`unknown_command`, `mutating_step_missing_command`); census pinned to dispatcher sources by `WorkflowCommandCensusTests`; recipes corrected (`import_file`, `record_sequence`, `create_marker`, `rename_marker`, `set_volume`, `insert_plugin`). |
| `mutation_kind` could lie (P2) | Bidirectional `mutation_kind_mismatch` lint. |
| Free-form confirmation levels (P2) | Levels restricted to `L1`/`L2`; mutating steps must be covered by a declared confirmation in level and command. |
| Version identity under grown surface (P2) | Documented contract: merge ⇒ next release must be `v3.5.0`; packaging untouched on branch by design. |
| Placeholder convention mismatch `<text>` vs `{query}` (P3) | Unified on template forms (`{query}`, `{id}`); schema `fields` generated from `CodingKeys` and pinned by test. |

Additional hardening: `live_verified_missing_evidence_file` lint + repo-file existence test for referenced evidence; fail-closed `URLComponents` routing for workflow resources with single-decode regression test; shared `ResourceJSONHelpers.swift` byte-identical with the #14 branch; truth-faithful limitations (relative `set_pan` V-Pot semantics, keycmd-only `delete_marker`/indexed `goto_marker`/`project.bounce`).

## Deterministic Gates

| Gate | Result | Evidence |
|---|---:|---|
| Format check | PASS | `git diff --check` exit 0. |
| Workflow suites | PASS | `swift test --no-parallel --filter Workflow` → 24 tests passed. |
| Full test suite | PASS | `swift test --no-parallel` → 1229 tests passed. |
| Release build | PASS | `swift build -c release` → build complete. |
| Python E2E syntax | PASS | `PYTHONPYCACHEPREFIX=/private/tmp/lpm-pycache18 python3 -m py_compile Scripts/live-e2e-test.py` exit 0. |

## Release-Binary Read-Only Smoke

```json
{
 "ok": true,
 "resource_count": 10,
 "template_count": 5,
 "workflow_count": 7,
 "workflow_pack_valid": true,
 "insert_production_ready": true,
 "insert_evidence_level": "live_verified",
 "insert_dependencies_resolved": false,
 "insert_unresolved": [
  "logic://stock-plugins/logic.stock.effect.gain",
  "logic://stock-plugins/{id}"
 ],
 "insert_step_commands": ["insert_plugin"],
 "readiness_dependencies_resolved": true,
 "schema_has_lint_rules": true,
 "malformed_uri_fails_closed": true
}
```

`resource_count` is 10 because `logic://mcu/state` is hidden while the MCU surface is disconnected.

The key honesty change: the live-verified Gain insert workflow is now served with `dependencies_resolved: false` and an explicit `unresolved_resources` list on this branch, because the #14 stock catalog is not part of this build. After #14 merges and this branch rebases, the same computation flips to `true` mechanically (covered by `dependenciesResolveWithStockSurface`).

## Convergence Round 2→3

Round-2 re-review (Codex gpt-5.5 xhigh): all 6 round-1 findings **CLOSED**; verdict PASS-WITH-CONDITIONS with 4 new edges, all fixed in the follow-up commit:

| New finding | Fix |
|---|---|
| Confirmation coverage validated as independent level/command sets (P2) | Exact `(level, command)` pair validation + regression test |
| Empty path segments accepted (`//schema`, trailing `/`) (P2) | Canonical-path guard in routing; `omittingEmptySubsequences: false` in template matching; tests |
| Census contained not-exposed stubs (`set_color`, `set_send`, `set_output`, `set_input`, `toggle_eq`, `reset_strip`, `bypass_plugin`) (P2) | Stubs removed; census test fails on "not exposed" case bodies; explicit exclusion test |
| `depends_on` accepted arbitrary prefixes like `logic:` (P3) | `invalid_dependency` lint; only `logic://<host>` roots cover refs |

Round-3 gates: `swift test --no-parallel` → **1232 tests passed**; `swift build -c release` PASS; `git diff --check` PASS.

## Live Mutation Evidence (unchanged)

The live-verified mutating workflow remains backed by `docs/tickets/mixer-verification/VERIFICATION-2026-06-09.md` (Logic Pro 12.2, `insert_plugin` State A with `verified:true`, `verify_source:"ax_plugin_slot"`, fail-closed `slot_occupied` repeat). A deterministic test now proves the referenced evidence file exists in the repo.
