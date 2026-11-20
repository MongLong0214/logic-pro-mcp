import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import LogicProMCP

// Two ratchets over `Sources/LogicProMCP`, both read from the syntax tree so a comment or a string
// cannot satisfy or defeat them.
//
//  1. FIXED SLEEPS. Every `usleep`, `Thread.sleep`, `Task.sleep`, injected `sleep(...)` and
//     AppleScript `delay N` is a site. A NEW site above `thresholdMs` (or one whose duration is not
//     a literal) fails. The summed literal duration may never exceed the recorded budget, and a
//     removed site fails until `docs/perf/fixed-sleep-baseline.json` is lowered, so the number can
//     only fall. The way to remove a fixed wait is a bounded readback poll (`SettlePoll`).
//
//  2. SYNTHETIC MOUSE. Any construction or post of a mouse/scroll CGEvent, cursor warp, or call of
//     the mouse helper counts. A file that is not in `docs/perf/synthetic-mouse-sites.json` fails, a
//     count above the recorded one fails, and a count below it fails until the file is lowered.
//     Every remaining file must carry the measured reason no direct path works, the direct
//     alternative to try, and the evidence for the reason.
//
// Regenerate counts after an intentional reduction: LPM_LATENCY_BASELINE_WRITE=1 swift test
// --filter OperationLatencyBudgetGuardTests (existing mouse reasons are preserved).

enum LatencyBudgetScan {
    struct Found {
        let key: String
        let line: Int
        let micros: Int?
    }

    struct Scan {
        var sleeps: [Found] = []
        var mouse: [Found] = []
    }

    static let mouseSymbols: Set<String> = [
        "leftMouseDown", "leftMouseUp", "leftMouseDragged", "rightMouseDown", "rightMouseUp",
        "rightMouseDragged", "otherMouseDown", "otherMouseUp", "otherMouseDragged", "mouseMoved",
        "scrollWheel", "CGWarpMouseCursorPosition", "CGEventCreateMouseEvent",
        "CGEventCreateScrollWheelEvent", "postMouseEvent", "prepareMouseClick", "postMouseClick",
        "postMouseDoubleClick",
    ]
    static let mouseLabels: Set<String> = ["mouseEventSource", "scrollWheelEvent2Source"]
    static let mouseHelperCalls: Set<String> = ["click", "doubleClick"]

    final class Visitor: SyntaxVisitor {
        let file: String
        let converter: SourceLocationConverter
        var scan = Scan()

        init(file: String, converter: SourceLocationConverter) {
            self.file = file
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        private func line(_ node: some SyntaxProtocol) -> Int {
            converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        }

        private func scope(_ node: some SyntaxProtocol) -> String {
            var function: String?
            var type: String?
            var cursor: Syntax? = Syntax(node)
            while let current = cursor {
                if function == nil {
                    if let decl = current.as(FunctionDeclSyntax.self) { function = decl.name.text }
                    else if current.is(InitializerDeclSyntax.self) { function = "init" }
                    else if let binding = current.as(PatternBindingSyntax.self),
                            let name = binding.pattern.as(IdentifierPatternSyntax.self) {
                        function = name.identifier.text
                    }
                }
                if type == nil {
                    if let decl = current.as(StructDeclSyntax.self) { type = decl.name.text }
                    else if let decl = current.as(ClassDeclSyntax.self) { type = decl.name.text }
                    else if let decl = current.as(EnumDeclSyntax.self) { type = decl.name.text }
                    else if let decl = current.as(ActorDeclSyntax.self) { type = decl.name.text }
                    else if let decl = current.as(ExtensionDeclSyntax.self) {
                        type = decl.extendedType.trimmedDescription
                    }
                }
                cursor = current.parent
            }
            return "\(type ?? "<file>").\(function ?? "<top>")"
        }

        private func record(sleep kind: String, micros: Int?, at node: some SyntaxProtocol) {
            let key = "\(file)|\(scope(node))|\(kind)|\(micros.map(String.init) ?? "dynamic")"
            scan.sleeps.append(Found(key: key, line: line(node), micros: micros))
        }

        private func record(mouse symbol: String, at node: some SyntaxProtocol) {
            scan.mouse.append(Found(key: "\(file)|\(scope(node))|\(symbol)", line: line(node), micros: nil))
        }

        static func number(_ expr: ExprSyntax?) -> Double? {
            guard let expr else { return nil }
            if let int = expr.as(IntegerLiteralExprSyntax.self) {
                return Double(int.literal.text.replacingOccurrences(of: "_", with: ""))
            }
            if let float = expr.as(FloatLiteralExprSyntax.self) {
                return Double(float.literal.text.replacingOccurrences(of: "_", with: ""))
            }
            return nil
        }

        /// `.milliseconds(50)`, `.seconds(1)`, `.microseconds(10)`, `.nanoseconds(5)`.
        static func durationMicros(_ expr: ExprSyntax?) -> Double? {
            guard let call = expr?.as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  let value = number(call.arguments.first?.expression) else { return nil }
            switch member.declName.baseName.text {
            case "seconds": return value * 1_000_000
            case "milliseconds": return value * 1_000
            case "microseconds": return value
            case "nanoseconds": return value / 1_000
            default: return nil
            }
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            let callee = node.calledExpression.trimmedDescription.replacingOccurrences(of: " ", with: "")
            let first = node.arguments.first
            func labelled(_ label: String) -> ExprSyntax? {
                node.arguments.first { $0.label?.text == label }?.expression
            }
            switch callee {
            case "usleep":
                record(sleep: "usleep", micros: Visitor.number(first?.expression).map(Int.init), at: node)
            case "Thread.sleep":
                record(sleep: "Thread.sleep",
                       micros: Visitor.number(labelled("forTimeInterval")).map { Int($0 * 1_000_000) }, at: node)
            case "Task.sleep":
                if let nanos = labelled("nanoseconds") {
                    record(sleep: "Task.sleep", micros: Visitor.number(nanos).map { Int($0 / 1_000) }, at: node)
                } else {
                    record(sleep: "Task.sleep", micros: Visitor.durationMicros(labelled("for")).map(Int.init), at: node)
                }
            default:
                let isInjectedSleep = callee == "sleep" || callee.hasSuffix(".sleep")
                    || callee.hasSuffix("waitForNextSample")
                if isInjectedSleep, !callee.hasPrefix("Thread.") {
                    var micros: Int?
                    if let duration = Visitor.durationMicros(first?.expression) { micros = Int(duration) }
                    else if let value = Visitor.number(first?.expression) {
                        // Heuristic units: a whole number of 1000 or more is nanoseconds, anything
                        // smaller is seconds. Only the SHAPE of the key matters to the ratchet.
                        micros = value >= 1000 ? Int(value / 1_000) : Int(value * 1_000_000)
                    }
                    record(sleep: "injected-sleep", micros: micros, at: node)
                }
            }
            if node.arguments.contains(where: { LatencyBudgetScan.mouseLabels.contains($0.label?.text ?? "") }) {
                record(mouse: "CGEvent(mouse-or-scroll)", at: node)
            }
            return .visitChildren
        }

        override func visit(_ node: StringSegmentSyntax) -> SyntaxVisitorContinueKind {
            let text = node.content.text
            guard text.contains("delay"),
                  let regex = try? NSRegularExpression(pattern: #"(?m)(?:^|\s)delay\s+([0-9]+(?:\.[0-9]+)?)\b"#) else {
                return .skipChildren
            }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: text), let seconds = Double(text[valueRange]) else { continue }
                record(sleep: "applescript-delay", micros: Int(seconds * 1_000_000), at: node)
            }
            return .skipChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if LatencyBudgetScan.mouseSymbols.contains(node.baseName.text) {
                record(mouse: node.baseName.text, at: node)
            }
            return .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            if node.base?.trimmedDescription == "AXMouseHelper",
               LatencyBudgetScan.mouseHelperCalls.contains(node.declName.baseName.text) {
                record(mouse: "AXMouseHelper.\(node.declName.baseName.text)", at: node)
            }
            return .visitChildren
        }
    }

    static func scan(source: String, file: String) -> Scan {
        let tree = Parser.parse(source: source)
        let visitor = Visitor(file: file, converter: SourceLocationConverter(fileName: file, tree: tree))
        visitor.walk(tree)
        return visitor.scan
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Parsing the tree takes minutes in a debug build, so the repository scan is done once.
    private static let cachedTree = Result { try scanTree(root: repoRoot) }
    static func sharedTree() throws -> Scan { try cachedTree.get() }

    static func scanTree(root: URL = repoRoot) throws -> Scan {
        let sources = root.appendingPathComponent("Sources/LogicProMCP")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var total = Scan()
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(sources.path.count + 1))
            let part = scan(source: try String(contentsOf: url, encoding: .utf8), file: relative)
            total.sleeps += part.sleeps
            total.mouse += part.mouse
        }
        return total
    }

    // MARK: baselines

    struct SleepBaseline: Codable, Equatable {
        var note: String
        var thresholdMs: Int
        var totalLiteralMicros: Int
        var sites: [String: Int]
    }

    struct MouseFile: Codable, Equatable {
        var count: Int
        var reason: String
        var directAlternative: String
        var evidence: String
        enum CodingKeys: String, CodingKey { case count, reason, directAlternative = "direct_alternative", evidence }
    }

    struct MouseBaseline: Codable, Equatable {
        var note: String
        var files: [String: MouseFile]
    }

    static func evaluateSleeps(_ scan: Scan, baseline: SleepBaseline) -> [String] {
        var violations: [String] = []
        var actual: [String: Int] = [:]
        for site in scan.sleeps { actual[site.key, default: 0] += 1 }
        var total = 0
        for site in scan.sleeps { total += site.micros ?? 0 }
        let limit = baseline.thresholdMs * 1_000
        for (key, count) in actual.sorted(by: { $0.key < $1.key }) {
            let extra = count - (baseline.sites[key] ?? 0)
            guard extra > 0 else { continue }
            let micros = scan.sleeps.first { $0.key == key }?.micros
            if let micros, micros <= limit { continue }
            let lines = scan.sleeps.filter { $0.key == key }.map { String($0.line) }.joined(separator: ",")
            violations.append("new fixed sleep over \(baseline.thresholdMs) ms (or not a literal): \(key) at line \(lines). "
                + "Poll the readback with SettlePoll instead of waiting.")
        }
        if total > baseline.totalLiteralMicros {
            violations.append("fixed-sleep budget exceeded: \(total) us > \(baseline.totalLiteralMicros) us")
        }
        for (key, recorded) in baseline.sites.sorted(by: { $0.key < $1.key }) where (actual[key] ?? 0) < recorded {
            violations.append("baseline is stale, a fixed sleep was removed: \(key) \(actual[key] ?? 0) < \(recorded). "
                + "Lower docs/perf/fixed-sleep-baseline.json (LPM_LATENCY_BASELINE_WRITE=1).")
        }
        if total < baseline.totalLiteralMicros, violations.isEmpty {
            violations.append("budget not ratcheted down: \(total) us < \(baseline.totalLiteralMicros) us")
        }
        return violations
    }

    static func evaluateMouse(_ scan: Scan, baseline: MouseBaseline) -> [String] {
        var violations: [String] = []
        var actual: [String: Int] = [:]
        for site in scan.mouse { actual[String(site.key.prefix { $0 != "|" }), default: 0] += 1 }
        for (file, count) in actual.sorted(by: { $0.key < $1.key }) {
            guard let recorded = baseline.files[file] else {
                violations.append("new synthetic-mouse site in \(file) (\(count)): drive the control with AXPress, an AX attribute write, a key command, MIDI or MCU instead")
                continue
            }
            if count > recorded.count {
                violations.append("synthetic-mouse sites grew in \(file): \(count) > \(recorded.count)")
            }
        }
        for (file, recorded) in baseline.files.sorted(by: { $0.key < $1.key }) {
            if (actual[file] ?? 0) < recorded.count {
                violations.append("synthetic-mouse baseline is stale for \(file): \(actual[file] ?? 0) < \(recorded.count); lower or delete the entry")
            }
            for (name, text, minimum) in [("reason", recorded.reason, 60), ("direct_alternative", recorded.directAlternative, 30),
                                          ("evidence", recorded.evidence, 10)] where text.trimmingCharacters(in: .whitespacesAndNewlines).count < minimum {
                violations.append("\(file) has no \(name) (at least \(minimum) characters): a remaining mouse site must say why no direct path works")
            }
        }
        return violations
    }

    static var sleepBaselineURL: URL { repoRoot.appendingPathComponent("docs/perf/fixed-sleep-baseline.json") }
    static var mouseBaselineURL: URL { repoRoot.appendingPathComponent("docs/perf/synthetic-mouse-sites.json") }

    static func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func write<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(value) + Data("\n".utf8)).write(to: url)
    }
}

@Suite struct OperationLatencyBudgetGuardTests {
    private static let thresholdMs = 50

    private static func regenerate(_ scan: LatencyBudgetScan.Scan) throws {
        var sites: [String: Int] = [:]
        for site in scan.sleeps { sites[site.key, default: 0] += 1 }
        let old = try? LatencyBudgetScan.load(LatencyBudgetScan.SleepBaseline.self, LatencyBudgetScan.sleepBaselineURL)
        try LatencyBudgetScan.write(LatencyBudgetScan.SleepBaseline(
            note: old?.note ?? "", thresholdMs: old?.thresholdMs ?? thresholdMs,
            totalLiteralMicros: scan.sleeps.reduce(0) { $0 + ($1.micros ?? 0) }, sites: sites
        ), LatencyBudgetScan.sleepBaselineURL)
        var counts: [String: Int] = [:]
        for site in scan.mouse { counts[String(site.key.prefix { $0 != "|" }), default: 0] += 1 }
        let oldMouse = try? LatencyBudgetScan.load(LatencyBudgetScan.MouseBaseline.self, LatencyBudgetScan.mouseBaselineURL)
        var files: [String: LatencyBudgetScan.MouseFile] = [:]
        for (file, count) in counts {
            var entry = oldMouse?.files[file] ?? .init(count: count, reason: "", directAlternative: "", evidence: "")
            entry.count = count
            files[file] = entry
        }
        try LatencyBudgetScan.write(LatencyBudgetScan.MouseBaseline(note: oldMouse?.note ?? "", files: files),
                                    LatencyBudgetScan.mouseBaselineURL)
    }

    private static func realScan() throws -> LatencyBudgetScan.Scan {
        let scan = try LatencyBudgetScan.sharedTree()
        if ProcessInfo.processInfo.environment["LPM_LATENCY_BASELINE_WRITE"] == "1" { try regenerate(scan) }
        return scan
    }

    // MARK: the real tree

    @Test func theTreeStaysInsideTheFixedSleepBudgetAndTheBudgetOnlyFalls() throws {
        let baseline = try LatencyBudgetScan.load(LatencyBudgetScan.SleepBaseline.self, LatencyBudgetScan.sleepBaselineURL)
        #expect(baseline.thresholdMs == Self.thresholdMs, "the threshold is part of the contract; do not raise it")
        let scan = try Self.realScan()
        #expect(scan.sleeps.count > 150, "the scanner must see the tree: it found \(scan.sleeps.count) sleep sites")
        #expect(LatencyBudgetScan.evaluateSleeps(scan, baseline: baseline) == [])
    }

    @Test func theTreeHasNoSyntheticMouseSiteBeyondTheMeasuredSet() throws {
        let baseline = try LatencyBudgetScan.load(LatencyBudgetScan.MouseBaseline.self, LatencyBudgetScan.mouseBaselineURL)
        let scan = try Self.realScan()
        #expect(scan.mouse.count > 20, "the scanner must see the tree: it found \(scan.mouse.count) mouse sites")
        #expect(LatencyBudgetScan.evaluateMouse(scan, baseline: baseline) == [])
    }

    // MARK: mutants. Each one edits a real source file in memory and must be refused.

    private static func sourceText(_ relative: String) throws -> String {
        try String(contentsOf: LatencyBudgetScan.repoRoot.appendingPathComponent("Sources/LogicProMCP/\(relative)"), encoding: .utf8)
    }

    private static func mutatedScan(replacing file: String, with edit: (String) -> String) throws -> LatencyBudgetScan.Scan {
        var scan = try LatencyBudgetScan.sharedTree()
        let mutated = LatencyBudgetScan.scan(source: edit(try sourceText(file)), file: file)
        scan.sleeps = scan.sleeps.filter { !$0.key.hasPrefix("\(file)|") } + mutated.sleeps
        scan.mouse = scan.mouse.filter { !$0.key.hasPrefix("\(file)|") } + mutated.mouse
        return scan
    }

    private static func sleepBaseline() throws -> LatencyBudgetScan.SleepBaseline {
        try LatencyBudgetScan.load(LatencyBudgetScan.SleepBaseline.self, LatencyBudgetScan.sleepBaselineURL)
    }
    private static func mouseBaseline() throws -> LatencyBudgetScan.MouseBaseline {
        try LatencyBudgetScan.load(LatencyBudgetScan.MouseBaseline.self, LatencyBudgetScan.mouseBaselineURL)
    }

    @Test func mutantAddingAHalfSecondSleepToAnOperationPathIsRefused() throws {
        let scan = try Self.mutatedScan(replacing: "Dispatchers/TransportDispatcher.swift") {
            $0 + "\nfunc addedWait() { usleep(500_000) }\n"
        }
        let violations = LatencyBudgetScan.evaluateSleeps(scan, baseline: try Self.sleepBaseline())
        #expect(violations.contains { $0.contains("new fixed sleep over 50 ms") && $0.contains("TransportDispatcher") })
        #expect(violations.contains { $0.contains("budget exceeded") })
    }

    @Test func mutantAddingASleepThroughANamedConstantIsRefusedToo() throws {
        let scan = try Self.mutatedScan(replacing: "Dispatchers/TransportDispatcher.swift") {
            $0 + "\nfunc sneaky(_ settle: UInt64) async { try? await Task.sleep(nanoseconds: settle) }\n"
        }
        let violations = LatencyBudgetScan.evaluateSleeps(scan, baseline: try Self.sleepBaseline())
        #expect(violations.contains { $0.contains("sneaky") && $0.contains("dynamic") })
    }

    @Test func mutantAddingAnAppleScriptDelayIsRefused() throws {
        let scan = try Self.mutatedScan(replacing: "Channels/AccessibilityChannel+Regions.swift") {
            $0 + "\nlet s = \"\"\"\n  tell application \"x\"\n    delay 0.4\n  end tell\n\"\"\"\n"
        }
        let violations = LatencyBudgetScan.evaluateSleeps(scan, baseline: try Self.sleepBaseline())
        #expect(violations.contains { $0.contains("applescript-delay") })
    }

    @Test func mutantRaisingAnExistingSleepIsRefused() throws {
        let scan = try Self.mutatedScan(replacing: "Channels/AccessibilityChannel+Regions.swift") {
            $0.replacingOccurrences(of: "nanoseconds: 350_000_000", with: "nanoseconds: 900_000_000")
        }
        let violations = LatencyBudgetScan.evaluateSleeps(scan, baseline: try Self.sleepBaseline())
        #expect(violations.contains { $0.contains("new fixed sleep") })
        #expect(violations.contains { $0.contains("budget exceeded") })
    }

    @Test func mutantRemovingASleepWithoutLoweringTheBaselineIsRefused() throws {
        let scan = try Self.mutatedScan(replacing: "Channels/AccessibilityChannel+Regions.swift") {
            $0.replacingOccurrences(of: "nanoseconds: 350_000_000", with: "nanoseconds: 0")
        }
        let violations = LatencyBudgetScan.evaluateSleeps(scan, baseline: try Self.sleepBaseline())
        #expect(violations.contains { $0.contains("baseline is stale") })
    }

    @Test func aCommentOrStringNamingASleepIsNotASite() {
        let scan = LatencyBudgetScan.scan(source: """
        // usleep(900_000) Thread.sleep(forTimeInterval: 3)
        let text = "Task.sleep(nanoseconds: 1_000_000_000) and usleep(5)"
        func quiet() {}
        """, file: "X.swift")
        #expect(scan.sleeps.isEmpty)
    }

    @Test func mutantAClickAddedToANewFileIsRefused() throws {
        var scan = try LatencyBudgetScan.sharedTree()
        scan.mouse += LatencyBudgetScan.scan(source: """
        func tap(_ p: CGPoint) { _ = AXMouseHelper.click(at: p) }
        """, file: "Dispatchers/NewDispatcher.swift").mouse
        let violations = LatencyBudgetScan.evaluateMouse(scan, baseline: try Self.mouseBaseline())
        #expect(violations.contains { $0.contains("new synthetic-mouse site in Dispatchers/NewDispatcher.swift") })
    }

    @Test func mutantAnExtraCursorWarpInAnAllowedFileIsRefused() throws {
        let scan = try Self.mutatedScan(replacing: "Accessibility/LibraryAccessor.swift") {
            $0 + "\nfunc hop(_ p: CGPoint) { CGWarpMouseCursorPosition(p) }\n"
        }
        let violations = LatencyBudgetScan.evaluateMouse(scan, baseline: try Self.mouseBaseline())
        #expect(violations.contains { $0.contains("grew in Accessibility/LibraryAccessor.swift") })
    }

    @Test func mutantARawCGEventMouseConstructionIsRefused() throws {
        let scan = LatencyBudgetScan.scan(source: """
        func press(_ s: CGEventSource?, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: s, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
            e?.post(tap: .cghidEventTap)
        }
        """, file: "Channels/Anywhere.swift")
        #expect(scan.mouse.count >= 2)
        var tree = try LatencyBudgetScan.sharedTree()
        tree.mouse += scan.mouse
        #expect(!LatencyBudgetScan.evaluateMouse(tree, baseline: try Self.mouseBaseline()).isEmpty)
    }

    @Test func mutantRemovingAMouseSiteWithoutLoweringTheBaselineIsRefused() throws {
        var scan = try LatencyBudgetScan.sharedTree()
        scan.mouse.removeAll { $0.key.hasPrefix("Workflows/OwnedAuxLifecycle.swift|") }
        let violations = LatencyBudgetScan.evaluateMouse(scan, baseline: try Self.mouseBaseline())
        #expect(violations.contains { $0.contains("stale for Workflows/OwnedAuxLifecycle.swift") })
    }

    @Test func mutantAMouseSiteWithoutAMeasuredReasonIsRefused() throws {
        var baseline = try Self.mouseBaseline()
        let file = try #require(baseline.files.keys.sorted().first)
        baseline.files[file]?.reason = "needed"
        baseline.files[file]?.evidence = ""
        let violations = LatencyBudgetScan.evaluateMouse(try LatencyBudgetScan.sharedTree(), baseline: baseline)
        #expect(violations.contains { $0.contains("no reason") })
        #expect(violations.contains { $0.contains("no evidence") })
    }
}
