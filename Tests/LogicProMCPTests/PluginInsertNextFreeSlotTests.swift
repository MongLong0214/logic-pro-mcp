@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #1618 step 1 — `insert_plugin` appends to the first empty Audio FX slot, takes an explicit slot,
/// and reads the pre-existing plug-ins back unchanged. Driven with the existing AX fakes; nothing
/// here ran against a live Logic.
@Suite("#1618 insert into the next free slot", .serialized)
struct PluginInsertNextFreeSlotTests {
    private final class Chain: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let strip: AXUIElement
        let runtime: AXLogicProElements.Runtime
        private var nextID = 3000

        init(_ names: [String?]) {
            let app = builder.element(900)
            let window = builder.element(901)
            let mixer = builder.element(902)
            strip = builder.element(903)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setChildren(window, [mixer])
            builder.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
            builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
            builder.setChildren(mixer, [strip])
            builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            addPluginTrackAssociation(builder, window: window, strip: strip)
            runtime = builder.makeLogicRuntime(appElement: app)
            set(names)
        }

        /// One row per slot, top-down: a name is an occupied slot, nil an empty one.
        func set(_ names: [String?]) {
            var rows: [AXUIElement] = []
            for (row, name) in names.enumerated() {
                nextID += 10
                let slot = builder.element(nextID)
                if let name {
                    let bypass = builder.element(nextID + 1)
                    let open = builder.element(nextID + 2)
                    builder.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
                    builder.setAttribute(slot, kAXDescriptionAttribute as String, name)
                    builder.setChildren(slot, [bypass, open])
                    builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
                    builder.setAttribute(bypass, kAXDescriptionAttribute as String, "Bypass")
                    builder.setAttribute(bypass, kAXValueAttribute as String, 0)
                    builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
                    builder.setAttribute(open, kAXDescriptionAttribute as String, "Open")
                } else {
                    builder.setAttribute(slot, kAXRoleAttribute as String, kAXButtonRole as String)
                    builder.setAttribute(slot, kAXDescriptionAttribute as String, "Audio Plugin")
                    builder.setAttribute(slot, kAXHelpAttribute as String, "Audio effect slot. Insert an audio effect.")
                }
                builder.setAttribute(slot, kAXPositionAttribute as String, axPoint(100, 300 + CGFloat(row) * 20))
                builder.setAttribute(slot, kAXSizeAttribute as String, axSize(58, 16))
                rows.append(slot)
            }
            builder.setChildren(strip, rows)
        }
    }

    private func unchanged(_ json: [String: Any]) -> Bool {
        (json["preexisting_slots_unchanged"] as? NSNumber)?.boolValue ?? false
    }

    private func insert(
        _ chain: Chain, params: [String: String], after: [String?]
    ) async -> (ok: Bool, json: [String: Any]) {
        var all = ["track": "0"]
        all.merge(params) { _, new in new }
        let result = await AccessibilityChannel.defaultInsertPlugin(
            params: all,
            runtime: chain.runtime,
            selectPlugin: { _, _, _, _ in
                chain.set(after)
                return .selected(.pressed(leaf: "Stereo"))
            },
            rollback: { true },
            readbackTimeoutMs: 50
        )
        let json = (try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any] ?? [:]
        return (result.isSuccess, json)
    }

    @Test("with no slot the plug-in goes to the first empty slot and the existing ones read back unchanged")
    func appendsToNextFreeSlot() async {
        let chain = Chain(["Channel EQ", "Compressor", nil, nil])
        let r = await insert(
            chain, params: ["plugin_name": "DeEsser 2"],
            after: ["Channel EQ", "Compressor", "DeEsser 2", nil]
        )
        #expect(r.ok)
        #expect(r.json["state"] as? String == "A")
        #expect(r.json["slot"] as? Int == 2)
        #expect(r.json["observed_plugin_name"] as? String == "DeEsser 2")
        #expect(unchanged(r.json))
        #expect((r.json["slots_before"] as? [Any])?.first as? String == "Channel EQ")
        #expect((r.json["slots_after"] as? [Any])?.count == 4)
    }

    @Test("an explicit slot is honoured and the empty slots before it stay empty")
    func explicitSlot() async {
        let chain = Chain(["Channel EQ", nil, nil])
        let r = await insert(
            chain, params: ["plugin_name": "ChromaVerb", "slot": "2"],
            after: ["Channel EQ", nil, "ChromaVerb"]
        )
        #expect(r.json["state"] as? String == "A")
        #expect(r.json["slot"] as? Int == 2)
        #expect(r.json["observed_plugin_name"] as? String == "ChromaVerb")
        #expect(unchanged(r.json))
    }

    @Test("an explicit occupied slot is refused, never replaced")
    func occupiedExplicitSlotRefuses() async {
        let chain = Chain(["Channel EQ", nil])
        let r = await insert(chain, params: ["plugin_name": "Gain", "slot": "0"], after: [])
        #expect(!r.ok)
        #expect(((r.json["hint"] as? String) ?? "").contains("slot_occupied"))
        #expect(chain.builder.actionCalls.isEmpty)
    }

    @Test("a strip whose visible slots are all occupied refuses with no_free_slot")
    func noFreeSlot() async {
        let chain = Chain(["Channel EQ", "Compressor"])
        let r = await insert(chain, params: ["plugin_name": "Gain"], after: [])
        #expect(!r.ok)
        #expect(((r.json["hint"] as? String) ?? "").contains("no_free_slot"))
        #expect(chain.builder.actionCalls.isEmpty)
    }

    @Test("an insert that disturbs a plug-in already on the strip is not State A")
    func disturbedExistingSlotIsNotVerified() async {
        let chain = Chain(["Channel EQ", nil])
        let r = await insert(
            chain, params: ["plugin_name": "DeEsser 2"],
            after: ["Compressor", "DeEsser 2"]
        )
        #expect(r.json["state"] as? String == "B")
        #expect(!unchanged(r.json))
    }

    @Test("an unmeasured plug-in refuses before any slot is pressed")
    func unmeasuredPluginRefuses() async {
        let chain = Chain([nil])
        let r = await insert(chain, params: ["plugin_name": "ChromaGlow"], after: [])
        #expect(!r.ok)
        #expect(r.json["error"] as? String == "invalid_params")
        #expect(chain.builder.actionCalls.isEmpty)
    }
}
