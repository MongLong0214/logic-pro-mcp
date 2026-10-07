@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#965 inspect_session reaches fresh population acquisition", .serialized)
struct Issue965FreshPopulationAcquisitionTests {
    private actor SuspendedRead {
        private var entered = false
        private var entryWaiter: CheckedContinuation<Void, Never>?
        private var readWaiter: CheckedContinuation<Void, Never>?
        func suspend() async {
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { readWaiter = $0 }
        }
        func waitForEntry() async {
            if !entered { await withCheckedContinuation { entryWaiter = $0 } }
        }
        func release() { readWaiter?.resume(); readWaiter = nil }
    }

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var attributes: [String] = []
        func record(_ attribute: String) { lock.withLock { attributes.append(attribute) } }
        var count: Int { lock.withLock { attributes.count } }
        var recorded: [String] { lock.withLock { attributes } }
        var helpCount: Int { lock.withLock { attributes.filter { $0 == kAXHelpAttribute as String }.count } }
    }

    private final class StackBookends: @unchecked Sendable {
        private let lock = NSLock()
        private var titleReads = Array(repeating: 0, count: 42)
        private var collapseReads: [Int]?
        func readTitle(at index: Int) -> Bool {
            lock.withLock {
                titleReads[index] += 1
                // The first bookend reads name/type/name, then the strict Mixer
                // absence walk reads identifying metadata from every header.
                // The fifth last-header title is the second bookend's name read.
                guard index == 41, titleReads[index] == 5 else { return false }
                collapseReads = titleReads
                return true
            }
        }
        var atCollapse: [Int]? { lock.withLock { collapseReads } }
        var counts: [Int] { lock.withLock { titleReads } }
    }

    private struct Fixture {
        let builder = FakeAXRuntimeBuilder()
        let reads = Reads()
        let events = Reads()
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let header: AXUIElement

        init() {
            app = builder.element(965_900)
            window = builder.element(965_901)
            rail = builder.element(965_902)
            header = builder.element(965_903)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Session - Tracks")
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setRole(rail, kAXListRole as String)
            builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            builder.setRole(header, kAXLayoutItemRole as String)
            builder.setAttribute(header, kAXTitleAttribute as String, " Fresh track ")
            builder.setAttribute(header, kAXSelectedAttribute as String, false)
            builder.setChildren(header, [])
            builder.setChildren(rail, [header])
            builder.setChildren(window, [rail])
        }

        func channel(unreadableRail: Bool = false, disclosure: AXUIElement? = nil,
                     additionalDisclosure: AXUIElement? = nil,
                     observationMouse: AXMouseHelper.Runtime? = nil,
                     wrongDisclosureHit: Bool = false,
                     observingAttribute: (@Sendable (AXUIElement, String) -> Void)? = nil,
                     readingAttribute: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?)? = nil,
                     observingChildren: (@Sendable (AXUIElement) -> Void)? = nil) -> AccessibilityChannel {
            let ax = builder.makeAXRuntime(
                    appElement: app,
                    attributeValueHandler: { element, attribute in
                        reads.record(attribute)
                        observingAttribute?(element, attribute)
                        if let read = readingAttribute?(element, attribute) {
                            switch read {
                            case .success(let value): return .some(value)
                            case .failure: return .some(nil)
                            }
                        }
                        return nil
                    },
                    attributeValueResultHandler: readingAttribute,
                    childrenResultHandler: { element in
                        observingChildren?(element)
                        return unreadableRail && CFEqual(element, rail)
                            ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
                    },
                    setAttributeHandler: { _, _, _ in events.record("setter"); return false },
                    performActionHandler: { element, action in
                        events.record(action)
                        // A successful AXPress is not expansion on the measured disclosure.
                        if let disclosure, CFEqual(element, disclosure), action == kAXPressAction as String { return true }
                        Issue.record("fixture forbids unrelated AX actions")
                        return false
                    },
                    elementAtPosition: { element, point in
                        guard CFEqual(element, app) else { return .success(nil) }
                        if let additionalDisclosure, point == CGPoint(x: 26, y: 36) {
                            return .success(additionalDisclosure)
                        }
                        guard let disclosure, point == CGPoint(x: 16, y: 26) else { return .success(nil) }
                        return .success(wrongDisclosureHit ? header : disclosure)
                    })
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
                executeAppleScript: { _ in Issue.record("fixture forbids AppleScript"); return .error("forbidden") },
                onScreenWindowList: { [] },
                postPopupMenuEscape: { Issue.record("fixture forbids Escape") },
                focusedApplicationPID: { 4242 }, observeFrontmost: nil)
            let mouse = AXMouseHelper.Runtime(
                postMouseEvent: { _, _, _ in Issue.record("fixture has no approved mouse actuation yet"); return false },
                postKeyEvent: { _ in Issue.record("fixture forbids keyboard events"); return false },
                postUnicodeScalar: { _ in Issue.record("fixture forbids typing"); return false }, sleepMicros: { _ in })
            let process = ProcessUtils.Runtime(logicProPID: { 4242 }, fallbackLogicProPID: { nil },
                logicProRunning: { true }, activateLogicPro: { Issue.record("fixture forbids activation"); return false },
                logicIsFrontmost: { true }, logicProBundleURL: { nil })
            return AccessibilityChannel(runtime: .axBacked(
                isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
                logicRuntime: logic, controlBarMouseRuntime: mouse, trackRenameMouseRuntime: mouse,
                trackToggleKeyRuntime: mouse, observationMouseRuntime: observationMouse, processRuntime: process,
                confirmNewTrackDialog: { Issue.record("fixture forbids Return") }, canPostEvents: { observationMouse != nil },
                runTempoFallback: { _ in Issue.record("fixture forbids fallback scripts"); return false }))
        }
    }

    @Test("permitted stack observation exposes real descendants but restores the current cache rail",
          arguments: [false, true])
    func registeredStackObservationDistinguishesCapturedAndRestoredMembership(navigation: Bool) async throws {
        try await observeStack(navigation: navigation, initiallyExpanded: false)
    }

    @Test("an already expanded rail really exposes all forty-two fixture headers without navigation")
    func registeredAlreadyExpandedStackReadsActualFullFixtureRail() async throws {
        try await observeStack(navigation: false, initiallyExpanded: true)
    }

    @Test func registeredStackKeepsOriginalReferenceAndEndsDescendantReference() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, verifyReferences: true)
    }

    @Test func registeredNestedStackObservationCapturesGrandchildrenAndEndsTheirExposure() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, verifyReferences: true, nested: true)
    }

    @Test(arguments: ["down_failed", "held_focus", "held_focus_returned", "wrong_hit"])
    func registeredStackPairsOnlyOwnedMouseDownAndUp(mouseCase: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, mouseCase: mouseCase)
    }

    @Test(arguments: ["expansion", "restoration"])
    func registeredStackDoesNotCertifyAnUnpostedMouseRelease(releaseCase: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, releaseCase: releaseCase)
    }

    @Test(arguments: ["expansion", "restoration"])
    func registeredNestedStackStopsAllGesturesAfterAnUnpostedInnerRelease(nestedRelease: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, nestedRelease: nestedRelease)
    }

    @Test(arguments: ["expansion", "restoration"])
    func registeredNestedStackNeverRestoresPastATrueDownWithUnreadFocus(downFocusRead: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, downFocusRead: downFocusRead)
    }

    @Test func registeredNestedStackKnownClosedExposureCannotReopenItsOldInverse() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, knownInnerReopen: true)
    }

    @Test(arguments: ["inner_closed", "replacement"])
    func registeredNestedStackCorroboratesTheRailAfterItsLastGrandchildRead(nestedFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, nestedFault: nestedFault)
    }

    @Test(arguments: ["focus", "project", "viewport"])
    func registeredNestedStackDoesNotReverseOverNewChildCustody(nestedFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, nestedFault: nestedFault)
    }

    @Test(arguments: ["cancel", "deadline"])
    func registeredNestedStackStopsAfterTheAcquisitionCutoff(nestedFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, nestedFault: nestedFault)
    }

    @Test(arguments: [false, true])
    func nestedExposureRequiresEveryAcquiredDisclosureAndCannotReopen(closeOuter: Bool) throws {
        let fixture = Fixture()
        let innerHeader = fixture.builder.element(965_470)
        let outer = fixture.builder.element(965_471)
        let inner = fixture.builder.element(965_472)
        fixture.builder.setRole(innerHeader, kAXLayoutItemRole as String)
        fixture.builder.setAttribute(innerHeader, kAXTitleAttribute as String, "Inner")
        for (header, triangle) in [(fixture.header, outer), (innerHeader, inner)] {
            fixture.builder.setRole(triangle, kAXDisclosureTriangleRole as String)
            fixture.builder.setAttribute(triangle, kAXValueAttribute as String, 1)
            fixture.builder.setChildren(header, [triangle])
        }
        fixture.builder.setChildren(fixture.rail, [fixture.header, innerHeader])
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/NestedScope.logicx")
        fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, [fixture.window])
        let ax = fixture.builder.makeAXRuntime(appElement: fixture.app,
            setAttributeHandler: { _, _, _ in Issue.record("no setters"); return false },
            performActionHandler: { _, _ in Issue.record("no actions"); return false })
        let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("no keys") },
            focusedApplicationPID: { 4242 }, observeFrontmost: nil)
        let scope = AXTrackBinding.Exposure(header: fixture.header, disclosure: outer, runtime: logic)
        #expect(scope.retainAcquiredDisclosure(header: innerHeader, disclosure: inner))
        let held = AXTrackBinding.Binding(window: fixture.window, header: innerHeader,
            document: "file:///tmp/NestedScope.logicx", runtime: logic, exposure: scope)
        #expect(scope.isCurrent && held.currentIndex() == 1)
        let closed = closeOuter ? outer : inner
        fixture.builder.setAttribute(closed, kAXValueAttribute as String, 0)
        #expect(!scope.isCurrent)
        fixture.builder.setAttribute(closed, kAXValueAttribute as String, 1)
        #expect(!scope.isCurrent && held.currentIndex() == nil)
        let fresh = AXTrackBinding.Exposure(header: fixture.header, disclosure: outer, runtime: logic)
        #expect(fresh.retainAcquiredDisclosure(header: innerHeader, disclosure: inner))
        let freshBinding = AXTrackBinding.Binding(window: fixture.window, header: innerHeader,
            document: "file:///tmp/NestedScope.logicx", runtime: logic, exposure: fresh)
        #expect(fresh.isCurrent && freshBinding.currentIndex() == 1)
        fresh.end()
        #expect(!fresh.isCurrent)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: ["gate", "cancel", "deadline"])
    func scopedTrackBindingDoesNotReadAXAfterCutoff(cutoff: String) {
        let fixture = Fixture()
        let disclosure = fixture.builder.element(965_450)
        fixture.builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
        fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
        fixture.builder.setChildren(fixture.header, [disclosure])
        let ax = fixture.builder.makeAXRuntime(attributeValueHandler: { _, attribute in
            fixture.reads.record(attribute); return nil
        }, setAttributeHandler: { _, _, _ in Issue.record("no setters"); return false },
           performActionHandler: { _, _ in Issue.record("no actions"); return false })
        let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("no keys") },
            focusedApplicationPID: { 4242 }, observeFrontmost: nil)
        let exposure = AXTrackBinding.Exposure(header: fixture.header, disclosure: disclosure, runtime: logic)
        let binding = AXTrackBinding.Binding(window: fixture.window, header: fixture.header,
            document: "file:///tmp/Stopped.logicx", runtime: logic, exposure: exposure)
        let context = OperationTraceContext(ownsGate: { cutoff != "gate" },
            deadline: cutoff == "deadline" ? ContinuousClock.now : nil,
            cancellationRequested: { cutoff == "cancel" })
        let index = OperationTraceContext.$current.withValue(context) { binding.currentIndex() }
        #expect(index == nil)
        #expect(fixture.reads.count == 0, "a live exposure must not read disclosure custody after the operation cutoff")
    }

    @Test("known ended exposure cannot publish writable authority for recycled duplicate-name headers")
    func registeredLateCollapseCannotResurrectRecycledDescendantReference() async throws {
        let fixture = Fixture()
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lpm965-ended-\(UUID().uuidString).logicx")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let headers = (1...42).map { fixture.builder.element(965_300 + $0) }
        let disclosure = fixture.builder.element(965_400)
        fixture.builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
        fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
        fixture.builder.setChildren(disclosure, [])
        for (index, header) in headers.enumerated() {
            fixture.builder.setRole(header, kAXLayoutItemRole as String)
            fixture.builder.setAttribute(header, kAXTitleAttribute as String,
                index == 1 || index == 2 ? "Repeated child" : "Track \(index + 1)")
            fixture.builder.setAttribute(header, kAXSelectedAttribute as String, index == 0)
            fixture.builder.setChildren(header, index == 0 ? [disclosure] : [])
        }
        let collapsed = [headers[0]] + Array(headers[24...])
        fixture.builder.setChildren(fixture.rail, headers)
        fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [headers[0]])
        fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, [fixture.window])
        fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.rail)
        fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, true)
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, bundle.absoluteString)
        let controlBar = fixture.builder.element(965_410)
        let play = fixture.builder.element(965_411)
        let record = fixture.builder.element(965_412)
        fixture.builder.setRole(controlBar, kAXGroupRole as String)
        fixture.builder.setAttribute(controlBar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
        for (control, labels) in [(play, AXLocalePolicy.transportPlayControl), (record, AXLocalePolicy.transportRecordControl)] {
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, labels.canonical)
            fixture.builder.setAttribute(control, kAXValueAttribute as String, 0)
        }
        fixture.builder.setChildren(controlBar, [play, record])
        fixture.builder.setChildren(fixture.window, [fixture.rail, controlBar])
        let bookends = StackBookends()
        let channel = fixture.channel(disclosure: disclosure, observingAttribute: { element, attribute in
            guard attribute == kAXTitleAttribute as String,
                  let index = headers.firstIndex(where: { CFEqual($0, element) }),
                  bookends.readTitle(at: index) else { return }
            fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 0)
            fixture.builder.setChildren(fixture.rail, collapsed)
        })
        let cache = StateCache()
        let registry = TargetRegistry()
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: registry,
            poller: StatePoller(axChannel: channel, cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array([.string("tracks")]), "allow_ui_navigation": .bool(false)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) {
                await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
            }
        let atCollapse = try #require(bookends.atCollapse)
        #expect(Array(atCollapse.prefix(41)) == Array(repeating: 7, count: 41))
        #expect(atCollapse[41] == 5)
        #expect(bookends.counts.allSatisfy { $0 >= 7 })
        #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == 19)
        #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        let rows = try #require(tracks["rows"] as? [[String: Any]])
        let childRows = rows.filter { ($0["name"] as? String)?.utf8.elementsEqual("Repeated child".utf8) == true }
        let childReference = childRows.first?["track_ref"] as? String
        // Reuse the exact CF handles, bytes and ordinal after the known disappearance.
        // This is not a fresh inspection or an approved reacquisition.
        fixture.builder.setChildren(fixture.rail, headers)
        fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
        let recycled = fixture.builder.makeAXRuntime().children(fixture.rail)
        #expect(recycled.count == 42 && CFEqual(recycled[1], headers[1]))
        #expect(fixture.builder.attributeValue(recycled[1], kAXTitleAttribute as String) as? String == "Repeated child")
        var mutationAuthority = false
        if let childReference {
            #expect(childRows.count == 2)
            let binding = try #require(await registry.resolve(TargetReference(rawValue: childReference)))
            let physical = try #require(binding.physicalTrack)
            #expect(CFEqual(physical.header, headers[1]) && binding.descriptor.trackIndex == 1)
            #expect(physical.document.utf8.elementsEqual(bundle.absoluteString.utf8))
            let outcome = await FeatureFlags.withAdr002TargetRefForTests(true) {
                await TargetRefResolver.resolveMutationIndex(["target_ref": .string(childReference)],
                    targetRegistry: registry, cache: cache, operation: "track.rename",
                    invalidIndexResult: toolInvalidParamsResult("explicit index required"))
            }
            if case .success(let resolved) = outcome {
                #expect(resolved.index == 1)
                mutationAuthority = true
            }
        } else {
            let coverage = tracks["coverage"] as? String
            if coverage == "partial" {
                #expect(childRows.isEmpty)
                let reasons = try #require(tracks["reasons"] as? [String])
                #expect(reasons.contains("collapsed_track_stack"))
                let collapsedStack = try #require(rows.first?["stack_collapsed"] as? Bool)
                #expect(collapsedStack)
            } else {
                #expect(coverage == "unavailable" || coverage == "unstable")
            }
        }
        #expect(!mutationAuthority, "a known ended exposure must not become writable again through recycled CF/name/index")
        #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        #expect(fixture.events.count == 0 && fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        #expect(gate.currentOperation() == nil)
    }

    private func observeStack(navigation: Bool, initiallyExpanded: Bool,
                              verifyReferences: Bool = false, mouseCase: String? = nil,
                              releaseCase: String? = nil, nested: Bool = false,
                              nestedRelease: String? = nil, nestedFault: String? = nil,
                              downFocusRead: String? = nil, knownInnerReopen: Bool = false) async throws {
        let fixture = Fixture()
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lpm965-stack-\(UUID().uuidString).logicx")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let headers = (1...42).map { fixture.builder.element(965_100 + $0) }
        let disclosure = fixture.builder.element(965_200)
        fixture.builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
        fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, initiallyExpanded ? 1 : 0)
        fixture.builder.setFrame(disclosure, x: 10, y: 20, width: 12, height: 12)
        fixture.builder.setActionNames(disclosure, [kAXPressAction as String])
        for (index, header) in headers.enumerated() {
            fixture.builder.setRole(header, kAXLayoutItemRole as String)
            fixture.builder.setAttribute(header, kAXTitleAttribute as String,
                                         index == 1 || index == 2 ? "Repeated child" : "Track \(index + 1)")
            fixture.builder.setAttribute(header, kAXSelectedAttribute as String, index == 0)
            fixture.builder.setChildren(header, index == 0 ? [disclosure] : [])
        }
        let collapsed = [headers[0]] + Array(headers[24...])
        let inner = fixture.builder.element(965_220)
        let grandchildren = nested ? [fixture.builder.element(965_221), fixture.builder.element(965_222)] : []
        let fullyExposed = Array(headers.prefix(2)) + grandchildren + Array(headers.dropFirst(2))
        if nested {
            fixture.builder.setRole(inner, kAXDisclosureTriangleRole as String)
            fixture.builder.setAttribute(inner, kAXValueAttribute as String, 0)
            fixture.builder.setFrame(inner, x: 20, y: 30, width: 12, height: 12)
            fixture.builder.setChildren(headers[1], [inner])
            for grandchild in grandchildren {
                fixture.builder.setRole(grandchild, kAXLayoutItemRole as String)
                fixture.builder.setAttribute(grandchild, kAXTitleAttribute as String, "Repeated grandchild")
                fixture.builder.setAttribute(grandchild, kAXSelectedAttribute as String, false)
                fixture.builder.setChildren(grandchild, [])
            }
            #expect(!collapsed.contains { CFEqual($0, headers[1]) })
            #expect(!headers.contains { row in grandchildren.contains { CFEqual(row, $0) } })
        }
        fixture.builder.setChildren(fixture.rail, initiallyExpanded ? headers : collapsed)
        fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, [fixture.window])
        fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.rail)
        fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, true)
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, bundle.absoluteString)
        fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [headers[0]])
        let controlBar = fixture.builder.element(965_210)
        fixture.builder.setRole(controlBar, kAXGroupRole as String)
        fixture.builder.setAttribute(controlBar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
        let play = fixture.builder.element(965_211)
        let record = fixture.builder.element(965_212)
        for (control, labels) in [(play, AXLocalePolicy.transportPlayControl), (record, AXLocalePolicy.transportRecordControl)] {
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, labels.canonical)
            fixture.builder.setAttribute(control, kAXValueAttribute as String, 0)
        }
        fixture.builder.setChildren(controlBar, [play, record])
        let scrollbar = fixture.builder.element(965_230)
        fixture.builder.setRole(scrollbar, kAXScrollBarRole as String)
        fixture.builder.setAttribute(scrollbar, kAXValueAttribute as String, 0.25)
        fixture.builder.setChildren(scrollbar, [])
        fixture.builder.setChildren(fixture.window, [fixture.rail, controlBar] + (nestedFault == "viewport" ? [scrollbar] : []))
        let replacement = fixture.builder.element(965_231)
        fixture.builder.setRole(replacement, kAXLayoutItemRole as String)
        fixture.builder.setAttribute(replacement, kAXTitleAttribute as String, "Repeated grandchild")
        fixture.builder.setAttribute(replacement, kAXSelectedAttribute as String, false)
        fixture.builder.setChildren(replacement, [])
        let observationMouse = AXMouseHelper.Runtime(postMouseEvent: { type, point, clicks in
            let isInner = nested && point == CGPoint(x: 26, y: 36)
            guard (type == .leftMouseDown || type == .leftMouseUp),
                  point == CGPoint(x: 16, y: 26) || isInner, clicks == 1 else {
                Issue.record("unexpected disclosure event"); return false
            }
            fixture.events.record(isInner ? (type == .leftMouseDown ? "inner_down" : "inner_up")
                : (type == .leftMouseDown ? "disclosure_down" : "disclosure_up"))
            let eventCount = fixture.events.count
            if let nestedRelease, isInner, type == .leftMouseUp,
               eventCount == (nestedRelease == "expansion" ? 4 : 6) {
                fixture.reads.record("inner_release_unposted")
                return false
            }
            let failedReleaseGesture = releaseCase == "expansion" ? 1 : 3
            if releaseCase != nil, eventCount == failedReleaseGesture, type == .leftMouseDown {
                // The disclosure can take effect on Down even when the paired
                // Up fails to create/post an event. Keep all other custody intact.
                let expanding = releaseCase == "expansion"
                fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, expanding ? 1 : 0)
                fixture.builder.setChildren(fixture.rail, expanding ? headers : collapsed)
                fixture.reads.record("release_fault_down_effect")
            }
            if releaseCase != nil, eventCount == failedReleaseGesture + 1, type == .leftMouseUp {
                fixture.reads.record("release_fault_up_unposted")
                return false
            }
            if type == .leftMouseDown {
                if mouseCase == "down_failed" { return false }
                if let downFocusRead, isInner, eventCount == (downFocusRead == "expansion" ? 3 : 5) {
                    fixture.reads.record("true_inner_down")
                }
                if mouseCase == "held_focus" || mouseCase == "held_focus_returned" {
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, disclosure)
                }
            }
            if type == .leftMouseUp {
                if mouseCase == "held_focus_returned" {
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.rail)
                }
                let target = isInner ? inner : disclosure
                let expanded = (fixture.builder.attributeValue(target, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                fixture.builder.setAttribute(target, kAXValueAttribute as String, expanded ? 0 : 1)
                fixture.builder.setChildren(fixture.rail, isInner ? (expanded ? headers : fullyExposed)
                    : (expanded ? collapsed : headers))
                if isInner, !expanded, let nestedFault,
                   ["focus", "project", "viewport"].contains(nestedFault) {
                    fixture.reads.record("child_custody_fault")
                    switch nestedFault {
                    case "focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, replacement)
                    case "project": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String,
                        bundle.deletingLastPathComponent().appendingPathComponent("Other.logicx").absoluteString)
                    default: fixture.builder.setAttribute(scrollbar, kAXValueAttribute as String, 0.75)
                    }
                }
                if isInner, !expanded, let nestedFault, ["cancel", "deadline"].contains(nestedFault) {
                    fixture.reads.record("child_custody_fault")
                    if nestedFault == "deadline" {
                        // Delay the actual injected channel after its fourth event,
                        // then resume strictly past the owned child's finite cutoff.
                        Thread.sleep(forTimeInterval: 0.15)
                    }
                }
            }
            return true
        }, postKeyEvent: { _ in Issue.record("fixture forbids keys"); return false },
           postUnicodeScalar: { _ in Issue.record("fixture forbids typing"); return false }, sleepMicros: { _ in })
        let cache = StateCache()
        let registry = TargetRegistry()
        let gate = LogicMutationGate()
        let fileReader: LogicProjectFileReader.Runtime = knownInnerReopen ? .init(
            currentDocumentPath: { nil }, now: Date.init, readPlistData: { _ in nil },
            mtime: { _ in
                guard fixture.reads.recorded.contains("inner_extractor_returned_zero") else { return nil }
                fixture.reads.record("closed_population_metadata")
                if fixture.reads.recorded.filter({ $0 == "closed_population_metadata" }).count == 2 {
                    fixture.reads.record("same_inner_reopened_on_retry")
                    fixture.builder.setAttribute(inner, kAXValueAttribute as String, 1)
                    fixture.builder.setChildren(fixture.rail, fullyExposed)
                }
                return nil
            }, sleep: { _ in }) : .unavailable
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: registry,
            poller: StatePoller(axChannel: fixture.channel(disclosure: disclosure,
                additionalDisclosure: nested ? inner : nil, observationMouse: observationMouse,
                wrongDisclosureHit: mouseCase == "wrong_hit", observingAttribute: { element, attribute in
                    if knownInnerReopen, fixture.events.count == 4, CFEqual(element, headers[1]),
                       attribute == kAXHelpAttribute as String {
                        fixture.reads.record("inner_row_help_before_stack_read")
                    }
                    guard let nestedFault, ["inner_closed", "replacement"].contains(nestedFault),
                          fixture.events.count == 4, attribute == kAXTitleAttribute as String,
                          CFEqual(element, grandchildren[1]) else { return }
                    fixture.reads.record("last_grandchild_title")
                    guard fixture.reads.recorded.filter({ $0 == "last_grandchild_title" }).count == 5 else { return }
                    fixture.reads.record("last_grandchild_fault")
                    if nestedFault == "inner_closed" {
                        fixture.builder.setAttribute(inner, kAXValueAttribute as String, 0)
                        fixture.builder.setChildren(fixture.rail, headers)
                    } else {
                        var changed = fullyExposed
                        changed[2] = replacement
                        fixture.builder.setChildren(fixture.rail, changed)
                    }
                }, readingAttribute: { element, attribute in
                    if knownInnerReopen, fixture.events.count == 4, CFEqual(element, inner),
                       attribute == kAXValueAttribute as String,
                       fixture.reads.recorded.contains("inner_row_help_before_stack_read"),
                       !fixture.reads.recorded.contains("inner_extractor_returned_zero") {
                        fixture.builder.setAttribute(inner, kAXValueAttribute as String, 0)
                        fixture.builder.setChildren(fixture.rail, headers)
                        fixture.reads.record("inner_extractor_returned_zero")
                        return .success(NSNumber(value: 0))
                    }
                    guard let downFocusRead, CFEqual(element, fixture.app),
                          attribute == kAXFocusedUIElementAttribute as String,
                          fixture.events.count == (downFocusRead == "expansion" ? 3 : 5),
                          !fixture.reads.recorded.contains("focus_read_missing_after_true_down") else { return nil }
                    fixture.reads.record("focus_read_missing_after_true_down")
                    return .success(nil)
                }, observingChildren: { element in
                    if knownInnerReopen, CFEqual(element, fixture.rail),
                       fixture.reads.recorded.contains("inner_extractor_returned_zero"),
                       !fixture.reads.recorded.contains("same_inner_reopened_on_retry"),
                       fixture.builder.makeAXRuntime().children(fixture.rail).count == 42 {
                        fixture.reads.record("closed_rail_actually_read")
                    }
                }), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: fileReader, keyboardFocus: { .notTextEditing })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: fileReader)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array([.string("tracks")]), "allow_ui_navigation": .bool(navigation)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) {
                if let nestedFault, ["cancel", "deadline"].contains(nestedFault),
                   let inherited = OperationTraceContext.current {
                    let context = OperationTraceContext(parentTraceID: inherited.parentTraceID,
                        mutationGateAcquired: inherited.mutationGateAcquired, ownsGate: inherited.ownsGate,
                        deadline: nestedFault == "deadline" ? ContinuousClock.now.advanced(by: .milliseconds(100)) : inherited.deadline,
                        cancellationRequested: {
                            inherited.cancellationRequested() || (nestedFault == "cancel"
                                && fixture.reads.recorded.contains("child_custody_fault"))
                        })
                    return await OperationTraceContext.$current.withValue(context) {
                        await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
                    }
                }
                return await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
            }
        if knownInnerReopen {
            #expect(fixture.reads.recorded.filter { $0 == "inner_extractor_returned_zero" }.count == 1)
            #expect(fixture.reads.recorded.contains("inner_row_help_before_stack_read"))
            #expect(fixture.reads.recorded.contains("closed_rail_actually_read"))
            #expect(fixture.reads.recorded.filter { $0 == "closed_population_metadata" }.count >= 2)
            #expect(fixture.reads.recorded.filter { $0 == "same_inner_reopened_on_retry" }.count == 1)
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up", "inner_down", "inner_up"],
                    "observed disclosure loss cannot renew the earlier inverse after the same controls reopen")
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == 44)
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            let current = await cache.getTracks()
            #expect(current.isEmpty)
            if let tracks = body["tracks"] as? [String: Any], let rows = tracks["rows"] as? [[String: Any]] {
                for row in rows where row["name"] as? String == "Repeated grandchild" {
                    let reference = try #require(row["track_ref"] as? String)
                    let binding = try #require(await registry.resolve(TargetReference(rawValue: reference)))
                    let physical = try #require(binding.physicalTrack)
                    #expect(physical.currentIndex() == nil)
                }
            } else {
                #expect(body["state"] as? String == "C")
                #expect(body["snapshot_id"] == nil)
            }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if let downFocusRead {
            #expect(fixture.reads.recorded.filter { $0 == "true_inner_down" }.count == 1)
            #expect(fixture.reads.recorded.filter { $0 == "focus_read_missing_after_true_down" }.count == 1)
            let expected = ["disclosure_down", "disclosure_up", "inner_down"]
                + (downFocusRead == "restoration" ? ["inner_up", "inner_down"] : [])
            #expect(fixture.events.recorded == expected,
                    "no inverse or additional gesture is owned while a TRUE-posted Down is unreleased")
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == (downFocusRead == "expansion" ? 42 : 44))
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == (downFocusRead == "expansion" ? 0 : 1))
            let focus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                runtime: fixture.builder.makeAXRuntime())
            #expect(CFEqual(try #require(focus), fixture.rail), "subsequent focus reads return the original healthy owner")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            let current = await cache.getTracks()
            #expect(current.isEmpty, "a pending mouse release cannot certify current rows")
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if let nestedFault {
            let lastReadFault = ["inner_closed", "replacement"].contains(nestedFault)
            #expect(fixture.reads.recorded.filter { $0 == (lastReadFault ? "last_grandchild_fault" : "child_custody_fault") }.count == 1)
            if lastReadFault {
                #expect(fixture.reads.recorded.filter { $0 == "last_grandchild_title" }.count >= 5,
                        "fault reaches the last grandchild after actual row extraction has begun")
            }
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up", "inner_down", "inner_up"],
                    "known child conflict must not start an inner inverse or collapse its outer owner")
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == (nestedFault == "inner_closed" ? 0 : 1))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            let current = await cache.getTracks()
            #expect(current.isEmpty, "conflicted temporary rows are never current cache authority")
            if lastReadFault {
                #expect(body["state"] as? String == "C")
                #expect(body["error"] as? String == "stale_snapshot")
                #expect(body["tracks"] == nil && body["snapshot_id"] == nil,
                        "the conflicted capture is discarded, not issued as a new domain report")
                #expect(effects["reason"] as? String == "stack_navigation_ownership_lost")
            }
            if nestedFault == "cancel" || nestedFault == "deadline" {
                #expect(body["state"] as? String == "C")
                #expect(body["error"] as? String == (nestedFault == "cancel" ? "cancelled" : "operation_timeout"))
                #expect(body["tracks"] == nil && body["snapshot_id"] == nil)
            }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            return
        }
        if let nestedRelease {
            #expect(fixture.reads.recorded.filter { $0 == "inner_release_unposted" }.count == 1)
            let expected = ["disclosure_down", "disclosure_up", "inner_down", "inner_up"]
                + (nestedRelease == "restoration" ? ["inner_down", "inner_up"] : [])
            #expect(fixture.events.recorded == expected, "no dependent inner or outer gesture follows an unposted release")
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == (nestedRelease == "expansion" ? 42 : 44))
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == (nestedRelease == "expansion" ? 0 : 1))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(effects["reason"] as? String == "stack_mouse_release_unverified")
            let current = await cache.getTracks()
            #expect(current.isEmpty)
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if let releaseCase {
            #expect(fixture.reads.recorded.filter { $0 == "release_fault_down_effect" }.count == 1)
            #expect(fixture.reads.recorded.filter { $0 == "release_fault_up_unposted" }.count == 1)
            let expectedEvents = releaseCase == "expansion" ? ["disclosure_down", "disclosure_up"]
                : ["disclosure_down", "disclosure_up", "disclosure_down", "disclosure_up"]
            #expect(fixture.events.recorded == expectedEvents,
                    "an unposted release must not launch a dependent restoration gesture")
            let expectedCount = releaseCase == "expansion" ? 42 : 19
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == expectedCount)
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == (releaseCase == "expansion" ? 1 : 0))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored",
                    "observed rail reversal cannot prove that the held mouse was released")
            #expect(effects["reason"] as? String == "stack_mouse_release_unverified")
            let current = await cache.getTracks()
            #expect(current.isEmpty, "unverified release must not certify current cache rows")
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            let focus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                                                            runtime: fixture.builder.makeAXRuntime())
            let heldFocus = try #require(focus)
            #expect(CFEqual(heldFocus, fixture.rail))
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
            #expect(gate.currentOperation() == nil)
            return
        }
        if let mouseCase {
            let expectedEvents = mouseCase == "wrong_hit" ? [] : mouseCase == "down_failed" ? ["disclosure_down"]
                : ["disclosure_down", "disclosure_up", "disclosure_down", "disclosure_up"]
            #expect(fixture.events.recorded == expectedEvents)
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == 19)
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            let focus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                                                            runtime: fixture.builder.makeAXRuntime())
            let actualFocus = try #require(focus)
            #expect(CFEqual(actualFocus, mouseCase == "held_focus" ? disclosure : fixture.rail))
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
            #expect(gate.currentOperation() == nil)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            if mouseCase == "held_focus" {
                #expect(effects["restoration"] as? String == "partially_restored")
                #expect(effects["reason"] as? String == "keyboard_focus_not_restored")
                let changed = try #require(effects["changed"] as? [String])
                #expect(changed.contains("keyboard_focus"))
            } else if mouseCase == "held_focus_returned" {
                #expect(effects["restoration"] as? String == "restored")
                let current = await cache.getTracks()
                #expect(current.count == 19)
            }
            return
        }
        let isError = result.isError ?? false
        #expect(!isError)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        let rows = try #require(tracks["rows"] as? [[String: Any]])
        let expectedHeaders = initiallyExpanded || navigation ? (nested ? fullyExposed : headers) : collapsed
        #expect(rows.count == expectedHeaders.count)
        #expect(rows.compactMap { $0["name"] as? String } == expectedHeaders.compactMap {
            fixture.builder.attributeValue($0, kAXTitleAttribute as String) as? String
        })
        #expect(rows.compactMap { $0["track_ref"] as? String }.count == expectedHeaders.count)
        #expect(tracks["coverage"] as? String == "partial", "exposure alone does not prove hidden/nested/global completion")
        let current = await cache.getTracks()
        #expect(current.count == (initiallyExpanded ? 42 : 19), "collapsed descendants must not become ordinary current cache rows")
        if nested {
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up", "inner_down", "inner_up",
                "inner_down", "inner_up", "disclosure_down", "disclosure_up"])
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "restored")
        }
        if verifyReferences {
            for (index, shouldResolve) in [(0, true), (1, false)] {
                let reference = try #require(rows[index]["track_ref"] as? String)
                let held = try #require(await registry.resolve(TargetReference(rawValue: reference)))
                let heldPhysical = try #require(held.physicalTrack)
                #expect(CFEqual(heldPhysical.header, headers[index]))
                if index == 1 {
                    // Recycle the same physical header and raw name at its captured
                    // ordinal BEFORE its first mutation lookup, without reacquisition.
                    fixture.builder.setChildren(fixture.rail, headers)
                    fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
                    let physical = try #require(held.physicalTrack)
                    #expect(physical.exposure != nil)
                    #expect(physical.currentIndex() == nil, "ended custody cannot resurrect on the same recycled owner")
                    // Corroborate the probe against exactly these readable injected
                    // owners, without issuing this fresh test-only scope as authority.
                    let live = AXTrackBinding.Exposure(header: headers[0], disclosure: disclosure,
                        runtime: physical.runtime, originalHeaders: collapsed)
                    let fresh = AXTrackBinding.Binding(window: physical.window, header: physical.header,
                        document: physical.document, runtime: physical.runtime, exposure: live)
                    #expect(fresh.currentIndex() == 1)
                    live.end()
                }
                let outcome = await FeatureFlags.withAdr002TargetRefForTests(true) {
                    await TargetRefResolver.resolveMutationIndex(["target_ref": .string(reference)],
                        targetRegistry: registry, cache: cache, operation: "track.rename",
                        invalidIndexResult: toolInvalidParamsResult("explicit index required"))
                }
                var resolved = false
                if case .success(let target) = outcome { resolved = true; #expect(target.index == index) }
                if shouldResolve { #expect(resolved) } else { #expect(!resolved) }
                if index == 1 {
                    fixture.builder.setChildren(fixture.rail, collapsed)
                    fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 0)
                }
            }
        }
        if nested {
            let grandchildRows = rows.filter { ($0["name"] as? String)?.utf8.elementsEqual("Repeated grandchild".utf8) == true }
            #expect(grandchildRows.count == 2)
            let reference = try #require(grandchildRows.first?["track_ref"] as? String)
            let binding = try #require(await registry.resolve(TargetReference(rawValue: reference)))
            let physical = try #require(binding.physicalTrack)
            #expect(CFEqual(physical.header, grandchildren[0]))
            #expect(binding.descriptor.trackIndex == 2)
            #expect(physical.exposure != nil)
            fixture.builder.setChildren(fixture.rail, fullyExposed)
            fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
            fixture.builder.setAttribute(inner, kAXValueAttribute as String, 1)
            let recycled = fixture.builder.makeAXRuntime().children(fixture.rail)
            #expect(CFEqual(recycled[2], grandchildren[0]))
            #expect(fixture.builder.attributeValue(recycled[2], kAXTitleAttribute as String) as? String == "Repeated grandchild")
            #expect(physical.currentIndex() == nil, "ended nested custody must not resurrect through the same CF/name/index")
            let live = AXTrackBinding.Exposure(header: headers[1], disclosure: inner,
                runtime: physical.runtime, originalHeaders: collapsed)
            let fresh = AXTrackBinding.Binding(window: physical.window, header: physical.header,
                document: physical.document, runtime: physical.runtime, exposure: live)
            #expect(fresh.currentIndex() == 2, "the same injected owners must remain readable for a genuinely live scope")
            live.end()
            let resolution = await FeatureFlags.withAdr002TargetRefForTests(true) {
                await TargetRefResolver.resolveMutationIndex(["target_ref": .string(reference)],
                    targetRegistry: registry, cache: cache, operation: "track.rename",
                    invalidIndexResult: toolInvalidParamsResult("explicit index required"))
            }
            var mutationAuthority = false
            if case .success = resolution { mutationAuthority = true }
            #expect(!mutationAuthority)
            fixture.builder.setChildren(fixture.rail, collapsed)
            fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 0)
            fixture.builder.setAttribute(inner, kAXValueAttribute as String, 0)
        }
        #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == (initiallyExpanded ? 42 : 19))
        #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == (initiallyExpanded ? 1 : 0))
        #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        let selected = try #require(fixture.builder.attributeValue(headers[0], kAXSelectedAttribute as String) as? Bool)
        #expect(selected)
        let focus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                                                        runtime: fixture.builder.makeAXRuntime())
        let actualFocus = try #require(focus)
        #expect(CFEqual(actualFocus, fixture.rail))
        if !navigation { #expect(fixture.events.count == 0) }
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        #expect(gate.currentOperation() == nil)
    }

    private func inspect(
        fixture: Fixture, unreadableRail: Bool = false, cancelBeforeRead: Bool = false,
        hasVisibleWindow: Bool = true,
        domains: [String] = ["tracks", "strips"],
        stopBeforeRead: Bool? = nil,
        keyboardFocus: @escaping @Sendable () -> AccessibilityChannel.LogicKeyboardFocus = { .notTextEditing }
    ) async throws -> CallTool.Result {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Session"))
        await cache.updateTracks([TrackState(id: 0, name: "Old cached track", type: .audio)])
        await cache.updateChannelStrips([ChannelStripState(trackIndex: 0, name: "Old cached strip")])
        let gate = LogicMutationGate()
        let poller = StatePoller(axChannel: fixture.channel(unreadableRail: unreadableRail), cache: cache,
                                 runtime: .init(hasVisibleWindow: { hasVisibleWindow }, projectFileReader: .unavailable,
                                                keyboardFocus: keyboardFocus))
        if let awaitStop = stopBeforeRead {
            if awaitStop { await poller.stop() }
            else { await poller.stopImmediately() }
        }
        let dependencies = HandlerDependencies(
            router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
            poller: poller,
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable
        )
        let handler = try #require(OperationHandlerRegistry.handler(
            tool: "logic_project", command: "inspect_session"
        ))
        let params: [String: Value] = ["domains": .array(domains.map(Value.string))]
        return await LogicProServer.runWithDeadline(
            tool: "logic_project", command: "inspect_session", commandParams: params,
            mutationGate: gate
        ) {
            if cancelBeforeRead { withUnsafeCurrentTask { $0?.cancel() } }
            return await handler(dependencies, params)
        }
    }

    @Test func registeredInspectionDoesNotRepublishTheOldCache() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let cache = StateCache()
            await cache.updateProject(ProjectInfo(name: "Session"))
            await cache.updateTracks([TrackState(id: 0, name: "Old cached track", type: .audio)])
            let gate = LogicMutationGate()
            let dependencies = HandlerDependencies(
                router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
                poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable)),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [:] }, projectFileReader: .unavailable
            )
            let handler = try #require(OperationHandlerRegistry.handler(
                tool: "logic_project", command: "inspect_session"
            ))
            let params: [String: Value] = ["domains": .array([.string("tracks")])]
            let result = await LogicProServer.runWithDeadline(
                tool: "logic_project", command: "inspect_session", commandParams: params,
                mutationGate: gate
            ) { await handler(dependencies, params) }
            let isError = result.isError ?? false
            #expect(!isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.compactMap { $0["name"] as? String } == [" Fresh track "],
                    "a fresh request must read after its invocation, not re-date the old cache")
            #expect(tracks["coverage"] as? String == "partial")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func failedRequestedReadsDoNotBorrowOlderRows() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, unreadableRail: true)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            for key in ["tracks", "strips"] {
                let domain = try #require(body[key] as? [String: Any])
                #expect(domain["coverage"] as? String == "unavailable")
                #expect(try #require(domain["rows"] as? [[String: Any]]).isEmpty,
                        "an unread requested domain is not the cached population")
            }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: ["tracks", "strips"])
    func sourceAndCoverageDistinguishUnrequestedFromFailedDomains(requested: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, domains: [requested])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let sources = try #require(body["sources"] as? [String: Any])
            let unrequested = requested == "tracks" ? "strips" : "tracks"
            let omitted = try #require(body[unrequested] as? [String: Any])
            #expect(omitted["coverage"] as? String == "unavailable")
            #expect(omitted["reasons"] as? [String] == ["domain_not_requested"])
            #expect(sources[unrequested] as? String == "not_requested")
            #expect(sources[requested] as? String == (requested == "tracks" ? "ax_request_read" : "ax_request_unavailable"))
        }
    }

    @Test func noVisibleWindowCannotEscapeTheInertPollerBoundary() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, hasVisibleWindow: false)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            for key in ["tracks", "strips"] {
                let domain = try #require(body[key] as? [String: Any])
                #expect(domain["coverage"] as? String == "unavailable")
                #expect(try #require(domain["rows"] as? [[String: Any]]).isEmpty)
            }
            #expect(fixture.reads.count == 0,
                    "the no-window runtime must not reach even injected AX, much less production AX")
        }
    }

    @Test(arguments: [false, true])
    func freshAcquisitionCannotEndAnInlineEdit(editingBeginsDuringRead: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, keyboardFocus: {
                !editingBeginsDuringRead || fixture.reads.count > 0
                    ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
                    : .notTextEditing
            })
            let isError = result.isError ?? false
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "readback_unavailable")
            #expect(body["snapshot_id"] == nil)
            #expect(fixture.reads.helpCount == 0,
                    "AXHelp is not a harmless read while the user is editing a name")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func cancellationBeforeAcquisitionProducesNoReplacementReport() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, cancelBeforeRead: true)
            let isError = result.isError ?? false
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "cancelled")
            #expect(body["snapshot_id"] == nil)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func cancelledCallerCannotStartDetachedAcquisition() async throws {
        let reads = Reads()
        let gate = LogicMutationGate()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LogicProServer.runWithDeadline(
                tool: "logic_project", command: "inspect_session", mutationGate: gate
            ) {
                reads.record("detached_work")
                return toolTextResult("replacement report")
            }
        }
        let result = await caller.value
        let isError = result.isError ?? false
        #expect(isError)
        #expect(reads.count == 0)
        #expect(gate.currentOperation() == nil)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "cancelled")
    }

    @Test func callerCancellationReachesAnAlreadyStartedAcquisition() async throws {
        let suspended = SuspendedRead()
        let gate = LogicMutationGate()
        let caller = Task {
            await LogicProServer.runWithDeadline(
                tool: "logic_project", command: "inspect_session", mutationGate: gate
            ) {
                await suspended.suspend()
                return Task.isCancelled
                    ? toolStateCResult(.cancelled, extras: ["write_attempted": false])
                    : toolTextResult("{\"replacement_published\":true}")
            }
        }
        await suspended.waitForEntry()
        caller.cancel()
        await suspended.release()
        let result = await caller.value
        let isError = result.isError ?? false
        #expect(isError)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "cancelled")
        #expect(body["replacement_published"] == nil)
        #expect(gate.currentOperation() == nil)
    }

    @Test func callerCancellationIsRememberedByTheOwnedContext() async throws {
        let suspended = SuspendedRead()
        let caller = Task {
            await LogicProServer.runWithDeadline(
                tool: "logic_project", command: "inspect_session", mutationGate: LogicMutationGate()
            ) {
                await suspended.suspend()
                let context = OperationTraceContext.current
                return toolTextResult(encodeJSON(Value.object([
                    "caller_cancelled": .bool(context?.cancellationRequested() ?? false)
                ])))
            }
        }
        await suspended.waitForEntry()
        caller.cancel()
        await suspended.release()
        let result = await caller.value
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(try #require(body["caller_cancelled"] as? Bool),
                "owned checks must observe remembered cancellation, not just task.cancel delivery")
    }

    @Test func rememberedCancellationRefusesAnUncancelledWorker() async throws {
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(
            mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) },
            cancellationRequested: { true }
        )
        let result = await OperationTraceContext.$current.withValue(context) {
            #expect(!Task.isCancelled,
                    "the fixture represents cancellation remembered before worker registration")
            #expect(context.ownsGate())
            do {
                try SessionPopulationObservation.requireOwnedAcquisition()
                return toolTextResult("{\"replacement_published\":true}")
            } catch SessionPopulationObservation.AcquisitionError.cancelled {
                return toolStateCResult(.cancelled, extras: ["write_attempted": false])
            } catch {
                return toolStateCResult(.readbackUnavailable, extras: ["write_attempted": false])
            }
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "cancelled")
        #expect(body["replacement_published"] == nil)
    }

    @Test func rememberedCancellationStopsTheRegisteredProducerBeforeAX() async throws {
        let fixture = Fixture()
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Original project"))
        await cache.updateTracks([TrackState(id: 0, name: "Original cached row", type: .audio)])
        let registry = TargetRegistry()
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(
            mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) },
            cancellationRequested: { true }
        )
        let dependencies = HandlerDependencies(
            router: ChannelRouter(), cache: cache, targetRegistry: registry,
            poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable)),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable
        )
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let result = await OperationTraceContext.$current.withValue(context) {
            #expect(!Task.isCancelled)
            #expect(context.ownsGate())
            return await handler(dependencies, ["domains": .array([.string("tracks")])])
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "cancelled")
        #expect(body["snapshot_id"] == nil)
        #expect(fixture.reads.count == 0)
        #expect(await cache.getProject().name == "Original project")
        #expect(await cache.getTracks().map(\.name) == ["Original cached row"])
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func stoppedPollerCannotAcquireWithoutABackgroundLoop(awaitStop: Bool) async throws {
        let fixture = Fixture()
        let result = try await inspect(fixture: fixture, stopBeforeRead: awaitStop)
        let isError = result.isError ?? false
        #expect(isError)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "readback_unavailable")
        #expect(body["snapshot_id"] == nil)
        #expect(fixture.reads.count == 0,
                "stop must close explicit request cycles even when no background loop was started")
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test func unstableLivePopulationIsNotACurrentRepairBaseline() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = StateCache()
            let project = ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx")
            let tracks = [TrackState(id: 0, name: "Name before a concurrent edit", type: .audio)]
            await cache.updateProject(project)
            await cache.updateTracks(tracks)
            let boundary = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
            let now = Date()
            let accepted = try #require(await cache.acceptFreshPopulation(
                .init(project: project, tracks: tracks, strips: [], fileTrackCount: nil,
                      beganAt: now, endedAt: now, stable: false),
                ifCurrent: boundary, stoppingWhen: { false }
            ))
            let capture = await SessionPopulationObservation.capture(
                cache: cache, targetRegistry: nil, fileReader: .unavailable, accepted: accepted
            )
            #expect(capture.before == capture.after,
                    "the counterexample requires an unchanged cache but changing live observations")
            #expect(!(await cache.inspectionIsCurrent(capture)))
            #expect(SessionPopulationObservation.trackRowReadbackReasons(capture: capture)
                .contains(.livePopulationMoved))
            let report = SessionPopulationObservation.build(
                request: .init(domains: [.tracks, .strips, .associations, .hierarchy, .routing, .color]),
                capture: capture
            )
            for reasons in [report.tracks.reasons, report.strips.reasons, report.associations.reasons,
                            report.hierarchy.reasons, report.routing?.reasons ?? [], report.color?.reasons ?? []] {
                #expect(reasons.contains(.livePopulationMoved),
                        "live instability must not be misreported as a cache movement")
            }
        }
    }

    @Test func disappearingNameWitnessIsNotAStablePopulation() async throws {
        final class NamePhase: @unchecked Sendable {
            private let lock = NSLock()
            private var observed = true
            var nameIsObserved: Bool { lock.withLock { observed } }
            func extractionPassedSelection() { lock.withLock { observed.toggle() } }
        }
        let fixture = Fixture()
        let field = fixture.builder.element(965_904)
        fixture.builder.setRole(field, kAXTextFieldRole as String)
        fixture.builder.setChildren(field, [])
        fixture.builder.setChildren(fixture.header, [field])
        fixture.builder.removeAttribute(fixture.header, kAXTitleAttribute as String)
        let phase = NamePhase()
        let extractionReads = Reads()
        let lostNameReads = Reads()
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app,
            attributeValueHandler: { element, attribute in
                // extractTrackState reads its primary name BEFORE this selected
                // value, then inferTrackType reads the name again. Advance the
                // before/after phase only at that actual extraction boundary.
                if CFEqual(element, fixture.header), attribute == kAXSelectedAttribute as String {
                    extractionReads.record(attribute)
                    phase.extractionPassedSelection()
                }
                guard CFEqual(element, field), attribute == kAXValueAttribute as String else { return nil }
                // A genuine name and the extractor's fallback have identical wire bytes.
                if phase.nameIsObserved { return .some("Untitled" as NSString) }
                lostNameReads.record(attribute)
                return .some(nil)
            },
            setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: runtime
        ))
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await channel.readFreshSessionPopulation(
                request: .init(domains: [.tracks]), fileReader: .unavailable, stoppingWhen: { false }
            )
        }
        #expect(!population.stable,
                "wire equality cannot hide loss of the live name witness needed to issue a target")
        #expect(extractionReads.count == 6, "all three before/after attempts must reject identity disagreement")
        #expect(lostNameReads.count >= 3, "the actual after-extraction must consume the missing-name fault")
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test func cancelledTasksCannotMintTrackOrProjectReferences() async throws {
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        let project = ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx")
        let track = TrackState(id: 0, name: "Fresh name", type: .audio)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let tracks = await TrackReferenceIssuance.issue(for: [track], registry: registry, snapshot: snapshot)
            let projectResult = await ProjectReferenceIssuance.issue(cached: project, registry: registry, snapshot: snapshot)
            return (tracks, projectResult)
        }
        let (tracks, projectResult) = await task.value
        #expect(tracks == nil)
        if case .stale = projectResult {} else { Issue.record("cancelled project issuance minted a target") }
        let trackDescriptor = TargetDescriptor(trackIndex: track.id, trackName: track.name)
        #expect(await registry.issuedReference(kind: .track, descriptor: trackDescriptor,
                                               fingerprint: trackDescriptor.fingerprint, snapshot: snapshot) == nil)
        let projectDescriptor = try #require(ProjectReferenceIssuance.descriptor(
            name: project.name, filePath: project.filePath, epoch: snapshot.projectEpoch
        ))
        #expect(await registry.issuedReference(kind: .project, descriptor: projectDescriptor,
                                               fingerprint: projectDescriptor.fingerprint, snapshot: snapshot) == nil)
    }

    @Test func cancelledPublicationCannotRetainANewReport() async throws {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx"))
        let epoch = await cache.auditSnapshot().projectEpoch
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.retainSessionReport(id: "cancelled-report", json: "{}",
                                                  capturedEpoch: epoch, capturedPath: "/tmp/Session.logicx")
        }
        #expect(!(await task.value))
        #expect(await cache.retainedSessionReport(id: "cancelled-report") == nil)
    }

    @Test(arguments: [false, true])
    func finalPublicationPreservesTheActualRefusalReason(deadlineExpired: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = StateCache()
            await cache.updateProject(ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx"))
            let capture = await SessionPopulationObservation.capture(
                cache: cache, targetRegistry: nil, fileReader: .unavailable
            )
            let context = OperationTraceContext(
                mutationGateAcquired: true, ownsGate: { deadlineExpired },
                deadline: deadlineExpired ? ContinuousClock.now.advanced(by: .seconds(-1)) : nil
            )
            let result = await OperationTraceContext.$current.withValue(context) {
                await ProjectDispatcher.handle(
                    command: "inspect_session", params: [:], router: ChannelRouter(), cache: cache,
                    dialogPresent: { false }, cleanupAuditFileReader: .unavailable,
                    acquireSessionPopulation: { _ in capture }
                )
            }
            let isError = result.isError ?? false
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == (deadlineExpired ? "operation_timeout" : "readback_unavailable"))
            #expect(body["snapshot_id"] == nil)
        }
    }

    @Test(arguments: [false, true])
    func interruptedRetentionIsNotMisreportedAsAStaleSnapshot(cancelDuringRetention: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = StateCache()
            await cache.updateProject(ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx"))
            let capture = await SessionPopulationObservation.capture(
                cache: cache, targetRegistry: nil, fileReader: .unavailable
            )
            let ownershipChecks = Reads()
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: {
                ownershipChecks.record("ownership")
                if ownershipChecks.count == 1 { return true }
                if cancelDuringRetention { withUnsafeCurrentTask { $0?.cancel() } }
                return false
            })
            let publication = Task {
                await OperationTraceContext.$current.withValue(context) {
                    await ProjectDispatcher.handle(
                        command: "inspect_session", params: [:], router: ChannelRouter(), cache: cache,
                        dialogPresent: { false }, cleanupAuditFileReader: .unavailable,
                        acquireSessionPopulation: { _ in capture }
                    )
                }
            }
            let result = await publication.value
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == (cancelDuringRetention ? "cancelled" : "readback_unavailable"))
            #expect(body["snapshot_id"] == nil)
            #expect(ownershipChecks.count >= 2, "the refusal must happen inside actor-owned retention")
            #expect(await cache.retainedSessionReport(id: capture.captureID) == nil)
        }
    }

    @Test func unboundFreshRowsCannotIssueProjectScopedTargets() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.compactMap { $0["name"] as? String } == [" Fresh track "])
            #expect(rows.allSatisfy { $0["track_ref"] == nil },
                    "unbound fresh rows are readable observations, not project-scoped write targets")
            #expect(tracks["coverage"] as? String == "partial")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func externalDocumentSwitchCannotReuseAnEarlierTrackReference() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = Fixture()
            let ownedDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpm965-fresh-targets-" + UUID().uuidString, isDirectory: true)
            let oldBundle = ownedDirectory.appendingPathComponent("Old.logicx", isDirectory: true)
            let newBundle = ownedDirectory.appendingPathComponent("New.logicx", isDirectory: true)
            try FileManager.default.createDirectory(at: oldBundle, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: ownedDirectory) }
            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, newBundle.absoluteString)
            let cache = StateCache()
            let oldProject = ProjectInfo(name: "Session", filePath: oldBundle.path)
            await cache.updateProject(oldProject)
            let registry = TargetRegistry()
            let oldSnapshot = await registry.currentSnapshot
            _ = await ProjectReferenceIssuance.issue(cached: oldProject, registry: registry, snapshot: oldSnapshot)
            let oldIssued = try #require(await TrackReferenceIssuance.issue(
                for: [TrackState(id: 0, name: " Fresh track ", type: .audio)],
                registry: registry, snapshot: oldSnapshot
            ))
            let oldReference = try #require(oldIssued.byRow.first ?? nil)
            let gate = LogicMutationGate()
            let dependencies = HandlerDependencies(
                router: ChannelRouter(), cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable)),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [:] }, projectFileReader: .unavailable
            )
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let params: [String: Value] = ["domains": .array([.string("tracks")])]
            let result = await LogicProServer.runWithDeadline(
                tool: "logic_project", command: "inspect_session", commandParams: params, mutationGate: gate
            ) { await handler(dependencies, params) }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let project = try #require(body["project"] as? [String: Any])
            #expect(project["file_path"] as? String == newBundle.path)
            let rows = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
            #expect(rows.first?["track_ref"] as? String != oldReference.rawValue)
            #expect(await registry.resolve(oldReference) == nil,
                    "a matching raw name and ordinal in a different document is not the earlier target")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }
}
