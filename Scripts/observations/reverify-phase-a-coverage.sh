#!/usr/bin/env bash
# Re-check 2026-09-07-phase-a-was-already-done-and-invisible.
#
# Needs Logic running and a release binary: the reading is what the shipped binary does against
# live Logic, and a debug build measured against nothing would answer a different question.
set -uo pipefail
cd "$(dirname "$0")/../.."

[ -x .build/release/LogicProMCP ] || { echo "REVERIFY FAIL: no release binary — run swift build -c release"; exit 1; }
pgrep -x "Logic Pro" >/dev/null || { echo "REVERIFY FAIL: Logic Pro is not running; this reading is of live behaviour"; exit 1; }

PROBE=Tests/LogicProMCPTests/ZZPhaseACoverageReverify.swift
cleanup() { rm -f "$PROBE"; if ! git diff --quiet -- Package.resolved 2>/dev/null; then git checkout -- Package.resolved; fi; }
trap cleanup EXIT

cat > "$PROBE" <<'EOF'
import Foundation
import Testing
@testable import LogicProMCP

@Suite("phase A coverage reverify") struct ZZPhaseACoverageReverify {
    @Test func histogram() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let result = try QualificationTransport().drive(.init(
            executableURL: root.appendingPathComponent(".build/release/LogicProMCP"),
            environment: ProcessInfo.processInfo.environment,
            expectedOperationCount: OperationRegistry.specs.count,
            operations: OperationRegistry.specs
        ))
        var buckets: [String: Int] = [:]
        for op in result.operationResults.values {
            buckets["\(op.mutability)/\(op.status)/\(op.verificationKind)", default: 0] += 1
        }
        for (k, v) in buckets.sorted(by: { $0.key < $1.key }) { print("REVERIFY \(k) = \(v)") }
    }
}
EOF

OUT=$(swift test --no-parallel --filter 'ZZPhaseACoverageReverify' 2>/dev/null | grep '^REVERIFY ')
printf '%s\n' "$OUT" | sed 's/^/  /'

FAIL=0
check() { printf '%s\n' "$OUT" | grep -qF "$1" || { FAIL=1; echo "  FAIL expected: $1"; }; }
check "readOnly/passed/semanticReadback = 21"
check "readOnly/notQualified/typedDeferral = 2"
check "mutating/notQualified/typedDeferral = 90"

[ "$FAIL" -eq 0 ] || { echo "REVERIFY FAIL — the coverage the record describes has moved"; exit 1; }
echo "REVERIFY PASS — 21 of 23 read-only operations pass with semantic readback"
