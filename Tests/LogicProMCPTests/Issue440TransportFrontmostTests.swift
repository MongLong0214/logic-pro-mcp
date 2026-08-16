import ApplicationServices
import Foundation
import Testing

@testable import LogicProMCP

/// #440 D at the operation level.
///
/// The frontmost gate was implemented inside `CGEventChannel`, but `transport.goto_position` is
/// served by the AX bar-slider path, which never reaches that channel. Measured on the release
/// artifact: driven with Logic frontmost it lands exactly on the requested bar (2/2), driven from
/// the background it lands somewhere else (observed 3.3.1.1 and 2.3.1.1 for a requested 1.1.1.1) and
/// reports State B. The envelope was honest, but the playhead had already moved — the operation
/// acted before it knew it could.
@Suite("#440 D — transport refuses to act unless Logic owns the keyboard")
struct Issue440TransportFrontmostTests {
    /// A runtime whose AX tree is irrelevant: every test here must refuse or proceed before any AX
    /// element is looked up, so reaching the tree at all is itself the failure.
    private func unusableAXRuntime(
        dialogScriptExecutions: Counter? = nil
    ) -> AXLogicProElements.Runtime {
        return AXLogicProElements.Runtime(
            logicProPID: { 4242 },
            ax: AXHelpers.Runtime(
                axApp: { _ in AXUIElementCreateSystemWide() },
                attributeValue: { _, _ in nil },
                setAttributeValue: { _, _, _ in false },
                children: { _ in [] },
                performAction: { _, _ in false },
                childCount: { _ in 0 }
            ),
            // Stubbed deliberately. Omitting it defaults to the real `AppleScriptChannel`, so this
            // test drove the actual Logic Pro on any machine where Logic was running, and its
            // result depended on whether the dialog route happened to work there. It passed only
            // while that route was broken.
            executeAppleScript: { _ in
                dialogScriptExecutions?.bump()
                // A normal pre-actuation dialog refusal proves the route can safely reach its
                // documented slider refusal without opening a real Logic dialog.
                return .success(#"{"result":"MENU_NOT_FOUND: fixture"}"#)
            }
        )
    }

    /// Counters shared with `@Sendable` seams.
    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    /// The envelope, whichever side it came out of: the gate must be visible on success as well as
    /// on refusal, so a test that only reads errors would miss half the contract.
    private func envelope(_ result: ChannelResult) -> [String: Any]? {
        let payload: String
        switch result {
        case let .error(text): payload = text
        case let .success(text): payload = text
        default: return nil
        }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    @Test("a background Logic that never comes forward is refused, and nothing is actuated")
    func refusesWhenActivationTimesOut() async throws {
        let activations = Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "1"],
            runtime: unusableAXRuntime(),
            isFrontmost: { false },
            activateLogic: { activations.bump(); return true },
            sleepMicros: { _ in }
        )

        let obj = try #require(envelope(result))
        #expect(try #require(obj["frontmost_preparation"] as? String) == "activation_timed_out")
        #expect(!(try #require(obj["write_attempted"] as? Bool)))
        #expect(try #require(obj["safe_to_retry"] as? Bool))
        #expect(activations.value == 1)
    }

    @Test("a refused activation is reported distinctly and still actuates nothing")
    func refusesWhenActivationIsRefused() async throws {
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "1"],
            runtime: unusableAXRuntime(),
            isFrontmost: { false },
            activateLogic: { false },
            sleepMicros: { _ in }
        )

        let obj = try #require(envelope(result))
        #expect(try #require(obj["frontmost_preparation"] as? String) == "activation_refused")
        #expect(!(try #require(obj["write_attempted"] as? Bool)))
    }

    @Test("one frontmost reading is not enough — the window server can be mid-switch")
    func singleObservationDoesNotRelease() async throws {
        let readings = Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "1"],
            runtime: unusableAXRuntime(),
            isFrontmost: { readings.bump(); return readings.value == 1 },
            activateLogic: { true },
            sleepMicros: { _ in }
        )

        // The first reading is true and every later one false, so the gate must never release.
        let obj = try #require(envelope(result))
        #expect(try #require(obj["frontmost_preparation"] as? String) == "activation_timed_out")
    }

    @Test("a frontmost Logic is not refused — the gate lets real work through")
    func frontmostProceedsPastTheGate() async throws {
        let activations = Counter()
        let frontmostReadings = Counter()
        let dialogScriptExecutions = Counter()
        // Mutation this rejects: replace `isFrontmost: isFrontmost` in
        // `gotoPositionViaBarSlider`'s FrontmostGate call with a non-injected false answer. The
        // route then refuses before this runtime's dialog seam and these assertions fail.
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "1"],
            runtime: unusableAXRuntime(dialogScriptExecutions: dialogScriptExecutions),
            isFrontmost: { frontmostReadings.bump(); return true },
            activateLogic: { activations.bump(); return true },
            sleepMicros: { _ in }
        )

        // The AX tree is empty, so this fails further along — but NOT at the gate, and without
        // having activated anything. The early menu failure cannot observe whether a dialog is
        // present, so the current contract refuses later position routes rather than falling
        // through to a global-input fallback. A gate that refused here would block every
        // legitimate call before this terminal safety decision was reached.
        let obj = try #require(envelope(result))
        // This proves both facts the test owns: the gate admitted the dialog route, and its
        // post-gate menu failure stayed terminal with no position write.
        #expect(try #require(obj["frontmost_preparation"] as? String) == "already_frontmost")
        #expect(try #require(obj["state"] as? String) == "C")
        #expect(try #require(obj["error"] as? String) == "ax_write_failed")
        #expect(try #require(obj["dialog_route_outcome"] as? String) == "menu_not_found")
        #expect(try #require(obj["fallback_unsafe"] as? Bool))
        #expect(!(try #require(obj["safe_to_retry"] as? Bool)))
        #expect(obj["position_route"] == nil)
        let writeAttempted = try #require(obj["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(obj["via"] == nil)
        #expect(result.message.contains(#""write_attempted":false"#))
        #expect(activations.value == 0)
        #expect(frontmostReadings.value == FrontmostGate.requiredObservations)
        #expect(dialogScriptExecutions.value == 1)
    }
}

/// The gate is only as good as the question it asks.
///
/// `ProcessUtils.logicIsFrontmost` used to read `NSWorkspace.frontmostApplication`, which is served
/// from a per-process cache that only refreshes while a run loop is running. The MCP server is
/// long-lived and does not run one, so the value goes stale — measured live, after switching from
/// Logic to Finder it kept answering "Logic Pro" while the window server and System Events both said
/// "Finder". Every run of the live gate matrix then reported `already_frontmost` for a backgrounded
/// Logic: the gate waved through precisely the state it exists to refuse.
@Suite("#440 D — the frontmost question is asked of the window server")
struct Issue440FrontmostSourceTests {
    @Test("frontmost is derived from the window server, not from NSWorkspace's cached answer")
    func predicateDoesNotReadNSWorkspaceFrontmostApplication() throws {
        let source = try String(
            contentsOf: installScriptContractRepositoryRootURL()
                .appendingPathComponent("Sources/LogicProMCP/Utilities/ProcessUtils.swift"),
            encoding: .utf8
        )
        let predicate = try #require(
            source.range(of: "logicIsFrontmost: {").map { source[$0.lowerBound...].prefix(400) }
        )
        #expect(!predicate.contains("NSWorkspace.shared.frontmostApplication"))
        #expect(predicate.contains("logicOwnsTheKeyboard"))
        #expect(source.contains("CGWindowListCopyWindowInfo"))
    }
}
