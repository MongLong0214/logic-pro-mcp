#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

struct KeyEventSpec {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

// Canonical key names plus aliases. `enter` is accepted as a synonym for
// `return` and `esc` for `escape`. `normalize()` also strips a leading `--`, so
// a caller that passes a flag-style argument (e.g. `--return`) still resolves to
// the verified Return primitive instead of aborting with an "unknown option"
// error. This is the #186 fix: capture tooling that scripted `--return` now
// drives a real Return/Enter key press.
let keyEventByName: [String: KeyEventSpec] = [
    "space": KeyEventSpec(keyCode: 49, flags: []),
    "return": KeyEventSpec(keyCode: 36, flags: []),
    "enter": KeyEventSpec(keyCode: 36, flags: []),
    "escape": KeyEventSpec(keyCode: 53, flags: []),
    "esc": KeyEventSpec(keyCode: 53, flags: []),
]

// Canonical name per key code, so `--check enter`/`--check esc` confirm the
// resolved primitive ("return"/"escape") rather than echoing the alias.
let canonicalNameByKeyCode: [CGKeyCode: String] = [
    49: "space",
    36: "return",
    53: "escape",
]

func supportedKeysLine() -> String {
    keyEventByName.keys.sorted().joined(separator: ", ")
}

func normalize(_ raw: String) -> String {
    var value = raw.lowercased()
    while value.hasPrefix("-") { value.removeFirst() }
    return value
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
let helpTokens: Set<String> = ["-h", "--help", "--list", "help"]

// Discovery / preflight surface — lists supported keys WITHOUT posting an event,
// so a capture harness can verify the required input primitive is available
// before it starts recording.
if rawArgs.isEmpty || rawArgs.contains(where: { helpTokens.contains($0.lowercased()) }) {
    print("usage: logic_key_event [--check] <key>")
    print("keys: \(supportedKeysLine())")
    print("notes: a leading -- is accepted (e.g. --return); --check <key> validates a key without posting it")
    // No argument at all is a usage error; an explicit --help/--list is success.
    exit(rawArgs.isEmpty ? 64 : 0)
}

// `--check <key>` (a.k.a. --dry-run / -n) resolves and validates the key without
// posting a CGEvent. Capture tooling uses this to fail closed BEFORE recording
// when a required input flag is unsupported, instead of aborting mid-capture.
let checkTokens: Set<String> = ["--check", "--dry-run", "-n"]
let checkMode = rawArgs.first.map { checkTokens.contains($0.lowercased()) } ?? false
let keyArgs = checkMode ? Array(rawArgs.dropFirst()) : rawArgs
let requestedKey = keyArgs.first ?? ""
let keyName = normalize(requestedKey)

guard let keyEvent = keyEventByName[keyName] else {
    FileHandle.standardError.write(
        Data("unknown_key: \(requestedKey) (supported: \(supportedKeysLine()))\n".utf8)
    )
    exit(64)
}

let canonicalName = canonicalNameByKeyCode[keyEvent.keyCode] ?? keyName

if checkMode {
    print("ok:\(canonicalName)")
    exit(0)
}

guard CGPreflightPostEventAccess() else {
    FileHandle.standardError.write(Data("post_event_access_denied\n".utf8))
    exit(2)
}

if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first {
    app.activate()
    usleep(120_000)
}

let source = CGEventSource(stateID: .hidSystemState)
guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyEvent.keyCode, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyEvent.keyCode, keyDown: false) else {
    FileHandle.standardError.write(Data("event_create_failed\n".utf8))
    exit(1)
}

keyDown.flags = keyEvent.flags
keyUp.flags = keyEvent.flags
keyDown.post(tap: .cghidEventTap)
usleep(30_000)
keyUp.post(tap: .cghidEventTap)
print("ok")
