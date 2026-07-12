import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-016 Tempo Map")
struct TempoMapTests {
    @Test func constantTempoConvertsOneBarToTwoSeconds() throws {
        let map = snapshot(events: [event(0, 120)])

        #expect(try #require(secondsAtTick(1_920, map: map)) == 2)
    }

    @Test func variableTempoUsesPiecewiseIntegration() throws {
        let map = snapshot(events: [event(0, 120), event(480, 60)])

        #expect(try #require(secondsAtTick(480, map: map)) == 0.5)
        #expect(try #require(secondsAtTick(960, map: map)) == 1.5)
        #expect(try #require(secondsAtTick(1_440, map: map)) == 2.5)
    }

    @Test func beatTimeRoundTripsAreStable() throws {
        let map = snapshot(events: [event(0, 120), event(480, 90), event(1_200, 72)])

        for tick in [Int64(0), 1, 479, 480, 481, 960, 1_200, 1_921] {
            let seconds = try #require(secondsAtTick(tick, map: map))
            #expect(tickAtSeconds(seconds, map: map) == tick)
        }
    }

    @Test func invalidMapsAndQueriesFailClosed() {
        let reversed = snapshot(events: [event(0, 120), event(480, 90), event(240, 60)])
        let duplicate = snapshot(events: [event(0, 120), event(0, 60)])
        let nonzeroStart = snapshot(events: [event(1, 120)])
        let zeroBPM = snapshot(events: [event(0, 0)])
        let infiniteBPM = snapshot(events: [event(0, .infinity)])
        let invalidPPQ = snapshot(events: [event(0, 120)], ppq: 0)

        for map in [reversed, duplicate, nonzeroStart, zeroBPM, infiniteBPM, invalidPPQ] {
            #expect(!isValidTempoMap(map))
            #expect(secondsAtTick(480, map: map) == nil)
            #expect(tickAtSeconds(1, map: map) == nil)
        }
        #expect(secondsAtTick(-1, map: snapshot()) == nil)
        #expect(tickAtSeconds(-1, map: snapshot()) == nil)
        #expect(tickAtSeconds(.infinity, map: snapshot()) == nil)
    }

    @Test func sagaRequiresCompleteValidCheckpointAndVerifiedRestore() {
        let valid = snapshot()
        let incomplete = snapshot(complete: false, partialReason: "tempo readback unavailable")
        let invalid = snapshot(events: [event(0, -1)])

        #expect(tempoMapSagaEligibility(beforeCheckpoint: nil, restoreVerified: true) == [
            .noCheckpoint,
        ])
        #expect(tempoMapSagaEligibility(beforeCheckpoint: incomplete, restoreVerified: true) == [
            .snapshotIncomplete,
        ])
        #expect(tempoMapSagaEligibility(beforeCheckpoint: invalid, restoreVerified: true) == [
            .invalidTempoMap,
        ])
        #expect(tempoMapSagaEligibility(beforeCheckpoint: valid, restoreVerified: false) == [
            .restoreNotVerified,
        ])
        #expect(tempoMapSagaEligibility(beforeCheckpoint: valid, restoreVerified: true).isEmpty)
    }

    @Test func incompleteInvalidCheckpointAccumulatesHonestRejections() {
        let checkpoint = snapshot(
            events: [event(0, -1)],
            complete: false,
            partialReason: "partial project tempo readback"
        )

        #expect(tempoMapSagaEligibility(beforeCheckpoint: checkpoint, restoreVerified: false) == [
            .snapshotIncomplete,
            .invalidTempoMap,
            .restoreNotVerified,
        ])
    }

    @Test func tempoMapDiffReportsChangesAndRemovalsByTick() {
        let before = snapshot(events: [event(0, 120), event(480, 90), event(960, 80)])
        let after = snapshot(events: [event(0, 120), event(480, 60), event(1_440, 100)])
        let diff = tempoMapDiff(before: before, after: after)

        #expect(diff.addedOrChanged == [event(480, 60), event(1_440, 100)])
        #expect(diff.removed == [event(960, 80)])
    }

    @Test func completeSnapshotAlwaysClearsPartialReason() throws {
        let initialized = snapshot(complete: true, partialReason: "stale reason")
        let encoded = Data(
            #"{"events":[{"tick":0,"bpm":120}],"timeSignatures":[],"ppq":480,"complete":true,"partialReason":"stale reason"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(TempoMapSnapshot.self, from: encoded)

        #expect(initialized.partialReason == nil)
        #expect(decoded.partialReason == nil)
    }

    @Test func projectModeAndReadOnlyStateRoundTrip() throws {
        let modes: [ProjectTempoMode] = [.keep, .adapt, .autoMatch]
        let state = SmartTempoState(
            mode: .autoMatch,
            analysisAvailable: true,
            mapPresent: true,
            complete: false,
            partialReason: "region readback not independently qualified"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode([ProjectTempoMode].self, from: encoder.encode(modes)) == modes)
        #expect(try decoder.decode(SmartTempoState.self, from: encoder.encode(state)) == state)
        #expect(!state.complete)
    }

    @Test func adr016FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR016_SMART_TEMPO"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr016SmartTempo)
    }

    private func snapshot(
        events: [TempoMapEvent] = [TempoMapEvent(tick: 0, bpm: 120)],
        ppq: Int = 480,
        complete: Bool = true,
        partialReason: String? = nil
    ) -> TempoMapSnapshot {
        TempoMapSnapshot(
            events: events,
            timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)],
            ppq: ppq,
            complete: complete,
            partialReason: partialReason
        )
    }

    private func event(_ tick: Int64, _ bpm: Double) -> TempoMapEvent {
        TempoMapEvent(tick: tick, bpm: bpm)
    }
}
