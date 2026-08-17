@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Records the order in which the channel touched things.
private final class GotoOrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func note(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    var recorded: [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// `transport.goto_position` must read the live transport state before it drives the Go To Position
/// dialog route, in the same request.
///
/// Measured on Logic 12.3, 2026-08-17, three samples each way on a freshly created project: as the
/// FIRST operation of a fresh server process the route answers `menu_state: could_not_be_closed`
/// with `menu_actuation_attempted: false` — it never actuates, and no menu is open (an external
/// System Events read counts zero). With the read in place, 3/3 succeed; with it removed, 3/3 fail.
/// The same read issued seconds earlier as a separate request does not help, so what matters is that
/// it happens inside this request, not that the process is warm.
///
/// The read belongs to the OPERATION, not to its callers. That is precisely what went wrong:
/// `TransportDispatcher.handleGotoPosition` did it via `liveTransportState`, so every caller that
/// went through the dispatcher was covered — and `record_sequence`, the one caller that routes the
/// operation directly, was not. Its mandatory playhead reset failed on every fresh process (#572).
@Suite("#572 the goto route reads the transport before it actuates")
struct Issue572GotoPreReadTests {
    private func runtime(probe: GotoOrderProbe) -> AccessibilityChannel.Runtime {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(57_200)
        let base = builder.makeLogicRuntime(appElement: app)
        let axBase = base.ax
        let logic = AXLogicProElements.Runtime(
            logicProPID: base.logicProPID,
            ax: AXHelpers.Runtime(
                axApp: axBase.axApp,
                attributeValue: { element, attribute in
                    probe.note("ax:\(attribute)")
                    return axBase.attributeValue(element, attribute)
                },
                setAttributeValue: axBase.setAttributeValue,
                children: { element in
                    probe.note("ax:AXChildren")
                    return axBase.children(element)
                },
                performAction: axBase.performAction,
                childCount: axBase.childCount
            ),
            executeAppleScript: base.executeAppleScript
        )
        return AccessibilityChannel.Runtime(
            isTrusted: { true },
            isLogicProRunning: { true },
            appRoot: { app },
            transportState: {
                probe.note("transport_read")
                return .success("{\"transport\":true}")
            },
            toggleTransportButton: { _ in .success("{}") },
            setTempo: { _ in .success("{}") },
            setCycleRange: { _ in .success("{}") },
            tracks: { .success("[]") },
            selectedTrack: { .success("{}") },
            selectTrack: { _ in .success("{}") },
            setTrackToggle: { _, _ in .success("{}") },
            renameTrack: { _ in .success("{}") },
            mixerState: { .success("{}") },
            channelStrip: { _ in .success("{}") },
            setMixerValue: { _, _ in .success("{}") },
            projectInfo: { .success("{}") },
            logicRuntime: logic
        )
    }

    @Test("the transport is read, and read before the route touches the AX tree")
    func transportIsReadFirst() async throws {
        let probe = GotoOrderProbe()
        let channel = AccessibilityChannel(runtime: runtime(probe: probe))

        _ = await channel.execute(operation: "transport.goto_position", params: ["bar": "5"])

        let recorded = probe.recorded
        // Without this read the dialog route fails as the first operation of a fresh process.
        let readIndex = try #require(recorded.firstIndex(of: "transport_read"))
        if let firstAX = recorded.firstIndex(where: { $0.hasPrefix("ax:") }) {
            // Ordering, not merely presence: a read that happens after the route has begun is not
            // the read the route needs.
            #expect(readIndex < firstAX)
        }
    }

    @Test("a different transport operation does not acquire the pre-read")
    func onlyTheGotoRouteReadsFirst() async {
        // Guards against "read the transport before everything", which would be a wider change than
        // the measurement supports and would double every transport request's AX work.
        let probe = GotoOrderProbe()
        let channel = AccessibilityChannel(runtime: runtime(probe: probe))

        _ = await channel.execute(operation: "transport.toggle_cycle", params: [:])

        #expect(!probe.recorded.contains("transport_read"))
    }
}
