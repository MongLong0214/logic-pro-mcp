# PRD: Verified Stock Plugin Intelligence (Issue #14)

**Status**: Approved for implementation
**Date**: 2026-06-09
**Owner**: Logic Pro MCP
**Related issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/14
**Supersedes**: invalidated combined implementation `8ea264c`

## 1. Problem

MCP clients need a trustworthy way to discover Logic Pro stock plugins without prompt-memory guesses. Today they cannot reliably know which stock plugin IDs exist, which names are observed versus inferred, which insert paths are safe hints, or which parameters are actually controllable/readback-capable.

The server must expose a provenance-backed, read-only stock plugin intelligence layer before any broader plugin insertion or parameter automation claims.

## 2. Goals

- Provide a stable stock plugin catalog schema with explicit truth labels.
- Enforce provenance rules so `verified` is never returned without evidence.
- Expose read-only MCP resources for catalog list, detail, search, census, and capabilities.
- Preserve existing mixer/plugin write safety gates.
- Document client trust boundaries and limitations.

## 3. Non-Goals

- No third-party Audio Unit discovery.
- No silent plugin insertion or write-side broadening.
- No universal parameter automation claim.
- No verified parameter metadata unless exact readback evidence exists.
- No release claim based on superseded commit `8ea264c`.

## 4. Truth Model

Truth labels are part of the public wire contract:

- `verified`: confirmed by current-machine evidence with source, method, timestamp, and Logic version when available.
- `observed`: seen in live/local observation but not fully validated.
- `manifested`: present in local metadata without live readback.
- `inferred`: known/static Logic behavior, not verified on this machine.
- `unavailable`: expected plugin checked and absent.
- `readback_mismatch`: expected and observed values differ.

## 5. Schema

Every catalog response includes:

- `schema_version`
- `generated_at`
- `logic_version`
- `locale`
- `catalog_source`
- `validation`
- `entries`

Every plugin entry includes:

- `id`
- `display_name`
- `type`
- `category`
- `availability_state`
- `provenance`
- `insert_paths`
- `slot_support`
- `known_presets`
- `parameters`
- `safe_write_capabilities`
- `limitations`

Every parameter entry includes its own truth label and provenance. A parameter cannot be `verified` unless both write and readback method evidence are present. Presets are represented by `known_presets` and must remain empty unless preset names are backed by provenance.

## 6. MCP Resources

Read-only resources:

- `logic://stock-plugins`
- `logic://stock-plugins/{id}`
- `logic://stock-plugins/search?query=<text>`
- `logic://stock-plugins/census`
- `logic://stock-plugins/capabilities`

No resource in this PRD may mutate Logic state.

## 7. Implementation Tickets

Canonical ticket board: `docs/tickets/issue14-verified-stock-plugin-intelligence/STATUS.md`

- `I14-T1`: schema models and truth-label validator.
- `I14-T2`: deterministic catalog seed with current-machine census overlay.
- `I14-T3`: read-only MCP resource handlers and resource registration.
- `I14-T4`: integration tests for list/detail/search/census/capabilities.
- `I14-T5`: docs and verification evidence.

## 8. Acceptance Criteria

- PRD and ticket board exist before implementation.
- Unit tests cover required fields, duplicate IDs, provenance, truth labels, and parameter evidence.
- No `verified` plugin or parameter can be emitted without required provenance.
- Discovery responses distinguish `verified`, `observed`, `manifested`, `inferred`, `unavailable`, and `readback_mismatch`.
- Existing mixer/plugin safety gates remain fail-closed.
- Read-only MCP resources expose list, detail, search, census, and capabilities.
- Docs/API and troubleshooting docs describe examples and limitations.
- Verification includes `swift test --no-parallel`, `swift build -c release`, `python3 -m py_compile Scripts/live-e2e-test.py`, and targeted live evidence when a live Logic session is available.

## 9. Test Plan

- Schema validator tests for duplicates, required provenance, and invalid parameter verification.
- Catalog tests for stable IDs, search, detail lookup, and unavailable entries.
- Resource tests for registered URIs/templates and read-only response shape.
- E2E tests through server resource reads.
- Live smoke test records Logic version, locale, catalog states, and at least one observed/verified stock plugin identity when possible.

## 10. ADR

**Decision**: ship #14 as read-only catalog intelligence with strict truth labels and a local-census overlay.
**Drivers**: prevent hallucinated plugin claims, preserve safety gates, provide useful client discovery now.
**Alternatives considered**: hard-coded static list only, live AX-only scanner, write-enabled insert planner.
**Why chosen**: static-only cannot claim verification; live-only is brittle and unavailable in CI; write-enabled scope belongs behind a later explicit gate.
**Consequences**: first release is conservative and may label many entries `inferred` or `unavailable`; clients get honest metadata instead of false confidence.
