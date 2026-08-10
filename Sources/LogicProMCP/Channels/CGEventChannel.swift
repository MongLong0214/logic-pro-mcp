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
        /// #440 D: whether Logic currently owns the keyboard.
        let isLogicFrontmost: @Sendable () -> Bool
        /// #440 D: bring Logic forward. Must NOT activate in-process — an
        /// in-process activation poisons this process's own `postToPid`, so the
        /// production path goes through AppleScript.
        let activateLogic: @Sendable () -> Bool

        /// The two #440 fields default to an already-frontmost Logic so existing
        /// callers that construct a Runtime for an unrelated reason keep
        /// compiling. The default is deliberately the PERMISSIVE one: a test
        /// that wants to exercise the gate must say so, and a test that does not
        /// mention frontmost is testing something else and should not be
        /// silently blocked by it. Production never takes these defaults — it
        /// uses `.production`, which wires the real probes.
        init(
            isLogicProRunning: @escaping @Sendable () -> Bool,
            logicProPID: @escaping @Sendable () -> pid_t?,
            postKeyEvent: @escaping @Sendable (CGKeyCode, CGEventFlags, pid_t) -> Bool,
            sleepMicros: @escaping @Sendable (useconds_t) -> Void,
            isLogicFrontmost: @escaping @Sendable () -> Bool = { true },
            activateLogic: @escaping @Sendable () -> Bool = { true }
        ) {
            self.isLogicProRunning = isLogicProRunning
            self.logicProPID = logicProPID
            self.postKeyEvent = postKeyEvent
            self.sleepMicros = sleepMicros
            self.isLogicFrontmost = isLogicFrontmost
            self.activateLogic = activateLogic
        }

        static let production = Runtime(
            isLogicProRunning: { ProcessUtils.isLogicProRunning },
            logicProPID: { ProcessUtils.logicProPID() },
            postKeyEvent: { keyCode, flags, pid in
                performKeyEvent(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { usleep($0) },
            isLogicFrontmost: ProcessUtils.Runtime.production.logicIsFrontmost,
            activateLogic: ProcessUtils.Runtime.production.activateLogicPro
        )
    }

    /// #440 D: why no event was posted. A CGEvent keystroke delivered while
    /// Logic is in the background is swallowed by the window server, and the
    /// caller previously saw a sent-but-unverified success for a keystroke Logic
    /// never received. Preparation now runs first and posts nothing when it
    /// fails, so the failure is visible instead of silent.
    /// The shared gate's outcome; kept under this name so existing callers and receipts are
    /// unchanged. The algorithm lives in `FrontmostGate` because the AX transport path needs the
    /// same precondition.
    typealias FrontmostPreparation = FrontmostGate.Preparation

    /// Consecutive frontmost observations required before posting. One reading
    /// can catch the window server mid-switch, which is exactly the race that
    /// makes a keystroke land nowhere.
    static let requiredFrontmostObservations = 2
    /// Bound on how long activation is given, as a count of polls.
    static let maximumActivationPolls = 20
    /// Settle between polls, and between activation and the first observation.
    static let activationPollMicros: useconds_t = 50_000

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
    /// Internal (not private) so the routing-audit invariant test in
    /// `RoutingAuditInvariantTests` can cross-check this table against
    /// `ChannelRouter.routingTable` and `MIDIKeyCommandsChannel.mappingTable`.
    static let keyMap: [String: Shortcut] = [
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
            // #440 D: prepare BEFORE the sequence, not per keystroke. A sequence
            // that lost the keyboard halfway would leave the Go To Position
            // dialog open with a partial value typed into it.
            let preparation = prepareFrontmost()
            guard preparation.isReady else {
                return Self.frontmostRefusal(operation: operation, preparation: preparation)
            }
            let sent = postShortcutSequence(sequence, pid: pid)
            if sent {
                // v3.1.1 (P2-2) — State B envelope. CGEvent sends keystrokes
                // fire-and-forget; we cannot read back the playhead position
                // from this channel, so success is `readback_unavailable`.
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "operation": operation,
                        "method": "cgevent",
                        "position": position,
                        "frontmost_preparation": preparation.rawValue,
                        "sent": true
                    ]
                ))
            } else {
                return .error("Failed to post CGEvent sequence for \(operation)")
            }
        }

        guard let shortcut = Self.keyMap[operation] else {
            return .error("No keyboard shortcut mapped for: \(operation)")
        }

        // #440 D: same gate as the sequence path. A mapped chord posted while
        // Logic is in the background is swallowed, and the State B envelope
        // below would then report a keystroke Logic never received.
        let preparation = prepareFrontmost()
        guard preparation.isReady else {
            return Self.frontmostRefusal(operation: operation, preparation: preparation)
        }

        let sent = runtime.postKeyEvent(shortcut.keyCode, shortcut.flags, pid)
        if sent {
            // v3.1.1 (P2-2) — same rationale as above. Single key chord
            // delivered; no read-back possible from this channel.
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: [
                    "operation": operation,
                    "method": "cgevent",
                    "frontmost_preparation": preparation.rawValue,
                    "sent": true
                ]
            ))
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

    /// #440 D: bring Logic forward and prove it owns the keyboard, before any
    /// event is created. Returns without posting anything when it cannot.
    ///
    /// Two consecutive frontmost observations are required rather than one. A
    /// single reading can be taken while the window server is mid-switch, and a
    /// keystroke posted in that window reaches nothing — which is the failure
    /// this gate exists to remove, so a gate that could itself be fooled by it
    /// would be pointless.
    func prepareFrontmost() -> FrontmostPreparation {
        FrontmostGate.prepare(
            isFrontmost: runtime.isLogicFrontmost,
            activate: runtime.activateLogic,
            sleepMicros: runtime.sleepMicros
        )
    }

    private func consecutiveFrontmostObservations() -> Int {
        var seen = 0
        for _ in 0..<Self.requiredFrontmostObservations {
            guard runtime.isLogicFrontmost() else { return 0 }
            seen += 1
            if seen < Self.requiredFrontmostObservations {
                runtime.sleepMicros(Self.activationPollMicros)
            }
        }
        return seen
    }

    /// State C for a refused preparation. `write_attempted` is false and
    /// `events_posted` is zero because nothing was created: the caller can
    /// retry without wondering whether a partial keystroke landed.
    static func frontmostRefusal(operation: String, preparation: FrontmostPreparation) -> ChannelResult {
        .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "CGEvent keystrokes are delivered to the frontmost application; Logic Pro did not own the "
                + "keyboard, so no event was posted. Bring Logic Pro to the front and retry.",
            extras: [
                "operation": operation,
                "method": "cgevent",
                "frontmost_preparation": preparation.rawValue,
                "events_posted": 0,
                "write_attempted": false,
                "safe_to_retry": true,
            ]
        ))
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
