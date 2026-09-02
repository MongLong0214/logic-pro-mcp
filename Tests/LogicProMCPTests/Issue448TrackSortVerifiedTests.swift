@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #448 — a sort is only State A when the post-write arrangement order is the
/// requested criterion's expected order. A changed order alone proves nothing:
/// another sort criterion also changes track order.

private actor TrackSortStateBChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private(set) var calls: [(operation: String, params: [String: String])] = []

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls.append((operation, params))
        return .success(HonestContract.encodeStateB(
            reason: .readbackMismatch,
            extras: ["operation": operation]
        ))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "#448 track-sort State-B probe")
    }
}

private struct TrackSortAXFixture {
    let runtime: AXLogicProElements.Runtime
    let expectedOrderJSON: String

    init(orderAfterPress: [Int], expectedReferenceOrder: [Int]? = nil) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(448_000)
        let arrange = builder.element(448_001)
        let rail = builder.element(448_002)
        let menuBar = builder.element(448_003)
        let file = builder.element(448_004)
        let edit = builder.element(448_005)
        let track = builder.element(448_006)
        let sortBy = builder.element(448_007)
        let sortByName = builder.element(448_008)

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setChildren(arrange, [rail])
        builder.setAttribute(rail, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(rail, kAXDescriptionAttribute as String, "Track Headers")

        let headers = (0..<3).map { offset -> AXUIElement in
            let header = builder.element(448_100 + offset)
            builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            builder.setAttribute(header, kAXTitleAttribute as String, "Studio Grand")
            builder.setChildren(header, [])
            return header
        }
        builder.setChildren(rail, headers)

        builder.setAttribute(file, kAXTitleAttribute as String, "파일")
        builder.setAttribute(edit, kAXTitleAttribute as String, "편집")
        builder.setAttribute(track, kAXTitleAttribute as String, "트랙")
        builder.setAttribute(sortBy, kAXTitleAttribute as String, "트랙을 다음으로 정렬")
        builder.setAttribute(sortByName, kAXTitleAttribute as String, "트랙 이름")
        builder.setAttribute(sortByName, kAXEnabledAttribute as String, true)
        builder.setChildren(menuBar, [file, edit, track])
        builder.setChildren(track, [sortBy])
        builder.setChildren(sortBy, [sortByName])

        runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == kAXPressAction as String,
                      builder.elementID(element) == builder.elementID(sortByName) else {
                    return false
                }
                builder.setChildren(rail, orderAfterPress.map { headers[$0] })
                return true
            }
        )
        let expected = (expectedReferenceOrder ?? orderAfterPress).map {
            TrackSortExpectedTrack(
                reference: "trk_studio_grand_\($0)",
                beforeIndex: $0,
                beforeName: "Studio Grand"
            )
        }
        expectedOrderJSON = String(
            data: try! JSONEncoder().encode(expected),
            encoding: .utf8
        )!
    }
}

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
        let runtimeResolved = Dictionary(uniqueKeysWithValues: TrackSortCriterion.allCases.map {
            ($0, $0.measuredLabel(for: "ko-KR"))
        })
        let allResolved = expected.allSatisfy { criterion, label in
            resolved[criterion] == label && runtimeResolved[criterion] == label
        }

        #expect(allResolved)
    }

    @Test("an unmeasured locale names the missing sort-menu measurement")
    func unmeasuredLocaleRefuses() {
        let policyRefusesEnglish = TrackSortCriterion.trackName.measuredLabel(for: "en_US") == nil
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .unmeasuredLocale("en_US") },
            after: { .read(["trk_bass", "trk_kick"]) }
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
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .criterionLabelMissing("트랙 이름") },
            after: { .read(["trk_bass", "trk_kick"]) }
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
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .actuated },
            after: { .read(["trk_kick", "trk_bass"]) }
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
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .unavailable },
            actuate: { .actuated },
            after: { .read(["trk_bass", "trk_kick"]) }
        )
        let afterUnreadable = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
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

    @Test("three same-named tracks sort and verify by their issued references")
    func duplicateNamesSortAndVerify() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [2, 1, 0])
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let expected = ["trk_studio_grand_2", "trk_studio_grand_1", "trk_studio_grand_0"]
        let allDisplayNamesAreDuplicates = Set(["Studio Grand", "Studio Grand", "Studio Grand"]).count == 1
        let verifiedUnambiguously = result.isSuccess
            && body["state"] as? String == "A"
            && body["expected_order"] as? [String] == expected
            && body["after_order"] as? [String] == expected

        #expect(allDisplayNamesAreDuplicates)
        #expect(verifiedUnambiguously)
    }

    @Test("an already-sorted reference order is State B with an observable reason")
    func alreadySortedIsStateB() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [0, 1, 2])
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let stateBForUnobservableNoOp = result.isSuccess
            && body["state"] as? String == "B"
            && body["reason"] as? String == HonestContract.UncertainReason.readbackUnavailable.rawValue
            && body["detail"] as? String == "already_sorted_command_unobservable"

        #expect(stateBForUnobservableNoOp)
    }

    @Test("a wrong post-sort reference order reaches State B and the tool surface refuses it")
    func postSortMismatchIsRefusedByToolSurface() async throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [1, 0, 2],
            expectedReferenceOrder: [2, 1, 0]
        )
        let channelResult = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let channelBody = try #require(sharedJSONObject(channelResult.message))

        let registry = TargetRegistry()
        let references = await FeatureFlags.withAdr002TargetRefForTests(true) {
            var references: [TargetReference] = []
            for index in 0..<3 {
                let descriptor = TargetDescriptor(trackIndex: index, trackName: "Studio Grand")
                references.append(await registry.bind(
                    kind: .track,
                    descriptor: descriptor,
                    fingerprint: descriptor.fingerprint
                ))
            }
            return references
        }
        let router = ChannelRouter()
        let stateBChannel = TrackSortStateBChannel()
        await router.register(stateBChannel)
        let toolResult = await FeatureFlags.withAdr002TargetRefForTests(true) {
            await TrackDispatcher.handle(
                command: "sort_verified",
                params: [
                    "criterion": .string("track_name"),
                    "expected_order": .array(references.reversed().map { .string($0.rawValue) }),
                    "confirmed": .bool(true),
                ],
                router: router,
                cache: StateCache(),
                targetRegistry: registry
            )
        }
        let toolBody = try #require(sharedJSONObject(sharedToolText(toolResult)))
        let mismatchWasStateB = channelResult.isSuccess
            && channelBody["state"] as? String == "B"
            && channelBody["reason"] as? String == HonestContract.UncertainReason.readbackMismatch.rawValue
        let toolRefusedMismatch = toolResult.isError == true
            && toolBody["state"] as? String == "B"
            && toolBody["reason"] as? String == HonestContract.UncertainReason.readbackMismatch.rawValue

        #expect(mismatchWasStateB)
        #expect(toolRefusedMismatch)
    }

    @Test("an expected order names an unavailable track reference before any write")
    func unavailableExpectedReferenceRefusesAndNamesIt() async throws {
        let registry = TargetRegistry()
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Studio Grand")
        let liveReference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        let absentReference = "trk_\(UUID().uuidString)"
        let router = ChannelRouter()
        let stateBChannel = TrackSortStateBChannel()
        await router.register(stateBChannel)

        let result = await FeatureFlags.withAdr002TargetRefForTests(true) {
            await TrackDispatcher.handle(
                command: "sort_verified",
                params: [
                    "criterion": .string("track_name"),
                    "expected_order": .array([.string(liveReference.rawValue), .string(absentReference)]),
                    "confirmed": .bool(true),
                ],
                router: router,
                cache: StateCache(),
                targetRegistry: registry
            )
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let missingReferences = try #require(body["missing_track_refs"] as? [String])
        let noWriteWasRouted = await stateBChannel.calls.isEmpty
        let namedAbsentReference = result.isError == true
            && body["reason"] as? String == "expected_order_unknown_track_refs"
            && missingReferences == [absentReference]
            && noWriteWasRouted

        #expect(namedAbsentReference)
    }

    @Test("a disabled measured menu item is refused before it is pressed")
    func disabledMenuItemRefuses() {
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .disabledMenuItem("트랙 이름") },
            after: { .read(["trk_bass", "trk_kick"]) }
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
