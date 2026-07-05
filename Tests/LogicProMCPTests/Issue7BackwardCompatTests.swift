import Foundation
import Testing
@testable import LogicProMCP

// v3.1.8 (Issue #7) — Codable backward compatibility:
// v3.1.7 envelopes (no source, no placeholder, no last_saved_age_sec) must
// decode cleanly into v3.1.8 structs.

@Test
func decodeV317ProjectInfo_succeeds() throws {
    let v317 = """
    {
      "name": "Test Project",
      "sampleRate": 48000,
      "bitDepth": 24,
      "tempo": 120,
      "timeSignature": "4/4",
      "trackCount": 5,
      "filePath": null,
      "lastUpdated": "2026-04-12T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let info = try decoder.decode(ProjectInfo.self, from: Data(v317.utf8))
    #expect(info.name == "Test Project")
    #expect(info.tempo == 120)
    #expect(info.source == nil)
    #expect(info.lastSavedAgeSec == nil)
}

@Test
func decodeV317TrackState_succeeds() throws {
    let v317 = """
    {
      "id": 0,
      "name": "Audio 1",
      "type": "audio",
      "isMuted": false,
      "isSoloed": false,
      "isArmed": false,
      "isSelected": true,
      "volume": 0.8,
      "pan": 0,
      "automationMode": "off",
      "color": null
    }
    """
    let track = try JSONDecoder().decode(TrackState.self, from: Data(v317.utf8))
    #expect(track.name == "Audio 1")
    #expect(track.isSelected)
    #expect(track.placeholder == nil)
}

@Test
func encodeV318ProjectInfo_includesNewFields() throws {
    var info = ProjectInfo()
    info.name = "X"
    info.source = "project_file"
    info.lastSavedAgeSec = 12.5
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(info)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"source\":\"project_file\""))
    #expect(json.contains("\"lastSavedAgeSec\":12.5"))
}

@Test
func encodeV318TrackState_placeholderEmittedWhenSet() throws {
    let track = TrackState(
        id: 0, name: "Track 1", type: .unknown,
        placeholder: true
    )
    let data = try JSONEncoder().encode(track)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"placeholder\":true"))
}

@Test
func roundTripV317JsonThroughV318Decoder_preservesShape() throws {
    // A full v3.1.7 ProjectInfo response shape — confirm forward compat.
    let v317 = """
    {
      "name": "Round Trip",
      "sampleRate": 44100,
      "bitDepth": 24,
      "tempo": 90,
      "timeSignature": "4/4",
      "trackCount": 3,
      "filePath": null,
      "lastUpdated": "2026-04-12T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let info = try decoder.decode(ProjectInfo.self, from: Data(v317.utf8))
    #expect(info.tempo == 90)
    #expect(info.trackCount == 3)
    #expect(info.source == nil)  // not present in v3.1.7
}
