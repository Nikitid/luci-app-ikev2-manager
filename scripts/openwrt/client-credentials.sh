#!/bin/sh
# Actual UCI/user transaction and VICI credential loading in a disposable rootfs.
set -eu
umask 077
work="$(mktemp -d)"
daemon=''
cleanup() {
	[ -z "$daemon" ] || { kill "$daemon" 2>/dev/null || :; wait "$daemon" 2>/dev/null || :; }
	rm -rf "$work" /etc/ikev2-manager/clients
}
trap cleanup EXIT INT TERM
cat >/etc/strongswan.conf <<'CONF'
charon {
 load_modular = no
 load = random nonce openssl kernel-netlink socket-default vici
 install_routes = no
}
CONF
mkdir -p /etc/swanctl/conf.d /etc/ikev2-manager/clients
chmod 700 /etc/ikev2-manager/clients
printf 'include conf.d/*.conf\n' >/etc/swanctl/swanctl.conf
# This fixture tests staging/loading while the gateway is not activated. It
# does not claim an operational inbound path or working desktop protection.
uci set ikev2-manager.globals.configured=0
uci commit ikev2-manager
start_daemon() {
	/usr/lib/ipsec/charon >"$work/charon.log" 2>&1 &
	daemon=$!
	i=0
	until swanctl --list-algs >/dev/null 2>&1; do
		i=$((i + 1)); [ "$i" -lt 15 ] || exit 1
		sleep 1
	done
}
start_daemon
printf 'add\nunrelated\ncredential-fixture-password\n' >/var/run/ikev2-manager-user-credential-fixture.in
chmod 600 /var/run/ikev2-manager-user-credential-fixture.in
/usr/libexec/ikev2-manager user-secret-set credential-fixture >/dev/null 2>&1
ucode /src/scripts/openwrt/client-runtime-state.uc /etc/ikev2-manager/clients seed
ucode /src/scripts/openwrt/client-credentials.uc prepare
IKEV2_ROOT=/tmp/untrusted IKEV2_USER_INPUT=/tmp/untrusted-input \
	STRONGSWAN_CONF=/tmp/untrusted-conf SWANCTL_DIR=/tmp/untrusted-swanctl \
	ucode /src/scripts/openwrt/client-credentials.uc provision
ucode /src/scripts/openwrt/client-credentials.uc retry
kill "$daemon"
wait "$daemon" 2>/dev/null || :
daemon=''
ucode /src/scripts/openwrt/client-credentials.uc offline
start_daemon
ucode /src/scripts/openwrt/client-credentials.uc retry
ucode /src/scripts/openwrt/client-credentials.uc safety
sh /src/scripts/openwrt/client-users-lock.sh "$daemon"
ucode /src/scripts/openwrt/client-credentials.uc cleanup
sh /src/scripts/openwrt/client-enrollment-http.sh
printf '%s\n' 'client-credentials: real strongSwan staging, retry, offline refusal and ownership checks PASS'
