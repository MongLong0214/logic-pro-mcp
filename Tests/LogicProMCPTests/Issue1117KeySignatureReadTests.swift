@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

struct KeySignatureRow: Sendable {
    let description: String
    let value: String
}

// EN/DE topology and values: the archived navigation-free AX census, not a new live run.
// docs/observations/evidence/2026-09-12-en-US-navigation-free.census.json:6108
// docs/observations/evidence/2026-09-12-de-DE-navigation-free.census.json:6108
private let measuredKeyRows = [
    KeySignatureRow(description: "Key Signature", value: "C Major"),
    KeySignatureRow(description: "Tonart", value: "C-Dur"),
]

// Apple's own description row. These fixtures are derivation, not ten-locale AX qualification.
// logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/en/Key%20Signature#value
private let derivedKeyDescriptions = [
    "Key Signature",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Key%20Signature#value
    "조표",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ja/Key%20Signature#value
    "キー",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/de/Key%20Signature#value
    "Tonart",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/es/Key%20Signature#value
    "Armadura",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/fr/Key%20Signature#value
    "Armature",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/it/Key%20Signature#value
    "Armatura",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/pt/Key%20Signature#value
    "Armadura",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/zh_CN/Key%20Signature#value
    "调号",
    // logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/zh_TW/Key%20Signature#value
    "調號",
]

private struct KeySignatureFixture {
    let builder = FakeAXRuntimeBuilder()
    let bar: AXUIElement
    let group: AXUIElement
    let popup: AXUIElement
    let sibling: AXUIElement

    init(description: String = derivedKeyDescriptions[0], value: Any? = "D Minor") {
        bar = builder.element(111_700)
        group = builder.element(111_701)
        popup = builder.element(111_702)
        sibling = builder.element(111_703)
        for element in [bar, group, sibling] {
            builder.setAttribute(element, kAXRoleAttribute as String, kAXGroupRole as String)
        }
        builder.setAttribute(popup, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
        builder.setAttribute(popup, kAXDescriptionAttribute as String, description)
        if let value { builder.setAttribute(popup, kAXValueAttribute as String, value) }
        builder.setChildren(bar, [group, sibling])
        builder.setChildren(group, [popup])
    }

    func read(runtime: AXHelpers.Runtime? = nil) throws -> [String: Any] {
        let state = AXValueExtractors.extractTransportState(
            from: bar, runtime: runtime ?? builder.makeAXRuntime()
        )
        return try keyStateJSON(state)
    }

    func checkReadOnly() {
        #expect(builder.setCalls.isEmpty)
        #expect(builder.actionCalls.isEmpty)
    }
}

private func keyStateJSON(_ state: TransportState) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try #require(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
}

private func keyStatePayload(_ key: String?) throws -> Data {
    var json = try keyStateJSON(TransportState())
    json["lastUpdated"] = "2026-09-12T00:00:00Z"
    if let key { json["keySignature"] = key }
    return try JSONSerialization.data(withJSONObject: json)
}

private func decodeKeyState(_ data: Data) throws -> TransportState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TransportState.self, from: data)
}

private actor KeySignatureStateChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    let payload: String
    var calls = 0

    init(payload: String) { self.payload = payload }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "hermetic key read") }
    func execute(operation: String, params _: [String: String]) async -> ChannelResult {
        guard operation == "transport.get_state" else { return .error("unexpected operation") }
        calls += 1
        return calls == 1 ? .success(payload) : .error("key fixture refresh failed")
    }
}

@Suite("#1117 current key signature is observed, never defaulted", .serialized)
struct Issue1117KeySignatureReadTests {
    @Test(arguments: measuredKeyRows)
    func readsArchivedPopup(row: KeySignatureRow) throws {
        let fixture = KeySignatureFixture(description: row.description, value: row.value)
        let json = try fixture.read()
        #expect(json["keySignature"] as? String == row.value)
        fixture.checkReadOnly()
    }

    @Test(arguments: derivedKeyDescriptions)
    func recognizesOwnDescription(description: String) throws {
        let fixture = KeySignatureFixture(description: description, value: "opaque observed value")
        let json = try fixture.read()
        #expect(json["keySignature"] as? String == "opaque observed value")
        fixture.checkReadOnly()
    }

    @Test(arguments: ["D Minor", "F♯ Minor", "B♭ Major", "C-Dur", " \u{00A0}raw key\u{00A0} "])
    func preservesRawValueBytes(value: String) throws {
        let fixture = KeySignatureFixture(value: value)
        let json = try fixture.read()
        let actual = try #require(json["keySignature"] as? String)
        #expect(Array(actual.utf8) == Array(value.utf8))
        fixture.checkReadOnly()
    }

    @Test(arguments: ["absent", "number", "bool", "null", "empty", "blank"])
    func malformedValueIsNotADefault(kind: String) throws {
        let value: Any?
        switch kind {
        case "number": value = NSNumber(value: 1)
        case "bool": value = NSNumber(value: true)
        case "null": value = NSNull()
        case "empty": value = ""
        case "blank": value = " \u{00A0}\n\t"
        default: value = nil
        }
        let fixture = KeySignatureFixture(value: value)
        let json = try fixture.read()
        #expect(json["keySignature"] == nil)
        fixture.checkReadOnly()
    }

    @Test(arguments: ["wrong-role", "compound", "whitespace", "title-only", "help-only", "time-signature"])
    func decoysDoNotSupplyAKey(kind: String) throws {
        let fixture = KeySignatureFixture(description: "")
        switch kind {
        case "wrong-role":
            fixture.builder.setAttribute(fixture.popup, kAXRoleAttribute as String, kAXStaticTextRole as String)
            fixture.builder.setAttribute(fixture.popup, kAXDescriptionAttribute as String, derivedKeyDescriptions[0])
        case "compound":
            fixture.builder.setAttribute(fixture.popup, kAXDescriptionAttribute as String, "Key Signature options")
        case "whitespace":
            fixture.builder.setAttribute(fixture.popup, kAXDescriptionAttribute as String, " Key Signature ")
        case "title-only":
            fixture.builder.setAttribute(fixture.popup, kAXTitleAttribute as String, derivedKeyDescriptions[0])
        case "help-only":
            fixture.builder.setAttribute(fixture.popup, kAXHelpAttribute as String, derivedKeyDescriptions[0])
        default:
            fixture.builder.setAttribute(fixture.popup, kAXDescriptionAttribute as String, "Time Signature")
            fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "4/4")
        }
        let json = try fixture.read()
        #expect(json["keySignature"] == nil)
        fixture.checkReadOnly()
    }

    @Test(arguments: ["same", "different", "absent", "malformed"])
    func duplicatePopupRefusesTraversalOrder(kind: String) throws {
        let fixture = KeySignatureFixture()
        let other = fixture.builder.element(111_704)
        fixture.builder.setAttribute(other, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
        fixture.builder.setAttribute(other, kAXDescriptionAttribute as String, derivedKeyDescriptions[0])
        switch kind {
        case "same": fixture.builder.setAttribute(other, kAXValueAttribute as String, "D Minor")
        case "different": fixture.builder.setAttribute(other, kAXValueAttribute as String, "G Major")
        case "malformed": fixture.builder.setAttribute(other, kAXValueAttribute as String, NSNumber(value: 1))
        default: break
        }
        fixture.builder.setChildren(fixture.sibling, [other])
        let json = try fixture.read()
        #expect(json["keySignature"] == nil)
        fixture.checkReadOnly()
    }

    @Test(arguments: ["root-children", "sibling-children", "sibling-role", "description", "value"])
    func failedScanCannotHideACompetingPopup(kind: String) throws {
        let fixture = KeySignatureFixture()
        let barID = fixture.builder.elementID(fixture.bar)
        let siblingID = fixture.builder.elementID(fixture.sibling)
        let popupID = fixture.builder.elementID(fixture.popup)
        let builder = fixture.builder
        let runtime = fixture.builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                let id = builder.elementID(element)
                if (kind == "sibling-role" && id == siblingID && attribute == kAXRoleAttribute as String)
                    || (kind == "description" && id == popupID && attribute == kAXDescriptionAttribute as String)
                    || (kind == "value" && id == popupID && attribute == kAXValueAttribute as String) {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            },
            childrenResultHandler: { element in
                let id = builder.elementID(element)
                if (kind == "root-children" && id == barID)
                    || (kind == "sibling-children" && id == siblingID) {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil
        )
        let json = try fixture.read(runtime: runtime)
        #expect(json["keySignature"] == nil)
        fixture.checkReadOnly()
    }

    @Test(arguments: ["cycle", "depth-limit"])
    func incompleteTreeDoesNotProveUniqueness(kind: String) throws {
        let fixture = KeySignatureFixture()
        if kind == "cycle" {
            fixture.builder.setChildren(fixture.sibling, [fixture.sibling])
        } else {
            var parent = fixture.sibling
            for offset in 0..<9 {
                let child = fixture.builder.element(111_720 + offset)
                fixture.builder.setAttribute(child, kAXRoleAttribute as String, kAXGroupRole as String)
                fixture.builder.setChildren(parent, [child])
                parent = child
            }
        }
        let json = try fixture.read()
        #expect(json["keySignature"] == nil)
        fixture.checkReadOnly()
    }

    @Test(arguments: [AXError.noValue.rawValue, AXError.attributeUnsupported.rawValue])
    func nativeChildlessStatusesAreReadable(status: Int32) throws {
        let fixture = KeySignatureFixture()
        let builder = fixture.builder
        let leafIDs = [builder.elementID(fixture.popup), builder.elementID(fixture.sibling)]
        let runtime = builder.makeAXRuntime(
            childrenResultHandler: { element in
                leafIDs.contains(builder.elementID(element)) ? .failure(.init(raw: status)) : nil
            }, setAttributeHandler: nil, performActionHandler: nil
        )
        let json = try fixture.read(runtime: runtime)
        #expect(json["keySignature"] as? String == "D Minor")
        fixture.checkReadOnly()
    }

    @Test func aLeafAtTheDepthBoundIsACompleteRead() throws {
        let fixture = KeySignatureFixture()
        var parent = fixture.bar
        for offset in 0..<7 {
            let child = fixture.builder.element(111_740 + offset)
            fixture.builder.setAttribute(child, kAXRoleAttribute as String, kAXGroupRole as String)
            fixture.builder.setChildren(parent, [child])
            parent = child
        }
        fixture.builder.setChildren(parent, [fixture.popup])
        let json = try fixture.read()
        #expect(json["keySignature"] as? String == "D Minor")
        fixture.checkReadOnly()
    }

    @Test func breadthExhaustionDiscardsAnEarlierMatch() throws {
        let fixture = KeySignatureFixture()
        let children = (0..<256).map { offset in
            let child = fixture.builder.element(111_800 + offset)
            fixture.builder.setAttribute(child, kAXRoleAttribute as String, kAXGroupRole as String)
            return child
        }
        fixture.builder.setChildren(fixture.sibling, children)
        let json = try fixture.read()
        #expect(json["keySignature"] == nil)
        fixture.checkReadOnly()
    }

    @Test(arguments: ["malformed-role", "malformed-description", "unread-other-popup"])
    func unreadCandidateMetadataDoesNotProveUniqueness(kind: String) throws {
        let fixture = KeySignatureFixture()
        let builder = fixture.builder
        let other = builder.element(111_704)
        let otherID = builder.elementID(other)
        builder.setAttribute(other, kAXRoleAttribute as String,
                             kind == "malformed-role" ? NSNumber(value: 1) : kAXPopUpButtonRole as String)
        if kind == "malformed-description" {
            builder.setAttribute(other, kAXDescriptionAttribute as String, NSNumber(value: 1))
        }
        builder.setChildren(fixture.sibling, [other])
        let runtime = builder.makeAXRuntime(
            attributeValueResultHandler: { element, attribute in
                if kind == "unread-other-popup", builder.elementID(element) == otherID,
                   attribute == kAXDescriptionAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil
        )
        let json = try fixture.read(runtime: runtime)
        #expect(json["keySignature"] == nil)
        fixture.checkReadOnly()
    }

    @Test func productionTransportProducerCarriesTheObservedKey() throws {
        let fixture = KeySignatureFixture()
        let app = fixture.builder.element(111_710)
        let window = fixture.builder.element(111_711)
        fixture.builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        fixture.builder.setChildren(window, [fixture.bar])
        fixture.builder.setAttribute(fixture.bar, kAXDescriptionAttribute as String, "Control Bar")
        let play = fixture.builder.element(111_712), record = fixture.builder.element(111_713)
        for (box, label) in [(play, "Play"), (record, "Record")] {
            fixture.builder.setAttribute(box, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            fixture.builder.setAttribute(box, kAXDescriptionAttribute as String, label)
            fixture.builder.setAttribute(box, kAXValueAttribute as String, NSNumber(value: false))
        }
        fixture.builder.setChildren(fixture.bar, [fixture.group, fixture.sibling, play, record])
        let result = AccessibilityChannel.defaultGetTransportState(
            runtime: fixture.builder.makeLogicRuntime(appElement: app)
        )
        #expect(result.isSuccess)
        let json = try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
        #expect(json["keySignature"] as? String == "D Minor")
        fixture.checkReadOnly()
    }

    @Test func roundTripsOptionalKeyAndDecodesHistoricalPayload() throws {
        let observed = try decodeKeyState(keyStatePayload("F♯ Minor"))
        let observedJSON = try keyStateJSON(observed)
        #expect(observedJSON["keySignature"] as? String == "F♯ Minor")
        let historical = try decodeKeyState(keyStatePayload(nil))
        let historicalJSON = try keyStateJSON(historical)
        #expect(historicalJSON["keySignature"] == nil)
    }

    @Test func resourceKeepsLiveCachedAndDefaultProvenance() async throws {
        let cache = StateCache()
        let router = ChannelRouter()
        let payload = try #require(String(data: keyStatePayload("D Minor"), encoding: .utf8))
        let channel = KeySignatureStateChannel(payload: payload)
        await router.register(channel)

        func envelope() async throws -> [String: Any] {
            let result = try await ResourceHandlers.read(uri: "logic://transport/state", cache: cache, router: router)
            let text = try #require(result.contents.first?.text)
            return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        func key(in envelope: [String: Any]) throws -> String? {
            let data = try #require(envelope["data"] as? [String: Any])
            let state = try #require(data["state"] as? [String: Any])
            return state["keySignature"] as? String
        }
        let live = try await envelope()
        #expect(live["source"] as? String == "ax_live")
        #expect(try key(in: live) == "D Minor")
        let cached = try await envelope()
        #expect(cached["source"] as? String == "cache")
        #expect(try #require(cached["unverified"] as? Bool))
        #expect(try #require(cached["stale"] as? Bool))
        #expect(try key(in: cached) == "D Minor")
        let unreadPayload = try #require(String(data: keyStatePayload(nil), encoding: .utf8))
        let unreadChannel = KeySignatureStateChannel(payload: unreadPayload)
        await router.register(unreadChannel)
        let refreshedWithoutKey = try await envelope()
        #expect(refreshedWithoutKey["source"] as? String == "ax_live")
        #expect(try key(in: refreshedWithoutKey) == nil)
        await cache.updateTransport(TransportState())
        let empty = try await envelope()
        #expect(empty["source"] as? String == "default")
        #expect(try key(in: empty) == nil)
        #expect(await channel.calls == 2)
        #expect(await unreadChannel.calls == 2)
    }
}
