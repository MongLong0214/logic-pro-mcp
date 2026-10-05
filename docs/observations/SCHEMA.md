# Observation records

Every live measurement gets a JSON record here.

## Why these exist

Logic is a moving target. A measurement is true of **one build of one application**, and when Logic
updates the surface can change underneath code that was written against it — silently, because the
code still compiles and the unit tests still pass. This repository has already been bitten by the
inverse: a roadmap row saying `NOT STARTED` about work that had shipped, and `popupUnmeasured`
shipping on 2026-09-02 with a note saying the selection was unmeasured, which stayed the refusal's
stated reason after 2026-09-04 measured it. Two days, and the note outlived the fact it reported.

So a record is not a note. It is a **claim bound to a host build, with the method to re-run it and
the code that depends on it**. When Logic moves, the question "what do we now not know?" has a
mechanical answer instead of a memory.

This mirrors `HostParameterGate`, which already invalidates a plug-in capability manifest when
`buildFingerprint` or `uiSignatureFingerprint` moves. Same principle, applied to what we know rather
than to what we expose.

## Lifecycle

```
        measured on host H
              |
          [ current ]  ── host moves ──▶  [ stale ]  ── re-run ──▶  current (new record)
              |                                |                         |
              |                                └── re-run disagrees ──────┤
              |                                                          ▼
              └────────── a later record supersedes it ──────▶     [ superseded ]
```

`stale` is not a failure. It is the honest state of a measurement whose host has moved and which
nobody has re-run. Code that depends on a stale observation is running on an assumption that was
true of a different application.

## Schema

```jsonc
{
  "id": "2026-09-04-controls-view-popup-selection",   // = filename stem, unique
  "date": "2026-09-04",                                // when MEASURED
  "subject": "Controls-view AXPopUpButton selection",
  "question": "Can a popup value be selected by name?",// answerable, not a topic
  "verdict": "wall",                                   // works | wall | partial | inconclusive
  "issues": [292, 306],

  "host": {                          // WHAT THIS IS TRUE OF. Drift is computed from these.
    "app": "Logic Pro",
    "version": "12.3",               // CFBundleShortVersionString
    "build": "6674",                 // CFBundleVersion — moves on updates that keep the version
    "locale": "ko-KR",               // AX labels are localised; a locale change can invalidate
    "os": "macOS 26.3 (25D125)"      // also a drift axis: an OS bump moves the AX surface too
  },

  "reverify": {                      // HOW TO RUN IT AGAIN. Required — see rule 6.
    "kind": "script",                // script | harness | manual
    "command": "Scripts/observations/reverify-controls-view-popups.sh",
    "expected": "every opened popup menu exposes only its current choice, or duplicate titles",
    "cost": "needs Logic open with a Compressor inserted; ~2 min"
  },

  "depends": [                       // CODE STANDING ON THIS. Empty is allowed and means nothing does.
    "Sources/LogicProMCP/HostParameters/ControlsViewBooleanParameterWriter.swift:LocatorFailure.popupUnmeasured"
  ],

  "method": "…how it was driven, including what was NOT done",
  "observations": [ … ],             // raw readings; never a summary of them
  "conclusion": "…what the readings support, no more",
  "limits": ["…what this does NOT establish"],
  "supersedes": null                 // id of the record this replaces
}
```

### `verdict`

| value | meaning |
|---|---|
| `works` | the thing does what was asked, observed by effect |
| `wall` | measured to be impossible on this host, with the reading that shows it |
| `partial` | works under stated conditions, named in `limits` |
| `inconclusive` | the instrument could not answer; say why in `limits` |

`inconclusive` is a real verdict. An instrument that could not see is not evidence of absence.

## Rules

1. **Observations before conclusions.** A number in `conclusion` must be derivable from
   `observations`. Enforced.
2. **`limits` is not optional.** Writing `[]` claims there is no boundary, which is nearly always
   false. Enforced.
3. **Status codes are not results.** An AX call returning `success` is a reading about the call, not
   about the world. Record what was observed afterwards.
4. **Supersede, never edit.** A later run that disagrees gets its own record with `supersedes` set.
   Two runs disagreeing is exactly what you want to be able to see.
5. **`host` is what the claim is true of. Generate it, never type it.**
   `Scripts/observation_host.py` prints the block measured from the machine you are on;
   `--check` compares existing records against it. `app`, `version`, `build` and `os` are
   required, and `Scripts/observations-status.py` reports every record whose `version`,
   `build` or `os` differs from what is installed.

   This rule is written the strong way because of what happened without it: on 2026-09-04 all
   nine records in the tree claimed `macOS 26.6` on a machine that has run `macOS 26.3` since
   February. The first block was written by hand and every later record inherited it by copy,
   so the error propagated exactly as fast as the records did. Nothing caught it — a copied
   field looks identical to a measured one. `locale` is recorded but is deliberately not a
   drift axis: a ko-KR record does not become untrue when the machine switches to en-US, it
   becomes a claim about a different host.

   A retained historical reading whose host was not bound must not borrow metadata generated
   later. Without changing the schema version, declare all required host keys, keep a nonempty
   `app`, and set `version`, `build`, `os`, and `locale` to JSON `null`, with
   `"binding": "unknown"` and a nonempty `reason`. Status readers report this as `unknown`, not
   current or stale; it grants no build or locale coverage. The existing
   `records_from_a_superseded_build` gap set also counts this unbound record. Keep any later
   installed metadata separately in the cited evidence, labelled with its collection time and
   limits; it cannot fill these historical fields. Known-host records retain the existing
   nonempty-field and supported-locale requirements.

6. **`reverify` is required**, because a claim nobody can re-run is a claim nobody can retire. Use
   `"kind": "manual"` with steps in `command` when no script exists yet — that is honest and still
   actionable; a missing field is neither.
7. **`depends` names the code standing on the claim**, so a stale observation reports which paths are
   now running on an unverified assumption.

## Schema 2 (ADR-019)

A record may carry two more keys. Records without them are schema 1, still valid, and counted as
a burn-down in `RATCHETS.json`.

```jsonc
  "schema": 2,
  "evidence": [                      // files this record rests on, under docs/observations/evidence/
    "evidence/2026-09-05-ja-JP-arrange-menus.census.json"
  ]
```

`evidence` files must exist; the guard checks. A record whose readings live only in its own
`observations` array is fine and states `"evidence": []` — the point is that a census dump or a
screenshot the conclusion depends on cannot be cited and then lost.

### Locale is an axis

`host.locale` is still not a *drift* axis (rule 5), but it is a *coverage* axis: the same question
measured in `ko-KR` and in `ja-JP` is two records, and `observations-status.py --coverage` reports
which locales each surface has been looked at in. The label projection (`docs/locale/ui-labels.json`,
schema 2) points INTO these records: a variant's `provenance` names the record, the AX `role`, the
`attribute` it was read from and the `match` mode (`exact`, `exact_strict`, `prefix` or `contains`), and the guard requires
the record to contain a **sighting** — an element of that role whose that attribute carried the
string under that mode. Three further rules make the citation hold:

- **`observed` is a quote.** It must equal, character for character, the value the cited record
  recorded on that element. Requiring only that it CONTAIN the variant left the rest of the field
  free, and a real but truncated reading was cited while `observed` claimed untruncated text.
- **`path_contains` says WHERE, when the label means a particular one.** Optional, and checked when
  present: the sighting's `path` must contain it. `roles` distinguishes KINDS of element and says
  nothing about which — Logic puts an `AXMenuButton` labelled `Edit` in the arrange window, in the
  mixer and in the Marker List. Measured 2026-09-05: four labels had a sighting satisfying every
  rule this file states — string, role, attribute, locale, real record — and all four were the
  wrong element, because the label meant a container the sighting was not in. The record already
  carried the answer; provenance had no field that read it.

  Do not backfill it from sightings that already exist. That is fitting the constraint to the
  evidence, which is how those four would have been written. Declare where the label addresses from
  the label's own meaning, then look there; where nothing is found, the label is unmeasured.
- **The role must be one the label declares** in its `roles` list. Otherwise a sighting of the same
  string on a different element backs the wrong label — `Edit` on a menu bar is not `Edit` on a
  toolbar button. `roles` is author-typed, and it is NOT the harmless kind of typed constraint: it
  selects which rows are searched, so a wrong role admits a sighting of the wrong element rather
  than merely refusing a right one. What this rule checks is that a citation names an element class
  and a record that shows one. It does not check that the class is the one the product searches.
- **A record's `expected` / `counterexample` subtrees are not readings.** They are element-shaped on
  purpose, which is what let a counterexample back the claim it was written to deny.
- **`exact_strict` is a third mode, not a stricter second.** `.exact` trims the observed text
  before comparing and `.exactStrict` does not — it exists to preserve the raw `desc == label`
  semantics the structural locators were written with. Held as one `exact`, the ledger certified a
  padded reading the product refuses: an AXGroup description of `" 再生ヘッドの位置 "` satisfies a
  trimming comparison and fails the one that element is actually read with. Which mode a label uses
  is derived from the Swift, like containment. Three labels are read BOTH ways at different call
  sites — so "the mode is a property of the label" is false for them; they are held to the looser
  rule and the guard names them on every run rather than leaving that implied.
- **`prefix` is the fourth mode.** It ANCHORS, so containment is looser than it, and the one label
  the product reads this way declared `contains` — the ledger accepted a sighting mid-value that
  the product refuses. Derived from the `MenuPath(..., itemMode: .prefix)` form, which names its
  LabelSet; a call site that passes a local variable cannot be derived and is not claimed.
- **The comparison folds case, because the product's does.** Every mode of `LabelSet` is
  case-insensitive — `.exact` and `.exactStrict` use `caseInsensitiveCompare`, `containsAny`
  searches with `.caseInsensitive` — and a guard stricter than the thing it audits refuses honest
  readings. Measured: Logic shows `Tracks contents`, `trackContentExplicit` stores `tracks
  contents` because the classifier lowercases before the lookup, the product matches, and a raw
  comparison did not. The only way to satisfy it was to write a variant Logic does not show. What
  does NOT fold is the `observed` quote above: matching is the product's rule, fidelity is this
  file's.

The mode is data because it cannot be guessed: inferring it from the label's NAME was wrong in both
directions against the real call sites, and where the Swift *can* say —
`AXLocalePolicy.<name>.containsAny` — the guard requires the declaration to agree with it. And a
sighting is a row, an attribute and the value that attribute carried — not a substring of the
serialized record, which accepted the variant `input` on the strength of a key named `with_input`.

`coverage` adds `retired` to `measured` / `identifier` / `unmeasured`, for a label whose element is
no longer read through it — permanent debt no measurement could ever discharge. It requires a
reason, and the reason is audited: a label whose name still appears as `AXLocalePolicy.<name>` in
`Sources/` cannot be retired. Taken on trust it was an escape hatch, because the projection marks
every locale `retired` and the ratchets count only literal `unmeasured` — so asserting a live label
was gone dropped a real gap out of every ceiling with no raise.

**Measured absence** — `measured` with `coverage_absent[locale]` — names the element it is about, as
a fragment of its AX path. The record must contain a row of the declared role at that path, and no
row there may carry any of the label's strings. `true` was accepted at first and it let any row of
the role anywhere in the record stand for an element nobody had looked at.

What this does NOT check is whether a record's own rows were read or typed. A record carries
readings, and a person writing down what they saw is how most of this ledger was built; the guard
verifies that the record SAW the string, not how the record came to say so. That is the ledger's
trust boundary, and `observations-status.py --unproven` now counts both kinds so it is visible
rather than only written down here.

So a record's `observations` are worth writing **row-shaped** — `{"role": …, "help": …}` — because
that is the shape a claim can rest on. Evidence files must live under `docs/observations/evidence/`
and are read as JSON rows; a screenshot is worth keeping and cannot back a claim, which is the
honest position rather than a checkbox.

### What the ledger does not know

```
Scripts/observations-status.py --unproven
```

lists, **by name**, things a person can go and do: variants with no provenance; label sets
unmeasured per locale; surfaces with no record per locale; records at schema 1; records whose
`reverify` is manual prose; `depends` entries that no longer resolve. Names rather than counts,
because a count is not a thing anyone can act on.

There is one thing that list cannot say, and it is the one the ledger was blindest to: a variant
that is present and WRONG. `undocumented_variants` counts strings nobody has backed; nothing
counted a string somebody typed instead of read. `playheadPositionGroupLabel` carried
`再生ヘッド位置` for as long as it had existed, Logic shows `再生ヘッドの位置`, and the set is
matched whole — so one missing character made the element unfindable on every Japanese Logic, and
the ledger read it as coverage.

```
Scripts/check-variants-appear-in-a-census.py
```

compares every variant against the census of its OWN locale, decided by script, and prints the
ones that are absent with a close neighbour. It is **counted, not gated**: the censuses are
navigation-free, so a label living on a dialog or a sheet is legitimately absent, and failing on
absence would make it wrong far more often than right. The near misses are for a person to read —
of the first five, three were real defects, one was a spelling the policy carries on purpose, and
one was a census artefact.

`docs/observations/RATCHETS.json` holds those same things as **sets of identities**, and
`Scripts/check-observation-ratchets.py` fails CI when a set gains a member — even if the total
falls, which is how a swap hides inside a count. It compares against the real `git merge-base`,
and the base is authoritative for growth: unioning it with the branch's own file is what a
same-commit raise exploits. A member that closed also fails, asking to be removed. Raising takes a
dated reason under `raised`, which lands and prints.

`RATCHETS.json` sits beside the records and is not one: a record is a **date-prefixed** file, and
every loader uses that rule rather than a name special-case.

## Tools

```
Scripts/observations-status.py            # what is current / stale / superseded, and why
Scripts/observations-status.py --stale    # exit 1 if anything is stale — for a post-update sweep
Scripts/check-observation-records.py      # schema, run by CI
Scripts/check-observations-cover-live-walls.py   # roadmap claims must have records, run by CI
Scripts/check-observation-ratchets.py     # what the ledger does not know may only shrink, run by CI
Scripts/observations-status.py --unproven # everything the ledger does not know, as a list
```

## When Logic updates

1. `Scripts/observations-status.py` lists every record whose `host` no longer matches, and the
   `depends` paths that were standing on each.
2. Re-run each `reverify` command.
3. Agreeing runs get a fresh record with the new `host` and `supersedes` set to the old id.
   Disagreeing runs get the same, and their `depends` paths need fixing.

## Schema 3 — the canon axis

A record at schema 3 says where each of its facts about Logic came from: Apple's bytes, or a
measurement taken because Apple's bytes could not answer. `docs/canon/README.md` holds the design;
this is the part a record author needs.

```jsonc
  "schema": 3,

  "canon": [                          // facts taken from Logic's own data
    {"ref":   "logic-canon://<source>/<unit>/<locale>/<key>#<field>",
     "value": "녹음 버튼. 선택한 트랙 또는 녹음 준비된 여러 트랙에 녹음합니다.",
     "used_for": "the key the AXHelp parser returns for the transport record button"}
  ],

  "canon_absent": [                   // facts no canonical source can answer
    {"claim":   "one live AXHelp value has no canonical source anywhere in the bundle",
     "strings": ["이 버튼을 누르면 윈도우를 확대/축소합니다."],
     "searched": [{"source":"quickhelp","locale":"ko"}, {"source":"strings","locale":"ko"}],
     "why_runtime": "an exhaustive scan of all 75,535 bundle files in three encodings found it nowhere"}
  ]
```

```jsonc
  "canon_not_applicable": {          // this record is not about a string Logic ships
    "reason": "read order, not any string in a .strings table"
  }
```

A schema-3 record needs one of the three. A record that cites nothing, claims nothing is uncitable
and does not say the axis is inapplicable is a record whose relationship to Logic's own data was
never stated.

`canon_not_applicable` exists because several records state facts about Logic's **behaviour** —
"the routing graph publishes nothing or 23 nodes depending on read order", "the marker list settles
in seconds and a poll that does not wait reads a stale answer". There is no key to cite and nothing
to prove absent, and forcing a citation there produces a perfunctory one, which is the failure this
axis exists to end arriving through the front door.

It is **not** a free pass. The guard reads the record's own readings, and if any of them resolves in
the corpus then a citation was available and the declaration is false. Measured against the
thirteen new records of one open branch: **eight quote nothing citable and may decline; five quote
strings Logic ships** — `Neue Spur`, `Erzeugen`, `컨트롤러 할당…` — and are named by the check. The
split is derived, not chosen.

`Scripts/check-canon-citations.py` refuses:

| | |
|---|---|
| a reference that does not parse | |
| a reference not in `docs/canon/index/` | nobody resolved it against Logic |
| a quoted value whose digest differs from Apple's | **the rule this axis exists for** |
| an absence claim over a corpus with no absence set | an absence over nothing is not a proof |
| an absence claim for a string Logic ships | it can be cited, so it must be |
| a schema-3 record with neither key | |
| a NEW record at schema 2 or lower | `docs/canon/WITHOUT-CANON.json` may only shrink |

### Why the ratchet is seeded full

104 records predate this rule and are listed in `WITHOUT-CANON.json`. Turning 104 records red at
once is how a rule gets deleted rather than satisfied; letting the 105th in quietly is how it
becomes decorative. The list may only shrink, and a member naming a file that is gone fails —
the same shape as `check-guards-have-self-tests.py`'s known-bare set, for the same reason.

### How this interacts with the label projection

`docs/locale/ui-labels.json` carries variants backed by a **sighting** in a record — a row that
carried the string. A sighting says a person saw it. A citation says Apple ships it. They answer
different questions and the second does not retire the first: a string can be in Logic's data and
never reach the interface (the live UI shows untranslated `German` and `MIDI Region` although ko
translations for both keys exist), and a string can reach the interface with no file behind it.

Measured 2026-09-15 across `AXLocalePolicy`'s 379 distinct literals: 113 are a QuickHelp Title,
226 more are somewhere in the bundle's 605,190 `.strings` entries, and **40 are in no file of the
app bundle**. Roughly half of those 40 are deliberate lowercase fragments for `.contains` matching
and were never whole labels; the rest are labels Logic composes at runtime, labels from a framework
outside this corpus, or labels somebody typed. Nothing in the ledger could tell them apart, which
is what the canon axis is for. The live count is printed by
`Scripts/check-policy-literals-against-canon.py`; do not restate it from memory.

### What a citation does not prove

That it is the **right** citation. A reference resolving with the right digest proves the quote is
Apple's text under that key. It does not prove that key describes the control the record is about.
`used_for` is required and is read by a person — the same trust boundary this file already names
for sightings.
