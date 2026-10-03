import Testing
@testable import LogicProMCP

/// Comparing an `Optional<Bool>` against `nil` inside `#expect` was dead under swift-testing 0.99.0:
/// it passed in either direction. Measured 2026-08-18, while a four-test suite passed against three
/// separate mutations of the code it was supposed to be covering.
///
/// This suite used to pin the dead form, and said so: *"If this suite goes red, the toolchain has
/// been fixed."* It went red on CI (Xcode 16.4) in #1088's first run, because #1088 moved the pin to
/// swift-testing 6.1.3, where both comparisons record their failure. That run is also the evidence
/// that CI had the dead form under 0.99.0: main's CI passed `#expect(presentFalse == nil)`.
///
/// It now pins the fixed form: each false comparison must record an issue, which `withKnownIssue`
/// checks, and a true one must pass. A library that brings the dead form back turns it red.
@Suite("Optional<Bool> compared to nil inside #expect records its result (#1088)")
struct DeadOptionalBoolComparisonTests {
    private func isAbsent(_ value: Bool?) -> Bool { value == nil }

    @Test("ordinary Swift gets it right")
    func plainSwiftIsCorrect() {
        #expect(isAbsent(nil))
        #expect(!isAbsent(false))
        #expect(!isAbsent(true))
    }

    /// The three comparisons the dead form got wrong. Each false one must record; the true one
    /// must not.
    @Test("inside the macro a false Optional<Bool> comparison records an issue")
    func insideTheMacroItRecords() {
        let presentFalse: Bool? = false
        let presentTrue: Bool? = true
        let absent: Bool? = nil

        withKnownIssue("presentFalse == nil is false") {
            #expect(presentFalse == nil)  // test-integrity:live: #1088 canary, must record
        }
        withKnownIssue("presentTrue == nil is false") {
            #expect(presentTrue == nil)  // test-integrity:live: #1088 canary, must record
        }
        withKnownIssue("absent != nil is false") {
            #expect(absent != nil)  // test-integrity:live: #1088 canary, must record
        }
        #expect(absent == nil)  // test-integrity:live: the true comparison passes
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
