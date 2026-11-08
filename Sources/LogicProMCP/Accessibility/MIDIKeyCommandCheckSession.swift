@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Drives the consented, read-only part of MIDI Key Command setup for one entry.
///
/// The session owns only a Key Commands window it opened itself. It refuses a
/// pre-existing window rather than overwriting the operator's filter state, types
/// only after positive focus proof, delegates exact row/column association to the
/// status-preserving AX surface reader, and publishes an inspection only after the
/// owned window is observed closed.
enum MIDIKeyCommandCheckSession {
    enum Outcome: Equatable {
        case inspected(MIDIKeyCommandSetup.Inspection)
        case failed(stage: String, cleanupConfirmed: Bool)
    }

    struct Runtime {
        var activateLogic: @Sendable () -> Void
        var logicIsFrontmost: @Sendable () -> Bool
        var postOptionK: @Sendable () -> Bool
        var typeText: @Sendable (String) -> Bool
        var sleep: @Sendable (Double) -> Void
        var isCancelled: @Sendable () -> Bool
        var ownsGate: @Sendable () -> Bool
        var uiLocale: @Sendable () -> String?
        var ax: AXHelpers.Runtime
        var elements: AXLogicProElements.Runtime

        static func production(ownsGate: @escaping @Sendable () -> Bool) -> Runtime {
            Runtime(
                activateLogic: { _ = ProcessUtils.Runtime.production.activateLogicPro() },
                logicIsFrontmost: ProcessUtils.Runtime.production.logicIsFrontmost,
                postOptionK: {
                    AXMouseHelper.Runtime.production.postFlaggedKeyEvent(40, .maskAlternate)
                },
                typeText: {
                    AXMouseHelper.typeText($0, isCancelled: { Task.isCancelled || !ownsGate() })
                },
                sleep: { Thread.sleep(forTimeInterval: $0) },
                isCancelled: { Task.isCancelled },
                ownsGate: ownsGate,
                uiLocale: { AXLogicProElements.logicUILocaleIdentifier() },
                ax: .production,
                elements: .production
            )
        }
    }

    private struct WindowCensus {
        let allWindowIDs: Set<Int>
        let candidates: [AXUIElement]
    }

    private enum WindowCensusResult {
        case observed(WindowCensus)
        case undetermined
    }

    private enum OpenedWindowResult {
        case found(AXUIElement)
        case failed(stage: String)
    }

    static func inspect(
        entry: MIDIKeyCommandBindingCatalog.Entry,
        runtime: Runtime
    ) -> Outcome {
        guard runtime.ownsGate(), !runtime.isCancelled() else {
            return .failed(stage: "ownership_lost", cleanupConfirmed: true)
        }
        guard let query = MIDIKeyCommandBindingCatalog.searchQuery(
            for: entry,
            locale: runtime.uiLocale()
        ) else {
            return .failed(stage: "command_name_unknown_for_locale", cleanupConfirmed: true)
        }

        let initialCensus: WindowCensus
        switch keyCommandsWindowCensus(runtime: runtime) {
        case .observed(let census):
            initialCensus = census
        case .undetermined:
            return .failed(stage: "key_commands_window_unreadable", cleanupConfirmed: true)
        }
        guard initialCensus.candidates.isEmpty else {
            return .failed(stage: "key_commands_in_use", cleanupConfirmed: true)
        }

        runtime.activateLogic()
        runtime.sleep(0.4)
        guard runtime.ownsGate(), !runtime.isCancelled() else {
            return .failed(stage: "ownership_lost", cleanupConfirmed: true)
        }
        // Activation and its settling delay create a user-interaction race. Re-read
        // immediately before Option-K and retain every existing window identity;
        // only one subsequently observed Key Commands window whose identity is new
        // can become session-owned.
        let baseline: WindowCensus
        switch keyCommandsWindowCensus(runtime: runtime) {
        case .observed(let census):
            baseline = census
        case .undetermined:
            return .failed(stage: "key_commands_window_unreadable", cleanupConfirmed: true)
        }
        guard baseline.candidates.isEmpty else {
            return .failed(stage: "key_commands_in_use", cleanupConfirmed: true)
        }
        guard runtime.postOptionK() else {
            return .failed(stage: "open_key_commands", cleanupConfirmed: true)
        }
        let window: AXUIElement
        switch openedWindow(after: baseline, runtime: runtime) {
        case .found(let observed):
            window = observed
        case .failed(let stage):
            return .failed(stage: stage, cleanupConfirmed: false)
        }

        func cleanup() -> Bool {
            guard runtime.ownsGate() else { return false }
            return close(window: window, runtime: runtime)
        }
        func fail(_ stage: String) -> Outcome {
            .failed(stage: stage, cleanupConfirmed: cleanup())
        }

        guard runtime.ownsGate(), !runtime.isCancelled() else { return fail("ownership_lost") }
        guard let search = searchField(in: window, runtime: runtime) else {
            return fail("search_field")
        }
        _ = AXHelpers.setAttribute(search, kAXValueAttribute, "" as CFTypeRef, runtime: runtime.ax)
        _ = AXHelpers.setAttribute(
            search,
            kAXFocusedAttribute,
            kCFBooleanTrue,
            runtime: runtime.ax
        )
        runtime.sleep(0.3)
        guard runtime.logicIsFrontmost(), focused(search, runtime: runtime) == true else {
            return fail("search_focus")
        }
        guard runtime.ownsGate(), !runtime.isCancelled() else { return fail("ownership_lost") }
        guard runtime.typeText(query) else { return fail("search_type") }
        runtime.sleep(0.4)
        guard runtime.ownsGate(), !runtime.isCancelled() else { return fail("ownership_lost") }

        let labels = MIDIKeyCommandSurfaceResolver.Labels(
            commandNames: Set(AXLocalePolicy.metronomeClickKeyCommandName.labels),
            controlSurfaceColumnTitles: Set(AXLocalePolicy.keyCommandsControlSurfaceColumnTitle.labels)
        )
        let inspection = map(
            MIDIKeyCommandAXSurface.read(
                in: window,
                entry: entry,
                labels: labels,
                runtime: runtime.ax
            )
        )
        guard cleanup() else {
            return .failed(stage: "close_key_commands", cleanupConfirmed: false)
        }
        return .inspected(inspection)
    }

    private static func map(_ outcome: MIDIKeyCommandAXSurface.Outcome) -> MIDIKeyCommandSetup.Inspection {
        switch outcome {
        case .resolved(_, _, let observation):
            switch observation {
            case .missing: return .missing
            case .provisional: return .provisional
            case .matchingLabelUnverifiedSource: return .matchingLabelUnverifiedSource
            case .conflicting: return .conflicting
            case .unreadable: return .unreadable
            }
        case .refused(let resolution):
            switch resolution {
            case .commandUnavailable: return .unknownCommand
            case .ambiguousCommand, .ambiguousAssignment: return .ambiguous
            case .columnUnavailable, .assignmentUnavailable, .geometryUnreadable:
                return .unreadable
            case .resolved:
                return .unreadable
            }
        case .unreadableSurface, .scanIncomplete:
            return .unreadable
        }
    }

    private static func keyCommandsWindowCensus(runtime: Runtime) -> WindowCensusResult {
        guard let app = AXLogicProElements.appRoot(runtime: runtime.elements) else {
            return .undetermined
        }
        let read: Result<[AXUIElement]?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            app,
            kAXWindowsAttribute,
            runtime: runtime.ax
        )
        guard case .success(let maybeWindows) = read else { return .undetermined }
        let windows = maybeWindows ?? []
        var candidates: [AXUIElement] = []
        for window in windows {
            let titleRead: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                window,
                kAXTitleAttribute,
                runtime: runtime.ax
            )
            let title: String?
            switch titleRead {
            case .success(nil):
                title = nil
            case .success(let value):
                guard let text = value as? String else { return .undetermined }
                title = text
            case .failure(let error) where error.isDefinitiveAbsence:
                title = nil
            case .failure:
                return .undetermined
            }
            guard AXLocalePolicy.keyCommandsWindowTitle.matches(title, mode: .contains) else {
                continue
            }
            let document: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                window,
                kAXDocumentAttribute,
                runtime: runtime.ax
            )
            switch document {
            case .success(nil):
                candidates.append(window)
            case .failure(let error) where error.isDefinitiveAbsence:
                candidates.append(window)
            case .success:
                continue
            case .failure:
                return .undetermined
            }
        }
        return .observed(.init(
            allWindowIDs: Set(windows.map(elementID)),
            candidates: candidates
        ))
    }

    private static func openedWindow(
        after baseline: WindowCensus,
        runtime: Runtime,
        deadline: Double = 4.0
    ) -> OpenedWindowResult {
        let step = 0.2
        var elapsed = 0.0
        while elapsed <= deadline {
            switch keyCommandsWindowCensus(runtime: runtime) {
            case .undetermined:
                return .failed(stage: "key_commands_window_unreadable")
            case .observed(let census):
                if census.candidates.count > 1 {
                    return .failed(stage: "key_commands_window_ambiguous")
                }
                if let candidate = census.candidates.first {
                    guard !baseline.allWindowIDs.contains(elementID(candidate)) else {
                        return .failed(stage: "key_commands_window_identity_mismatch")
                    }
                    return .found(candidate)
                }
            }
            if runtime.isCancelled() || !runtime.ownsGate() {
                return .failed(stage: "ownership_lost")
            }
            runtime.sleep(step)
            elapsed += step
        }
        return .failed(stage: "open_key_commands")
    }

    private static func searchField(in root: AXUIElement, runtime: Runtime) -> AXUIElement? {
        var queue = [root]
        var cursor = 0
        var visited = Set<Int>()
        while cursor < queue.count, visited.count < 6_000 {
            let element = queue[cursor]
            cursor += 1
            let id = Int(bitPattern: Unmanaged.passUnretained(element).toOpaque())
            guard visited.insert(id).inserted else { continue }
            let role = AXHelpers.getRole(element, runtime: runtime.ax)
            let subrole: String? = AXHelpers.getAttribute(
                element,
                kAXSubroleAttribute,
                runtime: runtime.ax
            )
            if role == "AXSearchField" || subrole == (kAXSearchFieldSubrole as String) {
                return element
            }
            switch AXHelpers.childrenResult(element, runtime: runtime.ax) {
            case .success(let children): queue.append(contentsOf: children)
            case .failure(let error) where error.isDefinitiveAbsence: break
            case .failure: return nil
            }
        }
        return nil
    }

    private static func focused(_ element: AXUIElement, runtime: Runtime) -> Bool? {
        let value: NSNumber? = AXHelpers.getAttribute(
            element,
            kAXFocusedAttribute,
            runtime: runtime.ax
        )
        return value.map { $0.intValue != 0 }
    }

    private static func close(window: AXUIElement, runtime: Runtime) -> Bool {
        func gone() -> Bool {
            guard case .observed(let census) = keyCommandsWindowCensus(runtime: runtime) else {
                return false
            }
            return !census.candidates.contains { CFEqual($0, window) }
        }
        if gone() { return true }
        guard let button: AXUIElement = AXHelpers.getAttribute(
            window,
            "AXCloseButton",
            runtime: runtime.ax
        ) else { return false }
        _ = AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax)
        return poll(runtime: runtime, deadline: 2.0, { gone() ? true : nil }) != nil
    }

    private static func poll<T>(
        runtime: Runtime,
        deadline: Double,
        _ probe: () -> T?
    ) -> T? {
        let step = 0.2
        var elapsed = 0.0
        while elapsed <= deadline {
            if let value = probe() { return value }
            if runtime.isCancelled() || !runtime.ownsGate() { return nil }
            runtime.sleep(step)
            elapsed += step
        }
        return nil
    }

    private static func elementID(_ element: AXUIElement) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(element).toOpaque())
    }
}
