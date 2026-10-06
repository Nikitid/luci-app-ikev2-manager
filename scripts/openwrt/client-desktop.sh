#!/bin/sh
# Disposable router for a complete desktop run: a real client on another machine
# enrolls over HTTPS, logs in with IKEv2 and reaches a selected service through
# the installed controller, its proxy and a required exit that is itself a real
# IKE SA to a namespace standing in for the far end. Needs a kernel with XFRM
# interfaces and a privileged container; /fixture holds a test TLS pair and
# hostname. Nothing here is a credential of any real system.
set -eu
umask 077
exit_ns=desktop-exit
hostname="$(cat /fixture/hostname)"
mkdir -p /etc/ikev2-manager/clients /etc/ikev2-manager/native-tls /etc/swanctl/conf.d /etc/swanctl/x509 /etc/swanctl/private
chmod 700 /etc/ikev2-manager/clients /etc/ikev2-manager/native-tls
cp /fixture/cert.pem /etc/ikev2-manager/native-tls/cert.pem
cp /fixture/key.pem /etc/ikev2-manager/native-tls/key.pem
cp /fixture/cert.pem /etc/swanctl/x509/native-server.pem
cp /fixture/key.pem /etc/swanctl/private/native-server.key
chmod 600 /etc/ikev2-manager/native-tls/*.pem /etc/swanctl/private/native-server.key
cat >/etc/strongswan.conf <<'CONF'
charon {
 load_modular = no
 load = des md4 openssl gmp random nonce aes sha2 hmac gcm pem x509 pkcs1 pubkey constraints kdf eap-identity eap-mschapv2 kernel-netlink socket-default vici
 install_routes = no
 filelog { native {
  path = /fixture/ike-daemon.log
  default = 1
  flush_line = yes
 } }
}
CONF
printf 'include conf.d/*.conf\n' >/etc/swanctl/swanctl.conf
secret="$(openssl rand -hex 24)"
cat >/etc/swanctl/conf.d/desktop.conf <<CONF
connections {
 ikev2-in {
  version = 2
  local_addrs = %any
  proposals = aes256-sha256-modp2048
  pools = native-clients
  local { auth = pubkey
   certs = native-server.pem
   id = $hostname
  }
  remote { auth = eap-mschapv2
   eap_id = %any
  }
  children { net {
   local_ts = 172.31.254.0/24
   esp_proposals = aes256-sha256-modp2048
   if_id_in = 43
   if_id_out = 43
  } }
 }
 proxy-out {
  version = 2
  local_addrs = 10.233.254.1
  remote_addrs = 10.233.254.2
  proposals = aes256gcm16-prfsha384-ecp384
  local { auth = psk
   id = router.test
  }
  remote { auth = psk
   id = exit.test
  }
  children { proxy4 {
   local_ts = 10.26.0.10/32
   remote_ts = 0.0.0.0/0
   esp_proposals = aes256gcm16-ecp384
   if_id_in = 42
   if_id_out = 42
  } }
 }
}
pools { native-clients { addrs = 10.239.250.10 } }
secrets { ike-path { id-1 = router.test
 id-2 = exit.test
 secret = "$secret"
} }
CONF

# The far end: its own daemon, the service and the resolver the exit serves.
ip netns add "$exit_ns"
mkdir -p /tmp/exit-run "/etc/netns/$exit_ns/swanctl"
cat >"/etc/netns/$exit_ns/strongswan.conf" <<'CONF'
charon {
 load_modular = no
 load = openssl gmp random nonce aes sha2 hmac gcm kdf kernel-netlink socket-default vici
 install_routes = no
}
CONF
cat >"/etc/netns/$exit_ns/swanctl/swanctl.conf" <<CONF
connections {
 exit {
  version = 2
  local_addrs = 10.233.254.2
  proposals = aes256gcm16-prfsha384-ecp384
  local { auth = psk
   id = exit.test
  }
  remote { auth = psk
   id = router.test
  }
  children { proxy4 {
   local_ts = 0.0.0.0/0
   remote_ts = 10.26.0.10/32
   esp_proposals = aes256gcm16-ecp384
   if_id_in = 42
   if_id_out = 42
  } }
 }
}
secrets { ike-path { id-1 = router.test
 id-2 = exit.test
 secret = "$secret"
} }
CONF
unset secret
far() {
	ip netns exec "$exit_ns" sh -c 'mount -o bind /tmp/exit-run /tmp/run || exit 1; exec "$@"' sh "$@"
}
ip -n "$exit_ns" link set lo up
ip link add exit-transit type veth peer name exit-peer netns "$exit_ns"
ip addr add 10.233.254.1/24 dev exit-transit
ip -n "$exit_ns" addr add 10.233.254.2/24 dev exit-peer
ip link set exit-transit up
ip -n "$exit_ns" link set exit-peer up
ip link add ipsec-in type xfrm dev lo if_id 43
ip link set ipsec-in up
ip route add 10.239.250.10/32 dev ipsec-in
ip link add ipsec-out type xfrm dev lo if_id 42
ip -n "$exit_ns" link add ipsec-out type xfrm dev lo if_id 42
ip link set ipsec-out up
ip -n "$exit_ns" link set ipsec-out up
ip addr add 10.26.0.10/32 dev ipsec-out
ip -n "$exit_ns" addr add 192.0.2.9/32 dev lo
ip -n "$exit_ns" addr add 192.0.2.53/32 dev lo
ip -n "$exit_ns" route add 10.26.0.10/32 dev ipsec-out
# A direct route to the service exists on purpose: traffic that escaped the
# required exit would arrive, and the counters below would show it.
ip route add 192.0.2.0/24 via 10.233.254.2
ip route add default dev ipsec-out src 10.26.0.10 table 1550
ip rule add oif ipsec-out lookup 1550 priority 10990
ip rule add from 10.26.0.10/32 lookup 1550 priority 10991
sysctl -q -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.ipsec-out.rp_filter=0 net.ipv4.conf.ipsec-in.rp_filter=0

uci set ikev2-manager.globals.configured=0
uci set ikev2-manager.server.enabled=1
uci set "ikev2-manager.server.identity=$hostname"
uci set ikev2-manager.server.pool4=10.239.250.10-10.239.250.10
uci set ikev2-manager.server.cert_file=/etc/ikev2-manager/native-tls/cert.pem
uci set ikev2-manager.server.key_file=/etc/ikev2-manager/native-tls/key.pem
uci set ikev2-manager.client=client
uci set ikev2-manager.client.enabled=1
uci set ikev2-manager.client.tunnel_dns_bootstrap=192.0.2.53:53
uci set ikev2-manager.client_access.enabled=1
uci set ikev2-manager.client_access.port=8443
uci commit ikev2-manager

/usr/lib/ipsec/charon >/fixture/charon.log 2>&1 &
far /usr/lib/ipsec/charon >/fixture/exit-charon.log 2>&1 &
i=0
until swanctl --stats >/dev/null 2>&1 && far swanctl --stats >/dev/null 2>&1; do
	i=$((i + 1)); [ "$i" -lt 20 ] || { printf '%s\n' 'client-desktop: daemons did not start' >&2; exit 1; }
	sleep 1
done
swanctl --load-all >/fixture/load-ike.log 2>&1
far swanctl --load-all >/fixture/load-exit.log 2>&1
swanctl --initiate --child proxy4 >/fixture/exit-login.log 2>&1 || { printf '%s\n' 'client-desktop: required exit login failed' >&2; exit 1; }
# The exit watcher's verdict, as the installed watcher would have written it.
printf 'exit 1 1\n' >/var/run/ikev2-tunnels.state

ip netns exec "$exit_ns" nft -f - <<'NFT'
table inet path_evidence {
 counter encrypted_service { }
 counter direct_service { }
 counter encrypted_dns { }
 counter direct_dns { }
 chain input {
  type filter hook input priority 0;
  iifname "ipsec-out" meta l4proto { tcp, udp } th dport { 4443, 4444 } counter name encrypted_service
  iifname "exit-peer" meta l4proto { tcp, udp } th dport { 4443, 4444 } counter name direct_service
  iifname "ipsec-out" tcp dport 53 counter name encrypted_dns
  iifname "exit-peer" tcp dport 53 counter name direct_dns
 }
}
NFT
ip netns exec "$exit_ns" socat TCP4-LISTEN:4443,bind=192.0.2.9,reuseaddr,fork EXEC:/bin/cat >/dev/null 2>&1 &
ip netns exec "$exit_ns" socat TCP4-LISTEN:4446,bind=192.0.2.9,reuseaddr,fork EXEC:/bin/cat >/dev/null 2>&1 &
ip netns exec "$exit_ns" socat -T 2 UDP4-RECVFROM:4444,bind=192.0.2.9,reuseaddr,fork PIPE >/dev/null 2>&1 &
ip netns exec "$exit_ns" dnsmasq --keep-in-foreground --no-resolv --no-hosts --bind-interfaces --listen-address=192.0.2.53 \
	--address=/api.example.com/192.0.2.9 --pid-file=/tmp/exit-run/dnsmasq.pid >/dev/null 2>&1 &

ucode /src/scripts/openwrt/client-runtime-state.uc /etc/ikev2-manager/clients seed unused "$hostname"
ucode -e 'import {read_client_state} from "/usr/libexec/ikev2-manager.d/client-access-store.uc"; let s=read_client_state("/etc/ikev2-manager/clients"); print(sprintf("%J",{version:1,expected_generation:0,endpoint:"https://"+s.publication.server.address+":19443/client/v1/enroll",id:"native-laptop",selected_services:["api"],lifetime_seconds:600}));' >/fixture/request.json
ucode /usr/libexec/ikev2-manager.d/client-access-invitation-control.uc issue </fixture/request.json >/fixture/invitation.json
/usr/libexec/ikev2-client-api serve >/fixture/api.log 2>&1 &
# The installed controller, started the way procd starts it.
/usr/libexec/ikev2-client-access watch >/fixture/controller.log 2>&1 &
i=0
until curl -sk --max-time 2 https://127.0.0.1:8443/ >/dev/null; do
	i=$((i + 1)); [ "$i" -lt 20 ] || { printf '%s\n' 'client-desktop: device API did not start' >&2; exit 1; }
	sleep 1
done
printf '%s\n' 'READY_NATIVE_ROUTER'
wait
