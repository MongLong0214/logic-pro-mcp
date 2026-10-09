import ApplicationServices
import Foundation

private enum MarkerCaptureContext {
    struct LockBoundary: @unchecked Sendable {
        let row: AXUIElement
        let cell: AXUIElement
    }
    struct Authority: @unchecked Sendable {
        let pid: pid_t
        let app: AXUIElement
        let main: AXUIElement
        let focusedWindow: AXUIElement
        let focusedElement: AXUIElement
        let document: String
    }
    @TaskLocal static var authority: Authority?
}

extension AccessibilityChannel {
    /// Explicit UI-mutating capture; the normal getter and poller never call this.
    /// The caller supplies the opener so fixtures cannot escape into AppleScript.
    static func defaultCaptureMarkers(
        runtime: AXLogicProElements.Runtime,
        openMarkerList: @Sendable () async -> ChannelResult
    ) async -> ChannelResult {
        var extras: [String: Any] = [
            "operation": "nav.capture_markers", "write_attempted": false,
            "ui_restored": false, "marker_source": "ax_marker_list",
        ]
        var observation = "initial_state"
        let originalPID = runtime.logicProPID()
        func blocked() -> Bool {
            Task.isCancelled || OperationTraceContext.current?.ownsGate() == false
        }
        func writeBlocked() -> Bool {
            blocked() || originalPID == nil || runtime.logicProPID() != originalPID
                || runtime.focusedApplicationPID() != originalPID
        }
        func raw(_ element: AXUIElement, _ attribute: String) throws -> AnyObject {
            observation = attribute
            let result: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                element, attribute, runtime: runtime.ax
            )
            guard let value = try result.get() else { throw AXHelpers.AXStatusError.malformedAttribute }
            return value
        }
        func element(_ source: AXUIElement, _ attribute: String) throws -> AXUIElement {
            let value = try raw(source, attribute)
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw AXHelpers.AXStatusError.malformedAttribute
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        func text(_ source: AXUIElement, _ attribute: String) throws -> String {
            guard let value = try raw(source, attribute) as? String, !value.isEmpty else {
                throw AXHelpers.AXStatusError.malformedAttribute
            }
            return value
        }
        func windows(_ app: AXUIElement) throws -> [AXUIElement] {
            let value = try raw(app, kAXWindowsAttribute as String)
            guard CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AnyObject],
                  array.count <= 128 else { throw AXHelpers.AXStatusError.malformedAttribute }
            var result: [AXUIElement] = []
            for item in array {
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else {
                    throw AXHelpers.AXStatusError.malformedAttribute
                }
                let window = unsafeBitCast(item, to: AXUIElement.self)
                guard !result.contains(where: { CFEqual($0, window) }) else {
                    throw AXHelpers.AXStatusError.malformedAttribute
                }
                result.append(window)
            }
            return result
        }
        func contains(_ elements: [AXUIElement], _ target: AXUIElement) -> Bool {
            elements.contains { CFEqual($0, target) }
        }
        // Opening Marker List can scroll the original arrange window to the
        // playhead. Retain physical controls, not replacement controls or ordinals.
        typealias Scroll = (control: AXUIElement, value: Double)
        var markerLockBoundaries: [MarkerCaptureContext.LockBoundary] = []
        func scrollValues(_ window: AXUIElement) throws -> [Scroll] {
            observation = "scroll_inventory"
            let boundaries = markerLockBoundaries
            let base = runtime.ax
            // The Marker List's Lock cell is a data field, not a viewport
            // carrier. Native AX reports a failure for its children even while
            // the strict marker inventory reads the required Position/Name.
            // Scope only the physically retained Lock cells; no failed read is
            // interpreted as an empty subtree, and all other nodes stay strict.
            let viewportAX = AXHelpers.Runtime(
                axApp: base.axApp, attributeValue: base.attributeValue,
                attributeIsSettable: base.attributeIsSettable,
                setAttributeValue: base.setAttributeValue, children: base.children,
                performAction: base.performAction, childCount: base.childCount,
                actionNames: base.actionNames, actionNamesResult: base.actionNamesResult,
                childrenResult: { node in
                    if boundaries.contains(where: { CFEqual($0.cell, node) }) { return .success([]) }
                    return AXHelpers.childrenResult(node, runtime: base)
                },
                attributeValueResult: base.attributeValueResult,
                performActionResult: base.performActionResult,
                elementAtPosition: base.elementAtPosition
            )
            var seenRows: [AXUIElement] = []
            var boundaryChanged = false
            let census = try AXHelpers.censusDescendantResult(
                of: window, role: kAXScrollBarRole as String, maxDepth: 32,
                runtime: viewportAX, requiresCompleteTraversal: true,
                permittingRead: { !blocked() },
                observingRole: { node, role in
                    if boundaries.contains(where: { CFEqual($0.cell, node) }), role != kAXCellRole as String {
                        boundaryChanged = true
                    }
                    if boundaries.contains(where: { CFEqual($0.row, node) }), role != kAXRowRole as String {
                        boundaryChanged = true
                    }
                },
                observingChildren: { parent, children in
                    for boundary in boundaries where CFEqual(boundary.row, parent) {
                        seenRows.append(parent)
                        if children.first.map({ CFEqual($0, boundary.cell) }) != true {
                            boundaryChanged = true
                        }
                    }
                }
            ).get()
            guard !boundaryChanged,
                  boundaries.allSatisfy({ boundary in seenRows.contains(where: { CFEqual($0, boundary.row) }) }) else {
                throw AXHelpers.AXStatusError.malformedAttribute
            }
            guard census.matches.count <= 32 else { throw AXHelpers.AXStatusError.malformedAttribute }
            var values: [Scroll] = []
            for control in census.matches {
                guard !values.contains(where: { CFEqual($0.control, control) }),
                      CFEqual(try element(control, kAXWindowAttribute as String), window) else {
                    throw AXHelpers.AXStatusError.malformedAttribute
                }
                let rawValue = try raw(control, kAXValueAttribute as String)
                guard CFGetTypeID(rawValue) != CFBooleanGetTypeID(), let value = rawValue as? NSNumber,
                      value.doubleValue.isFinite, (0...1).contains(value.doubleValue) else {
                    throw AXHelpers.AXStatusError.malformedAttribute
                }
                values.append((control, value.doubleValue))
            }
            return values
        }
        func sameScrollControls(_ a: [Scroll], _ b: [Scroll]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { CFEqual($0.control, $1.control) }
        }
        func sameScrollValues(_ a: [Scroll], _ b: [Scroll]) -> Bool {
            sameScrollControls(a, b) && zip(a, b).allSatisfy { $0.value == $1.value }
        }
        func lists(_ windows: [AXUIElement], document: String) throws -> [AXUIElement] {
            try windows.filter { window in
                let title = try text(window, kAXTitleAttribute as String)
                guard AXLocalePolicy.markerListWindowSuffixes.contains(where: { title.hasSuffix($0) }) else {
                    return false
                }
                return try text(window, kAXDocumentAttribute as String) == document
            }
        }
        func failure(_ error: HonestContract.FailureError = .readbackUnavailable, hint: String) -> ChannelResult {
            extras["observation"] = observation
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: extras))
        }
        func capture(_ list: AXUIElement) -> [MarkerState]? {
            switch AXLogicProElements.markerListInventoryFromListWindowWithReadFailure(list, runtime: runtime.ax) {
            case .success(let inventory): return inventory.markers
            case .failure(let error):
                extras["marker_read_failure_site"] = error.site.rawValue
                extras["marker_read_status"] = error.status.diagnosticLabel
                return nil
            }
        }
        func publish(_ markers: [MarkerState]) -> ChannelResult {
            guard let data = try? JSONEncoder().encode(markers),
                  let array = try? JSONSerialization.jsonObject(with: data) else {
                return failure(hint: "Captured markers could not be encoded.")
            }
            extras["markers"] = array
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        do {
            guard !blocked(), let app = AXLogicProElements.appRoot(runtime: runtime) else {
                return failure(hint: "Capture stopped before any UI write.")
            }
            let before = try windows(app)
            let main = try element(app, kAXMainWindowAttribute as String)
            let focusedWindow = try element(app, kAXFocusedWindowAttribute as String)
            let focusedElement = try element(app, kAXFocusedUIElementAttribute as String)
            let document = try text(main, kAXDocumentAttribute as String)
            guard contains(before, main), contains(before, focusedWindow),
                  try text(focusedWindow, kAXDocumentAttribute as String) == document,
                  CFEqual(try element(focusedElement, kAXWindowAttribute as String), focusedWindow) else {
                return failure(hint: "Original project and focused UI could not be bound.")
            }
            let existing = try lists(before, document: document)
            guard existing.count <= 1 else {
                return failure(hint: "More than one Marker List matches the project.")
            }
            if let list = existing.first, CFEqual(main, list) {
                // Bind structural scope only. Read AXRows and marker values
                // after the original scrollbar baseline, not before it.
                guard let table = try AXLogicProElements.markerListTable(in: list, runtime: runtime.ax).get() else {
                    return failure(hint: "The Marker List table could not be bound.")
                }
                let rows: [AXUIElement]
                switch AXLogicProElements.markerListStructuralRows(from: table, ownerWindow: list, runtime: runtime.ax) {
                case .success(let observed): rows = observed
                case .failure(let error):
                    extras["marker_read_failure_site"] = error.site.rawValue
                    extras["marker_read_status"] = error.status.diagnosticLabel
                    return failure(hint: "The Marker List row structure could not be bound.")
                }
                for row in rows {
                    let children = try AXHelpers.childrenResult(row, runtime: runtime.ax).get()
                    guard let lock = children.first,
                          try text(row, kAXRoleAttribute as String) == kAXRowRole as String,
                          try text(lock, kAXRoleAttribute as String) == kAXCellRole as String else {
                        return failure(hint: "The retained Marker List Lock cell could not be bound.")
                    }
                    markerLockBoundaries.append(.init(row: row, cell: lock))
                }
            }
            let originalScroll = try scrollValues(main)
            if let list = existing.first {
                extras["already_open"] = true
                let markers = capture(list)
                let currentWindows = try windows(app)
                let currentLists = try lists(currentWindows, document: document)
                guard !blocked(), currentWindows.count == before.count,
                      before.allSatisfy({ contains(currentWindows, $0) }),
                      currentLists.count == 1, CFEqual(currentLists[0], list),
                      CFEqual(try element(app, kAXMainWindowAttribute as String), main),
                      CFEqual(try element(app, kAXFocusedWindowAttribute as String), focusedWindow),
                      CFEqual(try element(app, kAXFocusedUIElementAttribute as String), focusedElement),
                      try text(main, kAXDocumentAttribute as String) == document,
                      try text(focusedWindow, kAXDocumentAttribute as String) == document,
                      try text(list, kAXDocumentAttribute as String) == document,
                      CFEqual(try element(focusedElement, kAXWindowAttribute as String), focusedWindow),
                      sameScrollValues(try scrollValues(main), originalScroll),
                      !blocked(), runtime.logicProPID() == originalPID else {
                    return failure(hint: "The already-open Marker List changed during inventory read.")
                }
                extras["ui_restored"] = true
                guard let markers else { return failure(hint: "Marker List rows could not be read.") }
                return publish(markers)
            }
            guard !writeBlocked(), let originalPID else { return failure(hint: "Capture stopped before opening Marker List.") }
            extras["already_open"] = false
            let opened = await MarkerCaptureContext.$authority.withValue(.init(
                pid: originalPID, app: app, main: main, focusedWindow: focusedWindow,
                focusedElement: focusedElement, document: document
            )) { await openMarkerList() }
            let openerBody = opened.message.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let openerAttempt = openerBody?["write_attempted"] as? Bool
            extras["write_attempted"] = openerAttempt ?? true
            guard openerAttempt != false else {
                return failure(hint: "The opener made no UI write; a concurrent window is not capture-owned.")
            }
            // Even a failed opener may have opened its window. Bind and clean up
            // that exact new window before returning the opener's failure.
            guard !writeBlocked() else { return failure(hint: "Capture abandoned; UI restoration is not promised.") }
            let after = try windows(app)
            let openedMain = try element(app, kAXMainWindowAttribute as String)
            let openedFocusWindow = try element(app, kAXFocusedWindowAttribute as String)
            let openedFocusElement = try element(app, kAXFocusedUIElementAttribute as String)
            let matches = try lists(after, document: document)
            let newWindows = after.filter { !contains(before, $0) }
            guard contains(after, main), contains(after, focusedWindow),
                  try text(main, kAXDocumentAttribute as String) == document,
                  try text(focusedWindow, kAXDocumentAttribute as String) == document,
                  matches.count == 1, newWindows.count == 1,
                  let owned = matches.first, CFEqual(newWindows[0], owned),
                  (CFEqual(openedMain, main) || CFEqual(openedMain, owned)),
                  (CFEqual(openedFocusWindow, focusedWindow) || CFEqual(openedFocusWindow, owned)),
                  CFEqual(try element(openedFocusElement, kAXWindowAttribute as String), openedFocusWindow),
                  try text(try element(app, kAXMainWindowAttribute as String), kAXDocumentAttribute as String) == document,
                  try text(try element(app, kAXFocusedWindowAttribute as String), kAXDocumentAttribute as String) == document else {
                return failure(hint: "The new Marker List could not be uniquely owned; no window was closed.")
            }
            let markers = opened.isSuccess ? capture(owned) : nil
            // Revalidate ownership after the potentially failing inventory read.
            func closeOwned() throws -> Bool {
                guard !writeBlocked() else { return false }
                let atClose = try windows(app)
                let closeMatches = try lists(atClose, document: document)
                guard atClose.count == before.count + 1,
                      before.allSatisfy({ contains(atClose, $0) }),
                      closeMatches.count == 1, CFEqual(closeMatches[0], owned),
                      CFEqual(try element(app, kAXMainWindowAttribute as String), openedMain),
                      CFEqual(try element(app, kAXFocusedWindowAttribute as String), openedFocusWindow),
                      CFEqual(try element(app, kAXFocusedUIElementAttribute as String), openedFocusElement),
                      try text(main, kAXDocumentAttribute as String) == document,
                      try text(focusedWindow, kAXDocumentAttribute as String) == document,
                      try text(owned, kAXDocumentAttribute as String) == document else { return false }
                return !writeBlocked()
            }
            guard try closeOwned() else {
                return failure(hint: "Capture lost window ownership; no cleanup write was attempted.")
            }
            let close = try element(owned, kAXCloseButtonAttribute as String)
            guard CFEqual(try element(close, kAXWindowAttribute as String), owned),
                  try text(close, kAXRoleAttribute as String) == kAXButtonRole as String,
                  let enabled = try raw(close, kAXEnabledAttribute as String) as? Bool, enabled,
                  try closeOwned() else {
                return failure(.axWriteFailed, hint: "The owned Marker List close button could not be pressed.")
            }
            extras["write_attempted"] = true
            _ = AXHelpers.performAction(close, kAXPressAction as String, runtime: runtime.ax)
            let closed = try windows(app)
            let closedMain = try element(app, kAXMainWindowAttribute as String)
            let closedFocusWindow = try element(app, kAXFocusedWindowAttribute as String)
            let closedFocusElement = try element(app, kAXFocusedUIElementAttribute as String)
            guard !contains(closed, owned), closed.count == before.count,
                  before.allSatisfy({ contains(closed, $0) }),
                  (CFEqual(closedMain, main) || CFEqual(closedMain, openedMain)),
                  (CFEqual(closedFocusWindow, focusedWindow) || CFEqual(closedFocusWindow, openedFocusWindow)),
                  (CFEqual(closedFocusElement, focusedElement) || CFEqual(closedFocusElement, openedFocusElement)),
                  try text(main, kAXDocumentAttribute as String) == document,
                  try text(focusedWindow, kAXDocumentAttribute as String) == document,
                  CFEqual(try element(focusedElement, kAXWindowAttribute as String), focusedWindow) else {
                return failure(hint: "Marker List closure or original UI ownership could not be verified.")
            }
            func restorationOwned() throws -> Bool {
                guard !writeBlocked() else { return false }
                let currentWindows = try windows(app)
                let currentMain = try element(app, kAXMainWindowAttribute as String)
                let currentWindow = try element(app, kAXFocusedWindowAttribute as String)
                let currentElement = try element(app, kAXFocusedUIElementAttribute as String)
                let currentDocument = try text(main, kAXDocumentAttribute as String)
                let currentFocusedDocument = try text(focusedWindow, kAXDocumentAttribute as String)
                let originalElementWindow = try element(focusedElement, kAXWindowAttribute as String)
                return currentWindows.count == before.count
                    && before.allSatisfy({ contains(currentWindows, $0) })
                    && (CFEqual(currentMain, main) || CFEqual(currentMain, closedMain))
                    && (CFEqual(currentWindow, focusedWindow) || CFEqual(currentWindow, closedFocusWindow))
                    && (CFEqual(currentElement, focusedElement) || CFEqual(currentElement, closedFocusElement))
                    && currentDocument == document && currentFocusedDocument == document
                    && CFEqual(originalElementWindow, focusedWindow) && !writeBlocked()
            }
            guard try restorationOwned() else { return failure(hint: "Capture lost ownership before restoration.") }
            _ = AXHelpers.setAttribute(main, kAXMainAttribute, kCFBooleanTrue, runtime: runtime.ax)
            guard try restorationOwned() else { return failure(hint: "Capture lost ownership during restoration.") }
            _ = AXHelpers.setAttribute(focusedWindow, kAXFocusedAttribute, kCFBooleanTrue, runtime: runtime.ax)
            guard try restorationOwned() else { return failure(hint: "Capture lost ownership during restoration.") }
            _ = AXHelpers.setAttribute(focusedElement, kAXFocusedAttribute, kCFBooleanTrue, runtime: runtime.ax)
            guard try restorationOwned(), CFEqual(try element(app, kAXMainWindowAttribute as String), main),
                  CFEqual(try element(app, kAXFocusedWindowAttribute as String), focusedWindow),
                  CFEqual(try element(app, kAXFocusedUIElementAttribute as String), focusedElement) else {
                return failure(hint: "Original main window and focus were not observed restored.")
            }
            for original in originalScroll {
                let current = try scrollValues(main)
                guard sameScrollControls(current, originalScroll), try restorationOwned() else {
                    return failure(hint: "Original scroll controls are no longer owned; no replacement was changed.")
                }
                guard let observed = current.first(where: { CFEqual($0.control, original.control) }) else {
                    return failure(hint: "Original scroll control could not be read.")
                }
                if observed.value == original.value { continue }
                guard AXHelpers.isAttributeSettable(original.control, kAXValueAttribute as String,
                                                    runtime: runtime.ax) == true,
                      sameScrollControls(try scrollValues(main), originalScroll), try restorationOwned() else {
                    return failure(hint: "Original scroll value cannot be safely restored.")
                }
                _ = AXHelpers.setAttribute(original.control, kAXValueAttribute as String,
                                           NSNumber(value: original.value), runtime: runtime.ax)
                guard try restorationOwned() else {
                    return failure(hint: "Capture lost ownership during scroll restoration.")
                }
            }
            guard sameScrollValues(try scrollValues(main), originalScroll), try restorationOwned(),
                  CFEqual(try element(app, kAXMainWindowAttribute as String), main),
                  CFEqual(try element(app, kAXFocusedWindowAttribute as String), focusedWindow),
                  CFEqual(try element(app, kAXFocusedUIElementAttribute as String), focusedElement) else {
                return failure(hint: "Original scroll positions and focus were not observed restored.")
            }
            extras["ui_restored"] = true
            guard opened.isSuccess else {
                extras["opener_error"] = opened.message
                return failure(.axWriteFailed, hint: "Opening failed; the owned window was cleaned up.")
            }
            guard let markers else { return failure(hint: "Marker List rows could not be read; UI was restored.") }
            return publish(markers)
        } catch {
            if let status = error as? AXHelpers.AXStatusError {
                extras["ax_status"] = status.diagnosticLabel
                if status.source == .axStatus { extras["ax_code"] = status.raw }
            }
            return failure(hint: "Capture or restoration observation was unreadable; no unknown window was closed.")
        }
    }

    /// Direct retained menu-leaf actuation: no activation, top-bar press, script,
    /// keyboard event or Escape cleanup. A visible new list, not AX's return
    /// code alone, is the outcome the capture protocol must independently bind.
    static func defaultOpenMarkerListForCapture(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        var attempted = false
        let authority = MarkerCaptureContext.authority
        let originalPID = authority?.pid ?? runtime.logicProPID()
        func stopped() -> Bool {
            Task.isCancelled || OperationTraceContext.current?.ownsGate() == false
                || originalPID == nil || runtime.logicProPID() != originalPID
                || runtime.focusedApplicationPID() != originalPID
        }
        func refused(_ hint: String, status: AXHelpers.AXStatusError? = nil) -> ChannelResult {
            var extras: [String: Any] = [
                "operation": "nav.capture_markers", "opener_source": "ax_menu_item",
                "write_attempted": attempted,
            ]
            if let status { extras["ax_status"] = status.diagnosticLabel }
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: hint, extras: extras))
        }
        func string(_ element: AXUIElement, _ attribute: String) throws -> String {
            let read: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                element, attribute, runtime: runtime.ax
            )
            guard let value = try read.get() else { throw AXHelpers.AXStatusError.malformedAttribute }
            return value
        }
        func identity(_ source: AXUIElement, _ attribute: String) throws -> AXUIElement {
            let read: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                source, attribute, runtime: runtime.ax
            )
            guard let value = try read.get(), CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw AXHelpers.AXStatusError.malformedAttribute
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        do {
            guard !stopped(), let app = AXLogicProElements.appRoot(runtime: runtime),
                  let bar = AXLogicProElements.getMenuBar(runtime: runtime) else {
                return refused("Logic must already own focus; capture never activates another application.")
            }
            if let authority, !CFEqual(app, authority.app) {
                return refused("Capture opener no longer belongs to the original application.")
            }
            let originalMain = try authority?.main ?? identity(app, kAXMainWindowAttribute as String)
            let originalWindow = try authority?.focusedWindow ?? identity(app, kAXFocusedWindowAttribute as String)
            let originalElement = try authority?.focusedElement ?? identity(app, kAXFocusedUIElementAttribute as String)
            let document = try authority?.document ?? string(originalMain, kAXDocumentAttribute as String)
            guard !document.isEmpty,
                  try string(originalWindow, kAXDocumentAttribute as String) == document,
                  CFEqual(try identity(originalElement, kAXWindowAttribute as String), originalWindow) else {
                return refused("Capture opener could not bind the original project and focus.")
            }
            let bars = try AXHelpers.childrenResult(bar, runtime: runtime.ax).get()
            guard bars.count <= 64 else { return refused("Menu bar census exceeded its bound.") }
            let navigation = try bars.filter {
                try string($0, kAXRoleAttribute as String) == kAXMenuBarItemRole as String
                    && AXLocalePolicy.navigateMenuBar.matches(
                        try string($0, kAXTitleAttribute as String), mode: .exact
                    )
            }
            guard navigation.count == 1 else { return refused("Navigate menu was not unique.") }
            // Retain the existing lookup's exact leaf, then prove uniqueness in
            // Navigate's direct rows. Unrelated nested submenus are not this
            // operation's selector scope and need not be traversed or opened.
            guard case .found(let retained) = AXLogicProElements.menuItemRead(
                labelPath: [AXLocalePolicy.navigateMenuBar, AXLocalePolicy.openMarkerListMenuItem],
                runtime: runtime
            ) else { return refused("Open Marker List menu entry could not be read.") }
            var matches: [AXUIElement] = []
            let containers = try AXHelpers.childrenResult(navigation[0], runtime: runtime.ax).get()
            guard containers.count <= 64 else { return refused("Navigate menu containers exceeded their bound.") }
            var rows: [AXUIElement] = []
            var seen: [AXUIElement] = [bar, navigation[0]]
            for container in containers {
                guard !stopped(), !seen.contains(where: { CFEqual($0, container) }) else {
                    return refused("Navigate menu containers were duplicated or cyclic.")
                }
                seen.append(container)
                switch try string(container, kAXRoleAttribute as String) {
                case let role where role == kAXMenuRole as String:
                    let children = try AXHelpers.childrenResult(container, runtime: runtime.ax).get()
                    guard rows.count + children.count <= 512 else {
                        return refused("Navigate direct rows exceeded their bound.")
                    }
                    rows.append(contentsOf: children)
                case let role where role == kAXMenuItemRole as String:
                    rows.append(container)
                    seen.removeLast() // The direct row is checked once below.
                default:
                    return refused("Navigate menu had an unsupported direct container.")
                }
            }
            guard rows.count <= 512 else { return refused("Navigate direct rows exceeded their bound.") }
            for current in rows {
                guard !stopped(), !seen.contains(where: { CFEqual($0, current) }),
                      try string(current, kAXRoleAttribute as String) == kAXMenuItemRole as String else {
                    return refused("Navigate direct rows were unreadable, duplicated or cyclic.")
                }
                seen.append(current)
                if AXLocalePolicy.openMarkerListMenuItem.matches(
                    try string(current, kAXTitleAttribute as String), mode: .exact
                ) { matches.append(current) }
            }
            let enabled: Result<Bool?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                retained, kAXEnabledAttribute as String, runtime: runtime.ax
            )
            guard matches.count == 1, CFEqual(matches[0], retained),
                  try enabled.get() == true,
                  try AXHelpers.getActionNamesResult(retained, runtime: runtime.ax).get().contains(kAXPressAction as String),
                  CFEqual(try identity(app, kAXMainWindowAttribute as String), originalMain),
                  CFEqual(try identity(app, kAXFocusedWindowAttribute as String), originalWindow),
                  CFEqual(try identity(app, kAXFocusedUIElementAttribute as String), originalElement),
                  try string(originalMain, kAXDocumentAttribute as String) == document,
                  try string(originalWindow, kAXDocumentAttribute as String) == document,
                  CFEqual(try identity(originalElement, kAXWindowAttribute as String), originalWindow),
                  !stopped() else { return refused("Open Marker List was ambiguous, disabled or not pressable.") }
            attempted = true
            _ = AXHelpers.performActionResult(retained, kAXPressAction as String, runtime: runtime.ax)
            for poll in 0..<20 {
                guard !stopped() else { return refused("Capture opening was abandoned; no further UI write was made.") }
                if AXLogicProElements.markerListBinding(runtime: runtime) != nil {
                    return .success(HonestContract.encodeStateA(extras: [
                        "operation": "nav.capture_markers", "opener_source": "ax_menu_item",
                        "write_attempted": true,
                    ]))
                }
                if poll < 19 { try await Task.sleep(for: .milliseconds(50)) }
            }
            return refused("The menu entry was pressed but a bound Marker List was not observed.")
        } catch {
            return refused("Capture menu could not be completely observed.", status: error as? AXHelpers.AXStatusError)
        }
    }

    static func defaultOpenMarkerList(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        if AXLogicProElements.findMarkerListWindow(runtime: runtime) != nil {
            return .success(HonestContract.encodeStateA(extras: [
                "operation": "nav.open_marker_list",
                "already_open": true,
            ]))
        }
        if AXLogicProElements.hasUnverifiedMarkerListWindow(runtime: runtime) {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "The requested marker view could not be verified.",
                extras: [
                    "operation": "nav.open_marker_list",
                    "write_attempted": false,
                ]
            ))
        }
        let menuResult = await pressMarkerMenuItem(.openList)
        guard menuResult.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Navigate > Open Marker List was not found or could not be pressed."
            ))
        }
        for _ in 0..<20 {
            if AXLogicProElements.findMarkerListWindow(runtime: runtime) != nil {
                return .success(HonestContract.encodeStateA(extras: [
                    "operation": "nav.open_marker_list",
                    "already_open": false,
                ]))
            }
            usleep(50_000)
        }
        return .error(HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "Navigate > Open Marker List was pressed, but the Marker List window did not appear."
        ))
    }

    static func defaultCreateMarker(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        let openResult = await defaultOpenMarkerList(runtime: runtime)
        guard openResult.isSuccess,
              let listWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) else {
            return openResult
        }

        guard case .success(let before) = AXLogicProElements.enumerateMarkersFromListWindow(
            listWindow,
            runtime: runtime.ax
        ) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "Marker List rows could not be read before creating a marker."
            ))
        }
        guard focusArrangeWindow(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "The arrange window could not be focused before creating a marker."
            ))
        }
        let menuResult = await pressMarkerMenuItem(.create)
        guard menuResult.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Navigate > Create Marker was not found or could not be pressed."
            ))
        }

        var after = before
        for _ in 0..<20 {
            usleep(50_000)
            guard let currentWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) else {
                continue
            }
            guard case .success(let current) = AXLogicProElements.enumerateMarkersFromListWindow(
                currentWindow,
                runtime: runtime.ax
            ) else { continue }
            after = current
            if after.count > before.count {
                break
            }
        }

        let requestedName = params["name"]
        var nameApplied: Bool? = nil
        var nameWriteAttempted: Bool? = nil
        if let requestedName, !requestedName.isEmpty,
           let currentWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) {
            let write = await renameSelectedMarker(
                requestedName,
                in: currentWindow,
                runtime: runtime
            )
            nameWriteAttempted = write.writeAttempted
            if !write.writeAttempted {
                nameApplied = false
            }
        }

        var extras: [String: Any] = [
            "operation": "nav.create_marker",
            "method": "accessibility_menu",
            "menu_path": "Navigate > Create Marker",
            "sent": true,
            "marker_count_before_channel": before.count,
            "marker_count_after_channel": after.count,
        ]
        if let requestedName, !requestedName.isEmpty {
            extras["requested_name"] = requestedName
            if let nameApplied {
                extras["name_applied"] = nameApplied
            }
            if let nameWriteAttempted {
                extras["name_write_attempted"] = nameWriteAttempted
            }
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: extras
        ))
    }

    static func defaultRenameMarker(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard let rawIndex = params["index"], let index = Int(rawIndex), index >= 0,
              let name = params["name"], !name.isEmpty else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "nav.rename_marker requires an index >= 0 and a non-empty name"
            ))
        }
        guard !AXLogicProElements.hasUnverifiedMarkerListWindow(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "The requested marker target could not be verified.",
                extras: [
                    "operation": "nav.rename_marker",
                    "requested_index": index,
                    "requested_name": name,
                    "write_attempted": false,
                ]
            ))
        }
        let openResult = await defaultOpenMarkerList(runtime: runtime)
        guard openResult.isSuccess else {
            return openResult
        }
        guard let binding = AXLogicProElements.markerListBinding(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "The requested marker target could not be verified after opening.",
                extras: [
                    "operation": "nav.rename_marker",
                    "requested_index": index,
                    "requested_name": name,
                    "write_attempted": false,
                ]
            ))
        }
        let window = binding.window
        guard case .success(let before) = AXLogicProElements.enumerateMarkersFromListWindow(
            window,
            runtime: runtime.ax
        ) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "Marker List rows could not be read before renaming a marker.",
                extras: ["operation": "nav.rename_marker", "requested_index": index, "write_attempted": false]
            ))
        }
        guard let target = before.first(where: { $0.id == index }) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Marker index \(index) was not found in the Marker List",
                extras: ["requested_index": index, "marker_count": before.count]
            ))
        }
        let stablePosition = target.positionSource == .parser
            && before.filter({ $0.position == target.position }).count == 1
            ? target.position
            : nil
        if target.name == name {
            let extras: [String: Any] = [
                "operation": "nav.rename_marker",
                "index": index,
                "previous_name": target.name,
                "requested_name": name,
                "observed_name": target.name,
                "write_attempted": false,
            ]
            guard stablePosition != nil else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras
                ))
            }
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        guard selectMarkerRow(index, in: window, runtime: runtime.ax) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Marker index \(index) could not be selected",
                extras: ["write_attempted": false]
            ))
        }
        let write = await renameSelectedMarker(name, in: window, runtime: runtime)
        var extras: [String: Any] = [
            "operation": "nav.rename_marker",
            "index": index,
            "previous_name": target.name,
            "requested_name": name,
            "write_attempted": write.writeAttempted,
        ]
        guard write.writeAttempted else {
            return .error(HonestContract.encodeStateC(
                error: write.failureError ?? .axWriteFailed,
                hint: "The selected marker name write could not be attempted",
                extras: extras
            ))
        }

        guard let stablePosition,
              let currentBinding = AXLogicProElements.markerListBinding(runtime: runtime),
              currentBinding.projectDocument == binding.projectDocument,
              CFEqual(currentBinding.window, binding.window) else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        guard case .success(let after) = AXLogicProElements.enumerateMarkersFromListWindow(
            currentBinding.window,
            runtime: runtime.ax
        ) else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        let matches = after.filter { $0.positionSource == .parser && $0.position == stablePosition }
        guard matches.count == 1 else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        let observed = matches[0]
        extras["observed_name"] = observed.name
        guard observed.name == name else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: extras
            ))
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    private static func selectMarkerRow(
        _ index: Int,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let table = AXHelpers.findAllDescendants(
            of: window,
            role: kAXTableRole,
            maxDepth: 8,
            runtime: runtime
        ).first else { return false }
        let rows: [AXUIElement] = AXHelpers.getAttribute(
            table,
            "AXRows",
            runtime: runtime
        ) ?? AXHelpers.getChildren(table, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime) == (kAXRowRole as String)
        }
        guard rows.indices.contains(index) else { return false }
        let row = rows[index]
        if AXHelpers.setAttribute(
            table,
            kAXSelectedRowsAttribute,
            [row] as CFArray,
            runtime: runtime
        ) {
            return true
        }
        return AXHelpers.setAttribute(
            row,
            kAXSelectedAttribute,
            kCFBooleanTrue,
            runtime: runtime
        )
    }

    enum MarkerMenuAction {
        case openList
        case create
    }

    /// Kept internal so the #519 menu-locale regression tests can assert the exact generated
    /// AppleScript (label coverage, canonical-first ordering, the Escape-on-error path) without
    /// invoking Logic Pro. Pure text generation — no execution.
    static func markerMenuActuationScript(_ action: MarkerMenuAction) -> String {
        let target = LogicProTarget.appleScriptTarget()
        let itemLabelSet: AXLocalePolicy.LabelSet
        switch action {
        case .openList:
            itemLabelSet = AXLocalePolicy.openMarkerListMenuItem
        case .create:
            itemLabelSet = AXLocalePolicy.createMarkerMenuItem
        }
        let focusBlock: String
        switch action {
        case .create:
            // The arrange window's title suffix is localized, so it is resolved from the same
            // LabelSet the rest of this file uses. It was an English/Korean literal pair, which
            // made this script fail outright on a Japanese Logic and surface as a missing menu item.
            let arrangeResolution = AppleScriptMenuResolution.windowWithTitleSuffix(
                AXLocalePolicy.arrangeWindowTitleSuffix,
                variableName: "targetWindow",
                notFoundError: "ARRANGE_WINDOW_NOT_FOUND"
            )
            focusBlock = """
                \(arrangeResolution)
                set value of attribute "AXMain" of targetWindow to true
                perform action "AXRaise" of targetWindow
                delay 0.1
            """
        case .openList:
            focusBlock = ""
        }
        // #519: resolve the Navigate bar/item names from AXLocalePolicy's LabelSets instead of
        // hard-coding one EN/KO literal each — see AppleScriptMenuResolution for why.
        let barResolution = AppleScriptMenuResolution.menuBarItem(
            AXLocalePolicy.navigateMenuBar,
            variableName: "barName",
            notFoundError: "NAVIGATE_MENU_BAR_NOT_FOUND"
        )
        let itemResolution = AppleScriptMenuResolution.menuItem(
            itemLabelSet,
            under: "menu bar item barName of menu bar 1",
            variableName: "itemName",
            notFoundError: "NAVIGATE_MENU_ITEM_NOT_FOUND"
        )
        return """
        \(target.activateByBundleID)
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                set frontmost to true
        \(focusBlock)
                \(barResolution)
                click menu bar item barName of menu bar 1
                delay 0.1
                -- #346: once the menu is open, ANY failure (item missing on a
                -- wrong locale, or disabled) must Escape it before erroring so
                -- the Navigate menu is never left open (wedging Logic).
                try
                    \(itemResolution)
                    set targetItem to menu item itemName of menu 1 of menu bar item barName of menu bar 1
                    if enabled of targetItem is false then error "menu item disabled"
                    click targetItem
                on error errMsg
                    key code 53
                    delay 0.1
                    error errMsg
                end try
            end tell
        end tell
        return "clicked"
        """
    }

    private static func pressMarkerMenuItem(_ action: MarkerMenuAction) async -> ChannelResult {
        await AppleScriptChannel.executeAppleScript(markerMenuActuationScript(action))
    }

    private static func focusArrangeWindow(runtime: AXLogicProElements.Runtime) -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return false
        }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app,
            kAXWindowsAttribute,
            runtime: runtime.ax
        ) ?? []
        let candidates = windows.filter { window in
            let title = AXHelpers.getTitle(window, runtime: runtime.ax) ?? ""
            let isMarkerList = AXLocalePolicy.markerListWindowSuffixes.contains {
                title.hasSuffix($0)
            }
            let subrole: String? = AXHelpers.getAttribute(
                window,
                kAXSubroleAttribute,
                runtime: runtime.ax
            )
            let isDialog = subrole == (kAXDialogSubrole as String)
                || subrole == (kAXSystemDialogSubrole as String)
            return !isMarkerList && !isDialog
        }
        let window = candidates.max { lhs, rhs in
            let left = AXHelpers.getSize(lhs, runtime: runtime.ax) ?? .zero
            let right = AXHelpers.getSize(rhs, runtime: runtime.ax) ?? .zero
            return left.width * left.height < right.width * right.height
        } ?? AXLogicProElements.mainWindow(runtime: runtime)
        guard let window else { return false }
        let madeMain = AXHelpers.setAttribute(
            window,
            kAXMainAttribute,
            kCFBooleanTrue,
            runtime: runtime.ax
        )
        let raised = AXHelpers.performAction(window, kAXRaiseAction, runtime: runtime.ax)
        usleep(100_000)
        return madeMain || raised
    }

}
