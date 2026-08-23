import Foundation
import Testing
@testable import LogicProMCP

/// #668 — the work closure must be able to see its own deadline.
///
/// `runWithDeadline` computed the budget and never handed it down, so a long operation could not
/// stop early. Cancellation does reach it, but only at the deadline instant — and `DeadlineRace`
/// is first-past-the-post, so by then the timeout owns the continuation and any partial result is
/// discarded. Knowing the budget in advance is what makes stopping early possible at all.
@Suite("Issue668OperationBudget")
struct Issue668OperationBudgetTests {

    @Test("the work closure can read a budget, and it reflects the command's deadline")
    func workSeesItsBudget() async {
        let observed = LockedBox<Duration?>(nil)

        _ = await LogicProServer.runWithDeadline(
            tool: "logic_system",
            command: "refresh_cache",
            deadlineOverride: 5
        ) {
            observed.set(OperationTraceContext.remainingBudget)
            return toolTextResult("{}")
        }

        let budget = observed.get()
        #expect(budget != nil, "the work closure saw no budget at all")
        if let budget {
            // Bound both sides: a budget that is present but wrong is worse than none, because
            // code would act on it. 5s was requested; allow for scheduling but not for a
            // different order of magnitude.
            #expect(budget <= .seconds(5))
            #expect(budget >= .seconds(4))
        }
    }

    @Test("outside a deadline there is no budget, rather than a made-up one")
    func noBudgetOutsideADeadline() {
        #expect(OperationTraceContext.remainingBudget == nil)
    }

    @Test("a budget that has run out reads as zero, never as a negative duration")
    func anExhaustedBudgetClampsToZero() {
        OperationTraceContext.$deadline.withValue(ContinuousClock().now.advanced(by: .seconds(-5))) {
            let budget = OperationTraceContext.remainingBudget
            #expect(budget == .zero, "past the deadline the budget is zero; a negative value would read as plenty")
        }
    }
}

/// Minimal box so the closure can report what it saw without capturing a var.
private final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
