import Foundation

func installScriptContractRepositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func scriptContents(_ relativePath: String) throws -> String {
    try String(contentsOf: installScriptContractRepositoryRootURL().appendingPathComponent(relativePath), encoding: .utf8)
}

struct ScriptRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        stdout + stderr
    }
}

struct InstallerFixture {
    let sandbox: URL
    let archiveURL: URL
    let sha256: String
    let fakeBin: URL
    let installRoot: URL
    let shareDir: URL
    let claudeLog: URL
    let pathEnv: String
}

@discardableResult
func runProcess(
    executable: String,
    arguments: [String],
    currentDirectoryURL: URL,
    environment: [String: String] = [:]
) throws -> ScriptRunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for key in mergedEnvironment.keys where key.hasPrefix("LOGIC_PRO_MCP_") {
        mergedEnvironment.removeValue(forKey: key)
    }
    for (key, value) in environment {
        mergedEnvironment[key] = value
    }
    process.environment = mergedEnvironment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()

    let stdout = String(
        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let stderr = String(
        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    return ScriptRunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

func runShellScript(
    _ relativePath: String,
    environment: [String: String] = [:]
) throws -> ScriptRunResult {
    try runProcess(
        executable: "/bin/bash",
        arguments: [installScriptContractRepositoryRootURL().appendingPathComponent(relativePath).path],
        currentDirectoryURL: installScriptContractRepositoryRootURL(),
        environment: environment
    )
}

func makeInstallScriptTempDir(_ name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeExecutable(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func writeFile(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

func makeInstallerFixture(
    includeProjectHelperScripts: Bool = true,
    includeSharedJXAHelper: Bool = true,
    symlinkedBounceHelper: Bool = false
) throws -> InstallerFixture {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-install-fixture-\(UUID().uuidString)")
    let payload = sandbox.appendingPathComponent("payload", isDirectory: true)
    let docs = payload.appendingPathComponent("docs", isDirectory: true)
    let scripts = payload.appendingPathComponent("Scripts", isDirectory: true)
    let archiveURL = sandbox.appendingPathComponent("LogicProMCP-macOS-universal.tar.gz")
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let installRoot = sandbox.appendingPathComponent("custom-install-root", isDirectory: true)
    let shareDir = installRoot.appendingPathComponent("share/logic-pro-mcp", isDirectory: true)
    let claudeLog = sandbox.appendingPathComponent("claude-args.log")

    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)

    try writeExecutable(
        payload.appendingPathComponent("LogicProMCP"),
        contents: """
        #!/bin/bash
        if [ "${1:-}" = "--check-permissions" ]; then
          echo "Accessibility: granted"
          echo "Automation: granted"
        fi
        exit 0
        """
    )
    try writeFile(docs.appendingPathComponent("SETUP.md"), contents: "setup")
    try writeExecutable(scripts.appendingPathComponent("install-keycmds.sh"), contents: "#!/bin/bash\nexit 0\n")
    try writeExecutable(scripts.appendingPathComponent("uninstall-keycmds.sh"), contents: "#!/bin/bash\nexit 0\n")
    try writeFile(scripts.appendingPathComponent("keycmd-preset.plist"), contents: "plist")
    try writeFile(scripts.appendingPathComponent("LogicProMCP-Scripter.js"), contents: "// scripter\n")
    if includeProjectHelperScripts {
        try writeExecutable(scripts.appendingPathComponent("logic_bounce.py"), contents: "#!/usr/bin/env python3\nprint('{}')\n")
        try writeExecutable(scripts.appendingPathComponent("logic_bounce_ui.py"), contents: "#!/usr/bin/env python3\n")
        if includeSharedJXAHelper {
            try writeExecutable(scripts.appendingPathComponent("logic_ui_jxa.py"), contents: "#!/usr/bin/env python3\n")
        }
        try writeExecutable(scripts.appendingPathComponent("logic_input_source.py"), contents: "#!/usr/bin/env python3\n")
        if symlinkedBounceHelper {
            let target = sandbox.appendingPathComponent("outside-bounce-helper.py")
            try writeFile(target, contents: "# outside\n")
            try FileManager.default.removeItem(at: scripts.appendingPathComponent("logic_bounce.py"))
            try FileManager.default.createSymbolicLink(
                at: scripts.appendingPathComponent("logic_bounce.py"),
                withDestinationURL: target
            )
        }
    }

    let tarResult = try runProcess(
        executable: "/usr/bin/tar",
        arguments: [
            "-czf",
            archiveURL.path,
            "-C",
            payload.path,
            "LogicProMCP",
            "docs",
            "Scripts",
        ],
        currentDirectoryURL: installScriptContractRepositoryRootURL()
    )
    guard tarResult.exitCode == 0 else {
        throw NSError(
            domain: "InstallScriptContractTests",
            code: Int(tarResult.exitCode),
            userInfo: [NSLocalizedDescriptionKey: "tar failed: \(tarResult.combinedOutput)"]
        )
    }

    let shaResult = try runProcess(
        executable: "/usr/bin/shasum",
        arguments: ["-a", "256", archiveURL.path],
        currentDirectoryURL: installScriptContractRepositoryRootURL()
    )
    guard shaResult.exitCode == 0,
          let sha256 = shaResult.stdout.split(separator: " ").first.map(String.init) else {
        throw NSError(
            domain: "InstallScriptContractTests",
            code: Int(shaResult.exitCode),
            userInfo: [NSLocalizedDescriptionKey: "shasum failed: \(shaResult.combinedOutput)"]
        )
    }

    try writeExecutable(
        fakeBin.appendingPathComponent("curl"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        out=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then
            out="$2"
            shift 2
            continue
          fi
          shift
        done
        cp "$FAKE_RELEASE_ARCHIVE" "$out"
        """
    )
    try writeExecutable(fakeBin.appendingPathComponent("codesign"), contents: "#!/bin/bash\nexit 0\n")
    try writeExecutable(
        fakeBin.appendingPathComponent("claude"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        : > "$CLAUDE_LOG"
        for arg in "$@"; do
          printf '%s\n' "$arg" >> "$CLAUDE_LOG"
        done
        exit 0
        """
    )
    return InstallerFixture(
        sandbox: sandbox,
        archiveURL: archiveURL,
        sha256: sha256,
        fakeBin: fakeBin,
        installRoot: installRoot,
        shareDir: shareDir,
        claudeLog: claudeLog,
        pathEnv: "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
    )
}
