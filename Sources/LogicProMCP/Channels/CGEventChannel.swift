import Carbon
import CoreGraphics
import Foundation

/// Channel that sends keyboard shortcuts to Logic Pro via CGEvent.
/// Uses CGEvent.postToPid() to deliver keystrokes directly without requiring window focus.
/// This is the primary channel for transport control and editing operations.
actor CGEventChannel: Channel {
    let id: ChannelID = .cgEvent

    /// The keyboard input source a posted key is read through, as TIS reports it.
    struct InputSourceReading: Sendable, Equatable {
        let id: String?
        let isASCIICapable: Bool
    }

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
        /// #1029 review R-03 / #1039: the current keyboard input source, or nil when it did not
        /// read. A plain letter is refused under nil as under a non-ASCII source, so the default is
        /// an ASCII-capable source with no id: the permissive one, for the same reason as the two
        /// #440 defaults below. `.production` reads TIS.
        let currentInputSource: @Sendable () -> InputSourceReading?

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
            activateLogic: @escaping @Sendable () -> Bool = { true },
            currentInputSource: @escaping @Sendable () -> InputSourceReading? = {
                InputSourceReading(id: nil, isASCIICapable: true)
            }
        ) {
            self.isLogicProRunning = isLogicProRunning
            self.logicProPID = logicProPID
            self.postKeyEvent = postKeyEvent
            self.sleepMicros = sleepMicros
            self.isLogicFrontmost = isLogicFrontmost
            self.activateLogic = activateLogic
            self.currentInputSource = currentInputSource
        }

        static let production = Runtime(
            isLogicProRunning: { ProcessUtils.isLogicProRunning },
            logicProPID: { ProcessUtils.logicProPID() },
            postKeyEvent: { keyCode, flags, pid in
                performKeyEvent(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { usleep($0) },
            isLogicFrontmost: ProcessUtils.Runtime.production.logicIsFrontmost,
            activateLogic: ProcessUtils.Runtime.production.activateLogicPro,
            currentInputSource: { CGEventChannel.readCurrentInputSource() }
        )
    }

    /// TIS's current keyboard input source: its id and `kTISPropertyInputSourceIsASCIICapable`.
    /// nil when the source or that property does not read. Measured 2026-09-28 on macOS 26.3: the
    /// same values read on the main thread, a detached thread and a detached task (2-Set Korean,
    /// false), so the channel's actor can call it.
    static func readCurrentInputSource() -> InputSourceReading? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let rawCapable = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return nil
        }
        let capable = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(rawCapable).takeUnretainedValue())
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        return InputSourceReading(id: id, isASCIICapable: capable)
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

        static func control(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskControl)
        }

        /// A numeric-keypad key. Logic binds keypad keys apart from the main row, and hardware
        /// sets this flag on them.
        static func keypad(_ code: CGKeyCode) -> Shortcut {
            Shortcut(keyCode: code, flags: .maskNumericPad)
        }

        /// The 26 letter keys (HIToolbox `kVK_ANSI_A` ... `kVK_ANSI_Z`).
        static let letterKeyCodes: Set<CGKeyCode> = Set([
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
            kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
            kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
            kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        ].map { CGKeyCode($0) })

        /// A letter key with no Command, Control or Option: the key an input method turns into its
        /// own character. Shift does not stop it (Shift-Q is ㅃ under 2-Set Korean).
        var isPlainLetter: Bool {
            Self.letterKeyCodes.contains(keyCode)
                && flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        }
    }

    /// Mapping from operation strings to keyboard shortcuts.
    ///
    /// Each entry is the keystroke Apple's Logic Pro User Guide lists as the U.S. default preset's
    /// binding for the function the op performs, and nothing else (#1029). The op -> function join,
    /// the pinned tables and the key-name -> keycode table live in
    /// `Scripts/check-cgevent-keystrokes-are-apples.py`, which refuses any other value. Keycodes
    /// are physical key positions on a U.S. ANSI keyboard (HIToolbox `kVK_*`).
    ///
    /// A posted key still carries the character the active input source gives it. Measured
    /// 2026-09-27 on a Korean Logic with the 2-Set Korean input method active: Q, N and X ran
    /// nothing, while Control-B, Option-Command-W, Command-Z, Space, comma, period and the keypad
    /// keys ran their commands. Under the ABC layout Q, N and X ran theirs too. #1039 reports the
    /// other plain letters here (R, C, K, P, Y, A, Z) dead the same way. Setting the event's Unicode
    /// string to the Latin letter did not help (measured 2026-09-28, Q, N and X, two focus
    /// placements), so `execute` refuses every plain letter under a source that is not
    /// ASCII-capable (`Shortcut.isPlainLetter`, `inputSourceRefusal`) and posts nothing.
    ///
    /// An op whose function has no default binding carries NO entry: a keystroke bound to some
    /// other command changes the wrong state and reports that it was sent, which is worse than the
    /// honest "No keyboard shortcut mapped". That is why edit.delete, view.toggle_inspector,
    /// view.toggle_step_editor and track.create_drummer are absent. project.new, project.save_as
    /// and nav.create_marker are absent because no routing chain reaches this channel for them.
    ///
    /// Internal (not private) so the routing-audit invariant test in
    /// `RoutingAuditInvariantTests` can cross-check this table against
    /// `ChannelRouter.routingTable` and `MIDIKeyCommandsChannel.mappingTable`.
    static let keyMap: [String: Shortcut] = [
        // Transport
        "transport.play":             .keypad(76),      // Play: keypad Enter
        "transport.stop":             .keypad(82),      // Stop: keypad 0
        "transport.record":           .key(15),         // Record: R
        "transport.pause":            .keypad(65),      // Pause: keypad Period
        "transport.resume":           .keypad(76),      // Play: keypad Enter, sent only when paused
        "transport.rewind":           .key(43),         // Rewind: Comma
        "transport.fast_forward":     .key(47),         // Forward: Period
        "transport.toggle_cycle":     .key(8),          // Toggle Cycle Mode: C
        "transport.toggle_metronome": .key(40),         // Toggle Metronome Click: K
        "transport.goto_position":    .key(44),         // Go to Position: Slash

        // Editing
        "edit.undo":                  .cmd(6),          // Undo: Command-Z
        "edit.redo":                  .cmdShift(6),     // Redo: Shift-Command-Z
        "edit.cut":                   .cmd(7),          // Cut: Command-X
        "edit.copy":                  .cmd(8),          // Copy: Command-C
        "edit.paste":                 .cmd(9),          // Paste: Command-V
        "edit.select_all":            .cmd(0),          // Select All: Command-A
        "edit.split":                 .cmd(17),         // Split Regions/Events at Playhead Position: Command-T
        "edit.join":                  .cmd(38),         // Join Regions/Notes: Command-J
        "edit.quantize":              .key(12),         // Quantize Selected Regions/Cells/Events: Q
        "edit.bounce_in_place":       .control(11),     // Bounce Regions/Cells in Place: Control-B

        // Views
        "view.toggle_mixer":          .key(7),          // Show/Hide Mixer: X
        "view.toggle_piano_roll":     .key(35),         // Show/Hide Piano Roll: P
        "view.toggle_library":        .key(16),         // Show/Hide Library: Y
        "view.toggle_score_editor":   .key(45),         // Show/Hide Score Editor: N

        // Project
        "project.save":               .cmd(1),          // Save: Command-S
        "project.close":              .cmdOption(13),   // Close Project: Option-Command-W

        // Tracks
        "track.create_audio":         .cmdOption(0),    // New Audio Track: Option-Command-A
        "track.create_instrument":    .cmdOption(1),    // New Software Instrument Track: Option-Command-S
        "track.duplicate":            .cmd(2),          // New Track with Duplicate Settings: Command-D
        "track.delete":               .cmd(51),         // Delete Track: Command-Delete

        // Navigation
        "nav.zoom_to_fit":            .key(6),          // Toggle Zoom to Fit Selection or All Contents: Z

        // Automation
        "automation.toggle_view":     .key(0),          // Show/Hide Automation: A
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

        // #1029 review R-03 and #1039: under an input source that is not ASCII-capable, a plain
        // letter reaches Logic as that source's character and runs nothing, and the State B below
        // would report a keystroke that did nothing. A source that does not read is refused the
        // same way: unread is not ASCII-capable, and the source it failed to read may be 2-Set
        // Korean (round 2, R-03).
        // Read after Logic is brought forward, immediately before the post (round 3, R-03): with
        // macOS's "Automatically switch to a document's input source", activation can restore
        // Logic's own source, so a reading taken before it can say ABC for a key that then reaches
        // Logic under 2-Set Korean. The same setting can turn 2-Set Korean into ABC on activation,
        // so no earlier reading refuses either. The cost: a refused key may have brought Logic
        // forward, and nothing is posted.
        if shortcut.isPlainLetter {
            guard let source = runtime.currentInputSource() else {
                return Self.inputSourceRefusal(operation: operation, source: nil)
            }
            if !source.isASCIICapable {
                return Self.inputSourceRefusal(operation: operation, source: source)
            }
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
        // The opener is read from keyMap so the one keystroke here that is a key command is the
        // one the guard compares with Apple's row. The digits and Return type into the dialog.
        guard let openDialog = keyMap["transport.goto_position"] else { return nil }
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

    /// State C for a plain letter under an input source that is not ASCII-capable, or that did not
    /// read (`source` nil). Not terminal, so the router tries the next rung, and when there is none
    /// the caller gets this refusal rather than a send-only success for a key that could not act.
    static func inputSourceRefusal(operation: String, source: InputSourceReading?) -> ChannelResult {
        var extras: [String: Any] = [
            "operation": operation,
            "method": "cgevent",
            "reason": source == nil ? "input_source_unreadable" : "input_source_blocks_plain_letters",
            "events_posted": 0,
            "write_attempted": false,
            "safe_to_retry": true,
        ]
        if let id = source?.id {
            extras["input_source_id"] = id
        }
        let hint: String
        if let source {
            hint = "The active input source (\(source.id ?? "unnamed")) is not ASCII-capable, so a plain "
                + "letter key reaches Logic as that source's character and runs no key command "
                + "(measured under 2-Set Korean: Q, N and X ran nothing). No event was posted. Switch "
                + "to an ASCII-capable input source such as ABC and retry."
        } else {
            hint = "The active input source did not read, so whether a plain letter key would reach "
                + "Logic as a letter is unknown (under 2-Set Korean, Q, N and X ran nothing). No event "
                + "was posted. Retry, or select an ASCII-capable input source such as ABC."
        }
        return .error(HonestContract.encodeStateC(error: .notSupported, hint: hint, extras: extras))
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
