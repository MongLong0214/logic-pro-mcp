@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Status-preserving, read-only adapter from Logic's already-filtered Key Commands
/// AX tree into the pure exact-row resolver. Opening the window, typing the filter,
/// selecting a command, and pressing Learn remain outside this type.
enum MIDIKeyCommandAXSurface {
    enum Outcome {
        case resolved(
            command: AXUIElement,
            assignment: AXUIElement,
            observation: MIDIKeyCommandBindingObservation
        )
        case refused(MIDIKeyCommandSurfaceResolver.Resolution)
        case unreadableSurface
        case scanIncomplete

        var isUnreadableSurface: Bool {
            if case .unreadableSurface = self { return true }
            return false
        }

        var isScanIncomplete: Bool {
            if case .scanIncomplete = self { return true }
            return false
        }
    }

    static func read(
        in root: AXUIElement,
        entry: MIDIKeyCommandBindingCatalog.Entry,
        labels: MIDIKeyCommandSurfaceResolver.Labels,
        runtime: AXHelpers.Runtime = .production,
        maxNodes: Int = 6_000
    ) -> Outcome {
        guard maxNodes > 0 else { return .scanIncomplete }

        var queue = [root]
        var cursor = 0
        var visited = Set<Int>()
        var elementsByID: [Int: AXUIElement] = [:]
        var cells: [MIDIKeyCommandSurfaceResolver.Cell] = []

        while cursor < queue.count, visited.count < maxNodes {
            let element = queue[cursor]
            cursor += 1
            let id = elementID(element)
            guard visited.insert(id).inserted else { continue }
            elementsByID[id] = element

            guard let role = readRequiredRole(element, runtime: runtime) else {
                return .unreadableSurface
            }
            let cellRole: MIDIKeyCommandSurfaceResolver.Cell.Role
            if role == "AXSearchField" {
                cellRole = .searchField
            } else if role == (kAXTextFieldRole as String) {
                let subrole = readOptionalString(
                    element,
                    attribute: kAXSubroleAttribute as String,
                    runtime: runtime
                )
                guard subrole != .unreadable else { return .unreadableSurface }
                cellRole = subrole == .value(kAXSearchFieldSubrole as String)
                    ? .searchField
                    : .textField
            } else if role == (kAXStaticTextRole as String) {
                cellRole = .staticText
            } else {
                cellRole = .other
            }

            var text: String?
            var frame: CGRect?
            switch cellRole {
            case .searchField, .textField, .staticText:
                guard let observedText = readText(element, runtime: runtime) else {
                    return .unreadableSurface
                }
                text = observedText
                if cellRole != .searchField {
                    guard let observedFrame = readFrame(element, runtime: runtime) else {
                        return .unreadableSurface
                    }
                    frame = observedFrame
                }
            case .other:
                break
            }

            cells.append(.init(id: id, role: cellRole, text: text, frame: frame))

            switch AXHelpers.childrenResult(element, runtime: runtime) {
            case .success(let children):
                queue.append(contentsOf: children)
            case .failure(let error) where error.isDefinitiveAbsence:
                break
            case .failure:
                return .unreadableSurface
            }
        }

        guard cursor == queue.count else { return .scanIncomplete }

        let resolution = MIDIKeyCommandSurfaceResolver.resolve(
            entry: entry,
            labels: labels,
            cells: cells
        )
        guard case .resolved(let commandID, let assignmentID, let observation) = resolution else {
            return .refused(resolution)
        }
        guard let command = elementsByID[commandID],
              let assignment = elementsByID[assignmentID] else { return .unreadableSurface }
        return .resolved(command: command, assignment: assignment, observation: observation)
    }

    private enum OptionalStringRead: Equatable {
        case value(String?)
        case unreadable
    }

    private static func readRequiredRole(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        switch readOptionalString(
            element,
            attribute: kAXRoleAttribute as String,
            runtime: runtime
        ) {
        case .value(let role): return role
        case .unreadable: return nil
        }
    }

    /// A nil return means the observation itself failed. `.some(nil)` means both
    /// string attributes were read successfully and the element carries no text.
    private static func readText(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String?? {
        let value = readOptionalString(
            element,
            attribute: kAXValueAttribute as String,
            runtime: runtime
        )
        let title = readOptionalString(
            element,
            attribute: kAXTitleAttribute as String,
            runtime: runtime
        )
        guard case .value(let valueText) = value,
              case .value(let titleText) = title else { return nil }
        return .some(valueText ?? titleText)
    }

    private static func readOptionalString(
        _ element: AXUIElement,
        attribute: String,
        runtime: AXHelpers.Runtime
    ) -> OptionalStringRead {
        let read: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            element,
            attribute,
            runtime: runtime
        )
        switch read {
        case .success(nil):
            return .value(nil)
        case .success(let value):
            guard let text = value as? String else { return .unreadable }
            return .value(text)
        case .failure(let error) where error.isDefinitiveAbsence:
            return .value(nil)
        case .failure:
            return .unreadable
        }
    }

    private static func readFrame(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> CGRect? {
        guard let position = AXHelpers.getPosition(element, runtime: runtime),
              let size = AXHelpers.getSize(element, runtime: runtime),
              position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func elementID(_ element: AXUIElement) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(element).toOpaque())
    }
}
