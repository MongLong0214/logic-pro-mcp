# Architecture Decision Records

## Most Important Conclusion

Phase 0 freezes governance and the current baseline before any ADR runtime implementation begins.
The core execution order is ADR-002 → ADR-003 → ADR-004 → ADR-001.
ADR-005 is cross-cutting and applies throughout the entire sequence.
Every ADR starts in `Proposed` status and advances only with its own implementation and qualification evidence.

## Category A — Core execution path

| ADR | Name | Category | Status | GitHub issue |
| --- | --- | --- | --- | --- |
| ADR-002 | Session-scoped Stable Target Reference | A | `Proposed` | [#285](https://github.com/MongLong0214/logic-pro-mcp/issues/285) |
| ADR-003 | Public Operation Contract Registry | A | `Proposed` | [#286](https://github.com/MongLong0214/logic-pro-mcp/issues/286) |
| ADR-005 | Operation Trace and Support Bundle | A | `Proposed` | [#288](https://github.com/MongLong0214/logic-pro-mcp/issues/288) |
| ADR-004 | Verified Mutation Saga | A | `Proposed` | [#287](https://github.com/MongLong0214/logic-pro-mcp/issues/287) |
| ADR-001 | Same-Release Live Qualification Gate | A | `Proposed` | [#284](https://github.com/MongLong0214/logic-pro-mcp/issues/284) |

## Category B — Shared infrastructure

| ADR | Name | Category | Status | GitHub issue |
| --- | --- | --- | --- | --- |
| ADR-006 | Versioned Cache | B | `Proposed` | [#289](https://github.com/MongLong0214/logic-pro-mcp/issues/289) |
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
