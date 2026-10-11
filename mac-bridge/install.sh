#!/bin/bash
# Install mac-bridge as a per-user LaunchAgent and publish it over HTTPS.
#
#   ./install.sh                      # Tailscale Funnel, URL detected
#   ./install.sh --url https://mac-bridge.example.com   # your own proxy (cloudflared etc.)
#   ./install.sh --port 8765
#
# Nothing outside these paths is changed:
#   ~/Library/Application Support/mac-bridge/   program, config, tokens, audit log
#   ~/Library/LaunchAgents/dev.mac-bridge.plist
#   ~/Library/Logs/mac-bridge.log
#   one Tailscale Funnel handler (only with the default Funnel mode)
set -euo pipefail

LABEL=dev.mac-bridge
PORT=8765
URL=""
here="$(cd "$(dirname "$0")" && pwd)"
state="$HOME/Library/Application Support/mac-bridge"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
log="$HOME/Library/Logs/mac-bridge.log"

while [ $# -gt 0 ]; do
	case "$1" in
		--url) URL="${2%/}"; shift 2 ;;
		--port) PORT="$2"; shift 2 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

[ "$(uname -s)" = Darwin ] || { echo "macOS only" >&2; exit 1; }

# A real python3: Homebrew first; /usr/bin/python3 only when the Command Line
# Tools are installed (otherwise it is a stub that opens an installer dialog).
python=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
	[ -x "$candidate" ] && { python="$candidate"; break; }
done
if [ -z "$python" ] && xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then
	python=/usr/bin/python3
fi
[ -n "$python" ] || { echo "python3 not found: brew install python, or xcode-select --install" >&2; exit 1; }
"$python" -c 'import sys; sys.exit(sys.version_info < (3, 9))' || { echo "$python is older than 3.9" >&2; exit 1; }

tailscale=""
for candidate in "$(command -v tailscale 2>/dev/null || true)" /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
	[ -n "$candidate" ] && [ -x "$candidate" ] && { tailscale="$candidate"; break; }
done

funnel_port=""
if [ -z "$URL" ]; then
	[ -n "$tailscale" ] || { echo "Tailscale not found. Install it, or pass --url for another HTTPS proxy." >&2; exit 1; }
	status="$("$tailscale" status --json)" || { echo "tailscale is not running or not logged in" >&2; exit 1; }
	dns="$(printf '%s' "$status" | "$python" -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
	[ -n "$dns" ] || { echo "could not read this Mac's Tailscale name" >&2; exit 1; }
	# Keep whatever the Mac already serves: take the first Funnel port that is free.
	used="$("$tailscale" serve status --json 2>/dev/null | "$python" -c '
import json, sys
try:
    data = json.load(sys.stdin) or {}
except ValueError:
    data = {}
ports = set((data.get("TCP") or {}).keys())
for host in (data.get("Web") or {}):
    ports.add(host.rsplit(":", 1)[-1])
print(" ".join(sorted(ports)))')"
	for candidate in 443 8443 10000; do
		case " $used " in *" $candidate "*) continue ;; esac
		funnel_port=$candidate; break
	done
	[ -n "$funnel_port" ] || { echo "Funnel ports 443, 8443 and 10000 are all in use on this Mac" >&2; exit 1; }
	URL="https://$dns"
	[ "$funnel_port" = 443 ] || URL="$URL:$funnel_port"
fi
case "$URL" in https://*) ;; *) echo "URL must be https://" >&2; exit 1 ;; esac

mkdir -p "$state/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod 700 "$state"
install -m 755 "$here/mac_bridge.py" "$state/bin/mac_bridge.py"

"$python" "$state/bin/mac_bridge.py" init --public-url "$URL" --port "$PORT"

# The agent runs in the login session, so it has the user's ssh-agent and
# keychain; PATH covers Homebrew for commands run through zsh -l anyway.
cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$python</string>
		<string>$state/bin/mac_bridge.py</string>
		<string>serve</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardOutPath</key><string>$log</string>
	<key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
EOF
plutil -lint "$plist" >/dev/null

domain="gui/$(id -u)"
launchctl bootout "$domain/$LABEL" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist"
launchctl enable "$domain/$LABEL"

for _ in 1 2 3 4 5 6 7 8 9 10; do
	curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
	sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/" >/dev/null || { echo "server did not start; see $log" >&2; exit 1; }

if [ -n "$funnel_port" ]; then
	echo "Publishing through Tailscale Funnel on port $funnel_port..."
	# First use may print a link to allow Funnel for this Mac in the tailnet policy.
	"$tailscale" funnel --bg --https="$funnel_port" "http://127.0.0.1:$PORT"
fi

cat <<EOF

mac-bridge is running.

  Connector URL:  $URL/mcp
  Config:         $state/config.json
  Audit log:      $state/audit.jsonl
  Server log:     $log

Next, in claude.ai: Settings -> Connectors -> Add custom connector,
name it "mac", URL $URL/mcp, then Connect and enter the passphrase.

Check from outside:  curl -s $URL/.well-known/oauth-protected-resource
EOF
