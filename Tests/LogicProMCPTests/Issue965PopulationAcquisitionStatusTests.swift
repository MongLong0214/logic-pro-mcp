@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#965 population producers preserve acquisition failures")
struct Issue965PopulationAcquisitionStatusTests {
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private final class DiscoveryReads: @unchecked Sendable {
        private let lock = NSLock()
        private var batches = 0
        private var roles = 0
        func batch() { lock.withLock { batches += 1 } }
        func scalar(_ attribute: String) {
            if attribute == kAXRoleAttribute as String { lock.withLock { roles += 1 } }
        }
        var counts: (batches: Int, roles: Int) { lock.withLock { (batches, roles) } }
    }

    enum Failure: CaseIterable, Sendable {
        case children, rowRole, missingRail
    }

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let first: AXUIElement

        init() {
            let b = FakeAXRuntimeBuilder()
            builder = b
            app = b.element(965_800)
            window = b.element(965_801)
            rail = b.element(965_802)
            first = b.element(965_803)
            b.setRole(window, kAXWindowRole as String)
            b.setRole(rail, kAXListRole as String)
            b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            b.setAttribute(app, kAXMainWindowAttribute as String, window)
            let second = b.element(965_804)
            for (index, header) in [first, second].enumerated() {
                b.setRole(header, kAXLayoutItemRole as String)
                b.setAttribute(header, kAXTitleAttribute as String, " Bass \(index) ")
                b.setChildren(header, [])
            }
            b.setChildren(rail, [first, second])
            b.setChildren(window, [rail])
        }

        func runtime(failure: Failure? = nil) -> AXLogicProElements.Runtime {
            let missing = failure == .missingRail
            if missing { builder.setChildren(window, []) }
            return builder.makeLogicRuntime(
                appElement: app,
                attributeValueHandler: { element, attribute in
                    if failure == .rowRole, CFEqual(element, first), attribute == kAXRoleAttribute as String {
                        return .some(nil)
                    }
                    return nil
                },
                attributeValueResultHandler: { element, attribute in
                    if failure == .rowRole, CFEqual(element, first), attribute == kAXRoleAttribute as String {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return nil
                },
                childrenHandler: { element in
                    failure == .children && CFEqual(element, rail) ? [] : nil
                },
                childrenResultHandler: { element in
                    if failure == .children, CFEqual(element, rail) {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return nil
                },
                setAttributeHandler: nil,
                performActionHandler: nil,
                executeAppleScript: { _ in .error("fixture forbids AppleScript") }
            )
        }
    }

    @Test("Verified rail discovery uses fresh batches without losing native failures or text-field pruning",
          arguments: ["owned", "role_failure", "children_failure", "malformed_children", "pruned_text_field"])
    func verifiedDiscoveryBatchesPreserveScope(_ fault: String) throws {
        let f = Fixture(), base = f.runtime(), reads = DiscoveryReads()
        let text = f.builder.element(965_806)
        if fault == "pruned_text_field" {
            f.builder.setRole(text, kAXTextFieldRole as String)
            f.builder.setChildren(f.window, [f.rail, text])
        }
        let ax = AXHelpers.Runtime(axApp: base.ax.axApp,
            attributeValue: { element, attribute in
                reads.scalar(attribute); return base.ax.attributeValue(element, attribute)
            }, attributeIsSettable: base.ax.attributeIsSettable,
            setAttributeValue: base.ax.setAttributeValue, children: base.ax.children,
            performAction: base.ax.performAction, childCount: base.ax.childCount,
            actionNames: base.ax.actionNames, actionNamesResult: base.ax.actionNamesResult,
            childrenResult: base.ax.childrenResult,
            attributeValueResult: { element, attribute in
                reads.scalar(attribute)
                return AXHelpers.getAttributeResult(element, attribute, runtime: base.ax)
            }, performActionResult: base.ax.performActionResult,
            attributeValuesResult: { element, attributes in
                reads.batch()
                return .success(attributes.map { attribute -> AnyObject in
                    let fails = fault == "role_failure" && CFEqual(element, f.first) && attribute == kAXRoleAttribute as String
                        || fault == "children_failure" && CFEqual(element, f.rail) && attribute == kAXChildrenAttribute as String
                        || fault == "pruned_text_field" && CFEqual(element, text) && attribute == kAXChildrenAttribute as String
                    if fails {
                        var error = AXError.cannotComplete
                        return AXValueCreate(.axError, &error)!
                    }
                    if fault == "malformed_children", CFEqual(element, f.window), attribute == kAXChildrenAttribute as String {
                        return NSNumber(value: 42)
                    }
                    if attribute == kAXChildrenAttribute as String {
                        return (try? AXHelpers.childrenResult(element, runtime: base.ax).get()).map { $0 as CFArray } ?? NSNull()
                    }
                    return base.ax.attributeValue(element, attribute) ?? NSNull()
                })
            })
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: ax,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") })
        let result = AXLogicProElements.allTrackHeadersVerifiedRead(in: f.window, runtime: runtime)
        if fault == "owned" || fault == "pruned_text_field" {
            guard case .read(let headers) = result else { Issue.record("The complete native rail must remain readable"); return }
            #expect(headers.count == 2 && CFEqual(headers[0], f.first))
            #expect(reads.counts.roles == 2, "Only final row classification needs separate role reads after the fresh discovery batches")
        } else {
            guard case .unreadable = result else { Issue.record("A failed or malformed visited node cannot publish an observed rail"); return }
        }
        #expect(reads.counts.batches > 0)
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    @Test(arguments: Failure.allCases)
    func unsuccessfulRailAcquisitionIsNotAnObservedPopulation(_ failure: Failure) async throws {
        let f = Fixture()
        let healthy = AccessibilityChannel.defaultGetTrackStates(runtime: f.runtime(), stoppingWhen: { false })
        let rows = try #require(healthy.states)
        #expect(rows.count == 2)
        #expect(Array(rows[0].name.utf8) == Array(" Bass 0 ".utf8))

        let runtime = f.runtime(failure: failure)
        let read = AccessibilityChannel.defaultGetTrackStates(runtime: runtime, stoppingWhen: { false })
        #expect(read.states == nil, "failed traversal is not empty or a shifted subset")
        #expect(!read.yielded, "AX failure is not a keyboard-focus yield")
        let wire = AccessibilityChannel.defaultGetTracks(runtime: runtime)
        #expect(!wire.isSuccess, "the encoded fallback must not republish the failed read as []")
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: runtime
        ))
        let foreground = await channel.readTrackStates()
        #expect(foreground == nil, "foreground polling must retain the same failed-read outcome")
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test
    func readableEmptyRailRemainsAnObservedEmptyPopulation() async throws {
        let f = Fixture()
        f.builder.setChildren(f.rail, [])
        let runtime = f.runtime()
        let read = AccessibilityChannel.defaultGetTrackStates(runtime: runtime, stoppingWhen: { false })
        #expect(try #require(read.states).isEmpty)
        #expect(!read.yielded)
        let wire = AccessibilityChannel.defaultGetTracks(runtime: runtime)
        #expect(wire.isSuccess)
        #expect(wire.message == "[]")
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: runtime
        ))
        let foreground = await channel.readTrackStates()
        #expect(try #require(foreground).isEmpty)
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    @Test
    func unrelatedLoadingSubtreeDoesNotDiscardAReadableRail() throws {
        let f = Fixture()
        let unrelated = f.builder.element(965_805)
        f.builder.setRole(unrelated, kAXGroupRole as String)
        f.builder.setChildren(f.window, [unrelated, f.rail])
        let runtime = f.builder.makeLogicRuntime(
            appElement: f.app,
            childrenHandler: { element in CFEqual(element, unrelated) ? [] : nil },
            childrenResultHandler: { element in
                CFEqual(element, unrelated)
                    ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
            },
            setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )
        let read = AccessibilityChannel.defaultGetTrackStates(runtime: runtime, stoppingWhen: { false })
        let rows = try #require(read.states)
        #expect(rows.map(\.id) == [0, 1])
        #expect(rows.map(\.name) == [" Bass 0 ", " Bass 1 "])
        #expect(!read.yielded)
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    @Test("poller finds a shallow exact rail before descending an earlier unrelated tree")
    func pollerFindsShallowExactRailBeforeEarlierDeepTree() async throws {
        let f = Fixture()
        // Logic 13 exposes the live rail as a localized AXGroup, not the legacy AXList fixture.
        f.builder.setRole(f.rail, kAXGroupRole as String)
        f.builder.setAttribute(f.rail, kAXDescriptionAttribute as String, "트랙 헤더")
        let deep = (0..<5).map { f.builder.element(965_810 + $0) }
        for node in deep { f.builder.setRole(node, kAXGroupRole as String) }
        for (parent, child) in zip(deep, deep.dropFirst()) {
            f.builder.setChildren(parent, [child])
        }
        f.builder.setChildren(deep.last!, [])
        f.builder.setChildren(f.window, [deep[0], f.rail])
        let deepReads = ReadCounter()
        let runtime = f.builder.makeLogicRuntime(
            appElement: f.app,
            childrenResultHandler: { element in
                if CFEqual(element, deep.last!) { deepReads.increment() }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )

        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
            logicRuntime: runtime
        ))
        let read = await channel.readTrackStates(stoppingWhen: { false })
        #expect(read.states?.map(\.name) == [" Bass 0 ", " Bass 1 "])
        #expect(!read.yielded)
        #expect(deepReads.count == 0,
                "a shallow exact Track Headers rail must win before the earlier unrelated tree is descended")
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    @Test(arguments: Failure.allCases)
    func failedTrackPollPreservesRowsRevisionAndObservationTime(_ failure: Failure) async throws {
        let f = Fixture()
        f.builder.setAttribute(f.window, kAXTitleAttribute as String, "Population - Tracks")
        let cache = StateCache()
        let healthy = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: f.runtime()
        ))
        let warm = StatePoller(axChannel: healthy, cache: cache, runtime: .init(hasVisibleWindow: { true }))
        #expect(await warm.refreshNow())
        let beforeRows = await cache.getTracks()
        #expect(beforeRows.map(\.name) == [" Bass 0 ", " Bass 1 "])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let beforeJSON = try encoder.encode(beforeRows)
        let beforeVersion = await cache.currentVersion(for: .tracks)
        let beforeTime = await cache.getTracksFetchedAt()

        let failed = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
            logicRuntime: f.runtime(failure: failure)
        ))
        let poller = StatePoller(axChannel: failed, cache: cache, runtime: .init(hasVisibleWindow: { true }))
        // More than the ordinary empty-read debounce: unknown must never turn
        // into an observed empty project, even after repeated fallback reads.
        for _ in 0..<3 { _ = await poller.refreshNow() }
        let afterRows = await cache.getTracks()
        #expect(try encoder.encode(afterRows) == beforeJSON)
        #expect(afterRows.map(\.liveIdentityBacked) == beforeRows.map(\.liveIdentityBacked))
        #expect(await cache.currentVersion(for: .tracks) == beforeVersion)
        #expect(await cache.getTracksFetchedAt() == beforeTime)
        #expect(await cache.getConsecutiveEmptyPolls() == 0)
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }

    @Test(arguments: Issue982UnreadChildrenTests.Layout.allCases)
    func unreadStripRoleCannotShiftPublicStripOrdinals(_ layout: Issue982UnreadChildrenTests.Layout) {
        let f = Issue982UnreadChildrenTests.fixture(layout)
        let runtime = f.builder.makeLogicRuntime(
            appElement: f.app,
            attributeValueHandler: { element, attribute in
                if CFEqual(element, f.strips[0]), attribute == kAXRoleAttribute as String { return .some(nil) }
                return nil
            },
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, f.strips[0]), attribute == kAXRoleAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            },
            setAttributeHandler: nil, performActionHandler: nil,
            executeAppleScript: { _ in .error("fixture forbids AppleScript") }
        )
        #expect(!AccessibilityChannel.defaultGetMixerState(runtime: runtime).isSuccess,
                "an unread physical strip must not be silently omitted from a fresh population")
        #expect(!AccessibilityChannel.defaultGetChannelStrip(params: ["index": "0"], runtime: runtime).isSuccess,
                "physical strip 1 must not become public strip index 0")
        #expect(f.builder.setCalls.isEmpty && f.builder.actionCalls.isEmpty)
    }
}
