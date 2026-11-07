#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/etc/swanctl/conf.d" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/root/usr/share/ikev2-manager/ca" \
	"$tmp/bin"
cp "$root"/ikev2-manager-runtime/lib/*.sh "$tmp/root/usr/libexec/ikev2-manager.d/"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		-c) shift 2 ;;
		-q) shift ;;
		*) break ;;
	esac
done
command="${1:-}"
[ "$#" -eq 0 ] || shift
case "$command" in
	get)
		case "${1:-}" in
			ikev2-manager.globals|ikev2-manager.server|ikev2-manager.client|ikev2-manager.dns)
				exit 0
				;;
			ikev2-manager.globals.configured) printf '%s\n' 0 ;;
			ikev2-manager.client.enabled) printf '%s\n' 1 ;;
			ikev2-manager.client.remote_address) printf '%s\n' vpn.example.test ;;
			ikev2-manager.client.remote_id) printf '%s\n' vpn.example.test ;;
			ikev2-manager.client.username) printf '%s\n' tunnel-user ;;
			ikev2-manager.client.dpd) printf '%s\n' 30 ;;
			ikev2-manager.client.mtu) printf '%s\n' 1400 ;;
			ikev2-manager.client.reconnect_cooldown) printf '%s\n' 15 ;;
			ikev2-manager.client.tunnel_dns_provider) printf '%s\n' google ;;
			ikev2-manager.client.tunnel_dns_upstream) printf '%s\n' 'https://dns.google/dns-query https://dns.cloudflare.com/dns-query' ;;
			ikev2-manager.client.tunnel_dns_bootstrap) printf '%s\n' '8.8.8.8:53 8.8.4.4:53 1.1.1.1:53 1.0.0.1:53' ;;
			ikev2-manager.client.custom_config) printf '%s\n' "$TEST_CUSTOM_MODE" ;;
			*) exit 1 ;;
		esac
		;;
	set|add_list|delete)
		printf '%s %s\n' "$command" "$*" >>"$TEST_UCI_LOG"
		;;
	commit)
		printf '%s %s\n' "$command" "$*" >>"$TEST_UCI_LOG"
		if [ "${1:-}" = ikev2-manager ] && [ -f "$TEST_FAIL_COMMIT" ]; then
			count="$(cat "$TEST_COMMIT_COUNT" 2>/dev/null || echo 0)"
			count=$((count + 1))
			printf '%s\n' "$count" >"$TEST_COMMIT_COUNT"
			if [ "$count" -ge 2 ]; then
				printf '%s\n' CORRUPTED >"$TEST_CONFIG_DIR/ikev2-manager"
				exit 1
			fi
		fi
		;;
	revert)
		printf '%s %s\n' "$command" "$*" >>"$TEST_UCI_LOG"
		;;
	show)
		exit 0
		;;
esac
EOF
chmod 755 "$tmp/bin/uci"
cat >"$tmp/bin/system-helper" <<'EOF'
#!/bin/sh
[ "${1:-}" = strongswan-security ] && [ "${2:-}" = client ]
EOF
chmod 755 "$tmp/bin/system-helper"

write_input() {
	remote_address="${1:-vpn.example.test}"
	remote_id="${2:-vpn.example.test}"
	cat >"$tmp/client.in" <<EOF
save
1
$remote_address
$remote_id
tunnel-user
30
1400
tunnel-password
15
google
https://dns.google/dns-query https://dns.cloudflare.com/dns-query
8.8.8.8:53 8.8.4.4:53 1.1.1.1:53 1.0.0.1:53
EOF
}

run_manager() {
	TEST_UCI_LOG="$tmp/uci.log" \
	TEST_FAIL_COMMIT="$tmp/fail-commit" \
	TEST_COMMIT_COUNT="$tmp/commit-count" \
	TEST_CUSTOM_MODE="${TEST_CUSTOM_MODE:-0}" \
	TEST_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_SYSTEM_HELPER="$tmp/bin/system-helper" \
	IKEV2_CLIENT_INPUT="$tmp/client.in" \
	IKEV2_CONFIG_LOCK="$tmp/config.lock" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	IKEV2_ACTION_STATUS="$tmp/latest.status" \
	IKEV2_ACTION_STATUS_DIR="$tmp/actions" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.lock.status" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" "$@"
}

printf '%s\n' ORIGINAL_UCI >"$tmp/root/etc/config/ikev2-manager"
printf '%s\n' ORIGINAL_SECRET >"$tmp/root/etc/ikev2-manager/client.secret"
printf '%s\n' ORIGINAL_PROFILE >"$tmp/root/etc/swanctl/conf.d/20-proxy-out.conf"
printf '%s\n' ORIGINAL_RENDERED_SECRET >"$tmp/root/etc/swanctl/conf.d/90-proxy-out-secret.conf"

write_input
: >"$tmp/uci.log"
run_manager client-input
grep -q 'proxy-out {' "$tmp/root/etc/swanctl/conf.d/20-proxy-out.conf"
grep -q 'id = "tunnel-user"' "$tmp/root/etc/swanctl/conf.d/90-proxy-out-secret.conf"
if grep -q 'tunnel-password' "$tmp/root/etc/ikev2-manager/client.secret"; then
	printf 'client password was stored in plaintext\n' >&2
	exit 1
fi

printf '%s\n' ORIGINAL_UCI >"$tmp/root/etc/config/ikev2-manager"
printf '%s\n' ORIGINAL_SECRET >"$tmp/root/etc/ikev2-manager/client.secret"
printf '%s\n' ORIGINAL_PROFILE >"$tmp/root/etc/swanctl/conf.d/20-proxy-out.conf"
printf '%s\n' ORIGINAL_RENDERED_SECRET >"$tmp/root/etc/swanctl/conf.d/90-proxy-out-secret.conf"
for name in \
	"etc/config/ikev2-manager" \
	"etc/ikev2-manager/client.secret" \
	"etc/swanctl/conf.d/20-proxy-out.conf" \
	"etc/swanctl/conf.d/90-proxy-out-secret.conf"; do
	cp "$tmp/root/$name" "$tmp/${name##*/}.before"
done
write_input
: >"$tmp/uci.log"
if TEST_CUSTOM_MODE=1 run_manager client-input >/dev/null 2>&1; then
	printf 'missing custom client profile unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/ikev2-manager.before" "$tmp/root/etc/config/ikev2-manager"
cmp -s "$tmp/client.secret.before" "$tmp/root/etc/ikev2-manager/client.secret"
cmp -s "$tmp/20-proxy-out.conf.before" "$tmp/root/etc/swanctl/conf.d/20-proxy-out.conf"
cmp -s "$tmp/90-proxy-out-secret.conf.before" "$tmp/root/etc/swanctl/conf.d/90-proxy-out-secret.conf"

write_input
: >"$tmp/fail-commit"
: >"$tmp/commit-count"
: >"$tmp/uci.log"
if run_manager client-input >/dev/null 2>&1; then
	printf 'failed client UCI commit unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/ikev2-manager.before" "$tmp/root/etc/config/ikev2-manager"
cmp -s "$tmp/client.secret.before" "$tmp/root/etc/ikev2-manager/client.secret"
cmp -s "$tmp/20-proxy-out.conf.before" "$tmp/root/etc/swanctl/conf.d/20-proxy-out.conf"
cmp -s "$tmp/90-proxy-out-secret.conf.before" "$tmp/root/etc/swanctl/conf.d/90-proxy-out-secret.conf"
rm -f "$tmp/fail-commit" "$tmp/commit-count"

for invalid_host in bad_host 999.999.999.999 host..example.test -vpn.example.test; do
	write_input "$invalid_host" vpn.example.test
	: >"$tmp/uci.log"
	if run_manager client-input >/dev/null 2>&1; then
		printf 'invalid client host unexpectedly succeeded: %s\n' "$invalid_host" >&2
		exit 1
	fi
	if grep -Eq '^(set|add_list|delete) ikev2-manager\.client' "$tmp/uci.log"; then
		printf 'invalid client host mutated UCI: %s\n' "$invalid_host" >&2
		exit 1
	fi
done

TEST_CUSTOM_MODE=0
write_input 2001:db8::1 2001:db8::1
: >"$tmp/uci.log"
run_manager client-input
grep -Fq 'set ikev2-manager.client.remote_address=2001:db8::1' "$tmp/uci.log"

cat >"$tmp/profile.in" <<'EOF'
connections {
	proxy-out {
		version = 2
	}
}
EOF
: >"$tmp/uci.log"
run_manager _action-run profile-test advanced-set outbound "$tmp/profile.in"
[ ! -e "$tmp/profile.in" ]
cmp -s "$tmp/root/etc/ikev2-manager/outbound.custom.conf" \
	"$tmp/root/etc/swanctl/conf.d/20-proxy-out.conf"
grep -q '^state=ok$' "$tmp/actions/profile-test.status"
grep -Fq 'set ikev2-manager.client.custom_config=1' "$tmp/uci.log"

cat >"$tmp/profile.in" <<'EOF'
connections {
	wrong-name {
		version = 2
	}
}
EOF
run_manager _action-run profile-invalid advanced-set outbound "$tmp/profile.in"
[ ! -e "$tmp/profile.in" ]
grep -q '^state=error$' "$tmp/actions/profile-invalid.status"

client_state="$(run_manager client-get)"
printf '%s\n' "$client_state" | grep -Fxq 'interface_present=0'
printf '%s\n' "$client_state" | grep -Fxq 'interface_bytes_in=0'
printf '%s\n' "$client_state" | grep -Fxq 'interface_bytes_out=0'

mkdir -p "$tmp/root/sys/class/net/ipsec-out/statistics"
printf '%s\n' 123456 >"$tmp/root/sys/class/net/ipsec-out/statistics/rx_bytes"
printf '%s\n' 654321 >"$tmp/root/sys/class/net/ipsec-out/statistics/tx_bytes"
client_state="$(run_manager client-get)"
printf '%s\n' "$client_state" | grep -Fxq 'interface_present=1'
printf '%s\n' "$client_state" | grep -Fxq 'interface_bytes_in=123456'
printf '%s\n' "$client_state" | grep -Fxq 'interface_bytes_out=654321'

printf 'client transaction tests OK\n'
