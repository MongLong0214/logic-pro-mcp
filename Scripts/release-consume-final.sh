#!/usr/bin/env bash
# Consume owner-staged final bytes. The verifier and anchor are supplied by the
# trusted operator/workflow, outside the candidate/bundle; neither is read from it.
# No candidate execution, rebuilding or signing occurs here. Private evidence and
# verifier reports never become release assets.
set -euo pipefail
umask 077

if [ "$#" != 7 ]; then
  echo "Usage: $0 stage|verify VERSION COMMIT CANDIDATE BUNDLE TRUSTED_VERIFIER PUBLIC_DIRECTORY" >&2
  exit 1
fi
mode="$1"; version="$2"; commit="$3"; candidate="$4"; bundle="$5"; verifier="$6"; public="$7"
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
[[ "$mode" = stage || "$mode" = verify ]] || exit 1
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || exit 1
[[ "$commit" =~ ^[a-f0-9]{40}$ ]] || exit 1
test -f "$candidate" && test -x "$candidate" && test ! -L "$candidate"
test -d "$bundle" && test ! -L "$bundle"
test -f "$verifier" && test -x "$verifier" && test ! -L "$verifier"
test -n "${LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY:-}"
bundle="$(cd "$bundle" && pwd -P)"
verifier="$(cd "$(dirname "$verifier")" && pwd -P)/$(basename "$verifier")"
case "$verifier" in "$bundle"/*) echo "Verifier must be outside the evidence bundle" >&2; exit 1;; esac

private="$(mktemp -d)"
trap 'rm -rf "$private"' EXIT
cp "$candidate" "$private/LogicProMCP"
mkdir "$private/bundle"
cp -R "$bundle/." "$private/bundle/"
verify_candidate() {
  # Keep the verifier's detailed report private, including on rejection.
  if ! "$verifier" verify --candidate "$1" --bundle "$private/bundle" \
      --release-version "$version" --expected-commit "$commit" \
      > "$private/verification.json" 2> "$private/verification.stderr"; then
    echo "Final-artifact trusted verification rejected" >&2
    exit 1
  fi
}
verify_candidate "$private/LogicProMCP"
if [ -n "${EXPECTED_BINARY_SHA256:-}" ] || [ -n "${EXPECTED_MANIFEST_SHA256:-}" ]; then
  [[ "${EXPECTED_BINARY_SHA256:-}" =~ ^[a-f0-9]{64}$ ]]
  [[ "${EXPECTED_MANIFEST_SHA256:-}" =~ ^[a-f0-9]{64}$ ]]
  test "$(shasum -a 256 "$private/LogicProMCP" | awk '{print $1}')" = "$EXPECTED_BINARY_SHA256"
  test "$(shasum -a 256 "$private/bundle/evidence-manifest.json" | awk '{print $1}')" = "$EXPECTED_MANIFEST_SHA256"
fi

if [ "$mode" = stage ]; then
  # mkdir refuses a reused/nonempty destination; all inputs were copied privately
  # before verification, so later changes to operator inputs cannot replace them.
  mkdir "$public"
  cp "$private/LogicProMCP" "$public/LogicProMCP"
  cp -R "$repo_root/docs" "$public/docs"
  cp -R "$repo_root/Scripts" "$public/Scripts"
  cp -R "$repo_root/Formula" "$public/Formula"
  (cd "$public" && LOGIC_PRO_MCP_RELEASE_VERSION="v$version" RELEASE_MODE=adhoc \
    bash "$repo_root/Scripts/release-package.sh")
  (cd "$public" && bash "$repo_root/Scripts/release-verify-formula-install-paths.sh")
fi

test -f "$public/LogicProMCP" && test ! -L "$public/LogicProMCP"
cmp "$private/LogicProMCP" "$public/LogicProMCP"
codesign --verify --strict --verbose=2 "$public/LogicProMCP"
verify_candidate "$public/LogicProMCP"
bash "$repo_root/Scripts/release-package.sh" --list-members > "$private/members"
for archive in LogicProMCP-macOS-universal.tar.gz LogicProMCP-macOS-arm64.tar.gz; do
  # Inspect headers before tar can follow a link or choose one of duplicate
  # executable entries. Public checksums do not authenticate member structure.
  if ! python3 - "$public/$archive" "$private/members" "$repo_root" "$commit" \
      > "$private/archive.stdout" 2> "$private/archive.stderr" <<'PY'
import pathlib, subprocess, sys, tarfile
expected = set(pathlib.Path(sys.argv[2]).read_text().splitlines())
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    names = set()
    executable = None
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if (not member.name or path.is_absolute() or '..' in path.parts
                or '\\' in member.name or str(path) in names
                or member.name not in expected or not member.isfile()):
            raise ValueError('Unsafe release archive member')
        names.add(str(path))
        if str(path) == 'LogicProMCP':
            if member.name != 'LogicProMCP' or not member.isfile() or not member.mode & 0o111:
                raise ValueError('Invalid release executable member')
            executable = member
        else:
            # Compare to immutable authenticated source, never downloaded/public
            # companion files or a candidate-provided checksum manifest.
            original = subprocess.run(['git', '-C', sys.argv[3], 'show',
                                       sys.argv[4] + ':' + member.name],
                                      check=True, capture_output=True).stdout
            if archive.extractfile(member).read() != original:
                raise ValueError('Release source member differs from approved commit')
    if executable is None or names != expected:
        raise ValueError('Release archive member set differs from packager')
PY
  then
    echo "Final-artifact archive structure rejected" >&2
    exit 1
  fi
  extraction="$private/$archive.member"
  mkdir "$extraction"
  tar -xzf "$public/$archive" -C "$extraction" LogicProMCP
  test -f "$extraction/LogicProMCP" && test ! -L "$extraction/LogicProMCP"
  verify_candidate "$extraction/LogicProMCP"
  cmp "$public/LogicProMCP" "$extraction/LogicProMCP"
done
(cd "$public" && shasum -a 256 --check SHA256SUMS.txt)
if [ "$mode" = stage ]; then
  (cd "$public" && shasum -a 256 LogicProMCP LogicProMCP-macOS-universal.tar.gz \
    LogicProMCP-macOS-arm64.tar.gz RELEASE-METADATA.json SHA256SUMS.txt > release-artifacts.sha256)
  shasum -a 256 "$private/bundle/evidence-manifest.json" | awk '{print $1}' \
    > "$public/qualification-manifest.sha256"
fi
echo "Final signed candidate and both archive members verified"
