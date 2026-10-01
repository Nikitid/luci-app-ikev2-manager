#!/bin/sh
# Outbound tunnel quality: one sample a minute from the health watcher, a
# summary of a window for the pages, and an on-demand speed comparison of the
# tunnel against the direct WAN path.
#
# History lives in /var/run: it costs no flash writes and starts empty after a
# reboot. A day at one sample a minute is about 100 KB.

set -u

# rpcd hands a page's environment to the helper unchanged, so the IKEV2_*
# overrides below would let any LuCI session redirect what this root helper
# runs. They are for the test suites; where the package is installed they are
# dropped and the standard search path is used.
if [ -e /usr/share/ikev2-manager/version ]; then
	PATH=/usr/sbin:/usr/bin:/sbin:/bin
	unset TMPDIR
	for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$ikev2_override"
	done
fi

runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
quality_dir="${IKEV2_QUALITY_DIR:-/var/run/ikev2-quality}"
samples_file="$quality_dir/samples"
events_file="$quality_dir/events"
sample_state="$quality_dir/sample.state"
speed_file="$quality_dir/speed.last"
sample_lock="$quality_dir/sample.lock"
speed_lock="$quality_dir/speed.lock"
speed_step_file="$quality_dir/speed.step"
speed_live_file="$quality_dir/speed.live"
action_status_file="$quality_dir/action.status"
action_status_dir="$quality_dir/actions"
net_dir="${IKEV2_NET_DIR:-/sys/class/net}"
tunnel_if='ipsec-out'
ping_targets="${IKEV2_QUALITY_PING_TARGETS:-1.1.1.1 8.8.8.8}"
ping_count=5
speed_seconds=8
sample_keep=1440
event_keep=200

. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/tunnel.sh"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

state_value() {
	sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1
}

state_number() {
	local value
	value="$(state_value "$1" "$2")"
	case "$value" in '' | *[!0-9]*) value=0 ;; esac
	printf '%s\n' "$value"
}

# The router's own default route is the WAN. Reading it from the main table
# works whatever the WAN interface is called.
wan_device() {
	ip -4 route show table main default 2>/dev/null |
		awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

# Print "sent received avg max jitter" for pings bound to one device, with "-"
# for the timings when nothing came back. BusyBox prints no deviation, so the
# replies are read one by one; jitter is the mean change between consecutive
# replies. The second target is tried only when the first answers nothing, so a
# provider that drops ICMP to one address does not read as a dead tunnel.
ping_stats() {
	local device="$1" target result
	result="0 0 - - -"
	[ -n "$device" ] || { printf '%s\n' "$result"; return 0; }
	for target in $ping_targets; do
		result="$(ping -4 -c "$ping_count" -W 1 -w $((ping_count + 2)) \
			-I "$device" "$target" 2>/dev/null | awk -v sent="$ping_count" '
			/DUP!/ { next }
			/ time=/ {
				v = $0; sub(/.* time=/, "", v); sub(/[^0-9.].*/, "", v)
				v += 0; n++; sum += v; if (v > max) max = v
				if (n > 1) { d = v - prev; if (d < 0) d = -d; jit += d }
				prev = v
			}
			/packets transmitted/ { sent = $1 + 0 }
			END {
				if (n) printf "%d %d %.1f %.1f %.1f\n", sent, n, sum / n, max, (n > 1 ? jit / (n - 1) : 0)
				else printf "%d 0 - - -\n", sent
			}')"
		case "$result" in *' 0 - - -') ;; *) break ;; esac
	done
	printf '%s\n' "$result"
}

counter() {
	local value
	value="$(cat "$net_dir/$tunnel_if/statistics/$1" 2>/dev/null || true)"
	case "$value" in '' | *[!0-9]*) value=- ;; esac
	printf '%s\n' "$value"
}

child_installed() {
	"${IKEV2_SA_HELPER:-/usr/libexec/ikev2-sa}" installed proxy-out proxy4
}

add_event() {
	printf '%s %s %s\n' "$1" "$2" "${3:--}" >>"$events_file"
}

trim_file() {
	local file="$1" keep="$2" lines
	[ -f "$file" ] || return 0
	lines="$(wc -l <"$file" 2>/dev/null || echo 0)"
	[ "$lines" -gt $((keep + keep / 10)) ] || return 0
	tail -n "$keep" "$file" >"${file}.new" && mv "${file}.new" "$file"
}

# The action that was running between FROM and TO, if any: one whose window
# overlaps that span. A window still open counts only while the action that
# opened it is alive, so a runner killed before its EXIT trap cannot turn every
# later sample into maintenance.
maintenance_during() {
	local from="$1" to="$2" kind open pid
	[ -s "$quality_marks_file" ] || return 0
	awk -v from="$from" -v to="$to" '
		$2 == "begin" { begin[$5 " " $3] = $1; next }
		$2 == "end" {
			key = $5 " " $3
			if (key in begin) {
				if (begin[key] <= to && $1 >= from) printf "%s 0 %s\n", $3, $5
				delete begin[key]
			}
		}
		END {
			for (key in begin)
				if (begin[key] <= to) { split(key, k, " "); printf "%s 1 %s\n", k[2], k[1] }
		}' "$quality_marks_file" 2>/dev/null | while read -r kind open pid; do
		if [ "$open" = 0 ] || kill -0 "$pid" 2>/dev/null; then
			printf '%s\n' "$kind"
			break
		fi
	done
}

# Marks older than the history are dropped. Writers append under the same
# lock, so none of their lines is lost between the read and the rename.
trim_marks() {
	local cutoff="$1"
	[ -s "$quality_marks_file" ] || return 0
	(
		flock -x 9 || exit 0
		awk -v cutoff="$cutoff" '$1 >= cutoff' "$quality_marks_file" >"${quality_marks_file}.new" &&
			mv "${quality_marks_file}.new" "$quality_marks_file"
	) 9>>"${quality_marks_file}.lock"
}

# IKE rekeys replace the SA unique id every few hours, so a changed id is not a
# reconnect. charon logs a new SA as "established" and a rekey as "rekeyed";
# print the time of each new one logged after SINCE, the previous sample. The
# time comes from the log line, so a reconnect can be matched against the
# action that caused it. Only the last messages are read: the whole ring
# buffer took four to five seconds of CPU on every sample of a busy router,
# and a minute never fills two thousand messages.
new_connections() {
	local since="$1" stamp at
	command -v logread >/dev/null 2>&1 || return 0
	logread -l 2000 2>/dev/null | grep 'IKE_SA proxy-out\[[0-9]*\] established between' |
		awk '
			BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (i = 1; i <= 12; i++) mon[m[i]] = i }
			{ printf "%s-%02d-%02d %s\n", $5, mon[$2], $3, $4 }' | while read -r stamp; do
		at="$(date -d "$stamp" +%s 2>/dev/null || echo 0)"
		[ "$at" -gt "$since" ] 2>/dev/null && printf 'new %s\n' "$at"
	done
	return 0
}

take_sample() {
	local now started finished client state tun wan wan_pid tun_recv rx tx previous down_since
	local since output maintenance at
	mkdir -p "$quality_dir"
	now="$(date +%s)"
	client="$(uci -q get ikev2-manager.client.enabled || echo 0)"
	tun="0 0 - - -"
	# Both paths take the ping time; measure them side by side.
	ping_stats "$(wan_device)" >"$quality_dir/wan.$$" &
	wan_pid=$!
	if [ "$client" != 1 ]; then
		state=off
	elif ! child_installed || [ ! -d "$net_dir/$tunnel_if" ]; then
		state=down
	else
		tun="$(ping_stats "$tunnel_if")"
		tun_recv="$(printf '%s\n' "$tun" | awk '{ print $2 }')"
		state=up
		# No ICMP reply is not proof of a dead tunnel: the far end may filter it.
		# Only a failed HTTPS request through the same device is.
		if [ "$tun_recv" = 0 ] && ! tunnel_https_reachable 2 3; then
			state=noreply
		fi
	fi
	wait "$wan_pid" 2>/dev/null || :
	wan="$(cat "$quality_dir/wan.$$" 2>/dev/null)"
	rm -f "$quality_dir/wan.$$"
	[ -n "$wan" ] || wan="0 0 - - -"
	finished="$(date +%s)"
	rx="$(counter rx_bytes)"
	tx="$(counter tx_bytes)"
	# A sample taken while an operator's action was running is its effect, not
	# the tunnel's: record which action it was.
	maintenance="$(maintenance_during "$now" "$finished")"
	printf '%s %s %s %s %s %s %s\n' "$now" "$state" "$tun" "$wan" "$rx" "$tx" \
		"${maintenance:--}" >>"$samples_file"
	trim_file "$samples_file" "$sample_keep"

	# The previous state carries across maintenance, so an action that took the
	# tunnel down and brought it back is neither an outage nor a restore.
	previous="$(state_value "$sample_state" state)"
	down_since="$(state_number "$sample_state" down_since)"
	if [ -z "$maintenance" ]; then
		case "$previous:$state" in
			up:down | up:noreply)
				add_event "$now" outage "$state"
				down_since="$now"
				;;
			down:up | noreply:up)
				add_event "$now" restored "$((now - down_since))"
				down_since=0
				;;
		esac
	else
		state="$previous"
	fi

	# The first sample only places the mark: what the log holds from before it
	# is not news.
	since="$(state_number "$sample_state" log_since)"
	[ "$since" -gt 0 ] || since="$now"
	output="$(new_connections "$since")"
	# A reconnect inside an action's window is that action; it has its own mark.
	printf '%s\n' "$output" | sed -n 's/^new //p' | while read -r at; do
		[ -n "$(maintenance_during "$at" "$at")" ] || add_event "$at" reconnect 1
	done
	trim_file "$events_file" "$event_keep"
	trim_marks $((now - 86400))

	{
		printf 'state=%s\n' "$state"
		printf 'down_since=%s\n' "$down_since"
		printf 'log_since=%s\n' "$now"
	} >"${sample_state}.new"
	mv "${sample_state}.new" "$sample_state"
}

sample() {
	mkdir -p "$quality_dir"
	pid_lock_acquire "$sample_lock" || return 0
	trap 'pid_lock_release "$sample_lock"' EXIT
	take_sample
}

percentile() {
	sort -n "$1" | awk -v p="$2" '
		{ v[NR] = $1 }
		END {
			if (!NR) { print "-"; exit }
			i = int((NR - 1) * p / 100 + 0.5) + 1
			printf "%.1f\n", v[i]
		}'
}

# Every event of the window as "time kind source detail": the sampler's own
# (outages, restores, reconnects) and the marks actions wrote. A window is
# reported once, when it ends, with how long it lasted.
window_events() {
	local start="$1"
	{
		[ ! -f "$events_file" ] ||
			awk -v start="$start" '$1 >= start { print $1, $2, "auto", $3 }' "$events_file"
		[ ! -f "$quality_marks_file" ] ||
			awk -v start="$start" '
				$2 == "begin" { begin[$5 " " $3] = $1; next }
				$1 < start { next }
				$2 == "end" {
					key = $5 " " $3
					print $1, $3, $4, (key in begin) ? $1 - begin[key] : "-"
					delete begin[key]
				}
				$2 == "event" { print $1, $3, $4, $6 }' "$quality_marks_file"
	} 2>/dev/null | sort -n -s
}

# Summarise the last WINDOW seconds in POINTS buckets. Loss is lost replies
# over sent requests, not an average of per-sample percentages. Availability
# counts every sample the tunnel was meant to be up. A sample taken during an
# operator's action counts for neither: its bucket shows the action instead.
# Traffic is the change of the device counters between consecutive samples; a
# counter that went back means the device was recreated and that step is
# skipped.
summary() {
	local window="$1" points="$2" now start work rtt_p50 wan_p50 unstable_at stable_since last_reconnect
	now="$(date +%s)"
	start=$((now - window))
	work="$(mktemp -d)" || die 'Unable to create a temporary directory'
	summary_work="$work"
	trap 'rm -rf "$summary_work"' EXIT
	window_events "$start" >"$work/events"
	awk -v start="$start" -v window="$window" -v points="$points" \
		-v rtt="$work/rtt" -v wrtt="$work/wan-rtt" '
		function rank(s) { return s == "down" ? 4 : s == "noreply" ? 3 : s == "maint" ? 2 : s == "up" ? 1 : 0 }
		function fmt(v) { return v == "" ? "-" : sprintf("%.1f", v) }
		{
			ts = $1 + 0
			if ($13 != "-" && prev_ts && ts - prev_ts > 0 && ts - prev_ts <= 180 &&
			    $13 >= prev_rx && $14 >= prev_tx) {
				dt = ts - prev_ts; rx_rate = ($13 - prev_rx) * 8 / dt; tx_rate = ($14 - prev_tx) * 8 / dt
				have_rate = 1
			} else
				have_rate = 0
			if ($13 != "-") { prev_ts = ts; prev_rx = $13; prev_tx = $14 } else prev_ts = 0
			if (ts < start) next
			samples++
			maint = ($15 != "" && $15 != "-")
			state = maint ? "maint" : $2
			b = int((ts - start) * points / window); if (b >= points) b = points - 1
			if (rank(state) > rank(bstate[b])) bstate[b] = state
			if (bstate[b] == "") bstate[b] = state
			if (maint && bmaint[b] == "") bmaint[b] = $15
			if ($8 > 0) { wsent += $8; wrecv += $9; bwsent[b] += $8; bwrecv[b] += $9 }
			if ($10 != "-") { print $10 > wrtt; bwrtt[b] += $10; bwn[b]++ }
			if (have_rate) {
				rx_sum += rx_rate; tx_sum += tx_rate; rn++
				if (rx_rate > rx_peak) rx_peak = rx_rate
				brx[b] += rx_rate; btx[b] += tx_rate; bn[b]++
			}
			if (maint) { maintained++; last_ts = ts; next }
			last = $0
			if (state != "off") measured++
			if (state == "up") up++
			if (state == "down" || state == "noreply") down_s += (last_ts ? ts - last_ts : 60)
			if (state != "up" && state != "off") unstable_at = ts
			if ($3 > 0) { sent += $3; recv += $4; bsent[b] += $3; brecv[b] += $4 }
			if ($5 != "-") {
				print $5 > rtt; jit += $7; jn++
				brtt[b] += $5; brn[b]++; if ($6 > bmax[b]) bmax[b] = $6
			}
			last_ts = ts
			if (!first_up && state == "up") first_up = ts
		}
		END {
			printf "samples=%d\nmeasured=%d\nmaintenance_samples=%d\n", samples, measured, maintained
			printf "availability=%s\n", measured ? sprintf("%.1f", up * 100 / measured) : "-"
			printf "down_seconds=%d\n", down_s
			printf "loss=%s\n", sent ? sprintf("%.1f", (sent - recv) * 100 / sent) : "-"
			printf "loss_sent=%d\nloss_lost=%d\n", sent, sent - recv
			printf "wan_loss=%s\n", wsent ? sprintf("%.1f", (wsent - wrecv) * 100 / wsent) : "-"
			printf "wan_sent=%d\nwan_lost=%d\n", wsent, wsent - wrecv
			printf "jitter=%s\n", jn ? sprintf("%.1f", jit / jn) : "-"
			printf "rx_avg_bps=%s\ntx_avg_bps=%s\nrx_peak_bps=%s\n", rn ? int(rx_sum / rn) : "-", rn ? int(tx_sum / rn) : "-", rn ? int(rx_peak) : "-"
			split(last, l, " ")
			printf "state=%s\nlast_sample=%s\n", (last != "" ? l[2] : (samples ? "maint" : "none")), (last != "" ? l[1] : "-")
			printf "last_rtt=%s\n", (last != "" ? l[5] : "-")
			# A bare ">" inside printf arguments is an output redirection.
			printf "last_loss=%s\n", ((last != "" && l[3] > 0) ? sprintf("%.1f", (l[3] - l[4]) * 100 / l[3]) : "-")
			printf "unstable_at=%s\nfirst_up=%s\n", unstable_at ? unstable_at : "-", first_up ? first_up : "-"
			out = ""
			step = window / points
			for (i = 0; i < points; i++) {
				t = int(start + i * step)
				if (bstate[i] == "") { p = t ",-,-,-,-,-,none,-,-,-" }
				else {
					p = t "," (brn[i] ? fmt(brtt[i] / brn[i]) : "-") "," (brn[i] ? fmt(bmax[i]) : "-") \
						"," (bsent[i] ? fmt((bsent[i] - brecv[i]) * 100 / bsent[i]) : "-") \
						"," (bwn[i] ? fmt(bwrtt[i] / bwn[i]) : "-") \
						"," (bwsent[i] ? fmt((bwsent[i] - bwrecv[i]) * 100 / bwsent[i]) : "-") \
						"," bstate[i] "," (bn[i] ? int(brx[i] / bn[i]) : "-") "," (bn[i] ? int(btx[i] / bn[i]) : "-") \
						"," (bmaint[i] != "" ? bmaint[i] : "-")
				}
				out = out (i ? ";" : "") p
			}
			printf "points=%s\n", out
		}' "$samples_file" 2>/dev/null >"$work/summary" || : >"$work/summary"
	: >>"$work/rtt"
	: >>"$work/wan-rtt"
	[ -s "$work/summary" ] || printf 'samples=0\nmeasured=0\nstate=none\n' >"$work/summary"

	printf 'window=%s\ngenerated=%s\n' "$window" "$now"
	grep -v '^unstable_at=\|^first_up=' "$work/summary"
	rtt_p50="$(percentile "$work/rtt" 50)"
	printf 'rtt_p50=%s\nrtt_p95=%s\n' "$rtt_p50" "$(percentile "$work/rtt" 95)"
	wan_p50="$(percentile "$work/wan-rtt" 50)"
	printf 'wan_rtt_p50=%s\n' "$wan_p50"
	if [ "$rtt_p50" != - ] && [ "$wan_p50" != - ]; then
		printf 'overhead_ms=%s\n' "$(awk -v a="$rtt_p50" -v b="$wan_p50" 'BEGIN { printf "%.1f", a - b }')"
	else
		printf 'overhead_ms=-\n'
	fi

	# The tunnel has been stable since the first sample after the last bad one.
	unstable_at="$(sed -n 's/^unstable_at=//p' "$work/summary")"
	if [ "${unstable_at:--}" = - ]; then
		stable_since="$(sed -n 's/^first_up=//p' "$work/summary")"
	else
		stable_since="$(awk -v after="$unstable_at" '$1 > after && $2 == "up" { print $1; exit }' "$samples_file" 2>/dev/null)"
	fi
	# A reconnect nobody asked for breaks the stable run as well.
	last_reconnect="$(awk '$2 == "reconnect" { t = $1 } END { if (t) print t }' "$work/events")"
	if [ -n "$last_reconnect" ] && [ "${stable_since:--}" != - ] && [ "$last_reconnect" -gt "$stable_since" ]; then
		stable_since="$last_reconnect"
	fi
	printf 'stable_since=%s\n' "${stable_since:--}"

	awk '
		$2 == "outage" { outages++ }
		$2 == "reconnect" { reconnects += $4 }
		$2 == "resolver-restart" { restarts++ }
		$2 == "dns-switch" { switches++ }
		$3 == "manual" { manual++ }
		END { printf "outages=%d\nreconnects=%d\nresolver_restarts=%d\ndns_switches=%d\nmanual_actions=%d\n", outages, reconnects, restarts, switches, manual }
	' "$work/events"
	# Newest first, at most twenty.
	printf 'events=%s\n' "$(awk '{ print $1 "," $2 "," $3 "," $4 }' "$work/events" |
		tail -n 20 | sed -n '1!G;h;$p' | tr '\n' ';' | sed 's/;$//')"

	quality_verdict "$work/summary" "$window" "$work/events"

	[ ! -s "$speed_file" ] || sed -n 's/^\([a-z_0-9]*\)=/speed_\1=/p' "$speed_file"
	# A choice stored before each path had its own service applies to both.
	printf 'speed_setting_tunnel_service=%s\n' "$(speed_setting tunnel_service "$(speed_setting service cloudflare)")"
	printf 'speed_setting_wan_service=%s\n' "$(speed_setting wan_service "$(speed_setting service cloudflare)")"
	printf 'speed_setting_tunnel_url=%s\n' "$(speed_setting tunnel_url "$(speed_setting url '')")"
	printf 'speed_setting_wan_url=%s\n' "$(speed_setting wan_url "$(speed_setting url '')")"
	printf 'speed_setting_direction=%s\n' "$(speed_setting direction down)"
	printf 'speed_setting_streams=%s\n' "$(speed_setting streams 1)"
}

# The lower bound of a 95% Wilson interval for LOST of SENT, in percent. Five
# pings a minute make one lost reply look like a 20% minute; the bound only
# rises above a threshold once the losses are too many to be chance.
wilson_awk='
	function wilson(lost, sent,   p, z, d, c, r) {
		if (sent <= 0) return 0
		p = lost / sent; z = 1.96
		d = 1 + z * z / sent
		c = p + z * z / (2 * sent)
		r = z * sqrt(p * (1 - p) / sent + z * z / (4 * sent * sent))
		return (c - r) / d * 100
	}'

# good, fair or poor from loss, availability, jitter and the reconnect rate;
# down and off follow the latest sample. The cause says whether the direct WAN
# path loses packets as well, which puts the fault with the provider.
quality_verdict() {
	local summary_file="$1" window="$2" events="$3"
	awk -v window="$window" -v events="$events" "$wilson_awk"'
		FILENAME == events { if ($2 == "reconnect") reconnects += $4; next }
		{ p = index($0, "="); v[substr($0, 1, p - 1)] = substr($0, p + 1) }
		END {
			state = v["state"]
			loss = wilson(v["loss_lost"], v["loss_sent"])
			wan = wilson(v["wan_lost"], v["wan_sent"])
			if (state == "none" || state == "") verdict = "unknown"
			else if (state == "off") verdict = "off"
			else if (state == "down" || state == "noreply") verdict = "down"
			else if (v["measured"] + 0 < 3) verdict = "unknown"
			else {
				verdict = "good"
				rate = reconnects * 3600 / window
				if (loss >= 1 || v["availability"] + 0 < 99 ||
				    (v["jitter"] != "-" && v["jitter"] + 0 >= 30) || rate >= 1)
					verdict = "fair"
				if (loss >= 5 || v["availability"] + 0 < 95)
					verdict = "poor"
			}
			cause = ""
			if (verdict == "fair" || verdict == "poor" || verdict == "down") {
				if (wan >= 1 && wan >= loss / 2) cause = "wan"
				else cause = "tunnel"
			}
			printf "loss_bound=%.1f\nquality=%s\nquality_cause=%s\n", loss, verdict, cause
		}' "$events" "$summary_file" 2>/dev/null
}

# Speed test services. The same service measures both paths with the same
# settings, or the comparison means nothing. Only Cloudflare accepts uploads.
speed_service_url() {
	case "$1:$2" in
		cloudflare:down) printf '%s\n' 'https://speed.cloudflare.com/__down?bytes=50000000' ;;
		cloudflare:up) printf '%s\n' 'https://speed.cloudflare.com/__up' ;;
		hetzner:down) printf '%s\n' 'https://fsn1-speed.hetzner.com/1GB.bin' ;;
		ovh:down) printf '%s\n' 'https://proof.ovh.net/files/1Gb.dat' ;;
		selectel:down) printf '%s\n' 'https://speedtest.selectel.ru/1GB' ;;
		custom:down) printf '%s\n' "$3" ;;
		*) return 1 ;;
	esac
}

speed_setting() {
	local value
	value="$(uci -q get "ikev2-manager.quality.speed_$1" 2>/dev/null || true)"
	printf '%s\n' "${value:-$2}"
}

valid_speed_url() {
	[ "${#1}" -le 300 ] || return 1
	printf '%s\n' "$1" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/?&=+-]*)?$'
}

# Upload payload: zeros streamed into curl, so memory stays flat whatever the
# stream count. Bounded, like a download, by the size and the time budget.
upload_request() {
	head -c 50000000 /dev/zero | curl -4 -fsS --interface "$1" -o /dev/null \
		--connect-timeout 4 --max-time "$2" -X POST -T - \
		-w '%{size_upload} %{time_total} %{time_starttransfer} %{remote_ip} %{http_code}' "$3" 2>/dev/null
}

download_request() {
	curl -4 -fsS --interface "$1" -o /dev/null --connect-timeout 4 --max-time "$2" \
		-w '%{size_download} %{time_total} %{time_starttransfer} %{remote_ip} %{http_code}' "$3" 2>/dev/null
}

# One stream: "bytes seconds ttfb remote_ip stalled limited". A request that ends on the
# time limit is the normal end on a fast link; a short one repeats while budget
# remains. A stream that ran out of time having received almost nothing did not
# measure a slow link: the path cut it, which is how a DPI box truncating a
# connection at 16-20 KB shows up.
measure_stream() {
	local device="$1" direction="$2" url="$3" started now out rc elapsed=0 runs=0 bytes=0 seconds=0 ttfb='' ip='' stalled=0 limited=0
	started="$(date +%s)"
	while [ "$runs" -lt 4 ] && [ "$elapsed" -lt "$speed_seconds" ]; do
		rc=0
		if [ "$direction" = up ]; then
			out="$(upload_request "$device" $((speed_seconds - elapsed)) "$url")" || rc=$?
		else
			out="$(download_request "$device" $((speed_seconds - elapsed)) "$url")" || rc=$?
		fi
		set -- $out
		# A service that rate-limits says so with 429; that is a refusal to
		# report, not a broken path.
		if [ "${5:-}" = 429 ]; then
			limited=1
			break
		fi
		case "$rc" in 0 | 28) ;; *) break ;; esac
		# Nothing at all is a connection that never worked, not a cut one: a
		# connect timeout ends with the same exit code.
		[ "${1:-0}" -gt 0 ] 2>/dev/null || break
		bytes=$((bytes + $1))
		seconds="$(awk -v a="$seconds" -v b="$2" 'BEGIN { print a + b }')"
		[ -n "$ttfb" ] || ttfb="$3"
		ip="$4"
		runs=$((runs + 1))
		if [ "$rc" = 28 ]; then
			[ "$bytes" -ge 65536 ] || stalled=1
			break
		fi
		now="$(date +%s)"
		elapsed=$((now - started))
	done
	printf '%s %s %s %s %s %s\n' "$bytes" "$seconds" "${ttfb:--}" "${ip:--}" "$stalled" "$limited"
}

cpu_ticks() {
	awk '/^cpu / { busy = $2 + $3 + $4 + $7 + $8; print busy, busy + $5 + $6; exit }' /proc/stat 2>/dev/null
}

# Measure one path in one direction with STREAMS parallel streams. Prints
# "bits_per_second ttfb_ms remote_ip stalled cpu_percent limited"; the rate is
# the sum of the streams' own rates. Fails when no stream received anything and
# none was cut or refused, which is a connection that never worked.
measure_path() {
	local device="$1" direction="$2" url="$3" streams="$4" i before after work
	work="$quality_dir/speed.$$"
	rm -rf "$work"
	mkdir -p "$work"
	before="$(cpu_ticks)"
	i=0
	while [ "$i" -lt "$streams" ]; do
		measure_stream "$device" "$direction" "$url" >"$work/$i" &
		i=$((i + 1))
	done
	wait
	after="$(cpu_ticks)"
	cat "$work"/* 2>/dev/null | awk -v before="$before" -v after="$after" '
		{
			if ($1 > 0 && $2 > 0) { rate += $1 * 8 / $2; got = 1 }
			if ($3 != "-" && (ttfb == "" || $3 < ttfb)) ttfb = $3
			if ($4 != "-") ip = $4
			if ($5 == 1) stalled = 1
			if ($6 == 1) limited = 1
		}
		END {
			split(before, b, " "); split(after, a, " ")
			cpu = (a[2] > b[2]) ? (a[1] - b[1]) * 100 / (a[2] - b[2]) : -1
			if (!got && !stalled && !limited) exit 1
			printf "%d %s %s %d %s %d\n", rate, (ttfb == "" ? "-" : int(ttfb * 1000)), (ip == "" ? "-" : ip), stalled, (cpu < 0 ? "-" : int(cpu + 0.5)), limited
		}'
	i=$?
	rm -rf "$work"
	return "$i"
}

fake_address() {
	case "$1" in 198.18.* | 198.19.*) return 0 ;; esac
	return 1
}

service_uploads() {
	[ "$1" = cloudflare ]
}

# Once a second while a test runs: the router's CPU load and the rate on the
# device being measured, for the page to show live. The device counters count
# everything on that device, which is the point: the router serves its clients
# while it tests.
speed_monitor() {
	local before after rx0 tx0 rx1 tx1 device direction
	before="$(cpu_ticks)"
	while :; do
		device="$(sed -n 's/^device=//p' "$speed_step_file" 2>/dev/null)"
		direction="$(sed -n 's/^direction=//p' "$speed_step_file" 2>/dev/null)"
		rx0="$(cat "$net_dir/$device/statistics/rx_bytes" 2>/dev/null || echo 0)"
		tx0="$(cat "$net_dir/$device/statistics/tx_bytes" 2>/dev/null || echo 0)"
		sleep 1
		after="$(cpu_ticks)"
		rx1="$(cat "$net_dir/$device/statistics/rx_bytes" 2>/dev/null || echo 0)"
		tx1="$(cat "$net_dir/$device/statistics/tx_bytes" 2>/dev/null || echo 0)"
		awk -v before="$before" -v after="$after" -v rx="$((rx1 - rx0))" -v tx="$((tx1 - tx0))" \
			-v direction="$direction" 'BEGIN {
				split(before, b, " "); split(after, a, " ")
				cpu = (a[2] > b[2]) ? (a[1] - b[1]) * 100 / (a[2] - b[2]) : 0
				printf "live_cpu=%d\nlive_bps=%d\n", cpu + 0.5, (direction == "up" ? tx : rx) * 8
			}' >"${speed_live_file}.new" 2>/dev/null && mv "${speed_live_file}.new" "$speed_live_file"
		before="$after"
	done
}

# Each path has its own service, so the tunnel can be measured against a
# server abroad and the WAN against one near the provider. Only Cloudflare
# takes an upload; a path whose service does not is reported as unavailable
# for that direction rather than failed.
speed_test() {
	local id="$1" tunnel_service="$2" wan_service="$3" direction="$4" streams="$5"
	local tunnel_url="${6:--}" wan_url="${7:--}" wan loaded loaded_pid
	local path device dir result failed='' limited='' directions key service url loaded_done=0
	if ! pid_lock_acquire "$speed_lock"; then
		action_status "$id" error 'A speed test is already running.'
		return 1
	fi
	# Global, not local: the EXIT trap runs after this function has returned.
	speed_monitor_pid=''
	trap 'pid_lock_release "$speed_lock"; [ -z "$speed_monitor_pid" ] || { kill "$speed_monitor_pid" 2>/dev/null; wait "$speed_monitor_pid" 2>/dev/null; }; rm -rf "$quality_dir/speed.$$" "$speed_step_file" "$speed_live_file" "${speed_live_file}.new"' EXIT
	if [ "$(uci -q get ikev2-manager.client.enabled || echo 0)" != 1 ] ||
	   ! child_installed || [ ! -d "$net_dir/$tunnel_if" ]; then
		action_status "$id" error 'The outbound tunnel is not connected.'
		return 1
	fi
	wan="$(wan_device)"
	[ -n "$wan" ] || { action_status "$id" error 'The router has no default route.'; return 1; }
	case "$direction" in both) directions='down up' ;; *) directions="$direction" ;; esac

	printf 'checked=%s\ntunnel_service=%s\nwan_service=%s\ndirection=%s\nstreams=%s\n' \
		"$(date +%s)" "$tunnel_service" "$wan_service" "$direction" "$streams" >"$quality_dir/speed.result"
	speed_monitor </dev/null >/dev/null 2>&1 &
	speed_monitor_pid=$!
	for path in tunnel wan; do
		if [ "$path" = tunnel ]; then
			device="$tunnel_if" service="$tunnel_service" url="$tunnel_url"
		else
			device="$wan" service="$wan_service" url="$wan_url"
		fi
		for dir in $directions; do
			key="${path}_${dir}"
			if [ "$dir" = up ] && ! service_uploads "$service"; then
				printf '%s_bps=unavailable\n' "$key" >>"$quality_dir/speed.result"
				continue
			fi
			printf 'path=%s\ndevice=%s\ndirection=%s\n' "$path" "$device" "$dir" >"$speed_step_file"
			action_status "$id" running "$(speed_step_message "$path" "$dir")"
			# Latency while the link is saturated shows buffering that idle
			# pings miss: measured beside the first tunnel transfer.
			loaded_pid=''
			if [ "$path" = tunnel ] && [ "$loaded_done" = 0 ]; then
				ping_stats "$tunnel_if" >"$quality_dir/loaded.$$" &
				loaded_pid=$!
				loaded_done=1
			fi
			result="$(measure_path "$device" "$dir" "$(speed_service_url "$service" "$dir" "$url")" "$streams")" || result=''
			if [ -n "$loaded_pid" ]; then
				wait "$loaded_pid" 2>/dev/null || :
				loaded="$(awk '{ print $3 }' "$quality_dir/loaded.$$" 2>/dev/null)"
				rm -f "$quality_dir/loaded.$$"
				printf 'loaded_rtt=%s\n' "${loaded:--}" >>"$quality_dir/speed.result"
			fi
			if [ -z "$result" ]; then
				failed="${failed:+$failed }$key"
				printf '%s_bps=-\n' "$key" >>"$quality_dir/speed.result"
				continue
			fi
			set -- $result
			if [ "$6" = 1 ] && [ "$1" = 0 ]; then
				limited="${limited:+$limited }$key"
				printf '%s_bps=limited\n' "$key" >>"$quality_dir/speed.result"
				continue
			fi
			# A FakeIP answer means the router resolved the test host through
			# the tunnel's own DNS, and the comparison would be meaningless.
			if fake_address "$3"; then
				rm -f "$quality_dir/speed.result"
				action_status "$id" error 'The test host resolved to a FakeIP address.'
				return 1
			fi
			printf '%s_bps=%s\n%s_ttfb_ms=%s\n%s_stalled=%s\n%s_cpu=%s\n' \
				"$key" "$1" "$key" "$2" "$key" "$4" "$key" "$5" >>"$quality_dir/speed.result"
		done
	done
	mv "$quality_dir/speed.result" "$speed_file"
	if [ -n "$limited" ] && [ -z "$failed" ]; then
		action_status "$id" error 'The test service is limiting requests from this router. Pick another service or try again later.'
		return 1
	fi
	case "$failed" in
		'') action_status "$id" ok 'Speed test finished' ;;
		tunnel_*) action_status "$id" error 'The transfer through the tunnel failed.' ;;
		*) action_status "$id" error 'The tunnel was measured, the direct transfer failed.' ;;
	esac
	[ -z "$failed" ]
}

speed_step_message() {
	case "$1:$2" in
		tunnel:down) printf '%s\n' 'Measuring the tunnel download...' ;;
		tunnel:up) printf '%s\n' 'Measuring the tunnel upload...' ;;
		wan:down) printf '%s\n' 'Measuring the direct download...' ;;
		*) printf '%s\n' 'Measuring the direct upload...' ;;
	esac
}

valid_speed_service() {
	case "$1" in cloudflare | hetzner | ovh | selectel | custom) return 0 ;; esac
	return 1
}

# Check the choice, remember it for the next visit, then start the test. A URL
# is "-" when its path does not use a custom file.
speed_test_start() {
	local tunnel_service="$1" wan_service="$2" direction="$3" streams="$4"
	local tunnel_url="${5:--}" wan_url="${6:--}" path service url
	valid_speed_service "$tunnel_service" && valid_speed_service "$wan_service" ||
		die 'Unknown speed test service'
	case "$direction" in down | up | both) ;; *) die 'Expected direction: down, up or both' ;; esac
	case "$streams" in 1 | 4 | 8) ;; *) die 'Expected 1, 4 or 8 streams' ;; esac
	[ "$direction" = down ] || service_uploads "$tunnel_service" || service_uploads "$wan_service" ||
		die 'Upload is available with Cloudflare only'
	for path in tunnel wan; do
		if [ "$path" = tunnel ]; then service="$tunnel_service" url="$tunnel_url"; else service="$wan_service" url="$wan_url"; fi
		if [ "$service" = custom ]; then
			valid_speed_url "$url" || die 'Enter an http:// or https:// address of a large file'
		elif [ "$path" = tunnel ]; then
			tunnel_url=-
		else
			wan_url=-
		fi
	done
	# Refuse a second test here, before the choice is stored: the page shows
	# the refusal at once, and the running test's settings stay as they were.
	mkdir -p "$quality_dir"
	! pid_lock_busy "$speed_lock" || die 'A speed test is already running.'
	uci -q get ikev2-manager.quality >/dev/null 2>&1 || uci set ikev2-manager.quality=quality
	uci set ikev2-manager.quality.speed_tunnel_service="$tunnel_service"
	uci set ikev2-manager.quality.speed_wan_service="$wan_service"
	uci set ikev2-manager.quality.speed_direction="$direction"
	uci set ikev2-manager.quality.speed_streams="$streams"
	[ "$tunnel_url" = - ] || uci set ikev2-manager.quality.speed_tunnel_url="$tunnel_url"
	[ "$wan_url" = - ] || uci set ikev2-manager.quality.speed_wan_url="$wan_url"
	uci commit ikev2-manager
	mkdir -p "$action_status_dir"
	start_action speed-test "$tunnel_service" "$wan_service" "$direction" "$streams" "$tunnel_url" "$wan_url"
}

run_action() {
	local id="$1" kind="$2"
	shift 2
	case "$kind" in
		speed-test) speed_test "$id" "$@" ;;
		*) action_status "$id" error 'Unknown action.'; return 1 ;;
	esac
}

window_seconds() {
	case "$1" in
		1h) printf '3600 60\n' ;;
		6h) printf '21600 72\n' ;;
		24h) printf '86400 96\n' ;;
		*) return 1 ;;
	esac
}

case "${1:-}" in
	sample)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		sample
		;;
	summary)
		[ "$#" -le 2 ] || die 'Expected: summary [1h|6h|24h]'
		spec="$(window_seconds "${2:-1h}")" || die 'Expected: summary [1h|6h|24h]'
		set -- $spec
		summary "$1" "$2"
		;;
	speed-test-async)
		[ "$#" -ge 5 ] && [ "$#" -le 7 ] ||
			die 'Expected: speed-test-async tunnel_service wan_service down|up|both 1|4|8 [tunnel_url|-] [wan_url|-]'
		shift
		speed_test_start "$@"
		;;
	_action-run)
		[ "$#" -ge 3 ] || die 'Expected: _action-run id kind'
		mkdir -p "$quality_dir" "$action_status_dir"
		shift
		run_action "$@"
		;;
	action-status)
		if [ -n "${2:-}" ]; then
			case "$2" in *[!0-9-]*) die 'Invalid action id' ;; esac
			cat "$action_status_dir/$2.status" 2>/dev/null || printf 'state=idle\n'
			# While a test runs, the live CPU load and rate ride along, so the
			# page's poll of the action carries them without a second call.
			if grep -q '^state=running$' "$action_status_dir/$2.status" 2>/dev/null; then
				cat "$speed_live_file" 2>/dev/null || :
				sed -n 's/^path=/live_path=/p; s/^direction=/live_direction=/p' "$speed_step_file" 2>/dev/null || :
			fi
		else
			cat "$action_status_file" 2>/dev/null || printf 'state=idle\n'
		fi
		;;
	*)
		die 'Usage: ikev2-tunnel-quality {sample|summary [1h|6h|24h]|speed-test-async tunnel_service wan_service direction streams [tunnel_url] [wan_url]|action-status [id]}'
		;;
esac
