@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #904: a second consumer of the same New Project AXWindow.title must carry
/// the row already cited by projectChooserWindowTitle. Fixed inputs come from
/// Logic 12.3 (6674), Logic.framework Localizable.strings/Choose a Project.
/// The KO title is archived in 2026-09-15-the-korean-project-chooser-names-itself;
/// the other localized inputs are derived synthetic windows, not native proof.
/// These tests call only read-only helpers, never project creation or scripts.
@Suite("#904 project picker title and document binding")
struct Issue904ProjectPickerBindingTests {
    private static let chooserRows: [(String, String)] = [
        ("en", "Choose a Project"),
        ("ko", "프로젝트 선택"),
        ("ja", "プロジェクトを選択"),
        ("de", "Wähle ein Projekt aus"),
        ("es", "Seleccionar un proyecto"),
        ("fr", "Choisir un projet"),
        ("it", "Scegli un progetto"),
        ("pt", "Escolha um projeto"),
        ("zh_CN", "选取项目"),
        ("zh_TW", "選擇計畫案"),
    ]

    private func fixture(title: String) -> (builder: FakeAXRuntimeBuilder, app: AXUIElement, window: AXUIElement) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(904_600)
        let window = builder.element(904_601)
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, title)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setChildren(app, [window])
        builder.setChildren(window, [])
        return (builder, app, window)
    }

    @Test("the actual picker classifier recognizes every own-row title", arguments: chooserRows)
    func pickerClassifierRecognizesOwnRow(locale: String, title: String) {
        let f = fixture(title: title)
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)
        #expect(AXLogicProElements.isProjectPickerWindow(f.window, runtime: runtime), "locale=\(locale)")
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("a successfully observed absent AXDocument excludes the chooser only", arguments: chooserRows)
    func readableAbsentDocumentExcludesOwnRowChooser(locale: String, title: String) {
        let f = fixture(title: title)
        let runtime = f.builder.makeLogicRuntime(appElement: f.app,
            attributeValueHandler: { element, attribute in
                if CFEqual(element, f.window), attribute == (kAXDocumentAttribute as String) { return .some(nil) }
                return nil
            }, attributeValueResultHandler: { element, attribute in
                if CFEqual(element, f.window), attribute == (kAXDocumentAttribute as String) { return .success(nil) }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil)
        #expect(AccessibilityChannel.isPositivelyTheProjectChooser(f.window, runtime: runtime), "locale=\(locale)")
        let count = AccessibilityChannel.documentWindowCount([f.window], runtime: runtime)
        #expect(count == 0)
        #expect(AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: count))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("a document with the exact chooser title remains an open document", arguments: chooserRows)
    func sameTitledDocumentCannotBeExcluded(locale: String, title: String) {
        let f = fixture(title: title)
        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///fixture/Existing.logicx/")
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)
        #expect(!AccessibilityChannel.isPositivelyTheProjectChooser(f.window, runtime: runtime), "locale=\(locale)")
        let count = AccessibilityChannel.documentWindowCount([f.window], runtime: runtime)
        #expect(count == 1)
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: count))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("legacy chooser title tolerance is retained", arguments: ["Choose Project", "New from Template"])
    func legacyPickerTitleToleranceRemains(title: String) {
        let f = fixture(title: title)
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)
        #expect(AXLogicProElements.isProjectPickerWindow(f.window, runtime: runtime))
        #expect(AccessibilityChannel.isPositivelyTheProjectChooser(f.window, runtime: runtime))
        #expect(AccessibilityChannel.documentWindowCount([f.window], runtime: runtime) == 0)
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("unrelated window titles and the other Project Select row are not choosers",
          arguments: ["My Song - Tracks", "Untitled 6 - Tracks", "Project Select", "プロジェクト選択"])
    func unrelatedWindowCannotBeExcluded(title: String) {
        let f = fixture(title: title)
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)
        #expect(!AXLogicProElements.isProjectPickerWindow(f.window, runtime: runtime))
        #expect(!AccessibilityChannel.isPositivelyTheProjectChooser(f.window, runtime: runtime))
        let count = AccessibilityChannel.documentWindowCount([f.window], runtime: runtime)
        #expect(count == 1)
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: count))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("failed AXDocument reads are unknown, never positive absence",
          arguments: [AXError.failure.rawValue, AXError.cannotComplete.rawValue,
                      AXError.apiDisabled.rawValue, AXError.invalidUIElement.rawValue])
    func failedDocumentObservationCannotExcludeWindow(rawStatus: Int32) {
        let f = fixture(title: "Choose a Project")
        let runtime = f.builder.makeLogicRuntime(appElement: f.app,
            // Original best-effort reader sees nil for this SAME failed read.
            // The status-preserving path sees its actual error, not absence.
            attributeValueHandler: { element, attribute in
                if CFEqual(element, f.window), attribute == (kAXDocumentAttribute as String) { return .some(nil) }
                return nil
            }, attributeValueResultHandler: { element, attribute in
                if CFEqual(element, f.window), attribute == (kAXDocumentAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: rawStatus))
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil)
        #expect(!AccessibilityChannel.isPositivelyTheProjectChooser(f.window, runtime: runtime))
        let count = AccessibilityChannel.documentWindowCount([f.window], runtime: runtime)
        #expect(count == 1)
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: count))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("present malformed AXDocument payloads cannot masquerade as missing",
          arguments: ["number", "boolean", "array", "dictionary", "null", "element"])
    func malformedDocumentObservationCannotExcludeWindow(shape: String) {
        let f = fixture(title: "Choose a Project")
        let payload: AnyObject
        switch shape {
        case "number": payload = NSNumber(value: 7)
        case "boolean": payload = NSNumber(value: false)
        case "array": payload = NSArray(array: ["file:///fixture/Existing.logicx/"])
        case "dictionary": payload = NSDictionary(dictionary: ["document": "file:///fixture/Existing.logicx/"])
        case "null": payload = NSNull()
        default: payload = f.window
        }
        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, payload)
        // Both raw-result and classic paths expose the same present payload.
        // A typed String cast returning nil is not proof of successful absence.
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)
        #expect(!AccessibilityChannel.isPositivelyTheProjectChooser(f.window, runtime: runtime))
        let count = AccessibilityChannel.documentWindowCount([f.window], runtime: runtime)
        #expect(count == 1)
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: count))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }
}

extension Issue904ProjectPickerBindingTests {
    @Test("documented AX absence statuses preserve legitimate chooser availability",
          arguments: [AXError.noValue.rawValue, AXError.attributeUnsupported.rawValue])
    func definitiveDocumentAbsenceStillExcludesChooser(rawStatus: Int32) {
        let f = fixture(title: "Choose a Project")
        let runtime = f.builder.makeLogicRuntime(appElement: f.app,
            // Both seams describe the same absence answer. No native chooser
            // status is claimed: these are the existing shared AX status rules.
            attributeValueHandler: { element, attribute in
                if CFEqual(element, f.window), attribute == (kAXDocumentAttribute as String) { return .some(nil) }
                return nil
            }, attributeValueResultHandler: { element, attribute in
                if CFEqual(element, f.window), attribute == (kAXDocumentAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: rawStatus))
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil)
        #expect(AccessibilityChannel.isPositivelyTheProjectChooser(f.window, runtime: runtime))
        let count = AccessibilityChannel.documentWindowCount([f.window], runtime: runtime)
        #expect(count == 0)
        #expect(AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: count))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("a real document named exactly like the chooser keeps its bound track rail", arguments: chooserRows)
    func sameTitledRealDocumentRemainsReadableInAllTrackHelpers(locale: String, title: String) {
        let f = fixture(title: title)
        f.builder.setAttribute(f.window, kAXDocumentAttribute as String, "file:///fixture/Existing.logicx/")
        let rail = f.builder.element(904_602)
        let row = f.builder.element(904_603)
        f.builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        f.builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        f.builder.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        f.builder.setAttribute(row, kAXDescriptionAttribute as String, "Track 1 “Fixture”")
        f.builder.setChildren(rail, [row])
        f.builder.setChildren(row, [])
        f.builder.setChildren(f.window, [rail])
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)

        // Exercise all three production helpers before inspecting any verdict;
        // one failure must not prevent sibling reader witnesses from running.
        let observedRail = AXLogicProElements.getTrackHeaders(runtime: runtime)
        let sharedRead = AXLogicProElements.allTrackHeadersRead(in: f.window, runtime: runtime)
        let verifiedRead = AXLogicProElements.allTrackHeadersVerifiedRead(in: f.window, runtime: runtime)

        if let observedRail {
            #expect(CFEqual(observedRail, rail), "locale=\(locale)")
        } else {
            Issue.record("getTrackHeaders hid a real document's rail; locale=\(locale)")
        }
        if case .read(let rows) = sharedRead {
            #expect(rows.count == 1)
            #expect(rows.contains { CFEqual($0, row) })
        } else {
            Issue.record("allTrackHeadersRead hid a real document's row; locale=\(locale)")
        }
        if case .read(let rows) = verifiedRead {
            #expect(rows.count == 1)
            #expect(rows.contains { CFEqual($0, row) })
        } else {
            Issue.record("allTrackHeadersVerifiedRead hid a real document's row; locale=\(locale)")
        }
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }
}

extension Issue904ProjectPickerBindingTests {
    @Test("a best-effort-only runtime cannot certify document absence")
    func classicNilDocumentReadIsNotPositiveAbsence() {
        let f = fixture(title: "Choose a Project")
        let injected = f.builder.makeAXRuntime(appElement: f.app)
        let classic = AXHelpers.Runtime(
            axApp: injected.axApp,
            attributeValue: injected.attributeValue,
            setAttributeValue: injected.setAttributeValue,
            children: injected.children,
            performAction: injected.performAction,
            childCount: injected.childCount
        )
        let runtime = AXLogicProElements.Runtime(
            logicProPID: { 4242 }, ax: classic,
            executeAppleScript: { _ in .error("unexpected script in a getter-only fixture") }
        )
        #expect(!AccessibilityChannel.isPositivelyTheProjectChooser(f.window, runtime: runtime))
        let count = AccessibilityChannel.documentWindowCount([f.window], runtime: runtime)
        #expect(count == 1)
        #expect(!AccessibilityChannel.blankApplicationCanRevealChooser(windowCount: count))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("chooser template rows stay hidden when document absence is known or the read is unknown",
          arguments: ["Choose a Project", "Choisir un projet"], ["absent", "failed", "malformed"])
    func pickerTemplateRailCannotBecomeTracks(title: String, documentShape: String) {
        let f = fixture(title: title)
        let rail = f.builder.element(904_604)
        let row = f.builder.element(904_605)
        f.builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        f.builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        f.builder.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        f.builder.setChildren(rail, [row])
        f.builder.setChildren(f.window, [rail])
        let runtime = f.builder.makeLogicRuntime(appElement: f.app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, f.window), attribute == (kAXDocumentAttribute as String) else { return nil }
                switch documentShape {
                case "failed": return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                case "malformed": return .success(NSNumber(value: 7))
                default: return .success(nil)
                }
            }, setAttributeHandler: nil, performActionHandler: nil)
        let observedRail = AXLogicProElements.getTrackHeaders(runtime: runtime)
        #expect(observedRail == nil)
        if case .read = AXLogicProElements.allTrackHeadersRead(in: f.window, runtime: runtime) {
            Issue.record("chooser or unknown-document template rows were exposed as tracks")
        }
        if case .read = AXLogicProElements.allTrackHeadersVerifiedRead(in: f.window, runtime: runtime) {
            Issue.record("chooser or unknown-document template rows became a verified rail")
        }
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }
}
