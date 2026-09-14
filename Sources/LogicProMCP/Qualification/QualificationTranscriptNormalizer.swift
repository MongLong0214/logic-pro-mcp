import Foundation

/// Makes qualification wire transcripts CROSS-RUN ID-STABLE across two runs of
/// the SAME built artifact by rewriting session-random identifiers to
/// placeholders derived from their order of first appearance. This normalizes
/// the ID dimension ONLY: a real same-artifact run still carries timestamp and
/// live-DAW-state variation this pass does NOT touch, so a whole live transcript
/// is not byte-identical run-to-run. The same-artifact comparison operates on
/// the ID-normalized wire; non-ID noise is out of scope of this pass.
///
/// Session-random identifiers this rewrites:
///   * target references — `trk_`/`mix_`/`ins_`/`prj_` followed by a random UUID,
///     minted per session by `TargetRegistry.bind` (see `TargetReference`);
///   * operation trace ids — `lpmcp_` followed by a random UUID, minted by
///     `TraceID`.
///
/// Each distinct raw identifier maps to a stable `<prefix>_<NORM:N>` placeholder
/// where `N` counts first appearances within that prefix. Referential integrity
/// is preserved end to end: the SAME raw identifier always maps to the SAME
/// placeholder, and two DISTINCT raw identifiers never collapse onto the same
/// placeholder. A transcript reader can therefore still see whether the
/// reference an operation addressed is (or is not) the reference a resource
/// emitted.
///
/// This is a DISPLAY/COMPARISON transform over the transcript ONLY. The
/// qualification's semantic target-faithfulness oracle
/// (`QualificationSemanticReadbackValidator`) runs on the raw, un-normalized
/// operation response/readback bytes (`QualificationOperationResult`), so it
/// continues to verify real identity — normalization cannot turn a wrong target
/// into a right one.
enum QualificationTranscriptNormalizer {
    /// `trk_`/`mix_`/`ins_`/`prj_` (`TargetReference`) and `lpmcp_` (`TraceID`)
    /// are each followed by a 36-char UUID. The negative lookbehind keeps a
    /// prefix that is the tail of a longer word (e.g. `ins` in `plugins_source`)
    /// from matching; the UUID shape is the second, decisive guard. The pattern
    /// is a compile-time constant, so a malformed literal is a build-caught
    /// programmer error — `try!` is the correct spelling here.
    private nonisolated(unsafe) static let identifierRegex = try! NSRegularExpression(
        pattern: "(?<![0-9A-Za-z_])(trk|mix|ins|prj|lpmcp)_"
            + "([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"
    )

    /// Rewrites a whole transcript with one shared placeholder table, so a ref
    /// that recurs across frames (a resource emits it, a later op addresses it)
    /// keeps a single stable placeholder.
    static func normalize(_ frames: [QualificationWireFrame]) -> [QualificationWireFrame] {
        var table = PlaceholderTable()
        var normalized: [QualificationWireFrame] = []
        normalized.reserveCapacity(frames.count)
        for frame in frames {
            normalized.append(QualificationWireFrame(
                sequence: frame.sequence,
                direction: frame.direction,
                operationID: table.rewrite(frame.operationID),
                payload: table.rewrite(frame.payload)
            ))
        }
        return normalized
    }

    /// Rewrites a single string with a fresh placeholder table. Convenience for
    /// call sites (and tests) that normalize one payload in isolation.
    static func normalizeString(_ value: String) -> String {
        var table = PlaceholderTable()
        return table.rewrite(value)
    }

    private struct PlaceholderTable {
        private var placeholderByIdentifier: [String: String] = [:]
        private var nextIndexByPrefix: [String: Int] = [:]

        mutating func rewrite(_ value: String) -> String {
            let subject = value as NSString
            let matches = identifierRegex.matches(
                in: value,
                range: NSRange(location: 0, length: subject.length)
            )
            guard !matches.isEmpty else { return value }
            var result = ""
            var cursor = 0
            for match in matches {
                let matched = match.range
                if matched.location > cursor {
                    result += subject.substring(
                        with: NSRange(location: cursor, length: matched.location - cursor)
                    )
                }
                let identifier = subject.substring(with: matched)
                let prefix = subject.substring(with: match.range(at: 1))
                result += placeholder(for: identifier, prefix: prefix)
                cursor = matched.location + matched.length
            }
            if cursor < subject.length {
                result += subject.substring(
                    with: NSRange(location: cursor, length: subject.length - cursor)
                )
            }
            return result
        }

        private mutating func placeholder(for identifier: String, prefix: String) -> String {
            if let existing = placeholderByIdentifier[identifier] { return existing }
            let index = nextIndexByPrefix[prefix, default: 0]
            nextIndexByPrefix[prefix] = index + 1
            let placeholder = "\(prefix)_<NORM:\(index)>"
            placeholderByIdentifier[identifier] = placeholder
            return placeholder
        }
    }
}
