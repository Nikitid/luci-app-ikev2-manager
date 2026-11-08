#!/bin/bash
# Runs the Windows client's tests or build in a Parallels Windows VM on this Mac.
#
#   scripts/windows-vm.sh test     desktop-clients/windows/test.ps1 -Wfp, or with the switches in
#                                  IKEV2_WINDOWS_TEST_FLAGS (for example "-Wfp -Profiles -Runtime win-x64")
#   scripts/windows-vm.sh build    desktop-clients/windows/build.ps1, outputs in dist/windows/
#   scripts/windows-vm.sh install  desktop-clients/windows/install-check.ps1 with the outputs of
#                                  build and the setup of release IKEV2_WINDOWS_EARLIER (default v2.2.8)
#   scripts/windows-vm.sh live     desktop-clients/windows/live-check.ps1: this build installed,
#                                  registered with the link in the file IKEV2_WINDOWS_INVITATION
#                                  against a real router, connected and used; see the script
#   scripts/windows-vm.sh run SCRIPT.ps1 [--user]
#                                  a PowerShell script of the repository, as an administrator or, with
#                                  --user, as the user signed in to the VM; log in dist/windows/windows-run.log
#
# The VM (IKEV2_WINDOWS_VM, default "WeExport Build") is reverted to its snapshot
# (IKEV2_WINDOWS_SNAPSHOT, default "build-ready") first and suspended afterwards, so
# nothing of a run stays in it. Sources go to it over the Parallels shared network only,
# behind a random path; the log of the run and the outputs come back the same way. The
# .NET SDK is the one the snapshot keeps in C:\build\dotnet.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-test}"
case "$MODE" in test | build | install | live | run) ;; *) echo "usage: $0 test|build|install|live|run SCRIPT.ps1 [--user]" >&2; exit 2 ;; esac
if [ "$MODE" = live ]; then
    [ -s "${IKEV2_WINDOWS_INVITATION:-}" ] || { echo "IKEV2_WINDOWS_INVITATION must name a file with the link" >&2; exit 2; }
fi
SCRIPT="${2:-}"
AS=()
if [ "$MODE" = run ]; then
    case "$SCRIPT" in *.ps1) ;; *) echo "usage: $0 run SCRIPT.ps1 [--user]" >&2; exit 2 ;; esac
    git ls-files --error-unmatch "$SCRIPT" >/dev/null 2>&1 || [ -f "$SCRIPT" ] || { echo "$SCRIPT not found" >&2; exit 2; }
    [ "${3:-}" != --user ] || AS=(--current-user)
fi
VM="${IKEV2_WINDOWS_VM:-WeExport Build}"
SNAPSHOT="${IKEV2_WINDOWS_SNAPSHOT:-build-ready}"
HOST=$(prlsrvctl net info Shared | awk '/Parallels adapter/{getline; print $3}')
[ -n "$HOST" ] || { echo "Parallels shared network address not found" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'kill "${SERVER:-0}" 2>/dev/null || true; prlctl suspend "$VM" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# The VM is shared with WeExport's build, which reverts it as well and
# suspends it when it is done: a run of either under the other breaks off.
# Wait until no other run uses it, from its revert to its suspend.
busy() {
    pgrep -f "prlctl exec $VM" >/dev/null || pgrep -f "scripts/build-windows.sh" >/dev/null
}
for _ in $(seq 1 180); do
    busy || break
    [ -n "${waited:-}" ] || { echo "Waiting for another run in VM '$VM' to finish" >&2; waited=1; }
    sleep 10
done
busy && { echo "VM '$VM' is still in use" >&2; exit 1; }
snapshot=$(prlctl snapshot-list "$VM" -j | python3 -c "import json,sys; print(next((k for k,v in json.load(sys.stdin).items() if v.get('name')=='$SNAPSHOT'),''))")
[ -n "$snapshot" ] || { echo "Snapshot '$SNAPSHOT' not found in VM '$VM'" >&2; exit 1; }
prlctl snapshot-switch "$VM" --id "$snapshot" >/dev/null
prlctl start "$VM" >/dev/null 2>&1 || true
# A restored VM answers simple commands before it can open a PowerShell session.
for _ in $(seq 1 120); do prlctl exec "$VM" ${AS[@]+"${AS[@]}"} powershell -NoProfile -Command exit >/dev/null 2>&1 && break; sleep 3; done

{ git ls-files desktop-clients windows-profile-installer; git ls-files --others --exclude-standard desktop-clients windows-profile-installer; } |
    sort -u | zip -q "$WORK/source.zip" -@
mkdir -p "$WORK/files/earlier"
if [ "$MODE" = install ] || [ "$MODE" = live ]; then
    for file in dist/windows/WaypointSetup.exe dist/windows/Waypoint-*-x64.msi dist/windows/Waypoint-*-arm64.msi; do
        [ -f "$file" ] || { echo "Build first: $file is missing" >&2; exit 1; }
        cp "$file" "$WORK/files/"
    done
    if [ "$MODE" = install ]; then
        gh release download "${IKEV2_WINDOWS_EARLIER:-v2.2.8}" --pattern WaypointSetup.exe --dir "$WORK/files/earlier"
    else
        cp "$IKEV2_WINDOWS_INVITATION" "$WORK/files/invitation.txt"
    fi
    (cd "$WORK/files" && find . -type f | sed 's|^\./||' > index.txt)
fi
# A failed run still brings its log back; none from an earlier run is left to be mistaken for it.
mkdir -p dist/windows
rm -f "dist/windows/windows-$MODE.log"
TOKEN=$(openssl rand -hex 16)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
python3 - "$HOST" "$PORT" "$TOKEN" "$WORK/source.zip" "$PWD/dist/windows" "$WORK/files" <<'EOF' &
import http.server, os, re, sys
host, port, token, source, outputs, files = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        served = re.fullmatch('/' + token + r'/files/((?:earlier/)?[\w.-]+\.(?:exe|msi|txt))', self.path)
        if self.path == '/' + token + '/source.zip':
            data = open(source, 'rb').read()
        elif served and os.path.isfile(os.path.join(files, served.group(1))):
            data = open(os.path.join(files, served.group(1)), 'rb').read()
        else:
            return self.send_error(404)
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
    FLAGS="${IKEV2_WINDOWS_TEST_FLAGS:--Wfp}"
    case "$FLAGS" in *[!A-Za-z0-9\ -]*) echo "IKEV2_WINDOWS_TEST_FLAGS: switches and values only" >&2; exit 2 ;; esac
    RUN="try { & C:\\waypoint\\src\\desktop-clients\\windows\\test.ps1 $FLAGS *>&1 | Tee-Object C:\\waypoint\\windows-test.log; \$code = \$LASTEXITCODE; if (-not \$?) { \$code = 1 } } catch { \$_ | Out-File -Append C:\\waypoint\\windows-test.log; \$code = 1 }"
    UPLOAD="Invoke-WebRequest -UseBasicParsing -Method Put -InFile C:\\waypoint\\windows-test.log '$BASE/upload/windows-test.log' | Out-Null"
elif [ "$MODE" = install ]; then
    # Long command lines are cut short by Parallels: the check fetches its own files.
    RUN="try { & C:\\waypoint\\src\\desktop-clients\\windows\\install-check.ps1 -Base '$BASE/files' -Files C:\\waypoint\\files *>&1 | Tee-Object C:\\waypoint\\windows-install.log; \$code = \$LASTEXITCODE; if (-not \$?) { \$code = 1 } } catch { \$_ | Out-File -Append C:\\waypoint\\windows-install.log; \$code = 1 }"
    UPLOAD="Invoke-WebRequest -UseBasicParsing -Method Put -InFile C:\\waypoint\\windows-install.log '$BASE/upload/windows-install.log' | Out-Null"
elif [ "$MODE" = live ]; then
    RUN="try { & C:\\waypoint\\src\\desktop-clients\\windows\\live-check.ps1 -Base '$BASE/files' -Files C:\\waypoint\\files *>&1 | Tee-Object C:\\waypoint\\windows-live.log; \$code = \$LASTEXITCODE; if (-not \$?) { \$code = 1 } } catch { \$_ | Out-File -Append C:\\waypoint\\windows-live.log; \$code = 1 }"
    UPLOAD="Invoke-WebRequest -UseBasicParsing -Method Put -InFile C:\\waypoint\\windows-live.log '$BASE/upload/windows-live.log' | Out-Null"
elif [ "$MODE" = run ]; then
    RUN="try { & C:\\waypoint\\src\\$(printf '%s' "$SCRIPT" | sed 's|/|\\|g') *>&1 | Tee-Object C:\\waypoint\\windows-run.log; \$code = \$LASTEXITCODE; if (-not \$?) { \$code = 1 } } catch { \$_ | Out-File -Append C:\\waypoint\\windows-run.log; \$code = 1 }"
    UPLOAD="Invoke-WebRequest -UseBasicParsing -Method Put -InFile C:\\waypoint\\windows-run.log '$BASE/upload/windows-run.log' | Out-Null"
else
    RUN="try { & C:\\waypoint\\src\\desktop-clients\\windows\\build.ps1 -Output C:\\waypoint\\out *>&1 | Tee-Object C:\\waypoint\\windows-build.log; \$code = \$LASTEXITCODE; if (-not \$?) { \$code = 1 } } catch { \$_ | Out-File -Append C:\\waypoint\\windows-build.log; \$code = 1 }"
    UPLOAD="Invoke-WebRequest -UseBasicParsing -Method Put -InFile C:\\waypoint\\windows-build.log '$BASE/upload/windows-build.log' | Out-Null; Get-ChildItem C:\\waypoint\\out -File | Where-Object { \$_.Extension -in '.exe','.msi','.zip' } | ForEach-Object { Invoke-WebRequest -UseBasicParsing -Method Put -InFile \$_.FullName ('$BASE/upload/' + \$_.Name) | Out-Null }"
fi
# Parallels rejects long -Command arguments; the script goes encoded.
COMMAND="\$ProgressPreference='SilentlyContinue'; \$env:WAYPOINT_DOTNET='C:\\build\\dotnet\\dotnet.exe'; New-Item -ItemType Directory -Force C:\\waypoint | Out-Null; New-Item -ItemType File -Force C:\\waypoint\\windows-$MODE.log | Out-Null; Invoke-WebRequest -UseBasicParsing '$BASE/source.zip' -OutFile C:\\waypoint\\source.zip; Remove-Item -Recurse -Force C:\\waypoint\\src -ErrorAction SilentlyContinue; Expand-Archive -Force C:\\waypoint\\source.zip C:\\waypoint\\src; $RUN; $UPLOAD; exit \$code"
set +e
prlctl exec "$VM" ${AS[@]+"${AS[@]}"} powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$(printf '%s' "$COMMAND" | iconv -f utf-8 -t utf-16le | base64)"
rc=$?
set -e
echo "Windows $MODE finished with $rc; log in dist/windows/windows-$MODE.log"
exit "$rc"
