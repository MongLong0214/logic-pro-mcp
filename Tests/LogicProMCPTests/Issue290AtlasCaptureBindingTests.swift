@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// The running-target observer is a new API: original-head compile absence is NOT behavioral RED.
/// Freeze this file after the approved seam-only checkpoint, which still emits `observed`.
/// Every AX read/action is supplied by FakeAXRuntimeBuilder; no production Control Bar route runs.
@Suite("Issue290AtlasCaptureBinding")
struct Issue290AtlasCaptureBindingTests {
    private final class Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let otherApp: AXUIElement
        let window: AXUIElement
        let otherWindow: AXUIElement
        let menu: AXUIElement
        let pid: pid_t = 4242

        init(titles: [String] = ["파일", "편집", "트랙"]) {
            app = builder.element(700)
            otherApp = builder.element(701)
            window = builder.element(702)
            otherWindow = builder.element(703)
            menu = builder.element(704)
            builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
            builder.setAttribute(otherWindow, kAXRoleAttribute as String, kAXWindowRole as String)
            builder.setAttribute(app, kAXWindowsAttribute as String, [window] as NSArray)
            builder.setAttribute(app, kAXMenuBarAttribute as String, menu)
            builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuBarRole as String)
            let items = titles.enumerated().map { index, title in
                let item = builder.element(710 + index)
                builder.setAttribute(item, kAXTitleAttribute as String, title)
                builder.setAttribute(item, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
                return item
            }
            builder.setChildren(menu, items)
            builder.setChildren(window, [])
        }

        var target: AtlasCapture.RunningTarget {
            .init(pid: pid, bundleID: "com.apple.logic10", logicVersion: "12.3")
        }

        func runtime(failedAttribute: String? = nil) -> AXHelpers.Runtime {
            let base = builder.makeAXRuntime(appElement: app,
                attributeValueResultHandler: { _, attribute in
                    guard attribute == failedAttribute else { return nil }
                    return .failure(.init(raw: AXError.failure.rawValue))
                }, setAttributeHandler: nil, performActionHandler: nil)
            // The builder's ordinary axApp ignores PID. Override that seam so another observed
            // process cannot pass membership using this fixture's application by accident.
            return AXHelpers.Runtime(axApp: { [self] value in value == pid ? app : otherApp },
                attributeValue: base.attributeValue,
                attributeIsSettable: base.attributeIsSettable,
                setAttributeValue: base.setAttributeValue,
                children: base.children, performAction: base.performAction,
                childCount: base.childCount, actionNames: base.actionNames,
                actionNamesResult: base.actionNamesResult, childrenResult: base.childrenResult,
                attributeValueResult: base.attributeValueResult,
                performActionResult: base.performActionResult)
        }

        func baselines() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpm290-capture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let baseline = AXSnapshot.Document(logicVersion: "99.99", locale: "en-US",
                scope: "window", capturedFrom: "ax", root: AXSnapshot.capture(window, runtime: runtime()))
            try JSONEncoder().encode(baseline).write(to: directory.appendingPathComponent("window.json"))
            return directory
        }

        func capture(_ directory: URL, target: AtlasCapture.RunningTarget? = nil,
                     failedAttribute: String? = nil) -> (pairs: [AtlasQualification.Pair], dropped: [String]) {
            let supplied = target ?? self.target
            return AtlasCapture.pairs(baselinesIn: directory, window: window,
                runtime: runtime(failedAttribute: failedAttribute), runningTarget: { supplied })
        }

        func assertReadOnly() {
            #expect(builder.setCalls.isEmpty)
            #expect(builder.actionCalls.isEmpty)
        }
    }

    @Test func currentMetadataComesFromRunningTargetAndSamePIDMenuNotBaseline() throws {
        let f = Fixture()
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = f.capture(directory)
        let pair = try #require(captured.pairs.first)
        #expect(captured.pairs.count == 1)
        #expect(captured.dropped.isEmpty)
        #expect(pair.current.logicVersion == "12.3")
        #expect(pair.current.locale == "ko-KR")
        #expect(pair.current.logicVersion != pair.baseline.logicVersion)
        #expect(pair.current.locale != pair.baseline.locale)
        f.assertReadOnly()
    }

    @Test func observedEnglishMenuCannotBeRelabelledAsKoreanBaseline() throws {
        let f = Fixture(titles: ["File", "Edit", "Track"])
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = f.capture(directory)
        let pair = try #require(result.pairs.first)
        #expect(pair.current.locale == "en-US")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/AX")
        let documents = try ["track-headers", "control-bar"].map {
            try JSONDecoder().decode(AXSnapshot.Document.self,
                from: Data(contentsOf: fixtures.appendingPathComponent(
                    "logic-12.x-desktop-ko-\($0).json")))
        }
        let axis = QualificationAxis(variant: .desktop, locale: .koKR,
            profile: .core, cache: .cold, fixture: .empty)
        let selected = documents.map { AtlasQualification.Pair(
            scope: $0.scope, baseline: $0, current: $0) }
        let positive = AtlasQualification.ComparisonEvidence(
            schema: "qualification-atlas-comparison/v1", binarySHA256: String(repeating: "a", count: 64),
            axis: axis, pairs: selected, dropped: [])
        if case let .diffed(verdict, _, unmeasured, dropped) = positive.outcome {
            #expect(verdict == .reuseFull)
            #expect(unmeasured.isEmpty)
            #expect(dropped.isEmpty)
        } else {
            Issue.record("The archived two-scope Korean positive must actually compare")
        }
        // Synthetic metadata witness using the same observed English menu result, not a
        // claim that this empty fake window captured the archived selected-scope roots.
        let wrongLocale = documents.map { baseline in AtlasQualification.Pair(
            scope: baseline.scope, baseline: baseline,
            current: AXSnapshot.Document(logicVersion: pair.current.logicVersion,
                locale: pair.current.locale, scope: baseline.scope,
                capturedFrom: pair.current.capturedFrom, root: baseline.root)) }
        let comparison = AtlasQualification.ComparisonEvidence(
            schema: "qualification-atlas-comparison/v1", binarySHA256: String(repeating: "a", count: 64),
            axis: axis, pairs: wrongLocale, dropped: [])
        guard case let .noBaselines(reason) = comparison.outcome else {
            Issue.record("Observed English must fail the existing Korean metadata binding")
            return
        }
        #expect(reason == "atlas capture locale/version is unknown or mismatches its axis")
        f.assertReadOnly()
    }

    @Test(arguments: ["", "observed", "unknown", "unspecified", "  unknown  "])
    func missingOrUnknownRunningVersionCannotBecomeCaptureMetadata(version: String) throws {
        let f = Fixture()
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = f.capture(directory, target: .init(pid: f.pid,
            bundleID: "com.apple.logic10", logicVersion: version))
        #expect(result.pairs.isEmpty)
        #expect(result.dropped == ["window.json"])
        f.assertReadOnly()
    }

    @Test func missingRunningTargetCannotUseBaselineOrInstalledMetadata() throws {
        let f = Fixture()
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = AtlasCapture.pairs(baselinesIn: directory, window: f.window,
            runtime: f.runtime(), runningTarget: { nil })
        #expect(result.pairs.isEmpty)
        #expect(result.dropped == ["window.json"])
        f.assertReadOnly()
    }

    @Test(arguments: [5757, 0])
    func suppliedWindowCannotBindDifferentOrInvalidObservedPID(pid: Int) throws {
        let f = Fixture()
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = f.capture(directory, target: .init(pid: pid_t(pid),
            bundleID: "com.apple.logic10", logicVersion: "12.3"))
        #expect(result.pairs.isEmpty)
        #expect(result.dropped == ["window.json"])
        f.assertReadOnly()
    }

    @Test func foreignBundleCannotBecomeLogicCapture() throws {
        let f = Fixture()
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = f.capture(directory, target: .init(pid: f.pid,
            bundleID: "com.example.not-logic", logicVersion: "12.3"))
        #expect(result.pairs.isEmpty)
        #expect(result.dropped == ["window.json"])
        f.assertReadOnly()
    }

    @Test(arguments: ["AXWindows", "AXMenuBar", "AXTitle"])
    func failedOwnershipOrLocaleReadCannotEstablishMetadata(attribute: String) throws {
        let f = Fixture()
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = f.capture(directory, failedAttribute: attribute)
        #expect(result.pairs.isEmpty)
        #expect(result.dropped == ["window.json"])
        f.assertReadOnly()
    }

    @Test(arguments: [false, true])
    func detachedOrMalformedWindowListCannotEstablishOwnership(malformed: Bool) throws {
        let f = Fixture()
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        if malformed {
            f.builder.setAttribute(f.app, kAXWindowsAttribute as String, "not an array")
        } else {
            f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [f.otherWindow] as NSArray)
        }
        let result = f.capture(directory)
        #expect(result.pairs.isEmpty)
        #expect(result.dropped == ["window.json"])
        f.assertReadOnly()
    }

    @Test(arguments: [false, true])
    func absentOrAmbiguousMenuLocaleCannotUseBaselineLocale(ambiguous: Bool) throws {
        let f = Fixture(titles: ambiguous ? ["파일", "편집", "트랙", "File", "Edit", "Track"] : [])
        let directory = try f.baselines()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = f.capture(directory)
        #expect(result.pairs.isEmpty)
        #expect(result.dropped == ["window.json"])
        f.assertReadOnly()
    }
}
