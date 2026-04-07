@preconcurrency import ApplicationServices
import Foundation
@testable import LogicProMCP

final class FakeAXRuntimeBuilder: @unchecked Sendable {
    private var elements: [Int: AXUIElement] = [:]
    private var attributes: [Int: [String: Any]] = [:]
    private var children: [Int: [AXUIElement]] = [:]
    private(set) var setCalls: [(elementID: Int, attribute: String)] = []
    private(set) var actionCalls: [(elementID: Int, action: String)] = []

    func element(_ id: Int) -> AXUIElement {
        if let element = elements[id] {
            return element
        }

        let element = AXUIElementCreateApplication(pid_t(id + 1000))
        elements[id] = element
        return element
    }

    func setAttribute(_ element: AXUIElement, _ attribute: String, _ value: Any) {
        attributes[key(for: element), default: [:]][attribute] = value
    }

    func setChildren(_ element: AXUIElement, _ value: [AXUIElement]) {
        children[key(for: element)] = value
    }

    func attributeValue(_ element: AXUIElement, _ attribute: String) -> Any? {
        attributes[key(for: element)]?[attribute]
    }

    func elementID(_ element: AXUIElement) -> Int {
        key(for: element)
    }

    func makeAXRuntime(appElement: AXUIElement? = nil) -> AXHelpers.Runtime {
        makeAXRuntime(appElement: appElement, setAttributeHandler: nil, performActionHandler: nil)
    }

    func makeAXRuntime(
        appElement: AXUIElement? = nil,
        setAttributeHandler: (@Sendable (AXUIElement, String, CFTypeRef) -> Bool)?,
        performActionHandler: (@Sendable (AXUIElement, String) -> Bool)?
    ) -> AXHelpers.Runtime {
        AXHelpers.Runtime(
            axApp: { [self] _ in
                appElement ?? element(0)
            },
            attributeValue: { [self] element, attribute in
                bridge(attributes[key(for: element)]?[attribute])
            },
            setAttributeValue: { [self] element, attribute, value in
                if let setAttributeHandler {
                    return setAttributeHandler(element, attribute, value)
                }
                setCalls.append((key(for: element), attribute))
                attributes[key(for: element), default: [:]][attribute] = value
                return true
            },
            children: { [self] element in
                children[key(for: element)] ?? []
            },
            performAction: { [self] element, action in
                if let performActionHandler {
                    return performActionHandler(element, action)
                }
                actionCalls.append((key(for: element), action))
                return true
            },
            childCount: { [self] element in
                children[key(for: element)]?.count
            }
        )
    }

    func makeLogicRuntime(pid: pid_t? = 4242, appElement: AXUIElement? = nil) -> AXLogicProElements.Runtime {
        makeLogicRuntime(
            pid: pid,
            appElement: appElement,
            setAttributeHandler: nil,
            performActionHandler: nil
        )
    }

    func makeLogicRuntime(
        pid: pid_t? = 4242,
        appElement: AXUIElement? = nil,
        setAttributeHandler: (@Sendable (AXUIElement, String, CFTypeRef) -> Bool)?,
        performActionHandler: (@Sendable (AXUIElement, String) -> Bool)?
    ) -> AXLogicProElements.Runtime {
        AXLogicProElements.Runtime(
            logicProPID: { pid },
            ax: makeAXRuntime(
                appElement: appElement,
                setAttributeHandler: setAttributeHandler,
                performActionHandler: performActionHandler
            )
        )
    }

    private func key(for element: AXUIElement) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(element).toOpaque())
    }

    private func bridge(_ value: Any?) -> AnyObject? {
        switch value {
        case let value as String:
            return value as NSString
        case let value as Bool:
            return NSNumber(value: value)
        case let value as Int:
            return NSNumber(value: value)
        case let value as Double:
            return NSNumber(value: value)
        case let value as Float:
            return NSNumber(value: value)
        case let value as NSNumber:
            return value
        case let value as AXUIElement:
            return unsafeBitCast(value, to: AnyObject.self)
        case let value as AnyObject:
            return value
        default:
            return nil
        }
    }
}
