import Foundation

/// Structured stderr logger. MCP servers must not write to stdout (reserved for JSON-RPC).
///
/// Features:
/// - Level gating (`LOG_LEVEL` env + runtime `setLevel`)
/// - Output format: plain text (default) or one-line JSON (`LOG_FORMAT=json`)
/// - Typed `Subsystem` enum with string back-compat for existing callsites
/// - Rate limiting: identical (level + subsystem + message) bursts are collapsed
///   so high-frequency callers (e.g. StatePoller error paths) can't flood stderr
/// - `output` sink is injectable for testability
enum Log {
    enum Level: String, Sendable, Comparable, CaseIterable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"

        fileprivate var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    /// Canonical subsystem identifiers used across the codebase.
    /// Existing `subsystem: String` callsites remain supported for back-compat.
    enum Subsystem: String, Sendable, CaseIterable {
        case main
        case server
        case router
        case poller
        case midi
        case mcu
        case scripter
        case ax
        case appleScript
        case cgEvent
        case keycmd
        case project
        case library
        case validation
    }

    enum Format: String, Sendable {
        case text
        case json
    }

    // MARK: - Configuration (mutable, lock-guarded)

    private static let configLock = NSLock()

    private nonisolated(unsafe) static var _output: @Sendable (String) -> Void = { msg in
        FileHandle.standardError.write(Data(msg.utf8))
    }

    /// Testable output sink. Default writes to stderr.
    static var output: @Sendable (String) -> Void {
        get { configLock.lock(); defer { configLock.unlock() }; return _output }
        set { configLock.lock(); defer { configLock.unlock() }; _output = newValue }
    }

    private nonisolated(unsafe) static var _minLevel: Level = {
        switch ProcessInfo.processInfo.environment["LOG_LEVEL"]?.lowercased() {
        case "debug": return .debug
        case "warn": return .warn
        case "error": return .error
        default: return .info
        }
    }()

    /// Minimum level that will be emitted. Honor-based — use `setLevel` to change.
    static var minLevel: Level {
        configLock.lock(); defer { configLock.unlock() }
        return _minLevel
    }

    /// Mutate the minimum log level at runtime (e.g. from an MCP tool).
    static func setLevel(_ level: Level) {
        configLock.lock(); defer { configLock.unlock() }
        _minLevel = level
    }

    private nonisolated(unsafe) static var _format: Format = {
        ProcessInfo.processInfo.environment["LOG_FORMAT"]?.lowercased() == "json" ? .json : .text
    }()

    /// Output format selector. Default follows `LOG_FORMAT` env.
    static var format: Format {
        configLock.lock(); defer { configLock.unlock() }
        return _format
    }

    // MARK: - Timestamp (thread-safe ISO8601)

    private nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dateFormatterLock = NSLock()

    private static func timestamp(_ date: Date = Date()) -> String {
        dateFormatterLock.lock(); defer { dateFormatterLock.unlock() }
        return dateFormatter.string(from: date)
    }

    // MARK: - Rate limiter

    /// Max identical messages per window before suppression kicks in.
    static let rateLimitThreshold: Int = 10
    /// Rate limit window in seconds. Identical messages emitted within this
    /// window beyond `rateLimitThreshold` are collapsed into a summary.
    static let rateLimitWindow: TimeInterval = 1.0
    /// Hard cap on tracked keys. When exceeded, expired windows are swept;
    /// if still above cap, the oldest entries are evicted. Prevents a
    /// long-running daemon from accumulating one entry per unique
    /// user-supplied log string (e.g. interpolated filenames, MIDI port names).
    static let rateLimitMaxEntries: Int = 1024

    private struct RateEntry {
        var count: Int
        var windowStart: Date
        var suppressed: Int
    }
    private nonisolated(unsafe) static var rateMap: [String: RateEntry] = [:]
    private static let rateMapLock = NSLock()

    /// Decide whether this log line should emit, and whether to flush a
    /// "Suppressed N identical messages" summary from a previous window.
    private static func rateCheck(key: String, now: Date = Date()) -> (emit: Bool, flushSuppressed: Int) {
        rateMapLock.lock(); defer { rateMapLock.unlock() }

        if var entry = rateMap[key] {
            if now.timeIntervalSince(entry.windowStart) > rateLimitWindow {
                let flush = entry.suppressed
                rateMap[key] = RateEntry(count: 1, windowStart: now, suppressed: 0)
                enforceRateMapCap(now: now)
                return (true, flush)
            }
            entry.count += 1
            if entry.count > rateLimitThreshold {
                entry.suppressed += 1
                rateMap[key] = entry
                return (false, 0)
            }
            rateMap[key] = entry
            return (true, 0)
        }
        rateMap[key] = RateEntry(count: 1, windowStart: now, suppressed: 0)
        enforceRateMapCap(now: now)
        return (true, 0)
    }

    /// Caller must hold `rateMapLock`. First sweeps entries whose windows are
    /// older than `rateLimitWindow`; if still above the cap, evicts the
    /// oldest remaining entries until we're at cap.
    private static func enforceRateMapCap(now: Date) {
        guard rateMap.count > rateLimitMaxEntries else { return }
        // Pass 1: sweep expired windows (always safe — fresh calls re-seed them).
        rateMap = rateMap.filter { _, entry in
            now.timeIntervalSince(entry.windowStart) <= rateLimitWindow
        }
        // Pass 2: still over cap → evict oldest by windowStart.
        if rateMap.count > rateLimitMaxEntries {
            let sorted = rateMap.sorted { $0.value.windowStart < $1.value.windowStart }
            let excess = rateMap.count - rateLimitMaxEntries
            for (key, _) in sorted.prefix(excess) {
                rateMap.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Core log API

    static func log(
        _ level: Level,
        _ message: String,
        subsystem: String = "main",
        file: String = #file,
        line: Int = #line
    ) {
        guard level >= minLevel else { return }

        let filename = (file as NSString).lastPathComponent
        let rateKey = "\(level.rawValue)|\(subsystem)|\(message)"
        let (emit, flushSuppressed) = rateCheck(key: rateKey)

        if flushSuppressed > 0 {
            emitLine(
                level: level,
                message: "Suppressed \(flushSuppressed) identical messages",
                subsystem: subsystem,
                filename: filename,
                line: line
            )
        }
        guard emit else { return }
        emitLine(level: level, message: message, subsystem: subsystem, filename: filename, line: line)
    }

    static func log(
        _ level: Level,
        _ message: String,
        subsystem: Subsystem,
        file: String = #file,
        line: Int = #line
    ) {
        log(level, message, subsystem: subsystem.rawValue, file: file, line: line)
    }

    private static func emitLine(
        level: Level,
        message: String,
        subsystem: String,
        filename: String,
        line: Int
    ) {
        let ts = timestamp()
        let entry: String
        switch format {
        case .json:
            entry = jsonLine(
                ts: ts, level: level, message: message,
                subsystem: subsystem, filename: filename, line: line
            )
        case .text:
            entry = "[\(ts)] [\(level.rawValue)] [\(subsystem)] \(message) (\(filename):\(line))\n"
        }
        output(entry)
    }

    private static func jsonLine(
        ts: String,
        level: Level,
        message: String,
        subsystem: String,
        filename: String,
        line: Int
    ) -> String {
        func esc(_ s: String) -> String {
            var out = ""
            out.reserveCapacity(s.count + 2)
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case let c where c.value < 0x20:
                    out += String(format: "\\u%04x", c.value)
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
            return out
        }
        // Hand-rolled emitter — avoids JSONEncoder allocation on the hot path.
        return "{\"ts\":\"\(ts)\",\"level\":\"\(level.rawValue)\",\"subsystem\":\"\(esc(subsystem))\",\"message\":\"\(esc(message))\",\"file\":\"\(esc(filename))\",\"line\":\(line)}\n"
    }

    // MARK: - String-subsystem convenience (back-compat, 60+ callsites)

    static func debug(_ msg: String, subsystem: String = "main", file: String = #file, line: Int = #line) {
        log(.debug, msg, subsystem: subsystem, file: file, line: line)
    }
    static func info(_ msg: String, subsystem: String = "main", file: String = #file, line: Int = #line) {
        log(.info, msg, subsystem: subsystem, file: file, line: line)
    }
    static func warn(_ msg: String, subsystem: String = "main", file: String = #file, line: Int = #line) {
        log(.warn, msg, subsystem: subsystem, file: file, line: line)
    }
    static func error(_ msg: String, subsystem: String = "main", file: String = #file, line: Int = #line) {
        log(.error, msg, subsystem: subsystem, file: file, line: line)
    }

    // MARK: - Subsystem-enum convenience

    static func debug(_ msg: String, subsystem: Subsystem, file: String = #file, line: Int = #line) {
        log(.debug, msg, subsystem: subsystem, file: file, line: line)
    }
    static func info(_ msg: String, subsystem: Subsystem, file: String = #file, line: Int = #line) {
        log(.info, msg, subsystem: subsystem, file: file, line: line)
    }
    static func warn(_ msg: String, subsystem: Subsystem, file: String = #file, line: Int = #line) {
        log(.warn, msg, subsystem: subsystem, file: file, line: line)
    }
    static func error(_ msg: String, subsystem: Subsystem, file: String = #file, line: Int = #line) {
        log(.error, msg, subsystem: subsystem, file: file, line: line)
    }

    // MARK: - Test helpers

    /// Reset rate-limiter state. Call between tests to avoid carryover.
    static func resetForTests() {
        rateMapLock.lock(); defer { rateMapLock.unlock() }
        rateMap.removeAll()
    }

    /// Force the format for testing. Production code should use `LOG_FORMAT` env.
    static func setFormatForTests(_ newFormat: Format) {
        configLock.lock(); defer { configLock.unlock() }
        _format = newFormat
    }
}
