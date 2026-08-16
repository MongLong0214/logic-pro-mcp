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
        /// Enumerates the actions an element advertises without attempting one.
        let actionNames: @Sendable (AXUIElement) -> [String]
        /// Injectable status-preserving action-name seam. `nil` falls back to the ordinary
        /// action reader, whose historical empty result has no status information.
        let actionNamesResult: (@Sendable (AXUIElement) -> Result<[String], AXStatusError>)?
        /// Injectable typed-children seam. `nil` means "use the production read".
        let childrenResult: (@Sendable (AXUIElement) -> Result<[AXUIElement], AXStatusError>)?
        /// Injectable status-preserving attribute seam. `nil` falls back to the ordinary
        /// attribute reader, whose historical `nil` result has no status information.
        let attributeValueResult: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXStatusError>)?
        /// Injectable status-preserving action seam. `nil` retains the historical
        /// Boolean action seam for existing test runtimes that cannot report an
        /// AXError status.
        let performActionResult: (@Sendable (AXUIElement, String) -> Result<Void, AXStatusError>)?

        /// Explicit memberwise initializer, replacing the compiler-synthesized one so
        /// `childrenResult` can default to `nil`. Every existing construction that omits
        /// it continues to compile unchanged.
        init(
            axApp: @escaping @Sendable (pid_t) -> AXUIElement,
            attributeValue: @escaping @Sendable (AXUIElement, String) -> AnyObject?,
            setAttributeValue: @escaping @Sendable (AXUIElement, String, CFTypeRef) -> Bool,
            children: @escaping @Sendable (AXUIElement) -> [AXUIElement],
            performAction: @escaping @Sendable (AXUIElement, String) -> Bool,
            childCount: @escaping @Sendable (AXUIElement) -> Int?,
            actionNames: @escaping @Sendable (AXUIElement) -> [String] = { _ in [] },
            actionNamesResult: (@Sendable (AXUIElement) -> Result<[String], AXStatusError>)? = nil,
            childrenResult: (@Sendable (AXUIElement) -> Result<[AXUIElement], AXStatusError>)? = nil,
            attributeValueResult: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXStatusError>)? = nil,
            performActionResult: (@Sendable (AXUIElement, String) -> Result<Void, AXStatusError>)? = nil
        ) {
            self.axApp = axApp
            self.attributeValue = attributeValue
            self.setAttributeValue = setAttributeValue
            self.children = children
            self.performAction = performAction
            self.childCount = childCount
            self.actionNames = actionNames
            self.actionNamesResult = actionNamesResult
            self.childrenResult = childrenResult
            self.attributeValueResult = attributeValueResult
            self.performActionResult = performActionResult
        }

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
                return AXHelpers.decodeChildrenArray(value)
            },
            performAction: { element, action in
                AXUIElementPerformAction(element, action as CFString) == .success
            },
            childCount: { element in
                var count: CFIndex = 0
                let result = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
                guard result == .success else { return nil }
                return count
            },
            actionNames: { element in
                var names: CFArray?
                guard AXUIElementCopyActionNames(element, &names) == .success,
                      let names,
                      let actions = names as? [String] else {
                    return []
                }
                return actions
            },
            actionNamesResult: { element in
                var names: CFArray?
                let status = AXUIElementCopyActionNames(element, &names)
                guard status == .success else {
                    return .failure(AXStatusError(raw: status.rawValue))
                }
                guard let names, let actions = names as? [String] else {
                    return .success([])
                }
                return .success(actions)
            },
            attributeValueResult: { element, attribute in
                var value: AnyObject?
                let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                guard status == .success else {
                    return .failure(AXStatusError(raw: status.rawValue))
                }
                return .success(value)
            },
            performActionResult: { element, action in
                let status = AXUIElementPerformAction(element, action as CFString)
                guard status == .success else {
                    return .failure(AXStatusError(raw: status.rawValue))
                }
                return .success(())
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

    /// Get a typed attribute value without collapsing an AX read failure into `nil`.
    ///
    /// The optional success value still represents an absent or mismatched value. Callers that
    /// need to distinguish a failed observation from an empty value can inspect the `Result`.
    /// Runtimes built before this seam was introduced retain their ordinary best-effort behavior.
    static func getAttributeResult<T>(
        _ element: AXUIElement,
        _ attribute: String,
        runtime: Runtime = .production
    ) -> Result<T?, AXStatusError> {
        if let read = runtime.attributeValueResult {
            // Cast only a value that is actually there. Casting `Optional.none` to `AnyObject`
            // bridges it to NSNull, so an absent attribute would come back as a present-but-
            // malformed value — and a reader that fails closed on malformed values would report a
            // blocking sheet on a window that has none.
            return read(element, attribute).map { value in
                guard let value else { return nil }
                return value as? T
            }
        }
        return .success(runtime.attributeValue(element, attribute).flatMap { $0 as? T })
    }

    /// The raw shape of an AX attribute that vends a collection of UI elements.
    ///
    /// `AXWindows` is a Core Foundation array at the AX boundary. Asking the
    /// generic typed helper for `[AXUIElement]` makes a second Swift-bridging
    /// assertion after the AX API has already returned a successful CFArray.
    /// Keep that representation boundary explicit for safety-critical scans:
    /// an absent payload, a non-array payload, and a decodable element list are
    /// three different observations.
    enum AXUIElementArrayRead {
        case elements([AXUIElement])
        case absent
        case malformed
    }

    /// Read a CFArray-backed AX attribute without requiring Swift to bridge it
    /// through `as? [AXUIElement]`. This deliberately reads the raw optional
    /// first, so the `Optional.none as AnyObject == NSNull` trap cannot turn an
    /// absent attribute into a present malformed value.
    static func getAXUIElementArrayRead(
        _ element: AXUIElement,
        _ attribute: String,
        runtime: Runtime = .production
    ) -> Result<AXUIElementArrayRead, AXStatusError> {
        let raw: Result<AnyObject?, AXStatusError>
        if let read = runtime.attributeValueResult {
            raw = read(element, attribute)
        } else {
            raw = .success(runtime.attributeValue(element, attribute))
        }
        return raw.map { value in
            guard let value else { return .absent }
            guard CFGetTypeID(value) == CFArrayGetTypeID() else { return .malformed }
            return .elements(decodeChildrenArray(value))
        }
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

    /// Typed AX read failure. `raw` carries an `AXError` only when `source` is
    /// `.axStatus`; callers that serialize diagnostics use `diagnosticLabel` so
    /// malformed values are never presented as invented AX status codes.
    struct AXStatusError: Error, Sendable, Equatable {
        enum Source: Sendable, Equatable {
            case axStatus
            case malformedChildren
            case malformedAttribute
        }

        let raw: Int32
        let source: Source

        init(raw: Int32) {
            self.raw = raw
            self.source = .axStatus
        }

        private init(raw: Int32, source: Source) {
            self.raw = raw
            self.source = source
        }

        /// A successful `AXChildren` read with a non-array payload did not
        /// establish that the element has no children. The private sentinel keeps
        /// existing raw-status call sites source-compatible; diagnostics expose
        /// `malformed_children`, never the sentinel value.
        static let malformedChildren = AXStatusError(
            raw: Int32.min,
            source: .malformedChildren
        )

        /// A successful attribute read whose value cannot establish the typed
        /// fact the caller needs. This is deliberately distinct from an AX
        /// status: a malformed `AXModal` payload has not said "false".
        static let malformedAttribute = AXStatusError(
            raw: Int32.min + 1,
            source: .malformedAttribute
        )

        var diagnosticLabel: String {
            switch source {
            case .axStatus: return "\(raw)"
            case .malformedChildren: return "malformed_children"
            case .malformedAttribute: return "malformed_attribute"
            }
        }

        /// Two AX statuses are ANSWERS, not failures. `attributeUnsupported` (-25205) means the
        /// element does not vend that attribute at all, and `noValue` (-25212) means it has none —
        /// which is exactly what a childless node or a table without `AXRows` reports. Measured on
        /// Logic 12.3, treating either as a failed read makes a status-preserving traversal answer
        /// "unreadable" for a tree it can plainly see, because a real AX tree is full of both.
        /// Everything else — cannot-complete, invalid element, API disabled — really is a failure.
        ///
        /// This lives here, on the status itself, because the distinction was independently
        /// rediscovered in two channels and got it wrong the second time.
        var isDefinitiveAbsence: Bool {
            raw == AXError.attributeUnsupported.rawValue || raw == AXError.noValue.rawValue
        }

        /// AX can return any of these while Logic is rebuilding an otherwise still-bound
        /// element tree. A post-write settle poll must discard the entire observation and try a
        /// fresh one within its existing budget. `failure` (-25200) is a failed read, not an
        /// answer of absence: it retires that poll, not the operation. This deliberately
        /// excludes `apiDisabled`: that reports a disabled accessibility API, not a short-lived
        /// rebuild state, so retrying it would only obscure the real failure.
        var isTransientDuringRebuild: Bool {
            raw == AXError.failure.rawValue
                || raw == AXError.cannotComplete.rawValue
                || raw == AXError.invalidUIElement.rawValue
        }

        /// The spelling of an AXError constant, when `raw` is one of Apple's defined values.
        /// Keep the raw number alongside this label at an exposure boundary: the number is the
        /// actual status returned by AX, while the label makes a live receipt actionable without
        /// asking the caller to reverse-map the code.
        var symbolicName: String? {
            switch raw {
            case AXError.success.rawValue: return "success"
            case AXError.failure.rawValue: return "failure"
            case AXError.illegalArgument.rawValue: return "illegalArgument"
            case AXError.invalidUIElement.rawValue: return "invalidUIElement"
            case AXError.invalidUIElementObserver.rawValue: return "invalidUIElementObserver"
            case AXError.cannotComplete.rawValue: return "cannotComplete"
            case AXError.attributeUnsupported.rawValue: return "attributeUnsupported"
            case AXError.actionUnsupported.rawValue: return "actionUnsupported"
            case AXError.notificationUnsupported.rawValue: return "notificationUnsupported"
            case AXError.notImplemented.rawValue: return "notImplemented"
            case AXError.notificationAlreadyRegistered.rawValue: return "notificationAlreadyRegistered"
            case AXError.notificationNotRegistered.rawValue: return "notificationNotRegistered"
            case AXError.apiDisabled.rawValue: return "apiDisabled"
            case AXError.noValue.rawValue: return "noValue"
            case AXError.parameterizedAttributeUnsupported.rawValue:
                return "parameterizedAttributeUnsupported"
            case AXError.notEnoughPrecision.rawValue: return "notEnoughPrecision"
            default: return nil
            }
        }
    }

    /// Why a direct AX action was not accepted. Production preserves the raw
    /// AXError; older Boolean-only test seams honestly report that no status was
    /// available instead of inventing one.
    enum AXActionError: Error, Sendable, Equatable {
        case status(AXStatusError)
        case statusUnavailable

        var diagnosticLabel: String {
            switch self {
            case .status(let error): return "ax_\(error.diagnosticLabel)"
            case .statusUnavailable: return "status_unavailable"
            }
        }

    }

    /// Pure projection of an AX read outcome into a typed result.
    ///
    /// Nothing is fabricated in either direction: a non-success status keeps its own raw
    /// value rather than collapsing to a single code, and a successful read never invents
    /// a status. An absent children value (`nil`) is an empty success. A malformed
    /// non-`CFArray` value is *not* empty: it is an unreadable tree, because callers
    /// that prove absence must not treat an undecodable subtree as visited.
    static func projectChildrenStatus(
        _ status: AXError,
        _ value: AnyObject?
    ) -> Result<[AXUIElement], AXStatusError> {
        guard status == .success else {
            return .failure(AXStatusError(raw: status.rawValue))
        }
        guard let value else { return .success([]) }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else {
            return .failure(.malformedChildren)
        }
        return .success(decodeChildrenArray(value))
    }

    /// Read an element's children, preserving a non-success AX status as a typed error
    /// instead of flattening it to an empty array the way `getChildren` does.
    static func childrenResult(
        _ element: AXUIElement,
        runtime: Runtime = .production
    ) -> Result<[AXUIElement], AXStatusError> {
        if let injected = runtime.childrenResult {
            return injected(element)
        }
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return projectChildrenStatus(status, value)
    }

    /// Decode a raw `kAXChildrenAttribute` value into `[AXUIElement]`, guarding
    /// the `CFArray` downcast (H-6 parity with getPosition/getSize). A malformed
    /// or mocked children attribute that is NOT a CFArray would make
    /// `unsafeDowncast` undefined behavior (process crash); this returns an empty
    /// list instead. Extracted from the production `children` closure so the
    /// guard is unit-testable without a live AX element.
    static func decodeChildrenArray(_ value: AnyObject) -> [AXUIElement] {
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let children = unsafeDowncast(value, to: CFArray.self)
        var collected: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(children) {
            let ptr = CFArrayGetValueAtIndex(children, i)
            let child = unsafeBitCast(ptr, to: AXUIElement.self)
            collected.append(child)
        }
        return collected
    }

    /// Perform a named action on an AX element (e.g. kAXPressAction).
    /// Returns true on success.
    @discardableResult
    static func performAction(_ element: AXUIElement, _ action: String, runtime: Runtime = .production) -> Bool {
        runtime.performAction(element, action)
    }

    /// Perform a named action without discarding the AXError reported by the
    /// production API. This is deliberately separate from the legacy Boolean
    /// wrapper so existing callers retain their behavior while safety-critical
    /// reconciliation can surface element-staleness diagnostics.
    static func performActionResult(
        _ element: AXUIElement,
        _ action: String,
        runtime: Runtime = .production
    ) -> Result<Void, AXActionError> {
        if let perform = runtime.performActionResult {
            return perform(element, action).mapError(AXActionError.status)
        }
        return runtime.performAction(element, action)
            ? .success(())
            : .failure(.statusUnavailable)
    }

    /// Enumerate the named actions that an element currently advertises.
    static func getActionNames(_ element: AXUIElement, runtime: Runtime = .production) -> [String] {
        runtime.actionNames(element)
    }

    /// Enumerate action names without flattening an AX read failure into an empty action list.
    static func getActionNamesResult(
        _ element: AXUIElement,
        runtime: Runtime = .production
    ) -> Result<[String], AXStatusError> {
        if let read = runtime.actionNamesResult {
            return read(element)
        }
        return .success(runtime.actionNames(element))
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
    /// H-6 (2026-05-08 enterprise review): pre-fix this used `as! AXValue`
    /// without a `CFGetTypeID` guard, so a malformed or mocked attribute
    /// could crash the process instead of returning nil. Now matches the
    /// guarded pattern already used by `LibraryAccessor`, `PluginInspector`,
    /// and `AXLogicProElements`.
    static func getPosition(_ element: AXUIElement, runtime: Runtime = .production) -> CGPoint? {
        guard let raw = runtime.attributeValue(element, kAXPositionAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast — guarded by CFGetTypeID above.
        let v = raw as! AXValue
        var pt = CGPoint.zero
        guard AXValueGetValue(v, .cgPoint, &pt) else { return nil }
        return pt
    }

    /// Get element screen size (kAXSizeAttribute) as CGSize.
    /// H-6: same `CFGetTypeID` guard as `getPosition`.
    static func getSize(_ element: AXUIElement, runtime: Runtime = .production) -> CGSize? {
        guard let raw = runtime.attributeValue(element, kAXSizeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast — guarded by CFGetTypeID above.
        let v = raw as! AXValue
        var sz = CGSize.zero
        guard AXValueGetValue(v, .cgSize, &sz) else { return nil }
        return sz
    }

    /// H2 (P2-5) — decode a CGPoint from an already-fetched raw AX attribute
    /// value (e.g. from `AXUIElementCopyAttributeValue`). Verifies BOTH that it
    /// is an AXValue AND that the `.cgPoint` extraction succeeds, returning nil
    /// (fail-closed) on a non-AXValue or a wrong-subtype AXValue (e.g. a
    /// `.cgRect` AXValue). Originally hoisted the `AXValueGetValue` Bool check
    /// out of coordinate-click call sites that ignored it and would fall back
    /// to a (0,0) misclick on drift; those callers have since been removed by
    /// the coordinate-free campaign, and the remaining consumers use this for
    /// fail-closed position READS.
    static func point(fromRawAttribute raw: AnyObject?) -> CGPoint? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast — guarded by CFGetTypeID above.
        var pt = CGPoint.zero
        guard AXValueGetValue((raw as! AXValue), .cgPoint, &pt) else { return nil }
        return pt
    }

    /// H2 (P2-5) — CGSize counterpart of `point(fromRawAttribute:)`.
    static func size(fromRawAttribute raw: AnyObject?) -> CGSize? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast — guarded by CFGetTypeID above.
        var sz = CGSize.zero
        guard AXValueGetValue((raw as! AXValue), .cgSize, &sz) else { return nil }
        return sz
    }
}
