import Testing
@testable import LogicProMCP

/// Comparing an `Optional<Bool>` against `nil` **inside** `#expect` does not work on this toolchain,
/// in either direction, and nothing stops you writing it.
///
/// `Scripts/ci-forbid-dead-expect.sh` says so in prose — *"`Optional<Bool> == nil` is dead and must
/// use `#require`"* — but carries no pattern for it, because a textual scanner cannot tell
/// `Optional<Bool>` from `Optional<String>` and this repository has hundreds of the latter where the
/// comparison is perfectly live.
///
/// Measured 2026-08-18, while a four-test suite passed against three separate mutations of the code
/// it was supposed to be covering. The assertions were `== nil` on a `Bool?`; they could not fail.
///
/// The bug is in the macro, not in Swift. `absent != nil` evaluates to `false` in ordinary code and
/// is reported as `true` inside `#expect`. So the fix is not a different operator — it is to compute
/// the comparison OUTSIDE the macro and hand `#expect` a plain `Bool`, which is what the `#448`
/// suite does with its `…WasReported` helpers.
///
/// **If this suite goes red, the toolchain has been fixed** — at which point the guard's prose and
/// the projections written around this bug can be reconsidered. A workaround with no expiry
/// condition outlives its reason.
@Suite("dead: Optional<Bool> compared to nil inside #expect")
struct DeadOptionalBoolComparisonTests {
    /// Computed in ordinary Swift, where the semantics are correct. `#expect` receives a plain
    /// `Bool` and evaluates it faithfully — this is the shape every assertion below relies on, and
    /// the shape callers should use.
    private func isAbsent(_ value: Bool?) -> Bool { value == nil }

    @Test("ordinary Swift gets it right")
    func plainSwiftIsCorrect() {
        #expect(isAbsent(nil))
        #expect(!isAbsent(false))
        #expect(!isAbsent(true))
    }

    /// The same three facts, written the way that looks natural inside the macro. Every one of these
    /// is the OPPOSITE of the truth, and every one passes.
    @Test("inside the macro the comparison is wrong in both directions")
    func insideTheMacroItIsDead() {
        let presentFalse: Bool? = false
        let presentTrue: Bool? = true
        let absent: Bool? = nil

        // Swift says false. The macro says true.
        #expect(presentFalse == nil)  // test-integrity:live: this suite exists to pin the dead form
        #expect(presentTrue == nil)   // test-integrity:live: this suite exists to pin the dead form
        // Swift says false. The macro says true.
        #expect(isMacroInequalityWrong(absent))
    }

    /// `absent != nil` is `false` in Swift. Written inside `#expect` it reports `true`, which is how
    /// the first attempt at a "safe projection" for this bug failed. Kept behind a helper so the
    /// claim is checked rather than asserted.
    private func isMacroInequalityWrong(_ absent: Bool?) -> Bool {
        (absent != nil) == false
    }

    /// Why the guard cannot simply forbid `== nil`: on every other optional type the comparison is
    /// live, and this repository has hundreds of those.
    @Test("the same comparison is live for other optional types")
    func otherOptionalsAreLive() {
        let text: String? = "x"
        let number: Int? = 0

        #expect(!isTextAbsent(text))
        #expect(!isNumberAbsent(number))
    }

    private func isTextAbsent(_ value: String?) -> Bool { value == nil }
    private func isNumberAbsent(_ value: Int?) -> Bool { value == nil }
}
