import Foundation
import Testing
@testable import LogicProMCP

/// ADR-006 asks for bounded per-client subscription queues. There are no queues at all, and the
/// consequence is the opposite shape from the unbounded growth the ADR anticipates: a slow
/// subscriber holds the poller, and the next cycle cannot start.
///
/// That claim spans three awaits in three types, and this suite pins each link separately because
/// no single seam sees the whole chain:
///
///   StatePoller.finishPoll   ->  awaits its `postPoll` callback
///   LogicProServer           ->  wires that callback to the notifier
///   ResourceUpdateNotifier   ->  awaits `notify(uri)` per subscribed URI
///
/// Two earlier versions of this suite were unsound, in ways worth keeping written down.
///
/// The first compared **durations**: one poller with a slow `postPoll` against one with an empty
/// one, asserting the difference exceeded half the injected delay. It failed on `origin/main` under
/// full-suite load measuring `slow - fast = -0.347s` — the wrong sign. A poll costs about a second
/// here and varies by more than the injected signal, so the comparison was noise.
///
/// The second counted **cycle/postPoll overlaps** under the running loop. That removed the
/// stopwatch but kept three problems: it asserted "no cycle can begin while postPoll is in flight",
/// which is false in general — actors are re-entrant, and a concurrent `refreshNow` starts a cycle
/// during `postPoll` — it calibrated a 2s subscriber cost against one machine's ~1.1s cycle, so a
/// slower machine would stop catching the mutant, and its fixed 8s window could fail unchanged code
/// by completing too few cycles.
///
/// What follows uses no calibrated durations. Each test blocks the downstream step on a gate that
/// is never opened until the assertion has been made, so the "it waits" direction cannot complete
/// no matter how slow the machine is. Only the refuted direction needs a margin, and it is one the
/// work has already finished by.
@Suite("Issue289PostPollCoupling")
struct Issue289PostPollCouplingTests {

    /// Generous, and deliberately not calibrated to anything: in the awaited design no amount of
    /// waiting lets the call return, because the gate downstream is still shut. It only has to
    /// exceed the time a *non*-waiting implementation needs to return, and that work is already
    /// complete by the time the gate is reached.
    private static let settleWindow = Duration.seconds(1)

    @Test("the poller does not finish its cycle until postPoll returns")
    func pollerAwaitsItsPostPoll() async {
        let entered = Gate()
        let release = Gate()
        let returned = Flag()

        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { true }),
            postPoll: { _ in
                entered.open()
                await release.wait()
            }
        )

        let refresh = Task { _ = await poller.refreshNow(); returned.set() }
        await entered.wait()
        // postPoll is now inside and cannot progress: `release` stays shut until after the check.
        // So if the refresh has completed, it did not wait for the subscriber.
        try? await Task.sleep(for: Self.settleWindow)

        #expect(!returned.isSet(),
                "refreshNow() completed while postPoll was still blocked, so it did not await it")

        release.open()
        _ = await refresh.value
        #expect(returned.isSet(), "the refresh never completed once postPoll was released")
    }

    @Test("the notifier does not move on until the subscriber's notify returns")
    func notifierAwaitsTheSubscriber() async {
        let registry = ResourceSubscriptionRegistry()
        let uri = "logic://transport/state"
        try? await registry.subscribe(uri: uri)

        let entered = Gate()
        let release = Gate()
        let published = Flag()
        let notifier = ResourceUpdateNotifier(registry: registry)

        // This is the link the previous versions of this suite never touched: they injected their
        // own `postPoll` and so proved only that `StatePoller` awaits *some* callback. Handing off
        // here would remove the slow-subscriber coupling while that assertion stayed green.
        let publish = Task {
            await notifier.publishChangedResources(
                cacheKeys: [.transport],
                cache: StateCache(),
                router: ChannelRouter(),
                notify: { _ in
                    entered.open()
                    await release.wait()
                }
            )
            published.set()
        }

        await entered.wait()
        try? await Task.sleep(for: Self.settleWindow)

        #expect(!published.isSet(),
                "publishChangedResources returned while notify was still blocked")

        release.open()
        await publish.value
        #expect(published.isSet(), "publishing never completed once notify was released")
    }
}

/// A one-shot gate. `open()` is idempotent and `wait()` returns immediately once opened, so neither
/// side has to be scheduled first — the tests do not depend on which task runs when.
private final class Gate: @unchecked Sendable {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    func open() {
        lock.lock()
        guard !isOpen else { lock.unlock(); return }
        isOpen = true
        let parked = waiters
        waiters = []
        lock.unlock()
        for waiter in parked { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

private final class Flag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
