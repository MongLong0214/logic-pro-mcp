#!/bin/bash
# Reproducible release build for LogicProMCP — canonical, fail-closed.
#
# Produces a byte-identical, loadable, ad-hoc-signed release binary across
# independent clean builds of the same commit. Run from the repository root of
# a fresh clone checked out at the exact release commit. Any failed step, a
# dirty tree, or dependency-pin drift aborts the build (fail-closed).
#
# Recipe:
#   0. verify clean git tree; wipe .build; swift package reset + resolve
#      --force-resolved-versions; verify resolve left the tree clean and
#      Package.resolved equals the committed blob (no pin drift)
#   1. swift build -c release --disable-sandbox --force-resolved-versions
#      (keeps LC_UUID -> loadable); verify the build left the tree clean
#
# Package.resolved is never put back. A lock that resolve or the build rewrote may name other
# dependency versions than the commit pins, and a binary built from them would be published as the
# commit's if the file were restored (#1098, from #1095's supplementary reviews). Any change
# refuses, and the file is kept for the caller to read.
#   2. codesign --remove-signature <bin>
#   3. strip -x <bin>                                  (remove local symbols -> deterministic content)
#   4. normalize LC_UUID to a content-derived value    (scripts/reproducible-build-uuid-patch.py)
#   5. codesign --force -s - -i LogicProMCP <bin>      (deterministic ad-hoc signature)
#
# Rationale: `swift build` alone is not byte-reproducible here — ld64 emits a
# nondeterministic local-symbol order and a per-link random LC_UUID. `strip -x`
# removes the symbol nondeterminism; the UUID patch removes the UUID
# nondeterminism while keeping a valid (loadable) LC_UUID. Both are minimal,
# audited post-link normalizations; nothing in __TEXT/__DATA is altered.
#
# Prints provenance (staged hashes, final SHA-256, UUID, codesign verify) to stdout.
set -euo pipefail
fatal() { echo "FATAL: $*" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/.build/release/LogicProMCP"
PATCHER="$HERE/reproducible-build-uuid-patch.py"
cd "$ROOT"

git rev-parse HEAD >/dev/null 2>&1 || fatal "not a git checkout"
echo "head: $(git rev-parse HEAD)"
# A `git status` that fails answers nothing on stdout; that is not a clean tree (#1095 supplementary
# review, R1095-S02), so its exit status is read before its output.
STATUS="$(git status --porcelain)" || fatal "git status did not read before the build; whether the tree is clean is unknown"
[ -z "$STATUS" ] || { printf '%s\n' "$STATUS" | head >&2; fatal "dirty tree before build"; }
echo "clean_tree: yes"
echo "toolchain: $(swift --version 2>&1 | tr '\n' ' ')"
COMMITTED_PKGRES="$(git show HEAD:Package.resolved | shasum -a 256 | cut -d' ' -f1)"
[ -n "$COMMITTED_PKGRES" ] || fatal "cannot hash committed Package.resolved"
echo "package_resolved_committed_sha256: $COMMITTED_PKGRES"
echo "patcher_sha256: $(shasum -a 256 "$PATCHER" | cut -d' ' -f1)"

rm -rf .build
swift package reset >/dev/null
swift package resolve --force-resolved-versions >/dev/null
# This file used to say that `swift package resolve` and `swift build` prune the platform-conditional
# pins from the on-disk lock on macOS, and it put the committed lock back after each. Measured on
# 2026-10-04 with Swift 6.2.4, in a fresh clone with no .build, resolve left Package.resolved
# byte-identical. A change here is therefore not assumed to be that prune: it refuses, and the
# file is kept.
STATUS="$(git status --porcelain)" || fatal "git status did not read after resolve; whether the tree is clean is unknown"
[ -z "$STATUS" ] || { printf '%s\n' "$STATUS" | head >&2; fatal "resolve changed the tree; Package.resolved is kept as resolve left it"; }
ONDISK_PKGRES="$(shasum -a 256 Package.resolved | cut -d' ' -f1)"
[ "$ONDISK_PKGRES" = "$COMMITTED_PKGRES" ] || fatal "Package.resolved does not hash as committed ($ONDISK_PKGRES != committed $COMMITTED_PKGRES)"

swift build -c release --disable-sandbox --force-resolved-versions >/dev/null
[ -x "$BIN" ] || fatal "release binary not produced"
echo "build_exit: 0"
STATUS="$(git status --porcelain)" || fatal "git status did not read after the build; whether the tree is clean is unknown"
[ -z "$STATUS" ] || { printf '%s\n' "$STATUS" | head >&2; fatal "the build changed the tree; Package.resolved is kept as the build left it"; }
echo "pre_strip_sha256: $(shasum -a 256 "$BIN" | cut -d' ' -f1)"
codesign --remove-signature "$BIN"
echo "remove_sig_exit: 0"
strip -x "$BIN"
echo "strip_exit: 0"
echo "post_strip_pre_uuid_sha256: $(shasum -a 256 "$BIN" | cut -d' ' -f1)"
python3 "$PATCHER" "$BIN"
echo "patch_exit: 0"
echo "post_uuidpatch_pre_sign_sha256: $(shasum -a 256 "$BIN" | cut -d' ' -f1)"
codesign --force -s - -i LogicProMCP "$BIN"
echo "sign_exit: 0"

echo "final_sha256: $(shasum -a 256 "$BIN" | cut -d' ' -f1)"
echo "size: $(stat -f%z "$BIN")"
UUID_OUT="$(otool -l "$BIN" | awk '/cmd LC_UUID/{f=1;next} f&&/uuid/{print $2;f=0}')"
[ -n "$UUID_OUT" ] || fatal "LC_UUID missing from final binary"
echo "uuid: $UUID_OUT"
codesign --verify --strict --verbose=4 "$BIN" 2>&1 | sed 's/^/codesign_verify: /'
# Final fail-closed guarantee: the source tree (incl. Package.resolved) must be clean at completion.
DIRTY="$(git status --porcelain)"
[ -z "$DIRTY" ] || { printf '%s\n' "$DIRTY" >&2; fatal "source tree dirty at completion (Package.resolved or other)"; }
echo "tree_clean_at_completion: yes"
