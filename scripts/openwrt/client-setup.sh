#!/bin/sh
# First activation of managed desktop access through the LuCI bridge, on an
# installed OpenWrt userland: state, listener settings and the WAN rule.
set -eu
work="$(mktemp -d)"
state_dir=/etc/ikev2-manager/clients
bridge=/usr/libexec/ikev2-client-admin
step=baseline
procd_pid='' ubus_pid=''
cp /etc/config/ikev2-manager "$work/ikev2-manager"
cp /etc/config/firewall "$work/firewall" 2>/dev/null || :
cp /etc/config/network "$work/network" 2>/dev/null || :
cleanup() {
 rc=$?
 [ "$rc" = 0 ] || printf 'client-setup: failed step=%s\n' "$step" >&2
 /etc/init.d/ikev2-client-access stop >/dev/null 2>&1 || :
 fw4 -q stop 2>/dev/null || :
 nft delete table inet ikev2_device_policy 2>/dev/null || :
 [ -z "$procd_pid" ] || { kill "$procd_pid" 2>/dev/null || :; wait "$procd_pid" 2>/dev/null || :; }
 [ -z "$ubus_pid" ] || { kill "$ubus_pid" 2>/dev/null || :; wait "$ubus_pid" 2>/dev/null || :; }
 rm -rf /var/run/ubus
 cp "$work/ikev2-manager" /etc/config/ikev2-manager
 [ ! -f "$work/firewall" ] || cp "$work/firewall" /etc/config/firewall
 if [ -f "$work/network" ]; then cp "$work/network" /etc/config/network; else rm -f /etc/config/network; fi
 ip link del br-lan 2>/dev/null || :
 rm -rf "$work" "$state_dir"
}
trap cleanup EXIT INT TERM
[ ! -e "$state_dir" ]
# The bridge enables and reloads a real service, so supervision is real too.
mkdir -p /var/run/ubus
/sbin/ubusd >"$work/ubus-log" 2>&1 &
ubus_pid=$!
/sbin/procd -S >"$work/procd-log" 2>&1 &
procd_pid=$!
i=0
until ubus list service >/dev/null 2>&1; do
 i=$((i + 1)); [ "$i" -lt 15 ] || { cat "$work/procd-log" >&2; exit 1; }
 sleep 1
done
# A router has its firewall running; the reload after a rule change needs it.
fw4 -q start 2>/dev/null || { printf '%s\n' 'client-setup: the firewall did not start' >&2; exit 1; }
setup() {
 token="setup$(date +%s)$1"
 ( umask 077; printf '%s\n' "$2" >"/var/run/ikev2-client-admin-$token.in" )
 "$bridge" client-admin-setup "$token" >"$work/queued"
 job="$(sed -n 's/^action_id=//p' "$work/queued")"
 i=0
 until "$bridge" client-admin-status "$job" | grep -Eqx 'state=(ok|error)'; do
  i=$((i + 1)); [ "$i" -lt 60 ] || return 2
  sleep 1
 done
 "$bridge" client-admin-status "$job" | grep -qx 'state=ok'
}
shown() { "$bridge" client-admin-settings | jsonfilter -e "@.$1"; }

step=unconfigured
# Without an inbound server name or a tunnel there is nothing to attach to.
[ "$(shown initialized)" = false ]
if setup a '{"version":1,"enabled":true,"port":8443,"virtual_subnet":"172.31.254.0/24","exit":"1"}'; then exit 1; fi
[ ! -e "$state_dir/initialized" ]
[ "$(uci -q get ikev2-manager.client_access.enabled)" = 0 ]

uci set ikev2-manager.server.enabled=1
uci set ikev2-manager.server.identity=vpn.example.com
uci set ikev2-manager.server.pool4=10.25.0.10-10.25.0.50
uci set ikev2-manager.client=client
uci set ikev2-manager.client.enabled=1
# The inbound zone the server's own Apply creates, closed to the router, and
# the resolver that every local and VPN client is otherwise sent to.
# netifd does not run in the container: the LAN device is made by hand.
ip link add br-lan type dummy 2>/dev/null || :
ip addr add 192.168.1.1/24 dev br-lan 2>/dev/null || :
ip link set br-lan up
[ -f /etc/config/network ] || : >/etc/config/network
uci set network.lan=interface
uci set network.lan.device=br-lan
uci commit network
uci set ikev2-manager.globals.dns_enforce=1
uci set ikev2-manager.globals.configured=1
uci commit ikev2-manager
# The table exists before remote clients are set up, as on a router in use;
# setting them up must change it, not find it "unchanged".
/usr/libexec/ikev2-device-routing sync
nft list chain inet ikev2_device_policy dns_prerouting | grep -q 'redirect to :53'
if nft list chain inet ikev2_device_policy dns_prerouting | grep -q 'ipsec-in'; then exit 1; fi
uci add firewall zone >/dev/null
uci set firewall.@zone[-1].name=ikev2in
uci set firewall.@zone[-1].device=ipsec-in
uci set firewall.@zone[-1].input=REJECT
uci set firewall.@zone[-1].output=ACCEPT
uci set firewall.@zone[-1].forward=REJECT
uci commit firewall
[ "$(shown server_identity)" = vpn.example.com ]
[ "$(shown 'tunnels[0]')" = 1 ]

step=refusals
for request in \
 '{"version":1,"enabled":true,"port":443,"virtual_subnet":"172.31.254.0/24","exit":"1"}' \
 '{"version":1,"enabled":true,"port":8443,"virtual_subnet":"8.8.8.0/24","exit":"1"}' \
 '{"version":1,"enabled":true,"port":8443,"virtual_subnet":"172.31.254.7/24","exit":"1"}' \
 '{"version":1,"enabled":true,"port":8443,"virtual_subnet":"10.25.0.0/24","exit":"1"}' \
 '{"version":1,"enabled":true,"port":8443,"virtual_subnet":"172.31.254.0/24","exit":"2"}' \
 '{"version":1,"enabled":true,"port":8443,"virtual_subnet":"172.31.254.0/24","exit":"1","path":"/etc"}'; do
 if setup b "$request"; then exit 1; fi
 [ ! -e "$state_dir/initialized" ]
 [ "$(uci -q get ikev2-manager.client_access.enabled)" = 0 ]
done

step=activation
setup c '{"version":1,"enabled":true,"port":9443,"virtual_subnet":"172.31.254.0/24","exit":"1"}'
[ -f "$state_dir/initialized" ]
[ "$(ls -ld "$state_dir" | cut -c1-10)" = drwx------ ]
[ "$(shown initialized)" = true ] && [ "$(shown virtual_subnet)" = 172.31.254.0/24 ] && [ "$(shown exit)" = 1 ] && [ "$(shown port)" = 9443 ]
[ "$(uci -q get ikev2-manager.client_access.enabled)" = 1 ] && [ "$(uci -q get ikev2-manager.client_access.port)" = 9443 ]
[ "$(uci -q get firewall.ikev2pbr_client_api.enabled)" = 1 ] && [ "$(uci -q get firewall.ikev2pbr_client_api.dest_port)" = 9443 ]
[ "$(uci -q get firewall.ikev2pbr_client_api.proto)" = tcp ] && [ "$(uci -q get firewall.ikev2pbr_client_api.target)" = ACCEPT ]
# Not only stored: the running firewall accepts the port from WAN.
nft list chain inet fw4 input_wan | grep -q 'tcp dport 9443 .*accept'
"$bridge" client-admin-show | jsonfilter -e '@.api_endpoint' | grep -qx 'https://vpn.example.com:9443/client/v1/enroll'
# An admitted device's traffic to the virtual subnet is delivered on this router:
# the closed inbound zone lets it in by its admission mark, and nothing else.
nft list chain inet fw4 input_ikev2in | grep 'ip daddr 172.31.254.0/24' | grep 'mark 0x00800000' | grep -q accept
# Name queries of remote devices are not captured by the local resolver's
# enforcement: the exemption stands ahead of the redirect in the live table.
nft list chain inet ikev2_device_policy dns_prerouting >"$work/dns-chain"
grep -q 'redirect to :53' "$work/dns-chain"
[ "$(grep -n 'iifname "ipsec-in" ip daddr 172.31.254.0/24 return' "$work/dns-chain" | cut -d: -f1)" -lt "$(grep -n 'redirect to :53' "$work/dns-chain" | cut -d: -f1)" ]
# The controller is supervised from now on and has installed its closed table.
i=0
until ubus call service list '{"name":"ikev2-client-access"}' | grep -q '"access"' && nft list table inet ikev2_client_access >/dev/null 2>&1; do
 i=$((i + 1)); [ "$i" -lt 15 ] || exit 1
 sleep 1
done

step=changes
# The subnet belongs to enrolled devices; the exit and the listener may move.
if setup d '{"version":1,"enabled":true,"port":9443,"virtual_subnet":"172.30.0.0/24","exit":"1"}'; then exit 1; fi
[ "$(shown virtual_subnet)" = 172.31.254.0/24 ]
uci set ikev2-manager.tunnel_2=tunnel
uci set ikev2-manager.tunnel_2.enabled=1
uci commit ikev2-manager
generation="$(ucode /usr/libexec/ikev2-manager.d/client-access-control.uc status | sed -n 's/^generation=//p')"
setup e '{"version":1,"enabled":false,"port":9444,"virtual_subnet":"172.31.254.0/24","exit":"2s"}'
[ "$(shown exit)" = 2s ] && [ "$(shown enabled)" = false ]
[ "$(ucode /usr/libexec/ikev2-manager.d/client-access-control.uc status | sed -n 's/^generation=//p')" = "$((generation + 1))" ]
[ "$(uci -q get firewall.ikev2pbr_client_api.enabled)" = 0 ] && [ "$(uci -q get firewall.ikev2pbr_client_api.dest_port)" = 9444 ]
if nft list chain inet fw4 input_wan | grep -Eq 'tcp dport (9443|9444) '; then exit 1; fi
# The same settings again publish nothing.
setup f '{"version":1,"enabled":false,"port":9444,"virtual_subnet":"172.31.254.0/24","exit":"2s"}'
[ "$(ucode /usr/libexec/ikev2-manager.d/client-access-control.uc status | sed -n 's/^generation=//p')" = "$((generation + 1))" ]
printf '%s\n' 'client-setup: refusals, first activation, listener and WAN rule, fixed subnet, exit change and disable passed'
