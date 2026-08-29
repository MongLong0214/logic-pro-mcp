import ApplicationServices
import Foundation

/// Takes the live half of an atlas diff: for each committed baseline, a capture at the same scope.
///
/// Split from `AtlasQualification` because these two have different testability. The decision —
/// what a verdict means for a run — is pure and every branch of it is exercised offline. This half
/// needs Logic on screen, so a build without it produces no pairs; an ARMED run reads that as a
/// refusal, which is the only reading that does not turn "could not look" into "nothing wrong".
///
/// WHERE THE BASELINES COME FROM
/// -----------------------------
/// `LOGIC_MCP_ATLAS_BASELINES`, a directory of `*.json` documents. Not bundled into the binary and
/// not discovered by walking upward from the executable: a qualification run is asked to prove a
/// release, and letting it find its own baselines by searching would let the answer depend on where
/// somebody happened to unpack it. The operator names the directory or the run has none.
enum AtlasCapture {

    /// The scope resolution a baseline's `scope` field asks for.
    ///
    /// Two routes, because two kinds of scope exist and only one can be matched by description.
    /// The control bar is resolved by `getControlBar`, which discriminates the two groups carrying
    /// that description by the property callers depend on (#628); everything else is a container
    /// named by an exact description, which is what the capture command already does.
    static func resolveScope(
        _ scope: String,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        if AXLocalePolicy.controlBarGroupLabel.matches(scope, mode: .exactStrict) {
            return AXLogicProElements.getControlBar()
        }
        if scope == "window" { return window }
        return AXLocalePolicy.censusDescendant(
            of: window, role: "AXGroup",
            matching: AXLocalePolicy.LabelSet(
                canonical: scope, variants: [], rationale: "atlas baseline scope"),
            mode: .exactStrict, maxDepth: 8, runtime: runtime).element
    }

    /// Every baseline in `directory`, paired with a capture taken at its own scope.
    ///
    /// A baseline whose scope cannot be resolved is DROPPED rather than paired with an empty
    /// document. An empty current would diff as "every selector vanished" — true-looking and about
    /// nothing — whereas a missing pair narrows what the run measured, which `uncovered` then
    /// reports honestly. Losing every pair leaves an armed run with nothing, and that refuses.
    static func pairs(
        baselinesIn directory: URL,
        window: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> (pairs: [AtlasQualification.Pair], dropped: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var out: [AtlasQualification.Pair] = []
        // What was NOT paired, by name. Dropping is right — an empty current would diff as "every
        // selector vanished", true-looking and about nothing — but dropping SILENTLY is not: with
        // one baseline unreadable and the rest covering every selector, the case passed while a
        // scope nobody could resolve went unmentioned. Named by review, 2026-08-29.
        var dropped: [String] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let baseline = try? JSONDecoder().decode(AXSnapshot.Document.self, from: data),
                  let root = resolveScope(baseline.scope, in: window, runtime: runtime)
            else { dropped.append(url.lastPathComponent); continue }
            let captured = AXSnapshot.capture(root, runtime: runtime)
            // NOT the baseline's `logicVersion` and `locale`. Copying them made the live document
            // assert what it was compared AGAINST rather than what it is, so a `ko` baseline read
            // on an English Logic produced a "ko" current and the pair looked matched. Nothing here
            // can read the running version or language, so the honest value is a name that says so
            // — a reader seeing `observed` knows to look elsewhere for the axis, which is exactly
            // what an empty-looking `ko` would have hidden. Named by review, 2026-08-29.
            let current = AXSnapshot.Document(
                logicVersion: "observed",
                locale: "observed",
                scope: baseline.scope,
                capturedFrom: "ax",
                root: AXSnapshot.restorableRootDescription(
                    scope: "control-bar",
                    resolvedDescription: AXLocalePolicy.controlBarGroupLabel
                        .matches(baseline.scope, mode: .exactStrict)
                        ? AXHelpers.getDescription(root, runtime: runtime) : nil
                ).map { AXSnapshot.scopedRoot(captured, readBackDescription: $0) } ?? captured)
            out.append(AtlasQualification.Pair(
                scope: baseline.scope, baseline: baseline, current: current))
        }
        return (out, dropped)
    }

    /// Pairs for the run happening now, or none.
    ///
    /// None when the directory is unset, when it holds nothing readable, or when Logic is not on
    /// screen. All three are the same fact from this function's point of view — it could not look —
    /// and the caller is the one that decides what that means.
    static func pairsForThisRun() -> (pairs: [AtlasQualification.Pair], dropped: [String]) {
        guard let path = ProcessInfo.processInfo.environment["LOGIC_MCP_ATLAS_BASELINES"],
              !path.isEmpty,
              let window = AXLogicProElements.mainWindow()
        else { return ([], []) }
        return pairs(baselinesIn: URL(fileURLWithPath: path), window: window)
    }
}
