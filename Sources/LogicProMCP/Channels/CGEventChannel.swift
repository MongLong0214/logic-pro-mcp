import CoreGraphics
import Foundation

/// Channel that sends keyboard shortcuts to Logic Pro via CGEvent.
/// Uses CGEvent.postToPid() to deliver keystrokes directly without requiring window focus.
/// This is the primary channel for transport control and editing operations.
actor CGEventChannel: Channel {
    let id: ChannelID = .cgEvent

    struct Runtime: Sendable {
        let isLogicProRunning: @Sendable () -> Bool
        let logicProPID: @Sendable () -> pid_t?
        let postKeyEvent: @Sendable (CGKeyCode, CGEventFlags, pid_t) -> Bool
        let sleepMicros: @Sendable (useconds_t) -> Void

        static let production = Runtime(
            isLogicProRunning: { ProcessUtils.isLogicProRunning },
            logicProPID: { ProcessUtils.logicProPID() },
            postKeyEvent: { keyCode, flags, pid in
                performKeyEvent(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { usleep($0) }
        )
    }

    private let runtime: Runtime

    init(runtime: Runtime = .production) {
        self.runtime = runtime
    }

    /// A keyboard shortcut definition.
    struct Shortcut: Sendable, Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags

        static func key(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [])
        }

        static func cmd(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskCommand)
        }

        static func cmdShift(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [.maskCommand, .maskShift])
        }

        static func option(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskAlternate)
        }

        static func shift(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskShift)
        }

        static func cmdOption(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: [.maskCommand, .maskAlternate])
        }
    }

    /// Mapping from operation strings to keyboard shortcuts.
    /// Key codes: https://developer.apple.com/documentation/coregraphics/cgkeycode
    private static let keyMap: [String: Shortcut] = [
        // Transport
        "transport.play":             .key(49),         // Space
        "transport.stop":             .key(49),         // Space (toggles)
        "transport.record":           .key(15),         // R
        "transport.pause":            .key(49),         // Space
        "transport.rewind":           .key(123),        // Left arrow
        "transport.fast_forward":     .key(124),        // Right arrow
        "transport.toggle_cycle":     .key(8),          // C
        "transport.toggle_metronome": .key(40),         // K
        "transport.goto_position":    .key(44),         // / (opens Go To Position)

        // Editing
        "edit.undo":                  .cmd(6),          // Cmd+Z
        "edit.redo":                  .cmdShift(6),     // Cmd+Shift+Z
        "edit.cut":                   .cmd(7),          // Cmd+X
        "edit.copy":                  .cmd(8),          // Cmd+C
        "edit.paste":                 .cmd(9),          // Cmd+V
        "edit.delete":                .key(51),         // Delete
        "edit.select_all":            .cmd(0),          // Cmd+A
        "edit.split":                 .cmd(17),         // Cmd+T

        // Views
        "view.toggle_mixer":          .key(7),          // X
        "view.toggle_piano_roll":     .key(35),         // P
        "view.toggle_library":        .key(16),         // Y
        "view.toggle_inspector":      .key(34),         // I
        "view.toggle_score_editor":   .cmdOption(35),   // Cmd+Option+P (approximate)
        "view.toggle_step_editor":    .cmdOption(34),   // Cmd+Option+I (approximate)

        // Project
        "project.new":                .cmd(45),         // Cmd+N
        "project.save":               .cmd(1),          // Cmd+S
        "project.save_as":            .cmdShift(1),     // Cmd+Shift+S
        "project.close":              .cmd(13),         // Cmd+W

        // Track creation
        "track.create_audio":         .cmdOption(0),    // Option+Cmd+A (approximate)
        "track.create_instrument":    .cmdOption(1),    // Option+Cmd+S (approximate)
        "track.create_drummer":       .cmdOption(6),    // (approximate)
        "track.duplicate":            .cmd(2),          // Cmd+D
        "track.delete":               .cmd(51),         // Cmd+Delete

        // Navigation
        "nav.create_marker":          .cmdOption(39),   // (approximate)
        "nav.zoom_to_fit":            .key(6),          // Z
        "edit.join":                  .cmd(38),         // Cmd+J
        "edit.quantize":              .key(44),         // Q (approximate)
        "edit.bounce_in_place":       .cmdOption(11),   // (approximate)

        // Automation
        "automation.toggle_view":     .key(0),          // A
    ]

    func start() async throws {
        guard runtime.isLogicProRunning() else {
            Log.warn("Logic Pro not running at CGEvent channel start", subsystem: "cgEvent")
            return
        }
        Log.info("CGEvent channel started", subsystem: "cgEvent")
    }

    func stop() async {
        Log.info("CGEvent channel stopped", subsystem: "cgEvent")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard let pid = runtime.logicProPID() else {
            return .error("Logic Pro is not running")
        }

        if operation == "transport.goto_position" {
            let position = params["position"] ?? params["time"] ?? "1.1.1.1"
            guard let sequence = Self.gotoPositionSequence(for: position) else {
                return .error("Unsupported position format for CGEvent fallback: \(position)")
            }
            let sent = postShortcutSequence(sequence, pid: pid)
            if sent {
                return .success("{\"operation\":\"\(operation)\",\"sent\":true,\"position\":\"\(position)\"}")
            } else {
                return .error("Failed to post CGEvent sequence for \(operation)")
            }
        }

        guard let shortcut = Self.keyMap[operation] else {
            return .error("No keyboard shortcut mapped for: \(operation)")
        }

        let sent = runtime.postKeyEvent(shortcut.keyCode, shortcut.flags, pid)
        if sent {
            return .success("{\"operation\":\"\(operation)\",\"sent\":true}")
        } else {
            return .error("Failed to post CGEvent for \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard runtime.isLogicProRunning() else {
            return .unavailable("Logic Pro is not running")
        }
        guard runtime.logicProPID() != nil else {
            return .unavailable("Cannot determine Logic Pro PID")
        }
        return .healthy(detail: "CGEvent ready")
    }

    static func gotoPositionSequence(for position: String) -> [Shortcut]? {
        let openDialog = Shortcut.key(44)
        let confirm = Shortcut.key(36)
        let typed = position.map { keyStroke(for: $0) }
        guard typed.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return [openDialog] + typed.compactMap { $0 } + [confirm]
    }

    // MARK: - Event Posting

    static func keyStroke(for character: Character) -> Shortcut? {
        switch character {
        case "0": return .key(29)
        case "1": return .key(18)
        case "2": return .key(19)
        case "3": return .key(20)
        case "4": return .key(21)
        case "5": return .key(23)
        case "6": return .key(22)
        case "7": return .key(26)
        case "8": return .key(28)
        case "9": return .key(25)
        case ".": return .key(47)
        case ":": return .shift(41)
        default: return nil
        }
    }

    /// Post a key-down/key-up pair to a specific PID.
    private static func performKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.error("Failed to create CGEventSource", subsystem: "cgEvent")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.error("Failed to create CGEvent for keyCode \(keyCode)", subsystem: "cgEvent")
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.postToPid(pid)
        keyUp.postToPid(pid)

        Log.debug("Posted key \(keyCode) flags \(flags.rawValue) to PID \(pid)", subsystem: "cgEvent")
        return true
    }

    private func postShortcutSequence(_ sequence: [Shortcut], pid: pid_t) -> Bool {
        guard let first = sequence.first, runtime.postKeyEvent(first.keyCode, first.flags, pid) else {
            return false
        }

        for shortcut in sequence.dropFirst() {
            runtime.sleepMicros(20_000)
            guard runtime.postKeyEvent(shortcut.keyCode, shortcut.flags, pid) else {
                return false
            }
        }

        return true
    }
}
