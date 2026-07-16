#!/bin/bash
set -euo pipefail

cd /Users/isaac/projects/logic-pro-mcp-adr001-remediation
EV=docs/tickets/lpmcp-prd-001/evidence
BIN="$PWD/LogicProMCP"
HEAD=8204877c2d66d11598ac5e7292d231fa42c8a8b3
SHA=8c3a525a89a6bbaaff09e362ea35aae8391243d9eff1221c1161aa58257262d6

restore_en() {
  defaults write com.apple.logic10 AppleLanguages -array en
  defaults write com.apple.logic10 AppleLocale -string en_US
  osascript -e 'tell application "Logic Pro" to quit' >/dev/null 2>&1 || true
  sleep 3
  open -a "Logic Pro"
}
trap restore_en EXIT

test "$(git rev-parse HEAD)" = "$HEAD"
test "$(shasum -a 256 "$BIN" | awk '{print $1}')" = "$SHA"
set -a
source "$EV/live/keys/ephemeral-qualify-keys.env"
set +a
export GIT_COMMIT="$HEAD"

run_axis() {
  local locale="$1"
  local out="$EV/live/exact-head-8204877-$locale"
  mkdir -p "$out"
  "$BIN" --qualify --out "$out/attestation.json" \
    --waivers .github/qualification/waivers.json \
    --release-version 3.11.0 --variant desktop --locale "$locale" \
    --profile full --cache cold >"$out/qualify-terminal.log" 2>&1
  find "$out" -type f ! -name sha256sums.txt -print0 \
    | sort -z \
    | xargs -0 shasum -a 256 >"$out/sha256sums.txt"
}

defaults write com.apple.logic10 AppleLanguages -array en
defaults write com.apple.logic10 AppleLocale -string en_US
osascript -e 'tell application "Logic Pro" to quit' >/dev/null 2>&1 || true
sleep 3
open -a "Logic Pro"
sleep 8
if [ ! -f "$EV/live/exact-head-8204877-en/attestation.json" ]; then
  run_axis en
fi

defaults write com.apple.logic10 AppleLanguages -array ko
defaults write com.apple.logic10 AppleLocale -string ko_KR
osascript -e 'tell application "Logic Pro" to quit' >/dev/null 2>&1 || true
sleep 3
open -a "Logic Pro"
sleep 8
run_axis ko

printf 'PASS\n' >"$EV/live/exact-head-8204877-terminal-result.txt"
