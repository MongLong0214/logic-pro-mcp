# PRD: Logic Pro MCP Workflow Skills Pack (Issue #15)

**Status**: Approved for implementation
**Date**: 2026-06-09
**Owner**: Logic Pro MCP
**Related issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/15
**Supersedes**: invalidated combined implementation `8ea264c`

## 1. Problem

Logic Pro MCP exposes many tools and resources, but clients still need repeatable workflows with explicit state checks, safe operation boundaries, stop conditions, and verification evidence. Unstructured prompt recipes drift from real tool/resource names and can imply unsafe autonomy.

## 2. Goals

- Define a workflow skill schema with validation rules.
- Ship a first workflow pack for common Logic Pro MCP jobs.
- Validate every workflow against current public tools/resources and safety gates.
- Expose workflows through read-only MCP resources.
- Integrate stock-plugin planning with #14 catalog resources instead of hard-coded plugin claims.

## 3. Non-Goals

- No fully autonomous DAW agent.
- No external publishing/export automation beyond documented manual steps.
- No bypass of existing destructive policy gates.
- No third-party plugin dependency.
- No production-ready mutating workflow without deterministic validation and live evidence.

## 4. Schema

Every workflow includes:

- `id`
- `title`
- `intent`
- `scope`
- `prerequisites`
- `allowed_tools`
- `allowed_resources`
- `required_confirmations`
- `state_checks`
- `steps`
- `verification`
- `failure_modes`
- `rollback_or_recovery`
- `evidence_level`
- `production_ready`
- `depends_on`
- `limitations`

## 5. Evidence Levels

- `deterministic`: schema/linter validated, no live mutation claim.
- `live_verified`: executed against a scoped live Logic session with evidence.
- `documentation_only`: guidance only; no executable mutation path.
- `experimental`: useful but hidden from production-ready defaults.

No mutating workflow can be `production_ready` unless it is `live_verified`.

## 6. Initial Workflow Pack

- `logic.workflow.readiness.project`: read-only project readiness check.
- `logic.workflow.midi.idea_sketch`: guarded MIDI idea sketch.
- `logic.workflow.arrangement.marker_plan`: marker planning and verification.
- `logic.workflow.mixer.gain_staging_prep`: guarded mixer prep with provenance requirements.
- `logic.workflow.plugins.stock_chain_plan`: #14-backed stock plugin chain planning, planning-only in this release.
- `logic.workflow.plugins.stock_insert_gain_live_verified`: guarded L2 Gain insert workflow backed by Logic Pro 12.2 live AX slot-readback evidence.
- `logic.workflow.bounce.readiness`: bounce readiness checklist with manual export boundary.

## 7. MCP Resources

Read-only resources:

- `logic://workflow-skills`
- `logic://workflow-skills/{id}`
- `logic://workflow-skills/search?query=<text>`
- `logic://workflow-skills/schema`

No workflow resource may execute a workflow or mutate Logic.

## 8. Implementation Tickets

Canonical ticket board: `docs/tickets/issue15-workflow-skills-pack/STATUS.md`

- `I15-T1`: workflow schema models and linter.
- `I15-T2`: first deterministic workflow pack.
- `I15-T3`: read-only MCP resource handlers and registration.
- `I15-T4`: integration/E2E tests for list/detail/search/schema.
- `I15-T5`: docs and verification evidence.

## 9. Acceptance Criteria

- PRD and ticket board exist before implementation.
- Tests cover schema validation, stale tool/resource references, destructive-step guardrails, duplicate IDs, and evidence-level rules.
- Every workflow lists prerequisites, allowed operations, state checks, failure modes, and verification output.
- Mutating workflows include explicit confirmation metadata and stop conditions.
- At least one mutating workflow is `live_verified` before it is marked `production_ready`.
- Workflow examples use current public tool/resource names only.
- #14-dependent workflows reference #14 resources and do not hard-code plugin availability claims.
- Read-only MCP resources expose workflow list/detail/search/schema.
- Documentation includes examples and limitations.
- Verification includes `swift test --no-parallel`, `swift build -c release`, schema/lint validation, and targeted live E2E where available.

## 10. Test Plan

- Linter tests for missing fields, duplicate IDs, stale references, missing confirmation metadata, and invalid production-ready claims.
- Pack tests proving all workflows validate.
- Resource tests for list/detail/search/schema.
- E2E tests through server resource reads.
- Live smoke test records workflow IDs and read-only resource evidence; mutating workflows remain non-production unless live evidence exists.

## 11. ADR

**Decision**: ship #15 as a validated read-only workflow pack with conservative evidence labels.
**Drivers**: prevent prompt recipe drift, preserve safety gates, give clients practical workflows now.
**Alternatives considered**: Markdown-only recipes, autonomous executor, generated recipes from code comments.
**Why chosen**: Markdown-only cannot be linted; autonomous execution is out of scope; generated recipes are too opaque for client trust.
**Consequences**: workflows guide clients instead of executing; production readiness is deliberately strict.
