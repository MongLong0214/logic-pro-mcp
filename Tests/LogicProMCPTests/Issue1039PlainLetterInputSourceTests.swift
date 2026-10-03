import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// #1029 review R-03 and #1039: under an input source that is not ASCII-capable (2-Set Korean), a
// plain letter key reaches Logic as that source's character and runs nothing; measured live for Q,
// N and X, with and without the event's Unicode string set to the Latin letter. `CGEventChannel`
// refuses such a key and posts nothing unless it can switch to an ASCII-capable layout for it
// (#1039, `Issue1039InputSourceSwitchTests`); the runtimes here offer no layout, so every
// non-ASCII reading refuses. It reads the source after Logic is brought forward, immediately before
// the post (round 3). These tests drive the channel through its input-source probe. Each names the
// mutation it kills. Nothing here reads a clock.

private let korean = CGEventChannel.InputSourceReading(
    id: "com.apple.inputmethod.Korean.2SetKorean", isASCIICapable: false
)
private let abc = CGEventChannel.InputSourceReading(id: "com.apple.keylayout.ABC", isASCIICapable: true)

private func runtime(
    _ recorder: CGEventRecorder,
    source: CGEventChannel.InputSourceReading?
) -> CGEventChannel.Runtime {
    CGEventChannel.Runtime(
        isLogicProRunning: { true },
        logicProPID: { 42 },
        postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
        sleepMicros: { _ in },
        currentInputSource: { source }
    )
}

/// Logic in the background whose activation changes the input source, as macOS's "Automatically
/// switch to a document's input source" does: the source reads `before` until `activateLogic`
/// runs and `after` from then on, and Logic reads frontmost only once it has been activated.
private final class ActivationSwitchesSource: @unchecked Sendable {
    private let lock = NSLock()
    private let before: CGEventChannel.InputSourceReading
    private let after: CGEventChannel.InputSourceReading
    private var activationCount = 0

    init(before: CGEventChannel.InputSourceReading, after: CGEventChannel.InputSourceReading) {
        self.before = before
        self.after = after
    }

    var activations: Int {
        lock.lock()
        defer { lock.unlock() }
        return activationCount
    }

    func runtime(_ recorder: CGEventRecorder) -> CGEventChannel.Runtime {
        CGEventChannel.Runtime(
            isLogicProRunning: { true },
            logicProPID: { 42 },
            postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
            sleepMicros: { _ in },
            isLogicFrontmost: { self.activations > 0 },
            activateLogic: {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.activationCount += 1
                return true
            },
            currentInputSource: { self.activations > 0 ? self.after : self.before }
        )
    }
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
    /// State B comes back), and posting without a layout to switch to.
    @Test("a plain letter under a non-ASCII source with no layout to switch to is refused and nothing is posted", arguments: plainLetterOps)
    func plainLetterRefusedUnderKorean(_ operation: String) async throws {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: runtime(recorder, source: korean))

        let result = await channel.execute(operation: operation, params: [:])

        #expect(!result.isSuccess, "\(operation): \(result.message)")
        #expect(recorder.snapshot().isEmpty, "\(operation) posted \(recorder.snapshot().map(\.keyCode))")
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "C")
        let success = try #require(object["success"] as? Bool)
        #expect(!success)
        #expect(object["error"] as? String == "not_supported")
        #expect(object["reason"] as? String == "input_source_blocks_plain_letters")
        #expect(object["input_source_id"] as? String == korean.id)
        #expect(object["input_source_switch_failure"] as? String == "no_ascii_capable_layout")
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

    /// Round 2, R-03: a source that does not read is refused like a non-ASCII one. Unread is not
    /// ASCII-capable, and the source TIS failed to read may be 2-Set Korean, where the key runs
    /// nothing and the send-only State B would report it as sent.
    /// Kills: an unread source posting again (`guard let source = ... else { refusal }` back to
    /// `if let source = ..., !source.isASCIICapable`), which is mutant `unread-source-posts`.
    @Test("a plain letter under a source that does not read is refused and nothing is posted", arguments: plainLetterOps)
    func plainLetterRefusedWhenTheSourceDoesNotRead(_ operation: String) async throws {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: runtime(recorder, source: nil))

        let result = await channel.execute(operation: operation, params: [:])

        #expect(!result.isSuccess, "\(operation): \(result.message)")
        #expect(recorder.snapshot().isEmpty, "\(operation) posted \(recorder.snapshot().map(\.keyCode))")
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "C")
        let success = try #require(object["success"] as? Bool)
        #expect(!success)
        #expect(object["error"] as? String == "not_supported")
        #expect(object["reason"] as? String == "input_source_unreadable")
        #expect(object["input_source_id"] == nil)
        #expect(object["events_posted"] as? Int == 0)
        let writeAttempted = try #require(object["write_attempted"] as? Bool)
        #expect(!writeAttempted)
    }

    /// Round 3, R-03: Logic in the background, ABC before activation and 2-Set Korean after it.
    /// The key would reach Logic under 2-Set Korean, so it is refused and nothing is posted.
    /// Kills: the source read before `prepareFrontmost()` again (the round-2 order, which reads
    /// ABC and posts), and dropping the read after it (mutant `no-post-activation-read`).
    @Test("a plain letter is refused when activation switches ABC to 2-Set Korean", arguments: plainLetterOps)
    func plainLetterRefusedWhenActivationSwitchesToKorean(_ operation: String) async throws {
        let recorder = CGEventRecorder()
        let focus = ActivationSwitchesSource(before: abc, after: korean)
        let channel = CGEventChannel(runtime: focus.runtime(recorder))

        let result = await channel.execute(operation: operation, params: [:])

        #expect(focus.activations == 1, "\(operation): activated \(focus.activations) times")
        #expect(!result.isSuccess, "\(operation): \(result.message)")
        #expect(recorder.snapshot().isEmpty, "\(operation) posted \(recorder.snapshot().map(\.keyCode))")
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "C")
        let success = try #require(object["success"] as? Bool)
        #expect(!success)
        #expect(object["error"] as? String == "not_supported")
        #expect(object["reason"] as? String == "input_source_blocks_plain_letters")
        #expect(object["input_source_id"] as? String == korean.id)
        #expect(object["events_posted"] as? Int == 0)
        let writeAttempted = try #require(object["write_attempted"] as? Bool)
        #expect(!writeAttempted)
    }

    /// The same setting the other way: 2-Set Korean before activation, ABC after it. The key
    /// reaches Logic as a letter, so it is posted; a reading taken before activation does not
    /// decide.
    /// Kills: the source read before `prepareFrontmost()` again, or a pre-activation read kept
    /// beside the new one and allowed to refuse.
    @Test("a plain letter is posted when activation switches 2-Set Korean to ABC", arguments: plainLetterOps)
    func plainLetterPostedWhenActivationSwitchesToABC(_ operation: String) async throws {
        let recorder = CGEventRecorder()
        let focus = ActivationSwitchesSource(before: korean, after: abc)
        let channel = CGEventChannel(runtime: focus.runtime(recorder))
        let shortcut = try #require(CGEventChannel.keyMap[operation])

        let result = await channel.execute(operation: operation, params: [:])

        #expect(focus.activations == 1, "\(operation): activated \(focus.activations) times")
        #expect(result.isSuccess, "\(operation): \(result.message)")
        #expect(recorder.snapshot().map(\.keyCode) == [shortcut.keyCode])
    }

    /// The unread source refuses plain letters only: a keypad key still posts.
    /// Kills: the unread check moved ahead of `shortcut.isPlainLetter`.
    @Test func plainNonLetterPostedWhenTheSourceDoesNotRead() async throws {
        let recorder = CGEventRecorder()
        let channel = CGEventChannel(runtime: runtime(recorder, source: nil))
        let shortcut = try #require(CGEventChannel.keyMap["transport.play"])

        let result = await channel.execute(operation: "transport.play", params: [:])

        #expect(result.isSuccess, "\(result.message)")
        #expect(recorder.snapshot().map(\.keyCode) == [shortcut.keyCode])
    }

    /// Shift does not keep a letter out of the IME (Shift-Q is ㅃ under 2-Set Korean).
    /// Kills: adding Shift to the modifiers that make a letter "not plain".
    @Test func shiftedLetterIsStillPlain() {
        #expect(CGEventChannel.Shortcut.shift(12).isPlainLetter)
        #expect(CGEventChannel.Shortcut.key(12).isPlainLetter)
        #expect(!CGEventChannel.Shortcut.control(11).isPlainLetter)
    }

    /// Through the real router: `view.toggle_mixer` (chain `[.midiKeyCommands, .cgEvent]`) with
    /// only CGEvent registered, a non-ASCII source and no layout to switch to fails with the
    /// refusal inside it, instead of a send-only success for a key that ran nothing.
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
