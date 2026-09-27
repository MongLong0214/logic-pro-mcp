import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// #1029 review R-03 and #1039: under an input source that is not ASCII-capable (2-Set Korean), a
// plain letter key reaches Logic as that source's character and runs nothing; measured live for Q,
// N and X, with and without the event's Unicode string set to the Latin letter. `CGEventChannel`
// now refuses such a key before it prepares or posts anything. These tests drive the channel
// through its input-source probe. Each names the mutation it kills. Nothing here reads a clock.

private let korean = CGEventChannel.InputSourceReading(
    id: "com.apple.inputmethod.Korean.2SetKorean", isASCIICapable: false
)
private let abc = CGEventChannel.InputSourceReading(id: "com.apple.keylayout.ABC", isASCIICapable: true)

/// Counts the frontmost probe and the activation, so a refusal can show it prepared nothing.
private final class PreparationCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func runtime(
    _ recorder: CGEventRecorder,
    source: CGEventChannel.InputSourceReading?,
    preparation: PreparationCalls = PreparationCalls()
) -> CGEventChannel.Runtime {
    CGEventChannel.Runtime(
        isLogicProRunning: { true },
        logicProPID: { 42 },
        postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
        sleepMicros: { _ in },
        isLogicFrontmost: {
            preparation.record()
            return true
        },
        activateLogic: {
            preparation.record()
            return true
        },
        currentInputSource: { source }
    )
}

private func envelope(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// Every op `keyMap` posts as a letter with no Command, Control or Option. #1039's list names
/// R, C, K, X, P, Y, A, Z, Q, N and I; I (view.toggle_inspector) has no entry on this branch, so it
/// posts nothing under any source.
private let plainLetterOps = [
    "transport.record",            // R
    "transport.toggle_cycle",      // C
    "transport.toggle_metronome",  // K
    "edit.quantize",               // Q
    "view.toggle_mixer",           // X
    "view.toggle_piano_roll",      // P
    "view.toggle_library",         // Y
    "view.toggle_score_editor",    // N
    "nav.zoom_to_fit",             // Z
    "automation.toggle_view",      // A
]

/// Letter keys with Command, Control or Option: the IME does not turn these into its own
/// character (measured: Control-B, Option-Command-W and Command-Z ran under 2-Set Korean).
private let modifiedLetterOps = [
    "edit.undo", "edit.redo", "edit.cut", "edit.copy", "edit.paste", "edit.select_all",
    "edit.split", "edit.join", "edit.bounce_in_place", "project.save", "project.close",
    "track.create_audio", "track.create_instrument", "track.duplicate",
]

/// Plain keys that are not letters (keypad, Comma, Period): measured to run under 2-Set Korean.
private let plainNonLetterOps = ["transport.play", "transport.pause", "transport.rewind", "transport.fast_forward"]

@Suite struct Issue1039PlainLetterInputSourceTests {

    /// Kills: dropping a letter from `Shortcut.letterKeyCodes` (the op drops out of this set), and
    /// a new plain-letter keyMap entry nobody listed as affected.
    @Test func thePlainLetterOpsAreExactlyTheListedOnes() {
        let found = Set(CGEventChannel.keyMap.filter { $0.value.isPlainLetter }.keys)
        #expect(found == Set(plainLetterOps), "plain-letter ops: \(found.sorted())")
    }

    /// Kills: removing the input-source check from `execute` (the key is posted and a send-only
    /// State B comes back), and moving it after `prepareFrontmost()` (Logic is brought forward for
    /// a key that cannot act).
    @Test("a plain letter under a non-ASCII source is refused and nothing is posted", arguments: plainLetterOps)
    func plainLetterRefusedUnderKorean(_ operation: String) async throws {
        let recorder = CGEventRecorder()
        let preparation = PreparationCalls()
        let channel = CGEventChannel(runtime: runtime(recorder, source: korean, preparation: preparation))

        let result = await channel.execute(operation: operation, params: [:])

        #expect(!result.isSuccess, "\(operation): \(result.message)")
        #expect(recorder.snapshot().isEmpty, "\(operation) posted \(recorder.snapshot().map(\.keyCode))")
        #expect(preparation.total == 0, "\(operation) prepared Logic \(preparation.total) times")
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "C")
        #expect(object["error"] as? String == "not_supported")
        #expect(object["reason"] as? String == "input_source_blocks_plain_letters")
        #expect(object["input_source_id"] as? String == korean.id)
        #expect(object["events_posted"] as? Int == 0)
        let writeAttempted = try #require(object["write_attempted"] as? Bool)
        #expect(!writeAttempted)
    }

    /// Kills: refusing whatever the source reads (the `!source.isASCIICapable` clause dropped).
    @Test("a plain letter under ABC is posted", arguments: plainLetterOps)
    func plainLetterPostedUnderABC(_ operation: String) async throws {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: runtime(recorder, source: abc))
        let shortcut = try #require(CGEventChannel.keyMap[operation])

        let result = await channel.execute(operation: operation, params: [:])

        #expect(result.isSuccess, "\(operation): \(result.message)")
        let events = recorder.snapshot()
        #expect(events.count == 1)
        #expect(events.first?.keyCode == shortcut.keyCode)
        #expect(events.first?.flags == shortcut.flags)
    }

    /// Kills: `isPlainLetter` ignoring the flags, which refuses Command-Z and Control-B too.
    @Test("a letter with Command, Control or Option is never refused", arguments: modifiedLetterOps)
    func modifiedLetterPostedUnderKorean(_ operation: String) async throws {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: runtime(recorder, source: korean))
        let shortcut = try #require(CGEventChannel.keyMap[operation])

        let result = await channel.execute(operation: operation, params: [:])

        #expect(result.isSuccess, "\(operation): \(result.message)")
        #expect(recorder.snapshot().first?.keyCode == shortcut.keyCode)
        #expect(recorder.snapshot().first?.flags == shortcut.flags)
    }

    /// Kills: dropping the letter test from `isPlainLetter`, which refuses keypad, Comma and Period.
    @Test("a plain key that is not a letter is never refused", arguments: plainNonLetterOps)
    func plainNonLetterPostedUnderKorean(_ operation: String) async throws {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: runtime(recorder, source: korean))
        let shortcut = try #require(CGEventChannel.keyMap[operation])

        let result = await channel.execute(operation: operation, params: [:])

        #expect(result.isSuccess, "\(operation): \(result.message)")
        #expect(recorder.snapshot().first?.keyCode == shortcut.keyCode)
    }

    /// An unread source is not read as blocking: the key is posted as before.
    /// Kills: treating an unread source as not ASCII-capable (`?.isASCIICapable != true`).
    @Test func plainLetterPostedWhenTheSourceDoesNotRead() async {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: runtime(recorder, source: nil))

        let result = await channel.execute(operation: "edit.quantize", params: [:])

        #expect(result.isSuccess, "\(result.message)")
        #expect(recorder.snapshot().map(\.keyCode) == [12])
    }

    /// Shift does not keep a letter out of the IME (Shift-Q is ㅃ under 2-Set Korean).
    /// Kills: adding Shift to the modifiers that make a letter "not plain".
    @Test func shiftedLetterIsStillPlain() {
        #expect(CGEventChannel.Shortcut.shift(12).isPlainLetter)
        #expect(CGEventChannel.Shortcut.key(12).isPlainLetter)
        #expect(!CGEventChannel.Shortcut.control(11).isPlainLetter)
    }

    /// Through the real router: `view.toggle_mixer` (chain `[.midiKeyCommands, .cgEvent]`) with
    /// only CGEvent registered and a non-ASCII source fails with the refusal inside it, instead of
    /// a send-only success for a key that ran nothing.
    /// Kills: removing the input-source check from `execute`.
    @Test func routerFailsHonestlyWhenCGEventIsTheOnlyRungLeft() async {
        let recorder = CGEventRecorder()
        let router = ChannelRouter()
        await router.register(CGEventChannel(runtime: runtime(recorder, source: korean)))

        let result = await router.route(operation: "view.toggle_mixer")

        #expect(!result.isSuccess, "\(result.message)")
        #expect(result.message.contains("input_source_blocks_plain_letters"), "\(result.message)")
        #expect(recorder.snapshot().isEmpty)
    }
}
