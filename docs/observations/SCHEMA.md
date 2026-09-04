# Observation records

Every live measurement gets a JSON record here.

## Why these exist

Logic is a moving target. A measurement is true of **one build of one application**, and when Logic
updates the surface can change underneath code that was written against it — silently, because the
code still compiles and the unit tests still pass. This repository has already been bitten by the
inverse: a roadmap row saying `NOT STARTED` about work that had shipped, and `popupUnmeasured`
sitting unmeasured for two weeks beside a note saying so.

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
    "os": "macOS 26.6"
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
5. **`host` is what the claim is true of.** Enforced: `version` and `build` are required, and
   `Scripts/observations-status.py` reports every record whose host differs from the installed Logic.
6. **`reverify` is required**, because a claim nobody can re-run is a claim nobody can retire. Use
   `"kind": "manual"` with steps in `command` when no script exists yet — that is honest and still
   actionable; a missing field is neither.
7. **`depends` names the code standing on the claim**, so a stale observation reports which paths are
   now running on an unverified assumption.

## Tools

```
Scripts/observations-status.py            # what is current / stale / superseded, and why
Scripts/observations-status.py --stale    # exit 1 if anything is stale — for a post-update sweep
Scripts/check-observation-records.py      # schema, run by CI
Scripts/check-observations-cover-live-walls.py   # roadmap claims must have records, run by CI
```

## When Logic updates

1. `Scripts/observations-status.py` lists every record whose `host` no longer matches, and the
   `depends` paths that were standing on each.
2. Re-run each `reverify` command.
3. Agreeing runs get a fresh record with the new `host` and `supersedes` set to the old id.
   Disagreeing runs get the same, and their `depends` paths need fixing.
