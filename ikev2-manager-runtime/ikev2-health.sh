#!/bin/sh

set -u

[ "$#" -eq 0 ] || {
	printf '%s\n' 'usage: ikev2-health' >&2
	exit 2
}

runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
action_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/tunnel.sh"

status_file='/var/run/ikev2-health.status'
probe_state='/var/run/ikev2-health-probe.state'
probe_interval=20
dns_probe_state='/var/run/ikev2-dns-segments-probe.state'
dns_probe_interval=60
tunnel_dns_probe_state='/var/run/ikev2-tunnel-dns-probe.state'
tunnel_dns_probe_interval=60
wan_dns_probe_state='/var/run/ikev2-wan-dns-probe.state'
wan_dns_probe_interval=60
set_dump_state='/var/run/ikev2-set-dump.state'
set_dump_interval=60
community_refresh_state='/var/run/ikev2-community-refresh.state'
community_refresh_interval=900
quality_sample_state='/var/run/ikev2-quality-sample.state'
quality_sample_interval=60
# The tunnel and policy pass runs every pass_interval seconds; the loop wakes
# every tick so a pass held back by a configuration transaction starts soon
# after it ends.
pass_interval=15
tick=5
task_dir='/var/run/ikev2-health.tasks'

sa_helper="${IKEV2_SA_HELPER:-/usr/libexec/ikev2-sa}"

has_proxy4() {
	"$sa_helper" installed proxy-out proxy4
}

probe_due() {
	now="$1"
	last="$(sed -n 's/^last=//p' "$probe_state" 2>/dev/null | tail -n1)"
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	[ $((now - last)) -ge "$probe_interval" ]
}

probe_failures() {
	value="$(sed -n 's/^failures=//p' "$probe_state" 2>/dev/null | tail -n1)"
	case "$value" in '' | *[!0-9]*) value=0 ;; esac
	printf '%s\n' "$value"
}

save_probe() {
	{
		printf 'last=%s\n' "$1"
		printf 'failures=%s\n' "$2"
	} >"${probe_state}.new"
	mv "${probe_state}.new" "$probe_state"
}

periodic_due() {
	now="$1"
	state="$2"
	interval="$3"
	last="$(cat "$state" 2>/dev/null || echo 0)"
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	[ $((now - last)) -ge "$interval" ]
}

mark_periodic() {
	printf '%s\n' "$1" >"${2}.new"
	mv "${2}.new" "$2"
}

# Slow checks run detached: a resolver probe or a FakeIP canary takes seconds
# to tens of seconds, and run in line they held back the next tunnel reconnect
# and policy repair by as much. Every task takes the lock its helper already
# uses, so running beside the pass is safe; the pid file keeps a second copy
# of the same task from starting while one still runs.
spawn_task() {
	local name="$1" pid
	shift
	pid="$(cat "$task_dir/$name.pid" 2>/dev/null || :)"
	case "$pid" in
		'' | *[!0-9]*) ;;
		*) ! kill -0 "$pid" 2>/dev/null || return 0 ;;
	esac
	mkdir -p "$task_dir"
	(
		"$@" </dev/null >/dev/null 2>&1 || :
		rm -f "$task_dir/$name.pid"
	) &
	printf '%s\n' "$!" >"$task_dir/$name.pid"
}

# periodic_task NAME STATE INTERVAL COMMAND...: starts COMMAND detached when
# its interval has passed. The clock is marked at the start, so a slow task
# is not started again before its interval even while it still runs.
periodic_task() {
	local name="$1" state="$2" interval="$3" now
	shift 3
	now="$(date +%s)"
	periodic_due "$now" "$state" "$interval" || return 0
	mark_periodic "$now" "$state"
	spawn_task "$name" "$@"
}

# Checks that change nothing while a configuration transaction is running
# would still read its half-applied state, so every scheduled check waits for
# the lock except the quality sample, which only pings through the tunnel.
dispatch_checks() {
	periodic_task dns-segments "$dns_probe_state" "$dns_probe_interval" \
		/usr/libexec/ikev2-manager-system dns-segments-check
	# The tunnel resolver's probes go through the tunnel a pause refuses; their
	# failures would switch providers for nothing.
	[ "$paused" = 1 ] ||
		periodic_task tunnel-dns "$tunnel_dns_probe_state" "$tunnel_dns_probe_interval" \
			/usr/libexec/ikev2-domain-router tunnel-dns-check
	periodic_task wan-dns "$wan_dns_probe_state" "$wan_dns_probe_interval" \
		/usr/libexec/ikev2-manager-system _dns-wan-refresh
	# The destination sets are copied only between transactions: a copy taken
	# while a restart refills them would replace a complete snapshot with a
	# partial one.
	if periodic_due "$(date +%s)" "$set_dump_state" "$set_dump_interval"; then
		"$routing_helper" dump >/dev/null 2>&1 || :
		mark_periodic "$(date +%s)" "$set_dump_state"
	fi
	# Service lists refresh on their own schedule. The helper decides whether a
	# refresh is due (after boot, then daily) and queues it detached.
	[ ! -x /usr/libexec/ikev2-domains-community ] ||
		periodic_task community "$community_refresh_state" "$community_refresh_interval" \
			/usr/libexec/ikev2-domains-community refresh-if-due
}

routing_helper="${IKEV2_ROUTING_HELPER:-/usr/libexec/ikev2-routing}"

service_cidr_policy_healthy() {
	"$routing_helper" check
}

ensure_discord_voice_policy() {
	[ -x /usr/libexec/ikev2-discord-voice ] || return 0
	/usr/libexec/ikev2-discord-voice check >/dev/null 2>&1 && return 0
	action_lock_busy && return 0
	/usr/libexec/ikev2-discord-voice sync >/dev/null 2>&1 || :
}

ensure_device_routing_policy() {
	[ -x /usr/libexec/ikev2-device-routing ] || return 0
	/usr/libexec/ikev2-device-routing check >/dev/null 2>&1 && return 0
	action_lock_busy && return 0
	/usr/libexec/ikev2-device-routing sync >/dev/null 2>&1 || :
}

# The inbound watcher owns this runtime, but it cannot repair itself once its
# own reconciliation stops completing: procd only respawns a process that
# exits, so a watcher that keeps running while its sets go stale leaves every
# VPN client fail-closed and silent. An independent check closes that gap.
ensure_inbound_user_policy() {
	[ -x /usr/libexec/ikev2-user-policy ] || return 0
	/usr/libexec/ikev2-user-policy check >/dev/null 2>&1 && return 0
	action_lock_busy && return 0
	/usr/libexec/ikev2-user-policy sync >/dev/null 2>&1 || :
}

# Persist once during an orderly reboot/service stop. Keeping the hot runtime
# dump in /var/run avoids flash writes every 15 seconds, while the shutdown
# snapshot lets warm client DNS caches survive the next boot without leaking.
health_lock="${IKEV2_HEALTH_LOCK:-/var/run/ikev2-health.lock}"
if ! pid_lock_acquire "$health_lock"; then
	printf '%s\n' 'ikev2-health is already running' >&2
	exit 1
fi

health_cleanup() {
	trap - EXIT INT TERM
	"$routing_helper" persist >/dev/null 2>&1 || :
	pid_lock_release "$health_lock"
}

trap 'health_cleanup; exit 0' INT TERM
trap 'health_cleanup' EXIT

tunnel_was_up=0
last_pass=0
paused=0

while true; do
	if [ "$(uci -q get ikev2-manager.globals.configured)" != 1 ]; then
		printf 'state=disabled updated=%s\n' "$(date +%s)" >"$status_file"
		sleep 60
		continue
	fi
	# Quality sampling only reads the tunnel, so it runs through pauses and
	# configuration transactions alike. It is detached: its pings take seconds
	# and must not delay the repairs below.
	[ ! -x /usr/libexec/ikev2-tunnel-quality ] ||
		periodic_task quality "$quality_sample_state" "$quality_sample_interval" \
			/usr/libexec/ikev2-tunnel-quality sample
	# Configuration transactions own the global action lock. Leave their DNS,
	# routing, nftables and strongSwan snapshots untouched; the next watcher pass
	# reconciles runtime after the transaction has committed or rolled back.
	if action_lock_busy; then
		sleep "$tick"
		continue
	fi
	loop_start="$(date +%s)"
	if [ $((loop_start - last_pass)) -lt "$pass_interval" ] && [ "$loop_start" -ge "$last_pass" ]; then
		dispatch_checks
		sleep "$tick"
		continue
	fi
	last_pass="$loop_start"

	# A pause changes nothing but the block at the tunnel, so everything else is
	# looked after as usual. The block follows the setting here too: a reboot
	# or a firewall tool that dropped it does not end a pause.
	paused=0
	[ "$(uci -q get ikev2-manager.domains.paused 2>/dev/null || echo 0)" != 1 ] || paused=1
	/usr/libexec/ikev2-manager-system _pause-sync >/dev/null 2>&1 ||
		logger -t ikev2-health 'the tunnel pause block could not be restored' 2>/dev/null || :

	if [ "$(uci -q get ikev2-manager.domains.engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router ensure >/dev/null 2>&1 || :
	fi
	routing_policy_state=ok
	service_cidr_policy_healthy || routing_policy_state=degraded
	ensure_discord_voice_policy
	ensure_device_routing_policy
	ensure_inbound_user_policy

	/etc/init.d/ikev2-xfrm start

	tunnel_up=0
	client_enabled="$(uci -q get ikev2-manager.client.enabled || echo 0)"
	if [ "$client_enabled" != 1 ]; then
		rm -f /var/run/ikev2-vip4
		"$routing_helper" sync-all || :
		state=client-disabled
		[ "$routing_policy_state" = ok ] || state=degraded
		printf 'state=%s updated=%s routing_policy=%s\n' \
			"$state" "$(date +%s)" "$routing_policy_state" >"$status_file"
	fi

	# strongSwan normally owns reconnects. Its boot-time start_action can run
	# before WAN is usable, however, and that initial failure is not reliably
	# retried. ensure-client is idempotent, locked and rate-limited, so the
	# watcher safely fills that gap without racing manual actions or hotplug.
	if [ "$client_enabled" = 1 ] && ! has_proxy4; then
		/usr/libexec/ikev2-manager ensure-client >/dev/null 2>&1 || :
	fi

	if [ "$client_enabled" = 1 ] && has_proxy4; then
		if /usr/libexec/ikev2-sync-vips &&
			"$routing_helper" sync-all; then
			now="$(date +%s)"
			failures="$(probe_failures)"
			if probe_due "$now"; then
				# Both endpoints can stall. Keep the probe bounded so a slow
				# uplink cannot delay the DNS, routing and fail-closed checks below.
				if tunnel_https_reachable 3 5; then
					failures=0
				else
					failures=$((failures + 1))
				fi
				save_probe "$now" "$failures"
			fi
			# Public endpoints are independent third parties. Probe failures are
			# telemetry only and must not tear down an otherwise installed SA.
			state=up
			[ "$failures" = 0 ] && tunnel_up=1
			case "$routing_policy_state:$failures" in ok:0) ;; *) state=degraded ;; esac
			printf 'state=%s updated=%s probe_failures=%s routing_policy=%s\n' \
				"$state" "$now" "$failures" "$routing_policy_state" >"$status_file"
		else
			printf 'state=degraded updated=%s\n' "$(date +%s)" >"$status_file"
		fi
	elif [ "$client_enabled" = 1 ]; then
		rm -f "$probe_state"
		rm -f /var/run/ikev2-vip4
		"$routing_helper" sync-all || :
		printf 'state=down updated=%s\n' "$(date +%s)" >"$status_file"
	fi

	# Self-heal the inbound server if it drifted: enabled in config but the
	# ikev2-in connection is not loaded into charon (e.g. strongSwan reinstall
	# cleared /etc/swanctl, or a partial swanctl reload left the pool/cert
	# unloaded). server-ensure re-syncs the cert and reloads; it is a no-op when
	# already healthy, so this only acts when the server is actually broken.
	if [ "$(uci -q get ikev2-manager.server.enabled)" = 1 ] &&
		! swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:'; then
		/usr/libexec/ikev2-manager server-ensure >/dev/null 2>&1 || :
	fi

	# The resolver can outlive a tunnel outage in a state that no longer carries
	# traffic. The helper paces its own checks; the watcher only says when the
	# tunnel has just come back. There is nothing to learn while it is down, or
	# while a pause refuses what would reach it.
	if [ "$tunnel_up" = 1 ] && [ "$paused" = 0 ] &&
	   [ "$(uci -q get ikev2-manager.domains.engine)" = fakeip ]; then
		if [ "$tunnel_was_up" = 1 ]; then
			spawn_task data-plane /usr/libexec/ikev2-domain-router data-plane-check
		else
			spawn_task data-plane /usr/libexec/ikev2-domain-router data-plane-check now
		fi
	fi
	tunnel_was_up="$tunnel_up"
	dispatch_checks
	sleep "$tick"
done
