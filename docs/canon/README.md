# The canon axis

**Apple's own bytes are the source of truth. A measurement is what we do where Apple's bytes cannot
answer — and that they cannot is itself checked, not asserted.**

## Why

Every failure this repository has had about Logic's interface has one shape: a string somebody
typed, standing where a string Logic ships should have been.

`playheadPositionGroupLabel` carried `再生ヘッド位置`. Logic shows `再生ヘッドの位置`. One missing
character made the element unfindable on every Japanese Logic, the set is matched whole, and the
ledger read it as coverage. Nothing was lying. Nothing had a way to check.

Measured on 2026-09-15, that is not an isolated case:

```
AXLocalePolicy holds 379 distinct literals the product matches Logic's interface with
  113   are a QuickHelp Title
  226   are somewhere in the bundle's 605,190 .strings entries
   40   are in no file of the app bundle
```

Those counts are printed by `Scripts/check-policy-literals-against-canon.py`, and they are the
only place they are written down. An earlier revision of this file carried 120/222/37 -- a first
pass taken before the extractor stopped counting `rationale` prose as labels -- in four documents
at once, in a change whose subject is typed numbers drifting from measured ones.

Some of those 37 are deliberate substrings for `.contains` matching. Some are labels nobody can
find. The repository could not tell which, because it had no notion of a citation.

## If you are opening an issue or a pull request

**What you have to provide.** One sentence, in the body, citing Logic, naming the behavioural
record the change rests on, or saying you are not talking about it.

On an ISSUE that sentence is asked for, not required: nothing is blocked, nothing is closed, and
you do not need a corpus build — or Logic — to report a problem. Open it with whatever evidence you
have, including none, and a maintainer can map what you saw to a row and add the reference. The
form below is what a pull request is gated on.

* Stating something about Logic: a `logic-canon://<source>/<locale>#value` reference AND the value
  in quotes. The forms and what each proves are below under *A citation without a key*. A worked
  one, so the shape is not only a placeholder — this reference resolves against the pinned corpus
  and the value beside it is what Logic ships at that key:

  ```text
  logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Trk#value
  Trk
  ```

  Both halves are required. A reference alone does not say what you claimed it says, and a value
  alone is a string you typed.
* Stating nothing about Logic: the sentence `This pull request body states no fact about Logic`
  (`This issue body` on an issue), and the reason. It has to be visible prose — a sentence a
  reader is shown only as code, or not at all, is deliberately not read, and the checker says so by
  name. Not read: a code block (a fence of backticks or tildes, closed or not, a list item's own line
  included, and text GitHub indents as code), an HTML comment, a footnote, and a raw `<pre>`. The
  check follows quotes and list items as GitHub does, and where it is unsure it hides: everything
  after a `<pre>` is hidden, even one quoted in backticks, and so is everything after a comment an
  HTML block leaves open. A link's target and the inside of an HTML tag are read.
* A change that touches a Logic-facing path cannot use the opt-out, whatever its description says.
  The prefixes are in `LOGIC-FACING.json` and the check derives this from the files, not the words.
* Resting on Logic's BEHAVIOUR rather than a string it ships: name, in visible prose, the
  `docs/observations/<name>.json` record that holds the measurement. It stands in for a citation
  only when this change adds or edits it, `check-observation-records.py` accepts it, it is a
  schema 3 record declaring `canon_not_applicable` that rule 13 accepts, one of its `depends` is a
  Logic-facing file outside `docs/` that this change also edits, and the body quotes no string the
  corpus holds. Do not paste a label citation instead: a label citation establishes
  what a label says, not what an element does when it is driven.

**What the checker establishes.** That a reference resolves against bytes committed to this
repository, and that a quoted value's digest matches Apple's at the pinned Logic build. Nothing
more. It is a check on the FORM of your evidence: it never ran Logic, it cannot tell you your
sentence about Logic is true, and passing it is not a statement that the change works.

**What stays human, or stays for runtime.** Whether the cited row is the RIGHT row. Whether a
`canon_absent` declaration is honest. Anything about how Logic behaves rather than what it ships —
that is measured live and recorded under `docs/observations/`, and no gate here does it for you.

**An issue is advised; a pull request is gated.** `canon-issue.yml` leaves ONE note on an issue and
edits that same note as you edit the body; nothing is blocked and no label is applied. A pull
request is different: `pr-policy` is a required check and a refusal blocks the merge. If the
checker itself could not finish — a corpus it could not read, a crash — it says so and blames
nobody; that is a repository-side failure, not a finding about your text.

**Where CI-integrity policy lives.** Not here. `.github/ci/` holds the four lists about this
repository's own CI — which jobs must gate, which commands must run, which guards may skip, which
guards have no test — owned by `Scripts/check-every-ci-job-is-required.py`. Editing one of those
does not go through the citation rule, because none of them rests on a row of Apple's data.

## The rule

1. A fact about Logic is **cited** to bytes inside Logic, by a reference that resolves and a quoted
   value whose digest matches Apple's.
2. A fact that cannot be cited is declared **`canon_absent`**, with the string, the corpora
   searched, and why a runtime measurement is the only route.
3. Both are checked mechanically, in CI, with no Logic installed.

That last clause is the whole design problem. `docs/observations/LOGIC-BUILD.json` already says CI
has no Logic — which is why the build there is declared rather than detected. A checker that needs
the application is advice, not a gate.

## How it works offline

```
build time   (needs Logic)     extract → digest → commit docs/canon/
check time   (needs nothing)   resolve a citation against what was committed
```

| file | what it is |
|---|---|
| `SOURCES.json` | which Logic assets are canonical, what each can answer, and what each cannot |
| `MANIFEST.json` | the exact Logic build, a digest over every byte of every corpus file, and the (source, locale) list every absence proof searches. That list may only GROW |
| `index/<source>.tsv` | key → digest, for keys something in this repository actually cites |
| `absence/<source>.<locale>.u32` | the sorted 32-bit digest prefixes of **every** value in that corpus |
| `WITHOUT-CANON.json` | records written before the rule. May only shrink. |
| `PROSE-NUMBERS.json` | numbers this README may state that no artifact and no record carries, and why each has none. May only shrink |
| `NOT-A-RECORD.json` | files under `docs/observations/` that are not observation records. May only shrink |

Four more lists were here until #951: `CI-GATE.json`, `CI-SKIPS.json`, `GUARDS-WITHOUT-A-TEST.json`
and `GUARD-TESTS-BLIND-TO-THEIR-GUARD.json`. They hold job names, guard names and test counts —
nothing about Logic — and they now live in `.github/ci/`, ratcheted by
`Scripts/check-every-ci-job-is-required.py`. **Where CI-integrity policy lives is `.github/ci/`.**
They were here only because the merge-base comparison happened to be written in this directory's
guard, and the cost was real: a contributor correcting a guard name had to satisfy the citation
rule over a change that rests on no row of Apple's data.

### A citation without a key

```text
logic-canon://<source>/<locale>#value
```

The key was where the last human judgement lived. `추가` is the value of `Add` and of
`Label_For_Drummer_Editor_GhostNotes_Slider|||More`; both resolve, both pass every check, and only
one *means* what a change is about. Of the 227 `.strings` values this repository matches Logic
with, only 63 have a unique key — so the other 164 asked somebody to choose, every time, with
nothing mechanical to check the choice against.

They should not have been asked. A `LabelSet` matches Logic at runtime **by value**; it never sees
a key. A key citation therefore asserts more than the code relies on, and the surplus is exactly
the part no check can verify. A value citation asserts what is used: Apple ships this string, in
this corpus, in this locale.

It resolves against `index/<source>.values.tsv`, full digests of the values actually cited —
deliberately **not** the absence sets. Those are 32-bit prefixes whose collisions are safe in one
direction: a collision makes an absent string look present, which *refuses* an absence claim.
Asking the same table whether a value is present inverts that, and would admit a citation to a
string Apple does not ship.

Use a key citation when the key is itself the claim — a QuickHelp key identifies a control, and
that is a fact about Logic worth pinning.

### Finding the citation in the first place

`Scripts/logic_canon.py locate '<string>'` prints every place a string is a whole value in
Logic, as references ready to paste. It exists because the AXHelp resolver is not the right
instrument for this and quietly looked like it was: `AXStringResolver.resolve` reads
`StringsIndex`, and the absence sets are built from `extract_strings`, which walks far more of the
bundle — the two counts and the shortfall are measured in #897. A string living only in the part
`resolve` cannot see answers `None` — which an author reads as *uncitable* — while
`is_absent` correctly refuses the absence claim, leaving no automated path either way. Both
`설치` and `키 레이블로 학습` are in that gap and both are citable. The narrow table is right
for what `resolve` does, reversing a live reading; issuing a citation is a different job.

The two examples above are the references it prints, and they are the citations #891 and #882
need:

```text
logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FInstall.strings/ko/164.title#value
  value:  설치
logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FKeyCommands.strings/ko/300557.title#value
  value:  키 레이블로 학습
```

The index holds only cited keys on purpose. A full QuickHelp index is 390,820 rows across ten
locales, and a checked-in artefact that size stops being read. The absence sets are the opposite:
they must be complete, because proving absence needs the whole corpus.

### The corpus is bounded, and the bound is the claim's bound

The absence sets cover five sources: `QuickHelp.plist`, every `.strings` file, MADSP's parameter
tables, nib runtime attributes, and the English compiled into `Base.lproj` nibs. They do **not**
cover strings compiled into the Logic binary, the labels in the 1,007 nibs Apple does not
base-internationalise, AppKit strings in the dyld shared cache, or the Help Book, which Logic serves
over the network rather than shipping.

The bound is the denominator of every absence proof here, so it is ratcheted: `MANIFEST.json`'s
(source, locale) set is compared against the merge base and may only grow. It was not, and the
consequence was measured rather than argued — deleting `madsp` and `nib` from the manifest, their
index and absence files from disk, and the entries records named, left a tree where all 48 guards
passed and every absence proof searched half the corpus it claimed. Each check verified the
manifest against artefacts the same build wrote, so consistency was preserved while the claim
shrank. Growing is free, and #895 did exactly that: it added `nibstrings`.

Its SIZE is ratcheted separately, because that comparison is a number rather than a membership.
`verify_absence_counts` already reads the counts and its own docstring says what that is worth —
the forgery needs "three consistent edits … instead of two", and a rebuild makes all three. Measured
the same way: twelve sets truncated to 50 entries each, counts and digests rewritten to match,
410,771 values discarded, `check-canon-citations` at exit 0 and 46 of 48 guards green, and
`logic_canon.py absent strings es 'Pista'` answering ABSENT for a string Logic ships.
`verify_index_against_absence` is the one check that could have seen it, and what it sees is
bounded by CITATION: it checks every committed index row against its corpus's absence set, and a
value nobody has cited has no row to check. This paragraph used to say "only six of the
twenty-three corpora carry a committed index row … blind to the other seventeen"; measured
2026-09-19 that is wrong twice over — the manifest carries TWENTY-FOUR corpora and TWENTY-THREE of
them carry at least one row, `strings/-` being the only one that carries none. Number WORDS are
invisible to `check-canon-prose-numbers.py`, which reads digits, which is how it rotted unnoticed.
A set may not lose entries while `MANIFEST.json` names the same Logic; a different Logic is allowed to hold different
strings, and the rule says so on stderr instead of passing quietly.

The same ratchet covers `shape` and `round_trip`, because those numbers are the denominator of the
only proof CI can run that the parser is right. `TheAlgorithmAgainstASurrogateCorpus` builds its
fixture FROM them, so lowering them lowers the bar: setting `suffix_pairs` to 1 and
`most_keys_on_one_composition` to 1 left a surrogate with one suffix pair and no shared composition
at all — the property 3,766 real ko keys have — and all 62 cases reported OK. The case named for
catching that cannot, because every assertion in it compares the surrogate against the numbers that
built the surrogate. Two floors now live in the test file rather than the manifest, and the same
cases fail rather than SKIP under CI: a missing shape skipped four of the five, and a skip exits 0.
`median_length` and `shortest` are exempt — they move with the language, not with the strength of a
claim — and the exemption is declared, so a structural number added later is ratcheted by default.

### Absent as bytes is not the same as uncitable

`absent` proves a BYTE STRING is not in the corpus. That is exactly true and half an answer:
`Input Port:` is absent from all 24 corpora and Logic ships `Input Port` — measured 2026-09-20, it
is in `strings/en` and in no other — so adding a colon proves anything uncitable. Three literals on the control-surface branch were proved absent that way and
all three are shipped labels.

So each corpus carries a second digest set, `absence/<source>.<locale>.folded.u32`, over the same
values with decoration removed — ellipsis, colon, bullet, dash, underscore, every kind of space.
`absent` then says NOT PROVEN when the bytes are missing but a shipped label folds to them, and
names the string to `locate`. Case is deliberately NOT folded: runtime matching is
case-insensitive, so `Go To Position` against Logic's `Go to Position` still matches on screen and
is not this defect. Folding case made the check fire 33 times, of which 3 were real.

It REFUSES, and what makes that possible is a table rather than a judgement.
`DECORATION-RULES.json` says which trailing punctuation each KIND of control may carry that Logic's
tables do not: an ellipsis on a menu item that opens a dialog, a colon after a field name. Neither
is a convention somebody remembered — each rule cites live AX evidence and a self-test asserts the
example is really in the file it names (522 readings of the ellipsis, 2,631 of the colon).

A LabelSet's own NAME says which kind it is: `setLocatorsMenuItem`, `controlSurfaceInputPortLabel`.
A name declaring nothing gets the default, which allows none — so the cost of adding punctuation is
naming what draws it, and nobody is asked to adjudicate the same question twice. `variants` are
exempt throughout: they are deliberate tolerance and being absent from Apple's data is the point of
them.

So `absent` means *not in this corpus*, never *not in Logic*. Two consequences worth stating:

- an absence claim over English used to be the weakest proof the system could produce, because
  English lives in `Base.lproj` nibs rather than in `.strings` overlays — measured: of the 162
  tables whose labels live in a nib, **zero** ship an `en.lproj` file. `nibstrings` (#895) reads
  them, keyed the way their own translations are keyed, so English is now cited at the same address
  as its Korean. What remains uncovered is the other direction of the same fact: 1,007 nibs are not
  base-internationalised at all, their labels are plain `NSString` mixed with Interface Builder's
  defaults, and no filter over them has been measured;
- the one live AXHelp value this repository cannot cite is most plausibly an AppKit string, and
  that plausibility is recorded as unverified rather than as a finding.

### Why the absence set is 32 bits

Proving presence needs one entry. Proving **absence** needs all of them, which is the expensive
direction and the one people skip — "I looked and it wasn't there" is not a proof anyone can re-run.

A 32-bit prefix collides, and the collision fails in the safe direction: it can make an absent
string look **present**, which refuses the absence claim and sends a person back to a machine with
Logic on it. It can never make a present string look absent, which would let a hand-typed string
masquerade as uncitable. The rate is in `MANIFEST.json` — worst case 1.2 × 10⁻⁵ — rather than left
for the reader to assume it is zero.

### Two ratchets over one population, measured

`docs/canon/WITHOUT-CANON.json` and `docs/observations/RATCHETS.json` overlap, and so do
`docs/canon/POLICY-LITERALS.json` and the ledger's `undocumented_variants`. The overlap is measured
rather than denied:

```
RATCHETS.schema_v1_records (schema < 2)   is a strict SUBSET of WITHOUT-CANON.json (schema < 3)
undocumented_variants ∩ POLICY-LITERALS `nowhere`   ≈ 30 of 42
```

They are kept apart because they answer different questions — *has this record caught up to the
current schema* versus *is this string in Logic's data* — and merging them would make one number
stand for two debts that close by different work. What this repository warns against is a second
copy of the truth, and the honest position is that this is close to one: shrinking either list does
not shrink the other, and nobody has yet written which shrinks first. That is a debt, and it is
recorded here rather than in nobody's head.

## Sighting and citation are not the same claim

A **sighting** is a row in a record: somebody saw this string on screen. A **citation** is a
reference into Logic's own data: Apple ships this string. Neither retires the other, and they can
disagree in both directions:

- a string can be in Logic's data and never reach the interface — measured: the live UI shows
  untranslated `German` and `MIDI Region` although ko translations for both keys exist;
- a string can reach the interface with no file behind it — measured: one live AXHelp value is in
  no file of the bundle.

Where they disagree, **neither wins automatically.** The rule is that the disagreement is recorded,
because a rule that picked a winner would have to pick it before anyone looked.

## Citing

```
logic-canon://<source>/<unit>/<locale>/<key>#<field>
```

```jsonc
"canon": [
  {"ref": "logic-canon://quickhelp/QuickHelp/ko/KCE_024_Record#composed",
   "value": "녹음 버튼. 선택한 트랙 또는 녹음 준비된 여러 트랙에 녹음합니다.",
   "used_for": "the key the AXHelp parser returns for the transport record button"}
]
```

```jsonc
"canon_absent": [
  {"claim": "the window zoom button's AXHelp has no canonical source",
   "strings": ["이 버튼을 누르면 윈도우를 확대/축소합니다."],
   "searched": [{"source": "quickhelp", "locale": "ko"}, {"source": "strings", "locale": "ko"}],
   "why_runtime": "an exhaustive byte scan of all 75,535 bundle files in three encodings found it nowhere; it is most likely drawn from AppKit inside the dyld shared cache, which is not a file this corpus can hold"}
]
```

## Where it is enforced

| where | what runs | what happens when it refuses |
|---|---|---|
| files in the tree | `Scripts/check-canon-citations.py`, discovered and run by `run-repo-guards.py` in `ci.yml`'s macOS `test` job | the job fails; `build` needs it, so the merge is blocked |
| the files a pull request touches | the same script with `--changed pr-changed.txt`, in `pr-policy.yml` | `pr-policy` is a required context, so the merge is blocked |
| a pull request body | the same script with `--text pr-body.md --changed pr-changed.txt`, in `pr-policy.yml` | the same |
| issue bodies | `Scripts/canon_issue_bot.py`, run by `canon-issue.yml` on `issues: [opened, edited]` | **nothing is blocked.** It leaves one advisory note and edits that same note as the body changes |

The pull-request row named a `canon-citations-in-the-pull-request` job until #950 moved the body
check into `pr-policy.yml`; the job is gone and the requirement is not. The issue row said
"nothing checks an issue mechanically yet" until #951.

A pull request body is not a file, so the tree-wide sweep could not see it — and the two documents
a change is actually reviewed through were exempt from the rule they carry. That is the
named-site / enforcement-site gap in its usual shape, and it is why rule 11 exists.

### The opt-out

A body that asserts nothing about Logic writes this sentence, with the reason:

> states no fact about Logic

Deliberately a sentence rather than a checkbox, because a checkbox is ticked without reading — and
deliberately **not** printed in `.github/pull_request_template.md`, because the first version of
that template shipped it pre-typed and every untouched template passed. A sentence the template
types for you is a sentence nobody meant.

It is refused in two cases, both derived rather than declared:

- the change edits a **Logic-facing path** (`Sources/LogicProMCP/{Accessibility,HostParameters,Channels}/`,
  `docs/{observations,locale,canon}/`, `Scripts/livekit/`) — what a change says about itself does
  not decide whether it states a fact about Logic; what it touches does;
- the sentence appears only where a reader is not shown it as prose: a code block, an HTML
  comment, a footnote or a `<pre>`. Text a reader does not see, or sees as an example, cannot carry
  a promise, and code blocks and comments were both used against this check before it looked.

A Logic-facing change that has nothing to cite because its evidence is behaviour does not need the
opt-out: it names the `canon_not_applicable` record it adds, under the conditions given in *If you
are opening an issue or a pull request*.

## The bindings — "was it actually used?"

A reference that resolves proves the quote is Apple's text. It does not prove anything in the
change rests on it, which is the other half of the requirement. So every citation declares where
the value lands, and the value must literally be there:

```jsonc
"binding": {"kind": "code", "path": "Sources/.../X.swift"}   // the file must contain it
"binding": {"kind": "record"}                                // this record must, outside `canon`
```

The first version of this had no bindings at all, and a citation could be decorative: correct
digest, correct quote, and no line of code or reading that had anything to do with it.

## The threat model, stated rather than implied

This is a **consistency** control, not a security control, and it cannot become one while its root
of trust is a file in the tree.

| adversary | what this stops |
|---|---|
| an honest author who errs | nearly everything: a misquoted value, an unpinned reference, a malformed one, a schema-2 record, an edited index, a truncated absence set, a literal Logic does not ship |
| an author routing around the rule | some of it. The opt-out is derived from the diff, the waiver lists are compared against the merge base, and the classification is committed — but a determined author has more room than an honest one |
| a committer acting in bad faith | **out of scope, by decision.** `MANIFEST.json` digests the index and the absence sets and is itself a tracked file, so write access is enough to forge all three consistently — review 2026-09-15 did it in three edits. Signing the artefacts would close that for a leaked credential, and it was built and then removed as over-engineering for a repository with one maintainer. The assumption is written here rather than defended. |
| a fork pull request | **no more than any other branch, and this row used to claim otherwise.** `ci.yml` triggers on `pull_request` and none of its checkouts pins a `ref:`, so the guards that run are the PULL REQUEST HEAD's own copies — a fork rewrites them exactly as a branch does. Measured 2026-09-19 by reading the workflow. What a fork cannot do is push to `main`; that is a different protection and it is the `non_fast_forward` and `deletion` rules, not this axis |

`verify_index_against_absence` and the absence entry counts raise the cost of an accident rather
than of an attack, which is what they are for: a wrong row needs the TSV, the binary absence set
and `MANIFEST.json` to agree, instead of one text edit.

**Three is the cost of adding a row, not the cost of every forgery, and this paragraph used to say
three flatly.** Review 2026-09-19 replaced the CONTENTS of `absence/strings.es.u32` — keeping only
the prefixes the cited `es` rows need, randomising the rest, and keeping the entry count at the
47926 the manifest records — then refreshed the manifest's `artifacts` digest. TWO files, every
guard green, and `is_absent("strings", "es", "Editar")` flipped from False to True for a string
Logic ships. The count ratchet compares a number and the digest compares the bytes that same edit
rewrote, so nothing looked at the contents. Nothing offline can: an entry nobody has cited has no
row to check it against, which is the bound `verify_index_against_absence` states above.

And a row can be MINTED without knowing Apple's text. `short_digest` is twelve hex while the
absence sets store the first eight, so a value whose leading eight hex collide with any committed
prefix passes `verify_index_against_absence`, and the prefixes are a public list — the `.u32` files
are in the tree. The search is bounded by the size of that list against a 32-bit space, which for a
set this size is minutes of computation. "Offline you can VERIFY a claimed value but not READ one"
is true and is half the sentence; the other half is that the digests bind a claim to the committed
artefacts, never to Apple.

`.github/CODEOWNERS` names an owner for `docs/canon/` and — measured 2026-09-15 — **does nothing**:
the branch ruleset has `require_code_owner_review: false` and `required_approving_review_count: 0`.
That is the right setting for a solo maintainer, who cannot approve their own pull request, and it
means CODEOWNERS is a statement of ownership rather than a control. Said here rather than left to
look like one.

What the gate actually proves is that **a quoted value matches a previously committed digest**.
Nothing here verifies the artefacts came from Logic: only `build`, on a machine with Logic, ever
touches Apple's bytes, and what CI sees is the result of a build it cannot re-run.

That is worth having. It makes the class of error that produced `再生ヘッド位置` against
`再生ヘッドの位置` impossible to commit by accident, which is the error this repository actually
makes. It is not a proof that Apple shipped the string.

## What this does **not** check

That a citation is the **right** one, and that a binding's occurrence is the one that matters.

A reference resolving with the right digest proves the quote is Apple's text under that key. It
does not prove that key describes the control the change is about. A binding proves the value is
in the file; a value sitting in a comment satisfies it. Closing that second gap needs the binding
to name a symbol AND the build to confirm the symbol carries the value — a different and much
heavier rule. `used_for` is required and is read by a person.

This is the same trust boundary `docs/observations/SCHEMA.md` already names for sightings, and
moving it would take a citation that says what the value is used *for* in a form a machine can
check against the code. That is worth building and is not built.

## Commands

```
Scripts/logic_canon.py build              # needs Logic. Re-pins everything.
Scripts/logic_canon.py status             # has the installed Logic drifted from the pin?
Scripts/logic_canon.py resolve <ref>      # what value does this reference name?
Scripts/logic_canon.py check <ref>=<val>  # does this quote hold, offline?
Scripts/logic_canon.py absent <src> <loc> <text>
Scripts/logic_canon.py axhelp             # reverse live AXHelp readings into keys, from stdin
Scripts/check-canon-citations.py          # the gate. Runs in CI.
```

## When Logic updates

`MANIFEST.json` pins a digest over every corpus byte. `logic_canon.py status` compares it to the
installed Logic and fails on drift. Rebuild, and every citation whose digest moved fails loudly —
which is the point: a citation that silently still "resolves" after Apple changed the string is
exactly the failure this axis exists to end.
