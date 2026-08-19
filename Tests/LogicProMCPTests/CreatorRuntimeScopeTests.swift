import Testing
@testable import LogicProMCP

/// The runtime must not select a variant the release matrix does not cover.
///
/// `QualificationAxis.shipVariants` is `[.desktop]` and the ADR records Creator Studio as
/// permanently out of scope. #631 corrected the README's claim of supporting both; this is the
/// other half — the code path that could still hand back Creator as the app to drive.
@Suite struct CreatorRuntimeScopeTests {
    private static func app(_ path: String, _ bundleID: String?) -> SetupDoctor.LogicAppInfo {
        SetupDoctor.LogicAppInfo(
            path: path,
            version: LogicProSupport.latestValidatedLogicVersion,
            bundleID: bundleID,
            readable: true
        )
    }

    @Test("Creator Studio alone is not selected as the app to drive")
    func creatorAloneIsNotPreferred() {
        let apps = [Self.app("/Applications/Logic Pro Creator Studio.app",
                             LogicProVariant.creatorStudio.bundleID)]
        // Before: fell through to the creatorStudio branch and returned it, so the doctor reported
        // a version and the server proceeded against a variant nothing has qualified.
        #expect(SetupDoctor.preferredLogicApp(apps) == nil)
        #expect(SetupDoctor.unshippedVariantOnly(apps))
    }

    @Test("an unrelated app is not selected either")
    func unrelatedAppIsNotPreferred() {
        // The old catch-all was `?? apps.first`, which could return something that is not Logic.
        let apps = [Self.app("/Applications/Not Logic.app", "com.example.other")]
        #expect(SetupDoctor.preferredLogicApp(apps) == nil)
        #expect(!SetupDoctor.unshippedVariantOnly(apps),
                "no Creator present, so this is not the out-of-scope case")
    }

    @Test("desktop is still selected, and preferred over Creator when both are installed")
    func desktopIsSelected() {
        let desktop = Self.app("/Applications/Logic Pro.app", LogicProVariant.desktop.bundleID)
        let creator = Self.app("/Applications/Logic Pro Creator Studio.app",
                               LogicProVariant.creatorStudio.bundleID)
        #expect(SetupDoctor.preferredLogicApp([desktop]) == desktop)
        // Creator FIRST in the list: passing by array order is not enough.
        #expect(SetupDoctor.preferredLogicApp([creator, desktop]) == desktop)
        #expect(!SetupDoctor.unshippedVariantOnly([creator, desktop]))
    }

    @Test("nothing installed is not the out-of-scope case")
    func emptyIsNotUnshipped() {
        #expect(SetupDoctor.preferredLogicApp([]) == nil)
        #expect(!SetupDoctor.unshippedVariantOnly([]))
    }

    @Test("the ship scope this rests on is desktop only")
    func shipScopeIsDesktopOnly() {
        // If this ever changes, the checks above are the ones to revisit rather than delete.
        #expect(QualificationAxis.shipVariants == [.desktop])
    }
}
