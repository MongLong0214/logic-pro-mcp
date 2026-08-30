import CoreGraphics
import Foundation

/// Clears a synthetic modifier that a previous run left held, and nothing else.
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
/// A marker written before the chord and removed after it answers exactly the question that
/// matters: *did OUR process leave a chord unfinished?* Present means yes, and the recovery posts
/// the same key-up the interrupted sequence would have. Absent means nothing is owed and nothing is
/// posted. It cannot fire because of anything a user is doing.
///
/// WHAT IT DOES NOT COVER, stated rather than implied: `SIGKILL` and a hard power loss remove the
/// process without removing the marker, which is the case this recovers; a marker that cannot be
/// written (read-only home, sandbox) leaves the window exactly as wide as it is today, and the
/// chord still runs — refusing to send a keystroke because a breadcrumb failed would trade a rare
/// stuck modifier for a broken feature.
enum StuckModifierRecovery {

    /// What a marker records: enough to post the clear the interrupted run owed, and no more.
    struct Marker: Codable, Equatable, Sendable {
        let keyCode: UInt16
        /// Diagnostic only. The recovery always posts with NO flags, because the event it stands in
        /// for is the flag-clearing key-up — replaying the chord's own flags would re-assert them.
        let flags: UInt64
    }

    static var defaultURL: URL? {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return root
            .appendingPathComponent("LogicProMCP", isDirectory: true)
            .appendingPathComponent("chord-in-flight.json", isDirectory: false)
    }

    // MARK: - Pure core

    /// The key-up a recovery should post, or nil when nothing is owed.
    ///
    /// Separated from the filesystem so every branch is testable without one: a missing marker, a
    /// marker that will not decode, and a good one are three different answers and each is a case
    /// below in the tests.
    static func recoveryKeyCode(from data: Data?) -> CGKeyCode? {
        guard let data,
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.keyCode <= UInt16(CGKeyCode.max)
        else { return nil }
        return CGKeyCode(marker.keyCode)
    }

    static func encode(keyCode: CGKeyCode, flags: CGEventFlags) -> Data? {
        try? JSONEncoder().encode(Marker(keyCode: UInt16(keyCode), flags: flags.rawValue))
    }

    // MARK: - Filesystem edges

    /// Record that a chord is about to be posted. Best effort by design — see the type comment.
    static func arm(keyCode: CGKeyCode, flags: CGEventFlags, at url: URL? = defaultURL) {
        guard let url, let data = encode(keyCode: keyCode, flags: flags) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The chord finished, including its clearing event. Nothing is owed.
    static func disarm(at url: URL? = defaultURL) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Post the clear a previous run owed, if it owed one. Safe to call on every start.
    ///
    /// The marker is removed BEFORE the post, so a crash inside `post` cannot make this loop on
    /// every subsequent launch. Losing one recovery is better than a startup that keeps trying.
    @discardableResult
    static func recoverIfNeeded(
        at url: URL? = defaultURL,
        post: (CGKeyCode) -> Void = { keyCode in
            let source = CGEventSource(stateID: .combinedSessionState)
            guard let clear = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            else { return }
            clear.flags = CGEventFlags(rawValue: 0)
            clear.post(tap: .cghidEventTap)
        }
    ) -> CGKeyCode? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard let keyCode = recoveryKeyCode(from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        post(keyCode)
        Log.info(
            "cleared a modifier left held by an interrupted chord (key \(keyCode))",
            subsystem: "cgEvent")
        return keyCode
    }
}
