import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #440 D — CGEvent must post nothing when Logic is not frontmost
//
// `CGEvent.postToPid` does not guarantee delivery: a keystroke posted while
// Logic is in the background is swallowed by the window server. The channel used
// to post regardless and return a State B "sent" envelope, so a caller was told
// a keystroke had been delivered to an application that never received it.
//
// The fix prepares first and posts nothing when preparation fails. These tests
// assert the property that actually matters — the EVENT COUNT — rather than the
// returned envelope, because an envelope can be made to look right while events
// still leak out. Every case counts real calls into the posting seam.
//
// Both directions are covered. A gate that never posts would be as wrong as one
// that always posts, so the already-frontmost and activated paths are asserted
// to post exactly the events the operation requires.

/// Records every post so a test can assert on the count, and drives frontmost
/// state as a scripted sequence so the mid-switch race can be reproduced.
private final class PostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var posts: [(CGKeyCode, CGEventFlags)] = []
    private var frontmostReadings: [Bool]
    private var activationsRequested = 0
    private let activationSucceeds: Bool
    private let frontmostAfterActivation: Bool

    init(frontmostReadings: [Bool], activationSucceeds: Bool = true, frontmostAfterActivation: Bool = true) {
        self.frontmostReadings = frontmostReadings
        self.activationSucceeds = activationSucceeds
        self.frontmostAfterActivation = frontmostAfterActivation
    }

    var postCount: Int {
        lock.lock(); defer { lock.unlock() }
        return posts.count
    }

    var activationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activationsRequested
    }

    func runtime() -> CGEventChannel.Runtime {
        CGEventChannel.Runtime(
            isLogicProRunning: { true },
            logicProPID: { 4242 },
            postKeyEvent: { [self] code, flags, _ in
                lock.lock(); defer { lock.unlock() }
                posts.append((code, flags))
                return true
            },
            sleepMicros: { _ in },
            isLogicFrontmost: { [self] in
                lock.lock(); defer { lock.unlock() }
                if !frontmostReadings.isEmpty { return frontmostReadings.removeFirst() }
                return frontmostAfterActivation
            },
            activateLogic: { [self] in
                lock.lock(); defer { lock.unlock() }
                activationsRequested += 1
                return activationSucceeds
            }
        )
    }
}

private func refusalReason(_ result: ChannelResult) -> String? {
    guard case let .error(payload) = result,
          let object = sharedJSONObject(payload) else { return nil }
    return object["frontmost_preparation"] as? String
}

@Suite("Issue #440 D — CGEvent frontmost gate")
struct Issue440FrontmostGateTests {
    /// The regression: Logic is in the background and stays there. Nothing may
    /// be posted, and the caller must be told, not handed a "sent" envelope.
    @Test("a mapped shortcut posts zero events when Logic never becomes frontmost")
    func mappedShortcutPostsNothingWhenBackground() async {
        let recorder = PostRecorder(frontmostReadings: [false], frontmostAfterActivation: false)
        let channel = CGEventChannel(runtime: recorder.runtime())

        let result = await channel.execute(operation: "transport.play", params: [:])

        #expect(recorder.postCount == 0, "no event may be created when Logic does not own the keyboard")
        #expect(!result.isSuccess)
        #expect(refusalReason(result) == "activation_timed_out")
    }

    /// The same property on the multi-keystroke path. A sequence that lost the
    /// keyboard halfway would leave a dialog open with a partial value typed in,
    /// so this one matters more than the single chord.
    @Test("a goto_position sequence posts zero events when Logic never becomes frontmost")
    func sequencePostsNothingWhenBackground() async {
        let recorder = PostRecorder(frontmostReadings: [false], frontmostAfterActivation: false)
        let channel = CGEventChannel(runtime: recorder.runtime())

        let result = await channel.execute(
            operation: "transport.goto_position",
            params: ["position": "5.1.1.1"]
        )

        #expect(recorder.postCount == 0, "a partial sequence is worse than none; zero events required")
        #expect(!result.isSuccess)
        #expect(refusalReason(result) == "activation_timed_out")
    }

    /// Activation itself refusing is a distinct outcome and must also post
    /// nothing, rather than falling through to a hopeful post.
    @Test("a refused activation posts zero events and is reported distinctly")
    func refusedActivationPostsNothing() async {
        let recorder = PostRecorder(
            frontmostReadings: [false],
            activationSucceeds: false,
            frontmostAfterActivation: false
        )
        let channel = CGEventChannel(runtime: recorder.runtime())

        let result = await channel.execute(operation: "transport.play", params: [:])

        #expect(recorder.postCount == 0)
        #expect(refusalReason(result) == "activation_refused")
        #expect(recorder.activationCount == 1, "activation is attempted exactly once, not retried blindly")
    }

    /// The gate must release when Logic already owns the keyboard, and must not
    /// activate anything in that case — an unnecessary activation is a visible
    /// window flash for the user.
    @Test("an already-frontmost Logic is not activated and receives the keystroke")
    func alreadyFrontmostPostsWithoutActivating() async {
        let recorder = PostRecorder(frontmostReadings: [true, true])
        let channel = CGEventChannel(runtime: recorder.runtime())

        let result = await channel.execute(operation: "transport.play", params: [:])

        #expect(recorder.postCount == 1, "the mapped chord must actually be delivered")
        #expect(recorder.activationCount == 0, "no activation when Logic already owns the keyboard")
        #expect(result.isSuccess)
    }

    /// Background at first, forward after activation: the whole point of
    /// activating. The sequence must then be delivered in full.
    @Test("a background Logic is activated and then receives the full sequence")
    func activatedThenPostsFullSequence() async {
        let recorder = PostRecorder(frontmostReadings: [false], frontmostAfterActivation: true)
        let channel = CGEventChannel(runtime: recorder.runtime())

        let result = await channel.execute(
            operation: "transport.goto_position",
            params: ["position": "5.1.1.1"]
        )

        #expect(recorder.activationCount == 1)
        let expected = CGEventChannel.gotoPositionSequence(for: "5.1.1.1")?.count
        #expect(recorder.postCount == expected, "every keystroke of the sequence must be delivered")
        #expect(result.isSuccess)
    }

    /// The mid-switch race the two-observation rule exists for: one reading says
    /// frontmost, the next says not. A single-observation gate would post here.
    @Test("a single frontmost reading is not enough to post")
    func oneFrontmostReadingDoesNotRelease() async {
        let recorder = PostRecorder(
            frontmostReadings: [true, false, false],
            activationSucceeds: false,
            frontmostAfterActivation: false
        )
        let channel = CGEventChannel(runtime: recorder.runtime())

        let result = await channel.execute(operation: "transport.play", params: [:])

        #expect(recorder.postCount == 0, "an unstable frontmost observation must not authorise a post")
        #expect(!result.isSuccess)
    }

    /// The gate's own constants must be sane: a single required observation
    /// would reintroduce the race the previous test covers.
    @Test("the gate requires more than one frontmost observation")
    func gateRequiresStableObservation() {
        #expect(CGEventChannel.requiredFrontmostObservations >= 2)
        #expect(CGEventChannel.maximumActivationPolls > 0)
    }
}
