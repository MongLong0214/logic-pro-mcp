# PRD: Verified Stock Plugin Intelligence (Issue #14)

**Status**: Draft v0.1 restart
**Date**: 2026-06-09
**Owner**: Isaac / Logic Pro MCP
**Implementation status**: Not started
**Related issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/14

> Restart note: previous implementation commit `8ea264c` is invalidated. It combined #14 and #15 in one shallow implementation and must not be used as implementation evidence. This PRD starts from `main` commit `c626fca` and defines the acceptance contract before any new code.

## 1. Problem

Logic Pro MCP can already expose some mixer state and can perform guarded stock plugin insertion in narrow verified paths, but MCP clients still do not have a truthful intelligence layer for Logic's built-in plugins.

Today a client must guess:

- the exact stock plugin identity and menu path;
- whether a plugin exists on the local Logic install;
- whether a plugin name was actually observed or merely assumed;
- which slots are occupied;
- which parameters are known, controllable, or readback-capable;
- whether a suggested plugin chain is safe to apply.

That turns an AI client's "plugin recommendation" into prompt-memory and guesswork. The product needs a verified, provenance-backed plugin intelligence surface that is strict about what it knows and explicit about what it does not know.

## 2. Goals

- Define a stable stock plugin intelligence schema before implementation.
- Build a catalog/census path that records source, timestamp, Logic version, locale, and verification method for every entry.
- Expose read-only MCP discovery surfaces for search and detail retrieval.
- Distinguish verified, observed, inferred, unavailable, and readback-mismatch states at the wire level.
- Keep all write-side behavior behind existing fail-closed gates.
- Enable future plugin insertion and parameter work without requiring clients to hallucinate plugin names or paths.

## 3. Non-Goals

- No third-party Audio Unit catalog in this PRD.
- No universal parameter automation claim.
- No silent plugin insertion.
- No automatic chain application without explicit user target, slot, and confirmation gates.
- No "verified" label for static hand-written entries.
- No release claim until deterministic tests and targeted live Logic evidence exist.

## 4. Users And Use Cases

### U1. AI client plugin discovery

An MCP client asks for safe stock plugin options for a task, such as gain staging, EQ cleanup, dynamics, metering, MIDI effects, or instruments.

The client receives plugin candidates with provenance, category, confidence, supported surfaces, and limitations.

### U2. Safe insertion planner

An MCP client wants to propose a stock plugin insertion plan before making any mutation.

The client can read slot state, allowed plugin identities, slot compatibility, and required confirmation level before calling any write tool.

### U3. Parameter-aware future control

An MCP client wants to know whether a stock plugin parameter is currently known by schema, live-observed by AX, write-only through Scripter, or not supported.

The client receives explicit capability states instead of inventing parameter contracts.

## 5. Product Contract

### 5.1 Truth Labels

Every plugin entry and parameter entry must carry one of these states:

| State | Meaning | Required evidence |
|-------|---------|-------------------|
| `verified` | Confirmed on the current machine through live Logic or local installation census and validated against schema | source, observed_at, Logic version, method |
| `observed` | Seen in a live AX/menu/resource scan, but not fully validated for all fields | source, observed_at, method |
| `manifested` | Found in local application/plugin metadata without live Logic readback | source path or manifest reference |
| `inferred` | Derived from known Logic behavior, not verified on this machine | inference reason, no verified claim |
| `unavailable` | Expected plugin was not found on the current system | checked_at, method |
| `readback_mismatch` | Requested/expected plugin or parameter did not match live readback | expected, observed, method |

### 5.2 Required Entry Fields

Each stock plugin catalog entry must include:

- `id`: stable internal identifier, e.g. `logic.stock.effect.gain`;
- `display_name`: user-facing Logic name;
- `type`: `effect`, `instrument`, `midi_effect`, `utility`, or `metering`;
- `category`: Logic browser/category group;
- `availability_state`: one of the truth labels above;
- `provenance`: source, method, observed timestamp, Logic version, locale, machine-safe source path where applicable;
- `insert_paths`: safe insert path hints with truth labels per path;
- `slot_support`: audio, instrument, MIDI FX, aux, stereo/mono constraints where known;
- `parameters`: optional parameter metadata, each with its own truth label;
- `safe_write_capabilities`: `none`, `insert_only`, `parameter_write_unverified`, `parameter_write_readback`, or future values;
- `limitations`: explicit string list for client-visible uncertainty.

### 5.3 Parameter Metadata Minimum

Parameter metadata is allowed only when each field is separately labelled:

- `id`;
- `display_name`;
- `unit`;
- `value_range`;
- `default_value`;
- `write_method`;
- `readback_method`;
- `availability_state`;
- `provenance`.

No parameter may be marked `verified` unless the exact parameter identity and readback path are verified.

## 6. MCP Surface

Initial surfaces are read-only resources or tools. Final naming can change during design review, but the wire contract must preserve the fields above.

### 6.1 Resource Candidates

- `logic://stock-plugins`
- `logic://stock-plugins/{id}`
- `logic://stock-plugins/search?query=...`
- `logic://stock-plugins/census`
- `logic://stock-plugins/capabilities`

### 6.2 Response Requirements

Responses must:

- be machine-parseable JSON;
- include `schema_version`;
- include `generated_at`;
- include `logic_version` when available;
- include `catalog_source`;
- include per-entry truth labels;
- never coerce missing evidence into `verified`;
- return empty lists with diagnostic metadata instead of fake entries.

## 7. Implementation Phases

### Phase 0: PRD Approval Gate

- Review this PRD against issue #14.
- Decide final resource/tool names.
- Decide whether #14 remains read-only until #15 consumes it.
- No code before this PRD is accepted.

### Phase 1: Schema And Validation Tests

TDD first. Tests must fail before implementation for:

- required fields;
- duplicate IDs;
- invalid truth label transitions;
- missing provenance on `verified`;
- parameters marked verified without readback evidence;
- backwards-compatible JSON decoding.

### Phase 2: Census Sources

Implement at least two source lanes where feasible:

- local install/metadata census;
- live Logic/AX/menu observation.

The catalog must be able to say "not verified yet" instead of filling gaps.

### Phase 3: Read-Only MCP Surfaces

Expose the catalog through read-only MCP surfaces. No mutation behavior belongs in this phase.

### Phase 4: Integration With Existing Insert Gates

Only after read-only surfaces are validated:

- connect catalog identity to the existing guarded stock plugin insert path;
- reject non-catalog or non-verified plugin IDs by default;
- keep destructive policy and confirmation requirements intact.

### Phase 5: Live Verification

Targeted live Logic verification must cover:

- catalog census on the current Logic version;
- at least one verified safe stock plugin identity;
- at least one unavailable or inferred entry path;
- a guarded insert/readback path only if Phase 4 is in scope.

## 8. Acceptance Criteria

- [ ] PRD is approved before implementation.
- [ ] Ticket board exists and maps every requirement to TDD work.
- [ ] Unit tests fail first for schema, provenance, duplicate IDs, truth labels, and parameter evidence.
- [ ] No entry can be marked `verified` without source, method, timestamp, and Logic version when available.
- [ ] Read-only MCP discovery surfaces expose truth labels and limitations.
- [ ] Existing mixer and plugin safety gates remain fail-closed.
- [ ] The implementation does not change write-side behavior unless a later ticket explicitly covers it.
- [ ] Targeted live Logic verification records at least one verified stock plugin path.
- [ ] Documentation explains what clients may trust and what they must not hallucinate.
- [ ] Verification evidence includes `swift test --no-parallel`, `swift build -c release`, `python3 -m py_compile Scripts/live-e2e-test.py`, and targeted live evidence where applicable.

## 9. Testing Strategy

### Deterministic Tests

- schema validation;
- fixture decoding;
- duplicate and alias handling;
- provenance rules;
- truth label transitions;
- MCP resource response shape;
- backwards compatibility for existing resources.

### Integration Tests

- resource provider registration;
- search/detail query behavior;
- no mutation path from discovery calls;
- catalog identity validation for future insert integration.

### Live Tests

Live tests must be explicit and scoped:

- Logic version captured;
- locale captured;
- AX permission state captured;
- project/session state captured;
- before/after plugin slot readback captured for any mutation path.

## 10. Safety And Security

- All discovery calls are read-only.
- Any future insert path remains Level 2 destructive policy with explicit confirmation.
- No third-party plugin filesystem scan beyond this PRD's scope.
- No private project content should be serialized into catalog evidence.
- Live test evidence should record plugin identities and slot states, not user musical content.

## 11. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Logic locale changes plugin display names | Wrong identity mapping | Stable IDs plus provenance and locale field |
| AX menu structure differs by Logic version | False availability | Versioned census and `observed` vs `verified` labels |
| Static catalog drifts | Hallucinated trust | Reject `verified` without live/local source |
| Parameter names are not readable | False parameter support | Mark parameter support unavailable until readback exists |
| Discovery surface becomes a write shortcut | Safety regression | Read-only Phase 3, explicit Phase 4 gate |

## 12. Open Questions

- Should the first shipped catalog include only plugins verified on the current machine, or also `inferred` stock Logic entries?
- What is the canonical stable ID format for AU/component-backed Logic plugins?
- Should plugin insertion accept display names, stable IDs only, or both with strict disambiguation?
- Should parameter metadata be deferred entirely until a separate #16-style parameter PRD?

## 13. Definition Of Done

Issue #14 is done only when:

- implementation maps directly to this PRD and ticket board;
- deterministic tests pass;
- build passes;
- docs are updated;
- targeted live evidence exists;
- GitHub issue evidence is current and does not cite superseded commit `8ea264c`;
- no #15 workflow recipe depends on unverified plugin catalog claims.
