#!/usr/bin/env python3
"""Issue #683: MCU feedback must not wedge a live stdio JSON-RPC server.

The companion C helper uses CoreMIDI directly because Python has no system
binding for virtual endpoints.  It creates a virtual source and a MIDI Thru
route to the destination created by LogicProMCP, then sends a captured MCU
traffic mix while this process drives initialize/initialized/tools/list.
"""

import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
from typing import Optional
import time
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
DRIVER_SOURCE = REPO / "Scripts" / "issue683_mcu_feedback_driver.c"
TARGET_PORT = "LogicProMCP-MCU-Internal"
CORE_MIDI_UNAVAILABLE = 77
TOOLS_LIST_TIMEOUT_SECONDS = 3.0


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def skip(message: str) -> None:
    # A skipped CoreMIDI exercise is deliberately loud: a green exit in this
    # environment is not evidence that the integration path ran.
    print(f"SKIP: {message}")
    raise SystemExit(0)


def build_paths() -> tuple[Path, Path]:
    try:
        bin_path = subprocess.check_output(
            ["swift", "build", "--disable-sandbox", "--show-bin-path"], cwd=REPO, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"could not locate Swift build products: {error}")
    server = Path(bin_path) / "LogicProMCP"
    if not server.exists():
        try:
            subprocess.run(
                ["swift", "build", "--disable-sandbox", "--product", "LogicProMCP"], cwd=REPO, check=True
            )
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f"could not build LogicProMCP: {error}")
    if not server.exists():
        fail(f"LogicProMCP binary is absent at {server}")
    compiler = shutil.which("clang")
    if compiler is None:
        skip("clang/CoreMIDI SDK is unavailable on this runner")
    temp_dir = Path(tempfile.mkdtemp(prefix="logic-pro-mcp-issue683-"))
    driver = temp_dir / "mcu-feedback-driver"
    try:
        subprocess.run(
            [compiler, str(DRIVER_SOURCE), "-framework", "CoreMIDI", "-framework", "CoreFoundation", "-o", str(driver)],
            cwd=REPO,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as error:
        skip(f"CoreMIDI harness could not compile: {error.stderr.strip()}")
    return server, driver


def write_frame(process: subprocess.Popen[str], frame: dict) -> None:
    if process.stdin is None:
        fail("server stdin is unavailable")
    process.stdin.write(json.dumps(frame, separators=(",", ":")) + "\n")
    process.stdin.flush()


def read_frame(process: subprocess.Popen[str], timeout: float) -> dict:
    if process.stdout is None:
        fail("server stdout is unavailable")
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        fail(f"no JSON-RPC reply within {timeout:.1f}s")
    line = process.stdout.readline()
    if not line:
        fail("server closed stdout before replying")
    try:
        return json.loads(line)
    except json.JSONDecodeError as error:
        fail(f"server emitted invalid JSON-RPC frame: {error}: {line!r}")


def stop(process: subprocess.Popen[str]) -> str:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    return process.stderr.read() if process.stderr is not None else ""


def start_feedback_driver(driver: Path) -> subprocess.Popen[str]:
    feedback = subprocess.Popen(
        [str(driver), TARGET_PORT], cwd=REPO, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if feedback.stdout is None:
        fail("CoreMIDI feedback driver stdout is unavailable")
    ready, _, _ = select.select([feedback.stdout], [], [], TOOLS_LIST_TIMEOUT_SECONDS)
    if ready:
        marker = feedback.stdout.readline().strip()
        if marker == "SENDING":
            return feedback
    driver_stdout, driver_stderr = feedback.communicate(timeout=5)
    if feedback.returncode == CORE_MIDI_UNAVAILABLE:
        skip(driver_stderr.strip() or "CoreMIDI is unavailable or not permitted")
    fail(
        f"CoreMIDI feedback driver did not route its first packet "
        f"(exit {feedback.returncode}): {driver_stderr.strip() or driver_stdout.strip()}"
    )


def core_midi_refuses_a_client(driver: Path) -> Optional[str]:
    """Ask CoreMIDI directly whether it will serve this host right now.

    Without this the check reports FAIL for a condition it cannot do anything
    about. MIDIServer is an on-demand daemon: it exits when idle, relaunches on
    the next connection, and can die outright — measured on a developer host,
    with crash reports, after which every `MIDIClientCreate` in every process
    returns -2 until it comes back. A run started inside that window fails for
    a reason that has nothing to do with the server under test.

    It probes with the same driver binary, which returns CORE_MIDI_UNAVAILABLE
    when it cannot get a client or an output port, so the probe cannot disagree
    with what the real run would hit. It is not vacuous: when CoreMIDI IS
    serving, this returns None and every later failure is reported as a failure.
    """
    probe = subprocess.run(
        [str(driver), "LogicProMCP-CoreMIDI-Availability-Probe"],
        cwd=REPO, text=True, capture_output=True, timeout=20,
    )
    if probe.returncode == CORE_MIDI_UNAVAILABLE:
        return probe.stderr.strip() or "CoreMIDI refused this process a client"
    return None


def main() -> None:
    server, driver = build_paths()
    refusal = core_midi_refuses_a_client(driver)
    if refusal is not None:
        skip(f"CoreMIDI is not serving this host: {refusal}")
    process = subprocess.Popen(
        [str(server)],
        cwd=REPO,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        write_frame(process, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26", "capabilities": {},
                "clientInfo": {"name": "issue683-repro", "version": "1"},
            },
        })
        initialized = read_frame(process, TOOLS_LIST_TIMEOUT_SECONDS)
        if initialized.get("id") != 1 or "result" not in initialized:
            fail(f"initialize did not succeed: {initialized}")

        feedback = start_feedback_driver(driver)
        # The driver owns the feedback stream while stdio sends the normal MCP
        # post-initialize notification and a protocol-local request.
        write_frame(process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        write_frame(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        reply = read_frame(process, TOOLS_LIST_TIMEOUT_SECONDS)

        driver_stdout, driver_stderr = feedback.communicate(timeout=5)
        if feedback.returncode == CORE_MIDI_UNAVAILABLE:
            skip(driver_stderr.strip() or "CoreMIDI is unavailable or not permitted")
        if feedback.returncode != 0:
            fail(
                f"CoreMIDI feedback driver exited {feedback.returncode}: "
                f"{driver_stderr.strip() or driver_stdout.strip()}"
            )
        if reply.get("id") != 2 or "result" not in reply:
            fail(f"tools/list did not receive a result: {reply}")
        tools = reply["result"].get("tools")
        if not isinstance(tools, list) or not tools:
            fail("tools/list result has no tools array")
        print("PASS: tools/list replied while 142 MCU feedback packets were routed to the server")
    finally:
        stderr = stop(process)
        if process.returncode not in (0, -15):
            print(f"server stderr after failure:\n{stderr}", file=sys.stderr)


if __name__ == "__main__":
    main()
