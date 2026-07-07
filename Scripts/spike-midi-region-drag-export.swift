#!/usr/bin/env swift
import CoreGraphics
import Foundation

struct JSONRecord: Encodable {
    let record_type: String
    let status: String
    let export_dir: String?
    let source: String?
    let destination: String?
    let path: String?
    let note: String
}

struct Point {
    let x: Double
    let y: Double
}

func emit(_ record: JSONRecord) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(record),
          let line = String(data: data, encoding: .utf8) else {
        return
    }
    print(line)
}

func argumentValue(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

func parsePoint(_ raw: String?) -> Point? {
    guard let raw else { return nil }
    let parts = raw.split(separator: ",", maxSplits: 1).map(String.init)
    guard parts.count == 2,
          let x = Double(parts[0]),
          let y = Double(parts[1]) else {
        return nil
    }
    return Point(x: x, y: y)
}

func pointLabel(_ point: Point?) -> String? {
    guard let point else { return nil }
    return "\(Int(point.x)),\(Int(point.y))"
}

func midiSnapshot(in directory: URL) -> [String: UInt64] {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    var snapshot: [String: UInt64] = [:]
    for url in urls where url.pathExtension.lowercased() == "mid" {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.uint64Value > 0,
              let modified = attrs[.modificationDate] as? Date else {
            continue
        }
        snapshot[url.path] = UInt64(modified.timeIntervalSince1970 * 1_000_000_000)
    }
    return snapshot
}

func newestChangedMIDI(in directory: URL, before: [String: UInt64]) -> URL? {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let changed = urls.filter { url in
            guard url.pathExtension.lowercased() == "mid",
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber,
                  size.uint64Value > 0,
                  let modified = attrs[.modificationDate] as? Date else {
                return false
            }
            let nanos = UInt64(modified.timeIntervalSince1970 * 1_000_000_000)
            return nanos > (before[url.path] ?? 0)
        }
        if let latest = changed.max(by: { left, right in
            let leftDate = ((try? FileManager.default.attributesOfItem(atPath: left.path)[.modificationDate]) as? Date) ?? .distantPast
            let rightDate = ((try? FileManager.default.attributesOfItem(atPath: right.path)[.modificationDate]) as? Date) ?? .distantPast
            return leftDate < rightDate
        }) {
            return latest
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

func postMouseDrag(from source: Point, to destination: Point) -> Bool {
    let sourcePoint = CGPoint(x: source.x, y: source.y)
    let destinationPoint = CGPoint(x: destination.x, y: destination.y)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: sourcePoint, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: destinationPoint, mouseButton: .left) else {
        return false
    }
    down.post(tap: .cghidEventTap)
    for step in 1...30 {
        let fraction = Double(step) / 30.0
        let x = source.x + (destination.x - source.x) * fraction
        let y = source.y + (destination.y - source.y) * fraction
        CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: x, y: y),
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
    }
    up.post(tap: .cghidEventTap)
    return true
}

let exportDir = URL(fileURLWithPath: argumentValue("--export-dir") ?? "/tmp/LogicProMCP-region-drag-spike")
let source = parsePoint(argumentValue("--source"))
let destination = parsePoint(argumentValue("--destination"))
let armed = ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_ARM_REGION_DRAG"] == "1"

try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
emit(JSONRecord(
    record_type: "region_drag_preflight",
    status: armed ? "armed" : "blocked",
    export_dir: exportDir.path,
    source: pointLabel(source),
    destination: pointLabel(destination),
    path: nil,
    note: armed
        ? "Armed live mouse drag. Use only with a scratch Logic project and verified source/destination coordinates."
        : "Refusing live drag until LOGIC_PRO_MCP_ARM_REGION_DRAG=1 is set; this prevents accidental timeline mutation."
))

guard armed else { exit(2) }
guard let source, let destination else {
    emit(JSONRecord(
        record_type: "region_drag_preflight",
        status: "blocked",
        export_dir: exportDir.path,
        source: pointLabel(source),
        destination: pointLabel(destination),
        path: nil,
        note: "Both --source x,y and --destination x,y are required."
    ))
    exit(2)
}

let before = midiSnapshot(in: exportDir)
guard postMouseDrag(from: source, to: destination) else {
    emit(JSONRecord(
        record_type: "region_drag_mouse",
        status: "failed",
        export_dir: exportDir.path,
        source: pointLabel(source),
        destination: pointLabel(destination),
        path: nil,
        note: "CGEvent drag could not be constructed."
    ))
    exit(2)
}

if let exported = newestChangedMIDI(in: exportDir, before: before) {
    emit(JSONRecord(
        record_type: "region_drag_export_result",
        status: "new_midi_found",
        export_dir: exportDir.path,
        source: pointLabel(source),
        destination: pointLabel(destination),
        path: exported.path,
        note: "Controlled file appeared. Parse and sentinel-equality verification must be performed before any State A claim."
    ))
    exit(0)
}

emit(JSONRecord(
    record_type: "region_drag_export_result",
    status: "no_midi_found",
    export_dir: exportDir.path,
    source: pointLabel(source),
    destination: pointLabel(destination),
    path: nil,
    note: "No controlled .mid file appeared; if drag landed inside Logic, run Cmd+Z and verify scratch-project rollback."
))
exit(2)
