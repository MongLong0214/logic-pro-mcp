# T1: Drive Logic's per-track audio export from the export panel

**Issue**: #369 — `export_run artifacts:[stem]` currently yields a single project-level bounce
**Priority**: P1
**Size**: M
**Status**: Not started
**Depends On**: a contract decision, named in §5

---

## 1. Why this ticket exists at all

The roadmap entry for #369 said the export panel's per-track filename fields report
`settable=true` and do not accept writes, and that *"if that holds, per-track stems cannot be driven
from this surface and the issue closes with the measurement."*

**It does not hold.** Measured 2026-08-19 on Logic Pro 12.3, driving the panel with Accessibility
only and no coordinates:

```
~/Music/Logic/Studio Grand_1.aif    394,922 bytes

logic_audio.analyze_file:
  channel_count 2 · sample_rate 48000 · duration_seconds 2.048
  peak_dbfs -13.799 · non_silent_duration_seconds 0.744 · silence_ratio 0.637
  verification { status: "pass" }
```

Real audio, produced by the surface this issue said could not produce it. So #369 does not close with
a measurement of absence; it is implementable work, and this ticket is the mechanism.

## 2. The mechanism, measured

**The menu.** `File ▸ Export ▸ All Tracks as Audio Files…`. Two facts that a naive drive gets wrong:

- Enablement read from a CLOSED menu is meaningless. The same items read `enabled=false` closed and
  `enabled=true` with the menu open — macOS validates on open. A probe that skips opening reports
  every export item unavailable.
- The leaf's TITLE is rewritten by Logic with the selection: `Tracks as Audio Files…` became
  `1 Track as Audio File…`. Resolving a leaf by name must survive a title Logic edits, not only one
  it localizes.

**The panel.** 628 elements. Buttons `New Folder`, `Hide Options`, `Cancel`, `Export` — the options
are already shown. The option surface is fully readable:

```
popups      Logic · Trim Silence at File End · AIFF · One File per Track · 16-bit ·
            Overload Protection Only
checkboxes  Bypass Effect Plug-ins · Include Audio Tail · Include Volume/Pan Automation ·
            Add resulting files to Project Browser · Include Tempo Information
```

`One File per Track` is the per-track control. It is on this panel, not behind it — correcting the
earlier reading, which had seen only the file-browser half.

**The destination.** Typing a path dismisses the panel. Reproduced twice: ⇧⌘G, type, Return, and the
export panel is gone with nothing written. The first popup carries the destination (`Logic`), so the
folder must be selected through the panel's own browser (`AXOutline` / `AXRow` / `AXCell`) as an
element, and the popup re-read to confirm it changed **before** pressing Export.

**Completion.** A window titled `Logic Pro` appears immediately after Export and is gone by the time
a follow-up read arrives. It is the progress dialog, not an error. Its disappearance is the
completion signal; the Export click returning is not.

## 3. Acceptance criteria

- [ ] AC-1: `export_run artifacts:[stem]` opens the export panel through the menu, with the menu
      actually opened before any item is read or clicked.
- [ ] AC-2: The destination is selected as a browser element and the destination popup is re-read and
      confirmed changed before Export is pressed. A destination that cannot be confirmed is State C
      with `write_attempted: false`.
- [ ] AC-3: `One File per Track` is read back as the active value before Export is pressed, and a
      panel that does not offer it is State C rather than a project-level bounce wearing the word
      "stem".
- [ ] AC-4: Completion waits for the progress window to disappear, bounded; a run that never sees it
      appear and never sees it go is State B `readback_unavailable`, not success.
- [ ] AC-5: Every produced file is verified with `logic_audio.analyze_file` and its non-silent
      duration is non-zero. A stem that is silence is not a produced artifact.
- [ ] AC-6: The panel is left closed on every exit path, including refusals.

## 4. TDD spec

Unit, against the fake AX runtime:

- a closed menu whose items read `enabled=false` must not be treated as unavailable — the drive opens
  the menu first, and the test asserts the open happened before the read
- a leaf title that differs from the canonical (`1 Track as Audio File…` vs
  `Tracks as Audio Files…`) still resolves
- a destination popup whose value does not change after selection produces State C, `write_attempted:
  false`
- a progress window that never disappears within the budget produces State B, not State A
- a produced file whose analysis reports `non_silent_duration_seconds == 0` fails verification

Live, in `Scripts/livekit/`:

- one region on one track, export, one file, analyzer `status: pass`, non-silent > 0
- two populated tracks produce two files, and the count is asserted against the number of tracks with
  regions rather than against the number of tracks
- the run deletes what it produced and says so in the restoration record

## 5. The decision this ticket is blocked on

**What State does a partially successful stem run report?** Logic writes one file per populated
track. If three of four verify and one is silence, the run has produced something real and something
useless.

The two coherent answers are: State C for the whole run with every file named and the good ones left
on disk, or State A per file with a run-level summary that is not a State at all. This project's
contract does not currently have a shape for "mostly worked", and inventing one inside this ticket
would be deciding a contract question in an implementation.

Everything else here is measured and mechanical.
