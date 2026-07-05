import Darwin
import Foundation

extension ProjectExportExecutor {
    static func bounceHelperResult(from output: BoundedProcessRunner.Output) -> BounceHelperResult {
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDetail = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "exit_code=\(output.exitCode)")
        let fallbackBounceFired = stdout.contains("\"bounce_fired\":true")

        guard let data = output.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(fallbackDetail, bounceFired: fallbackBounceFired)
        }

        // An explicit `bounce_fired` from the helper is authoritative; only fall
        // back to heuristics when the field is ABSENT. Parentheses are required:
        // `??` binds tighter than `||`, so the un-parenthesized form let an
        // explicit `bounce_fired:false` be overridden to true by a non-empty
        // artifact / success flag.
        let bounceFired = (obj["bounce_fired"] as? Bool)
            ?? (((obj["success"] as? Bool) == true)
                || ((obj["artifact"] as? String)?.isEmpty == false)
                || fallbackBounceFired)
        if output.exitCode == 0,
           let ok = obj["success"] as? Bool, ok,
           let artifact = obj["artifact"] as? String,
           !artifact.isEmpty {
            return .success(artifact, bounceFired: true)
        }
        if let helperError = obj["error"] as? String, !helperError.isEmpty {
            return .failure(helperError, bounceFired: bounceFired)
        }
        if let helperReason = obj["reason"] as? String, !helperReason.isEmpty {
            return .failure(helperReason, bounceFired: bounceFired)
        }
        if let payload = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let payloadString = String(data: payload, encoding: .utf8),
           !payloadString.isEmpty {
            if output.exitCode == 0 {
                return .failure(payloadString, bounceFired: bounceFired)
            }
            return .failure("bounce_helper_exit_code_\(output.exitCode): \(payloadString)", bounceFired: bounceFired)
        }
        return .failure(fallbackDetail, bounceFired: bounceFired)
    }

    static func runBounceHelper(
        artifactPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        executablePath: String? = nil,
        timeout: TimeInterval = bounceHelperTimeout,
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        runProcess: BounceHelperProcessRunner = { executable, arguments, timeout in
            BoundedProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) async -> BounceHelperResult {
        guard let helper = resolveBounceHelperPath(
            environment: environment,
            currentDirectoryPath: currentDirectoryPath,
            executablePath: executablePath,
            fileExists: fileExists
        ) else {
            return .failure("bounce_helper_missing: no candidate path")
        }
        guard fileExists(helper) else {
            return .failure("bounce_helper_missing: \(helper)")
        }
        let result = runProcess(
            resolvePython3Path(environment: environment),
            [helper, "--target-path", artifactPath],
            timeout
        )
        switch result {
        case .timedOut:
            return .failure("bounce_helper_timed_out")
        case let .spawnFailed(message):
            return .failure("bounce_helper_spawn_failed: \(message)")
        case let .completed(output):
            return bounceHelperResult(from: output)
        }
    }
}
