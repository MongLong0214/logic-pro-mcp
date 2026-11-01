import Foundation
import Testing
@testable import LogicProMCP

struct VirtualMIDIProcessGroupOwnershipTests {
    @Test func bothCreatorErrorsTerminateWithoutARequestedHumanRestart() {
        for message in [MIDIEngineError.ownershipLockHeld(name: "fixture").description,
                        MIDIPortError.ownershipLockHeld(name: "fixture").description] {
            #expect(message.contains("port group"))
            #expect(message.contains("creation terminated"))
            #expect(message.contains("without requesting human intervention"))
            #expect(!message.contains("restart"))
            #expect(!message.contains("stop competing"))
        }
    }

    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        var group = 0, creation = 0, active = 0, peak = 0, releases = 0, groupReleases = 0
        func update<T>(_ body: (Counts) -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body(self)
        }
    }

    @Test func winningProcessRetainsOneGroupAcrossAllPortCreations() {
        let counts = Counts()
        var group: VirtualMIDIEndpointOwnershipLock.ProcessGroup? = .init(acquireGroup: {
            counts.update { $0.group += 1 }
            return .acquired(.testing { counts.update { $0.groupReleases += 1 } })
        }, acquireCreation: {
            counts.update { $0.creation += 1 }
            return .acquired(.testing { counts.update { $0.releases += 1 } })
        })
        for _ in 0..<4 {
            guard case .acquired(let lease) = group?.acquire() else {
                Issue.record("The winning process must admit every channel"); return
            }
            lease.release(); lease.release()
        }
        counts.update {
            #expect($0.group == 1 && $0.creation == 4 && $0.releases == 4)
            #expect($0.groupReleases == 0, "Per-port cleanup must not surrender the process claim")
        }
        group = nil
        #expect(counts.update { $0.groupReleases } == 1)
    }

    @Test(arguments: [false, true])
    func losingOrUnavailableProcessCannotAcquireALaterSubset(unavailable: Bool) {
        let counts = Counts()
        let group = VirtualMIDIEndpointOwnershipLock.ProcessGroup(acquireGroup: {
            let attempt = counts.update { $0.group += 1; return $0.group }
            // A second attempt would win: refusal must remain process-consistent.
            if attempt > 1 { return .acquired(.testing()) }
            return unavailable ? .unavailable("fixture failure") : .held
        }, acquireCreation: {
            counts.update { $0.creation += 1 }; return .acquired(.testing())
        })
        for _ in 0..<4 {
            switch group.acquire() {
            case .held: #expect(!unavailable)
            case .unavailable(let reason): #expect(unavailable && reason == "fixture failure")
            case .acquired: Issue.record("A denied process must not create any port later")
            }
        }
        counts.update { #expect($0.group == 1 && $0.creation == 0) }
    }

    @Test func concurrentChannelsInTheWinningProcessDoNotRejectEachOther() {
        let counts = Counts()
        let group = VirtualMIDIEndpointOwnershipLock.ProcessGroup(acquireGroup: {
            counts.update { $0.group += 1 }; return .acquired(.testing())
        }, acquireCreation: {
            counts.update { $0.creation += 1; $0.active += 1; $0.peak = max($0.peak, $0.active) }
            return .acquired(.testing { counts.update { $0.active -= 1; $0.releases += 1 } })
        })
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            guard case .acquired(let lease) = group.acquire() else {
                Issue.record("Concurrent channels in one owner must serialize, not degrade"); return
            }
            Thread.sleep(forTimeInterval: 0.005)
            lease.release(); lease.release()
        }
        counts.update {
            #expect($0.group == 1 && $0.creation == 8 && $0.releases == 8)
            #expect($0.active == 0 && $0.peak == 1)
        }
    }

    @Test(arguments: [false, true])
    func creationRefusalDoesNotLeakTheLocalGateOrDiscardTheGroup(unavailable: Bool) {
        let counts = Counts()
        let group = VirtualMIDIEndpointOwnershipLock.ProcessGroup(acquireGroup: {
            counts.update { $0.group += 1 }; return .acquired(.testing())
        }, acquireCreation: {
            let attempt = counts.update { $0.creation += 1; return $0.creation }
            if attempt == 1 { return unavailable ? .unavailable("fixture creation failure") : .held }
            return .acquired(.testing())
        })
        switch group.acquire() {
        case .held: #expect(!unavailable)
        case .unavailable(let reason): #expect(unavailable && reason == "fixture creation failure")
        case .acquired: Issue.record("The first creation must preserve its actual refusal")
        }
        guard case .acquired(let lease) = group.acquire() else {
            Issue.record("The owner must release the local gate after a failed creation"); return
        }
        lease.release()
        counts.update { #expect($0.group == 1 && $0.creation == 2) }
    }
}
