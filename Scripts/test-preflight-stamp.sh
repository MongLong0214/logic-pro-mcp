#!/bin/bash
# Self-test for the #552 stamp and its pre-push hook. A gate nobody has watched refuse is decoration.
set -uo pipefail
ROOT="${1:-.}"
cd "$ROOT" || { echo "FAIL: bad root"; exit 2; }
STAMPER="Scripts/preflight-stamp.sh"
HOOK="Scripts/pre-push-require-stamp.sh"
[ -f "$STAMPER" ] && [ -f "$HOOK" ] || { echo "CANNOT-TEST(2): scripts missing under $ROOT"; exit 2; }

TMP=$(mktemp -d) || { echo "CANNOT-TEST(2): mktemp failed"; exit 2; }
[ -d "$TMP" ] || { echo "CANNOT-TEST(2): mktemp produced no directory"; exit 2; }
export LPM_STAMP_DIR="$TMP/stamps"
FAIL=0
ok () { printf '  ok   %s\n' "$1"; }
no () { printf '  FAIL %s\n' "$1"; FAIL=1; }

bash "$STAMPER" check HEAD >/dev/null 2>&1
[ $? -eq 1 ] && ok "unstamped tree reports NOT-STAMPED (1)" || no "unstamped tree did not exit 1"

bash "$STAMPER" record HEAD >/dev/null 2>&1
bash "$STAMPER" check HEAD >/dev/null 2>&1
[ $? -eq 0 ] && ok "stamped tree reports OK (0)" || no "stamped tree did not exit 0"

bash "$STAMPER" check "definitely-not-a-ref" >/dev/null 2>&1
[ $? -eq 2 ] && ok "unresolvable tree-ish is CANNOT-CHECK (2), not 0 or 1" || no "unresolvable tree-ish did not exit 2"

# the hook: a stamped commit passes, an unstamped one is refused
printf 'refs/heads/x %s refs/heads/x %s\n' "$(git rev-parse HEAD)" "$(git rev-parse HEAD)" \
  | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "hook allows a stamped commit" || no "hook refused a stamped commit"

rm -rf "$LPM_STAMP_DIR"
printf 'refs/heads/x %s refs/heads/x %s\n' "$(git rev-parse HEAD)" "$(git rev-parse HEAD)" \
  | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 1 ] && ok "hook refuses an unstamped commit" || no "hook did NOT refuse an unstamped commit"

# The exploit an earlier revision shipped: the stamp was keyed on the TREE alone, so amending a message
# to add forbidden metadata kept it valid and the gate permitted the very class the preflight refuses.
# Commit messages are not in the tree, and the preflight greps them. Same tree must NOT mean same stamp.
SCRATCH=$(mktemp -d) || { echo "CANNOT-TEST(2): mktemp failed"; exit 2; }
(
  cd "$SCRATCH" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  echo x > f && git add f && git commit -qm "original message"
  cp "$OLDPWD/$STAMPER" ./stamp.sh
  TREE_BEFORE=$(git rev-parse HEAD^{tree})
  LPM_STAMP_DIR="$SCRATCH/st" bash ./stamp.sh record HEAD >/dev/null 2>&1
  git commit -q --amend -m "forbidden: worker-model routing, codex session"
  TREE_AFTER=$(git rev-parse HEAD^{tree})
  [ "$TREE_BEFORE" = "$TREE_AFTER" ] || exit 9   # the premise: the tree really is unchanged
  LPM_STAMP_DIR="$SCRATCH/st" bash ./stamp.sh check HEAD >/dev/null 2>&1
  exit $?
)
case $? in
  1) ok "a message-only amend INVALIDATES the stamp (tree-only keying was the exploit)" ;;
  9) no "scratch fixture broken: the amend changed the tree, so the case was not exercised" ;;
  *) no "a message-only amend kept the stamp — the gate would permit forbidden commit metadata" ;;
esac
rm -rf "$SCRATCH"

# `hook` must be able to report every state it distinguishes. Exercised in a scratch repo so the real
# clone's hook is never touched — a test that installs or removes the live gate to prove a point would
# leave the machine in whichever state it crashed in.
HOOKTEST=$(mktemp -d) || { echo "CANNOT-TEST(2): mktemp failed"; exit 2; }
(
  cd "$HOOKTEST" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  echo x > f && git add f && git commit -qm "c"
  cp "$OLDPWD/$STAMPER" ./stamp.sh
  H=$(git rev-parse --git-common-dir)/hooks/pre-push.commitlore-chained

  bash ./stamp.sh hook >/dev/null 2>&1
  [ $? -eq 1 ] || exit 11                       # absent must be NOT-ENFORCED(1)

  # A stamp recorded into a hookless clone has to SAY so; silence there is the whole defect.
  # Capture, do not pipe into `grep -q`. Under `set -o pipefail` a `-q` grep exits at its first match,
  # the producer takes SIGPIPE writing its next line, and the pipeline reports 141 — so the assertion
  # fails or passes depending on whether the writer happened to finish first. That race cost a real
  # debugging detour here; a check whose verdict depends on buffering is not a check.
  OUT=$(LPM_STAMP_DIR="$HOOKTEST/st" bash ./stamp.sh record HEAD 2>&1)
  case "$OUT" in *"warning: no executable"*) ;; *) exit 12 ;; esac

  printf '#!/bin/bash\nexit 0\n' > "$H"
  chmod -x "$H"
  OUT=$(bash ./stamp.sh hook 2>&1)
  case "$OUT" in *"not executable"*) ;; *) exit 13 ;; esac

  chmod +x "$H"
  bash ./stamp.sh hook >/dev/null 2>&1
  [ $? -eq 0 ] || exit 14                       # installed and executable must be OK(0)

  # ...and the warning must STOP once it is installed, or it is noise rather than a signal.
  OUT=$(LPM_STAMP_DIR="$HOOKTEST/st2" bash ./stamp.sh record HEAD 2>&1)
  case "$OUT" in *"warning: no executable"*) exit 15 ;; esac
  exit 0
)
case $? in
  0)  ok "hook reports absent / non-executable / installed, and record warns only when unenforced" ;;
  11) no "an absent hook did not report NOT-ENFORCED(1)" ;;
  12) no "record stayed silent in a clone with no hook installed — the silent absence is the defect" ;;
  13) no "a non-executable hook was not distinguished from an installed one" ;;
  14) no "an installed executable hook did not report OK(0)" ;;
  15) no "record warned about an absent hook while one was installed" ;;
  *)  no "hook-state fixture broke before it could measure anything" ;;
esac
rm -rf "$HOOKTEST"

printf 'refs/heads/x 0000000000000000000000000000000000000000 refs/heads/x %s\n' "$(git rev-parse HEAD)" \
  | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "hook allows a branch deletion" || no "hook refused a deletion"

rm -rf "$TMP"
echo
[ "$FAIL" -eq 0 ] && { echo "OK: the stamp refuses an unverified tree and allows a verified one"; exit 0; }
echo "FAIL: the stamp gate does not do what it claims"; exit 1
