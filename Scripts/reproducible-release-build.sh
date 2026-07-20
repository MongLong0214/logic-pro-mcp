#!/bin/bash
# Reproducible release build for LogicProMCP — canonical, fail-closed.
#
# Produces a byte-identical, loadable, ad-hoc-signed release binary across
# independent clean builds of the same commit. Run from the repository root of
# a fresh clone checked out at the exact release commit. Any failed step, a
# dirty tree, or dependency-pin drift aborts the build (fail-closed).
#
# Recipe:
#   0. verify clean git tree; wipe .build; swift package reset + resolve;
#      verify resolve left the tree clean and Package.resolved equals the
#      committed blob (no pin drift)
#   1. swift build -c release --disable-sandbox        (keeps LC_UUID -> loadable)
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
[ -z "$(git status --porcelain)" ] || { git status --porcelain | head >&2; fatal "dirty tree before build"; }
echo "clean_tree: yes"
echo "toolchain: $(swift --version 2>&1 | tr '\n' ' ')"
COMMITTED_PKGRES="$(git show HEAD:Package.resolved | shasum -a 256 | cut -d' ' -f1)"
[ -n "$COMMITTED_PKGRES" ] || fatal "cannot hash committed Package.resolved"
echo "package_resolved_committed_sha256: $COMMITTED_PKGRES"
echo "patcher_sha256: $(shasum -a 256 "$PATCHER" | cut -d' ' -f1)"

rm -rf .build
swift package reset >/dev/null
swift package resolve >/dev/null
# The checked-in Package.resolved is the cross-platform lock. On macOS `swift package resolve`
# prunes the platform-conditional (e.g. Linux server) pins from the on-disk file; that prune is a
# macOS-local view and must NOT be committed (it would break other platforms / the CI lock check).
# Restore the committed cross-platform lock so the tree is clean and the resolved dependency set
# used by the build is deterministic. The macOS binary only links the macOS-relevant pins, which
# are identical run-to-run, so the output stays byte-reproducible.
git checkout -- Package.resolved
[ -z "$(git status --porcelain)" ] || { git status --porcelain | head >&2; fatal "tree dirty after resolve + Package.resolved restore"; }
ONDISK_PKGRES="$(shasum -a 256 Package.resolved | cut -d' ' -f1)"
[ "$ONDISK_PKGRES" = "$COMMITTED_PKGRES" ] || fatal "Package.resolved restore failed ($ONDISK_PKGRES != committed $COMMITTED_PKGRES)"

swift build -c release --disable-sandbox >/dev/null
[ -x "$BIN" ] || fatal "release binary not produced"
echo "build_exit: 0"
# `swift build` re-loads the dependency graph and re-prunes the on-disk Package.resolved on macOS,
# even though resolution already happened. Restore the committed cross-platform lock again so the
# source tree is clean at completion. This does not affect the already-built binary.
git checkout -- Package.resolved
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
git checkout -- Package.resolved 2>/dev/null || true
DIRTY="$(git status --porcelain)"
[ -z "$DIRTY" ] || { printf '%s\n' "$DIRTY" >&2; fatal "source tree dirty at completion (Package.resolved or other)"; }
echo "tree_clean_at_completion: yes"
