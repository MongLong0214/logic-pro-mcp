import ApplicationServices
import Foundation

/// Low-level wrappers around the macOS Accessibility (AX) API.
/// All functions are synchronous; they block briefly while the AX subsystem responds.
enum AXHelpers {
    struct Runtime: @unchecked Sendable {
        let axApp: @Sendable (pid_t) -> AXUIElement
        let attributeValue: @Sendable (AXUIElement, String) -> AnyObject?
        let setAttributeValue: @Sendable (AXUIElement, String, CFTypeRef) -> Bool
        let children: @Sendable (AXUIElement) -> [AXUIElement]
        let performAction: @Sendable (AXUIElement, String) -> Bool
        let childCount: @Sendable (AXUIElement) -> Int?

        static let production = Runtime(
            axApp: { pid in
                let element = AXUIElementCreateApplication(pid)
                // Cap per-message AX wait. Default (~6s) stacks across multi-step
                // ops (rename = find+press+set+confirm = 4 messages); under matrix
                // load that exceeded the client's 15s tools/call timeout and
                // stalled the stdio loop. 2.5s/msg keeps worst-case ~10s.
                AXUIElementSetMessagingTimeout(element, 2.5)
                return element
            },
            attributeValue: { element, attribute in
                var value: AnyObject?
                let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                guard result == .success else { return nil }
                return value
            },
            setAttributeValue: { element, attribute, value in
                AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
            },
            children: { element in
                var value: AnyObject?
                let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                guard status == .success, let value else {
                    return []
                }
                let children = unsafeDowncast(value, to: CFArray.self)

                var collected: [AXUIElement] = []
                for i in 0..<CFArrayGetCount(children) {
                    let ptr = CFArrayGetValueAtIndex(children, i)
                    let child = unsafeBitCast(ptr, to: AXUIElement.self)
                    collected.append(child)
                }
                return collected
            },
            performAction: { element, action in
                AXUIElementPerformAction(element, action as CFString) == .success
            },
            childCount: { element in
                var count: CFIndex = 0
                let result = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
                guard result == .success else { return nil }
                return count
            }
        )
    }

    /// Create an AXUIElement reference for a running application by PID.
    static func axApp(pid: pid_t, runtime: Runtime = .production) -> AXUIElement {
        runtime.axApp(pid)
    }

    /// Get a typed attribute value from an AX element.
    /// Returns nil on any error (element gone, attribute missing, type mismatch).
    static func getAttribute<T>(_ element: AXUIElement, _ attribute: String, runtime: Runtime = .production) -> T? {
        runtime.attributeValue(element, attribute) as? T
    }

    /// Set an attribute value on an AX element.
    /// Returns true on success, false on error.
    @discardableResult
    static func setAttribute(
        _ element: AXUIElement,
        _ attribute: String,
        _ value: CFTypeRef,
        runtime: Runtime = .production
    ) -> Bool {
        runtime.setAttributeValue(element, attribute, value)
    }

    /// Get the children of an AX element.
    static func getChildren(_ element: AXUIElement, runtime: Runtime = .production) -> [AXUIElement] {
        runtime.children(element)
    }

    /// Perform a named action on an AX element (e.g. kAXPressAction).
    /// Returns true on success.
    @discardableResult
    static func performAction(_ element: AXUIElement, _ action: String, runtime: Runtime = .production) -> Bool {
        runtime.performAction(element, action)
    }

    /// Get the role string of an element (e.g. "AXButton", "AXSlider").
    static func getRole(_ element: AXUIElement, runtime: Runtime = .production) -> String? {
        getAttribute(element, kAXRoleAttribute, runtime: runtime)
    }

    /// Get the title of an element.
    static func getTitle(_ element: AXUIElement, runtime: Runtime = .production) -> String? {
        getAttribute(element, kAXTitleAttribute, runtime: runtime)
    }

    /// Get the identifier of an element.
    static func getIdentifier(_ element: AXUIElement, runtime: Runtime = .production) -> String? {
        getAttribute(element, kAXIdentifierAttribute, runtime: runtime)
    }

    /// Find a child element matching optional criteria.
    /// Searches direct children only (not recursive) for performance.
    static func findChild(
        of element: AXUIElement,
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        let children = getChildren(element, runtime: runtime)
        for child in children {
            if let role, getRole(child, runtime: runtime) != role { continue }
            if let title, getTitle(child, runtime: runtime) != title { continue }
            if let identifier, getIdentifier(child, runtime: runtime) != identifier { continue }
            return child
        }
        return nil
    }

    /// Recursive version of findChild. Searches the entire subtree via DFS.
    /// Use sparingly — deep trees can be slow.
    static func findDescendant(
        of element: AXUIElement,
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        maxDepth: Int = 10,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }
        let children = getChildren(element, runtime: runtime)
        for child in children {
            let roleMatch = role == nil || getRole(child, runtime: runtime) == role
            let titleMatch = title == nil || getTitle(child, runtime: runtime) == title
            let idMatch = identifier == nil || getIdentifier(child, runtime: runtime) == identifier
            if roleMatch && titleMatch && idMatch {
                return child
            }
            if let found = findDescendant(
                of: child, role: role, title: title, identifier: identifier,
                maxDepth: maxDepth - 1, runtime: runtime
            ) {
                return found
            }
        }
        return nil
    }

    /// Collect all descendants matching criteria. Useful for enumerating track headers, etc.
    static func findAllDescendants(
        of element: AXUIElement,
        role: String? = nil,
        maxDepth: Int = 5,
        runtime: Runtime = .production
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        collectDescendants(of: element, role: role, maxDepth: maxDepth, runtime: runtime, into: &results)
        return results
    }

    private static func collectDescendants(
        of element: AXUIElement,
        role: String?,
        maxDepth: Int,
        runtime: Runtime,
        into results: inout [AXUIElement]
    ) {
        guard maxDepth > 0 else { return }
        let children = getChildren(element, runtime: runtime)
        for child in children {
            if role == nil || getRole(child, runtime: runtime) == role {
                results.append(child)
            }
            collectDescendants(of: child, role: role, maxDepth: maxDepth - 1, runtime: runtime, into: &results)
        }
    }

    /// Get the number of children without allocating the full array.
    static func getChildCount(_ element: AXUIElement, runtime: Runtime = .production) -> Int? {
        runtime.childCount(element)
    }

    /// Get the value of an element (kAXValueAttribute).
    static func getValue(_ element: AXUIElement, runtime: Runtime = .production) -> AnyObject? {
        runtime.attributeValue(element, kAXValueAttribute)
    }

    /// Get the description of an element (kAXDescriptionAttribute).
    static func getDescription(_ element: AXUIElement, runtime: Runtime = .production) -> String? {
        getAttribute(element, kAXDescriptionAttribute, runtime: runtime)
    }

    /// Get the help/tooltip text of an element (kAXHelpAttribute).
    static func getHelp(_ element: AXUIElement, runtime: Runtime = .production) -> String? {
        getAttribute(element, kAXHelpAttribute, runtime: runtime)
    }

    /// Get element screen position (kAXPositionAttribute) as CGPoint.
    static func getPosition(_ element: AXUIElement, runtime: Runtime = .production) -> CGPoint? {
        guard let raw = runtime.attributeValue(element, kAXPositionAttribute) else { return nil }
        // swiftlint:disable:next force_cast — AXValue bridging is well-defined for position attrs.
        let v = raw as! AXValue
        var pt = CGPoint.zero
        guard AXValueGetValue(v, .cgPoint, &pt) else { return nil }
        return pt
    }

    /// Get element screen size (kAXSizeAttribute) as CGSize.
    static func getSize(_ element: AXUIElement, runtime: Runtime = .production) -> CGSize? {
        guard let raw = runtime.attributeValue(element, kAXSizeAttribute) else { return nil }
        // swiftlint:disable:next force_cast
        let v = raw as! AXValue
        var sz = CGSize.zero
        guard AXValueGetValue(v, .cgSize, &sz) else { return nil }
        return sz
    }
}
