class LogicProMcp < Formula
  desc "MCP server for Logic Pro — the missing API"
  homepage "https://github.com/MongLong0214/logic-pro-mcp"
  # Single source of truth is Sources/LogicProMCP/Server/ServerConfig.swift
  # (ServerConfig.serverVersion). Bump both together.
  version "3.4.6"
  license "MIT"

  # GitHub Actions release artifacts are expected to be true universal
  # tarballs. Historical/local ADHOC prerelease cuts may still record
  # arm64-only metadata, so inspect RELEASE-METADATA.json when auditing a
  # specific tag.
  #
  # SHA256 is copied from the published v3.4.6 SHA256SUMS.txt for
  # LogicProMCP-macOS-universal.tar.gz.
  on_macos do
    url "https://github.com/MongLong0214/logic-pro-mcp/releases/download/v#{version}/LogicProMCP-macOS-universal.tar.gz"
    sha256 "6420274b4fbbb863226a2a163b971a36161c10880e8f3a06d979100a35bc01d3"
  end

  depends_on :macos => :sonoma

  # NOTE (v3.1.6): no `depends_on xcode:` — this Formula installs the
  # pre-built GitHub release binary; it does not invoke `swift build` or any
  # Apple toolchain. Source builds via `Package.swift` still require Xcode
  # 16.4+ (Swift 6.2) because the resolved swift-sdk dependency requires the
  # newer compiler inference behavior.

  def install
    bin.install "LogicProMCP"
    # Helper assets shipped with the binary so users can complete Logic Pro
    # integration without re-cloning the repo.
    pkgshare.install "SETUP.md"
    pkgshare.install "install-keycmds.sh"
    pkgshare.install "uninstall-keycmds.sh"
    pkgshare.install "keycmd-preset.plist"
    pkgshare.install "LogicProMCP-Scripter.js"
  end

  def caveats
    <<~EOS
      Logic Pro MCP Server is installed at #{bin}/LogicProMCP.

      Register with Claude Code:
        claude mcp add --scope user logic-pro -- LogicProMCP

      Check macOS permissions:
        LogicProMCP --check-permissions

      Complete Logic Pro integration (MCU, Key Commands, Scripter):
        open #{pkgshare}/SETUP.md

      Approve manual-validation channels after Logic Pro setup:
        LogicProMCP --approve-channel MIDIKeyCommands
        LogicProMCP --approve-channel Scripter
    EOS
  end

  test do
    # Verify the binary runs and prints the expected report shape on
    # `--check-permissions`. Exit code is 0 when both Accessibility and
    # Logic Automation are granted (typical Logic-installed dev box) and
    # non-zero when at least one is missing (typical CI). Don't constrain
    # the test to a specific code — both are valid; the report contents
    # are the contract this test guards.
    output = shell_output("#{bin}/LogicProMCP --check-permissions 2>&1; echo \"exit=$?\"")
    assert_match(/Accessibility/, output)
    assert_match(/Automation/, output)
    assert_match(/exit=[01]/, output, "exit code should be 0 (granted) or 1 (missing)")
  end
end
