#!/usr/bin/env python3
"""A stand-in MCP stdio server for test_mcp.py. Not a test itself.

Speaks newline-delimited JSON-RPC like LogicProMCP. Behaviour is chosen per request by the tool
command or the resource URI:

  tools/call  command "echo"        structuredContent {"echo": params}
              command "text"        a text content item holding JSON
              command "big"         a structuredContent string of params["n"] characters
              command "slow"        replies after params["s"] seconds
              command "swap"        holds this reply until the NEXT request arrives, then answers
                                    it before that request (a stale reply ahead of the current one)
              command "noise"       writes a non-JSON line, then the reply
              command "exit"        exits without replying
  resources/read                    contents[0].text = JSON {"uri": uri}
It also writes one line to stderr at start, which the client must capture in its file.
"""

import json
import sys
import time


def reply(rid, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()


def tool_result(command, params):
    if command == "text":
        return {"content": [{"type": "text", "text": json.dumps({"from": "text", **params})}]}
    if command == "big":
        return {"structuredContent": {"blob": "x" * int(params["n"])}}
    return {"structuredContent": {"echo": params}}


def main():
    sys.stderr.write("[INFO] fake server up\n")
    sys.stderr.flush()
    held = None
    for line in sys.stdin:
        message = json.loads(line)
        rid = message.get("id")
        method = message.get("method")
        if rid is None:
            continue
        if held is not None:
            # The earlier request is answered FIRST, so the reply line the client reads next
            # belongs to a request it has stopped waiting for.
            reply(*held)
            held = None
        if method == "initialize":
            reply(rid, {"protocolVersion": message["params"]["protocolVersion"],
                        "serverInfo": {"name": "fake"}, "capabilities": {}})
        elif method == "resources/read":
            uri = message["params"]["uri"]
            reply(rid, {"contents": [{"uri": uri, "text": json.dumps({"uri": uri})}]})
        elif method == "tools/call":
            args = message["params"]["arguments"]
            command, params = args.get("command"), args.get("params") or {}
            if command == "slow":
                time.sleep(float(params["s"]))
            if command == "exit":
                sys.exit(3)
            if command == "noise":
                sys.stdout.write("this line is not json\n")
                sys.stdout.flush()
            if command == "swap":
                held = (rid, tool_result("echo", params))
                continue
            reply(rid, tool_result(command, params))


if __name__ == "__main__":
    main()
