class LogicProMcp < Formula
  desc "MCP server for Logic Pro — the missing API"
  homepage "https://github.com/MongLong0214/logic-pro-mcp"
  # Single source of truth is Sources/LogicProMCP/Server/ServerConfig.swift
  # (ServerConfig.serverVersion). Bump both together.
  version "3.0.2"
  license "MIT"

  # arm64-native binary. Intel Macs run under Rosetta 2 — functional but
  # slower + with minor CoreMIDI / AX timing differences. The release workflow
  # with full Xcode + `swift build --arch arm64 --arch x86_64` would emit a
  # true universal binary; ADHOC local releases ship arm64 only. The tarball
  # is published under both `-arm64` and `-universal` names for backward
  # compatibility with taps that hardcoded the older URL — the bytes are
  # identical.
  #
  # NOTE: sha256 below is the v3.0.1 adhoc-signed tarball shipped on GitHub.
  #       Update every release from the published SHA256SUMS.txt.
  on_macos do
    url "https://github.com/MongLong0214/logic-pro-mcp/releases/download/v#{version}/LogicProMCP-macOS-universal.tar.gz"
    sha256 "713cbd4d2bd359746d082ba00fc117d1596fcce7183cca715f82ece1771bdc92"
  end

  depends_on :macos => :sonoma
  depends_on xcode: ["15.0", :build]

  def install
    bin.install "LogicProMCP"
    # Helper assets shipped with the binary so users can complete Logic Pro
    # integration without re-cloning the repo.
    pkgshare.install "docs/SETUP.md"
    pkgshare.install "Scripts/install-keycmds.sh"
    pkgshare.install "Scripts/uninstall-keycmds.sh"
    pkgshare.install "Scripts/keycmd-preset.plist"
    pkgshare.install "Scripts/LogicProMCP-Scripter.js"
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
    # Verify the binary runs and exits cleanly on --check-permissions
    output = shell_output("#{bin}/LogicProMCP --check-permissions 2>&1", 1)
    assert_match(/Accessibility/, output)
    assert_match(/Automation/, output)
  end
end
