import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// Delete a marker through the Marker List itself, so the operation works on a default install.
    ///
    /// `nav.delete_marker` previously routed only to `[.midiKeyCommands, .cgEvent]`, which means it
    /// does nothing until the operator has installed the key-command preset AND performed a manual
    /// MIDI Learn inside Logic. Until then the CC goes out, Logic has nothing bound to it, the marker
    /// survives, and the caller is told `readback_unavailable` — a setup prerequisite reported as a
    /// readback problem. Deleting a marker should not require a hand-configured MIDI binding.
    ///
    /// Measured on Logic 12.3 while building this path:
    ///   * each Marker List row carries a custom `Delete` action, and performing it does **nothing** —
    ///     the return code says success and the marker stays. Only the observed effect counts.
    ///   * selecting the row does work: the table reports it in `AXSelectedRows`.
    ///   * with the row selected AND keyboard focus inside the Marker table, a Delete key removes it.
    ///
    /// That last condition is the whole safety story. The same keystroke sent while focus sits in the
    /// arrange area deletes the selected REGION or TRACK instead. So focus is verified to be inside
    /// the marker table immediately before the key is posted, and the operation refuses otherwise
    /// rather than pressing Delete somewhere unknown.
    static func defaultDeleteMarker(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production,
        mouse: AXMouseHelper.Runtime = .production
    ) async -> ChannelResult {
        guard index >= 0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "nav.delete_marker requires an index >= 0",
                extras: ["operation": "nav.delete_marker", "write_attempted": false]
            ))
        }

        let openResult = await defaultOpenMarkerList(runtime: runtime)
        guard openResult.isSuccess else { return openResult }

        guard let binding = AXLogicProElements.markerListBinding(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "The Marker List could not be bound after opening.",
                extras: ["operation": "nav.delete_marker", "requested_index": index, "write_attempted": false]
            ))
        }
        let window = binding.window
        let before = AXLogicProElements.enumerateMarkersFromListWindow(window, runtime: runtime.ax)
        guard let target = before.first(where: { $0.id == index }) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Marker index \(index) was not found in the Marker List",
                extras: [
                    "operation": "nav.delete_marker",
                    "requested_index": index,
                    "marker_count": before.count,
                    "write_attempted": false,
                ]
            ))
        }

        // Identify the survivor set by name+position rather than by index: indices renumber when a
        // row disappears, so comparing indices after the write would prove nothing.
        let expectedSurvivors = before.filter { $0.id != index }
            .map { "\($0.name)@\($0.position)" }
            .sorted()
        var extras: [String: Any] = [
            "operation": "nav.delete_marker",
            "requested_index": index,
            "target_name": target.name,
            "target_position": target.position,
            "marker_count_before": before.count,
        ]

        guard selectMarkerRowForDeletion(index, in: window, runtime: runtime.ax) else {
            // A weaker key-command channel cannot answer an indexed delete: it ignores `index`
            // and fires CC 45 blindly, without proving which marker would be removed.
            extras["write_attempted"] = false
            extras["fallback_unsafe"] = true
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Marker index \(index) could not be selected, so nothing was pressed",
                extras: extras
            ))
        }

        guard markerTableHasKeyboardFocus(runtime: runtime) else {
            // Refusing here is the point: the same keystroke elsewhere deletes a region or a track.
            extras["write_attempted"] = false
            extras["fallback_unsafe"] = true
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "The Marker List did not hold keyboard focus, so Delete was not pressed — "
                    + "the same key deletes a region or a track when focus is in the arrange area.",
                extras: extras
            ))
        }

        extras["write_attempted"] = true
        _ = mouse.postKeyEvent(0x33)  // kVK_Delete
        mouse.sleepMicros(400_000)

        guard let afterBinding = AXLogicProElements.markerListBinding(runtime: runtime),
              afterBinding.projectDocument == binding.projectDocument,
              CFEqual(afterBinding.window, binding.window) else {
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        // The Marker List enumeration is not stable immediately after a write: measured live, two
        // reads taken back to back can disagree, and a blank row keeps rendering the previous row's
        // name. Verifying against a single read produced a State A for a marker that was still
        // there. So require two consecutive identical readings before believing either of them, and
        // report State B when they will not settle rather than certifying a guess.
        var survivors: [String] = []
        var settled = false
        var previous: [String]?
        for _ in 0..<6 {
            let reading = AXLogicProElements.enumerateMarkersFromListWindow(
                afterBinding.window, runtime: runtime.ax
            ).map { "\($0.name)@\($0.position)" }.sorted()
            if let previous, previous == reading {
                survivors = reading
                settled = true
                break
            }
            previous = reading
            mouse.sleepMicros(250_000)
        }
        guard settled else {
            extras["readback_settled"] = false
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        extras["readback_settled"] = true
        extras["marker_count_after"] = survivors.count

        guard survivors == expectedSurvivors else {
            // Either the target survived, or something else went with it. Both are mismatches, and
            // saying which is more useful than a bare count.
            extras["observed_survivors"] = survivors
            extras["expected_survivors"] = expectedSurvivors
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    /// Selects the row and confirms the table agrees, since a write that reports success without
    /// changing the selection would leave Delete pointed at whatever was selected before.
    private static func selectMarkerRowForDeletion(
        _ index: Int,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let table = AXHelpers.findAllDescendants(
            of: window, role: kAXTableRole as String, maxDepth: 12, runtime: runtime
        ).first else { return false }
        let rows = AXHelpers.findAllDescendants(
            of: table, role: kAXRowRole as String, maxDepth: 4, runtime: runtime
        )
        guard index >= 0, index < rows.count else { return false }
        _ = AXHelpers.setAttribute(
            rows[index], kAXSelectedAttribute as String, kCFBooleanTrue, runtime: runtime
        )
        let selected: [AXUIElement] = AXHelpers.getAttribute(
            table, "AXSelectedRows", runtime: runtime
        ) ?? []
        return selected.count == 1 && CFEqual(selected[0], rows[index])
    }

    /// True when the focused element is the Marker List's table, or lives inside it.
    private static func markerTableHasKeyboardFocus(
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let focused: AXUIElement = AXHelpers.getAttribute(
                  app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax
              ) else { return false }
        var current: AXUIElement? = focused
        var hops = 0
        while let element = current, hops < 6 {
            if (AXHelpers.getRole(element, runtime: runtime.ax) ?? "") == (kAXTableRole as String),
               ancestryMentionsMarker(element, runtime: runtime.ax) {
                return true
            }
            current = AXHelpers.getAttribute(
                element, kAXParentAttribute as String, runtime: runtime.ax
            )
            hops += 1
        }
        return false
    }

    private static func ancestryMentionsMarker(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < 6 {
            let description = AXHelpers.getAttribute(
                node, kAXDescriptionAttribute as String, runtime: runtime
            ) as String? ?? ""
            if AXLocalePolicy.markerContainerKeywords.matches(description, mode: .contains) { return true }
            current = AXHelpers.getAttribute(node, kAXParentAttribute as String, runtime: runtime)
            hops += 1
        }
        return false
    }
}
