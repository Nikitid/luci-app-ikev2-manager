#!/bin/sh

# After a long tunnel outage the FakeIP resolver kept running with healthy
# listeners while its tunnel path no longer resolved anything, and a failed
# FakeIP start left a router in standard mode for good. Exercise the recovery
# ladder and the start retry against stubs, then check the watcher wiring.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
router="$root/ikev2-manager-runtime/ikev2-domain-router.sh"
health="$root/ikev2-manager-runtime/ikev2-health.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
# The LuCI backend's source is the script plus the libraries it sources.
manager_source="$tmp/manager-source.sh"
cat "$root/luci-ikev2-manager/ikev2-manager.sh" \
	"$root"/ikev2-manager-runtime/lib/manager-*.sh >"$manager_source"

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

extract() {
	awk -v name="$1" '
		index($0, name "() {") == 1 { body = 1; close_with = "}" }
		index($0, name "() (") == 1 { body = 1; close_with = ")" }
		body { print }
		body && $0 == close_with { exit }
	' "$router"
}

for name in getv defaultv state_number data_plane_canary save_data_plane_state \
	data_plane_check recover_reliable_mode; do
	extract "$name" >>"$tmp/functions.sh"
	grep -q "^$name() " "$tmp/functions.sh" || fail "function is missing: $name"
done
sh -n "$tmp/functions.sh"

mkdir -p "$tmp/bin"
cp "$root/scripts/uci-stub.sh" "$tmp/bin/uci"
chmod +x "$tmp/bin/uci"

# Every scenario runs in its own subshell with fresh state. The stubs follow
# the extracted functions so they replace the ones the scenario must control.
setup() {
	rm -rf "$tmp/uci" "$tmp/run"
	mkdir -p "$tmp/uci" "$tmp/run"
	printf 'domains=domains\ndomains.engine=fakeip\nclient=client\nclient.enabled=1\n' \
		>"$tmp/uci/ikev2-manager"
	printf '1000\n' >"$tmp/now"
	: >"$tmp/calls"
}

stubs='
	PATH="$tmp/bin:$PATH"
	UCI_STUB_DIR="$tmp/uci"
	export PATH UCI_STUB_DIR
	config=ikev2-manager
	data_plane_state="$tmp/run/data-plane.state"
	tunnel_dns_state="$tmp/run/tunnel-dns.state"
	lock_dir="$tmp/run/lock"
	. "$tmp/functions.sh"
	date() { cat "$tmp/now"; }
	logger() { :; }
	quality_mark() { :; }
	internet_dns_reachable() { :; }
	init_config() { :; }
	runtime_healthy() { [ ! -e "$tmp/unhealthy" ]; }
	data_plane_canary() { printf "canary\n" >>"$tmp/calls"; [ -e "$tmp/canary-ok" ]; }
	probe_tunnel_data_plane() { [ -e "$tmp/tunnel-ok" ]; }
	ip() { :; }
	pid_lock_busy() { return 1; }
	with_lock() { "$@"; }
	restart_resolver() { printf "restart\n" >>"$tmp/calls"; }
	write_status() { printf "%s:%s\n" "$1" "${2:-}" >"$tmp/run/status"; }
	restore_dnsmasq() { :; }
	nft_stop() { :; }
	activate() {
		printf "activate\n" >>"$tmp/calls"
		[ -e "$tmp/activate-ok" ] || return 1
		uci set "$config.domains.engine=fakeip"
		uci commit "$config"
	}
'

state() { sed -n "s/^$1=//p" "$tmp/run/data-plane.state" | tail -n1; }
restarts_run() { grep -c '^restart$' "$tmp/calls" || true; }
at() { printf '%s\n' "$1" >"$tmp/now"; }

# A working data plane is recorded and never restarted.
setup
(
	eval "$stubs"
	: >"$tmp/canary-ok"
	data_plane_check
	[ "$(state state)" = ok ] || fail 'healthy data plane was not recorded as ok'
	[ "$(restarts_run)" = 0 ] || fail 'healthy data plane was restarted'

	# A healthy data plane is checked once a minute, unless the caller says
	# the tunnel has just come back.
	at 1030; data_plane_check
	[ "$(grep -c '^canary$' "$tmp/calls")" = 1 ] || fail 'healthy data plane was checked too often'
	data_plane_check now
	[ "$(grep -c '^canary$' "$tmp/calls")" = 2 ] || fail 'tunnel return did not force a check'
	at 1090; data_plane_check
	[ "$(grep -c '^canary$' "$tmp/calls")" = 3 ] || fail 'healthy data plane was not checked after a minute'
)
rm -f "$tmp/canary-ok"

# The tunnel itself is down: the resolver is not at fault and is left alone.
setup
(
	eval "$stubs"
	data_plane_check
	data_plane_check
	data_plane_check
	[ "$(state state)" = tunnel-down ] || fail 'tunnel outage was not recognised'
	[ "$(restarts_run)" = 0 ] || fail 'resolver was restarted during a tunnel outage'
)

# A failing tunnel DNS provider belongs to tunnel_dns_check.
setup
(
	eval "$stubs"
	: >"$tmp/tunnel-ok"
	printf 'failures=2\n' >"$tunnel_dns_state"
	data_plane_check
	data_plane_check
	[ "$(state state)" = tunnel-dns-down ] || fail 'tunnel DNS failure was not delegated'
	[ "$(restarts_run)" = 0 ] || fail 'resolver was restarted for a tunnel DNS provider failure'
)

# The incident: tunnel carries traffic, tunnel DNS answers, the live resolver
# does not. One failure is tolerated; the second restarts it.
setup
(
	eval "$stubs"
	: >"$tmp/tunnel-ok"
	data_plane_check
	[ "$(state state)" = degraded ] || fail 'first failure was not recorded as degraded'
	[ "$(restarts_run)" = 0 ] || fail 'resolver was restarted after a single failure'
	at 1020
	data_plane_check
	[ "$(restarts_run)" = 1 ] || fail 'stuck resolver was not restarted'
	[ "$(state state)" = restarted ] || fail 'restart was not recorded'
	[ "$(state restarts)" = 1 ] || fail 'restart count was not recorded'
	grep -q '^active:FakeIP resolver restarted' "$tmp/run/status" ||
		fail 'restart was not reported in the domain status'

	# Still failing: the next restart waits for the two-minute backoff.
	at 1040; data_plane_check
	at 1100; data_plane_check
	[ "$(restarts_run)" = 1 ] || fail 'restart backoff was not honoured'
	at 1140; data_plane_check
	[ "$(restarts_run)" = 2 ] || fail 'resolver was not restarted after the backoff'
	[ "$(state restarts)" = 2 ] || fail 'second restart was not counted'

	# Recovery keeps the count for an hour, then forgets it.
	: >"$tmp/canary-ok"
	at 1200; data_plane_check
	[ "$(state state)" = ok ] || fail 'recovery was not recorded'
	grep -q '^active:FakeIP data plane recovered' "$tmp/run/status" ||
		fail 'a stale restart report survived recovery'
	[ "$(state restarts)" = 2 ] || fail 'restart count was forgotten too early'
	at 4800; data_plane_check
	[ "$(state restarts)" = 0 ] || fail 'restart count was never forgotten'
)
rm -f "$tmp/canary-ok" "$tmp/tunnel-ok"

# Listener faults belong to ensure_runtime; the canary is not even run.
setup
(
	eval "$stubs"
	: >"$tmp/unhealthy"
	data_plane_check
	! grep -q canary "$tmp/calls" || fail 'canary ran against an unhealthy runtime'
)
rm -f "$tmp/unhealthy"

# Standard mode has no FakeIP data plane to check.
setup
(
	eval "$stubs"
	printf 'state=degraded\n' >"$data_plane_state"
	uci set ikev2-manager.domains.engine=nftset
	data_plane_check
	[ ! -e "$data_plane_state" ] || fail 'stale data-plane state survived standard mode'
)

# The mode is the operator's choice alone: nothing switches it, retries it or
# falls back to the other one on its own.
for name in fallback retry_fakeip set_fakeip_retry; do
	if grep -q "^$name() " "$router"; then
		fail "the automatic mode switch $name is still there"
	fi
done
if extract repair_runtime | grep -q 'engine=nftset'; then
	fail 'the FakeIP repair still switches to matching by address'
fi
if grep -q 'domain-router fallback' "$root/ikev2-manager-runtime/ikev2-domain-router.init"; then
	fail 'a failed FakeIP start still falls back to matching by address'
fi
if grep -q 'fakeip-retry\|fakeip_retry' "$health"; then
	fail 'the watcher still retries FakeIP'
fi

# Manual recovery restarts a running resolver through the verified path, a
# pause included: a pause only refuses what reaches the tunnel, the resolver
# keeps running.
setup
(
	eval "$stubs"
	uci set ikev2-manager.domains.paused=1
	recover_reliable_mode || fail 'manual resolver restart failed during a pause'
	[ "$(restarts_run)" = 1 ] || fail 'manual recovery did not restart the resolver during a pause'

	uci set ikev2-manager.domains.paused=0
	recover_reliable_mode || fail 'manual resolver restart failed'
	[ "$(restarts_run)" = 2 ] || fail 'manual recovery did not restart the resolver'
	grep -q '^active:FakeIP resolver restarted on request' "$tmp/run/status" ||
		fail 'manual restart was not reported'

	restart_resolver() { printf 'restart\n' >>"$tmp/calls"; : >"$tmp/unhealthy"; }
	if recover_reliable_mode; then fail 'an unhealthy restart was reported as success'; fi
	rm -f "$tmp/unhealthy"

	uci set ikev2-manager.domains.engine=nftset
	if recover_reliable_mode; then fail 'manual recovery succeeded with reliable mode disabled'; fi
	grep -q '^error:Reliable mode is not enabled' "$tmp/run/status" ||
		fail 'disabled reliable mode was not reported'
) || fail 'manual recovery scenario failed'

# The manual routing restart rebuilds policy routing and verifies what Apply
# verifies; a failing check fails the restart.
(
	eval "$(awk 'index($0, "pbr_restart_manual() {") == 1 { body = 1 } body { print } body && $0 == "}" { exit }' \
		"$root/ikev2-manager-runtime/ikev2-manager-system.sh")"
	die() { printf 'die:%s\n' "$*" >>"$tmp/manual"; exit 1; }
	getv() { printf '1\n'; }
	logger() { :; }
	routing_runtime_helper="$tmp/routing"
	printf '#!/bin/sh\nprintf "routing %%s\\n" "$1" >>"%s/manual"\n' "$tmp" >"$tmp/routing"
	chmod 755 "$tmp/routing"
	for step in sync_device_runtime sync_inbound_user_policy failclosed_check failclosed_ipv6_check; do
		eval "$step() { printf '%s\\n' $step >>\"\$tmp/manual\"; [ ! -e \"\$tmp/fail-$step\" ]; }"
	done
	: >"$tmp/manual"
	( pbr_restart_manual ) || fail 'a clean manual routing restart failed'
	printf '%s\n' 'routing stop' 'routing sync' sync_device_runtime sync_inbound_user_policy \
		failclosed_check failclosed_ipv6_check | cmp -s - "$tmp/manual" ||
		fail "the manual routing restart did not rebuild and verify: $(tr '\n' ' ' <"$tmp/manual")"
	: >"$tmp/fail-failclosed_check"
	: >"$tmp/manual"
	if ( pbr_restart_manual ); then fail 'a manual restart with an open tunnel table succeeded'; fi
	grep -q '^die:Fail-closed route validation failed' "$tmp/manual" ||
		fail 'a failed fail-closed check was not reported'
) || fail 'manual routing restart scenario failed'
grep -Fq '"/usr/libexec/ikev2-manager-system pbr-restart-async"' "$root/luci-ikev2-manager/acl.json" &&
	grep -Fq '"/usr/libexec/ikev2-manager-system recover-reliable-async"' "$root/luci-ikev2-manager/acl.json" ||
	fail 'manual recovery actions are not granted to the page'

# The canary asks the live instance through its authenticated controller.
setup
(
	eval "$stubs"
	eval "$(extract data_plane_canary)"
	. "$root/ikev2-manager-runtime/lib/controller.sh"
	data_plane_canary_urls='https://a.example/ https://b.example/'
	fixture_secret="$(printf '%064d' 7)"
	jsonfilter() {
		case "$*" in
			*clash_api.secret*) printf '%s\n' "$fixture_secret" ;;
			*@.delay*) sed -n 's/.*"delay":\([0-9]*\).*/\1/p' "$2" ;;
		esac
	}
	curl() {
		for arg in "$@"; do last="$arg"; done
		prev=''
		for arg in "$@"; do
			[ "$prev" = --config ] && grep -Fq "Bearer $fixture_secret" "$arg" &&
				printf 'auth\n' >>"$tmp/calls"
			prev="$arg"
		done
		printf '%s\n' "$last" >>"$tmp/calls"
		case "$last" in
			*a.example*) [ -e "$tmp/first-ok" ] && printf '{"delay":42}' || printf '{"message":"error"}' ;;
			*b.example*) [ -e "$tmp/second-ok" ] || return 22; printf '{"delay":42}' ;;
		esac
	}
	data_plane_canary && fail 'canary passed with both targets failing'
	grep -Fq 'http://127.0.0.44:1605/proxies/ikev2-out/delay?timeout=5000&url=https://a.example/' "$tmp/calls" ||
		fail 'canary did not test the tunnel outbound'
	grep -q '^auth$' "$tmp/calls" || fail 'canary did not authenticate'
	: >"$tmp/second-ok"
	data_plane_canary || fail 'canary did not fall back to its second target'

	# A controller that does not answer at all fails at once: a frozen instance
	# would hold every further target for the full timeout.
	: >"$tmp/calls"
	curl() { printf 'call\n' >>"$tmp/calls"; return 28; }
	data_plane_canary && fail 'canary passed with an unresponsive controller'
	[ "$(grep -c '^call$' "$tmp/calls")" = 1 ] ||
		fail 'canary kept waiting on an unresponsive controller'
)
rm -f "$tmp/second-ok"

# That the watcher checks the data plane only while the tunnel is up, and at
# once when it comes back, is checked on the running watcher by
# scripts/test-health-loop.sh.
grep -Fq 'data-plane-check) data_plane_check "${2:-}"' "$router" ||
	fail 'domain router does not dispatch data-plane-check'

# A manual reconnect during an outage removed the tunnel address; every socket
# opened meanwhile took the WAN address as its source and stayed broken after
# the tunnel returned. Only disabling the client may remove it.
awk '/^connect_action\(\) \{/,/^}/' "$manager_source" >"$tmp/connect"
[ -s "$tmp/connect" ] || fail 'connect_action is missing'
! grep -q 'addr flush' "$tmp/connect" || fail 'reconnect removes the tunnel address'

printf '%s\n' 'data-plane recovery tests OK'
