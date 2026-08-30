import CoreGraphics
import Foundation

/// Native CGEvent-based mouse + keyboard helpers for AX elements that
/// require real mouse double-click or typed input — specifically Logic
/// Pro's tempo slider and cycle locator sliders, which expose a
/// double-click-to-edit text overlay that System Events' `click at` /
/// AXPress path does not trigger.
///
/// Why native instead of osascript fallback: earlier attempts spawned
/// `/usr/bin/osascript` per call and leaked one file descriptor each time
/// (see AccessibilityChannel.swift comment at defaultSetTempo). Keeping
/// the double-click + keystroke sequence inside the server process
/// eliminates the FD exhaustion path entirely.
enum AXMouseHelper {
    struct Runtime: @unchecked Sendable {
        let postMouseEvent: @Sendable (CGEventType, CGPoint, Int64) -> Bool
        let postKeyEvent: @Sendable (CGKeyCode) -> Bool
        let postUnicodeScalar: @Sendable (UniChar) -> Bool
        let sleepMicros: @Sendable (useconds_t) -> Void
        /// Post a key chord WITH modifier flags (e.g. Ctrl+Shift+E). Kept
        /// separate from `postKeyEvent` (bare key) so callers that never need
        /// modifiers stay untouched; defaults to a no-op so existing `Runtime`
        /// constructions compile unchanged. Used by the #106 record-arm path
        /// (Logic's configurable "Toggle Track Record Enable" key command).
        let postFlaggedKeyEvent: @Sendable (CGKeyCode, CGEventFlags) -> Bool

        init(
            postMouseEvent: @escaping @Sendable (CGEventType, CGPoint, Int64) -> Bool,
            postKeyEvent: @escaping @Sendable (CGKeyCode) -> Bool,
            postUnicodeScalar: @escaping @Sendable (UniChar) -> Bool,
            sleepMicros: @escaping @Sendable (useconds_t) -> Void,
            postFlaggedKeyEvent: @escaping @Sendable (CGKeyCode, CGEventFlags) -> Bool = { _, _ in false }
        ) {
            self.postMouseEvent = postMouseEvent
            self.postKeyEvent = postKeyEvent
            self.postUnicodeScalar = postUnicodeScalar
            self.sleepMicros = sleepMicros
            self.postFlaggedKeyEvent = postFlaggedKeyEvent
        }

        static func keyboardEvents(
            source: CGEventSource?,
            keyCode: CGKeyCode,
            flags: CGEventFlags,
            clearModifiersAfter: Bool = false
        ) -> (down: CGEvent, up: CGEvent, modifierClear: CGEvent?)? {
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            else { return nil }
            down.flags = flags
            up.flags = flags

            guard clearModifiersAfter else { return (down, up, nil) }
            guard let modifierClear = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
            ) else { return nil }
            modifierClear.flags = CGEventFlags(rawValue: 0)
            return (down, up, modifierClear)
        }

        static let production = Runtime(
            postMouseEvent: { type, point, clickCount in
                let source = CGEventSource(stateID: .combinedSessionState)
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else { return false }
                event.setIntegerValueField(.mouseEventClickState, value: clickCount)
                event.post(tap: .cghidEventTap)
                return true
            },
            postKeyEvent: { keyCode in
                let source = CGEventSource(stateID: .combinedSessionState)
                guard let events = keyboardEvents(
                    source: source,
                    keyCode: keyCode,
                    flags: CGEventFlags(rawValue: 0)
                ) else { return false }
                events.down.post(tap: .cghidEventTap)
                events.up.post(tap: .cghidEventTap)
                return true
            },
            postUnicodeScalar: { scalar in
                let source = CGEventSource(stateID: .combinedSessionState)
                guard let events = keyboardEvents(
                    source: source,
                    keyCode: 0,
                    flags: CGEventFlags(rawValue: 0)
                ) else { return false }
                var u16 = [scalar]
                events.down.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16)
                events.up.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16)
                events.down.post(tap: .cghidEventTap)
                events.up.post(tap: .cghidEventTap)
                return true
            },
            sleepMicros: { usleep($0) },
            postFlaggedKeyEvent: { keyCode, flags in
                let source = CGEventSource(stateID: .combinedSessionState)
                guard let events = keyboardEvents(
                    source: source,
                    keyCode: keyCode,
                    flags: flags,
                    clearModifiersAfter: true
                ) else { return false }
                // Three separate posts, and a process that dies between the second and the third
                // leaves macOS holding a modifier no physical key is holding. The marker says a
                // chord is in flight so the next start can post the clear this run owed; see
                // `StuckModifierRecovery` for why a marker and not a blind clear at startup.
                StuckModifierRecovery.arm(keyCode: keyCode, flags: flags)
                defer { StuckModifierRecovery.disarm() }
                events.down.post(tap: .cghidEventTap)
                events.up.post(tap: .cghidEventTap)
                events.modifierClear?.post(tap: .cghidEventTap)
                return true
            }
        )
    }

    /// Post a native double-click at the screen point. The two down/up
    /// pairs carry `clickCount = 2` on the second pair so macOS recognises
    /// the sequence as a double-click (single-clicks repeated quickly are
    /// NOT the same thing). Returns true when every down/up event posted, so
    /// callers can fall back to another injector on failure.
    @discardableResult
    static func doubleClick(at point: CGPoint, runtime: Runtime = .production) -> Bool {
        let down1 = runtime.postMouseEvent(.leftMouseDown, point, 1)
        let up1 = runtime.postMouseEvent(.leftMouseUp, point, 1)

        // Inter-click pause must stay well under macOS's system-wide
        // double-click interval (default ~500 ms) — 40 ms is reliable.
        runtime.sleepMicros(40_000)

        let down2 = runtime.postMouseEvent(.leftMouseDown, point, 2)
        let up2 = runtime.postMouseEvent(.leftMouseUp, point, 2)
        return down1 && up1 && down2 && up2
    }

    /// Post a single native left-click at the screen point.
    @discardableResult
    static func click(at point: CGPoint, runtime: Runtime = .production) -> Bool {
        let down = runtime.postMouseEvent(.leftMouseDown, point, 1)
        runtime.sleepMicros(20_000)
        let up = runtime.postMouseEvent(.leftMouseUp, point, 1)
        return down && up
    }

    /// Post a sequence of keystrokes representing the given string. Only
    /// ASCII digits, `.`, `-` and `Return` are supported — sufficient for
    /// tempo / locator numeric entry.
    static func typeNumericString(_ s: String, runtime: Runtime = .production) {
        for ch in s {
            guard let keyCode = numericKeyCode(for: ch) else { continue }
            postKey(keyCode, runtime: runtime)
            runtime.sleepMicros(15_000)
        }
    }

    /// Post `s` as real keystrokes, ONE UTF-16 code unit at a time. `isCancelled`
    /// is checked immediately BEFORE each unit, so a command deadline firing mid-
    /// string stops posting further units (no new key after the deadline, #413).
    /// Returns true when the whole string was posted, false when cancellation
    /// stopped it part-way so the caller can fail closed.
    @discardableResult
    static func typeText(
        _ s: String,
        runtime: Runtime = .production,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        for codeUnit in s.utf16 {
            if isCancelled() { return false }
            _ = runtime.postUnicodeScalar(codeUnit)
            runtime.sleepMicros(12_000)
        }
        return true
    }

    /// Post a Return key tap.
    static func pressReturn(runtime: Runtime = .production) {
        postKey(0x24, runtime: runtime)   // kVK_Return = 0x24
    }

    /// Post an Escape key tap (used to dismiss unwanted popups on error).
    static func pressEscape(runtime: Runtime = .production) {
        postKey(0x35, runtime: runtime)   // kVK_Escape = 0x35
    }

    private static func postKey(_ keyCode: CGKeyCode, runtime: Runtime) {
        _ = runtime.postKeyEvent(keyCode)
    }

    /// Virtual key codes for numeric input (kVK_ANSI_0 .. kVK_ANSI_9 + decimal/minus).
    /// Reference: HIToolbox/Events.h (values are stable across macOS versions).
    private static func numericKeyCode(for ch: Character) -> CGKeyCode? {
        switch ch {
        case "0": return 0x1D
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19
        case ".": return 0x2F   // kVK_ANSI_Period
        case "-": return 0x1B   // kVK_ANSI_Minus
        default:  return nil
        }
    }
}
