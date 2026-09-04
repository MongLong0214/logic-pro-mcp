@preconcurrency import ApplicationServices
import Foundation


extension AXLogicProElements {
    // MARK: - Menu Bar

    private static let englishTopLevelMenuTitles: Set<String> = ["File", "Edit", "Track"]
    private static let koreanTopLevelMenuTitles: Set<String> = ["파일", "편집", "트랙"]

    /// The legacy menu helpers intentionally flatten AX failure to `nil` for
    /// best-effort callers. A mutation verifier needs the stronger distinction:
    /// -25205/-25212 say a menu node is absent; every other status means that
    /// node was not read and must refuse before an action is sent.
    enum MenuItemRead: Error {
        case found(AXUIElement)
        case absent
        case unreadable(stage: String, status: String)
    }

    enum LogicUILocaleRead {
        case locale(String)
        case absent
        case unreadable(stage: String, status: String)
    }

    /// Get the menu bar for Logic Pro.
    static func getMenuBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute, runtime: runtime.ax)
    }

    static func logicUILocaleIdentifier(runtime: Runtime = .production) -> String? {
        guard let menuBar = getMenuBar(runtime: runtime) else { return nil }
        let titles = AXHelpers.getChildren(menuBar, runtime: runtime.ax).compactMap {
            AXHelpers.getTitle($0, runtime: runtime.ax)
        }
        return logicUILocaleIdentifier(menuTitles: titles)
    }

    /// Status-preserving locale read for mutation verification. It is separate
    /// from `logicUILocaleIdentifier` so historic read-only callers retain their
    /// best-effort behavior.
    static func logicUILocaleIdentifierRead(runtime: Runtime = .production) -> LogicUILocaleRead {
        switch verifiedMenuBarRead(runtime: runtime) {
        case .absent:
            return .absent
        case .unreadable(let stage, let status):
            return .unreadable(stage: stage, status: status)
        case .found(let menuBar):
            switch verifiedMenuChildrenRead(menuBar, stage: "AXMenuBar.AXChildren", runtime: runtime.ax) {
            case .failure(let result):
                switch result {
                case .absent:
                    return .absent
                case .unreadable(let stage, let status):
                    return .unreadable(stage: stage, status: status)
                case .found:
                    preconditionFailure("A children read cannot find a menu item")
                }
            case .success(let children):
                var titles: [String] = []
                for child in children {
                    switch verifiedMenuTitleRead(child, stage: "AXMenuBarItem.AXTitle", runtime: runtime.ax) {
                    case .success(let title):
                        if let title { titles.append(title) }
                    case .failure(let result):
                        switch result {
                        case .absent:
                            continue
                        case .unreadable(let stage, let status):
                            return .unreadable(stage: stage, status: status)
                        case .found:
                            preconditionFailure("A title read cannot find a menu item")
                        }
                    }
                }
                guard let locale = logicUILocaleIdentifier(menuTitles: titles) else { return .absent }
                return .locale(locale)
            }
        }
    }

    static func logicUILocaleIdentifier(menuTitles: [String]) -> String? {
        let observed = Set(menuTitles)
        let englishMatch = englishTopLevelMenuTitles.isSubset(of: observed)
        let koreanMatch = koreanTopLevelMenuTitles.isSubset(of: observed)
        guard englishMatch != koreanMatch else { return nil }
        return englishMatch ? QualificationLocale.enUS.rawValue : QualificationLocale.koKR.rawValue
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    /// Locale-resolved menu lookup (#519): each step matches ANY measured label for that item.
    ///
    /// The literal-string overload below is fine when the caller already knows the exact title, and
    /// wrong the moment Logic is running in another language. `save_as` used to work around that by
    /// trying a Korean literal and then an English one, which covers exactly two of the languages
    /// Logic ships and fails silently in the rest — the shape #519 is about.
    static func menuItem(
        labelPath: [AXLocalePolicy.LabelSet],
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard var current = getMenuBar(runtime: runtime) else { return nil }
        for labels in labelPath {
            var found = false
            for child in AXHelpers.getChildren(current, runtime: runtime.ax) {
                if labels.matches(AXHelpers.getTitle(child, runtime: runtime.ax)) {
                    current = child
                    found = true
                    break
                }
                for sub in AXHelpers.getChildren(child, runtime: runtime.ax)
                where labels.matches(AXHelpers.getTitle(sub, runtime: runtime.ax)) {
                    current = sub
                    found = true
                    break
                }
                if found { break }
            }
            guard found else { return nil }
        }
        return current
    }

    /// Locate a menu item under one menu-bar menu by its locale-free `AXIdentifier`.
    ///
    /// Measured on Logic 12.3 (ko-KR) 2026-09-04, walking the whole `편집` menu: 151 items, and
    /// `AXIdentifier` is NOT a general escape from localized titles. The menu-BAR items publish no
    /// identifier at all (12 of 12 `<none>`), and inside the Select submenu ten of seventeen items
    /// share the single value `localMenuItemAction:` — an identifier that names the dispatcher, not
    /// the item. Only the items Logic wires to a distinct selector carry a distinct value
    /// (`selectAll:`, `deselectAll:`, `invertSelection:`), and for those the value is unique: a scan
    /// of all 151 items found `deselectAll:` exactly once.
    ///
    /// So this addresses the leaf by identifier and still takes the containing menu by label,
    /// because the menu bar leaves no other way to name it. A shared identifier resolves to NOTHING
    /// rather than to whichever item traversal order reached first: the scan collects every match in
    /// the bounded region and answers only when there is exactly one. That turns "the caller assumed
    /// wrong about this build" into a refusal instead of into an action on an item nobody chose.
    ///
    /// "Every match in the bounded region" is only true if the region was fully READ, so the scan
    /// uses status-preserving reads and refuses when one fails. The best-effort helpers return an
    /// empty child array on failure, which would let an unreadable subtree hide the second match and
    /// hand back the uniqueness the caller asked to have checked.
    static func menuItem(
        identifier: String,
        inMenuBar menuBar: AXLocalePolicy.LabelSet,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard let bar = getMenuBar(runtime: runtime) else { return nil }
        guard let menu = AXHelpers.getChildren(bar, runtime: runtime.ax).first(where: {
            menuBar.matches(AXHelpers.getTitle($0, runtime: runtime.ax))
        }) else { return nil }

        // Four levels below the menu-bar item, because the AXMenu containers take a level each:
        // menu-bar item -> AXMenu -> item -> AXMenu -> item. `deselectAll:` sits at the last of
        // those (편집 > 선택 > 전체 선택 해제). A first cut stopped at three and never reached it,
        // and the operation's pre-state gate is what caught that rather than a wrong answer. The
        // bound stays tight so a mis-typed identifier cannot walk the whole tree.
        //
        // The whole bounded region is scanned before answering, rather than returning the first
        // match. Returning early would make a SHARED identifier resolve to whichever item traversal
        // order reached first — silently, and differently on another build — and a shared identifier
        // is the common case here, not the exotic one: ten of the seventeen items in this very
        // submenu publish `localMenuItemAction:`. Two matches is not a near miss to be broken by
        // ordering; it means the caller's assumption about this identifier is wrong on this host,
        // and the only safe answer is none.
        // Status-preserving reads throughout, because "exactly one match" is a claim about the whole
        // region and the best-effort helpers cannot make it. `AXHelpers.getChildren` turns a failed
        // read into an EMPTY array, so an unreadable subtree would hide a duplicate and the scan
        // would report the uniqueness it was asked to verify. A read that fails is not an absence;
        // it is the scan being unable to answer, and the answer then has to be none.
        var matches: [AXUIElement] = []
        guard case .success(var frontier) = AXHelpers.childrenResult(menu, runtime: runtime.ax) else {
            return nil
        }
        let maxDepth = 4
        for depth in 0..<maxDepth {
            var next: [AXUIElement] = []
            for element in frontier {
                let identifierRead: Result<String?, AXHelpers.AXStatusError> =
                    AXHelpers.getAttributeResult(
                        element, kAXIdentifierAttribute as String, runtime: runtime.ax
                    )
                // A menu item, not merely something carrying the identifier. Menus, groups and
                // whatever else Logic hangs here are not pressable as items.
                let roleRead: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                    element, kAXRoleAttribute as String, runtime: runtime.ax
                )
                // Either read can EXCLUDE this element on its own, and an exclusion makes the other
                // read irrelevant — so a failure only matters when it is still load-bearing. The
                // first cut demanded both reads succeed, which meant an element conclusively
                // excluded by its identifier (`localMenuItemAction:`, which most of Logic's items
                // carry) still aborted the whole lookup if its role happened to be unreadable. That
                // is a refusal the uniqueness claim does not need: an excluded element cannot be
                // the duplicate the scan is looking for.
                let identifierExcludes = (try? identifierRead.get()).map { $0 != identifier } ?? false
                let roleExcludes = (try? roleRead.get()).map { $0 != (kAXMenuItemRole as String) } ?? false
                if identifierExcludes || roleExcludes {
                    // Not this item, decided by a read that succeeded.
                } else {
                    switch (identifierRead, roleRead) {
                    case (.success(let identifierValue), .success(let role)):
                        if identifierValue == identifier, role == (kAXMenuItemRole as String) {
                            matches.append(element)
                        }
                    case (.failure(let error), _) where error.isDefinitiveAbsence:
                        break       // no identifier at all: not this item, and a real answer
                    case (_, .failure(let error)) where error.isDefinitiveAbsence:
                        break       // no role at all: cannot be a menu item, and a real answer
                    default:
                        return nil  // still load-bearing, and unreadable
                    }
                }

                // Children only matter while there is another level to scan. Reading them on the
                // last iteration cannot find a duplicate — nothing will look at them — so failing
                // there would refuse a healthy unique leaf to protect a claim that is already made.
                guard depth + 1 < maxDepth else { continue }
                switch AXHelpers.childrenResult(element, runtime: runtime.ax) {
                case .success(let kids):
                    next.append(contentsOf: kids)
                case .failure(let error) where error.isDefinitiveAbsence:
                    continue
                case .failure:
                    return nil      // a subtree that could have held a duplicate
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    /// Status-preserving counterpart to the locale-resolved `menuItem` lookup.
    /// It is intentionally additive: ordinary callers retain the old
    /// best-effort result, while a mutation verifier can distinguish a missing
    /// leaf from the AX failure that prevented it from being examined.
    static func menuItemRead(
        labelPath: [AXLocalePolicy.LabelSet],
        runtime: Runtime = .production
    ) -> MenuItemRead {
        switch verifiedMenuBarRead(runtime: runtime) {
        case .absent:
            return .absent
        case .unreadable(let stage, let status):
            return .unreadable(stage: stage, status: status)
        case .found(var current):
            for labels in labelPath {
                switch verifiedMenuChildrenRead(current, stage: "AXChildren", runtime: runtime.ax) {
                case .failure(let read):
                    return read
                case .success(let children):
                    var next: AXUIElement?
                    for child in children {
                        switch verifiedMenuTitleRead(child, stage: "AXTitle", runtime: runtime.ax) {
                        case .failure(let read):
                            if case .absent = read {
                                break
                            }
                            return read
                        case .success(let title):
                            if labels.matches(title) {
                                next = child
                                break
                            }
                        }
                        if next != nil { break }

                        switch verifiedMenuChildrenRead(child, stage: "AXChildren", runtime: runtime.ax) {
                        case .failure(let read):
                            if case .absent = read {
                                continue
                            }
                            return read
                        case .success(let descendants):
                            for descendant in descendants {
                                switch verifiedMenuTitleRead(descendant, stage: "AXTitle", runtime: runtime.ax) {
                                case .failure(let read):
                                    if case .absent = read {
                                        continue
                                    }
                                    return read
                                case .success(let title):
                                    if labels.matches(title) {
                                        next = descendant
                                        break
                                    }
                                }
                            }
                        }
                        if next != nil { break }
                    }
                    guard let next else { return .absent }
                    current = next
                }
            }
            return .found(current)
        }
    }

    static func menuItem(path: [String], runtime: Runtime = .production) -> AXUIElement? {
        guard var current = getMenuBar(runtime: runtime) else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current, runtime: runtime.ax)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child, runtime: runtime.ax) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child, runtime: runtime.ax)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub, runtime: runtime.ax) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
    }

    private static func verifiedMenuBarRead(runtime: Runtime) -> MenuItemRead {
        guard let app = appRoot(runtime: runtime) else {
            return .unreadable(stage: "app_root", status: "unavailable")
        }
        switch AXHelpers.getAttributeResult(
            app, kAXMenuBarAttribute as String, runtime: runtime.ax
        ) as Result<AXUIElement?, AXHelpers.AXStatusError> {
        case .success(.some(let menuBar)):
            return .found(menuBar)
        case .success(.none):
            return .absent
        case .failure(let error) where error.isDefinitiveAbsence:
            return .absent
        case .failure(let error):
            return .unreadable(stage: "AXMenuBar", status: error.diagnosticLabel)
        }
    }

    private static func verifiedMenuChildrenRead(
        _ element: AXUIElement,
        stage: String,
        runtime: AXHelpers.Runtime
    ) -> Result<[AXUIElement], MenuItemRead> {
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case .success(let children):
            return .success(children)
        case .failure(let error) where error.isDefinitiveAbsence:
            return .failure(.absent)
        case .failure(let error):
            return .failure(.unreadable(stage: stage, status: error.diagnosticLabel))
        }
    }

    private static func verifiedMenuTitleRead(
        _ element: AXUIElement,
        stage: String,
        runtime: AXHelpers.Runtime
    ) -> Result<String?, MenuItemRead> {
        switch AXHelpers.getAttributeResult(
            element, kAXTitleAttribute as String, runtime: runtime
        ) as Result<String?, AXHelpers.AXStatusError> {
        case .success(let title):
            return .success(title)
        case .failure(let error) where error.isDefinitiveAbsence:
            return .failure(.absent)
        case .failure(let error):
            return .failure(.unreadable(stage: stage, status: error.diagnosticLabel))
        }
    }

}
