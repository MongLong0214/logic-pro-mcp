import Foundation

/// Shared parser for the `"pitch,offsetMs,durMs[,vel[,ch]];..."` note-sequence
/// format used by `midi.play_sequence` and `record_sequence`. Rejects segments
/// whose pitch/offset/duration/velocity/channel fall outside MIDI ranges, and
/// returns the remaining valid notes. Callers layer their own upper bounds
/// (256 for real-time play, 1024 for SMF import) on top of the result.
enum NoteSequenceParser {
    struct ParsedNote: Equatable {
        let pitch: UInt8       // 0...127
        let offsetMs: Int      // >= 0
        let durationMs: Int    // 1...30000
        let velocity: UInt8    // 0...127
        let channel: UInt8     // 0...15
    }

    static func parse(_ notes: String) -> [ParsedNote] {
        notes.split(separator: ";").compactMap(parseSegment)
    }

    private static func parseSegment<S: StringProtocol>(_ raw: S) -> ParsedNote? {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let pitch = Int(parts[0]), (0...127).contains(pitch),
              let offset = Int(parts[1]), offset >= 0,
              let duration = Int(parts[2]), (1...30_000).contains(duration) else { return nil }
        let velocity = parts.count >= 4
            ? (Int(parts[3]).flatMap { (0...127).contains($0) ? $0 : nil } ?? 100)
            : 100
        let channel = parts.count >= 5
            ? (Int(parts[4]).flatMap { (0...15).contains($0) ? $0 : nil } ?? 0)
            : 0
        return ParsedNote(
            pitch: UInt8(pitch),
            offsetMs: offset,
            durationMs: duration,
            velocity: UInt8(velocity),
            channel: UInt8(channel)
        )
    }
}
