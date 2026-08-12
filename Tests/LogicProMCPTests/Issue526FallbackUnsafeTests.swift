@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private actor Issue526ErrorChannel: Channel {
    nonisolated let id: ChannelID
    private let envelope: String
    private var executionCount = 0

    init(id: ChannelID, envelope: String) {
        self.id = id
        self.envelope = envelope
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executionCount += 1
        return .error(envelope)
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "Issue526 error channel")
    }

    func executions() -> Int {
        executionCount
    }
}

private actor Issue526SuccessProbeChannel: Channel {
    nonisolated let id: ChannelID
    private var executionCount = 0

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executionCount += 1
        return .success("Issue526 fallback executed")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "Issue526 success probe")
    }

    func executions() -> Int {
        executionCount
    }
}

private func issue526SelectionFailureRuntime() -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(52_600)
    let arrange = builder.element(52_601)
    let markerList = builder.element(52_602)
    let table = builder.element(52_603)
    let row = builder.element(52_604)
    let lockCell = builder.element(52_605)
    let positionCell = builder.element(52_606)
    let markerNameCell = builder.element(52_607)
    let position = builder.element(52_608)
    let markerName = builder.element(52_609)

    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Issue526 - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/Issue526.logicx")
    builder.setAttribute(markerList, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(markerList, kAXTitleAttribute as String, "Issue526 - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/Issue526.logicx")
    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(table, kAXDescriptionAttribute as String, "Marker Table")
    builder.setAttribute(row, kAXRoleAttribute as String, kAXRowRole as String)
    for cell in [lockCell, positionCell, markerNameCell] {
        builder.setAttribute(cell, kAXRoleAttribute as String, kAXCellRole as String)
    }
    builder.setAttribute(position, kAXDescriptionAttribute as String, "1 1 1 1")
    builder.setAttribute(markerName, kAXDescriptionAttribute as String, "Target")
    builder.setChildren(positionCell, [position])
    builder.setChildren(markerNameCell, [markerName])
    builder.setChildren(row, [lockCell, positionCell, markerNameCell])
    builder.setAttribute(table, "AXRows", [row])
    builder.setChildren(table, [row])
    builder.setChildren(markerList, [table])

    // The row's selected attribute may be set, but the table never confirms it in
    // AXSelectedRows, which makes selectMarkerRowForDeletion refuse before any menu pick.
    return builder.makeLogicRuntime(appElement: app)
}

private let issue526NoOpMouseRuntime = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

/// Builds a Marker List whose exact Edit-menu Delete entry removes `actualDeleteIndex`. Keeping
/// that distinct from the requested index lets this fixture exercise the verification proof without
/// using a coordinate click or a synthetic key.
private func issue526MarkerDeleteReadbackRuntime(
    markers: [(position: String, name: String)],
    actualDeleteIndex: Int
) -> (runtime: AXLogicProElements.Runtime, mouse: AXMouseHelper.Runtime) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(52_700)
    let arrange = builder.element(52_701)
    let markerList = builder.element(52_702)
    let table = builder.element(52_703)
    let editMenu = builder.element(52_704)
    let menu = builder.element(52_705)
    let deleteEntry = builder.element(52_706)

    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Issue526 - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/Issue526.logicx")
    builder.setAttribute(markerList, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(markerList, kAXTitleAttribute as String, "Issue526 - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/Issue526.logicx")
    builder.setAttribute(editMenu, kAXRoleAttribute as String, kAXMenuButtonRole as String)
    builder.setAttribute(editMenu, kAXDescriptionAttribute as String, "Edit")
    builder.setActionNames(editMenu, [kAXShowMenuAction as String])
    builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
    builder.setAttribute(deleteEntry, kAXRoleAttribute as String, kAXMenuItemRole as String)
    builder.setAttribute(deleteEntry, kAXTitleAttribute as String, "Delete")
    builder.setAttribute(deleteEntry, kAXEnabledAttribute as String, kCFBooleanTrue)
    builder.setChildren(menu, [deleteEntry])
    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(table, kAXDescriptionAttribute as String, "Marker Table")

    let rows: [AXUIElement] = markers.enumerated().map { index, marker in
        let base = 52_710 + index * 10
        let row = builder.element(base)
        let lockCell = builder.element(base + 1)
        let positionCell = builder.element(base + 2)
        let markerNameCell = builder.element(base + 3)
        let position = builder.element(base + 4)
        let markerName = builder.element(base + 5)
        builder.setAttribute(row, kAXRoleAttribute as String, kAXRowRole as String)
        for cell in [lockCell, positionCell, markerNameCell] {
            builder.setAttribute(cell, kAXRoleAttribute as String, kAXCellRole as String)
        }
        builder.setAttribute(position, kAXDescriptionAttribute as String, marker.position)
        builder.setAttribute(markerName, kAXDescriptionAttribute as String, marker.name)
        builder.setChildren(positionCell, [position])
        builder.setChildren(markerNameCell, [markerName])
        builder.setChildren(row, [lockCell, positionCell, markerNameCell])
        return row
    }
    builder.setAttribute(table, "AXRows", rows)
    builder.setChildren(table, rows)
    builder.setChildren(markerList, [editMenu, table])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { element, attribute, _ in
            if attribute == kAXSelectedAttribute as String {
                builder.setAttribute(table, "AXSelectedRows", [element])
            }
            return true
        },
        performActionHandler: { element, action in
            if CFEqual(element, editMenu), action == (kAXShowMenuAction as String) {
                builder.setChildren(editMenu, [menu])
                return true
            }
            if CFEqual(element, deleteEntry), action == (kAXPickAction as String) {
                let postDeleteRows = rows.enumerated()
                    .filter { $0.offset != actualDeleteIndex }
                    .map { $0.element }
                builder.setAttribute(table, "AXRows", postDeleteRows)
                builder.setChildren(table, postDeleteRows)
                builder.setChildren(editMenu, [])
                // Match the live anomaly: the AX action status is not proof of the observed write.
                return false
            }
            return true
        }
    )
    let mouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { _ in false },
        postUnicodeScalar: { _ in false },
        sleepMicros: { _ in }
    )
    return (runtime, mouse)
}

@Test func testIssue526FallbackUnsafeStateCStopsMultiChannelFallback() async {
    let router = ChannelRouter()
    let envelope = HonestContract.encodeStateC(
        error: .axWriteFailed,
        hint: "Delete is unsafe without a confirmed Marker List menu route",
        extras: [
            "fallback_unsafe": true,
            "write_attempted": false,
        ]
    )
    let accessibility = Issue526ErrorChannel(id: .accessibility, envelope: envelope)
    let keyCommands = Issue526SuccessProbeChannel(id: .midiKeyCommands)
    await router.register(accessibility)
    await router.register(keyCommands)

    let result = await router.route(operation: "nav.set_zoom_level", params: ["level": "50"])

    // Mutation applied once: restore the removed keyboard-focus fallback wording. The receipt must
    // describe the menu-only delete contract instead.
    #expect(!result.isSuccess)
    #expect(!envelope.contains("keyboard"))
    #expect(result.message == envelope)
    #expect(HonestContract.isFallbackUnsafeStateC(result.message))
    #expect(await accessibility.executions() == 1)
    #expect(await keyCommands.executions() == 0)
}

@Test func testIssue526StateCWithoutFallbackUnsafeStillFallsThrough() async {
    let router = ChannelRouter()
    let envelope = HonestContract.encodeStateC(
        error: .axWriteFailed,
        hint: "AX write failed for a channel-local reason",
        extras: ["write_attempted": false]
    )
    let accessibility = Issue526ErrorChannel(id: .accessibility, envelope: envelope)
    let keyCommands = Issue526SuccessProbeChannel(id: .midiKeyCommands)
    await router.register(accessibility)
    await router.register(keyCommands)

    let result = await router.route(operation: "nav.set_zoom_level", params: ["level": "50"])

    #expect(result.isSuccess)
    #expect(!HonestContract.isFallbackUnsafeStateC(envelope))
    #expect(await accessibility.executions() == 1)
    #expect(await keyCommands.executions() == 1)
}

@Test func testIssue526FallbackUnsafeNonTerminalStateCStopsMultiChannelFallback() async {
    let router = ChannelRouter()
    let envelope = HonestContract.encodeStateC(
        error: .axWriteFailed,
        hint: "Marker List selection is unsafe to fall back from",
        extras: ["fallback_unsafe": true]
    )
    let accessibility = Issue526ErrorChannel(id: .accessibility, envelope: envelope)
    let keyCommands = Issue526SuccessProbeChannel(id: .midiKeyCommands)
    await router.register(accessibility)
    await router.register(keyCommands)

    let result = await router.route(operation: "nav.set_zoom_level", params: ["level": "50"])

    #expect(!result.isSuccess)
    #expect(result.message == envelope)
    #expect(HonestContract.isFallbackUnsafeStateC(result.message))
    #expect(await accessibility.executions() == 1)
    #expect(await keyCommands.executions() == 0)
}

@Test func testIssue526StateAExtrasCannotMasqueradeAsFallbackUnsafeStateC() {
    let envelope = HonestContract.encodeStateA(extras: [
        "success": false,
        "fallback_unsafe": true,
    ])

    #expect(!HonestContract.isFallbackUnsafeStateC(envelope))
}

@Test func testIssue526StateBEnvelopeWithMarkerIsNotFallbackUnsafeStateC() {
    let envelope = HonestContract.encodeStateB(
        reason: .readbackUnavailable,
        extras: [
            "success": false,
            "fallback_unsafe": true,
        ]
    )

    #expect(!HonestContract.isFallbackUnsafeStateC(envelope))
}

@Test func testIssue526FallbackUnsafeMarkerWithoutErrorStringIsNotFallbackUnsafeStateC() {
    let envelope = #"{"success":false,"state":"C","fallback_unsafe":true}"#

    #expect(!HonestContract.isFallbackUnsafeStateC(envelope))
}

@Test func testIssue526SelectionFailureRefusalIsFallbackUnsafeAndStopsChain() async throws {
    let refusal = await AccessibilityChannel.defaultDeleteMarker(
        index: 0,
        runtime: issue526SelectionFailureRuntime(),
        mouse: issue526NoOpMouseRuntime
    )
    let receipt = try #require(JSONSerialization.jsonObject(
        with: Data(refusal.message.utf8)
    ) as? [String: Any])
    let selectionWriteAttempted = try #require(receipt["selection_write_attempted"] as? Bool)

    // Mutation applied once: set `selection_write_attempted` false when AXSelectedRows cannot
    // confirm the write. This fixture accepts AXSelected before that failed confirmation, so the
    // false provenance claim fails here.
    #expect(!refusal.isSuccess)
    #expect(selectionWriteAttempted)
    let router = ChannelRouter()
    let accessibility = Issue526ErrorChannel(id: .accessibility, envelope: refusal.message)
    let keyCommands = Issue526SuccessProbeChannel(id: .midiKeyCommands)
    await router.register(accessibility)
    await router.register(keyCommands)

    let result = await router.route(operation: "nav.set_zoom_level", params: ["level": "50"])

    #expect(HonestContract.isFallbackUnsafeStateC(refusal.message))
    #expect(refusal.message.contains("could not be selected"))
    #expect(!result.isSuccess)
    #expect(result.message == refusal.message)
    #expect(await accessibility.executions() == 1)
    #expect(await keyCommands.executions() == 0)
}

@Test func testIssue526DuplicateTargetPositionReturnsStateBWhenWrongRowWasDeleted() async throws {
    // The requested target at index 1 and the actually deleted row at index 2
    // share 5.1.1.1. Their position multisets are therefore identical after
    // either deletion; the old gate returned State A for this wrong-target write.
    let fixture = issue526MarkerDeleteReadbackRuntime(
        markers: [
            (position: "1 1 1 1", name: "Intro"),
            (position: "5 1 1 1", name: "Requested Target"),
            (position: "5 1 1 1", name: "Wrong Row"),
            (position: "9 1 1 1", name: "Outro"),
        ],
        actualDeleteIndex: 2
    )

    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_unavailable")
    #expect(try #require(envelope["write_attempted"] as? Bool))
    #expect(envelope["marker_count_before"] as? Int == 4)
    #expect(envelope["marker_count_after"] as? Int == 3)
    #expect(!(try #require(envelope["target_position_unique"] as? Bool)))
    #expect(try #require(envelope["position_evidence_canonical"] as? Bool))
    #expect(try #require(envelope["reason_detail"] as? String).contains("cannot establish which marker"))
}

@Test func testIssue526FallbackPositionCollisionAlsoReturnsStateB() async throws {
    // A failed parse manufactures ordinal 1 as 1.1.1.1, which collides with
    // the next row's genuine 1.1.1.1. Deleting that next row reproduces the
    // same multiset expected after deleting the requested fallback row.
    let fixture = issue526MarkerDeleteReadbackRuntime(
        markers: [
            (position: "not a position", name: "Fallback Target"),
            (position: "1 1 1 1", name: "Parsed Same Position"),
            (position: "9 1 1 1", name: "Outro"),
        ],
        actualDeleteIndex: 1
    )

    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(!(try #require(envelope["target_position_unique"] as? Bool)))
    #expect(!(try #require(envelope["prewrite_position_evidence_canonical"] as? Bool)))
    #expect(try #require(envelope["reason_detail"] as? String).contains("cannot establish which marker"))
}
