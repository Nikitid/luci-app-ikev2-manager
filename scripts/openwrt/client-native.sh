#!/bin/sh
# Disposable router for a native desktop HTTPS enrollment integration run.
# /fixture is a private host directory containing a test TLS pair and hostname.
set -eu
umask 077
mkdir -p /etc/ikev2-manager/clients /etc/ikev2-manager/native-tls /etc/swanctl/conf.d
chmod 700 /etc/ikev2-manager/clients /etc/ikev2-manager/native-tls
cp /fixture/cert.pem /etc/ikev2-manager/native-tls/cert.pem
cp /fixture/key.pem /etc/ikev2-manager/native-tls/key.pem
chmod 600 /etc/ikev2-manager/native-tls/*.pem
hostname="$(cat /fixture/hostname)"
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
if [ -f /fixture/enable-ike ]; then
 mkdir -p /etc/swanctl/x509 /etc/swanctl/private
 cp /fixture/cert.pem /etc/swanctl/x509/native-server.pem
 cp /fixture/key.pem /etc/swanctl/private/native-server.key
 chmod 600 /etc/swanctl/private/native-server.key
 cat >/etc/swanctl/conf.d/native-server.conf <<CONF
connections {
 native-server {
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
  } }
 }
}
pools { native-clients { addrs = 10.239.250.10 } }
CONF
 ip address add 172.31.254.1/32 dev lo
fi
uci set ikev2-manager.globals.configured=0
uci set ikev2-manager.server.enabled=1
uci set "ikev2-manager.server.identity=$hostname"
uci set ikev2-manager.server.cert_file=/etc/ikev2-manager/native-tls/cert.pem
uci set ikev2-manager.server.key_file=/etc/ikev2-manager/native-tls/key.pem
uci set ikev2-manager.client_access.enabled=1
uci set ikev2-manager.client_access.port=8443
uci commit ikev2-manager
/usr/lib/ipsec/charon >/fixture/charon.log 2>&1 &
charon=$!
api=''
cleanup() {
 [ -z "$api" ] || { kill "$api" 2>/dev/null || :; wait "$api" 2>/dev/null || :; }
 kill "$charon" 2>/dev/null || :
 wait "$charon" 2>/dev/null || :
}
trap cleanup EXIT INT TERM
i=0
until swanctl --list-algs >/dev/null 2>&1; do
 i=$((i + 1)); [ "$i" -lt 20 ] || exit 1
 sleep 1
done
if [ -f /fixture/enable-ike ]; then
 swanctl --load-all >/fixture/load-ike.log 2>&1
fi
ucode /src/scripts/openwrt/client-runtime-state.uc /etc/ikev2-manager/clients seed unused "$hostname"
ucode -e 'import {read_client_state} from "/usr/libexec/ikev2-manager.d/client-access-store.uc"; let s=read_client_state("/etc/ikev2-manager/clients"); print(sprintf("%J",{version:1,expected_generation:0,endpoint:"https://"+s.publication.server.address+":19443/client/v1/enroll",id:"native-laptop",selected_services:["api"],lifetime_seconds:600}));' >/fixture/request.json
ucode /usr/libexec/ikev2-manager.d/client-access-invitation-control.uc issue </fixture/request.json >/fixture/invitation.json
/usr/libexec/ikev2-client-api serve >/fixture/api.log 2>&1 &
api=$!
i=0
until curl -sk --max-time 2 https://127.0.0.1:8443/ >/dev/null; do
 i=$((i + 1)); [ "$i" -lt 20 ] || exit 1
 sleep 1
done
printf '%s\n' 'READY_NATIVE_ROUTER'
wait "$api"
