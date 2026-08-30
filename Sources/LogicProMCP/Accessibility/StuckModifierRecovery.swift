import CoreGraphics
import Darwin
import Foundation

/// Attempts a zero-flags synthetic key-up from a stale chord marker; it neither establishes that
/// a modifier remains held nor verifies event delivery.
///
/// WHY THIS EXISTS
/// ---------------
/// `AXMouseHelper.postFlaggedKeyEvent` attempts three separate posts: key-down with the requested
/// flags, key-up with those flags, and key-up with zero flags. The requested flags can be Control,
/// Shift, Option, Command, or empty; this code does not observe physical key state or delivery.
/// A process can terminate between those calls, leaving a marker that later startup code can use
/// only as a reason to attempt a zero-flags key-up.
///
/// Discussion #458 reported Logic becoming hard to use after running the integration — track volume
/// moving 0.1 dB at a time, tracks and locators not draggable. This code does not establish that
/// report's cause. It narrows one possible interruption window by recording a best-effort marker,
/// without proving that recovery is needed or reaches macOS.
///
/// WHY A MARKER AND NOT A BLIND CLEAR
/// ----------------------------------
/// Posting a modifier-clear at startup unconditionally would also fire while a user is genuinely
/// holding Shift, and nothing available here can tell a synthetic held flag from a physical one —
/// `CGEventSource.flagsState` reports the combined state and cannot say who put a flag there.
///
/// Each process attempts to write one PID-named marker before the first tracked chord and attempts
/// to remove it after the tracked depth returns to zero. At startup, this code attempts a clear
/// only after removing a parseable marker whose payload PID is different and does not currently
/// appear live. That limits blind clears, but it does not prove a marker's provenance, its owner's
/// lifetime, or that its modifier remains held: a PID can be reused, including across a reboot,
/// and best-effort arming means a live process can lack its marker.
/// A marker can survive a hard power loss, but that survival is not evidence that a clear is needed.
///
/// Residual limitations:
/// - PID reuse; reboot-stale markers; and a marker written under a different UID or home.
/// - Markers are unauthenticated, and the filename PID is never checked against the payload PID.
/// - No proof that a modifier is still held at recovery time, and no test covering production
///   `kill`/`errno` behavior or actual `CGEvent` delivery.
/// - A marker that cannot be written leaves the posting window as it was; the chord still runs
///   because refusing its keystroke after a breadcrumb failure would break the feature.
/// - A failed `disarm` can leave a completed marker, and the deliberate remove-before-post window
///   can lose a clear if the process stops after removal and before the post.
/// - An unmatched `ChordMarkerNesting.end` is logged but does not remove a marker.
/// - Two threads can overlap non-LIFO, leaving a marker key code from a chord that has ended. The
///   recovery post uses zero flags, so that stale code affects the log's accuracy rather than the
///   modifier-clear attempt: a zero-flags key-up clears modifier state independently of its key
///   code, while a key-up for a key nobody holds releases nothing.
/// - `ChordMarkerNesting` callbacks must not re-enter the chord path because they run under its
///   non-recursive lock.
/// - Production `AXMouseHelper.Runtime.postChord` and the `start()` wiring to recovery are not
///   exercised by the injected tests.
enum StuckModifierRecovery {

    /// Diagnostic data only: the chord's key code, flags, and PID. It records no UID, boot
    /// identity, process start time, or proof that the clear was not already posted.
    struct Marker: Codable, Equatable, Sendable {
        let keyCode: UInt16
        /// Diagnostic only. The default recovery poster builds an event with zero flags, because
        /// replaying the chord's own flags would re-assert them; an injected `post` closure is not
        /// constrained to do so.
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

    /// Returns a decoded, in-range marker key code, or nil when decoding or key-width validation
    /// fails. It does not establish the marker's provenance or trustworthiness.
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

    /// Returns true only when a different PID currently has no process. `ESRCH` establishes that
    /// current PID state, not the original marker owner or that a clear is still needed. Injecting
    /// the check leaves this decision testable without creating processes.
    static func shouldRecover(
        marker: Marker,
        isAlive: (Int32) -> Bool,
        selfPID: Int32
    ) -> Bool {
        marker.pid != selfPID && !isAlive(marker.pid)
    }

    /// Builds the default zero-flags key-up without posting it. This construction can be tested
    /// directly, but injected recovery tests do not constrain a replacement production poster.
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

    /// Attempts to remove the marker after the chord path has attempted its posts. A failed removal
    /// or a process stop before removal can leave a completed marker that later startup cannot
    /// distinguish from an interrupted chord.
    static func disarm(at url: URL? = defaultURL) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        _ = removeMarker(at: url)
    }

    /// Attempts a clear for each removable, parseable marker whose different PID currently has no
    /// process. It is not proven safe on every start: a reboot-stale marker can cause a post even
    /// though no modifier remains held.
    ///
    /// The marker is deliberately removed before posting, so a crash during posting cannot retry
    /// the same clear on every later start. Between successful removal and the post, another writer
    /// can recreate the file, and a kill in that window permanently loses the clear represented by
    /// the removed marker. The latter is the deliberate trade for avoiding a crashing post loop.
    ///
    /// The return value contains only key codes for which the poster reports constructing an event
    /// and calling `CGEvent.post`. A normal return from `CGEvent.post` is not proof that macOS
    /// delivered the event.
    @discardableResult
    static func recoverIfNeeded(
        in directory: URL? = defaultDirectoryURL,
        selfPID: Int32 = getpid(),
        isAlive: (Int32) -> Bool = processIsAlive,
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        post: (CGKeyCode) -> Bool = { keyCode in
            guard let clear = clearEvent(for: keyCode) else { return false }
            clear.post(tap: .cghidEventTap)
            return true
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
            if post(keyCode) {
                recovered.append(keyCode)
                Log.info(
                    "posted a modifier-clear event for a recovery marker (key \(keyCode)); delivery is not verified",
                    subsystem: "cgEvent")
            } else {
                Log.warn(
                    "modifier recovery marker was found, but its clear event could not be built and posted (key \(keyCode))",
                    subsystem: "cgEvent")
            }
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
