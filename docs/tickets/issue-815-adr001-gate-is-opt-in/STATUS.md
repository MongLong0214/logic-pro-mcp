# Issue 815 — the ADR-001 gate is opt-in, and no repository variable can turn it on

Issue: [#815](https://github.com/MongLong0214/logic-pro-mcp/issues/815) — holds R-REL, R-MATRIX, R-MUT, R-PROV
Blocks: [#284](https://github.com/MongLong0214/logic-pro-mcp/issues/284) (ADR-001), and [#816](https://github.com/MongLong0214/logic-pro-mcp/issues/816) depends on this landing first
Size: **S for the eight edits, because they are seven deletions and one rewrite — and the ticket is M because the honest part is what the edits do NOT buy, which has to be written down or the next reader thinks four debts closed.**

Status: **specified, not implemented.**

## 1. The clause that fails, measured

`pinnedTrustedVerifierStep(in:)` is a chain of `guard … else { return nil }`, so it cannot say which
clause failed. It fails on this one, in `blockingStep` (`ProductionReadinessContracts.swift:155`):

```swift
guard stepScalar("continue-on-error", in: body) == nil,
      stepScalar("if", in: body) == nil,
      stepScalar("shell", in: body) == nil,
```

and `release.yml` carries **seven** steps with an `if`:

```
186  193  198  222  282  289  294      if: ${{ vars.ADR001_QUALIFICATION_ENFORCED == 'true' }}
```

**Setting `ADR001_QUALIFICATION_ENFORCED=true` does not satisfy the checker.** It rejects the
PRESENCE of `if`, never evaluating its expression. So the gate is opt-in in a way no repository
variable can switch on, and the four debts are asserted open on every CI run because seven steps are
conditional rather than because anything about them is wrong.

**An eighth failure**, independent of the seven. The checker demands an exact line list
(`:268`-`:270`):

```swift
let expectedManifestLines = ["shasum -a 256 \\"]
    + artifactFiles.map { "\($0) \\" }
    + ["> release-artifacts.sha256"]
```

and `release.yml:231-250` builds the list conditionally instead:

```bash
files=( LogicProMCP … SHA256SUMS.txt )
# qualification-evidence/* exists only when the ADR-001 gate is enforced …
if [ -d qualification-evidence ]; then
  files+=( qualification-evidence/… )
fi
shasum -a 256 "${files[@]}" > release-artifacts.sha256
```

The comment states the intent: evidence is included "only when present so a deferred-gate release
still succeeds". That is the same opt-in, expressed in bash — evidence files disappear from the
manifest silently rather than failing.

**What would change if this reading were wrong.** I checked it twice, because my first check said
zero: a `grep` with broken shell quoting returned no matches and I was one sentence from calling the
diagnosis a fabrication. The counts above come from `grep -c 'vars.ADR001_QUALIFICATION_ENFORCED =='`
and the line numbers from `grep -n`. If those seven lines are not there, this ticket is void.

## 2. The change, exact

**Seven deletions.** At `release.yml` lines 186, 193, 198, 222, 282, 289, 294, delete exactly:

```diff
-        if: ${{ vars.ADR001_QUALIFICATION_ENFORCED == 'true' }}
```

There is no replacement. The steps become mandatory, which is what a gate is.

**One rewrite.** `release.yml:231-250`, keeping `run: |` at 230:

```yaml
          shasum -a 256 \
            LogicProMCP \
            LogicProMCP-macOS-universal.tar.gz \
            LogicProMCP-macOS-arm64.tar.gz \
            RELEASE-METADATA.json \
            SHA256SUMS.txt \
            qualification-evidence/release-qualification-attestation.json \
            qualification-evidence/evidence-manifest.json \
            qualification-evidence/case-manifest.json \
            qualification-evidence/public-transcript.json \
            qualification-evidence/mutation-restore-compensation.json \
            > release-artifacts.sha256
```

Missing evidence now fails the step instead of vanishing from the required set.

## 3. Acceptance criteria that can fail

1. `grep -c 'vars.ADR001_QUALIFICATION_ENFORCED ==' .github/workflows/release.yml` returns **0**.
2. `productionReadinessContractsAreSatisfiedOnCurrentTree` pins exactly `[R-PUB, R-SEM]` — the
   assertion flip the contract test exists to force. It currently pins six.
3. The release workflow, run end to end, reaches `Create GitHub Release` with the evidence files
   present. **A workflow that satisfies the parser and not the runner is the failure this repository
   keeps finding**, and #815's own acceptance says so.
4. With `qualification-evidence/` absent, the manifest step FAILS rather than producing a manifest
   that omits it.

Criterion 3 cannot be met by editing YAML. It requires the qualification run to actually produce a
bundle, which is the work below that this ticket does not do.

## 4. What these edits do NOT buy, and this is the load-bearing section

**The edits repair the contract CHECK. They do not supply the qualification capability.**
`release.yml:174` states plainly that the full same-artifact live matrix and per-operation semantic
coverage do not yet produce a passing signed bundle, and that the runner can emit only a
`not_qualified` skeleton. Deleting the `if` guards makes seven steps mandatory; if they cannot pass,
the release path stops. **That is the correct outcome and it will look like a regression.**

**Two clauses pass without doing what their names say.** Both are the repository's recurring failure
class and both must be recorded rather than silently satisfied:

- `trusted-provenance-verify` (`:310`) is accepted when its script is exactly
  `test -f qualification-evidence/evidence-manifest.json` and `test -n "$TRUSTED_QUALIFICATION_PUBLIC_KEY"`.
  That checks a file exists and a variable is non-empty. **No signature is verified, no producer is
  authenticated, nothing binds the evidence to the candidate.** The step's name overstates its own
  script. The real check may be `trusted-verifier verify` at `:214` and `:301`; establishing that
  requires the verifier at its pinned commit and is not settled here.
- `required-matrix-axes:2` (`:240` demands it, `:205` supplies it) is an `echo`. Printing the string
  runs no matrix and validates no coverage. The checker knows: it attributes runtime enforcement to
  `PromotionGate.requiredCombinations` at `:561`.

**Making the function return non-nil does not close all four debts.** R-MATRIX separately checks a
required-combination count and actual managed fixtures at `:567`, defined outside these two files.
So the honest claim after this ticket is *four debts stop being asserted open for a parser reason*,
not *four debts are closed*.

## 5. Not in scope

- Producing a passing qualification bundle. That is the work, and it is #284/#373.
- Making `trusted-provenance-verify` verify a provenance. Named above so it is on the record; a
  separate ticket, because widening a shared definition while fixing a blocker is how the next
  blocker gets manufactured.
- #816's transparency-bound publication, which depends on this landing.
- Improving the `guard` chain so it can say which clause failed. Tempting while here, and it is a
  different change with a different blast radius — but worth noting that the whole cost of this
  issue was a chain that returns `nil` for eight distinct reasons.

## 6. What this ticket does NOT establish

- That the release path works afterwards. It establishes that the contract checker stops refusing for
  a reason unrelated to the release's content.
- That `trusted-verifier verify` provides the protection its neighbours' names imply. Unread.
- That the seven steps are the only conditional gating. Seven were counted for this variable; there
  are 13 `if:` lines in the file and six belong to the notarisation mode switch, which the checker
  does not inspect because those steps are not the ones it names.
