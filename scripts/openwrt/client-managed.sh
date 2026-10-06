#!/bin/sh
# The inbound server as the product renders it, with managed desktop access set
# up: a peer that names itself in the managed domain is offered the virtual
# subnet alone, any other peer the configured networks. Real IKEv2 between this
# container and a namespace; needs XFRM interfaces for the server's link.
set -eu
umask 077
work="$(mktemp -d /tmp/ikev2-client-managed.XXXXXX)"
peer="ikev2-managed-peer-$$"
fail() { printf 'client-managed: %s\n' "$*" >&2; exit 1; }
cleanup() {
	for process in $(ip netns pids "$peer" 2>/dev/null); do kill "$process" 2>/dev/null || :; done
	ip netns del "$peer" 2>/dev/null || :
	rm -rf "/etc/netns/$peer" "$work"
	[ -z "${charon_pid:-}" ] || kill "$charon_pid" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 1' INT TERM
cat >/etc/strongswan.conf <<'CONF'
charon {
 load_modular = no
 load = des md4 openssl gmp random nonce aes sha2 hmac gcm pem x509 pkcs1 pubkey constraints kdf eap-identity eap-mschapv2 kernel-netlink socket-default vici
 install_routes = no
}
CONF
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -days 2 -subj '/CN=Managed Test CA' -keyout "$work/ca.key" -out "$work/ca.pem" >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -subj '/CN=vpn.example.com' -keyout "$work/server.key" -out "$work/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:vpn.example.com\nextendedKeyUsage=serverAuth\n' >"$work/server.ext"
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" -CAcreateserial -days 2 -extfile "$work/server.ext" -out "$work/server.pem" >/dev/null 2>&1
cat "$work/server.pem" "$work/ca.pem" >"$work/chain.pem"
mkdir -p /etc/ikev2-manager/test-server
cp "$work/chain.pem" /etc/ikev2-manager/test-server/cert.pem
cp "$work/server.key" /etc/ikev2-manager/test-server/key.pem
uci set ikev2-manager.server.enabled=1
uci set ikev2-manager.server.identity=vpn.example.com
uci set ikev2-manager.server.pool4=10.25.0.10-10.25.0.20
uci set ikev2-manager.server.local_ts=0.0.0.0/0
uci set ikev2-manager.server.cert_file=/etc/ikev2-manager/test-server/cert.pem
uci set ikev2-manager.server.key_file=/etc/ikev2-manager/test-server/key.pem
uci commit ikev2-manager
password="$(openssl rand -hex 24)"
mkdir -p /etc/swanctl/conf.d
cat >/etc/swanctl/conf.d/99-test-account.conf <<CONF
secrets { eap-test { id = alice
 secret = "$password"
} }
CONF
/usr/lib/ipsec/charon >"$work/server.log" 2>&1 &
charon_pid=$!
i=0
until swanctl --stats >/dev/null 2>&1; do
	i=$((i + 1)); [ "$i" -lt 15 ] || fail 'the daemon did not start'
	sleep 1
done
/usr/libexec/ikev2-manager server-ensure >"$work/ensure.log" 2>&1 || fail "the product could not bring its server up: $(tail -n 2 "$work/ensure.log")"
swanctl --list-conns | grep -q '^ikev2-in:' || fail 'the inbound connection is not loaded'
if swanctl --list-conns | grep -q '^ikev2-in-managed:'; then fail 'a managed connection exists before access is set up'; fi

# Setting access up publishes the virtual subnet; the server follows on ensure.
mkdir -m 700 -p /etc/ikev2-manager/clients
ucode /src/scripts/openwrt/client-runtime-state.uc /etc/ikev2-manager/clients seed-empty
/usr/libexec/ikev2-manager server-ensure >"$work/ensure.log" 2>&1 || fail 'the product could not add the managed connection'
swanctl --list-conns | grep -q '^ikev2-in-managed:' || fail 'the managed connection was not loaded after setup'

ip netns add "$peer"
mkdir -p "$work/run" "/etc/netns/$peer/swanctl/x509ca"
cp /etc/strongswan.conf "/etc/netns/$peer/strongswan.conf"
cp "$work/ca.pem" "/etc/netns/$peer/swanctl/x509ca/ca.pem"
ip -n "$peer" link set lo up
ip link add managed-transit type veth peer name transit netns "$peer"
ip addr add 10.232.253.1/24 dev managed-transit
ip -n "$peer" addr add 10.232.253.2/24 dev transit
ip link set managed-transit up
ip -n "$peer" link set transit up
connection() {
	cat <<CONF
 $1 {
  version = 2
  local_addrs = 10.232.253.2
  remote_addrs = 10.232.253.1
  vips = 0.0.0.0
  proposals = aes256gcm16-prfsha384-ecp384
  local { auth = eap-mschapv2
   id = $2
   eap_id = alice
  }
  remote { auth = pubkey
   id = vpn.example.com
  }
  children { net {
   local_ts = dynamic
   remote_ts = 0.0.0.0/0
   esp_proposals = aes256gcm16-ecp384
  } }
 }
CONF
}
{
	printf 'connections {\n'
	connection managed alice@managed.ikev2-manager
	connection plain alice
	printf '}\nsecrets { eap-test { id = alice\n secret = "%s"\n} }\n' "$password"
} >"/etc/netns/$peer/swanctl/swanctl.conf"
unset password
far() {
	ip netns exec "$peer" sh -c 'mount -o bind "$1" /tmp/run || exit 1; shift; exec "$@"' sh "$work/run" "$@"
}
far /usr/lib/ipsec/charon >"$work/peer.log" 2>&1 &
i=0
until far swanctl --stats >/dev/null 2>&1; do
	i=$((i + 1)); [ "$i" -lt 15 ] || fail 'the peer daemon did not start'
	sleep 1
done
far swanctl --load-all >"$work/peer-load.log" 2>&1 || fail 'the peer configuration did not load'

offered() { swanctl --list-sas | sed -n "/^$1:/,/^[a-z]/p" | sed -n 's/^ *local  *\([0-9./ ]*\)$/\1/p' | head -n 1; }
far swanctl --initiate --child net --ike managed >"$work/managed.log" 2>&1 || fail 'a managed peer could not log in'
swanctl --list-sas | grep -q '^ikev2-in-managed:' || fail 'a managed peer was not answered by the managed connection'
[ "$(offered ikev2-in-managed)" = 172.31.254.0/24 ] || fail "a managed peer was offered $(offered ikev2-in-managed)"
far swanctl --list-sas | grep -q 'remote  *172.31.254.0/24' || fail 'the managed peer did not receive the narrowed networks'
# The admission reader sees it as the same account on the same server.
swanmon list-sas >"$work/sas.json"
ucode /usr/libexec/ikev2-manager.d/client-access-policy.uc sessions <"$work/sas.json" >"$work/sessions.json" || fail 'the session reader refused the managed connection'
[ "$(jsonfilter -i "$work/sessions.json" -e '@[0].identity')" = alice ] || fail 'the managed session was not read as its account'
far swanctl --terminate --ike managed >/dev/null 2>&1 || fail 'the managed peer could not log out'

far swanctl --initiate --child net --ike plain >"$work/plain.log" 2>&1 || fail 'an ordinary peer could not log in'
swanctl --list-sas | grep -q '^ikev2-in:' || fail 'an ordinary peer was not answered by the ordinary connection'
[ "$(offered ikev2-in)" = 0.0.0.0/0 ] || fail "an ordinary peer was offered $(offered ikev2-in)"
far swanctl --terminate --ike plain >/dev/null 2>&1 || :
printf '%s\n' 'client-managed: the rendered server offers managed peers the virtual subnet alone and ordinary peers the configured networks'
