# Acceptance documents — `lpm-acceptance/1`

An acceptance document holds the rows that decide whether one issue is done. They are written
before the code and never by the implementer (ADR-027 D1). The fixed verifier in `Scripts/verify/`
reads one and is the only place a verdict is computed.

- Shape: `Scripts/verify/acceptance_schema.json`.
- Every rule that relates fields to one another: `Scripts/verify/engine.py` `validate_spec`.

This file explains both. Where it and the code disagree, the code is what runs.

```
python3 Scripts/verify/verify.py check-spec docs/acceptance/<issue>.json   # admissible?
python3 Scripts/verify/verify.py recheck <evidence.json> [--spec <doc>]    # recompute every verdict
python3 Scripts/verify/verify.py record <evidence.json> --out docs/observations
python3 Scripts/verify/verify.py self-test                                 # fixtures + mutants
```

`verify.py run` and `verify.py batch`, the live lifecycle, are P0b. Until then they exit 2 and run nothing.

## Exit codes

| exit | word | check-spec | recheck |
|---|---|---|---|
| 0 | clean | admissible, and every quote is verbatim in its source | every row PASSES in every required locale, the stored verdicts equal the recomputed ones, every run's locale reading is its run key, and the binary's provenance is verified on this host (below) |
| 1 | failed | — | a row FAILS, or a stored verdict differs from the recomputed one |
| 2 | refused | shape, a refusal rule, or a quote that is not in its source | the evidence is malformed (an observation entry included), its `spec_sha256` is not the digest of its spec, `--spec` names a different document, or a run's locale reading names another locale |
| 3 | incomplete | a source could not be fetched, so its quote is unchecked | a row is UNREADABLE, a required locale was not run or carries no readable locale reading, the binary is `unbound`, or its provenance could not be verified on this host |

A failure outranks incompleteness: evidence with one FAIL and nine missing locales exits 1.

## The document

```json
{
 "format": "lpm-acceptance/1",
 "issue": 1020,
 "surface": "system.midi",
 "sources": [{"doc": "issue:1020", "sha": null, "quote": "A toggle must not be presented as a set."}],
 "fixture": {"id": "lpm-locale-campaign-19", "note": "what the project holds and how the server is started"},
 "locales": "all",
 "rows": [ ... ]
}
```

| field | meaning |
|---|---|
| `format` | exactly `lpm-acceptance/1` |
| `issue` | the GitHub issue these rows decide |
| `surface` | a surface id of `docs/observations/SURFACES.md`, carried into generated records |
| `sources` | where the criteria come from, one quote each (below) |
| `fixture` | `id` names the project state P0b opens or resets to; `note` says what that state is |
| `locales` | `"all"`, meaning the ten of `Scripts/logic_canon.py` `EXPECTED_LOCALES`, or `{"subset": [...], "reason": "..."}` |
| `rows` | at least one row |

### Sources

`{"doc", "sha", "quote"}`. `quote` has at least 20 characters. `check-spec` fetches the source and
requires the quote to appear in it byte for byte:

- `"doc": "issue:<n>"` with `"sha": null` is read from GitHub with `gh issue view <n> --json body`.
- `"doc": "docs/adr/ADR-<nnn>-....md"` or `"doc": "docs/prd/<name>.md"`, with `sha` naming the
  40-hex commit it is quoted at, is read with `git show <sha>:<doc>`. The repository squash-merges,
  so pin a commit on `main`; a branch commit disappears when the branch is deleted.

Nothing else is a criterion source. `docs/acceptance/**`, `docs/observations/**`, `Sources/**`,
`Tests/**` and every other path are refused, whatever they say: a criterion comes from an ADR, a
PRD or an issue, never from the rows that judge it, an earlier observation, a test or the product
(ADR-027 D1, D3). Text anywhere in the document that points into product source
(`Sources/`, `AXLocalePolicy`, `AXLocaleValues`) is refused as well.

### Locales

`"all"` is the default scope. A subset needs a non-blank `reason`, and every code in it must be
one of the ten.

## Rows

```json
{
 "id": "arm-unarmed-sets",
 "criterion": 0,
 "steps": [
  {"as": "pre", "probe": {"name": "track_armed", "args": {"index": 0}}},
  {"as": "reply", "call": {"tool": "logic_tracks", "command": "arm", "params": {"index": 0, "enabled": true}}},
  {"as": "post", "probe": {"name": "track_armed", "args": {"index": 0}}}
 ],
 "operation": "reply",
 "expect": [
  {"path": "reply.state", "op": "eq", "value": "A"},
  {"path": "post.armed", "op": "eq", "value": true},
  {"path": "post.armed", "op": "changed", "ref": {"obs": "pre.armed"}}
 ],
 "counterexample": [{"observation": "pre", "replaces": "post", "must_fail": [1, 2]}],
 "restore": [
  {"as": "undo", "call": {"tool": "logic_tracks", "command": "arm", "params": {"index": 0, "enabled": false}}},
  {"as": "restored", "probe": {"name": "track_armed", "args": {"index": 0}}}
 ],
 "restore_expect": [{"path": "restored.armed", "op": "eq", "ref": {"obs": "pre.armed"}}],
 "independence": ["pre", "post"]
}
```

| field | meaning |
|---|---|
| `id` | unique in the document, `[a-z0-9-]` |
| `criterion` | index into `sources`: the quote this row decides |
| `steps` | what the runner does, in order; each binds its reading to the name in `as` |
| `operation` | the name of the `call` step this row judges; order is measured from it |
| `expect` | expectations over the bound readings; the row PASSES only if every one PASSES. Each is an effect, or an invariant with `"invariant": true` (below) |
| `counterexample` | substitutions that must make named expectations FAIL (below) |
| `restore` | steps that return the fixture to its as-found state (may be empty) |
| `restore_expect` | expectations that prove it was returned; they may read `steps` and `restore` names |
| `independence` | the names whose readings do not come from the operation's own reply |

### Steps

Exactly one of:

| step | the reading bound to `as` |
|---|---|
| `{"call": {"tool": "logic_*", "command", "params"}}` | the `tools/call` reply, as the exact JSON text received |
| `{"read": {"uri": "logic://..."}}` | the `resources/read` contents, as the exact JSON text received |
| `{"probe": {"name", "args"}}` | a registered probe's result (`Scripts/verify/probes.py`); unknown names and wrong argument types are refused |
| `{"wait": {"probe", "until": {"path", "op", "value"}, "timeout_ms", "interval_ms"}}` | the probe's last reading, polled until the condition holds or the bounded time runs out (at most 60000 ms) |

A wait condition takes a constant, so `changed`, `unchanged` and `matches_canon` are refused there,
and an `interval_ms` above `timeout_ms` is refused because it would read once and call that waiting.

### Paths

A path is a small JSONPath subset. Its first segment is a bound name, and the rest walk into that
reading:

```
reply.state                  key `state`
post.data[0]                 element 0 of the list under `data`
post.data[id=15].isArmed     the ONE element of `data` whose `id` is 15, then its `isArmed`
census.rows[name="Audio 1"]  selector values are JSON scalars, or a bare word read as a string
```

Keys match `[A-Za-z0-9_$-]+`. A key containing `.`, `[`, `]` or `=` cannot be addressed, and the
parser refuses such a path rather than guessing. A path whose root no step binds is refused.

### Outcomes

Every check has one of three outcomes:

- **PASS**: the reading exists and satisfies the operator.
- **FAIL**: the reading exists and does not.
- **UNREADABLE**: the reading does not exist. That covers a missing key, an index past the end, a
  selector matching zero or several elements, an observation the runner could not take, and an
  observation whose stored bytes differ from its recorded `raw_bytes`.

A missing path is never FAIL and never PASS. A reading of the wrong type for its operator is FAIL.

### Operators (closed set)

| op | operand | PASS when |
|---|---|---|
| `eq`, `ne` | `value` or `ref.obs` | strict JSON (in)equality: `true` is not `1`, lists compare in order |
| `in`, `not_in` | a list `value`, or `ref.obs` | the reading is / is not an element |
| `subset`, `superset` | a list `value`, or `ref.obs` | as sets of JSON values |
| `count_eq`, `count_ge` | a non-negative integer `value`, or `ref.obs` | the reading is a list of that length / at least that length |
| `changed`, `unchanged` | `ref.obs` only | the reading differs from / equals another observation |
| `is_null`, `not_null` | none | the path exists and holds / does not hold `null` |
| `matches_canon` | `ref.canon` + `ref.locale` + `ref.quote` only | the reading's canon digest equals the pinned digest of that canon row |

`changed`/`unchanged` compute what `ne`/`eq` compute. They are separate names so that a row meaning
"this moved relative to the pre-state" cannot be written against a constant by mistake.

`matches_canon` references are `logic-canon://strings/<source>/<locale>/<key>#value` with
`"locale": "$locale"` (the run's locale) or one fixed code, and a `quote`: the value the ref text's
own locale pins, checked by `check-spec` against the canon digest. Put `"quote": "..."` on a line of
its own, which is what `check-canon-citations` reads as the citation's value. They are resolved offline against
`docs/canon/index/`, and a row that is not pinned in that locale is UNREADABLE. A value citation
(one with no key) is refused: it says Apple ships the string somewhere, not that this element
shows it (ADR-027 D6). A document gives the pinned locale in the ref text (for example `en`) so
that `check-canon-citations` can resolve it.

### Independence and counterexamples

These are the D4 rules: every row proves, in the same run, that its checks can fail, and that
what it credits to the operation was read after the operation ran.

- `independence` names steps of the row that are not calls. A call's reply is the operation
  reporting on itself, so naming one is refused.
- `operation` names a `call` step. Steps run in the order written, so "before" and "after" are
  positions in `steps` relative to it.
- An expectation is an **effect** unless it says `"invariant": true`.
  - An effect that reads an independent step must read a step bound AFTER the operation. One that
    reads a step bound before it is refused: it is a precondition, and a precondition is written
    as an invariant.
  - An effect that reads an independent step must be listed in some counterexample's `must_fail`.
  - An **invariant** ("the other tracks are unchanged", "nothing was written") must PASS, but it
    is never credited as proof and is never listed in `must_fail`; listing one is refused.
- Each `counterexample` names an `observation` bound BEFORE the operation and a step it
  `replaces`, and lists `must_fail` indices into `expect`. The engine judges those expectations
  again with the replaced reading swapped for the other one. Each must then FAIL. If one PASSES,
  the row FAILS with `counterexample_accepted`: the check cannot tell the two states apart. If one
  is UNREADABLE, the row is UNREADABLE.
- A row needs at least one effect over an independent step bound after the operation, listed in
  `must_fail`. Otherwise the only falsifiable checks read the operation's own reply or a state
  read before it acted, and the row is refused as self-report.
- Use the pre-state reading as the counterexample of a post-state expectation. It is what the
  reading would be if the operation did nothing.

### Restore

`restore_expect` is judged like `expect`. If one FAILS, the row FAILS with `restore_failed`: the
fixture was left changed, and the next row's as-found state is not the one it assumes.

## Evidence — `lpm-evidence/1`

`Scripts/verify/evidence_doc.py` holds the full field list. In short:

- `spec` and `spec_sha256`: the document judged and the digest of its canonical JSON.
- `binary`: `{binary_path, binary_sha256, head, binding, note}`, the names
  `Scripts/verify/live/binary.py` returns.
  - `binding` is `built-by-verifier` only when the verifier built the binary from a clean detached
    checkout of `head` and measured its digest (P0b).
  - Anything else is `unbound`, and unbound evidence is never clean: its best exit is 3.
  - A `built-by-verifier` label is not taken on trust. `recheck` verifies, on the host running it,
    that `binary_path` is a file, that it re-hashes to `binary_sha256`, and that `head` is a commit
    of this repository (`git cat-file -e <head>^{commit}`). If any of these fails, provenance is
    `unverified`, with the reason, and the best exit is 3. This proves the file named is the file
    hashed; it does not prove the file was built from `head`. Someone with write access who builds
    a matching file by hand is out of scope.
- `runs.<locale>`: `{date, host, locale_reading, rows.<id>.observations.<name>}`.
  - `locale_reading` is what `Scripts/verify/live/locale.py` `reading()` measured when the run
    started: `{lproj, code, expected_title, language_setting, window_names}`. It must name the run
    key: `lproj` equals the key, `code` is that locale's code, the language setting's first entry
    is the code, and the expected title is among the window names. A reading that names another
    locale is refused and the run does not count; a missing or unreadable one leaves the locale
    unverified (exit 3 at best).
  - Each observation is `{step, raw, raw_bytes}`, where `raw` is the whole reply text, never
    truncated.
  - An observation the runner could not take is `{step, unreadable: reason}`.
  - An observation whose `step` differs from the spec's step of that name is UNREADABLE.
- `verdicts.<locale>.<row>`: what the engine computed when the evidence was written. `recheck`
  recomputes them and compares `verdict`, `expect`, `counterexample` and `restore`.

Every observation entry is shape-checked before anything is judged: an entry that is not an
object, a `step` that is not an object, or a `raw`/`raw_bytes`/`unreadable` of the wrong type is
refused (exit 2), never a crash.

Writes are atomic: a temporary file in the destination directory, `fsync`, then `os.replace`.

`record` reads the evidence bytes once and judges those bytes. It then publishes them as
`docs/observations/evidence/<sha256>.json`, named by their own digest, before it writes any record.
Every record cites that file, and its reverify command is `verify.py recheck` on it, so a later run
can never overwrite what an earlier record points at. It writes nothing unless provenance is
verified, and it skips a locale that is not measured or that stored no host block or date.

## The pilot

`docs/acceptance/1020.json` holds the #1020 rows. `docs/acceptance/evidence/1020-ko-4b036d93.json`
is the ko run of `live_1020_mcu_set_arm_is_a_set` at 4b036d93, converted by
`Scripts/verify/convert_1020.py`. The converter's docstring states exactly what that conversion
proves and what it cannot.
