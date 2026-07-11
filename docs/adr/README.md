# Architecture Decision Records

## Most Important Conclusion

Phase 0 freezes governance and the current baseline before any ADR runtime implementation begins.
The core execution order is ADR-002 → ADR-003 → ADR-004 → ADR-001.
ADR-005 is cross-cutting and applies throughout the entire sequence.
Every ADR starts in `Proposed` status and advances only with its own implementation and qualification evidence.

The three kernel ADRs — ADR-002, ADR-003, ADR-005 — are now `In Implementation`: each has flag-gated (default-off) pilots merged to `main` with deterministic tests and live evidence (see the [Implementation status](#implementation-status) section). They add zero runtime behavior with their flags off. ADR-006 has also entered `In Implementation` with a first, types-only increment (the runtime cache rewiring is deferred pending a live soak — see its status entry). ADR-001, ADR-004, ADR-007 and all Category C/D ADRs remain `Proposed` — they depend on the kernel being not just merged but live-qualified, which is ongoing.

## Category A — Core execution path

| ADR | Name | Category | Status | GitHub issue |
| --- | --- | --- | --- | --- |
| ADR-002 | Session-scoped Stable Target Reference | A | `In Implementation` | [#285](https://github.com/MongLong0214/logic-pro-mcp/issues/285) |
| ADR-003 | Public Operation Contract Registry | A | `In Implementation` | [#286](https://github.com/MongLong0214/logic-pro-mcp/issues/286) |
| ADR-005 | Operation Trace and Support Bundle | A | `In Implementation` | [#288](https://github.com/MongLong0214/logic-pro-mcp/issues/288) |
| ADR-004 | Verified Mutation Saga | A | `Proposed` | [#287](https://github.com/MongLong0214/logic-pro-mcp/issues/287) |
| ADR-001 | Same-Release Live Qualification Gate | A | `Proposed` | [#284](https://github.com/MongLong0214/logic-pro-mcp/issues/284) |

## Category B — Shared infrastructure

| ADR | Name | Category | Status | GitHub issue |
| --- | --- | --- | --- | --- |
| ADR-006 | Versioned Cache | B | `In Implementation` | [#289](https://github.com/MongLong0214/logic-pro-mcp/issues/289) |
| ADR-007 | AX Selector Atlas | B | `Proposed` | [#290](https://github.com/MongLong0214/logic-pro-mcp/issues/290) |

## Category C — Expansion foundations

| ADR | Name | Category | Status | GitHub issue |
| --- | --- | --- | --- | --- |
| ADR-008 | Verified Mixer Routing Graph | C | `Proposed` | [#291](https://github.com/MongLong0214/logic-pro-mcp/issues/291) |
| ADR-009 | Verified Plugin Apply-back Expansion | C | `Proposed` | [#292](https://github.com/MongLong0214/logic-pro-mcp/issues/292) |
| ADR-010 | MIDI Note-level Independent Readback Research | C | `Proposed` | [#293](https://github.com/MongLong0214/logic-pro-mcp/issues/293) |

## Category D — Capability ADRs

| ADR | Name | Category | Status | GitHub issue |
| --- | --- | --- | --- | --- |
| ADR-011 | Full Verified Compressor Control | D | `Proposed` | [#299](https://github.com/MongLong0214/logic-pro-mcp/issues/299) |
| ADR-012 | Spectral Analysis and EQ Recommendation | D | `Proposed` | [#300](https://github.com/MongLong0214/logic-pro-mcp/issues/300) |
| ADR-013 | Verified Channel EQ Band Control | D | `Proposed` | [#301](https://github.com/MongLong0214/logic-pro-mcp/issues/301) |
| ADR-014 | Independent MIDI Event Readback | D | `Proposed` | [#302](https://github.com/MongLong0214/logic-pro-mcp/issues/302) |
| ADR-015 | Piano Roll Data-level Transform | D | `Proposed` | [#303](https://github.com/MongLong0214/logic-pro-mcp/issues/303) |
| ADR-016 | Smart Tempo and Tempo-map Control | D | `Proposed` | [#304](https://github.com/MongLong0214/logic-pro-mcp/issues/304) |
| ADR-017 | Flex Pitch Inspection and Verified Editing | D | `Proposed` | [#305](https://github.com/MongLong0214/logic-pro-mcp/issues/305) |
| ADR-018 | Verified Third-party Host-Parameter Control | D | `Proposed` | [#306](https://github.com/MongLong0214/logic-pro-mcp/issues/306) |

## Implementation status

Kernel pilots merged to `main`, all behind default-off feature flags (zero runtime behavior change when off):

### ADR-003 — Public Operation Contract Registry (`In Implementation`)
- **100% public-operation registry coverage: all 10 tools** — `logic_transport` (13 cmds), `logic_mixer` (5), `logic_navigate` (8), `logic_audio` (1), `logic_system` (4), `logic_plugins` (3), `logic_edit` (14), `logic_project` (16), `logic_midi` (16), `logic_tracks` (19).
- Typed `OperationSpec` per command (mutability, confirmation, target, verification, retry, deadline, availability, capability). Dual-source: the registry is derived alongside the legacy manual maps, gated by `FeatureFlags.adr003OperationRegistry`.
- Drift-detection tests pin each tool's registry-derived mutating set / deadlines to `LogicProServer.mutatingCommandsByTool`, plus a global 10/10-tool coverage gate. Confirmation policy is pinned to `DestructivePolicy.level(for:)`.
- Registry review caught real contract-vs-reality drift (e.g. `logic_navigate.delete_marker`/`toggle_view` had no readback path; several commands are honestly `.requiresKeyBinding`/`.bestEffort`/`.unsupported`).
- Merged: #316, #319, #321, #324, #325, #326, #327, #328.

### ADR-002 — Session-scoped Stable Target Reference (`In Implementation`)
- `TargetRegistry` actor (server session + project epoch + topology generation + live fingerprint), opaque `track_ref` on the tracks resource, `tracks.rename` piloted end-to-end behind `FeatureFlags.adr002TargetRef`.
- Live negative-qualification against real Logic Pro: valid ref → State A verified; stale-after-topology-bump / bogus / target_ref-index mismatch → State C `stale_target_reference` with zero writes (neighbor track provably untouched).
- Merged: #318.

### ADR-005 — Operation Trace and Support Bundle (`In Implementation`)
- `OperationTraceStore` actor (bounded ring buffer, privacy allowlist), trace-ID + event-phase model with explicit `write_boundary.crossed` instrumentation, piloted on the verified `logic_transport`, `logic_mixer`, and `logic_tracks` (rename / mute / solo / arm) write paths behind `FeatureFlags.adr005OperationTrace`. `logic_system` trace query commands added.
- Merged: #317, #320, #330.

### ADR-006 — Versioned Cache (`In Implementation`)
- First increment: pure snapshot value types only — `VersionedSnapshot<Value>` (project epoch, section revision, observed-at, source, completeness, fingerprint), `StateSource` / `Completeness` / `CacheSectionID` enums, and pure `etag` / `cacheAgeMillis(now:)` derivations, behind `FeatureFlags.adr006VersionedCache` (default off).
- Deliberately scoped out (deferred): the `RefreshCoordinator` (single-flight refresh + backpressure), the actual resource-envelope wiring (`project_epoch` / `section_revision` / `etag` / `cache_age_ms` on reads), and any `StateCache` rewiring. Those require the 30-minute memory-soak and large-project benchmarks from #289's acceptance criteria, which need live qualification and are not claimed here.
- Deterministic tests only (no runtime path touched): field preservation, etag stability, `cacheAgeMillis` monotonicity + clock-skew guard, `Codable` round-trips, section completeness, flag-default-off.

### Release qualification
- Strict live E2E suite (`LOGIC_PRO_MCP_STRICT_LIVE=1`, real Logic Pro, fresh-session bootstrap) is green on `main`.
- One live-discovered defect (English-UI track delete, #322) was fixed (#323) and live-re-verified.
