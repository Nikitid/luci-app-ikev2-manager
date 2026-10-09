#!/bin/sh
# Two tunnels to two real strongSwan servers, end to end: both connect, each
# exit's traffic leaves through its own tunnel, the first exit moves to the
# second tunnel when its server goes and comes back two minutes after it
# returns, what is bound to the first tunnel without backup waits for it
# instead of moving, and with no tunnel left nothing reaches the WAN.
#
# Runs inside a privileged OpenWrt rootfs container with the package and
# strongSwan installed (install.sh failover). The servers live in network
# namespaces of their own, each with its own charon, and a third namespace is
# a LAN client. The kernel must have XFRM interfaces; without them the test
# says so and stops.

set -eu

# A failure in CI is read from its output alone: it carries the tunnels' state
# and the logs.
fail() {
	printf 'failover: %s\n' "$*" >&2
	{
		printf -- '-- SAs\n'
		/usr/libexec/ikev2-sa tunnels 2>&1 || :
		printf -- '-- tunnel choice\n'
		cat /var/run/ikev2-tunnels.state 2>&1 || :
		ip -4 rule show 2>&1 | grep '^280' || :
		for table in 1601 1603; do
			printf -- '-- table %s\n' "$table"
			ip -4 route show table "$table" 2>&1 || :
		done
		for log in /tmp/charon-*.log /tmp/health.log /tmp/ikev2-manager-action.log; do
			[ -f "$log" ] || continue
			printf -- '-- %s\n' "$log"
			tail -n 40 "$log"
		done
	} >&2
	exit 1
}
step() { printf '  %s\n' "$*"; }

if ! ip link add xfrm-probe type xfrm dev lo if_id 99 2>/dev/null; then
	[ "${IKEV2_REQUIRE_XFRM:-0}" != 1 ] || fail 'this kernel has no XFRM interfaces'
	printf '%s\n' 'failover: skipped, this kernel has no XFRM interfaces'
	exit 0
fi
ip link del xfrm-probe

mkdir -p /var/lock /var/run /tmp/run

# --- the network ------------------------------------------------------------
#
#   lan 192.168.1.100 -- br-lan 192.168.1.1 [router] br-wan 10.99.0.1 -- srv1 10.99.0.11
#                                                                    \-- srv2 10.99.0.12
#
# Both servers answer on 203.0.113.10 and 198.51.100.10, the destinations of
# the first and the second exit, and on 192.0.2.10, which is bound to the
# first tunnel without backup; which server carried a packet is told by their
# counters, not by the address.

bridge() {
	ip link add "$1" type bridge
	ip addr add "$2" dev "$1"
	ip link set "$1" up
}
# attach NAMESPACE ADDRESS BRIDGE GATEWAY
attach() {
	ip netns add "$1"
	ip link add "v-$1" type veth peer name eth0 netns "$1"
	ip link set "v-$1" master "$3" up
	ip -n "$1" addr add "$2" dev eth0
	ip -n "$1" link set eth0 up
	ip -n "$1" link set lo up
	ip -n "$1" route add default via "$4"
}
bridge br-lan 192.168.1.1/24
bridge br-wan 10.99.0.1/24
attach lan 192.168.1.100/24 br-lan 192.168.1.1
attach srv1 10.99.0.11/24 br-wan 10.99.0.1
attach srv2 10.99.0.12/24 br-wan 10.99.0.1
echo 1 >/proc/sys/net/ipv4/ip_forward

# --- the servers --------------------------------------------------------------

ca=/tmp/ca
mkdir -p "$ca"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -days 2 \
	-subj '/CN=Failover Test CA' -keyout "$ca/ca.key" -out "$ca/ca.pem" 2>/dev/null
# The client trusts what x509ca holds, as it does the Let's Encrypt roots.
cp "$ca/ca.pem" /etc/swanctl/x509ca/failover-test-ca.pem

# server N: its own certificate, account, address pool and charon, whose
# VICI socket sits beside the others in /tmp.
server() {
	local n="$1" dir="/etc/netns/srv$1"
	mkdir -p "$dir/swanctl/x509" "$dir/swanctl/private" "$dir/swanctl/x509ca" "$dir/swanctl/conf.d"
	openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes \
		-subj "/CN=srv$n.test" -keyout "$dir/swanctl/private/server.key" \
		-out "/tmp/srv$n.csr" 2>/dev/null
	printf 'subjectAltName=DNS:srv%s.test\nextendedKeyUsage=serverAuth\n' "$n" >"/tmp/srv$n.ext"
	openssl x509 -req -in "/tmp/srv$n.csr" -CA "$ca/ca.pem" -CAkey "$ca/ca.key" \
		-CAcreateserial -days 2 -extfile "/tmp/srv$n.ext" \
		-out "$dir/swanctl/x509/server.pem" 2>/dev/null
	cat >"$dir/strongswan.conf" <<EOF
charon {
	load_modular = yes
	plugins {
		include strongswan.d/charon/*.conf
		vici {
			socket = unix:///tmp/srv$n.vici
		}
	}
	filelog {
		log {
			path = /tmp/charon-srv$n.log
			default = 1
		}
	}
}
EOF
	cat >"$dir/swanctl/swanctl.conf" <<EOF
connections {
	rw {
		version = 2
		proposals = aes256gcm16-prfsha384-ecp384
		pools = pool$n
		local {
			auth = pubkey
			certs = server.pem
			id = srv$n.test
		}
		remote {
			auth = eap-mschapv2
			eap_id = %any
		}
		children {
			net {
				local_ts = 0.0.0.0/0
				esp_proposals = aes256gcm16-ecp384
			}
		}
	}
}
pools {
	pool$n {
		addrs = 10.10.$n.0/24
	}
}
secrets {
	eap-user {
		id = user$n
		secret = "pass-$n"
	}
}
EOF
	# The destinations, answered by the server itself.
	ip -n "srv$n" addr add 203.0.113.10/32 dev lo
	ip -n "srv$n" addr add 198.51.100.10/32 dev lo
	ip -n "srv$n" addr add 192.0.2.10/32 dev lo
	ip netns exec "srv$n" nft -f - <<'EOF'
table inet count {
	counter first { }
	counter second { }
	counter bound { }
	chain input {
		type filter hook input priority 0;
		ip daddr 203.0.113.10 icmp type echo-request counter name first
		ip daddr 198.51.100.10 icmp type echo-request counter name second
		ip daddr 192.0.2.10 icmp type echo-request counter name bound
	}
}
EOF
}

# start N: charon in the server's namespace, with /var/run of its own so its
# PID file does not meet the router's charon. Its log is /tmp/charon-srvN.log.
start() {
	ip netns exec "srv$1" sh -c '
		mount -t tmpfs tmpfs /tmp/run
		/usr/lib/ipsec/charon >/dev/null 2>&1 &
		echo $! >/tmp/srv'"$1"'.pid
	'
	i=0
	until swanctl --stats --uri "unix:///tmp/srv$1.vici" >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 15 ] || fail "the charon of server $1 did not start"
		sleep 1
	done
	ip netns exec "srv$1" swanctl --load-all --uri "unix:///tmp/srv$1.vici" >/dev/null ||
		fail "server $1 did not load its configuration"
}
stop() {
	kill "$(cat "/tmp/srv$1.pid")" 2>/dev/null || :
	rm -f "/tmp/srv$1.vici"
}
# seen N COUNTER: the echo requests server N has answered on that address
seen() {
	ip netns exec "srv$1" nft list counter inet count "$2" |
		sed -n 's/.*packets \([0-9]*\).*/\1/p'
}

step 'two strongSwan servers start in their own namespaces'
server 1
server 2
start 1
start 2

# --- the router -----------------------------------------------------------------

# wait_until SECONDS COMMAND...: whether the command succeeded within the time
wait_until() {
	local limit="$1" i=0
	shift
	until "$@" >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt "$limit" ] || return 1
		sleep 1
	done
}
tunnel_up() {
	/usr/libexec/ikev2-sa tunnels | awk -v n="$1" '$1 == n && $2 == 1 { up = 1 } END { exit !up }'
}
tunnel_down() { ! tunnel_up "$1"; }
exit_uses() { grep -qx "exit $1 $2" /var/run/ikev2-tunnels.state; }
# reaches ADDRESS SERVER COUNTER: a LAN client's pings to the address are
# answered, and by that server
reaches() {
	local before after
	before="$(seen "$2" "$3")"
	ip netns exec lan ping -c 2 -W 3 "$1" >/dev/null 2>&1 ||
		fail "the LAN client got no answer from $1"
	after="$(seen "$2" "$3")"
	[ "$after" -gt "$before" ] || fail "$1 was not answered by server $2"
}

step 'the router connects both tunnels the way the pages set them up'
# netifd does not run: the LAN is described in UCI, where the helpers fall
# back to look for it.
touch /etc/config/network
uci -q batch <<'UCI'
set network.lan=interface
set network.lan.device='br-lan'
set ikev2-manager.globals.configured='1'
set ikev2-manager.globals.device_schema='2'
set ikev2-manager.domains=domains
set ikev2-manager.domains.engine='nftset'
commit
UCI
# netifd does not run, so fw4 cannot learn the LAN zone's device; it is named.
uci set firewall.@zone[0].device='br-lan'
uci commit firewall
fw4 -q start 2>/dev/null || fail 'the firewall did not start'
# The first exit's destination, the second's, and what is bound to the first
# tunnel without backup.
printf '203.0.113.10/32\n' >/etc/pbr-ikev2-service-cidrs.txt
printf '198.51.100.10/32\n' >/etc/pbr-ikev2-service-cidrs.exit-2.txt
printf '192.0.2.10/32\n' >/etc/pbr-ikev2-service-cidrs.exit-1s.txt
/usr/lib/ipsec/charon >/tmp/charon-router.log 2>&1 &
wait_until 15 swanctl --stats || fail 'the router charon did not start'
/etc/init.d/ikev2-xfrm start || fail 'the tunnel links were not created'

token=failover-test
printf '%s\n' save 1 10.99.0.11 srv1.test user1 10 1400 pass-1 15 google \
	https://dns.google/dns-query 8.8.8.8:53 >"/var/run/ikev2-manager-client-$token.in"
/usr/libexec/ikev2-manager client-input "$token" || fail 'the first tunnel was not saved'
printf '%s\n' save new Backup 1 10.99.0.12 srv2.test user2 10 1400 1 pass-2 \
	>"/var/run/ikev2-manager-tunnel-$token.in"
action="$(/usr/libexec/ikev2-manager tunnel-input "$token" | sed -n 's/^action_id=//p')"
[ -n "$action" ] || fail 'the second tunnel was not saved'
action_done() {
	/usr/libexec/ikev2-manager action-status "$action" | grep -Eq '^state=(ok|error)$'
}
wait_until 90 action_done || fail 'applying the second tunnel did not finish'
/usr/libexec/ikev2-manager action-status "$action" | sed -n 's/^message=/    apply: /p'

swanctl --load-all >/dev/null 2>&1 || fail 'the router did not load the tunnels'
/usr/libexec/ikev2-manager ensure-client || :
wait_until 30 tunnel_up 1 || fail 'the first tunnel did not connect'
wait_until 30 tunnel_up 2 || fail 'the second tunnel did not connect'

# Anything for the two destinations that leaves other than through a tunnel.
nft -f - <<'NFT'
table ip failover {
	counter leaked { }
	chain forward {
		type filter hook forward priority 0;
		ip daddr { 203.0.113.10, 198.51.100.10, 192.0.2.10 } oifname != "ipsec-out*" counter name leaked
	}
}
NFT

/usr/libexec/ikev2-health >/tmp/health.log 2>&1 &
health=$!
wait_until 40 exit_uses 1 1 && wait_until 5 exit_uses 2 2 ||
	fail "the watcher did not give each exit its own tunnel: $(cat /var/run/ikev2-tunnels.state 2>/dev/null)"
for link in ipsec-out ipsec-out2; do
	wait_until 20 sh -c "ip -4 -o addr show dev $link | grep -q 'inet 10\.10\.'" ||
		fail "$link did not get its virtual address"
done

step 'each exit leaves through its own tunnel'
reaches 203.0.113.10 1 first
reaches 198.51.100.10 2 second
reaches 192.0.2.10 1 bound

step 'the first exit moves to the second tunnel when its server goes'
# A charon that stops deletes its SAs, so the router learns at once.
stop 1
wait_until 40 exit_uses 1 2 || fail 'the first exit did not move to the second tunnel'
reaches 203.0.113.10 2 first
reaches 198.51.100.10 2 second

step 'what is bound to the first tunnel waits for it instead of moving'
exit_uses 1s 0 || fail "the exit without backup was given a tunnel: $(cat /var/run/ikev2-tunnels.state)"
before="$(seen 2 bound)"
ip netns exec lan ping -c 2 -W 2 192.0.2.10 >/dev/null 2>&1 &&
	fail 'what is bound to the first tunnel was answered while that tunnel is down'
[ "$(seen 2 bound)" = "$before" ] || fail 'what is bound to the first tunnel left through the second'

step 'it comes back once its own tunnel has been up for two minutes'
start 1
wait_until 90 tunnel_up 1 || fail 'the first tunnel did not reconnect'
up_since="$(date +%s)"
sleep 20
exit_uses 1 2 || fail 'the first exit went back before its tunnel had stayed up'
reaches 203.0.113.10 2 first
# Its own tunnel is all it may use, so there is nothing to hold it back from.
reaches 192.0.2.10 1 bound
wait_until 150 exit_uses 1 1 || fail 'the first exit did not go back to its own tunnel'
held=$(($(date +%s) - up_since))
[ "$held" -ge 105 ] || fail "the first exit went back after ${held} s of its tunnel up"
# The choice is written down first and the rules follow it within the same
# pass of the watcher: a packet sent in between still leaves through the
# tunnel the exit is moving away from. So the move is given a few seconds to
# reach the data path; that it does, and by which server, is what is checked.
moved() {
	local before
	before="$(seen 1 first)"
	ip netns exec lan ping -c 1 -W 2 203.0.113.10 >/dev/null 2>&1 || return 1
	[ "$(seen 1 first)" -gt "$before" ]
}
wait_until 10 moved || fail '203.0.113.10 was still not answered by server 1 ten seconds after the move back'
reaches 203.0.113.10 1 first

step 'with no tunnel left nothing reaches the WAN'
stop 1
stop 2
wait_until 40 tunnel_down 1 && wait_until 10 tunnel_down 2 || fail 'the tunnels did not go down'
sleep 20
ip netns exec lan ping -c 2 -W 2 203.0.113.10 >/dev/null 2>&1 &&
	fail 'the first exit was answered with no tunnel up'
ip netns exec lan ping -c 2 -W 2 198.51.100.10 >/dev/null 2>&1 &&
	fail 'the second exit was answered with no tunnel up'
leaked="$(nft list counter ip failover leaked | sed -n 's/.*packets \([0-9]*\).*/\1/p')"
[ "$leaked" = 0 ] || fail "$leaked packets for the tunnels left another way"

kill "$health" 2>/dev/null || :
printf '%s\n' 'failover OK'
