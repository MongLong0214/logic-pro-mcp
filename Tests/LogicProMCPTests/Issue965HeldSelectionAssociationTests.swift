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
        let bundle: URL
        var selections: [Int] = []
        var fault: String?
        var transientEditorRead = false
        var transientForeignRead = false
        var metadataReads = 0
        var focusReadsBeforeWrite = [0, 0]
        var scopeLossPhase: Int?
        var scopeLossRead: Int?
        var scopeLossInjected = false

        init() throws {
            bundle = FileManager.default.temporaryDirectory.appendingPathComponent("965-selection-\(UUID().uuidString).logicx")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            app = builder.element(1_965_700)
            window = builder.element(1_965_701)
            rail = builder.element(1_965_702)
            mixer = builder.element(1_965_703)
            headers = [builder.element(1_965_704), builder.element(1_965_705)]
            strips = [builder.element(1_965_706), builder.element(1_965_707)]
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
            builder.setChildren(window, [rail, mixer, bar])
        }

        deinit { try? FileManager.default.removeItem(at: bundle) }

        func channel() -> AccessibilityChannel {
            let base = builder.makeLogicRuntime(appElement: app,
                attributeValueHandler: { [self] element, attribute in
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
                    if strips.contains(where: { CFEqual($0, element) }),
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
                    guard CFEqual(element, rail), attribute == kAXSelectedChildrenAttribute as String,
                          let chosen = value as? [AXUIElement], chosen.count == 1,
                          let index = headers.firstIndex(where: { CFEqual($0, chosen[0]) }) else {
                        Issue.record("only exact held rail selection is authorized"); return false
                    }
                    selections.append(index)
                    if fault == "no_op" { return true }
                    for (row, header) in headers.enumerated() {
                        builder.setAttribute(header, kAXSelectedAttribute as String, row == index)
                    }
                    // The actual physical relationship is deliberately not positional.
                    builder.setAttribute(app, kAXFocusedUIElementAttribute as String, strips[1 - index])
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
                }, performActionHandler: { _, _ in Issue.record("no action fallback"); return false },
                executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") })
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: base.ax,
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

    @Test(arguments: ["foreign_focus", "transient_foreign_focus", "unchanged_focus", "document", "header_replacement", "strip_replacement", "playback", "transient_editor"])
    func observedCustodyLossCannotAuthorizeAnotherSelection(fault: String) async throws {
        let f = try Fixture()
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
