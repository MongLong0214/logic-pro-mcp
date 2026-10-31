import Foundation
import MCP
import Testing
@testable import LogicProMCP

private func expectInvalidParamsWithoutRouting(
    _ result: CallTool.Result,
    channels: [MockChannel],
    label: String
) async {
    let text = sharedToolText(result)
    #expect(result.isError!, "\(label) must reject before routing; got: \(text)")
    #expect(text.contains("invalid_params"), "\(label) must return invalid_params; got: \(text)")
    for channel in channels {
        #expect(await channel.executedOps.isEmpty, "\(label) must not route on invalid input")
    }
}

@Suite("Production hardening review regressions")
struct ProductionHardeningReviewRegressionTests {
    @Test("MIDI port must reject non-string values when present")
    func testMIDIPortRejectsNonStringWhenPresent() async {
        let router = ChannelRouter()
        let coreMidi = MockChannel(id: .coreMIDI)
        await router.register(coreMidi)

        let result = await MIDIDispatcher.handle(
            command: "send_note",
            params: ["note": .int(60), "port": .bool(true)],
            router: router,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            result,
            channels: [coreMidi],
            label: "send_note port bool"
        )
    }

    @Test("integer aliases reject invalid primary and conflicting values")
    func testIntegerAliasRejectsInvalidPrimaryAndConflict() async {
        let invalidRouter = ChannelRouter()
        let invalidMCU = MockChannel(id: .mcu)
        await invalidRouter.register(invalidMCU)

        let invalidPrimary = await MixerDispatcher.handle(
            command: "set_volume",
            params: ["track": .string("abc"), "index": .int(0), "value": .double(0.5)],
            router: invalidRouter,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            invalidPrimary,
            channels: [invalidMCU],
            label: "set_volume invalid track alias"
        )

        let conflictRouter = ChannelRouter()
        let conflictMCU = MockChannel(id: .mcu)
        await conflictRouter.register(conflictMCU)

        let conflictingAliases = await MixerDispatcher.handle(
            command: "set_volume",
            params: ["track": .int(2), "index": .int(0), "value": .double(0.5)],
            router: conflictRouter,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            conflictingAliases,
            channels: [conflictMCU],
            label: "set_volume conflicting track/index aliases"
        )
    }

    @Test("supported destructive confirmation requires literal bool true")
    func testDestructiveConfirmationRequiresLiteralBoolTrue() async {
        let insertRouter = ChannelRouter()
        let ax = MockChannel(id: .accessibility)
        await insertRouter.register(ax)

        let insert = await MixerDispatcher.handle(
            command: "insert_plugin",
            params: [
                "track": .int(0),
                "slot": .int(0),
                "plugin_name": .string("Gain"),
                "confirmed": .string("yes"),
            ],
            router: insertRouter,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            insert,
            channels: [ax],
            label: "insert_plugin confirmed string"
        )
    }

    @Test("play_sequence rejects top-level channel")
    func testPlaySequenceRejectsTopLevelChannel() async {
        let router = ChannelRouter()
        let coreMidi = MockChannel(id: .coreMIDI)
        await router.register(coreMidi)

        let result = await MIDIDispatcher.handle(
            command: "play_sequence",
            params: ["notes": .string("60,0,100"), "channel": .int(16)],
            router: router,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            result,
            channels: [coreMidi],
            label: "play_sequence top-level channel"
        )
    }

    @Test("note sequence parser rejects extra and empty fields")
    func testNoteSequenceParserRejectsExtraAndEmptyFields() {
        switch NoteSequenceParser.parse("60,0,100,90,1,ignored") {
        case .success(let notes):
            Issue.record("expected extra field failure, got \(notes)")
        case .failure(let error):
            guard case .malformed = error else {
                Issue.record("expected malformed extra field, got \(error)")
                return
            }
        }

        switch NoteSequenceParser.parse("60,0,100,") {
        case .success(let notes):
            Issue.record("expected trailing comma failure, got \(notes)")
        case .failure(let error):
            guard case .malformed = error else {
                Issue.record("expected malformed trailing comma, got \(error)")
                return
            }
        }
    }

    @Test("record_sequence allows SMF timing beyond realtime play_sequence cap")
    func testRecordSequenceAllowsLongSMFTimingBeforeImport() async {
        let router = ChannelRouter()
        let ax = MockChannel(id: .accessibility)
        await router.register(ax)
        let cache = StateCache()
        await cache.updateDocumentState(true)

        let result = await TrackDispatcher.handleRecordSequenceSMF(
            params: [
                "notes": .string("60,70000,100,90,1"),
                "bar": .int(1),
                "tempo": .double(120),
            ],
            router: router,
            cache: cache,
            trackHeaderCount: { 1 },
            trackNameAt: { _ in nil },
            readRegions: { .success([]) },
            settleReadback: {}
        )

        let text = sharedToolText(result)
        #expect(!text.contains("invalid timing"), "record_sequence must not inherit realtime 60s cap; got: \(text)")
        #expect(
            await ax.executedOps.map(\.0).contains("midi.import_file"),
            "long SMF timing must reach import path instead of failing parser validation; got: \(text)"
        )
    }

    @Test("play_sequence keeps realtime timing caps before routing")
    func testPlaySequenceRejectsLongRealtimeTimingBeforeRouting() async {
        let router = ChannelRouter()
        let coreMidi = MockChannel(id: .coreMIDI)
        await router.register(coreMidi)

        let result = await MIDIDispatcher.handle(
            command: "play_sequence",
            params: ["notes": .string("60,70000,100,90,1")],
            router: router,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            result,
            channels: [coreMidi],
            label: "play_sequence long realtime sequence"
        )
        let text = sharedToolText(result)
        #expect(text.contains("realtime") || text.contains("30s") || text.contains("60s"), "expected realtime cap hint, got: \(text)")
    }

    @Test("goto_marker malformed index returns invalid_params")
    func testGotoMarkerMalformedIndexReturnsInvalidParams() async {
        let router = ChannelRouter()
        let keyCmd = MockChannel(id: .midiKeyCommands)
        await router.register(keyCmd)

        let result = await NavigateDispatcher.handle(
            command: "goto_marker",
            params: ["index": .string("abc")],
            router: router,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            result,
            channels: [keyCmd],
            label: "goto_marker malformed index"
        )
    }

    @Test("import_file validates path type and shape before routing")
    func testImportFileValidatesPathTypeAndShapeBeforeRouting() async {
        let boolRouter = ChannelRouter()
        let boolAX = MockChannel(id: .accessibility)
        await boolRouter.register(boolAX)

        let boolPath = await MIDIDispatcher.handle(
            command: "import_file",
            params: ["path": .bool(true)],
            router: boolRouter,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            boolPath,
            channels: [boolAX],
            label: "import_file bool path"
        )

        let emptyRouter = ChannelRouter()
        let emptyAX = MockChannel(id: .accessibility)
        await emptyRouter.register(emptyAX)

        let emptyPath = await MIDIDispatcher.handle(
            command: "import_file",
            params: ["path": .string("")],
            router: emptyRouter,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            emptyPath,
            channels: [emptyAX],
            label: "import_file empty path"
        )

        let outsideRouter = ChannelRouter()
        let outsideAX = MockChannel(id: .accessibility)
        await outsideRouter.register(outsideAX)

        let outsideSandbox = await MIDIDispatcher.handle(
            command: "import_file",
            params: ["path": .string("/tmp/outside.mid")],
            router: outsideRouter,
            cache: StateCache()
        )

        await expectInvalidParamsWithoutRouting(
            outsideSandbox,
            channels: [outsideAX],
            label: "import_file outside sandbox"
        )
    }

    @Test("set_plugin_param accepts numeric string value")
    func testSetPluginParamAcceptsNumericStringValue() async {
        let router = ChannelRouter()
        let mcu = VerifiedSelectMockChannel(id: .mcu)
        let scripter = MockChannel(id: .scripter)
        await router.register(mcu)
        await router.register(scripter)

        let result = await MixerDispatcher.handle(
            command: "set_plugin_param",
            params: [
                "track": .int(4),
                "insert": .int(0),
                "param": .int(5),
                "value": .string("0.5"),
            ],
            router: router,
            cache: StateCache()
        )

        #expect(!(result.isError!), "numeric string value should remain compatible")
        #expect(await mcu.executedOps.map(\.0) == ["track.select"])
        let scripterOps = await scripter.executedOps
        #expect(scripterOps.count == 1)
        #expect(scripterOps.first?.0 == "plugin.set_param")
        #expect(scripterOps.first?.1["value"] == "0.5")
    }
}
