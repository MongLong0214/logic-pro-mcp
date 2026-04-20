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

    /// Post a native double-click at the screen point. The two down/up
    /// pairs carry `clickCount = 2` on the second pair so macOS recognises
    /// the sequence as a double-click (single-clicks repeated quickly are
    /// NOT the same thing).
    static func doubleClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)

        post(.leftMouseDown, at: point, clickCount: 1, source: source)
        post(.leftMouseUp, at: point, clickCount: 1, source: source)

        // Inter-click pause must stay well under macOS's system-wide
        // double-click interval (default ~500 ms) — 40 ms is reliable.
        usleep(40_000)

        post(.leftMouseDown, at: point, clickCount: 2, source: source)
        post(.leftMouseUp, at: point, clickCount: 2, source: source)
    }

    private static func post(
        _ type: CGEventType,
        at point: CGPoint,
        clickCount: Int64,
        source: CGEventSource?
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
    }

    /// Post a sequence of keystrokes representing the given string. Only
    /// ASCII digits, `.`, `-` and `Return` are supported — sufficient for
    /// tempo / locator numeric entry.
    static func typeNumericString(_ s: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for ch in s {
            guard let keyCode = numericKeyCode(for: ch) else { continue }
            postKey(keyCode, source: source)
            usleep(15_000)
        }
    }

    /// Post a sequence of keystrokes for an arbitrary ASCII string. Uses
    /// Unicode text injection so we don't have to maintain a full virtual-key
    /// table — relies on the active input source to resolve characters. Used
    /// by the Library type-to-jump path when we need to seek to a preset that
    /// is scrolled out of the AX-visible but screen-invisible viewport.
    static func typeText(_ s: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for ch in s.unicodeScalars {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            var u16 = [UniChar(ch.value & 0xFFFF)]
            down.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16)
            up.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }

    /// Post a Return key tap.
    static func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        postKey(0x24, source: source)   // kVK_Return = 0x24
    }

    /// Post an Escape key tap (used to dismiss unwanted popups on error).
    static func pressEscape() {
        let source = CGEventSource(stateID: .combinedSessionState)
        postKey(0x35, source: source)   // kVK_Escape = 0x35
    }

    private static func postKey(_ keyCode: CGKeyCode, source: CGEventSource?) {
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
