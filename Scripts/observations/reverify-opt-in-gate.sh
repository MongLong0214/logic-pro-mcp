#!/usr/bin/env bash
# Re-check 2026-09-07-an-opt-in-gate-is-not-a-gate — EXCEPT that it no longer has a subject.
#
# On 2026-09-13 the qualification subsystem was removed: `ProductionReadinessContracts.swift`,
# `Issue815OptInGateTests`, `productionReadinessContractsAreSatisfiedOnCurrentTree`, and the seven
# `ADR001_QUALIFICATION_ENFORCED` steps in `.github/workflows/release.yml` are all gone (measured:
# `grep -c ADR001_QUALIFICATION_ENFORCED .github/workflows/release.yml` = 0).
#
# This file refuses instead of running, because the two things it could otherwise do are both
# false. Reporting PASS would credit a gate that does not exist. Reporting FAIL would say the
# reading MOVED, when what happened is that the thing being read was deleted — and that is the
# failure this repository keeps finding in its own checks: a control that passes, or fails, for a
# reason unrelated to what it claims to measure.
#
# The record stays true about the release workflow as it stood on 2026-09-07. Nothing re-verifies
# it, and that is the honest state until a gate exists again.
set -uo pipefail
echo "CANNOT-REVERIFY(3): the subject was removed on 2026-09-13 — no qualification gate exists to re-read."
exit 3
