@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// The Mixer strip of a software-instrument track ("Deluxe Classic", E-Piano loaded, no inserts) as
// Logic Pro 13.0 (7801, Korean) draws it, measured 2026-11-16 from the Aqua session:
// impl-logic13/A1-frames-instrument-strip.stdout and A2-node-instr-{12,13,14,15}.stdout.
// Logic 13 draws its slots 22 px tall and 28 px apart, so the empty "MIDI 플러그인" slot button sits
// exactly one adjacency step (height + 6) above the instrument group. On Logic 12.3.1 (18 px slots,
// 26 px apart) it was out of reach. Children are in Logic's own order. No AX element is read from
// a running Logic.

private let stripX: CGFloat = 376
private let stripWidth: CGFloat = 66

private func element(
    _ b: FakeAXRuntimeBuilder, _ id: Int, role: String, y: CGFloat, height: CGFloat,
    x: CGFloat = stripX, width: CGFloat = stripWidth, description: String, help: String? = nil
) -> AXUIElement {
    let el = b.element(id)
    b.setAttribute(el, kAXRoleAttribute as String, role)
    b.setAttribute(el, kAXDescriptionAttribute as String, description)
    if let help { b.setAttribute(el, kAXHelpAttribute as String, help) }
    b.setAttribute(el, kAXPositionAttribute as String, axPoint(x, y))
    b.setAttribute(el, kAXSizeAttribute as String, axSize(width, height))
    return el
}

private let sendHelp = "센드 슬롯. 신호를 Aux 채널 스트립으로 라우팅합니다. 센드를 사용하여"
private let audioEffectHelp = "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. "
    + "이펙트를 사용하여 실시간으로 신호를 변경합니다. "
private let midiEffectHelp = "MIDI 이펙트 슬롯. MIDI 이펙트를 삽입합니다. 사용 중인 슬롯을 클릭하여 플러그인을 엽니다. "

private struct Logic13InstrumentStrip {
    let children: [AXUIElement]
    let emptyInsert: AXUIElement
    let instrument: AXUIElement
    let midiSlot: AXUIElement

    init(_ b: FakeAXRuntimeBuilder) {
        let sendStub = element(b, 13010, role: kAXButtonRole as String, y: 615, height: 11, width: 48,
                               description: "보내기 버튼", help: sendHelp)
        let send = element(b, 13011, role: kAXButtonRole as String, y: 594, height: 22, width: 48,
                           description: "보내기 버튼", help: sendHelp)
        let appendStub = element(b, 13012, role: kAXButtonRole as String, y: 554, height: 11,
                                 description: "오디오 플러그인", help: audioEffectHelp)
        emptyInsert = element(b, 13013, role: kAXButtonRole as String, y: 533, height: 22,
                              description: "오디오 플러그인", help: audioEffectHelp)
        instrument = element(b, 13014, role: kAXGroupRole as String, y: 505, height: 22, description: "E-Piano")
        let bypass = element(b, 130141, role: kAXCheckBoxRole as String, y: 505, height: 22, width: 20,
                             description: "바이패스")
        b.setAttribute(bypass, kAXValueAttribute as String, 0)
        let open = element(b, 130142, role: kAXButtonRole as String, y: 505, height: 22, x: 396, width: 29,
                           description: "열기")
        let list = element(b, 130143, role: kAXButtonRole as String, y: 505, height: 22, x: 425, width: 17,
                           description: "목록")
        b.setChildren(instrument, [bypass, open, list])
        midiSlot = element(b, 13015, role: kAXButtonRole as String, y: 477, height: 22,
                           description: "MIDI 플러그인", help: midiEffectHelp)
        let eqDisplay = element(b, 13016, role: kAXButtonRole as String, y: 441, height: 29, x: 377, width: 64,
                                description: "EQ", help: "EQ 디스플레이. 채널 EQ를 추가하거나 삽입된 채널 또는 리니어 페이즈")
        children = [sendStub, send, appendStub, emptyInsert, instrument, midiSlot, eqDisplay]
    }
}

@Test func logic13InstrumentStripMIDISlotIsNotAnEmptyInsert() throws {
    let b = FakeAXRuntimeBuilder()
    let strip = Logic13InstrumentStrip(b)
    let read = AXLogicProElements.audioPluginInsertSlots(children: strip.children, runtime: b.makeAXRuntime())
    // The strip has exactly one addressable insert: the empty 22 px audio slot under the instrument.
    #expect(read.count == 1)
    #expect(!read.contains { $0.readStatus == .unclassified })
    #expect(!read.contains { CFEqual($0.element, strip.midiSlot) })
    #expect(!read.contains { CFEqual($0.element, strip.instrument) })
    let first = try #require(read.first)
    #expect(CFEqual(first.element, strip.emptyInsert))
    #expect(first.index == 0)
    #expect(first.isEmpty)
    #expect(b.actionCalls.isEmpty)
}
