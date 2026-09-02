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
