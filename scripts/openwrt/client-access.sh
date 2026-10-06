#!/bin/sh
# Isolated kernel packet test. Requires XFRM interfaces and nft_xfrm; it does not
# alter existing namespaces, management routes, firewall tables or IKE SAs.
set -eu
umask 077
ulimit -c 0
client="ikev2-sa-client-$$"
server="ikev2-sa-server-$$"
work="$(mktemp -d /tmp/ikev2-sa-binding.XXXXXX)"
echo_pid=''
udp_pid=''
client_created=0
server_created=0
cleanup() {
	[ -z "$echo_pid" ] || kill "$echo_pid" 2>/dev/null || :
	[ -z "$udp_pid" ] || kill "$udp_pid" 2>/dev/null || :
	for namespace in "$client" "$server"; do
		case "$namespace" in
			"$client") [ "$client_created" = 1 ] || continue ;;
			"$server") [ "$server_created" = 1 ] || continue ;;
		esac
		for process in $(ip netns pids "$namespace" 2>/dev/null); do kill "$process" 2>/dev/null || :; done
		ip netns del "$namespace" 2>/dev/null || :
	done
	rm -rf "$work"
}
trap cleanup EXIT INT TERM
fail() {
	printf 'client-access: %s\n' "$*" >&2
	[ ! -f "$work/probe.log" ] || cat "$work/probe.log" >&2
	[ ! -f "$work/udp.log" ] || tail -n 10 "$work/udp.log" >&2
	[ "$server_created" != 1 ] || ip netns exec "$server" nft list table inet ikev2_client_access >&2 2>/dev/null || :
	exit 1
}
ip netns add "$client"
client_created=1
ip netns add "$server"
server_created=1
ip netns exec "$client" ip link add transit type veth peer name transit-peer netns "$server" || fail 'isolated veth creation failed'
ip -n "$client" addr add 10.231.254.2/24 dev transit
ip -n "$server" addr add 10.231.254.1/24 dev transit-peer
ip -n "$client" link set transit up
ip -n "$server" link set transit-peer up
for namespace in "$client" "$server"; do
	ip -n "$namespace" link set lo up
	ip -n "$namespace" link add ipsec-in type xfrm dev lo if_id 43 || fail "isolated XFRM interface creation failed"
	ip -n "$namespace" link set ipsec-in up
done
ip -n "$client" addr add 10.25.0.10/32 dev lo
ip -n "$server" addr add 172.31.254.1/32 dev lo
ip -n "$client" route add 172.31.254.1/32 dev ipsec-in src 10.25.0.10
ip -n "$server" route add 10.25.0.10/32 dev ipsec-in src 172.31.254.1
# Each disposable run creates fresh ESP key material.
key="0x$(openssl rand -hex 20)"
configure() {
	ns="$1"; own="$2"; peer="$3"; inner="$4"; other="$5"; outgoing="$6"; incoming="$7"; request="${8:-12}"
	ip netns exec "$ns" ip xfrm state add src "$own" dst "$peer" proto esp spi "$outgoing" reqid "$request" mode tunnel if_id 43 aead 'rfc4106(gcm(aes))' "$key" 128
	ip netns exec "$ns" ip xfrm state add src "$peer" dst "$own" proto esp spi "$incoming" reqid "$request" mode tunnel if_id 43 aead 'rfc4106(gcm(aes))' "$key" 128
	ip netns exec "$ns" ip xfrm policy add dir out src "$inner/32" dst "$other/32" if_id 43 tmpl src "$own" dst "$peer" proto esp reqid "$request" mode tunnel
	ip netns exec "$ns" ip xfrm policy add dir in src "$other/32" dst "$inner/32" if_id 43 tmpl src "$peer" dst "$own" proto esp reqid "$request" mode tunnel
}
configure "$client" 10.231.254.2 10.231.254.1 10.25.0.10 172.31.254.1 0x100 0x200
configure "$server" 10.231.254.1 10.231.254.2 172.31.254.1 10.25.0.10 0x200 0x100
ip netns exec "$server" socat TCP4-LISTEN:4443,bind=172.31.254.1,reuseaddr,fork EXEC:/bin/cat >"$work/echo.log" 2>&1 &
echo_pid=$!
ip netns exec "$server" socat -T 2 UDP4-RECVFROM:4444,bind=172.31.254.1,reuseaddr,fork PIPE >"$work/udp.log" 2>&1 &
udp_pid=$!
sleep 1
kill -0 "$echo_pid" || fail 'echo server failed'
probe() {
	endpoint="${1:-TCP4}:172.31.254.1:${2:-4443},bind=10.25.0.10,connect-timeout=1"
	# UDP has no EOF; an empty EOF datagram must not close the echo fixture.
	[ "${1:-TCP4}" != UDP4 ] || endpoint="$endpoint,shut-none"
	printf 'sa-binding-probe\n' | ip netns exec "$client" socat -T 1 - "$endpoint" 2>"$work/probe.log" || :
}
[ "$(probe)" = sa-binding-probe ] || fail 'encrypted baseline traffic failed'
compiler="${CLIENT_ACCESS_COMPILER:-/usr/libexec/ikev2-manager.d/client-access-policy.uc}"
apply() {
	in_spi="$1"; out_spi="$2"; allowed_reqid="${3:-12}"
	identity="${4:-alice}"; admitted="${5:-alice}"; lease="${6:-30}"
	users="[]"
	[ "$admitted" = none ] || users="[{\"identity\":\"$admitted\",\"policy\":\"example\"}]"
	cat >"$work/input.json" <<POLICY
{"version":1,"pool":{"first":"10.25.0.10","last":"10.25.0.100"},
"policies":[{"version":1,"id":"example","revision":1,
"server":{"address":"vpn.example.com","remote_id":"vpn.example.com"},
"virtual_subnet":"172.31.254.0/24","exit":"1",
"resources":[{"id":"api","domain":"api.example.com","address":"172.31.254.1",
"transports":[{"protocol":"tcp","ports":[4443,4445]},{"protocol":"udp","ports":[4444]}]}]}],
"users":$users,"sessions":[{"identity":"$identity","address":"10.25.0.10",
"reqid":$allowed_reqid,"spi_in":"$(printf '%08x' "$in_spi")","spi_out":"$(printf '%08x' "$out_spi")"}],"lease_seconds":$lease}
POLICY
	ucode "$compiler" authorize <"$work/input.json" >"$work/compiled.json"
	ucode -e 'import {readfile} from "fs"; let d=json(readfile(ARGV[0])); if(type(d.nft)!="string" || !length(d.nft)) die("Missing compiled guard"); print(d.nft);' "$work/compiled.json" >"$work/guard.nft"
	{
		if ip netns exec "$server" nft list table inet ikev2_client_access >/dev/null 2>&1; then printf '%s\n' 'delete table inet ikev2_client_access'; fi
		cat "$work/guard.nft"
	} >"$work/transaction.nft"
	ip netns exec "$server" nft -c -f "$work/transaction.nft" || fail 'compiled guard validation failed'
	ip netns exec "$server" nft -f "$work/transaction.nft" || fail 'compiled guard installation failed'
	ip netns exec "$server" nft list table inet ikev2_client_access >/dev/null || fail 'compiled guard was not installed'
}
apply 0x100 0x200
[ "$(probe)" = sa-binding-probe ] || fail 'correct authenticated SA binding failed'
# Exercise the actual controller with committed publication and local SA
# evidence. Only VICI evidence is a fixture; nft and encrypted traffic are real.
mkdir -p "$work/controller/state" "$work/controller/uci"
chmod 700 "$work/controller/state"
cp "${CLIENT_ACCESS_HELPER:-/usr/libexec/ikev2-client-access}" "$work/controller/helper.sh"
fixture="${CLIENT_ACCESS_RUNTIME_FIXTURE:-/src/scripts/openwrt/client-runtime-state.uc}"
ucode "$fixture" "$work/controller/state" seed "$work/controller/sessions.json"
ucode "$fixture" "$work/controller/state" valid-sa "$work/controller/sessions.json"
cat >"$work/controller/uci/ikev2-manager" <<'CONFIG'
config server 'server'
 option enabled '1'
 option pool4 '10.25.0.10-10.25.0.100'
CONFIG
cat >"$work/controller/uci.sh" <<UCI
#!/bin/sh
exec /sbin/uci -c '$work/controller/uci' "\$@"
UCI
cat >"$work/controller/swanmon.sh" <<SWANMON
#!/bin/sh
case "\$(cat '$work/controller/query-mode')" in
 error) exit 1 ;;
 hang) sleep 20; exit 1 ;;
esac
cat '$work/controller/sessions.json'
SWANMON
chmod 700 "$work/controller/uci.sh" "$work/controller/swanmon.sh"
printf '%s\n' valid >"$work/controller/query-mode"
controller() {
	env IKEV2_CLIENT_REQUIRE_PATH=0 IKEV2_RUNTIME_LIB_DIR="${CLIENT_ACCESS_RUNTIME_LIB:-/usr/libexec/ikev2-manager.d}" \
		IKEV2_CLIENT_STATE_DIR="$work/controller/state" IKEV2_CLIENT_RUNTIME_DIR="$work/controller/runtime" \
		IKEV2_SWANMON="$work/controller/swanmon.sh" IKEV2_UCI_BIN="$work/controller/uci.sh" \
		"$(command -v ip)" netns exec "$server" sh "$work/controller/helper.sh" "$1"
}
controller sync || fail 'controller publication failed'
[ "$(probe)" = sa-binding-probe ] || fail 'controller did not admit TCP'
[ "$(probe UDP4 4444)" = sa-binding-probe ] || fail 'controller did not admit UDP'
ucode "$fixture" "$work/controller/state" revoke "$work/controller/sessions.json"
controller sync || fail 'controller revocation failed'
[ -z "$(probe)" ] || fail 'committed revocation retained TCP access'
[ -z "$(probe UDP4 4444)" ] || fail 'committed revocation retained UDP access'
ucode "$fixture" "$work/controller/state" enable "$work/controller/sessions.json"
controller sync || fail 'controller did not refresh enabled policy'
[ "$(probe)" = sa-binding-probe ] || fail 'controller positive control failed'
printf '%s\n' error >"$work/controller/query-mode"
if controller sync; then fail 'failed VICI query was accepted'; fi
[ -z "$(probe)" ] || fail 'VICI failure retained access'
[ -z "$(probe UDP4 4444)" ] || fail 'VICI failure retained UDP access'
grep -Fxq state=failed "$work/controller/runtime/status" || fail 'VICI failure not reported'
printf '%s\n' valid >"$work/controller/query-mode"
controller sync || fail 'controller recovery failed'
cp "$work/controller/state/state.json" "$work/controller/committed.json"
ucode "$fixture" "$work/controller/state" invalid-state "$work/controller/sessions.json"
if controller sync; then fail 'inconsistent publication was accepted'; fi
[ -z "$(probe)" ] || fail 'invalid publication retained access'
cp "$work/controller/committed.json" "$work/controller/state/state.json"
controller sync || fail 'restored publication failed'
printf '%s\n' hang >"$work/controller/query-mode"
started="$(date +%s)"
if controller sync; then fail 'unanswered VICI query was accepted'; fi
[ "$(( $(date +%s) - started ))" -le 7 ] || fail 'VICI query was not bounded'
[ -z "$(probe)" ] || fail 'VICI timeout retained access'
printf '%s\n' valid >"$work/controller/query-mode"
controller sync || fail 'timeout recovery failed'
controller close || fail 'explicit controller closure failed'
[ -z "$(probe)" ] || fail 'explicit closure retained access'
controller watch >"$work/controller/watch.log" 2>&1 &
watcher_job=$!
sleep 2
[ "$(probe)" = sa-binding-probe ] || fail 'watcher did not admit traffic'
[ "$(probe UDP4 4444)" = sa-binding-probe ] || fail 'watcher did not admit UDP'
worker_pid="$(cat "$work/controller/runtime/worker.lock/pid")"
kill -KILL "$worker_pid"
wait "$watcher_job" 2>/dev/null || :
sleep 16
[ -z "$(probe)" ] || fail 'killed watcher grants did not expire'
[ -z "$(probe UDP4 4444)" ] || fail 'killed watcher UDP grants did not expire'
controller sync || fail 'stale watcher lock was not recovered'
[ "$(probe)" = sa-binding-probe ] || fail 'stale-lock recovery did not admit traffic'
controller watch >"$work/controller/watch.log" 2>&1 &
watcher_job=$!
sleep 2
worker_pid="$(cat "$work/controller/runtime/worker.lock/pid")"
kill -TERM "$worker_pid"
wait "$watcher_job" 2>/dev/null || :
[ -z "$(probe)" ] || fail 'stopped watcher retained access'
[ -z "$(probe UDP4 4444)" ] || fail 'stopped watcher retained UDP access'
ip netns exec "$server" nft delete table inet ikev2_client_access
ip netns exec "$server" nft add table inet ikev2_client_access
ip netns exec "$server" nft add chain inet ikev2_client_access unrelated_owner
if controller sync; then fail 'foreign table was replaced'; fi
ip netns exec "$server" nft list chain inet ikev2_client_access unrelated_owner >/dev/null || fail 'foreign table was changed'
ip netns exec "$server" nft delete table inet ikev2_client_access
controller sync || fail 'controller did not install a missing guard'
[ "$(probe)" = sa-binding-probe ] || fail 'missing-guard recovery did not admit traffic'
/sbin/uci -c "$work/controller/uci" set ikev2-manager.server.enabled=0
/sbin/uci -c "$work/controller/uci" commit ikev2-manager
controller sync || fail 'disabled server closure failed'
[ -z "$(probe)" ] || fail 'disabled server retained access'
[ -z "$(probe UDP4 4444)" ] || fail 'disabled server retained UDP access'
/sbin/uci -c "$work/controller/uci" set ikev2-manager.server.enabled=1
/sbin/uci -c "$work/controller/uci" commit ikev2-manager
controller sync || fail 'enabled server recovery failed'
printf '%s\n' 'client controller: persistent assignments, errors, timeout, stop, crash expiry and ownership OK'
apply 0x101 0x200
[ -z "$(probe)" ] || fail 'different inbound SA passed an old grant'
apply 0x100 0x201
[ -z "$(probe)" ] || fail 'different outbound SA passed an old grant'
apply 0x100 0x200 13
[ -z "$(probe)" ] || fail 'different request ID passed an old grant'
apply 0x100 0x200
[ "$(probe)" = sa-binding-probe ] || fail 'restoring the SA binding did not restore traffic'
[ "$(probe UDP4 4444)" = sa-binding-probe ] || fail 'assigned encrypted UDP failed'
apply 0x100 0x200 12 unknown alice
[ -z "$(probe)" ] || fail 'unknown identity reached an assigned service'
apply 0x100 0x200 12 alice none
[ -z "$(probe UDP4 4444)" ] || fail 'revoked UDP access remained open'
apply 0x100 0x200 12 alice alice 5
[ "$(probe)" = sa-binding-probe ] || fail 'short lease never allowed baseline traffic'
sleep 6
[ -z "$(probe)" ] || fail 'expired grant passed encrypted TCP'
# Revocation also interrupts an already established server-to-client stream.
apply 0x100 0x200
cat >"$work/stream.sh" <<'STREAM'
#!/bin/sh
while :; do printf 'stream-data\n'; sleep 1; done
STREAM
chmod 700 "$work/stream.sh"
ip netns exec "$server" socat TCP4-LISTEN:4445,bind=172.31.254.1,reuseaddr EXEC:"$work/stream.sh" >"$work/stream-server.log" 2>&1 &
stream_server=$!
sleep 1
ip netns exec "$client" socat -u TCP4:172.31.254.1:4445,bind=10.25.0.10,connect-timeout=2 - >"$work/stream.out" 2>"$work/stream-client.log" &
stream_client=$!
sleep 2
[ -s "$work/stream.out" ] || fail 'established stream never received baseline data'
apply 0x100 0x200 12 alice none
sleep 1
before="$(wc -c <"$work/stream.out")"
sleep 2
[ "$(wc -c <"$work/stream.out")" = "$before" ] || fail 'revoked established stream continued'
kill -0 "$stream_server" && kill -0 "$stream_client" || fail 'stream ended rather than being filtered'
# Removing both reply stages must expose the still-open stream.
ip netns exec "$server" nft flush chain inet ikev2_client_access output
ip netns exec "$server" nft flush chain inet ikev2_client_access postrouting
sleep 5
[ "$(wc -c <"$work/stream.out")" -gt "$before" ] || fail 'stream check could not detect absent reply guards'
apply 0x100 0x200 12 alice none
kill "$stream_client" "$stream_server" 2>/dev/null || :
# Replace the actual SAs and keys while retaining the same inner client address.
# The previous owner's authorization must not transfer to the new encrypted SA.
apply 0x100 0x200
for namespace in "$client" "$server"; do
	ip netns exec "$namespace" ip xfrm state flush
	ip netns exec "$namespace" ip xfrm policy flush
done
key="0x$(openssl rand -hex 20)"
configure "$client" 10.231.254.2 10.231.254.1 10.25.0.10 172.31.254.1 0x101 0x201 13
configure "$server" 10.231.254.1 10.231.254.2 172.31.254.1 10.25.0.10 0x201 0x101 13
[ -z "$(probe)" ] || fail 'reused VIP inherited an old owner grant'
apply 0x101 0x201 13 bob alice
[ -z "$(probe)" ] || fail 'new authenticated identity inherited another user assignment'
apply 0x101 0x201 13 bob bob
[ "$(probe)" = sa-binding-probe ] || fail 'new owner could not use its own assignment'
# Removing the generated guard must restore traffic otherwise denied by it.
apply 0x101 0x201 13 bob none
[ -z "$(probe)" ] || fail 'revocation did not deny the new owner'
ip netns exec "$server" nft delete table inet ikev2_client_access
[ "$(probe)" = sa-binding-probe ] || fail 'negative control could not detect an absent guard'
apply 0x101 0x201 13 bob bob
printf '%s\n' 'client access: generated SA-bound encrypted TCP/UDP, expiry, revocation and reused-VIP denial OK'
