import Foundation

/// Channel that controls Logic Pro via AppleScript.
/// Very narrow scope: app lifecycle operations only (new, open, close project).
/// AppleScript is slow and modal, so it is used only when no better channel exists.
actor AppleScriptChannel: Channel {
    let id: ChannelID = .appleScript

    func start() async throws {
        Log.info("AppleScript channel started", subsystem: "appleScript")
    }

    func stop() async {
        Log.info("AppleScript channel stopped", subsystem: "appleScript")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        switch operation {
        case "project.new":
            return await runScript(newProjectScript())

        case "project.open":
            guard let path = params["path"] else {
                return .error("Missing 'path' parameter for project.open")
            }
            return openProjectViaWorkspace(path: path)

        case "project.close":
            let saving = params["saving"] ?? "yes"
            return await runScript(closeProjectScript(saving: saving))

        case "project.save":
            return await runScript(saveProjectScript())

        // Transport fallbacks — whitelist enforced (PRD §6.3)
        case "transport.play", "transport.stop", "transport.record", "transport.pause":
            let action = operation.replacingOccurrences(of: "transport.", with: "")
            guard AppleScriptSafety.isAllowedTransportAction(action) else {
                return .error("Transport action not in whitelist: \(action)")
            }
            return await runScript(transportScript(action: action))

        default:
            return .error("Unsupported AppleScript operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        return .healthy(detail: "AppleScript ready")
    }

    // MARK: - Script execution

    private func runScript(_ source: String) async -> ChannelResult {
        // Run NSAppleScript on a detached task to avoid blocking the actor's
        // cooperative thread pool. executeAndReturnError can take seconds.
        return await Task.detached(priority: .userInitiated) {
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: source)
            let result = script?.executeAndReturnError(&errorDict)

            if let error = errorDict {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                let number = error[NSAppleScript.errorNumber] as? Int ?? -1
                Log.error("AppleScript error \(number): \(message)", subsystem: "appleScript")
                return ChannelResult.error("AppleScript error: \(message)")
            }

            let output = result?.stringValue ?? "OK"
            return ChannelResult.success("{\"result\":\"\(AppleScriptChannel.escapeJSON(output))\"}")
        }.value
    }

    // MARK: - Script templates

    private func newProjectScript() -> String {
        """
        tell application "Logic Pro"
            activate
            delay 0.5
        end tell
        tell application "System Events"
            tell process "Logic Pro"
                click menu item "New..." of menu "File" of menu bar 1
            end tell
        end tell
        """
    }

    private func openProjectViaWorkspace(path: String) -> ChannelResult {
        // Use NSWorkspace.open instead of AppleScript string interpolation
        // to completely prevent injection attacks (PRD §6.3)
        if AppleScriptSafety.openFile(at: path) {
            return .success("Opened: \(path)")
        } else {
            return .error("Failed to open: \(path)")
        }
    }

    private func closeProjectScript(saving: String) -> String {
        let saveClause: String
        switch saving.lowercased() {
        case "no", "false":
            saveClause = "saving no"
        case "ask":
            saveClause = "saving ask"
        default:
            saveClause = "saving yes"
        }
        return """
        tell application "Logic Pro"
            close front document \(saveClause)
        end tell
        """
    }

    private func saveProjectScript() -> String {
        """
        tell application "Logic Pro"
            save front document
        end tell
        """
    }

    private func transportScript(action: String) -> String {
        """
        tell application "Logic Pro"
            \(action)
        end tell
        """
    }

    // MARK: - Helpers

    private static func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
