import AppKit
import Foundation

/// Canonical Logic Pro variant metadata loaded from manifest.json.
struct LogicProVariantRecord: Sendable, Equatable, Decodable {
    let name: String
    let bundleID: String
    let processName: String
    let defaultInstallPath: String

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case processName = "process_name"
        case defaultInstallPath = "default_install_path"
    }
}

enum LogicProVariantPolicy {
    static let manifestEnvironmentKey = "LOGIC_PRO_MCP_MANIFEST_PATH"

    private struct ManifestRoot: Decodable {
        let supportedLogicProVariants: [LogicProVariantRecord]

        enum CodingKeys: String, CodingKey {
            case supportedLogicProVariants = "supported_logic_pro_variants"
        }
    }

    static let records: [LogicProVariantRecord] = loadRecords()

    static var knownBundleIDs: [String] {
        records.map(\.bundleID)
    }

    static var knownProcessNames: [String] {
        records.map(\.processName)
    }

    static var macOSExecutablePathMarkers: [String] {
        records.map { record in
            URL(fileURLWithPath: record.defaultInstallPath)
                .appendingPathComponent("Contents/MacOS/")
                .path
        }
    }

    static func record(named name: String) -> LogicProVariantRecord? {
        records.first { $0.name == name }
    }

    static func record(forBundleID bundleID: String) -> LogicProVariantRecord? {
        records.first { $0.bundleID == bundleID }
    }

    static func processName(forBundleID bundleID: String?) -> String {
        guard let bundleID else {
            return records.first?.processName ?? "Logic Pro"
        }
        return record(forBundleID: bundleID)?.processName ?? bundleID
    }

    static func resolveBundleID(
        forcedBundleID: String?,
        frontmostBundleID: String?,
        isRunning: (String) -> Bool,
        isInstalled: (String) -> Bool
    ) -> String {
        if let forced = forcedBundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !forced.isEmpty {
            return forced
        }
        if let frontmostBundleID, knownBundleIDs.contains(frontmostBundleID) {
            return frontmostBundleID
        }
        for bundleID in knownBundleIDs where isRunning(bundleID) {
            return bundleID
        }
        for bundleID in knownBundleIDs where isInstalled(bundleID) {
            return bundleID
        }
        return knownBundleIDs.first ?? emergencyFallback()[0].bundleID
    }

    private static func loadRecords() -> [LogicProVariantRecord] {
        if let records = loadManifestRecords() {
            return records
        }
        fputs(
            "LogicProVariantPolicy: manifest.json unavailable; using embedded emergency fallback\n",
            stderr
        )
        return emergencyFallback()
    }

    private static func loadManifestRecords() -> [LogicProVariantRecord]? {
        guard let url = findRepoFile(relativePath: "manifest.json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(ManifestRoot.self, from: data),
              !root.supportedLogicProVariants.isEmpty else {
            return nil
        }
        return root.supportedLogicProVariants
    }

    static func findRepoFile(relativePath: String) -> URL? {
        if let configured = ProcessInfo.processInfo.environment[manifestEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let configuredURL = URL(fileURLWithPath: configured)
            if relativePath == "manifest.json" {
                return FileManager.default.fileExists(atPath: configuredURL.path) ? configuredURL : nil
            }
            let sibling = configuredURL.deletingLastPathComponent().appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling
            }
        }

        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }

        if let root = repoRootFromSource() {
            let sourceRelative = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: sourceRelative.path) {
                return sourceRelative
            }
        }
        return nil
    }

    /// The repository root, found by walking up from this file until a directory holds
    /// `Package.swift`.
    ///
    /// This used to be three `deletingLastPathComponent()` calls, which landed on `<repo>/Sources`
    /// and probed `<repo>/Sources/manifest.json` — a path that does not exist, so the fallback
    /// could never fire (#776). Counting directory levels is what made that possible AND silent:
    /// the count was right when it was written and wrong the moment the file's depth changed, with
    /// nothing to notice. Walking to a MARKER states what is being looked for, so moving this file
    /// cannot quietly break it again.
    static func repoRootFromSource() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }
        return nil
    }

    private static func emergencyFallback() -> [LogicProVariantRecord] {
        [
            LogicProVariantRecord(
                name: "desktop",
                bundleID: "com.apple.logic10",
                processName: "Logic Pro",
                defaultInstallPath: "/Applications/Logic Pro.app"
            ),
            LogicProVariantRecord(
                name: "creator_studio",
                bundleID: "com.apple.mobilelogic",
                processName: "Logic Pro Creator Studio",
                defaultInstallPath: "/Applications/Logic Pro Creator Studio.app"
            ),
        ]
    }
}

/// Supported Logic Pro product variants (desktop purchase vs Creator Studio subscription).
/// Metadata is loaded at runtime from manifest.json.
enum LogicProVariant: String, Sendable {
    case desktop = "desktop"
    case creatorStudio = "creator_studio"
    case unknown = "unknown"

    static let knownVariants: [LogicProVariant] = LogicProVariantPolicy.records.compactMap {
        LogicProVariant(rawValue: $0.name)
    }

    private var record: LogicProVariantRecord? {
        guard self != .unknown else { return nil }
        return LogicProVariantPolicy.record(named: rawValue)
    }

    var bundleID: String {
        record?.bundleID ?? ""
    }

    var processName: String {
        record?.processName ?? ""
    }

    var defaultInstallPath: String {
        record?.defaultInstallPath ?? ""
    }

    static func from(bundleID: String) -> LogicProVariant? {
        guard let record = LogicProVariantPolicy.record(forBundleID: bundleID) else { return nil }
        return LogicProVariant(rawValue: record.name)
    }
}

/// Pre-escaped AppleScript fragments for the resolved Logic Pro target.
struct LogicProAppleScriptTarget: Sendable, Equatable {
    let tellApplicationByBundleID: String
    let activateByBundleID: String
    let quitByBundleID: String
    /// System Events target, e.g. `process "Logic Pro"`.
    let systemEventsProcessTarget: String
}

/// Resolved Logic Pro target for process detection, AppleScript, and install probes.
struct LogicProTarget: Sendable, Equatable {
    let variant: LogicProVariant
    let bundleID: String
    let processName: String
    /// False when `LOGIC_PRO_BUNDLE_ID` points at an unknown/uninstalled app — process metadata is not trustworthy.
    let processMetadataResolved: Bool

    static let knownVariants: [LogicProVariant] = LogicProVariant.knownVariants

    static let desktop = LogicProTarget(variant: .desktop)
    static let creatorStudio = LogicProTarget(variant: .creatorStudio)

    init(variant: LogicProVariant) {
        self.variant = variant
        self.bundleID = variant.bundleID
        self.processName = variant.processName
        self.processMetadataResolved = true
    }

    init(bundleID: String, processName: String, processMetadataResolved: Bool) {
        if processMetadataResolved {
            self.variant = LogicProVariant.from(bundleID: bundleID) ?? .unknown
        } else {
            self.variant = .unknown
        }
        self.bundleID = bundleID
        self.processName = processName
        self.processMetadataResolved = processMetadataResolved
    }

    static func target(for variant: LogicProVariant) -> LogicProTarget {
        LogicProTarget(variant: variant)
    }

    static func target(forBundleID bundleID: String) -> LogicProTarget? {
        guard let variant = LogicProVariant.from(bundleID: bundleID) else { return nil }
        return target(for: variant)
    }

    /// All known bundle IDs in preference order (desktop before Creator Studio; matches manifest.json).
    static var knownBundleIDs: [String] {
        LogicProVariantPolicy.knownBundleIDs
    }

    static var knownProcessNames: [String] {
        LogicProVariantPolicy.knownProcessNames
    }

    /// Environment variable name for forcing a specific Logic Pro variant.
    static let bundleIDEnvironmentKey = "LOGIC_PRO_BUNDLE_ID"

    struct Runtime: Sendable {
        let forcedBundleID: @Sendable () -> String?
        let frontmostBundleID: @Sendable () -> String?
        let runningApplications: @Sendable (String) -> [NSRunningApplication]
        let installedApplicationURL: @Sendable (String) -> URL?

        static let production = Runtime(
            forcedBundleID: {
                let value = ProcessInfo.processInfo.environment[bundleIDEnvironmentKey]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value, !value.isEmpty else { return nil }
                return value
            },
            frontmostBundleID: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            },
            runningApplications: { bundleID in
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            },
            installedApplicationURL: { bundleID in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            }
        )
    }

    private struct TimedTargetCache {
        let value: LogicProTarget
        let expiresAt: Date
    }

    private static let targetCacheTTL: TimeInterval = 0.5
    private static let targetCacheLock = NSLock()
    nonisolated(unsafe) private static var targetCache: TimedTargetCache?

    /// Currently resolved Logic Pro target (cached briefly).
    static var current: LogicProTarget {
        resolved(runtime: .production)
    }

    static func resolved(runtime: Runtime = .production) -> LogicProTarget {
        let now = Date()
        targetCacheLock.lock()
        if let cached = targetCache, cached.expiresAt > now {
            let value = cached.value
            targetCacheLock.unlock()
            return value
        }
        targetCacheLock.unlock()

        let target = resolveUncached(runtime: runtime)
        targetCacheLock.lock()
        targetCache = TimedTargetCache(value: target, expiresAt: now.addingTimeInterval(targetCacheTTL))
        targetCacheLock.unlock()
        return target
    }

    static func invalidateCache() {
        targetCacheLock.lock()
        targetCache = nil
        targetCacheLock.unlock()
    }

    static func resolveUncached(runtime: Runtime = .production) -> LogicProTarget {
        let resolvedBundleID = LogicProVariantPolicy.resolveBundleID(
            forcedBundleID: runtime.forcedBundleID(),
            frontmostBundleID: runtime.frontmostBundleID(),
            isRunning: { !runtime.runningApplications($0).isEmpty },
            isInstalled: { runtime.installedApplicationURL($0) != nil }
        )

        if let forced = runtime.forcedBundleID() {
            if let target = target(forBundleID: forced) {
                return target
            }
            if let fromBundle = targetFromInstalledBundle(bundleID: forced, runtime: runtime) {
                return fromBundle
            }
            return LogicProTarget(
                bundleID: forced,
                processName: forced,
                processMetadataResolved: false
            )
        }

        if let variant = LogicProVariant.from(bundleID: resolvedBundleID) {
            let running = runningTargets(runtime: runtime)
            if !running.isEmpty {
                if let frontmostID = runtime.frontmostBundleID(),
                   let frontmost = running.first(where: { $0.bundleID == frontmostID }) {
                    return frontmost
                }
                if let match = running.first(where: { $0.bundleID == resolvedBundleID }) {
                    return match
                }
                return running[0]
            }
            return target(for: variant)
        }

        return .desktop
    }

    static func runningTargets(runtime: Runtime = .production) -> [LogicProTarget] {
        knownVariants.compactMap { variant in
            let bundleID = variant.bundleID
            guard !runtime.runningApplications(bundleID).isEmpty else { return nil }
            return target(for: variant)
        }
    }

    static func runningApplication(runtime: Runtime = .production) -> NSRunningApplication? {
        if let forced = runtime.forcedBundleID() {
            return runtime.runningApplications(forced).first
        }
        let running = runningTargets(runtime: runtime)
        if let frontmostID = runtime.frontmostBundleID(),
           let match = running.first(where: { $0.bundleID == frontmostID }),
           let app = runtime.runningApplications(match.bundleID).first {
            return app
        }
        for variant in knownVariants {
            if let app = runtime.runningApplications(variant.bundleID).first {
                return app
            }
        }
        return runtime.runningApplications(current.bundleID).first
    }

    static func installedBundleURL(runtime: Runtime = .production) -> URL? {
        let target = resolved(runtime: runtime)
        return runningApplication(runtime: runtime)?.bundleURL
            ?? runtime.installedApplicationURL(target.bundleID)
    }

    static func installedApplicationPath(runtime: Runtime = .production) -> String? {
        installedBundleURL(runtime: runtime)?.path
    }

    /// Best-effort installed Logic Pro.app path for factory content probes.
    static func preferredInstalledApplicationPath(runtime: Runtime = .production) -> String {
        if let path = installedApplicationPath(runtime: runtime) {
            return path
        }
        for variant in knownVariants {
            if let url = runtime.installedApplicationURL(variant.bundleID) {
                return url.path
            }
            if FileManager.default.fileExists(atPath: variant.defaultInstallPath) {
                return variant.defaultInstallPath
            }
        }
        return LogicProVariant.desktop.defaultInstallPath
    }

    static func isKnownBundleID(_ bundleID: String) -> Bool {
        LogicProVariant.from(bundleID: bundleID) != nil
    }

    static func isLogicFrontmostBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return isKnownBundleID(bundleID)
    }

    /// Whether a process/window-owner name is one of Logic's, compared with its internal spacing
    /// normalised.
    ///
    /// Measured on macOS 15 with Logic Pro 12.3, 2026-08-17, by switching
    /// `defaults write com.apple.logic10 AppleLanguages` and restarting:
    /// `CGWindowListCopyWindowInfo`'s `kCGWindowOwnerName` answers `"Logic Pro"` with an ordinary
    /// space in English and Japanese, and with a **NO-BREAK SPACE (U+00A0)** in Korean. An exact
    /// compare against the manifest's `"Logic Pro"` therefore matched nothing on a Korean-UI Mac,
    /// and `ProcessUtils.logicProPID(fromWindowList:)` silently found no Logic window at all — a
    /// discriminator contributing nothing, for a reason having nothing to do with Logic.
    ///
    /// The normalisation is deliberately narrow: whitespace characters collapse to `U+0020`, so any
    /// separator macOS localises to (U+00A0 here, U+202F elsewhere) still matches, while `LogicPro`
    /// with the separator REMOVED does not. Fixing it here rather than adding a second literal to
    /// the manifest keeps one locale's rendering from becoming a second product name.
    static func isLogicProcessName(_ name: String) -> Bool {
        let normalized = normalizedProcessName(name)
        return knownProcessNames.contains { normalizedProcessName($0) == normalized }
    }

    static func normalizedProcessName(_ name: String) -> String {
        String(name.map { $0.isWhitespace ? " " : $0 })
    }

    /// Health/diagnostic label for the resolved variant.
    var variantLabel: String {
        guard processMetadataResolved else { return "unknown_forced" }
        return variant.rawValue
    }

    func appleScriptTarget() -> LogicProAppleScriptTarget {
        let escapedLogicProBundleID = AppleScriptSafety.escapeForScript(bundleID)
        let tellApplicationByBundleID = "tell application id \"\(escapedLogicProBundleID)\""
        let escapedLogicProProcessName = AppleScriptSafety.escapeForScript(processName)
        return LogicProAppleScriptTarget(
            tellApplicationByBundleID: tellApplicationByBundleID,
            activateByBundleID: "\(tellApplicationByBundleID) to activate",
            quitByBundleID: "\(tellApplicationByBundleID) to quit",
            systemEventsProcessTarget: "process \"\(escapedLogicProProcessName)\""
        )
    }

    static func appleScriptTarget(runtime: Runtime = .production) -> LogicProAppleScriptTarget {
        resolved(runtime: runtime).appleScriptTarget()
    }

    private static func targetFromInstalledBundle(
        bundleID: String,
        runtime: Runtime
    ) -> LogicProTarget? {
        guard let url = runtime.installedApplicationURL(bundleID),
              let bundle = Bundle(url: url) else {
            return nil
        }
        let processName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundleID
        return LogicProTarget(bundleID: bundleID, processName: processName, processMetadataResolved: true)
    }
}
