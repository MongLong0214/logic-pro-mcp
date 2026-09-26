import CoreGraphics
import Darwin
import Foundation

/// #942. Pure readers over the list `CGWindowListCopyWindowInfo` returns, so the post-leaf
/// settlement of `goto_position` can be decided from a measurement the parent took in-process.
///
/// Why the window server and not AX or AppleScript: an open Logic menu wedges AppleEvent dispatch
/// (-1712) and a modal dialog poisons every AX reading, so the two components that could be asked
/// "is a menu still up" are exactly the ones the leftover state disables. The window server is
/// neither, and `ProcessUtils.logicOwnsTheKeyboard` and `logicOwnedPopupMenuWindowCount` in
/// AccessibilityChannel+VerifiedPlugins already read it for the same reason.
///
/// Every function takes the raw list as an argument rather than calling CoreGraphics itself. That
/// is what lets each branch be driven from a fixture, and it is also what keeps the readings
/// consistent with each other: the caller reads the list once and puts every question to that one
/// array. A list that failed to come back never reaches these functions; the caller reports that
/// as unreadable, because a read that did not happen is not an empty screen.
enum LogicOnScreenWindows {
    struct Entry: Equatable, Sendable {
        let number: Int
        let layer: Int
        let bounds: CGRect?
        let name: String?
    }

    /// The layer the window server gives a popup menu. Read from CoreGraphics rather than spelled
    /// as 101 so a toolchain that moves it moves this with it.
    static var popupMenuLevel: Int { Int(CGWindowLevelForKey(.popUpMenuWindow)) }

    /// The rows Logic owns, with the keys the other readers need. A row without a window number
    /// or a layer is dropped: the window server documents both as keys every row carries, so a
    /// row missing one is malformed rather than a window in an unknown state, and the two readers
    /// this follows skip it as well.
    static func logicOwned(_ windows: [[String: Any]], logicPID: pid_t) -> [Entry] {
        windows.compactMap { window in
            guard let owner = ProcessUtils.pidValue(from: window[kCGWindowOwnerPID as String]), owner == logicPID,
                  let number = intValue(window[kCGWindowNumber as String]),
                  let layer = intValue(window[kCGWindowLayer as String]) else {
                return nil
            }
            return Entry(
                number: number,
                layer: layer,
                bounds: rect(window[kCGWindowBounds as String]),
                name: window[kCGWindowName as String] as? String
            )
        }
    }

    /// How many Logic-owned windows sit at exactly the popup-menu layer. Exactly, because a Logic
    /// window one level up is a different kind of surface and another process's popup is not
    /// Logic's menu; neither is something an Escape sent to Logic would close.
    static func popupMenuCount(_ windows: [[String: Any]], logicPID: pid_t) -> Int {
        let level = popupMenuLevel
        return logicOwned(windows, logicPID: logicPID).filter { $0.layer == level }.count
    }

    /// Whether the process that owns the keyboard is Logic, read the way
    /// `ProcessUtils.logicOwnsTheKeyboard` reads it: the list is ordered front to back and the
    /// first normal-layer window belongs to the app keystrokes go to. This one answers nil, rather
    /// than false, when there is no such window or its owner cannot be read: an Escape must not be
    /// sent on the strength of a reading that was not taken.
    static func keyboardOwnerIsLogic(_ windows: [[String: Any]], logicPID: pid_t) -> Bool? {
        for window in windows {
            guard intValue(window[kCGWindowLayer as String]) == 0 else { continue }
            guard let owner = ProcessUtils.pidValue(from: window[kCGWindowOwnerPID as String]) else { return nil }
            return owner == logicPID
        }
        return nil
    }

    /// Logic-owned windows that were not on screen in `baseline`, the menu layer excluded. The
    /// menu is counted by `popupMenuCount`; what this answers is whether the leaf click left a
    /// window behind, which is the Go To Position dialog if it is anything the parent opened.
    static func appearedSince(
        baseline: Set<Int>, in windows: [[String: Any]], logicPID: pid_t
    ) -> [Entry] {
        let level = popupMenuLevel
        return logicOwned(windows, logicPID: logicPID).filter {
            !baseline.contains($0.number) && $0.layer != level
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
