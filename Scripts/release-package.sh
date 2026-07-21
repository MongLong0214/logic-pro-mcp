#!/usr/bin/env bash
set -euo pipefail

release_version="${GITHUB_REF_NAME:-${LOGIC_PRO_MCP_RELEASE_VERSION:-local-dev}}"

binary_path="${LOGIC_PRO_MCP_PACKAGE_BINARY:-LogicProMCP}"
binary_dir=$(cd "$(dirname "$binary_path")" && pwd -P)
binary_name=$(basename "$binary_path")
binary_file="$binary_dir/$binary_name"
root_binary="$(pwd -P)/LogicProMCP"

if [ "${RELEASE_MODE:-}" = "notarized" ]; then
  team_id="${APPLE_NOTARY_TEAM_ID:-}"
  signing="notarized"
  if [ -z "$team_id" ]; then
    echo "::error::APPLE_NOTARY_TEAM_ID is required when RELEASE_MODE=notarized"
    exit 1
  fi
else
  team_id="ADHOC"
  signing="adhoc"
fi

if [ "$binary_name" != "LogicProMCP" ]; then
  echo "::error::Release binary basename must be LogicProMCP (got $binary_name)"
  exit 1
fi

if [ ! -x "$binary_file" ]; then
  echo "::error::Release binary is missing or not executable: $binary_file"
  exit 1
fi

rm -f LogicProMCP-macOS-universal.tar.gz LogicProMCP-macOS-arm64.tar.gz SHA256SUMS.txt RELEASE-METADATA.json

lipo_out=$(lipo -info "$binary_file" 2>/dev/null || true)
if [ -z "$lipo_out" ]; then
  echo "::error::lipo -info $binary_file returned no output"
  exit 1
fi

if echo "$lipo_out" | grep -q "Non-fat file"; then
  arch_field=$(echo "$lipo_out" | sed -E 's/.*architecture: ([a-zA-Z0-9_]+).*/\1/')
  if [ -z "$arch_field" ] || ! echo "$arch_field" | grep -qE '^[a-zA-Z0-9_]+$'; then
    echo "::error::Could not parse architecture from lipo output: $lipo_out"
    exit 1
  fi
  arch_json="[\"$arch_field\"]"
else
  arch_list=$(echo "$lipo_out" | sed -E 's/.*are: //' | tr ' ' '\n' | grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)
  if [ -z "$arch_list" ]; then
    echo "::error::Could not parse fat-file architectures from lipo output: $lipo_out"
    exit 1
  fi
  arch_json="[$arch_list]"
fi

python3 - "$release_version" "$team_id" "$signing" "$arch_json" > RELEASE-METADATA.json <<'PY'
import json
import sys

version, team_id, signing, arch_json = sys.argv[1:]
metadata = {
    "version": version,
    "team_id": team_id,
    "signing": signing,
    "architectures": json.loads(arch_json),
}
print(json.dumps(metadata, separators=(",", ":")))
PY

if [ "$binary_file" != "$root_binary" ]; then
  cp "$binary_file" "$root_binary"
  chmod 0755 "$root_binary"
  binary_file="$root_binary"
  binary_dir=$(pwd -P)
fi

tar czf LogicProMCP-macOS-universal.tar.gz \
  -C "$binary_dir" LogicProMCP \
  -C "$PWD" \
  docs/SETUP.md \
  Scripts/install-keycmds.sh \
  Scripts/uninstall-keycmds.sh \
  Scripts/keycmd-preset.plist \
  Scripts/LogicProMCP-Scripter.js \
  Scripts/logic_bounce.py \
  Scripts/logic_bounce_ui.py \
  Scripts/logic_ui_jxa.py \
  Scripts/logic_input_source.py \
  Scripts/logic_variants.py

cp LogicProMCP-macOS-universal.tar.gz LogicProMCP-macOS-arm64.tar.gz
shasum -a 256 LogicProMCP-macOS-universal.tar.gz > SHA256SUMS.txt
shasum -a 256 LogicProMCP-macOS-arm64.tar.gz >> SHA256SUMS.txt
binary_sha=$(shasum -a 256 "$binary_file" | awk '{print $1}')
printf '%s  LogicProMCP\n' "$binary_sha" >> SHA256SUMS.txt
