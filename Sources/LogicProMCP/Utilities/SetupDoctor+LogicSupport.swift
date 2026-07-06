import Foundation

extension SetupDoctor {
    static func staticVersion(fromStringsOutput output: String) -> StaticVersionResult {
        var versions: [String] = []
        for line in output.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                  let major = Int(parts[0]), major > 0 else {
                continue
            }
            if !versions.contains(value) {
                versions.append(value)
            }
        }
        return versions.count == 1 ? .version(versions[0]) : .indeterminate(versions)
    }


    static func preferredLogicApp(_ apps: [LogicAppInfo]) -> LogicAppInfo? {
        apps.first { $0.path == "/Applications/Logic Pro.app" } ?? apps.first
    }


    static func preferredReadableLogicApp(_ apps: [LogicAppInfo]) -> LogicAppInfo? {
        let readable = apps.filter { $0.readable && $0.version != nil }
        return preferredLogicApp(readable)
    }


    static func productionLogicApps() -> [LogicAppInfo] {
        let homeLogic = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Logic Pro.app").path
        return ["/Applications/Logic Pro.app", homeLogic].compactMap { path -> LogicAppInfo? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let infoURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any] else {
                return LogicAppInfo(path: path, version: nil, bundleID: nil, readable: false)
            }
            return LogicAppInfo(
                path: path,
                version: plist["CFBundleShortVersionString"] as? String,
                bundleID: plist["CFBundleIdentifier"] as? String,
                readable: plist["CFBundleShortVersionString"] as? String != nil
            )
        }
    }


}
