@preconcurrency import ApplicationServices
import Foundation
@testable import LogicProMCP

/// A control-bar display-mode double for the qualification cycles that need a four-component
/// playhead. The mode is a file (`display-mode`) in the server double's directory: the server
/// double reads it to decide whether it publishes the bar-and-beat readback of Logic's default
/// Beats & Project or the four components of Beats, and every call the cycle makes is appended to
/// the same `requests` log the server double writes, so one file shows the whole order.
final class QualificationPositionDisplayFake: @unchecked Sendable {
    enum Fault {
        case none
        /// The popup cannot be read at all.
        case unreadable
        /// A switch that reports itself done and changes nothing.
        case switchNotApplied
        /// A switch that cannot be performed.
        case switchUnavailable
        /// A restore that is refused outright.
        case restoreRefused
        /// A restore that reports itself done and changes nothing, so the re-read disagrees.
        case restoreNotApplied
    }

    static let beatsAndProject = "Beats & Project"
    static let beats = "Beats"

    let directory: URL
    let fault: Fault
    private let lock = NSLock()

    init(directory: URL, start: String, fault: Fault = .none) throws {
        self.directory = directory
        self.fault = fault
        try Data((start + "\n").utf8).write(to: modeFile)
    }

    var modeFile: URL { directory.appendingPathComponent("display-mode") }

    var mode: String {
        (try? String(contentsOf: modeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unreadable"
    }

    var display: QualificationPositionDisplay {
        QualificationPositionDisplay(
            read: { [self] in
                let current: String? = fault == .unreadable ? nil : mode
                log("read", mode: current)
                return current
            },
            selectBeats: { [self] in
                log("switch", mode: nil)
                if fault == .switchUnavailable {
                    return .unavailable("display_mode_beats_item_not_pressed")
                }
                let found = mode
                if fault != .switchNotApplied { write(Self.beats) }
                return .switched(lease(original: found))
            },
            restore: { [self] lease in
                log("restore", mode: nil)
                if fault == .restoreRefused { return .refused("display_mode_not_restored") }
                if fault != .restoreNotApplied { write(lease.original) }
                return .restored
            })
    }

    private func lease(original: String) -> ControlBarDisplayMode.Lease {
        ControlBarDisplayMode.Lease(
            original: original, window: AXUIElementCreateSystemWide(), windowTitle: "fixture",
            document: "fixture.logicx", popup: AXUIElementCreateSystemWide())
    }

    private func write(_ mode: String) {
        try? Data((mode + "\n").utf8).write(to: modeFile)
    }

    private func log(_ event: String, mode: String?) {
        lock.lock(); defer { lock.unlock() }
        var entry: [String: Any] = ["display_mode": event]
        entry["mode"] = mode ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = directory.appendingPathComponent("requests")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// The fixture's request log reduced to what the order of a cycle is made of: the display-mode
    /// calls (with the mode each read returned), every transport read, and every command that can
    /// move or stage something. Cache refreshes and unrelated reads are dropped.
    static func events(in directory: URL) -> [String] {
        let log = (try? String(
            contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8)) ?? ""
        let commands = ["play", "stop", "pause", "goto_bar", "goto_position", "goto_marker",
                        "create_marker", "delete_marker"]
        var events: [String] = []
        for line in log.split(separator: "\n") where !line.contains("__adr001b_no_write_probe") {
            if let data = line.data(using: .utf8),
               let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let kind = entry["display_mode"] as? String {
                let mode = entry["mode"] as? String
                events.append(mode.map { "mode_\(kind)=\($0)" } ?? "mode_\(kind)")
            } else if line.contains("\"uri\":\"logic://transport/state\"") {
                events.append("transport_read")
            } else if let command = commands.first(where: { line.contains("\"command\":\"\($0)\"") }) {
                events.append(command)
            }
        }
        return events
    }

    /// The last two display-mode calls, provided nothing else was logged between them: the mode
    /// restore and the read that confirms it. Whatever the sweep reads after the cycle is not part
    /// of the cycle and is not looked at.
    static func closingModeCalls(in events: [String]) -> [String] {
        let modeIndexes = events.indices.filter { events[$0].hasPrefix("mode_") }
        guard modeIndexes.count >= 2 else { return events }
        let last = modeIndexes[modeIndexes.count - 1], before = modeIndexes[modeIndexes.count - 2]
        return last == before + 1 ? [events[before], events[last]] : ["not adjacent"] + [events[before], events[last]]
    }

    /// The index of the first event at or after `from` that equals `event`.
    static func index(of event: String, in events: [String], from: Int = 0) -> Int? {
        guard from <= events.count else { return nil }
        return events[from...].firstIndex(of: event)
    }

    /// Whether `expected` is an ordered subsequence of `events`.
    static func containsInOrder(_ expected: [String], in events: [String]) -> Bool {
        var from = 0
        for event in expected {
            guard let found = index(of: event, in: events, from: from) else { return false }
            from = found + 1
        }
        return true
    }
}
