#!/bin/bash
# Runs the Windows client's tests or build in a Parallels Windows VM on this Mac.
#
#   scripts/windows-vm.sh test     desktop-clients/windows/test.ps1 -Wfp
#   scripts/windows-vm.sh build    desktop-clients/windows/build.ps1, outputs in dist/windows/
#
# The VM (IKEV2_WINDOWS_VM, default "WeExport Build") is reverted to its snapshot
# (IKEV2_WINDOWS_SNAPSHOT, default "build-ready") first and suspended afterwards, so
# nothing of a run stays in it. Sources go to it over the Parallels shared network only,
# behind a random path; the log of the run and the outputs come back the same way.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-test}"
case "$MODE" in test | build) ;; *) echo "usage: $0 test|build" >&2; exit 2 ;; esac
VM="${IKEV2_WINDOWS_VM:-WeExport Build}"
SNAPSHOT="${IKEV2_WINDOWS_SNAPSHOT:-build-ready}"
HOST=$(prlsrvctl net info Shared | awk '/Parallels adapter/{getline; print $3}')
[ -n "$HOST" ] || { echo "Parallels shared network address not found" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'kill "${SERVER:-0}" 2>/dev/null || true; prlctl suspend "$VM" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

snapshot=$(prlctl snapshot-list "$VM" -j | python3 -c "import json,sys; print(next((k for k,v in json.load(sys.stdin).items() if v.get('name')=='$SNAPSHOT'),''))")
[ -n "$snapshot" ] || { echo "Snapshot '$SNAPSHOT' not found in VM '$VM'" >&2; exit 1; }
prlctl snapshot-switch "$VM" --id "$snapshot" >/dev/null
prlctl start "$VM" >/dev/null 2>&1 || true
for _ in $(seq 1 60); do prlctl exec "$VM" cmd /c ver >/dev/null 2>&1 && break; sleep 2; done

{ git ls-files desktop-clients; git ls-files --others --exclude-standard desktop-clients; } | sort -u | zip -q "$WORK/source.zip" -@
# A failed run still brings its log back; none from an earlier run is left to be mistaken for it.
mkdir -p dist/windows
rm -f "dist/windows/windows-$MODE.log"
TOKEN=$(openssl rand -hex 16)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
python3 - "$HOST" "$PORT" "$TOKEN" "$WORK/source.zip" "$PWD/dist/windows" <<'EOF' &
import http.server, os, re, sys
host, port, token, source, outputs = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path != '/' + token + '/source.zip':
            return self.send_error(404)
        data = open(source, 'rb').read()
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_PUT(self):
        match = re.fullmatch('/' + token + r'/upload/([\w.-]+\.(?:exe|msi|zip|log))', self.path)
        if not match:
            return self.send_error(404)
        left = int(self.headers['Content-Length'])
        with open(os.path.join(outputs, match.group(1)), 'wb') as stream:
            while left:
                block = self.rfile.read(min(left, 1 << 20)); stream.write(block); left -= len(block)
        self.send_response(201); self.end_headers()
http.server.ThreadingHTTPServer((host, port), Handler).serve_forever()
EOF
SERVER=$!
disown "$SERVER"
sleep 1
BASE="http://$HOST:$PORT/$TOKEN"
if [ "$MODE" = test ]; then
    RUN="try { & C:\\waypoint\\src\\desktop-clients\\windows\\test.ps1 -Wfp *>&1 | Tee-Object C:\\waypoint\\windows-test.log; \$code = \$LASTEXITCODE; if (-not \$?) { \$code = 1 } } catch { \$_ | Out-File -Append C:\\waypoint\\windows-test.log; \$code = 1 }"
    UPLOAD="Invoke-WebRequest -UseBasicParsing -Method Put -InFile C:\\waypoint\\windows-test.log '$BASE/upload/windows-test.log' | Out-Null"
else
    RUN="try { & C:\\waypoint\\src\\desktop-clients\\windows\\build.ps1 -Output C:\\waypoint\\out *>&1 | Tee-Object C:\\waypoint\\windows-build.log; \$code = \$LASTEXITCODE; if (-not \$?) { \$code = 1 } } catch { \$_ | Out-File -Append C:\\waypoint\\windows-build.log; \$code = 1 }"
    UPLOAD="Invoke-WebRequest -UseBasicParsing -Method Put -InFile C:\\waypoint\\windows-build.log '$BASE/upload/windows-build.log' | Out-Null; Get-ChildItem C:\\waypoint\\out -File | Where-Object { \$_.Extension -in '.exe','.msi','.zip' } | ForEach-Object { Invoke-WebRequest -UseBasicParsing -Method Put -InFile \$_.FullName ('$BASE/upload/' + \$_.Name) | Out-Null }"
fi
# Parallels rejects long -Command arguments; the script goes encoded.
COMMAND="\$ProgressPreference='SilentlyContinue'; New-Item -ItemType Directory -Force C:\\waypoint | Out-Null; Invoke-WebRequest -UseBasicParsing '$BASE/source.zip' -OutFile C:\\waypoint\\source.zip; Expand-Archive -Force C:\\waypoint\\source.zip C:\\waypoint\\src; $RUN; $UPLOAD; exit \$code"
set +e
prlctl exec "$VM" powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$(printf '%s' "$COMMAND" | iconv -f utf-8 -t utf-16le | base64)"
rc=$?
set -e
echo "Windows $MODE finished with $rc; log in dist/windows/windows-$MODE.log"
exit "$rc"
