#!/usr/bin/env python3
"""Exercise real curl responses, retries and DNS failure classification offline."""
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory() as folder:
    work = Path(folder)
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
        "-keyout", str(work / "key"), "-out", str(work / "cert"),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    class Handler(http.server.BaseHTTPRequestHandler):
        calls = 0
        mode = "retry"
        def log_message(self, *args):
            pass
        def do_GET(self):
            type(self).calls += 1
            if self.mode == "retry" and self.calls == 1:
                self.send_error(503)
                return
            if self.mode == "down":
                self.send_error(503)
                return
            body = b"ip=203.0.113.9\nloc=NL\n"
            if self.mode == "html":
                body = b"<html>unrelated success</html>"
            if self.mode == "invalid":
                body = b"ip=999.1.1.1\nloc=NL\n"
            if self.path.startswith("/dns-query"):
                body = b"not a DNS packet"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(work / "cert", work / "key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    host = f"127.0.0.1:{server.server_port}"
    env = {**os.environ, "CURL_CA_BUNDLE": str(work / "cert")}
    def run(command, *args):
        return subprocess.run([
            "sh", "-c", '. "$1"; shift; ' + command, "probe",
            str(ROOT / "scripts/kuma-probes.sh"), *args,
        ], env=env, capture_output=True, text=True, timeout=25)
    try:
        for mode, expected, calls in [
            ("retry", 0, 2), ("down", 1, 2), ("html", 1, 2), ("invalid", 1, 2),
        ]:
            Handler.mode, Handler.calls = mode, 0
            result = run('trace "$1"', host)
            assert result.returncode == expected, (mode, result)
            assert Handler.calls == calls, (mode, Handler.calls)
            assert result.stdout.strip() == ("203.0.113.9 NL" if expected == 0 else "")
        Handler.mode = "healthy"
        interface = "lo0" if os.uname().sysname == "Darwin" else "lo"
        result = run('trace_failure "$1" "$2" "$3"', "unresolvable.example.test",
                     f"https://{host}/dns-query", interface)
        assert "DNS через туннель" in result.stdout, result
        assert "маршрут этим сбоем не проверен" in result.stdout, result
    finally:
        server.shutdown()
print("Kuma probe tests OK")
