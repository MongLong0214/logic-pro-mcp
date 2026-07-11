# Architecture Decision Records

## Most Important Conclusion

Phase 0 freezes governance and the current baseline before any ADR runtime implementation begins.
The core execution order is ADR-002 → ADR-003 → ADR-004 → ADR-001.
ADR-005 is cross-cutting and applies throughout the entire sequence.
Every ADR starts in `Proposed` status and advances only with its own implementation and qualification evidence.

The three kernel ADRs — ADR-002, ADR-003, ADR-005 — are now `In Implementation`: each has flag-gated (default-off) pilots merged to `main` with deterministic tests and live evidence (see the [Implementation status](#implementation-status) section). They add zero runtime behavior with their flags off. ADR-006 has also entered `In Implementation` with a first, types-only increment (the runtime cache rewiring is deferred pending a live soak — see its status entry). ADR-004 has entered `In Implementation` with a pure in-memory saga engine (reversible-ops-only; live execution and MCP surface deferred — see its status entry). ADR-001 has entered `In Implementation` with a qualification-gate harness skeleton (attestation types + a pure promotion-gate evaluator; the live qualification matrix and release-gate CI enforcement are deferred — see its status entry). This completes the guide's core assurance chain (ADR-002 → 003 → 004 → 001) in flag-gated / harness form. ADR-007 and all Category C/D ADRs remain `Proposed` — they depend on the kernel being not just merged but live-qualified, which is ongoing.

## Category A — Core execution path

| ADR | Name | Category | Status | GitHub issue |
| --- | --- | --- | --- | --- |
| ADR-002 | Session-scoped Stable Target Reference | A | `In Implementation` | [#285](https://github.com/MongLong0214/logic-pro-mcp/issues/285) |
| ADR-003 | Public Operation Contract Registry | A | `In Implementation` | [#286](https://github.com/MongLong0214/logic-pro-mcp/issues/286) |
| ADR-005 | Operation Trace and Support Bundle | A | `In Implementation` | [#288](https://github.com/MongLong0214/logic-pro-mcp/issues/288) |
| ADR-004 | Verified Mutation Saga | A | `In Implementation` | [#287](https://github.com/MongLong0214/logic-pro-mcp/issues/287) |
| ADR-001 | Same-Release Live Qualification Gate | A | `In Implementation` | [#284](https://github.com/MongLong0214/logic-pro-mcp/issues/284) |

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

### ADR-004 — Verified Mutation Saga (`In Implementation`)
- MVP saga engine only: a pure in-memory `actor MutationSaga` (12-state machine, full-plan preflight, compensation journal) behind `FeatureFlags.adr004MutationSaga` (default off). Step execution is injected via a `SagaStepExecutor` protocol — tests drive it with a synthetic mock; no live Logic and no dispatcher/MCP wiring.
- **Full-plan preflight gate**: every step's target is resolved against the `TargetRegistry` (ADR-002) and validated against the operation registry (ADR-003); if any step has a stale/mismatched target, an unregistered/non-reversible operation, or an invalid inverse, **no step executes** (the executor is never called — asserted by `runCount == 0`).
- **Reversible-ops allowlist, exactly six**: `track.rename`, `mixer.set_volume`, `mixer.set_pan`, `tracks.set_mute`, `tracks.set_solo`, `tracks.set_record_arm`. Each inverse restores the captured before-state.
- **No blind inverse**: on an unverified (State B) or ambiguous write, the engine does a fresh readback and branches — applied → compensate, not-applied → no-op, unknown → `rollbackUncertain`. `fullyCompensated` is reported only after compensation readback confirms restoration; partial outcomes never surface as top-level success (`complete: false`).
- 7 deterministic tests (synthetic executor): preflight-rejects-before-run, happy-path journal evidence, reverse-order compensation, no-blind-inverse reconciliation, compensation-failure honesty, idempotency + flag-default-off, exact state-machine/allowlist.
- Deferred (honest scope): live execution against real dispatchers, the public MCP surface, and non-reversible / multi-target operations. Those need real write-path wiring plus live qualification and are not claimed here.

### ADR-001 — Same-Release Live Qualification Gate (`In Implementation`)
- Harness skeleton + pure gate logic only. `ReleaseQualificationAttestation` / `QualificationCase` / `QualificationWaiver` value types (matching #284's schema, snake_case JSON keys), the qualification matrix axes (`LogicVariant` / `QualificationLocale` / `SetupProfile` / `CacheState` / `ProjectFixture`), and the exact 4 required combinations (desktop|creator × en-US|ko-KR, core/cold).
- **Pure `PromotionGate` evaluator** (no I/O, no clock): rejects promotion on any of the six distinct reasons — required case failed, required combination not qualified, missing artifact, binary SHA-256 mismatch, expired waiver, release-version mismatch. A required combination qualifies **only** when a matching case is `passed` **and** `verified` **and** carries evidence — a `waived` / unverified / evidence-less case never satisfies a required combination (`skip is not pass`). Waiver expiry is a pure SemVer comparison; malformed SHA / version inputs fail closed.
- `Scripts/live-qualification-runner.py` is a **non-live skeleton** — it emits the attestation shape with `not_qualified` placeholders and a `TODO(#284)` marking where the real matrix run plugs in. It performs no Logic / MCP calls.
- 19 deterministic tests over the gate (all six rejection reasons, the three `skip-is-not-pass` variants, fail-closed-on-malformed, duplicate-case detection, `Codable` date round-trip, exact required-combination keys).
- Deferred (honest scope): the actual same-artifact live qualification matrix run on real Logic Pro, and wiring the gate into the release pipeline as an enforced CI check. Those need a human-attended real-Logic environment across the full variant/locale/profile matrix and are not claimed here; no CI workflow or release script is modified by this increment.

### Release qualification
- Strict live E2E suite (`LOGIC_PRO_MCP_STRICT_LIVE=1`, real Logic Pro, fresh-session bootstrap) is green on `main`.
- One live-discovered defect (English-UI track delete, #322) was fixed (#323) and live-re-verified.
