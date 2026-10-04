@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// R1108-01's sibling insertion gap: the first Mixer description read occurs
/// after the initial reference-name guard, but before independent acquisition.
private final class ReferenceInsertAcquisitionFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let mixerReads = MutableBox(0)
    let app: AXUIElement
    let mixer: AXUIElement
    let rail: AXUIElement
    let headers: [AXUIElement]

    init() {
        let b = builder
        app = b.element(110_701)
        let window = b.element(110_702)
        rail = b.element(110_703)
        mixer = b.element(110_704)
        let names = (0..<9).map { "Track \($0)" } + ["Bass", "Hi Synth"]
        headers = names.enumerated().map { index, name in
            let header = b.element(111_000 + index)
            b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(header, kAXDescriptionAttribute as String, "1개의 ‘\(name)’ 트랙")
            b.setAttribute(header, kAXSelectedAttribute as String, index == 9)
            return header
        }
        let strips = names.enumerated().map { index, name in
            let strip = b.element(112_000 + index * 10)
            let field = b.element(112_001 + index * 10)
            let slot = b.element(112_002 + index * 10)
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(field, kAXDescriptionAttribute as String, "이름")
            b.setAttribute(field, kAXValueAttribute as String, name)
            b.setAttribute(slot, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(slot, kAXDescriptionAttribute as String, "오디오 플러그인")
            b.setAttribute(slot, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
            b.setChildren(strip, [field, slot])
            return strip
        }
        b.setAttribute(rail, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(rail, kAXDescriptionAttribute as String, "트랙 헤더")
        b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(rail, headers)
        b.setChildren(mixer, strips)
        b.setChildren(window, [rail, mixer])
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
    }

    func runtime(reorderAfterInitialGuard: Bool) -> AXLogicProElements.Runtime {
        builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { [self] element, attribute in
                if CFEqual(element, mixer), attribute == (kAXDescriptionAttribute as String) {
                    mixerReads.value += 1
                    if mixerReads.value == 1, reorderAfterInitialGuard {
                        var reordered = headers
                        reordered.swapAt(9, 10)
                        builder.setChildren(rail, reordered)
                    }
                }
                return nil
            },
            setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in
                Issue.record("the reference acquisition fixture must never execute live AppleScript")
                return .error("unexpected live script")
            }
        )
    }
}

private func referenceInsertAcquisition(reorder: Bool) async throws -> ([String: Any], Int, Int) {
    let fixture = ReferenceInsertAcquisitionFixture()
    let driverCalls = MutableBox(0)
    let project = FileManager.default.temporaryDirectory
        .appendingPathComponent("reference-insert-acquisition-\(UUID().uuidString).logicx", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: project) }
    let projectPath = project.path
    let result = await AccessibilityChannel.defaultInsertVerified(
        params: [
            "track": "9", "insert": "0", "plugin": "Gain", "mode": "duplicate_applyback",
            "project_expected_path": projectPath, "expected_track_name": "Bass",
            "expected_slot_read_status": "empty", "expected_plugin_identity": "",
        ], runtime: fixture.runtime(reorderAfterInitialGuard: reorder),
        frontDocumentPath: { projectPath },
        insertDriver: { _, insert, pluginID, _, _ in
            driverCalls.value += 1
            return (.mounted(slot: insert, pluginID: pluginID, observedName: "Gain"), [:])
        }
    )
    let object = try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
    return (object, driverCalls.value, fixture.mixerReads.value)
}

@Test func testEmptyInsertReferenceRefusesReorderAfterInitialNameGuardBeforeAcquisition() async throws {
    let (object, driverCalls, mixerReads) = try await referenceInsertAcquisition(reorder: true)
    #expect(mixerReads > 0, "the initial name guard must pass before the Mixer acquisition interleaving")
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "stale_target_reference")
    #expect(driverCalls == 0)
    let attempted = try #require(object["write_attempted"] as? Bool)
    #expect(!attempted)
}

@Test func testUnchangedEmptyInsertReferenceAcquisitionInvokesDriverOnce() async throws {
    let (object, driverCalls, mixerReads) = try await referenceInsertAcquisition(reorder: false)
    #expect(mixerReads > 0)
    #expect(object["state"] as? String == "A")
    #expect(driverCalls == 1)
}
