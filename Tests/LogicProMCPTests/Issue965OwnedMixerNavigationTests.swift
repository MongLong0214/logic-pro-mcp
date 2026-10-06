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

        func channel() -> AccessibilityChannel {
            let logic = builder.makeLogicRuntime(appElement: app,
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
                    builder.setChildren(window, showing ? [rail, mixer] : [rail])
                    builder.setAttribute(view, kAXSelectedAttribute as String, false)
                    if showing { afterShow?() } else { afterHide?() }
                    return true
                },
                executeAppleScript: { _ in Issue.record("inspection must not invoke AppleScript"); return .error("forbidden") })
            return AccessibilityChannel(runtime: .axBacked(
                isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: logic))
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
