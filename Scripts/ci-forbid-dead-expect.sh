#!/bin/bash
# CI lint (#393): forbid DEAD swift-testing boolean expectations.
#
# On this toolchain `#expect(<Bool> == true/false)` PASSES UNCONDITIONALLY (`#expect(true == false)`
# passes) — the assertion proves nothing. The same holds for `!= true/false`, `?? true/false`,
# `== .some(<Bool>)`, and for the `#require(<Bool> == true/false)` macro. Load-bearing spellings:
# bare `#expect(x)` / `#expect(!x)`; for Optionals `let v = try #require(x)` then a bare
# `#expect(v)` (or `#expect(try #require(x))`).
#
# This scanner is span- and closure-aware (a line-based grep misses the dead spelling when the
# `#expect(...)` call wraps across lines, when the dead operator lives in `#require(...)`, or when
# the line merely *contains* a closure whose `== true` is legitimate while a SECOND, top-level
# `== true` on the same line is dead). It:
#   - extracts each `#expect(...)` / `#require(...)` call with balanced parens (multiline OK),
#   - blanks string literals (so `== true` inside a message string is not counted),
#   - removes balanced `{...}` closure bodies (so `.filter { $0 == true }` stays live),
#   - then flags the dead operators in what remains.
#
# Not flagged (LIVE): comparisons inside closures; string/int/enum-VALUE `==`; `== .none`
# (a real enum-case comparison in this codebase — Optional<Bool> uses `== nil`); comment lines;
# and any call carrying an explicit `// test-integrity:live` suppression (each such use must
# justify why the spelling is genuinely load-bearing — e.g. a `Bool == Bool` of two non-literals,
# or a literal that only appears inside a message string).
#
# Exit 1 (fail CI) on any dead site.
set -uo pipefail
ROOT="${1:-.}"
cd "$ROOT" || { echo "FATAL: bad root $ROOT"; exit 2; }

python3 - <<'PY'
import sys, re, glob, bisect

# Dead operators, checked against a call with strings blanked and closures removed:
#   RHS literal:  x == true / x != false
#   LHS literal:  true == x / false != x   (lookbehind avoids `.true` / `footrue`)
#   coalesce:     x ?? true / x ?? false   (see the known over-flag note below)
#   some-wrap:    x == .some(...) / x == Optional.some(...)
# Known safe over-flag: a NESTED `?? true/false` inside a live top-level `Bool == Bool`
# (e.g. `#expect((opt ?? false) == other)`) is flagged too; annotate such a line with
# `// test-integrity:live:` — the lint errs toward flagging (never toward missing dead code).
# NB: no `\(*`/`\)*` around the literals — a parenthesised `(true)` is not worth matching
# and doing so mis-fires on `foo(label: true) == .enumCase` (a call argument followed by a
# live enum comparison). Comment-stripping below covers `== /* x */ true`.
DEAD = re.compile(
    r'(==|!=)\s*(true|false)\b'
    r'|(?<![.\w])(true|false)\s*(==|!=)'
    r'|\?\?\s*(true|false)\b'
    r'|==\s*(?:Optional\s*(?:<[^>]*>)?\s*)?\.some\s*\('
)

def calls(text):
    """Yield (start_offset, call_text) for each #expect(/#require( with a balanced-paren arg."""
    for m in re.finditer(r'#(?:expect|require)\s*\(', text):
        depth, j = 0, m.end() - 1  # position of the opening '('
        while j < len(text):
            c = text[j]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        yield m.start(), text[m.start():j + 1]

def blank_strings(s):
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', s)

def strip_comments(s):
    # blank block and line comments so trivia between an operator and a literal
    # (e.g. `== /* x */ true`) cannot hide a dead spelling. Runs AFTER blank_strings
    # so a `//` or `/*` inside a string literal is already gone.
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.DOTALL)
    s = re.sub(r'//[^\n]*', ' ', s)
    return s

def drop_closures(s):
    out, depth = [], 0
    for c in s:
        if c == '{':
            depth += 1
        elif c == '}':
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(c)
    return ''.join(out)

hits = []
for f in sorted(glob.glob('Tests/**/*.swift', recursive=True)):
    lines = open(f, encoding='utf-8').read().split('\n')
    text = '\n'.join(lines)
    starts = [0]
    for ln in lines:
        starts.append(starts[-1] + len(ln) + 1)
    for off, call in calls(text):
        lineno = bisect.bisect_right(starts, off)
        raw = lines[lineno - 1]
        if 'test-integrity:live' in call or 'test-integrity:live' in raw:
            continue
        if re.match(r'\s*(//|///|\*)', raw):
            continue
        if DEAD.search(drop_closures(strip_comments(blank_strings(call)))):
            hits.append((f, lineno, raw.strip()[:110]))

if hits:
    print("::error::Dead swift-testing boolean expectations found (#393). These pass unconditionally.")
    print("Convert to bare #expect(x)/#expect(!x); for Optionals: let v = try #require(x); #expect(v).")
    print("If genuinely load-bearing (literal only inside a message string, or a top-level Bool==Bool), append '// test-integrity:live: <reason>'.")
    for f, l, t in hits:
        print(f"{f}:{l}: {t}")
    print("COUNT:", len(hits))
    sys.exit(1)
print("OK: no dead boolean #expect/#require spellings in Tests/ (#393 test-integrity)")
PY
