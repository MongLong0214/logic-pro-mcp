import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import LogicProMCP

// Acceptance lint (runs in every configuration): the pure `assessReadback`
// chokepoint has NO production reference, and the `CompleteProof` mint has
// exactly its known sites — all inside the assessment file. So the dark core is
// inert in the shipped binary; when the live provider is added it becomes the
// single allowed reference and this lint is updated to name it.
//
// The scan is Swift-syntax-aware: string-literal content is `.stringSegment`
// tokens and comments are trivia, so scanning `.identifier` tokens matches only
// real code references — a call hidden in a comment, a plain/raw/interpolated
// string, or after a `//`/`/*` that merely appears inside a string is neither
// missed nor mis-stripped by fragile hand lexing.
@Suite struct MIDIReadbackCallSiteLintTests {
    private static let assessmentFile = "MIDIReadbackAssessment.swift"
    // The only permitted `CompleteProof()` mint sites, both in the assessment
    // file: the production return of `assessReadback` and the debug-only seam.
    private static let expectedProofMintSites = 2

    /// Whether a token is a real identifier reference to `name`, comparing the
    /// token's text with any backtick escaping removed (so `` `assessReadback` ``
    /// matches) and excluding string-segment content by construction.
    private static func isIdentifierRef(_ token: TokenSyntax, _ name: String) -> Bool {
        if case .stringSegment = token.tokenKind { return false }
        return token.text.replacingOccurrences(of: "`", with: "") == name
    }

    /// Count real identifier references to `name` (excludes comments and string
    /// content; catches backtick-escaped identifiers).
    static func identifierCount(_ source: String, _ name: String) -> Int {
        Parser.parse(source: source)
            .tokens(viewMode: .sourceAccurate)
            .reduce(0) { $0 + (isIdentifierRef($1, name) ? 1 : 0) }
    }

    /// Count `Name(` and `Name.init(` construction sites (identifier `Name`
    /// followed by `(`, or by `.init(`), backtick-insensitive.
    static func callSiteCount(_ source: String, _ name: String) -> Int {
        let tokens = Array(Parser.parse(source: source).tokens(viewMode: .sourceAccurate))
        var count = 0
        for i in tokens.indices where isIdentifierRef(tokens[i], name) {
            if i + 1 < tokens.count, tokens[i + 1].tokenKind == .leftParen {
                count += 1
            } else if i + 3 < tokens.count,
                      tokens[i + 1].tokenKind == .period,
                      tokens[i + 2].text.replacingOccurrences(of: "`", with: "") == "init",
                      tokens[i + 3].tokenKind == .leftParen {
                count += 1
            }
        }
        return count
    }

    @Test func noProductionAssessReadbackReferenceAndProofMintIsExact() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // LogicProMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let sources = repoRoot.appendingPathComponent("Sources/LogicProMCP")
        let assessmentPath = sources
            .appendingPathComponent("MIDIReadback/\(Self.assessmentFile)")
            .standardizedFileURL.path

        let fm = FileManager.default
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: sources.path, isDirectory: &isDir) && isDir.boolValue,
                "source directory not found at \(sources.path)")

        var scanned = 0
        var sawAssessmentFile = false
        var offenders: [String] = []
        var proofMintInAssessment = 0
        let enumerator = fm.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            // Hard-fail file reads: an unreadable source is an error, not "empty".
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                offenders.append("\(url.lastPathComponent): unreadable (\(error))")
                continue
            }
            let isAssessment = url.standardizedFileURL.path == assessmentPath
            let proofMints = Self.callSiteCount(text, "CompleteProof")
            if isAssessment {
                sawAssessmentFile = true
                proofMintInAssessment = proofMints
                continue
            }
            if Self.identifierCount(text, "assessReadback") > 0 {
                offenders.append("\(url.lastPathComponent): references assessReadback")
            }
            if proofMints > 0 {
                offenders.append("\(url.lastPathComponent): mints CompleteProof outside its file")
            }
        }

        #expect(sawAssessmentFile, "expected the assessment file at \(assessmentPath)")
        #expect(scanned > 50, "expected to scan the LogicProMCP source tree; scanned \(scanned) files")
        #expect(offenders.isEmpty, "dark-core call-site lint offenders: \(offenders)")
        #expect(proofMintInAssessment == Self.expectedProofMintSites,
                "CompleteProof mint sites in \(Self.assessmentFile) = \(proofMintInAssessment), expected \(Self.expectedProofMintSites)")
    }

    @Test func syntaxScanIgnoresStringsAndCommentsButCatchesRealReferences() {
        // Real references (caught) — including forms that defeat lexical stripping.
        #expect(Self.identifierCount("let r = assessReadback (evidence)", "assessReadback") == 1)
        #expect(Self.identifierCount("let r = assessReadback\n    (evidence)", "assessReadback") == 1)
        #expect(Self.identifierCount("let fn = assessReadback", "assessReadback") == 1)
        #expect(Self.identifierCount("return \"\\(assessReadback(e))\"", "assessReadback") == 1)       // string interpolation
        #expect(Self.identifierCount("let s = #\"\\#(assessReadback(e))\"#", "assessReadback") == 1)   // raw-string interpolation
        #expect(Self.identifierCount("let u = \"https://x\"; assessReadback(e)", "assessReadback") == 1) // // inside a string
        #expect(Self.identifierCount("let r = `assessReadback`(e)", "assessReadback") == 1)             // backtick-escaped identifier
        #expect(Self.callSiteCount("return .complete(CompleteProof ())", "CompleteProof") == 1)         // whitespace before paren
        #expect(Self.callSiteCount("return .complete(CompleteProof.init())", "CompleteProof") == 1)     // .init() construction
        #expect(Self.callSiteCount("return .complete(`CompleteProof`())", "CompleteProof") == 1)        // backtick construction
        // Not counted: comments, plain string content, member access, unrelated ids.
        #expect(Self.identifierCount("// minted only by assessReadback(evidence)", "assessReadback") == 0)
        #expect(Self.identifierCount("/* /* nested */ see assessReadback */", "assessReadback") == 0)
        #expect(Self.identifierCount("let id = \"eventListAX.assessReadback.v1\"", "assessReadback") == 0)
        #expect(Self.identifierCount("let u = \"/*\"; let x = 1", "assessReadback") == 0)               // /* inside a string, no ref
        #expect(Self.callSiteCount("CompleteProof.makeForTesting()", "CompleteProof") == 0)             // member access, not a mint
    }
}
