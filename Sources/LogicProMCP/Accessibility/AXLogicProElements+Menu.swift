import ApplicationServices
import Foundation


extension AXLogicProElements {
    // MARK: - Menu Bar

    private static let englishTopLevelMenuTitles: Set<String> = ["File", "Edit", "Track"]
    private static let koreanTopLevelMenuTitles: Set<String> = ["파일", "편집", "트랙"]

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

}
