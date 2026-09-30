#!/usr/bin/env python3
"""Cases for `check-template-mode-has-one-user.py`, driven through its entry point at fixture trees.

The repository is one case, and the control: a guard that refused every tree would pass all the
refusals below, so the real tree must be accepted and each refusal must name what it refused.
"""
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(REPO, "Scripts", "check-template-mode-has-one-user.py")
failed = 0

DECL = ("    static let editUndoMenuPath = MenuPath(bar: editMenuBar, item: undoMenuItemPrefix, "
        "itemMode: .template)\n")
POLICY = ("enum AXLocalePolicy {\n" + DECL +
          "    func f(_ m: MatchMode) { switch m { case .template: break; default: break } }\n}\n")


def case(label, ok, detail=""):
    global failed
    failed += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label}" + (f" -> {detail}" if not ok and detail else ""))


def run(files):
    root = tempfile.mkdtemp()
    for name, body in files.items():
        with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
            handle.write(body)
    return subprocess.run([sys.executable, GUARD], capture_output=True, text=True,
                          env=dict(os.environ, LPM_TEMPLATE_SOURCES=root))


real = subprocess.run([sys.executable, GUARD], capture_output=True, text=True)
case("CONTROL: the repository is accepted", real.returncode == 0, real.stdout + real.stderr)

ok = run({"AXLocalePolicy.swift": POLICY})
case("CONTROL: the one declaration and a `case .template` are accepted", ok.returncode == 0, ok.stdout)

second = run({"AXLocalePolicy.swift": POLICY,
              "Other.swift": "let p = MenuPath(bar: b, item: someOtherSet, itemMode: .template)\n"})
case("a second MenuPath using .template is refused",
     second.returncode == 1 and "Other.swift:1" in second.stdout, second.stdout)

call = run({"AXLocalePolicy.swift": POLICY,
            "Other.swift": "let ok = x.matches(t, mode: .template)\n"})
case("a `matches(mode: .template)` call is refused",
     call.returncode == 1 and "Other.swift:1" in call.stdout, call.stdout)

longform = run({"AXLocalePolicy.swift": POLICY,
                "Other.swift": "let m = AXLocalePolicy.MatchMode.template\n"})
case("the spelled-out MatchMode.template is refused",
     longform.returncode == 1 and "Other.swift:1" in longform.stdout, longform.stdout)

other_set = run({"AXLocalePolicy.swift": POLICY.replace("undoMenuItemPrefix", "someOtherSet")})
case("editUndoMenuPath on a different set is refused",
     other_set.returncode == 1, other_set.stdout)

none = run({"AXLocalePolicy.swift": POLICY.replace(".template)", ".prefix)")})
case("a tree where editUndoMenuPath stopped using it is refused",
     none.returncode == 1 and "0 time(s)" in none.stdout, none.stdout)

commented = run({"AXLocalePolicy.swift": POLICY, "Other.swift": "// itemMode: .template\n"})
case("a comment is not a use", commented.returncode == 0, commented.stdout)

print(f"{failed} failed")
sys.exit(1 if failed else 0)
