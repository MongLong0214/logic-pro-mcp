import Foundation

/// v3.1.8 (Issue #7) — read project metadata from `.logicx/Alternatives/000/
/// MetaData.plist`. Logic Pro 12.x's AppleScript scripting dictionary no longer
/// exposes `tracks` / `markers` / `tempo` / `time signature`; the v3.1.5
/// AppleScript-primary helpers therefore return -2753 on every call. The
/// project-file fallback covers project-info reliably and supplies a track
/// **count** for placeholder rows when the AX walker is occluded by a
/// non-arrange panel.
///
/// Path validation is hardened per PRD §6.3:
///   1. resolvingSymlinksInPath on the bundle root
///   2. reject paths whose components contain `..`
///   3. require `.logicx` extension and that it is a directory
///   4. resolve the leaf (`Alternatives/000/MetaData.plist`) symlinks
///   5. require the leaf to sit under the resolved bundle root
///   6. cap read at 10MB
///   7. mtime-jitter retry: detect concurrent Logic-save mid-read
///
/// All public APIs are `@Sendable` so `Runtime.production` can be wired into
/// `ResourceHandlers` without actor isolation.
struct LogicProjectMetadata: Sendable, Equatable {
    let bundlePath: URL
    let tempo: Double?
    let signatureNumerator: Int?
    let signatureDenominator: Int?
    let trackCount: Int?
    let lastSavedFrom: String?
    let metadataMTime: Date

    var timeSignatureString: String? {
        guard let n = signatureNumerator, let d = signatureDenominator else { return nil }
        return "\(n)/\(d)"
    }

    /// Clamp at 0 for future-dated mtime (clock skew / restored backups).
    func lastSavedAgeSec(now: Date) -> Double {
        max(0, now.timeIntervalSince(metadataMTime))
    }
}

enum LogicProjectFileReader {
    /// Maximum plist size (defensive — typical Logic MetaData.plist is < 1MB).
    static let maxPlistBytes = 10 * 1024 * 1024

    /// Backoff between mtime-jitter retries.
    static let jitterRetryNanos: UInt64 = 50_000_000

    struct Runtime: Sendable {
        let currentDocumentPath: @Sendable () async -> String?
        let now: @Sendable () -> Date
        let readPlistData: @Sendable (URL) -> Data?
        let mtime: @Sendable (URL) -> Date?
        let sleep: @Sendable (UInt64) async -> Void

        static let production: Runtime = .init(
            currentDocumentPath: { await AppleScriptChannel.currentDocumentPath() },
            now: Date.init,
            readPlistData: { url in FileManager.default.contents(atPath: url.path) },
            mtime: { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            },
            sleep: { nanos in try? await Task.sleep(nanoseconds: nanos) }
        )

        /// A deliberately inert dependency for headless cache tests.  The
        /// poller opts into `.production` explicitly; ordinary injected poller
        /// runtimes must not spawn an AppleScript read merely because a test
        /// refreshed its synthetic AX cache.
        static let unavailable: Runtime = .init(
            currentDocumentPath: { nil },
            now: Date.init,
            readPlistData: { _ in nil },
            mtime: { _ in nil },
            sleep: { _ in }
        )
    }

    /// Top-level entry: query the current Logic document path via AppleScript,
    /// validate the bundle, and read its `MetaData.plist`. Returns nil for
    /// every failure mode (no document, path validation fail, parse error,
    /// persistent mtime jitter).
    static func read(runtime: Runtime = .production) async -> LogicProjectMetadata? {
        guard let pathString = await runtime.currentDocumentPath(),
              !pathString.isEmpty else {
            return nil
        }
        return await readPath(pathString, runtime: runtime)
    }

    /// Validate + read a specific bundle path (test entry-point).
    static func readPath(_ pathString: String, runtime: Runtime = .production) async -> LogicProjectMetadata? {
        guard let leaf = validatePath(pathString) else { return nil }
        return await readWithMtimeRetry(leafURL: leaf.leaf, bundlePath: leaf.bundle, runtime: runtime, attempt: 0)
    }

    // MARK: - Path validation

    struct ValidatedPath {
        let bundle: URL
        let leaf: URL
    }

    /// PRD §6.3: realpath bundle, reject `..` and non-`.logicx`, require leaf
    /// to live under the resolved bundle.
    static func validatePath(_ pathString: String) -> ValidatedPath? {
        // Pre-normalisation: reject `..` in the raw path components. This
        // catches `/foo/../Legit.logicx` even before symlink resolution
        // (defensive depth — `URL.resolvingSymlinksInPath` should normalise
        // these out, but we don't trust it for security).
        let raw = URL(fileURLWithPath: pathString)
        if raw.pathComponents.contains("..") { return nil }

        let bundle = raw.resolvingSymlinksInPath()
        if bundle.pathComponents.contains("..") { return nil }
        guard bundle.pathExtension.lowercased() == "logicx" else { return nil }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }

        let leaf = bundle
            .appendingPathComponent("Alternatives", isDirectory: true)
            .appendingPathComponent("000", isDirectory: true)
            .appendingPathComponent("MetaData.plist")
            .resolvingSymlinksInPath()
        if leaf.pathComponents.contains("..") { return nil }

        // Leaf must sit strictly under the resolved bundle. Anti symlink-escape:
        // if the leaf was a symlink to /tmp/evil/whatever, resolvingSymlinksInPath
        // followed it; the resulting path will not start with the bundle root.
        let bundleWithSlash = bundle.path.hasSuffix("/") ? bundle.path : bundle.path + "/"
        guard leaf.path.hasPrefix(bundleWithSlash) else { return nil }

        return ValidatedPath(bundle: bundle, leaf: leaf)
    }

    // MARK: - mtime jitter retry

    private static func readWithMtimeRetry(
        leafURL: URL,
        bundlePath: URL,
        runtime: Runtime,
        attempt: Int
    ) async -> LogicProjectMetadata? {
        guard let mtime1 = runtime.mtime(leafURL),
              let data = runtime.readPlistData(leafURL) else {
            return nil
        }
        guard data.count <= maxPlistBytes,
              let parsed = parseData(data) else {
            return nil
        }
        guard let mtime2 = runtime.mtime(leafURL) else { return nil }

        if mtime1 == mtime2 {
            return LogicProjectMetadata(
                bundlePath: bundlePath,
                tempo: parsed.tempo,
                signatureNumerator: parsed.numerator,
                signatureDenominator: parsed.denominator,
                trackCount: parsed.trackCount,
                lastSavedFrom: parsed.lastSavedFrom,
                metadataMTime: mtime1
            )
        }

        if attempt == 0 {
            await runtime.sleep(jitterRetryNanos)
            return await readWithMtimeRetry(
                leafURL: leafURL, bundlePath: bundlePath, runtime: runtime, attempt: 1
            )
        }
        return nil
    }

    // MARK: - Plist parsing

    private struct ParsedFields {
        var tempo: Double?
        var numerator: Int?
        var denominator: Int?
        var trackCount: Int?
        var lastSavedFrom: String?
    }

    private static func parseData(_ data: Data) -> ParsedFields? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            return nil
        }
        var fields = ParsedFields()

        // `tempo.isFinite` rejects NaN/±Inf so a non-finite BeatsPerMinute never
        // enters the cache/report. A non-finite Double would make JSONEncoder
        // throw downstream, which would otherwise surface as a silent encode
        // fallback rather than honest data.
        if let tempo = (plist["BeatsPerMinute"] as? NSNumber)?.doubleValue, tempo > 0, tempo.isFinite {
            fields.tempo = tempo
        }
        if let n = (plist["SongSignatureNumerator"] as? NSNumber)?.intValue,
           let d = (plist["SongSignatureDenominator"] as? NSNumber)?.intValue,
           n > 0, d > 0 {
            fields.numerator = n
            fields.denominator = d
        }
        if let tc = (plist["NumberOfTracks"] as? NSNumber)?.intValue, tc >= 0 {
            fields.trackCount = tc
        }
        fields.lastSavedFrom = plist["LastSavedFrom"] as? String

        return fields
    }
}
