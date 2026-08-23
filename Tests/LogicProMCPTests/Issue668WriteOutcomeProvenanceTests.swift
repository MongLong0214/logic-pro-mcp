import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import LogicProMCP

/// #668 — the refresh receipt may only report writes it actually observed landing.
///
/// The receipt fix split `poll`'s answer into `readable` and `applied`, so that `refresh_cache`
/// stops reporting `refreshed: true` for a section whose conditional write was refused. That fix
/// routes four of the five sections through the `poll` helper, which derives `applied` from the
/// compare-and-swap return value.
///
/// The fifth — the `readTrackStates()` fast path — bypasses `poll`, and I left the defect alive in
/// it: it discarded the CAS result with `_ =` and constructed `PollOutcome(readable: true,
/// applied: true)`. That is the same lie the split exists to remove, surviving in the one branch
/// the refactor did not pass through, on the section most likely to lose a race on a large project.
///
/// Patching that one line would leave the next such branch free to reintroduce it, so this pins the
/// property instead: **inside the poller, a write outcome must be derived, never asserted.**
///
/// The scan is syntax-aware (SwiftParser), so it is not defeated by the words appearing in a
/// comment — which they do, in the very code this guards.
///
/// STATED LIMIT: this is a source-level guard, not a behavioural one. Exercising the fast path
/// needs `AccessibilityChannel.readTrackStates()` to return a value, which needs live Logic —
/// `StatePoller` takes the concrete channel, so there is no seam to fake it in a unit test. What
/// this catches is the defect's syntactic signature at every site in the file, present and future.
/// Both checks were mutation-tested against the pre-fix source and fail on it.
@Suite("Issue668WriteOutcomeProvenance")
struct Issue668WriteOutcomeProvenanceTests {

    private static func pollerSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LogicProMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let poller = repoRoot.appendingPathComponent(
            "Sources/LogicProMCP/State/StatePoller.swift")
        return try String(contentsOf: poller, encoding: .utf8)
    }

    /// Every `PollOutcome(...)` construction, paired with the literal its `applied:` argument was
    /// given — or `nil` when that argument is an expression rather than a literal.
    private static func appliedLiterals(_ source: String) -> [Bool?] {
        final class Walk: SyntaxVisitor {
            var found: [Bool?] = []
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                let callee = node.calledExpression.trimmedDescription
                guard callee.hasSuffix("PollOutcome") else { return .visitChildren }
                for argument in node.arguments where argument.label?.text == "applied" {
                    let literal = argument.expression.as(BooleanLiteralExprSyntax.self)
                    found.append(literal.map { $0.literal.tokenKind == .keyword(.true) })
                }
                return .visitChildren
            }
        }
        let walk = Walk(viewMode: .sourceAccurate)
        walk.walk(Parser.parse(source: source))
        return walk.found
    }

    /// Discard statements (`_ = …`) whose right-hand side is a call carrying an `ifCurrent:`
    /// argument — a compare-and-swap whose verdict was thrown away.
    ///
    /// Matches `SequenceExprSyntax`, not `InfixOperatorExprSyntax`: SwiftParser emits assignments
    /// unfolded, so the folded `InfixOperatorExpr` never appears in a freshly parsed tree. Written
    /// against the folded shape first, this walk returned 0 on a source that plainly contained the
    /// discard — the check could not see its own subject, and only the mutation run exposed it.
    /// `walkIsAimedAtItsSubject` now pins that it can.
    static func discardedCASCount(_ source: String) -> Int {
        final class Walk: SyntaxVisitor {
            var count = 0
            override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
                var elements = Array(node.elements)
                guard elements.count >= 3,
                      elements.removeFirst().is(DiscardAssignmentExprSyntax.self),
                      elements.removeFirst().is(AssignmentExprSyntax.self)
                else { return .visitChildren }
                let rhs = elements.map(\.description).joined()
                if rhs.contains("ifCurrent:") { count += 1 }
                return .visitChildren
            }
        }
        let walk = Walk(viewMode: .sourceAccurate)
        walk.walk(Parser.parse(source: source))
        return walk.count
    }

    @Test("no poll reports a write it did not observe landing")
    func appliedIsNeverAsserted() throws {
        let source = try Self.pollerSource()
        let literals = Self.appliedLiterals(source)

        // Guard the guard: if `PollOutcome` is ever renamed, this walk silently finds nothing and
        // passes vacuously. A rule that cannot see its subject is not a rule.
        #expect(!literals.isEmpty, "found no PollOutcome construction — has the type been renamed?")

        // `applied: false` is fine: `.unreadable` is a genuine "nothing was read, so nothing
        // landed". `applied: true` is the defect — a claim about a write whose CAS was not read.
        let asserted = literals.filter { $0 == true }.count
        #expect(asserted == 0,
                "\(asserted) PollOutcome(s) hardcode applied: true; it must come from the CAS")
    }

    @Test("no compare-and-swap verdict is discarded inside the poller")
    func casVerdictsAreNotDiscarded() throws {
        let source = try Self.pollerSource()

        // The subject must exist, or this passes for the wrong reason.
        #expect(source.contains("ifCurrent:"), "no conditional write found — has the CAS moved?")

        let discarded = Self.discardedCASCount(source)
        #expect(discarded == 0,
                "\(discarded) conditional write(s) discard their verdict; the receipt is built from it")
    }

    /// A check that reports 0 because it cannot see is indistinguishable from one that reports 0
    /// because the file is clean — and that is exactly what the first version of `discardedCASCount`
    /// did. This shows the walk firing on the defect and staying quiet on its fix, so a later green
    /// from it means something.
    @Test("the discard walk can actually see a discarded verdict")
    func walkIsAimedAtItsSubject() {
        let defective = """
            func f() async {
                _ = await cache.updateTracks(tracks, ifCurrent: version)
            }
            """
        let fixed = """
            func f() async {
                let applied = await cache.updateTracks(tracks, ifCurrent: version)
            }
            """
        // An unrelated discard must not be counted — the rule is about CAS verdicts, not `_ =`.
        let irrelevant = """
            func f() async {
                _ = await cache.refresh()
            }
            """
        #expect(Self.discardedCASCount(defective) == 1, "did not see the discard it exists to catch")
        #expect(Self.discardedCASCount(fixed) == 0, "flagged a bound result")
        #expect(Self.discardedCASCount(irrelevant) == 0, "flagged a discard that carries no CAS")
    }
}
