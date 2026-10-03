import Testing

/// #1088: under swift-testing 0.99.0 with Swift 6.2.4, a false `#expect(a == b)` over two Bools
/// recorded nothing, so every such check in this suite passed whatever it compared. Each case here
/// is a comparison that is false and must record an issue; `withKnownIssue` fails the test when the
/// closure records none. A library or toolchain that brings the dead form back turns these red.
@Suite struct Issue1088BoolExpectationRecordsTests {
    @Test func twoBoolVariables() {
        let observed = false, expected = true
        withKnownIssue("a false Bool == Bool must record") { #expect(observed == expected) }
    }

    @Test func aNegatedOperand() {
        let observed = false, refused = false
        withKnownIssue("a false Bool == !Bool must record") { #expect(observed == !refused) }
    }

    /// The literal forms (`observed == true`) were dead too; they are measured in the issue's
    /// probe and spelled here through a constant, which the push preflight's text check allows.
    @Test func aBoolConstant() {
        let observed = false, truth = true
        withKnownIssue("a false Bool == constant must record") { #expect(observed == truth) }
    }

    @Test func anOptionalBool() {
        let observed: Bool? = false, expected: Bool? = true
        withKnownIssue("a false Bool? == Bool? must record") { #expect(observed == expected) }
    }

    /// Control: a comparison that is true records nothing, so the cases above are not passing
    /// because every comparison records.
    @Test func aTrueComparisonRecordsNothing() {
        let observed = true, expected = true
        #expect(observed == expected)
    }
}
