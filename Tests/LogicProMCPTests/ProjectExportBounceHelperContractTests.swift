import Foundation
import Testing
@testable import LogicProMCP

@Suite("Project export bounce helper contract", .serialized)
struct ProjectExportBounceHelperContractTests {
    // Use nonexistent fixture roots; real /opt/homebrew can make URL stats stall on CI.
    private static let trustedCliclick = "/opt/homebrew/bin/cliclick"

    // #210: the resolveCliclick seam now returns a CliclickResolution. Test helpers.
    private static func resolvedCliclick(_ path: String) -> ProjectExportExecutor.CliclickResolution {
        .init(resolvedPath: path, candidates: [.init(path: path, source: .canonical, reason: .resolved)])
    }
    private static let unresolvedCliclick = ProjectExportExecutor.CliclickResolution(
        resolvedPath: nil,
        candidates: [.init(path: "/opt/homebrew/bin/cliclick", source: .canonical, reason: .parentWritable)]
    )

    @Test("resolver honors LOGIC_PRO_MCP_SHARE_DIR for custom install layouts")
    func resolverUsesConfiguredShareDir() {
        let resolved = ProjectExportExecutor.resolveBounceHelperPath(
            environment: ["LOGIC_PRO_MCP_SHARE_DIR": "/tmp/custom/share/logic-pro-mcp"],
            currentDirectoryPath: "/tmp/elsewhere",
            executablePath: nil,
            commandLineExecutablePath: "LogicProMCP",
            processExecutablePath: nil,
            fileExists: { $0 == "/tmp/custom/share/logic-pro-mcp/logic_bounce.py" },
            resolveSymlinks: { $0 }
        )
        #expect(resolved == "/tmp/custom/share/logic-pro-mcp/logic_bounce.py")
    }

    @Test("bare PATH arg0 is ignored when no real executable path is available")
    func barePathNameArgvZeroIsIgnoredWithoutResolvedExecutablePath() {
        let effective = ProjectExportExecutor.effectiveExecutablePath(
            overrideExecutablePath: nil,
            commandLineExecutablePath: "LogicProMCP",
            processExecutablePath: nil
        )
        #expect(effective == nil)
    }

    @Test("resolver uses the real executable path when arg0 is only a PATH name")
    func resolverUsesProcessExecutablePathForPathLaunches() {
        let homebrew = ProjectExportExecutor.resolveBounceHelperPath(
            environment: [:],
            currentDirectoryPath: "/tmp/elsewhere",
            executablePath: nil,
            commandLineExecutablePath: "LogicProMCP",
            processExecutablePath: "/private/tmp/lpmcp-cellar-fixture/Cellar/logic-pro-mcp/3.7.1/bin/LogicProMCP",
            fileExists: {
                $0 == "/private/tmp/lpmcp-cellar-fixture/Cellar/logic-pro-mcp/3.7.1/share/logic-pro-mcp/logic_bounce.py"
            },
            resolveSymlinks: { $0 }
        )
        #expect(
            homebrew == "/private/tmp/lpmcp-cellar-fixture/Cellar/logic-pro-mcp/3.7.1/share/logic-pro-mcp/logic_bounce.py"
        )
    }

    @Test("resolver finds flattened helper assets for custom non-bin installs")
    func resolverFindsFlattenedHelperForCustomNonBinInstall() {
        let resolved = ProjectExportExecutor.resolveBounceHelperPath(
            environment: [:],
            currentDirectoryPath: "/tmp/elsewhere",
            executablePath: "/tmp/LogicProMCP-root/LogicProMCP",
            fileExists: {
                $0 == "/tmp/LogicProMCP-root/share/logic-pro-mcp/logic_bounce.py"
            },
            resolveSymlinks: { $0 }
        )
        #expect(resolved == "/tmp/LogicProMCP-root/share/logic-pro-mcp/logic_bounce.py")
    }

    @Test("resolver finds repo, extracted, and flattened Homebrew helper locations")
    func resolverFindsPackagedHelperLocations() {
        let sourceBuild = ProjectExportExecutor.resolveBounceHelperPath(
            environment: [:],
            currentDirectoryPath: "/tmp/elsewhere",
            executablePath: "/Users/test/logic-pro-mcp/.build/debug/LogicProMCP",
            fileExists: {
                $0 == "/Users/test/logic-pro-mcp/Package.swift" ||
                    $0 == "/Users/test/logic-pro-mcp/Scripts/logic_bounce.py"
            },
            resolveSymlinks: { $0 }
        )
        #expect(sourceBuild == "/Users/test/logic-pro-mcp/Scripts/logic_bounce.py")

        let extracted = ProjectExportExecutor.resolveBounceHelperPath(
            environment: [:],
            currentDirectoryPath: "/tmp/elsewhere",
            executablePath: "/Applications/LogicProMCP/LogicProMCP",
            fileExists: { $0 == "/Applications/LogicProMCP/Scripts/logic_bounce.py" },
            resolveSymlinks: { $0 }
        )
        #expect(extracted == "/Applications/LogicProMCP/Scripts/logic_bounce.py")

        let homebrew = ProjectExportExecutor.resolveBounceHelperPath(
            environment: [:],
            currentDirectoryPath: "/tmp/elsewhere",
            executablePath: "/private/tmp/lpmcp-cellar-fixture/Cellar/logic-pro-mcp/3.7.1/bin/LogicProMCP",
            fileExists: {
                $0 == "/private/tmp/lpmcp-cellar-fixture/Cellar/logic-pro-mcp/3.7.1/share/logic-pro-mcp/logic_bounce.py"
            },
            resolveSymlinks: { $0 }
        )
        #expect(
            homebrew == "/private/tmp/lpmcp-cellar-fixture/Cellar/logic-pro-mcp/3.7.1/share/logic-pro-mcp/logic_bounce.py"
        )
    }

    @Test("runBounceHelper surfaces a missing helper path")
    func runBounceHelperFailsWhenHelperIsMissing() async throws {
        let result = await withBounceHelperOverride("/tmp/logic-bounce-missing.py") {
            await ProjectExportExecutor.runBounceHelper(
                artifactPath: "/tmp/output/Song.wav",
                fileExists: { _ in false },
                runProcess: { _, _, _ in
                    Issue.record("missing helper path should fail before spawning the subprocess")
                    return .timedOut
                }
            )
        }

        #expect(result.artifactPath == nil)
        #expect(result.error == "bounce_helper_missing: /tmp/logic-bounce-missing.py")
    }

    @Test("cliclick resolver ignores PATH hijacks and rejects writable trusted dirs")
    func cliclickResolverRejectsUntrustedLocations() {
        // PATH hijack: nothing trusted is executable → rejected. (Acceptance is covered
        // hermetically in CliclickTrustResolverTests, which can inject the realpath/isRegularFile
        // seams the String? wrapper does not expose.)
        let hijacked = ProjectExportExecutor.resolveTrustedCliclick(
            environment: ["PATH": "/tmp"],
            isExecutable: { $0 == "/tmp/cliclick" },
            attributesOfItem: { _ in [.posixPermissions: NSNumber(value: 0o755)] }
        )
        #expect(hijacked == nil)

        // Writable canonical parent (0o777) → rejected before any file check.
        let writableTrustedDir = ProjectExportExecutor.resolveTrustedCliclick(
            environment: ["LOGIC_PRO_MCP_CLICLICK": Self.trustedCliclick],
            isExecutable: { $0 == Self.trustedCliclick },
            attributesOfItem: { _ in [.posixPermissions: NSNumber(value: 0o777)] }
        )
        #expect(writableTrustedDir == nil)
    }

    @Test("runBounceHelper fails closed before launch when cliclick is missing")
    func runBounceHelperFailsWhenCliclickIsMissing() async throws {
        let result = await ProjectExportExecutor.runBounceHelper(
            artifactPath: "/tmp/output/Song.wav",
            environment: [:],
            currentDirectoryPath: "/tmp/repo",
            executablePath: "/Applications/LogicProMCP/LogicProMCP",
            fileExists: { $0 == "/Applications/LogicProMCP/Scripts/logic_bounce.py" },
            resolveCliclick: { _ in Self.unresolvedCliclick },
            runProcess: { _, _, _ in
                Issue.record("missing cliclick should fail before spawning the helper")
                return .timedOut
            }
        )

        #expect(result.artifactPath == nil)
        // #210: the failure is now diagnosable — prefix preserved, candidate reasons + remediation appended.
        let error = try #require(result.error)
        #expect(error.hasPrefix("bounce_helper_dependency_missing: cliclick"))
        #expect(error.contains("parent_writable"))
        #expect(error.contains("chmod g-w /opt/homebrew/bin"))
        #expect(!result.bounceFired)
    }

    @Test("runBounceHelper surfaces timeout and stderr fallback")
    func runBounceHelperHandlesTimeoutAndStderrFallback() async {
        let timedOut = await ProjectExportExecutor.runBounceHelper(
            artifactPath: "/tmp/output/Song.wav",
            environment: [:],
            currentDirectoryPath: "/tmp/repo",
            executablePath: "/Applications/LogicProMCP/LogicProMCP",
            fileExists: { $0 == "/Applications/LogicProMCP/Scripts/logic_bounce.py" },
            resolveCliclick: { _ in Self.resolvedCliclick(Self.trustedCliclick) },
            runProcess: { _, arguments, _ in
                #expect(Array(arguments.suffix(2)) == ["--cliclick-path", Self.trustedCliclick])
                return .timedOut
            }
        )
        #expect(timedOut.artifactPath == nil)
        #expect(timedOut.error == "bounce_helper_timed_out")
        #expect(!timedOut.bounceFired)

        let stderrFallback = await ProjectExportExecutor.runBounceHelper(
            artifactPath: "/tmp/output/Song.wav",
            environment: [:],
            currentDirectoryPath: "/tmp/repo",
            executablePath: "/Applications/LogicProMCP/LogicProMCP",
            fileExists: { $0 == "/Applications/LogicProMCP/Scripts/logic_bounce.py" },
            resolveCliclick: { _ in Self.resolvedCliclick(Self.trustedCliclick) },
            runProcess: { _, _, _ in
                .completed(
                    .init(
                        exitCode: 2,
                        stdout: "not-json",
                        stderr: "panel click failed",
                        stdoutTruncated: false,
                        stderrTruncated: false
                    )
                )
            }
        )
        #expect(stderrFallback.artifactPath == nil)
        #expect(stderrFallback.error == "panel click failed")
        #expect(!stderrFallback.bounceFired)
    }

    @Test("runBounceHelper rejects success-looking JSON on non-zero exit and surfaces helper JSON errors")
    func runBounceHelperRejectsNonZeroSuccessJson() async {
        let nonZeroSuccess = await ProjectExportExecutor.runBounceHelper(
            artifactPath: "/tmp/output/Song.wav",
            environment: [:],
            currentDirectoryPath: "/tmp/repo",
            executablePath: "/Applications/LogicProMCP/LogicProMCP",
            fileExists: { $0 == "/Applications/LogicProMCP/Scripts/logic_bounce.py" },
            resolveCliclick: { _ in Self.resolvedCliclick(Self.trustedCliclick) },
            runProcess: { _, _, _ in
                .completed(
                    .init(
                        exitCode: 9,
                        stdout: #"{"success":true,"artifact":"/tmp/output/Song.aif"}"#,
                        stderr: "",
                        stdoutTruncated: false,
                        stderrTruncated: false
                    )
                )
            }
        )
        #expect(nonZeroSuccess.artifactPath == nil)
        #expect(nonZeroSuccess.error?.contains("bounce_helper_exit_code_9") == true)
        #expect(nonZeroSuccess.bounceFired)

        let helperJsonError = await ProjectExportExecutor.runBounceHelper(
            artifactPath: "/tmp/output/Song.wav",
            environment: [:],
            currentDirectoryPath: "/tmp/repo",
            executablePath: "/Applications/LogicProMCP/LogicProMCP",
            fileExists: { $0 == "/Applications/LogicProMCP/Scripts/logic_bounce.py" },
            resolveCliclick: { _ in Self.resolvedCliclick(Self.trustedCliclick) },
            runProcess: { _, _, _ in
                .completed(
                    .init(
                        exitCode: 0,
                        stdout: #"{"success":false,"error":"artifact_not_produced_in_staging","bounce_fired":true}"#,
                        stderr: "",
                        stdoutTruncated: false,
                        stderrTruncated: false
                    )
                )
            }
        )
        #expect(helperJsonError.artifactPath == nil)
        #expect(helperJsonError.error == "artifact_not_produced_in_staging")
        #expect(helperJsonError.bounceFired)
    }

    // Regression: an explicit `bounce_fired:false` from the helper must be
    // authoritative even when a non-empty `artifact` is also present. The
    // pre-fix `??`/`||` precedence let the artifact field flip bounceFired back
    // to true, masking the helper's honest signal.
    @Test("runBounceHelper honors explicit bounce_fired:false over a non-empty artifact")
    func runBounceHelperHonorsExplicitBounceFiredFalse() async {
        let result = await ProjectExportExecutor.runBounceHelper(
            artifactPath: "/tmp/output/Song.wav",
            environment: [:],
            currentDirectoryPath: "/tmp/repo",
            executablePath: "/Applications/LogicProMCP/LogicProMCP",
            fileExists: { $0 == "/Applications/LogicProMCP/Scripts/logic_bounce.py" },
            resolveCliclick: { _ in Self.resolvedCliclick(Self.trustedCliclick) },
            runProcess: { _, _, _ in
                .completed(
                    .init(
                        exitCode: 3,
                        stdout: #"{"success":false,"bounce_fired":false,"artifact":"/tmp/output/Song.aif","error":"bounce_aborted"}"#,
                        stderr: "",
                        stdoutTruncated: false,
                        stderrTruncated: false
                    )
                )
            }
        )
        #expect(result.artifactPath == nil)
        #expect(result.error == "bounce_aborted")
        #expect(!result.bounceFired)
    }
}
