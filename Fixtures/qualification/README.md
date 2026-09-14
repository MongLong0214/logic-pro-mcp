# Managed qualification fixtures

These files are the managed, reproducible input **descriptors** for the
LPMCP-PRD-001 / ADR-001 qualification matrix. They close the repository-content
half of the `R-MATRIX` production-readiness debt ("managed fixture matrix
unbound"): the matrix descriptors now exist as byte-stable content that is
SHA-256-bound in `fixture-manifest.json`, rather than being named only by a
workflow marker. A consumer that drives them through a live Logic Pro session
does not exist yet (see "Scope and limitation").

## What these are

Each `desktop-<locale>-<size>.json` file is a **canonical descriptor** of the
project state a same-artifact qualification run is expected to establish for one
axis. A descriptor pins the deterministic project content (tempo, time
signature, sample rate, track layout) for its fixture size and records the axis
it belongs to (`variant / locale / profile / cache / fixture`).

They are honest content, not opaque labels:

- **Reproducible** — regenerated deterministically by `generate-fixtures.py`, so
  a clean tree is byte-identical.
- **SHA-bound** — `fixture-manifest.json` records the SHA-256 of every fixture's
  exact bytes. `ManagedQualificationFixtureTests` recomputes each SHA from disk
  and fails closed on any drift, so the identity is verified, not asserted.

## Ship matrix coverage

Owner decision (2026-07-17, ADR-001): Desktop Logic Pro is the only ship surface;
Creator Studio is permanently out of scope. The required same-artifact matrix is
therefore `desktop x {en-US, ko-KR}` with the `empty` project fixture — both
required axes are present here. The `medium` and `large` sizes are additional
managed inputs for broader reproducible coverage.

| variant | locale | empty | medium | large |
| ------- | ------ | ----- | ------ | ----- |
| desktop | en-US  | yes   | yes    | yes   |
| desktop | ko-KR  | yes   | yes    | yes   |

## Host preconditions a live run needs

The descriptors above pin the PROJECT. They say nothing about the host, and a
qualification run's result moves by several operations depending on host state that
nothing in the artifacts records. Every line below was measured on 2026-09-14
against Logic 12.3 (6674) on macOS 26.3, and each one was found by a run changing
its answer with no code change between the two.

| precondition | what it costs when unmet | measured |
| --- | --- | --- |
| A Latin keyboard input source is active | `tracks.mute`, `tracks.solo`, `tracks.arm`, `transport.set_tempo` stop qualifying | 36 pass under `com.apple.inputmethod.Korean.2SetKorean`, 38 under `com.apple.keylayout.ABC`, same binary and project |
| The arrange window is wide enough for the control bar's Cycle and Metronome buttons | `transport.toggle_cycle`, `transport.toggle_metronome` stop qualifying | at 1024x746 the `사이클` / `메트로놈 클릭` checkboxes are absent from the AX tree; at 1900x1040 both are present, enabled, and move under `AXPress` |
| The Mixer panel is visible | `mixer.set_volume`, `mixer.set_pan` stop qualifying | `logic://mixer` answers `data_source: mixer_not_visible` and the freshness gate refuses the readback |
| Logic's Library panel is open | `tracks.list_library` REFUSES instead of answering, which reads as a fixed defect | the live gate test reports the pinned entry as one that "stopped failing"; the panel was shut after a restart |
| The record-arm key command is assigned, under the SAME input source the run will post from | `tracks.arm` stops qualifying | a chord learned under 2-set Korean is stored by Logic as `⌃⇧ㄷ` and does not answer a `⌃⇧E` posted under ABC |

Two of these are worth stating as principles rather than rows.

**A composing input source rewrites the character a synthetic key carries.** The
keystroke is still delivered — a bare spacebar toggles play under the Korean source
— so only keys carrying letters are affected, and only they break. Logic's own
Learn records the composed character, which is why an assignment can look correct
in the Key Commands window and do nothing.

**Logic hides control-bar buttons that do not fit.** A narrower window is not a
cosmetic difference to an accessibility-driven actuator; the control it needs is
not in the tree at all.

None of this is visible in the qualification artifacts. A run that reports 36 and a
run that reports 41 differ in host state, and the attestation says nothing about
which host state produced it. Closing that is `R-MATRIX` work this README does not
claim to have done: what it does is stop the preconditions being rediscovered one
at a time.

## Scope and limitation

These descriptors satisfy the repository `R-MATRIX` contract: the closer
`ProductionReadinessContractEvaluator.managedFixturesPresent` recomputes each
fixture's SHA-256, requires digest equality, and requires every ship-required
axis to be covered by a fixture whose SHA-bound descriptor declares that axis.
They are the canonical spec of each axis input; they do not themselves drive
Logic Pro, and no consumer of them exists yet. Automatically loading a descriptor
into a live Logic Pro session and consuming it end-to-end in the qualification
harness is a live step that belongs to the ADR-001 live-matrix program, not to
this repository-content debt.

## Regenerating

```
python3 Fixtures/qualification/generate-fixtures.py
```

The script rewrites every descriptor and `fixture-manifest.json` deterministically
and prints each fixture's SHA-256. A clean regeneration must leave the tree
unchanged.
