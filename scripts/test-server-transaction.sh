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
		if [ "${TEST_UPGRADE_PROFILE:-0}" = 1 ]; then
			case "${1:-}" in
				ikev2-manager.globals.configured|ikev2-manager.server.enabled)
					printf '%s\n' 1 ;;
				ikev2-manager.server.custom_config) printf '%s\n' 0 ;;
				ikev2-manager.server.identity) printf '%s\n' vpn.example ;;
				ikev2-manager.server.pool4) printf '%s\n' 10.20.30.10-10.20.30.100 ;;
				ikev2-manager.server.dns4) printf '%s\n' 10.20.30.1 ;;
				ikev2-manager.server.dpd) printf '%s\n' 30 ;;
				ikev2-manager.server.ike_rekey) printf '%s\n' 14400 ;;
				ikev2-manager.server.child_rekey) printf '%s\n' 3600 ;;
				ikev2-manager.server.mobike|ikev2-manager.server.fragmentation)
					printf '%s\n' 1 ;;
				ikev2-manager.server.local_ts) printf '%s\n' 0.0.0.0/0 ;;
				*) exit 1 ;;
			esac
			exit 0
		fi
		case "${1:-}" in
			ikev2-manager.server.enabled|ikev2-manager.globals.configured)
				printf '%s\n' 0
				;;
			ikev2-manager.server.custom_config)
				printf '%s\n' "$TEST_CUSTOM_MODE"
				;;
			ikev2-manager.*)
				exit 0
				;;
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
			# The first commit is the server's own: reading the configuration
			# commits nothing while no default is missing.
			if [ "$count" -ge 1 ]; then
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

write_input() {
	inbound_zone="${1:-ikev2in}"
	outbound_zone="${2:-ikev2out}"
	enabled="${3:-0}"
	identity="${4:-}"
	cat >"$tmp/server.in" <<EOF
$enabled
$identity
10.20.30.10-10.20.30.100
10.20.30.1/24
10.20.30.1
/etc/ssl/acme


30
14400
3600
1400
1
1
0.0.0.0/0
1
1
0

lan
$inbound_zone
$outbound_zone
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
	IKEV2_SERVER_INPUT="$tmp/server.in" \
	IKEV2_CONFIG_LOCK="$tmp/config.lock" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" server-input
}

printf '%s\n' ORIGINAL_UCI >"$tmp/root/etc/config/ikev2-manager"
printf '%s\n' ORIGINAL_PROFILE >"$tmp/root/etc/swanctl/conf.d/30-inbound.conf"
write_input
: >"$tmp/uci.log"
run_manager
grep -q 'Inbound server is disabled' "$tmp/root/etc/swanctl/conf.d/30-inbound.conf"
grep -Fq 'set ikev2-manager.server.allow_internet=1' "$tmp/uci.log"
grep -Fq 'add_list ikev2-manager.server.lan_zone=lan' "$tmp/uci.log"

printf '%s\n' ORIGINAL_UCI >"$tmp/root/etc/config/ikev2-manager"
printf '%s\n' ORIGINAL_PROFILE >"$tmp/root/etc/swanctl/conf.d/30-inbound.conf"
cp "$tmp/root/etc/config/ikev2-manager" "$tmp/uci.before"
cp "$tmp/root/etc/swanctl/conf.d/30-inbound.conf" "$tmp/profile.before"
write_input ikev2in ikev2out 1 vpn.example
: >"$tmp/uci.log"
if TEST_CUSTOM_MODE=1 run_manager >/dev/null 2>&1; then
	printf 'missing custom server profile unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/uci.before" "$tmp/root/etc/config/ikev2-manager"
cmp -s "$tmp/profile.before" "$tmp/root/etc/swanctl/conf.d/30-inbound.conf"

write_input
: >"$tmp/fail-commit"
: >"$tmp/commit-count"
: >"$tmp/uci.log"
if run_manager >/dev/null 2>&1; then
	printf 'failed server UCI commit unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/uci.before" "$tmp/root/etc/config/ikev2-manager"
cmp -s "$tmp/profile.before" "$tmp/root/etc/swanctl/conf.d/30-inbound.conf"
rm -f "$tmp/fail-commit" "$tmp/commit-count"

write_input shared shared
: >"$tmp/uci.log"
if run_manager >/dev/null 2>&1; then
	printf 'identical inbound/outbound firewall zones unexpectedly succeeded\n' >&2
	exit 1
fi
if grep -Eq '^(set|add_list|delete) ikev2-manager\.server' "$tmp/uci.log"; then
	printf 'invalid server input mutated UCI before validation\n' >&2
	exit 1
fi

# A package upgrade must regenerate and load the managed responder profile so
# a changed uniqueness policy takes effect without restarting strongSwan or
# terminating established CHILD_SAs.
TEST_UPGRADE_PROFILE=1 \
TEST_UCI_LOG="$tmp/uci.log" \
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" _upgrade-server-profile
grep -Fq 'unique = replace' "$tmp/root/etc/swanctl/conf.d/30-inbound.conf"

printf 'server transaction tests OK\n'
