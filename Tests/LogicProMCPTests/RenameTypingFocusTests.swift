import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

/// `logic_tracks rename` types the new name through Track > Rename Track one code unit at a time.
/// Measured on Logic 12.3.1 (German UI): a rename to "MCP Test" left the name at "MCP T" and the
/// track soloed with the editor open. A key that reaches Logic outside the rename field is a key
/// command, so typing may continue only while the focus reads as text editing.
///
/// Every test here drives `typeRenameName` with a scripted focus reading and a recording runtime:
/// no AX element is read, no CGEvent is posted, and Logic is not involved.
private final class RenameKeyRecorder: @unchecked Sendable {
    var keyEvents: [CGKeyCode] = []
    var unicodeEvents: [UniChar] = []
    var sleeps: [useconds_t] = []
    /// When set, the post of the code unit at this position fails and nothing is recorded for it.
    var failingPost: Int?
    /// When set, posting this key code fails and nothing is recorded for it.
    var failingKey: CGKeyCode?

    func runtime() -> AXMouseHelper.Runtime {
        AXMouseHelper.Runtime(
            postMouseEvent: { _, _, _ in true },
            postKeyEvent: { keyCode in
                if keyCode == self.failingKey { return false }
                self.keyEvents.append(keyCode)
                return true
            },
            postUnicodeScalar: { scalar in
                if self.failingPost == self.unicodeEvents.count { return false }
                self.unicodeEvents.append(scalar)
                return true
            },
            sleepMicros: { micros in
                self.sleeps.append(micros)
            }
        )
    }

    var typed: String { String(utf16CodeUnits: unicodeEvents, count: unicodeEvents.count) }
}

private let textField = AccessibilityChannel.LogicKeyboardFocus.textEditing(
    role: kAXTextFieldRole as String, byInsertionPoint: false
)
private let returnKey: CGKeyCode = 0x24
private let escapeKey: CGKeyCode = 0x35

private func stateOf(_ result: ChannelResult) -> (state: String?, json: [String: Any]) {
    let json = (try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any] ?? [:]
    return (json["state"] as? String, json)
}

@Test func renameTypingStopsWhereTheFocusLeavesTheFieldAndPostsNothingAfter() throws {
    let recorder = RenameKeyRecorder()

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test",
        focus: { recorder.unicodeEvents.count < 5 ? textField : .notTextEditing },
        mouseRuntime: recorder.runtime()
    )

    #expect(outcome == .textFocusLost(sentCodeUnits: 5, focus: .notTextEditing))
    #expect(recorder.typed == "MCP T")
    #expect(!recorder.keyEvents.contains(returnKey))
    #expect(!recorder.keyEvents.contains(escapeKey))
    #expect(recorder.keyEvents.isEmpty)

    let result = AccessibilityChannel.renameTypingFailure(
        outcome, baseExtras: ["track": 3, "requested": "MCP Test"], observed: "MCP T"
    )
    let (state, json) = stateOf(result)
    #expect(!result.isSuccess)
    #expect(state == "C")
    #expect(state != "A")
    #expect(json["precondition"] as? String == "text_focus_lost")
    #expect(json["sent_code_units"] as? Int == 5)
    #expect(json["observed"] as? String == "MCP T")
    let attempted = try #require(json["write_attempted"] as? Bool)
    #expect(attempted)
}

@Test func aFailedPostStopsTheTypingAndCountsOnlyThePostsThatWentThrough() throws {
    // #1103 review R2: the count was taken before each post, so a post that failed was counted.
    let recorder = RenameKeyRecorder()
    recorder.failingPost = 2

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test", focus: { textField }, mouseRuntime: recorder.runtime()
    )

    #expect(outcome == .postFailed(sentCodeUnits: 2))
    #expect(recorder.typed == "MC")
    #expect(recorder.keyEvents.isEmpty)

    let result = AccessibilityChannel.renameTypingFailure(
        outcome, baseExtras: ["track": 3, "requested": "MCP Test"], observed: "MC"
    )
    let (state, json) = stateOf(result)
    #expect(state == "C")
    #expect(json["error"] as? String == "ax_write_failed")
    #expect(json["precondition"] as? String == "key_post_failed")
    #expect(json["sent_code_units"] as? Int == 2)
    #expect(json["keyboard_focus"] is NSNull)
}

@Test func renameTypingPostsNothingWhenTheFieldNeverTakesTheFocus() throws {
    let recorder = RenameKeyRecorder()

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test",
        focus: { .notTextEditing },
        mouseRuntime: recorder.runtime(),
        focusWaitAttempts: 4,
        focusWaitMicros: 1
    )

    #expect(outcome == .textFocusNotReached(.notTextEditing))
    #expect(recorder.unicodeEvents.isEmpty)
    #expect(recorder.keyEvents.isEmpty)
    #expect(recorder.sleeps == [1, 1, 1])

    let result = AccessibilityChannel.renameTypingFailure(
        outcome, baseExtras: ["track": 3, "requested": "MCP Test"], observed: "Inst. 4"
    )
    let (state, json) = stateOf(result)
    #expect(!result.isSuccess)
    #expect(state == "C")
    #expect(json["precondition"] as? String == "text_focus_not_reached")
    #expect(json["sent_code_units"] as? Int == 0)
    let notAttempted = try #require(json["write_attempted"] as? Bool)
    #expect(!notAttempted)
}

@Test func renameTypingWaitsForTheFieldThenTypesTheWholeNameAndOneReturn() {
    let recorder = RenameKeyRecorder()
    var reads = 0

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test",
        focus: {
            reads += 1
            return reads < 3 ? .notTextEditing : textField
        },
        mouseRuntime: recorder.runtime(),
        focusWaitMicros: 1
    )

    #expect(outcome == .typed)
    #expect(recorder.typed == "MCP Test")
    #expect(recorder.keyEvents == [returnKey])
}

@Test func renameTypingKeepsTheExistingTypingPathWhenTheFocusHolds() {
    let recorder = RenameKeyRecorder()

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test", focus: { textField }, mouseRuntime: recorder.runtime()
    )

    #expect(outcome == .typed)
    #expect(recorder.typed == "MCP Test")
    #expect(recorder.keyEvents == [returnKey])
    #expect(recorder.keyEvents.filter { $0 == returnKey }.count == 1)
    #expect(!recorder.keyEvents.contains(escapeKey))
}

@Test func renameTypingWithholdsReturnWhenTheFocusLeavesAfterTheLastCharacter() {
    let recorder = RenameKeyRecorder()

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test",
        focus: { recorder.unicodeEvents.count < 8 ? textField : .notTextEditing },
        mouseRuntime: recorder.runtime()
    )

    #expect(outcome == .textFocusLost(sentCodeUnits: 8, focus: .notTextEditing))
    #expect(recorder.typed == "MCP Test")
    #expect(recorder.keyEvents.isEmpty)
}

@Test(arguments: AccessibilityChannel.LogicKeyboardFocus.UnreadableStage.allCases)
func anUnreadableFocusWhileWaitingStopsAtOnceEvenIfTheFieldWouldTakeIt(
    stage: AccessibilityChannel.LogicKeyboardFocus.UnreadableStage
) {
    // #1103 review R2, F1: the wait retried an unreadable reading, so unreadable then a text field
    // typed the whole name and Return.
    let recorder = RenameKeyRecorder()
    var readings: [AccessibilityChannel.LogicKeyboardFocus] = [.unreadable(stage), textField]

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test",
        focus: { readings.count > 1 ? readings.removeFirst() : readings[0] },
        mouseRuntime: recorder.runtime(),
        focusWaitAttempts: 5,
        focusWaitMicros: 1
    )

    #expect(outcome == .textFocusNotReached(.unreadable(stage)))
    #expect(recorder.unicodeEvents.isEmpty)
    #expect(recorder.keyEvents.isEmpty)
}

@Test func aFailedReturnIsNotATypedName() throws {
    // #1103 review R2, F2: the Return post's result was discarded.
    let recorder = RenameKeyRecorder()
    recorder.failingKey = returnKey

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test", focus: { textField }, mouseRuntime: recorder.runtime()
    )

    #expect(outcome == .postFailed(sentCodeUnits: 8))
    #expect(recorder.typed == "MCP Test")
    #expect(recorder.keyEvents.isEmpty)
    let (state, json) = stateOf(AccessibilityChannel.renameTypingFailure(
        outcome, baseExtras: [:], observed: "Track 1"
    ))
    #expect(state == "C")
    #expect(json["precondition"] as? String == "key_post_failed")
    #expect(json["sent_code_units"] as? Int == 8)
}

@Test(arguments: AccessibilityChannel.LogicKeyboardFocus.UnreadableStage.allCases)
func renameTypingFailsClosedWhenTheFocusNeverReads(
    stage: AccessibilityChannel.LogicKeyboardFocus.UnreadableStage
) {
    let recorder = RenameKeyRecorder()

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test",
        focus: { .unreadable(stage) },
        mouseRuntime: recorder.runtime(),
        focusWaitAttempts: 3,
        focusWaitMicros: 1
    )

    #expect(outcome == .textFocusNotReached(.unreadable(stage)))
    #expect(recorder.unicodeEvents.isEmpty)
    #expect(recorder.keyEvents.isEmpty)

    let (state, json) = stateOf(AccessibilityChannel.renameTypingFailure(
        outcome, baseExtras: [:], observed: nil
    ))
    #expect(state == "C")
    #expect(json["keyboard_focus"] as? String == "unreadable_\(stage)")
}

@Test(arguments: AccessibilityChannel.LogicKeyboardFocus.UnreadableStage.allCases)
func renameTypingStopsWhenTheFocusTurnsUnreadableMidName(
    stage: AccessibilityChannel.LogicKeyboardFocus.UnreadableStage
) {
    let recorder = RenameKeyRecorder()

    let outcome = AccessibilityChannel.typeRenameName(
        "MCP Test",
        focus: { recorder.unicodeEvents.count < 3 ? textField : .unreadable(stage) },
        mouseRuntime: recorder.runtime()
    )

    #expect(outcome == .textFocusLost(sentCodeUnits: 3, focus: .unreadable(stage)))
    #expect(recorder.typed == "MCP")
    #expect(recorder.keyEvents.isEmpty)
}
