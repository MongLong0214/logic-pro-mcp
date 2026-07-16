#!/bin/bash
set -euo pipefail

cd /Users/isaac/projects/logic-pro-mcp-adr001-remediation
EV=docs/tickets/lpmcp-prd-001/evidence

restore_en() {
  defaults write com.apple.logic10 AppleLanguages -array en
  defaults write com.apple.logic10 AppleLocale -string en_US
  osascript -e 'tell application "Logic Pro" to quit' >/dev/null 2>&1 || true
  sleep 3
  open -a "Logic Pro"
}
trap restore_en EXIT

defaults write com.apple.logic10 AppleLanguages -array ko
defaults write com.apple.logic10 AppleLocale -string ko_KR
osascript -e 'tell application "Logic Pro" to quit' >/dev/null 2>&1 || true
sleep 3
open -a "Logic Pro"
sleep 8

osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "Logic Pro"
    set frontmost to true
    keystroke "n" using command down
    delay 3
    key code 36
    delay 3
    key code 36
  end tell
end tell
APPLESCRIPT
sleep 6

bash "$EV/run-exact-head-mutation-body-8204877.sh"
printf 'PASS\n' >"$EV/live/mutation/exact-head-8204877-ko/result-v2.txt"
