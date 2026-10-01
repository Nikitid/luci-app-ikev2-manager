#!/bin/sh
# /usr/libexec/ikev2-devices
# Per-device routing mode manager for the independent nftables policy.
#
# Commands:
#   dump                         — list current state (domain/fullroute/exclude)
#   clients                      — list active local IPv4 neighbours
#   zones                        — list firewall zones and their logical networks
#   add-subnet    <addr>         — add addr to the base domain policy
#   remove-subnet <addr>         — remove addr from the base domain policy
#   add-override  <addr> <mode>  — mode: fullroute | exclude
#   remove-override <addr>       — remove fullroute/exclude policy for addr

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

BASE_RULE='ikev2pbr_domains'
APP_CONFIG='ikev2-manager'
DEST_FILES='file:///etc/pbr-ikev2-domains.txt file:///etc/pbr-ikev2-service-cidrs.txt'
RESTART_HELPER="${IKEV2_RESTART_HELPER:-/usr/libexec/ikev2-domains-restart}"
DEVICE_RUNTIME_HELPER="${IKEV2_DEVICE_RUNTIME_HELPER:-/usr/libexec/ikev2-device-routing}"
SYSTEM_HELPER="${IKEV2_SYSTEM_HELPER:-/usr/libexec/ikev2-manager-system}"
DHCP_LEASES="${IKEV2_DHCP_LEASES:-/tmp/dhcp.leases}"
PBR_CONFIG="${IKEV2_PBR_CONFIG:-/etc/config/pbr}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/devices.sh"
. "$runtime_lib_dir/controller.sh"

valid_addr() { device_valid_address "$1"; }

# Commit and then synchronously re-apply the affected runtime. On any failure
# the exact previous UCI package is put back and re-applied.
restart_pbr() {
	case "${1:-full}" in
		device) "$DEVICE_RUNTIME_HELPER" sync ;;
		firewall | device-firewall) "$DEVICE_RUNTIME_HELPER" sync ;;
		*) "$RESTART_HELPER" --wait ;;
	esac
}

# A convenience preset for devices that must bypass every project-managed
# path. It remains ordinary device_policy state, so every choice can still be
# adjusted independently afterwards.
cmd_set_unmanaged() {
	local addr="${1:-}" backup mode='device-firewall'
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }

	backup="$(backup_pbr)" || return 1
	if ! device_migrate || ! device_set "$addr" exclude ||
	   ! device_set_flag "$addr" dns_passthrough 1 ||
	   ! device_set_flag "$addr" dpi_passthrough 1 ||
	   ! render_policies; then
		restore_pbr "$backup" "$mode"
		return 1
	fi
	commit_and_restart "$backup" "$mode"
}

# Store the three exclusion switches as one transaction. PBR exclusion is the
# route_mode=exclude override; DNS and Zapret remain independent flags.
cmd_set_exclusions() {
	local addr="${1:-}" pbr="${2:-}" dns="${3:-}" dpi="${4:-}" backup current value
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
	for value in "$pbr" "$dns" "$dpi"; do
		case "$value" in 0 | 1) ;; *) printf 'switch values must be 0 or 1\n' >&2; return 1 ;; esac
	done

	backup="$(backup_pbr)" || return 1
	if ! device_migrate; then
		restore_pbr "$backup" device-firewall
		return 1
	fi
	current="$(device_mode "$addr")"
	if [ "$pbr" = 1 ]; then
		device_set "$addr" exclude || { restore_pbr "$backup" device-firewall; return 1; }
	else
		case "$current" in
			exclude | fullroute | none) device_remove "$addr" || {
				restore_pbr "$backup" device-firewall; return 1; } ;;
		esac
	fi
	if ! device_set_flag "$addr" dns_passthrough "$dns" ||
	   ! device_set_flag "$addr" dpi_passthrough "$dpi" ||
	   ! render_policies; then
		restore_pbr "$backup" device-firewall
		return 1
	fi
	commit_and_restart "$backup" device-firewall
}

# Full-VPN inclusion intentionally carries no exclusion flags.
cmd_set_included() {
	local addr="${1:-}" backup
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
	backup="$(backup_pbr)" || return 1
	if ! device_migrate || ! device_set "$addr" fullroute ||
	   ! device_set_flag "$addr" dns_passthrough 0 ||
	   ! device_set_flag "$addr" dpi_passthrough 0 ||
	   ! render_policies; then
		restore_pbr "$backup" device-firewall
		return 1
	fi
	commit_and_restart "$backup" device-firewall
}

# Remove the row as a whole. An explicit domain-policy member keeps that mode;
# only its exclusions are cleared.
cmd_clear_policy() {
	local addr="${1:-}" backup current
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
	backup="$(backup_pbr)" || return 1
	if ! device_migrate; then
		restore_pbr "$backup" device-firewall
		return 1
	fi
	current="$(device_mode "$addr")"
	case "$current" in
		fullroute | exclude | none) device_remove "$addr" || {
			restore_pbr "$backup" device-firewall; return 1; } ;;
	esac
	if ! device_set_flag "$addr" dns_passthrough 0 ||
	   ! device_set_flag "$addr" dpi_passthrough 0 ||
	   ! render_policies; then
		restore_pbr "$backup" device-firewall
		return 1
	fi
	commit_and_restart "$backup" device-firewall
}

# PBR's configuration is part of the snapshot only where it exists: a router
# that never had PBR has no /etc/config/pbr, and exporting it failed, so no
# device setting could be changed at all.
restore_pbr() {
	local backup="$1" restart_mode="${2:-full}"
	if { [ -e "$backup/pbr" ] && ! uci import pbr <"$backup/pbr" >/dev/null 2>&1; } ||
	   ! uci import "$APP_CONFIG" <"$backup/app" >/dev/null 2>&1 ||
	   { [ -e "$backup/pbr" ] && ! uci commit pbr >/dev/null 2>&1; } ||
	   ! uci commit "$APP_CONFIG" >/dev/null 2>&1 ||
	   ! restart_pbr "$restart_mode" >/dev/null 2>&1; then
		printf '%s\n' 'Device rollback incomplete; previous configuration snapshot retained' >&2
		return 1
	fi
	rm -rf "$backup"
}

# Conntrack deletion does not close an accepted userspace TProxy socket.
# Use sing-box's authenticated loopback API to retire just this source's flows.
close_device_connections() (
	local address="$1" work object id source prefix network
	[ "$(uci -q get "$APP_CONFIG.domains.engine" 2>/dev/null || true)" = fakeip ] || return 0
	[ "$(uci -q get "$APP_CONFIG.domains.paused" 2>/dev/null || echo 0)" != 1 ] || return 0
	work="$(mktemp -d)" || return 1
	trap 'rm -rf "$work"' EXIT
	trap 'exit 1' INT TERM
	controller_curl_config "$work" || return 1
	curl -4fsS --noproxy '*' --connect-timeout 2 --max-time 3 \
		--config "$work/curl.conf" "http://$controller_address/connections" >"$work/connections" || return 1
	[ "$(jsonfilter -i "$work/connections" -t '@.connections')" = array ] || return 1
	jsonfilter -i "$work/connections" -e '@.connections[*]' >"$work/objects"
	network="${address%/*}"; prefix="${address#*/}"
	[ "$prefix" != "$address" ] || prefix=32
	while IFS= read -r object; do
		source="$(jsonfilter -s "$object" -e '@.metadata.sourceIP')" || return 1
		# API metadata is untrusted input. Only validated IPv4 sources can match.
		printf '%s\n' "$source" | awk -v network="$network" -v prefix="$prefix" '
			function ipv4(s, a,n,i,v) {
				n=split(s,a,"."); if(n!=4) return -1
				v=0; for(i=1;i<=4;i++) {
					if(a[i]!~/^[0-9]+$/ || a[i]>255) return -1
					v=v*256+a[i]
				} return v
			}
			{ s=ipv4($0); n=ipv4(network); size=2^(32-prefix)
			  exit !(s>=0 && n>=0 && int(s/size)==int(n/size)) }
		' || continue
		id="$(jsonfilter -s "$object" -e '@.id')" || return 1
		printf '%s' "$id" | grep -Eq '^[0-9a-fA-F-]{36}$' || return 1
		curl -4fsS --noproxy '*' --connect-timeout 2 --max-time 3 \
			--config "$work/curl.conf" -X DELETE \
			"http://$controller_address/connections/$id" >/dev/null || return 1
	done <"$work/objects"
)

commit_and_restart() {
	local backup="$1" restart_mode="${2:-full}" result=0
	# Removing a legacy duplicate from UCI is not enough: its rule can still be
	# active in PBR's current nftables program. Force one checked rebuild at the
	# migration boundary; subsequent device-only edits stay on the fast path.
	[ "${device_pbr_legacy_removed:-0}" = 0 ] || restart_mode=full
	[ ! -e "$backup/pbr" ] || uci commit pbr || result=1
	uci commit "$APP_CONFIG" || result=1
	if [ "$result" = 0 ]; then
		restart_pbr "$restart_mode" || result=1
	fi
	if [ "$result" = 0 ] && [ -n "${addr:-}" ]; then
		close_device_connections "$addr" || result=1
	fi
	if [ "$result" = 0 ] && [ -n "${addr:-}" ]; then
		if ! conntrack -D -s "$addr" >"$backup/conntrack.log" 2>&1; then
			# conntrack returns 1 for an empty match as well as real errors.
			grep -Eq '0 flow entries have been deleted' "$backup/conntrack.log" || result=1
		fi
	fi
	if [ "$result" != 0 ]; then
		restore_pbr "$backup" "$restart_mode"
		return 1
	fi
	rm -rf "$backup"
}

# Remove legacy PBR artefacts. The independent early nftables table is the only
# live implementation of full-route and exclusion overrides.
render_policies() {
	device_pbr_render "$BASE_RULE" "$DEST_FILES"
}

backup_pbr() {
	local backup
	backup="$(mktemp -d)" || return 1
	if { [ -e "$PBR_CONFIG" ] && ! uci export pbr >"$backup/pbr"; } ||
	   ! uci export "$APP_CONFIG" >"$backup/app"; then
		rm -rf "$backup"
		return 1
    fi
    printf '%s\n' "$backup"
}

# Domain-mode devices follow the shared policy; override modes are applied by
# ikev2-device-routing before PBR evaluates its own rules.
cmd_dump() {
	local work address mode flags
	work="$(mktemp)" || return 1
	if ! device_list >"$work"; then
		rm -f "$work"
		return 1
	fi
	while read -r address mode; do
		[ -n "$address" ] || continue
		flags=''
		device_flag_enabled "$address" dns_passthrough && flags="$flags dns=1"
		device_flag_enabled "$address" dpi_passthrough && flags="$flags dpi=1"
		case "$mode" in
			none)
				printf 'addr=%s mode=none%s\n' "$address" "$flags"
				;;
			domain)
				printf 'addr=%s mode=domain%s\n' "$address" "$flags"
				;;
			fullroute)
				printf 'addr=%s mode=fullroute%s\n' "$address" "$flags"
				;;
			exclude)
				printf 'addr=%s mode=exclude%s\n' "$address" "$flags"
				;;
		esac
	done <"$work"
	rm -f "$work"
}

# Opt-outs are independent of the routing mode, so they are set separately and
# each one re-applies only the runtime it actually affects.
cmd_set_flag() {
	local addr="${1:-}" flag="${2:-}" value="${3:-}" backup mode
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
	device_valid_flag "$flag" || { printf 'unknown flag: %s\n' "$flag" >&2; return 1; }
	case "$value" in
		0 | 1) ;;
		*) printf 'flag value must be 0 or 1\n' >&2; return 1 ;;
	esac
	case "$flag" in
		dns_passthrough) mode='firewall' ;;
		*) mode='device' ;;
	esac

	backup="$(backup_pbr)" || return 1
	if ! device_migrate || ! device_set_flag "$addr" "$flag" "$value" ||
	   ! render_policies; then
		restore_pbr "$backup" "$mode"
		return 1
	fi
	commit_and_restart "$backup" "$mode"
}

# A subnet joins the shared domain policy. Rendering it into the base policy is
# the system helper's job, so this path needs the full restart.
cmd_add_subnet() {
	local addr="${1:-}" backup
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
	[ "$(device_mode "$addr")" = domain ] && return 0

	backup="$(backup_pbr)" || return 1
	if ! device_migrate || ! device_set "$addr" domain || ! render_policies; then
		restore_pbr "$backup"
		return 1
	fi
	commit_and_restart "$backup"
}

cmd_remove_subnet() {
	local addr="${1:-}" backup
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
	[ "$(device_mode "$addr")" = domain ] || return 0

	backup="$(backup_pbr)" || return 1
	if ! device_migrate || ! device_remove "$addr" || ! render_policies; then
		restore_pbr "$backup"
		return 1
	fi
	commit_and_restart "$backup"
}

cmd_add_override() {
	local addr="${1:-}" mode="${2:-}" backup
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }
	case "$mode" in
		fullroute | exclude) ;;
		*) printf 'unknown mode: %s\n' "$mode" >&2; return 1 ;;
	esac

	backup="$(backup_pbr)" || return 1
	if ! device_migrate || ! device_set "$addr" "$mode" || ! render_policies; then
		restore_pbr "$backup"
		return 1
	fi
	commit_and_restart "$backup" device
}

# Removing an override returns the address to the default device policy. DNS
# and DPI bypass flags are independent and remain unchanged.
cmd_remove_override() {
	local addr="${1:-}" backup
	valid_addr "$addr" || { printf 'valid IPv4 address or subnet required\n' >&2; exit 1; }

	backup="$(backup_pbr)" || return 1
	if ! device_migrate || ! device_remove "$addr" || ! render_policies; then
		restore_pbr "$backup"
		return 1
	fi
	commit_and_restart "$backup" device
}

# Active local IPv4 neighbours, enriched with DHCP lease names. The WAN next
# hop and unresolved entries are excluded; the UI retains a Custom option for
# sleeping, static or routed clients that are not visible at this moment.
cmd_clients() {
	local tmp wan_device
	tmp="$(mktemp)" || return 1
	trap 'rm -f "$tmp"' EXIT INT TERM
	wan_device="$(ip -4 route show default 2>/dev/null |
		sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)"
	ip -4 neigh show 2>/dev/null >"$tmp"
	awk -v wan="$wan_device" '
		NR == FNR {
			if (NF >= 4) { lease_mac[$3] = $2; lease_name[$3] = $4 }
			next
		}
		{
			ip = $1; dev = ""; mac = ""; state = $NF
			for (i = 2; i <= NF; i++) {
				if ($i == "dev" && i < NF) dev = $(i + 1)
				if ($i == "lladdr" && i < NF) mac = $(i + 1)
			}
			if (dev == "" || dev == wan || dev == "lo" || dev == "ipsec-in" ||
			    mac == "" || state == "FAILED" || state == "INCOMPLETE") next
			name = lease_name[ip]
			if (name == "*" || name == "-") name = ""
			if (mac == "") mac = lease_mac[ip]
			# BusyBox sort has no key fields and ignores -t/-k silently, and
			# its -n overflows past 2^31, so the address is sorted as text by a
			# zero-padded prefix that is cut off after.
			split(ip, o, ".")
			printf "%03d%03d%03d%03d\t%s\t%s\t%s\n", o[1], o[2], o[3], o[4], ip, name, mac
		}' "$DHCP_LEASES" "$tmp" 2>/dev/null | sort | cut -f2-
	rm -f "$tmp"
	trap - EXIT INT TERM
}

# List logical OpenWrt networks that have an IPv4 subnet, as name=CIDR lines.
# Used by the UI to offer a pick-list instead of free-text subnet entry.
cmd_networks() {
    local names n st addr mask
    names=$(ubus call network.interface dump 2>/dev/null \
        | jsonfilter -e '@.interface[*].interface' 2>/dev/null)
    for n in $names; do
        case "$n" in loopback|lo|ikev2out|'') continue ;; esac
        st=$(ubus call network.interface."$n" status 2>/dev/null) || continue
        addr=$(printf '%s' "$st" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
        mask=$(printf '%s' "$st" | jsonfilter -e '@["ipv4-address"][0].mask' 2>/dev/null)
        [ -n "$addr" ] && [ -n "$mask" ] || continue
        calc="$(ipcalc.sh "$addr/$mask" 2>/dev/null || true)"
        NETWORK="$(printf '%s\n' "$calc" | sed -n 's/^NETWORK=//p' | head -n1)"
        PREFIX="$(printf '%s\n' "$calc" | sed -n 's/^PREFIX=//p' | head -n1)"
        [ -n "$NETWORK" ] || continue
        printf '%s=%s/%s\n' "$n" "$NETWORK" "${PREFIX:-$mask}"
    done
}

# List firewall zones as name=network1 network2 lines. Keeping this beside the
# logical-network enumerator gives LuCI one authoritative source for pickers and
# avoids asking users to type UCI zone names.
cmd_zones() {
	local sections section name networks
	sections="$(uci show firewall 2>/dev/null \
		| sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p')"
	for section in $sections; do
		name="$(uci -q get "firewall.$section.name" 2>/dev/null || true)"
		[ -n "$name" ] || continue
		networks="$(uci -q get "firewall.$section.network" 2>/dev/null || true)"
		printf '%s=%s\n' "$name" "$networks"
	done
}

case "${1:-}" in
    dump)             cmd_dump ;;
	clients)          cmd_clients ;;
    networks)         cmd_networks ;;
	zones)            cmd_zones ;;
    add-subnet)       cmd_add_subnet "${2:-}" ;;
    remove-subnet)    cmd_remove_subnet "${2:-}" ;;
    add-override)     cmd_add_override "${2:-}" "${3:-}" ;;
	remove-override)  cmd_remove_override "${2:-}" ;;
	set-flag)         cmd_set_flag "${2:-}" "${3:-}" "${4:-}" ;;
	set-unmanaged)    cmd_set_unmanaged "${2:-}" ;;
	set-exclusions)   cmd_set_exclusions "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
	set-included)     cmd_set_included "${2:-}" ;;
	clear-policy)     cmd_clear_policy "${2:-}" ;;
    *)
		printf 'usage: %s {dump|clients|networks|zones|add-subnet <addr>|remove-subnet <addr>|add-override <addr> <mode>|remove-override <addr>|set-flag <addr> <dns_passthrough|dpi_passthrough> <0|1>|set-unmanaged <addr>|set-exclusions <addr> <pbr> <dns> <zapret>|set-included <addr>|clear-policy <addr>}\n' "$0" >&2
        exit 1 ;;
esac
