import ApplicationServices
import Foundation
import Testing

@testable import LogicProMCP

/// `logic://project/info` reported `name` as the whole title of Logic's main window, and Logic
/// titles that window `<project> - <view>` with the view in its own UI language. Measured
/// 2026-09-27 on Logic 12.3 with one project open: `lpm-locale-campaign - Tracks` in English,
/// `… - 트랙` in Korean, `… - トラック` in Japanese, `… - Spuren` in German, `… - Pistas` in Spanish
/// and Portuguese, `… - Pistes` in French, `… - Tracce` in Italian, `… - 轨道` in Simplified and
/// `… - 音軌` in Traditional Chinese. The `prj_` descriptor is built from that name, so one project
/// had ten descriptors.
///
/// The spellings here are the ones `AXLocalePolicy.arrangeWindowTitleSuffix` carries; the first
/// test pins that the set under test IS the policy's set, so a label added to the policy without a
/// row here fails rather than going untested.
@Suite("#1022 logic://project/info names the project, not the arrange view")
struct Issue1022ProjectNameFromWindowTitleTests {
    /// Nine spellings for ten languages: Spanish and Portuguese both read `Pistas`.
    private static let measuredSuffixes: [String] = [
        "Tracks", "트랙", "トラック", "Spuren", "Pistas", "Pistes", "Tracce", "轨道", "音軌",
    ]

    private static let project = "lpm-locale-campaign"

    @Test("the suffixes under test are exactly the ones the policy carries")
    func suffixesUnderTestArePolicySet() {
        #expect(Set(Self.measuredSuffixes) == Set(AXLocalePolicy.arrangeWindowTitleSuffix.labels))
        #expect(Self.measuredSuffixes.count == 9)
    }

    @Test("every measured suffix is stripped from the title", arguments: measuredSuffixes)
    func suffixIsStripped(suffix: String) {
        let title = "\(Self.project) - \(suffix)"
        #expect(AccessibilityChannel.projectName(fromWindowTitle: title) == Self.project)
        let components = AccessibilityChannel.arrangeWindowTitleComponents(title)
        #expect(components?.projectName == Self.project)
        #expect(components?.viewSuffix == suffix)
    }

    @Test("a title without a known suffix is reported as it reads, not guessed at")
    func unknownSuffixIsLeftAlone() {
        let unchanged = [
            Self.project,
            "\(Self.project) - Something Else",
            "\(Self.project) -Tracks",
            "\(Self.project) - tracks",
            "Choose a Project",
            "Unknown",
            "",
        ]
        for title in unchanged {
            #expect(AccessibilityChannel.projectName(fromWindowTitle: title) == title, "\(title)")
            #expect(AccessibilityChannel.arrangeWindowTitleComponents(title) == nil, "\(title)")
        }
    }

    @Test("a title that is only the suffix is not a project name", arguments: measuredSuffixes)
    func bareSuffixIsLeftAlone(suffix: String) {
        for title in [suffix, " - \(suffix)", "- \(suffix)", "   - \(suffix)"] {
            #expect(AccessibilityChannel.projectName(fromWindowTitle: title) == title, "\(title)")
            #expect(AccessibilityChannel.arrangeWindowTitleComponents(title) == nil, "\(title)")
            #expect(!AccessibilityChannel.isCreatedProjectWindowTitle(title), "\(title)")
        }
    }

    @Test("only the last suffix is stripped from a name that itself contains ' - '")
    func onlyTheLastSuffixIsStripped() {
        #expect(AccessibilityChannel.projectName(fromWindowTitle: "Verse - Take 2 - Tracks") == "Verse - Take 2")
        #expect(AccessibilityChannel.projectName(fromWindowTitle: "Take 2 - Tracks - Tracks") == "Take 2 - Tracks")
        #expect(AccessibilityChannel.projectName(fromWindowTitle: "Tracks - Tracks") == "Tracks")
        #expect(AccessibilityChannel.projectName(fromWindowTitle: "a - 트랙 - トラック") == "a - 트랙")
        #expect(AccessibilityChannel.projectName(fromWindowTitle: "a - Tracks - 트랙") == "a - Tracks")
    }

    @Test("the created-project witness and the name share one rule", arguments: measuredSuffixes)
    func witnessAgreesWithTheName(suffix: String) {
        let title = "\(Self.project) - \(suffix)"
        #expect(AccessibilityChannel.isCreatedProjectWindowTitle(title))
        #expect(AccessibilityChannel.isCreatedProjectWindowTitle("  \(title)  "))
        #expect(AccessibilityChannel.projectName(fromWindowTitle: "  \(title)  ") == Self.project)
    }

    @Test("one project has one descriptor in every language")
    func descriptorIsTheSameInEveryLanguage() {
        let path = "/Users/someone/Music/Logic/\(Self.project).logicx"
        let fingerprints = Set(Self.measuredSuffixes.compactMap { suffix -> String? in
            let name = AccessibilityChannel.projectName(fromWindowTitle: "\(Self.project) - \(suffix)")
            return ProjectReferenceIssuance.descriptor(name: name, filePath: path, epoch: 7)?.fingerprint
        })
        #expect(fingerprints.count == 1)
        // The control: the raw titles, which is what the descriptor used to be built from, give
        // one fingerprint per spelling. Without it the assertion above could pass on a descriptor
        // that ignores its name.
        let rawFingerprints = Set(Self.measuredSuffixes.compactMap { suffix -> String? in
            ProjectReferenceIssuance.descriptor(name: "\(Self.project) - \(suffix)", filePath: path, epoch: 7)?.fingerprint
        })
        #expect(rawFingerprints.count == Self.measuredSuffixes.count)
    }

    @Test("project.get_info through the runtime seam yields the stripped name", arguments: measuredSuffixes)
    func getProjectInfoYieldsTheStrippedName(suffix: String) throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(2)
        // No AXWindows on the app: `mainWindow` then falls back to AXMainWindow, which is the
        // shape every other minimal fixture in this suite builds.
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(window, kAXTitleAttribute as String, "\(Self.project) - \(suffix)")
        let runtime = builder.makeLogicRuntime(appElement: app)

        let result = AccessibilityChannel.defaultGetProjectInfo(runtime: runtime)
        guard case .success(let json) = result else {
            Issue.record("expected success, got \(result.message)")
            return
        }
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["name"] as? String == Self.project)
    }

    @Test("project.get_info reports a title without a known suffix as it reads")
    func getProjectInfoLeavesAnUnknownTitleAlone() throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(2)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(window, kAXTitleAttribute as String, "\(Self.project) - Something Else")
        let runtime = builder.makeLogicRuntime(appElement: app)

        let result = AccessibilityChannel.defaultGetProjectInfo(runtime: runtime)
        guard case .success(let json) = result else {
            Issue.record("expected success, got \(result.message)")
            return
        }
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["name"] as? String == "\(Self.project) - Something Else")
    }
}
