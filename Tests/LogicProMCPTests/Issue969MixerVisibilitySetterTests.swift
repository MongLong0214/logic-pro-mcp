@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#969 explicit final Mixer visibility", .serialized)
struct Issue969MixerVisibilitySetterTests {
    private final class Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let menuBar: AXUIElement
        let view: AXUIElement
        let toggle: AXUIElement
        let mixer: AXUIElement
        var showing: Bool
        var events: [String] = []
        var leafAcknowledged = true
        var leafChangesVisibility = true
        var leafLeavesMenuOpen = false
        var contradictoryShow = false
        var unknownWindowChildren = false
        var cancelLeavesMenuOpen = false
        var gateOwned = true
        var cancelled = false
        var afterCancel: (@Sendable () -> Void)?
        var afterDecisiveMixerRead: (@Sendable () -> Void)?

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
            builder.setChildren(window, showing ? [rail, mixer] : [rail])
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
                attributeValueHandler: { [self] element, attribute in
                    observeDecisiveMixerRead(element, attribute)
                    return nil
                },
                attributeValueResultHandler: { [self] element, attribute in
                    observeDecisiveMixerRead(element, attribute)
                    return nil
                }, childrenResultHandler: { [self] element in
                    if unknownWindowChildren, CFEqual(element, window) {
                        return .failure(.init(raw: Int32(AXError.cannotComplete.rawValue)))
                    }
                    return nil
                },
                setAttributeHandler: { [self] _, _, _ in
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
                        if leafChangesVisibility { showing = contradictoryShow ? true : !showing }
                        events.append(showing ? "show_mixer" : "hide_mixer")
                        updateVisibility()
                        builder.setAttribute(view, kAXSelectedAttribute as String, leafLeavesMenuOpen)
                        return leafAcknowledged
                    }
                    events.append("unexpected_action"); Issue.record("unexpected visibility action"); return false
                }, executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") })
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
                executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
                onScreenWindowList: { [] },
                postPopupMenuEscape: { Issue.record("global Escape forbidden") },
                focusedApplicationPID: { 4242 }, observeFrontmost: nil)
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
}
