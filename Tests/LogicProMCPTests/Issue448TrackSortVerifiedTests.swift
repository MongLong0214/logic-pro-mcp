import Testing
@testable import LogicProMCP

/// #448 — a sort is only State A when the post-write arrangement order is the
/// requested criterion's expected order. A changed order alone proves nothing:
/// another sort criterion also changes track order.
@Suite("#448 verified track sort")
struct Issue448TrackSortVerifiedTests {
    @Test("an unknown sort criterion is rejected before any AX work")
    func unknownCriterionRefuses() {
        let criterion = TrackSortCriterion(rawValue: "not_a_sort_criterion")
        let isUnknown = criterion == nil

        #expect(isUnknown)
    }

    @Test("every measured Korean criterion resolves to its observed menu label")
    func everyCriterionResolvesMeasuredLabel() {
        let expected: [TrackSortCriterion: String] = [
            .midiChannel: "MIDI 채널",
            .audioChannel: "오디오 채널",
            .outputChannel: "출력 채널",
            .instrumentName: "악기 이름",
            .trackName: "트랙 이름",
            .used: "사용 여부",
            .creationDate: "생성일",
        ]

        let resolved = Dictionary(uniqueKeysWithValues: TrackSortCriterion.allCases.map {
            ($0, $0.measuredLabel(for: "ko_KR"))
        })
        let allResolved = expected.allSatisfy { criterion, label in
            resolved[criterion] == label
        }

        #expect(allResolved)
    }

    @Test("an unmeasured locale names the missing sort-menu measurement")
    func unmeasuredLocaleRefuses() {
        let policyRefusesEnglish = TrackSortCriterion.trackName.measuredLabel(for: "en_US") == nil
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["Bass", "Kick"],
            before: { .read(["Kick", "Bass"]) },
            actuate: { .unmeasuredLocale("en_US") },
            after: { .read(["Bass", "Kick"]) }
        )

        let refusedForMissingMeasurement: Bool
        if case .refused(.unmeasuredLocale(let locale)) = outcome {
            refusedForMissingMeasurement = locale == "en_US"
        } else {
            refusedForMissingMeasurement = false
        }
        let bothLocaleGuardsHeld = policyRefusesEnglish && refusedForMissingMeasurement
        #expect(bothLocaleGuardsHeld)
    }

    @Test("a missing leaf in the measured locale has its own refusal")
    func measuredCriterionLabelAbsentRefuses() {
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["Bass", "Kick"],
            before: { .read(["Kick", "Bass"]) },
            actuate: { .criterionLabelMissing("트랙 이름") },
            after: { .read(["Bass", "Kick"]) }
        )

        let refusedForAbsentMeasuredLabel: Bool
        if case .refused(.criterionLabelMissing(let label)) = outcome {
            refusedForAbsentMeasuredLabel = label == "트랙 이름"
        } else {
            refusedForAbsentMeasuredLabel = false
        }
        #expect(refusedForAbsentMeasuredLabel)
    }

    @Test("an order changed by the wrong criterion is refused, not reported verified")
    func postSortMismatchRefuses() {
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["Bass", "Kick"],
            before: { .read(["Kick", "Bass"]) },
            actuate: { .actuated },
            after: { .read(["Kick", "Bass"]) }
        )

        let rejectedMismatch: Bool
        if case .uncertain(.afterOrderMismatch) = outcome {
            rejectedMismatch = true
        } else {
            rejectedMismatch = false
        }
        #expect(rejectedMismatch)
    }

    @Test("an unreadable before or after order is never assumed")
    func unreadableOrdersRefuseOrRemainUncertain() {
        let beforeUnreadable = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["Bass", "Kick"],
            before: { .unavailable },
            actuate: { .actuated },
            after: { .read(["Bass", "Kick"]) }
        )
        let afterUnreadable = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["Bass", "Kick"],
            before: { .read(["Kick", "Bass"]) },
            actuate: { .actuated },
            after: { .unavailable }
        )

        let beforeRefused: Bool
        if case .refused(.beforeOrderUnreadable) = beforeUnreadable {
            beforeRefused = true
        } else {
            beforeRefused = false
        }
        let afterUncertain: Bool
        if case .uncertain(.afterOrderUnreadable) = afterUnreadable {
            afterUncertain = true
        } else {
            afterUncertain = false
        }

        #expect(beforeRefused)
        #expect(afterUncertain)
    }

    @Test("an already-sorted project is State B because a no-op is not observable")
    func alreadySortedIsUncertain() {
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["Bass", "Kick"],
            before: { .read(["Bass", "Kick"]) },
            actuate: { .actuated },
            after: { .read(["Bass", "Kick"]) }
        )

        let isUnobservableNoOp: Bool
        if case .uncertain(.alreadySortedCommandUnobservable) = outcome {
            isUnobservableNoOp = true
        } else {
            isUnobservableNoOp = false
        }
        #expect(isUnobservableNoOp)
    }

    @Test("a disabled measured menu item is refused before it is pressed")
    func disabledMenuItemRefuses() {
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["Bass", "Kick"],
            before: { .read(["Kick", "Bass"]) },
            actuate: { .disabledMenuItem("트랙 이름") },
            after: { .read(["Bass", "Kick"]) }
        )

        let disabledWasRefused: Bool
        if case .refused(.disabledMenuItem(let label)) = outcome {
            disabledWasRefused = label == "트랙 이름"
        } else {
            disabledWasRefused = false
        }
        #expect(disabledWasRefused)
    }
}
