import ApplicationServices
import Foundation

/// Scores an atlas baseline against the selectors in production, and diffs two baselines.
///
/// This is the piece `UIDriftReport` was written without. `drift(previous:current:roleChanges:)`
/// takes `[SelectorID: Double]` and nothing produced those numbers, so the report could not be
/// called from anywhere — the same shape as the resolver having no adapter.
///
/// Both sides are snapshots, so a diff runs with no Logic on the machine. That matters for the
/// criterion it serves: "new Logic version qualification includes atlas diff" is a step that has to
/// run wherever qualification runs, and a step needing the application open would not.
enum AtlasDiff {

    /// Every selector the product actually resolves through, with the identity it selects.
    ///
    /// The adopted set, not the whole `SelectorID` enum. A selector nobody calls has no confidence
    /// to lose, and scoring it would report drift in something that cannot break.
    static var adoptedSelectors: [SemanticSelector] {
        [
            AXLogicProElements.headerPanSelector,
            AXLogicProElements.volumeFaderSelector,
            AXLogicProElements.controlBarSelector,
            AXLogicProElements.toggleSelector(labels: AXLocalePolicy.trackMuteButton.labels),
            AXLogicProElements.toggleSelector(labels: AXLocalePolicy.trackSoloButton.labels),
            AXLogicProElements.toggleSelector(labels: AXLocalePolicy.trackRecordEnableCheckbox.labels),
        ]
    }

    /// A snapshot node as something the resolver can score.
    ///
    /// `ancestors` is threaded down the walk rather than read back up, because a snapshot has no
    /// parent links — it is a tree, and the only place the chain exists is the path taken to reach
    /// the node.
    static func candidates(
        in node: AXSnapshot.Node,
        ancestors: [String] = []
    ) -> [(candidate: ResolvableCandidate, node: AXSnapshot.Node)] {
        var attributes: [String: String] = [:]
        if let description = node.description {
            attributes[kAXDescriptionAttribute as String] = description
        }
        if let help = node.help {
            attributes[kAXHelpAttribute as String] = help
        }
        let here = ResolvableCandidate(
            axIdentifier: node.identifier,
            role: node.role,
            subrole: node.subrole,
            title: nil,
            ancestors: ancestors,
            attributes: attributes,
            valueSignature: node.valueRange,
            geometry: nil
        )
        var out = [(here, node)]
        for child in node.children {
            out += candidates(in: child, ancestors: [node.role] + ancestors)
        }
        return out
    }

    /// The best score each adopted selector reaches anywhere in this baseline.
    ///
    /// BEST, not the resolution. A selector that matches two nodes resolves to `.ambiguous` and is a
    /// refusal at run time — but for drift the question is "how well can this selector still see its
    /// control", and the answer to that is the strongest evidence available. Ambiguity is a separate
    /// failure and the report has `changedRoles` and the resolver's own policy for it.
    static func confidences(in document: AXSnapshot.Document) -> [SelectorID: Double] {
        let all = candidates(in: document.root)
        var out: [SelectorID: Double] = [:]
        for selector in adoptedSelectors {
            let best = all.map { confidence(of: $0.candidate, against: selector) }.max() ?? 0
            // Absent, not zero. `drift` distinguishes "scored 0" from "not present at all", and the
            // second is what a selector that vanished from the tree looks like.
            if best > 0 { out[selector.id] = best }
        }
        return out
    }

    /// The drift between two baselines, ready for a qualification report.
    static func between(
        baseline: AXSnapshot.Document,
        current: AXSnapshot.Document
    ) -> [SelectorDrift] {
        drift(
            previous: confidences(in: baseline),
            current: confidences(in: current),
            roleChanges: [:]
        )
    }

    /// What a qualification run should do with a diff.
    ///
    /// `policy(for:)` already decides per selector; this is the run-level answer, and it is the
    /// worst case rather than a majority. One selector that can no longer find its control is
    /// enough to make a mutation unsafe, and averaging that away is how a gate stops being one.
    static func verdict(for drifts: [SelectorDrift]) -> QualificationReuse {
        let policies = drifts.map(policy(for:))
        if policies.contains(.failClosedMutation) { return .failClosedMutation }
        if policies.contains(.readOnlyOnly) { return .readOnlyOnly }
        return .reuseFull
    }
}
