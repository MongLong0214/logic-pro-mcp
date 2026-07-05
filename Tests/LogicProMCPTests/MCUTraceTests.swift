import Foundation
import Testing
@testable import LogicProMCP

/// T-A1 (#10) — MCU_TRACE raw-MIDI stderr trace. Pure format + env-gate are
/// unit-tested here; the production TX/RX call sites in ProductionMCUTransport
/// and the actual stderr write are exercised by the live E2E spike (AC-1.4),
/// since they require a real CoreMIDI endpoint.
@Suite struct MCUTraceTests {

    // AC-1.2 — hex format, direction prefix.
    @Test func testFormatTX() {
        #expect(MCUTrace.formatLine(.tx, [0xE0, 0x0C, 0x7F]) == "MCU TX: e0 0c 7f")
    }

    @Test func testFormatRX() {
        #expect(MCUTrace.formatLine(.rx, [0xB0, 0x30, 0x40]) == "MCU RX: b0 30 40")
    }

    @Test func testFormatEmptyBytes() {
        #expect(MCUTrace.formatLine(.tx, []) == "MCU TX:")
    }

    // AC-1.1/1.3 — gate off unless MCU_TRACE == "1".
    @Test func testGateOffByDefault() {
        #expect(!(MCUTrace.shouldTrace([:])))
    }

    @Test func testGateOffWhenZero() {
        #expect(!(MCUTrace.shouldTrace(["MCU_TRACE": "0"])))
        #expect(!(MCUTrace.shouldTrace(["MCU_TRACE": "true"])))
    }

    @Test func testGateOnWhenOne() {
        #expect(MCUTrace.shouldTrace(["MCU_TRACE": "1"]))
    }

    // AC-1.2 — when enabled, a line (with newline) is written to the provided
    // handle (default .standardError in production — never stdout).
    @Test func testEmitWritesToHandleWhenEnabled() throws {
        let pipe = Pipe()
        MCUTrace.emit(.tx, [0xE0, 0x00, 0x40], enabled: true, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text == "MCU TX: e0 00 40\n")
    }

    // AC-1.1 — disabled emit writes nothing.
    @Test func testEmitSilentWhenDisabled() throws {
        let pipe = Pipe()
        MCUTrace.emit(.rx, [0xB0, 0x30, 0x40], enabled: false, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(data.isEmpty)
    }
}
