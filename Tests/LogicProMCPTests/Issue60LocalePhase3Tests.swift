import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #60 (Phase 3): the read-only heuristic token bags that classify which AX
/// container is the marker ruler / the transport-control bar are now centralized
/// in `AXLocalePolicy` instead of inline literals. These deterministic EN+KO
/// tests pin the token coverage so a future edit can't silently drop a locale.
/// They are read-only classifiers — no State-A success is gated on them.
@Suite("Issue60 locale phase 3 token bags")
struct Issue60LocalePhase3Tests {
    @Test("marker container keywords cover EN + KO")
    func markerKeywords() {
        let labels = AXLocalePolicy.markerContainerKeywords.labels
        #expect(labels.contains("marker"))
        #expect(labels.contains("마커"))
    }

    @Test("transport container metadata covers EN + KO")
    func transportMetadata() {
        let labels = AXLocalePolicy.transportContainerMetadata.labels
        #expect(labels.contains("transport"))
        #expect(labels.contains("control bar"))
        #expect(labels.contains("컨트롤 막대"))
    }

    @Test("transport control keywords preserve the full EN + KO + JA token set")
    func transportControlKeywords() {
        let b = FakeAXRuntimeBuilder()
        let expected: Set<String> = [
            "play", "stop", "record", "cycle", "loop", "metronome", "rewind", "forward",
            "재생", "녹음", "사이클", "메트로놈", "클릭",
            "再生", "録音", "サイクル", "メトロノーム", "クリック",
        ]
        for (index, label) in expected.sorted().enumerated() {
            let group = b.element(904960 + index * 2), button = b.element(904961 + index * 2)
            b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
            b.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(button, kAXDescriptionAttribute as String, label)
            b.setChildren(group, [button])
            #expect(AXLogicProElements.transportControlKeywordHits(
                in: group, runtime: b.makeAXRuntime()).count == 1, "legacy control \(label)")
        }
    }

    @Test("reused transport slider authorities preserve all legacy EN + KO hints")
    func transportSliderHints() {
        let expected: Set<String> = ["tempo", "bpm", "position", "템포", "재생헤드 위치", "마디", "비트"]
        for hint in expected {
            #expect(AXLocalePolicy.tempoSliderLabel.containsAny(in: hint)
                || AXLocalePolicy.playheadPositionFieldLabel.containsAny(in: hint)
                || AXLocalePolicy.barSliderLabel.containsAny(in: hint)
                || AXLocalePolicy.beatSliderLabel.containsAny(in: hint))
        }
    }

    @Test("containsAny matches both EN and KO control-bar metadata (classifier semantics)")
    func containsAnyEnKo() {
        // The classifier scans an already-lowercased aggregate string.
        #expect(AXLocalePolicy.transportContainerMetadata.containsAny(in: "group transport bar"))
        #expect(AXLocalePolicy.transportContainerMetadata.containsAny(in: "그룹 컨트롤 막대"))
        #expect(!AXLocalePolicy.transportContainerMetadata.containsAny(in: "mixer strip"))
    }

    @Test("every Phase 3 token bag carries at least one Korean variant")
    func everyBagHasKorean() {
        let bags: [(String, AXLocalePolicy.LabelSet)] = [
            ("markerContainerKeywords", AXLocalePolicy.markerContainerKeywords),
            ("transportContainerMetadata", AXLocalePolicy.transportContainerMetadata),
            ("transportPlayControl", AXLocalePolicy.transportPlayControl),
            ("transportRecordControl", AXLocalePolicy.transportRecordControl),
            ("transportCycleControl", AXLocalePolicy.transportCycleControl),
            ("transportMetronomeControl", AXLocalePolicy.transportMetronomeControl),
            ("tempoSliderLabel", AXLocalePolicy.tempoSliderLabel),
            ("playheadPositionFieldLabel", AXLocalePolicy.playheadPositionFieldLabel),
            ("barSliderLabel", AXLocalePolicy.barSliderLabel),
            ("beatSliderLabel", AXLocalePolicy.beatSliderLabel),
        ]
        for (name, bag) in bags {
            let hasKorean = bag.labels.contains { $0.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
            #expect(hasKorean, "\(name) must carry a Korean variant for KO-locale coverage")
        }
    }

    // MARK: - Functional classifier coverage (drives the real AX entry points)
    //
    // The token-coverage tests above pin the bag contents; these prove the bag
    // is actually *consumed* by the read-only classifier it backs, end-to-end,
    // through a fake AX tree — in both English and Korean.

    // The two `enumerateMarkers` keyword-fallback cases that used to sit here were removed on
    // 2026-09-16 with the path they tested (#907). They proved that a marker container could be
    // classified by `markerContainerKeywords` on a fake tree with no Marker-List window and no
    // AXRuler -- a tree no Logic this repository pins produces, because 12.2 took markers out of
    // the arrange-window AX subtree entirely. The bag itself is still exercised: it now resolves
    // the marker group in the rename script, and `check-labelsets-are-derived.py` checks all ten
    // of its languages against Apple's own row.

    /// `getTransportBar` falls through to the `looksLikeTransportContainer`
    /// classifier (no toolbar / no id="Transport" group), which must recognize
    /// the control-bar group by the `transportContainerMetadata` bag. EN + KO.
    @Test("getTransportBar classifies the control bar by metadata (EN + KO)",
          arguments: ["transport", "컨트롤 막대"])
    func transportContainerMetadataIsWired(metadataLabel: String) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(8100)
        let window = b.element(8101)
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        let group = b.element(8110)
        b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(group, kAXDescriptionAttribute as String, metadataLabel)
        b.setChildren(window, [group])

        let bar = AXLogicProElements.getTransportBar(runtime: b.makeLogicRuntime(appElement: app))
        #expect(bar == group, "locale \(metadataLabel)")
    }
}
