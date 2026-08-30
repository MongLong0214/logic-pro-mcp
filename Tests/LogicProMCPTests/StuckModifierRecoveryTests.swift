import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

private enum MarkerRemovalError: Error {
    case failed
}

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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lpm-stuck-modifier-\(UUID().uuidString)", isDirectory: true)
    }

    private func markerURL(_ pid: Int32, in directory: URL) -> URL {
        StuckModifierRecovery.markerURL(for: pid, in: directory)
    }

    @Test("markers are owned by their process in both name and payload")
    func markerOwnershipIsPersisted() throws {
        let pid: Int32 = 4_242
        let directory = temporaryDirectory()
        let url = markerURL(pid, in: directory)

        #expect(url.lastPathComponent == "chord-in-flight-4242.json")
        let data = try #require(
            StuckModifierRecovery.encode(keyCode: 14, flags: [.maskControl, .maskShift], pid: pid))
        let marker = try JSONDecoder().decode(StuckModifierRecovery.Marker.self, from: data)
        #expect(marker.pid == pid)
        #expect(marker.flags == CGEventFlags([.maskControl, .maskShift]).rawValue)
    }

    @Test("only a known-dead marker from another process is recoverable")
    func recoveryOwnershipDecisionIsConservative() {
        let selfPID: Int32 = 101
        let own = StuckModifierRecovery.Marker(keyCode: 14, flags: 0, pid: selfPID)
        let live = StuckModifierRecovery.Marker(keyCode: 14, flags: 0, pid: 102)
        let dead = StuckModifierRecovery.Marker(keyCode: 14, flags: 0, pid: 103)

        #expect(!StuckModifierRecovery.shouldRecover(
            marker: own, isAlive: { _ in false }, selfPID: selfPID))
        #expect(!StuckModifierRecovery.shouldRecover(
            marker: live, isAlive: { _ in true }, selfPID: selfPID))
        #expect(StuckModifierRecovery.shouldRecover(
            marker: dead, isAlive: { _ in false }, selfPID: selfPID))
    }

    @Test("nothing is owed when no chord was in flight")
    func noMarkerPostsNothing() {
        // The case that runs on every ordinary start. A recovery that posted here would fire while
        // a user is genuinely holding Shift, which is the reason this is a marker and not a blind
        // clear — `CGEventSource.flagsState` reports the combined state and cannot say who set it.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var posted: [CGKeyCode] = []
        let result = StuckModifierRecovery.recoverIfNeeded(
            in: directory,
            selfPID: 101,
            isAlive: { _ in false },
            post: { posted.append($0); return true }
        )
        #expect(result.isEmpty)
        #expect(posted.isEmpty, "a start with no marker posted \(posted)")
    }

    @Test("an armed chord that never disarmed is cleared on the next start")
    func armedThenInterruptedIsRecovered() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selfPID: Int32 = 101
        let livePID: Int32 = 102
        let deadPID: Int32 = 103
        let ownURL = markerURL(selfPID, in: directory)
        let liveURL = markerURL(livePID, in: directory)
        let deadURL = markerURL(deadPID, in: directory)
        StuckModifierRecovery.arm(keyCode: 12, flags: .maskControl, at: ownURL, pid: selfPID)
        StuckModifierRecovery.arm(keyCode: 13, flags: .maskControl, at: liveURL, pid: livePID)
        StuckModifierRecovery.arm(keyCode: 14, flags: [.maskControl, .maskShift], at: deadURL, pid: deadPID)

        var posted: [CGKeyCode] = []
        let result = StuckModifierRecovery.recoverIfNeeded(
            in: directory,
            selfPID: selfPID,
            isAlive: { $0 == livePID },
            post: { posted.append($0); return true }
        )

        #expect(result == [14])
        #expect(posted == [14], "the orphaned key-up was not posted")
        #expect(FileManager.default.fileExists(atPath: ownURL.path),
                "a process must retain its own in-flight marker")
        #expect(FileManager.default.fileExists(atPath: liveURL.path),
                "a live process must retain its in-flight marker")
        #expect(!FileManager.default.fileExists(atPath: deadURL.path),
                "an orphaned marker survived its own recovery and will fire again next start")
    }

    @Test("a completed chord owes nothing")
    func armThenDisarmLeavesNothing() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pid: Int32 = 103
        let url = markerURL(pid, in: directory)
        StuckModifierRecovery.arm(keyCode: 14, flags: [.maskControl, .maskShift], at: url, pid: pid)
        StuckModifierRecovery.disarm(at: url)

        var posted: [CGKeyCode] = []
        let result = StuckModifierRecovery.recoverIfNeeded(
            in: directory,
            selfPID: 101,
            isAlive: { _ in false },
            post: { posted.append($0); return true }
        )
        #expect(result.isEmpty)
        #expect(posted.isEmpty)
    }

    @Test("recovery runs once, even if the post itself brings the process down")
    func theMarkerIsRemovedBeforeThePost() {
        // The marker is removed BEFORE posting on purpose. If it were removed after, a crash inside
        // the post would leave the file behind and every subsequent launch would try again — a
        // recovery that repeats a keystroke on every start is worse than the state it recovers.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pid: Int32 = 103
        let url = markerURL(pid, in: directory)
        StuckModifierRecovery.arm(keyCode: 14, flags: .maskControl, at: url, pid: pid)
        var gone = false
        let result = StuckModifierRecovery.recoverIfNeeded(
            in: directory,
            selfPID: 101,
            isAlive: { _ in false },
            post: { _ in
                gone = !FileManager.default.fileExists(atPath: url.path)
                return true
            }
        )
        #expect(result == [14])
        #expect(gone, "the marker still existed while the post ran")
    }

    @Test("a marker that cannot be read owes nothing and does not survive")
    func unreadableMarkerIsDiscarded() throws {
        // Garbage in the file is not a reason to post a keystroke, and not a reason to keep trying
        // either. Both halves matter: posting would be acting on nothing, keeping would be a start
        // that never gets clean.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = markerURL(103, in: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        var posted: [CGKeyCode] = []
        let result = StuckModifierRecovery.recoverIfNeeded(
            in: directory,
            selfPID: 101,
            isAlive: { _ in false },
            post: { posted.append($0); return true }
        )
        #expect(result.isEmpty)
        #expect(posted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a failed marker removal never posts a clear")
    func removalThrowLeavesMarkerAndPostsNothing() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = markerURL(103, in: directory)
        StuckModifierRecovery.arm(keyCode: 14, flags: .maskControl, at: url, pid: 103)

        var posted: [CGKeyCode] = []
        let result = StuckModifierRecovery.recoverIfNeeded(
            in: directory,
            selfPID: 101,
            isAlive: { _ in false },
            remove: { _ in throw MarkerRemovalError.failed },
            post: { posted.append($0); return true }
        )
        #expect(result.isEmpty)
        #expect(posted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a marker that remains after removal never posts a clear")
    func removalThatLeavesFilePostsNothing() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = markerURL(103, in: directory)
        StuckModifierRecovery.arm(keyCode: 14, flags: .maskControl, at: url, pid: 103)

        var posted: [CGKeyCode] = []
        let result = StuckModifierRecovery.recoverIfNeeded(
            in: directory,
            selfPID: 101,
            isAlive: { _ in false },
            remove: { _ in },
            post: { posted.append($0); return true }
        )
        #expect(result.isEmpty)
        #expect(posted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a clear that cannot be built and posted is not reported as recovered")
    func failedClearPostIsNotReportedAsRecovered() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = markerURL(103, in: directory)
        StuckModifierRecovery.arm(keyCode: 14, flags: .maskControl, at: url, pid: 103)
        var attempted: [CGKeyCode] = []

        let result = StuckModifierRecovery.recoverIfNeeded(
            in: directory,
            selfPID: 101,
            isAlive: { _ in false },
            post: {
                attempted.append($0)
                return false
            }
        )

        #expect(attempted == [14])
        #expect(result.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("the recovery replays the CLEAR, never the chord")
    func theMarkerCarriesFlagsForDiagnosisOnly() throws {
        // A marker records the flags it was armed with, and the recovery must not put them back.
        // The event it stands in for is the flag-CLEARING key-up; re-asserting Control and Shift
        // would recreate the state this exists to remove.
        let data = try #require(
            StuckModifierRecovery.encode(
                keyCode: 14,
                flags: [.maskControl, .maskShift],
                pid: 103
            ))
        let marker = try JSONDecoder().decode(StuckModifierRecovery.Marker.self, from: data)
        #expect(marker.flags == CGEventFlags([.maskControl, .maskShift]).rawValue,
                "the flags were not recorded, so a reader cannot tell what was held")
        #expect(StuckModifierRecovery.recoveryKeyCode(from: data) == 14)
        #expect(StuckModifierRecovery.recoveryKeyCode(from: Data("{}".utf8)) == nil)
    }

    @Test("the production clear has no flags and retains the chord key code")
    func clearEventNeverReassertsTheChordFlags() throws {
        let keyCode: CGKeyCode = 14
        let event = try #require(StuckModifierRecovery.clearEvent(for: keyCode))

        #expect(event.flags.rawValue == 0)
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode))
    }
}
