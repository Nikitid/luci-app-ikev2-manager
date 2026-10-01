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
sync_vips_helper="${IKEV2_SYNC_VIPS:-/usr/libexec/ikev2-sync-vips}"
pbr_user_helper="${IKEV2_PBR_USER:-/usr/share/pbr/pbr.user.ikev2out}"
discord_voice_helper="${IKEV2_DISCORD_VOICE:-/usr/libexec/ikev2-discord-voice}"
pbr_signature_file="${IKEV2_PBR_SIGNATURE:-/var/run/ikev2-pbr-policy.signature}"
domain_file="${IKEV2_DOMAIN_FILE:-/etc/pbr-ikev2-domains.txt}"
service_cidr_file="${IKEV2_SERVICE_CIDR_FILE:-/etc/pbr-ikev2-service-cidrs.txt}"
routing_helper="${IKEV2_ROUTING_HELPER:-/usr/libexec/ikev2-routing}"

. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/routing.sh"

routing_native() {
	[ "$(uci -q get ikev2-manager.globals.routing_backend 2>/dev/null)" = native ]
}

drop_reclassified_connections() {
	command -v conntrack >/dev/null 2>&1 || return 0
	set_table=fw4
	set_name="$(nft list table inet fw4 2>/dev/null |
		sed -n 's/^[[:space:]]*set \(pbr_ikev2out_4_dst_ip_[^[:space:]]*\) {.*/\1/p' |
		grep -v '_user$' | head -n1)"
	if routing_native; then
		set_table=ikev2_routing
		set_name=dst4
	fi
	if [ -n "$set_name" ]; then
		# Existing flow-offloaded sessions retain their old WAN route after a
		# domain is newly classified. Drop only sessions whose destination now
		# belongs to the managed PBR set so their next connection is re-evaluated.
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
	if routing_native; then
		"$routing_helper" check >/dev/null 2>&1 || return 1
	else
		"$pbr_init" running >/dev/null 2>&1 || return 1
	fi
	router_dns_ready 127.0.0.1 || return 1
	"$system_helper" failclosed-check >/dev/null 2>&1 || return 1
	forward_chain_ok || return 1
	if [ "$(uci -q get ikev2-manager.domains.engine 2>/dev/null || true)" = fakeip ]; then
		"$domain_router_helper" status 2>/dev/null | grep -q '^healthy=yes$' || return 1
	fi
}

pbr_policy_signature() {
	local signature_input signature rc engine
	command -v sha256sum >/dev/null 2>&1 || return 1
	signature_input="${pbr_signature_file}.input.$$"
	engine="$(uci -q get ikev2-manager.domains.engine 2>/dev/null || true)"
	printf 'engine=%s\n' "$engine" >"$signature_input" || {
		rm -f "$signature_input"
		return 1
	}
	uci -q export pbr >>"$signature_input" 2>/dev/null || {
		rm -f "$signature_input"
		return 1
	}
	printf '%s\n' '-- service networks --' >>"$signature_input" || {
		rm -f "$signature_input"
		return 1
	}
	if [ -r "$service_cidr_file" ]; then
		cat "$service_cidr_file" >>"$signature_input" || {
			rm -f "$signature_input"
			return 1
		}
	fi
	# Reliable mode routes selected names through its local FakeIP rule-set.
	# The legacy PBR domain file is relevant only in Standard mode; including
	# it here would force a redundant PBR rebuild for every hot rule reload.
	if [ "$engine" != fakeip ]; then
		printf '%s\n' '-- standard-mode domains --' >>"$signature_input" || {
			rm -f "$signature_input"
			return 1
		}
		if [ -r "$domain_file" ]; then
			cat "$domain_file" >>"$signature_input" || {
				rm -f "$signature_input"
				return 1
			}
		fi
	fi
	signature="$(sha256sum "$signature_input" 2>/dev/null | awk '{ print $1 }')"
	rc=$?
	rm -f "$signature_input"
	[ "$rc" -eq 0 ] && [ -n "$signature" ] || return 1
	printf '%s\n' "$signature"
}

remember_pbr_signature() {
	[ -n "$1" ] || return 0
	printf '%s\n' "$1" >"${pbr_signature_file}.new" || return 1
	mv "${pbr_signature_file}.new" "$pbr_signature_file"
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

# With the application's own routing a list change rewrites its dnsmasq sets
# (restarting dnsmasq when they changed) and never rebuilds PBR, which the
# first sync after the switch has already emptied of our policies.
perform_native_refresh() {
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

perform_restart() {
	if routing_native; then
		perform_native_refresh
		return
	fi
	"$system_helper" _sync-pbr || return 1
	policy_signature="$(pbr_policy_signature 2>/dev/null || true)"
	previous_signature="$(sed -n '1p' "$pbr_signature_file" 2>/dev/null || true)"
	pbr_reload=1
	if [ -n "$policy_signature" ] && [ "$policy_signature" = "$previous_signature" ] &&
	   "$pbr_init" running >/dev/null 2>&1; then
		pbr_reload=0
	fi
	if [ "$(uci -q get ikev2-manager.domains.engine 2>/dev/null || true)" = fakeip ] &&
	   [ -x "$domain_router_helper" ]; then
		"$domain_router_helper" refresh-rules || return 1
	fi
	"$xfrm_init" start || return 1
	if [ "$(uci -q get ikev2-manager.client.enabled 2>/dev/null || echo 0)" = 1 ]; then
		"$sync_vips_helper" || return 1
	fi
	# Some procd/PBR versions return a non-zero status after a successful reload.
	# Judge the live runtime instead. Never follow it with an automatic restart:
	# a slow reload may still own PBR while its init call has already returned,
	# and a second rebuild would extend the forwarding outage.
	if [ "$pbr_reload" = 1 ]; then
		logger -t ikev2-pbr-action "begin owner=manager action=reload pid=$$" 2>/dev/null || true
		"$pbr_init" reload >/dev/null 2>&1 || true
		if ! wait_for_pbr_runtime; then
			logger -t ikev2-pbr-action "error owner=manager action=reload pid=$$" 2>/dev/null || true
			return 1
		fi
		logger -t ikev2-pbr-action "end owner=manager action=reload pid=$$" 2>/dev/null || true
	fi
	"$pbr_init" running || return 1
	wait_for_router_dns 127.0.0.1 20 || return 1
	"$system_helper" failclosed-check || return 1
	ensure_forward_chain || return 1
	"$xfrm_init" start || return 1
	if [ "$(uci -q get ikev2-manager.client.enabled 2>/dev/null || echo 0)" = 1 ]; then
		"$sync_vips_helper" || return 1
	fi
	"$pbr_user_helper" || return 1
	[ ! -x "$discord_voice_helper" ] || "$discord_voice_helper" sync || return 1
	drop_reclassified_connections
	remember_pbr_signature "$policy_signature" || return 1
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
