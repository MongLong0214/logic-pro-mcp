import AppKit
import Foundation

/// Channel that controls Logic Pro via AppleScript.
/// Very narrow scope: app lifecycle operations only (new, open, close project).
/// AppleScript is slow and modal, so it is used only when no better channel exists.
actor AppleScriptChannel: Channel {
    let id: ChannelID = .appleScript

    struct FrontDocumentIdentity: Equatable, Sendable {
        let path: String?
        let name: String?

        var isUntitled: Bool {
            name != nil && path == nil
        }
    }

    struct Runtime: Sendable {
        let isLogicProRunning: @Sendable () -> Bool
        let openFile: @Sendable (String) -> Bool
        let runScript: @Sendable (String) async -> ChannelResult
        let executeTransportAction: @Sendable (String) async -> ChannelResult
        let fileExists: @Sendable (String) -> Bool
        let fileModificationDate: @Sendable (String) -> Date?
        // #110: front document's on-disk path, for read-back-verified save.
        let currentDocumentPath: @Sendable () async -> String?

        init(
            isLogicProRunning: @escaping @Sendable () -> Bool,
            openFile: @escaping @Sendable (String) -> Bool,
            runScript: @escaping @Sendable (String) async -> ChannelResult,
            executeTransportAction: @escaping @Sendable (String) async -> ChannelResult,
            fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
            fileModificationDate: @escaping @Sendable (String) -> Date? = {
                (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
            },
            currentDocumentPath: @escaping @Sendable () async -> String? = {
                await AppleScriptChannel.currentDocumentPath()
            }
        ) {
            self.isLogicProRunning = isLogicProRunning
            self.openFile = openFile
            self.runScript = runScript
            self.executeTransportAction = executeTransportAction
            self.fileExists = fileExists
            self.fileModificationDate = fileModificationDate
            self.currentDocumentPath = currentDocumentPath
        }

        static let production = Runtime(
            isLogicProRunning: { ProcessUtils.isLogicProRunning },
            openFile: { AppleScriptSafety.openFile(at: $0) },
            runScript: { source in
                await AppleScriptChannel.executeAppleScript(source)
            },
            executeTransportAction: { action in
                switch action {
                case "play":
                    return await AppleScriptChannel.executeAppleScript(
                        AppleScriptChannel.transportScript(action: action)
                    )
                case "stop":
                    return await AppleScriptChannel.executeAppleScript(
                        AppleScriptChannel.transportScript(action: action)
                    )
                case "record":
                    return await AppleScriptChannel.executeAppleScript(
                        AppleScriptChannel.transportScript(action: action)
                    )
                default:
                    return .error("Unsupported transport action: \(action)")
                }
            }
        )
    }

    private let runtime: Runtime

    init(runtime: Runtime = .production) {
        self.runtime = runtime
    }

    func start() async throws {
        Log.info("AppleScript channel started", subsystem: "appleScript")
    }

    func stop() async {
        Log.info("AppleScript channel stopped", subsystem: "appleScript")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        switch operation {
        case "project.new":
            let previousDocumentIdentity = await logicCurrentDocumentIdentity()
            let raw = await runScript(newProjectScript())
            let currentDocumentIdentity = await logicCurrentDocumentIdentity()
            return Self.wrapNewProjectResult(
                raw,
                previousDocumentIdentity: previousDocumentIdentity,
                currentDocumentIdentity: currentDocumentIdentity
            )

        case "project.open":
            guard let path = params["path"] else {
                return .error("Missing 'path' parameter for project.open")
            }
            let raw = await openProjectViaWorkspace(path: path)
            return Self.wrapMutatingResult(raw, operation: operation, extras: ["path": path])

        case "project.close":
            let saving = params["saving"] ?? "yes"
            let raw = await runScript(closeProjectScript(saving: saving))
            return Self.wrapMutatingResult(raw, operation: operation, extras: ["saving": saving])

        case "project.save":
            // #110: verify the front document's `.logicx` package was actually
            // (re)written. The on-disk mtime is authoritative: `save front
            // document` reliably persists even when the AppleEvent reply times
            // out (-1712), so a successful write is confirmed by the file
            // advancing past the save start — independent of the script's
            // success/error verdict. An untitled document (no path) or a
            // package whose mtime did not advance stays an honest State B and
            // never claims a verified save an export/bounce step would trust.
            let documentPath = await runtime.currentDocumentPath()
            // #144 fail-fast: resolving the front document's path FIRST means an
            // UNTITLED document (no on-disk path) never reaches `save front
            // document`, which would raise Logic's modal Save sheet and block the
            // AppleEvent until the sheet is dismissed (observed live as a server
            // hang to the command deadline / harness teardown). Short-circuit to a
            // terminal State C `unsupported_state` so the caller gets an instant,
            // honest failure with a recovery hint instead of a guaranteed hang.
            if let failFast = Self.untitledSaveFailFast(documentPath: documentPath) {
                return failFast
            }
            let beforeMtime = documentPath.flatMap(runtime.fileModificationDate)
            let saveStartedAt = Date()
            let raw = await runScript(saveProjectScript())
            return Self.verifiedSaveResult(
                raw,
                documentPath: documentPath,
                beforeMtime: beforeMtime,
                afterMtime: documentPath.flatMap(runtime.fileModificationDate),
                saveStartedAt: saveStartedAt
            )

        case "project.save_as":
            guard let path = params["path"] else {
                return .error("Missing 'path' parameter for project.save_as")
            }
            guard AppleScriptSafety.isValidProjectPath(path, requireExisting: false) else {
                return .error("save_as requires an absolute .logicx project path")
            }
            let saveStartedAt = Date()
            let candidatePaths = Self.saveAsCandidatePaths(path: path)
            let preexistingPaths = Set(candidatePaths.filter(runtime.fileExists))
            let beforeModificationDates = candidatePaths.reduce(into: [String: Date]()) { dates, candidate in
                if runtime.fileExists(candidate), let date = runtime.fileModificationDate(candidate) {
                    dates[candidate] = date
                }
            }
            let raw = await runScript(saveProjectAsScript(path: path))
            return Self.wrapSaveAsResult(
                raw,
                path: path,
                saveStartedAt: saveStartedAt,
                preexistingPaths: preexistingPaths,
                beforeModificationDates: beforeModificationDates,
                fileExists: runtime.fileExists,
                fileModificationDate: runtime.fileModificationDate
            )

        // Transport fallbacks — AppleScript is only authoritative for commands
        // confirmed to exist in Logic Pro's scripting dictionary.
        case "transport.stop":
            let action = operation.replacingOccurrences(of: "transport.", with: "")
            guard AppleScriptSafety.isAllowedTransportAction(action) else {
                return .error("Transport action not in whitelist: \(action)")
            }
            let raw = await runtime.executeTransportAction(action)
            return Self.wrapMutatingResult(raw, operation: operation)

        case "transport.record":
            let action = operation.replacingOccurrences(of: "transport.", with: "")
            guard AppleScriptSafety.isAllowedTransportAction(action) else {
                return .error("Transport action not in whitelist: \(action)")
            }
            let raw = await runtime.executeTransportAction(action)
            return Self.wrapMutatingResult(raw, operation: operation)

        case "transport.play":
            let action = operation.replacingOccurrences(of: "transport.", with: "")
            guard AppleScriptSafety.isAllowedTransportAction(action) else {
                return .error("Transport action not in whitelist: \(action)")
            }
            let raw = await runtime.executeTransportAction(action)
            return Self.wrapMutatingResult(raw, operation: operation)

        case "transport.pause":
            return .error("Unsupported AppleScript operation: \(operation)")

        default:
            return .error("Unsupported AppleScript operation: \(operation)")
        }
    }

    /// v3.1.1 (P2-2) — wrap a successful AppleScript-driven mutation in a
    /// Honest Contract State B envelope so the wire format matches the AX /
    /// MCU channels. AppleScript mutations cannot read back the resulting
    /// state via the same script path (we'd need a follow-up `tell ... return
    /// ...` round-trip plus a deterministic schema), so all successes here
    /// are `verified:false / readback_unavailable`. Errors stay as
    /// `ChannelResult.error` — the router treats those as terminal.
    static func wrapMutatingResult(
        _ result: ChannelResult,
        operation: String,
        extras: [String: Any] = [:]
    ) -> ChannelResult {
        guard result.isSuccess else { return result }
        // If the script body already produced an HC envelope (open-project's
        // verifyOpenedProject path returns plain "Opened: <path>" but a future
        // refactor could return an HC envelope directly), leave it alone.
        if HonestContractEnvelopeDetector.isAlreadyEnvelope(result.message) {
            return result
        }
        var merged: [String: Any] = [
            "operation": operation,
            "method": "applescript",
            "raw": result.message
        ]
        for (k, v) in extras { merged[k] = v }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable, extras: merged
        ))
    }

    /// #144 (B): derive the `observed_name` extra for `project.new` from the
    /// raw script output (`name of newDocument`). Returns an empty dictionary on
    /// a script error or blank/whitespace name so the envelope is unchanged when
    /// there is no usable name — the State-B verdict itself never changes.
    static func newProjectExtras(_ result: ChannelResult) -> [String: Any] {
        guard result.isSuccess else { return [:] }
        // runScript wraps the AppleScript value as `{"result":"<name>"}`; unwrap
        // it so observed_name is the bare document name ("Untitled"), not the
        // raw JSON envelope. Fall back to the trimmed message if it is not the
        // expected wrapper shape.
        let trimmed = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let unwrapped = obj["result"] as? String {
            name = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = trimmed
        }
        guard !name.isEmpty else { return [:] }
        return ["observed_name": name]
    }

    static func wrapNewProjectResult(
        _ result: ChannelResult,
        previousDocumentIdentity: FrontDocumentIdentity?,
        currentDocumentIdentity: FrontDocumentIdentity?
    ) -> ChannelResult {
        guard result.isSuccess else { return result }

        var extras = newProjectExtras(result)
        if let currentDocumentName = currentDocumentIdentity?.name {
            extras["observed_document_name"] = currentDocumentName
        }
        if let currentDocumentPath = currentDocumentIdentity?.path {
            extras["observed_document_path"] = currentDocumentPath
        }

        guard didFrontDocumentChange(
            previousDocumentIdentity: previousDocumentIdentity,
            currentDocumentIdentity: currentDocumentIdentity
        ) else {
            return .error(HonestContract.encodeStateC(
                error: .readbackMismatch,
                hint: "project.new completed but the front document identity did not change",
                extras: extras.merging([
                    "operation": "project.new",
                    "method": "applescript",
                    "raw": result.message,
                ]) { _, new in new }
            ))
        }

        return wrapMutatingResult(result, operation: "project.new", extras: extras)
    }

    static func didFrontDocumentChange(
        previousDocumentIdentity: FrontDocumentIdentity?,
        currentDocumentIdentity: FrontDocumentIdentity?
    ) -> Bool {
        guard let currentDocumentIdentity else {
            return false
        }
        guard let previousDocumentIdentity else {
            return true
        }
        return currentDocumentIdentity != previousDocumentIdentity
    }

    /// #144: fail-fast guard for `project.save`. Returns a terminal State C
    /// `unsupported_state` envelope when the front document is untitled (no
    /// on-disk path), so the blocking `save front document` script is never
    /// fired against a document that would raise Logic's modal Save sheet and
    /// hang the AppleEvent. Returns `nil` for a titled document (non-empty
    /// path) so the healthy verified-save path proceeds unchanged. Deterministic
    /// and side-effect-free — unit-testable without driving live Logic.
    static func untitledSaveFailFast(documentPath: String?) -> ChannelResult? {
        let hasPath = (documentPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        guard !hasPath else { return nil }
        return .error(HonestContract.encodeStateC(
            error: .unsupportedState,
            hint: "front document is untitled (no on-disk path); use project.save_as with an absolute .logicx path to write and verify it",
            extras: [
                "operation": "project.save",
                "method": "applescript",
            ]
        ))
    }

    /// #110: build the HC verdict for `project.save` from on-disk file
    /// evidence. The `.logicx` package mtime is authoritative — `save front
    /// document` persists even when the AppleEvent reply times out (-1712) —
    /// so a write confirmed by the mtime advancing past `saveStartedAt` (or
    /// beyond a pre-save snapshot) is verified State A regardless of `result`'s
    /// success/error. No path (untitled) or an unchanged mtime → honest State B.
    static func verifiedSaveResult(
        _ result: ChannelResult,
        documentPath: String?,
        beforeMtime: Date?,
        afterMtime: Date?,
        saveStartedAt: Date
    ) -> ChannelResult {
        // A script body that already produced an HC envelope is passed through
        // untouched (matches wrapMutatingResult's no-double-wrap contract).
        if HonestContractEnvelopeDetector.isAlreadyEnvelope(result.message) {
            return result
        }

        var extras: [String: Any] = [
            "operation": "project.save",
            "method": "applescript",
            "verify_source": "file_mtime",
            // Preserve the raw script payload verbatim, matching the prior
            // wrapMutatingResult contract (callers/tests rely on `raw`).
            "raw": result.message,
        ]
        if let documentPath { extras["document_path"] = documentPath }
        if let afterMtime { extras["observed_mtime"] = iso8601String(afterMtime) }
        if let beforeMtime { extras["previous_mtime"] = iso8601String(beforeMtime) }

        // 1) File evidence is authoritative: a package written this save is
        //    verified State A even if the AppleEvent reply timed out (-1712).
        let documentExists = documentPath.map { !$0.isEmpty } ?? false
        let wroteThisSave = documentExists && (afterMtime.map { after in
            after >= saveStartedAt || beforeMtime.map { after > $0 } == true
        } ?? false)
        if wroteThisSave {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        // 2) No write observed + the script itself errored → surface that error
        //    verbatim (terminal); the router treats it as a real failure.
        if !result.isSuccess {
            return result
        }
        // 3) Script succeeded but no on-disk evidence: an untitled document has
        //    no path to check (direct to save_as); a titled one whose mtime
        //    didn't advance is an honest "fired but unconfirmed". Never State A.
        guard documentExists else {
            extras["reason_detail"] = "front document has no on-disk path (untitled); use save_as to verify"
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        extras["reason_detail"] = "save reported success but the .logicx package mtime did not advance"
        return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
    }

    static func wrapSaveAsResult(
        _ result: ChannelResult,
        path: String,
        saveStartedAt: Date,
        preexistingPaths: Set<String>,
        beforeModificationDates: [String: Date],
        fileExists: @Sendable (String) -> Bool,
        fileModificationDate: @Sendable (String) -> Date?
    ) -> ChannelResult {
        guard result.isSuccess else { return result }
        if HonestContractEnvelopeDetector.isAlreadyEnvelope(result.message) {
            return result
        }

        let observedPath = saveAsCandidatePaths(path: path).first(where: fileExists)

        var extras: [String: Any] = [
            "operation": "project.save_as",
            "method": "applescript",
            "path": path,
            "raw": result.message
        ]

        guard let observedPath else {
            return .error(HonestContract.encodeStateC(
                error: .readbackMismatch,
                hint: "project.save_as completed but no .logicx package was observed at the requested path",
                extras: extras
            ))
        }

        let afterModificationDate = fileModificationDate(observedPath)
        if let afterModificationDate {
            extras["observed_mtime"] = iso8601String(afterModificationDate)
        }
        if let beforeModificationDate = beforeModificationDates[observedPath] {
            extras["previous_mtime"] = iso8601String(beforeModificationDate)
        }
        if preexistingPaths.contains(observedPath) {
            guard let beforeModificationDate = beforeModificationDates[observedPath],
                  let afterModificationDate,
                  afterModificationDate > beforeModificationDate ||
                    afterModificationDate >= saveStartedAt else {
                return .error(HonestContract.encodeStateC(
                    error: .readbackMismatch,
                    hint: "project.save_as completed but the existing .logicx package modification time did not advance",
                    extras: extras.merging(["observed": observedPath]) { _, new in new }
                ))
            }
        } else if afterModificationDate == nil {
            return .error(HonestContract.encodeStateC(
                error: .readbackMismatch,
                hint: "project.save_as completed but no modification time could be read from the new .logicx package",
                extras: extras.merging(["observed": observedPath]) { _, new in new }
            ))
        }

        return .success(HonestContract.encodeStateA(
            extras: extras.merging(["observed": observedPath]) { _, new in new }
        ))
    }

    static func saveAsCandidatePaths(path: String) -> [String] {
        path.hasSuffix(".logicx") ? [path] : [path, path + ".logicx"]
    }

    // Hoisted out of `iso8601String` (audit P3 / round-1 #19): a fresh
    // ISO8601DateFormatter per call is wasteful. Reuse one instance guarded by a
    // lock — mirrors Utilities/JSONHelper.swift, whose formatter is not
    // documented thread-safe for concurrent callers. `nonisolated(unsafe)` is
    // required because ISO8601DateFormatter is not Sendable; the lock supplies
    // the actual safety. Default options → identical output to the prior code.
    private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FormatterLock = NSLock()

    private static func iso8601String(_ date: Date) -> String {
        iso8601FormatterLock.lock()
        defer { iso8601FormatterLock.unlock() }
        return iso8601Formatter.string(from: date)
    }

    func healthCheck() async -> ChannelHealth {
        guard runtime.isLogicProRunning() else {
            return .unavailable("Logic Pro not running")
        }
        let probe = await runScript(readinessProbeScript())
        switch probe {
        case .success:
            return .healthy(detail: "AppleScript ready")
        case .error(let message):
            return .unavailable(message)
        }
    }

    // MARK: - Script execution

    private func runScript(_ source: String) async -> ChannelResult {
        await runtime.runScript(source)
    }

    static func executeAppleScript(_ source: String) async -> ChannelResult {
        await Task.detached(priority: .userInitiated) {
            let execution = BoundedProcessRunner.run(
                executable: "/usr/bin/osascript",
                arguments: appleScriptArguments(for: source),
                timeout: ServerConfig.appleScriptTimeout,
                outputLimitBytes: 128 * 1024
            )
            guard case let .completed(output) = execution else {
                Log.error("AppleScript child process failed: \(execution)", subsystem: "appleScript")
                return ChannelResult.error("AppleScript error: \(execution)")
            }

            let stderrOutput = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.exitCode != 0 {
                let message = stderrOutput.isEmpty ? "osascript exited with status \(output.exitCode)" : stderrOutput
                Log.error("AppleScript error: \(message)", subsystem: "appleScript")
                return ChannelResult.error("AppleScript error: \(message)")
            }

            let result = normalizedAppleScriptResult(output.stdout)
            return ChannelResult.success("{\"result\":\"\(AppleScriptChannel.escapeJSON(result))\"}")
        }.value
    }

    // MARK: - Script templates

    private func newProjectScript() -> String {
        """
        tell application "Logic Pro"
            activate
        end tell
        tell application "System Events"
            tell process "Logic Pro"
                click menu item 1 of menu 1 of menu bar item 3 of menu bar 1
                repeat 20 times
                    delay 0.2
                    if (count of windows) > 0 then
                        return name of window 1
                    end if
                end repeat
            end tell
        end tell
        return ""
        """
    }

    private func openProjectViaWorkspace(path: String) async -> ChannelResult {
        // Use Launch Services via open(1) instead of AppleScript string interpolation
        // to completely prevent injection attacks (PRD §6.3)
        guard runtime.openFile(path) else {
            return .error("Failed to open: \(path)")
        }

        let initialVerification = await runScript(verifyOpenedProjectScript(path: path))
        switch initialVerification {
        case .success:
            return .success("Opened: \(path)")
        case .error(let initialMessage):
            guard runtime.isLogicProRunning() else {
                return .error("Failed to verify opened project: \(path). \(initialMessage)")
            }

            let documentAfterInitialVerification = await logicCurrentDocumentIdentity()
            if let currentDocumentPath = documentAfterInitialVerification?.path,
               projectPathsMatch(currentDocumentPath, path) {
                return .success("Opened: \(path)")
            }

            if documentAfterInitialVerification?.isUntitled == true {
                return .error(HonestContract.encodeStateC(
                    error: .unsupportedState,
                    hint: "project.open could not verify the requested project and the current front document is untitled; refusing to close an unsaved document to retry",
                    extras: [
                        "operation": "project.open",
                        "method": "applescript",
                        "path": path,
                    ]
                ))
            }

            _ = await runScript(closeCurrentProjectIfAnyScript(saving: "no"))

            guard runtime.openFile(path) else {
                if let previousDocumentPath = documentAfterInitialVerification?.path,
                   !projectPathsMatch(previousDocumentPath, path) {
                    _ = runtime.openFile(previousDocumentPath)
                }
                return .error("Failed to open after closing current project: \(path)")
            }

            let retryVerification = await runScript(verifyOpenedProjectScript(path: path))
            switch retryVerification {
            case .success:
                return .success("Opened: \(path)")
            case .error(let retryMessage):
                if let currentDocumentPath = await logicCurrentDocumentPath(),
                   projectPathsMatch(currentDocumentPath, path) {
                    return .success("Opened: \(path)")
                }
                if let previousDocumentPath = documentAfterInitialVerification?.path,
                   !projectPathsMatch(previousDocumentPath, path) {
                    _ = runtime.openFile(previousDocumentPath)
                }
                return .error("Failed to verify opened project: \(path). \(retryMessage)")
            }
        }
    }

    private func closeProjectScript(saving: String) -> String {
        let saveClause = closeProjectSaveClause(saving: saving)
        return """
        tell application "Logic Pro"
            close front document \(saveClause)
        end tell
        """
    }

    private func closeCurrentProjectIfAnyScript(saving: String) -> String {
        let saveClause = closeProjectSaveClause(saving: saving)
        return """
        tell application "Logic Pro"
            if (count of documents) > 0 then
                close front document \(saveClause)
            end if
        end tell
        """
    }

    static func currentDocumentPathScript() -> String {
        """
        tell application "Logic Pro"
            if (count of documents) > 0 then
                try
                    return path of front document as text
                on error
                    return ""
                end try
            end if
            return ""
        end tell
        """
    }

    static func currentDocumentIdentityScript() -> String {
        """
        tell application "Logic Pro"
            if (count of documents) > 0 then
                set docPath to ""
                set docName to ""
                try
                    set docPath to path of front document as text
                end try
                try
                    set docName to name of front document as text
                end try
                return docPath & character id 31 & docName
            end if
            return ""
        end tell
        """
    }

    /// v3.1.8 (Issue #7) — file-scoped helper for `LogicProjectFileReader` so it
    /// can resolve the open project's path without instantiating a channel.
    /// Returns nil when no document is open, TCC is denied, or AppleScript
    /// fails for any reason.
    @Sendable
    static func currentDocumentPath() async -> String? {
        let result = await Self.executeAppleScript(currentDocumentPathScript())
        return Self.parseCurrentDocumentPath(from: result)
    }

    static func parseCurrentDocumentPath(from result: ChannelResult) -> String? {
        guard result.isSuccess else { return nil }
        let raw = Self.appleScriptResultText(from: result)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard raw.hasPrefix("/") else { return nil }
        return raw
    }

    static func parseCurrentDocumentIdentity(from result: ChannelResult) -> FrontDocumentIdentity? {
        guard result.isSuccess else { return nil }
        let raw = Self.appleScriptResultText(from: result)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }

        let parts = raw.split(
            separator: "\u{001F}",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return nil }

        let rawPath = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = rawPath.hasPrefix("/") ? rawPath : nil
        let name = rawName.isEmpty ? nil : rawName

        guard path != nil || name != nil else { return nil }
        return FrontDocumentIdentity(path: path, name: name)
    }

    /// Static, side-effect-free POSIX-path comparison used by the verified
    /// project-identity gate (R10, AC15). Mirrors the instance
    /// `projectPathsMatch`/`normalizedProjectPath` logic exactly (symlink
    /// resolution + `/private` prefix + trailing-slash normalization) so the
    /// gate reuses the same comparison the open/save lifecycle already relies on.
    static func projectPathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedProjectPathStatic(lhs)
        let right = normalizedProjectPathStatic(rhs)
        if left == right { return true }
        if left.hasPrefix("/private"), String(left.dropFirst(8)) == right { return true }
        if right.hasPrefix("/private"), left == String(right.dropFirst(8)) { return true }
        return false
    }

    static func normalizedProjectPathStatic(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if normalized.hasSuffix("/") {
            return String(normalized.dropLast())
        }
        return normalized
    }

    private func logicCurrentDocumentPath() async -> String? {
        let result = await runScript(Self.currentDocumentPathScript())
        return Self.parseCurrentDocumentPath(from: result)
    }

    private func logicCurrentDocumentIdentity() async -> FrontDocumentIdentity? {
        let result = await runScript(Self.currentDocumentIdentityScript())
        return Self.parseCurrentDocumentIdentity(from: result)
    }

    /// Instance shim over the static comparison so the open/save lifecycle and
    /// the verified project-identity gate (R10, AC15) share one implementation.
    /// Byte-identical to the former instance body (which duplicated the static).
    private func projectPathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        Self.projectPathsMatch(lhs, rhs)
    }

    static func appleScriptResultText(from result: ChannelResult) -> String? {
        guard result.isSuccess else { return nil }
        let message = result.message
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let value = object["result"]
        else {
            return message
        }
        return value
    }

    private func closeProjectSaveClause(saving: String) -> String {
        switch saving.lowercased() {
        case "no", "false":
            return "saving no"
        case "ask":
            return "saving ask"
        default:
            return "saving yes"
        }
    }

    private func saveProjectScript() -> String {
        """
        tell application "Logic Pro"
            save front document
        end tell
        """
    }

    private func readinessProbeScript() -> String {
        """
        tell application "Logic Pro"
            return name
        end tell
        """
    }

    private func verifyOpenedProjectScript(path: String) -> String {
        // Normalize path to resolve /private/Users vs /Users symlink differences
        let normalizedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let escapedPath = normalizedPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return """
        tell application "Logic Pro"
            repeat 25 times
                if (count of documents) > 0 then
                    try
                        set docPath to path of front document as text
                        -- Normalize: strip trailing slash for comparison
                        if docPath ends with "/" then set docPath to text 1 thru -2 of docPath
                        set expectedPath to "\(escapedPath)"
                        if expectedPath ends with "/" then set expectedPath to text 1 thru -2 of expectedPath
                        if docPath is expectedPath then return "opened"
                        -- Also check without /private prefix
                        if docPath starts with "/private" and (text 9 thru -1 of docPath) is expectedPath then return "opened"
                        if expectedPath starts with "/private" and docPath is (text 9 thru -1 of expectedPath) then return "opened"
                    end try
                end if
                delay 0.2
            end repeat
            error "Timed out waiting for Logic Pro to open the requested project"
        end tell
        """
    }

    private func saveProjectAsScript(path: String) -> String {
        let escapedPath = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return """
        tell application "Logic Pro"
            save front document in (POSIX file "\(escapedPath)")
        end tell
        """
    }

    private static func transportScript(action: String) -> String {
        "tell application id \"\(ServerConfig.logicProBundleID)\" to \(action)"
    }

    // MARK: - Helpers

    static func escapeJSON(_ string: String) -> String {
        // RFC 8259 forbids unescaped U+0000..U+001F bytes inside a JSON
        // string. Pre-v3.1.5 we only handled the common whitespace trio,
        // so AppleScript outputs that legitimately contain other control
        // bytes (e.g. the U+001F / U+001E delimiters used by the new
        // markers / projectInfo / tracks helpers) round-tripped as raw
        // bytes and broke `JSONSerialization` parsing. Escape every
        // control character as a `\u00XX` sequence so the wrapper is
        // always valid JSON.
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": result.append("\\\\")
            case "\"": result.append("\\\"")
            case "\n": result.append("\\n")
            case "\r": result.append("\\r")
            case "\t": result.append("\\t")
            case "\u{08}": result.append("\\b")
            case "\u{0C}": result.append("\\f")
            default:
                if scalar.value < 0x20 {
                    result.append(String(format: "\\u%04X", scalar.value))
                } else {
                    result.append(Character(scalar))
                }
            }
        }
        return result
    }

    /// Sanitizes raw `osascript` stdout for downstream JSON wrapping. C0 control
    /// bytes are stripped because RFC 8259 forbids them unescaped — EXCEPT
    /// `\n`/`\r`/`\t` (legitimate whitespace) and U+001E/U+001F, the record /
    /// field separators the front-document identity readback (and the marker /
    /// projectInfo / tracks helpers) use as structured delimiters. Those two are
    /// preserved here and escaped as ``/`` later by `escapeJSON`.
    ///
    /// Stripping U+001F here was a real defect: `currentDocumentIdentityScript`
    /// emits `docPath & character id 31 & docName`, so deleting the delimiter
    /// before `parseCurrentDocumentIdentity` collapsed the readback to a single
    /// field, forced `logicCurrentDocumentIdentity()` to return `nil`, and made
    /// `project.new` / `project.open` verification degrade to State C / CGEvent
    /// fallback on every real invocation. `internal` so the delimiter-survival
    /// regression test drives this exact sanitizer instead of stubbing `runScript`.
    static func normalizedAppleScriptResult(_ raw: String) -> String {
        let sanitized = String(
            raw.unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "\n" || scalar == "\r" || scalar == "\t"
                    || scalar == "\u{1E}" || scalar == "\u{1F}"
            }
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "OK" : sanitized
    }

    private static func appleScriptArguments(for source: String) -> [String] {
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.flatMap { ["-e", $0] }
    }

}
