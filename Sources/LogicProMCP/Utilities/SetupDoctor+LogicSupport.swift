import AppKit
import Foundation

extension SetupDoctor {
    static func staticVersion(fromStringsOutput output: String) -> StaticVersionResult {
        let markerPrefix = "LOGIC_PRO_MCP_VERSION="
        let markerVersions = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.hasPrefix(markerPrefix) else { return nil }
                let version = String(value.dropFirst(markerPrefix.count))
                return Self.SemanticVersion(version)?.normalizedCore
            }
        if let marker = markerVersions.first {
            return .version(marker)
        }

        var versions: [String] = []
        for line in output.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version = Self.SemanticVersion(value), version.major > 0 else {
                continue
            }
            if !versions.contains(version.normalizedCore) {
                versions.append(version.normalizedCore)
            }
        }
        return versions.count == 1 ? .version(versions[0]) : .indeterminate(versions)
    }


    /// The app this server will drive, or nil when none of the shipped variants is installed.
    ///
    /// The last two fallbacks used to be `creatorStudio` and then ANY app. `shipVariants` is
    /// `[.desktop]` and the ADR records Creator Studio as permanently out of scope — so returning
    /// it here made the runtime select a variant the release matrix does not cover, and the
    /// catch-all could return something that is not Logic at all. Recognising a bundle id is not
    /// claiming support for it, which is the same correction the README needed.
    ///
    /// Callers must distinguish "nothing shipped is installed" from "a bundle would not read":
    /// `unshippedVariantOnly` answers that, so the doctor does not report an out-of-scope install
    /// as an unreadable one.
    static func preferredLogicApp(_ apps: [LogicAppInfo]) -> LogicAppInfo? {
        apps.first {
            $0.path == LogicProVariant.desktop.defaultInstallPath
                && $0.bundleID == LogicProVariant.desktop.bundleID
        }
            ?? apps.first { $0.bundleID == LogicProVariant.desktop.bundleID }
            ?? apps.first { $0.path == LogicProVariant.desktop.defaultInstallPath }
    }

    /// Whether the only Logic present is one this release does not ship for. Distinguishes an
    /// out-of-scope install from an unreadable bundle, which otherwise report identically.
    static func unshippedVariantOnly(_ apps: [LogicAppInfo]) -> Bool {
        preferredLogicApp(apps) == nil
            && apps.contains { $0.bundleID == LogicProVariant.creatorStudio.bundleID }
    }


    static func preferredReadableLogicApp(_ apps: [LogicAppInfo]) -> LogicAppInfo? {
        let readable = supportedLogicApps(apps).filter { $0.readable && $0.version != nil }
        return preferredLogicApp(readable)
    }


    static func supportedLogicApps(_ apps: [LogicAppInfo]) -> [LogicAppInfo] {
        apps.filter { app in
            guard let bundleID = app.bundleID else { return app.readable }
            return LogicProTarget.isKnownBundleID(bundleID)
        }
    }


    static func logicVariantLabel(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return LogicProVariant.from(bundleID: bundleID)?.rawValue
    }


    static func productionLogicAppCandidatePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return LogicProVariant.knownVariants.flatMap { variant in
            [
                variant.defaultInstallPath,
                "\(home)/Applications/\(URL(fileURLWithPath: variant.defaultInstallPath).lastPathComponent)",
            ]
        }
    }


    static func productionLogicApps() -> [LogicAppInfo] {
        var byPath: [String: LogicAppInfo] = [:]

        for path in productionLogicAppCandidatePaths() {
            if let info = logicAppInfo(at: path) {
                byPath[path] = info
            }
        }

        for variant in LogicProTarget.knownVariants {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: variant.bundleID) else {
                continue
            }
            let path = url.path
            if byPath[path] == nil, let info = logicAppInfo(at: path) {
                byPath[path] = info
            }
        }

        return byPath.values.sorted { $0.path < $1.path }
    }


    static func logicAppInfo(at path: String) -> LogicAppInfo? {
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
