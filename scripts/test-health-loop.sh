#!/bin/sh
#
# The watcher, run as a whole against stubs with its intervals shortened.
# It synced policy routing, device routing and Discord voice on every pass
# whether they had drifted or not, read each setting with its own uci call and
# started the XFRM init script every fifteen seconds; on an idle router that
# was about a fifth of a CPU core. It now checks, repairs only what a check
# finds broken and does so under the router action lock, follows the tunnel
# for the routes that depend on it, and stops at once on TERM.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
watcher=''
cleanup() {
	if [ -n "$watcher" ]; then
		kill "$watcher" 2>/dev/null || :
		wait "$watcher" 2>/dev/null || :
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	[ ! -s "$tmp/log" ] || sed 's/^/  log: /' "$tmp/log" >&2
	exit 1
}

S="$tmp/state"
mkdir -p "$S" "$tmp/bin" "$tmp/run" "$tmp/net/ipsec-out" "$tmp/net/ipsec-in"
export S
log="$tmp/log"
: >"$log"
printf '0x1091\n' >"$tmp/net/ipsec-out/flags"
printf '0x1091\n' >"$tmp/net/ipsec-in/flags"
: >"$S/sa-up"

settings() {
	printf "%s\n" "ikev2-manager.globals.configured='1'" \
		"ikev2-manager.domains.engine='fakeip'" \
		"ikev2-manager.domains.paused='${1:-0}'" \
		"ikev2-manager.client.enabled='1'" \
		"ikev2-manager.server.enabled='1'" >"$S/uci.show"
	[ -z "${2:-}" ] || printf "%s\n" "ikev2-manager.tunnel_2=tunnel" \
		"ikev2-manager.tunnel_2.enabled='1'" >>"$S/uci.show"
}
settings 0

stub() {
	printf '#!/bin/sh\n%s\n' "$2" >"$tmp/bin/$1"
	chmod 755 "$tmp/bin/$1"
}
# Every helper records its call, and whether the router action lock was held.
record='l=-; [ -d "$S/action.lock" ] && l=locked; printf "%s %s %s\n" "${0##*/}" "$*" "$l" >>"$S/../log"'
stub uci "[ \"\$1 \$2 \$3\" = '-q show ikev2-manager' ] && cat \"\$S/uci.show\""
stub nft "[ \"\$*\" = 'list table inet ikev2_pause' ] && [ -e \"\$S/pause-table\" ]"
# HTTPS crosses a link unless the test says the tunnel behind it is silent.
stub curl 'link=
while [ "$#" -gt 0 ]; do [ "$1" != --interface ] || link="$2"; shift; done
[ ! -e "$S/silent-$link" ] || exit 28
echo ip=192.0.2.1'
stub logger ':'
stub routing "$record
case \"\$1\" in check) [ ! -e \"\$S/routing-broken\" ] ;; sync) rm -f \"\$S/routing-broken\" ;; esac"
stub device "$record"
stub discord "$record"
stub user-policy "$record"
stub domain-router "$record
[ \"\$1\" != exits-apply ] || [ ! -e \"\$S/exits-refused\" ]"
stub manager "$record"
stub sync-vips "$record"
stub community "$record"
stub system "$record"
stub xfrm "$record"
stub quality "$record
sleep 3"
stub sa "$record
case \"\$1\" in
	tunnels)
		[ ! -e \"\$S/sa-up\" ] || printf '1\\t1\\t10.20.20.10\\n'
		[ ! -e \"\$S/sa2-up\" ] || printf '2\\t1\\t10.30.0.7\\n' ;;
	conn-loaded) exit 0 ;;
	*) exit 1 ;;
esac"
ln -s "$(command -v flock)" "$tmp/bin/flock"
printf 'state=ok\n' >"$tmp/run/data-plane.state"

start_watcher() {
PATH="$tmp/bin:$PATH" \
IKEV2_RUN_DIR="$tmp/run" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_ACTION_LOCK="$S/action.lock" \
IKEV2_ACTION_LOCK_STATUS="$S/action.lock.status" \
IKEV2_HEALTH_TICK=1 \
IKEV2_HEALTH_PASS_INTERVAL="${1:-1}" \
IKEV2_HEALTH_CHECK_INTERVAL=3 \
IKEV2_HEALTH_QUALITY_INTERVAL=2 \
IKEV2_HEALTH_TUNNEL_PROBE_INTERVAL=1 \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_NFT="$tmp/bin/nft" \
IKEV2_NET_DIR="$tmp/net" \
IKEV2_VIP_FILE="$tmp/run/vip4" \
IKEV2_DATA_PLANE_STATE="$tmp/run/data-plane.state" \
IKEV2_SA_HELPER="$tmp/bin/sa" \
IKEV2_ROUTING_HELPER="$tmp/bin/routing" \
IKEV2_SYSTEM_HELPER="$tmp/bin/system" \
IKEV2_DOMAIN_ROUTER_HELPER="$tmp/bin/domain-router" \
IKEV2_DEVICE_ROUTING_HELPER="$tmp/bin/device" \
IKEV2_DISCORD_VOICE_HELPER="$tmp/bin/discord" \
IKEV2_USER_POLICY_HELPER="$tmp/bin/user-policy" \
IKEV2_MANAGER_HELPER="$tmp/bin/manager" \
IKEV2_SYNC_VIPS="$tmp/bin/sync-vips" \
IKEV2_QUALITY_HELPER="$tmp/bin/quality" \
IKEV2_COMMUNITY_HELPER="$tmp/bin/community" \
IKEV2_XFRM_INIT="$tmp/bin/xfrm" \
IKEV2_TUNNEL_RETURN_HOLD=3 \
	sh "$root/ikev2-manager-runtime/ikev2-health.sh" &
watcher=$!
}
start_watcher

count() {
	local n
	n="$(grep -c "$1" "$log" 2>/dev/null)" || :
	printf '%s\n' "${n:-0}"
}
wait_for() {
	local i=0
	while [ "$i" -lt 100 ]; do
		[ "$(count "$1")" -ge "${2:-1}" ] && return 0
		sleep 0.1
		i=$((i + 1))
	done
	fail "${3:-waited in vain for: $1}"
}

# A healthy router: everything is checked, nothing is synced but the tunnel
# routes the first pass finds an SA for.
wait_for '^routing check' 2 'policy routing is not checked'
wait_for '^device check' 1 'device routing is not checked'
wait_for '^routing check' 3 'the passes stopped while the quality sample ran'
[ "$(count '^routing sync ')" = 1 ] || fail 'a healthy runtime was synced more than for its tunnel'
[ "$(count 'sync-all')" = 0 ] || fail 'the watcher still syncs every runtime on every pass'
for helper in device discord user-policy; do
	[ "$(count "^$helper sync")" = 0 ] || fail "a healthy $helper runtime was synced"
done
[ "$(count '^xfrm start')" -le "$(count '^routing check')" ] ||
	fail 'the XFRM links were started on every pass, not with the checks'
wait_for '^domain-router data-plane-check now' 1 'the data plane was not checked when the tunnel came up'
grep -q '^state=up ' "$tmp/run/ikev2-health.status" || fail 'the status does not say the tunnel is up'

# A runtime that drifted is repaired, under the router action lock.
: >"$S/routing-broken"
before="$(count '^routing sync ')"
wait_for '^routing sync ' $((before + 1)) 'a broken policy routing was not repaired'
grep '^routing sync ' "$log" | tail -n 1 | grep -q ' locked$' || fail 'a repair ran without the action lock'
# The stub records its call as it starts; the watcher releases the lock once
# the repair returns, a moment later on a loaded machine.
i=0
while [ -d "$S/action.lock" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
[ ! -d "$S/action.lock" ] || fail 'a repair left the action lock held'

# The tunnel goes: its routes follow at once, and the client is brought back.
before="$(count '^routing sync ')"
rm -f "$S/sa-up"
wait_for '^routing sync ' $((before + 1)) 'the routes did not follow the tunnel going down'
wait_for '^manager ensure-client' 1 'a lost tunnel was not reconnected'
plane="$(count 'data-plane-check')"
sleep 2
[ "$(count 'data-plane-check')" = "$plane" ] || fail 'the data plane was checked while the tunnel was down'
grep -q '^state=down ' "$tmp/run/ikev2-health.status" || fail 'the status does not say the tunnel is down'

# It comes back: the address first, then the routes, then the data plane.
: >"$S/sa-up"
wait_for '^domain-router data-plane-check now' 2 'the data plane was not checked when the tunnel returned'
wait_for '^sync-vips' 1 'the tunnel address was not reconciled when the tunnel returned'

# A router action holds back the passes, but not the quality sample, which
# only pings.
sleep 30 &
holder=$!
mkdir "$S/action.lock"
printf 'owner=test\naction_id=1\npid=%s\npid_start=\n' "$holder" >"$S/action.lock.status"
sleep 1.5
checks="$(count '^routing check')"
samples="$(count '^quality sample')"
sleep 4.5
[ "$(count '^routing check')" = "$checks" ] || fail 'the watcher checked the runtimes during a router action'
[ "$(count '^quality sample')" -gt "$samples" ] || fail 'a router action held back the quality sample'
kill "$holder" 2>/dev/null || :
wait "$holder" 2>/dev/null || :
rm -rf "$S/action.lock" "$S/action.lock.status"

# The pause block follows the setting.
settings 1
wait_for '^system _pause-sync' 1 'a missing pause block was not restored'

# TERM is acted on during the sleep, and the destination sets are kept.
kill -TERM "$watcher"
i=0
while kill -0 "$watcher" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
! kill -0 "$watcher" 2>/dev/null || fail 'the watcher did not stop on TERM'
watcher=''
grep -q '^routing persist' "$log" || fail 'the watcher stopped without keeping the destination sets'

# A second tunnel stands in for the first: the exits move to it at once and
# sing-box is told; the first takes them back only after it has stayed up.
mkdir -p "$tmp/net/ipsec-out2"
printf '0x1091\n' >"$tmp/net/ipsec-out2/flags"
: >"$S/sa2-up"
settings 0 two
applies="$(count '^domain-router exits-apply')"
start_watcher
state="$tmp/run/ikev2-tunnels.state"
i=0
while ! grep -qx 'exit 2 2' "$state" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
grep -qx 'exit 1 1' "$state" && grep -qx 'exit 2 2' "$state" || fail 'each exit did not start on its own tunnel'
# The first choice reaches sing-box too, after the state is written; counted
# before it is, it would pass for the move below.
wait_for '^domain-router exits-apply' $((applies + 1)) 'sing-box was not told the first choice'
applies="$(count '^domain-router exits-apply')"
before="$(count '^routing sync ')"
ensures="$(count '^manager ensure-client')"
rm -f "$S/sa-up"
wait_for '^domain-router exits-apply' $((applies + 1)) 'sing-box was not moved to the standing-in tunnel'
grep -qx 'exit 1 2' "$state" || fail 'the first exit did not move to the second tunnel'
[ "$(count '^routing sync ')" -gt "$before" ] || fail 'the routes did not follow the exit'
wait_for '^manager ensure-client' $((ensures + 1)) 'the lost tunnel was not reconnected while the other stood in'
: >"$S/sa-up"
sleep 1.5
grep -qx 'exit 1 2' "$state" || fail 'the first tunnel took its exit back at once'
wait_for '^domain-router exits-apply' $((applies + 2)) 'the first tunnel never took its exit back'
grep -qx 'exit 1 1' "$state" || fail 'the first exit did not return to its tunnel'
# A resolver that does not take the choice is asked again on the next pass.
applies="$(count '^domain-router exits-apply')"
: >"$S/exits-refused"
rm -f "$S/sa-up"
wait_for '^domain-router exits-apply' $((applies + 3)) 'a refused exit choice was not offered again'
rm -f "$S/exits-refused"
sleep 2
applies="$(count '^domain-router exits-apply')"
sleep 2
[ "$(count '^domain-router exits-apply')" = "$applies" ] || fail 'a taken exit choice was offered again'
: >"$S/sa-up"

# A tunnel that stays connected while nothing crosses it: strongSwan takes
# three minutes to call its server dead, and all that time its traffic went
# nowhere. Probed through each tunnel, it loses its exits like one that went
# down - but only against another tunnel that answers.
until_state() {
	local i=0
	while ! grep -qx "$1" "$state" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
	grep -qx "$1" "$state" 2>/dev/null
}
until_state 'exit 1 1' || fail 'the first tunnel did not take its exit back before the probe scenario'
i=0
while ! grep -qx '2:1' "$tmp/run/ikev2-tunnel-probe.state" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -qx '2:1' "$tmp/run/ikev2-tunnel-probe.state" || fail 'the tunnels are not probed while two are up'
sleep 2
applies="$(count '^domain-router exits-apply')"
: >"$S/silent-ipsec-out2"
until_state 'exit 2 1' || fail 'a tunnel nothing crosses kept its exit'
grep -qx 'silent 2 1' "$state" || fail 'the silent tunnel is not recorded'
grep -qx 'exit 2s 0' "$state" || fail 'what is bound to the silent tunnel was given another'
grep -qx 'exit 1 1' "$state" || fail 'the answering tunnel lost its own exit'
wait_for '^domain-router exits-apply' $((applies + 1)) 'sing-box was not moved off the silent tunnel'
# It answers again: back among the tunnels, and held like one that returned.
rm -f "$S/silent-ipsec-out2"
until_state 'exit 2s 2' || fail 'a tunnel that answers again did not get its bound exit back'
until_state 'exit 2 2' || fail 'a tunnel that answers again never took its exit back'
! grep -q '^silent ' "$state" || fail 'a tunnel that answers again is still recorded as silent'
# No tunnel reaches the endpoints: they or the uplink failed, nothing moves.
: >"$S/silent-ipsec-out"
: >"$S/silent-ipsec-out2"
sleep 5
grep -qx 'exit 1 1' "$state" && grep -qx 'exit 2 2' "$state" ||
	fail 'the exits moved while every tunnel failed the probe'
! grep -q '^silent ' "$state" || fail 'a tunnel was called silent with no other answering'
rm -f "$S/silent-ipsec-out" "$S/silent-ipsec-out2"
kill -TERM "$watcher"
wait "$watcher" 2>/dev/null || :
watcher=''
rm -f "$S/sa2-up"

# A signal from the inbound watcher, which follows strongSwan's events, runs
# the next pass at once: the routes then follow the tunnel without waiting.
settings 0
start_watcher 30
wait_for '^sa tunnels' 1 'the watcher did not start its first pass'
sleep 2
passes="$(count '^sa tunnels')"
kill -USR1 "$watcher"
wait_for '^sa tunnels' $((passes + 1)) 'a wake-up signal did not run a pass'
kill -TERM "$watcher"
wait "$watcher" 2>/dev/null || :
watcher=''

printf '%s\n' 'health loop tests OK'
