@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #106 / ADR-001 — the track mute/solo/arm actuator ladder is COORDINATE-FREE.
/// Each op actuates via AX/keyboard only (no mouse click), determines success by
/// RE-READING the checkbox AXValue (never the AX action's return code), and fails
/// closed (never a coordinate fallback) when the read-back never reaches the
/// desired state. Every test is deterministic (fakes, no live Logic) and each
/// asserts ZERO mouse events — the coordinate rung is gone.
@Suite("#106 coordinate-free track toggle actuator")
struct CoordFreeTrackToggleTests {

    // MARK: - Fixtures / doubles

    /// Records the CGEvent keyboard + mouse posts a coordinate-free actuator
    /// makes, and (optionally) mutates the fake AX tree when a key lands — the
    /// deterministic stand-in for "Logic honoured the key command".
    private final class KeyMouseRecorder: @unchecked Sendable {
        var keyEvents: [CGKeyCode] = []
        var flaggedKeyEvents: [(code: CGKeyCode, flags: CGEventFlags)] = []
        var mouseEvents: [(type: CGEventType, point: CGPoint, clickCount: Int64)] = []
        var onKeyEvent: ((CGKeyCode) -> Void)?
        var onFlaggedKey: ((CGKeyCode, CGEventFlags) -> Void)?

        func runtime() -> AXMouseHelper.Runtime {
            AXMouseHelper.Runtime(
                postMouseEvent: { type, point, clickCount in
                    self.mouseEvents.append((type, point, clickCount))
                    return true
                },
                postKeyEvent: { code in
                    self.keyEvents.append(code)
                    self.onKeyEvent?(code)
                    return true
                },
                postUnicodeScalar: { _ in false },
                sleepMicros: { _ in },
                postFlaggedKeyEvent: { code, flags in
                    self.flaggedKeyEvents.append((code, flags))
                    self.onFlaggedKey?(code, flags)
                    return true
                }
            )
        }
    }

    private struct ToggleFixture {
        let builder: FakeAXRuntimeBuilder
        let app: AXUIElement
        let headers: [AXUIElement]
        let mute: [AXUIElement]
        let solo: [AXUIElement]
        let arm: [AXUIElement]
        let recordCheckbox: AXUIElement // control-bar transport Record (arm honesty guard)
    }

    /// A Logic-12-shaped fake: an AXList("Track Headers") of AXLayoutItem rows,
    /// each carrying Mute/Solo/Record-Enable AXCheckBoxes (value 0) plus an
    /// AXSelected flag. `selected` seeds which rows report AXSelected == true.
    private func makeToggleFixture(
        trackCount: Int = 1,
        selected: Set<Int> = [0],
        nilSelected: Set<Int> = []
    ) -> ToggleFixture {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(9000)
        let window = b.element(9001)
        let trackList = b.element(9002)
        let controlBar = b.element(9003)
        let recordCheckbox = b.element(9004)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setChildren(window, [trackList, controlBar])
        b.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
        b.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
        // Control bar with the transport Record checkbox (value 0 = not
        // recording) so `transportRecordingState` can read it in arm tests.
        b.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
        b.setChildren(controlBar, [recordCheckbox])
        b.setAttribute(recordCheckbox, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(recordCheckbox, kAXTitleAttribute as String, "Record")
        b.setAttribute(recordCheckbox, kAXValueAttribute as String, 0)

        var headers: [AXUIElement] = []
        var mutes: [AXUIElement] = []
        var solos: [AXUIElement] = []
        var arms: [AXUIElement] = []
        for i in 0..<trackCount {
            let base = 9100 + i * 10
            let header = b.element(base)
            let mute = b.element(base + 1)
            let solo = b.element(base + 2)
            let arm = b.element(base + 3)
            b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            b.setAttribute(header, kAXTitleAttribute as String, "Track \(i + 1)")
            // `nilSelected` leaves AXSelected UNSET (nil/unreadable) for those rows,
            // modelling headers that omit the attribute (#5 fail-closed input).
            if !nilSelected.contains(i) {
                b.setAttribute(header, kAXSelectedAttribute as String, selected.contains(i))
            }
            for (control, desc) in [(mute, "Mute"), (solo, "Solo"), (arm, "Record Enable")] {
                b.setAttribute(control, kAXRoleAttribute as String, kAXCheckBoxRole as String)
                b.setAttribute(control, kAXDescriptionAttribute as String, desc)
                b.setAttribute(control, kAXValueAttribute as String, 0)
            }
            b.setChildren(header, [mute, solo, arm])
            headers.append(header); mutes.append(mute); solos.append(solo); arms.append(arm)
        }
        b.setChildren(trackList, headers)
        return ToggleFixture(
            builder: b, app: app, headers: headers,
            mute: mutes, solo: solos, arm: arms, recordCheckbox: recordCheckbox
        )
    }

    /// A process runtime whose `activateLogicPro` is a no-op — keeps the
    /// coordinate-free path from reaching for the real Logic app under test.
    private func noopProcessRuntime() -> ProcessUtils.Runtime {
        ProcessUtils.Runtime(
            logicProPID: { 4242 },
            fallbackLogicProPID: { 4242 },
            logicProRunning: { true },
            activateLogicPro: { true },
            logicProBundleURL: { nil }
        )
    }

    private func makeChannel(
        _ fixture: ToggleFixture,
        keyRuntime: AXMouseHelper.Runtime,
        performAction: (@Sendable (AXUIElement, String) -> Bool)? = nil
    ) -> AccessibilityChannel {
        let logic = fixture.builder.makeLogicRuntime(
            appElement: fixture.app,
            setAttributeHandler: nil,
            performActionHandler: performAction
        )
        return AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true },
            isLogicProRunning: { true },
            logicRuntime: logic,
            trackToggleKeyRuntime: keyRuntime,
            processRuntime: noopProcessRuntime()
        ))
    }

    private func object(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func boolValue(_ fixture: ToggleFixture, _ element: AXUIElement) -> Bool? {
        (fixture.builder.attributeValue(element, kAXValueAttribute as String) as? NSNumber)?.boolValue
    }

    // MARK: - Solo: AXPress is the (only) actuator

    @Test("solo flips on AXPress → verified State A via press, ZERO mouse/key")
    func soloAXPressFlipsVerifiedStateA() async throws {
        let f = makeToggleFixture()
        let solo = f.solo[0]
        let key = KeyMouseRecorder()
        // Real Logic: AXPress on the Solo checkbox flips it directly.
        let channel = makeChannel(f, keyRuntime: key.runtime()) { element, action in
            if element == solo, action == kAXPressAction as String {
                f.builder.setAttribute(solo, kAXValueAttribute as String, 1)
            }
            return true
        }

        let result = await channel.execute(operation: "track.set_solo", params: ["index": "0", "enabled": "true"])

        #expect(result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "A")
        #expect(obj?["verified"] as? Bool == true)
        #expect(obj?["action"] as? String == "press")
        #expect(obj?["button"] as? String == "Solo")
        #expect(boolValue(f, solo) == true)
        // ADR-001: solo needs no keyboard and NO coordinate events.
        // Mutation-check: a re-added mouse rung would populate mouseEvents.
        #expect(key.keyEvents.isEmpty)
        #expect(key.mouseEvents.isEmpty)
    }

    @Test("success is judged by the read-back, not the AX return code (#106 sites-6/7)")
    func soloReadbackBeatsReturnCode() async throws {
        let f = makeToggleFixture()
        let solo = f.solo[0]
        let key = KeyMouseRecorder()
        // The action REPORTS failure (false) yet the control actually moved —
        // exactly the live #106 sites-6/7 signature. Only a read-back-driven
        // ladder reaches State A here; a return-code-gated one would State C.
        let channel = makeChannel(f, keyRuntime: key.runtime()) { element, action in
            if element == solo, action == kAXPressAction as String {
                f.builder.setAttribute(solo, kAXValueAttribute as String, 1)
                return false
            }
            return true
        }

        let result = await channel.execute(operation: "track.set_solo", params: ["index": "0", "enabled": "true"])

        #expect(result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "A")
        #expect(obj?["action"] as? String == "press")
        #expect(boolValue(f, solo) == true)
    }

    // MARK: - Mute: select + key 'm'

    @Test("mute: AXPress no-ops, exclusive-select + key 'm' flips → State A keyboard-mute, ZERO mouse")
    func muteKeyboardActuatorFlipsStateA() async throws {
        let f = makeToggleFixture()
        let mute = f.mute[0]
        let key = KeyMouseRecorder()
        key.onKeyEvent = { code in
            if code == AccessibilityChannel.trackMuteKeyCode {
                f.builder.setAttribute(mute, kAXValueAttribute as String, 1)
            }
        }
        // Default performAction (nil): AXPress records + returns true but NEVER
        // flips a checkbox — modelling Logic's no-op mute press.
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "true"])

        #expect(result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "A")
        #expect(obj?["action"] as? String == "keyboard-mute")
        #expect(boolValue(f, mute) == true)
        // The natural-primary AXPress was still tried first (its return ignored)…
        #expect(f.builder.actionCalls.contains {
            $0.elementID == f.builder.elementID(mute) && $0.action == kAXPressAction as String
        })
        // …and the rung that LANDED it was the 'm' key command, ZERO mouse.
        #expect(key.keyEvents.contains(AccessibilityChannel.trackMuteKeyCode))
        #expect(key.mouseEvents.isEmpty)
    }

    @Test("mute fails closed (State C) when the keyboard rung does not flip — no coordinate fallback")
    func muteFailsClosedNoCoordinateFallback() async throws {
        let f = makeToggleFixture()
        let key = KeyMouseRecorder() // records the key but never flips the value
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "true"])

        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "ax_write_failed")
        #expect(boolValue(f, f.mute[0]) == false)
        // The key WAS attempted (selection was exclusive) but nothing flipped —
        // and CRUCIALLY no coordinate rung ran to "rescue" it.
        #expect(key.keyEvents.contains(AccessibilityChannel.trackMuteKeyCode))
        #expect(key.mouseEvents.isEmpty)
    }

    // MARK: - Arm: user-assigned "Toggle Track Record Enable" key command

    @Test("arm: exclusive-select + configurable Ctrl+Shift+E chord flips → State A keyboard-arm, ZERO mouse")
    func armKeyboardActuatorFlipsStateA() async throws {
        let f = makeToggleFixture()
        let arm = f.arm[0]
        guard case let .resolved(armCode, armFlags) = AccessibilityChannel.resolveArmChord() else {
            Issue.record("default arm chord must resolve to a valid code + modifier flags")
            return
        }
        let key = KeyMouseRecorder()
        // Correct "Toggle Track Record Enable": flips the track's record-enable,
        // does NOT touch the transport Record checkbox.
        key.onFlaggedKey = { code, _ in
            if code == armCode { f.builder.setAttribute(arm, kAXValueAttribute as String, 1) }
        }
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_arm", params: ["index": "0", "enabled": "true"])

        #expect(result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "A")
        #expect(obj?["action"] as? String == "keyboard-arm")
        #expect(obj?["button"] as? String == "Record")
        #expect(boolValue(f, arm) == true)
        // The RESOLVED chord (code + modifier flags) was posted, ZERO mouse, and
        // no bare-key path was used.
        #expect(key.flaggedKeyEvents.contains { $0.code == armCode && $0.flags == armFlags })
        #expect(key.keyEvents.isEmpty)
        #expect(key.mouseEvents.isEmpty)
        // Honesty: transport did not start recording.
        #expect(boolValue(f, f.recordCheckbox) == false)
    }

    @Test("arm fails closed (State C) with the exact 'Toggle Track Record Enable' key-command hint")
    func armFailClosedWithKeyCommandHint() async throws {
        let f = makeToggleFixture()
        let key = KeyMouseRecorder() // records the chord but never flips arm
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_arm", params: ["index": "0", "enabled": "true"])

        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "ax_write_failed")
        // Must say EXACTLY the operator-facing key-command guidance.
        #expect(obj?["hint"] as? String == "arm requires the Logic key command 'Toggle Track Record "
            + "Enable' assigned to the configured key (default Ctrl+Shift+E); assign it in Logic ▸ Key "
            + "Commands, or set LOGIC_PRO_MCP_ARM_KEYCODE/_MODIFIERS to your chosen key.")
        #expect(key.mouseEvents.isEmpty)
    }

    @Test("arm honesty: a key that starts transport RECORDING fails closed, never a false arm")
    func armFailsClosedWhenKeyStartsRecording() async throws {
        let f = makeToggleFixture()
        guard case let .resolved(armCode, _) = AccessibilityChannel.resolveArmChord() else {
            Issue.record("default arm chord must resolve")
            return
        }
        let key = KeyMouseRecorder()
        // Mis-assigned key = transport Record: it starts recording (control-bar
        // Record → 1) and does NOT arm the track.
        key.onFlaggedKey = { code, _ in
            if code == armCode { f.builder.setAttribute(f.recordCheckbox, kAXValueAttribute as String, 1) }
        }
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_arm", params: ["index": "0", "enabled": "true"])

        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "ax_write_failed")
        #expect(obj?["recording_started"] as? Bool == true)
        let hint = obj?["hint"] as? String ?? ""
        #expect(hint.contains("transport recording"))
        #expect(hint.contains("Toggle Track Record Enable"))
        // The arm checkbox was never (falsely) claimed armed.
        #expect(boolValue(f, f.arm[0]) == false)
        #expect(key.mouseEvents.isEmpty)
    }

    // MARK: - Toggle-from-read + selection guard

    @Test("toggle-from-read: already at desired → verified no-op with ZERO actuation")
    func toggleFromReadIsVerifiedNoOp() async throws {
        let f = makeToggleFixture()
        f.builder.setAttribute(f.mute[0], kAXValueAttribute as String, 1) // already muted
        let key = KeyMouseRecorder()
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "true"])

        #expect(result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "A")
        #expect(obj?["action"] as? String == "no-op")
        // No rung ran: no AXPress on the checkbox, no key, no mouse.
        // Mutation-check: dropping the toggle-from-read short-circuit would fire
        // the ladder and populate these.
        #expect(!f.builder.actionCalls.contains {
            $0.elementID == f.builder.elementID(f.mute[0]) && $0.action == kAXPressAction as String
        })
        #expect(key.keyEvents.isEmpty)
        #expect(key.mouseEvents.isEmpty)
    }

    @Test("exclusive-selection guard: ambiguous selection blocks the key (no wrong-track toggle)")
    func exclusiveSelectionGuardBlocksKey() async throws {
        // Two tracks, BOTH reporting selected. Keyboard mute would act on the
        // selected track(s) — so with selection non-exclusive the guard MUST
        // refuse to post the key, and the op fails closed.
        let f = makeToggleFixture(trackCount: 2, selected: [0, 1])
        let key = KeyMouseRecorder()
        key.onKeyEvent = { code in
            // If the guard were broken and this fired, it would fabricate a flip.
            if code == AccessibilityChannel.trackMuteKeyCode {
                f.builder.setAttribute(f.mute[0], kAXValueAttribute as String, 1)
            }
        }
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "true"])

        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        // The load-bearing guard assertion: the key was NEVER posted because
        // selection could not be proven exclusive, so no track was toggled.
        #expect(key.keyEvents.isEmpty)
        #expect(key.mouseEvents.isEmpty)
        #expect(boolValue(f, f.mute[0]) == false)
    }

    // MARK: - Configurable arm keycode

    // MARK: - #7 configurable arm chord: config errors fail closed, never fall open

    /// Helper: does `resolveArmChord` return `.resolved` satisfying `check`?
    private func resolvedChord(
        _ env: [String: String],
        _ check: (CGKeyCode, CGEventFlags) -> Bool
    ) -> Bool {
        if case let .resolved(code, flags) = AccessibilityChannel.resolveArmChord(environment: env) {
            return check(code, flags)
        }
        return false
    }

    @Test("#7 arm chord resolution: absent→default; valid→parsed; bad keycode / unknown modifier → config error; empty → bare")
    func armChordResolutionContract() {
        #expect(AccessibilityChannel.defaultArmKeyCode == 14)

        // Row: ABSENT → default Ctrl+Shift+E (14). Force-unwrapped via closure so
        // the assertion is live (never a DEAD `optionalBool == true`).
        #expect(resolvedChord([:]) { code, flags in
            code == 14 && flags.contains(.maskControl) && flags.contains(.maskShift)
                && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate)
        })
        #expect(AccessibilityChannel.defaultArmModifiers == [.maskControl, .maskShift])

        // Row: present + valid keycode + valid modifier list → parsed.
        #expect(resolvedChord([
            "LOGIC_PRO_MCP_ARM_KEYCODE": "60",
            "LOGIC_PRO_MCP_ARM_KEY_MODIFIERS": "command, option"
        ]) { code, flags in
            code == 60 && flags.contains(.maskCommand) && flags.contains(.maskAlternate)
                && !flags.contains(.maskControl)
        })

        // Row: `ARM_KEYCODE=not-a-number` → INVALID (no silent fallback to 14).
        #expect({
            if case .invalidKeyCode = AccessibilityChannel.resolveArmChord(
                environment: ["LOGIC_PRO_MCP_ARM_KEYCODE": "not-a-number"]
            ) { return true }
            return false
        }())

        // Row: `ARM_KEY_MODIFIERS=controle,shft` (typos) → INVALID (no dropped tokens).
        #expect({
            if case .invalidModifierToken = AccessibilityChannel.resolveArmChord(
                environment: ["LOGIC_PRO_MCP_ARM_KEY_MODIFIERS": "controle,shft"]
            ) { return true }
            return false
        }())

        // Row: `ARM_KEY_MODIFIERS=` (present-empty) → resolved as a BARE key (no
        // flags). The arm PATH then refuses this as unsafe (see behavioral test).
        #expect(resolvedChord(["LOGIC_PRO_MCP_ARM_KEY_MODIFIERS": ""]) { _, flags in
            flags.isEmpty
        })
    }

    @Test("#7 arm path fails closed (arm_key_config_invalid) on an unparseable keycode override — key NOT posted")
    func armRefusesInvalidKeycodeConfig() {
        let f = makeToggleFixture()
        let key = KeyMouseRecorder()
        let logic = f.builder.makeLogicRuntime(
            appElement: f.app, setAttributeHandler: nil, performActionHandler: nil
        )
        let result = AccessibilityChannel.defaultSetTrackToggle(
            params: ["index": "0", "enabled": "true"],
            button: "Record",
            runtime: logic,
            keyRuntime: key.runtime(),
            processRuntime: noopProcessRuntime(),
            environment: ["LOGIC_PRO_MCP_ARM_KEYCODE": "not-a-number"]
        )
        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "arm_key_config_invalid")
        // The chord was never posted — a fail-open default would have posted 14.
        #expect(key.flaggedKeyEvents.isEmpty)
        #expect(!boolValue(f, f.arm[0])!)
    }

    @Test("#7 arm path refuses a BARE (no-modifier) key override as unsafe — key NOT posted")
    func armRefusesBareKeyConfig() {
        let f = makeToggleFixture()
        let key = KeyMouseRecorder()
        let logic = f.builder.makeLogicRuntime(
            appElement: f.app, setAttributeHandler: nil, performActionHandler: nil
        )
        let result = AccessibilityChannel.defaultSetTrackToggle(
            params: ["index": "0", "enabled": "true"],
            button: "Record",
            runtime: logic,
            keyRuntime: key.runtime(),
            processRuntime: noopProcessRuntime(),
            environment: ["LOGIC_PRO_MCP_ARM_KEY_MODIFIERS": ""]  // present-empty → bare
        )
        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "arm_key_config_invalid")
        #expect(key.flaggedKeyEvents.isEmpty)
        #expect(key.keyEvents.isEmpty)
    }

    // MARK: - #3 double-toggle halt barrier

    @Test("#3 halt barrier: rung-1 flips but its poll misses ⇒ rung-2 is NOT fired, result State A (no toggle-back)")
    func haltBarrierStopsSecondRungAfterLatePress() {
        // Scripted read-back: the barrier BEFORE the press reads 0 (proceed); the
        // press's poll MISSES (injected false); then — modelling an AXValue that
        // published only after the press poll window — the barrier BEFORE the
        // keyboard rung reads 1 (== desired) and HALTS. A ladder without the
        // barrier would advance and fire (toggle back) the keyboard rung.
        var pressFired = false
        var keyboardFired = false
        let press: AccessibilityChannel.TrackToggleRung = ("press", 250, {
            pressFired = true
            return .actuated
        })
        let keyboard: AccessibilityChannel.TrackToggleRung = ("keyboard-mute", 600, {
            keyboardFired = true
            return .actuated
        })
        let reads: [Bool?] = [false, true]  // barrier-before-press, barrier-before-keyboard
        var idx = 0
        let outcome = AccessibilityChannel.runTrackToggleLadder(
            rungs: [press, keyboard],
            desired: true,
            readValue: {
                defer { idx += 1 }
                return reads[min(idx, reads.count - 1)]
            },
            pollMatched: { _ in false }  // press poll MISSES
        )

        #expect(pressFired)
        #expect(!keyboardFired)  // ← load-bearing: barrier halted before rung-2
        #expect({
            if case .landed(let action) = outcome { return action == "press" }
            return false
        }())
    }

    // MARK: - #5 nil AXSelected is not proof of "unselected"

    @Test("#5 exclusive-select confirm: a non-target header with nil/unreadable AXSelected ⇒ NOT exclusive (fail closed)")
    func nonTargetNilSelectedIsNotExclusive() {
        // Target (0) selected; header 1 omits AXSelected entirely (nil). We cannot
        // PROVE header 1 is unselected, so exclusivity is unproven → refuse.
        let f = makeToggleFixture(trackCount: 2, selected: [0], nilSelected: [1])
        let logic = f.builder.makeLogicRuntime(
            appElement: f.app, setAttributeHandler: nil, performActionHandler: nil
        )
        let exclusive = AccessibilityChannel.confirmExclusiveSelection(
            index: 0, runtime: logic, processRuntime: noopProcessRuntime()
        )
        #expect(!exclusive)
    }

    // MARK: - #4 select→key TOCTOU

    /// Marks a second header selected on the Nth AXPress of a watched header —
    /// modelling a concurrent multi-select that appears between the first exclusive
    /// confirm and the atomic re-confirm right before the key post.
    private final class HeaderPressFlip: @unchecked Sendable {
        let builder: FakeAXRuntimeBuilder
        let watch: AXUIElement
        let onNthPress: Int
        let select: AXUIElement
        var presses = 0
        init(builder: FakeAXRuntimeBuilder, watch: AXUIElement, onNthPress: Int, select: AXUIElement) {
            self.builder = builder
            self.watch = watch
            self.onNthPress = onNthPress
            self.select = select
        }
        func handler(_ element: AXUIElement, _ action: String) -> Bool {
            if action == (kAXPressAction as String), element == watch {
                presses += 1
                if presses == onNthPress {
                    builder.setAttribute(select, kAXSelectedAttribute as String, true)
                }
            }
            return true
        }
    }

    @Test("#4 select→key TOCTOU: selection lost between confirm and post ⇒ fail closed, key NOT posted")
    func selectionLostBeforeKeyFailsClosed() async throws {
        let f = makeToggleFixture(trackCount: 2, selected: [0])  // header 1 starts unselected
        let key = KeyMouseRecorder()
        key.onKeyEvent = { code in
            if code == AccessibilityChannel.trackMuteKeyCode {
                f.builder.setAttribute(f.mute[0], kAXValueAttribute as String, 1)
            }
        }
        // The keyboard rung re-confirms exclusivity IMMEDIATELY before the key. The
        // SECOND confirm's own selectTrackViaAX presses header 0 (press #2 overall),
        // and at that instant header 1 becomes selected too — so the re-check sees a
        // non-exclusive selection and must refuse without posting.
        let flip = HeaderPressFlip(builder: f.builder, watch: f.headers[0], onNthPress: 2, select: f.headers[1])
        let channel = makeChannel(f, keyRuntime: key.runtime(), performAction: { flip.handler($0, $1) })

        let result = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "true"])

        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "selection_not_exclusive")
        // Load-bearing: the TOCTOU re-check caught the change → key NEVER posted.
        #expect(key.keyEvents.isEmpty)
        #expect(!boolValue(f, f.mute[0])!)  // live force-unwrap (fixture always sets 0/1)
    }

    // MARK: - #6 keyboard-focus gate

    @Test("#6 focus gate: a focused editable text field ⇒ mute refuses the synthetic key (unsafe_focus_for_synthetic_key)")
    func muteRefusesWhenFocusIsEditableText() async throws {
        let f = makeToggleFixture()
        // Focus is on a rename/search text field — a synthetic 'm' would type text.
        let textField = f.builder.element(9500)
        f.builder.setAttribute(textField, kAXRoleAttribute as String, kAXTextFieldRole as String)
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, textField)
        let key = KeyMouseRecorder()
        key.onKeyEvent = { code in
            if code == AccessibilityChannel.trackMuteKeyCode {
                f.builder.setAttribute(f.mute[0], kAXValueAttribute as String, 1)
            }
        }
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "true"])

        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "unsafe_focus_for_synthetic_key")
        #expect(key.keyEvents.isEmpty)  // key NEVER posted
        #expect(!boolValue(f, f.mute[0])!)
    }

    @Test("#6 focus gate: a focused editable text field ⇒ arm refuses the synthetic chord")
    func armRefusesWhenFocusIsEditableText() async throws {
        let f = makeToggleFixture()
        let textField = f.builder.element(9500)
        f.builder.setAttribute(textField, kAXRoleAttribute as String, kAXTextFieldRole as String)
        f.builder.setAttribute(f.app, kAXFocusedUIElementAttribute as String, textField)
        let key = KeyMouseRecorder()
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_arm", params: ["index": "0", "enabled": "true"])

        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "unsafe_focus_for_synthetic_key")
        #expect(key.flaggedKeyEvents.isEmpty)  // chord NEVER posted
        #expect(!boolValue(f, f.arm[0])!)
    }

    // MARK: - #2 transport unreadable ⇒ arm fails closed (never State A while maybe recording)

    @Test("#2 arm honesty: transport Record UNREADABLE at post-actuate ⇒ transport_state_unknown, not State A")
    func armFailsClosedWhenTransportUnreadable() async throws {
        let f = makeToggleFixture()
        let arm = f.arm[0]
        guard case let .resolved(armCode, _) = AccessibilityChannel.resolveArmChord() else {
            Issue.record("default arm chord must resolve")
            return
        }
        // Make the control-bar Record checkbox UNREADABLE (a non-numeric AXValue →
        // readControlBarCheckboxValue returns nil), so transport state is unknown.
        f.builder.setAttribute(f.recordCheckbox, kAXValueAttribute as String, "unreadable")
        let key = KeyMouseRecorder()
        // The arm key genuinely flips the record-enable checkbox — but with the
        // transport state unreadable we still cannot honestly claim a clean arm.
        key.onFlaggedKey = { code, _ in
            if code == armCode { f.builder.setAttribute(arm, kAXValueAttribute as String, 1) }
        }
        let channel = makeChannel(f, keyRuntime: key.runtime())

        let result = await channel.execute(operation: "track.set_arm", params: ["index": "0", "enabled": "true"])

        #expect(!result.isSuccess)
        let obj = object(result.message)
        #expect(obj?["state"] as? String == "C")
        #expect(obj?["error"] as? String == "transport_state_unknown")
        // The checkbox DID flip, yet arm is NOT claimed as State A (success:false
        // + State C error above prove it was never a verified clean arm).
        #expect(boolValue(f, arm)!)
        #expect(key.mouseEvents.isEmpty)
    }
}
