#!/usr/bin/env bash
# Protected owner inputs only; no URL, key, private evidence or verifier report
# is printed/uploaded. The caller owns and removes this private directory.
set -euo pipefail
umask 077
mode="${1:-}"; destination="${2:-}"
[[ "$mode" = stage || "$mode" = verify ]] && test -d "$destination"
# Curl errors and ZIP integrity diagnostics can include private URLs/member
# names. Preserve details only in the caller-owned private directory.
exec 3>&2
trap 'echo "Qualified private input fetch rejected" >&3' ERR
exec > "$destination/fetch.stdout" 2> "$destination/fetch.stderr"
test -n "${QUALIFICATION_EVIDENCE_URL:-}"
[[ "${QUALIFICATION_EVIDENCE_SHA256:-}" =~ ^[a-f0-9]{64}$ ]]
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --max-time 120 \
  "$QUALIFICATION_EVIDENCE_URL" --output "$destination/evidence.zip"
printf '%s  %s\n' "$QUALIFICATION_EVIDENCE_SHA256" "$destination/evidence.zip" | shasum -a 256 --check
python3 - "$destination/evidence.zip" "$destination/bundle" <<'PY'
import pathlib, shutil, stat, sys, zipfile
archive, destination = sys.argv[1:]
root = pathlib.Path(destination)
root.mkdir(mode=0o700)
with zipfile.ZipFile(archive) as bundle:
    names = set()
    for member in bundle.infolist():
        path = pathlib.PurePosixPath(member.filename)
        kind = stat.S_IFMT(member.external_attr >> 16)
        if (not member.filename or path.is_absolute() or '..' in path.parts
                or '\\' in member.filename or member.filename in names
                or kind not in (0, stat.S_IFREG, stat.S_IFDIR)):
            raise ValueError('Unsafe qualified bundle member')
        names.add(member.filename)
    for member in bundle.infolist():
        output = root / member.filename
        if member.is_dir():
            output.mkdir(parents=True, exist_ok=True)
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(member) as source, output.open('xb') as target:
                shutil.copyfileobj(source, target)
PY
if [ "$mode" = stage ]; then
  test -n "${QUALIFICATION_CANDIDATE_URL:-}"
  [[ "${QUALIFICATION_CANDIDATE_SHA256:-}" =~ ^[a-f0-9]{64}$ ]]
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --max-time 120 \
    "$QUALIFICATION_CANDIDATE_URL" --output "$destination/LogicProMCP"
  printf '%s  %s\n' "$QUALIFICATION_CANDIDATE_SHA256" "$destination/LogicProMCP" | shasum -a 256 --check
  chmod 0755 "$destination/LogicProMCP"
fi
