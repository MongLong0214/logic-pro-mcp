@preconcurrency import ApplicationServices
import Foundation

/// A qualification-only Library read that is independent of the product's
/// `LibraryAccessor.enumerate` path and its cached resource projection.
enum QualificationLibraryPanelReader {
    struct Snapshot: Codable, Equatable, Sendable {
        let categories: [String]
        let presetsByCategory: [String: [String]]
        let currentCategory: String?
        let currentPreset: String?
    }

    private struct Unavailable: Encodable {
        let available = false
        let reason = "explicit_library_panel_unavailable"
    }

    private struct PositionedText {
        let value: String
        let position: CGPoint
        let traversalIndex: Int
    }

    private struct Column {
        let x: CGFloat
        let traversalIndex: Int
        let values: [String]
    }

    static func read(
        runtime: AXLogicProElements.Runtime = .production
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let snapshot = snapshot(runtime: runtime) else {
            return try encoder.encode(Unavailable())
        }
        return try encoder.encode(snapshot)
    }

    static func snapshot(
        runtime: AXLogicProElements.Runtime = .production
    ) -> Snapshot? {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { return nil }
        let browser = AXLocalePolicy.censusDescendant(
            of: window,
            role: kAXBrowserRole,
            matching: AXLocalePolicy.libraryPanelLabel,
            mode: .exactStrict,
            maxDepth: 10,
            runtime: runtime.ax
        ).element
        guard let browser else { return nil }

        let texts = AXHelpers.censusDescendant(
            of: browser,
            role: kAXStaticTextRole,
            maxDepth: 6,
            runtime: runtime.ax
        ).matches
        let positioned = texts.enumerated().compactMap { index, text in
            positionedText(text, traversalIndex: index, runtime: runtime.ax)
        }
        var buckets: [(x: CGFloat, traversalIndex: Int, items: [PositionedText])] = []
        for item in positioned.sorted(by: {
            if $0.position.x != $1.position.x { return $0.position.x < $1.position.x }
            return $0.traversalIndex < $1.traversalIndex
        }) {
            if let index = buckets.firstIndex(where: { abs($0.x - item.position.x) < 30 }) {
                buckets[index].items.append(item)
            } else {
                buckets.append((item.position.x, item.traversalIndex, [item]))
            }
        }
        let columns = buckets.map { bucket in
            let items = bucket.items.sorted { lhs, rhs in
                if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
                if lhs.position.x != rhs.position.x { return lhs.position.x < rhs.position.x }
                return lhs.traversalIndex < rhs.traversalIndex
            }
            return Column(
                x: bucket.x,
                traversalIndex: bucket.traversalIndex,
                values: items.map(\.value)
            )
        }.sorted { lhs, rhs in
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.traversalIndex < rhs.traversalIndex
        }

        guard let categoryColumn = columns.first else {
            return Snapshot(
                categories: [],
                presetsByCategory: [:],
                currentCategory: nil,
                currentPreset: nil
            )
        }
        guard columns.count >= 2 else {
            return Snapshot(
                categories: categoryColumn.values,
                presetsByCategory: [:],
                currentCategory: nil,
                currentPreset: nil
            )
        }

        let selections = selectedTexts(in: browser, runtime: runtime.ax)
        let indexedSelections = selections.compactMap { selection -> (Int, PositionedText)? in
            guard let index = columns.indices.min(by: {
                abs(columns[$0].x - selection.position.x)
                    < abs(columns[$1].x - selection.position.x)
            }), abs(columns[index].x - selection.position.x) < 30 else { return nil }
            return (index, selection)
        }
        guard let currentCategory = indexedSelections.first(where: { $0.0 == 0 })?.1.value else {
            return Snapshot(
                categories: categoryColumn.values,
                presetsByCategory: [:],
                currentCategory: nil,
                currentPreset: nil
            )
        }
        let currentPreset = indexedSelections
            .filter { $0.0 > 0 }
            .max(by: { lhs, rhs in lhs.0 < rhs.0 })?
            .1.value
        return Snapshot(
            categories: categoryColumn.values,
            presetsByCategory: [currentCategory: columns[1].values],
            currentCategory: currentCategory,
            currentPreset: currentPreset
        )
    }

    private static func positionedText(
        _ element: AXUIElement,
        traversalIndex: Int,
        runtime: AXHelpers.Runtime
    ) -> PositionedText? {
        guard let raw: String = AXHelpers.getAttribute(
            element,
            kAXValueAttribute,
            runtime: runtime
        ) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let origin = AXHelpers.getPosition(element, runtime: runtime),
              let size = AXHelpers.getSize(element, runtime: runtime) else {
            return nil
        }
        return PositionedText(
            value: value,
            position: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2),
            traversalIndex: traversalIndex
        )
    }

    private static func selectedTexts(
        in browser: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [PositionedText] {
        // The product inventory also discovers columns without requiring AXList,
        // but it only assigns selected ownership from AXList.SelectedChildren.
        // Keep those semantics aligned while acquiring the census independently.
        let roles: [String] = [kAXListRole as String]
        let containers = roles.reduce(into: [AXUIElement]()) { result, role in
            result.append(contentsOf: AXHelpers.findAllDescendants(
                of: browser,
                role: role,
                maxDepth: 6,
                runtime: runtime
            ))
        }
        var result: [PositionedText] = []
        var traversalIndex = 0
        for container in containers {
            guard let selected: [AXUIElement] = AXHelpers.getAttribute(
                container,
                kAXSelectedChildrenAttribute,
                runtime: runtime
            ) else { continue }
            for child in selected {
                if let direct = positionedText(
                    child,
                    traversalIndex: traversalIndex,
                    runtime: runtime
                ) {
                    result.append(direct)
                    traversalIndex += 1
                    continue
                }
                let texts = AXHelpers.findAllDescendants(
                    of: child,
                    role: kAXStaticTextRole,
                    maxDepth: 6,
                    runtime: runtime
                )
                for text in texts {
                    if let nested = positionedText(
                        text,
                        traversalIndex: traversalIndex,
                        runtime: runtime
                    ) {
                        result.append(nested)
                        traversalIndex += 1
                    }
                }
            }
        }
        return result
    }
}
