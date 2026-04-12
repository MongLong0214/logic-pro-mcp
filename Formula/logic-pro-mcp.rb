class LogicProMcp < Formula
  desc "MCP server for Logic Pro — the missing API"
  homepage "https://github.com/MongLong0214/logic-pro-mcp"
  version "2.1.0"
  license "MIT"

  # Apple Silicon + Intel unified binary via swift build -c release (macOS universal)
  on_macos do
    url "https://github.com/MongLong0214/logic-pro-mcp/releases/download/v#{version}/LogicProMCP-macOS-universal.tar.gz"
    # Populate sha256 from release SHA256SUMS.txt before publishing:
    sha256 "REPLACE_WITH_RELEASE_SHA256"
  end

  depends_on :macos => :sonoma
  depends_on xcode: ["15.0", :build]

  def install
    bin.install "LogicProMCP"
  end

  def caveats
    <<~EOS
      Logic Pro MCP Server is installed at #{bin}/LogicProMCP.

      To register with Claude Code:
        claude mcp add --scope user logic-pro -- LogicProMCP

      To register with Claude Desktop, add to
        ~/Library/Application Support/Claude/claude_desktop_config.json:

        {
          "mcpServers": {
            "logic-pro": {
              "command": "#{bin}/LogicProMCP",
              "args": []
            }
          }
        }

      Check macOS permissions:
        LogicProMCP --check-permissions

      Additional setup for full functionality:
        • MCU Control Surface — see docs/MCU-SETUP.md in the repo
        • MIDI Key Commands — run Scripts/install-keycmds.sh from the repo
        • Scripter MIDI FX — load Scripts/LogicProMCP-Scripter.js in Logic Pro

      After manual validation, approve the manual-validation channels:
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
