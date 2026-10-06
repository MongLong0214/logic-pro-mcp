@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#965 bound Mixer presentation witnesses", .serialized)
struct Issue965MixerPresentationWitnessTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }
    private final class StopRead: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var later = 0
        func observe(stop: Bool) { lock.withLock { if stopped { later += 1 }; if stop { stopped = true } } }
        var isStopped: Bool { lock.withLock { stopped } }
        var laterReads: Int { lock.withLock { later } }
    }

    private struct Fixture {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let owner: AXUIElement
        let toolbar: AXUIElement
        let modes: AXUIElement
        let filters: AXUIElement
        let layout: AXUIElement
        let modeControls: [AXUIElement]
        let filterControls: [AXUIElement]

        init(korean: Bool = false) {
            app = builder.element(965_950)
            window = builder.element(965_951)
            owner = builder.element(965_952)
            toolbar = builder.element(965_953)
            modes = builder.element(965_954)
            filters = builder.element(965_955)
            layout = builder.element(965_956)
            let elements = builder
            modeControls = (0..<3).map { elements.element(965_960 + $0) }
            filterControls = (0..<8).map { elements.element(965_970 + $0) }
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Session - Tracks")
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            for node in [owner, toolbar] {
                builder.setRole(node, kAXGroupRole as String)
                builder.setAttribute(node, kAXDescriptionAttribute as String, korean ? "믹서" : "Mixer")
            }
            builder.setRole(modes, kAXRadioGroupRole as String)
            builder.setRole(filters, kAXGroupRole as String)
            builder.setRole(layout, "AXLayoutArea")
            builder.setAttribute(layout, kAXDescriptionAttribute as String, korean ? "믹서" : "Mixer")
            let modeNames = korean ? ["단일", "트랙", "모두"] : ["Single", "Tracks", "All"]
            let filterNames = korean
                ? ["오디오", "악기", "Aux", "버스", "입력", "출력", "마스터/VCA", "MIDI"]
                : ["Audio", "Inst", "Aux", "Bus", "Input", "Output", "Master/VCA", "MIDI"]
            for (index, node) in modeControls.enumerated() {
                builder.setRole(node, kAXRadioButtonRole as String)
                builder.setAttribute(node, kAXDescriptionAttribute as String, modeNames[index])
                builder.setAttribute(node, kAXValueAttribute as String, index == 2 ? 1 : 0)
                builder.setChildren(node, [])
            }
            for (index, node) in filterControls.enumerated() {
                builder.setRole(node, kAXCheckBoxRole as String)
                builder.setAttribute(node, kAXDescriptionAttribute as String, filterNames[index])
                builder.setAttribute(node, kAXValueAttribute as String, 1)
                builder.setChildren(node, [])
            }
            builder.setChildren(modes, modeControls)
            builder.setChildren(filters, filterControls)
            builder.setChildren(toolbar, [modes, filters])
            let strip = builder.element(965_980)
            builder.setRole(strip, kAXLayoutItemRole as String)
            builder.setChildren(strip, [])
            builder.setChildren(layout, [strip])
            builder.setChildren(owner, [toolbar, layout])
            builder.setChildren(window, [owner])
        }
    }

    private func inspect(
        _ fixture: Fixture,
        attributes: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?)? = nil,
        rawAttributes: (@Sendable (AXUIElement, String) -> AnyObject??)? = nil,
        children: (@Sendable (AXUIElement) -> Result<[AXUIElement], AXHelpers.AXStatusError>?)? = nil,
        keyboardFocus: @escaping @Sendable () -> AccessibilityChannel.LogicKeyboardFocus = { .notTextEditing },
        gate: LogicMutationGate = LogicMutationGate(),
        expectSuccess: Bool = true
    ) async throws -> [String: Any] {
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
            logicRuntime: fixture.builder.makeLogicRuntime(
                appElement: fixture.app, attributeValueHandler: rawAttributes,
                attributeValueResultHandler: attributes,
                childrenResultHandler: children,
                setAttributeHandler: nil, performActionHandler: nil,
                executeAppleScript: { _ in .error("fixture forbids AppleScript") }
            )
        ))
        let cache = StateCache()
        let dependencies = HandlerDependencies(
            router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
            poller: StatePoller(axChannel: channel, cache: cache,
                               runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable,
                                              keyboardFocus: keyboardFocus)),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable
        )
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array([.string("strips")])]
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_project", command: "inspect_session", commandParams: params, mutationGate: gate
        ) { await handler(dependencies, params) }
        let isError = result.isError ?? false
        if expectSuccess { #expect(!isError) }
        else { #expect(isError) }
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test(arguments: [false, true])
    func ownAllAndEightEnabledFiltersAreReportedWithoutWholeCoverage(korean: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let body = try await inspect(Fixture(korean: korean))
            let strips = try #require(body["strips"] as? [String: Any])
            #expect(strips["coverage"] as? String == "partial")
            let reasons = try #require(strips["reasons"] as? [String])
            #expect(reasons.contains("count_is_the_only_end_witness"))
            #expect(!reasons.contains("mixer_filters_unread"))
            let witnesses = try #require(strips["witnesses"] as? [String: Any])
            let presentation = try #require(witnesses["presentation"] as? [String: Any])
            #expect(presentation["mode"] as? String == "all")
            let filters = try #require(presentation["type_filters"] as? [String: Bool])
            #expect(filters.count == 8 && filters.values.allSatisfy { $0 })
        }
    }

    @Test func sameStripCountDoesNotHideFilterDrift() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let counter = Counter()
            let body = try await inspect(fixture, attributes: { element, attribute in
                guard CFEqual(element, fixture.filterControls[0]), attribute == kAXValueAttribute as String else { return nil }
                return .success(NSNumber(value: counter.next() % 2))
            })
            let strips = try #require(body["strips"] as? [String: Any])
            #expect(strips["coverage"] as? String == "unstable")
            let reasons = try #require(strips["reasons"] as? [String])
            #expect(reasons.contains("live_population_moved"))
        }
    }

    @Test(arguments: ["tracks", "disabled_type"])
    func knownRestrictedPresentationReportsFilteringNotAnUnreadFilter(restriction: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            if restriction == "tracks" {
                fixture.builder.setAttribute(fixture.modeControls[2], kAXValueAttribute as String, 0)
                fixture.builder.setAttribute(fixture.modeControls[1], kAXValueAttribute as String, 1)
            } else { fixture.builder.setAttribute(fixture.filterControls[0], kAXValueAttribute as String, 0) }
            let body = try await inspect(fixture)
            let strips = try #require(body["strips"] as? [String: Any])
            #expect(strips["coverage"] as? String == "partial")
            let reasons = try #require(strips["reasons"] as? [String])
            #expect(reasons.contains("mixer_presentation_filtered"))
            #expect(reasons.contains("count_is_the_only_end_witness"))
            #expect(!reasons.contains("mixer_filters_unread"))
        }
    }

    @Test(arguments: ["missing", "duplicate", "wrong_role", "nonbinary", "string_value", "two_selected", "wrong_sibling"])
    func invalidModeAuthorityStaysUnknown(defect: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            switch defect {
            case "missing": fixture.builder.setChildren(fixture.modes, Array(fixture.modeControls.dropLast()))
            case "duplicate": fixture.builder.setChildren(fixture.modes, fixture.modeControls + [fixture.modeControls[0]])
            case "wrong_role": fixture.builder.setRole(fixture.modeControls[0], kAXCheckBoxRole as String)
            case "nonbinary": fixture.builder.setAttribute(fixture.modeControls[2], kAXValueAttribute as String, 0.9)
            case "string_value": fixture.builder.setAttribute(fixture.modeControls[2], kAXValueAttribute as String, "1")
            case "two_selected": fixture.builder.setAttribute(fixture.modeControls[0], kAXValueAttribute as String, 1)
            default:
                fixture.builder.setChildren(fixture.toolbar, [fixture.filters])
                fixture.builder.setChildren(fixture.window, [fixture.owner, fixture.modes])
            }
            let presentation = try await presentation(inspect(fixture))
            #expect(presentation["mode"] is NSNull)
        }
    }

    @Test(arguments: ["missing", "duplicate", "wrong_role", "wrong_sibling", "cycle", "duplicate_toolbar"])
    func invalidFilterAuthorityStaysUnknown(defect: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            switch defect {
            case "missing": fixture.builder.setChildren(fixture.filters, Array(fixture.filterControls.dropLast()))
            case "duplicate": fixture.builder.setChildren(fixture.filters, fixture.filterControls + [fixture.filterControls[0]])
            case "wrong_role": fixture.builder.setRole(fixture.filterControls[0], kAXRadioButtonRole as String)
            case "cycle": fixture.builder.setChildren(fixture.filters, fixture.filterControls + [fixture.filters])
            case "duplicate_toolbar":
                let decoy = fixture.builder.element(965_990)
                fixture.builder.setRole(decoy, kAXGroupRole as String)
                fixture.builder.setAttribute(decoy, kAXDescriptionAttribute as String, "Mixer")
                fixture.builder.setChildren(decoy, [])
                fixture.builder.setChildren(fixture.owner, [fixture.toolbar, fixture.layout, decoy])
            default:
                fixture.builder.setChildren(fixture.toolbar, [fixture.modes])
                fixture.builder.setChildren(fixture.window, [fixture.owner, fixture.filters])
            }
            let observed = try await presentation(inspect(fixture))
            let filters = try #require(observed["type_filters"] as? [String: Any])
            #expect(filters.count == 8 && filters.values.allSatisfy { $0 is NSNull })
        }
    }

    @Test(arguments: ["mode_value", "filter_value", "filter_role", "toolbar_children"])
    func unreadableAXStateIsNotEnabled(defect: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let observed = try await presentation(inspect(fixture, attributes: { element, attribute in
                let target = defect == "mode_value" ? fixture.modeControls[2] : fixture.filterControls[0]
                let name = defect == "filter_role" ? kAXRoleAttribute : kAXValueAttribute
                guard CFEqual(element, target), attribute == name else { return nil }
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }, children: { element in
                defect == "toolbar_children" && CFEqual(element, fixture.toolbar)
                    ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
            }))
            if defect == "mode_value" { #expect(observed["mode"] is NSNull) }
            else {
                let filters = try #require(observed["type_filters"] as? [String: Any])
                #expect(filters["audio"] is NSNull)
            }
        }
    }

    @Test func inspectorControlsCannotSupplyMissingOwnFilters() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let inspector = fixture.builder.element(965_991)
            fixture.builder.setRole(inspector, kAXGroupRole as String)
            fixture.builder.setAttribute(inspector, kAXDescriptionAttribute as String, "Inspector")
            fixture.builder.setChildren(inspector, [fixture.filters])
            fixture.builder.setChildren(fixture.toolbar, [fixture.modes])
            fixture.builder.setChildren(fixture.window, [inspector, fixture.owner])
            let observed = try await presentation(inspect(fixture))
            let filters = try #require(observed["type_filters"] as? [String: Any])
            #expect(filters.values.allSatisfy { $0 is NSNull })
            #expect(observed["mode"] as? String == "all")
        }
    }

    @Test(arguments: ["failure", "absent"])
    func unreadPossibleToolbarCompetitorPreventsKnownPresentation(status: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let competitor = fixture.builder.element(965_992)
            fixture.builder.setRole(competitor, kAXGroupRole as String)
            fixture.builder.setChildren(competitor, [])
            fixture.builder.setChildren(fixture.owner, [fixture.toolbar, fixture.layout, competitor])
            let observed = try await presentation(inspect(fixture, attributes: { element, attribute in
                guard CFEqual(element, competitor), attribute == kAXDescriptionAttribute as String else { return nil }
                return status == "failure" ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : .success(nil)
            }))
            #expect(observed["mode"] is NSNull)
            let filters = try #require(observed["type_filters"] as? [String: Any])
            #expect(filters.values.allSatisfy { $0 is NSNull })
        }
    }

    @Test func staleInnerElementCannotBorrowAnOwnersToolbar() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let reads = Counter()
            let observed = try await presentation(inspect(fixture, children: { element in
                guard CFEqual(element, fixture.owner) else { return nil }
                // Each discovery sees the inner area, while its presentation read observes
                // that exact edge gone. Old retained inner reads still return the same strips.
                return .success(reads.next() % 2 == 1 ? [fixture.toolbar, fixture.layout] : [fixture.toolbar])
            }))
            #expect(observed["mode"] is NSNull)
            let filters = try #require(observed["type_filters"] as? [String: Any])
            #expect(filters.values.allSatisfy { $0 is NSNull })
        }
    }

    @Test func cancellationDuringFilterReadStopsLaterControls() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let laterReads = Counter()
            _ = try await inspect(fixture, attributes: { element, attribute in
                if CFEqual(element, fixture.filterControls[0]), attribute == kAXValueAttribute as String {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else if Task.isCancelled { _ = laterReads.next() }
                return nil
            }, expectSuccess: false)
            #expect(laterReads.next() == 1, "no later AX controls may be read after cancellation")
        }
    }

    @Test func cancellationDuringDiscoveryStopsBeforeLaterAXReads() throws {
        enum Stop: Error { case requested }
        let fixture = Fixture()
        let state = StopRead()
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app,
            attributeValueHandler: { element, attribute in
                state.observe(stop: CFEqual(element, fixture.owner) && attribute == kAXRoleAttribute as String)
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )
        do {
            _ = try AXLogicProElements.mixerPopulationAreaLookup(in: fixture.window, runtime: runtime, checking: {
                if state.isStopped { throw Stop.requested }
            })
            Issue.record("discovery did not observe cancellation")
        } catch Stop.requested {}
        #expect(state.laterReads == 0, "legacy ID discovery must share the checked, bounded walk")
    }

    @Test func unnamedInnerWrapperRetainsItsPhysicalOwnerBinding() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let wrapper = fixture.builder.element(965_993)
            fixture.builder.setRole(wrapper, kAXGroupRole as String)
            fixture.builder.setAttribute(wrapper, kAXDescriptionAttribute as String, "")
            fixture.builder.setChildren(wrapper, [fixture.layout])
            fixture.builder.setChildren(fixture.owner, [fixture.toolbar, wrapper])
            let observed = try await presentation(inspect(fixture))
            #expect(observed["mode"] as? String == "all")
            let filters = try #require(observed["type_filters"] as? [String: Bool])
            #expect(filters.count == 8 && filters.values.allSatisfy { $0 })
        }
    }

    @Test func directModeRadiosDoNotConfuseNarrowWideWithPopulationMode() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture(korean: true)
            let narrow = fixture.builder.element(965_994)
            let wide = fixture.builder.element(965_995)
            // Width labels here are the archived EN native bytes from axdump234.out;
            // this mixed-language fixture tests scope, not native KO width wording.
            for (node, description, value) in [(narrow, "Narrow Channel Strips", 1), (wide, "Wide Channel Strips", 0)] {
                fixture.builder.setRole(node, kAXRadioButtonRole as String)
                fixture.builder.setAttribute(node, kAXDescriptionAttribute as String, description)
                fixture.builder.setAttribute(node, kAXValueAttribute as String, value)
                fixture.builder.setChildren(node, [])
            }
            // Current 12.3 owner toolbar exposes the three mode radios directly. The
            // two width radios also live here, but are not population-mode controls.
            fixture.builder.setChildren(fixture.toolbar, fixture.modeControls + [fixture.filters, narrow, wide])
            let observed = try await presentation(inspect(fixture))
            #expect(observed["mode"] as? String == "all")
            let filters = try #require(observed["type_filters"] as? [String: Bool])
            #expect(filters.count == 8 && filters.values.allSatisfy { $0 })
        }
    }

    @Test(arguments: ["missing", "duplicate", "wrong_role", "unread_description", "cycle"])
    func directModeAuthorityUsesTheSameRefusalRules(defect: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            var controls = fixture.modeControls
            if defect == "missing" { controls.removeLast() }
            if defect == "duplicate" { controls.append(fixture.modeControls[0]) }
            if defect == "wrong_role" { fixture.builder.setRole(fixture.modeControls[0], kAXCheckBoxRole as String) }
            fixture.builder.setChildren(fixture.toolbar, controls + [fixture.filters])
            if defect == "cycle" {
                fixture.builder.setChildren(fixture.toolbar, controls + [fixture.filters, fixture.toolbar])
            }
            let observed = try await presentation(inspect(fixture, attributes: { element, attribute in
                defect == "unread_description" && CFEqual(element, fixture.modeControls[0])
                    && attribute == kAXDescriptionAttribute as String
                    ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
            }))
            #expect(observed["mode"] is NSNull)
        }
    }

    @Test(arguments: [false, true])
    func firstLegacyGroupDoesNotSpendReadBudgetOnTrailingSubtrees(earlierScrollArea: Bool) throws {
        enum Budget: Error { case exhausted }
        let fixture = Fixture()
        let wrapper = fixture.builder.element(965_996)
        let winner = fixture.builder.element(965_997)
        let laterGroup = fixture.builder.element(965_998)
        let tail = fixture.builder.element(965_999)
        let scrollArea = fixture.builder.element(965_990)
        for node in [wrapper, winner, laterGroup, tail] {
            fixture.builder.setRole(node, kAXGroupRole as String)
        }
        for node in [winner, laterGroup, scrollArea] {
            fixture.builder.setAttribute(node, kAXIdentifierAttribute as String, "Mixer")
        }
        fixture.builder.setRole(scrollArea, kAXScrollAreaRole as String)
        fixture.builder.setChildren(scrollArea, [])
        fixture.builder.setChildren(winner, [fixture.layout])
        fixture.builder.setChildren(wrapper, [winner])
        fixture.builder.setChildren(fixture.owner, [wrapper])
        fixture.builder.setChildren(laterGroup, [])
        fixture.builder.setChildren(tail, [])
        fixture.builder.setChildren(fixture.window,
                                    (earlierScrollArea ? [scrollArea] : []) + [fixture.owner, laterGroup, tail])
        let budget = StopRead()
        let trailingReads = Counter()
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app,
            attributeValueHandler: { element, _ in
                if CFEqual(element, laterGroup) || CFEqual(element, tail) {
                    _ = trailingReads.next()
                    budget.observe(stop: true)
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )
        do {
            let result = try AXLogicProElements.mixerPopulationAreaLookup(
                in: fixture.window, runtime: runtime, checking: {
                    // A trailing read consumes the virtual budget. No clock or sleep
                    // participates in this test's acquisition deadline.
                    if budget.isStopped { throw Budget.exhausted }
                }
            )
            let binding = try #require(result.binding)
            #expect(CFEqual(binding.mixer, winner))
            #expect(binding.owners.count == 1 && CFEqual(binding.owners[0], fixture.owner))
            let expectedPath = [fixture.window, fixture.owner, wrapper, winner]
            #expect(binding.path.count == expectedPath.count)
            #expect(zip(binding.path, expectedPath).allSatisfy { CFEqual($0, $1) })
        } catch Budget.exhausted {
            Issue.record("a decisive legacy group must return before spending the trailing read budget")
        }
        #expect(trailingReads.next() == 1, "no later group or unrelated subtree may be read after the first legacy group")
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test func legacyGroupDiscoveryChecksCancellationBeforeItsFirstRead() throws {
        enum Stop: Error { case requested }
        let fixture = Fixture()
        fixture.builder.setAttribute(fixture.owner, kAXIdentifierAttribute as String, "Mixer")
        let reads = Counter()
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app, attributeValueHandler: { _, _ in
                _ = reads.next()
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )
        do {
            _ = try AXLogicProElements.mixerPopulationAreaLookup(
                in: fixture.window, runtime: runtime, checking: { throw Stop.requested }
            )
            Issue.record("discovery must observe cancellation before selecting a legacy group")
        } catch Stop.requested {}
        #expect(reads.next() == 1)
    }

    @Test func registeredProducerDoesNotAmplifyFocusReadsForNonHelpMetadata() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            var readings: [(focus: Int, help: Int)] = []
            for neutralCount in [0, 8] {
                let fixture = Fixture()
                let neutral = (0..<neutralCount).map { fixture.builder.element(966_100 + $0) }
                for node in neutral {
                    fixture.builder.setRole(node, kAXGroupRole as String)
                    fixture.builder.setChildren(node, [])
                }
                fixture.builder.setChildren(fixture.window, [fixture.owner] + neutral)
                let focusReads = Counter()
                let helpReads = Counter()
                let focus = actualFocusReader(fixture, reads: focusReads)
                let observed = try await presentation(inspect(fixture, rawAttributes: { _, attribute in
                    if attribute == kAXHelpAttribute as String { _ = helpReads.next() }
                    return nil
                }, keyboardFocus: focus))
                #expect(observed["mode"] as? String == "all")
                readings.append((focusReads.count, helpReads.count))
            }
            let addedFocusReads = readings[1].focus - readings[0].focus
            let addedHelpReads = readings[1].help - readings[0].help
            #expect(addedHelpReads > 0, "the real producer must traverse the added no-ID nodes")
            #expect(addedFocusReads == addedHelpReads,
                    "additional metadata must retain one focus check per AXHelp, without another focus acquisition before each non-Help read")
        }
    }

    @Test(arguments: ["help", "stage"])
    func registeredProducerKeepsHelpAndStageTextEditingChecks(boundary: String) async throws {
        let fixture = Fixture()
        let edited = StopRead()
        let refused = StopRead()
        let focusReads = Counter()
        let focus = actualFocusReader(fixture, reads: focusReads, editing: {
            let editing = edited.isStopped
            if editing { refused.observe(stop: true) }
            return editing
        })
        let body = try await inspect(fixture, rawAttributes: { element, attribute in
            // Discovery asks for Help after these metadata. Presentation's last
            // checkbox value instead has no Help before the next full stage check.
            let trigger = boundary == "help"
                ? CFEqual(element, fixture.owner) && attribute == kAXIdentifierAttribute as String
                : CFEqual(element, fixture.filterControls[7]) && attribute == kAXValueAttribute as String
            edited.observe(stop: trigger)
            if refused.isStopped { refused.observe(stop: false) }
            return nil
        }, keyboardFocus: focus, expectSuccess: false)
        #expect(edited.isStopped && refused.isStopped)
        #expect(refused.laterReads == 0, "no checked AX read may follow a focus refusal")
        #expect(body["error"] as? String == "readback_unavailable")
        #expect(body["snapshot_id"] == nil)
    }

    @Test(arguments: ["cancel", "ownership"])
    func registeredProducerStopsOnNonHelpLifecycleLoss(loss: String) async throws {
        let fixture = Fixture()
        let neutral = fixture.builder.element(966_120)
        fixture.builder.setRole(neutral, kAXGroupRole as String)
        fixture.builder.setChildren(neutral, [])
        fixture.builder.setChildren(fixture.window, [fixture.owner, neutral])
        let stopped = StopRead()
        let gate = LogicMutationGate()
        let body = try await inspect(fixture, rawAttributes: { element, attribute in
            let trigger = CFEqual(element, neutral) && attribute == kAXIdentifierAttribute as String
            stopped.observe(stop: trigger)
            if trigger {
                if loss == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
                else {
                    _ = gate.tryAcquire(operation: "test.successor", now: .distantFuture)
                }
            }
            return nil
        }, gate: gate, expectSuccess: false)
        #expect(stopped.isStopped)
        #expect(stopped.laterReads == 0, "lifecycle loss must be checked before the next non-Help metadata")
        #expect(body["error"] as? String == (loss == "cancel" ? "cancelled" : "readback_unavailable"))
        #expect(body["snapshot_id"] == nil)
    }

    @Test func omittedPerReadCallbackRetainsGenericStoppingWhenSemantics() async throws {
        let fixture = Fixture()
        let stopped = StopRead()
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app, attributeValueHandler: { element, attribute in
                stopped.observe(stop: CFEqual(element, fixture.owner) && attribute == kAXIdentifierAttribute as String)
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: runtime
        ))
        let context = OperationTraceContext(mutationGateAcquired: true)
        await OperationTraceContext.$current.withValue(context) {
            do {
                _ = try await channel.readFreshSessionPopulation(
                    request: .init(domains: [.strips]), fileReader: .unavailable,
                    stoppingWhen: { stopped.isStopped }
                )
                Issue.record("the generic stop must still be asked before each checked metadata read")
            } catch let error as SessionPopulationObservation.NavigationAcquisitionError {
                switch error.cause {
                case SessionPopulationObservation.AcquisitionError.textEditing: break
                default: Issue.record("unexpected wrapped acquisition error: \(error.cause)")
                }
            } catch {
                Issue.record("unexpected acquisition error: \(error)")
            }
        }
        #expect(stopped.isStopped && stopped.laterReads == 0)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    private func actualFocusReader(
        _ fixture: Fixture, reads: Counter,
        editing: @escaping @Sendable () -> Bool = { false }
    ) -> @Sendable () -> AccessibilityChannel.LogicKeyboardFocus {
        let focused = fixture.builder.element(966_090)
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, focused)
        fixture.builder.setRole(focused, kAXGroupRole as String)
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app, attributeValueHandler: { element, attribute in
                if CFEqual(element, fixture.app), attribute == kAXFocusedUIElementAttribute as String {
                    _ = reads.next()
                }
                if CFEqual(element, focused), attribute == kAXRoleAttribute as String, editing() {
                    return .some(kAXTextFieldRole as NSString)
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )
        return { AccessibilityChannel.readLogicKeyboardFocus(runtime: runtime) }
    }

    private func presentation(_ body: [String: Any]) throws -> [String: Any] {
        let strips = try #require(body["strips"] as? [String: Any])
        #expect(strips["coverage"] as? String == "partial")
        let witnesses = try #require(strips["witnesses"] as? [String: Any])
        return try #require(witnesses["presentation"] as? [String: Any])
    }
}
