@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// The same fixture can run on the unmodified base: these tests use the existing channel APIs.
/// Arrange track 9 is Bass, while two aux strips put its Mixer strip at ordinal 11.
private final class ArrangeIndexRegressionFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let mixer: AXUIElement

    init(bassOccupied: Bool) {
        let b = builder
        app = b.element(40_000)
        let window = b.element(40_001)
        let rail = b.element(40_002)
        mixer = b.element(40_003)
        let names = (0..<9).map { "Track \($0)" } + ["Bass"]
        let headers = names.enumerated().map { index, name in
            let header = b.element(40_100 + index)
            b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(header, kAXDescriptionAttribute as String, "1개의 ‘\(name)’ 트랙")
            b.setAttribute(header, kAXSelectedAttribute as String, index == 9)
            return header
        }
        let stripNames = Array(names.prefix(9)) + ["Aux 1", "Aux 2", "Bass"]
        let strips = stripNames.enumerated().map { index, name in
            let base = 41_000 + index * 100
            let strip = b.element(base)
            let field = b.element(base + 1)
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(field, kAXDescriptionAttribute as String, "이름")
            b.setAttribute(field, kAXValueAttribute as String, name)
            let pluginName: String? = index == 9 ? "Compressor"
                : index == 11 && bassOccupied ? "Gain" : nil
            let slot = b.element(base + 2)
            if let pluginName {
                let bypass = b.element(base + 3)
                let open = b.element(base + 4)
                b.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
                b.setAttribute(slot, kAXDescriptionAttribute as String, pluginName)
                b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
                b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
                b.setAttribute(bypass, kAXValueAttribute as String, 0)
                b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
                b.setAttribute(open, kAXDescriptionAttribute as String, "열기")
                b.setChildren(slot, [bypass, open])
            } else {
                b.setAttribute(slot, kAXRoleAttribute as String, kAXButtonRole as String)
                b.setAttribute(slot, kAXDescriptionAttribute as String, "오디오 플러그인")
                b.setAttribute(slot, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
            }
            b.setAttribute(slot, kAXPositionAttribute as String, axPoint(100 + CGFloat(index) * 80, 300))
            b.setAttribute(slot, kAXSizeAttribute as String, axSize(58, 16))
            b.setChildren(strip, [field, slot])
            return strip
        }
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(rail, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(rail, kAXDescriptionAttribute as String, "트랙 헤더")
        b.setAttribute(mixer, kAXRoleAttribute as String, kAXLayoutAreaRole as String)
        b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(rail, headers)
        b.setChildren(mixer, strips)
        b.setChildren(window, [rail, mixer])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
    }

    var runtime: AXLogicProElements.Runtime {
        builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in
                Issue.record("the regression fixture must never execute a live script")
                return .error("unexpected live script")
            })
    }
}

private final class ArrangeIndexInsertDriver: @unchecked Sendable {
    private(set) var calls: [(track: Int, insert: Int, pluginID: String)] = []

    var driver: AccessibilityChannel.PluginInsertDriver {
        { track, insert, pluginID, _, _ in
            self.calls.append((track, insert, pluginID))
            return (.mounted(slot: insert, pluginID: pluginID, observedName: "Gain"), ["fake": true])
        }
    }
}

private func arrangeIndexRegressionObject(_ result: ChannelResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

@Suite("Plug-in Arrange index regression past aux strips")
struct PluginArrangeIndexRegressionTests {
    @Test func inventoryReadsBassAtArrangeNineRatherThanAuxAtMixerNine() async throws {
        let fixture = ArrangeIndexRegressionFixture(bassOccupied: true)
        let result = await AccessibilityChannel.defaultGetPluginInventory(
            params: ["track": "9"], runtime: fixture.runtime,
            revealMixer: { runtime in (AXLogicProElements.getMixerArea(runtime: runtime), .alreadyVisible) }
        )
        let object = try arrangeIndexRegressionObject(result)
        #expect(object["state"] as? String == "A")
        #expect(object["track_name"] as? String == "Bass")
        #expect(object["mixer_strip_index"] as? Int == 11)
        let plugins = try #require(object["plugins"] as? [[String: Any]])
        #expect(plugins.map { $0["name"] as? String } == ["Gain"])
        #expect(plugins.map { $0["plugin_id"] as? String } == ["logic.stock.effect.gain"])
        #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
    }

    @Test func fullInventoryReadsBassGainRatherThanAuxCompressor() throws {
        let fixture = ArrangeIndexRegressionFixture(bassOccupied: true)
        let inventory = try #require(AccessibilityChannel.fullStripInventory(track: 9, runtime: fixture.runtime))
        #expect(inventory.count == 1)
        #expect(inventory[0]?.name == "Gain")
        #expect(inventory[0]?.pluginID == "logic.stock.effect.gain")
        #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
    }

    @Test func insertUsesEmptyBassSlotWithoutRefusingOccupiedAuxSlot() async throws {
        let fixture = ArrangeIndexRegressionFixture(bassOccupied: false)
        let driver = ArrangeIndexInsertDriver()
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-arrange-regression-\(UUID().uuidString).logicx", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: project) }
        let projectPath = project.path
        let result = await AccessibilityChannel.defaultInsertVerified(
            params: ["track": "9", "insert": "0", "plugin": "Gain", "mode": "duplicate_applyback",
                     "project_expected_path": projectPath],
            runtime: fixture.runtime, frontDocumentPath: { projectPath }, insertDriver: driver.driver,
            rollback: { _, _, _, _ in
                Issue.record("the matching fake mount must not need rollback")
                return AccessibilityChannel.RollbackResult(
                    attempted: false, succeeded: false, retries: 0, lastClickResult: "not attempted")
            }
        )
        let object = try arrangeIndexRegressionObject(result)
        #expect(object["state"] as? String == "A")
        #expect(object["observed_slot"] as? Int == 0)
        #expect(object["observed_plugin_id"] as? String == "logic.stock.effect.gain")
        #expect(driver.calls.count == 1)
        let call = try #require(driver.calls.first)
        #expect(call.track == 9)
        #expect(call.insert == 0)
        #expect(call.pluginID == "logic.stock.effect.gain")
        #expect(fixture.builder.actionCalls.isEmpty && fixture.builder.setCalls.isEmpty)
    }
}
