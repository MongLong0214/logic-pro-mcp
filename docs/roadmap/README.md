# Roadmap — source of truth

**This file is the source of truth for what is open and what order it runs in.** It is not a mirror
of anything. Where this file and any out-of-repo document disagree, this file wins.

The structure it replaces — `roadmap-v10-r*-CONTROLLING-*.md` in `~/.hermes/controlling/`, with its
promotion receipt and append-only ledger — is **non-authoritative as of 2026-08-24**. Those files
are left in place deliberately. Deleting them would take the reason for this change with them:
the controlling copy was last modified 2026-08-10, its ledger could not be found, and the in-repo
mirror opened by disclaiming itself, so **both copies were stale and neither could be corrected
without the other**. That is the failure this file exists to end.

`roadmap-2026-08-10.md` is retained beside this file, superseded, for the same reason.

## The update rule

**When an issue opens or closes, the same PR updates the table below.** A roadmap that is updated
"when someone remembers" is stale within two weeks — measured, that is exactly how its predecessor
got here.

That rule is a convention, and a convention is a claim. **The check now exists**:
`Scripts/roadmap-table-matches-github.py` runs in CI and fails when this table and GitHub disagree —
either a row that was never flipped, or an open issue nobody added. It refuses (exit 2) rather than
reporting clean when it cannot tell: a `gh issue list` result that hit its own `--limit` looks
identical to a complete one, and written against `--limit 200` this check would have compared
against the newest 200 of 239 issues and passed. `Scripts/test-roadmap-table-guard.sh` drives every
one of those paths and asserts the exit codes, so the guard has been watched fail.

One exception, and it is narrow: **a pull request may mark closed the issues it says it closes.**
Without it a closing PR has no truthful row to write — open while it is open, stale the instant it
merges — and #684 hit exactly that, turning `main` red on its own merge commit. The exemption
applies only to issues named in that PR's `Closes #N`, only in the ahead direction, and not at all
on a push to `main`; a row claiming an open issue is closed still fails, and the closing PR must
still list the issue rather than delete its row.

It does not check the prose. The "waiting on" column, the order, and the state block below are still
claims dated by the "measured" line, and only issue numbers and open/closed are mechanised.

## State — measured 2026-08-30 at `709a0178`

```
open PRs 0 · v3.15.0 published · 17 open issues
```

| ADR | issue | state | what it is waiting on |
|---|---|---|---|
| ADR-001 | #284 | OPEN | 6 of 7 LPMCP-PRD-001 contracts open; `R-SEM` splits 23 read-only (15 already pass) / 49 mutating awaiting a write-and-readback qualification mode that does not exist / 37 mutating with a waiver route |
| ADR-002 | #285 | closed | |
| ADR-003 | #286 | closed | |
| ADR-004 | #287 | closed | |
| ADR-005 | #288 | closed | |
| ADR-006 | #289 | closed | shipped #674/#675, measured and closed |
| ADR-007 | #290 | closed | all seven criteria met and measured; closed 2026-08-30. Criterion 1 was narrowed to Desktop by the owner — Creator left product scope on 2026-07-17, so the line predated the decision |
| ADR-008 | #291 | OPEN | node identity cannot be the display string — needs a decision, not an attempt |
| ADR-009 | #292 | OPEN | apply-back expansion on Wave-0 insert work; #299 and #301 consume it. Measured 2026-08-30: Logic's Controls view renders a stock plug-in as an `AXTable`, one `AXRow` per parameter whose cell carries an `AXStaticText` label and a control. **Addressable, not yet written to.** It is NOT the shape `set_param_verified` drives — step 9 matches an `AXSlider` by its own `AXDescription`, and in this view the sliders have none; the name is on a sibling. A locator for row-labelled controls is new work |
| ADR-010 | #293 | OPEN | the collector's shape was already right; measured 2026-08-29 it reads a real note table and returns both notes. It could not START in any language but English — the Event tab was matched against the literal `"Event"` — fixed in #712. What stays closed is ADR-010's body: `assessReadback` and the public provider |
| ADR-011 | #299 | OPEN | behind #292. Measured 2026-08-30: the Compressor's *native* editor exposes 22 sliders (11 settable) on one instance and 20 (10 settable) on another, and names exactly one (`Threshold`) on both; that is also the one parameter `set_param_verified` supports — consistent with step 9 matching on `AXDescription`, though the causal link is inferred from the code path rather than measured. Its Controls view carries a labelled row per parameter (`Ratio`, `Attack`, `Release`, `Make Up`, `Knee`, `Circuit Type`, …). No write attempted anywhere |
| ADR-012 | #300 | closed | promoted and closed 2026-08-28; all seven acceptance criteria measured, four artifacts found and fixed on the way (#693-#697) |
| ADR-013 | #301 | closed | shipped 2026-08-31 — `plugins.set_eq_band_verified` registers all 24 named band parameters and reaches State A live. The recorded wall was not where it was said to be: Channel EQ's native view exposes 8 named band enables and 26 `AXSlider`s, and the opacity claim came from a census that instantiates the AU *outside* Logic, which ADR-018's Important Boundary says cannot speak for the live instance. The write is a walk, not a set — the sliders expose only `AXIncrement`/`AXDecrement`, and a direct `AXUIElementSetAttributeValue` returns success while landing a different value. Original wording: Measured 2026-08-30, the recorded wall is not where it was said to be: Channel EQ's native view exposes 8 named band enables and 26 `AXSlider`s, including all 24 named band parameters; every slider reports `settable=yes` and carries `AXValueDescription` in Hz/dB. **No write was attempted, and AX settability lies** — what is established is that the controls are addressable and readable. The opacity claim came from a census that instantiates the AU *outside* Logic, which ADR-018's Important Boundary says cannot speak for the live instance. The ADR's C4 Decision was revised on the issue the same day |
| ADR-014 | #302 | OPEN | R1 shipped. R2 is NOT STARTED rather than blocked: measured 2026-08-29, `kAXColumns` is present and returns 8 columns — what is absent is any title or description ON them, and the header's sort buttons carry the names the collector already binds. Next step is an R2 ticket, not another measurement |
| ADR-015 | #303 | OPEN | behind #293, and measured 2026-08-29 the dependency is narrower than "transforms must not read their own plan" — `TransformVerification` already refuses a proof that shares the observed pipeline. What is missing is a MAKER: `IndependentExpectedSeam` is inside `#if QUALIFICATION_FAULT_SEAM`, so in a release build `independentPayload` is always nil and no positive match is possible. The three modules exist; the gap is the live ingestion boundary in front of them |
| ADR-016 | #304 | OPEN | NOT STARTED. Nothing has been measured against this surface in either direction — the previous row asserted there was no obstacle, which is a claim about the world that nobody had dated |
| ADR-017 | #305 | OPEN | NOT STARTED rather than blocked. Flex Pitch is in the Audio Track Editor, not a plug-in window, so the AU-parameter-view wall recorded here was never about this surface — it was inherited, not observed. The measurement it needs is aimed at note **identity stability** over a Flex-analysed region |
| ADR-018 | #306 | OPEN | measured 2026-08-30: Tier B is **addressable** for stock plug-ins — the Controls view table above — which is weaker than "viable"; no write or readback was attempted, so viability is not established. The third-party plug-ins this ADR is named after are unmeasured. The earlier "same wall as #305" was wrong on the surface: #305 is a plug-in-window claim attached to a region editor |

Also open, outside the ADR set:

| issue | state | what it is waiting on |
|---|---|---|
| #308 | OPEN | index only; closes when the ADRs it indexes do |
| #369 | closed | shipped #737 (`466dc20f`) — the drive works against a localized Logic. Seven live rounds found six independent defects, each fatal alone: English-only matching, the panel read ~1 s before it could exist, `AXURL` read as a String, the destination searching the wrong AX roles, navigation confirmed by a *change* when the panel reopens on the last destination, and a progress dialog titled `Logic<U+00A0>Pro`. Terminal State B is the design: three tracks named "Studio Grand" came out as `Studio Grand.aif`/`_1`/`_2`, names Logic assigns after the export |
| #373 | OPEN | Phase B needs live readback; `logic://tracks` is cache-served, so a stale read passes the same equality check |
| #448 | OPEN | layout readback is deliverable; colour and reorder need a definition of "verified" for a write nothing can read back |
| #678 | closed | the drift guard and this file's update rule shipped in #684 |
| #735 | OPEN | legacy `MIDIPacketList` traversal walked past a value copy (SIGBUS). Fixed on `fix/735-midi-packetlist`; measured 2026-09-02 the parsed inbound stream has NO production consumer, so `LogicProMCP-MIDI-In` accepts MIDI and discards it — decide whether to finish that port or stop publishing it. The live gate cannot express this proof: `is_clean` requires captures/visual/recordings and this is a non-UI path with nothing in Logic to observe |
| #736 | OPEN | external report — duplicate virtual MIDI endpoints AND MCU feedback never detected; the reporter's own measurement tied both halves to the duplicate names (killing one pair, touching nothing in Logic, produced `connected: true` for the first time in that session). PR #738 landed the ownership-conflict path (`MIDIEngine.swift:488`, `MIDIPortManager.swift:370`). Verified on main by the reporter: an owner publishes all four ports, a second instance declines rather than publishing a twin (`has_foreign_endpoint`, `endpoint_count: 2`), and the degraded instance answers State C naming the contended port. STILL UNCONFIRMED, and item 2 of the reporter's own checklist: that the surviving owner reports `mcu.connected: true`. Port publication is not feedback detection |
| #747 | closed | `project.save_as` was dead on a Korean Logic. Measured 2026-09-03: the menu item is `별도 저장…` not `다른 이름으로 저장…`; the panel is titled `저장` with radios `패키지`/`폴더`, all three compared against English literals; and Command-Shift-G opens no Go-to-Folder sheet on this build, while typing `/` opens it at once. Proven by a live save that landed the file on disk |
| #748 | OPEN | `logic://tracks` never reads live here — `poll_mode idle`, `project ""`, `track_count 0` — on both the long-lived fixture and a fresh saved project, while `tracks.create_audio` and `tracks.select` read the same tracks fine. No caller can obtain a `trk_` reference, which is why #448's verified sort has never been driven live |
| #749 | OPEN | a long chained-`+` string literal inside a `merging(...)` trailing closure timed out the Swift type-checker and blocked a contributor's build entirely. Two sites hoisted and a guard added on `fix/749-typecheck-timeout`; closes when that lands |
| #754 | OPEN | `is_clean`'s non-vacuity clauses require captures, visual assertions and a claimed mutation, which a change with no surface in Logic's UI cannot earn honestly. Split out of #735, whose harness drives the real CoreMIDI callback and is rejected for having nothing to photograph. Wants a declared non-UI class whose zeros are still earned, by a counterexample control rather than by waiver |
| #755 | OPEN | the server publishes `LogicProMCP-MIDI-In`, parses everything sent to it, and drops it — `inboundMessages` has no production consumer. Either give it one or stop publishing the destination; a silent discard is the worst of the three states. Split out of #735 |
| #742 | OPEN | a handoff for whoever picks up the open issues next: where main is, which branches carry unmerged work, the one confirmed live-gate failure and its trace, and the corrections made publicly so they are not re-inherited. Closes when the work it hands off is picked up |
| #683 | OPEN | external report — MCU feedback from Logic Pro Creator Studio wedges the loop; four hypotheses refuted or weakened by measurement, blocked on a `sample` from the reporter's host |
| #724 | closed | |
| #726 | closed | |
| #685 | closed | fixed in this pull request — the nudge loop no longer abandons a write on one failed AX read |

### Three reopen reasons, checked rather than inferred

The instruction that produced this file asked for these to be established, not guessed:

- **#293** — not absence. `Sources/LogicProMCP/MIDIReadback/` has ten modules including the
  provider. The recorded problem is that the fixture gave every Event-List cell a child, so the
  collector was written against a shape Logic does not produce.
- **#301** — genuine absence of the *operations*: no band read or write is registered in
  `OperationRegistry`. What was inferred from that was wrong. The note read the absence as
  consistent with "a measured wall", and consistency is not evidence — an unbuilt feature and a
  blocked one look identical from the registry. Measured 2026-08-30 there is no wall: Channel EQ
  exposes 26 sliders, including all 24 named band parameters, and every slider is settable. The
  registry was empty because nobody had written the operations, which is the ordinary reason a
  registry is empty.
- **#300** — neither, and it is closed now. Four modules existed *and* two operations were
  registered; what was open was the promotion decision. Answering it took measuring what the flag
  was holding back, which turned up four artifacts nobody had recorded: three bands reporting the
  floor as a reading, an accumulator band drawing a cut at 20 Hz on material with nothing wrong
  there, a loudness gate published under the name `confidence`, and that same accumulator still
  reaching `frequency_peaks` after the first three were fixed. Promotion was the decision; the
  measurement was the work.

## Order

The order below is derived from dependency, not from priority. Where an item is behind a wall, the
next step is a measurement and the honest outcome may be a scope decision with that measurement
attached — not a silent deferral.

1. **#284** — the release gate. Five of its six open contracts are `release.yml` requirements, so
   most of it is repo-side work rather than live work. `R-SEM` is the large one, and measuring it
   on 2026-08-24 moved its blocker: the 49 mutating operations with a verification plan are waiting
   on a write-and-readback qualification mode that does not exist, which the #284 matrix does not
   supply. #373 covers a smaller part of it than "depends on #373" suggested.
2. ~~**#290**~~ — closed 2026-08-30. The diff runs at qualification time as a case and a refusal
   rejects a promotion; five baselines cover en and ko and leave no adopted selector unmeasured.
   The English control bar earned its keep on capture, exposing a prefix match that let the
   transport's Record button read as a track's arm toggle — invisible in Korean, where `녹음` is
   not a prefix of `녹음 활성화`.
3. **#293 → #303** — readback before the transforms that must take their expected values from it.
   #293's collector is measured reading a live note table; what remains there is the ADR body.
4. **#302** — re-measured. `kAXColumns` resolves 8 columns and none of them carries a name, which
   is a different fact from the one recorded; the header sort buttons supply the column map and
   `readHeaders` already reads them. The next step is an R2 ticket.
5. **#292 → #299**. #300's promotion is done — the flag is removed, not defaulted on.
6. **#291, #301, #305, #306, #369, #448** — each starts with a measurement or a decision.
   Measurements on 2026-08-30 covered #301, #306 and #369, and each moved its item rather than
   confirming it: Channel EQ's controls are addressable, the Controls view carries a labelled row
   per parameter, and the export menu path is reachable and enabled. **None of the three involved a
   write**, so each establishes reachability and not verified control. #305 moved for a different
   reason — its blocker named a plug-in window and Flex Pitch is a region editor, so it was never a
   measurement about that surface, and one still has not been made. #291 and #448 turned out to
   need decisions rather than measurements, and both were made and recorded on their issues. The
   limit that held is the Compressor's native editor naming one slider on each measured instance
   (of twenty-two on one and twenty on the other): an *identity* limit rather than a reachability
   one, and a different repair.
7. **#373 → #284's `R-SEM`**, then **#308** closes as an index.

## What this file does not claim

It does not claim any of the above is verified live. Issue state here is a transcription of GitHub
at the measured date, and the "waiting on" column is transcribed from each issue's own recorded
findings. Where this file and an issue disagree, **the issue is right and this file is the one that
is wrong** — the same relationship its predecessor declared toward a file nobody could read.
