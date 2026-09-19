@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

/// The install drive itself can only be validated live — a fake cannot reproduce a real Logic
/// Install window (`2026-09-15-the-setup-windows-own-menu-installs-the-surface` is that reading).
/// What is pinned here is the part a live run cannot pin: that each refusal CAN fire.
///
/// Every case below names the mutation it would survive if the code were wrong, because four
/// controls in this repository have already passed for the wrong reason. In particular
/// `conclude` is exercised in BOTH directions: a check that only asserts the success mapping
/// would still pass if `noEffect` were also mapped to success, which is precisely the bug that
/// would let this operation certify a control surface that does not work.
@Suite struct ControlSurfaceSetupTests {
    /// The runtime's hooks are `@Sendable`, so a captured `var` cannot record that one fired.
    private final class Flag: @unchecked Sendable {
        private(set) var value = false
        func set() { value = true }
    }


    // MARK: - The honesty mapping

    @Test("a configured surface with no observed MCU effect is a FAILURE, not a success")
    func noEffectIsNotSuccess() throws {
        var e = ControlSurfaceSetup.Evidence()
        e.writeSource = .deviceInstalled
        let out = ControlSurfaceSetup.conclude(.configured(e), verifiedBy: .noEffect)
        guard case .failed(let stage, _, let evidence) = out else {
            Issue.record("expected .failed, got \(out)")
            return
        }
        #expect(stage == "verify_mcu_effect")
        // The evidence must SAY the effect was absent. A nil here would read as "not checked".
        // Comparing an OPTIONAL Bool against a literal is dead in this toolchain — the assertion
        // always passes — so the unwrap below is what actually asserts. Caught by the
        // public-surface preflight rather than by the suite: three lines here were green while
        // checking nothing, and they were the lines guarding "configured but not working must not
        // read as success".
        let observed = try #require(evidence.mcuEffectObserved)
        #expect(!observed)
        let published = try #require(evidence.extras["mcu_effect_observed"] as? Bool)
        #expect(!published)
    }

    @Test("an already-correct surface with no observed MCU effect is also a failure")
    func alreadyConfiguredStillNeedsProof() {
        var e = ControlSurfaceSetup.Evidence()
        e.writeSource = .existingBindingVerify
        let out = ControlSurfaceSetup.conclude(.alreadyConfigured(e), verifiedBy: .noEffect)
        guard case .failed = out else {
            Issue.record("expected .failed, got \(out)")
            return
        }
    }

    @Test("an observed MCU effect is the only thing that produces a verified outcome")
    func effectObservedVerifies() throws {
        var e = ControlSurfaceSetup.Evidence()
        e.writeSource = .deviceInstalled
        guard case .configuredAndVerified(let ev) = ControlSurfaceSetup.conclude(.configured(e), verifiedBy: .effectObserved) else {
            Issue.record("configured + effect should verify")
            return
        }
        #expect(try #require(ev.mcuEffectObserved))

        var e2 = ControlSurfaceSetup.Evidence()
        e2.writeSource = .existingBindingVerify
        guard case .alreadyBound = ControlSurfaceSetup.conclude(.alreadyConfigured(e2), verifiedBy: .effectObserved) else {
            Issue.record("already configured + effect should report alreadyBound")
            return
        }
    }

    @Test("a verification that could not be attempted is UNVERIFIED, distinct from a verification that failed")
    func couldNotAttemptIsItsOwnState() {
        let e = ControlSurfaceSetup.Evidence()
        guard case .configuredUnverified(let why, let ev) = ControlSurfaceSetup.conclude(
            .configured(e), verifiedBy: .couldNotAttempt("the poll never ran")) else {
            Issue.record("expected .configuredUnverified")
            return
        }
        #expect(why == "the poll never ran")
        // nil, not false: nothing observed the absence of an effect either.
        #expect(ev.mcuEffectObserved == nil)
        #expect(ev.extras["mcu_effect_observed"] == nil)
    }

    @Test("consent and drive failures pass through conclude untouched")
    func passThroughs() {
        #expect(ControlSurfaceSetup.conclude(.consentRequired, verifiedBy: .effectObserved) == .consentRequired)
        var e = ControlSurfaceSetup.Evidence()
        e.configurationWriteAttempted = true
        // Even an observed effect must not upgrade a failed drive: the effect could be someone
        // else's already-working surface.
        guard case .failed(let stage, _, _) = ControlSurfaceSetup.conclude(
            .failed(stage: "install_device", hint: "h", e), verifiedBy: .effectObserved) else {
            Issue.record("a failed drive must stay failed")
            return
        }
        #expect(stage == "install_device")
    }

    // MARK: - Consent

    @Test("without consent the drive performs no AX call at all")
    func consentGateIsBeforeEverySideEffect() {
        let b = FakeAXRuntimeBuilder()
        let ax = b.makeAXRuntime()
        let runtime = ControlSurfaceSetup.Runtime(
            ax: ax, elements: AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax))
        let activated = Flag()
        var rt = runtime
        rt.activateLogic = { activated.set() }
        #expect(ControlSurfaceSetup.drive(consent: false, runtime: rt) == .consentRequired)
        // Mutation this would catch: moving the consent guard below `activateLogic()`, which is
        // how a refusal becomes a refusal that already touched the user's machine.
        #expect(!activated.value)
        #expect(b.actionCalls.isEmpty)
        #expect(b.setCalls.isEmpty)
    }

    // MARK: - The ko-KR menu collision

    @Test("both Korean 설정… items are returned, because only the window they open tells them apart")
    func setupMenuCandidatesReturnsBoth() {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(0), bar = b.element(1), logicMenu = b.element(2)
        let barMenu = b.element(3), surfaces = b.element(4), surfacesMenu = b.element(5)
        let setup = b.element(6), settings = b.element(7), rebuild = b.element(8)
        b.setAttribute(app, kAXMenuBarAttribute as String, bar)
        b.setChildren(bar, [logicMenu])
        b.setAttribute(logicMenu, kAXTitleAttribute as String, "Logic Pro")
        b.setChildren(logicMenu, [barMenu])
        b.setChildren(barMenu, [surfaces])
        b.setAttribute(surfaces, kAXTitleAttribute as String, "컨트롤 서피스")
        b.setChildren(surfaces, [surfacesMenu])
        b.setChildren(surfacesMenu, [setup, settings, rebuild])
        // Logic renders `Setup…` and `Settings…` identically in Korean, and gives both the same
        // AXIdentifier. Measured en-US 2026-09-12 / ko-KR 2026-09-05.
        b.setAttribute(setup, kAXTitleAttribute as String, "설정…")
        b.setAttribute(settings, kAXTitleAttribute as String, "설정…")
        b.setAttribute(rebuild, kAXTitleAttribute as String, "기본값 재형성")

        let ax = b.makeAXRuntime(appElement: app)
        let rt = ControlSurfaceSetup.Runtime(
            ax: ax, elements: AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax))
        // Mutation this catches: using `AXLogicProElements.menuItem(labelPath:)`, which returns the
        // FIRST match — a coin flip between the Setup window and a preferences dialog.
        #expect(ControlSurfaceSetup.setupMenuCandidates(runtime: rt).count == 2)
    }

    // MARK: - The device row

    @Test("the device row must match manufacturer AND model exactly")
    func rowMatchingRefusesNeighbours() {
        // The three rows that really sit beside the target in the Install window, read live
        // 2026-09-15. Each one is a model whose name CONTAINS the target's.
        let cases: [(String, String, Bool)] = [
            ("Loud Technologies / Mackie", "Mackie Control", true),
            ("Loud Technologies / Mackie", "Mackie Control C4", false),
            ("Loud Technologies / Mackie", "Mackie Control Extender", false),
            ("Loud Technologies / Mackie", "Mackie Control Extender Pro", false),
            ("Akai", "Mackie Control", false),
        ]
        for (maker, model, expected) in cases {
            let b = FakeAXRuntimeBuilder()
            let row = b.element(0), c0 = b.element(1), c1 = b.element(2)
            let t0 = b.element(3), t1 = b.element(4)
            b.setChildren(row, [c0, c1])
            b.setChildren(c0, [t0]); b.setChildren(c1, [t1])
            b.setAttribute(t0, kAXValueAttribute as String, maker)
            b.setAttribute(t1, kAXValueAttribute as String, model)
            let ax = b.makeAXRuntime()
            let rt = ControlSurfaceSetup.Runtime(
                ax: ax, elements: AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax))
            // Branch rather than compare against `expected`. Both sides are Bool here so the
            // comparison is not actually dead, but the integrity scanner cannot tell a Bool
            // operand from an Optional one and neither can a reader skimming it — and the whole
            // point of that scanner is that this shape has hidden always-pass assertions before.
            let matched = ControlSurfaceSetup.rowMatchesDevice(row, runtime: rt)
            if expected {
                #expect(matched, "\(maker) / \(model) must match")
            } else {
                #expect(!matched, "\(maker) / \(model) must NOT match")
            }
        }
    }

    // MARK: - The labelled popup

    private func portWindow(
        labels: [(String, String, String)]
    ) -> (FakeAXRuntimeBuilder, AXUIElement, ControlSurfaceSetup.Runtime) {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(0)
        var groups: [AXUIElement] = []
        var id = 1
        for (label, role, value) in labels {
            let group = b.element(id); id += 1
            let text = b.element(id); id += 1
            let control = b.element(id); id += 1
            b.setAttribute(text, kAXValueAttribute as String, label)
            b.setAttribute(control, kAXRoleAttribute as String, role)
            b.setAttribute(control, kAXValueAttribute as String, value)
            b.setChildren(group, [text, control])
            groups.append(group)
        }
        b.setChildren(window, groups)
        let ax = b.makeAXRuntime(appElement: window)
        return (b, window, ControlSurfaceSetup.Runtime(
            ax: ax, elements: AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: ax)))
    }

    @Test("a port popup is found by the label beside it")
    func popupFoundByLabel() {
        let (_, window, rt) = portWindow(labels: [
            ("출력 포트:", "AXPopUpButton", "끔"),
            ("입력 포트:", "AXPopUpButton", "모두"),
        ])
        #expect(ControlSurfaceSetup.labelledValue(
            in: window, label: AXLocalePolicy.controlSurfaceOutputPortLabel, runtime: rt) == "끔")
        #expect(ControlSurfaceSetup.labelledValue(
            in: window, label: AXLocalePolicy.controlSurfaceInputPortLabel, runtime: rt) == "모두")
    }

    @Test("the port labels are found in every language Logic ships, with the colon the form draws")
    func popupFoundInEveryLocale() {
        // The reason these three LabelSets carry Apple's row instead of hand-typed spellings. Each
        // pair below is `Localizable.strings/<locale>/Output Port` and `.../Input Port` verbatim,
        // with the trailing colon the form DRAWS and the table does not store -- `field_label` in
        // docs/canon/DECORATION-RULES.json. Under the old `.exactStrict` comparison only the two
        // spellings somebody had typed matched, and the other eight languages read as unbound.
        for (locale, output, input) in [
            ("en", "Output Port", "Input Port"),
            ("ko", "출력 포트", "입력 포트"),
            ("ja", "出力ポート", "入力ポート"),
            ("de", "Output-Port", "Input-Port"),
            ("es", "Puerto de salida", "Puerto de entrada"),
            ("fr", "Port de sortie", "Port d’entrée"),
            ("it", "Porta di uscita", "Porta di ingresso"),
            ("pt", "Porta de saída", "Porta de entrada"),
            ("zh_CN", "输出端口", "输入端口"),
            ("zh_TW", "輸出埠", "輸入埠"),
        ] {
            let (_, window, rt) = portWindow(labels: [
                (output + ":", "AXPopUpButton", "끔"),
                (input + ":", "AXPopUpButton", "모두"),
            ])
            #expect(ControlSurfaceSetup.labelledValue(
                in: window, label: AXLocalePolicy.controlSurfaceOutputPortLabel,
                runtime: rt) == "끔", "output port unreadable in \(locale)")
            #expect(ControlSurfaceSetup.labelledValue(
                in: window, label: AXLocalePolicy.controlSurfaceInputPortLabel,
                runtime: rt) == "모두", "input port unreadable in \(locale)")
        }
    }

    @Test("the label match is ANCHORED, so a longer field name that merely contains it is not it")
    func prefixIsAnchoredNotContained() {
        // The control for the case above. `.prefix` is looser than `.exactStrict` and the looseness
        // has to stop somewhere: it tolerates what the form DRAWS after the name, never a different
        // name the label happens to sit inside. Without the anchor this reads the wrong popup and
        // reports it as the port, which is worse than reporting nothing.
        let (_, window, rt) = portWindow(labels: [
            ("MIDI 입력 포트:", "AXPopUpButton", "wrong"),
        ])
        #expect(ControlSurfaceSetup.labelledValue(
            in: window, label: AXLocalePolicy.controlSurfaceInputPortLabel, runtime: rt) == nil)
    }

    @Test("two controls under one label refuse rather than picking whichever came first")
    func duplicateLabelRefuses() {
        let (_, window, rt) = portWindow(labels: [
            ("출력 포트:", "AXPopUpButton", "끔"),
            ("출력 포트:", "AXPopUpButton", "LogicProMCP-MCU-Internal"),
        ])
        // Mutation this catches: `.first` instead of a uniqueness check — which would silently
        // bind the wrong control and, worse, read back the RIGHT-looking value from the other one.
        #expect(ControlSurfaceSetup.labelledPopup(
            in: window, label: AXLocalePolicy.controlSurfaceOutputPortLabel, runtime: rt) == nil)
    }

    @Test("a port already carrying the wanted value is left alone and reported as-is")
    func bindIsIdempotent() {
        let (b, window, rt) = portWindow(labels: [
            ("출력 포트:", "AXPopUpButton", ControlSurfaceSetup.portName),
        ])
        let after = ControlSurfaceSetup.bindPort(
            in: window, label: AXLocalePolicy.controlSurfaceOutputPortLabel,
            to: ControlSurfaceSetup.portName, runtime: rt)
        #expect(after == ControlSurfaceSetup.portName)
        // No menu was opened, so nothing in the user's configuration was touched.
        #expect(b.actionCalls.isEmpty)
    }

    @Test("a bind whose popup does not change reports the OLD value, so the caller's check fails")
    func bindReportsWhatItSees() {
        let (_, window, rt) = portWindow(labels: [
            ("출력 포트:", "AXPopUpButton", "끔"),
        ])
        // No AXMenu exists in this fixture, so the choice cannot be made. The measured reason this
        // matters: on 2026-09-15 the press that opened the Input Port menu returned
        // kAXErrorCannotComplete, so neither the action's result nor its absence says anything.
        // Only the value afterwards does.
        let after = ControlSurfaceSetup.bindPort(
            in: window, label: AXLocalePolicy.controlSurfaceOutputPortLabel,
            to: ControlSurfaceSetup.portName, runtime: rt)
        #expect(after == "끔")
        #expect(after != ControlSurfaceSetup.portName)
    }

    // MARK: - Locale

    @Test("the Korean spelling of Setup… and Settings… is the same string in both label sets")
    func localeRecordsTheCollision() {
        // This is a FACT about Logic, pinned so that anyone who 'fixes' one of these variants has
        // to confront that the collision is the reason the drive identifies windows, not items.
        #expect(AXLocalePolicy.controlSurfaceSetupMenuItem.matches("설정…"))
        #expect(AXLocalePolicy.controlSurfaceSettingsMenuItem.matches("설정…"))
        #expect(AXLocalePolicy.controlSurfaceSetupMenuItem.canonical
                != AXLocalePolicy.controlSurfaceSettingsMenuItem.canonical)
    }

    @Test("every control-surface label set is registered for the locale projection")
    func labelSetsAreRegistered() {
        let registered = AXLocalePolicy.allLabelSets
        for set in [AXLocalePolicy.controlSurfacesMenuItem,
                    AXLocalePolicy.controlSurfaceSetupMenuItem,
                    AXLocalePolicy.controlSurfaceSettingsMenuItem,
                    AXLocalePolicy.controlSurfaceSetupWindowTitle,
                    AXLocalePolicy.controlSurfaceNewMenuButton,
                    AXLocalePolicy.controlSurfaceInstallMenuItem,
                    AXLocalePolicy.controlSurfaceInstallWindowTitle,
                    AXLocalePolicy.controlSurfaceAddButton,
                    AXLocalePolicy.controlSurfaceOutputPortLabel,
                    AXLocalePolicy.controlSurfaceInputPortLabel,
                    AXLocalePolicy.controlSurfaceModelLabel,
                    AXLocalePolicy.applicationMenuBarItem] {
            #expect(registered.contains(set), "\(set.canonical) is not in allLabelSets")
        }
    }

    // MARK: - Evidence

    @Test("evidence does not publish install fields for a run that installed nothing")
    func evidenceDoesNotOverclaim() {
        var e = ControlSurfaceSetup.Evidence()
        e.writeSource = .portsBound
        e.deviceRowMatches = 1
        e.addPressed = true
        let extras = e.extras
        // Mutation this catches: publishing install evidence unconditionally, which would let a
        // ports-only run present `add_pressed: true` left over from a field nobody set this run.
        #expect(extras["add_pressed"] == nil)
        #expect(extras["device_row_matches"] == nil)
        #expect(extras["write_source"] as? String == "ports_bound")
    }
}
