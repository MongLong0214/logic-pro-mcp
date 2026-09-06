# Roadmap — source of truth

**This file is the source of truth for what is open and what order it runs in.** It is not a mirror
of anything. Where this file and any out-of-repo document disagree, this file wins.

The structure it replaces — `roadmap-v10-r*-CONTROLLING-*.md` in `~/.hermes/controlling/`, with its
promotion receipt and append-only ledger — is **non-authoritative as of 2026-08-24**. Those files
are left in place deliberately. Deleting them would take the reason for this change with them:
the controlling copy was last modified 2026-08-10, its ledger could not be found, and the in-repo
mirror opened by disclaiming itself, so **both copies were stale and neither could be corrected
without the other**. That is the failure this file exists to end.

`roadmap-2026-08-10.md` was retained beside this file, superseded, until 2026-09-05. It is gone
now — a second roadmap in the tree is the thing this file exists to end, and the reason it
existed is written above rather than left in a file nobody reads. Git has it if it is wanted.

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

## State — measured 2026-09-05 at `793fdaa7`

```
v3.15.0 published · ADR-019 landed · 20 open issues, 1 closing with this change
```

| ADR | issue | state | what it is waiting on |
|---|---|---|---|
| ADR-001 | #284 | OPEN | 6 of 7 LPMCP-PRD-001 contracts open, and the `R-SEM` split is stale in its total. It accounts for 109 operations — 23 read-only (15 already pass) / 49 mutating awaiting a write-and-readback qualification mode that does not exist / 37 mutating with a waiver route — while `OperationRegistry` today declares 113 dotted operation ids, each with exactly one spec row and each present in the allow table (count them: `case … = "…"` rows whose id contains a dot). The read-only figure is still exactly 23, so the four additions are all mutating; the 49/37 sub-split is not derivable from the registry and needs recomputing against the qualification profile |
| ADR-002 | #285 | closed | |
| ADR-003 | #286 | closed | |
| ADR-004 | #287 | closed | |
| ADR-005 | #288 | closed | |
| ADR-006 | #289 | closed | shipped #674/#675, measured and closed |
| ADR-007 | #290 | closed | all seven criteria met and measured; closed 2026-08-30. Criterion 1 was narrowed to Desktop by the owner — Creator left product scope on 2026-07-17, so the line predated the decision |
| ADR-008 | #291 | OPEN | node identity was decided and shipped in PR #740, and the destination read that blocked every edge is fixed. **Node identity works** — reading `logic://tracks` issues `trk_` references and nodes go 0 → 3. **The destination read was never unimplemented**: the model has carried `input` and `output` since it was written, the readers were wired, and `outputSlotHelpKeyword` / `inputSlotHelpKeyword` carried `variants: []`, so `output slot` and `input slot` were the only strings either could match. With the ko-KR renderings measured 2026-09-04 the same project goes `with_input` 0 → 1 and `with_output` 0 → 3, and both `#291` harnesses run clean (13/13 and 9/9) — they could not run at all before, for three reasons of their own filed as #767. Ruled out on the way rather than assumed: the depth-4 search radius (4 of 12 layout items reach an output slot, and depth 8 finds no more) and Korean normalisation (the live help is NFC). What remains open is the rest of the graph — sends name no destination in either language, which is a property of the surface, and the edge half beyond slots |
| ADR-009 | #292 | OPEN | **Controls view cannot reach this ADR's own acceptance criterion, and that is now measured rather than pending.** The criterion is 3 stock plug-ins or 10 parameters; `set_param_verified` supports one, Threshold, through the Controls-view CHECKBOX path. Both routes to widen it are walls: sliders (`sliderNotActuable`, 2026-09-02 — AXValue set and AXIncrement both report success and the slider does not move) and popups (2026-09-04 — `AXShowMenu` opens the menu, but `Circuit Type`/`Distortion`/`Mode` expose only the current choice plus one untitled disabled item, and `Auto Gain` exposes three enabled items ALL titled `-12 dB`, so no selection can be requested by name; polled to settle, not read once). Reading is unaffected — every popup reports its label and current value. What this needs is a decision on what the ADR promises, not more effort against the same surface |
| ADR-010 | #293 | OPEN | the collector reads correctly and a release build cannot enter it. Re-measured 2026-09-04 against a region written by `record_sequence`: both notes came back with the right pitch, velocity, channel and position, so the reading half is settled. The closed half is sharper than "the public provider" — `collect` takes a `RegistryResolvedIdentityProof`, and the only construction of that type sits inside `#if QUALIFICATION_FAULT_SEAM`, which `Package.swift` scopes to debug. The shipped binary exports no mint, so nothing can build the argument; nothing registers the provider either. `--probe-event-list` walks the same read path from the hashed artifact for observation only. It could not START outside English until #712 fixed the `"Event"` tab literal; `Status` is localised too (`노트`), and no literal comparison on it exists today |
| ADR-011 | #299 | OPEN | behind #292, and the 22-sliders-and-1-name census is now explained rather than restated. Native editor, measured 2026-08-30: 22 sliders (11 settable) on one Compressor instance and 20 (10 settable) on another, naming exactly one parameter (`Threshold`). Read attribute by attribute 2026-09-04, the other 21 are not anonymous by accident — every slider is described `슬라이더` and carries only a number, while the parameter NAMES are the value of separate `AXTextField`s (`THRESHOLD`, `MIX`, `OUTPUT GAIN`) and several settings live in button titles (`ON`, `0 dB`, `AUTO`). So every value and every name is readable and nothing in the elements says which belongs to which; pairing them means pairing by AX order or position, which this repository refuses everywhere. **That is a wall for verified writes, not a gap in the census.** Writes HAVE been attempted on the Controls view and both non-checkbox roles are walls too: AXSlider value and increment each reported success on 2026-09-02 and moved nothing, and the popups open but expose only the current choice or identically-titled options. The checkbox path is the one that works |
| ADR-012 | #300 | closed | promoted and closed 2026-08-28; all seven acceptance criteria measured, four artifacts found and fixed on the way (#693-#697) |
| ADR-013 | #301 | closed | shipped 2026-08-31 — `plugins.set_eq_band_verified` registers all 24 named band parameters and reaches State A live. The recorded wall was not where it was said to be: Channel EQ's native view exposes 8 named band enables and 26 `AXSlider`s, and the opacity claim came from a census that instantiates the AU *outside* Logic, which ADR-018's Important Boundary says cannot speak for the live instance. The write is a walk, not a set — the sliders expose only `AXIncrement`/`AXDecrement`, and a direct `AXUIElementSetAttributeValue` returns success while landing a different value. Original wording: Measured 2026-08-30, the recorded wall is not where it was said to be: Channel EQ's native view exposes 8 named band enables and 26 `AXSlider`s, including all 24 named band parameters; every slider reports `settable=yes` and carries `AXValueDescription` in Hz/dB. **No write was attempted, and AX settability lies** — what is established is that the controls are addressable and readable. The opacity claim came from a census that instantiates the AU *outside* Logic, which ADR-018's Important Boundary says cannot speak for the live instance. The ADR's C4 Decision was revised on the issue the same day |
| ADR-014 | #302 | OPEN | R1 shipped. R2 is NOT STARTED rather than blocked, and the two statements of why were both wrong. Re-measured 2026-09-04 on the live Event List: `AXColumns` IS present and resolves — status 0, **6** columns, not the 8 this row claimed and not the absent the issue header still claims. What is missing is identity ON them: every column's `AXTitle` and `AXDescription` is empty, and the names live on the `AXHeader` sort buttons (`L`, `M`, `위치`, `이름`, `트랙`, `길이`) — which is the route `EventListReadbackCollector.sortButtonTitles` already takes. So column identity is available, just not from the columns. Next step is an R2 ticket |
| ADR-015 | #303 | OPEN | behind #293. The stated blocker was CHECKED rather than taken on trust and it holds: `IndependentExpectedSeam` sits inside `#if QUALIFICATION_FAULT_SEAM` (lines 59-121), `Package.swift` scopes that define to `.debug`, and the shipped release binary carries **zero** seam symbols — so `independentPayload` is always nil there and `verifyRegion` can only answer `incompleteCannotVerify`. A positive note match is structurally impossible in what ships. The three verification modules exist; the gap is the live ingestion boundary in front of them, which is R2 |
| ADR-016 | #304 | OPEN | the tempo map is read, and written by converging on the target rather than assuming a write lands. Bounded in three places, each measured rather than assumed: an attempt budget of 64, a wall-clock deadline, and a rollback that converges back to the initial tempo under the same deadline. Two CI-only failures came from that third clock being unpinned while a test declared which bound it measured — the deadline override now reaches the rollback. `supportedTempoRange` is integer BPM 5...999. Still open: sub-bar tempo events and Smart Tempo's analysis modes are untouched |
| ADR-017 | #305 | OPEN | NOT STARTED rather than blocked, and measured 2026-09-04 to be the same shape as ADR-015: the modules exist and nothing can reach them. `FlexPitchModel` / `FlexPitchEditGate` / `FlexPitchRefValidity` are pure logic with **one** reference outside their own directory — the feature flag's own declaration — and the flag's only reader is a test asserting it is off. So no path produces a `FlexPitchSnapshot` from a live region, and the note-identity-stability measurement this ADR needs cannot be made through the product. The correction stands: Flex Pitch is in the Audio Track Editor, so the AU-parameter-view wall was inherited, not observed. What is still unmeasured is Logic's side — an AX walk of that editor over a Flex-analysed region |
| ADR-018 | #306 | OPEN | the write that 2026-08-30 said had not been attempted was attempted 2026-09-04, and Tier B does not survive it: Controls-view popups open but expose only the current choice, and `Auto Gain` exposes three enabled items all titled `-12 dB`, so no selection is addressable by name — see ADR-009. Addressable stays weaker than viable, and for popups it is now measured NOT viable; the checkbox path is the one that works. Separately, and shared with ADR-015 and ADR-017: this ADR's four modules (`PluginCapabilityManifest`, `HostParameterGate`, `HostParameterPlane`, `ControlsViewParameterEnumerator`) each count **zero** references outside their own directory, and `adr018HostParams`'s only reader is a test asserting it is off. The third-party plug-ins this ADR is named after remain unmeasured |

Also open, outside the ADR set:

| issue | state | what it is waiting on |
|---|---|---|
| #308 | closed | closed 2026-09-05 as superseded. Its job was to index ADR implementation work; the phases above do that, with a precondition and a done-when per phase, so keeping the issue would restore the two-copies problem this file exists to end. The ADR issues it indexed stay open in their own phases. |
| #369 | closed | shipped #737 (`466dc20f`) — the drive works against a localized Logic. Seven live rounds found six independent defects, each fatal alone: English-only matching, the panel read ~1 s before it could exist, `AXURL` read as a String, the destination searching the wrong AX roles, navigation confirmed by a *change* when the panel reopens on the last destination, and a progress dialog titled `Logic<U+00A0>Pro`. Terminal State B is the design: three tracks named "Studio Grand" came out as `Studio Grand.aif`/`_1`/`_2`, names Logic assigns after the export |
| #373 | OPEN | Phase B needs live readback; `logic://tracks` is cache-served, so a stale read passes the same equality check |
| #448 | OPEN | `tracks.sort_verified` ships: it drives `Track > Sort Tracks by`, binds the verdict to the menu leaf actually pressed, and checks the effect against a complete caller-supplied order — so a sort by the wrong criterion cannot pass, and an already-sorted project stays State B because a no-op cannot prove the command ran. It refuses a collapsed stack (a scope it cannot enumerate) and a duplicate-name project (an identity it cannot key). Driven live 2026-09-03: 4 of 4 State A. Two things measured and NOT fixed here — Logic 12.3's `트랙 이름` leaf performs no operation at all while `악기 이름` and `생성일` work, all seven reading `AXEnabled = true`; and the settle witness is #757. Still open: anchor-based reorder is drag-only, and colour still needs a definition of verified for a write nothing reads back |
| #678 | closed | the drift guard and this file's update rule shipped in #684 |
| #735 | closed | legacy `MIDIPacketList` traversal walked past a value copy and killed the server (SIGBUS), reachable by anyone sending to a published port. `MIDIPacket.data` imports as a fixed 256-byte tuple, so a value copy captures one packet's storage however many the list holds; both sites now walk the ORIGINAL pointer with `unsafeSequence()` and reject rather than truncate an oversized packet. `MIDIFeedback.parse` took the list BY VALUE, so no change inside its body could have fixed it — the signature takes a pointer now. Independently confirmed by #683's reporter: 5 of 5 crashes in isolation at 40 packets per list with the defect, 0 of 8 with the fix, and 2 of 3 in-server deaths on `LogicProMCP-MIDI-In`. The live-gate rule that could not express this proof is #754; the inbound destination nothing reads is #755 |
| #736 | OPEN | external report — duplicate virtual MIDI endpoints AND MCU feedback never detected; the reporter's own measurement tied both halves to the duplicate names (killing one pair, touching nothing in Logic, produced `connected: true` for the first time in that session). PR #738 landed the ownership-conflict path (`MIDIEngine.swift:488`, `MIDIPortManager.swift:370`). Verified on main by the reporter: an owner publishes all four ports, a second instance declines rather than publishing a twin (`has_foreign_endpoint`, `endpoint_count: 2`), and the degraded instance answers State C naming the contended port. STILL UNCONFIRMED, and item 2 of the reporter's own checklist: that the surviving owner reports `mcu.connected: true`. Port publication is not feedback detection |
| #747 | closed | `project.save_as` was dead on a Korean Logic. Measured 2026-09-03: the menu item is `별도 저장…` not `다른 이름으로 저장…`; the panel is titled `저장` with radios `패키지`/`폴더`, all three compared against English literals; and Command-Shift-G opens no Go-to-Folder sheet on this build, while typing `/` opens it at once. Proven by a live save that landed the file on disk |
| #748 | closed | the title was wrong. Re-measured 2026-09-03: `logic://tracks` DOES read live, and `refresh_cache` closes the cold-cache window on the first call — the report caught the gap before the first poll. The real defect is that a collapsed track stack truncates the list while `readable` stays true: a 26-track project answered 3 rows, Logic numbering them 1, 25 and 26, and the 23 hidden tracks received no `track_ref`. `complete` is now a fact separate from `readable`, `verified_empty` requires it, and the truncated `logic://tracks/{index}` bounds say so instead of implying the project is that small. Reason code `collapsed_track_stack`, shared with #448's refusal |
| #749 | closed | a long chained-`+` string literal inside a `merging(...)` trailing closure timed out the Swift type-checker and blocked a contributor's build entirely. Two sites hoisted into a `let`; `Scripts/check-typechecker-heavy-literals.py` refuses a flat collection literal in the first unlabeled argument when one ordinary quoted-string value has 3+ concatenations. It does not cover labeled or non-first arguments, a later chain after a nested call, parenthesised pieces, or raw strings |
| #754 | closed | `is_clean` required a capture, a visual assertion and a recording of every run, so a change with no surface in Logic's UI could not earn its zeros honestly and #735's harness was rejected for having nothing to photograph. A document now DECLARES `surface="non_ui"` and earns those zeros with a counterexample control instead; an undeclared document is still judged as UI, because zero counters is also what a harness that did nothing looks like. Landed as two pull requests because `lpm-live-gate.sh` reads the rule from `origin/main`, so the rule cannot judge itself. STILL OPEN and tracked here: the gate has no way to accept a proof it did not generate — #683's reporter's 5-of-5 / 0-of-8 is stronger than the harness and remains unusable as evidence |
| #755 | closed | closed 2026-09-05. The server published `LogicProMCP-MIDI-In`, parsed everything sent to it and dropped it — `inboundMessages` had no production consumer, so a client could not tell "delivered and ignored" from "delivered and acted on". Unpublished until something reads it. `live_735_multi_packet_lists_arrive_intact.py` sent real packet lists to that endpoint and goes with it; falsifiable adoption stays at 8 because `live_755_no_inbound_destination_is_published.py` replaces it, asking CoreMIDI from a separate process and pairing the absence with a positive control — the source must still be there, or the zero is also satisfied by a server that never started. #735's traversal fix keeps its coverage in `testMIDIEngineReceivesEveryPacketAcrossMIDIPacketListCopyBoundary`, 64 packets across the value-copy boundary that crashed. |
| #757 | closed | the sort's settle witness took its first read with no delay and accepted the first pair of equal observations, so a sort landing slower than the 75 ms poll had its own PRE-sort order accepted as settled — measured 1 of 5 live drives, under load. Fixed by the fact that made it decidable: `execute` already refuses `beforeOrder == expectedOrder` as unobservable, so wherever State A is reachable the arrangement must move, and an unchanged order means 'not landed' rather than 'settled'. An expired budget now returns the unchanged order instead of `.unavailable`, because 'no observable change' is an answer and calling it unreadable would deny four successful reads |
| #742 | closed | closed 2026-09-05 as stale. It was a handoff naming branches that have since landed — `d6a2d0c9`, `8643d94f`, `ec8eb768`, `e8e40b16`, `27089818`, `14ae9c81`, `468fc906`, each verified present. Its other function, saying what is in flight, is the phases above. |
| #683 | OPEN | external report — MCU feedback from Logic Pro Creator Studio wedges the loop; four hypotheses refuted or weakened by measurement, blocked on a `sample` from the reporter's host |
| #724 | closed | |
| #726 | closed | |
| #685 | closed | fixed in this pull request — the nudge loop no longer abandons a write on one failed AX read |
| #766 | OPEN | `inferTrackType` answered `audio` for every track and now answers `unknown` when it cannot tell. The header aggregate carries identical type tokens on all 7 headers — the Input Monitoring help present on every one names an audio track and a software instrument track in the same sentence — so first-match-wins was constant and no ordering repairs it. Reading deeper was ruled out by measurement rather than left as an option: at depth 8 the three headers share 135 tokens and every unique one is the track's own name or a track-stack arrow. Live after the change: instrument, audio and drummer created back to back all report `unknown` with `requested_track_type` intact. `SemanticOracleTable` moved its per-op pin to `requested_track_type`, which really is per-op, and the four unit fixtures stopped carrying values live Logic cannot emit. Still open: where the type IS readable is the channel strip (an input slot marks audio, a MIDI effect slot marks an instrument), that read needs the Mixer revealed, and one of four strips measured was undetermined by the pair |
| #767 | closed | AppleScript `entire contents` returns an empty list, without raising, for all ten applications it was tried on here — measured 2026-09-04 at 0 for a Logic window where a manual descent finds 464 elements, and 0 for nine other applications. Ten is what was tested, not every installed application. Evidence from 2026-08-23 has a harness clean, so it is a regression and the cause is still open. The `Sources` use is GONE: `region.select_last` verified with `lastRegionInfo` (startBar then trackIndex) while selecting with a screen-coordinate script, so the correct rule only ever reported that the other had missed — it now selects from the same enumeration, and the rectangle filter that matched every track header went with it. Selecting needed more than swapping the rule: `AXSelected` is settable, returns success, and is a TOGGLE (three writes of `true` give on, off, on), `AXPress` did not select from either start tried (2-selected and 0-selected), and the enclosing `AXLayoutArea` reports `AXSelectedChildren` settable=false — so the operation empties the selection with Logic's own Deselect All (addressed by the locale-free `AXIdentifier` `deselectAll:`, unique among the Edit menu's 151 items), then writes once against a pre-state it has read back, and reports State A only when the whole selection is that one region. `#291`'s harnesses are fixed and clean. One of the two documented AX-opacity conclusions has been re-measured and corrected: the Channel EQ editor exposes 26 named `AXSlider`s over 25 distinct names, 24 of them the eight bands' parameters (manual descent finds 70 elements in the same dialog where `entire contents` returns 0), and on the one slider that was written, `AXValue` is not a setter but a one-step nudge toward the target, so a value is reached by a bounded write-then-readback loop (the other 25 were read, not written). The CONTROLS-view conclusion is unsupported rather than corrected — the 29-row table that refutes the opacity framing was measured on Compressor, a different plug-in, so the Channel EQ's own Controls view has still not been looked at with a working instrument. The readable surface is per plug-in, not a host property: ChromaVerb and the Studio Grand instrument expose zero sliders in the same session, so the spike's description was wrong about the plug-in it was named after and right about its neighbours. A guard now refuses the phrase in any string literal, with no allowlist — every one of the eleven remaining occurrences — across six files under `Sources/` and `Scripts/`, outside the guard and its test — is prose about the defect |
| #774 | OPEN | `region.move_to_playhead` snapshots and re-reads with `selectedRegionInfo`, which returns the FIRST selected region, while Logic's Move to Playhead is documented to act on the selection — so two selected regions would give an envelope that names one. What Logic's menu command actually does to a multi-region selection has NOT been observed here; the singular readback is what was read, in the code. Same root cause #767 fixed for `region.select_last`, and unlike that one this is on a reachable path (`EditDispatcher` maps it). A CODE READING only: every live run had exactly one region selected, which the harness asserts as a precondition, so nothing measured bears on it. Two earlier claims here are WITHDRAWN — that no harness drives the operation (four `live_575_*` harnesses exist and `..._reachable.py` drives it) and that it moves nothing on this host (it moves: 10/10 checks, bar 1 to 9, independent witness agreeing; the failure was an open Mixer, whose Edit menu does not carry `이동 > 재생헤드로` at all). Separately, that harness cannot produce clean evidence right now: its visual band is a fixed 500x300 window at a constant offset and misses the moved region, so `visual_failed` is 1 with every check green |
| #775 | closed | Reported: the tap Formula bumped `version` to 3.15.0 but kept the v3.14.0 `sha256`, so `brew install logic-pro-mcp` fails for everyone on the documented install path. Reproduced: the pinned hash is byte-identical to v3.14.0's universal tarball and v3.15.0 publishes a different one, both from each release's own `SHA256SUMS.txt`. Root cause is a missing check — `release-verify-formula-install-paths.sh` verifies this same file but only its install PATHS, so the one field that must move with `version` is the one nothing compared. Fixed, and `Scripts/ci-verify-formula-sha.sh` now asks the named release what it published on every build: it refuses rather than passes when it cannot ask, refuses a Formula carrying more than one hash rather than checking the first, and passes loudly on a version whose release is not tagged yet so a release-prep bump is not blocked |
| #776 | closed | closed 2026-09-05. `findRepoFile`'s source-relative fallback counted three `deletingLastPathComponent()` calls and landed on `<repo>/Sources`, probing a path that has never existed, so it could not fire at all. It walks up to the directory holding `Package.swift` now — a marker rather than a count, which is what made the bug silent. First test for that function. |
| #777 | closed | closed 2026-09-05, fixed by other work. The issue named a six-part `+` chain inside the dictionary literal passed to `merging` at `AccessibilityChannel+MIDIImport.swift:640`; `0a6f71f1` (landed for #749) hoists it into `let readbackHint` and the file now passes that binding in. **Not re-measured on Swift 6.3.3** — CI pins 6.2, so what is established is that the named cause is gone. |
| #780 | closed | The visual band was `(_CONTENTS[0] + 12, _CONTENTS[1], 500, 300)` — a constant offset and size derived from the canvas position and nothing else, so whether it contained the region it asserted about depended on zoom and scroll, which it never read. Measured 2026-09-05 on one run: the fixed band contains 39 of the region's 64 vertical points at both positions while the derived band contains all 64, so it was watching a fraction of its own subject even where it worked. Replaced by two rectangles — a canvas slice for settling, and the region's own measured frame before and after, unioned and padded — and `ax_region_select.swift` now emits whole frames in window coordinates and states which space it used. 11 of 11 checks with `visual_failed: 0`. NOT reproduced: the ko-KR run the issue reports, where both bands would have to be compared on that project |
| #778 | OPEN | Reported: on a Japanese Logic, 72 of 115 `AXLocalePolicy` label sets carry English and Korean forms but no Japanese one, so AX-backed reads fail. Same class as #768, which counts the sets whose `variants` list is empty; this one counts the sets that have variants but not that language. Not yet reproduced here |
| #773 | OPEN | Six livekit harnesses still select their window or menu by an English literal (`"Tracks" in titles`, `name ends with "Tracks"`, `name contains "Mixer"`, `menu bar item "Edit"`), which raises or finds nothing on a Logic whose arrange window is `트랙`. Not a regression: `check-livekit-ui-literals.py` already holds every site in its `KNOWN` ratchet, so new ones are refused and these are grandfathered. Split out of #767 because editing a file under `Scripts/livekit/` makes the ship gate require a passing live run of that harness, so six harnesses means six live runs with their own evidence |
| #792 | OPEN | A live harness can define a check and never call it, and nothing notices. Walking the AST of every `Scripts/livekit/*.py` finds two module-level `def`s in `live_*.py` that are referenced nowhere in their own file — `start_bar` in `live_519_region_op_on_a_localized_logic.py` and `playhead` in `live_534_goto_position.py`, the latter carrying `if False else None` under a docstring saying it reads live. `evidence.py`'s four are its public surface, called cross-file, which is why the test is whether anything imports the module rather than which directory it sits in. The third instance is what prompted the count: `same_region` was added to `live_575_move_to_playhead_reachable.py` to close a review finding, documented as the fix, and called from nowhere — a blind review of that commit approved it. Neither the ship gate nor CI can see this shape. A ratchet is the wrong instrument: a dead helper is a deletion, not a debt. The census and the command that reproduces it are in the issue |
| #793 | OPEN | The campaign proposer silently resurrects a retracted provenance claim. `markerListDeleteMenuItem` means the Marker List window's Delete; it had been backed by the ja-JP arrange-menus census, which walks the application MENU BAR, so the `削除` it saw was the Edit menu's. That was retracted 2026-09-05 with a dated ratchet entry. Running `locale-propose.py --apply` for two unrelated labels re-added the block verbatim and flipped `coverage['ja-JP']` back to `measured`; nothing failed, and the ratchet reported it as `1 item(s) closed` — inviting a tightened ceiling around a withdrawn claim. `path_contains` would prevent the match but lives INSIDE a provenance block, so it can only constrain evidence already written, and a retracted label has no block to hold it. `roles` is the only label-level filter and is too coarse: an `AXMenuItem` named `削除` is one wherever Logic puts it. Needs a label-level declaration of where evidence may come from, read by the proposer as well as the guard. NOT audited: whether other retractions have already been resurrected |
| #794 | OPEN | Live evidence can attest a binary to a commit it was not built from. `Scripts/livekit/evidence.py:1300` sets `built_from` from the WORKTREE's HEAD, not from the binary, and nothing compares the two — so a document reads `built_from: <head>, worktree_clean: true` while the artifact came from an earlier commit. Hit on 2026-09-06 by launching a harness before `swift build` finished: the run produced a document naming the new head, reported two red checks, and the code under test never ran. The `.evidence.N.json` rotation is the only reason the two runs are comparable afterwards. Cheapest fix is to refuse when any tracked `Sources/` file is newer than the binary's mtime; stronger is to embed the build commit and read it back |
| #795 | OPEN | 87 of 142 label sets have variants but no Japanese form, and a census gives STRINGS without the mapping from a label to its string — which is why #778 has moved one label at a time. The three censuses of 2026-09-05 walk the same surfaces in the same order, so stripping bracketed titles out of each row's `path` makes the skeletons comparable across locales: 1005 of 1031 rows match via `SequenceMatcher`, `arrange.menus` 617 of 617, `arrange.window` 388 of 422. Excluding the Apple menu (which carries the SYSTEM locale, not Logic's), 751 aligned pairs carry a string on both sides and 676 differ. The 34 unmatched rows all sit in the Library pane, whose tree differed between runs — 15 of them carry real strings, so that pane is a named hole in the method. Raw index alignment is unsafe: one inserted row shifts the tail and every later pair looks plausible while being wrong |
| #796 | OPEN | The campaign project's track-header count moved 4 to 6 to 7 across 2026-09-06, read from `get_regions._debug` on runs bound to successive heads. Nothing run between those heads creates tracks — the two #778 harnesses toggle a window and read regions. It already cost one false red: at `e18bcfe2` the enumeration check went red because 7 headers no longer fit the viewport where 6 had, and that coupling is now fixed. The leading suspect was the ship gate's own suite, since `MIDIEngineTests` references `.production` runtimes and the key-command channel maps 47 CC commands — but a before/after reading around a full 4427-test gate showed the count unchanged, so that hypothesis is not supported. What was not isolated is the repeated quit / language-change / reopen / Save cycle |
| #797 | OPEN | A locked screen is invisible to the live harness, and the three AX paths the repository uses disagree about it. Measured 2026-09-07 with the screen locked and Logic running as pid 3574: the direct `AXUIElement` API reports 1 window titled `Logic Pro`, System Events reports 0 windows, `CGWindowList` reports 1 window with an empty name, `evidence.logic_window()` returns None, and `_production_ax_modal_signals()` raises `_ModalReadError('AX sheet descendant search reached depth 32')`. None of those says the screen is locked, so a run fails naming a recursion guard or an empty window list. On 2026-09-06 the System Events reading was taken at face value and Logic was force-restarted on it, which changed nothing. `CGSessionCopyCurrentDictionary()['CGSSessionScreenIsLocked']` is one call and exact; the harness preflight can refuse by name before any AX read. NOT established: whether a lock is what wedged the 34-minute gate that day |
| #798 | OPEN | The documented way to regenerate `docs/locale/ui-labels.json` reformats all 2858 of its lines without changing a value. `Scripts/locale_labels.py:408` and `:419` write `indent=2`, `locale-propose.py --apply` likewise, and the file in the tree is indented with one space and round-trips through `indent=1` byte for byte. `check-locale-labels-json.py` compares PARSED objects, so nothing in CI can see the drift and it survives indefinitely. The cost is review: a campaign adding two provenance blocks plus the regeneration the file itself asks for produces a 2858-line diff those two blocks are not findable in — measured 2026-09-07 while adding an 8-line field to two labels. Either direction closes it; what keeps it closed is a test that compares BYTES, since comparing parsed objects is what let it drift |
| #768 | closed | closed 2026-09-05 by ADR-019. The ask was that an empty `variants` list be able to say whether it is a decision or a gap. All 18 such labels now declare `unmeasured` in every locale in `docs/locale/ui-labels.json`, `check-locale-labels-json.py` refuses a missing or unbacked declaration, and `RATCHETS.json` counts them so the number can only fall. They are named as gaps, not resolved. |
| #769 | closed | closed 2026-09-05. `operations_driven` counted `tools/call` only, so a harness driving the product through `resources/read` scored zero and could never satisfy `is_clean` — the clause's own docstring says it rules out a run that never touched the product. Resource reads count now, named by URI. Measured live at `a88f49e0`: `live_291_output_slot_is_read` came back 9/9 with `operations_driven: 7`, **six of them `resources/read` the old rule recorded none of** (record `2026-09-05-a-resource-only-read-was-absent-from-its-own-receipt`). The zeros #769 cites are earlier revisions of those harnesses and were not re-measured here — this revision makes one `refresh_cache` call, so the old rule would have scored it 1 and passed while its receipt named none of the reads that did the work. |

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

## Order — the phases

Numbering expresses dependency order, not a requirement to finish every preceding phase.

There is no phase for "close the index issue". #308 was that index, and these phases are what it
was indexing — each with a precondition and a done-when it never carried. Keeping both would
rebuild the two-copies problem the top of this file exists to end, so #308 closes with this change
rather than after the ADR work it tracked.

### Phase 1 — Repair the code-only foundations

Deliver accurate harness interaction accounting, working manifest discovery, and removal of an unused MIDI destination.

- **Issues it closes:** #755, #769, #776.
- **PRECONDITION:** None.
- **DONE WHEN:** Server startup no longer publishes the unconsumed inbound destination; a resource-only harness records product interaction while an idle harness still fails that requirement; source-relative manifest discovery resolves the repository-root manifest with other lookup routes unavailable. These checks require no running Logic.
- **KIND:** `code`.

### Phase 2 — Make live evidence usable across locales and viewports

Deliver harnesses that find the intended UI and observe the region they actually moved.

- **Issues it closes:** #773, #778, #780.
- **PRECONDITION:** Phase 1, so resource-only runs can produce valid interaction evidence.
- **DONE WHEN:** Every affected harness runs successfully with its English-only selectors removed; Japanese region enumeration works using measured `trackContentExplicit` and `trackContentGeneric` forms; the move harness captures the region’s measured before/after frames and detects movement across changed zoom or scroll conditions. Japanese label work remains incomplete until measured on Japanese Logic.
- **KIND:** `mixed`.

### Phase 3 — Resolve MIDI ownership and feedback failures

Deliver confirmed feedback detection by the surviving owner and a server that remains responsive under the reported MCU conditions.

- **Issues it closes:** #683, #736.
- **PRECONDITION:** None for diagnosis; repeat endpoint measurements after Phase 1 changes publication.
- **DONE WHEN:** The surviving owner reports actual MCU feedback with `mcu.connected: true`, while a second instance declines conflicting ownership. The reported hang is resolved and the affected host confirms continued protocol responses. Closure remains blocked on a sample from the wedged reporter process or an equivalent reproducer; Desktop success alone does not resolve the Creator Studio report.
- **KIND:** `mixed`.

### Phase 4 — Verify the complete region move

Deliver move-to-playhead results that account for the whole affected selection.

- **Issues it closes:** #774.
- **PRECONDITION:** Phase 2, including the repaired visual witness.
- **DONE WHEN:** A live multi-region measurement establishes what Logic’s command moves and how it treats relative positions. Verification then checks the complete affected selection and detects a partial or wrong-region result. Completion is blocked on that initial measurement; single-region success does not establish multi-region semantics.
- **KIND:** `mixed`.

### Phase 5 — Reach independent MIDI readback in release builds

Deliver a production path from resolved region identity to the existing Event List collector.

- **Issues it closes:** #293.
- **PRECONDITION:** None; the triage already establishes that the collector can read live notes.
- **DONE WHEN:** A release build constructs `RegistryResolvedIdentityProof` from resolved production identity, registers and reaches the provider through the product, and returns complete note observations for the intended region. Stale identity, wrong-region reads, and incomplete observations cannot pass; duplicate notes and timing normalization survive comparison.
- **KIND:** `mixed`.

### Phase 6 — Establish independent expected-note ingestion

Deliver R2 positive verification backed by an independently established expected sequence.

- **Issues it closes:** #302.
- **PRECONDITION:** Phase 5 provides the qualified observed-note source.
- **DONE WHEN:** A release build reaches the live-ingestion boundary and positively verifies matching notes while rejecting deliberate mismatches. Expected notes come from precommitted independent intent or a distinct observation source; copying observed notes or attaching a provenance label cannot manufacture independence. R1 fixtures and debug seams do not satisfy this phase.
- **KIND:** `mixed`.

### Phase 7 — Connect verified note transforms

Deliver Piano Roll transforms whose verification uses the production independent-note source.

- **Issues it closes:** #303.
- **PRECONDITION:** Phase 6.
- **DONE WHEN:** A transform reached through the release product takes its input notes from independent readback, produces the intended live note changes, and detects wrong-target or incorrect-note outcomes. Its own write plan cannot substitute for the independent source, and missing evidence cannot produce a positive verdict.
- **KIND:** `mixed`.

### Phase 8 — Set and qualify the stock-plugin parameter scope

Deliver a shared capability registry whose advertised operations are demonstrably reachable.

- **Issues it closes:** #292.
- **PRECONDITION:** None.
- **DONE WHEN:** The issue explicitly resolves its acceptance scope against the recorded Controls-view slider and popup failures. Every retained capability demonstrates target identity, effective actuation, and independent readback on a live instance. Any reduced scope is recorded as an evidence-backed decision; experimental entries alone do not count as expansion.
- **KIND:** `mixed`.

### Phase 9 — Complete the Compressor scope

Deliver qualified Compressor controls and an explicit outcome for the remaining auto-setting promise.

- **Issues it closes:** #299.
- **PRECONDITION:** Phase 8 establishes the shared registry’s supported contract.
- **DONE WHEN:** Additional retained parameters are qualified through that registry, and retained auto-setting behavior lands the intended settings with readback. Anonymous sliders cannot gain identity through positional pairing. Parameters or auto-setting that remain unsupported receive an explicit scope decision backed by the relevant measurement; the landed threshold control alone does not close this phase.
- **KIND:** `mixed`.

### Phase 10 — Qualify actual third-party host parameters

Deliver a measured third-party capability boundary and production access to its supported controls.

- **Issues it closes:** #306.
- **PRECONDITION:** Phase 8 before integrating verified writes; initial third-party observations may start immediately.
- **DONE WHEN:** Actual third-party instances inside Logic are measured for parameter identity, effective writes, and readback, and supported capabilities are reachable through the product. Completion remains blocked on those measurements: stock Compressor observations cannot qualify third-party plugins. Unreachable scope is closed only through an explicit measurement-backed decision.
- **KIND:** `mixed`.

### Phase 11 — Complete observable mixer and track organization

Deliver honest routing coverage, observed track types, and resolved color and anchor-movement behavior.

- **Issues it closes:** #291, #766, #448.
- **PRECONDITION:** None for observation; Phase 2 before relying on affected localized harnesses for closure.
- **DONE WHEN:** Send edges have observed destination identities, or their exclusion is explicitly settled without publishing an incomplete graph as complete. Channel-strip type readback identifies supported cases and preserves `unknown` for ambiguous strips. Color changes and anchor movement each have an observable verification contract and a successful live demonstration, or an evidence-backed scope decision. Existing slot reads and global sorting do not prove these remaining behaviors.
- **KIND:** `mixed`.

### Phase 12 — Measure and complete region-editor capabilities

Deliver a resolved scope for remaining Smart Tempo and Flex Pitch control.

- **Issues it closes:** #304, #305.
- **PRECONDITION:** None; neither editor observation depends on plugin-parameter qualification.
- **DONE WHEN:** Smart Tempo analysis controls are measured with an audio region selected, and retained analysis modes and sub-bar tempo behavior are verified. Flex Pitch is measured in the Audio Track Editor on a Flex-analyzed region; retained editing has production snapshot access, stable note identity, and independent effect verification. Flex Pitch completion remains blocked on that editor measurement. Unsupported scope requires an explicit decision based on that surface.
- **KIND:** `mixed`.

### Phase 13 — Qualify successful mutations and restoration

Deliver qualification that can prove a mutation worked and that its effects were restored.

- **Issues it closes:** #373.
- **PRECONDITION:** Phase 1 for evidence accounting. Each operation’s live recipe requires its relevant capability phase; MIDI verification recipes require Phase 6.
- **DONE WHEN:** The existing exact-binary transport performs real calls, checks independent post-state, restores or compensates, and verifies restoration. Negative controls expose stale readback and failed restoration. Disposable-project cases demonstrate final restoration. Coverage is reconciled against the current operation registry rather than inherited operation counts; refusal probes alone cannot qualify successful mutations.
- **KIND:** `mixed`.

### Phase 14 — Enforce same-artifact release qualification

Deliver release enforcement backed by evidence for the artifact actually distributed.

- **Issues it closes:** #284.
- **PRECONDITION:** None for release-workflow work. Phase 13 and evidence for the candidate’s claimed capabilities are required before enabling enforcement.
- **DONE WHEN:** Every remaining release contract is satisfied; the qualified artifact and distributed artifact have identical SHA-256 without rebuilding between qualification and publication. Current registered operations have required evidence or individually justified waivers under the existing policy. Missing, mismatched, or failing evidence prevents promotion. Completing Phase 13 alone does not satisfy the other release contracts.
- **KIND:** `mixed`.

## What can run at the same time

- Phase 1, Phase 5, Phase 8, Phase 11 observations, Phase 12, and Phase 3 diagnosis can start together. Phase 14’s repository work can also begin immediately.
- After Phase 1, Phase 2 and Phase 13’s qualification-mode work can run alongside the domain phases. Qualification recipes follow capabilities as they become available.
- The hard completion chains are **Phase 2 → Phase 4**, **Phase 5 → Phase 6 → Phase 7**, **Phase 8 → Phases 9 and 10**, and **Phase 13 → Phase 14**.
- Phases 9 and 10 may proceed together once Phase 8’s shared contract is settled. Phase 11’s three issue tracks and Phase 12’s two editor investigations can proceed independently.
- Phase 1’s endpoint changes and Phase 3’s ownership measurements must not overlap on one host. Measurements must name which publication behavior they observed.
- Concurrent live drives must not share a Logic instance: selections, active editors, Mixer visibility, and project mutations change each other’s preconditions. In particular, Phase 4 must not run alongside Phase 11’s Mixer work, and Phase 13’s restore recipes must not overlap another live mutation. Separate hosts permit parallel runs.
- Sequencing assumption: AX-only work does not require Phase 3. Any recipe that relies on MCU feedback must wait for its feedback confirmation.

## Where this plan is most likely to be wrong

1. **Readable controls may lack usable identity or actuation.** This threatens plugin expansion, routing sends, color verification, and Flex Pitch. Cheapest measurement: inspect one actual target inside Logic, attempt one reversible change, and read its effect independently. Use the specific editor and plugin; a neighboring surface cannot establish a wall.

2. **MIDI independence may remain unreachable in the shipped product.** Existing collectors and fixtures can hide a missing production connection. Cheapest measurement: drive one known region through a release build, obtain a positive match from the production boundary, then change an expected note and require a mismatch before building transforms.

3. **Host conditions may invalidate otherwise convincing evidence.** The MCU hang remains reporter-specific, while locale and active-window state have already changed outcomes. Cheapest measurements: obtain the wedged-process sample and surviving-owner feedback observation; run one affected harness in the required locale and window state before expanding the campaign.

## What this file does not claim

It does not claim any of the above is verified live. Issue state here is a transcription of GitHub
at the measured date, and the "waiting on" column is transcribed from each issue's own recorded
findings. Where this file and an issue disagree, **the issue is right and this file is the one that
is wrong** — the same relationship its predecessor declared toward a file nobody could read.
