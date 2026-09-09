@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - #766 — the type read off the channel strip, and the two it refuses to read
//
// The track header carries no type signal: measured on all seven headers of a project, the token
// sets are identical, because the Input Monitoring button's help names an audio track and a
// software instrument track in one sentence. The first half of #766 made that answer `unknown`
// instead of `audio`.
//
// The inspector channel strip DOES carry one, for two of the four kinds. Measured 2026-09-09 on
// Logic 12.3 (6674), en, one track per `create_*` operation, reading the leading sentence of every
// direct child's AXHelp:
//
//     create_audio          -> Input slot, Record Enable, Input Monitoring, Channel Mode
//     create_instrument     -> MIDI Effect slot, instrument group "Piano"
//     create_drummer        -> MIDI Effect slot, instrument group "Drum Kit"      <- IDENTICAL
//     create_external_midi  -> no output/send/audio-effect slot; Assign control rows
//
// The drummer row is the reason this classifier returns an optional. Its strip cannot be told from
// a software instrument's, so the answer for that shape is no answer.
@Suite("#766 the strip separates audio and external MIDI, and refuses the instrument family")
struct Issue766StripTrackTypeTests {
    // The measured strips, as the leading help sentences `slotKinds` produces.
    private static let audioStrip = [
        "name field", "mute button", "solo button", "record enable button",
        "input monitoring button", "volume fader", "volume display", "peak level display",
        "pan/balance knob", "group slot", "output slot", "send slot", "audio effect slot",
        "channel mode button", "input slot", "eq display", "gain reduction meter", "setting button",
    ]
    private static let instrumentStrip = [
        "name field", "mute button", "solo button", "volume fader", "volume display",
        "peak level display", "pan/balance knob", "group slot", "output slot", "send slot",
        "audio effect slot", "midi effect slot", "eq display", "gain reduction meter",
        "setting button",
    ]
    private static let drummerStrip = instrumentStrip
    private static let externalMIDIStrip = [
        "name field", "mute button", "volume fader", "volume display", "pan/balance knob",
        "group slot", "assign control", "assign control", "assign control", "assign control",
    ]

    @Test("the audio strip is read as audio")
    func audioIsRead() {
        #expect(AXLogicProElements.reading(fromSlotKinds: Self.audioStrip) == .type(.audio))
    }

    @Test("the external MIDI strip is read as external MIDI")
    func externalMIDIIsRead() {
        #expect(AXLogicProElements.reading(fromSlotKinds: Self.externalMIDIStrip) == .type(.externalMIDI))
    }

    // The whole point of the optional. If this ever returns `.softwareInstrument`, it returns it for
    // the drummer too, because the two lists are the same object.
    @Test("the instrument strip is refused rather than narrowed")
    func instrumentIsRefused() {
        #expect(AXLogicProElements.reading(fromSlotKinds: Self.instrumentStrip) == .instrumentFamily)
    }

    @Test("the drummer strip is refused, and is indistinguishable from the instrument one")
    func drummerIsRefused() {
        #expect(Self.drummerStrip == Self.instrumentStrip)
        #expect(AXLogicProElements.reading(fromSlotKinds: Self.drummerStrip) == .instrumentFamily)
    }

    // `audio effect slot` shares two of three words with `midi effect slot`. Matching on the shared
    // tail rather than the full phrase would match every strip that has an audio insert.
    //
    // The assertion is on the LABEL, not on the classifier. Asserting it through
    // `reading(fromSlotKinds:)` cannot fail: the audio strip has an input slot, so it answers
    // `.type(.audio)` before the MIDI-effect branch is ever reached, and a widened phrase is
    // invisible from there. Measured by mutation — widening the canonical to `effect slot` left
    // the whole suite green until this test existed.
    @Test("the MIDI effect phrase does not match an audio effect slot")
    func midiEffectPhraseIsNotTheSharedTail() {
        #expect(AXLocalePolicy.midiEffectSlotHelpKeyword.containsAny(in: "midi effect slot"))
        #expect(!AXLocalePolicy.midiEffectSlotHelpKeyword.containsAny(in: "audio effect slot"))
        // The same hazard one branch over, and the reason `inputSlotHelpKeyword` is a phrase.
        #expect(!AXLocalePolicy.inputSlotHelpKeyword.containsAny(in: "input monitoring button"))
    }

    // The family is a reading, not a failure to read: the create path publishes different
    // provenance for the two. Collapsing them would also make the MIDI-effect branch return what
    // falling through returns, and a rule nothing can distinguish is not a rule.
    @Test("the instrument family is not the same answer as no answer")
    func familyIsNotUndetermined() {
        #expect(AXLogicProElements.reading(fromSlotKinds: Self.instrumentStrip) == .instrumentFamily)
        #expect(AXLogicProElements.reading(fromSlotKinds: nil) == .undetermined)
        #expect(AXLogicProElements.reading(fromSlotKinds: Self.instrumentStrip) != .undetermined)
    }

    // The external-MIDI clause is a conjunction: the Assign control rows AND the absence of an
    // output slot. Dropping the absence half would classify any strip that carries an assign
    // control as external MIDI.
    @Test("assign control beside an output slot is not external MIDI")
    func assignControlAloneIsNotExternal() {
        let both = Self.externalMIDIStrip + ["output slot"]
        #expect(AXLogicProElements.reading(fromSlotKinds: both) == .undetermined)
    }

    // A strip whose child list could not be read shows no output slot either, so an absence-shaped
    // clause would classify it. `slotKinds` answers `nil` rather than `[]` for exactly this, and
    // the classifier has to refuse on `nil` rather than treat it as an empty strip.
    @Test("an unreadable child list is not an empty strip")
    func unreadableIsNotEmpty() {
        #expect(AXLogicProElements.reading(fromSlotKinds: nil) == .undetermined)
        #expect(AXLogicProElements.reading(fromSlotKinds: []) == .undetermined)
    }

    // The inspector rebuilds its strip when the selection changes, and the rebuild is not finished
    // when the operation that changed the selection returns. Reading ONCE makes the answer a race:
    // the strip still names the previous track, the name does not agree, and the read degrades to
    // the header's `unknown` — intermittently. The strip here names the wrong track for the first
    // three reads and the right one after, so a single-pass reader misses it and a settling one
    // does not.
    @Test("the strip is read after the inspector has rebuilt it, not before")
    func theStripIsAwaitedRatherThanRacedFor() {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(1)
        let strip = builder.element(2)
        builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(strip, kAXHelpAttribute as String, "Left inspector channel strip")
        builder.setChildren(window, [strip])

        let reads = Counter()
        let runtime = builder.makeAXRuntime(attributeValueHandler: { element, attribute in
            guard attribute == kAXDescriptionAttribute as String, CFEqual(element, strip) else {
                return nil
            }
            reads.bump()
            // The previous track for the first three reads, then the one that was just created.
            return .some(reads.value > 3 ? "Audio 7" as AnyObject : "Studio Grand" as AnyObject)
        }, setAttributeHandler: nil, performActionHandler: nil)

        let raced = AXLogicProElements.inspectorChannelStrip(
            named: "Audio 7", in: window, settleAttempts: 1, settleInterval: 1, runtime: runtime)
        #expect(raced == nil, "a single pass found a strip the inspector had not rebuilt yet")

        let settled = AXLogicProElements.inspectorChannelStrip(
            named: "Audio 7", in: window, settleAttempts: 40, settleInterval: 1, runtime: runtime)
        #expect(settled != nil, "the strip never settled on the expected name")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @Test("slotKinds keeps an unreadable child list apart from an empty one")
    func slotKindsPreservesTheDistinction() {
        let builder = FakeAXRuntimeBuilder()
        let readable = builder.element(1)
        let slot = builder.element(2)
        builder.setAttribute(slot, kAXHelpAttribute as String,
                             "Input slot. Choose the channel strip input source.")
        builder.setChildren(readable, [slot])
        let unreadable = builder.element(3)

        let runtime = builder.makeAXRuntime(childrenResultHandler: { element in
            CFEqual(element, unreadable)
                ? .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                : nil
        }, setAttributeHandler: nil, performActionHandler: nil)

        #expect(AXLogicProElements.slotKinds(in: readable, runtime: runtime) == ["input slot"])
        #expect(AXLogicProElements.slotKinds(in: unreadable, runtime: runtime) == nil)
    }
}
