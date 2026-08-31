@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// T3 — R16 / AC20: 3-plane through-handler reachability for logic_plugins.
//
// Plane 1 (tool dispatch)     — callTool("logic_plugins", …) must NOT return "Unknown tool".
// Plane 2 (operation routing) — the op must NOT return "Unknown operation" (it IS in the routing table).
// Plane 3 (channel execute)   — AccessibilityChannel.execute must NOT fall to the
//                               "Unsupported AX operation" default; it reaches the
//                               verified implementation (fixture).
//
// The default LogicProServer registers no channels until start(), so the
// handler-level call resolves to channels_exhausted — which proves Plane 1+2
// (the op is registered and routed). Plane 3 is proven by routing through a
// router that has a fake-AX AccessibilityChannel registered.

private func decodeJSONObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}

private func sharedObject(_ result: CallTool.Result) -> [String: Any]? {
    decodeJSONObject(sharedToolText(result))
}

private func sharedObject(_ result: ChannelResult) -> [String: Any]? {
    decodeJSONObject(result.message)
}

// MARK: - Plane 1 + Plane 2 (handler entry → router)

// NOTE: the Plane-1 handler-entry test `testPluginsToolReachesRouterNotUnknownTool`
// lives in VerifiedOpGateTests.swift's @Suite(.serialized) — it drives the shared
// VerifiedOpGate via callTool, so it must be serialized with the other gate tests.

@Test func testPluginsOperationsAreRegisteredInRoutingTable() async {
    // Plane 2: a missing routing-table entry yields "Unknown operation: …".
    // With no channels registered the router returns channels_exhausted — which
    // proves the op IS in the table (it got past the routingTable lookup).
    let router = ChannelRouter()
    for operation in ["plugin.get_inventory", "plugin.set_param_verified", "plugin.set_eq_band_verified", "plugin.insert_verified"] {
        let result = await router.route(operation: operation, params: ["track": "0"])
        let msg = result.message
        #expect(!msg.contains("Unknown operation"), "\(operation): Plane 2 — not in routing table")
    }
}

@Test func testPluginsVerifiedOpsRouteAXOnlyNoFallback() async {
    // R16: verified ops must be AX-only (single-channel chain) so a failure
    // never falls back to Scripter/MCU and fabricates a false verified result.
    for operation in ["plugin.get_inventory", "plugin.set_param_verified", "plugin.set_eq_band_verified", "plugin.insert_verified"] {
        let chain = ChannelRouter.routingTable[operation]
        #expect(chain == [.accessibility], "\(operation) must route through .accessibility alone")
    }
}

// MARK: - Plane 3 (router → channel execute → fixture)

private func makeFakeAXChannel() -> (AccessibilityChannel, FakeAXRuntimeBuilder) {
    let b = FakeAXRuntimeBuilder()
    // Minimal mixer fixture so get_inventory reaches a real strip enumeration.
    let app = b.element(990)
    let window = b.element(991)
    let mixer = b.element(992)
    let strip = b.element(993)
    let emptySlot = b.element(994)
    b.setAttribute(app, kAXMainWindowAttribute as String, window)
    b.setChildren(window, [mixer])
    b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    b.setChildren(mixer, [strip])
    b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setChildren(strip, [emptySlot])
    b.setAttribute(emptySlot, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(emptySlot, kAXDescriptionAttribute as String, "오디오 플러그인")
    b.setAttribute(emptySlot, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")

    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: b.makeLogicRuntime(appElement: app)
    )
    return (AccessibilityChannel(runtime: runtime), b)
}

@Test func testPluginGetInventoryReachesChannelExecute() async {
    let (channel, _) = makeFakeAXChannel()
    // Direct execute — proves the operation case exists (Plane 3). A missing
    // case returns "Unsupported AX operation: …".
    let result = await channel.execute(operation: "plugin.get_inventory", params: ["track": "0"])
    let text = result.message
    #expect(!text.contains("Unsupported AX operation"), "Plane 3 — get_inventory not handled in execute")
    // It reached the real implementation and produced inventory JSON.
    let obj = sharedObject(result)
    #expect(obj?["operation"] as? String == "logic_plugins.get_inventory")
    #expect((obj?["complete"] as? Bool)!)
}

@Test func testPluginSetParamVerifiedReachesChannelExecute() async {
    let (channel, _) = makeFakeAXChannel()
    let result = await channel.execute(operation: "plugin.set_param_verified", params: [
        "track": "0", "insert": "0", "plugin": "Gain", "param": "gain_db",
        "value": "-4.0", "unit": "dB", "mode": "duplicate_applyback",
        "project_expected_path": "/tmp/x.logicx",
    ])
    let text = result.message
    #expect(!text.contains("Unsupported AX operation"), "Plane 3 — set_param_verified not handled in execute")
    // Reaches the R6 precedence (mode/path/identity/preflight) — a real HC v2 envelope.
    let obj = sharedObject(result)
    #expect(obj?["hc_schema"] as? Int == 2)
    #expect(obj?["operation"] as? String == "logic_plugins.set_param_verified")
}

@Test func testPluginSetEQBandVerifiedReachesChannelExecute() async {
    let (channel, _) = makeFakeAXChannel()
    let result = await channel.execute(operation: "plugin.set_eq_band_verified", params: [
        "track": "0", "insert": "0", "band": "Peak 1", "parameter": "Frequency",
        "value": "250", "unit": "raw_ax_value", "mode": "duplicate_applyback",
        "project_expected_path": "/tmp/x.logicx",
    ])
    let text = result.message
    #expect(!text.contains("Unsupported AX operation"), "Plane 3 — set_eq_band_verified not handled in execute")
    let obj = sharedObject(result)
    #expect(obj?["hc_schema"] as? Int == 2)
    #expect(obj?["operation"] as? String == "logic_plugins.set_eq_band_verified")
}

@Test func testPluginInsertVerifiedReachesChannelExecute() async {
    let (channel, _) = makeFakeAXChannel()
    let result = await channel.execute(operation: "plugin.insert_verified", params: [
        "track": "0", "insert": "0", "plugin": "Gain",
        "mode": "duplicate_applyback", "project_expected_path": "/tmp/x.logicx",
    ])
    let text = result.message
    #expect(!text.contains("Unsupported AX operation"), "Plane 3 — insert_verified not handled in execute")
    let obj = sharedObject(result)
    #expect(obj?["hc_schema"] as? Int == 2)
    #expect(obj?["operation"] as? String == "logic_plugins.insert_verified")
}

// MARK: - Full path: router(with AX) → channel → fixture

@Test func testPluginGetInventoryFullRouterToChannelPath() async {
    let (channel, _) = makeFakeAXChannel()
    let router = ChannelRouter()
    await router.register(channel)
    // Router resolves plugin.get_inventory → [.accessibility] → channel.execute
    // → defaultGetPluginInventory → fixture. End-to-end through both router
    // planes and the channel.
    let result = await router.route(operation: "plugin.get_inventory", params: ["track": "0"])
    #expect(result.isSuccess)
    #expect(!result.message.contains("Unknown operation"))
    #expect(!result.message.contains("channels_exhausted"))
    let obj = sharedObject(result)
    #expect(obj?["operation"] as? String == "logic_plugins.get_inventory")
}
