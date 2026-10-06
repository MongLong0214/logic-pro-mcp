@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// #965 name propagation only. The names originate in fake AXValue reads, not model construction.
// Existing JSON APIs compile before name fields exist. No strip-to-track association is asserted.
@Suite("#965 observed Mixer names survive the existing cache and JSON readers")
struct Issue965MixerNamePropagationTests {
    private func fixture(
        name: String = "Observed Name", label: String = "name",
        unidentified: Bool = false, ambiguous: Bool = false, failed: Bool = false
    ) -> (builder: FakeAXRuntimeBuilder, runtime: AXLogicProElements.Runtime) {
        let b = FakeAXRuntimeBuilder()
        let strip = makeLiveDumpStrip(b, id: 40_000)
        let field = b.element(40_001) // makeLiveDumpStrip's direct Name field.
        b.setAttribute(strip, kAXDescriptionAttribute as String, "Do not use strip description")
        b.setAttribute(field, kAXDescriptionAttribute as String, label)
        b.setAttribute(field, kAXValueAttribute as String, name)
        var children = b.makeAXRuntime().children(strip)
        if unidentified { children.removeAll { CFEqual($0, field) } }
        if ambiguous {
            let second = b.element(40_100)
            b.setAttribute(second, kAXRoleAttribute as String, kAXTextFieldRole as String)
            b.setAttribute(second, kAXDescriptionAttribute as String, label)
            b.setAttribute(second, kAXValueAttribute as String, "Caf\u{0065}\u{0301}")
            children.append(second)
        }
        b.setChildren(strip, children)
        _ = make123MixerFixture(stripCount: 1, firstStrip: strip, builder: b)

        // A readable header decoy makes an accidental track-name fallback observable.
        let rail = b.element(40_200)
        let header = b.element(40_201)
        let headerName = b.element(40_202)
        b.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setAttribute(headerName, kAXRoleAttribute as String, kAXTextFieldRole as String)
        b.setAttribute(headerName, kAXDescriptionAttribute as String, "Do not use header name")
        b.setAttribute(headerName, kAXValueAttribute as String, "Do not use header name")
        b.setChildren(header, [headerName])
        b.setChildren(rail, [header])
        let window = b.element(11) // make123MixerFixture's supplied main window.
        b.setChildren(window, b.makeAXRuntime().children(window) + [rail])

        let runtime = b.makeLogicRuntime(
            appElement: b.element(10),
            attributeValueHandler: { element, attribute in
                failed && CFEqual(element, field) && attribute == kAXValueAttribute as String
                    ? .some(nil) : nil
            },
            attributeValueResultHandler: { element, attribute in
                guard failed, CFEqual(element, field), attribute == kAXValueAttribute as String else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: { _, _, _ in
                Issue.record("read-only name acquisition attempted an AX write")
                return false
            },
            performActionHandler: { _, _ in
                Issue.record("read-only name acquisition attempted an AX action")
                return false
            },
            performActionResultHandler: { _, _ in
                Issue.record("read-only name acquisition attempted a status-preserving AX action")
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            executeAppleScript: { _ in
                Issue.record("synthetic name fixture reached AppleScript")
                return .error("AppleScript is unavailable in this synthetic fixture")
            }
        )
        return (b, runtime)
    }

    private func producerRows(
        _ runtime: AXLogicProElements.Runtime
    ) throws -> [(path: String, raw: String, row: [String: Any])] {
        let mixer = AccessibilityChannel.defaultGetMixerState(runtime: runtime)
        let strip = AccessibilityChannel.defaultGetChannelStrip(params: ["index": "0"], runtime: runtime)
        #expect(mixer.isSuccess)
        #expect(strip.isSuccess)
        let rows = try #require(try sharedParseJSON(mixer.message) as? [[String: Any]])
        #expect(rows.count == 1)
        return [
            ("mixer", mixer.message, try #require(rows.first)),
            ("strip", strip.message, try #require(sharedJSONObject(strip.message))),
        ]
    }

    private func decodedRows(path: String, raw: String) throws -> [ChannelStripState] {
        let data = Data(raw.utf8)
        if path == "mixer" { return try JSONDecoder().decode([ChannelStripState].self, from: data) }
        return [try JSONDecoder().decode(ChannelStripState.self, from: data)]
    }

    private func cached(_ strips: [ChannelStripState]) async -> StateCache {
        let cache = StateCache()
        await cache.updateDocumentState(true)
        await cache.updateTracks([TrackState(id: 0, name: "Do not use cached track name", type: .audio)])
        await cache.updateChannelStrips(strips)
        return cache
    }

    private func inspectionRow(_ cache: StateCache) async throws -> [String: Any] {
        let captureTime = await cache.getMixerFetchedAt()
        let capture = await SessionPopulationObservation.capture(
            cache: cache, targetRegistry: nil, fileReader: .unavailable, now: { captureTime }
        )
        let report = SessionPopulationObservation.build(
            request: .init(domains: [.strips, .associations]), capture: capture
        )
        let object = try #require(sharedJSONObject(try encodeJSONStrict(report, compact: true)))
        let strips = try #require(object["strips"] as? [String: Any])
        #expect(strips["coverage"] as? String == "partial")
        let associations = try #require(object["associations"] as? [String: Any])
        #expect(associations["coverage"] as? String == "unavailable")
        let rows = try #require(strips["rows"] as? [[String: Any]])
        #expect(rows.count == 1)
        return try #require(rows.first)
    }

    private func expectNameBytes(_ row: [String: Any], _ expected: String) {
        if let observed = row["name"] as? String {
            #expect(Array(observed.utf8) == Array(expected.utf8))
        } else {
            Issue.record("the JSON reader omitted the observed Name-field value")
        }
        #expect(row["name_read_error"] == nil)
    }

    @Test func mixerReadersPublishObservedRawNameBytes() throws {
        for (name, label) in [(" Bass ", "name"), ("Caf\u{0065}\u{0301}", "이름"), ("0", "name")] {
            let f = fixture(name: name, label: label)
            let direct = try #require(try AXPluginInstanceIdentity.stripNameResult(
                f.builder.element(40_000), runtime: f.runtime.ax
            ).get())
            try #require(Array(direct.utf8) == Array(name.utf8))
            for observed in try producerRows(f.runtime) { expectNameBytes(observed.row, name) }
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test func producerNamesSurviveCacheResourcesAndInspection() async throws {
        for name in [" Bass ", "Caf\u{0065}\u{0301}", "0"] {
            let f = fixture(name: name)
            let direct = try #require(try AXPluginInstanceIdentity.stripNameResult(
                f.builder.element(40_000), runtime: f.runtime.ax
            ).get())
            try #require(Array(direct.utf8) == Array(name.utf8))
            for observed in try producerRows(f.runtime) {
                let cache = await cached(try decodedRows(path: observed.path, raw: observed.raw))
                let mixer = try await ResourceHandlers.readMixer(cache: cache, uri: "logic://mixer", targetRegistry: nil)
                let mixerObject = try #require(sharedJSONObject(sharedResourceText(mixer)))
                let mixerRows = try #require(mixerObject["strips"] as? [[String: Any]])
                expectNameBytes(try #require(mixerRows.first), name)
                let strip = try await ResourceHandlers.readMixerStrip(at: 0, cache: cache, uri: "logic://mixer/0", targetRegistry: nil)
                let stripObject = try #require(sharedJSONObject(sharedResourceText(strip)))
                expectNameBytes(try #require(stripObject["strip"] as? [String: Any]), name)
                let inspected = try await inspectionRow(cache)
                expectNameBytes(inspected, name)
                #expect(inspected["name_status"] as? String == "observed")
            }
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test func unidentifiedAndFailedNameReadsStayUnknownWithoutFallback() async throws {
        for mode in ["unidentified", "ambiguous", "failed", "blank"] {
            let f = fixture(
                name: mode == "blank" ? " \n " : "Caf\u{00E9}", unidentified: mode == "unidentified",
                ambiguous: mode == "ambiguous", failed: mode == "failed"
            )
            let direct = AXPluginInstanceIdentity.stripNameResult(
                f.builder.element(40_000), runtime: f.runtime.ax
            )
            if mode == "failed" {
                guard case .failure(let error) = direct else {
                    Issue.record("failed Name-field fixture did not reach the injected AX failure")
                    return
                }
                try #require(error.raw == AXError.cannotComplete.rawValue)
            } else {
                let name = try direct.get()
                try #require(name == nil)
            }
            for observed in try producerRows(f.runtime) {
                #expect(observed.row["name"] == nil || observed.row["name"] is NSNull)
                if let error = observed.row["name_read_error"] as? String {
                    #expect(!error.isEmpty)
                } else {
                    Issue.record("an attempted unidentified or failed name read needs an unknown reason")
                }
                let cache = await cached(try decodedRows(path: observed.path, raw: observed.raw))
                let inspected = try await inspectionRow(cache)
                #expect(inspected["name"] is NSNull)
                #expect(inspected["name_status"] as? String == "unknown")
            }
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test func pollerAndPublicInspectionReplaceAnOldNameWithUnknown() async throws {
        let cache = StateCache()
        let observedName = " Bass\u{0065}\u{0301} "
        for failed in [false, true] {
            let f = fixture(name: observedName, failed: failed)
            // Only the Mixer getter uses AX, through the complete fake runtime above. All
            // other poller getters and the project-file reader are inert; no live host access.
            let channel = AccessibilityChannel(runtime: .init(
                isTrusted: { true }, isLogicProRunning: { true }, appRoot: { nil },
                transportState: { .success("{}") },
                toggleTransportButton: { _ in .error("unexpected mutation") },
                setTempo: { _ in .error("unexpected mutation") },
                setCycleRange: { _ in .error("unexpected mutation") },
                tracks: { .success("[]") }, trackStates: { [] },
                selectedTrack: { .success("{}") },
                selectTrack: { _ in .error("unexpected mutation") },
                setTrackToggle: { _, _ in .error("unexpected mutation") },
                renameTrack: { _ in .error("unexpected mutation") },
                mixerState: { AccessibilityChannel.defaultGetMixerState(runtime: f.runtime) },
                channelStrip: { _ in .error("unexpected getter") },
                setMixerValue: { _, _ in .error("unexpected mutation") },
                projectInfo: { .success(#"{"name":"Inert","sampleRate":44100,"bitDepth":24,"tempo":120,"timeSignature":"4/4","trackCount":0,"filePath":null,"lastUpdated":"2026-04-16T00:00:00Z"}"#) },
                markers: { .success("[]") }
            ))
            let poller = StatePoller(
                axChannel: channel, cache: cache, runtime: .init(hasVisibleWindow: { true })
            )
            let refreshed = await poller.refreshNow()
            #expect(refreshed)
            let result = await ProjectDispatcher.handle(
                command: "inspect_session",
                params: ["domains": .array([.string("strips"), .string("associations")])],
                router: ChannelRouter(), cache: cache, targetRegistry: nil,
                cleanupAuditFileReader: .unavailable
            )
            let isError = result.isError ?? false
            #expect(!isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let strips = try #require(body["strips"] as? [String: Any])
            #expect(strips["coverage"] as? String == "partial")
            let rows = try #require(strips["rows"] as? [[String: Any]])
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            if failed {
                #expect(row["name"] is NSNull)
                #expect(row["name_status"] as? String == "unknown")
                let reason = try #require(row["name_read_error"] as? String)
                #expect(!reason.isEmpty)
            } else {
                expectNameBytes(row, observedName)
                #expect(row["name_status"] as? String == "observed")
            }
            let associations = try #require(body["associations"] as? [String: Any])
            #expect(associations["coverage"] as? String == "unavailable")
            #expect(f.builder.setCalls.isEmpty)
            #expect(f.builder.actionCalls.isEmpty)
        }
    }

    @Test func legacyMixerPayloadKeepsNameNotRead() async throws {
        let legacy = #"{"trackIndex":0,"volume":0,"pan":0,"eqEnabled":false,"plugins":[]}"#
        let decoded = try JSONDecoder().decode(ChannelStripState.self, from: Data(legacy.utf8))
        let encoded = try #require(sharedJSONObject(try encodeJSONStrict(decoded, compact: true)))
        #expect(encoded["name"] == nil)
        #expect(encoded["name_read_error"] == nil)
        let cache = await cached([decoded])
        let inspected = try await inspectionRow(cache)
        #expect(inspected["name"] is NSNull)
        #expect(inspected["name_status"] as? String == "not_read")
    }
}
