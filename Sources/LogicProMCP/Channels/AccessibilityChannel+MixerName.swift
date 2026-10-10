@preconcurrency import ApplicationServices
import Foundation

extension AccessibilityChannel {
    /// One name write on an already-issued physical Mixer source. This does not
    /// establish Arrange association, coupling, an inverse or plan preservation.
    static func renamePhysicalMixerStrip(
        params: [String: String], runtime: AXLogicProElements.Runtime,
        mouse: AXMouseHelper.Runtime, canPostEvents: @Sendable () -> Bool
    ) -> ChannelResult {
        let guardHelp = AXHelpers.HelpReadGuard(allowHelpReads: false, stop: { !ExactTrackNameAdapter.operationPermitted() })
        return AXHelpers.HelpReadGuard.$current.withValue(guardHelp) {
            var attempted = false
            var before: String?
            var extras: [String: Any] {
                ["operation": "mixer.rename_exact", "before": before as Any? ?? NSNull(),
                 "write_attempted": attempted, "coupling_qualified": false,
                 "focus_restoration": attempted ? "not_restored" : "not_attempted"]
            }
            func refuse(_ hint: String) -> ChannelResult {
                if attempted { return .success(HonestContract.encodeStateB(reason: .readbackUnavailable,
                    extras: extras.merging(["hint": hint]) { _, new in new })) }
                return .error(HonestContract.encodeStateC(error: .staleTargetReference, hint: hint, extras: extras))
            }
            guard Set(params.keys) == ["name", "expected_name"], let desired = params["name"],
                  let expected = params["expected_name"], TrackDispatcher.renameNameFailure(desired) == nil,
                  let source = AXMixerStripBinding.current, let pid = runtime.logicProPID(),
                  let app = AXLogicProElements.appRoot(runtime: runtime) else {
                return refuse("An observed physical Mixer source and valid exact name bytes are required.")
            }
            func owned() -> Bool {
                guard ExactTrackNameAdapter.operationPermitted(), runtime.logicProPID() == pid,
                      runtime.focusedApplicationPID() == pid, source.currentIndex(runtime: runtime) != nil,
                      case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: runtime),
                      CFEqual(window, source.window),
                      case .success(.some(let doc)) = AXLogicProElements.projectPickerDocumentRead(source.window, runtime: runtime),
                      doc.utf8.elementsEqual(source.document.utf8),
                      let focusedWindow: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedWindowAttribute as String, runtime: runtime.ax),
                      CFEqual(focusedWindow, source.window) else { return false }
                return ExactTrackNameAdapter.operationPermitted()
            }
            func nameField() -> AXUIElement? {
                guard case .success(let children) = AXHelpers.childrenResult(source.strip, runtime: runtime.ax) else { return nil }
                var matches: [AXUIElement] = []
                for child in children {
                    guard case .success(.some(let role)) = AXHelpers.getAttributeResult(child, kAXRoleAttribute as String, runtime: runtime.ax)
                        as Result<String?, AXHelpers.AXStatusError> else { return nil }
                    if role != kAXTextFieldRole as String { continue }
                    guard case .success(.some(let description)) = AXHelpers.getAttributeResult(child, kAXDescriptionAttribute as String, runtime: runtime.ax)
                        as Result<String?, AXHelpers.AXStatusError> else { return nil }
                    if AXLocalePolicy.mixerStripNameField.matches(description, mode: .exact) { matches.append(child) }
                }
                return matches.count == 1 ? matches[0] : nil
            }
            func observedName() -> String? {
                guard owned(), case .success(.some(let name)) = AXPluginInstanceIdentity.stripNameResult(source.strip, runtime: runtime.ax),
                      owned() else { return nil }
                return name
            }
            func stopped() -> Bool {
                AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportPlayControl, runtime: runtime) == false &&
                AXLogicProElements.readControlBarCheckboxValue(matching: AXLocalePolicy.transportRecordControl, runtime: runtime) == false
            }
            before = observedName()
            guard let before, before.utf8.elementsEqual(expected.utf8), let plate = nameField() else {
                return refuse("The same physical source does not have the exact expected name.")
            }
            if before.utf8.elementsEqual(desired.utf8) {
                return .success(HonestContract.encodeStateA(extras: extras.merging([
                    "observed": before, "via": "no-op", "reread_required": false
                ]) { _, new in new }))
            }
            func safeAcquisitionFocus() -> AXUIElement? {
                guard let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) else { return nil }
                if readLogicKeyboardFocus(of: focused, runtime: runtime) != .notTextEditing {
                    // Logic reports an insertion point on the focused strip
                    // after one click. Only this original physical container
                    // with its original, noneditable name plate is allowed.
                    guard CFEqual(focused, source.strip),
                          AXHelpers.getRole(focused, runtime: runtime.ax) == "AXLayoutItem",
                          nameField().map({ CFEqual($0, plate) }) == true,
                          AXHelpers.isAttributeSettable(plate, kAXValueAttribute as String, runtime: runtime.ax) == false else { return nil }
                }
                guard let finalFocus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                      CFEqual(finalFocus, focused) else { return nil }
                return ExactTrackNameAdapter.operationPermitted() ? focused : nil
            }
            guard safeAcquisitionFocus() != nil,
                  !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
                  stopped(),
                  let hitTest = runtime.ax.elementAtPosition,
                  let position = AXHelpers.getPosition(plate, runtime: runtime.ax),
                  let size = AXHelpers.getSize(plate, runtime: runtime.ax),
                  position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else {
                return refuse("Stopped transport, safe focus and the exact name field geometry must be observable.")
            }
            let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
            for count: Int64 in [1, 2] {
                guard let pair = mouse.prepareMouseClick(point, count),
                      stopped(), !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
                      let safeFocus = safeAcquisitionFocus(),
                      owned(), nameField().map({ CFEqual($0, plate) }) == true,
                      observedName()?.utf8.elementsEqual(expected.utf8) == true,
                      AXHelpers.getPosition(plate, runtime: runtime.ax) == position,
                      AXHelpers.getSize(plate, runtime: runtime.ax) == size,
                      case .success(.some(let hit)) = hitTest(app, point), CFEqual(hit, plate),
                      owned(),
                      let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                      CFEqual(focused, safeFocus),
                      canPostEvents(), ExactTrackNameAdapter.operationPermitted() else {
                    return refuse("The held name field or operation authority changed before editor acquisition.")
                }
                // Prepare first and check authority after all AX reads. Complete
                // a posted Down's paired Up without intervening reads or awaits.
                attempted = true
                guard pair.postDown() else { return refuse("The name-field click was not acknowledged.") }
                guard pair.postUp() else { return refuse("The paired name-field mouse release was not acknowledged.") }
                if count == 1 { mouse.sleepMicros(40_000) }
            }
            var editor: AXUIElement?
            for _ in 0..<10 {
                if let candidate = nameField(),
                   AXHelpers.isAttributeSettable(candidate, kAXValueAttribute as String, runtime: runtime.ax) == true,
                   let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                   CFEqual(focused, candidate) { editor = candidate; break }
                guard owned() else { return refuse("Source custody changed while acquiring its editor.") }
                mouse.sleepMicros(50_000)
            }
            guard let editor else { return refuse("No owned editable name field was observed; no value was written.") }
            func ownsEditor(expectedValue: String) -> Bool {
                guard stopped(), !AXLogicProElements.dialogPresenceReason(runtime: runtime).isBlocked,
                      owned(), nameField().map({ CFEqual($0, editor) }) == true,
                      AXHelpers.isAttributeSettable(editor, kAXValueAttribute as String, runtime: runtime.ax) == true,
                      case .success(.some(let text)) = AXHelpers.getAttributeResult(editor, kAXValueAttribute as String, runtime: runtime.ax)
                        as Result<String?, AXHelpers.AXStatusError>, text.utf8.elementsEqual(expectedValue.utf8),
                      let editorWindow: AXUIElement = AXHelpers.getAttribute(editor, kAXWindowAttribute as String, runtime: runtime.ax),
                      CFEqual(editorWindow, source.window),
                      owned(),
                      let focused: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
                      CFEqual(focused, editor) else { return false }
                return ExactTrackNameAdapter.operationPermitted()
            }
            guard ownsEditor(expectedValue: expected), ExactTrackNameAdapter.operationPermitted() else {
                return refuse("The held editor was not current before the name setter.")
            }
            _ = AXHelpers.setAttribute(editor, kAXValueAttribute as String, desired as CFTypeRef, runtime: runtime.ax)
            guard ownsEditor(expectedValue: desired), canPostEvents(), ExactTrackNameAdapter.operationPermitted() else {
                return refuse("The attempted editor value was not independently readable under the same custody.")
            }
            _ = mouse.postKeyEvent(36)
            // Return ACK is not a commit. The same physical source must expose
            // the desired name outside the editor, twice, without rerebinding.
            for _ in 0..<10 {
                if let current = nameField(), !CFEqual(current, editor),
                   observedName()?.utf8.elementsEqual(desired.utf8) == true,
                   observedName()?.utf8.elementsEqual(desired.utf8) == true,
                   owned(), ExactTrackNameAdapter.operationPermitted() {
                    return .success(HonestContract.encodeStateA(extras: extras.merging([
                        "observed": desired, "verify_source": "ax_same_physical_mixer_name",
                        "reread_required": true
                    ]) { _, new in new }))
                }
                guard owned() else { return refuse("The committed name's physical source became unavailable.") }
                mouse.sleepMicros(50_000)
            }
            return refuse("The committed name was not verified; do not retry or synthesize an inverse.")
        }
    }
}
