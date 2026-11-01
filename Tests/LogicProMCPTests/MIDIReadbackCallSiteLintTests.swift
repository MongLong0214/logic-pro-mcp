import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import LogicProMCP

// Defense-in-depth acceptance lint (runs in every configuration). The LOAD-BEARING
// control is Swift access control, not this scan: `CompleteProof`'s initializer is
// fileprivate to the assessment file, so no other file can construct one, and there
// is no public/internal initializer, factory, or decoder — so no production
// `.complete` can be minted outside `assessReadback`. This scan is a SECONDARY aid:
// it hard-fails on unreadable sources and permits only the named production callers —
// the Event List provider adapter and the explicitly partial selected-region reader — plus the
// expected `CompleteProof` construction sites in the assessment file. It does NOT claim to census
// every possible future
// Swift alias/factory form — a same-file `typealias` or helper mint is caught by
// source review of the change, not by this heuristic. The scan is syntax-aware
// (string content is `.stringSegment`, comments are trivia), so it is not defeated
// by strings/comments the way a hand lexer would be.
@Suite struct MIDIReadbackCallSiteLintTests {
    private static let assessmentFile = "MIDIReadbackAssessment.swift"
    private static let providerFile = "EventListMIDINoteReadbackProvider.swift"
    // The strict read-only probe and the bounded/restoring partial harvest are the two
    // release-constructible ways into the collector's raw-row path. Their containment would
    // otherwise be just today's call graph: both are `internal`, so any file in the module could
    // grow another caller silently. The CLI owns the strict probe; the public State-B reader owns
    // the restoring harvest. The collector file declares both.
    private static let collectorFile = "EventListReadbackCollector.swift"
    private static let probeEntryFile = "MainEntrypoint.swift"
    private static let partialReaderFile = "SelectedRegionEventListReader.swift"
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

    /// Count `CompleteProof` initializer calls, structurally (not by token
    /// adjacency), so a CONTEXTUAL initializer — `.complete(.init(contentBinding:))`,
    /// which carries no `CompleteProof` token — is still counted. Because the mint
    /// is fileprivate to the assessment file, a contextual `.init` there is exactly
    /// where an extra mint could hide; `contentBinding:` is `CompleteProof`'s unique
    /// initializer label, so an implicit-base `.init(contentBinding:)` is a mint.
    static func completeProofMintCount(_ source: String) -> Int {
        let counter = CompleteProofMintCounter(viewMode: .sourceAccurate)
        counter.walk(Parser.parse(source: source))
        return counter.count
    }

    private static func scan(
        _ source: String,
        parse: (String) -> SourceFileSyntax = { Parser.parse(source: $0) }
    ) -> (
        proofMints: Int,
        assessmentReferences: Int,
        strictProbeReferences: Int,
        harvestedProbeReferences: Int
    ) {
        let tree = parse(source)
        let counter = CompleteProofMintCounter(viewMode: .sourceAccurate)
        counter.walk(tree)
        var assessmentReferences = 0
        var strictProbeReferences = 0
        var harvestedProbeReferences = 0
        for token in tree.tokens(viewMode: .sourceAccurate) {
            if isIdentifierRef(token, "assessReadback") { assessmentReferences += 1 }
            if isIdentifierRef(token, "observeNoteTable") { strictProbeReferences += 1 }
            if isIdentifierRef(token, "observeHarvestedNoteTable") {
                harvestedProbeReferences += 1
            }
        }
        return (
            counter.count,
            assessmentReferences,
            strictProbeReferences,
            harvestedProbeReferences
        )
    }

    private static func probeCallSiteOffenders(
        fileName: String,
        strictProbeReferences: Int,
        harvestedProbeReferences: Int
    ) -> [String] {
        var offenders: [String] = []
        if strictProbeReferences > 0,
           fileName != probeEntryFile,
           fileName != collectorFile {
            offenders.append("\(fileName): references observeNoteTable")
        }
        if harvestedProbeReferences > 0,
           fileName != partialReaderFile,
           fileName != collectorFile {
            offenders.append("\(fileName): references observeHarvestedNoteTable")
        }
        return offenders
    }

    private struct FileCensus {
        let offenders: [String]
        let proofMintInAssessment: Int?
        let assessmentReferencesInProvider: Int?
        let strictProbeReferencesInEntrypoint: Int?
        let harvestedProbeReferencesInPartialReader: Int?
    }

    private static func fileCensus(
        fileName: String,
        isAssessment: Bool,
        scan: (
            proofMints: Int,
            assessmentReferences: Int,
            strictProbeReferences: Int,
            harvestedProbeReferences: Int
        )
    ) -> FileCensus {
        var offenders = probeCallSiteOffenders(
            fileName: fileName,
            strictProbeReferences: scan.strictProbeReferences,
            harvestedProbeReferences: scan.harvestedProbeReferences
        )
        if isAssessment {
            return FileCensus(
                offenders: offenders,
                proofMintInAssessment: scan.proofMints,
                assessmentReferencesInProvider: nil,
                strictProbeReferencesInEntrypoint: nil,
                harvestedProbeReferencesInPartialReader: nil
            )
        }

        let providerReferenceCount = fileName == providerFile ? scan.assessmentReferences : nil
        if scan.assessmentReferences > 0, providerReferenceCount == nil {
            offenders.append("\(fileName): references assessReadback")
        }
        if scan.proofMints > 0 {
            offenders.append("\(fileName): mints CompleteProof outside its file")
        }
        return FileCensus(
            offenders: offenders,
            proofMintInAssessment: nil,
            assessmentReferencesInProvider: providerReferenceCount,
            strictProbeReferencesInEntrypoint:
                fileName == probeEntryFile ? scan.strictProbeReferences : nil,
            harvestedProbeReferencesInPartialReader:
                fileName == partialReaderFile ? scan.harvestedProbeReferences : nil
        )
    }

    @Test func combinedScanParsesOnceAndRetainsSyntaxBoundaries() {
        let source = ##"""
        // assessReadback observeNoteTable observeHarvestedNoteTable CompleteProof()
        /* /* nested */ assessReadback observeNoteTable observeHarvestedNoteTable */
        let text = "assessReadback observeNoteTable observeHarvestedNoteTable CompleteProof()"
        let raw = #"assessReadback observeNoteTable observeHarvestedNoteTable CompleteProof()"#
        let assessment = `assessReadback`
        let probe = observeNoteTable
        let harvest = observeHarvestedNoteTable
        let interpolation = "\(assessReadback(evidence)) \(observeNoteTable()) \(observeHarvestedNoteTable())"
        let rawInterpolation = #"\#(assessReadback(evidence)) \#(observeNoteTable()) \#(observeHarvestedNoteTable())"#
        let proof = CompleteProof(contentBinding: binding)
        let contextual = .complete(.init(contentBinding: binding))
        let unrelated = .init(other: binding)
        """##
        var parserCalls = 0
        let result = Self.scan(source) { text in
            parserCalls += 1
            return Parser.parse(source: text)
        }
        #expect(parserCalls == 1)
        #expect(result.assessmentReferences == 3)
        #expect(result.strictProbeReferences == 3)
        #expect(result.harvestedProbeReferences == 3)
        #expect(result.proofMints == 2)
    }

    @Test func assessmentFileCannotBypassProbeCallSiteCensus() {
        let scan = Self.scan("let strict = observeNoteTable; let harvest = observeHarvestedNoteTable")
        let census = Self.fileCensus(
            fileName: Self.assessmentFile,
            isAssessment: true,
            scan: scan
        )

        #expect(census.offenders == [
            "\(Self.assessmentFile): references observeNoteTable",
            "\(Self.assessmentFile): references observeHarvestedNoteTable",
        ])
        #expect(census.proofMintInAssessment == 0)
    }

    @Test func onlyEventListProviderMayAssessReadbackAndProofMintIsExact() throws {
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
        var assessmentReferencesInProvider = 0
        var strictProbeReferencesInEntrypoint = 0
        var harvestedProbeReferencesInPartialReader = 0
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
            let scan = Self.scan(text)
            let census = Self.fileCensus(
                fileName: url.lastPathComponent,
                isAssessment: isAssessment,
                scan: scan
            )
            offenders.append(contentsOf: census.offenders)
            if let count = census.proofMintInAssessment {
                sawAssessmentFile = true
                proofMintInAssessment = count
            }
            if let count = census.assessmentReferencesInProvider {
                assessmentReferencesInProvider = count
            }
            if let count = census.strictProbeReferencesInEntrypoint {
                strictProbeReferencesInEntrypoint = count
            }
            if let count = census.harvestedProbeReferencesInPartialReader {
                harvestedProbeReferencesInPartialReader = count
            }
        }

        #expect(sawAssessmentFile, "expected the assessment file at \(assessmentPath)")
        #expect(scanned > 50, "expected to scan the LogicProMCP source tree; scanned \(scanned) files")
        #expect(offenders.isEmpty, "dark-core call-site lint offenders: \(offenders)")
        #expect(assessmentReferencesInProvider == 1,
                "\(Self.providerFile) must be the sole adapter call site for assessReadback")
        #expect(strictProbeReferencesInEntrypoint == 1,
                "\(Self.probeEntryFile) must contain the one CLI probe call to observeNoteTable")
        #expect(harvestedProbeReferencesInPartialReader == 1,
                "\(Self.partialReaderFile) must contain the one public partial-read call to observeHarvestedNoteTable")
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
        #expect(Self.completeProofMintCount("return .complete(CompleteProof ())") == 1)         // whitespace before paren
        #expect(Self.completeProofMintCount("return .complete(CompleteProof.init())") == 1)     // .init() construction
        #expect(Self.completeProofMintCount("return .complete(`CompleteProof`())") == 1)        // backtick construction
        #expect(Self.completeProofMintCount("return .complete(.init(contentBinding: x))") == 1) // CONTEXTUAL .init mint (the bypass)
        #expect(Self.completeProofMintCount("f(a: CompleteProof(contentBinding: x), b: .init(contentBinding: y))") == 2) // both forms
        #expect(Self.completeProofMintCount("return .complete(self.init(contentBinding: x))") == 1) // self.init delegation
        #expect(Self.completeProofMintCount("return .complete(LogicProMCP.CompleteProof(contentBinding: x))") == 1) // module-qualified type
        #expect(Self.completeProofMintCount("return .complete(LogicProMCP.CompleteProof.init(contentBinding: x))") == 1) // module-qualified .init
        // Not counted: comments, plain string content, member access, unrelated ids.
        #expect(Self.identifierCount("// minted only by assessReadback(evidence)", "assessReadback") == 0)
        #expect(Self.identifierCount("/* /* nested */ see assessReadback */", "assessReadback") == 0)
        #expect(Self.identifierCount("let id = \"eventListAX.assessReadback.v1\"", "assessReadback") == 0)
        #expect(Self.identifierCount("let u = \"/*\"; let x = 1", "assessReadback") == 0)               // /* inside a string, no ref
        #expect(Self.completeProofMintCount("CompleteProof.makeForTesting()") == 0)             // factory, not the initializer
        #expect(Self.completeProofMintCount("let x: Foo = .init(other: 1)") == 0)              // contextual .init, not contentBinding
        #expect(Self.completeProofMintCount("bar.baz(contentBinding: 1)") == 0)                // labeled call, not an initializer
        #expect(Self.completeProofMintCount("self.init(other: 1)") == 0)                        // self.init without contentBinding
    }
}

/// Structural counter for `CompleteProof` initializer calls, including a
/// contextual `.init(contentBinding:)` whose type is inferred (no `CompleteProof`
/// token). `contentBinding` is `CompleteProof`'s only initializer label, so an
/// implicit-base `.init(contentBinding:)` is unambiguously one of its mints.
private final class CompleteProofMintCounter: SyntaxVisitor {
    private(set) var count = 0

    private func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "")
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if isCompleteProofMint(node) { count += 1 }
        return .visitChildren
    }

    /// A call is a `CompleteProof` mint if it constructs the type by any Swift
    /// form. `contentBinding` is `CompleteProof`'s only initializer label, so an
    /// `init` call carrying it (contextual `.init`, `self.init`, `Type.init`) is
    /// unambiguously one of its mints even when the type token is absent.
    private func isCompleteProofMint(_ node: FunctionCallExprSyntax) -> Bool {
        let firstArgLabel = node.arguments.first?.label?.text
        // Bare `CompleteProof(...)` / `` `CompleteProof`(...) ``.
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            return stripped(ref.baseName.text) == "CompleteProof"
        }
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        let name = stripped(member.declName.baseName.text)
        // Member type construction: `X.CompleteProof(...)` (e.g. module-qualified).
        if name == "CompleteProof" { return true }
        // Any initializer call that targets CompleteProof by name
        // (`CompleteProof.init(...)`) or carries its unique `contentBinding` label
        // (`.init(contentBinding:)`, `self.init(contentBinding:)`, `X.init(...)`).
        if name == "init" {
            if let base = member.base?.as(DeclReferenceExprSyntax.self),
               stripped(base.baseName.text) == "CompleteProof" {
                return true
            }
            return firstArgLabel == "contentBinding"
        }
        return false
    }
}
