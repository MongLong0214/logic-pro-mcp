import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #1040: `extractTrackState` read Mute, Solo and Record Enable with `?? false`, so a control that
/// was not found, or whose value would not read, was published as a confirmed `false`. A reader of
/// `logic://tracks` could not tell "this track is unmuted" from "nobody read this track's mute".
///
/// Each test names the mutation that turns it red. The three toggle mutations are the pre-#1040
/// line restored on one field: `?? false` after the Mute read, after the Solo read, or after the
/// Record Enable read in `AXValueExtractors.extractTrackState`.
///
/// The reads go through `reading(_:)` and `isUnread(_:)`, which take `Bool?`. Comparing an
/// `Optional<Bool>` inside `#expect` is dead on this toolchain in both directions, so the
/// comparison is made in an ordinary function and the macro is handed a plain `Bool`.
@Suite("Issue1040 track-header toggles read unknown, not false")
struct Issue1040TrackHeaderToggleReadTests {
    enum Toggle: String, CaseIterable, Sendable {
        case mute, solo, recordEnable
    }

    private struct Header {
        let builder: FakeAXRuntimeBuilder
        let header: AXUIElement
        let controls: [Toggle: AXUIElement]
    }

    /// A header shaped like the one Logic 12.3 draws: an `AXLayoutItem` whose toggles are
    /// `AXCheckBox` children described as an English Logic describes them. `omit` leaves one out;
    /// every other control is present and readable, so the header itself is not the thing unread.
    private func makeHeader(on: Bool, omit: Toggle? = nil) -> Header {
        let b = FakeAXRuntimeBuilder()
        let header = b.element(1)
        b.setAttribute(header, kAXRoleAttribute, "AXLayoutItem")
        let descriptions: [Toggle: String] = [
            .mute: AXLocalePolicy.trackMuteButton.canonical,
            .solo: AXLocalePolicy.trackSoloButton.canonical,
            .recordEnable: "Record Enable",
        ]
        var controls: [Toggle: AXUIElement] = [:]
        var children: [AXUIElement] = []
        for (offset, toggle) in Toggle.allCases.enumerated() where toggle != omit {
            let e = b.element(10 + offset)
            b.setAttribute(e, kAXRoleAttribute, "AXCheckBox")
            b.setAttribute(e, kAXDescriptionAttribute, descriptions[toggle] ?? "")
            b.setAttribute(e, kAXValueAttribute, on ? 1 : 0)
            controls[toggle] = e
            children.append(e)
        }
        b.setChildren(header, children)
        return Header(builder: b, header: header, controls: controls)
    }

    private func reading(_ value: Bool?) -> Bool? { value }

    private func isUnread(_ value: Bool?) -> Bool { value == nil }

    private func value(of toggle: Toggle, in track: TrackState) -> Bool? {
        switch toggle {
        case .mute: reading(track.isMuted)
        case .solo: reading(track.isSoloed)
        case .recordEnable: reading(track.isArmed)
        }
    }

    /// Kills: `?? false` restored after the read of the toggle under test.
    @Test("a header without the control reads it as unknown", arguments: Toggle.allCases)
    func missingControlIsUnknown(_ toggle: Toggle) throws {
        let h = makeHeader(on: true, omit: toggle)
        let track = AXValueExtractors.extractTrackState(
            from: h.header, index: 0, runtime: h.builder.makeAXRuntime())
        #expect(isUnread(value(of: toggle, in: track)), "\(toggle.rawValue)")
        // The other two were on the header and lit, so this is not a header nobody read.
        for other in Toggle.allCases where other != toggle {
            let lit = try #require(value(of: other, in: track), "\(other.rawValue)")
            #expect(lit, "\(other.rawValue)")
        }
    }

    /// Kills: `?? false` restored after the read of the toggle under test.
    @Test("a control whose value will not read is unknown", arguments: Toggle.allCases)
    func unreadableValueIsUnknown(_ toggle: Toggle) throws {
        let h = makeHeader(on: true)
        let builder = h.builder
        let targetID = builder.elementID(try #require(h.controls[toggle]))
        let runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                guard attribute == kAXValueAttribute as String, builder.elementID(element) == targetID else {
                    return nil
                }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let track = AXValueExtractors.extractTrackState(from: h.header, index: 0, runtime: runtime)
        #expect(isUnread(value(of: toggle, in: track)), "\(toggle.rawValue)")
    }

    /// Kills: a read that drops the value it found, for example `extractButtonState` answering nil
    /// for 1 or for 0. Without this, "always unknown" would satisfy the two tests above.
    @Test("a readable control still reads true or false", arguments: [true, false])
    func readableControlReadsItsValue(_ on: Bool) throws {
        let h = makeHeader(on: on)
        let track = AXValueExtractors.extractTrackState(
            from: h.header, index: 0, runtime: h.builder.makeAXRuntime())
        for toggle in Toggle.allCases {
            let read = try #require(value(of: toggle, in: track), "\(toggle.rawValue)")
            #expect(on ? read : !read, "\(toggle.rawValue) on=\(on)")
        }
    }
}

/// The project audit over `tracks`, with every other section read and fresh, so a finding comes from
/// the tracks alone.
private func auditOf(_ tracks: [TrackState]) -> ProjectSessionAudit.AuditReport {
    let now = Date(timeIntervalSince1970: 1_730_000_000)
    var project = ProjectInfo()
    project.name = "Fixture Session"
    project.filePath = "/tmp/Fixture Session.logicx"
    project.source = "ax_live"
    project.trackCount = tracks.count
    var transport = TransportState()
    transport.tempo = 126
    transport.lastUpdated = now
    return ProjectSessionAudit.buildAudit(snapshot: ProjectSessionAudit.Snapshot(
        now: now, hasDocument: true, axOccluded: false,
        project: project, projectFetchedAt: now,
        transport: transport,
        tracks: tracks, tracksFetchedAt: now,
        regions: [], regionsFetchedAt: now, regionsComplete: true,
        markers: [], markersFetchedAt: now,
        channelStrips: [], mixerFetchedAt: now,
        fileTrackCount: nil, blockingDialogButtons: nil
    ))
}

/// The consumers of an unread toggle (#1040). Each decides something from Mute, Solo or Record
/// Enable, and each must take `nil` as "nobody read it", not as off.
@Suite("Issue1040 consumers take an unread toggle as unread")
struct Issue1040UnreadToggleConsumerTests {
    private func isUnread(_ value: Bool?) -> Bool { value == nil }

    /// A row as a header read leaves it with every toggle read off. Written out: a row built without
    /// one starts unread, since #1040's MCU finding.
    private func readTrack(_ id: Int, _ name: String, type: TrackType = .audio) -> TrackState {
        TrackState(id: id, name: name, type: type, isMuted: false, isSoloed: false, isArmed: false)
    }

    private func unreadTrack(_ id: Int, _ name: String, mute: Bool = false, solo: Bool = false, arm: Bool = false) -> TrackState {
        var track = readTrack(id, name)
        if mute { track.isMuted = nil }
        if solo { track.isSoloed = nil }
        if arm { track.isArmed = nil }
        return track
    }

    /// Kills: `decode(Bool.self, forKey:)` restored for any of the three in `TrackState.init(from:)`
    /// (a row written without the key no longer decodes), and a nil that is written as `false`.
    @Test("an unread toggle leaves the wire as an absent key and comes back unread")
    func unreadToggleRoundTripsAsAbsent() throws {
        let track = unreadTrack(0, "Vox", mute: true, solo: true, arm: true)
        let wire = String(decoding: try JSONEncoder().encode(track), as: UTF8.self)
        for key in ["isMuted", "isSoloed", "isArmed"] {
            #expect(!wire.contains("\"\(key)\""), "\(key) in \(wire)")
        }
        let back = try JSONDecoder().decode(TrackState.self, from: Data(wire.utf8))
        #expect(isUnread(back.isMuted))
        #expect(isUnread(back.isSoloed))
        #expect(isUnread(back.isArmed))

        // The control: a toggle that was read as off stays a read `false` on the wire and back.
        let read = readTrack(1, "Bass")
        let readWire = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        #expect(readWire.contains("\"isMuted\":false"), "\(readWire)")
        let readBack = try JSONDecoder().decode(TrackState.self, from: Data(readWire.utf8))
        let muted = try #require(readBack.isMuted)
        #expect(!muted)
    }

    /// Kills: the disarm sweep reading an unread arm as disarmed (`t.isArmed == true` as the loop's
    /// filter), which reports State A over a track nobody read, and a sweep that sends that track a
    /// disarm, which on an unreadable checkbox can only be a press.
    @Test("arm_only reports an unread arm unverified and sends it nothing")
    func armOnlyLeavesAnUnreadArmUnverified() async throws {
        let router = ChannelRouter()
        let channel = RecordingArmChannel()
        await router.register(channel)
        let cache = StateCache()
        await cache.updateTracks([
            unreadTrack(0, "Unread", arm: true),
            readTrack(1, "Target", type: .softwareInstrument),
            readTrack(2, "Disarmed"),
        ])

        let result = await TrackDispatcher.handle(
            command: "arm_only", params: ["index": .int(1)], router: router, cache: cache)

        let data = Data(sharedToolText(result).utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["state"] as? String == "B")
        #expect(object["reason"] as? String == "readback_unavailable")
        #expect(object["unverifiedDisarm"] as? [Int] == [0])
        #expect(object["disarmed"] as? [Int] == [])
        #expect(await channel.writes == ["1:true"])
    }

    /// Kills: dropping `track_toggles_unread`, or filling its lists with anything but nil. Without
    /// it an unread Solo passes as "no track is soloed" and the export reads `review_ready`.
    @Test("the audit names an unread toggle and holds the export for review")
    func auditNamesUnreadToggles() throws {
        let read = [
            readTrack(0, "Kick"),
            readTrack(1, "Bass"),
            readTrack(2, "Keys"),
        ]
        let control = auditOf(read)
        #expect(control.evidence.exportReadiness.status == "review_ready")
        #expect(!control.findings.contains { $0.id == "track_toggles_unread" })

        let report = auditOf([read[0], unreadTrack(1, "Bass", solo: true), unreadTrack(2, "Keys", mute: true, arm: true)])
        let finding = try #require(report.findings.first { $0.id == "track_toggles_unread" })
        #expect(finding.evidence.target == "1,2")
        #expect(finding.evidence.values == [
            "unread_mute_indices=2", "unread_solo_indices=1", "unread_arm_indices=2",
        ])
        #expect(report.evidence.exportReadiness.status == "review_required")
        #expect(report.evidence.tracks.soloedIndices == [])
        #expect(report.evidence.tracks.mutedIndices == [])
        #expect(report.evidence.tracks.armedIndices == [])
    }
}

/// Answers every `track.set_arm` as a verified write and keeps the order it was asked in.
private actor RecordingArmChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private(set) var writes: [String] = []

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard operation == "track.set_arm" else { return .success("Mock: \(operation)") }
        let index = Int(params["index"] ?? "") ?? -1
        let enabled = (params["enabled"] ?? "true") == "true"
        writes.append("\(index):\(enabled)")
        return .success(HonestContract.encodeStateA(extras: [
            "track": index, "enabled": enabled, "function": "recArm",
            "observed": enabled, "verification_source": "mock_ax_readback",
        ]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "recording arm channel")
    }
}

/// #1040 residual 1: Input Monitoring had no LabelSet, so nothing read it into `TrackState`. It is now
/// found by `AXLocalePolicy.trackInputMonitoringButton`, whose members are Apple's own rows in every
/// locale Logic ships, and read on the same terms as Mute and Solo: true, false, or unread.
@Suite("Issue1040 Input Monitoring reads through its LabelSet")
struct Issue1040InputMonitoringReadTests {
    private struct Header {
        let builder: FakeAXRuntimeBuilder
        let header: AXUIElement
        let monitor: AXUIElement?
    }

    /// A header with lit Mute, Solo and Record Enable checkboxes, plus an Input Monitoring checkbox
    /// described `monitorLabel` (none when nil). The lit neighbours show that the header was read.
    private func makeHeader(monitorLabel: String?, on: Bool) -> Header {
        let b = FakeAXRuntimeBuilder()
        let header = b.element(1)
        b.setAttribute(header, kAXRoleAttribute, "AXLayoutItem")
        var children: [AXUIElement] = []
        let neighbours = [
            AXLocalePolicy.trackMuteButton.canonical, AXLocalePolicy.trackSoloButton.canonical, "Record Enable",
        ]
        for (offset, label) in neighbours.enumerated() {
            let e = b.element(10 + offset)
            b.setAttribute(e, kAXRoleAttribute, "AXCheckBox")
            b.setAttribute(e, kAXDescriptionAttribute, label)
            b.setAttribute(e, kAXValueAttribute, 1)
            children.append(e)
        }
        var monitor: AXUIElement?
        if let monitorLabel {
            let e = b.element(20)
            b.setAttribute(e, kAXRoleAttribute, "AXCheckBox")
            b.setAttribute(e, kAXDescriptionAttribute, monitorLabel)
            b.setAttribute(e, kAXValueAttribute, on ? 1 : 0)
            children.append(e)
            monitor = e
        }
        b.setChildren(header, children)
        return Header(builder: b, header: header, monitor: monitor)
    }

    private func isUnread(_ value: Bool?) -> Bool { value == nil }

    private func neighboursRead(_ track: TrackState) -> Bool {
        track.isMuted == true && track.isSoloed == true && track.isArmed == true
    }

    /// Kills: dropping the read from `extractTrackState` (the field left nil), and dropping
    /// `trackInputMonitoringButton` from `extractTrackButtonState`'s label map, where the English
    /// fallback still finds `Input Monitoring` but no other language.
    @Test("each member of the LabelSet is found and read as true or false",
          arguments: AXLocalePolicy.trackInputMonitoringButton.labels)
    func everyMemberReads(_ label: String) throws {
        for on in [true, false] {
            let h = makeHeader(monitorLabel: label, on: on)
            let track = AXValueExtractors.extractTrackState(
                from: h.header, index: 0, runtime: h.builder.makeAXRuntime())
            let read = try #require(track.isInputMonitoring, "\(label) on=\(on)")
            #expect(on ? read : !read, "\(label) on=\(on)")
        }
    }

    /// The set is Apple's row in all ten locales Logic ships, one member each (English is the base).
    /// Kills: a member dropped from `variants`, which leaves that locale's control unread.
    @Test("the LabelSet holds one member per locale Logic ships")
    func memberPerLocale() {
        let expected: Set<String> = [
            "Input Monitoring", "입력 모니터링", "入力モニタリング", "Input-Monitoring",
            "Monitorización de entrada", "Monitoring de l’entrée", "Monitoraggio ingresso",
            "Monitoramento de Entrada", "输入监听", "輸入監聽",
        ]
        #expect(Set(AXLocalePolicy.trackInputMonitoringButton.labels) == expected)
    }

    /// `allLabelSets` is the allowlist an AX snapshot records labels verbatim under; a set missing
    /// from it is written as a shape, and a fixture taken from that snapshot no longer matches it.
    /// Kills: leaving `trackInputMonitoringButton` out of `allLabelSets`.
    @Test("the set is registered in allLabelSets")
    func registered() {
        #expect(AXLocalePolicy.allLabelSets.contains(AXLocalePolicy.trackInputMonitoringButton))
    }

    /// Kills: `?? false` after the Input Monitoring read.
    @Test("a header without the control, or with a description outside the set, reads it as unread",
          arguments: [nil, "Monitor de entrada"] as [String?])
    func missingOrUnknownLabelIsUnread(_ label: String?) {
        let h = makeHeader(monitorLabel: label, on: true)
        let track = AXValueExtractors.extractTrackState(
            from: h.header, index: 0, runtime: h.builder.makeAXRuntime())
        #expect(neighboursRead(track))
        #expect(isUnread(track.isInputMonitoring), "\(label ?? "no control")")
    }

    /// Kills: `?? false` after the Input Monitoring read.
    @Test("a control whose value will not read is unread")
    func unreadableValueIsUnread() throws {
        let h = makeHeader(monitorLabel: AXLocalePolicy.trackInputMonitoringButton.canonical, on: true)
        let builder = h.builder
        let targetID = builder.elementID(try #require(h.monitor))
        let runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                guard attribute == kAXValueAttribute as String, builder.elementID(element) == targetID else {
                    return nil
                }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let track = AXValueExtractors.extractTrackState(from: h.header, index: 0, runtime: runtime)
        #expect(neighboursRead(track))
        #expect(isUnread(track.isInputMonitoring))
    }

    /// Kills: `decode` in place of `decodeIfPresent` for `isInputMonitoring`, under which a row
    /// written without the key no longer decodes.
    @Test("an unread Input Monitoring is an absent key; a read one round-trips")
    func wireShape() throws {
        let unread = TrackState(id: 0, name: "Vox", type: .audio)
        let unreadWire = String(decoding: try JSONEncoder().encode(unread), as: UTF8.self)
        #expect(!unreadWire.contains("\"isInputMonitoring\""), "\(unreadWire)")
        let unreadBack = try JSONDecoder().decode(TrackState.self, from: Data(unreadWire.utf8))
        #expect(isUnread(unreadBack.isInputMonitoring))

        var read = TrackState(id: 1, name: "Gtr", type: .audio)
        read.isInputMonitoring = true
        let readWire = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        #expect(readWire.contains("\"isInputMonitoring\":true"), "\(readWire)")
        let readBack = try JSONDecoder().decode(TrackState.self, from: Data(readWire.utf8))
        let on = try #require(readBack.isInputMonitoring)
        #expect(on)
    }
}

/// #1040, live on 2026-09-28 (ko, Logic 12.3): in the `logic://tracks` read taken right after a
/// track was armed, the rows came from MCU feedback, not from a header read, and the armed track
/// was published `isArmed: false`. MCU feedback never writes `isArmed` (the Rec LED blinks, #1020),
/// so that `false` was the struct's default: a Record Enable nobody read, published as off. Nothing
/// in the JSON marked the row: `source` was `ax_live`, and `liveIdentityBacked` is not encoded.
@Suite("Issue1040 rows built without a header read publish no toggle")
struct Issue1040RowsWithoutHeaderReadTests {
    private func isUnread(_ value: Bool?) -> Bool { value == nil }
    private func reading(_ value: Bool?) -> Bool? { value }

    private let headlessFileReader = LogicProjectFileReader.Runtime(
        currentDocumentPath: { nil },
        now: Date.init,
        readPlistData: { _ in nil },
        mtime: { _ in nil },
        sleep: { _ in }
    )

    /// Kills: `= false` restored as the default of `isMuted`, `isSoloed` or `isArmed` in
    /// `TrackState`. The row MCU feedback creates then carries that `false` onto the wire. Also
    /// kills the MCU Mute LED written into `isMuted` (`$0.isMuted = button.on` in
    /// `MCUFeedbackParser`), which puts `isMuted: true` on row 2.
    @Test("a row MCU feedback creates carries only what the feedback reported")
    func mcuCreatedRowPublishesOnlyWhatItHeard() async throws {
        let cache = StateCache()
        let parser = MCUFeedbackParser(cache: cache)
        // Strip 2's Solo LED on (note 0x0A), into a cache no header read has filled: the parser
        // creates rows 0, 1 and 2 to hold it. Then strip 2's Mute LED on (note 0x12), which is not
        // the header's Mute and is not written.
        await parser.handle(.noteOn(channel: 0, note: 0x0A, velocity: 0x7F))
        await parser.handle(.noteOn(channel: 0, note: 0x12, velocity: 0x7F))

        let tracks = await cache.getTracks()
        #expect(tracks.count == 3)
        let soloed = try #require(reading(tracks[2].isSoloed))
        #expect(soloed)
        #expect(isUnread(tracks[2].isMuted))
        #expect(isUnread(tracks[2].isArmed))
        #expect(isUnread(tracks[0].isMuted) && isUnread(tracks[0].isSoloed) && isUnread(tracks[0].isArmed))

        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", fileReader: headlessFileReader
        )
        let document = try #require(sharedJSONObject(sharedResourceText(result)))
        let rows = try #require(document["data"] as? [[String: Any]])
        #expect(rows.count == 3)
        let row2 = try #require(rows.first { ($0["id"] as? Int) == 2 })
        let soloedOnTheWire = try #require(row2["isSoloed"] as? Bool)
        #expect(soloedOnTheWire)
        #expect(!row2.keys.contains("isArmed"))
        #expect(!row2.keys.contains("isMuted"))
        let row0 = try #require(rows.first { ($0["id"] as? Int) == 0 })
        #expect(!row0.keys.contains("isMuted"))
        #expect(!row0.keys.contains("isSoloed"))
        #expect(!row0.keys.contains("isArmed"))
    }
}

/// #1040 review round 1 (R1-1040-01): `MCUFeedbackParser` wrote the MCU Mute LED into
/// `TrackState.isMuted`, which is the track header's Mute checkbox. Logic lights that LED on every
/// strip a solo silences, so on 2026-09-28 in es-ES a silenced track whose checkbox read 0 was
/// published `isMuted: true`. The LED no longer writes `isMuted` at all.
@Suite("Issue1040 a solo-induced MCU Mute LED is not the header's Mute")
struct Issue1040MCUMuteLEDTests {
    private let headlessFileReader = LogicProjectFileReader.Runtime(
        currentDocumentPath: { nil },
        now: Date.init,
        readPlistData: { _ in nil },
        mtime: { _ in nil },
        sleep: { _ in }
    )

    /// Track 3 as a header read leaves it: Mute reads `muteValue`, Solo and Record Enable read 0.
    private func headerRead(muteValue: Int) -> TrackState {
        let b = FakeAXRuntimeBuilder()
        let header = b.element(1)
        b.setAttribute(header, kAXRoleAttribute, "AXLayoutItem")
        let controls: [(String, Int)] = [
            (AXLocalePolicy.trackMuteButton.canonical, muteValue),
            (AXLocalePolicy.trackSoloButton.canonical, 0),
            ("Record Enable", 0),
        ]
        var children: [AXUIElement] = []
        for (offset, control) in controls.enumerated() {
            let e = b.element(10 + offset)
            b.setAttribute(e, kAXRoleAttribute, "AXCheckBox")
            b.setAttribute(e, kAXDescriptionAttribute, control.0)
            b.setAttribute(e, kAXValueAttribute, control.1)
            children.append(e)
        }
        b.setChildren(header, children)
        return AXValueExtractors.extractTrackState(from: header, index: 3, runtime: b.makeAXRuntime())
    }

    /// Track 3's Mute checkbox reads 0 (the solo silences it without muting it) or -1 (what the
    /// walks in de, en, it, pt and zh_CN read on the silenced track at least once), and 1 as the
    /// control: a Mute the header did read on still reaches `logic://tracks` and the audit.
    ///
    /// Kills: the LED write restored (`$0.isMuted = button.on`), red on the 0 and -1 cases; and the
    /// LED filling only an unread Mute (`$0.isMuted = $0.isMuted ?? button.on`), red on -1.
    @Test("the Mute LED lit by another track's solo leaves the header's reading as it was",
          arguments: [0, -1, 1])
    func soloInducedMuteLEDIsNotPublished(_ muteValue: Int) async throws {
        let cache = StateCache()
        let parser = MCUFeedbackParser(cache: cache)
        var rows = (0..<3).map {
            TrackState(id: $0, name: "Track \($0 + 1)", type: .audio, isMuted: false, isSoloed: false, isArmed: false)
        }
        rows.append(headerRead(muteValue: muteValue))
        await cache.updateTracks(rows)

        // Track 2 soloed: Logic lights its Solo LED (note 0x0A) and the Mute LED of the strips the
        // solo silences, here strip 3 (note 0x13).
        await parser.handle(.noteOn(channel: 0, note: 0x0A, velocity: 0x7F))
        await parser.handle(.noteOn(channel: 0, note: 0x13, velocity: 0x7F))

        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", fileReader: headlessFileReader
        )
        let document = try #require(sharedJSONObject(sharedResourceText(result)))
        let published = try #require(document["data"] as? [[String: Any]])
        let row3 = try #require(published.first { ($0["id"] as? Int) == 3 })
        let report = auditOf(await cache.getTracks())

        switch muteValue {
        case 1:
            let muted = try #require(row3["isMuted"] as? Bool)
            #expect(muted)
            #expect(report.evidence.tracks.mutedIndices == [3])
        case 0:
            let muted = try #require(row3["isMuted"] as? Bool, "\(row3)")
            #expect(!muted, "\(row3)")
            #expect(report.evidence.tracks.mutedIndices == [])
        default:
            #expect(!row3.keys.contains("isMuted"), "\(row3)")
            #expect(report.evidence.tracks.mutedIndices == [])
        }
        // The Solo LED is still written: track 2 reads soloed.
        let row2 = try #require(published.first { ($0["id"] as? Int) == 2 })
        let soloed = try #require(row2["isSoloed"] as? Bool)
        #expect(soloed)
    }
}
