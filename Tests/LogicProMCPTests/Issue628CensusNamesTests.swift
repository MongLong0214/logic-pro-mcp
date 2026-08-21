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

    /// **These five exist because the first version of `names()` was a `??` chain**, which falls
    /// through on nil ONLY. AX returns present-but-empty strings routinely, so an element with
    /// `description == ""` and `title == "Mixer"` stopped at the empty description and reported
    /// `<unnamed AXGroup>`: the fallback was written, shipped, and unreachable. The original tests
    /// covered "description present" and "everything absent" and missed the entire middle.
    @Test("an empty description falls through to the title")
    func emptyDescriptionFallsThroughToTitle() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6550)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        let g = group(b, 6551, description: "")
        b.setAttribute(g, kAXTitleAttribute as String, "Mixer")
        b.setChildren(root, [g])

        let names = AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole as String, maxDepth: 4, runtime: b.makeAXRuntime()
        ).names(runtime: b.makeAXRuntime())
        #expect(names == ["Mixer"])
    }

    @Test("an empty description and empty title fall through to the identifier")
    func emptyPairFallsThroughToIdentifier() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6560)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        let g = group(b, 6561, description: "")
        b.setAttribute(g, kAXTitleAttribute as String, "")
        b.setAttribute(g, kAXIdentifierAttribute as String, "transport-rail")
        b.setChildren(root, [g])

        let names = AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole as String, maxDepth: 4, runtime: b.makeAXRuntime()
        ).names(runtime: b.makeAXRuntime())
        #expect(names == ["transport-rail"])
    }

    /// A whitespace-only description passed `!isEmpty` and became the name — producing exactly the
    /// blank entry the placeholder exists to prevent, while looking like a successful read.
    @Test("a whitespace-only description is not a name")
    func whitespaceIsNotAName() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6570)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        let g = group(b, 6571, description: "   ")
        b.setChildren(root, [g])

        let names = AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole as String, maxDepth: 4, runtime: b.makeAXRuntime()
        ).names(runtime: b.makeAXRuntime())
        #expect(names == ["<unnamed AXGroup>"])
        #expect(!names.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// The LabelSet census is a SECOND producer of `Census`. Dropping `matches:` from it alone left
    /// every other case here green — nothing covered it, which is how a second implementation of
    /// the same contract goes uncovered.
    @Test("the LabelSet census names its candidates too")
    func labelSetCensusNamesCandidates() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6580)
        b.setAttribute(root, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(root, [group(b, 6581, description: "Control Bar"),
                             group(b, 6582, description: "Control Bar")])

        let census = AXLocalePolicy.censusDescendant(
            of: root,
            role: kAXGroupRole as String,
            matching: AXLocalePolicy.LabelSet(canonical: "Control Bar", variants: [],
                                              rationale: "test"),
            mode: .exactStrict,
            maxDepth: 4,
            runtime: b.makeAXRuntime())
        #expect(census.candidates == 2)
        #expect(census.element == nil)
        #expect(census.names(runtime: b.makeAXRuntime()) == ["Control Bar", "Control Bar"])
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
