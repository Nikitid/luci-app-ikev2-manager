#!/bin/sh

# Runs inside an OpenWrt rootfs container (see scripts/luci-stand.sh): installs
# LuCI and the package from this tree, starts ubusd, rpcd and uhttpd without
# procd, and fills the router with synthetic data.
#
#   container.sh up           install and start (once per container)
#   container.sh mode NAME    first-run | empty | vpn-only | full | error
#   container.sh delay MS     hold every helper call back by MS milliseconds
#   container.sh lang NAME    auto | en | ru; the pages' own catalog, not LuCI's
#
# The stand never carries a real name, address or credential. The login is
# root with the test password below, valid only inside this container.

set -eu

state=/tmp/stand
password=stand-test
sock=/var/run/ubus/ubus.sock
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

# Every helper LuCI may execute is read through a wrapper, so a mode that
# fails or slows the router needs no change to the page or to the helper.
helpers='/usr/libexec/ikev2-devices /usr/libexec/ikev2-device-routing
	/usr/libexec/ikev2-domains-community /usr/libexec/ikev2-domain-router
	/usr/libexec/ikev2-manager /usr/libexec/ikev2-manager-system
	/usr/libexec/ikev2-tunnel-quality /usr/libexec/ikev2-client-admin'

install_all() {
	mkdir -p /var/lock /var/run /tmp/run /var/run/ubus /tmp/ipk /tmp/luci-sessions "$state"
	apk update >/dev/null 2>&1 || apk update >/dev/null
	apk add luci-light luci-theme-bootstrap uhttpd uhttpd-mod-ubus uhttpd-mod-ucode \
		rpcd rpcd-mod-file rpcd-mod-luci rpcd-mod-rpcsys ucode-mod-uloop \
		ip-full ucode-mod-fs ucode-mod-digest socat sing-box openssl-util >/dev/null
	# The IPK carries the same files as the APK, unpacked here without scripts.
	tar -xzf /src/dist/*.ipk -C /tmp/ipk
	tar -xzf /tmp/ipk/data.tar.gz -C /
	# Theme and module defaults that the init system applies at first boot.
	for f in /etc/uci-defaults/*; do
		[ -f "$f" ] || continue
		# shellcheck disable=SC1090
		(. "$f") >/dev/null 2>&1 || true
		rm -f "$f"
	done
	printf '%s\n%s\n' "$password" "$password" | passwd root >/dev/null 2>&1
	for h in $helpers; do
		[ -x "$h" ] || continue
		[ -e "$h.real" ] || mv "$h" "$h.real"
		cat >"$h" <<WRAP
#!/bin/sh
# luci-stand wrapper: delay and failure modes in front of the real helper.
ms=\$(cat $state/delay 2>/dev/null || echo 0)
# BusyBox sleep takes whole seconds; a fraction fails and would not delay at all.
[ "\$ms" = 0 ] || sleep "\$(((ms + 999) / 1000))"
if [ "\$(cat $state/mode 2>/dev/null)" = error ]; then
	echo 'stand: injected failure' >&2
	exit 1
fi
exec $h.real "\$@"
WRAP
		chmod 0755 "$h"
	done
}

start_daemons() {
	ubusd -s "$sock" </dev/null >/dev/null 2>&1 &
	sleep 1
	rpcd -s "$sock" </dev/null >/dev/null 2>&1 &
	ucode "$here/ubus-shim.uc" </dev/null >/tmp/ubus-shim.log 2>&1 &
	uhttpd -f -h /www -r OpenWrt -x /cgi-bin -u /ubus -U "$sock" -p 0.0.0.0:80 \
		-o /cgi-bin/luci -O /usr/share/ucode/luci/uhttpd.uc -t 60 </dev/null >/tmp/uhttpd.log 2>&1 &
}

# What a real router has and the rootfs does not: the logical networks that
# ubus-shim.uc reports and that the helpers look up in UCI.
seed_network() {
	uci -q delete network.lan || true
	uci -q delete network.wan || true
	[ -e /etc/config/network ] || : >/etc/config/network
	uci set network.lan=interface
	uci set network.lan.proto=static
	uci set network.lan.device=br-lan
	uci set network.lan.ipaddr=10.99.0.1
	uci set network.lan.netmask=255.255.255.0
	uci set network.wan=interface
	uci set network.wan.proto=static
	uci set network.wan.device=eth0
	uci set network.wan.ipaddr=203.0.113.2
	uci set network.wan.netmask=255.255.255.0
	uci commit network
	# Neighbours for the device list; a link of its own leaves the container's
	# real interface alone.
	ip link add br-lan type dummy 2>/dev/null || true
	ip link set br-lan up
	ip address add 10.99.0.1/24 dev br-lan 2>/dev/null || true
	for last in 10 11 12; do
		ip neigh replace "10.99.0.$last" lladdr "02:00:00:00:00:$last" dev br-lan nud permanent || true
	done
}

reset_state() {
	rm -rf /etc/ikev2-manager/users.db /etc/ikev2-manager/client.secret /etc/ikev2-manager/tunnels.secret \
		/etc/ikev2-manager/mail.json \
		/etc/ikev2-manager/clients /etc/pbr-ikev2-*.txt /tmp/ikev2-*.status /tmp/dhcp.leases
	for run in /var/run /tmp/run; do
		rm -rf "$run"/ikev2-client-admin "$run"/ikev2-client-seen "$run"/ikev2-quality \
			"$run"/ikev2-manager-doctor-ui.cache "$run"/ikev2-*.status
	done
	cp /usr/share/ikev2-manager/defaults/ikev2-manager /etc/config/ikev2-manager
	: >/etc/ikev2-manager/users.db 2>/dev/null || true
	rm -f /usr/sbin/swanmon
}

# The monitor fails with the helpers in the error mode.
install_swanmon() {
	cat >/usr/sbin/swanmon <<SWAN
#!/bin/sh
if [ "\$(cat $state/mode 2>/dev/null)" = error ]; then
	echo 'stand: injected failure' >&2
	exit 1
fi
cat $state/sa.json
SWAN
	chmod 0755 /usr/sbin/swanmon
}

seed_empty() {
	uci set ikev2-manager.globals.configured=1
	uci set ikev2-manager.server.enabled=1
	uci set ikev2-manager.server.identity=vpn.example.test
	uci commit ikev2-manager
	printf '{"errors":[],"data":[{}]}\n' >"$state/sa.json"
	install_swanmon
}

# A day of samples, one a minute, in the format of take_sample, with one short
# outage: time, state, tunnel and WAN ping (sent, received, avg, jitter, max),
# tunnel counters, maintenance.
seed_quality() {
	mkdir -p /var/run/ikev2-quality
	now="$(date +%s)"
	awk -v now="$now" 'BEGIN {
		for (i = 1440; i >= 1; i--) {
			down = (i >= 200 && i < 206)
			rx += 1200000 + (i % 7) * 90000; tx += 300000 + (i % 5) * 40000
			printf "%d %s %s 5 5 %.1f 1.2 %.1f %d %d - -\n", now - i * 60, down ? "down" : "up",
				down ? "0 0 - - -" : sprintf("5 5 %.1f 1.4 %.1f", 38 + i % 9, 44 + i % 9),
				12 + i % 4, 15 + i % 4, rx, tx
		}
	}' | awk '{ print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, "-" }' >/var/run/ikev2-quality/samples
	{
		printf '%s outage %s\n' $((now - 12000)) 360
		printf '%s reconnect 1\n' $((now - 11640))
		printf '%s dns-switch -\n' $((now - 7200))
	} >/var/run/ikev2-quality/events
	# The second tunnel keeps a history of its own, so its tab draws a chart too.
	cp /var/run/ikev2-quality/samples /var/run/ikev2-quality/samples-2
	: >/var/run/ikev2-quality/events-2
}

seed_devices() {
	uci set ikev2-manager.globals.device_schema="$(sed -n 's/^device_schema_version=//p' /usr/libexec/ikev2-manager.d/devices.sh | tr -d "'\"")"
	uci set ikev2-manager.device_10_99_0_10=device_policy
	uci set ikev2-manager.device_10_99_0_10.address=10.99.0.10
	uci set ikev2-manager.device_10_99_0_10.route_mode=exclude
	uci set ikev2-manager.device_10_99_0_10.dns_passthrough=1
	uci set ikev2-manager.device_10_99_0_11=device_policy
	uci set ikev2-manager.device_10_99_0_11.address=10.99.0.11
	uci set ikev2-manager.device_10_99_0_11.route_mode=fullroute
	uci set ikev2-manager.device_10_99_0_11.respect_exclusions=1
	now="$(date +%s)"
	printf '%s 02:00:00:00:00:10 10.99.0.10 tv-test *\n%s 02:00:00:00:00:11 10.99.0.11 laptop-test *\n%s 02:00:00:00:00:12 10.99.0.12 phone-test *\n' \
		$((now + 3600)) $((now + 3600)) $((now + 3600)) >/tmp/dhcp.leases
}

seed_segments() {
	uci set ikev2-manager.dnsseg_corp=dns_segment
	uci set ikev2-manager.dnsseg_corp.name='Corp names'
	uci set ikev2-manager.dnsseg_corp.enabled=1
	uci set ikev2-manager.dnsseg_corp.domains='corp.example.test intranet.example.test'
	uci set ikev2-manager.dnsseg_corp.protocol=udp
	uci set ikev2-manager.dnsseg_corp.upstream_mode=load_balance
	uci set ikev2-manager.dnsseg_corp.upstream='203.0.113.53:53'
	uci set ikev2-manager.dnsseg_corp.port=5550
}

# Remote clients go through the application's own store, so what the page reads
# is what a real publication writes.
seed_clients() {
	uci set ikev2-manager.client_access=client_access
	uci set ikev2-manager.client_access.enabled=1
	uci set ikev2-manager.client_access.port=8443
	uci set ikev2-manager.client_access.approve=0
	uci commit ikev2-manager
	mkdir -p /etc/ikev2-manager/clients
	chmod 0700 /etc/ikev2-manager/clients
	ucode -L /usr/libexec/ikev2-manager.d "$here/seed-clients.uc"
	umask 077
	cat >/etc/ikev2-manager/mail.json <<'MAIL'
{"version":1,"host":"smtp.example.test","port":587,"security":"starttls","user":"mailer@example.test","password":"stand-mail","from":"mailer@example.test"}
MAIL
	umask 022
}

seed_vpn() {
	seed_empty
	uci set ikev2-manager.client.enabled=1
	uci set ikev2-manager.client.remote_address=exit.example.test
	uci set ikev2-manager.client.remote_id=exit.example.test
	uci set ikev2-manager.client.username=router-test
	uci set ikev2-manager.tunnel_2=tunnel
	uci set ikev2-manager.tunnel_2.name='Second exit'
	uci set ikev2-manager.tunnel_2.enabled=1
	uci set ikev2-manager.tunnel_2.remote_address=exit2.example.test
	uci set ikev2-manager.tunnel_2.remote_id=exit2.example.test
	uci set ikev2-manager.tunnel_2.username=router-test-2
	uci set ikev2-manager.dns.managed=1
	seed_devices
	seed_segments
	uci commit ikev2-manager
	printf 'router-test\t0sc3RhbmQ=\n' >/etc/ikev2-manager/client.secret
	chmod 0600 /etc/ikev2-manager/client.secret
	# A router always has the second tunnel's password: it cannot be added
	# without one, and Save of its other settings keeps it.
	printf '2\trouter-test-2\t0sc3RhbmQ=\n' >/etc/ikev2-manager/tunnels.secret
	chmod 0600 /etc/ikev2-manager/tunnels.secret
	seed_quality
	for name in alice bob carol; do
		printf '%s\t0sc3RhbmQ=\n' "$name" >>/etc/ikev2-manager/users.db
	done
	printf 'chat.example.test\nmedia.example.test\n' >/etc/pbr-ikev2-domains.manual.txt
	printf '203.0.113.0/24\n' >/etc/pbr-ikev2-addresses.manual.txt
	printf 'bank.example.test\n' >/etc/pbr-ikev2-domains.exclude.txt
	printf 'telegram 2\n' >/etc/pbr-ikev2-exits.txt
	printf 'openai\nanthropic_ai\ntelegram\n' >/etc/pbr-ikev2-community-selected.txt
	cat >"$state/sa.json" <<'SA'
{"errors":[],"data":[
{"ikev2-in":{"state":"ESTABLISHED","uniqueid":"3","established":"5400","remote-eap-id":"alice","remote-vips":["10.20.30.10"],"remote-host":"198.51.100.7","child-sas":{"ikev2-in-3":{"name":"ikev2-in","state":"INSTALLED","install-time":"1800","bytes-in":"73400320","bytes-out":"524288000"}}}},
{"proxy-out":{"state":"ESTABLISHED","uniqueid":"1","established":"7200","remote-host":"203.0.113.10","remote-id":"exit.example.test","local-vips":["10.20.20.10"],"child-sas":{"proxy4-1":{"name":"proxy4","state":"INSTALLED","install-time":"7200","bytes-in":"1073741824","bytes-out":"268435456"}}}}
]}
SA
}

seed_full() {
	seed_vpn
	seed_clients
}

set_mode() {
	mode="$1"
	case "$mode" in first-run | empty | vpn-only | full | error) ;; *) echo "unknown mode: $mode" >&2; exit 2 ;; esac
	reset_state
	case "$mode" in
	empty) seed_empty ;;
	vpn-only) seed_vpn ;;
	full | error) seed_full ;;
	esac
	echo "$mode" >"$state/mode"
}

case "${1:-}" in
up)
	install_all
	[ -f "$state/delay" ] || echo 0 >"$state/delay"
	seed_network
	# Its window covers the status page at every open.
	uci -q set attendedsysupgrade.client.login_check_for_upgrades=0 && uci commit attendedsysupgrade
	start_daemons
	set_mode first-run
	;;
mode) set_mode "${2:?mode}" ;;
delay) echo "${2:?milliseconds}" >"$state/delay" ;;
lang)
	uci set luci.main.lang="${2:?language}"
	uci set luci.languages=internal
	uci set luci.languages.en=English
	uci set luci.languages.ru='Русский (Russian)'
	uci commit luci
	rm -f /tmp/luci-indexcache*
	;;
*) echo 'Usage: container.sh {up|mode NAME|delay MS|lang NAME}' >&2; exit 2 ;;
esac
