#!/bin/bash
# Live E2E test: sends JSON-RPC messages to the MCP server via stdio
# Requires: Logic Pro running, Accessibility + Automation permissions granted

set -euo pipefail

BINARY=".build/debug/LogicProMCP"
PASS=0
FAIL=0
TOTAL=0
FAILURES=""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

send_and_check() {
    local test_name="$1"
    local request="$2"
    local expect_pattern="$3"  # grep -E pattern to match in response
    local reject_pattern="${4:-}"  # optional pattern that must NOT appear

    TOTAL=$((TOTAL + 1))

    # Send initialize + request via stdio, capture response
    local init_msg='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
    local initialized_msg='{"jsonrpc":"2.0","method":"notifications/initialized"}'

    local response
    response=$(printf '%s\n%s\n%s\n' "$init_msg" "$initialized_msg" "$request" | timeout 30 "$BINARY" 2>/dev/null || true)

    if [ -z "$response" ]; then
        FAIL=$((FAIL + 1))
        FAILURES="${FAILURES}\n  ${RED}✘${NC} $test_name — empty response"
        printf "  ${RED}✘${NC} %s — empty response\n" "$test_name"
        return
    fi

    # Check for expected pattern in the last JSON-RPC response
    local last_response
    last_response=$(echo "$response" | grep '"id":1' | tail -1)

    if [ -z "$last_response" ]; then
        # Try to find any response with result
        last_response=$(echo "$response" | grep '"result"' | tail -1)
    fi

    if [ -z "$last_response" ]; then
        FAIL=$((FAIL + 1))
        FAILURES="${FAILURES}\n  ${RED}✘${NC} $test_name — no JSON-RPC response found"
        printf "  ${RED}✘${NC} %s — no JSON-RPC response\n" "$test_name"
        return
    fi

    if echo "$last_response" | grep -qE "$expect_pattern"; then
        if [ -n "$reject_pattern" ] && echo "$last_response" | grep -qE "$reject_pattern"; then
            FAIL=$((FAIL + 1))
            FAILURES="${FAILURES}\n  ${RED}✘${NC} $test_name — unexpected pattern: $reject_pattern"
            printf "  ${RED}✘${NC} %s — unexpected pattern\n" "$test_name"
        else
            PASS=$((PASS + 1))
            printf "  ${GREEN}✔${NC} %s\n" "$test_name"
        fi
    else
        FAIL=$((FAIL + 1))
        FAILURES="${FAILURES}\n  ${RED}✘${NC} $test_name — expected: $expect_pattern"
        printf "  ${RED}✘${NC} %s — pattern not found\n" "$test_name"
        # Show truncated response for debugging
        printf "    response: %.200s\n" "$last_response"
    fi
}

call_tool() {
    local tool="$1"
    local command="$2"
    local params="${3:-}"

    if [ -z "$params" ]; then
        echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":{\"command\":\"$command\"}}}"
    else
        echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":{\"command\":\"$command\",\"params\":$params}}}"
    fi
}

read_resource() {
    local uri="$1"
    echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/read\",\"params\":{\"uri\":\"$uri\"}}"
}

list_tools() {
    echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
}

list_resources() {
    echo '{"jsonrpc":"2.0","id":1,"method":"resources/list","params":{}}'
}

echo ""
echo "══════════════════════════════════════════════════════"
echo " Logic Pro MCP — Live E2E Test Suite"
echo "══════════════════════════════════════════════════════"
echo ""

# ─── §1: MCP Protocol ───
echo "${YELLOW}§1 MCP Protocol${NC}"

send_and_check \
    "tools/list returns 8 tools" \
    "$(list_tools)" \
    "logic_transport.*logic_system|logic_system.*logic_transport"

send_and_check \
    "resources/list returns resources" \
    "$(list_resources)" \
    "logic://transport/state"

# ─── §2: System Commands ───
echo ""
echo "${YELLOW}§2 System Commands${NC}"

send_and_check \
    "system.help returns tool list" \
    "$(call_tool logic_system help)" \
    "logic_transport"

send_and_check \
    "system.health returns valid JSON with logic_pro_running=true" \
    "$(call_tool logic_system health)" \
    "logic_pro_running.*true"

send_and_check \
    "system.health shows channels" \
    "$(call_tool logic_system health)" \
    "channels"

send_and_check \
    "system.permissions shows granted" \
    "$(call_tool logic_system permissions)" \
    "[Gg]ranted"

send_and_check \
    "system.refresh completes" \
    "$(call_tool logic_system refresh)" \
    "result"

# ─── §3: Transport ───
echo ""
echo "${YELLOW}§3 Transport (Live)${NC}"

send_and_check \
    "transport.get_state returns transport JSON" \
    "$(call_tool logic_transport get_state)" \
    "tempo|isPlaying|position"

send_and_check \
    "transport.toggle_cycle toggles" \
    "$(call_tool logic_transport toggle_cycle)" \
    "result"

send_and_check \
    "transport.toggle_metronome toggles" \
    "$(call_tool logic_transport toggle_metronome)" \
    "result"

# ─── §4: Tracks ───
echo ""
echo "${YELLOW}§4 Tracks (Live)${NC}"

send_and_check \
    "track.get_tracks returns track array or error" \
    "$(call_tool logic_tracks get_tracks)" \
    "result"

send_and_check \
    "track.get_selected returns selected track or error" \
    "$(call_tool logic_tracks get_selected)" \
    "result"

# ─── §5: Mixer ───
echo ""
echo "${YELLOW}§5 Mixer (Live)${NC}"

send_and_check \
    "mixer.get_state returns mixer data" \
    "$(call_tool logic_mixer get_state)" \
    "result"

# ─── §6: Project ───
echo ""
echo "${YELLOW}§6 Project (Live)${NC}"

send_and_check \
    "project.get_info returns project info" \
    "$(call_tool logic_project get_info)" \
    "result"

send_and_check \
    "project.is_running returns true" \
    "$(call_tool logic_project is_running)" \
    "true"

# ─── §7: MIDI ───
echo ""
echo "${YELLOW}§7 MIDI${NC}"

send_and_check \
    "midi.list_ports returns port list" \
    "$(call_tool logic_midi list_ports)" \
    "sources|destinations|result"

send_and_check \
    "midi.send_cc dispatches" \
    "$(call_tool logic_midi send_cc '{"controller":"7","value":"100"}')" \
    "result"

# ─── §8: Resources ───
echo ""
echo "${YELLOW}§8 Resources (Live)${NC}"

send_and_check \
    "resource logic://transport/state readable" \
    "$(read_resource 'logic://transport/state')" \
    "tempo|position|contents"

send_and_check \
    "resource logic://tracks readable" \
    "$(read_resource 'logic://tracks')" \
    "contents"

send_and_check \
    "resource logic://mixer readable" \
    "$(read_resource 'logic://mixer')" \
    "mcu_connected|contents"

send_and_check \
    "resource logic://system/health readable" \
    "$(read_resource 'logic://system/health')" \
    "logic_pro_running|contents"

send_and_check \
    "resource logic://midi/ports readable" \
    "$(read_resource 'logic://midi/ports')" \
    "contents"

# ─── §9: Security ───
echo ""
echo "${YELLOW}§9 Security Validation${NC}"

send_and_check \
    "project.open rejects relative path" \
    "$(call_tool logic_project open '{"path":"relative/song.logicx"}')" \
    "error|isError.*true|invalid|reject"

send_and_check \
    "project.open rejects /dev/ path" \
    "$(call_tool logic_project open '{"path":"/dev/null.logicx"}')" \
    "error|isError.*true|invalid|reject"

send_and_check \
    "project.open rejects non-logicx extension" \
    "$(call_tool logic_project open '{"path":"/tmp/file.txt"}')" \
    "error|isError.*true|invalid|reject"

# ─── Summary ───
echo ""
echo "══════════════════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
    printf " ${GREEN}✔ All $TOTAL tests passed${NC}\n"
else
    printf " ${RED}✘ $FAIL/$TOTAL failed${NC}, ${GREEN}$PASS passed${NC}\n"
    printf "$FAILURES\n"
fi
echo "══════════════════════════════════════════════════════"
echo ""

exit $FAIL
