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
schema 2) points INTO these records: a variant's `provenance` names the record, the AX `role` and
the `attribute` it was read from, and the guard requires the record to contain a **sighting** — an
element of that role whose that attribute carried the string. Not a substring of the serialized
record, which accepted the variant `input` on the strength of a key named `with_input`.

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
