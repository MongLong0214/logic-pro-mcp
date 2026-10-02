// #1039 review R1 (PR #1085): set or reset TIS's ASCII-capable layout for the live check.
// Build: swiftc -O Scripts/livekit/ax_1039_ascii_history.swift -o <path>; pass <path> to
// live_1039_plain_letters_under_2set_korean.py --ascii-history-tool. It changes the machine's
// enabled input sources: `dvorak` enables Dvorak, `reset` disables it again.
//   ascii_history read            -> prints current source, ASCII layout, and what R types in ABC/US/Dvorak
//   ascii_history dvorak          -> enable Dvorak, select it, select 2-Set Korean; ASCII layout must read Dvorak
//   ascii_history reset           -> select ABC, select 2-Set Korean, disable Dvorak; ASCII layout must read ABC
import Carbon
import Foundation

let korean = "com.apple.inputmethod.Korean.2SetKorean"
let abc = "com.apple.keylayout.ABC"
let dvorak = "com.apple.keylayout.Dvorak"
let us = "com.apple.keylayout.US"

func source(_ id: String, installed: Bool) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, installed)?.takeRetainedValue(), CFArrayGetCount(list) > 0,
          let raw = CFArrayGetValueAtIndex(list, 0) else { return nil }
    return Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
}

func id(_ s: TISInputSource?) -> String {
    guard let s, let raw = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "nil" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func letter(_ layoutID: String, _ keyCode: UInt16) -> String {
    guard let s = source(layoutID, installed: true),
          let rawData = TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) else { return "nil" }
    let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return "nil" }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    var dead: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0
    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
    return status == noErr ? String(utf16CodeUnits: chars, count: length) : "err\(status)"
}

let usKeys: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]

func state() -> [String: Any] {
    let enabled = source(dvorak, installed: false) != nil
    return [
        "current": id(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()),
        "ascii_layout": id(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()),
        "dvorak_enabled": enabled,
        "abc_enabled": source(abc, installed: false) != nil,
        "us_enabled": source(us, installed: false) != nil,
        "r_key_types": ["abc": letter(abc, 15), "us": letter("com.apple.keylayout.US", 15), "dvorak": letter(dvorak, 15)],
        // For each U.S. letter key, what ABC and Dvorak type on it: the harness derives from this
        // which layout a key must go out under.
        "us_letter_keys": Dictionary(uniqueKeysWithValues: usKeys.map { letterName, code in
            (letterName, ["abc": letter(abc, code), "us": letter(us, code), "dvorak": letter(dvorak, code)])
        }),
    ]
}

func select(_ target: String) -> Bool {
    guard let s = source(target, installed: false) else { return false }
    let ok = TISSelectInputSource(s) == noErr
    usleep(300_000)
    return ok
}

func emit(_ extra: [String: Any]) {
    var out = state()
    out.merge(extra) { _, new in new }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

switch CommandLine.arguments.dropFirst().first {
case "dvorak":
    var steps: [String: Any] = [:]
    if source(dvorak, installed: false) == nil, let s = source(dvorak, installed: true) {
        steps["enable"] = TISEnableInputSource(s) == noErr
        usleep(300_000)
    }
    steps["select_dvorak"] = select(dvorak)
    steps["select_korean"] = select(korean)
    let s = state()
    emit(steps)
    exit((s["ascii_layout"] as? String) == dvorak && (s["current"] as? String) == korean ? 0 : 1)
case "dvorak-us":
    // #1085 review R2: ABC installed but disabled, U.S. enabled, Dvorak offered. U.S. is enabled
    // before ABC is disabled, so an ASCII-capable layout stays enabled throughout.
    var steps: [String: Any] = [:]
    for id in [us, dvorak] where source(id, installed: false) == nil {
        if let s = source(id, installed: true) { steps["enable_\(id)"] = TISEnableInputSource(s) == noErr; usleep(300_000) }
    }
    steps["select_dvorak"] = select(dvorak)
    steps["select_korean"] = select(korean)
    if let s = source(abc, installed: false) { steps["disable_abc"] = TISDisableInputSource(s) == noErr; usleep(300_000) }
    let s = state()
    emit(steps)
    exit((s["ascii_layout"] as? String) == dvorak && (s["current"] as? String) == korean
         && (s["abc_enabled"] as? Bool) == false && (s["us_enabled"] as? Bool) == true ? 0 : 1)
case "reset-us":
    // Undo dvorak-us: ABC enabled and offered again, U.S. and Dvorak disabled.
    var steps: [String: Any] = [:]
    if source(abc, installed: false) == nil, let s = source(abc, installed: true) {
        steps["enable_abc"] = TISEnableInputSource(s) == noErr; usleep(300_000)
    }
    steps["select_abc"] = select(abc)
    steps["select_korean"] = select(korean)
    for id in [dvorak, us] {
        if let s = source(id, installed: false) { steps["disable_\(id)"] = TISDisableInputSource(s) == noErr; usleep(300_000) }
    }
    let s = state()
    emit(steps)
    exit((s["ascii_layout"] as? String) == abc && (s["current"] as? String) == korean
         && (s["abc_enabled"] as? Bool) == true ? 0 : 1)
case "reset":
    var steps: [String: Any] = ["select_abc": select(abc), "select_korean": select(korean)]
    if let s = source(dvorak, installed: false) {
        steps["disable"] = TISDisableInputSource(s) == noErr
        usleep(300_000)
    }
    let s = state()
    emit(steps)
    exit((s["ascii_layout"] as? String) == abc && (s["current"] as? String) == korean ? 0 : 1)
default:
    emit([:])
}
