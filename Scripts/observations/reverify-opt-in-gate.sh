#!/usr/bin/env bash
# Re-check 2026-09-07-an-opt-in-gate-is-not-a-gate. Offline and read-only.
set -uo pipefail
cd "$(dirname "$0")/../.."
FAIL=0
step() { local l="$1"; shift; if "$@" >/tmp/rv-gate.$$ 2>&1; then printf '  ok   %s\n' "$l"; else FAIL=1; printf '  FAIL %s\n' "$l"; tail -12 /tmp/rv-gate.$$ | sed 's/^/       /'; fi; rm -f /tmp/rv-gate.$$; }

echo "== the diagnosis, pinned in the suite =="
step "seven gate steps skippable; the 'missing' step present; if-guarded steps do not block" \
  swift test --no-parallel --filter 'Issue815OptInGateTests'
step "the open debt set is still what the record describes" \
  swift test --no-parallel --filter 'productionReadinessContractsAreSatisfiedOnCurrentTree'

echo "== the file, read directly =="
N=$(grep -c "if: \${{ vars.ADR001_QUALIFICATION_ENFORCED == 'true' }}" .github/workflows/release.yml)
printf '  %-58s %s\n' "steps behind ADR001_QUALIFICATION_ENFORCED" "$N"
[ "$N" -eq 7 ] || { FAIL=1; echo "  FAIL expected 7"; }
if grep -q 'stepScalar("if", in: body) == nil' Sources/LogicProMCP/Qualification/ProductionReadinessContracts.swift; then
  printf '  %-58s %s\n' "blockingStep still refuses a step with an if" "found"
else FAIL=1; echo "  FAIL blockingStep no longer refuses an if-guarded step"; fi

if ! git diff --quiet -- Package.resolved 2>/dev/null; then git checkout -- Package.resolved; echo "  note Package.resolved restored after the build"; fi
[ "$FAIL" -eq 0 ] || { echo "REVERIFY FAIL"; exit 1; }
echo "REVERIFY PASS — an opt-in gate is still not a gate"
