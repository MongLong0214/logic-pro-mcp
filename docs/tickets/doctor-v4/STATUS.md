# Pipeline Status: Doctor v4 — Intent-Aware, Source-Aware Readiness Platform

**PRD**: `docs/prd/PRD-doctor-v4.md`
**Status**: v4 readiness spine implemented; extended hardening tickets remain pending
**Base**: Doctor v3 Done/PASS (`docs/tickets/doctor-v3/STATUS.md`)
**Execution rule**: sequential landing. No ticket may weaken v3 honesty or remove v3 checks.

## Tickets

| Ticket | Title | Status | Depends On |
|--------|-------|--------|------------|
| T1 | Safety/remediation quick fix | Todo | none |
| T2 | `skip_reason` additive field | Implemented | T1 |
| T3 | Relative registration resolver | Todo | T2 |
| T4 | Profile-aware manual channel checks | Implemented (scope model) | T2 |
| T5 | Manual validation decision store | Todo | T4 |
| T6 | Client profile / generic MCP client | Implemented (profile scoping) | T3 |
| T7 | Capability readiness JSON | Implemented | T2, T4, T6 |
| T8 | Typed check registry | Todo | T2 |
| T9 | Evidence builder/privacy hardening | Todo | T8 |
| T10 | Static version marker / SemanticVersion | Todo | T3, T8 |

## Dependency Graph

```text
T1 -> T2 -> T3 -> T6 ┐
          └-> T4 -> T5 ├-> T7
          └-> T8 -> T9 ┘
                 └-> T10
```

## Board-Wide Binding Gates (apply to EVERY ticket — CTO v0.2)

1. **TDD**: red tests written and FAIL-verified before implementation; no dead-`#expect` forms (`optBool == true`, `?? false`, `== .some(true)` — repo footgun #92).
2. **Cumulative review**: on each ticket's completion, review T(n-1)+T(n) diff together + run the full `swift test --no-parallel` suite; every 5 tickets, full cumulative review T1..T(n).
3. **Live/evidence gate**: any ticket touching a real system surface (T1 remediation output, T3 resolver, T5 store CLI, T6 detection, T7 capabilities, T10 marker) ends with a local `doctor --json` (and profile variants where relevant) evidence capture attached to the PR.
4. **Manual QA gate**: per-ticket QA section is mandatory before Done.
5. **Honesty invariants**: no ticket may weaken v3 honesty (false-green 0 per profile scope, §5.1.1 PRD), remove v3 checks, execute arbitrary binaries (C4), or bypass the evidence builder once T9 lands.
6. **Sequential landing** (shared check metadata/test literals — parallel landing conflicts guaranteed).

## Per-Ticket Risk Register (CTO v0.2)

- T1: renderer/docs coupling — snapshot tests must change together (risk: docs drift).
- T2: aggregate semantics touched — regression risk on shipped optional-skip rule (`SetupDoctor+Rendering.swift:137`); FrozenV3 decode pins the wire.
- T3: supersedes shipped relative-command policy — must keep the resolution-basis honesty caveat (PRD §5.10) or it reintroduces a cross-context false-green.
- T4/T6: profile/client scoping — the §5.1.1 calculus is the contract; any deviation is a false-green vector. CI-honesty test per profile required.
- T5: store migration — legacy approvals must survive (data-loss risk); corrupt-store warning must not brick doctor.
- T7: capability table is DATA (PRD §5.3) — hard-coding it in logic makes T8 a rewrite; mixer_mcu capped at `unknown_live_verify_required` (hint-grade honesty).
- T8: registry must reproduce the exact shipped check order (order regression breaks the exact-id contract test).
- T9: central builder touches every check — highest regression surface; land late, full-suite + privacy scan.
- T10: marker effective only post-release (PRD §5.11); keep strings fallback or older-binary detection silently dies.

## Final Gate

- `swift test --no-parallel`
- `swift build -c release`
- `LogicProMCP doctor --json` for core/full/client profiles
- privacy scan of doctor JSON
- renderer snapshot for default/verbose/quiet
- docs anchor coverage
- FrozenV1/V2/V3 decode green (wire superset chain)
