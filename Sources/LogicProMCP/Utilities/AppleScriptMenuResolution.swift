import Foundation

/// Generates the localized-menu candidate-resolution AppleScript snippet used by every
/// generated menu-bar/menu-item click site (#519).
///
/// `AXLocalePolicy` already carries every locale variant Logic's top-level menu titles and
/// menu items are known to use — for example `fileMenuBar` lists `"File"`, `"파일"`, AND
/// `"ファイル"` — but the AppleScript call sites that clicked through the File/Navigate/Edit
/// menus hard-coded only one or two of those names inline. The table looked like it supported
/// a locale (Japanese) that no call site could actually reach. Routing every menu-drive site
/// through this generator, instead of a hand-written literal, is what keeps that gap from
/// reopening: a variant added to `AXLocalePolicy` becomes reachable everywhere this helper is
/// used, with no call site to remember to update, and a future site that skips this helper and
/// writes a quoted literal name straight after the `menu bar item` keyword again is caught by
/// `Scripts/ci-forbid-hardcoded-menu-bar-item.sh` (registered in `.github/workflows/ci.yml` next
/// to the dead-`#expect` gate).
///
/// The generated script never assumes an index or a single name: it tries each label —
/// canonical first, then variants, in the order `LabelSet.labels` returns them — and uses the
/// first one AppleScript reports `exists`. A given running Logic only ever exposes ONE of a
/// LabelSet's labels (its actual UI language), so trying canonical before a locale variant does
/// not change which one an actual run picks; it only fixes the order candidates are probed in.
enum AppleScriptMenuResolution {
    /// Emits:
    /// ```applescript
    /// set <variableName> to missing value
    /// repeat with candidate in {"canonical", "variant1", ...}
    ///     if exists <elementKeyword> candidate<existsSuffix> then
    ///         set <variableName> to candidate as text
    ///         exit repeat
    ///     end if
    /// end repeat
    /// if <variableName> is missing value then error "<notFoundError>"
    /// ```
    ///
    /// `existsSuffix` is the AppleScript text that completes the `exists` specifier right after
    /// the bare `candidate` token — for example `" of menu bar 1"` for a top-level menu-bar
    /// item, or `" of menu 1 of menu bar item barName of menu bar 1"` for a submenu item nested
    /// under an already-resolved bar variable. `elementKeyword` is `"menu bar item"` or
    /// `"menu item"`, interpolated as plain AppleScript vocabulary — never followed directly by
    /// a quote, so this generator itself never trips the hard-coded-literal guard.
    ///
    /// Labels are escaped with `AppleScriptSafety.escapeForScript`, the same helper the rest of
    /// the AppleScript builders use, so a variant containing a `"` or `\` cannot break out of the
    /// `{...}` list literal.
    ///
    /// On failure the loop raises `error "<notFoundError>"` (an ordinary AppleScript error) —
    /// callers that already wrap the resolution in `try ... on error errMsg ... end try` catch it
    /// exactly like any other menu-not-found failure and keep their existing cleanup/Escape path.
    static func candidateResolution(
        elementKeyword: String,
        labelSet: AXLocalePolicy.LabelSet,
        existsSuffix: String,
        variableName: String,
        notFoundError: String
    ) -> String {
        let literals = labelSet.labels
            .map { "\"\(AppleScriptSafety.escapeForScript($0))\"" }
            .joined(separator: ", ")
        return """
        set \(variableName) to missing value
        repeat with candidate in {\(literals)}
            if exists \(elementKeyword) candidate\(existsSuffix) then
                set \(variableName) to candidate as text
                exit repeat
            end if
        end repeat
        if \(variableName) is missing value then error "\(notFoundError)"
        """
    }

    /// Resolves a WINDOW by localized title suffix, in the order the LabelSet lists.
    ///
    /// Window titles are `"<project name> - <localized view name>"`, so this matches by
    /// `ends with` rather than by element name. The `try` around each attempt is load-bearing:
    /// `first window whose name ends with ...` raises `-1719` when nothing matches, which would
    /// abort the whole script instead of moving on to the next locale's suffix.
    ///
    /// This exists because the marker-menu script hard-coded an English and a Korean suffix as a
    /// `try`/`on error` pair. On a Japanese Logic both lookups failed, the script errored, and
    /// `create_marker` reported `Navigate > Create Marker was not found or could not be pressed` —
    /// a locale gap wearing the costume of a missing menu item. Measured live on 2026-08-17: the
    /// menu names were already resolved from a LabelSet; only the window lookup was not.
    static func windowWithTitleSuffix(
        _ labelSet: AXLocalePolicy.LabelSet,
        variableName: String,
        notFoundError: String
    ) -> String {
        let literals = labelSet.labels
            .map { "\"\(AppleScriptSafety.escapeForScript($0))\"" }
            .joined(separator: ", ")
        return """
        set \(variableName) to missing value
        repeat with candidate in {\(literals)}
            try
                set \(variableName) to first window whose name ends with candidate
                exit repeat
            end try
        end repeat
        if \(variableName) is missing value then error "\(notFoundError)"
        """
    }

    /// Convenience for a top-level menu-bar item: `menu bar item <name> of menu bar 1`.
    static func menuBarItem(
        _ labelSet: AXLocalePolicy.LabelSet,
        variableName: String,
        notFoundError: String
    ) -> String {
        candidateResolution(
            elementKeyword: "menu bar item",
            labelSet: labelSet,
            existsSuffix: " of menu bar 1",
            variableName: variableName,
            notFoundError: notFoundError
        )
    }

    /// Convenience for a menu item nested one level under an already-resolved parent
    /// specifier (a resolved `menu bar item` variable or a resolved `menu item` variable).
    /// `parentSpecifier` is the exact AppleScript specifier text the item lives under, e.g.
    /// `"menu bar item barName of menu bar 1"` or
    /// `"menu item goToName of menu 1 of menu bar item barName of menu bar 1"`.
    static func menuItem(
        _ labelSet: AXLocalePolicy.LabelSet,
        under parentSpecifier: String,
        variableName: String,
        notFoundError: String
    ) -> String {
        candidateResolution(
            elementKeyword: "menu item",
            labelSet: labelSet,
            existsSuffix: " of menu 1 of \(parentSpecifier)",
            variableName: variableName,
            notFoundError: notFoundError
        )
    }
}
