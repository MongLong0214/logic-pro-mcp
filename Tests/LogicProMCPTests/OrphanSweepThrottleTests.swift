import Foundation
import Testing
@testable import LogicProMCP

/// The sweep marker sits at a predictable, uid-derived name in a directory this process does not
/// own, so whatever is there is INPUT. These pin the three ways a hostile or stale entry could
/// change what the server does, each of which an independent review named before it was fixed.
@Suite("the orphan-sweep throttle treats its marker as input")
struct OrphanSweepThrottleTests {
    private func scratchMarker() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpm-sweep-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("marker")
    }

    @Test("a fresh marker suppresses the sweep, and an old one does not")
    func aFreshMarkerSuppressesAndAnOldOneDoesNot() throws {
        let marker = try scratchMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        let now = Date()

        // First call has nothing to read: it claims and sweeps.
        #expect(LogicProServer.orphanSweepIsDue(now: now, markerURL: marker, interval: 3600))
        // Second call, minutes later, reads the claim it just wrote.
        #expect(!LogicProServer.orphanSweepIsDue(now: now.addingTimeInterval(600),
                                                 markerURL: marker, interval: 3600))
        // And an hour on, it is due again.
        #expect(LogicProServer.orphanSweepIsDue(now: now.addingTimeInterval(4000),
                                                markerURL: marker, interval: 3600))
    }

    /// A timestamp AHEAD of now is not a reading about the past. `elapsed < due` alone accepts it
    /// — a negative interval satisfies that comparison forever — and the sweep would never run
    /// again on that machine.
    @Test("a marker stamped in the future does not silence the sweep")
    func aFutureMarkerDoesNotSilenceTheSweep() throws {
        let marker = try scratchMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        let now = Date()
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(86_400)], ofItemAtPath: marker.path)

        #expect(LogicProServer.orphanSweepIsDue(now: now, markerURL: marker, interval: 3600))
    }

    /// Not a regular file this uid owns: the entry is replaced. A directory at that name would
    /// otherwise be read for a modification time and believed.
    @Test("a directory at the marker path is replaced rather than believed")
    func aDirectoryAtTheMarkerPathIsReplaced() throws {
        let marker = try scratchMarker()
        defer { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)

        #expect(LogicProServer.orphanSweepIsDue(now: Date(), markerURL: marker, interval: 3600))
        var info = stat()
        #expect(lstat(marker.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFREG)
    }

    /// A claim that cannot be written means the throttle is not in force. The sweep is skipped
    /// rather than run by every process that starts — this is housekeeping, and the honest failure
    /// direction is to do less of it.
    @Test("an unwritable marker path skips the sweep instead of running it every time")
    func anUnwritableMarkerSkipsTheSweep() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpm-sweep-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        #expect(!LogicProServer.orphanSweepIsDue(now: Date(),
                                                 markerURL: dir.appendingPathComponent("marker"),
                                                 interval: 3600))
    }
}

/// A gate holder the command deadline already abandoned must not keep the background poller out of
/// Logic forever. Reclamation happens inside `tryAcquire`; if no later mutation ever asks, nothing
/// clears the holder, and a poller gated on "is anybody there" would skip every cycle from then on.
@Suite("the mutation gate reports entitlement, not mere occupancy")
struct MutationGateEntitlementTests {
    @Test("a live holder holds the gate")
    func aLiveHolderHoldsTheGate() {
        let gate = LogicMutationGate(staleHolderTTL: 360, timedOutReclaimGrace: 15)
        let now = Date()
        #expect(gate.tryAcquire(operation: "track.record_sequence", now: now) != nil)
        #expect(gate.isHeldByEntitledHolder(now: now.addingTimeInterval(1)))
    }

    @Test("a holder abandoned by the deadline stops holding it once its grace elapses")
    func anAbandonedHolderStopsHoldingItAfterTheGrace() {
        let gate = LogicMutationGate(staleHolderTTL: 360, timedOutReclaimGrace: 15)
        let now = Date()
        let claim = gate.tryAcquire(operation: "transport.goto_position", now: now)
        #expect(claim != nil)
        gate.markTimedOut(claim!, now: now)

        // Inside the grace the abandoned work may still be unwinding, so it still counts.
        #expect(gate.isHeldByEntitledHolder(now: now.addingTimeInterval(5)))
        // Past it, a successor would be let in — so the poller may go back in too.
        #expect(!gate.isHeldByEntitledHolder(now: now.addingTimeInterval(20)))
    }

    @Test("a holder past the stale TTL stops holding it even without a timeout mark")
    func aStaleHolderStopsHoldingIt() {
        let gate = LogicMutationGate(staleHolderTTL: 360, timedOutReclaimGrace: 15)
        let now = Date()
        #expect(gate.tryAcquire(operation: "track.rename", now: now) != nil)
        #expect(gate.isHeldByEntitledHolder(now: now.addingTimeInterval(300)))
        #expect(!gate.isHeldByEntitledHolder(now: now.addingTimeInterval(400)))
    }

    @Test("an empty gate is not held")
    func anEmptyGateIsNotHeld() {
        #expect(!LogicMutationGate().isHeldByEntitledHolder())
    }
}
