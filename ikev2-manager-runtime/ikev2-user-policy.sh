#!/bin/sh

set -u
umask 077

config='ikev2-manager'
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
table="${IKEV2_USER_POLICY_TABLE:-ikev2_user_policy}"
users_db="${IKEV2_USERS_DB:-/etc/ikev2-manager/users.db}"
sessions_file="${IKEV2_SESSIONS_FILE:-}"
rules_out="${IKEV2_RULES_OUT:-}"
signature_file="${IKEV2_USER_POLICY_SIGNATURE:-/var/run/ikev2-user-policy.signature}"
session_state="${IKEV2_USER_POLICY_SESSIONS:-/var/run/ikev2-user-policy.sessions}"
policy_state="${IKEV2_USER_POLICY_FINGERPRINTS:-/var/run/ikev2-user-policy.policy}"
sync_lock_dir="${IKEV2_USER_POLICY_LOCK:-/var/run/ikev2-user-policy.lock}"
health_lock="${IKEV2_HEALTH_LOCK:-/var/run/ikev2-health.lock}"
refresh_interval="${IKEV2_USER_POLICY_REFRESH_INTERVAL:-30}"
# Consecutive failed reconciliations before the watcher gives up and lets procd
# respawn it. One failure is expected while charon restarts or an nft
# transaction races another table; a run of them means this process can no
# longer maintain the fail-closed sets and must be replaced rather than keep
# looping over a runtime that no longer matches the live sessions.
sync_failure_limit="${IKEV2_USER_POLICY_FAILURE_LIMIT:-3}"
swanctl_bin="${IKEV2_SWANCTL:-/usr/sbin/swanctl}"
sa_helper="${IKEV2_SA_HELPER:-/usr/libexec/ikev2-sa}"
socat_bin="${IKEV2_SOCAT:-/usr/bin/socat}"
event_source="${IKEV2_USER_POLICY_EVENT_SOURCE:-}"
uci_config_dir="${IKEV2_UCI_CONFIG_DIR:-/etc/config}"
uci_binary="${IKEV2_UCI_BIN:-/sbin/uci}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
client_state_dir="${IKEV2_CLIENT_STATE_DIR:-/etc/ikev2-manager/clients}"
ucode_bin="${IKEV2_UCODE:-ucode}"
. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/validate.sh"
. "$runtime_lib_dir/nft-runtime.sh"
# Backstop only. The VICI watcher reacts to inbound CHILD_SA events immediately
# and performs a full authoritative reconciliation. This timeout protects
# active sessions if the event stream is temporarily unavailable; the periodic
# reconciliation refreshes it independently of outbound and DNS health checks.
session_timeout="${IKEV2_USER_POLICY_TIMEOUT:-90s}"
direct_tproxy_address='127.0.0.1'
direct_tproxy_port='1603'
direct_tproxy_mark='0x00400001'
tproxy_mark='0x00400000'
tproxy_mask='0x00ff0000'
fakeip_range='198.18.0.0/15'

uci() {
	"$uci_binary" -c "$uci_config_dir" "$@"
}

stop_runtime() {
	if runtime_exists; then
		runtime_owned || {
			printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
			return 1
		}
		"$nft_bin" delete table inet "$table" >/dev/null 2>&1 || return 1
	fi
	rm -f "$signature_file" "$session_state" "$policy_state"
}

acquire_sync_lock() {
	attempt=0
	while [ "$attempt" -lt 6 ]; do
		pid_lock_acquire "$sync_lock_dir" && return 0
		attempt=$((attempt + 1))
		sleep 1
	done
	printf '%s\n' 'Inbound user-policy update is already running' >&2
	return 1
}

release_sync_lock() {
	pid_lock_release "$sync_lock_dir"
}

run_locked() {
	operation="$1"
	acquire_sync_lock || return 1
	if "$operation"; then
		result=0
	else
		result=$?
	fi
	release_sync_lock
	return "$result"
}

valid_ipv4_target() {
	local address prefix
	case "$1" in
		*/*)
			address="${1%/*}"
			prefix="${1#*/}"
			case "$prefix" in '' | *[!0-9]*) return 1 ;; esac
			[ "$prefix" -le 32 ] && valid_ipv4 "$address"
			;;
		*) valid_ipv4 "$1" ;;
	esac
}

valid_target_list() {
	local count target
	count=0
	for target in $1; do
		count=$((count + 1))
		[ "$count" -le 64 ] && valid_ipv4_target "$target" || return 1
	done
	[ "$count" -gt 0 ]
}

valid_device() {
	[ -n "$1" ] && [ "${#1}" -le 15 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.:@-]+$'
}

# BusyBox sort has no -o: it would silently leave the file untouched and print
# the sorted result on stdout instead. Duplicate elements then abort the whole
# nft transaction and every active client loses access when its timeout entry
# expires.
sort_unique_in_place() {
	file="$1"
	sort -u "$file" >"${file}.sorted" || return 1
	mv "${file}.sorted" "$file"
}

policy_section() {
	printf 'user_%s\n' "$(printf '%s' "$1" | sha256sum | awk '{ print substr($1, 1, 16) }')"
}

policy_value() {
	user="$1"
	option="$2"
	fallback="$3"
	section="$(policy_section "$user")"
	saved_user="$(uci -q get "$config.$section.username" 2>/dev/null || true)"
	if [ "$saved_user" = "$user" ]; then
		value="$(uci -q get "$config.$section.$option" 2>/dev/null || true)"
	else
		value=''
	fi
	printf '%s\n' "${value:-$fallback}"
}

user_exists() {
	awk -F '\t' -v user="$1" '$1 == user { found = 1 } END { exit found ? 0 : 1 }' \
		"$users_db" 2>/dev/null
}

network_device() {
	local interface device
	interface="$1"
	device="$(ubus call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(ubus call "network.interface.$interface" status 2>/dev/null |
			jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(uci -q get "network.$interface.device" 2>/dev/null || true)"
	valid_device "$device" && printf '%s\n' "$device"
}

collect_lan_devices() {
	output="$1"
	: >"$output"
	for wanted in $(uci -q get "$config.server.lan_zone" 2>/dev/null || echo lan); do
		uci show firewall 2>/dev/null |
			sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p' |
			while IFS= read -r section; do
			name="$(uci -q get "firewall.$section.name" 2>/dev/null || true)"
			if [ "$name" = "$wanted" ]; then
				for network in $(uci -q get "firewall.$section.network" 2>/dev/null || true); do
					network_device "$network" >>"$output" 2>/dev/null || true
				done
				for device in $(uci -q get "firewall.$section.device" 2>/dev/null || true); do
					valid_device "$device" && printf '%s\n' "$device" >>"$output"
				done
			fi
		done
	done
	sort_unique_in_place "$output"
}

lan_access_configured() {
	[ "$(uci -q get "$config.server.allow_lan" 2>/dev/null || echo 1)" = 1 ] &&
		return 0
	for section in $(uci show "$config" 2>/dev/null |
		sed -n "s/^${config}\.\([^.=]*\)=user_policy$/\1/p"); do
		case "$(uci -q get "$config.$section.lan_access" 2>/dev/null || true)" in
			all | limited) return 0 ;;
		esac
	done
	return 1
}

collect_sessions() {
	local output
	output="$1"
	: >"$output"
	if [ -n "$sessions_file" ]; then
		[ -r "$sessions_file" ] && cat "$sessions_file" >"$output"
		return
	fi
	# Only the inbound server's own connection is read, by key: the text
	# listing used to be cut into segments by pattern, and a connection listed
	# after a client could lend that client its address. The helper bounds the
	# VICI query, so a wedged charon cannot freeze the watcher, and a failed or
	# partial listing is an error, never an empty set of sessions.
	if ! "$sa_helper" sessions ikev2-in >"$output" 2>/dev/null; then
		: >"$output"
		printf '%s\n' 'Unable to list inbound strongSwan sessions' >&2
		return 1
	fi
}

write_address_set() {
	name="$1"
	file="$2"
	printf '  set %s {\n    type ipv4_addr\n    flags timeout\n    timeout %s\n' \
		"$name" "$session_timeout"
	if [ -s "$file" ]; then
		printf '    elements = { '
		set_elements "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

write_device_set() {
	file="$1"
	printf '  set lan_devices {\n    type ifname\n'
	if [ -s "$file" ]; then
		printf '    elements = { '
		awk 'BEGIN { first=1 } NF {
			if (!first) printf ", "
			printf "\"%s\"", $0
			first=0
		}' "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

resolve_access() {
	user="$1"
	global_router="$2"
	global_internet="$3"
	global_lan="$4"

	router="$(policy_value "$user" router_access inherit)"
	case "$router" in
		allow) resolved_router=1 ;;
		deny) resolved_router=0 ;;
		*) resolved_router="$global_router" ;;
	esac

	internet="$(policy_value "$user" internet_access inherit)"
	case "$internet" in
		allow) resolved_internet=1 ;;
		deny) resolved_internet=0 ;;
		*) resolved_internet="$global_internet" ;;
	esac

	lan="$(policy_value "$user" lan_access inherit)"
	case "$lan" in
		all | limited | deny) resolved_lan="$lan" ;;
		*) [ "$global_lan" = 1 ] && resolved_lan=all || resolved_lan=deny ;;
	esac

	pbr="$(policy_value "$user" pbr_mode inherit)"
	[ "$pbr" = exclude ] || pbr=inherit
}

sync_runtime() (
	enabled="$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)"
	configured="$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)"
	custom="$(uci -q get "$config.server.custom_config" 2>/dev/null || echo 0)"
	if [ "$enabled" != 1 ] || [ "$configured" != 1 ] || [ "$custom" = 1 ]; then
		stop_runtime
		return $?
	fi
	if runtime_exists && ! runtime_owned; then
		printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
		return 1
	fi

	pool="$(uci -q get "$config.server.pool4" 2>/dev/null || true)"
	case "$pool" in
		*-*) ;;
		*) printf '%s\n' 'Invalid inbound client pool' >&2; return 1 ;;
	esac
	if ! valid_ipv4 "${pool%%-*}" || ! valid_ipv4 "${pool#*-}"; then
		printf '%s\n' 'Invalid inbound client pool' >&2
		return 1
	fi

	work="${TMPDIR:-/tmp}/ikev2-user-policy.$$"
	mkdir -p "$work" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	collect_sessions "$work/sessions" || return 1
	sort_unique_in_place "$work/sessions" || return 1
	# A lingering SA can still hold an address the pool has already handed to
	# the next user. Applying both identities would grant that address the
	# union of two policies, so an ambiguous address is dropped entirely.
	awk -F '\t' '
		NR == FNR { if (seen[$2]++ == 0) owner[$2] = $1; else if (owner[$2] != $1) bad[$2] = 1; next }
		!($2 in bad)
	' "$work/sessions" "$work/sessions" >"$work/sessions.filtered" || return 1
	mv "$work/sessions.filtered" "$work/sessions"
	collect_lan_devices "$work/lan-devices"
	if lan_access_configured && [ ! -s "$work/lan-devices" ]; then
		printf '%s\n' 'Unable to resolve an interface for the inbound LAN zones' >&2
		return 1
	fi
	: >"$work/router"
	: >"$work/internet"
	: >"$work/lan-full"
	: >"$work/pbr-excluded"
	: >"$work/limited"
	: >"$work/public"

	global_router="$(uci -q get "$config.server.allow_router" 2>/dev/null || echo 0)"
	global_internet="$(uci -q get "$config.server.allow_internet" 2>/dev/null || echo 1)"
	global_lan="$(uci -q get "$config.server.allow_lan" 2>/dev/null || echo 1)"
	mapped=0
	: >"$work/policy"
	while IFS="$(printf '\t')" read -r user vip extra; do
		[ -z "${extra:-}" ] || continue
		if ! valid_user "$user" || ! valid_ipv4 "$vip" || ! user_exists "$user"; then
			continue
		fi
		targets=''
		resolve_access "$user" "$global_router" "$global_internet" "$global_lan"
		public_ports="$(normalize_list "$(policy_value "$user" public_ports '')")"
		valid_port_list "$public_ports" || {
			printf 'Invalid public router port list for VPN user %s\n' "$user" >&2
			return 1
		}
		[ -z "$public_ports" ] ||
			printf '%s\t%s\n' "$vip" "$public_ports" >>"$work/public"
		[ "$resolved_router" = 1 ] && printf '%s\n' "$vip" >>"$work/router"
		[ "$resolved_internet" = 1 ] && printf '%s\n' "$vip" >>"$work/internet"
		case "$resolved_lan" in
			all) printf '%s\n' "$vip" >>"$work/lan-full" ;;
			limited)
				targets="$(normalize_list "$(policy_value "$user" lan_targets '')")"
				valid_target_list "$targets" || {
					printf 'Invalid local target list for VPN user %s\n' "$user" >&2
					return 1
				}
				printf '%s\t%s\n' "$vip" "$targets" >>"$work/limited"
				;;
		esac
		[ "$pbr" = exclude ] && printf '%s\n' "$vip" >>"$work/pbr-excluded"
		# What this address may reach, for deciding whose connections a change
		# has to end.
		printf '%s\t%s|%s|%s|%s|%s|%s|%s\n' "$vip" "$user" "$resolved_router" \
			"$resolved_internet" "$resolved_lan" "$targets" "$public_ports" "$pbr" \
			>>"$work/policy"
		mapped=$((mapped + 1))
	done <"$work/sessions"
	for file in router internet lan-full pbr-excluded; do
		sort_unique_in_place "$work/$file" || return 1
	done

	wan_values="$(mark_values "$(routing_mark_rule wan)")" || wan_values=''
	if [ -s "$work/pbr-excluded" ] && [ -z "$wan_values" ]; then
		printf '%s\n' 'Unable to derive the WAN routing mark' >&2
		return 1
	fi
	wan_clear="${wan_values%% *}"
	wan_mark="${wan_values#* }"
	domain_engine="$(uci -q get "$config.domains.engine" 2>/dev/null || echo nftset)"
	if [ "$domain_engine" = fakeip ] && [ -s "$work/pbr-excluded" ]; then
		case "$fakeip_range" in
			*/*) valid_ipv4_target "$fakeip_range" ;;
			*) false ;;
		esac || {
			printf '%s\n' 'Invalid FakeIP range for the inbound routing exclusion' >&2
			return 1
		}
	fi

	managed_input_rule=''
	managed_wan_rule=''
	if [ -f "$client_state_dir/initialized" ]; then
		managed_subnet="$("$ucode_bin" "$runtime_lib_dir/client-access-runtime.uc" subnet "$client_state_dir" '' '' 2>/dev/null)" || managed_subnet=''
		if [ -n "$managed_subnet" ] && valid_ipv4_target "$managed_subnet"; then
			# Only SA/tuple admission sets this mark. The independent path guard
			# rejects unmarked virtual traffic, including a missing admission table.
			managed_input_rule="    iifname \"ipsec-in\" ip daddr $managed_subnet meta mark == 0x00800000 return"
			managed_wan_rule="$managed_input_rule"
		fi
	fi
	rules="$work/rules.nft"
	{
		runtime_exists && printf 'delete table inet %s\n' "$table"
		printf 'table inet %s {\n' "$table"
		cat <<'EOF'
  chain ikev2_manager_owned {
    comment "IKEv2 Manager inbound user policy"
  }

EOF
		printf '  set inbound_pool {\n    type ipv4_addr\n    flags interval\n'
		printf '    elements = { %s }\n  }\n\n' "$pool"
		write_device_set "$work/lan-devices"
		write_address_set router_allowed "$work/router"
		write_address_set internet_allowed "$work/internet"
		write_address_set lan_full "$work/lan-full"
		write_address_set pbr_excluded "$work/pbr-excluded"

		limited_index=0
		while IFS="$(printf '\t')" read -r vip targets; do
			limited_index=$((limited_index + 1))
			printf '  set lan_limited_%s {\n' "$limited_index"
			printf '    type ipv4_addr\n    flags timeout\n    timeout %s\n' "$session_timeout"
			printf '    elements = { %s }\n  }\n\n' "$vip"
		done <"$work/limited"

		public_index=0
		while IFS="$(printf '\t')" read -r vip ports; do
			public_index=$((public_index + 1))
			printf '  set public_client_%s {\n' "$public_index"
			printf '    type ipv4_addr\n    flags timeout\n    timeout %s\n' "$session_timeout"
			printf '    elements = { %s }\n  }\n\n' "$vip"
		done <"$work/public"

		cat <<EOF
  chain input {
    type filter hook input priority -1; policy accept;
$managed_input_rule
    iifname "ipsec-in" ip saddr @inbound_pool meta l4proto { tcp, udp } th dport 53 return
    iifname "ipsec-in" ip saddr @inbound_pool meta mark & $tproxy_mask == $tproxy_mark ip saddr @internet_allowed return
    iifname "ipsec-in" ip saddr @inbound_pool meta mark & $tproxy_mask == $tproxy_mark counter drop
EOF
		public_index=0
		while IFS="$(printf '\t')" read -r vip ports; do
			public_index=$((public_index + 1))
			printf '    iifname "ipsec-in" ip saddr @public_client_%s meta l4proto { tcp, udp } th dport { ' \
				"$public_index"
			printf '%s' "$ports" | tr ' ' ',' | sed 's/,/, /g'
			printf ' } return\n'
		done <"$work/public"
		cat <<EOF
    iifname "ipsec-in" ip saddr @router_allowed return
    iifname "ipsec-in" ip saddr @inbound_pool counter drop
  }

  chain forward {
    type filter hook forward priority -1; policy accept;
    iifname "ipsec-in" ip saddr @inbound_pool jump inbound_policy
  }

  chain inbound_policy {
    ip daddr @inbound_pool counter drop
    oifname @lan_devices jump lan_policy
    ip saddr @internet_allowed return
    counter drop
  }

  chain lan_policy {
    ip saddr @lan_full return
EOF
		limited_index=0
		while IFS="$(printf '\t')" read -r vip targets; do
			limited_index=$((limited_index + 1))
			printf '    ip saddr @lan_limited_%s ip daddr { ' "$limited_index"
			printf '%s' "$targets" | tr ' ' ',' | sed 's/,/, /g'
			printf ' } return\n'
		done <"$work/limited"
		cat <<'EOF'
    counter drop
  }
EOF
		if [ -s "$work/pbr-excluded" ] && [ "$domain_engine" = fakeip ]; then
			cat <<EOF

  chain direct_tproxy {
    type filter hook prerouting priority -153; policy accept;
    iifname "ipsec-in" ip saddr @pbr_excluded ip daddr $fakeip_range meta l4proto tcp meta mark set $direct_tproxy_mark tproxy ip to $direct_tproxy_address:$direct_tproxy_port counter accept
    iifname "ipsec-in" ip saddr @pbr_excluded ip daddr $fakeip_range meta l4proto udp meta mark set $direct_tproxy_mark tproxy ip to $direct_tproxy_address:$direct_tproxy_port counter accept
  }
EOF
		fi
		if [ -s "$work/pbr-excluded" ]; then
			cat <<EOF

  chain direct_wan {
    type filter hook prerouting priority -149; policy accept;
$managed_wan_rule
    iifname "ipsec-in" ip saddr @pbr_excluded meta mark & $tproxy_mask != $tproxy_mark meta mark set meta mark & $wan_clear | $wan_mark counter accept
  }
EOF
		fi
		echo '}'
	} >"$rules"

	if [ -n "$rules_out" ]; then
		cp "$rules" "$rules_out"
	else
		"$nft_bin" -c -f "$rules" >/dev/null 2>&1 || {
			printf '%s\n' 'Inbound user-policy nftables validation failed' >&2
			return 1
		}
		"$nft_bin" -f "$rules" >/dev/null 2>&1 || {
			printf '%s\n' 'Unable to install inbound user-policy rules' >&2
			return 1
		}
		signature="$({
			sed "/^delete table inet $table$/d" "$rules"
			cat "$work/sessions"
		} | sha256sum | awk '{ print $1 }')"
		# End the connections of an address only when what it may reach
		# changed: its user or that user's access, a session that ended, or a
		# new one whose address may have belonged to someone else. Any client
		# connecting or leaving used to end every other client's connections,
		# and for a client behind the router's NAT that is a dropped
		# connection. Settings shared by every client are part of each
		# fingerprint, so changing them still ends all of them.
		shared="$({
			cat "$work/lan-devices"
			printf '%s\n' "$pool" "$domain_engine" "$wan_values"
		} | sha256sum | awk '{ print $1 }')"
		awk -F '\t' -v shared="$shared" '{ print $1 "\t" $2 "|" shared }' "$work/policy" |
			sort -u >"$work/policy.state"
		if command -v conntrack >/dev/null 2>&1; then
			# An older state has addresses only; every one of them differs once.
			if [ -f "$policy_state" ]; then
				cat "$policy_state" >"$work/policy.before"
			else
				awk '{ print $1 "\told" }' "$session_state" >"$work/policy.before" 2>/dev/null ||
					: >"$work/policy.before"
			fi
			# Files are told apart by name: NR == FNR misreads an empty first file.
			awk -F '\t' -v now_file="$work/policy.state" '
				FILENAME == now_file { now[$1] = $2; seen[$1] = 1; next }
				{ before[$1] = $2; seen[$1] = 1 }
				END { for (address in seen) if (now[address] != before[address]) print address }
			' "$work/policy.state" "$work/policy.before" | sort -u |
				while IFS= read -r address; do
					valid_ipv4 "$address" || continue
					conntrack -D -s "$address" >/dev/null 2>&1 || :
				done
		fi
		mkdir -p "${policy_state%/*}"
		cp "$work/policy.state" "${policy_state}.new" && chmod 600 "${policy_state}.new" &&
			mv "${policy_state}.new" "$policy_state"
		mkdir -p "${signature_file%/*}" "${session_state%/*}"
		# The fingerprint of what the kernel now holds, next to the signature:
		# a later check notices any change to the table, not only the rules it
		# looks for by name.
		record_runtime "$signature_file" "$signature" || {
			printf '%s\n' 'Unable to read back the installed inbound user-policy rules' >&2
			return 1
		}
		awk -F '\t' 'NF >= 2 { print $2 }' "$work/sessions" |
			sort -u >"${session_state}.new"
		chmod 600 "${session_state}.new"
		mv "${session_state}.new" "$session_state"
	fi
	printf 'mapped=%s\n' "$mapped"
	rm -rf "$work"
	trap - EXIT INT TERM
)

check_runtime() {
	enabled="$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)"
	configured="$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)"
	custom="$(uci -q get "$config.server.custom_config" 2>/dev/null || echo 0)"
	if [ "$enabled" != 1 ] || [ "$configured" != 1 ] || [ "$custom" = 1 ]; then
		! runtime_exists
		return
	fi
	runtime_owned || return 1
	local input forward policy set_name
	input="$("$nft_bin" list chain inet "$table" input 2>/dev/null)" || return 1
	forward="$("$nft_bin" list chain inet "$table" forward 2>/dev/null)" || return 1
	policy="$("$nft_bin" list chain inet "$table" inbound_policy 2>/dev/null)" || return 1
	printf '%s\n' "$input" | grep -q 'hook input' || return 1
	printf '%s\n' "$input" | grep -Eq 'ip saddr @inbound_pool.*drop' || return 1
	printf '%s\n' "$forward" | grep -q 'hook forward' || return 1
	printf '%s\n' "$forward" | grep -q 'jump inbound_policy' || return 1
	printf '%s\n' "$policy" | grep -Eq 'ip daddr @inbound_pool.*drop' || return 1
	for set_name in inbound_pool internet_allowed router_allowed lan_full pbr_excluded; do
		"$nft_bin" list set inet "$table" "$set_name" >/dev/null 2>&1 || return 1
	done
	# The checks above name the fail-closed rules; the fingerprint catches
	# every other change - a user's rule altered, an allow rule added, an
	# address taken out of a set - that would leave them all in place.
	runtime_unchanged "$signature_file" || return 1
	# Structure alone cannot tell a healthy runtime from one that stopped
	# reconciling: the table and all five sets survive intact while the sets sit
	# empty, and the fail-closed rules then drop every inbound client. Compare
	# the live sessions against the state the last successful sync recorded, so a
	# runtime that no longer tracks them reports unhealthy and the health watcher
	# repairs it.
	local sessions user vip extra stale last_sync now age
	# A live watcher normally writes this file every 30 seconds. Session
	# membership alone cannot detect a watcher stuck on an unchanged SA set.
	[ -f "$session_state" ] || return 1
	last_sync="$(date -r "$session_state" +%s 2>/dev/null)" || return 1
	now="$(date +%s)" || return 1
	age=$((now - last_sync))
	[ "$age" -ge 0 ] && [ "$age" -le 75 ] || return 1
	sessions="${TMPDIR:-/tmp}/ikev2-user-policy-check.$$"
	collect_sessions "$sessions" || {
		rm -f "$sessions"
		return 1
	}
	stale=0
	while IFS="$(printf '\t')" read -r user vip extra; do
		[ -z "${extra:-}" ] || continue
		valid_ipv4 "$vip" || continue
		grep -qxF "$vip" "$session_state" 2>/dev/null || stale=1
	done <"$sessions"
	rm -f "$sessions"
	[ "$stale" -eq 0 ]
}

monitor_source() {
	# swanctl uses stdio and does not explicitly flush every VICI event. socat
	# gives it a PTY so each newline is delivered immediately instead of waiting
	# for a pipe buffer. stderr is intentionally discarded: a monitor failure is
	# reported by the parent watcher and recovered by procd.
	exec "$swanctl_bin" --monitor-sa --raw 2>/dev/null
}

# swanctl --monitor-sa ends itself, when charon goes away, with kill(0, SIGINT):
# its whole process group. Run by procd that group is procd's own, and procd
# takes SIGINT as a reboot - every charon restart rebooted the router. setsid
# gives the monitor a session and group of its own. See docs/TRAPS.md.
run_event_source() {
	if [ -n "$event_source" ]; then
		exec "$event_source"
	fi
	[ -x "$socat_bin" ] || return 127
	exec "$socat_bin" -u "EXEC:$0 monitor-source,pty,rawer,setsid" STDOUT
}

# One reconciliation, with the helper's own diagnosis preserved. The watcher
# used to discard both the output and the exit status, so a runtime that had
# stopped tracking sessions looked identical to a healthy one: procd saw a live
# process, the log stayed silent, and the fail-closed rules dropped every
# inbound client until someone restarted the service by hand. procd already
# forwards this stderr to syslog.
sync_once() {
	reason="$("$0" sync 2>&1 >/dev/null)" && return 0
	reason="$(printf '%s' "$reason" | tr '\n' ';')"
	if [ -n "$reason" ]; then
		printf 'Inbound user-policy reconciliation failed: %s\n' "$reason" >&2
	else
		printf '%s\n' 'Inbound user-policy reconciliation failed' >&2
	fi
	return 1
}

watch_runtime() {
	case "$refresh_interval" in
		'' | *[!0-9]* | 0)
			printf '%s\n' 'Invalid inbound user-policy refresh interval' >&2
			return 1
			;;
	esac
	raw="${TMPDIR:-/tmp}/ikev2-user-policy-watch.$$"
	events="${raw}.events"
	monitor_pid=''
	refresh_pid=''
	sync_failures=0
	cleanup_watcher() {
		if [ -n "$refresh_pid" ]; then
			kill "$refresh_pid" 2>/dev/null || true
			wait "$refresh_pid" 2>/dev/null || true
			refresh_pid=''
		fi
		if [ -n "$monitor_pid" ]; then
			kill "$monitor_pid" 2>/dev/null || true
			wait "$monitor_pid" 2>/dev/null || true
			monitor_pid=''
		fi
		exec 3>&- 3<&-
		rm -f "$raw" "${raw}.new" "$events"
	}
	reload_watcher() {
		cleanup_watcher
		exec "$0" watch
	}
	trap 'cleanup_watcher; exit 0' INT TERM
	trap reload_watcher HUP
	trap cleanup_watcher EXIT
	rm -f "$events"
	mkfifo "$events" || return 1
	# Open both ends before starting the producer, otherwise either side may
	# block while procd is starting or stopping the service.
	exec 3<>"$events"
	# Preserve the boot-time fail-closed guard even if charon is not ready yet.
	sync_once || true
	(
		source_pid=''
		stop_source() {
			[ -z "$source_pid" ] || kill "$source_pid" 2>/dev/null || true
			[ -z "$source_pid" ] || wait "$source_pid" 2>/dev/null || true
		}
		trap 'stop_source; exit 0' INT TERM
		run_event_source &
		source_pid=$!
		wait "$source_pid"
		rc=$?
		source_pid=''
		printf 'ikev2-monitor-exit=%s\n' "$rc"
	) >"$events" 2>/dev/null &
	monitor_pid=$!
	(
		sleeper_pid=''
		stop_refresh() {
			[ -z "$sleeper_pid" ] || kill "$sleeper_pid" 2>/dev/null || true
			[ -z "$sleeper_pid" ] || wait "$sleeper_pid" 2>/dev/null || true
			exit 0
		}
		trap stop_refresh INT TERM
		while true; do
			sleep "$refresh_interval" &
			sleeper_pid=$!
			wait "$sleeper_pid"
			sleeper_pid=''
			printf '%s\n' ikev2-refresh
		done
	) >"$events" 2>/dev/null &
	refresh_pid=$!
	# Close the registration gap: an SA established before VICI subscribed is
	# covered by this second snapshot, while an event already queued in the FIFO
	# merely causes one harmless additional reconciliation.
	sleep 1
	sync_once || true
	while true; do
		IFS= read -r event <&3 || return 1
		case "$event" in
			ikev2-monitor-exit=*)
				printf '%s\n' 'Inbound VICI monitor stopped' >&2
				return 1
				;;
			'child-updown event {'*'proxy-out {'*|'child-updown event {'*'proxy-out-'[2-7]' {'*)
				# The outbound tunnels are the health watcher's: wake it, so the
				# routes that follow a tunnel follow at once.
				health_pid=''
				read -r health_pid 2>/dev/null <"$health_lock/pid" || :
				case "$health_pid" in '' | *[!0-9]*) ;; *) kill -USR1 "$health_pid" 2>/dev/null || : ;; esac
				;;
			ikev2-refresh|'child-updown event {'*'ikev2-in {'*)
				# The timer is the recovery path for a lost event and refreshes
				# timeout-backed set elements without polling every two seconds.
				if sync_once; then
					sync_failures=0
				else
					sync_failures=$((sync_failures + 1))
					if [ "$sync_failures" -ge "$sync_failure_limit" ]; then
						printf 'Inbound user-policy reconciliation failed %s times in a row\n' \
							"$sync_failures" >&2
						return 1
					fi
				fi
				;;
		esac
	done
}

case "${1:-sync}" in
	sync) run_locked sync_runtime ;;
	stop) run_locked stop_runtime ;;
	check) check_runtime ;;
	watch) watch_runtime ;;
	monitor-source) monitor_source ;;
	*) printf 'usage: %s [sync|stop|check|watch|monitor-source]\n' "$0" >&2; exit 2 ;;
esac
