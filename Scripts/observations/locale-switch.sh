#!/bin/bash
# Set Logic's UI language, quit it WITHOUT saving, and relaunch it on the canonical fixture.
#
#   Scripts/observations/locale-switch.sh <locale>        e.g. ko-KR, zh-TW
#
# It never clicks. A dialog Logic raises is not this script's to answer: if Logic will not quit it says so
# and exits 4, and the person (or the unattended run, as a HOLD) deals with it. The one tool that ever
# pressed a dialog's default button here is the reason this file exists; a script that clicks "Don't
# Save" on the wrong sheet destroys somebody's project, and a language switch has no business near one.
#
# Exit: 0 Logic is up in <locale> on the fixture; 2 usage or no fixture; 3 the language could not be set;
#       4 Logic would not quit; 5 Logic did not come back with a window.
set -u
LOCALE="${1:-}"
FIX="${LPM_LOCALE_FIXTURE:-$HOME/.hermes/cache/logic-cto/impl-logic13/R11/fixture/QualFixtureR11.logicx}"
case "$LOCALE" in
  en-US|ko-KR|ja-JP|de-DE|es-ES|fr-FR|it-IT|pt-BR|zh-CN|zh-TW) ;;
  *) echo "usage: $0 <en-US|ko-KR|ja-JP|de-DE|es-ES|fr-FR|it-IT|pt-BR|zh-CN|zh-TW>"; exit 2;;
esac
[ -d "$FIX" ] || { echo "PRECONDITION: fixture $FIX does not exist"; exit 2; }
defaults write com.apple.logic10 AppleLanguages -array "$LOCALE" || exit 3
if pgrep -xq "Logic Pro"; then
  osascript -e 'tell application "Logic Pro" to quit saving no' >/dev/null 2>&1
  for _ in $(seq 1 60); do pgrep -xq "Logic Pro" || break; sleep 1; done
  if pgrep -xq "Logic Pro"; then echo "Logic did not quit - not clicking anything"; exit 4; fi
fi
open -a "Logic Pro" "$FIX" || exit 5
n=0
for _ in $(seq 1 60); do
  n=$(osascript -e 'tell application "System Events" to tell process "Logic Pro" to get count of windows' 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 1 ] 2>/dev/null && break
  sleep 2
done
sleep 10
echo "LANG=$(defaults read com.apple.logic10 AppleLanguages | tr -d ' \n')"
echo "WINDOWS=$(osascript -e 'tell application "System Events" to tell process "Logic Pro" to get name of every window' 2>&1)"
[ "${n:-0}" -ge 1 ] 2>/dev/null || exit 5
