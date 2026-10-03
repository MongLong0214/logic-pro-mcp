import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// #1039: under an input source that is not ASCII-capable (2-Set Korean) a plain letter key reaches
// Logic as that source's character and runs nothing. `CGEventChannel` now selects TIS's
// ASCII-capable layout for the key, reads it back as current before posting, waits, posts, waits,
// and selects the user's source again, reading that back too. A switch that does not read back
// posts nothing. These tests drive the channel through a fake TIS that logs every read, selection,
// settle and post in order. Each names the mutation it kills. Nothing here reads a clock or touches
// the machine's input source.

private let koreanID = "com.apple.inputmethod.Korean.2SetKorean"
private let abcID = "com.apple.keylayout.ABC"
private let korean = CGEventChannel.InputSourceReading(id: koreanID, isASCIICapable: false)
private let abc = CGEventChannel.InputSourceReading(id: abcID, isASCIICapable: true)
private let dvorakID = "com.apple.keylayout.Dvorak"
private let dvorak = CGEventChannel.InputSourceReading(id: dvorakID, isASCIICapable: true)
private let usID = "com.apple.keylayout.US"
private let us = CGEventChannel.InputSourceReading(id: usID, isASCIICapable: true)
private let usLetters = CGEventChannel.Shortcut.usLetters
/// What Dvorak types on the U.S. letter keys `keyMap` posts: R types p, and so on. A types a.
private let dvorakLetters: [CGKeyCode: String] = usLetters.merging(
    [15: "p", 8: "j", 40: "t", 12: "'", 7: "q", 35: "l", 16: "f", 6: ";", 1: "o", 31: "r", 45: "b"]
) { _, dvorak in dvorak }
/// Distinct from the frontmost gate's 50 ms polls, so a settle can be told apart in the log.
private let settle: useconds_t = 7_777

/// Every op `keyMap` posts as a letter with no Command, Control or Option.
private let plainLetterOps = [
    "transport.record", "transport.toggle_cycle", "transport.toggle_metronome",
    "view.toggle_mixer", "view.toggle_piano_roll", "view.toggle_library", "view.toggle_score_editor",
    "nav.zoom_to_fit", "automation.toggle_view",
]

/// A TIS whose current source changes only as `outcomes` lets a selection change it.
private final class FakeTIS: @unchecked Sendable {
    enum Selection {
        /// Returns true and the source becomes the one selected.
        case takes
        /// Returns false and nothing changes.
        case refused
        /// Returns true and nothing changes.
        case silent
        /// Returns true and the source stops reading.
        case unreadable
    }

    private let lock = NSLock()
    private var current: CGEventChannel.InputSourceReading?
    private var entries: [String] = []
    private var posted: [(keyCode: CGKeyCode, flags: CGEventFlags)] = []
    private let layoutID: String?
    private let outcomes: [String: Selection]
    private let postSucceeds: Bool
    private let known: [String: CGEventChannel.InputSourceReading] = [
        koreanID: korean, abcID: abc, dvorakID: dvorak, usID: us,
    ]
    private let letters: [String: [CGKeyCode: String]]
    private let enabled: Set<String>

    init(
        current: CGEventChannel.InputSourceReading?,
        layoutID: String? = abcID,
        outcomes: [String: Selection] = [:],
        postSucceeds: Bool = true,
        letters: [String: [CGKeyCode: String]] = [abcID: usLetters],
        enabled: Set<String>? = nil
    ) {
        self.letters = letters
        // A layout whose key map the fake knows is enabled unless the case says otherwise.
        self.enabled = enabled ?? Set(letters.keys)
        self.current = current
        self.layoutID = layoutID
        self.outcomes = outcomes
        self.postSucceeds = postSucceeds
    }

    var log: [String] { locked { entries } }
    var source: CGEventChannel.InputSourceReading? { locked { current } }
    var posts: [(keyCode: CGKeyCode, flags: CGEventFlags)] { locked { posted } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func read() -> CGEventChannel.InputSourceReading? {
        locked {
            entries.append("read:\(current.map { $0.id ?? "unnamed" } ?? "nil")")
            return current
        }
    }

    private func select(_ id: String) -> Bool {
        locked {
            entries.append("select:\(id)")
            switch outcomes[id] ?? .takes {
            case .takes:
                current = known[id]
                return true
            case .refused:
                return false
            case .silent:
                return true
            case .unreadable:
                current = nil
                return true
            }
        }
    }

    func runtime() -> CGEventChannel.Runtime {
        CGEventChannel.Runtime(
            isLogicProRunning: { true },
            logicProPID: { 42 },
            postKeyEvent: { keyCode, flags, _ in
                self.locked {
                    self.entries.append("post:\(keyCode)")
                    if self.postSucceeds { self.posted.append((keyCode, flags)) }
                    return self.postSucceeds
                }
            },
            sleepMicros: { micros in
                if micros == settle { self.locked { self.entries.append("settle") } }
            },
            currentInputSource: { self.read() },
            asciiCapableLayoutID: {
                self.locked {
                    self.entries.append("layout")
                    return self.layoutID
                }
            },
            selectInputSource: { self.select($0) },
            layoutLetter: { id, keyCode in self.letters[id]?[keyCode] },
            layoutIsEnabled: { self.enabled.contains($0) },
            inputSourceSettleMicros: settle
        )
    }
}

private func envelope(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// The ways a switch does not read back, and what each must leave behind.
enum UnverifiedSwitch: String, CaseIterable, Sendable {
    /// TIS refuses the selection; the source still reads 2-Set Korean, so nothing is selected back.
    case selectRefused
    /// TIS says yes and nothing changes.
    case selectSilent
    /// TIS says yes and the source stops reading; 2-Set Korean is selected back.
    case readingLost
    /// TIS names no ASCII-capable layout; nothing is selected.
    case noLayout
    /// 2-Set Korean reads without an id, so it could not be selected back; nothing is selected.
    case sourceUnnamed

    fileprivate var tis: FakeTIS {
        switch self {
        case .selectRefused: FakeTIS(current: korean, outcomes: [abcID: .refused])
        case .selectSilent: FakeTIS(current: korean, outcomes: [abcID: .silent])
        case .readingLost: FakeTIS(current: korean, outcomes: [abcID: .unreadable])
        case .noLayout: FakeTIS(current: korean, layoutID: nil)
        case .sourceUnnamed: FakeTIS(current: CGEventChannel.InputSourceReading(id: nil, isASCIICapable: false))
        }
    }

    var failure: String {
        switch self {
        case .selectRefused: "select_failed"
        case .selectSilent, .readingLost: "switch_not_verified"
        case .noLayout: "no_ascii_capable_layout"
        case .sourceUnnamed: "source_id_unreadable"
        }
    }

    /// The log after the first read, up to the refusal.
    var logAfterFirstRead: [String] {
        switch self {
        case .selectRefused: ["layout", "select:\(abcID)", "read:\(koreanID)"]
        case .selectSilent: ["layout", "select:\(abcID)", "read:\(koreanID)"]
        case .readingLost: ["layout", "select:\(abcID)", "read:nil", "select:\(koreanID)", "read:\(koreanID)"]
        case .noLayout: ["layout"]
        case .sourceUnnamed: []
        }
    }

    /// Whether a selection was made, so the reply must say where the source was left.
    var reportsRestore: Bool {
        switch self {
        case .selectRefused, .selectSilent, .readingLost: true
        case .noLayout, .sourceUnnamed: false
        }
    }
}

/// The ways the user's source does not read back after the key.
enum FailedRestore: String, CaseIterable, Sendable {
    /// TIS refuses 2-Set Korean; the source stays on ABC.
    case refused
    /// TIS says yes and the source stays on ABC.
    case silent
    /// TIS says yes and the source stops reading.
    case unreadable

    fileprivate var selection: FakeTIS.Selection {
        switch self {
        case .refused: .refused
        case .silent: .silent
        case .unreadable: .unreadable
        }
    }

    var after: String? {
        switch self {
        case .refused, .silent: abcID
        case .unreadable: nil
        }
    }
}

@Suite struct Issue1039InputSourceSwitchTests {

    /// (a) Under an ASCII-capable source the key is posted with no layout asked for and nothing
    /// selected, and the reply says no switch was made.
    /// Kills: switching whenever a letter is plain (the `isASCIICapable` test dropped), which logs
    /// a layout read and two selections; and the unswitched reply losing `input_source_switched`.
    @Test("an ASCII-capable source posts the key with no switch", arguments: plainLetterOps)
    func asciiSourcePostsWithNoSwitch(_ operation: String) async throws {
        let tis = FakeTIS(current: abc)
        let channel = CGEventChannel(runtime: tis.runtime())
        let shortcut = try #require(CGEventChannel.keyMap[operation])

        let result = await channel.execute(operation: operation, params: [:])

        #expect(result.isSuccess, "\(operation): \(result.message)")
        #expect(tis.log == ["read:\(abcID)", "post:\(shortcut.keyCode)"], "\(operation): \(tis.log)")
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "B")
        let switched = try #require(object["input_source_switched"] as? Bool)
        #expect(!switched)
        #expect(object["input_source_before"] == nil)
        #expect(object["input_source_restored"] == nil)
    }

    /// (b) Under 2-Set Korean the key is posted once, under ABC, and 2-Set Korean is current again
    /// afterwards. The reply names all three steps.
    /// Kills: the refusal kept for a non-ASCII source (nothing posted, State C); the restore
    /// dropped (the fake is left on ABC); and any of the five reply fields missing or wrong.
    @Test("2-Set Korean switches to ABC, posts once and selects 2-Set Korean back", arguments: plainLetterOps)
    func koreanSourceSwitchesPostsAndRestores(_ operation: String) async throws {
        let tis = FakeTIS(current: korean)
        let channel = CGEventChannel(runtime: tis.runtime())
        let shortcut = try #require(CGEventChannel.keyMap[operation])

        let result = await channel.execute(operation: operation, params: [:])

        #expect(result.isSuccess, "\(operation): \(result.message)")
        #expect(tis.posts.map(\.keyCode) == [shortcut.keyCode], "\(operation): \(tis.log)")
        #expect(tis.posts.first?.flags == shortcut.flags)
        #expect(tis.source == korean, "\(operation) left the source at \(String(describing: tis.source))")
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "B")
        let sent = try #require(object["sent"] as? Bool)
        #expect(sent)
        let switched = try #require(object["input_source_switched"] as? Bool)
        #expect(switched)
        #expect(object["input_source_before"] as? String == koreanID)
        #expect(object["input_source_switched_to"] as? String == abcID)
        let restored = try #require(object["input_source_restored"] as? Bool)
        #expect(restored)
        #expect(object["input_source_after"] as? String == koreanID)
        #expect(object["hint"] == nil)
    }

    /// (c) A switch that does not read back posts nothing and refuses with the 2-Set Korean
    /// reason, naming the step that stopped it. Where a selection was made, the user's source is
    /// put back and the reply says where it was left.
    /// Kills: posting on TIS's return alone (`selected` without the re-read), posting when the
    /// re-read names another source or none, switching away from a source with no id, and a
    /// refusal that leaves the source on whatever the failed selection did.
    /// Review R1 of #1085 (R-1039-01): TIS offers Dvorak, where most of these keys type another
    /// letter, so the key for R would reach Logic as P. ABC types the U.S. letter and is selected
    /// in its place; for A, which Dvorak also types as a, Dvorak is kept. Kills: the layout taken
    /// on its ASCII capability alone (Dvorak is selected for every key).
    @Test("a layout that types another letter on the key is passed over for ABC", arguments: plainLetterOps)
    func aLayoutTypingAnotherLetterIsPassedOver(_ operation: String) async throws {
        let tis = FakeTIS(current: korean, layoutID: dvorakID, letters: [dvorakID: dvorakLetters, abcID: usLetters])
        let channel = CGEventChannel(runtime: tis.runtime())
        let shortcut = try #require(CGEventChannel.keyMap[operation])
        let letter = try #require(usLetters[shortcut.keyCode])
        let expected = dvorakLetters[shortcut.keyCode] == letter ? dvorakID : abcID

        let result = await channel.execute(operation: operation, params: [:])

        #expect(result.isSuccess, "\(operation): \(result.message)")
        #expect(tis.log.filter { $0.hasPrefix("select:") } == ["select:\(expected)", "select:\(koreanID)"],
                "\(operation): \(tis.log)")
        #expect(tis.posts.map(\.keyCode) == [shortcut.keyCode])
        let object = try #require(envelope(result.message))
        #expect(object["input_source_switched_to"] as? String == expected)
    }

    /// Review R2 of #1085 (R-1039-04): ABC is installed, so its key map reads, but disabled, and
    /// U.S. is enabled. A disabled layout cannot be selected, so the key must go out under U.S.
    /// (or Dvorak, for a key it types as the letter). Kills: a candidate taken without asking
    /// whether it is enabled (ABC is selected, the selection fails and nothing is posted).
    @Test("a disabled ABC is passed over for an enabled U.S.", arguments: plainLetterOps)
    func aDisabledABCIsPassedOverForUS(_ operation: String) async throws {
        let tis = FakeTIS(
            current: korean, layoutID: dvorakID,
            letters: [dvorakID: dvorakLetters, abcID: usLetters, usID: usLetters],
            enabled: [dvorakID, usID]
        )
        let channel = CGEventChannel(runtime: tis.runtime())
        let shortcut = try #require(CGEventChannel.keyMap[operation])
        let letter = try #require(usLetters[shortcut.keyCode])
        let expected = dvorakLetters[shortcut.keyCode] == letter ? dvorakID : usID

        let result = await channel.execute(operation: operation, params: [:])

        #expect(result.isSuccess, "\(operation): \(result.message)")
        #expect(tis.log.filter { $0.hasPrefix("select:") } == ["select:\(expected)", "select:\(koreanID)"],
                "\(operation): \(tis.log)")
        #expect(tis.posts.map(\.keyCode) == [shortcut.keyCode])
    }

    /// With ABC and U.S. both installed but disabled, no enabled candidate types the letter: the
    /// key is refused and nothing is selected. Kills: the enabled check applied to ABC alone.
    @Test("no enabled layout typing the key's letter refuses the key", arguments: plainLetterOps)
    func noEnabledLayoutTypingTheLetterRefuses(_ operation: String) async throws {
        let tis = FakeTIS(
            current: korean, layoutID: dvorakID,
            letters: [dvorakID: dvorakLetters, abcID: usLetters, usID: usLetters],
            enabled: [dvorakID]
        )
        let channel = CGEventChannel(runtime: tis.runtime())
        let shortcut = try #require(CGEventChannel.keyMap[operation])
        let letter = try #require(usLetters[shortcut.keyCode])
        // A types a under Dvorak, which is enabled, so it goes out; the case is the others.
        guard dvorakLetters[shortcut.keyCode] != letter else { return }

        let result = await channel.execute(operation: operation, params: [:])

        #expect(!result.isSuccess, "\(operation): \(result.message)")
        #expect(tis.posts.isEmpty)
        #expect(!tis.log.contains { $0.hasPrefix("select:") }, "\(operation): \(tis.log)")
        let object = try #require(envelope(result.message))
        #expect(object["input_source_switch_failure"] as? String == "layout_types_another_letter")
    }

    /// When neither TIS's layout nor ABC or U.S. reads as typing the key's letter, nothing is
    /// selected or posted. Kills: falling back to TIS's layout when no candidate types the letter.
    @Test("no layout typing the key's letter refuses the key", arguments: plainLetterOps)
    func noLayoutTypingTheLetterRefuses(_ operation: String) async throws {
        let tis = FakeTIS(current: korean, layoutID: dvorakID, letters: [dvorakID: dvorakLetters])
        let channel = CGEventChannel(runtime: tis.runtime())
        let shortcut = try #require(CGEventChannel.keyMap[operation])
        let letter = try #require(usLetters[shortcut.keyCode])
        // A types a under Dvorak too, so Dvorak is a layout that types it; the case is the others.
        guard dvorakLetters[shortcut.keyCode] != letter else { return }

        let result = await channel.execute(operation: operation, params: [:])

        #expect(!result.isSuccess, "\(operation): \(result.message)")
        #expect(tis.posts.isEmpty)
        #expect(!tis.log.contains { $0.hasPrefix("select:") }, "\(operation): \(tis.log)")
        #expect(tis.source == korean)
        let object = try #require(envelope(result.message))
        #expect(object["input_source_switch_failure"] as? String == "layout_types_another_letter")
    }

    @Test("a switch that does not read back posts nothing", arguments: UnverifiedSwitch.allCases)
    func unverifiedSwitchPostsNothing(_ scenario: UnverifiedSwitch) async throws {
        let tis = scenario.tis
        let originalID = tis.source?.id
        let channel = CGEventChannel(runtime: tis.runtime())

        let result = await channel.execute(operation: "transport.record", params: [:])

        #expect(!result.isSuccess, "\(scenario): \(result.message)")
        #expect(tis.posts.isEmpty, "\(scenario) posted \(tis.posts.map(\.keyCode))")
        #expect(!tis.log.contains { $0.hasPrefix("post:") }, "\(scenario): \(tis.log)")
        #expect(Array(tis.log.dropFirst()) == scenario.logAfterFirstRead, "\(scenario): \(tis.log)")
        #expect(tis.source?.id == originalID, "\(scenario) left the source at \(String(describing: tis.source))")
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "C")
        #expect(object["error"] as? String == "not_supported")
        #expect(object["reason"] as? String == "input_source_blocks_plain_letters")
        #expect(object["events_posted"] as? Int == 0)
        let writeAttempted = try #require(object["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        let switched = try #require(object["input_source_switched"] as? Bool)
        #expect(!switched)
        #expect(object["input_source_switch_failure"] as? String == scenario.failure)
        if scenario.reportsRestore {
            let restored = try #require(object["input_source_restored"] as? Bool, "\(scenario): \(object)")
            #expect(restored)
            #expect(object["input_source_after"] as? String == koreanID)
        } else {
            #expect(object["input_source_restored"] == nil, "\(scenario): \(object)")
            #expect(!tis.log.contains { $0.hasPrefix("select:") }, "\(scenario): \(tis.log)")
        }
    }

    /// (d) The key went out under ABC and 2-Set Korean did not read back: the reply is still the
    /// send-only State B (the key was posted, so no other rung may press it again), and it says the
    /// source was not restored, where it was left, and in a hint what to select.
    /// Kills: `input_source_restored` taken from TIS's return instead of the reading (the silent
    /// case reports true), a restore that is never read back, and a reply that omits the failure.
    @Test("a restore that does not read back is named in the reply", arguments: FailedRestore.allCases)
    func failedRestoreIsReported(_ scenario: FailedRestore) async throws {
        let tis = FakeTIS(current: korean, outcomes: [koreanID: scenario.selection])
        let channel = CGEventChannel(runtime: tis.runtime())

        let result = await channel.execute(operation: "view.toggle_mixer", params: [:])

        #expect(result.isSuccess, "\(scenario): \(result.message)")
        #expect(tis.posts.map(\.keyCode) == [7], "\(scenario): \(tis.log)")
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "B")
        let switched = try #require(object["input_source_switched"] as? Bool)
        #expect(switched)
        #expect(object["input_source_before"] as? String == koreanID)
        let restored = try #require(object["input_source_restored"] as? Bool)
        #expect(!restored, "\(scenario): \(object)")
        if let after = scenario.after {
            #expect(object["input_source_after"] as? String == after)
        } else {
            #expect(object["input_source_after"] is NSNull, "\(scenario): \(object)")
        }
        let hint = try #require(object["hint"] as? String)
        #expect(hint.contains("Select \(koreanID) again"), "\(hint)")
    }

    /// (e) A source that does not read is refused as before, and no layout is asked for and
    /// nothing is selected: there is no source to put back.
    /// Kills: an unread source treated as a non-ASCII one and switched (mutant `switch-unread`),
    /// which logs a layout read and selections and posts.
    @Test("a source that does not read is refused with no switch", arguments: plainLetterOps)
    func unreadableSourceRefusesWithNoSwitch(_ operation: String) async throws {
        let tis = FakeTIS(current: nil)
        let channel = CGEventChannel(runtime: tis.runtime())

        let result = await channel.execute(operation: operation, params: [:])

        #expect(!result.isSuccess, "\(operation): \(result.message)")
        #expect(tis.log == ["read:nil"], "\(operation): \(tis.log)")
        #expect(tis.posts.isEmpty)
        let object = try #require(envelope(result.message))
        #expect(object["state"] as? String == "C")
        #expect(object["reason"] as? String == "input_source_unreadable")
        #expect(object["events_posted"] as? Int == 0)
        #expect(object["input_source_switched"] == nil)
    }

    /// (f) The order: the switch is read back before the post, the post waits a settle after it,
    /// and the user's source is selected back only after another settle, then read back.
    /// Kills: the post moved ahead of the re-read, either settle dropped, and the restore moved
    /// ahead of the post or of its settle.
    @Test("the switch is verified before the post and undone after it", arguments: plainLetterOps)
    func switchIsVerifiedBeforeThePostAndRestoredAfter(_ operation: String) async throws {
        let tis = FakeTIS(current: korean)
        let channel = CGEventChannel(runtime: tis.runtime())
        let shortcut = try #require(CGEventChannel.keyMap[operation])

        _ = await channel.execute(operation: operation, params: [:])

        #expect(tis.log == [
            "read:\(koreanID)",
            "layout",
            "select:\(abcID)",
            "read:\(abcID)",
            "settle",
            "post:\(shortcut.keyCode)",
            "settle",
            "select:\(koreanID)",
            "read:\(koreanID)",
        ], "\(operation): \(tis.log)")
    }

    /// A post that fails after a switch still selects the user's source back, and the error says so.
    /// Kills: the restore made only when the key was sent.
    @Test func failedPostStillRestores() async throws {
        let tis = FakeTIS(current: korean, postSucceeds: false)
        let channel = CGEventChannel(runtime: tis.runtime())

        let result = await channel.execute(operation: "transport.record", params: [:])

        #expect(!result.isSuccess)
        #expect(result.message.contains("Failed to post CGEvent for transport.record"), "\(result.message)")
        #expect(result.message.contains("reads \(koreanID) again"), "\(result.message)")
        #expect(tis.source == korean)
        #expect(Array(tis.log.suffix(2)) == ["select:\(koreanID)", "read:\(koreanID)"], "\(tis.log)")
        #expect(!tis.log.suffix(3).contains("settle"), "no settle after a key that was not posted: \(tis.log)")
    }

    /// Through the real router: `view.toggle_mixer` with only CGEvent registered, under 2-Set
    /// Korean and a TIS that can switch, posts X once and answers State B with the source restored.
    /// Kills: the refusal kept for a non-ASCII source, which the router returns as the failure.
    @Test func routerPostsThroughTheSwitchWhenCGEventIsTheOnlyRungLeft() async throws {
        let tis = FakeTIS(current: korean)
        let router = ChannelRouter()
        await router.register(CGEventChannel(runtime: tis.runtime()))

        let result = await router.route(operation: "view.toggle_mixer")

        #expect(result.isSuccess, "\(result.message)")
        #expect(tis.posts.map(\.keyCode) == [7])
        #expect(tis.source == korean)
        #expect(result.message.contains("\"input_source_restored\":true"), "\(result.message)")
    }
}
