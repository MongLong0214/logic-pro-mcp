#!/usr/bin/env bash
# Consume owner-staged final bytes. The verifier and anchor are supplied by the
# trusted operator/workflow, outside the candidate/matrix; neither is read from it.
# No candidate execution, rebuilding or signing occurs here. Private evidence and
# verifier reports never become release assets.
set -euo pipefail
umask 077

if [ "$#" != 7 ]; then
  echo "Usage: $0 stage|verify|verify-public VERSION COMMIT CANDIDATE MATRIX TRUSTED_VERIFIER PUBLIC_DIRECTORY" >&2
  exit 1
fi
mode="$1"; version="$2"; commit="$3"; candidate="$4"; matrix="$5"; verifier="$6"; public="$7"
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
[[ "$mode" = stage || "$mode" = verify || "$mode" = verify-public ]] || exit 1
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || exit 1
[[ "$commit" =~ ^[a-f0-9]{40}$ ]] || exit 1
if [ ! -f "$candidate" ] || [ -L "$candidate" ]; then
  echo "Final candidate must be a regular non-link file" >&2
  exit 1
fi
if [ ! -d "$matrix" ] || [ -L "$matrix" ]; then
  echo "Qualification matrix must be a non-link directory" >&2
  exit 1
fi
if [ ! -f "$verifier" ] || [ ! -x "$verifier" ] || [ -L "$verifier" ]; then
  echo "Trusted verifier must be a regular non-link executable" >&2
  exit 1
fi
test -n "${LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY:-}"
matrix="$(cd "$matrix" && pwd -P)"
verifier="$(cd "$(dirname "$verifier")" && pwd -P)/$(basename "$verifier")"
case "$verifier" in "$matrix"/*) echo "Verifier must be outside the qualification matrix" >&2; exit 1;; esac

private="$(mktemp -d)"
trap 'rm -rf "$private"' EXIT
cp "$candidate" "$private/LogicProMCP"
mkdir "$private/matrix"
cp -R "$matrix/." "$private/matrix/"
verify_candidate() {
  # Keep the verifier's detailed report private, including on rejection.
  if ! "$verifier" verify-matrix --candidate "$1" \
      --matrix-index "$private/matrix/qualification-matrix-input.json" \
      --release-version "$version" --expected-commit "$commit" \
      > "$private/verification.json" 2> "$private/verification.stderr"; then
    echo "Final-artifact trusted verification rejected" >&2
    exit 1
  fi
}
verify_candidate "$private/LogicProMCP"
if [ -n "${EXPECTED_BINARY_SHA256:-}" ] || [ -n "${EXPECTED_MATRIX_SHA256:-}" ]; then
  [[ "${EXPECTED_BINARY_SHA256:-}" =~ ^[a-f0-9]{64}$ ]]
  [[ "${EXPECTED_MATRIX_SHA256:-}" =~ ^[a-f0-9]{64}$ ]]
  test "$(shasum -a 256 "$private/LogicProMCP" | awk '{print $1}')" = "$EXPECTED_BINARY_SHA256"
  test "$(shasum -a 256 "$private/matrix/release-qualification-matrix.json" | awk '{print $1}')" = "$EXPECTED_MATRIX_SHA256"
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

# Reject outer file types before cmp, archive opening or checksum reads. Member
# validation and trusted verification cannot protect an earlier blocking read.
for artifact in LogicProMCP LogicProMCP-macOS-universal.tar.gz LogicProMCP-macOS-arm64.tar.gz SHA256SUMS.txt; do
  if [ ! -f "$public/$artifact" ] || [ -L "$public/$artifact" ]; then
    echo "Final-artifact input must be a regular non-link file" >&2
    exit 1
  fi
done
if [ "$mode" = verify-public ]; then
  for artifact in RELEASE-METADATA.json qualification-public.json; do
    if [ ! -f "$public/$artifact" ] || [ -L "$public/$artifact" ]; then
      echo "Final-artifact input must be a regular non-link file" >&2
      exit 1
    fi
  done
fi
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
  if [ ! -f "$extraction/LogicProMCP" ] || [ -L "$extraction/LogicProMCP" ]; then
    echo "Extracted candidate must be a regular non-link file" >&2
    exit 1
  fi
  verify_candidate "$extraction/LogicProMCP"
  cmp "$public/LogicProMCP" "$extraction/LogicProMCP"
done
# Hash only the declared artifacts. A checksum file is untrusted data, never a
# source of paths to open. Sorting retains support for reordered checksum rows.
(cd "$public" && shasum -a 256 LogicProMCP-macOS-universal.tar.gz \
  LogicProMCP-macOS-arm64.tar.gz LogicProMCP | LC_ALL=C sort) > "$private/expected-checksums"
LC_ALL=C sort "$public/SHA256SUMS.txt" > "$private/supplied-checksums"
cmp "$private/expected-checksums" "$private/supplied-checksums"
if [ "$mode" = verify-public ]; then
  if ! "$verifier" verify-public-matrix --public-directory "$public" \
      --release-version "$version" --expected-commit "$commit" \
      > "$private/public-verification.json" 2> "$private/public-verification.stderr"; then
    echo "Final-artifact public evidence rejected" >&2
    exit 1
  fi
  # Tie the complete authenticated public projection to THIS frozen private
  # matrix root and independently derive distribution metadata from the same
  # candidate. A valid projection from another matrix must never splice in.
  if ! python3 - "$private/public-verification.json" "$private/matrix/release-qualification-matrix.json" \
      "$public/RELEASE-METADATA.json" "$public/LogicProMCP" "$version" \
      > "$private/public-binding.stdout" 2> "$private/public-binding.stderr" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
private_bytes = pathlib.Path(sys.argv[2]).read_bytes()
private = json.loads(private_bytes)
if payload['privateMatrixSHA256'] != hashlib.sha256(private_bytes).hexdigest():
    raise ValueError('Different accepted private matrix')
for key in ('commitSHA', 'releaseVersion', 'binarySHA256', 'logicVersion',
            'operationCatalogSHA256'):
    if payload[key] != private[key]:
        raise ValueError('Public matrix identity differs from private matrix')
axis_keys = ('variant', 'locale', 'profile', 'cache', 'fixture')
def run_identity(run):
    return tuple(run['axis'][key] for key in axis_keys), run['childAttestationSHA256']
if sorted(map(run_identity, payload['runs'])) != sorted(map(run_identity, private['runs'])):
    raise ValueError('Public matrix children differ from private matrix')
def contains_private_path(value):
    if isinstance(value, dict):
        return 'path' in value or any(contains_private_path(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_private_path(item) for item in value)
    return False
if contains_private_path(payload):
    raise ValueError('Public matrix disclosed a private path')
with open(sys.argv[3], 'rb') as source:
    raw = source.read(4097)
if len(raw) > 4096:
    raise ValueError('Oversized release metadata')
metadata = json.loads(raw)
info = subprocess.run(['lipo', '-info', sys.argv[4]], check=True, capture_output=True,
                      text=True, timeout=10).stdout.strip()
single = re.search(r'Non-fat file: .* is architecture: ([A-Za-z0-9_]+)$', info)
multiple = re.search(r'Architectures in the fat file: .* are: ([A-Za-z0-9_ ]+)$', info)
architectures = [single.group(1)] if single else multiple.group(1).split() if multiple else None
if not architectures or metadata != {'version': 'v' + sys.argv[5], 'team_id': 'ADHOC',
                                      'signing': 'adhoc', 'architectures': architectures}:
    raise ValueError('Release metadata differs from accepted candidate')
PY
  then
    echo "Final-artifact public binding rejected" >&2
    exit 1
  fi
fi
if [ "$mode" = stage ]; then
  (cd "$public" && shasum -a 256 LogicProMCP LogicProMCP-macOS-universal.tar.gz \
    LogicProMCP-macOS-arm64.tar.gz RELEASE-METADATA.json SHA256SUMS.txt > release-artifacts.sha256)
  shasum -a 256 "$private/matrix/release-qualification-matrix.json" | awk '{print $1}' \
    > "$public/qualification-matrix.sha256"
fi
echo "Final signed candidate and both archive members verified"
