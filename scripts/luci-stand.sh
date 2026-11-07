#!/bin/sh

# A LuCI test stand: the package from this tree installed into an OpenWrt
# rootfs container next to the real LuCI, rpcd and uhttpd, with synthetic data.
# Nothing here touches a router.
#
#   scripts/luci-stand.sh up              build the package, start the stand
#   scripts/luci-stand.sh mode NAME       first-run | empty | vpn-only | full | error
#   scripts/luci-stand.sh delay MS        hold each helper call back by MS
#   scripts/luci-stand.sh lang auto|ru    the language LuCI serves the pages in
#   scripts/luci-stand.sh probe [NAME...] ui_probe every page in both themes;
#                                         IKEV2_UI_PROBE is the path of ui_probe.cjs
#   scripts/luci-stand.sh down            remove the container
#
# IKEV2_STAND_NAME and IKEV2_STAND_PORT run a second stand beside the first.
#
# The pages are served on http://127.0.0.1:$IKEV2_STAND_PORT (default 18081)
# through a proxy that signs in, so a probe or a browser opens them directly.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
name="${IKEV2_STAND_NAME:-ikev2-luci-stand}"
port="${IKEV2_STAND_PORT:-18081}"
inner=$((port - 1))
release="${IKEV2_STAND_RELEASE:-25.12.6}"
out="$root/build/luci-stand"
pidfile="$out/proxy.pid"
pages='setup client dns routing remote-clients admin/status/overview'

case "$(uname -m)" in
	x86_64 | amd64) target=x86-64; platform='' ;;
	arm64 | aarch64) target=armsr-armv8; platform='--platform linux/aarch64_generic' ;;
	*) printf 'unsupported host architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

inside() { docker exec "$name" sh /src/scripts/luci-stand/container.sh "$@"; }

stop_proxy() {
	[ ! -f "$pidfile" ] || kill "$(cat "$pidfile")" 2>/dev/null || true
	rm -f "$pidfile"
}

case "${1:-}" in
up)
	command -v docker >/dev/null 2>&1 || { printf '%s\n' 'Docker is required' >&2; exit 1; }
	"$root/scripts/build-ipk.sh" >/dev/null
	docker rm -f "$name" >/dev/null 2>&1 || true
	# shellcheck disable=SC2086
	docker run -d --name "$name" $platform --cap-add NET_ADMIN \
		-p "127.0.0.1:$inner:80" -v "$root:/src:ro" \
		"openwrt/rootfs:$target-$release" sleep infinity >/dev/null
	inside up
	mkdir -p "$out"
	stop_proxy
	nohup node "$root/scripts/luci-stand/proxy.cjs" "$port" "$inner" >"$out/proxy.log" 2>&1 &
	echo $! >"$pidfile"
	sleep 1
	printf 'stand: http://127.0.0.1:%s/cgi-bin/luci/admin/services/ikev2-manager/setup\n' "$port"
	;;
mode) inside mode "${2:?mode}" ;;
delay) inside delay "${2:?milliseconds}" ;;
lang) inside lang "${2:?language}" ;;
probe)
	shift
	# The page probe is a separate tool (ui_probe.cjs); say where it is.
	probe_tool="${IKEV2_UI_PROBE:?set IKEV2_UI_PROBE to the path of ui_probe.cjs}"
	# shellcheck disable=SC2086
	[ "$#" -gt 0 ] || set -- $pages
	status=0
	for page in "$@"; do
		# A bare name is one of this application's pages; admin/... is a LuCI path.
		# LuCI's own status page is timed by LuCI: its widget is checked on its own.
		wait='.ikev2-section, .ikev2-empty, .ikev2-note' timing=''
		case "$page" in admin/*) path="$page" wait='#view > *' timing='--no-timing' ;; *) path="admin/services/ikev2-manager/$page" ;; esac
		# shellcheck disable=SC2086
		node "$probe_tool" \
			"http://127.0.0.1:$port/cgi-bin/luci/$path" \
			--out "$out/${IKEV2_STAND_LABEL:-run}/$(basename "$page")" --wait "$wait" $timing --ignore 'header, #topmenu, #tabmenu, footer' || status=1
	done
	exit "$status"
	;;
down)
	stop_proxy
	docker rm -f "$name" >/dev/null 2>&1 || true
	;;
*)
	sed -n '3,17p' "$0" >&2
	exit 2
	;;
esac
