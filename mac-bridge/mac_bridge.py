#!/usr/bin/env python3
"""mac-bridge: a remote MCP server that lends this Mac to Claude sessions.

Claude (claude.ai, Claude Code cloud sessions) connects to it as a custom
connector over HTTPS. The server listens on loopback only; a reverse proxy
(Tailscale Funnel or Cloudflare Tunnel) publishes it. Every MCP request needs
an OAuth 2.1 bearer token, issued only after the owner enters the bridge
passphrase on the authorization page.

Tools: run a command on the Mac, read and write files under allowed roots,
list SSH hosts and run a command on one of them through the Mac's own SSH
configuration and agent.

Standard library only; Python 3.9+ (the macOS Command Line Tools python works).

  mac_bridge.py init --public-url https://mac.example.ts.net
  mac_bridge.py serve
  mac_bridge.py set-passphrase | revoke-all | status
"""

import argparse
import base64
import fnmatch
import glob
import getpass
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"
PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")

HOME = os.path.expanduser("~")
DEFAULT_DIR = os.path.join(HOME, "Library", "Application Support", "mac-bridge") \
    if sys.platform == "darwin" else os.path.join(HOME, ".config", "mac-bridge")
STATE_DIR = os.environ.get("MAC_BRIDGE_DIR", DEFAULT_DIR)
CONFIG_PATH = os.path.join(STATE_DIR, "config.json")
TOKENS_PATH = os.path.join(STATE_DIR, "tokens.json")
AUDIT_PATH = os.path.join(STATE_DIR, "audit.jsonl")

DEFAULT_CONFIG = {
    "listen_host": "127.0.0.1",
    "listen_port": 8765,
    "public_url": "",
    "passphrase": None,
    # allow | confirm (a dialog on the Mac, denied after the timeout) | deny
    "local_exec": "allow",
    "ssh_exec": "allow",
    "file_read": "allow",
    "file_write": "allow",
    "confirm_timeout": 60,
    # Glob patterns matched against the destination given to ssh_exec.
    # Empty list: every Host alias in ~/.ssh/config, nothing else.
    "ssh_hosts": [],
    "ssh_options": ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"],
    "shell": "/bin/zsh",
    "file_roots": ["~"],
    "file_deny": ["~/.ssh/id_*", "~/.ssh/*_key", "~/.gnupg/**", "~/Library/Keychains/**",
                  "~/Library/Application Support/mac-bridge/**", "~/.aws/credentials"],
    "max_output_bytes": 200000,
    "max_file_bytes": 5000000,
    "default_timeout": 120,
    "max_timeout": 900,
    "access_token_ttl": 3600,
    "refresh_token_ttl": 60 * 86400,
    "allowed_redirect_hosts": ["claude.ai", "claude.com", "localhost", "127.0.0.1"],
}

_lock = threading.RLock()
_failures = []          # timestamps of wrong passphrases
_pending = {}           # authorization transactions waiting for the passphrase


# ---------------------------------------------------------------- storage

def _write_private(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def _read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def load_config():
    config = dict(DEFAULT_CONFIG)
    config.update(_read_json(CONFIG_PATH, {}))
    return config


def load_tokens():
    tokens = _read_json(TOKENS_PATH, {})
    for key in ("clients", "access", "refresh"):
        tokens.setdefault(key, {})
    return tokens


def save_tokens(tokens):
    now = time.time()
    for kind in ("access", "refresh"):
        tokens[kind] = {k: v for k, v in tokens[kind].items() if v["expires"] > now}
    _write_private(TOKENS_PATH, tokens)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def hash_passphrase(passphrase):
    salt = secrets.token_bytes(16)
    rounds = 600000
    key = hashlib.pbkdf2_hmac("sha256", passphrase.encode(), salt, rounds)
    return {"salt": salt.hex(), "rounds": rounds, "hash": key.hex()}


def check_passphrase(stored, passphrase):
    if not stored:
        return False
    key = hashlib.pbkdf2_hmac("sha256", passphrase.encode(), bytes.fromhex(stored["salt"]), stored["rounds"])
    return hmac.compare_digest(key.hex(), stored["hash"])


def audit(event, **fields):
    record = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event}
    record.update(fields)
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        fd = os.open(AUDIT_PATH, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------- policy

class Denied(Exception):
    pass


def confirm_on_mac(config, title, detail):
    """Ask the person at the Mac. Anything but an explicit Allow is a denial."""
    if sys.platform != "darwin":
        return False
    text = detail if len(detail) <= 900 else detail[:900] + "…"
    script = ('display dialog item 1 of argv with title item 2 of argv '
              'buttons {"Deny", "Allow"} default button "Deny" cancel button "Deny" '
              'giving up after %d with icon caution' % int(config["confirm_timeout"]))
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", "on run argv", "-e", script, "-e", "end run",
                                 text, title], capture_output=True, text=True,
                                timeout=int(config["confirm_timeout"]) + 10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and "button returned:Allow" in result.stdout \
        and "gave up:true" not in result.stdout


def enforce(config, key, title, detail):
    mode = config.get(key, "deny")
    if mode == "allow":
        return
    if mode == "confirm" and confirm_on_mac(config, title, detail):
        return
    raise Denied("%s is %s by the bridge policy" % (key, "not confirmed" if mode == "confirm" else "disabled"))


def ssh_config_aliases():
    """Literal Host aliases from ~/.ssh/config and the files it includes."""
    aliases, seen = [], set()

    def read(path, depth):
        if depth > 5 or path in seen:
            return
        seen.add(path)
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            return
        for line in lines:
            words = line.strip().split()
            if not words or words[0].startswith("#"):
                continue
            keyword = words[0].lower()
            if keyword == "host":
                for name in words[1:]:
                    if not any(c in name for c in "*?!") and name not in aliases:
                        aliases.append(name)
            elif keyword == "include":
                for pattern in words[1:]:
                    pattern = os.path.expanduser(pattern)
                    if not os.path.isabs(pattern):
                        pattern = os.path.join(HOME, ".ssh", pattern)
                    for match in sorted(glob.glob(pattern)):
                        read(match, depth + 1)

    read(os.path.join(HOME, ".ssh", "config"), 0)
    return aliases


SSH_DESTINATION = re.compile(r"\A(?:[A-Za-z0-9._%+-]+@)?[A-Za-z0-9][A-Za-z0-9._-]*\Z")


def check_ssh_host(config, host):
    if not isinstance(host, str) or not SSH_DESTINATION.match(host):
        raise Denied("host must be an ssh alias or user@host, without options")
    name = host.split("@", 1)[-1]
    patterns = config.get("ssh_hosts") or []
    if patterns:
        if not any(fnmatch.fnmatchcase(host, p) or fnmatch.fnmatchcase(name, p) for p in patterns):
            raise Denied("host %s is not in the bridge's ssh_hosts" % host)
    elif name not in ssh_config_aliases():
        raise Denied("host %s is not a Host alias in ~/.ssh/config" % host)


def resolve_path(config, path, write):
    if not isinstance(path, str) or not path or "\0" in path:
        raise Denied("path required")
    full = os.path.realpath(os.path.expanduser(path))
    roots = [os.path.realpath(os.path.expanduser(r)) for r in config["file_roots"]]
    if not any(full == r or full.startswith(r.rstrip("/") + "/") for r in roots):
        raise Denied("path is outside the bridge's file_roots")
    # The bridge's own passphrase hash, tokens and audit log are never served.
    own = os.path.realpath(STATE_DIR)
    if full == own or full.startswith(own + "/"):
        raise Denied("path is the bridge's own state")
    for pattern in config["file_deny"]:
        pattern = os.path.expanduser(pattern)
        if pattern.endswith("/**"):
            base = os.path.realpath(pattern[:-3])
            if full == base or full.startswith(base + "/"):
                raise Denied("path is protected by the bridge's file_deny")
        elif fnmatch.fnmatch(full, os.path.join(os.path.realpath(os.path.dirname(pattern)), os.path.basename(pattern))):
            raise Denied("path is protected by the bridge's file_deny")
    return full


# ---------------------------------------------------------------- execution

def run_process(config, argv, stdin, timeout, env=None):
    limit = int(config["max_output_bytes"])
    timeout = max(1, min(int(timeout or config["default_timeout"]), int(config["max_timeout"])))
    started = time.time()
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True, env=env, cwd=HOME)
    timed_out = False
    try:
        out, err = proc.communicate(stdin.encode() if stdin else b"", timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        out, err = proc.communicate()

    def clip(data):
        text = data.decode("utf-8", errors="replace")
        if len(data) > limit:
            return text[:limit] + "\n…[truncated, %d bytes total]" % len(data)
        return text

    return {"exit_code": proc.returncode, "timed_out": timed_out, "seconds": round(time.time() - started, 2),
            "stdout": clip(out), "stderr": clip(err)}


def format_result(result):
    head = "exit_code: %s%s  (%.2fs)" % (result["exit_code"], ", TIMED OUT" if result["timed_out"] else "",
                                         result["seconds"])
    parts = [head]
    if result["stdout"]:
        parts.append("--- stdout ---\n" + result["stdout"])
    if result["stderr"]:
        parts.append("--- stderr ---\n" + result["stderr"])
    return "\n".join(parts)


def tool_mac_exec(config, args):
    command = args.get("command")
    if not isinstance(command, str) or not command.strip():
        raise Denied("command required")
    enforce(config, "local_exec", "Claude: run on this Mac", command)
    shell = config["shell"]
    cwd = args.get("cwd")
    if cwd:
        command = "cd %s && %s" % (shlex.quote(os.path.expanduser(cwd)), command)
    result = run_process(config, [shell, "-lc", command], args.get("stdin"), args.get("timeout"))
    audit("mac_exec", command=command, exit_code=result["exit_code"], timed_out=result["timed_out"])
    return format_result(result)


def tool_ssh_exec(config, args):
    host, command = args.get("host"), args.get("command")
    check_ssh_host(config, host)
    if not isinstance(command, str) or not command.strip():
        raise Denied("command required")
    enforce(config, "ssh_exec", "Claude: run on %s" % host, command)
    argv = ["/usr/bin/ssh"] + list(config["ssh_options"]) + ["--", host, command]
    if not os.path.exists(argv[0]):
        argv[0] = "ssh"
    result = run_process(config, argv, args.get("stdin"), args.get("timeout"))
    audit("ssh_exec", host=host, command=command, exit_code=result["exit_code"], timed_out=result["timed_out"])
    return format_result(result)


def tool_ssh_hosts(config, args):
    aliases = ssh_config_aliases()
    patterns = config.get("ssh_hosts") or []
    lines = ["SSH Host aliases in ~/.ssh/config on the Mac:"]
    for alias in aliases:
        ok = not patterns or any(fnmatch.fnmatchcase(alias, p) for p in patterns)
        lines.append("  %s%s" % (alias, "" if ok else "   (not allowed by ssh_hosts)"))
    if patterns:
        lines.append("Allowed destination patterns: " + ", ".join(patterns))
    else:
        lines.append("Only these aliases are allowed.")
    lines.append("ssh_exec policy: %s" % config["ssh_exec"])
    return "\n".join(lines)


def tool_read_file(config, args):
    path = resolve_path(config, args.get("path"), False)
    enforce(config, "file_read", "Claude: read a file", path)
    size = os.path.getsize(path)
    if size > int(config["max_file_bytes"]):
        raise Denied("file is %d bytes, over max_file_bytes" % size)
    with open(path, "rb") as f:
        data = f.read()
    audit("read_file", path=path, bytes=len(data))
    try:
        text = data.decode("utf-8")
        if args.get("encoding") != "base64":
            return text
    except UnicodeDecodeError:
        pass
    return "base64:" + base64.b64encode(data).decode()


def tool_write_file(config, args):
    path = resolve_path(config, args.get("path"), True)
    content = args.get("content")
    if not isinstance(content, str):
        raise Denied("content required")
    data = base64.b64decode(content) if args.get("encoding") == "base64" else content.encode()
    if len(data) > int(config["max_file_bytes"]):
        raise Denied("content is over max_file_bytes")
    enforce(config, "file_write", "Claude: write a file", "%s (%d bytes)" % (path, len(data)))
    if os.path.exists(path) and not args.get("overwrite"):
        raise Denied("file exists; pass overwrite=true to replace it")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".mac-bridge.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    audit("write_file", path=path, bytes=len(data))
    return "wrote %d bytes to %s" % (len(data), path)


def tool_status(config, args):
    return json.dumps({
        "bridge": VERSION, "host": os.uname().nodename, "user": getpass.getuser(),
        "policy": {k: config[k] for k in ("local_exec", "ssh_exec", "file_read", "file_write")},
        "file_roots": config["file_roots"], "ssh_hosts": config["ssh_hosts"] or "aliases in ~/.ssh/config",
        "ssh_agent": bool(os.environ.get("SSH_AUTH_SOCK")),
    }, indent=2)


TIMEOUT_SCHEMA = {"type": "integer", "description": "Seconds before the process is killed (default 120, max 900)."}
TOOLS = {
    "mac_exec": (tool_mac_exec, {
        "description": "Run a shell command on the user's Mac (zsh login shell, as the user, in their home "
                       "directory) and return exit code, stdout and stderr. The Mac is on the user's local "
                       "network and VPNs, so it can reach hosts the cloud session cannot.",
        "inputSchema": {"type": "object", "properties": {
            "command": {"type": "string", "description": "Shell command line."},
            "cwd": {"type": "string", "description": "Working directory (default: home)."},
            "stdin": {"type": "string", "description": "Text passed on standard input."},
            "timeout": TIMEOUT_SCHEMA}, "required": ["command"]}}),
    "ssh_hosts": (tool_ssh_hosts, {
        "description": "List the SSH hosts ssh_exec may reach: Host aliases from the Mac's ~/.ssh/config "
                       "and the bridge's allow patterns. Call this before ssh_exec when the host name is unknown.",
        "inputSchema": {"type": "object", "properties": {}}}),
    "ssh_exec": (tool_ssh_exec, {
        "description": "Run a command on a host over SSH from the user's Mac, with the Mac's own SSH config, "
                       "keys and agent (BatchMode: no password prompts, unknown host keys are refused). "
                       "Use stdin to send file contents, e.g. command='cat > /tmp/x' with stdin set.",
        "inputSchema": {"type": "object", "properties": {
            "host": {"type": "string", "description": "SSH alias from ssh_hosts, or user@alias."},
            "command": {"type": "string", "description": "Remote command line."},
            "stdin": {"type": "string", "description": "Text passed on standard input."},
            "timeout": TIMEOUT_SCHEMA}, "required": ["host", "command"]}}),
    "mac_read_file": (tool_read_file, {
        "description": "Read a file on the Mac. Text is returned as is; binary as 'base64:<data>'.",
        "inputSchema": {"type": "object", "properties": {
            "path": {"type": "string", "description": "Absolute path or ~/path."},
            "encoding": {"type": "string", "enum": ["text", "base64"]}}, "required": ["path"]}}),
    "mac_write_file": (tool_write_file, {
        "description": "Write a file on the Mac (parent directories are created). Refuses to replace an "
                       "existing file unless overwrite is true.",
        "inputSchema": {"type": "object", "properties": {
            "path": {"type": "string"},
            "content": {"type": "string"},
            "encoding": {"type": "string", "enum": ["text", "base64"]},
            "overwrite": {"type": "boolean"}}, "required": ["path", "content"]}}),
    "bridge_status": (tool_status, {
        "description": "Show the Mac bridge's identity and policy (what is allowed, confirmed or denied).",
        "inputSchema": {"type": "object", "properties": {}}}),
}

ANNOTATIONS = {
    "ssh_hosts": {"readOnlyHint": True}, "bridge_status": {"readOnlyHint": True},
    "mac_read_file": {"readOnlyHint": True},
    "mac_exec": {"destructiveHint": True, "openWorldHint": True},
    "ssh_exec": {"destructiveHint": True, "openWorldHint": True},
    "mac_write_file": {"destructiveHint": True},
}


# ---------------------------------------------------------------- MCP

def mcp_dispatch(config, message):
    method, ident = message.get("method"), message.get("id")
    params = message.get("params") or {}
    if ident is None:
        return None  # notification
    if method == "initialize":
        asked = params.get("protocolVersion")
        version = asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
        return {"jsonrpc": "2.0", "id": ident, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "mac-bridge", "version": VERSION},
            "instructions": "Tools that act on the user's own Mac and, through it, on SSH hosts of the user's "
                            "network. Results come back as text. Prefer ssh_hosts before ssh_exec."}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": ident, "result": {}}
    if method == "tools/list":
        tools = []
        for name, (_, spec) in TOOLS.items():
            entry = {"name": name}
            entry.update(spec)
            entry["annotations"] = ANNOTATIONS.get(name, {})
            tools.append(entry)
        return {"jsonrpc": "2.0", "id": ident, "result": {"tools": tools}}
    if method == "tools/call":
        name = params.get("name")
        if name not in TOOLS:
            return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32602, "message": "Unknown tool: %s" % name}}
        args = params.get("arguments") or {}
        try:
            text, failed = TOOLS[name][0](config, args), False
        except Denied as error:
            text, failed = "Denied: %s" % error, True
            audit("denied", tool=name, reason=str(error))
        except (OSError, ValueError) as error:
            text, failed = "Error: %s" % error, True
        return {"jsonrpc": "2.0", "id": ident, "result": {
            "content": [{"type": "text", "text": text}], "isError": failed}}
    return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "Method not found"}}


# ---------------------------------------------------------------- HTTP / OAuth

PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>mac-bridge</title>
<style>body{{font:16px -apple-system,system-ui,sans-serif;max-width:30rem;margin:3rem auto;padding:0 1rem;color:#222}}
@media(prefers-color-scheme:dark){{body{{background:#1c1c1e;color:#eee}}input{{background:#2c2c2e;color:#eee}}}}
input,button{{font:inherit;padding:.5rem;width:100%;box-sizing:border-box;margin:.4rem 0}}
.muted{{opacity:.7;font-size:.9em}} .err{{color:#d33}}</style></head><body>
<h2>Give {client} access to this Mac?</h2>
<p>It will be able to run commands on <b>{host}</b> and, through it, on your SSH hosts,
within the bridge policy.</p><p class="muted">Returns to {redirect}</p>
{error}<form method="post" action="/authorize">
<input type="hidden" name="tx" value="{tx}">
<input type="password" name="passphrase" placeholder="Bridge passphrase" autofocus autocomplete="current-password">
<button type="submit">Allow</button></form></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "mac-bridge/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # -- helpers
    @property
    def config(self):
        return self.server.config

    def base(self):
        return self.config["public_url"].rstrip("/")

    def send(self, status, body=b"", content_type="application/json", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def read_body(self, limit):
        length = int(self.headers.get("Content-Length") or 0)
        if length > limit:
            raise ValueError("body too large")
        return self.rfile.read(length) if length else b""

    def form(self):
        return {k: v[0] for k, v in urllib.parse.parse_qs(self.read_body(65536).decode(), keep_blank_values=True).items()}

    def oauth_error(self, error, description, status=400):
        self.send(status, {"error": error, "error_description": description})

    # -- routing
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        path = url.path.rstrip("/") or "/"
        if path.startswith("/.well-known/oauth-protected-resource"):
            return self.send(200, {"resource": self.base() + "/mcp", "authorization_servers": [self.base()],
                                   "bearer_methods_supported": ["header"], "resource_name": "mac-bridge"})
        if path.startswith("/.well-known/oauth-authorization-server") or \
                path.startswith("/.well-known/openid-configuration"):
            base = self.base()
            return self.send(200, {
                "issuer": base, "authorization_endpoint": base + "/authorize", "token_endpoint": base + "/token",
                "registration_endpoint": base + "/register", "revocation_endpoint": base + "/revoke",
                "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none", "client_secret_post", "client_secret_basic"],
                "scopes_supported": ["mac"]})
        if path == "/authorize":
            return self.authorize_page(dict(urllib.parse.parse_qsl(url.query)))
        if path == "/mcp":
            if not self.bearer():
                return
            return self.send(405, {"error": "use POST"}, headers={"Allow": "POST"})
        if path == "/":
            return self.send(200, "mac-bridge %s\n" % VERSION, "text/plain")
        self.send(404, {"error": "not found"})

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path.rstrip("/")
        try:
            if path == "/mcp":
                return self.mcp()
            if path == "/register":
                return self.register()
            if path == "/authorize":
                return self.authorize_submit()
            if path == "/token":
                return self.token()
            if path == "/revoke":
                return self.revoke()
        except ValueError as error:
            return self.oauth_error("invalid_request", str(error))
        self.send(404, {"error": "not found"})

    def do_DELETE(self):
        if urllib.parse.urlsplit(self.path).path.rstrip("/") == "/mcp" and self.bearer():
            return self.send(405, {"error": "sessions are stateless"})
        self.send(404, {"error": "not found"})

    # -- MCP endpoint
    def bearer(self):
        header = self.headers.get("Authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        if token:
            with _lock:
                entry = load_tokens()["access"].get(digest(token))
            if entry and entry["expires"] > time.time():
                return entry
        meta = self.base() + "/.well-known/oauth-protected-resource"
        self.send(401, {"error": "invalid_token"}, headers={
            "WWW-Authenticate": 'Bearer realm="mac-bridge", resource_metadata="%s"' % meta})
        return None

    def mcp(self):
        if not self.bearer():
            return
        origin = self.headers.get("Origin")
        if origin and urllib.parse.urlsplit(origin).hostname not in \
                set(self.config["allowed_redirect_hosts"]) | {urllib.parse.urlsplit(self.base()).hostname}:
            return self.send(403, {"error": "origin not allowed"})
        try:
            message = json.loads(self.read_body(int(self.config["max_file_bytes"]) * 2 + 65536))
        except ValueError:
            return self.send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        config = load_config()
        if isinstance(message, list):
            replies = [r for r in (mcp_dispatch(config, m) for m in message if isinstance(m, dict)) if r]
            return self.send(200, replies) if replies else self.send(202)
        if not isinstance(message, dict):
            return self.send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid"}})
        reply = mcp_dispatch(config, message)
        if reply is None:
            return self.send(202)
        self.send(200, reply)

    # -- OAuth: dynamic client registration
    def redirect_allowed(self, uri):
        parts = urllib.parse.urlsplit(uri)
        host = parts.hostname or ""
        local = host in ("localhost", "127.0.0.1")
        if parts.scheme != "https" and not (parts.scheme == "http" and local):
            return False
        return host in self.config["allowed_redirect_hosts"]

    def register(self):
        try:
            request = json.loads(self.read_body(65536) or b"{}")
        except ValueError:
            return self.oauth_error("invalid_client_metadata", "JSON body required")
        uris = request.get("redirect_uris")
        if not isinstance(uris, list) or not uris or not all(isinstance(u, str) and self.redirect_allowed(u) for u in uris):
            return self.oauth_error("invalid_redirect_uri", "redirect_uris must point at an allowed host")
        method = request.get("token_endpoint_auth_method", "none")
        if method not in ("none", "client_secret_post", "client_secret_basic"):
            method = "none"
        client = {"client_id": "mb_" + secrets.token_urlsafe(16), "redirect_uris": uris,
                  "client_name": str(request.get("client_name") or "MCP client")[:80],
                  "token_endpoint_auth_method": method, "client_id_issued_at": int(time.time()),
                  "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]}
        stored = dict(client)
        if method != "none":
            client["client_secret"] = secrets.token_urlsafe(32)
            client["client_secret_expires_at"] = 0
            stored["secret_hash"] = digest(client["client_secret"])
        with _lock:
            tokens = load_tokens()
            if len(tokens["clients"]) >= 50:
                oldest = min(tokens["clients"], key=lambda k: tokens["clients"][k]["client_id_issued_at"])
                tokens["clients"].pop(oldest)
            tokens["clients"][client["client_id"]] = stored
            save_tokens(tokens)
        audit("register", client=client["client_name"], redirect_uris=uris)
        self.send(201, client)

    # -- OAuth: authorization with the bridge passphrase
    def authorize_page(self, query, error=""):
        with _lock:
            client = load_tokens()["clients"].get(query.get("client_id", ""))
        redirect = query.get("redirect_uri", "")
        if not client or redirect not in client["redirect_uris"]:
            return self.send(400, "Unknown client or redirect_uri", "text/plain")
        if query.get("response_type") != "code" or query.get("code_challenge_method") != "S256" or \
                not re.match(r"\A[A-Za-z0-9._~-]{43,128}\Z", query.get("code_challenge", "")):
            return self.redirect_error(redirect, query.get("state"), "invalid_request", "PKCE S256 is required")
        tx = secrets.token_urlsafe(24)
        with _lock:
            now = time.time()
            for key in [k for k, v in _pending.items() if v["expires"] < now]:
                _pending.pop(key)
            _pending[tx] = {"query": query, "expires": now + 600}
        page = PAGE.format(client=html.escape(client["client_name"]), host=html.escape(os.uname().nodename),
                           redirect=html.escape(urllib.parse.urlsplit(redirect).hostname or redirect),
                           tx=tx, error='<p class="err">%s</p>' % html.escape(error) if error else "")
        self.send(200, page, "text/html; charset=utf-8", headers={
            "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"})

    def redirect_error(self, redirect, state, error, description):
        params = {"error": error, "error_description": description}
        if state:
            params["state"] = state
        sep = "&" if "?" in redirect else "?"
        self.send(302, headers={"Location": redirect + sep + urllib.parse.urlencode(params)})

    def authorize_submit(self):
        form = self.form()
        with _lock:
            pending = _pending.pop(form.get("tx", ""), None)
        if not pending or pending["expires"] < time.time():
            return self.send(400, "This approval page expired. Start the connection again.", "text/plain")
        query = pending["query"]
        with _lock:
            now = time.time()
            _failures[:] = [t for t in _failures if t > now - 900]
            locked = len(_failures) >= 5
        if locked:
            audit("authorize_locked")
            return self.send(429, "Too many wrong passphrases. Try again in 15 minutes.", "text/plain")
        if not check_passphrase(self.config.get("passphrase"), form.get("passphrase", "")):
            with _lock:
                _failures.append(time.time())
            audit("authorize_failed", client_id=query.get("client_id"))
            time.sleep(1)
            return self.authorize_page(query, "Wrong passphrase.")
        code = secrets.token_urlsafe(32)
        with _lock:
            tokens = load_tokens()
            tokens.setdefault("codes", {})
            tokens["codes"] = {k: v for k, v in tokens["codes"].items() if v["expires"] > time.time()}
            tokens["codes"][digest(code)] = {
                "client_id": query["client_id"], "redirect_uri": query["redirect_uri"],
                "challenge": query["code_challenge"], "resource": query.get("resource"),
                "expires": time.time() + 300}
            save_tokens(tokens)
        audit("authorized", client_id=query["client_id"], redirect_uri=query["redirect_uri"])
        params = {"code": code}
        if query.get("state"):
            params["state"] = query["state"]
        params["iss"] = self.base()
        sep = "&" if "?" in query["redirect_uri"] else "?"
        self.send(302, headers={"Location": query["redirect_uri"] + sep + urllib.parse.urlencode(params)})

    # -- OAuth: token endpoint
    def client_auth(self, form, tokens):
        client_id, secret = form.get("client_id"), form.get("client_secret")
        header = self.headers.get("Authorization", "")
        if header.lower().startswith("basic "):
            try:
                pair = base64.b64decode(header[6:]).decode()
                client_id, secret = [urllib.parse.unquote(p) for p in pair.split(":", 1)]
            except (ValueError, UnicodeDecodeError):
                return None
        client = tokens["clients"].get(client_id or "")
        if not client:
            return None
        if client.get("secret_hash") and not (secret and hmac.compare_digest(digest(secret), client["secret_hash"])):
            return None
        return client

    def issue(self, tokens, client_id, resource):
        access, refresh = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        now = time.time()
        tokens["access"][digest(access)] = {"client_id": client_id, "resource": resource,
                                            "expires": now + int(self.config["access_token_ttl"])}
        tokens["refresh"][digest(refresh)] = {"client_id": client_id, "resource": resource,
                                              "expires": now + int(self.config["refresh_token_ttl"])}
        return {"access_token": access, "token_type": "Bearer", "expires_in": int(self.config["access_token_ttl"]),
                "refresh_token": refresh, "scope": "mac"}

    def token(self):
        form = self.form()
        with _lock:
            tokens = load_tokens()
            client = self.client_auth(form, tokens)
            if not client:
                return self.oauth_error("invalid_client", "unknown client or bad secret", 401)
            grant = form.get("grant_type")
            if grant == "authorization_code":
                entry = tokens.get("codes", {}).pop(digest(form.get("code", "")), None)
                save_tokens(tokens)
                if not entry or entry["expires"] < time.time() or entry["client_id"] != client["client_id"] or \
                        entry["redirect_uri"] != form.get("redirect_uri"):
                    return self.oauth_error("invalid_grant", "code is invalid, used or expired")
                verifier = form.get("code_verifier", "")
                challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
                if not hmac.compare_digest(challenge, entry["challenge"]):
                    return self.oauth_error("invalid_grant", "PKCE verification failed")
                reply = self.issue(tokens, client["client_id"], entry.get("resource"))
            elif grant == "refresh_token":
                entry = tokens["refresh"].pop(digest(form.get("refresh_token", "")), None)
                if not entry or entry["expires"] < time.time() or entry["client_id"] != client["client_id"]:
                    save_tokens(tokens)
                    return self.oauth_error("invalid_grant", "refresh token is invalid or expired")
                reply = self.issue(tokens, client["client_id"], entry.get("resource"))
            else:
                return self.oauth_error("unsupported_grant_type", "authorization_code or refresh_token")
            save_tokens(tokens)
        audit("token", grant=grant, client_id=client["client_id"])
        self.send(200, reply)

    def revoke(self):
        form = self.form()
        value = digest(form.get("token", ""))
        with _lock:
            tokens = load_tokens()
            tokens["access"].pop(value, None)
            tokens["refresh"].pop(value, None)
            save_tokens(tokens)
        self.send(200, {})


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, config):
        self.config = config
        super().__init__((config["listen_host"], int(config["listen_port"])), Handler)


# ---------------------------------------------------------------- CLI

def ask_passphrase():
    while True:
        first = getpass.getpass("Bridge passphrase (12+ characters): ")
        if len(first) < 12:
            print("Too short.")
            continue
        if getpass.getpass("Repeat: ") == first:
            return first
        print("Did not match.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init", help="create the configuration and set the passphrase")
    init.add_argument("--public-url", required=True, help="https URL the proxy publishes, e.g. https://mac.tail1234.ts.net")
    init.add_argument("--port", type=int, default=DEFAULT_CONFIG["listen_port"])
    sub.add_parser("serve", help="run the server")
    sub.add_parser("set-passphrase", help="change the passphrase")
    sub.add_parser("revoke-all", help="drop every client and token; Claude has to connect again")
    sub.add_parser("status", help="show configuration and active tokens")
    args = parser.parse_args()

    if args.command == "init":
        url = args.public_url.rstrip("/")
        if not url.startswith("https://"):
            sys.exit("public URL must be https://")
        config = _read_json(CONFIG_PATH, {})
        config.update({"public_url": url, "listen_port": args.port})
        if not config.get("passphrase") or input("Keep the existing passphrase? [Y/n] ").strip().lower() == "n":
            config["passphrase"] = hash_passphrase(ask_passphrase())
        _write_private(CONFIG_PATH, config)
        print("Configuration: %s\nConnector URL: %s/mcp" % (CONFIG_PATH, url))
    elif args.command == "set-passphrase":
        config = _read_json(CONFIG_PATH, {})
        config["passphrase"] = hash_passphrase(ask_passphrase())
        _write_private(CONFIG_PATH, config)
        print("Passphrase changed. Existing tokens stay valid; run revoke-all to end them.")
    elif args.command == "revoke-all":
        _write_private(TOKENS_PATH, {"clients": {}, "access": {}, "refresh": {}})
        audit("revoke_all")
        print("All clients and tokens removed.")
    elif args.command == "status":
        config, tokens = load_config(), load_tokens()
        now = time.time()
        print("config: %s" % CONFIG_PATH)
        print("connector URL: %s/mcp" % config["public_url"])
        print("listen: %s:%s" % (config["listen_host"], config["listen_port"]))
        print("policy: " + ", ".join("%s=%s" % (k, config[k]) for k in ("local_exec", "ssh_exec", "file_read", "file_write")))
        print("clients: %d, live access tokens: %d, refresh tokens: %d" % (
            len(tokens["clients"]), sum(1 for v in tokens["access"].values() if v["expires"] > now),
            sum(1 for v in tokens["refresh"].values() if v["expires"] > now)))
    elif args.command == "serve":
        config = load_config()
        if not config.get("public_url") or not config.get("passphrase"):
            sys.exit("run `mac_bridge.py init --public-url ...` first")
        if config["listen_host"] not in ("127.0.0.1", "::1", "localhost") and not os.environ.get("MAC_BRIDGE_ALLOW_NONLOCAL"):
            sys.exit("refusing to listen on %s: publish through a proxy instead" % config["listen_host"])
        server = Server(config)
        signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
        sys.stderr.write("mac-bridge %s on %s:%s for %s\n" % (VERSION, config["listen_host"], config["listen_port"],
                                                               config["public_url"]))
        audit("start", version=VERSION)
        server.serve_forever()


if __name__ == "__main__":
    main()
