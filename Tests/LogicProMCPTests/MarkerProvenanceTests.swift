import Testing
import Foundation
@testable import LogicProMCP

// v3.2 — Marker provenance 검증.
// PositionSource enum + Codable backward compat + resource envelope
// (position_source / is_canonical) + goto_marker HC top-level uncertainty merge.

// MARK: - MarkerState Codable round-trip

// 모든 PositionSource case 에 대해 round-trip 균질 검증. 신규 enum case 추가 시
// `PositionSource.allCases` 자동 확장 (v3.3 등에서 case 추가 시 누락 방지).
@Test("MarkerState Codable round-trip — 모든 PositionSource",
      arguments: PositionSource.allCases)
func markerState_codableRoundTrip(_ source: PositionSource) throws {
    let original = MarkerState(
        id: 0, name: "M", position: "1.1.1.1", positionSource: source
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MarkerState.self, from: data)
    #expect(decoded == original, "round-trip 동등성 (\(source))")
    #expect(decoded.positionSource == source, "\(source) 보존")
}

// v3.1.x cache snapshot 디코딩 — positionSource field 없음 → .unknown
// false provenance 차단.
@Test("MarkerState legacy snapshot decode → .unknown")
func markerState_legacySnapshot_decodesAsUnknown() throws {
    let legacyJSON = #"{"id":0,"name":"VOCALS","position":"146.4.4.240"}"#
        .data(using: .utf8)!
    let decoded = try JSONDecoder().decode(MarkerState.self, from: legacyJSON)
    #expect(decoded.positionSource == .unknown)
    #expect(decoded.id == 0)
    #expect(decoded.name == "VOCALS")
    #expect(decoded.position == "146.4.4.240")
}

@Test("MarkerState legacy array decode — 모두 .unknown")
func markerState_legacyArray_decodesAsUnknown() throws {
    let legacyJSON = #"""
    [
      {"id":0,"name":"A","position":"1.1.1.1"},
      {"id":1,"name":"B","position":"2.1.1.1"}
    ]
    """#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode([MarkerState].self, from: legacyJSON)
    #expect(decoded.count == 2)
    #expect(decoded.allSatisfy { $0.positionSource == .unknown })
}

// MARK: - PositionSource enum

@Test("PositionSource rawValue 안정성 (wire schema 보장)")
func positionSource_rawValueStability() {
    #expect(PositionSource.parser.rawValue == "parser")
    #expect(PositionSource.fallback.rawValue == "fallback")
    #expect(PositionSource.unknown.rawValue == "unknown")
}

// MARK: - goto_marker uncertainty merge (HC top-level)

@Test("mergeMarkerUncertainty: HC State A → top-level extras 추가")
func mergeMarkerUncertainty_stateA_addsTopLevelExtras() {
    let raw = #"{"requested":"1.1.1.1","success":true,"verified":true}"#
    let merged = NavigateDispatcher.mergeMarkerUncertainty(
        into: raw, source: .fallback
    )
    #expect(merged.contains("\"marker_position_uncertain\":true"))
    #expect(merged.contains("\"marker_position_source\":\"fallback\""))
    #expect(merged.contains("\"success\":true"))
}

@Test("mergeMarkerUncertainty: HC State B → 보존 + extras 추가")
func mergeMarkerUncertainty_stateB_preservesReason() {
    let raw = #"{"reason":"readback_unavailable","success":true,"verified":false}"#
    let merged = NavigateDispatcher.mergeMarkerUncertainty(
        into: raw, source: .unknown
    )
    #expect(merged.contains("\"marker_position_uncertain\":true"))
    #expect(merged.contains("\"marker_position_source\":\"unknown\""))
    #expect(merged.contains("\"reason\":\"readback_unavailable\""))
    #expect(merged.contains("\"verified\":false"))
}

@Test("mergeMarkerUncertainty: HC State C (success:false) → merge skip")
func mergeMarkerUncertainty_stateC_skipsMerge() {
    let raw = #"{"error":"ax_write_failed","success":false}"#
    let merged = NavigateDispatcher.mergeMarkerUncertainty(
        into: raw, source: .fallback
    )
    // State C 보존 — uncertainty merge 안 함
    #expect(!merged.contains("marker_position_uncertain"))
    #expect(merged.contains("\"success\":false"))
    #expect(merged.contains("\"error\":\"ax_write_failed\""))
}

@Test("mergeMarkerUncertainty: invalid JSON → 원본 그대로")
func mergeMarkerUncertainty_invalidJSON_returnsRaw() {
    let raw = "not json"
    let merged = NavigateDispatcher.mergeMarkerUncertainty(
        into: raw, source: .fallback
    )
    #expect(merged == raw)
}

// MARK: - PositionSource.isCanonical (단일 진실 소스 보호)

@Test("PositionSource.isCanonical — parser 만 true",
      arguments: [
        (PositionSource.parser, true),
        (PositionSource.fallback, false),
        (PositionSource.unknown, false),
      ])
func positionSource_isCanonical(source: PositionSource, expected: Bool) {
    #expect(expected ? source.isCanonical : !source.isCanonical)
}

// MARK: - MarkerState.fromParsed factory (양쪽 fallback site dedup 회귀 보호)

@Test("MarkerState.fromParsed: parser 성공 → .parser + canonical position")
func markerState_fromParsed_success() {
    let m = MarkerState.fromParsed("146.4.4.240", ordinal: 0, name: "VOCALS")
    #expect(m.position == "146.4.4.240")
    #expect(m.positionSource == .parser)
    #expect(m.id == 0)
    #expect(m.name == "VOCALS")
}

@Test("MarkerState.fromParsed: parser 실패 → .fallback + (ordinal+1).1.1.1 합성")
func markerState_fromParsed_fallback() {
    let m = MarkerState.fromParsed(nil, ordinal: 5, name: "X")
    #expect(m.position == "6.1.1.1")
    #expect(m.positionSource == .fallback)
    #expect(m.id == 5)
}

// MARK: - logic://markers wire schema (회귀 보호: position_source / is_canonical 키 + derived 정확성)

@Test("encodeMarkersWire: parser 마커 → position_source=parser + is_canonical=true")
func encodeMarkersWire_parser() throws {
    let markers = [
        MarkerState(id: 0, name: "VOCALS", position: "146.4.4.240", positionSource: .parser),
    ]
    let decoded = try #require(sharedJSONArray(ResourceHandlers.encodeMarkersWire(markers)))
    #expect(decoded.count == 1)
    let item = decoded[0]
    #expect(item["id"] as? Int == 0)
    #expect(item["name"] as? String == "VOCALS")
    #expect(item["position"] as? String == "146.4.4.240")
    #expect(item["position_source"] as? String == "parser")
    #expect((item["is_canonical"] as? Bool)!)
    // domain camelCase 필드는 wire 에 새지 않아야 한다.
    #expect(item["positionSource"] == nil)
    #expect(item["isCanonical"] == nil)
}

@Test("encodeMarkersWire: fallback 마커 → position_source=fallback + is_canonical=false")
func encodeMarkersWire_fallback() throws {
    let markers = [
        MarkerState(id: 1, name: "X", position: "2.1.1.1", positionSource: .fallback),
    ]
    let decoded = try #require(sharedJSONArray(ResourceHandlers.encodeMarkersWire(markers)))
    let item = decoded[0]
    #expect(item["position_source"] as? String == "fallback")
    #expect(!((item["is_canonical"] as? Bool)!))
}

@Test("encodeMarkersWire: unknown(legacy) 마커 → position_source=unknown + is_canonical=false")
func encodeMarkersWire_unknown() throws {
    let markers = [
        MarkerState(id: 2, name: "Legacy", position: "1.1.1.1", positionSource: .unknown),
    ]
    let decoded = try #require(sharedJSONArray(ResourceHandlers.encodeMarkersWire(markers)))
    let item = decoded[0]
    #expect(item["position_source"] as? String == "unknown")
    #expect(!((item["is_canonical"] as? Bool)!))
}

@Test("encodeMarkersWire: 빈 배열 → []")
func encodeMarkersWire_empty() throws {
    let decoded = try #require(sharedJSONArray(ResourceHandlers.encodeMarkersWire([])))
    #expect(decoded.isEmpty)
}
