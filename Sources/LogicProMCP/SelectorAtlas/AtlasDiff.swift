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
            AXLogicProElements.transportPlaySelector,
            AXLogicProElements.toggleSelector(labels: AXLocalePolicy.trackMuteButton.labels),
            AXLogicProElements.toggleSelector(labels: AXLocalePolicy.trackSoloButton.labels),
            AXLogicProElements.toggleSelector(labels: AXLocalePolicy.trackRecordEnableCheckbox.labels),
        ]
    }

    /// Which container a selector addresses, so it is not scored outside it.
    ///
    /// A selector is written for a scope, and production supplies that scope at the call site:
    /// `findTrackArmButton` searches a TRACK HEADER, so the control bar's global Record button is
    /// never in its candidate set. #628 established the same thing for Solo — "Solo matches TWENTY
    /// checkboxes, one in the Control Bar and nineteen track buttons; scoping to the bar makes it
    /// unique."
    ///
    /// `confidences` scores across a whole document, so without this it asks a selector a question
    /// it was not written for. Measured 2026-08-30 the moment an English control-bar baseline
    /// existed: the arm toggle matches `Record` by prefix and the transport's Record button carries
    /// exactly that description, so diffing the two locales' control bars reported
    /// `trackHeaderArmToggle changed` — a drift in nothing, produced by scoring a track selector in
    /// a bar. Korean hid it only because `녹음` is not a prefix of `녹음 활성화`.
    static func scopeOf(_ id: SelectorID) -> ScopeKind {
        switch id {
        case .controlBar, .transportPlayButton: .controlBar
        default: .trackHeaderRail
        }
    }

    enum ScopeKind: Equatable, Sendable { case controlBar, trackHeaderRail }

    /// The selectors a document may be scored against, from what it says its scope is.
    ///
    /// A `window` capture holds both, so it scores everything. A scope nothing recognises scores
    /// nothing rather than everything — an unknown container is not a reason to ask every question.
    static func selectors(for document: AXSnapshot.Document) -> [SemanticSelector] {
        if document.scope == "window" { return adoptedSelectors }
        let kind: ScopeKind? =
            AXLocalePolicy.controlBarGroupLabel.matches(document.scope, mode: .exactStrict)
                ? .controlBar
                : (AXLocalePolicy.trackHeadersDescription.matches(document.scope, mode: .exactStrict)
                    ? .trackHeaderRail : nil)
        guard let kind else { return [] }
        return adoptedSelectors.filter { scopeOf($0.id) == kind }
    }

    /// Selectors that name ONE thing, not one-per-row.
    ///
    /// How many there should be is part of what a selector means, and coverage only asks a question
    /// that has an answer for the repeating kind. Without this, `.controlBar` was permanently
    /// unmeasured: `uncovered` requires a coverage measurement, coverage requires a repetition, and
    /// there is exactly one control bar in a window — so no baseline could ever cover it and no
    /// verdict could ever be `.reuseFull`. That is a gate that fails closed on its own definition
    /// rather than on the tree.
    static let singularSelectors: Set<SelectorID> = [.controlBar, .transportPlayButton]

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
        for selector in selectors(for: document) {
            let best = all.map { confidence(of: $0.candidate, against: selector) }.max() ?? 0
            // Absent, not zero. `drift` distinguishes "scored 0" from "not present at all", and the
            // second is what a selector that vanished from the tree looks like.
            if best > 0 { out[selector.id] = best }
        }
        return out
    }

    /// Every set of like siblings in the tree — each a candidate for "the thing there are many of".
    ///
    /// A container qualifies when it has two or more children and they all carry the same role: a
    /// track-header rail's rows, a mixer's strips. The set is not chosen here, because which one is
    /// the right unit depends on the selector being measured — see `coverage`.
    static func siblingSets(in node: AXSnapshot.Node) -> [[AXSnapshot.Node]] {
        var out: [[AXSnapshot.Node]] = []
        if node.children.count >= 2, Set(node.children.map(\.role)).count == 1 {
            out.append(node.children)
        }
        for child in node.children { out += siblingSets(in: child) }
        return out
    }

    /// Where a selector's repetition lives, as an index path to the container holding the units.
    ///
    /// Coverage is the measurement the best-score view cannot make. `confidences` takes the maximum
    /// across the tree, so a Logic update that strips the volume fader from five of six track
    /// headers leaves the maximum at 1.0 and the diff reads `.stable` — while every operation
    /// against those five tracks fails. Coverage goes 1.0 -> 0.2 and the run stops.
    ///
    /// The unit set is chosen PER SELECTOR, as the one holding the most of its matches — and that
    /// choice is the whole difference between working and not. Taking the root's children instead
    /// picked, in a whole-window capture, the five top-level groups (inspector, library, tracks,
    /// mixer, control bar): the mixer's faders all live inside one of them, so removing four of five
    /// left that one group still hit, coverage unchanged, and the loss read `.stable`. The
    /// repetition is nested, and the measurement has to find it where it is, not where the root is.
    ///
    /// A PATH, because the unit set has to be chosen once and then read in both documents. Choosing
    /// it independently on each side is what broke the first version: strip four of five mixer
    /// faders and the five-strip set drops to one hit, so a smaller two-unit set elsewhere now has
    /// the most matches and wins — reporting 1.0 again, from a different place. The measurement
    /// moved to keep its own score up. The baseline names the place; the current capture is read
    /// there and nowhere else.
    static func unitPath(in document: AXSnapshot.Document, for selector: SemanticSelector) -> [Int]? {
        var best: (path: [Int], hits: Int, ratio: Double)?
        func visit(_ node: AXSnapshot.Node, _ path: [Int]) {
            if node.children.count >= 2, Set(node.children.map(\.role)).count == 1 {
                let hits = node.children.filter { matches(selector, in: $0) }.count
                let ratio = Double(hits) / Double(node.children.count)
                if hits > 0,
                   best == nil || hits > best!.hits || (hits == best!.hits && ratio < best!.ratio) {
                    best = (path, hits, ratio)
                }
            }
            for (index, child) in node.children.enumerated() { visit(child, path + [index]) }
        }
        visit(document.root, [])
        return best?.path
    }

    static func matches(_ selector: SemanticSelector, in node: AXSnapshot.Node) -> Bool {
        candidates(in: node).contains { confidence(of: $0.candidate, against: selector) >= 0.6 }
    }

    /// The roles along a path, plus the role of the units at the end of it.
    ///
    /// An index path names a POSITION, not a thing. Read in another capture it can land on a
    /// different container that happens to have two or more children — and if that one is fully
    /// covered, a real loss elsewhere reads as no change at all. The role chain is the cheapest
    /// identity a snapshot can carry, and requiring it to still hold turns "the path resolved" into
    /// "the path resolved to the same kind of place".
    ///
    /// It is not a true identity and this does not pretend otherwise: two containers of the same
    /// role at the same depth are indistinguishable here. What it removes is the accidental case —
    /// a shifted index landing on something structurally unrelated.
    static func pathSignature(
        in document: AXSnapshot.Document, at path: [Int]
    ) -> [String]? {
        var node = document.root
        var roles = [node.role]
        for index in path {
            guard index < node.children.count else { return nil }
            node = node.children[index]
            roles.append(node.role)
        }
        guard node.children.count >= 2,
              let unitRole = node.children.first?.role,
              node.children.allSatisfy({ $0.role == unitRole })
        else { return nil }
        return roles + [unitRole]
    }

    /// The fraction of units at `path` that still find the selector's control.
    ///
    /// Returns nil when the path no longer resolves, no longer holds two or more like siblings, or
    /// no longer has the role chain `expecting` describes. Each of those is a change worth failing
    /// on rather than scoring, and `between` reads a nil here as zero.
    ///
    /// A LIMIT worth stating: this measures how many of the units present carry the control, so it
    /// cannot see units themselves disappearing — five strips at 5/5 becoming two strips at 2/2
    /// reads as no change. That is deliberate. Unit count follows the project (three tracks make
    /// three rows), so a baseline captured on one project and a run on another would report drift
    /// on every honest comparison if the count were part of the measurement.
    static func coverage(
        in document: AXSnapshot.Document,
        for selector: SemanticSelector,
        at path: [Int],
        expecting signature: [String]? = nil
    ) -> Double? {
        guard let actual = pathSignature(in: document, at: path) else { return nil }
        if let signature, signature != actual { return nil }
        var node = document.root
        for index in path { node = node.children[index] }
        return Double(node.children.filter { matches(selector, in: $0) }.count)
            / Double(node.children.count)
    }

    /// Coverage for every adopted selector, each measured where that selector's repetition is.
    static func coverage(in document: AXSnapshot.Document) -> [SelectorID: Double] {
        var out: [SelectorID: Double] = [:]
        for selector in adoptedSelectors {
            if let path = unitPath(in: document, for: selector),
               let ratio = coverage(in: document, for: selector, at: path) {
                out[selector.id] = ratio
            }
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
        // Measured at the SAME place on both sides: the baseline names where the repetition is, and
        // the current capture is read there. See `unitPath`.
        var before: [SelectorID: Double] = [:]
        var after: [SelectorID: Double] = [:]
        for selector in adoptedSelectors {
            guard let path = unitPath(in: baseline, for: selector),
                  let signature = pathSignature(in: baseline, at: path) else { continue }
            before[selector.id] = coverage(in: baseline, for: selector, at: path)
            // A path that no longer resolves, no longer holds like siblings, or now holds a
            // different KIND of place scores zero rather than nothing — the units did not go
            // missing, the tree around them changed shape, and that is not a reason to say stable.
            after[selector.id] = coverage(
                in: current, for: selector, at: path, expecting: signature) ?? 0
        }
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
    /// A selector counts as covered only when BOTH measurements were possible — it scored somewhere,
    /// and there was a repetition to read its coverage in. Scoring alone is not coverage: a capture
    /// holding exactly one instance of every selector and no repeated sibling set anywhere produces
    /// a full set of confidences, an empty unmeasured set, and a verdict of full reuse — while the
    /// measurement that catches partial loss never ran once.
    static func uncovered(
        baseline: AXSnapshot.Document,
        current: AXSnapshot.Document
    ) -> Set<SelectorID> {
        var covered = Set<SelectorID>()
        for selector in adoptedSelectors {
            let scored = confidences(in: baseline)[selector.id] != nil
                || confidences(in: current)[selector.id] != nil
            let measurable = singularSelectors.contains(selector.id)
                || unitPath(in: baseline, for: selector) != nil
            if scored, measurable { covered.insert(selector.id) }
        }
        return Set(adoptedSelectors.map(\.id)).subtracting(covered)
    }

    /// What a qualification run should do with a diff.
    ///
    /// `policy(for:)` already decides per selector; this is the run-level answer, and it is the
    /// worst case rather than a majority. One selector that can no longer find its control is
    /// enough to make a mutation unsafe, and averaging that away is how a gate stops being one.
    /// The verdict for a qualification run, from the baselines themselves.
    ///
    /// THIS is the entry point a caller should use, and the reason it exists is that the other one
    /// takes coverage as an argument — which means a caller can assert coverage it never measured.
    /// Removing the default from that parameter made the question unavoidable; it did not make the
    /// answer true. Here there is nothing to pass: the drifts and the unmeasured set are both
    /// derived from the same two documents, so `.reuseFull` cannot be reached by spelling `[]`.
    ///
    /// - Parameter baselines: every pair to be considered. Coverage is the UNION across them,
    ///   because one scope covering what another misses is exactly how a full baseline set is
    ///   assembled — and a selector no pair covers is unmeasured however many pairs there are.
    static func verdict(
        baselines: [(baseline: AXSnapshot.Document, current: AXSnapshot.Document)]
    ) -> QualificationReuse {
        guard !baselines.isEmpty else { return .failClosedMutation }
        let drifts = baselines.flatMap { between(baseline: $0.baseline, current: $0.current) }
        let unmeasured = baselines
            .map { uncovered(baseline: $0.baseline, current: $0.current) }
            .reduce(Set(adoptedSelectors.map(\.id))) { $0.intersection($1) }
        return verdict(for: drifts, assumingCoverage: unmeasured)
    }

    /// - Parameter assumingCoverage: the selectors the caller asserts were NOT measured. Named for
    ///   what it is: an assumption. `verdict(baselines:)` derives the same value from the documents
    ///   and is what production should call — passing `[]` here is a claim, and a claim is not a
    ///   measurement. Kept for the cases that build drifts by hand, where there is no document to
    ///   derive anything from.
    static func verdict(
        for drifts: [SelectorDrift],
        assumingCoverage uncovered: Set<SelectorID>
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
