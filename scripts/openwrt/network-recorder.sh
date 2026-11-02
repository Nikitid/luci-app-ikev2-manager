#!/bin/sh
# Real BusyBox/ip/flock behaviour; probe results may be down on an offline host.
set -eu
work=/tmp/network-recorder-test
rm -rf "$work"
ip link add ipsec-out7 type dummy
cleanup() {
	[ -z "${loop_pid:-}" ] || kill "$loop_pid" 2>/dev/null || true
	[ -z "${reader_pid:-}" ] || kill "$reader_pid" 2>/dev/null || true
	[ -z "${log_pid:-}" ] || kill "$log_pid" 2>/dev/null || true
	[ -z "${bus_pid:-}" ] || kill "$bus_pid" 2>/dev/null || true
	ip link del ipsec-out7
	rm -rf "$work" /tmp/ikev2-network
}
trap cleanup EXIT
ip link set ipsec-out7 up
ip addr add 198.51.100.77/32 dev ipsec-out7
NETWORK_HISTORY_DIR="$work" sh /src/scripts/network-recorder.sh paths-once
[ -s "$work/paths.log" ]
grep -q 'ipsec-out7=no-icmp' "$work/paths.log"
[ -n "$(find "$work" -maxdepth 0 -user root ! -perm -077)" ]
[ -n "$(find "$work/paths.log" -maxdepth 0 -user root ! -perm -077)" ]
awk 'BEGIN {for(i=1;i<=17281;i++)print "1 paths old"}' >"$work/paths.log"
NETWORK_HISTORY_DIR="$work" sh /src/scripts/network-recorder.sh paths-once
[ "$(wc -l <"$work/paths.log")" = 17280 ]
tail -n1 "$work/paths.log" | grep -q 'ipsec-out7=no-icmp'
# A stopped loop must not leave its idle sleep holding the writer lock.
NETWORK_HISTORY_DIR="$work/loop" sh /src/scripts/network-recorder.sh paths & loop_pid=$!
i=0
while [ ! -s "$work/loop/paths.log" ]; do
	i=$((i + 1)); [ "$i" -lt 15 ]; sleep 1
done
sleep 1
kill "$loop_pid"
wait "$loop_pid" 2>/dev/null || true
loop_pid=
exec 8>"$work/loop/paths.lock"
flock -n 8
flock -u 8
exec 8>&-

# Execute the init script's real logread command against OpenWrt logd.
# The procd adapter selects only the event instance in this isolated container.
mkdir -p /var/run /tmp/run
/sbin/ubusd >"$work/ubusd.log" 2>&1 & bus_pid=$!
sleep 1
/sbin/logd >"$work/logd.log" 2>&1 & log_pid=$!
sleep 1
. /src/scripts/network-recorder.init
procd_open_instance() { instance="$1"; }
procd_close_instance() { :; }
procd_set_param() {
	[ "$instance:$1" = events:command ] || return 0
	shift
	"$@" >"$work/reader.log" 2>&1 & reader_pid=$!
}
start_service
sleep 1
logger -t ikev2-recorder-test 'event capture verification'
logger -t ipsec 'IKE rekey failed: verification'
sleep 1
grep -q 'ikev2-recorder-test.*event capture verification' /tmp/ikev2-network/events.log
grep -q 'ipsec.*IKE rekey failed' /tmp/ikev2-network/events.log
# -S is KiB despite logread's usage text. Verify actual bounded rotation.
payload=$(awk 'BEGIN {for(i=0;i<850;i++)printf "x"}')
i=0
while [ "$i" -lt 700 ]; do
	logger -t ikev2-recorder-test "$payload"
	i=$((i + 1))
	[ "$((i % 20))" != 0 ] || sleep 1
done
sleep 1
[ -f /tmp/ikev2-network/events.log.old ]
size=$(wc -c </tmp/ikev2-network/events.log.old)
[ "$size" -ge 524288 ] && [ "$size" -lt 526000 ]
printf 'network recorder BusyBox scenarios OK\n'
