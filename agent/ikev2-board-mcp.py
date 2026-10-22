#!/usr/bin/env python3
"""MCP server for the office board's requests, for Claude Code and Codex alike.

It speaks MCP over stdio and reaches one router over SSH with a key whose
authorized_keys entry forces "/usr/libexec/ikev2-board agent": the router
decides what may be done, this server only names it.

    claude mcp add office -- python3 agent/ikev2-board-mcp.py --router home
    codex mcp add office -- python3 agent/ikev2-board-mcp.py --router home

Routers are named in ~/.config/ikev2-board/routers.json, never in this
repository:

    {"home": {"host": "192.0.2.1", "port": 22, "user": "root",
              "key": "~/.ssh/ikev2-board-home"}}
"""

import argparse
import json
import os
import re
import subprocess
import sys

CONFIG = os.path.expanduser("~/.config/ikev2-board/routers.json")
PROTOCOL = "2025-06-18"
ID = re.compile(r"^[0-9a-f-]{1,40}$")
DOMAIN = re.compile(r"^[a-z0-9]([a-z0-9-]{0,62}\.)+[a-z]{2,63}$")

TOOLS = [
    {"name": "list_requests", "description": "The newest office requests (up to 50): who asked, which service or site does not work, what happens, status and note.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "show_request", "description": "One request in full.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}},
    {"name": "get_picture", "description": "Screenshot N (1-3) attached to a request.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "number": {"type": "integer", "minimum": 1, "maximum": 3}}, "required": ["id", "number"]}},
    {"name": "services", "description": "Services that go through the tunnel, each with its domains, and the operator's own domains.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "trace_domain", "description": "How the router routes one domain now: which list or service matches it, the exit, the FakeIP address and the link.",
     "inputSchema": {"type": "object", "properties": {"domain": {"type": "string"}}, "required": ["domain"]}},
    {"name": "set_status", "description": "Set a request's status (new, working, done, rejected) with a short note colleagues see on the board.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "status": {"type": "string", "enum": ["new", "working", "done", "rejected"]}, "note": {"type": "string", "maxLength": 300}}, "required": ["id", "status"]}},
    {"name": "add_domains", "description": "Route these domains through the tunnel (the operator's own list). Changes the router: first show the user the exact domains and why, and call this only after the user confirmed in this chat; pass confirmed=true then.",
     "inputSchema": {"type": "object", "properties": {"domains": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 20}, "confirmed": {"type": "boolean"}}, "required": ["domains", "confirmed"]}},
]


class Refused(Exception):
    pass


def router(name):
    try:
        with open(CONFIG, encoding="utf-8") as handle:
            entry = json.load(handle)[name]
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f"ikev2-board-mcp: router '{name}' is not configured in {CONFIG}: {error}")
    return entry


def call(target, *words):
    command = [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "IdentitiesOnly=yes",
        "-i", os.path.expanduser(target["key"]), "-p", str(target.get("port", 22)),
        f"{target.get('user', 'root')}@{target['host']}", " ".join(words),
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise Refused((result.stderr or result.stdout).strip() or f"router answered {result.returncode}")
    return result.stdout


def run_tool(target, name, args):
    if name == "list_requests":
        return call(target, "list")
    if name == "show_request" or name == "get_picture":
        if not ID.match(str(args.get("id", ""))):
            raise Refused("expected a request id")
        if name == "show_request":
            return call(target, "show", args["id"])
        number = int(args.get("number", 0))
        if number not in (1, 2, 3):
            raise Refused("expected a picture number 1-3")
        data = call(target, "picture", args["id"], str(number)).strip()
        kind = "image/png" if data.startswith("iVBOR") else "image/jpeg"
        return {"type": "image", "data": data, "mimeType": kind}
    if name == "services":
        return call(target, "services")
    if name == "trace_domain":
        domain = str(args.get("domain", "")).lower()
        if not DOMAIN.match(domain):
            raise Refused("expected a domain")
        return call(target, "trace", domain)
    if name == "set_status":
        if not ID.match(str(args.get("id", ""))) or args.get("status") not in ("new", "working", "done", "rejected"):
            raise Refused("expected a request id and a status")
        # The router splits the command on spaces; the note is only text.
        note = re.sub(r"[^\w .,:;!?()/@+-]", "", str(args.get("note", "")), flags=re.UNICODE)[:300]
        return call(target, "status", args["id"], args["status"], note) or "ok"
    if name == "add_domains":
        if args.get("confirmed") is not True:
            raise Refused("ask the user first and pass confirmed=true once they agreed")
        domains = [str(d).lower() for d in args.get("domains", [])]
        if not domains or len(domains) > 20 or not all(DOMAIN.match(d) for d in domains):
            raise Refused("expected 1-20 domains")
        return call(target, "add-domains", *domains)
    raise Refused(f"unknown tool {name}")


def answer(message_id, result=None, error=None):
    reply = {"jsonrpc": "2.0", "id": message_id}
    if error is not None:
        reply["error"] = error
    else:
        reply["result"] = result
    sys.stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--router", required=True)
    target = router(parser.parse_args().router)
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method, message_id = message.get("method"), message.get("id")
        if message_id is None:
            continue
        if method == "initialize":
            answer(message_id, {"protocolVersion": message.get("params", {}).get("protocolVersion", PROTOCOL),
                                "capabilities": {"tools": {}},
                                "serverInfo": {"name": "ikev2-board", "version": "1"}})
        elif method == "tools/list":
            answer(message_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = message.get("params", {})
            try:
                output = run_tool(target, params.get("name"), params.get("arguments") or {})
                content = [output] if isinstance(output, dict) else [{"type": "text", "text": output}]
                answer(message_id, {"content": content})
            except (Refused, subprocess.TimeoutExpired, ValueError) as error:
                answer(message_id, {"content": [{"type": "text", "text": str(error)}], "isError": True})
        elif method == "ping":
            answer(message_id, {})
        else:
            answer(message_id, error={"code": -32601, "message": "method not found"})


if __name__ == "__main__":
    main()
