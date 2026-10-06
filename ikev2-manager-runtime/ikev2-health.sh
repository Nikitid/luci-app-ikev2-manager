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

run_dir="${IKEV2_RUN_DIR:-/var/run}"
status_file="$run_dir/ikev2-health.status"
tunnel_state_file="${IKEV2_TUNNEL_STATE:-$run_dir/ikev2-tunnels.state}"
probe_interval=20
dns_probe_state="$run_dir/ikev2-dns-segments-probe.state"
dns_probe_interval=60
tunnel_dns_probe_state="$run_dir/ikev2-tunnel-dns-probe.state"
tunnel_dns_probe_interval=60
# A healthy tunnel resolver is proven every few minutes; each proof starts a
# sing-box worker, the costliest check the watcher runs.
tunnel_dns_healthy_interval=180
tunnel_dns_state="${IKEV2_TUNNEL_DNS_STATE:-$run_dir/ikev2-tunnel-dns.state}"
wan_dns_probe_state="$run_dir/ikev2-wan-dns-probe.state"
wan_dns_probe_interval=60
set_dump_state="$run_dir/ikev2-set-dump.state"
set_dump_interval=60
community_refresh_state="$run_dir/ikev2-community-refresh.state"
community_refresh_interval=900
quality_sample_state="$run_dir/ikev2-quality-sample.state"
data_plane_dispatch_state="$run_dir/ikev2-data-plane-dispatch.state"
data_plane_state="${IKEV2_DATA_PLANE_STATE:-$run_dir/ikev2-data-plane.state}"
quality_sample_interval="${IKEV2_HEALTH_QUALITY_INTERVAL:-60}"
# The tunnel pass runs every pass_interval seconds; the loop wakes every tick
# so a pass held back by a configuration transaction starts soon after it
# ends. The tests shorten both.
pass_interval="${IKEV2_HEALTH_PASS_INTERVAL:-15}"
tick="${IKEV2_HEALTH_TICK:-5}"
# With more than one tunnel up, whether traffic crosses each is probed this
# often, detached; the rounds are what tunnel_track counts.
tunnel_probe_interval="${IKEV2_HEALTH_TUNNEL_PROBE_INTERVAL:-15}"
tunnel_probe_dispatch="$run_dir/ikev2-tunnel-probe-dispatch.state"
tunnel_probe_file="$run_dir/ikev2-tunnel-probe.state"
task_dir="$run_dir/ikev2-health.tasks"

sa_helper="${IKEV2_SA_HELPER:-/usr/libexec/ikev2-sa}"
routing_helper="${IKEV2_ROUTING_HELPER:-/usr/libexec/ikev2-routing}"
system_helper="${IKEV2_SYSTEM_HELPER:-/usr/libexec/ikev2-manager-system}"
domain_router_helper="${IKEV2_DOMAIN_ROUTER_HELPER:-/usr/libexec/ikev2-domain-router}"
device_routing_helper="${IKEV2_DEVICE_ROUTING_HELPER:-/usr/libexec/ikev2-device-routing}"
discord_voice_helper="${IKEV2_DISCORD_VOICE_HELPER:-/usr/libexec/ikev2-discord-voice}"
user_policy_helper="${IKEV2_USER_POLICY_HELPER:-/usr/libexec/ikev2-user-policy}"
manager_helper="${IKEV2_MANAGER_HELPER:-/usr/libexec/ikev2-manager}"
sync_vips_helper="${IKEV2_SYNC_VIPS:-/usr/libexec/ikev2-sync-vips}"
quality_helper="${IKEV2_QUALITY_HELPER:-/usr/libexec/ikev2-tunnel-quality}"
community_helper="${IKEV2_COMMUNITY_HELPER:-/usr/libexec/ikev2-domains-community}"
xfrm_init="${IKEV2_XFRM_INIT:-/etc/init.d/ikev2-xfrm}"
vip_file="${IKEV2_VIP_FILE:-/var/run/ikev2-vip4}"
net_dir="${IKEV2_NET_DIR:-/sys/class/net}"
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
uci_bin="${IKEV2_UCI_BIN:-uci}"

# The schedule is read and written without starting a process: the loop wakes
# every few seconds, and a cat or mv each time added up to most of its cost.
periodic_due() {
	local at="$1" state="$2" interval="$3" last=0
	read -r last 2>/dev/null <"$state" || last=0
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	[ $((at - last)) -ge "$interval" ] || [ "$at" -lt "$last" ]
}

mark_periodic() {
	printf '%s\n' "$1" >"$2"
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
	local name="$1" state="$2" interval="$3" at
	shift 3
	at="${now:-$(date +%s)}"
	periodic_due "$at" "$state" "$interval" || return 0
	mark_periodic "$at" "$state"
	spawn_task "$name" "$@"
}

# One probe round: whether HTTPS crosses each tunnel named, all of them at
# once, so a silent one costs the round its timeout a single time. The round
# is written whole, its time first, then "index:1" or "index:0" a tunnel.
probe_tunnels() {
	local index round="$tunnel_probe_file.$$"
	for index in "$@"; do
		tunnel_names "$index"
		(
			if tunnel_https_reachable 3 5 "$tunnel_link"; then
				printf '%s:1\n' "$index"
			else
				printf '%s:0\n' "$index"
			fi >"$round.$index"
		) &
	done
	wait
	{
		date +%s
		for index in "$@"; do cat "$round.$index"; done
	} >"$round" 2>/dev/null && mv "$round" "$tunnel_probe_file"
	for index in "$@"; do rm -f "$round.$index"; done
}

# Read the round the probe last wrote, once: sets probe_round to its results
# and returns 1 when there is none that was not read before. No process is
# started; the loop asks every few seconds.
probe_round_read=''
probe_round_take() {
	local stamp line
	probe_round=''
	[ -r "$tunnel_probe_file" ] || return 1
	{
		read -r stamp || stamp=''
		[ -n "$stamp" ] && [ "$stamp" != "$probe_round_read" ] || return 1
		while read -r line; do
			case "$line" in
				[1-7]:[01]) probe_round="$probe_round${probe_round:+ }$line" ;;
			esac
		done
	} <"$tunnel_probe_file"
	probe_round_read="$stamp"
}

# Whether a round is waiting in which a tunnel failed: the pass that counts it
# then runs now, not at its interval.
probe_round_failed() {
	local stamp line
	[ -r "$tunnel_probe_file" ] || return 1
	{
		read -r stamp || return 1
		[ "$stamp" != "$probe_round_read" ] || return 1
		while read -r line; do
			case "$line" in [1-7]:0) return 0 ;; esac
		done
	} <"$tunnel_probe_file"
	return 1
}

# Checks that change nothing while a configuration transaction is running
# would still read its half-applied state, so every scheduled check waits for
# the lock except the quality sample, which only pings through the tunnel.
dispatch_checks() {
	periodic_task dns-segments "$dns_probe_state" "$dns_probe_interval" \
		"$system_helper" dns-segments-check
	# The tunnel resolver's probes go through the tunnel a pause refuses; their
	# failures would switch providers for nothing.
	if [ "$paused" != 1 ]; then
		if tunnel_dns_failing; then
			interval="$tunnel_dns_probe_interval"
		else
			interval="$tunnel_dns_healthy_interval"
		fi
		periodic_task tunnel-dns "$tunnel_dns_probe_state" "$interval" \
			"$domain_router_helper" tunnel-dns-check
	fi
	periodic_task wan-dns "$wan_dns_probe_state" "$wan_dns_probe_interval" \
		"$system_helper" _dns-wan-refresh
	# The destination sets are copied only between transactions: a copy taken
	# while a restart refills them would replace a complete snapshot with a
	# partial one.
	if periodic_due "$now" "$set_dump_state" "$set_dump_interval"; then
		"$routing_helper" dump >/dev/null 2>&1 || :
		mark_periodic "$now" "$set_dump_state"
	fi
	# Service lists refresh on their own schedule. The helper decides whether a
	# refresh is due (after boot, then daily) and queues it detached.
	[ ! -x "$community_helper" ] ||
		periodic_task community "$community_refresh_state" "$community_refresh_interval" \
			"$community_helper" refresh-if-due
}

# The slower checks of the runtimes run once a minute, the tunnel pass every
# fifteen seconds; a check that fails is repaired at once.
check_interval="${IKEV2_HEALTH_CHECK_INTERVAL:-60}"

# What a pass needs from the configuration, from one uci call instead of one
# for each option.
load_settings() {
	local settings line
	configured=0 paused=0 engine=nftset client_enabled=0 server_enabled=0
	settings="$("$uci_bin" -q show ikev2-manager 2>/dev/null)" || settings=''
	while IFS= read -r line; do
		case "$line" in
			"ikev2-manager.globals.configured='1'") configured=1 ;;
			"ikev2-manager.domains.paused='1'") paused=1 ;;
			"ikev2-manager.domains.engine='fakeip'") engine=fakeip ;;
			"ikev2-manager.client.enabled='1'") client_enabled=1 ;;
			"ikev2-manager.server.enabled='1'") server_enabled=1 ;;
		esac
	done <<EOF
$settings
EOF
	tunnel_settings_parse <<EOF
$settings
EOF
}

# Whether a network link exists and is up, read from sysfs without starting a
# process.
link_up() {
	local flags
	read -r flags 2>/dev/null <"$net_dir/$1/flags" || return 1
	case "$flags" in 0x[0-9a-fA-F]*) ;; *) return 1 ;; esac
	[ $((flags & 1)) = 1 ]
}

# Whether the tunnel resolver's last check failed, read without starting a
# process. Failing, it is checked every minute so a switch to the next
# endpoint is not delayed.
tunnel_dns_failing() {
	local line
	while IFS= read -r line; do
		case "$line" in failures=0) return 1 ;; failures=*) return 0 ;; esac
	done 2>/dev/null <"$tunnel_dns_state"
	return 1
}

# Whether the FakeIP data plane passed its last check, read without starting
# a process.
data_plane_ok() {
	local line
	while IFS= read -r line; do
		[ "$line" != state=ok ] || return 0
	done 2>/dev/null <"$data_plane_state"
	return 1
}

# Repairs run under the router action lock, so that a page action cannot run
# beside one. With the lock taken by someone else nothing is repaired; the
# next pass looks again.
repair() {
	action_lock_try_acquire watcher "watcher-$$" || return 0
	"$@" >/dev/null 2>&1 || :
	release_action_lock
}

# The XFRM links the configuration needs are up, and the inbound one is down
# while the server is off. Checked from sysfs every pass; the init script
# also puts the inbound gateway address back, so it runs once a minute too.
links_current() {
	local index
	[ -n "$tunnel_on" ] || [ "$server_enabled" = 1 ] || return 0
	link_up ipsec-out || return 1
	for index in $tunnel_on; do
		[ "$index" != 1 ] || continue
		link_up "ipsec-out$index" || return 1
	done
	if [ "$server_enabled" = 1 ]; then
		link_up ipsec-in
	else
		! link_up ipsec-in
	fi
}

# The pause block follows domains.paused: a reboot or a firewall tool that
# dropped it does not end a pause.
pause_current() {
	if "$nft_bin" list table inet ikev2_pause >/dev/null 2>&1; then
		[ "$paused" = 1 ]
	else
		[ "$paused" = 0 ]
	fi
}

# The runtimes that change only when something else disturbs them: each is
# checked, and only one that fails is synced. They used to be synced on every
# pass whatever their state, which cost most of the watcher's CPU.
check_runtimes() {
	routing_policy_state=ok
	if ! "$routing_helper" check >/dev/null 2>&1; then
		repair "$routing_helper" sync
		"$routing_helper" check >/dev/null 2>&1 || routing_policy_state=degraded
	fi
	if [ -x "$device_routing_helper" ] && ! "$device_routing_helper" check >/dev/null 2>&1; then
		repair "$device_routing_helper" sync
	fi
	if [ -x "$discord_voice_helper" ] && ! "$discord_voice_helper" check >/dev/null 2>&1; then
		repair "$discord_voice_helper" sync
	fi
	# The inbound watcher owns this runtime, but it cannot repair itself once
	# its own reconciliation stops completing: procd only respawns a process
	# that exits, so a watcher that keeps running while its sets go stale
	# leaves every VPN client fail-closed and silent.
	if [ -x "$user_policy_helper" ] && ! "$user_policy_helper" check >/dev/null 2>&1; then
		repair "$user_policy_helper" sync
	fi
	# Repairs FakeIP under its own lock when it finds the runtime broken.
	if [ "$engine" = fakeip ] && [ -x "$domain_router_helper" ]; then
		"$domain_router_helper" ensure >/dev/null 2>&1 || :
	fi
	# Idempotent, and it also puts the inbound gateway address back; run
	# unlocked like before, since taking the lock each minute only filled the
	# log with begin and end lines.
	"$xfrm_init" start >/dev/null 2>&1 || :
	# Self-heal the inbound server if it drifted: enabled in config but the
	# ikev2-in connection is not loaded into charon (e.g. strongSwan reinstall
	# cleared /etc/swanctl, or a partial swanctl reload left the pool/cert
	# unloaded). server-ensure re-syncs the cert and reloads; it is a no-op when
	# already healthy, so this only acts when the server is actually broken.
	if [ "$server_enabled" = 1 ] && ! "$sa_helper" conn-loaded ikev2-in; then
		"$manager_helper" server-ensure >/dev/null 2>&1 || :
	# The connection for managed desktop devices, once their access is set
	# up; server-ensure knows when a custom configuration owns that instead.
	elif [ "$server_enabled" = 1 ] && [ -f /etc/ikev2-manager/clients/initialized ] &&
	   ! "$sa_helper" conn-loaded ikev2-in-managed; then
		"$manager_helper" server-ensure >/dev/null 2>&1 || :
	fi
	[ "$client_enabled" != 1 ] || [ "$sa_installed" != 1 ] || "$sync_vips_helper" >/dev/null 2>&1 || :
}

# Persist once during an orderly reboot/service stop. Keeping the hot runtime
# dump in /var/run avoids flash writes every 15 seconds, while the shutdown
# snapshot lets warm client DNS caches survive the next boot without leaking.
health_lock="${IKEV2_HEALTH_LOCK:-$run_dir/ikev2-health.lock}"
if ! pid_lock_acquire "$health_lock"; then
	printf '%s\n' 'ikev2-health is already running' >&2
	exit 1
fi

health_cleanup() {
	trap - EXIT INT TERM
	[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null || :
	"$routing_helper" persist >/dev/null 2>&1 || :
	pid_lock_release "$health_lock"
}

sleeper=''
trap 'health_cleanup; exit 0' INT TERM
# The inbound policy watcher, which follows strongSwan's events, signals when
# the outbound SA comes or goes: the next pass then runs at once instead of up
# to a pass interval later.
trap 'last_pass=0' USR1
trap 'health_cleanup' EXIT

tunnel_was_up=0
tunnel_silent=''
sa_was_up=-
exits_pending=0
last_pass=0
last_checks=0
probe_last=0
probe_failures=0
routing_policy_state=ok
paused=0

# A TERM that arrives during the sleep is acted on at once: in the foreground
# the sleep held it back past procd's five-second bound, which then killed the
# watcher before it could keep the destination sets.
pause_loop() {
	sleep "$1" &
	sleeper=$!
	wait "$sleeper" 2>/dev/null || :
	sleeper=''
}

while true; do
	now="$(date +%s)"
	load_settings
	if [ "$configured" != 1 ]; then
		printf 'state=disabled updated=%s\n' "$now" >"$status_file"
		pause_loop 60
		continue
	fi
	# Quality sampling only reads the tunnel, so it runs through pauses and
	# configuration transactions alike. It is detached: its pings take seconds
	# and must not delay the repairs below.
	[ ! -x "$quality_helper" ] ||
		periodic_task quality "$quality_sample_state" "$quality_sample_interval" \
			"$quality_helper" sample
	# Configuration transactions own the global action lock. Leave their DNS,
	# routing, nftables and strongSwan snapshots untouched; the next watcher pass
	# reconciles runtime after the transaction has committed or rolled back.
	if action_lock_busy; then
		pause_loop "$tick"
		continue
	fi
	if [ $((now - last_pass)) -lt "$pass_interval" ] && [ "$now" -ge "$last_pass" ] &&
	   ! probe_round_failed; then
		dispatch_checks
		pause_loop "$tick"
		continue
	fi
	last_pass="$now"

	# A pause changes nothing but the block at the tunnel, so everything else is
	# looked after as usual.
	if ! pause_current; then
		repair "$system_helper" _pause-sync
		pause_current ||
			logger -t ikev2-health 'the tunnel pause block could not be restored' 2>/dev/null || :
	fi
	links_current || repair "$xfrm_init" start

	# One SA snapshot a pass, whatever the number of tunnels: those with an
	# installed CHILD_SA, and of them those whose link is up to carry traffic.
	sa_up='' tunnels_up=''
	if [ -n "$tunnel_on" ]; then
		sa_lines="$("$sa_helper" tunnels 2>/dev/null)" || sa_lines=''
		while IFS='	' read -r index installed address; do
			[ "$installed" = 1 ] || continue
			case " $tunnel_on " in *" $index "*) ;; *) continue ;; esac
			sa_up="$sa_up${sa_up:+ }$index"
			tunnel_names "$index"
			link_up "$tunnel_link" || continue
			tunnels_up="$tunnels_up${tunnels_up:+ }$index"
		done <<EOF
$sa_lines
EOF
	fi
	sa_installed=0
	case " $sa_up " in *' 1 '*) [ "$client_enabled" != 1 ] || sa_installed=1 ;; esac
	# The tunnel default routes follow the SAs: written when one comes up,
	# removed when it goes, at once rather than at the next check.
	routing_due=0
	if [ "$sa_up" != "$sa_was_up" ]; then
		for index in $sa_was_up; do
			case " $sa_up " in *" $index "*) continue ;; esac
			if [ "$index" = 1 ]; then
				rm -f "$vip_file"
				probe_last=0
				probe_failures=0
			else
				rm -f "$vip_file-$index"
			fi
		done
		[ -z "$sa_up" ] || "$sync_vips_helper" >/dev/null 2>&1 || :
		routing_due=1
	fi
	sa_was_up="$sa_up"
	# An installed SA does not say traffic crosses the tunnel. With another
	# tunnel to compare with, each is probed, detached, and one that falls
	# silent is left out below as if it were down. A pause refuses what the
	# probe would send, through every tunnel alike.
	silent_before="$tunnel_silent"
	probe_round_take || :
	case "$tunnels_up" in
		*' '*)
			if [ "$paused" != 1 ]; then
				# shellcheck disable=SC2086
				periodic_task tunnel-probe "$tunnel_probe_dispatch" "$tunnel_probe_interval" \
					probe_tunnels $tunnels_up
			fi
			;;
	esac
	tunnel_track "$tunnels_up" "$probe_round"
	[ "$tunnel_silent" = "$silent_before" ] || [ -z "$tunnel_silent" ] ||
		logger -t ikev2-health "connected, but nothing crosses: tunnel $tunnel_silent" 2>/dev/null || :
	# Which tunnel each exit uses; a tunnel coming back takes its exit back
	# only after it has stayed up, so this can change with no SA changing.
	tunnel_select "$now" "$tunnel_carrying" "$tunnel_silent"
	[ -z "$tunnel_changes" ] || routing_due=1
	[ "$routing_due" = 0 ] || repair "$routing_helper" sync
	if [ -n "$tunnel_changes" ] && tunnel_several; then
		logger -t ikev2-health "exits now use: $tunnel_changes" 2>/dev/null || :
		# Only an exit that may move has a selector to turn: one without
		# backup, written "Ns:", keeps the single tunnel it has.
		case " $tunnel_changes" in *' '[1-7]:*) exits_pending=1 ;; esac
	fi
	# sing-box follows through its controller, which a restarting resolver
	# does not answer: the choice is offered again every pass until taken.
	if [ "$exits_pending" = 1 ] && action_lock_try_acquire watcher "watcher-$$"; then
		! "$domain_router_helper" exits-apply >/dev/null 2>&1 || exits_pending=0
		release_action_lock
	fi

	if [ $((now - last_checks)) -ge "$check_interval" ] || [ "$now" -lt "$last_checks" ]; then
		last_checks="$now"
		check_runtimes
	fi

	tunnel_up=0
	if [ "$client_enabled" != 1 ]; then
		state=client-disabled
		[ "$routing_policy_state" = ok ] || state=degraded
		printf 'state=%s updated=%s routing_policy=%s\n' \
			"$state" "$now" "$routing_policy_state" >"$status_file"
	elif [ "$sa_installed" = 1 ]; then
		if [ $((now - probe_last)) -ge "$probe_interval" ] || [ "$now" -lt "$probe_last" ]; then
			# Both endpoints can stall. Keep the probe bounded so a slow uplink
			# cannot delay the next pass.
			if tunnel_https_reachable 3 5; then
				probe_failures=0
			else
				probe_failures=$((probe_failures + 1))
			fi
			probe_last="$now"
		fi
		# Public endpoints are independent third parties. Probe failures are
		# telemetry only and must not tear down an otherwise installed SA.
		state=up
		[ "$probe_failures" = 0 ] && tunnel_up=1
		case "$routing_policy_state:$probe_failures" in ok:0) ;; *) state=degraded ;; esac
		printf 'state=%s updated=%s probe_failures=%s routing_policy=%s\n' \
			"$state" "$now" "$probe_failures" "$routing_policy_state" >"$status_file"
	else
		printf 'state=down updated=%s\n' "$now" >"$status_file"
	fi
	# strongSwan normally owns reconnects. Its boot-time start_action can run
	# before WAN is usable, however, and that initial failure is not reliably
	# retried. ensure-client is idempotent, locked and rate-limited per
	# tunnel, so the watcher safely fills that gap for every enabled tunnel
	# without racing manual actions or hotplug.
	[ "$sa_up" = "$tunnel_on" ] || "$manager_helper" ensure-client >/dev/null 2>&1 || :

	# The resolver can outlive a tunnel outage in a state that no longer carries
	# traffic. The helper paces its own checks; the watcher asks once a minute,
	# and at once when the tunnel has just come back. There is nothing to learn
	# while it is down, or while a pause refuses what would reach it.
	if [ "$tunnel_up" = 1 ] && [ "$paused" = 0 ] && [ "$engine" = fakeip ]; then
		if [ "$tunnel_was_up" = 1 ] && data_plane_ok; then
			periodic_task data-plane "$data_plane_dispatch_state" 60 \
				"$domain_router_helper" data-plane-check
		elif [ "$tunnel_was_up" = 1 ]; then
			# Failing: the helper retries on its own shorter interval.
			spawn_task data-plane "$domain_router_helper" data-plane-check
		else
			mark_periodic "$now" "$data_plane_dispatch_state"
			spawn_task data-plane "$domain_router_helper" data-plane-check now
		fi
	fi
	tunnel_was_up="$tunnel_up"
	dispatch_checks
	pause_loop "$tick"
done
