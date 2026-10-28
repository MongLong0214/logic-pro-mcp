# Review requirements

This file is the repository-owned project input for automated independent review. Review the
exact candidate commit that supplied these bytes; a working tree, newer branch tip, prior review,
or producer summary is not a substitute.

A review may apply this policy only when the runner preserves its exact bytes and revision together
with the exact base and head. File presence, a prompt reference, or a model statement that it read
the file is not delivery evidence.

- Apply the change-type evidence matrix in [CONTRIBUTING.md](CONTRIBUTING.md). The required checks
  follow actual impact, not a file extension or directory name.
- Apply the citation and observation boundaries in [the canon guide](docs/canon/README.md). A
  protocol-only change does not invent a native observation. A native behavior claim needs the
  applicable exact-build, fixture, action, and independent readback evidence.
- State each actionable finding with its reachable failure condition, exact candidate evidence,
  expected and actual behavior, violated contract, affected consumer, and closure condition.
- Classify a finding as an introduced regression, an existing in-contract defect, an unrelated
  pre-existing issue, or an evidence gap. Do not turn an unrelated old issue, style preference,
  naming preference, or speculative future feature into a correctness blocker.
- Missing required evidence remains an evidence gap; it is not a PASS and not proof of a product
  defect. Tests, citations, digest-shaped strings, and producer assertions prove only what their
  own boundaries establish.
- A repair or dispute does not self-certify closure. Re-run the applicable verification and obtain
  fresh independent review of the current candidate before treating a finding as resolved.
- Resolve disagreement through the existing bounded independent evidence path. If the required
  evidence remains incomplete at its limit, finish unsuccessfully rather than request a human
  tie-breaker, risk waiver, or unverified PASS.

