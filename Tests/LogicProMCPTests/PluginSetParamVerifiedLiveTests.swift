@preconcurrency import ApplicationServices
import Foundation
import MCP
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
    /// The first post-press value is mixed; a blind second press would land on
    /// `true` rather than the original `false`.
    case mixedThenChanged
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
    /// Every attribute write and action that reached the two handlers, in order, as
    /// (element id, attribute or action name). The counters above cover named elements only.
    let axActions = MutableBox<[(element: Int, name: String)]>([])
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
        mixerAuxCountBeforeTarget: Int = 0,
        duplicateTrackNameAt: Int? = nil,
        pluginSlotNamesByTrack: [Int: [Int: String]] = [:],
        emptyInsertChain: Bool = false,
        // #982: the children read of the Mixer, or of the target strip, fails through both seams.
        mixerChildrenUnread: Bool = false,
        mixerByIdentifier: Bool = false,
        targetStripChildrenUnread: Bool = false,
        pluginWindowRejectsDirectDemotion: Bool = false,
        slotPressReturnsFalse: Bool = false,
        sliderWriteBehavior: SliderWriteBehavior = .direct,
        rejectSliderWrites: Bool = false,
        rejectSliderInverseAcknowledgement: Bool = false,
        sliderDisplayUnit: String = "%",
        sliderDisplayRoundsDown: Bool = false,
        sliderUsesSignedPositiveDisplay: Bool = false,
        onSliderDisplayAfterWrite: (@Sendable (FakeAXRuntimeBuilder, AXUIElement) -> Void)? = nil,
        onSliderAttributeRead: (@Sendable (FakeAXRuntimeBuilder, AXUIElement, String, Int) -> Void)? = nil,
        pluginWindowStaticTextValues: [String]? = nil,
        pluginWindowTitleReadFails: Bool = false,
        pluginWindowsReadStatusBeforeTargetOpen: AXHelpers.AXStatusError? = nil,
        nonPluginWindowSubroleReadStatus: AXHelpers.AXStatusError? = nil,
        sliderDescriptionReadStatuses: MutableBox<[Int: AXHelpers.AXStatusError]>? = nil,
        pluginWindowStaticTextValueReadStatuses: MutableBox<[Int: AXHelpers.AXStatusError]>? = nil,
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
        viewMenuDuplicatesOnReveal: Bool = false,
        viewMenuOmitsEditorItem: Bool = false,
        viewMenuEditorItemEnabled: Bool = true,
        viewSettleDelay: TimeInterval = 0.5,
        onTrackHeaderPress: (@Sendable (FakeAXRuntimeBuilder, Int) -> Void)? = nil
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
        let duplicateControlsViewMenu = b.element(100_914)
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
            let nameField = b.element(150_000 + i)
            b.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(nameField, kAXDescriptionAttribute as String, "이름")
            b.setAttribute(nameField, kAXValueAttribute as String,
                           i == track || i == duplicateTrackNameAt ? trackDisplayName : "Other \(i)")
            if i == track {
                if emptyInsertChain {
                    // #234 — a Master/VCA-shaped target strip that exposes zero
                    // enumerable insert slots, to exercise the slot-addressing
                    // guard's zero-slot branch.
                    let noInsertChildren = masterShapedStripChildren(b, base: 1500)
                    b.setAttribute(noInsertChildren[0], kAXValueAttribute as String, trackDisplayName)
                    b.setChildren(strip, noInsertChildren)
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
            b.setChildren(strip, [nameField] + b.makeAXRuntime().children(strip))
            if i == track {
                for aux in 0..<mixerAuxCountBeforeTarget {
                    let auxStrip = b.element(160_000 + aux)
                    let auxName = b.element(161_000 + aux)
                    b.setAttribute(auxStrip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
                    b.setAttribute(auxName, kAXRoleAttribute as String, kAXTextFieldRole as String)
                    b.setAttribute(auxName, kAXDescriptionAttribute as String, "이름")
                    b.setAttribute(auxName, kAXValueAttribute as String, "Aux \(aux + 1)")
                    b.setChildren(auxStrip, [auxName, LiveFixture.emptySlot(b, 162_000 + aux)])
                    strips.append(auxStrip)
                }
            }
            strips.append(strip)
        }
        if mixerChildrenUnread, mixerByIdentifier {
            // The older shape. Logic 12.2 and 12.3 show the layout area below, with no identifier.
            b.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
        } else {
            b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
            b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        }
        b.setChildren(mixer, strips)
        let unreadChildrenOf: AXUIElement? = mixerChildrenUnread
            ? mixer : (targetStripChildrenUnread ? strips[track] : nil)

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
            let displayed = sliderDisplayRoundsDown ? value.rounded(.down) : value.rounded()
            return "\(sign)\(Int(displayed)) \(sliderDisplayUnit)"
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
        b.setAttribute(controlsViewMenuItem, kAXEnabledAttribute as String, true)
        b.setRole(editorViewMenuItem, kAXMenuItemRole as String)
        b.setAttribute(editorViewMenuItem, kAXTitleAttribute as String, "편집기")
        b.setAttribute(editorViewMenuItem, kAXEnabledAttribute as String, viewMenuEditorItemEnabled)
        let viewMenuItems = viewMenuOmitsEditorItem
            ? [controlsViewMenuItem]
            : [controlsViewMenuItem, editorViewMenuItem]
        b.setChildren(controlsViewMenu, viewMenuItems)
        b.setRole(duplicateControlsViewMenu, kAXMenuRole as String)
        b.setChildren(duplicateControlsViewMenu, viewMenuItems)
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
        let selectionHeaderRows = headerRows
        let forced = forcedAfterValue
        let writeBehavior = sliderWriteBehavior
        let pluginWindowsReadStatusBeforeTargetOpen = pluginWindowsReadStatusBeforeTargetOpen
        let nonPluginWindowSubroleReadStatus = nonPluginWindowSubroleReadStatus
        let menuOpen = MutableBox(false)
        let menuVisible = MutableBox(false)
        let menuCensusPolls = MutableBox(0)
        let pendingPluginWindowChildren = MutableBox<(children: [AXUIElement], settlesAt: Date)?>(nil)
        let runtime = b.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                if CFEqual(element, slider) {
                    onSliderAttributeRead?(b, slider, attribute, sliderWriteCount.value)
                }
                if CFEqual(element, slider), attribute == (kAXValueDescriptionAttribute as String),
                   sliderWriteCount.value > 0 {
                    onSliderDisplayAfterWrite?(b, slider)
                }
                return nil
            },
            attributeValueResultHandler: { element, attribute in
                if CFEqual(element, slider) {
                    onSliderAttributeRead?(b, slider, attribute, sliderWriteCount.value)
                }
                if let status = pluginWindowsReadStatusBeforeTargetOpen,
                   CFEqual(element, app),
                   attribute == (kAXWindowsAttribute as String),
                   targetOpenControlPressCount.value == 0 {
                    return .failure(status)
                }
                if let status = nonPluginWindowSubroleReadStatus,
                   CFEqual(element, arrangeWindow),
                   attribute == (kAXSubroleAttribute as String) {
                    return .failure(status)
                }
                if pluginWindowTitleReadFails,
                   CFEqual(element, pluginWindow),
                   attribute == (kAXTitleAttribute as String) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if let status = sliderDescriptionReadStatuses?.value[b.elementID(element)],
                   attribute == (kAXDescriptionAttribute as String) {
                    return .failure(status)
                }
                if let status = pluginWindowStaticTextValueReadStatuses?.value[b.elementID(element)],
                   attribute == (kAXValueAttribute as String) {
                    return .failure(status)
                }
                return nil
            },
            childrenHandler: { element in
                if let unreadChildrenOf, CFEqual(element, unreadChildrenOf) {
                    return []
                }
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
                if let unreadChildrenOf, CFEqual(element, unreadChildrenOf) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
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
                    return .success(viewMenuDuplicatesOnReveal
                        ? [controlsViewMenu, duplicateControlsViewMenu]
                        : [controlsViewMenu]
                    )
            },
            setAttributeHandler: { [b, axActions] el, attribute, value in
                // The selection ladder's first two rungs decline in this fixture. Its existing
                // AXPress handler owns selection and the interleavings exercised below.
                if attribute == kAXSelectedChildrenAttribute as String || attribute == kAXSelectedAttribute as String {
                    return false
                }
                axActions.value.append((b.elementID(el), attribute))
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
                if rejectSliderInverseAcknowledgement, writeIndex > 0 { return false }
                return true
            },
            performActionHandler: { [b, axActions] el, action in
                axActions.value.append((b.elementID(el), action))
                if pluginWindowRejectsDirectDemotion,
                   b.elementID(el) == b.elementID(arrangeWindow),
                   action == (kAXRaiseAction as String) {
                    b.setAttribute(pluginWindow, kAXMainAttribute as String, false)
                    b.setAttribute(pluginWindow, kAXFocusedAttribute as String, false)
                    return true
                }
                let key = b.elementID(el)
                if action == (kAXPressAction as String),
                   let ordinal = selectionHeaderRows.firstIndex(where: { CFEqual($0, el) }) {
                    // elementID is pointer-backed, not the creation ID supplied
                    // to element(_:). Match the AX element before naming its row.
                    onTrackHeaderPress?(b, 1100 + ordinal)
                }
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
                    if controlsCheckboxWriteBehavior == .mixedThenChanged {
                        if controlsCheckboxPressCount.value == 1 {
                            b.setAttribute(controlsCheckbox, kAXValueAttribute as String, NSNumber(value: 2))
                        } else {
                            b.setAttribute(controlsCheckbox, kAXValueAttribute as String, true)
                        }
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
        // Inserts are numbered in screen order, so a chain of several needs frames: one row per
        // slot, top-down in the order the ids give them (`id % 100` is the slot's position).
        b.setAttribute(group, kAXPositionAttribute as String, axPoint(100, 300 + CGFloat(id % 100) * 20))
        b.setAttribute(group, kAXSizeAttribute as String, axSize(58, 16))
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

@Test(arguments: ["75", "60.5", "unknown", "nonfinite", "gate", "cancellation", "deadline"])
func testForwardWriteDoesNotOverwriteItsChangedBeforeValue(_ fault: String) async throws {
    let retainedBefore = MutableBox<Double?>(nil)
    let injected = MutableBox(false)
    let zeroSettersAtInjection = MutableBox(false)
    let fixture = LiveFixture(beforeValue: 60, onSliderAttributeRead: { builder, slider, attribute, writes in
        guard writes == 0 else { return }
        if attribute == (kAXValueAttribute as String), retainedBefore.value == nil {
            retainedBefore.value = builder.attributeValue(slider, attribute) as? Double
        }
        guard attribute == (kAXDescriptionAttribute as String), retainedBefore.value != nil,
              !injected.value else { return }
        // The engine already read its numeric before-state. This later identity
        // read retains the SAME description, slot, editor and control CFs.
        injected.value = true
        zeroSettersAtInjection.value = writes == 0
        if let value = Double(fault) {
            builder.setAttribute(slider, kAXValueAttribute as String, value)
        } else if fault == "unknown" {
            builder.setAttribute(slider, kAXValueAttribute as String, NSNull())
        } else if fault == "nonfinite" {
            builder.setAttribute(slider, kAXValueAttribute as String, Double.nan)
        }
    })
    let context = OperationTraceContext(mutationGateAcquired: true,
        ownsGate: { fault != "gate" || !injected.value },
        deadline: fault == "deadline" ? ContinuousClock.now.advanced(by: .seconds(-1)) : nil,
        cancellationRequested: { fault == "cancellation" && injected.value })
    let result = await OperationTraceContext.$current.withValue(context) {
        await runLive(fixture: fixture, params: thresholdParams(value: "38"))
    }
    #expect(retainedBefore.value == 60)
    #expect(injected.value)
    #expect(zeroSettersAtInjection.value)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(result["state"] as? String == "C")
    if let value = Double(fault) { #expect(fixture.currentSliderValue == value) }
    else if fault == "unknown" { #expect(fixture.currentSliderValue == nil) }
    else if fault == "nonfinite" {
        let current = try #require(fixture.currentSliderValue)
        #expect(current.isNaN)
    } else { #expect(fixture.currentSliderValue == 60) }
    let attempted = try #require(result["write_attempted"] as? Bool)
    #expect(!attempted)
}

@Test func testForwardWriteWithStableBeforeStillSetsRequestedValue() async throws {
    let fixture = LiveFixture(beforeValue: 60)
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "38"))
    #expect(result["state"] as? String == "A")
    #expect(fixture.sliderWriteCount.value == 1)
    #expect(fixture.currentSliderValue == 38)
}

@Test func testSagaApprovedThresholdBeforeIsCheckedByTheActualWriter() async throws {
    let fixture = LiveFixture(beforeValue: 75)
    let expected = PluginSagaExpectedBefore(track: 0, insert: 6, projectPath: expectedPath,
        param: "threshold", observed: .double(60))
    let result = await PluginSagaExpectedBefore.$current.withValue(expected) {
        await runLive(fixture: fixture, params: thresholdParams(value: "38"))
    }
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.currentSliderValue == 75)
    #expect(result["state"] as? String == "C")
    let attempted = try #require(result["write_attempted"] as? Bool)
    #expect(!attempted)
}

@Test(arguments: ["frequency", "gain"])
func testSelectedEQApprovedRawBeforeIsCheckedByTheActualWriter(_ parameter: String) async throws {
    let label = parameter == "frequency" ? "Frequency" : "Gain"
    for (approved, state, count) in [(1.0, "C", 0), (0.0, "A", 3)] {
        let fixture = LiveFixture(thresholdDescription: "Peak 1 \(label)", pluginSlotName: "Channel EQ",
            beforeValue: 0, sliderWriteBehavior: .oneStepTowardRequest)
        let expected = PluginSagaExpectedBefore(track: 0, insert: 6, projectPath: expectedPath,
            param: "peak_1_\(parameter)", observed: .double(approved), pluginID: "logic.stock.effect.channel_eq")
        let result = await PluginSagaExpectedBefore.$current.withValue(expected) {
            await AccessibilityChannel.defaultSetEQBandVerified(params: namedEQBandParams(parameter: label),
                runtime: fixture.runtime, frontDocumentPath: { expectedPath },
                pluginPopupMenuCleaner: { _ in .noPopupObserved })
        }
        #expect(fixture.sliderWriteCount.value == count)
        #expect(fixture.currentSliderValue == Double(count))
        let body = try #require(decodedJSONObject(result.message))
        #expect(body["state"] as? String == state)
        if state == "C" {
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
        }
    }
}

@Test func testSagaApprovedLimiterBeforeIsCheckedBeforeTheActualCheckboxPress() async throws {
    let fixture = LiveFixture(controlsViewRowLabel: "Limiter On", controlsCheckboxBefore: true,
        controlsViewInitiallySelected: true)
    let expected = PluginSagaExpectedBefore(track: 0, insert: 6, projectPath: expectedPath,
        param: "limiter_on", observed: .bool(false))
    let result = await PluginSagaExpectedBefore.$current.withValue(expected) {
        await runLive(fixture: fixture, params: controlsBooleanParams())
    }
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    let current = try #require(fixture.builder.attributeValue(fixture.builder.element(100_908), kAXValueAttribute as String) as? Bool)
    #expect(current)
    #expect(result["state"] as? String == "C")
    let attempted = try #require(result["write_attempted"] as? Bool)
    #expect(!attempted)
}

@Test(arguments: ["threshold", "limiter_on"])
func testSagaMatchingApprovedBeforeReachesItsActualParameterMutation(_ param: String) async throws {
    let fixture = param == "threshold" ? LiveFixture(beforeValue: 60)
        : LiveFixture(controlsViewRowLabel: "Limiter On", controlsViewInitiallySelected: true)
    let expected = PluginSagaExpectedBefore(track: 0, insert: 6, projectPath: expectedPath,
        param: param, observed: param == "threshold" ? .double(60) : .bool(false))
    let params = param == "threshold" ? thresholdParams(value: "38") : controlsBooleanParams()
    let result = await PluginSagaExpectedBefore.$current.withValue(expected) {
        await runLive(fixture: fixture, params: params)
    }
    #expect(result["state"] as? String == "A")
    if param == "threshold" {
        #expect(fixture.sliderWriteCount.value == 1)
        #expect(fixture.currentSliderValue == 38)
    } else {
        #expect(fixture.controlsCheckboxPressCount.value == 1)
        let current = try #require(fixture.builder.attributeValue(fixture.builder.element(100_908), kAXValueAttribute as String) as? Bool)
        #expect(current)
    }
}

@Test func testFirstIncrementNudgeDoesNotOverwriteAChangedEntryReading() async throws {
    let reads = MutableBox(0)
    let injected = MutableBox(false)
    let zeroSettersAtInjection = MutableBox(false)
    let fixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription, pluginSlotName: "Channel EQ",
        beforeValue: 0, sliderWriteBehavior: .oneStepTowardRequest,
        onSliderAttributeRead: { builder, slider, attribute, writes in
            guard writes == 0 else { return }
            if attribute == (kAXValueAttribute as String) { reads.value += 1 }
            if attribute == (kAXValueDescriptionAttribute as String), reads.value >= 2, !injected.value {
                // The walk's entry numeric reading is retained before its display
                // is read. An external edit happens before the FIRST nudge.
                injected.value = true
                zeroSettersAtInjection.value = writes == 0
                builder.setAttribute(slider, kAXValueAttribute as String, 7.0)
            }
        }
    )
    let result = try await runChannelEQFixture(fixture: fixture,
        params: channelEQFixtureParams(value: "3", unit: "raw_ax_value"),
        writeMethod: "ax_slider_increment_walk")
    #expect(reads.value >= 2)
    #expect(injected.value)
    #expect(zeroSettersAtInjection.value)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.currentSliderValue == 7)
    #expect(result["state"] as? String == "C")
    let attempted = try #require(result["write_attempted"] as? Bool)
    #expect(!attempted)
}

@Test func testVerifiedParameterBindsArrangeNineToMixerElevenPastTwoAuxes() async {
    let fixture = LiveFixture(track: 9, trackDisplayName: "Bass", mixerAuxCountBeforeTarget: 2)
    let obj = await runLive(fixture: fixture, params: thresholdParams(track: 9))
    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 60)
    #expect(fixture.sliderWriteCount.value == 1)
    let identity = obj["target_identity"] as? [String: Any]
    #expect(identity?["track_index"] as? Int == 9)
}

@Test func testThresholdPercentAliasKeepsRawHalfPercentAndReportsRoundedDisplay() async {
    let fixture = LiveFixture(sliderDisplayRoundsDown: true)
    let obj = await runLive(fixture: fixture, params: thresholdParams(value: "0.5", unit: "percent"))
    #expect(obj["state"] as? String == "A")
    #expect(fixture.currentSliderValue == 0.5)
    #expect(obj["requested_normalized"] as? Double == 0.5)
    #expect(obj["observed_normalized"] as? Double == 0.5)
    #expect(obj["observed_display"] as? String == "0 %")
    #expect(obj["tolerance"] as? Double == 1)
}

@Test func testThresholdPercentAliasesDoNotConvertThirtyEightToFractionOrDB() async {
    for unit in ["percent", "%", "normalized"] {
        let fixture = LiveFixture()
        let obj = await runLive(fixture: fixture, params: thresholdParams(value: "38", unit: unit))
        #expect(obj["state"] as? String == "A")
        #expect(fixture.currentSliderValue == 38)
        #expect(obj["observed_display"] as? String == "38 %")
    }
}

@Test func testThresholdPercentRequestOutsideRawScaleNeverWrites() async {
    for value in ["-1", "101"] {
        let fixture = LiveFixture()
        let obj = await runLive(fixture: fixture, params: thresholdParams(value: value, unit: "percent"))
        #expect(obj["state"] as? String == "C")
        #expect(fixture.sliderWriteCount.value == 0)
    }
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

@Test func testPluginViewRefusalNamesTheMenuNeverAppearedPhase() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        viewMenuRevealAfterPolls: nil
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let phase = try #require(result["plugin_view_switch_phase"] as? String)
    let writeAttempted = try #require(result["write_attempted"] as? Bool)
    let namesTheObservedPhase = phase == "menu_never_appeared"
    let refusedBeforeWrite = !writeAttempted
    // Mutation: drop the menu-appearance diagnostic mapping.
    #expect(namesTheObservedPhase)
    #expect(refusedBeforeWrite)
}

@Test func testPluginViewRefusalNamesTheMenuAmbiguousPhase() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        viewMenuRevealAfterPolls: 0,
        viewMenuDuplicatesOnReveal: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let phase = try #require(result["plugin_view_switch_phase"] as? String)
    let namesTheObservedPhase = phase == "menu_ambiguous"
    // Mutation: drop the scoped-menu ambiguity diagnostic mapping.
    #expect(namesTheObservedPhase)
}

@Test func testPluginViewRefusalNamesTheItemNotFoundPhase() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        viewMenuRevealAfterPolls: 0,
        viewMenuOmitsEditorItem: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let phase = try #require(result["plugin_view_switch_phase"] as? String)
    let namesTheObservedPhase = phase == "item_not_found"
    // Mutation: drop the scoped-item-not-found diagnostic mapping.
    #expect(namesTheObservedPhase)
}

@Test func testPluginViewRefusalNamesTheItemNotEnabledPhase() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        viewMenuRevealAfterPolls: 0,
        viewMenuEditorItemEnabled: false
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let phase = try #require(result["plugin_view_switch_phase"] as? String)
    let namesTheObservedPhase = phase == "item_not_enabled"
    // Mutation: drop the AXEnabled refusal diagnostic mapping.
    #expect(namesTheObservedPhase)
}

@Test func testPluginViewRefusalNamesThePostPickStructurePhaseAndDeadlineSnapshot() async throws {
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        viewMenuPressChangesStructure: false,
        viewMenuRevealAfterPolls: 0
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let phase = try #require(result["plugin_view_switch_phase"] as? String)
    let tables = try #require(result["plugin_view_structure_table_count"] as? Int)
    let rows = try #require(result["plugin_view_structure_row_count"] as? Int)
    let describedSliders = try #require(result["plugin_view_structure_described_slider_count"] as? Int)
    let waitedMilliseconds = try #require(result["plugin_view_structure_waited_ms"] as? Int)
    let restorationAttempted = try #require(result["plugin_view_restore_attempted"] as? Bool)
    let restorationObserved = try #require(result["plugin_view_restore_observed"] as? Bool)
    let namesTheObservedPhase = phase == "pick_performed_structure_never_confirmed"
    let capturesDeadlineClassifierState = tables == 1
        && rows == 2
        && describedSliders == 0
        && waitedMilliseconds >= 2_900
    let entryViewRestorationSurvived = restorationAttempted && restorationObserved
    // Mutation: omit `failure.responseDiagnostics` from the State-C envelope.
    #expect(namesTheObservedPhase)
    #expect(capturesDeadlineClassifierState)
    #expect(entryViewRestorationSurvived)
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
    // Was `Ansicht`, which German Logic actually uses -- so this case asserted a refusal that
    // existed only because `pluginWindowViewSwitcher` had not been widened yet. #892 derived it
    // from the row Apple keys the View control under, and `Ansicht` is one of that row's values
    // (three of the four rows whose English is `View` agree on it, and it is also what this
    // repository read off a running German Logic). The refusal is real for a description that is
    // NOT one of Apple's spellings, so the fixture uses one: `Anzeigen` is the fourth row's German
    // for `View` and is not what this control is called -- a near miss chosen to look right.
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        pluginWindowViewSwitcherDescription: "Anzeigen"
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

@Test func testCompressorThresholdAcceptsTheGermanViewSwitcherApplePublishes() async throws {
    // The other half of the case above: a description Apple DOES ship for this control must not
    // refuse as an unmeasured locale. Before #892 it did, because the LabelSet carried three
    // languages and German was not one of the three the plug-in path had been given.
    let fixture = LiveFixture(
        controlsViewInitiallySelected: true,
        pluginWindowViewSwitcherDescription: "Ansicht"
    )
    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let observed = (result["what_was_observed"] as? String) ?? ""
    #expect(!observed.contains("not measured for this locale"),
            "a German Logic's own View spelling must not read as an unmeasured locale")
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

@Test func testCompressorControlsViewStatusZeroUnchangedReadbackRefusesWithoutASecondPress() async throws {
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
    let noCompensatingPressWasSent = fixture.controlsCheckboxPressCount.value == 1
    #expect(error == "readback_mismatch")
    #expect(!restoreAttempted)
    #expect(restoreObserved)
    #expect(writeAttempted)
    #expect(statusOnlyWasNotSuccess)
    #expect(noCompensatingPressWasSent)
}

@Test func testControlsViewCheckboxAlreadyAtRequestedValueIsVerifiedWithoutActuation() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: true
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let state = try #require(result["state"] as? String)
    let verified = try #require(result["verified"] as? Bool)
    let observed = try #require(result["observed_boolean"] as? Bool)
    let writeAttempted = try #require(result["write_attempted"] as? Bool)
    let noCheckboxPress = fixture.controlsCheckboxPressCount.value == 0
    #expect(state == "A")
    #expect(verified)
    #expect(observed)
    #expect(!writeAttempted)
    #expect(noCheckboxPress)
}

@Test func testUnknownCheckboxReadbackDoesNotClaimAChangedOrRestoredParameter() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On",
        controlsCheckboxBefore: false,
        controlsCheckboxWriteBehavior: .mixedThenChanged
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())

    let state = try #require(result["state"] as? String)
    let restoreAttempted = try #require(result["restore_attempted"] as? Bool)
    let safeToRetry = try #require(result["safe_to_retry"] as? Bool)
    let onlyTheInitialPressWasSent = fixture.controlsCheckboxPressCount.value == 1
    #expect(state == "C")
    #expect(result["parameter_left_changed"] is NSNull)
    #expect(result["restore_observed"] is NSNull)
    #expect(result["restore_observed_boolean"] is NSNull)
    #expect(!restoreAttempted)
    #expect(!safeToRetry)
    #expect(onlyTheInitialPressWasSent)
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
    let noBlindInverseWasSent = fixture.controlsCheckboxPressCount.value == 1
    #expect(stateIsC)
    #expect(mixedReadbackWasNotVerified)
    #expect(writeAttempted)
    #expect(noBlindInverseWasSent)
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
    let reportedAXWriteFailure = error == "ax_write_failed"
    #expect(reportedAXWriteFailure)
    #expect(restorationFailureWasVisible)
    #expect(!rollbackAttempted)
    #expect(result["parameter_left_changed"] is NSNull)
    #expect(fixture.sliderWriteCount.value == 1)
}

@Test func testDirectReadbackLossWithholdsInverseAndReportsFailedViewRestore() async throws {
    let fixture = LiveFixture(
        sliderWriteBehavior: .scripted([nil, 51]),
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let error = try #require(result["error"] as? String)
    let rollbackAttempted = try #require(result["rollback_attempted"] as? Bool)
    let rolledBack = try #require(result["rolled_back"] as? Bool)
    let safeToRetry = try #require(result["safe_to_retry"] as? Bool)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let onlyTheInitialWriteWasSent = fixture.sliderWriteCount.value == 1
    let reportedReadbackLoss = error == "readback_lost_after_write"
    #expect(reportedReadbackLoss)
    #expect(!rollbackAttempted)
    #expect(!rolledBack)
    #expect(result["rollback_observed"] is NSNull)
    #expect(!safeToRetry)
    #expect(result["parameter_left_changed"] is NSNull)
    #expect(restorationFailureWasVisible)
    #expect(onlyTheInitialWriteWasSent)
}

@Test func testDirectReadbackLossWithWithheldRollbackReportsUnknownParameter() async throws {
    let fixture = LiveFixture(
        sliderWriteBehavior: .scripted([nil, nil]),
        controlsViewInitiallySelected: true,
        viewMenuReadFailsAfterFirstSelection: true
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())

    let rollbackAttempted = try #require(result["rollback_attempted"] as? Bool)
    let rolledBack = try #require(result["rolled_back"] as? Bool)
    let safeToRetry = try #require(result["safe_to_retry"] as? Bool)
    let restorationFailureWasVisible = reportsFailedPluginViewRestoration(result)
    let rollbackWasNotObserved = !rolledBack
    let retryIsNotSafe = !safeToRetry
    #expect(!rollbackAttempted)
    #expect(rollbackWasNotObserved)
    #expect(result["parameter_left_changed"] is NSNull)
    #expect(fixture.sliderWriteCount.value == 1)
    #expect(retryIsNotSafe)
    #expect(restorationFailureWasVisible)
}

@Test func testDirectRollbackNearMissUsesTheParametersOwnZeroTolerance() async throws {
    let fixture = LiveFixture(
        thresholdDescription: channelEQFixtureAXDescription,
        pluginSlotName: "Channel EQ",
        beforeValue: 51,
        // The readable mismatch is owned; compensation reaches 51.4 rather than
        // the pre-write 51. This fixture declares tolerance 0 below.
        sliderWriteBehavior: .scripted([40, 51.4])
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

@Test func testUnreadableCompetingEditorMakesWindowUniquenessUndecidable() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowTitleReadFails: true
    )
    let sibling = matchingCompressorEditorWindow(fixture: fixture, baseID: 9_000)
    let existingWindows = try #require(
        fixture.builder.attributeValue(fixture.app, kAXWindowsAttribute as String) as? [AXUIElement]
    )
    fixture.builder.setAttribute(
        fixture.app,
        kAXWindowsAttribute as String,
        existingWindows + [sibling.window]
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    let state = try #require(obj["state"] as? String)
    let error = try #require(obj["error"] as? String)
    let diagnostic = try #require(obj["plugin_window_read_failure"] as? String)
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    let sliderWasUntouched = fixture.currentSliderValue == 51
    #expect(state == "C")
    #expect(error == "window_identity_unresolved")
    #expect(diagnostic == "-25200")
    #expect(!writeAttempted)
    #expect(sliderWasUntouched)
    #expect(fixture.builder.attributeValue(sibling.slider, kAXValueAttribute as String) as? Double == 51)
}

@Test func testUnreadableEditorDuringDuplicatePrecountRefusesBeforeTargetSlotPress() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]],
        pluginWindowTitleReadFails: true
    )
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    let state = try #require(obj["state"] as? String)
    let error = try #require(obj["error"] as? String)
    let diagnostic = try #require(obj["plugin_window_read_failure"] as? String)
    let noTargetSlotPress = fixture.targetOpenControlPressCount.value == 0
    #expect(state == "C")
    #expect(error == "window_identity_unresolved")
    #expect(diagnostic == "-25200")
    #expect(noTargetSlotPress)
}

@Test func testDuplicatePrecountTreatsNoValueAXWindowsAsEmptyAndWrites() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]],
        pluginWindowsReadStatusBeforeTargetOpen: AXHelpers.AXStatusError(
            raw: AXError.noValue.rawValue
        )
    )

    let result = await runLive(fixture: fixture, params: thresholdParams())
    let absencePrecountReachedTheWrite = result["state"] as? String == "A"
        && fixture.targetOpenControlPressCount.value == 1
        && fixture.currentSliderValue == 60
    #expect(absencePrecountReachedTheWrite)
}

@Test func testDuplicatePrecountPreservesCannotCompleteAsARefusal() async throws {
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        pluginSlotNamesByTrack: [0: [0: "Compressor", 6: "Compressor"]],
        pluginWindowsReadStatusBeforeTargetOpen: AXHelpers.AXStatusError(
            raw: AXError.cannotComplete.rawValue
        )
    )

    let result = await runLive(fixture: fixture, params: thresholdParams())
    // AXWindows now also owns Arrange identity acquisition. A globally unreadable
    // list refuses there before the duplicate-editor census; its direct status
    // preservation remains covered by testPluginEditorEnumerationPreservesCannotCompleteAsAReadFailure.
    let unreadablePrecountRefusedBeforeThePress = result["state"] as? String == "C"
        && result["error"] as? String == "incomplete_inventory"
        && fixture.targetOpenControlPressCount.value == 0
        && fixture.currentSliderValue == 51
    #expect(unreadablePrecountRefusedBeforeThePress)
}

@Test func testPluginEditorEnumerationTreatsDefinitiveAXAbsenceAsEmpty() {
    let absenceStatuses = [AXError.noValue.rawValue, AXError.attributeUnsupported.rawValue]
    let everyAbsenceWasAnEmptyCensus = absenceStatuses.allSatisfy { rawStatus in
        let fixture = LiveFixture(
            pluginWindowsReadStatusBeforeTargetOpen: AXHelpers.AXStatusError(raw: rawStatus)
        )
        switch AXLogicProElements.pluginEditorWindows(runtime: fixture.runtime) {
        case let .success(editors):
            return editors.isEmpty
        case .failure:
            return false
        }
    }
    #expect(everyAbsenceWasAnEmptyCensus)
}

@Test func testPluginEditorEnumerationPreservesCannotCompleteAsAReadFailure() {
    let fixture = LiveFixture(
        pluginWindowsReadStatusBeforeTargetOpen: AXHelpers.AXStatusError(
            raw: AXError.cannotComplete.rawValue
        )
    )
    let result = AXLogicProElements.pluginEditorWindows(runtime: fixture.runtime)
    let cannotCompleteWasPreserved: Bool
    switch result {
    case let .failure(error):
        cannotCompleteWasPreserved = error.raw == AXError.cannotComplete.rawValue
    case .success:
        cannotCompleteWasPreserved = false
    }
    #expect(cannotCompleteWasPreserved)
}

@Test func testPluginWindowClassificationTreatsDefinitiveAXAbsenceAsANonCandidate() {
    let absenceStatuses = [AXError.noValue.rawValue, AXError.attributeUnsupported.rawValue]
    let everyAbsenceLeftTheReadableEditorClassified = absenceStatuses.allSatisfy { rawStatus in
        let fixture = LiveFixture(
            nonPluginWindowSubroleReadStatus: AXHelpers.AXStatusError(raw: rawStatus)
        )
        let match = AXLogicProElements.pluginWindowMatch(
            forTrackName: trackName,
            matchingPluginID: "logic.stock.effect.compressor",
            matchingSliderDescription: "Threshold",
            runtime: fixture.runtime
        )
        if case .unique = match {
            return true
        }
        return false
    }
    #expect(everyAbsenceLeftTheReadableEditorClassified)
}

@Test func testPluginWindowClassificationPreservesCannotCompleteAsUnreadable() {
    let fixture = LiveFixture(
        nonPluginWindowSubroleReadStatus: AXHelpers.AXStatusError(
            raw: AXError.cannotComplete.rawValue
        )
    )
    let match = AXLogicProElements.pluginWindowMatch(
        forTrackName: trackName,
        matchingPluginID: "logic.stock.effect.compressor",
        matchingSliderDescription: "Threshold",
        runtime: fixture.runtime
    )
    let cannotCompleteWasUnreadable: Bool
    switch match {
    case let .unreadable(error):
        cannotCompleteWasUnreadable = error.raw == AXError.cannotComplete.rawValue
    case .none, .unique, .ambiguous, .pluginIdentityMismatch:
        cannotCompleteWasUnreadable = false
    }
    #expect(cannotCompleteWasUnreadable)
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
    let remainingCensus = AXLogicProElements.matchingPluginEditorWindows(
        forTrackName: trackName,
        matchingPluginID: "logic.stock.effect.compressor",
        runtime: fixture.runtime
    )
    guard case let .success(remainingEditors) = remainingCensus else {
        Issue.record("the post-close editor census was unreadable")
        return
    }
    let allNewEditorsWereClosed = remainingEditors.isEmpty
    #expect(allNewEditorsWereClosed)
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

// #965: these witnesses run the actual parameter/EQ acquisition and write path, not just the
// name helper. Every external-input fallback is injected; accepted AX writes stay in the fixture.
private func rawReferenceRuntime(_ fixture: LiveFixture) -> AXLogicProElements.Runtime {
    AXLogicProElements.Runtime(
        logicProPID: fixture.runtime.logicProPID, ax: fixture.runtime.ax,
        executeAppleScript: { _ in
            Issue.record("raw reference fixture must not execute AppleScript")
            return .error("unexpected script")
        }, onScreenWindowList: { [] },
        postPopupMenuEscape: { Issue.record("raw reference fixture must not post Escape") },
        focusedApplicationPID: { 4242 }
    )
}

private func runRawReferenceWrite(
    _ fixture: LiveFixture, eq: Bool, expected: String,
    entryLookup: @escaping VerifiedPluginCatalog.EntryLookup = VerifiedPluginCatalog.productionEntryLookup
) async throws -> [String: Any] {
    var params = eq ? namedEQBandParams() : thresholdParams()
    params["expected_track_name"] = expected
    let runtime = rawReferenceRuntime(fixture)
    let opener: AccessibilityChannel.PluginWindowOpener = { _, _, _, _, _ in
        Issue.record("raw reference fixture must use its already visible editor")
        return nil
    }
    let result: ChannelResult
    if eq {
        result = await AccessibilityChannel.defaultSetEQBandVerified(
            params: params, runtime: runtime, frontDocumentPath: { expectedPath },
            entryLookup: entryLookup, pluginWindowOpener: opener,
            pluginPopupMenuCleaner: { _ in .noPopupObserved }
        )
    } else {
        result = await AccessibilityChannel.defaultSetParamVerified(
            params: params, runtime: runtime, frontDocumentPath: { expectedPath },
            entryLookup: entryLookup, pluginWindowOpener: opener,
            pluginPopupMenuCleaner: { _ in .noPopupObserved }
        )
    }
    return try #require(sharedJSONObject(result.message))
}

private func rawReferenceFixture(
    name: String, eq: Bool,
    onSelection: (@Sendable (FakeAXRuntimeBuilder, Int) -> Void)? = nil
) -> LiveFixture {
    LiveFixture(
        trackDisplayName: name, thresholdDescription: eq ? "Peak 1 Frequency" : "Threshold",
        pluginSlotName: eq ? "Channel EQ" : "Compressor", beforeValue: eq ? 0 : 51,
        sliderWriteBehavior: eq ? .oneStepTowardRequest : .direct,
        onTrackHeaderPress: onSelection
    )
}

@Test(arguments: [false, true], [(" Bass", "Bass "), ("q\u{0301}\u{0323}", "q\u{0323}\u{0301}")])
func testIssue965PluginReferenceRejectsByteDistinctLiveNameBeforeAnyAction(
    _ eq: Bool, names: (String, String)
) async throws {
    let fixture = rawReferenceFixture(name: names.1, eq: eq)
    let object = try await runRawReferenceWrite(fixture, eq: eq, expected: names.0)
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "stale_target_reference")
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    let expected = try #require(object["expected_track_name"] as? String)
    let observed = try #require(object["observed_track_name"] as? String)
    #expect(expected.utf8.elementsEqual(names.0.utf8))
    #expect(observed.utf8.elementsEqual(names.1.utf8))
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.axActions.value.isEmpty)
}

@Test(arguments: [false, true], [" Bass ", "q\u{0301}\u{0323}"])
func testIssue965PluginReferenceUnchangedRawNameStillWrites(_ eq: Bool, name: String) async throws {
    let fixture = rawReferenceFixture(name: name, eq: eq)
    let object = try await runRawReferenceWrite(fixture, eq: eq, expected: name)
    #expect(object["state"] as? String == "A")
    let verified = try #require(object["verified"] as? Bool)
    #expect(verified)
    #expect(fixture.currentSliderValue == (eq ? 3 : 60))
    #expect(fixture.sliderWriteCount.value == (eq ? 3 : 1))
}

@Test(arguments: [false, true], ["catalog", "selection"])
func testIssue965PluginReferenceRejectsRawDriftAfterInitialGuard(_ eq: Bool, stage: String) async throws {
    let old = "q\u{0301}\u{0323}"
    let changed = "q\u{0323}\u{0301}"
    #expect(old == changed, "exercise canonical equality without byte equality")
    let interleaves = MutableBox(0)
    let mutate: @Sendable (FakeAXRuntimeBuilder) -> Void = { builder in
        interleaves.value += 1
        builder.setAttribute(builder.element(1100), kAXDescriptionAttribute as String, "1개의 ‘\(changed)’ 트랙")
        builder.setAttribute(builder.element(150_000), kAXValueAttribute as String, changed)
        builder.setAttribute(builder.element(1004), kAXTitleAttribute as String, changed)
        builder.setAttribute(builder.element(1012), kAXValueAttribute as String, changed)
    }
    let fixture = rawReferenceFixture(name: old, eq: eq, onSelection: { builder, headerID in
        if stage == "selection", headerID == 1100, interleaves.value == 0 { mutate(builder) }
    })
    let lookups = MutableBox(0)
    let lookup: VerifiedPluginCatalog.EntryLookup = { requestedID in
        lookups.value += 1
        if stage == "catalog", lookups.value == 1 { mutate(fixture.builder) }
        return VerifiedPluginCatalog.productionEntryLookup(requestedID)
    }
    let object = try await runRawReferenceWrite(fixture, eq: eq, expected: old, entryLookup: lookup)
    #expect(lookups.value > 0, "initial live name check must pass before the interleaving")
    #expect(interleaves.value == 1, "drive a real catalog/selection boundary, not an initial mismatch")
    #expect(object["state"] as? String == "C")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.currentSliderValue == (eq ? 0 : 51))
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
}

@Test func testIssue965PluginReferenceRetainedInventoryRejectsByteDistinctSameElements() async throws {
    let old = "q\u{0301}\u{0323}"
    let changed = "q\u{0323}\u{0301}"
    let fixture = LiveFixture(trackDisplayName: old)
    let emptySlot = fixture.builder.element(965_700)
    fixture.builder.setAttribute(emptySlot, kAXRoleAttribute as String, kAXButtonRole as String)
    fixture.builder.setAttribute(emptySlot, kAXDescriptionAttribute as String, "오디오 플러그인")
    fixture.builder.setAttribute(emptySlot, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
    fixture.builder.setChildren(emptySlot, [])
    fixture.builder.setChildren(fixture.builder.element(1200), [fixture.builder.element(150_000), emptySlot])
    let driverCalls = MutableBox(0)
    let result = await AccessibilityChannel.defaultInsertVerified(
        params: ["track": "0", "insert": "0", "plugin": "Compressor",
                 "mode": "duplicate_applyback", "project_expected_path": expectedPath,
                 "expected_track_name": old], runtime: rawReferenceRuntime(fixture),
        frontDocumentPath: { expectedPath },
        insertDriver: { track, _, _, _, runtime in
            driverCalls.value += 1
            let before = AccessibilityChannel.fullStripInventory(track: track, runtime: runtime)
            let initiallyReadable = before != nil
            #expect(initiallyReadable)
            // Retain every AX element: only the acquired raw name drifts.
            fixture.builder.setAttribute(fixture.builder.element(1100), kAXDescriptionAttribute as String,
                                         "1개의 ‘\(changed)’ 트랙")
            fixture.builder.setAttribute(fixture.builder.element(150_000), kAXValueAttribute as String, changed)
            let after = AccessibilityChannel.fullStripInventory(track: track, runtime: runtime)
            let refused = after == nil
            #expect(refused, "retained binding must not authorize canonical-equivalent raw name drift")
            return (.transientSetupFailure(stage: "fixture_terminal"), [:])
        }
    )
    #expect(driverCalls.value == 1)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.targetOpenControlPressCount.value == 0)
}

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

// R1108-01: a reference's first name check must not authorize a different,
// independently acquired target. The entry lookup is production's step 4,
// after the first name guard and before track selection / Mixer acquisition.
private func expectedNameAcquisitionInterleave(
    eq: Bool,
    occupiedInsertReference: Bool,
    reorderAfterInitialGuard: Bool
) async throws -> (object: [String: Any], fixture: LiveFixture, lookups: Int) {
    let pluginName = eq ? "Channel EQ" : "Compressor"
    let pluginID = eq ? "logic.stock.effect.channel_eq" : "logic.stock.effect.compressor"
    let fixture = LiveFixture(
        track: 9, trackDisplayName: "Bass",
        thresholdDescription: eq ? "Peak 1 Frequency" : "Threshold",
        pluginSlotName: pluginName,
        beforeValue: eq ? 0 : 51,
        otherTracks: 10,
        pluginSlotNamesByTrack: [10: [6: pluginName]],
        sliderWriteBehavior: eq ? .oneStepTowardRequest : .direct
    )
    let builder = fixture.builder
    let bassHeader = builder.element(1109)
    let replacementHeader = builder.element(1110)
    builder.setAttribute(replacementHeader, kAXDescriptionAttribute as String, "1개의 ‘Hi Synth’ 트랙")
    builder.setAttribute(builder.element(150_010), kAXValueAttribute as String, "Hi Synth")
    let lookups = MutableBox(0)
    let lookup: VerifiedPluginCatalog.EntryLookup = { requestedID in
        lookups.value += 1
        if lookups.value == 1, reorderAfterInitialGuard {
            // This is a reorder of distinct AX header elements, not a duplicate
            // name or a mismatch already present when the reference guard ran.
            var headers = (0...10).map { builder.element(1100 + $0) }
            headers.swapAt(9, 10)
            builder.setChildren(builder.element(1002), headers)
            builder.setAttribute(bassHeader, kAXSelectedAttribute as String, false)
            builder.setAttribute(replacementHeader, kAXSelectedAttribute as String, true)
            builder.setAttribute(builder.element(1004), kAXTitleAttribute as String, "Hi Synth")
            builder.setAttribute(builder.element(1012), kAXValueAttribute as String, "Hi Synth")
        }
        return VerifiedPluginCatalog.productionEntryLookup(requestedID)
    }
    var params = eq ? namedEQBandParams() : thresholdParams()
    params["track"] = "9"
    // These are the channel parameters forwarded by trk_ and occupied ins_
    // resolution, respectively; the dispatcher itself is not under test here.
    params["expected_track_name"] = "Bass"
    if occupiedInsertReference {
        params["expected_slot_read_status"] = "ok"
        params["expected_plugin_identity"] = pluginID
    }
    let result: ChannelResult
    if eq {
        result = await AccessibilityChannel.defaultSetEQBandVerified(
            params: params, runtime: fixture.runtime,
            frontDocumentPath: { expectedPath }, entryLookup: lookup,
            pluginPopupMenuCleaner: { _ in .noPopupObserved }
        )
    } else {
        result = await AccessibilityChannel.defaultSetParamVerified(
            params: params, runtime: fixture.runtime,
            frontDocumentPath: { expectedPath }, entryLookup: lookup,
            pluginPopupMenuCleaner: { _ in .noPopupObserved }
        )
    }
    let data = try #require(result.message.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (object, fixture, lookups.value)
}

private func assertExpectedNameAcquisitionRefusal(eq: Bool, occupiedInsertReference: Bool) async throws {
    let observed = try await expectedNameAcquisitionInterleave(
        eq: eq, occupiedInsertReference: occupiedInsertReference, reorderAfterInitialGuard: true
    )
    // Reaching the first catalog lookup proves the initial expected-name guard
    // allowed Bass before the interleaving changed the index's identity.
    #expect(observed.lookups > 0)
    #expect(observed.object["state"] as? String == "C")
    #expect(observed.object["error"] as? String == "stale_target_reference")
    #expect(observed.fixture.sliderWriteCount.value == 0)
    #expect(observed.fixture.currentSliderValue == (eq ? 0 : 51))
    let writeAttempted = try #require(observed.object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
}

@Test func testTrackReferenceCompressorRefusesReorderAfterInitialNameGuardBeforeAcquisition() async throws {
    try await assertExpectedNameAcquisitionRefusal(eq: false, occupiedInsertReference: false)
}

@Test func testOccupiedInsertReferenceCompressorRefusesReorderAfterInitialNameGuardBeforeAcquisition() async throws {
    try await assertExpectedNameAcquisitionRefusal(eq: false, occupiedInsertReference: true)
}

@Test func testTrackReferenceEQRefusesReorderAfterInitialNameGuardBeforeAcquisition() async throws {
    try await assertExpectedNameAcquisitionRefusal(eq: true, occupiedInsertReference: false)
}

@Test func testOccupiedInsertReferenceEQRefusesReorderAfterInitialNameGuardBeforeAcquisition() async throws {
    try await assertExpectedNameAcquisitionRefusal(eq: true, occupiedInsertReference: true)
}

@Test func testUnchangedTrackAndOccupiedInsertReferenceAcquisitionStillWritesRequestedPlugin() async throws {
    for eq in [false, true] {
        for occupiedInsertReference in [false, true] {
            let observed = try await expectedNameAcquisitionInterleave(
                eq: eq, occupiedInsertReference: occupiedInsertReference, reorderAfterInitialGuard: false
            )
            #expect(observed.lookups > 0)
            #expect(observed.object["state"] as? String == "A")
            #expect(observed.fixture.sliderWriteCount.value == (eq ? 3 : 1))
            #expect(observed.fixture.currentSliderValue == (eq ? 3 : 60))
        }
    }
}

@Test func testTrackReferenceRetainsOriginalBindingAcrossHeaderReorderDuringSelectionPress() async throws {
    let selectionPresses = MutableBox(0)
    let fixture = LiveFixture(
        track: 9, trackDisplayName: "Bass", otherTracks: 10,
        pluginSlotNamesByTrack: [10: [6: "Compressor"]],
        onTrackHeaderPress: { builder, headerID in
            guard headerID == 1109 else { return }
            selectionPresses.value += 1
            guard selectionPresses.value == 1 else { return }
            var headers = (0...10).map { builder.element(1100 + $0) }
            headers.swapAt(9, 10)
            builder.setChildren(builder.element(1002), headers)
            builder.setAttribute(builder.element(1109), kAXSelectedAttribute as String, false)
            builder.setAttribute(builder.element(1110), kAXSelectedAttribute as String, true)
            builder.setAttribute(builder.element(1004), kAXTitleAttribute as String, "Hi Synth")
            builder.setAttribute(builder.element(1012), kAXValueAttribute as String, "Hi Synth")
        }
    )
    fixture.builder.setAttribute(fixture.builder.element(1110), kAXDescriptionAttribute as String,
                                 "1개의 ‘Hi Synth’ 트랙")
    fixture.builder.setAttribute(fixture.builder.element(150_010), kAXValueAttribute as String, "Hi Synth")
    var params = thresholdParams(track: 9)
    params["expected_track_name"] = "Bass"
    let object = await runLive(fixture: fixture, params: params)
    let selectionWasTriggeredExactlyOnce = selectionPresses.value == 1
    try #require(selectionWasTriggeredExactlyOnce, "the actual header AXPress must trigger this interleaving")
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "stale_target_reference")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.currentSliderValue == 51)
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
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

@Test func testUnknownCheckboxAfterPressDoesNotSendBlindInverse() async throws {
    let fixture = LiveFixture(
        controlsViewRowLabel: "Limiter On", controlsCheckboxBefore: false,
        controlsCheckboxWriteBehavior: .mixedThenChanged,
        controlsViewInitiallySelected: true, viewSettleDelay: 0
    )
    let result = await runLive(fixture: fixture, params: controlsBooleanParams())
    #expect(fixture.controlsCheckboxPressCount.value == 1)
    let raw = try #require(fixture.builder.attributeValue(
        fixture.builder.element(100_908), kAXValueAttribute as String) as? NSNumber)
    #expect(raw.intValue == 2)
    #expect(result["state"] as? String == "C")
    #expect(result["error"] as? String == "readback_lost_after_write")
    let attempted = try #require(result["restore_attempted"] as? Bool)
    let safe = try #require(result["safe_to_retry"] as? Bool)
    #expect(!attempted)
    #expect(!safe)
    #expect(result["observed_boolean"] is NSNull)
}

@Test func testUnknownSliderAfterWriteDoesNotSendBlindInverse() async throws {
    let fixture = LiveFixture(sliderWriteBehavior: .scripted([nil, 51]))
    let result = await runLive(fixture: fixture, params: thresholdParams())
    #expect(fixture.sliderWriteCount.value == 1)
    #expect(fixture.currentSliderValue == nil)
    #expect(result["error"] as? String == "readback_lost_after_write")
    let attempted = try #require(result["rollback_attempted"] as? Bool)
    let safe = try #require(result["safe_to_retry"] as? Bool)
    #expect(!attempted)
    #expect(!safe)
}

@Test func testSliderRollbackDoesNotOverwriteNewerUserValue() async throws {
    let edits = MutableBox(0)
    let fixture = LiveFixture(
        sliderWriteBehavior: .scripted([40, 51]),
        onSliderDisplayAfterWrite: { builder, slider in
            if edits.value == 0 {
                // The write's independent numeric readback already observed 40.
                // A later user edit lands while its display is being read.
                edits.value += 1
                builder.setAttribute(slider, kAXValueAttribute as String, 75.0)
            }
        }
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())
    #expect(edits.value == 1)
    #expect(result["observed_normalized"] as? Double == 40)
    #expect(fixture.sliderWriteCount.value == 1)
    #expect(fixture.currentSliderValue == 75)
    #expect(result["error"] as? String == "readback_mismatch")
    let attempted = try #require(result["rollback_attempted"] as? Bool)
    let safe = try #require(result["safe_to_retry"] as? Bool)
    #expect(!attempted)
    #expect(!safe)
}

@Test(arguments: ["slot", "control", "gate", "cancellation"])
func testSliderRollbackRequiresItsStillOwnedTarget(_ loss: String) async throws {
    let injected = MutableBox(false)
    let fixture = LiveFixture(
        sliderWriteBehavior: .scripted([40, 51]),
        onSliderDisplayAfterWrite: { builder, _ in
            guard !injected.value else { return }
            injected.value = true
            if loss == "slot" {
                builder.setAttribute(builder.element(1306), kAXDescriptionAttribute as String, "Noise Gate")
            } else if loss == "control" {
                let replacement = builder.element(100_999)
                builder.setRole(replacement, kAXSliderRole as String)
                builder.setAttribute(replacement, kAXDescriptionAttribute as String, "Threshold")
                builder.setAttribute(replacement, kAXValueAttribute as String, 40.0)
                let window = builder.element(1004)
                let children = builder.makeAXRuntime().children(window)
                builder.setChildren(window, children.map { CFEqual($0, builder.element(1005)) ? replacement : $0 })
            }
        }
    )
    let context = OperationTraceContext(mutationGateAcquired: true,
        ownsGate: { loss != "gate" || !injected.value },
        cancellationRequested: { loss == "cancellation" && injected.value })
    let result = await OperationTraceContext.$current.withValue(context) {
        await runLive(fixture: fixture, params: thresholdParams())
    }
    #expect(injected.value)
    #expect(result["observed_normalized"] as? Double == 40)
    #expect(fixture.sliderWriteCount.value == 1)
    #expect(fixture.currentSliderValue == 40)
    #expect(result["state"] as? String == "C")
    let attempted = try #require(result["rollback_attempted"] as? Bool)
    #expect(!attempted)
}

@Test func testSliderAlreadyAtBeforeDoesNotClaimAnInverse() async throws {
    let fixture = LiveFixture(beforeValue: 51, forcedAfterValue: 51)
    let result = await runLive(fixture: fixture, params: thresholdParams())
    #expect(fixture.sliderWriteCount.value == 1)
    #expect(fixture.currentSliderValue == 51)
    #expect(result["error"] as? String == "readback_mismatch")
    let attempted = try #require(result["rollback_attempted"] as? Bool)
    let rolledBack = try #require(result["rolled_back"] as? Bool)
    let leftChanged = try #require(result["parameter_left_changed"] as? Bool)
    #expect(!attempted)
    #expect(!rolledBack)
    #expect(!leftChanged)
}

@Test(arguments: ["unknown", "before_despite_failed_ack"])
func testSliderInverseReceiptUsesIndependentStateNotAttemptStatus(_ state: String) async throws {
    let fixture = LiveFixture(
        sliderWriteBehavior: .scripted([40, state == "unknown" ? nil : 51]),
        rejectSliderInverseAcknowledgement: state != "unknown"
    )
    let result = await runLive(fixture: fixture, params: thresholdParams())
    #expect(fixture.sliderWriteCount.value == 2)
    #expect(result["observed_normalized"] as? Double == 40)
    #expect(result["state"] as? String == "C")
    let attempted = try #require(result["rollback_attempted"] as? Bool)
    #expect(attempted)
    if state == "unknown" {
        #expect(fixture.currentSliderValue == nil)
        #expect(result["rollback_observed"] is NSNull)
        #expect(result["parameter_left_changed"] is NSNull)
    } else {
        #expect(fixture.currentSliderValue == 51)
        #expect(result["rollback_observed"] as? Double == 51)
        let changed = try #require(result["parameter_left_changed"] as? Bool)
        #expect(!changed)
    }
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
    let fixture = LiveFixture(beforeValue: 51, pluginWindowPresent: false)
    let b = fixture.builder
    let duplicateSlider = b.element(3200)
    b.setAttribute(duplicateSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(duplicateSlider, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(duplicateSlider, kAXValueAttribute as String, 51.0)
    b.setChildren(b.element(1004), [
        b.element(1007), b.element(1008), b.element(1005), duplicateSlider,
        b.element(1011), b.element(1009),
    ])

    let openedWindow = AXUIElementSendable(b.element(1004))
    let obj = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        opener: { _, _, _, _, _ in
            b.setAttribute(fixture.app, kAXWindowsAttribute as String, [b.element(1001), b.element(1004)])
            return openedWindow
        }
    )

    let state = try #require(obj["state"] as? String)
    let error = try #require(obj["error"] as? String)
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    let refusedAsAmbiguous = state == "C" && error == "window_identity_unresolved"
    let noSliderWriteWasAttempted = !writeAttempted && fixture.currentSliderValue == 51
    #expect(refusedAsAmbiguous)
    #expect(noSliderWriteWasAttempted)
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

@Test func testMatchingSliderDescriptionWinsOverAnUnrelatedDescriptionReadFailure() async throws {
    let descriptionStatuses = MutableBox<[Int: AXHelpers.AXStatusError]>([:])
    let fixture = LiveFixture(
        beforeValue: 51,
        sliderDescriptionReadStatuses: descriptionStatuses
    )
    let b = fixture.builder
    let unreadableSlider = b.element(32_101)
    b.setAttribute(unreadableSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    descriptionStatuses.value[b.elementID(unreadableSlider)] = AXHelpers.AXStatusError(
        raw: AXError.failure.rawValue
    )
    b.setChildren(b.element(1004), [
        b.element(1007), b.element(1008), unreadableSlider, b.element(1005),
        b.element(1011), b.element(1009),
    ])

    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let state = try #require(result["state"] as? String)
    let reachedVerifiedWrite = state == "A"
    let writeWasAttempted = fixture.sliderWriteCount.value == 1
    let matchingSliderWasWritten = fixture.currentSliderValue == 60
    #expect(reachedVerifiedWrite)
    #expect(writeWasAttempted)
    #expect(matchingSliderWasWritten)
}

@Test func testUnmatchedSliderDescriptionReadFailureRefusesAsUnknown() async throws {
    let descriptionStatuses = MutableBox<[Int: AXHelpers.AXStatusError]>([:])
    let fixture = LiveFixture(
        thresholdDescription: "Output Gain",
        pluginWindowPresent: false,
        sliderDescriptionReadStatuses: descriptionStatuses
    )
    let b = fixture.builder
    let unreadableSlider = b.element(32_102)
    b.setAttribute(unreadableSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    descriptionStatuses.value[b.elementID(unreadableSlider)] = AXHelpers.AXStatusError(
        raw: AXError.failure.rawValue
    )
    b.setChildren(b.element(1004), [
        b.element(1007), b.element(1008), unreadableSlider, b.element(1005),
        b.element(1011), b.element(1009),
    ])
    let openedWindow = AXUIElementSendable(b.element(1004))

    let result = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        opener: { _, _, _, _, _ in openedWindow }
    )

    let error = try #require(result["error"] as? String)
    let readFailure = try #require(result["slider_description_read_failure"] as? String)
    let writeAttempted = try #require(result["write_attempted"] as? Bool)
    let refusedAsUnknown = error == "window_identity_unresolved"
    let namesTheAXReadFailure = readFailure == "-25200"
    let didNotClaimControlWasAbsent = error != "param_control_not_found"
    let noSliderWriteWasAttempted = !writeAttempted && fixture.sliderWriteCount.value == 0
    #expect(refusedAsUnknown)
    #expect(namesTheAXReadFailure)
    #expect(didNotClaimControlWasAbsent)
    #expect(noSliderWriteWasAttempted)
}

@Test func testUnmatchedSliderDescriptionsWithOnlyAbsenceAndSuccessAreNotFound() async throws {
    let descriptionStatuses = MutableBox<[Int: AXHelpers.AXStatusError]>([:])
    let fixture = LiveFixture(
        thresholdDescription: "Output Gain",
        pluginWindowPresent: false,
        sliderDescriptionReadStatuses: descriptionStatuses
    )
    let b = fixture.builder
    let noValueSlider = b.element(32_103)
    let unsupportedSlider = b.element(32_104)
    b.setAttribute(noValueSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(unsupportedSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    descriptionStatuses.value[b.elementID(noValueSlider)] = AXHelpers.AXStatusError(
        raw: AXError.noValue.rawValue
    )
    descriptionStatuses.value[b.elementID(unsupportedSlider)] = AXHelpers.AXStatusError(
        raw: AXError.attributeUnsupported.rawValue
    )
    b.setChildren(b.element(1004), [
        b.element(1007), b.element(1008), noValueSlider, unsupportedSlider, b.element(1005),
        b.element(1011), b.element(1009),
    ])
    let openedWindow = AXUIElementSendable(b.element(1004))

    let result = await runLive(
        fixture: fixture,
        params: thresholdParams(),
        opener: { _, _, _, _, _ in openedWindow }
    )

    let error = try #require(result["error"] as? String)
    let writeAttempted = try #require(result["write_attempted"] as? Bool)
    let reportedObservedAbsence = error == "param_control_not_found"
    let noReadFailureWasInvented = result["slider_description_read_failure"] == nil
    let noSliderWriteWasAttempted = !writeAttempted && fixture.sliderWriteCount.value == 0
    #expect(reportedObservedAbsence)
    #expect(noReadFailureWasInvented)
    #expect(noSliderWriteWasAttempted)
}

@Test func testBypassEvidenceWinsOverAnUnrelatedLabelReadFailure() async throws {
    let descriptionStatuses = MutableBox<[Int: AXHelpers.AXStatusError]>([:])
    let fixture = LiveFixture(
        beforeValue: 51,
        sliderDescriptionReadStatuses: descriptionStatuses
    )
    let b = fixture.builder
    descriptionStatuses.value[b.elementID(b.element(1008))] = AXHelpers.AXStatusError(
        raw: AXError.failure.rawValue
    )

    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let state = try #require(result["state"] as? String)
    let reachedVerifiedWrite = state == "A"
    let matchingSliderWasWritten = fixture.currentSliderValue == 60
    #expect(reachedVerifiedWrite)
    #expect(matchingSliderWasWritten)
}

@Test func testPluginHeaderEvidenceWinsOverAnUnrelatedStaticTextReadFailure() async throws {
    let staticTextStatuses = MutableBox<[Int: AXHelpers.AXStatusError]>([:])
    let fixture = LiveFixture(
        beforeValue: 51,
        pluginWindowStaticTextValueReadStatuses: staticTextStatuses
    )
    let b = fixture.builder
    staticTextStatuses.value[b.elementID(b.element(1010))] = AXHelpers.AXStatusError(
        raw: AXError.failure.rawValue
    )

    let result = await runLive(fixture: fixture, params: thresholdParams(value: "60"))

    let state = try #require(result["state"] as? String)
    let reachedVerifiedWrite = state == "A"
    let matchingSliderWasWritten = fixture.currentSliderValue == 60
    #expect(reachedVerifiedWrite)
    #expect(matchingSliderWasWritten)
}

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

// MARK: - #982 unread children are refused as unread, not as an absent track

@Test(arguments: [(true, true), (true, false), (false, false)])
func testUnreadChildrenAreIncompleteInventoryForThatReason(mixerUnread: Bool, mixerByIdentifier: Bool) async throws {
    // Before #982 an unread Mixer read as one with no strips ("track index 0 is not present") and
    // an unread strip as one with no inserts ("insert 6 ... out of range").
    let fixture = LiveFixture(
        beforeValue: 51, mixerChildrenUnread: mixerUnread, mixerByIdentifier: mixerByIdentifier,
        targetStripChildrenUnread: !mixerUnread)
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "incomplete_inventory")
    #expect(!(try #require(obj["write_attempted"] as? Bool)))
    #expect(obj["what_was_observed"] as? String
        == (mixerUnread ? "the mixer's children did not read" : "the strip's children did not read"))
    #expect(fixture.currentSliderValue == 51, "no write may occur when the chain was not read")
    // Acquiring the original identity now precedes selection. Unread Mixer/strip children
    // cannot establish that binding, so even the selection action must not dispatch.
    let actions = fixture.axActions.value
    #expect(actions.isEmpty, "\(actions)")
    #expect(fixture.sliderWriteCount.value == 0)
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
            b.setAttribute(g, kAXPositionAttribute as String, axPoint(100, 300 + CGFloat(s) * 20))
            b.setAttribute(g, kAXSizeAttribute as String, axSize(58, 16))
            slots.append(g)
        }
        b.setChildren(strip, slots)
        let stripName = b.element(3201)
        b.setAttribute(stripName, kAXRoleAttribute as String, kAXTextFieldRole as String)
        b.setAttribute(stripName, kAXDescriptionAttribute as String, "이름")
        b.setAttribute(stripName, kAXValueAttribute as String, trackName)
        b.setChildren(strip, [stripName] + slots)
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

@Test func testNormalAcquisitionViewRefusalClosesTheEditorItOpened() async {
    // This is the normal (non-duplicate) acquisition path: the target-slot
    // press opens an editor, then View selection refuses before any parameter
    // write. The operation owns that newly observed editor even on State C.
    let fixture = LiveFixture(
        pluginWindowPresent: false,
        openWindowOnSlotPress: true,
        controlsViewRowLabel: "Limiter On",
        viewMenuSelectionSetsUnconfirmedStructure: true,
        viewSettleDelay: 0
    )

    let result = await runLive(
        fixture: fixture,
        params: controlsBooleanParams()
    )
    // Probe AXWindows directly instead of reusing the writer's plugin-editor
    // classifier: the cleanup proof must still see an editor if that classifier
    // is ever changed to omit one.
    let independentAXProbeFoundNoEditor: Bool
    if let windows = fixture.builder.attributeValue(
        fixture.app,
        kAXWindowsAttribute as String
    ) as? [AXUIElement] {
        independentAXProbeFoundNoEditor = windows.count == 1
    } else {
        independentAXProbeFoundNoEditor = false
    }
    let refusalClosedItsNewEditor = result["state"] as? String == "C"
        && result["error"] as? String == "plugin_view_not_confirmed"
        && fixture.pluginCloseControlPressCount.value == 1
        && independentAXProbeFoundNoEditor
    #expect(refusalClosedItsNewEditor)
}

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
    let remainingCensus = AXLogicProElements.matchingPluginEditorWindows(
        forTrackName: trackName,
        matchingPluginID: "logic.stock.effect.compressor",
        runtime: fixture.runtime
    )
    guard case let .success(remainingEditors) = remainingCensus else {
        Issue.record("the post-close editor census was unreadable")
        return
    }
    let constructedEditorWasClosed = remainingEditors.isEmpty
    #expect(constructedEditorWasClosed)
}

@Test func testReusedEditorIsNotClosedByTheOperation() async {
    // The single-instance path reuses an editor the caller already had open.
    // Closing it would destroy state this operation never created — a worse
    // defect than the one the close exists to fix.
    let fixture = LiveFixture(beforeValue: 51)
    let obj = await runLive(fixture: fixture, params: thresholdParams())

    #expect(obj["state"] as? String == "A")
    #expect(fixture.pluginCloseControlPressCount.value == 0)
    let reusableCensus = AXLogicProElements.matchingPluginEditorWindows(
        forTrackName: trackName,
        matchingPluginID: "logic.stock.effect.compressor",
        runtime: fixture.runtime
    )
    guard case let .success(reusableEditors) = reusableCensus else {
        Issue.record("the reused-editor census was unreadable")
        return
    }
    let existingEditorRemainedOpen = !reusableEditors.isEmpty
    #expect(existingEditorRemainedOpen)
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

// #955 B0: use the actual channel entry point, not a requested-value echo or
// a writer with an unchanged target. Every AX access is injected by LiveFixture.
private func parameterReadRuntime(
    _ fixture: LiveFixture,
    onScreenWindowList: @escaping @Sendable () -> [[String: Any]]? = { [] },
    actionNamesRead: (@Sendable (AXUIElement) -> Result<[String], AXHelpers.AXStatusError>?)? = nil,
    attributeRead: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?)? = nil,
    legacyAttributeRead: Bool = false
) -> AXLogicProElements.Runtime {
    let original = fixture.runtime.ax
    let ax = AXHelpers.Runtime(
        axApp: original.axApp, attributeValue: { element, attribute in
            // Frontness still uses the legacy optional-value reader. A fault
            // injected only into the Result reader must not pretend to cover it.
            if legacyAttributeRead, let result = attributeRead?(element, attribute) {
                switch result {
                case let .success(value): return value
                case .failure: return nil
                }
            }
            return original.attributeValue(element, attribute)
        },
        attributeIsSettable: original.attributeIsSettable, setAttributeValue: original.setAttributeValue,
        children: original.children, performAction: original.performAction, childCount: original.childCount,
        actionNames: original.actionNames, actionNamesResult: { element in
            actionNamesRead?(element) ?? original.actionNamesResult?(element) ?? .success(original.actionNames(element))
        },
        childrenResult: original.childrenResult,
        attributeValueResult: { element, attribute in
            attributeRead?(element, attribute) ?? original.attributeValueResult!(element, attribute)
        },
        performActionResult: original.performActionResult, elementAtPosition: original.elementAtPosition
    )
    return AXLogicProElements.Runtime(
        logicProPID: fixture.runtime.logicProPID, ax: ax,
        executeAppleScript: { _ in
            Issue.record("A parameter read must not escape to AppleScript")
            return .error("unexpected AppleScript")
        },
        onScreenWindowList: onScreenWindowList,
        postPopupMenuEscape: { Issue.record("A parameter read must not post global Escape") },
        focusedApplicationPID: { 4242 }
    )
}

private func parameterReadParams(_ param: String = "threshold") -> [String: String] {
    ["track": "0", "insert": "6", "plugin": "Compressor", "param": param,
     "project_expected_path": expectedPath, "expected_track_name": trackName,
     "expected_slot_read_status": "ok", "expected_plugin_identity": "logic.stock.effect.compressor"]
}

// #1396: measured Gain Controls view has a display-bearing slider, a raw-only
// sibling slider and its value indicator. Boolean rows contain two named radio
// buttons. These reads must not borrow the writer's single-control authority.
private func gainReadFixture(_ param: String = "gain", controls: Bool = false,
                             windowPresent: Bool = true, openOnPress: Bool = false) -> LiveFixture {
    let labels = ["gain": "Gain:", "phase_invert": "Phase Invert:", "phase_invert_left": "Phase Left:",
        "phase_invert_right": "Phase Right:", "swap_lr": "Swap L/R:", "mono": "Make Mono:"]
    let fixture = LiveFixture(pluginSlotName: "Gain", pluginWindowPresent: windowPresent,
        openWindowOnSlotPress: openOnPress, controlsViewRowLabel: labels[param],
        controlsViewInitiallySelected: controls, viewSettleDelay: 0)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let first = b.element(139_601), second = b.element(139_602)
    if param == "gain" {
        let container = b.element(139_603), indicator = b.element(139_604)
        b.setRole(container, kAXGroupRole as String)
        for slider in [first, second] {
            b.setRole(slider, kAXSliderRole as String)
            b.setAttribute(slider, kAXValueAttribute as String, 959.0)
        }
        b.setAttribute(first, kAXValueDescriptionAttribute as String, "-0.1 dB")
        b.setRole(indicator, "AXValueIndicator")
        b.setAttribute(indicator, kAXValueAttribute as String, 959.0)
        b.setChildren(container, [first])
        b.setChildren(second, [indicator])
        b.setChildren(b.element(100_905), [b.element(100_907), container, second])
    } else {
        let titles = param == "mono" ? ("Stereo", "Mono") : param == "swap_lr" ? ("Norm", "Swap") : ("Norm", "Inv")
        for (radio, title, value) in [(first, titles.0, 0), (second, titles.1, 1)] {
            b.setRole(radio, kAXRadioButtonRole as String)
            b.setAttribute(radio, kAXTitleAttribute as String, title)
            b.setAttribute(radio, kAXValueAttribute as String, value)
        }
        b.setChildren(b.element(100_905), [b.element(100_907), first, second])
    }
    return fixture
}

private let noiseGateReadCases: [(String, String, Double, String)] = [
    ("threshold", "Threshold:", 52, "-48 dB"),
    ("hysteresis", "Hysteresis:", 35, "-2.5 dB"),
    ("reduction", "Reduction:", 1, "-99 dB"),
    ("attack", "Attack:", 4, "4 ms"),
    ("hold", "Hold:", 5, "50 ms"),
    ("release", "Release:", 11, "11.0 ms"),
    ("high_cutoff", "High Cutoff:", 99, "19100 Hz"),
    ("low_cutoff", "Low Cutoff:", 1, "21 Hz"),
    ("lookahead", "Lookahead:", 1, "0.2 ms"),
]

private func noiseGateReadFixture(_ param: String, controls: Bool = false,
                                  choice: String = "Band Reject") -> LiveFixture {
    let row = noiseGateReadCases.first { $0.0 == param }
    let fixture = LiveFixture(pluginSlotName: "Noise Gate",
        controlsViewRowLabel: row?.1 ?? "Characteristics:",
        controlsViewInitiallySelected: controls, viewSettleDelay: 0)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    if let row {
        for (id, role) in [(139_641, "AXSlider"), (139_642, "AXSlider"), (139_643, "AXValueIndicator")] {
            b.setRole(b.element(id), role)
            b.setAttribute(b.element(id), kAXValueAttribute as String, row.2)
        }
        b.setAttribute(b.element(139_641), kAXValueDescriptionAttribute as String, row.3)
        b.setChildren(b.element(139_642), [b.element(139_643)])
        b.setChildren(b.element(100_905), [b.element(100_907), b.element(139_641), b.element(139_642)])
    } else {
        b.setRole(b.element(139_641), kAXPopUpButtonRole as String)
        b.setAttribute(b.element(139_641), kAXValueAttribute as String, choice)
        b.setChildren(b.element(100_905), [b.element(100_907), b.element(139_641)])
    }
    return fixture
}

private func noiseGateReadParams(_ param: String) -> [String: String] {
    var params = parameterReadParams(param)
    params["plugin"] = "Noise Gate"
    params["expected_plugin_identity"] = "logic.stock.effect.noise_gate"
    return params
}

@Test(arguments: noiseGateReadCases.map { $0.0 }, [false, true])
func testIssue1396NoiseGateReadsOpaqueRawWithActualDisplay(_ param: String, _ controls: Bool) async throws {
    let expected = try #require(noiseGateReadCases.first { $0.0 == param })
    let fixture = noiseGateReadFixture(param, controls: controls)
    let beforeView = fixture.currentPluginViewTitle
    let result = await AccessibilityChannel.defaultGetParamVerified(params: noiseGateReadParams(param), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    #expect(object["observed_raw"] as? Double == expected.2)
    #expect(object["observed_display"] as? String == expected.3)
    #expect(object["raw_unit"] as? String == "raw_ax_value")
    #expect(fixture.currentPluginViewTitle == beforeView)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_641...139_643).contains($0.element) })
}

@Test(arguments: ["Bandpass", "Band Reject"], [false, true])
func testIssue1396NoiseGateReadsSelectedFilterWithoutOpeningPopup(_ choice: String, _ controls: Bool) async throws {
    let fixture = noiseGateReadFixture("sidechain_filter_mode", controls: controls, choice: choice)
    let beforeView = fixture.currentPluginViewTitle
    let result = await AccessibilityChannel.defaultGetParamVerified(params: noiseGateReadParams("sidechain_filter_mode"), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    #expect(object["observed_raw"] as? String == choice)
    #expect(object["observed_display"] as? String == choice)
    #expect(object["raw_unit"] as? String == "string")
    #expect(fixture.currentPluginViewTitle == beforeView)
    #expect(!fixture.axActions.value.contains { $0.element == 139_641 })
}

@Test(arguments: ["empty", "absent", "malformed", "unreadable", "drift", "duplicate", "wrong_role", "unobserved_choice"])
func testIssue1396NoiseGateUncertainPopupIsUnknownWithoutActuation(_ kind: String) async throws {
    let fixture = noiseGateReadFixture("sidechain_filter_mode")
    let b = fixture.builder
    switch kind {
    case "empty": b.setAttribute(b.element(139_641), kAXValueAttribute as String, "")
    case "absent": b.setAttribute(b.element(139_641), kAXValueAttribute as String, NSNull())
    case "malformed": b.setAttribute(b.element(139_641), kAXValueAttribute as String, NSNumber(value: true))
    case "unobserved_choice": b.setAttribute(b.element(139_641), kAXValueAttribute as String, "Unavailable selection")
    case "wrong_role": b.setRole(b.element(139_641), kAXTextFieldRole as String)
    case "duplicate":
        b.setRole(b.element(139_642), kAXPopUpButtonRole as String)
        b.setAttribute(b.element(139_642), kAXValueAttribute as String, "Band Reject")
        b.setChildren(b.element(100_905), [b.element(100_907), b.element(139_641), b.element(139_642)])
    default: break
    }
    let reads = MutableBox(0)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        guard CFEqual(element, b.element(139_641)), attribute == kAXValueAttribute as String else { return nil }
        if kind == "unreadable" { return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)) }
        if kind == "drift" {
            reads.value += 1
            return .success((reads.value == 1 ? "Band Reject" : "Bandpass") as NSString)
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: noiseGateReadParams("sidechain_filter_mode"), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "B", "\(kind): \(object)")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(fixture.currentPluginViewTitle == "편집기")
    #expect(!fixture.axActions.value.contains { (139_641...139_643).contains($0.element) })
}

@Test(arguments: noiseGateReadCases.map { $0.0 } + ["sidechain_filter_mode"])
func testIssue1396NoiseGateReadDoesNotGrantAWriter(_ param: String) async throws {
    let fixture = noiseGateReadFixture(param)
    var params = noiseGateReadParams(param)
    params.merge(["mode": "duplicate_applyback", "value": "1"]) { _, new in new }
    let result = await AccessibilityChannel.defaultSetParamVerified(params: params, runtime: parameterReadRuntime(fixture), frontDocumentPath: { expectedPath })
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(fixture.axActions.value.isEmpty)
}

@Test func testIssue1396NoiseGatePopupProtocolRejectsWrongTypesUnknownChoicesAndContradictoryDisplay() async throws {
    let fixture = noiseGateReadFixture("sidechain_filter_mode")
    let result = await AccessibilityChannel.defaultGetParamVerified(params: noiseGateReadParams("sidechain_filter_mode"), runtime: parameterReadRuntime(fixture))
    var object = try #require(sharedJSONObject(result.message))
    // Synthetic transport fields do not provide independent native evidence.
    object["target_ref"] = "ins_gate_fixture"
    object["target_fingerprint"] = "gate_fixture_fingerprint"
    let oracle = try #require(SemanticOracleTable.byOperationID[.pluginsGetParamVerified])
    let valid = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: object), readbackData: Data()))
    #expect(valid)
    let corruptions: [[String: Any]] = [
        ["observed_raw": true],
        ["observed_raw": "Unavailable selection", "observed_display": "Unavailable selection"],
        ["observed_raw": "Bandpass", "observed_display": "Band Reject"],
        ["raw_unit": "raw_ax_value"],
    ]
    for corruption in corruptions {
        var corrupted = object
        corrupted.merge(corruption) { _, new in new }
        let verdict = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: corrupted), readbackData: Data()))
        #expect(!verdict)
    }
}

private func sampleDelayReadFixture(_ param: String = "left_delay", samples: Bool = true,
                                    controls: Bool = false, windowPresent: Bool = true,
                                    openOnPress: Bool = false) -> LiveFixture {
    let fixture = LiveFixture(pluginSlotName: "SmpleDly",
        pluginWindowPresent: windowPresent, openWindowOnSlotPress: openOnPress,
        pluginWindowStaticTextValues: ["보기:", "Sample Delay", trackName],
        controlsViewRowLabel: param == "delay" ? "Delay:" : param == "left_delay" ? "Left Delay:" : "Right Delay:",
        controlsViewInitiallySelected: controls, viewSettleDelay: 0)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let raw = samples ? (param == "delay" ? 35.0 : param == "left_delay" ? 1.0 : 0.0) : 0.0
    for (id, role) in [(139_621, "AXSlider"), (139_622, "AXSlider"), (139_623, "AXValueIndicator")] {
        b.setRole(b.element(id), role)
        b.setAttribute(b.element(id), kAXValueAttribute as String, raw)
    }
    b.setAttribute(b.element(139_621), kAXValueDescriptionAttribute as String,
        samples ? "\(Int(raw)) samples" : "0.0 ms")
    b.setChildren(b.element(139_622), [b.element(139_623)])
    b.setChildren(b.element(100_905), [b.element(100_907), b.element(139_621), b.element(139_622)])
    b.setRole(b.element(139_624), kAXRowRole as String)
    b.setRole(b.element(139_625), kAXCellRole as String)
    b.setRole(b.element(139_626), kAXStaticTextRole as String)
    b.setAttribute(b.element(139_626), kAXValueAttribute as String, "Unit:")
    for (id, title, value) in [(139_627, "Samples", samples ? 1 : 0), (139_628, "ms", samples ? 0 : 1)] {
        b.setRole(b.element(id), kAXRadioButtonRole as String)
        b.setAttribute(b.element(id), kAXTitleAttribute as String, title)
        b.setAttribute(b.element(id), kAXValueAttribute as String, value)
    }
    b.setChildren(b.element(139_625), [b.element(139_626), b.element(139_627), b.element(139_628)])
    b.setChildren(b.element(139_624), [b.element(139_625)])
    let rows = [b.element(100_904), b.element(139_624)]
    b.setChildren(b.element(100_903), rows)
    b.setAttribute(b.element(100_903), kAXRowsAttribute as String, rows)
    return fixture
}

private func sampleDelayReadParams(_ param: String = "left_delay") -> [String: String] {
    var params = parameterReadParams(param)
    params["plugin"] = "Sample Delay"
    params["expected_plugin_identity"] = "logic.stock.effect.sample_delay"
    return params
}

@Test(arguments: ["left_delay", "right_delay"], [false, true])
func testIssue1396SampleDelayReadsOnlyConfirmedSamples(_ param: String, _ controls: Bool) async throws {
    let fixture = sampleDelayReadFixture(param, controls: controls)
    let beforeView = fixture.currentPluginViewTitle
    let result = await AccessibilityChannel.defaultGetParamVerified(params: sampleDelayReadParams(param), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    #expect(object["observed_raw"] as? Double == (param == "left_delay" ? 1 : 0))
    #expect(object["observed_display"] as? String == (param == "left_delay" ? "1 samples" : "0 samples"))
    #expect(object["raw_unit"] as? String == "samples")
    #expect(fixture.currentPluginViewTitle == beforeView)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_621...139_628).contains($0.element) })
}

@Test(arguments: [false, true])
func testIssue1396SampleDelayMillisecondsAreUnknownWithoutChangingUnits(_ controls: Bool) async throws {
    let fixture = sampleDelayReadFixture(samples: false, controls: controls)
    let beforeView = fixture.currentPluginViewTitle
    let result = await AccessibilityChannel.defaultGetParamVerified(params: sampleDelayReadParams(), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "B", "\(object)")
    #expect(object["parameter_read_status"] as? String == "samples_unit_not_selected")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(fixture.currentPluginViewTitle == beforeView)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_621...139_628).contains($0.element) })
}

@Test(arguments: ["both_units_on", "both_units_off", "missing_unit_title", "duplicate_unit_row", "unit_drift", "display_ms", "display_count_mismatch", "fractional_samples"])
func testIssue1396SampleDelayUncertainUnitOrCountNeverBecomesZero(_ kind: String) async throws {
    let fixture = sampleDelayReadFixture()
    let b = fixture.builder
    switch kind {
    case "both_units_on": b.setAttribute(b.element(139_628), kAXValueAttribute as String, 1)
    case "both_units_off": b.setAttribute(b.element(139_627), kAXValueAttribute as String, 0)
    case "missing_unit_title": b.setAttribute(b.element(139_627), kAXTitleAttribute as String, NSNull())
    case "duplicate_unit_row":
        b.setRole(b.element(139_629), kAXRowRole as String)
        b.setChildren(b.element(139_629), [b.element(139_625)])
        let rows = [b.element(100_904), b.element(139_624), b.element(139_629)]
        b.setChildren(b.element(100_903), rows)
        b.setAttribute(b.element(100_903), kAXRowsAttribute as String, rows)
    case "display_ms": b.setAttribute(b.element(139_621), kAXValueDescriptionAttribute as String, "0.0 ms")
    case "display_count_mismatch": b.setAttribute(b.element(139_621), kAXValueDescriptionAttribute as String, "0 samples")
    case "fractional_samples":
        for id in [139_621, 139_622, 139_623] { b.setAttribute(b.element(id), kAXValueAttribute as String, 0.5) }
        b.setAttribute(b.element(139_621), kAXValueDescriptionAttribute as String, "0.5 samples")
    default: break
    }
    let unitReads = MutableBox(0)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        guard kind == "unit_drift", attribute == kAXValueAttribute as String else { return nil }
        if CFEqual(element, b.element(139_627)) {
            unitReads.value += 1
            return .success(NSNumber(value: unitReads.value == 1 ? 1 : 0))
        }
        if CFEqual(element, b.element(139_628)) { return .success(NSNumber(value: unitReads.value == 1 ? 0 : 1)) }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: sampleDelayReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "B", "\(kind): \(object)")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(fixture.currentPluginViewTitle == "편집기")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_621...139_629).contains($0.element) })
}

@Test(arguments: ["left_delay", "right_delay"])
func testIssue1396SampleDelayReadNeverGrantsWrites(_ param: String) async throws {
    let fixture = sampleDelayReadFixture(param)
    var params = sampleDelayReadParams(param)
    params.merge(["mode": "duplicate_applyback", "value": "2", "unit": "samples"]) { _, new in new }
    let result = await AccessibilityChannel.defaultSetParamVerified(params: params, runtime: parameterReadRuntime(fixture), frontDocumentPath: { expectedPath })
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(fixture.axActions.value.isEmpty)
}

private func gainReadParams(_ param: String = "gain") -> [String: String] {
    var params = parameterReadParams(param)
    params["plugin"] = "Gain"
    params["expected_plugin_identity"] = "logic.stock.effect.gain"
    return params
}

@Test(arguments: [false, true])
func testIssue1417MonoGainReadsPolarityAndClosesItsNewEditor(_ controls: Bool) async throws {
    let fixture = gainReadFixture("phase_invert", controls: controls, windowPresent: false, openOnPress: true)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams("phase_invert"), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    let inverted = try #require(object["observed_raw"] as? Bool)
    #expect(inverted)
    #expect(object["observed_display"] as? String == "Inv")
    #expect(object["raw_unit"] as? String == "boolean")
    let closed = try #require(object["editor_close_observed"] as? Bool)
    let restored = try #require(object["plugin_view_restore_observed"] as? Bool)
    #expect(closed)
    #expect(restored)
    #expect(fixture.pluginCloseControlPressCount.value == 1)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_601...139_604).contains($0.element) })
}

@Test(arguments: [false, true])
func testIssue1417MonoDelayReadsNonzeroSamplesAndClosesItsNewEditor(_ controls: Bool) async throws {
    let fixture = sampleDelayReadFixture("delay", controls: controls, windowPresent: false, openOnPress: true)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: sampleDelayReadParams("delay"), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    #expect(object["observed_raw"] as? Double == 35)
    #expect(object["observed_display"] as? String == "35 samples")
    #expect(object["raw_unit"] as? String == "samples")
    let closed = try #require(object["editor_close_observed"] as? Bool)
    let restored = try #require(object["plugin_view_restore_observed"] as? Bool)
    #expect(closed)
    #expect(restored)
    #expect(fixture.pluginCloseControlPressCount.value == 1)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_621...139_628).contains($0.element) })
}

@Test(arguments: [false, true])
func testIssue1417MonoDelayMillisecondsRemainUnknownWithoutChangingUnits(_ controls: Bool) async throws {
    let fixture = sampleDelayReadFixture("delay", samples: false, controls: controls)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: sampleDelayReadParams("delay"), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "B", "\(object)")
    #expect(object["parameter_read_status"] as? String == "samples_unit_not_selected")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(fixture.currentPluginViewTitle == (controls ? "컨트롤" : "편집기"))
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_621...139_628).contains($0.element) })
}

@Test(arguments: ["mono_gain", "stereo_gain", "mono_delay", "stereo_delay"])
func testIssue1417ParameterKeysNeverFallBackAcrossPluginFormats(_ kind: String) async throws {
    let gain = kind.hasSuffix("gain")
    let mono = kind.hasPrefix("mono")
    let actualKey = gain ? (mono ? "phase_invert" : "phase_invert_left") : (mono ? "delay" : "left_delay")
    let requestedKey = gain ? (mono ? "phase_invert_left" : "phase_invert") : (mono ? "left_delay" : "delay")
    let fixture = gain ? gainReadFixture(actualKey) : sampleDelayReadFixture(actualKey)
    let params = gain ? gainReadParams(requestedKey) : sampleDelayReadParams(requestedKey)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: params, runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "B", "\(kind): \(object)")
    #expect(object["parameter_read_status"] as? String == "rowLabelNotFound")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test(arguments: ["phase_invert", "delay"])
func testIssue1417MonoReadMetadataDoesNotAuthorizeWrites(_ key: String) async throws {
    let fixture = key == "delay" ? sampleDelayReadFixture(key) : gainReadFixture(key)
    var params = key == "delay" ? sampleDelayReadParams(key) : gainReadParams(key)
    params.merge(["mode": "duplicate_applyback", "value": "1", "unit": key == "delay" ? "samples" : "boolean"]) { _, new in new }
    let result = await AccessibilityChannel.defaultSetParamVerified(params: params, runtime: parameterReadRuntime(fixture), frontDocumentPath: { expectedPath })
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(fixture.axActions.value.isEmpty)
}

private func issue1417BlockingWindow(_ fixture: LiveFixture) -> AXUIElement {
    let b = fixture.builder
    let dialog = b.element(141_701)
    b.setRole(dialog, kAXWindowRole as String)
    b.setAttribute(dialog, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)
    b.setAttribute(dialog, kAXModalAttribute as String, true)
    b.setAttribute(dialog, kAXTitleAttribute as String, "Blocking fixture")
    b.setChildren(dialog, [])
    return dialog
}

@Test(arguments: ["dialog", "windows_unreadable"])
func testIssue1417ScalarReadRefusesBlockedOrUnreadableModalStateBeforeAcquisition(_ kind: String) async throws {
    let fixture = gainReadFixture()
    let b = fixture.builder
    if kind == "dialog" {
        let windows = try #require(b.attributeValue(fixture.app, kAXWindowsAttribute as String) as? [AXUIElement])
        b.setAttribute(fixture.app, kAXWindowsAttribute as String, windows + [issue1417BlockingWindow(fixture)])
    }
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if kind == "windows_unreadable", CFEqual(element, fixture.app), attribute == kAXWindowsAttribute as String {
            return .failure(AXHelpers.AXStatusError(raw: AXError.apiDisabled.rawValue))
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C", "\(object)")
    #expect(object["dialog_presence_reason"] as? String == (kind == "dialog" ? "blocking_window_found" : "windows_read_failed"))
    let actualDialog = try #require(object["refusal_names_an_actual_dialog"] as? Bool)
    if kind == "dialog" { #expect(actualDialog) } else { #expect(!actualDialog) }
    #expect(object["observed_raw"] == nil)
    #expect(fixture.axActions.value.isEmpty)
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test func testIssue1417ScalarReadDiscardsValueWhenModalAppearsDuringCollection() async throws {
    let fixture = gainReadFixture(controls: true)
    let b = fixture.builder
    let dialog = issue1417BlockingWindow(fixture)
    let arrived = MutableBox(false)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if !arrived.value, CFEqual(element, b.element(139_601)), attribute == kAXValueAttribute as String {
            arrived.value = true
            let windows = b.attributeValue(fixture.app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
            b.setAttribute(fixture.app, kAXWindowsAttribute as String, windows + [dialog])
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(arrived.value)
    #expect(object["state"] as? String == "C", "\(object)")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.axActions.value.isEmpty)
}

@Test(arguments: [false, true])
func testIssue1396GainPreservesRawAndVerbatimDisplayWithoutAudioWrites(_ controls: Bool) async throws {
    let fixture = gainReadFixture(controls: controls)
    let beforeView = fixture.currentPluginViewTitle
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    #expect(object["observed_raw"] as? Double == 959)
    #expect(object["observed_display"] as? String == "-0.1 dB")
    #expect(object["raw_unit"] as? String == "raw_ax_value")
    #expect(object["display_read_status"] as? String == "read")
    #expect(fixture.currentPluginViewTitle == beforeView)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_601...139_604).contains($0.element) })
}

@Test(arguments: ["phase_invert_left", "phase_invert_right", "swap_lr", "mono"], [false, true])
func testIssue1396GainReadsNamedOneHotRadioPairs(_ param: String, _ controls: Bool) async throws {
    let fixture = gainReadFixture(param, controls: controls)
    let beforeView = fixture.currentPluginViewTitle
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(param), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    #expect(try #require(object["observed_raw"] as? Bool))
    #expect(object["raw_unit"] as? String == "boolean")
    #expect(object["observed_display"] as? String == (param == "mono" ? "Mono" : param == "swap_lr" ? "Swap" : "Inv"))
    #expect(fixture.currentPluginViewTitle == beforeView)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    #expect(!fixture.axActions.value.contains { (139_601...139_604).contains($0.element) })
}

@Test(arguments: ["duplicate_display", "malformed_other_display", "missing_raw", "different_raw", "malformed_raw", "no_display", "extra_control", "unreadable_description", "drift"])
func testIssue1396GainUncertainNumericReadIsBAndRestoresView(_ kind: String) async throws {
    let fixture = gainReadFixture()
    let b = fixture.builder
    switch kind {
    case "duplicate_display": b.setAttribute(b.element(139_602), kAXValueDescriptionAttribute as String, "-0.1 dB")
    case "malformed_other_display": b.setAttribute(b.element(139_602), kAXValueDescriptionAttribute as String, NSNumber(value: 7))
    case "missing_raw": b.setAttribute(b.element(139_601), kAXValueAttribute as String, NSNull())
    case "different_raw": b.setAttribute(b.element(139_602), kAXValueAttribute as String, 960)
    case "malformed_raw": b.setAttribute(b.element(139_601), kAXValueAttribute as String, NSNumber(value: true))
    case "no_display": b.setAttribute(b.element(139_601), kAXValueDescriptionAttribute as String, "")
    case "extra_control":
        let extra = b.element(139_605)
        b.setRole(extra, kAXButtonRole as String)
        b.setChildren(b.element(139_603), [b.element(139_601), extra])
    default: break
    }
    let reads = MutableBox(0)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if kind == "unreadable_description", CFEqual(element, b.element(139_602)), attribute == kAXValueDescriptionAttribute as String {
            return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        }
        if kind == "drift", CFEqual(element, b.element(139_601)), attribute == kAXValueAttribute as String {
            reads.value += 1
            return .success(NSNumber(value: reads.value == 1 ? 959 : 960))
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "B", "\(kind): \(object)")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(object["parameter_read_status"] as? String != "read")
    #expect(fixture.currentPluginViewTitle == "편집기")
    #expect(try #require(object["plugin_view_restore_observed"] as? Bool))
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test(arguments: ["both_on", "both_off", "mixed", "missing", "duplicate_title", "wrong_title", "drift"])
func testIssue1396GainUncertainRadioReadIsBWithoutDefault(_ kind: String) async throws {
    let fixture = gainReadFixture("phase_invert_left")
    let b = fixture.builder
    switch kind {
    case "both_on": b.setAttribute(b.element(139_601), kAXValueAttribute as String, 1)
    case "both_off": b.setAttribute(b.element(139_602), kAXValueAttribute as String, 0)
    case "mixed": b.setAttribute(b.element(139_602), kAXValueAttribute as String, 2)
    case "missing": b.setAttribute(b.element(139_602), kAXValueAttribute as String, NSNull())
    case "duplicate_title": b.setAttribute(b.element(139_601), kAXTitleAttribute as String, "Inv")
    case "wrong_title": b.setAttribute(b.element(139_601), kAXTitleAttribute as String, "Other")
    default: break
    }
    let reads = MutableBox(0)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if kind == "drift", CFEqual(element, b.element(139_602)), attribute == kAXValueAttribute as String {
            reads.value += 1
            return .success(NSNumber(value: reads.value == 1 ? 1 : 0))
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams("phase_invert_left"), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "B", "\(kind): \(object)")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(try #require(object["plugin_view_restore_observed"] as? Bool))
    #expect(!fixture.axActions.value.contains { (139_601...139_604).contains($0.element) })
}

@Test(arguments: ["gain", "phase_invert_left", "phase_invert_right", "swap_lr", "mono"])
func testIssue1396GainReadMetadataNeverAuthorizesParameterWrites(_ param: String) async throws {
    let fixture = gainReadFixture(param)
    var params = gainReadParams(param)
    params.merge(["mode": "duplicate_applyback", "value": "1", "unit": param == "gain" ? "dB" : "boolean"]) { _, new in new }
    let result = await AccessibilityChannel.defaultSetParamVerified(params: params,
        runtime: parameterReadRuntime(fixture), frontDocumentPath: { expectedPath })
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(!fixture.axActions.value.contains { (139_601...139_604).contains($0.element) })
    #expect(fixture.axActions.value.isEmpty)
}

@Test func testIssue1396GainReadRejectsEngineeringUnitBeforeUIAcquisition() async throws {
    let fixture = gainReadFixture()
    var params = gainReadParams()
    params["unit"] = "dB"
    let result = await AccessibilityChannel.defaultGetParamVerified(params: params, runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "invalid_params")
    #expect(fixture.axActions.value.isEmpty)
    #expect(StockPluginCatalog.entry(id: "logic.stock.effect.gain")?.parameters.first?.unit == "dB")
}

@Test(arguments: [false, true])
func testIssue1396GainUnfrontEditorRefusalRetainsOnlyNewWindowCleanup(_ alreadyOpen: Bool) async throws {
    let fixture = gainReadFixture(windowPresent: alreadyOpen, openOnPress: true)
    let b = fixture.builder
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if CFEqual(element, b.element(1004)),
           [kAXMainAttribute as String, kAXFocusedAttribute as String].contains(attribute) {
            return .success(NSNumber(value: false))
        }
        return nil
    }, legacyAttributeRead: true)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    if alreadyOpen {
        #expect(object["state"] as? String == "A", "\(object)")
        #expect(fixture.pluginCloseControlPressCount.value == 0)
    } else {
        #expect(object["state"] as? String == "C", "\(object)")
        #expect(fixture.pluginCloseControlPressCount.value == 1)
        #expect(try #require(object["editor_close_observed"] as? Bool))
        let windows = try #require(b.attributeValue(b.element(1000), kAXWindowsAttribute as String) as? [AXUIElement])
        #expect(!windows.contains { CFEqual($0, b.element(1004)) })
    }
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test(arguments: ["same", "other", "absent", "malformed", "unreadable"])
func testIssue1396GainUsesExactApplicationFocusedWindowWhenEditorFlagsAreFalse(_ kind: String) async throws {
    let fixture = gainReadFixture(windowPresent: false, openOnPress: true)
    let b = fixture.builder
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if CFEqual(element, b.element(1004)),
           [kAXMainAttribute as String, kAXFocusedAttribute as String].contains(attribute) {
            return .success(NSNumber(value: false))
        }
        if CFEqual(element, b.element(1000)), attribute == kAXFocusedWindowAttribute as String {
            switch kind {
            case "same": return .success(b.element(1004))
            case "other": return .success(b.element(1001))
            case "absent": return .success(nil)
            case "malformed": return .success("not a window" as NSString)
            default: return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            }
        }
        return nil
    }, legacyAttributeRead: true)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == (kind == "same" ? "A" : "C"), "\(kind): \(object)")
    if kind == "same" {
        #expect(object["observed_raw"] as? Double == 959)
        #expect(object["observed_display"] as? String == "-0.1 dB")
    } else {
        #expect(object["observed_raw"] == nil)
    }
    #expect(try #require(object["editor_close_observed"] as? Bool))
    #expect(fixture.pluginCloseControlPressCount.value == 1)
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test(arguments: [false, true])
func testIssue1396GainEditorDescriptionFailureStillReadsAndRestoresOwnedView(_ allSliderDescriptionsFail: Bool) async throws {
    let fixture = gainReadFixture(windowPresent: false, openOnPress: true)
    let b = fixture.builder
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        let slider = allSliderDescriptionsFail
            ? b.attributeValue(element, kAXRoleAttribute as String) as? String == kAXSliderRole as String
            : CFEqual(element, b.element(1005))
        if slider, attribute == kAXDescriptionAttribute as String {
            return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    #expect(object["observed_raw"] as? Double == 959)
    #expect(object["observed_display"] as? String == "-0.1 dB")
    #expect(try #require(object["plugin_view_restore_attempted"] as? Bool))
    #expect(try #require(object["plugin_view_restore_observed"] as? Bool))
    #expect(try #require(object["editor_close_observed"] as? Bool))
    #expect(fixture.currentPluginViewTitle == "편집기")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test func testIssue1396GainRadioFalseDoesNotReadAdjacentRowWithSameTitles() async throws {
    let fixture = gainReadFixture("phase_invert_left")
    let b = fixture.builder
    b.setAttribute(b.element(139_601), kAXValueAttribute as String, 1)
    b.setAttribute(b.element(139_602), kAXValueAttribute as String, 0)
    let row = b.element(139_610), cell = b.element(139_611), label = b.element(139_612)
    let off = b.element(139_613), on = b.element(139_614)
    b.setRole(row, kAXRowRole as String); b.setRole(cell, kAXCellRole as String)
    b.setRole(label, kAXStaticTextRole as String)
    b.setAttribute(label, kAXValueAttribute as String, "Phase Right:")
    for (radio, title, value) in [(off, "Norm", 0), (on, "Inv", 1)] {
        b.setRole(radio, kAXRadioButtonRole as String)
        b.setAttribute(radio, kAXTitleAttribute as String, title)
        b.setAttribute(radio, kAXValueAttribute as String, value)
    }
    b.setChildren(cell, [label, off, on]); b.setChildren(row, [cell])
    let rows = [row, b.element(100_904)]
    b.setChildren(b.element(100_903), rows)
    b.setAttribute(b.element(100_903), kAXRowsAttribute as String, rows)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams("phase_invert_left"), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "\(object)")
    let value = try #require(object["observed_raw"] as? Bool)
    #expect(!value)
    #expect(object["observed_display"] as? String == "Norm")
}

@Test func testIssue1396GainProjectLossDuringReadReturnsCWithoutRestoringIntoForeignProject() async throws {
    let fixture = gainReadFixture()
    let b = fixture.builder
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if CFEqual(element, b.element(139_601)), attribute == kAXValueAttribute as String {
            b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: "/tmp/Other.logicx").absoluteString)
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(fixture.editorViewMenuPressCount.value == 0)
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test(arguments: ["gain", "phase_invert_left"])
func testIssue1396GainProtocolOracleChecksMeasuredRawTypeAndUnit(_ param: String) async throws {
    let fixture = gainReadFixture(param)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: gainReadParams(param), runtime: parameterReadRuntime(fixture))
    var object = try #require(sharedJSONObject(result.message))
    // Synthetic transport binding for protocol validation, not native evidence.
    object["target_ref"] = "ins_gain_fixture"
    object["target_fingerprint"] = "gain_fixture_fingerprint"
    let oracle = try #require(SemanticOracleTable.byOperationID[.pluginsGetParamVerified])
    let valid = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: object), readbackData: Data()))
    #expect(valid)
    for (key, value) in [("raw_unit", "dB" as Any),
        ("observed_raw", param == "gain" ? true as Any : 1.0 as Any),
        ("observed_display", NSNull() as Any)] {
        var corrupted = object; corrupted[key] = value
        let verdict = try #require(oracle.evaluate(responseData: JSONSerialization.data(withJSONObject: corrupted), readbackData: Data()))
        #expect(!verdict)
    }
}

@Test func testIssue955ParameterPlanUsesActualAXReadersAndRestoresViewsWithoutAudioWrites() async throws {
    try await FeatureFlags.withAdr002TargetRefForTests(true) {
        let fixture = LiveFixture(beforeValue: 51, controlsViewRowLabel: "Limiter On",
            controlsCheckboxBefore: true, controlsViewInitiallySelected: true, viewSettleDelay: 0)
        fixture.builder.setAttribute(fixture.builder.element(1001), kAXDocumentAttribute as String,
                                     URL(fileURLWithPath: expectedPath).absoluteString)
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
            logicRuntime: parameterReadRuntime(fixture), canPostEvents: { false }))
        let router = ChannelRouter(), cache = StateCache(), registry = TargetRegistry()
        await router.register(channel)
        let project = ProjectInfo(name: "Parameter fixture", filePath: expectedPath)
        await cache.updateProject(project)
        await cache.updateTracks([TrackState(id: 0, name: trackName, type: .audio)])
        let snapshot = await registry.currentSnapshot
        _ = await registry.snapshotForObservedProject(project, ifCurrent: snapshot, stoppingWhen: { false })
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: trackName)
        let reference = await registry.bind(kind: .pluginInsert, descriptor: descriptor,
            fingerprint: TargetRefResolver.pluginInsertFingerprint(descriptor: descriptor, insert: 6,
                pluginIdentity: "logic.stock.effect.compressor"))
        let result = await PluginsDispatcher.handle(verifiedGate: VerifiedOpGate(), command: "plan_parameter_changes",
            params: ["target_ref": .string(reference.rawValue), "changes": .array([
                .object(["param": "threshold", "value": .int(38), "unit": "percent"]),
                .object(["param": "limiter_on", "value": false, "unit": "boolean"]),
            ])], router: router, cache: cache, targetRegistry: registry)
        let object = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(object["state"] as? String == "A", "Injected real B0 acquisition must produce a plan: \(object)")
        #expect(try #require(object["complete"] as? Bool))
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(entries.count == 2)
        let threshold = try #require(entries.first { $0["param"] as? String == "threshold" })
        #expect(threshold["observed_before"] as? Double == 51)
        #expect(threshold["requested_value"] as? Double == 38)
        let limiter = try #require(entries.first { $0["param"] as? String == "limiter_on" })
        let limiterBefore = try #require(limiter["observed_before"] as? Bool)
        #expect(limiterBefore)
        #expect(fixture.sliderWriteCount.value == 0)
        #expect(fixture.controlsCheckboxPressCount.value == 0)
        #expect(fixture.currentSliderValue == 51)
        #expect(fixture.currentPluginViewTitle == "컨트롤")
        for entry in entries {
            let observations = try #require(entry["read_observations"] as? [[String: Any]])
            #expect(observations.count == 2)
            for observation in observations {
                let response = try #require(observation["response"] as? [String: Any])
                let restored = try #require(response["plugin_view_restore_observed"] as? Bool)
                #expect(restored)
            }
        }
    }
}

@Test func testIssue301StateReaderUsesOwnedEditorAndReportsMissingBandsWithoutWriting() async throws {
    // The real acquisition path, deliberately incomplete Controls data. A
    // single observed enable must not masquerade as a complete eight-band EQ.
    let fixture = LiveFixture(
        thresholdDescription: "Low Shelf Frequency", pluginSlotName: "Channel EQ", beforeValue: 240,
        controlsViewRowLabel: "Low Cut On/Off", controlsCheckboxBefore: true,
        controlsViewInitiallySelected: true, viewSettleDelay: 0
    )
    fixture.builder.setAttribute(fixture.builder.element(1001), kAXDocumentAttribute as String,
                                 URL(fileURLWithPath: expectedPath).absoluteString)
    let channel = AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
        logicRuntime: parameterReadRuntime(fixture), canPostEvents: { false }
    ))
    let result = await channel.execute(operation: "plugin.get_channel_eq_state_verified", params: [
        "track": "0", "insert": "6", "plugin": "Channel EQ",
        "project_expected_path": expectedPath, "expected_track_name": trackName,
        "expected_slot_read_status": "ok", "expected_plugin_identity": "logic.stock.effect.channel_eq",
    ])
    let object = try #require(sharedJSONObject(result.message), "Actual AX operation must return its honest envelope: \(result.message)")
    #expect(object["state"] as? String == "B")
    let complete: Bool = try #require(object["complete"] as? Bool)
    let writeAttempted: Bool = try #require(object["write_attempted"] as? Bool)
    #expect(!complete)
    #expect(!writeAttempted)
    let bands = try #require(object["bands"] as? [[String: Any]])
    #expect(bands.count == 8)
    let lowCut = try #require(bands.first)
    let lowCutEnabled: Bool = try #require((lowCut["enabled"] as? [String: Any])?["observed_raw"] as? Bool)
    #expect(lowCutEnabled)
    #expect((lowCut["frequency"] as? [String: Any])?["read_status"] as? String == "absent")
    #expect(fixture.currentPluginViewTitle == "컨트롤")
    let viewRestored: Bool = try #require(object["plugin_view_restore_observed"] as? Bool)
    #expect(viewRestored)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    #expect(fixture.pluginCloseControlPressCount.value == 0)
    #expect(fixture.currentSliderValue == 240)
}

@Test func testIssue301SlotLossAtCleanupInvalidatesSamplesButKeepsCleanupReceipt() async throws {
    let fixture = LiveFixture(
        thresholdDescription: "Low Shelf Frequency", pluginSlotName: "Channel EQ", beforeValue: 240,
        pluginWindowPresent: false, openWindowOnSlotPress: true,
        controlsViewRowLabel: "Low Cut On/Off", controlsCheckboxBefore: true,
        controlsViewInitiallySelected: true, viewSettleDelay: 0
    )
    fixture.builder.setAttribute(fixture.builder.element(1001), kAXDocumentAttribute as String,
                                 URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, attributeRead: { _, attribute in
        // The project remains the same; the occupied slot changes only after
        // owned editor cleanup. A project-only final bookend misses this.
        if attribute == (kAXDocumentAttribute as String), fixture.pluginCloseControlPressCount.value > 0 {
            fixture.builder.setAttribute(fixture.builder.element(1306), kAXDescriptionAttribute as String, "Compressor")
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetChannelEQStateVerified(params: [
        "track": "0", "insert": "6", "plugin": "Channel EQ",
        "project_expected_path": expectedPath, "expected_track_name": trackName,
        "expected_slot_read_status": "ok", "expected_plugin_identity": "logic.stock.effect.channel_eq",
    ], runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(fixture.pluginCloseControlPressCount.value == 1)
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "stale_target_reference")
    #expect(object["bands"] == nil)
    let editorClosed: Bool = try #require(object["editor_close_observed"] as? Bool)
    let viewRestored: Bool = try #require(object["plugin_view_restore_observed"] as? Bool)
    let writeAttempted: Bool = try #require(object["write_attempted"] as? Bool)
    #expect(editorClosed)
    #expect(viewRestored)
    #expect(!writeAttempted)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test func testIssue955ReadThresholdUsesObservedValueWithoutAudioMutation() async throws {
    let fixture = LiveFixture(beforeValue: 51)
    fixture.builder.setAttribute(fixture.builder.element(1001), kAXDocumentAttribute as String,
                                 URL(fileURLWithPath: expectedPath).absoluteString)
    let readRuntime = parameterReadRuntime(fixture)
    let channel = AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
        logicRuntime: readRuntime, canPostEvents: { false }
    ))
    let result = await channel.execute(operation: "plugin.get_param_verified", params: [
        "track": "0", "insert": "6", "plugin": "Compressor", "param": "threshold",
        "unit": "normalized", "project_expected_path": expectedPath,
        "expected_track_name": trackName, "expected_slot_read_status": "ok",
        "expected_plugin_identity": "logic.stock.effect.compressor",
    ])
    let data = try #require(result.message.data(using: .utf8))
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        Issue.record("The parameter read must return an observed HC v2 result, not: \(result.message)")
        return
    }
    #expect(object["state"] as? String == "A")
    #expect(object["operation"] as? String == "logic_plugins.get_param_verified")
    #expect(object["observed_raw"] as? Double == 51)
    #expect(object["raw_unit"] as? String == "normalized")
    #expect(object["observed_display"] as? String == "51 %")
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    #expect(fixture.currentSliderValue == 51)
    #expect(fixture.pluginCloseControlPressCount.value == 0)
}

// End registry custody only after the actual AX reader has finished restoration.
// This preserves the real acquisition/read/cleanup path inside the routing seam.
private actor ParameterReadRegistryEndChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    let reader: AccessibilityChannel
    let registry: TargetRegistry
    init(reader: AccessibilityChannel, registry: TargetRegistry) {
        self.reader = reader
        self.registry = registry
    }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy() }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        let result = await reader.execute(operation: operation, params: params)
        await registry.bumpTopologyGeneration()
        return result
    }
}

@Test(arguments: [false, true])
func testIssue955PublicReadResolvesOccupiedInsertReference(_ contextEndsAfterRead: Bool) async throws {
    try await FeatureFlags.withAdr002TargetRefForTests(true) {
        let fixture = LiveFixture(beforeValue: 51, controlsViewInitiallySelected: true, viewSettleDelay: 0)
        fixture.builder.setAttribute(fixture.builder.element(1001), kAXDocumentAttribute as String,
                                     URL(fileURLWithPath: expectedPath).absoluteString)
        let readRuntime = parameterReadRuntime(fixture)
        let router = ChannelRouter()
        let reader = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
            logicRuntime: readRuntime, canPostEvents: { false }
        ))
        let cache = StateCache()
        let project = ProjectInfo(name: "AcidWashBass copy", filePath: expectedPath)
        await cache.updateProject(project)
        await cache.updateTracks([TrackState(id: 0, name: trackName, type: .audio)])
        let registry = TargetRegistry()
        if contextEndsAfterRead {
            await router.register(ParameterReadRegistryEndChannel(reader: reader, registry: registry))
        } else { await router.register(reader) }
        let initialSnapshot = await registry.currentSnapshot
        _ = await registry.snapshotForObservedProject(project, ifCurrent: initialSnapshot, stoppingWhen: { false })
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: trackName)
        let fingerprint = TargetRefResolver.pluginInsertFingerprint(
            descriptor: descriptor, insert: 6, pluginIdentity: "logic.stock.effect.compressor"
        )
        let reference = await registry.bind(kind: .pluginInsert, descriptor: descriptor, fingerprint: fingerprint)
        let result = await PluginsDispatcher.handle(
            verifiedGate: VerifiedOpGate(), command: "get_param_verified",
            params: ["target_ref": .string(reference.rawValue), "param": .string("threshold")],
            router: router, cache: cache, targetRegistry: registry
        )
        let object = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(try #require(object["plugin_view_restore_attempted"] as? Bool))
        #expect(try #require(object["plugin_view_restore_observed"] as? Bool))
        #expect(fixture.currentPluginViewTitle == "컨트롤")
        if contextEndsAfterRead {
            #expect(object["state"] as? String == "C")
            #expect(object["error"] as? String == "stale_target_reference")
            #expect(object["observed_raw"] == nil)
            #expect(object["observed_display"] == nil)
            #expect(fixture.sliderWriteCount.value == 0)
            #expect(fixture.controlsCheckboxPressCount.value == 0)
            return
        }
        #expect(object["state"] as? String == "A", "Public reader must be reachable: \(object)")
        #expect(object["observed_raw"] as? Double == 51)
        #expect(object["target_ref"] as? String == reference.rawValue)
        #expect(object["target_fingerprint"] as? String == fingerprint)
        #expect(fixture.sliderWriteCount.value == 0)
        #expect(fixture.controlsCheckboxPressCount.value == 0)
        #expect(fixture.currentSliderValue == 51)
        #expect(OperationRegistry.spec(tool: "logic_plugins", command: "get_param_verified")?.mutability == .readOnly)
        #expect(ChannelRouter.routingTable["plugin.get_param_verified"] == [.accessibility])
        let oracle = try #require(SemanticOracleTable.byOperationID[.pluginsGetParamVerified])
        let actualResponse = try JSONSerialization.data(withJSONObject: object)
        let actualVerdict = try #require(oracle.evaluate(responseData: actualResponse, readbackData: Data()) as Bool?)
        #expect(actualVerdict)
        for (key, value) in [("observed_raw", true as Any), ("write_attempted", true as Any),
                             ("raw_unit", "dB" as Any), ("parameter_read_status", "unknown" as Any)] {
            var corrupted = object
            corrupted[key] = value
            let corruptedResponse = try JSONSerialization.data(withJSONObject: corrupted)
            let corruptedVerdict = try #require(oracle.evaluate(responseData: corruptedResponse, readbackData: Data()) as Bool?)
            #expect(!corruptedVerdict)
        }
    }
}

private func readOnlyBooleanEntryLookup(_ param: String) throws -> VerifiedPluginCatalog.EntryLookup {
    let original = try #require(StockPluginCatalog.entry(id: "logic.stock.effect.compressor"))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    var parameters = try #require(object["parameters"] as? [[String: Any]])
    let index = try #require(parameters.firstIndex { $0["id"] as? String == param })
    parameters[index].removeValue(forKey: "write_method")
    parameters[index].removeValue(forKey: "tolerance")
    object["parameters"] = parameters
    let entry = try JSONDecoder().decode(StockPluginCatalogEntry.self,
        from: JSONSerialization.data(withJSONObject: object))
    return { id in id == entry.id ? entry : StockPluginCatalog.entry(id: id) }
}

@Test(arguments: [("limiter_on", false), ("limiter_on", true), ("auto_release", false), ("auto_release", true)],
      [(false, false), (false, true), (true, false), (true, true)])
func testIssue955ReadBooleanNeverPressesParameterAndRestoresView(_ configuration: (String, Bool),
                                                              _ viewAndMetadata: (Bool, Bool)) async throws {
    let (param, value) = configuration
    let (alreadyControls, readOnlyMetadata) = viewAndMetadata
    let fixture = LiveFixture(controlsViewRowLabel: param == "limiter_on" ? "Limiter On" : "Auto Release", controlsCheckboxBefore: value,
                              controlsViewInitiallySelected: alreadyControls, viewSettleDelay: 0)
    fixture.builder.setAttribute(fixture.builder.element(1001), kAXDocumentAttribute as String,
                                 URL(fileURLWithPath: expectedPath).absoluteString)
    let initialView = fixture.currentPluginViewTitle
    let result = await AccessibilityChannel.defaultGetParamVerified(
        params: parameterReadParams(param), runtime: parameterReadRuntime(fixture),
        entryLookup: readOnlyMetadata ? try readOnlyBooleanEntryLookup(param) : VerifiedPluginCatalog.productionEntryLookup
    )
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A", "Boolean read should use the existing observed control: \(object)")
    let observedValue = try #require(object["observed_raw"] as? Bool)
    let valueMatches = observedValue == value
    #expect(valueMatches)
    #expect(object["raw_unit"] as? String == "boolean")
    #expect(object["parameter_read_status"] as? String == "read")
    #expect(fixture.currentPluginViewTitle == initialView)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.currentSliderValue == 51)
    #expect(try #require(object["plugin_view_restore_observed"] as? Bool))
}

@Test(arguments: ["limiter_on", "auto_release"])
func testIssue1396ReadOnlyBooleanMetadataNeverAuthorizesAWrite(_ param: String) async throws {
    let fixture = LiveFixture()
    var params = parameterReadParams(param)
    params.merge(["mode": "duplicate_applyback", "value": "1", "unit": "boolean"]) { _, new in new }
    let result = await AccessibilityChannel.defaultSetParamVerified(params: params,
        runtime: parameterReadRuntime(fixture), frontDocumentPath: { expectedPath },
        entryLookup: try readOnlyBooleanEntryLookup(param))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "unsupported_param_readback")
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(fixture.axActions.value.isEmpty)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test func testIssue955ProjectLossAfterCleanupKeepsRestorationReceiptButNotValue() async throws {
    let fixture = LiveFixture(controlsViewInitiallySelected: true, viewSettleDelay: 0)
    let arrange = fixture.builder.element(1001)
    fixture.builder.setAttribute(arrange, kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        // The value was sampled in Editor view. Project ownership ends only after
        // cleanup has restored Controls view, at the final native bookend.
        if CFEqual(element, arrange), attribute == kAXDocumentAttribute as String,
           fixture.editorViewMenuPressCount.value > 0, fixture.controlsViewMenuPressCount.value > 0 {
            return .success(URL(fileURLWithPath: "/tmp/Other.logicx").absoluteString as NSString)
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "project_identity_mismatch")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(try #require(object["plugin_view_restore_attempted"] as? Bool))
    #expect(try #require(object["plugin_view_restore_observed"] as? Bool))
    #expect(fixture.currentPluginViewTitle == "컨트롤")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test(arguments: [("not_a_parameter", "unknown"), ("gain", "unsupported")])
func testIssue955ReadDistinguishesUnknownFromUnsupported(_ param: String, _ status: String) async throws {
    let fixture = LiveFixture()
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(param), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["parameter_read_status"] as? String == status)
    #expect(object["observed_raw"] == nil)
    #expect(fixture.axActions.value.isEmpty)
}

@Test(arguments: ["absent", "unreadable", "boolean", "text", "nonfinite"])
func testIssue955ReadNeverInventsZeroForUnavailableSlider(_ kind: String) async throws {
    let fixture = LiveFixture()
    fixture.builder.setAttribute(fixture.builder.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let slider = fixture.builder.element(1005)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        guard CFEqual(element, slider), attribute == kAXValueAttribute as String else { return nil }
        switch kind {
        case "absent": return .success(nil)
        case "unreadable": return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        case "boolean": return .success(NSNumber(value: true))
        case "text": return .success("not a number" as NSString)
        default: return .success(NSNumber(value: Double.nan))
        }
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "readback_unavailable")
    #expect(object["parameter_read_status"] as? String == (["absent", "unreadable"].contains(kind) ? kind : "malformed"))
    #expect(object["observed_raw"] == nil)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test func testIssue955ReadRejectsReplacementControlAfterSampling() async throws {
    let fixture = LiveFixture()
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let slider = b.element(1005)
    let replacement = b.element(900_955)
    b.setAttribute(replacement, kAXRoleAttribute as String, kAXSliderRole as String)
    b.setAttribute(replacement, kAXDescriptionAttribute as String, "Threshold")
    b.setAttribute(replacement, kAXValueAttribute as String, 99.0)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if CFEqual(element, slider), attribute == kAXValueAttribute as String {
            b.setChildren(b.element(1004), fixture.runtime.ax.children(b.element(1004)).map { CFEqual($0, slider) ? replacement : $0 })
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["observed_raw"] == nil)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test func testIssue955ReadDoesNotSelectAnUnselectedTrack() async throws {
    let fixture = LiveFixture(trackSelected: false)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(), runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A")
    #expect(!(try #require(b.attributeValue(b.element(1100), kAXSelectedAttribute as String) as? Bool)))
    #expect(!fixture.axActions.value.contains(where: { $0.element == b.elementID(b.element(1100)) }))
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test func testIssue955ReadDoesNotRestoreIntoAChangedProject() async throws {
    let fixture = LiveFixture(controlsViewInitiallySelected: true, viewSettleDelay: 0)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if CFEqual(element, b.element(1005)), attribute == kAXValueAttribute as String {
            b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: "/tmp/Other.logicx").absoluteString)
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["observed_raw"] == nil)
    #expect(fixture.editorViewMenuPressCount.value == 1)
    #expect(fixture.controlsViewMenuPressCount.value == 0, "Do not apply an inverse after project ownership ended")
    #expect(!(try #require(object["plugin_view_restore_attempted"] as? Bool)))
    #expect(!(try #require(object["plugin_view_restore_observed"] as? Bool)))
    #expect(try #require(object["plugin_view_restore_unobserved"] as? Bool))
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test(arguments: ["track", "insert", "unit", "plugin", "value", "mode", "project_expected_path"])
func testIssue955PublicReadRejectsInvalidInputsBeforeTargetLookup(_ key: String) async throws {
    var params: [String: Value] = ["target_ref": .string("ins_unissued"), "param": .string("threshold")]
    params[key] = .object(["unexpected": .bool(true)])
    let result = await PluginsDispatcher.handle(
        verifiedGate: VerifiedOpGate(), command: "get_param_verified", params: params,
        router: ChannelRouter(), cache: StateCache(), targetRegistry: TargetRegistry()
    )
    let object = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "invalid_params")
}

@Test func testIssue955ReadStopsInverseWhenProjectChangesAfterMenuOpens() async throws {
    let fixture = LiveFixture(controlsViewInitiallySelected: true, viewSettleDelay: 0)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        // Restore preflight succeeded. Ownership ends while the inverse's menu is
        // being read, before its actual AXPick; entry-only checking is insufficient.
        if CFEqual(element, b.element(100_902)), attribute == kAXEnabledAttribute as String,
           fixture.editorViewMenuPressCount.value > 0 {
            b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: "/tmp/Other.logicx").absoluteString)
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["observed_raw"] == nil)
    #expect(fixture.controlsViewMenuPressCount.value == 0, "Ownership must be checked at the inverse AXPick, not only on restore entry")
    #expect(!(try #require(object["plugin_view_restore_observed"] as? Bool)))
    #expect(try #require(object["plugin_view_restore_unobserved"] as? Bool))
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test func testIssue955ReadStopsForwardViewPickWhenProjectChangesAfterMenuOpens() async throws {
    let fixture = LiveFixture(controlsViewRowLabel: "Limiter On", viewSettleDelay: 0)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if CFEqual(element, b.element(100_902)), attribute == kAXEnabledAttribute as String {
            b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: "/tmp/Other.logicx").absoluteString)
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams("limiter_on"), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["observed_raw"] == nil)
    #expect(fixture.controlsViewMenuPressCount.value == 0)
    #expect(fixture.editorViewMenuPressCount.value == 0)
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test(arguments: [false, true])
func testIssue955ReadRefusalReportsCleanupOfItsNewEditor(_ popupOpen: Bool) async throws {
    let fixture = LiveFixture(sliderBeforeReadable: false, pluginWindowPresent: false, openWindowOnSlotPress: true)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, onScreenWindowList: {
        popupOpen ? [[kCGWindowOwnerPID as String: 4242, kCGWindowNumber as String: 955,
                      kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel]] : []
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == (popupOpen ? "window_open_failed" : "readback_unavailable"))
    #expect(object["observed_raw"] == nil)
    #expect(try #require(object["editor_close_observed"] as? Bool), "Refusal must retain the observed cleanup result")
    #expect(fixture.targetOpenControlPressCount.value == 1)
    #expect(fixture.pluginCloseControlPressCount.value == 1)
    let remainingWindows = try #require(b.attributeValue(fixture.app, kAXWindowsAttribute as String) as? [AXUIElement])
    #expect(remainingWindows.count == 1, "The acquired editor must not leak on a popup or value-read refusal")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test(arguments: ["project", "slot", "editor"])
func testIssue955ReadDoesNotCloseAnEditorAfterOwnershipEnds(_ changed: String) async throws {
    let fixture = LiveFixture(pluginWindowPresent: false, openWindowOnSlotPress: true)
    let b = fixture.builder
    let arrange = b.element(1001)
    let editor = b.element(1004)
    let sampled = MutableBox(false)
    b.setAttribute(arrange, kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if CFEqual(element, b.element(1005)), attribute == kAXValueAttribute as String { sampled.value = true }
        // Parameter read and its identity bookends succeeded. Ownership ends
        // while cleanup obtains the close button, just before its AXPress.
        if sampled.value, CFEqual(element, editor), attribute == kAXCloseButtonAttribute as String {
            switch changed {
            case "project":
                b.setAttribute(arrange, kAXDocumentAttribute as String, URL(fileURLWithPath: "/tmp/Other.logicx").absoluteString)
            case "slot": b.setAttribute(b.element(1306), kAXDescriptionAttribute as String, "Noise Gate")
            default: b.setAttribute(editor, kAXTitleAttribute as String, "Another Track")
            }
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["observed_raw"] == nil)
    #expect(!(try #require(object["editor_close_attempted"] as? Bool)))
    #expect(!(try #require(object["editor_close_observed"] as? Bool)))
    #expect(try #require(object["editor_cleanup_unobserved"] as? Bool))
    #expect(object["editor_still_open"] == nil, "Lost custody cannot establish the original editor's residual state")
    #expect(fixture.pluginCloseControlPressCount.value == 0, "Do not close a window through lost ownership")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

@Test(arguments: ["read", "absent", "unreadable", "malformed"])
func testIssue955BooleanReadReportsTheActualDisplayStatus(_ status: String) async throws {
    let fixture = LiveFixture(controlsViewRowLabel: "Limiter On", controlsViewInitiallySelected: true, viewSettleDelay: 0)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        guard CFEqual(element, b.element(100_908)), attribute == kAXValueDescriptionAttribute as String else { return nil }
        switch status {
        case "read": return .success("Off" as NSString)
        case "absent": return .success(nil)
        case "unreadable": return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        default: return .success(NSNumber(value: 7))
        }
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams("limiter_on"), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A")
    #expect(!(try #require(object["observed_raw"] as? Bool)))
    #expect(object["display_read_status"] as? String == status)
    if status == "read" { #expect(object["observed_display"] as? String == "Off") }
    else { #expect(object["observed_display"] is NSNull) }
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test(arguments: [false, true])
func testIssue955ReadRejectsValueDriftDuringDisplayCollection(_ checkbox: Bool) async throws {
    let fixture = LiveFixture(controlsViewRowLabel: checkbox ? "Limiter On" : nil,
                              controlsViewInitiallySelected: checkbox, viewSettleDelay: 0)
    let b = fixture.builder
    let control = b.element(checkbox ? 100_908 : 1005)
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let runtime = parameterReadRuntime(fixture, attributeRead: { element, attribute in
        if CFEqual(element, control), attribute == kAXValueDescriptionAttribute as String {
            // Identity did not change, but the paired host display belongs to a
            // different raw value. Returning 51 with "60 %" would be misleading.
            b.setAttribute(control, kAXValueAttribute as String, checkbox ? true : 60.0)
            return .success((checkbox ? "On" : "60 %") as NSString)
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(
        params: parameterReadParams(checkbox ? "limiter_on" : "threshold"), runtime: runtime
    )
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["parameter_read_status"] as? String == "unstable")
    #expect(object["observed_raw"] == nil)
    #expect(object["observed_display"] == nil)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
    #expect(fixture.sliderWriteCount.value == 0)
}

@Test(arguments: ["track", "insert"])
func testIssue955PublicReadRejectsStringIndicesDeclaredAsIntegers(_ key: String) async throws {
    let result = await PluginsDispatcher.handle(
        verifiedGate: VerifiedOpGate(), command: "get_param_verified",
        params: ["target_ref": .string("ins_unissued"), "param": .string("threshold"), key: .string("0")],
        router: ChannelRouter(), cache: StateCache(), targetRegistry: TargetRegistry()
    )
    let object = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(object["error"] as? String == "invalid_params", "Typed input validation must precede target lookup")
}

@Test(arguments: ChannelEQBandCatalog.parameters.map(\.id))
func testIssue955ReadsEveryDeclaredEQNativeSlider(_ param: String) async throws {
    let metadata = try #require(ChannelEQBandCatalog.parameters.first(where: { $0.id == param }))
    let fixture = LiveFixture(thresholdDescription: metadata.axDescription, pluginSlotName: "Channel EQ", beforeValue: 51)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    var params = parameterReadParams(param)
    params["plugin"] = "Channel EQ"
    params["expected_plugin_identity"] = "logic.stock.effect.channel_eq"
    let result = await AccessibilityChannel.defaultGetParamVerified(params: params, runtime: parameterReadRuntime(fixture))
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String == "A")
    #expect(object["param"] as? String == param)
    #expect(object["observed_raw"] as? Double == 51)
    #expect(object["raw_unit"] as? String == metadata.rawUnit)
    #expect(object["observed_display"] as? String == "51 %")
    #expect(fixture.sliderWriteCount.value == 0)
    #expect(fixture.controlsCheckboxPressCount.value == 0)
}

private actor Issue955ReviewReadStartLatch {
    private var suspended: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            suspended = continuation
            ready?.resume()
            ready = nil
        }
    }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func release() {
        suspended?.resume()
        suspended = nil
    }
}

@Test func testIssue955ReviewCancelledReadCannotOpenAnEditor() async throws {
    let fixture = LiveFixture(pluginWindowPresent: false, openWindowOnSlotPress: true)
    fixture.builder.setAttribute(fixture.builder.element(1001), kAXDocumentAttribute as String,
        URL(fileURLWithPath: expectedPath).absoluteString)
    let latch = Issue955ReviewReadStartLatch()
    let task = Task {
        await latch.waitForRelease()
        #expect(Task.isCancelled)
        return await AccessibilityChannel.defaultGetParamVerified(
            params: parameterReadParams(), runtime: parameterReadRuntime(fixture))
    }
    await latch.waitUntilSuspended()
    task.cancel()
    await latch.release()
    let result = await task.value
    let object = try #require(sharedJSONObject(result.message))
    #expect(object["state"] as? String != "A")
    #expect(fixture.targetOpenControlPressCount.value == 0)
    #expect(fixture.axActions.value.isEmpty)
}

@Test(arguments: ["threshold", "limiter_on"], ["project", "slot"])
func testIssue955ReadAcquisitionStopsWhenRankingEndsCustody(_ param: String, _ changed: String) async throws {
    let fixture = LiveFixture(pluginWindowPresent: false, openWindowOnSlotPress: true)
    let b = fixture.builder
    b.setAttribute(b.element(1001), kAXDocumentAttribute as String, URL(fileURLWithPath: expectedPath).absoluteString)
    let ended = MutableBox(false)
    let runtime = parameterReadRuntime(fixture, actionNamesRead: { element in
        if CFEqual(element, b.element(13062)), !ended.value {
            ended.value = true
            if changed == "project" {
                b.setAttribute(b.element(1001), kAXDocumentAttribute as String, "file:///tmp/another.logicx/")
            } else {
                b.setAttribute(b.element(1306), kAXDescriptionAttribute as String, "Noise Gate")
            }
        }
        return nil
    })
    let result = await AccessibilityChannel.defaultGetParamVerified(params: parameterReadParams(param), runtime: runtime)
    let object = try #require(sharedJSONObject(result.message))
    #expect(ended.value)
    #expect(object["state"] as? String == "C")
    #expect(fixture.targetOpenControlPressCount.value == 0)
    #expect(fixture.axActions.value.isEmpty)
}
