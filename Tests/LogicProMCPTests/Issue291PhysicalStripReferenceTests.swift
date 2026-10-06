@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Actual readers, registry issuance, dispatch and AX writes over injected elements only.
@Suite("#291 physical Mixer references", .serialized)
struct Issue291PhysicalStripReferenceTests {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func take() -> Bool { lock.withLock { if fired { return false }; fired = true; return true } }
    }
    final class Fixture: @unchecked Sendable {
        let b = FakeAXRuntimeBuilder()
        let pid: pid_t = 2_910_900
        let bundle: URL
        let app: AXUIElement
        let window: AXUIElement
        let mixer: AXUIElement
        let headers: [AXUIElement]
        let strips: [AXUIElement]
        let headerVolumes: [AXUIElement]
        let headerPans: [AXUIElement]
        let volumes: [AXUIElement]
        let pans: [AXUIElement]
        let outputs: [AXUIElement]
        let root: AXUIElement
        let pair: AXUIElement
        private var currentStrips: [AXUIElement]
        private var openedSlot: AXUIElement?
        var reportedProjectPath: String?
        var onAttributeRead: (@Sendable (AXUIElement, String) -> Void)?
        var attributeReadResult: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?)?
        var childrenReadResult: (@Sendable (AXUIElement) -> Result<[AXUIElement], AXHelpers.AXStatusError>?)?
        var onChildrenResultRead: (@Sendable (AXUIElement) -> Void)?
        private(set) var mutations: [(AXUIElement, String)] = []

        init(aux: Bool = false, duplicateNames: Bool = false) throws {
            let builder = b
            let stripCount = aux ? 3 : 2
            bundle = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpm291-physical-\(UUID().uuidString).logicx", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            app = b.element(2_910_000); window = b.element(2_910_001)
            mixer = b.element(2_910_002)
            let rail = b.element(2_910_003)
            headers = [b.element(2_910_010), b.element(2_910_020)]
            headerVolumes = [b.element(2_910_011), b.element(2_910_021)]
            headerPans = [b.element(2_910_012), b.element(2_910_022)]
            strips = (0..<stripCount).map { builder.element(2_910_100 + $0 * 10) }
            volumes = (0..<stripCount).map { builder.element(2_910_101 + $0 * 10) }
            pans = (0..<stripCount).map { builder.element(2_910_102 + $0 * 10) }
            outputs = (0..<stripCount).map { builder.element(2_910_103 + $0 * 10) }
            root = b.element(2_910_200); pair = b.element(2_910_201)
            currentStrips = strips
            b.setRole(app, kAXApplicationRole as String)
            b.setRole(window, kAXWindowRole as String)
            b.setAttribute(window, kAXTitleAttribute as String, "Session - Tracks")
            b.setAttribute(window, kAXDocumentAttribute as String, bundle.absoluteString)
            b.setAttribute(app, kAXMainWindowAttribute as String, window)
            b.setAttribute(app, kAXWindowsAttribute as String, [window])
            b.setAttribute(app, kAXFocusedWindowAttribute as String, window)
            b.setAttribute(app, kAXFocusedUIElementAttribute as String, window)
            b.setRole(rail, kAXListRole as String)
            b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            for i in headers.indices {
                b.setRole(headers[i], kAXLayoutItemRole as String)
                b.setAttribute(headers[i], kAXTitleAttribute as String, duplicateNames ? "Same" : ["A", "B"][i])
                b.setAttribute(headers[i], kAXSelectedAttribute as String, false)
                slider(headerVolumes[i], value: 100, min: 0, max: 233, description: "Volume")
                slider(headerPans[i], value: 63.5, min: 0, max: 127, description: "")
                let indicator = b.element(2_910_030 + i)
                b.setRole(indicator, "AXValueIndicator")
                b.setAttribute(indicator, kAXDescriptionAttribute as String, "0 Pan")
                b.setChildren(headerPans[i], [indicator])
                b.setChildren(headers[i], [headerVolumes[i], headerPans[i]])
            }
            b.setChildren(rail, headers)
            b.setNamedContainer(mixer, role: "AXLayoutArea", description: "Mixer", x: 0, y: 100, width: 400, height: 400)
            for i in strips.indices {
                b.setRole(strips[i], kAXLayoutItemRole as String)
                b.setFrame(strips[i], x: CGFloat(i * 80), y: 100, width: 80, height: 400)
                let name = b.element(2_910_104 + i * 10)
                b.setRole(name, kAXTextFieldRole as String)
                b.setAttribute(name, kAXDescriptionAttribute as String, "Name")
                b.setAttribute(name, kAXValueAttribute as String, duplicateNames ? "Same" : ["B", "A", "Aux"][i])
                b.setChildren(name, [])
                slider(volumes[i], value: 100, min: 0, max: 233, description: "Volume")
                slider(pans[i], value: 0, min: -64, max: 63, description: "")
                let indicator = b.element(2_910_105 + i * 10)
                b.setRole(indicator, "AXValueIndicator")
                b.setAttribute(indicator, kAXDescriptionAttribute as String, "0 Pan")
                b.setChildren(pans[i], [indicator])
                b.setButton(outputs[i], description: "Stereo Output",
                            help: "Output slot. Choose the channel strip output.",
                            x: CGFloat(i * 80), y: 150, width: 60, height: 20)
                b.setChildren(outputs[i], [])
                b.setChildren(strips[i], [name, outputs[i], volumes[i], pans[i]])
            }
            b.setChildren(mixer, strips)
            let bar = b.element(2_910_300)
            b.setRole(bar, kAXGroupRole as String)
            b.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
            let buttons = [b.element(2_910_301), b.element(2_910_302)]
            for (button, name) in zip(buttons, ["Play", "Record"]) {
                b.setRole(button, kAXCheckBoxRole as String)
                b.setAttribute(button, kAXDescriptionAttribute as String, name)
                b.setAttribute(button, kAXValueAttribute as String, 0)
                b.setChildren(button, [])
            }
            b.setChildren(bar, buttons)
            b.setChildren(window, [rail, bar, mixer])
            b.setRole(root, kAXMenuRole as String)
            let parent = b.element(2_910_202); let submenu = b.element(2_910_203)
            b.setRole(parent, kAXMenuItemRole as String)
            b.setAttribute(parent, kAXTitleAttribute as String, "Output")
            b.setAttribute(parent, kAXEnabledAttribute as String, true)
            b.setRole(submenu, kAXMenuRole as String)
            b.setRole(pair, kAXMenuItemRole as String)
            b.setAttribute(pair, kAXTitleAttribute as String, "Output 3-4")
            b.setAttribute(pair, kAXEnabledAttribute as String, true)
            b.setChildren(pair, []); b.setChildren(submenu, [pair])
            b.setChildren(parent, [submenu]); b.setChildren(root, [parent])
            b.setActionNames(root, [kAXCancelAction as String])
        }

        deinit { try? FileManager.default.removeItem(at: bundle) }

        private func slider(_ element: AXUIElement, value: Double, min: Double, max: Double, description: String) {
            b.setRole(element, kAXSliderRole as String)
            b.setAttribute(element, kAXDescriptionAttribute as String, description)
            b.setAttribute(element, kAXValueAttribute as String, value)
            b.setAttribute(element, kAXMinValueAttribute as String, min)
            b.setAttribute(element, kAXMaxValueAttribute as String, max)
            b.setAttributeSettable(element, kAXValueAttribute as String, true)
            b.setChildren(element, [])
        }

        func reorder(_ order: [Int]) {
            currentStrips = order.map { strips[$0] }
            b.setChildren(mixer, currentStrips)
        }

        func value(_ element: AXUIElement) -> Double? {
            (b.attributeValue(element, kAXValueAttribute as String) as? NSNumber)?.doubleValue
                ?? b.attributeValue(element, kAXValueAttribute as String) as? Double
        }

        private func action(_ element: AXUIElement, _ action: String) -> Bool {
            mutations.append((element, action))
            if action == kAXCancelAction as String, CFEqual(element, root) {
                openedSlot = nil; b.setChildren(mixer, currentStrips); return true
            }
            if action == kAXPressAction as String {
                if outputs.contains(where: { CFEqual($0, element) }) {
                    openedSlot = element; b.setChildren(mixer, currentStrips + [root]); return true
                }
                if CFEqual(element, pair), let slot = openedSlot {
                    b.setAttribute(slot, kAXDescriptionAttribute as String, "Output 3-4")
                    openedSlot = nil; b.setChildren(mixer, currentStrips); return true
                }
            }
            let delta: Double = action == kAXIncrementAction as String ? 10 : (action == kAXDecrementAction as String ? -10 : 0)
            if delta != 0, let old = value(element) {
                let lo = b.attributeValue(element, kAXMinValueAttribute as String) as? Double ?? -1e9
                let hi = b.attributeValue(element, kAXMaxValueAttribute as String) as? Double ?? 1e9
                b.setAttribute(element, kAXValueAttribute as String, Swift.min(Swift.max(old + delta, lo), hi))
                return true
            }
            Issue.record("unexpected injected AX action \(action)"); return false
        }

        var logic: AXLogicProElements.Runtime {
            let ax = b.makeAXRuntime(appElement: app, attributeValueHandler: { [self] element, attribute in
                onAttributeRead?(element, attribute)
                if let result = attributeReadResult?(element, attribute) {
                    switch result {
                    case .success(let value): return .some(value)
                    case .failure: return .some(nil)
                    }
                }
                return nil
            }, attributeValueResultHandler: { [self] in attributeReadResult?($0, $1) },
            childrenHandler: { [self] element in
                guard let result = childrenReadResult?(element) else { return nil }
                switch result {
                case .success(let children): return children
                case .failure: return []
                }
            },
            childrenResultHandler: { [self] element in
                onChildrenResultRead?(element)
                return childrenReadResult?(element)
            },
            setAttributeHandler: { [self] element, attribute, raw in
                mutations.append((element, attribute))
                guard attribute == kAXValueAttribute as String, let old = value(element), let requested = raw as? NSNumber else {
                    Issue.record("unexpected injected AX setter"); return false
                }
                let target = requested.doubleValue
                b.setAttribute(element, attribute, old + (target > old ? 1 : (target < old ? -1 : 0)))
                return true
            }, performActionHandler: { [self] in action($0, $1) },
            performActionResultHandler: { [self] in
                action($0, $1) ? .success(()) : .failure(.init(raw: AXError.failure.rawValue))
            }, executeAppleScript: { _ in Issue.record("AX AppleScript forbidden"); return .error("forbidden") })
            return AXLogicProElements.Runtime(
                logicProPID: { [self] in pid }, ax: ax,
                executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
                executeAppleScriptWithTimeout: { _, _ in Issue.record("timed AppleScript forbidden"); return .error("forbidden") },
                onScreenWindowList: { [self] in
                    var windows: [[String: Any]] = [[kCGWindowOwnerPID as String: pid,
                        kCGWindowNumber as String: 291_900, kCGWindowLayer as String: 0]]
                    if openedSlot != nil { windows.append([kCGWindowOwnerPID as String: pid,
                        kCGWindowNumber as String: 291_901, kCGWindowLayer as String: 101]) }
                    return windows
                },
                postPopupMenuEscape: { Issue.record("Escape forbidden") },
                focusedApplicationPID: { [self] in pid },
                observeFrontmost: { [self] in .init(reason: .logicOwnsKeyboard, keyboardOwnerPID: pid,
                    keyboardOwnerBundleID: "com.apple.logic10", keyboardWindowLayer: 0,
                    focusedApplicationPID: pid, focusRead: .read) }
            )
        }

        func channel(typedMixer: Bool = true, typedUnread: Bool = false,
                     onJSONMixerRead: @escaping @Sendable () -> Void = {}) -> AccessibilityChannel {
            let runtime = logic
            let typed: (@Sendable (@escaping @Sendable () -> Bool) -> (states: [ChannelStripState]?, yielded: Bool))?
            if typedMixer {
                typed = { stop in typedUnread ? (nil, false) : AccessibilityChannel.defaultGetMixerStates(runtime: runtime, stoppingWhen: stop) }
            } else { typed = nil }
            return AccessibilityChannel(runtime: .init(
                isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
                appRoot: { [self] in app }, transportState: { .success("{}") },
                toggleTransportButton: { _ in Issue.record("transport action forbidden"); return .error("forbidden") },
                toggleStepInputKeyboard: { Issue.record("keyboard action forbidden"); return .error("forbidden") },
                setTempo: { _ in Issue.record("tempo forbidden"); return .error("forbidden") },
                setCycleRange: { _ in Issue.record("cycle forbidden"); return .error("forbidden") },
                tracks: { AccessibilityChannel.defaultGetTracks(runtime: runtime) },
                trackStates: { AccessibilityChannel.defaultGetTrackStates(runtime: runtime) },
                trackStatesStopping: { AccessibilityChannel.defaultGetTrackStates(runtime: runtime, stoppingWhen: $0) },
                selectedTrack: { AccessibilityChannel.defaultGetSelectedTrack(runtime: runtime) },
                selectTrack: { _ in Issue.record("select forbidden"); return .error("forbidden") },
                setTrackToggle: { _, _ in Issue.record("toggle forbidden"); return .error("forbidden") },
                renameTrack: { _ in Issue.record("rename forbidden"); return .error("forbidden") },
                sortTracks: { _ in Issue.record("sort forbidden"); return .error("forbidden") },
                mixerState: { onJSONMixerRead(); return AccessibilityChannel.defaultGetMixerState(runtime: runtime) },
                mixerStates: typed,
                channelStrip: { AccessibilityChannel.defaultGetChannelStrip(params: $0, runtime: runtime) },
                setMixerValue: { AccessibilityChannel.defaultSetMixerValue(params: $0, target: $1, runtime: runtime) },
                projectInfo: { [self] in AccessibilityChannel.encodeResult(ProjectInfo(name: "Session", filePath: reportedProjectPath ?? bundle.path)) },
                markers: { .success("[]") },
                openMarkerList: { Issue.record("marker forbidden"); return .error("forbidden") },
                createMarker: { _ in Issue.record("marker forbidden"); return .error("forbidden") },
                renameMarker: { _ in Issue.record("marker forbidden"); return .error("forbidden") },
                deleteMarker: { _ in Issue.record("marker forbidden"); return .error("forbidden") },
                importMIDIFile: { _ in Issue.record("import forbidden"); return .error("forbidden") },
                confirmNewTrackDialog: { Issue.record("Return forbidden") }, canPostEvents: { false }, logicRuntime: runtime
            ))
        }
    }

    private func publish(_ fixture: Fixture, background: Bool = false, tracksFirst: Bool = false) async throws -> (StateCache, TargetRegistry, ChannelRouter, [[String: Any]]) {
        let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
        let channel = fixture.channel(); await router.register(channel)
        let poller = StatePoller(axChannel: channel, cache: cache,
            runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                           projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
        if background {
            #expect(await poller.refreshNow())
        } else {
            let gate = LogicMutationGate()
            let deps = HandlerDependencies(router: router, cache: cache, targetRegistry: registry, poller: poller,
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [0: "A", 1: "B"] }, projectFileReader: .unavailable)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let params: [String: Value] = ["domains": .array([.string("tracks"), .string("strips")]), "allow_ui_navigation": .bool(false)]
            let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
                commandParams: params, mutationGate: gate) { await handler(deps, params) }
            let isError = result.isError ?? false
            #expect(!isError)
            let object = try #require(sharedJSONObject(sharedToolText(result)))
            #expect((object["sources"] as? [String: Any])?["strips"] as? String == "ax_request_read")
            #expect((object["strips"] as? [String: Any])?["coverage"] as? String == "partial")
        }
        #expect(fixture.mutations.isEmpty)
        if tracksFirst {
            _ = try await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router,
                                                targetRegistry: registry, fileReader: .unavailable)
        }
        let rows = try await resourceRows(cache, registry, router)
        return (cache, registry, router, rows)
    }

    private func resourceRows(_ cache: StateCache, _ registry: TargetRegistry, _ router: ChannelRouter) async throws -> [[String: Any]] {
        let result = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                                                   targetRegistry: registry, fileReader: .unavailable)
        return try #require(sharedJSONObject(sharedResourceText(result))?["strips"] as? [[String: Any]])
    }

    @Test(arguments: ["set_volume", "set_pan"], [false, true])
    func publishedReversedReferenceWritesOnlyPhysicalB(command: String, background: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture, background: background)
            #expect(rows.compactMap { $0["name"] as? String } == ["B", "A"])
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            let requested = command == "set_pan" ? 1.0 : AXValueExtractors.logicMixerFaderPositionToContract(110.0 / 233.0)
            let result = await MixerDispatcher.handle(command: command,
                params: ["target_ref": .string(reference), "value": .double(requested)], router: router, cache: cache,
                targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == "A")
            #expect(body["target_ref"] as? String == reference)
            let target = command == "set_pan" ? fixture.pans[0] : fixture.volumes[0]
            #expect(fixture.value(target) == (command == "set_pan" ? 63 : 110))
            #expect(!fixture.mutations.isEmpty && fixture.mutations.allSatisfy { CFEqual($0.0, target) })
            #expect(fixture.headerVolumes.allSatisfy { fixture.value($0) == 100 })
            #expect(fixture.headerPans.allSatisfy { fixture.value($0) == 63.5 })
        }
    }

    @Test func publishedReferenceSurvivesSamePhysicalStripReorderForOutput() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            fixture.reorder([1, 0])
            let result = await MixerDispatcher.handle(command: "set_output_verified",
                params: ["target_ref": .string(reference), "destination": .object(["kind": .string("physical"),
                         "ports": .array([.int(3), .int(4)])])], router: router, cache: cache,
                targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == "A")
            #expect(body["target_ref"] as? String == reference)
            #expect(fixture.b.attributeValue(fixture.outputs[0], kAXDescriptionAttribute as String) as? String == "Output 3-4")
            #expect(fixture.b.attributeValue(fixture.outputs[1], kAXDescriptionAttribute as String) as? String == "Stereo Output")
            #expect(fixture.mutations.contains { CFEqual($0.0, fixture.outputs[0]) && $0.1 == kAXPressAction as String })
            #expect(!fixture.mutations.contains { CFEqual($0.0, fixture.outputs[1]) })
        }
    }

    @Test(arguments: [false, true])
    func mixerOnlyAuxGetsIndependentUsableReference(background: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(aux: true)
            let (cache, registry, router, rows) = try await publish(fixture, background: background)
            let reference = try #require(rows[2]["mixer_strip_ref"] as? String)
            #expect(Set(rows.compactMap { $0["mixer_strip_ref"] as? String }).count == 3)
            let result = await MixerDispatcher.handle(command: "set_volume",
                params: ["target_ref": .string(reference), "value": .double(AXValueExtractors.logicMixerFaderPositionToContract(110.0 / 233.0))], router: router, cache: cache,
                targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "A")
            #expect(fixture.value(fixture.volumes[2]) == 110)
            #expect(!fixture.mutations.isEmpty && fixture.mutations.allSatisfy { CFEqual($0.0, fixture.volumes[2]) })
        }
    }

    @Test func mismatchedProjectMetadataCannotIssuePhysicalAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            fixture.reportedProjectPath = fixture.bundle.appendingPathComponent("other.logicx").path
            var refused = false
            do { _ = try await publish(fixture, background: true) }
            catch { refused = true }
            #expect(refused, "a physical B-document observation cannot be issued under another cached project")
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func duplicateDisplayNamesAndResourceReadOrderRetainIndependentPhysicalReferences(tracksFirst: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(aux: true, duplicateNames: true)
            let (cache, registry, router, rows) = try await publish(fixture, background: true, tracksFirst: tracksFirst)
            let references = rows.compactMap { $0["mixer_strip_ref"] as? String }
            #expect(references.count == 3 && Set(references).count == 3)
            _ = try await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router,
                                                targetRegistry: registry, fileReader: .unavailable)
            let again = try await resourceRows(cache, registry, router)
            #expect(again.compactMap { $0["mixer_strip_ref"] as? String } == references)
            let individual = try await ResourceHandlers.read(uri: "logic://mixer/1", cache: cache, router: router,
                                                            targetRegistry: registry, fileReader: .unavailable)
            #expect((sharedJSONObject(sharedResourceText(individual))?["strip"] as? [String: Any])?["mixer_strip_ref"] as? String == references[1])
            let result = await MixerDispatcher.handle(command: "set_pan", params: ["target_ref": .string(references[1]), "value": .double(-1)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "Same", 1: "Same"][$0] },
                liveTrackNames: { [0: "Same", 1: "Same"] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "A")
            #expect(fixture.value(fixture.pans[1]) == -64)
            #expect(fixture.mutations.allSatisfy { CFEqual($0.0, fixture.pans[1]) })
        }
    }

    @Test func physicalReferenceIsStableAcrossTypedRefreshAfterReorder() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(aux: true)
            let (cache, registry, router, before) = try await publish(fixture, background: true)
            let bReference = try #require(before[0]["mixer_strip_ref"] as? String)
            let auxReference = try #require(before[2]["mixer_strip_ref"] as? String)
            fixture.reorder([2, 1, 0])
            let poller = StatePoller(axChannel: fixture.channel(), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await poller.refreshNow())
            let after = try await resourceRows(cache, registry, router)
            #expect(after[0]["mixer_strip_ref"] as? String == auxReference)
            #expect(after[2]["mixer_strip_ref"] as? String == bReference)
            let result = await MixerDispatcher.handle(command: "set_volume",
                params: ["target_ref": .string(auxReference), "value": .double(AXValueExtractors.logicMixerFaderPositionToContract(110.0 / 233.0))],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "A")
            #expect(fixture.value(fixture.volumes[2]) == 110)
            #expect(fixture.mutations.allSatisfy { CFEqual($0.0, fixture.volumes[2]) })
        }
    }

    @Test(arguments: ["replaced", "removed", "document", "epoch", "topology"])
    func stalePhysicalOwnerOrMembershipNeverActs(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            switch change {
            case "replaced":
                let replacement = fixture.b.element(2_911_000)
                fixture.b.setRole(replacement, kAXLayoutItemRole as String)
                fixture.b.setChildren(replacement, fixture.b.makeAXRuntime().children(fixture.strips[0]))
                fixture.b.setChildren(fixture.mixer, [replacement, fixture.strips[1]])
            case "removed": fixture.reorder([1])
            case "document": fixture.b.setAttribute(fixture.window, kAXDocumentAttribute as String, fixture.bundle.appendingPathComponent("other.logicx").absoluteString)
            case "epoch": await registry.bumpProjectEpoch()
            default: await registry.bumpTopologyGeneration()
            }
            let result = await MixerDispatcher.handle(command: "set_volume", params: ["target_ref": .string(reference), "value": .double(0.6)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["error"] as? String == "stale_target_reference")
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func trackReferenceAndExplicitIndexPreserveArrangeHeaderWrites(useReference: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, _) = try await publish(fixture)
            let resource = try await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router,
                                                         targetRegistry: registry, fileReader: .unavailable)
            let first = try #require((sharedJSONObject(sharedResourceText(resource))?["data"] as? [[String: Any]])?.first)
            let reference = try #require(first["track_ref"] as? String)
            var params: [String: Value] = ["value": .double(AXValueExtractors.logicMixerFaderPositionToContract(110.0 / 233.0))]
            if useReference { params["target_ref"] = .string(reference) } else { params["track"] = .int(0) }
            let result = await MixerDispatcher.handle(command: "set_volume", params: params, router: router, cache: cache,
                targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "A")
            #expect(fixture.value(fixture.headerVolumes[0]) == 110)
            #expect(fixture.mutations.allSatisfy { CFEqual($0.0, fixture.headerVolumes[0]) })
            #expect(fixture.volumes.allSatisfy { fixture.value($0) == 100 })
        }
    }

    @Test func jsonRoundTripCannotManufacturePhysicalAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, _) = try await publish(fixture)
            let native = await cache.getChannelStrips()
            let imported = try JSONDecoder().decode([ChannelStripState].self, from: JSONEncoder().encode(native))
            #expect(imported.allSatisfy { $0.physicalBinding == nil })
            await cache.updateChannelStrips(imported)
            let rows = try await resourceRows(cache, registry, router)
            #expect(rows.allSatisfy { $0["mixer_strip_ref"] == nil })
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func coldIndividualStripFirstBootstrapsTheSamePhysicalReference(auxOnly: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(aux: true)
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            if auxOnly { fixture.b.setChildren(fixture.b.element(2_910_003), []) }
            let channel = fixture.channel(); await router.register(channel)
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await poller.refreshNow())
            if auxOnly { #expect(await cache.getTracks().isEmpty) }
            #expect(await registry.currentProjectIdentity == nil)
            let index = auxOnly ? 2 : 0
            let first = try await ResourceHandlers.read(uri: "logic://mixer/\(index)", cache: cache, router: router,
                                                      targetRegistry: registry, fileReader: .unavailable)
            let reference = try #require((sharedJSONObject(sharedResourceText(first))?["strip"] as? [String: Any])?["mixer_strip_ref"] as? String)
            let all = try await resourceRows(cache, registry, router)
            #expect(all[index]["mixer_strip_ref"] as? String == reference)
            _ = try await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router,
                                                targetRegistry: registry, fileReader: .unavailable)
            let again = try await resourceRows(cache, registry, router)
            #expect(again[index]["mixer_strip_ref"] as? String == reference)
            let result = await MixerDispatcher.handle(command: "set_pan", params: ["target_ref": .string(reference), "value": .double(1)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "A")
            #expect(fixture.value(fixture.pans[index]) == 63)
            #expect(fixture.mutations.allSatisfy { CFEqual($0.0, fixture.pans[index]) })
        }
    }

    @Test(arguments: [false, true])
    func changedCurrentProjectCannotReviveAnOldPhysicalReference(publishProjectReference: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture, background: true)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            let changedPath = fixture.bundle.appendingPathComponent("other.logicx").path
            fixture.reportedProjectPath = changedPath
            let poller = StatePoller(axChannel: fixture.channel(), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await poller.refreshNow())
            if publishProjectReference {
                _ = try await ResourceHandlers.read(uri: "logic://project/info", cache: cache, router: router,
                                                    targetRegistry: registry, fileReader: .unavailable)
                #expect(await registry.currentProjectIdentity?.projectFilePath == changedPath)
            }
            let result = await MixerDispatcher.handle(command: "set_volume", params: ["target_ref": .string(reference), "value": .double(0.6)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["error"] as? String == "stale_target_reference")
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func physicalControlReplacementImmediatelyBeforeActionIsStaleWithoutActuation() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            let replacement = fixture.b.element(2_912_000)
            for key in [kAXRoleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXMinValueAttribute, kAXMaxValueAttribute] {
                fixture.b.setAttribute(replacement, key as String, try #require(fixture.b.attributeValue(fixture.volumes[0], key as String)))
            }
            fixture.b.setChildren(replacement, [])
            let once = Once()
            fixture.onAttributeRead = { element, attribute in
                if attribute == kAXValueAttribute as String, CFEqual(element, fixture.volumes[0]), once.take() {
                    let children = fixture.b.makeAXRuntime().children(fixture.strips[0])
                    fixture.b.setChildren(fixture.strips[0], children.map { CFEqual($0, element) ? replacement : $0 })
                }
            }
            defer { fixture.onAttributeRead = nil }
            let result = await MixerDispatcher.handle(command: "set_volume", params: ["target_ref": .string(reference), "value": .double(0.6)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["error"] as? String == "stale_target_reference")
            #expect(fixture.mutations.isEmpty)
            #expect(fixture.value(replacement) == 100)
        }
    }

    @Test(arguments: [false, true])
    func physicalPanNeverUsesControlOrderOrFirstDuplicate(duplicate: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            var children = fixture.b.makeAXRuntime().children(fixture.strips[0])
            if duplicate {
                fixture.b.setAttribute(fixture.pans[0], kAXDescriptionAttribute as String, "Pan")
                let second = fixture.b.element(2_913_000)
                fixture.b.setRole(second, kAXSliderRole as String)
                fixture.b.setAttribute(second, kAXDescriptionAttribute as String, "Pan")
                fixture.b.setAttribute(second, kAXValueAttribute as String, 0.0)
                fixture.b.setAttribute(second, kAXMinValueAttribute as String, -64.0)
                fixture.b.setAttribute(second, kAXMaxValueAttribute as String, 63.0)
                fixture.b.setChildren(second, [])
                children.append(second)
            } else {
                children.removeAll { CFEqual($0, fixture.volumes[0]) || CFEqual($0, fixture.pans[0]) }
                children += [fixture.pans[0], fixture.volumes[0]]
            }
            fixture.b.setChildren(fixture.strips[0], children)
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            let result = await MixerDispatcher.handle(command: "set_pan", params: ["target_ref": .string(reference), "value": .double(1)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            if duplicate {
                #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "C")
                #expect(fixture.mutations.isEmpty)
            } else {
                #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "A")
                #expect(fixture.value(fixture.pans[0]) == 63)
                #expect(fixture.mutations.allSatisfy { CFEqual($0.0, fixture.pans[0]) })
            }
            #expect(fixture.value(fixture.volumes[0]) == 100)
        }
    }

    @Test func nativePhysicalRowsDoNotInventPositionalTrackRoutingEdges() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            fixture.b.setAttribute(fixture.outputs[0], kAXDescriptionAttribute as String, "Bus 1")
            let (cache, registry, router, rows) = try await publish(fixture, background: true)
            #expect(rows[0]["output"] as? String == "Bus 1")
            let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                                                         targetRegistry: registry, fileReader: .unavailable)
            let graph = try #require(sharedJSONObject(sharedResourceText(resource))?["routing_graph"] as? [String: Any])
            #expect(try #require(graph["edges"] as? [[String: Any]]).isEmpty)
            #expect(try #require(graph["nodes"] as? [[String: Any]]).isEmpty,
                    "the B strip is not proven to belong to Arrange A merely because both have ordinal zero")
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: ["late_role_absent", "late_help_failed", "late_children_failed", "depth_omitted_slider"])
    func physicalPanRequiresEveryPotentialCandidateExamined(shape: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            fixture.b.setAttribute(fixture.pans[0], kAXDescriptionAttribute as String, "Pan")
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            let late = fixture.b.element(2_914_000)
            fixture.b.setRole(late, kAXSliderRole as String)
            fixture.b.setAttribute(late, kAXDescriptionAttribute as String, "Pan")
            fixture.b.setAttribute(late, kAXValueAttribute as String, 0.0)
            fixture.b.setAttribute(late, kAXMinValueAttribute as String, -64.0)
            fixture.b.setAttribute(late, kAXMaxValueAttribute as String, 63.0)
            fixture.b.setChildren(late, [])
            var tail = late
            if shape == "depth_omitted_slider" {
                // The extra candidate is at depth five. A depth-four walk must not
                // promote its unexamined subtree into proof of a unique named pan.
                for offset in 1...4 {
                    let group = fixture.b.element(2_914_000 + offset)
                    fixture.b.setRole(group, kAXGroupRole as String)
                    fixture.b.setChildren(group, [tail])
                    tail = group
                }
            }
            fixture.b.setChildren(fixture.strips[0], fixture.b.makeAXRuntime().children(fixture.strips[0]) + [tail])
            if shape == "late_role_absent" || shape == "late_help_failed" {
                fixture.attributeReadResult = { element, attribute in
                    guard CFEqual(element, late) else { return nil }
                    if shape == "late_role_absent", attribute == kAXRoleAttribute as String {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if shape == "late_help_failed", attribute == kAXHelpAttribute as String {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return nil
                }
            } else if shape == "late_children_failed" {
                fixture.childrenReadResult = { CFEqual($0, late) ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil }
            }
            let result = await MixerDispatcher.handle(command: "set_pan", params: ["target_ref": .string(reference), "value": .double(1)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "C")
            #expect(fixture.mutations.isEmpty)
            #expect(fixture.value(fixture.pans[0]) == 0)
            #expect(fixture.value(late) == 0)
            #expect(fixture.value(fixture.volumes[0]) == 100)
        }
    }

    @Test(arguments: ["duplicate_membership", "missing_window", "wrong_mixer_owner"])
    func physicalMembershipAndWindowOwnerMustRemainUnique(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            if change == "duplicate_membership" {
                fixture.b.setChildren(fixture.mixer, [fixture.strips[0], fixture.strips[1], fixture.strips[0]])
            } else if change == "missing_window" {
                fixture.b.setAttribute(fixture.app, kAXWindowsAttribute as String, [AXUIElement]())
            } else {
                fixture.b.setChildren(fixture.window, fixture.b.makeAXRuntime().children(fixture.window).filter { !CFEqual($0, fixture.mixer) })
            }
            let result = await MixerDispatcher.handle(command: "set_pan", params: ["target_ref": .string(reference), "value": .double(1)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["error"] as? String == "stale_target_reference")
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func disablingReferencesDoesNotDisableLegacyTrackWritesOrIssuePhysicalRefs() async throws {
        let fixture = try Fixture()
        let (cache, registry, router, reference) = try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, router, rows) = try await publish(fixture, background: true)
            return (cache, registry, router, try #require(rows[0]["mixer_strip_ref"] as? String))
        }
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let rows = try await resourceRows(cache, registry, router)
            #expect(rows.allSatisfy { $0["mixer_strip_ref"] == nil })
            let refused = await MixerDispatcher.handle(command: "set_volume", params: ["target_ref": .string(reference), "value": .double(0.6)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(refused))?["state"] as? String == "C")
            #expect(fixture.mutations.isEmpty)
            let legacy = await MixerDispatcher.handle(command: "set_volume",
                params: ["track": .int(0), "value": .double(AXValueExtractors.logicMixerFaderPositionToContract(110.0 / 233.0))],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(legacy))?["state"] as? String == "A")
            #expect(fixture.value(fixture.headerVolumes[0]) == 110)
            #expect(fixture.volumes.allSatisfy { fixture.value($0) == 100 })
            #expect(fixture.mutations.allSatisfy { CFEqual($0.0, fixture.headerVolumes[0]) })
        }
    }

    @Test func scheduledBackgroundCycleRetainsIndependentPhysicalMixerAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(aux: true)
            fixture.b.setChildren(fixture.b.element(2_910_003), [])
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            let channel = fixture.channel(); await router.register(channel)
            let (finished, completion) = AsyncStream<Void>.makeStream()
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, sleep: { _ in
                    completion.finish(); throw CancellationError()
                }, blockingDialogInfo: { nil }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            await poller.start()
            for await _ in finished {}
            await poller.stop()
            #expect(await cache.getTracks().isEmpty)
            #expect(await registry.currentProjectIdentity == nil)
            let rows = try await resourceRows(cache, registry, router)
            let reference = try #require(rows[2]["mixer_strip_ref"] as? String)
            #expect(Set(rows.compactMap { $0["mixer_strip_ref"] as? String }).count == 3)
            let result = await MixerDispatcher.handle(command: "set_pan", params: ["target_ref": .string(reference), "value": .double(1)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { _ in nil }, liveTrackNames: { [:] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "A")
            #expect(fixture.value(fixture.pans[2]) == 63)
            #expect(fixture.mutations.allSatisfy { CFEqual($0.0, fixture.pans[2]) })
        }
    }

    @Test(arguments: [false, true])
    func JSONFallbackCannotManufacturePhysicalAuthorityAndTypedFailureNeverFallsBack(typedUnread: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let jsonRead = Once()
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            let channel = fixture.channel(typedMixer: typedUnread, typedUnread: typedUnread,
                onJSONMixerRead: { _ = jsonRead.take() })
            await router.register(channel)
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await poller.refreshNow())
            let cached = await cache.getChannelStrips()
            if typedUnread {
                #expect(cached.isEmpty)
                #expect(jsonRead.take(), "the unread typed provider must not cause a second JSON acquisition")
            } else {
                #expect(cached.count == 2)
                #expect(!jsonRead.take(), "the absent typed provider retains the existing JSON transport")
                #expect(cached.allSatisfy { $0.physicalBinding == nil })
                let rows = try await resourceRows(cache, registry, router)
                #expect(rows.allSatisfy { $0["mixer_strip_ref"] == nil })
            }
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: ["set_volume", "set_pan", "set_output_verified"])
    func physicalWriteReceiptsDoNotClaimArrangeTrackAssociation(command: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(aux: true)
            let (cache, registry, router, rows) = try await publish(fixture, background: true)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            fixture.reorder([2, 1, 0])
            let params: [String: Value] = command == "set_output_verified"
                ? ["target_ref": .string(reference), "destination": .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])])]
                : ["target_ref": .string(reference), "value": .double(command == "set_pan" ? 1 : AXValueExtractors.logicMixerFaderPositionToContract(110.0 / 233.0))]
            let result = await MixerDispatcher.handle(command: command, params: params,
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            let receipt = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(receipt["state"] as? String == "A")
            #expect(receipt["track"] == nil)
            #expect(receipt["mixer_strip_index"] as? Int == 2)
            if command == "set_output_verified" {
                #expect(fixture.b.attributeValue(fixture.outputs[0], kAXDescriptionAttribute as String) as? String == "Output 3-4")
                #expect(fixture.b.attributeValue(fixture.outputs[1], kAXDescriptionAttribute as String) as? String == "Stereo Output")
            } else {
                let identity = try #require(receipt["target_identity"] as? [String: Any])
                #expect(identity["track_index"] == nil)
                #expect(identity["mixer_strip_index"] as? Int == 2)
                #expect(fixture.mutations.allSatisfy { CFEqual($0.0, command == "set_pan" ? fixture.pans[0] : fixture.volumes[0]) })
            }
        }
    }

    @Test(arguments: ["late_role_absent", "late_help_failed", "late_children_failed", "depth_omitted_slider"])
    func physicalVolumeRequiresEveryPotentialCandidateExamined(shape: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            let late = fixture.b.element(2_915_000)
            fixture.b.setRole(late, kAXSliderRole as String)
            fixture.b.setAttribute(late, kAXDescriptionAttribute as String, shape == "late_help_failed" ? "" : "Volume")
            fixture.b.setAttribute(late, kAXHelpAttribute as String, "Volume fader")
            fixture.b.setAttribute(late, kAXValueAttribute as String, 100.0)
            fixture.b.setAttribute(late, kAXMinValueAttribute as String, 0.0)
            fixture.b.setAttribute(late, kAXMaxValueAttribute as String, 233.0)
            fixture.b.setChildren(late, [])
            var tail = late
            let levels = shape == "depth_omitted_slider" ? 4 : (shape == "late_children_failed" ? 1 : 0)
            for offset in 0..<levels {
                let group = fixture.b.element(2_915_001 + offset)
                fixture.b.setRole(group, kAXGroupRole as String)
                fixture.b.setChildren(group, [tail])
                tail = group
            }
            fixture.b.setChildren(fixture.strips[0], fixture.b.makeAXRuntime().children(fixture.strips[0]) + [tail])
            if shape == "late_role_absent" || shape == "late_help_failed" {
                fixture.attributeReadResult = { element, attribute in
                    guard CFEqual(element, late) else { return nil }
                    if shape == "late_role_absent", attribute == kAXRoleAttribute as String {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if shape == "late_help_failed", attribute == kAXHelpAttribute as String {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return nil
                }
            } else if shape == "late_children_failed" {
                let blocked = tail
                fixture.childrenReadResult = { CFEqual($0, blocked) ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil }
            }
            let observed = try #require(AccessibilityChannel.defaultGetMixerStates(runtime: fixture.logic, stoppingWhen: { false }).states)
            #expect(observed[0].volume == 0, "a failed unique fader selection must not supply a typed value")
            let result = await MixerDispatcher.handle(command: "set_volume",
                params: ["target_ref": .string(reference), "value": .double(AXValueExtractors.logicMixerFaderPositionToContract(110.0 / 233.0))],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "C")
            #expect(fixture.mutations.isEmpty)
            #expect(fixture.value(fixture.volumes[0]) == 100)
            #expect(fixture.value(late) == 100)
        }
    }

    @Test(arguments: ["send", "zoom"])
    func physicalPanEliminationCannotReacceptAnExplicitNonPan(identity: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            fixture.b.setChildren(fixture.pans[0], [])
            fixture.b.setAttribute(fixture.pans[0], kAXDescriptionAttribute as String, identity == "send" ? "send knob" : "Zoom")
            fixture.b.setAttribute(fixture.pans[0], kAXHelpAttribute as String, identity == "send"
                ? "Send Level knob. Set the level of the signal sent to the aux channel strip." : "Zoom slider")
            let result = await MixerDispatcher.handle(command: "set_pan", params: ["target_ref": .string(reference), "value": .double(1)],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            #expect(sharedJSONObject(sharedToolText(result))?["state"] as? String == "C")
            #expect(fixture.mutations.isEmpty)
            #expect(fixture.value(fixture.pans[0]) == 0)
            #expect(fixture.value(fixture.volumes[0]) == 100)
        }
    }

    @Test func physicalOutputCannotVerifyAnotherStripAfterPreReadReorder() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            // Existing legacy Mixer shape makes the first children read the physical membership
            // census, and the next the output operation's own census. Neither shape is a native claim.
            fixture.b.setRole(fixture.mixer, kAXGroupRole as String)
            fixture.b.setAttribute(fixture.mixer, kAXIdentifierAttribute as String, "Mixer")
            fixture.b.setAttribute(fixture.outputs[1], kAXDescriptionAttribute as String, "Output 3-4")
            let (cache, registry, router, rows) = try await publish(fixture)
            let reference = try #require(rows[0]["mixer_strip_ref"] as? String)
            let first = Once(); let second = Once()
            fixture.onChildrenResultRead = { element in
                guard CFEqual(element, fixture.mixer) else { return }
                if first.take() { return }
                if second.take() { fixture.reorder([1, 0]) }
            }
            defer { fixture.onChildrenResultRead = nil }
            let result = await MixerDispatcher.handle(command: "set_output_verified",
                params: ["target_ref": .string(reference), "destination": .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])])],
                router: router, cache: cache, targetRegistry: registry, liveTrackName: { [0: "A", 1: "B"][$0] }, liveTrackNames: { [0: "A", 1: "B"] })
            let receipt = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(receipt["state"] as? String == "A")
            let changed: Bool = try #require(receipt["changed"] as? Bool)
            #expect(changed, "already-at-destination Arrange A cannot verify referenced physical B")
            #expect(receipt["mixer_strip_index"] as? Int == 1)
            #expect(fixture.b.attributeValue(fixture.outputs[0], kAXDescriptionAttribute as String) as? String == "Output 3-4")
            #expect(!fixture.mutations.isEmpty)
            #expect(fixture.mutations.contains { CFEqual($0.0, fixture.outputs[0]) && $0.1 == kAXPressAction as String })
            #expect(!fixture.mutations.contains { CFEqual($0.0, fixture.outputs[1]) })
        }
    }
}
