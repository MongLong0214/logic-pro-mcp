# ADR-027 — A fixed verifier: completion is judged by the repository, from Apple's data, in ten locales

**Status:** Accepted by owner directive, 2026-09-27: "내가 개입하지않아도 시스템적으로 완벽하게 돌아가게 구현해". The oracle catalogue (D3) is filled from the Apple data census completed the same day (`/Users/isaac/lpm-evidence/apple-census/synthesis/SYNTHESIS.md`).
**Related:** ADR-019 (observation ledger), #308 (ADR programme), `Scripts/livekit/`, `Scripts/logic_canon.py`, `docs/locale/ui-labels.json`
**Date:** 2026-09-27
**Owner directive:**
- "Sonnet급 에이전트도 작업을 수행할수있을만큼의 타이트한 기계적 검증시스템."
- "기능구현이 완료되었는지 명확한 증거를 제시하면 그걸 기계적으로 검증할수있고, 모든 언어 locale도 기계적으로 지원."
- "이 시스템이 올바르게 작동된다면 남은 ADR 18개의 개발속도도 기하급수적으로 빨라져야돼."

## Context

Audits on origin/main d81c7e5b, 2026-09-27. Reports and commands are in `/Users/isaac/lpm-evidence/apple-census/audit-{A,B}-report.md`; the coordinator spot-checked the claims below and corrected two.

```
live harnesses                        65 files, 18,613 lines; 9.7% shared code (evidence.py 1,991 lines)
assertions written by the implementer 447 of 447; 0 from a ticket, ADR or spec
expected strings from Apple data      3 harnesses; 10 take them from the product's own AXLocalePolicy
pass flag supplied by the author      364 checks; observations cut at 400 chars; the binary's head guessed from file times
checks naming a mutation              206 of 364; no named mutation is ever run
harnesses that cannot exit non-zero   2 (live_766, live_849)
harnesses running all ten locales     2 of 65; language switching written 6+ times
typed non-ASCII labels in harnesses   122 across 27 files; ui-labels.json used by 1 harness
harness commits fixing the instrument 88 of 113 (the top 5 classes are 57: aimed wrong, cannot fail, wrong UI model, locale spelling, wrong-commit evidence)
canon: Swift UI literals              1,263, all hand-typed; 92.1% exact Apple strings; 85 found nowhere
canon: it/pt/zh_TW QuickHelp.plist    byte-identical to English, yet used as their translation (AXLocaleValues ships English as it-IT/pt-BR/zh-TW)
canon: label "derived" credit          286 cells credited with no pinned Apple row
```

**Throughput.** Today it is bounded by the instrument, not the product. #291 R1's product fix was one commit (b281cb01); its harness took three rounds of fixes before it could say anything. #1027 took three review rounds and two ten-locale drives. Every feature pays for a new harness, a hand-written record and a coordinator's judgement. Adding agents does not add throughput, because every feature queues on the same judge and the same serial live lane.

**Correctness.** The same session also produced two cases where the product was wrong in one language and only a ten-locale run could see it:
- #291: an occupied send slot was never reported, in any language.
- German: the track-header Mute is `Stumm`, which the label set, derived from one Apple row (`Mute#acc` → `Ton aus`), cannot match.

The second is canon defect D2 turning into a product defect.

**The permission layer retired on 2026-09-13 (1fc80e79) is not coming back.**
- That layer was stamps and records of having run: machines deciding whether work may proceed.
- This ADR is the opposite. The verifier runs the checks itself, keeps nothing that authorizes itself, and its exit code is the verdict.

## Decision

### D1 — Acceptance is data written before the code, never by the implementer

- Each ticket carries `docs/acceptance/<issue>.json`: rows of `{operation, fixture, preconditions, observe, expect, oracle, counterexample, restore}`.
- `expect` is expressed in canonical keys and oracle references, never in a localized string.
- Each row cites the ADR/PRD criterion it implements as `{doc, sha, quote}`. A check refuses a row whose quote is not verbatim in that document at that SHA.
- No human approves rows. A second, independent agent (a different model or provider) reviews the derivation, and its findings block like any failed check.
- An implementer who changes a row changes the contract. The PR check shows that as a separate diff class, which needs the independent review again.

### D2 — One repository-owned verifier; harness code per feature goes to zero

`Scripts/verify/verify.py` runs acceptance rows against a binary built from an exact head. The head's hash is measured from the binary, not inferred from file times. The verifier owns:
- the lifecycle: locale switch, fixture open and reset, server exclusivity, screen lock sampled per check, modal and menu cleanliness, restore verification;
- raw observation storage: untruncated, with the predicate source stored beside it;
- the pass computation. No author-supplied `passed` exists.

Feature-specific code is allowed only as registered **probes**: readers and actuators in a shared library, each with its own positive control and mutants.

### D3 — Oracles come from outside the product

An expected value must come from one of these:
- a pinned Apple row, proven translated for that locale (D6);
- an independent reader of the same state: MCU feedback, AppleScript, a file on disk, a second AX path;
- an ADR constant.

The verifier refuses an expectation taken from product code (`AXLocalePolicy`, `AXLocaleValues`).

**Oracle catalogue (census, Logic Pro 12.3 build 6674, 2026-09-27).** The census covered every file of the bundle (86,951 = `find` exactly), the system and user Logic data, and Apple's web guides: 93,149 local files in 410 classes, 48 of them used by the repo (15,215 files) and 362 unused (80,356). Oracles by class of expectation:

| expectation | Apple data | ten-locale status (measured) |
|---|---|---|
| UI labels (buttons, menus, headers, AX descriptions) | `.strings` UI rows: 15,464 addresses in all ten locales, 11,678 translated in all nine; nib labels: 630 in all ten, 269 translated in all nine | the only broad ten-locale source; row-level translation is proven per address (D6) |
| plural and count phrases | `.stringsdict`: 100 files, 1,040 keys, all ten locales | not in the canon today (0 of 1,040) |
| QuickHelp text | `QuickHelp.plist`: 29,511 addresses | **it, pt and zh_TW are English copies (0.0% differ); never an oracle for those three** |
| content names (patches, loops, IRs) | `ContentDatabaseV01.db` strings: 38,368 addresses | translated only in zh_CN and zh_TW; key on internal ids or English elsewhere |
| key commands | Apple's key-command table (web guide, 839 function–key rows); `.logikcs` presets (binary, not decodable yet) | web guide version unmeasured; no zh_TW web content |
| control-surface (MCU) assignments | two Apple channels (web tables 277 rows; PDF 240 rows) agreeing on 67 of 68 controls; `config.lua` for 98 third-party scripts | locale-independent |
| plug-in identity and parameters | `DefaultPluginMapping.plist` (242 AUs), `auval`, MADSP tables (128 units), `.pst`/`.cst`/Smart Controls maps | locale-independent; the canon has no range field |
| project structure fixtures | 45 factory `.logicx` with MetaData | locale-independent |
| MIDI fixtures | 155 MIDI chunks in Apple Loops | locale-independent |

Four product defects were found by these oracles on the same day. They are filed as issues and are the first work for the verifier to judge:
- CGEvent fallback keystrokes that Apple binds to other, state-changing commands;
- a factory preset catalog that sees 2 of 257 ES2 presets;
- readers that reject Apple's own content;
- hand-typed labels missing locales (`tickSliderLabel`).

### D4 — Every check proves in the same run that it can fail

- Each row has a counterexample: a raw observation, captured in the run, that the same predicate must reject.
- The predicate library carries mutants that CI runs. A predicate that no mutant can flip is refused.
- This closes the "cannot fail" and "wrong aim" classes, which are 28 of the 88 instrument fixes.

**Order rules.** A row names its operation, the one call it judges; no call follows it.
- An invariant is a precondition and nothing else: it reads only steps taken before the operation. A reading after the operation is a claim about the operation, and so is an effect.
- Every reading after the operation is an effect, and some counterexample must make it FAIL. No flag exempts one.
- A preservation claim ("the upper row is unchanged") is an effect too. Its counterexample is a reading taken before the operation that differs from the preserved one. If the fixture has none, the row adds a probe step that takes one.
- A claim is measured against the state just before the operation, after every call that precedes it, so a setup call cannot be credited to the operation.
- An effect's expected value comes from before the operation: its `ref.obs` names a reading taken before the operation, not a call. A reply, the operation's or a setup call's, and a reading taken after the operation are not independent expected values.
- A counterexample is the same kind of reading as the one it replaces, and each check it lists reads the replaced step. A check it lists does not compare with the counterexample's own observation: with that observation substituted, the check compares a reading with itself and fails whatever was read.
- A restore check reads only what a restore produced: steps bound after the last call in `restore`, the restoring action, by the same test for a call that the rules above use. A probe before that call, a reading between two calls in `restore` (a later call can undo what it read), the call's own reply, and every step from the operation on are refused: a reading taken after the operation and before a restore is a claim about the operation, so it belongs in `expect`, with a counterexample. Its `ref.obs` may name a reading before the operation, the as-found state it is compared with. No restore check reads a call's reply, in `steps` or in `restore`. A `restore` with no call restored nothing, so its `restore_expect` is empty; a `restore` with a call has at least one restore check, since a write is credited only when its restore is verified (#984). A restore check needs no counterexample, so nothing yet shows it can fail.
- `Scripts/verify/engine.py` `validate_spec` is where these rules run; `docs/acceptance/SCHEMA.md` explains them.

### D5 — Ten locales by the mechanism, batched

- The live lane is one Logic, and the locale switch is its cost.
- `verify.py --batch` switches each locale once and runs every pending head's rows in that locale. N features cost ten switches, not 10·N.
- Labels resolve only through canon keys. A literal in a probe is refused, as now, but with no English-only exemption list.

### D6 — Canon corrections (audit B)

- **Localization proof.** A file or row counts for a locale only if it is proven translated. A file byte-identical to English is flagged as not localized, and the locale falls back to a measured reading or stays `unmeasured`. This is D1 of audit B.
- **Derivation is positional.** A label is derived only from the row the UI element uses, proven by one live reading per row family. Coincidental presence anywhere in the locale does not count. This is D2.
- **Removed values fail.** Value citations fail when Apple removes the value (D3).
- **One fold definition.** Digest and fold share one definition (D4).
- **The AX-comparison guard covers every literal,** not only whole Apple values (D5).
- **Smaller fixes.** Parser parity with CoreFoundation (D6), a CLI that fails loudly (D7), `.stringsdict` ingested, and an automatic drift check against the installed Logic.

### D7 — Evidence re-checks offline, and records are generated

- `verify.py --recheck <evidence>` recomputes every verdict from the stored raw observations and predicates. It can FAIL, REFUSE, or report incomplete. Only `run` certifies clean.
- Every field of an evidence file was written by whoever wrote the file, so a file cannot attest to its own build, locale or observations. Clean needs an attestation held in process by the run that produced the evidence: the binary's digest as built, the head the verifier checked out, each locale's reading, and the digest of the evidence bytes. Nothing builds one from a file. Host checks on a file's binary block are consistency checks; they never make it clean. A worker cannot hand the verifier a verdict.
- **The trust boundary.** Clean is honoured only from `verify.py run` invoked by the gate itself; a verdict printed by any other process, including a script that imports the engine and calls `judge` with an attestation it built, is not evidence. An attestation is a value of the running verifier, not a document. Forging one requires editing code the verifier runs, which review and CI guard; the verifier does not guard against its own code (the insider class, #816). The self-test holds the boundary it can: it parses every tracked `.py` file (`git ls-files '*.py'`) and fails when anything outside the in-process sites names `Attestation`, and inside `Scripts/verify/` it also refuses the routes that build one without naming it. Runtime secrets and signatures inside one Python process are ruled out: they protect nothing against code in that process.
- Exit codes: 0 clean (`run` only), 1 a row failed, 2 refused, 3 incomplete (the best a file can reach).
- One generator in the repo writes observation records from evidence. Hand-written records stay valid, and new ones are generated. It writes only with an attestation, in the process that produced the evidence; recording a file from the command line is refused.

### D8 — Throughput is the acceptance criterion of this ADR

Measured before and after on the next ADR tickets:
- new harness lines per feature: target 0;
- verdicts computed by the verifier: target 100%;
- locale switches per batch: 10;
- coordinator interventions per issue;
- ticket-to-merge time.

The ADR is not done until the programme is measurably faster on these.

## Phases (proposal)

- **P0.** The verifier core, lifecycle, probe registry, counterexample and mutant machinery, and `--recheck`. Pilot: port the #1020 and #291 harnesses to acceptance rows, and show equal or stronger verdicts in ten locales.
  - **P0a** (#1028) is the commit set that adds this ADR: the offline engine in `Scripts/verify/` — the acceptance format `lpm-acceptance/1` (`docs/acceptance/SCHEMA.md`), the closed predicate set, the verdict engine, the evidence format with its binding rule, `verify.py check-spec | recheck | self-test` with its mutant runner in `run-repo-guards`, the recording logic in process (`record_attested`), exercised by the self-test — the `record` subcommand refuses a file with exit 2 and says why; the producing command is `run`, in P0b-2 — and the #1020 pilot (`docs/acceptance/1020.json`) with one converted evidence file. It drives nothing live.
  - **P0b** is the live lifecycle behind `verify.py run` and `verify.py batch`: build from a clean detached checkout, locale switch, a fixture gate before each row with one reset when it misses, probes, and the restore to Korean. The runner is `Scripts/verify/runner.py` and `Scripts/verify/runner_live.py`, the probes `Scripts/verify/probes.py` and `Scripts/verify/live/spec_probes.py`, and the library `Scripts/verify/live/` (P0b-1, #1033). P0b-2b adds `run` and `batch`: the one place an attestation is built, in the process that ran the rows, and, given `--record`, the only producer of records. Its first live run of #1020, in ten locales on 2026-09-28, is not clean; the #1028 row in `docs/roadmap/README.md` says how. Before it, P0b-2a (#1046) tightens the offline engine against the pre-merge adversarial re-check of #1032, answering W01, W02, W04, W05 and W06 (W03 was no finding): NaN and Infinity are refused, a null at any depth or a key on one side only is UNREADABLE under `changed`, `ne` and `not_in`, `unchanged` of two nulls is UNREADABLE, a restore check reads only after the last call in `restore`, and `changed` needs another check that pins the same path, `eq` a constant, `in` a listed set or `matches_canon` a canon row.
- **P1.** Canon D6, and the oracle catalogue above wired into the canon (stringsdict, a translation-proof flag, per-locale exclusions).
- **P2.** Ticket-gate acceptance rows for the open ADRs: 001, 007, 008, 009, 011, 014, 015, 016, 017, 018, and 020–026 (#965–#971).
- **P3.** Parallel Sonnet implementation against the rows, with auto-merge on a green verifier. Measure D8.

## The owner is not in the loop

- Every gate that waited for the owner becomes a mechanical check or an independent review (D1).
- A feature PR that touches product paths merges automatically when CI is green AND its acceptance rows pass in ten locales on the verifier. Nothing else decides.
- This is not the retired permission layer. No stamp or record authorizes anything; the verifier runs the checks itself each time.
- Escalation to the owner is limited to P0/P1: security, destructive or irreversible actions, iCloud, publishing outside the repository.
- Orchestration state lives in files (`docs/acceptance/QUEUE.json` and the boot packet), so a restarted session resumes without anyone re-explaining.

## Not decided here

- Which old harnesses are ported and which are retired. This is decided per ADR in P2, by coverage.
