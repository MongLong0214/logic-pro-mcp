import ApplicationServices
import Foundation

/// Read-only census of a named plug-in across the Mixer, plus the AX identity
/// each open editor window advertises (#972). Built for hosts that want to find
/// their OWN instances: an AUv3 view sets `kAXIdentifier` on its root
/// (`<prefix><instance-id>`), and this read walks each editor window for it.
///
/// Composes the existing readers only: `getMixerArea` / `stripEnumeration`
/// (ordinal strips, read whole or partial), `audioPluginInsertSlots` (physical
/// slot positions preserved), `trackNames` (arrange headers) and
/// `pluginEditorWindows` (fully classified editors). Nothing here actuates and
/// no `AXUIElement` escapes: the snapshot is value data.
///
/// Three states a caller can tell apart, because they mean different things:
///  * EMPTY: `census` returns a snapshot with no strips and no windows and a
///    `diagnostics.note` saying why (`mixer-not-found`, `no-hosting-strips`, …).
///  * PARTIAL: `stripsReadWhole == false`; strips are listed but the list may
///    miss a hosting strip and ordinals must not be trusted: the Mixer's or a
///    strip's children did not read, a child of the Mixer refused its role
///    read, a read made while classifying a strip's inserts failed, or an
///    occupied insert's name did not read. A failed read is never reported as
///    a strip that hosts nothing.
///  * FAILED: the editor-window enumeration answered an AX error; `census`
///    THROWS `CensusError.windowsReadFailed` carrying the status and whatever
///    strips were read. A failed read is never reported as zero windows.
///
/// Measured on Logic Pro 12.3.1 (6682), en-US, and stated rather than papered
/// over: the editor window's AX title is the TRACK name, so a window is joined
/// to a strip by name and duplicate names are the caller's ambiguity to refuse;
/// Logic labels an occupied insert slot with the AU component name truncated
/// (~10 characters), so slot matching is prefix-tolerant, which makes a strip a
/// CANDIDATE and not an identification: every plug-in whose label shares the
/// name's stem matches. The identity is the window's `kAXIdentifier`; the Mixer strips are
/// reachable through `getMixerArea` when the Mixer is docked in the main window.
public enum AXPluginInstanceIdentity {

    /// One Mixer strip carrying at least one insert whose display name matches.
    /// A candidate, not an identification: see `slotNameMatches`.
    public struct Strip: Sendable, Equatable {
        /// Ordinal in the Mixer's strip enumeration (0-based). Meaningful only
        /// when the snapshot's `stripsReadWhole` is true.
        public let ordinal: Int
        /// The strip's readable name, if any (AXTextField / title metadata).
        public let name: String?
        /// Physical insert positions whose display name matched.
        public let insertSlots: [Int]
    }

    /// One open plug-in editor window and the identity found inside it.
    public struct Window: Sendable, Equatable {
        /// The window's AX title (measured: the track name).
        public let title: String
        /// The first descendant `kAXIdentifier` beginning with the prefix, or nil.
        public let identifier: String?
        /// Whether the walk read every node down to `maxDepth` and found nothing
        /// below it. When false, a nil `identifier` is unknown, not absent: a
        /// node's children did not read, or the window goes deeper than the walk.
        public let identifierReadWhole: Bool
    }

    /// What WAS observed, so an empty snapshot can never be silent about its
    /// cause. Counts and flags only; no names.
    public struct Diagnostics: Sendable, Equatable {
        public let logicPID: Int
        /// The raw `AXWindows` count on the application element, nil when that
        /// read did not succeed.
        public let axWindowCount: Int?
        public let mainWindowFound: Bool
        public let mixerFound: Bool
        /// The app-level windows read answered `kAXErrorCannotComplete` once and
        /// was re-read after 200 ms (the #608 rule: once, and only for that status).
        public let windowsReadRetried: Bool
        /// Why the snapshot is empty when it is: `main-window-nil`,
        /// `mixer-not-found`, `mixer-children-unreadable`, `no-hosting-strips`.
        /// Nil when something was found.
        public let note: String?
    }

    public struct AXSnapshot: Sendable, Equatable {
        public let strips: [Strip]
        /// Whether the strip list was read WHOLE: the Mixer's children and every
        /// strip's children read, every Mixer child read its role, every read
        /// made while classifying inserts succeeded or answered -25205/-25212,
        /// and every occupied insert's name read.
        public let stripsReadWhole: Bool
        public let windows: [Window]
        /// Arrange track headers by 0-based index, when every header read.
        public let trackNames: [Int: String]?
        public let diagnostics: Diagnostics
    }

    public enum CensusError: Error, Sendable, Equatable {
        /// No Logic Pro process; nothing was read.
        case logicNotRunning
        /// `identifierPrefix` was empty, which every identifier begins with;
        /// nothing was read.
        case emptyIdentifierPrefix
        /// The editor-window enumeration answered an AX error. `status` is the
        /// raw `AXError`; `strips` and `stripsReadWhole` are what the Mixer read
        /// returned before the failure, so a caller keeps the half it has.
        case windowsReadFailed(status: Int32, strips: [Strip], stripsReadWhole: Bool,
                               diagnostics: Diagnostics)
    }

    /// Does an insert slot's display name denote `pluginName`? Logic labels an
    /// occupied slot with the Audio Unit's component name TRUNCATED to about ten
    /// characters (measured on 12.3.1: an AU named "SN8KExtension" reads
    /// "SN8KExtens"), so an exact match is wrong in both directions: the label
    /// may be a prefix of the name, or the name a prefix of the label. Both
    /// sides are trimmed and lowercased; a prefix match needs at least 4 characters.
    /// The second direction is what lets a host pass its stem (`SN8K` against
    /// the label `SN8KExtens`, measured), and it is also why a match is only a
    /// candidate: `SN8KOther` matches `SN8K` too, and so does any plug-in whose
    /// whole name is a truncated label's prefix.
    static func slotNameMatches(_ slotName: String?, pluginName wanted: String) -> Bool {
        let a = (slotName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard a.count >= 4, b.count >= 4 else { return a == b && !a.isEmpty }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Enumerate strips hosting `pluginName` and the identity each open editor
    /// window exposes under `identifierPrefix`.
    /// - Parameters:
    ///   - pluginName: the insert display name to match (case-insensitive, trimmed, prefix-tolerant).
    ///   - identifierPrefix: the `kAXIdentifier` prefix the plug-in's view root sets.
    ///   - maxDepth: window walk depth for the identifier search.
    /// - Throws: `CensusError.emptyIdentifierPrefix`; `CensusError.logicNotRunning`;
    ///   `CensusError.windowsReadFailed` when the editor-window read itself failed
    ///   (never surfaced as empty).
    public static func census(
        pluginName: String,
        identifierPrefix: String,
        maxDepth: Int = 12
    ) throws -> AXSnapshot {
        try census(pluginName: pluginName, identifierPrefix: identifierPrefix,
                   maxDepth: maxDepth, runtime: .production)
    }

    /// Runtime-injected variant (the module's test seam; `Runtime` is internal).
    static func census(
        pluginName: String,
        identifierPrefix: String,
        maxDepth: Int,
        runtime: AXLogicProElements.Runtime
    ) throws -> AXSnapshot {
        guard !identifierPrefix.isEmpty else { throw CensusError.emptyIdentifierPrefix }
        guard let pid = runtime.logicProPID() else { throw CensusError.logicNotRunning }
        let appRoot = AXLogicProElements.appRoot(runtime: runtime)

        // #608 measured: the FIRST windows read in a fresh process can answer
        // kAXErrorCannotComplete (-25204), the AX messaging did not go through,
        // and the same read succeeds milliseconds later. A failed read is not an
        // observation: re-read once, only for that status, never a read that
        // succeeded (whatever it said).
        var windowsReadRetried = false
        var axWindowCount: Int?
        if let appRoot {
            var read: Result<[AXUIElement]?, AXHelpers.AXStatusError> =
                AXHelpers.getAttributeResult(appRoot, kAXWindowsAttribute as String, runtime: runtime.ax)
            if case let .failure(error) = read, error.raw == AXError.cannotComplete.rawValue {
                usleep(200_000)
                windowsReadRetried = true
                read = AXHelpers.getAttributeResult(appRoot, kAXWindowsAttribute as String, runtime: runtime.ax)
            }
            if case let .success(windows) = read { axWindowCount = windows?.count }
        }
        let mainWindowFound = AXLogicProElements.mainWindow(runtime: runtime) != nil
        let mixer = AXLogicProElements.getMixerArea(runtime: runtime)

        // Children are read with their status: `getChildren` answers a failed
        // read with [], which would report a Mixer or strip it could not see as
        // one that hosts nothing.
        var strips: [Strip] = []
        var readWhole = false
        var mixerChildrenUnreadable = false
        if let mixer {
            if let children = AXLogicProElements.childrenIfRead(mixer, runtime: runtime.ax) {
                let enumeration = AXLogicProElements.stripEnumeration(children: children, runtime: runtime.ax)
                readWhole = enumeration.unreadableChildren == 0
                let failedSlotReads = FailedReads()
                let slotRuntime = noting(failedSlotReads, over: runtime.ax)
                for (index, strip) in enumeration.strips.enumerated() {
                    guard let stripChildren = AXLogicProElements.childrenIfRead(strip, runtime: runtime.ax) else {
                        readWhole = false
                        continue
                    }
                    let slots = AXLogicProElements.audioPluginInsertSlots(children: stripChildren, runtime: slotRuntime)
                    if failedSlotReads.any || slots.contains(where: { $0.readStatus == .occupiedUnreadable }) {
                        readWhole = false
                    }
                    let hits = slots.filter { slotNameMatches($0.name, pluginName: pluginName) }.map(\.index)
                    guard !hits.isEmpty else { continue }
                    strips.append(Strip(ordinal: index, name: stripName(strip, runtime: runtime.ax), insertSlots: hits))
                }
            } else {
                mixerChildrenUnreadable = true
            }
        }

        func diagnostics(note: String?) -> Diagnostics {
            Diagnostics(logicPID: Int(pid), axWindowCount: axWindowCount,
                        mainWindowFound: mainWindowFound, mixerFound: mixer != nil,
                        windowsReadRetried: windowsReadRetried, note: note)
        }

        let editors: [AXUIElement]
        switch AXLogicProElements.pluginEditorWindows(runtime: runtime) {
        case let .success(found):
            editors = found
        case let .failure(error):
            // FAILED is not EMPTY: the caller gets the status and what was read.
            throw CensusError.windowsReadFailed(status: error.raw, strips: strips,
                                                stripsReadWhole: readWhole,
                                                diagnostics: diagnostics(note: "windows-read-failed"))
        }
        let windows = editors.map { window in
            let found = firstIdentifier(in: window, prefix: identifierPrefix,
                                        maxDepth: maxDepth, runtime: runtime.ax)
            return Window(title: (AXHelpers.getTitle(window, runtime: runtime.ax) ?? "")
                              .trimmingCharacters(in: .whitespacesAndNewlines),
                          identifier: found.identifier, identifierReadWhole: found.readWhole)
        }

        let note: String?
        if !strips.isEmpty || !windows.isEmpty {
            note = nil
        } else if appRoot == nil {
            note = "app-root-nil"
        } else if !mainWindowFound {
            note = "main-window-nil"
        } else if mixer == nil {
            note = "mixer-not-found"
        } else if mixerChildrenUnreadable {
            note = "mixer-children-unreadable"
        } else {
            note = "no-hosting-strips"
        }
        return AXSnapshot(strips: strips, stripsReadWhole: readWhole, windows: windows,
                          trackNames: AXLogicProElements.trackNames(runtime: runtime),
                          diagnostics: diagnostics(note: note))
    }

    /// A strip's readable name: the text field (or, failing that, static text)
    /// whose value is non-empty and is not a numeric level readout. The lookup
    /// is a census, not a first match: every candidate of the role is counted,
    /// and the name is returned only when the name-like readings agree on ONE
    /// string. Two distinct readings are an ambiguity a read-only census must
    /// not settle by tree order, so the strip keeps its ordinal (nil) and the
    /// join stays honest. Measured 12.3.1 docked Mixer: one name field per
    /// strip, the level and pan readouts are numeric static texts.
    static func stripName(_ strip: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        for role in [kAXTextFieldRole as String, kAXStaticTextRole as String] {
            let census = AXHelpers.censusDescendant(of: strip, role: role, maxDepth: 3, runtime: runtime)
            var readings: [String] = []
            for element in census.matches {
                guard let text = AXValueExtractors.extractTextValue(element, runtime: runtime)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, Double(text) == nil, !readings.contains(text) else { continue }
                readings.append(text)
            }
            if readings.count == 1 { return readings[0] }
            if readings.count > 1 { return nil }
        }
        let title = AXHelpers.getTitle(strip, runtime: runtime)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty ?? true) ? nil : title
    }

    /// Depth-first search for the first descendant whose `kAXIdentifier` starts
    /// with `prefix`. Remote (out-of-process) view content is walked like any
    /// other subtree; an AX refusal at any node ends that branch, not the search,
    /// and makes `readWhole` false. So does a node at `maxDepth` that still has
    /// children, because they were not looked at.
    static func firstIdentifier(in root: AXUIElement, prefix: String, maxDepth: Int,
                                runtime: AXHelpers.Runtime) -> (identifier: String?, readWhole: Bool) {
        guard let children = AXLogicProElements.childrenIfRead(root, runtime: runtime) else { return (nil, false) }
        guard maxDepth > 0 else { return (nil, children.isEmpty) }
        var readWhole = true
        for child in children {
            switch AXHelpers.getAttributeResult(child, kAXIdentifierAttribute as String, runtime: runtime) as Result<String?, AXHelpers.AXStatusError> {
            case let .success(id?) where id.hasPrefix(prefix):
                return (id, true)
            case .success:
                break
            case let .failure(error) where error.isDefinitiveAbsence:
                break
            case .failure:
                readWhole = false
            }
            let below = firstIdentifier(in: child, prefix: prefix, maxDepth: maxDepth - 1, runtime: runtime)
            if let id = below.identifier { return (id, true) }
            readWhole = readWhole && below.readWhole
        }
        return (nil, readWhole)
    }

    /// Whether any read made under `noting(_:over:)` failed with a status other
    /// than -25205/-25212.
    private final class FailedReads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var any: Bool {
            lock.lock(); defer { lock.unlock() }
            return count > 0
        }

        func note<T>(_ result: Result<T, AXHelpers.AXStatusError>) -> Result<T, AXHelpers.AXStatusError> {
            if case let .failure(error) = result, !error.isDefinitiveAbsence {
                lock.lock(); count += 1; lock.unlock()
            }
            return result
        }
    }

    /// `base`, answering every attribute and children read from its
    /// status-preserving seam and noting each failure in `failures`. The
    /// insert-slot classifier reads through `getChildren` and `getAttribute`,
    /// which answer a failure the way they answer an absence (#982): an insert
    /// group whose children or role did not read is classified as no slot, and
    /// the strip reads as one hosting nothing. Noting under the classifier lets
    /// the census call that read partial without changing what the classifier
    /// returns to anyone else. In production the status-preserving read is the
    /// same AX call the lossy one makes, so the classifier sees the same answers.
    private static func noting(_ failures: FailedReads, over base: AXHelpers.Runtime) -> AXHelpers.Runtime {
        let attribute: @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError> = { element, name in
            failures.note(AXHelpers.getAttributeResult(element, name, runtime: base))
        }
        let children: @Sendable (AXUIElement) -> Result<[AXUIElement], AXHelpers.AXStatusError> = { element in
            failures.note(AXHelpers.childrenResult(element, runtime: base))
        }
        return AXHelpers.Runtime(
            axApp: base.axApp,
            attributeValue: { element, name in
                if case let .success(value) = attribute(element, name) { return value }
                return nil
            },
            attributeIsSettable: base.attributeIsSettable,
            setAttributeValue: base.setAttributeValue,
            children: { element in
                if case let .success(found) = children(element) { return found }
                return []
            },
            performAction: base.performAction,
            childCount: base.childCount,
            actionNames: base.actionNames,
            actionNamesResult: base.actionNamesResult,
            childrenResult: children,
            attributeValueResult: attribute,
            performActionResult: base.performActionResult
        )
    }
}
