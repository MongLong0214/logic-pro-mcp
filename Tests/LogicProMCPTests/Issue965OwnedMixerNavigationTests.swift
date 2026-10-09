@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#965 owned Mixer observation navigation", .serialized)
struct Issue965OwnedMixerNavigationTests {
    private final class Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let menuBar: AXUIElement
        let view: AXUIElement
        let toggle: AXUIElement
        let mixer: AXUIElement
        let strip: AXUIElement
        var pressed: [String] = []
        var showing = false
        var extraWindowChildren: [AXUIElement] = []
        var afterShow: (@Sendable () -> Void)?
        var afterHide: (@Sendable () -> Void)?
        var afterOpen: (@Sendable () -> Void)?
        var hideFails = false
        var enabledReadable = true
        var openReturnsFalse = false
        var cancelLeavesMenuOpen = false
        var showFails = false
        var unreadLabelElement: AXUIElement?

        init() {
            app = builder.element(965_950)
            window = builder.element(965_951)
            rail = builder.element(965_952)
            menuBar = builder.element(965_953)
            view = builder.element(965_954)
            toggle = builder.element(965_955)
            mixer = builder.element(965_956)
            strip = builder.element(965_957)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Navigation fixture - Tracks")
            builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/NavigationFixture.logicx")
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setAttribute(app, kAXFocusedWindowAttribute as String, window)
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, rail)
            builder.setAttribute(app, kAXFrontmostAttribute as String, true)
            builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
            builder.setRole(rail, kAXListRole as String)
            builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            builder.setChildren(rail, [])
            builder.setChildren(window, [rail])
            builder.setRole(menuBar, kAXMenuBarRole as String)
            builder.setRole(view, kAXMenuBarItemRole as String)
            builder.setAttribute(view, kAXTitleAttribute as String, "View")
            builder.setAttribute(view, kAXSelectedAttribute as String, false)
            builder.setActionNames(view, [kAXPressAction as String, kAXCancelAction as String])
            builder.setRole(toggle, kAXMenuItemRole as String)
            builder.setAttribute(toggle, kAXTitleAttribute as String, "Show Mixer")
            builder.setAttribute(toggle, kAXEnabledAttribute as String, true)
            builder.setActionNames(toggle, [kAXPressAction as String])
            builder.setChildren(menuBar, [view])
            builder.setChildren(view, [toggle])
            builder.setRole(mixer, kAXGroupRole as String)
            builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
            builder.setRole(strip, kAXLayoutItemRole as String)
            let name = builder.element(965_958)
            builder.setRole(name, kAXTextFieldRole as String)
            builder.setAttribute(name, kAXDescriptionAttribute as String, "Name")
            builder.setAttribute(name, kAXValueAttribute as String, "Mixer-only aux")
            builder.setChildren(strip, [name])
            builder.setChildren(mixer, [strip])
        }

        func channel(observationMouse: AXMouseHelper.Runtime? = nil,
                     observationHit: AXUIElement? = nil) -> AccessibilityChannel {
            let base = builder.makeLogicRuntime(appElement: app,
                attributeValueHandler: { [self] element, attribute in
                    if !enabledReadable, CFEqual(element, toggle), attribute == kAXEnabledAttribute as String {
                        return .some(nil)
                    }
                    return nil
                },
                attributeValueResultHandler: { [self] element, attribute in
                    if let unreadLabelElement, CFEqual(element, unreadLabelElement), attribute == kAXTitleAttribute as String {
                        return .failure(.init(raw: Int32(AXError.cannotComplete.rawValue)))
                    }
                    return nil
                },
                setAttributeHandler: { _, _, _ in Issue.record("inspection must not set AX attributes"); return false },
                performActionHandler: { [self] element, action in
                    if CFEqual(element, view) {
                        pressed.append(action == kAXCancelAction as String ? "cancel_view" : "open_view")
                        if action == kAXPressAction as String {
                            builder.setAttribute(view, kAXSelectedAttribute as String, true)
                            afterOpen?()
                            return !openReturnsFalse
                        }
                        if !cancelLeavesMenuOpen {
                            builder.setAttribute(view, kAXSelectedAttribute as String, false)
                            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, rail)
                        }
                        return true
                    }
                    guard CFEqual(element, toggle), action == kAXPressAction as String else {
                        Issue.record("unexpected navigation action"); return false
                    }
                    if showing && hideFails { pressed.append("hide_mixer_failed"); return false }
                    if !showing && showFails { pressed.append("show_mixer_failed"); return false }
                    showing.toggle()
                    pressed.append(showing ? "show_mixer" : "hide_mixer")
                    builder.setAttribute(toggle, kAXTitleAttribute as String, showing ? "Hide Mixer" : "Show Mixer")
                    builder.setChildren(window, [rail] + extraWindowChildren + (showing ? [mixer] : []))
                    builder.setAttribute(view, kAXSelectedAttribute as String, false)
                    if showing { afterShow?() } else { afterHide?() }
                    return true
                },
                executeAppleScript: { _ in Issue.record("inspection must not invoke AppleScript"); return .error("forbidden") })
            guard let observationMouse else {
                return AccessibilityChannel(runtime: .axBacked(
                    isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: base))
            }
            let ax = base.ax
            let observedAX = AXHelpers.Runtime(axApp: ax.axApp, attributeValue: ax.attributeValue,
                attributeIsSettable: ax.attributeIsSettable, setAttributeValue: ax.setAttributeValue,
                children: ax.children, performAction: ax.performAction, childCount: ax.childCount,
                actionNames: ax.actionNames, actionNamesResult: ax.actionNamesResult,
                childrenResult: ax.childrenResult, attributeValueResult: ax.attributeValueResult,
                performActionResult: ax.performActionResult,
                elementAtPosition: { [self] element, point in
                    guard CFEqual(element, app), point == CGPoint(x: 16, y: 26) else { return .success(nil) }
                    return .success(observationHit)
                })
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: observedAX,
                executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") },
                onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("no Escape") },
                focusedApplicationPID: { 4242 }, observeFrontmost: nil)
            let deniedMouse = AXMouseHelper.Runtime(postMouseEvent: { _, _, _ in Issue.record("no unrelated mouse"); return false },
                postKeyEvent: { _ in Issue.record("no keys"); return false },
                postUnicodeScalar: { _ in Issue.record("no typing"); return false }, sleepMicros: { _ in })
            let process = ProcessUtils.Runtime(logicProPID: { 4242 }, fallbackLogicProPID: { nil },
                logicProRunning: { true }, activateLogicPro: { Issue.record("no activation"); return false },
                logicIsFrontmost: { true }, logicProBundleURL: { nil })
            return AccessibilityChannel(runtime: .axBacked(
                isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: logic,
                controlBarMouseRuntime: deniedMouse, trackRenameMouseRuntime: deniedMouse,
                trackToggleKeyRuntime: deniedMouse, observationMouseRuntime: observationMouse,
                processRuntime: process, confirmNewTrackDialog: { Issue.record("no Return") },
                canPostEvents: { true }, runTempoFallback: { _ in Issue.record("no fallback"); return false }))
        }
    }

    private func inspect(_ fixture: Fixture, navigation: Bool,
                         registry: TargetRegistry? = nil, projectRef: String? = nil) async throws -> [String: Any] {
        let cache = StateCache()
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: registry ?? TargetRegistry(),
            poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                               keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        var params: [String: Value] = ["domains": .array([.string("strips")]), "allow_ui_navigation": .bool(navigation)]
        if let projectRef { params["project_ref"] = .string(projectRef) }
        let commandParams = params
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: commandParams, mutationGate: gate) { await handler(dependencies, commandParams) }
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test func translatedHideCannotAuthorizeTemporaryMixerReveal() async throws {
        let fixture = Fixture()
        fixture.afterOpen = { [fixture] in
            fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String, "Masquer la table de mixage")
        }
        let body = try await inspect(fixture, navigation: true)
        #expect(body["schema"] as? String == SessionPopulationObservation.schema)
        #expect(!fixture.showing)
        #expect(!fixture.pressed.contains("show_mixer"))
        #expect(!fixture.pressed.contains("hide_mixer"))
        let effects = try #require(body["ui_effects"] as? [String: Any])
        let changed = try #require(effects["changed"] as? [String])
        #expect(!changed.contains("mixer_visibility"))
    }

    @Test func permittedNavigationReadsTheRevealedMixerAndRestoresIt() async throws {
        let fixture = Fixture()
        let body = try await inspect(fixture, navigation: true)
        #expect(body["schema"] as? String == SessionPopulationObservation.schema)
        let strips = try #require(body["strips"] as? [String: Any])
        let rows = try #require(strips["rows"] as? [[String: Any]])
        #expect(rows.compactMap { $0["name"] as? String } == ["Mixer-only aux"])
        #expect(strips["coverage"] as? String == "partial", "revealing the Mixer does not prove filter/end coverage")
        let effects = try #require(body["ui_effects"] as? [String: Any])
        let navigated = try #require(effects["navigation_performed"] as? Bool)
        #expect(navigated)
        #expect(effects["restoration"] as? String == "restored")
        #expect(fixture.pressed == ["open_view", "show_mixer", "open_view", "hide_mixer"])
        #expect(!fixture.showing)
    }

    private func inspectVisibilityFixture(_ fixture: Issue969MixerVisibilitySetterTests.Fixture) async throws -> [String: Any] {
        let cache = StateCache()
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
            poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                               keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array([.string("strips")]), "allow_ui_navigation": .bool(true)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test("temporary Mixer reading restores its exact live workspace after the reveal moves focus",
          arguments: [false, true])
    func temporaryRevealRestoresCapturedWorkspaceFocus(parentContainer: Bool) async throws {
        let fixture = Issue969MixerVisibilitySetterTests.Fixture(showing: false)
        let movedFocus: AXUIElement
        if parentContainer {
            let container = fixture.builder.element(965_991)
            fixture.builder.setRole(container, kAXGroupRole as String)
            fixture.builder.setRole(fixture.mixer, "AXLayoutArea")
            let strip = fixture.builder.element(965_992)
            fixture.builder.setRole(strip, kAXLayoutItemRole as String)
            fixture.builder.setChildren(strip, [])
            fixture.builder.setChildren(fixture.mixer, [strip])
            fixture.builder.setChildren(container, [fixture.mixer])
            fixture.mixerContainer = container
            movedFocus = container
        } else { movedFocus = fixture.mixer }
        fixture.permitsCapturedFocusRestore = true
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, true)
        fixture.afterVisibilityChange = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                fixture.showing ? movedFocus : fixture.rail)
        }
        let body = try await inspectVisibilityFixture(fixture)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        #expect(fixture.events == ["open_view", "show_mixer", "restore_captured_focus", "open_view", "hide_mixer"])
        #expect(!fixture.showing)
        let focus = try #require(fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String))
        #expect(CFEqual(focus as AnyObject, fixture.rail))
        #expect((body["strips"] as? [String: Any])?["coverage"] as? String != "complete",
                "exact view restoration does not qualify the requested population")
    }

    @Test("temporary reading does not focus or hide after lost custody or an unverified focus setter",
          arguments: ["unsupported", "false_ack", "no_readback", "retired", "foreign", "window", "document", "pid", "app", "menu_open", "parent_mismatch", "after_restore_focus", "after_restore_document", "after_path_pid", "after_path_app"])
    func temporaryRevealRefusesUnownedFocusRestoration(fault: String) async throws {
        let fixture = Issue969MixerVisibilitySetterTests.Fixture(showing: false)
        fixture.permitsCapturedFocusRestore = true
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, fault != "unsupported")
        fixture.focusRestoreAcknowledged = fault != "false_ack"
        fixture.focusRestoreChangesFocus = fault != "no_readback"
        fixture.leafLeavesMenuOpen = fault == "menu_open"
        let foreign = fixture.builder.element(965_993)
        fixture.builder.setRole(foreign, kAXGroupRole as String)
        fixture.builder.setChildren(foreign, [])
        fixture.builder.setAttribute(foreign, kAXMainWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(foreign, kAXFocusedWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(foreign, kAXFocusedUIElementAttribute as String, fixture.mixer)
        fixture.builder.setAttribute(foreign, kAXFrontmostAttribute as String, true)
        fixture.builder.setAttribute(foreign, kAXMenuBarAttribute as String, fixture.menuBar)
        fixture.afterVisibilityChange = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.mixer)
            switch fault {
            case "retired": fixture.builder.setChildren(fixture.window, [fixture.mixer])
            case "foreign":
                fixture.builder.setChildren(fixture.window, [fixture.rail, fixture.mixer, foreign])
                fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, foreign)
            case "window": fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, foreign)
            case "document": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
            case "pid": fixture.logicPID = 4243
            case "app": fixture.currentApp = foreign
            case "parent_mismatch": fixture.builder.setAttribute(fixture.rail, kAXParentAttribute as String, foreign)
            default: break
            }
        }
        fixture.afterFocusRestore = {
            switch fault {
            case "after_restore_focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, foreign)
            case "after_restore_document": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
            default: break
            }
        }
        if fault == "after_path_pid" || fault == "after_path_app" {
            fixture.attributeReadObserver = { element, attribute in
                guard fixture.events.contains("restore_captured_focus"), CFEqual(element, fixture.rail),
                      attribute == kAXParentAttribute as String else { return }
                fixture.attributeReadObserver = nil
                if fault == "after_path_pid" { fixture.logicPID = 4243 }
                else {
                    fixture.builder.setAttribute(foreign, kAXFocusedUIElementAttribute as String, fixture.rail)
                    fixture.currentApp = foreign
                }
            }
        }
        let body = try await inspectVisibilityFixture(fixture)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
        #expect(!fixture.events.contains("hide_mixer"))
        #expect(fixture.showing)
        let setterExpected = ["false_ack", "no_readback", "after_restore_focus", "after_restore_document", "after_path_pid", "after_path_app"].contains(fault)
        let setterMatches = fixture.events.contains("restore_captured_focus") == setterExpected
        #expect(setterMatches)
    }

    @Test(arguments: [false, true])
    func aMixerRevealCannotTransferStackNavigationToAnotherProject(sameWindow: Bool) async throws {
        let fixture = Fixture()
        let otherWindow = sameWindow ? fixture.window : fixture.builder.element(965_970)
        let otherRail = fixture.builder.element(965_971)
        let otherHeader = fixture.builder.element(965_972)
        let triangle = fixture.builder.element(965_973)
        let bar = fixture.builder.element(965_974)
        let play = fixture.builder.element(965_975)
        let record = fixture.builder.element(965_976)
        if !sameWindow {
            fixture.builder.setRole(otherWindow, kAXWindowRole as String)
            fixture.builder.setAttribute(otherWindow, kAXTitleAttribute as String, "Other - Tracks")
            fixture.builder.setAttribute(otherWindow, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
        }
        fixture.builder.setRole(otherRail, kAXListRole as String)
        fixture.builder.setAttribute(otherRail, kAXIdentifierAttribute as String, "Track Headers")
        fixture.builder.setRole(otherHeader, kAXLayoutItemRole as String)
        fixture.builder.setAttribute(otherHeader, kAXTitleAttribute as String, "Other stack")
        fixture.builder.setAttribute(otherHeader, kAXSelectedAttribute as String, false)
        fixture.builder.setRole(triangle, kAXDisclosureTriangleRole as String)
        fixture.builder.setAttribute(triangle, kAXValueAttribute as String, 0)
        fixture.builder.setFrame(triangle, x: 10, y: 20, width: 12, height: 12)
        fixture.builder.setChildren(otherHeader, [triangle])
        fixture.builder.setChildren(otherRail, [otherHeader])
        fixture.builder.setRole(bar, kAXGroupRole as String)
        fixture.builder.setAttribute(bar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
        for (control, label) in [(play, AXLocalePolicy.transportPlayControl), (record, AXLocalePolicy.transportRecordControl)] {
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, label.canonical)
            fixture.builder.setAttribute(control, kAXValueAttribute as String, 0)
        }
        fixture.builder.setChildren(bar, [play, record])
        if !sameWindow { fixture.builder.setChildren(otherWindow, [otherRail, bar]) }
        fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, sameWindow ? [fixture.window] : [fixture.window, otherWindow])
        fixture.afterShow = {
            // The existing Arrange reader selects the first rail-bearing window.
            // Model the switched window as that actual current acquisition source.
            fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, sameWindow ? [otherWindow] : [otherWindow, fixture.window])
            if sameWindow {
                // Reuse the exact window/title, but change its actual document and rail.
                fixture.builder.setAttribute(otherWindow, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                fixture.builder.setChildren(otherWindow, [otherRail, bar])
            }
            fixture.builder.setAttribute(fixture.app, kAXMainWindowAttribute as String, otherWindow)
            fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, otherWindow)
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, otherRail)
        }
        let mouseEvents = FixtureMouseEvents()
        let mouse = AXMouseHelper.Runtime(postMouseEvent: { type, point, clicks in
            guard point == CGPoint(x: 16, y: 26), clicks == 1,
                  type == .leftMouseDown || type == .leftMouseUp else { Issue.record("unexpected mouse"); return false }
            mouseEvents.append(type == .leftMouseDown ? "B_down" : "B_up")
            if type == .leftMouseUp {
                let wasOpen = (fixture.builder.attributeValue(triangle, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                fixture.builder.setAttribute(triangle, kAXValueAttribute as String, wasOpen ? 0 : 1)
            }
            return true
        }, postKeyEvent: { _ in Issue.record("no keys"); return false },
           postUnicodeScalar: { _ in Issue.record("no typing"); return false }, sleepMicros: { _ in })
        let cache = StateCache()
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
            poller: StatePoller(axChannel: fixture.channel(observationMouse: mouse, observationHit: triangle), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array([.string("tracks"), .string("strips")]), "allow_ui_navigation": .bool(true)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
        #expect(fixture.pressed == ["open_view", "show_mixer"])
        #expect(fixture.showing, "A's retained Mixer cannot be restored after the project switch")
        let ax = fixture.builder.makeAXRuntime()
        let main: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXMainWindowAttribute as String, runtime: ax)
        let heldMain = try #require(main)
        #expect(CFEqual(heldMain, otherWindow))
        #expect(fixture.builder.attributeValue(otherWindow, kAXDocumentAttribute as String) as? String == "file:///tmp/Other.logicx")
        #expect(ax.children(otherRail).count == 1 && CFEqual(ax.children(otherRail)[0], otherHeader))
        #expect(mouseEvents.values.isEmpty, "ownership of A cannot authorize disclosure gestures in B")
        #expect((fixture.builder.attributeValue(triangle, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(effects["restoration"] as? String == "not_restored")
        #expect(fixture.builder.setCalls.isEmpty)
        #expect(gate.currentOperation() == nil)
    }

    @Test(arguments: [false, true])
    func sameProjectComposedMixerAndStackObservationRestoresBoth(navigation: Bool) async throws {
        let fixture = Fixture()
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lpm965-composed-\(UUID().uuidString).logicx")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundle) }
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, bundle.absoluteString)
        fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, [fixture.window])
        let header = fixture.builder.element(965_980)
        let child = fixture.builder.element(965_981)
        let triangle = fixture.builder.element(965_982)
        let bar = fixture.builder.element(965_983)
        let play = fixture.builder.element(965_984)
        let record = fixture.builder.element(965_985)
        for (row, name) in [(header, "Owned stack"), (child, "Observed child")] {
            fixture.builder.setRole(row, kAXLayoutItemRole as String)
            fixture.builder.setAttribute(row, kAXTitleAttribute as String, name)
            fixture.builder.setAttribute(row, kAXSelectedAttribute as String, false)
            fixture.builder.setChildren(row, [])
        }
        fixture.builder.setRole(triangle, kAXDisclosureTriangleRole as String)
        fixture.builder.setAttribute(triangle, kAXValueAttribute as String, 0)
        fixture.builder.setFrame(triangle, x: 10, y: 20, width: 12, height: 12)
        fixture.builder.setChildren(header, [triangle])
        fixture.builder.setChildren(fixture.rail, [header])
        fixture.builder.setRole(bar, kAXGroupRole as String)
        fixture.builder.setAttribute(bar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
        for (control, label) in [(play, AXLocalePolicy.transportPlayControl), (record, AXLocalePolicy.transportRecordControl)] {
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, label.canonical)
            fixture.builder.setAttribute(control, kAXValueAttribute as String, 0)
        }
        fixture.builder.setChildren(bar, [play, record])
        fixture.extraWindowChildren = [bar]
        fixture.builder.setChildren(fixture.window, [fixture.rail, bar])
        let mouse = AXMouseHelper.Runtime(postMouseEvent: { type, point, clicks in
            guard point == CGPoint(x: 16, y: 26), clicks == 1,
                  type == .leftMouseDown || type == .leftMouseUp else { Issue.record("unexpected mouse"); return false }
            fixture.pressed.append(type == .leftMouseDown ? "stack_down" : "stack_up")
            if type == .leftMouseUp {
                let wasOpen = (fixture.builder.attributeValue(triangle, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                fixture.builder.setAttribute(triangle, kAXValueAttribute as String, wasOpen ? 0 : 1)
                fixture.builder.setChildren(fixture.rail, wasOpen ? [header] : [header, child])
            }
            return true
        }, postKeyEvent: { _ in Issue.record("no keys"); return false },
           postUnicodeScalar: { _ in Issue.record("no typing"); return false }, sleepMicros: { _ in })
        let cache = StateCache()
        let registry = TargetRegistry()
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: registry,
            poller: StatePoller(axChannel: fixture.channel(observationMouse: mouse, observationHit: triangle), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array([.string("tracks"), .string("strips")]), "allow_ui_navigation": .bool(navigation)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) {
                await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
            }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let rows = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.compactMap { $0["name"] as? String } == (navigation ? ["Owned stack", "Observed child"] : ["Owned stack"]))
        #expect(rows.compactMap { $0["track_ref"] as? String }.count == rows.count)
        let current = await cache.getTracks()
        #expect(current.map(\.name) == ["Owned stack"])
        #expect(fixture.pressed == (navigation ? ["open_view", "show_mixer", "stack_down", "stack_up", "stack_down", "stack_up", "open_view", "hide_mixer"] : []))
        #expect(!fixture.showing)
        #expect((fixture.builder.attributeValue(triangle, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        let effects = try #require(body["ui_effects"] as? [String: Any])
        if navigation { #expect(effects["restoration"] as? String == "restored") }
        let focus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String, runtime: fixture.builder.makeAXRuntime())
        let heldFocus = try #require(focus)
        #expect(CFEqual(heldFocus, fixture.rail))
        #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        #expect(fixture.builder.setCalls.isEmpty && gate.currentOperation() == nil)
    }

    private final class FixtureMouseEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        func append(_ value: String) { lock.withLock { recorded.append(value) } }
        var values: [String] { lock.withLock { recorded } }
    }

    @Test func navigationDisabledNeverOpensTheMenu() async throws {
        let fixture = Fixture()
        let body = try await inspect(fixture, navigation: false)
        let strips = try #require(body["strips"] as? [String: Any])
        #expect(strips["coverage"] as? String == "unavailable")
        #expect(fixture.pressed.isEmpty)
        #expect(!fixture.showing)
    }

    @Test func aFailedHideDismissesOnlyTheOwnedMenuAndReportsTheResidualMixer() async throws {
        let fixture = Fixture()
        fixture.hideFails = true
        let body = try await inspect(fixture, navigation: true)
        let effects = try #require(body["ui_effects"] as? [String: Any])
        let navigated = try #require(effects["navigation_performed"] as? Bool)
        #expect(navigated)
        #expect(effects["restoration"] as? String == "not_restored")
        #expect(fixture.showing)
        #expect(fixture.pressed == ["open_view", "show_mixer", "open_view", "hide_mixer_failed", "cancel_view"])
        #expect((body["strips"] as? [String: Any])?["coverage"] as? String == "unstable")
    }

    @Test func aHumanFocusChangeDuringMenuOpeningStopsTheLeafAndRestoration() async throws {
        let fixture = Fixture()
        let otherItem = fixture.builder.element(965_959)
        fixture.builder.setRole(otherItem, kAXMenuItemRole as String)
        fixture.afterOpen = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, otherItem)
        }
        let body = try await inspect(fixture, navigation: true)
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(effects["restoration"] as? String == "not_restored")
        #expect(fixture.pressed == ["open_view"], "do not finish or cancel someone else's menu choice")
        #expect(!fixture.showing)
    }

    @Test func unreadableEnabledStateCannotAuthorizeTheLeaf() async throws {
        let fixture = Fixture()
        fixture.enabledReadable = false
        let body = try await inspect(fixture, navigation: true)
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(effects["restoration"] as? String == "restored")
        #expect(fixture.pressed == ["open_view", "cancel_view"])
        #expect(!fixture.showing)
    }

    @Test func failedMenuOpenStillReportsAndRestoresTheOwnedEffect() async throws {
        let fixture = Fixture()
        fixture.openReturnsFalse = true
        fixture.afterOpen = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.toggle)
        }
        let body = try await inspect(fixture, navigation: true)
        let effects = try #require(body["ui_effects"] as? [String: Any])
        let navigated = try #require(effects["navigation_performed"] as? Bool)
        #expect(navigated)
        #expect(effects["changed"] as? [String] == ["view_menu"])
        #expect(effects["restoration"] as? String == "restored")
        #expect(fixture.pressed == ["open_view", "cancel_view"])
    }

    @Test func cancelAcknowledgementWithoutMenuClosureIsNotAStableBaseline() async throws {
        let fixture = Fixture()
        fixture.enabledReadable = false
        fixture.cancelLeavesMenuOpen = true
        fixture.afterOpen = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.toggle)
        }
        let body = try await inspect(fixture, navigation: true)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
        #expect((body["strips"] as? [String: Any])?["coverage"] as? String == "unstable")
        #expect(fixture.pressed == ["open_view", "cancel_view"])
    }

    @Test func failedMixerActionDoesNotClaimAnObservedVisibilityChange() async throws {
        let fixture = Fixture()
        fixture.showFails = true
        let body = try await inspect(fixture, navigation: true)
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(effects["changed"] as? [String] == ["view_menu"])
        let attempted = try #require(effects["attempted"] as? [String])
        #expect(attempted.contains("mixer_visibility"))
        #expect(effects["restoration"] as? String == "not_restored", "a failed action is not a proven native no-op")
        #expect(fixture.pressed == ["open_view", "show_mixer_failed", "cancel_view"])
        #expect(!fixture.showing)
    }

    @Test(arguments: [true, false])
    func anUnreadableCompetingMenuLabelCannotAuthorizeNavigation(atMenuBar: Bool) async throws {
        let fixture = Fixture()
        let competing = fixture.builder.element(965_960)
        fixture.builder.setRole(competing, atMenuBar ? kAXMenuBarItemRole as String : kAXMenuItemRole as String)
        fixture.unreadLabelElement = competing
        fixture.builder.setChildren(atMenuBar ? fixture.menuBar : fixture.view,
                                    [atMenuBar ? fixture.view : fixture.toggle, competing])
        let body = try await inspect(fixture, navigation: true)
        #expect(fixture.pressed == (atMenuBar ? [] : ["open_view", "cancel_view"]))
        #expect(!fixture.showing)
        #expect((body["strips"] as? [String: Any])?["coverage"] as? String == "unavailable")
    }

    @Test func cancellationAfterRevealReportsResidualsWithoutAnotherUIAction() async throws {
        let fixture = Fixture()
        fixture.afterShow = { withUnsafeCurrentTask { $0?.cancel() } }
        let body = try await inspect(fixture, navigation: true)
        #expect(body["error"] as? String == "cancelled")
        #expect(body["snapshot_id"] == nil)
        let navigated = try #require(body["navigation_performed"] as? Bool)
        #expect(navigated)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
        #expect(fixture.pressed == ["open_view", "show_mixer"])
        #expect(fixture.showing)
    }

    @Test func publicationFailureRetainsTheAlreadyObservedUIEffects() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = StateCache()
            let boundary = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var population = SessionPopulationObservation.FreshPopulation(
                project: ProjectInfo(name: "Navigation fixture"), tracks: nil, strips: [], fileTrackCount: nil,
                beganAt: now, endedAt: now, stable: true)
            population.uiEffects = .init(navigationPerformed: true, restoration: "restored",
                                         changed: ["view_menu", "mixer_visibility"])
            let accepted = try #require(await cache.acceptFreshPopulation(population, ifCurrent: boundary, stoppingWhen: { false }))
            let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: nil,
                fileReader: .unavailable, accepted: accepted)
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { false })
            let result = await OperationTraceContext.$current.withValue(context) {
                await ProjectDispatcher.handle(command: "inspect_session", params: [:], router: ChannelRouter(),
                    cache: cache, cleanupAuditFileReader: .unavailable, acquireSessionPopulation: { _ in capture })
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "readback_unavailable")
            #expect(body["snapshot_id"] == nil)
            let navigated = try #require(body["navigation_performed"] as? Bool)
            #expect(navigated)
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
        }
    }

    @Test(arguments: [true, false])
    func postAcquisitionRefusalRetainsObservedEffects(staleReference: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = StateCache()
            let registry = TargetRegistry()
            let boundary = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
            let now = Date()
            var population = SessionPopulationObservation.FreshPopulation(
                project: ProjectInfo(name: "Navigation fixture", filePath: "/tmp/NavigationFixture.logicx"),
                tracks: [], strips: [], fileTrackCount: nil, beganAt: now, endedAt: now, stable: false)
            population.uiEffects = .init(navigationPerformed: true, restoration: "not_restored",
                                         changed: ["view_menu", "mixer_visibility"], reason: "navigation_ownership_lost")
            let accepted = try #require(await cache.acceptFreshPopulation(population, ifCurrent: boundary, stoppingWhen: { false }))
            let capture = await SessionPopulationObservation.capture(cache: cache, targetRegistry: registry,
                fileReader: .unavailable, requestedProjectRef: staleReference ? "invalidated-reference" : nil, accepted: accepted)
            if !staleReference { await cache.clearProjectState() }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { true })
            let result = await OperationTraceContext.$current.withValue(context) {
                await ProjectDispatcher.handle(command: "inspect_session", params: [:], router: ChannelRouter(),
                    cache: cache, targetRegistry: registry, cleanupAuditFileReader: .unavailable,
                    acquireSessionPopulation: { _ in capture })
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == (staleReference ? "stale_target_reference" : "stale_snapshot"))
            #expect(body["snapshot_id"] == nil)
            let effects = try #require(body["ui_effects"] as? [String: Any])
            let navigated = try #require(effects["navigation_performed"] as? Bool)
            #expect(navigated)
            #expect(effects["changed"] as? [String] == ["view_menu", "mixer_visibility"])
            #expect(effects["restoration"] as? String == "not_restored")
        }
    }

    @Test(arguments: [8, 9, 12])
    func postChannelOwnershipLossRetainsRestorationReceipt(refuseAt: Int) async throws {
        let fixture = Fixture()
        let cache = StateCache()
        let poller = StatePoller(axChannel: fixture.channel(), cache: cache,
            runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                           keyboardFocus: { .notTextEditing }))
        let checks = RestorationChecks(refuseAt: refuseAt)
        fixture.afterHide = { checks.arm() }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { checks.stillOwned() })
        let result = await OperationTraceContext.$current.withValue(context) {
            await ProjectDispatcher.handle(command: "inspect_session",
                params: ["domains": .array([.string("strips")]), "allow_ui_navigation": .bool(true)],
                router: ChannelRouter(), cache: cache, cleanupAuditFileReader: .unavailable,
                acquireSessionPopulation: { request in
                    try await poller.acquireSessionPopulation(request: request, targetRegistry: nil)
                })
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "readback_unavailable")
        #expect(fixture.pressed == ["open_view", "show_mixer", "open_view", "hide_mixer"])
        let navigated = try #require(body["navigation_performed"] as? Bool)
        #expect(navigated)
        #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
    }

    private final class RestorationChecks: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var checks = 0
        private let refuseAt: Int
        init(refuseAt: Int) { self.refuseAt = refuseAt }
        func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
        func stillOwned() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard armed else { return true }
            checks += 1
            // Runtime calibration records checks 1–7 in the channel, 8 before cache
            // acceptance, 9 inside acceptance, and 12 after capture (no registry).
            return checks < refuseAt
        }
    }

    @Test func aCurrentReferenceForAnotherLiveDocumentDoesNotNavigate() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = Fixture()
            let registry = TargetRegistry()
            let snapshot = await registry.currentSnapshot
            let descriptor = TargetDescriptor.project(name: "Other", filePath: "/tmp/Other.logicx", epoch: snapshot.projectEpoch)
            let reference = try #require(await registry.bind(kind: .project, descriptor: descriptor,
                fingerprint: descriptor.fingerprint, snapshot: snapshot))
            let body = try await inspect(fixture, navigation: true, registry: registry, projectRef: reference.rawValue)
            #expect(body["error"] as? String == "stale_target_reference")
            #expect(fixture.pressed.isEmpty)
            #expect(!fixture.showing)
        }
    }
}
