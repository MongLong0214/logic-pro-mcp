@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#965 held selection association", .serialized)
struct Issue965HeldSelectionAssociationTests {
    @Test func publicDescriptionDistinguishesPhysicalPairsFromWholePopulation() {
        let description = ProjectDispatcher.tool.description ?? ""
        #expect(description.contains("held exclusive selection"), "Describe the implemented physical observation, not name/index joins")
        #expect(description.contains("partial association pairs"), "A bounded pair witness is not complete population coverage")
        #expect(!description.contains("actual track-to-strip associations remain unimplemented"), "The registered producer already publishes verified physical pairs")
        #expect(description.contains("complete population remain unqualified"), "Do not turn a capability-description correction into a native/global acceptance claim")
    }

    private final class Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let mixer: AXUIElement
        let headers: [AXUIElement]
        let strips: [AXUIElement]
        let scroll: AXUIElement
        let bundle: URL
        var selections: [Int] = []
        var scrollWrites: [Double] = []
        var viewportReadsAfterSelection = 0
        var inverseValueReadCount = 0
        var viewportFaultAtRead: Int?
        var viewportFaultInjected = false
        var referenceCurrent = true
        var useBulkReads = false
        var batchReadCalls = 0
        var reciprocalPathBatchCalls = 0
        var pathBatchFault: String?
        var windowScopeBatchCalls = 0
        var windowScopeBatchFault: String?
        var fault: String?
        var transientEditorRead = false
        var transientForeignRead = false
        var metadataReads = 0
        var focusReadsBeforeWrite = [0, 0]
        var scopeLossPhase: Int?
        var scopeLossRead: Int?
        var scopeLossInjected = false
        var loseNextSelectionRead = false
        var postRestoreSelectionFaults = 0
        var volatileSlider: AXUIElement?
        var transientZoomRoleObserved = false
        var zoomRoleReadsAfterSelection = 0
        var zoomRoleReadsAtFirstValue: Int?
        var zoomRoleFaultAtRead: Int?
        var routingReplacement: AXUIElement?
        var routingAction: (@Sendable (AXUIElement, String) -> Bool)?
        var routingDestinationPresses = 0
        var routingWrongSourcePressed = false
        var expireRetainedCapture = false
        var routingRead: (@Sendable (AXUIElement, String) -> Void)?
        var routingSelection: (@Sendable (Int) -> Void)?
        var routingLateScopeInjected = false

        init(withViewport: Bool = false) throws {
            bundle = FileManager.default.temporaryDirectory.appendingPathComponent("965-selection-\(UUID().uuidString).logicx")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            app = builder.element(1_965_700)
            window = builder.element(1_965_701)
            rail = builder.element(1_965_702)
            mixer = builder.element(1_965_703)
            headers = [builder.element(1_965_704), builder.element(1_965_705)]
            strips = [builder.element(1_965_706), builder.element(1_965_707)]
            scroll = builder.element(1_965_708)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Selection fixture - Tracks")
            builder.setAttribute(window, kAXDocumentAttribute as String, bundle.absoluteString)
            builder.setAttribute(app, kAXWindowsAttribute as String, [window])
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setAttribute(app, kAXFocusedWindowAttribute as String, window)
            builder.setAttribute(app, kAXFrontmostAttribute as String, true)
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, strips[1])
            builder.setRole(rail, kAXListRole as String)
            builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            builder.setAttributeSettable(rail, kAXSelectedChildrenAttribute as String, true)
            builder.setRole(mixer, kAXGroupRole as String)
            builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
            for (index, header) in headers.enumerated() {
                builder.setRole(header, kAXLayoutItemRole as String)
                builder.setAttribute(header, kAXTitleAttribute as String, "Duplicate")
                builder.setAttribute(header, kAXSelectedAttribute as String, index == 0)
                builder.setChildren(header, [])
            }
            for (index, strip) in strips.enumerated() {
                builder.setRole(strip, kAXLayoutItemRole as String)
                builder.setAttribute(strip, kAXNumberOfCharactersAttribute as String, 0)
                builder.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, 0)
                let name = builder.element(1_965_710 + index)
                builder.setRole(name, kAXTextFieldRole as String)
                builder.setAttribute(name, kAXDescriptionAttribute as String, "Name")
                builder.setAttribute(name, kAXValueAttribute as String, "Duplicate")
                builder.setChildren(strip, [name])
            }
            builder.setChildren(rail, headers)
            builder.setChildren(mixer, strips)
            let bar = builder.element(1_965_720)
            let play = builder.element(1_965_721)
            let record = builder.element(1_965_722)
            builder.setRole(bar, kAXGroupRole as String)
            builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
            for (control, title) in [(play, "Play"), (record, "Record")] {
                builder.setRole(control, kAXCheckBoxRole as String)
                builder.setAttribute(control, kAXTitleAttribute as String, title)
                builder.setAttribute(control, kAXValueAttribute as String, 0)
                builder.setChildren(control, [])
            }
            builder.setChildren(bar, [play, record])
            builder.setRole(scroll, kAXScrollBarRole as String)
            builder.setAttribute(scroll, kAXValueAttribute as String, NSNumber(value: 0.8))
            builder.setAttributeSettable(scroll, kAXValueAttribute as String, true)
            builder.setChildren(scroll, [])
            builder.setChildren(window, [rail, mixer, bar] + (withViewport ? [scroll] : []))
        }

        deinit { try? FileManager.default.removeItem(at: bundle) }

        func channel() -> AccessibilityChannel {
            let base = builder.makeLogicRuntime(appElement: app,
                attributeValueHandler: { [self] element, attribute in
                    routingRead?(element, attribute)
                    if CFEqual(element, scroll), selections.count == 1 {
                        if attribute == kAXRoleAttribute as String {
                            zoomRoleReadsAfterSelection += 1
                            if zoomRoleReadsAfterSelection == zoomRoleFaultAtRead {
                                transientZoomRoleObserved = true
                                return .some(kAXTextFieldRole as NSString)
                            }
                        }
                        if attribute == kAXValueAttribute as String, zoomRoleReadsAtFirstValue == nil {
                            zoomRoleReadsAtFirstValue = zoomRoleReadsAfterSelection
                        }
                    }
                    if CFEqual(element, scroll), attribute == kAXValueAttribute as String, selections.count == 2 {
                        viewportReadsAfterSelection += 1
                        if viewportFaultAtRead == viewportReadsAfterSelection {
                            viewportFaultInjected = true
                            if fault == "scroll_document" { builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                            if fault == "scroll_focus" { builder.setAttribute(app, kAXFocusedUIElementAttribute as String, builder.element(1_965_730)) }
                            if fault == "scroll_playback" { builder.setAttribute(builder.element(1_965_721), kAXValueAttribute as String, 1) }
                            if fault == "scroll_cancel" { withUnsafeCurrentTask { $0?.cancel() } }
                            if fault == "scroll_reference" { referenceCurrent = false }
                            if fault == "scroll_replacement" {
                                let replacement = builder.element(1_965_741)
                                builder.setRole(replacement, kAXScrollBarRole as String)
                                builder.setAttribute(replacement, kAXValueAttribute as String, NSNumber(value: 0.1))
                                builder.setChildren(replacement, [])
                                builder.setChildren(window, [rail, mixer, builder.element(1_965_720), replacement])
                            }
                            if fault == "scroll_newer" {
                                builder.setAttribute(scroll, attribute, NSNumber(value: 0.6))
                                return .some(NSNumber(value: 0.6))
                            }
                        }
                    }
                    if fault == "post_restore_selection_missing" || fault == "post_restore_selection_malformed",
                       selections == [1, 0], CFEqual(element, headers[1]) {
                        if attribute == kAXTitleAttribute as String { loseNextSelectionRead = true }
                        if attribute == kAXSelectedAttribute as String, loseNextSelectionRead {
                            loseNextSelectionRead = false
                            postRestoreSelectionFaults += 1
                            return fault == "post_restore_selection_missing" ? .some(nil) : .some(NSNumber(value: 2))
                        }
                    }
                    if CFEqual(element, app), attribute == kAXFocusedUIElementAttribute as String,
                       selections.count < 2 {
                        focusReadsBeforeWrite[selections.count] += 1
                        if scopeLossPhase == selections.count, scopeLossRead == focusReadsBeforeWrite[selections.count] {
                            scopeLossInjected = true
                            if fault == "final_focus_document" {
                                builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            } else if fault == "final_focus_window" {
                                let foreign = builder.element(1_965_740)
                                builder.setAttribute(app, kAXMainWindowAttribute as String, foreign)
                                builder.setAttribute(app, kAXFocusedWindowAttribute as String, foreign)
                            }
                            // Still return the expected held focus. Its deciding
                            // read changed scope after the prior scope validation.
                        }
                    }
                    if fault == "transient_foreign_focus", selections.count == 1,
                       CFEqual(element, app), attribute == kAXFocusedUIElementAttribute as String, !transientForeignRead {
                        transientForeignRead = true
                        return .some(builder.element(1_965_730))
                    }
                    return nil
                }, attributeValueResultHandler: { [self] element, attribute in
                    if routingReplacement != nil, CFEqual(element, strips[1]) {
                        return .failure(.init(raw: AXError.invalidUIElement.rawValue))
                    }
                    if let volatileSlider, CFEqual(element, volatileSlider), !selections.isEmpty,
                       attribute == kAXDescriptionAttribute as String {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    let isReplacement = routingReplacement.map { CFEqual($0, element) } ?? false
                    if strips.contains(where: { CFEqual($0, element) }) || isReplacement,
                       attribute == kAXValueAttribute as String || attribute == kAXSelectedTextAttribute as String {
                        if fault == "transient_editor", selections.count == 1,
                           CFEqual(element, strips[0]), attribute == kAXValueAttribute as String, !transientEditorRead {
                            transientEditorRead = true
                            return .success("Editing" as NSString)
                        }
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    return nil
                },
                setAttributeHandler: { [self] element, attribute, value in
                    if CFEqual(element, scroll), attribute == kAXValueAttribute as String,
                       let number = value as? NSNumber {
                        scrollWrites.append(number.doubleValue)
                        inverseValueReadCount = viewportReadsAfterSelection
                        if fault == "scroll_no_effect" { return true }
                        builder.setAttribute(scroll, attribute, number)
                        return true
                    }
                    guard CFEqual(element, rail), attribute == kAXSelectedChildrenAttribute as String,
                          let chosen = value as? [AXUIElement], chosen.count == 1,
                          let index = headers.firstIndex(where: { CFEqual($0, chosen[0]) }) else {
                        Issue.record("only exact held rail selection is authorized"); return false
                    }
                    selections.append(index)
                    routingSelection?(index)
                    if fault == "no_op" { return true }
                    for (row, header) in headers.enumerated() {
                        builder.setAttribute(header, kAXSelectedAttribute as String, row == index)
                    }
                    // The actual physical relationship is deliberately not positional.
                    builder.setAttribute(app, kAXFocusedUIElementAttribute as String,
                        index == 0 ? routingReplacement ?? strips[1] : strips[0])
                    if fault == "selection_scroll" || fault?.hasPrefix("scroll_") == true {
                        // Native R11: restoring the selected header/focused strip did
                        // not restore the Tracks scrollbar's original value.
                        builder.setAttribute(scroll, kAXValueAttribute as String, NSNumber(value: 0.1))
                    }
                    if selections.count == 1 {
                        if fault == "foreign_focus" { builder.setAttribute(app, kAXFocusedUIElementAttribute as String, builder.element(1_965_730)) }
                        if fault == "unchanged_focus" { builder.setAttribute(app, kAXFocusedUIElementAttribute as String, strips[1]) }
                        if fault == "document" { builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                        if fault == "header_replacement" {
                            let replacement = builder.element(1_965_731)
                            builder.setRole(replacement, kAXLayoutItemRole as String)
                            builder.setAttribute(replacement, kAXTitleAttribute as String, "Duplicate")
                            builder.setAttribute(replacement, kAXSelectedAttribute as String, true)
                            builder.setChildren(replacement, [])
                            builder.setChildren(rail, [headers[0], replacement])
                        }
                        if fault == "strip_replacement" {
                            let replacement = builder.element(1_965_732)
                            builder.setRole(replacement, kAXLayoutItemRole as String)
                            builder.setChildren(replacement, [])
                            builder.setChildren(mixer, [replacement, strips[1]])
                        }
                        if fault == "playback" { builder.setAttribute(builder.element(1_965_721), kAXValueAttribute as String, 1) }
                        if fault == "header_name" { builder.setAttribute(headers[index], kAXTitleAttribute as String, "Changed during selection") }
                        if fault == "strip_name", let name = builder.makeAXRuntime().children(strips[1 - index]).first {
                            builder.setAttribute(name, kAXValueAttribute as String, "Changed during selection")
                        }
                    }
                    if selections.count == 2, fault == "restore_foreign_focus" {
                        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, builder.element(1_965_730))
                    }
                    return true
                }, performActionHandler: { [self] element, action in
                    if let routingAction { return routingAction(element, action) }
                    Issue.record("no action fallback"); return false
                },
                executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") })
            let ax: AXHelpers.Runtime
            if useBulkReads {
                ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
                    attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
                    children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
                    actionNames: base.ax.actionNames, actionNamesResult: base.ax.actionNamesResult,
                    childrenResult: base.ax.childrenResult, attributeValueResult: base.ax.attributeValueResult,
                    performActionResult: base.ax.performActionResult, elementAtPosition: base.ax.elementAtPosition,
                    attributeValuesResult: { [self] element, attributes in
                        batchReadCalls += 1
                        let scopeBatch = CFEqual(element, window)
                            && attributes == [kAXTitleAttribute as String, kAXDocumentAttribute as String]
                        if scopeBatch {
                            windowScopeBatchCalls += 1
                            switch windowScopeBatchFault {
                            case "failure": return .failure(.init(raw: AXError.cannotComplete.rawValue))
                            case "short": return .success(["Selection fixture - Tracks" as NSString])
                            case "title_type": return .success([NSNumber(value: 0), bundle.absoluteString as NSString])
                            case "document_type": return .success(["Selection fixture - Tracks" as NSString, NSNumber(value: 0)])
                            case "foreign_title": return .success(["Foreign - Tracks" as NSString, bundle.absoluteString as NSString])
                            case "foreign_document": return .success(["Selection fixture - Tracks" as NSString, "file:///tmp/Foreign.logicx" as NSString])
                            default: break
                            }
                        }
                        if attributes == [kAXChildrenAttribute as String, kAXParentAttribute as String] {
                            reciprocalPathBatchCalls += 1
                            if CFEqual(element, builder.element(1_965_720)), let pathBatchFault {
                                if pathBatchFault == "unreadable" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                                if pathBatchFault == "malformed_children" { return .success(["not children" as NSString, window]) }
                                if pathBatchFault == "foreign_children" { return .success([[] as CFArray, window]) }
                                if pathBatchFault == "malformed_parent" { return .success([[builder.element(1_965_721), builder.element(1_965_722)] as CFArray, "not parent" as NSString]) }
                            }
                        }
                        var values: [AnyObject] = []
                        for attribute in attributes {
                            let reading: Result<AnyObject?, AXHelpers.AXStatusError>
                            if attribute == kAXChildrenAttribute as String {
                                reading = AXHelpers.childrenResult(element, runtime: base.ax).map { $0 as CFArray }
                            } else {
                                reading = AXHelpers.getAttributeResult(element, attribute, runtime: base.ax)
                            }
                            switch reading {
                            case .success(let value): values.append(value ?? NSNull())
                            case .failure(let error):
                                var nativeError = AXError(rawValue: error.raw) ?? .cannotComplete
                                guard let wrapped = AXValueCreate(.axError, &nativeError) else { return .failure(error) }
                                values.append(wrapped)
                            }
                        }
                        if scopeBatch, windowScopeBatchFault == "document_after_batch" {
                            builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                        return .success(values)
                    })
            } else { ax = base.ax }
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
                executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") },
                onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("no Escape") },
                focusedApplicationPID: { 4242 })
            return AccessibilityChannel(runtime: .axBacked(isTrusted: { true },
                isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: logic))
        }
    }

    private func inspect(_ f: Fixture, navigation: Bool = true, cache: StateCache = StateCache(),
                         fileReader: LogicProjectFileReader.Runtime = .unavailable,
                         registry: TargetRegistry = TargetRegistry(), projectRef: String? = nil) async throws -> [String: Any] {
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: registry,
            poller: StatePoller(axChannel: f.channel(), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: fileReader,
                               keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: fileReader)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        var arguments: [String: Value] = ["domains": .array([.string("associations")]), "allow_ui_navigation": .bool(navigation)]
        if let projectRef { arguments["project_ref"] = .string(projectRef) }
        let params = arguments
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test func retainedMixerPairUsesActualCaptureAndExactPhysicalReferenceOnly() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture()
            let cache = StateCache()
            let registry = TargetRegistry()
            let body = try await inspect(f, cache: cache, registry: registry)
            let id = try #require(body["snapshot_id"] as? String)
            let retained = try #require(await cache.retainedInspection(id: id))
            let pair = try #require(retained.capture.freshPopulation?.selectionAssociations.first)
            let row = try #require(retained.capture.channelStrips.indices.first {
                retained.capture.channelStrips[$0].physicalBinding?.matches(pair.strip) == true
            })
            let ref = try #require(retained.capture.mixerReference(at: row))
            let source = try #require(await registry.resolve(ref)?.physicalMixerStrip)
            let found = try #require(await cache.retainedMixerAssociation(
                reference: ref, source: source, snapshot: await registry.currentSnapshot))
            #expect(found.track.matches(pair.track) && found.strip.matches(source))
            #expect(await cache.retainedMixerAssociation(reference: .init(rawValue: "mix_unissued"),
                source: source, snapshot: await registry.currentSnapshot) == nil)
            let other = AXMixerStripBinding.Binding(window: source.window, mixer: source.mixer,
                strip: f.builder.element(1_965_999), document: source.document)
            #expect(await cache.retainedMixerAssociation(reference: ref, source: other,
                snapshot: await registry.currentSnapshot) == nil)
            await registry.bumpTopologyGeneration()
            #expect(await cache.retainedMixerAssociation(reference: ref, source: source,
                snapshot: await registry.currentSnapshot) == nil)
        }
    }

    @Test(arguments: ["paired", "missing_pair", "replaced_header", "foreign_project", "foreign_focus", "deciding_read", "partial_restore", "track_ref", "track_ref_missing_pair", "track_ref_replaced_strip"])
    func outputReadbackRenewsRetiredSourceOnlyThroughOriginalCapturedHeader(condition: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture()
            if condition.hasPrefix("track_ref") {
                f.builder.setAttribute(f.headers[0], kAXTitleAttribute as String, "Original")
                f.builder.setAttribute(f.headers[1], kAXTitleAttribute as String, "Other")
            }
            let captureNow = ContinuousClock.now
            let cache = StateCache(sessionCaptureNow: {
                f.expireRetainedCapture ? captureNow.advanced(by: StateCache.sessionCaptureLifetime) : captureNow
            }), registry = TargetRegistry()
            let output = f.builder.element(1_965_950), replacement = f.builder.element(1_965_951)
            let newOutput = f.builder.element(1_965_952), root = f.builder.element(1_965_953)
            let parent = f.builder.element(1_965_954), submenu = f.builder.element(1_965_955)
            let leaf = f.builder.element(1_965_956)
            let decoyOutput = f.builder.element(1_965_959)
            for (button, label) in [(output, "Stereo Output"), (newOutput, "Output 3-4"), (decoyOutput, "Stereo Output")] {
                f.builder.setButton(button, description: label, help: "Output slot. Choose the channel strip output.",
                    x: 0, y: 0, width: 1, height: 1)
                f.builder.setChildren(button, [])
            }
            f.builder.setChildren(f.strips[1], f.builder.makeAXRuntime().children(f.strips[1]) + [output])
            f.builder.setChildren(f.strips[0], f.builder.makeAXRuntime().children(f.strips[0]) + [decoyOutput])
            f.builder.setRole(replacement, kAXLayoutItemRole as String)
            f.builder.setAttribute(replacement, kAXNumberOfCharactersAttribute as String, 0)
            f.builder.setAttribute(replacement, kAXInsertionPointLineNumberAttribute as String, 0)
            f.builder.setChildren(replacement, [newOutput])
            for menu in [root, submenu] { f.builder.setRole(menu, kAXMenuRole as String) }
            for (item, title) in [(parent, "Output"), (leaf, "Output 3-4")] {
                f.builder.setRole(item, kAXMenuItemRole as String)
                f.builder.setAttribute(item, kAXTitleAttribute as String, title)
                f.builder.setAttribute(item, kAXEnabledAttribute as String, true)
            }
            f.builder.setChildren(leaf, []); f.builder.setChildren(submenu, [leaf])
            f.builder.setChildren(parent, [submenu]); f.builder.setChildren(root, [parent])
            if condition == "deciding_read" {
                f.routingRead = { element, attribute in
                    if f.selections.count == 4, CFEqual(element, newOutput), attribute == kAXDescriptionAttribute as String {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                }
            } else if condition == "partial_restore" {
                f.routingSelection = { _ in
                    if f.selections.count == 3 {
                        f.routingLateScopeInjected = true
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                }
            }
            f.routingAction = { element, action in
                guard action == kAXPressAction as String else { Issue.record("unexpected routing action"); return false }
                if CFEqual(element, output) { f.builder.setChildren(f.mixer, f.strips + [root]); return true }
                if CFEqual(element, decoyOutput) {
                    f.routingWrongSourcePressed = true
                    f.builder.setChildren(f.mixer, f.strips + [root]); return true
                }
                if CFEqual(element, leaf) {
                    f.routingDestinationPresses += 1
                    if f.routingWrongSourcePressed {
                        f.builder.setAttribute(decoyOutput, kAXDescriptionAttribute as String, "Output 3-4")
                        f.builder.setChildren(f.mixer, f.strips)
                        return true
                    }
                    f.routingReplacement = replacement
                    f.builder.setChildren(f.mixer, [f.strips[0], replacement])
                    f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, replacement)
                    if condition == "replaced_header" {
                        let foreign = f.builder.element(1_965_957)
                        f.builder.setRole(foreign, kAXLayoutItemRole as String)
                        f.builder.setAttribute(foreign, kAXTitleAttribute as String, "Duplicate")
                        f.builder.setAttribute(foreign, kAXSelectedAttribute as String, true)
                        f.builder.setChildren(foreign, [])
                        f.builder.setChildren(f.rail, [foreign, f.headers[1]])
                    } else if condition == "foreign_project" {
                        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    } else if condition == "foreign_focus" {
                        let foreign = f.builder.element(1_965_958)
                        f.builder.setRole(foreign, kAXTextFieldRole as String)
                        f.builder.setAttributeSettable(foreign, kAXValueAttribute as String, true)
                        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, foreign)
                    }
                    return true
                }
                Issue.record("unowned routing action"); return false
            }
            let before = try await inspect(f, cache: cache, registry: registry)
            let id = try #require(before["snapshot_id"] as? String)
            let capture = try #require(await cache.retainedInspection(id: id)).capture
            let sourceRow = try #require(capture.channelStrips.indices.first {
                capture.channelStrips[$0].physicalBinding.map { CFEqual($0.strip, f.strips[1]) } == true
            })
            var target = try #require(capture.mixerReference(at: sourceRow))
            if condition.hasPrefix("track_ref") {
                let tracks = TrackReferenceIssuance.liveInventory(capture.tracks)
                let trackRow = try #require(tracks.indices.first {
                    tracks[$0].physicalBinding.map { CFEqual($0.header, f.headers[0]) } == true
                })
                target = try #require(capture.issued?.byRow[trackRow])
            }
            let project: String
            if case .issued(let issued)? = capture.projectIssuance { project = issued.rawValue }
            else { Issue.record("the actual capture must issue a project reference"); return }
            if condition == "missing_pair" || condition == "track_ref_missing_pair" { f.expireRetainedCapture = true }
            if condition == "track_ref_replaced_strip" {
                f.builder.setChildren(f.mixer, [f.strips[0], replacement])
                f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, replacement)
            }
            let router = ChannelRouter(); await router.register(f.channel())
            let gate = LogicMutationGate()
            let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: f.channel(), cache: cache,
                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                        keyboardFocus: { .notTextEditing })),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { condition.hasPrefix("track_ref") ? [0: "Original", 1: "Other"] : [0: "Duplicate", 1: "Duplicate"] })
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_output_verified"))
            let params: [String: Value] = ["project_ref": .string(project), "target_ref": .string(target.rawValue),
                "destination": .object(["kind": .string("physical"), "ports": .array([.int(3), .int(4)])]),
                "expected_current": .object(["kind": .string("stereo_output")])]
            let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_output_verified",
                commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(!f.routingWrongSourcePressed, "An Arrange ordinal must never choose an unrelated physical Mixer strip")
            if condition == "track_ref_missing_pair" || condition == "track_ref_replaced_strip" {
                #expect(body["state"] as? String == "C")
                let wrote = try #require(body["write_attempted"] as? Bool)
                #expect(!wrote && f.routingDestinationPresses == 0)
                #expect(f.selections == [1, 0])
                return
            }
            let succeeds = condition == "paired" || condition == "track_ref"
            #expect(body["state"] as? String == (succeeds ? "A" : "B"), "Actual response: \(sharedToolText(result))")
            let verified = try #require(body["verified"] as? Bool)
            if succeeds {
                #expect(verified)
                let reread = try #require(body["reference_reread_required"] as? Bool)
                #expect(reread)
            } else { #expect(!verified) }
            #expect(f.routingReplacement != nil)
            let expectedSelections = condition == "partial_restore" ? [1, 0, 1]
                : ((succeeds || condition == "deciding_read") ? [1, 0, 1, 0] : [1, 0])
            #expect(f.selections == expectedSelections)
            if condition == "deciding_read" || condition == "partial_restore" { #expect(f.routingLateScopeInjected) }
            if condition == "partial_restore" {
                let effects = try #require(body["ui_effects"] as? [String: Any])
                #expect(effects["restoration"] as? String == "not_restored")
                let attempted = try #require(effects["attempted"] as? [String])
                #expect(attempted.contains("track_selection"))
            }
            #expect(f.routingDestinationPresses == 1)
            let refused = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_output_verified",
                commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
            let refusal = try #require(sharedJSONObject(sharedToolText(refused)))
            #expect(refusal["state"] as? String == "C")
            let wrote = try #require(refusal["write_attempted"] as? Bool)
            #expect(!wrote && f.routingDestinationPresses == 1)
        }
    }

    @Test(arguments: [false, true])
    func heldWindowScopeUsesFreshTitleDocumentBatchOnlyOnCapableRuntimes(bulk: Bool) async throws {
        let f = try Fixture()
        f.useBulkReads = bulk
        let body = try await inspect(f)
        let rows = try #require((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 2 && f.selections == [1, 0])
        #expect(bulk ? f.windowScopeBatchCalls > 0 : f.windowScopeBatchCalls == 0)
    }

    @Test(arguments: ["failure", "short", "title_type", "document_type",
                      "foreign_title", "foreign_document", "document_after_batch"])
    func failedFreshWindowScopeBatchOrLaterDocumentChangeCannotAuthorizeSelection(fault: String) async throws {
        let f = try Fixture()
        f.useBulkReads = true
        f.windowScopeBatchFault = fault
        let body = try await inspect(f)
        #expect(f.windowScopeBatchCalls > 0)
        #expect(f.selections.isEmpty)
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
        #expect((rows?.count ?? 0) == 0)
    }

    @Test func explicitNavigationPublishesPhysicalPairsWithoutNameOrOrdinalJoin() async throws {
        let f = try Fixture()
        let body = try await inspect(f)
        let section = try #require(body["associations"] as? [String: Any])
        let rows = try #require(section["rows"] as? [[String: Any]])
        let tracks = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
        let strips = try #require((body["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.count == 2)
        for row in rows {
            let trackIndex = try #require(row["track_index"] as? Int)
            #expect(row["track_ref"] as? String == tracks[trackIndex]["track_ref"] as? String)
            #expect(row["mixer_strip_ref"] as? String == strips[1 - trackIndex]["mixer_strip_ref"] as? String)
            #expect(row["source"] as? String == "held_exclusive_selection_focus")
        }
        #expect(section["coverage"] as? String == "partial", "visible pairs are not whole-population proof")
        #expect(f.selections == [1, 0])
        let selected = try #require(f.builder.attributeValue(f.headers[0], kAXSelectedAttribute as String) as? Bool)
        #expect(selected)
        let focus: AXUIElement = try #require(AXHelpers.getAttribute(f.app, kAXFocusedUIElementAttribute as String,
            runtime: f.builder.makeAXRuntime()))
        #expect(CFEqual(focus, f.strips[1]))
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test(arguments: [false, true])
    func selectionInducedViewportDriftRestoresOnlyItsOriginalControl(bulk: Bool) async throws {
        let f = try Fixture(withViewport: true)
        f.useBulkReads = bulk
        f.fault = "selection_scroll"
        let body = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites == [0.8], "restore the exact held scrollbar, not a new matching control")
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.8)
        #expect((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] != nil)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        #expect(bulk ? f.batchReadCalls > 0 : f.batchReadCalls == 0)
        #expect(bulk ? f.reciprocalPathBatchCalls > 0 : f.reciprocalPathBatchCalls == 0)
    }

    @Test(arguments: ["Vertical Zoom", "수직 확대/축소"], [false, true])
    func selectionInducedZoomDriftCannotClaimRestoration(label: String, noEffect: Bool) async throws {
        let f = try Fixture(withViewport: true)
        f.useBulkReads = true
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, label)
        f.fault = noEffect ? "scroll_no_effect" : "selection_scroll"
        let body = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites == [0.8], "selection-owned zoom drift requires the original physical control's inverse")
        let restoration = try #require((body["ui_effects"] as? [String: Any])?["restoration"] as? String)
        if noEffect {
            #expect(restoration != "restored", "a successful AX write without exact zoom readback is not restoration")
            #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.1)
        } else {
            #expect(restoration == "restored")
            #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.8)
        }
    }

    @Test(arguments: ["Volume", "Pan", "Zoom", "Vertical Zoom calibration"])
    func viewportInverseCannotUseAnUnrelatedSliderDescription(label: String) async throws {
        let f = try Fixture(withViewport: true)
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, label)
        f.fault = "selection_scroll"
        _ = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites.isEmpty, "neither generic zoom containment nor a musical slider authorizes a viewport write")
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.1)
    }

    @Test func malformedZoomDescriptionCannotBeTreatedAsAbsent() async throws {
        let f = try Fixture(withViewport: true)
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, NSNumber(value: 42))
        f.fault = "selection_scroll"
        _ = try await inspect(f)
        #expect(f.selections.isEmpty, "a malformed successful description is not proof that an owned viewport control is absent")
        #expect(f.scrollWrites.isEmpty)
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.8)
    }

    @Test func anUnrelatedInspectorSliderCannotPreventOriginalZoomRestoration() async throws {
        let f = try Fixture(withViewport: true)
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, "Vertical Zoom")
        let unrelated = f.builder.element(1_965_780)
        f.builder.setRole(unrelated, kAXSliderRole as String)
        f.builder.setAttribute(unrelated, kAXDescriptionAttribute as String, "Gain")
        f.builder.setChildren(unrelated, [])
        f.builder.setChildren(f.window, [f.rail, f.mixer, f.builder.element(1_965_720), f.scroll, unrelated])
        f.volatileSlider = unrelated
        f.fault = "selection_scroll"
        let body = try await inspect(f)
        #expect(f.selections == [1, 0], "do not abandon the owned selection because a non-viewport Inspector slider was redrawn")
        #expect(f.scrollWrites == [0.8])
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.8)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test func aSampledOriginalZoomRoleContradictionCannotBeRenewedAway() async throws {
        let calibration = try Fixture(withViewport: true)
        calibration.builder.setRole(calibration.scroll, kAXSliderRole as String)
        calibration.builder.setAttribute(calibration.scroll, kAXDescriptionAttribute as String, "Vertical Zoom")
        calibration.fault = "selection_scroll"
        _ = try await inspect(calibration)
        let firstValueRoleReads = try #require(calibration.zoomRoleReadsAtFirstValue)
        #expect(firstValueRoleReads >= 2)
        let f = try Fixture(withViewport: true)
        f.builder.setRole(f.scroll, kAXSliderRole as String)
        f.builder.setAttribute(f.scroll, kAXDescriptionAttribute as String, "Vertical Zoom")
        f.fault = "selection_scroll"
        // The last role read before this viewport value is the direct held
        // role check; the preceding read is its fresh complete census sample.
        f.zoomRoleFaultAtRead = firstValueRoleReads - 1
        let body = try await inspect(f)
        #expect(f.transientZoomRoleObserved)
        #expect(f.selections == [1])
        #expect(f.scrollWrites.isEmpty)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test(arguments: ["unreadable", "malformed_children", "foreign_children", "malformed_parent"])
    func aFailedFreshReciprocalPathBatchCannotAuthorizeSelection(fault: String) async throws {
        let f = try Fixture()
        f.useBulkReads = true
        f.pathBatchFault = fault
        let body = try await inspect(f)
        #expect(f.reciprocalPathBatchCalls > 0, "exercise the original intermediate transport parent")
        #expect(f.selections.isEmpty, "do not reconstruct a failed physical reciprocal path")
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
        #expect((rows ?? []).isEmpty, "no physical pairs without the original reciprocal path")
    }

    @Test(arguments: ["scroll_document", "scroll_focus", "scroll_replacement", "scroll_newer", "scroll_playback", "scroll_cancel"], [false, true])
    func decidingViewportLossCannotAuthorizeItsInverse(fault: String, bulk: Bool) async throws {
        let calibration = try Fixture(withViewport: true)
        calibration.useBulkReads = bulk
        calibration.fault = "selection_scroll"
        _ = try await inspect(calibration)
        #expect(calibration.scrollWrites == [0.8])
        let f = try Fixture(withViewport: true)
        f.useBulkReads = bulk
        f.fault = fault
        f.viewportFaultAtRead = calibration.inverseValueReadCount
        let body = try await inspect(f)
        #expect(f.viewportFaultInjected, "exercise the actual last deciding viewport-value read")
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites.isEmpty, "do not overwrite a newer view or act through lost control/document/focus custody")
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test func scrollbarAckWithoutReadbackDoesNotClaimRestoration() async throws {
        let f = try Fixture(withViewport: true)
        f.fault = "scroll_no_effect"
        let body = try await inspect(f)
        #expect(f.scrollWrites == [0.8])
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.1)
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test func unwriteableOriginalScrollbarCannotAuthorizeAnInverse() async throws {
        let f = try Fixture(withViewport: true)
        f.fault = "selection_scroll"
        f.builder.setAttributeSettable(f.scroll, kAXValueAttribute as String, false)
        let body = try await inspect(f)
        #expect(f.selections == [1, 0])
        #expect(f.scrollWrites.isEmpty)
        #expect((f.builder.attributeValue(f.scroll, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.1)
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
    }

    @Test func decidingViewportReferenceRetirementCannotAuthorizeAnInverse() async throws {
        func observe(_ f: Fixture) async throws -> SessionPopulationObservation.FreshPopulation {
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            return try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(
                    request: .init(domains: [.tracks, .strips, .associations], allowUINavigation: true),
                    fileReader: .unavailable,
                    navigationReferenceIsCurrent: { f.referenceCurrent }, stoppingWhen: { false })
            }
        }
        let calibration = try Fixture(withViewport: true)
        calibration.fault = "selection_scroll"
        let positive = try await observe(calibration)
        #expect(calibration.scrollWrites == [0.8])
        #expect(positive.selectionAssociations.count == 2)
        let f = try Fixture(withViewport: true)
        f.fault = "scroll_reference"
        f.viewportFaultAtRead = calibration.inverseValueReadCount
        let refused = try await observe(f)
        #expect(f.viewportFaultInjected && !f.referenceCurrent)
        #expect(f.selections == [1, 0], "all physical custody remains unchanged at reference retirement")
        #expect(f.scrollWrites.isEmpty, "renew the request's current-reference authority after deciding AX reads")
        #expect(refused.selectionAssociations.isEmpty)
        #expect(refused.uiEffects.restoration == "not_restored")
    }

    @Test(arguments: ["post_restore_selection_missing", "post_restore_selection_malformed"])
    func restoredPopulationCannotLoseOriginalSelectionReadback(fault: String) async throws {
        let f = try Fixture()
        f.fault = fault
        let body = try await inspect(f)
        #expect(f.selections == [1, 0], "the physical challenge and restoration must actually run")
        #expect(f.postRestoreSelectionFaults == 4, "all four post-restoration title-associated selection samples must consume the fault")
        #expect(body["associations"] == nil, "do not retain pairs after initial-vs-restored selection provenance changes")
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "stale_snapshot")
        #expect((body["ui_effects"] as? [String: Any])?["reason"] as? String == "association_population_moved")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test(arguments: ["header_name", "strip_name"])
    func decidingSelectionCannotPublishEarlierPresentation(fault: String) async throws {
        let f = try Fixture()
        f.fault = fault
        let body = try await inspect(f)
        #expect(f.selections == [1, 0], "the physical selection and restoration must actually run")
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "stale_snapshot")
        let navigationPerformed = try #require(body["navigation_performed"] as? Bool)
        #expect(navigationPerformed)
        #expect((body["ui_effects"] as? [String: Any])?["reason"] as? String == "association_population_moved")
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    @Test func aCurrentReferenceForAnotherLiveDocumentDoesNotSelect() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Fixture(), registry = TargetRegistry()
            let snapshot = await registry.currentSnapshot
            let descriptor = TargetDescriptor.project(name: "Other", filePath: "/tmp/Other.logicx", epoch: snapshot.projectEpoch)
            let reference = try #require(await registry.bind(kind: .project, descriptor: descriptor,
                fingerprint: descriptor.fingerprint, snapshot: snapshot))
            let body = try await inspect(f, registry: registry, projectRef: reference.rawValue)
            #expect(f.selections.isEmpty, "a registry-current reference must also match the actual held native document before UI writes")
            #expect(body["state"] as? String == "C")
            #expect(body["associations"] == nil)
        }
    }

    @Test(arguments: ["final_focus_document", "final_focus_window"], [0, 1])
    func finalDecidingFocusCannotMoveScopeBeforeForwardOrCleanupWrite(fault: String, phase: Int) async throws {
        let calibration = try Fixture()
        let positive = try await inspect(calibration)
        #expect((positive["associations"] as? [String: Any])?["rows"] != nil)
        let f = try Fixture()
        f.fault = fault
        f.scopeLossPhase = phase
        f.scopeLossRead = calibration.focusReadsBeforeWrite[phase]
        let body = try await inspect(f)
        #expect(f.scopeLossInjected, "exercise the actual final deciding focus read, not an earlier proxy")
        #expect(f.selections == (phase == 0 ? [] : [1]), "R965-ASSOC-C001: no write after the final focus read moved document/window scope")
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
    }

    @Test func navigationOptOutCannotSelectOrInventPairs() async throws {
        let f = try Fixture()
        let body = try await inspect(f, navigation: false)
        let section = try #require(body["associations"] as? [String: Any])
        #expect(section["rows"] == nil)
        #expect(section["coverage"] as? String == "unavailable")
        #expect(f.selections.isEmpty)
    }

    @Test(arguments: [-1.0, 2.0, 0.9, Double.nan, Double.infinity, -Double.infinity])
    func malformedSelectedValueCannotAuthorizeAssociationNavigation(value: Double) async throws {
        let f = try Fixture()
        f.builder.setAttribute(f.headers[0], kAXSelectedAttribute as String, NSNumber(value: value))
        let body = try await inspect(f)
        #expect(f.selections.isEmpty, "an unread selection cannot authorize a forward or restoration write")
        let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
        #expect(rows == nil, "non-Boolean numeric selection is not physical association evidence")
    }

    @Test(arguments: ["foreign_focus", "transient_foreign_focus", "unchanged_focus", "document", "header_replacement", "strip_replacement", "playback", "transient_editor"], [false, true])
    func observedCustodyLossCannotAuthorizeAnotherSelection(fault: String, bulk: Bool) async throws {
        let f = try Fixture()
        f.useBulkReads = bulk
        f.fault = fault
        let body = try await inspect(f)
        #expect(f.selections == [1], "never rebind a replacement or overwrite a sampled foreign/editor state")
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
        if fault == "transient_foreign_focus" { #expect(f.transientForeignRead, "the actual optional focus-read seam must be exercised") }
        if fault == "foreign_focus" || fault == "unchanged_focus" {
            #expect((body["ui_effects"] as? [String: Any])?["changed"] as? [String] == ["track_selection"],
                    "a deciding read observed actual selection even though its focus could not qualify a pair")
        }
    }

    @Test(arguments: ["no_op", "restore_foreign_focus"])
    func anAckWithoutACompleteRoundtripCannotPublishPairs(fault: String) async throws {
        let f = try Fixture()
        f.fault = fault
        let body = try await inspect(f)
        #expect(f.selections == (fault == "no_op" ? [1] : [1, 0]))
        #expect(body["associations"] == nil)
        #expect(body["state"] as? String == "C")
    }

    @Test(arguments: ["before_final_read", "during_final_read", "project_epoch", "occlusion"])
    func restoredSelectionStartsAFreshReadWithoutIgnoringItsBoundary(fault: String) async throws {
        let f = try Fixture(), cache = StateCache()
        let metadata = try PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": 2], format: .xml, options: 0)
        let fileReader = LogicProjectFileReader.Runtime(currentDocumentPath: { nil }, now: Date.init,
            readPlistData: { _ in metadata }, mtime: { _ in
                f.metadataReads += 1
                return Date(timeIntervalSince1970: Double(f.metadataReads % 2))
            }, sleep: { _ in
                // An actual awaited metadata retry deterministically delivers the
                // cache echo. No timed Task, sleep or synthetic boundary callback.
                if fault == "before_final_read", f.selections.isEmpty {
                    await cache.updateFader(strip: 0, volume: 0.5)
                } else if fault == "during_final_read", f.selections.count == 2 {
                    await cache.updateFader(strip: 0, volume: 0.5)
                } else if fault == "project_epoch", f.selections.isEmpty {
                    await cache.advanceProjectEpoch()
                } else if fault == "occlusion", f.selections.isEmpty {
                    await cache.updateAXOccluded(true); await cache.updateAXOccluded(false)
                }
            })
        let body = try await inspect(f, cache: cache, fileReader: fileReader)
        #expect(f.selections == [1, 0])
        if fault == "before_final_read" {
            let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]
            #expect(rows?.count == 2, "accept only a new full post-restoration read, never the earlier cache boundary")
            #expect(await cache.sectionRevision(.mixer) > 0, "the cache echo must actually occur")
        } else {
            #expect(body["associations"] == nil)
            #expect(body["state"] as? String == "C", "new read revision, project epoch and occlusion losses remain blocking")
        }
    }
}
