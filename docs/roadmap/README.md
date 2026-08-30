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
open PRs 0 · v3.14.0 published · 16 open issues
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
| ADR-009 | #292 | OPEN | apply-back expansion on Wave-0 insert work; #299 and #301 consume it. Measured 2026-08-30, the plane it needs exists: Logic's Controls view renders a stock plug-in as an `AXTable`, one named `AXRow` per parameter, read by row label rather than index — the shape `set_param_verified` steps 9-12 already drive |
| ADR-010 | #293 | OPEN | the collector's shape was already right; measured 2026-08-29 it reads a real note table and returns both notes. It could not START in any language but English — the Event tab was matched against the literal `"Event"` — fixed in #712. What stays closed is ADR-010's body: `assessReadback` and the public provider |
| ADR-011 | #299 | OPEN | behind #292, and the reason only `threshold` is supported is now measured: the Compressor's *native* editor names 1 of its 22 sliders, so 21 have nothing to match on. Its Controls view names all of them — `Ratio`, `Attack`, `Release`, `Make Up`, `Knee`, `Circuit Type` and the rest. No write attempted |
| ADR-012 | #300 | closed | promoted and closed 2026-08-28; all seven acceptance criteria measured, four artifacts found and fixed on the way (#693-#697) |
| ADR-013 | #301 | OPEN | zero band operations registered, so no public surface — but the wall is gone. Measured 2026-08-30, Channel EQ's native view exposes all 8 bands as **24 named, settable sliders** with `AXValueDescription` in Hz/dB. The opacity claim came from a census that instantiates the AU *outside* Logic, which #306's Important Boundary says cannot speak for the live instance. The C4 Decision in the ADR body is superseded |
| ADR-014 | #302 | OPEN | R1 shipped. R2 is NOT STARTED rather than blocked: measured 2026-08-29, `kAXColumns` is present and returns 8 columns — what is absent is any title or description ON them, and the header's sort buttons carry the names the collector already binds. Next step is an R2 ticket, not another measurement |
| ADR-015 | #303 | OPEN | behind #293, and measured 2026-08-29 the dependency is narrower than "transforms must not read their own plan" — `TransformVerification` already refuses a proof that shares the observed pipeline. What is missing is a MAKER: `IndependentExpectedSeam` is inside `#if QUALIFICATION_FAULT_SEAM`, so in a release build `independentPayload` is always nil and no positive match is possible. The three modules exist; the gap is the live ingestion boundary in front of them |
| ADR-016 | #304 | OPEN | NOT STARTED. Nothing has been measured against this surface in either direction — the previous row asserted there was no obstacle, which is a claim about the world that nobody had dated |
| ADR-017 | #305 | OPEN | NOT STARTED rather than blocked. Flex Pitch is in the Audio Track Editor, not a plug-in window, so the AU-parameter-view wall recorded here was never about this surface — it was inherited, not observed. The measurement it needs is aimed at note **identity stability** over a Flex-analysed region |
| ADR-018 | #306 | OPEN | Tier B measured viable for **stock** plug-ins (the Controls view table above); the third-party plug-ins this ADR is named after are still unmeasured. measured 2026-08-30. The earlier "same wall as #305" was wrong twice: #305 is a different surface, and the wall is not there |

Also open, outside the ADR set:

| issue | state | what it is waiting on |
|---|---|---|
| #308 | OPEN | index only; closes when the ADRs it indexes do |
| #369 | OPEN | re-measured 2026-08-30: the menu path IS reachable and enabled (`파일 > 내보내기 > 모든 트랙을 오디오 파일로…`, `AXEnabled=true`, no menu opening needed). The PANEL is still unmeasured, and no caller exists for a three-level menu path. The first reading of this was taken under a Logic modal that disables the whole File menu and was discarded |
| #373 | OPEN | Phase B needs live readback; `logic://tracks` is cache-served, so a stale read passes the same equality check |
| #448 | OPEN | layout readback is deliverable; colour and reorder need a definition of "verified" for a write nothing can read back |
| #678 | closed | the drift guard and this file's update rule shipped in #684 |
| #683 | OPEN | external report — MCU feedback from Logic Pro Creator Studio wedges the loop; four hypotheses refuted or weakened by measurement, blocked on a `sample` from the reporter's host |
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
  names all 24 band sliders and every one is settable. The registry was empty because nobody had
  written the operations, which is the ordinary reason a registry is empty.
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
6. **#291, #301, #305, #306, #369, #448** — each starts with a measurement. Four were made on
   2026-08-30 and three of the four moved the item rather than confirming it: #301's wall does not
   exist, #305's wall was never about its own surface, and #306's Tier B works for stock plug-ins.
   The one that held is the Compressor's native editor, which names one slider of twenty-two — and
   that is an *identity* wall, not a reachability one, which is a different repair.
7. **#373 → #284's `R-SEM`**, then **#308** closes as an index.

## What this file does not claim

It does not claim any of the above is verified live. Issue state here is a transcription of GitHub
at the measured date, and the "waiting on" column is transcribed from each issue's own recorded
findings. Where this file and an issue disagree, **the issue is right and this file is the one that
is wrong** — the same relationship its predecessor declared toward a file nobody could read.
