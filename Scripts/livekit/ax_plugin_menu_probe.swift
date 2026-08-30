#!/usr/bin/env swift
// Raw Accessibility API witness for the #301, #306, and #369 live harnesses.
//
// System Events is deliberately not used for AXDescription here. It synthesises a description from
// AXRoleDescription when AXDescription is nil, which would turn #306's observed "no slider
// descriptions" into a false positive. This helper reports the raw AX attributes and performs only
// the named, reversible presses its Python harness requests.

import AppKit
import ApplicationServices
import Foundation

typealias JSON = [String: Any]

enum AXRead<Value> {
    case value(Value)
    case absent
    case failed(AXError)

    var status: String {
        switch self {
        case .value: return "success_with_value"
        case .absent: return "success_without_value"
        case .failed: return "failed"
        }
    }

    var errorCode: Any {
        guard case .failed(let error) = self else { return NSNull() }
        return error.rawValue
    }

    var value: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}

var axReadFailures: [JSON] = []

func elementIdentity(_ element: AXUIElement) -> String {
    "cfhash:\(String(CFHash(element), radix: 16))"
}

// Two AX errors are ANSWERS, not failures: the element has no such attribute, or the attribute
// holds no value. A menu item legitimately has no AXDescription and reports one of these on every
// read. Counting them as failures made `outcome` read `could_not_search` on a perfectly good walk,
// which stopped all three harnesses at their first precondition. Verified against AXError.h:
// kAXErrorAttributeUnsupported = -25205, kAXErrorNoValue = -25212.
let axAbsenceErrors: Set<Int32> = [
    AXError.attributeUnsupported.rawValue,
    AXError.noValue.rawValue,
]

func recordReadFailure(
    _ element: AXUIElement,
    attribute: String,
    error: AXError,
    readSite: String
) {
    // An absence is recorded on the element itself (status/error siblings); it does not belong in
    // the list that decides whether the search completed.
    guard !axAbsenceErrors.contains(error.rawValue) else { return }
    // Let the failing element identify itself. `read_site` is a function name, which is not enough
    // to find a stale reference among several call paths — diagnosing one kAXErrorIllegalArgument
    // took three runs because the receipt could say only "some description read failed". These
    // reads are best effort and may fail too on a dead reference, which is itself informative.
    var role = "<unreadable>"
    var roleValue: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
       let text = roleValue as? String {
        role = text
    }
    var title = "<unreadable>"
    var titleValue: AnyObject?
    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
       let text = titleValue as? String {
        title = text
    }
    axReadFailures.append([
        "attribute": attribute,
        "status": error.rawValue,
        "code": error.rawValue,
        "element_id": elementIdentity(element),
        "element_role": role,
        "element_title": title,
        "read_site": readSite,
    ])
}

func trackRead<T>(_ read: AXRead<T>, attribute: String) -> AXRead<T> {
    // Record failures at the actual AX call, where the element identity and read site are still
    // available. Recording only after a value conversion loses both and makes a JSON null
    // impossible to locate in a raw-AX receipt.
    return read
}

// Preserve success-with-value, success-with-absent, and failed AX requests. A raw `nil` loses the
// distinction and let failed slider reads masquerade as empty AXDescriptions or unsettable values.
func attr<T>(
    _ element: AXUIElement,
    _ attribute: String,
    readSite: String = #function
) -> AXRead<T> {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else {
        recordReadFailure(element, attribute: attribute, error: result, readSite: readSite)
        return .failed(result)
    }
    guard let value else { return .absent }
    guard let typed = value as? T else { return .absent }
    return .value(typed)
}

func role(_ element: AXUIElement) -> AXRead<String> {
    attr(element, kAXRoleAttribute as String)
}

func description(_ element: AXUIElement) -> AXRead<String> {
    attr(element, kAXDescriptionAttribute as String)
}

func title(_ element: AXUIElement) -> AXRead<String> {
    attr(element, kAXTitleAttribute as String)
}

func valueDescription(_ element: AXUIElement) -> AXRead<String> {
    attr(element, kAXValueDescriptionAttribute as String)
}

func textValue(_ element: AXUIElement) -> AXRead<String> {
    attr(element, kAXValueAttribute as String)
}

func boolAttribute(_ element: AXUIElement, _ attribute: String) -> AXRead<Bool> {
    switch attr(element, attribute) as AXRead<NSNumber> {
    case .value(let value): return .value(value.boolValue)
    case .absent: return .absent
    case .failed(let error): return .failed(error)
    }
}

func scalarValue(_ element: AXUIElement, _ attribute: String) -> AXRead<Any> {
    switch attr(element, attribute) as AXRead<AnyObject> {
    case .value(let raw):
        if let value = raw as? String { return .value(value) }
        if let value = raw as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .value(value.boolValue) }
            return .value(value.doubleValue)
        }
        return .absent
    case .absent:
        return .absent
    case .failed(let error):
        return .failed(error)
    }
}

func valueIsSettable(_ element: AXUIElement) -> AXRead<Bool> {
    var settable = DarwinBoolean(false)
    let result = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
    guard result == .success else {
        recordReadFailure(
            element,
            attribute: kAXValueAttribute as String,
            error: result,
            readSite: "AXUIElementIsAttributeSettable"
        )
        return .failed(result)
    }
    return .value(settable.boolValue)
}

func stringValue(_ read: AXRead<String>, attribute: String) -> String {
    switch trackRead(read, attribute: attribute) {
    case .value(let value): return value
    case .absent, .failed: return ""
    }
}

func roleText(_ element: AXUIElement) -> String {
    stringValue(role(element), attribute: kAXRoleAttribute as String)
}

func descriptionText(_ element: AXUIElement) -> String {
    stringValue(description(element), attribute: kAXDescriptionAttribute as String)
}

func titleText(_ element: AXUIElement) -> String {
    stringValue(title(element), attribute: kAXTitleAttribute as String)
}

func textValueText(_ element: AXUIElement) -> String {
    stringValue(textValue(element), attribute: kAXValueAttribute as String)
}

func scalarJSONValue(_ read: AXRead<Any>, attribute: String) -> Any {
    switch trackRead(read, attribute: attribute) {
    case .value(let value): return value
    case .absent, .failed: return NSNull()
    }
}

func scalarJSONWitness(_ read: AXRead<Any>, attribute: String) -> JSON {
    [
        "value": scalarJSONValue(read, attribute: attribute),
        "status": readStatus(read),
        "error": readError(read),
    ]
}

func boolJSONValue(_ read: AXRead<Bool>, attribute: String, absent: Any = NSNull()) -> Any {
    switch trackRead(read, attribute: attribute) {
    case .value(let value): return value
    case .absent, .failed: return absent
    }
}

func elementValue(_ read: AXRead<AXUIElement>, attribute: String) -> AXUIElement? {
    switch trackRead(read, attribute: attribute) {
    case .value(let value): return value
    case .absent, .failed: return nil
    }
}

func children(_ element: AXUIElement) -> AXRead<[AXUIElement]> {
    attr(element, kAXChildrenAttribute as String)
}

func childElements(_ element: AXUIElement) -> [AXUIElement] {
    switch trackRead(children(element), attribute: kAXChildrenAttribute as String) {
    case .value(let value): return value
    case .absent, .failed: return []
    }
}

func descendants(_ root: AXUIElement, _ depth: Int = 18) -> [AXUIElement] {
    var result: [AXUIElement] = []
    func visit(_ element: AXUIElement, _ remaining: Int) {
        result.append(element)
        guard remaining > 0 else { return }
        for child in childElements(element) { visit(child, remaining - 1) }
    }
    visit(root, depth)
    return result
}

func readStatus<Value>(_ read: AXRead<Value>) -> String {
    read.status
}

func readError<Value>(_ read: AXRead<Value>) -> Any {
    read.errorCode
}

func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
    CFEqual(lhs, rhs)
}

func snapshot(_ element: AXUIElement) -> JSON {
    let roleRead = role(element)
    let descriptionRead = description(element)
    let titleRead = title(element)
    let valueDescriptionRead = valueDescription(element)
    let settableRead = valueIsSettable(element)
    let enabledRead = boolAttribute(element, kAXEnabledAttribute as String)
    let valueRead = scalarValue(element, kAXValueAttribute as String)
    var out: JSON = [
        // The same identifier is carried by ax_read_failures, so a failed null can be located in
        // this census instead of being attributed only to an attribute name shared by many nodes.
        "element_id": elementIdentity(element),
        // The historic scalar fields remain for old callers. Their status/error siblings retain
        // the AX result, so empty/false no longer silently means success-with-absent.
        "role": stringValue(roleRead, attribute: kAXRoleAttribute as String),
        "role_status": readStatus(roleRead),
        "role_error": readError(roleRead),
        "description": stringValue(descriptionRead, attribute: kAXDescriptionAttribute as String),
        "description_status": readStatus(descriptionRead),
        "description_error": readError(descriptionRead),
        "title": stringValue(titleRead, attribute: kAXTitleAttribute as String),
        "title_status": readStatus(titleRead),
        "title_error": readError(titleRead),
        "value_description": stringValue(valueDescriptionRead,
                                         attribute: kAXValueDescriptionAttribute as String),
        "value_description_status": readStatus(valueDescriptionRead),
        "value_description_error": readError(valueDescriptionRead),
        "value_settable": boolJSONValue(settableRead, attribute: kAXValueAttribute as String,
                                          absent: false),
        "value_settable_status": readStatus(settableRead),
        "value_settable_error": readError(settableRead),
    ]
    out["enabled"] = boolJSONValue(enabledRead, attribute: kAXEnabledAttribute as String)
    out["enabled_status"] = readStatus(enabledRead)
    out["enabled_error"] = readError(enabledRead)
    out["value"] = scalarJSONValue(valueRead, attribute: kAXValueAttribute as String)
    out["value_status"] = readStatus(valueRead)
    out["value_error"] = readError(valueRead)
    return out
}

func elementName(_ element: AXUIElement) -> String {
    let fromTitle = titleText(element)
    return fromTitle.isEmpty ? descriptionText(element) : fromTitle
}

func candidateOutcome(_ count: Int) -> String {
    if count == 0 { return "not_found" }
    if count == 1 { return "searched" }
    return "ambiguous"
}

func emit(_ body: JSON) {
    var completed = body
    // Zero candidates and a failed AX walk are different outcomes. The counts remain in the result,
    // while this field lets a caller reject a partial success without parsing every nested witness.
    if !axReadFailures.isEmpty {
        completed["outcome"] = "could_not_search"
        completed["ax_read_failures"] = axReadFailures
    } else if completed["error"] != nil {
        completed["outcome"] = "could_not_search"
    } else if completed["outcome"] == nil {
        completed["outcome"] = "searched"
    }
    guard JSONSerialization.isValidJSONObject(completed),
          let data = try? JSONSerialization.data(withJSONObject: completed, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        print("{\"error\":\"could not encode probe result\"}")
        return
    }
    print(string)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    emit(["error": "usage: ax_plugin_menu_probe.swift <mode> <json-config>"])
    exit(2)
}

let mode = arguments[1]
let configData = Data(arguments[2].utf8)
let config = ((try? JSONSerialization.jsonObject(with: configData)) as? JSON) ?? [:]

func configuredString(_ key: String) -> String {
    config[key] as? String ?? ""
}

func configuredOptionalString(_ key: String) -> String? {
    config[key] as? String
}

func configuredStrings(_ key: String) -> [String] {
    config[key] as? [String] ?? []
}

func configuredStringFamily(_ key: String) -> [String] {
    if let values = config[key] as? [String] { return values }
    if let value = config[key] as? String { return [value] }
    return []
}

guard let logic = NSWorkspace.shared.runningApplications.first(
    where: { $0.bundleIdentifier == "com.apple.logic10" }
) else {
    emit(["error": "Logic Pro is not running"])
    exit(3)
}

let app = AXUIElementCreateApplication(logic.processIdentifier)

func windows() -> [AXUIElement] {
    switch trackRead(attr(app, kAXWindowsAttribute as String) as AXRead<[AXUIElement]>,
                     attribute: kAXWindowsAttribute as String) {
    case .value(let value): return value
    case .absent, .failed: return []
    }
}

func newWindows(since before: [AXUIElement]) -> [AXUIElement] {
    // AX exposes no direct edge from an insert slot to the plug-in window its button opens. This is
    // deliberately application-wide rather than a pretend binding; openPlugin emits that widening
    // in its receipt so harnesses do not present the sole new Logic window as slot-proven.
    windows().filter { candidate in !before.contains(where: { same($0, candidate) }) }
}

func windows(titled expectedTitle: String) -> [AXUIElement] {
    windows().filter { titleText($0) == expectedTitle }
}

func press(_ element: AXUIElement, _ action: String = kAXPressAction as String) -> Int {
    Int(AXUIElementPerformAction(element, action as CFString).rawValue)
}

func closeWindow(_ window: AXUIElement, closeLabel: String) -> JSON {
    let buttons = descendants(window).filter {
        roleText($0) == "AXButton" && descriptionText($0) == closeLabel
    }
    var result: JSON = [
        "close_button_candidates": buttons.map(snapshot),
        "pressed": false,
        "press_status": NSNull(),
    ]
    if buttons.count == 1 {
        result["pressed"] = true
        result["press_status"] = press(buttons[0])
        usleep(700_000)
    }
    result["window_still_present"] = windows().contains(where: { same($0, window) })
    return result
}

func pluginSlots(in root: AXUIElement, named name: String) -> [AXUIElement] {
    descendants(root).filter { roleText($0) == "AXGroup" && descriptionText($0) == name }
}

func pluginSlots(named name: String) -> [AXUIElement] {
    windows().flatMap { window in
        pluginSlots(in: window, named: name)
    }
}

func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct AncestorGroupSearch {
    let found: Bool
    let matchingDescription: String?
    let boundHit: Bool
}

// The Inspector can expose a selected track's channel strip as another AXLayoutArea named
// "믹서". Only the Mixer pane's layout area is contained by an AXGroup with that same label.
// Keep the parent walk bounded so a malformed AX tree cannot make the witness hang; callers report
// a bound hit as an unresolved observation rather than treating it as a definitive non-match.
func matchingGroupAncestor(
    of element: AXUIElement,
    named expectedDescriptions: Set<String>,
    maximumDepth: Int = 12
) -> AncestorGroupSearch {
    var current = element
    for _ in 0..<maximumDepth {
        guard let parent = elementValue(
            attr(current, kAXParentAttribute as String) as AXRead<AXUIElement>,
            attribute: kAXParentAttribute as String
        ) else {
            return AncestorGroupSearch(found: false, matchingDescription: nil, boundHit: false)
        }
        if roleText(parent) == (kAXGroupRole as String) {
            let parentDescription = trimmed(descriptionText(parent))
            if expectedDescriptions.contains(parentDescription) {
                return AncestorGroupSearch(
                    found: true,
                    matchingDescription: parentDescription,
                    boundHit: false
                )
            }
        }
        current = parent
    }

    // We inspected the allowed number of ancestors. A further parent means the answer is unknown
    // at this bound (including in a cycle), so do not silently classify this layout area as out.
    let hasMoreAncestors = elementValue(
        attr(current, kAXParentAttribute as String) as AXRead<AXUIElement>,
        attribute: kAXParentAttribute as String
    )
    return AncestorGroupSearch(
        found: false,
        matchingDescription: nil,
        boundHit: hasMoreAncestors != nil
    )
}

struct MixerContainerSearch {
    let layoutAreasSeen: [AXUIElement]
    let containers: [AXUIElement]
    let ancestorSearchBoundHitCount: Int
}

func mixerContainers(named mixerLabels: [String]) -> MixerContainerSearch {
    let targets = Set(mixerLabels.map(trimmed))
    guard !targets.isEmpty else {
        return MixerContainerSearch(
            layoutAreasSeen: [],
            containers: [],
            ancestorSearchBoundHitCount: 0
        )
    }
    let layoutAreasSeen = windows().flatMap { window in
        descendants(window).filter { container in
            // Require the layout-area role first: Logic exposes an AXGroup with the same mixer
            // description, but channel strips are descendants of the AXLayoutArea.
            roleText(container) == (kAXLayoutAreaRole as String)
        }
    }
    var ancestorSearchBoundHitCount = 0
    var containers: [AXUIElement] = []
    for container in layoutAreasSeen {
        // An AXLayoutArea outside a labelled AXGroup cannot be the Mixer pane, so resolve the
        // ancestry before asking it for AXDescription. Live AXLayoutArea elements can answer that
        // read with kAXErrorIllegalArgument even while their AXRole read succeeds.
        let ancestor = matchingGroupAncestor(
            of: container,
            named: targets
        )
        if ancestor.boundHit { ancestorSearchBoundHitCount += 1 }
        guard ancestor.found, let ancestorDescription = ancestor.matchingDescription else { continue }

        // Only a layout area inside a labelled mixer group is a description candidate. Require
        // the same exact label so one configured synonym cannot admit another by coincidence.
        // Keep a failed read observable: descriptionText records it in ax_read_failures.
        let layoutAreaDescription = trimmed(descriptionText(container))
        if layoutAreaDescription == ancestorDescription {
            containers.append(container)
            continue
        }

        // A nearer ancestor can use a different configured synonym. The first ancestry walk has
        // already proved this layout area is in the mixer branch; now preserve the exact-label
        // rule by checking whether the layout area's own label occurs farther up that branch.
        guard targets.contains(layoutAreaDescription) else { continue }
        let exactAncestor = matchingGroupAncestor(
            of: container,
            named: [layoutAreaDescription]
        )
        if exactAncestor.boundHit { ancestorSearchBoundHitCount += 1 }
        if exactAncestor.found {
            containers.append(container)
        }
    }
    return MixerContainerSearch(
        layoutAreasSeen: layoutAreasSeen,
        containers: containers,
        ancestorSearchBoundHitCount: ancestorSearchBoundHitCount
    )
}

func channelStrips(named trackLabel: String, in mixer: AXUIElement) -> [AXUIElement] {
    let target = trimmed(trackLabel)
    return descendants(mixer).filter { strip in
        roleText(strip) == (kAXLayoutItemRole as String) && trimmed(descriptionText(strip)) == target
    }
}

struct PluginSlotSearch {
    let slots: [AXUIElement]
    let unscopedSlots: [AXUIElement]
    let trackLabel: String?
    let mixerLayoutAreasSeen: [AXUIElement]?
    let mixerContainers: [AXUIElement]?
    let mixerAncestorSearchBoundHitCount: Int?
    let matchingStrips: [AXUIElement]
    let scopedSlots: [AXUIElement]?
}

func pluginSlotSearch(
    named slotName: String,
    trackLabel: String?,
    mixerLabels: [String]? = nil
) -> PluginSlotSearch {
    let unscopedSlots = pluginSlots(named: slotName)
    guard let trackLabel else {
        return PluginSlotSearch(
            slots: unscopedSlots,
            unscopedSlots: unscopedSlots,
            trackLabel: nil,
            mixerLayoutAreasSeen: nil,
            mixerContainers: nil,
            mixerAncestorSearchBoundHitCount: nil,
            matchingStrips: [],
            scopedSlots: nil
        )
    }

    let mixerSearch = mixerContainers(named: mixerLabels ?? [])
    let mixerContainers = mixerSearch.containers
    // Never widen this search back to the window: the arrange area's track header has the same
    // AXLayoutItem role and track description as the mixer strip. An unresolved mixer is therefore
    // a refusal condition, not permission to choose an identically named element by tree position.
    guard mixerContainers.count == 1, let mixer = mixerContainers.first else {
        return PluginSlotSearch(
            slots: [],
            unscopedSlots: unscopedSlots,
            trackLabel: trackLabel,
            mixerLayoutAreasSeen: mixerSearch.layoutAreasSeen,
            mixerContainers: mixerContainers,
            mixerAncestorSearchBoundHitCount: mixerSearch.ancestorSearchBoundHitCount,
            matchingStrips: [],
            scopedSlots: nil
        )
    }

    let matchingStrips = channelStrips(named: trackLabel, in: mixer)
    // Resolve the strip exactly before descending into it. The probe reports zero or many matching
    // strips as a refusal condition; choosing one by tree order would open a plug-in on the wrong
    // track when names are duplicated.
    guard matchingStrips.count == 1, let strip = matchingStrips.first else {
        return PluginSlotSearch(
            slots: [],
            unscopedSlots: unscopedSlots,
            trackLabel: trackLabel,
            mixerLayoutAreasSeen: mixerSearch.layoutAreasSeen,
            mixerContainers: mixerContainers,
            mixerAncestorSearchBoundHitCount: mixerSearch.ancestorSearchBoundHitCount,
            matchingStrips: matchingStrips,
            scopedSlots: nil
        )
    }

    let scopedSlots = pluginSlots(in: strip, named: slotName)
    return PluginSlotSearch(
        slots: scopedSlots,
        unscopedSlots: unscopedSlots,
        trackLabel: trackLabel,
        mixerLayoutAreasSeen: mixerSearch.layoutAreasSeen,
        mixerContainers: mixerContainers,
        mixerAncestorSearchBoundHitCount: mixerSearch.ancestorSearchBoundHitCount,
        matchingStrips: matchingStrips,
        scopedSlots: scopedSlots
    )
}

func slotSearchReport(_ search: PluginSlotSearch) -> JSON {
    var result: JSON = [
        "slot_count": search.slots.count,
        "slots": search.slots.map(snapshot),
        "outcome": candidateOutcome(search.slots.count),
    ]
    guard let trackLabel = search.trackLabel else { return result }

    // Keep the full-window census beside the scoped one so evidence can show that the name
    // narrowed the search, rather than merely reporting a convenient single result.
    result["track_label"] = trackLabel
    result["unscoped_slot_count"] = search.unscopedSlots.count
    result["unscoped_slots"] = search.unscopedSlots.map(snapshot)
    result["mixer_layout_areas_seen"] = search.mixerLayoutAreasSeen?.count ?? 0
    result["mixer_container_count"] = search.mixerContainers?.count ?? 0
    result["mixer_containers"] = search.mixerContainers?.map(snapshot) ?? []
    let mixerAncestorSearchBoundHitCount = search.mixerAncestorSearchBoundHitCount ?? 0
    result["mixer_ancestor_search_bound_hit"] = mixerAncestorSearchBoundHitCount > 0
    result["mixer_ancestor_search_bound_hit_count"] = mixerAncestorSearchBoundHitCount
    result["matching_strip_count"] = search.matchingStrips.count
    result["matching_strips"] = search.matchingStrips.map(snapshot)
    result["scoped_slot_count"] = search.scopedSlots?.count ?? NSNull()
    result["scoped_slots"] = search.scopedSlots?.map(snapshot) ?? []
    return result
}

func openPlugin(
    slotName: String,
    openLabel: String,
    trackLabel: String? = nil,
    mixerLabels: [String]? = nil,
    beforePress: ((AXUIElement) -> Void)? = nil
) -> (JSON, AXUIElement?, AXUIElement?) {
    let search = pluginSlotSearch(
        named: slotName,
        trackLabel: trackLabel,
        mixerLabels: mixerLabels
    )
    let slots = search.slots
    var result = slotSearchReport(search)
    result.merge([
        "open_button_candidates": [],
        "pressed_children": [],
        "open_press_status": NSNull(),
        "opened_windows": [],
    ]) { _, new in new }
    guard slots.count == 1 else { return (result, nil, nil) }

    let slot = slots[0]
    // The caller can take a negative-control reading before this helper mutates anything. In #301
    // that is the bypass value: reading it after the Open press would not catch an Open path that
    // toggled it and toggled it back before the witness looked.
    beforePress?(slot)
    let buttons = childElements(slot).filter {
        roleText($0) == "AXButton" && descriptionText($0) == openLabel
    }
    result["slot_children"] = childElements(slot).map(snapshot)
    result["open_button_candidates"] = buttons.map(snapshot)
    guard buttons.count == 1 else {
        result["outcome"] = candidateOutcome(buttons.count)
        return (result, slot, nil)
    }

    let before = windows()
    result["pressed_children"] = [snapshot(buttons[0])]
    result["open_press_status"] = press(buttons[0])
    usleep(1_400_000)
    let opened = newWindows(since: before)
    result["opened_windows_scope"] = "all_logic_application_windows"
    result["opened_windows_scope_widened_from_pressed_slot"] = true
    result["opened_windows_scope_note"] = "new windows are not bound to the pressed \(slotName) slot"
    result["opened_windows"] = opened.map(snapshot)
    result["outcome"] = candidateOutcome(opened.count)
    return (result, slot, opened.count == 1 ? opened[0] : nil)
}

func bandCheckboxes(in group: AXUIElement) -> [JSON] {
    descendants(group).filter { roleText($0) == "AXCheckBox" }.map(snapshot)
}

func sliders(in root: AXUIElement) -> [JSON] {
    descendants(root).filter { roleText($0) == "AXSlider" }.map(snapshot)
}

func rowCensus(in root: AXUIElement) -> [JSON] {
    descendants(root).filter { roleText($0) == "AXRow" }.map { row in
        let cells = descendants(row, 6).filter { roleText($0) == "AXCell" }
        let cellData: [JSON] = cells.map { cell in
            let staticTexts = descendants(cell, 6).filter { roleText($0) == "AXStaticText" }
            let controls = descendants(cell, 6).filter {
                ["AXSlider", "AXRadioButton", "AXPopUpButton"].contains(roleText($0))
            }
            return [
                "static_texts": staticTexts.map { textValueText($0).isEmpty ? elementName($0) : textValueText($0) },
                "control_roles": controls.map(roleText),
            ]
        }
        return ["cells": cellData]
    }
}

func menuItems(for button: AXUIElement) -> [AXUIElement] {
    // The View button is the witness boundary. Falling back to every app menu item silently widened
    // a failed local lookup into an unrelated menu match, exactly like the mixer search this file
    // already keeps scoped. An empty local result stays empty and the caller's outcome says so.
    descendants(button, 8).filter { roleText($0) == "AXMenuItem" }
}

func selectView(in window: AXUIElement, viewLabels: [String], wanted: String) -> JSON {
    let buttons = descendants(window).filter {
        roleText($0) == "AXMenuButton" && viewLabels.contains(descriptionText($0))
    }
    var result: JSON = [
        "button_candidates": buttons.map(snapshot),
        "items": [],
        "item_candidates": [],
        "pressed": false,
        "show_menu_status": NSNull(),
        "press_status": NSNull(),
        "outcome": candidateOutcome(buttons.count),
    ]
    guard buttons.count == 1 else { return result }

    result["show_menu_status"] = press(buttons[0], kAXShowMenuAction as String)
    usleep(700_000)
    let items = menuItems(for: buttons[0])
    let selected = items.filter { elementName($0) == wanted }
    result["items"] = items.map(snapshot)
    result["item_candidates"] = selected.map(snapshot)
    result["outcome"] = candidateOutcome(selected.count)
    guard selected.count == 1 else { return result }

    result["pressed"] = true
    result["press_status"] = press(selected[0])
    usleep(1_300_000)
    return result
}

func runChannelEQ() {
    let slotName = configuredString("slot_label")
    let openLabel = configuredString("open_label")
    let closeLabel = configuredString("close_label")
    let bypassLabels = configuredStrings("bypass_labels")
    // Scope the slot search the way every other mode here does. Without it a `Channel EQ` search
    // finds TWO: the mixer strip's insert and the Inspector's copy of the same strip for the
    // selected track. They are the same plug-in seen twice, and refusing on `slot_count == 2` is
    // correct but unusable. Optional so the unscoped behaviour is unchanged for callers that do not
    // pass a track.
    let trackLabelRaw = configuredString("track_label")
    let trackLabel: String? = trackLabelRaw.isEmpty ? nil : trackLabelRaw
    let mixerLabels = configuredStrings("mixer_labels")
    var result: JSON = ["frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
    var bypasses: [AXUIElement] = []
    var bypassBefore: AXRead<Any> = .absent
    var bypassAfter: AXRead<Any> = .absent
    let (openResult, slot, opened) = openPlugin(
        slotName: slotName,
        openLabel: openLabel,
        trackLabel: trackLabel,
        mixerLabels: mixerLabels.isEmpty ? nil : mixerLabels
    ) { slot in
        bypasses = childElements(slot).filter {
            roleText($0) == "AXCheckBox" && bypassLabels.contains(descriptionText($0))
        }
        if bypasses.count == 1 {
            bypassBefore = scalarValue(bypasses[0], kAXValueAttribute as String)
        }
    }
    result["open"] = openResult
    guard slot != nil else {
        result["outcome"] = openResult["outcome"] ?? "not_found"
        emit(result)
        return
    }

    result["bypass_candidates"] = bypasses.map(snapshot)
    let bypassBeforeWitness = scalarJSONWitness(bypassBefore, attribute: kAXValueAttribute as String)
    result["bypass_before"] = bypassBeforeWitness["value"]
    result["bypass_before_status"] = bypassBeforeWitness["status"]
    result["bypass_before_error"] = bypassBeforeWitness["error"]

    guard let opened else {
        result["outcome"] = openResult["outcome"] ?? "not_found"
        if bypasses.count == 1 {
            bypassAfter = scalarValue(bypasses[0], kAXValueAttribute as String)
        }
        let bypassAfterWitness = scalarJSONWitness(bypassAfter, attribute: kAXValueAttribute as String)
        result["bypass_after"] = bypassAfterWitness["value"]
        result["bypass_after_status"] = bypassAfterWitness["status"]
        result["bypass_after_error"] = bypassAfterWitness["error"]
        emit(result)
        return
    }

    let groups = descendants(opened).filter {
        roleText($0) == "AXGroup" && descriptionText($0) == "EQ"
    }
    result["eq_group_count"] = groups.count
    result["outcome"] = candidateOutcome(groups.count)
    result["band_checkboxes"] = groups.count == 1 ? bandCheckboxes(in: groups[0]) : []
    result["sliders"] = groups.count == 1 ? sliders(in: groups[0]) : []
    result["close"] = closeWindow(opened, closeLabel: closeLabel)
    if bypasses.count == 1 {
        bypassAfter = scalarValue(bypasses[0], kAXValueAttribute as String)
    }
    let bypassAfterWitness = scalarJSONWitness(bypassAfter, attribute: kAXValueAttribute as String)
    result["bypass_after"] = bypassAfterWitness["value"]
    result["bypass_after_status"] = bypassAfterWitness["status"]
    result["bypass_after_error"] = bypassAfterWitness["error"]
    emit(result)
}

func runPluginSlot() {
    let search = pluginSlotSearch(
        named: configuredString("slot_label"),
        trackLabel: configuredOptionalString("track_label"),
        mixerLabels: configuredStringFamily("mixer_label")
    )
    let slots = search.slots
    var result = slotSearchReport(search)
    result["frontmost_bundle_id"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    result["slot_children"] = slots.count == 1 ? childElements(slots[0]).map(snapshot) : []
    emit(result)
}

func runCompressor() {
    let slotName = configuredString("slot_label")
    let openLabel = configuredString("open_label")
    let closeLabel = configuredString("close_label")
    let viewLabels = configuredStrings("view_labels")
    let controlsLabel = configuredString("controls_label")
    let editorLabel = configuredString("editor_label")
    var result: JSON = ["frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
    let (openResult, _, opened) = openPlugin(
        slotName: slotName,
        openLabel: openLabel,
        trackLabel: configuredOptionalString("track_label"),
        mixerLabels: configuredStringFamily("mixer_label")
    )
    result["open"] = openResult
    guard let opened else {
        result["outcome"] = openResult["outcome"] ?? "not_found"
        emit(result)
        return
    }

    result["native_editor_sliders"] = sliders(in: opened)
    let openedWindowTitle = titleText(opened)
    let controlsSelection = selectView(in: opened, viewLabels: viewLabels, wanted: controlsLabel)
    result["controls_selection"] = controlsSelection
    if let outcome = controlsSelection["outcome"] as? String, outcome != "searched" {
        result["outcome"] = outcome
    }

    // `opened` belongs to the pre-switch editor tree. kAXErrorIllegalArgument on an AXDescription
    // read is the signature of using that stale AXUIElement after the view rebuild, so enumerate a
    // fresh window before taking the Controls census.
    let controlsWindows = windows(titled: openedWindowTitle)
    result["controls_window_count"] = controlsWindows.count
    guard controlsWindows.count == 1, let controlsWindow = controlsWindows.first else {
        result["outcome"] = candidateOutcome(controlsWindows.count)
        emit(result)
        return
    }
    result["controls_rows"] = rowCensus(in: controlsWindow)
    result["controls_sliders"] = sliders(in: controlsWindow)
    let editorSelection = selectView(in: controlsWindow, viewLabels: viewLabels, wanted: editorLabel)
    result["editor_selection"] = editorSelection
    if result["outcome"] == nil,
       let outcome = editorSelection["outcome"] as? String, outcome != "searched" {
        result["outcome"] = outcome
    }

    // The Editor selection rebuilds the subtree again; this is a separate, fresh-tree census.
    let editorWindows = windows(titled: openedWindowTitle)
    result["editor_window_count"] = editorWindows.count
    guard editorWindows.count == 1, let editorWindow = editorWindows.first else {
        result["outcome"] = candidateOutcome(editorWindows.count)
        emit(result)
        return
    }
    result["editor_after_restore_sliders"] = sliders(in: editorWindow)
    result["rows_after_restore"] = rowCensus(in: editorWindow)
    result["close"] = closeWindow(editorWindow, closeLabel: closeLabel)
    emit(result)
}

func path(_ elements: [AXUIElement]) -> [JSON] {
    elements.map(snapshot)
}

func oneMenuChild(of element: AXUIElement) -> [AXUIElement] {
    childElements(element).filter { roleText($0) == "AXMenu" }
}

func runExportMenu() {
    let fileLabels = configuredStrings("file_labels")
    let exportLabel = configuredString("export_label")
    let allTracksLabel = configuredString("all_tracks_label")
    let oneTrackLabel = configuredString("one_track_label")
    let openLabel = configuredString("open_label")
    var result: JSON = ["frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
    guard let menuBar = elementValue(
        attr(app, kAXMenuBarAttribute as String) as AXRead<AXUIElement>,
        attribute: kAXMenuBarAttribute as String
    ) else {
        result["error"] = "Logic has no AXMenuBar"
        emit(result)
        return
    }
    let fileItems = childElements(menuBar).filter {
        roleText($0) == "AXMenuBarItem" && fileLabels.contains(elementName($0))
    }
    result["file_candidates"] = fileItems.map(snapshot)
    guard fileItems.count == 1 else {
        result["outcome"] = candidateOutcome(fileItems.count)
        emit(result)
        return
    }

    let menus = oneMenuChild(of: fileItems[0])
    result["file_menu_candidates"] = menus.map(snapshot)
    guard menus.count == 1 else {
        result["outcome"] = candidateOutcome(menus.count)
        emit(result)
        return
    }

    let fileMenu = menus[0]
    let exportItems = childElements(fileMenu).filter {
        roleText($0) == "AXMenuItem" && elementName($0) == exportLabel
    }
    let openItems = childElements(fileMenu).filter {
        roleText($0) == "AXMenuItem" && elementName($0) == openLabel
    }
    result["export_candidates"] = exportItems.map(snapshot)
    result["open_candidates"] = openItems.map(snapshot)
    result["open_path"] = openItems.count == 1 ? path([fileItems[0], fileMenu, openItems[0]]) : []
    guard exportItems.count == 1 else {
        result["outcome"] = candidateOutcome(exportItems.count)
        emit(result)
        return
    }

    let exportMenus = oneMenuChild(of: exportItems[0])
    result["export_menu_candidates"] = exportMenus.map(snapshot)
    guard exportMenus.count == 1 else {
        result["outcome"] = candidateOutcome(exportMenus.count)
        emit(result)
        return
    }

    let leaves = childElements(exportMenus[0]).filter { roleText($0) == "AXMenuItem" }
    let allTracks = leaves.filter { elementName($0) == allTracksLabel }
    let oneTrack = leaves.filter { elementName($0) == oneTrackLabel }
    result["all_tracks_candidates"] = allTracks.map(snapshot)
    result["one_track_candidates"] = oneTrack.map(snapshot)
    result["all_tracks_path"] = allTracks.count == 1
        ? path([fileItems[0], fileMenu, exportItems[0], exportMenus[0], allTracks[0]]) : []
    result["one_track_path"] = oneTrack.count == 1
        ? path([fileItems[0], fileMenu, exportItems[0], exportMenus[0], oneTrack[0]]) : []
    if allTracks.count != 1 {
        result["outcome"] = candidateOutcome(allTracks.count)
    } else if oneTrack.count != 1 {
        result["outcome"] = candidateOutcome(oneTrack.count)
    }
    emit(result)
}

switch mode {
case "channel-eq": runChannelEQ()
case "compressor": runCompressor()
case "plugin-slot": runPluginSlot()
case "export-menu": runExportMenu()
default:
    emit(["error": "unknown mode: \(mode)"])
    exit(2)
}
