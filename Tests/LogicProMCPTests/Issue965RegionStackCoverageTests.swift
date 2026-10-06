@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#965 region coverage preserves stack visibility uncertainty", .serialized)
struct Issue965RegionStackCoverageTests {
    private enum StackShape: String, CaseIterable, Sendable {
        case collapsed, childrenUnread, childRoleUnread, valueUnread, valueMissing, valueMalformed
    }

    // The same in-viewport rail/content shape as the existing AX-backed region fixture.
    // Missing descendant rows are not supplied: a collapsed stack does not expose them.
    private final class Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let headers: [AXUIElement]
        let disclosure: AXUIElement
        var unreadChildren: AXUIElement?
        var unreadRole: AXUIElement?
        var unreadValue = false

        init(stackRow: Int? = nil, expanded: Bool = false) {
            app = builder.element(1_965_010)
            window = builder.element(1_965_011)
            let rail = builder.element(1_965_012)
            headers = [builder.element(1_965_013), builder.element(1_965_014)]
            let content = builder.element(1_965_015)
            let region = builder.element(1_965_016)
            disclosure = builder.element(1_965_017)

            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setAttribute(app, kAXWindowsAttribute as String, [window])
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXPositionAttribute as String, axPoint(0, 0))
            builder.setAttribute(window, kAXSizeAttribute as String, axSize(1_200, 400))
            builder.setChildren(window, [rail, content])
            builder.setRole(rail, kAXGroupRole as String)
            builder.setAttribute(rail, kAXDescriptionAttribute as String, "Tracks header")
            builder.setChildren(rail, headers)
            for (index, header) in headers.enumerated() {
                builder.setRole(header, kAXLayoutItemRole as String)
                builder.setAttribute(header, kAXPositionAttribute as String, axPoint(0, CGFloat(100 + index * 60)))
                builder.setAttribute(header, kAXSizeAttribute as String, axSize(200, 40))
                builder.setChildren(header, [])
            }
            builder.setRole(disclosure, kAXDisclosureTriangleRole as String)
            builder.setAttribute(disclosure, kAXValueAttribute as String, expanded ? 1 : 0)
            if let stackRow { builder.setChildren(headers[stackRow], [disclosure]) }

            builder.setRole(content, kAXGroupRole as String)
            builder.setAttribute(content, kAXDescriptionAttribute as String, "Tracks contents")
            builder.setChildren(content, [region])
            builder.setRole(region, kAXLayoutItemRole as String)
            builder.setAttribute(region, kAXDescriptionAttribute as String, "Visible MIDI Region")
            builder.setAttribute(region, kAXHelpAttribute as String, "Region starts at 1 bars and ends at 2 bars, MIDI region.")
            builder.setAttribute(region, kAXPositionAttribute as String, axPoint(240, 108))
            builder.setAttribute(region, kAXSizeAttribute as String, axSize(320, 24))
        }

        func runtime() -> AXLogicProElements.Runtime {
            builder.makeLogicRuntime(
                appElement: app,
                attributeValueResultHandler: { [self] element, attribute in
                    if let unreadRole, CFEqual(element, unreadRole), attribute == kAXRoleAttribute as String {
                        return .failure(.init(raw: Int32(AXError.cannotComplete.rawValue)))
                    }
                    if unreadValue, CFEqual(element, disclosure), attribute == kAXValueAttribute as String {
                        return .failure(.init(raw: Int32(AXError.cannotComplete.rawValue)))
                    }
                    return nil
                },
                childrenResultHandler: { [self] element in
                    if let unreadChildren, CFEqual(element, unreadChildren) {
                        return .failure(.init(raw: Int32(AXError.cannotComplete.rawValue)))
                    }
                    return nil
                },
                setAttributeHandler: { _, _, _ in Issue.record("region inventory must not write AX attributes"); return false },
                performActionHandler: { _, _ in Issue.record("region inventory must not perform AX actions"); return false },
                executeAppleScript: { _ in Issue.record("region inventory must not run AppleScript"); return .error("forbidden") })
        }

        func channel() -> AccessibilityChannel {
            return AccessibilityChannel(runtime: .axBacked(
                isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: runtime()))
        }

        func read() async throws -> [String: Any] {
            let result = await channel().execute(operation: "region.get_regions", params: [:])
            #expect(result.isSuccess)
            return try #require(sharedJSONObject(result.message))
        }
    }

    @Test(arguments: StackShape.allCases, [0, 1])
    private func anInViewportStackGapDoesNotCertifyTheWholeArrangement(shape: StackShape, stackRow: Int) async throws {
        let fixture = Fixture(stackRow: stackRow)
        switch shape {
        case .collapsed: break
        case .childrenUnread: fixture.unreadChildren = fixture.headers[stackRow]
        case .childRoleUnread: fixture.unreadRole = fixture.disclosure
        case .valueUnread: fixture.unreadValue = true
        case .valueMissing: fixture.builder.removeAttribute(fixture.disclosure, kAXValueAttribute as String)
        case .valueMalformed: fixture.builder.setAttribute(fixture.disclosure, kAXValueAttribute as String, 0.9)
        }
        let payload = try await fixture.read()
        let complete = try #require(payload["complete"] as? Bool)
        #expect(!complete)
        #expect(payload["scope"] as? String == "visible_arrange_area")
        #expect(payload["returned_count"] as? Int == 1, "keep the independently observed visible region")
        let enumeration = try AccessibilityChannel.enumerateRegionItems(runtime: fixture.runtime()).get()
        #expect(enumeration.trackHeaderCount == 2)
        #expect(enumeration.trackHeadersWithinViewport == 2)
    }

    @Test(arguments: [false, true])
    func supportedFlatAndExpandedControlsKeepTheirConditionalCoverage(expandedStack: Bool) async throws {
        let fixture = Fixture(stackRow: expandedStack ? 0 : nil, expanded: true)
        let payload = try await fixture.read()
        let complete = try #require(payload["complete"] as? Bool)
        #expect(complete)
        #expect(payload["scope"] as? String == "whole_arrangement")
        #expect(payload["returned_count"] as? Int == 1)
    }
}
