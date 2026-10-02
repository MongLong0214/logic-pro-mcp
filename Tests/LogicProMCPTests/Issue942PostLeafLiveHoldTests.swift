import Foundation
import Testing
@testable import LogicProMCP

// The executor these tests drive exists only in debug builds (`postLeafLiveHoldExecutor` is under
// `#if DEBUG`), so the suite is too: a release build of the test target must still compile (review
// R1 of #1082). Release builds are kept from reading the variable by the same condition.
#if DEBUG

/// #942. The debug-build live-hold seam (`AccessibilityChannel+GotoPostLeafLiveHold.swift`): the
/// executor a live harness drives the dialog route through in place of the script. What these
/// tests establish is that each name the harness writes becomes the result the route classifies as
/// one of the fourteen that settle, that nothing else becomes a result at all, and that the three
/// files move the way the harness reads them. Whether a real server reaches the seam is the live
/// run's to show: it reads `entered` written by that server.
///
/// NO `#expect(<Bool> == <Bool>)` HERE (#393). Every hold runs with its release written before it
/// starts or with a poll count, so nothing here waits on a clock.
///
/// Every test names the mutation it was seen red under.
@Suite(.serialized) struct Issue942PostLeafLiveHoldTests {
    typealias Settlement = Issue942PostLeafSettlementTests
    typealias Harness = Issue942PostLeafMenuReconciliationTests

    /// The twelve site names and the two appearance names: the fourteen the harness may write.
    static let names: [String] =
        AccessibilityChannel.postLeafCleanupSites.map(\.identifier)
            + ["dialog_unidentified_new_window", "dialog_appearance_unreadable"]

    /// A fresh directory with `result` naming `name` and, when `released`, `release` already there.
    static func holdDirectory(naming name: String?, released: Bool) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue942-live-hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let name {
            try name.write(to: folder.appendingPathComponent("result"), atomically: true, encoding: .utf8)
        }
        if released {
            try Data().write(to: folder.appendingPathComponent("release"))
        }
        return folder
    }

    static func exists(_ folder: URL, _ file: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
    }

    static func errorText(_ result: ChannelResult) throws -> String {
        guard case let .error(text) = result else {
            Issue.record("expected an error, got \(result)")
            return ""
        }
        return text
    }

    /// The route, with the seam as its script and the settlement's screens on the scripted server.
    static func route(through folder: URL) async throws -> (envelope: [String: Any], server: Issue942ScriptedWindowServer) {
        let server = Issue942ScriptedWindowServer(Settlement.routeScreens.map(\.windows))
        let ledger = try #require(AccessibilityChannel.DialogIssuanceLedger.create())
        defer { ledger.remove() }
        let routed = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "942"],
            runtime: Settlement.routeRuntime(server),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { server.sleep($0) },
            executeDialogScript: AccessibilityChannel.postLeafLiveHoldExecutor(
                directory: folder.path, polls: 1, pollNanos: 0),
            createDialogIssuanceLedger: { ledger }
        )
        return (try Settlement.envelope(routed), server)
    }

    /// Each of the fourteen names, run through the route, ends on a result that settles: the
    /// receipt carries `post_leaf_settlement`, the settlement sends its one Escape at the menu,
    /// and the refusal outside it is the one that name stands for. `entered` holds the result
    /// the seam answered, and `release` is consumed so the next hold waits for its own.
    ///
    /// Mutations seen red: the site result built on `menuRefusal` (no settlement: that refusal
    /// reconciles); the envelope dropped so the raw result is returned (unparsed); the two
    /// appearance values swapped (outcome names the other result); `entered` not written;
    /// `release` left in place.
    @Test(arguments: Self.names)
    func eachNameBecomesAResultThatSettles(_ name: String) async throws {
        let folder = try Self.holdDirectory(naming: name, released: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = try #require(AccessibilityChannel.postLeafLiveHoldResult(token: name))

        let run = try await Self.route(through: folder)

        let receipt = try #require(run.envelope["post_leaf_settlement"] as? [String: Any], "\(name)")
        #expect(try Settlement.token(receipt, "action") == "menu_escape_loop", "\(name)")
        #expect(try Settlement.escapeTargets(receipt) == ["menu"], "\(name)")
        #expect(run.server.escapeCount == 1, "\(name)")
        // What the live harness reads to know the reply is the refusal and not a later channel's.
        let fallbackUnsafe = try #require(run.envelope["fallback_unsafe"] as? Bool, "\(name)")
        #expect(fallbackUnsafe, "\(name)")
        let safeToRetry = try #require(run.envelope["safe_to_retry"] as? Bool, "\(name)")
        #expect(!safeToRetry, "\(name)")
        let outcome = try Settlement.token(run.envelope, "dialog_route_outcome")
        if AccessibilityChannel.postLeafLiveHoldAppearanceResults[name] != nil {
            #expect(outcome == name, "\(name)")
        } else {
            #expect(outcome.hasSuffix("_cleanup_closed_false"), "\(name)")
        }
        let entered = try String(contentsOf: folder.appendingPathComponent("entered"), encoding: .utf8)
        #expect(entered == expected, "\(name)")
        #expect(!Self.exists(folder, "release"), "\(name): the hold consumes its release")
    }

    /// A site's result is the site's dialog refusal: the prefix the site's AppleScript returns,
    /// the refusal it appends, and the state `dismissOpenGoToPositionDialog` answers for a dialog
    /// it saw and could not close.
    ///
    /// Mutation seen red: `(CLOSED)` in place of `(OPEN)`.
    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.map(\.identifier))
    func aSiteNameIsThatSitesOpenDialogRefusal(_ identifier: String) throws {
        let site = try Harness.site(identifier)
        #expect(
            AccessibilityChannel.postLeafLiveHoldResult(token: identifier)
                == "\(site.resultPrefix)\(AccessibilityChannel.PostLeafCleanupSite.dialogRefusal) (OPEN)")
    }

    /// A name that is not one of the fourteen answers an error before anything is written, so
    /// a typo in the harness cannot become some other result.
    ///
    /// Mutation seen red: an unknown name falls back to the first site.
    @Test(arguments: [
        "", "ok", "OK", "leaf_click_errorx", "LEAF_CLICK_ERROR", "leaf_click_error\nreturn_focus",
        "DIALOG_UNIDENTIFIED_NEW_WINDOW", "menu_refusal", "post_return",
    ])
    func aNameOutsideTheFourteenIsAnErrorAndWritesNothing(_ name: String) async throws {
        #expect(AccessibilityChannel.postLeafLiveHoldResult(token: name) == nil, "\(name)")
        let folder = try Self.holdDirectory(naming: name, released: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executor = AccessibilityChannel.postLeafLiveHoldExecutor(directory: folder.path, polls: 1, pollNanos: 0)
        let text = try Self.errorText(await executor("script"))
        #expect(text.contains("names none of the fourteen"), "\(name)")
        #expect(!Self.exists(folder, "entered"), "\(name)")
        #expect(Self.exists(folder, "release"), "\(name): an error leaves the release for the harness to see")
    }

    /// The name is read with the line end a shell `echo` adds trimmed off, and nothing else.
    ///
    /// Mutation seen red: the name read untrimmed.
    @Test func aNameWithItsLineEndIsThatName() async throws {
        let folder = try Self.holdDirectory(naming: "return_focus\n", released: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executor = AccessibilityChannel.postLeafLiveHoldExecutor(directory: folder.path, polls: 1, pollNanos: 0)
        guard case .success = await executor("script") else {
            Issue.record("a name ending in a newline answered an error")
            return
        }
        let entered = try String(contentsOf: folder.appendingPathComponent("entered"), encoding: .utf8)
        #expect(entered == AccessibilityChannel.postLeafLiveHoldResult(token: "return_focus"))
    }

    /// No `result` file is the same error.
    ///
    /// Mutation seen red: a missing file read as the empty name of the first site.
    @Test func aMissingResultFileIsAnError() async throws {
        let folder = try Self.holdDirectory(naming: nil, released: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executor = AccessibilityChannel.postLeafLiveHoldExecutor(directory: folder.path, polls: 1, pollNanos: 0)
        #expect(try Self.errorText(await executor("script")).contains("names none of the fourteen"))
        #expect(!Self.exists(folder, "entered"))
    }

    /// A hold that is never released answers an error after its polls, having written `entered`:
    /// the harness that died mid-hold is visible to whoever reads the directory.
    ///
    /// Mutation seen red: the loop returning success when its polls run out.
    @Test(arguments: [1, 3])
    func anUnreleasedHoldIsAnErrorAfterItsPolls(_ polls: Int) async throws {
        let folder = try Self.holdDirectory(naming: "return_focus", released: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executor = AccessibilityChannel.postLeafLiveHoldExecutor(directory: folder.path, polls: polls, pollNanos: 0)
        #expect(try Self.errorText(await executor("script")).contains("release did not appear"))
        #expect(Self.exists(folder, "entered"))
    }

    /// Positive control for the one above: the same hold with its release written answers the
    /// envelope, parsed back to the result the name stands for.
    @Test func aReleasedHoldAnswersTheEnvelopeOfItsResult() async throws {
        let folder = try Self.holdDirectory(naming: "return_focus", released: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executor = AccessibilityChannel.postLeafLiveHoldExecutor(directory: folder.path, polls: 1, pollNanos: 0)
        guard case let .success(text) = await executor("script") else {
            Issue.record("a released hold answered an error")
            return
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["result"] as? String == AccessibilityChannel.postLeafLiveHoldResult(token: "return_focus"))
    }

    /// The test process is not started with the hold directory, so the route keeps its script.
    ///
    /// Mutation seen red: the environment lookup answering a hold for an absent key.
    @Test func withoutTheEnvironmentTheRouteKeepsItsScript() throws {
        try #require(ProcessInfo.processInfo.environment[AccessibilityChannel.postLeafLiveHoldEnvironmentKey] == nil)
        #expect(AccessibilityChannel.postLeafLiveHoldExecutorFromEnvironment() == nil)
    }
}
#endif
