@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// v3.1.9 (Issue #8 — Logic 12.2 marker list AX scrape).
// Logic Pro 12.2 removed user markers from the main arrange window's AX
// subtree; they only appear in the dedicated `*-마커 목록` /
// `*-Marker List` window's `AXTable`. These tests build synthetic AX trees
// that mirror the structure observed via Accessibility Inspector dump on a
// real 12.2 install (see issue #8) and verify that
// `AXLogicProElements.enumerateMarkers` resolves them via the new tier.

/// Builds the tree Logic actually presents, measured on 12.3 (2026-08-17):
///
/// - the table's `AXChildren` carry FOUR `AXColumn` nodes and one `AXGroup` at every row count,
///   so an empty Marker List is a table with children and no rows — not a childless table;
/// - the window carries Logic's own "Number of Items" static text (`"0 Markers"`, `"3 Markers"`),
///   which is the independent witness that tells an empty list apart from a rebuilding one;
/// - the table answers `AXWindow`.
///
/// Before this, the empty fixture gave the table zero children. That shape does not occur in
/// Logic, and building it is what let a reader that refused every empty Marker List pass its
/// own emptiness test — see `AXLogicProElements.markerListStructuralRows`.
///
/// `itemCountText` overrides the witness so a test can present a list whose witness disagrees
/// with its rows; `omitItemCount` removes the witness node entirely.
private func makeMarkerListTree(
    builder: FakeAXRuntimeBuilder,
    appElement: AXUIElement,
    arrangeWindow: AXUIElement,
    markerListWindow: AXUIElement,
    rows: [(position: String, name: String, length: String)],
    itemCountText: String? = nil,
    omitItemCount: Bool = false
) -> AXUIElement {
    // appRoot exposes both windows via kAXWindowsAttribute
    builder.setAttribute(appElement, kAXWindowsAttribute as String, [arrangeWindow, markerListWindow])
    builder.setAttribute(appElement, kAXMainWindowAttribute as String, arrangeWindow)

    builder.setAttribute(arrangeWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrangeWindow, kAXTitleAttribute as String, "TestProject - 트랙")
    builder.setAttribute(arrangeWindow, kAXDocumentAttribute as String, "/TestProject.logicx")

    builder.setAttribute(markerListWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(markerListWindow, kAXTitleAttribute as String, "TestProject - 마커 목록")
    builder.setAttribute(markerListWindow, kAXDocumentAttribute as String, "/TestProject.logicx")

    // Table inside marker list window
    let table = builder.element(8000)
    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(table, kAXWindowAttribute as String, markerListWindow)

    var windowChildren: [AXUIElement] = [table]
    if !omitItemCount {
        let itemCount = builder.element(8900)
        builder.setAttribute(itemCount, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(itemCount, kAXDescriptionAttribute as String, "Number of Items")
        builder.setAttribute(
            itemCount,
            kAXValueAttribute as String,
            itemCountText ?? (rows.count == 1 ? "1 Marker" : "\(rows.count) Markers")
        )
        windowChildren.append(itemCount)
    }
    builder.setChildren(markerListWindow, windowChildren)

    // Build N rows; each row has 4 cells: [Lock, Position, Name, Length]
    var rowElements: [AXUIElement] = []
    var nextID = 8100
    for (rowIdx, row) in rows.enumerated() {
        let rowElem = builder.element(nextID); nextID += 1
        builder.setAttribute(rowElem, kAXRoleAttribute as String, kAXRowRole as String)

        let lockCell = builder.element(nextID); nextID += 1
        let posCell = builder.element(nextID); nextID += 1
        let nameCell = builder.element(nextID); nextID += 1
        let lenCell = builder.element(nextID); nextID += 1
        builder.setAttribute(lockCell, kAXRoleAttribute as String, kAXCellRole as String)
        builder.setAttribute(posCell, kAXRoleAttribute as String, kAXCellRole as String)
        builder.setAttribute(nameCell, kAXRoleAttribute as String, kAXCellRole as String)
        builder.setAttribute(lenCell, kAXRoleAttribute as String, kAXCellRole as String)
        builder.setAttribute(lockCell, kAXDescriptionAttribute as String, "셀")
        builder.setAttribute(posCell, kAXDescriptionAttribute as String, "셀")
        builder.setAttribute(nameCell, kAXDescriptionAttribute as String, "셀")
        builder.setAttribute(lenCell, kAXDescriptionAttribute as String, "셀")

        // Position cell wraps a child group whose AXDescription is the position string
        let posChild = builder.element(nextID); nextID += 1
        builder.setAttribute(posChild, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(posChild, kAXDescriptionAttribute as String, row.position)
        builder.setChildren(posCell, [posChild])

        // Name cell wraps a child cell whose AXDescription is the marker name
        let nameChild = builder.element(nextID); nextID += 1
        builder.setAttribute(nameChild, kAXRoleAttribute as String, kAXCellRole as String)
        builder.setAttribute(nameChild, kAXDescriptionAttribute as String, row.name)
        builder.setChildren(nameCell, [nameChild])

        // Length cell wraps a child group whose AXDescription is the length string
        let lenChild = builder.element(nextID); nextID += 1
        builder.setAttribute(lenChild, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(lenChild, kAXDescriptionAttribute as String, row.length)
        builder.setChildren(lenCell, [lenChild])

        builder.setChildren(rowElem, [lockCell, posCell, nameCell, lenCell])
        rowElements.append(rowElem)
        _ = rowIdx
    }
    builder.setAttribute(table, "AXRows", rowElements)
    // Measured: the four column nodes and the trailing group are children of the table at every
    // row count, so the structural reader always sees a non-empty child list.
    var tableChildren: [AXUIElement] = []
    for column in 0..<4 {
        let columnElement = builder.element(8800 + column)
        builder.setAttribute(columnElement, kAXRoleAttribute as String, kAXColumnRole as String)
        tableChildren.append(columnElement)
    }
    tableChildren.append(contentsOf: rowElements)
    let tableGroup = builder.element(8890)
    builder.setAttribute(tableGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    tableChildren.append(tableGroup)
    builder.setChildren(table, tableChildren)

    return arrangeWindow
}

private final class MarkerListReadProbe: @unchecked Sendable {
    var failedAXRowsReadWasObserved = false
}

@Test
func enumerateMarkers_logic122_markerListWindow_open_returnsMarkers() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7000)
    let arrange = builder.element(7001)
    let listWin = builder.element(7002)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: [
            (position: "1 1 1 1 ", name: "Intro", length: "∞"),
            (position: "5 1 1 1 ", name: "Verse", length: "∞"),
            (position: "9 2 3 4 ", name: "Chorus", length: "∞"),
        ]
    )
    let runtime = builder.makeLogicRuntime(appElement: app)
    let markers = AXLogicProElements.enumerateMarkers(in: arrange, runtime: runtime)
    #expect(markers.count == 3)
    #expect(markers[0].name == "Intro")
    #expect(markers[0].position == "1.1.1.1")
    #expect(markers[0].positionSource == .parser)
    #expect(markers[1].name == "Verse")
    #expect(markers[1].position == "5.1.1.1")
    #expect(markers[1].positionSource == .parser)
    #expect(markers[2].name == "Chorus")
    #expect(markers[2].position == "9.2.3.4")
    #expect(markers[2].positionSource == .parser)
}

@Test
func enumerateMarkers_emptyMarkerListWindow_returnsEmpty() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7100)
    let arrange = builder.element(7101)
    let listWin = builder.element(7102)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: []
    )
    let runtime = builder.makeLogicRuntime(appElement: app)
    let result = AXLogicProElements.enumerateMarkersFromListWindow(listWin, runtime: runtime.ax)

    // This is the shape a project with no markers presents: columns and a group under the table,
    // no rows, and Logic's own witness reading "0 Markers". Measured live 2026-08-17, reading it
    // as unreadable made `create_marker` — the only route to a first marker — permanently State C.
    // Source mutation applied once: turn the successful empty `AXRows` result into a failure.
    // This table genuinely exposes zero rows, so the restored reader must preserve its empty answer.
    if case .success(let markers) = result {
        #expect(markers.isEmpty)
    } else {
        #expect(false, "an exposed table with zero rows must be a readable empty list")
    }
}

@Test
func enumerateMarkers_zeroRowsWithANonZeroWitnessStaysUnreadable() async {
    // A rebuilding table: the rows are gone from the projection while Logic's own count still
    // says three. Publishing `[]` here is what the corroboration guard exists to prevent — it once
    // certified the delete of a marker that was still present. Loosening the guard for the empty
    // list must not reopen that.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7_200)
    let arrange = builder.element(7_201)
    let listWin = builder.element(7_202)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: [], itemCountText: "3 Markers"
    )
    let result = AXLogicProElements.enumerateMarkersFromListWindow(
        listWin, runtime: builder.makeLogicRuntime(appElement: app).ax
    )
    if case .success(let markers) = result {
        #expect(Bool(false), "a witness reporting 3 markers cannot yield an empty list, got \(markers.count)")
    }
}

@Test
func enumerateMarkers_zeroRowsWithNoWitnessStaysUnreadable() async {
    // Absence of the witness is not a zero. Without the independent count there is nothing to
    // tell an empty Marker List apart from a table that has not finished rebuilding.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7_300)
    let arrange = builder.element(7_301)
    let listWin = builder.element(7_302)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: [], omitItemCount: true
    )
    let result = AXLogicProElements.enumerateMarkersFromListWindow(
        listWin, runtime: builder.makeLogicRuntime(appElement: app).ax
    )
    if case .success(let markers) = result {
        #expect(Bool(false), "a missing witness cannot yield an empty list, got \(markers.count)")
    }
}

@Test
func enumerateMarkers_missingTableIsUnavailableRatherThanEmpty() async {
    // Source mutation applied once: restore `.success([])` when markerListTable finds no table.
    // This window has no table, so that mutation fails the unavailable-read assertion.
    let builder = FakeAXRuntimeBuilder()
    let listWin = builder.element(7_150)
    builder.setAttribute(listWin, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setChildren(listWin, [])

    let result = AXLogicProElements.enumerateMarkersFromListWindow(
        listWin, runtime: builder.makeAXRuntime()
    )
    if case .failure(let error) = result {
        #expect(error.raw == AXError.noValue.rawValue)
    } else {
        #expect(false, "a Marker List without its table cannot certify an empty list")
    }
}

@Test
func enumerateMarkers_skipsUnreadableSiblingBeforeRealTable() async {
    // Source mutation applied once: return the non-absence AXChildren failure directly from
    // `markerListTable`. The first sibling then prevents the later real table from being reached,
    // and this successful enumeration fails.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7_160)
    let arrange = builder.element(7_161)
    let listWin = builder.element(7_162)
    _ = makeMarkerListTree(
        builder: builder,
        appElement: app,
        arrangeWindow: arrange,
        markerListWindow: listWin,
        rows: [(position: "5 1 1 1", name: "Reachable", length: "∞")]
    )
    let unreadableSibling = builder.element(7_163)
    let tableGroup = builder.element(7_164)
    let table = builder.element(8_000)
    builder.setAttribute(unreadableSibling, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(tableGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setChildren(listWin, [unreadableSibling, tableGroup])
    builder.setChildren(tableGroup, [table])

    let runtime = builder.makeAXRuntime(
        appElement: app,
        childrenResultHandler: { element in
            if CFEqual(element, unreadableSibling) {
                return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
            }
            return nil
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )
    let result = AXLogicProElements.enumerateMarkersFromListWindow(listWin, runtime: runtime)

    guard case .success(let markers) = result else {
        #expect(false, "an unreadable unrelated sibling must not hide a readable Marker List table")
        return
    }
    #expect(markers.map(\.name) == ["Reachable"])
    #expect(markers.map(\.position) == ["5.1.1.1"])
}

@Test
func enumerateMarkers_childValueSurvivesAbsentDescription() async {
    // Source mutation applied once: return the child AXDescription absence as a failure instead of
    // falling through to AXValue. The position child below then makes enumeration unavailable.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7_170)
    let arrange = builder.element(7_171)
    let listWin = builder.element(7_172)
    _ = makeMarkerListTree(
        builder: builder,
        appElement: app,
        arrangeWindow: arrange,
        markerListWindow: listWin,
        rows: [(position: "unused", name: "AXValue Position", length: "∞")]
    )
    let positionChild = builder.element(8_105)
    builder.setAttribute(positionChild, kAXValueAttribute as String, "5 1 1 1")
    let runtime = builder.makeAXRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            if CFEqual(element, positionChild), attribute == kAXDescriptionAttribute as String {
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            }
            return nil
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )
    let result = AXLogicProElements.enumerateMarkersFromListWindow(listWin, runtime: runtime)

    guard case .success(let markers) = result else {
        #expect(false, "an absent child description must fall through to its AXValue")
        return
    }
    #expect(markers.count == 1)
    #expect(markers[0].name == "AXValue Position")
    #expect(markers[0].position == "5.1.1.1")
}

@Test
func enumerateMarkers_listWindow_closed_fallsThroughToRulerStrategy() async {
    // No marker list window — only arrange window with the legacy AXRuler
    // ruler (Logic 11.x compat). The fallback strategy should still find it.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7200)
    let arrange = builder.element(7201)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange])
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "TestProject - 트랙")

    // Two rulers: timeline + marker. Marker ruler has 2 static texts.
    let timelineRuler = builder.element(7210)
    let markerRuler = builder.element(7211)
    builder.setAttribute(timelineRuler, kAXRoleAttribute as String, "AXRuler")
    builder.setAttribute(markerRuler, kAXRoleAttribute as String, "AXRuler")
    let m1 = builder.element(7220)
    let m2 = builder.element(7221)
    builder.setAttribute(m1, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(m1, kAXTitleAttribute as String, "Section A")
    builder.setAttribute(m2, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(m2, kAXTitleAttribute as String, "Section B")
    builder.setChildren(markerRuler, [m1, m2])

    builder.setChildren(arrange, [timelineRuler, markerRuler])

    let runtime = builder.makeLogicRuntime(appElement: app)
    let markers = AXLogicProElements.enumerateMarkers(in: arrange, runtime: runtime)
    #expect(markers.count == 2)
    #expect(markers[0].name == "Section A")
    #expect(markers[1].name == "Section B")
    // ruler walker 의 fixture 는 position 속성을 노출하지 않음 → caller fallback.
    #expect(markers[0].positionSource == .fallback)
    #expect(markers[1].positionSource == .fallback)
}

// v3.1.11 (Issue #9): parameterized 매트릭스로 통합. 기존 _validInputs / _invalidInputs는
// 단일 커밋으로 strict 4-component 정책 + parameterized 패턴으로 교체.
@Test("parseMarkerListPosition: 유효 입력 → canonical 형태", arguments: [
    ("1 1 1 1", "1.1.1.1"),                     // 한글 12.2 whole-bar
    ("146 4 4 240", "146.4.4.240"),             // 영문 12.2 비-bar-aligned
    ("146 4 4 240.", "146.4.4.240"),            // 영문 UI 끝 마침표 (이번 fix 핵심)
    ("146 4 4 240,", "146.4.4.240"),            // 끝 콤마 방어
    ("  146 4 4 240  ", "146.4.4.240"),         // 양쪽 공백
    ("146  4  4  240", "146.4.4.240"),          // 다중 공백
    ("146\t4\t4\t240", "146.4.4.240"),          // 탭 separator
    ("17 2 3 4", "17.2.3.4"),                   // 정확 4 컴포넌트
])
func parseMarkerListPosition_valid(input: String, expected: String) {
    #expect(AXLogicProElements.parseMarkerListPosition(input) == expected)
}

@Test("parseMarkerListPosition: 무효 입력 → nil", arguments: [
    "", "   ", ".",                              // 빈 / 의미 없음
    "abc", "1 abc", "1 2 3 x",                   // 비숫자 혼합
    "1", "17 2", "1 2 3",                        // NG11 strict 4 — 1-3 components 거부
    "1 2 3 4 5", "1 2 3 4 5 6",                  // 5+ components
    "0 0 0 0", "0 1 1 1", "1 0 1 1",             // NG8 1-based 위반
    "١٤٦ ٤ ٤ ٢٤٠",                              // NG9 ASCII narrow (Arabic-Indic)
    "1.1 1.1", "146.4 4 240",                    // NG7 mixed separator
    "+1 2 3 4", "-1 2 3 4", "1 +2 3 4",          // NG9 부호 prefix (Int 리터럴 우회 차단)
])
func parseMarkerListPosition_invalid(input: String) {
    #expect(AXLogicProElements.parseMarkerListPosition(input) == nil)
}

@Test
func findMarkerListWindow_englishLocale_matches() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7300)
    let arrange = builder.element(7301)
    let listWin = builder.element(7302)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, listWin])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "TestProject - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/TestProject.logicx")
    builder.setAttribute(listWin, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(listWin, kAXTitleAttribute as String, "TestProject - Marker List")
    builder.setAttribute(listWin, kAXDocumentAttribute as String, "/TestProject.logicx")
    let runtime = builder.makeLogicRuntime(appElement: app)
    let win = AXLogicProElements.findMarkerListWindow(runtime: runtime)
    #expect(win == listWin)
}

@Test
func findMarkerListWindow_scopesToActiveProject() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7_320)
    let activeArrange = builder.element(7_321)
    let foreignList = builder.element(7_322)
    let activeList = builder.element(7_323)
    builder.setAttribute(app, kAXMainWindowAttribute as String, activeArrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [foreignList, activeArrange, activeList])
    builder.setAttribute(activeArrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(activeArrange, kAXTitleAttribute as String, "ActiveProject - Tracks")
    builder.setAttribute(activeArrange, kAXDocumentAttribute as String, "/ActiveProject.logicx")
    builder.setAttribute(foreignList, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(foreignList, kAXTitleAttribute as String, "OtherProject - Marker List")
    builder.setAttribute(foreignList, kAXDocumentAttribute as String, "/OtherProject.logicx")
    builder.setAttribute(activeList, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(activeList, kAXTitleAttribute as String, "ActiveProject - Marker List")
    builder.setAttribute(activeList, kAXDocumentAttribute as String, "/ActiveProject.logicx")

    let runtime = builder.makeLogicRuntime(appElement: app)
    let window = AXLogicProElements.findMarkerListWindow(runtime: runtime)

    #expect(window == activeList)
}

@Test
func findMarkerListWindow_notOpen_returnsNil() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7400)
    let arrange = builder.element(7401)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "TestProject - 트랙")
    let runtime = builder.makeLogicRuntime(appElement: app)
    let win = AXLogicProElements.findMarkerListWindow(runtime: runtime)
    #expect(win == nil)
}

@Test
func enumerateMarkers_listAndRulerBothPresent_listWins() async {
    // When both surfaces exist (mid-version transition), prefer the marker
    // list window as authoritative — it's the post-12.2 location.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7500)
    let arrange = builder.element(7501)
    let listWin = builder.element(7502)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: [(position: "1 1 1 1 ", name: "FromList", length: "∞")]
    )
    // Add a stale AXRuler in the arrange window with a DIFFERENT marker name
    let timelineRuler = builder.element(7510)
    let markerRuler = builder.element(7511)
    builder.setAttribute(timelineRuler, kAXRoleAttribute as String, "AXRuler")
    builder.setAttribute(markerRuler, kAXRoleAttribute as String, "AXRuler")
    let staleText = builder.element(7520)
    builder.setAttribute(staleText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(staleText, kAXTitleAttribute as String, "FromRuler")
    builder.setChildren(markerRuler, [staleText])
    builder.setChildren(arrange, [timelineRuler, markerRuler])

    let runtime = builder.makeLogicRuntime(appElement: app)
    let markers = AXLogicProElements.enumerateMarkers(in: arrange, runtime: runtime)
    #expect(markers.count == 1)
    #expect(markers[0].name == "FromList", "list strategy must take precedence")
    #expect(markers[0].positionSource == .parser, "list 경로 parser 성공 source 보존")
}

@Test
func enumerateMarkers_openEmptyMarkerListDoesNotFallThroughToStaleRuler() async {
    // A successfully read empty Marker List is an answer. It must not be replaced with an old
    // ruler label merely because this convenience API returns an array rather than Result.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7_530)
    let arrange = builder.element(7_531)
    let listWin = builder.element(7_532)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: []
    )
    let timelineRuler = builder.element(7_533)
    let markerRuler = builder.element(7_534)
    let staleText = builder.element(7_535)
    builder.setAttribute(timelineRuler, kAXRoleAttribute as String, "AXRuler")
    builder.setAttribute(markerRuler, kAXRoleAttribute as String, "AXRuler")
    builder.setAttribute(staleText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(staleText, kAXTitleAttribute as String, "Stale ruler marker")
    builder.setChildren(markerRuler, [staleText])
    builder.setChildren(arrange, [timelineRuler, markerRuler])

    let runtime = builder.makeLogicRuntime(appElement: app)
    guard case .success(let listMarkers) = AXLogicProElements.enumerateMarkersFromListWindow(
        listWin, runtime: runtime.ax
    ) else {
        #expect(false, "the empty Marker List fixture must be a successful read")
        return
    }
    #expect(listMarkers.isEmpty)
    #expect(AXLogicProElements.enumerateMarkers(in: arrange, runtime: runtime).isEmpty)
}

@Test
func enumerateMarkers_failedOpenMarkerListDoesNotFallThroughToStaleRuler() async {
    // A failed Marker-List read is not a successful empty read, but neither result may be
    // laundered into the stale ruler answer that feeds the independent position_multiset check.
    let builder = FakeAXRuntimeBuilder()
    let probe = MarkerListReadProbe()
    let app = builder.element(7_540)
    let arrange = builder.element(7_541)
    let listWin = builder.element(7_542)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: [(position: "1 1 1 1", name: "Live list marker", length: "∞")]
    )
    let table = builder.element(8_000)
    let timelineRuler = builder.element(7_543)
    let markerRuler = builder.element(7_544)
    let staleText = builder.element(7_545)
    builder.setAttribute(timelineRuler, kAXRoleAttribute as String, "AXRuler")
    builder.setAttribute(markerRuler, kAXRoleAttribute as String, "AXRuler")
    builder.setAttribute(staleText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(staleText, kAXTitleAttribute as String, "Stale ruler marker")
    builder.setChildren(markerRuler, [staleText])
    builder.setChildren(arrange, [timelineRuler, markerRuler])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            if CFEqual(element, table), attribute == "AXRows" {
                probe.failedAXRowsReadWasObserved = true
                return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
            }
            return nil
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )
    let listResult = AXLogicProElements.enumerateMarkersFromListWindow(listWin, runtime: runtime.ax)
    guard case .failure(let error) = listResult else {
        #expect(false, "the failed Marker List seam must remain distinct from a successful empty read")
        return
    }
    #expect(error.raw == AXError.failure.rawValue)
    #expect(probe.failedAXRowsReadWasObserved)

    probe.failedAXRowsReadWasObserved = false
    #expect(AXLogicProElements.enumerateMarkers(in: arrange, runtime: runtime).isEmpty)
    #expect(probe.failedAXRowsReadWasObserved)
}

// MARK: - StateCache.updateMarkers fetchedAt invariant (v3.1.9 Issue #8 cache bug)

@Test
func enumerateMarkers_malformedRowMakesEnumerationUnavailable() async {
    // A present row with fewer than 3 cells has not been read completely. It must not be silently
    // skipped while valid rows are surfaced, because a destructive caller could mistake that
    // partial list for a complete survivor set.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7600)
    let arrange = builder.element(7601)
    let listWin = builder.element(7602)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, listWin])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "TestProject - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/TestProject.logicx")
    builder.setAttribute(listWin, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(listWin, kAXTitleAttribute as String, "TestProject - 마커 목록")
    builder.setAttribute(listWin, kAXDocumentAttribute as String, "/TestProject.logicx")

    let table = builder.element(7610)
    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setChildren(listWin, [table])

    // Build: row[0] valid (4 cells), row[1] malformed (2 cells), row[2] valid (4 cells)
    let validRow1 = builder.element(7620)
    let malformedRow = builder.element(7621)
    let validRow2 = builder.element(7622)
    for r in [validRow1, malformedRow, validRow2] {
        builder.setAttribute(r, kAXRoleAttribute as String, kAXRowRole as String)
    }
    func cell(_ id: Int, child: AXUIElement?) -> AXUIElement {
        let c = builder.element(id)
        builder.setAttribute(c, kAXRoleAttribute as String, kAXCellRole as String)
        if let child = child { builder.setChildren(c, [child]) }
        return c
    }
    func leaf(_ id: Int, role: String, desc: String) -> AXUIElement {
        let e = builder.element(id)
        builder.setAttribute(e, kAXRoleAttribute as String, role)
        builder.setAttribute(e, kAXDescriptionAttribute as String, desc)
        return e
    }
    let v1Cells = [
        cell(7700, child: nil),
        cell(7701, child: leaf(7702, role: kAXGroupRole as String, desc: "1 1 1 1 ")),
        cell(7703, child: leaf(7704, role: kAXCellRole as String, desc: "ValidA")),
        cell(7705, child: leaf(7706, role: kAXGroupRole as String, desc: "∞")),
    ]
    let mfCells = [cell(7710, child: nil), cell(7711, child: nil)] // only 2 cells
    let v2Cells = [
        cell(7720, child: nil),
        cell(7721, child: leaf(7722, role: kAXGroupRole as String, desc: "9 1 1 1 ")),
        cell(7723, child: leaf(7724, role: kAXCellRole as String, desc: "ValidB")),
        cell(7725, child: leaf(7726, role: kAXGroupRole as String, desc: "∞")),
    ]
    builder.setChildren(validRow1, v1Cells)
    builder.setChildren(malformedRow, mfCells)
    builder.setChildren(validRow2, v2Cells)
    let rows = [validRow1, malformedRow, validRow2]
    builder.setAttribute(table, "AXRows", rows)
    builder.setChildren(table, rows)

    let runtime = builder.makeLogicRuntime(appElement: app)
    let result = AXLogicProElements.enumerateMarkersFromListWindow(listWin, runtime: runtime.ax)

    // Source mutation applied once: replace the incomplete-row failure with `continue`. That
    // returns two valid-looking rows and fails this explicit unavailable-read assertion.
    if case .failure(let error) = result {
        #expect(error.raw == AXError.noValue.rawValue)
    } else {
        #expect(false, "a present unreadable row must make enumeration unavailable")
    }
}

@Test
func enumerateMarkers_unparseablePosition_usesIndexFallback() async {
    // When the position cell carries a non-numeric description,
    // `parseMarkerListPosition` returns nil and the caller substitutes
    // the index-based fallback "\(index+1).1.1.1". The marker name still
    // surfaces — this isn't a row rejection.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7800)
    let arrange = builder.element(7801)
    let listWin = builder.element(7802)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: [(position: "abc", name: "BadPos", length: "∞")]
    )
    let runtime = builder.makeLogicRuntime(appElement: app)
    let markers = AXLogicProElements.enumerateMarkers(in: arrange, runtime: runtime)
    #expect(markers.count == 1)
    #expect(markers[0].name == "BadPos", "name still captured even when position unparseable")
    #expect(markers[0].position == "1.1.1.1", "fallback position is index+1.1.1.1")
    #expect(markers[0].positionSource == .fallback, "parser 실패 → caller fallback provenance")
}

// v3.1.11 (Issue #9): 영문 12.2 비-bar-aligned 마커 + UI 끝 마침표 통합 회귀.
// raw "146 4 4 240." → parser → MarkerState.position == "146.4.4.240" 검증.
@Test
func enumerateMarkers_trailingDotPosition_canonicalizes() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7900)
    let arrange = builder.element(7901)
    let listWin = builder.element(7902)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: [(position: "146 4 4 240.", name: "VOCALS", length: "∞")]
    )
    let runtime = builder.makeLogicRuntime(appElement: app)
    let markers = AXLogicProElements.enumerateMarkers(in: arrange, runtime: runtime)
    #expect(markers.count == 1)
    #expect(markers[0].name == "VOCALS")
    #expect(markers[0].position == "146.4.4.240", "영문 UI 끝 마침표 strip 후 canonical")
    #expect(markers[0].positionSource == .parser, "trailing-dot strip 후 parser 성공")
}

// v3.1.11 (Issue #9 / Tester P0): 한글 12.2 whole-bar 통합 회귀 — G3 영문/한글
// 양쪽 정확성 명시 보장.
@Test
func enumerateMarkers_koreanWholeBarPosition_canonicalizes() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7910)
    let arrange = builder.element(7911)
    let listWin = builder.element(7912)
    _ = makeMarkerListTree(
        builder: builder, appElement: app,
        arrangeWindow: arrange, markerListWindow: listWin,
        rows: [(position: "1 1 1 1", name: "Section A", length: "∞")]
    )
    let runtime = builder.makeLogicRuntime(appElement: app)
    let markers = AXLogicProElements.enumerateMarkers(in: arrange, runtime: runtime)
    #expect(markers.count == 1)
    #expect(markers[0].name == "Section A")
    #expect(markers[0].position == "1.1.1.1")
    #expect(markers[0].positionSource == .parser, "한글 whole-bar parser 성공")
}

@Test
func updateMarkers_emptyToEmpty_advancesFetchedAt() async {
    let cache = StateCache()
    let beforeFetched = await cache.getMarkersFetchedAt()
    #expect(beforeFetched == .distantPast, "fresh cache must start at .distantPast")

    // Two consecutive empty updates (the v3.1.9 honest-empty case).
    await cache.updateMarkers([])
    let afterFirst = await cache.getMarkersFetchedAt()
    #expect(afterFirst > .distantPast, "first empty update must advance fetchedAt")

    // Sleep briefly so the second timestamp is detectably newer.
    try? await Task.sleep(nanoseconds: 10_000_000)

    await cache.updateMarkers([])
    let afterSecond = await cache.getMarkersFetchedAt()
    #expect(
        afterSecond > afterFirst,
        "second empty update must ALSO advance fetchedAt (pre-v3.1.9 short-circuited and left it stale)"
    )
}

@Test
func updateMarkers_sameNonEmpty_advancesFetchedAt() async {
    let cache = StateCache()
    let m1 = MarkerState(id: 0, name: "Intro", position: "1.1.1.1")
    await cache.updateMarkers([m1])
    let after1 = await cache.getMarkersFetchedAt()
    try? await Task.sleep(nanoseconds: 10_000_000)
    await cache.updateMarkers([m1])
    let after2 = await cache.getMarkersFetchedAt()
    #expect(after2 > after1, "fetchedAt must advance for any successful poll, not just diffs")
}
