import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

private final class AXMouseHelperRecorder: @unchecked Sendable {
    var mouseEvents: [(type: CGEventType, point: CGPoint, clickCount: Int64)] = []
    var keyEvents: [CGKeyCode] = []
    var unicodeEvents: [UniChar] = []
    var sleeps: [useconds_t] = []

    func runtime() -> AXMouseHelper.Runtime {
        AXMouseHelper.Runtime(
            postMouseEvent: { type, point, clickCount in
                self.mouseEvents.append((type, point, clickCount))
                return true
            },
            postKeyEvent: { keyCode in
                self.keyEvents.append(keyCode)
                return true
            },
            postUnicodeScalar: { scalar in
                self.unicodeEvents.append(scalar)
                return true
            },
            sleepMicros: { micros in
                self.sleeps.append(micros)
            }
        )
    }
}

@Test func axMouseHelperDoubleClickUsesTwoClickCountsWithoutPostingRealEvents() {
    let recorder = AXMouseHelperRecorder()
    let point = CGPoint(x: 12, y: 34)

    AXMouseHelper.doubleClick(at: point, runtime: recorder.runtime())

    #expect(recorder.mouseEvents.count == 4)
    #expect(recorder.mouseEvents.map(\.type) == [
        .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp,
    ])
    #expect(recorder.mouseEvents.map(\.clickCount) == [1, 1, 2, 2])
    #expect(recorder.mouseEvents.allSatisfy { $0.point == point })
    #expect(recorder.sleeps == [40_000])
}

@Test func axMouseHelperClickUsesSingleDownUpPairWithoutPostingRealEvents() {
    let recorder = AXMouseHelperRecorder()
    let point = CGPoint(x: 56, y: 78)

    let posted = AXMouseHelper.click(at: point, runtime: recorder.runtime())

    #expect(posted)
    #expect(recorder.mouseEvents.count == 2)
    #expect(recorder.mouseEvents.map(\.type) == [.leftMouseDown, .leftMouseUp])
    #expect(recorder.mouseEvents.map(\.clickCount) == [1, 1])
    #expect(recorder.mouseEvents.allSatisfy { $0.point == point })
    #expect(recorder.sleeps == [20_000])
}

@Test func axMouseHelperNumericTypingSkipsUnsupportedCharactersAndPostsReturnEscape() {
    let recorder = AXMouseHelperRecorder()
    let runtime = recorder.runtime()

    AXMouseHelper.typeNumericString("12x.-", runtime: runtime)
    AXMouseHelper.pressReturn(runtime: runtime)
    AXMouseHelper.pressEscape(runtime: runtime)

    #expect(recorder.keyEvents == [0x12, 0x13, 0x2F, 0x1B, 0x24, 0x35])
    #expect(recorder.sleeps == [15_000, 15_000, 15_000, 15_000])
}

@Test func axMouseHelperTextTypingInjectsUnicodeScalars() {
    let recorder = AXMouseHelperRecorder()

    AXMouseHelper.typeText("A한", runtime: recorder.runtime())

    #expect(recorder.unicodeEvents == [65, 54620])
    #expect(recorder.sleeps == [12_000, 12_000])
}

@Test func axMouseHelperTextTypingPreservesSupplementaryUnicodeScalars() {
    let recorder = AXMouseHelperRecorder()

    AXMouseHelper.typeText("🎹", runtime: recorder.runtime())

    #expect(recorder.unicodeEvents == [0xD83C, 0xDFB9])
    #expect(recorder.sleeps == [12_000, 12_000])
}

@Test func axMouseHelperKeyboardEventsCarryExplicitFlagsAndClearChordState() throws {
    let source = try #require(CGEventSource(stateID: .combinedSessionState))
    let chordFlags: CGEventFlags = [.maskControl, .maskShift]
    let chord = try #require(AXMouseHelper.Runtime.keyboardEvents(
        source: source,
        keyCode: 0x0E,
        flags: chordFlags,
        clearModifiersAfter: true
    ))
    let bare = try #require(AXMouseHelper.Runtime.keyboardEvents(
        source: source,
        keyCode: 0x2E,
        flags: CGEventFlags(rawValue: 0)
    ))

    #expect(chord.down.flags == chordFlags)
    #expect(chord.up.flags == chordFlags)
    #expect(chord.modifierClear?.flags == CGEventFlags(rawValue: 0))
    #expect(bare.down.flags == CGEventFlags(rawValue: 0))
    #expect(bare.up.flags == CGEventFlags(rawValue: 0))
    #expect(bare.modifierClear == nil)
}
