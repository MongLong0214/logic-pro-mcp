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

## State — measured 2026-08-29 at `4ef4d3cf`

```
open PRs 0 · v3.14.0 published · 17 open issues
```

| ADR | issue | state | what it is waiting on |
|---|---|---|---|
| ADR-001 | #284 | OPEN | 6 of 7 LPMCP-PRD-001 contracts open; `R-SEM` splits 23 read-only (15 already pass) / 49 mutating awaiting a write-and-readback qualification mode that does not exist / 37 mutating with a waiver route |
| ADR-002 | #285 | closed | |
| ADR-003 | #286 | closed | |
| ADR-004 | #287 | closed | |
| ADR-005 | #288 | closed | |
| ADR-006 | #289 | closed | shipped #674/#675, measured and closed |
| ADR-007 | #290 | OPEN | scoring fixed and six selectors adopted; the diff, four baselines and cross-locale coverage shipped in #707/#708. Waiting on a **decision**, not work: wiring the diff into `--qualify` changes the attestation schema or the release gate's behaviour, and the three options are written up on the issue |
| ADR-008 | #291 | OPEN | node identity cannot be the display string — needs a decision, not an attempt |
| ADR-009 | #292 | OPEN | apply-back expansion on Wave-0 insert work; #299 and #301 consume it |
| ADR-010 | #293 | OPEN | the collector's shape was already right; measured 2026-08-29 it reads a real note table and returns both notes. It could not START in any language but English — the Event tab was matched against the literal `"Event"` — fixed in #712. What stays closed is ADR-010's body: `assessReadback` and the public provider |
| ADR-011 | #299 | OPEN | behind #292 |
| ADR-012 | #300 | closed | promoted and closed 2026-08-28; all seven acceptance criteria measured, four artifacts found and fixed on the way (#693-#697) |
| ADR-013 | #301 | OPEN | **zero band operations registered** — no public surface; the AX plane a readback needs is not exposed |
| ADR-014 | #302 | OPEN | R1 shipped. R2 is NOT STARTED rather than blocked: measured 2026-08-29, `kAXColumns` is present and returns 8 columns — what is absent is any title or description ON them, and the header's sort buttons carry the names the collector already binds. Next step is an R2 ticket, not another measurement |
| ADR-015 | #303 | OPEN | behind #293 |
| ADR-016 | #304 | OPEN | implementation; no measured AX wall in front of it |
| ADR-017 | #305 | OPEN | AU parameter view observed AX-opaque; starts with a measurement |
| ADR-018 | #306 | OPEN | same wall as #305 |

Also open, outside the ADR set:

| issue | state | what it is waiting on |
|---|---|---|
| #308 | OPEN | index only; closes when the ADRs it indexes do |
| #369 | OPEN | Export panel AX-opaque — no accessible path to per-track stems |
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
- **#301** — genuine absence. No band read or write is registered in `OperationRegistry`, which
  matches "a measured wall" rather than contradicting it.
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
2. **#290** — the scoring decision is made and the atlas is in use. `confidence` is a ratio over
   the evidence a selector actually requests, so a header slider with no `AXIdentifier` scores 1.0
   on what it does expose; six selectors resolve identity through it. What remains is not code: the
   diff runs, but nothing calls it at qualification time, and every way of wiring it touches either
   the attestation schema or what `--qualify` refuses. That choice is on the issue as A/B/C.
3. **#293 → #303** — readback before the transforms that must take their expected values from it.
   #293's collector is measured reading a live note table; what remains there is the ADR body.
4. **#302** — re-measured. `kAXColumns` resolves 8 columns and none of them carries a name, which
   is a different fact from the one recorded; the header sort buttons supply the column map and
   `readHeaders` already reads them. The next step is an R2 ticket.
5. **#292 → #299**. #300's promotion is done — the flag is removed, not defaulted on.
6. **#291, #301, #305, #306, #369, #448** — each starts with a measurement.
7. **#373 → #284's `R-SEM`**, then **#308** closes as an index.

## What this file does not claim

It does not claim any of the above is verified live. Issue state here is a transcription of GitHub
at the measured date, and the "waiting on" column is transcribed from each issue's own recorded
findings. Where this file and an issue disagree, **the issue is right and this file is the one that
is wrong** — the same relationship its predecessor declared toward a file nobody could read.
