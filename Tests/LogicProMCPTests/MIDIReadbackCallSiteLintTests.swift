import Foundation
import Testing
@testable import LogicProMCP

// Acceptance lint (runs in every configuration): the pure `assessReadback`
// chokepoint has NO production call site, and the `CompleteProof` mint appears
// only in its defining file. This keeps the dark core inert — nothing in the
// shipped binary invokes the assessment or constructs a completeness proof. When
// the live provider is added it becomes the single allowed caller, and this lint
// is updated to name it.
@Suite struct MIDIReadbackCallSiteLintTests {
    @Test func assessReadbackHasNoProductionCallSiteAndProofMintIsConfined() throws {
        let assessmentFile = "MIDIReadbackAssessment.swift"
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

        var scanned = 0
        var offenders: [String] = []
        let enumerator = fm.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let name = url.lastPathComponent
            guard name != assessmentFile else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("assessReadback(") {
                offenders.append("\(name): production call to assessReadback")
            }
            if text.contains("CompleteProof(") {
                offenders.append("\(name): CompleteProof mint outside its file")
            }
        }

        #expect(scanned > 50, "expected to scan the LogicProMCP source tree; scanned \(scanned) files")
        #expect(offenders.isEmpty,
                "assessReadback must have no production call site and CompleteProof must be minted only in \(assessmentFile): \(offenders)")
    }
}
