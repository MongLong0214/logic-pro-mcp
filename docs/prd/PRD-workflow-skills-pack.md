# PRD: Logic Pro MCP Workflow Skills Pack (Issue #15)

**Status**: Draft v0.1 restart
**Date**: 2026-06-09
**Owner**: Isaac / Logic Pro MCP
**Implementation status**: Not started
**Related issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/15

> Restart note: previous implementation commit `8ea264c` is invalidated. It combined #14 and #15, exposed shallow static recipes, and must not be used as implementation evidence. This PRD starts from `main` commit `c626fca` and defines a validation-first workflow system before any new implementation.

## 1. Problem

Logic Pro MCP exposes a powerful tool and resource surface, but clients still need repeatable, safe, verified workflows. Without a structured workflow pack, users and AI clients are forced to improvise long prompt recipes for common jobs like setting up projects, sketching MIDI, arranging markers, preparing gain staging, using stock plugins, and validating a bounce.

Unstructured recipes are risky because they drift from real MCP tool names, omit state checks, hide destructive steps, and can imply automation that the server cannot safely guarantee.

## 2. Goals

- Define a workflow skill schema before implementation.
- Build a validation/lint layer that prevents stale tool, resource, and safety references.
- Provide a first workflow pack for common Logic Pro MCP jobs.
- Make every workflow explicit about prerequisites, state checks, allowed operations, destructive gates, stop conditions, and verification evidence.
- Keep workflow recipes client-facing and honest: workflows guide safe operation; they do not claim full DAW autonomy.
- Integrate with #14 only through verified catalog surfaces, not hard-coded plugin guesses.

## 3. Non-Goals

- No fully autonomous DAW agent.
- No publishing, emailing, uploading, or external distribution.
- No bypass of existing destructive policy gates.
- No third-party plugin dependency.
- No static prompt library that cannot be schema-validated.
- No workflow marked production-ready without deterministic or live evidence.

## 4. Workflow Skill Schema

Each workflow must include:

- `id`: stable workflow identifier;
- `title`: concise display title;
- `intent`: what user job it supports;
- `scope`: what it may and may not touch;
- `prerequisites`: project state, permissions, Logic visibility, MCP resources;
- `allowed_tools`: exact current MCP tool names;
- `allowed_resources`: exact current MCP resource URIs;
- `required_confirmations`: destructive policy levels and when they trigger;
- `state_checks`: reads that must pass before mutation;
- `steps`: ordered operations with expected response shape;
- `verification`: how the client knows the workflow worked;
- `failure_modes`: known failures and required stop behavior;
- `rollback_or_recovery`: when possible, otherwise explicit "manual recovery";
- `evidence_level`: `deterministic`, `live_verified`, `documentation_only`, or `experimental`;
- `depends_on`: optional dependency on #14 plugin catalog or other surfaces.

## 5. Workflow Evidence Levels

| Level | Meaning | Requirements |
|-------|---------|--------------|
| `deterministic` | Validated by schema and unit/integration tests only | Lint plus test fixture |
| `live_verified` | Executed against a real Logic session in a scoped way | Live log, Logic version, before/after evidence |
| `documentation_only` | Safe explanatory workflow, no executable mutation path | Must not imply production-ready execution |
| `experimental` | Known useful pattern but not yet stable | Must be hidden from default production list unless explicitly requested |

No mutating workflow can be `live_verified` without an actual live run.

## 6. Initial Workflow Pack

The first pack should be small but deep. Quality is more important than recipe count.

### W1. Project Readiness Check

Purpose: confirm Logic/MCP state before doing creative work.

Expected contents:

- permissions check;
- Logic running check;
- project info read;
- transport state read;
- tracks/resource read;
- mixer visibility/provenance check;
- clear stop reasons.

Mutation: none.

### W2. MIDI Idea Sketch

Purpose: create or import a small MIDI idea with explicit track target and verification.

Expected contents:

- target project/state checks;
- track selection or creation gate;
- MIDI import or sequence path;
- post-write track/region evidence;
- failure mode for unverified selection.

Mutation: yes, guarded.

### W3. Arrangement Marker Plan

Purpose: create or verify arrangement markers/positions without stale parser assumptions.

Expected contents:

- marker resource read;
- position parser constraints;
- proposed marker list;
- mutation gates only where supported;
- post-write marker readback or honest unavailable result.

Mutation: optional, guarded.

### W4. Gain Staging And Mixer Prep

Purpose: safely prepare mix levels using verified mixer readback.

Expected contents:

- mixer provenance requirement;
- track strip mapping;
- no write if target verification fails;
- volume/pan write verification requirements;
- stop condition when AX/MCU readback is unavailable.

Mutation: yes, guarded.

### W5. Stock Plugin Chain Planning

Purpose: plan stock plugin chains using #14 catalog evidence.

Expected contents:

- #14 catalog dependency;
- no plugin claim without `verified` or explicitly labelled lower evidence;
- slot occupancy check;
- insert plan output;
- write phase separated from planning phase.

Mutation: planning only in first release. Insert execution requires #14 Phase 4 plus explicit confirmation.

### W6. Bounce Readiness Checklist

Purpose: prepare a project for export without claiming export automation unless supported.

Expected contents:

- project save state;
- transport position/cycle state;
- track mute/solo/arm checks;
- plugin/mixer evidence where available;
- external bounce/export steps marked manual unless implemented.

Mutation: none or explicitly gated.

## 7. Validation Rules

Workflow validation must fail when:

- a workflow references a non-existent MCP tool;
- a workflow references a non-existent MCP resource;
- a mutating step lacks confirmation metadata;
- a destructive step appears before required state checks;
- a workflow claims live verification without an evidence file;
- a workflow depends on #14 verified plugins but uses hard-coded plugin names;
- a workflow claims success without specifying response fields to inspect;
- a workflow omits failure modes for a mutation.

## 8. MCP Surface

Initial resource candidates:

- `logic://workflow-skills`
- `logic://workflow-skills/{id}`
- `logic://workflow-skills/search?query=...`
- `logic://workflow-skills/schema`

Responses must include:

- `schema_version`;
- `generated_at`;
- `workflow_count`;
- per-workflow `evidence_level`;
- validation status;
- exact tool/resource references;
- limitations.

## 9. Implementation Phases

### Phase 0: PRD Approval Gate

- Approve schema and initial workflow list.
- Decide final resource names.
- Decide whether workflows live as Swift resources, JSON fixtures, Markdown plus parser, or a hybrid.
- No code before this PRD is accepted.

### Phase 1: Schema And Linter

TDD first:

- schema validation;
- duplicate IDs;
- missing required fields;
- tool/resource reference validation;
- destructive-step gate validation;
- evidence-level validation.

### Phase 2: Deterministic Workflow Pack

Add the first workflows with validation fixtures.

Rules:

- no recipe count padding;
- no implementation shortcut through static unvalidated strings;
- no `production-ready` label until validation passes.

### Phase 3: MCP Read-Only Surfaces

Expose workflows through read-only resources.

No workflow resource may trigger a mutation. It only tells clients what to do and how to verify.

### Phase 4: Live Verification

Run targeted live workflows only where the current Logic session and safety gates allow it.

At least one mutating workflow must be live-verified before any mutating workflow is labelled production-ready.

### Phase 5: Client Documentation

Document how Claude Desktop, Cursor, and other MCP clients should consume the workflow pack.

Docs must show how to:

- inspect prerequisites;
- run state checks;
- ask for user confirmation;
- interpret stop conditions;
- verify results.

## 10. Acceptance Criteria

- [ ] PRD is approved before implementation.
- [ ] Ticket board exists and maps every workflow/schema rule to TDD work.
- [ ] Unit tests fail first for schema, linter, and destructive-step guardrails.
- [ ] Workflow references are validated against current tool/resource names.
- [ ] Every workflow lists prerequisites, state checks, allowed operations, failure modes, and verification output.
- [ ] Mutating workflows require explicit confirmation metadata.
- [ ] Workflow resources are read-only.
- [ ] At least one mutating workflow is live-verified before production-ready status.
- [ ] #14-dependent workflows consume #14 surfaces and do not hard-code plugin claims.
- [ ] Documentation includes examples and limitations.
- [ ] Verification evidence includes `swift test --no-parallel`, `swift build -c release`, schema/lint validation, and targeted live E2E where applicable.

## 11. Testing Strategy

### Deterministic Tests

- schema parser tests;
- fixture validation tests;
- missing field tests;
- tool/resource reference tests;
- destructive-step ordering tests;
- evidence-level tests.

### Integration Tests

- resource provider registration;
- workflow listing/detail/search;
- compatibility with existing MCP resource response patterns;
- no accidental mutation from workflow resource reads.

### Live Tests

Live tests must use scoped projects and record:

- Logic version;
- workflow ID and schema version;
- exact steps executed;
- before/after reads;
- mutation confirmation evidence;
- failure and stop conditions if encountered.

## 12. Safety

- Workflows guide clients; they do not override server safety.
- Every mutation remains subject to existing dispatcher, channel, and destructive policy checks.
- If a state check is uncertain, the workflow must stop or ask the client to request explicit user input outside the server.
- No workflow should imply that Logic project content was changed unless a readback proves it.

## 13. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Static recipe drift | Clients call stale tools | Linter validates current tool/resource names |
| Recipe overclaims autonomy | Unsafe user expectations | Evidence levels and explicit non-goals |
| Plugin workflows hallucinate catalog data | Wrong insert plans | Depend on #14 verified catalog only |
| Live verification mutates user work | Data loss | scoped project, explicit confirmation, before/after evidence |
| Too many workflows dilute quality | Shallow pack | small initial pack with deep validation |

## 14. Open Questions

- Should workflow fixtures be Swift-native data, JSON files, Markdown front matter, or generated from docs?
- Should experimental workflows be exposed by default or hidden behind a query flag?
- Should workflow IDs follow `logic.workflow.<domain>.<name>`?
- Which single mutating workflow is safest for first live verification?
- Should #15 wait for #14 Phase 3 before shipping stock-plugin-chain planning?

## 15. Definition Of Done

Issue #15 is done only when:

- implementation maps directly to this PRD and ticket board;
- workflow schema and linter exist;
- read-only workflow resources exist;
- at least the first pack is validated;
- mutating recipes have evidence gates;
- targeted live evidence exists for any production-ready mutation workflow;
- GitHub issue evidence is current and does not cite superseded commit `8ea264c`;
- no workflow overstates Logic Pro MCP's verified capabilities.
