import Darwin
import Dispatch
import Foundation

protocol ServerStarting: Sendable {
    func start() async throws
    func stop() async
}

extension ServerStarting {
    /// Default no-op so existing test mocks that only implement `start()` keep
    /// working. Production `LogicProServer` overrides with the real teardown.
    func stop() async {}
}

extension LogicProServer: ServerStarting {}

enum MainEntrypoint {
    static func run(
        arguments: [String],
        permissionCheck: () -> PermissionChecker.PermissionStatus = PermissionChecker.check,
        serverFactory: () -> any ServerStarting = { LogicProServer() },
        approvalStoreFactory: () -> any ManualValidationStoring = { ManualValidationStore() },
        doctorRuntime: SetupDoctor.Runtime = .production,
        lifecycleRuntime: SetupLifecycle.Runtime = .production,
        qualificationCommand: ([String]) async -> QualificationCommandResult = { arguments in
            await QualificationRunner().run(arguments: arguments)
        },
        // Injected so doctor's color/TTY gating is pinnable in tests (AC-5.4).
        isStdoutTTY: () -> Bool = { isatty(STDOUT_FILENO) != 0 },
        doctorEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        writeStdout: (String) -> Void = { message in
            FileHandle.standardOutput.write(Data(message.utf8))
        },
        writeStderr: (String) -> Void = { message in
            FileHandle.standardError.write(Data(message.utf8))
        }
    ) async -> Int {
        // `--version` and `--help` are terminal global flags: print and exit
        // WITHOUT creating the approval store, checking permissions, or —
        // critically — starting the long-lived MCP server channels (#212/#213).
        // Placed before every other branch so no side effect runs first.
        //
        // `--version` emits the bare version string only: SetupLifecycle
        // .productionInstalledBinaryVersion() runs the installed binary with
        // `--version`, requires exit 0, and compares the trimmed stdout for
        // EQUALITY against ServerConfig.serverVersion to detect install drift.
        // Any prefix (e.g. "logic-pro-mcp 3.7.4") would break that equality.
        if hasFlag("--version", or: "-V", in: arguments) {
            writeStdout(ServerConfig.serverVersion + "\n")
            return 0
        }
        if hasFlag("--help", or: "-h", in: arguments) {
            writeStdout(usageText + "\n")
            return 0
        }

        if let command = arguments.dropFirst().first,
           command == "--qualify" || command == "--verify-promotion" {
            let result = await qualificationCommand(arguments)
            if !result.stdout.isEmpty { writeStdout(result.stdout) }
            if !result.stderr.isEmpty { writeStderr(result.stderr) }
            return result.exitCode
        }

        let approvalStore = approvalStoreFactory()

        if isDoctorCommand(arguments) {
            // Arm the opt-in update lookup ONLY when --check-updates is present, so
            // the default run never touches the network (G7/NG4). A test-injected
            // lookup (already non-nil) is left untouched.
            var runtime = doctorRuntime
            if arguments.contains("--check-updates"), runtime.latestReleaseLookup == nil {
                runtime.latestReleaseLookup = { SetupDoctor.productionLatestReleaseLookup() }
            }
            let report = SetupDoctor.generate(
                arguments: arguments,
                permissionStatus: permissionCheck(),
                approvals: await approvalStore.list(),
                runtime: runtime,
                manualStoreHealth: await approvalStore.health()
            )
            if arguments.contains("--json") {
                // --json is the machine contract: identical bytes regardless of
                // verbosity/color flags (AC-5.5).
                writeStdout(encodeJSON(report) + "\n")
            } else {
                let mode: SetupDoctor.OutputMode = arguments.contains("--verbose")
                    ? .verbose
                    : (arguments.contains("--quiet") ? .quiet : .default)
                let useColor = isStdoutTTY() && doctorEnvironment["NO_COLOR"] == nil
                writeStdout(SetupDoctor.renderHuman(report, mode: mode, useColor: useColor) + "\n")
            }
            return arguments.contains("--strict")
                ? SetupDoctor.strictExitCode(report)
                : (SetupDoctor.shouldExitWithFailure(report) ? 1 : 0)
        }

        if isLifecycleSubcommand(arguments) {
            // #214: `LogicProMCP lifecycle <install|update|uninstall> [--json]`
            // is the documented read-only planning surface. Pre-fix the
            // `lifecycle` verb was unparsed and fell through to server startup
            // (the audit saw a hang/timeout). It prints the SAME plan the bare
            // `<action> --dry-run` form produces — no `--dry-run` needed because
            // the `lifecycle` namespace never executes anything; live execution
            // stays delegated to Scripts/install.sh / uninstall.sh.
            guard let command = lifecycleSubcommandAction(arguments) else {
                let valid = SetupLifecycle.Command.allCases.map(\.rawValue).joined(separator: "|")
                writeStderr(
                    "Usage: LogicProMCP lifecycle <\(valid)> [--json]\n"
                        + "Prints a read-only lifecycle plan (see docs/SETUP.md).\n"
                )
                return 1
            }
            let plan = SetupLifecycle.plan(command: command, runtime: lifecycleRuntime)
            let output = arguments.contains("--json")
                ? encodeJSON(plan)
                : SetupLifecycle.renderHuman(plan)
            writeStdout(output + "\n")
            return 0
        }

        if let command = lifecycleCommand(arguments) {
            // Live execution is intentionally NOT performed here — it is delegated
            // to Scripts/install.sh / uninstall.sh. Without --dry-run we refuse
            // honestly and exit non-zero rather than faking execution.
            guard arguments.contains("--dry-run") else {
                let script = command == .uninstall
                    ? "Scripts/uninstall.sh"
                    : "Scripts/install.sh"
                writeStderr(
                    "Live \(command.rawValue) is not performed by this binary. "
                        + "Re-run with --dry-run to preview the plan, or run \(script) "
                        + "to execute (see docs/SETUP.md).\n"
                )
                return 1
            }
            let plan = SetupLifecycle.plan(command: command, runtime: lifecycleRuntime)
            let output = arguments.contains("--json")
                ? encodeJSON(plan)
                : SetupLifecycle.renderHuman(plan)
            writeStdout(output + "\n")
            return 0
        }

        if arguments.contains("--list-approvals") {
            let approvals = await approvalStore.list()
            writeStderr(ManualValidationStore.summary(for: approvals) + "\n")
            return 0
        }

        if let rawChannel = optionValue("--approve-channel", in: arguments) {
            guard let channel = ManualValidationChannel.parse(rawChannel) else {
                writeStderr("Unknown approval channel: \(rawChannel)\n")
                return 1
            }
            do {
                try await approvalStore.approve(channel, note: optionValue("--approval-note", in: arguments))
                writeStderr("Approved \(channel.rawValue) for runtime use.\n")
                return 0
            } catch {
                writeStderr("Failed to persist approval for \(channel.rawValue): \(error)\n")
                return 1
            }
        }

        if let rawChannel = optionValue("--skip-channel", in: arguments) {
            guard let channel = ManualValidationChannel.parse(rawChannel) else {
                writeStderr("Unknown manual-validation channel: \(rawChannel)\n")
                return 1
            }
            do {
                try await approvalStore.skip(channel, note: optionValue("--skip-note", in: arguments))
                writeStderr("Intentionally skipped \(channel.rawValue) for doctor readiness.\n")
                return 0
            } catch {
                writeStderr("Failed to persist skip decision for \(channel.rawValue): \(error)\n")
                return 1
            }
        }

        if let rawChannel = optionValue("--revoke-channel", in: arguments) {
            guard let channel = ManualValidationChannel.parse(rawChannel) else {
                writeStderr("Unknown approval channel: \(rawChannel)\n")
                return 1
            }
            do {
                try await approvalStore.revoke(channel)
                writeStderr("Revoked approval for \(channel.rawValue).\n")
                return 0
            } catch {
                writeStderr("Failed to revoke approval for \(channel.rawValue): \(error)\n")
                return 1
            }
        }

        // #616: a release-constructible probe of the Event List note table.
        //
        // The ship gate binds live evidence to sha256 of THIS binary. `EventListReadbackCollector`
        // lives in it, but `collect` needs a `RegistryResolvedIdentityProof` whose only mint is
        // compiled under a debug condition — so the shipped artifact contained the code under test
        // and could not enter it, and every live check written about that code scored zero mutations.
        //
        // This flag is observation only. It mints no identity, calls no `assessReadback`, completes
        // no qualification, and adds no MCP surface: the dark provider stays dark and
        // `publicProvider()` stays nil. What it does is run the same `readHeaders`/`readRows`/`readRow`
        // path the collector runs, against live Logic, from the artifact the gate hashes — so a
        // harness can watch that path change when the product changes, which is what the gate has
        // always asked for and what no route I tried before could give it.
        if arguments.contains("--probe-event-list") {
            do {
                let seen = try EventListReadbackCollector.observeNoteTable()
                func cells(_ row: RawEventRow) -> [String: Any] {
                    row.reduce(into: [String: Any]()) { out, pair in
                        out[pair.key.id] = [
                            "sliderValue": pair.value.sliderValue as Any,
                            "valueDescription": pair.value.valueDescription as Any,
                        ]
                    }
                }
                let payload: [String: Any] = [
                    "ok": true,
                    "rows": seen.rows.count,
                    // What LOGIC rendered. `columns` used to be the row keys, which are minted from
                    // the canonical constants on every success — a harness comparing those to the
                    // same constants was comparing English to English and could not fail.
                    "live_columns": seen.liveHeaderTitles,
                    "first_row_cell_children": seen.firstRowCellChildren,
                    "all_rows": seen.rows.map(cells),
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                writeStdout(String(data: data, encoding: .utf8)! + "\n")
                return 0
            } catch {
                // The failure is the interesting half: `cellChildCountMismatch(row:column:actual:)` is
                // what the guard under test throws, and a harness has to be able to read it.
                let data = try? JSONSerialization.data(
                    withJSONObject: ["ok": false, "error": "\(error)"], options: [.sortedKeys]
                )
                let text = String(data: data ?? Data(), encoding: .utf8) ?? "{\"ok\":false}"
                writeStdout(text + "\n")
                return 1
            }
        }

        // #628: the counting locator, run against live Logic from the artifact the gate hashes.
        //
        // `AXHelpers.censusDescendant` answers "how many matched", which is the fact the blind
        // `findDescendant` cannot report. A unit test can prove the counting rule against a tree it
        // built itself; only this can show the rule surviving contact with Logic's real one, and
        // the count it returns is checkable against an instrument that is not this code.
        //
        // Observation only, exactly like `--probe-event-list`: it reads, adds no MCP surface, and
        // performs no action. `role` is the one criterion an outside instrument can reproduce
        // without sharing this code's notion of a label, which is what makes the comparison worth
        // making — matching on a LabelSet would have the harness and the product agreeing because
        // they read the same table.
        if arguments.contains("--probe-locator-census") {
            let role = arguments.drop(while: { $0 != "--probe-locator-census" })
                .dropFirst().first ?? "AXButton"
            let depth = Int(arguments.drop(while: { $0 != "--probe-locator-depth" })
                .dropFirst().first ?? "") ?? 10
            guard let window = AXLogicProElements.mainWindow() else {
                writeStdout("{\"ok\":false,\"error\":\"no main window\"}\n")
                return 1
            }
            // `--probe-locator-from <AXDescription>` searches from a named container instead of the
            // window. Without it the probe can only answer "how many X in the whole window", and no
            // call site searches the whole window — they search from a rail, a strip, a header. A
            // count taken from the wrong root is a number about a different question, and the tail
            // of this issue is exactly the work of deciding call site by call site whether the set
            // has one member.
            //
            // The container itself is resolved by the SAME counting rule, so an ambiguous container
            // refuses rather than picking one and reporting a confident count taken from whichever
            // it happened to reach.
            var root = window
            var rootDescription: String? = nil
            var rootCandidates: Int? = nil
            if let from = arguments.drop(while: { $0 != "--probe-locator-from" }).dropFirst().first {
                let container = AXLocalePolicy.censusDescendant(
                    of: window,
                    role: "AXGroup",
                    matching: AXLocalePolicy.LabelSet(
                        canonical: from, variants: [],
                        rationale: "probe argument, matched verbatim"),
                    mode: .exactStrict,
                    maxDepth: depth,
                    runtime: .production
                )
                rootCandidates = container.candidates
                guard let found = container.element else {
                    let why = container.candidates == 0
                        ? "no container with that description"
                        : "the container description is ambiguous"
                    // #628: the count refuses, the NAMES make the refusal actionable. "2 matched"
                    // cannot distinguish a genuinely ambiguous tree from a selector one word too
                    // broad; the two descriptions can.
                    let named = container.names(runtime: .production)
                    let namesJSON = (try? JSONSerialization.data(withJSONObject: named))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    writeStdout("{\"ok\":false,\"error\":\"\(why)\",\"from\":\"\(from)\","
                        + "\"containerCandidates\":\(container.candidates),"
                        + "\"containerCandidateNames\":\(namesJSON)}\n")
                    return 1
                }
                root = found
                rootDescription = from
            }
            let census = AXHelpers.censusDescendant(of: root, role: role, maxDepth: depth)
            let payload: [String: Any] = [
                "ok": true,
                "role": role,
                "maxDepth": depth,
                "from": rootDescription as Any,
                "containerCandidates": rootCandidates as Any,
                "candidates": census.candidates,
                // Named only when the answer is ambiguous: at one match the name adds nothing the
                // caller did not already ask for, and each name costs an AX round trip.
                "candidateNames": census.candidates > 1 ? census.names(runtime: .production) : [],
                // `identified` is the whole point of the count: it is true only at exactly one, and
                // a reader can tell that from "something was returned" — which the blind lookup
                // reports identically at one match and at nine.
                "identified": census.isUnambiguous,
                "returnedElement": census.element != nil,
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard let data, let text = String(data: data, encoding: .utf8) else {
                writeStdout("{\"ok\":false,\"error\":\"could not encode the census\"}\n")
                return 1
            }
            writeStdout(text + "\n")
            return 0
        }

        // #628: the survivor count of a real call site's own predicate.
        //
        // `--probe-locator-census` answers "how many carry this role". It cannot answer the question
        // the tail actually asks, which is how many survive the DISCRIMINATOR a site applies —
        // `isTrackHeadersGroup`, `looksLikeTransportContainer`. Those are the sites this issue is
        // about: they gather many and select one with a predicate, and nothing records whether the
        // predicate left one or several.
        //
        // The predicates are called HERE rather than reimplemented. A measurement that rewrites the
        // rule can disagree with the code for a reason that has nothing to do with the tree, which
        // is the failure this whole issue is a census of.
        //
        // Observation only: it gathers, filters, counts, and returns. It selects nothing.
        if arguments.contains("--probe-selection-census") {
            guard let window = AXLogicProElements.mainWindow() else {
                writeStdout("{\"ok\":false,\"error\":\"no main window\"}\n")
                return 1
            }
            let ax = AXLogicProElements.Runtime.production.ax
            var results: [[String: Any]] = []

            func record(_ site: String, _ gathered: Int, _ survivors: Int) {
                results.append([
                    "site": site,
                    "gathered": gathered,
                    "survivors": survivors,
                    // The whole point: a predicate that leaves one has identified something. One
                    // that leaves several has narrowed and then still taken tree order.
                    "identified": survivors == 1,
                ])
            }

            let groups8 = AXHelpers.findAllDescendants(
                of: window, role: "AXGroup", maxDepth: 8, runtime: ax)
            record("AXLogicProElements.isTrackHeadersGroup",
                   groups8.count,
                   groups8.filter { AXLogicProElements.isTrackHeadersGroup($0, runtime: ax) }.count)

            let groups6 = AXHelpers.findAllDescendants(
                of: window, role: "AXGroup", maxDepth: 6, runtime: ax)
            record("AXLogicProElements.looksLikeTransportContainer",
                   groups6.count,
                   groups6.filter { AXLogicProElements.looksLikeTransportContainer($0, runtime: ax) }.count)

            // Sites whose collection is gathered from something other than the window. The input is
            // resolved through the product's own accessor, so a site that cannot be reached in this
            // UI state is reported as unreachable rather than as zero — those are different facts
            // and only one of them is about the code.
            if let controlBar = AXLogicProElements.getControlBar() {
                let barGroups = AXHelpers.findAllDescendants(
                    of: controlBar, role: "AXGroup", maxDepth: 8, runtime: ax)
                record("AXLocalePolicy.playheadPositionGroupLabel (inside the control bar)",
                       barGroups.count,
                       barGroups.filter {
                           AXLocalePolicy.playheadPositionGroupLabel.matches(
                               AXHelpers.getDescription($0, runtime: ax), mode: .exactStrict)
                       }.count)
            } else {
                results.append(["site": "AXLocalePolicy.playheadPositionGroupLabel (inside the control bar)",
                                "unreachable": "no control bar in this UI state"])
            }

            // The toggle locator was deliberately absent here. Its predicate closes over a
            // `labels: [String]` PARAMETER, so a survivor count taken with one label set says as
            // much about the argument as about the tree, and parameterised sites needed their
            // callers enumerated first.
            //
            // They are enumerated now, and the answer is why this can be measured: there are
            // exactly THREE production callers — mute, solo, arm — and every one passes a fixed
            // `AXLocalePolicy` set rather than an arbitrary array. So the three rows below carry
            // the product's own arguments, not a probe author's choice, and the count means what
            // the other rows mean.
            //
            // The predicate is called, not reimplemented: `trackToggleCandidates` is the same
            // function `findTrackToggleControl` selects from.
            if let header = AXLogicProElements.findTrackHeader(at: 0) {
                let boxes = AXHelpers.findAllDescendants(
                    of: header, role: "AXCheckBox", maxDepth: 4, runtime: ax)
                for (site, labels) in [
                    ("AXLogicProElements.findTrackMuteButton",
                     AXLocalePolicy.trackMuteButton.labels),
                    ("AXLogicProElements.findTrackSoloButton",
                     AXLocalePolicy.trackSoloButton.labels),
                    ("AXLogicProElements.findTrackArmButton",
                     AXLocalePolicy.trackRecordEnableCheckbox.labels),
                ] {
                    record(site, boxes.count,
                           AXLogicProElements.trackToggleCandidates(
                               among: boxes, labels: labels, runtime: ax).count)
                }
            } else {
                results.append(["site": "AXLogicProElements.findTrackMute/Solo/ArmButton",
                                "unreachable": "no track header at index 0 in this UI state"])
            }

            if let header = AXLogicProElements.findTrackHeader(at: 0) {
                let sliders = AXHelpers.findAllDescendants(
                    of: header, role: "AXSlider", maxDepth: 4, runtime: ax)
                // The PRODUCT's predicate, called — not a copy of it. The first version of this
                // block reimplemented the closure from `findPanControlInHeader` verbatim, which is
                // the exact thing this issue is a census of and which I had refused four times in
                // its thread. A copy drifts, and then the probe measures a rule the product no
                // longer runs.
                record("AXLogicProElements.findPanControlInHeader (header pan slider)",
                       sliders.count,
                       AXLogicProElements.headerPanSliderCandidates(
                           among: sliders, runtime: ax).count)
            } else {
                results.append(["site": "AXLogicProElements.findPanControlInHeader (header pan slider)",
                                "unreachable": "no track header at index 0 in this UI state"])
            }

            // The mixer strip pair. Both have an UNCONDITIONAL positional fallback when their
            // discriminator finds nothing — `sliders.first` and `sliders[1]` — so what matters here
            // is not only how many survive the predicate but whether the predicate finds anything
            // at all. A survivor count of zero means the site is selecting by index, which is this
            // issue's sentence written literally.
            let mixerArea = AXLogicProElements.getMixerArea()
            let strips = mixerArea.map {
                AXLogicProElements.mixerChannelStrips(in: $0, runtime: ax)
            } ?? []
            if let strip = strips.first {
                let sliders = AXHelpers.findAllDescendants(
                    of: strip, role: "AXSlider", maxDepth: 4, runtime: ax)
                record("AXLogicProElements.findVolumeFader (falls back to sliders.first)",
                       sliders.count,
                       sliders.filter { AXLogicProElements.sliderText($0, runtime: ax).isVolumeFader }.count)
                record("AXLogicProElements.findPanControl (falls back to sliders[1])",
                       sliders.count,
                       sliders.filter { AXLogicProElements.sliderText($0, runtime: ax).isPanControl }.count)
            } else {
                results.append(["site": "AXLogicProElements.findVolumeFader/.findPanControl",
                                "unreachable": "no mixer channel strip in this UI state"])
            }

            // Does the discriminated sibling accessor resolve, and is its answer the same element
            // the transport scan takes first? That is the whole question behind "is this a contract
            // decision or a missing composition" — and it is measurable, not arguable.
            let controlBar = AXLogicProElements.getControlBar()
            let scanFirst = AXLogicProElements.transportContainerCandidates(
                among: AXHelpers.findAllDescendants(of: window, role: "AXGroup", maxDepth: 6, runtime: ax)
            ).first
            results.append([
                "site": "getControlBar() vs the transport scan's first survivor",
                "controlBarResolves": controlBar != nil,
                "scanReturnsSomething": scanFirst != nil,
                "sameElement": (controlBar != nil && scanFirst != nil)
                    ? CFEqual(controlBar!, scanFirst!) : false,
            ])

            let payload: [String: Any] = ["ok": true, "sites": results]
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard let data, let text = String(data: data, encoding: .utf8) else {
                writeStdout("{\"ok\":false,\"error\":\"could not encode the census\"}\n")
                return 1
            }
            writeStdout(text + "\n")
            return 0
        }

        if arguments.contains("--check-permissions") {
            let status = permissionCheck()
            writeStderr(status.summary + "\n")
            return status.allGranted ? 0 : 1
        }

        if let option = arguments.dropFirst().first, option.hasPrefix("-") {
            writeStderr("Unknown option: \(option)\n")
            return 1
        }

        let server = serverFactory()

        // SIGTERM / SIGINT → coordinated shutdown, then exit. Pre-fix the
        // handlers called `exit(0)` directly which skipped the AX poller,
        // channel transports, and virtual MIDI port teardown — leaking
        // resources every time a supervisor restarted the process.
        //
        // The handler runs on a dedicated background queue (not `.main`) so
        // `group.wait` cannot deadlock against an actor that needs the main
        // runloop. Hard timeout caps cleanup at 3s; on overrun we still exit
        // with a non-zero code so a supervisor can notice.
        let signalQueue = DispatchQueue(label: "logic-pro-mcp.signal")
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        ignoreBrokenPipeSignal()

        let shutdownTimeout = DispatchTimeInterval.seconds(3)
        let shutdown: @Sendable () -> Void = { [server] in
            let group = DispatchGroup()
            group.enter()
            Task {
                await server.stop()
                group.leave()
            }
            if group.wait(timeout: .now() + shutdownTimeout) == .timedOut {
                Log.error(
                    "Shutdown timeout exceeded — exiting without confirmed cleanup",
                    subsystem: "main"
                )
                exit(1)
            }
            Log.info("Server stopped — graceful shutdown complete", subsystem: "main")
            exit(0)
        }
        signalSource.setEventHandler(handler: shutdown)
        intSource.setEventHandler(handler: shutdown)
        signalSource.resume()
        intSource.resume()

        do {
            try await server.start()
            return 0
        } catch {
            Log.error("Server failed: \(error)", subsystem: "main")
            return 1
        }
    }

    /// CLI usage printed by `--help`. Kept in sync with the command branches
    /// below and the CLI surface documented in docs/SETUP.md.
    static let usageText = """
        \(ServerConfig.serverName) \(ServerConfig.serverVersion) — Logic Pro MCP server

        USAGE:
          LogicProMCP                          Start the MCP server over stdio (default; used by an MCP client)
          LogicProMCP --help, -h               Print this help and exit
          LogicProMCP --version, -V            Print the version and exit
          LogicProMCP --probe-event-list       Read the open Event List note table once and print JSON; exit
          LogicProMCP --probe-locator-census <AXRole> [--probe-locator-depth N] [--probe-locator-from <AXDescription>]
                                               Count the descendants of the main window with that
                                               role and print JSON; exit. Observation only.
                                               Observation only: it selects nothing and writes nothing.
          LogicProMCP doctor [--json] [--verbose|--quiet] [--check-updates] [--strict] [--profile <core|mixer|keycmd|legacy-scripter|full>] [--client <claude-code|claude-desktop|cursor|vscode|terminal|custom>]
                                               Print a diagnostic report and exit
          LogicProMCP lifecycle <install|update|uninstall> [--json]
                                               Print a read-only lifecycle plan and exit
          LogicProMCP <install|update|uninstall> --dry-run [--json]
                                               Print a read-only lifecycle plan and exit
          LogicProMCP --check-permissions      Print macOS permission status and exit (non-zero if not ready)
          LogicProMCP --qualify --out <attestation.json> [--cases <cases.json>] [--waivers <waivers.json>] [--release-version <version>] [--variant <desktop|creator>] [--locale <en|ko>] [--profile <core|full>] [--cache <cold|warm>]
                                               Drive the packaged binary over stdio and write a live qualification attestation
          LogicProMCP --verify-promotion --attestation <attestation.json> --release-version <version> --expected-binary-sha256 <hex> --expected-commit <sha> [--required-artifacts <path,...>]
                                               non-authoritative local diagnostic; emits a JSON decision with no promotion authority
          LogicProMCP --list-approvals         List manual channel approvals and exit
          LogicProMCP --approve-channel <MIDIKeyCommands|Scripter> [--approval-note <note>]
                                               Record a manual channel approval and exit
          LogicProMCP --skip-channel <MIDIKeyCommands|Scripter> [--skip-note <note>]
                                               Record an intentional doctor skip decision and exit
          LogicProMCP --revoke-channel <MIDIKeyCommands|Scripter>
                                               Revoke a manual channel approval and exit

        With no arguments the binary runs as an MCP stdio server. See docs/SETUP.md for setup.
        """

    /// Ignore SIGPIPE (set disposition to `SIG_IGN`) so a client that closes the
    /// read end of our stdout mid-frame turns the raw `Darwin.write` in
    /// `SerializedStdioTransport` into an EPIPE the write loop already handles —
    /// NOT a default-disposition process kill. Without this the server dies
    /// (signal 13) the instant a peer hangs up. Extracted so the regression test
    /// can install the exact production guard (see `SIGPIPERegressionTests`).
    static func ignoreBrokenPipeSignal() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// True when a terminal global flag (`--version`, `--help`, …) appears
    /// anywhere in the user-supplied arguments (the program path at index 0 is
    /// ignored). These flags print-and-exit, so they are checked before any
    /// subcommand parsing or server startup.
    private static func hasFlag(_ flag: String, or alias: String? = nil, in arguments: [String]) -> Bool {
        let userArgs = arguments.dropFirst()
        return userArgs.contains(flag) || (alias.map { userArgs.contains($0) } ?? false)
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func isDoctorCommand(_ arguments: [String]) -> Bool {
        Array(arguments.dropFirst()).first == "doctor"
    }

    private static func lifecycleCommand(_ arguments: [String]) -> SetupLifecycle.Command? {
        guard let first = Array(arguments.dropFirst()).first else { return nil }
        return SetupLifecycle.Command(rawValue: first)
    }

    private static func isLifecycleSubcommand(_ arguments: [String]) -> Bool {
        Array(arguments.dropFirst()).first == "lifecycle"
    }

    /// The action following the `lifecycle` verb, e.g. `lifecycle install` →
    /// `.install`. The first non-flag token after `lifecycle` is the action, so
    /// `lifecycle install --json` and `lifecycle --json install` both resolve.
    /// Returns nil for a missing or unrecognized action (→ usage error).
    private static func lifecycleSubcommandAction(_ arguments: [String]) -> SetupLifecycle.Command? {
        guard let actionRaw = arguments.dropFirst(2).first(where: { !$0.hasPrefix("-") }) else {
            return nil
        }
        return SetupLifecycle.Command(rawValue: actionRaw)
    }
}
