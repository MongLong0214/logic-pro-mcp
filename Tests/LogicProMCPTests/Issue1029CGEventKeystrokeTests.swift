import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// #1029: every keystroke `CGEventChannel.keyMap` posts is the one Apple's Logic Pro User Guide lists
// as the U.S. default preset's binding for the op's function, and an op whose function has no such
// binding posts nothing. `Scripts/check-cgevent-keystrokes-are-apples.py` holds the join against
// Apple's pinned tables; these tests pin the channel's BEHAVIOUR for each keystroke that changed, so
// the value that was there before cannot come back unnoticed. Each case names that value: restoring
// it is the mutation the case kills. Nothing here reads a clock.

private func recordingRuntime(_ recorder: CGEventRecorder) -> CGEventChannel.Runtime {
    CGEventChannel.Runtime(
        isLogicProRunning: { true },
        logicProPID: { 42 },
        postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
        sleepMicros: { _ in }
    )
}

struct CorrectedKeystroke: Sendable, CustomTestStringConvertible {
    let operation: String
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    /// Apple's row, as the pinned table spells it.
    let appleRow: String
    /// The keyMap value before #1029. Restoring it is the mutation this case kills.
    let killsRestoring: String

    var testDescription: String { "\(operation) = \(appleRow); kills \(killsRestoring)" }
}

struct RemovedKeystroke: Sendable, CustomTestStringConvertible {
    let operation: String
    let why: String
    /// The keyMap entry before #1029. Restoring it is the mutation this case kills.
    let killsRestoring: String

    var testDescription: String { "\(operation) posts nothing (\(why)); kills \(killsRestoring)" }
}

@Suite("#1029 CGEvent keystrokes are Apple's U.S. defaults")
struct Issue1029CGEventKeystrokeTests {
    static let corrected: [CorrectedKeystroke] = [
        .init(operation: "transport.play", keyCode: 76, flags: .maskNumericPad,
              appleRow: "Play | keypad Enter", killsRestoring: ".key(49) Space bar = Play or Stop"),
        .init(operation: "transport.stop", keyCode: 82, flags: .maskNumericPad,
              appleRow: "Stop | keypad 0", killsRestoring: ".key(49) Space bar = Play or Stop"),
        .init(operation: "transport.pause", keyCode: 65, flags: .maskNumericPad,
              appleRow: "Pause | keypad Period", killsRestoring: ".key(49) Space bar = Play or Stop"),
        .init(operation: "transport.rewind", keyCode: 43, flags: [],
              appleRow: "Rewind | Comma", killsRestoring: ".key(123) Left Arrow = Select Previous Region"),
        .init(operation: "transport.fast_forward", keyCode: 47, flags: [],
              appleRow: "Forward | Period", killsRestoring: ".key(124) Right Arrow = Select Next Region"),
        .init(operation: "view.toggle_score_editor", keyCode: 45, flags: [],
              appleRow: "Show/Hide Score Editor | N",
              killsRestoring: ".cmdOption(35) Option-Command-P = New Session Player SI Track"),
        .init(operation: "project.close", keyCode: 13, flags: [.maskCommand, .maskAlternate],
              appleRow: "Close Project | Option-Command-W", killsRestoring: ".cmd(13) Command-W = Close Window"),
        .init(operation: "edit.bounce_in_place", keyCode: 11, flags: .maskControl,
              appleRow: "Bounce Regions/Cells in Place | Control-B",
              killsRestoring: ".cmdOption(11) Option-Command-B = Time Stretch Region Length to Nearest Bar"),
    ]

    static let removed: [RemovedKeystroke] = [
        .init(operation: "edit.delete", why: "Apple binds no plain delete command to Delete",
              killsRestoring: "\"edit.delete\": .key(51)"),
        .init(operation: "view.toggle_inspector", why: "no Show/Hide Inspector row; I = Scissors Tool",
              killsRestoring: "\"view.toggle_inspector\": .key(34)"),
        .init(operation: "view.toggle_step_editor", why: "no Show/Hide Step Editor row",
              killsRestoring: "\"view.toggle_step_editor\": .cmdOption(34)"),
        .init(operation: "track.create_drummer", why: "no New Drummer Track row; Option-Command-Z = Toggle Individual Track Zoom",
              killsRestoring: "\"track.create_drummer\": .cmdOption(6)"),
        .init(operation: "project.new", why: "its chain is [.accessibility]; Command-N is New from Template",
              killsRestoring: "\"project.new\": .cmd(45)"),
        .init(operation: "project.save_as", why: "its chain is [.accessibility]; a keystroke cannot carry the path",
              killsRestoring: "\"project.save_as\": .cmdShift(1)"),
        .init(operation: "edit.quantize", why: "Q applies the quantize value Logic holds; a keystroke cannot carry the requested grid",
              killsRestoring: "\"edit.quantize\": .key(12)"),
        .init(operation: "nav.create_marker", why: "its chain is [.accessibility]; Create Marker is Option-Apostrophe",
              killsRestoring: "\"nav.create_marker\": .cmdOption(39)"),
    ]

    @Test("a corrected op posts exactly Apple's key and modifiers", arguments: corrected)
    func correctedOpPostsApplesKeystroke(_ entry: CorrectedKeystroke) async {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: recordingRuntime(recorder))
        let result = await channel.execute(operation: entry.operation, params: [:])
        #expect(result.isSuccess, "\(result.message)")
        let events = recorder.snapshot()
        #expect(events.count == 1)
        #expect(events.first?.keyCode == entry.keyCode, "\(entry.operation) must post \(entry.appleRow)")
        #expect(events.first?.flags == entry.flags, "\(entry.operation) must post \(entry.appleRow)")
    }

    @Test("an op whose function Apple binds to no key posts nothing and says so", arguments: removed)
    func removedOpPostsNothing(_ entry: RemovedKeystroke) async {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: recordingRuntime(recorder))
        let result = await channel.execute(operation: entry.operation, params: [:])
        #expect(!result.isSuccess)
        #expect(result.message.contains("No keyboard shortcut mapped"), "\(result.message)")
        #expect(recorder.snapshot().isEmpty, "\(entry.operation) posted a keystroke: \(entry.why)")
    }

    /// Kills: a keyMap entry for an op whose routing chain never reaches `.cgEvent`, as
    /// project.new, project.save_as and nav.create_marker carried before #1029. Such an entry is
    /// dead unless someone later adds the channel to the chain, and then it fires unreviewed.
    @Test("every keyMap op is one the router can hand to CGEvent")
    func everyKeyMapOpIsReachable() {
        let unreachable = CGEventChannel.keyMap.keys
            .filter { !(ChannelRouter.routingTable[$0] ?? []).contains(.cgEvent) }
            .sorted()
        #expect(unreachable.isEmpty, "keyMap entries no routing chain reaches: \(unreachable)")
    }
}
