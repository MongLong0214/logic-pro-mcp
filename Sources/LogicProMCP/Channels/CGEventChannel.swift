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
        /// read. A plain letter is refused under nil, and under a non-ASCII source it is posted
        /// only through a verified switch, so the default is an ASCII-capable source with no id:
        /// the permissive one, for the same reason as the two #440 defaults below. `.production`
        /// reads TIS.
        let currentInputSource: @Sendable () -> InputSourceReading?
        /// #1039: the id of the ASCII-capable keyboard layout TIS offers
        /// (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`), or nil when there is none or
        /// its id does not read. The default is nil: a runtime that says nothing about layouts
        /// cannot switch, and a plain letter under a non-ASCII source is refused as before.
        let asciiCapableLayoutID: @Sendable () -> String?
        /// #1039: select the enabled input source with this id (`TISSelectInputSource`); true when
        /// TIS returned noErr. That return is not taken as the switch: the channel reads
        /// `currentInputSource` again. The default selects nothing.
        let selectInputSource: @Sendable (String) -> Bool
        /// #1039 review R1: the character the keyboard layout with this id types for this key with
        /// no modifier (`UCKeyTranslate` over its `kTISPropertyUnicodeKeyLayoutData`), or nil when
        /// it does not read. The default reads nothing: a runtime that says nothing about what a
        /// layout types cannot switch, and the plain letter is refused.
        let layoutLetter: @Sendable (String, CGKeyCode) -> String?
        /// #1039 review R2: whether the input source with this id is enabled, the only kind
        /// `selectInputSource` can select. The default says no.
        let layoutIsEnabled: @Sendable (String) -> Bool
        /// #1039: the wait after a switched layout reads back as current, before the key, and
        /// again after the key, before the user's source is selected back
        /// (`inputSourceSwitchSettleMicros`).
        let inputSourceSettleMicros: useconds_t
        /// #1038: the window server's on-screen list, the one `AXLogicProElements.Runtime`
        /// `.onScreenWindowList` reads for the AX route's post-leaf settlement; nil when it did not
        /// come back. goto_position types nothing until this list shows the Go To Position dialog,
        /// so the default is nil: a runtime that says nothing about the screen gets a refusal, not
        /// a dialog nobody saw. `.production` reads CoreGraphics.
        let onScreenWindowList: @Sendable () -> [[String: Any]]?
        /// #942: the process the accessibility server names as the focused application, read with
        /// the window list so an application with no window on screen is not missed as the
        /// keyboard's owner (`LogicOnScreenWindows.keyboardOwnerIsLogic`). nil is unread, which
        /// leaves the window reading to answer alone, so the default changes nothing for a runtime
        /// that does not set it. `.production` asks the system-wide AX element.
        let focusedApplicationPID: @Sendable () -> pid_t?

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
            },
            asciiCapableLayoutID: @escaping @Sendable () -> String? = { nil },
            selectInputSource: @escaping @Sendable (String) -> Bool = { _ in false },
            layoutLetter: @escaping @Sendable (String, CGKeyCode) -> String? = { _, _ in nil },
            layoutIsEnabled: @escaping @Sendable (String) -> Bool = { _ in false },
            inputSourceSettleMicros: useconds_t = CGEventChannel.inputSourceSwitchSettleMicros,
            onScreenWindowList: @escaping @Sendable () -> [[String: Any]]? = { nil },
            focusedApplicationPID: @escaping @Sendable () -> pid_t? = { nil }
        ) {
            self.isLogicProRunning = isLogicProRunning
            self.logicProPID = logicProPID
            self.postKeyEvent = postKeyEvent
            self.sleepMicros = sleepMicros
            self.isLogicFrontmost = isLogicFrontmost
            self.activateLogic = activateLogic
            self.currentInputSource = currentInputSource
            self.asciiCapableLayoutID = asciiCapableLayoutID
            self.selectInputSource = selectInputSource
            self.layoutLetter = layoutLetter
            self.layoutIsEnabled = layoutIsEnabled
            self.inputSourceSettleMicros = inputSourceSettleMicros
            self.onScreenWindowList = onScreenWindowList
            self.focusedApplicationPID = focusedApplicationPID
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
            currentInputSource: { CGEventChannel.readCurrentInputSource() },
            asciiCapableLayoutID: { CGEventChannel.readASCIICapableLayoutID() },
            selectInputSource: { CGEventChannel.selectEnabledInputSource(id: $0) },
            layoutLetter: { CGEventChannel.readLayoutLetter(layoutID: $0, keyCode: $1) },
            layoutIsEnabled: { CGEventChannel.isEnabledInputSource(id: $0) },
            onScreenWindowList: AXLogicProElements.Runtime.liveOnScreenWindowList,
            focusedApplicationPID: { ProcessUtils.focusedApplicationPID() }
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

    /// #1039: the id of the keyboard layout TIS gives for ASCII typing under the current source
    /// (for 2-Set Korean, the layout its Latin mode types through). nil when TIS returns none or
    /// its id does not read. No other layout is guessed at.
    static func readASCIICapableLayoutID() -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// #1039: `TISSelectInputSource` on the enabled source whose id is `id`. False when no enabled
    /// source has that id or TIS returns an error. Called off the main thread from the channel's
    /// actor, where `readCurrentInputSource` was measured to read; whether a selection made here
    /// reaches the keys Logic receives is the live check's to show.
    static func selectEnabledInputSource(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue(),
              CFArrayGetCount(list) > 0,
              let raw = CFArrayGetValueAtIndex(list, 0) else {
            return false
        }
        let source = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
        return TISSelectInputSource(source) == noErr
    }

    /// #1039 review R1: the character the installed keyboard layout `layoutID` types for `keyCode`
    /// with no modifier, read from the layout's own key map. nil when no installed source has that
    /// id, it carries no Unicode key layout, or the translation produces nothing.
    static func readLayoutLetter(layoutID: String, keyCode: CGKeyCode) -> String? {
        let filter = [kTISPropertyInputSourceID as String: layoutID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue(),
              CFArrayGetCount(list) > 0,
              let raw = CFArrayGetValueAtIndex(list, 0) else {
            return nil
        }
        let source = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
        guard let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// #1039 review R2: whether an enabled input source has this id. A disabled layout still reads
    /// its key map (`readLayoutLetter` reads installed ones) but cannot be selected.
    static func isEnabledInputSource(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return false }
        return CFArrayGetCount(list) > 0
    }

    /// #1039 review R1: layouts that type the U.S. letter on every letter key, tried when TIS's
    /// ASCII-capable layout types another (Dvorak, AZERTY). Each is still checked key by key.
    static let usLetterLayoutIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]

    /// #1039: how long a switched layout is given to reach Logic before the key, and the key to be
    /// read by Logic before the user's source goes back. The read-back is this process's view; it
    /// does not show when Logic sees the selection, or that Logic has read a posted key. Not
    /// measured: the live check of #1039 is to set it.
    static let inputSourceSwitchSettleMicros: useconds_t = 100_000

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

        /// The 26 letter keys (HIToolbox `kVK_ANSI_A` ... `kVK_ANSI_Z`) and the letter each types
        /// on a U.S. layout, which is the letter the key map means (#1039 review R1).
        static let usLetters: [CGKeyCode: String] = ([
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
            kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
            kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
            kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
            kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
            kVK_ANSI_Z: "z",
        ] as [Int: String]).reduce(into: [CGKeyCode: String]()) { $0[CGKeyCode($1.key)] = $1.value }
        static let letterKeyCodes = Set(usLetters.keys)

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
    /// placements), so under a source that is not ASCII-capable `execute` posts a plain letter
    /// (`Shortcut.isPlainLetter`) only after selecting TIS's ASCII-capable layout and reading it
    /// back as current, then selects the user's source again (`switchToASCIICapableLayout`). When
    /// the switch cannot be made or read back it refuses and posts nothing (`inputSourceRefusal`).
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
        // edit.quantize posts nothing: its `value` names a grid, and Apple's Q (Quantize Selected
        // Regions/Cells/Events) applies whatever quantize value Logic holds, which no key can set.
        // Measured 2026-10-03: Q changed the region's quantize parameter on one press in German
        // and on no press after an undo, in either selection mode (#1029).
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
            // #1038: the opener alone goes out first. Every character after it types into
            // whatever has the keyboard, so none is posted until the window server shows the
            // Go To Position dialog on screen.
            let dialogObservation: [String: Any]
            switch openGotoPositionDialog(opener: sequence[0], pid: pid) {
            case .openerNotPosted:
                return .error("Failed to post CGEvent sequence for \(operation)")
            case let .refused(reason, openerPosted, reading):
                return Self.gotoDialogRefusal(
                    position: position, preparation: preparation, reason: reason,
                    openerPosted: openerPosted, reading: reading
                )
            case let .open(polls, reading):
                dialogObservation = ["polls": polls, "read": reading]
            }
            let sent = postShortcutSequence(Array(sequence.dropFirst()), pid: pid)
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
                        "dialog_observation": dialogObservation,
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
        // #1039: a non-ASCII source no longer refuses outright. The key goes out between a
        // verified switch to TIS's ASCII-capable layout and the user's source selected back.
        var switched: (originalID: String, layoutID: String)?
        if shortcut.isPlainLetter {
            guard let source = runtime.currentInputSource() else {
                return Self.inputSourceRefusal(operation: operation, source: nil)
            }
            if !source.isASCIICapable {
                switch switchToASCIICapableLayout(from: source, keyCode: shortcut.keyCode) {
                case let .refused(failure, restore):
                    return Self.inputSourceRefusal(
                        operation: operation, source: source, switchFailure: failure, restore: restore
                    )
                case let .switched(originalID, layoutID):
                    switched = (originalID, layoutID)
                    runtime.sleepMicros(runtime.inputSourceSettleMicros)
                }
            }
        }

        let sent = runtime.postKeyEvent(shortcut.keyCode, shortcut.flags, pid)
        var restore: InputSourceRestore?
        if let switched {
            if sent {
                runtime.sleepMicros(runtime.inputSourceSettleMicros)
            }
            restore = restoreInputSource(switched.originalID)
        }
        if sent {
            // v3.1.1 (P2-2) — same rationale as above. Single key chord
            // delivered; no read-back possible from this channel.
            var extras: [String: Any] = [
                "operation": operation,
                "method": "cgevent",
                "frontmost_preparation": preparation.rawValue,
                "sent": true
            ]
            if let switched, let restore {
                extras.merge(Self.switchedExtras(
                    originalID: switched.originalID, layoutID: switched.layoutID, restore: restore
                )) { _, new in new }
            } else if shortcut.isPlainLetter {
                // Read as ASCII-capable just above: posted with no switch.
                extras["input_source_switched"] = false
            }
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        } else {
            var message = "Failed to post CGEvent for \(operation)"
            if let switched, let restore {
                message += restore.restored
                    ? ". The input source was switched to \(switched.layoutID) for the key and reads "
                        + "\(switched.originalID) again."
                    : ". The input source was switched to \(switched.layoutID) for the key and could not "
                        + "be selected back: it reads \(restore.after?.id ?? "unreadable"), not "
                        + "\(switched.originalID). Select \(switched.originalID) again."
            }
            return .error(message)
        }
    }

    // MARK: - #1039 input-source switch

    /// What selecting TIS's ASCII-capable layout for one plain letter came to.
    enum InputSourceSwitch {
        /// `layoutID` read back as the current, ASCII-capable source after it was selected.
        case switched(originalID: String, layoutID: String)
        /// Nothing may be posted. `failure` names the step that stopped it; `restore` is the
        /// reading after the user's source was put back, nil when nothing had been selected.
        case refused(failure: String, restore: InputSourceRestore?)
    }

    /// The input source as read after a switch was undone.
    struct InputSourceRestore {
        /// The reading after the user's source was selected back; nil when it did not read.
        let after: InputSourceReading?
        /// The user's source id, which `after` must name.
        let originalID: String

        /// The source reads as the one the user had. Decided by the reading, not by what
        /// `TISSelectInputSource` returned.
        var restored: Bool { after?.id == originalID }
    }

    /// #1039: select the ASCII-capable layout for a plain letter whose current source is not
    /// ASCII-capable, and read it back as the current source before anything is posted.
    ///
    /// A source whose id did not read is not switched away from: nothing could select it back.
    /// When the selection does not read back, the user's source is put back (unless the reading
    /// already names it) and the switch is refused.
    ///
    /// Review R1: ASCII-capable does not mean the key types the letter the key map means. TIS can
    /// name Dvorak or AZERTY, where the key for R types P or another letter, and with key-label
    /// assignments that is another command. So the layout must type the U.S. letter on this key,
    /// read from its key map before anything is selected; when TIS's does not, ABC or U.S. is
    /// tried, and when none does, nothing is selected or posted. Review R2: a candidate must also be
    /// enabled, since only an enabled source can be selected; a disabled ABC is passed over for an
    /// enabled U.S.
    func switchToASCIICapableLayout(from source: InputSourceReading, keyCode: CGKeyCode) -> InputSourceSwitch {
        guard let originalID = source.id else {
            return .refused(failure: "source_id_unreadable", restore: nil)
        }
        guard let offered = runtime.asciiCapableLayoutID() else {
            return .refused(failure: "no_ascii_capable_layout", restore: nil)
        }
        let candidates = [offered] + Self.usLetterLayoutIDs.filter { $0 != offered }
        guard let letter = Shortcut.usLetters[keyCode],
              let layoutID = candidates.first(where: {
                  runtime.layoutIsEnabled($0) && runtime.layoutLetter($0, keyCode) == letter
              }) else {
            return .refused(failure: "layout_types_another_letter", restore: nil)
        }
        let selected = runtime.selectInputSource(layoutID)
        let reading = runtime.currentInputSource()
        if selected, let reading, reading.id == layoutID, reading.isASCIICapable {
            return .switched(originalID: originalID, layoutID: layoutID)
        }
        let restore = reading?.id == originalID
            ? InputSourceRestore(after: reading, originalID: originalID)
            : restoreInputSource(originalID)
        return .refused(failure: selected ? "switch_not_verified" : "select_failed", restore: restore)
    }

    /// #1039: select the user's source again and read whether it is current.
    func restoreInputSource(_ originalID: String) -> InputSourceRestore {
        _ = runtime.selectInputSource(originalID)
        return InputSourceRestore(after: runtime.currentInputSource(), originalID: originalID)
    }

    /// The reply fields of a plain letter posted through a switch. A source left on the layout is
    /// named in a hint as well as in `input_source_restored`, so the reply cannot read as clean.
    static func switchedExtras(originalID: String, layoutID: String, restore: InputSourceRestore) -> [String: Any] {
        var extras: [String: Any] = [
            "input_source_switched": true,
            "input_source_before": originalID,
            "input_source_switched_to": layoutID,
            "input_source_restored": restore.restored,
            "input_source_after": restore.after?.id as Any? ?? NSNull(),
        ]
        if !restore.restored {
            extras["hint"] = "The key went out under \(layoutID), selected in place of \(originalID) "
                + "because \(originalID) is not ASCII-capable. Selecting \(originalID) again did not read "
                + "back: the input source reads \(restore.after?.id ?? "unreadable"). Select \(originalID) again."
        }
        return extras
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

    /// State C for a plain letter under an input source that is not ASCII-capable and could not be
    /// switched away from for the key (`switchFailure`), or that did not read (`source` nil). Not
    /// terminal, so the router tries the next rung, and when there is none the caller gets this
    /// refusal rather than a send-only success for a key that could not act. `restore` is the
    /// reading after a selection that did not read back was undone.
    static func inputSourceRefusal(
        operation: String,
        source: InputSourceReading?,
        switchFailure: String? = nil,
        restore: InputSourceRestore? = nil
    ) -> ChannelResult {
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
        if let switchFailure {
            extras["input_source_switched"] = false
            extras["input_source_switch_failure"] = switchFailure
        }
        if let restore {
            extras["input_source_restored"] = restore.restored
            extras["input_source_after"] = restore.after?.id as Any? ?? NSNull()
        }
        let hint: String
        if let source {
            let name = source.id ?? "unnamed"
            let why: String
            switch switchFailure {
            case "source_id_unreadable":
                why = " Its id did not read, so it could not have been selected back after the key, and "
                    + "no ASCII-capable layout was selected."
            case "no_ascii_capable_layout":
                why = " TIS named no ASCII-capable keyboard layout to select for the key."
            case "layout_types_another_letter":
                why = " Neither TIS's ASCII-capable layout nor an enabled ABC or U.S. reads as typing "
                    + "this key's letter, so the key could run another command; no layout was selected."
            case let failure?:
                why = " Selecting TIS's ASCII-capable layout for the key did not read back as the current "
                    + "source (\(failure))."
            case nil:
                why = ""
            }
            var restored = ""
            if let restore {
                restored = restore.restored
                    ? " The input source reads \(restore.originalID) again."
                    : " Selecting \(restore.originalID) back did not read back either: the input source reads "
                        + "\(restore.after?.id ?? "unreadable"). Select \(restore.originalID) again."
            }
            hint = "The active input source (\(name)) is not ASCII-capable, so a plain letter key reaches "
                + "Logic as that source's character and runs no key command (measured under 2-Set "
                + "Korean: Q, N and X ran nothing).\(why) No event was posted.\(restored) Switch to an "
                + "ASCII-capable input source such as ABC and retry."
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

    // MARK: - #1038 Go To Position dialog gate

    /// How long the dialog is given to appear after the opener: the AppleScript route's bound,
    /// 30 reads 0.1 s apart.
    static let gotoDialogObservationPolls = 30
    static let gotoDialogObservationPollMicros: useconds_t = 100_000

    enum GotoDialogGate {
        /// The dialog was read on screen, alone, with no Logic menu up and Logic owning the
        /// keyboard. `polls` is how many waits it took; `reading` is the reading that said so.
        case open(polls: Int, reading: [String: Any])
        /// Nothing may be typed. `reading` is the last window-list reading, nil when none was taken.
        case refused(reason: String, openerPosted: Bool, reading: [String: Any]?)
        /// The opener's own post failed.
        case openerNotPosted
    }

    /// Posts the opener and reads the window server until the Go To Position dialog is on screen.
    ///
    /// The reading is the AX route's own (`AccessibilityChannel.readPostLeafScreen`): the
    /// Logic-owned windows that were not on screen before the opener, the popup-menu layer apart,
    /// and the dialog named ours only when exactly one appeared and its title is a
    /// `goToPositionDialogTitle` under `.exactStrict`. The list is read before the opener, so a
    /// list that does not come back refuses with nothing posted. A window that appeared and is not
    /// that dialog refuses at once, as the AppleScript route does; a dialog that does not appear
    /// within the bound refuses when it runs out.
    func openGotoPositionDialog(opener: Shortcut, pid: pid_t) -> GotoDialogGate {
        guard let before = runtime.onScreenWindowList() else {
            return .refused(reason: "window_list_unreadable", openerPosted: false, reading: nil)
        }
        let baseline = Set(LogicOnScreenWindows.logicOwned(before, logicPID: pid).map(\.number))
        guard runtime.postKeyEvent(opener.keyCode, opener.flags, pid) else {
            return .openerNotPosted
        }
        var polls = 0
        while true {
            let (reading, appeared) = AccessibilityChannel.readPostLeafScreen(
                baseline: baseline, logicPID: pid, windows: runtime.onScreenWindowList(),
                focusedApplicationPID: runtime.focusedApplicationPID()
            )
            let fields = AccessibilityChannel.PostLeafSettlement.readingFields(reading, appeared: appeared)
            if reading.dialog == .identifiedOurs, reading.menu == .closed, reading.logicOwnsKeyboard == true {
                return .open(polls: polls, reading: fields)
            }
            if reading.menu == .unreadable || reading.dialog == .unreadable {
                return .refused(reason: "window_list_unreadable", openerPosted: true, reading: fields)
            }
            if case .unidentified = reading.dialog {
                return .refused(reason: "unidentified_window_appeared", openerPosted: true, reading: fields)
            }
            guard polls < Self.gotoDialogObservationPolls else {
                // Ours on screen but a Logic menu above it, or the keyboard not read as Logic's:
                // a character typed now goes to the menu or to another process, not the field.
                let reason = reading.dialog == .identifiedOurs ? "dialog_not_typable" : "dialog_not_observed"
                return .refused(reason: reason, openerPosted: true, reading: fields)
            }
            runtime.sleepMicros(Self.gotoDialogObservationPollMicros)
            polls += 1
        }
    }

    /// State C for a goto_position whose dialog was not observed. No position character and no
    /// Return was posted, so `write_attempted` is false. When the opener went out, whatever it did
    /// is unknown -- a dialog can still appear after the bound -- so the caller is told to read the
    /// screen before retrying and no other channel may take the operation over.
    static func gotoDialogRefusal(
        position: String,
        preparation: FrontmostPreparation,
        reason: String,
        openerPosted: Bool,
        reading: [String: Any]?
    ) -> ChannelResult {
        let hint = openerPosted
            ? "The Go To Position key was posted, but the dialog was not read on screen (\(reason)), so the "
                + "position and Return were not typed. Whatever the key did is unobserved: read Logic's windows "
                + "before retrying, and close a Go To Position dialog that appeared late."
            : "The window list did not read before the Go To Position key, so a dialog could not have been "
                + "told apart from what was already on screen. Nothing was posted; retry."
        return .error(HonestContract.encodeStateC(
            error: .dialogNotFound,
            hint: hint,
            extras: [
                "operation": "transport.goto_position",
                "method": "cgevent",
                "position": position,
                "frontmost_preparation": preparation.rawValue,
                "reason": reason,
                "events_posted": openerPosted ? 1 : 0,
                "dialog_opener_posted": openerPosted,
                "dialog_observation": reading as Any? ?? NSNull(),
                "write_attempted": false,
                "safe_to_retry": !openerPosted,
                "fallback_unsafe": openerPosted,
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
