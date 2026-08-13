#!/bin/bash
# CI lint (#393): forbid DEAD swift-testing boolean expectations.
#
# On this toolchain every TOP-LEVEL `#expect(<Bool> == <Bool>)` or `!=` comparison passes
# unconditionally (`#expect(true == false)` passes) — the assertion proves nothing. This includes
# `Bool?` comparisons such as `as? Bool != nil`. The existing literal, coalesce, `.some`, and
# `#require` forms below are dead too. Load-bearing spellings: bare `#expect(x)` /
# `#expect(!x)`; for Optional presence, `let v = try #require(x)` and then a bare `#expect(v)`
# when the value must be true (or `#expect(!v)` when it must be false). Project through a non-Bool
# value when an assertion must compare two Boolean or Optional<Boolean> values.
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
# (a real enum-case comparison in this codebase); comment lines; and any call carrying an explicit
# `// test-integrity:live` suppression. A suppression may only document a scanner
# over-approximation where the compared operands are demonstrably non-Bool — it is never an escape
# for a top-level Boolean comparison. `Optional<Bool> == nil` is dead and must use `#require`.
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
# A nested `?? true/false` may be conservatively caught too. It must never be
# suppressed when the surrounding assertion is a top-level Boolean comparison:
# that comparison is independently dead.
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
    r'\bfor\s+(?P<variable>[A-Za-z_]\w*)\s+in\s+(?P<collection>(?:[A-Za-z_]\w*\s*\.\s*)*[A-Za-z_]\w*)\s*\{'
)

# This compiler bug is specific to Bool expectations. A collection can state
# that type explicitly, name that labelled tuple through a typealias, or infer
# it from a labelled `expected: true/false` literal; all three forms need
# coverage. Other labelled tuples (for example, enum equality) remain ordinary
# live comparisons and must not be swept into this Boolean-integrity lint.
BOOL_LABELLED_TUPLE_COLLECTION = re.compile(
    r'\b(?:let|var)\s+(?P<collection>[A-Za-z_]\w*)\s*:\s*'
    r'\[\([^\]]*\bexpected\s*:\s*Bool\b[^\]]*\)\]'
)
INFERRED_BOOL_LABELLED_TUPLE_COLLECTION = re.compile(
    r'\b(?:let|var)\s+(?P<collection>[A-Za-z_]\w*)\s*=\s*'
    r'\[\s*\([^\]]*?\bexpected\s*:\s*(?:true|false)\b',
    re.DOTALL,
)
BOOL_LABELLED_TUPLE_ALIAS = re.compile(
    r'\btypealias\s+(?P<alias>[A-Za-z_]\w*)\s*=\s*'
    r'\([^)]*\bexpected\s*:\s*Bool\b[^)]*\)',
    re.DOTALL,
)
ALIASED_BOOL_LABELLED_TUPLE_COLLECTION = re.compile(
    r'\b(?:let|var)\s+(?P<collection>[A-Za-z_]\w*)\s*:\s*'
    r'\[\s*(?P<alias>[A-Za-z_]\w*)\s*\]'
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
    blank = lambda match: ''.join('\n' if char == '\n' else ' ' for char in match.group())
    s = re.sub(r'/\*.*?\*/', blank, s, flags=re.DOTALL)
    s = re.sub(r'//[^\n]*', blank, s)
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
    """Return `(lhs, op, rhs)` for one top-level `==`/`!=` macro expression."""
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
        elif depth == 0 and expression.startswith(('==', '!='), index):
            if equality is not None:
                return None
            equality = (index, expression[index:index + 2])
            index += 1
        elif depth == 0 and char == ',':
            break
        index += 1
    if equality is None:
        return None
    equality_index, operator = equality
    return expression[:equality_index], operator, expression[equality_index + 2:index]

def expected_tuple_field(operand, variable):
    # Parenthesised operands are accepted, but the field itself must be exactly
    # `<loop-variable>.expected`; `.name` and any other tuple member stay live.
    return re.fullmatch(
        rf'\s*(?:\(\s*)*{re.escape(variable)}\s*\.\s*expected(?:\s*\))*\s*',
        operand,
    ) is not None

def direct_bool_cast(operand):
    return re.search(r'\bas\s*\?\s*Bool\b', operand) is not None

def parenthesized_comparison(operand):
    # The complete operand, rather than an incidental comparison nested in a
    # ternary/call, must be parenthesised. Its result is therefore Bool even
    # when its two inner operands are Strings or enums.
    stripped = operand.strip()
    if not stripped.startswith('('):
        return False
    closing = 0
    for index, char in enumerate(stripped):
        if char == '(':
            closing += 1
        elif char == ')':
            closing -= 1
            if closing == 0:
                if index != len(stripped) - 1:
                    return False
                inner = stripped[1:-1]
                return top_level_equality_in_expression(inner)
    return False

def top_level_equality_in_expression(expression):
    depth, index = 0, 0
    found_equality = False
    while index < len(expression):
        char = expression[index]
        if char in '([{':
            depth += 1
        elif char in ')]}':
            depth = max(0, depth - 1)
        elif depth == 0 and char == '?':
            # `(condition == value ? enumA : enumB)` returns the enum, not
            # the Boolean condition. Optional casts are handled separately.
            return False
        elif depth == 0 and expression.startswith(('==', '!='), index):
            found_equality = True
        index += 1
    return found_equality

def balanced_function_scopes(cleaned):
    """Return `(body_start, body_end, bool_parameter_names)` for each function."""
    scopes = []
    for match in re.finditer(r'\bfunc\s+[A-Za-z_]\w*', cleaned):
        opening = cleaned.find('{', match.end())
        if opening < 0:
            continue
        closing = balanced_brace_end(cleaned, opening)
        if closing is None:
            continue
        signature = cleaned[match.end():opening]
        parameters = {
            parameter.group('name')
            for parameter in re.finditer(
                r'\b(?P<name>[A-Za-z_]\w*)\s*:\s*Bool\s*\??\b', signature
            )
        }
        scopes.append((opening + 1, closing, parameters))
    return scopes

def scope_for(scopes, offset, text_length):
    containing = [scope for scope in scopes if scope[0] <= offset < scope[1]]
    if containing:
        return min(containing, key=lambda scope: scope[1] - scope[0])
    return 0, text_length, set()

def bool_local_names_before(cleaned, offset, scope):
    """Approximate local Bool types from annotations and obvious Bool initializers."""
    start, _, parameters = scope
    prefix = cleaned[start:offset]
    names = set(parameters)
    names.update(
        match.group('name')
        for match in re.finditer(
            r'\b(?:let|var)\s+(?P<name>[A-Za-z_]\w*)\s*:\s*Bool\s*\??\b', prefix
        )
    )
    for declaration in re.finditer(r'\b(?:let|var)\s+(?P<bindings>[^\n;]+)', prefix):
        names.update(
            binding.group('name')
            for binding in re.finditer(
                r'(?:^|,)\s*(?P<name>[A-Za-z_]\w*)\s*=\s*(?:true|false)\b',
                declaration.group('bindings'),
            )
        )
    # Equality and Boolean literals always infer Bool, so this also covers
    # locals such as `let requiresTarget = spec.target == .accepts...`.
    for match in re.finditer(
        r'\b(?:let|var)\s+(?P<name>[A-Za-z_]\w*)\s*=\s*(?P<value>[^\n;]+)', prefix
    ):
        value = match.group('value')
        # A multiline ternary often has its `?` on the following line. Its
        # initializer is not Bool merely because its condition uses `==`.
        continues_as_ternary = re.match(r'\s*\n\s*\?', prefix[match.end():]) is not None
        if (value.strip() in {'true', 'false'}
                or (not continues_as_ternary and top_level_equality_in_expression(value))):
            names.add(match.group('name'))
    return names

def bool_destructured_names_at(cleaned, offset):
    """Approximate Bool bindings in `for (..)` patterns over typed tuples."""
    collections = {}
    for declaration in re.finditer(
        r'\b(?:let|var)\s+(?P<name>[A-Za-z_]\w*)\s*:\s*\[\s*\((?P<types>[^)]*)\)\s*\]',
        cleaned,
        re.DOTALL,
    ):
        collections[declaration.group('name')] = [
            re.fullmatch(r'\s*Bool\s*\??\s*', part) is not None
            for part in declaration.group('types').split(',')
        ]

    names = set()
    for loop in re.finditer(
        r'\bfor\s*\((?P<bindings>[^)]*)\)\s+in\s*'
        r'(?P<collection>(?:[A-Za-z_]\w*\s*\.\s*)*[A-Za-z_]\w*)\s*\{',
        cleaned,
    ):
        closing = balanced_brace_end(cleaned, loop.end() - 1)
        if closing is None or not (loop.end() <= offset < closing):
            continue
        collection = re.split(r'\s*\.\s*', loop.group('collection'))[-1]
        bool_positions = collections.get(collection)
        if bool_positions is None:
            continue
        bindings = [binding.strip() for binding in loop.group('bindings').split(',')]
        names.update(
            binding
            for binding, is_bool in zip(bindings, bool_positions)
            if is_bool and re.fullmatch(r'[A-Za-z_]\w*', binding)
        )
    return names

def operand_has_bool_type(operand, local_bool_names):
    stripped = operand.strip()
    if direct_bool_cast(stripped) or parenthesized_comparison(stripped):
        return True
    if re.fullmatch(r'[A-Za-z_]\w*', stripped) and stripped in local_bool_names:
        return True
    return False

def matching_bool_member_equality(lhs, rhs, bool_member_names):
    """Recognize `x.flag == y.flag` only when `flag` is declared Bool.

    A receiver-free name set cannot safely classify `x.flag == enum.flag`: the
    same spelling can name unrelated properties. Requiring the same declared
    member on both operands covers equality of Bool fields without sweeping
    ordinary String/enum comparisons into this lint.
    """
    terminal_member = re.compile(r'\.\s*([A-Za-z_]\w*)\s*$')
    left = terminal_member.search(lhs)
    right = terminal_member.search(rhs)
    return (
        left is not None
        and right is not None
        and left.group(1) == right.group(1)
        and left.group(1) in bool_member_names
    )

def direct_bool_member_names(cleaned):
    """Return Bool properties declared directly in a nominal type/extension."""
    depths, depth = [], 0
    for char in cleaned:
        depths.append(depth)
        if char == '{':
            depth += 1
        elif char == '}':
            depth = max(0, depth - 1)

    names = set()
    type_declaration = re.compile(
        r'\b(?:struct|class|actor|enum|protocol|extension)\b[^{}]*\{'
    )
    property_declaration = re.compile(
        r'\b(?:public|private|internal|fileprivate|open)?\s*'
        r'(?:static\s+)?(?:let|var)\s+(?P<name>[A-Za-z_]\w*)\s*:\s*Bool\s*\??\b'
    )
    for type_match in type_declaration.finditer(cleaned):
        opening = type_match.end() - 1
        closing = balanced_brace_end(cleaned, opening)
        if closing is None:
            continue
        member_depth = depths[opening] + 1
        for property_match in property_declaration.finditer(cleaned, opening + 1, closing):
            if depths[property_match.start()] == member_depth:
                names.add(property_match.group('name'))
    return names

swift_sources = sorted(
    glob.glob('Sources/**/*.swift', recursive=True)
    + glob.glob('Tests/**/*.swift', recursive=True)
)
bool_member_names = set()
for swift_source in swift_sources:
    source = strip_comments(blank_strings(open(swift_source, encoding='utf-8').read()))
    # This deliberately records member names rather than receiver types. It is
    # an over-approximation, but lets the shell scanner recognize real Bool
    # fields such as `isCanonical`, `writeBoundaryCrossed`, and `isError`.
    bool_member_names.update(direct_bool_member_names(source))
    # Tuple labels are members too: `let tc: (input: String, expected: Bool)`
    # must catch `tc.expected` even when there is no loop. Restrict this to
    # tuple declarations/typealiases: ordinary function parameters are not
    # receiver members and names such as `audio` would cause false positives.
    bool_member_names.update(
        match.group('name')
        for match in re.finditer(
            r'\b(?:let|var)\s+[A-Za-z_]\w*\s*:\s*(?:\[\s*)?\([^)]*?'
            r'\b(?P<name>[A-Za-z_]\w*)\s*:\s*Bool\s*\??\b[^)]*\)',
            source,
            re.DOTALL,
        )
    )
    bool_member_names.update(
        match.group('name')
        for match in re.finditer(
            r'\btypealias\s+[A-Za-z_]\w*\s*=\s*\([^)]*?'
            r'\b(?P<name>[A-Za-z_]\w*)\s*:\s*Bool\s*\??\b[^)]*\)',
            source,
            re.DOTALL,
        )
    )

hits = []
for f in sorted(glob.glob('Tests/**/*.swift', recursive=True)):
    lines = open(f, encoding='utf-8').read().split('\n')
    text = '\n'.join(lines)
    cleaned = strip_comments(blank_strings(text))
    starts = [0]
    for ln in lines:
        starts.append(starts[-1] + len(ln) + 1)
    scopes = balanced_function_scopes(cleaned)
    for off, call in calls(text):
        lineno = bisect.bisect_right(starts, off)
        raw = lines[lineno - 1]
        if 'test-integrity:live' in call or 'test-integrity:live' in raw:
            continue
        if re.match(r'\s*(//|///|\*)', raw):
            continue
        sanitized_call = drop_closures(strip_comments(blank_strings(call)))
        if DEAD.search(sanitized_call):
            hits.append((f, lineno, raw.strip()[:110]))
            continue
        # Swift Testing's defect is type-based, not limited to `== true`.
        # Keep this to top-level `#expect` comparisons: a Boolean comparison
        # inside a closure or a larger expression remains a live sub-expression.
        if not call.startswith('#expect'):
            continue
        operands = top_level_equality_operands(strip_comments(blank_strings(call)))
        if operands is None:
            continue
        lhs, _, rhs = operands
        # Most comparisons have no bare identifier operand, so avoid repeatedly
        # scanning their enclosing functions for local declarations.
        if (re.fullmatch(r'\s*[A-Za-z_]\w*\s*', lhs)
                or re.fullmatch(r'\s*[A-Za-z_]\w*\s*', rhs)):
            scope = scope_for(scopes, off, len(cleaned))
            local_bool_names = bool_local_names_before(cleaned, off, scope)
            local_bool_names.update(bool_destructured_names_at(cleaned, off))
        else:
            local_bool_names = set()
        if (operand_has_bool_type(lhs, local_bool_names)
                or operand_has_bool_type(rhs, local_bool_names)
                or matching_bool_member_equality(lhs, rhs, bool_member_names)):
            hits.append((f, lineno, raw.strip()[:110]))
    # The labelled-tuple loop form is dead independently of literal Bool
    # comparisons, so relate each loop to a Boolean collection and inspect
    # `#expect` calls inside its balanced body. Report the #expect line, not
    # the loop line, for a direct fix.
    bool_labelled_tuple_collections = {
        match.group('collection')
        for match in BOOL_LABELLED_TUPLE_COLLECTION.finditer(cleaned)
    }
    bool_labelled_tuple_collections.update(
        match.group('collection')
        for match in INFERRED_BOOL_LABELLED_TUPLE_COLLECTION.finditer(cleaned)
    )
    bool_labelled_tuple_aliases = {
        match.group('alias')
        for match in BOOL_LABELLED_TUPLE_ALIAS.finditer(cleaned)
    }
    bool_labelled_tuple_collections.update(
        match.group('collection')
        for match in ALIASED_BOOL_LABELLED_TUPLE_COLLECTION.finditer(cleaned)
        if match.group('alias') in bool_labelled_tuple_aliases
    )
    cleaned_calls = list(calls(cleaned))
    for match in LABELLED_TUPLE_LOOP.finditer(cleaned):
        collection = re.split(r'\s*\.\s*', match.group('collection'))[-1]
        if collection not in bool_labelled_tuple_collections:
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
            lhs, _, rhs = operands
            if expected_tuple_field(lhs, match.group('variable')) or expected_tuple_field(rhs, match.group('variable')):
                hits.append((f, lineno, raw.strip()[:110]))

if hits:
    print("::error::Dead swift-testing boolean expectations found (#393). These pass unconditionally.")
    print("Convert to bare #expect(x)/#expect(!x); for Optionals: let v = try #require(x); #expect(v).")
    print("If this scanner over-approximated non-Bool operands, append '// test-integrity:live: <non-Bool reason>'.")
    for f, l, t in hits:
        print(f"{f}:{l}: {t}")
    print("COUNT:", len(hits))
    sys.exit(1)
print("OK: no dead boolean #expect/#require spellings in Tests/ (#393 test-integrity)")
PY
