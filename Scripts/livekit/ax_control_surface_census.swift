// What control surfaces does Logic have installed, and what are their ports bound to?
//
// Measured 2026-09-11: this host had ZERO devices and an Input Port reading `Invalid Port`, so
// nothing this product sent on the MCU port reached Logic — while `logic_system health` reported
// `mcu.connected: true` and `registered_as_device: true` throughout, because those are set by any
// INBOUND traffic rather than by a handshake reply.
//
// A census rather than an assertion: it prints what is there, and the caller decides. Requires the
// Control Surface Setup window to be open (Logic Pro > Control Surfaces > Setup…).
//
//   swiftc -O ax_control_surface_census.swift -o census && ./census
import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }; return v }
func s(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first!
let ax = AXUIElementCreateApplication(app.processIdentifier)
let wins = (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
guard let w = wins.first(where: { s($0, kAXTitleAttribute as String).contains("Control Surface") }) else { exit(1) }
var all: [AXUIElement] = []
func walk(_ e: AXUIElement, _ d: Int) { if d > 12 { return }; all.append(e); for c in kids(e) { walk(c, d+1) } }
walk(w, 0)
let tables = all.filter { s($0, kAXRoleAttribute as String) == "AXTable" }
for (ti, t) in tables.enumerated() {
    var sub: [AXUIElement] = []
    func w2(_ e: AXUIElement, _ d: Int) { if d > 6 { return }; sub.append(e); for c in kids(e) { w2(c, d+1) } }
    w2(t, 0)
    let rows = sub.filter { s($0, kAXRoleAttribute as String) == "AXRow" }
    print("table[\(ti)] rows=\(rows.count)")
    for (ri, r) in rows.prefix(6).enumerated() {
        var rs: [AXUIElement] = []
        func w3(_ e: AXUIElement, _ d: Int) { if d > 5 { return }; rs.append(e); for c in kids(e) { w3(c, d+1) } }
        w3(r, 0)
        let texts = rs.compactMap { e -> String? in
            let v = s(e, kAXValueAttribute as String); return v.isEmpty ? nil : v
        }
        print("   row[\(ri)]: \(texts.prefix(4))")
    }
}
// The device area sits above; list any group whose descendants mention a device name.
print("=== any element mentioning Mackie / Control / MCU ===")
for e in all {
    let blob = (s(e, kAXValueAttribute as String) + " " + s(e, kAXDescriptionAttribute as String) + " " + s(e, kAXTitleAttribute as String))
    if blob.lowercased().contains("mackie") || blob.lowercased().contains("logicpromcp") {
        print("  \(s(e, kAXRoleAttribute as String)): \(blob.trimmingCharacters(in: .whitespaces))")
    }
}
