#!/bin/bash
set -euo pipefail

REPO="MongLong0214/logic-pro-mcp"
BINARY="LogicProMCP"
ARCHIVE="LogicProMCP-macOS-universal.tar.gz"
INSTALL_DIR="${LOGIC_PRO_MCP_INSTALL_DIR:-/usr/local/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${LOGIC_PRO_MCP_VERSION:-v3.7.3}"
SHA256="${LOGIC_PRO_MCP_SHA256:-}"
EXPECTED_TEAM_ID="${LOGIC_PRO_MCP_TEAM_ID:-}"
REGISTER_CLAUDE="${LOGIC_PRO_MCP_REGISTER_CLAUDE:-1}"
INSTALL_KEYCMDS="${LOGIC_PRO_MCP_INSTALL_KEYCMDS:-1}"
SKIP_SUDO="${LOGIC_PRO_MCP_SKIP_SUDO:-0}"

fail_install() { echo "  Error: $1"; exit 1; }

fail_path_validation() { fail_install "$1"; }

if [ -f "$SCRIPT_DIR/install-common.sh" ]; then
    source "$SCRIPT_DIR/install-common.sh"
else
    eval '
collapse_path_segments(){ local raw="$1" absolute="$1"; if [[ "$absolute" != /* ]]; then absolute="$PWD/$absolute"; fi; local IFS=/ part; local -a path_parts; local -a stack=(); read -r -a path_parts <<<"$absolute"; for part in "${path_parts[@]}"; do case "$part" in ""|".") ;; "..") if [ "${#stack[@]}" -gt 0 ]; then unset "stack[${#stack[@]}-1]"; fi ;; *) stack+=("$part") ;; esac; done; if [ "${#stack[@]}" -eq 0 ]; then printf "/\n"; return; fi; local normalized; printf -v normalized "/%s" "${stack[@]}"; printf "%s\n" "$normalized"; }
normalize_path(){ local collapsed; collapsed="$(collapse_path_segments "$1")"; if [ -d "$collapsed" ]; then (cd "$collapsed" && pwd -P); return; fi; local parent base; parent="$(dirname "$collapsed")"; base="$(basename "$collapsed")"; if [ -d "$parent" ]; then printf "%s/%s\n" "$(cd "$parent" && pwd -P)" "$base"; return; fi; printf "%s\n" "$collapsed"; }
require_absolute_path(){ local label="$1" path="$2"; case "$path" in /*) ;; *) fail_path_validation "$label must be an absolute path: $path" ;; esac; }
validate_install_dir(){ local path="$1"; require_absolute_path "install_dir" "$path"; case "$path" in /|/System|/System/*|/private/var/db|/private/var/db/*|/etc|/etc/*|/bin|/bin/*|/sbin|/sbin/*|/usr/bin|/usr/bin/*|/usr/sbin|/usr/sbin/*) fail_path_validation "install_dir must not target a protected system path: $path" ;; esac; }
validate_share_dir(){ local path="$1"; require_absolute_path "share_dir" "$path"; case "$path" in */share/logic-pro-mcp) ;; *) fail_path_validation "share_dir must end with /share/logic-pro-mcp: $path" ;; esac; }
nearest_existing_path(){ local path="$1"; while [ ! -e "$path" ] && [ "$path" != "/" ]; do path="$(dirname "$path")"; done; printf "%s\n" "$path"; }
path_writable_without_sudo(){ local path="$1"; if [ -e "$path" ]; then [ -w "$path" ]; return; fi; [ -w "$(nearest_existing_path "$path")" ]; }
require_command(){ local name="$1" install_hint="$2"; if command -v "$name" >/dev/null 2>&1; then return 0; fi; echo "  Error: required dependency missing: $name"; echo "    $install_hint"; exit 1; }
run_with_optional_sudo(){ local use_sudo="$1"; shift; if [ "$use_sudo" = "1" ]; then sudo "$@"; else "$@"; fi; }
install_release_asset(){ local use_sudo="$1" mode="$2" source="$3" destination="$4"; run_with_optional_sudo "$use_sudo" install -m "$mode" "$source" "$destination"; }
install_optional_release_asset(){ local use_sudo="$1" mode="$2" source="$3" destination="$4"; if [ -e "$source" ]; then install_release_asset "$use_sudo" "$mode" "$source" "$destination"; fi; }
install_extracted_assets(){ local use_sudo="$1"; run_with_optional_sudo "$use_sudo" mkdir -p "$INSTALL_DIR" "$SHARE_DIR"; run_with_optional_sudo "$use_sudo" mv "$EXTRACTED_BINARY" "$INSTALL_DIR/$BINARY"; install_release_asset "$use_sudo" 0644 "$EXTRACTED_SETUP" "$SHARE_DIR/SETUP.md"; install_release_asset "$use_sudo" 0755 "$EXTRACTED_INSTALL_KEYCMDS" "$SHARE_DIR/install-keycmds.sh"; install_release_asset "$use_sudo" 0755 "$EXTRACTED_UNINSTALL_KEYCMDS" "$SHARE_DIR/uninstall-keycmds.sh"; install_release_asset "$use_sudo" 0644 "$EXTRACTED_KEYCMD_PRESET" "$SHARE_DIR/keycmd-preset.plist"; install_release_asset "$use_sudo" 0644 "$EXTRACTED_SCRIPTER" "$SHARE_DIR/LogicProMCP-Scripter.js"; install_optional_release_asset "$use_sudo" 0755 "$EXTRACTED_BOUNCE" "$SHARE_DIR/logic_bounce.py"; install_optional_release_asset "$use_sudo" 0755 "$EXTRACTED_BOUNCE_UI" "$SHARE_DIR/logic_bounce_ui.py"; install_optional_release_asset "$use_sudo" 0755 "$EXTRACTED_UI_JXA" "$SHARE_DIR/logic_ui_jxa.py"; install_optional_release_asset "$use_sudo" 0755 "$EXTRACTED_INPUT_SOURCE" "$SHARE_DIR/logic_input_source.py"; }
'
fi

INSTALL_DIR="$(normalize_path "$INSTALL_DIR")"
if [ "$(basename "$INSTALL_DIR")" = "bin" ]; then INSTALL_PREFIX="$(normalize_path "$(dirname "$INSTALL_DIR")")"; else INSTALL_PREFIX="$(normalize_path "$INSTALL_DIR")"; fi
SHARE_DIR="$(normalize_path "${LOGIC_PRO_MCP_SHARE_DIR:-$INSTALL_PREFIX/share/logic-pro-mcp}")"

validate_install_dir "$INSTALL_DIR"
validate_share_dir "$SHARE_DIR"

validate_release_archive_manifest() {
    local archive="$1"
    local line mode path type_char
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        mode="${1:-}"
        path="${9:-}"
        if [ -z "$mode" ] || [ -z "$path" ]; then
            fail_install "could not parse release archive entry: $line"
        fi
        type_char="${mode%"${mode#?}"}"
        case "$type_char" in
            -|d) ;;
            *) fail_install "release archive contains unsupported entry type for $path: $type_char" ;;
        esac
        case "$path" in
            /*|../*|*/../*|*/..|..)
                fail_install "release archive contains unsafe path: $path"
                ;;
            LogicProMCP|docs|docs/|docs/SETUP.md|Scripts|Scripts/|Scripts/install-keycmds.sh|Scripts/uninstall-keycmds.sh|Scripts/keycmd-preset.plist|Scripts/LogicProMCP-Scripter.js|Scripts/logic_bounce.py|Scripts/logic_bounce_ui.py|Scripts/logic_ui_jxa.py|Scripts/logic_input_source.py)
                ;;
            *)
                fail_install "release archive contains unexpected path: $path"
                ;;
        esac
    done < <(tar -tvzf "$archive")
}

validate_extracted_asset_file() {
    local path="$1"
    if [ ! -e "$path" ]; then
        fail_install "release archive is missing required asset: $path"
    fi
    if [ -L "$path" ] || [ ! -f "$path" ]; then
        fail_install "release archive asset must be a regular file: $path"
    fi
}

validate_optional_extracted_asset_file() {
    local path="$1"
    if [ -e "$path" ]; then
        validate_extracted_asset_file "$path"
    fi
}

verify_signature() {
    local binary_path="$1"

    if ! command -v codesign >/dev/null 2>&1; then
        echo "  Error: codesign not available for signature verification."
        return 1
    fi

    echo "  Verifying code signature..."
    if ! codesign --verify --strict --verbose=2 "$binary_path" >/dev/null 2>&1; then
        echo "  Error: code signature verification failed."
        return 1
    fi

    # ADHOC releases (no Apple Developer Program membership) skip TeamID check —
    # they are pinned only by SHA256 manifest in the same release.
    if [ "$EXPECTED_TEAM_ID" = "ADHOC" ]; then
        return 0
    fi

    if [ -n "$EXPECTED_TEAM_ID" ]; then
        local actual_team_id
        actual_team_id=$(codesign -dv --verbose=4 "$binary_path" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
        if [ "$actual_team_id" != "$EXPECTED_TEAM_ID" ]; then
            echo "  Error: TeamIdentifier mismatch."
            echo "    expected: $EXPECTED_TEAM_ID"
            echo "    actual:   ${actual_team_id:-<none>}"
            return 1
        fi
    fi
}

verify_gatekeeper() {
    local binary_path="$1"

    # ADHOC releases are not notarized; Gatekeeper will reject. Skip the
    # assessment for this release type — SHA256 + codesign --verify still
    # guarantee the binary wasn't tampered with in transit.
    if [ "$EXPECTED_TEAM_ID" = "ADHOC" ]; then
        echo "  Skipping Gatekeeper assessment (ADHOC release)."
        return 0
    fi

    if ! command -v spctl >/dev/null 2>&1; then
        echo "  Error: spctl not available for Gatekeeper assessment."
        return 1
    fi

    echo "  Verifying Gatekeeper assessment..."
    if ! spctl --assess --type execute "$binary_path" >/dev/null 2>&1; then
        echo "  Error: Gatekeeper assessment failed. Binary is not notarized/stapled for this machine."
        return 1
    fi
}

strip_quarantine() {
    # macOS quarantine attribute from GitHub download blocks execution on first
    # run ("cannot be opened because the developer cannot be verified") even
    # when SHA256 + codesign verify cleanly. Removing it only for the adhoc
    # case keeps notarized releases on the strict path.
    local binary_path="$1"
    if [ "$EXPECTED_TEAM_ID" = "ADHOC" ]; then
        xattr -d com.apple.quarantine "$binary_path" 2>/dev/null || true
    fi
}

echo ""
echo "  Logic Pro MCP Server — Installer"
echo ""

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86_64" ]; then
    echo "  Error: Unsupported macOS architecture: $ARCH"
    exit 1
fi

if [ "$VERSION" = "latest" ]; then
    echo "  Error: mutable 'latest' installs are not allowed in enterprise mode."
    echo "    Set LOGIC_PRO_MCP_VERSION to a pinned tag, e.g. v3.7.3."
    exit 1
fi

echo "  Downloading release $VERSION..."
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/$ARCHIVE"
SHA_URL="https://github.com/$REPO/releases/download/$VERSION/SHA256SUMS.txt"
METADATA_URL="https://github.com/$REPO/releases/download/$VERSION/RELEASE-METADATA.json"

# Fail-closed provenance policy:
#
# By default the installer REQUIRES both LOGIC_PRO_MCP_SHA256 and
# LOGIC_PRO_MCP_TEAM_ID to be supplied out-of-band. Without them we'd be
# pulling binary + SHA + signer metadata from the same GitHub release surface,
# which means an attacker who can modify the release can replace all three in
# lockstep and the "pin" check becomes a rubber stamp.
#
# Operators who knowingly accept that same-origin trust model (e.g. Homebrew
# tap users, or one-off local installs) can opt in explicitly by setting
# LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1. In that mode the missing values are
# fetched from the release and the installer prints a loud warning.
if [ -z "$SHA256" ] || [ -z "$EXPECTED_TEAM_ID" ]; then
    if [ "${LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN:-0}" != "1" ]; then
        echo "  Error: installer refuses to run with missing provenance pins."
        echo ""
        echo "  For a hardened install, set BOTH:"
        echo "    LOGIC_PRO_MCP_SHA256=<hex-from-SHA256SUMS.txt for $ARCHIVE>"
        echo "    LOGIC_PRO_MCP_TEAM_ID=<ADHOC|10-char-Team-ID>"
        echo ""
        echo "  To explicitly accept same-origin provenance (fetch SHA + Team ID"
        echo "  from the same GitHub release as the binary) set:"
        echo "    LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1"
        echo ""
        echo "  See SECURITY.md §Installer trust model for the trust tiers."
        exit 1
    fi
    echo "  ⚠  LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN=1 — fetching missing provenance"
    echo "     from the same GitHub release surface as the binary."
fi

REMOTE_PROVENANCE_USED=0
if [ -z "$SHA256" ]; then
    REMOTE_PROVENANCE_USED=1
    echo "  Fetching release SHA256 manifest..."
    SHA256=$(curl -fsSL "$SHA_URL" | awk -v artifact="$ARCHIVE" '$2 == artifact {print $1}')
    if [ -z "$SHA256" ]; then
        echo "  Error: could not resolve SHA256 for $ARCHIVE from release manifest."
        exit 1
    fi
fi

if [ -z "$EXPECTED_TEAM_ID" ]; then
    REMOTE_PROVENANCE_USED=1
    echo "  Fetching release metadata..."
    METADATA_JSON=$(curl -fsSL "$METADATA_URL")
    EXPECTED_TEAM_ID=$(printf '%s\n' "$METADATA_JSON" | sed -n 's/.*"team_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$EXPECTED_TEAM_ID" ]; then
        echo "  Error: could not resolve TeamIdentifier from release metadata."
        echo "    Expected signed release metadata at: $METADATA_URL"
        exit 1
    fi
fi

if [ "$REMOTE_PROVENANCE_USED" = "1" ]; then
    echo ""
    echo "  ⚠  Provenance values were fetched from the same GitHub release surface."
    echo "     For hardened installs, set both env vars out-of-band."
    echo "     See SECURITY.md §Installer trust model."
    echo ""
fi

TMP_DIR=$(mktemp -d)
TMP_ARCHIVE="$TMP_DIR/$ARCHIVE"
if curl -fsSL "$DOWNLOAD_URL" -o "$TMP_ARCHIVE" 2>/dev/null; then
    echo "  Verifying SHA256..."
    ACTUAL_SHA256=$(shasum -a 256 "$TMP_ARCHIVE" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$SHA256" ]; then
        echo "  Error: SHA256 mismatch."
        echo "    expected: $SHA256"
        echo "    actual:   $ACTUAL_SHA256"
        rm -rf "$TMP_DIR"
        exit 1
    fi
    validate_release_archive_manifest "$TMP_ARCHIVE"
    tar -xzf "$TMP_ARCHIVE" -C "$TMP_DIR"
    EXTRACTED_BINARY="$TMP_DIR/$BINARY"
    EXTRACTED_SETUP="$TMP_DIR/docs/SETUP.md"
    EXTRACTED_INSTALL_KEYCMDS="$TMP_DIR/Scripts/install-keycmds.sh"
    EXTRACTED_UNINSTALL_KEYCMDS="$TMP_DIR/Scripts/uninstall-keycmds.sh"
    EXTRACTED_KEYCMD_PRESET="$TMP_DIR/Scripts/keycmd-preset.plist"
    EXTRACTED_SCRIPTER="$TMP_DIR/Scripts/LogicProMCP-Scripter.js"
    EXTRACTED_BOUNCE="$TMP_DIR/Scripts/logic_bounce.py"
    EXTRACTED_BOUNCE_UI="$TMP_DIR/Scripts/logic_bounce_ui.py"
    EXTRACTED_UI_JXA="$TMP_DIR/Scripts/logic_ui_jxa.py"
    EXTRACTED_INPUT_SOURCE="$TMP_DIR/Scripts/logic_input_source.py"
    for required in "$EXTRACTED_BINARY" "$EXTRACTED_SETUP" "$EXTRACTED_INSTALL_KEYCMDS" "$EXTRACTED_UNINSTALL_KEYCMDS" "$EXTRACTED_KEYCMD_PRESET" "$EXTRACTED_SCRIPTER"; do validate_extracted_asset_file "$required"; done
    validate_optional_extracted_asset_file "$EXTRACTED_BOUNCE"
    validate_optional_extracted_asset_file "$EXTRACTED_BOUNCE_UI"
    validate_optional_extracted_asset_file "$EXTRACTED_UI_JXA"
    validate_optional_extracted_asset_file "$EXTRACTED_INPUT_SOURCE"

    verify_signature "$EXTRACTED_BINARY"
    verify_gatekeeper "$EXTRACTED_BINARY"
    strip_quarantine "$EXTRACTED_BINARY"
    require_command "cliclick" "Install it first: brew install cliclick"
    chmod +x "$EXTRACTED_BINARY"
    echo "  Installing to $INSTALL_DIR/$BINARY..."
    USE_SUDO=0
    if [ "$SKIP_SUDO" != "1" ] && ! { path_writable_without_sudo "$INSTALL_DIR" && path_writable_without_sudo "$SHARE_DIR"; }; then USE_SUDO=1; fi
    install_extracted_assets "$USE_SUDO"
    rm -rf "$TMP_DIR"
    echo "  Done."
else
    echo "  Error: failed to download pinned release artifact."
    rm -rf "$TMP_DIR"
    exit 1
fi

echo ""

# Register with Claude by default when available.
if [ "$REGISTER_CLAUDE" = "1" ] && command -v claude &>/dev/null; then
    echo "  Registering with Claude Code..."
    claude mcp add --scope user logic-pro -e "LOGIC_PRO_MCP_SHARE_DIR=$SHARE_DIR" -- "$INSTALL_DIR/$BINARY" 2>/dev/null && echo "  Registered." || echo "  Already registered."
else
    echo "  Claude registration skipped."
    echo "    Manual command: claude mcp add --scope user logic-pro -e LOGIC_PRO_MCP_SHARE_DIR=\"$SHARE_DIR\" -- \"$INSTALL_DIR/$BINARY\""
fi

echo ""

if [ -f "$SHARE_DIR/install-keycmds.sh" ]; then
    if [ "$INSTALL_KEYCMDS" = "1" ]; then
        # RB-6 (2026-05-08 enterprise review): the prior wording "Key
        # Commands preset installed" overstated what the inner script
        # actually does. On Logic 12.2+ the .plist cannot be Imported
        # (Logic gates that on the .logikcs format), so the script only
        # STAGES a CC→Command mapping reference for Manual MIDI Learn.
        # Wording corrected so an operator reading the install log
        # doesn't think the bindings are live.
        echo "  Staging Key Commands mapping reference..."
        if bash "$SHARE_DIR/install-keycmds.sh"; then
            echo "  Key Commands mapping reference staged. (Logic 12.2+ requires"
            echo "    Manual MIDI Learn — see docs/SETUP.md §MIDIKeyCommands.)"
        else
            echo "  Warning: Key Commands reference staging did not complete cleanly."
        fi
    else
        echo "  Key Commands mapping reference staging skipped."
        echo "    Manual command: bash $SHARE_DIR/install-keycmds.sh"
    fi
    echo ""
fi

# Check permissions
echo "  Checking permissions..."
if ! "$INSTALL_DIR/$BINARY" --check-permissions 2>&1 | sed 's/^/    /'; then
    echo "  Warning: required Logic Pro permissions are not granted yet."
fi

echo ""
echo "  Manual Logic Pro setup required before production use:"
echo "    1. Open Logic Pro"
echo "    2. Logic Pro > Control Surfaces > Setup"
echo "    3. New > Install > Mackie Control > Add"
echo "    4. Set MIDI In/Out to: LogicProMCP-MCU-Internal"
echo "    5. Insert MIDI FX > Scripter and load: $SHARE_DIR/LogicProMCP-Scripter.js"
echo "    6. (Optional) Manually MIDI-Learn a few Key Commands you actually need."
echo "       Logic Pro 12.2+ no longer accepts the legacy .plist preset import"
echo "       (the Import menu is gray on 12.2 — see docs/SETUP.md §MIDIKeyCommands)."
echo "       Most preset operations are already covered by logic_edit /"
echo "       logic_project / logic_navigate / logic_tracks / logic_transport;"
echo "       manual binding is only required for channel-only ops like"
echo "       transport.capture_recording. Audited coverage matrix in SETUP.md."
echo "    7. Approve verified manual channels:"
echo "       $INSTALL_DIR/$BINARY --approve-channel MIDIKeyCommands"
echo "       $INSTALL_DIR/$BINARY --approve-channel Scripter"
echo ""
echo "  Installation complete. Health will remain manual_validation_required"
echo "  for Key Commands and Scripter until those Logic Pro steps are done."
echo ""
