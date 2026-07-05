import ApplicationServices
import Foundation


extension AXLogicProElements {
    // MARK: - Markers

    /// Defensive upper bound on AX marker enumeration. Logic projects in the
    /// wild rarely exceed a few dozen markers; this cap keeps the AX traversal
    /// cost predictable even for pathological 10k-marker compositions.
    private static let markerLimit = 512

    /// Enumerate user markers from the project. Strategy order reflects
    /// Logic AX surface drift across major versions:
    ///
    /// **v3.1.9 (Issue #8) — Logic 12.2+ primary**: scrape the dedicated
    /// **Marker List** window's `AXTable`. Logic 12.2 removed user markers
    /// from the main arrange window's AX subtree entirely (the `AXRuler`
    /// strategy that v3.1.8 introduced returns empty on 12.2 because there
    /// are zero `AXRuler` elements in the arrange window). The dedicated
    /// Marker List window — opened via `탐색 → 마커 목록 열기` /
    /// `Navigate → Open Marker List` — exposes markers as
    /// `AXRow → AXCell` rows with name in cell column 2 and position in
    /// cell column 1.
    ///
    /// **v3.1.8 — Logic 11.x fallback**: `AXRuler` structural position
    /// inside the arrange area (the second `AXRuler` is the marker ruler;
    /// the first is the timeline). Preserved for older builds whose marker
    /// ruler is still in the arrange-window subtree.
    ///
    /// **legacy keyword fallback**: scan `AXGroup` descriptions for
    /// `marker` / `마커`. Preserved for very old Logic versions.
    ///
    /// Strategy 1's data quality requires the user to keep the Marker List
    /// window open. Callers that need first-class markers without a
    /// pre-opened window can set `LOGIC_PRO_MCP_AUTO_OPEN_MARKER_LIST=1`
    /// in the environment to trigger a one-time menu click on first
    /// successful project poll (see `defaultGetMarkers` in
    /// `AccessibilityChannel`).
    static func enumerateMarkers(
        in arrangementArea: AXUIElement,
        runtime: Runtime = .production
    ) -> [MarkerState] {
        // Strategy 1 — Logic 12.2+: scrape the Marker List window's AXTable.
        if let listWindow = findMarkerListWindow(runtime: runtime) {
            let listMarkers = enumerateMarkersFromListWindow(listWindow, runtime: runtime.ax)
            if !listMarkers.isEmpty { return listMarkers }
        }

        // Strategy 2 — Logic 11.x: AXRuler-based.
        var rulerElement: AXUIElement? = nil
        let rulers = AXHelpers.findAllDescendants(
            of: arrangementArea, role: "AXRuler", maxDepth: 6, runtime: runtime.ax
        )
        if rulers.count >= 2 {
            rulerElement = rulers[1]
        } else if let only = rulers.first {
            rulerElement = only
        }

        // Strategy 3 — keyword fallback (oldest path).
        if rulerElement == nil {
            // #60: centralized marker-container keyword bag (read-only classifier).
            let markerKeywords = AXLocalePolicy.markerContainerKeywords.labels
            let groups = AXHelpers.findAllDescendants(
                of: arrangementArea, role: kAXGroupRole, maxDepth: 6, runtime: runtime.ax
            )
            for group in groups {
                let id = AXHelpers.getIdentifier(group, runtime: runtime.ax)?.lowercased() ?? ""
                let desc = AXHelpers.getDescription(group, runtime: runtime.ax)?.lowercased() ?? ""
                let title = AXHelpers.getTitle(group, runtime: runtime.ax)?.lowercased() ?? ""
                let combined = "\(id) \(desc) \(title)"
                if markerKeywords.contains(where: { combined.contains($0.lowercased()) }) {
                    rulerElement = group
                    break
                }
            }
        }

        guard let ruler = rulerElement else { return [] }

        let texts = AXHelpers.findAllDescendants(
            of: ruler, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime.ax
        )
        var markers: [MarkerState] = []
        markers.reserveCapacity(min(texts.count, markerLimit))
        for (index, text) in texts.prefix(markerLimit).enumerated() {
            let name = AXHelpers.getTitle(text, runtime: runtime.ax)
                ?? AXHelpers.getDescription(text, runtime: runtime.ax)
                ?? axValueAsName(text, runtime: runtime.ax)
                ?? ""
            guard !name.isEmpty else { continue }
            let parsed = extractMarkerPosition(text, runtime: runtime.ax)
            markers.append(.fromParsed(parsed, ordinal: index, name: name))
        }
        return markers
    }

    /// Locate the open Marker List window (Logic 12.2+ surface). Title
    /// suffix matches:
    ///   - `*- 마커 목록` (Korean localisation)
    ///   - `*- Marker List` (English)
    ///
    /// Returns nil if no such window is open. Window enumeration uses the
    /// `kAXWindowsAttribute` array on the application root; test doubles
    /// that don't implement that attribute correctly fall through to nil.
    /// Matches by suffix because the window title is
    /// `"<project name> - <localized 'Marker List'>"`; the localized suffix
    /// table lives in `AXLocalePolicy.markerListWindowSuffixes` (round-1 #7).
    static func findMarkerListWindow(runtime: Runtime = .production) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        return windows.first { window in
            guard let title = AXHelpers.getTitle(window, runtime: runtime.ax) else {
                return false
            }
            return AXLocalePolicy.markerListWindowSuffixes.contains { title.hasSuffix($0) }
        }
    }

    /// Read `MarkerState[]` from the Marker List window's `AXTable`.
    ///
    /// Observed structure on Logic Pro 12.2 (verified 2026-05-07 against
    /// `무제 15.logicx` with 3 user markers):
    /// ```
    /// AXTable
    ///   AXRow
    ///     AXCell  (Lock column — empty)
    ///     AXCell ─ AXGroup(desc="1 1 1 1 ")  ← position, space-separated B B D T
    ///     AXCell ─ AXCell(desc="마커 1")     ← marker name
    ///     AXCell ─ AXGroup(desc="∞")          ← length, ∞ for trailing marker
    /// ```
    /// We extract name from cell index 2's first child description, position
    /// from cell index 1's first child description (parsed via
    /// `parseMarkerListPosition` to the canonical `"bar.beat.div.tick"` form).
    static func enumerateMarkersFromListWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [MarkerState] {
        let tables = AXHelpers.findAllDescendants(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
        )
        guard let table = tables.first else { return [] }

        let rows: [AXUIElement] = AXHelpers.getAttribute(
            table, "AXRows", runtime: runtime
        ) ?? AXHelpers.getChildren(table, runtime: runtime).filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXRowRole as String)
        }

        var markers: [MarkerState] = []
        markers.reserveCapacity(min(rows.count, markerLimit))
        for (index, row) in rows.prefix(markerLimit).enumerated() {
            let cells = AXHelpers.getChildren(row, runtime: runtime).filter {
                (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXCellRole as String)
            }
            // Need at least 3 cells: [Lock, Position, Name, ...].
            guard cells.count >= 3 else { continue }
            let positionRaw = firstChildDescription(of: cells[1], runtime: runtime) ?? ""
            let nameRaw = firstChildDescription(of: cells[2], runtime: runtime) ?? ""
            let name = nameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let parsed = parseMarkerListPosition(positionRaw)
            markers.append(.fromParsed(parsed, ordinal: index, name: name))
        }
        return markers
    }

    /// First non-empty `AXDescription` in `cell`'s direct children, skipping
    /// the localized placeholder ("셀" / "Cell" / "セル" / etc.) that
    /// `AXCell`s carry by default (table in `AXLocalePolicy.markerCellPlaceholders`,
    /// round-1 #7). Falls through to the cell's own description / value if no
    /// child carries a meaningful one.
    private static func firstChildDescription(
        of cell: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let placeholder = AXLocalePolicy.markerCellPlaceholders
        for child in AXHelpers.getChildren(cell, runtime: runtime) {
            if let desc = AXHelpers.getDescription(child, runtime: runtime),
               !desc.isEmpty,
               !placeholder.contains(desc) {
                return desc
            }
            if let value = AXHelpers.getValue(child, runtime: runtime) as? String,
               !value.isEmpty {
                return value
            }
        }
        if let cellDesc = AXHelpers.getDescription(cell, runtime: runtime),
           !cellDesc.isEmpty,
           !placeholder.contains(cellDesc) {
            return cellDesc
        }
        if let value = AXHelpers.getValue(cell, runtime: runtime) as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }

    /// Logic Marker List 셀의 위치 문자열을 표준 "bar.beat.div.tick" 형태로 변환한다.
    ///
    /// 관찰된 입력 변형:
    /// - 한글 12.2: `"1 1 1 1"` (공백 구분, whole-bar)
    /// - 영문 12.2: `"146 4 4 240."` (공백 구분 + UI 끝 마침표)
    ///
    /// 정확히 4 컴포넌트, 각 ASCII 정수 1 이상이어야 한다. Logic UI는 항상 4
    /// 컴포넌트를 노출하므로 1-3 컴포넌트는 비-position 셀(예: tempo)일 가능성으로
    /// nil 반환한다. 호출자는 `\(index+1).1.1.1` fallback을 사용한다.
    static func parseMarkerListPosition(_ raw: String) -> String? {
        // 끝의 마침표/콤마는 Logic UI rendering artifact — 반복 strip.
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, last == "." || last == "," {
            trimmed.removeLast()
        }
        // 공백/탭만 separator (Logic은 공백만 사용; 점은 끝에서만 의미).
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        // 정확히 4 컴포넌트 + ASCII 0-9만 (부호 prefix·Arabic-Indic 거부) + 1-based.
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  part.allSatisfy { $0.isASCII && $0.isNumber }
                      && (Int(part) ?? 0) >= 1
              }) else {
            return nil
        }
        return parts.joined(separator: ".")
    }

    private static func axValueAsName(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard let v = AXValueExtractors.extractTextValue(element, runtime: runtime),
              !v.isEmpty, !looksLikeBarPosition(v) else { return nil }
        return v
    }

    private static func extractMarkerPosition(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let candidates = [
            AXValueExtractors.extractTextValue(element, runtime: runtime),
            AXHelpers.getHelp(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
        ]
        for candidate in candidates {
            guard let raw = candidate, !raw.isEmpty else { continue }
            if looksLikeBarPosition(raw) { return raw }
        }
        return nil
    }

    private static func looksLikeBarPosition(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 1, parts.count <= 4 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

}
