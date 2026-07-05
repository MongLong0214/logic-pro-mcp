collapse_path_segments() {
    local raw="$1"
    local absolute="$raw"
    if [[ "$absolute" != /* ]]; then
        absolute="$PWD/$absolute"
    fi

    local IFS='/'
    local part
    local -a path_parts
    local -a stack=()
    read -r -a path_parts <<<"$absolute"
    for part in "${path_parts[@]}"; do
        case "$part" in
            ""|".") ;;
            "..")
                if [ "${#stack[@]}" -gt 0 ]; then
                    unset "stack[${#stack[@]}-1]"
                fi
                ;;
            *) stack+=("$part") ;;
        esac
    done

    if [ "${#stack[@]}" -eq 0 ]; then
        printf '/\n'
        return
    fi

    local normalized
    printf -v normalized '/%s' "${stack[@]}"
    printf '%s\n' "$normalized"
}

normalize_path() {
    local collapsed
    collapsed="$(collapse_path_segments "$1")"
    if [ -d "$collapsed" ]; then
        (
            cd "$collapsed"
            pwd -P
        )
        return
    fi

    local parent
    local base
    parent="$(dirname "$collapsed")"
    base="$(basename "$collapsed")"
    if [ -d "$parent" ]; then
        printf '%s/%s\n' "$(
            cd "$parent"
            pwd -P
        )" "$base"
        return
    fi

    printf '%s\n' "$collapsed"
}

require_absolute_path() {
    local label="$1"
    local path="$2"
    case "$path" in
        /*) ;;
        *) fail_path_validation "$label must be an absolute path: $path" ;;
    esac
}

# Reject protected system paths for either install_dir or share_dir. The
# blocklist is evaluated on the REALPATH: install.sh/uninstall.sh run
# normalize_path (which resolves symlinks via `pwd -P`) before calling the
# validators. On macOS the top-level /etc and /tmp are symlinks into /private,
# so a value like `/etc` arrives here already rewritten to `/private/etc` —
# the /private mirrors below are what actually close that sudo-mv/rm-rf bypass
# (the bare spellings stay as belt-and-suspenders for paths normalize_path
# cannot resolve). /private/var is NOT blanket-denied because the macOS
# per-user temp dir lives under /private/var/folders; only the sensitive
# /private/var/db subtree is listed.
reject_protected_system_path() {
    local label="$1"
    local path="$2"
    # Match the blocklist case-INSENSITIVELY. On a case-insensitive filesystem
    # (APFS default) a case-varied spelling — /TMP, /Private/Tmp, /ETC — resolves
    # to the same world-writable/system dir, but normalize_path preserves lexical
    # casing (a non-existent intermediate can't be resolved via `pwd -P`), so a
    # case-sensitive glob would let it slip past and then `sudo mv`/install into
    # e.g. /private/tmp. Save/restore the caller's nocasematch so we don't leak it.
    local had_nocasematch=0
    if shopt -q nocasematch; then
        had_nocasematch=1
    fi
    shopt -s nocasematch
    local matched=0
    case "$path" in
        /|/System|/System/*|/etc|/etc/*|/private/etc|/private/etc/*|/tmp|/tmp/*|/private/tmp|/private/tmp/*|/private/var/db|/private/var/db/*|/bin|/bin/*|/sbin|/sbin/*|/usr/bin|/usr/bin/*|/usr/sbin|/usr/sbin/*)
            matched=1
            ;;
    esac
    if [ "$had_nocasematch" -eq 0 ]; then
        shopt -u nocasematch
    fi
    if [ "$matched" -eq 1 ]; then
        fail_path_validation "$label must not target a protected system path: $path"
    fi
}

validate_install_dir() {
    local path="$1"
    require_absolute_path "install_dir" "$path"
    reject_protected_system_path "install_dir" "$path"
}

validate_share_dir() {
    local path="$1"
    require_absolute_path "share_dir" "$path"
    reject_protected_system_path "share_dir" "$path"
    case "$path" in
        */share/logic-pro-mcp) ;;
        *) fail_path_validation "share_dir must end with /share/logic-pro-mcp: $path" ;;
    esac
}

nearest_existing_path() {
    local path="$1"
    while [ ! -e "$path" ] && [ "$path" != "/" ]; do
        path="$(dirname "$path")"
    done
    printf '%s\n' "$path"
}

path_writable_without_sudo() {
    local path="$1"
    if [ -e "$path" ]; then
        [ -w "$path" ]
        return
    fi
    [ -w "$(nearest_existing_path "$path")" ]
}

validate_approval_store() {
    local path="$1"
    require_absolute_path "approval_store" "$path"
    case "$path" in
        */Library/Application\ Support/LogicProMCP/operator-approvals.json) ;;
        *) fail_path_validation "approval_store must be the LogicProMCP operator approvals file under ~/Library/Application Support: $path" ;;
    esac
}

require_command() {
    local name="$1"
    local install_hint="$2"
    if command -v "$name" >/dev/null 2>&1; then
        return 0
    fi

    echo "  Error: required dependency missing: $name"
    echo "    $install_hint"
    exit 1
}

run_with_optional_sudo() {
    local use_sudo="$1"
    shift
    if [ "$use_sudo" = "1" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

install_release_asset() {
    local use_sudo="$1"
    local mode="$2"
    local source="$3"
    local destination="$4"
    run_with_optional_sudo "$use_sudo" install -m "$mode" "$source" "$destination"
}

install_optional_release_asset() {
    local use_sudo="$1"
    local mode="$2"
    local source="$3"
    local destination="$4"
    if [ -e "$source" ]; then
        install_release_asset "$use_sudo" "$mode" "$source" "$destination"
    fi
}

install_extracted_assets() {
    local use_sudo="$1"
    run_with_optional_sudo "$use_sudo" mkdir -p "$INSTALL_DIR" "$SHARE_DIR"
    run_with_optional_sudo "$use_sudo" mv "$EXTRACTED_BINARY" "$INSTALL_DIR/$BINARY"
    install_release_asset "$use_sudo" 0644 "$EXTRACTED_SETUP" "$SHARE_DIR/SETUP.md"
    install_release_asset "$use_sudo" 0755 "$EXTRACTED_INSTALL_KEYCMDS" "$SHARE_DIR/install-keycmds.sh"
    install_release_asset "$use_sudo" 0755 "$EXTRACTED_UNINSTALL_KEYCMDS" "$SHARE_DIR/uninstall-keycmds.sh"
    install_release_asset "$use_sudo" 0644 "$EXTRACTED_KEYCMD_PRESET" "$SHARE_DIR/keycmd-preset.plist"
    install_release_asset "$use_sudo" 0644 "$EXTRACTED_SCRIPTER" "$SHARE_DIR/LogicProMCP-Scripter.js"
    install_optional_release_asset "$use_sudo" 0755 "$EXTRACTED_BOUNCE" "$SHARE_DIR/logic_bounce.py"
    install_optional_release_asset "$use_sudo" 0755 "$EXTRACTED_BOUNCE_UI" "$SHARE_DIR/logic_bounce_ui.py"
    install_optional_release_asset "$use_sudo" 0755 "$EXTRACTED_UI_JXA" "$SHARE_DIR/logic_ui_jxa.py"
    install_optional_release_asset "$use_sudo" 0755 "$EXTRACTED_INPUT_SOURCE" "$SHARE_DIR/logic_input_source.py"
}
