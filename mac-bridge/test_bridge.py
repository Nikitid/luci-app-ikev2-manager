#!/usr/bin/env python3
"""End-to-end test: discovery, DCR, passphrase authorization, PKCE token,
refresh, MCP calls and policy denials against a live server on loopback."""

import base64
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 18765
BASE = "http://127.0.0.1:%d" % PORT
PUBLIC = "https://bridge.test"
PASS = "correct horse battery staple"
REDIRECT = "https://claude.ai/api/mcp/auth_callback"

state = tempfile.mkdtemp(prefix="mac-bridge-test-")
os.environ["MAC_BRIDGE_DIR"] = state
sys.path.insert(0, HERE)
import mac_bridge  # noqa: E402

mac_bridge._write_private(mac_bridge.CONFIG_PATH, {
    "public_url": PUBLIC, "listen_port": PORT, "passphrase": mac_bridge.hash_passphrase(PASS),
    "file_roots": ["/tmp"], "ssh_hosts": ["testhost"], "access_token_ttl": 2,
    "shell": "/bin/bash"})

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


raw = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)


def call(method, path, body=None, headers=None, form=False, via=opener):
    data = None
    headers = dict(headers or {})
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        resp = via.open(req, timeout=30)
        return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def check(cond, what):
    if not cond:
        print("FAIL:", what)
        sys.exit(1)
    print("ok  ", what)


server = subprocess.Popen([sys.executable, os.path.join(HERE, "mac_bridge.py"), "serve"],
                          stderr=open(os.path.join(state, "server.log"), "w"))
try:
    for _ in range(50):
        try:
            if call("GET", "/")[0] == 200:
                break
        except OSError:
            time.sleep(0.1)

    st, hd, _ = call("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    check(st == 401 and "resource_metadata=\"%s/.well-known/oauth-protected-resource\"" % PUBLIC
          in hd.get("WWW-Authenticate", ""), "unauthenticated MCP gets 401 with resource metadata")

    st, _, body = call("GET", "/.well-known/oauth-protected-resource/mcp")
    meta = json.loads(body)
    check(st == 200 and meta["authorization_servers"] == [PUBLIC], "protected resource metadata")
    st, _, body = call("GET", "/.well-known/oauth-authorization-server")
    asm = json.loads(body)
    check(asm["code_challenge_methods_supported"] == ["S256"] and asm["registration_endpoint"].startswith(PUBLIC),
          "authorization server metadata")

    st, _, body = call("POST", "/register", {"redirect_uris": ["https://evil.example/cb"]})
    check(st == 400, "registration refuses a foreign redirect host")
    st, _, body = call("POST", "/register", {"redirect_uris": [REDIRECT], "client_name": "Claude",
                                             "token_endpoint_auth_method": "none"})
    client = json.loads(body)
    check(st == 201 and client["client_id"].startswith("mb_") and "client_secret" not in client, "public client registered")

    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client["client_id"], "redirect_uri": REDIRECT,
                                "code_challenge": challenge, "code_challenge_method": "S256", "state": "xyz",
                                "resource": PUBLIC + "/mcp", "scope": "mac"})
    st, hd, page = call("GET", "/authorize?" + q)
    check(st == 200 and b"Bridge passphrase" in page and hd.get("X-Frame-Options") == "DENY", "authorization page")
    tx = re.search(rb'name="tx" value="([^"]+)"', page).group(1).decode()

    st, _, page = call("POST", "/authorize", {"tx": tx, "passphrase": "wrong"}, form=True, via=raw)
    check(st == 200 and b"Wrong passphrase" in page, "wrong passphrase is refused")
    tx2 = re.search(rb'name="tx" value="([^"]+)"', page).group(1).decode()
    st, _, _ = call("POST", "/authorize", {"tx": tx, "passphrase": PASS}, form=True, via=raw)
    check(st == 400, "a used approval page cannot be replayed")

    st, hd, _ = call("POST", "/authorize", {"tx": tx2, "passphrase": PASS}, form=True, via=raw)
    loc = urllib.parse.urlsplit(hd.get("Location", ""))
    params = dict(urllib.parse.parse_qsl(loc.query))
    check(st == 302 and loc.netloc == "claude.ai" and params.get("state") == "xyz" and params.get("code"),
          "right passphrase redirects with code and state")

    bad = {"grant_type": "authorization_code", "code": params["code"], "redirect_uri": REDIRECT,
           "client_id": client["client_id"], "code_verifier": "x" * 50}
    st, _, _ = call("POST", "/token", bad, form=True)
    check(st == 400, "wrong PKCE verifier is refused (and burns the code)")

    # new code for the real exchange
    st, _, page = call("GET", "/authorize?" + q)
    tx = re.search(rb'name="tx" value="([^"]+)"', page).group(1).decode()
    st, hd, _ = call("POST", "/authorize", {"tx": tx, "passphrase": PASS}, form=True, via=raw)
    code = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(hd["Location"]).query))["code"]
    good = dict(bad, code=code, code_verifier=verifier)
    st, _, body = call("POST", "/token", good, form=True)
    tok = json.loads(body)
    check(st == 200 and tok["token_type"] == "Bearer" and tok["refresh_token"], "token exchange with PKCE")
    st, _, _ = call("POST", "/token", good, form=True)
    check(st == 400, "authorization code is single-use")

    auth = {"Authorization": "Bearer " + tok["access_token"], "Accept": "application/json, text/event-stream"}

    def rpc(method, params=None, ident=1, headers=auth):
        msg = {"jsonrpc": "2.0", "id": ident, "method": method}
        if params is not None:
            msg["params"] = params
        st, _, body = call("POST", "/mcp", msg, headers=headers)
        return st, json.loads(body) if body else None

    st, r = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                               "clientInfo": {"name": "test", "version": "1"}})
    check(st == 200 and r["result"]["protocolVersion"] == "2025-06-18", "initialize negotiates the protocol")
    st, _, _ = call("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, headers=auth)
    check(st == 202, "notification gets 202")
    st, r = rpc("tools/list")
    names = sorted(t["name"] for t in r["result"]["tools"])
    check(names == ["bridge_status", "mac_exec", "mac_read_file", "mac_write_file", "ssh_exec", "ssh_hosts"], "tools/list")

    def tool(name, args):
        st, r = rpc("tools/call", {"name": name, "arguments": args})
        return r["result"]["isError"], r["result"]["content"][0]["text"]

    err, text = tool("mac_exec", {"command": "echo hello; echo oops >&2; exit 3"})
    check(not err and "exit_code: 3" in text and "hello" in text and "oops" in text, "mac_exec returns code and streams")
    err, text = tool("mac_exec", {"command": "cat", "stdin": "piped"})
    check("piped" in text, "mac_exec passes stdin")
    t0 = time.time()
    err, text = tool("mac_exec", {"command": "sleep 30", "timeout": 1})
    check("TIMED OUT" in text and time.time() - t0 < 10, "mac_exec kills on timeout")

    target = os.path.join(tempfile.mkdtemp(prefix="mb-work-"), "sub", "note.txt")
    err, text = tool("mac_write_file", {"path": target, "content": "привет"})
    check(not err and os.path.exists(target), "write_file creates the file")
    err, text = tool("mac_write_file", {"path": target, "content": "x"})
    check(err and "overwrite" in text, "write_file refuses to replace without overwrite")
    err, text = tool("mac_read_file", {"path": target})
    check(not err and text == "привет", "read_file returns text")
    err, text = tool("mac_read_file", {"path": "/etc/passwd"})
    check(err and "file_roots" in text, "read_file outside roots is denied")
    err, text = tool("mac_read_file", {"path": os.path.join(state, "config.json")})
    check(err and "own state" in text, "the bridge never serves its own state")
    err, text = tool("ssh_exec", {"host": "-oProxyCommand=sh", "command": "id"})
    check(err and "without options" in text, "ssh_exec refuses option injection in host")
    err, text = tool("ssh_exec", {"host": "otherhost", "command": "id"})
    check(err and "not in the bridge" in text, "ssh_exec refuses hosts outside ssh_hosts")

    # policy is re-read on every call
    cfg = json.load(open(os.path.join(state, "config.json")))
    cfg["local_exec"] = "deny"
    mac_bridge._write_private(os.path.join(state, "config.json"), cfg)
    err, text = tool("mac_exec", {"command": "echo hi"})
    check(err and "disabled" in text, "policy change applies without restart")

    time.sleep(2.5)
    st, _ = rpc("ping")
    check(st == 401, "expired access token is refused")
    st, _, body = call("POST", "/token", {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
                                          "client_id": client["client_id"]}, form=True)
    tok2 = json.loads(body)
    check(st == 200 and tok2["access_token"] != tok["access_token"], "refresh issues a new token")
    st, _, _ = call("POST", "/token", {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
                                       "client_id": client["client_id"]}, form=True)
    check(st == 400, "refresh tokens rotate")
    st, r = rpc("ping", headers={"Authorization": "Bearer " + tok2["access_token"]})
    check(st == 200, "new access token works")

    raw_tokens = open(os.path.join(state, "tokens.json")).read()
    check(tok2["access_token"] not in raw_tokens and tok2["refresh_token"] not in raw_tokens, "tokens stored hashed only")
    check(oct(os.stat(os.path.join(state, "tokens.json")).st_mode & 0o777) == "0o600", "token file is 0600")

    for i in range(5):
        st, _, page = call("GET", "/authorize?" + q)
        tx = re.search(rb'name="tx" value="([^"]+)"', page).group(1).decode()
        call("POST", "/authorize", {"tx": tx, "passphrase": "nope"}, form=True, via=raw)
    st, _, page = call("GET", "/authorize?" + q)
    tx = re.search(rb'name="tx" value="([^"]+)"', page).group(1).decode()
    st, _, _ = call("POST", "/authorize", {"tx": tx, "passphrase": PASS}, form=True, via=raw)
    check(st == 429, "lockout after repeated wrong passphrases")
    print("ALL OK")
finally:
    server.terminate()
    server.wait(5)
