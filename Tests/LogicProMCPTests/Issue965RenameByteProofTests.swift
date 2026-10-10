@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private final class RenameByteProofFixture: @unchecked Sendable {
    let builder: FakeAXRuntimeBuilder
    let app: AXUIElement
    let header: AXUIElement
    let field: AXUIElement
    let requested: String
    let nameAfterSet: String
    var refuseSelection = false
    private(set) var events: [String] = []

    init(initial: String, requested: String, nameAfterSet: String) {
        let builder = FakeAXRuntimeBuilder()
        self.builder = builder
        self.requested = requested
        self.nameAfterSet = nameAfterSet
        app = builder.element(965_300)
        let window = builder.element(965_301)
        let rail = builder.element(965_302)
        header = builder.element(965_303)
        field = builder.element(965_304)
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, "Fixture - Tracks")
        builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        // Keep the fallback selection read positive: it must never enter selectTrackViaAX's
        // legacy direct native setters. No menu exists, so a failed AX readback refuses safely.
        builder.setAttribute(header, kAXSelectedAttribute as String, true)
        builder.setAttribute(field, kAXRoleAttribute as String, kAXTextFieldRole as String)
        builder.setAttribute(field, kAXDescriptionAttribute as String, initial)
        builder.setAttribute(field, kAXValueAttribute as String, "0")
        builder.setChildren(field, [])
        builder.setChildren(header, [field])
        builder.setChildren(rail, [header])
        builder.setChildren(window, [rail])
        builder.setChildren(app, [window])
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    }

    var runtime: AXLogicProElements.Runtime {
        AXLogicProElements.Runtime(
            logicProPID: { 4242 },
            ax: builder.makeAXRuntime(
                appElement: app,
                setAttributeHandler: { [self] element, attribute, value in
                    if refuseSelection, attribute == kAXSelectedChildrenAttribute as String
                        || attribute == kAXSelectedAttribute as String { return false }
                    guard CFEqual(element, field), attribute == kAXValueAttribute as String,
                          let written = value as? String else {
                        Issue.record("Unexpected fixture AX setter")
                        return false
                    }
                    events.append("set_name")
                    #expect(written.utf8.elementsEqual(requested.utf8))
                    builder.setAttribute(field, kAXDescriptionAttribute as String, nameAfterSet)
                    return true
                },
                performActionHandler: { [self] element, action in
                    if refuseSelection, !CFEqual(element, field), action == kAXPressAction as String {
                        events.append("selection_attempt")
                        return false
                    }
                    guard CFEqual(element, field),
                          action == kAXPressAction as String || action == kAXConfirmAction as String else {
                        Issue.record("Unexpected fixture AX action")
                        return false
                    }
                    events.append(action)
                    return true
                }
            ),
            executeAppleScript: { [self] _ in
                events.append("script")
                return .error("Fixture refuses AppleScript")
            },
            onScreenWindowList: { [] },
            postPopupMenuEscape: { [self] in events.append("popup_escape") },
            focusedApplicationPID: { 4242 }
        )
    }

    var mouseRuntime: AXMouseHelper.Runtime {
        AXMouseHelper.Runtime(
            postMouseEvent: { [self] _, _, _ in events.append("mouse"); return false },
            postKeyEvent: { [self] _ in events.append("key"); return false },
            postUnicodeScalar: { [self] _ in events.append("unicode"); return false },
            sleepMicros: { _ in },
            postFlaggedKeyEvent: { [self] _, _ in events.append("flagged_key"); return false }
        )
    }

    var processRuntime: ProcessUtils.Runtime {
        ProcessUtils.Runtime(
            logicProPID: { 4242 }, fallbackLogicProPID: { 4242 },
            logicProRunning: { true },
            activateLogicPro: { [self] in events.append("activate"); return false },
            logicIsFrontmost: { true }, logicProBundleURL: { nil }
        )
    }

    func rename(_ params: [String: String]) -> ChannelResult {
        AccessibilityChannel.defaultRenameTrack(
            params: params, runtime: runtime, mouseRuntime: mouseRuntime,
            processRuntime: processRuntime
        )
    }

    func expectNoFallbackInput() {
        for event in ["script", "popup_escape", "mouse", "key", "unicode", "flagged_key"] {
            #expect(!events.contains(event))
        }
    }
}

private actor RenameByteProofChannel: Channel {
    nonisolated let id = ChannelID.accessibility
    let fixture: RenameByteProofFixture
    private(set) var operations: [(String, [String: String])] = []

    init(_ fixture: RenameByteProofFixture) { self.fixture = fixture }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "Injected rename fixture") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        operations.append((operation, params))
        if operation == "track.rename" { return fixture.rename(params) }
        if operation == "track.set_mute" {
            return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
        }
        return .error("Unexpected fixture route")
    }
}

@Suite("#965 raw rename proof preserves #353 continuity")
struct Issue965RenameByteProofTests {
    private static let oldName = "q\u{0301}\u{0323}"
    private static let newName = "q\u{0323}\u{0301}"

    @Test(arguments: [-1.0, 2.0, 0.9, Double.nan, Double.infinity, -Double.infinity])
    func allMalformedSelectionCannotBypassLegacyRenameExclusivity(value: Double) throws {
        let f = RenameByteProofFixture(initial: "Before", requested: "Changed", nameAfterSet: "Changed")
        f.refuseSelection = true
        let rail: AXUIElement = try #require(AXHelpers.getAttribute(f.header, kAXParentAttribute as String,
            runtime: f.builder.makeAXRuntime()))
        let other = f.builder.element(965_305)
        f.builder.setRole(other, kAXLayoutItemRole as String)
        f.builder.setChildren(other, [])
        for header in [f.header, other] {
            f.builder.setAttribute(header, kAXSelectedAttribute as String, NSNumber(value: value))
        }
        f.builder.setChildren(rail, [f.header, other])
        let result = f.rename(["index": "0", "name": "Changed"])
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "selection_not_exclusive")
        #expect(!f.events.contains("set_name"))
        #expect(!f.events.contains(kAXPressAction as String))
        #expect(!f.events.contains(kAXConfirmAction as String))
        f.expectNoFallbackInput()
    }

    @Test func byteDistinctEquivalentRenameRequiresAnActualWriteAndExactReadback() throws {
        let f = RenameByteProofFixture(
            initial: Self.oldName, requested: Self.newName, nameAfterSet: Self.newName
        )
        let result = f.rename(["index": "0", "name": Self.newName])
        #expect(result.isSuccess)
        let body = try #require(sharedJSONObject(result.message))
        #expect(try #require(body["state"] as? String) == "A")
        #expect(try #require(body["via"] as? String) == "ax_set_value")
        let observed = try #require(body["observed"] as? String)
        #expect(observed.utf8.elementsEqual(Self.newName.utf8))
        #expect(f.events == [kAXPressAction as String, "set_name", kAXConfirmAction as String])
        f.expectNoFallbackInput()
    }

    @Test func acceptedSetWithByteDistinctEquivalentReadbackCannotCertifyStateA() throws {
        let f = RenameByteProofFixture(
            initial: "Before", requested: Self.newName, nameAfterSet: Self.oldName
        )
        let result = f.rename(["index": "0", "name": Self.newName])
        let body = try #require(sharedJSONObject(result.message))
        #expect(try #require(body["state"] as? String) != "A")
        #expect(f.events.contains("set_name"))
        let actual = try #require(AXLogicProElements.trackName(at: 0, runtime: f.runtime))
        #expect(actual.utf8.elementsEqual(Self.oldName.utf8))
        f.expectNoFallbackInput()
    }

    @Test func exactRenameThroughDispatcherKeepsSameReferenceForNextLiveCheckedOperation() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = RenameByteProofFixture(
                initial: Self.oldName, requested: Self.newName, nameAfterSet: Self.newName
            )
            let runtime = f.runtime
            let cache = StateCache()
            await cache.updateTracks([
                AXValueExtractors.extractTrackState(from: f.header, index: 0, runtime: runtime.ax),
            ])
            let registry = TargetRegistry()
            let snapshot = await registry.currentSnapshot
            let issued = try #require(await TrackReferenceIssuance.issue(
                for: await cache.getTracks(), registry: registry, snapshot: snapshot
            ))
            let reference = try #require(issued.byTrackIndex[0])
            let router = ChannelRouter()
            let channel = RenameByteProofChannel(f)
            await router.register(channel)
            let renamed = await TrackDispatcher.handle(
                command: "rename",
                params: ["target_ref": .string(reference.rawValue), "name": .string(Self.newName)],
                router: router, cache: cache, targetRegistry: registry,
                liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }
            )
            let renameBody = try #require(sharedJSONObject(sharedToolText(renamed)))
            #expect(try #require(renameBody["state"] as? String) == "A")
            #expect(try #require(renameBody["via"] as? String) == "ax_set_value")
            let observed = try #require(renameBody["observed"] as? String)
            #expect(observed.utf8.elementsEqual(Self.newName.utf8))
            let binding = try #require(await registry.resolve(reference))
            #expect(binding.descriptor.trackName.utf8.elementsEqual(Self.newName.utf8))
            let cachedTracks = await cache.getTracks()
            let cached = try #require(cachedTracks.first)
            #expect(cached.name.utf8.elementsEqual(Self.newName.utf8))

            let second = await TrackDispatcher.handle(
                command: "mute", params: ["target_ref": .string(reference.rawValue)],
                router: router, cache: cache, targetRegistry: registry,
                liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }
            )
            let secondBody = try #require(sharedJSONObject(sharedToolText(second)))
            #expect(try #require(secondBody["state"] as? String) == "A")
            #expect(try #require(secondBody["target_ref"] as? String) == reference.rawValue)
            let operations = await channel.operations
            #expect(operations.map(\.0) == ["track.rename", "track.set_mute"])
            #expect(operations.last?.1["index"] == "0")
            #expect(f.events == [kAXPressAction as String, "set_name", kAXConfirmAction as String])
            f.expectNoFallbackInput()
        }
    }
}
