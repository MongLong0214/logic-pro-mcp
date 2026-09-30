import Foundation

/// #942. A debug-build seam that lets a live harness put the real screen into the state one of the
/// fourteen post-leaf results leaves behind, so the settlement that follows those results can be
/// watched acting on Logic rather than on a fixture.
///
/// None of the fourteen can be produced on demand: each needs the script to fail at one particular
/// point after the leaf click. What the settlement acts on is not the script, though, but the
/// window list the parent reads after the script returns. So the seam keeps everything around the
/// script -- the frontmost gate, the cross-process lock, the baseline read before the script, the
/// parser, the settlement and the receipt -- and replaces only the script. It returns the envelope
/// the script returns for one named result, after holding long enough for the harness to arrange
/// the screen.
///
/// The protocol is three files in the directory the environment names. The harness writes the
/// result's name to `result`; the seam writes `entered` once it holds; the harness arranges the
/// screen and writes `release`. A hold that is never released answers an error, which the route
/// treats like a script that did not complete. Release builds never read the environment.
extension AccessibilityChannel {
    static let postLeafLiveHoldEnvironmentKey = "LOGIC_MCP_942_POST_LEAF_HOLD_DIR"
    /// 600 x 100 ms = 60 s: time to open a menu and a dialog through System Events, and bounded so
    /// a harness that died mid-hold does not leave the server waiting forever.
    static let postLeafLiveHoldPolls = 600
    static let postLeafLiveHoldPollNanos: UInt64 = 100_000_000

    /// The names the seam answers to: the twelve `PostLeafCleanupSite` identifiers and the two
    /// appearance results, which have no site because they return before either cleanup runs.
    static let postLeafLiveHoldAppearanceResults = [
        "dialog_unidentified_new_window": "DIALOG_UNIDENTIFIED_NEW_WINDOW",
        "dialog_appearance_unreadable": "DIALOG_APPEARANCE_UNREADABLE",
    ]

    /// The script result for one of the fourteen, or nil for any other name: a name that is not one
    /// of the fourteen must not become some other result. A site's result is its dialog refusal as
    /// the site's AppleScript assembles it, with `OPEN`, the state `dismissOpenGoToPositionDialog`
    /// answers for a dialog it saw and could not close.
    static func postLeafLiveHoldResult(token: String) -> String? {
        if let appearance = postLeafLiveHoldAppearanceResults[token] { return appearance }
        guard let site = postLeafCleanupSites.first(where: { $0.identifier == token }) else { return nil }
        return site.resultPrefix + PostLeafCleanupSite.dialogRefusal + " (OPEN)"
    }

    /// The executor the dialog route uses in place of the script when the environment names a hold
    /// directory; nil otherwise, and always nil in a release build.
    static func postLeafLiveHoldExecutorFromEnvironment() -> (@Sendable (String) async -> ChannelResult)? {
        #if DEBUG
        guard let directory = ProcessInfo.processInfo.environment[postLeafLiveHoldEnvironmentKey],
              !directory.isEmpty
        else { return nil }
        return postLeafLiveHoldExecutor(directory: directory)
        #else
        return nil
        #endif
    }

    #if DEBUG
    static func postLeafLiveHoldExecutor(
        directory: String,
        polls: Int = postLeafLiveHoldPolls,
        pollNanos: UInt64 = postLeafLiveHoldPollNanos
    ) -> @Sendable (String) async -> ChannelResult {
        { _ in
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            let release = folder.appendingPathComponent("release")
            guard let named = try? String(contentsOf: folder.appendingPathComponent("result"), encoding: .utf8),
                  let result = postLeafLiveHoldResult(token: named.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return .error("942 live hold: \(directory)/result names none of the fourteen post-leaf results")
            }
            guard FileManager.default.createFile(
                atPath: folder.appendingPathComponent("entered").path, contents: Data(result.utf8)
            ) else {
                return .error("942 live hold: \(directory)/entered could not be written")
            }
            for _ in 0..<polls {
                if FileManager.default.fileExists(atPath: release.path) {
                    try? FileManager.default.removeItem(at: release)
                    return .success("{\"result\":\"\(AppleScriptChannel.escapeJSON(result))\"}")
                }
                try? await Task.sleep(nanoseconds: pollNanos)
            }
            return .error("942 live hold: \(directory)/release did not appear")
        }
    }
    #endif
}
