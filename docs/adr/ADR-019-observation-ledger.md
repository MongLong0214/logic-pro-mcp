# ADR-019 — Observation Ledger: every claim names the record that produced it

**Status:** Proposed — revised after blind review (2026-09-05); P1 implements D1, D2, D3, D6, D8
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

These are four different failures, and an earlier draft of this document called them one. They
are not:

| gap | kind of failure | what closes it |
|---|---|---|
| 255 variants with no reading | evidence integrity — a string the product matches with nothing behind it | D1 makes a NEW one impossible; only D4's campaign closes the existing 255, by measuring them |
| 18 empty `variants` lists | state model — one shape for "measured, nothing distinct", "addressed by identifier", "never looked" | D2: a per-locale coverage state |
| 113 with no Japanese | **measurement not performed** — no schema closes this | D4: a campaign, run |
| `host.locale` inert | reporting — the field exists and nothing asks it anything | D3: a locale axis in the status tool |

What they share is narrower than a root cause: in each, the system can say a thing is *well-formed*
and cannot say it is *true of Logic*. The unit of trust has to move from "the record is well-formed"
to "the string the product will match was read, in this record, and here is the reading". This
document makes the first, second and fourth gaps mechanical. It makes the third *countable*; only
running the campaign closes it, and a phase that ships without new measurement has not closed it.

## Decision

### D1 — A variant is a claim, and a claim names its record

`ui-labels.json` moves to `schema: 2`. Every variant carries a `provenance` block:

```jsonc
"roles": ["AXButton"],            // the AX roles THIS LABEL may be read on — see below
"provenance": {
  "입력 슬롯": {
    "record":    "2026-09-04-mixer-slot-readback-was-a-one-language-match",   // MUST exist
    "locale":    "ko-KR",         // MUST equal that record's host.locale
    "date":      "2026-09-04",    // MUST equal that record's date, and be a real one
    "role":      "AXButton",      // MUST be one of `roles`
    "attribute": "help",          // which AX attribute carried it
    "match":     "contains",      // `exact` or `contains`; MUST agree with how Swift reads the set
    "observed":  "입력 슬롯. 채널 스트립 입력 소스를 선택합니다…"   // a QUOTE, see below
  }
}
```

`observed` is not a field an author fills in: it must equal, character for character, the value the
cited record recorded on that element. Requiring only that it CONTAIN the variant left the rest of
the string free, and a real truncated reading was cited while `observed` claimed the untruncated
text nobody had read. If the record truncated, the quote is truncated.

`roles` is declared per label, not per block, and every citation must name one of them. Without it
the shared-string hole D2 closes for coverage stays open for provenance: `editMenuBar` could be
backed by a sighting of `編集` on an `AXMenuButton` that belongs to `markerListEditMenuButton`. It is
author-typed on purpose — the AX role is not derivable from the Swift, and a typed CONSTRAINT can
only ever refuse evidence, never manufacture it, so a wrong one costs a false RED somebody fixes.

Resolving `record` to a file and matching its `host.locale` is cheap referential integrity — it
catches a dangling id and a locale typo, and it is not evidence. A fabricated variant could cite any
same-locale record and paste itself into `observed`. What makes provenance a reading is one more
check, and it is the load-bearing one:

**the record must contain a SIGHTING of the variant**: an element of a named `role` whose named
`attribute` carried that string, under a named `match` mode. The block names all three, and the
guard walks the record's row-shaped
readings (its own `observations`, plus any file under `docs/observations/evidence/`) looking for
that element. The block's `date` must equal the record's.

A sighting, not a substring. Searching the serialized record was the first cut, and it accepted two
things it should not have: the variant `input` was satisfied by the KEY `with_input`, and
`eventListColumnL`'s canonical `L` by any capital L in any path in any reading. An element and an
attribute are also what a caller needs in order to find the thing again, so the evidence and the
addressing are the same three fields.

`match` is `exact` or `contains`, and it is data rather than a guess. An earlier cut inferred it
from the label's NAME — `*Keyword` meant containment — and measured against the product's real call
sites it was wrong in both directions: `cancelButton` and `audioPluginSlotLabel` are read with
`containsAny`, while `inputSlotHelpKeyword` appears at no call site at all because it is passed to a
helper that does the matching. So the block declares it, and where the Swift *can* say, the guard
requires the declaration to agree.

Evidence is read as JSON rows and must live under `docs/observations/evidence/`. A screenshot
therefore cannot back a claim — it is worth keeping and it is not machine-checkable, and pretending
otherwise would be the same fabrication one level up.

A record that never saw the string cannot be cited for it. This holds today for both existing
provenance entries — the mixer-slot record's `help` readings contain `입력 슬롯` and `출력 슬롯` —
and it is exactly the relationship the earlier shape never required. What it still cannot check is
whether a record's observations were themselves typed rather than read; that is what the ledger's
own schema, `reverify`, and review are for, and this document does not claim otherwise.

A **new** variant without provenance is refused. Existing undocumented variants are a burn-down:
listed by name, counted, and the count may only fall.

### D2 — Empty `variants` is not a state. `coverage` is.

A `LabelSet` is not one translation slot per locale. It aggregates synonyms and contexts —
`deleteTracksPrimaryButton` carries both `Delete Tracks and Content` and `Delete`, and an English
Logic shows both, on different sheets. So "present" and "absent" are not exclusive for it, and an
earlier draft's four-state model was wrong. Three states are:

| value | meaning | is it a gap? |
|---|---|---|
| `measured` | a record in this locale observed the surface this label lives on, and its observations contain at least one of this label's strings — a variant with provenance, or the canonical | no |
| `identifier` | not matched by label at all — addressed by a locale-free `AXIdentifier`, and a record in this locale observed that identifier on that element | no |
| `unmeasured` | nobody has looked | **yes** |
| `retired` | the element this label addressed is no longer read through it, so no measurement in any locale can ever close it | no |

**Data model.** `coverage[locale]` is one of those strings. When a variant with provenance in that
locale exists, `measured` is DERIVED and no citation is stored — the provenance is the evidence.
Otherwise three fields are required and the guard checks all three:

| field | holds |
|---|---|
| `coverage_records[locale]` | the record id |
| `coverage_roles[locale]` | the AX role the label addresses — `Edit` on a menu bar is not `Edit` on a toolbar button, and both `editMenuBar` and `markerListEditMenuButton` carry `Edit`, `편집`, `編集` |
| `coverage_identifiers[locale]` | for `identifier` only: the AXIdentifier, which the record must have been seen carrying |

Without the role, any record showing either element backs both, which is the same shared-string
hole D1 closes for variants.

`retired` requires a label-level `retired.reason`. It exists because `headerPanHint` — superseded by
`sliderPanHint` — sat in the ledger as three locales of `unmeasured`, which is debt nobody could
discharge by measuring anything. A permanent gap overstates the real one and trains readers to
ignore the number.

There is no `absent`. "Logic shows the canonical here" is a `measured` whose record contains the
canonical; "this element is unlabelled" is a `measured` whose record says so in its observations.
Neither is a state of its own, and neither is manufactured: the campaign in D4 proposes nothing for a
label whose strings it did not see on an element of the right role.

Supported locales are `en-US`, `ko-KR`, `ja-JP`. `unmeasured` is counted per locale and each count
may only fall. **#778 is the `ja-JP: unmeasured` count**; #768's eighteen empty lists become
eighteen declared states, most of them `unmeasured`, which is the true one.

`coverage` lives in the JSON, not in Swift. Swift stays the compiled source of the *strings*; the
JSON carries what is known *about* them, and `Scripts/locale_labels.py --write` preserves it —
`provenance`, all three `coverage_*` maps, and the typed `roles` and `retired`, which travel
together. Carrying only some of them was a data-loss bug: the next `--write` stripped the backing a
claim needed and the guard then refused a claim that had been valid.

### D3 — Locale becomes an axis of the ledger

`host.locale` stays a field and stops being inert. `observations-status.py --coverage` reports, per
surface, which locales have a record — and then per LOCALE, how many surfaces that locale has seen.
The second half matters more than it sounds: on the day this landed, 13 of 19 surfaces had a record
and every one of those records was Korean, so a locale-blind "13 of 19" was reporting coverage the
ledger did not have. It reads the ratchet guard's `live_state`, so the report and the enforcement
cannot drift into two definitions of a gap. D1's cross-check (variant locale ⇔ record locale) is what makes
the JSON auditable against the ledger rather than beside it.

### D4 — A census tool and a campaign, so the gaps can actually be closed

`Scripts/observations/locale-census.swift` walks a named surface and emits every
`{role, attribute, string, path}` it can read. `Scripts/observations/locale-campaign.sh <locale>`:

1. refuses unless the open project is the **disposable fixture** `Fixtures/locale/campaign.logicx`
   — it never saves, closes or overwrites a user's project, and authorisation to switch Logic's
   language is not authorisation to resolve a save prompt on someone's work. `session_519` refuses
   to restart for that reason; the fixture is what removes the reason;
2. sets `defaults write com.apple.logic10 AppleLanguages -array <lang>`, relaunches on the fixture,
   and **verifies** the running UI is in that locale by reading the menu bar. A run that cannot
   prove its locale refuses;
3. runs the census over the **navigation-free** surfaces first: the menu bar and every menu (AX
   reads them without opening them) and the whole main window, classified by the labelled ancestry
   the census writes into each path rather than by a label the new locale has not been measured for.
   Surfaces behind a menu press or a button — plug-in editors, the Event List — are reached only
   with labels the first census produced, so the second campaign uses what the first measured;

   **The locale proof bootstraps and does not verify.** Confirming "this is ja-JP" by reading
   `ファイル` needs a Japanese label that is itself unmeasured. So a locale's FIRST campaign records
   the locale it *requested* along with the menu-bar titles that came up, and establishes them as
   the witness; every later run checks against that record and refuses on a mismatch. The first run
   is a measurement, not a check, and the record says which it was;
4. writes one observation record per `(surface, locale)` with the census as `evidence`;
5. proposes `provenance` for a label set only where a census element of the **same role**
   carries its canonical or a variant — `editMenuBar` and `markerListEditMenuButton` both say
   `Edit`, and only one of them is a menu-bar item. It proposes nothing else.

The proposals are reviewed and committed by a person. The campaign is how `ja-JP` and `en-US` get
measured.

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
{ "allowed": {
    "undocumented_variants":    ["regionKindMidi→가짜", "…"],          // 255 members
    "unmeasured_coverage":      {"en-US": ["…"], "ko-KR": ["…"], "ja-JP": ["…"]},
    "schema_v1_records":        ["2026-08-30-…", "…"],
    "manual_reverify":          ["…"],
    "surfaces_without_records": ["en-US→arrange.regions", "…"] },
  "raised": {
    "undocumented_variants": { "date": "2026-09-05", "reason": "…",
                               "members": ["regionKindMidi→가짜"] } } }   // exactly what it allows
```

**Sets of identities, not counts.** A count is defeated by a swap: add one undocumented variant,
document a different one, and `variants - provenance` is unchanged while the ledger knows strictly
less about a new string. So the file holds the members — `regionKindMidi→가짜`, not `255` — and a
new member fails even when the total falls. The diff then says which claim appeared, which a number
never could.

**The base is authoritative for growth, and it is a real merge base.** `git merge-base HEAD
origin/main`, not that ref's tip, which a branch can outrun. The file is not consulted for the
growth test at all: unioning the two is exactly what a same-commit raise exploits — add the member,
add it to the file, and a union permits it. A member the base already allowed is therefore never a
growth, which is what lets a branch drop one from its own file once it has genuinely CLOSED it.

**A ceiling must still name everything live.** Growth-against-base and lag-against-file leave a gap
between them: with the base allowing `{b,c}`, a file listing only `{b}` and `c` still live, there is
no growth and no lag, and the ceiling quietly under-reports by one. Understatement is therefore its
own finding — every live member must appear in the file, whatever the base allowed. An earlier draft
of this document described that shape as correct, and its self-test asserted it.

**Three findings, independently.** Growth, lag and understatement are reported separately. They were
an if/elif, so one valid raise silenced the other two on the same key: a change could add a member
with a reason and drop an unrelated closed one in the same commit, unremarked.

**A raise lands, and only for what it names.** An entry under `raised` with a real calendar date, a
reason with substance, and a `members` list passes — printing all of it. Refusing every raise made
`raised` unusable, because the base can never acquire a member without merging a change that fails.
But `members` is what binds the decision to what it decided: without it, one raise recorded for one
growth authorised every later, unrelated growth on the same key forever. `2026-99-99` is date-SHAPED
and is not a date; a `reason` of `"\u200b"` survives `strip()` and says nothing. Both are refused.

**An unreadable base is a failure in CI.** GitHub's checkout is shallow by default, so the merge base
is absent, so the guard silently degrades to comparing the branch against its own file — and a commit
that adds a gap while raising its own ceiling passes. Under `CI` that is now an error naming the fix
(`fetch-depth: 0`, which this repository's workflow sets); locally it stays a note. A base that
RESOLVES but predates the ledger is a different thing — the commit introducing the file — and is
allowed once, named as `bootstrap`, because refusing it would make that commit unmergeable.

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
- `coverage: measured` without a variant is a claim and needs a record in that locale whose
  observations contain the canonical. The campaign produces it; hand-writing it is the same
  fabrication the whole system exists to prevent, and the guard refuses it the same way.
- Four ratchets and a burn-down list mean the state of knowledge is visible in a diff, and a change
  that reduces it fails CI rather than passing quietly.
- **P1 does not close the 255.** It replaces "2 documented is a stable equilibrium" with "255
  undocumented is a counted, named, non-growing debt". Those are different states and only the
  second can be worked off; the work is P2, and it is measurement, not schema.

## Not decided here

- Whether `coverage` should be carried into Swift as a compile-time table. It would let the product
  refuse a lookup in a locale it knows it has not measured. That is a product behaviour change and
  wants its own decision.
- Locales beyond the three named. The shape admits more; adding one is a row in this document and a
  campaign, not a schema change.
