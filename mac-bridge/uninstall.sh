#!/bin/bash
# Remove the mac-bridge LaunchAgent and its Funnel handler.
#   ./uninstall.sh           keep config, tokens and audit log
#   ./uninstall.sh --purge   remove them too
set -euo pipefail

LABEL=dev.mac-bridge
state="$HOME/Library/Application Support/mac-bridge"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$plist"

tailscale=""
for candidate in "$(command -v tailscale 2>/dev/null || true)" /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
	[ -n "$candidate" ] && [ -x "$candidate" ] && { tailscale="$candidate"; break; }
done
url="$(/usr/bin/plutil -extract public_url raw "$state/config.json" 2>/dev/null || true)"
if [ -n "$tailscale" ] && [ -n "$url" ]; then
	case "$url" in
		*.ts.net:8443) port=8443 ;;
		*.ts.net:10000) port=10000 ;;
		*.ts.net) port=443 ;;
		*) port="" ;;
	esac
	# Only the handler this bridge added; other serve/funnel config stays.
	[ -z "$port" ] || "$tailscale" funnel --https="$port" off 2>/dev/null || true
fi

if [ "${1:-}" = --purge ]; then
	rm -rf "$state"
	rm -f "$HOME/Library/Logs/mac-bridge.log"
fi
echo "mac-bridge removed${1:+ ($1)}."
