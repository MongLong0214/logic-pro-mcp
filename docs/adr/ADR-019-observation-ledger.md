# ADR-019 — Observation Ledger: every claim names the record that produced it

**Status:** Proposed
**Related:** #768 (empty variants), #778 (Japanese coverage), #767 (the instrument that started the observation records), `docs/observations/SCHEMA.md`, `docs/locale/ui-labels.json`
**Date:** 2026-09-05

## Context

The observation system exists so that when Logic moves, "what do we now not know?" has a mechanical
answer. Measured on 2026-09-05 against `main`, it answers that question well for records and badly
for everything standing on them:

```
observation records          24     schema-clean, host drift 0, roadmap-bound
label-set variants          257     of which 2 carry a reading; 255 are strings someone typed
label sets with []            18     one shape for three facts: measured-absent, identifier-addressed, never looked
label sets without Japanese  113     no ja-JP measurement has ever been run
records' host.locale         24× ko-KR   locale is recorded and is not an axis of anything
```

These are four symptoms of one missing primitive. **A claim can exist without the record that
produced it.** `measured` in `ui-labels.json` is an optional annex; the ratchet on it only stops the
count from falling, so 2 is a stable equilibrium. An empty `variants` list is silent about why. A
record's `locale` is stored and never queried. So the system can prove a record is well-formed and
cannot prove a variant is real — and the variants are what the product matches against at runtime.

The unit of trust has to move from "the record is well-formed" to "the string the product will
match was read, here, on this host, and this is where".

## Decision

### D1 — A variant is a claim, and a claim names its record

`ui-labels.json` moves to `schema: 2`. Every variant carries a `provenance` block:

```jsonc
"입력 슬롯": {
  "record":     "2026-09-04-mixer-slot-readback-was-a-one-language-match",   // MUST exist
  "locale":     "ko-KR",          // MUST equal that record's host.locale
  "date":       "2026-09-04",     // a real date
  "host":       "Logic Pro 12.3 (6674) on macOS 26.3 (25D125)",
  "observed":   "입력 슬롯. 채널 스트립 입력 소스를 선택합니다. …",  // MUST contain the variant
  "on_element": "AXButton, AXDescription \"입력 1\""
}
```

Two of those are new and load-bearing: `record` must resolve to a file in `docs/observations/`,
and its `host.locale` must match. That turns provenance from three strings anyone can type into a
pointer into the ledger, auditable by the same guard that audits the ledger.

A **new** variant without provenance is refused. Existing undocumented variants are a burn-down:
listed by name, counted, and the count may only fall.

### D2 — Empty `variants` is not a state. `coverage` is.

Each label set declares, per supported locale, one of four values:

| value | meaning | is it a gap? |
|---|---|---|
| `present` | measured; the variant is in the list with provenance | no |
| `absent` | measured; this locale has no distinct form (the canonical is what Logic shows, or the element is unlabelled) | no |
| `identifier` | not matched by label at all — addressed by a locale-free `AXIdentifier`, named | no |
| `unmeasured` | nobody has looked | **yes** |

Supported locales are `en-US`, `ko-KR`, `ja-JP` — the three Logic ships that this repository has
either measured or been asked about. `unmeasured` is the only gap, it is counted per locale, and each
count may only fall. **#778 is, by construction, the `ja-JP: unmeasured` count.** #768 is the
eighteen sets whose empty list this replaces with a declared reason.

`coverage` lives in the JSON, not in Swift. Swift stays the compiled source of the *strings*; the
JSON carries what is known *about* them. `Scripts/locale_labels.py --write` preserves `coverage` and
`provenance` across regeneration exactly as it preserves `measured` today.

### D3 — Locale becomes an axis of the ledger

`host.locale` stays a field and stops being inert. `observations-status.py --coverage` reports, per
surface, which locales have a record. D1's cross-check (variant locale ⇔ record locale) is what makes
the JSON auditable against the ledger rather than beside it.

### D4 — A census tool and a campaign, so the gaps can actually be closed

`Scripts/observations/locale-census.swift` walks a named surface and emits every
`{role, attribute, string, path}` it can read. `Scripts/observations/locale-campaign.sh <locale>`:

1. saves the open project, sets `defaults write com.apple.logic10 AppleLanguages -array <lang>`,
   relaunches Logic on the same project, and **verifies** the running UI is in that locale by reading
   the menu bar — a run that cannot prove its locale refuses, as `session_519_locale_flow.py` already
   does;
2. runs the census over every surface it can reach;
3. writes one observation record per `(surface, locale)` with the census as `evidence`;
4. proposes `provenance` for every label set whose canonical or variant matches a census string,
   and `coverage: absent` for every set whose canonical appears verbatim.

The proposals are reviewed and committed by a person. The campaign is how `ja-JP` and `en-US` get
measured; the repository's owner has explicitly authorised switching Logic's language.

### D5 — Records carry `schema` and `evidence`

Records gain `"schema": 2` and an `evidence` list of files under `docs/observations/evidence/` —
census dumps, screenshots, harness output — that the guard verifies exist. Existing records are
`schema: 1` implicitly; both validate, and the v1 count is a burn-down.

### D6 — One command answers "what do we not know?"

`observations-status.py --unproven` prints, in one place:

- every variant without provenance, by label set;
- every `(label set, locale)` that is `unmeasured`;
- every `(surface, locale)` with no record;
- every record at schema 1;
- every record whose `reverify.kind` is `manual`;
- every `depends` entry whose file or symbol no longer resolves.

Each line is a thing a person can go and do. The counts behind it are the ratchets in D8.

### D7 — `reverify` has a contract and a runner

Exit 0 the record still holds; 1 it does not; 2 a precondition was not met. The three scripts that
exist already follow this by convention; it becomes the rule. `observations-status.py --reverify
<id>` runs one; `--reverify-stale` runs every stale record's command in turn and reports which
disagreed. `kind: manual` is honest and is counted as debt.

### D8 — Ratchets are data in one file

`docs/observations/RATCHETS.json` holds every burn-down ceiling:

```jsonc
{ "undocumented_variants": 255, "unmeasured_coverage": {"en-US": …, "ko-KR": …, "ja-JP": …},
  "schema_v1_records": 24, "manual_reverify": 19, "surfaces_without_records": 6 }
```

A guard compares the live counts to the file and fails on any count that rose. Lowering a ceiling
is a normal commit; raising one is a reviewed decision with a reason in the diff. Scattering these
numbers as constants inside individual guards — which is where `TOTAL_VARIANT_CEILING = 257` lives
today — is what makes a ratchet invisible to the person deciding whether to move it.

## Phases

| phase | delivers | measurement needed |
|---|---|---|
| **P1** | ADR; JSON schema 2 with `provenance` + `coverage`; RATCHETS.json seeded at today's numbers; guards + self-tests; `--unproven` | none — seeds only |
| **P2** | census tool; campaign script; `ja-JP` and `en-US` campaigns run; records written; provenance filled from census; ratchets lowered | Logic in three locales |
| **P3** | `evidence` on records; schema-2 migration of the 24; reverify runner; `manual` burn-down | reruns of existing reverify commands |

Each phase is one branch, blind-reviewed before merge.

## Consequences

- A translated variant can no longer be added by editing Swift alone. That is the point: the guard
  refuses a string nobody read.
- `coverage: absent` is a claim and needs the same provenance as `present` — a record in that locale
  showing the surface. The campaign produces it; hand-writing it is the same fabrication the whole
  system exists to prevent.
- Four ratchets and a burn-down list mean the state of knowledge is visible in a diff, and a change
  that reduces it fails CI rather than passing quietly.

## Not decided here

- Whether `coverage` should be carried into Swift as a compile-time table. It would let the product
  refuse a lookup in a locale it knows it has not measured. That is a product behaviour change and
  wants its own decision.
- Locales beyond the three named. The shape admits more; adding one is a row in this document and a
  campaign, not a schema change.
