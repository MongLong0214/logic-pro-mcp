#!/bin/bash
# LogicProMCP Full Uninstaller
# Rolls back all MCP server artifacts (PRD §9.3)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${LOGIC_PRO_MCP_INSTALL_DIR:-/usr/local/bin}"
SKIP_SUDO="${LOGIC_PRO_MCP_SKIP_SUDO:-0}"

fail_uninstall() {
    echo "Error: $1"
    exit 1
}

fail_path_validation() {
    fail_uninstall "$1"
}

# uninstall.sh relies on the shared path/validation helpers (normalize_path,
# validate_*). install-common.sh is not shipped in the release tarball, so guard
# the source: a bare `source` under `set -e` would abort with an opaque error if
# uninstall.sh is fetched/run detached from its sibling (mirroring the curl
# install pattern). Fail with an actionable message instead.
if [ -f "$SCRIPT_DIR/install-common.sh" ]; then
    source "$SCRIPT_DIR/install-common.sh"
else
    fail_uninstall "install-common.sh not found next to uninstall.sh ($SCRIPT_DIR); run uninstall.sh from a full checkout that includes Scripts/install-common.sh"
fi

if [ -n "${LOGIC_PRO_MCP_APPROVAL_STORE:-}" ]; then
    fail_uninstall "LOGIC_PRO_MCP_APPROVAL_STORE override is not supported by uninstall.sh"
fi

INSTALL_DIR="$(normalize_path "$INSTALL_DIR")"
BINARY="$INSTALL_DIR/LogicProMCP"
APPROVAL_STORE="$(normalize_path "$HOME/Library/Application Support/LogicProMCP/operator-approvals.json")"
APPROVAL_LOCK="$APPROVAL_STORE.lock"
LAUNCH_AGENT="$(normalize_path "$HOME/Library/LaunchAgents/com.logicpro.mcp.plist")"
LAUNCH_AGENT_SERVICE="gui/$UID/com.logicpro.mcp"

if [ "$(basename "$INSTALL_DIR")" = "bin" ]; then
    INSTALL_PREFIX="$(normalize_path "$(dirname "$INSTALL_DIR")")"
else
    INSTALL_PREFIX="$(normalize_path "$INSTALL_DIR")"
fi
SHARE_DIR="$(normalize_path "${LOGIC_PRO_MCP_SHARE_DIR:-$INSTALL_PREFIX/share/logic-pro-mcp}")"

validate_install_dir "$INSTALL_DIR"
validate_share_dir "$SHARE_DIR"
validate_approval_store "$APPROVAL_STORE"

echo "=== LogicProMCP Full Uninstaller ==="
echo ""

# 1. Stop and remove the exact legacy launch agent before deleting its binary.
# The plist uses KeepAlive, so a failed bootout must leave both the plist and
# binary intact rather than creating a restart loop or a partial uninstall.
launch_agent_service_status() {
    launchctl print "$LAUNCH_AGENT_SERVICE" >/dev/null 2>&1
}

LAUNCH_AGENT_HOLD=""

restore_held_launch_agent_plist() {
    if [ -z "$LAUNCH_AGENT_HOLD" ] || { [ ! -e "$LAUNCH_AGENT_HOLD" ] && [ ! -L "$LAUNCH_AGENT_HOLD" ]; }; then
        return 0
    fi
    if [ -e "$LAUNCH_AGENT" ] || [ -L "$LAUNCH_AGENT" ]; then
        fail_uninstall "Uninstall unsuccessful: launch agent plist path reappeared while the original remained preserved."
    fi
    if ! mv "$LAUNCH_AGENT_HOLD" "$LAUNCH_AGENT"; then
        fail_uninstall "Uninstall unsuccessful: preserved launch agent plist could not be restored after service cleanup failed."
    fi
    LAUNCH_AGENT_HOLD=""
}

fail_launch_agent_cleanup() {
    local message="$1"
    local restore_plist="${2:-0}"
    if [ "$restore_plist" -eq 1 ]; then
        restore_held_launch_agent_plist
    fi
    fail_uninstall "$message"
}

wait_for_launch_agent_absence() {
    local attempt
    local status
    LAUNCH_AGENT_WAIT_OUTCOME="indeterminate"
    for attempt in 1 2 3 4 5; do
        if launch_agent_service_status; then
            if [ "$attempt" -lt 5 ]; then
                sleep 0.1
                continue
            fi
            LAUNCH_AGENT_WAIT_OUTCOME="loaded"
            return 0
        else
            status=$?
            if [ "$status" -eq 113 ]; then
                LAUNCH_AGENT_WAIT_OUTCOME="absent"
                return 0
            fi
            return 0
        fi
    done
    LAUNCH_AGENT_WAIT_OUTCOME="loaded"
    return 0
}

stop_launch_agent_service() {
    local bootout_status=0
    local restore_plist="${1:-0}"
    if launchctl bootout "$LAUNCH_AGENT_SERVICE" >/dev/null 2>&1; then
        :
    else
        bootout_status=$?
    fi

    wait_for_launch_agent_absence
    case "$LAUNCH_AGENT_WAIT_OUTCOME" in
        absent)
            return 0
            ;;
        loaded)
            if [ "$bootout_status" -ne 0 ]; then
                fail_launch_agent_cleanup "Uninstall unsuccessful: launch agent service could not be stopped and remains loaded." "$restore_plist"
            fi
            fail_launch_agent_cleanup "Uninstall unsuccessful: launch agent service remains loaded." "$restore_plist"
            ;;
        *)
            fail_launch_agent_cleanup "Uninstall unsuccessful: launch agent service removal could not be verified." "$restore_plist"
            ;;
    esac
}

if launch_agent_service_status; then
    stop_launch_agent_service
    echo "✓ Removed launch agent service: $LAUNCH_AGENT_SERVICE"
else
    STATUS=$?
    if [ "$STATUS" -ne 113 ]; then
        fail_uninstall "Uninstall unsuccessful: launch agent service state could not be established."
    fi
    echo "Launch agent service not loaded — skipped."
fi

if [ -e "$LAUNCH_AGENT" ] || [ -L "$LAUNCH_AGENT" ]; then
    LAUNCH_AGENT_HOLD="${LAUNCH_AGENT}.logicpromcp-uninstall.$$"
    if [ -e "$LAUNCH_AGENT_HOLD" ] || [ -L "$LAUNCH_AGENT_HOLD" ]; then
        fail_uninstall "Uninstall unsuccessful: launch agent plist staging path already exists."
    fi
    if ! mv "$LAUNCH_AGENT" "$LAUNCH_AGENT_HOLD"; then
        fail_uninstall "Uninstall unsuccessful: launch agent plist could not be staged for removal."
    fi
    if [ -e "$LAUNCH_AGENT" ] || [ -L "$LAUNCH_AGENT" ] || { [ ! -e "$LAUNCH_AGENT_HOLD" ] && [ ! -L "$LAUNCH_AGENT_HOLD" ]; }; then
        restore_held_launch_agent_plist
        fail_uninstall "Uninstall unsuccessful: launch agent plist staging could not be verified."
    fi
else
    echo "Launch agent plist not found — skipped."
fi

# Close the KeepAlive race: the exact service can reappear between the first
# absence readback and plist removal. With the plist now absent, stop that same
# owned service once more if needed and refuse before binary deletion unless its
# final state is observed absent.
if launch_agent_service_status; then
    stop_launch_agent_service 1
    echo "✓ Removed reloaded launch agent service: $LAUNCH_AGENT_SERVICE"
else
    STATUS=$?
    if [ "$STATUS" -ne 113 ]; then
        fail_launch_agent_cleanup "Uninstall unsuccessful: final launch agent service state could not be established." 1
    fi
fi

if [ -n "$LAUNCH_AGENT_HOLD" ]; then
    if rm -f "$LAUNCH_AGENT_HOLD"; then
        :
    elif [ -e "$LAUNCH_AGENT_HOLD" ] || [ -L "$LAUNCH_AGENT_HOLD" ]; then
        restore_held_launch_agent_plist
        fail_uninstall "Uninstall unsuccessful: launch agent plist could not be removed from staging."
    fi
    if [ -e "$LAUNCH_AGENT_HOLD" ] || [ -L "$LAUNCH_AGENT_HOLD" ]; then
        restore_held_launch_agent_plist
        fail_uninstall "Uninstall unsuccessful: staged launch agent plist remains after removal."
    fi
    LAUNCH_AGENT_HOLD=""
    echo "✓ Removed launch agent plist: $LAUNCH_AGENT"
fi

# 2. Remove operator approvals
if [ -f "$APPROVAL_STORE" ] || [ -f "$APPROVAL_LOCK" ]; then
    rm -f "$APPROVAL_STORE" "$APPROVAL_LOCK"
    echo "✓ Removed operator approvals: $APPROVAL_STORE (and lock sidecar when present)"
else
    echo "Operator approvals not found — skipped."
fi

# 3. Remove binary
if [ -f "$BINARY" ]; then
    USE_SUDO=0
    if ! { [ "$SKIP_SUDO" = "1" ] || [ -w "$INSTALL_DIR" ]; }; then
        USE_SUDO=1
    fi
    run_with_optional_sudo "$USE_SUDO" rm "$BINARY"
    echo "✓ Removed binary: $BINARY"
else
    echo "Binary not found — skipped."
fi

# 4. Uninstall Key Commands
if [ -f "$SHARE_DIR/uninstall-keycmds.sh" ]; then
    echo ""
    bash "$SHARE_DIR/uninstall-keycmds.sh"
elif [ -f "$SCRIPT_DIR/uninstall-keycmds.sh" ]; then
    echo ""
    bash "$SCRIPT_DIR/uninstall-keycmds.sh"
else
    echo "Key Commands uninstaller not found — skipped."
fi

if [ -d "$SHARE_DIR" ]; then
    USE_SUDO=0
    if ! { [ "$SKIP_SUDO" = "1" ] || [ -w "$SHARE_DIR" ] || [ -w "$(dirname "$SHARE_DIR")" ]; }; then
        USE_SUDO=1
    fi
    run_with_optional_sudo "$USE_SUDO" rm -rf "$SHARE_DIR"
    echo "✓ Removed shared assets: $SHARE_DIR"
else
    echo "Shared assets not found — skipped."
fi

# 5. Remove MCP registration
echo ""
if command -v claude >/dev/null 2>&1; then
    if claude mcp remove logic-pro >/dev/null 2>&1; then
        echo "✓ Removed Claude Code registration: logic-pro"
    else
        fail_uninstall "Uninstall unsuccessful: Claude Code deregistration failed or could not be established."
    fi
else
    fail_uninstall "Uninstall unsuccessful: Claude Code deregistration is unavailable because the CLI is missing."
fi
echo ""

# Logic-resident Scripter/MCU state has no programmatic removal/readback path.
# Preserve the completed filesystem/registration effects and terminate with the
# exact residual instead of requesting an operator cleanup.
fail_uninstall "Uninstall unsuccessful: Logic-resident Scripter/MCU state is unverified."
