import Foundation
import Testing
@testable import LogicProMCP

// T8 — Tool description must inline-document the `port` selector + 1-based
// channel convention so AI clients reading `tools/list` know the right shape.
// PRD: issue1-keycmd-port-routing AC-10 / §3 US-2 (BREAKING ch index migration)
//
// Background: pre-v3.1.6 the description omitted explicit "1-based" wording,
// causing ch=0 / ch=17 caller errors that surfaced only at validateMidiChannel
// (BREAKING ch index migration in §3.2). The description string is the
// caller's contract; locking it down prevents description/runtime drift.

@Suite("MIDIDispatcher tool description contract")
struct MIDIDispatcherDescriptionTests {

    @Test("description documents `port` selector and 1-based channel range")
    func testToolDescriptionContainsPortAndChannelInfo() {
        let description = MIDIDispatcher.tool.description ?? ""

        // port selector must be inline-documented (BREAKING in v3.1.6 — keycmd
        // routing exposed publicly for the first time).
        #expect(
            description.contains("port:"),
            "MIDIDispatcher.tool.description must mention `port:` selector inline"
        )
        #expect(
            description.contains("\"midi\"") && description.contains("\"keycmd\""),
            "MIDIDispatcher.tool.description must list both `midi` and `keycmd` port values"
        )

        // Channel is 1-based (matches Logic Pro UI display Ch 1..16).
        #expect(
            description.contains("1-based"),
            "MIDIDispatcher.tool.description must state channel is 1-based"
        )
        #expect(
            description.contains("1..16") || description.contains("1-16") || description.contains("1 to 16"),
            "MIDIDispatcher.tool.description must state channel range 1..16"
        )
    }

    @Test("keycmd description is honest without requesting manual setup")
    func testKeycmdDescriptionHasNoManualContinuation() {
        let description = MIDIDispatcher.tool.description ?? ""

        #expect(!description.contains("requires one-time MIDI Learn"))
        #expect(description.contains("no programmatic Logic binding or outcome readback"))
        #expect(description.contains("returns State B without requesting setup"))
    }
}
