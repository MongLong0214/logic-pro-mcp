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

    private final class SelectionDispatchClock: @unchecked Sendable {
        private let lock = NSLock()
        private var acceptedAt: ContinuousClock.Instant?
        func accept() { lock.withLock { acceptedAt = .now } }
        var settled: Bool {
            lock.withLock {
                acceptedAt.map { $0.duration(to: .now) >= .milliseconds(120) } ?? false
            }
        }
    }

    private final class StackBookends: @unchecked Sendable {
        private let lock = NSLock()
        private var titleReads = Array(repeating: 0, count: 42)
        private var collapseReads: [Int]?
        func readTitle(at index: Int) -> Bool {
            lock.withLock {
                titleReads[index] += 1
                // Fresh population omits focus-moving Help/type inference. The
                // first bookend reads the name, then the strict Mixer absence
                // walk reads metadata. The third title is the second name read.
                guard index == 41, titleReads[index] == 3 else { return false }
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
                     thirdDisclosure: AXUIElement? = nil,
                     wrongAdditionalDisclosureHit: Bool = false,
                     observationMouse: AXMouseHelper.Runtime? = nil,
                     hiddenControl: AXUIElement? = nil,
                     needsWindowServerBootstrap: Bool = false,
                     focusedPID: pid_t = 4242,
                     observationAction: (@Sendable (AXUIElement, String) -> Bool?)? = nil,
                     observationHit: (@Sendable (CGPoint) -> AXUIElement?)? = nil,
                     wrongDisclosureHit: Bool = false,
                     focusSetter: (@Sendable (AXUIElement, String, CFTypeRef) -> Bool)? = nil,
                     frameReads: Reads? = nil, frameFault: String? = nil,
                     observingAttribute: (@Sendable (AXUIElement, String) -> Void)? = nil,
                     readingAttribute: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?)? = nil,
                     observingChildren: (@Sendable (AXUIElement) -> Void)? = nil,
                     observingLegacyChildren: (@Sendable (AXUIElement) -> Void)? = nil,
                     observeHost: @escaping @Sendable (pid_t) -> ProcessUtils.LogicHostObservation? = { _ in nil }) -> AccessibilityChannel {
            let baseAX = builder.makeAXRuntime(
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
                    childrenHandler: { element in
                        observingLegacyChildren?(element)
                        return nil
                    },
                    childrenResultHandler: { element in
                        observingChildren?(element)
                        return unreadableRail && CFEqual(element, rail)
                            ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
                    },
                    setAttributeHandler: { element, attribute, value in
                        if let focusSetter { return focusSetter(element, attribute, value) }
                        events.record("setter"); return false
                    },
                    performActionHandler: { element, action in
                        if let result = observationAction?(element, action) { return result }
                        events.record(action)
                        // A successful AXPress is not expansion on the measured disclosure.
                        if let disclosure, CFEqual(element, disclosure), action == kAXPressAction as String { return true }
                        Issue.record("fixture forbids unrelated AX actions")
                        return false
                    },
                    elementAtPosition: { element, point in
                        guard CFEqual(element, app) else { return .success(nil) }
                        if let hit = observationHit?(point) { return .success(hit) }
                        if let hiddenControl, point == CGPoint(x: 16, y: 26) { return .success(hiddenControl) }
                        if let thirdDisclosure, point == CGPoint(x: 36, y: 46) { return .success(thirdDisclosure) }
                        if let additionalDisclosure, point == CGPoint(x: 26, y: 36) {
                            return .success(wrongAdditionalDisclosureHit ? header : additionalDisclosure)
                        }
                        guard let disclosure, point == CGPoint(x: 16, y: 26) else { return .success(nil) }
                        return .success(wrongDisclosureHit ? header : disclosure)
                    })
            let ax: AXHelpers.Runtime
            if let frameReads {
                let frameBatch: (@Sendable (AXUIElement, [String]) -> Result<[AnyObject], AXHelpers.AXStatusError>)?
                if frameFault == "legacy" { frameBatch = nil }
                else {
                    frameBatch = { element, attributes in
                        let geometry = attributes == [kAXPositionAttribute as String, kAXSizeAttribute as String]
                        if geometry {
                            frameReads.record("frame_batch")
                            if frameFault == "failure" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                            if frameFault == "null_fallback" || frameFault == "missing" { return .success([NSNull(), NSNull()]) }
                        }
                        var values: [AnyObject] = []
                        for attribute in attributes {
                            let reading: Result<AnyObject?, AXHelpers.AXStatusError> = attribute == kAXChildrenAttribute as String
                                ? AXHelpers.childrenResult(element, runtime: baseAX).map { $0 as CFArray }
                                : AXHelpers.getAttributeResult(element, attribute, runtime: baseAX)
                            switch reading {
                            case .success(let value): values.append(value ?? NSNull())
                            case .failure(let error):
                                var nativeError = AXError(rawValue: error.raw) ?? .cannotComplete
                                guard let wrapped = AXValueCreate(.axError, &nativeError) else { return .failure(error) }
                                values.append(wrapped)
                            }
                        }
                        if geometry {
                            if frameFault == "short" { return .success(Array(values.prefix(1))) }
                            if frameFault == "position_type" { values[0] = NSNumber(value: 0) }
                            if frameFault == "size_type" { values[1] = NSNumber(value: 0) }
                            if frameFault == "position_kind" { values[0] = values[1] }
                        }
                        return .success(values)
                    }
                }
                ax = AXHelpers.Runtime(axApp: baseAX.axApp, attributeValue: baseAX.attributeValue,
                    attributeIsSettable: baseAX.attributeIsSettable, setAttributeValue: baseAX.setAttributeValue,
                    children: baseAX.children, performAction: baseAX.performAction, childCount: baseAX.childCount,
                    actionNames: baseAX.actionNames, actionNamesResult: baseAX.actionNamesResult,
                    childrenResult: baseAX.childrenResult, attributeValueResult: { element, attribute in
                        if [kAXPositionAttribute as String, kAXSizeAttribute as String].contains(attribute) {
                            frameReads.record("frame_single")
                            if frameFault == "missing", attribute == kAXPositionAttribute as String { return .success(nil) }
                        }
                        return AXHelpers.getAttributeResult(element, attribute, runtime: baseAX)
                    }, performActionResult: baseAX.performActionResult, elementAtPosition: baseAX.elementAtPosition,
                    attributeValuesResult: frameBatch)
            } else { ax = baseAX }
            let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
                executeAppleScript: { _ in Issue.record("fixture forbids AppleScript"); return .error("forbidden") },
                onScreenWindowList: { reads.record("window_server_bootstrap"); return [] },
                postPopupMenuEscape: { Issue.record("fixture forbids Escape") },
                focusedApplicationPID: { needsWindowServerBootstrap && !reads.recorded.contains("window_server_bootstrap") ? nil : focusedPID },
                observeFrontmost: nil, observeHost: observeHost)
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

    @Test(arguments: ["observed", "unknown", "changed", "wrong_window"])
    func registeredInspectionBindsHostMetadataToItsOwnBookends(mode: String) async throws {
        let fixture = Fixture()
        let hostReads = Reads()
        let result = try await inspect(fixture: fixture, domains: ["tracks"], observeHost: { pid in
            #expect(pid == 4242)
            hostReads.record("host")
            if mode == "unknown" { return nil }
            if mode == "wrong_window" {
                fixture.builder.setAttribute(fixture.app, kAXMainWindowAttribute as String,
                                             fixture.builder.element(965_999))
            }
            return .init(logicVersion: "12.3", logicBuild: mode == "changed" ? "\(hostReads.recorded.count)" : "6674")
        })
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let host = try #require(body["host_observation"] as? [String: Any])
        if mode == "observed" {
            #expect(host["logic_version"] as? String == "12.3")
            #expect(host["logic_build"] as? String == "6674")
        } else {
            #expect(host["logic_version"] is NSNull)
            #expect(host["logic_build"] is NSNull)
        }
        #expect(!hostReads.recorded.isEmpty)
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test("fresh inspection reports the held hidden-track view without querying Help or actuating it",
          arguments: [false, true])
    func registeredInspectionReportsHiddenTrackView(shown: Bool) async throws {
        let fixture = hiddenViewFixture(shown: shown)
        let result = try await inspect(fixture: fixture, domains: ["tracks"])
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        let witnesses = try #require(tracks["witnesses"] as? [String: Any])
        let actual = try #require(witnesses["hidden_tracks_shown"] as? Bool)
        if shown { #expect(actual) }
        else { #expect(!actual) }
        #expect(tracks["coverage"] as? String == "partial")
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        #expect(fixture.reads.helpCount == 0)
    }

    @Test(arguments: ["nonbinary", "fractional", "duplicate", "wrong_window", "wrong_parent",
                      "wrong_description", "label_extension", "other_mode", "missing_parent", "absent_control"])
    func registeredInspectionDoesNotInventHiddenView(fault: String) async throws {
        let fixture = hiddenViewFixture(shown: false, fault: fault)
        let result = try await inspect(fixture: fixture, domains: ["tracks"])
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        let witnesses = try #require(tracks["witnesses"] as? [String: Any])
        #expect(witnesses["hidden_tracks_shown"] == nil)
        #expect(tracks["coverage"] as? String == "partial")
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        #expect(fixture.reads.helpCount == 0)
    }

    @Test(arguments: [false, true])
    func registeredInspectionReadsTheActualHeaderHideButton(hidden: Bool) async throws {
        let fixture = hiddenViewFixture(shown: true)
        let button = fixture.builder.element(965_980)
        fixture.builder.setRole(button, kAXCheckBoxRole as String)
        fixture.builder.setAttribute(button, kAXDescriptionAttribute as String, "Hide Track")
        fixture.builder.setAttribute(button, kAXValueAttribute as String, NSNumber(value: hidden ? 1 : 0))
        fixture.builder.setAttribute(button, kAXParentAttribute as String, fixture.header)
        fixture.builder.setAttribute(button, kAXWindowAttribute as String, fixture.window)
        fixture.builder.setChildren(fixture.header, [button])
        let result = try await inspect(fixture: fixture, domains: ["tracks"])
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        let rows = try #require(tracks["rows"] as? [[String: Any]])
        let actual = try #require(rows.first?["hidden"] as? Bool)
        if hidden { #expect(actual) }
        else { #expect(!actual) }
        #expect(tracks["coverage"] as? String == "partial")
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        #expect(fixture.reads.helpCount == 0)
    }

    @Test(arguments: ["missing", "duplicate", "fractional", "nonbinary", "wrong_role",
                      "wrong_parent", "wrong_window", "extended_label", "unread_value"])
    func registeredInspectionCannotInventAHeaderHideFlag(fault: String) async throws {
        let fixture = hiddenViewFixture(shown: true)
        let button = fixture.builder.element(965_980)
        fixture.builder.setRole(button, kAXCheckBoxRole as String)
        fixture.builder.setAttribute(button, kAXDescriptionAttribute as String, "Hide Track")
        fixture.builder.setAttribute(button, kAXValueAttribute as String, NSNumber(value: 1))
        fixture.builder.setAttribute(button, kAXParentAttribute as String, fixture.header)
        fixture.builder.setAttribute(button, kAXWindowAttribute as String, fixture.window)
        fixture.builder.setChildren(fixture.header, [button])
        switch fault {
        case "missing": fixture.builder.setChildren(fixture.header, [])
        case "duplicate":
            let other = fixture.builder.element(965_981)
            fixture.builder.setRole(other, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(other, kAXDescriptionAttribute as String, "Hide Track")
            fixture.builder.setChildren(fixture.header, [button, other])
        case "fractional": fixture.builder.setAttribute(button, kAXValueAttribute as String, NSNumber(value: 0.5))
        case "nonbinary": fixture.builder.setAttribute(button, kAXValueAttribute as String, NSNumber(value: 2))
        case "wrong_role": fixture.builder.setRole(button, kAXButtonRole as String)
        case "wrong_parent": fixture.builder.setAttribute(button, kAXParentAttribute as String, fixture.rail)
        case "wrong_window": fixture.builder.setAttribute(button, kAXWindowAttribute as String, fixture.builder.element(965_982))
        case "extended_label": fixture.builder.setAttribute(button, kAXDescriptionAttribute as String, "Hide Track elsewhere")
        case "unread_value": fixture.builder.setAttribute(button, kAXValueAttribute as String, "unread")
        default: Issue.record("unexpected hide flag fault")
        }
        let result = try await inspect(fixture: fixture, domains: ["tracks"])
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        let rows = try #require(tracks["rows"] as? [[String: Any]])
        #expect(rows.first?["hidden"] as? String == "unknown")
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        #expect(fixture.reads.helpCount == 0)
    }

    @Test func registeredInspectionRejectsChangingHeaderHideValues() async throws {
        let fixture = hiddenViewFixture(shown: true)
        let button = fixture.builder.element(965_980)
        fixture.builder.setRole(button, kAXCheckBoxRole as String)
        fixture.builder.setAttribute(button, kAXDescriptionAttribute as String, "Hide Track")
        fixture.builder.setAttribute(button, kAXValueAttribute as String, NSNumber(value: 1))
        fixture.builder.setAttribute(button, kAXParentAttribute as String, fixture.header)
        fixture.builder.setAttribute(button, kAXWindowAttribute as String, fixture.window)
        fixture.builder.setChildren(fixture.header, [button])
        let values = Reads()
        let result = try await inspect(fixture: fixture, domains: ["tracks"], readingAttribute: { element, attribute in
            guard CFEqual(element, button), attribute == kAXValueAttribute as String else { return nil }
            values.record(attribute)
            return .success(NSNumber(value: values.count.isMultiple(of: 2) ? 0 : 1))
        })
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        let rows = try #require(tracks["rows"] as? [[String: Any]])
        #expect(tracks["coverage"] as? String == "unstable")
        #expect(tracks["reasons"] as? [String] == ["live_population_moved"])
        #expect(rows.first?["hidden"] as? String == "unknown")
        #expect(rows.first?["track_ref"] == nil)
        #expect(values.count >= 6, "all bounded attempts must actually read the changing value")
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        #expect(fixture.reads.helpCount == 0)
    }

    private func hiddenViewFixture(shown: Bool, fault: String? = nil) -> Fixture {
        let fixture = Fixture()
        let split = fixture.builder.element(965_970)
        let headerSplit = fixture.builder.element(965_976)
        let legendSplit = fixture.builder.element(965_977)
        let headerScroll = fixture.builder.element(965_971)
        let legend = fixture.builder.element(965_972)
        let hide = fixture.builder.element(965_973)
        fixture.builder.setRole(split, kAXSplitGroupRole as String)
        fixture.builder.setRole(headerSplit, kAXSplitGroupRole as String)
        fixture.builder.setRole(legendSplit, kAXSplitGroupRole as String)
        fixture.builder.setRole(headerScroll, kAXScrollAreaRole as String)
        fixture.builder.setRole(legend, kAXGroupRole as String)
        fixture.builder.setRole(fixture.rail, kAXGroupRole as String)
        fixture.builder.setAttribute(fixture.rail, kAXDescriptionAttribute as String, "Tracks header")
        fixture.builder.setRole(hide, kAXCheckBoxRole as String)
        fixture.builder.setAttribute(hide, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracks   H")
        fixture.builder.setAttribute(hide, kAXValueAttribute as String, NSNumber(value: shown ? 1 : 0))
        fixture.builder.setAttribute(hide, kAXWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(fixture.header, kAXParentAttribute as String, fixture.rail)
        fixture.builder.setAttribute(fixture.rail, kAXParentAttribute as String, headerScroll)
        fixture.builder.setAttribute(split, kAXParentAttribute as String, fixture.window)
        fixture.builder.setChildren(headerScroll, [fixture.rail])
        fixture.builder.setChildren(legend, [hide])
        fixture.builder.setChildren(headerSplit, [headerScroll])
        fixture.builder.setChildren(legendSplit, [legend])
        fixture.builder.setChildren(split, [legendSplit, headerSplit])
        fixture.builder.setChildren(fixture.window, [split])
        switch fault {
        case "nonbinary": fixture.builder.setAttribute(hide, kAXValueAttribute as String, NSNumber(value: 2))
        case "fractional": fixture.builder.setAttribute(hide, kAXValueAttribute as String, NSNumber(value: 0.5))
        case "duplicate":
            let other = fixture.builder.element(965_974)
            fixture.builder.setRole(other, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(other, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracks   H")
            fixture.builder.setAttribute(other, kAXValueAttribute as String, NSNumber(value: 0))
            fixture.builder.setAttribute(other, kAXWindowAttribute as String, fixture.window)
            fixture.builder.setChildren(legend, [hide, other])
        case "wrong_window": fixture.builder.setAttribute(hide, kAXWindowAttribute as String, fixture.builder.element(965_975))
        case "wrong_parent": fixture.builder.setAttribute(split, kAXParentAttribute as String, fixture.builder.element(965_975))
        case "wrong_description": fixture.builder.setAttribute(hide, kAXDescriptionAttribute as String, "Other Show/Hide Hidden Tracks")
        case "label_extension": fixture.builder.setAttribute(hide, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracksuit")
        case "other_mode": fixture.builder.setAttribute(hide, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracks Other Mode")
        case "missing_parent": fixture.builder.removeAttribute(fixture.header, kAXParentAttribute as String)
        case "absent_control": fixture.builder.setChildren(legend, [])
        default: break
        }
        return fixture
    }

    @Test("Whole population needs a real all-shown single-page end, not merely saved count agreement",
          arguments: ["complete", "complete_bottom", "flat_hierarchy", "flat_hierarchy_no_navigation", "flat_hierarchy_bottom",
                      "flat_hierarchy_hidden", "flat_hierarchy_count_gap", "flat_hierarchy_open_stack",
                      "hidden", "scrollable", "scrolled", "negative_scroll", "out_of_range_scroll", "nonfinite_scroll", "infinite_scroll", "offscreen", "missing_row",
                      "unreadable_enabled", "foreign_scrollbar", "duplicate_scrollbar",
                      "late_scrollbar_retirement", "late_frame_loss", "late_scrollbar_role", "late_hidden_view",
                      "late_scrollbar_orientation", "late_scrollbar_parent", "late_scrollbar_window",
                      "paired_complete", "paired_null_fallback", "paired_legacy", "paired_missing",
                      "paired_position_type", "paired_size_type", "paired_position_kind", "paired_failure", "paired_short",
                      "paired_late_frame_loss", "paired_late_scrollbar_retirement"])
    func registeredSinglePageTrackPopulationEnd(caseName: String) async throws {
        let frameMode = caseName.hasPrefix("paired_") ? String(caseName.dropFirst("paired_".count)) : nil
        let fault = frameMode.map { ["complete", "null_fallback", "legacy"].contains($0) ? "complete" : $0 } ?? caseName
        let frameReads = frameMode.map { _ in Reads() }
        let f = hiddenViewFixture(shown: fault != "hidden" && fault != "flat_hierarchy_hidden")
        let second = f.builder.element(965_990), workspace = f.builder.element(965_991)
        let content = f.builder.element(965_992), vertical = f.builder.element(965_993)
        for (i, header) in [f.header, second].enumerated() {
            f.builder.setRole(header, kAXLayoutItemRole as String)
            f.builder.setAttribute(header, kAXTitleAttribute as String, "Track \(i + 1)")
            f.builder.setAttribute(header, kAXDescriptionAttribute as String, "Track \(i + 1) “Track \(i + 1)”")
            f.builder.setAttribute(header, kAXSelectedAttribute as String, false)
            f.builder.setFrame(header, x: 0, y: CGFloat(i * 40), width: 200, height: 40)
            f.builder.setChildren(header, [])
        }
        f.builder.setChildren(f.rail, fault == "missing_row" ? [f.header] : [f.header, second])
        if fault == "flat_hierarchy_open_stack" {
            let disclosure = f.builder.element(965_996)
            f.builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
            f.builder.setAttribute(disclosure, kAXValueAttribute as String, NSNumber(value: 1))
            f.builder.setChildren(f.header, [disclosure])
        }
        let headerScroll = f.builder.element(965_971), headerSplit = f.builder.element(965_976)
        f.builder.setFrame(headerScroll, x: 0, y: 0, width: 200, height: 200)
        f.builder.setRole(workspace, kAXScrollAreaRole as String)
        f.builder.setFrame(workspace, x: 200, y: 0, width: 400, height: 200)
        f.builder.setRole(content, kAXGroupRole as String)
        f.builder.setAttribute(content, kAXDescriptionAttribute as String, "Tracks contents")
        f.builder.setChildren(content, [])
        f.builder.setRole(vertical, kAXScrollBarRole as String)
        f.builder.setAttribute(vertical, kAXOrientationAttribute as String, kAXVerticalOrientationValue as String)
        f.builder.setAttribute(vertical, kAXEnabledAttribute as String, NSNumber(value: fault == "scrollable"))
        let scrollValue: Double
        switch fault {
        case "scrolled": scrollValue = 0.5
        case "complete_bottom", "flat_hierarchy_bottom": scrollValue = 1
        case "negative_scroll": scrollValue = -1
        case "out_of_range_scroll": scrollValue = 2
        case "nonfinite_scroll": scrollValue = .nan
        case "infinite_scroll": scrollValue = .infinity
        default: scrollValue = 0
        }
        f.builder.setAttribute(vertical, kAXValueAttribute as String, NSNumber(value: scrollValue))
        f.builder.setAttribute(vertical, kAXWindowAttribute as String, f.window)
        f.builder.setChildren(vertical, [])
        f.builder.setChildren(workspace, [content, vertical])
        f.builder.setChildren(headerSplit, [headerScroll, workspace])
        if fault == "offscreen" { f.builder.setFrame(second, x: 0, y: 190, width: 200, height: 40) }
        if fault == "foreign_scrollbar" {
            f.builder.setAttribute(vertical, kAXWindowAttribute as String, f.builder.element(965_994))
        }
        if fault == "duplicate_scrollbar" {
            let other = f.builder.element(965_995)
            f.builder.setRole(other, kAXScrollBarRole as String)
            f.builder.setAttribute(other, kAXOrientationAttribute as String, kAXVerticalOrientationValue as String)
            f.builder.setAttribute(other, kAXEnabledAttribute as String, NSNumber(value: false))
            f.builder.setAttribute(other, kAXValueAttribute as String, NSNumber(value: 0))
            f.builder.setChildren(other, [])
            f.builder.setChildren(workspace, [content, vertical, other])
        }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lpm965-single-page-\(UUID().uuidString).logicx")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundle) }
        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, bundle.absoluteString)
        let metadata = try PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": fault == "flat_hierarchy_count_gap" ? 3 : 2], format: .xml, options: 0)
        let reader = LogicProjectFileReader.Runtime(currentDocumentPath: { nil }, now: Date.init,
            readPlistData: { _ in metadata }, mtime: { _ in Date(timeIntervalSince1970: 0) }, sleep: { _ in })
        let endBoundaryReads = Reads()
        let flatHierarchy = fault.hasPrefix("flat_hierarchy")
        let result = try await inspect(fixture: f, domains: flatHierarchy ? ["tracks", "hierarchy"] : ["tracks"],
            navigation: fault == "flat_hierarchy", fileReader: reader,
            frameReads: frameReads, frameFault: frameMode,
            readingAttribute: { element, attribute in
                if fault == "unreadable_enabled", CFEqual(element, vertical), attribute == kAXEnabledAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if fault.hasPrefix("late_"), CFEqual(element, vertical), attribute == kAXValueAttribute as String {
                    endBoundaryReads.record("deciding_value")
                    if endBoundaryReads.count == 3 {
                        if fault == "late_frame_loss" {
                            f.builder.setFrame(second, x: 0, y: 190, width: 200, height: 40)
                        } else if fault == "late_scrollbar_role" {
                            f.builder.setRole(vertical, kAXButtonRole as String)
                        } else if fault == "late_hidden_view" {
                            f.builder.setAttribute(f.builder.element(965_973), kAXValueAttribute as String, NSNumber(value: 0))
                        } else if fault == "late_scrollbar_orientation" {
                            f.builder.setAttribute(vertical, kAXOrientationAttribute as String, kAXHorizontalOrientationValue as String)
                        } else if fault == "late_scrollbar_parent" {
                            f.builder.setAttribute(vertical, kAXParentAttribute as String, f.builder.element(965_994))
                        } else if fault == "late_scrollbar_window" {
                            f.builder.setAttribute(vertical, kAXWindowAttribute as String, f.builder.element(965_994))
                        } else {
                            let replacement = f.builder.element(965_995)
                            f.builder.setRole(replacement, kAXScrollBarRole as String)
                            f.builder.setAttribute(replacement, kAXOrientationAttribute as String, kAXVerticalOrientationValue as String)
                            f.builder.setAttribute(replacement, kAXEnabledAttribute as String, NSNumber(value: false))
                            f.builder.setAttribute(replacement, kAXValueAttribute as String, NSNumber(value: 0))
                            f.builder.setChildren(replacement, [])
                            f.builder.setChildren(workspace, [content, replacement])
                        }
                    }
                    return .success(NSNumber(value: 0))
                }
                return nil
            })
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        let witnesses = try #require(tracks["witnesses"] as? [String: Any])
        let completeFlat = fault == "flat_hierarchy" || fault == "flat_hierarchy_no_navigation" || fault == "flat_hierarchy_bottom"
        if fault == "complete" || fault == "complete_bottom" || completeFlat || fault == "flat_hierarchy_open_stack" {
            #expect(tracks["coverage"] as? String == "complete", "A real one-page end must be usable, not unconditional count-only partial coverage")
            #expect(witnesses["population_end_source"] as? String == "ax_all_shown_single_page")
        } else {
            #expect(tracks["coverage"] as? String != "complete")
        }
        if completeFlat {
            let hierarchy = try #require(body["hierarchy"] as? [String: Any])
            #expect(hierarchy["coverage"] as? String == "complete")
            #expect(hierarchy["reasons"] as? [String] == [])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.count == 2)
            for row in rows {
                #expect(row["parent"] is NSNull)
                #expect(row["depth"] as? Int == 0)
                #expect(row["parent_source"] as? String == "ax_complete_flat_population")
                #expect(row["depth_source"] as? String == "ax_complete_flat_population")
                #expect(row["track_ref"] as? String != nil)
            }
        } else if flatHierarchy {
            let hierarchy = try #require(body["hierarchy"] as? [String: Any])
            #expect(hierarchy["coverage"] as? String != "complete")
            for row in try #require(tracks["rows"] as? [[String: Any]]) {
                #expect(row["parent"] as? String == "unknown")
                #expect(row["depth"] as? String == "unknown")
                #expect(row["parent_source"] == nil && row["depth_source"] == nil)
            }
        }
        if fault.hasPrefix("late_") { #expect(endBoundaryReads.count >= 3, "Actually execute the deciding final end read") }
        if let frameReads {
            let batches = frameReads.recorded.filter { $0 == "frame_batch" }.count
            let singles = frameReads.recorded.filter { $0 == "frame_single" }.count
            if frameMode == "legacy" {
                #expect(batches == 0 && singles == 36, "Keep every independent frame sample on non-batch runtimes")
            } else {
                #expect(batches > 0, "Reach the actual paired geometry reader, not merely inject an unused batch")
                if frameMode == "complete" || frameMode == "null_fallback" {
                    #expect(batches == 18, "Both geometry observations of all three elements remain in all three coverage bookends")
                    #expect(singles == (frameMode == "null_fallback" ? 36 : 0))
                }
            }
        }
        #expect(f.events.recorded.isEmpty && f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
        #expect(f.reads.helpCount == 0)
    }

    @Test("permitted hidden-track observation captures hidden members and restores the current rail", arguments: [false, true])
    func registeredHiddenViewObservationCapturesAndRestoresMembership(needsWindowServerBootstrap: Bool) async throws {
        try await observeHiddenView(needsWindowServerBootstrap: needsWindowServerBootstrap)
    }

    @Test func registeredHiddenViewUsesOnlyTheBoundMenuWhenAnotherApplicationHasKeyboardFocus() async throws {
        try await observeHiddenView(scopedMenu: true)
    }

    @Test func registeredHiddenViewRestoresPresentationButDoesNotReviveRecycledSelectionIdentity() async throws {
        try await observeHiddenView(scopedMenu: true, recycledSelection: true)
    }

    @Test(arguments: ["changed_name", "changed_description", "hidden_selection", "missing_hide_flag",
                      "duplicate_name", "foreign_focus", "wrong_hide_window", "nonbinary_hide_flag", "project", "playback"])
    func registeredHiddenPresentationCleanupRefusesChangedOrUnprovenCustody(fault: String) async throws {
        try await observeHiddenView(scopedMenu: true, recycledSelection: true, cleanupFault: fault)
    }

    @Test(arguments: ["inverse_name", "inverse_description"])
    func registeredHiddenCleanupDoesNotCreditChangedInversePresentation(fault: String) async throws {
        try await observeHiddenView(scopedMenu: true, recycledSelection: true, cleanupFault: fault)
    }

    @Test(arguments: ["document", "window", "cleanup_document", "cleanup_window"])
    func registeredHiddenMenuRejectsTargetSwitchDuringFinalMenuRead(fault: String) async throws {
        try await observeHiddenView(scopedMenu: true, recycledSelection: fault.hasPrefix("cleanup_"), menuBoundaryFault: fault)
    }

    @Test(arguments: ["document", "window", "cleanup_document", "cleanup_window"], [2, 3])
    func registeredHiddenMenuRejectsTargetSwitchInTheStopCallbackAfterItsScopeRead(fault: String, callback: Int) async throws {
        try await observeHiddenView(scopedMenu: true, recycledSelection: fault.hasPrefix("cleanup_"),
                                   lateMenuStopFault: fault, lateMenuStopCallback: callback)
    }

    private func observeHiddenView(needsWindowServerBootstrap: Bool = false, scopedMenu: Bool = false,
                                   recycledSelection: Bool = false, cleanupFault: String? = nil,
                                   menuBoundaryFault: String? = nil, lateMenuStopFault: String? = nil,
                                   lateMenuStopCallback: Int = 2) async throws {
        let fixture = hiddenViewFixture(shown: false)
        let hide = fixture.builder.element(965_973)
        let hidden = fixture.builder.element(965_978)
        fixture.builder.setRole(hidden, kAXLayoutItemRole as String)
        fixture.builder.setAttribute(hidden, kAXTitleAttribute as String, "Known hidden track")
        fixture.builder.setAttribute(hidden, kAXSelectedAttribute as String, false)
        fixture.builder.setAttribute(hidden, kAXParentAttribute as String, fixture.rail)
        fixture.builder.setChildren(hidden, [])
        if recycledSelection {
            fixture.builder.setAttribute(fixture.header, kAXDescriptionAttribute as String, "Track 2 “ Fresh track ”")
            fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, true)
        }
        let anchor = fixture.builder.element(965_989)
        if recycledSelection {
            fixture.builder.setRole(anchor, kAXLayoutItemRole as String)
            fixture.builder.setAttribute(anchor, kAXTitleAttribute as String, "Anchor")
            fixture.builder.setAttribute(anchor, kAXDescriptionAttribute as String, "Track 1 “Anchor”")
            fixture.builder.setAttribute(anchor, kAXSelectedAttribute as String, false)
            fixture.builder.setChildren(anchor, [])
            fixture.builder.setChildren(fixture.rail, [anchor, fixture.header])
        }
        fixture.builder.setFrame(hide, x: 10, y: 20, width: 12, height: 12)
        fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [AXUIElement]())
        fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, [fixture.window])
        fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.rail)
        fixture.builder.setAttribute(fixture.rail, kAXWindowAttribute as String, fixture.window)
        fixture.builder.setAttributeSettable(fixture.rail, kAXFocusedAttribute as String, true)
        fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, true)
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lpm965-hidden-\(UUID().uuidString).logicx")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundle) }
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, bundle.absoluteString)
        let bar = fixture.builder.element(965_979)
        fixture.builder.setRole(bar, kAXGroupRole as String)
        fixture.builder.setAttribute(bar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
        let play = fixture.builder.element(965_980), record = fixture.builder.element(965_981)
        for (control, labels) in [(play, AXLocalePolicy.transportPlayControl), (record, AXLocalePolicy.transportRecordControl)] {
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, labels.canonical)
            fixture.builder.setAttribute(control, kAXValueAttribute as String, 0)
            fixture.builder.setChildren(control, [])
        }
        fixture.builder.setChildren(bar, [play, record])
        let split = fixture.builder.element(965_970)
        fixture.builder.setChildren(fixture.window, [split, bar])
        let toggle = fixture.builder.element(965_986)
        if scopedMenu {
            let menuBar = fixture.builder.element(965_983)
            let track = fixture.builder.element(965_984)
            let menu = fixture.builder.element(965_985)
            fixture.builder.setRole(menuBar, kAXMenuBarRole as String)
            fixture.builder.setRole(track, kAXMenuBarItemRole as String)
            fixture.builder.setAttribute(track, kAXTitleAttribute as String, "Track")
            fixture.builder.setRole(menu, kAXMenuRole as String)
            fixture.builder.setRole(toggle, kAXMenuItemRole as String)
            fixture.builder.setAttribute(toggle, kAXTitleAttribute as String, "Toggle Hide View")
            fixture.builder.setAttribute(toggle, kAXEnabledAttribute as String, true)
            fixture.builder.setActionNames(toggle, [kAXPressAction as String])
            fixture.builder.setChildren(menu, [toggle])
            fixture.builder.setChildren(track, [menu])
            fixture.builder.setChildren(menuBar, [track])
            fixture.builder.setAttribute(fixture.app, kAXMenuBarAttribute as String, menuBar)
        }
        let mouse = AXMouseHelper.Runtime(postMouseEvent: { type, point, clicks in
            if scopedMenu { Issue.record("bound menu acquisition must never post global mouse events"); return false }
            guard point == CGPoint(x: 16, y: 26), clicks == 1,
                  type == .leftMouseDown || type == .leftMouseUp else {
                Issue.record("unrelated hidden-view gesture"); return false
            }
            fixture.events.record(type == .leftMouseDown ? "hidden_down" : "hidden_up")
            if type == .leftMouseUp {
                let shown = (fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                fixture.builder.setAttribute(hide, kAXValueAttribute as String, shown ? 0 : 1)
                fixture.builder.setChildren(fixture.rail, shown ? [fixture.header] : [fixture.header, hidden])
            }
            return true
        }, postKeyEvent: { _ in Issue.record("no key fallback"); return false },
           postUnicodeScalar: { _ in Issue.record("no typing"); return false }, sleepMicros: { _ in })
        let cache = StateCache(), gate = LogicMutationGate()
        let menuReads = Reads()
        let lateScopeReads = Reads()
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
            poller: StatePoller(axChannel: fixture.channel(observationMouse: mouse, hiddenControl: hide,
                needsWindowServerBootstrap: needsWindowServerBootstrap, focusedPID: scopedMenu ? 7777 : 4242,
                observationAction: { element, action in
                    guard scopedMenu, CFEqual(element, toggle), action == kAXPressAction as String else { return nil }
                    fixture.events.record("hidden_menu")
                    let shown = (fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                    fixture.builder.setAttribute(hide, kAXValueAttribute as String, shown ? 0 : 1)
                    if recycledSelection {
                        fixture.builder.setAttribute(fixture.header, kAXTitleAttribute as String, shown ? " Fresh track " : "Known hidden track")
                        fixture.builder.setAttribute(fixture.header, kAXDescriptionAttribute as String,
                            shown ? "Track 2 “ Fresh track ”" : "Track 1 “Known hidden track”")
                        if shown, cleanupFault == "inverse_name" {
                            fixture.builder.setAttribute(fixture.header, kAXTitleAttribute as String, "Changed by inverse")
                        }
                        if shown, cleanupFault == "inverse_description" {
                            fixture.builder.setAttribute(fixture.header, kAXDescriptionAttribute as String, "Track 99 “ Fresh track ”")
                        }
                        fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, shown)
                        fixture.builder.setAttribute(hidden, kAXTitleAttribute as String, " Fresh track ")
                        fixture.builder.setAttribute(hidden, kAXDescriptionAttribute as String, "Track 2 “ Fresh track ”")
                        fixture.builder.setAttribute(hidden, kAXSelectedAttribute as String, true)
                        let flag = fixture.builder.element(965_988)
                        fixture.builder.setRole(flag, kAXCheckBoxRole as String)
                        fixture.builder.setAttribute(flag, kAXDescriptionAttribute as String, "Hide Track")
                        fixture.builder.setAttribute(flag, kAXValueAttribute as String, 0)
                        fixture.builder.setAttribute(flag, kAXWindowAttribute as String, fixture.window)
                        fixture.builder.setChildren(hidden, [flag])
                        if !shown {
                            switch cleanupFault {
                            case "changed_name": fixture.builder.setAttribute(hidden, kAXTitleAttribute as String, "Changed")
                                fixture.builder.setAttribute(hidden, kAXDescriptionAttribute as String, "Track 2 “Changed”")
                            case "changed_description": fixture.builder.setAttribute(hidden, kAXDescriptionAttribute as String, "Track 99 “ Fresh track ”")
                            case "hidden_selection": fixture.builder.setAttribute(flag, kAXValueAttribute as String, 1)
                            case "missing_hide_flag": fixture.builder.setChildren(hidden, [])
                            case "duplicate_name": fixture.builder.setAttribute(anchor, kAXTitleAttribute as String, " Fresh track ")
                                fixture.builder.setAttribute(anchor, kAXDescriptionAttribute as String, "Track 1 “ Fresh track ”")
                            case "foreign_focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                                fixture.builder.element(965_990))
                            case "wrong_hide_window": fixture.builder.setAttribute(flag, kAXWindowAttribute as String,
                                fixture.builder.element(965_991))
                            case "nonbinary_hide_flag": fixture.builder.setAttribute(flag, kAXValueAttribute as String, NSNumber(value: 0.5))
                            case "project": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            case "playback": fixture.builder.setAttribute(play, kAXValueAttribute as String, 1)
                            default: break
                            }
                        }
                    }
                    fixture.builder.setChildren(fixture.rail, recycledSelection
                        ? (shown ? [anchor, fixture.header] : [anchor, fixture.header, hidden])
                        : (shown ? [fixture.header] : [fixture.header, hidden]))
                    return true
                }, readingAttribute: { element, attribute in
                    guard menuBoundaryFault != nil || lateMenuStopFault != nil,
                          CFEqual(element, toggle), attribute == kAXEnabledAttribute as String else { return nil }
                    menuReads.record("enabled")
                    if menuBoundaryFault != nil, menuReads.count == (menuBoundaryFault?.hasPrefix("cleanup_") == true ? 12 : 5) {
                        if menuBoundaryFault?.hasSuffix("document") == true {
                            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        } else {
                            let other = fixture.builder.element(965_992)
                            fixture.builder.setAttribute(fixture.app, kAXMainWindowAttribute as String, other)
                            fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, other)
                        }
                    }
                    return .success(NSNumber(value: true))
                }), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable, keyboardFocus: {
                    if let lateMenuStopFault,
                       menuReads.count >= (lateMenuStopFault.hasPrefix("cleanup_") ? 12 : 5),
                       fixture.events.count == (lateMenuStopFault.hasPrefix("cleanup_") ? 1 : 0),
                       !lateScopeReads.recorded.contains("scope_switched_in_stop") {
                        lateScopeReads.record("stop_callback")
                        guard lateScopeReads.count == lateMenuStopCallback else { return .notTextEditing }
                        lateScopeReads.record("scope_switched_in_stop")
                        if lateMenuStopFault.hasSuffix("document") {
                            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        } else {
                            let foreign = fixture.builder.element(965_992)
                            fixture.builder.setAttribute(fixture.app, kAXMainWindowAttribute as String, foreign)
                            fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, foreign)
                        }
                    }
                    return .notTextEditing
                })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array([.string("tracks")]), "allow_ui_navigation": .bool(true)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        if let lateMenuStopFault {
            let injected = lateScopeReads.recorded.contains("scope_switched_in_stop")
            #expect(injected)
            let cleanup = lateMenuStopFault.hasPrefix("cleanup_")
            #expect(fixture.events.recorded == (cleanup ? ["hidden_menu"] : []),
                    "the stop callback cannot authorize app-global AXPress after its document/window changes")
            #expect((fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == (cleanup ? 1 : 0))
            #expect(fixture.builder.setCalls.isEmpty)
            return
        }
        if menuBoundaryFault != nil {
            let cleanup = menuBoundaryFault?.hasPrefix("cleanup_") == true
            #expect(menuReads.count >= (cleanup ? 12 : 5), "the switch must occur in the final held-menu reread")
            #expect(fixture.events.recorded == (cleanup ? ["hidden_menu"] : []), "an app-global menu leaf must not act on a switched document")
            #expect((fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == (cleanup ? 1 : 0))
            #expect(fixture.builder.setCalls.isEmpty)
            return
        }
        let inverseFault = cleanupFault == "inverse_name" || cleanupFault == "inverse_description"
        if recycledSelection {
            if body["state"] as? String == "C" {
                #expect(body["snapshot_id"] == nil)
                #expect(body["tracks"] == nil)
            } else {
                // Retaining a diagnostic report is not stable row authority.
                let tracks = try #require(body["tracks"] as? [String: Any])
                #expect(tracks["coverage"] as? String == "unstable")
                let rows = try #require(tracks["rows"] as? [[String: Any]])
                #expect(rows.allSatisfy { $0["track_ref"] == nil })
                if cleanupFault == nil { #expect(rows.compactMap { $0["name"] as? String } == ["Anchor", "Known hidden track", " Fresh track "]) }
            }
        } else {
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.compactMap { $0["name"] as? String } == [" Fresh track ", "Known hidden track"])
            #expect(tracks["coverage"] as? String == "partial", "physical acquisition does not invent an end witness")
        }
        let effects = try #require(body["ui_effects"] as? [String: Any])
        #expect(try #require(effects["navigation_performed"] as? Bool))
        if cleanupFault == nil { #expect(effects["restoration"] as? String == "restored") }
        else { #expect(effects["restoration"] as? String != "restored") }
        #expect(fixture.events.recorded == (scopedMenu ? (cleanupFault == nil || inverseFault ? ["hidden_menu", "hidden_menu"] : ["hidden_menu"]) : ["hidden_down", "hidden_up", "hidden_down", "hidden_up"]))
        #expect((fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == (cleanupFault == nil || inverseFault ? 0 : 1))
        if cleanupFault == nil {
            #expect(await cache.getTracks().map(\.name) == (recycledSelection ? [] : [" Fresh track "]),
                "unstable capture must not refresh ordinary cache; temporary hidden members are never current cache rows")
        }
        #expect(fixture.builder.setCalls.isEmpty)
        if scopedMenu {
            // The injected action handler records the exact held leaf above;
            // FakeAXRuntimeBuilder's default action log is bypassed by it.
            #expect(fixture.events.recorded.count == (cleanupFault == nil || inverseFault ? 2 : 1))
            #expect(fixture.reads.recorded.contains(kAXMenuBarAttribute as String))
        } else { #expect(fixture.builder.actionCalls.isEmpty) }
    }

    @Test func hiddenExposureCanRetainAStackOnTheFirstOriginalHeader() {
        let fixture = hiddenViewFixture(shown: true)
        let hide = fixture.builder.element(965_973)
        let triangle = fixture.builder.element(965_982)
        fixture.builder.setRole(triangle, kAXDisclosureTriangleRole as String)
        fixture.builder.setAttribute(triangle, kAXValueAttribute as String, 1)
        fixture.builder.setChildren(fixture.header, [triangle])
        let ax = fixture.builder.makeAXRuntime(appElement: fixture.app)
        let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("no keys") },
            focusedApplicationPID: { 4242 }, observeFrontmost: nil)
        let scope = AXTrackBinding.Exposure(header: fixture.header, disclosure: hide, runtime: logic,
            originalHeaders: [fixture.header], hiddenViewWindow: fixture.window)
        #expect(scope.isCurrent)
        #expect(scope.retainAcquiredDisclosure(header: fixture.header, disclosure: triangle))
        #expect(!scope.retainAcquiredDisclosure(header: fixture.header, disclosure: triangle), "a real stack must still be unique")
        #expect(scope.isCurrent)
        fixture.builder.setAttribute(triangle, kAXValueAttribute as String, 0)
        #expect(!scope.isCurrent, "the first stack's loss must end hidden exposure too")
        fixture.builder.setAttribute(triangle, kAXValueAttribute as String, 1)
        #expect(!scope.isCurrent, "a later open cannot renew observed loss")
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test("permitted stack observation exposes real descendants but restores the current cache rail",
          arguments: [false, true])
    func registeredStackObservationDistinguishesCapturedAndRestoredMembership(navigation: Bool) async throws {
        try await observeStack(navigation: navigation, initiallyExpanded: false)
    }

    @Test func registeredHiddenViewSampleCannotRenewAnEndedStackInverse() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, hiddenViewLoss: true)
    }

    @Test("an already expanded rail really exposes all forty-two fixture headers without navigation")
    func registeredAlreadyExpandedStackReadsActualFullFixtureRail() async throws {
        try await observeStack(navigation: false, initiallyExpanded: true)
    }

    @Test func registeredStackKeepsOriginalReferenceAndEndsDescendantReference() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, verifyReferences: true)
    }

    @Test func registeredSingleStackKnownClosedExposureCannotReopenItsOldInverse() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, knownOuterReopen: true)
    }

    @Test func registeredSingleStackSampledReplacementCannotRestoreItsOldDisclosureInverse() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, knownOuterReplacement: true)
    }

    @Test(arguments: ["competing", "role_loss"])
    func registeredSingleStackUsesTheActuallyDecidingDisclosureIdentity(disclosureDecision: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            knownOuterReplacement: true, disclosureDecision: disclosureDecision)
    }

    @Test func registeredNestedStackObservationCapturesGrandchildrenAndEndsTheirExposure() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, verifyReferences: true, nested: true)
    }

    @Test(arguments: [false, true])
    func registeredHierarchyPublishesOnlyHeldDisclosureMembership(nested: Bool) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: nested,
            verifyHierarchy: true)
    }

    @Test(arguments: [false, true])
    func registeredHierarchyRetainsDirectChildrenOnlyWhenRevealedStacksWereClosed(nested: Bool) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: nested,
            verifyHierarchy: true, verifyDirectChildren: true)
    }

    @Test("A complete population and every stack's actual direct children establish the whole forest",
          arguments: [false, true], ["complete", "complete_bottom", "count_gap", "offscreen"])
    func registeredCompleteStackHierarchy(nested: Bool, fault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: nested,
            verifyHierarchy: true, verifyDirectChildren: true, completeHierarchy: fault)
    }

    @Test("A complete visible population cannot fill an unobserved stack's direct children",
          arguments: ["open", "boolean"])
    func registeredCompletePopulationStillNeedsEveryDirectStackObservation(child: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            verifyHierarchy: true, verifyDirectChildren: true, revealedStack: child, completeHierarchy: "complete")
    }

    @Test(arguments: ["open", "boolean", "late_open"])
    func registeredHierarchyDoesNotPromoteAnOpenOrUntypedChildStackToDirectMembership(child: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            verifyHierarchy: true, verifyDirectChildren: true, revealedStack: child)
    }

    @Test(arguments: [false, true])
    func registeredHierarchyDoesNotInferMembershipFromVisibleRowOrder(expanded: Bool) async throws {
        try await observeStack(navigation: false, initiallyExpanded: expanded, verifyHierarchy: true)
    }

    @Test(arguments: ["inner_closed", "replacement", "focus", "project", "viewport", "cancel", "deadline"])
    func registeredHierarchyDiscardsUnrestoredOrConflictedExposure(fault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            nestedFault: fault, verifyHierarchy: true)
    }

    @Test func registeredStackReadsItsOriginalNoneditablePassiveName() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, headerFocus: "initial_passive")
    }

    @Test func registeredMixerInclusiveStackReadsItsOriginalNoneditablePassiveName() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: "initial_passive", includeStrips: true)
    }

    @Test func registeredFullDomainStackAvoidsFocusMovingHeaderHelpBeforeItsFirstGesture() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true)
    }

    @Test func registeredFullDomainNestedStackObservesExposedHeaderAssociationsAndRestores() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true)
    }

    @Test(arguments: ["editing", "inverse"])
    func registeredExposedStackAssociationsRequirePassiveCustodyAndOriginalSelectionInverse(fault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainAssociationFault: fault)
    }

    @Test func registeredNestedFullDomainMixerEndUsesOwnedPhysicalFocusAndRestoresPassiveHeader() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true)
    }

    @Test func registeredMixerEndFocusACKWithoutEffectUsesOnlyTheHeldBlankStrip() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, mixerFocusACKHasNoEffect: true)
    }

    @Test func registeredOwnedMixerFocusClickRequiresItsActualLandingBeforeReading() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, mixerFocusACKHasNoEffect: true,
            mixerFocusClickDelayed: true)
    }

    @Test func registeredPassiveHeaderReturnDoesNotAXFocusAnInlineRenameEditor() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, headerFocusSetterOpensEditor: true)
    }

    @Test func registeredHeaderReturnACKWithoutActualFocusCannotCertifyRestoration() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, headerHelpHasNoEffect: true)
    }

    @Test func registeredHeaderReturnUsesOnlyTheRetainedPassiveFieldClick() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, headerFocusSetterOpensEditor: true,
            headerReturnClick: "complete")
    }

    @Test(arguments: ["wrong_hit", "changed_hit", "up_failed", "no_landing"])
    func registeredHeaderClickRefusesWrongHitIncompleteReleaseAndNoLanding(_ fault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, headerFocusSetterOpensEditor: true,
            headerReturnClick: fault)
    }

    @Test func registeredHeaderReturnPreservesOnlyItsOriginalSelection() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, headerFocusSetterOpensEditor: true,
            headerReturnSelection: "complete")
    }

    @Test(arguments: ["declined", "no_landing", "selection_conflict"])
    func registeredHeaderReturnRequiresActualLandingAndUnchangedSelection(_ fault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, headerFocusSetterOpensEditor: true,
            headerReturnSelection: fault)
    }

    @Test(arguments: ["wrong_hit", "changed_hit", "up_failed", "click_no_effect"])
    func registeredMixerFocusFallbackRefusesUnownedHitsIncompleteReleaseAndNoLanding(_ fault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, mixerFocusACKHasNoEffect: true,
            mixerFocusClickFault: fault)
    }

    @Test(arguments: ["unsettable_inverse", "edited_label", "foreign_focus", "declined_inverse"])
    func registeredNestedMixerEndCannotCertifyLostOrUnrestorableOriginalFocus(_ fault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "initial_passive", completeHierarchy: "complete", fullDomainMixerOpen: true,
            fullDomainAssociation: true, fullDomainMixerEnd: true, mixerEndFault: fault)
    }

    @Test(arguments: ["initial_editable", "initial_insertion", "initial_foreign", "initial_range",
        "initial_alias", "initial_string", "initial_value", "initial_wrong_window"])
    func registeredStackInitialFocusExceptionCannotAcquireAnEditorOrOtherField(focus: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, headerFocus: focus)
    }

    @Test(arguments: ["initial_editable", "initial_insertion", "initial_foreign", "initial_range",
        "initial_alias", "initial_string", "initial_value", "initial_wrong_window"])
    func registeredMixerInclusiveInitialFocusStillRefusesAnEditorOrOtherField(focus: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: focus, includeStrips: true)
    }

    @Test(arguments: [false, true])
    func registeredSiblingStacksCaptureAllDeclaredRowsAndRestoreOrdinaryCache(navigation: Bool) async throws {
        try await observeSiblingStacks(navigation: navigation)
    }

    @Test(arguments: ["closed", "role_loss", "replacement"])
    func registeredSiblingOwnershipLossCannotResumeAnOldInverse(loss: String) async throws {
        try await observeSiblingStacks(navigation: true, ownershipLoss: loss)
    }

    @Test(arguments: ["closed", "role_loss", "replacement"])
    func registeredSiblingLateDecidingLossCannotResumeAnOldInverse(loss: String) async throws {
        try await observeSiblingStacks(navigation: true, lateOwnershipLoss: loss)
    }

    @Test(arguments: ["role_loss", "replacement"])
    func registeredSiblingPostReleaseCensusLossCannotResumeAnOldInverse(loss: String) async throws {
        try await observeSiblingStacks(navigation: true, postReleaseOwnershipLoss: loss)
    }

    @Test(arguments: ["role_loss", "replacement"])
    func registeredSiblingCollectorCensusLossCannotResumeAnOldInverse(loss: String) async throws {
        try await observeSiblingStacks(navigation: true, postReleaseOwnershipLoss: "collector_" + loss)
    }

    @Test(arguments: ["role_loss", "replacement"])
    func registeredSiblingViewportCensusLossCannotResumeAnOldInverse(loss: String) async throws {
        try await observeSiblingStacks(navigation: true, postReleaseOwnershipLoss: "viewport_" + loss)
    }

    @Test(arguments: ["transport_role_loss", "transport_replacement", "mixer_role_loss", "mixer_replacement"])
    func registeredSiblingPresentationCensusLossCannotResumeAnOldInverse(loss: String) async throws {
        try await observeSiblingStacks(navigation: true, postReleaseOwnershipLoss: loss)
    }

    @Test func registeredSiblingPassiveRowLossCannotResumeAnOldInverse() async throws {
        try await observeSiblingStacks(navigation: true, postReleaseOwnershipLoss: "row_role_loss")
    }

    @Test func registeredSiblingAutomationRowLossCannotResumeAnOldInverse() async throws {
        try await observeSiblingStacks(navigation: true, postReleaseOwnershipLoss: "row_automation_role_loss")
    }

    @Test func registeredNewlyRevealedSiblingDisclosuresAcquireEveryHeldChild() async throws {
        try await observeSiblingStacks(navigation: true, siblingCase: "revealed")
    }

    @Test(arguments: ["alias", "wrong_hit", "release_expansion", "release_restoration", "cancel", "recycled"])
    func registeredSiblingTraversalPreservesControlCustody(siblingCase: String) async throws {
        try await observeSiblingStacks(navigation: true, siblingCase: siblingCase)
    }

    private func observeSiblingStacks(navigation: Bool, ownershipLoss: String? = nil, siblingCase: String? = nil,
                                      lateOwnershipLoss: String? = nil, postReleaseOwnershipLoss: String? = nil) async throws {
        let fixture = Fixture()
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lpm965-siblings-\(UUID().uuidString).logicx")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let headers = (0..<32).map { fixture.builder.element(965_500 + $0) }
        let first = fixture.builder.element(965_550)
        let second = fixture.builder.element(965_551)
        let replacement = fixture.builder.element(965_552)
        let third = fixture.builder.element(965_553)
        let revealed = siblingCase == "revealed"
        fixture.builder.setRole(replacement, kAXDisclosureTriangleRole as String)
        fixture.builder.setAttribute(replacement, kAXValueAttribute as String, 1)
        for (target, x, y) in [(first, 10.0, 20.0), (second, 20.0, 30.0), (third, 30.0, 40.0)] {
            fixture.builder.setRole(target, kAXDisclosureTriangleRole as String)
            fixture.builder.setAttribute(target, kAXValueAttribute as String, 0)
            fixture.builder.setFrame(target, x: x, y: y, width: 12, height: 12)
        }
        for (index, header) in headers.enumerated() {
            fixture.builder.setRole(header, kAXLayoutItemRole as String)
            fixture.builder.setAttribute(header, kAXTitleAttribute as String,
                index == 1 || index == 17 ? "Repeated sibling child" : "Sibling track \(index + 1)")
            fixture.builder.setAttribute(header, kAXSelectedAttribute as String, index == 0)
            fixture.builder.setChildren(header, index == 0 ? [first]
                : index == (revealed ? 1 : 16) ? [siblingCase == "alias" ? first : second]
                : revealed && index == 16 ? [third] : [])
        }
        let original = headers.enumerated().filter {
            revealed ? !(1...23).contains($0.offset) : !(1...7).contains($0.offset) && !(17...23).contains($0.offset)
        }.map(\.element)
        #expect(original.count == (revealed ? 9 : 18))
        fixture.builder.setChildren(fixture.rail, original)
        fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, [fixture.window])
        fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.rail)
        fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, true)
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, bundle.absoluteString)
        let controlBar = fixture.builder.element(965_560)
        let play = fixture.builder.element(965_561)
        let record = fixture.builder.element(965_562)
        fixture.builder.setRole(controlBar, kAXGroupRole as String)
        fixture.builder.setAttribute(controlBar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
        for (control, labels) in [(play, AXLocalePolicy.transportPlayControl), (record, AXLocalePolicy.transportRecordControl)] {
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, labels.canonical)
            fixture.builder.setAttribute(control, kAXValueAttribute as String, 0)
        }
        fixture.builder.setChildren(controlBar, [play, record])
        fixture.builder.setChildren(fixture.window, [fixture.rail, controlBar])
        let collectorLoss = postReleaseOwnershipLoss?.hasPrefix("collector_") == true
        let viewportLoss = postReleaseOwnershipLoss?.hasPrefix("viewport_") == true
        let transportLoss = postReleaseOwnershipLoss?.hasPrefix("transport_") == true
        let mixerLoss = postReleaseOwnershipLoss?.hasPrefix("mixer_") == true
        let rowLoss = postReleaseOwnershipLoss?.hasPrefix("row_") == true
        let automationRowLoss = postReleaseOwnershipLoss?.hasPrefix("row_automation_") == true
        let censusLossKind = collectorLoss ? postReleaseOwnershipLoss?.dropFirst("collector_".count).description
            : viewportLoss ? postReleaseOwnershipLoss?.dropFirst("viewport_".count).description
            : transportLoss ? postReleaseOwnershipLoss?.dropFirst("transport_".count).description
            : mixerLoss ? postReleaseOwnershipLoss?.dropFirst("mixer_".count).description
            : automationRowLoss ? postReleaseOwnershipLoss?.dropFirst("row_automation_".count).description
            : rowLoss ? postReleaseOwnershipLoss?.dropFirst("row_".count).description : postReleaseOwnershipLoss
        let mouse = AXMouseHelper.Runtime(postMouseEvent: { type, point, clicks in
            let isSecond = point == CGPoint(x: 26, y: 36)
            let isThird = revealed && point == CGPoint(x: 36, y: 46)
            guard clicks == 1, point == CGPoint(x: 16, y: 26) || isSecond || isThird,
                  type == .leftMouseDown || type == .leftMouseUp else {
                Issue.record("unexpected sibling observation event"); return false
            }
            fixture.events.record((isThird ? "third_" : isSecond ? "second_" : "first_") + (type == .leftMouseDown ? "down" : "up"))
            if type == .leftMouseUp, isSecond,
               (siblingCase == "release_expansion" && fixture.events.count == 4)
                || (siblingCase == "release_restoration" && fixture.events.count == 6) {
                fixture.reads.record("sibling_release_unposted")
                return false
            }
            if type == .leftMouseUp {
                let target = isThird ? third : isSecond ? second : first
                let open = (fixture.builder.attributeValue(target, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                fixture.builder.setAttribute(target, kAXValueAttribute as String, open ? 0 : 1)
                let firstOpen = (fixture.builder.attributeValue(first, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                let secondOpen = (fixture.builder.attributeValue(second, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                let thirdOpen = (fixture.builder.attributeValue(third, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                fixture.builder.setChildren(fixture.rail, headers.enumerated().filter {
                    if revealed {
                        return (firstOpen || !(1...23).contains($0.offset))
                            && (secondOpen || !(2...7).contains($0.offset))
                            && (thirdOpen || !(17...23).contains($0.offset))
                    }
                    return
                    (firstOpen || !(1...7).contains($0.offset)) && (secondOpen || !(17...23).contains($0.offset))
                }.map(\.element))
                if let censusLossKind, !collectorLoss, !viewportLoss, !transportLoss, !mixerLoss, !rowLoss, fixture.events.count == 4 {
                    fixture.reads.record("post_release_loss_installed")
                    if censusLossKind == "role_loss" { fixture.builder.setRole(first, kAXButtonRole as String) }
                    if censusLossKind == "replacement" { fixture.builder.setChildren(headers[0], [replacement]) }
                }
            }
            return true
        }, postKeyEvent: { _ in Issue.record("fixture forbids keys"); return false },
           postUnicodeScalar: { _ in Issue.record("fixture forbids typing"); return false }, sleepMicros: { _ in })
        let channel = fixture.channel(disclosure: first, additionalDisclosure: second,
            thirdDisclosure: revealed ? third : nil, wrongAdditionalDisclosureHit: siblingCase == "wrong_hit", observationMouse: mouse,
            observingAttribute: { element, attribute in
                if collectorLoss || viewportLoss || transportLoss || mixerLoss || rowLoss, fixture.events.count == 4,
                   !fixture.reads.recorded.contains("post_release_loss_installed") {
                    if CFEqual(element, second), attribute == kAXValueAttribute as String {
                        fixture.reads.record("collector_value_read")
                    }
                    if transportLoss, CFEqual(element, controlBar), attribute == kAXRoleAttribute as String,
                       fixture.reads.recorded.filter({ $0 == "collector_value_read" }).count >= 2 {
                        fixture.reads.record("transport_scan_ready")
                    }
                    if mixerLoss, CFEqual(element, headers[31]), attribute == kAXTitleAttribute as String,
                       fixture.reads.recorded.filter({ $0 == "collector_value_read" }).count >= 2,
                       !fixture.reads.recorded.contains("mixer_scan_ready") {
                        fixture.reads.record("mixer_scan_ready")
                    }
                    if rowLoss, CFEqual(element, first), attribute == kAXValueAttribute as String,
                       fixture.reads.recorded.filter({ $0 == "collector_value_read" }).count >= 2,
                       (fixture.builder.attributeValue(first, attribute) as? NSNumber)?.intValue == 1,
                       !fixture.reads.recorded.contains("row_stack_open") {
                        fixture.reads.record("row_stack_open")
                    }
                    if fixture.reads.recorded.filter({ $0 == "collector_value_read" }).count >= 2,
                       (collectorLoss && CFEqual(element, fixture.window) && attribute == kAXTitleAttribute as String)
                        || ((viewportLoss || (transportLoss && fixture.reads.recorded.contains("transport_scan_ready"))
                            || (mixerLoss && fixture.reads.recorded.contains("mixer_scan_ready"))
                            || (rowLoss && fixture.reads.recorded.contains("row_stack_open")
                                && (!automationRowLoss || fixture.reads.recorded.contains("row_automation_ready"))))
                            && censusLossKind == "role_loss" && CFEqual(element, first) && attribute == kAXRoleAttribute as String) {
                        fixture.reads.record("post_release_loss_installed")
                        if censusLossKind == "role_loss" { fixture.builder.setRole(first, kAXButtonRole as String) }
                        if censusLossKind == "replacement" { fixture.builder.setChildren(headers[0], [replacement]) }
                    }
                }
                if censusLossKind == "role_loss", CFEqual(element, first),
                   attribute == kAXRoleAttribute as String,
                   fixture.builder.attributeValue(first, attribute) as? String == kAXButtonRole as String,
                   !fixture.reads.recorded.contains("post_release_loss_actually_sampled") {
                    fixture.reads.record("post_release_loss_actually_sampled")
                }
                if automationRowLoss, CFEqual(element, headers[1]), attribute == kAXTitleAttribute as String,
                   fixture.reads.recorded.contains("post_release_loss_actually_sampled"),
                   !fixture.reads.recorded.contains("post_release_loss_returned") {
                    fixture.builder.setRole(first, kAXDisclosureTriangleRole as String)
                    fixture.reads.record("row_automation_recovery")
                    fixture.reads.record("post_release_loss_returned")
                }
                if let lateOwnershipLoss, fixture.events.count == 2 {
                    if CFEqual(element, second), attribute == kAXPositionAttribute as String,
                       !fixture.reads.recorded.contains("late_loss_armed") {
                        fixture.reads.record("late_loss_armed")
                    }
                    if fixture.reads.recorded.contains("late_loss_armed"),
                       !fixture.reads.recorded.contains("late_loss_installed") {
                        if CFEqual(element, first), attribute == kAXValueAttribute as String,
                           (fixture.builder.attributeValue(first, attribute) as? NSNumber)?.intValue == 1,
                           !fixture.reads.recorded.contains("late_loss_early_open") {
                            fixture.reads.record("late_loss_early_open")
                        }
                        if CFEqual(element, fixture.window), attribute == kAXTitleAttribute as String,
                           fixture.reads.recorded.contains("late_loss_early_open") {
                            fixture.reads.record("late_loss_installed")
                            if lateOwnershipLoss == "closed" { fixture.builder.setAttribute(first, kAXValueAttribute as String, 0) }
                            if lateOwnershipLoss == "role_loss" { fixture.builder.setRole(first, kAXButtonRole as String) }
                            if lateOwnershipLoss == "replacement" { fixture.builder.setChildren(headers[0], [replacement]) }
                        }
                    }
                }
                if let lateOwnershipLoss, fixture.reads.recorded.contains("late_loss_installed"),
                   !fixture.reads.recorded.contains("late_loss_returned") {
                    if (lateOwnershipLoss == "closed" && CFEqual(element, first) && attribute == kAXValueAttribute as String
                        && (fixture.builder.attributeValue(first, attribute) as? NSNumber)?.intValue == 0)
                        || (lateOwnershipLoss == "role_loss" && CFEqual(element, first) && attribute == kAXRoleAttribute as String
                            && fixture.builder.attributeValue(first, attribute) as? String == kAXButtonRole as String) {
                        if !fixture.reads.recorded.contains("late_loss_actually_sampled") {
                            fixture.reads.record("late_loss_actually_sampled")
                        }
                    }
                    if fixture.reads.recorded.contains("late_loss_actually_sampled"),
                       CFEqual(element, fixture.window), attribute == kAXTitleAttribute as String {
                        fixture.builder.setAttribute(first, kAXValueAttribute as String, 1)
                        fixture.builder.setRole(first, kAXDisclosureTriangleRole as String)
                        fixture.builder.setChildren(headers[0], [first])
                        fixture.reads.record("late_loss_returned")
                    }
                }
                if let ownershipLoss, fixture.events.count == 2, CFEqual(element, second),
                   attribute == kAXPositionAttribute as String,
                   !fixture.reads.recorded.contains("sibling_loss_installed") {
                    fixture.reads.record("sibling_loss_installed")
                    if ownershipLoss == "closed" { fixture.builder.setAttribute(first, kAXValueAttribute as String, 0) }
                    if ownershipLoss == "role_loss" { fixture.builder.setRole(first, kAXButtonRole as String) }
                    if ownershipLoss == "replacement" { fixture.builder.setChildren(headers[0], [replacement]) }
                }
                if let ownershipLoss, fixture.reads.recorded.contains("sibling_loss_installed"),
                   !fixture.reads.recorded.contains("sibling_loss_returned") {
                    if ownershipLoss == "closed", CFEqual(element, first), attribute == kAXValueAttribute as String,
                       (fixture.builder.attributeValue(first, attribute) as? NSNumber)?.intValue == 0 {
                        fixture.reads.record("sibling_loss_actually_sampled")
                    }
                    if ownershipLoss == "role_loss", CFEqual(element, first), attribute == kAXRoleAttribute as String,
                       fixture.builder.attributeValue(first, attribute) as? String == kAXButtonRole as String {
                        fixture.reads.record("sibling_loss_actually_sampled")
                    }
                    if fixture.reads.recorded.contains("sibling_loss_actually_sampled"),
                       CFEqual(element, fixture.window), attribute == kAXTitleAttribute as String {
                        fixture.builder.setAttribute(first, kAXValueAttribute as String, 1)
                        fixture.builder.setRole(first, kAXDisclosureTriangleRole as String)
                        fixture.builder.setChildren(headers[0], [first])
                        fixture.reads.record("sibling_loss_returned")
                    }
                }
                if attribute == kAXTitleAttribute as String, let index = headers.firstIndex(where: { CFEqual($0, element) }) {
                    fixture.reads.record("sibling_title_\(index)")
                }
            }, observingChildren: { element in
                if viewportLoss || (transportLoss && fixture.reads.recorded.contains("transport_scan_ready"))
                    || (mixerLoss && fixture.reads.recorded.contains("mixer_scan_ready")),
                   censusLossKind == "replacement", CFEqual(element, headers[0]),
                   fixture.events.count == 4,
                   fixture.reads.recorded.filter({ $0 == "collector_value_read" }).count >= 2,
                   !fixture.reads.recorded.contains("post_release_loss_installed") {
                    fixture.builder.setChildren(headers[0], [replacement])
                    fixture.reads.record("post_release_loss_installed")
                }
                if censusLossKind == "replacement", CFEqual(element, headers[0]),
                   fixture.reads.recorded.contains("post_release_loss_installed"),
                   !fixture.reads.recorded.contains("post_release_loss_returned"),
                   !fixture.reads.recorded.contains("post_release_loss_actually_sampled") {
                    let children = fixture.builder.makeAXRuntime().children(headers[0])
                    if children.count == 1, CFEqual(children[0], replacement) {
                        fixture.reads.record("post_release_loss_actually_sampled")
                    }
                }
                if postReleaseOwnershipLoss != nil, CFEqual(element, fixture.rail),
                   fixture.reads.recorded.contains("post_release_loss_actually_sampled"),
                   !fixture.reads.recorded.contains("post_release_loss_returned") {
                    fixture.builder.setRole(first, kAXDisclosureTriangleRole as String)
                    fixture.builder.setChildren(headers[0], [first])
                    fixture.reads.record("post_release_loss_returned")
                }
                if lateOwnershipLoss == "replacement", CFEqual(element, headers[0]),
                   fixture.reads.recorded.contains("late_loss_installed"),
                   !fixture.reads.recorded.contains("late_loss_returned"),
                   !fixture.reads.recorded.contains("late_loss_actually_sampled") {
                    let children = fixture.builder.makeAXRuntime().children(headers[0])
                    if children.count == 1, CFEqual(children[0], replacement) {
                        fixture.reads.record("late_loss_actually_sampled")
                    }
                }
                if ownershipLoss == "replacement", CFEqual(element, headers[0]),
                   fixture.reads.recorded.contains("sibling_loss_installed"),
                   !fixture.reads.recorded.contains("sibling_loss_returned") {
                    let children = fixture.builder.makeAXRuntime().children(headers[0])
                    if children.count == 1, CFEqual(children[0], replacement) {
                        fixture.reads.record("sibling_loss_actually_sampled")
                    }
                }
            }, observingLegacyChildren: { element in
                if automationRowLoss, CFEqual(element, headers[0]),
                   fixture.reads.recorded.contains("row_stack_open"),
                   !fixture.reads.recorded.contains("post_release_loss_installed") {
                    fixture.reads.record("row_legacy_header_read")
                    if fixture.reads.recorded.filter({ $0 == "row_legacy_header_read" }).count == 3 {
                        fixture.reads.record("row_automation_ready")
                    }
                }
                if rowLoss, !automationRowLoss, CFEqual(element, headers[0]),
                   fixture.reads.recorded.contains("post_release_loss_actually_sampled"),
                   !fixture.reads.recorded.contains("post_release_loss_returned") {
                    fixture.builder.setRole(first, kAXDisclosureTriangleRole as String)
                    fixture.reads.record("row_pan_recovery")
                    fixture.reads.record("post_release_loss_returned")
                }
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
        let params: [String: Value] = ["domains": .array([.string("tracks")]), "allow_ui_navigation": .bool(navigation)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) {
                if siblingCase == "cancel", let inherited = OperationTraceContext.current {
                    let context = OperationTraceContext(parentTraceID: inherited.parentTraceID,
                        mutationGateAcquired: inherited.mutationGateAcquired, ownsGate: inherited.ownsGate,
                        deadline: inherited.deadline, cancellationRequested: {
                            inherited.cancellationRequested() || fixture.events.count == 4
                        })
                    return await OperationTraceContext.$current.withValue(context) {
                        await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
                    }
                }
                return await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
            }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        if postReleaseOwnershipLoss != nil {
            if rowLoss {
                let open = try #require(fixture.reads.recorded.firstIndex(of: "row_stack_open"))
                let installed = try #require(fixture.reads.recorded.firstIndex(of: "post_release_loss_installed"))
                let sampled = try #require(fixture.reads.recorded.firstIndex(of: "post_release_loss_actually_sampled"))
                let recovered = try #require(fixture.reads.recorded.firstIndex(of:
                    automationRowLoss ? "row_automation_recovery" : "row_pan_recovery"))
                #expect(open < installed && installed < sampled && sampled < recovered)
                if automationRowLoss {
                    let ready = try #require(fixture.reads.recorded.firstIndex(of: "row_automation_ready"))
                    #expect(open < ready && ready < installed)
                }
            }
            if transportLoss || mixerLoss {
                let ready = try #require(fixture.reads.recorded.firstIndex(of: transportLoss ? "transport_scan_ready" : "mixer_scan_ready"))
                let installed = try #require(fixture.reads.recorded.firstIndex(of: "post_release_loss_installed"))
                #expect(ready < installed)
            }
            #expect(fixture.reads.recorded.filter { $0.hasPrefix("post_release_loss_") } == [
                "post_release_loss_installed", "post_release_loss_actually_sampled", "post_release_loss_returned"
            ])
            #expect(fixture.events.recorded == ["first_down", "first_up", "second_down", "second_up"])
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(await cache.getTracks().isEmpty)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if lateOwnershipLoss != nil {
            #expect(fixture.reads.recorded.filter { $0.hasPrefix("late_loss_") } == [
                "late_loss_armed", "late_loss_early_open", "late_loss_installed",
                "late_loss_actually_sampled", "late_loss_returned"
            ])
            #expect(fixture.events.recorded == ["first_down", "first_up"])
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(await cache.getTracks().isEmpty)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if let siblingCase, ["alias", "wrong_hit", "release_expansion", "release_restoration", "cancel"].contains(siblingCase) {
            let events = siblingCase == "alias" ? [] : siblingCase == "wrong_hit"
                ? ["first_down", "first_up", "first_down", "first_up"]
                : ["first_down", "first_up", "second_down", "second_up"]
                    + (siblingCase == "release_restoration" ? ["second_down", "second_up"] : [])
            #expect(fixture.events.recorded == events)
            let current = await cache.getTracks()
            let effects = try #require(body["ui_effects"] as? [String: Any])
            if siblingCase.hasPrefix("release_") {
                #expect(fixture.reads.recorded.filter { $0 == "sibling_release_unposted" }.count == 1)
                #expect(effects["reason"] as? String == "stack_mouse_release_unverified")
            }
            if siblingCase == "alias" || siblingCase == "wrong_hit" {
                #expect(current.count == original.count)
                let tracks = try #require(body["tracks"] as? [String: Any])
                let rows = try #require(tracks["rows"] as? [[String: Any]])
                #expect(rows.count == (siblingCase == "alias" ? 18 : 25))
                #expect(tracks["coverage"] as? String == "partial")
            } else {
                #expect(current.isEmpty)
                #expect(effects["restoration"] as? String == "not_restored")
            }
            if siblingCase == "cancel" { #expect(body["error"] as? String == "cancelled") }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if ownershipLoss != nil {
            #expect(fixture.reads.recorded.filter { $0 == "sibling_loss_installed" }.count == 1)
            #expect(fixture.reads.recorded.contains("sibling_loss_actually_sampled"))
            #expect(fixture.reads.recorded.filter { $0 == "sibling_loss_returned" }.count == 1)
            #expect(fixture.events.recorded == ["first_down", "first_up"], "sampled loss cannot renew the previous inverse")
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            let current = await cache.getTracks()
            #expect(current.isEmpty)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        let tracks = try #require(body["tracks"] as? [String: Any])
        let rows = try #require(tracks["rows"] as? [[String: Any]])
        let expected = navigation ? headers : original
        #expect(rows.count == expected.count)
        #expect(rows.compactMap { $0["name"] as? String } == expected.compactMap {
            fixture.builder.attributeValue($0, kAXTitleAttribute as String) as? String
        })
        let forward = ["first_down", "first_up", "second_down", "second_up"] + (revealed ? ["third_down", "third_up"] : [])
        let inverse = (revealed ? ["third_down", "third_up"] : []) + ["second_down", "second_up", "first_down", "first_up"]
        #expect(fixture.events.recorded == (navigation ? forward + inverse : []))
        #expect(tracks["coverage"] as? String == "partial", "declared fixture membership is not a global hidden/end witness")
        let current = await cache.getTracks()
        #expect(current.count == original.count)
        #expect(zip(current, original).allSatisfy { state, header in
            state.physicalBinding.map { CFEqual($0.header, header) && $0.exposure == nil } == true
        })
        for target in [first, second] + (revealed ? [third] : []) {
            #expect((fixture.builder.attributeValue(target, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
        }
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
        try #require(rows.count == expected.count)
        for (row, header) in zip(rows, expected) {
            let reference = try #require(row["track_ref"] as? String)
            let binding = try #require(await registry.resolve(TargetReference(rawValue: reference)))
            let physical = try #require(binding.physicalTrack)
            #expect(CFEqual(physical.header, header))
            let index = try #require(headers.firstIndex { CFEqual($0, header) })
            #expect(fixture.reads.recorded.contains("sibling_title_\(index)"))
            if navigation, !original.contains(where: { CFEqual($0, header) }) {
                #expect(physical.exposure != nil && physical.currentIndex() == nil)
            }
        }
        if siblingCase == "recycled" {
            let originalRef = try #require(rows.first?["track_ref"] as? String)
            let originalBinding = try #require(await registry.resolve(TargetReference(rawValue: originalRef)))
            let heldRuntime = try #require(originalBinding.physicalTrack).runtime
            fixture.builder.setChildren(fixture.rail, headers)
            for target in [first, second] { fixture.builder.setAttribute(target, kAXValueAttribute as String, 1) }
            for row in rows where row["name"] as? String == "Repeated sibling child" {
                let reference = try #require(row["track_ref"] as? String)
                let binding = try #require(await registry.resolve(TargetReference(rawValue: reference)))
                let physical = try #require(binding.physicalTrack)
                #expect(physical.currentIndex() == nil, "recycled CF/name/ordinal does not renew ended descendant custody")
            }
            let live = AXTrackBinding.Exposure(header: headers[0], disclosure: first,
                runtime: heldRuntime, originalHeaders: original)
            #expect(live.retainAcquiredDisclosure(header: headers[16], disclosure: second))
            let probe = AXTrackBinding.Binding(window: fixture.window, header: headers[1], document: bundle.absoluteString,
                runtime: heldRuntime, exposure: live)
            #expect(probe.currentIndex() == 1, "same owners permit a genuinely live scope")
            live.end()
            #expect(probe.currentIndex() == nil)
        }
    }

    @Test(arguments: ["down_failed", "held_focus", "held_focus_returned", "wrong_hit", "prepare_failed"])
    func registeredStackPairsOnlyOwnedMouseDownAndUp(mouseCase: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, mouseCase: mouseCase)
    }

    @Test func registeredStackPreservesExpansionFailureWhenPostedPairHasNoObservedEffect() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, mouseCase: "no_effect")
    }

    @Test func registeredStackCompletesPostedDownBeforeObservingUnrelatedTextFocus() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, mouseCase: "unrelated_text_focus")
    }

    @Test func registeredStackWaitsForCompletedPairLandingBeforeCaptureAndRestoration() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, delayedLanding: true)
    }

    @Test(arguments: ["passive", "editable", "insertion", "foreign", "replacement"])
    func registeredStackReadFocusExceptionIsLimitedToItsHeldPassiveLabel(headerFocus: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, headerFocus: headerFocus)
    }

    @Test func registeredPopulationDoesNotReadFocusMovingTrackHelp() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, helpMovesFocus: true)
    }

    @Test func nestedStackRetainsTheSameOwnedOuterPassiveFocusThroughInnerClicks() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "passive", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String)
    }

    @Test func hiddenNestedStackRestoresWorkspaceBeforeHideViewRecyclesItsPassiveLabel() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "passive", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String,
            hiddenView: true)
    }

    @Test(arguments: ["unavailable", "declined", "wrong_readback", "reparented", "foreign_focus", "post_focus_project"])
    func hiddenNestedStackRefusesTheViewInverseWhenOriginalFocusCannotBeVerified(hiddenFocusFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "passive", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String,
            hiddenView: true, hiddenFocusFault: hiddenFocusFault)
    }

    @Test(arguments: [false, true], ["document", "main_window", "focused_window"])
    func stackFocusRestorationRefusesScopeChangedByItsFinalPassiveFocusRead(hiddenView: Bool, lateScopeFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "passive", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String,
            hiddenView: hiddenView, lateScopeFault: lateScopeFault)
    }

    @Test(arguments: ["retained_label_editable", "retained_label_insertion", "retained_label_replacement", "retained_label_foreign"])
    func nestedStackRefusesLostOrEditingPreviouslyAcceptedPassiveFocus(nestedFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            nestedFault: nestedFault, headerFocus: "passive", focusRestoration: "restored",
            originalFocusRole: kAXGroupRole as String)
    }

    @Test(arguments: ["restored", "unavailable", "declined", "wrong_readback", "reparented", "foreign_focus"])
    func registeredStackRestoresOnlyItsHeldWorkspaceFocus(focusRestoration: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: "passive", focusRestoration: focusRestoration)
    }

    @Test(arguments: ["restored", "unavailable", "declined", "wrong_readback", "reparented", "foreign_focus"],
          [kAXLayoutAreaRole as String, kAXGroupRole as String])
    func registeredStackRestoresWorkspaceAfterItsHeldDisclosureTakesFocus(
        focusRestoration: String, originalFocusRole: String
    ) async throws {
        // Native Logic can leave focus on the exact clicked disclosure after
        // a successful expand/collapse, rather than on its passive label.
        try await observeStack(navigation: true, initiallyExpanded: false,
            mouseCase: "held_focus", focusRestoration: focusRestoration,
            originalFocusRole: originalFocusRole)
    }

    @Test(arguments: [false, true])
    func registeredStackRestoresWorkspaceAfterItsHeldHeaderTakesFocus(nested: Bool) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, mouseCase: "held_header_focus",
            nested: nested, focusRestoration: "restored")
    }

    @Test(arguments: ["restored", "unavailable", "declined", "wrong_readback", "reparented", "foreign_focus"])
    func registeredStackRestoresOnlyItsOriginalOwnedContainerFocus(focusRestoration: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: "passive", focusRestoration: focusRestoration, originalFocusRole: kAXGroupRole as String)
    }

    @Test(arguments: ["radio_held", "radio_with_name"])
    func registeredStackRestoresWorkspaceAfterItsHeldRadioTakesFocus(headerFocus: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: headerFocus, focusRestoration: "restored")
    }

    @Test func registeredStackRestoresAfterItsUnchangedPreheldSliderTakesFocus() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: "slider_held", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String)
    }

    @Test func registeredStackRefusesSliderChangedByTheLastPreInverseMetadataRead() async throws {
        let calibration = Reads()
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: "slider_held", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String,
            sliderMetadataObservations: calibration)
        let boundary = try #require(calibration.recorded.first(where: { $0.hasPrefix("inverse_boundary_") }))
        let finalRead = try #require(Int(boundary.dropFirst("inverse_boundary_".count)))
        #expect(finalRead > 0)
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: "slider_final_changed", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String,
            sliderMetadataObservations: Reads(), sliderMutationAt: finalRead)
    }

    @Test func registeredStackRetainsPreheldPassiveFocusWhenOwnershipReadsMoveIt() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: "slider_to_label", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String)
    }

    @Test func nestedStackRetainsPassiveFocusAcceptedByItsOwnershipRead() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            headerFocus: "slider_to_label", focusRestoration: "restored",
            originalFocusRole: kAXLayoutAreaRole as String, retainOwnershipReadFocus: true)
    }

    @Test func registeredStackRefusesForeignPassiveLabelAfterOwnershipReads() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: "slider_to_foreign_label", focusRestoration: "restored", originalFocusRole: kAXGroupRole as String)
    }

    @Test(arguments: ["slider_foreign", "slider_replacement", "slider_changed", "slider_insertion", "slider_text", "slider_late_changed"])
    func registeredStackRefusesLostOrEditingSliderFocus(headerFocus: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false,
            headerFocus: headerFocus, focusRestoration: "restored", originalFocusRole: kAXGroupRole as String)
    }

    @Test(arguments: ["radio_foreign", "radio_replacement", "radio_ambiguous", "radio_ambiguous_late", "radio_editable", "radio_changed", "radio_unknown", "radio_role", "radio_role_sample"])
    func registeredStackDoesNotAdoptUnownedOrChangedRadioFocus(headerFocus: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, headerFocus: headerFocus)
    }

    @Test func finalPreDownStopDoesNotReportNavigationThatNeverPosted() async throws {
        try await observeFinalPreDownStop()
    }

    @Test(arguments: ["document", "main_window", "focused_window", "foreground_pid", "logic_pid",
                      "cleanup_document", "cleanup_main_window", "cleanup_focused_window",
                      "cleanup_foreground_pid", "cleanup_logic_pid"], [5, 6])
    func finalPreDownScopeSwitchCannotPostAgainstAnotherTarget(fault: String, callback: Int) async throws {
        try await observeFinalPreDownStop(fault: fault, callback: callback)
    }

    private func observeFinalPreDownStop(fault: String? = nil, callback: Int = 6) async throws {
        let cleanup = fault?.hasPrefix("cleanup_") == true
        // Restore first checks the acquired entry's ownership, adding two stop
        // callbacks before click's own two ownership passes and final callbacks.
        let switchingCallback = callback + (cleanup ? 2 : 0)
        let f = Fixture()
        let disclosure = f.builder.element(965_700)
        f.builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
        f.builder.setAttribute(disclosure, kAXValueAttribute as String, 0)
        f.builder.setFrame(disclosure, x: 10, y: 20, width: 12, height: 12)
        f.builder.setChildren(f.header, [disclosure])
        f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [f.window])
        f.builder.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.window)
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.rail)
        f.builder.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/late-stop.logicx")
        let bar = f.builder.element(965_701)
        f.builder.setRole(bar, kAXGroupRole as String)
        f.builder.setAttribute(bar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
        let play = f.builder.element(965_702), record = f.builder.element(965_703)
        for (control, labels) in [(play, AXLocalePolicy.transportPlayControl), (record, AXLocalePolicy.transportRecordControl)] {
            f.builder.setRole(control, kAXCheckBoxRole as String)
            f.builder.setAttribute(control, kAXDescriptionAttribute as String, labels.canonical)
            f.builder.setAttribute(control, kAXValueAttribute as String, 0)
        }
        f.builder.setChildren(bar, [play, record])
        f.builder.setChildren(f.window, [f.rail, bar])
        f.builder.setAttribute(f.app, "fixture_logic_pid", NSNumber(value: 4242))
        f.builder.setAttribute(f.app, "fixture_foreground_pid", NSNumber(value: 4242))
        let logic = AXLogicProElements.Runtime(logicProPID: {
            (f.builder.attributeValue(f.app, "fixture_logic_pid") as? NSNumber).map { pid_t($0.int32Value) }
        },
            ax: f.builder.makeAXRuntime(appElement: f.app,
                setAttributeHandler: { _, _, _ in Issue.record("no AX setters"); return false },
                performActionHandler: { _, _ in Issue.record("no AX actions"); return false },
                elementAtPosition: { _, _ in .success(disclosure) }),
            executeAppleScript: { _ in Issue.record("no scripts"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("no Escape") }, focusedApplicationPID: {
                (f.builder.attributeValue(f.app, "fixture_foreground_pid") as? NSNumber).map { pid_t($0.int32Value) }
            })
        let mouse = AXMouseHelper.Runtime(postMouseEvent: { type, _, _ in
            f.events.record("post")
            if cleanup, type == .leftMouseUp {
                let shown = (f.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                f.builder.setAttribute(disclosure, kAXValueAttribute as String, NSNumber(value: shown ? 0 : 1))
            }
            return true
        },
            postKeyEvent: { _ in false }, postUnicodeScalar: { _ in false }, sleepMicros: { _ in })
        let checks = Reads()
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let stop: @Sendable () -> Bool = {
            checks.record("stop")
            if let fault, checks.count == switchingCallback {
                f.reads.record("scope_switched_in_stop")
                if fault.hasSuffix("foreground_pid") {
                    f.builder.setAttribute(f.app, "fixture_foreground_pid", NSNumber(value: 8888))
                } else if fault.hasSuffix("logic_pid") {
                    f.builder.setAttribute(f.app, "fixture_logic_pid", NSNumber(value: 4343))
                } else if fault.hasSuffix("document") {
                    f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                } else {
                    let other = f.builder.element(965_704)
                    f.builder.setAttribute(f.app, fault.hasSuffix("main_window")
                        ? kAXMainWindowAttribute as String : kAXFocusedWindowAttribute as String, other)
                }
            }
            return fault == nil && checks.count == callback
        }
        let effects = try await OperationTraceContext.$current.withValue(context) {
            let candidate = AccessibilityChannel.OwnedTrackStackObservationNavigation(
                window: f.window, logic: logic, mouse: mouse, expectedProject: nil,
                requiresProjectReference: false, referenceIsCurrent: { true })
            let navigation = try #require(candidate)
            if cleanup {
                await navigation.expand(stoppingWhen: { false })
                return await navigation.restore(stoppingWhen: stop)
            }
            await navigation.expand(stoppingWhen: stop)
            return await navigation.restore(stoppingWhen: { false })
        }
        if fault == nil {
            #expect(checks.count == 6, "refuse only at the last pre-Down permission check, after full preflight")
        } else {
            let injected = f.reads.recorded.contains("scope_switched_in_stop")
            #expect(injected, "the late target switch must actually occur before the mouse pair")
        }
        if cleanup {
            #expect(f.events.count == 2, "only the original owned expansion pair may be posted")
            #expect((f.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            #expect(effects.navigationPerformed && effects.restoration == "not_restored")
        } else {
            #expect(f.events.recorded.isEmpty)
            #expect(!effects.navigationPerformed && effects.attempted.isEmpty)
            #expect(effects.restoration == "not_applicable")
        }
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
    func registeredNestedStackNeverRestoresPastACompletedPairWithUnreadFocus(downFocusRead: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, downFocusRead: downFocusRead)
    }

    @Test func registeredNestedStackKnownClosedExposureCannotReopenItsOldInverse() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, knownInnerReopen: true)
    }

    @Test func selectedCensusMissingOwnedHeaderCannotRenewItsOldInverse() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, selectedCensusLoss: true)
    }

    @Test func selectedRailEnumerationMissingOwnedHeaderCannotRenewItsOldInverse() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, selectedEnumerationLoss: true)
    }

    @Test func observedStackExpansionSurvivesLaterForeignFocusRefusalInUIReceipt() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, postAckForeignFocus: true)
    }

    @Test func registeredNestedStackSampledReplacementCannotRestoreItsOldDisclosureInverse() async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, knownInnerReplacement: true)
    }

    @Test(arguments: ["competing", "role_loss"])
    func registeredNestedStackUsesTheActuallyDecidingDisclosureIdentity(disclosureDecision: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true,
            knownInnerReplacement: true, disclosureDecision: disclosureDecision)
    }

    @Test(arguments: ["inner_closed", "replacement"])
    func registeredNestedStackCorroboratesTheRailAfterItsLastGrandchildRead(nestedFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, nestedFault: nestedFault)
    }

    @Test(arguments: ["focus", "project", "viewport"])
    func registeredNestedStackDoesNotReverseOverNewChildCustody(nestedFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, nestedFault: nestedFault)
    }

    @Test(arguments: ["cancel", "deadline", "cancel_read", "cancel_task_read"])
    func registeredNestedStackRestoresOnCancellationButNotAfterDeadline(nestedFault: String) async throws {
        try await observeStack(navigation: true, initiallyExpanded: false, nested: true, nestedFault: nestedFault)
    }

    @Test(arguments: ["cancel_read_focus", "cancel_read_project", "cancel_read_viewport",
                      "cancel_read_control", "cancel_read_gate", "cancel_read_deadline"])
    func cancelledOwnedStackStillRequiresItsOriginalCustody(nestedFault: String) async throws {
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
        let readsBeforeCutoff = fixture.reads.count
        let context = OperationTraceContext(ownsGate: { cutoff != "gate" },
            deadline: cutoff == "deadline" ? ContinuousClock.now : nil,
            cancellationRequested: { cutoff == "cancel" })
        let index = OperationTraceContext.$current.withValue(context) { binding.currentIndex() }
        #expect(index == nil)
        #expect(fixture.reads.count == readsBeforeCutoff, "a live exposure must not read disclosure custody after the operation cutoff")
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
        #expect(Array(atCollapse.prefix(41)) == Array(repeating: 3, count: 41))
        #expect(atCollapse[41] == 3)
        #expect(bookends.counts.allSatisfy { $0 >= 3 })
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
                              downFocusRead: String? = nil, knownOuterReopen: Bool = false,
                              knownOuterReplacement: Bool = false, knownInnerReopen: Bool = false,
                              knownInnerReplacement: Bool = false, disclosureDecision: String? = nil,
                              delayedLanding: Bool = false, headerFocus: String? = nil,
                              helpMovesFocus: Bool = false, focusRestoration: String? = nil,
                              originalFocusRole: String = "AXLayoutArea", includeStrips: Bool = false,
                              hiddenViewLoss: Bool = false, hiddenView: Bool = false,
                              hiddenFocusFault: String? = nil, lateScopeFault: String? = nil,
                              verifyHierarchy: Bool = false, verifyDirectChildren: Bool = false,
                              revealedStack: String? = nil, selectedCensusLoss: Bool = false,
                              selectedEnumerationLoss: Bool = false, postAckForeignFocus: Bool = false,
                              sliderMetadataObservations: Reads? = nil, sliderMutationAt: Int? = nil,
                              completeHierarchy: String? = nil, fullDomainMixerOpen: Bool = false,
                              fullDomainAssociation: Bool = false, fullDomainAssociationFault: String? = nil,
                              fullDomainMixerEnd: Bool = false, mixerEndFault: String? = nil,
                              mixerFocusACKHasNoEffect: Bool = false, mixerFocusClickDelayed: Bool = false,
                              mixerFocusClickFault: String? = nil, headerFocusSetterOpensEditor: Bool = false,
                              headerHelpHasNoEffect: Bool = false, headerReturnSelection: String? = nil,
                              headerReturnClick: String? = nil, retainOwnershipReadFocus: Bool = false) async throws {
        let fixture = Fixture()
        let focusBoundaryReads = Reads()
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lpm965-stack-\(UUID().uuidString).logicx")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let headers = (1...(fullDomainAssociation ? 2 : 42)).map { fixture.builder.element(965_100 + $0) }
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
        let collapsed = fullDomainMixerOpen ? [headers[0]] : [headers[0]] + Array(headers[24...])
        if mouseCase == "held_header_focus" {
            fixture.builder.setAttribute(headers[0], kAXWindowAttribute as String, fixture.window)
        }
        if selectedCensusLoss || selectedEnumerationLoss {
            fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [headers[0]])
        }
        let passiveLabel = fixture.builder.element(965_240)
        let passiveRoleReads = Reads()
        let otherLabel = fixture.builder.element(965_241)
        let workspace = fixture.builder.element(965_242)
        let shownLabel = fixture.builder.element(965_243)
        let hide = fixture.builder.element(965_244)
        let hideMenu = fixture.builder.element(965_245)
        if let focusRestoration {
            fixture.builder.setRole(workspace, originalFocusRole)
            fixture.builder.setAttribute(workspace, kAXWindowAttribute as String, fixture.window)
            fixture.builder.setAttribute(workspace, kAXParentAttribute as String, fixture.window)
            fixture.builder.setAttributeSettable(workspace, kAXFocusedAttribute as String, focusRestoration != "unavailable")
            fixture.builder.setChildren(workspace, [])
        }
        if helpMovesFocus {
            fixture.builder.setRole(otherLabel, kAXTextFieldRole as String)
            fixture.builder.setAttribute(otherLabel, kAXValueAttribute as String, "foreign editor")
        }
        if let headerFocus {
            for label in [passiveLabel, otherLabel] {
                fixture.builder.setRole(label, headerFocus.hasPrefix("slider_") ? kAXSliderRole as String
                    : headerFocus.hasPrefix("radio_") ? kAXRadioButtonRole as String : kAXTextFieldRole as String)
                fixture.builder.setAttribute(label, kAXDescriptionAttribute as String,
                    headerFocus.hasPrefix("radio_") ? "Has Focus" : "Track 1")
                fixture.builder.setAttribute(label, kAXValueAttribute as String,
                    headerFocus.hasPrefix("slider_") ? 173 : headerFocus.hasPrefix("radio_") ? 1 : 0)
                if headerFocus.hasPrefix("slider_") {
                    fixture.builder.setAttributeSettable(label, kAXValueAttribute as String, true)
                }
                fixture.builder.setAttribute(label, kAXWindowAttribute as String, fixture.window)
            }
            if headerFocus == "editable" || headerFocus == "initial_editable" {
                fixture.builder.setAttributeSettable(passiveLabel, kAXValueAttribute as String, true)
                fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, "Track 1")
            }
            if headerFocus == "insertion" || headerFocus == "initial_insertion" {
                fixture.builder.setAttribute(passiveLabel, kAXInsertionPointLineNumberAttribute as String, 0)
            }
            if headerFocus == "initial_range" { fixture.builder.setAttribute(passiveLabel, kAXSelectedTextRangeAttribute as String, 0) }
            if headerFocus == "initial_string" { fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, "0") }
            if headerFocus == "initial_value" { fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, 1) }
            if headerFocus == "initial_wrong_window" {
                fixture.builder.setAttribute(passiveLabel, kAXWindowAttribute as String, fixture.builder.element(965_999))
            }
            if headerFocus != "foreign" { fixture.builder.setChildren(headers[0], [disclosure, passiveLabel]) }
            if headerFocus == "initial_alias" { fixture.builder.setChildren(headers[0], [disclosure, passiveLabel, otherLabel]) }
            if headerFocus == "radio_with_name" {
                fixture.builder.setRole(shownLabel, kAXTextFieldRole as String)
                fixture.builder.setAttribute(shownLabel, kAXValueAttribute as String, 0)
                fixture.builder.setAttribute(shownLabel, kAXWindowAttribute as String, fixture.window)
                fixture.builder.setChildren(headers[0], [disclosure, passiveLabel, shownLabel])
            }
            if headerFocus == "slider_to_label" || headerFocus == "slider_to_foreign_label" {
                fixture.builder.setRole(shownLabel, kAXTextFieldRole as String)
                fixture.builder.setAttribute(shownLabel, kAXValueAttribute as String, 0)
                fixture.builder.setAttribute(shownLabel, kAXWindowAttribute as String, fixture.window)
                if headerFocus == "slider_to_label" {
                    fixture.builder.setChildren(headers[0], [disclosure, passiveLabel, shownLabel])
                }
            }
            if headerFocus == "radio_ambiguous" { fixture.builder.setChildren(headers[0], [disclosure, passiveLabel, otherLabel]) }
            if headerFocus == "radio_editable" { fixture.builder.setAttributeSettable(passiveLabel, kAXValueAttribute as String, true) }
            if headerFocus == "radio_unknown" { fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, "1") }
        }
        let inner = fixture.builder.element(965_220)
        let substitutedDisclosure = fixture.builder.element(965_223)
        fixture.builder.setRole(substitutedDisclosure, kAXDisclosureTriangleRole as String)
        fixture.builder.setAttribute(substitutedDisclosure, kAXValueAttribute as String, 1)
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
        if let revealedStack, revealedStack != "late_open" {
            fixture.builder.setRole(inner, kAXDisclosureTriangleRole as String)
            fixture.builder.setAttribute(inner, kAXValueAttribute as String,
                revealedStack == "boolean" ? NSNumber(value: true) : NSNumber(value: 1))
            fixture.builder.setChildren(headers[1], [inner])
        }
        fixture.builder.setChildren(fixture.rail, initiallyExpanded ? headers : collapsed)
        if hiddenViewLoss || hiddenView {
            fixture.builder.setRole(fixture.rail, kAXGroupRole as String)
            fixture.builder.setAttribute(fixture.rail, kAXDescriptionAttribute as String, "Tracks header")
        }
        fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, [fixture.window])
        fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                                     focusRestoration == nil ? fixture.rail : workspace)
        if let headerFocus, headerFocus.hasPrefix("initial_") {
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                headerFocus == "initial_foreign" ? otherLabel : passiveLabel)
        }
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
        fixture.builder.setChildren(fixture.window, [fixture.rail, controlBar]
            + (nestedFault == "viewport" || nestedFault == "cancel_read_viewport" ? [scrollbar] : []) + (focusRestoration == nil ? [] : [workspace]))
        if hiddenView {
            fixture.builder.setRole(shownLabel, kAXTextFieldRole as String)
            fixture.builder.setAttribute(shownLabel, kAXDescriptionAttribute as String, "Track 1")
            fixture.builder.setAttribute(shownLabel, kAXValueAttribute as String, 0)
            fixture.builder.setAttribute(shownLabel, kAXWindowAttribute as String, fixture.window)
            let split = fixture.builder.element(965_246), legendSplit = fixture.builder.element(965_247)
            let headerSplit = fixture.builder.element(965_248), scroll = fixture.builder.element(965_249)
            let legend = fixture.builder.element(965_250)
            for element in [split, legendSplit, headerSplit] { fixture.builder.setRole(element, kAXSplitGroupRole as String) }
            fixture.builder.setRole(scroll, kAXScrollAreaRole as String)
            fixture.builder.setRole(legend, kAXGroupRole as String)
            fixture.builder.setRole(hide, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(hide, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracks   H")
            fixture.builder.setAttribute(hide, kAXValueAttribute as String, 0)
            fixture.builder.setAttribute(hide, kAXWindowAttribute as String, fixture.window)
            fixture.builder.setChildren(legend, [hide]); fixture.builder.setChildren(scroll, [fixture.rail])
            fixture.builder.setChildren(legendSplit, [legend]); fixture.builder.setChildren(headerSplit, [scroll])
            fixture.builder.setChildren(split, [legendSplit, headerSplit])
            fixture.builder.setChildren(fixture.window, [split, controlBar, workspace])
            for header in headers { fixture.builder.setAttribute(header, kAXParentAttribute as String, fixture.rail) }
            let menuBar = fixture.builder.element(965_251), trackMenu = fixture.builder.element(965_252)
            let menu = fixture.builder.element(965_253)
            fixture.builder.setRole(menuBar, kAXMenuBarRole as String)
            fixture.builder.setRole(trackMenu, kAXMenuBarItemRole as String)
            fixture.builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
            fixture.builder.setRole(menu, kAXMenuRole as String)
            fixture.builder.setRole(hideMenu, kAXMenuItemRole as String)
            fixture.builder.setAttribute(hideMenu, kAXTitleAttribute as String, "Toggle Hide View")
            fixture.builder.setAttribute(hideMenu, kAXEnabledAttribute as String, true)
            fixture.builder.setActionNames(hideMenu, [kAXPressAction as String])
            fixture.builder.setChildren(menu, [hideMenu]); fixture.builder.setChildren(trackMenu, [menu])
            fixture.builder.setChildren(menuBar, [trackMenu])
            fixture.builder.setAttribute(fixture.app, kAXMenuBarAttribute as String, menuBar)
        }
        if let completeHierarchy {
            // The same real end scaffold as the registered flat-population test,
            // now around actual owned outer/inner disclosure transitions.
            let split = fixture.builder.element(965_246), legendSplit = fixture.builder.element(965_247)
            let headerSplit = fixture.builder.element(965_248), scroll = fixture.builder.element(965_249)
            let legend = fixture.builder.element(965_250), pageWorkspace = fixture.builder.element(965_258)
            let content = fixture.builder.element(965_259), vertical = fixture.builder.element(965_260)
            for element in [split, legendSplit, headerSplit] { fixture.builder.setRole(element, kAXSplitGroupRole as String) }
            fixture.builder.setRole(fixture.rail, kAXGroupRole as String)
            fixture.builder.setAttribute(fixture.rail, kAXDescriptionAttribute as String, "Tracks header")
            fixture.builder.setRole(scroll, kAXScrollAreaRole as String)
            fixture.builder.setFrame(scroll, x: 0, y: 0, width: 200, height: 2000)
            for (index, header) in fullyExposed.enumerated() {
                fixture.builder.setFrame(header, x: 0, y: CGFloat(index * 40), width: 200, height: 40)
            }
            if completeHierarchy == "offscreen" {
                fixture.builder.setFrame(headers.last!, x: 0, y: 1990, width: 200, height: 40)
            }
            fixture.builder.setRole(legend, kAXGroupRole as String)
            fixture.builder.setRole(hide, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(hide, kAXDescriptionAttribute as String, "Show/Hide Hidden Tracks   H")
            fixture.builder.setAttribute(hide, kAXValueAttribute as String, NSNumber(value: 1))
            fixture.builder.setAttribute(hide, kAXWindowAttribute as String, fixture.window)
            fixture.builder.setChildren(legend, [hide]); fixture.builder.setChildren(scroll, [fixture.rail])
            fixture.builder.setRole(pageWorkspace, kAXScrollAreaRole as String)
            fixture.builder.setRole(content, kAXGroupRole as String)
            fixture.builder.setAttribute(content, kAXDescriptionAttribute as String, "Tracks contents")
            fixture.builder.setChildren(content, [])
            fixture.builder.setRole(vertical, kAXScrollBarRole as String)
            fixture.builder.setAttribute(vertical, kAXOrientationAttribute as String, kAXVerticalOrientationValue as String)
            fixture.builder.setAttribute(vertical, kAXEnabledAttribute as String, NSNumber(value: false))
            fixture.builder.setAttribute(vertical, kAXValueAttribute as String, NSNumber(value: completeHierarchy == "complete_bottom" ? 1 : 0))
            fixture.builder.setAttribute(vertical, kAXWindowAttribute as String, fixture.window)
            fixture.builder.setChildren(vertical, []); fixture.builder.setChildren(pageWorkspace, [content, vertical])
            fixture.builder.setChildren(legendSplit, [legend]); fixture.builder.setChildren(headerSplit, [scroll, pageWorkspace])
            fixture.builder.setChildren(split, [legendSplit, headerSplit]); fixture.builder.setChildren(fixture.window, [split, controlBar])
        }
        let exposedMixer = fixture.builder.element(965_270)
        let exposedStrips = (0..<9).map { fixture.builder.element(965_271 + $0) }
        let associationStripIndices = [5, 1, 7, 3]
        let endFocusPoint = CGPoint(x: CGFloat((associationStripIndices[0] + 1) * 80 + 40), y: 500)
        let headerReturnPoint = CGPoint(x: 70, y: 109)
        let endEdit = fixture.builder.element(965_310), endSelectAll = fixture.builder.element(965_311)
        let returnEditor = fixture.builder.element(965_390)
        if headerFocusSetterOpensEditor {
            #expect(!CFEqual(returnEditor, passiveLabel))
            fixture.builder.setRole(returnEditor, kAXTextFieldRole as String)
            fixture.builder.setAttribute(returnEditor, kAXValueAttribute as String, "Original stack")
            fixture.builder.setAttributeSettable(returnEditor, kAXValueAttribute as String, true)
            fixture.builder.setAttribute(returnEditor, kAXInsertionPointLineNumberAttribute as String, 0)
            fixture.builder.setAttribute(returnEditor, kAXNumberOfCharactersAttribute as String, 14)
            fixture.builder.setAttribute(returnEditor, kAXSelectedTextAttribute as String, "Original stack")
            fixture.builder.setAttribute(returnEditor, kAXParentAttribute as String, fixture.window)
            fixture.builder.setAttribute(returnEditor, kAXWindowAttribute as String, fixture.window)
        }
        if fullDomainMixerOpen {
            // Native-style named Mixer, with no legacy AXIdentifier shortcut.
            // The one exposed root cannot initialize the two-header association.
            let mixer = exposedMixer
            fixture.builder.setRole(mixer, "AXLayoutArea")
            fixture.builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
            let strips = exposedStrips
            for (index, strip) in strips.enumerated() {
                fixture.builder.setRole(strip, kAXLayoutItemRole as String)
                fixture.builder.setAttribute(strip, kAXDescriptionAttribute as String, "Physical strip \(index)")
                fixture.builder.setChildren(strip, [])
            }
            fixture.builder.setChildren(mixer, strips)
            let originalChildren = fixture.builder.makeAXRuntime().children(fixture.window)
            fixture.builder.setChildren(fixture.window, originalChildren + [mixer])
            fixture.builder.setAttribute(headers[0], kAXHelpAttribute as String, "Track header. Mute or solo the track.")
            if fullDomainAssociation {
                fixture.builder.setAttribute(exposedMixer, kAXSelectedChildrenAttribute as String,
                    [exposedStrips[associationStripIndices[0]]])
                fixture.builder.setAttributeSettable(fixture.rail, kAXSelectedChildrenAttribute as String, true)
                #expect(fullyExposed.count == associationStripIndices.count)
            }
            #expect(collapsed.count == 1)
            #expect(fixture.builder.makeAXRuntime().children(headers[0]).count == 2)
        }
        if fullDomainMixerEnd {
            let owner = fixture.builder.element(965_300), toolbar = fixture.builder.element(965_301)
            let filters = fixture.builder.element(965_302), menuBar = fixture.builder.element(965_303)
            for element in [owner, toolbar, filters] { fixture.builder.setRole(element, kAXGroupRole as String) }
            for element in [owner, toolbar] { fixture.builder.setAttribute(element, kAXDescriptionAttribute as String, "Mixer") }
            let modes = ["Single", "Tracks", "All"].enumerated().map { index, label -> AXUIElement in
                let control = fixture.builder.element(965_320 + index)
                fixture.builder.setRole(control, kAXRadioButtonRole as String)
                fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, label)
                fixture.builder.setAttribute(control, kAXValueAttribute as String, index == 2 ? 1 : 0)
                fixture.builder.setChildren(control, [])
                return control
            }
            let filterControls = ["Audio", "Inst", "Aux", "Bus", "Input", "Output", "Master/VCA", "MIDI"]
                .enumerated().map { index, label -> AXUIElement in
                    let control = fixture.builder.element(965_330 + index)
                    fixture.builder.setRole(control, kAXCheckBoxRole as String)
                    fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, label)
                    fixture.builder.setAttribute(control, kAXValueAttribute as String, 1)
                    fixture.builder.setChildren(control, [])
                    return control
                }
            fixture.builder.setChildren(filters, filterControls)
            fixture.builder.setChildren(toolbar, modes + [filters])
            fixture.builder.setChildren(owner, [toolbar, exposedMixer])
            let roots = fixture.builder.makeAXRuntime().children(fixture.window).filter { !CFEqual($0, exposedMixer) }
            fixture.builder.setChildren(fixture.window, roots + [owner])
            for (index, element) in ([exposedMixer] + exposedStrips).enumerated() {
                fixture.builder.setFrame(element, x: CGFloat(index * 80), y: 440,
                    width: index == 0 ? 720 : 80, height: 240)
                fixture.builder.setAttribute(element, kAXWindowAttribute as String, fixture.window)
            }
            for strip in exposedStrips {
                fixture.builder.setAttribute(strip, kAXNumberOfCharactersAttribute as String, 0)
                fixture.builder.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, 0)
                fixture.builder.setAttributeSettable(strip, kAXFocusedAttribute as String, true)
            }
            fixture.builder.setAttributeSettable(passiveLabel, kAXFocusedAttribute as String, true)
            fixture.builder.setFrame(passiveLabel, x: 20, y: 100, width: 100, height: 18)
            if mixerEndFault == "unsettable_inverse" {
                fixture.builder.setAttributeSettable(passiveLabel, kAXFocusedAttribute as String, false)
            }
            fixture.builder.setAttribute(exposedMixer, kAXVisibleChildrenAttribute as String, exposedStrips)
            fixture.builder.setAttributeSettable(exposedMixer, kAXSelectedChildrenAttribute as String, true)
            fixture.builder.setRole(menuBar, kAXMenuBarRole as String)
            fixture.builder.setRole(endEdit, kAXMenuBarItemRole as String)
            fixture.builder.setAttribute(endEdit, kAXTitleAttribute as String, "Edit")
            fixture.builder.setAttribute(endEdit, kAXSelectedAttribute as String, false)
            fixture.builder.setActionNames(endEdit, [kAXPressAction as String, kAXCancelAction as String])
            fixture.builder.setRole(endSelectAll, kAXMenuItemRole as String)
            fixture.builder.setAttribute(endSelectAll, kAXIdentifierAttribute as String, "selectAll:")
            fixture.builder.setAttribute(endSelectAll, kAXEnabledAttribute as String, true)
            fixture.builder.setActionNames(endSelectAll, [kAXPressAction as String])
            fixture.builder.setChildren(endSelectAll, [])
            fixture.builder.setChildren(endEdit, [endSelectAll])
            fixture.builder.setChildren(menuBar, [endEdit])
            fixture.builder.setAttribute(fixture.app, kAXMenuBarAttribute as String, menuBar)
        }
        let replacement = fixture.builder.element(965_231)
        fixture.builder.setRole(replacement, kAXLayoutItemRole as String)
        fixture.builder.setAttribute(replacement, kAXTitleAttribute as String, "Repeated grandchild")
        fixture.builder.setAttribute(replacement, kAXSelectedAttribute as String, false)
        fixture.builder.setChildren(replacement, [])
        let preparation: (@Sendable (CGPoint, Int64) -> AXMouseHelper.PreparedMouseClick?)?
        if mouseCase == "prepare_failed" { preparation = { _, _ in nil } }
        else { preparation = nil }
        let observationMouse = AXMouseHelper.Runtime(postMouseEvent: { type, point, clicks in
            if fullDomainMixerEnd, point == headerReturnPoint {
                #expect(clicks == 1 && (type == .leftMouseDown || type == .leftMouseUp))
                fixture.reads.record(type == .leftMouseDown ? "header_return_down" : "header_return_up")
                if type == .leftMouseDown { fixture.reads.record("owned_end_header_focus_inverse") }
                if type == .leftMouseDown, headerReturnClick == "up_failed" {
                    fixture.reads.record("header_return_incomplete_pair_landed")
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, passiveLabel)
                }
                if type == .leftMouseUp {
                    if headerReturnClick == "up_failed" || headerReturnSelection == "declined" { return false }
                    if headerReturnClick != "no_landing", headerReturnSelection != "no_landing",
                       !headerHelpHasNoEffect, mixerEndFault != "declined_inverse" {
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, passiveLabel)
                    }
                }
                return true
            }
            if mixerFocusACKHasNoEffect, point == endFocusPoint {
                #expect(clicks == 1 && (type == .leftMouseDown || type == .leftMouseUp))
                fixture.reads.record(type == .leftMouseDown ? "owned_end_focus_down" : "owned_end_focus_up")
                if mixerFocusClickFault == "up_failed", type == .leftMouseDown {
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                        exposedStrips[associationStripIndices[0]])
                }
                if mixerFocusClickFault == "up_failed", type == .leftMouseUp {
                    fixture.reads.record("owned_focus_click_up_failed"); return false
                }
                if type == .leftMouseUp, !mixerFocusClickDelayed, mixerFocusClickFault != "click_no_effect" {
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                        exposedStrips[associationStripIndices[0]])
                }
                return true
            }
            if type == .leftMouseDown, fixture.events.count == 2, let sliderMetadataObservations {
                sliderMetadataObservations.record("inverse_boundary_\(sliderMetadataObservations.recorded.filter { $0 == "metadata" }.count)")
            }
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
                if let headerFocus {
                    let focused = ["foreign", "replacement", "radio_foreign", "radio_replacement", "slider_foreign", "slider_replacement"].contains(headerFocus) ? otherLabel
                        : hiddenView ? shownLabel : passiveLabel
                    if headerFocus == "replacement" || headerFocus == "radio_replacement" || headerFocus == "slider_replacement" {
                        fixture.builder.setChildren(headers[0], [disclosure, otherLabel])
                    }
                    if headerFocus == "radio_changed" { fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, 0) }
                    if headerFocus == "slider_changed" { fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, 172) }
                    if headerFocus == "slider_insertion" {
                        fixture.builder.setAttribute(passiveLabel, kAXInsertionPointLineNumberAttribute as String, 0)
                    }
                    if headerFocus == "slider_text" {
                        fixture.builder.setAttribute(passiveLabel, kAXSelectedTextAttribute as String, "editing")
                    }
                    if headerFocus == "radio_role" {
                        fixture.builder.setRole(passiveLabel, kAXTextFieldRole as String)
                        fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, 0)
                    }
                    if headerFocus == "radio_ambiguous_late" {
                        fixture.builder.setChildren(headers[0], [disclosure, passiveLabel, otherLabel])
                    }
                    if retainOwnershipReadFocus, eventCount > 2 {
                        fixture.reads.record("ownership_read_focus_retained_during_later_click")
                    } else {
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                            retainOwnershipReadFocus ? disclosure : focused)
                    }
                }
                if mouseCase == "unrelated_text_focus" {
                    fixture.builder.setRole(replacement, kAXTextFieldRole as String)
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, replacement)
                    fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
                    fixture.builder.setChildren(fixture.rail, headers)
                }
                if let downFocusRead, isInner, eventCount == (downFocusRead == "expansion" ? 3 : 5) {
                    fixture.reads.record("true_inner_down")
                }
                if mouseCase == "held_focus" || mouseCase == "held_focus_returned" {
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, disclosure)
                }
                if mouseCase == "held_header_focus" {
                    fixture.reads.record("completed_gesture_focused_original_header")
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, headers[0])
                }
            }
            if type == .leftMouseUp {
                if mouseCase == "no_effect" || mouseCase == "unrelated_text_focus" { return true }
                if mouseCase == "held_focus_returned" {
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.rail)
                }
                let target = isInner ? inner : disclosure
                let expanded = (fixture.builder.attributeValue(target, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                fixture.builder.setAttribute(target, kAXValueAttribute as String, expanded ? 0 : 1)
                fixture.builder.setChildren(fixture.rail, isInner ? (expanded ? headers : fullyExposed)
                    : (expanded ? collapsed : headers))
                if hiddenView, eventCount == 9, let hiddenFocusFault {
                    fixture.reads.record("hidden_focus_fault_boundary")
                    switch hiddenFocusFault {
                    case "unavailable": fixture.builder.setAttributeSettable(workspace, kAXFocusedAttribute as String, false)
                    case "reparented": fixture.builder.setAttribute(workspace, kAXParentAttribute as String, otherLabel)
                    case "foreign_focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, otherLabel)
                    default: break
                    }
                }
                if eventCount == 4, focusRestoration == "reparented" {
                    fixture.builder.setAttribute(workspace, kAXParentAttribute as String, otherLabel)
                }
                if eventCount == 4, focusRestoration == "foreign_focus" {
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, otherLabel)
                }
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
                if isInner, !expanded, let nestedFault, nestedFault.hasPrefix("retained_label_") {
                    fixture.reads.record("child_custody_fault")
                    switch nestedFault {
                    case "retained_label_editable":
                        fixture.builder.setAttributeSettable(passiveLabel, kAXValueAttribute as String, true)
                    case "retained_label_insertion":
                        fixture.builder.setAttribute(passiveLabel, kAXInsertionPointLineNumberAttribute as String, 0)
                    case "retained_label_replacement":
                        fixture.builder.setChildren(headers[0], [disclosure, otherLabel])
                    default:
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, otherLabel)
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
           postUnicodeScalar: { _ in Issue.record("fixture forbids typing"); return false }, sleepMicros: { _ in },
           prepareMouseClick: preparation)
        let cache = StateCache()
        let registry = TargetRegistry()
        let gate = LogicMutationGate()
        let fileReader: LogicProjectFileReader.Runtime = (knownOuterReopen || knownOuterReplacement || knownInnerReopen || knownInnerReplacement) ? .init(
            currentDocumentPath: { nil }, now: Date.init, readPlistData: { _ in nil },
            mtime: { _ in
                if knownOuterReopen || knownOuterReplacement {
                    guard fixture.reads.recorded.contains("outer_extractor_returned_zero")
                        || fixture.reads.recorded.contains("replacement_disclosure_value_read") else { return nil }
                    fixture.reads.record("closed_population_metadata")
                    if fixture.reads.recorded.filter({ $0 == "closed_population_metadata" }).count == 2 {
                        fixture.reads.record("same_outer_reopened_on_retry")
                        fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
                        fixture.builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
                        fixture.builder.setChildren(headers[0], [disclosure])
                        fixture.builder.setChildren(fixture.rail, headers)
                    }
                    return nil
                }
                guard fixture.reads.recorded.contains("inner_extractor_returned_zero")
                    || fixture.reads.recorded.contains("replacement_disclosure_value_read") else { return nil }
                fixture.reads.record("closed_population_metadata")
                if fixture.reads.recorded.filter({ $0 == "closed_population_metadata" }).count == 2 {
                    fixture.reads.record("same_inner_reopened_on_retry")
                    fixture.builder.setAttribute(inner, kAXValueAttribute as String, 1)
                    fixture.builder.setRole(inner, kAXDisclosureTriangleRole as String)
                    fixture.builder.setChildren(headers[1], [inner])
                    fixture.builder.setChildren(fixture.rail, fullyExposed)
                }
                return nil
            }, sleep: { _ in }) : completeHierarchy == nil ? .unavailable : .init(
                currentDocumentPath: { nil }, now: Date.init, readPlistData: { _ in
                    try? PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": fullyExposed.count
                        + (completeHierarchy == "count_gap" ? 1 : 0)], format: .xml, options: 0)
                }, mtime: { _ in Date(timeIntervalSince1970: 0) }, sleep: { _ in })
        let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache, targetRegistry: registry,
            poller: StatePoller(axChannel: fixture.channel(disclosure: disclosure,
                additionalDisclosure: nested ? inner : nil, observationMouse: observationMouse,
                observationAction: { element, action in
                    if fullDomainMixerEnd, CFEqual(element, endEdit) || CFEqual(element, endSelectAll) {
                        let focused = fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String)
                        guard let focused, CFEqual(focused as AnyObject, exposedStrips[associationStripIndices[0]]) else {
                            Issue.record("global Select All must not run from a name field or Arrange context"); return false
                        }
                        if CFEqual(element, endEdit) {
                            fixture.reads.record(action == kAXPressAction as String ? "owned_end_open_edit" : "owned_end_cancel_edit")
                            fixture.builder.setAttribute(endEdit, kAXSelectedAttribute as String, action == kAXPressAction as String)
                        } else {
                            #expect(action == kAXPressAction as String)
                            fixture.reads.record("owned_end_select_all")
                            if mixerEndFault == "edited_label" {
                                fixture.builder.setAttributeSettable(passiveLabel, kAXValueAttribute as String, true)
                                fixture.reads.record("owned_end_fault_edited_label")
                            }
                            if mixerEndFault == "foreign_focus" {
                                fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, otherLabel)
                                fixture.reads.record("owned_end_fault_foreign_focus")
                            }
                            fixture.builder.setAttribute(exposedMixer, kAXSelectedChildrenAttribute as String, exposedStrips)
                            fixture.builder.setAttribute(endEdit, kAXSelectedAttribute as String, false)
                        }
                        return true
                    }
                    guard hiddenView, CFEqual(element, hideMenu), action == kAXPressAction as String else { return nil }
                    fixture.events.record("hidden_menu")
                    let wasShown = (fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == 1
                    fixture.builder.setAttribute(hide, kAXValueAttribute as String, wasShown ? 0 : 1)
                    fixture.builder.setChildren(headers[0], [disclosure, wasShown ? passiveLabel : shownLabel])
                    if wasShown {
                        let focus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                            runtime: fixture.builder.makeAXRuntime())
                        if focus.map({ CFEqual($0, shownLabel) }) == true {
                            fixture.reads.record("hidden_inverse_before_workspace_focus")
                            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, passiveLabel)
                        }
                    }
                    return true
                },
                observationHit: { point in
                    if fullDomainMixerEnd, point == headerReturnPoint {
                        fixture.reads.record("header_return_hit")
                        if headerReturnClick == "wrong_hit" || (headerReturnClick == "changed_hit"
                            && fixture.reads.recorded.filter({ $0 == "header_return_hit" }).count == 2) {
                            fixture.reads.record("header_return_wrong_hit"); return otherLabel
                        }
                        return passiveLabel
                    }
                    guard mixerFocusACKHasNoEffect, point == endFocusPoint else { return nil }
                    fixture.reads.record("owned_focus_blank_hit")
                    if mixerFocusClickFault == "wrong_hit" || (mixerFocusClickFault == "changed_hit"
                        && fixture.reads.recorded.filter({ $0 == "owned_focus_blank_hit" }).count == 2) {
                        fixture.reads.record("owned_focus_blank_wrong_hit"); return otherLabel
                    }
                    return exposedStrips[associationStripIndices[0]]
                }, wrongDisclosureHit: mouseCase == "wrong_hit", focusSetter: { element, attribute, value in
                    if fullDomainMixerEnd {
                        if attribute == kAXFocusedAttribute as String,
                           CFEqual(element, passiveLabel) || CFEqual(element, exposedStrips[associationStripIndices[0]]) {
                            fixture.reads.record(CFEqual(element, passiveLabel) ? "owned_end_header_focus_inverse" : "owned_end_mixer_focus_forward")
                            if CFEqual(element, passiveLabel), headerFocusSetterOpensEditor {
                                fixture.reads.record("passive_name_AXFocused_opened_real_editor")
                                fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, returnEditor)
                                return true
                            }
                            if mixerFocusACKHasNoEffect, !CFEqual(element, passiveLabel) {
                                do {
                                    let current = try #require(fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String))
                                    #expect(CFEqual(current as AnyObject, passiveLabel))
                                } catch { return false }
                                fixture.reads.record("owned_focus_ack_ineffective")
                                return true
                            }
                            if CFEqual(element, passiveLabel), mixerEndFault == "declined_inverse" { return false }
                            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, element)
                            return true
                        }
                        if CFEqual(element, exposedMixer), attribute == kAXSelectedChildrenAttribute as String {
                            let original = AXHelpers.decodeChildrenArray(value)
                            #expect(original.count == 1 && CFEqual(original[0], exposedStrips[associationStripIndices[0]]))
                            fixture.reads.record("owned_end_mixer_selection_inverse")
                            fixture.builder.setAttribute(exposedMixer, kAXSelectedChildrenAttribute as String, original)
                            return true
                        }
                    }
                    if fullDomainAssociation { fixture.reads.record("exposed_association_setter_call") }
                    if fullDomainAssociation, CFEqual(element, fixture.rail), attribute == kAXSelectedChildrenAttribute as String {
                        let requested = AXHelpers.decodeChildrenArray(value)
                        guard requested.count == 1,
                              let index = fullyExposed.firstIndex(where: { CFEqual($0, requested[0]) }) else {
                            Issue.record("association must select one actual exposed header"); return false
                        }
                        fixture.reads.record("exposed_association_selection_\(index)")
                        if fullDomainAssociationFault == "inverse", index == 0 {
                            fixture.reads.record("exposed_association_inverse_refused")
                            return false
                        }
                        for (rowIndex, row) in fullyExposed.enumerated() {
                            fixture.builder.setAttribute(row, kAXSelectedAttribute as String, rowIndex == index)
                        }
                        fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, requested)
                        // This physical relationship is supplied by the native owner,
                        // deliberately unrelated to display names or strip ordinals.
                        fixture.builder.setAttribute(exposedMixer, kAXSelectedChildrenAttribute as String,
                            [exposedStrips[associationStripIndices[index]]])
                        if fullDomainAssociationFault == "editing", index == 1 {
                            fixture.reads.record("exposed_association_passive_field_changed")
                            fixture.builder.setAttributeSettable(passiveLabel, kAXValueAttribute as String, true)
                        }
                        return true
                    }
                    guard let focusRestoration else { Issue.record("no AX setters"); return false }
                    #expect(CFEqual(element, workspace) && attribute == kAXFocusedAttribute as String)
                    do {
                        let number = try #require(value as? NSNumber)
                        #expect(number.boolValue)
                    } catch { return false }
                    fixture.reads.record("workspace_focus_setter")
                    if focusRestoration == "declined" || hiddenFocusFault == "declined" { return false }
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                        focusRestoration == "wrong_readback" || hiddenFocusFault == "wrong_readback" ? otherLabel : workspace)
                    if hiddenFocusFault == "post_focus_project" {
                        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                    return true
                }, observingAttribute: { element, attribute in
                    if postAckForeignFocus, fixture.events.count == 2, CFEqual(element, disclosure),
                       attribute == kAXValueAttribute as String,
                       Thread.callStackSymbols.contains(where: { $0.contains("observeCompletedClick") }) {
                        fixture.reads.record("held_expansion_ack_read")
                    }
                    if postAckForeignFocus, fixture.reads.recorded.contains("held_expansion_ack_read"),
                       !fixture.reads.recorded.contains("foreign_focus_after_held_ack"),
                       CFEqual(element, fixture.window), attribute == kAXRoleAttribute as String,
                       Thread.callStackSymbols.contains(where: { $0.contains("allTrackHeadersVerifiedRead") }) {
                        fixture.reads.record("foreign_focus_after_held_ack")
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, otherLabel)
                    }
                    if selectedEnumerationLoss, fixture.events.count == 2,
                       CFEqual(element, headers[headers.count - 1]), attribute == kAXSelectedAttribute as String {
                        fixture.reads.record("selected_enumeration_rows_captured")
                    }
                    if selectedEnumerationLoss, CFEqual(element, fixture.rail),
                       attribute == kAXSelectedChildrenAttribute as String,
                       fixture.reads.recorded.contains("selected_enumeration_missing_header_sample"),
                       !fixture.reads.recorded.contains("selected_enumeration_header_recovered") {
                        fixture.reads.record("selected_enumeration_header_recovered")
                        fixture.builder.setChildren(fixture.rail, headers)
                    }
                    if selectedCensusLoss, fixture.events.count == 2,
                       CFEqual(element, fixture.rail), attribute == kAXSelectedChildrenAttribute as String {
                        fixture.reads.record("selected_census_armed")
                    }
                    if selectedCensusLoss, CFEqual(element, fixture.window), attribute == kAXTitleAttribute as String,
                       fixture.reads.recorded.contains("selected_census_missing_header_sample"),
                       !fixture.reads.recorded.contains("selected_census_header_recovered") {
                        fixture.reads.record("selected_census_header_recovered")
                        fixture.builder.setChildren(fixture.rail, headers)
                    }
                    if revealedStack == "late_open", fixture.events.count == 2,
                       CFEqual(element, headers[1]), attribute == kAXTitleAttribute as String,
                       fixture.reads.recorded.contains("revealed_disclosure_scan_completed"),
                       !fixture.reads.recorded.contains("revealed_stack_opened_after_scan") {
                        fixture.reads.record("revealed_stack_opened_after_scan")
                        fixture.builder.setRole(inner, kAXDisclosureTriangleRole as String)
                        fixture.builder.setAttribute(inner, kAXValueAttribute as String, 1)
                        fixture.builder.setChildren(headers[1], [inner])
                    }
                    if headerFocus == "radio_role_sample", fixture.events.count == 2,
                       CFEqual(element, passiveLabel), attribute == kAXRoleAttribute as String {
                        passiveRoleReads.record("role")
                        let changed = passiveRoleReads.count == 2
                        fixture.builder.setRole(passiveLabel, changed ? kAXTextFieldRole as String : kAXRadioButtonRole as String)
                        fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, changed ? 0 : 1)
                        if changed { fixture.reads.record("passive_classifier_role_changed") }
                    }
                    if nested, fixture.events.count == (hiddenView ? 9 : 8),
                       CFEqual(element, fixture.app), attribute == kAXFocusedUIElementAttribute as String {
                        focusBoundaryReads.record("focus")
                        if let lateScopeFault {
                            // Calibrated positive call stacks locate the final
                            // stop callback's held-focus read before the setter:
                            // 22 for Stack-only and 27 with the initial Hide menu.
                            if focusBoundaryReads.count == (hiddenView ? 27 : 22) {
                                fixture.reads.record("late_scope_fault_injected")
                                if lateScopeFault == "document" {
                                    fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                                } else {
                                    let foreign = fixture.builder.element(965_299)
                                    fixture.builder.setRole(foreign, kAXWindowRole as String)
                                    fixture.builder.setAttribute(fixture.app,
                                        lateScopeFault == "main_window" ? kAXMainWindowAttribute as String : kAXFocusedWindowAttribute as String,
                                        foreign)
                                }
                            }
                        }
                    }
                    if hiddenViewLoss, fixture.events.count == 2, CFEqual(element, headers.last!),
                       attribute == kAXTitleAttribute as String {
                        fixture.reads.record("hidden_view_last_row_name")
                    }
                    if hiddenViewLoss, fixture.events.count == 2, CFEqual(element, headers[0]),
                       attribute == kAXParentAttribute as String,
                       fixture.reads.recorded.contains("hidden_view_last_row_name"),
                       !fixture.reads.recorded.contains("hidden_view_parent_read") {
                        fixture.reads.record("hidden_view_parent_read")
                    }
                    if hiddenViewLoss, CFEqual(element, fixture.window), attribute == kAXTitleAttribute as String,
                       fixture.reads.recorded.contains("hidden_view_held_header_missing"),
                       !fixture.reads.recorded.contains("hidden_view_same_header_recovered") {
                        fixture.builder.setChildren(fixture.rail, headers)
                        fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 1)
                        fixture.reads.record("hidden_view_same_header_recovered")
                    }
                    if mouseCase == "unrelated_text_focus", fixture.events.count == 1 {
                        fixture.reads.record("ax_read_during_held_down")
                    }
                    if knownOuterReopen, fixture.events.count == 2, CFEqual(element, headers[0]),
                       attribute == kAXTitleAttribute as String { fixture.reads.record("outer_row_name_before_stack_read") }
                    if knownOuterReplacement, fixture.events.count == 2, CFEqual(element, headers[0]),
                       attribute == kAXTitleAttribute as String,
                       !fixture.reads.recorded.contains("replacement_disclosure_installed") {
                        fixture.reads.record("replacement_disclosure_installed")
                        if disclosureDecision == "role_loss" {
                            fixture.builder.setRole(disclosure, kAXButtonRole as String)
                            fixture.builder.setChildren(headers[0], [disclosure, substitutedDisclosure])
                        } else {
                            fixture.builder.setChildren(headers[0], disclosureDecision == "competing"
                                ? [substitutedDisclosure, disclosure] : [substitutedDisclosure])
                        }
                        fixture.builder.setChildren(fixture.rail, collapsed)
                    }
                    if disclosureDecision == "role_loss", CFEqual(element, disclosure),
                       attribute == kAXRoleAttribute as String,
                       fixture.builder.attributeValue(disclosure, attribute) as? String == kAXButtonRole as String {
                        fixture.reads.record("held_disclosure_button_role_read")
                    }
                    if knownOuterReplacement, CFEqual(element, substitutedDisclosure) {
                        if attribute == kAXRoleAttribute as String { fixture.reads.record("replacement_disclosure_role_read") }
                        if attribute == kAXValueAttribute as String { fixture.reads.record("replacement_disclosure_value_read") }
                    }
                    if knownInnerReopen, fixture.events.count == 4, CFEqual(element, headers[1]),
                       attribute == kAXTitleAttribute as String {
                        fixture.reads.record("inner_row_name_before_stack_read")
                    }
                    if knownInnerReplacement, fixture.events.count == 4, CFEqual(element, headers[1]),
                       attribute == kAXTitleAttribute as String,
                       !fixture.reads.recorded.contains("replacement_disclosure_installed") {
                        fixture.reads.record("replacement_disclosure_installed")
                        if disclosureDecision == "role_loss" {
                            fixture.builder.setRole(inner, kAXButtonRole as String)
                            fixture.builder.setChildren(headers[1], [inner, substitutedDisclosure])
                        } else {
                            fixture.builder.setChildren(headers[1], disclosureDecision == "competing"
                                ? [substitutedDisclosure, inner] : [substitutedDisclosure])
                        }
                        fixture.builder.setChildren(fixture.rail, headers)
                    }
                    if disclosureDecision == "role_loss", CFEqual(element, inner),
                       attribute == kAXRoleAttribute as String,
                       fixture.builder.attributeValue(inner, attribute) as? String == kAXButtonRole as String {
                        fixture.reads.record("held_disclosure_button_role_read")
                    }
                    if knownInnerReplacement, CFEqual(element, substitutedDisclosure) {
                        if attribute == kAXRoleAttribute as String { fixture.reads.record("replacement_disclosure_role_read") }
                        if attribute == kAXValueAttribute as String { fixture.reads.record("replacement_disclosure_value_read") }
                    }
                    guard let nestedFault,
                          ["inner_closed", "replacement", "cancel_task_read"].contains(nestedFault) || nestedFault.hasPrefix("cancel_read"),
                          fixture.events.count == 4, attribute == kAXTitleAttribute as String,
                          CFEqual(element, grandchildren[1]) else { return }
                    fixture.reads.record("last_grandchild_title")
                    guard fixture.reads.recorded.filter({ $0 == "last_grandchild_title" }).count == 3 else { return }
                    fixture.reads.record("last_grandchild_fault")
                    if nestedFault.hasPrefix("cancel_read") || nestedFault == "cancel_task_read" {
                        switch nestedFault {
                        case "cancel_read_focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, replacement)
                        case "cancel_read_project": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                        case "cancel_read_viewport": fixture.builder.setAttribute(scrollbar, kAXValueAttribute as String, 0.75)
                        case "cancel_read_control": fixture.builder.setRole(inner, kAXButtonRole as String)
                        case "cancel_read_deadline":
                            if let deadline = OperationTraceContext.current?.deadline {
                                // Expire only after the deciding cancellation marker.
                                // The outer timer retains its independent cleanup margin.
                                Thread.sleep(forTimeInterval: LogicProServer.secondsFromNow(until: deadline))
                            } else { Issue.record("Expected the actual inner deadline") }
                        default: break
                        }
                        if nestedFault == "cancel_task_read" { withUnsafeCurrentTask { $0?.cancel() } }
                        return
                    }
                    if nestedFault == "inner_closed" {
                        fixture.builder.setAttribute(inner, kAXValueAttribute as String, 0)
                        fixture.builder.setChildren(fixture.rail, headers)
                    } else {
                        var changed = fullyExposed
                        changed[2] = replacement
                        fixture.builder.setChildren(fixture.rail, changed)
                    }
                }, readingAttribute: { element, attribute in
                    if headerReturnSelection == "selection_conflict", CFEqual(element, fixture.rail),
                       attribute == kAXSelectedChildrenAttribute as String,
                       fixture.reads.recorded.contains("owned_end_select_all"),
                       !fixture.reads.recorded.contains("header_selection_conflict") {
                        fixture.reads.record("header_selection_conflict")
                        fixture.builder.setAttribute(headers[0], kAXSelectedAttribute as String, false)
                        fixture.builder.setAttribute(headers[1], kAXSelectedAttribute as String, true)
                        fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [headers[1]])
                    }
                    if mixerFocusClickDelayed, CFEqual(element, fixture.app), attribute == kAXFocusedUIElementAttribute as String,
                       fixture.reads.recorded.contains("owned_end_focus_up"),
                       !fixture.reads.recorded.contains("owned_focus_click_landed") {
                        fixture.reads.record("owned_focus_click_landing_read")
                        if fixture.reads.recorded.filter({ $0 == "owned_focus_click_landing_read" }).count == 2 {
                            fixture.reads.record("owned_focus_click_landed")
                            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                                exposedStrips[associationStripIndices[0]])
                        }
                    }
                    if fullDomainMixerEnd, exposedStrips.contains(where: { CFEqual($0, element) }),
                       [kAXValueAttribute as String, kAXSelectedTextAttribute as String].contains(attribute) {
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if retainOwnershipReadFocus, fixture.events.count == 2,
                       CFEqual(element, fixture.app), attribute == kAXFocusedUIElementAttribute as String,
                       Thread.callStackSymbols.contains(where: { $0.contains("acceptHeldGestureFocus") }) {
                        fixture.reads.record("disclosure_focus_accepted_before_owned_read")
                    }
                    if ["slider_to_label", "slider_to_foreign_label"].contains(headerFocus ?? ""),
                       fixture.events.count == 2, CFEqual(element, play), attribute == kAXValueAttribute as String,
                       Thread.callStackSymbols.contains(where: { $0.contains("owned") }),
                       !retainOwnershipReadFocus || fixture.reads.recorded.contains("disclosure_focus_accepted_before_owned_read"),
                       !fixture.reads.recorded.contains("held_slider_focus_moved_by_owned_transport_read") {
                        fixture.reads.record("held_slider_focus_moved_by_owned_transport_read")
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, shownLabel)
                    }
                    if headerFocus?.hasPrefix("slider_") == true,
                       CFEqual(element, passiveLabel) || CFEqual(element, otherLabel),
                       [kAXInsertionPointLineNumberAttribute as String, kAXSelectedTextRangeAttribute as String,
                        kAXSelectedTextAttribute as String, kAXNumberOfCharactersAttribute as String].contains(attribute) {
                        if fixture.events.count == 2, attribute == kAXNumberOfCharactersAttribute as String {
                            sliderMetadataObservations?.record("metadata")
                        }
                        if fixture.events.count == 2, attribute == kAXNumberOfCharactersAttribute as String,
                           headerFocus == "slider_late_changed" || (headerFocus == "slider_final_changed"
                            && sliderMetadataObservations?.recorded.filter { $0 == "metadata" }.count == sliderMutationAt) {
                            fixture.reads.record("slider_value_changed_at_final_metadata")
                            fixture.builder.setAttribute(passiveLabel, kAXValueAttribute as String, 172)
                        }
                        if let value = fixture.builder.attributeValue(element, attribute) { return .success(value as AnyObject) }
                        return .failure(.init(raw: AXError.noValue.rawValue))
                    }
                    if fullDomainMixerOpen, CFEqual(element, headers[0]), attribute == kAXHelpAttribute as String {
                        fixture.reads.record("initial_header_help_moved_focus")
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, headers[0])
                    }
                    if helpMovesFocus, fixture.events.count > 0, attribute == kAXHelpAttribute as String {
                        fixture.reads.record("focus_moving_help_read")
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, otherLabel)
                    }
                    if nestedFault == "cancel_task_read", fixture.events.count == 6,
                       CFEqual(element, inner), attribute == kAXValueAttribute as String,
                       !fixture.reads.recorded.contains("cancelled_inverse_pending_landing") {
                        fixture.reads.record("cancelled_inverse_pending_landing")
                        return .success(NSNumber(value: 1))
                    }
                    if delayedLanding, CFEqual(element, disclosure), attribute == kAXValueAttribute as String,
                       [2, 4].contains(fixture.events.count) {
                        let marker = fixture.events.count == 2 ? "pending_expansion_landing" : "pending_restoration_landing"
                        if !fixture.reads.recorded.contains(marker) {
                            fixture.reads.record(marker)
                            return .success(NSNumber(value: fixture.events.count == 2 ? 0 : 1))
                        }
                    }
                    if knownOuterReopen, fixture.events.count == 2, CFEqual(element, disclosure),
                          attribute == kAXValueAttribute as String,
                          fixture.reads.recorded.contains("outer_row_name_before_stack_read"),
                          !fixture.reads.recorded.contains("outer_extractor_returned_zero") {
                        fixture.builder.setAttribute(disclosure, kAXValueAttribute as String, 0)
                        fixture.builder.setChildren(fixture.rail, collapsed)
                        fixture.reads.record("outer_extractor_returned_zero")
                        return .success(NSNumber(value: 0))
                    }
                    if knownInnerReopen, fixture.events.count == 4, CFEqual(element, inner),
                       attribute == kAXValueAttribute as String,
                       fixture.reads.recorded.contains("inner_row_name_before_stack_read"),
                       !fixture.reads.recorded.contains("inner_extractor_returned_zero") {
                        fixture.builder.setAttribute(inner, kAXValueAttribute as String, 0)
                        fixture.builder.setChildren(fixture.rail, headers)
                        fixture.reads.record("inner_extractor_returned_zero")
                        return .success(NSNumber(value: 0))
                    }
                    guard let downFocusRead, CFEqual(element, fixture.app),
                          attribute == kAXFocusedUIElementAttribute as String,
                          fixture.events.count == (downFocusRead == "expansion" ? 4 : 6),
                          !fixture.reads.recorded.contains("focus_read_missing_after_true_down") else { return nil }
                    fixture.reads.record("focus_read_missing_after_true_down")
                    return .success(nil)
                }, observingChildren: { element in
                    if selectedEnumerationLoss, fixture.events.count == 2,
                       CFEqual(element, fixture.rail),
                       Thread.callStackSymbols.contains(where: { $0.contains("enumerateTrackHeaderRows") }),
                       Thread.callStackSymbols.contains(where: { $0.contains("uniqueTrackHeaderRail") }),
                       fixture.reads.recorded.contains("selected_enumeration_rows_captured"),
                       !fixture.reads.recorded.contains("selected_enumeration_missing_header_sample") {
                        fixture.reads.record("selected_enumeration_missing_header_sample")
                        fixture.builder.setChildren(fixture.rail, Array(headers.dropFirst()))
                    }
                    if selectedCensusLoss, CFEqual(element, fixture.rail),
                       fixture.reads.recorded.contains("selected_census_armed"),
                       !fixture.reads.recorded.contains("selected_census_missing_header_sample") {
                        fixture.reads.record("selected_census_missing_header_sample")
                        fixture.builder.setChildren(fixture.rail, Array(headers.dropFirst()))
                    }
                    if revealedStack == "late_open", fixture.events.count == 2,
                       CFEqual(element, headers[23]),
                       Thread.callStackSymbols.contains(where: { $0.contains("disclosureStates") }) {
                        fixture.reads.record("revealed_disclosure_scan_completed")
                    }
                    if hiddenViewLoss, CFEqual(element, fixture.rail),
                       fixture.reads.recorded.contains("hidden_view_parent_read"),
                       !fixture.reads.recorded.contains("hidden_view_held_header_missing") {
                        fixture.builder.setChildren(fixture.rail, Array(headers.dropFirst()))
                        fixture.reads.record("hidden_view_held_header_missing")
                    }
                    if knownOuterReplacement, CFEqual(element, headers[0]),
                       fixture.reads.recorded.contains("replacement_disclosure_installed"),
                       !fixture.reads.recorded.contains("same_outer_reopened_on_retry") {
                        let children = fixture.builder.makeAXRuntime().children(headers[0])
                        let expected = disclosureDecision == "role_loss" ? [disclosure, substitutedDisclosure]
                            : disclosureDecision == "competing" ? [substitutedDisclosure, disclosure] : [substitutedDisclosure]
                        if children.count == expected.count,
                           zip(children, expected).allSatisfy({ CFEqual($0.0, $0.1) }) {
                            fixture.reads.record("replacement_disclosure_children_read")
                        }
                    }
                    if (knownOuterReopen || knownOuterReplacement), CFEqual(element, fixture.rail),
                       (fixture.reads.recorded.contains("outer_extractor_returned_zero")
                        || fixture.reads.recorded.contains("replacement_disclosure_value_read")),
                       !fixture.reads.recorded.contains("same_outer_reopened_on_retry"),
                       fixture.builder.makeAXRuntime().children(fixture.rail).count == 19 {
                        fixture.reads.record("closed_rail_actually_read")
                    }
                    if knownInnerReplacement, CFEqual(element, headers[1]),
                       fixture.reads.recorded.contains("replacement_disclosure_installed"),
                       !fixture.reads.recorded.contains("same_inner_reopened_on_retry") {
                        let children = fixture.builder.makeAXRuntime().children(headers[1])
                        let expected = disclosureDecision == "role_loss" ? [inner, substitutedDisclosure]
                            : disclosureDecision == "competing" ? [substitutedDisclosure, inner] : [substitutedDisclosure]
                        if children.count == expected.count,
                           zip(children, expected).allSatisfy({ CFEqual($0.0, $0.1) }) {
                            fixture.reads.record("replacement_disclosure_children_read")
                        }
                    }
                    if (knownInnerReopen || knownInnerReplacement), CFEqual(element, fixture.rail),
                       (fixture.reads.recorded.contains("inner_extractor_returned_zero")
                        || fixture.reads.recorded.contains("replacement_disclosure_value_read")),
                       !fixture.reads.recorded.contains("same_inner_reopened_on_retry"),
                       fixture.builder.makeAXRuntime().children(fixture.rail).count == 42 {
                        fixture.reads.record("closed_rail_actually_read")
                    }
                }), cache: cache,
                runtime: .init(hasVisibleWindow: { true }, projectFileReader: fileReader, keyboardFocus: {
                    if retainOwnershipReadFocus,
                       let current = fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String),
                       CFEqual(current as AnyObject, disclosure) { return .notTextEditing }
                    if fullDomainMixerOpen {
                        let current = fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String)
                        if headerFocusSetterOpensEditor, let current, CFEqual(current as AnyObject, returnEditor) {
                            return .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
                        }
                        if fullDomainMixerEnd, let current,
                           exposedStrips.contains(where: { CFEqual($0, current as AnyObject) }) {
                            return .textEditing(role: kAXLayoutItemRole as String, byInsertionPoint: true)
                        }
                        if let current, CFEqual(current as AnyObject, passiveLabel) {
                            return .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
                        }
                        return .notTextEditing
                    }
                    if focusRestoration != nil {
                        let focus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                            runtime: fixture.builder.makeAXRuntime())
                        if let focus, CFEqual(focus, workspace) { return .notTextEditing }
                    }
                    if helpMovesFocus, fixture.reads.recorded.contains("focus_moving_help_read") {
                        return .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
                    }
                    if headerFocus?.hasPrefix("initial_") == true
                        || ((mouseCase == "unrelated_text_focus" || headerFocus != nil) && fixture.events.count > 0) {
                        return .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
                    }
                    return .notTextEditing
                })),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: fileReader)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
        let params: [String: Value] = ["domains": .array(fullDomainMixerOpen
            ? [.string("tracks"), .string("hierarchy"), .string("strips"), .string("associations")] : verifyHierarchy
            ? [.string("tracks"), .string("hierarchy")] : includeStrips
                ? [.string("tracks"), .string("strips")] : [.string("tracks")]), "allow_ui_navigation": .bool(navigation),
            "scope": .string(selectedCensusLoss || selectedEnumerationLoss ? "selection" : "whole_project")]
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: params, mutationGate: gate) {
                if let nestedFault,
                   ["cancel", "deadline", "cancel_task_read"].contains(nestedFault) || nestedFault.hasPrefix("cancel_read"),
                   let inherited = OperationTraceContext.current {
                    let context = OperationTraceContext(parentTraceID: inherited.parentTraceID,
                        mutationGateAcquired: inherited.mutationGateAcquired,
                        ownsGate: { inherited.ownsGate() && !(nestedFault == "cancel_read_gate"
                            && fixture.reads.recorded.contains("last_grandchild_fault")) },
                        deadline: nestedFault == "deadline" ? ContinuousClock.now.advanced(by: .milliseconds(100))
                            : nestedFault == "cancel_read_deadline" ? inherited.deadline?.advanced(by: .seconds(-5)) : inherited.deadline,
                        cancellationRequested: {
                            inherited.cancellationRequested() || (nestedFault == "cancel"
                                && fixture.reads.recorded.contains("child_custody_fault"))
                                || (nestedFault.hasPrefix("cancel_read") && fixture.reads.recorded.contains("last_grandchild_fault"))
                        })
                    return await OperationTraceContext.$current.withValue(context) {
                        await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
                    }
                }
                return await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
            }
        if let fullDomainAssociationFault {
            #expect(fixture.reads.recorded.contains(fullDomainAssociationFault == "inverse"
                ? "exposed_association_inverse_refused" : "exposed_association_passive_field_changed"))
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up", "inner_down", "inner_up"],
                "a failed selection inverse or lost passive custody cannot authorize disclosure cleanup")
            #expect(fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            let pairs = ((body["associations"] as? [String: Any])?["rows"] as? [[String: Any]]) ?? []
            #expect(pairs.isEmpty, "unrestored or conflicted exposed relationships must not be published")
            return
        }
        if let headerReturnClick {
            #expect(!fixture.reads.recorded.contains("passive_name_AXFocused_opened_real_editor"))
            #expect(fixture.reads.recorded.contains("owned_end_select_all"))
            if headerReturnClick == "complete" {
                #expect(fixture.reads.recorded.contains("header_return_down") && fixture.reads.recorded.contains("header_return_up"))
            } else {
                if headerReturnClick == "wrong_hit" || headerReturnClick == "changed_hit" {
                    #expect(fixture.reads.recorded.contains("header_return_wrong_hit"))
                    #expect(!fixture.reads.recorded.contains("header_return_down"))
                } else {
                    #expect(fixture.reads.recorded.contains("header_return_down") && fixture.reads.recorded.contains("header_return_up"))
                    if headerReturnClick == "up_failed" { #expect(fixture.reads.recorded.contains("header_return_incomplete_pair_landed")) }
                }
                #expect(fixture.events.count == 4, "Unverified return cannot authorize disclosure inverses")
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                let effects = try #require(body["ui_effects"] as? [String: Any])
                #expect(effects["restoration"] as? String == "not_restored")
                #expect(body["snapshot_id"] == nil)
                #expect(gate.currentOperation() == nil && fixture.builder.actionCalls.isEmpty)
                return
            }
        }
        if let headerReturnSelection {
            #expect(!fixture.reads.recorded.contains("passive_name_AXFocused_opened_real_editor"))
            if headerReturnSelection == "selection_conflict" {
                #expect(fixture.reads.recorded.contains("header_selection_conflict"))
                #expect(!fixture.reads.recorded.contains("header_return_down"))
            } else { #expect(fixture.reads.recorded.contains("header_return_down") && fixture.reads.recorded.contains("header_return_up")) }
            if headerReturnSelection != "complete" {
                #expect(fixture.events.count == 4, "No selection ACK can authorize unobserved original-focus restoration")
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                let effects = try #require(body["ui_effects"] as? [String: Any])
                #expect(effects["restoration"] as? String == "not_restored")
                #expect(body["snapshot_id"] == nil)
                #expect(gate.currentOperation() == nil && fixture.builder.actionCalls.isEmpty)
                return
            }
        }
        if headerHelpHasNoEffect {
            #expect(fixture.reads.recorded.contains("header_return_down") && fixture.reads.recorded.contains("header_return_up"))
            #expect(fixture.events.count == 4, "No Help string can authorize an original-focus or disclosure inverse")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(body["snapshot_id"] == nil)
            #expect(gate.currentOperation() == nil && fixture.builder.actionCalls.isEmpty)
            return
        }
        if let mixerFocusClickFault {
            #expect(fixture.reads.recorded.contains("owned_focus_ack_ineffective"))
            #expect(!fixture.reads.recorded.contains("owned_end_select_all"))
            #expect(!fixture.reads.recorded.contains("owned_end_header_focus_inverse"))
            if mixerFocusClickFault == "wrong_hit" || mixerFocusClickFault == "changed_hit" {
                #expect(fixture.reads.recorded.contains("owned_focus_blank_wrong_hit"))
                #expect(!fixture.reads.recorded.contains("owned_end_focus_down"))
            } else {
                #expect(fixture.reads.recorded.contains("owned_end_focus_down") && fixture.reads.recorded.contains("owned_end_focus_up"))
                if mixerFocusClickFault == "up_failed" { #expect(fixture.reads.recorded.contains("owned_focus_click_up_failed")) }
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(body["snapshot_id"] == nil, "An ineffective/uncertain focus transport cannot certify any whole population")
            #expect(gate.currentOperation() == nil && fixture.builder.actionCalls.isEmpty)
            return
        }
        if let mixerEndFault {
            let endSequence = fixture.reads.recorded.filter { $0.hasPrefix("owned_end_") }
            #expect(fixture.reads.recorded.filter { $0 == "exposed_association_setter_call" }.count == 4)
            if mixerEndFault == "unsettable_inverse" {
                #expect(endSequence.isEmpty, "An unreadable/unsettable original inverse must refuse before acquiring Mixer focus")
                #expect(fixture.events.count == 8)
            } else {
                #expect(endSequence.contains("owned_end_mixer_focus_forward") && endSequence.contains("owned_end_select_all"))
                #expect(fixture.events.count == 4, "Lost or unrestored original focus cannot authorize disclosure cleanup")
                if mixerEndFault == "declined_inverse" {
                    #expect(endSequence.contains("owned_end_header_focus_inverse"))
                } else {
                    #expect(endSequence.contains("owned_end_fault_" + mixerEndFault))
                    #expect(!endSequence.contains("owned_end_header_focus_inverse"), "No blind focus inverse over an editor or foreign focus")
                }
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == (mixerEndFault == "unsettable_inverse" ? "restored" : "not_restored"))
            let overall = body["overall"] as? [String: Any]
            if let complete = overall?["complete"] as? Bool { #expect(!complete) }
            #expect(gate.currentOperation() == nil && fixture.builder.actionCalls.isEmpty)
            return
        }
        if fullDomainMixerOpen {
            if headerFocusSetterOpensEditor, headerReturnSelection == nil, headerReturnClick == nil {
                #expect(!fixture.reads.recorded.contains("passive_name_AXFocused_opened_real_editor"))
                #expect(fixture.reads.recorded.contains("header_return_down") && fixture.reads.recorded.contains("header_return_up"))
            }
            let headerHelpReads = fixture.reads.recorded.filter { $0 == "initial_header_help_moved_focus" }.count
            #expect(headerHelpReads == 0, "The request-owned reveal must retain the fresh census's proved control-forest Help omission")
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up", "inner_down", "inner_up",
                "inner_down", "inner_up", "disclosure_down", "disclosure_up"])
            let currentFocus = try #require(fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String))
            #expect(CFEqual(currentFocus as AnyObject, passiveLabel))
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == 1)
            if fullDomainAssociation {
                let associationSelections = fixture.reads.recorded.filter { $0.hasPrefix("exposed_association_selection_") }
                #expect(associationSelections == ["exposed_association_selection_1", "exposed_association_selection_2",
                    "exposed_association_selection_3", "exposed_association_selection_0"])
                // A custom builder setter bypasses its default setCalls array.
                // Count that actual entrypoint; its guard above rejects any
                // non-rail/non-selection call rather than pretending it is absent.
                #expect(fixture.reads.recorded.filter { $0 == "exposed_association_setter_call" }.count == 4)
            } else { #expect(fixture.builder.setCalls.isEmpty) }
            #expect(fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "restored")
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.count == fullyExposed.count)
            if fullDomainAssociation {
                let associations = try #require(body["associations"] as? [String: Any])
                let pairs = try #require(associations["rows"] as? [[String: Any]])
                #expect(pairs.count == fullyExposed.count)
                #expect(pairs.allSatisfy { $0["source"] as? String == "held_exclusive_selection_selected_child" })
                #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == 1)
                let selected = try #require(fixture.builder.attributeValue(exposedMixer, kAXSelectedChildrenAttribute as String))
                let selectedStrips = AXHelpers.decodeChildrenArray(selected as CFTypeRef)
                #expect(selectedStrips.count == 1 && CFEqual(selectedStrips[0], exposedStrips[associationStripIndices[0]]))
            }
            if fullDomainMixerEnd {
                let endSequence = fixture.reads.recorded.filter { $0.hasPrefix("owned_end_") }
                let focusClick = mixerFocusACKHasNoEffect ? ["owned_end_focus_down", "owned_end_focus_up"] : []
                #expect(endSequence == ["owned_end_mixer_focus_forward"] + focusClick + ["owned_end_open_edit", "owned_end_select_all",
                    "owned_end_mixer_selection_inverse", "owned_end_header_focus_inverse"])
                if mixerFocusACKHasNoEffect { #expect(fixture.reads.recorded.contains("owned_focus_ack_ineffective")) }
                if mixerFocusClickDelayed { #expect(fixture.reads.recorded.contains("owned_focus_click_landed")) }
                let strips = try #require(body["strips"] as? [String: Any])
                #expect(strips["coverage"] as? String == "complete")
                let overall = try #require(body["overall"] as? [String: Any])
                let complete = try #require(overall["complete"] as? Bool)
                #expect(complete)
            }
            // This regression proves owned disclosure exposure and inverse,
            // not complete populations or a newly invented stack association.
            return
        }
        if selectedCensusLoss || selectedEnumerationLoss {
            let missing = selectedEnumerationLoss ? "selected_enumeration_missing_header_sample" : "selected_census_missing_header_sample"
            let recovered = selectedEnumerationLoss ? "selected_enumeration_header_recovered" : "selected_census_header_recovered"
            #expect(fixture.reads.recorded.filter { $0 == missing }.count == 1)
            #expect(fixture.reads.recorded.filter { $0 == recovered }.count == 1)
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up"],
                    "a sampled missing owned header irreversibly ends the old inverse")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(body["snapshot_id"] == nil)
            #expect(await cache.getTracks().isEmpty)
            return
        }
        if verifyHierarchy, nestedFault != nil {
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect((body["hierarchy"] as? [String: Any])?["disclosure_exposures"] == nil,
                "an incomplete inverse, changed project/control/focus/viewport or interruption grants no hierarchy evidence")
        }
        if helpMovesFocus {
            #expect(!fixture.reads.recorded.contains("focus_moving_help_read"),
                    "fresh population must not query AXHelp, which moves native Logic focus")
        }
        if knownOuterReopen || knownOuterReplacement {
            if knownOuterReopen {
                #expect(fixture.reads.recorded.filter { $0 == "outer_extractor_returned_zero" }.count == 1)
                #expect(fixture.reads.recorded.contains("outer_row_name_before_stack_read"))
            } else {
                #expect(!CFEqual(substitutedDisclosure, disclosure))
                #expect(fixture.reads.recorded.filter { $0 == "replacement_disclosure_installed" }.count == 1)
                #expect(fixture.reads.recorded.contains("replacement_disclosure_children_read"))
                #expect(fixture.reads.recorded.contains("replacement_disclosure_role_read"))
                #expect(fixture.reads.recorded.contains("replacement_disclosure_value_read"))
                if disclosureDecision == "role_loss" {
                    #expect(fixture.reads.recorded.contains("held_disclosure_button_role_read"))
                }
            }
            #expect(fixture.reads.recorded.contains("closed_rail_actually_read"))
            #expect(fixture.reads.recorded.filter { $0 == "closed_population_metadata" }.count >= 2)
            #expect(fixture.reads.recorded.filter { $0 == "same_outer_reopened_on_retry" }.count == 1)
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up"],
                    "a positively observed closed exposure cannot renew its original inverse")
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == 42)
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            let current = await cache.getTracks()
            #expect(current.isEmpty)
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if knownInnerReopen || knownInnerReplacement {
            if knownInnerReopen {
                #expect(fixture.reads.recorded.filter { $0 == "inner_extractor_returned_zero" }.count == 1)
                #expect(fixture.reads.recorded.contains("inner_row_name_before_stack_read"))
            } else {
                #expect(!CFEqual(substitutedDisclosure, inner))
                #expect(fixture.reads.recorded.filter { $0 == "replacement_disclosure_installed" }.count == 1)
                #expect(fixture.reads.recorded.contains("replacement_disclosure_children_read"))
                #expect(fixture.reads.recorded.contains("replacement_disclosure_role_read"))
                #expect(fixture.reads.recorded.contains("replacement_disclosure_value_read"))
                if disclosureDecision == "role_loss" {
                    #expect(fixture.reads.recorded.contains("held_disclosure_button_role_read"))
                }
            }
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
            let expected = ["disclosure_down", "disclosure_up", "inner_down", "inner_up"]
                + (downFocusRead == "restoration" ? ["inner_down", "inner_up"] : [])
            #expect(fixture.events.recorded == expected,
                    "paired Up completes the held click, but unread focus forbids any later gesture")
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == (downFocusRead == "expansion" ? 44 : 42))
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == (downFocusRead == "expansion" ? 1 : 0))
            let focus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                runtime: fixture.builder.makeAXRuntime())
            #expect(CFEqual(try #require(focus), fixture.rail), "subsequent focus reads return the original healthy owner")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            let current = await cache.getTracks()
            #expect(current.isEmpty, "unread post-pair focus cannot certify current rows")
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if hiddenViewLoss {
            #expect(fixture.reads.recorded.filter { $0 == "hidden_view_held_header_missing" }.count == 1)
            #expect(fixture.reads.recorded.filter { $0 == "hidden_view_same_header_recovered" }.count == 1)
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up"],
                    "a positively sampled missing held header cannot regain inverse authority")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(body["snapshot_id"] == nil)
            #expect(await cache.getTracks().isEmpty)
            return
        }
        if let nestedFault {
            let lastReadFault = ["inner_closed", "replacement", "cancel_task_read"].contains(nestedFault)
                || nestedFault.hasPrefix("cancel_read")
            #expect(fixture.reads.recorded.filter { $0 == (lastReadFault ? "last_grandchild_fault" : "child_custody_fault") }.count == 1)
            if lastReadFault {
                #expect(fixture.reads.recorded.filter { $0 == "last_grandchild_title" }.count >= 3,
                        "fault reaches the last grandchild after actual row extraction has begun")
            }
            let cancelled = nestedFault == "cancel_read" || nestedFault == "cancel_task_read"
            let expectedEvents = ["disclosure_down", "disclosure_up", "inner_down", "inner_up"]
                + (cancelled ? ["inner_down", "inner_up", "disclosure_down", "disclosure_up"] : [])
            #expect(fixture.events.recorded == expectedEvents,
                    "cancellation restores held disclosures; actual custody conflicts and expired deadlines forbid inverses")
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == (cancelled ? 0 : 1))
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == (cancelled || nestedFault == "inner_closed" ? 0 : 1))
            if cancelled {
                #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == collapsed.count)
            }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == (cancelled ? "restored" : "not_restored"))
            let current = await cache.getTracks()
            #expect(current.isEmpty, "conflicted temporary rows are never current cache authority")
            if nestedFault.hasPrefix("retained_label_") {
                #expect(body["state"] as? String == "C" && body["snapshot_id"] == nil)
                #expect(!fixture.reads.recorded.contains("workspace_focus_setter"),
                        "lost passive focus never authorizes overwriting the current focus")
            }
            if lastReadFault && !cancelled && !nestedFault.hasPrefix("cancel_read") {
                #expect(body["state"] as? String == "C")
                #expect(body["error"] as? String == "stale_snapshot")
                #expect(body["tracks"] == nil && body["snapshot_id"] == nil,
                        "the conflicted capture is discarded, not issued as a new domain report")
                #expect(effects["reason"] as? String == "stack_navigation_ownership_lost")
            }
            if nestedFault == "cancel" || nestedFault == "deadline" || cancelled || nestedFault.hasPrefix("cancel_read") {
                #expect(body["state"] as? String == "C")
                #expect(body["error"] as? String == (nestedFault == "deadline" ? "operation_timeout" : "cancelled"))
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
        if lateScopeFault != nil {
            let injected = fixture.reads.recorded.contains("late_scope_fault_injected")
            let setterAttempted = fixture.reads.recorded.contains("workspace_focus_setter")
            #expect(injected)
            #expect(!setterAttempted, "a final held-focus read cannot authorize a setter after the document/window changes")
            let expectedStackEvents = ["disclosure_down", "disclosure_up", "inner_down", "inner_up",
                "inner_down", "inner_up", "disclosure_down", "disclosure_up"]
            #expect(fixture.events.recorded == (hiddenView ? ["hidden_menu"] + expectedStackEvents : expectedStackEvents))
            if hiddenView { #expect((fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == 1) }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String != "restored")
            if body["state"] as? String == "C" {
                #expect(body["snapshot_id"] == nil && body["tracks"] == nil)
            } else {
                let tracks = try #require(body["tracks"] as? [String: Any])
                #expect(tracks["coverage"] as? String == "unstable")
                let rows = try #require(tracks["rows"] as? [[String: Any]])
                #expect(rows.allSatisfy { $0["track_ref"] == nil })
            }
            #expect(await cache.getTracks().isEmpty)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            return
        }
        if let hiddenFocusFault {
            let faultBoundaryReached = fixture.reads.recorded.contains("hidden_focus_fault_boundary")
            #expect(faultBoundaryReached)
            #expect(fixture.events.recorded == ["hidden_menu", "disclosure_down", "disclosure_up", "inner_down", "inner_up",
                "inner_down", "inner_up", "disclosure_down", "disclosure_up"],
                "unverified original focus must not initiate the final Hide View inverse")
            #expect((fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            let setters = fixture.reads.recorded.filter { $0 == "workspace_focus_setter" }
            #expect(setters.count == (["declined", "wrong_readback", "post_focus_project"].contains(hiddenFocusFault) ? 1 : 0))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String != "restored")
            if body["state"] as? String == "C" {
                #expect(body["snapshot_id"] == nil && body["tracks"] == nil)
            } else {
                let tracks = try #require(body["tracks"] as? [String: Any])
                #expect(tracks["coverage"] as? String == "unstable")
                let rows = try #require(tracks["rows"] as? [[String: Any]])
                #expect(rows.allSatisfy { $0["track_ref"] == nil })
            }
            #expect(await cache.getTracks().isEmpty)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            return
        }
        if postAckForeignFocus {
            #expect(fixture.reads.recorded.contains("held_expansion_ack_read"))
            #expect(fixture.reads.recorded.contains("foreign_focus_after_held_ack"))
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up"])
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["changed"] as? [String] == ["stack_disclosure"],
                    "later custody refusal must retain the already observed UI change")
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(effects["reason"] as? String == "stack_navigation_ownership_lost")
            #expect(body["state"] as? String == "C" && body["snapshot_id"] == nil)
            #expect(await cache.getTracks().isEmpty)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if let headerFocus, headerFocus.hasPrefix("slider_"), headerFocus != "slider_held", headerFocus != "slider_to_label" {
            if headerFocus == "slider_to_foreign_label" {
                #expect(fixture.reads.recorded.contains("held_slider_focus_moved_by_owned_transport_read"))
            }
            if headerFocus == "slider_late_changed" || headerFocus == "slider_final_changed" {
                #expect(fixture.reads.recorded.contains("slider_value_changed_at_final_metadata"))
            }
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up"])
            #expect(!fixture.reads.recorded.contains("workspace_focus_setter"))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(["stack_navigation_ownership_lost", "stack_expansion_unverified", "stack_restoration_unverified"].contains(effects["reason"] as? String ?? ""))
            #expect(await cache.getTracks().isEmpty)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
            #expect(gate.currentOperation() == nil)
            return
        }
        if let focusRestoration {
            let restored = focusRestoration == "restored"
            if mouseCase == "held_header_focus" {
                #expect(fixture.reads.recorded.contains("completed_gesture_focused_original_header"))
            }
            if headerFocus == "slider_to_label" {
                #expect(fixture.reads.recorded.contains("held_slider_focus_moved_by_owned_transport_read"))
            }
            if retainOwnershipReadFocus {
                #expect(fixture.reads.recorded.contains("disclosure_focus_accepted_before_owned_read"))
                #expect(fixture.reads.recorded.contains("ownership_read_focus_retained_during_later_click"),
                        "the later nested gesture must leave the independently accepted outer label focused")
            }
            let setters = fixture.reads.recorded.filter { $0 == "workspace_focus_setter" }
            #expect(setters.count == (["restored", "declined", "wrong_readback"].contains(focusRestoration) ? 1 : 0))
            let stackEvents = nested
                ? ["disclosure_down", "disclosure_up", "inner_down", "inner_up",
                   "inner_down", "inner_up", "disclosure_down", "disclosure_up"]
                : ["disclosure_down", "disclosure_up", "disclosure_down", "disclosure_up"]
            #expect(fixture.events.recorded == (hiddenView ? ["hidden_menu"] + stackEvents + ["hidden_menu"] : stackEvents))
            if hiddenView {
                let inversePrecededWorkspaceFocus = fixture.reads.recorded.contains("hidden_inverse_before_workspace_focus")
                #expect(!inversePrecededWorkspaceFocus)
                #expect((fixture.builder.attributeValue(hide, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            }
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == 19)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == (restored ? "restored"
                : focusRestoration == "foreign_focus" ? "not_restored" : "partially_restored"))
            if restored {
                #expect(body["tracks"] != nil && body["snapshot_id"] != nil)
                if nested {
                    #expect(((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])?.count == 44)
                    #expect((fixture.builder.attributeValue(inner, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
                }
                let actualFocus: AXUIElement? = AXHelpers.getAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                    runtime: fixture.builder.makeAXRuntime())
                let focused = try #require(actualFocus)
                #expect(CFEqual(focused, workspace))
            } else { #expect(body["state"] as? String == "C" && body["snapshot_id"] == nil) }
            let current = await cache.getTracks()
            #expect(current.count == (restored ? 19 : 0))
            #expect(current.allSatisfy { $0.type == .unknown })
            // The explicit setter handler records its actual invocations above;
            // FakeAXRuntimeBuilder's default setter ledger is bypassed by it.
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
            #expect(gate.currentOperation() == nil)
            return
        }
        if let headerFocus, headerFocus.hasPrefix("initial_") {
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            if headerFocus == "initial_passive" {
                #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up", "disclosure_down", "disclosure_up"])
                #expect((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]] != nil)
                #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
                #expect(await cache.getTracks().count == 19)
            } else {
                #expect(fixture.events.recorded.isEmpty)
                #expect(body["state"] as? String == "C" && body["tracks"] == nil)
            }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            return
        }
        if let headerFocus {
            if headerFocus == "radio_role_sample" {
                #expect(fixture.reads.recorded.contains("passive_classifier_role_changed"))
            }
            let passive = headerFocus == "passive"
            #expect(fixture.events.recorded == (passive
                ? ["disclosure_down", "disclosure_up", "disclosure_down", "disclosure_up"]
                : ["disclosure_down", "disclosure_up"]))
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == (passive ? 19 : 42))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(body["state"] as? String == "C" && body["snapshot_id"] == nil)
            #expect(effects["restoration"] as? String == (passive ? "partially_restored" : "not_restored"))
            if passive { #expect(effects["reason"] as? String == "keyboard_focus_not_restored") }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
            #expect(gate.currentOperation() == nil)
            let current = await cache.getTracks()
            #expect(current.isEmpty, "partial focus restoration cannot publish a fully restored capture")
            return
        }
        if mouseCase == "unrelated_text_focus" {
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up"],
                    "a posted Down must receive its preconstructed paired Up before AX focus reads")
            #expect(!fixture.reads.recorded.contains("ax_read_during_held_down"))
            #expect(fixture.builder.makeAXRuntime().children(fixture.rail).count == 42)
            #expect((fixture.builder.attributeValue(disclosure, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(body["state"] as? String == "C" && body["snapshot_id"] == nil)
            let navigationPerformed = try #require(effects["navigation_performed"] as? Bool)
            #expect(navigationPerformed)
            #expect(effects["restoration"] as? String == "not_restored")
            #expect(effects["reason"] as? String != "stack_mouse_release_unverified")
            #expect((fixture.builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect((fixture.builder.attributeValue(record, kAXValueAttribute as String) as? NSNumber)?.intValue == 0)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty && gate.currentOperation() == nil)
            let current = await cache.getTracks()
            #expect(current.isEmpty, "unrelated focus must still refuse capture and inverse navigation")
            return
        }
        if let mouseCase {
            let expectedEvents = mouseCase == "wrong_hit" || mouseCase == "prepare_failed" ? [] : mouseCase == "down_failed" ? ["disclosure_down"]
                : mouseCase == "no_effect" ? ["disclosure_down", "disclosure_up"]
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
            if mouseCase == "no_effect" {
                #expect(effects["reason"] as? String == "stack_expansion_unverified",
                        "cleanup must preserve the observed forward failure, not invent ownership loss")
                #expect(effects["restoration"] as? String == "not_restored")
                let navigationPerformed = try #require(effects["navigation_performed"] as? Bool)
                #expect(navigationPerformed)
                #expect(body["state"] as? String == "C")
                #expect(body["tracks"] == nil && body["snapshot_id"] == nil)
                let current = await cache.getTracks()
                #expect(current.isEmpty, "an unqualified expansion cannot certify a current population")
            } else if mouseCase == "held_focus" {
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
        let completeForest = (completeHierarchy == "complete" || completeHierarchy == "complete_bottom") && revealedStack == nil
        let completePopulation = completeHierarchy == "complete" || completeHierarchy == "complete_bottom"
        #expect(tracks["coverage"] as? String == (completePopulation ? "complete" : "partial"),
            "only an independently complete all-shown page plus its bound saved count establishes the full population")
        if verifyHierarchy {
            let hierarchy = try #require(body["hierarchy"] as? [String: Any])
            if navigation {
                let exposures = try #require(hierarchy["disclosure_exposures"] as? [[String: Any]])
                #expect(hierarchy["coverage"] as? String == (completeForest ? "complete" : "partial"))
                #expect(exposures.count == (nested ? 2 : 1))
                #expect(exposures.first?["stack_ref"] as? String == rows[0]["track_ref"] as? String)
                #expect(exposures.first?["exposed_track_refs"] as? [String]
                    == headers[1...23].compactMap { header in
                        expectedHeaders.firstIndex(where: { CFEqual($0, header) }).flatMap { rows[$0]["track_ref"] as? String }
                    })
                if nested {
                    #expect(exposures[1]["stack_ref"] as? String == rows[1]["track_ref"] as? String)
                    #expect(exposures[1]["exposed_track_refs"] as? [String] == rows[2...3].compactMap { $0["track_ref"] as? String })
                }
                #expect(exposures.allSatisfy { $0["source"] as? String == "owned_disclosure_exposure" })
                if verifyDirectChildren {
                    if revealedStack == "late_open" {
                        #expect(fixture.reads.recorded.contains("revealed_stack_opened_after_scan"))
                        let isStack = try #require(rows[1]["is_stack_header"] as? Bool)
                        let collapsed = try #require(rows[1]["stack_collapsed"] as? Bool)
                        #expect(isStack)
                        #expect(!collapsed)
                    }
                    if revealedStack == nil {
                        #expect(exposures.allSatisfy {
                            $0["direct_child_track_refs"] as? [String] == $0["exposed_track_refs"] as? [String]
                        }, "closed revealed descendants distinguish direct children from an arbitrary exposure delta")
                        #expect(exposures.allSatisfy { $0["direct_children_source"] as? String == "owned_disclosure_closed_descendants" })
                    } else {
                        #expect(exposures.allSatisfy { $0["direct_child_track_refs"] == nil && $0["direct_children_source"] == nil },
                            "an already-open or Boolean child control cannot rule out exposed grandchildren")
                    }
                }
            } else {
                #expect(hierarchy["coverage"] as? String == "unavailable")
                #expect(hierarchy["disclosure_exposures"] == nil)
            }
            var observedParents: [String: String] = [:]
            if navigation, revealedStack == nil {
                let outer = try #require(rows[0]["track_ref"] as? String)
                for header in headers[1...23] {
                    let index = try #require(expectedHeaders.firstIndex(where: { CFEqual($0, header) }))
                    observedParents[try #require(rows[index]["track_ref"] as? String)] = outer
                }
                if nested {
                    let inner = try #require(rows[1]["track_ref"] as? String)
                    for row in rows[2...3] { observedParents[try #require(row["track_ref"] as? String)] = inner }
                }
            }
            for row in rows {
                let ref = try #require(row["track_ref"] as? String)
                if let parent = observedParents[ref] {
                    #expect(row["parent"] as? String == parent,
                        "qualified closed-descendant observations should project their captured physical parent")
                    #expect(row["parent_source"] as? String == "owned_disclosure_closed_descendants")
                } else {
                    if completeForest {
                        #expect(row["parent"] is NSNull)
                        #expect(row["parent_source"] as? String == "ax_complete_disclosure_population")
                    } else { #expect(row["parent"] as? String == "unknown" && row["parent_source"] == nil) }
                }
                if completeForest {
                    var depth = 0, current = ref
                    while let parent = observedParents[current] { depth += 1; current = parent }
                    #expect(row["depth"] as? Int == depth)
                    #expect(row["depth_source"] as? String == "ax_complete_disclosure_population")
                } else {
                    #expect(row["depth"] as? String == "unknown",
                        "partial population or missing direct-stack proof cannot establish absolute depth")
                }
            }
            let overall = try #require(body["overall"] as? [String: Any])
            let complete = try #require(overall["complete"] as? Bool)
            if completeForest { #expect(complete) } else { #expect(!complete) }
        }
        let current = await cache.getTracks()
        #expect(current.count == (initiallyExpanded ? 42 : 19), "collapsed descendants must not become ordinary current cache rows")
        if delayedLanding {
            #expect(fixture.reads.recorded.contains("pending_expansion_landing"))
            #expect(fixture.reads.recorded.contains("pending_restoration_landing"))
            #expect(fixture.events.recorded == ["disclosure_down", "disclosure_up", "disclosure_down", "disclosure_up"])
            let effects = try #require(body["ui_effects"] as? [String: Any])
            #expect(effects["restoration"] as? String == "restored")
        }
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

    private func passiveHeaderFocusFixture(fault: String? = nil) -> (Fixture, AXUIElement) {
        let fixture = Fixture()
        let label = fixture.builder.element(965_984)
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/965-passive-header.logicx/")
        fixture.builder.setRole(label, kAXTextFieldRole as String)
        fixture.builder.setAttribute(label, kAXValueAttribute as String, NSNumber(value: 0))
        fixture.builder.setAttribute(label, kAXWindowAttribute as String, fixture.window)
        fixture.builder.setAttributeSettable(label, kAXValueAttribute as String, false)
        fixture.builder.setChildren(label, [])
        fixture.builder.setChildren(fixture.header, [label])
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, label)
        fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, true)
        fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.window)
        switch fault {
        case "editable": fixture.builder.setAttributeSettable(label, kAXValueAttribute as String, true)
        case "string": fixture.builder.setAttribute(label, kAXValueAttribute as String, "0")
        case "boolean": fixture.builder.setAttribute(label, kAXValueAttribute as String, false)
        case "nonzero": fixture.builder.setAttribute(label, kAXValueAttribute as String, 1)
        case "insertion": fixture.builder.setAttribute(label, kAXInsertionPointLineNumberAttribute as String, 0)
        case "range": fixture.builder.setAttribute(label, kAXSelectedTextRangeAttribute as String, "")
        case "selected_text": fixture.builder.setAttribute(label, kAXSelectedTextAttribute as String, "")
        case "wrong_window": fixture.builder.setAttribute(label, kAXWindowAttribute as String, fixture.builder.element(965_985))
        case "wrong_parent": fixture.builder.setAttribute(label, kAXParentAttribute as String, fixture.rail)
        case "duplicate": fixture.builder.setChildren(fixture.header, [label, label])
        case "other_field":
            let other = fixture.builder.element(965_985)
            fixture.builder.setRole(other, kAXTextFieldRole as String)
            fixture.builder.setChildren(fixture.header, [label, other])
        case "not_frontmost": fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, false)
        case "wrong_focused_window": fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.builder.element(965_985))
        case "unbound": fixture.builder.removeAttribute(fixture.window, kAXDocumentAttribute as String)
        default: break
        }
        return (fixture, label)
    }

    @Test("passive track-read focus samples the retained app without rebuilding it on each guard")
    func passiveHeaderReadFocusReusesBoundAppButReadsFreshFocus() async throws {
        let (fixture, label) = passiveHeaderFocusFixture()
        let roots = Reads()
        let focusReads = Reads()
        let ax = fixture.builder.makeAXRuntime(appElementProvider: { _ in
            roots.record("app_root")
            return fixture.app
        }, attributeValueHandler: { element, attribute in
            if CFEqual(element, fixture.app), attribute == kAXFocusedUIElementAttribute as String {
                focusReads.record(attribute)
            }
            return nil
        }, attributeValueResultHandler: { element, attribute in
            guard CFEqual(element, label), attribute == kAXValueAttribute as String else { return nil }
            return .success(fixture.builder.attributeValue(label, attribute) as AnyObject?)
        }, setAttributeHandler: nil, performActionHandler: nil)
        let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("read focus cannot execute scripts"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("read focus cannot post Escape") },
            focusedApplicationPID: { 4242 })
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: ["domains": .array([.string("tracks")]), "allow_ui_navigation": .bool(false)],
            mutationGate: LogicMutationGate()) {
            guard let held = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope
                .PassiveHeaderReadFocus(window: fixture.window, logic: logic) else {
                Issue.record("positive fixture must bind its original passive label")
                return CallTool.Result(content: [], isError: true)
            }
            let boundRoots = roots.count
            let boundFocusReads = focusReads.count
            for _ in 0..<8 { #expect(held.permits()) }
            #expect(roots.count == boundRoots, "fresh focus guards must not rebuild the same PID-bound app")
            #expect(focusReads.count >= boundFocusReads + 8, "each guard still samples current focus")
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.header)
            #expect(!held.permits())
            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, label)
            #expect(!held.permits(), "restored focus cannot revive lost custody")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
            return CallTool.Result(content: [])
        }
        let failed = result.isError ?? false
        #expect(!failed)
    }

    @Test("passive focus revalidates its held rail without rediscovering unrelated window subtrees",
          arguments: ["identifier", "role", "rows", "path", "document", "title"])
    func passiveHeaderReadFocusRechecksHeldRail(fault: String) async throws {
        let (fixture, label) = passiveHeaderFocusFixture()
        let unrelated = fixture.builder.element(965_987)
        fixture.builder.setRole(unrelated, kAXGroupRole as String)
        fixture.builder.setChildren(unrelated, [])
        fixture.builder.setChildren(fixture.window, [fixture.rail, unrelated])
        let unrelatedReads = Reads()
        let ax = fixture.builder.makeAXRuntime(appElement: fixture.app,
            attributeValueHandler: { element, attribute in
                if CFEqual(element, unrelated) { unrelatedReads.record(attribute) }
                return nil
            }, attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, label), attribute == kAXValueAttribute as String else { return nil }
                return .success(fixture.builder.attributeValue(label, attribute) as AnyObject?)
            }, setAttributeHandler: nil, performActionHandler: nil)
        let logic = AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("read focus cannot execute scripts"); return .error("forbidden") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("read focus cannot post Escape") },
            focusedApplicationPID: { 4242 })
        let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
            commandParams: ["domains": .array([.string("tracks")]), "allow_ui_navigation": .bool(false)],
            mutationGate: LogicMutationGate()) {
            guard let held = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope
                .PassiveHeaderReadFocus(window: fixture.window, logic: logic) else {
                Issue.record("positive fixture must bind its original passive label")
                return CallTool.Result(content: [], isError: true)
            }
            let initialReads = unrelatedReads.count
            #expect(initialReads > 0, "initial binding still verifies the whole window")
            for _ in 0..<8 { #expect(held.permits()) }
            #expect(unrelatedReads.count == initialReads, "held focus checks must not rediscover unrelated subtrees")
            switch fault {
            case "identifier": fixture.builder.setAttribute(fixture.rail, kAXIdentifierAttribute as String, "Other")
            case "role": fixture.builder.setRole(fixture.rail, kAXButtonRole as String)
            case "rows": fixture.builder.setChildren(fixture.rail, [])
            case "path": fixture.builder.setChildren(fixture.window, [unrelated])
            case "document": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/other.logicx/")
            default: fixture.builder.setAttribute(fixture.window, kAXTitleAttribute as String, "Choose a Project")
            }
            #expect(!held.permits(), "fresh rail and original window custody remain required")
            fixture.builder.setRole(fixture.rail, kAXListRole as String)
            fixture.builder.setAttribute(fixture.rail, kAXIdentifierAttribute as String, "Track Headers")
            fixture.builder.setChildren(fixture.rail, [fixture.header])
            fixture.builder.setChildren(fixture.window, [fixture.rail, unrelated])
            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/965-passive-header.logicx/")
            fixture.builder.setAttribute(fixture.window, kAXTitleAttribute as String, "Session - Tracks")
            #expect(!held.permits(), "restoring the fixture cannot revive lost custody")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
            return CallTool.Result(content: [])
        }
        let failed = result.isError ?? false
        #expect(!failed)
    }

    @Test("a held immutable numeric track-name label permits only the navigation-disabled track read")
    func registeredPassiveHeaderLabelAllowsOnlyTrackRead() async throws {
        let (fixture, label) = passiveHeaderFocusFixture()
        let result = try await inspect(fixture: fixture, domains: ["tracks"],
            keyboardFocus: { .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) },
            readingAttribute: { element, attribute in
                guard CFEqual(element, label), attribute == kAXValueAttribute as String else { return nil }
                // Preserve NSNumber versus CFBoolean; the generic fake bridge
                // otherwise casts NSNumber(0) through its earlier Bool case.
                return .success(fixture.builder.attributeValue(label, attribute) as AnyObject?)
            })
        let error = result.isError ?? false
        #expect(!error)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let rows = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.compactMap { $0["name"] as? String } == [" Fresh track "])
        #expect(fixture.reads.helpCount == 0)
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: ["editable", "string", "boolean", "nonzero", "insertion", "range", "selected_text",
                      "wrong_window", "wrong_parent", "duplicate", "other_field", "not_frontmost",
                      "wrong_focused_window", "unbound"])
    func registeredPassiveHeaderLabelRejectsUnsafeOrAmbiguousFocus(fault: String) async throws {
        let (fixture, label) = passiveHeaderFocusFixture(fault: fault)
        let result = try await inspect(fixture: fixture, domains: ["tracks"],
            keyboardFocus: { .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) },
            readingAttribute: { element, attribute in
                guard CFEqual(element, label), attribute == kAXValueAttribute as String else { return nil }
                return .success(fixture.builder.attributeValue(label, attribute) as AnyObject?)
            })
        let error = result.isError ?? false
        #expect(error)
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func registeredPassiveHeaderLabelCannotAuthorizeHelpOrNavigation(navigation: Bool) async throws {
        let (fixture, label) = passiveHeaderFocusFixture()
        let result = try await inspect(fixture: fixture, domains: navigation ? ["tracks"] : ["tracks", "strips"],
            navigation: navigation,
            keyboardFocus: { .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) },
            readingAttribute: { element, attribute in
                guard CFEqual(element, label), attribute == kAXValueAttribute as String else { return nil }
                return .success(fixture.builder.attributeValue(label, attribute) as AnyObject?)
            })
        let error = result.isError ?? false
        #expect(error)
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: ["focus", "document", "editable", "label", "rail", "window"])
    func registeredPassiveHeaderLabelLosesOriginalReadCustody(fault: String) async throws {
        let (fixture, label) = passiveHeaderFocusFixture()
        let checks = Reads()
        let result = try await inspect(fixture: fixture, domains: ["tracks"],
            keyboardFocus: { .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) },
            readingAttribute: { element, attribute in
                guard CFEqual(element, label) else { return nil }
                if attribute == kAXSelectedTextAttribute as String {
                    checks.record(attribute)
                    if checks.count == 2 {
                        switch fault {
                        case "focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.header)
                        case "document": fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/other.logicx/")
                        case "editable": fixture.builder.setAttributeSettable(label, kAXValueAttribute as String, true)
                        case "label": fixture.builder.setChildren(fixture.header, [])
                        case "rail": fixture.builder.setChildren(fixture.window, [])
                        default: fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.builder.element(965_986))
                        }
                    }
                }
                if attribute == kAXValueAttribute as String {
                    return .success(fixture.builder.attributeValue(label, attribute) as AnyObject?)
                }
                return nil
            })
        let error = result.isError ?? false
        #expect(error)
        #expect(checks.count >= 2)
        #expect(fixture.reads.helpCount == 0)
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    private func passiveMixerFocusFixture(fault: String? = nil) -> (Fixture, AXUIElement) {
        let fixture = Fixture()
        let outer = fixture.builder.element(965_980)
        let mixer = fixture.builder.element(965_981)
        let focus = fixture.builder.element(965_982)
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String,
                                     "file:///tmp/965-passive-mixer-focus.logicx/")
        fixture.builder.setRole(outer, kAXGroupRole as String)
        fixture.builder.setAttribute(outer, kAXDescriptionAttribute as String, "Mixer")
        fixture.builder.setRole(mixer, kAXLayoutAreaRole as String)
        fixture.builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        fixture.builder.setRole(focus, kAXLayoutItemRole as String)
        fixture.builder.setAttribute(focus, kAXDescriptionAttribute as String, "An observed strip")
        fixture.builder.setAttribute(focus, kAXNumberOfCharactersAttribute as String, 0)
        fixture.builder.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, 0)
        fixture.builder.setChildren(focus, [])
        fixture.builder.setChildren(mixer, [focus])
        fixture.builder.setChildren(outer, [mixer])
        fixture.builder.setChildren(fixture.window, [fixture.rail, outer])
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, focus)
        fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, true)
        fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.window)
        fixture.builder.setAttributeSettable(focus, kAXValueAttribute as String, false)
        switch fault {
        case "editor_role": fixture.builder.setRole(focus, kAXTextFieldRole as String)
        case "other_role": fixture.builder.setRole(focus, kAXGroupRole as String)
        case "characters": fixture.builder.setAttribute(focus, kAXNumberOfCharactersAttribute as String, 1)
        case "insertion_line": fixture.builder.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, 1)
        case "boolean_line": fixture.builder.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, false)
        case "string_line": fixture.builder.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, "0")
        case "boolean_characters": fixture.builder.setAttribute(focus, kAXNumberOfCharactersAttribute as String, false)
        case "settable_value": fixture.builder.setAttributeSettable(focus, kAXValueAttribute as String, true)
        case "not_frontmost": fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, false)
        case "foreign_window": fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String,
                                                             fixture.builder.element(965_983))
        case "wrong_parent": fixture.builder.setAttribute(focus, kAXParentAttribute as String, fixture.rail)
        case "foreign_focus": fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                                                            fixture.builder.element(965_983))
        case "detached": fixture.builder.setChildren(mixer, [])
        case "duplicate": fixture.builder.setChildren(mixer, [focus, focus])
        case "unbound_document": fixture.builder.removeAttribute(fixture.window, kAXDocumentAttribute as String)
        default: break
        }
        return (fixture, focus)
    }

    @Test("a fresh Mixer population does not query focus-moving scalar Help",
          arguments: ["none", "indicator", "slider", "text"])
    func registeredMixerReadOmitsFocusMovingScalarHelp(childShape: String) async throws {
        let (fixture, focus) = passiveMixerFocusFixture()
        let volume = fixture.builder.element(965_987)
        let pan = fixture.builder.element(965_988)
        let scalarReads = Reads()
        for (slider, name, value) in [(volume, "Volume", 0.75), (pan, "Pan", 0.25)] {
            fixture.builder.setRole(slider, kAXSliderRole as String)
            fixture.builder.setAttribute(slider, kAXDescriptionAttribute as String, name)
            fixture.builder.setAttribute(slider, kAXHelpAttribute as String, name)
            fixture.builder.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
            fixture.builder.setAttribute(slider, kAXMaxValueAttribute as String, 1.0)
            fixture.builder.setAttribute(slider, kAXValueAttribute as String, value)
            fixture.builder.setChildren(slider, [])
        }
        if childShape != "none" {
            let indicator = fixture.builder.element(965_989)
            let role = childShape == "slider" ? kAXSliderRole as String
                : childShape == "text" ? kAXStaticTextRole as String : kAXValueIndicatorRole as String
            fixture.builder.setRole(indicator, role)
            fixture.builder.setChildren(indicator, [])
            fixture.builder.setChildren(childShape == "text" ? pan : volume, [indicator])
        }
        fixture.builder.setChildren(focus, [volume, pan])
        let result = try await inspect(fixture: fixture, domains: ["strips"],
            readingAttribute: { element, attribute in
                if attribute == kAXHelpAttribute as String,
                   CFEqual(element, volume) || CFEqual(element, pan) {
                    scalarReads.record(attribute)
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, element)
                }
                return nil
            })
        let isError = result.isError ?? false
        #expect(!isError)
        #expect(scalarReads.count == 0, "Scalar metadata is not permission to move focus during a fresh population")
        let held = try #require(fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String))
        #expect(CFEqual(held as AnyObject, focus))
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test("fresh Mixer discovery omits focus-moving Help on a completely read header control forest")
    func registeredMixerDiscoveryOmitsFocusMovingHeaderHelp() async throws {
        let (fixture, focus) = passiveMixerFocusFixture()
        let roles = [kAXRadioButtonRole, kAXSplitterRole, kAXDisclosureTriangleRole,
                     kAXCheckBoxRole, kAXSliderRole, kAXTextFieldRole] as [String]
        var controls: [AXUIElement] = []
        for (index, role) in roles.enumerated() {
            let control = fixture.builder.element(965_990 + index)
            fixture.builder.setRole(control, role)
            fixture.builder.setChildren(control, [])
            controls.append(control)
        }
        let thumb = fixture.builder.element(965_996)
        fixture.builder.setRole(thumb, kAXSliderRole as String)
        fixture.builder.setChildren(thumb, [])
        fixture.builder.setChildren(controls[4], [thumb])
        fixture.builder.setChildren(fixture.header, controls)
        fixture.builder.setAttribute(fixture.header, kAXHelpAttribute as String, "Track header. Mute or solo the track.")
        let headerHelp = Reads()
        let result = try await inspect(fixture: fixture, domains: ["strips"],
            readingAttribute: { element, attribute in
                if CFEqual(element, fixture.header), attribute == kAXHelpAttribute as String {
                    headerHelp.record(attribute)
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.header)
                }
                return nil
            })
        let isError = result.isError ?? false
        #expect(!isError)
        #expect(headerHelp.count == 0, "A fully read forest of non-Mixer controls needs no Inspector exclusion")
        let held = try #require(fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String))
        #expect(CFEqual(held as AnyObject, focus))
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    private func passiveMixerAttributeRead(_ focus: AXUIElement, fault: String? = nil)
        -> @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>? {
        { element, attribute in
            guard CFEqual(element, focus) else { return nil }
            if attribute == kAXValueAttribute as String || attribute == kAXSelectedTextAttribute as String {
                if fault == "text_value", attribute == kAXValueAttribute as String { return .success("editing" as NSString) }
                if fault == "selected_text", attribute == kAXSelectedTextAttribute as String { return .success("" as NSString) }
                if fault == "unread_value", attribute == kAXValueAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return .failure(.init(raw: AXError.noValue.rawValue))
            }
            return nil
        }
    }

    @Test func registeredSelectAllDispatchSettlesBeforeOwnedMenuCleanup() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1, fault: "delayed_dispatch")
    }

    @Test func registeredSelectAllObservesDelayedNativeSelectionAfterClosedMenuACK() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "timed_dispatch_healthy")
    }

    @Test func registeredSelectAllWaitsForItsEarlyFirstFocusBeforeSelectionCompletes() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "timed_dispatch_early_first_focus")
    }

    @Test func registeredSelectAllFirstFocusCanArriveAfterItsPreHoldRead() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "timed_dispatch_held_first_focus")
    }

    @Test func registeredSelectAllFirstFocusCanArriveDuringPostReferenceFocusRead() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "timed_dispatch_held_first_focus_after_reference")
    }

    @Test func registeredSelectAllInverseWaitsForItsOriginalSelectionAndFocus() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "select_all_first_focus_inverse_dispatch")
    }

    @Test func registeredSelectAllFirstFocusCanArriveAtItsInverseAcknowledgement() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "select_all_first_focus_inverse_only_dispatch")
    }

    @Test func registeredOriginalMixerReadFocusSurvivesOwnedSelectionReturn() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "full_population_shared_original_mixer_focus_return")
    }

    @Test(arguments: ["subset", "foreign", "document", "focus", "transport", "unread", "cancel", "census"])
    func registeredSelectAllLateInverseFocusCannotReplaceCompleteSelectionOrCustody(fault: String) async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "select_all_first_focus_inverse_only_dispatch_" + fault)
    }

    @Test(arguments: ["noop", "subset", "foreign", "document", "focus", "transport", "unread", "cancel", "census", "geometry"])
    func registeredSelectAllInverseSettlementCannotReplaceOriginalCustody(fault: String) async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "select_all_first_focus_inverse_dispatch_" + fault)
    }

    @Test(arguments: ["noop", "subset", "foreign", "document", "focus", "transport", "unread", "cancel"])
    func registeredHeldFirstFocusCannotReplaceCompleteSelectionOrCustody(fault: String) async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "timed_dispatch_held_first_focus_" + fault)
    }

    @Test(arguments: ["noop", "subset", "foreign", "document", "focus", "transport", "unread", "cancel"])
    func registeredEarlyFirstFocusCannotReplaceCompleteSelectionOrCustody(fault: String) async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "timed_dispatch_early_first_focus_" + fault)
    }

    @Test(arguments: ["noop", "subset", "foreign", "document", "focus", "transport", "unread", "cancel"])
    func registeredDelayedSelectionCannotSupplyMissingCustody(fault: String) async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "timed_dispatch_" + fault)
    }

    @Test func registeredSelectAllSettlesBetweenPostReadAndInverseRead() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1, fault: "late_deciding_settlement")
    }

    @Test func registeredOwnedSelectAllReturnsFirstStripFocusThenRestoresNonfirstOriginal() async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1, fault: "select_all_first_focus")
    }

    @Test(arguments: ["partial", "foreign", "document", "unacked"])
    func registeredSelectAllFirstFocusRequiresTheExactIssuedCompleteSelection(fault: String) async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1,
            fault: "select_all_first_focus_" + fault)
    }

    @Test(arguments: ["late_deciding_foreign", "late_deciding_subset", "late_deciding_unread", "late_deciding_document", "late_deciding_cancel"])
    func registeredLateSelectAllSettlementDoesNotAdoptUnknownOrForeignSelection(fault: String) async throws {
        try await registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: 1, fault: fault)
    }

    @Test("owned Mixer Select All observes offscreen population and restores the actual original subset",
          arguments: [1, 2, 4], ["healthy", "no_navigation", "not_all", "filter_off", "hidden_off", "not_settable",
                             "unread_selection", "duplicate_original", "missing_menu", "duplicate_menu", "noop_selection",
                             "omitted_offscreen", "foreign_selected", "duplicate_selected", "malformed_selected",
                             "late_document", "late_focus", "replaced_census", "restore_ack_only", "restore_false",
                             "restore_geometry", "restore_visible", "before_menu_document", "before_leaf_document", "inverse_deciding_document",
                             "restore_selected_focus", "restore_focus_false", "restore_focus_ack_only",
                             "restore_focus_foreign", "restore_focus_unselected", "restore_focus_document",
                             "restore_focus_selection_drift", "full_population_restore_focus",
                             "full_population_foreign_focus", "full_population_document",
                             "full_population_shared", "full_population_shared_final_value", "full_population_shared_final_owner",
                             "full_population_shared_final_document", "full_population_shared_final_filter",
                             "before_leaf_transport_document"])
    func registeredOwnedMixerSelectAllProvesPopulationAndRestoresSelection(originalCount: Int, fault: String) async throws {
        let fixture = hiddenViewFixture(shown: fault != "hidden_off")
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/MixerPopulation.logicx")
        fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, true)
        let fullPopulation = fault.hasPrefix("full_population_")
        let originalMixerReturn = fault == "full_population_shared_original_mixer_focus_return"
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("965-mixer-selection-\(UUID().uuidString).logicx")
        if fullPopulation {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, bundle.absoluteString)
        }
        defer { if fullPopulation { try? FileManager.default.removeItem(at: bundle) } }
        let otherHeader = fixture.builder.element(966_070)
        if fullPopulation {
            fixture.builder.setRole(otherHeader, kAXLayoutItemRole as String)
            fixture.builder.setAttribute(otherHeader, kAXTitleAttribute as String, "Other track")
            fixture.builder.setAttribute(otherHeader, kAXSelectedAttribute as String, false)
            fixture.builder.setChildren(otherHeader, [])
            fixture.builder.setChildren(fixture.rail, [fixture.header, otherHeader])
            fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [fixture.header])
            fixture.builder.setAttributeSettable(fixture.rail, kAXSelectedChildrenAttribute as String, true)
            fixture.builder.setAttribute(fixture.app, kAXWindowsAttribute as String, [fixture.window])
        }
        let owner = fixture.builder.element(966_000), mixer = fixture.builder.element(966_001)
        let toolbar = fixture.builder.element(966_002), filters = fixture.builder.element(966_003)
        let strips = (0..<4).map { fixture.builder.element(966_010 + $0) }
        for group in [owner, toolbar, filters] { fixture.builder.setRole(group, kAXGroupRole as String) }
        for group in [owner, toolbar, mixer] { fixture.builder.setAttribute(group, kAXDescriptionAttribute as String, "Mixer") }
        fixture.builder.setRole(mixer, kAXLayoutAreaRole as String)
        let modeLabels = ["Single", "Tracks", "All"]
        let modes = modeLabels.enumerated().map { index, label -> AXUIElement in
            let node = fixture.builder.element(966_020 + index)
            fixture.builder.setRole(node, kAXRadioButtonRole as String)
            fixture.builder.setAttribute(node, kAXDescriptionAttribute as String, label)
            fixture.builder.setAttribute(node, kAXValueAttribute as String, index == 2 ? 1 : 0)
            fixture.builder.setChildren(node, [])
            return node
        }
        let labels = ["Audio", "Inst", "Aux", "Bus", "Input", "Output", "Master/VCA", "MIDI"]
        let filterControls = labels.enumerated().map { index, label -> AXUIElement in
            let node = fixture.builder.element(966_030 + index)
            fixture.builder.setRole(node, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(node, kAXDescriptionAttribute as String, label)
            fixture.builder.setAttribute(node, kAXValueAttribute as String, 1)
            fixture.builder.setChildren(node, [])
            return node
        }
        for (index, strip) in strips.enumerated() {
            fixture.builder.setRole(strip, kAXLayoutItemRole as String)
            fixture.builder.setAttribute(strip, kAXNumberOfCharactersAttribute as String, 0)
            fixture.builder.setAttribute(strip, kAXInsertionPointLineNumberAttribute as String, 0)
            fixture.builder.setAttributeSettable(strip, kAXValueAttribute as String, false)
            fixture.builder.setAttributeSettable(strip, kAXFocusedAttribute as String, true)
            let name = fixture.builder.element(966_040 + index)
            fixture.builder.setRole(name, kAXTextFieldRole as String)
            fixture.builder.setAttribute(name, kAXDescriptionAttribute as String, "Name")
            fixture.builder.setAttribute(name, kAXValueAttribute as String, "Physical \(index)")
            fixture.builder.setChildren(name, [])
            fixture.builder.setChildren(strip, [name])
        }
        fixture.builder.setChildren(filters, filterControls)
        fixture.builder.setChildren(toolbar, modes + [filters])
        fixture.builder.setChildren(mixer, strips)
        fixture.builder.setChildren(owner, [toolbar, mixer])
        for (index, element) in ([mixer] + strips).enumerated() {
            var point = CGPoint(x: Double(index * 80), y: 440)
            var size = CGSize(width: index == 0 ? 320 : 80, height: 640)
            fixture.builder.setAttribute(element, kAXPositionAttribute as String, AXValueCreate(.cgPoint, &point)!)
            fixture.builder.setAttribute(element, kAXSizeAttribute as String, AXValueCreate(.cgSize, &size)!)
        }
        fixture.builder.setAttribute(mixer, kAXVisibleChildrenAttribute as String, Array(strips.suffix(2)))
        let original = Array(strips.suffix(originalCount))
        fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, original)
        fixture.builder.setAttributeSettable(mixer, kAXSelectedChildrenAttribute as String, true)
        if fault == "not_all" {
            fixture.builder.setAttribute(modes[2], kAXValueAttribute as String, 0)
            fixture.builder.setAttribute(modes[1], kAXValueAttribute as String, 1)
        }
        if fault == "filter_off" { fixture.builder.setAttribute(filterControls[2], kAXValueAttribute as String, 0) }
        if fault == "not_settable" { fixture.builder.setAttributeSettable(mixer, kAXSelectedChildrenAttribute as String, false) }
        if fault == "duplicate_original" { fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [strips[3], strips[3]]) }
        let earlyFirstFocus = fault.hasPrefix("timed_dispatch_early_first_focus")
        let heldFirstFocus = fault.hasPrefix("timed_dispatch_held_first_focus")
        let firstFocusTransition = fault.hasPrefix("select_all_first_focus") || earlyFirstFocus || heldFirstFocus || originalMixerReturn
        let initialFocus = firstFocusTransition ? original[0] : strips[0]
        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, initialFocus)
        fixture.builder.setAttribute(fixture.app, kAXFocusedWindowAttribute as String, fixture.window)
        fixture.builder.setAttribute(fixture.app, kAXFrontmostAttribute as String, true)
        let bar = fixture.builder.element(966_050), edit = fixture.builder.element(966_051), selectAll = fixture.builder.element(966_052)
        fixture.builder.setRole(bar, kAXMenuBarRole as String)
        fixture.builder.setRole(edit, kAXMenuBarItemRole as String)
        fixture.builder.setAttribute(edit, kAXTitleAttribute as String, "Edit")
        fixture.builder.setAttribute(edit, kAXSelectedAttribute as String, false)
        fixture.builder.setActionNames(edit, [kAXPressAction as String, kAXCancelAction as String])
        fixture.builder.setRole(selectAll, kAXMenuItemRole as String)
        fixture.builder.setAttribute(selectAll, kAXIdentifierAttribute as String, "selectAll:")
        fixture.builder.setAttribute(selectAll, kAXTitleAttribute as String, "Select All")
        fixture.builder.setAttribute(selectAll, kAXEnabledAttribute as String, true)
        fixture.builder.setActionNames(selectAll, [kAXPressAction as String])
        fixture.builder.setChildren(selectAll, [])
        fixture.builder.setChildren(edit, [selectAll])
        if fault == "missing_menu" { fixture.builder.setChildren(edit, []) }
        if fault == "duplicate_menu" {
            let duplicate = fixture.builder.element(966_053)
            fixture.builder.setRole(duplicate, kAXMenuItemRole as String)
            fixture.builder.setAttribute(duplicate, kAXIdentifierAttribute as String, "selectAll:")
            fixture.builder.setChildren(duplicate, [])
            fixture.builder.setChildren(edit, [selectAll, duplicate])
        }
        fixture.builder.setChildren(bar, [edit])
        fixture.builder.setAttribute(fixture.app, kAXMenuBarAttribute as String, bar)
        let roots = AXHelpers.getChildren(fixture.window, runtime: fixture.builder.makeAXRuntime())
        let transport = fixture.builder.element(966_060)
        fixture.builder.setRole(transport, kAXGroupRole as String)
        fixture.builder.setAttribute(transport, kAXDescriptionAttribute as String, "Control Bar")
        let controls = ["Play", "Record"].enumerated().map { index, title -> AXUIElement in
            let control = fixture.builder.element(966_061 + index)
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(control, kAXTitleAttribute as String, title)
            fixture.builder.setAttribute(control, kAXValueAttribute as String, 0)
            fixture.builder.setChildren(control, [])
            return control
        }
        fixture.builder.setChildren(transport, controls)
        fixture.builder.setChildren(fixture.window, roots + [owner, transport])
        let selectionReads = Reads()
        let originalMixerGuardReads = Reads()
        let selectionClock = SelectionDispatchClock()
        let inverseClock = SelectionDispatchClock()
        let inverseOnlyFirstFocus = fault.hasPrefix("select_all_first_focus_inverse_only_dispatch")
        let delayedInverse = fault.hasPrefix("select_all_first_focus_inverse_dispatch") || inverseOnlyFirstFocus
        let healthyDelayedInverse = ["select_all_first_focus_inverse_dispatch", "select_all_first_focus_inverse_only_dispatch"].contains(fault)
        let timedDispatch = fault.hasPrefix("timed_dispatch_")
        let dispatchFault = fault.replacingOccurrences(of: "timed_dispatch_early_first_focus", with: "timed_dispatch")
            .replacingOccurrences(of: "timed_dispatch_held_first_focus", with: "timed_dispatch")
        let sharedRead = fault.hasPrefix("full_population_shared")
        let snapshotReads = Reads()
        let nativeRead = passiveMixerAttributeRead(initialFocus)
        let selectionReturnsFocus = fault == "restore_selected_focus" || fault.hasPrefix("restore_focus_") || fullPopulation || firstFocusTransition
        let result = try await inspect(fixture: fixture,
            domains: fullPopulation ? ["tracks", "hierarchy", "strips", "associations"] : ["tracks", "strips"], navigation: fault != "no_navigation",
            targetReferences: fullPopulation,
            keyboardFocus: {
                if originalMixerReturn, fixture.events.recorded.contains("select_all"),
                   !fixture.events.recorded.contains("restore_mixer_selection") {
                    originalMixerGuardReads.record("editing_guard")
                }
                return selectionReturnsFocus
                    ? .textEditing(role: kAXLayoutItemRole as String, byInsertionPoint: true) : .notTextEditing
            },
            observationAction: { element, action in
                if CFEqual(element, edit) {
                    fixture.events.record(action == kAXPressAction as String ? "open_edit" : "cancel_edit")
                    if fault == "delayed_dispatch", action == kAXCancelAction as String,
                       !selectionReads.recorded.contains("delayed_dispatch_settled") {
                        selectionReads.record("delayed_dispatch_cancelled")
                    }
                    fixture.builder.setAttribute(edit, kAXSelectedAttribute as String, action == kAXPressAction as String)
                    return true
                }
                if CFEqual(element, selectAll), action == kAXPressAction as String {
                    fixture.events.record("select_all")
                    if fault == "delayed_dispatch" { return true }
                    if timedDispatch {
                        // The native ACK and menu closure precede selection. No
                        // background task writes the fixture, even after return.
                        selectionClock.accept()
                        fixture.builder.setAttribute(edit, kAXSelectedAttribute as String, false)
                        if earlyFirstFocus {
                            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, strips[0])
                            selectionReads.record("early_first_focus")
                        }
                        return true
                    }
                    if fault != "noop_selection" && !fault.hasPrefix("late_deciding_") {
                        fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips)
                    }
                    if fault == "omitted_offscreen" { fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, Array(strips.suffix(2))) }
                    if fault == "foreign_selected" { fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips + [fixture.header]) }
                    if fault == "duplicate_selected" { fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips + [strips[0]]) }
                    if fault == "malformed_selected" { fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, NSNumber(value: 4)) }
                    if fault == "late_document" { fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx") }
                    if fault == "late_focus" { fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.header) }
                    if fault == "replaced_census" { fixture.builder.setChildren(mixer, Array(strips.dropLast())) }
                    if firstFocusTransition, !inverseOnlyFirstFocus {
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                            fault == "select_all_first_focus_foreign" ? fixture.header : strips[0])
                        if fault == "select_all_first_focus_partial" {
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, [strips[0]])
                        }
                        if fault == "select_all_first_focus_document" {
                            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                    }
                    fixture.builder.setAttribute(edit, kAXSelectedAttribute as String, false)
                    return fault != "select_all_first_focus_unacked"
                }
                return nil
            }, focusSetter: { element, attribute, value in
                if fullPopulation, CFEqual(element, fixture.rail), attribute == kAXSelectedChildrenAttribute as String,
                   CFGetTypeID(value) == CFArrayGetTypeID(),
                   let selected = AXHelpers.decodeChildrenArray(value).first {
                    fixture.events.record("association_select")
                    let initial = CFEqual(selected, fixture.header)
                    fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, initial)
                    fixture.builder.setAttribute(otherHeader, kAXSelectedAttribute as String, !initial)
                    fixture.builder.setAttribute(fixture.rail, attribute, value)
                    fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, initial ? original : [strips[1]])
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String,
                        initial ? (originalMixerReturn ? initialFocus : strips[0]) : strips[1])
                    return true
                }
                if CFEqual(element, initialFocus), attribute == kAXFocusedAttribute as String {
                    fixture.events.record("restore_captured_focus")
                    if fault != "restore_focus_ack_only" {
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, initialFocus)
                    }
                    if fault == "restore_focus_selection_drift" {
                        fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips)
                    }
                    if sharedRead, fixture.events.recorded.contains("select_all") {
                        if fault == "full_population_shared_final_value" {
                            fixture.builder.setAttribute(fixture.builder.element(966_040), kAXValueAttribute as String, "Changed after acquisition")
                        }
                        if fault == "full_population_shared_final_owner" {
                            fixture.builder.setChildren(mixer, Array(strips.dropLast()))
                        }
                    }
                    return fault != "restore_focus_false"
                }
                guard CFEqual(element, mixer), attribute == kAXSelectedChildrenAttribute as String else { return false }
                fixture.events.record("restore_mixer_selection")
                if delayedInverse {
                    if inverseOnlyFirstFocus {
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, strips[0])
                        selectionReads.record("inverse_only_first_focus")
                        switch fault {
                        case "select_all_first_focus_inverse_only_dispatch_subset":
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, Array(strips.prefix(2)))
                        case "select_all_first_focus_inverse_only_dispatch_foreign":
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips + [fixture.header])
                        case "select_all_first_focus_inverse_only_dispatch_document":
                            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        case "select_all_first_focus_inverse_only_dispatch_focus":
                            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.header)
                        case "select_all_first_focus_inverse_only_dispatch_transport":
                            fixture.builder.setAttribute(controls[0], kAXValueAttribute as String, 1)
                        case "select_all_first_focus_inverse_only_dispatch_cancel":
                            withUnsafeCurrentTask { $0?.cancel() }
                        case "select_all_first_focus_inverse_only_dispatch_census":
                            fixture.builder.setChildren(mixer, Array(strips.dropLast()))
                        default: break
                        }
                    }
                    inverseClock.accept()
                    return true
                }
                if fault != "restore_ack_only" { fixture.builder.setAttribute(mixer, attribute, value) }
                if selectionReturnsFocus {
                    let returned = ["restore_focus_foreign", "full_population_foreign_focus"].contains(fault) ? fixture.header
                        : fault == "restore_focus_unselected" ? strips[1] : original[0]
                    fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, returned)
                    if ["restore_focus_document", "full_population_document"].contains(fault) {
                        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                }
                if fault == "restore_geometry" {
                    var moved = CGPoint(x: 7, y: 440)
                    fixture.builder.setAttribute(mixer, kAXPositionAttribute as String, AXValueCreate(.cgPoint, &moved)!)
                }
                if fault == "restore_visible" { fixture.builder.setAttribute(mixer, kAXVisibleChildrenAttribute as String, [strips[3]]) }
                return fault != "restore_false"
            }, readingAttribute: { element, attribute in
                if originalMixerReturn, CFEqual(element, strips[0]), attribute == kAXNumberOfCharactersAttribute as String,
                   fixture.events.recorded.contains("select_all"), !fixture.events.recorded.contains("restore_mixer_selection") {
                    selectionReads.record("owned_first_focus_metadata_read")
                    if originalMixerGuardReads.count > 0,
                       !selectionReads.recorded.contains("owned_first_focus_metadata_unread") {
                        // One unavailable read of the temporary first-focus
                        // witness must not retire the separately captured
                        // original passive strip when our inverse returns it.
                        selectionReads.record("owned_first_focus_metadata_unread")
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                }
                if delayedInverse, (!inverseOnlyFirstFocus || healthyDelayedInverse),
                   fixture.events.recorded.contains("restore_mixer_selection"),
                   inverseClock.settled, !selectionReads.recorded.contains("inverse_dispatch_settled") {
                    selectionReads.record("inverse_dispatch_settled")
                    if fault != "select_all_first_focus_inverse_dispatch_noop" {
                        fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, original)
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, initialFocus)
                    }
                    switch fault {
                    case "select_all_first_focus_inverse_dispatch_subset":
                        fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, Array(strips.prefix(2)))
                    case "select_all_first_focus_inverse_dispatch_foreign":
                        fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, original + [fixture.header])
                    case "select_all_first_focus_inverse_dispatch_document":
                        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    case "select_all_first_focus_inverse_dispatch_focus":
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.header)
                    case "select_all_first_focus_inverse_dispatch_transport":
                        fixture.builder.setAttribute(controls[0], kAXValueAttribute as String, 1)
                    case "select_all_first_focus_inverse_dispatch_cancel":
                        withUnsafeCurrentTask { $0?.cancel() }
                    case "select_all_first_focus_inverse_dispatch_census":
                        fixture.builder.setChildren(mixer, Array(strips.dropLast()))
                    case "select_all_first_focus_inverse_dispatch_geometry":
                        var moved = CGPoint(x: 7, y: 440)
                        fixture.builder.setAttribute(mixer, kAXPositionAttribute as String, AXValueCreate(.cgPoint, &moved)!)
                    default: break
                    }
                }
                if fault == "select_all_first_focus_inverse_dispatch_unread",
                   selectionReads.recorded.contains("inverse_dispatch_settled"), CFEqual(element, mixer),
                   attribute == kAXSelectedChildrenAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if fault == "select_all_first_focus_inverse_only_dispatch_unread",
                   fixture.events.recorded.contains("restore_mixer_selection"), CFEqual(element, mixer),
                   attribute == kAXSelectedChildrenAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if heldFirstFocus, CFEqual(element, fixture.app), attribute == kAXFocusedUIElementAttribute as String,
                   fixture.events.recorded.contains("select_all"), !fixture.events.recorded.contains("restore_mixer_selection") {
                    let before = fixture.builder.attributeValue(element, attribute)
                    selectionReads.record("post_leaf_focus_read")
                    let boundary = fault == "timed_dispatch_held_first_focus_after_reference" ? 3 : 2
                    if selectionReads.recorded.filter({ $0 == "post_leaf_focus_read" }).count == boundary {
                        // The loop's pre-hold read still observes the original
                        // focus; native focus moves before held custody renews.
                        fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, strips[0])
                        selectionReads.record("held_first_focus")
                    }
                    return .success(before.map { $0 as AnyObject })
                }
                if fault == "delayed_dispatch", CFEqual(element, edit), attribute == kAXSelectedAttribute as String,
                   fixture.events.recorded.contains("select_all"), !fixture.events.recorded.contains("cancel_edit"),
                   !selectionReads.recorded.contains("delayed_dispatch_settled") {
                    selectionReads.record("pending_menu_read")
                    if selectionReads.recorded.filter({ $0 == "pending_menu_read" }).count == 3 {
                        selectionReads.record("delayed_dispatch_settled")
                        fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips)
                        fixture.builder.setAttribute(edit, kAXSelectedAttribute as String, false)
                    }
                }
                if sharedRead, CFEqual(element, fixture.builder.element(966_040)), attribute == kAXValueAttribute as String {
                    snapshotReads.record(fixture.events.recorded.contains("select_all") ? "after" : "before")
                    if fixture.events.recorded.contains("restore_captured_focus") {
                        if fault == "full_population_shared_final_document" {
                            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                        }
                        if fault == "full_population_shared_final_filter" {
                            fixture.builder.setAttribute(filterControls[2], kAXValueAttribute as String, 0)
                        }
                    }
                }
                if CFEqual(element, mixer), attribute == kAXSelectedChildrenAttribute as String {
                    selectionReads.record(attribute)
                    if fault == "unread_selection" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
                    let opened = fixture.events.recorded.contains("open_edit")
                    let selected = fixture.events.recorded.contains("select_all")
                    if timedDispatch, selected, selectionClock.settled,
                       !selectionReads.recorded.contains("timed_dispatch_settled") {
                        selectionReads.record("timed_dispatch_settled")
                        switch dispatchFault {
                        case "timed_dispatch_noop": break
                        case "timed_dispatch_subset":
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, Array(strips.prefix(2)))
                        case "timed_dispatch_foreign":
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips + [fixture.header])
                        case "timed_dispatch_unread": return .failure(.init(raw: AXError.cannotComplete.rawValue))
                        default:
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips)
                            if dispatchFault == "timed_dispatch_document" {
                                fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            }
                            if dispatchFault == "timed_dispatch_focus" {
                                fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.header)
                            }
                            if dispatchFault == "timed_dispatch_transport" {
                                fixture.builder.setAttribute(controls[0], kAXValueAttribute as String, 1)
                            }
                            if dispatchFault == "timed_dispatch_cancel" { withUnsafeCurrentTask { $0?.cancel() } }
                        }
                    }
                    if fault == "before_leaf_transport_document", opened, !selected {
                        selectionReads.record("leaf_deciding")
                    }
                    if (fault == "before_menu_document" && selectionReads.count == 2)
                        || (fault == "before_leaf_document" && opened && !selected)
                        || (fault == "inverse_deciding_document" && selected && selectionReads.recorded.filter({ $0 == "after_select_all" }).count == 1) {
                        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    }
                    if selected { selectionReads.record("after_select_all") }
                    if fault.hasPrefix("late_deciding_"), selected,
                       selectionReads.recorded.filter({ $0 == "after_select_all" }).count == 5 {
                        // The accepted leaf has not changed the first three bounded
                        // samples or the post-menu read. Its exact population settles
                        // at the inverse's deciding read, as observed on the host.
                        selectionReads.record("late_deciding_transition")
                        switch fault {
                        case "late_deciding_foreign":
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips + [fixture.header])
                        case "late_deciding_subset":
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, Array(strips.prefix(2)))
                        case "late_deciding_unread": return .failure(.init(raw: AXError.cannotComplete.rawValue))
                        case "late_deciding_document":
                            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips)
                        case "late_deciding_cancel":
                            fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips)
                            withUnsafeCurrentTask { $0?.cancel() }
                        default: fixture.builder.setAttribute(mixer, kAXSelectedChildrenAttribute as String, strips)
                        }
                    }
                    if fault.hasPrefix("late_deciding_") || timedDispatch {
                        // Own this status-bearing result: the legacy value fallback
                        // invokes readingAttribute a second time when it returns nil.
                        return .success(fixture.builder.attributeValue(mixer, attribute).map { $0 as AnyObject })
                    }
                }
                if fault == "before_leaf_transport_document", CFEqual(element, controls[1]),
                   attribute == kAXValueAttribute as String, selectionReads.recorded.contains("leaf_deciding") {
                    // The final held transport read still returns stopped, but its
                    // deciding native read changes the project before Select All.
                    fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Foreign.logicx")
                    selectionReads.record("transport_document_changed")
                }
                if strips.contains(where: { CFEqual($0, element) }),
                   [kAXValueAttribute as String, kAXSelectedTextAttribute as String].contains(attribute) {
                    return .failure(.init(raw: AXError.noValue.rawValue))
                }
                return nativeRead(element, attribute)
            })
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        if originalMixerReturn {
            #expect(selectionReads.recorded.contains("owned_first_focus_metadata_unread"))
            #expect(fixture.events.recorded.filter { $0 == "select_all" }.count == 1)
            #expect(fixture.events.recorded.filter { $0 == "restore_mixer_selection" }.count == 1)
            let returned = try #require(fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String))
            #expect(CFEqual(returned as CFTypeRef, initialFocus))
            #expect(body["state"] as? String == "C" && body["snapshot_id"] == nil)
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored",
                "Retiring association authority must not erase our independently verified inverse: \(body)")
            return
        }
        if delayedInverse {
            if !inverseOnlyFirstFocus || healthyDelayedInverse {
                #expect(selectionReads.recorded.contains("inverse_dispatch_settled"))
            }
            #expect(fixture.events.recorded.filter({ $0 == "restore_mixer_selection" }).count == 1)
            if !healthyDelayedInverse {
                #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "not_restored")
                #expect(!fixture.events.recorded.contains("restore_captured_focus"))
            }
            if ["select_all_first_focus_inverse_dispatch_cancel", "select_all_first_focus_inverse_only_dispatch_cancel"].contains(fault) {
                #expect(body["state"] as? String == "C" && body["error"] as? String == "cancelled")
                return
            }
            if inverseOnlyFirstFocus { #expect(selectionReads.recorded.contains("inverse_only_first_focus")) }
        }
        if timedDispatch {
            #expect(selectionReads.recorded.contains("timed_dispatch_settled"),
                "Actually observe the delayed native result, not merely an ACK or early refusal")
            #expect(fixture.events.recorded.filter({ $0 == "select_all" }).count == 1)
            if (earlyFirstFocus || heldFirstFocus)
                && !["timed_dispatch_early_first_focus", "timed_dispatch_held_first_focus", "timed_dispatch_held_first_focus_after_reference"].contains(fault) {
                #expect(!fixture.events.recorded.contains("restore_mixer_selection"))
            } else if ["timed_dispatch_noop", "timed_dispatch_subset"].contains(fault) {
                #expect(fixture.events.recorded.filter({ $0 == "restore_mixer_selection" }).count == 1)
                let restored = try #require(fixture.builder.attributeValue(mixer,
                    kAXSelectedChildrenAttribute as String) as? [AXUIElement])
                #expect(restored.count == original.count && zip(restored, original).allSatisfy { CFEqual($0, $1) })
                #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
            } else if !["timed_dispatch_healthy", "timed_dispatch_early_first_focus", "timed_dispatch_held_first_focus", "timed_dispatch_held_first_focus_after_reference"].contains(fault) {
                #expect(!fixture.events.recorded.contains("restore_mixer_selection"))
            }
            if earlyFirstFocus { #expect(selectionReads.recorded.contains("early_first_focus")) }
            if heldFirstFocus { #expect(selectionReads.recorded.contains("held_first_focus")) }
        }
        if fault == "late_deciding_cancel" || dispatchFault == "timed_dispatch_cancel" {
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "cancelled")
            #expect(selectionReads.recorded.contains(fault == "late_deciding_cancel" ? "late_deciding_transition" : "timed_dispatch_settled"))
            #expect(fixture.events.recorded.filter({ $0 == "select_all" }).count == 1)
            #expect(!fixture.events.recorded.contains("restore_mixer_selection"))
            return
        }
        let section: [String: Any]
        if fullPopulation && (!["full_population_restore_focus", "full_population_shared"].contains(fault) || originalCount != 1) {
            #expect(body["state"] as? String == "C" && body["snapshot_id"] == nil)
            section = body["strips"] as? [String: Any] ?? [:]
        } else { section = try #require(body["strips"] as? [String: Any]) }
        let completeExpected = ["healthy", "restore_selected_focus", "delayed_dispatch", "late_deciding_settlement", "select_all_first_focus", "select_all_first_focus_inverse_dispatch", "select_all_first_focus_inverse_only_dispatch", "timed_dispatch_healthy", "timed_dispatch_early_first_focus", "timed_dispatch_held_first_focus", "timed_dispatch_held_first_focus_after_reference"].contains(fault)
            || (["full_population_restore_focus", "full_population_shared"].contains(fault) && originalCount == 1)
            || (originalCount == strips.count && ["noop_selection", "restore_ack_only", "restore_focus_false",
                "restore_focus_ack_only", "restore_focus_unselected", "restore_focus_selection_drift"].contains(fault))
        if completeExpected {
            #expect(section["coverage"] as? String == "complete")
            let focusInverse = fault == "restore_focus_unselected" || (selectionReturnsFocus && !CFEqual(original[0], initialFocus))
            #expect(fixture.events.recorded.filter { $0 != "association_select" } == ["open_edit", "select_all", "restore_mixer_selection"]
                + (focusInverse ? ["restore_captured_focus"] : []))
            #expect((body["ui_effects"] as? [String: Any])?["restoration"] as? String == "restored")
            if originalCount == strips.count {
                let changed = (body["ui_effects"] as? [String: Any])?["changed"] as? [String] ?? []
                #expect(!changed.contains("mixer_selection") && !changed.contains("mixer_selection_restoration"))
            }
        } else { #expect(section["coverage"] as? String != "complete") }
        if firstFocusTransition {
            #expect(fixture.events.recorded.filter { $0 == "select_all" }.count == 1)
            if completeExpected {
                let actual = try #require(fixture.builder.attributeValue(fixture.app, kAXFocusedUIElementAttribute as String))
                #expect(CFEqual(actual as AnyObject, initialFocus))
            } else if !delayedInverse { #expect(!fixture.events.recorded.contains("restore_mixer_selection")) }
        }
        if fault == "delayed_dispatch" {
            #expect(fixture.events.recorded.filter { $0 == "select_all" }.count == 1)
            #expect(selectionReads.recorded.contains("pending_menu_read"))
            #expect(selectionReads.recorded.contains("delayed_dispatch_settled"))
            #expect(!selectionReads.recorded.contains("delayed_dispatch_cancelled"))
        }
        if fault.hasPrefix("late_deciding_") {
            #expect(selectionReads.recorded.contains("late_deciding_transition"))
            #expect(fixture.events.recorded.filter({ $0 == "select_all" }).count == 1)
            if fault == "late_deciding_settlement" {
                #expect(fixture.events.recorded.filter({ $0 == "restore_mixer_selection" }).count == 1)
            } else { #expect(!fixture.events.recorded.contains("restore_mixer_selection")) }
        }
        if fault == "before_menu_document" { #expect(!fixture.events.recorded.contains("open_edit")) }
        if fault == "before_leaf_document" { #expect(!fixture.events.recorded.contains("select_all")) }
        if fault == "before_leaf_transport_document" {
            #expect(selectionReads.recorded.contains("leaf_deciding"))
            #expect(selectionReads.recorded.contains("transport_document_changed"))
            #expect(!fixture.events.recorded.contains("select_all"))
        }
        if fault == "inverse_deciding_document" { #expect(!fixture.events.recorded.contains("restore_mixer_selection")) }
        if fullPopulation && originalCount == 1 {
            #expect(fixture.events.recorded.filter { $0 == "association_select" }.count == 2)
            #expect(fixture.events.recorded.contains("restore_mixer_selection"))
            if ["full_population_restore_focus", "full_population_shared"].contains(fault) {
                #expect(fixture.events.recorded.contains("restore_captured_focus"))
                let rows = (body["associations"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
                #expect(rows.count == 2)
            } else if !sharedRead { #expect(!fixture.events.recorded.contains("restore_captured_focus")) }
        }
        if ["restore_focus_foreign", "restore_focus_document"].contains(fault)
            || (fault == "restore_focus_unselected" && originalCount != strips.count) {
            #expect(!fixture.events.recorded.contains("restore_captured_focus"))
        }
        if ["restore_focus_false", "restore_focus_ack_only", "restore_focus_selection_drift"].contains(fault)
            && originalCount != strips.count {
            #expect(fixture.events.recorded.contains("restore_captured_focus"))
            let effects = body["ui_effects"] as? [String: Any]
            #expect((effects?["attempted"] as? [String] ?? []).contains("mixer_focus_restoration"))
            let changed = effects?["changed"] as? [String] ?? []
            if fault == "restore_focus_selection_drift" { #expect(changed.contains("mixer_focus_restoration")) }
            else { #expect(!changed.contains("mixer_focus_restoration")) }
            #expect(effects?["restoration"] as? String == "not_restored")
        }
        if completeExpected {
            let restored = try #require(fixture.builder.attributeValue(mixer, kAXSelectedChildrenAttribute as String) as? [AXUIElement])
            #expect(restored.count == original.count && zip(restored, original).allSatisfy { CFEqual($0, $1) })
        }
        if fault == "full_population_shared", originalCount == 1 {
            // The existing name reader samples the same real Name control twice
            // per snapshot. One initial and one final snapshot retain both reads.
            #expect(snapshotReads.recorded.filter { $0 == "before" }.count == 2)
            #expect(snapshotReads.recorded.filter { $0 == "after" }.count == 2)
            #expect(fixture.events.recorded.filter { $0 == "select_all" }.count == 1)
            #expect(fixture.events.recorded.filter { $0 == "restore_mixer_selection" }.count == 1)
        }
        let headerSelected = try #require(fixture.builder.attributeValue(fixture.header, kAXSelectedAttribute as String) as? Bool)
        #expect(headerSelected)
    }

    @Test("a noneditable physical Mixer strip's zero insertion sentinel does not block a no-navigation track read")
    func registeredTrackOnlyReadAdmitsHeldPassiveMixerFocus() async throws {
        let (fixture, focus) = passiveMixerFocusFixture()
        let result = try await inspect(fixture: fixture, domains: ["tracks"],
            keyboardFocus: { .textEditing(role: kAXLayoutItemRole as String, byInsertionPoint: true) },
            readingAttribute: passiveMixerAttributeRead(focus))
        let error = result.isError ?? false
        #expect(!error)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let rows = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows.compactMap { $0["name"] as? String } == [" Fresh track "])
        #expect(fixture.reads.helpCount == 0)
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test("a passive Mixer read exception cannot admit an editor, unread capability or wrong physical owner",
          arguments: ["editor_role", "other_role", "characters", "insertion_line", "settable_value",
                      "foreign_focus", "detached", "duplicate", "unbound_document", "text_value",
                      "selected_text", "unread_value", "boolean_line", "string_line", "boolean_characters",
                      "not_frontmost", "foreign_window", "wrong_parent"])
    func registeredPassiveMixerReadRejectsChangedCapability(fault: String) async throws {
        let (fixture, focus) = passiveMixerFocusFixture(fault: fault)
        let result = try await inspect(fixture: fixture, domains: ["tracks"],
            keyboardFocus: { .textEditing(role: kAXLayoutItemRole as String, byInsertionPoint: true) },
            readingAttribute: passiveMixerAttributeRead(focus, fault: fault))
        let error = result.isError ?? false
        #expect(error)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["state"] as? String == "C")
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test("the passive Mixer exception never authorizes Mixer Help or navigation", arguments: [false, true])
    func registeredPassiveMixerReadStillRefusesRequestedStrips(navigation: Bool) async throws {
        let (fixture, focus) = passiveMixerFocusFixture()
        let result = try await inspect(fixture: fixture, domains: navigation ? ["tracks"] : ["tracks", "strips"],
            navigation: navigation,
            keyboardFocus: { .textEditing(role: kAXLayoutItemRole as String, byInsertionPoint: true) },
            readingAttribute: passiveMixerAttributeRead(focus))
        let error = result.isError ?? false
        #expect(error)
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test("a passive Mixer read loses permission when its acquired focus or project changes",
          arguments: ["focus", "document", "editable"])
    func registeredPassiveMixerReadRejectsLostCustody(fault: String) async throws {
        let (fixture, focus) = passiveMixerFocusFixture()
        let checks = Reads()
        let nativeRead = passiveMixerAttributeRead(focus)
        let result = try await inspect(fixture: fixture, domains: ["tracks"],
            keyboardFocus: { .textEditing(role: kAXLayoutItemRole as String, byInsertionPoint: true) },
            readingAttribute: { element, attribute in
                if CFEqual(element, focus), attribute == kAXSelectedTextAttribute as String {
                    checks.record(attribute)
                    if checks.count == 2 {
                        if fault == "focus" {
                            fixture.builder.setAttribute(fixture.app, kAXFocusedUIElementAttribute as String, fixture.header)
                        } else if fault == "document" {
                            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/other.logicx/")
                        } else {
                            fixture.builder.setAttributeSettable(focus, kAXValueAttribute as String, true)
                        }
                    }
                }
                return nativeRead(element, attribute)
            })
        let error = result.isError ?? false
        #expect(error)
        #expect(checks.count >= 2)
        #expect(fixture.reads.helpCount == 0)
        #expect(fixture.events.recorded.isEmpty)
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: [-1.0, 2.0, 0.9, Double.nan, Double.infinity, -Double.infinity])
    func registeredInspectionKeepsUnreadableSelectionUnknown(value: Double) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, NSNumber(value: value))
            let result = try await inspect(fixture: fixture, domains: ["tracks"])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows.first?["is_selected"] is NSNull,
                    "a failed strict selection read is not an observed unselected row")
            #expect(fixture.reads.helpCount == 0)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func registeredInspectionKeepsObservedSelection(selected: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, selected)
            let result = try await inspect(fixture: fixture, domains: ["tracks"])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            let observed = try #require(rows.first?["is_selected"] as? Bool)
            if selected { #expect(observed) } else { #expect(!observed) }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func registeredSelectionScopeUsesOnlyObservedSelection(selected: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, selected)
            let result = try await inspect(fixture: fixture, domains: ["tracks"], scope: "selection")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.count == (selected ? 1 : 0))
            let reasons = try #require(tracks["reasons"] as? [String])
            #expect(!reasons.contains("selection_state_unverified"))
            #expect(tracks["coverage"] as? String == "partial", "observed selection does not prove the global rail end")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func completeSelectedChildrenWitnessDoesNotRequireWholeProjectEnd(selected: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, selected)
            fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String,
                                         selected ? [fixture.header] : [AXUIElement]())
            let result = try await inspect(fixture: fixture, domains: ["tracks"], scope: "selection")
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.count == (selected ? 1 : 0))
            #expect(tracks["coverage"] as? String == "complete")
            #expect(try #require(tracks["reasons"] as? [String]).isEmpty)
            let witnesses = try #require(tracks["witnesses"] as? [String: Any])
            #expect(witnesses["selection_membership_source"] as? String == "ax_selected_children")
            let overall = try #require(body["overall"] as? [String: Any])
            let complete = try #require(overall["complete"] as? Bool)
            #expect(complete)
            #expect(fixture.reads.helpCount == 0)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: ["missing", "duplicate", "foreign", "flag_disagrees", "wrong_type", "unreadable", "malformed_flag"])
    func selectedChildrenMustBeFullyObservedAndAgreeWithRows(defect: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, true)
            fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [fixture.header])
            switch defect {
            case "missing": fixture.builder.removeAttribute(fixture.rail, kAXSelectedChildrenAttribute as String)
            case "duplicate": fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [fixture.header, fixture.header])
            case "foreign": fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [fixture.builder.element(965_998)])
            case "flag_disagrees": fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [AXUIElement]())
            case "wrong_type": fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, "selected")
            case "malformed_flag": fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, NSNumber(value: 2))
            default: break
            }
            let result = try await inspect(fixture: fixture, domains: ["tracks"], scope: "selection",
                readingAttribute: { element, attribute in
                    guard defect == "unreadable", CFEqual(element, fixture.rail),
                          attribute == kAXSelectedChildrenAttribute as String else { return nil }
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                })
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            #expect(tracks["coverage"] as? String != "complete")
            let witnesses = try #require(tracks["witnesses"] as? [String: Any])
            #expect(witnesses["selection_membership_source"] == nil)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func selectedChildrenWitnessCannotReplaceEarlierRowSelection() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, false)
            fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [fixture.header])
            let result = try await inspect(fixture: fixture, domains: ["tracks"], scope: "selection",
                readingAttribute: { element, attribute in
                    guard CFEqual(element, fixture.header), attribute == kAXSelectedAttribute as String else { return nil }
                    let readings = fixture.reads.recorded
                    let selectedRead = readings.lastIndex(of: kAXSelectedChildrenAttribute as String) ?? -1
                    let rowRead = readings.lastIndex(of: kAXTitleAttribute as String) ?? -1
                    return .success(NSNumber(value: selectedRead > rowRead))
                })
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            #expect(tracks["coverage"] as? String != "complete")
            let witnesses = try #require(tracks["witnesses"] as? [String: Any])
            #expect(witnesses["selection_membership_source"] == nil)
        }
    }

    @Test func selectedChildrenWitnessNeverCertifiesWholeProject() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, true)
            fixture.builder.setAttribute(fixture.rail, kAXSelectedChildrenAttribute as String, [fixture.header])
            let result = try await inspect(fixture: fixture, domains: ["tracks"])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            #expect(tracks["coverage"] as? String == "partial")
            let witnesses = try #require(tracks["witnesses"] as? [String: Any])
            #expect(witnesses["selection_membership_source"] == nil)
        }
    }

    @Test func soloPresentationNormalizationIsReusableByLaterFootprintReads() throws {
        let captured = [
            TrackState(id: 0, name: "Peer", type: .audio,
                isMuted: false, isSoloed: false, isArmed: false),
            TrackState(id: 1, name: "Solo", type: .audio,
                isMuted: false, isSoloed: true, isArmed: false),
            TrackState(id: 2, name: "Muted", type: .audio,
                isMuted: true, isSoloed: false, isArmed: false),
        ]
        var later = captured
        later[0].isMuted = nil
        later[0].isSoloed = nil
        later[1].isMuted = nil
        later[2].isSoloed = nil

        let normalizedCapture = try #require(AccessibilityChannel.soloPresentationSafeTrackStates(captured))
        let normalizedLater = try #require(AccessibilityChannel.soloPresentationSafeTrackStates(later))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(normalizedCapture) == encoder.encode(normalizedLater),
            "the same active Solo makes only non-true Mute/Solo animation frames unread")
        let retainedSolo = try #require(normalizedCapture[1].isSoloed as Bool?)
        #expect(retainedSolo)
        let retainedMute = try #require(normalizedCapture[2].isMuted as Bool?)
        #expect(retainedMute,
            "explicit on readings remain protected")

        var movedSolo = later
        movedSolo[1].isSoloed = nil
        movedSolo[0].isSoloed = true
        let normalizedMoved = try #require(AccessibilityChannel.soloPresentationSafeTrackStates(movedSolo))
        #expect(try encoder.encode(normalizedCapture) != encoder.encode(normalizedMoved),
            "a changed active Solo owner is still a changed footprint")

        var noSolo = captured
        noSolo[1].isSoloed = false
        let exactNoSolo = try #require(AccessibilityChannel.soloPresentationSafeTrackStates(noSolo))
        let exactMute = try #require(exactNoSolo[0].isMuted as Bool?)
        let exactSolo = try #require(exactNoSolo[0].isSoloed as Bool?)
        #expect(!exactMute && !exactSolo,
            "without an active Solo the ordinary exact toggle readings remain intact")
    }

    @Test(arguments: ["solo_blink", "no_solo_blink", "solo_true_to_false"])
    func soloMuteAnimationDoesNotMoveFreshPopulation(_ mode: String) async throws {
        let fixture = Fixture()
        let mute = fixture.builder.element(965_980)
        let solo = fixture.builder.element(965_981)
        let arm = fixture.builder.element(965_982)
        for control in [mute, solo, arm] {
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setChildren(control, [])
        }
        fixture.builder.setAttribute(mute, kAXDescriptionAttribute as String,
            AXLocalePolicy.trackMuteButton.canonical)
        fixture.builder.setAttribute(solo, kAXDescriptionAttribute as String,
            AXLocalePolicy.trackSoloButton.canonical)
        fixture.builder.setAttribute(arm, kAXDescriptionAttribute as String,
            AXLocalePolicy.trackRecordEnableCheckbox.canonical)
        fixture.builder.setAttribute(solo, kAXValueAttribute as String,
            mode == "no_solo_blink" ? 0 : 1)
        fixture.builder.setAttribute(arm, kAXValueAttribute as String, 0)
        fixture.builder.setChildren(fixture.header, [mute, solo, arm])

        let muteReads = Reads()
        let channel = fixture.channel(readingAttribute: { element, attribute in
            guard CFEqual(element, mute), attribute == kAXValueAttribute as String else { return nil }
            muteReads.record(attribute)
            if mode == "solo_true_to_false" {
                return .success(NSNumber(value: muteReads.count.isMultiple(of: 2) ? 0 : 1))
            }
            // Logic reports an unmuted track silenced by Solo as alternating
            // -1 and 0 frames. Neither frame is an explicit Mute change.
            return .success(NSNumber(value: muteReads.count.isMultiple(of: 2) ? 0 : -1))
        })
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await channel.readFreshSessionPopulation(
                request: .init(domains: [.tracks]), fileReader: .unavailable, stoppingWhen: { false }
            )
        }

        if mode == "solo_blink" {
            #expect(population.stable)
            #expect(muteReads.count == 2, "the first exact physical bookend should stabilize")
            let track = try #require(population.tracks?.first)
            #expect(track.isMuted == nil, "a Solo-contaminated non-true Mute is not published as off")
            let soloed = try #require(track.isSoloed as Bool?)
            #expect(soloed)
        } else {
            #expect(!population.stable,
                "without corroborated Solo, or when true Mute changes, the strict bookend must still refuse")
            #expect(muteReads.count == 6, "all three strict retries must observe the disagreement")
        }
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test(arguments: ["blink", "true_to_false"])
    func inactiveSoloAnimationDoesNotHideARealSoloChange(_ mode: String) async throws {
        let fixture = Fixture()
        func toggle(_ id: Int, _ description: String, _ value: Int) -> AXUIElement {
            let control = fixture.builder.element(id)
            fixture.builder.setRole(control, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(control, kAXDescriptionAttribute as String, description)
            fixture.builder.setAttribute(control, kAXValueAttribute as String, value)
            fixture.builder.setChildren(control, [])
            return control
        }
        let activeMute = toggle(965_983, AXLocalePolicy.trackMuteButton.canonical, 0)
        let activeSolo = toggle(965_984, AXLocalePolicy.trackSoloButton.canonical, 1)
        let activeArm = toggle(965_985, AXLocalePolicy.trackRecordEnableCheckbox.canonical, 0)
        fixture.builder.setChildren(fixture.header, [activeMute, activeSolo, activeArm])

        let peer = fixture.builder.element(965_986)
        fixture.builder.setRole(peer, kAXLayoutItemRole as String)
        fixture.builder.setAttribute(peer, kAXTitleAttribute as String, "Peer")
        fixture.builder.setAttribute(peer, kAXSelectedAttribute as String, false)
        let peerMute = toggle(965_987, AXLocalePolicy.trackMuteButton.canonical, 0)
        let peerSolo = toggle(965_988, AXLocalePolicy.trackSoloButton.canonical, 0)
        let peerArm = toggle(965_989, AXLocalePolicy.trackRecordEnableCheckbox.canonical, 0)
        fixture.builder.setChildren(peer, [peerMute, peerSolo, peerArm])
        fixture.builder.setChildren(fixture.rail, [fixture.header, peer])

        let soloReads = Reads()
        let channel = fixture.channel(readingAttribute: { element, attribute in
            guard CFEqual(element, peerSolo), attribute == kAXValueAttribute as String else { return nil }
            soloReads.record(attribute)
            let odd = !soloReads.count.isMultiple(of: 2)
            return .success(NSNumber(value: mode == "true_to_false" && odd ? 1 : odd ? -1 : 0))
        })
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await channel.readFreshSessionPopulation(
                request: .init(domains: [.tracks]), fileReader: .unavailable, stoppingWhen: { false }
            )
        }

        if mode == "blink" {
            #expect(population.stable)
            #expect(soloReads.count == 2)
            let tracks = try #require(population.tracks)
            #expect(tracks.count == 2)
            let first = try #require(tracks.first)
            let soloed = try #require(first.isSoloed as Bool?)
            #expect(soloed)
            #expect(tracks[1].isSoloed == nil,
                "an inactive Solo animation frame is unread, never a published false")
        } else {
            #expect(!population.stable, "an explicit Solo-on reading disappearing must remain unstable")
            #expect(soloReads.count == 6)
        }
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    @Test func disappearingSelectionReadIsNotAStablePopulation() async throws {
        let fixture = Fixture()
        let selectionReads = Reads()
        let channel = fixture.channel(observingAttribute: { element, attribute in
            guard CFEqual(element, fixture.header), attribute == kAXSelectedAttribute as String else { return }
            selectionReads.record(attribute)
            if selectionReads.count.isMultiple(of: 2) {
                fixture.builder.removeAttribute(fixture.header, kAXSelectedAttribute as String)
            } else {
                fixture.builder.setAttribute(fixture.header, kAXSelectedAttribute as String, false)
            }
        })
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
                "legacy false wire equality cannot hide loss of the actual selection read")
        #expect(selectionReads.count == 6, "all three before/after attempts must consume the disagreement")
        #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
    }

    private func inspect(
        fixture: Fixture, unreadableRail: Bool = false, cancelBeforeRead: Bool = false,
        hasVisibleWindow: Bool = true,
        domains: [String] = ["tracks", "strips"],
        scope: String = "whole_project",
        navigation: Bool = false,
        targetReferences: Bool = false,
        stopBeforeRead: Bool? = nil,
        keyboardFocus: @escaping @Sendable () -> AccessibilityChannel.LogicKeyboardFocus = { .notTextEditing },
        fileReader: LogicProjectFileReader.Runtime = .unavailable,
        frameReads: Reads? = nil, frameFault: String? = nil,
        observationAction: (@Sendable (AXUIElement, String) -> Bool?)? = nil,
        focusSetter: (@Sendable (AXUIElement, String, CFTypeRef) -> Bool)? = nil,
        readingAttribute: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?)? = nil,
        observeHost: @escaping @Sendable (pid_t) -> ProcessUtils.LogicHostObservation? = { _ in nil }
    ) async throws -> CallTool.Result {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Session"))
        await cache.updateTracks([TrackState(id: 0, name: "Old cached track", type: .audio)])
        await cache.updateChannelStrips([ChannelStripState(trackIndex: 0, name: "Old cached strip")])
        let gate = LogicMutationGate()
        let poller = StatePoller(axChannel: fixture.channel(unreadableRail: unreadableRail,
                                                         observationAction: observationAction, focusSetter: focusSetter,
                                                         frameReads: frameReads, frameFault: frameFault,
                                                         readingAttribute: readingAttribute, observeHost: observeHost), cache: cache,
                                 runtime: .init(hasVisibleWindow: { hasVisibleWindow }, projectFileReader: fileReader,
                                                keyboardFocus: keyboardFocus))
        if let awaitStop = stopBeforeRead {
            if awaitStop { await poller.stop() }
            else { await poller.stopImmediately() }
        }
        let dependencies = HandlerDependencies(
            router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
            poller: poller,
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: fileReader
        )
        let handler = try #require(OperationHandlerRegistry.handler(
            tool: "logic_project", command: "inspect_session"
        ))
        let params: [String: Value] = ["domains": .array(domains.map(Value.string)), "scope": .string(scope),
                                       "allow_ui_navigation": .bool(navigation)]
        return await LogicProServer.runWithDeadline(
            tool: "logic_project", command: "inspect_session", commandParams: params,
            mutationGate: gate
        ) {
            if cancelBeforeRead { withUnsafeCurrentTask { $0?.cancel() } }
            if targetReferences {
                return await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
            }
            return await handler(dependencies, params)
        }
    }

    @Test(arguments: ["unrequested_mixer", "requested_mixer", "tracks", "project", "occlusion", "epoch"])
    func registeredTrackOnlyAcquisitionScopesCacheMovement(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let bundle = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpm965-domain-boundary-\(UUID().uuidString).logicx")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: bundle) }
            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, bundle.absoluteString)
            let cache = StateCache()
            let project = ProjectInfo(name: "Session", filePath: bundle.path)
            await cache.updateProject(project)
            await cache.updateTracks([TrackState(id: 0, name: "Old cached track", type: .audio)])
            await cache.updateChannelStrips([ChannelStripState(trackIndex: 0, name: "Unrequested strip", volume: 0.25)])
            let beforeMixer = await cache.currentVersion(for: .mixer)
            let metadataReads = Reads()
            let metadata = try PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": 1],
                format: .xml, options: 0)
            let fileReader = LogicProjectFileReader.Runtime(currentDocumentPath: { nil }, now: Date.init,
                readPlistData: { _ in metadata }, mtime: { _ in
                    metadataReads.record("mtime")
                    return Date(timeIntervalSince1970: metadataReads.count == 1 ? 0 : 1)
                }, sleep: { _ in
                    // Actual production metadata retry is an awaited point inside acquisition.
                    // This models an MCU cache echo, not a separate AX reader or a timed race.
                    switch fault {
                    case "unrequested_mixer", "requested_mixer": await cache.updateFader(strip: 0, volume: 0.75)
                    case "tracks": await cache.updateTracks([TrackState(id: 0, name: "Concurrent edit", type: .audio)])
                    case "project": await cache.updateProject(project)
                    case "occlusion": await cache.updateAXOccluded(true); await cache.updateAXOccluded(false)
                    case "epoch": await cache.updateDocumentState(false); await cache.updateDocumentState(true)
                    default: Issue.record("unknown boundary fixture")
                    }
                })
            let gate = LogicMutationGate()
            let dependencies = HandlerDependencies(router: ChannelRouter(), cache: cache,
                targetRegistry: TargetRegistry(),
                poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: fileReader)),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [:] }, projectFileReader: fileReader)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let domains = fault == "requested_mixer" ? ["tracks", "strips"] : ["tracks"]
            let params: [String: Value] = ["domains": .array(domains.map(Value.string))]
            let result = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
                commandParams: params, mutationGate: gate) { await handler(dependencies, params) }
            let isError = result.isError ?? false
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(metadataReads.count >= 4, "the actual metadata retry must have executed the cache change")
            if fault == "unrequested_mixer" {
                #expect(!isError, "an unrequested MCU Mixer echo must not discard a stable Track reading")
                let tracks = try #require(body["tracks"] as? [String: Any])
                let rows = try #require(tracks["rows"] as? [[String: Any]])
                #expect(rows.compactMap { $0["name"] as? String } == [" Fresh track "])
                #expect(tracks["coverage"] as? String == "partial", "local acceptance does not invent a global end")
                #expect(await cache.getChannelStrips().first?.volume == 0.75, "do not overwrite unrequested Mixer data")
                #expect(await cache.currentVersion(for: .mixer) != beforeMixer)
                let id = try #require(body["snapshot_id"] as? String)
                let retained = try #require(await cache.retainedInspection(id: id))
                #expect(retained.capture.after.versions[.mixer] == (await cache.currentVersion(for: .mixer)),
                        "the accepted capture must retain the full current Mixer boundary")
                #expect(await cache.inspectionIsCurrent(retained.capture))
                let historical = await cache.retainedSessionReport(id: id)
                await cache.updateFader(strip: 0, volume: 0.8)
                #expect(!(await cache.inspectionIsCurrent(retained.capture)),
                        "later Mixer movement still invalidates a current repair baseline")
                #expect(await cache.retainedSessionReport(id: id) == historical,
                        "a retained historical capture remains immutable, not refreshed")
            } else {
                #expect(isError)
                #expect(body["error"] as? String == "readback_unavailable")
                #expect(body["snapshot_id"] == nil, "requested or project-wide movement must not publish authority")
            }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
            #expect(fixture.events.recorded.isEmpty)
        }
    }

    @Test func trackOnlyAcceptanceCannotOverwriteUnrequestedStripValues() async throws {
        let cache = StateCache()
        let project = ProjectInfo(name: "Session")
        await cache.updateProject(project)
        await cache.updateChannelStrips([ChannelStripState(trackIndex: 0, volume: 0.25)])
        let before = await cache.captureBoundary(watching: [.tracks, .project])
        await cache.updateFader(strip: 0, volume: 0.75)
        let now = Date()
        let accepted = await cache.acceptFreshPopulation(
            .init(project: project, tracks: [], strips: [ChannelStripState(trackIndex: 0, volume: 0.25)],
                  fileTrackCount: nil, beganAt: now, endedAt: now, stable: true),
            ifCurrent: before, request: .init(domains: [.tracks]), stoppingWhen: { false })
        #expect(accepted == nil, "a narrowed request must not smuggle a strip overwrite past the full boundary")
        #expect(await cache.getChannelStrips().first?.volume == 0.75)
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

    @Test(arguments: ["title", "document", "both", "title_absent", "document_absent",
                      "document_unreadable", "document_malformed", "unchanged"])
    func finalTrackValueReadCannotCertifyEarlierDocumentIdentity(_ change: String) async throws {
        let fixture = Fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpm965-document-bookend-" + UUID().uuidString, isDirectory: true)
        let original = directory.appendingPathComponent("Original.logicx", isDirectory: true)
        let replacement = directory.appendingPathComponent("Replacement.logicx", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, original.absoluteString)
        let rowReads = Reads()
        let channel = fixture.channel(observingAttribute: { element, attribute in
            guard CFEqual(element, fixture.header), attribute == kAXSelectedAttribute as String else { return }
            rowReads.record(attribute)
            // The after-pass already copied the title/document. Reuse the same window,
            // header and wire values while an external edit changes its identity during
            // the actually consumed last-row value read; no expected-result echo.
            guard rowReads.count == 2 else { return }
            if change == "title" || change == "both" {
                fixture.builder.setAttribute(fixture.window, kAXTitleAttribute as String, "Replacement - Tracks")
            }
            if change == "document" || change == "both" {
                fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, replacement.absoluteString)
            }
            if change == "title_absent" { fixture.builder.removeAttribute(fixture.window, kAXTitleAttribute as String) }
            if change == "document_absent" { fixture.builder.removeAttribute(fixture.window, kAXDocumentAttribute as String) }
            if change == "document_malformed" {
                fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, 42)
            }
        }, readingAttribute: { element, attribute in
            guard change == "document_unreadable", rowReads.count >= 2,
                  CFEqual(element, fixture.window), attribute == kAXDocumentAttribute as String else { return nil }
            return .failure(.init(raw: AXError.cannotComplete.rawValue))
        })
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await channel.readFreshSessionPopulation(
                request: .init(domains: [.tracks]), fileReader: .unavailable, stoppingWhen: { false }
            )
        }
        #expect(rowReads.count >= 2, "the fault must reach the real after-row extraction")
        if change == "title_absent" {
            #expect(!population.stable)
            #expect(population.project == nil)
        } else if change == "document_unreadable" || change == "document_malformed" {
            #expect(!population.stable, "a failed or malformed document read is not observed document absence")
        } else {
            #expect(population.stable, "an independently stable retry remains allowed")
            #expect(population.project?.name == (change == "title" || change == "both" ? "Replacement" : "Session"))
            let expectedPath = change == "document_absent" ? nil
                : change == "document" || change == "both" ? replacement.path : original.path
            #expect(population.project?.filePath == expectedPath)
        }
        if change != "unchanged" { #expect(rowReads.count >= 4, "the changed identity must invalidate the original pair") }
        else { #expect(rowReads.count == 2, "a genuinely unchanged pair needs no extra stabilization attempt") }
        #expect(fixture.events.count == 0 && fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
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

    @Test(arguments: ["cancelled", "deadline", "ownershipLost", "pollerStopped", "textEditing", "other"], [false, true])
    func acquisitionFailureHintDoesNotInventATimeout(causeName: String, wrapped: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = StateCache()
            await cache.updateProject(ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx"))
            let result = await ProjectDispatcher.handle(
                command: "inspect_session", params: [:], router: ChannelRouter(), cache: cache,
                dialogPresent: { false }, cleanupAuditFileReader: .unavailable,
                acquireSessionPopulation: { _ in
                    let cause: Error
                    switch causeName {
                    case "cancelled": cause = SessionPopulationObservation.AcquisitionError.cancelled
                    case "deadline": cause = SessionPopulationObservation.AcquisitionError.deadline
                    case "ownershipLost": cause = SessionPopulationObservation.AcquisitionError.ownershipLost
                    case "pollerStopped": cause = SessionPopulationObservation.AcquisitionError.pollerStopped
                    case "textEditing": cause = SessionPopulationObservation.AcquisitionError.textEditing
                    default: cause = NSError(domain: "AcquisitionTest", code: 1)
                    }
                    if wrapped {
                        var effects = SessionPopulationObservation.UIEffects()
                        effects.navigationPerformed = true
                        effects.attempted = ["stack_disclosure"]
                        effects.restoration = "not_restored"
                        effects.reason = "stack_expansion_unverified"
                        throw SessionPopulationObservation.NavigationAcquisitionError(cause: cause, effects: effects)
                    }
                    throw cause
                }
            )
            let isError: Bool = try #require(result.isError as Bool?)
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let hint = try #require(body["hint"] as? String)
            if causeName == "ownershipLost" {
                #expect(hint.contains("operation ownership or cache/project custody"))
            }
            if causeName == "pollerStopped" { #expect(hint.contains("population producer is stopped")) }
            if causeName == "textEditing" { #expect(hint.contains("keyboard-focus/observation guard")) }
            let expectedError = causeName == "cancelled" ? "cancelled"
                : causeName == "deadline" ? "operation_timeout" : "readback_unavailable"
            #expect(body["error"] as? String == expectedError)
            #expect(body["state"] as? String == "C" && body["snapshot_id"] == nil)
            let writeAttempted = try #require(body["write_attempted"] as? Bool)
            #expect(!writeAttempted)
            #expect(hint.contains("no replacement report was published"))
            if causeName == "deadline" { #expect(hint.contains("deadline")) }
            else {
                #expect(!hint.contains("deadline"), "a non-deadline refusal must not be diagnosed as a timeout")
                if causeName == "cancelled" { #expect(hint.contains("cancelled")) }
            }
            let effects = try #require(body["ui_effects"] as? [String: Any])
            let navigationPerformed = try #require(effects["navigation_performed"] as? Bool)
            if wrapped { #expect(navigationPerformed) }
            else { #expect(!navigationPerformed) }
            #expect(effects["attempted"] as? [String] == (wrapped ? ["stack_disclosure"] : []))
            #expect(effects["changed"] as? [String] == [])
            #expect(effects["restoration"] as? String == (wrapped ? "not_restored" : "not_applicable"))
        }
    }

    @Test(arguments: [false, true])
    func operationOnlyCustodyLossDoesNotAssertThatTheProjectChanged(revokedGate: Bool) async throws {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx"))
        let before = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
        let context = revokedGate ? OperationTraceContext(mutationGateAcquired: true, ownsGate: { false }) : nil
        let result = await OperationTraceContext.$current.withValue(context) {
            await ProjectDispatcher.handle(command: "inspect_session", params: [:], router: ChannelRouter(), cache: cache,
                dialogPresent: { false }, cleanupAuditFileReader: .unavailable, acquireSessionPopulation: { _ in
                    try SessionPopulationObservation.requireOwnedAcquisition()
                    throw SessionPopulationObservation.AcquisitionError.pollerStopped
                })
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let hint = try #require(body["hint"] as? String)
        #expect(hint.contains("operation ownership"))
        #expect(body["error"] as? String == "readback_unavailable")
        #expect(body["state"] as? String == "C")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(body["snapshot_id"] == nil)
        #expect(await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections) == before)
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

    @Test(arguments: ["before", "during"])
    func externalDocumentSwitchCannotReuseAnEarlierTrackReference(_ changeTiming: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = Fixture()
            let ownedDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpm965-fresh-targets-" + UUID().uuidString, isDirectory: true)
            let oldBundle = ownedDirectory.appendingPathComponent("Old.logicx", isDirectory: true)
            let newBundle = ownedDirectory.appendingPathComponent("New.logicx", isDirectory: true)
            try FileManager.default.createDirectory(at: oldBundle, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: ownedDirectory) }
            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String,
                                         changeTiming == "before" ? newBundle.absoluteString : oldBundle.absoluteString)
            let rowReads = Reads()
            let channel = fixture.channel(observingAttribute: { element, attribute in
                guard CFEqual(element, fixture.header), attribute == kAXSelectedAttribute as String else { return }
                rowReads.record(attribute)
                if changeTiming == "during", rowReads.count == 2 {
                    fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, newBundle.absoluteString)
                }
            })
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
                poller: StatePoller(axChannel: channel, cache: cache,
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
            #expect(rowReads.count >= (changeTiming == "during" ? 4 : 2))
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }
}
