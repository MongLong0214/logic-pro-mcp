@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #628: `findDescendant` returns the first match in traversal order and nothing records that there
/// was only one. When it is right, nothing says it was right for a reason rather than by luck — and
/// that silence is the defect, not the choosing.
///
/// `AXLocalePolicy.censusDescendant` (from #633) is the counting form for lookups that match a
/// localized `LabelSet`. This is the counting form for the other half: `role` / `title` /
/// `identifier` matched exactly. They stay two functions on purpose — a `LabelSet` is a set of
/// human-facing labels in whatever language Logic runs in, an `AXIdentifier` is a stable
/// non-localized name, and putting a locale question and an identity question behind one parameter
/// invites a lookup that "works in English".
///
/// What these tests do NOT establish: that any particular call site is unambiguous live. The count
/// is a property of the tree the walk ran on. `getControlBar` was a *discriminated* loop that still
/// had two candidates, so "has a discriminator" and "resolves to one" are different facts and only
/// the second one is what this returns.
@Suite("Issue #628 — a descendant lookup that reports how many it found")
struct Issue628CountingLocatorTests {

    /// Two elements a `role`-only lookup cannot tell apart. `findDescendant` answers with the first
    /// and no complaint; the census refuses and says two.
    @Test("two matches: no element, and the count is what says why")
    func twoMatchesRefuse() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6281)
        let first = b.element(6282)
        let second = b.element(6283)
        b.setAttribute(first, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(second, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setChildren(root, [first, second])
        let runtime = b.makeAXRuntime()

        // The existing lookup is unchanged and still answers — that is the behaviour being
        // preserved, not a defect being left in place. Adoption is counted, not forced.
        let blind = AXHelpers.findDescendant(of: root, role: kAXButtonRole, runtime: runtime)
        #expect(blind != nil)

        let census = AXHelpers.censusDescendant(of: root, role: kAXButtonRole, runtime: runtime)
        #expect(census.candidates == 2)
        #expect(census.element == nil)
        #expect(census.isUnambiguous == false)
    }

    @Test("exactly one match: identified, and recorded as one")
    func oneMatchIsIdentified() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6284)
        let button = b.element(6285)
        let other = b.element(6286)
        b.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(other, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setChildren(root, [button, other])

        let census = AXHelpers.censusDescendant(
            of: root, role: kAXButtonRole, runtime: b.makeAXRuntime())
        #expect(census.candidates == 1)
        #expect(census.isUnambiguous)
        let found = try #require(census.element)
        #expect(CFEqual(found, button))
    }

    @Test("no match: zero, and zero is not one")
    func noMatch() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6287)
        let text = b.element(6288)
        b.setAttribute(text, kAXRoleAttribute as String, kAXStaticTextRole as String)
        b.setChildren(root, [text])

        let census = AXHelpers.censusDescendant(
            of: root, role: kAXButtonRole, runtime: b.makeAXRuntime())
        #expect(census.candidates == 0)
        #expect(census.element == nil)
        #expect(census.isUnambiguous == false)
    }

    /// The case that decides whether the number means anything: a match INSIDE another match.
    ///
    /// `findDescendant` stops at the outer one only because it returns it — had the outer node not
    /// matched, the walk would have descended. So both are things it could have returned under a
    /// different tree order, and counting only the outermost would report `1` for a tree the
    /// original can resolve two ways. That is the exact flattery this issue is about.
    @Test("a match nested inside a match counts, because the blind form could have returned either")
    func nestedMatchesBothCount() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6289)
        let outer = b.element(6290)
        let inner = b.element(6291)
        b.setAttribute(outer, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(inner, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(root, [outer])
        b.setChildren(outer, [inner])

        let census = AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole, runtime: b.makeAXRuntime())
        #expect(census.candidates == 2)
        #expect(census.element == nil)
    }

    /// Every criterion narrows, and all three are ANDed — the same rule `findDescendant` applies, so
    /// the two cannot disagree about what a match is.
    @Test("title and identifier narrow the same way findDescendant narrows")
    func criteriaAreAnded() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6292)
        let wanted = b.element(6293)
        let wrongTitle = b.element(6294)
        let wrongIdentifier = b.element(6295)
        for (node, title, ident) in [(wanted, "Play", "transport.play"),
                                     (wrongTitle, "Stop", "transport.play"),
                                     (wrongIdentifier, "Play", "transport.stop")] {
            b.setAttribute(node, kAXRoleAttribute as String, kAXButtonRole as String)
            b.setAttribute(node, kAXTitleAttribute as String, title)
            b.setAttribute(node, kAXIdentifierAttribute as String, ident)
        }
        b.setChildren(root, [wanted, wrongTitle, wrongIdentifier])
        let runtime = b.makeAXRuntime()

        let byRole = AXHelpers.censusDescendant(of: root, role: kAXButtonRole, runtime: runtime)
        #expect(byRole.candidates == 3)

        let byTitle = AXHelpers.censusDescendant(
            of: root, role: kAXButtonRole, title: "Play", runtime: runtime)
        #expect(byTitle.candidates == 2)

        let byBoth = AXHelpers.censusDescendant(
            of: root, role: kAXButtonRole, title: "Play", identifier: "transport.play",
            runtime: runtime)
        #expect(byBoth.candidates == 1)
        let found = try #require(byBoth.element)
        #expect(CFEqual(found, wanted))

        // The blind form agrees about WHICH element, and cannot say how many there were. Both
        // halves matter: if they disagreed, adopting the census would change behaviour rather than
        // report on it.
        let blind = try #require(AXHelpers.findDescendant(
            of: root, role: kAXButtonRole, title: "Play", identifier: "transport.play",
            runtime: runtime))
        #expect(CFEqual(blind, wanted))
    }

    /// `maxDepth` bounds the count as well as the search. A census that quietly searched deeper than
    /// the lookup it stands in for would report candidates the original could never have returned.
    @Test("maxDepth bounds the count, so it describes the same search")
    func depthBoundsTheCount() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6296)
        let level1 = b.element(6297)
        let level2 = b.element(6298)
        b.setAttribute(level1, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(level2, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(root, [level1])
        b.setChildren(level1, [level2])
        let runtime = b.makeAXRuntime()

        #expect(AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole, maxDepth: 1, runtime: runtime).candidates == 1)
        #expect(AXHelpers.censusDescendant(
            of: root, role: kAXGroupRole, maxDepth: 2, runtime: runtime).candidates == 2)
    }

    /// The label-matching census and this one are the same type now, not two structs that mean the
    /// same thing. They were declared separately for a while, which is how two copies of one idea
    /// start.
    @Test("both census forms return one type")
    func oneCensusType() throws {
        let b = FakeAXRuntimeBuilder()
        let root = b.element(6299)
        let census: AXLocalePolicy.Census = AXHelpers.censusDescendant(
            of: root, role: kAXButtonRole, runtime: b.makeAXRuntime())
        #expect(census.candidates == 0)
    }
}
