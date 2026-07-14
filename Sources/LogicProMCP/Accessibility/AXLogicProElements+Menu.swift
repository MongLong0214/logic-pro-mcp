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
