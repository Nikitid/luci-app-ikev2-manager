#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/runtime"
cp "$root/ikev2-manager-runtime/lib/actions.sh" "$tmp/runtime/actions.sh"
cp "$root/ikev2-manager-runtime/lib/routing.sh" "$tmp/runtime/routing.sh"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
while [ "${1:-}" = -q ]; do shift; done
case "${1:-}:${2:-}" in
	get:ikev2-manager.globals.configured) echo 1 ;;
	get:ikev2-manager.client.enabled) echo 0 ;;
	get:ikev2-manager.domains.engine) echo fakeip ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/pbr-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$TEST_PBR_LOG"
case "$1" in
reload) exit "${TEST_RELOAD_RC:-0}" ;;
restart) : >"${TEST_PBR_STATE:-/tmp/test-pbr-state}"; exit 0 ;;
running)
	[ "${TEST_RUNTIME_DOWN_UNTIL_RESTART:-0}" != 1 ] ||
		[ -e "${TEST_PBR_STATE:-/tmp/test-pbr-state}" ]
	;;
*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/system" <<'EOF'
#!/bin/sh
printf 'system %s\n' "$1" >>"$TEST_DOMAIN_LOG"
case "$1" in _sync-pbr | failclosed-check) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$tmp/bin/domain-router" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$TEST_DOMAIN_LOG"
[ "$1" = refresh-rules ]
EOF
cat >"$tmp/bin/xfrm" <<'EOF'
#!/bin/sh
printf 'xfrm %s\n' "$1" >>"$TEST_DOMAIN_LOG"
[ "$1" = start ]
EOF
cat >"$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
printf 'Name: %s\nAddress 1: 192.0.2.1\n' "$1"
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list chain inet fw4 forward') echo 'jump forward_lan' ;;
	'list chain inet fw4 pbr_prerouting')
		[ -e "$TEST_PBR_OURS" ] || exit 1
		echo 'ip daddr @pbr_ikev2out_4_dst_ip goto pbr_mark_0x020000 comment "IKEv2 PBR domains"'
		;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/discord" <<'EOF'
#!/bin/sh
[ "$1" = sync ]
EOF
chmod 755 "$tmp/bin"/*
# Keep chmod confined to test stubs; flock remains owned by the host system.
ln -s "$(command -v flock)" "$tmp/bin/flock"

run_restart() {
	PATH="$tmp/bin:/usr/bin:/sbin:/bin" \
	TEST_PBR_LOG="$tmp/pbr.log" \
	TEST_DOMAIN_LOG="$tmp/domain.log" \
	TEST_RELOAD_RC="${TEST_RELOAD_RC:-0}" \
	TEST_RUNTIME_DOWN_UNTIL_RESTART="${TEST_RUNTIME_DOWN_UNTIL_RESTART:-0}" \
	TEST_PBR_STATE="$tmp/pbr.state" \
	TEST_PBR_OURS="$tmp/pbr.ours" \
	IKEV2_PBR_RESTART_LOCK="$tmp/restart.lock" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.status" \
	IKEV2_PBR_RESTART_LOG="$tmp/restart.log" \
	IKEV2_PBR_WAIT_SECONDS=1 \
	IKEV2_SERVICE_CIDR_FILE="$tmp/cidrs.txt" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/runtime" \
	IKEV2_SYSTEM_HELPER="$tmp/bin/system" \
	IKEV2_DOMAIN_ROUTER_HELPER="$tmp/bin/domain-router" \
	IKEV2_XFRM_INIT="$tmp/bin/xfrm" \
	IKEV2_PBR_INIT="$tmp/bin/pbr-init" \
	IKEV2_DISCORD_VOICE="$tmp/bin/discord" \
	IKEV2_ROUTING_HELPER="$tmp/bin/routing" \
		sh "$root/luci-ikev2-domains/restart-pbr.sh" --wait
}
cat >"$tmp/bin/routing" <<'EOF'
#!/bin/sh
[ "$1" = check ]
EOF
chmod 755 "$tmp/bin/routing"

# A list change rewrites the routing sets and the FakeIP rules, with the XFRM
# links up first, and never touches PBR when PBR holds nothing of ours.
: >"$tmp/pbr.log"
: >"$tmp/domain.log"
run_restart || { cat "$tmp/restart.log" >&2; printf '%s\n' 'a list refresh failed' >&2; exit 1; }
if grep -Eq '^(reload|restart)$' "$tmp/pbr.log"; then
	printf '%s\n' 'a list change rebuilt PBR' >&2
	exit 1
fi
grep -Fxq refresh-rules "$tmp/domain.log" || {
	printf '%s\n' 'a list refresh skipped the reliable-mode rules' >&2
	exit 1
}
[ "$(grep -n '^xfrm start$' "$tmp/domain.log" | head -n1 | cut -d: -f1)" -lt \
	"$(grep -n '^system _sync-pbr$' "$tmp/domain.log" | head -n1 | cut -d: -f1)" ] || {
	printf '%s\n' 'routing was synced before the XFRM links came up' >&2
	exit 1
}

# A router that routed through PBR keeps its copy of our policies until the
# first sync retires it; PBR is then reloaded once, without a second rebuild.
: >"$tmp/pbr.ours"
: >"$tmp/pbr.log"
run_restart
[ "$(grep -c '^reload$' "$tmp/pbr.log")" = 1 ]
if grep -Fxq restart "$tmp/pbr.log"; then
	printf '%s\n' 'a successful PBR reload used the stop/start path' >&2
	exit 1
fi

: >"$tmp/pbr.log"
TEST_RELOAD_RC=1 run_restart
[ "$(grep -c '^reload$' "$tmp/pbr.log")" = 1 ]
if grep -Fxq restart "$tmp/pbr.log"; then
	printf '%s\n' 'non-zero reload result caused a redundant restart despite healthy runtime' >&2
	exit 1
fi

# A PBR that is not running routes nothing and is left alone.
: >"$tmp/pbr.log"
rm -f "$tmp/pbr.state"
TEST_RUNTIME_DOWN_UNTIL_RESTART=1 run_restart || {
	printf '%s\n' 'a list refresh failed while PBR was stopped' >&2
	exit 1
}
if grep -Eq '^(reload|restart)$' "$tmp/pbr.log"; then
	printf '%s\n' 'a stopped PBR was started by a list change' >&2
	exit 1
fi
rm -f "$tmp/pbr.ours"

printf '%s\n' 'PBR restart tests OK'
