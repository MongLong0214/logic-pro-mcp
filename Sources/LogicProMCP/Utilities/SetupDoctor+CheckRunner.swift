import Foundation

extension SetupDoctor {
    struct DoctorCheckRunContext {
        let executablePath: String?
        let installSource: InstallSource
        let claudeRegistration: ClaudeRegistration
        let doctorProfile: DoctorProfile
        let clientProfile: ClientProfile
        let permissionStatus: PermissionChecker.PermissionStatus
        let approvals: [ManualValidationChannel: ManualValidationApproval]
        let runtime: Runtime
        let manualStoreHealth: ManualValidationStoreHealth
        let logicApps: [LogicAppInfo]
        let staticVersionForPath: (String) -> StaticVersionResult
    }

    static func runRegisteredChecks(context: DoctorCheckRunContext) -> [Check] {
        var checks: [Check] = []
        for definition in checkDefinitions where shouldInclude(definition, context: context) {
            let start = context.runtime.monotonicNowMs()
            guard var check = executeRegisteredCheck(definition.id, context: context, checks: checks) else {
                continue
            }
            // Preserve whole-millisecond, sequential timing while registry order drives execution.
            check.durationMs = (max(0, context.runtime.monotonicNowMs() - start)).rounded()
            checks.append(check)
        }
        return checks
    }

    private static func shouldInclude(
        _ definition: DoctorCheckDefinition,
        context: DoctorCheckRunContext
    ) -> Bool {
        switch definition.inclusionRule {
        case .always:
            return true
        case .latestReleaseLookupAvailable:
            return context.runtime.latestReleaseLookup != nil
        }
    }

    private static func executeRegisteredCheck(
        _ id: DoctorCheckID,
        context: DoctorCheckRunContext,
        checks: [Check]
    ) -> Check? {
        switch id {
        case .binaryPath:
            return binaryPathCheck(executablePath: context.executablePath, runtime: context.runtime)
        case .binaryExecutable:
            return binaryExecutableCheck(executablePath: context.executablePath, runtime: context.runtime)
        case .binaryVersion:
            return binaryVersionCheck()
        case .installSource:
            return installSourceCheck(
                installSource: context.installSource,
                executablePath: context.executablePath
            )
        case .installBinaryInventory:
            return installBinaryInventoryCheck(
                executablePath: context.executablePath,
                installSource: context.installSource,
                runtime: context.runtime,
                claudeRegistration: context.claudeRegistration,
                staticVersionForPath: context.staticVersionForPath
            )
        case .installShareDir:
            return installShareDirCheck(runtime: context.runtime, installSource: context.installSource)
        case .releaseSignature:
            return releaseSignatureCheck(executablePath: context.executablePath, runtime: context.runtime)
        case .releaseQuarantine:
            return releaseQuarantineCheck(executablePath: context.executablePath, runtime: context.runtime)
        case .mcpClaudeCodeRegistration:
            return claudeRegistrationCheck(
                registration: context.claudeRegistration,
                clientProfile: context.clientProfile
            )
        case .mcpRegistrationTarget:
            return mcpRegistrationTargetCheck(
                registration: context.claudeRegistration,
                runtime: context.runtime,
                checks: checks,
                staticVersionForPath: context.staticVersionForPath,
                clientProfile: context.clientProfile
            )
        case .mcpClaudeDesktopRegistration:
            return claudeDesktopRegistrationCheck(runtime: context.runtime, clientProfile: context.clientProfile)
        case .permissionsAccessibility:
            return accessibilityPermissionCheck(context.permissionStatus)
        case .permissionsAutomationLogicPro:
            return automationPermissionCheck(context.permissionStatus)
        case .permissionsAutomationSystemEvents:
            return systemEventsAutomationCheck(context.permissionStatus)
        case .permissionsPostEventAccess:
            return postEventAccessCheck(context.permissionStatus)
        case .permissionsLaunchContext:
            return launchContextCheck(runtime: context.runtime)
        case .permissionsTCCCrossContext:
            return tccCrossContextCheck(runtime: context.runtime)
        case .systemMacOSVersion:
            return macOSVersionCheck(runtime: context.runtime)
        case .logicInstallation:
            return logicInstallationCheck(logicApps: context.logicApps)
        case .logicVersionSupport:
            return logicVersionSupportCheck(logicApps: context.logicApps, checks: checks)
        case .logicApplicationState:
            return logicApplicationStateCheck(runtime: context.runtime)
        case .logicBlockingDialog:
            return logicBlockingDialogCheck(runtime: context.runtime, checks: checks)
        case .channelsManualValidation:
            return manualValidationCheck(
                approvals: context.approvals,
                profile: context.doctorProfile,
                storeHealth: context.manualStoreHealth
            )
        case .channelsKeycmdReference:
            return keycmdReferenceCheck(runtime: context.runtime, profile: context.doctorProfile)
        case .channelsMCUWiringHint:
            return mcuWiringHintCheck(runtime: context.runtime, profile: context.doctorProfile)
        case .dependenciesClickFallback:
            return clickFallbackCheck(
                runtime: context.runtime,
                permissionStatus: context.permissionStatus
            )
        case .updatesLatestRelease:
            return context.runtime.latestReleaseLookup.map {
                updateCheck(outcome: $0(), installSource: context.installSource)
            }
        }
    }
}
