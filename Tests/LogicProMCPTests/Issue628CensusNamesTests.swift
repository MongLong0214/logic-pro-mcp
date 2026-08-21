@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #628 states two things that must be demonstrable:
///
///     two candidates exist   ->  refused, and both are named
///     one candidate exists   ->  recorded as one, not merely accepted
///
/// The second was already met — `Census.isUnambiguous`, carried into the probe payload and asserted
/// in live evidence. The first was met only HALFWAY: `censusDescendant` computed every match, kept
/// the count, and threw the matches away. So it refused without saying which two, and "2 matched"
/// cannot distinguish a genuinely ambiguous tree from a selector one word too broad.
///
/// These cases pin the naming, including the case that would otherwise print as `["", "", ""]`.
@Suite("Issue #628 — an ambiguous census names its candidates")
struct Issue628CensusNamesTests {

    private func group(_ b: FakeAXRuntimeBuilder, _ id: Int, description: String?) -> AXUIElement {
        let g = b.element(id)
        b.setAttribute(g, kAXRoleAttribute as String, kAXGroupRole as String)
        if let description {
            b.setAttribute(g, kAXDescriptionAttribute as String, description)
        }
        b.setChildren(g, [])
        return g
    }

    @Test("two matches are refused AND both are named")
    func twoMatchesAreNamed() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6500)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(root, [group(b, 6501, description: "Control Bar"),
                             group(b, 6502, description: "Control Bar")])

        let census = AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole as String, maxDepth: 4, runtime: b.makeAXRuntime())

        #expect(census.candidates == 2)
        #expect(census.element == nil)          // refused
        #expect(!census.isUnambiguous)
        // ...and it can say WHICH two. This is the half that was missing.
        #expect(census.names(runtime: b.makeAXRuntime()) == ["Control Bar", "Control Bar"])
    }

    /// The names must come off the ELEMENTS, not be re-derived from the query — two candidates that
    /// matched a role-only lookup can be called different things, and a refusal that flattened them
    /// to one label would hide exactly the case worth seeing.
    @Test("candidates that call themselves different things are reported separately")
    func distinctNamesSurvive() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6510)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(root, [group(b, 6511, description: "Tracks header"),
                             group(b, 6512, description: "Tracks contents")])

        let census = AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole as String, maxDepth: 4, runtime: b.makeAXRuntime())
        #expect(census.names(runtime: b.makeAXRuntime()) == ["Tracks header", "Tracks contents"])
    }

    /// An element with nothing to call itself must not print as `""`. Three anonymous groups
    /// reported as `["", "", ""]` read as a bug in the reporter rather than a fact about the tree,
    /// and the person holding that refusal learns nothing at all.
    @Test("an unnamed candidate reports its role rather than an empty string")
    func unnamedCandidatesSaySo() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6520)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(root, [group(b, 6521, description: nil), group(b, 6522, description: nil)])

        let names = AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole as String, maxDepth: 4, runtime: b.makeAXRuntime()
        ).names(runtime: b.makeAXRuntime())
        #expect(names == ["<unnamed AXGroup>", "<unnamed AXGroup>"])
        #expect(!names.contains(""))
    }

    /// The one-match path must not start paying for names it does not need, and must still report
    /// the match itself.
    @Test("a single match is identified and its match list holds exactly it")
    func oneMatchStillIdentifies() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6530)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        let only = group(b, 6531, description: "Mixer")
        b.setChildren(root, [only])

        let census = AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole as String, maxDepth: 4, runtime: b.makeAXRuntime())
        #expect(census.isUnambiguous)
        #expect(census.matches.count == 1)
        let found = try #require(census.element)
        #expect(CFEqual(found, only))
    }

    @Test("no match names nothing, and does not fabricate an entry")
    func noMatchNamesNothing() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6540)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(root, [])

        let census = AXHelpers.censusDescendant(
            of: root, role: kAXSliderRole as String, maxDepth: 4, runtime: b.makeAXRuntime())
        #expect(census.candidates == 0)
        #expect(census.matches.isEmpty)
        #expect(census.names(runtime: b.makeAXRuntime()).isEmpty)
    }
}
