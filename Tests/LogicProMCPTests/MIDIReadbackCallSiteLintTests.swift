import Foundation
import Testing
@testable import LogicProMCP

// Acceptance lint (runs in every configuration): the pure `assessReadback`
// chokepoint has NO production reference, and the `CompleteProof` mint appears
// only in its defining file — so the dark core is inert in the shipped binary.
//
// The scan is comment-aware and matches on identifier boundaries (not a raw
// substring), so whitespace/newline/function-reference evasions are caught;
// file reads hard-fail (an unreadable source is an error, never silently empty).
// When the live provider is added it becomes the single allowed reference and
// this lint is updated to name it.
@Suite struct MIDIReadbackCallSiteLintTests {
    private static let assessmentFile = "MIDIReadbackAssessment.swift"

    /// Strip `//` line comments, `/* */` block comments, and string-literal
    /// CONTENT (single-line and `"""` multi-line) so identifier matches are not
    /// fooled by prose or string data — but KEEP the code inside `\(…)` string
    /// interpolations, since a call hidden in an interpolation is a real
    /// production reference. Only real code tokens remain.
    static func strippedOfComments(_ source: String) -> String {
        var out = ""
        let c = Array(source)
        var i = 0

        // Emit the code inside a `\(…)` interpolation (balanced parens); `i`
        // points just past `\(`. Returns with `i` just past the closing `)`.
        func emitInterpolation() {
            var depth = 1
            while i < c.count, depth > 0 {
                if c[i] == "(" { depth += 1; out.append(c[i]); i += 1 }
                else if c[i] == ")" { depth -= 1; if depth > 0 { out.append(c[i]) }; i += 1 }
                else { out.append(c[i]); i += 1 }
            }
            out.append(" ")
        }

        while i < c.count {
            if i + 1 < c.count, c[i] == "/", c[i + 1] == "/" {
                while i < c.count, c[i] != "\n" { i += 1 }
            } else if i + 1 < c.count, c[i] == "/", c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i = min(i + 2, c.count)
            } else if i + 2 < c.count, c[i] == "\"", c[i + 1] == "\"", c[i + 2] == "\"" {
                i += 3
                while i + 2 < c.count, !(c[i] == "\"" && c[i + 1] == "\"" && c[i + 2] == "\"") {
                    if c[i] == "\\", i + 1 < c.count, c[i + 1] == "(" { i += 2; emitInterpolation() }
                    else { i += 1 }
                }
                i = min(i + 3, c.count)
            } else if c[i] == "\"" {
                i += 1
                while i < c.count, c[i] != "\"" {
                    if c[i] == "\\", i + 1 < c.count, c[i + 1] == "(" { i += 2; emitInterpolation() }
                    else if c[i] == "\\" { i += 2 }
                    else { i += 1 }
                }
                i += 1
            } else {
                out.append(c[i])
                i += 1
            }
        }
        return out
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// Any non-comment reference to the `assessReadback` identifier (call or
    /// function value) — whitespace/newline before `(` and bare references count.
    static func referencesAssessReadback(_ source: String) -> Bool {
        matches("(?<![A-Za-z0-9_])assessReadback(?![A-Za-z0-9_])", in: strippedOfComments(source))
    }

    /// A `CompleteProof(` mint (allowing whitespace before the paren).
    static func mintsCompleteProof(_ source: String) -> Bool {
        matches("(?<![A-Za-z0-9_])CompleteProof[ \\t\\n]*\\(", in: strippedOfComments(source))
    }

    @Test func noProductionAssessReadbackReferenceOrProofMint() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // LogicProMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let sources = repoRoot.appendingPathComponent("Sources/LogicProMCP")

        let fm = FileManager.default
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: sources.path, isDirectory: &isDir) && isDir.boolValue,
                "source directory not found at \(sources.path)")

        // Allow the assessment file ONLY at its exact path, so a second file that
        // happens to share the basename cannot smuggle an unscanned reference.
        let assessmentPath = sources
            .appendingPathComponent("MIDIReadback/\(Self.assessmentFile)")
            .standardizedFileURL.path
        var sawAssessmentFile = false

        var scanned = 0
        var offenders: [String] = []
        let enumerator = fm.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let name = url.lastPathComponent
            // Hard-fail file reads: an unreadable source is an error, not "empty".
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                offenders.append("\(name): unreadable (\(error))")
                continue
            }
            if url.standardizedFileURL.path == assessmentPath {
                sawAssessmentFile = true
                continue
            }
            if Self.referencesAssessReadback(text) {
                offenders.append("\(url.lastPathComponent): references assessReadback")
            }
            if Self.mintsCompleteProof(text) {
                offenders.append("\(url.lastPathComponent): mints CompleteProof outside its file")
            }
        }

        #expect(sawAssessmentFile, "expected to find the assessment file at \(assessmentPath)")
        #expect(scanned > 50, "expected to scan the LogicProMCP source tree; scanned \(scanned) files")
        #expect(offenders.isEmpty,
                "assessReadback must have no production reference and CompleteProof must be minted only in \(Self.assessmentFile): \(offenders)")
    }

    @Test func lintCatchesEvasionFormsButIgnoresComments() {
        // Evasion forms the old substring check would have missed:
        #expect(Self.referencesAssessReadback("let r = assessReadback (evidence)"))   // space before paren
        #expect(Self.referencesAssessReadback("let f = assessReadback\n    (evidence)")) // newline before paren
        #expect(Self.referencesAssessReadback("let fn = assessReadback"))              // bare function reference
        #expect(Self.referencesAssessReadback("return \"\\(assessReadback(e))\""))     // hidden in string interpolation
        #expect(Self.referencesAssessReadback("log(\"x=\\(assessReadback)\")"))         // bare ref in interpolation
        #expect(Self.mintsCompleteProof("return .complete(CompleteProof ())"))         // space before paren
        // Not flagged: comment mentions, plain string content, and unrelated identifiers.
        #expect(!Self.referencesAssessReadback("// minted only by assessReadback(evidence)"))
        #expect(!Self.referencesAssessReadback("/* see assessReadback for details */"))
        #expect(!Self.referencesAssessReadback("let x = reassessReadbackLater(y)"))    // substring, not the identifier
        #expect(!Self.referencesAssessReadback("let id = \"eventListAX.assessReadback.v1\"")) // plain string content, not code
        #expect(!Self.mintsCompleteProof("CompleteProof.makeForTesting()"))            // method, not a mint call
    }
}
