@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Issue 301 truthful Channel EQ Controls collection")
struct Issue301ChannelEQControlsCollectionTests {
    private let names = ["Low Cut", "Low Shelf", "Peak 1", "Peak 2", "Peak 3", "Peak 4", "High Shelf", "High Cut"]

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let window: AXUIElement
        let table: AXUIElement
        let runtime: AXHelpers.Runtime
        let rows: [String: AXUIElement]
        let cells: [String: AXUIElement]
        let controls: [String: AXUIElement]
        let inline: [String: AXUIElement]
    }

    private func fixture() -> Fixture {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(100)
        let table = builder.element(101)
        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(table, kAXTableRole as String)
        let bypass = builder.element(102)
        builder.setRole(bypass, kAXCheckBoxRole as String)
        builder.setAttribute(bypass, kAXDescriptionAttribute as String, "bypass")
        builder.setAttribute(bypass, kAXValueAttribute as String, 1)
        var rowList: [AXUIElement] = []
        var rows: [String: AXUIElement] = [:]
        var cells: [String: AXUIElement] = [:]
        var controls: [String: AXUIElement] = [:]
        var inline: [String: AXUIElement] = [:]
        for (index, name) in names.enumerated() {
            let cut = index == 0 || index == 7
            for (field, suffix) in ["On/Off", "Frequency", cut ? "Slope" : "Gain", "Q-Factor"].enumerated() {
                let label = "\(name) \(suffix)"
                let base = 200 + index * 100 + field * 10
                let row = builder.element(base)
                let cell = builder.element(base + 1)
                let text = builder.element(base + 2)
                let control = builder.element(base + 3)
                builder.setRole(row, kAXRowRole as String)
                builder.setRole(cell, kAXCellRole as String)
                builder.setRole(text, kAXStaticTextRole as String)
                builder.setAttribute(text, kAXValueAttribute as String, label + ":")
                let role = suffix == "On/Off" ? kAXCheckBoxRole : suffix == "Slope" ? kAXPopUpButtonRole : kAXSliderRole
                builder.setRole(control, role as String)
                if suffix == "On/Off" {
                    builder.setAttribute(control, kAXValueAttribute as String, index == 7 ? 0 : 1)
                    builder.setChildren(cell, [text, control])
                } else if suffix == "Slope" {
                    builder.setAttribute(control, kAXValueAttribute as String, "24 dB/Oct")
                    builder.setChildren(cell, [text, control])
                } else {
                    builder.setAttribute(control, kAXValueAttribute as String, 240)
                    let container = builder.element(base + 4)
                    let displayControl = builder.element(base + 5)
                    builder.setRole(container, kAXGroupRole as String)
                    builder.setRole(displayControl, kAXSliderRole as String)
                    builder.setAttribute(displayControl, kAXValueAttribute as String, 240)
                    let display = suffix == "Frequency" ? "100 Hz" : suffix == "Gain" ? "0.0 dB" : "1.00"
                    builder.setAttribute(displayControl, kAXValueDescriptionAttribute as String, display)
                    builder.setChildren(container, [displayControl])
                    builder.setChildren(cell, [text, container, control])
                    inline[label] = displayControl
                }
                builder.setChildren(row, [cell])
                rowList.append(row)
                rows[label] = row
                cells[label] = cell
                controls[label] = control
            }
        }
        builder.setChildren(table, rowList)
        builder.setAttribute(table, kAXRowsAttribute as String, rowList)
        builder.setChildren(window, [bypass, table])
        let runtime = builder.makeAXRuntime(
            appElement: builder.element(99),
            setAttributeHandler: { _, _, _ in Issue.record("State collection must never set an AX attribute"); return false },
            performActionHandler: { _, _ in Issue.record("State collection must never actuate a control"); return false }
        )
        return Fixture(builder: builder, window: window, table: table, runtime: runtime,
                       rows: rows, cells: cells, controls: controls, inline: inline)
    }

    private func band(_ result: [String: Any], _ name: String) throws -> [String: Any] {
        let bands = try #require(result["bands"] as? [[String: Any]])
        return try #require(bands.first { $0["name"] as? String == name })
    }

    @Test func eightBandsRetainRawDisplayAndSeparateEnableFromBypass() throws {
        let f = fixture()
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: f.runtime, contextIsCurrent: { true })
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(complete)
        #expect((result["bands"] as? [[String: Any]])?.count == 8)
        let shelf = try band(result, "Low Shelf")
        let frequency = try #require(shelf["frequency"] as? [String: Any])
        #expect(frequency["observed_raw"] as? Double == 240)
        #expect(frequency["observed_display"] as? String == "100 Hz")
        #expect(frequency["raw_unit"] as? String == "raw_ax_value")
        let highCut = try band(result, "High Cut")
        let enabled = try #require(highCut["enabled"] as? [String: Any])
        let highCutEnabled: Bool = try #require(enabled["observed_raw"] as? Bool)
        #expect(!highCutEnabled)
        let slope = try #require(highCut["slope"] as? [String: Any])
        #expect(slope["observed_raw"] as? String == "24 dB/Oct")
        #expect((highCut["gain"] as? [String: Any])?["read_status"] as? String == "not_applicable")
        let pluginEnabled: Bool = try #require((result["plugin_enabled"] as? [String: Any])?["observed_raw"] as? Bool)
        #expect(pluginEnabled)
        let pluginBypassed: Bool = try #require((result["plugin_bypass"] as? [String: Any])?["observed_raw"] as? Bool)
        #expect(!pluginBypassed)
    }

    @Test func duplicatedNamedRowsCannotBecomeCompleteByChoosingFirst() throws {
        let f = fixture()
        var rows = names.flatMap { name in
            ["On/Off", "Frequency", name.hasSuffix("Cut") ? "Slope" : "Gain", "Q-Factor"].compactMap { f.rows["\(name) \($0)"] }
        }
        let duplicate = f.builder.element(2000)
        f.builder.setRole(duplicate, kAXRowRole as String)
        f.builder.setChildren(duplicate, [try #require(f.cells["Peak 1 Frequency"])])
        rows.append(duplicate)
        f.builder.setChildren(f.table, rows)
        f.builder.setAttribute(f.table, kAXRowsAttribute as String, rows)
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: f.runtime, contextIsCurrent: { true })
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(!complete)
        let peak = try band(result, "Peak 1")
        let field = try #require(peak["frequency"] as? [String: Any])
        #expect(field["read_status"] as? String == "ambiguous")
        #expect(field["observed_raw"] is NSNull)
    }

    @Test func disagreeingRedundantSlidersAreUnstableNotGuessed() throws {
        let f = fixture()
        f.builder.setAttribute(try #require(f.inline["Low Shelf Frequency"]), kAXValueAttribute as String, 241)
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: f.runtime, contextIsCurrent: { true })
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(!complete)
        let shelf = try band(result, "Low Shelf")
        let field = try #require(shelf["frequency"] as? [String: Any])
        #expect(field["read_status"] as? String == "unstable")
        #expect(field["observed_raw"] is NSNull)
    }

    @Test func lostCustodyCannotYieldCompleteValues() throws {
        let f = fixture()
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: f.runtime, contextIsCurrent: { false })
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(!complete)
        let reasons = try #require(result["partial_reasons"] as? [String])
        #expect(reasons.contains("context_ended"))
    }

    @Test func missingRequiredHostDisplayKeepsRawButCannotClaimComplete() throws {
        let f = fixture()
        f.builder.removeAttribute(try #require(f.inline["Low Shelf Frequency"]), kAXValueDescriptionAttribute as String)
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: f.runtime, contextIsCurrent: { true })
        let field = try #require(try band(result, "Low Shelf")["frequency"] as? [String: Any])
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(!complete)
        #expect(field["read_status"] as? String == "display_absent")
        #expect(field["observed_raw"] as? Double == 240)
        #expect(field["observed_display"] is NSNull)
        #expect(field["display_read_status"] as? String == "absent")
    }

    @Test func emptyRequiredHostDisplayCannotClaimComplete() throws {
        let f = fixture()
        f.builder.setAttribute(try #require(f.inline["Low Shelf Frequency"]), kAXValueDescriptionAttribute as String, "   ")
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: f.runtime, contextIsCurrent: { true })
        let field = try #require(try band(result, "Low Shelf")["frequency"] as? [String: Any])
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(!complete)
        #expect(field["read_status"] as? String == "display_malformed")
        #expect(field["observed_raw"] as? Double == 240)
        #expect(field["observed_display"] as? String == "   ")
        #expect(field["display_read_status"] as? String == "malformed")
    }

    @Test func booleanSliderRawIsMalformedNotNumericZeroOrOne() throws {
        let f = fixture()
        f.builder.setAttribute(try #require(f.controls["Low Shelf Frequency"]), kAXValueAttribute as String, true)
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: f.runtime, contextIsCurrent: { true })
        let field = try #require(try band(result, "Low Shelf")["frequency"] as? [String: Any])
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(!complete)
        #expect(field["read_status"] as? String == "malformed")
        #expect(field["observed_raw"] is NSNull)
    }

    @Test func unreadableRowsCannotUseReadableChildrenToInventCompleteness() throws {
        let f = fixture()
        let builder = f.builder
        let runtime = builder.makeAXRuntime(
            appElement: builder.element(99),
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, builder.element(101)), attribute == kAXRowsAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            },
            setAttributeHandler: { _, _, _ in Issue.record("No setter during observation"); return false },
            performActionHandler: { _, _ in Issue.record("No control actions during observation"); return false }
        )
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: runtime, contextIsCurrent: { true })
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(!complete)
        let reasons = try #require(result["partial_reasons"] as? [String])
        #expect(!reasons.isEmpty)
        #expect(reasons.allSatisfy { $0.hasSuffix(":unreadable") })
    }

    @Test func replacedInlineControlWithSameValuesCannotPassBookends() throws {
        let f = fixture()
        let builder = f.builder
        let replacement = builder.element(5001)
        let container = builder.element(5000)
        builder.setRole(container, kAXGroupRole as String)
        builder.setRole(replacement, kAXSliderRole as String)
        builder.setAttribute(replacement, kAXValueAttribute as String, 240)
        builder.setAttribute(replacement, kAXValueDescriptionAttribute as String, "100 Hz")
        builder.setChildren(container, [replacement])
        let runtime = builder.makeAXRuntime(
            appElement: builder.element(99),
            attributeValueResultHandler: { element, attribute in
                // Low Shelf Frequency's original inline display is sampled in
                // the first collection. Replace it before the next collection;
                // equal values alone do not establish physical control custody.
                if CFEqual(element, builder.element(315)), attribute == kAXValueDescriptionAttribute as String {
                    builder.setChildren(builder.element(311), [builder.element(312), builder.element(5000), builder.element(313)])
                }
                return nil
            },
            setAttributeHandler: { _, _, _ in Issue.record("No setter during observation"); return false },
            performActionHandler: { _, _ in Issue.record("No control actions during observation"); return false }
        )
        let result = ChannelEQControlsStateReader.collect(in: f.window, runtime: runtime, contextIsCurrent: { true })
        let field = try #require(try band(result, "Low Shelf")["frequency"] as? [String: Any])
        let complete: Bool = try #require(result["complete"] as? Bool)
        #expect(!complete)
        #expect(field["read_status"] as? String == "unstable")
        #expect(field["observed_raw"] is NSNull)
    }
}
