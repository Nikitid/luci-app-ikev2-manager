#!/bin/sh

# Tunnel quality history: the watcher's sample, the events it derives, the
# marks operator actions leave, the window summary the pages read and the
# on-demand speed test. The probes run against stubs, so every number below
# is known in advance.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-tunnel-quality.sh"
health="$root/ikev2-manager-runtime/ikev2-health.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

stub="$tmp/stub"
mkdir -p "$tmp/bin" "$stub"
cp "$root/scripts/uci-stub.sh" "$tmp/bin/uci"

# -d reads a log time, which the tests write in UTC.
cat >"$tmp/bin/date" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -d ]; then
	/bin/date -u -j -f '%Y-%m-%d %H:%M:%S' "$2" +%s 2>/dev/null || /bin/date -u -d "$2" +%s
	exit
fi
[ "${1:-}" = +%s ] && [ -s "$STUB/now" ] && exec cat "$STUB/now"
exec /bin/date "$@"
EOF

# start_action detaches through start-stop-daemon; record what it was asked.
cat >"$tmp/bin/start-stop-daemon" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB/started"
EOF

# Replies come from $STUB/ping-<device>-<target>, one "time" per line.
cat >"$tmp/bin/ping" <<'EOF'
#!/bin/sh
device='' target='' count=5
while [ "$#" -gt 0 ]; do
	case "$1" in
		-I) device="$2"; shift ;;
		-c) count="$2"; shift ;;
		-W | -w | -i) shift ;;
		-*) ;;
		*) target="$1" ;;
	esac
	shift
done
printf '%s %s\n' "$device" "$target" >>"$STUB/ping-calls"
printf 'PING %s (%s): 56 data bytes\n' "$target" "$target"
n=0
if [ -f "$STUB/ping-$device-$target" ]; then
	while read -r t; do
		printf '64 bytes from %s: seq=%s ttl=56 time=%s ms\n' "$target" "$n" "$t"
		n=$((n + 1))
	done <"$STUB/ping-$device-$target"
fi
printf '\n--- %s ping statistics ---\n' "$target"
printf '%s packets transmitted, %s packets received\n' "$count" "$n"
[ "$n" -gt 0 ]
EOF

cat >"$tmp/bin/swanmon" <<'EOF'
#!/bin/sh
cat "$STUB/sas" 2>/dev/null || :
EOF

# The whole ring buffer cost seconds of CPU on every sample; only the last
# messages may be read.
cat >"$tmp/bin/logread" <<'EOF'
#!/bin/sh
[ "${1:-}" = -l ] || : >"$STUB/whole-log-read"
cat "$STUB/log" 2>/dev/null || :
EOF

cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	'-4 route show table main default') [ -e "$STUB/no-default" ] || echo 'default via 192.0.2.1 dev wan9 proto static' ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/logger" <<'EOF'
#!/bin/sh
:
EOF

# The tunnel HTTPS probe answers when $STUB/https-ok exists. A speed request
# (the one with -w) prints $STUB/speed-<device>-<down|up> and exits with the
# code in the matching .rc file.
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
device='' write='' direction=down
while [ "$#" -gt 0 ]; do
	case "$1" in
		--interface) device="$2"; shift ;;
		-w) write=1; shift ;;
		-T) direction=up; shift ;;
		--connect-timeout | --max-time | -o | -X) shift ;;
	esac
	shift
done
if [ -n "$write" ]; then
	[ "$direction" = down ] || cat >/dev/null
	printf '%s %s\n' "$device" "$direction" >>"$STUB/speed-calls"
	cat "$STUB/speed-$device-$direction" 2>/dev/null
	exit "$(cat "$STUB/speed-$device-$direction.rc" 2>/dev/null || echo 0)"
fi
[ -e "$STUB/https-ok" ] || exit 7
echo 'ip=203.0.113.9'
EOF
chmod +x "$tmp/bin/"*

installed_sa='{"errors":[],"data":[{"proxy-out":{"uniqueid":"5","state":"ESTABLISHED","child-sas":{"proxy4-3":{"name":"proxy4","uniqueid":"3","state":"INSTALLED","mode":"TUNNEL"}}}}]}'

PATH="$tmp/bin:$PATH"
STUB="$stub"
UCI_STUB_DIR="$tmp/uci"
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib"
IKEV2_QUALITY_DIR="$tmp/quality"
IKEV2_NET_DIR="$tmp/net"
TZ=UTC
IKEV2_SA_HELPER="$root/ikev2-manager-runtime/ikev2-sa.sh"
IKEV2_SWANMON="$tmp/bin/swanmon"
export PATH STUB UCI_STUB_DIR IKEV2_RUNTIME_LIB_DIR IKEV2_QUALITY_DIR IKEV2_NET_DIR TZ
export IKEV2_SA_HELPER IKEV2_SWANMON
marks="$tmp/quality/marks"

setup() {
	rm -rf "$stub" "$tmp/uci" "$tmp/quality" "$tmp/net"
	mkdir -p "$stub" "$tmp/uci" "$tmp/net/ipsec-out/statistics"
	printf 'client=client\nclient.enabled=1\n' >"$tmp/uci/ikev2-manager"
	printf '%s\n' "$installed_sa" >"$stub/sas"
	printf '1000\n' >"$stub/now"
	printf '0\n' >"$tmp/net/ipsec-out/statistics/rx_bytes"
	printf '0\n' >"$tmp/net/ipsec-out/statistics/tx_bytes"
	printf '50\n52\n48\n54\n46\n' >"$stub/ping-ipsec-out-1.1.1.1"
	printf '2\n2\n2\n2\n2\n' >"$stub/ping-wan9-1.1.1.1"
}

sample_at() {
	printf '%s\n' "$1" >"$stub/now"
	"$helper" sample
}

last_sample() {
	tail -n1 "$tmp/quality/samples"
}

expect() {
	value="$(sed -n "s/^$1=//p" "$tmp/summary")"
	[ "$value" = "$2" ] || fail "summary $1 is '$value', expected '$2'"
}

points() {
	sed -n 's/^points=//p' "$tmp/summary" | tr ';' '\n'
}

# A healthy sample: both paths pinged, jitter is the mean change between
# consecutive replies, the device counters are recorded as they are, and no
# action was running.
setup
printf '1000\n' >"$tmp/net/ipsec-out/statistics/rx_bytes"
sample_at 1000
[ "$(last_sample)" = '1000 up 5 5 50.0 54.0 5.0 5 5 2.0 2.0 0.0 1000 0 -' ] ||
	fail "unexpected healthy sample: $(last_sample)"
grep -qx 'wan9 1.1.1.1' "$stub/ping-calls" || fail 'the WAN path was not pinged on the default route device'
[ ! -s "$tmp/quality/events" ] || fail 'a first healthy sample produced an event'

# Partial loss is kept as sent and received counts.
setup
printf '50\n50\n' >"$stub/ping-ipsec-out-1.1.1.1"
sample_at 1000
case "$(last_sample)" in '1000 up 5 2 50.0 50.0 0.0 '*) ;; *) fail "loss was not recorded: $(last_sample)" ;; esac

# A far end that drops ICMP to the first target is measured on the second.
setup
rm -f "$stub/ping-ipsec-out-1.1.1.1"
printf '60\n60\n60\n60\n60\n' >"$stub/ping-ipsec-out-8.8.8.8"
sample_at 1000
case "$(last_sample)" in '1000 up 5 5 60.0 '*) ;; *) fail "the second target was not used: $(last_sample)" ;; esac

# No ICMP at all, but HTTPS crosses the tunnel: up, with no timings. Without
# HTTPS it is a tunnel that carries nothing.
setup
rm -f "$stub/ping-ipsec-out-1.1.1.1"
touch "$stub/https-ok"
sample_at 1000
case "$(last_sample)" in '1000 up 5 0 - - - '*) ;; *) fail "filtered ICMP read as a failure: $(last_sample)" ;; esac
rm -f "$stub/https-ok"
sample_at 1060
case "$(last_sample)" in '1060 noreply 5 0 - - - '*) ;; *) fail "a silent tunnel was not reported: $(last_sample)" ;; esac
grep -qx '1060 outage noreply' "$tmp/quality/events" || fail 'the outage event is missing'
printf '50\n50\n50\n50\n50\n' >"$stub/ping-ipsec-out-1.1.1.1"
sample_at 1180
grep -qx '1180 restored 120' "$tmp/quality/events" || fail 'the restore event does not carry the outage length'

# No installed child SA is down without a ping; a disabled client is off.
setup
: >"$stub/sas"
sample_at 1000
case "$(last_sample)" in '1000 down 0 0 - - - 5 5 '*) ;; *) fail "a missing SA was not down: $(last_sample)" ;; esac
grep -q '^ipsec-out ' "$stub/ping-calls" && fail 'a down tunnel was pinged'
printf 'client=client\nclient.enabled=0\n' >"$tmp/uci/ikev2-manager"
sample_at 1060
case "$(last_sample)" in '1060 off '*) ;; *) fail "a disabled client was not off: $(last_sample)" ;; esac

# Actions mark themselves. One that can interrupt the tunnel opens a window
# its EXIT trap closes; one that cannot is a single event; the rest leave
# nothing.
setup
(
	. "$root/ikev2-manager-runtime/lib/actions.sh"
	quality_action_begin pbr-restart
	quality_action_end
	quality_action_begin recover-reliable
	quality_action_end
	quality_action_begin dns-set
	quality_action_end
)
[ "$(awk '{ print $1, $2, $3, $4 }' "$marks" | tr '\n' ';')" = \
	'1000 begin pbr-restart manual;1000 end pbr-restart manual;1000 event recover-reliable manual;' ] ||
	fail "actions marked themselves wrongly: $(cat "$marks")"
for runner in "$root/ikev2-manager-runtime/ikev2-manager-system.sh" "$root/luci-ikev2-manager/ikev2-manager.sh"; do
	grep -q '^	quality_action_begin "\$kind"$' "$runner" || fail "$runner does not mark its actions"
	grep -q "trap 'quality_action_end; " "$runner" || fail "$runner does not close its window on exit"
done
grep -q 'quality_mark event resolver-restart auto' "$root/ikev2-manager-runtime/ikev2-domain-router.sh" ||
	fail 'the automatic resolver restart is not marked'
grep -q 'quality_mark event dns-switch auto' "$root/ikev2-manager-runtime/ikev2-domain-router.sh" ||
	fail 'the tunnel DNS switch is not marked'

# A sample inside a window is maintenance: it names the action and is neither
# an outage nor a restore. The state before the window carries across it.
setup
sample_at 1000
printf '1050 begin connect manual 1 -\n1070 end connect manual 1 -\n' >"$marks"
: >"$stub/sas"
sample_at 1060
case "$(last_sample)" in '1060 down '*' connect') ;; *) fail "a sample inside a window was not marked: $(last_sample)" ;; esac
printf '%s\n' "$installed_sa" >"$stub/sas"
sample_at 1120
case "$(last_sample)" in '1120 up '*' -') ;; *) fail "a sample after the window was marked: $(last_sample)" ;; esac
[ ! -s "$tmp/quality/events" ] || fail "a planned interruption was reported as an outage: $(cat "$tmp/quality/events")"
# An open window counts while its action lives, and not after it died.
sleep 30 &
alive=$!
printf '1150 begin pbr-restart manual %s -\n1150 begin set manual 999999 -\n' "$alive" >"$marks"
sample_at 1180
case "$(last_sample)" in *' pbr-restart') ;; *) fail "a running action did not mark the sample: $(last_sample)" ;; esac
kill "$alive" 2>/dev/null || :
wait "$alive" 2>/dev/null || :
sample_at 1240
case "$(last_sample)" in *' -') ;; *) fail "a dead action kept marking samples: $(last_sample)" ;; esac

# Reconnects come from charon's "established" lines logged after the previous
# sample, at the time the log gives. Rekeys are not reconnects, the first
# sample only places the mark, and a reconnect inside an action's window is
# that action's.
setup
base="$(date -d '2026-09-25 21:00:00' +%s)"
printf '%s\n' 'Fri Sep 25 20:00:00 2026 daemon.info ipsec: 14[IKE] IKE_SA proxy-out[1] established between a...b' \
	'Fri Sep 25 20:30:00 2026 daemon.info ipsec: 13[IKE] IKE_SA proxy-out[8] rekeyed between a...b' >"$stub/log"
sample_at "$base"
[ ! -s "$tmp/quality/events" ] || fail 'the first sample counted old connections'
printf '%s\n' 'Fri Sep 25 21:00:30 2026 daemon.info ipsec: 11[IKE] IKE_SA proxy-out[9] rekeyed between a...b' >>"$stub/log"
sample_at $((base + 60))
[ ! -s "$tmp/quality/events" ] || fail 'a rekey was counted as a reconnect'
printf '%s begin connect manual 1 -\n%s end connect manual 1 -\n' "$((base + 90))" "$((base + 100))" >"$marks"
printf '%s\n' 'Fri Sep 25 21:01:35 2026 daemon.info ipsec: 10[IKE] IKE_SA proxy-out[12] established between a...b' \
	'Fri Sep 25 21:01:50 2026 daemon.info ipsec: 09[IKE] IKE_SA proxy-out[14] established between a...b' >>"$stub/log"
sample_at $((base + 120))
[ "$(cat "$tmp/quality/events")" = "$((base + 110)) reconnect 1" ] ||
	fail "reconnects were not dated from the log or the manual one was counted: $(cat "$tmp/quality/events")"
sample_at $((base + 180))
[ "$(grep -c reconnect "$tmp/quality/events")" = 1 ] || fail 'connections were counted twice'
# Lines that have rotated out of the ring buffer lose nothing that is new.
printf '%s\n' 'Fri Sep 25 21:03:10 2026 daemon.info ipsec: 08[IKE] IKE_SA proxy-out[20] established between a...b' >"$stub/log"
sample_at $((base + 240))
grep -qx "$((base + 190)) reconnect 1" "$tmp/quality/events" || fail 'a rotated log lost a connection'
[ ! -e "$stub/whole-log-read" ] || fail 'a sample read the whole system log'

# History is bounded, marks included.
setup
mkdir -p "$tmp/quality"
awk 'BEGIN { for (i = 1; i <= 1600; i++) print i, "up 5 5 50.0 50.0 0.0 5 5 2.0 2.0 0.0 0 0 -" }' >"$tmp/quality/samples"
printf '10 event dns-switch auto 1 -\n90000 event dns-switch auto 1 -\n' >"$marks"
sample_at 100000
[ "$(wc -l <"$tmp/quality/samples" | tr -d ' ')" = 1440 ] || fail 'samples were not trimmed'
[ "$(last_sample | cut -d' ' -f1)" = 100000 ] || fail 'trimming dropped the newest sample'
[ "$(cat "$marks")" = '90000 event dns-switch auto 1 -' ] || fail "old marks were not trimmed: $(cat "$marks")"

# The summary: loss is lost over sent across samples, percentiles come from
# the per-sample means, availability counts every sample the tunnel was meant
# to be up, and traffic is the counter change between consecutive samples. A
# maintenance sample counts for none of it and names its action instead. The
# first line is the older fourteen-field format, which still reads.
setup
mkdir -p "$tmp/quality"
cat >"$tmp/quality/samples" <<'EOF'
100 up 5 5 40.0 45.0 2.0 5 5 2.0 2.0 0.0 0 0
10000 up 10 10 40.0 45.0 2.0 5 5 2.0 2.0 0.0 0 0
10060 up 5 5 50.0 55.0 4.0 5 5 3.0 3.0 0.0 750000 75000 -
10120 up 5 4 60.0 90.0 6.0 5 5 3.0 3.0 0.0 1500000 150000 -
10190 down 0 0 - - - 5 5 2.0 2.0 0.0 1500000 150000 pbr-restart
10250 noreply 5 0 - - - 5 5 2.0 2.0 0.0 1500000 150000 -
10300 up 5 5 70.0 75.0 8.0 5 5 2.0 2.0 0.0 100 100 -
EOF
printf '10330\n' >"$stub/now"
cat >"$tmp/quality/events" <<'EOF'
5000 reconnect 1
10250 outage noreply
10300 restored 50
10300 reconnect 1
EOF
cat >"$marks" <<'EOF'
10180 begin pbr-restart manual 7 -
10205 end pbr-restart manual 7 -
10210 event resolver-restart auto 8 -
10220 event dns-switch auto 8 https://b.example/dns-query
EOF
"$helper" summary 1h >"$tmp/summary"
expect window 3600
expect samples 6
expect measured 5
expect maintenance_samples 1
expect availability 80.0
expect loss 20.0
expect loss_sent 30
expect loss_lost 6
expect wan_loss 0.0
expect rtt_p50 60.0
expect rtt_p95 70.0
expect jitter 5.0
expect wan_rtt_p50 2.0
expect overhead_ms 58.0
expect rx_avg_bps 50000
expect rx_peak_bps 100000
expect state up
expect last_rtt 70.0
expect last_loss 0.0
expect down_seconds 60
expect outages 1
expect reconnects 1
expect resolver_restarts 1
expect dns_switches 1
expect manual_actions 1
expect stable_since 10300
expect events '10300,reconnect,auto,1;10300,restored,auto,50;10250,outage,auto,noreply;10220,dns-switch,auto,https://b.example/dns-query;10210,resolver-restart,auto,-;10205,pbr-restart,manual,25'
expect quality poor
expect quality_cause tunnel
[ "$(points | wc -l | tr -d ' ')" = 60 ] || fail 'the one-hour summary does not have 60 points'
# Per-bucket loss, the worst state wins a bucket, and maintenance names the action.
points | grep -qx '10090,60.0,90.0,20.0,3.0,0.0,up,100000,10000,-' || fail 'the loss bucket is wrong'
points | grep -q '^10210,-,-,100.0,2.0,0.0,noreply,' || fail 'the silent bucket is wrong'
points | grep -q '^10090,.*,maint,' && fail 'a measured bucket was shown as maintenance'
points | grep -qx '10150,-,-,-,2.0,0.0,maint,0,0,pbr-restart' ||
	fail 'the maintenance bucket does not name its action'
"$helper" summary 24h >"$tmp/summary"
[ "$(points | wc -l | tr -d ' ')" = 96 ] || fail 'the day summary does not have 96 points'
# A fifteen-minute bucket holds the samples and shows the worst of them.
points | tail -n1 | grep -q ',noreply,' || fail 'a bucket did not keep its worst state'
"$helper" summary 2h >/dev/null 2>&1 && fail 'an unknown window was accepted'

# The verdict judges loss by the lower bound of its confidence interval: a
# few lost pings out of a few hundred are chance, a steady loss is not. Loss
# on the WAN as well puts the fault with the provider.
verdict_fixture() {
	awk -v n="$1" -v lost="$2" -v wlost="$3" 'BEGIN {
		for (i = 0; i < n; i++) {
			tr = (i < lost) ? 4 : 5; wr = (i < wlost) ? 4 : 5
			printf "%d up 5 %d 40.0 45.0 2.0 5 %d 2.0 2.0 0.0 0 0 -\n", 7000 + i * 50, tr, wr
		}
	}' >"$tmp/quality/samples"
	: >"$tmp/quality/events"
	: >"$marks"
	"$helper" summary 1h >"$tmp/summary"
}
verdict_fixture 60 3 0
expect loss 1.0
expect quality good
verdict_fixture 60 20 0
expect quality fair
expect quality_cause tunnel
verdict_fixture 60 20 20
expect quality fair
expect quality_cause wan
verdict_fixture 60 50 0
expect quality poor
verdict_fixture 2 0 0
expect quality unknown
rm -f "$tmp/quality/samples" "$tmp/quality/events" "$marks"
"$helper" summary 1h >"$tmp/summary"
expect samples 0
expect quality unknown

# The speed test: each path and direction for the time budget, the rate the
# sum of the streams' rates, time to first byte from the first request, and
# latency under load from a ping beside the tunnel download.
speed_setup() {
	setup
	mkdir -p "$tmp/quality/actions"
	for device in ipsec-out wan9; do
		printf '50000000 4.0 0.25 104.16.1.1' >"$stub/speed-$device-down"
		printf '25000000 4.0 0.1 104.16.1.1' >"$stub/speed-$device-up"
		printf '28\n' >"$stub/speed-$device-down.rc"
		printf '28\n' >"$stub/speed-$device-up.rc"
	done
	printf '50000000 1.0 0.1 104.16.1.1' >"$stub/speed-wan9-down"
	printf '0\n' >"$stub/speed-wan9-down.rc"
}
speed_value() {
	value="$(sed -n "s/^$1=//p" "$tmp/quality/speed.last")"
	[ "$value" = "$2" ] || fail "speed $1 is '$value', expected '$2'"
}
speed_setup
"$helper" _action-run 1-1 speed-test cloudflare cloudflare both 1 - - || fail 'the speed test failed'
[ "$(sed -n 's/^state=//p' "$tmp/quality/actions/1-1.status")" = ok ] || fail 'the speed test did not report ok'
[ "$(grep -c '^ipsec-out down$' "$stub/speed-calls")" = 1 ] || fail 'a timed-out tunnel request was repeated'
[ "$(grep -c '^wan9 down$' "$stub/speed-calls")" = 4 ] || fail 'a fast link was not measured over repeated requests'
[ "$(grep -c ' up$' "$stub/speed-calls")" = 2 ] || fail 'the upload was not measured on both paths'
speed_value tunnel_service cloudflare
speed_value wan_service cloudflare
speed_value direction both
speed_value streams 1
speed_value tunnel_down_bps 100000000
speed_value tunnel_down_ttfb_ms 250
speed_value tunnel_up_bps 50000000
speed_value wan_down_bps 400000000
speed_value wan_up_bps 50000000
speed_value wan_down_stalled 0
speed_value loaded_rtt 50.0
[ "$(grep -c '^loaded_rtt=' "$tmp/quality/speed.last")" = 1 ] || fail 'latency under load was measured more than once'
[ ! -e "$tmp/quality/speed.live" ] && [ ! -e "$tmp/quality/speed.step" ] ||
	fail 'the live readings outlived the test'
"$helper" summary 1h >"$tmp/summary"
expect speed_tunnel_down_bps 100000000
expect speed_wan_up_bps 50000000

# Each path has its own service. A service that takes no upload leaves that
# path's upload unavailable, not failed.
speed_setup
"$helper" _action-run 1-7 speed-test ovh cloudflare both 1 - - || fail 'a mixed choice failed'
speed_value tunnel_service ovh
speed_value wan_service cloudflare
speed_value tunnel_up_bps unavailable
speed_value wan_up_bps 50000000
[ "$(grep -c '^ipsec-out up$' "$stub/speed-calls")" = 0 ] || fail 'a download-only service was asked for an upload'

# Streams run side by side and their rates add up.
speed_setup
"$helper" _action-run 1-2 speed-test ovh ovh down 4 - - || fail 'the four-stream test failed'
[ "$(grep -c '^ipsec-out down$' "$stub/speed-calls")" = 4 ] || fail 'four streams did not run'
grep -q ' up$' "$stub/speed-calls" && fail 'a download-only test uploaded'
speed_value tunnel_down_bps 400000000
speed_value tunnel_up_bps ''

# A path that cuts the transfer after a few kilobytes is reported as cut, not
# as a slow link and not as a failure.
speed_setup
printf '16126 8.0 0.2 78.46.170.2' >"$stub/speed-wan9-down"
printf '28\n' >"$stub/speed-wan9-down.rc"
"$helper" _action-run 1-3 speed-test hetzner hetzner down 1 - - || fail 'a cut transfer failed the test'
speed_value wan_down_stalled 1
speed_value tunnel_down_stalled 0

# A service that rate-limits is reported as limiting, not as a broken path.
speed_setup
printf '1 0.1 0.1 104.16.1.1 429' >"$stub/speed-ipsec-out-down"
printf '22\n' >"$stub/speed-ipsec-out-down.rc"
"$helper" _action-run 1-8 speed-test cloudflare selectel down 4 - - && fail 'a rate-limited test reported success'
grep -q '^message=The test service is limiting requests from this router. Pick another service or try again later.$' \
	"$tmp/quality/actions/1-8.status" || fail 'the rate limit is not reported'
speed_value tunnel_down_bps limited
speed_value wan_down_bps 1600000000

# A FakeIP answer makes the comparison meaningless.
speed_setup
printf '50000000 4.0 0.25 198.18.0.7' >"$stub/speed-ipsec-out-down"
"$helper" _action-run 1-4 speed-test cloudflare cloudflare down 1 - - && fail 'a FakeIP answer was accepted'
grep -q '^message=The test host resolved to a FakeIP address.$' "$tmp/quality/actions/1-4.status" ||
	fail 'the FakeIP refusal is not reported'
[ ! -e "$tmp/quality/speed.last" ] || fail 'a refused test was stored'

# No tunnel, no test; an HTTP error is a failure, not a zero result.
speed_setup
: >"$stub/sas"
"$helper" _action-run 1-5 speed-test cloudflare cloudflare down 1 - - && fail 'a speed test ran without a tunnel'
grep -q '^message=The outbound tunnel is not connected.$' "$tmp/quality/actions/1-5.status" ||
	fail 'the missing tunnel is not reported'
[ ! -e "$stub/speed-calls" ] || fail 'a download started without a tunnel'
printf '%s\n' "$installed_sa" >"$stub/sas"
printf '22\n' >"$stub/speed-ipsec-out-down.rc"
"$helper" _action-run 1-6 speed-test cloudflare cloudflare down 1 - - && fail 'an HTTP error was accepted'
grep -q '^message=The transfer through the tunnel failed.$' "$tmp/quality/actions/1-6.status" ||
	fail 'the failed tunnel transfer is not reported'

# While a test runs its status carries the live CPU load and rate; once it has
# finished it does not.
setup
mkdir -p "$tmp/quality/actions"
printf 'action_id=2-1\nstate=running\nmessage=Measuring the tunnel download...\n' >"$tmp/quality/actions/2-1.status"
printf 'live_cpu=63\nlive_bps=150000000\n' >"$tmp/quality/speed.live"
printf 'path=tunnel\ndevice=ipsec-out\ndirection=down\n' >"$tmp/quality/speed.step"
"$helper" action-status 2-1 >"$tmp/summary"
expect live_cpu 63
expect live_bps 150000000
expect live_path tunnel
expect live_direction down
printf 'action_id=2-1\nstate=ok\n' >"$tmp/quality/actions/2-1.status"
"$helper" action-status 2-1 | grep -q '^live_' && fail 'a finished test still reports live readings'

# The choice is checked before anything runs, remembered, and passed on.
setup
"$helper" speed-test-async ovh ovh up 1 >/dev/null 2>&1 && fail 'an upload was accepted with no service that takes one'
"$helper" speed-test-async cloudflare cloudflare down 3 >/dev/null 2>&1 && fail 'an odd stream count was accepted'
"$helper" speed-test-async nowhere cloudflare down 1 >/dev/null 2>&1 && fail 'an unknown service was accepted'
"$helper" speed-test-async custom ovh down 1 'ftp://x/y' - >/dev/null 2>&1 && fail 'a non-http address was accepted'
"$helper" speed-test-async ovh custom down 1 - 'https://a.example/f;rm' >/dev/null 2>&1 &&
	fail 'an address with shell characters was accepted'
[ ! -e "$stub/started" ] || fail 'a refused choice started a test'
"$helper" speed-test-async custom selectel down 8 'https://files.example/1GB.bin' 'https://ignored.example/x' |
	grep -q '^action_id=' || fail 'a valid choice did not start'
grep -q '_action-run .* speed-test custom selectel down 8 https://files.example/1GB.bin -$' "$stub/started" ||
	fail "the choice was not passed on: $(cat "$stub/started")"
"$helper" summary 1h >"$tmp/summary"
expect speed_setting_tunnel_service custom
expect speed_setting_wan_service selectel
expect speed_setting_streams 8
expect speed_setting_tunnel_url https://files.example/1GB.bin
# A choice stored before the paths were separate applies to both.
setup
printf 'client=client\nclient.enabled=1\nquality=quality\nquality.speed_service=ovh\n' >"$tmp/uci/ikev2-manager"
"$helper" summary 1h >"$tmp/summary"
expect speed_setting_tunnel_service ovh
expect speed_setting_wan_service ovh

# A second test is refused before it can overwrite the running one's choice.
mkdir -p "$tmp/quality/speed.lock"
sleep 30 &
printf '%s\n' "$!" >"$tmp/quality/speed.lock/pid"
"$helper" speed-test-async cloudflare cloudflare up 1 >/dev/null 2>&1 && fail 'a second speed test was accepted'
kill "$!" 2>/dev/null || :
"$helper" summary 1h >"$tmp/summary"
expect speed_setting_tunnel_service ovh

"$helper" action-status '../x' >/dev/null 2>&1 && fail 'a path was accepted as an action id'

# That the watcher samples detached and through router actions is checked on
# the running watcher by scripts/test-health-loop.sh.

printf '%s\n' 'tunnel quality ok'
