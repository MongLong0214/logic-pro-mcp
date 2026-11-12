#!/usr/bin/env bash
set -euo pipefail

runner_temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$runner_temp_root"
build_root=$(mktemp -d "$runner_temp_root/logicpromcp-universal.XXXXXX")

find_arch_binary() {
  local build_dir="$1"
  local arch="$2"
  local candidates_file="$build_root/${arch}-candidates.txt"
  local candidate=""
  local file_out=""
  local bin=""

  find "$build_dir" -type f -name LogicProMCP -perm -u+x | sort > "$candidates_file"

  if [ ! -s "$candidates_file" ]; then
    echo "::error::No executable LogicProMCP candidates found under $build_dir for $arch" >&2
    exit 1
  fi

  while IFS= read -r candidate; do
    file_out=$(file "$candidate")
    echo "Candidate [$arch]: $candidate" >&2
    echo "$file_out" >&2
    if echo "$file_out" | grep -q "Mach-O" && echo "$file_out" | grep -q "$arch"; then
      bin="$candidate"
      break
    fi
  done < "$candidates_file"

  if [ -z "$bin" ]; then
    echo "::error::No $arch LogicProMCP binary located; candidates below:" >&2
    while IFS= read -r candidate; do
      file "$candidate" >&2
    done < "$candidates_file"
    exit 1
  fi

  printf '%s\n' "$bin"
}

arm64_build_dir="$build_root/arm64"
x64_build_dir="$build_root/x86_64"

swift build -c release --product LogicProMCP --arch arm64 --scratch-path "$arm64_build_dir" &
arm64_pid=$!
swift build -c release --product LogicProMCP --arch x86_64 --scratch-path "$x64_build_dir" &
x64_pid=$!

arm64_status=0
x64_status=0
wait "$arm64_pid" || arm64_status=$?
wait "$x64_pid" || x64_status=$?
if [ "$arm64_status" -ne 0 ] || [ "$x64_status" -ne 0 ]; then
  echo "::error::universal build failed (arm64=$arm64_status, x86_64=$x64_status)" >&2
  exit 1
fi

arm64_bin=$(find_arch_binary "$arm64_build_dir" "arm64")
x64_bin=$(find_arch_binary "$x64_build_dir" "x86_64")

echo "ARM64 binary: $arm64_bin"
echo "x86_64 binary: $x64_bin"
lipo -create -output LogicProMCP "$arm64_bin" "$x64_bin"
chmod +x LogicProMCP

file_out=$(file LogicProMCP)
echo "$file_out"
for need in "Mach-O universal binary" "arm64" "x86_64"; do
  if ! echo "$file_out" | grep -q "$need"; then
    echo "::error::LogicProMCP missing required slice/type: '$need'"
    exit 1
  fi
done
