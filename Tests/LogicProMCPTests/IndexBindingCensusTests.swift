import Foundation
import MCP
import Testing

@testable import LogicProMCP

// PRD-007 (ADR-002 #285) — the index-binding ratchet's censuses.
//
// These are RECEIPTS, not behaviour tests. The ratchet only means something if
// moving an op between tiers is a visible, deliberate diff — so each tier is
// pinned by explicit operation-ID list. A census failure is not necessarily a
// bug: it is the reviewer's cue that the contract moved, and the diff is the
// evidence of which way.

@Suite("PRD-007 index-binding census")
struct IndexBindingCensusTests {
    private static func specs(_ ids: Set<OperationID>) -> [OperationSpec] {
        OperationRegistry.specs.filter { ids.contains($0.id) }
    }

    private static func ids(where predicate: (OperationSpec) -> Bool) -> Set<OperationID> {
        Set(OperationRegistry.specs.filter(predicate).map(\.id))
    }

    // MARK: - (a) seed set is corroborated and accepts the corroboration param

    @Test("census (a): the seed set is exactly the corroborated tier")
    func seedSetIsCorroborated() {
        // The pin. Changing this literal is the only legitimate way to change
        // which ops demand corroboration — and reviewing that diff is the point.
        let expectedSeedSet: Set<OperationID> = [
            .tracksDelete,          // irreversible topology destruction
            .tracksDuplicate,       // topology mutation; wrong target = phantom copy
            .tracksSetInstrument,   // replace-class; overwrites the wrong strip's patch
            .pluginsInsertVerified, // insert-class topology, trackIndex-keyed
        ]
        #expect(OperationRegistry.corroboratedOperationIDs == expectedSeedSet)
        #expect(Self.ids { $0.indexBinding == .corroborated } == expectedSeedSet)
    }

    @Test("census (a): every seed op advertises expected_name")
    func seedSetAdvertisesCorroborationParam() {
        for spec in Self.specs(OperationRegistry.corroboratedOperationIDs) {
            #expect(
                spec.allowedParams.contains(OperationRegistry.corroborationParam),
                "\(spec.id.rawValue) is corroborated but does not accept \(OperationRegistry.corroborationParam) — callers could not satisfy the gate"
            )
            // The escape hatch the refusal hint promises must actually exist.
            #expect(
                spec.allowedParams.contains("target_ref"),
                "\(spec.id.rawValue) refusal offers target_ref as an alternative; it must accept one"
            )
            #expect(spec.target == .acceptsStableTarget, "\(spec.id.rawValue)")
            #expect(spec.mutability == Mutability.`mutating`, "\(spec.id.rawValue)")
        }
    }

    @Test("census (a): no op outside the seed set advertises expected_name")
    func corroborationParamIsNotAdvertisedElsewhere() {
        let advertising = Self.ids { $0.allowedParams.contains(OperationRegistry.corroborationParam) }
        #expect(
            advertising == OperationRegistry.corroboratedOperationIDs,
            "expected_name must not be advertised by ops that would silently ignore it"
        )
    }

    // MARK: - (b) refRequired is empty today

    @Test("census (b): refRequired is assigned to zero production ops")
    func refRequiredIsEmpty() {
        // PINNED EMPTY. `.refRequired` is implemented and unit-tested via a
        // synthetic spec, but no production op carries it yet.
        //
        // PLANNED PROMOTION: `tracks.delete` (today `.corroborated`) moves here.
        // PRD-007 Part 2 flipped `FeatureFlags.adr002TargetRef` to default ON,
        // so the "every caller can obtain a target_ref" precondition is met —
        // this set stays empty by DELIBERATE choice, not by blocker. Promoting
        // is its own row flip + catalog diff, and it would still strand callers
        // running the `=0` kill-switch with no usable alternative.
        //
        // This set going non-empty IS the promotion receipt.
        #expect(OperationRegistry.refRequiredOperationIDs.isEmpty)
        #expect(Self.ids { $0.indexBinding == .refRequired }.isEmpty)
    }

    // MARK: - (c) the legacy deprecation census

    @Test("census (c): legacyIndexAllowed is pinned exactly")
    func legacyIndexAllowedIsPinned() throws {
        // DEPRECATED TIER. Every member still writes to a bare, unproven
        // ordinal. Shrinking this list is the ratchet turning; it must never
        // grow. Each entry earns its place only by being reversible — a
        // wrong-target write here is recoverable by the user. This pinned set is
        // the ADR-002 done-bar's recorded, issue-linked waiver (#401): the
        // residual is visible and enforced here, not a silent gap. A newly
        // registered reversible parameter write joins this tier deliberately;
        // it must bring the same explicit census update as its registry row.
        let expectedLegacy: Set<OperationID> = [
            .mixerSetVolume,           // reversible level write
            .mixerSetPan,              // reversible pan write
            .pluginsSetParamVerified,  // reversible param write (verified readback)
            .pluginsSetEQBandVerified, // reversible named-EQ parameter write
            .tracksSelect,             // selection only; no persistent state change
            .tracksRename,             // reversible: rename back
            .tracksMute,               // reversible toggle
            .tracksSolo,               // reversible toggle
            .tracksArm,                // reversible toggle
            .tracksArmOnly,            // reversible toggle
            .tracksSetAutomation,      // reversible mode switch
        ]
        #expect(Self.ids { $0.indexBinding == .legacyIndexAllowed } == expectedLegacy)

        // KNOWN RESIDUAL, deliberately NOT in any tier: `mixer.insert_plugin` is
        // an index-keyed plugin INSERT (irreversible-class by the seed set's own
        // test) that this axis cannot cover, because its TargetPolicy is `.none`
        // — it accepts no target_ref, so `.corroborated`'s "or supply target_ref"
        // escape hatch would be unofferable. Ratcheting it requires first making
        // it target-bearing. Asserted here so the gap is a tracked fact, not an
        // oversight that reads as coverage — the recorded, issue-linked waiver is
        // #401. The FULL hazard class (this op plus its reversible sibling) is
        // pinned by `unratchetedTrackKeyedHazardsArePinned`.
        let insertPlugin = try #require(
            OperationRegistry.specs.first { $0.id == .mixerInsertPlugin }
        )
        #expect(insertPlugin.target == TargetPolicy.none)
        #expect(insertPlugin.indexBinding == nil)
    }

    // MARK: - (c') the unratcheted-hazard tripwire

    @Test("census (c'): index-keyed mutating ops that are NOT target-bearing are pinned")
    func unratchetedTrackKeyedHazardsArePinned() {
        // THE TRIPWIRE (team-lead ruling, PRD-007). An op that keys on a track
        // strip but carries `target: .none` has an index path the ratchet CANNOT
        // reach: `.corroborated`/`.refRequired` only attach to target-bearing
        // specs, and its corroboration refusal could not honestly offer
        // "use target_ref instead" — it accepts none. Such an op therefore keeps
        // a wrong-target index path with no in-tier remedy.
        //
        // Pinning the exact set makes that gap a CI-carried receipt, not prose:
        // any NEW op added to this class fails this census and forces an explicit
        // decision (give it target_ref, then a tier) instead of silently
        // inheriting an unratcheted index path. Same no-open-ended-runway rule as
        // the refRequired==[] census.
        //
        // Discriminator = carries a track-strip selector (`track`/`track_index`).
        // `index`-only ops (navigate marker ops) are deliberately EXCLUDED: their
        // `index` addresses a marker, not a track, which is a different (and not
        // PRD-007-scoped) wrong-target class.
        let hazards = Self.ids {
            $0.mutability == Mutability.`mutating`
                && $0.target == .none
                && !$0.allowedParams.isDisjoint(with: ["track", "track_index"])
        }
        // PLANNED PROMOTIONS (each a later batch; the plumbing is a TargetPolicy
        // row + resolver change, a separate contract move from this PR):
        //   • mixer.insert_plugin    → give target_ref, then .corroborated
        //                              (irreversible insert; wrong-target is a real defect).
        //   • mixer.set_plugin_param → give target_ref, then .legacyIndexAllowed
        //                              (reversible param write; ratchet cost not yet earned,
        //                              but it still must become target-bearing to leave this set).
        // Existing members may only shrink; a new reversible target-bearing
        // operation requires an explicit census update with its registry row.
        #expect(hazards == [.mixerInsertPlugin, .mixerSetPluginParam])

        // The distinguishing property is real, not incidental: none of these can
        // accept the escape hatch their would-be corroboration refusal names.
        for spec in Self.specs(hazards) {
            #expect(!spec.allowedParams.contains("target_ref"), "\(spec.id.rawValue)")
            #expect(spec.indexBinding == nil, "\(spec.id.rawValue) is not tier-eligible until target-bearing")
        }
    }

    // MARK: - the axis's shape invariant

    @Test("census: indexBinding is non-nil for exactly the target-bearing mutating ops")
    func indexBindingAppliesExactlyToTargetBearingMutations() {
        for spec in OperationRegistry.specs {
            let isTargetBearingMutation =
                spec.target == .acceptsStableTarget && spec.mutability == Mutability.`mutating`
            let hasIndexBinding = spec.indexBinding != nil
            #expect(
                isTargetBearingMutation ? hasIndexBinding : !hasIndexBinding,
                "\(spec.id.rawValue): indexBinding=\(String(describing: spec.indexBinding)) but target-bearing-mutation=\(isTargetBearingMutation)"
            )
        }
        // Every tier's members are disjoint and together cover the whole axis.
        let tiered = Self.ids { $0.indexBinding != nil }
        let union = OperationRegistry.corroboratedOperationIDs
            .union(OperationRegistry.refRequiredOperationIDs)
            .union(Self.ids { $0.indexBinding == .legacyIndexAllowed })
        #expect(tiered == union)
        #expect(
            OperationRegistry.corroboratedOperationIDs
                .intersection(OperationRegistry.refRequiredOperationIDs)
                .isEmpty,
            "an op cannot be both corroborated and ref-required"
        )
    }

    // MARK: - (d) the rename census

    @Test("census (d): no 'requires_stable_target' spelling survives in the catalog")
    func renameLeavesNoStaleWireString() {
        // The rename's whole point: the wire must not carry a name that claims a
        // requirement the registry never enforced. A catalog walk (not a grep)
        // so this proves the SHIPPED surface, not just the source text.
        let snapshot = OperationCatalog.snapshot()
        for entry in snapshot.operations {
            #expect(
                entry.target != "requires_stable_target",
                "\(entry.id) still advertises the retired target policy string"
            )
            #expect(
                ["none", "accepts_stable_target"].contains(entry.target),
                "\(entry.id) has unknown target policy '\(entry.target)'"
            )
        }
        let encoded = try? JSONEncoder().encode(snapshot)
        let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!json.isEmpty)
        #expect(
            !json.contains("requires_stable_target"),
            "the retired policy string must not appear anywhere in the published catalog"
        )
        #expect(json.contains("accepts_stable_target"), "the new spelling must be published")
    }

    @Test("census (d): the target policy wire strings are exactly the two live spellings")
    func targetPolicyWireStringsPinned() {
        let published = Set(OperationCatalog.snapshot().operations.map(\.target))
        #expect(published == ["none", "accepts_stable_target"])
    }

    // MARK: - catalog publishes the new axis

    @Test("catalog: index_binding is published for exactly the tiered ops")
    func catalogPublishesIndexBinding() throws {
        let snapshot = OperationCatalog.snapshot()
        let bySpecID = Dictionary(
            uniqueKeysWithValues: OperationRegistry.specs.map { ($0.id.rawValue, $0) }
        )
        var published: [String: String] = [:]
        for entry in snapshot.operations {
            let spec = try #require(bySpecID[entry.id])
            switch spec.indexBinding {
            case nil:
                #expect(entry.indexBinding == nil, "\(entry.id) must publish no tier")
            case .some(let policy):
                let wire = try #require(entry.indexBinding, "\(entry.id) must publish its tier")
                published[entry.id] = wire
                #expect(wire == Self.expectedWire(policy), "\(entry.id)")
            }
        }
        #expect(published["tracks.delete"] == "corroborated")
        #expect(published["tracks.rename"] == "legacy_index_allowed")
        #expect(published["plugins.insert_verified"] == "corroborated")
        #expect(published["plugins.get_inventory"] == nil, "read-only op has no index binding")
        #expect(Set(published.values) == ["corroborated", "legacy_index_allowed"])
    }

    private static func expectedWire(_ policy: IndexBindingPolicy) -> String {
        switch policy {
        case .refRequired: "ref_required"
        case .corroborated: "corroborated"
        case .legacyIndexAllowed: "legacy_index_allowed"
        }
    }
}

// MARK: - .refRequired via a synthetic spec

// `.refRequired` carries zero production ops this increment, but shipping an
// unexercised enum case is how a tier rots before it is ever used. The guard is
// a pure function over an injected policy, so the tier is provable today
// against a synthetic spec — and the promotion (a registry row flip) then only
// has to change the row, not discover that the mechanism never worked.
@Suite("PRD-007 refRequired tier (synthetic)")
struct IndexBindingRefRequiredTests {
    private static let syntheticHeaders: @Sendable () -> [Int: String]? = { [3: "Drums"] }

    @Test("refRequired: a bare index is refused with stable_target_required")
    func refRequiredRefusesBareIndex() throws {
        let result = IndexBindingGuard.evaluate(
            policy: .refRequired,
            operation: "synthetic.ref_required_op",
            params: ["index": .int(3)],
            index: 3,
            liveTrackNames: Self.syntheticHeaders
        )
        let refusal = try #require(result)
        let object = try #require(sharedJSONObject(sharedToolText(refusal)))
        #expect(object["error"] as? String == "stable_target_required")
        #expect(object["state"] as? String == "C")
        let v1 = try #require(object["write_attempted"] as? Bool)
        #expect(!v1)
        #expect(object["requested_index"] as? Int == 3)
    }

    @Test("refRequired: expected_name cannot rescue a bare index")
    func refRequiredIgnoresCorroboration() throws {
        // The whole distinction from `.corroborated`: no amount of name evidence
        // substitutes for a stable identity at this tier. A correct, unique,
        // live-matching name must STILL be refused.
        let result = IndexBindingGuard.evaluate(
            policy: .refRequired,
            operation: "synthetic.ref_required_op",
            params: ["index": .int(3), "expected_name": .string("Drums")],
            index: 3,
            liveTrackNames: Self.syntheticHeaders
        )
        let refusal = try #require(result)
        let object = try #require(sharedJSONObject(sharedToolText(refusal)))
        #expect(object["error"] as? String == "stable_target_required")
        let v1 = try #require(object["write_attempted"] as? Bool)
        #expect(!v1)
    }

    @Test("refRequired: a supplied target_ref passes the guard to the ref machinery")
    func refRequiredAcceptsTargetRef() {
        let result = IndexBindingGuard.evaluate(
            policy: .refRequired,
            operation: "synthetic.ref_required_op",
            params: ["target_ref": .string("trk_abc")],
            index: 3,
            liveTrackNames: Self.syntheticHeaders
        )
        #expect(result == nil)
    }

    @Test("legacyIndexAllowed and non-tiered ops never gate")
    func untieredPoliciesNeverGate() {
        for policy: IndexBindingPolicy? in [.legacyIndexAllowed, nil] {
            let result = IndexBindingGuard.evaluate(
                policy: policy,
                operation: "synthetic.legacy_op",
                params: ["index": .int(3)],
                index: 3,
                liveTrackNames: nil
            )
            #expect(result == nil, "policy \(String(describing: policy)) must not gate the index path")
        }
    }
}
