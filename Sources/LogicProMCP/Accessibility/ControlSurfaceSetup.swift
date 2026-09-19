import AppKit
import ApplicationServices
import Foundation

/// Consent-based server automation of the one-time control-surface install that every MCU
/// operation depends on (#884, and the #862 operations behind it).
///
/// Why this exists: Logic ships with NO control surface installed. Until one is, every MCU message
/// this server sends is discarded by Logic without a reply — and `logic_system health` still says
/// `mcu.connected: true`, because that flag is set by ANY inbound traffic rather than by a
/// handshake. Measured 2026-09-15 on Logic 12.3 (6674): with no device installed,
/// `track.set_automation` returns State C `channels_exhausted`; with the device installed and both
/// ports bound it returns State B and the mixer's automation button visibly reads Touch.
///
/// The install is GUI-only. Three routes were tried and rejected before this one, and each failure
/// is worth more than the success because each looked like a wall:
///
///   * The Setup window's only plain `AXButton` advertises `AXPress`, returns `.success`, and does
///     nothing. Pressing it by index once opened `Controller Assignments` instead.
///   * The `Control Surfaces` submenu's items contain no install entry.
///   * `Rebuild Defaults` with this server's ports up DOES rewrite
///     `~/Library/Preferences/com.apple.logic.pro.cs` (0 → 5 occurrences of `LogicProMCP`) while
///     the Setup window keeps reading `No Device`. Logic learning the port names is not Logic
///     installing a device, and a check that reads only the preference file cannot tell them apart.
///
/// The route that works is the Setup window's OWN menu bar — an `AXMenuButton` with subrole
/// `AXSegment` whose name is in `AXDescription`, inside the window rather than in the application
/// menu bar. The earlier probes enumerated the application menu bar and the window's `AXButton`s,
/// which is why they reported no route: they never read the two places the route lives.
///
/// The drive, every step judged by an OBSERVED effect rather than by a return code:
///
///   0. Verify-first. Read the Setup window. If the installed model already matches and both ports
///      already read this server's port, NOTHING is written and the run reports that.
///   1. Open `Logic Pro > Control Surfaces > Setup…`. On ko-KR that submenu holds TWO items
///      spelled `설정…` (`Setup…` and `Settings…`) sharing one AXIdentifier, so the item is chosen
///      by pressing a candidate and IDENTIFYING THE WINDOW THAT OPENED; a wrong window is closed
///      and the next candidate tried. Selecting by ordinal would be the positional targeting this
///      repository refuses, and here it would also be wrong half the time.
///   2. `New` → `Install…`, then the device row is matched on manufacturer AND model, must be
///      UNIQUE, is selected via `AXSelected`, and the selection is READ BACK. The run also refuses
///      when any other row reads selected, because `Add` commits the selection rather than the row
///      this code looked at.
///   3. `Add`, then the install is confirmed by re-reading the Setup window's `Model:` label.
///   4. Each port popup is found by its sibling LABEL, never by index. Opening it is done in a
///      SEPARATE step from choosing, because AX calls block while a menu tracks — and the open
///      itself reports `kAXErrorCannotComplete` (-25205) on the very presses that do open the menu,
///      measured 2026-09-15. So the open is judged by whether a menu carrying the popup's current
///      value appeared, and the choice is judged by re-reading the popup's value afterwards.
///   5. The Setup window is closed and the close is read back. A Setup window left open makes every
///      live harness in this repository report `checks_with_blocking_modal_unknown` and refuse.
///   6. State A is claimed ONLY when the caller's verifier observes MCU feedback that Logic sent
///      AFTER this drive began. Logic emits none until a surface is installed and bound, so that
///      reading comes from the application; the ports carrying the right names is the thing this
///      code just wrote, and re-reading it would be the check agreeing with itself.
enum ControlSurfaceSetup {
    /// Manufacturer and model as the Install window publishes them. These are NOT localized — they
    /// come from the device bundle under `Logic Pro.app/Contents/Frameworks/MACore.framework`, and
    /// the ko-KR Install window read 2026-09-15 shows them in English among 144 rows.
    static let manufacturer = "Loud Technologies / Mackie"
    static let model = "Mackie Control"

    /// The virtual CoreMIDI endpoint this server creates. It exists only while the server process
    /// does, so the install must be driven from a live server or the popups will not offer it.
    static let portName = "LogicProMCP-MCU-Internal"

    /// What a run did to the user's configuration.
    enum WriteSource: String, Equatable {
        /// Nothing was written.
        case none
        /// The device and both port bindings were already in place.
        case existingBindingVerify = "existing_binding_verify"
        /// The port bindings were changed; the device was already installed.
        case portsBound = "ports_bound"
        /// The device was installed and both ports bound.
        case deviceInstalled = "device_installed"
    }

    /// Per-phase evidence, surfaced verbatim so a claim is auditable and a failure says how far the
    /// drive got.
    struct Evidence: Equatable {
        var writeSource: WriteSource = .none
        /// True once ANY change to the user's control-surface configuration was attempted.
        var configurationWriteAttempted = false
        var setupWindowOpened = false
        /// How many menu items matched `Setup…` — 2 on ko-KR, and the reason the window is
        /// identified rather than the item.
        var setupMenuCandidates: Int?
        /// A window that opened and was NOT the Setup window, closed again before retrying.
        var wrongWindowOpened: String?
        var installWindowOpened = false
        /// Rows matching manufacturer AND model. Anything but 1 refuses.
        var deviceRowMatches: Int?
        var selectionReadback = false
        var addPressed = false
        /// The `Model:` reading AFTER `Add` — the observed proof an install landed.
        var modelAfterInstall: String?
        var outputPortBefore: String?
        var outputPortAfter: String?
        var inputPortBefore: String?
        var inputPortAfter: String?
        var setupWindowClosed = false
        /// Whether the caller's functional verifier saw a real MCU operation take effect.
        var mcuEffectObserved: Bool?

        var extras: [String: Any] {
            var out: [String: Any] = [
                "write_source": writeSource.rawValue,
                "configuration_write_attempted": configurationWriteAttempted,
                "device_model": ControlSurfaceSetup.model,
                "port_name": ControlSurfaceSetup.portName,
            ]
            out["setup_window_opened"] = setupWindowOpened
            if let setupMenuCandidates { out["setup_menu_candidates"] = setupMenuCandidates }
            if let wrongWindowOpened { out["wrong_window_opened"] = wrongWindowOpened }
            if writeSource == .deviceInstalled {
                out["install_window_opened"] = installWindowOpened
                if let deviceRowMatches { out["device_row_matches"] = deviceRowMatches }
                out["selection_readback"] = selectionReadback
                out["add_pressed"] = addPressed
                if let modelAfterInstall { out["model_after_install"] = modelAfterInstall }
            }
            if let outputPortBefore { out["output_port_before"] = outputPortBefore }
            if let outputPortAfter { out["output_port_after"] = outputPortAfter }
            if let inputPortBefore { out["input_port_before"] = inputPortBefore }
            if let inputPortAfter { out["input_port_after"] = inputPortAfter }
            out["setup_window_closed"] = setupWindowClosed
            if let mcuEffectObserved { out["mcu_effect_observed"] = mcuEffectObserved }
            return out
        }
    }

    /// What the GUI drive alone established. Deliberately SEPARATE from `Outcome`: the drive can
    /// only report what it configured, and "configured" is not "works". Nothing here may be
    /// rendered to a caller — `conclude(_:verifiedBy:)` turns it into an `Outcome`, and it needs a
    /// functional reading to do that.
    enum DriveOutcome: Equatable {
        case consentRequired
        /// Device and both ports were already correct. No configuration was written.
        case alreadyConfigured(Evidence)
        /// Configuration was written and read back.
        case configured(Evidence)
        case failed(stage: String, hint: String, Evidence)
    }

    enum Outcome: Equatable {
        case consentRequired
        /// Device and both ports were already correct AND an MCU operation was observed to land.
        case alreadyBound(Evidence)
        /// Configuration was written and an MCU operation was observed to land.
        case configuredAndVerified(Evidence)
        /// Configuration was written but nothing proved it works — no verifier, or the verifier
        /// could not run. This must never read as success.
        case configuredUnverified(String, Evidence)
        case failed(stage: String, hint: String, Evidence)
    }

    /// Whether a functional MCU check landed. Distinguishing "did not land" from "could not be
    /// attempted" matters: only the first is evidence about the binding.
    enum VerifyResult: Equatable {
        case effectObserved
        case noEffect
        case couldNotAttempt(String)
    }

    struct Runtime {
        var activateLogic: @Sendable () -> Void = {}
        var sleep: @Sendable (Double) -> Void = { _ in }
        var isCancelled: @Sendable () -> Bool = { false }
        var ownsGate: @Sendable () -> Bool = { true }
        var ax: AXHelpers.Runtime
        var elements: AXLogicProElements.Runtime

        static func production(ownsGate: @escaping @Sendable () -> Bool = { true }) -> Runtime {
            Runtime(
                activateLogic: { _ = ProcessUtils.Runtime.production.activateLogicPro() },
                sleep: { Thread.sleep(forTimeInterval: $0) },
                isCancelled: { Task.isCancelled },
                ownsGate: ownsGate,
                ax: .production,
                elements: .production
            )
        }
    }

    // MARK: - Entry point

    /// Drive Logic's GUI. Synchronous and AX-only, so it runs off the cooperative pool; the
    /// functional proof is the caller's job (see `conclude`).
    static func drive(consent: Bool, runtime: Runtime) -> DriveOutcome {
        var evidence = Evidence()
        guard consent else { return .consentRequired }

        runtime.activateLogic()
        runtime.sleep(0.3)

        // 0. Verify-first. Open the window read-only; if everything is already bound, prove it
        //    functionally and write nothing.
        guard let setup = openSetupWindow(runtime: runtime, evidence: &evidence) else {
            return .failed(
                stage: "open_setup_window",
                hint: "Could not open Logic Pro > Control Surfaces > Setup…. "
                    + wrongWindowHint(evidence)
                    + "Open it by hand, then choose New > Install…, add \"\(model)\", and set both "
                    + "Output Port and Input Port to \"\(portName)\".",
                evidence)
        }
        evidence.setupWindowOpened = true

        let installedModel = labelledValue(in: setup, label: AXLocalePolicy.controlSurfaceModelLabel, runtime: runtime)
        evidence.outputPortBefore = labelledValue(in: setup, label: AXLocalePolicy.controlSurfaceOutputPortLabel, runtime: runtime)
        evidence.inputPortBefore = labelledValue(in: setup, label: AXLocalePolicy.controlSurfaceInputPortLabel, runtime: runtime)

        if installedModel == model,
           evidence.outputPortBefore == portName,
           evidence.inputPortBefore == portName {
            evidence.writeSource = .existingBindingVerify
            evidence.setupWindowClosed = closeWindowAndConfirm(setup, runtime: runtime)
            return .alreadyConfigured(evidence)
        }

        // 1. Install the device when it is not there. An unexpected OTHER model is left alone and
        //    refused: replacing somebody's configured surface is not this operation's business.
        if let installedModel, !installedModel.isEmpty, installedModel != model {
            evidence.setupWindowClosed = closeWindowAndConfirm(setup, runtime: runtime)
            return .failed(
                stage: "foreign_device_installed",
                hint: "Logic already has the control surface \"\(installedModel)\" installed. "
                    + "This server will not replace it. Add \"\(model)\" yourself via "
                    + "New > Install… and bind its ports to \"\(portName)\".",
                evidence)
        }

        if installedModel != model {
            guard case .success = installDevice(setup: setup, runtime: runtime, evidence: &evidence) else {
                return .failed(
                    stage: evidence.addPressed ? "confirm_install" : "install_device",
                    hint: installFailureHint(evidence),
                    evidence)
            }
            evidence.writeSource = .deviceInstalled
            // Re-read AFTER the install. The first reading was taken when there was no device, so
            // both ports were nil; publishing that would make the evidence say the popups were
            // unreadable when in fact they did not yet exist.
            evidence.outputPortBefore = labelledValue(in: setup, label: AXLocalePolicy.controlSurfaceOutputPortLabel, runtime: runtime)
            evidence.inputPortBefore = labelledValue(in: setup, label: AXLocalePolicy.controlSurfaceInputPortLabel, runtime: runtime)
        } else {
            evidence.writeSource = .portsBound
        }

        // 2. Bind both ports. Output FIRST: the input port defaults to the all-sources value, which
        //    already includes this server, so a run that stops after the input port can read as
        //    bound while nothing Logic sends can reach anybody.
        for (label, keyPath) in [
            (AXLocalePolicy.controlSurfaceOutputPortLabel, \Evidence.outputPortAfter),
            (AXLocalePolicy.controlSurfaceInputPortLabel, \Evidence.inputPortAfter),
        ] {
            guard !stopped(runtime) else {
                return .failed(stage: "cancelled", hint: "The operation deadline elapsed or the mutation gate was reclaimed before both ports were bound.", evidence)
            }
            evidence.configurationWriteAttempted = true
            let landed = bindPort(in: setup, label: label, to: portName, runtime: runtime)
            evidence[keyPath: keyPath] = landed
            guard landed == portName else {
                evidence.setupWindowClosed = closeWindowAndConfirm(setup, runtime: runtime)
                return .failed(
                    stage: "bind_port",
                    hint: "The \"\(label.canonical)\" popup still reads \(landed.map { "\"\($0)\"" } ?? "nothing") "
                        + "after choosing \"\(portName)\". This server's virtual ports exist only while it "
                        + "runs, so the port is offered only to a live server; bind it by hand if this repeats.",
                    evidence)
            }
        }

        evidence.setupWindowClosed = closeWindowAndConfirm(setup, runtime: runtime)
        return .configured(evidence)
    }

    // MARK: - Functional proof

    /// Join the GUI drive to a functional reading. This is where State A is decided, and the only
    /// input that can decide it is `verifiedBy` — the popups reading the right names is the thing
    /// the drive just WROTE, so checking it again would be the check agreeing with itself.
    static func conclude(_ drive: DriveOutcome, verifiedBy verdict: VerifyResult) -> Outcome {
        switch drive {
        case .consentRequired:
            return .consentRequired
        case .failed(let stage, let hint, let evidence):
            return .failed(stage: stage, hint: hint, evidence)
        case .alreadyConfigured(var evidence), .configured(var evidence):
            let wasAlreadyConfigured: Bool
            if case .alreadyConfigured = drive { wasAlreadyConfigured = true } else { wasAlreadyConfigured = false }
            switch verdict {
            case .effectObserved:
                evidence.mcuEffectObserved = true
                return wasAlreadyConfigured ? .alreadyBound(evidence) : .configuredAndVerified(evidence)
            case .noEffect:
                evidence.mcuEffectObserved = false
                return .failed(
                    stage: "verify_mcu_effect",
                    hint: "Both ports now read \"\(portName)\" but Logic still sends this server no MCU "
                        + "feedback, so the surface is configured and not working. Check that Logic Pro > "
                        + "Control Surfaces > Bypass All Control Surfaces is off.",
                    evidence)
            case .couldNotAttempt(let why):
                evidence.mcuEffectObserved = nil
                return .configuredUnverified(why, evidence)
            }
        }
    }

    // MARK: - Step 1: the Setup window

    /// Press each `Setup…` candidate and keep the one whose WINDOW identifies itself. ko-KR spells
    /// `Setup…` and `Settings…` identically and gives both the same AXIdentifier, so the item cannot
    /// be told apart before it is pressed — only the window it opens can.
    private static func openSetupWindow(runtime: Runtime, evidence: inout Evidence) -> AXUIElement? {
        if let already = window(titled: AXLocalePolicy.controlSurfaceSetupWindowTitle, runtime: runtime) {
            return already
        }
        let candidates = setupMenuCandidates(runtime: runtime)
        evidence.setupMenuCandidates = candidates.count
        for item in candidates {
            guard !stopped(runtime) else { return nil }
            // Snapshot BEFORE the press. The cleanup below closes a window, and "close the frontmost
            // dialog" would happily close a floating window the user already had open — the Library,
            // a plug-in editor — that this operation never opened and has no business touching. Only
            // a window that was not there a moment ago can be one this press produced.
            let before = Set(windows(runtime: runtime).compactMap {
                AXHelpers.getTitle($0, runtime: runtime.ax)
            })
            _ = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
            runtime.sleep(0.8)
            if let found = window(titled: AXLocalePolicy.controlSurfaceSetupWindowTitle, runtime: runtime) {
                return found
            }
            // The other `설정…`. Close what THIS press put up before trying the next candidate, or
            // the preferences dialog stays on screen and every later read is made through it.
            if let stray = windows(runtime: runtime).first(where: { w in
                guard let title = AXHelpers.getTitle(w, runtime: runtime.ax), !before.contains(title) else { return false }
                let subrole = AXHelpers.getAttribute(w, kAXSubroleAttribute as String, runtime: runtime.ax) as String?
                return subrole == "AXDialog" || subrole == "AXFloatingWindow"
            }) {
                evidence.wrongWindowOpened = AXHelpers.getTitle(stray, runtime: runtime.ax)
                _ = closeWindowAndConfirm(stray, runtime: runtime)
                runtime.sleep(0.4)
            }
        }
        return nil
    }

    /// Every menu item under `Logic Pro > Control Surfaces` whose title matches `Setup…`.
    ///
    /// Deliberately NOT `AXLogicProElements.menuItem(labelPath:)`: that returns the FIRST match, and
    /// on ko-KR the first match is a coin flip between the Setup window and a preferences dialog.
    static func setupMenuCandidates(runtime: Runtime) -> [AXUIElement] {
        guard let bar = AXLogicProElements.getMenuBar(runtime: runtime.elements) else { return [] }
        guard let appMenu = AXHelpers.getChildren(bar, runtime: runtime.ax).first(where: {
            AXLocalePolicy.applicationMenuBarItem.matches(AXHelpers.getTitle($0, runtime: runtime.ax))
        }) else { return [] }
        // menu-bar item -> AXMenu -> `Control Surfaces` -> AXMenu -> the items.
        let surfaces = descendants(of: appMenu, depth: 2, runtime: runtime).filter {
            AXLocalePolicy.controlSurfacesMenuItem.matches(AXHelpers.getTitle($0, runtime: runtime.ax))
        }
        return surfaces.flatMap { parent in
            descendants(of: parent, depth: 2, runtime: runtime).filter {
                AXLocalePolicy.controlSurfaceSetupMenuItem.matches(AXHelpers.getTitle($0, runtime: runtime.ax))
            }
        }
    }

    // MARK: - Step 2: install the device

    private enum StepResult { case success, failure }

    private static func installDevice(
        setup: AXUIElement,
        runtime: Runtime,
        evidence: inout Evidence
    ) -> StepResult {
        guard !stopped(runtime) else { return .failure }
        evidence.configurationWriteAttempted = true

        // The window's own menu bar, not the application's: an AXMenuButton naming itself in
        // AXDescription. Probes that read AXTitle, or that read only the application menu bar,
        // report no install route at all.
        guard let newMenu = descendants(of: setup, depth: 4, runtime: runtime).first(where: {
            AXHelpers.getRole($0, runtime: runtime.ax) == "AXMenuButton"
                && AXLocalePolicy.controlSurfaceNewMenuButton.matches(
                    AXHelpers.getDescription($0, runtime: runtime.ax))
        }) else { return .failure }

        _ = AXHelpers.performAction(newMenu, kAXPressAction as String, runtime: runtime.ax)
        runtime.sleep(0.8)

        guard let install = openMenuItem(titled: AXLocalePolicy.controlSurfaceInstallMenuItem, runtime: runtime) else {
            return .failure
        }
        _ = AXHelpers.performAction(install, kAXPressAction as String, runtime: runtime.ax)
        runtime.sleep(1.2)

        guard let picker = window(titled: AXLocalePolicy.controlSurfaceInstallWindowTitle, runtime: runtime) else {
            return .failure
        }
        evidence.installWindowOpened = true

        let rows = descendants(of: picker, depth: 6, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == "AXRow"
        }
        let matches = rows.filter { rowMatchesDevice($0, runtime: runtime) }
        evidence.deviceRowMatches = matches.count
        // Exactly one, or none. Two rows claiming the same manufacturer and model means this build
        // is not what this code was written against, and `Add` commits a selection rather than the
        // row this code looked at.
        guard matches.count == 1, let row = matches.first else {
            _ = closeWindowAndConfirm(picker, runtime: runtime)
            return .failure
        }

        _ = AXHelpers.setAttribute(row, kAXSelectedAttribute as String, kCFBooleanTrue, runtime: runtime.ax)
        runtime.sleep(0.5)
        let selected: Bool? = AXHelpers.getAttribute(row, kAXSelectedAttribute as String, runtime: runtime.ax)
        evidence.selectionReadback = selected == true
        // Another selected row would be added instead of — or alongside — this one.
        let strays = rows.filter { other in
            other != row && (AXHelpers.getAttribute(other, kAXSelectedAttribute as String, runtime: runtime.ax) as Bool? == true)
        }
        guard evidence.selectionReadback, strays.isEmpty else {
            _ = closeWindowAndConfirm(picker, runtime: runtime)
            return .failure
        }

        guard let add = descendants(of: picker, depth: 3, runtime: runtime).first(where: {
            AXHelpers.getRole($0, runtime: runtime.ax) == "AXButton"
                && AXLocalePolicy.controlSurfaceAddButton.matches(AXHelpers.getTitle($0, runtime: runtime.ax))
        }) else {
            _ = closeWindowAndConfirm(picker, runtime: runtime)
            return .failure
        }
        _ = AXHelpers.performAction(add, kAXPressAction as String, runtime: runtime.ax)
        evidence.addPressed = true
        runtime.sleep(1.5)

        // The proof the install landed is the Setup window naming the model — not the press's
        // return code, which is `.success` on presses that do nothing.
        evidence.modelAfterInstall = labelledValue(in: setup, label: AXLocalePolicy.controlSurfaceModelLabel, runtime: runtime)
        _ = closeWindowAndConfirm(picker, runtime: runtime)
        return evidence.modelAfterInstall == model ? .success : .failure
    }

    static func rowMatchesDevice(_ row: AXUIElement, runtime: Runtime) -> Bool {
        let cells = AXHelpers.getChildren(row, runtime: runtime.ax).map { cell in
            AXHelpers.getChildren(cell, runtime: runtime.ax)
                .compactMap { AXHelpers.getValue($0, runtime: runtime.ax) as? String }
                .joined()
        }
        return cells.count >= 2 && cells[0] == manufacturer && cells[1] == model
    }

    // MARK: - Step 3: bind a port

    /// Returns the popup's value AFTER the attempt, so the caller compares against what it wanted
    /// instead of trusting an action result.
    static func bindPort(
        in setup: AXUIElement,
        label: AXLocalePolicy.LabelSet,
        to value: String,
        runtime: Runtime
    ) -> String? {
        guard let popup = labelledPopup(in: setup, label: label, runtime: runtime) else { return nil }
        let before: String? = AXHelpers.getValue(popup, runtime: runtime.ax) as? String
        if before == value { return before }

        // Opening and choosing are two steps because AX calls block while a menu tracks. And the
        // open's return code is not usable: measured 2026-09-15, the press that opened the Input
        // Port menu returned kAXErrorCannotComplete (-25205). The open is judged by whether a menu
        // carrying the popup's CURRENT value appeared.
        _ = AXHelpers.performAction(popup, kAXPressAction as String, runtime: runtime.ax)
        runtime.sleep(0.7)

        guard let before, let item = openMenuItem(titled: value, carryingSibling: before, runtime: runtime) else {
            return AXHelpers.getValue(popup, runtime: runtime.ax) as? String
        }
        _ = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
        runtime.sleep(1.0)
        return AXHelpers.getValue(popup, runtime: runtime.ax) as? String
    }

    // MARK: - AX plumbing

    private static func stopped(_ runtime: Runtime) -> Bool {
        runtime.isCancelled() || !runtime.ownsGate()
    }

    private static func appElement(runtime: Runtime) -> AXUIElement? {
        guard let pid = runtime.elements.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid, runtime: runtime.ax)
    }

    private static func windows(runtime: Runtime) -> [AXUIElement] {
        guard let app = appElement(runtime: runtime) else { return [] }
        return AXHelpers.getAttribute(app, kAXWindowsAttribute as String, runtime: runtime.ax) ?? []
    }

    private static func window(titled label: AXLocalePolicy.LabelSet, runtime: Runtime) -> AXUIElement? {
        windows(runtime: runtime).first { label.matches(AXHelpers.getTitle($0, runtime: runtime.ax)) }
    }

    private static func descendants(of element: AXUIElement, depth: Int, runtime: Runtime) -> [AXUIElement] {
        var frontier = [element]
        var out: [AXUIElement] = []
        for _ in 0..<depth {
            var next: [AXUIElement] = []
            for e in frontier {
                let children = AXHelpers.getChildren(e, runtime: runtime.ax)
                out.append(contentsOf: children)
                next.append(contentsOf: children)
            }
            if next.isEmpty { break }
            frontier = next
        }
        return out
    }

    /// The control beside a label. Logic gives these popups no title, no identifier and no
    /// description, so the label that sits next to them is the only name they have — and an index
    /// is not a name.
    static func labelledPopup(
        in window: AXUIElement,
        label: AXLocalePolicy.LabelSet,
        runtime: Runtime
    ) -> AXUIElement? {
        let hits = labelledSiblings(in: window, label: label, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime.ax) == "AXPopUpButton"
        }
        // Exactly one, so a relabelled build refuses instead of writing to whatever came first.
        return hits.count == 1 ? hits.first : nil
    }

    static func labelledValue(
        in window: AXUIElement,
        label: AXLocalePolicy.LabelSet,
        runtime: Runtime
    ) -> String? {
        let hits = labelledSiblings(in: window, label: label, runtime: runtime)
        guard hits.count == 1, let e = hits.first else { return nil }
        return AXHelpers.getValue(e, runtime: runtime.ax) as? String
    }

    private static func labelledSiblings(
        in window: AXUIElement,
        label: AXLocalePolicy.LabelSet,
        runtime: Runtime
    ) -> [AXUIElement] {
        var out: [AXUIElement] = []
        for group in descendants(of: window, depth: 14, runtime: runtime) {
            let children = AXHelpers.getChildren(group, runtime: runtime.ax)
            guard children.count >= 2 else { continue }
            let text = AXHelpers.getValue(children[0], runtime: runtime.ax) as? String
            // `.prefix`, not `.exactStrict`. The form DRAWS the colon after a field name and Logic's
            // table holds the bare name -- `field_label` in docs/canon/DECORATION-RULES.json,
            // witnessed. Comparing verbatim forced these three LabelSets to carry a colon on
            // every spelling, which made them nine hand-typed strings instead of Apple's row,
            // and a row is what can be checked offline in all ten locales. Ambiguity still
            // fails closed: `labelledValue` requires exactly one hit.
            if label.matches(text, mode: .prefix) { out.append(children[1]) }
        }
        return out
    }

    /// An item in whatever menu is currently tracking. `carryingSibling` identifies WHICH menu when
    /// several are alive — a popup's menu is the one that also lists the popup's current value.
    private static func openMenuItem(
        titled title: String,
        carryingSibling sibling: String? = nil,
        runtime: Runtime
    ) -> AXUIElement? {
        guard let app = appElement(runtime: runtime) else { return nil }
        var menus: [AXUIElement] = []
        var frontier = [app]
        for _ in 0..<10 {
            var next: [AXUIElement] = []
            for e in frontier {
                for c in AXHelpers.getChildren(e, runtime: runtime.ax) {
                    if AXHelpers.getRole(c, runtime: runtime.ax) == "AXMenu" { menus.append(c) }
                    next.append(c)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        for menu in menus {
            let items = AXHelpers.getChildren(menu, runtime: runtime.ax)
            let titles = items.map { AXHelpers.getTitle($0, runtime: runtime.ax) ?? "" }
            if let sibling, !titles.contains(sibling) { continue }
            if let i = items.first(where: { AXHelpers.getTitle($0, runtime: runtime.ax) == title }) { return i }
        }
        return nil
    }

    private static func openMenuItem(
        titled label: AXLocalePolicy.LabelSet,
        runtime: Runtime
    ) -> AXUIElement? {
        guard let app = appElement(runtime: runtime) else { return nil }
        var frontier = [app]
        for _ in 0..<10 {
            var next: [AXUIElement] = []
            for e in frontier {
                for c in AXHelpers.getChildren(e, runtime: runtime.ax) {
                    if AXHelpers.getRole(c, runtime: runtime.ax) == "AXMenu" {
                        for item in AXHelpers.getChildren(c, runtime: runtime.ax)
                        where label.matches(AXHelpers.getTitle(item, runtime: runtime.ax)) {
                            return item
                        }
                    }
                    next.append(c)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return nil
    }

    /// Close a window and READ BACK that it went. A close button that reports success while the
    /// window stays is the same class of lie as a press that changes nothing.
    @discardableResult
    private static func closeWindowAndConfirm(_ w: AXUIElement, runtime: Runtime) -> Bool {
        guard let button = AXHelpers.getChildren(w, runtime: runtime.ax).first(where: {
            AXHelpers.getAttribute($0, kAXSubroleAttribute as String, runtime: runtime.ax) as String? == "AXCloseButton"
        }) else { return false }
        let title = AXHelpers.getTitle(w, runtime: runtime.ax)
        _ = AXHelpers.performAction(button, kAXPressAction as String, runtime: runtime.ax)
        for _ in 0..<10 {
            runtime.sleep(0.2)
            let open = windows(runtime: runtime).contains { AXHelpers.getTitle($0, runtime: runtime.ax) == title }
            if !open { return true }
        }
        return false
    }

    // MARK: - Hints

    private static func wrongWindowHint(_ e: Evidence) -> String {
        guard let wrong = e.wrongWindowOpened else { return "" }
        return "Pressing a \"\(AXLocalePolicy.controlSurfaceSetupMenuItem.canonical)\" item opened "
            + "\"\(wrong)\" instead — on a Korean Logic that submenu spells both "
            + "\"\(AXLocalePolicy.controlSurfaceSetupMenuItem.canonical)\" and "
            + "\"\(AXLocalePolicy.controlSurfaceSettingsMenuItem.canonical)\" the same way. "
    }

    private static func installFailureHint(_ e: Evidence) -> String {
        if let n = e.deviceRowMatches, n != 1 {
            return "The Install window listed \(n) rows for \"\(manufacturer)\" / \"\(model)\"; "
                + "this server acts only on exactly one."
        }
        if e.addPressed {
            return "Add was pressed but the Setup window still reads "
                + "\(e.modelAfterInstall.map { "\"\($0)\"" } ?? "no model") rather than \"\(model)\"."
        }
        if !e.installWindowOpened {
            return "The New > Install… route did not open the device picker."
        }
        return "The device row could not be selected, so Add was never pressed."
    }
}
