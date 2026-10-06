#!/bin/sh
# Real EAP login and admission in disposable namespaces. No root VPN changes.
set -eu
umask 077
ulimit -c 0
work="$(mktemp -d /tmp/ikev2-client-ike.XXXXXX)"
client="ikev2-auth-client-$$"
server="ikev2-auth-server-$$"
lib="${CLIENT_ACCESS_RUNTIME_LIB:-/usr/libexec/ikev2-manager.d}"
helper="${CLIENT_ACCESS_HELPER:-/usr/libexec/ikev2-client-access}"
fixture="${CLIENT_ACCESS_RUNTIME_FIXTURE:-/tests/client-runtime-state.uc}"
. "$lib/package-manager.sh"
created=''
root_pid="$(cat /var/run/charon.pid 2>/dev/null || :)"
cleanup() {
	for namespace in $created; do
		for process in $(ip netns pids "$namespace" 2>/dev/null); do kill "$process" 2>/dev/null || :; done
		ip netns del "$namespace" 2>/dev/null || :
		rm -rf "/etc/netns/$namespace"
	done
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
fail() {
 printf 'client-ike: %s\n' "$*" >&2
 if [ -f "$work/proxy.log" ]; then
  tail -n 30 "$work/proxy.log" >&2
  tail -n 10 "$work/exit-echo.log" >&2
  ip netns exec "$server" nft list table inet ikev2_client_path >&2 2>/dev/null || :
  ip netns exec "$server" nft list table inet ikev2_client_access >&2 2>/dev/null || :
  ip netns exec "$path_exit" nft list table inet path_evidence >&2 2>/dev/null || :
 fi
 # Fixed diagnostic phrases only; never emit identities or generated secrets.
 for log in "$work/login.log" "$work/$server/daemon.log" "$work/$client/daemon.log"; do
  [ -f "$log" ] || continue
  grep -oE 'loaded plugins:.*|algorithm.*|EAP-MS-CHAPv2.*|EAP method.*|loading EAP.*|failed to.*|unable to.*|AUTHENTICATION_FAILED|NO_PROPOSAL_CHOSEN|TS_UNACCEPTABLE|authentication failed|no EAP key found|no shared key found|no trusted RSA public key found|no trusted ECDSA public key found|no issuer certificate found|no private key found|EAP method not supported|no socket implementation registered|maximum number of retransmits reached|unable to resolve|failed to establish CHILD_SA|not found|EAP_MSCHAPV2|EAP_IDENTITY|established successfully' "$log" >&2 || :
 done
 exit 1
}
# ip netns exec gives each command a private slave mount namespace. Bind only
# the disposable daemon run directory; swanmon then reads the real local VICI.
role() {
	local namespace="$1"; shift
	ip netns exec "$namespace" sh -c '
		mount -o bind "$1" /tmp/run || exit 1
		shift
		exec "$@"
	' sh "$work/$namespace/run" "$@"
}
for namespace in "$client" "$server"; do
	[ ! -e "/etc/netns/$namespace" ] || fail 'namespace configuration already exists'
	ip netns add "$namespace"
	created="$created $namespace"
	mkdir -p "$work/$namespace/run" "/etc/netns/$namespace/swanctl/x509" "/etc/netns/$namespace/swanctl/x509ca" "/etc/netns/$namespace/swanctl/private"
	cat >"/etc/netns/$namespace/strongswan.conf" <<'CONF'
charon {
 load_modular = no
 load = des md4 openssl gmp random nonce aes sha2 hmac gcm pem x509 pkcs1 pubkey constraints kdf eap-identity eap-mschapv2 kernel-netlink socket-default vici
 install_routes = no
}
CONF
	ip -n "$namespace" link set lo up
	ip -n "$namespace" link add ipsec-in type xfrm dev lo if_id 43
	ip -n "$namespace" link set ipsec-in up
done
ip netns exec "$client" ip link add transit type veth peer name transit-peer netns "$server"
ip -n "$client" addr add 10.232.254.2/24 dev transit
ip -n "$server" addr add 10.232.254.1/24 dev transit-peer
ip -n "$client" link set transit up
ip -n "$server" link set transit-peer up
ip -n "$server" addr add 172.31.254.1/32 dev lo
ip -n "$server" route add 10.25.0.10/32 dev ipsec-in
ip -n "$client" route add 172.31.254.0/24 dev ipsec-in
password="$(openssl rand -hex 24)"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -days 2 -subj '/CN=Client Test CA' -keyout "$work/ca.key" -out "$work/ca.pem" >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -subj '/CN=vpn.example.com' -keyout "/etc/netns/$server/swanctl/private/server.key" -out "$work/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:vpn.example.com\nextendedKeyUsage=serverAuth\n' >"$work/server.ext"
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" -CAcreateserial -days 2 -extfile "$work/server.ext" -out "/etc/netns/$server/swanctl/x509/server.pem" >/dev/null 2>&1
cp "$work/ca.pem" "/etc/netns/$client/swanctl/x509ca/ca.pem"
cat >"/etc/netns/$server/swanctl/swanctl.conf" <<CONF
connections {
 ikev2-in {
  version = 2
  local_addrs = 10.232.254.1
  proposals = aes256gcm16-prfsha384-ecp384
  pools = clients
  local { auth = pubkey
   certs = server.pem
   id = vpn.example.com
  }
  remote { auth = eap-mschapv2
   eap_id = %any
  }
  children { net {
   local_ts = 172.31.254.0/24
   esp_proposals = aes256gcm16-ecp384
   if_id_in = 43
   if_id_out = 43
  } }
 }
}
pools { clients { addrs = 10.25.0.10 } }
secrets { eap-alice { id = alice
 secret = "$password"
} }
CONF
cat >"/etc/netns/$client/swanctl/swanctl.conf" <<CONF
connections {
 office {
  version = 2
  local_addrs = 10.232.254.2
  remote_addrs = 10.232.254.1
  vips = 0.0.0.0
  proposals = aes256gcm16-prfsha384-ecp384
  local { auth = eap-mschapv2
   id = alice
   eap_id = alice
  }
  remote { auth = pubkey
   id = vpn.example.com
  }
  children { net {
   local_ts = dynamic
   remote_ts = 172.31.254.0/24
   esp_proposals = aes256gcm16-ecp384
   if_id_in = 43
   if_id_out = 43
  } }
 }
}
secrets { eap-alice { id = alice
 secret = "$password"
} }
CONF
unset password
for namespace in "$server" "$client"; do
	role "$namespace" /usr/lib/ipsec/charon >"$work/$namespace/daemon.log" 2>&1 &
	i=0
	until role "$namespace" swanctl --stats >/dev/null 2>&1; do
		i=$((i + 1)); [ "$i" -lt 15 ] || fail 'isolated daemon startup failed'
		sleep 1
	done
	role "$namespace" swanctl --load-all >"$work/$namespace/load.log" 2>&1 || fail 'isolated configuration load failed'
done
pkg_run_bounded 25 role "$client" swanctl --initiate --child net >"$work/login.log" 2>&1 || fail 'certificate-validated EAP login failed'
ip -n "$client" route replace 172.31.254.0/24 dev ipsec-in src 10.25.0.10
role "$server" swanmon list-sas >"$work/sessions.json" || fail 'real VICI read failed'
mkdir -m 700 "$work/state"
ucode "$fixture" "$work/state" seed
cat >"$work/uci" <<'UCI'
#!/bin/sh
case "$*" in
 '-q get ikev2-manager.server.enabled') echo 1 ;;
 '-q get ikev2-manager.server.pool4') echo 10.25.0.10-10.25.0.10 ;;
 *) exit 1 ;;
esac
UCI
chmod 700 "$work/uci"
# A test copy keeps the production invocation's environment sanitization intact.
cp "$helper" "$work/helper.sh"
path_required=0
path_auto=0
controller() {
	role "$server" env IKEV2_CLIENT_AUTO_PATH="$path_auto" IKEV2_TUNNEL_STATE="$work/tunnels.state" IKEV2_CLIENT_REQUIRE_PATH="$path_required" IKEV2_RUNTIME_LIB_DIR="$lib" IKEV2_CLIENT_STATE_DIR="$work/state" IKEV2_CLIENT_RUNTIME_DIR="$work/runtime" IKEV2_UCI_BIN="$work/uci" sh "$work/helper.sh" "$1"
}
controller sync || fail 'controller rejected real authenticated session'
grep -q '^grants=[1-9]' "$work/runtime/status" || fail 'real EAP session produced no grants'
ip netns exec "$server" socat TCP4-LISTEN:4443,bind=172.31.254.1,reuseaddr,fork EXEC:/bin/cat >"$work/echo.log" 2>&1 &
ip netns exec "$server" socat -T 2 UDP4-RECVFROM:4444,bind=172.31.254.1,reuseaddr,fork PIPE >"$work/udp.log" 2>&1 &
ip netns exec "$server" socat TCP4-LISTEN:4446,bind=172.31.254.1,reuseaddr,fork EXEC:/bin/cat >"$work/unselected.log" 2>&1 &
sleep 1
probe() {
	printf 'authenticated-path\n' | ip netns exec "$client" socat -T 2 - TCP4:172.31.254.1:${1:-4443},connect-timeout=2,shut-none 2>/dev/null
}
udp_probe() {
 printf 'authenticated-udp\n' | ip netns exec "$client" socat -T 2 - UDP4:172.31.254.1:4444,shut-none 2>/dev/null
}
[ "$(probe)" = authenticated-path ] || fail 'authenticated encrypted TCP path failed'
[ "$(udp_probe)" = authenticated-udp ] || fail 'authenticated encrypted UDP path failed'
[ -z "$(probe 4446 || :)" ] || fail 'unselected service port admitted' 
ucode "$fixture" "$work/state" revoke
controller sync || fail 'revocation reconciliation failed'
[ -z "$(probe || :)" ] || fail 'revoked authenticated client retained access'
[ -z "$(udp_probe || :)" ] || fail 'revoked authenticated client retained UDP access' 
ucode "$fixture" "$work/state" enable
controller sync || fail 'restored assignment reconciliation failed'
[ "$(probe)" = authenticated-path ] || fail 'restored encrypted TCP path failed'
[ "$(udp_probe)" = authenticated-udp ] || fail 'restored encrypted UDP path failed' 
if [ "${CLIENT_ACCESS_TEST_PATH:-0}" = 1 ]; then
	# shellcheck disable=SC1090
	. "${CLIENT_ACCESS_PATH_SCENARIO:-/src/scripts/openwrt/client-path.sh}"
fi
pkg_run_bounded 10 role "$client" swanctl --terminate --ike office >"$work/terminate.log" 2>&1 || fail 'isolated session termination failed'
controller sync || fail 'disconnected reconciliation failed'
grep -q '^grants=0$' "$work/runtime/status" || fail 'disconnected client retained grants'
[ -z "$root_pid" ] || {
 [ "$(cat /var/run/charon.pid 2>/dev/null)" = "$root_pid" ] && kill -0 "$root_pid" || fail 'working daemon changed'
}
printf '%s\n' 'client-ike: real certificate/EAP login, VICI admission, encrypted TCP/UDP, selected ports, revocation and disconnect passed'
