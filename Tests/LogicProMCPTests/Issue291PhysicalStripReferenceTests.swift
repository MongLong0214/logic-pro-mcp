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

        init(aux: Bool = false, duplicateNames: Bool = false, secondAux: Bool = false) throws {
            let builder = b
            let stripCount = secondAux ? 4 : (aux ? 3 : 2)
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
                b.setAttribute(name, kAXValueAttribute as String, duplicateNames ? "Same" : ["B", "A", "Aux", "Aux 2"][i])
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

    @Test(arguments: ["fresh", "mixer_first", "tracks_first", "aux_only"])
    func physicalSourceNodesUseTheSameActualReferencesAsResourcesAndInspection(order: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(duplicateNames: true, secondAux: true)
            if order == "aux_only" {
                let rail = try #require(fixture.b.makeAXRuntime().children(fixture.window).first)
                fixture.b.setChildren(rail, [])
            }
            fixture.b.setAttribute(fixture.outputs[0], kAXDescriptionAttribute as String, "Bus 1")
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            let channel = fixture.channel(); await router.register(channel)
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                               projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await poller.refreshNow())
            if order == "tracks_first" {
                _ = try await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router,
                    targetRegistry: registry, fileReader: .unavailable)
            }
            // The individual resource is also a legitimate cold first reader.
            let individual = try await ResourceHandlers.read(uri: "logic://mixer/0", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable)
            let individualRef = try #require((sharedJSONObject(sharedResourceText(individual))?["strip"] as? [String: Any])?["mixer_strip_ref"] as? String)
            if order == "mixer_first" {
                _ = try await resourceRows(cache, registry, router)
            }
            let gate = LogicMutationGate()
            let deps = HandlerDependencies(router: router, cache: cache, targetRegistry: registry, poller: poller,
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [0: "A", 1: "B"] }, projectFileReader: .unavailable)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let params: [String: Value] = ["domains": .array([.string("tracks"), .string("strips"), .string("routing")]), "allow_ui_navigation": .bool(false)]
            let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
                commandParams: params, mutationGate: gate) { await handler(deps, params) }
            let isError = result.isError ?? false
            #expect(!isError)
            let report = try #require(sharedJSONObject(sharedToolText(result)))
            let inspectedRows = try #require((report["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
            let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable)
            let object = try #require(sharedJSONObject(sharedResourceText(resource)))
            let rows = try #require(object["strips"] as? [[String: Any]])
            let graph = try #require(object["routing_graph"] as? [String: Any])
            let nodes = try #require(graph["nodes"] as? [[String: Any]])
            let references = rows.compactMap { $0["mixer_strip_ref"] as? String }
            #expect(references.count == 4)
            #expect(Set(references).count == 4)
            #expect(references.first == individualRef)
            #expect(inspectedRows.compactMap { $0["mixer_strip_ref"] as? String } == references)
            #expect(Set(nodes.compactMap { $0["id"] as? String }) == Set(references))
            #expect(nodes.count == 4)
            #expect(nodes.allSatisfy { $0["kind"] as? String == "physical_strip" })
            #expect(nodes.allSatisfy { ($0["targetRef"] as? [String: Any])?["rawValue"] as? String == $0["id"] as? String })
            #expect(try #require(graph["edges"] as? [[String: Any]]).isEmpty)
            let complete = try #require(graph["complete"] as? Bool)
            #expect(!complete)
            let routing = try #require(report["routing"] as? [String: Any])
            #expect(Set((routing["nodes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }) == Set(references))
            #expect(NSDictionary(dictionary: try #require(routing["graph"] as? [String: Any]))
                .isEqual(to: try #require(graph["coverage"] as? [String: Any])))
            for reference in references {
                let binding = try #require(await registry.resolve(TargetReference(rawValue: reference)))
                #expect(binding.kind == .mixerStrip)
                #expect(binding.physicalMixerStrip != nil)
            }
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func capturedPhysicalInputSlotsReachTheSameResourceAndInspectionNodes(background: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(duplicateNames: true, secondAux: true)
            let rail = try #require(fixture.b.makeAXRuntime().children(fixture.window).first)
            fixture.b.setChildren(rail, [])
            let sources = ["Bus 1", "Input 3"]
            for (offset, source) in sources.enumerated() {
                let receiver = fixture.strips[2 + offset]
                let input = fixture.b.element(2_911_000 + offset)
                fixture.b.setButton(input, description: source,
                    help: "Input slot. Choose the channel strip input source.",
                    x: 0, y: 0, width: 1, height: 1)
                fixture.b.setChildren(input, [])
                fixture.b.setChildren(receiver, fixture.b.makeAXRuntime().children(receiver) + [input])
            }
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            let channel = fixture.channel(); await router.register(channel)
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                               projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            if background { #expect(await poller.refreshNow()) }
            let gate = LogicMutationGate()
            let deps = HandlerDependencies(router: router, cache: cache, targetRegistry: registry, poller: poller,
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [:] }, projectFileReader: .unavailable)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let params: [String: Value] = ["domains": .array([.string("strips"), .string("routing")]),
                                         "allow_ui_navigation": .bool(false)]
            let response = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
                commandParams: params, mutationGate: gate) { await handler(deps, params) }
            let isError = response.isError ?? false
            #expect(!isError)
            let report = try #require(sharedJSONObject(sharedToolText(response)))
            let inspectedRows = try #require((report["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
            let inspectedRouting = try #require(report["routing"] as? [String: Any])
            let inspectedNodes = try #require(inspectedRouting["nodes"] as? [[String: Any]])
            let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable)
            let body = try #require(sharedJSONObject(sharedResourceText(resource)))
            let rows = try #require(body["strips"] as? [[String: Any]])
            let graph = try #require(body["routing_graph"] as? [String: Any])
            let nodes = try #require(graph["nodes"] as? [[String: Any]])
            try #require(rows.count == 4 && inspectedRows.count == 4)
            let references = try rows.map { try #require($0["mixer_strip_ref"] as? String) }
            #expect(Set(references).count == 4)
            #expect(inspectedRows.compactMap { $0["mixer_strip_ref"] as? String } == references)
            #expect(nodes.allSatisfy { $0["kind"] as? String == "physical_strip" })
            #expect(nodes.allSatisfy { $0["displayName"] as? String == "Same" })
            for (offset, source) in sources.enumerated() {
                let reference = references[2 + offset]
                let node = try #require(nodes.first { $0["id"] as? String == reference })
                let inspectedNode = try #require(inspectedNodes.first { $0["id"] as? String == reference })
                #expect((node["observed_input_slot"] as? [String: Any])?["state"] as? String == "observed_source")
                #expect((node["observed_input_slot"] as? [String: Any])?["source"] as? String == source)
                #expect((inspectedNode["observed_input_slot"] as? [String: Any])?["state"] as? String == "observed_source")
                #expect((inspectedNode["observed_input_slot"] as? [String: Any])?["source"] as? String == source)
                #expect(rows[2 + offset]["input"] as? String == source)
            }
            #expect(try #require(graph["edges"] as? [[String: Any]]).isEmpty)
            #expect(((graph["coverage"] as? [String: Any])?["bus_to_aux_input"] as? [String: Any])?["state"] as? String == "not_observed")
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func sameLabelInputReplacementBetweenBookendsDoesNotAdoptNewSlotCustody() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(duplicateNames: true)
            let old = fixture.b.element(2_911_100)
            let replacement = fixture.b.element(2_911_101)
            let unaffected = fixture.b.element(2_911_102)
            for control in [old, replacement, unaffected] {
                fixture.b.setButton(control, description: "Bus 1",
                    help: "Input slot. Choose the channel strip input source.",
                    x: 0, y: 0, width: 1, height: 1)
                fixture.b.setChildren(control, [])
            }
            let originalChildren = fixture.b.makeAXRuntime().children(fixture.strips[0])
            fixture.b.setChildren(fixture.strips[0], originalChildren + [old])
            fixture.b.setChildren(fixture.strips[1], fixture.b.makeAXRuntime().children(fixture.strips[1]) + [unaffected])
            let sawOld = Once(); let sawReplacement = Once(); let changed = Once()
            fixture.onAttributeRead = { element, attribute in
                guard attribute == kAXDescriptionAttribute as String else { return }
                if CFEqual(element, old) { _ = sawOld.take() }
                if CFEqual(element, replacement) { _ = sawReplacement.take() }
            }
            defer { fixture.onAttributeRead = nil }
            let fileReader = LogicProjectFileReader.Runtime(currentDocumentPath: { nil }, now: Date.init,
                readPlistData: { _ in nil }, mtime: { _ in
                    if changed.take() {
                        #expect(!sawOld.take(), "the original input's deciding description read must precede this metadata gap")
                        fixture.b.setChildren(fixture.strips[0], originalChildren + [replacement])
                    }
                    return nil
                }, sleep: { _ in })
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            let channel = fixture.channel(); await router.register(channel)
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                               projectFileReader: fileReader, keyboardFocus: { .notTextEditing }))
            let gate = LogicMutationGate()
            let deps = HandlerDependencies(router: router, cache: cache, targetRegistry: registry, poller: poller,
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [0: "Same", 1: "Same"] }, projectFileReader: fileReader)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let params: [String: Value] = ["domains": .array([.string("tracks"), .string("strips"), .string("routing")]),
                                         "allow_ui_navigation": .bool(false)]
            let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
                commandParams: params, mutationGate: gate) { await handler(deps, params) }
            let isError = result.isError ?? false
            #expect(!isError)
            #expect(!changed.take() && !sawReplacement.take(), "the one replacement and its subsequent deciding read must both execute")
            let report = try #require(sharedJSONObject(sharedToolText(result)))
            #expect((report["strips"] as? [String: Any])?["coverage"] as? String == "partial")
            #expect((report["tracks"] as? [String: Any])?["coverage"] as? String == "partial")
            let inspected = try #require((report["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
            #expect(inspected.count == 2)
            #expect(inspected[0]["input_status"] as? String == "unreadable")
            #expect(inspected[0]["input"] == nil)
            #expect(inspected[1]["input"] as? String == "Bus 1")
            let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable)
            let body = try #require(sharedJSONObject(sharedResourceText(resource)))
            let rows = try #require(body["strips"] as? [[String: Any]])
            let nodes = try #require((body["routing_graph"] as? [String: Any])?["nodes"] as? [[String: Any]])
            let references = rows.compactMap { $0["mixer_strip_ref"] as? String }
            try #require(references.count == 2)
            let affectedNode = try #require(nodes.first { $0["id"] as? String == references[0] })
            let unaffectedNode = try #require(nodes.first { $0["id"] as? String == references[1] })
            #expect(affectedNode["observed_input_slot"] == nil)
            #expect((unaffectedNode["observed_input_slot"] as? [String: Any])?["source"] as? String == "Bus 1")
            #expect(fixture.mutations.isEmpty)
        }
    }

    private final class RetryInputTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        private var unreadArmed = false
        func record(_ event: String) -> Int {
            lock.withLock { events.append(event); return events.filter { $0 == event }.count }
        }
        func count(_ event: String) -> Int { lock.withLock { events.filter { $0 == event }.count } }
        func armUnread() { lock.withLock { unreadArmed = true } }
        func consumeUnread() -> Bool {
            lock.withLock { if !unreadArmed { return false }; unreadArmed = false; return true }
        }
    }

    @Test(arguments: ["title_retry", "unread_population_retry"])
    func earlierInputSampleCannotBeForgottenAcrossPopulationRetries(gap: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(duplicateNames: true)
            // The existing legacy-ID shape gives this fixture a decisive Mixer lookup, so
            // unread_population_retry fails the population enumeration, not an unrelated walk.
            fixture.b.setRole(fixture.mixer, kAXGroupRole as String)
            fixture.b.setAttribute(fixture.mixer, kAXIdentifierAttribute as String, "Mixer")
            let originalChildren = fixture.b.makeAXRuntime().children(fixture.strips[0])
            let old = addInput(fixture, strip: fixture.strips[0], id: 2_911_600)
            let replacement = fixture.b.element(2_911_601)
            fixture.b.setButton(replacement, description: "Bus 1",
                help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 1, height: 1)
            fixture.b.setChildren(replacement, [])
            _ = addInput(fixture, strip: fixture.strips[1], id: 2_911_602, source: "Input 3")
            let trace = RetryInputTrace(); let metadataGap = Once()
            fixture.onAttributeRead = { element, attribute in
                guard attribute == kAXDescriptionAttribute as String else { return }
                if CFEqual(element, old) {
                    let count = trace.record("old_deciding_read")
                    if gap == "title_retry", count == 2 {
                        #expect(trace.count("metadata_gap") == 1)
                        _ = trace.record("replacement")
                        // The current walk retained C1 and still reads its unchanged value;
                        // the next actual sample traverses the newly installed C2 instead.
                        fixture.b.setChildren(fixture.strips[0], originalChildren + [replacement])
                    }
                }
                if CFEqual(element, replacement) { _ = trace.record("replacement_deciding_read") }
            }
            fixture.childrenReadResult = { element in
                guard CFEqual(element, fixture.mixer), trace.consumeUnread() else { return nil }
                _ = trace.record("population_unread")
                #expect(trace.count("old_deciding_read") == 1)
                _ = trace.record("replacement")
                fixture.b.setChildren(fixture.strips[0], originalChildren + [replacement])
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            defer { fixture.onAttributeRead = nil; fixture.childrenReadResult = nil }
            let fileReader = LogicProjectFileReader.Runtime(currentDocumentPath: { nil }, now: Date.init,
                readPlistData: { _ in nil }, mtime: { _ in
                    if metadataGap.take() {
                        _ = trace.record("metadata_gap")
                        #expect(trace.count("old_deciding_read") == 1)
                        if gap == "title_retry" {
                            fixture.b.setAttribute(fixture.window, kAXTitleAttribute as String, "Session - Tracks (retry)")
                        } else { trace.armUnread() }
                    }
                    return nil
                }, sleep: { _ in })
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            let channel = fixture.channel(); await router.register(channel)
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                               projectFileReader: fileReader, keyboardFocus: { .notTextEditing }))
            let gate = LogicMutationGate()
            let deps = HandlerDependencies(router: router, cache: cache, targetRegistry: registry, poller: poller,
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [:] }, projectFileReader: fileReader)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let params: [String: Value] = ["domains": .array([.string("strips"), .string("routing")]),
                                         "allow_ui_navigation": .bool(false)]
            let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
                commandParams: params, mutationGate: gate) { await handler(deps, params) }
            let isError = result.isError ?? false
            #expect(!isError)
            #expect(trace.count("metadata_gap") == 1 && trace.count("replacement") == 1)
            #expect(trace.count("old_deciding_read") == (gap == "title_retry" ? 2 : 1))
            #expect(trace.count("replacement_deciding_read") == 2, "the retry must actually sample C2 before and after")
            #expect(trace.count("population_unread") == (gap == "unread_population_retry" ? 1 : 0))
            #expect(fixture.b.attributeValue(fixture.window, kAXDocumentAttribute as String) as? String == fixture.bundle.absoluteString)
            let observedFocus = try #require(fixture.b.makeAXRuntime().attributeValue(fixture.app, kAXFocusedWindowAttribute as String))
            #expect(CFEqual(observedFocus, fixture.window))
            let report = try #require(sharedJSONObject(sharedToolText(result)))
            #expect((report["strips"] as? [String: Any])?["coverage"] as? String == "partial")
            let inspected = try #require((report["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
            try #require(inspected.count == 2)
            #expect(inspected[0]["input_status"] as? String == "unreadable")
            #expect(inspected[0]["input"] == nil)
            #expect(inspected[1]["input"] as? String == "Input 3")
            let nodes = try #require((report["routing"] as? [String: Any])?["nodes"] as? [[String: Any]])
            let reference = try #require(inspected[0]["mixer_strip_ref"] as? String)
            #expect(try #require(nodes.first { $0["id"] as? String == reference })["observed_input_slot"] == nil)
            let resource = try await inputGraph(cache, registry, router)
            #expect(resource.rows.compactMap { $0["mixer_strip_ref"] as? String } == inspected.compactMap { $0["mixer_strip_ref"] as? String })
            #expect(try #require(resource.graph.nodes.first { $0.id == reference }).observedInputSlot == nil)
            let unaffectedRef = try #require(inspected[1]["mixer_strip_ref"] as? String)
            #expect(resource.graph.nodes.first { $0.id == unaffectedRef }?.observedInputSlot?.source == "Input 3")
            #expect(resource.graph.edges.isEmpty && resource.graph.coverage.busToAuxInput.state == .notObserved)
            #expect(fixture.mutations.isEmpty)
        }
    }

    private func addInput(_ fixture: Fixture, strip: AXUIElement, id: Int, source: String = "Bus 1") -> AXUIElement {
        let input = fixture.b.element(id)
        fixture.b.setButton(input, description: source,
            help: "Input slot. Choose the channel strip input source.", x: 0, y: 0, width: 1, height: 1)
        fixture.b.setChildren(input, [])
        fixture.b.setChildren(strip, fixture.b.makeAXRuntime().children(strip) + [input])
        return input
    }

    private func inputGraph(_ cache: StateCache, _ registry: TargetRegistry, _ router: ChannelRouter) async throws
        -> (rows: [[String: Any]], graph: RoutingGraph) {
        let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let body = try #require(sharedJSONObject(sharedResourceText(resource)))
        let object = try #require(body["routing_graph"] as? [String: Any])
        return (try #require(body["strips"] as? [[String: Any]]),
                try JSONDecoder().decode(RoutingGraph.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    @Test(arguments: ["no_slot", "blank", "description", "help", "role", "children", "duplicate", "unknown_bus", "depth", "cycle"])
    func incompleteOrAmbiguousInputReadsDoNotPublishPhysicalSlotCustody(shape: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let strip = fixture.strips[0]
            let originalChildren = fixture.b.makeAXRuntime().children(strip)
            let input = addInput(fixture, strip: strip, id: 2_911_200, source: shape == "blank" ? "" : "Bus 1")
            if shape == "no_slot" { fixture.b.setChildren(strip, originalChildren) }
            if shape == "duplicate" || shape == "unknown_bus" {
                let competitor = addInput(fixture, strip: strip, id: 2_911_201, source: "Bus 2")
                if shape == "unknown_bus" {
                    fixture.b.setAttribute(competitor, kAXHelpAttribute as String, "Unidentified source control")
                }
            }
            if ["description", "help", "role"].contains(shape) {
                let deciding = shape == "description" ? kAXDescriptionAttribute as String
                    : (shape == "help" ? kAXHelpAttribute as String : kAXRoleAttribute as String)
                fixture.attributeReadResult = { element, attribute in
                    CFEqual(element, input) && attribute == deciding
                        ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
                }
            }
            if shape == "children" {
                fixture.childrenReadResult = { CFEqual($0, input) ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil }
            }
            if shape == "depth" {
                var nested = input
                for offset in 0..<4 {
                    let group = fixture.b.element(2_911_210 + offset)
                    fixture.b.setRole(group, kAXGroupRole as String)
                    fixture.b.setChildren(group, [nested]); nested = group
                }
                fixture.b.setChildren(strip, originalChildren + [nested])
            }
            if shape == "cycle" { fixture.b.setChildren(input, [input]) }
            let (cache, registry, router, _) = try await publish(fixture, background: true)
            let state = try #require(await cache.getChannelStrips().first)
            #expect(state.inputSlotBinding == nil)
            #expect(state.inputObservation?.state == (shape == "no_slot" ? .noSlot : .unreadable))
            let (rows, graph) = try await inputGraph(cache, registry, router)
            let reference = try #require(rows.first?["mixer_strip_ref"] as? String)
            let node = try #require(graph.nodes.first { $0.id == reference })
            #expect(node.observedInputSlot == nil)
            #expect(graph.edges.isEmpty && graph.coverage.busToAuxInput.state == .notObserved)
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func ordinaryAndScheduledTypedInputCustodyFollowsPhysicalReferencesThroughReorder(scheduled: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(duplicateNames: true)
            fixture.b.setChildren(fixture.b.element(2_910_003), [])
            _ = addInput(fixture, strip: fixture.strips[0], id: 2_911_300, source: "Bus 1")
            _ = addInput(fixture, strip: fixture.strips[1], id: 2_911_301, source: "Input 3")
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            let channel = fixture.channel(); await router.register(channel)
            let (finished, completion) = AsyncStream<Void>.makeStream()
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, sleep: { _ in
                    completion.finish(); throw CancellationError()
                }, blockingDialogInfo: { nil }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            if scheduled {
                await poller.start(); for await _ in finished {}; await poller.stop()
            } else { #expect(await poller.refreshNow()) }
            let first = try await inputGraph(cache, registry, router)
            let firstRef = try #require(first.rows[0]["mixer_strip_ref"] as? String)
            let secondRef = try #require(first.rows[1]["mixer_strip_ref"] as? String)
            #expect(firstRef != secondRef)
            #expect(first.graph.nodes.first { $0.id == firstRef }?.observedInputSlot?.source == "Bus 1")
            #expect(first.graph.nodes.first { $0.id == secondRef }?.observedInputSlot?.source == "Input 3")
            fixture.reorder([1, 0])
            // stop() intentionally leaves that scheduled poller stopped. A fresh ordinary
            // producer performs the next real refresh, rather than bypassing its stop latch.
            let ordinary = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await ordinary.refreshNow())
            let reordered = try await inputGraph(cache, registry, router)
            #expect(reordered.rows.compactMap { $0["mixer_strip_ref"] as? String } == [secondRef, firstRef])
            #expect(reordered.graph.nodes.first { $0.id == firstRef }?.observedInputSlot?.source == "Bus 1")
            #expect(reordered.graph.nodes.first { $0.id == secondRef }?.observedInputSlot?.source == "Input 3")
            #expect(reordered.graph.edges.isEmpty && fixture.mutations.isEmpty)
        }
    }

    @Test func encodedInputDisplayCannotReconstructOwnControlCustody() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            _ = addInput(fixture, strip: fixture.strips[0], id: 2_911_400)
            let (cache, registry, router, _) = try await publish(fixture, background: true)
            let native = await cache.getChannelStrips()
            #expect(native[0].inputSlotBinding != nil)
            var imported = try JSONDecoder().decode([ChannelStripState].self, from: JSONEncoder().encode(native))
            #expect(imported[0].inputObservation?.source == "Bus 1")
            #expect(imported.allSatisfy { $0.physicalBinding == nil && $0.inputSlotBinding == nil })
            await cache.updateChannelStrips(imported)
            let display = try await inputGraph(cache, registry, router)
            #expect(display.rows.allSatisfy { $0["mixer_strip_ref"] == nil })
            #expect(display.graph.nodes.allSatisfy { $0.observedInputSlot == nil })
            // Even a separately legitimate physical strip owner does not authenticate imported
            // input display. Only the typed own-control observation may supply this node field.
            imported[0].physicalBinding = native[0].physicalBinding
            await cache.updateChannelStrips(imported)
            let physical = try await inputGraph(cache, registry, router)
            let reference = try #require(physical.rows[0]["mixer_strip_ref"] as? String)
            #expect(try #require(physical.graph.nodes.first { $0.id == reference }).observedInputSlot == nil)
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func JSONFallbackAndUnreadTypedMixerCannotPublishInputControlCustody(typedUnread: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            _ = addInput(fixture, strip: fixture.strips[0], id: 2_911_500)
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            let channel = fixture.channel(typedMixer: typedUnread, typedUnread: typedUnread)
            await router.register(channel)
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await poller.refreshNow())
            let states = await cache.getChannelStrips()
            if !typedUnread { #expect(states.first?.inputObservation?.source == "Bus 1") }
            #expect(states.allSatisfy { $0.inputSlotBinding == nil && $0.physicalBinding == nil })
            let display = try await inputGraph(cache, registry, router)
            #expect(display.graph.nodes.allSatisfy { $0.observedInputSlot == nil })
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func MCUDisplayAndFaderCacheCannotSupplyPhysicalInputSlotCustody() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let cache = StateCache(); let registry = TargetRegistry(); let router = ChannelRouter()
            await cache.updateProject(.init(name: "Session", filePath: fixture.bundle.path, source: "fixture"))
            await cache.updateDocumentState(true)
            await cache.updateMCUDisplayRow(upper: true, text: "Bus 1", offset: 0)
            await cache.updateFader(strip: 0, volume: 0.5)
            #expect(await cache.getMCUDisplay().upperRow.hasPrefix("Bus 1"))
            let strip = try #require(await cache.getChannelStrips().first)
            #expect(strip.physicalBinding == nil && strip.inputSlotBinding == nil && strip.inputObservation == nil)
            let display = try await inputGraph(cache, registry, router)
            #expect(display.rows.allSatisfy { $0["mixer_strip_ref"] == nil })
            #expect(display.graph.nodes.allSatisfy { $0.observedInputSlot == nil })
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func scheduledPhysicalSourceNodePublicationNeedsNoArrangeOrPreliminaryResource() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(secondAux: true)
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
            let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable)
            let object = try #require(sharedJSONObject(sharedResourceText(resource)))
            let rows = try #require(object["strips"] as? [[String: Any]])
            let graph = try #require(object["routing_graph"] as? [String: Any])
            let nodes = try #require(graph["nodes"] as? [[String: Any]])
            let references = rows.compactMap { $0["mixer_strip_ref"] as? String }
            #expect(Set(references).count == 4)
            #expect(Set(nodes.compactMap { $0["id"] as? String }) == Set(references))
            #expect(nodes.allSatisfy { $0["kind"] as? String == "physical_strip" })
            #expect(try #require(graph["edges"] as? [[String: Any]]).isEmpty)
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func physicalSourceIdentityDoesNotUseNamesOrMixerOrdinalsAndNeverGrantsTrackWriteAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture(duplicateNames: true, secondAux: true)
            let (cache, registry, router, original) = try await publish(fixture, background: true)
            let originalRefs = original.compactMap { $0["mixer_strip_ref"] as? String }
            var duplicateOrdinals = await cache.getChannelStrips()
            for i in duplicateOrdinals.indices { duplicateOrdinals[i].trackIndex = 0 }
            await cache.updateChannelStrips(duplicateOrdinals)
            let duplicateRows = try await resourceRows(cache, registry, router)
            #expect(duplicateRows.compactMap { $0["mixer_strip_ref"] as? String } == originalRefs)
            fixture.reorder([3, 1, 0, 2])
            let channel = fixture.channel()
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                               projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await poller.refreshNow())
            let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable)
            let object = try #require(sharedJSONObject(sharedResourceText(resource)))
            let rows = try #require(object["strips"] as? [[String: Any]])
            #expect(rows.compactMap { $0["mixer_strip_ref"] as? String } == [3, 1, 0, 2].map { originalRefs[$0] })
            let graphObject = try #require(object["routing_graph"] as? [String: Any])
            let graph = try JSONDecoder().decode(RoutingGraph.self, from: JSONSerialization.data(withJSONObject: graphObject))
            #expect(Set(graph.nodes.map(\.id)) == Set(originalRefs))
            #expect(graph.edges.isEmpty)
            let decision = evaluate(.init(sourceTrackRef: TargetReference(rawValue: originalRefs[0]),
                physicalSlot: 0, destinationBusNumber: 1, destinationRef: nil,
                expectedProjectEpoch: graph.projectEpoch), against: graph)
            #expect(!decision.allowed)
            #expect(decision.rejections.contains(.sourceNotFound))
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test(arguments: ["json", "disabled", "duplicate_physical"])
    func physicalSourcePublicationCannotManufactureUniqueOwnership(loss: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(loss != "disabled") {
            let fixture = try Fixture()
            let (cache, registry, router, _) = try await publish(fixture, background: true)
            let typed = await cache.getChannelStrips()
            if loss == "json" {
                let data = try JSONEncoder().encode(typed)
                await cache.updateChannelStrips(try JSONDecoder().decode([ChannelStripState].self, from: data))
            } else if loss == "duplicate_physical" {
                await cache.updateChannelStrips([typed[0], typed[0]])
            }
            let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable)
            let object = try #require(sharedJSONObject(sharedResourceText(resource)))
            let rows = try #require(object["strips"] as? [[String: Any]])
            let nodes = try #require((object["routing_graph"] as? [String: Any])?["nodes"] as? [[String: Any]])
            #expect(rows.allSatisfy { $0["mixer_strip_ref"] == nil })
            #expect(!nodes.contains { $0["kind"] as? String == "physical_strip" })
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func stalePhysicalReferenceIssuanceMakesInspectionUnstableWithoutPublishingAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            fixture.reportedProjectPath = "/injected-other.logicx"
            let cache = StateCache(); let registry = TargetRegistry()
            let channel = fixture.channel()
            let poller = StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                               projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
            #expect(await poller.refreshNow())
            let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: registry, fileReader: .unavailable)
            let report = SessionPopulationObservation.build(request: .init(domains: [.tracks, .strips, .routing]), capture: capture)
            #expect(report.tracks.coverage == .partial)
            #expect(!report.tracks.reasons.contains(.targetSnapshotStale))
            #expect(report.tracks.rows.allSatisfy { $0.trackRef != nil })
            #expect(report.strips.coverage == .unstable)
            #expect(report.strips.reasons.contains(.targetSnapshotStale))
            #expect(report.strips.rows.allSatisfy { $0.mixerStripRef == nil })
            #expect(SessionPopulationObservation.routingGraph(capture: capture).nodes.isEmpty)
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func physicalSourceCaptureMovementAndCancellationNeverPublishCurrentAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, _, _) = try await publish(fixture, background: true)
            let fileReader = LogicProjectFileReader.Runtime(currentDocumentPath: {
                await cache.updateAXOccluded(true)
                return nil
            }, now: Date.init, readPlistData: { _ in nil }, mtime: { _ in nil }, sleep: { _ in })
            let moved = await SessionPopulationObservation.capture(cache: cache, targetRegistry: registry, fileReader: fileReader)
            #expect(moved.before != moved.after)
            let movedReport = SessionPopulationObservation.build(request: .init(domains: [.strips, .routing]), capture: moved)
            #expect(movedReport.strips.coverage == .unstable)
            #expect(movedReport.strips.rows.allSatisfy { $0.mixerStripRef == nil })
            #expect(SessionPopulationObservation.routingGraph(capture: moved).nodes.isEmpty)
            await cache.updateAXOccluded(false)
            let cancelled = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await SessionPopulationObservation.capture(cache: cache, targetRegistry: registry, fileReader: .unavailable)
            }.value
            #expect(cancelled.mixerReferences == nil)
            #expect(cancelled.referencesStale)
            #expect(SessionPopulationObservation.routingGraph(capture: cancelled).nodes.isEmpty)
            #expect(SessionPopulationObservation.build(request: .init(domains: [.strips]), capture: cancelled).strips.coverage == .unstable)
            #expect(fixture.mutations.isEmpty)
        }
    }

    @Test func physicalSourceReferencesReissueThroughTheSameCaptureAfterRegistryMovement() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = try Fixture()
            let (cache, registry, router, rows) = try await publish(fixture, background: true)
            let old = rows.compactMap { $0["mixer_strip_ref"] as? String }
            await registry.bumpTopologyGeneration()
            let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable)
            let object = try #require(sharedJSONObject(sharedResourceText(resource)))
            let newRows = try #require(object["strips"] as? [[String: Any]])
            let references = newRows.compactMap { $0["mixer_strip_ref"] as? String }
            #expect(Set(references).count == 2)
            #expect(Set(references).isDisjoint(with: old))
            let nodes = try #require((object["routing_graph"] as? [String: Any])?["nodes"] as? [[String: Any]])
            #expect(Set(nodes.compactMap { $0["id"] as? String }) == Set(references))
            for reference in old { #expect(await registry.resolve(TargetReference(rawValue: reference)) == nil) }
            for reference in references { #expect(await registry.resolve(TargetReference(rawValue: reference))?.physicalMixerStrip != nil) }
            #expect(fixture.mutations.isEmpty)
        }
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
            let nodes = try #require(graph["nodes"] as? [[String: Any]])
            #expect(Set(nodes.compactMap { $0["id"] as? String }) == Set(rows.compactMap { $0["mixer_strip_ref"] as? String }))
            #expect(nodes.allSatisfy { $0["kind"] as? String == "physical_strip" },
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
