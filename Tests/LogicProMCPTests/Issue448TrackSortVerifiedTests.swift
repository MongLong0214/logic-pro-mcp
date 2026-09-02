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
    private let result: ChannelResult

    init(result: ChannelResult = .success(HonestContract.encodeStateB(
        reason: .readbackMismatch,
        extras: ["operation": "track.sort_verified"]
    ))) {
        self.result = result
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls.append((operation, params))
        return result
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "#448 track-sort State-B probe")
    }
}

private final class TrackSortActionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var postPressRailReadCount = 0

    func recordPress() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var pressCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func nextPostPressRailRead() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = postPressRailReadCount
        postPressRailReadCount += 1
        return current
    }
}

private let trackNameActuation = TrackSortVerifier.ActuatedMenuItem(
    localizedLabel: "트랙 이름",
    criterion: .trackName
)

private struct TrackSortAXFixture {
    let runtime: AXLogicProElements.Runtime
    let expectedOrderJSON: String
    let actionProbe: TrackSortActionProbe

    init(
        orderAfterPress: [Int],
        expectedReferenceOrder: [Int]? = nil,
        names: [String] = ["Kick", "Bass", "Piano"],
        pressReturnsSuccess: Bool = true,
        collapsedStackAt: Int? = nil,
        railUnreadableAfterPress: Bool = false,
        postPressOrders: [[Int]]? = nil,
        windowsReadStatus: AXHelpers.AXStatusError? = nil,
        railRoleReadStatus: AXHelpers.AXStatusError? = nil,
        menuEnabledReadStatus: AXHelpers.AXStatusError? = nil
    ) {
        precondition(names.count == 3)
        let builder = FakeAXRuntimeBuilder()
        let probe = TrackSortActionProbe()
        actionProbe = probe
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
            builder.setAttribute(header, kAXTitleAttribute as String, names[offset])
            if collapsedStackAt == offset {
                let disclosure = builder.element(448_200 + offset)
                builder.setAttribute(disclosure, kAXRoleAttribute as String, kAXDisclosureTriangleRole as String)
                builder.setAttribute(disclosure, kAXValueAttribute as String, 0)
                builder.setChildren(header, [disclosure])
            } else {
                builder.setChildren(header, [])
            }
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
            attributeValueResultHandler: { element, attribute in
                if let windowsReadStatus,
                   builder.elementID(element) == builder.elementID(app),
                   attribute == (kAXWindowsAttribute as String) {
                    return .failure(windowsReadStatus)
                }
                if let railRoleReadStatus,
                   builder.elementID(element) == builder.elementID(rail),
                   attribute == (kAXRoleAttribute as String) {
                    return .failure(railRoleReadStatus)
                }
                if let menuEnabledReadStatus,
                   builder.elementID(element) == builder.elementID(sortByName),
                   attribute == (kAXEnabledAttribute as String) {
                    return .failure(menuEnabledReadStatus)
                }
                return nil
            },
            childrenResultHandler: { element in
                guard builder.elementID(element) == builder.elementID(rail),
                      probe.pressCount > 0 else {
                    return nil
                }
                if railUnreadableAfterPress {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                if let postPressOrders, !postPressOrders.isEmpty {
                    // The strict rail scan reads the candidate and then its rows,
                    // so each observation consumes two rail-children reads.
                    let observation = min(
                        probe.nextPostPressRailRead() / 2,
                        postPressOrders.count - 1
                    )
                    return .success(postPressOrders[observation].map { headers[$0] })
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == kAXPressAction as String,
                      builder.elementID(element) == builder.elementID(sortByName) else {
                    return false
                }
                probe.recordPress()
                builder.setChildren(rail, orderAfterPress.map { headers[$0] })
                return pressReturnsSuccess
            }
        )
        let expected = (expectedReferenceOrder ?? orderAfterPress).map {
            TrackSortExpectedTrack(
                reference: "trk_\($0)",
                beforeIndex: $0,
                beforeName: names[$0]
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

    @Test("an order matching expectation under the wrong actuated criterion is refused")
    func wrongActuatedCriterionRefuses() {
        let instrumentNameActuation = TrackSortVerifier.ActuatedMenuItem(
            localizedLabel: "악기 이름",
            criterion: .instrumentName
        )
        let outcome = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .actuated(instrumentNameActuation) },
            // The wrong sort happens to produce the requested permutation. This
            // test fails if the production criterion-binding guard is removed.
            after: { .read(["trk_bass", "trk_kick"]) }
        )

        let rejectedWrongActuatedCriterion: Bool
        if case .refused(.criterionMismatch(let actual, let label)) = outcome {
            rejectedWrongActuatedCriterion = actual == .instrumentName && label == "악기 이름"
        } else {
            rejectedWrongActuatedCriterion = false
        }
        #expect(rejectedWrongActuatedCriterion)
    }

    @Test("an unreadable before or after order is never assumed")
    func unreadableOrdersRefuseOrRemainUncertain() {
        let beforeUnreadable = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .unavailable },
            actuate: { .actuated(trackNameActuation) },
            after: { .read(["trk_bass", "trk_kick"]) }
        )
        let afterUnreadable = TrackSortVerifier.execute(
            criterion: .trackName,
            expectedOrder: ["trk_bass", "trk_kick"],
            before: { .read(["trk_kick", "trk_bass"]) },
            actuate: { .actuated(trackNameActuation) },
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

    @Test("duplicate names refuse before AX work because no per-track identity was issued")
    func duplicateNamesRefuseBeforePress() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            names: ["Studio Grand", "Studio Grand", "Studio Grand"]
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let duplicateNamesWerePresent = Set(["Studio Grand", "Studio Grand", "Studio Grand"]).count == 1
        let refusedWithoutAXPress = result.isSuccess == false
            && body["reason"] as? String == "duplicate_name_reference_identity_unprovable"
            && fixture.actionProbe.pressCount == 0

        #expect(duplicateNamesWerePresent)
        #expect(refusedWithoutAXPress)
    }

    @Test("State A carries the exact pressed leaf and its measured criterion")
    func verifiedSortCarriesActuatedCriterionEvidence() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [2, 1, 0])
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let includesActualLeafEvidence = result.isSuccess
            && body["state"] as? String == "A"
            && body["criterion"] as? String == "track_name"
            && body["actuated_criterion"] as? String == "track_name"
            && body["actuated_menu_item_label"] as? String == "트랙 이름"
            && fixture.actionProbe.pressCount == 1

        #expect(includesActualLeafEvidence)
    }

    @Test("a collapsed stack refuses before its hidden tracks can be sorted")
    func collapsedStackRefusesBeforePress() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [2, 1, 0], collapsedStackAt: 1)
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let collapsedScopeWasRejected = result.isSuccess == false
            && body["reason"] as? String == "collapsed_track_stack"
            && (body["collapsed_stack"] as? [String: Any])?["index"] as? Int == 1
            && fixture.actionProbe.pressCount == 0

        #expect(collapsedScopeWasRejected)
    }

    @Test("a failed AXPress still reads back and reports a verified observed order")
    func failedPressStillReadsBack() throws {
        let fixture = TrackSortAXFixture(orderAfterPress: [2, 1, 0], pressReturnsSuccess: false)
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let failedReceiptDidNotEraseTheWrite = result.isSuccess
            && body["state"] as? String == "A"
            && body["menu_press_reported_success"] as? Bool == false
            && body["write_attempted"] as? Bool == true
            && body["after_order"] as? [String] == ["trk_2", "trk_1", "trk_0"]
            && fixture.actionProbe.pressCount == 1

        #expect(failedReceiptDidNotEraseTheWrite)
    }

    @Test("a failed AXPress with unreadable order marks project state unknown and invalidates refs")
    func failedPressUnreadableOrderInvalidatesReferences() async throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            pressReturnsSuccess: false,
            railUnreadableAfterPress: true
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
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Kick")
        let reference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        let router = ChannelRouter()
        await router.register(TrackSortStateBChannel(result: channelResult))
        _ = await FeatureFlags.withAdr002TargetRefForTests(true) {
            await TrackDispatcher.handle(
                command: "sort_verified",
                params: [
                    "criterion": .string("track_name"),
                    "expected_order": .array([.string(reference.rawValue)]),
                    "confirmed": .bool(true),
                ],
                router: router,
                cache: StateCache(),
                targetRegistry: registry
            )
        }
        let referenceWasInvalidated = await registry.resolve(reference) == nil
        let unknownStateWasHonest = channelResult.isSuccess
            && channelBody["state"] as? String == "B"
            && channelBody["write_attempted"] as? Bool == true
            && channelBody["project_state"] as? String == "unknown"
            && channelBody["safe_to_retry"] as? Bool == false
            && fixture.actionProbe.pressCount == 1

        #expect(unknownStateWasHonest)
        #expect(referenceWasInvalidated)
    }

    @Test("a transient matching order cannot reach State A before the second matching observation")
    func transientOrderDoesNotPassSettleWitness() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            postPressOrders: [[2, 1, 0], [1, 0, 2]]
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let transientWasNotPromoted = result.isSuccess
            && body["state"] as? String == "B"
            && body["reason"] as? String == HonestContract.UncertainReason.readbackMismatch.rawValue
            && body["after_order"] as? [String] == ["trk_1", "trk_0", "trk_2"]

        #expect(transientWasNotPromoted)
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

    @Test("an AXWindows read failure refuses instead of falling through a legacy empty list")
    func windowsReadFailureRefusesBeforePress() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            windowsReadStatus: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let failedWindowReadWasNotAnEmptyWindowList = result.isSuccess == false
            && body["reason"] as? String == "before_order_read_failed"
            && body["read_failure_stage"] as? String == "AXWindows"
            && body["read_failure_status"] as? String == String(AXError.cannotComplete.rawValue)
            && fixture.actionProbe.pressCount == 0

        #expect(failedWindowReadWasNotAnEmptyWindowList)
    }

    @Test("the two definitive-absence AX statuses still permit the direct arrange-window read")
    func windowsDefinitiveAbsenceIsNotAReadFailure() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            windowsReadStatus: AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let definitiveAbsenceWasHandledAsAbsence = result.isSuccess
            && body["state"] as? String == "A"
            && fixture.actionProbe.pressCount == 1

        #expect(definitiveAbsenceWasHandledAsAbsence)
    }

    @Test("an unreadable rail role refuses instead of being flattened to no rail")
    func railRoleReadFailureRefusesBeforePress() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            railRoleReadStatus: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let unreadableRoleWasNotReportedAsAbsentRail = result.isSuccess == false
            && body["reason"] as? String == "before_order_read_failed"
            && body["read_failure_stage"] as? String == "track_header_candidate_role"
            && body["read_failure_status"] as? String == String(AXError.cannotComplete.rawValue)
            && fixture.actionProbe.pressCount == 0

        #expect(unreadableRoleWasNotReportedAsAbsentRail)
    }

    @Test("an unreadable AXEnabled status is not misreported as a disabled menu item")
    func menuEnabledReadFailureRefusesBeforePress() throws {
        let fixture = TrackSortAXFixture(
            orderAfterPress: [2, 1, 0],
            menuEnabledReadStatus: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )
        let result = AccessibilityChannel.defaultSortTracks(
            params: [
                "criterion": "track_name",
                "expected_order_json": fixture.expectedOrderJSON,
            ],
            runtime: fixture.runtime
        )
        let body = try #require(sharedJSONObject(result.message))
        let enabledReadFailureWasNamed = result.isSuccess == false
            && body["reason"] as? String == "sort_menu_read_failed"
            && fixture.actionProbe.pressCount == 0

        #expect(enabledReadFailureWasNamed)
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
