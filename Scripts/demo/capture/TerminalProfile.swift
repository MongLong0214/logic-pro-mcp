// TerminalProfile: write a Terminal.app `.terminal` settings file for the on-camera client window.
//
// Opaque (the stock "Clear Dark" profile is translucent and would show whatever is behind it), a large monospaced
// font so the client stays legible when the film scales it down, and the landing site's colours. Opening the file
// with `open` makes Terminal open one window with these settings and run `--command` in it; nothing is clicked.
//
//   TerminalProfile --out demo.terminal --command "tmux -L logic-aqua attach -t lpmdemo" [--font-size 24] [--cols 70] [--rows 22]
import AppKit

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func archived(_ obj: Any) -> Data {
    (try? NSKeyedArchiver.archivedData(withRootObject: obj, requiringSecureCoding: false)) ?? Data()
}

func rgb(_ hex: String) -> NSColor {
    let v = Int(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

guard let out = arg("--out"), let command = arg("--command") else {
    print("usage: TerminalProfile --out FILE --command CMD [--font-size N] [--cols N] [--rows N]")
    exit(2)
}
let size = CGFloat(Double(arg("--font-size") ?? "24") ?? 24)
let font = NSFont(name: "SFMono-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
let name = arg("--name") ?? "Logic Pro MCP demo"
let settings: [String: Any] = [
    "name": name,
    "type": "Window Settings",
    "ProfileCurrentVersion": 2.07,
    "Font": archived(font),
    "FontAntialias": true,
    "FontWidthSpacing": 1.0,
    "FontHeightSpacing": 1.05,
    "BackgroundColor": archived(rgb("#101512")),
    "TextColor": archived(rgb("#f1f0eb")),
    "TextBoldColor": archived(rgb("#ffffff")),
    "CursorColor": archived(rgb("#d4ed77")),
    "SelectionColor": archived(rgb("#2c3530")),
    "UseBrightBold": true,
    "columnCount": Int(arg("--cols") ?? "70") ?? 70,
    "rowCount": Int(arg("--rows") ?? "22") ?? 22,
    "CommandString": command,
    "RunCommandAsShell": false,
    "shellExitAction": 1,
    "ShowWindowSettingsNameInTitle": false,
    "ShowShellCommandInTitle": false,
    "ShowDimensionsInTitle": false,
    "ShowRepresentedURLInTitle": false,
    "ShowRepresentedURLPathInTitle": false,
    "ShowActiveProcessInTitle": false,
    "ShowTTYNameInTitle": false,
    "ShowCommandKeyInTitle": false,
    "WindowTitle": name,
    "ShowActiveProcessArgumentsInTitle": false,
    "ScrollbackLines": 2000,
    "ShouldLimitScrollback": 1,
]
let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out): \(font.fontName) \(size) pt")
