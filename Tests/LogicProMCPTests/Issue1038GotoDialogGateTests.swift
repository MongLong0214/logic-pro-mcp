import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #1038 — goto_position types nothing until the dialog is on screen
//
// The CGEvent route opens Go To Position with one key and then types the position and Return.
// It used to post all of them in one run, so when the dialog did not open -- a menu up, a sheet,
// another window -- the digits and Return went to whatever had the keyboard. Every case below
// counts real calls into the posting seam: the envelope can be made to look right while
// characters still go out.

/// A window server for goto_position. Before the opener it shows Logic's main window; once the
/// opener has gone through `observing(_:)` it adds whatever `appears` says, after
/// `appearsAfterReads` further reads. The opener's key is taken from the product's own sequence,
/// so the double follows it if the binding moves.
final class GotoDialogScreen: @unchecked Sendable {
    enum Appearance {
        /// A Logic window with this title, at the modal-panel layer the dialog was measured at.
        case window(title: String?)
        case nothing
    }

    static let opener: CGKeyCode = CGEventChannel.gotoPositionSequence(for: "1.1.1.1")![0].keyCode
    static let englishTitle = "Go To Position"

    private let lock = NSLock()
    private let pid: pid_t
    private let appears: Appearance
    private let appearsAfterReads: Int
    private let listReadable: Bool
    private let menuOpen: Bool
    private let keyboardOwner: pid_t?
    private var openerPosted = false
    private var readsSinceOpener = 0
    private var dialogShown = false
    private var reads = 0
    private var typedBeforeDialogShown = 0

    init(
        pid: pid_t,
        appears: Appearance = .window(title: GotoDialogScreen.englishTitle),
        appearsAfterReads: Int = 0,
        listReadable: Bool = true,
        menuOpen: Bool = false,
        keyboardOwner: pid_t? = nil
    ) {
        self.pid = pid
        self.appears = appears
        self.appearsAfterReads = appearsAfterReads
        self.listReadable = listReadable
        self.menuOpen = menuOpen
        self.keyboardOwner = keyboardOwner
    }

    /// How many times the list was asked for.
    var listReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    /// Keys other than the opener that went out before any list read had shown the dialog.
    var keysTypedBeforeDialogShown: Int { lock.lock(); defer { lock.unlock() }; return typedBeforeDialogShown }

    func windows() -> [[String: Any]]? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        guard listReadable else { return nil }
        var list: [[String: Any]] = []
        if menuOpen {
            list.append(Self.window(owner: pid, number: 7, layer: LogicOnScreenWindows.popupMenuLevel, title: nil))
        }
        if openerPosted {
            readsSinceOpener += 1
            if readsSinceOpener > appearsAfterReads, case let .window(title) = appears {
                list.append(Self.window(owner: pid, number: 2, layer: 8, title: title))
                dialogShown = true
            }
        }
        if let keyboardOwner {
            list.append(Self.window(owner: keyboardOwner, number: 9, layer: 0, title: "Finder"))
        }
        list.append(Self.window(owner: pid, number: 1, layer: 0, title: "Untitled - Tracks"))
        return list
    }

    /// Wraps a posting seam so the screen knows when the opener went out and can count keys typed
    /// before the dialog had been read on screen.
    func observing(
        _ post: @escaping @Sendable (CGKeyCode, CGEventFlags, pid_t) -> Bool
    ) -> @Sendable (CGKeyCode, CGEventFlags, pid_t) -> Bool {
        { [self] code, flags, target in
            let delivered = post(code, flags, target)
            lock.lock(); defer { lock.unlock() }
            if delivered, code == Self.opener, !openerPosted {
                openerPosted = true
            } else if delivered, !dialogShown {
                typedBeforeDialogShown += 1
            }
            return delivered
        }
    }

    private static func window(owner: pid_t, number: Int, layer: Int, title: String?) -> [String: Any] {
        var window: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: owner),
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowLayer as String: NSNumber(value: layer),
        ]
        if let title { window[kCGWindowName as String] = title }
        return window
    }
}

private final class Issue1038Posts: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [CGKeyCode] = []
    private var sleepMicros: [useconds_t] = []

    var posted: [CGKeyCode] { lock.lock(); defer { lock.unlock() }; return codes }
    /// Waits of the dialog poll's length; the frontmost gate's own wait is a different length.
    var dialogPollWaits: Int {
        lock.lock(); defer { lock.unlock() }
        return sleepMicros.filter { $0 == CGEventChannel.gotoDialogObservationPollMicros }.count
    }

    func runtime(pid: pid_t, screen: GotoDialogScreen) -> CGEventChannel.Runtime {
        CGEventChannel.Runtime(
            isLogicProRunning: { true },
            logicProPID: { pid },
            postKeyEvent: screen.observing { [self] code, _, _ in
                lock.lock(); defer { lock.unlock() }
                codes.append(code)
                return true
            },
            sleepMicros: { [self] micros in
                lock.lock(); defer { lock.unlock() }
                sleepMicros.append(micros)
            },
            onScreenWindowList: { screen.windows() }
        )
    }
}

private func issue1038Envelope(_ result: ChannelResult) -> [String: Any]? {
    guard let data = result.message.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

@Suite("Issue #1038 — goto_position types nothing until the dialog is observed open")
struct Issue1038GotoDialogGateTests {
    static let pid: pid_t = 1038

    /// Mutation this kills: post the whole sequence without waiting for the dialog (the pre-#1038
    /// `postShortcutSequence(sequence, ...)`). Ten keys go out and this counts them.
    @Test("a dialog that never appears is refused with the opener as the only key posted")
    func neverAppearingDialogTypesNothing() async throws {
        let screen = GotoDialogScreen(pid: Self.pid, appears: .nothing)
        let posts = Issue1038Posts()
        let channel = CGEventChannel(runtime: posts.runtime(pid: Self.pid, screen: screen))

        let result = await channel.execute(operation: "transport.goto_position", params: ["position": "12.1.1.1"])

        #expect(posts.posted == [GotoDialogScreen.opener], "no position character and no Return may follow")
        #expect(screen.keysTypedBeforeDialogShown == 0)
        #expect(!result.isSuccess)
        let envelope = try #require(issue1038Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["error"] as? String) == "dialog_not_found")
        #expect(try #require(envelope["reason"] as? String) == "dialog_not_observed")
        #expect(try #require(envelope["events_posted"] as? Int) == 1)
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
        // The wait is bounded by the poll count, not by a clock this test would have to read.
        #expect(posts.dialogPollWaits == CGEventChannel.gotoDialogObservationPolls)
    }

    /// Mutation this kills: post the opener before the baseline read, or read an unreadable
    /// baseline as an empty screen. Either posts at least the opener here.
    @Test("a window list that does not read before the opener posts nothing at all")
    func unreadableBaselinePostsNothing() async throws {
        let screen = GotoDialogScreen(pid: Self.pid, listReadable: false)
        let posts = Issue1038Posts()
        let channel = CGEventChannel(runtime: posts.runtime(pid: Self.pid, screen: screen))

        let result = await channel.execute(operation: "transport.goto_position", params: ["position": "5.1.1.1"])

        #expect(posts.posted.isEmpty)
        let envelope = try #require(issue1038Envelope(result))
        #expect(try #require(envelope["reason"] as? String) == "window_list_unreadable")
        #expect(try #require(envelope["events_posted"] as? Int) == 0)
        #expect(try #require(envelope["safe_to_retry"] as? Bool))
        #expect(!(try #require(envelope["fallback_unsafe"] as? Bool)))
    }

    /// Mutation this kills: take any window that appeared after the opener for the dialog (drop the
    /// `goToPositionDialogTitle` match). A sheet or another dialog would then receive the digits.
    @Test("a window that appeared and is not the dialog refuses at the first reading")
    func strangerWindowRefusesAtOnce() async throws {
        let screen = GotoDialogScreen(pid: Self.pid, appears: .window(title: "Save"))
        let posts = Issue1038Posts()
        let channel = CGEventChannel(runtime: posts.runtime(pid: Self.pid, screen: screen))

        let result = await channel.execute(operation: "transport.goto_position", params: ["position": "5.1.1.1"])

        #expect(posts.posted == [GotoDialogScreen.opener])
        let envelope = try #require(issue1038Envelope(result))
        #expect(try #require(envelope["reason"] as? String) == "unidentified_window_appeared")
        #expect(screen.listReads == 2, "the baseline and one reading; a stranger is not waited out")
    }

    /// Mutation this kills: accept the dialog while a Logic menu is open above it (drop the
    /// `menu == .closed` condition). The digits would go to the menu.
    @Test("the dialog under an open Logic menu is not typed into")
    func dialogUnderOpenMenuIsNotTyped() async throws {
        let screen = GotoDialogScreen(pid: Self.pid, menuOpen: true)
        let posts = Issue1038Posts()
        let channel = CGEventChannel(runtime: posts.runtime(pid: Self.pid, screen: screen))

        let result = await channel.execute(operation: "transport.goto_position", params: ["position": "5.1.1.1"])

        #expect(posts.posted == [GotoDialogScreen.opener])
        let envelope = try #require(issue1038Envelope(result))
        #expect(try #require(envelope["reason"] as? String) == "dialog_not_typable")
    }

    /// Mutation this kills: accept the dialog without Logic read as the keyboard owner (drop the
    /// `logicOwnsKeyboard == true` condition). The digits would go to the other process.
    @Test("the dialog is not typed into while another process owns the keyboard")
    func dialogWithoutKeyboardIsNotTyped() async throws {
        let screen = GotoDialogScreen(pid: Self.pid, keyboardOwner: 77)
        let posts = Issue1038Posts()
        let channel = CGEventChannel(runtime: posts.runtime(pid: Self.pid, screen: screen))

        let result = await channel.execute(operation: "transport.goto_position", params: ["position": "5.1.1.1"])

        #expect(posts.posted == [GotoDialogScreen.opener])
        let envelope = try #require(issue1038Envelope(result))
        #expect(try #require(envelope["reason"] as? String) == "dialog_not_typable")
    }

    /// Mutation this kills: read the screen once after the opener instead of polling (the dialog
    /// takes a few reads to draw), or type before the reading that shows it.
    @Test("a dialog that takes several reads to appear is typed into, and only after it was read")
    func lateDialogIsTypedIntoAfterItWasRead() async throws {
        let screen = GotoDialogScreen(pid: Self.pid, appears: .window(title: "위치로 이동"), appearsAfterReads: 3)
        let posts = Issue1038Posts()
        let channel = CGEventChannel(runtime: posts.runtime(pid: Self.pid, screen: screen))

        let result = await channel.execute(operation: "transport.goto_position", params: ["position": "5.1.1.1"])

        let sequence = try #require(CGEventChannel.gotoPositionSequence(for: "5.1.1.1"))
        #expect(posts.posted == sequence.map(\.keyCode))
        #expect(screen.keysTypedBeforeDialogShown == 0)
        #expect(result.isSuccess)
        let envelope = try #require(issue1038Envelope(result))
        let observation = try #require(envelope["dialog_observation"] as? [String: Any])
        #expect(try #require(observation["polls"] as? Int) == 3)
    }
}
