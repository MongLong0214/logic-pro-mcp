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

    @Test func aBoolLiteral() {
        let observed = false
        withKnownIssue("a false Bool == true must record") { #expect(observed == true) }
    }

    @Test func anOptionalBool() {
        let observed: Bool? = false
        withKnownIssue("a false Bool? == true must record") { #expect(observed == true) }
    }

    /// Control: a comparison that is true records nothing, so the cases above are not passing
    /// because every comparison records.
    @Test func aTrueComparisonRecordsNothing() {
        let observed = true, expected = true
        #expect(observed == expected)
    }
}
