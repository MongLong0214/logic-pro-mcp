# T1: Drive Logic's per-track audio export from the export panel

**Issue**: #369 — `export_run artifacts:[stem]` currently yields a single project-level bounce
**Priority**: P1
**Size**: M
**Status**: Not started
**Depends On**: None

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

## 5. Partial success — the contract already has this shape

An earlier revision of this ticket said the project's contract had no shape for "mostly worked" and
declared the ticket blocked on a decision. **That was wrong, and it was wrong the way this repository
spends most of its guards on**: an absence asserted without aiming the instrument at the place the
answer lives.

`ProjectExportExecutor` already carries it, and it is the executor `export_run artifacts:[stem]`
flows through:

```
Honest Contract per artifact:
  State A — bounce fired AND on-disk verification PASSED
  State B — bounce fired but the artifact could not be verified (never appeared / analyzer
            warn/fail) — success uncertain
  State C — a hard failure (open/identity/route error, or the plan was degraded for this artifact)
```

So a stem run is a list of artifacts — one per populated track — each getting its own State, each
verified on disk with `AudioAnalyzer`. That is what AC-5 already asks for, and it needs no new
contract shape.

Two things the existing machine does that a stem run should inherit rather than reinvent:

- **`fail_if_exists` is never overwritten.** An artifact the plan flagged `would_overwrite` fails
  closed rather than bouncing over a file that is already there.
- **Already-present-and-verified artifacts are skipped**, which is what makes `export_resume`
  idempotent. A stem run gets resume for free if it produces its file list the same way.

The one thing genuinely new is that the file names come from Logic, not from the plan: the panel
writes `<track name>_1.aif`, so the executor cannot pre-compute the paths it will poll for. It has to
enumerate the destination after the progress window closes and bind each file to a track by name.
That is implementation, not a contract question.
