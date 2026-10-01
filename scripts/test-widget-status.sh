#!/bin/sh

set -eu

repo="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/etc/init.d" \
	"$tmp/root/sys/class/net/ipsec-out/statistics" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/root/var/run" \
	"$tmp/bin"
cp "$repo"/ikev2-manager-runtime/lib/*.sh "$tmp/root/usr/libexec/ikev2-manager.d/"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
while [ "${1:-}" = -q ] || [ "${1:-}" = -c ]; do
	case "$1" in -c) shift ;; esac
	shift
done
command="${1:-}"
[ "$#" -eq 0 ] || shift
key="${1:-}"
case "$command:$key" in
	'show:pbr') echo 'pbr.legacy_exclude=policy' ;;
	'show:ikev2-manager') ;;
	'get:pbr.legacy_exclude.name') echo 'VPN Exclude: 192.168.1.90' ;;
	'get:pbr.legacy_exclude.enabled') echo 1 ;;
	'get:pbr.legacy_exclude.src_addr') echo '192.168.1.90' ;;
	'get:ikev2-manager.globals.device_schema') exit 1 ;;
	'get:ikev2-manager.globals.configured') echo 1 ;;
	'get:ikev2-manager.client.enabled') echo 1 ;;
	'get:ikev2-manager.server.enabled') echo 1 ;;
	'get:ikev2-manager.domains.engine') echo fakeip ;;
	*) exit 0 ;;
esac
EOF
cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in 192.168.1.90/32) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$tmp/bin/swanctl" <<'EOF'
#!/bin/sh
case "$1" in
	--list-conns) echo 'ikev2-in: IKEv2' ;;
	--list-pools) echo 'router_pool4' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
[ "$*" = '-4 route show table 1601' ] &&
	echo 'unreachable default metric 32767'
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list chain inet ikev2_device_policy dns_prerouting')
		echo 'counter packets 1 bytes 64 redirect to :53 comment "ikev2-device:dns-enforce"'
		;;
	'list chain inet ikev2_device_policy dot_forward')
		echo 'counter packets 1 bytes 64 reject comment "ikev2-device:dot-block"'
		;;
	'list ruleset')
		case "${TEST_MTPROTO_FIREWALL:-accept}" in
			accept) echo 'tcp dport 1443 counter packets 1 bytes 64 accept' ;;
			dnat) echo 'tcp dport 1443 counter packets 1 bytes 64 dnat ip to 192.0.2.2:1443' ;;
			missing) echo 'tcp dport 443 counter packets 1 bytes 64 accept' ;;
		esac
		;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/lsmod" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/root/usr/libexec/ikev2-routing" <<'EOF'
#!/bin/sh
[ "$1" = check ]
EOF
cat >"$tmp/root/usr/libexec/ikev2-domain-router" <<'EOF'
#!/bin/sh
[ "$1" = status ] || exit 1
cat <<'STATUS'
service=running
healthy=yes
state=active
STATUS
EOF
chmod 755 \
	"$tmp/bin/uci" \
	"$tmp/bin/ipcalc.sh" \
	"$tmp/bin/swanctl" \
	"$tmp/bin/ip" \
	"$tmp/bin/nft" \
	"$tmp/bin/lsmod" \
	"$tmp/root/usr/libexec/ikev2-routing" \
	"$tmp/root/usr/libexec/ikev2-domain-router"

cat >"$tmp/root/var/run/ikev2-health.status" <<'EOF'
state=up failures=0
EOF
printf '%s\n' 123456 >"$tmp/root/sys/class/net/ipsec-out/statistics/rx_bytes"
printf '%s\n' 654321 >"$tmp/root/sys/class/net/ipsec-out/statistics/tx_bytes"
cat >"$tmp/root/etc/pbr-ikev2-domains.txt" <<'EOF'
# generated
example.com
example.net
EOF
cat >"$tmp/root/etc/pbr-ikev2-addresses.manual.txt" <<'EOF'
203.0.113.0/24
EOF
cat >"$tmp/root/etc/pbr-ikev2-community-selected.txt" <<'EOF'
discord
telegram
EOF

if ! PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$repo/luci-ikev2-manager/ikev2-manager.sh" widget-status \
		>"$tmp/status" 2>"$tmp/error"
then
	cat "$tmp/error" >&2
	exit 1
fi

for expected in \
	'health=up' \
	'configured=1' \
	'routing=running' \
	'client_enabled=1' \
	'server_enabled=1' \
	'interface_present=1' \
	'interface_bytes_in=123456' \
	'interface_bytes_out=654321' \
	'inbound_conn_loaded=1' \
	'inbound_pool_loaded=1' \
	'pbr_domains=2' \
	'manual_addresses=1' \
	'community_services=2' \
	'device_excluded=1' \
	'device_dns_passthrough=0' \
	'device_dpi_passthrough=0' \
	'device_excluded_packets=0' \
	'device_excluded_bytes=0' \
	'killswitch=active' \
	'domain_engine=fakeip' \
	'domain_service=running' \
	'domain_healthy=yes' \
	'domain_state=active'
do
	grep -qx "$expected" "$tmp/status" || {
		printf 'missing widget status field: %s\n' "$expected" >&2
		cat "$tmp/status" >&2
		exit 1
	}
done

for firewall_mode in accept dnat; do
	TEST_MTPROTO_FIREWALL="$firewall_mode" \
	PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$repo/luci-ikev2-manager/ikev2-manager.sh" overview \
		>"$tmp/overview-$firewall_mode"
	grep -qx 'mtproto_firewall=active' "$tmp/overview-$firewall_mode" || {
		printf 'MTProto %s firewall rule was not detected\n' "$firewall_mode" >&2
		exit 1
	}
	grep -qx 'dns_hijack=active' "$tmp/overview-$firewall_mode"
	grep -qx 'dot_block=active' "$tmp/overview-$firewall_mode"
done

TEST_MTPROTO_FIREWALL=missing \
PATH="$tmp/bin:$PATH" \
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$repo/luci-ikev2-manager/ikev2-manager.sh" overview \
	>"$tmp/overview-missing"
grep -qx 'mtproto_firewall=missing' "$tmp/overview-missing" || {
	printf 'missing MTProto firewall rule was reported active\n' >&2
	exit 1
}

grep -Fq '"/usr/libexec/ikev2-manager widget-status": [ "exec" ]' \
	"$repo/luci-ikev2-manager/acl.json"

# The Overview include polls frequently. A cached snapshot must avoid rerunning
# the heavier UCI/PBR/domain status collection while still returning a complete
# response. Live SAs and traffic are fetched separately by swanmon.
rm -f "$tmp/widget.cache"
for pass in 1 2; do
	PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	IKEV2_WIDGET_STATUS_CACHE_TEST=1 \
	IKEV2_WIDGET_STATUS_CACHE="$tmp/widget.cache" \
	IKEV2_WIDGET_STATUS_TTL=15 \
		sh "$repo/luci-ikev2-manager/ikev2-manager.sh" widget-status \
		>"$tmp/cache-$pass"
	[ "$pass" != 1 ] || printf '%s\n' 999999 \
		>"$tmp/root/sys/class/net/ipsec-out/statistics/rx_bytes"
done
cmp -s "$tmp/cache-1" "$tmp/cache-2" || {
	printf '%s\n' 'widget snapshot cache did not reuse the first response' >&2
	exit 1
}
grep -qx 'interface_bytes_in=123456' "$tmp/cache-2"

# Past its lifetime the snapshot is still served, and replaced in the
# background; a poll does not wait for the live collection. Past the stale
# limit it is collected while the poll waits.
cat >"$tmp/bin/start-stop-daemon" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_SSD_LOG"
EOF
chmod 755 "$tmp/bin/start-stop-daemon"
age_cache() {
	sed "s/^cached_at=.*/cached_at=$(( $(date +%s) - $1 ))/" "$tmp/widget.cache" >"$tmp/widget.cache.aged"
	mv "$tmp/widget.cache.aged" "$tmp/widget.cache"
}
widget_poll() {
	PATH="$tmp/bin:$PATH" \
	TEST_SSD_LOG="$tmp/ssd.log" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	IKEV2_WIDGET_STATUS_CACHE_TEST=1 \
	IKEV2_WIDGET_STATUS_CACHE="$tmp/widget.cache" \
	IKEV2_WIDGET_STATUS_TTL=15 \
		sh "$repo/luci-ikev2-manager/ikev2-manager.sh" widget-status
}
: >"$tmp/ssd.log"
age_cache 60
widget_poll >"$tmp/cache-stale"
grep -qx 'interface_bytes_in=123456' "$tmp/cache-stale" || {
	printf '%s\n' 'an expired widget snapshot was recollected while the poll waited' >&2
	exit 1
}
grep -q '_widget-status-refresh' "$tmp/ssd.log" || {
	printf '%s\n' 'an expired widget snapshot was not refreshed in the background' >&2
	exit 1
}
age_cache 1000
widget_poll >"$tmp/cache-old"
grep -qx 'interface_bytes_in=999999' "$tmp/cache-old" || {
	printf '%s\n' 'a snapshot past the stale limit was served instead of recollected' >&2
	exit 1
}

printf '%s\n' 'status widget runtime tests OK'
