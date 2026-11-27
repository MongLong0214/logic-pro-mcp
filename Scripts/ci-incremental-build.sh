#!/usr/bin/env bash
# Incremental build for the hosted test-build job, on top of a restored `.build`.
#
#   ci-incremental-build.sh key   <build command...>   print the toolchain-and-flags part of the cache key
#   ci-incremental-build.sh build <build command...>   restore source mtimes, build, and fall back to a clean build
#
# The cache key and the build take the SAME command words, so a flag change is a different key.
# `swift build` remains the judge of what is out of date; this script only makes a freshly
# checked-out tree look unchanged where its content is unchanged (Scripts/ci-restore-source-mtimes.py)
# and makes sure a bad cache can cost time but never fail the job.
set -euo pipefail

state=".build/ci-source-state.tsv"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sha() { shasum -a 256 | cut -c1-16; }

case "${1:-}" in
  key)
    shift
    test "$#" -gt 0
    toolchain="$(swift --version 2>&1 | sha)"
    flags="$(printf '%s\n' "$*" | sha)"
    # The runner image version is deliberately not part of the key: images roll out unevenly and
    # an image bump that leaves the compiler and SDK alone would only turn a warm cache cold.
    # What decides whether compiled output is reusable is the compiler, the SDK and the CLT.
    sdk="$({
      xcrun --show-sdk-version 2>&1 || true
      xcrun --show-sdk-build-version 2>&1 || true
      pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>&1 | grep '^version:' || true
    } | sha)"
    echo "swift-build-${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}-swift${toolchain}-sdk${sdk}-flags${flags}"
    ;;
  build)
    shift
    test "$#" -gt 0
    restored=false
    if [ -e "$state" ]; then
      restored=true
    elif [ -e .build ]; then
      # A build directory without our state was not written by a build this script can vouch for.
      echo "::warning::.build has no source state; discarding it"
      rm -rf .build
    fi
    python3 "$here/ci-restore-source-mtimes.py"
    if "$@"; then
      exit 0
    fi
    if [ "$restored" != true ]; then
      # Already a clean build: running it again would only repeat the failure.
      exit 1
    fi
    echo "::warning::incremental build failed on a restored .build; retrying from a clean .build"
    rm -rf .build
    python3 "$here/ci-restore-source-mtimes.py"
    "$@"
    ;;
  *)
    echo "usage: $0 key|build <build command...>" >&2
    exit 2
    ;;
esac
