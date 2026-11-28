# Roadmap — source of truth

**This file records what is open, what each open issue needs to be resolved at the root, and the
order to work in.** The ADR programme's scheduling entry is [#308](https://github.com/MongLong0214/logic-pro-mcp/issues/308)
(START HERE), and each owning issue's body is that work's acceptance contract. Where this file and
an issue disagree, the issue is right.

The 2026-11-23 text (fourteen phases, twelve batches, hour forecasts, per-issue classification) is
replaced, not appended: main moved 136 commits since v3.19.0 and most of its rows were out of date.
Git has it (`git show 2eacb5d6:docs/roadmap/README.md`).

**Update rule.** Update this file in the pull request that changes an issue's delivery state. The
roadmap is a dated readback, not a CI policy surface. It measures nothing: Logic behaviour quoted
below comes from the linked issues and from `docs/qualification/not-qualified-logic13.json`.

## State — read 2026-11-28 at `main` `a2f127d6`

```
45 open issues · 1 open pull request (#1625, passed native, about to merge) · latest stable release v3.19.0 (2026-11-18) · source version 3.19.0
```

**Not in v3.19.0.** Everything below marked "on main" reaches users only with the next release; until
then a reporter needs a build of main.

- **Merged since the 2026-11-23 state, product:** #1619 (`insert_plugin` appends to the next free
  slot and covers every measured stock Audio FX, #1618), #1622 (a timeout after a write is State B
  unknown outcome and names the likely cause, refs #1565), #1623 (Logic 13 track type in
  `record_sequence`), #1630 (no "emergency fallback" line on packaged installs, fixes #1627), #1561
  (export finds the volume sidebar structurally; **sidebar step only, List view still fails**, see
  #1553), #1590 (one place in the Swift names the Logic release; ko-KR label census of Logic 13.0 (7801)), #1624
  (qualification judges each operation against the settled baseline, #1594 M6), and earlier
  #1608/#1609 (read-only sample source preparation) and #1566 (poller cost bound, #668).
- **Open pull request:** #1625 (R3-01: transport, marker and bar cycles restore the exact playhead and
  the control-bar display mode). **#1597 (the #1596 permission fix) was closed unmerged on
  2026-11-23**; its branch `fix/1596-postevent-tcc` (`2e030d36`) is not on main, so #1596 is not fixed.
- **Qualification on Logic 13.0 (7801):** 17 of 138 registered operations are live-qualified; the other
  121 are listed with a reason in `docs/qualification/not-qualified-logic13.json` (69
  `unknown_param_probe_only`, 21 `readback_not_compared`, 9 `recipe_refused`, 8
  `semantic_validator_unavailable`, and 14 in seven smaller classes). Nothing on that list is claimed.
- **New product limitation:** `transport.pause` refuses with `readback_unavailable` when the control
  bar displays Beats, because tempo is not readable there. Recorded on #1621; it is a second defect in
  that issue, no separate issue exists.
- **Release:** v3.19.0 is unsigned (`signing: unsigned`); the signature wording in #284 and #816
  describes scope the release does not have.

### CI as it is now

Owned by the CTO and handled autonomously; listed so the plan's cost model is true.

- The native qualification result handshake is fixed (#1628): it waits on pending, ignores other
  attempts and never turns a passed qualification into a failure. Native runs only the live tests on
  the Logic host and no longer re-runs the general suite (#1629): **about 11 min instead of about 79**.
  The native wait can be cancelled (#1632) and a native-only rerun reuses the earlier attempt's
  release artifact (#1634).
- Tests are dealt into four shards and offline guards left the build path (#1635). Synthetic runtimes
  read outputs without the 1.5 s popup wait (#1633).
- An incremental test-build cache restores `.build` and source mtimes and is keyed on the SDK and
  Command Line Tools version (#1636, #1637). It hits on GitHub but **saved nothing on a pull request
  that changed product sources**, because the whole test module recompiles. **The test-build is still
  about 33 min** and is now the longest step. No issue tracks it.

### What can and cannot be measured here

The host runs Logic Pro 13.0 (7801) on macOS 26.3; other locales are measured by switching. It cannot
run Logic 12.x, Creator Studio or macOS 27, so reports from those cannot be reproduced locally. They
are answered from the reporter's data and re-measured on 13.0 wherever the code path is shared, and
none is closed as unreproducible. Standing rules: every implementation gets tight live proof on real
Logic, ten locales are the default scope, one Logic session at a time, nothing is closed as impossible.

## Next 10

Real users on current Logic 13 first, then external reports we can act on. Epic slices follow in Waves
2 to 5.

1. **#1596** — A reporter on Logic 13 and macOS 27.2.1 waits for a build; the fix exists on a branch,
   needs no Logic, and without it nothing works from Claude Desktop. S.
2. **#1600** — `tracks.select` does not select on Logic 13, confirmed on a second machine; root of #1598 and #1599.
3. **#1598** — Mute and solo refuse on any unselected track; follows #1600 directly.
4. **#1599** — Rename fails and reports `success: true` with `isError: true`; the envelope is fixable now.
5. **#1621** — Stop does not stop on Logic 13, 3 of 3 trials; pause refuses in Beats.
6. **#1601** — goto never verifies and costs 2 to 10 s; #1625's exact playhead read supplies the readback.
7. **#1603** — An agent's first `logic://tracks` read sees zero tracks.
8. **#1553** — The reporter measured the exact ancestor chain; sidebar merged, List view still refuses.
9. **#1565** — Reporters hit en-US timeouts on every live read; the fix is on main and needs their retest and our en-US proof.
10. **#1618** — The most common first workflow, a vocal chain; send-to-bus and any-slot parameters remain.

## Plan to resolve all 45

Sizes: **S** hours, **M** about a day, **L** several days, **XL** a programme of its own. "Resolved at
the root" is the end state the owning issue's body would accept, not that a pull request merged. No row
closes an issue; the owner closes each one after the evidence it names exists. Logic time, not code,
orders the waves, since there is one session at a time; Wave 0 needs almost none and runs beside Wave 1.

### Wave 0 — Settle what main or the release already fixed (6)

| issue | resolved at the root means | first step | depends on | size |
|---|---|---|---|---|
| #1552 | `logic://project/info` sampleRate is the saved project rate. Shipped in 3.19.0 (#1558); the reporter's Logic 13 run reads 48000 from `project_file` and `ax_live`. | Put the scope in the close-out: Logic 12.4 was not rerun; reopen on a 12.4 repro. The reporter's 7-day window ended 2026-11-27. | reporter silent; Logic 12.4 cannot be run here | S |
| #1550 | `resolve_path` never waits behind unrelated AX reads. Shipped in 3.19.0 (#1560); on Logic 13 every resolve was at or below 24 ms. | Same close-out sentence as #1552; the 12.4 long wait is the one case not rerun. | reporter silent; Logic 12.4 | S |
| #1585 | The reporter's Logic 13.0 on macOS 27.2 reports ready in `doctor`. `AXWindow: 0` was the census counting descendants only, and 13.0 is validated since 3.19.0. | Wait for the retest asked on 2026-11-20 (`brew upgrade`, `doctor --json --profile core`); if still `not_ready`, the redacted output names the group. | reporter on macOS 27.2 | S |
| #1626 | On Logic 12.4 `goto_bar` and `toggle_view` work, or the 3.19.0 envelope's `frontmost_observation.reason` names the cause and that is fixed. The envelope has the 3.18.0 shape, so probably not a 3.19.0 regression. | Wait for the three answers asked on 2026-11-27 (health version, `.mcp.json` command, restart). Meanwhile on the host: show the stricter 3.19.0 frontmost check (layer-8 panel, unreadable owner, focused-app mismatch) passes with Logic frontmost. | reporter's reply; Logic 12.4 cannot be run | S |
| #1565 | On Logic 13 en-US no read hangs for the rest of the process after two reads, and a timeout after a write is State B unknown outcome naming the cause (Browser open, Logic off the current Space, saturated main thread). On main in #1622, which only refs the issue. | Ask jasonwallis777 and ryanhellerud1 to repeat their read-only probes on a build of main, not 3.19.0. Ours: reads 3 and 10 succeed after two hung reads, with the Browser open and with Logic off-Space, in en-US. | reporters; one en-US session | M |
| #668 | `refresh_cache` completes inside its deadline with all four sections on a project with about 74 AX-visible rows. #1566 took a 165-track tutorial from 24.6 s then a timeout to 7.7 to 11.7 s, but that fixture exposes only 11 rows. | Open a copy of the preserved project whose metadata says 74 tracks, count the AX-visible rows (expand track stacks), run refresh repeatedly. | live Logic, one run | S |

### Wave 1 — Defects users hit on Logic 13 now (12)

One root explains four of them: on Logic 13 a changing track write acts only on the selected track, and
selection itself does not take. Fix **#1600** first and #1598, #1599 reduce to replays; #1604 and #1605
are the same family (focus left by an earlier click).

| issue | resolved at the root means | first step | depends on | size |
|---|---|---|---|---|
| #1596 | The permission report and doctor name the process macOS checks; `LogicProMCP --request-permissions` makes macOS list that binary; docs say grant the binary, not Claude. Both reporters (Logic 12.3 on macOS 27.2, Logic 13.0 on macOS 27.2.1) get Accessibility and PostEvent. | Rebase `fix/1596-postevent-tcc` on main and open the pull request; check the disclaimed launch with a launcher that disclaims responsibility on this host. | none for code, no Logic; reporters confirm on macOS 27, which this host cannot run | S |
| #1600 | `tracks.select` puts the requested row under selection and reads it back (State A), also after a Track Stack is expanded and collapsed; where it cannot, State C with the cause. Never State B with `success: true` and `observed: null`. | Reproduce on a clean fixture with saved logs (the demo saved none), then find which rung of the AX selection ladder (`AccessibilityChannel+Tracks.swift`) reports success without selecting. Add the second reporter's case: with stacks, row 6 lands on row 5. | live Logic 13 | M |
| #1598 | Mute and solo apply to any track and read back; a refusal names the real cause, never "No keyboard shortcut mapped". | After #1600, replay the repro and log why the AX channel declined; make that the refusal text and stop the fall to a key command with no mapping. | #1600 | M |
| #1599 | Rename works by index and by `target_ref` with the name read back; State B never carries `success: true` with `isError: true` when the name did not change. | Write the failing test for the contradicting envelope now (offline); the select-before-rename failure goes with #1600. | #1600 for the live half | M |
| #1604 | The refusal names the focused name field and how to clear it (Escape, or click an empty area), checked on Logic 13. The refusal itself is right and stays. | Edit the hint, add one test, one live run showing Escape clears the focus. | none | S |
| #1605 | The native preflight sets Tracks-list focus itself or says what to do, or is shown not to need it. Observation only; no reproduction without the demo's outside automation. | Reproduce: click the arrange area and rename tracks as the demo did, then run the preflight. If it reproduces, the preflight is CI-owned; hand it to the CTO. | live Logic; #1604 same family | S |
| #1603 | The first `logic://tracks` read in a new process returns the tracks or a marker that tells the client to retry; never `data: []` as an answer. | Make the first read wait, bounded, for the first poll; test with a fake poller; time it on Logic 13. | related to #1565 poller | M |
| #1621 | `transport.stop` stops playback and reads `isPlaying` false on Logic 13 in all ten locales; pause and play work in every control-bar display mode or the refusal names the mode. Two defects: stop presses the only control, the Play checkbox, and playback restarts at the start; pause refuses in Beats because tempo is unreadable. | Live: read the Play checkbox's value before and after the press and compare with the Space-key control that stopped playback within 1.5 s. For Beats, take tempo from the Tempo List (#304's reader) or name the mode; measure Time, Beats & Time and Custom. | #1625 merged (display-mode restore); live Logic | M |
| #1601 | `goto_bar` and `transport.goto_position` return State A when the exact four-component position reads back, with no dialog route where a faster verified one exists. Today the dialog reads bar and beat only, so State B forever. | Use #1625's exact playhead read in Beats as the after-read and compare it to the request. Share one timing pass with #1606 and #1600. | #1625 merged; live Logic | M |
| #1602 | Every write family handles an open blocking dialog alike; the System Overload alert is its own named error; mixer writes refuse while it is open (they report State A today). | Offline: list write operations without the pre-write blocking-dialog check. Then provoke the alert on the host (small buffer, heavy instruments) and read its role and text to name it. | live Logic to provoke it | M |
| #1553 | `export_run` stem works with the Export panel in List and Column view on Logic 13. #1561 on main resolves the sidebar only; component selection still requires an `AXGroup`/`AXList` ancestor and refuses `stem_destination_component_group_unresolved`. | Add the List branch to `selectListedComponent` (`ProjectStemExportPanelDriver.swift`) through `AXTextField > AXCell > AXRow > AXOutline`, built from the reporter's two ancestor chains as fake-AX tests, keeping Column and every refusal; one live List and Column comparison. | live Logic, one run | M |
| #1618 | On a fresh project an agent builds EQ → DeEsser 2 → Compressor → Pitch Correction plus a ChromaVerb send, every step State A, checked in en and ko and then the other eight locales. Steps 1 and 2 are on main (#1619). | Run the chain on main to see which of step 3 (send to a bus) and step 4 (does `set_param_verified` stop at visible slots) fail; reuse an existing aux first, creation waits for #967. | #967 for creating a bus; live Logic | M |

### Wave 2 — Requested features, each starting with one measurement (9)

The recall-sheet reporter's four requests (#1417, #1430, #1571, and the read half of #884) share one
read-only path and are worth planning as one.

| issue | resolved at the root means | first step | depends on | size |
|---|---|---|---|---|
| #1606 | Fader writes are bounded by Logic, not by stepping: a direct value write or a batch with one readback, still verified. Today 0.25 to 1.3 s per write in ten-unit detents. | Timed run of 15 writes on the host that splits write, readback and actor wait (the demo's log was never saved); try a direct value write and the MCU fader against the detent route. One pass also times #1601 and #1600. | #1565's actor wait if the split shows it | M |
| #1588 | Region rename by track and region with the name read back; Chord Track write at bar and beat with read back, or the published measurement of why not. Reporter is on Logic 12.2; only 13.0 can be measured. | Region rename first (builds on region selection and track rename); census the Chord Track as a global track in parallel. | #1600 (selection); live Logic | L |
| #1417 | On Logic 13 mono Gain and Sample Delay read State A (#1424 added `phase_invert` and `delay`) and no first read after server start leaves its editor open. | Twenty first reads after server start on Logic 13, recording AXSubrole, the close-button read status and window presence, the capture asked on 2026-10-25. | live Logic; the 12.4 case cannot be run | S |
| #1430 | `get_param_verified` answers State A for the recall-sheet parameters of ChromaVerb, Space Designer, Tape Delay, Stereo Delay and Overdrive in ten locales. | Build the fixture with #1619's insert (the missing fixture no longer blocks), then dump each editor's AX tree read-only. | #1619 merged; live Logic | L |
| #299 | Every Compressor parameter reads and writes verified (threshold, `limiter_on` and `auto_release` exist). Substance overlaps #1430, #1417 and #955: one reader family. | One more parameter, ratio first, through the existing Controls-view writer. | live Logic | L |
| #1571 | `logic://mixer` reports pan mode (balance or Stereo Pan) and the spread where the tree has it, `null` with a reason where it does not. | Read-only dump of the pan knob's AXHelp and AXDescription in each mode on Logic 13; refresh the canon index for the "stereo pan" string first. | canon index; live Logic | M |
| #884 | Automation is readable per track (which parameters carry data), then volume points by position and value, then add, set and delete a point with a read back. Today only the current-playhead value is readable. | Finite measurement on Logic 13 of the sources that could hold points: the lane's parameter popup, the Event List (shared with #302), the saved project. Ship the which-parameters read first. | #302's Event List walk; live Logic | L |
| #1516 | Operations run with Logic in the background through verified MIDI key-command bindings; one qualified region command. The catalog, binding inspection and `toggle_metronome` slice are merged (#1522, #1562). | Measure whether Key Commands is reachable through Accessibility on Logic 13 (the 2026-11-23 state said it is not); the answer picks Learn through the owned MIDI port or another binding route. | live Logic 13 | L |
| #1546 | Creator Studio verified by someone who has it: attestation from `--qualify --variant creator` on a disposable project, then fixes for what it shows. The source comment that calls the variant permanently out of scope should be reworded. | Answer the reporter with the exact commands and a draft-pull-request path; check whether a #1600 reporter's "Creator Studio 13.0 (7801)" is the build number our host reports. | the reporter's Creator Studio host; macOS 27 | L |

### Wave 3 — Evidence and verifier programme (6)

#284, #1028, #1586 and #1403 are one programme seen from four sides: #1586 restates #1028 for the
current verifier, #1403 asks the same of the unattended path, and #816 is the publication half of #284.

| issue | resolved at the root means | first step | depends on | size |
|---|---|---|---|---|
| #284 | The release candidate's exact bytes pass live qualification on en-US and ko-KR (core profile), the evidence is bound to those bytes, and a release cannot publish without it. 17 of 138 operations qualify today. | Make every Wave 1 fix land with its recipe so it leaves the 121 list; then the 69 `unknown_param_probe_only` by user value. | live Logic; #1590 (version-tagged cells, merged) | XL |
| #1028 | Acceptance rows as data per ticket, a fixed verifier that judges from Apple's data, and the label census in ten locales. #1590 measured ko-KR; when filed, 2 of 65 harnesses ran all ten locales. | Census the next locale (en-US) with the #1590 tool; review the outside verifier example posted 2026-11-15 as input, as the owner asked. | live Logic, one locale a session | XL |
| #1586 | A feature counts as done only when its acceptance row ran on real Logic with an independent readback and restore. This is #1028's scope; the one unique item is the caller gap: a connected caller's `inspect_session` omitted Solo, Mute and Record values and returned no strip links. | Read current main's `inspect_session` on Logic 13 for Solo, Mute, Record Enable and verified strip links; report the result on the thread. | #1028 | M |
| #816 | The qualified release's evidence is retrievable and hash-bound to the executable, with the actual guarantee of an unsigned release written down (integrity yes, authenticity no). | Write that reconciliation with #284 first; then publish the evidence file with its hash beside `SHA256SUMS.txt`. | #284 | M |
| #1403 | No step from merge through native qualification to release needs a person. The 2026-11 CI fixes (handshake, cancel, native-only rerun) are slices of it. | Check the body's remaining items against the pipeline as it runs today and mark those #1576 and #1463 made moot; the rest go to the CTO. | CTO-owned CI | M |
| #308 | The permanent index. Its top block is r5 of 2026-09-22 and points at a queue that has moved. | After this file merges, replace the top block with a pointer here. | this pull request | S |

### Wave 4 — Session repair and organization (6)

Each needs Logic 13 re-measurement first; their last measurements predate it. #971 integrates
the others, so it goes last.

| issue | resolved at the root means | first step | depends on | size |
|---|---|---|---|---|
| #291 | Exact bus, output and send repairs verified, with restore, across the ten locales. Send-level and the Korean/English Send-only completions are qualified; the last measured failure (2026-10-29) was `compensationFailed` after 600 s on Output → Bus 1. | Re-run that Output → Bus 1 compensation on Logic 13. | live Logic; #967 for bus creation | XL |
| #967 | Create or reuse the intended bus and aux without disturbing routing, and delete only what we created. Blocker measured: the original Mixer strip objects retire during creation, so ownership cannot rest on object identity. | Re-acquire the created strip by name and channel after creation, and test that on Logic 13. | #291 | XL |
| #969 | Verified sorting, exact ordering, grouping and view layout that do not break Track Stacks. Mixer visibility is shipped (#1142, #1143, #1521); ordering, grouping and layout are not. | Exact-order primitive on Logic 13 once select works; the second #1600 reporter's stack case is the test. | #1600; live Logic | XL |
| #862 | An MCU strip index binds to a Logic channel, so a plug-in edit through MCU names its target. Logic re-banks on selection and nothing reads the bank offset; banking settle is fixed (250 ms). | Route search: read the strip's name from the device after each bank and compare it with the intended channel; measure whether it identifies one channel. | live Logic with MCU bound | L |
| #970 | A verified read of a track's colour, then writes. Provider searches so far (the floating Color window, the Inspector, Track Color Bars, the saved project) found no readable colour. | Repeat the attribute sweep on Logic 13; then test an independent read of the exact header's colour bar by screen sampling at the header's AX frame. | live Logic | L |
| #971 | One approved multi-domain repair runs end to end with an independent final readback. Reuses the audit, Saga and #1519 slice; nothing is rebuilt. | Pure adapter and coordination tests over the slices that already exist. | #291, #967, #969, #970 | XL |

### Wave 5 — Provider backlog (6)

Each is a programme; its first slice is one real thing proved on Logic 13, then expansion.

| issue | resolved at the root means | first step | depends on | size |
|---|---|---|---|---|
| #302 | A production, target-bound, complete note read of the selected region, then an independent comparison. A partial Event-List read is merged (#1480). As measured 2026-09-09 the release binary carries no expected-source seam, so a positive match is structurally impossible. | Move the independent expected source from the debug-only seam into production. | live Logic | XL |
| #303 | One exactly selected note's velocity changes and restores with a full independent read. | Read-only plan once #302's snapshot is valid. | #302 | L |
| #304 | The Tempo List is read target-bound (a reader exists), then one event's BPM edit, then Smart Tempo. | Expose the Tempo List snapshot with complete or partial semantics; #1621's Beats pause can use it. | live Logic | XL |
| #305 | A Flex-analysed monophonic audio region is inspected with stable note identity, then one scalar edit. No producer exists. | Prepare one disposable project holding an analysed audio region by hand, then census the audio editor. | live Logic; fixture | XL |
| #306 | One exact third-party plug-in build, insert and parameter reads and writes two-way; then generalise. | Pick the plug-in a user workflow names; the Controls-view read path already worked once. | #862, #299 | XL |
| #955 | A parameter snapshot and diff of what has verified reads, then a batch with a proven inverse. Activate only for a named workflow. | A snapshot composed from the existing reads (Channel EQ, Compressor threshold, Gain, Noise Gate, Sample Delay). | #299, #1430, #1417 | XL |

## Overlaps, and what we cannot finish alone

- **One fix, several issues:** #1600 resolves the cause of #1598 and #1599; #1604 and #1605 are one family
  with them. #1601 and #1606 are one latency question. #1586 restates #1028; #1403 overlaps it; #816 is
  half of #284. #299, #1417, #1430 and #955 share one reader family. #971 integrates #291, #967, #969,
  #970. #303 waits on #302. #1618's bus step overlaps #967. #1552 and #1550 are the same reporter and
  the same kind of close-out.
- **Needs an answer or a platform we do not have:** #1626 (Logic 12.4; waits on the reporter's version
  and `.mcp.json`), #1585 and #1596 (macOS 27 reporters; we ship the fix or the explanation and they
  confirm), #1565 (reporters retest on a build of main), #1552 and #1550 (a 12.4 rerun cannot be
  made here; the Logic 13 evidence stands), #1546 (needs a Creator Studio host; the reporter has
  offered). What would unblock each is named in its row.
- **Whole programmes, not a single fix:** #284, #1028, #291, #967, #969, #971, #302 to #306, #955. Each
  row names the one slice to prove next; closing each needs many Logic sessions, not one pull request.
- **No issue yet, carried from 2026-11-23 and not re-measured:** `create_marker` does not apply its name
  on Logic 13; the release `candidate-package` job runs on `macos-15-intel`; Key Commands is not
  exposed to Accessibility on Logic 13.

## What this file does not claim

It does not turn a merged pull request into a resolved issue, or a native pass into whole-issue
completion. Issue state here is a transcription of GitHub at the date above.
