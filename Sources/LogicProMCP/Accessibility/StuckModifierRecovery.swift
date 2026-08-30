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
/// Each process attempts to write one PID-named marker before its outermost chord and removes it
/// after. At startup, this code only attempts a clear after removing a parseable marker whose
/// different PID does not currently appear live. That limits blind clears, but it does not prove a
/// marker's provenance, its owner's lifetime, or that its modifier remains held: a PID can be
/// reused, including across a reboot, and best-effort arming means a live process can lack its
/// marker.
/// A hard power loss can leave a marker but cannot leave the macOS event state held, so its
/// surviving marker is not evidence that a clear is needed.
///
/// Residual limitations: PID reuse; reboot-stale markers; a marker written under a different UID
/// or home; no proof that a modifier is still held at recovery time; and no test covering the
/// production `kill`/`errno` behavior or actual `CGEvent` delivery. A marker that cannot be
/// written (read-only home or sandbox) leaves the posting window as it was; the chord still runs
/// because refusing its keystroke after a breadcrumb failure would break the feature.
enum StuckModifierRecovery {

    /// Diagnostic data only: the chord's key code, flags, and PID. It records no UID, boot
    /// identity, process start time, or proof that the clear was not already posted.
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

    /// The chord finished, including its clearing event, so remove its marker. If the process dies
    /// after the clear but before this removal, a completed marker can survive without a matching
    /// log line and a later start cannot distinguish it from an interrupted chord.
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
