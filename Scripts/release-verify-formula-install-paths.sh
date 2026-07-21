#!/usr/bin/env bash
set -euo pipefail

tar -tzf LogicProMCP-macOS-universal.tar.gz > tarball-listing.txt
echo "Tarball listing:"
cat tarball-listing.txt

paths=$(sed -nE 's/^[[:space:]]*(pkgshare|bin)\.install "([^"]+)".*/\2/p' Formula/logic-pro-mcp.rb)
if [ -z "$paths" ]; then
  echo "::error::Parsed no install paths from Formula/logic-pro-mcp.rb — parser or Formula layout drifted"
  exit 1
fi

fail=0
while IFS= read -r path; do
  if grep -Fxq "$path" tarball-listing.txt; then
    echo "OK: $path"
  else
    echo "::error::Formula installs '$path' but it is missing from LogicProMCP-macOS-universal.tar.gz"
    fail=1
  fi
done <<< "$paths"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "Formula install paths verified against the built tarball."

# #427: import-closure completeness. The check above is one-directional (every
# installed path exists in the tarball); it CANNOT catch a *missing* install
# line, which is exactly how v3.11.0 shipped logic_bounce.py without its shared
# dependency logic_variants.py -> ModuleNotFoundError at runtime. This asserts
# that for every Python helper the Formula installs, every `logic_*` module it
# imports is ALSO installed by the Formula. Imports are read from the EXTRACTED
# tarball (the actual shipped bytes), not the repo, so the gate verifies what
# ships and runs identically in CI and in the hermetic contract test. A future
# split/rename that adds a new intra-helper dependency fails the release at tag
# time instead of silently dropping a module from the package.
installed_pys=$(printf '%s\n' "$paths" | sed -nE 's#^Scripts/(logic_[a-z0-9_]+)\.py$#\1#p' | sort -u)
closure_extract=$(mktemp -d)
trap 'rm -rf "$closure_extract"' EXIT
tar -xzf LogicProMCP-macOS-universal.tar.gz -C "$closure_extract"
closure_fail=0
while IFS= read -r mod; do
  [ -z "$mod" ] && continue
  src="$closure_extract/Scripts/${mod}.py"
  if [ ! -f "$src" ]; then
    echo "::error::Formula installs Scripts/${mod}.py but it is absent from the built tarball"
    closure_fail=1
    continue
  fi
  # local logic_* modules this helper imports (both `import X` and `from X import`).
  # `|| true`: a helper with no logic_* imports makes grep exit 1, which would
  # trip `set -euo pipefail` and abort the gate before it finished checking.
  deps=$(grep -hoE '^(from|import) logic_[a-z0-9_]+' "$src" 2>/dev/null \
    | sed -E 's/^(from|import) //' | sort -u || true)
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if printf '%s\n' "$installed_pys" | grep -Fxq "$dep"; then
      echo "OK closure: $mod -> $dep"
    else
      echo "::error::Formula installs Scripts/${mod}.py which imports '${dep}', but Scripts/${dep}.py is NOT in the Formula install list (incomplete package -> runtime ModuleNotFoundError). Add it to Formula/logic-pro-mcp.rb and Scripts/release-package.sh."
      closure_fail=1
    fi
  done <<< "$deps"
done <<< "$installed_pys"

if [ "$closure_fail" -ne 0 ]; then
  exit 1
fi

echo "Python helper import-closure verified: every imported logic_* module is packaged."
