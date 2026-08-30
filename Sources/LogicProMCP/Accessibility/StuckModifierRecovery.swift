import CoreGraphics
import Darwin
import Foundation

/// Clears a synthetic modifier that an interrupted process left held.
///
/// WHY THIS EXISTS
/// ---------------
/// A flagged chord is three posts: key-down with flags, key-up with flags, and a key-up with NO
/// flags whose only job is to release the modifier. `AXMouseHelper.postFlaggedKeyEvent` sends all
/// three back to back, so the sequence is correct — but it is three separate calls, and a process
/// that dies between the second and the third leaves macOS believing Control or Shift is held while
/// no physical key is down.
///
/// That is not hypothetical. Discussion #458 reported Logic becoming hard to use after running the
/// integration — track volume moving 0.1 dB at a time, tracks and locators not draggable — which is
/// the signature of a held Control during mouse interaction. I could not reproduce it in normal use
/// and still cannot; the only way I produced the state was by deliberately omitting the third event.
/// So this does not claim to be that user's cause. It closes the window I found while looking,
/// which was left open with only an acknowledgement.
///
/// WHY A MARKER AND NOT A BLIND CLEAR
/// ----------------------------------
/// Posting a modifier-clear at startup unconditionally would also fire while a user is genuinely
/// holding Shift, and nothing available here can tell a synthetic held flag from a physical one —
/// `CGEventSource.flagsState` reports the combined state and cannot say who put a flag there.
///
/// Each process writes its own PID-bearing marker before its chord and removes it after. Startup
/// only clears a marker whose owner is gone, and only after removing that marker. A live process
/// keeps its marker, so another ordinary MCP launch does not post into its in-flight chord. PID
/// reuse is the remaining ambiguity: an unrelated process can inherit a dead marker's PID, making
/// that marker look live. Recovery then skips it, leaving the stuck modifier in the same state as
/// before this feature; it never posts a keystroke the user did not ask for.
///
/// WHAT IT DOES NOT COVER, stated rather than implied: `SIGKILL` and a hard power loss remove the
/// process without removing the marker, which is the case this recovers; a marker that cannot be
/// written (read-only home, sandbox) leaves the window exactly as wide as it is today, and the
/// chord still runs — refusing to send a keystroke because a breadcrumb failed would trade a rare
/// stuck modifier for a broken feature.
enum StuckModifierRecovery {

    /// What a marker records: enough to identify its owner and post the clear it owed, and no more.
    struct Marker: Codable, Equatable, Sendable {
        let keyCode: UInt16
        /// Diagnostic only. The recovery always posts with NO flags, because the event it stands in
        /// for is the flag-clearing key-up — replaying the chord's own flags would re-assert them.
        let flags: UInt64
        let pid: Int32
    }

    private static let markerPrefix = "chord-in-flight-"
    private static let markerSuffix = ".json"

    static var defaultDirectoryURL: URL? {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return root.appendingPathComponent("LogicProMCP", isDirectory: true)
    }

    static var defaultURL: URL? {
        guard let directory = defaultDirectoryURL else { return nil }
        return markerURL(for: getpid(), in: directory)
    }

    static func markerURL(for pid: Int32, in directory: URL) -> URL {
        directory.appendingPathComponent("\(markerPrefix)\(pid)\(markerSuffix)", isDirectory: false)
    }

    // MARK: - Pure core

    /// The key-up a recovery should post, or nil when the marker is not trustworthy.
    static func recoveryKeyCode(from data: Data?) -> CGKeyCode? {
        guard let marker = marker(from: data) else { return nil }
        return CGKeyCode(marker.keyCode)
    }

    static func encode(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        pid: Int32 = getpid()
    ) -> Data? {
        try? JSONEncoder().encode(Marker(keyCode: UInt16(keyCode), flags: flags.rawValue, pid: pid))
    }

    /// Keep every liveness uncertainty on the safe side: only a known-dead, other process is owed
    /// a clear. Injecting the check leaves this decision testable without creating processes.
    static func shouldRecover(
        marker: Marker,
        isAlive: (Int32) -> Bool,
        selfPID: Int32
    ) -> Bool {
        marker.pid != selfPID && !isAlive(marker.pid)
    }

    /// Builds the final key-up without posting it, so its zero-flags contract is independently
    /// testable and cannot drift behind the recovery tests that inject their own poster.
    static func clearEvent(for keyCode: CGKeyCode) -> CGEvent? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let clear = CGEvent(
            keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return nil }
        clear.flags = CGEventFlags(rawValue: 0)
        return clear
    }

    // MARK: - Filesystem edges

    /// Record that a chord is about to be posted. Best effort by design — see the type comment.
    static func arm(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        at url: URL? = defaultURL,
        pid: Int32 = getpid()
    ) {
        guard let url, let data = encode(keyCode: keyCode, flags: flags, pid: pid) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The chord finished, including its clearing event. A surviving marker must be visible in logs
    /// because another start would otherwise mistake this completed chord for an interrupted one.
    static func disarm(at url: URL? = defaultURL) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        _ = removeMarker(at: url)
    }

    /// Post every orphaned clear a previous process owed, if any. Safe to call on every start.
    ///
    /// A remove must both return normally and leave no file behind before a clear is posted. That
    /// makes concurrent starts race safely: only the process that actually removed a marker can
    /// recover it.
    @discardableResult
    static func recoverIfNeeded(
        in directory: URL? = defaultDirectoryURL,
        selfPID: Int32 = getpid(),
        isAlive: (Int32) -> Bool = processIsAlive,
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        post: (CGKeyCode) -> Void = { keyCode in
            guard let clear = clearEvent(for: keyCode) else { return }
            clear.post(tap: .cghidEventTap)
        }
    ) -> [CGKeyCode] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return [] }

        var recovered: [CGKeyCode] = []
        for url in urls where isMarkerURL(url) {
            guard let marker = marker(from: try? Data(contentsOf: url)) else {
                _ = removeMarker(at: url, remove: remove, fileExists: fileExists)
                continue
            }
            guard shouldRecover(marker: marker, isAlive: isAlive, selfPID: selfPID) else { continue }
            guard removeMarker(at: url, remove: remove, fileExists: fileExists) else { continue }

            let keyCode = CGKeyCode(marker.keyCode)
            post(keyCode)
            recovered.append(keyCode)
            Log.info(
                "cleared a modifier left held by an interrupted chord (key \(keyCode))",
                subsystem: "cgEvent")
        }
        return recovered
    }

    private static func marker(from data: Data?) -> Marker? {
        guard let data,
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.keyCode <= UInt16(CGKeyCode.max)
        else { return nil }
        return marker
    }

    private static func isMarkerURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(markerPrefix) && name.hasSuffix(markerSuffix)
    }

    private static func removeMarker(
        at url: URL,
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        do {
            try remove(url)
        } catch {
            Log.warn("could not remove modifier recovery marker at \(url.path): \(error)", subsystem: "cgEvent")
            return false
        }
        guard !fileExists(url.path) else {
            Log.warn("modifier recovery marker remained after removal at \(url.path)", subsystem: "cgEvent")
            return false
        }
        return true
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        // `kill(-1, 0)` has process-group semantics, so malformed marker data must never reach it.
        guard pid > 0 else { return true }
        guard kill(pid_t(pid), 0) != 0 else { return true }
        switch errno {
        case EPERM:
            return true
        case ESRCH:
            return false
        default:
            return true
        }
    }
}
