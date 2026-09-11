import Foundation
import Testing

@testable import LogicProMCP

/// #855 — the last segment of a configured plug-in menu path is the CHANNEL CONFIGURATION, and that
/// belongs to the strip rather than to the request.
///
/// Measured 2026-09-12 against live Logic 12.3: on a mono audio track the `Compressor` submenu
/// offers exactly `["Mono"]`, so all four configured paths — each ending in `Stereo` or `스테레오` —
/// missed the leaf, and `insert_plugin` refused to insert a plug-in that was sitting right there.
/// The same paths walk end to end on a stereo strip, which is why the original report could
/// truthfully say "the path demonstrably exists" while the product was truthfully failing: the two
/// sentences were about different strips.
@Suite("#855 plug-in insert leaf is the strip's configuration")
struct PluginInsertLeafConfigurationTests {
    // MARK: - which leaf gets pressed

    @Test("the caller's preference wins when the strip offers it")
    func preferenceWinsWhenOffered() {
        #expect(
            AccessibilityChannel.leafChoice(preferred: "Stereo", offered: ["Stereo", "Dual Mono"])
                == "Stereo"
        )
    }

    /// The measured regression. A single-item menu has no choice in it, so refusing would be
    /// refusing on a technicality — and that is exactly what the product did.
    @Test("a mono strip's single configuration is taken even though Stereo was asked for")
    func singleOfferedConfigurationIsTaken() {
        #expect(AccessibilityChannel.leafChoice(preferred: "Stereo", offered: ["Mono"]) == "Mono")
        #expect(AccessibilityChannel.leafChoice(preferred: "스테레오", offered: ["Mono"]) == "Mono")
    }

    /// Several configurations and none of them the requested one is NOT a free choice. Picking the
    /// first would be choosing a channel layout on the operator's behalf, silently, on a mutation
    /// that is not undoable from their seat.
    @Test("several unrequested configurations refuse rather than picking one")
    func severalUnrequestedConfigurationsRefuse() {
        #expect(
            AccessibilityChannel.leafChoice(
                preferred: "Stereo", offered: ["Mono", "Mono->Stereo", "Dual Mono"]
            ) == nil
        )
    }

    /// An empty leaf menu is not a single choice. Guarded explicitly because `offered.count == 1`
    /// and `offered.isEmpty` are one typo apart, and the empty case is what an unreadable menu
    /// produces — the failure mode that must never resolve to a press.
    @Test("an empty leaf menu resolves to nothing, not to a press")
    func emptyLeafMenuRefuses() {
        #expect(AccessibilityChannel.leafChoice(preferred: "Stereo", offered: []) == nil)
    }

    // MARK: - what the failure says

    /// Every one of these used to be the sentence "plugin menu selection failed". Finding the real
    /// cause needed a replication of the walk against the live tree, because the response could not
    /// tell a wrong category name from a configuration the strip does not have.
    @Test("the three failures are distinguishable by label")
    func failuresAreDistinguishable() {
        let root = AccessibilityChannel.MenuSelectionOutcome.rootMenuNotFound
        let leaf = AccessibilityChannel.MenuSelectionOutcome.noPathWalked([
            .leafMissing(wanted: "Stereo", offered: ["Mono"]),
        ])
        let segment = AccessibilityChannel.MenuSelectionOutcome.noPathWalked([
            .segmentMissing("다이내믹스"),
        ])

        #expect(AccessibilityChannel.menuFailureLabel(root) == "root_menu_not_found")
        #expect(AccessibilityChannel.menuFailureLabel(leaf) == "leaf_not_offered_by_this_strip")
        #expect(AccessibilityChannel.menuFailureLabel(segment) == "no_path_segment_matched")
        #expect(Set([
            AccessibilityChannel.menuFailureLabel(root),
            AccessibilityChannel.menuFailureLabel(leaf),
            AccessibilityChannel.menuFailureLabel(segment),
        ]).count == 3)
    }

    /// The real attempt list mixes endings: the Korean-category paths miss a segment while the
    /// English ones reach the leaf. The label must report the ending that carries information —
    /// reaching the leaf PROVES the category walked, so a leafMissing anywhere outranks a
    /// segmentMissing.
    @Test("a leaf that was reached outranks a category that did not match")
    func leafOutranksSegmentInAMixedAttemptList() {
        let mixed = AccessibilityChannel.MenuSelectionOutcome.noPathWalked([
            .leafMissing(wanted: "스테레오", offered: ["Mono"]),
            .leafMissing(wanted: "Stereo", offered: ["Mono"]),
            .segmentMissing("다이내믹스"),
            .segmentMissing("다이내믹스"),
        ])
        #expect(AccessibilityChannel.menuFailureLabel(mixed) == "leaf_not_offered_by_this_strip")
        #expect(AccessibilityChannel.menuLeafOffered(mixed) == ["Mono"])
    }

    @Test("the hint names what the strip offered, not what was asked for")
    func hintNamesWhatTheStripOffered() throws {
        let spec = try #require(AccessibilityChannel.pluginInsertSpec(named: "Compressor"))
        let hint = AccessibilityChannel.menuSelectionHint(
            .noPathWalked([.leafMissing(wanted: "Stereo", offered: ["Mono"])]),
            spec: spec
        )
        #expect(hint.contains("Compressor"))
        #expect(hint.contains("Mono"))
        // The point of the sentence, not just its contents: a reader has to learn WHOSE property
        // the missing segment is, or they will go on believing the menu path is wrong.
        #expect(hint.lowercased().contains("channel configuration"))
    }

    @Test("a root that never opened says so instead of blaming the path")
    func rootNotFoundHintDoesNotBlameThePath() throws {
        let spec = try #require(AccessibilityChannel.pluginInsertSpec(named: "Compressor"))
        let hint = AccessibilityChannel.menuSelectionHint(.rootMenuNotFound, spec: spec)
        #expect(hint.contains("never opened"))
        #expect(!hint.contains("Dynamics"))
    }

    /// The success envelope reports the configuration PRESSED, not the one requested. Without this
    /// the whole behaviour is invisible on the wire: a mono insert and a stereo insert would be
    /// indistinguishable, and the live run could not tell a fixed product from one that got lucky.
    @Test("a success names the configuration that was pressed, not the one requested")
    func successNamesTheChosenConfiguration() {
        #expect(
            AccessibilityChannel.menuLeafChosen(.selected(.pressed(leaf: "Mono"))) == "Mono"
        )
        #expect(
            AccessibilityChannel.menuLeafChosen(.selected(.pressed(leaf: "Stereo"))) == "Stereo"
        )
    }

    @Test("a failure names no chosen configuration")
    func failureNamesNoChosenConfiguration() {
        #expect(AccessibilityChannel.menuLeafChosen(.rootMenuNotFound).isEmpty)
        #expect(
            AccessibilityChannel.menuLeafChosen(
                .noPathWalked([.leafMissing(wanted: "Stereo", offered: ["Mono"])])
            ).isEmpty
        )
        // A press that was REFUSED is not a press. Guarded separately because `.pressRefused`
        // carries a leaf name and would read as a choice to a `case .selected` that forgot to
        // check the inner step.
        #expect(
            AccessibilityChannel.menuLeafChosen(
                .noPathWalked([.pressRefused(leaf: "Stereo")])
            ).isEmpty
        )
    }

    @Test("offered titles are empty when no leaf menu was ever reached")
    func noLeafReachedOffersNothing() {
        #expect(AccessibilityChannel.menuLeafOffered(.rootMenuNotFound).isEmpty)
        #expect(
            AccessibilityChannel.menuLeafOffered(
                .noPathWalked([.segmentMissing("Dynamics")])
            ).isEmpty
        )
    }

    /// Every stock spec ends its paths in a channel configuration. Pinned so a later spec added with
    /// a plug-in name in the last position — which would make `leafChoice`'s single-item rule press
    /// an arbitrary configuration — is caught here rather than live.
    @Test("every configured spec ends its paths in a channel configuration")
    func everySpecEndsInAConfiguration() throws {
        let configurations: Set<String> = ["Stereo", "스테레오", "Mono", "모노", "Dual Mono"]
        for name in ["Gain", "Compressor", "Channel EQ"] {
            let spec = try #require(AccessibilityChannel.pluginInsertSpec(named: name))
            #expect(!spec.menuPaths.isEmpty, "\(name)")
            for path in spec.menuPaths {
                let last = try #require(path.last)
                #expect(configurations.contains(last), "\(name): path ends in \(last)")
            }
        }
    }
}
