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

# swift-testing on this toolchain also fails to evaluate a Boolean
# labelled-tuple `expected` comparison inside a loop. In particular, this
# superficially sensible table test passes even if `actual` is hard-coded:
#
#     for testCase in cases { #expect(actual == testCase.expected) }
#
# Catch both equality directions at the macro argument level, after relating a
# loop variable to a Boolean tuple collection. The field is deliberately named
# `expected`: matching any tuple field incorrectly flags ordinary tests such as
# `#expect(actualName == testCase.name)`.
LABELLED_TUPLE_LOOP = re.compile(
    r'\bfor\s+(?P<variable>[A-Za-z_]\w*)\s+in\s+(?P<collection>[A-Za-z_]\w*)\s*\{'
)

# This compiler bug is specific to Bool expectations. A collection can state
# that type explicitly or infer it from a labelled `expected: true/false`
# literal; both forms need coverage. Other labelled tuples (for example, enum
# equality) remain ordinary live comparisons and must not be swept into this
# Boolean-integrity lint.
BOOL_LABELLED_TUPLE_COLLECTION = re.compile(
    r'\b(?:let|var)\s+(?P<collection>[A-Za-z_]\w*)\s*:\s*'
    r'\[\([^\]]*\bexpected\s*:\s*Bool\b[^\]]*\)\]'
)
INFERRED_BOOL_LABELLED_TUPLE_COLLECTION = re.compile(
    r'\b(?:let|var)\s+(?P<collection>[A-Za-z_]\w*)\s*=\s*'
    r'\[\s*\([^\]]*?\bexpected\s*:\s*(?:true|false)\b',
    re.DOTALL,
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
    # Preserve offsets (and newlines) because findings are reported against the
    # original source. A short replacement shifts every later line lookup and
    # can make a real loop finding appear to be inside an unrelated string.
    return re.sub(
        r'"(?:\\.|[^"\\])*"',
        lambda match: ''.join('\n' if char == '\n' else ' ' for char in match.group()),
        s,
    )

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

def balanced_brace_end(s, opening):
    """Return the matching `}` for a `{` at opening, or None when incomplete."""
    depth = 0
    for index in range(opening, len(s)):
        if s[index] == '{':
            depth += 1
        elif s[index] == '}':
            depth -= 1
            if depth == 0:
                return index
    return None

def top_level_equality_operands(call):
    """Return the two sides of a top-level `==` in a macro call, if present."""
    opening = call.find('(')
    if opening < 0 or not call.endswith(')'):
        return None
    expression = call[opening + 1:-1]
    depth, index = 0, 0
    equality = None
    while index < len(expression):
        char = expression[index]
        if char in '([{':
            depth += 1
        elif char in ')]}':
            depth = max(0, depth - 1)
        elif depth == 0 and expression.startswith('==', index):
            if equality is not None:
                return None
            equality = index
            index += 1
        elif depth == 0 and char == ',':
            break
        index += 1
    if equality is None:
        return None
    return expression[:equality], expression[equality + 2:index]

def expected_tuple_field(operand, variable):
    # Parenthesised operands are accepted, but the field itself must be exactly
    # `<loop-variable>.expected`; `.name` and any other tuple member stay live.
    return re.fullmatch(
        rf'\s*(?:\(\s*)*{re.escape(variable)}\s*\.\s*expected(?:\s*\))*\s*',
        operand,
    ) is not None

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
    # The labelled-tuple loop form is dead independently of literal Bool
    # comparisons, so relate each loop to a Boolean collection and inspect
    # `#expect` calls inside its balanced body. Report the #expect line, not
    # the loop line, for a direct fix.
    cleaned = strip_comments(blank_strings(text))
    bool_labelled_tuple_collections = {
        match.group('collection')
        for match in BOOL_LABELLED_TUPLE_COLLECTION.finditer(cleaned)
    }
    bool_labelled_tuple_collections.update(
        match.group('collection')
        for match in INFERRED_BOOL_LABELLED_TUPLE_COLLECTION.finditer(cleaned)
    )
    cleaned_calls = list(calls(cleaned))
    for match in LABELLED_TUPLE_LOOP.finditer(cleaned):
        if match.group('collection') not in bool_labelled_tuple_collections:
            continue
        closing = balanced_brace_end(cleaned, match.end() - 1)
        if closing is None:
            continue
        for expect_offset, call in cleaned_calls:
            if not (match.end() <= expect_offset < closing):
                continue
            lineno = bisect.bisect_right(starts, expect_offset)
            raw = lines[lineno - 1]
            if 'test-integrity:live' in call or 'test-integrity:live' in raw:
                continue
            operands = top_level_equality_operands(call)
            if operands is None:
                continue
            lhs, rhs = operands
            if expected_tuple_field(lhs, match.group('variable')) or expected_tuple_field(rhs, match.group('variable')):
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
