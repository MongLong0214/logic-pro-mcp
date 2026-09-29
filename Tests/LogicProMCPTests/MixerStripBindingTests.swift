import Testing
@testable import LogicProMCP

// A verified plug-in write selects an arrange track header and binds the editor
// window by that header's name, but reads the insert chain from a mixer strip.
// Header and strip ordinals only coincide until the first strip with no header
// at the same position (an aux return or bus), so the strip is joined by name.

/// Arrange headers measured on a 12.3.1 project: two Drums stack headers, the
/// kit, Bass, a Synths stack, and a run of duplicate "Guitar" names.
private let headers: [Int: String] = [
    0: "Drums", 1: "Drums", 2: "Kick", 3: "Snare", 4: "Bass",
    5: "Synths", 6: "Hi Synth", 7: "Guitar", 8: "Guitar",
]

/// The same project's Mixer: two aux returns sit after the kit, so every later
/// strip is two ordinals past its header.
private let strips: [String?] = [
    "Drums", "Drums", "Kick", "Snare", "Aux 1", "Aux 2", "Bass",
    "Synths", "Hi Synth", "Guitar", "Guitar",
]

private func bind(_ track: Int, headers: [Int: String]? = headers, strips: [String?] = strips)
    -> Result<Int, AccessibilityChannel.StripBindingFailure> {
    AccessibilityChannel.mixerStripIndex(forTrack: track, headerNames: headers, stripNames: strips)
}

@Test func aStripAtTheHeadersOwnOrdinalIsKeptWhenTheNamesMatch() {
    #expect(bind(2) == .success(2))
    #expect(bind(3) == .success(3))
}

@Test func aStripPastAnAuxReturnIsBoundByNameNotOrdinal() {
    // Ordinal 4 is "Aux 1"; writing there is the bug this binding closes.
    #expect(bind(4) == .success(6))
    #expect(bind(6) == .success(8))
}

@Test func duplicateNamesBindInArrangeOrder() {
    #expect(bind(0) == .success(0))
    #expect(bind(1) == .success(1))
    #expect(bind(7) == .success(9))
    #expect(bind(8) == .success(10))
}

@Test func aNameWithNoStripIsRefused() {
    var noBass = strips
    noBass[6] = "Bass DI"
    #expect(bind(4, strips: noBass) == .failure(.noStripNamed("Bass")))
}

@Test func unequalNameCountsAreRefusedRatherThanGuessed() {
    var extraGuitar = strips
    extraGuitar.append("Guitar")
    #expect(bind(7, strips: extraGuitar) == .failure(.ambiguous(name: "Guitar", headerCount: 2, stripCount: 3)))
}

@Test func withNoNamesToJoinOnTheHeaderOrdinalIsKept() {
    // Nothing to join on: the write keeps the header's ordinal, and the
    // insert's plug-in identity and editor title still gate it downstream.
    #expect(bind(4, strips: [nil, nil, nil, nil, nil]) == .success(4))
    #expect(bind(4, headers: nil) == .success(4))
    #expect(bind(42) == .failure(.notInMixer(stripCount: 11)))
}
