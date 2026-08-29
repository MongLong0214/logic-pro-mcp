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

    /// The repeated units a scope is made of — one per track on a track-header rail.
    ///
    /// A rail is a list of rows with the same controls in each. Anything measured over the whole
    /// tree cannot tell six rows from one, and that is the gap `coverage` closes.
    static func repeatedUnits(in document: AXSnapshot.Document) -> [AXSnapshot.Node] {
        let children = document.root.children
        let modal = Dictionary(grouping: children, by: \.role)
            .max { $0.value.count < $1.value.count }
        guard let modal, modal.value.count >= 2 else { return [] }
        return modal.value
    }

    /// The fraction of repeated units in which a selector finds its control.
    ///
    /// This is the measurement the best-score view cannot make. `confidences` takes the maximum
    /// across the tree, so a Logic update that strips the volume fader from five of six track
    /// headers leaves the maximum at 1.0 and the diff reads `.stable` — while every operation
    /// against those five tracks fails. Coverage goes 1.0 -> 0.17 and the run stops.
    ///
    /// A FRACTION, not a count. Counts are not comparable between two captures of different
    /// projects: the Korean baseline has six tracks and the English one three, and demanding equal
    /// counts would report every honest re-capture as drift.
    static func coverage(in document: AXSnapshot.Document) -> [SelectorID: Double] {
        let units = repeatedUnits(in: document)
        guard !units.isEmpty else { return [:] }
        var out: [SelectorID: Double] = [:]
        for selector in adoptedSelectors {
            let hits = units.filter { unit in
                candidates(in: unit).contains {
                    confidence(of: $0.candidate, against: selector) >= 0.6
                }
            }
            out[selector.id] = Double(hits.count) / Double(units.count)
        }
        return out
    }

    /// The drift between two baselines, ready for a qualification report.
    ///
    /// Two measurements, because one of them cannot see a whole class of failure. The confidence
    /// diff catches a label Logic renamed; the coverage diff catches a control Logic removed from
    /// most rows but not all. A selector that loses coverage is reported `.changed` even when its
    /// best score is untouched — the strength of the best evidence in the tree says nothing about
    /// how many of the controls still carry it.
    static func between(
        baseline: AXSnapshot.Document,
        current: AXSnapshot.Document
    ) -> [SelectorDrift] {
        let before = coverage(in: baseline)
        let after = coverage(in: current)
        return drift(
            previous: confidences(in: baseline),
            current: confidences(in: current),
            roleChanges: [:]
        ).map { reported in
            guard let was = before[reported.selectorID], let now = after[reported.selectorID],
                  now < was - 0.001,
                  reported.status == .stable || reported.status == .minorDrift
            else { return reported }
            return SelectorDrift(
                selectorID: reported.selectorID,
                status: .changed,
                previousConfidence: reported.previousConfidence,
                currentConfidence: reported.currentConfidence,
                changedRoles: reported.changedRoles,
                affectedOperations: reported.affectedOperations
            )
        }
    }

    /// Adopted selectors this pair of baselines says nothing about.
    ///
    /// Silence is not coverage. A track-header fixture contains no control bar, so diffing two of
    /// them produces no `.controlBar` row at all — and a verdict read off that list alone would call
    /// transport qualified because nothing contradicted it. The caller has to see what was not
    /// measured, which is why it is a separate return rather than a quietly dropped key.
    static func uncovered(
        baseline: AXSnapshot.Document,
        current: AXSnapshot.Document
    ) -> Set<SelectorID> {
        let scored = Set(confidences(in: baseline).keys)
            .union(confidences(in: current).keys)
        return Set(adoptedSelectors.map(\.id)).subtracting(scored)
    }

    /// What a qualification run should do with a diff.
    ///
    /// `policy(for:)` already decides per selector; this is the run-level answer, and it is the
    /// worst case rather than a majority. One selector that can no longer find its control is
    /// enough to make a mutation unsafe, and averaging that away is how a gate stops being one.
    /// - Parameter uncovered: adopted selectors this pair did not measure. A run that leaves any
    ///   selector unmeasured cannot reuse a mutation qualification for it, so passing an empty set
    ///   is a claim the caller has to be able to make. The parameter has no default for that
    ///   reason: a default would let the honest question go unasked at the call site.
    static func verdict(
        for drifts: [SelectorDrift],
        uncovered: Set<SelectorID>
    ) -> QualificationReuse {
        // An empty comparison measured NOTHING, and nothing is not agreement. Two snapshots of the
        // wrong scope produce no drift rows at all, and this used to answer `.reuseFull` for them —
        // a gate that passes hardest when it is aimed at nothing.
        guard !drifts.isEmpty else { return .failClosedMutation }
        if !uncovered.isEmpty { return .failClosedMutation }
        let policies = drifts.map(policy(for:))
        if policies.contains(.failClosedMutation) { return .failClosedMutation }
        if policies.contains(.readOnlyOnly) { return .readOnlyOnly }
        return .reuseFull
    }
}
