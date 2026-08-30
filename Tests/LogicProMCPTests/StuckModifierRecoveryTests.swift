import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

/// Discussion #458 — a user reported Logic becoming hard to use after running the integration:
/// track volume moving 0.1 dB at a time, tracks and locators not draggable. That is the signature
/// of a held Control during mouse interaction.
///
/// I could not reproduce it in normal use and still cannot. The only way the state appeared was by
/// deliberately omitting the third event of a flagged chord — so these cases do not claim to
/// reproduce that user's cause. They pin the window that omission proved exists: three separate
/// posts, and a process that dies between the second and the third leaves the modifier held.
@Suite("StuckModifierRecovery")
struct StuckModifierRecoveryTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lpm-stuck-modifier-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("chord-in-flight.json")
    }

    @Test("nothing is owed when no chord was in flight")
    func noMarkerPostsNothing() {
        // The case that runs on every ordinary start. A recovery that posted here would fire while
        // a user is genuinely holding Shift, which is the reason this is a marker and not a blind
        // clear — `CGEventSource.flagsState` reports the combined state and cannot say who set it.
        var posted: [CGKeyCode] = []
        let result = StuckModifierRecovery.recoverIfNeeded(at: tempURL()) { posted.append($0) }
        #expect(result == nil)
        #expect(posted.isEmpty, "a start with no marker posted \(posted)")
    }

    @Test("an armed chord that never disarmed is cleared on the next start")
    func armedThenInterruptedIsRecovered() throws {
        // `arm` then no `disarm` is exactly what a process dying between the key-up and the
        // modifier-clear leaves behind.
        let url = tempURL()
        StuckModifierRecovery.arm(keyCode: 14, flags: [.maskControl, .maskShift], at: url)
        #expect(FileManager.default.fileExists(atPath: url.path), "arm wrote nothing")

        var posted: [CGKeyCode] = []
        let result = StuckModifierRecovery.recoverIfNeeded(at: url) { posted.append($0) }
        #expect(result == 14)
        #expect(posted == [14], "the owed key-up was not posted")
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "the marker survived its own recovery and will fire again next start")
    }

    @Test("a completed chord owes nothing")
    func armThenDisarmLeavesNothing() {
        let url = tempURL()
        StuckModifierRecovery.arm(keyCode: 14, flags: [.maskControl, .maskShift], at: url)
        StuckModifierRecovery.disarm(at: url)

        var posted: [CGKeyCode] = []
        #expect(StuckModifierRecovery.recoverIfNeeded(at: url) { posted.append($0) } == nil)
        #expect(posted.isEmpty)
    }

    @Test("recovery runs once, even if the post itself brings the process down")
    func theMarkerIsRemovedBeforeThePost() {
        // The marker is removed BEFORE posting on purpose. If it were removed after, a crash inside
        // the post would leave the file behind and every subsequent launch would try again — a
        // recovery that repeats a keystroke on every start is worse than the state it recovers.
        let url = tempURL()
        StuckModifierRecovery.arm(keyCode: 14, flags: .maskControl, at: url)
        var gone = false
        _ = StuckModifierRecovery.recoverIfNeeded(at: url) { _ in
            gone = !FileManager.default.fileExists(atPath: url.path)
        }
        #expect(gone, "the marker still existed while the post ran")
    }

    @Test("a marker that cannot be read owes nothing and does not survive")
    func unreadableMarkerIsDiscarded() throws {
        // Garbage in the file is not a reason to post a keystroke, and not a reason to keep trying
        // either. Both halves matter: posting would be acting on nothing, keeping would be a start
        // that never gets clean.
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        var posted: [CGKeyCode] = []
        #expect(StuckModifierRecovery.recoverIfNeeded(at: url) { posted.append($0) } == nil)
        #expect(posted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("the recovery replays the CLEAR, never the chord")
    func theMarkerCarriesFlagsForDiagnosisOnly() throws {
        // A marker records the flags it was armed with, and the recovery must not put them back.
        // The event it stands in for is the flag-CLEARING key-up; re-asserting Control and Shift
        // would recreate the state this exists to remove.
        let data = try #require(
            StuckModifierRecovery.encode(keyCode: 14, flags: [.maskControl, .maskShift]))
        let marker = try JSONDecoder().decode(StuckModifierRecovery.Marker.self, from: data)
        #expect(marker.flags == CGEventFlags([.maskControl, .maskShift]).rawValue,
                "the flags were not recorded, so a reader cannot tell what was held")
        #expect(StuckModifierRecovery.recoveryKeyCode(from: data) == 14)

        // And the production post closure is the only place flags could be re-applied. It is
        // exercised by the default argument in `recoverIfNeeded`, which sets `flags` to zero; the
        // observable contract here is that the recovery is identified by key code alone.
        #expect(StuckModifierRecovery.recoveryKeyCode(from: Data("{}".utf8)) == nil)
    }
}
