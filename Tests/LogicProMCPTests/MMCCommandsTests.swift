import Foundation
import Testing
@testable import LogicProMCP

@Suite("MMCCommands")
struct MMCCommandsTests {

    // MARK: - New no-arg commands

    @Test("deferredPlay emits SysEx with command byte 0x03")
    func deferredPlayBytes() {
        #expect(MMCCommands.deferredPlay() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x03, 0xF7])
    }

    @Test("reset emits SysEx with command byte 0x0D")
    func resetBytes() {
        #expect(MMCCommands.reset() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x0D, 0xF7])
    }

    @Test("write emits SysEx with command byte 0x40")
    func writeBytes() {
        #expect(MMCCommands.write() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x40, 0xF7])
    }

    // MARK: - goto (memory locate)

    @Test("goto emits 0x44 0x01 + target byte")
    func gotoTargetBytes() throws {
        let bytes = try MMCCommands.goto(target: 0x05)
        #expect(bytes == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x44, 0x01, 0x05, 0xF7])
    }

    @Test("goto rejects target > 0x7F")
    func gotoRejectsHighTarget() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.goto(target: 0x80)
        }
    }

    @Test("goto accepts deviceID 0x7F (broadcast)")
    func gotoAcceptsBroadcast() throws {
        let bytes = try MMCCommands.goto(target: 0x01, deviceID: 0x7F)
        #expect(bytes[2] == 0x7F)
    }

    // MARK: - locateStrict input validation

    @Test("locateStrict rejects hours > 23")
    func locateRejectsHours24() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 24, minutes: 0, seconds: 0, frames: 0)
        }
    }

    @Test("locateStrict rejects minutes > 59")
    func locateRejectsMinutes60() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 60, seconds: 0, frames: 0)
        }
    }

    @Test("locateStrict rejects seconds > 59")
    func locateRejectsSeconds60() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 60, frames: 0)
        }
    }

    @Test("locateStrict rejects frames = 30 at 30fps (max frame index is 29)")
    func locateRejectsFrames30At30fps() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 0, frames: 30, frameRate: .fps30)
        }
    }

    @Test("locateStrict rejects subframes > 99")
    func locateRejectsSubframes100() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 0, frames: 0, subframes: 100)
        }
    }

    @Test("locateStrict at 24fps boundary: frames=23 OK, frames=24 rejected")
    func locate24fpsBoundary() throws {
        _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 0, frames: 23, frameRate: .fps24)
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 0, frames: 24, frameRate: .fps24)
        }
    }

    // MARK: - Frame rate encoding in hours byte

    @Test("locateStrict encodes 24fps in hours bits 5-6 as 00")
    func frameRate24Encoding() throws {
        let bytes = try MMCCommands.locateStrict(hours: 1, minutes: 2, seconds: 3, frames: 4, frameRate: .fps24)
        // hours byte is at index 7. 0b00_xxxxx for 24fps
        #expect(bytes[7] & 0b0110_0000 == 0)
        #expect(bytes[7] & 0b0001_1111 == 1)
    }

    @Test("locateStrict encodes 25fps in hours bits 5-6 as 01")
    func frameRate25Encoding() throws {
        let bytes = try MMCCommands.locateStrict(hours: 2, minutes: 0, seconds: 0, frames: 0, frameRate: .fps25)
        #expect(bytes[7] & 0b0110_0000 == 0b0010_0000)
        #expect(bytes[7] & 0b0001_1111 == 2)
    }

    @Test("locateStrict encodes 29.97df in hours bits 5-6 as 10")
    func frameRate2997dfEncoding() throws {
        let bytes = try MMCCommands.locateStrict(hours: 3, minutes: 0, seconds: 0, frames: 0, frameRate: .fps29_97df)
        #expect(bytes[7] & 0b0110_0000 == 0b0100_0000)
    }

    @Test("locateStrict encodes 30fps in hours bits 5-6 as 11")
    func frameRate30Encoding() throws {
        let bytes = try MMCCommands.locateStrict(hours: 4, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30)
        #expect(bytes[7] & 0b0110_0000 == 0b0110_0000)
    }

    // MARK: - bar/beat → SMPTE

    @Test("barBeatToSMPTE: bar 1 beat 1 is zero position")
    func barBeatZero() throws {
        let smpte = try #require(MMCCommands.barBeatToSMPTE(
            bar: 1, beat: 1.0, tempo: 120, beatsPerBar: 4
        ))
        #expect(smpte.hours == 0)
        #expect(smpte.minutes == 0)
        #expect(smpte.seconds == 0)
        #expect(smpte.frames == 0)
    }

    @Test("barBeatToSMPTE: bar 2 beat 1 at 120bpm 4/4 = 2 seconds")
    func barBeatTwoBarsAt120() throws {
        let smpte = try #require(MMCCommands.barBeatToSMPTE(
            bar: 2, beat: 1.0, tempo: 120, beatsPerBar: 4
        ))
        #expect(smpte.hours == 0)
        #expect(smpte.minutes == 0)
        #expect(smpte.seconds == 2)
    }

    @Test("barBeatToSMPTE: bar 61 at 120bpm 4/4 = 2 minutes")
    func barBeatTwoMinutes() throws {
        let smpte = try #require(MMCCommands.barBeatToSMPTE(
            bar: 61, beat: 1.0, tempo: 120, beatsPerBar: 4
        ))
        #expect(smpte.minutes == 2)
        #expect(smpte.seconds == 0)
    }

    @Test("barBeatToSMPTE rejects invalid inputs")
    func barBeatInvalidInputs() {
        #expect(MMCCommands.barBeatToSMPTE(bar: 0, beat: 1.0, tempo: 120, beatsPerBar: 4) == nil)
        #expect(MMCCommands.barBeatToSMPTE(bar: 1, beat: 0.5, tempo: 120, beatsPerBar: 4) == nil)
        #expect(MMCCommands.barBeatToSMPTE(bar: 1, beat: 1.0, tempo: 0, beatsPerBar: 4) == nil)
        #expect(MMCCommands.barBeatToSMPTE(bar: 1, beat: 1.0, tempo: 120, beatsPerBar: 0) == nil)
    }

    @Test("barBeatToSMPTE caps at 24h SMPTE limit")
    func barBeatExceeds24h() {
        // At 1 bpm 1/1, bar 86401 = 86400 beats = 86400 sec = exactly 24h
        let result = MMCCommands.barBeatToSMPTE(bar: 86_402, beat: 1.0, tempo: 1, beatsPerBar: 1)
        #expect(result == nil)
    }

    // MARK: - Back-compat: existing byte layout unchanged

    @Test("existing locate output is unchanged (byte equality)")
    func existingLocateUnchanged() {
        let bytes = MMCCommands.locate(hours: 1, minutes: 2, seconds: 3, frames: 4, subframes: 5)
        #expect(bytes == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x44, 0x06, 0x01, 1, 2, 3, 4, 5, 0xF7])
    }
}
