import Foundation
import Testing
@testable import LogicProMCP

/// Issue #210 — Swift cliclick trust resolver, kept in parity with Scripts/logic_bounce_ui.py.
@Suite("cliclick trust resolver (#210)", .serialized)
struct CliclickTrustResolverTests {
    typealias Deps = ProjectExportExecutor.CliclickResolverDeps
    typealias Rejection = ProjectExportExecutor.CliclickRejection

    /// Hermetic filesystem. files/dirs: path -> (mode, uid). realpath default identity.
    private func deps(
        files: [String: (mode: Int, uid: UInt32)] = [:],
        dirs: [String: (mode: Int, uid: UInt32)] = [:],
        realpath: [String: String] = [:],
        executables: Set<String>? = nil,
        uid: UInt32 = 501,
        sha256: [String: String] = [:]
    ) -> Deps {
        let exes = executables ?? Set(files.keys)
        return Deps(
            isExecutable: { exes.contains($0) },
            attributesOfItem: { path in
                if let file = files[path] {
                    return [.type: FileAttributeType.typeRegular,
                            .posixPermissions: NSNumber(value: file.mode),
                            .ownerAccountID: NSNumber(value: file.uid)]
                }
                if let dir = dirs[path] {
                    return [.type: FileAttributeType.typeDirectory,
                            .posixPermissions: NSNumber(value: dir.mode),
                            .ownerAccountID: NSNumber(value: dir.uid)]
                }
                throw NSError(domain: "test.fakefs", code: 2)
            },
            isRegularFile: { files[$0] != nil },   // dirs are not regular files
            realpath: { realpath[$0] ?? ($0.hasPrefix("/") ? $0 : nil) },
            sha256OfFile: { sha256[$0] },
            currentUid: { uid }
        )
    }

    /// A clean approved tree at /approved/bin/cliclick, 0o755, owned by self (501), "/" root-owned.
    private var approvedFiles: [String: (mode: Int, uid: UInt32)] { ["/approved/bin/cliclick": (0o755, 501)] }
    private var approvedDirs: [String: (mode: Int, uid: UInt32)] {
        ["/approved/bin": (0o755, 501), "/approved": (0o755, 501), "/": (0o755, 0)]
    }

    private func firstReason(_ res: ProjectExportExecutor.CliclickResolution) -> Rejection? {
        res.candidates.first?.reason
    }

    // MARK: canonical (NG1)

    @Test func canonical_parent_writable() {
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: [:],
            deps: deps(files: ["/opt/homebrew/bin/cliclick": (0o755, 501)],
                       dirs: ["/opt/homebrew/bin": (0o775, 501)])
        )
        #expect(res.resolvedPath == nil)
        #expect(firstReason(res) == .parentWritable)
    }

    @Test func canonical_resolved() {
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: [:],
            deps: deps(files: ["/opt/homebrew/bin/cliclick": (0o755, 501)],
                       dirs: ["/opt/homebrew/bin": (0o755, 501)])
        )
        #expect(res.resolvedPath == "/opt/homebrew/bin/cliclick")
        #expect(firstReason(res) == .resolved)
    }

    @Test func canonical_not_executable() {
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: [:],
            deps: deps(files: ["/opt/homebrew/bin/cliclick": (0o644, 501)],
                       dirs: ["/opt/homebrew/bin": (0o755, 501)],
                       executables: [])
        )
        #expect(res.resolvedPath == nil)
        #expect(firstReason(res) == .notExecutable)
    }

    @Test func canonical_not_found_missing_file() {  // guardian P2-1
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: [:],
            deps: deps(files: [:], dirs: ["/opt/homebrew/bin": (0o755, 501)])
        )
        #expect(res.resolvedPath == nil)
        #expect(firstReason(res) == .notFound)
    }

    @Test func canonical_directory_rejected() {  // boomer #1: a directory at a canonical path
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: [:],
            deps: deps(files: [:],
                       dirs: ["/opt/homebrew/bin/cliclick": (0o755, 501),  // a DIRECTORY named cliclick
                              "/opt/homebrew/bin": (0o755, 501)],
                       executables: ["/opt/homebrew/bin/cliclick"])  // dir has the x (search) bit
        )
        #expect(res.resolvedPath == nil)  // must NOT be accepted (parity with Python isfile)
        #expect(firstReason(res) == .notFound)
    }

    @Test func arbitrary_realpath_nil_is_not_found() {  // guardian P2-1
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/missing/cliclick"],
            deps: deps(realpath: [:])  // realpath returns nil for an unmapped path → not_found
        )
        #expect(firstReason(res) == .notFound)
    }

    // MARK: arbitrary override (strict)

    @Test func arbitrary_resolved_returns_real_path() {
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick"],
            deps: deps(files: approvedFiles, dirs: approvedDirs)
        )
        #expect(res.resolvedPath == "/approved/bin/cliclick")
        #expect(firstReason(res) == .resolved)
    }

    @Test func arbitrary_not_absolute() {
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "relative/cliclick"],
            deps: deps()
        )
        #expect(firstReason(res) == .notAbsolute)
    }

    @Test func arbitrary_file_writable() {
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick"],
            deps: deps(files: ["/approved/bin/cliclick": (0o757, 501)], dirs: approvedDirs)
        )
        #expect(firstReason(res) == .fileWritable)
    }

    @Test func arbitrary_owner_untrusted() {
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick"],
            deps: deps(files: ["/approved/bin/cliclick": (0o755, 999)], dirs: approvedDirs)
        )
        #expect(firstReason(res) == .ownerUntrusted)
    }

    @Test func arbitrary_ancestor_writable() {
        var dirs = approvedDirs
        dirs["/approved"] = (0o775, 501)
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick"],
            deps: deps(files: approvedFiles, dirs: dirs)
        )
        #expect(firstReason(res) == .ancestorWritable)
    }

    @Test func arbitrary_ancestor_hostile_owner() {
        var dirs = approvedDirs
        dirs["/approved/bin"] = (0o755, 999) // non-writable but owned by a hostile non-root user
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick"],
            deps: deps(files: approvedFiles, dirs: dirs)
        )
        #expect(firstReason(res) == .ancestorWritable)
    }

    @Test func arbitrary_symlink_real_ancestry_rejected() {
        // Override → symlink whose REAL target sits under a writable Cellar (the live #210 case).
        let real = "/opt/homebrew/Cellar/cliclick/5.1/bin/cliclick"
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/opt/homebrew/bin/cliclick"],
            deps: deps(
                files: [real: (0o755, 501)],
                dirs: [
                    "/opt/homebrew/Cellar/cliclick/5.1/bin": (0o755, 501),
                    "/opt/homebrew/Cellar/cliclick/5.1": (0o755, 501),
                    "/opt/homebrew/Cellar/cliclick": (0o755, 501),
                    "/opt/homebrew/Cellar": (0o775, 501), // writable ancestor
                    "/opt/homebrew": (0o755, 501), "/opt": (0o755, 0), "/": (0o755, 0),
                ],
                realpath: ["/opt/homebrew/bin/cliclick": real]
            )
        )
        #expect(firstReason(res) == .ancestorWritable)
    }

    @Test func arbitrary_sha256_match_and_mismatch() {
        let digest = String(repeating: "a", count: 64)
        let okRes = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick",
                          "LOGIC_PRO_MCP_CLICLICK_SHA256": digest.uppercased()],
            deps: deps(files: approvedFiles, dirs: approvedDirs, sha256: ["/approved/bin/cliclick": digest])
        )
        #expect(okRes.resolvedPath == "/approved/bin/cliclick")

        let badRes = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick",
                          "LOGIC_PRO_MCP_CLICLICK_SHA256": String(repeating: "b", count: 64)],
            deps: deps(files: approvedFiles, dirs: approvedDirs, sha256: ["/approved/bin/cliclick": digest])
        )
        #expect(firstReason(badRes) == .sha256Mismatch)
    }

    @Test func arbitrary_sha256_blank_or_malformed_rejected() {
        let digest = String(repeating: "a", count: 64)
        for pin in ["   ", String(repeating: "z", count: 64)] {
            let res = ProjectExportExecutor.resolveCliclickDetailed(
                environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick",
                              "LOGIC_PRO_MCP_CLICLICK_SHA256": pin],
                deps: deps(files: approvedFiles, dirs: approvedDirs, sha256: ["/approved/bin/cliclick": digest])
            )
            #expect(firstReason(res) == .sha256Mismatch, "pin \"\(pin)\" must reject")
        }
    }

    // MARK: resolution + fallthrough + diagnosis

    @Test func override_rejected_does_not_suppress_canonical_fallthrough() {
        var dirs = approvedDirs
        dirs["/approved"] = (0o775, 501) // override rejected: ancestor_writable
        dirs["/opt/homebrew/bin"] = (0o755, 501)
        var files = approvedFiles
        files["/opt/homebrew/bin/cliclick"] = (0o755, 501)
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: ["LOGIC_PRO_MCP_CLICLICK": "/approved/bin/cliclick"],
            deps: deps(files: files, dirs: dirs)
        )
        #expect(res.resolvedPath == "/opt/homebrew/bin/cliclick")
        let overrideCandidate = res.candidates.first { $0.source == .override }
        #expect(overrideCandidate?.reason == .ancestorWritable)
    }

    @Test func diagnostic_summary_lists_reasons_and_remediation() {
        let res = ProjectExportExecutor.resolveCliclickDetailed(
            environment: [:],
            deps: deps(dirs: ["/opt/homebrew/bin": (0o775, 501)])
        )
        #expect(res.resolvedPath == nil)
        #expect(res.diagnosticSummary.contains("parent_writable"))
        #expect(res.diagnosticSummary.contains("chmod g-w /opt/homebrew/bin"))
    }

    @Test func resolveTrustedCliclick_wrapper_delegates_to_detailed() {
        // Back-compat: the String? wrapper returns resolveCliclickDetailed().resolvedPath.
        // Machine-independent: nothing is executable → every candidate rejects → nil.
        let path = ProjectExportExecutor.resolveTrustedCliclick(
            environment: [:],
            isExecutable: { _ in false },
            attributesOfItem: { _ in [.posixPermissions: NSNumber(value: 0o755)] }
        )
        #expect(path == nil)
    }
}
