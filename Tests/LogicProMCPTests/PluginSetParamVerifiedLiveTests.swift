@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// T5 — logic_plugins.set_param_verified LIVE write/readback path (R6 steps 6-13)
// for the FIRST verified-writable parameter, Compressor `threshold` (normalized
// %. Deterministic via
// FakeAXRuntimeBuilder + an injected plugin-window opener; no running Logic Pro.
//
// The fixture wires the full AX tree the live path walks:
//   app
//     ├─ AXWindows = [arrangeWindow, pluginWindow]
//   arrangeWindow ── trackHeaders group (AXSelected rows) + mixer (strips/slots)
//   pluginWindow  (title = track name) ── Threshold AXSlider (AXValue + valueDesc)
//
// Coverage:
//   - State A (before 51 → set 60 → after 60, within tolerance)
//   - tolerance edge (within → A, outside → C readback_mismatch + rollback)
//   - window not found → window_open_failed (and opener fallback → A)
//   - slider not found → param_control_not_found
//   - other param (Gain, capability .unsupported) → unsupported_param_readback

private let expectedPath = "/Users/me/Music/AcidWashBass copy.logicx"
private let trackName = "Acid Wash Bass"

// MARK: - Fixture

private enum SliderWriteBehavior: Sendable {
    case direct
    case oneStepTowardRequest
    /// Each AXValue write uses the next readback. `nil` models a lost numeric
    /// AXValue readback after an accepted write.
    case scripted([Double?])
}

private enum ControlsCheckboxWriteBehavior: Sendable, Equatable {
    case toggle
    /// The first requested transition reads back as AX's mixed/indeterminate
    /// state. `NSNumber.boolValue` would incorrectly call this true.
    case mixedAfterPress
    /// AXPress reports status 0/accepted but the checkbox AXValue is inert.
    /// This is the exact observation that prevents a status-only success.
    case statusZeroUnchanged
}

/// A live-path fixture. The slider's AXValueDescription is recomputed from its
/// AXValue on every write so a write updates the readback the way Logic does
/// ("60 %"). `forcedAfterValue` models a sticky/taper mismatch; `otherTracks`
/// pads the header/strip count so a non-zero target track index is realistic.
private final class LiveFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let windowsAddedOnSlotPress: MutableBox<[AXUIElement]>
    let targetOpenControlPressCount: MutableBox<Int>
    let pluginCloseControlPressCount: MutableBox<Int>
    let sliderWriteCount: MutableBox<Int>
    let controlsCheckboxPressCount: MutableBox<Int>
    let controlsViewMenuPressCount: MutableBox<Int>
    let editorViewMenuPressCount: MutableBox<Int>
    let runtime: AXLogicProElements.Runtime

    init(
        track: Int = 0,
        insert: Int = 6,
        trackDisplayName: String = trackName,
        trackSelected: Bool = true,
        thresholdDescription: String = "Threshold",
        pluginSlotName: String = "Compressor",
        beforeValue: Double = 51,
        sliderBeforeReadable: Bool = true,
        pluginWindowPresent: Bool = true,
        openWindowOnSlotPress: Bool = false,
        forcedAfterValue: Double? = nil,
        otherTracks: Int = 0,
        duplicateTrackNameAt: Int? = nil,
        pluginSlotNamesByTrack: [Int: [Int: String]] = [:],
        emptyInsertChain: Bool = false,
        pluginWindowRejectsDirectDemotion: Bool = false,
        slotPressReturnsFalse: Bool = false,
        sliderWriteBehavior: SliderWriteBehavior = .direct,
        rejectSliderWrites: Bool = false,
        sliderDisplayUnit: String = "%",
        sliderUsesSignedPositiveDisplay: Bool = false,
        pluginWindowStaticTextValues: [String]? = nil,
        // An already-visible editor whose title becomes the target track only
        // after the slot press. This models an existing AX element being
        // retargeted by an unrelated UI transition; duplicate acquisition must
        // refuse it because the press did not create a new window element.
        pluginWindowTitleBeforeSlotPress: String? = nil,
        // Model an editor whose close control is pressed but which stays in
        // AXWindows. The close must be judged by the observed window list, not
        // by the press returning true.
        pluginCloseControlFailsToClose: Bool = false,
        controlsViewRowLabel: String? = nil,
        controlsViewControlRole: String = kAXCheckBoxRole as String,
        controlsCheckboxBefore: Bool = false,
        controlsCheckboxWriteBehavior: ControlsCheckboxWriteBehavior = .toggle,
        controlsViewInitiallySelected: Bool = false,
        pluginWindowViewSwitcherDescription: String = "보기",
        viewMenuPressChangesStructure: Bool = true,
        viewMenuPressChangesTitle: Bool = true,
        viewMenuSelectionSetsUnconfirmedStructure: Bool = false,
        viewMenuBecomesUnavailableAfterControlsSelection: Bool = false,
        viewMenuReadFailsAfterFirstSelection: Bool = false,
        controlsTableReadFailsAfterRestoration: Bool = false,
        invalidateTargetSlotAfterViewSelection: Bool = false,
        mutatePluginHeaderAfterViewSelection: Bool = false,
        ambiguousEditorSliderAfterViewSelection: Bool = false,
        viewMenuRevealAfterPolls: Int? = 3,
        viewSettleDelay: TimeInterval = 0.5
    ) {
        let b = builder
        let windowsAddedOnSlotPress = MutableBox<[AXUIElement]>([])
        let targetOpenControlPressCount = MutableBox(0)
        let pluginCloseControlPressCount = MutableBox(0)
        let sliderWriteCount = MutableBox(0)
        let controlsCheckboxPressCount = MutableBox(0)
        let controlsViewMenuPressCount = MutableBox(0)
        let editorViewMenuPressCount = MutableBox(0)
        let app = b.element(1000)
        let arrangeWindow = b.element(1001)
        let headersGroup = b.element(1002)
        let mixer = b.element(1003)
        let pluginWindow = b.element(1004)
        let slider = b.element(1005)
        let pluginClose = b.element(1006)
        let pluginBypass = b.element(1007)
        let pluginLink = b.element(1008)
        let controlsViewSwitcher = b.element(1009)
        let controlsViewMenu = b.element(100_901)
        let controlsViewMenuItem = b.element(100_902)
        let editorViewMenuItem = b.element(100_909)
        let controlsTable = b.element(100_903)
        let controlsRow = b.element(100_904)
        let controlsLabelCell = b.element(100_905)
        let controlsLabel = b.element(100_907)
        let controlsCheckbox = b.element(100_908)
        let controlsHeadingRow = b.element(100_910)
        let controlsHeadingCell = b.element(100_911)
        let controlsHeadingLabel = b.element(100_912)

        // --- Track headers: one row per track, selected-state on the target. ---
        var headerRows: [AXUIElement] = []
        let namedTrackCount = (pluginSlotNamesByTrack.keys.max() ?? -1) + 1
        let rowCount = max(max(track + 1, otherTracks + 1), namedTrackCount)
        for i in 0..<rowCount {
            let row = b.element(1100 + i)
            b.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            // Track name is surfaced via the header's AXDescription (quoted),
            // matching how extractTrackName reads live Logic headers.
            let name = i == track || i == duplicateTrackNameAt ? trackDisplayName : "Other \(i)"
            b.setAttribute(row, kAXDescriptionAttribute as String, "1개의 ‘\(name)’ 트랙")
            b.setAttribute(row, kAXSelectedAttribute as String, (i == track && trackSelected))
            headerRows.append(row)
        }
        b.setAttribute(headersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(headersGroup, kAXDescriptionAttribute as String, "트랙 헤더")
        b.setChildren(headersGroup, headerRows)

        // --- Mixer: one strip per track; target strip carries occupied inserts
        //     up to `insert` so audioPluginInsertSlots reports it occupied. ---
        var strips: [AXUIElement] = []
        var targetSlot: AXUIElement?
        var targetOpenButton: AXUIElement?
        for i in 0..<rowCount {
            let strip = b.element(1200 + i)
            b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            if i == track {
                if emptyInsertChain {
                    // #234 — a Master/VCA-shaped target strip that exposes zero
                    // enumerable insert slots, to exercise the slot-addressing
                    // guard's zero-slot branch.
                    b.setChildren(strip, masterShapedStripChildren(b, base: 1500))
                } else {
                    var slots: [AXUIElement] = []
                    for s in 0...insert {
                        let name = pluginSlotNamesByTrack[i]?[s]
                            ?? (s == insert ? pluginSlotName : "Plugin \(s)")
                        let slot = LiveFixture.occupiedSlot(b, 1300 + s, name: name)
                        if s == insert {
                            targetSlot = slot
                            targetOpenButton = b.element((1300 + s) * 10 + 2)
                        }
                        slots.append(slot)
                    }
                    b.setChildren(strip, slots)
                }
            } else if let namedSlots = pluginSlotNamesByTrack[i],
                      let lastInsert = namedSlots.keys.max() {
                let slots = (0...lastInsert).map { s in
                    LiveFixture.occupiedSlot(
                        b,
                        1400 + (i * 100) + s,
                        name: namedSlots[s] ?? "Plugin \(s)"
                    )
                }
                b.setChildren(strip, slots)
            } else {
                b.setChildren(strip, [LiveFixture.emptySlot(b, 1400 + i)])
            }
            strips.append(strip)
        }
        b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(mixer, strips)

        // --- Arrange window holds both the headers group and the mixer. ---
        b.setAttribute(arrangeWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(arrangeWindow, kAXTitleAttribute as String, "AcidWashBass — Tracks")
        b.setChildren(arrangeWindow, [headersGroup, mixer])

        // --- Plug-in window: title == track name; direct AXStaticText children
        //     include the plug-in display name at no fixed index. ---
        b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(slider, kAXDescriptionAttribute as String, thresholdDescription)
        b.setAttribute(
            slider,
            kAXValueAttribute as String,
            sliderBeforeReadable ? beforeValue : NSNull()
        )
        b.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
        b.setAttribute(slider, kAXMaxValueAttribute as String, 100.0)
        let formatSliderDisplay: @Sendable (Double) -> String = { value in
            let sign = sliderUsesSignedPositiveDisplay && value > 0 ? "+" : ""
            return "\(sign)\(Int(value.rounded())) \(sliderDisplayUnit)"
        }
        b.setAttribute(slider, kAXValueDescriptionAttribute as String, formatSliderDisplay(beforeValue))
        b.setAttribute(pluginClose, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(pluginBypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(pluginBypass, kAXDescriptionAttribute as String, "bypass")
        b.setAttribute(pluginLink, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(pluginLink, kAXDescriptionAttribute as String, "link")
        b.setAttribute(pluginWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(pluginWindow, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(
            pluginWindow,
            kAXTitleAttribute as String,
            pluginWindowTitleBeforeSlotPress ?? trackDisplayName
        )
        b.setAttribute(pluginWindow, kAXCloseButtonAttribute as String, pluginClose)
        b.setAttribute(pluginWindow, kAXMainAttribute as String, pluginWindowPresent)
        b.setAttribute(pluginWindow, kAXFocusedAttribute as String, pluginWindowPresent)
        let staticTexts = (pluginWindowStaticTextValues ?? ["보기:", pluginSlotName, trackDisplayName])
            .enumerated()
            .map { offset, value -> AXUIElement in
                let text = b.element(1010 + offset)
                b.setAttribute(text, kAXRoleAttribute as String, kAXStaticTextRole as String)
                b.setAttribute(text, kAXValueAttribute as String, value)
                return text
            }
        let ambiguousEditorSlider = b.element(100_913)
        if ambiguousEditorSliderAfterViewSelection {
            b.setAttribute(ambiguousEditorSlider, kAXRoleAttribute as String, kAXSliderRole as String)
            b.setAttribute(ambiguousEditorSlider, kAXDescriptionAttribute as String, thresholdDescription)
            b.setAttribute(ambiguousEditorSlider, kAXValueAttribute as String, beforeValue)
        }
        var pluginWindowChildren = [pluginBypass, pluginLink, slider]
            + (ambiguousEditorSliderAfterViewSelection ? [ambiguousEditorSlider] : [])
            + staticTexts
        b.setRole(controlsViewSwitcher, kAXMenuButtonRole as String)
        b.setAttribute(
            controlsViewSwitcher,
            kAXDescriptionAttribute as String,
            pluginWindowViewSwitcherDescription
        )
        b.setAttribute(
            controlsViewSwitcher,
            kAXTitleAttribute as String,
            controlsViewInitiallySelected ? "컨트롤" : "편집기"
        )
        b.setRole(controlsViewMenu, kAXMenuRole as String)
        b.setRole(controlsViewMenuItem, kAXMenuItemRole as String)
        b.setAttribute(controlsViewMenuItem, kAXTitleAttribute as String, "컨트롤")
        b.setRole(editorViewMenuItem, kAXMenuItemRole as String)
        b.setAttribute(editorViewMenuItem, kAXTitleAttribute as String, "편집기")
        b.setChildren(controlsViewMenu, [controlsViewMenuItem, editorViewMenuItem])
        pluginWindowChildren += [controlsViewSwitcher]
        var controlsViewWindowChildren = [pluginBypass, pluginLink]
            + staticTexts
            + [controlsViewSwitcher]
        // Controls view itself is identified by a parameter row whose label
        // and control occupy one AXCell as siblings. Keep that measured shape even
        // when this fixture is exercising an editor-slider write rather than
        // a Controls-view checkbox write.
        b.setRole(controlsTable, kAXTableRole as String)
        b.setRole(controlsRow, kAXRowRole as String)
        b.setRole(controlsHeadingRow, kAXRowRole as String)
        b.setRole(controlsHeadingCell, kAXCellRole as String)
        b.setRole(controlsHeadingLabel, kAXStaticTextRole as String)
        b.setAttribute(controlsHeadingLabel, kAXValueAttribute as String, "Dynamics")
        b.setChildren(controlsHeadingCell, [controlsHeadingLabel])
        b.setChildren(controlsHeadingRow, [controlsHeadingCell])
        b.setChildren(controlsTable, [controlsHeadingRow, controlsRow])
        b.setAttribute(controlsTable, kAXRowsAttribute as String, [controlsHeadingRow, controlsRow])
        controlsViewWindowChildren += [controlsTable]
        b.setRole(controlsLabelCell, kAXCellRole as String)
        b.setRole(controlsLabel, kAXStaticTextRole as String)
        b.setAttribute(
            controlsLabel,
            kAXValueAttribute as String,
            controlsViewRowLabel ?? "Measured Controls Parameter"
        )
        b.setRole(controlsCheckbox, controlsViewControlRole)
        b.setAttribute(controlsCheckbox, kAXValueAttribute as String, controlsCheckboxBefore)
        b.setChildren(controlsLabelCell, [controlsLabel, controlsCheckbox])
        b.setChildren(controlsRow, [controlsLabelCell])
        // Controls view has rows, but no editor-view slider descriptions.
        // Keep its shape distinct from the native editor so a test cannot
        // accidentally keep relying on Threshold after the view changes.
        b.setChildren(
            pluginWindow,
            controlsViewInitiallySelected ? controlsViewWindowChildren : pluginWindowChildren
        )

        let windows = pluginWindowPresent ? [arrangeWindow, pluginWindow] : [arrangeWindow]
        b.setAttribute(app, kAXWindowsAttribute as String, windows)
        // mainWindow fallback target (used if AXWindows is ever empty).
        b.setAttribute(app, kAXMainWindowAttribute as String, arrangeWindow)

        // Intercept AXValue writes so AXValueDescription tracks the new value the
        // way Logic re-renders it ("X %") and an optional forced value models a
        // sticky parameter (readback != requested).
        let sliderKey = b.elementID(slider)
        let targetSlotKey = targetSlot.map { b.elementID($0) }
        let targetSlotForViewMutation = targetSlot
        let targetOpenButtonKey = targetOpenButton.map { b.elementID($0) }
        let pluginCloseKey = b.elementID(pluginClose)
        let controlsCheckboxKey = b.elementID(controlsCheckbox)
        let controlsViewMenuItemKey = b.elementID(controlsViewMenuItem)
        let editorViewMenuItemKey = b.elementID(editorViewMenuItem)
        let controlsViewSwitcherKey = b.elementID(controlsViewSwitcher)
        let controlsWindowChildren = controlsViewWindowChildren
        let editorWindowChildren = pluginWindowChildren
        let forced = forcedAfterValue
        let writeBehavior = sliderWriteBehavior
        let menuOpen = MutableBox(false)
        let menuVisible = MutableBox(false)
        let menuCensusPolls = MutableBox(0)
        let pendingPluginWindowChildren = MutableBox<(children: [AXUIElement], settlesAt: Date)?>(nil)
        let runtime = b.makeLogicRuntime(
            appElement: app,
            childrenHandler: { element in
                if CFEqual(element, pluginWindow),
                   let pending = pendingPluginWindowChildren.value,
                   Date() >= pending.settlesAt {
                    b.setChildren(pluginWindow, pending.children)
                    pendingPluginWindowChildren.value = nil
                }
                if CFEqual(element, controlsViewSwitcher), menuOpen.value, menuVisible.value {
                    return [controlsViewMenu]
                }
                return nil
            },
            childrenResultHandler: { element in
                // The status-preserving censuses read through this seam rather
                // than `childrenHandler`; advance the same realistic view-settle
                // state before serving either read path.
                if CFEqual(element, pluginWindow),
                   let pending = pendingPluginWindowChildren.value,
                   Date() >= pending.settlesAt {
                    b.setChildren(pluginWindow, pending.children)
                    pendingPluginWindowChildren.value = nil
                }
                if controlsTableReadFailsAfterRestoration,
                   CFEqual(element, controlsTable),
                   controlsViewMenuPressCount.value > 0 {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                guard CFEqual(element, controlsViewSwitcher), menuOpen.value else { return nil }
                if viewMenuReadFailsAfterFirstSelection,
                   controlsViewMenuPressCount.value + editorViewMenuPressCount.value > 0 {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                guard let revealAfterPolls = viewMenuRevealAfterPolls else {
                    return .success([])
                }
                if menuCensusPolls.value < max(0, revealAfterPolls) {
                    menuCensusPolls.value += 1
                    return .success([])
                }
                menuVisible.value = true
                return .success([controlsViewMenu])
            },
            setAttributeHandler: { [b] el, attribute, value in
                if pluginWindowRejectsDirectDemotion,
                   b.elementID(el) == b.elementID(pluginWindow),
                   attribute == (kAXMainAttribute as String) || attribute == (kAXFocusedAttribute as String),
                   (value as? NSNumber)?.boolValue == false {
                    return true
                }
                guard b.elementID(el) == sliderKey, attribute == (kAXValueAttribute as String) else {
                    b.setAttribute(el, attribute, value)
                    return true
                }
                let requested = (value as? NSNumber)?.doubleValue ?? 0
                let current = (b.attributeValue(slider, kAXValueAttribute as String) as? NSNumber)?.doubleValue
                    ?? (b.attributeValue(slider, kAXValueAttribute as String) as? Double)
                    ?? 0
                let writeIndex = sliderWriteCount.value
                sliderWriteCount.value += 1
                if rejectSliderWrites {
                    return false
                }
                let landed: Double?
                switch writeBehavior {
                case .direct:
                    landed = forced ?? requested
                case .oneStepTowardRequest:
                    if requested > current {
                        landed = current + 1
                    } else if requested < current {
                        landed = current - 1
                    } else {
                        landed = current
                    }
                case let .scripted(readbacks):
                    landed = readbacks.indices.contains(writeIndex) ? readbacks[writeIndex] : current
                }
                b.setAttribute(el, kAXValueAttribute as String, landed ?? NSNull())
                if let landed {
                    b.setAttribute(el, kAXValueDescriptionAttribute as String, formatSliderDisplay(landed))
                }
                return true
            },
            performActionHandler: { [b] el, action in
                if pluginWindowRejectsDirectDemotion,
                   b.elementID(el) == b.elementID(arrangeWindow),
                   action == (kAXRaiseAction as String) {
                    b.setAttribute(pluginWindow, kAXMainAttribute as String, false)
                    b.setAttribute(pluginWindow, kAXFocusedAttribute as String, false)
                    return true
                }
                let key = b.elementID(el)
                if key == controlsViewSwitcherKey {
                    guard action == (kAXPressAction as String) else { return false }
                    guard !(viewMenuBecomesUnavailableAfterControlsSelection
                        && controlsViewMenuPressCount.value > 0) else {
                        return true
                    }
                    menuOpen.value = true
                    menuVisible.value = false
                    menuCensusPolls.value = 0
                    return true
                }
                if key == controlsViewMenuItemKey || key == editorViewMenuItemKey {
                    guard action == (kAXPickAction as String) else { return false }
                    menuOpen.value = false
                    menuVisible.value = false
                    if key == controlsViewMenuItemKey {
                        controlsViewMenuPressCount.value += 1
                        if invalidateTargetSlotAfterViewSelection, let targetSlotForViewMutation {
                            b.setAttribute(targetSlotForViewMutation, kAXDescriptionAttribute as String, "Noise Gate")
                        }
                        if mutatePluginHeaderAfterViewSelection, staticTexts.indices.contains(1) {
                            b.setAttribute(staticTexts[1], kAXValueAttribute as String, "Noise Gate")
                        }
                        if viewMenuSelectionSetsUnconfirmedStructure {
                            pendingPluginWindowChildren.value = (
                                children: [controlsViewSwitcher],
                                settlesAt: Date().addingTimeInterval(max(0, viewSettleDelay))
                            )
                        } else if viewMenuPressChangesStructure {
                            pendingPluginWindowChildren.value = (
                                children: controlsWindowChildren,
                                settlesAt: Date().addingTimeInterval(max(0, viewSettleDelay))
                            )
                        }
                        if viewMenuPressChangesTitle {
                            b.setAttribute(controlsViewSwitcher, kAXTitleAttribute as String, "컨트롤")
                        }
                        return true
                    }
                    editorViewMenuPressCount.value += 1
                    if invalidateTargetSlotAfterViewSelection, let targetSlotForViewMutation {
                        b.setAttribute(targetSlotForViewMutation, kAXDescriptionAttribute as String, "Noise Gate")
                    }
                    if mutatePluginHeaderAfterViewSelection, staticTexts.indices.contains(1) {
                        b.setAttribute(staticTexts[1], kAXValueAttribute as String, "Noise Gate")
                    }
                    if viewMenuSelectionSetsUnconfirmedStructure {
                        pendingPluginWindowChildren.value = (
                            children: [controlsViewSwitcher],
                            settlesAt: Date().addingTimeInterval(max(0, viewSettleDelay))
                        )
                    } else if viewMenuPressChangesStructure {
                        pendingPluginWindowChildren.value = (
                            children: editorWindowChildren,
                            settlesAt: Date().addingTimeInterval(max(0, viewSettleDelay))
                        )
                    }
                    if viewMenuPressChangesTitle {
                        b.setAttribute(controlsViewSwitcher, kAXTitleAttribute as String, "편집기")
                    }
                    return true
                }
                guard action == (kAXPressAction as String) else { return true }
                if key == pluginCloseKey {
                    pluginCloseControlPressCount.value += 1
                    if !pluginCloseControlFailsToClose {
                        b.setAttribute(app, kAXWindowsAttribute as String, [arrangeWindow])
                    }
                    return true
                }
                if key == controlsCheckboxKey,
                   controlsViewRowLabel != nil {
                    controlsCheckboxPressCount.value += 1
                    if controlsCheckboxWriteBehavior == .toggle {
                        let old = (b.attributeValue(controlsCheckbox, kAXValueAttribute as String) as? NSNumber)?.boolValue
                            ?? (b.attributeValue(controlsCheckbox, kAXValueAttribute as String) as? Bool)
                            ?? false
                        b.setAttribute(controlsCheckbox, kAXValueAttribute as String, !old)
                        return true
                    }
                    if controlsCheckboxWriteBehavior == .mixedAfterPress {
                        b.setAttribute(controlsCheckbox, kAXValueAttribute as String, NSNumber(value: 2))
                        return true
                    }
                    // Core AX returns status 0 for a successful action. Keep
                    // AXValue inert while still reporting that status so this
                    // fixture proves status alone cannot certify a write.
                    return true
                }
                guard key == targetSlotKey || key == targetOpenButtonKey else {
                    return true
                }
                if key == targetOpenButtonKey {
                    targetOpenControlPressCount.value += 1
                }
                if pluginWindowTitleBeforeSlotPress != nil {
                    b.setAttribute(pluginWindow, kAXTitleAttribute as String, trackDisplayName)
                }
                if openWindowOnSlotPress {
                    b.setAttribute(
                        app,
                        kAXWindowsAttribute as String,
                        [arrangeWindow, pluginWindow] + windowsAddedOnSlotPress.value
                    )
                }
                b.setAttribute(pluginWindow, kAXMainAttribute as String, true)
                b.setAttribute(pluginWindow, kAXFocusedAttribute as String, true)
                // Model real Logic 12.3: the slot/open-control AXPress opens the
                // window but reports a NON-ZERO AX status. The observed-window
                // poll must succeed regardless of this return.
                return !slotPressReturnsFalse
            }
        )
        self.app = app
        self.windowsAddedOnSlotPress = windowsAddedOnSlotPress
        self.targetOpenControlPressCount = targetOpenControlPressCount
        self.pluginCloseControlPressCount = pluginCloseControlPressCount
        self.sliderWriteCount = sliderWriteCount
        self.controlsCheckboxPressCount = controlsCheckboxPressCount
        self.controlsViewMenuPressCount = controlsViewMenuPressCount
        self.editorViewMenuPressCount = editorViewMenuPressCount
        self.runtime = runtime
    }

    private static func occupiedSlot(_ b: FakeAXRuntimeBuilder, _ id: Int, name: String) -> AXUIElement {
        let group = b.element(id)
        let bypass = b.element(id * 10 + 1)
        let open = b.element(id * 10 + 2)
        b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(group, kAXDescriptionAttribute as String, name)
        b.setChildren(group, [bypass, open])
        b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
        b.setAttribute(bypass, kAXValueAttribute as String, 0)
        b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(open, kAXDescriptionAttribute as String, "열기")
        return group
    }

    private static func emptySlot(_ b: FakeAXRuntimeBuilder, _ id: Int) -> AXUIElement {
        let el = b.element(id)
        b.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(el, kAXDescriptionAttribute as String, "오디오 플러그인")
        b.setAttribute(el, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
        return el
    }

    var currentSliderValue: Double? {
        builder.attributeValue(builder.element(1005), kAXValueAttribute as String) as? Double
    }

    var currentPluginViewTitle: String? {
        builder.attributeValue(builder.element(1009), kAXTitleAttribute as String) as? String
    }
}

private func runLive(
    fixture: LiveFixture,
    params: [String: String],
    frontDoc: String? = expectedPath,
    opener: AccessibilityChannel.PluginWindowOpener? = nil,
    popupMenuCleaner: AccessibilityChannel.PluginPopupMenuCleaner? = nil
) async -> [String: Any] {
    let result = await AccessibilityChannel.defaultSetParamVerified(
        params: params,
        runtime: fixture.runtime,
        frontDocumentPath: { frontDoc },
        pluginWindowOpener: opener ?? AccessibilityChannel.livePluginWindowOpener,
        // These are AX-tree fixtures, not a live CoreGraphics qualification.
        // Keep their default deterministic; popup-cleanup regressions inject
        // the exact non-clean outcome they need to exercise.
        pluginPopupMenuCleaner: popupMenuCleaner ?? { _ in .noPopupObserved }
    )
    return try! JSONSerialization.jsonObject(
        with: result.message.data(using: .utf8)!, options: []
    ) as! [String: Any]
}

private func reportsFailedPluginViewRestoration(_ envelope: [String: Any]) -> Bool {
    guard let attempted = envelope["plugin_view_restore_attempted"] as? Bool,
          let observed = envelope["plugin_view_restore_observed"] as? Bool else {
        return false
    }
    if let leftChanged = envelope["plugin_view_left_changed"] as? Bool {
        return attempted && !observed && leftChanged
    }
    let restorationWasUnobserved = envelope["plugin_view_restore_unobserved"] as? Bool ?? false
    return attempted && !observed && restorationWasUnobserved
}

/// A second same-track Compressor editor for the duplicate-insert post-count
/// case. Its distinct AX elements intentionally share every non-geometry
/// identity attribute the live editors share.
private func matchingCompressorEditorWindow(
    fixture: LiveFixture,
    baseID: Int,
    trackName editorTrackName: String = trackName
) -> (window: AXUIElement, slider: AXUIElement) {
    let b = fixture.builder
    let window = b.element(baseID)
    let slider = b.element(baseID + 1)
    let close = b.element(baseID + 2)
    let bypass = b.element(baseID + 3)
    let link = b.element(baseID + 4)
    let pluginName = b.element(baseID + 5)
    b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(slider, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(slider, kAXValueAttribute as String, 51.0)
    b.setAttribute(close, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(bypass, kAXDescriptionAttribute as String, "bypass")
    b.setAttribute(link, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(link, kAXDescriptionAttribute as String, "link")
    b.setAttribute(pluginName, kAXRoleAttribute as String, kAXStaticTextRole as String)
    b.setAttribute(pluginName, kAXValueAttribute as String, "Compressor")
    b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    b.setAttribute(window, kAXTitleAttribute as String, editorTrackName)
    b.setAttribute(window, kAXCloseButtonAttribute as String, close)
    b.setChildren(window, [bypass, link, slider, pluginName])
    return (window, slider)
}

/// A Controls-view editor on another strip. It intentionally has no described
/// slider: header identity, not the native-editor anchor, must keep this
/// window out of the requested strip's checkbox write.
private func controlsViewCompressorEditorWindow(
    fixture: LiveFixture,
    baseID: Int,
    trackName editorTrackName: String
) -> (window: AXUIElement, checkbox: AXUIElement) {
    let b = fixture.builder
    let window = b.element(baseID)
    let close = b.element(baseID + 1)
    let bypass = b.element(baseID + 2)
    let pluginName = b.element(baseID + 3)
    let headerTrackName = b.element(baseID + 4)
    let table = b.element(baseID + 5)
    let row = b.element(baseID + 6)
    let labelCell = b.element(baseID + 7)
    let label = b.element(baseID + 9)
    let checkbox = b.element(baseID + 10)

    b.setRole(close, kAXButtonRole as String)
    b.setRole(bypass, kAXCheckBoxRole as String)
    b.setAttribute(bypass, kAXDescriptionAttribute as String, "bypass")
    b.setRole(pluginName, kAXStaticTextRole as String)
    b.setAttribute(pluginName, kAXValueAttribute as String, "Compressor")
    b.setRole(headerTrackName, kAXStaticTextRole as String)
    b.setAttribute(headerTrackName, kAXValueAttribute as String, editorTrackName)
    b.setRole(table, kAXTableRole as String)
    b.setRole(row, kAXRowRole as String)
    b.setRole(labelCell, kAXCellRole as String)
    b.setRole(label, kAXStaticTextRole as String)
    b.setAttribute(label, kAXValueAttribute as String, "Limiter On")
    b.setRole(checkbox, kAXCheckBoxRole as String)
    b.setAttribute(checkbox, kAXValueAttribute as String, false)
    b.setChildren(labelCell, [label, checkbox])
    b.setChildren(row, [labelCell])
    b.setChildren(table, [row])
    b.setAttribute(table, kAXRowsAttribute as String, [row])
    b.setRole(window, kAXWindowRole as String)
    b.setAttribute(window, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    b.setAttribute(window, kAXTitleAttribute as String, editorTrackName)
    b.setAttribute(window, kAXCloseButtonAttribute as String, close)
    b.setChildren(window, [bypass, pluginName, headerTrackName, table])
    return (window, checkbox)
}

private func thresholdParams(
    track: Int = 0,
    insert: Int = 6,
    value: String = "60",
    unit: String = "normalized",
    mode: String = "duplicate_applyback",
    path: String? = expectedPath
) -> [String: String] {
    var p: [String: String] = [
        "track": String(track), "insert": String(insert),
        "plugin": "Compressor", "param": "threshold",
        "value": value, "unit": unit, "mode": mode,
    ]
    if let path { p["project_expected_path"] = path }
    return p
}

private func controlsBooleanParams(
    param: String = "limiter_on",
    value: String = "1"
) -> [String: String] {
    thresholdParams(value: value, unit: "boolean").merging([
        "param": param,
    ]) { _, new in new }
}

private let channelEQFixtureParamID = "__test_channel_eq_band_gain"
private let channelEQFixtureAXDescription = "__TEST Channel EQ Band Gain"

private func channelEQFixtureEntryLookup(
    writeMethod: String = "ax_slider_axvalue",
    unit: String = "dB",
    acceptedUnits: [String]? = nil,
    range: StockPluginValueRange = StockPluginValueRange(min: -24, max: 24, defaultValue: 0),
    tolerance: Double = 0.5
) -> VerifiedPluginCatalog.EntryLookup {
    { pluginID in
        guard pluginID == "logic.stock.effect.channel_eq" else {
            return StockPluginCatalog.entry(id: pluginID)
        }
        let provenance = StockPluginProvenance.verified(
            source: "test_fixture",
            method: "ax_plugin_window",
            observedAt: "2026-07-07T00:00:00Z",
            logicVersion: nil,
            locale: "en_US",
            evidence: ["parameter_readback", "test_fixture_only"]
        )
        return StockPluginCatalogEntry(
            id: "logic.stock.effect.channel_eq",
            displayName: "Channel EQ",
            type: .effect,
            category: "EQ",
            availabilityState: .verified,
            provenance: provenance,
            insertPaths: [
                StockPluginInsertPath(
                    path: ["Audio FX", "EQ", "Channel EQ"],
                    availabilityState: .verified,
                    provenance: provenance
                ),
            ],
            slotSupport: StockPluginSlotSupport(audio: true, instrument: false, midiFX: false, aux: true),
            knownPresets: [],
            parameters: [
                StockPluginParameterMetadata(
                    id: channelEQFixtureParamID,
                    displayName: "Test Channel EQ Band Gain",
                    unit: unit,
                    acceptedUnits: acceptedUnits,
                    valueRange: range,
                    writeMethod: writeMethod,
                    readbackMethod: "ax_slider_axvalue",
                    tolerance: tolerance,
                    axDescription: channelEQFixtureAXDescription,
                    availabilityState: .verified,
                    provenance: provenance
                ),
            ],
            safeWriteCapabilities: .parameterWriteReadback,
            limitations: ["test fixture only"]
        )
    }
}

private func channelEQFixtureParamAlias(pluginID: String, alias: String) -> String? {
    guard pluginID == "logic.stock.effect.channel_eq" else {
        return VerifiedPluginCatalog.canonicalParamKey(pluginID: pluginID, alias: alias)
    }
    let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case channelEQFixtureParamID.lowercased():
        return channelEQFixtureParamID
    default:
        return nil
    }
}

private func channelEQFixtureParams(
    param: String = channelEQFixtureParamID,
    value: String = "3.0",
    unit: String = "dB"
) -> [String: String] {
    thresholdParams(value: value, unit: unit).merging([
        "plugin": "Channel EQ",
        "param": param,
    ]) { _, new in new }
}

private func runChannelEQFixture(
    forcedAfterValue: Double? = nil,
    params: [String: String] = channelEQFixtureParams()
) async throws -> [String: Any] {
    let fixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        forcedAfterValue: forcedAfterValue
    )
    let result = await AccessibilityChannel.defaultSetParamVerified(
        params: params,
        runtime: fixture.runtime,
        frontDocumentPath: { expectedPath },
        entryLookup: channelEQFixtureEntryLookup(),
        paramAliasLookup: channelEQFixtureParamAlias,
        pluginPopupMenuCleaner: { _ in .noPopupObserved }
    )
    let data = try #require(result.message.data(using: .utf8))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return obj
}

private func runChannelEQFixture(
    fixture: LiveFixture,
    params: [String: String],
    writeMethod: String,
    incrementWalkBudget: Int = ChannelEQBandCatalog.incrementWalkBudget,
    tolerance: Double = 0.5
) async throws -> [String: Any] {
    let result = await AccessibilityChannel.defaultSetParamVerified(
        params: params,
        runtime: fixture.runtime,
        frontDocumentPath: { expectedPath },
        entryLookup: channelEQFixtureEntryLookup(
            writeMethod: writeMethod,
            unit: "raw_ax_value",
            range: StockPluginValueRange(min: 0, max: 10, defaultValue: 0),
            tolerance: tolerance
        ),
        paramAliasLookup: channelEQFixtureParamAlias,
        pluginPopupMenuCleaner: { _ in .noPopupObserved },
        incrementWalkBudget: incrementWalkBudget
    )
    let data = try #require(result.message.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func namedEQBandParams(
    band: String = "Peak 1",
    parameter: String = "Frequency",
    value: String = "3",
    unit: String = "raw_ax_value"
) -> [String: String] {
    [
        "track": "0",
        "insert": "6",
        "band": band,
        "parameter": parameter,
        "value": value,
        "unit": unit,
        "mode": "duplicate_applyback",
        "project_expected_path": expectedPath,
    ]
}

// MARK: - State A: full round-trip (before 51 → set 60 → after 60)

@Test func testCompressorThresholdVerifiedWriteReachesStateA() async {
    let fixture = LiveFixture(beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    #expect(obj["state"] as? String == "A")
    #expect((obj["verified"] as? Bool)!)
    #expect((obj["success"] as? Bool)!)
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(obj["requested_normalized"] as? Double == 60)
    #expect(obj["observed_normalized"] as? Double == 60)
    #expect(obj["observed_display"] as? String == "60 %")
    #expect(obj["display_unit"] as? String == "%")
    #expect(obj["tolerance"] as? Double == 1.0)
    #expect(obj["write_source"] as? String == "ax_plugin_window")
    #expect(obj["verify_source"] as? String == "ax_plugin_window")
    let identity = obj["target_identity"] as? [String: Any]
    #expect(identity?["plugin_id"] as? String == "logic.stock.effect.compressor")
    #expect(identity?["track_index"] as? Int == 0)
    #expect(identity?["insert"] as? Int == 6)
    // The live slider actually changed.
    #expect(fixture.currentSliderValue == 60)
    let noViewMenuSelection = fixture.controlsViewMenuPressCount.value == 0
        && fixture.editorViewMenuPressCount.value == 0
    #expect(noViewMenuSelection)
}

@Test func testCompressorThresholdSwitchesControlsToEditorThenRestoresControls() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        controlsViewInitiallySelected: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let state = try #require(result["state"] as? String)
    let observedDisplay = try #require(result["observed_display"] as? String)
    let selectedEditorOnce = fixture.editorViewMenuPressCount.value == 1
    let restoredControlsOnce = fixture.controlsViewMenuPressCount.value == 1
    let restoredEntryTitle = fixture.currentPluginViewTitle == "컨트롤"
    let sliderWasFoundAndWritten = fixture.currentSliderValue == 60
    let stateIsA = state == "A"
    let observedDisplayMatches = observedDisplay == "60 %"
    #expect(stateIsA)
    #expect(observedDisplayMatches)
    #expect(selectedEditorOnce)
    #expect(restoredControlsOnce)
    #expect(restoredEntryTitle)
    #expect(sliderWasFoundAndWritten)
}

@Test func testCompressorThresholdEnsuresAndSearchesBoundEditorNotOtherOpenCompressor() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        controlsViewInitiallySelected: true
    )
    // A duplicate-applyback run can leave another Compressor editor open.
    // It shares the plug-in header identity but belongs to another track, so
    // only the target editor may be switched, searched, and written.
    let other = matchingCompressorEditorWindow(
        fixture: fixture,
        baseID: 8_700,
        trackName: "Other Strip"
    )
    let existingWindows = fixture.builder.attributeValue(
        fixture.app,
        kAXWindowsAttribute as String
    ) as? [AXUIElement] ?? []
    fixture.builder.setAttribute(
        fixture.app,
        kAXWindowsAttribute as String,
        existingWindows + [other.window]
    )

    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let state = try #require(result["state"] as? String)
    let otherSliderValue = try #require(
        fixture.builder.attributeValue(other.slider, kAXValueAttribute as String) as? Double
    )
    let targetSelectedEditorOnce = fixture.editorViewMenuPressCount.value == 1
    let targetRestoredControlsOnce = fixture.controlsViewMenuPressCount.value == 1
    let stateIsA = state == "A"
    let targetSliderWasWritten = fixture.currentSliderValue == 60
    let otherSliderWasUntouched = otherSliderValue == 51
    #expect(stateIsA)
    #expect(targetSliderWasWritten)
    #expect(otherSliderWasUntouched)
    #expect(targetSelectedEditorOnce)
    #expect(targetRestoredControlsOnce)
}

@Test func testCompressorThresholdConfirmsEditorStructureDespiteUnchangedContradictoryTitle() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        controlsViewInitiallySelected: true,
        viewMenuPressChangesTitle: false
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let state = try #require(result["state"] as? String)
    let titleStayedContradictory = fixture.currentPluginViewTitle == "컨트롤"
    let selectedEditor = fixture.editorViewMenuPressCount.value == 1
    let restoredControls = fixture.controlsViewMenuPressCount.value == 1
    let sliderWasWritten = fixture.currentSliderValue == 60
    let stateIsA = state == "A"
    #expect(stateIsA)
    #expect(titleStayedContradictory)
    #expect(selectedEditor)
    #expect(restoredControls)
    #expect(sliderWasWritten)
}

@Test func testCompressorThresholdRefusesWhenEditorStructureNeverAppears() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        controlsViewInitiallySelected: true,
        viewMenuPressChangesStructure: false
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let error = try #require(result["error"] as? String)
    let observed = try #require(result["what_was_observed"] as? String)
    let reportsUnconfirmedView = error == "plugin_view_not_confirmed"
    let reportsStructureDeadline = observed.contains("expected editor structure")
    let sliderWasNotWritten = fixture.sliderWriteCount.value == 0
    let entryViewWasExplicitlyReselected = fixture.editorViewMenuPressCount.value == 1
        && fixture.controlsViewMenuPressCount.value == 1
    #expect(reportsUnconfirmedView)
    #expect(reportsStructureDeadline)
    #expect(sliderWasNotWritten)
    #expect(entryViewWasExplicitlyReselected)
}

@Test func testCompressorThresholdRestoresControlsAfterSliderLookupRefusal() async throws {
    let fixture = LiveFixture(
        thresholdDescription: "Native-only non-anchor",
        controlsViewInitiallySelected: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let error = try #require(result["error"] as? String)
    let switchedToEditorOnce = fixture.editorViewMenuPressCount.value == 1
    let restoredControlsOnce = fixture.controlsViewMenuPressCount.value == 1
    let restoredEntryTitle = fixture.currentPluginViewTitle == "컨트롤"
    let reportsSliderLookupRefusal = error == "param_control_not_found"
    #expect(reportsSliderLookupRefusal)
    #expect(switchedToEditorOnce)
    #expect(restoredControlsOnce)
    #expect(restoredEntryTitle)
}

@Test func testCompressorThresholdRefusesUnmeasuredViewSwitcherLocale() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        pluginWindowViewSwitcherDescription: "Ansicht"
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let error = try #require(result["error"] as? String)
    let observed = try #require(result["what_was_observed"] as? String)
    let noViewMenuSelection = fixture.controlsViewMenuPressCount.value == 0
        && fixture.editorViewMenuPressCount.value == 0
    let noSliderWrite = fixture.sliderWriteCount.value == 0
    let reportsUnconfirmedView = error == "plugin_view_not_confirmed"
    let reportsUnmeasuredLocale = observed.contains("not measured for this locale")
    #expect(reportsUnconfirmedView)
    #expect(reportsUnmeasuredLocale)
    #expect(noViewMenuSelection)
    #expect(noSliderWrite)
}

@Test func testCompressorControlsViewCheckboxUsesRowLabelPressAndChangedReadback() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let state = try #require(result["state"] as? String)
    let verified = try #require(result["verified"] as? Bool)
    let observed = try #require(result["observed_boolean"] as? Bool)
    let rowLabel = try #require(result["controls_view_row_label"] as? String)
    let presses = fixture.controlsCheckboxPressCount.value
    let oneVerifiedPress = presses == 1
    let selectedControlsOnce = fixture.controlsViewMenuPressCount.value == 1
    let restoredEditorOnce = fixture.editorViewMenuPressCount.value == 1
    let restoredEntryTitle = fixture.currentPluginViewTitle == "편집기"
    #expect(state == "A")
    #expect(verified)
    #expect(observed)
    #expect(rowLabel == "Limiter On")
    #expect(oneVerifiedPress)
    #expect(selectedControlsOnce)
    #expect(restoredEditorOnce)
    #expect(restoredEntryTitle)
}

@Test func testControlsViewAlreadyOpenWithoutDescribedSlidersBindsHeaderAndReachesCheckbox() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false,
        controlsViewInitiallySelected: true
    )

    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let state = try #require(result["state"] as? String)
    let verified = try #require(result["verified"] as? Bool)
    let checkboxPresses = fixture.controlsCheckboxPressCount.value
    let viewMenuPresses = fixture.controlsViewMenuPressCount.value
    let editorViewMenuPresses = fixture.editorViewMenuPressCount.value
    #expect(state == "A")
    #expect(verified)
    #expect(checkboxPresses == 1)
    #expect(viewMenuPresses == 0)
    #expect(editorViewMenuPresses == 0)
}

@Test func testNativeEditorWithoutThresholdAnchorBindsHeaderThenSelectsControls() async throws {
    let fixture = LiveFixture(
        thresholdDescription: "Native-only non-anchor",
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false
    )

    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let state = try #require(result["state"] as? String)
    let verified = try #require(result["verified"] as? Bool)
    let checkboxPresses = fixture.controlsCheckboxPressCount.value
    let viewMenuPresses = fixture.controlsViewMenuPressCount.value
    let editorViewMenuPresses = fixture.editorViewMenuPressCount.value
    #expect(state == "A")
    #expect(verified)
    #expect(checkboxPresses == 1)
    #expect(viewMenuPresses == 1)
    #expect(editorViewMenuPresses == 1)
}

@Test func testControlsViewHeaderBindingChoosesRequestedStripAndLeavesOtherEditorUntouched() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false,
        controlsViewInitiallySelected: true
    )
    let other = controlsViewCompressorEditorWindow(
        fixture: fixture,
        baseID: 8_600,
        trackName: "Other Strip"
    )
    let existingWindows = fixture.builder.attributeValue(
        fixture.app,
        kAXWindowsAttribute as String
    ) as? [AXUIElement] ?? []
    fixture.builder.setAttribute(
        fixture.app,
        kAXWindowsAttribute as String,
        existingWindows + [other.window]
    )

    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let state = try #require(result["state"] as? String)
    let targetCheckboxPresses = fixture.controlsCheckboxPressCount.value
    let otherCheckboxState = try #require(
        fixture.builder.attributeValue(other.checkbox, kAXValueAttribute as String) as? Bool
    )
    #expect(state == "A")
    #expect(targetCheckboxPresses == 1)
    #expect(!otherCheckboxState)
}

@Test func testControlsViewMismatchedHeaderRefusesBeforeCheckboxActuation() async throws {
    let fixture = LiveFixture(
        thresholdDescription: "Native-only non-anchor",
        pluginWindowStaticTextValues: ["보기:", "Noise Gate", trackName],
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false,
        controlsViewInitiallySelected: true
    )

    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let error = try #require(result["error"] as? String)
    let writeAttempted = try #require(result["write_attempted"] as? Bool)
    let checkboxPresses = fixture.controlsCheckboxPressCount.value
    #expect(error == "plugin_window_plugin_mismatch")
    #expect(!writeAttempted)
    #expect(checkboxPresses == 0)
}

@Test func testControlsViewCheckboxBindsTargetHeaderBeforeSharedThresholdAnchor() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false
    )
    let unrelatedEditors = ["Drums", "Reverb", "Piano", "Vox"].enumerated().map { offset, otherTrack in
        matchingCompressorEditorWindow(
            fixture: fixture,
            baseID: 8_000 + offset * 10,
            trackName: otherTrack
        ).window
    }
    let existingWindows = fixture.builder.attributeValue(
        fixture.app,
        kAXWindowsAttribute as String
    ) as? [AXUIElement] ?? []
    fixture.builder.setAttribute(
        fixture.app,
        kAXWindowsAttribute as String,
        existingWindows + unrelatedEditors
    )

    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    // Every added editor exposes the same Threshold slider. Success proves the
    // target track/plugin header binding selected the intended editor before
    // treating Threshold as its secondary Controls-view witness.
    #expect(result["state"] as? String == "A")
    #expect(fixture.controlsCheckboxPressCount.value == 1)
}

@Test func testCompressorControlsViewAutoReleaseUsesItsOwnRowLabel() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Auto Release",
        controlsCheckboxBefore: true
    )
    let result = await runLive(
        fixture: fixture,
        params: controlsBooleanParams(param: "auto_release", value: "0")
    )

    let state = try #require(result["state"] as? String)
    let verified = try #require(result["verified"] as? Bool)
    let observed = try #require(result["observed_boolean"] as? Bool)
    let rowLabel = try #require(result["controls_view_row_label"] as? String)
    let oneVerifiedPress = fixture.controlsCheckboxPressCount.value == 1
    #expect(state == "A")
    #expect(verified)
    #expect(!observed)
    #expect(rowLabel == "Auto Release")
    #expect(oneVerifiedPress)
}

@Test func testCompressorControlsViewStatusZeroUnchangedReadbackRefusesAndRestores() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false,
        controlsCheckboxWriteBehavior: .statusZeroUnchanged
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let error = try #require(result["error"] as? String)
    let restoreAttempted = try #require(result["restore_attempted"] as? Bool)
    let restoreObserved = try #require(result["restore_observed"] as? Bool)
    let writeAttempted = try #require(result["write_attempted"] as? Bool)
    let statusOnlyWasNotSuccess = result["state"] as? String != "A"
    let pressAndRestore = fixture.controlsCheckboxPressCount.value == 2
    #expect(error == "readback_mismatch")
    #expect(restoreAttempted)
    #expect(restoreObserved)
    #expect(writeAttempted)
    #expect(statusOnlyWasNotSuccess)
    #expect(pressAndRestore)
}

@Test func testCompressorControlsViewMixedNSNumberReadbackRefusesInsteadOfStateA() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false,
        controlsCheckboxWriteBehavior: .mixedAfterPress
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let state = try #require(result["state"] as? String)
    let error = try #require(result["error"] as? String)
    let writeAttempted = try #require(result["write_attempted"] as? Bool)
    let stateIsC = state == "C"
    let mixedReadbackWasNotVerified = error == "readback_lost_after_write"
    let compensatingPressWasAttempted = fixture.controlsCheckboxPressCount.value == 2
    #expect(stateIsC)
    #expect(mixedReadbackWasNotVerified)
    #expect(writeAttempted)
    #expect(compensatingPressWasAttempted)
}

@Test func testControlsLookupRefusalReportsFailedRestoreThatLeavesControlsSelected() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "A Different Boolean",
        controlsCheckboxBefore: false,
        viewMenuBecomesUnavailableAfterControlsSelection: true
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let state = try #require(result["state"] as? String)
    let error = try #require(result["error"] as? String)
    let restoreAttempted = try #require(result["plugin_view_restore_attempted"] as? Bool)
    let restoreObserved = try #require(result["plugin_view_restore_observed"] as? Bool)
    let leftChanged = try #require(result["plugin_view_left_changed"] as? Bool)
    let observedStructure = try #require(result["plugin_view_restore_observed_structure"] as? String)
    let lookupRefusalWasStateC = state == "C" && error == "param_control_not_found"
    let restorationFailureWasVisible = restoreAttempted && !restoreObserved && leftChanged
    let fixtureWasLeftInControls = fixture.currentPluginViewTitle == "컨트롤"
    #expect(lookupRefusalWasStateC)
    #expect(restorationFailureWasVisible)
    #expect(observedStructure == "controls")
    #expect(fixtureWasLeftInControls)
}

@Test func testUnobservedRestoreDoesNotClaimTheRestoredEntryViewWasLeftChanged() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        controlsTableReadFailsAfterRestoration: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let state = try #require(result["state"] as? String)
    let restoreAttempted = try #require(result["plugin_view_restore_attempted"] as? Bool)
    let restoreObserved = try #require(result["plugin_view_restore_observed"] as? Bool)
    let restorationWasReportedUnobserved = try #require(result["plugin_view_restore_unobserved"] as? Bool)
    let entryViewWasActuallyReselected = fixture.currentPluginViewTitle == "컨트롤"
    let leftChangedWasNotAsserted = result["plugin_view_left_changed"] == nil
    let writeReachedStateA = state == "A"
    let restoreAttemptWasUnconfirmed = restoreAttempted && !restoreObserved
    #expect(writeReachedStateA)
    #expect(restoreAttemptWasUnconfirmed)
    #expect(restorationWasReportedUnobserved)
    #expect(entryViewWasActuallyReselected)
    #expect(leftChangedWasNotAsserted)
}

@Test func testNoTableConfirmsEditorBeforeTheFailedCompensatingRestore() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        viewMenuSelectionSetsUnconfirmedStructure: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let error = try #require(result["error"] as? String)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let noSliderWrite = fixture.sliderWriteCount.value == 0
    let reportedMissingEditorControl = error == "param_control_not_found"
    #expect(reportedMissingEditorControl)
    #expect(restorationFailureWasVisible)
    #expect(noSliderWrite)
}

@Test func testTargetRevalidationStateCReportsFailedViewRestore() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        viewMenuReadFailsAfterFirstSelection: true,
        invalidateTargetSlotAfterViewSelection: true
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let error = try #require(result["error"] as? String)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let noCheckboxPress = fixture.controlsCheckboxPressCount.value == 0
    let reportedUnresolvedIdentity = error == "window_identity_unresolved"
    #expect(reportedUnresolvedIdentity)
    #expect(restorationFailureWasVisible)
    #expect(noCheckboxPress)
}

@Test func testPluginIdentityFailureStateCReportsFailedViewRestore() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        viewMenuReadFailsAfterFirstSelection: true,
        mutatePluginHeaderAfterViewSelection: true
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let error = try #require(result["error"] as? String)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let noCheckboxPress = fixture.controlsCheckboxPressCount.value == 0
    let reportedUnresolvedIdentity = error == "window_identity_unresolved"
    #expect(reportedUnresolvedIdentity)
    #expect(restorationFailureWasVisible)
    #expect(noCheckboxPress)
}

@Test func testSliderAmbiguityStateCReportsFailedViewRestore() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true,
        ambiguousEditorSliderAfterViewSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let error = try #require(result["error"] as? String)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let noSliderWrite = fixture.sliderWriteCount.value == 0
    let reportedUnresolvedIdentity = error == "window_identity_unresolved"
    #expect(reportedUnresolvedIdentity)
    #expect(restorationFailureWasVisible)
    #expect(noSliderWrite)
}

@Test func testDirectWriteRejectionStateCReportsFailedViewRestore() async throws {
    let fixture = LiveFixture(
        rejectSliderWrites: true,
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let error = try #require(result["error"] as? String)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let rollbackAttempted = try #require(result["rollback_attempted"] as? Bool)
    let parameterMayBeChanged = try #require(result["parameter_left_changed"] as? Bool)
    let reportedAXWriteFailure = error == "ax_write_failed"
    #expect(reportedAXWriteFailure)
    #expect(restorationFailureWasVisible)
    #expect(rollbackAttempted)
    #expect(parameterMayBeChanged)
}

@Test func testDirectReadbackLossRollsBackAndReportsFailedViewRestore() async throws {
    let fixture = LiveFixture(
        sliderWriteBehavior: .scripted([nil, 51]),
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let error = try #require(result["error"] as? String)
    let rollbackAttempted = try #require(result["rollback_attempted"] as? Bool)
    let rolledBack = try #require(result["rolled_back"] as? Bool)
    let rollbackObserved = try #require(result["rollback_observed"] as? Double)
    let safeToRetry = try #require(result["safe_to_retry"] as? Bool)
    let parameterLeftChanged = try #require(result["parameter_left_changed"] as? Bool)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let rollbackWasWritten = fixture.sliderWriteCount.value == 2
    let reportedReadbackLoss = error == "readback_lost_after_write"
    let rollbackObservedOriginalValue = rollbackObserved == 51
    let parameterWasNotLeftChanged = !parameterLeftChanged
    #expect(reportedReadbackLoss)
    #expect(rollbackAttempted)
    #expect(rolledBack)
    #expect(rollbackObservedOriginalValue)
    #expect(safeToRetry)
    #expect(parameterWasNotLeftChanged)
    #expect(restorationFailureWasVisible)
    #expect(rollbackWasWritten)
}

@Test func testDirectReadbackLossWithFailedRollbackReportsParameterLeftChanged() async throws {
    let fixture = LiveFixture(
        sliderWriteBehavior: .scripted([nil, nil]),
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let rollbackAttempted = try #require(result["rollback_attempted"] as? Bool)
    let rolledBack = try #require(result["rolled_back"] as? Bool)
    let parameterLeftChanged = try #require(result["parameter_left_changed"] as? Bool)
    let safeToRetry = try #require(result["safe_to_retry"] as? Bool)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let rollbackWasNotObserved = !rolledBack
    let retryIsNotSafe = !safeToRetry
    #expect(rollbackAttempted)
    #expect(rollbackWasNotObserved)
    #expect(parameterLeftChanged)
    #expect(retryIsNotSafe)
    #expect(restorationFailureWasVisible)
}

@Test func testDirectRollbackNearMissUsesTheParametersOwnZeroTolerance() async throws {
    let fixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 51,
        // The write's readback is lost; compensation reaches 51.4 rather than
        // the pre-write 51. This fixture declares tolerance 0 below.
        sliderWriteBehavior: .scripted([nil, 51.4])
    )
    let result = try await runChannelEQFixture(
        fixture: fixture,
        params: channelEQFixtureParams(value: "3", unit: "raw_ax_value"),
        writeMethod: "ax_slider_axvalue",
        tolerance: 0
    )

    let rollbackAttempted = try #require(result["rollback_attempted"] as? Bool)
    let rolledBack = try #require(result["rolled_back"] as? Bool)
    let rollbackObserved = try #require(result["rollback_observed"] as? Double)
    let parameterLeftChanged = try #require(result["parameter_left_changed"] as? Bool)
    let safeToRetry = try #require(result["safe_to_retry"] as? Bool)
    let exactRestorationWasNotObserved = !rolledBack && rollbackObserved == 51.4
    let parameterWasLeftChanged = parameterLeftChanged && !safeToRetry
    #expect(rollbackAttempted)
    #expect(exactRestorationWasNotObserved)
    #expect(parameterWasLeftChanged)
}

@Test func testReadbackMismatchStateCReportsFailedViewRestore() async throws {
    let fixture = LiveFixture(
        forcedAfterValue: 40,
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let error = try #require(result["error"] as? String)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let reportedReadbackMismatch = error == "readback_mismatch"
    #expect(reportedReadbackMismatch)
    #expect(restorationFailureWasVisible)
}

@Test func testIncrementWalkFailureStateCReportsFailedViewRestore() async throws {
    let fixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        sliderWriteBehavior: .scripted([0]),
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = try await runChannelEQFixture(
        fixture: fixture,
        params: channelEQFixtureParams(value: "3", unit: "raw_ax_value"),
        writeMethod: "ax_slider_increment_walk"
    )

    let error = try #require(result["error"] as? String)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let reportedNoIncrementProgress = error == "increment_walk_no_progress"
    #expect(reportedNoIncrementProgress)
    #expect(restorationFailureWasVisible)
}

@Test func testUnreadableDirectBeforeStateRefusesWithoutWriting() async throws {
    let fixture = LiveFixture(
        sliderBeforeReadable: false,
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let error = try #require(result["error"] as? String)
    let writeAttempted = try #require(result["write_attempted"] as? Bool)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let noSliderWrite = fixture.sliderWriteCount.value == 0
    let reportedReadbackUnavailable = error == "readback_unavailable"
    let writeWasNotAttempted = !writeAttempted
    #expect(reportedReadbackUnavailable)
    #expect(writeWasNotAttempted)
    #expect(restorationFailureWasVisible)
    #expect(noSliderWrite)
}

@Test func testWithinToleranceStillStateA() async {
    // forcedAfter 60.7 vs requested 60 → |0.7| <= 1.0 → State A.
    let fixture = LiveFixture(beforeValue: 51, forcedAfterValue: 60.7)
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "60"))
    #expect(obj["state"] as? String == "A")
    #expect(obj["observed_normalized"] as? Double == 60.7)
}

// MARK: - Plug-in editor header identity

@Test func testPreopenedDifferentPluginHeaderIsRefusedBeforeWrite() async throws {
    // The reuse path must not adopt a same-track, same-parameter Noise Gate
    // editor for a Compressor request merely because both expose Threshold.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowStaticTextValues: ["보기:", "Noise Gate", trackName]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "plugin_window_plugin_mismatch")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect((try #require(obj["what_was_observed"] as? String)).contains("Noise Gate"))
    #expect(fixture.currentSliderValue == 51)
}

@Test func testRequestedPluginHeaderAllowsPreopenedReuseToReachStateA() async {
    // This takes the production opener's pre-existing-window reuse branch.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowStaticTextValues: ["보기:", "Compressor", trackName]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())
    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
}

@Test func testPluginHeaderAliasMapsToRequestedCanonicalID() async throws {
    // The observed spelling intentionally differs from the catalog display
    // name. Raw string equality would reject it; catalog alias resolution must
    // accept it as Channel EQ.
    let fixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        pluginWindowStaticTextValues: ["보기:", "ChannelEQ", trackName]
    )
    let obj = try await runChannelEQFixture(
        fixture: fixture,
        params: channelEQFixtureParams(value: "3", unit: "raw_ax_value"),
        writeMethod: "ax_slider_axvalue"
    )

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 3)
}

@Test func testPluginWindowWithoutReadableStaticTextIsRefused() async throws {
    let fixture = LiveFixture(beforeValue: 51, pluginWindowStaticTextValues: [])
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "plugin_window_plugin_mismatch")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect((try #require(obj["what_was_observed"] as? String)).contains("no readable direct AXStaticText"))
    #expect(fixture.currentSliderValue == 51)
}

@Test func testPluginHeaderNameIsFoundAtAnyDirectStaticTextIndex() async {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowStaticTextValues: ["보기:", "unused label", trackName, "Compressor", "status"]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
}

@Test func testControlsViewHeaderWithoutLocalizedViewLabelStillPasses() async {
    // Logic's Controls view drops the localized 보기: label but keeps the
    // plug-in display name. The check must not depend on the label's presence.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowStaticTextValues: ["Compressor", trackName]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
}

@Test func testLadderPollRefusesNewlyOpenedDifferentPluginHeader() async throws {
    // No editor is present for the preflight scan. The slot press reveals a
    // Noise Gate editor on a track NAMED Compressor. The title and its matching
    // direct static-text value are the track, not the plug-in, so every poll
    // result must reject the shared Threshold slider. This would write State A
    // before the header check excludes the track name.
    let fixture = LiveFixture(
        trackDisplayName: "Compressor",
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        pluginWindowStaticTextValues: ["보기:", "Noise Gate", "Compressor"]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "plugin_window_plugin_mismatch")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect((try #require(obj["what_was_observed"] as? String)).contains("Noise Gate"))
    #expect(fixture.currentSliderValue == 51)
}

// MARK: - #726 per-track plug-in-instance ambiguity

@Test func testDuplicatePluginInstancesAcquireByOneTargetOpenPress() async {
    // Mutation caught: reusing the name-only opener (or taking an unproven
    // editor) would make this fail before State A or press another control.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
    #expect(fixture.targetOpenControlPressCount.value == 1)
}

@Test func testDuplicatePluginWithAnAlreadyOpenEditorRefusesBeforePress() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "duplicate_plugin_editor_already_open")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(obj["matching_editor_count_before_press"] as? Int == 1)
    #expect(fixture.targetOpenControlPressCount.value == 0)
    #expect(fixture.currentSliderValue == 51)
}

@Test func testDuplicatePluginWithTwoEditorsAfterOnePressRefuses() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]]
    )
    let sibling = matchingCompressorEditorWindow(fixture: fixture, baseID: 3_500)
    fixture.windowsAddedOnSlotPress.value = [sibling.window]
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "duplicate_plugin_editor_count_mismatch")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(obj["matching_editor_count_after_press"] as? Int == 2)
    #expect(fixture.targetOpenControlPressCount.value == 1)
    #expect(fixture.currentSliderValue == 51)
    #expect(fixture.builder.attributeValue(sibling.slider, kAXValueAttribute as String) as? Double == 51)
    // Count-mismatch is an early return, but both editors were newly observed
    // after this operation's press and must not be stranded for the next call.
    #expect(fixture.pluginCloseControlPressCount.value == 1)
    #expect(AXLogicProElements.matchingPluginEditorWindows(
        forTrackName: trackName,
        matchingPluginID: "logic.stock.effect.compressor",
        runtime: fixture.runtime
    ).isEmpty)
}

@Test func testDuplicateAcquisitionRejectsAnExistingEditorThatOnlyBecomesAMatchAfterPress() async throws {
    // The pre-press AX window list already contains this editor, but it does
    // not identify the target track until the target control is pressed. A
    // count-only implementation accepts it and writes; provenance requires a
    // newly observed AX element as well as exactly one matching editor.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: true,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]],
        pluginWindowTitleBeforeSlotPress: "Other Track"
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "duplicate_plugin_editor_count_mismatch")
    #expect(obj["matching_editor_count_after_press"] as? Int == 1)
    #expect(obj["new_matching_editor_count_after_press"] as? Int == 0)
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(fixture.targetOpenControlPressCount.value == 1)
    #expect(fixture.currentSliderValue == 51)
    #expect(fixture.pluginCloseControlPressCount.value == 0)
}

@Test func testDuplicatePluginWithNoEditorAfterOnePressRefuses() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "duplicate_plugin_editor_count_mismatch")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(obj["matching_editor_count_after_press"] as? Int == 0)
    #expect(fixture.targetOpenControlPressCount.value == 1)
    #expect(fixture.currentSliderValue == 51)
}

@Test func testSinglePluginWithAnAlreadyOpenEditorKeepsExistingBehaviour() async {
    let fixture = LiveFixture(beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
}

@Test func testDifferentPluginInstancesOnTargetTrackStillProceed() async {
    // Mutation caught: treating every occupied insert as an ambiguity would
    // block a Compressor merely because a different plug-in shares the track.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginSlotNamesByTrack: [0: [0: "Gain", 6: "Compressor"]]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
}

@Test func testSamePluginOnDifferentTracksStillProceeds() async {
    // Mutation caught: scanning the whole mixer instead of only the addressed
    // track would reject independent Compressor instances on other tracks.
    let fixture = LiveFixture(
        beforeValue: 51,
        otherTracks: 1,
        pluginSlotNamesByTrack: [1: [0: "Compressor"]]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
}

@Test func testSinglePluginInstanceStillProceeds() async {
    // Mutation caught: an off-by-one ambiguity condition (`count >= 1`) would
    // refuse the single insert that remains safely addressable.
    let fixture = LiveFixture(insert: 0, beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams(insert: 0))

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
}

@Test func testDuplicateChannelEQInstancesAlsoRequireAProvenPostCount() async throws {
    // The shared verified-write engine must not let the named-band route escape
    // duplicate-instance construction. The injected opener cannot supply a
    // window here: this branch must use exactly one slot-control press instead.
    let fixture = LiveFixture(
        thresholdDescription: "Peak 1 Frequency",
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        pluginWindowPresent: false,
        pluginSlotNamesByTrack: [0: [0: "Channel EQ", 6: "Channel EQ"]]
    )
    let openerInvoked = MutableBox(false)
    let result = await AccessibilityChannel.defaultSetEQBandVerified(
        params: namedEQBandParams(),
        runtime: fixture.runtime,
        frontDocumentPath: { expectedPath },
        pluginWindowOpener: { _, _, _, _, _ in
            openerInvoked.value = true
            return nil
        }
    )
    let data = try #require(result.message.data(using: .utf8))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "duplicate_plugin_editor_count_mismatch")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(obj["conflicting_insert_indices"] as? [Int] == [0, 6])
    #expect(obj["matching_editor_count_after_press"] as? Int == 0)
    #expect(fixture.targetOpenControlPressCount.value == 1)
    #expect(!openerInvoked.value, "the duplicate branch must not reuse the generic opener")
}

// MARK: - ADR-002 F1: live track-name cross-check for target_ref resolutions

// The `target_ref` path threads the reference's bound track name in as
// `expected_track_name`. When the live AX header at the positional index no
// longer reads back that name (out-of-band UI reorder, stale cache), the write
// must fail closed with stale_target_reference BEFORE any AXValue write —
// otherwise a same-index/same-plugin collision would land a wrong-target write.

@Test func testExpectedTrackNameMismatchFailsClosedStaleAndDoesNotWrite() async throws {
    // Live header at index 0 is "Acid Wash Bass"; the ref was bound to a track
    // whose name has since changed (its live index now holds a different track).
    let fixture = LiveFixture(beforeValue: 51)
    var params = thresholdParams(value: "60")
    params["expected_track_name"] = "Kick Bus"
    let obj = await runLive(fixture: fixture, params: params)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "stale_target_reference")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
    #expect(obj["expected_track_name"] as? String == "Kick Bus")
    #expect(obj["observed_track_name"] as? String == "Acid Wash Bass")
    // The live slider was NEVER written — zero wrong-target write.
    #expect(fixture.currentSliderValue == 51)
}

@Test func testExpectedTrackNameMatchStillReachesStateA() async {
    // The bound name still matches the live header → guard is a no-op passthrough.
    let fixture = LiveFixture(beforeValue: 51)
    var params = thresholdParams(value: "60")
    params["expected_track_name"] = trackName
    let obj = await runLive(fixture: fixture, params: params)

    #expect(obj["state"] as? String == "A")
    #expect((obj["verified"] as? Bool)!)
    #expect(fixture.currentSliderValue == 60)
}

@Test func testDuplicateLiveTrackNameFailsClosedBeforeWrite() async throws {
    let fixture = LiveFixture(beforeValue: 51, otherTracks: 1, duplicateTrackNameAt: 1)
    var params = thresholdParams(value: "60")
    params["expected_track_name"] = trackName
    let obj = await runLive(fixture: fixture, params: params)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "ambiguous_target_name")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
    let v2 = try #require(obj["ambiguous_live_track_name"] as? Bool)
    #expect(v2)
    #expect(obj["ambiguous_track_indices"] as? [Int] == [0, 1])
    #expect(fixture.currentSliderValue == 51)
}

@Test func testAbsentExpectedTrackNameIsByteInvariant() async {
    // Explicit-index / flag-off path: no expected_track_name → unchanged State A.
    let fixture = LiveFixture(beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "60"))
    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
}

@Test func testChannelEQFixtureParamResolvesAndVerifiesStateAWithinTolerance() async throws {
    let canonical = VerifiedPluginCatalog.canonicalParamKey(
        pluginID: "logic.stock.effect.channel_eq",
        alias: channelEQFixtureParamID,
        paramAliasLookup: channelEQFixtureParamAlias
    )
    #expect(canonical == channelEQFixtureParamID)
    #expect(VerifiedPluginCatalog.paramCapability(
        pluginID: "logic.stock.effect.channel_eq",
        paramKey: channelEQFixtureParamID,
        entryLookup: channelEQFixtureEntryLookup()
    ) == .writeReadback)

    let obj = try await runChannelEQFixture(forcedAfterValue: 3.4)

    #expect(obj["state"] as? String == "A")
    #expect(try #require(obj["verified"] as? Bool))
    #expect(obj["observed_normalized"] as? Double == 3.4)
    #expect(obj["tolerance"] as? Double == 0.5)
    let identity = try #require(obj["target_identity"] as? [String: Any])
    #expect(identity["plugin_id"] as? String == "logic.stock.effect.channel_eq")
}

@Test func testChannelEQFixtureParamOutsideToleranceIsReadbackMismatch() async throws {
    let obj = try await runChannelEQFixture(forcedAfterValue: 1.0)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "readback_mismatch")
    let v1 = try #require(obj["verified"] as? Bool)
    #expect(!v1)
    #expect(try #require(obj["write_attempted"] as? Bool))
    #expect(obj["requested_normalized"] as? Double == 3.0)
    #expect(obj["observed_normalized"] as? Double == 1.0)
}

@Test func testChannelEQFixtureUnsupportedParamFailsClosedUnsupportedParamReadback() async throws {
    let obj = try await runChannelEQFixture(params: channelEQFixtureParams(param: "unregistered_channel_eq_param"))

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "unsupported_param_readback")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
}

// MARK: - #301 Channel EQ increment-walk dispatch

@Test func testVerifiedPluginDeclaredWriteMethodSelectsWalkOrSingleAXValueSet() async throws {
    let walkFixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        sliderWriteBehavior: .oneStepTowardRequest
    )
    let walk = try await runChannelEQFixture(
        fixture: walkFixture,
        params: channelEQFixtureParams(value: "3", unit: "raw_ax_value"),
        writeMethod: "ax_slider_increment_walk"
    )
    #expect(walk["state"] as? String == "A")
    #expect(walkFixture.sliderWriteCount.value == 3)

    let singleSetFixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 0
    )
    let singleSet = try await runChannelEQFixture(
        fixture: singleSetFixture,
        params: channelEQFixtureParams(value: "3", unit: "raw_ax_value"),
        writeMethod: "ax_slider_axvalue"
    )
    #expect(singleSet["state"] as? String == "A")
    #expect(singleSetFixture.sliderWriteCount.value == 1)
}

@Test func testVerifiedPluginIncrementWalkFailuresAreDistinctStateCEnvelopes() async throws {
    struct Scenario {
        let initial: Double
        let requested: String
        let writes: [Double?]
        let budget: Int
        let error: String
        let outcome: String
    }
    let scenarios = [
        Scenario(
            initial: 0,
            requested: "3",
            writes: [0],
            budget: 4,
            error: "increment_walk_no_progress",
            outcome: "noProgress"
        ),
        Scenario(
            initial: 0,
            requested: "3",
            writes: [1, 2],
            budget: 2,
            error: "increment_walk_budget_exhausted",
            outcome: "budgetExhausted"
        ),
        Scenario(
            initial: 4,
            requested: "5",
            writes: [7, 8],
            budget: 4,
            error: "increment_walk_overshot",
            outcome: "overshot"
        ),
        Scenario(
            initial: 0,
            requested: "3",
            writes: [nil],
            budget: 4,
            error: "readback_lost_after_write",
            outcome: "readbackLost"
        ),
    ]

    for scenario in scenarios {
        let fixture = LiveFixture(
            thresholdDescription: channelEQFixtureAXDescription,
            pluginSlotName: "Channel EQ",
            beforeValue: scenario.initial,
            sliderWriteBehavior: .scripted(scenario.writes)
        )
        let result = try await runChannelEQFixture(
            fixture: fixture,
            params: channelEQFixtureParams(value: scenario.requested, unit: "raw_ax_value"),
            writeMethod: "ax_slider_increment_walk",
            incrementWalkBudget: scenario.budget
        )
        #expect(result["state"] as? String == "C")
        #expect(result["error"] as? String == scenario.error)
        #expect(result["walk_outcome"] as? String == scenario.outcome)
        let writeAttempted = try #require(result["write_attempted"] as? Bool)
        #expect(writeAttempted)
    }
}

@Test func testVerifiedPluginIncrementWalkRollbackUsesTheWalkAndReportsFailure() async throws {
    let rollbackFixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        // Forward: 0 → 1 → 2 → 2 (no progress). Rollback: 2 → 1 → 0.
        sliderWriteBehavior: .scripted([1, 2, 2, 1, 0])
    )
    let rolledBack = try await runChannelEQFixture(
        fixture: rollbackFixture,
        params: channelEQFixtureParams(value: "3", unit: "raw_ax_value"),
        writeMethod: "ax_slider_increment_walk"
    )
    #expect(rolledBack["error"] as? String == "increment_walk_no_progress")
    let rollbackSucceeded = try #require(rolledBack["rollback_succeeded"] as? Bool)
    #expect(rollbackSucceeded)
    #expect(rolledBack["rollback_outcome"] as? String == "arrived")
    #expect(rollbackFixture.sliderWriteCount.value == 5)

    let failedRollbackFixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        sliderWriteBehavior: .scripted([1, 1, 1])
    )
    let failedRollback = try await runChannelEQFixture(
        fixture: failedRollbackFixture,
        params: channelEQFixtureParams(value: "3", unit: "raw_ax_value"),
        writeMethod: "ax_slider_increment_walk"
    )
    let rollbackFailed = try #require(failedRollback["rollback_succeeded"] as? Bool)
    #expect(!rollbackFailed)
    #expect(failedRollback["rollback_outcome"] as? String == "noProgress")
}

@Test func testVerifiedPluginNamedEQBandHonorsUnitsAndRefusesUnresolvedNamesBeforeWindowOpen() async throws {
    let validFixture = LiveFixture(
        thresholdDescription: "Peak 1 Frequency",
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        sliderWriteBehavior: .oneStepTowardRequest
    )
    let validResult = await AccessibilityChannel.defaultSetEQBandVerified(
        params: namedEQBandParams(),
        runtime: validFixture.runtime,
        frontDocumentPath: { expectedPath },
        pluginPopupMenuCleaner: { _ in .noPopupObserved }
    )
    let validData = try #require(validResult.message.data(using: .utf8))
    let valid = try #require(try JSONSerialization.jsonObject(with: validData) as? [String: Any])
    #expect(valid["state"] as? String == "A")
    #expect(validFixture.sliderWriteCount.value == 3)

    for params in [
        namedEQBandParams(unit: "dB"),
        namedEQBandParams(band: "Peak 9"),
        namedEQBandParams(parameter: "Resonance"),
    ] {
        let fixture = LiveFixture(
            thresholdDescription: "Peak 1 Frequency",
            pluginSlotName: "Channel EQ",
            beforeValue: 0,
            pluginWindowPresent: false
        )
        let result = await AccessibilityChannel.defaultSetEQBandVerified(
            params: params,
            runtime: fixture.runtime,
            frontDocumentPath: { expectedPath }
        )
        let data = try #require(result.message.data(using: .utf8))
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(envelope["state"] as? String == "C")
        #expect(envelope["error"] as? String == "invalid_params")
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(fixture.sliderWriteCount.value == 0)
    }
}

@Test func testNamedEQEngineeringUnitUsesCatalogCapitalizationInExactTarget() async throws {
    // Mutation caught: accepting `db` case-insensitively but retaining it in
    // the target rendering asks for `+3 db`, which can never equal Logic's
    // measured `+3 dB` display.
    let fixture = LiveFixture(
        thresholdDescription: "Peak 1 Gain",
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        sliderWriteBehavior: .oneStepTowardRequest,
        sliderDisplayUnit: "dB",
        sliderUsesSignedPositiveDisplay: true
    )
    let result = await AccessibilityChannel.defaultSetEQBandVerified(
        params: namedEQBandParams(parameter: "Gain", unit: "db"),
        runtime: fixture.runtime,
        frontDocumentPath: { expectedPath },
        pluginPopupMenuCleaner: { _ in .noPopupObserved }
    )
    let data = try #require(result.message.data(using: .utf8))
    let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(envelope["state"] as? String == "A")
    #expect(envelope["requested_display"] as? String == "+3 dB")
    #expect(envelope["display_unit"] as? String == "dB")
}

// MARK: - State C: tolerance exceeded → readback_mismatch + rollback

@Test func testOutsideToleranceIsReadbackMismatchAndRollsBack() async {
    // Slider sticks at 40 regardless of the requested 60 → |40-60| = 20 > 1.0.
    let fixture = LiveFixture(beforeValue: 51, forcedAfterValue: 40)
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "readback_mismatch")
    #expect(!((obj["verified"] as? Bool)!))
    #expect((obj["write_attempted"] as? Bool)!)
    #expect(obj["requested_normalized"] as? Double == 60)
    #expect(obj["observed_normalized"] as? Double == 40)
    #expect(obj["tolerance"] as? Double == 1.0)
    // Rollback re-set to the before value (51). Because the slider is forced to
    // 40 on every write, the re-read returns 40, so rollback is attempted but
    // does not confirm — the honest report says attempted:true, succeeded:false.
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect(obj["rollback_to"] as? Double == 51)
}

@Test func testRollbackSucceedsWhenWriteIsHonest() async {
    // No forced value: the rollback write to 51 actually lands, so the re-read
    // confirms it. We still get readback_mismatch because the FIRST write (to
    // an out-of-range requested value) is what mismatches — drive that via a
    // requested value the slider cannot reach by clamping through forced=nil but
    // a requested value far from before. Instead, model a slider that lands the
    // requested value, then assert a mismatch using a tolerance-busting target.
    // Simpler: forced value equals a near-miss only on the FIRST write.
    let fixture = OneShotStickyFixture(beforeValue: 51, firstWriteLandsAt: 40)
    let result = await AccessibilityChannel.defaultSetParamVerified(
        params: thresholdParams(value: "60"),
        runtime: fixture.runtime,
        frontDocumentPath: { expectedPath },
        pluginPopupMenuCleaner: { _ in .noPopupObserved }
    )
    let obj = try! JSONSerialization.jsonObject(with: result.message.data(using: .utf8)!) as! [String: Any]
    #expect(obj["error"] as? String == "readback_mismatch")
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect((obj["rollback_succeeded"] as? Bool)!, "the rollback write to 51 lands and is confirmed")
    #expect(fixture.currentSliderValue == 51)
}

// MARK: - State C: window not found → window_open_failed

@Test func testNoOpenPluginWindowIsWindowOpenFailed() async throws {
    let fixture = LiveFixture(beforeValue: 51, pluginWindowPresent: false)
    let obj = await runLive(fixture: fixture, params: thresholdParams())
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "window_open_failed")
    #expect(!((obj["write_attempted"] as? Bool)!))
    let v1 = try #require(obj["opener_action_attempted"] as? Bool)
    #expect(v1)
    #expect(obj["requested_window_title"] as? String == trackName)
    #expect(obj["requested_slider_description"] as? String == "Threshold")
    let windowCandidates = obj["window_candidates"] as? [[String: Any]]
    #expect(windowCandidates?.first?["title"] as? String == "AcidWashBass — Tracks")
}

@Test func testProductionOpenerOpensClosedTargetSlotWindow() async {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(obj["observed_normalized"] as? Double == 60)
    #expect(fixture.currentSliderValue == 60)
}

@Test func testPluginWindowAcquisitionLadderExcludesMenuOpenersByAction() {
    let builder = FakeAXRuntimeBuilder()
    let slot = builder.element(40_100)
    let ordinaryButton = builder.element(40_101)
    let menuButton = builder.element(40_102)
    builder.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(ordinaryButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(menuButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(ordinaryButton, kAXDescriptionAttribute as String, "Open editor")
    builder.setAttribute(menuButton, kAXDescriptionAttribute as String, "Anything")
    builder.setActionNames(ordinaryButton, [kAXPressAction as String])
    builder.setActionNames(menuButton, [kAXPressAction as String, kAXShowMenuAction as String])
    builder.setChildren(slot, [ordinaryButton, menuButton])

    let ranked = AccessibilityChannel.rankedPluginSlotOpenControls(
        in: slot, runtime: builder.makeAXRuntime()
    )

    #expect(ranked.contains { CFEqual($0.element, ordinaryButton) })
    #expect(!ranked.contains { CFEqual($0.element, menuButton) })
}

@Test func testPluginSlotMenuOpenerDecisionUsesAdvertisedActions() {
    #expect(AccessibilityChannel.pluginSlotControlOpensMenu(
        actionNames: [kAXPressAction as String, kAXShowMenuAction as String]
    ))
    #expect(AccessibilityChannel.pluginSlotControlOpensMenu(
        actionNames: ["AXPress", "Name:Legacy open plug-in menu"]
    ))
    #expect(!AccessibilityChannel.pluginSlotControlOpensMenu(actionNames: [kAXPressAction as String]))
}

@Test func testStuckPluginPopupIsReportedInTheVerifiedWriteEnvelope() async throws {
    let fixture = LiveFixture(beforeValue: 51)
    let obj = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        popupMenuCleaner: { _ in
            .couldNotDismiss(initialPopupCount: 1, remainingPopupCount: 1)
        }
    )

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "window_open_failed")
    #expect(obj["plugin_popup_menu_state"] as? String == "could_not_be_dismissed")
    #expect(obj["plugin_popup_menu_remaining_window_count"] as? Int == 1)
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    let safeToRetry = try #require(obj["safe_to_retry"] as? Bool)
    #expect(!writeAttempted)
    #expect(!safeToRetry)
    #expect(fixture.currentSliderValue == 51)
}

@Test func testUnreadablePluginPopupCountIsNotReportedAsClean() async throws {
    // Mutation caught: collapsing a nil CoreGraphics popup count into
    // noPopupObserved allows a write after the screen state became unknowable.
    let fixture = LiveFixture(beforeValue: 51)
    let obj = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        popupMenuCleaner: { _ in .popupCountUnavailable }
    )

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "window_open_failed")
    #expect(obj["plugin_popup_menu_state"] as? String == "window_count_unavailable")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    let safeToRetry = try #require(obj["safe_to_retry"] as? Bool)
    #expect(!safeToRetry)
    #expect(fixture.currentSliderValue == 51)
}

@Test func testConsecutiveEQBandWritesReuseTheVerifiedOpenEditor() async throws {
    let fixture = LiveFixture(
        thresholdDescription: "Peak 1 Frequency",
        pluginSlotName: "Channel EQ",
        beforeValue: 0,
        sliderWriteBehavior: .oneStepTowardRequest
    )
    let params = namedEQBandParams(value: "3")
    let cleaner: AccessibilityChannel.PluginPopupMenuCleaner = { _ in .noPopupObserved }

    let first = await AccessibilityChannel.defaultSetEQBandVerified(
        params: params,
        runtime: fixture.runtime,
        frontDocumentPath: { expectedPath },
        pluginPopupMenuCleaner: cleaner
    )
    let second = await AccessibilityChannel.defaultSetEQBandVerified(
        params: params,
        runtime: fixture.runtime,
        frontDocumentPath: { expectedPath },
        pluginPopupMenuCleaner: cleaner
    )
    let firstData = try #require(first.message.data(using: .utf8))
    let secondData = try #require(second.message.data(using: .utf8))
    let firstEnvelope = try #require(try JSONSerialization.jsonObject(
        with: firstData
    ) as? [String: Any])
    let secondEnvelope = try #require(try JSONSerialization.jsonObject(
        with: secondData
    ) as? [String: Any])

    #expect(firstEnvelope["state"] as? String == "A")
    #expect(secondEnvelope["state"] as? String == "A")
}

@Test func testOpenerReachesStateAWhenSlotPressReturnsFalseButWindowOpens() async {
    // Regression guard for the coord-removal feature-loss bug. On real Logic
    // 12.3 the slot/open-control AXPress can open the plugin window while
    // reporting a NON-ZERO AX status. The old loop did `guard pressElement …
    // else { continue }`, skipping the observed-window poll on that false
    // return, so the window that DID open was never claimed → window_open_failed.
    // The fix consults `pollOpenPluginWindow` regardless of the press return; the
    // op MUST now reach State A.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        slotPressReturnsFalse: true
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(obj["observed_normalized"] as? Double == 60)
    #expect(fixture.currentSliderValue == 60)
}

@Test func testOpenerStaysFailClosedWhenSlotPressReturnsFalseAndNoWindowOpens() async {
    // Complement: the press fires (and returns false) but NOTHING opens. The fix
    // must remain fail-closed (window_open_failed), never fabricate State A.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: false,
        slotPressReturnsFalse: true
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "window_open_failed")
    #expect(!((obj["write_attempted"] as? Bool)!))
    #expect(fixture.currentSliderValue == 51)
}

@Test func testManualPreopenFallsBackToRaisingArrangeWhenFocusedCannotBeClearedDirectly() async {
    let fixture = LiveFixture(beforeValue: 51, pluginWindowRejectsDirectDemotion: true)
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(obj["observed_normalized"] as? Double == 60)
    #expect(fixture.currentSliderValue == 60)
}

@Test func testProductionOpenerReportsOpenedNativeWindowWithoutRequestedSlider() async throws {
    let fixture = LiveFixture(
        thresholdDescription: "Output Gain",
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "param_control_not_found")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
    let observed = try #require(obj["what_was_observed"] as? String)
    #expect(observed.contains("no slider with that AX description"))
    #expect(fixture.currentSliderValue == 51)
}

@Test func testWrongObservedPluginFailsClosedBeforeWindowAcquisition() async throws {
    let fixture = LiveFixture(
        pluginSlotName: "Gain",
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "target_plugin_mismatch")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
    #expect(fixture.currentSliderValue == 51)
}

@Test func testAmbiguousSameTrackParameterWindowsFailClosed() async throws {
    let fixture = LiveFixture(beforeValue: 51)
    let b = fixture.builder
    let duplicateWindow = b.element(3000)
    let duplicateSlider = b.element(3001)
    b.setAttribute(duplicateSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(duplicateSlider, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(duplicateSlider, kAXValueAttribute as String, 51.0)
    b.setAttribute(duplicateWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(duplicateWindow, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    b.setAttribute(duplicateWindow, kAXTitleAttribute as String, trackName)
    let duplicateClose = b.element(3002)
    let duplicateBypass = b.element(3003)
    let duplicateLink = b.element(3004)
    let duplicatePluginName = b.element(3005)
    b.setAttribute(duplicateClose, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(duplicateBypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(duplicateBypass, kAXDescriptionAttribute as String, "bypass")
    b.setAttribute(duplicateLink, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(duplicateLink, kAXDescriptionAttribute as String, "link")
    b.setAttribute(duplicatePluginName, kAXRoleAttribute as String, kAXStaticTextRole as String)
    b.setAttribute(duplicatePluginName, kAXValueAttribute as String, "Compressor")
    b.setAttribute(duplicateWindow, kAXCloseButtonAttribute as String, duplicateClose)
    b.setChildren(duplicateWindow, [duplicateBypass, duplicateLink, duplicateSlider, duplicatePluginName])
    b.setAttribute(fixture.app, kAXWindowsAttribute as String, [
        b.element(1001), b.element(1004), duplicateWindow,
    ])

    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "window_identity_unresolved")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
    #expect(fixture.currentSliderValue == 51)
}

@Test func testWrongWindowIdentityFailsClosed() async throws {
    let fixture = LiveFixture(beforeValue: 51, pluginWindowPresent: false)
    let b = fixture.builder
    let wrongWindow = b.element(3100)
    let wrongSlider = b.element(3101)
    let wrongClose = b.element(3102)
    let wrongBypass = b.element(3103)
    let wrongLink = b.element(3104)
    b.setAttribute(wrongSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(wrongSlider, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(wrongSlider, kAXValueAttribute as String, 51.0)
    b.setAttribute(wrongClose, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(wrongBypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(wrongBypass, kAXDescriptionAttribute as String, "bypass")
    b.setAttribute(wrongLink, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(wrongLink, kAXDescriptionAttribute as String, "link")
    b.setAttribute(wrongWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(wrongWindow, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    b.setAttribute(wrongWindow, kAXTitleAttribute as String, trackName)
    b.setAttribute(wrongWindow, kAXCloseButtonAttribute as String, wrongClose)
    b.setAttribute(wrongWindow, kAXMainAttribute as String, true)
    b.setAttribute(wrongWindow, kAXFocusedAttribute as String, true)
    b.setChildren(wrongWindow, [wrongBypass, wrongLink, wrongSlider])
    b.setAttribute(fixture.app, kAXWindowsAttribute as String, [b.element(1001), wrongWindow])

    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "plugin_window_plugin_mismatch")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
    #expect(fixture.currentSliderValue == 51)
    #expect(b.attributeValue(wrongSlider, kAXValueAttribute as String) as? Double == 51)
}

@Test func testAmbiguousWindowAppearingAfterSlotPressFailsClosed() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true
    )
    let b = fixture.builder
    let duplicateWindow = b.element(3300)
    let duplicateSlider = b.element(3301)
    let duplicateClose = b.element(3302)
    let duplicateBypass = b.element(3303)
    let duplicateLink = b.element(3304)
    let duplicatePluginName = b.element(3305)
    b.setAttribute(duplicateSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(duplicateSlider, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(duplicateSlider, kAXValueAttribute as String, 51.0)
    b.setAttribute(duplicateClose, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(duplicateBypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(duplicateBypass, kAXDescriptionAttribute as String, "bypass")
    b.setAttribute(duplicateLink, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(duplicateLink, kAXDescriptionAttribute as String, "link")
    b.setAttribute(duplicatePluginName, kAXRoleAttribute as String, kAXStaticTextRole as String)
    b.setAttribute(duplicatePluginName, kAXValueAttribute as String, "Compressor")
    b.setAttribute(duplicateWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(duplicateWindow, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    b.setAttribute(duplicateWindow, kAXTitleAttribute as String, trackName)
    b.setAttribute(duplicateWindow, kAXCloseButtonAttribute as String, duplicateClose)
    b.setAttribute(duplicateWindow, kAXMainAttribute as String, true)
    b.setAttribute(duplicateWindow, kAXFocusedAttribute as String, true)
    b.setChildren(duplicateWindow, [duplicateBypass, duplicateLink, duplicateSlider, duplicatePluginName])
    fixture.windowsAddedOnSlotPress.value = [duplicateWindow]

    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "window_identity_unresolved")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
    #expect(fixture.currentSliderValue == 51)
    #expect(b.attributeValue(duplicateSlider, kAXValueAttribute as String) as? Double == 51)
}

@Test func testAmbiguousRequestedSlidersFailClosed() async throws {
    let fixture = LiveFixture(beforeValue: 51)
    let b = fixture.builder
    let duplicateSlider = b.element(3200)
    b.setAttribute(duplicateSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(duplicateSlider, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(duplicateSlider, kAXValueAttribute as String, 51.0)
    b.setChildren(b.element(1004), [
        b.element(1007), b.element(1008), b.element(1005), duplicateSlider,
        b.element(1011), b.element(1009),
    ])

    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "window_identity_unresolved")
    let v1 = try #require(obj["write_attempted"] as? Bool)
    #expect(!v1)
    #expect(fixture.currentSliderValue == 51)
}

@Test func testOpenerFallbackProducesStateA() async {
    // No already-open window, but the injected opener supplies one → write
    // proceeds to State A. Proves step 8b is wired.
    let fixture = LiveFixture(beforeValue: 51, pluginWindowPresent: false)
    // Build a standalone window element with the Threshold slider for the opener.
    let b = fixture.builder
    let openedWindow = b.element(2000)
    let openedSlider = b.element(2001)
    b.setAttribute(openedSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(openedSlider, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(openedSlider, kAXValueAttribute as String, 51.0)
    b.setAttribute(openedSlider, kAXValueDescriptionAttribute as String, "51 %")
    let openedClose = b.element(2002)
    let openedBypass = b.element(2003)
    let openedLink = b.element(2004)
    let openedPluginName = b.element(2005)
    let openedViewSwitcher = b.element(2006)
    b.setAttribute(openedClose, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(openedBypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(openedBypass, kAXDescriptionAttribute as String, "bypass")
    b.setAttribute(openedLink, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(openedLink, kAXDescriptionAttribute as String, "link")
    b.setAttribute(openedPluginName, kAXRoleAttribute as String, kAXStaticTextRole as String)
    b.setAttribute(openedPluginName, kAXValueAttribute as String, "Compressor")
    b.setAttribute(openedViewSwitcher, kAXRoleAttribute as String, kAXMenuButtonRole as String)
    b.setAttribute(openedViewSwitcher, kAXDescriptionAttribute as String, "보기")
    b.setAttribute(openedViewSwitcher, kAXTitleAttribute as String, "편집기")
    b.setAttribute(openedWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(openedWindow, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    b.setAttribute(openedWindow, kAXTitleAttribute as String, trackName)
    b.setAttribute(openedWindow, kAXCloseButtonAttribute as String, openedClose)
    b.setAttribute(openedWindow, kAXMainAttribute as String, true)
    b.setAttribute(openedWindow, kAXFocusedAttribute as String, true)
    b.setChildren(openedWindow, [
        openedBypass, openedLink, openedSlider, openedPluginName, openedViewSwitcher,
    ])
    b.setAttribute(fixture.app, kAXWindowsAttribute as String, [b.element(1001), openedWindow])
    let sendable = AXUIElementSendable(openedWindow)

    let obj = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        opener: { _, pluginID, name, desc, _ in
            (pluginID == "logic.stock.effect.compressor" && name == trackName && desc == "Threshold")
                ? sendable
                : nil
        }
    )
    #expect(obj["state"] as? String == "A", "opener-supplied window must allow the write")
    #expect(obj["observed_normalized"] as? Double == 60)
}

// MARK: - State C: slider not found → param_control_not_found

@Test func testWindowWithoutMatchingSliderIsParamControlNotFound() async {
    // The window exists and is titled with the track name, but its only slider
    // carries a DIFFERENT description, so the "already open" lookup skips it AND
    // the opener returns a window whose slider still cannot be matched.
    let fixture = LiveFixture(thresholdDescription: "슬라이더", beforeValue: 51, pluginWindowPresent: true)
    // openPluginWindow requires BOTH title match AND matching slider — with a
    // non-matching slider the already-open lookup fails, so route through an
    // opener that returns the very same (non-matching) window to reach step 9.
    let b = fixture.builder
    let mismatchWindow = b.element(2100)
    let mismatchSlider = b.element(2101)
    b.setAttribute(mismatchSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(mismatchSlider, kAXDescriptionAttribute as String, "슬라이더")
    b.setAttribute(mismatchWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(mismatchWindow, kAXTitleAttribute as String, trackName)
    b.setChildren(mismatchWindow, [mismatchSlider])
    let sendable = AXUIElementSendable(mismatchWindow)

    let obj = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        opener: { _, _, _, _, _ in sendable }
    )
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "param_control_not_found")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - State C: track not selectable → track_selection_failed

@Test func testTrackNotVerifiedSelectedIsTrackSelectionFailed() async {
    // Header never reads back as AXSelected → step-6 verification fails.
    let fixture = LiveFixture(trackSelected: false, beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams())
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "track_selection_failed")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - State C: target insert empty → incomplete_inventory

@Test func testEmptyTargetSlotIsIncompleteInventory() async {
    // insert 6 is occupied in the fixture; request insert 0 which is also
    // occupied. To hit "empty target", ask for a slot beyond the occupied chain.
    let fixture = LiveFixture(insert: 3) // slots 0..3 occupied
    let obj = await runLive(fixture: fixture, params: thresholdParams(insert: 5))
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "incomplete_inventory")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - #234 zero-slot slot-addressing diagnostics (AC-5)

@Test func testSetParamVerifiedZeroSlotsStateCDistinctDiagnostics() async {
    // A zero-slot (Master-shaped) target strip through set_param_verified's slot-
    // addressing guard. Pre-#234 the guard reported the bare "insert N is out of
    // range (0 slots)"; now it names the insert_section_not_enumerable condition
    // and carries the recovery hint. Still State C with its existing
    // incomplete_inventory code — the write path never softens to State B — and no
    // write is attempted.
    let fixture = LiveFixture(beforeValue: 51, emptyInsertChain: true)
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "incomplete_inventory")
    #expect(!((obj["write_attempted"] as? Bool)!))
    let observed = (obj["what_was_observed"] as? String) ?? ""
    #expect(observed.contains("no enumerable insert slots"))
    let hint = (obj["recovery_hint"] as? String) ?? ""
    #expect(hint.contains("Master"))
    #expect(fixture.currentSliderValue == 51, "no write may occur when the slot cannot be addressed")
}

// MARK: - Other parameter (Gain) stays unsupported (no write)

@Test func testGainStillUnsupportedNoWrite() async {
    let fixture = LiveFixture()
    let obj = await runLive(fixture: fixture, params: [
        "track": "0", "insert": "6", "plugin": "Gain", "param": "gain_db",
        "value": "-4", "unit": "dB", "mode": "duplicate_applyback",
        "project_expected_path": expectedPath,
    ])
    #expect(obj["error"] as? String == "unsupported_param_readback")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - Precedence: wrong unit / out-of-range still beat the live write

@Test func testThresholdWrongUnitIsInvalidParamsBeforeWrite() async {
    let fixture = LiveFixture()
    let obj = await runLive(fixture: fixture, params: thresholdParams(unit: "dB"))
    #expect(obj["error"] as? String == "invalid_params")
}

@Test func testThresholdOutOfRangeIsInvalidParamsBeforeWrite() async {
    let fixture = LiveFixture()
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "150"))
    #expect(obj["error"] as? String == "invalid_params")
    #expect(fixture.currentSliderValue == 51, "no write may occur on a range violation")
}

@Test func testThresholdConfirmedLiveBlockedBeforeWrite() async {
    let fixture = LiveFixture()
    let obj = await runLive(fixture: fixture, params: thresholdParams(mode: "confirmed_live"))
    #expect(obj["error"] as? String == "unsupported_mode")
    #expect(fixture.currentSliderValue == 51)
}

// MARK: - A fixture whose slider is sticky on the FIRST write only

/// Models a slider that lands the FIRST write at `firstWriteLandsAt` (forcing a
/// mismatch) but honours every subsequent write (so the rollback to `before`
/// confirms). Lets us assert rollback_succeeded:true distinctly from the
/// permanently-sticky case.
private final class OneShotStickyFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let runtime: AXLogicProElements.Runtime
    private let writeCount = Counter()

    init(beforeValue: Double, firstWriteLandsAt: Double) {
        let b = builder
        let app = b.element(3000)
        let arrangeWindow = b.element(3001)
        let headersGroup = b.element(3002)
        let mixer = b.element(3003)
        let pluginWindow = b.element(3004)
        let slider = b.element(3005)

        let row = b.element(3100)
        b.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setAttribute(row, kAXDescriptionAttribute as String, "1개의 ‘\(trackName)’ 트랙")
        b.setAttribute(row, kAXSelectedAttribute as String, true)
        b.setAttribute(headersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(headersGroup, kAXDescriptionAttribute as String, "트랙 헤더")
        b.setChildren(headersGroup, [row])

        let strip = b.element(3200)
        b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        var slots: [AXUIElement] = []
        for s in 0...6 {
            let g = b.element(3300 + s)
            let by = b.element((3300 + s) * 10 + 1)
            let op = b.element((3300 + s) * 10 + 2)
            b.setAttribute(g, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(g, kAXDescriptionAttribute as String, s == 6 ? "Compressor" : "P\(s)")
            b.setChildren(g, [by, op])
            b.setAttribute(by, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            b.setAttribute(by, kAXDescriptionAttribute as String, "바이패스")
            b.setAttribute(by, kAXValueAttribute as String, 0)
            b.setAttribute(op, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(op, kAXDescriptionAttribute as String, "열기")
            slots.append(g)
        }
        b.setChildren(strip, slots)
        b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(mixer, [strip])

        b.setAttribute(arrangeWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setChildren(arrangeWindow, [headersGroup, mixer])

        b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(slider, kAXDescriptionAttribute as String, "Threshold")
        b.setAttribute(slider, kAXValueAttribute as String, beforeValue)
        b.setAttribute(slider, kAXValueDescriptionAttribute as String, "\(Int(beforeValue)) %")
        b.setAttribute(pluginWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(pluginWindow, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(pluginWindow, kAXTitleAttribute as String, trackName)
        let pluginClose = b.element(3006)
        let pluginBypass = b.element(3007)
        let pluginLink = b.element(3008)
        let pluginName = b.element(3009)
        let viewSwitcher = b.element(3010)
        b.setAttribute(pluginClose, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(pluginBypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(pluginBypass, kAXDescriptionAttribute as String, "bypass")
        b.setAttribute(pluginLink, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(pluginLink, kAXDescriptionAttribute as String, "link")
        b.setAttribute(pluginName, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setAttribute(pluginName, kAXValueAttribute as String, "Compressor")
        b.setAttribute(viewSwitcher, kAXRoleAttribute as String, kAXMenuButtonRole as String)
        b.setAttribute(viewSwitcher, kAXDescriptionAttribute as String, "보기")
        b.setAttribute(viewSwitcher, kAXTitleAttribute as String, "편집기")
        b.setAttribute(pluginWindow, kAXCloseButtonAttribute as String, pluginClose)
        b.setAttribute(pluginWindow, kAXMainAttribute as String, true)
        b.setAttribute(pluginWindow, kAXFocusedAttribute as String, true)
        b.setChildren(pluginWindow, [pluginBypass, pluginLink, slider, pluginName, viewSwitcher])

        b.setAttribute(app, kAXWindowsAttribute as String, [arrangeWindow, pluginWindow])
        b.setAttribute(app, kAXMainWindowAttribute as String, arrangeWindow)

        let sliderKey = b.elementID(slider)
        let counter = writeCount
        self.runtime = b.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { [b] el, attribute, value in
                guard b.elementID(el) == sliderKey, attribute == (kAXValueAttribute as String) else {
                    b.setAttribute(el, attribute, value)
                    return true
                }
                let requested = (value as? NSNumber)?.doubleValue ?? 0
                let n = counter.next()
                let landed = n == 1 ? firstWriteLandsAt : requested
                b.setAttribute(el, kAXValueAttribute as String, landed)
                b.setAttribute(el, kAXValueDescriptionAttribute as String, "\(Int(landed.rounded())) %")
                return true
            },
            performActionHandler: { [b] _, action in
                guard action == (kAXPressAction as String) else { return true }
                b.setAttribute(pluginWindow, kAXMainAttribute as String, true)
                b.setAttribute(pluginWindow, kAXFocusedAttribute as String, true)
                return true
            }
        )
    }

    var currentSliderValue: Double? {
        builder.attributeValue(builder.element(3005), kAXValueAttribute as String) as? Double
    }
}

/// Tiny serial counter for the one-shot fixture (the AX runtime closure is
/// @Sendable so a class with a lock keeps it Sendable-safe under --no-parallel).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}

// MARK: - #726 the operation closes the editor it opened

@Test func testDuplicateAcquisitionClosesTheEditorItOpened() async throws {
    // Measured live: writing insert 0 then insert 2 on a two-Compressor track
    // failed on the second call with duplicate_plugin_editor_already_open,
    // because the first call left its editor open. The operation opened that
    // window from a known-empty state, so it owns closing it.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
    let closeObserved = try #require(obj["editor_close_observed"] as? Bool)
    #expect(closeObserved)
    #expect(fixture.pluginCloseControlPressCount.value == 1)
    #expect(AXLogicProElements.matchingPluginEditorWindows(
        forTrackName: trackName,
        matchingPluginID: "logic.stock.effect.compressor",
        runtime: fixture.runtime
    ).isEmpty)
}

@Test func testReusedEditorIsNotClosedByTheOperation() async {
    // The single-instance path reuses an editor the caller already had open.
    // Closing it would destroy state this operation never created — a worse
    // defect than the one the close exists to fix.
    let fixture = LiveFixture(beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.pluginCloseControlPressCount.value == 0)
    #expect(!AXLogicProElements.matchingPluginEditorWindows(
        forTrackName: trackName,
        matchingPluginID: "logic.stock.effect.compressor",
        runtime: fixture.runtime
    ).isEmpty)
}

@Test func testAnUnverifiableCloseDoesNotChangeTheWriteVerdict() async throws {
    // The write's verdict is established before the close is attempted. A close
    // that cannot be observed must not turn a verified write into a failure —
    // the leftover editor announces itself on the NEXT call as
    // duplicate_plugin_editor_already_open, which carries the recovery hint.
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]],
        pluginCloseControlFailsToClose: true
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
    let closeObserved = try #require(obj["editor_close_observed"] as? Bool)
    let editorStillOpen = try #require(obj["editor_still_open"] as? Bool)
    #expect(!closeObserved)
    #expect(editorStillOpen)
    let recoveryHint = try #require(obj["recovery_hint"] as? String)
    #expect(recoveryHint.contains("Close it before another duplicate-instance write"))
    // Tried, and retried, rather than giving up after one press.
    #expect(fixture.pluginCloseControlPressCount.value == 3)
}

@Test func testAlreadyOpenDuplicateRefusalCarriesARecoveryHint() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["error"] as? String == "duplicate_plugin_editor_already_open")
    let hint = try #require(obj["recovery_hint"] as? String)
    #expect(hint.contains("Close the open"))
}
