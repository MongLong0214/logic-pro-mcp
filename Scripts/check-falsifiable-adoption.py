#!/usr/bin/env python3
"""The strongest affordance a live harness has must not decay, and the gap must be a number.

`evidence.falsifiable()` hands the predicate to the framework, which runs it twice: once on what
the run observed, once on a counterexample the author had to write down. The check passes only when
the first is accepted AND the second rejected, and the author cannot supply the second result.
It is the only thing in the live kit that can notice a condition which could not have failed.

`is_clean` counts `checks_with_a_counterexample` and deliberately does not require it:

    Requiring every harness to HAVE one is the clause with teeth, and it is left
    counted-but-unenforced ... thirty-odd harnesses predate the affordance, and turning the whole
    live suite red in one step invites someone to delete the clause instead of converting the
    call sites. Enforce it when the count reaches the harness count, not before.

That reasoning is right and it left the number to nobody. Measured 2026-08-29: **1 of 35**. A
comment saying "enforce it later" has no way to notice going backwards, and no way to say how far
"later" is.

So this guard does the smaller thing that is mechanical rather than the larger one that is a
promise: the count may rise and may not fall. Raising FLOOR is a reviewed edit in this file, which
is where a ratchet's teeth are — a number that can be lowered by whoever is inconvenienced is a
suggestion.

It does not check that a counterexample is a GOOD one. It does reject one mechanically detectable
hollow form: a constant dictionary counterexample paired with a lambda that only reads one
attribute or subscript from its parameter, including `.get(...)`. That form proves lookup
distinguishes true from false, not that the predicate examines its stated observation. Beyond that
narrow case, whether the alternative is the one that matters remains the author's claim and a
reviewer's job.
"""
import ast
import glob
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The measured floor. Raise it when a harness converts; never lower it to make a branch pass.
# 8 -> 9 on 2026-09-05: live_778_japanese_ax_reads_resolve, whose three assertions are each about a
# state a Japanese Logic used to be in, so each is written against the envelope that state produced.
# 9 -> 10, same day: live_778_step_input_toggle_reaches_its_menu_item. Its counterexamples are the
# State C envelope the operation really returned before the fix, and Logic's window list before the
# toggle — one from the product, one from outside it.
FLOOR = 10
_FALSIFIABLE_PARAMETERS = (
    "tag", "predicate", "observation", "counterexample", "expected", "mutation", "modal_snapshot",
)
_REQUIRED_FALSIFIABLE_PARAMETERS = _FALSIFIABLE_PARAMETERS[:5]

def _call_argument(call, position, keyword):
    if len(call.args) > position:
        return call.args[position]
    return next((arg.value for arg in call.keywords if arg.arg == keyword), None)


def _constant_literal(node):
    if isinstance(node, ast.Constant):
        return True
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        return all(_constant_literal(item) for item in node.elts)
    if isinstance(node, ast.Dict):
        return all((key is None or _constant_literal(key)) and _constant_literal(value)
                   for key, value in zip(node.keys, node.values))
    return False


def _has_plausible_falsifiable_arity(call):
    """Whether a call supplies every required `Evidence.falsifiable` argument.

    A name match alone is not adoption: `E.falsifiable(1)` cannot run the framework's predicate
    contract and must not raise the floor. Positional and keyword calls are both valid forms.
    """
    if len(call.args) > len(_FALSIFIABLE_PARAMETERS) or any(
            isinstance(argument, ast.Starred) for argument in call.args):
        return False
    supplied = {}
    for position, argument in enumerate(call.args):
        supplied[_FALSIFIABLE_PARAMETERS[position]] = argument
    for keyword in call.keywords:
        if (keyword.arg is None or keyword.arg not in _FALSIFIABLE_PARAMETERS
                or keyword.arg in supplied):
            return False
        supplied[keyword.arg] = keyword.value
    return all(name in supplied for name in _REQUIRED_FALSIFIABLE_PARAMETERS)


def _is_single_parameter_access(body, parameter):
    """Whether `body` only accesses the lambda parameter once, with no assertion around it."""
    if isinstance(body, (ast.Attribute, ast.Subscript)):
        base = body.value
    elif isinstance(body, ast.Call) and isinstance(body.func, ast.Attribute):
        # `.get(...)` is still a single access on the parameter, merely with call syntax.
        base = body.func.value
    else:
        return False
    return isinstance(base, ast.Name) and base.id == parameter


def _is_hollow_falsifiable(call):
    """The known boolean-wrapper pattern, not a claim to judge arbitrary counterexamples."""
    predicate = _call_argument(call, 1, "predicate")
    counterexample = _call_argument(call, 3, "counterexample")
    if not isinstance(predicate, ast.Lambda) or not isinstance(counterexample, ast.Dict):
        return False
    if not _constant_literal(counterexample):
        return False
    if len(predicate.args.args) != 1 or predicate.args.vararg or predicate.args.kwarg:
        return False
    parameter = predicate.args.args[0].arg
    return _is_single_parameter_access(predicate.body, parameter)


def _falsifiable_calls(text):
    """`(has_real_call, hollow_lines)` for actual calls, never comments or strings.

    Parsed, because a regex counts `# falsifiable(` in a comment and a `"falsifiable("` in a
    string. Found by review, 2026-08-29, reproduced: a harness whose only occurrence was a comment
    held the floor and passed CI, and the test that was supposed to catch it wrote the word without
    the parenthesis — so the control could not see the defect it was aimed at.

    A file that will not parse claims nothing. It cannot be run either, so it cannot be an adopter.
    """
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return False, []
    has_real_call = False
    hollow_lines = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
        if name == "falsifiable" and _has_plausible_falsifiable_arity(node):
            if _is_hollow_falsifiable(node):
                hollow_lines.append(node.lineno)
            else:
                has_real_call = True
    return has_real_call, hollow_lines


def _calls_falsifiable(text):
    """Whether this source has an actual, non-hollow call to `falsifiable`."""
    return _falsifiable_calls(text)[0]


def adoption(paths=None, include_hollow=False):
    """Adopting harnesses and total; optionally include separately reported hollow call locations."""
    files = paths if paths is not None else sorted(
        glob.glob(os.path.join(REPO, "Scripts", "livekit", "live_*.py")))
    adopters = []
    hollow = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            # Unreadable is not adopted. Counting it either way would let a permissions accident
            # move the number, and this number is the whole point of the guard.
            continue
        has_real_call, hollow_lines = _falsifiable_calls(text)
        name = os.path.basename(path)
        hollow.extend((name, line) for line in hollow_lines)
        if has_real_call:
            adopters.append(name)
    if include_hollow:
        return adopters, len(files), hollow
    return adopters, len(files)


def main():
    adopters, total, hollow = adoption(include_hollow=True)
    if total == 0:
        print("-> FAIL: no live harnesses found — an empty set satisfies any floor")
        return 1

    print(f"   falsifiable() adoption: {len(adopters)} of {total} harnesses (floor {FLOOR})")
    for name in adopters:
        print(f"     uses it  {name}")
    for name, line in hollow:
        print(f"     hollow   {name}:{line} (constant counterexample + boolean-wrapper predicate)")

    if len(adopters) < FLOOR:
        print(f"-> FAIL: adoption fell to {len(adopters)}, below the recorded floor {FLOOR}")
        print("   A harness lost its counterexample, or one was deleted. Restore it, or raise the")
        print("   question in review — do not lower FLOOR to make this pass.")
        return 1

    if len(adopters) > FLOOR:
        print(f"-> FAIL: adoption is {len(adopters)} but FLOOR is still {FLOOR}")
        print(f"   Raise FLOOR to {len(adopters)} in this file. A ratchet that does not tighten")
        print("   when it can is a counter, and the next regression falls back to the old number.")
        return 1

    remaining = total - len(adopters)
    if remaining:
        print(f"   {remaining} harness(es) have no counterexample. `is_clean` will enforce")
        print(f"   checks_with_a_counterexample > 0 when this reaches {total}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
