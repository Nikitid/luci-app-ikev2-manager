#!/bin/sh

lock_dir="${IKEV2_PBR_RESTART_LOCK:-/var/run/ikev2-domains-pbr-restart.lock}"
global_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
global_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
log_file="${IKEV2_PBR_RESTART_LOG:-/tmp/ikev2-domains-pbr-restart.log}"
action_lock_dir="$global_lock_dir"
action_lock_status="$global_lock_status"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
system_helper="${IKEV2_SYSTEM_HELPER:-/usr/libexec/ikev2-manager-system}"
domain_router_helper="${IKEV2_DOMAIN_ROUTER_HELPER:-/usr/libexec/ikev2-domain-router}"
xfrm_init="${IKEV2_XFRM_INIT:-/etc/init.d/ikev2-xfrm}"
pbr_init="${IKEV2_PBR_INIT:-/etc/init.d/pbr}"
discord_voice_helper="${IKEV2_DISCORD_VOICE:-/usr/libexec/ikev2-discord-voice}"
service_cidr_file="${IKEV2_SERVICE_CIDR_FILE:-/etc/pbr-ikev2-service-cidrs.txt}"
routing_helper="${IKEV2_ROUTING_HELPER:-/usr/libexec/ikev2-routing}"

. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/routing.sh"

drop_reclassified_connections() {
	command -v conntrack >/dev/null 2>&1 || return 0
	# Recognised by name, sing-box routes the selected domains and this set
	# stays empty.
	set_table=ikev2_routing
	set_name=dst4
	if nft list set inet "$set_table" "$set_name" >/dev/null 2>&1; then
		# Existing flow-offloaded sessions retain their old WAN route after a
		# domain is newly classified. Drop only sessions whose destination now
		# belongs to the destination set so their next connection is re-evaluated.
		conntrack -L 2>/dev/null |
			awk '{
				for (i = 1; i <= NF; i++) {
					if ($i ~ /^src=/) {
						for (j = i + 1; j <= NF; j++) {
							if ($j ~ /^dst=/) {
								sub(/^dst=/, "", $j)
								print $j
								next
							}
						}
					}
				}
			}' |
			sort -u |
			while IFS= read -r address; do
				[ -n "$address" ] || continue
				if nft get element inet "$set_table" "$set_name" "{ $address }" >/dev/null 2>&1; then
					conntrack -D -d "$address" >/dev/null 2>&1 || :
				fi
			done
	fi

	if [ -r /etc/pbr-ikev2-service-cidrs.txt ]; then
		while IFS= read -r cidr; do
			[ -n "$cidr" ] || continue
			conntrack -D -d "$cidr" >/dev/null 2>&1 || :
		done </etc/pbr-ikev2-service-cidrs.txt
	fi
}

check_runtime() {
	[ "$(uci -q get ikev2-manager.globals.configured 2>/dev/null || echo 0)" = 1 ] ||
		return 1
	"$routing_helper" check >/dev/null 2>&1 || return 1
	router_dns_ready 127.0.0.1 || return 1
	"$system_helper" failclosed-check >/dev/null 2>&1 || return 1
	forward_chain_ok || return 1
	if [ "$(uci -q get ikev2-manager.domains.engine 2>/dev/null || true)" = fakeip ]; then
		"$domain_router_helper" status 2>/dev/null | grep -q '^healthy=yes$' || return 1
	fi
}

pbr_runtime_ready() {
	"$pbr_init" running >/dev/null 2>&1 &&
		nft list chain inet fw4 pbr_prerouting >/dev/null 2>&1 &&
		forward_chain_ok
}

wait_for_pbr_runtime() {
	tries=0
	max_tries="${IKEV2_PBR_WAIT_SECONDS:-30}"
	case "$max_tries" in '' | *[!0-9]*) max_tries=30 ;; esac
	while [ "$tries" -lt "$max_tries" ]; do
		pbr_runtime_ready && return 0
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

# A list change rewrites the destination sets of policy routing (restarting
# dnsmasq when they changed) and the FakeIP rules, and never rebuilds the
# firewall. A router that routed through PBR keeps PBR's copy of our policies
# until the first sync retires it; PBR is then reloaded once without them.
perform_restart() {
	# Routes into a link that is down fail; the links come up first.
	"$xfrm_init" start || return 1
	"$system_helper" _sync-pbr || return 1
	if [ "$(uci -q get ikev2-manager.domains.engine 2>/dev/null || true)" = fakeip ] &&
	   [ -x "$domain_router_helper" ]; then
		"$domain_router_helper" refresh-rules || return 1
	fi
	if "$pbr_init" running >/dev/null 2>&1 &&
	   nft list chain inet fw4 pbr_prerouting 2>/dev/null | grep -q 'comment "IKEv2 PBR'; then
		"$pbr_init" reload >/dev/null 2>&1 || true
		wait_for_pbr_runtime || return 1
	fi
	wait_for_router_dns 127.0.0.1 20 || return 1
	"$routing_helper" check || return 1
	"$system_helper" failclosed-check || return 1
	ensure_forward_chain || return 1
	[ ! -x "$discord_voice_helper" ] || "$discord_voice_helper" sync || return 1
	drop_reclassified_connections
}

# A restart called from inside a router action runs under that action's lock.
run_restart() {
	global_owned=0
	if ! action_lock_held_by_ancestor; then
		acquire_action_lock pbr-restart domains || return 1
		global_owned=1
	fi
	if ! pid_lock_acquire "$lock_dir"; then
		if [ "$global_owned" = 1 ]; then
			rm -f "$global_lock_status"
			rmdir "$global_lock_dir" 2>/dev/null || true
		fi
		return 1
	fi
	cleanup_restart() {
		pid_lock_release "$lock_dir"
		if [ "$global_owned" = 1 ]; then
			rm -f "$global_lock_status"
			rmdir "$global_lock_dir" 2>/dev/null || true
		fi
	}
	trap cleanup_restart EXIT INT TERM
	if perform_restart >"$log_file" 2>&1; then
		result=0
	else
		result=1
	fi
	trap - EXIT INT TERM
	cleanup_restart
	return "$result"
}

schedule_restart() {
	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -b -q -S -x "$0" -- _run
	else
		setsid "$0" _run </dev/null >/dev/null 2>&1 &
	fi
}

case "${1:-}" in
	--check)
		check_runtime
		;;
	--wait)
		run_restart
		;;
	_run)
		sleep 1
		run_restart
		;;
	'')
		schedule_restart
		;;
	*)
		printf 'usage: %s [--check|--wait]\n' "$0" >&2
		exit 2
		;;
esac
