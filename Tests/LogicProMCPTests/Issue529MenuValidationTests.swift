@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private func issue529Position(of fragment: String, in script: String) throws -> String.Index {
    let range = try #require(
        script.range(of: fragment),
        "Generated AppleScript must contain: \(fragment)"
    )
    return range.lowerBound
}

private func issue529Positions(of fragment: String, in script: String) -> [String.Index] {
    var positions: [String.Index] = []
    var searchStart = script.startIndex
    while let range = script.range(of: fragment, range: searchStart..<script.endIndex) {
        positions.append(range.lowerBound)
        searchStart = range.upperBound
    }
    return positions
}

private func issue529TransportSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/LogicProMCP/Channels/AccessibilityChannel+Transport.swift"
        ),
        encoding: .utf8
    )
}

private func issue529SentinelPrefixes(
    capturedBy patterns: [String],
    from source: String
) throws -> Set<String> {
    let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
    var sentinels = Set<String>()
    for pattern in patterns {
        let expression = try NSRegularExpression(pattern: pattern)
        for match in expression.matches(in: source, range: sourceRange) {
            let captureRange = try #require(Range(match.range(at: 1), in: source))
            sentinels.insert(String(source[captureRange]))
        }
    }
    return sentinels
}

/// Reads the actual result-flow `return` literals from the generated script. It intentionally does
/// not carry a second list of sentinels: adding a new script result changes this set automatically.
private func issue529EmittedDialogResultSentinels(from script: String) throws -> Set<String> {
    let resultFlowStart = try #require(script.range(
        of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)"
    ))
    let resultFlow = issue529StrippedOfAppleScriptComments(String(script[resultFlowStart.lowerBound...]))
    return try issue529SentinelPrefixes(
        capturedBy: [#"(?m)\breturn\s+\"([A-Z][A-Z_]+)"#],
        from: resultFlow
    )
}

/// The literal head of every result-flow `return`, i.e. everything up to the first interpolation.
/// The prefix set above stops at the first `[A-Z_]` run, which is the right granularity for
/// comparing two *sets of names* but is not a value the script ever emits: every
/// `DIALOG_INPUT_ISSUED` return carries a second segment (`: SELECT_ALL_ARMED` /
/// `: POSITION_INPUT_ARMED`) that the classifier's `hasPrefix` arms include. Feeding the bare first
/// token to the classifier therefore probes a string production never produces, and it answered
/// `.unexpectedResult` for exactly that reason. Probe with what is emitted.
private func issue529EmittedDialogResultLiterals(from script: String) throws -> Set<String> {
    let resultFlowStart = try #require(script.range(
        of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)"
    ))
    let resultFlow = issue529StrippedOfAppleScriptComments(String(script[resultFlowStart.lowerBound...]))
    return try issue529SentinelPrefixes(
        capturedBy: [#"(?m)\breturn\s+\"([A-Z][A-Z_]+[^\"]*)\""#],
        from: resultFlow
    )
}

/// Reads the classifier's own `switch` arms. The patterns describe Swift's four match syntaxes in
/// this method, while every sentinel value is captured from production code rather than listed here.
private func issue529ClassifierMatchedDialogResultSentinels() throws -> Set<String> {
    let source = try issue529TransportSource()
    let classifierStart = try #require(source.range(
        of: "static func classifyGotoPositionDialogResult("
    ))
    let afterClassifier = source[classifierStart.lowerBound...]
    let classifierEnd = try #require(afterClassifier.range(
        of: "\n    private enum GotoPositionDialogRouteResult"
    ))
    let classifier = String(afterClassifier[..<classifierEnd.lowerBound])
    return try issue529SentinelPrefixes(
        capturedBy: [
            #"(?m)^\s*case\s+\"([A-Z][A-Z_]+)"#,
            #"(?m)^\s*case\s+let\s+value\s+where\s+value\.hasPrefix\(\"([A-Z][A-Z_]+)"#,
            #"(?m)^\s*case\s+let\s+value\s+where\s+value\s*==\s*\"([A-Z][A-Z_]+)"#,
            #"(?m)^\s*\|\|\s*value\.hasPrefix\(\"([A-Z][A-Z_]+)"#,
        ],
        from: classifier
    )
}

/// AppleScript accepts both classic carriage-return and Unix line-feed source. Treat a line
/// comment as ending at a line terminator, not at one chosen encoding of it.
private func issue529IsAppleScriptLineTerminator(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy(CharacterSet.newlines.contains)
}

/// Neutralises AppleScript `--`, `#`, and `(* ... *)` comments before a positional or structural
/// assertion runs against generated script text. #921 follow-up (RV-6): a statement inside any
/// stripped comment form must not satisfy a source-shape assertion. Newlines are preserved so the
/// structural helpers below still reason in terms of the original statement lines.
private func issue529StrippedOfAppleScriptComments(_ script: String) -> String {
    var stripped = ""
    var index = script.startIndex
    var blockCommentDepth = 0
    var inLineComment = false
    var inString = false

    while index < script.endIndex {
        let character = script[index]
        let nextIndex = script.index(after: index)
        let nextCharacter: Character? = nextIndex < script.endIndex ? script[nextIndex] : nil

        if blockCommentDepth > 0 {
            if character == "(", nextCharacter == "*" {
                stripped.append(" ")
                stripped.append(" ")
                blockCommentDepth += 1
                index = script.index(after: nextIndex)
            } else if character == "*", nextCharacter == ")" {
                stripped.append(" ")
                stripped.append(" ")
                blockCommentDepth -= 1
                index = script.index(after: nextIndex)
            } else {
                stripped.append(issue529IsAppleScriptLineTerminator(character) ? character : " ")
                index = nextIndex
            }
            continue
        }

        if inLineComment {
            stripped.append(issue529IsAppleScriptLineTerminator(character) ? character : " ")
            if issue529IsAppleScriptLineTerminator(character) { inLineComment = false }
            index = nextIndex
            continue
        }

        if inString {
            stripped.append(character)
            if character == "\\", let nextCharacter {
                stripped.append(nextCharacter)
                index = script.index(after: nextIndex)
            } else {
                if character == "\"" { inString = false }
                index = nextIndex
            }
            continue
        }

        if character == "\"" {
            stripped.append(character)
            inString = true
        } else if character == "-", nextCharacter == "-" {
            stripped.append(" ")
            stripped.append(" ")
            inLineComment = true
            index = script.index(after: nextIndex)
            continue
        } else if character == "#" {
            stripped.append(" ")
            inLineComment = true
            index = nextIndex
            continue
        } else if character == "(", nextCharacter == "*" {
            stripped.append(" ")
            stripped.append(" ")
            blockCommentDepth = 1
            index = script.index(after: nextIndex)
            continue
        } else {
            stripped.append(character)
        }
        index = nextIndex
    }
    return stripped
}

/// Structurally locates the `end if` that closes the `if` beginning at `ifStart` (which must point
/// at the first character of an `if ... then` line), by depth-counting AppleScript `if`/`end if`
/// lines between them. A one-line `if X then Y` never opens a block that needs an `end if`, so only
/// a line ending in exactly `then` counts as an opener; `else if X then` starts with `else`, not
/// `if `, so it does not open a new level — there is exactly one `end if` per `if`/`else if`/`else`
/// chain. #921 follow-up (RV-4): textual ordering alone cannot distinguish "nested inside this
/// `if`" from "runs after its `end if`" — closing the branch early and moving its body into a new
/// unconditional block preserves every `position < position` comparison that ignores nesting.
private func issue529MatchingEndIf(after ifStart: String.Index, in script: String) -> String.Index? {
    var index = ifStart
    var depth = 0
    while index < script.endIndex {
        let lineEnd = script[index...].firstIndex(of: "\n") ?? script.endIndex
        let trimmedLine = script[index..<lineEnd].trimmingCharacters(in: .whitespaces)
        if trimmedLine.hasPrefix("if ") && trimmedLine.hasSuffix("then") {
            depth += 1
        } else if trimmedLine == "end if" {
            depth -= 1
            if depth == 0 { return index }
        }
        guard lineEnd < script.endIndex else { break }
        index = script.index(after: lineEnd)
    }
    return nil
}

/// The `try...end try` counterpart to `issue529MatchingEndIf`. The revalidation read must set its
/// success flag inside its own `try`, not merely later in the enclosing `if revalidated` block: an
/// AppleScript assignment that throws leaves its old value in place while execution continues after
/// `end try`.
private func issue529MatchingEndTry(after tryStart: String.Index, in script: String) -> String.Index? {
    var index = tryStart
    var depth = 0
    while index < script.endIndex {
        let lineEnd = script[index...].firstIndex(of: "\n") ?? script.endIndex
        let trimmedLine = script[index..<lineEnd].trimmingCharacters(in: .whitespaces)
        if trimmedLine == "try" {
            depth += 1
        } else if trimmedLine == "end try" {
            depth -= 1
            if depth == 0 { return index }
        }
        guard lineEnd < script.endIndex else { break }
        index = script.index(after: lineEnd)
    }
    return nil
}

/// Returns every active multiline `if`, `repeat`, and `try` block enclosing `position`, from
/// outermost to innermost. Callers pass comment-neutralised script, so a statement inside a
/// stripped AppleScript `--`, `#`, or `(* ... *)` comment cannot acquire a plausible enclosing
/// chain merely by being present in the source.
private func issue529EnclosingAppleScriptBlocks(
    at position: String.Index,
    in script: String
) -> [String]? {
    let positionLineStart = script[..<position].lastIndex(of: "\n")
        .map { script.index(after: $0) } ?? script.startIndex
    var blocks: [String] = []
    var lineStart = script.startIndex

    while lineStart < positionLineStart {
        let lineEnd = script[lineStart...].firstIndex(of: "\n") ?? script.endIndex
        let line = script[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)

        if line.hasPrefix("if ") && line.hasSuffix("then") {
            blocks.append(line)
        } else if line == "try" {
            blocks.append(line)
        } else if line.hasPrefix("repeat ") {
            blocks.append(line)
        } else if line == "end if" {
            guard blocks.last?.hasPrefix("if ") == true else { return nil }
            blocks.removeLast()
        } else if line == "end try" {
            guard blocks.last == "try" else { return nil }
            blocks.removeLast()
        } else if line == "end repeat" {
            guard blocks.last?.hasPrefix("repeat ") == true else { return nil }
            blocks.removeLast()
        }

        guard lineEnd < script.endIndex else { break }
        lineStart = script.index(after: lineEnd)
    }
    return blocks
}

private func issue529NextActiveAppleScriptStatement(
    afterLineStartingAt lineStart: String.Index,
    in script: String
) -> String.Index? {
    var start = script[lineStart...].firstIndex(where: issue529IsAppleScriptLineTerminator)
        .map { script.index(after: $0) } ?? script.endIndex

    while start < script.endIndex {
        while start < script.endIndex, issue529IsAppleScriptLineTerminator(script[start]) {
            start = script.index(after: start)
        }
        guard start < script.endIndex else { return nil }
        let lineEnd = script[start...].firstIndex(where: issue529IsAppleScriptLineTerminator)
            ?? script.endIndex
        if let statementStart = script[start..<lineEnd].firstIndex(where: { !$0.isWhitespace }) {
            return statementStart
        }
        start = lineEnd < script.endIndex ? script.index(after: lineEnd) : script.endIndex
    }
    return nil
}

/// The reconciliation handler has one direct fallthrough spine: handler entry enters its `try`,
/// then the snapshot guard, unknown-dialog observation, and menu loop. The guards may refuse their
/// own unsafe outcomes, but no unscoped statement may divert a path that falls through them.
private func issue529ReconciliationFallthroughReachesMenuLoop(
    in script: String,
    handlerEntry: String.Index,
    tryStart: String.Index,
    snapshotGuardStart: String.Index,
    snapshotGuardEnd: String.Index,
    unknownDialogGuardStart: String.Index,
    unknownDialogGuardEnd: String.Index,
    menuLoopStart: String.Index
) -> Bool {
    issue529NextActiveAppleScriptStatement(afterLineStartingAt: handlerEntry, in: script)
        == tryStart
        && issue529NextActiveAppleScriptStatement(afterLineStartingAt: tryStart, in: script)
        == snapshotGuardStart
        && issue529NextActiveAppleScriptStatement(afterLineStartingAt: snapshotGuardEnd, in: script)
        == unknownDialogGuardStart
        && issue529NextActiveAppleScriptStatement(afterLineStartingAt: unknownDialogGuardEnd, in: script)
        == menuLoopStart
}

private func issue529LedgerPath(from script: String, stage: String) throws -> String {
    let prefix = "recordDialogIssuance(\"\(stage)\", \""
    let start = try #require(script.range(of: prefix))
    let tail = script[start.upperBound...]
    let end = try #require(tail.firstIndex(of: "\""))
    return String(tail[..<end])
}

/// The snapshot path READ OUT OF THE SCRIPT, not derived from the ledger path.
///
/// This test file used to build it as `ledgerPath + ".preleaf-windows"`, which was a second copy
/// of the product's layout — and it broke the moment the ledger moved into a directory of its own
/// (it now costs one recursive delete instead of enumerating the user temporary directory). The
/// script carries both paths; taking the one it carries is the only version that cannot drift.
private func issue529SnapshotPath(from script: String) throws -> String {
    let prefix = "recordPreLeafGoToPositionWindowSnapshot(preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount, \""
    let start = try #require(script.range(of: prefix))
    let tail = script[start.upperBound...]
    let end = try #require(tail.firstIndex(of: "\""))
    return String(tail[..<end])
}

private final class Issue529Counter: @unchecked Sendable {
    private(set) var value = 0

    func bump() {
        value += 1
    }
}

private final class Issue529StringBox: @unchecked Sendable {
    private(set) var value: String?

    func set(_ value: String) {
        self.value = value
    }
}

/// Bridges the real AX Go To Position route into ChannelRouter while retaining the script-result
/// seam. This lets the adversarial fixtures prove both that their script response was consumed and
/// that the router did not release CGEvent's `/` + position + Return sequence.
private actor Issue529DialogFixtureChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private let scriptResult: String
    private let scriptExecutions: Issue529Counter
    private let sliderWrites: Issue529Counter

    init(
        scriptResult: String,
        scriptExecutions: Issue529Counter,
        sliderWrites: Issue529Counter
    ) {
        self.scriptResult = scriptResult
        self.scriptExecutions = scriptExecutions
        self.sliderWrites = sliderWrites
    }

    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "dialog fixture") }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        let scriptResult = scriptResult
        let scriptExecutions = scriptExecutions
        return await AccessibilityChannel.gotoPositionViaBarSlider(
            params: params,
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                scriptExecutions.bump()
                return .success(#"{"result":"\#(scriptResult)"}"#)
            }
        )
    }
}

private actor Issue529DialogLockGate {
    private var started = false
    private var finishedWithoutEntering = false
    private var startWaiter: CheckedContinuation<Bool, Never>?
    private var releaseRequested = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func entered() {
        started = true
        startWaiter?.resume(returning: true)
        startWaiter = nil
    }

    /// A first call refused before its script never calls `entered()`, so a waiter that listened only
    /// for that would wait forever (#994). The call's return wakes the waiter instead.
    func finished() {
        guard !started else { return }
        finishedWithoutEntering = true
        startWaiter?.resume(returning: false)
        startWaiter = nil
    }

    /// True once the first call is inside its script; false if it returned without getting there.
    func waitUntilEnteredOrFinished() async -> Bool {
        if started { return true }
        if finishedWithoutEntering { return false }
        return await withCheckedContinuation { startWaiter = $0 }
    }

    func waitForRelease() async {
        guard !releaseRequested else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        releaseRequested = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private func issue529SliderRuntime(
    sliderWrites: Issue529Counter,
    includeBeatSlider: Bool = false,
    executeAppleScript: @escaping @Sendable (String) async -> ChannelResult = { _ in
        .success(#"{"result":"MENU_NOT_FOUND"}"#)
    }
) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(5290)
    let window = builder.element(5291)
    let controlBar = builder.element(5292)
    let barSlider = builder.element(5293)
    let beatSlider = builder.element(5294)
    let playheadPosition = builder.element(5295)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [playheadPosition])
    builder.setAttribute(playheadPosition, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(playheadPosition, kAXDescriptionAttribute as String, "Playhead Position")
    builder.setChildren(playheadPosition, includeBeatSlider ? [barSlider, beatSlider] : [barSlider])
    builder.setAttribute(barSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(barSlider, kAXDescriptionAttribute as String, "Bar")
    builder.setAttribute(barSlider, kAXValueAttribute as String, NSNumber(value: 1))
    if includeBeatSlider {
        builder.setAttribute(beatSlider, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(beatSlider, kAXDescriptionAttribute as String, "Beat")
        builder.setAttribute(beatSlider, kAXValueAttribute as String, NSNumber(value: 1))
    }

    return builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { element, attribute, value in
            if (element == barSlider || element == beatSlider), attribute == kAXValueAttribute as String {
                sliderWrites.bump()
            }
            builder.setAttribute(element, attribute, value)
            return true
        },
        performActionHandler: { _, _ in true },
        executeAppleScript: executeAppleScript
    )
}

private func issue529Envelope(_ result: ChannelResult) -> [String: Any]? {
    let payload: String
    switch result {
    case let .success(text), let .error(text):
        payload = text
    }
    guard let data = payload.data(using: .utf8),
          let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return envelope
}

private func issue529PreexistingDialogRuntime(
    reconciliationCalls: Issue529Counter,
    capturedScript: Issue529StringBox? = nil
) -> (builder: FakeAXRuntimeBuilder, runtime: AXLogicProElements.Runtime, cancel: AXUIElement) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(52_901)
    let projectWindow = builder.element(52_902)
    let dialogWindow = builder.element(52_903)
    let cancel = builder.element(52_904)

    builder.setAttribute(app, kAXMainWindowAttribute as String, projectWindow)
    builder.setAttribute(app, kAXWindowsAttribute as String, [projectWindow, dialogWindow])
    builder.setAttribute(projectWindow, kAXModalAttribute as String, false)
    builder.setAttribute(dialogWindow, kAXTitleAttribute as String, "Go To Position")
    builder.setAttribute(dialogWindow, kAXSubroleAttribute as String, kAXFloatingWindowSubrole as String)
    builder.setAttribute(dialogWindow, kAXModalAttribute as String, true)
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setChildren(dialogWindow, [cancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: nil,
        executeAppleScript: { script in
            capturedScript?.set(script)
            reconciliationCalls.bump()
            return .success(#"{"result":"CLOSED"}"#)
        }
    )
    return (builder, runtime, cancel)
}

@Suite("Issue #529 — Go To Position menu validation")
struct Issue529MenuValidationTests {
    @Test("locale is decided by non-actuating reads before one resolved leaf is issued")
    func localeIsDecidedBeforeSingleResolvedLeafIsIssued() throws {
        // Mutation this rejects: restore either intermediate menu-bar/submenu click, or replace
        // either full leaf path with an object selected by a prior click. Both let a menu-bar click
        // block the script before the Go To Position dialog can open.
        //
        // #519: the bar/item/leaf names are each resolved from an AXLocalePolicy LabelSet
        // (canonical first, then variants) instead of a hard-coded EN/KO literal branch pair, so
        // the three read-only candidate loops below (bar, then "Go To", then "Position…") replace
        // the old koreanDecision/englishDecision two-branch check.
        //
        // #921: locale discovery is still entirely read-only, but the leaf click is no longer the
        // ONLY click in this script. A disabled `enabled` read can be a stale closed-menu cache, so
        // the disabled branch (which only runs after `enabledRead`) forces exactly one bounded
        // menu-bar click to revalidate before trusting it, and closes what it opens before the leaf
        // is ever reached. The invariant below is narrower, not gone: nothing before the enabled
        // read opens a menu, and this script contains exactly that one menu-bar click.
        // #921 follow-up (RV-4): stripped of comment lines before any positional/count assertion —
        // see issue529StrippedOfAppleScriptComments for why an un-stripped script let a commented-
        // out click keep passing this test's own count check below.
        let script = issue529StrippedOfAppleScriptComments(
            AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        )
        // Candidate lists are derived from the LabelSets rather than spelled out: a measured label
        // added to AXLocalePolicy must not break an ordering test that is about ordering.
        func candidateList(_ set: AXLocalePolicy.LabelSet) -> String {
            "repeat with candidate in {" + set.labels.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        }
        let barResolution = try issue529Position(
            of: candidateList(AXLocalePolicy.navigateMenuBar),
            in: script
        )
        let itemResolution = try issue529Position(
            of: candidateList(AXLocalePolicy.goToMenuItem),
            in: script
        )
        let leafResolution = try issue529Position(
            of: candidateList(AXLocalePolicy.goToPositionMenuItem),
            in: script
        )
        let enabledRead = try issue529Position(
            of: "set menuItemEnabled to enabled of menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )

        #expect(barResolution < itemResolution)
        #expect(itemResolution < leafResolution)
        #expect(leafResolution < enabledRead)
        #expect(enabledRead < leafClick)
        #expect(!String(script[..<enabledRead]).contains("click menu bar item"),
                "locale discovery and the enabled read must stay read-only")
        #expect(issue529Positions(of: "click menu bar item", in: script).count == 1,
                "#921 adds exactly one bounded revalidation click; a second would risk a menu wedge")
        #expect(!script.contains("selectedMenuBarItem"))
        #expect(!script.contains("selectedSubmenuItem"))
        #expect(!script.contains("menuItemOpenedAfterClick"))
    }

    @Test("the reviewed Japanese Go To Position title is an exact operable dialog title")
    func japaneseGoToPositionTitleIsCoveredInBothDialogObservers() throws {
        // Mutation this rejects: remove `dialogTitle is "位置の移動"` from either title predicate.
        // This issue covers the exact JA modal title plus its existing キャンセル dismissal path;
        // it does not claim Japanese Navigate-menu routing or a general locale policy (#519).
        let writeScript = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/LogicProMCPTests/Issue529MenuValidationTests.swift",
                with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Transport.swift"
            ),
            encoding: .utf8
        )
        // The two observers used to be held to agreement by COUNTING this predicate twice in the
        // source. They agree structurally now: both render the same handler from
        // `AXLocalePolicy.goToPositionDialogTitle`, which is what #876 changed after adding a German
        // title to that LabelSet and watching the route go on refusing — the decision lived in these
        // literals, not in the policy. So the source must carry NO hand-written copy of the
        // predicate, and the generated handler must carry every title the LabelSet declares. That is
        // strictly stronger than the count: a second literal list cannot come back, and a title
        // dropped from the policy fails here instead of silently narrowing the route.
        let titlePredicateOccurrences = issue529Positions(
            of: "dialogTitle is \"位置の移動\"", in: source
        )
        let handler = AccessibilityChannel.goToPositionDialogTitleHandlerAppleScript()

        #expect(writeScript.contains("dialogTitle is \"位置の移動\""))
        // Was `writeScript.contains("button \"キャンセル\"")`, one literal out of the three this path
        // used to carry. The cancel candidates are rendered from the LabelSet now, so the check is
        // the same shape as the title loop below: EVERY spelling has to reach the script, which is
        // what makes a language added to the policy reach this modal.
        for cancel in AXLocalePolicy.cancelButton.labels {
            #expect(writeScript.contains("\"\(cancel)\""),
                    "the rendered script drops \(cancel), so a Logic in that language finds no Cancel")
        }
        #expect(titlePredicateOccurrences.count == 0,
                "the title predicate must be rendered from the LabelSet, never written into the source")
        for title in AXLocalePolicy.goToPositionDialogTitle.labels {
            #expect(handler.contains("dialogTitle is \"\(title)\""),
                    "the rendered handler drops \(title), so the route would not recognise that dialog")
        }
    }

    @Test("the dialog-ready poll remains the authority after the resolved leaf click")
    func resolvedLeafClickIsFollowedByDialogReadyPoll() throws {
        // Mutation this rejects: remove the bounded exact-dialog poll, or put dialog input before
        // it. The leaf can issue successfully while Logic has not rendered the modal yet.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let readyPoll = try issue529Position(
            of: "repeat 30 times",
            in: script
        )
        let input = try issue529Position(
            of: "keystroke \"529.1.1.1\"",
            in: script
        )

        #expect(leafClick < readyPoll)
        #expect(readyPoll < input)
    }

    @Test("entry cleanup runs before locale discovery or menu actuation")
    func entryTimeCleanupPrecedesMenuWork() throws {
        // Mutation this rejects: move entry cleanup below either locale resolution or the resolved
        // leaf click, allowing a stale menu to leak into this request's only menu actuation.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryCleanup = try issue529Position(
            of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)",
            in: script
        )
        let firstOperationalDelay = try issue529Position(of: "delay 0.2", in: script)
        let localeDecision = try issue529Position(
            of: "repeat with candidate in {"
                + AXLocalePolicy.navigateMenuBar.labels.map { "\"\($0)\"" }.joined(separator: ", ")
                + "}",
            in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )

        #expect(entryCleanup < firstOperationalDelay)
        #expect(entryCleanup < localeDecision)
        #expect(entryCleanup < leafClick)
    }

    @Test("entry refuses an unreadable menu bar before any transport actuation")
    func entryCleanupRefusesAnUnreadableMenuBar() throws {
        // Mutation this rejects: restore the `OPEN || OPEN_UNREADABLE` guard, which treats an
        // unreadable entry read as safe enough to start the menu/slider route.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let entryGuard = try issue529Position(
            of: "if entryMenuCleanup is not \"CLOSED\" then",
            in: script
        )
        let localeDecision = try issue529Position(
            of: "repeat with candidate in {"
                + AXLocalePolicy.navigateMenuBar.labels.map { "\"\($0)\"" }.joined(separator: ", ")
                + "}",
            in: script
        )

        #expect(entryGuard < localeDecision)
        #expect(script.contains("if menuState is \"UNREADABLE\" and not knownOpen then return \"UNREADABLE\""))
    }

    /// Script fixture: the entry menu read is unreadable. Because this run has not opened a menu,
    /// it must refuse without manufacturing an Escape into an unknown focus target.
    @Test("unreadable entry state refuses without Escape")
    func entryCleanupRefusesUnreadableAfterObservedOpen() async throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let dismissalStart = try issue529Position(of: "on dismissOpenMenu(theProcess, knownOpen)", in: script)
        let dismissalEnd = try issue529Position(of: "end dismissOpenMenu", in: script)
        let dismissal = String(script[dismissalStart..<dismissalEnd])
        let unreadableGuard = try issue529Position(
            of: "if menuState is \"UNREADABLE\" and not knownOpen then return \"UNREADABLE\"",
            in: dismissal
        )
        let escape = try issue529Position(of: "key code 53", in: dismissal)
        #expect(unreadableGuard < escape)

        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_PICK_FAILED: menu state was not observed closed at entry (UNREADABLE)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(sliderWrites.value == 0)
    }

    @Test("declared menu-cleanup refusal sites correspond exactly to the generated script")
    func declaredMenuCleanupRefusalSitesCorrespondToTheGeneratedScript() throws {
        let generatedScript = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let script = issue529StrippedOfAppleScriptComments(generatedScript)
        let sites = AccessibilityChannel.menuCleanupRefusalSites
        let entryCleanup = try issue529Position(
            of: "set entryMenuCleanup to my dismissOpenMenu(logicProcess, false)",
            in: script
        )
        let entryRefusal = try issue529Position(
            of: "return \"MENU_PICK_FAILED: menu state was not observed closed at entry",
            in: script
        )
        let escape = try issue529Position(of: "key code 53", in: script)
        let menuStateObservations = issue529Positions(
            of: "set menuState to my menuOpenState(theProcess)",
            in: script
        )
        let refusalPrefixOccurrences = issue529Positions(
            of: AccessibilityChannel.MenuCleanupRefusalSite.refusalPrefix,
            in: script
        )

        #expect(sites.count == 4, "the declared registry has one value for each refusal site")
        #expect(Set(sites.map(\.identifier)).count == sites.count,
                "each declared menu-cleanup refusal site needs a distinct identifier")
        #expect(refusalPrefixOccurrences.count == sites.count,
                "the generated script may not contain an undeclared menu-cleanup refusal")
        #expect(entryCleanup < entryRefusal)
        #expect(menuStateObservations.contains { escape < $0 })
        // r-941round7 recorded that passing `.provablyPreLeaf` (now `.menuOnly`) to the reconciler is correct ONLY
        // while every such refusal precedes the leaf click, and that the suite catches a fifth site
        // added after the click POSITIONALLY. Round 9 replaced the positional pair with a count, so
        // the only remaining check on `emittedBeforeLeafClick` was the flag asserting itself: move
        // an interpolation after the leaf click, leave its Boolean true, and the count, the
        // containment and the flag are all still satisfied. Measure the position instead.
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 "
                + "of menu bar item barName of menu bar 1",
            in: generatedScript
        )
        for site in sites {
            #expect(site.emittedBeforeLeafClick,
                    "the declared menu-cleanup refusal site \(site.identifier) must be pre-leaf")
            #expect(generatedScript.contains(site.appleScript),
                    "the generated script must include the refusal text declared by \(site.identifier)")
            let marker = try issue529Position(
                of: "-- MENU_CLEANUP_REFUSAL_SITE: \(site.identifier)", in: generatedScript
            )
            // Written as `site.emittedBeforeLeafClick == (marker < leafClick)` this proved
            // nothing: a top-level `Bool == Bool` inside `#expect` passes unconditionally on
            // this toolchain, which is the hazard this file already records below. Measured:
            // with the comparison inverted to `marker > leafClick`, so every site compares
            // `true == false`, the filtered suite still exited 0 with 56 passed. The flag is
            // already pinned to `true` by the expectation above, so the position is asserted
            // on its own and both halves can now fail.
            #expect(marker < leafClick,
                    """
                    \(site.identifier) declares emittedBeforeLeafClick=\
                    \(site.emittedBeforeLeafClick) but the generated script places it \
                    after the leaf click
                    """)
        }
    }

    /// #921. The forced revalidation click must be reachable ONLY when the entry read already
    /// said the leaf was disabled — otherwise every ordinary enabled leaf would pick up an extra
    /// menu click before the real leaf actuation, changing the success path this issue was never
    /// about. Confirms the click, both sentinels, and the disabled-branch `end if` are nested
    /// inside `if not menuItemEnabled then`, and that the statement immediately after that `end if`
    /// is the SAME comment the pre-#921 script reached in the enabled case.
    @Test("the forced revalidation pass only runs inside the already-disabled branch")
    func forcedRevalidationStaysInsideTheDisabledBranchOnly() throws {
        // Mutation this rejects: move the `click menu bar item barName of menu bar 1` revalidation
        // above `if not menuItemEnabled then`, which would open a menu on every enabled leaf too.
        //
        // #921 follow-up (RV-6): comments are neutralised before any statement is found, and each
        // revalidation statement's exact active `if`/`try` chain is asserted below. Presence,
        // ordering, and a matching disabled-branch `end if` alone all let an added false guard make
        // the pass unreachable; an added `if true` is also rejected because this is an exact
        // reachability contract, not a claim that today's condition happens to evaluate true.
        let script = issue529StrippedOfAppleScriptComments(
            AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 921)
        )
        let disabledBranchStart = try issue529Position(of: "if not menuItemEnabled then", in: script)
        let disabledBranchEnd = try #require(
            issue529MatchingEndIf(after: disabledBranchStart, in: script),
            "the `if not menuItemEnabled then` branch must close with a structurally matching end if"
        )
        let revalidationClick = try issue529Position(
            of: "click menu bar item barName of menu bar 1", in: script
        )
        let revalidationSelectedRead = try issue529Position(
            of: "if selected of menu bar item barName of menu bar 1 then set revalidated to true",
            in: script
        )
        let revalidationTryStart = try #require(
            script.range(
                of: "try",
                options: .backwards,
                range: disabledBranchStart..<revalidationClick
            )?.lowerBound,
            "the revalidation click must remain inside its AppleScript try"
        )
        let revalidationTryEnd = try #require(
            issue529MatchingEndTry(after: revalidationTryStart, in: script),
            "the revalidation click's try must have a structurally matching end try"
        )
        let revalidationTry = String(script[revalidationTryStart..<revalidationTryEnd])
        let revalidationAttemptMarker = try #require(
            script.range(
                of: "set menuActuationAttempted to true",
                range: revalidationTryStart..<revalidationTryEnd
            )?.lowerBound,
            "the revalidation try must mark its menu actuation attempt"
        )
        let revalidationCleanup = try issue529Position(
            of: "set cleanupState to my dismissOpenMenu(logicProcess, revalidated)", in: script
        )
        let revalidationReread = try #require(
            issue529Positions(
                of: "set menuItemEnabled to enabled of menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
                in: script
            ).last,
            "the forced pass must re-read the leaf while its menu is open"
        )
        let freshReadingSet = try issue529Position(of: "set freshReadingTaken to true", in: script)
        let stillDisabledReturn = try issue529Position(of: "return \"MENU_DISABLED\"", in: script)
        let unreadableReturn = try issue529Position(of: "return \"MENU_VALIDATION_UNREADABLE:", in: script)
        // The first non-comment statement after the disabled branch's `end if` in the unmodified
        // (pre-#921) script — unchanged position proves the enabled path still falls through to
        // exactly what it always did. (Its own former anchor was a comment line, blanked above.)
        let nextStatementAfterBranch = try issue529Position(
            of: "set observedGoToPositionDialog to missing value",
            in: script
        )

        #expect(disabledBranchStart < revalidationClick)
        // The marker must be in the SAME try and before its click. AX can perform the click and
        // then throw, so moving it after the click (or deleting it) would make unreadable cleanup
        // act as if no menu could have opened.
        #expect(revalidationTryStart < revalidationAttemptMarker)
        #expect(revalidationAttemptMarker < revalidationClick)
        #expect(revalidationClick < revalidationTryEnd)
        #expect(issue529Positions(of: "set menuActuationAttempted to true", in: revalidationTry).count == 1)
        #expect(revalidationClick < revalidationCleanup)
        #expect(revalidationCleanup < stillDisabledReturn)
        #expect(revalidationCleanup < unreadableReturn)
        // Nesting, not just ordering: the click and both sentinels must lie strictly inside the
        // branch's OWN end if, not merely after its opening `if`.
        #expect(revalidationClick < disabledBranchEnd)
        #expect(stillDisabledReturn < disabledBranchEnd)
        #expect(unreadableReturn < disabledBranchEnd)
        #expect(disabledBranchEnd < nextStatementAfterBranch)
        // Exact active block chains make the statements reachable: no false/true wrapper, loop, or
        // extra try may sit between this disabled branch and the revalidation pass.
        let disabledThenTry = ["if not menuItemEnabled then", "try"]
        let disabledThenValidatedThenTry = ["if not menuItemEnabled then", "if revalidated then", "try"]
        let disabledOnly = ["if not menuItemEnabled then"]
        #expect(try #require(issue529EnclosingAppleScriptBlocks(at: revalidationAttemptMarker, in: script)) == disabledThenTry)
        #expect(try #require(issue529EnclosingAppleScriptBlocks(at: revalidationClick, in: script)) == disabledThenTry)
        #expect(try #require(issue529EnclosingAppleScriptBlocks(at: revalidationSelectedRead, in: script)) == disabledThenTry)
        #expect(try #require(issue529EnclosingAppleScriptBlocks(at: revalidationReread, in: script)) == disabledThenValidatedThenTry)
        #expect(try #require(issue529EnclosingAppleScriptBlocks(at: freshReadingSet, in: script)) == disabledThenValidatedThenTry)
        #expect(try #require(issue529EnclosingAppleScriptBlocks(at: revalidationCleanup, in: script)) == disabledOnly)
    }

    @Test("a swallowed re-read error refuses as unreadable, not as a fresh disabled reading")
    func swallowedRevalidationRereadRefusesAsUnreadableNotDisabled() throws {
        // #921 follow-up (RV-2): AppleScript's `try...end try` with no `on error` handler leaves an
        // assigned variable at its PRIOR value when the assignment throws. `menuItemEnabled` starts
        // this branch at its original stale `false` (that is why the branch runs at all), so a
        // swallowed re-read error left it sitting at that same `false` -- and the branch reported
        // MENU_DISABLED for a reading it never actually took. `freshReadingTaken` is a SEPARATE flag,
        // set true only inside the re-read's own successful try body, so it cannot inherit the stale
        // value the way `menuItemEnabled` itself does.
        //
        // Mutation this rejects: gate the MENU_DISABLED/MENU_VALIDATION_UNREADABLE branch on
        // `revalidated` alone (the pre-fix shape), which cannot tell "the menu opened but the re-read
        // failed" from "the menu opened and the re-read said disabled".
        let script = issue529StrippedOfAppleScriptComments(
            AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 921)
        )
        let freshReadingInit = try issue529Position(of: "set freshReadingTaken to false", in: script)
        let rereadPositions = issue529Positions(
            of: "set menuItemEnabled to enabled of menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        #expect(rereadPositions.count == 2)
        let revalidationReread = try #require(rereadPositions.last)
        let rereadTryStart = try #require(
            script.range(
                of: "try",
                options: .backwards,
                range: script.startIndex..<revalidationReread
            )?.lowerBound,
            "the re-read must remain inside an AppleScript try block"
        )
        let rereadTryEnd = try #require(
            issue529MatchingEndTry(after: rereadTryStart, in: script),
            "the fresh enabled read must have a structurally matching end try"
        )
        let freshReadingSet = try issue529Position(of: "set freshReadingTaken to true", in: script)
        let disabledDecision = try issue529Position(
            of: "if freshReadingTaken and menuItemEnabled then", in: script
        )
        let stillDisabledReturn = try issue529Position(of: "return \"MENU_DISABLED\"", in: script)
        let unreadableReturn = try issue529Position(of: "return \"MENU_VALIDATION_UNREADABLE:", in: script)

        #expect(freshReadingInit < revalidationReread)
        #expect(revalidationReread < freshReadingSet)
        #expect(freshReadingSet < rereadTryEnd,
                "the success flag must stay inside the re-read's try, not after a swallowed error")
        #expect(freshReadingSet < disabledDecision)
        #expect(disabledDecision < stillDisabledReturn)
        #expect(disabledDecision < unreadableReturn)
        #expect(script.contains("else if freshReadingTaken then"))
        #expect(!script.contains("else if revalidated then"),
                "the decision must key off whether a reading was TAKEN, not merely whether the menu opened")
    }

    @Test("reconciliation has a direct fallthrough path from entry to its menu loop")
    func reconciliationEntryFallsThroughToTheMenuLoop() async throws {
        // #921 follow-up (RV-1): the forced revalidation pass opens Logic's own top-level menu
        // before the pre-leaf snapshot is ever written. The disabled branch ends first; the snapshot
        // is persisted later, after the dialog and total-window observations. Thus a timeout anywhere
        // from revalidation through those observations reaches reconciliation without a snapshot and
        // must retain its menu-recovery fallthrough after the required dialog observation. That loop
        // follows this route's deliberate fresh-observation policy, not an ownership guarantee: a
        // user could open a menu after the child dies and before reconciliation, yet another position
        // actuation remains blocked until the observed menu is closed.
        //
        // Mutation this rejects: insert a return (or any other direct statement) at handler entry,
        // before the snapshot guard, or before the menu loop. Capture the generated script rather
        // than scanning its Swift template: an escaped line terminator in a source literal can turn
        // a source-line comment into an active AppleScript return.
        let reconciliationScript = Issue529StringBox()
        let runtime = issue529SliderRuntime(
            sliderWrites: Issue529Counter(),
            executeAppleScript: { script in
                reconciliationScript.set(script)
                return .success(#"{"result":"CLOSED"}"#)
            }
        )
        _ = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: runtime,
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in .error("osascript timed out before any ledger boundary") },
            createDialogIssuanceLedger: { nil }
        )
        let activeHelper = issue529StrippedOfAppleScriptComments(
            try #require(reconciliationScript.value)
        )
        let outerSystemEventsTell = try #require(
            activeHelper.range(of: "tell application \"System Events\"", options: .backwards)?.lowerBound,
            "the generated reconciliation script must enter System Events"
        )
        let reconciliationHandlerEntry = try #require(
            issue529NextActiveAppleScriptStatement(afterLineStartingAt: outerSystemEventsTell, in: activeHelper),
            "the generated reconciliation handler must enter its target process"
        )
        let reconciliationTryStart = try #require(
            issue529NextActiveAppleScriptStatement(afterLineStartingAt: reconciliationHandlerEntry, in: activeHelper),
            "the reconciliation handler must enter its outer try directly from handler entry"
        )
        let snapshotGuardStart = try issue529Position(
            of: "if \"\" is not \"\" then", in: activeHelper
        )
        let snapshotGuardEnd = try #require(
            issue529MatchingEndIf(after: snapshotGuardStart, in: activeHelper),
            "the snapshot-gated dialog block must close with a structurally matching end if"
        )
        let dialogCleanup = try issue529Position(
            of: "set dialogCleanupState to my dismissGoToPositionDialog(it, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)",
            in: activeHelper
        )
        let unknownDialogGuardStart = try issue529Position(
            of: "if true then", in: activeHelper
        )
        let unknownDialogGuardEnd = try #require(
            issue529MatchingEndIf(after: unknownDialogGuardStart, in: activeHelper),
            "the unknown-dialog observation block must close with a structurally matching end if"
        )
        let menuLoop = try #require(
            activeHelper.range(
                of: "repeat 3 times",
                range: unknownDialogGuardEnd..<activeHelper.endIndex
            )?.lowerBound,
            "the menu loop must follow dialog reconciliation"
        )
        let menuFocus = try issue529Position(of: "set menuFocusState to my menuEscapeFocusState(it)", in: activeHelper)

        // The dialog cleanup stays inside the snapshot-gated block (ownership requires the snapshot).
        // The enclosing handler's direct-statement spine then falls through its unknown-dialog
        // observation and into the menu loop. This checks the parent-scope control-flow structure,
        // not an arbitrarily selected textual gap.
        #expect(snapshotGuardStart < dialogCleanup)
        #expect(dialogCleanup < snapshotGuardEnd)
        let fallsThroughToMenuLoop = issue529ReconciliationFallthroughReachesMenuLoop(
            in: activeHelper,
            handlerEntry: reconciliationHandlerEntry,
            tryStart: reconciliationTryStart,
            snapshotGuardStart: snapshotGuardStart,
            snapshotGuardEnd: snapshotGuardEnd,
            unknownDialogGuardStart: unknownDialogGuardStart,
            unknownDialogGuardEnd: unknownDialogGuardEnd,
            menuLoopStart: menuLoop
        )
        #expect(fallsThroughToMenuLoop,
                "the reconciliation handler must fall through from entry, through dialog checks, to the menu loop")
        #expect(snapshotGuardEnd < menuFocus)
    }

    @Test("AppleScript line comments end at a carriage-return line terminator")
    func commentStripperEndsLineCommentsAtCarriageReturn() {
        let source = "-- comment\rreturn \"OPEN\""
        let stripped = issue529StrippedOfAppleScriptComments(source)

        #expect(stripped.contains("return \"OPEN\""),
                "a line comment must end at an AppleScript line terminator, leaving following code active")
    }

    @Test("cleanup after the resolved leaf is marked as an attempted menu write")
    func resolvedLeafClickMarksSubsequentCleanupAsAttempted() throws {
        // Mutation this rejects: move the attempt marker after the leaf or remove it, which makes
        // a leaf-error cleanup claim the menu was never actuated.
        //
        // #921 follow-up (RV-3) also sets `menuActuationAttempted` immediately BEFORE the EARLIER
        // revalidation click, so the full script now contains this exact line twice. Scope the
        // search to the region from the end of the disabled branch onward, or `issue529Position`'s
        // first-match semantics would silently bind to the revalidation occurrence instead — which
        // is always `< leafClick` regardless of whether the leaf-adjacent line survives, making the
        // mutation this test names undetectable.
        let fullScript = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let postRevalidationBranch = try issue529Position(
            of: "set observedGoToPositionDialog to missing value", in: fullScript
        )
        let script = String(fullScript[postRevalidationBranch...])
        let attempted = try issue529Position(of: "set menuActuationAttempted to true", in: script)
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let leafErrorHandlerEnd = try issue529Position(of: "-- Wait up to 3s for a new exact modal dialog", in: script)
        let leafErrorHandler = String(script[leafClick..<leafErrorHandlerEnd])
        let cleanupAfterMenuItemClick = try issue529Position(
            of: "set cleanupState to my dismissOpenMenu(logicProcess, true)", in: leafErrorHandler
        )
        let refusalContextAfterMenuItemClick = try issue529Position(
            of: "my menuCleanupActuationContext(menuActuationAttempted)", in: leafErrorHandler
        )

        #expect(attempted < leafClick)
        #expect(leafClick < leafErrorHandlerEnd)
        #expect(cleanupAfterMenuItemClick < refusalContextAfterMenuItemClick)
    }

    @Test("JSON-wrapped menu-not-found result refuses the dialog route")
    func jsonWrappedMenuNotFoundRefusesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"MENU_NOT_FOUND: Navigate menu missing"}"#
        )

        #expect(classification == .failure(.menuNotFound))
    }

    @Test("JSON-wrapped menu-pick-failed result refuses the dialog route")
    func jsonWrappedMenuPickFailedRefusesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"MENU_PICK_FAILED: AXPress failed"}"#
        )

        #expect(classification == .failure(.menuPickFailed(menuActuationAttempted: nil)))
    }

    /// #921. The forced revalidation pass can fail to open the menu at all (unlike `MENU_DISABLED`,
    /// which the script only returns once the pass DID open and re-read the leaf). This sentinel
    /// must not carry the same "the leaf is disabled" meaning, or the refusal message reverts to
    /// the exact ambiguity #921 reported.
    @Test("JSON-wrapped menu-validation-unreadable result refuses the dialog route without claiming disabled")
    func jsonWrappedMenuValidationUnreadableRefusesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"MENU_VALIDATION_UNREADABLE: menu_actuation_attempted=true"}"#
        )
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)

        #expect(classification == .failure(.menuValidationUnreadable(menuActuationAttempted: true)))
        #expect(classification != .failure(.menuDisabled))
        #expect(classification.diagnosticLabel == "menu_validation_unreadable")
        // A readable fresh-disabled result proves the click completed; an unreadable-validation
        // result does not, because the click itself may have thrown. The generated script therefore
        // marks the click attempt before issuing it, so cleanup can conservatively handle a menu it
        // may already have opened.
        #expect(classification.requiresUnsafeUIRefusal)
        #expect(classification.menuObservation == .closed)
        #expect(classification.menuActuationAttempted == .some(true))
        #expect(script.contains(
            "return \"MENU_VALIDATION_UNREADABLE: menu_actuation_attempted=\" & (menuActuationAttempted as text)"
        ))
    }

    @Test("legacy and malformed menu-validation sentinels remain conservative while neighboring values are unrelated")
    func menuValidationSentinelBoundaryPreservesSafetyWithoutSwallowingNeighbors() async throws {
        // Mutation this rejects: restore the parser's `.unexpectedResult` fallback for malformed
        // MENU_VALIDATION_UNREADABLE values. That fallback appears dialog-safe and could release the
        // later slider route; every spelling below must instead retain the unreadable refusal and its
        // conservative attempted-actuation reading.
        //
        // A neighboring token is not the sentinel merely because it shares its characters. Widening
        // the parser back to `hasPrefix("MENU_VALIDATION_UNREADABLE")` classifies this as a terminal
        // safety refusal and fails the exact-classification assertion below.
        let neighboringClassification = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"MENU_VALIDATION_UNREADABLENESS"}"#
        )
        #expect(neighboringClassification == .failure(.unexpectedResult))

        for sentinel in [
            "MENU_VALIDATION_UNREADABLE",
            "MENU_VALIDATION_UNREADABLE:menu_actuation_attempted=true",
            "MENU_VALIDATION_UNREADABLE:   menu_actuation_attempted=true",
            "MENU_VALIDATION_UNREADABLE: menu_actuation_attempted=TRUE",
            "MENU_VALIDATION_UNREADABLE: menu_actuation_attempted=garbage",
        ] {
            let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
                "{\"result\":\"\(sentinel)\"}"
            )
            #expect(classification.diagnosticLabel == "menu_validation_unreadable")
            #expect(classification.requiresUnsafeUIRefusal)
            #expect(classification.menuActuationAttempted == .some(true))

            let sliderWrites = Issue529Counter()
            let result = await AccessibilityChannel.gotoPositionViaBarSlider(
                params: ["bar": "529"],
                runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
                isFrontmost: { true },
                activateLogic: { true },
                sleepMicros: { _ in },
                executeDialogScript: { _ in .success("{\"result\":\"\(sentinel)\"}") }
            )

            let envelope = try #require(issue529Envelope(result))
            #expect(!result.isSuccess)
            #expect(try #require(envelope["state"] as? String) == "C")
            #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
            #expect(sliderWrites.value == 0)
        }
    }

    @Test("a pre-actuation menu close failure returns State C without touching the slider")
    func preActuationMenuCloseFailureDoesNotFallThroughToSlider() async throws {
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_PICK_FAILED: menu cleanup was not observed (OPEN)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["menu_state"] as? String) == "could_not_be_closed")
        let hint = try #require(envelope["hint"] as? String)
        #expect(hint.contains("not observed closed"))
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(!(try #require(envelope["menu_actuation_attempted"] as? Bool)))
        #expect(HonestContract.isFallbackUnsafeStateC(result.message))
        #expect(sliderWrites.value == 0)
    }

    /// #921. The refusal payload used to print `could_not_be_closed` for EVERY classification that
    /// reaches it, including three the script returns only after `dismissOpenMenu` answered exactly
    /// `CLOSED`. An outside report read that field, concluded the entry cleanup had refused, and
    /// argued a root cause its own payload rules out. A diagnostic that contradicts an observation
    /// the same run made is worse than one that says nothing.
    @Test("a refusal reports the menu state the script OBSERVED, not a constant")
    func menuStateIsAReadingNotALiteral() async throws {
        // Each sentinel sits behind `if cleanupState is not "CLOSED" then return MENU_PICK_FAILED`
        // in the script, so reaching it PROVES the menus were read closed.
        for (sentinel, outcome, actuationAttempted) in [
            ("MENU_NOT_FOUND: no such menu item", "menu_not_found", false),
            ("MENU_STATE_UNREADABLE", "menu_state_unreadable", false),
            // MENU_DISABLED can be reached only after its fresh read, which proves the revalidation
            // click completed. The generated script now marks its attempted actuation BEFORE that
            // click, so its own unreadable result remains attempted even if AX throws; the false
            // fixture below preserves parser coverage for an encoded external result.
            ("MENU_DISABLED", "menu_disabled", true),
            ("MENU_VALIDATION_UNREADABLE: menu_actuation_attempted=true", "menu_validation_unreadable", true),
            ("MENU_VALIDATION_UNREADABLE: menu_actuation_attempted=false", "menu_validation_unreadable", false),
        ] {
            let sliderWrites = Issue529Counter()
            let result = await AccessibilityChannel.gotoPositionViaBarSlider(
                params: ["bar": "529"],
                runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
                isFrontmost: { true },
                activateLogic: { true },
                sleepMicros: { _ in },
                executeDialogScript: { _ in .success("{\"result\":\"\(sentinel)\"}") }
            )
            let envelope = try #require(issue529Envelope(result), "\(sentinel)")
            #expect(try #require(envelope["menu_state"] as? String) == "closed",
                    "\(sentinel): the script read the menus closed before giving up")
            #expect(try #require(envelope["dialog_route_outcome"] as? String) == outcome,
                    "\(sentinel): the outcome names the real cause")
            // The SAFETY contract is unchanged; only the diagnostic stopped lying.
            #expect(try #require(envelope["state"] as? String) == "C", "\(sentinel)")
            #expect(!(try #require(envelope["safe_to_retry"] as? Bool)), "\(sentinel)")
            #expect(!(try #require(envelope["write_attempted"] as? Bool)), "\(sentinel)")
            // A top-level `Bool == Bool` inside `#expect` passes unconditionally on this toolchain
            // (Scripts/ci-forbid-dead-expect.sh), so the comparison is branched into two bare
            // expectations instead. Written as one `==` it proved nothing about either case.
            let reportedActuation = try #require(envelope["menu_actuation_attempted"] as? Bool)
            if actuationAttempted {
                #expect(reportedActuation,
                        "\(sentinel): the forced revalidation pass clicked, so this must say so")
            } else {
                #expect(!reportedActuation,
                        "\(sentinel): the script reported that the actuation-attempt marker was never reached")
            }
            #expect(sliderWrites.value == 0, "\(sentinel)")
        }
    }

    /// The control for the case above, and the reason it is not just "stop saying that string":
    /// where the cleanup GENUINELY failed the payload must still say so. Deleting the derivation
    /// and returning `.closed` everywhere passes the case above and fails this one.
    @Test("a cleanup that really did not close still reports could_not_be_closed")
    func aRealCleanupFailureStillSaysSo() async throws {
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_PICK_FAILED: menu cleanup was not observed (OPEN)"}"#)
            }
        )
        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["menu_state"] as? String) == "could_not_be_closed")
    }

    @Test("menu-close diagnostic identifies menu actuation rather than a position write")
    func menuCloseDiagnosticNamesMenuActuation() {
        for (result, expectedLabel) in [
            (
                "MENU_PICK_FAILED: menu cleanup was not observed after menu actuation (OPEN)",
                "menu_could_not_be_closed_menu_actuation_attempted_true"
            ),
            (
                "MENU_PICK_FAILED: menu cleanup was not observed (OPEN)",
                "menu_could_not_be_closed_menu_actuation_attempted_false"
            ),
        ] {
            let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
                "{\"result\":\"\(result)\"}"
            )
            #expect(classification.diagnosticLabel == expectedLabel)
        }
    }

    @Test("an unparsed dialog result is terminal and cannot release another position route")
    func unexpectedDialogResultDoesNotFallThroughToRetryableRoute() async throws {
        // Mutation this rejects: restore `.unexpectedResult` as an observed dialog-safe result.
        // One character wrong in a script sentinel establishes no menu/dialog state, so every later
        // fallback must remain withheld. The discriminator is `safe_to_retry`, which does change
        // with the fix; `sliderWrites == 0` is not one. `gotoPositionViaBarSlider` never writes the
        // bar/beat slider on any path (see its own doc comment), so that count is zero for every
        // input and is kept only as the shape this file's other cases use.
        let malformedSentinel = "DIALOG_APPEARANCE_UNREADABL3"
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
            "{\"result\":\"\(malformedSentinel)\"}"
        )
        #expect(classification == .failure(.unexpectedResult))
        #expect(classification.requiresUnsafeUIRefusal)

        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in .success("{\"result\":\"\(malformedSentinel)\"}") }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String) == "unexpected_result")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
        #expect(sliderWrites.value == 0)
    }

    @Test("an undecodable dialog payload is terminal for the same reason an unparsed result is")
    func malformedDialogPayloadDoesNotFallThroughToRetryableRoute() async throws {
        // Found by review of the `.unexpectedResult` fix: `.malformedPayload` is produced by the
        // same guard at the top of the classifier, for a strictly worse input -- stdout that is not
        // even the `{"result": …}` shape -- and it released the fallback because it had never been
        // named on either safety list. Mutation this rejects: drop `.malformedPayload` from
        // `performedDialogSafetyObservation`'s false list, which is the state the bug was in.
        let undecodable = "not even json"
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(undecodable)
        #expect(classification == .failure(.malformedPayload))
        #expect(classification.requiresUnsafeUIRefusal)

        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in .success(undecodable) }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String) == "malformed_payload")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
    }

    @Test("every dialog classification states its own fallback safety rather than inheriting one")
    func everyDialogClassificationDeclaresItsFallbackSafety() throws {
        // `performedDialogSafetyObservation` used to list the outcomes that had NOT read the state
        // and default the rest to "observed", so a case added to the enum became fallback-safe by
        // saying nothing. That is how `.malformedPayload` shipped unsafe. The lists are inverted
        // and exhaustive now, and this pins the answer for every case so the inversion is checked
        // rather than trusted: adding a case makes the switch non-exhaustive (a compile error) and
        // changing an existing answer fails here.
        let expected: [(AccessibilityChannel.GotoPositionDialogResultClassification, Bool)] = [
            (.driven, false),
            (.failure(.menuNotFound), true),
            (.failure(.menuStateUnreadable), true),
            (.failure(.menuDisabled), true),
            (.failure(.menuValidationUnreadable(menuActuationAttempted: false)), true),
            (.failure(.menuValidationUnreadable(menuActuationAttempted: true)), true),
            (.failure(.malformedPayload), true),
            (.failure(.unexpectedResult), true),
            (.failure(.menuPickFailed(menuActuationAttempted: nil)), false),
            (.failure(.menuCouldNotBeClosed(menuActuationAttempted: false, reconciledMenuClosed: false)), true),
            (.failure(.menuCouldNotBeClosed(menuActuationAttempted: true, reconciledMenuClosed: true)), true),
            (.failure(.dialogPreexisting(menuActuationAttempted: nil)), true),
            (.failure(.dialogPreexistenceUnreadable(menuActuationAttempted: nil)), true),
            (.failure(.dialogUnidentifiedNewWindow), true),
            (.failure(.dialogAppearanceUnreadable), true),
            (.failure(.dialogActuationIssued(cleanup: .dialogNotObservedClosed)), true),
            (.failure(.dialogActuationIssued(cleanup: .menuNotObservedClosed(reconciledMenuClosed: false))), true),
            (.failure(.dialogActuationIssued(cleanup: .menuNotObservedClosed(reconciledMenuClosed: true))), true),
            (.failure(.dialogActuationIssued(cleanup: .observedClosed)), false),
            (.failure(.dialogSubmissionNotIssued(cleanup: .dialogNotObservedClosed)), true),
            (.failure(.dialogSubmissionNotIssued(cleanup: .menuNotObservedClosed(reconciledMenuClosed: false))), true),
            (.failure(.dialogSubmissionNotIssued(cleanup: .menuNotObservedClosed(reconciledMenuClosed: true))), true),
            (.failure(.dialogSubmissionNotIssued(cleanup: .observedClosed)), false),
            (.failure(.dialogInputIssued(issuance: .returnArmed, cleanup: .dialogNotObservedClosed)), false),
            (.failure(.dialogSubmissionIssued(cleanup: .dialogNotObservedClosed)), false),
            (.failure(.executionFailed(issuance: .notIssued, cleanupObservedClosed: false)), true),
            (.failure(.executionFailed(issuance: .notIssued, cleanupObservedClosed: true)), false),
            (.failure(.executionFailed(issuance: .returnArmed, cleanupObservedClosed: false)), false),
        ]
        for (classification, refuses) in expected {
            // Not `#expect(a == refuses)`: a top-level `Bool == Bool` inside `#expect` passes
            // unconditionally on this toolchain (recorded as `r-941round11`), and this table
            // measured nothing at all until the mutant that flips `.malformedPayload` walked
            // straight through it.
            if refuses {
                #expect(classification.requiresUnsafeUIRefusal,
                        "\(classification.diagnosticLabel) released the fallback")
            } else {
                #expect(!classification.requiresUnsafeUIRefusal,
                        "\(classification.diagnosticLabel) refused the fallback")
            }
        }
    }

    @Test("generated dialog result sentinels and classifier sentinels remain in lockstep")
    func generatedDialogResultSentinelsMatchClassifierSentinels() throws {
        let emitted = try issue529EmittedDialogResultSentinels(
            from: AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        )
        let matched = try issue529ClassifierMatchedDialogResultSentinels()

        #expect(!emitted.isEmpty)
        #expect(emitted == matched, "emitted=\(emitted.sorted()) matched=\(matched.sorted())")

        let literals = try issue529EmittedDialogResultLiterals(
            from: AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        )
        #expect(literals.count >= emitted.count)
        for literal in literals {
            let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
                "{\"result\":\"\(literal)\"}"
            )
            #expect(classification != .failure(.unexpectedResult),
                    "the script emits \(literal) but the classifier does not match it")
        }
    }

    @Test("a post-click menu close failure records menu navigation, not a position write")
    func postClickMenuCloseFailureRefusesBeforePositionWrite() async throws {
        let sliderWrites = Issue529Counter()
        let reconciliationCalls = Issue529Counter()
        let reconciliationScript = Issue529StringBox()
        let ledger = try #require(AccessibilityChannel.DialogIssuanceLedger.create())
        defer { ledger.remove() }
        try "READY\n0\n5".write(
            to: ledger.preLeafWindowSnapshotURL,
            atomically: true,
            encoding: .utf8
        )
        let snapshotPath = try #require(
            ledger.preLeafWindowSnapshotPath,
            "the fixture ledger must hold an accepted READY pre-leaf snapshot"
        )
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(
                sliderWrites: sliderWrites,
                executeAppleScript: { script in
                    reconciliationScript.set(script)
                    reconciliationCalls.bump()
                    return .success(#"{"result":"CLOSED"}"#)
                }
            ),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_PICK_FAILED: menu cleanup was not observed after menu actuation (UNREADABLE)"}"#)
            },
            createDialogIssuanceLedger: { ledger }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "menu_could_not_be_closed_menu_actuation_attempted_true")
        #expect(try #require(envelope["menu_actuation_attempted"] as? Bool))
        #expect(!(try #require(envelope["write_attempted"] as? Bool)))
        #expect(HonestContract.isFallbackUnsafeStateC(result.message))
        #expect(reconciliationCalls.value == 1,
                "a normal post-actuation cleanup failure must enter the parent-owned reconciler")
        let script = try #require(reconciliationScript.value)
        #expect(script.contains("if \"\" is not \"\" then"),
                "the pre-leaf menu-cleanup refusal must use the menu-only reconciliation path")
        #expect(!script.contains(snapshotPath),
                "the pre-leaf menu-cleanup refusal must not pass its READY snapshot to dialog cleanup")
        #expect(sliderWrites.value == 0)
        // The reconciler above observed CLOSED. Discarding that Boolean left `menu_state` reporting
        // the script's `could_not_be_closed` over a closure the parent had just observed — the same
        // misleading diagnostic this route exists to remove, rebuilt one layer up.
        #expect(try #require(envelope["menu_state"] as? String) == "closed",
                "a reconciliation that observed the menu closed must reach menu_state")
        // Stated beside it deliberately: reporting the menu closed must not soften the refusal.
        // This pass proves the MENU closed and establishes nothing about a dialog.
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
    }

    /// The control for the assertion above. Without it, `menuObservation` could return `.closed` for
    /// every `menuCouldNotBeClosed` and both tests would still be green — a reconciled closure and a
    /// reconciliation that observed nothing would become indistinguishable in the receipt.
    @Test("a reconciliation that did not observe closure still reports could_not_be_closed")
    func unreconciledPostClickMenuCloseFailureStillSaysSo() async throws {
        let sliderWrites = Issue529Counter()
        let reconciliationCalls = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(
                sliderWrites: sliderWrites,
                executeAppleScript: { _ in
                    reconciliationCalls.bump()
                    return .success(#"{"result":"OPEN"}"#)
                }
            ),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_PICK_FAILED: menu cleanup was not observed after menu actuation (UNREADABLE)"}"#)
            }
        )
        let envelope = try #require(issue529Envelope(result))
        #expect(reconciliationCalls.value == 1,
                "the same post-actuation path must be exercised, or this is not a control")
        #expect(try #require(envelope["menu_state"] as? String) == "could_not_be_closed")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(sliderWrites.value == 0)
    }

    @Test("a leaf click that may have opened an unidentified dialog never releases CGEvent")
    func leafActuationFailureAfterOpeningDialogDoesNotRouteToCGEvent() async throws {
        // Mutation this rejects: remove the `dialogActuationIssued(cleanup: .dialogNotObservedClosed)`
        // unsafe-UI classification. The fixture is the leaf's AX error after the total-window
        // observation saw a new, unidentifiable dialog. Its reply must remain terminal: reaching
        // CGEvent would post `/`, the position text, and Return into that still-open dialog.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let leafFailureBlock = String(script[leafClick...])
        let leafError = try issue529Position(of: "on error errMsg", in: leafFailureBlock)
        let cleanup = try issue529Position(
            of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: leafFailureBlock
        )
        let cleanupRefusal = try issue529Position(
            of: "if dialogCleanupState is not \"CLOSED\" then", in: leafFailureBlock
        )
        let dialogStateStart = try issue529Position(
            of: "on goToPositionDialogState(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: script
        )
        let dialogStateEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
        let dialogState = String(script[dialogStateStart..<dialogStateEnd])
        #expect(leafError < cleanup)
        #expect(cleanup < cleanupRefusal)
        #expect(dialogState.contains("if dialogWindow is missing value then"))
        #expect(dialogState.contains("return my observedGoToPositionDialogClosure(theProcess, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)"))

        let scriptExecutions = Issue529Counter()
        let sliderWrites = Issue529Counter()
        let accessibility = Issue529DialogFixtureChannel(
            scriptResult: "DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (UNIDENTIFIED)",
            scriptExecutions: scriptExecutions,
            sliderWrites: sliderWrites
        )
        let cgEventRecorder = CGEventRecorder()
        let cgEvent = CGEventChannel(runtime: .init(
            isLogicProRunning: { true },
            logicProPID: { 529 },
            postKeyEvent: { keyCode, flags, pid in
                cgEventRecorder.post(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { _ in }
        ))
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.register(cgEvent)

        let result = await router.route(
            operation: "transport.goto_position",
            params: ["position": "529.1.1.1"]
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "dialog_actuation_issued_cleanup_closed_false")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the leaf-error reply")
        #expect(sliderWrites.value == 0)
        #expect(cgEventRecorder.snapshot().isEmpty, "CGEvent must not receive the fallback sequence")
    }

    @Test("an issued leaf AX failure with unobserved cleanup stays State C and never selects the slider")
    func issuedLeafActuationFailureWithUnobservedCleanupDoesNotSelectSlider() async throws {
        // Mutation this rejects: classify OPEN_UNKNOWN_SUBROLE cleanup as CLOSED (or otherwise
        // treat this leaf failure as clean navigation), letting an unrecognised titled modal fall
        // through to the slider while it remains open.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_ACTUATION_ISSUED: dialog cleanup was not observed (OPEN_UNKNOWN_SUBROLE)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(try #require(envelope["state"] as? String) == "C")
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        let submissionAttempted = try #require(envelope["dialog_submission_attempted"] as? Bool)
        let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)
        #expect(!writeAttempted)
        #expect(!submissionAttempted)
        #expect(fallbackUnsafe)
        #expect(sliderWrites.value == 0)
    }

    @Test("an unrecognised localized dialog title is terminal and cannot release another position route")
    func unidentifiedNewWindowDoesNotProduceRouterContinuableResult() async throws {
        // Mutation this rejects: treat an unmatched title as “not present”, restore the old `dialog
        // did not become ready` result, or remove this classification from the unsafe-UI refusal.
        // #519 still owns locale support; this fixture pins the narrower promise that a title we
        // cannot match is honestly reported as unidentified rather than absent.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        #expect(script.contains("on newWindowAppearedSince(theProcess, preLeafGoToPositionWindowCount)"))
        #expect(script.contains("return \"DIALOG_UNIDENTIFIED_NEW_WINDOW\""))

        let sliderWrites = Issue529Counter()
        let scriptExecutions = Issue529Counter()
        let accessibility = Issue529DialogFixtureChannel(
            scriptResult: "DIALOG_UNIDENTIFIED_NEW_WINDOW: localized title not in the measured whitelist",
            scriptExecutions: scriptExecutions,
            sliderWrites: sliderWrites
        )
        let cgEventRecorder = CGEventRecorder()
        let cgEvent = CGEventChannel(runtime: .init(
            isLogicProRunning: { true },
            logicProPID: { 529 },
            postKeyEvent: { keyCode, flags, pid in
                cgEventRecorder.post(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { _ in }
        ))
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.register(cgEvent)
        let result = await router.route(
            operation: "transport.goto_position",
            params: ["position": "529.1.1.1"]
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "dialog_unidentified_new_window")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
        #expect(HonestContract.isFallbackUnsafeStateC(result.message))
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the unrecognised-title reply")
        #expect(sliderWrites.value == 0)
        #expect(cgEventRecorder.snapshot().isEmpty, "CGEvent must not receive the localized-dialog fallback")
    }

    @Test("a menu result that never observed dialogs cannot release CGEvent")
    func uninspectedDialogPreflightFailuresDoNotRouteToCGEvent() async throws {
        // Mutation this rejects: change `if !performedDialogSafetyObservation { return true }`
        // to return false. Each script reply exits before either pre-leaf dialog/window count, so
        // it cannot answer that no modal is open. The recorder would otherwise receive `/`, digits,
        // and Return globally. Running all four proves every classifier seam reaches this gate.
        for (scriptResult, diagnostic) in [
            ("MENU_NOT_FOUND", "menu_not_found"),
            ("MENU_DISABLED", "menu_disabled"),
            ("MENU_STATE_UNREADABLE", "menu_state_unreadable"),
            ("MENU_VALIDATION_UNREADABLE: menu_actuation_attempted=true", "menu_validation_unreadable"),
        ] {
            let scriptExecutions = Issue529Counter()
            let sliderWrites = Issue529Counter()
            let accessibility = Issue529DialogFixtureChannel(
                scriptResult: scriptResult,
                scriptExecutions: scriptExecutions,
                sliderWrites: sliderWrites
            )
            let cgEventRecorder = CGEventRecorder()
            let cgEvent = CGEventChannel(runtime: .init(
                isLogicProRunning: { true },
                logicProPID: { 529 },
                postKeyEvent: { keyCode, flags, pid in
                    cgEventRecorder.post(keyCode: keyCode, flags: flags, pid: pid)
                },
                sleepMicros: { _ in }
            ))
            let router = ChannelRouter()
            await router.register(accessibility)
            await router.register(cgEvent)
            let result = await router.route(
                operation: "transport.goto_position",
                params: ["position": "5.1.1.1"]
            )

            let envelope = try #require(issue529Envelope(result))
            #expect(!result.isSuccess, "\(scriptResult) must remain terminal")
            #expect(try #require(envelope["state"] as? String) == "C")
            #expect(try #require(envelope["dialog_route_outcome"] as? String) == diagnostic)
            #expect(try #require(envelope["fallback_unsafe"] as? Bool))
            #expect(!(try #require(envelope["write_attempted"] as? Bool)))
            #expect(scriptExecutions.value == 1, "fixture seam must deliver \(scriptResult)")
            #expect(sliderWrites.value == 0)
            #expect(cgEventRecorder.snapshot().isEmpty, "\(scriptResult) must not release CGEvent")
        }
    }

    @Test("an unreadable post-leaf total-window count is terminal rather than clean actuation")
    func unreadableDialogAppearanceDoesNotReleaseAnotherPositionRoute() async throws {
        // Mutation this rejects: restore the old DIALOG_ACTUATION_ISSUED “appearance became
        // unreadable” reply, which the classifier treated as cleanup observed closed. A failed
        // count did not answer whether the leaf opened a dialog, so no later route may type.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let unreadableRefusal = try issue529Position(
            of: "if dialogAppearanceUnreadable then return \"DIALOG_APPEARANCE_UNREADABLE\"",
            in: script
        )
        let cleanup = try #require(
            issue529Positions(of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(", in: script)
                .first(where: { unreadableRefusal < $0 })
        )
        #expect(unreadableRefusal < cleanup)

        let sliderWrites = Issue529Counter()
        let scriptExecutions = Issue529Counter()
        let accessibility = Issue529DialogFixtureChannel(
            scriptResult: "DIALOG_APPEARANCE_UNREADABLE",
            scriptExecutions: scriptExecutions,
            sliderWrites: sliderWrites
        )
        let cgEventRecorder = CGEventRecorder()
        let cgEvent = CGEventChannel(runtime: .init(
            isLogicProRunning: { true },
            logicProPID: { 529 },
            postKeyEvent: { keyCode, flags, pid in
                cgEventRecorder.post(keyCode: keyCode, flags: flags, pid: pid)
            },
            sleepMicros: { _ in }
        ))
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.register(cgEvent)
        let result = await router.route(
            operation: "transport.goto_position",
            params: ["position": "529.1.1.1"]
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["dialog_route_outcome"] as? String) == "dialog_appearance_unreadable")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the unreadable-count reply")
        #expect(sliderWrites.value == 0)
        #expect(cgEventRecorder.snapshot().isEmpty, "CGEvent must not receive the unreadable-count fallback")
    }

    @Test("an unidentified post-Return dialog never emits the ordinary dialog State B")
    func postReturnUnidentifiedDialogCarriesUnsafeVerificationProvenance() async throws {
        // Mutation this rejects: let goToPositionDialogState return CLOSED for a missing reference,
        // `exists false`, or an unrecognised title. The post-Return cleanup reply then lacks the
        // unsafe marker and a coincident playhead can falsely certify State A downstream.
        let scriptExecutions = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["position": "5.1.1.1"],
            runtime: issue529SliderRuntime(sliderWrites: Issue529Counter()),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                scriptExecutions.bump()
                return .success(#"{"result":"DIALOG_SUBMISSION_ISSUED: dialog cleanup was not observed (UNIDENTIFIED)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "dialog_submission_issued_cleanup_closed_false")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(try #require(envelope["dialog_submission_attempted"] as? Bool))
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the post-Return reply")
    }

    @Test("an absent new window retains the clean pre-input State C")
    func noNewWindowStillProducesExistingCleanStateC() async throws {
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_ACTUATION_ISSUED: dialog did not become ready"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["error"] as? String) == "not_supported")
        #expect(try #require(envelope["safe_to_retry"] as? Bool))
        #expect(envelope["fallback_unsafe"] == nil)
        #expect(sliderWrites.value == 0)
    }

    @Test("a clean leaf-only failure does not invent an AX slider route")
    func cleanLeafActuationFailureDoesNotInventSliderRoute() async throws {
        // This requirement remains correct, but its fixture is deliberately narrow: “after
        // observed cleanup” means the post-leaf total-window check proved no new window remained.
        // If the click opened any window, the write script now returns unobserved cleanup instead
        // and the terminal test above applies. Source mutation: restore `via:"slider"` or
        // `error:.axWriteFailed` in the no-route receipt.
        let sliderWrites = Issue529Counter()
        let scriptExecutions = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                scriptExecutions.bump()
                return .success(#"{"result":"DIALOG_ACTUATION_ISSUED: AXPress reported failure after observed cleanup"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["error"] as? String) == "not_supported")
        #expect(try #require(envelope["position_route"] as? String) == "unavailable")
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(envelope["via"] == nil)
        #expect(scriptExecutions.value == 1, "fixture seam must deliver the observed-cleanup reply")
        #expect(sliderWrites.value == 0)
    }

    @Test("a dead child after the durable leaf checkpoint is indeterminate and cannot select the slider")
    func deadChildAfterLeafCheckpointDoesNotClaimSubmissionOrReleaseSlider() async throws {
        // Mutations this rejects:
        // 1. Remove the parent-owned `LEAF_ARMED` ledger checkpoint or ignore it in the `.error`
        //    branch — this clean-reconciliation fixture falls through to the slider.
        // 2. Source mutation: set `dialog_submission_attempted:true` / `write_attempted:true`
        //    for LEAF_ARMED. The marker precedes the leaf click, so it cannot prove submission.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                try! "LEAF_ARMED".write(toFile: ledgerPath, atomically: true, encoding: .utf8)
                return .error("osascript timed out after leaf click")
            },
            reconcileAfterDialogExecutionFailure: { true }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        let writeAttempted = envelope["write_attempted"] as? Bool
        let submissionAttempted = envelope["dialog_submission_attempted"] as? Bool
        #expect(writeAttempted.map { $0 ? "true" : "false" } == nil)
        #expect(submissionAttempted.map { $0 ? "true" : "false" } == nil)
        #expect(try #require(envelope["dialog_submission_indeterminate"] as? Bool))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(sliderWrites.value == 0)
    }

    @Test("a spawn failure without a ledger reports global input as indeterminate")
    func spawnFailureWithoutLedgerDoesNotOverclaimAGlobalInputAttempt() async throws {
        // Mutation this rejects: return `.attempted` rather than `.indeterminate` for
        // `.executionFailed(issuance: .unknown, ...)`. With ledger creation intentionally failed,
        // this fixture's `spawnFailed` result proves no child or key event existed; uncertainty
        // still suppresses fallback, but must not be serialized as an asserted attempt.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in .error("osascript spawnFailed") },
            reconcileAfterDialogExecutionFailure: { true },
            createDialogIssuanceLedger: { nil }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "execution_failed_issuance_unknown_cleanup_closed_true")
        #expect(try #require(envelope["dialog_input_indeterminate"] as? Bool))
        #expect(try #require(envelope["dialog_input_boundary"] as? String) == "unknown")
        #expect(try #require(envelope["dialog_input_target"] as? String) == "unknown")
        #expect(try #require(envelope["write_attempted_indeterminate"] as? Bool))
        #expect(envelope["dialog_input_attempted"] == nil)
        #expect(envelope["write_attempted"] == nil)
        #expect(try #require(envelope["dialog_submission_indeterminate"] as? Bool))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(sliderWrites.value == 0)
    }

    @Test("parent ledger cleanup removes an orphaned randomized staging file")
    func parentLedgerCleanupRemovesOrphanedTemporaryFile() async throws {
        // Mutation this rejects: remove the sibling-prefix cleanup from
        // `DialogIssuanceLedger.remove()`. This fixture leaves a `.tmp.*` file behind exactly as a
        // killed child can after `mktemp`; the parent must remove it before returning.
        let orphanedTemporaryPath = Issue529StringBox()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: Issue529Counter()),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                let temporaryPath = ledgerPath + ".tmp.orphaned-test"
                try! Data("orphaned".utf8).write(to: URL(fileURLWithPath: temporaryPath))
                orphanedTemporaryPath.set(temporaryPath)
                return .error("osascript terminated after mktemp")
            },
            reconcileAfterDialogExecutionFailure: { true }
        )

        _ = result
        let temporaryPath = try #require(orphanedTemporaryPath.value)
        #expect(!FileManager.default.fileExists(atPath: temporaryPath))
    }

    @Test("a timeout without a pre-leaf snapshot skips dialog cleanup but still attempts menu recovery")
    func unavailablePreLeafSnapshotSkipsDialogCleanupButStillAttemptsMenuRecovery() async throws {
        // #921 follow-up (RV-1): before this fix, `observeAndClearStrayGoToPositionUI` hit `guard
        // let preLeafWindowSnapshotPath else { return false }` before ever calling `executeScript`,
        // so a killed child with no durable ownership snapshot skipped EVERY cleanup, including the
        // menu-only Escape loop. That loop follows this route's deliberate fresh-observation policy,
        // not an ownership guarantee: a user could open a menu after the child dies and before
        // reconciliation. This test used to assert the resulting skip (`reconciliationCalls.value ==
        // 0`) as correct; it was the bug.
        //
        // Mutation this rejects: restore the early `guard let ... else { return false }`, which
        // would make `reconciliationCalls.value` read back 0 again and the dialog-cleanup gate below
        // unreachable-but-also-untested.
        let sliderWrites = Issue529Counter()
        let reconciliationCalls = Issue529Counter()
        let reconciliationScript = Issue529StringBox()
        let runtime = issue529SliderRuntime(
            sliderWrites: sliderWrites,
            executeAppleScript: { script in
                reconciliationScript.set(script)
                reconciliationCalls.bump()
                return .success(#"{"result":"CLOSED"}"#)
            }
        )
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: runtime,
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in .error("osascript timed out before any ledger boundary") },
            createDialogIssuanceLedger: { nil }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        // The canned CLOSED is only this fixture's result. The separate structural assertions below
        // establish that the generated unknown-state script first observes for a dialog and then
        // reaches its menu loop; this fixture captures that structure but does not execute it.
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "execution_failed_issuance_unknown_cleanup_closed_true")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(reconciliationCalls.value == 1)
        let capturedScript = try #require(reconciliationScript.value)
        #expect(!capturedScript.contains("\r"),
                "the generated reconciliation script must not contain bare carriage returns")
        let script = issue529StrippedOfAppleScriptComments(capturedScript)
        #expect(script.contains("if \"\" is not \"\" then"))
        #expect(script.contains("if true then"),
                "an unavailable snapshot must observe for a dialog before menu-only CLOSED is trusted")
        let unknownDialogObservation = try issue529Position(
            of: "set unownedGoToPositionDialogCount to my goToPositionDialogCount(it)", in: script
        )
        let unknownDialogObservationLoop = try issue529Position(
            of: "repeat 20 times", in: script
        )
        let observationLoopDelay = try #require(
            script.range(of: "delay 0.1", range: unknownDialogObservationLoop..<script.endIndex)?.lowerBound,
            "the bounded unknown-dialog observation must delay between counts"
        )
        let menuFocus = try issue529Position(
            of: "set menuFocusState to my menuEscapeFocusState(it)", in: script
        )
        let unknownDialogObservationEnd = try #require(
            script.range(of: "end repeat", range: unknownDialogObservation..<menuFocus)?.lowerBound,
            "the unknown-dialog observation must close its bounded poll before menu recovery"
        )
        let unknownDialogObservationStatements = String(
            script[unknownDialogObservationLoop..<unknownDialogObservationEnd]
        )
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        #expect(unknownDialogObservation < menuFocus,
                "unknown reconciliation must look for a dialog before it can inspect the menu")
        #expect(issue529Positions(
            of: "set unownedGoToPositionDialogCount to my goToPositionDialogCount(it)", in: script
        ).count == 1, "the dialog count must be a single statement inside the bounded poll")
        #expect(unknownDialogObservationLoop < observationLoopDelay)
        #expect(observationLoopDelay < unknownDialogObservation)
        #expect(unknownDialogObservationStatements == [
            "repeat 20 times",
            "delay 0.1",
            "set unownedGoToPositionDialogCount to my goToPositionDialogCount(it)",
            "if unownedGoToPositionDialogCount is \"UNREADABLE\" then return \"DIALOG_UNREADABLE\"",
            "if unownedGoToPositionDialogCount is greater than 0 then return \"DIALOG_UNIDENTIFIED\"",
        ], "a dialog that appears after the first count must be seen by a bounded poll, not missed after one count")
        let menuLoop = try #require(
            script.range(of: "repeat 3 times", options: .backwards, range: script.startIndex..<menuFocus)
        )
        let menuEscape = try #require(
            script.range(of: "key code 53", range: menuFocus..<script.endIndex)
        )
        let menuPathToEscape = String(script[menuLoop.lowerBound..<menuEscape.lowerBound])
        let menuPathStatements = menuPathToEscape
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(menuPathStatements == [
            "repeat 3 times",
            "set menuFocusState to my menuEscapeFocusState(it)",
            "if menuFocusState is \"CLOSED\" then return \"CLOSED\"",
            "if menuFocusState is not \"FOCUSED\" then return menuFocusState",
        ], "nothing may interrupt the menu loop's path from its header to Escape")
        // This fixture captures but does not execute its reconciliation script. The exact active
        // chain proves that this loop is live in the outer try, rather than merely present inside a
        // false guard (or any newly added guard) that would leave its statement list unchanged.
        let menuLoopChain = ["try", "repeat 3 times"]
        #expect(try #require(issue529EnclosingAppleScriptBlocks(at: menuFocus, in: script)) == menuLoopChain)
        #expect(try #require(issue529EnclosingAppleScriptBlocks(at: menuEscape.lowerBound, in: script)) == menuLoopChain)
        #expect(sliderWrites.value == 0)
    }

    @Test("an unavailable post-leaf snapshot observes dialogs before a clean reconciliation")
    func unavailablePostLeafSnapshotUsesConservativeDialogObservation() async throws {
        // A dead child after LEAF_ARMED may have opened the dialog while its snapshot is absent or
        // corrupt. It must not be conflated with the known pre-leaf menu-only case: observe a dialog
        // first, refuse rather than cancel an unowned one, and only then permit a clean menu result.
        // `actionCalls.isEmpty` proves only that this test's fake AX runtime received no Swift AX
        // action; the captured AppleScript is not executed against that fake runtime.
        //
        // Mutation this rejects: route an unavailable `.error` snapshot through the provably-pre-
        // leaf context. That leaves `if false then` here and makes a canned menu CLOSED look clean
        // without the required dialog observation.
        let reconciliationCalls = Issue529Counter()
        let reconciliationScript = Issue529StringBox()
        let fixture = issue529PreexistingDialogRuntime(
            reconciliationCalls: reconciliationCalls,
            capturedScript: reconciliationScript
        )
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: fixture.runtime,
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                try! "LEAF_ARMED".write(toFile: ledgerPath, atomically: true, encoding: .utf8)
                return .error("osascript timed out after leaf click")
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(reconciliationCalls.value == 1)
        #expect(fixture.builder.actionCalls.isEmpty)
        let script = try #require(reconciliationScript.value)
        #expect(script.contains("if \"\" is not \"\" then"))
        #expect(script.contains("if true then"),
                "an unavailable post-leaf snapshot must observe for a dialog before clean reconciliation")
        let dialogObservation = try issue529Position(
            of: "set unownedGoToPositionDialogCount to my goToPositionDialogCount(it)", in: script
        )
        let menuFocus = try issue529Position(of: "set menuFocusState to my menuEscapeFocusState(it)", in: script)
        #expect(dialogObservation < menuFocus,
                "unknown reconciliation must inspect dialogs before it can return menu CLOSED")
    }

    @Test("timeout reconciliation refuses an unrecognised modal rather than reporting closed")
    func timeoutReconcilerChecksTotalWindowCountBeforeWithholdingClosure() async throws {
        // Mutation this rejects: return CLOSED after the equal-count branch. A timeout process has
        // only serialized counts, not the in-process pre-leaf AX references, so equal totals cannot
        // distinguish a vanished target from a replacement paired with a different disappearance.
        // The fixture returns DIALOG_UNIDENTIFIED to prove the reconciliation seam ran.
        let reconciliationCalls = Issue529Counter()
        let reconciliationScript = Issue529StringBox()
        let runtime = issue529SliderRuntime(
            sliderWrites: Issue529Counter(),
            executeAppleScript: { script in
                reconciliationCalls.bump()
                reconciliationScript.set(script)
                return .success(#"{"result":"DIALOG_UNIDENTIFIED"}"#)
            }
        )
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: runtime,
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { script in
                let ledgerPath = try! issue529LedgerPath(from: script, stage: "LEAF_ARMED")
                try! "LEAF_ARMED".write(toFile: ledgerPath, atomically: true, encoding: .utf8)
                let snapshotPath = try! issue529SnapshotPath(from: script)
                try! "READY\n0\n1".write(toFile: snapshotPath, atomically: true, encoding: .utf8)
                return .error("osascript timed out after leaf click")
            }
        )

        let envelope = try #require(issue529Envelope(result))
        let script = try #require(reconciliationScript.value)
        let dialogStateStart = try issue529Position(
            of: "on goToPositionDialogState(theProcess, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)",
            in: script
        )
        let dialogStateEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
        let dialogState = String(script[dialogStateStart..<dialogStateEnd])
        let totalWindowCount = try issue529Position(
            of: "set currentGoToPositionWindowCount to my goToPositionWindowCount(theProcess)", in: dialogState
        )
        let unidentified = try issue529Position(
            of: "if currentGoToPositionWindowCount is not preLeafGoToPositionWindowCount then return \"UNIDENTIFIED\"",
            in: dialogState
        )
        let dialogCleanup = try issue529Position(
            of: "set dialogCleanupState to my dismissGoToPositionDialog(it, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)",
            in: script
        )
        let menuFocus = try issue529Position(of: "set menuFocusState to my menuEscapeFocusState(it)", in: script)

        #expect(result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(reconciliationCalls.value == 1, "fixture seam must execute the timeout reconciler")
        #expect(script.contains("if false then"),
                "a readable READY snapshot must use owned-dialog cleanup rather than unknown observation")
        #expect(totalWindowCount < unidentified)
        #expect(!dialogState.contains("return \"CLOSED\""))
        #expect(dialogCleanup < menuFocus)
    }

    @Test("an existing dialog or focus loss refuses before a position submission")
    func preexistingDialogAndFocusLossDoNotSubmitPosition() async throws {
        // Source mutations: classify DIALOG_PREEXISTING as a clean fallback, or classify
        // DIALOG_SUBMISSION_NOT_ISSUED as issued. Either lets another run's dialog receive a
        // position write or falsely reports that this focus-loss fixture submitted one.
        let preexisting = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: Issue529Counter()),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_PREEXISTING: fixture dialog belongs to another request"}"#)
            }
        )
        let preexistingEnvelope = try #require(issue529Envelope(preexisting))
        #expect(!preexisting.isSuccess)
        #expect(try #require(preexistingEnvelope["state"] as? String) == "C")
        #expect(try #require(preexistingEnvelope["fallback_unsafe"] as? Bool))
        let preexistingWrite = try #require(preexistingEnvelope["write_attempted"] as? Bool)
        #expect(!preexistingWrite)

        let focusLoss = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: Issue529Counter()),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_SUBMISSION_NOT_ISSUED: observed Go To Position dialog was not focused before typing (NOT_FOCUSED)"}"#)
            }
        )
        let focusLossEnvelope = try #require(issue529Envelope(focusLoss))
        #expect(!focusLoss.isSuccess)
        #expect(try #require(focusLossEnvelope["state"] as? String) == "C")
        let focusLossWrite = try #require(focusLossEnvelope["write_attempted"] as? Bool)
        #expect(!focusLossWrite)
        #expect(focusLossEnvelope["dialog_submission_attempted"] == nil)
    }

    @Test("a concurrent Go To Position request is refused before its leaf protocol begins")
    func concurrentDialogRequestCannotShareTheObservedModal() async throws {
        // Source mutation: remove GoToPositionDialogExecutionLock acquisition, or take it after
        // executing the dialog script. The contender then reaches its injected script instead of
        // refusing before any menu leaf can be issued.
        let gate = Issue529DialogLockGate()
        let firstScriptCalls = Issue529Counter()
        let contenderScriptCalls = Issue529Counter()
        let firstRuntime = issue529SliderRuntime(
            sliderWrites: Issue529Counter(),
            executeAppleScript: { _ in
                firstScriptCalls.bump()
                await gate.entered()
                await gate.waitForRelease()
                return .success(#"{"result":"MENU_NOT_FOUND"}"#)
            }
        )
        let contenderRuntime = issue529SliderRuntime(
            sliderWrites: Issue529Counter(),
            executeAppleScript: { _ in
                contenderScriptCalls.bump()
                return .success(#"{"result":"MENU_NOT_FOUND"}"#)
            }
        )

        // The production lock file is shared with every server and test run of this user, and any
        // holder of it refuses the first call (#994). Both calls here contend for a file nothing
        // else opens.
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-issue529-\(UUID().uuidString).lock").path
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        let first = Task {
            let result = await AccessibilityChannel.gotoPositionViaBarSlider(
                params: ["bar": "529"], runtime: firstRuntime,
                isFrontmost: { true }, activateLogic: { true }, sleepMicros: { _ in },
                dialogExecutionLockPath: lockPath
            )
            await gate.finished()
            return result
        }
        guard await gate.waitUntilEnteredOrFinished() else {
            let refused = await first.value
            Issue.record("the first call returned without reaching its script: \(refused.message)")
            return
        }
        let contender = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "530"], runtime: contenderRuntime,
            isFrontmost: { true }, activateLogic: { true }, sleepMicros: { _ in },
            dialogExecutionLockPath: lockPath
        )
        await gate.release()
        // The first call reached its script and returned the script's answer, not a lock refusal.
        let firstEnvelope = try #require(issue529Envelope(await first.value))
        #expect(try #require(firstEnvelope["dialog_route_outcome"] as? String) == "menu_not_found")

        let contenderEnvelope = try #require(issue529Envelope(contender))
        #expect(!contender.isSuccess)
        #expect(try #require(contenderEnvelope["error"] as? String) == "mutating_operation_in_progress")
        #expect(firstScriptCalls.value == 1)
        #expect(contenderScriptCalls.value == 0)
    }

    @Test("global-input and Return boundaries suppress a clean retry")
    func inputAndReturnIssuanceAreReportedAsUnsafe() async throws {
        // Source mutations: remove either SELECT_ALL_ARMED/POSITION_INPUT_ARMED checkpoint, or
        // classify DIALOG_INPUT_ISSUED as a clean non-submission failure. The first leaves a
        // timeout gap; the second returns State C with `write_attempted:false` after global input.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let selectAllLedger = try issue529Position(
            of: "recordDialogIssuance(\"SELECT_ALL_ARMED\"",
            in: script
        )
        let selectAll = try issue529Position(of: "keystroke \"a\" using command down", in: script)
        let positionInputLedger = try issue529Position(
            of: "recordDialogIssuance(\"POSITION_INPUT_ARMED\"",
            in: script
        )
        let positionInput = try issue529Position(of: "keystroke \"529.1.1.1\"", in: script)
        let returnLedger = try issue529Position(
            of: "recordDialogIssuance(\"RETURN_ARMED\"",
            in: script
        )
        let returnKey = try issue529Position(of: "keystroke return", in: script)
        #expect(selectAllLedger < selectAll)
        #expect(selectAll < positionInputLedger)
        #expect(positionInputLedger < positionInput)
        #expect(positionInput < returnLedger)
        #expect(returnLedger < returnKey)

        let preInputSliderWrites = Issue529Counter()
        let preInput = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: preInputSliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_SUBMISSION_NOT_ISSUED: observed Go To Position dialog was not focused before typing (NOT_FOCUSED)"}"#)
            }
        )
        let preInputEnvelope = try #require(issue529Envelope(preInput))
        #expect(!preInput.isSuccess)
        #expect(try #require(preInputEnvelope["state"] as? String) == "C")
        #expect(try #require(preInputEnvelope["position_route"] as? String) == "unavailable")
        let preInputWriteAttempted = try #require(preInputEnvelope["write_attempted"] as? Bool)
        #expect(!preInputWriteAttempted)
        #expect(preInputSliderWrites.value == 0)

        let inputSliderWrites = Issue529Counter()
        let input = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: inputSliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: position text may have been sent (AX error)"}"#)
            }
        )
        let inputEnvelope = try #require(issue529Envelope(input))
        #expect(input.isSuccess)
        #expect(try #require(inputEnvelope["state"] as? String) == "B")
        #expect(try #require(inputEnvelope["dialog_input_attempted"] as? Bool))
        #expect(try #require(inputEnvelope["dialog_input_boundary"] as? String) == "POSITION_INPUT_ARMED")
        #expect(try #require(inputEnvelope["dialog_input_target"] as? String) == "unknown")
        #expect(try #require(inputEnvelope["write_attempted"] as? Bool))
        #expect(!(try #require(inputEnvelope["safe_to_retry"] as? Bool)))
        #expect(try #require(inputEnvelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(inputEnvelope["dialog_submission_attempted"] as? Bool)))
        #expect(inputSliderWrites.value == 0)

        let postReturnSliderWrites = Issue529Counter()
        let postReturn = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: postReturnSliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_SUBMISSION_ISSUED: Return may have been sent (AX error)"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(postReturn))
        #expect(postReturn.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "B")
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        let submissionAttempted = try #require(envelope["dialog_submission_attempted"] as? Bool)
        let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)
        #expect(writeAttempted)
        #expect(submissionAttempted)
        #expect(fallbackUnsafe)
        #expect(postReturnSliderWrites.value == 0)
    }

    @Test("a menu-not-found result with no dialog observation is terminal and does not issue the slider")
    func menuNotFoundDoesNotIssueRelativeSlider() async throws {
        // Mutation this rejects: treat MENU_NOT_FOUND as a clean fallback. It occurs before a
        // dialog count, so it must be terminal even though no position write was attempted.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "529"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"MENU_NOT_FOUND"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["error"] as? String) == "ax_write_failed")
        #expect(try #require(envelope["dialog_route_outcome"] as? String) == "menu_not_found")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(sliderWrites.value == 0)
    }

    @Test("a reachable bar and beat slider still cannot express an absolute position")
    func relativeSliderDoesNotCertifyOrIssueTheRequestedPosition() async throws {
        // Mutation this rejects: set `kAXValueAttribute` on either Playhead Position component.
        // The measured bar control increments relatively; no guessed mapping may turn it into an
        // absolute-position write, even when the `beat` slider is reachable.
        let sliderWrites = Issue529Counter()
        let result = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["position": "529.4.1.1"],
            runtime: issue529SliderRuntime(sliderWrites: sliderWrites, includeBeatSlider: true),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                .success(#"{"result":"DIALOG_ACTUATION_ISSUED: dialog did not become ready"}"#)
            }
        )

        let envelope = try #require(issue529Envelope(result))
        #expect(!result.isSuccess)
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["requested"] as? String) == "529.4.1.1")
        let unobserved = try #require(envelope["unobserved_position_components"] as? [String])
        #expect(unobserved == ["bar", "beat", "subdivision", "tick"])
        let unexpressed = try #require(envelope["unexpressed_position_components"] as? [String])
        #expect(unexpressed == ["bar", "beat", "subdivision", "tick"])
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(try #require(envelope["position_route"] as? String) == "unavailable")
        #expect(sliderWrites.value == 0)
    }

    @Test("the dialog receives the complete requested musical position")
    func dialogTypesTheFullRequestedPosition() throws {
        // Mutation this rejects: replace the dialog input with the bar number or reconstruct it as
        // `.1.1.1`, silently discarding the request's beat/subdivision/tick components.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(position: "529.4.7.123")
        #expect(script.contains("keystroke \"529.4.7.123\""))
    }

    @Test("successful dialog submission observes modal closure before OK")
    func successfulDialogSubmissionObservesClosureBeforeOK() throws {
        // Mutation this rejects: return `OK` immediately after `keystroke return`, without reading
        // `goToPositionDialogState` and handling a dialog Logic ignored.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let returnKey = try issue529Position(of: "keystroke return", in: script)
        let postReturnObservation = try issue529Position(
            of: "set dialogPostReturnState to my goToPositionDialogState(logicProcess, observedGoToPositionDialog, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: script
        )
        let postReturnClosedGate = try issue529Position(
            of: "if dialogPostReturnState is not \"CLOSED\" then", in: script
        )
        let ok = try issue529Position(of: "return \"OK\"", in: script)

        #expect(returnKey < postReturnObservation)
        #expect(postReturnObservation < postReturnClosedGate)
        #expect(postReturnClosedGate < ok)
    }

    @Test("post-Return closure preserves every pre-leaf window rather than trusting an equal count")
    func postReturnClosureRequiresStablePreLeafWindowReferences() throws {
        // Mutation this rejects: remove `if preLeafWindowsState is not "UNCHANGED" then return
        // "UNIDENTIFIED"`. In the separating state, the original dialog reference is absent, an
        // old unrelated window also disappeared, and an unnamed Go To Position modal remains. The
        // totals happen to match, but the missing pre-leaf reference proves that equality is not
        // an observed closure of this run's dialog.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
        let preLeafSnapshot = try issue529Position(
            of: "set preLeafGoToPositionWindows to every window as list", in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let stateStart = try issue529Position(
            of: "on goToPositionDialogState(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: script
        )
        let stateEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
        let state = String(script[stateStart..<stateEnd])
        let closureStart = try issue529Position(
            of: "on observedGoToPositionDialogClosure(theProcess, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)",
            in: script
        )
        let closureEnd = try issue529Position(of: "end observedGoToPositionDialogClosure", in: script)
        let closure = String(script[closureStart..<closureEnd])
        let referenceRead = try issue529Position(
            of: "set preLeafWindowsState to my preLeafGoToPositionWindowsState(theProcess, preLeafGoToPositionWindows)",
            in: closure
        )
        let preservedGuard = try issue529Position(
            of: "if preLeafWindowsState is not \"UNCHANGED\" then return \"UNIDENTIFIED\"", in: closure
        )
        let currentCount = try issue529Position(
            of: "set currentGoToPositionWindowCount to my goToPositionWindowCount(theProcess)", in: closure
        )
        let countGuard = try issue529Position(
            of: "if currentGoToPositionWindowCount is not preLeafGoToPositionWindowCount then return \"UNIDENTIFIED\"", in: closure
        )
        let closed = try issue529Position(of: "return \"CLOSED\"", in: closure)

        #expect(preLeafSnapshot < leafClick)
        #expect(state.contains("if not (exists dialogWindow) then"))
        #expect(state.contains("return my observedGoToPositionDialogClosure(theProcess, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)"))
        #expect(referenceRead < preservedGuard)
        #expect(preservedGuard < currentCount)
        #expect(currentCount < countGuard)
        #expect(countGuard < closed)
    }

    @Test("durable issuance checkpoints precede the leaf and Return actuators")
    func durableIssuanceCheckpointsPrecedeActuators() throws {
        // Mutations this rejects: move either persistent checkpoint after its corresponding click
        // or key event, restore a direct `printf > ledgerPath` replacement, or omit cleanup after
        // a post-`mktemp` failure. The former recreates a no-record timeout window; the latter two
        // can respectively truncate the prior marker or leak a randomized staging file.
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(
            position: "529.4.1.1",
            issuanceLedgerPath: "/private/tmp/issue529-ledger"
        )
        let leafCheckpoint = try issue529Position(
            of: "recordDialogIssuance(\"LEAF_ARMED\"", in: script
        )
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
            in: script
        )
        let returnCheckpoint = try issue529Position(
            of: "recordDialogIssuance(\"RETURN_ARMED\"", in: script
        )
        let returnKey = try issue529Position(of: "keystroke return", in: script)
        let ledgerHandlerStart = try issue529Position(
            of: "on recordDialogIssuance(stage, ledgerPath)", in: script
        )
        let ledgerHandlerEnd = try issue529Position(
            of: "end recordDialogIssuance", in: script
        )
        let ledgerHandler = String(script[ledgerHandlerStart..<ledgerHandlerEnd])
        let temporaryLedger = try issue529Position(of: "set temporaryLedgerPath to do shell script", in: ledgerHandler)
        let stagedWrite = try issue529Position(of: "quoted form of temporaryLedgerPath", in: ledgerHandler)
        let atomicRename = try issue529Position(of: "&& /bin/mv -f", in: ledgerHandler)
        let cleanupGuard = try issue529Position(
            of: "if temporaryLedgerPath is not \"\" then", in: ledgerHandler
        )
        let temporaryCleanup = try issue529Position(of: "/bin/rm -f", in: ledgerHandler)

        #expect(leafCheckpoint < leafClick)
        #expect(returnCheckpoint < returnKey)
        #expect(temporaryLedger < stagedWrite)
        #expect(stagedWrite < atomicRename)
        #expect(atomicRename < cleanupGuard)
        #expect(cleanupGuard < temporaryCleanup)
        #expect(ledgerHandler.contains("ledgerPath & \".tmp.XXXXXX\""))
    }

    @Test("JSON-wrapped disabled and script-emitted preexisting sentinels refuse the dialog route")
    func jsonWrappedExistingSentinelsRefuseDialogRoute() {
        let disabled = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"MENU_DISABLED"}"#
        )
        let preexisting = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"DIALOG_PREEXISTING: Go To Position dialog was already present before leaf click"}"#
        )

        #expect(disabled == .failure(.menuDisabled))
        #expect(preexisting == .failure(.dialogPreexisting(menuActuationAttempted: nil)))

        // This was a classifier-only legacy sentinel. The script does not emit it, so it must not
        // survive outside the generator/classifier parity set; it now takes the terminal unparsed
        // result path instead of silently permitting a later fallback.
        let staleNotReady = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"DIALOG_NOT_READY"}"#
        )
        #expect(staleNotReady == .failure(.unexpectedResult))
        #expect(staleNotReady.requiresUnsafeUIRefusal)
    }

    @Test("only JSON-wrapped OK counts as driving the dialog route")
    func jsonWrappedOKDrivesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult(
            #"{"result":"OK"}"#
        )

        #expect(classification == .driven)
    }

    @Test("malformed result payload refuses the dialog route")
    func malformedPayloadRefusesDialogRoute() {
        let classification = AccessibilityChannel.classifyGotoPositionDialogResult("MENU_NOT_FOUND: unwrapped")

        #expect(classification == .failure(.malformedPayload))
    }
}

/// Before this run issues its resolved leaf, an unreadable menu read with no actuation by this run
/// must withhold Escape rather than sending it into unknown focus. Locale discovery owns no menu
/// actuation; the forced-revalidation branch below is the explicit pre-leaf exception.
@Test("locale discovery stays unowned until the resolved leaf issuance boundary")
func dismissalContextKeepsLocaleReadsUnownedUntilResolvedLeafIssuance() throws {
    // Source mutations: change an AXEnabled-read, locale-resolution, or LEAF_ARMED-write failure
    // cleanup to `dismissOpenMenu(logicProcess, true)`. Those paths have no confirmed open menu,
    // so UNREADABLE must withhold Escape from unrelated focus. The disabled-entry cleanup is
    // deliberately excluded: its `revalidated` argument records the forced menu observation.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)

    // Entry, locale discovery, the initial enabled read, and a failed durable checkpoint use
    // unowned cleanup. The disabled-entry branch is the pre-leaf exception: its `revalidated`
    // argument says this run observed the forced revalidation menu open.
    //
    // #519: locale discovery used to have two textually separate cleanup call sites — an explicit
    // "no candidate exists" branch and a catch-all `on error errMsg` handler — because the old
    // if/else-if chain distinguished "nothing matched" from "reading a candidate raised an AX
    // error". The candidate-loop resolution now raises the SAME kind of AppleScript `error` for
    // both ("not found" and "unreadable" are no longer distinguishable, which the old code did not
    // rely on either — both returned the same MENU_NOT_FOUND-prefixed refusal), so one shared
    // `on error errMsg` handler covers what used to be two call sites: 5 sites, not 6.
    //
    // #921: one of those 5 became conditional. The disabled-entry cleanup is now the one pre-leaf
    // site that may genuinely have opened something (the forced revalidation click), so it passes
    // `revalidated` instead of a hardcoded `false` — never a hardcoded `true`, which the assertion
    // below still checks. 4 literal-`false` sites plus that 1 `revalidated` site keeps the same 5
    // pre-leaf cleanup calls this test has always counted.
    #expect(issue529Positions(of: "my dismissOpenMenu(logicProcess, false)", in: script).count == 4)
    #expect(issue529Positions(of: "my dismissOpenMenu(logicProcess, revalidated)", in: script).count == 1)

    let leafCheckpoint = try issue529Position(
        of: "recordDialogIssuance(\"LEAF_ARMED\"",
        in: script
    )
    let resolvedLeaf = try issue529Position(
        of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
        in: script
    )
    #expect(leafCheckpoint < resolvedLeaf)
    let preLeaf = String(script[..<resolvedLeaf])
    #expect(!preLeaf.contains("my dismissOpenMenu(logicProcess, true)"))
    #expect(!script.contains("click selectedMenuBarItem"))
    #expect(!script.contains("click selectedSubmenuItem"))

    // The handler itself only skips Escape when no menu has been established as this run's.
    #expect(script.contains("if menuState is \"UNREADABLE\" and not knownOpen then return \"UNREADABLE\""))
}

@Test("the newly opened Go To Position dialog is count-bound and bracket-focus-bound before global typing")
func gotoPositionDialogRequiresNewCountAndBracketedFocusedBinding() throws {
    // Mutations this rejects: remove AXFloatingWindow or AXModal from the known input class;
    // delete the pre-leaf readable count snapshot or its new-window predicate; remove the second
    // frontmost read after AXFocusedWindow; restore a title/AXFocused fallback; or move a global
    // key before its post-marker focus guard. Any one can select a same-titled plug-in window or
    // let a handoff during AX resolution authorise input for another application.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(position: "529.4.7.123")
    let preLeafSnapshot = try #require(
        script.range(
            of: "set preLeafGoToPositionDialogCount to my goToPositionDialogCount(logicProcess)",
            options: .backwards
        )
    ).lowerBound
    let preLeafSnapshotGuard = try #require(
        script.range(of: "if preLeafGoToPositionDialogCount is \"UNREADABLE\" then", options: .backwards)
    ).lowerBound
    let preexistingDialogGuard = try issue529Position(
        of: "if preLeafGoToPositionDialogCount is greater than 0 then",
        in: script
    )
    let leafClick = try issue529Position(
        of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
        in: script
    )
    let observedDialog = try issue529Position(
        of: "set observedGoToPositionDialog to my matchingGoToPositionDialog(logicProcess, preLeafGoToPositionDialogCount)",
        in: script
    )
    let selectAllLedger = try issue529Position(
        of: "recordDialogIssuance(\"SELECT_ALL_ARMED\"", in: script
    )
    let focusGuard = try issue529Position(
        of: "set dialogFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)",
        in: script
    )
    let focusRefusal = try issue529Position(
        of: "observed Go To Position dialog was not focused before typing",
        in: script
    )
    let selectAll = try issue529Position(of: "keystroke \"a\" using command down", in: script)
    let positionInputLedger = try issue529Position(
        of: "recordDialogIssuance(\"POSITION_INPUT_ARMED\"", in: script
    )
    let typingFocusGuard = try issue529Position(
        of: "set dialogTypingFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)",
        in: script
    )
    let positionInput = try issue529Position(of: "keystroke \"529.4.7.123\"", in: script)
    let returnLedger = try issue529Position(of: "recordDialogIssuance(\"RETURN_ARMED\"", in: script)
    let returnFocusGuard = try issue529Position(
        of: "set dialogReturnFocusState to my observedGoToPositionDialogFocusState(logicProcess, observedGoToPositionDialog)",
        in: script
    )
    let returnKey = try issue529Position(of: "keystroke return", in: script)
    let focusHandlerStart = try issue529Position(
        of: "on observedGoToPositionDialogFocusState(theProcess, dialogWindow)", in: script
    )
    let focusHandlerEnd = try issue529Position(
        of: "end observedGoToPositionDialogFocusState", in: script
    )
    let focusHandler = String(script[focusHandlerStart..<focusHandlerEnd])
    let firstFrontmostRead = try issue529Position(of: "set logicWasFrontmost to frontmost", in: focusHandler)
    let focusedWindowRead = try issue529Position(
        of: "set processFocusedWindow to value of attribute \"AXFocusedWindow\"", in: focusHandler
    )
    let finalFrontmostRead = try issue529Position(
        of: "set logicIsStillFrontmost to frontmost", in: focusHandler
    )
    let dialogStateHandlerStart = try issue529Position(
        of: "on goToPositionDialogState(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)", in: script
    )
    let dialogStateHandlerEnd = try issue529Position(of: "end goToPositionDialogState", in: script)
    let dialogStateHandler = String(script[dialogStateHandlerStart..<dialogStateHandlerEnd])

    #expect(preLeafSnapshot < preLeafSnapshotGuard)
    #expect(preLeafSnapshotGuard < preexistingDialogGuard)
    #expect(preexistingDialogGuard < leafClick)
    #expect(leafClick < observedDialog)
    #expect(observedDialog < selectAllLedger)
    #expect(selectAllLedger < focusGuard)
    #expect(focusGuard < focusRefusal)
    #expect(focusRefusal < selectAll)
    #expect(selectAll < positionInputLedger)
    #expect(positionInputLedger < typingFocusGuard)
    #expect(typingFocusGuard < positionInput)
    #expect(positionInput < returnLedger)
    #expect(returnLedger < returnFocusGuard)
    #expect(returnFocusGuard < returnKey)
    #expect(firstFrontmostRead < focusedWindowRead)
    #expect(focusedWindowRead < finalFrontmostRead)
    #expect(focusHandler.contains("if logicWasFrontmost is not true then return \"NOT_FRONTMOST\""))
    #expect(focusHandler.contains("if logicIsStillFrontmost is not true then return \"NOT_FRONTMOST\""))
    #expect(focusHandler.contains("set dialogIsModal to value of attribute \"AXModal\" of dialogWindow"))
    #expect(focusHandler.contains("if processFocusedWindow is not dialogWindow then return \"NOT_FOCUSED\""))
    #expect(!focusHandler.contains("name of processFocusedWindow"))
    #expect(!focusHandler.contains("if focused of dialogWindow"))
    #expect(dialogStateHandler.contains("if not my knownGoToPositionDialogSubrole(dialogSubrole) then return \"OPEN_UNKNOWN_SUBROLE\""))
    #expect(dialogStateHandler.contains("if not my knownGoToPositionDialogTitle(dialogTitle) then return \"UNIDENTIFIED\""))
    #expect(dialogStateHandler.contains("return my observedGoToPositionDialogClosure(theProcess, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)"))
    #expect(dialogStateHandler.contains("set dialogIsModal to value of attribute \"AXModal\" of dialogWindow"))
    #expect(dialogStateHandler.contains("return \"OPEN_UNVERIFIED_MODALITY\""))
}

@Test("a pre-existing matching dialog refuses before this run's leaf click")
func gotoPositionDialogRefusesPreexistingMatchingDialogBeforeLeaf() throws {
    // Mutation this rejects: remove the readable count guard. Without it, an already-open matching
    // dialog could be used as the target of this run's global keystrokes.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    let snapshot = try issue529Position(
        of: "set preLeafGoToPositionDialogCount to my goToPositionDialogCount(logicProcess)", in: script
    )
    let preexistingGuard = try issue529Position(
        of: "if preLeafGoToPositionDialogCount is greater than 0 then", in: script
    )
    let leaf = try issue529Position(
        of: "click menu item positionName of menu 1 of menu item goToName of menu 1 of menu bar item barName of menu bar 1",
        in: script
    )
    let matcherStart = try issue529Position(
        of: "on matchingGoToPositionDialog(theProcess, preLeafGoToPositionDialogCount)", in: script
    )
    let matcherEnd = try issue529Position(of: "end matchingGoToPositionDialog", in: script)
    let matcher = String(script[matcherStart..<matcherEnd])
    let countBasedPriorWindowGuard = try issue529Position(
        of: "set wasPresentBefore to my windowWasPresentBefore(currentGoToPositionDialogCount, preLeafGoToPositionDialogCount)",
        in: matcher
    )
    let exactNewCountGuard = try issue529Position(
        of: "if currentGoToPositionDialogCount is not (preLeafGoToPositionDialogCount + 1) then return missing value",
        in: matcher
    )

    #expect(snapshot < preexistingGuard)
    #expect(preexistingGuard < leaf)
    #expect(countBasedPriorWindowGuard < exactNewCountGuard)
}

@Test("an unreadable Cancel result re-observes the dialog before Escape")
func unreadableCancelDoesNotAuthoriseEscapeWithoutDialogObservation() throws {
    // Mutation this rejects: move `key code 53` directly after an `UNREADABLE` Cancel result,
    // bypassing either the fresh exact-dialog state observation or the bracketed
    // frontmost-plus-AXFocusedWindow guard for that exact dialog.
    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    let handlerStart = try issue529Position(
        of: "on dismissOpenGoToPositionDialog(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)", in: script
    )
    let handlerEnd = try issue529Position(of: "end dismissOpenGoToPositionDialog", in: script)
    let handler = String(script[handlerStart..<handlerEnd])
    let unreadableBranchStart = try issue529Position(
        of: "if cancelOutcome is \"NO_BUTTON\" or cancelOutcome is \"UNREADABLE\" then", in: handler
    )
    let unreadableBranch = String(handler[unreadableBranchStart...])
    // Every operand is the first occurrence in the same fixed branch slice. Unlike the former
    // `.first { before < $0 && $0 < escape }` form, none is selected using the ordering asserted
    // below, so moving Escape before a guard makes the test fail.
    let reobservation = try issue529Position(
        of: "set dialogState to my goToPositionDialogState(theProcess, dialogWindow, preLeafGoToPositionWindows, preLeafGoToPositionWindowCount)", in: unreadableBranch
    )
    let closedGuard = try issue529Position(
        of: "if dialogState is \"CLOSED\" then return \"CLOSED\"", in: unreadableBranch
    )
    let unreadableGuard = try issue529Position(
        of: "if dialogState is \"UNREADABLE\" then return \"OPEN_UNREADABLE\"", in: unreadableBranch
    )
    let stillOpenGuard = try issue529Position(
        of: "if dialogState is not \"OPEN\" then return dialogState", in: unreadableBranch
    )
    let cleanupFocusGuard = try issue529Position(
        of: "set cleanupDialogFocusState to my observedGoToPositionDialogFocusState(theProcess, dialogWindow)",
        in: unreadableBranch
    )
    let escape = try issue529Position(of: "key code 53", in: unreadableBranch)

    #expect(reobservation < closedGuard)
    #expect(closedGuard < unreadableGuard)
    #expect(unreadableGuard < stillOpenGuard)
    #expect(stillOpenGuard < cleanupFocusGuard)
    #expect(cleanupFocusGuard < escape)
}

@Test("dead-child reconciliation targets the measured dialog before menu state")
func aDeadScriptReconcilesDialogBeforeMenuState() throws {
    // Mutations this rejects: restore the PID bypass, drop the durable pre-leaf count filter,
    // remove the final frontmost read after AXFocusedWindow, or send menu Escape after a single
    // frontmost read. Each would either cancel another run's dialog or let Escape reach a
    // different focused modal/app.
    let source = try String(
        contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/LogicProMCPTests/Issue529MenuValidationTests.swift",
            with: "Sources/LogicProMCP/Channels/AccessibilityChannel+Transport.swift"
        ),
        encoding: .utf8
    )
    let helperStart = try #require(source.range(of: "private static func observeAndClearStrayGoToPositionUI("))
    let helperEnd = try #require(source.range(of: "// MARK: - Control-bar checkbox helpers"))
    let helper = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
    let measuredSubrole = try issue529Position(of: "on knownGoToPositionDialogSubrole(dialogSubrole)", in: helper)
    let dialogObservation = try issue529Position(
        of: "on matchingGoToPositionDialog(theProcess, preLeafGoToPositionDialogCount)", in: helper
    )
    let snapshotParser = AccessibilityChannel.preLeafGoToPositionWindowSnapshotParserAppleScript()
    let dialogCleanup = try issue529Position(
        of: "set dialogCleanupState to my dismissGoToPositionDialog(it, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)",
        in: helper
    )
    let dialogStateStart = try issue529Position(
        of: "on goToPositionDialogState(theProcess, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)", in: helper
    )
    let dialogStateEnd = try issue529Position(of: "end goToPositionDialogState", in: helper)
    let dialogState = String(helper[dialogStateStart..<dialogStateEnd])
    let preexistingCountRefusal = try issue529Position(
        of: "if preLeafGoToPositionDialogCount is greater than 0 then return \"PREEXISTING\"", in: dialogState
    )
    let targetMatch = try issue529Position(
        of: "set dialogWindow to my matchingGoToPositionDialog(theProcess, preLeafGoToPositionDialogCount)",
        in: dialogState
    )
    let dismissHandlerStart = try issue529Position(
        of: "on dismissGoToPositionDialog(theProcess, preLeafGoToPositionDialogCount, preLeafGoToPositionWindowCount)", in: helper
    )
    let dismissHandlerEnd = try issue529Position(of: "end dismissGoToPositionDialog", in: helper)
    let dismissHandler = String(helper[dismissHandlerStart..<dismissHandlerEnd])
    let nonOpenRefusal = try issue529Position(
        of: "if dialogState is not \"OPEN\" then return dialogState", in: dismissHandler
    )
    // The cancel attempt, which is no longer three `exists button "<literal>"` tests. #892 renders
    // the candidates from `AXLocalePolicy.cancelButton` -- ten languages instead of three -- so the
    // anchor is the branch that presses whatever the resolution found.
    let cancelAttempt = try issue529Position(of: "if cancelName is not missing value then", in: dismissHandler)
    let focusedWindowRead = try issue529Position(
        of: "set processFocusedWindow to value of attribute \"AXFocusedWindow\"", in: helper
    )
    let finalFrontmostRead = try issue529Position(of: "set logicIsStillFrontmost to frontmost", in: helper)
    let menuFocus = try issue529Position(of: "set menuFocusState to my menuEscapeFocusState(it)", in: helper)
    let menuCleanupTail = String(helper[menuFocus...])
    let menuEscape = try issue529Position(of: "key code 53", in: menuCleanupTail)

    #expect(helper.contains("\\(preLeafGoToPositionWindowSnapshotParserAppleScript())"))
    #expect(snapshotParser.contains("on preLeafGoToPositionWindowSnapshot(snapshotPath)"))
    #expect(measuredSubrole < dialogObservation)
    #expect(dialogObservation < dialogCleanup)
    #expect(preexistingCountRefusal < targetMatch)
    #expect(nonOpenRefusal < cancelAttempt)
    #expect(focusedWindowRead < finalFrontmostRead)
    #expect(dialogCleanup < menuFocus)
    #expect(menuCleanupTail.startIndex < menuEscape)
    #expect(helper.contains("set dialogIsModal to value of attribute \"AXModal\" of dialogWindow"))
    #expect(helper.contains("if processFocusedWindow is not dialogWindow then return \"NOT_FOCUSED\""))
    #expect(!helper.contains("if frontmost then"))
    #expect(!helper.contains("ProcessUtils.logicProPID"))
}

@Test("the pre-leaf snapshot accepts only a readiness marker and canonical dialog/window counts")
func preLeafGoToPositionSnapshotIsUnambiguousAndNonInjectable() throws {
    // Mutation this rejects: weaken the count-format guard so a stale/truncated snapshot or a
    // title-shaped delimiter payload can reach timeout reconciliation as if it named this run.
    let ledger = try #require(AccessibilityChannel.DialogIssuanceLedger.create())
    defer { ledger.remove() }

    let snapshotURL = ledger.preLeafWindowSnapshotURL
    #expect(ledger.preLeafWindowSnapshotPath == nil)

    try "READY\n0\n1".write(to: snapshotURL, atomically: true, encoding: .utf8)
    #expect(ledger.preLeafWindowSnapshotPath == snapshotURL.path)

    for malformedSnapshot in [
        "READY",
        "READY\n",
        "READY\n01",
        "READY\n-1",
        "READY\n1|title=forged",
        "READY\n1\nextra",
        "READY\n0\n",
        "READY\n01\n1",
        "READY\n0\n01",
        "READY\n1\n0",
        "READY\n0\n1\nextra",
        "UNAVAILABLE",
    ] {
        try malformedSnapshot.write(to: snapshotURL, atomically: true, encoding: .utf8)
        #expect(ledger.preLeafWindowSnapshotPath == nil)
    }

    let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    #expect(script.contains("set snapshotText to \"READY\" & linefeed & (matchingGoToPositionDialogCount as text) & linefeed & (totalWindowCount as text)"))
    #expect(!script.contains("id of contents of preLeafWindow"))
    #expect(!script.contains("AXIdentifier"))
}

@Test("the timeout parser accepts the LF snapshot through Foundation")
func timeoutSnapshotParserUsesFoundationPreservedDelimiter() throws {
    // Mutation this rejects: change the production parser's `text item delimiters to linefeed`
    // back to `return`. Foundation preserves the writer's LF, so the probe executes that same
    // boundary without touching System Events and would produce one item rather than the
    // required three.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("logic-pro-mcp-snapshot-parser-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshotURL = directory.appendingPathComponent("preleaf-windows")
    try "READY\n0\n1".write(to: snapshotURL, atomically: true, encoding: .utf8)

    let parser = AccessibilityChannel.preLeafGoToPositionWindowSnapshotParserAppleScript()
    let parserProbe = parser + "\nreturn preLeafGoToPositionWindowSnapshot(\"\(snapshotURL.path)\")"
    let probeResult = try runProcess(
        executable: "/usr/bin/osascript",
        arguments: ["-e", parserProbe],
        currentDirectoryURL: directory
    )

    let writer = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)

    #expect(probeResult.exitCode == 0)
    #expect(probeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0, 1")
    #expect(writer.contains("set snapshotText to \"READY\" & linefeed"))
    #expect(parser.contains("set AppleScript's text item delimiters to linefeed"))
    #expect(!parser.contains("set AppleScript's text item delimiters to return"))
}

@Test("the write script emits the unidentified-window refusal, and emits it before any dismissal")
func writeScriptRefusesAnUnidentifiedNewWindowBeforeDismissingAnything() throws {
    // The whole unidentified-new-window refusal rests on this one AppleScript return. Every Swift-side
    // test downstream of it starts from a reply string, so deleting this line leaves the parser, the
    // classifier and the envelope tests all green while the defect returns: a window this run opened but
    // could not name would again be reported CLOSED, the result would be router-continuable, and CGEvent
    // would type the position into the live dialog.
    //
    // Order is part of the contract, not decoration. The refusal must come BEFORE
    // `dismissOpenGoToPositionDialog`, or the script would cancel the window it just declined to identify
    // — which is the same wrong-target cancellation the reconciler was fixed to avoid.
    // The generated script, not the Swift source: since #942 the dismissal is emitted from
    // `PostLeafCleanupSite`, which the source declares above the script it is interpolated into.
    let source = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    // Scope to the not-ready block. An earlier dismissal exists in the leaf-click `on error` handler,
    // which is a different case and legitimately dismisses first.
    let scriptStart = try #require(source.range(of: "if not dialogReady then"))
    let script = String(source[scriptStart.lowerBound...])

    let unidentifiedRefusal = try issue529Position(
        of: "if dialogAppearanceUnidentified then return \"DIALOG_UNIDENTIFIED_NEW_WINDOW\"", in: script
    )
    let dialogDismissal = try issue529Position(
        of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(", in: script
    )
    #expect(unidentifiedRefusal < dialogDismissal)
}

@Test("the write script records APPEARED before relying on the unidentified-window refusal")
func writeScriptMarksAnAppearedUnidentifiedWindow() throws {
    // The Swift classifier can only protect the result that AppleScript emits. Deleting this
    // assignment leaves `dialogAppearanceUnidentified` false, bypasses the terminal return below,
    // and turns a newly opened unknown-title window into a clean actuation failure. Keep the
    // APPEARED observation, assignment, terminal return, and no-dismissal order load-bearing.
    // The generated script, not the Swift source: since #942 the dismissal is emitted from
    // `PostLeafCleanupSite`, which the source declares above the script it is interpolated into.
    let source = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 529)
    let pollStart = try #require(source.range(of: "set dialogReady to false"))
    let script = String(source[pollStart.lowerBound...])
    let totalWindowObservation = try issue529Position(
        of: "set newWindowState to my newWindowAppearedSince(logicProcess, preLeafGoToPositionWindowCount)",
        in: script
    )
    let appearedGuard = try issue529Position(
        of: "if newWindowState is \"APPEARED\" or newWindowState is \"UNIDENTIFIED\" then",
        in: script
    )
    let appearedAssignment = try issue529Position(
        of: "set dialogAppearanceUnidentified to true", in: script
    )
    let unidentifiedRefusal = try issue529Position(
        of: "if dialogAppearanceUnidentified then return \"DIALOG_UNIDENTIFIED_NEW_WINDOW\"", in: script
    )
    let dialogDismissal = try issue529Position(
        of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(", in: script
    )

    #expect(totalWindowObservation < appearedGuard)
    #expect(appearedGuard < appearedAssignment)
    #expect(appearedAssignment < unidentifiedRefusal)
    #expect(unidentifiedRefusal < dialogDismissal)
}

/// #942. Twelve post-leaf returns closed the Go To Position dialog and then the menu, and a menu
/// that was not observed closed there was never reconciled: the parser folded it into the dialog
/// case, and the only reconciliation it could have reached was the snapshot path, whose dialog half
/// never answers CLOSED. The reconciliation fixtures below return a canned answer without running
/// the generated script (r-941round7), so what they establish about the pass is structural: which
/// path it was given and what the receipt does with its answer.
@Suite(.serialized) struct Issue942PostLeafMenuReconciliationTests {
    typealias Site = AccessibilityChannel.PostLeafCleanupSite

    static let sites = AccessibilityChannel.postLeafCleanupSites

    static func site(_ identifier: String) throws -> Site {
        try #require(sites.first { $0.identifier == identifier })
    }

    /// A result carrying `value`, encoded the way the script channel encodes one.
    static func scriptOutput(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["result": value])
        return try #require(String(data: data, encoding: .utf8))
    }

    static func menuRefusal(_ site: Site) -> String {
        "\(site.resultPrefix)\(Site.menuRefusal) after menu actuation (UNREADABLE)"
    }

    static func dialogRefusal(_ site: Site) -> String {
        "\(site.resultPrefix)\(Site.dialogRefusal) (UNREADABLE)"
    }

    /// The four sites, under two prefixes, whose refusal is the State C unsafe-UI receipt, which
    /// carries `menu_state`. The other eight may have issued global input and end in the State B
    /// fallback-suppression receipt, which carries no `menu_state`.
    static func refusesAsStateC(_ site: Site) -> Bool {
        site.resultPrefix == "DIALOG_ACTUATION_ISSUED" || site.resultPrefix == "DIALOG_SUBMISSION_NOT_ISSUED"
    }

    @Test("declared post-leaf cleanup sites correspond exactly to the generated script")
    func declaredSitesCorrespondToTheGeneratedScript() throws {
        let generatedScript = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 942)
        let script = issue529StrippedOfAppleScriptComments(generatedScript)
        #expect(Self.sites.count == 12)
        #expect(Set(Self.sites.map(\.identifier)).count == Self.sites.count)
        // Every dialog cleanup and every menu refusal in the script is a declared one, so a
        // thirteenth inline copy cannot reintroduce the unreconciled shape.
        #expect(issue529Positions(
            of: "set dialogCleanupState to my dismissOpenGoToPositionDialog(logicProcess, observedGoToPositionDialog",
            in: script
        ).count == Self.sites.count)
        #expect(issue529Positions(of: "menu cleanup was not observed", in: script).count
            == Self.sites.count + AccessibilityChannel.menuCleanupRefusalSites.count)
        let leafClick = try issue529Position(
            of: "click menu item positionName of menu 1 of menu item goToName of menu 1 "
                + "of menu bar item barName of menu bar 1",
            in: generatedScript
        )
        for site in Self.sites {
            #expect(generatedScript.contains(site.appleScript), "\(site.identifier)")
            let marker = try issue529Position(
                of: "-- POST_LEAF_CLEANUP_SITE: \(site.identifier)", in: generatedScript
            )
            #expect(marker > leafClick, "\(site.identifier) is declared post-leaf")
        }
    }

    /// The sites appear in the script in the order the protocol reaches them, which is the order
    /// `postLeafCleanupSites` declares. Two sites swapped in the script would each report the
    /// other's stage, such as `POSITION_INPUT_ARMED` after only Select All was sent, and the other
    /// tests here would still pass: each site is still rendered once and after the leaf click.
    @Test func theSitesAppearInTheOrderTheyAreDeclared() throws {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 942)
        let inScriptOrder = try Self.sites
            .map { site in
                (try issue529Position(of: "-- POST_LEAF_CLEANUP_SITE: \(site.identifier)\n", in: script),
                 site.identifier)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
        #expect(inScriptOrder == Self.sites.map(\.identifier))
    }

    /// Binds each declared prefix to the parser: a prefix the parser does not classify would fall
    /// to another arm and never reach the menu-only case.
    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.map(\.identifier))
    func eachSitesRefusalsParseToTheCleanupTheyName(_ identifier: String) throws {
        let site = try Self.site(identifier)
        let menu = AccessibilityChannel.classifyGotoPositionDialogResult(
            try Self.scriptOutput(Self.menuRefusal(site)))
        #expect(menu.postLeafCleanup == .menuNotObservedClosed(reconciledMenuClosed: false))
        #expect(menu.requiresPostActuationMenuReconciliation)
        let dialog = AccessibilityChannel.classifyGotoPositionDialogResult(
            try Self.scriptOutput(Self.dialogRefusal(site)))
        #expect(dialog.postLeafCleanup == .dialogNotObservedClosed)
        #expect(!dialog.requiresPostActuationMenuReconciliation)
        // The route outcome keeps its spelling: the script did not observe both closed.
        #expect(menu.diagnosticLabel == dialog.diagnosticLabel)
        #expect(menu.diagnosticLabel.hasSuffix("_cleanup_closed_false"))
    }

    /// The menu cleanup can press Escape. Each site settles the dialog first and returns its
    /// refusal before the menu cleanup, so that Escape is never sent while the Go To Position
    /// dialog may still be open. Whether it may be is the question #942 leaves open.
    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.map(\.identifier))
    func eachSiteSettlesTheDialogBeforeTheMenu(_ identifier: String) throws {
        let script = try Self.site(identifier).appleScript
        let dialogCleanup = try issue529Position(of: "my dismissOpenGoToPositionDialog(", in: script)
        let dialogRefusal = try issue529Position(of: Site.dialogRefusal, in: script)
        let dialogGuardEnd = try issue529Position(of: "end if", in: script)
        let menuCleanup = try issue529Position(of: "my dismissOpenMenu(", in: script)
        let menuRefusal = try issue529Position(of: Site.menuRefusal, in: script)
        #expect(dialogCleanup < dialogRefusal)
        #expect(dialogRefusal < dialogGuardEnd)
        #expect(dialogGuardEnd < menuCleanup)
        #expect(menuCleanup < menuRefusal)
    }

    @Test func onlyTheExactMenuRefusalIsTheMenuOnlyCase() throws {
        let other = AccessibilityChannel.classifyGotoPositionDialogResult(
            try Self.scriptOutput("DIALOG_SUBMISSION_ISSUED: the menu cleanup was not observed (OPEN)"))
        #expect(other.postLeafCleanup == .dialogNotObservedClosed)
        let closed = AccessibilityChannel.classifyGotoPositionDialogResult(
            try Self.scriptOutput("DIALOG_ACTUATION_ISSUED: dialog did not become ready"))
        #expect(closed.postLeafCleanup == .observedClosed)
        #expect(!closed.requiresPostActuationMenuReconciliation)
    }

    /// Runs the route on one site's menu refusal with a READY snapshot on the ledger, so a pass
    /// handed the snapshot path would carry it in its script. With `executionFailureStage` the
    /// child instead dies after writing that stage to the ledger, which runs the snapshot pass.
    static func runMenuRefusal(
        _ site: Site, reconcilerAnswer: String, result: String? = nil, executionFailureStage: String? = nil
    ) async throws -> (envelope: [String: Any], calls: Int, script: String?, snapshotPath: String, sliderWrites: Int) {
        let sliderWrites = Issue529Counter()
        let calls = Issue529Counter()
        let reconciliationScript = Issue529StringBox()
        let ledger = try #require(AccessibilityChannel.DialogIssuanceLedger.create())
        defer { ledger.remove() }
        try "READY\n0\n5".write(to: ledger.preLeafWindowSnapshotURL, atomically: true, encoding: .utf8)
        let snapshotPath = try #require(ledger.preLeafWindowSnapshotPath)
        let output = try scriptOutput(result ?? menuRefusal(site))
        let routed = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "942"],
            runtime: issue529SliderRuntime(
                sliderWrites: sliderWrites,
                executeAppleScript: { script in
                    reconciliationScript.set(script)
                    calls.bump()
                    return .success(#"{"result":"\#(reconcilerAnswer)"}"#)
                }
            ),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { _ in },
            executeDialogScript: { _ in
                guard let executionFailureStage else { return .success(output) }
                try? executionFailureStage.write(to: ledger.url, atomically: true, encoding: .utf8)
                return .error("osascript timedOut")
            },
            createDialogIssuanceLedger: { ledger }
        )
        let envelope = try #require(issue529Envelope(routed))
        return (envelope, calls.value, reconciliationScript.value, snapshotPath, sliderWrites.value)
    }

    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.map(\.identifier), [true, false])
    func aPostLeafMenuRefusalIsReconciledMenuOnly(_ identifier: String, reconcilerObservedClosed: Bool) async throws {
        let site = try Self.site(identifier)
        let run = try await Self.runMenuRefusal(
            site, reconcilerAnswer: reconcilerObservedClosed ? "CLOSED" : "OPEN")
        #expect(run.calls == 1, "the menu refusal must enter the parent-owned reconciler")
        let script = try #require(run.script)
        #expect(script.contains("if \"\" is not \"\" then"), "the pass must be the menu-only path")
        #expect(!script.contains(run.snapshotPath), "the snapshot path never reaches the menu loop")
        #expect(run.sliderWrites == 0)
        // Reconciling the menu changes what the receipt says about it, never the refusal.
        #expect(try #require(run.envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(run.envelope["safe_to_retry"] as? Bool)))
        #expect(try #require(run.envelope["dialog_route_outcome"] as? String).hasSuffix("_cleanup_closed_false"))
        if Self.refusesAsStateC(site) {
            #expect(try #require(run.envelope["state"] as? String) == "C")
            #expect(try #require(run.envelope["menu_state"] as? String)
                == (reconcilerObservedClosed ? "closed" : "could_not_be_closed"))
        } else {
            #expect(try #require(run.envelope["state"] as? String) == "B")
        }
    }

    /// The control: a dialog that was not observed closed is not the menu-only case, so it is not
    /// reconciled here and its receipt still says nothing about the menu.
    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.map(\.identifier))
    func aPostLeafDialogRefusalIsNotReconciled(_ identifier: String) async throws {
        let site = try Self.site(identifier)
        let run = try await Self.runMenuRefusal(
            site, reconcilerAnswer: "CLOSED", result: Self.dialogRefusal(site))
        #expect(run.calls == 0)
        #expect(run.sliderWrites == 0)
        #expect(try #require(run.envelope["fallback_unsafe"] as? Bool))
        if Self.refusesAsStateC(site) {
            #expect(try #require(run.envelope["menu_state"] as? String) == "unobserved")
        }
    }
}
