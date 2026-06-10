# Issue #15 Ticket Board: Logic Pro MCP Workflow Skills Pack

**Issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/15
**PRD**: `docs/prd/PRD-workflow-skills-pack.md`
**Status**: Done

## Tickets

- [x] `I15-T1` Workflow schema and linter
  - Define workflow, steps, confirmations, state checks, verification, failure modes, and evidence levels.
  - Linter rejects stale tool/resource references, duplicate IDs, missing mutating confirmations, and invalid production-ready claims.

- [x] `I15-T2` Initial workflow pack
  - Add project readiness, MIDI idea sketch, marker plan, gain staging prep, stock plugin chain planning, and bounce readiness workflows.
  - Keep #14-dependent workflow planning-only and catalog-backed.

- [x] `I15-T3` MCP resources
  - Register `logic://workflow-skills`, `logic://workflow-skills/{id}`, `logic://workflow-skills/search?query=`, and `logic://workflow-skills/schema`.
  - Keep resources read-only and side-effect free.

- [x] `I15-T4` Tests
  - Unit tests for linter and workflow pack.
  - Resource and server E2E tests for list/detail/search/schema.

- [x] `I15-T5` Docs and evidence
  - Update API docs and client usage notes.
  - Add verification evidence and limitations.

## Done Criteria

- All workflows validate against current public tools/resources.
- Mutating workflows include confirmations and stop conditions.
- No workflow is marked production-ready without matching evidence.
- `swift build -c release`, `swift test --no-parallel`, and doc/schema validation pass.

## Hardening Round (2026-06-10)

Adversarial review (Codex gpt-5.5 xhigh + full-repo review cross-check) returned 2 P1 / 3 P2 / 1 P3 findings. All addressed:

- [x] `R1` Lint-gate bypass removed: `currentResourceURIs()` no longer hardcodes phantom `logic://stock-plugins*` URIs. The linter resolves references against the real `ResourceProvider` surface with template-aware matching; refs that don't resolve must be declared per-workflow in `depends_on` or the lint fails.
- [x] `R2` Honesty surfaced at read time: every served workflow now carries computed `dependencies_resolved` + `unresolved_resources`. The two stock-dependent workflows are served with `dependencies_resolved: false` on this branch (tested); once #14 merges and this branch rebases, they flip to `true` mechanically (tested via injected surface).
- [x] `R3` Command-level validation: `WorkflowStep.command` added and linted against a per-tool public command census (`publicCommands`), which is itself pinned to the dispatcher sources by `WorkflowCommandCensusTests`. The stale `midi_import` reference was corrected to `logic_midi.import_file` (with `logic_tracks.record_sequence` as the declared alternative), and the marker recipe now names `create_marker`/`rename_marker` explicitly.
- [x] `R4` Mutation-kind truth lint: `read_only` with mutating steps and `guarded_mutation` without mutating steps both fail (`mutation_kind_mismatch`).
- [x] `R5` Confirmation levels restricted to `L1`/`L2`; mutating steps must be covered by a declared confirmation in both level and command (`mutating_step_not_covered_by_confirmation`); mutating steps without a command fail (`mutating_step_missing_command`).
- [x] `R6` `live_verified` workflows must reference an evidence file (`live_verified_missing_evidence_file`), and a deterministic test verifies referenced evidence files exist in the repo.
- [x] `R7` Placeholder convention unified on `{query}`/`{id}` template forms; schema `fields` generated from `WorkflowSkill.CodingKeys` (drift-proof, tested); lint rule census exposed in the schema resource.
- [x] `R8` Fail-closed `URLComponents` URI routing for workflow resources (unknown subpaths/params rejected); search query double-decode bug fixed and regression-tested. Shared JSON helpers moved to `ResourceJSONHelpers.swift` (byte-identical with #14's branch to avoid merge collisions).
- [x] `R9` Truth-faithful recipe limitations: `set_pan` relative V-Pot semantics, keycmd-only `delete_marker`/indexed `goto_marker`/`project.bounce` documented in the affected workflows.

## Convergence Round 2→3 (2026-06-10)

Round-2 adversarial re-review (Codex gpt-5.5 xhigh) confirmed all round-1 findings closed and surfaced 3 P2 / 1 P3 new edges — all fixed:

- [x] `R10` Confirmation coverage is now an exact `(level, command)` pair: a command confirmed at L1 no longer licenses an L2 step (`confirmationCoverageIsPairwise` test).
- [x] `R11` Doubled/trailing-slash URIs fail closed in both resource routing (canonical path reconstruction) and template matching (`omittingEmptySubsequences: false`).
- [x] `R12` Command census purged of not-exposed stubs (`set_color`, `set_send`, `set_output`, `set_input`, `toggle_eq`, `reset_strip`, `bypass_plugin`); the census test now fails if a census command's case body is a "not exposed" stub.
- [x] `R13` `depends_on` roots must be well-formed `logic://<host>` URIs (`invalid_dependency` lint); bare `logic:` prefixes no longer cover the URI space.

Release identity note: `serverVersion` stays `3.4.6` on this branch by design — packaging surfaces pin the published v3.4.6 artifacts. Merging this PR requires the next release to ship as `v3.5.0`; do not rebuild/redistribute as `3.4.6`.

## Verification

See `docs/tickets/issue15-workflow-skills-pack/VERIFICATION-2026-06-09.md` and `docs/tickets/issue15-workflow-skills-pack/VERIFICATION-2026-06-10.md` (hardening round).

Final production-readiness pass (2026-06-10):

- `logic_system help` now derives resource/template counts from `ResourceProvider`, preventing stale help/banner counts when #14/#15 public resources are merged in either order.
- `swift test --no-parallel` — 1235 tests passed.
- `swift build -c release` — passed.
- `PYTHONPYCACHEPREFIX=/private/tmp/lpm-pycache-issue15 python3 -m py_compile Scripts/live-e2e-test.py` — passed.
- `git diff --check origin/main` — passed.
- `LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh` — 281/281 passed.
