#!/bin/bash
# build_attested_binary.sh <worktree> <out-root>
#
# Build LogicProMCP at the worktree's HEAD with that commit embedded in the Mach-O section
# __TEXT,__lpm_commit, copy it to <out-root>/bin-<head8>/LogicProMCP, and write build-receipt.json beside
# it. A live harness reads the section back from the file it measures and refuses a binary that does
# not carry the head it is run as (live_1092_rewind_and_forward_step_one_bar.py, provenance_refusal):
# the binary names its own source, instead of the evidence naming the worktree's head when it is written
# (#1095 review rounds 1-3).
#
# Refuses a dirty tree before and after the build. A local `swift build` can rewrite Package.resolved;
# that file is put back first.
set -euo pipefail
W=${1:?worktree}
OUT=${2:?out-root}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$W"
git checkout -- Package.resolved 2>/dev/null || true
if [ -n "$(git status --porcelain)" ]; then
    echo "the tree is not clean; nothing was built" >&2
    git status --porcelain | head >&2
    exit 1
fi
HEAD_SHA=$(git rev-parse HEAD)
STAMP=$(mktemp)
printf '%s' "$HEAD_SHA" > "$STAMP"
swift build --product LogicProMCP \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __lpm_commit -Xlinker "$STAMP" 2>&1 | tail -1
rm -f "$STAMP"
git checkout -- Package.resolved 2>/dev/null || true
if [ -n "$(git status --porcelain)" ]; then
    echo "the tree changed during the build" >&2
    exit 1
fi
DEST="$OUT/bin-${HEAD_SHA:0:8}"
mkdir -p "$DEST"
cp .build/debug/LogicProMCP "$DEST/LogicProMCP"
CARRIED=$(python3 - "$HERE" "$DEST/LogicProMCP" <<'PY'
import importlib.util, os, sys
here, binary = sys.argv[1], sys.argv[2]
sys.path.insert(0, here)
spec = importlib.util.spec_from_file_location("h", os.path.join(here, "live_1092_rewind_and_forward_step_one_bar.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.embedded_commit(binary) or "")
PY
)
SHA=$(shasum -a 256 "$DEST/LogicProMCP" | cut -d' ' -f1)
printf '{"head": "%s", "embedded_commit": "%s", "sha256": "%s", "built_at": "%s"}\n' \
    "$HEAD_SHA" "$CARRIED" "$SHA" "$(date -u +%FT%TZ)" > "$DEST/build-receipt.json"
cat "$DEST/build-receipt.json"
if [ "$CARRIED" != "$HEAD_SHA" ]; then
    echo "the section does not read back as the head" >&2
    exit 1
fi
