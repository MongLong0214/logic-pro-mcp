import ApplicationServices
import Foundation

/// A marker operation that has to look at Logic's Marker List opens that window when it is not
/// already open. Opening it moves the key view into the list, and nothing used to close it again:
/// the window stayed on screen and every later operation inherited the moved focus. An operation
/// must close what it opened and put the focus back.
///
/// Ownership is exact: the opener retains the very window it saw appear and the project it was
/// bound to, and only that window is closed, after its project binding is read again. A list the
/// user already had open, or another project's list, is never touched. Absence is proved only by
/// a window census that was read; a census or focus read that fails leaves the outcome unverified
/// rather than reporting it closed or restored.
extension AccessibilityChannel {
    struct MarkerListOrigin: @unchecked Sendable {
        let app: AXUIElement
        let windows: [AXUIElement]
        let listWasOpen: Bool
        let main: AXUIElement?
        let focusedWindow: AXUIElement?
        let focusedElement: AXUIElement?
        /// The AXDocument of the main window, read BEFORE the open; nil when it could not be read.
        /// A list is adopted only when it is bound to this same project.
        let projectDocument: String?
    }

    /// The Marker List window an operation opened, and the project document it was bound to when
    /// it appeared. Cleanup acts on this element only: rediscovering "the current project's list"
    /// later would find another project's list once the user had switched to it.
    struct OpenedMarkerList: @unchecked Sendable {
        let origin: MarkerListOrigin
        let window: AXUIElement
        let projectDocument: String
    }

    struct MarkerListRestoration: Equatable, Sendable {
        /// True when this operation opened the list and it is gone again.
        let closed: Bool
        /// True when focus (window and element) reads as it did before the operation.
        let focusRestored: Bool
        /// Why a restoration step did not hold; nil when everything did.
        let reason: String?
    }

    /// The screen as it was before `nav.open_marker_list` opened the list on behalf of a caller that
    /// will release it (`nav.release_marker_list`). One slot: marker operations hold the mutation
    /// gate, so two cannot interleave.
    private final class OpenedListLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: OpenedMarkerList?
        func record(_ value: OpenedMarkerList) { lock.withLock { opened = value } }
        func take() -> OpenedMarkerList? { lock.withLock { let value = opened; opened = nil; return value } }
    }
    private static let openedListLedger = OpenedListLedger()

    /// Records the list `binding` names as opened by this operation, and answers whether it did.
    /// Nothing is recorded for a window that was already in the census taken before the open, for
    /// a list bound to a project other than the one in front before the open (the user can switch
    /// projects and open that project's list while the opener awaits the menu action), or when
    /// that origin project could not be read: none of those is shown to be this operation's.
    @discardableResult
    static func recordOpenedMarkerList(
        _ origin: MarkerListOrigin,
        opened binding: AXLogicProElements.MarkerListBinding
    ) -> Bool {
        guard !origin.listWasOpen,
              let originProject = origin.projectDocument,
              originProject == binding.projectDocument,
              !origin.windows.contains(where: { CFEqual($0, binding.window) }) else { return false }
        openedListLedger.record(OpenedMarkerList(
            origin: origin, window: binding.window, projectDocument: binding.projectDocument))
        return true
    }

    /// Closes the list `nav.open_marker_list` opened and restores focus. Answers State A with
    /// `marker_list_closed` / `ui_restored`; with nothing recorded it states that nothing was owned.
    static func releaseMarkerList(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        guard let opened = openedListLedger.take() else {
            return .success(HonestContract.encodeStateA(extras: [
                "operation": "nav.release_marker_list", "owned": false,
            ]))
        }
        let restoration = await restoreMarkerListOrigin(opened, runtime: runtime)
        var extras: [String: Any] = [
            "operation": "nav.release_marker_list", "owned": true,
            "marker_list_closed": restoration.closed,
            "ui_restored": restoration.closed && restoration.focusRestored,
        ]
        if let reason = restoration.reason { extras["ui_restore_reason"] = reason }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    static func markerListOrigin(
        runtime: AXLogicProElements.Runtime,
        listWasOpen knownListWasOpen: Bool? = nil
    ) -> MarkerListOrigin? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              case .success(let windows) = windowCensus(app, runtime: runtime) else { return nil }
        return MarkerListOrigin(
            app: app, windows: windows,
            listWasOpen: knownListWasOpen ?? (AXLogicProElements.findMarkerListWindow(runtime: runtime) != nil),
            main: AXHelpers.getAttribute(app, kAXMainWindowAttribute as String, runtime: runtime.ax),
            focusedWindow: AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
            focusedElement: AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
            projectDocument: mainWindowDocument(app, runtime: runtime))
    }

    /// The AXDocument of the app's main window, or nil when either read fails or answers nothing.
    static func mainWindowDocument(_ app: AXUIElement, runtime: AXLogicProElements.Runtime) -> String? {
        let main: Result<AXUIElement?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            app, kAXMainWindowAttribute as String, runtime: runtime.ax)
        guard case .success(.some(let window)) = main else { return nil }
        let document: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            window, kAXDocumentAttribute as String, runtime: runtime.ax)
        guard case .success(.some(let value)) = document, !value.isEmpty else { return nil }
        return value
    }

    /// The application's window list, or the AX status that kept it from being read. A window is
    /// absent only when a census that WAS read lacks it; a failed read says nothing either way.
    static func windowCensus(
        _ app: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        let read: Result<[AXUIElement]?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            app, kAXWindowsAttribute as String, runtime: runtime.ax)
        switch read {
        case .success(.some(let windows)): return .success(windows)
        case .success(.none): return .failure(.malformedAttribute)
        case .failure(let status): return .failure(status)
        }
    }

    /// Puts the focus back on the window and element it was on, and answers whether a fresh read
    /// agrees. A write that AX accepted is not evidence: only the re-read counts. Only elements
    /// that were READ on both sides compare: a failed read is not a reading, so two failed reads
    /// are not equal focus, and a focus that could not be read before cannot be shown restored.
    static func restoreFocus(_ origin: MarkerListOrigin, runtime: AXLogicProElements.Runtime) -> Bool {
        guard let focusedWindow = origin.focusedWindow,
              let focusedElement = origin.focusedElement else { return false }
        func current(_ attribute: String) -> AXUIElement? {
            let read: Result<AXUIElement?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                origin.app, attribute, runtime: runtime.ax)
            guard case .success(.some(let element)) = read else { return nil }
            return element
        }
        func focusMatches() -> Bool {
            guard let window = current(kAXFocusedWindowAttribute as String),
                  let element = current(kAXFocusedUIElementAttribute as String) else { return false }
            return CFEqual(window, focusedWindow) && CFEqual(element, focusedElement)
        }
        if !focusMatches() {
            if let main = origin.main {
                _ = AXHelpers.setAttribute(main, kAXMainAttribute as String, kCFBooleanTrue, runtime: runtime.ax)
            }
            _ = AXHelpers.setAttribute(focusedWindow, kAXFocusedAttribute as String, kCFBooleanTrue, runtime: runtime.ax)
            _ = AXHelpers.setAttribute(focusedElement, kAXFocusedAttribute as String, kCFBooleanTrue, runtime: runtime.ax)
            Thread.sleep(forTimeInterval: 0.1)
        }
        return focusMatches()
    }

    /// Runs a synchronous operation that moves the key view (a typed entry into a control-bar
    /// field) and puts it back. The response says whether the re-read agrees.
    static func withFocusRestored(
        runtime: AXLogicProElements.Runtime,
        _ operation: () -> ChannelResult
    ) -> ChannelResult {
        guard let origin = markerListOrigin(runtime: runtime, listWasOpen: true) else { return operation() }
        let result = operation()
        let restored = restoreFocus(origin, runtime: runtime)
        return annotate(result, with: ["focus_restored": restored])
    }

    static func restoreMarkerListOrigin(
        _ opened: OpenedMarkerList,
        runtime: AXLogicProElements.Runtime
    ) async -> MarkerListRestoration {
        let app = opened.origin.app
        func present(in windows: [AXUIElement]) -> Bool { windows.contains { CFEqual($0, opened.window) } }
        func unreadableCensus(_ status: AXHelpers.AXStatusError, _ when: String) -> String {
            "the window census could not be read \(when) (AX status \(status.diagnosticLabel)), "
                + "so the Marker List's closure is unverified"
        }
        var reason: String?
        var closed = false
        switch windowCensus(app, runtime: runtime) {
        case .failure(let status):
            reason = unreadableCensus(status, "before the close")
        case .success(let windows) where !present(in: windows):
            closed = true // a census that was read no longer holds the window this operation opened
        case .success:
            // Still open. Act on it only while it is still the list of the project it was opened
            // for: an element can outlive its project, and a project change is not ours to undo.
            let document: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                opened.window, kAXDocumentAttribute as String, runtime: runtime.ax)
            switch document {
            case .success(.some(let value)) where value == opened.projectDocument:
                if let button: AXUIElement = AXHelpers.getAttribute(
                    opened.window, kAXCloseButtonAttribute as String, runtime: runtime.ax) {
                    _ = AXHelpers.performAction(button, kAXPressAction as String, runtime: runtime.ax)
                    var lastFailure: AXHelpers.AXStatusError?
                    for _ in 0..<30 {
                        switch windowCensus(app, runtime: runtime) {
                        case .success(let windows):
                            lastFailure = nil
                            closed = !present(in: windows)
                        case .failure(let status):
                            lastFailure = status
                        }
                        if closed { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if !closed {
                        reason = lastFailure.map { unreadableCensus($0, "after the close") }
                            ?? "the Marker List window did not close"
                    }
                } else {
                    reason = "the Marker List window has no readable close button"
                }
            case .success:
                reason = "the window this operation opened is no longer bound to its project, so it was left open"
            case .failure(let status):
                reason = "the opened window's project could not be read (AX status \(status.diagnosticLabel)), "
                    + "so it was left open"
            }
        }
        let focusRestored: Bool
        if let unbound = await projectBindingRefusal(opened, runtime: runtime) {
            focusRestored = false
            if reason == nil { reason = unbound }
        } else {
            focusRestored = restoreFocus(opened.origin, runtime: runtime)
            if !focusRestored, reason == nil { reason = "focus did not return to the element it was on" }
        }
        return MarkerListRestoration(closed: closed, focusRestored: focusRestored, reason: reason)
    }

    /// Why focus must not be written back, or nil when it may. Putting the focus back is an act
    /// on the screen, and it is this operation's only while the project it opened the list for is
    /// still the one in front: a user who moved to another project keeps the focus they put there.
    private static func projectBindingRefusal(
        _ opened: OpenedMarkerList,
        runtime: AXLogicProElements.Runtime
    ) async -> String? {
        var last = "the main window could not be read, so focus restoration is unverified"
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(50)) }
            let main: Result<AXUIElement?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                opened.origin.app, kAXMainWindowAttribute as String, runtime: runtime.ax)
            guard case .success(.some(let window)) = main else { continue }
            let document: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                window, kAXDocumentAttribute as String, runtime: runtime.ax)
            switch document {
            case .success(.some(let value)) where value == opened.projectDocument:
                return nil
            case .success(.some):
                return "another project is in front now, so focus was left where the user put it"
            default:
                last = "the main window's project could not be read, so focus restoration is unverified"
            }
        }
        return last
    }

    /// Runs a marker operation and, when it opened the Marker List itself (the opener records the
    /// screen it found in the ledger), closes it and restores focus. The outcome is reported in the
    /// response as `marker_list_closed` / `ui_restored`; the operation's own verdict is never
    /// changed by it. An operation that opened nothing performs no read here.
    static func withMarkerListRestored(
        runtime: AXLogicProElements.Runtime,
        _ operation: () async -> ChannelResult
    ) async -> ChannelResult {
        let result = await operation()
        guard let opened = openedListLedger.take() else { return result }
        let restoration = await restoreMarkerListOrigin(opened, runtime: runtime)
        var extras: [String: Any] = [
            "marker_list_closed": restoration.closed,
            "ui_restored": restoration.closed && restoration.focusRestored,
        ]
        if let reason = restoration.reason { extras["ui_restore_reason"] = reason }
        return annotate(result, with: extras)
    }

    private static func annotate(_ result: ChannelResult, with extras: [String: Any]) -> ChannelResult {
        guard let data = result.message.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return result }
        for (key, value) in extras { object[key] = value }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { return result }
        switch result {
        case .success: return .success(text)
        case .error: return .error(text)
        }
    }
}
