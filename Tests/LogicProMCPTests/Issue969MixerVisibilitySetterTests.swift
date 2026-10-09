@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#969 explicit final Mixer visibility", .serialized)
struct Issue969MixerVisibilitySetterTests {
    final class Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let menuBar: AXUIElement
        let view: AXUIElement
        let toggle: AXUIElement
        let mixer: AXUIElement
        var showing: Bool
        var extraWindowChildren: [AXUIElement] = []
        var afterVisibilityChange: (@Sendable () -> Void)?
        var attributeReadObserver: (@Sendable (AXUIElement, String) -> Void)?
        var events: [String] = []
        var leafAcknowledged = true
        var leafChangesVisibility = true
        var leafLeavesMenuOpen = false
        var contradictoryShow = false
        var contradictoryHide = false
        var unknownWindowChildren = false
        var cancelLeavesMenuOpen = false
        var gateOwned = true
        var cancelled = false
        var logicPID: pid_t = 4242
        var currentApp: AXUIElement?
        var unreadNestedGroup: AXUIElement?
        var failedMetadata: (AXUIElement, String)?
        var failedMetadataError: AXError = .cannotComplete
        var structuralRoleSamples: [String] = []
        var finalMixerReads = 0
        var finalFocusReads = 0
        var finalFocusArmed = false
        var focusReadAtLoss: Int?
        var afterFinalFocusRead: (@Sendable () -> Void)?
        var afterCancel: (@Sendable () -> Void)?
        var afterDecisiveMixerRead: (@Sendable () -> Void)?
        var afterCleanupActionNames: (@Sendable () -> Void)?
        var permitsCapturedFocusRestore = false
        var focusRestoreAcknowledged = true
        var focusRestoreChangesFocus = true
        var mixerContainer: AXUIElement?
        var railContainer: AXUIElement?
        var afterFocusRestore: (@Sendable () -> Void)?
        var postShowMenuReads = 0

        init(showing: Bool) {
            self.showing = showing
            app = builder.element(969_001)
            window = builder.element(969_002)
            rail = builder.element(969_003)
            menuBar = builder.element(969_004)
            view = builder.element(969_005)
            toggle = builder.element(969_006)
            mixer = builder.element(969_007)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Visibility fixture - Tracks")
            builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/VisibilityFixture.logicx")
            builder.setAttribute(app, kAXWindowsAttribute as String, [window])
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setAttribute(app, kAXFocusedWindowAttribute as String, window)
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, rail)
            builder.setAttribute(app, kAXFrontmostAttribute as String, true)
            builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
            builder.setRole(rail, kAXListRole as String)
            builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            builder.setChildren(rail, [])
            builder.setRole(menuBar, kAXMenuBarRole as String)
            builder.setRole(view, kAXMenuBarItemRole as String)
            builder.setAttribute(view, kAXTitleAttribute as String, "View")
            builder.setAttribute(view, kAXSelectedAttribute as String, false)
            builder.setActionNames(view, [kAXPressAction as String, kAXCancelAction as String])
            builder.setRole(toggle, kAXMenuItemRole as String)
            builder.setAttribute(toggle, kAXEnabledAttribute as String, true)
            builder.setActionNames(toggle, [kAXPressAction as String])
            builder.setChildren(menuBar, [view])
            builder.setChildren(view, [toggle])
            builder.setRole(mixer, kAXGroupRole as String)
            builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
            builder.setChildren(mixer, [])
            updateVisibility()
        }

        func updateVisibility() {
            builder.setChildren(window, extraWindowChildren + (showing ? [railContainer ?? rail, mixerContainer ?? mixer] : [railContainer ?? rail]))
            builder.setAttribute(toggle, kAXTitleAttribute as String, showing ? "Hide Mixer" : "Show Mixer")
        }

        func observeDecisiveMixerRead(_ element: AXUIElement, _ attribute: String) {
            if CFEqual(element, mixer), attribute == kAXIdentifierAttribute as String,
               builder.attributeValue(view, kAXSelectedAttribute as String) as? Bool == true,
               let callback = afterDecisiveMixerRead {
                afterDecisiveMixerRead = nil
                callback()
            }
        }

        func channel() -> AccessibilityChannel {
            let ax = builder.makeAXRuntime(appElement: app,
                appElementProvider: { [self] _ in currentApp ?? app },
                attributeValueHandler: { [self] element, attribute in
                    attributeReadObserver?(element, attribute)
                    observeDecisiveMixerRead(element, attribute)
                    if afterFinalFocusRead != nil {
                        if CFEqual(element, mixer), attribute == kAXIdentifierAttribute as String {
                            finalMixerReads += 1
                        }
                        if CFEqual(element, app), attribute == kAXFocusedUIElementAttribute as String,
                           finalMixerReads == 2 {
                            finalFocusReads += 1
                            if finalFocusArmed, let callback = afterFinalFocusRead {
                                focusReadAtLoss = finalFocusReads
                                afterFinalFocusRead = nil
                                callback()
                            }
                        }
                    }
                    return nil
                },
                attributeValueResultHandler: { [self] element, attribute in
                    attributeReadObserver?(element, attribute)
                    observeDecisiveMixerRead(element, attribute)
                    if let failedMetadata, CFEqual(element, failedMetadata.0), attribute == failedMetadata.1 {
                        return .failure(.init(raw: Int32(failedMetadataError.rawValue)))
                    }
                    return nil
                }, childrenResultHandler: { [self] element in
                    if unknownWindowChildren, CFEqual(element, window) {
                        return .failure(.init(raw: Int32(AXError.cannotComplete.rawValue)))
                    }
                    if let unreadNestedGroup, CFEqual(element, unreadNestedGroup) {
                        return .failure(.init(raw: Int32(AXError.cannotComplete.rawValue)))
                    }
                    return nil
                },
                actionNamesHandler: { [self] element in
                    if CFEqual(element, view), showing,
                       builder.attributeValue(view, kAXSelectedAttribute as String) as? Bool == true,
                       let callback = afterCleanupActionNames {
                        afterCleanupActionNames = nil
                        callback()
                    }
                    return nil
                },
                setAttributeHandler: { [self] element, attribute, value in
                    if permitsCapturedFocusRestore, CFEqual(element, rail),
                       attribute == kAXFocusedAttribute as String, value as? Bool == true {
                        events.append("restore_captured_focus")
                        if focusRestoreChangesFocus { builder.setAttribute(app, kAXFocusedUIElementAttribute as String, rail) }
                        afterFocusRestore?()
                        return focusRestoreAcknowledged
                    }
                    events.append("unexpected_setter"); Issue.record("visibility must not set an AX attribute"); return false
                }, performActionHandler: { [self] element, action in
                    if CFEqual(element, view) {
                        if action == kAXPressAction as String {
                            events.append("open_view")
                            builder.setAttribute(view, kAXSelectedAttribute as String, true)
                            return true
                        }
                        if action == kAXCancelAction as String {
                            events.append("cancel_view")
                            builder.setAttribute(view, kAXSelectedAttribute as String, cancelLeavesMenuOpen)
                            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, rail)
                            afterCancel?()
                            return true
                        }
                    }
                    if CFEqual(element, toggle), action == kAXPressAction as String {
                        if leafChangesVisibility { showing = contradictoryShow ? true : contradictoryHide ? false : !showing }
                        events.append(showing ? "show_mixer" : "hide_mixer")
                        updateVisibility()
                        afterVisibilityChange?()
                        builder.setAttribute(view, kAXSelectedAttribute as String, leafLeavesMenuOpen)
                        return leafAcknowledged
                    }
                    events.append("unexpected_action"); Issue.record("unexpected visibility action"); return false
                }, executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") })
            let logic = AXLogicProElements.Runtime(logicProPID: { [self] in logicPID }, ax: ax,
                executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
                onScreenWindowList: { [] },
                postPopupMenuEscape: { Issue.record("global Escape forbidden") },
                focusedApplicationPID: { [self] in logicPID }, observeFrontmost: nil)
            // Every unrelated channel callback is inert; no axBacked/native ancillary defaults.
            return AccessibilityChannel(runtime: .init(
                isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, appRoot: { [self] in app },
                transportState: { .error("unused") }, toggleTransportButton: { _ in .error("unused") },
                setTempo: { _ in .error("unused") }, setCycleRange: { _ in .error("unused") },
                tracks: { .error("unused") }, selectedTrack: { .error("unused") }, selectTrack: { _ in .error("unused") },
                setTrackToggle: { _, _ in .error("unused") }, renameTrack: { _ in .error("unused") },
                mixerState: { .error("unused") }, channelStrip: { _ in .error("unused") }, setMixerValue: { _, _ in .error("unused") },
                projectInfo: { .error("unused") }, confirmNewTrackDialog: { Issue.record("Return forbidden") },
                canPostEvents: { false }, logicRuntime: logic))
        }
    }

    @Test(arguments: [false, true])
    func showingMixerRestoresExactRetainedSettableFocus(parentContainer: Bool) async throws {
        let fixture = Fixture(showing: false)
        let expectedFocus: AXUIElement
        if parentContainer {
            let container = fixture.builder.element(969_081)
            fixture.builder.setRole(container, kAXGroupRole as String)
            fixture.builder.setRole(fixture.mixer, "AXLayoutArea")
            let strip = fixture.builder.element(969_083)
            fixture.builder.setRole(strip, kAXLayoutItemRole as String)
            fixture.builder.setChildren(strip, [])
            fixture.builder.setChildren(fixture.mixer, [strip])
            fixture.builder.setChildren(container, [fixture.mixer])
            fixture.mixerContainer = container
            expectedFocus = container
        } else { expectedFocus = fixture.mixer }
        fixture.permitsCapturedFocusRestore = true
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, true)
        fixture.afterVisibilityChange = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, expectedFocus)
        }
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "A")
        let verified = try #require(body["verified"] as? Bool)
        #expect(verified)
        #expect(fixture.events == ["open_view", "show_mixer", "restore_captured_focus"])
        let restored = try #require(fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String))
        #expect(CFEqual(restored as AnyObject, fixture.rail))
        #expect(fixture.showing)
    }

    @Test(arguments: ["unsupported", "false_ack", "no_readback", "retired", "foreign", "window", "document", "pid", "cancel", "gate", "menu_open", "parent_mismatch", "after_restore_focus", "after_restore_document", "after_restore_gate"])
    func focusRestorationCannotOverrideLostCustodyOrFalseAcknowledgement(fault: String) async throws {
        let fixture = Fixture(showing: false)
        fixture.permitsCapturedFocusRestore = true
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, fault != "unsupported")
        fixture.focusRestoreAcknowledged = fault != "false_ack"
        fixture.focusRestoreChangesFocus = fault != "no_readback"
        fixture.leafLeavesMenuOpen = fault == "menu_open"
        let foreign = fixture.builder.element(969_082)
        fixture.builder.setRole(foreign, kAXGroupRole as String)
        fixture.builder.setChildren(foreign, [])
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
            case "cancel": fixture.cancelled = true
            case "gate": fixture.gateOwned = false
            case "parent_mismatch": fixture.builder.setAttribute(fixture.rail, kAXParentAttribute as String, foreign)
            default: break
            }
        }
        fixture.afterFocusRestore = {
            switch fault {
            case "after_restore_focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, foreign)
            case "after_restore_document": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
            case "after_restore_gate": fixture.gateOwned = false
            default: break
            }
        }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { fixture.gateOwned }, cancellationRequested: { fixture.cancelled })
        let body = try await set(fixture, visible: true, context: context)
        #expect(body["state"] as? String == "B")
        let verified = try #require(body["verified"] as? Bool)
        #expect(!verified)
        let attempted = ["false_ack", "no_readback", "after_restore_focus", "after_restore_document", "after_restore_gate"].contains(fault)
        #expect(fixture.events == (attempted ? ["open_view", "show_mixer", "restore_captured_focus"] : ["open_view", "show_mixer"]))
        let actualAttempt = try #require(body["focus_restore_attempted"] as? Bool)
        #expect(actualAttempt == attempted)
    }

    @Test
    func anAutomaticallyClosedOwnedMenuPermitsExactFocusRestoration() async throws {
        let fixture = Fixture(showing: false)
        fixture.permitsCapturedFocusRestore = true
        fixture.leafLeavesMenuOpen = true
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, true)
        fixture.afterVisibilityChange = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.mixer)
        }
        fixture.attributeReadObserver = { element, attribute in
            if fixture.showing, CFEqual(element, fixture.app), attribute == kAXFocusedUIElementAttribute as String {
                fixture.builder.setAttribute(fixture.view, kAXSelectedAttribute as String, false)
            }
        }
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "A")
        let verified = try #require(body["verified"] as? Bool)
        #expect(verified)
        #expect(fixture.events == ["open_view", "show_mixer", "restore_captured_focus"])
        let menuRestored = try #require(body["menu_restored"] as? Bool)
        #expect(menuRestored)
    }

    @Test
    func retirementAtTheLastClosedMenuReadCannotFocusTheRetiredElement() async throws {
        let fixture = Fixture(showing: false)
        fixture.permitsCapturedFocusRestore = true
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, true)
        fixture.afterVisibilityChange = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.mixer)
        }
        fixture.attributeReadObserver = { element, attribute in
            if fixture.showing, CFEqual(element, fixture.view), attribute == kAXSelectedAttribute as String {
                fixture.postShowMenuReads += 1
                // AXPress's immediate read, the restoration entry read, then the
                // last closed-menu custody read: retire after the first path proof.
                if fixture.postShowMenuReads == 3 { fixture.builder.setChildren(fixture.window, [fixture.mixer]) }
            }
        }
        let body = try await set(fixture, visible: true)
        #expect(fixture.postShowMenuReads >= 3)
        #expect(body["state"] as? String == "B")
        #expect(fixture.events == ["open_view", "show_mixer"])
        let attempted = try #require(body["focus_restore_attempted"] as? Bool)
        #expect(!attempted)
    }

    private func set(_ fixture: Fixture, visible: Bool, view: String = "mixer", rawVisible: Value? = nil,
                     context: OperationTraceContext? = nil) async throws -> [String: Any] {
        let router = ChannelRouter()
        await router.register(fixture.channel())
        let legacy = MockChannel(id: .midiKeyCommands)
        await router.register(legacy)
        let cache = StateCache()
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: TargetRegistry(),
            poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            projectLifecycleExecute: { _ in .init(executionError: "unused", timedOut: false, terminationStatus: 1, stderrOutput: "") },
            liveTrackNames: { [:] }, projectFileReader: .unavailable)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_navigate", command: "toggle_view"))
        let params: [String: Value] = ["view": .string(view), "visible": rawVisible ?? .bool(visible)]
        if let invalid = LogicProServer.strictParamValidationResult(tool: "logic_navigate", command: "toggle_view", params: params) {
            return sharedJSONObject(sharedToolText(invalid)) ?? [:]
        }
        let result: CallTool.Result
        if let context {
            result = await OperationTraceContext.$current.withValue(context) { await handler(dependencies, params) }
        } else {
            result = await LogicProServer.runWithDeadline(tool: "logic_navigate", command: "toggle_view",
                commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
        }
        #expect(await legacy.executedOps.isEmpty, "an explicit final state must not route a blind key toggle")
        return sharedJSONObject(sharedToolText(result)) ?? [:]
    }

    @Test(arguments: [AXError.notImplemented, AXError.cannotComplete])
    func unavailableArrangeWindowHelpDoesNotHideObservedMixerAbsence(error: AXError) async throws {
        let fixture = Fixture(showing: false)
        fixture.failedMetadata = (fixture.window, kAXHelpAttribute as String)
        fixture.failedMetadataError = error
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "A")
        #expect(fixture.events == ["open_view", "show_mixer"])
        #expect(fixture.showing)
    }

    @Test(arguments: [AXError.notImplemented, AXError.cannotComplete])
    func unavailableContainerHelpDoesNotHideCompletelyReadMixerAbsence(error: AXError) async throws {
        let fixture = Fixture(showing: false)
        let group = fixture.builder.element(969_041)
        fixture.builder.setRole(group, kAXGroupRole as String)
        fixture.builder.setChildren(group, [])
        fixture.extraWindowChildren = [group]
        fixture.updateVisibility()
        fixture.failedMetadata = (group, kAXHelpAttribute as String)
        fixture.failedMetadataError = error
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "A")
        #expect(fixture.events == ["open_view", "show_mixer"])
        #expect(fixture.showing)
    }

    @Test(arguments: [AXError.notImplemented, AXError.cannotComplete])
    func unavailableButtonHelpDoesNotHideCompletelyReadMixerAbsence(error: AXError) async throws {
        let fixture = Fixture(showing: false)
        let button = fixture.builder.element(969_042)
        fixture.builder.setRole(button, kAXButtonRole as String)
        fixture.builder.setChildren(button, [])
        fixture.extraWindowChildren = [button]
        fixture.updateVisibility()
        fixture.failedMetadata = (button, kAXHelpAttribute as String)
        fixture.failedMetadataError = error
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "A")
        #expect(fixture.events == ["open_view", "show_mixer"])
        #expect(fixture.showing)
    }

    @Test func unavailableContainerHelpCannotMakeUnreadChildrenAbsent() async throws {
        let fixture = Fixture(showing: false)
        let group = fixture.builder.element(969_043)
        fixture.builder.setRole(group, kAXGroupRole as String)
        fixture.extraWindowChildren = [group]
        fixture.updateVisibility()
        fixture.failedMetadata = (group, kAXHelpAttribute as String)
        fixture.failedMetadataError = .notImplemented
        fixture.unreadNestedGroup = group
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "C")
        #expect(fixture.events.isEmpty)
        #expect(!fixture.showing)
    }

    @Test(arguments: [kAXDescriptionAttribute as String, kAXTitleAttribute as String])
    func unreadCandidateTextCannotInventStripsInAnObservedNonStripContainer(attribute: String) async throws {
        let fixture = Fixture(showing: false)
        let scroll = fixture.builder.element(969_045)
        let layout = fixture.builder.element(969_046)
        let bar = fixture.builder.element(969_047)
        fixture.builder.setRole(scroll, kAXScrollAreaRole as String)
        fixture.builder.setRole(layout, kAXLayoutAreaRole as String)
        fixture.builder.setRole(bar, kAXScrollBarRole as String)
        fixture.builder.setChildren(layout, [])
        fixture.builder.setChildren(bar, [])
        fixture.builder.setChildren(scroll, [layout, bar])
        fixture.extraWindowChildren = [scroll]
        fixture.updateVisibility()
        fixture.failedMetadata = (scroll, attribute)
        fixture.failedMetadataError = .failure
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "A")
        #expect(fixture.events == ["open_view", "show_mixer"])
        #expect(fixture.showing)
    }

    @Test(arguments: ["possible_strip", "unknown_role", "unknown_children", "unknown_identifier"])
    func unreadCandidateTextStillRefusesAPossibleOrUnreadMixer(shape: String) async throws {
        let fixture = Fixture(showing: false)
        let scroll = fixture.builder.element(969_048)
        let child = fixture.builder.element(969_049)
        fixture.builder.setRole(scroll, kAXScrollAreaRole as String)
        if shape != "unknown_role" {
            fixture.builder.setRole(child, shape == "possible_strip" ? kAXLayoutItemRole as String : kAXLayoutAreaRole as String)
        }
        fixture.builder.setChildren(child, [])
        fixture.builder.setChildren(scroll, [child])
        fixture.extraWindowChildren = [scroll]
        fixture.updateVisibility()
        fixture.failedMetadata = (scroll, shape == "unknown_identifier" ? kAXIdentifierAttribute as String : kAXDescriptionAttribute as String)
        fixture.failedMetadataError = .failure
        if shape == "unknown_children" { fixture.unreadNestedGroup = scroll }
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "C")
        #expect(fixture.events.isEmpty)
        #expect(!fixture.showing)
    }

    @Test func aDecidingStripRoleCannotBeErasedByAnEarlierNonStripProbe() {
        let fixture = Fixture(showing: false)
        let scroll = fixture.builder.element(969_052)
        let child = fixture.builder.element(969_053)
        fixture.builder.setRole(scroll, kAXScrollAreaRole as String)
        fixture.builder.setChildren(scroll, [child])
        fixture.builder.setChildren(child, [])
        fixture.builder.setChildren(fixture.window, [fixture.rail, scroll])
        let ax = fixture.builder.makeAXRuntime(appElement: fixture.app,
            attributeValueHandler: { [fixture] element, attribute in
                if CFEqual(element, child), attribute == kAXRoleAttribute as String {
                    fixture.structuralRoleSamples.append("ordinary_non_strip")
                    return .some(kAXLayoutAreaRole as NSString)
                }
                return nil
            }, attributeValueResultHandler: { [fixture] element, attribute in
                if CFEqual(element, scroll), attribute == kAXDescriptionAttribute as String {
                    return .failure(.init(raw: Int32(AXError.failure.rawValue)))
                }
                if CFEqual(element, child), attribute == kAXRoleAttribute as String {
                    fixture.structuralRoleSamples.append("deciding_strip")
                    return .success(kAXLayoutItemRole as NSString)
                }
                return nil
            }, setAttributeHandler: { _, _, _ in Issue.record("AX setter forbidden"); return false },
            performActionHandler: { _, _ in Issue.record("AX action forbidden"); return false },
            executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") })
        let runtime = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("global Escape forbidden") },
            focusedApplicationPID: { 4242 })
        let lookup = AXLogicProElements.mixerAreaLookup(in: fixture.window,
            runtime: runtime, requiresCompleteAbsence: true)
        #expect(fixture.structuralRoleSamples.contains("deciding_strip"))
        if case .childrenUnread = lookup {} else {
            Issue.record("a sampled direct strip under unread candidate text cannot certify Mixer absence")
        }
        #expect(fixture.events.isEmpty)
    }

    @Test func readableRootInspectorContextStillExcludesItsMixer() {
        let fixture = Fixture(showing: true)
        fixture.builder.setAttribute(fixture.window, kAXHelpAttribute as String, "Inspector")
        let runtime = AXLogicProElements.Runtime(logicProPID: { 4242 },
            ax: fixture.builder.makeAXRuntime(appElement: fixture.app),
            executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("global Escape forbidden") },
            focusedApplicationPID: { 4242 })
        let lookup = AXLogicProElements.mixerAreaLookup(in: fixture.window,
            runtime: runtime, requiresCompleteAbsence: true)
        if case .notFound = lookup {} else { Issue.record("readable Inspector context must remain excluded") }
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [(false, true), (true, false), (false, false), (true, true)])
    func registeredSetterLeavesTheRequestedFinalState(initial: Bool, desired: Bool) async throws {
        let fixture = Fixture(showing: initial)
        let body = try await set(fixture, visible: desired)
        #expect(body["state"] as? String == "A")
        let verified = try #require(body["verified"] as? Bool)
        #expect(verified)
        let before = try #require(body["before_visible"] as? Bool)
        if initial { #expect(before) } else { #expect(!before) }
        let after = try #require(body["after_visible"] as? Bool)
        if desired { #expect(after); #expect(fixture.showing) }
        else { #expect(!after); #expect(!fixture.showing) }
        #expect(fixture.events == (initial == desired ? [] : ["open_view", desired ? "show_mixer" : "hide_mixer"]))
        let menuSelected = try #require(fixture.builder.attributeValue(fixture.view, kAXSelectedAttribute as String) as? Bool)
        #expect(!menuSelected)
        fixture.events.removeAll()
        let repeated = try await set(fixture, visible: desired)
        #expect(repeated["state"] as? String == "A")
        let repeatedAfter = try #require(repeated["after_visible"] as? Bool)
        if desired { #expect(repeatedAfter) } else { #expect(!repeatedAfter) }
        #expect(fixture.events.isEmpty, "repeating the desired state sends no AX events")
    }

    @Test("the own dynamic Mixer action keeps its shipped French direction", arguments: [false, true])
    func frenchMixerDirectionsReachTheRegisteredSetter(desired: Bool) async throws {
        let fixture = Fixture(showing: !desired)
        fixture.attributeReadObserver = { [fixture] element, attribute in
            if CFEqual(element, fixture.toggle), attribute == kAXTitleAttribute as String {
                fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String,
                    fixture.showing ? "Masquer la table de mixage" : "Afficher la table de mixage")
            }
        }
        // Independent MAMobileGeneralUI Show/Hide Mixer values, matched to the
        // archived dynamic EN/KO actions. This injected menu is not native French qualification.
        let body = try await set(fixture, visible: desired)
        #expect(body["state"] as? String == "A")
        let verified = try #require(body["verified"] as? Bool)
        #expect(verified)
        if desired { #expect(fixture.showing) } else { #expect(!fixture.showing) }
        #expect(fixture.events == ["open_view", desired ? "show_mixer" : "hide_mixer"])
    }

    @Test("a translated contradictory Mixer direction cannot authorize the leaf", arguments: [false, true])
    func contradictoryFrenchMixerDirectionsNeverPress(initial: Bool) async throws {
        let fixture = Fixture(showing: initial)
        fixture.attributeReadObserver = { [fixture] element, attribute in
            if CFEqual(element, fixture.toggle), attribute == kAXTitleAttribute as String {
                fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String,
                    fixture.showing ? "Afficher la table de mixage" : "Masquer la table de mixage")
            }
        }
        let body = try await set(fixture, visible: !initial)
        #expect(body["state"] as? String != "A")
        if initial { #expect(fixture.showing) } else { #expect(!fixture.showing) }
        #expect(!fixture.events.contains("show_mixer"))
        #expect(!fixture.events.contains("hide_mixer"))
    }

    @Test func visibilityIsAnOptionalRegistryBooleanWithoutAddingAPublicAlias() throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_navigate", command: "toggle_view"))
        #expect(spec.allowedParams.contains("visible"))
        let contract = try #require(OperationRegistry.parameterContracts[spec.id])
        #expect(contract.params["visible"]?.kind == .boolean)
        #expect(!contract.required.contains(["visible"]))
        #expect(LogicProServer.strictParamValidationResult(tool: "logic_navigate", command: "toggle_view",
            params: ["view": .string("mixer"), "visible": .bool(true)]) == nil)
    }

    @Test func aKnownOppositeEnglishMenuDirectionCannotAuthorizeTheLeaf() async throws {
        let fixture = Fixture(showing: true)
        fixture.contradictoryShow = true
        fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String, "Show Mixer")
        let body = try await set(fixture, visible: false)
        #expect(body["state"] as? String != "A")
        #expect(fixture.events == ["open_view", "cancel_view"])
        #expect(fixture.showing)
    }

    @Test func finalStateIsReadAgainAfterOwnedMenuCleanup() async throws {
        let fixture = Fixture(showing: false)
        fixture.leafLeavesMenuOpen = true
        fixture.afterCancel = {
            fixture.showing = false
            fixture.updateVisibility()
        }
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "B")
        let after = try #require(body["after_visible"] as? Bool)
        #expect(!after)
        #expect(fixture.events == ["open_view", "show_mixer", "cancel_view"])
        #expect(!fixture.showing)
    }

    @Test func unknownVisibilityIsNotHiddenAndSendsNoActions() async throws {
        let fixture = Fixture(showing: false)
        fixture.unknownWindowChildren = true
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "C")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(fixture.events.isEmpty)
    }

    @Test func ownershipLossInsideTheDecidingMixerReadStopsTheLeaf() async throws {
        let fixture = Fixture(showing: true)
        let otherWindow = fixture.builder.element(969_008)
        fixture.afterDecisiveMixerRead = {
            fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, otherWindow)
        }
        let body = try await set(fixture, visible: false)
        #expect(body["state"] as? String == "B")
        #expect(fixture.events == ["open_view"])
        #expect(fixture.showing)
        #expect(fixture.afterDecisiveMixerRead == nil)
    }

    @Test(arguments: [true, false])
    func aFalseLeafAcknowledgementIsJudgedByActualFinalReadback(effect: Bool) async throws {
        let fixture = Fixture(showing: false)
        fixture.leafAcknowledged = false
        fixture.leafChangesVisibility = effect
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == (effect ? "A" : "B"))
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(attempted)
        if effect { #expect(fixture.showing) } else { #expect(!fixture.showing) }
        #expect(fixture.events == ["open_view", effect ? "show_mixer" : "hide_mixer"])
    }

    @Test(arguments: ["piano_roll", "score", "step_editor", "library", "inspector", "automation"])
    func explicitVisibilityForOtherViewsIsRejectedWithoutRouting(view: String) async throws {
        let fixture = Fixture(showing: false)
        let body = try await set(fixture, visible: true, view: view)
        #expect(body["state"] as? String == "C")
        #expect(fixture.events.isEmpty)
    }

    @Test func aStringBooleanIsNotAnExplicitFinalState() async throws {
        let fixture = Fixture(showing: false)
        let body = try await set(fixture, visible: true, rawVisible: .string("true"))
        #expect(body["state"] as? String == "C")
        #expect(fixture.events.isEmpty)
    }

    @Test func attemptedRefusalRetainsTheStableStateBReason() async throws {
        let fixture = Fixture(showing: false)
        fixture.leafAcknowledged = false
        fixture.leafChangesVisibility = false
        let channel = fixture.channel()
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { true },
                                            deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        let result = await OperationTraceContext.$current.withValue(context) {
            await channel.execute(operation: "view.set_mixer_visibility", params: ["visible": "true"])
        }
        let message: String
        switch result { case .success(let value), .error(let value): message = value }
        let body = try #require(sharedJSONObject(message))
        #expect(body["state"] as? String == "B")
        #expect(body["reason"] as? String == "readback_unavailable")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(attempted)
    }

    @Test func theActualExplicitStateAHasACoveredReceiptOracle() async throws {
        let body = try await set(Fixture(showing: false), visible: true)
        #expect(body["state"] as? String == "A")
        #expect(SemanticOracleTable.postClosureMutatingOperationIDs.contains(.navigateToggleView))
        #expect(SemanticOracleTable.structurallyUnverifiedMutatingOperationIDs[.navigateToggleView] == nil)
        let oracle = try #require(SemanticOracleTable.byOperationID[.navigateToggleView])
        let data = try JSONSerialization.data(withJSONObject: body)
        let passed = try #require(oracle.evaluate(responseData: data, readbackData: Data("{}".utf8)))
        #expect(passed)
        for (key, replacement) in [
            ("operation", "view.toggle_mixer" as Any), ("visibility_source", "key_command" as Any),
            ("after_visible", false as Any), ("menu_restored", false as Any),
            ("state", "B" as Any), ("verified", false as Any),
        ] {
            var mutant = body
            mutant[key] = replacement
            let accepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: mutant), readbackData: Data("{}".utf8)))
            #expect(!accepted, "receipt corruption at \(key) must be refused")
        }
    }

    @Test func cleanupAcknowledgementWithoutObservedClosureIsNotStateA() async throws {
        let fixture = Fixture(showing: false)
        fixture.leafLeavesMenuOpen = true
        fixture.cancelLeavesMenuOpen = true
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "B")
        let restored = try #require(body["menu_restored"] as? Bool)
        #expect(!restored)
        #expect(fixture.showing)
        #expect(fixture.events == ["open_view", "show_mixer", "cancel_view"])
    }

    @Test func documentLossAtCleanupActionNamesCannotCancelTheUnownedMenu() async throws {
        let fixture = Fixture(showing: false)
        fixture.leafLeavesMenuOpen = true
        fixture.afterCleanupActionNames = {
            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
        }
        let body = try await set(fixture, visible: true)
        #expect(fixture.afterCleanupActionNames == nil, "the final successful cleanup action-names read must execute the interference")
        #expect(body["state"] as? String == "B")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(attempted)
        let restored = try #require(body["menu_restored"] as? Bool)
        #expect(!restored)
        #expect(fixture.events == ["open_view", "show_mixer"])
        let selected = try #require(fixture.builder.attributeValue(fixture.view, kAXSelectedAttribute as String) as? Bool)
        #expect(selected)
        #expect(fixture.showing)
    }

    @Test func aSameLabelMixerReplacementDuringCleanupDoesNotVerifyTheHeldMixer() async throws {
        let fixture = Fixture(showing: false)
        fixture.leafLeavesMenuOpen = true
        fixture.afterCancel = {
            let replacement = fixture.builder.element(969_020)
            fixture.builder.setRole(replacement, kAXGroupRole as String)
            fixture.builder.setAttribute(replacement, kAXIdentifierAttribute as String, "Mixer")
            fixture.builder.setChildren(replacement, [])
            fixture.builder.setChildren(fixture.window, [fixture.rail, replacement])
        }
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "B")
        #expect(body["after_visible"] == nil)
        #expect(fixture.events == ["open_view", "show_mixer", "cancel_view"])
    }

    @Test(arguments: ["gate", "cancel", "document"])
    func lossAtTheDecidingMixerReadCannotPressOrCleanUpAnotherOwnersMenu(loss: String) async throws {
        let fixture = Fixture(showing: true)
        fixture.afterDecisiveMixerRead = {
            switch loss {
            case "gate": fixture.gateOwned = false
            case "cancel": fixture.cancelled = true
            default: fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
            }
        }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { fixture.gateOwned },
                                           cancellationRequested: { fixture.cancelled })
        let body = try await set(fixture, visible: false, context: context)
        #expect(body["state"] as? String == "B")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(attempted)
        let restored = try #require(body["menu_restored"] as? Bool)
        #expect(!restored)
        #expect(fixture.events == ["open_view"])
        #expect(fixture.showing)
        #expect(fixture.afterDecisiveMixerRead == nil)
    }

    @Test func anExpiredOwnedContextSendsNoAction() async throws {
        let fixture = Fixture(showing: false)
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { true }, deadline: ContinuousClock.now)
        let body = try await set(fixture, visible: true, context: context)
        #expect(body["state"] as? String == "C")
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [(false, true), (true, false), (false, false), (true, true)])
    func everyFinalStateEnvelopeHasAnExplicitBooleanAttemptReceipt(initial: Bool, desired: Bool) async throws {
        let body = try await set(Fixture(showing: initial), visible: desired)
        #expect(body["state"] as? String == "A")
        let attempted = try #require(body["write_attempted"] as? Bool)
        if initial != desired { #expect(attempted) } else { #expect(!attempted) }
        let oracle = try #require(SemanticOracleTable.byOperationID[.navigateToggleView])
        let readback = Data("{}".utf8)
        let accepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: body), readbackData: readback))
        #expect(accepted)
        var missing = body
        missing.removeValue(forKey: "write_attempted")
        let missingAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: missing), readbackData: readback))
        #expect(!missingAccepted)
        var numeric = body
        numeric["write_attempted"] = 1
        let numericAccepted = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: numeric), readbackData: readback))
        #expect(!numericAccepted)
    }

    @Test(arguments: ["trimmed", "uppercase", "description_only"])
    func acceptedShowDirectionFormsCannotAuthorizeAnExplicitHide(form: String) async throws {
        let fixture = Fixture(showing: true)
        fixture.contradictoryShow = true
        switch form {
        case "trimmed": fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String, " show mixer ")
        case "uppercase": fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String, "SHOW MIXER")
        default:
            fixture.builder.removeAttribute(fixture.toggle, kAXTitleAttribute as String)
            fixture.builder.setAttribute(fixture.toggle, kAXDescriptionAttribute as String, AXLocalePolicy.showMixerMenuItem.canonical)
        }
        let body = try await set(fixture, visible: false)
        #expect(body["state"] as? String != "A")
        #expect(fixture.events == ["open_view", "cancel_view"])
        #expect(fixture.showing)
    }

    @Test(arguments: ["focus", "window", "pid", "app", "healthy"])
    func cleanupActionNamesCannotSubstituteRetainedAuthority(loss: String) async throws {
        let fixture = Fixture(showing: false)
        fixture.leafLeavesMenuOpen = true
        fixture.afterCleanupActionNames = {
            switch loss {
            case "focus":
                let foreignFocus = fixture.builder.element(969_031)
                fixture.builder.setRole(foreignFocus, kAXListRole as String)
                fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, foreignFocus)
            case "window": fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.builder.element(969_032))
            case "pid": fixture.logicPID = 4243
            case "app":
                let otherApp = fixture.builder.element(969_033)
                fixture.builder.setAttribute(otherApp, kAXFrontmostAttribute as String, true)
                fixture.builder.setAttribute(otherApp, kAXMainWindowAttribute as String, fixture.window)
                fixture.builder.setAttribute(otherApp, kAXFocusedWindowAttribute as String, fixture.window)
                fixture.builder.setAttribute(otherApp, kAXFocusedUIElementAttribute as String, fixture.rail)
                fixture.currentApp = otherApp
            default: break
            }
        }
        let body = try await set(fixture, visible: true)
        #expect(fixture.afterCleanupActionNames == nil)
        #expect(body["state"] as? String == (loss == "healthy" ? "A" : "B"))
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(attempted)
        #expect(fixture.events == (loss == "healthy" ? ["open_view", "show_mixer", "cancel_view"] : ["open_view", "show_mixer"]))
        let selected = try #require(fixture.builder.attributeValue(fixture.view, kAXSelectedAttribute as String) as? Bool)
        if loss == "healthy" { #expect(!selected) } else { #expect(selected) }
    }

    @Test(arguments: ["gate", "cancel", "deadline", "healthy"])
    func theLastFinalFocusReadCannotPublishAfterAuthorityLoss(loss: String) async throws {
        let fixture = Fixture(showing: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        fixture.afterFinalFocusRead = {
            switch loss {
            case "gate": fixture.gateOwned = false
            case "cancel": fixture.cancelled = true
            case "deadline":
                // Model a successful AX read that returns only after the operation's
                // actual monotonic deadline. This is not a latency/SLA assertion.
                while ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
            default: break
            }
        }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: {
            // The final lookup's second retained-Mixer ID read is followed by owned():
            // its two stop focus reads, ownedMenuFocus, and last stop focus read. Arm
            // only after its trailing gate corroboration, so the next read is the
            // final standalone sameFocus(), not an earlier deciding guard.
            if fixture.finalMixerReads == 2, fixture.finalFocusReads == 4 {
                fixture.finalFocusArmed = true
            }
            return fixture.gateOwned
        }, deadline: deadline, cancellationRequested: { fixture.cancelled })
        let body = try await set(fixture, visible: true, context: context)
        #expect(fixture.afterFinalFocusRead == nil)
        #expect(fixture.focusReadAtLoss == 5)
        if loss == "gate" { #expect(!fixture.gateOwned) }
        if loss == "cancel" { #expect(fixture.cancelled) }
        if loss == "deadline" { #expect(ContinuousClock.now >= deadline) }
        #expect(body["state"] as? String == (loss == "healthy" ? "A" : "B"))
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(attempted)
        #expect(fixture.events == ["open_view", "show_mixer"])
    }

    @Test(arguments: [true, false])
    func anUnreadUnnamedSubtreeDoesNotProveMixerAbsence(unread: Bool) async throws {
        let fixture = Fixture(showing: false)
        let group = fixture.builder.element(969_040)
        fixture.builder.setRole(group, kAXGroupRole as String)
        fixture.builder.setChildren(group, [])
        fixture.builder.setChildren(fixture.window, [fixture.rail, group])
        if unread { fixture.unreadNestedGroup = group }
        let body = try await set(fixture, visible: false)
        #expect(body["state"] as? String == (unread ? "C" : "A"))
        if unread { #expect(body["before_visible"] == nil) }
        else {
            let before = try #require(body["before_visible"] as? Bool)
            #expect(!before)
        }
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: ["role", "identifier", "description", "title", "malformed_help", "depth", "cycle", "node_budget", "visible"])
    func incompleteMixerDiscoveryCannotProveAbsence(shape: String) async throws {
        let fixture = Fixture(showing: shape == "visible")
        let group = fixture.builder.element(969_050)
        fixture.builder.setRole(group, kAXGroupRole as String)
        fixture.builder.setChildren(group, [])
        fixture.builder.setChildren(fixture.window, fixture.showing ? [fixture.rail, fixture.mixer, group] : [fixture.rail, group])
        switch shape {
        case "depth":
            var parent = group
            for index in 0..<13 {
                let child = fixture.builder.element(970_000 + index)
                fixture.builder.setRole(child, kAXGroupRole as String)
                fixture.builder.setChildren(child, [])
                fixture.builder.setChildren(parent, [child])
                parent = child
            }
            fixture.builder.setChildren(parent, [fixture.mixer])
        case "cycle": fixture.builder.setChildren(group, [group])
        case "node_budget":
            let children = (0..<4096).map { index in
                let child = fixture.builder.element(980_000 + index)
                fixture.builder.setRole(child, kAXGroupRole as String)
                fixture.builder.setChildren(child, [])
                return child
            }
            fixture.builder.setChildren(group, children)
        case "visible": fixture.unreadNestedGroup = group
        case "malformed_help": fixture.builder.setAttribute(group, kAXHelpAttribute as String, 42)
        default:
            if shape == "description" || shape == "title" {
                let strip = fixture.builder.element(969_051)
                fixture.builder.setRole(strip, kAXLayoutItemRole as String)
                fixture.builder.setChildren(strip, [])
                fixture.builder.setChildren(group, [strip])
            }
            let attributes = ["role": kAXRoleAttribute as String, "identifier": kAXIdentifierAttribute as String,
                              "description": kAXDescriptionAttribute as String, "title": kAXTitleAttribute as String]
            fixture.failedMetadata = (group, try #require(attributes[shape]))
        }
        let body = try await set(fixture, visible: fixture.showing)
        #expect(body["state"] as? String == (fixture.showing ? "A" : "C"))
        if !fixture.showing { #expect(body["before_visible"] == nil) }
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: [true, false])
    func containerHelpCensusStillVisitsMixerChildren(readableInspector: Bool) {
        let fixture = Fixture(showing: false)
        let group = fixture.builder.element(969_044)
        fixture.builder.setRole(group, kAXGroupRole as String)
        fixture.builder.setChildren(group, [fixture.mixer])
        fixture.builder.setChildren(fixture.window, [fixture.rail, group])
        if readableInspector { fixture.builder.setAttribute(group, kAXHelpAttribute as String, "Inspector") }
        let ax = fixture.builder.makeAXRuntime(appElement: fixture.app,
            attributeValueResultHandler: { element, attribute in
                if !readableInspector, CFEqual(element, group), attribute == kAXHelpAttribute as String {
                    return .failure(.init(raw: Int32(AXError.notImplemented.rawValue)))
                }
                return nil
            }, setAttributeHandler: { _, _, _ in Issue.record("AX setter forbidden"); return false },
            performActionHandler: { _, _ in Issue.record("AX action forbidden"); return false },
            executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") })
        let runtime = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("global Escape forbidden") },
            focusedApplicationPID: { 4242 })
        let lookup = AXLogicProElements.mixerAreaLookup(in: fixture.window,
            runtime: runtime, requiresCompleteAbsence: true)
        if readableInspector {
            if case .notFound = lookup {} else { Issue.record("readable Inspector context must exclude its Mixer") }
        } else {
            if case .found(let observed) = lookup { #expect(CFEqual(observed, fixture.mixer)) }
            else { Issue.record("unread Help must not skip a Mixer descendant") }
        }
        #expect(fixture.events.isEmpty)
    }

    @Test(arguments: ["canonical", "trimmed", "uppercase", "description_only"])
    func acceptedHideDirectionFormsCannotAuthorizeAnExplicitShow(form: String) async throws {
        let fixture = Fixture(showing: false)
        fixture.contradictoryHide = true
        switch form {
        case "trimmed": fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String, " hide mixer ")
        case "uppercase": fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String, "HIDE MIXER")
        case "description_only":
            fixture.builder.removeAttribute(fixture.toggle, kAXTitleAttribute as String)
            fixture.builder.setAttribute(fixture.toggle, kAXDescriptionAttribute as String, "Hide Mixer")
        default: fixture.builder.setAttribute(fixture.toggle, kAXTitleAttribute as String, "Hide Mixer")
        }
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String != "A")
        #expect(fixture.events == ["open_view", "cancel_view"])
        #expect(!fixture.showing)
    }

    @Test func unknownAbsenceCannotAuthorizeAnExplicitShow() async throws {
        let fixture = Fixture(showing: false)
        let group = fixture.builder.element(969_041)
        fixture.builder.setRole(group, kAXGroupRole as String)
        fixture.builder.setChildren(group, [])
        fixture.builder.setChildren(fixture.window, [fixture.rail, group])
        fixture.unreadNestedGroup = group
        let body = try await set(fixture, visible: true)
        #expect(body["state"] as? String == "C")
        #expect(body["before_visible"] == nil)
        #expect(fixture.events.isEmpty)
        #expect(!fixture.showing)
    }
}
