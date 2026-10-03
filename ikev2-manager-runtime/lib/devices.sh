#!/bin/sh
# Device policy model shared by the routing helpers and the LuCI backend.
#
# Per-device settings live in named `device_policy` sections of the application
# config. The independent ikev2_device_policy nftables table is authoritative;
# old PBR policies are imported once and then removed as derived legacy state.
#
# Section layout:
#   config device_policy 'device_192_168_2_4'
#       option address    '192.168.2.4'
#       option route_mode 'domain' | 'fullroute' | 'exclude'

device_config="${IKEV2_DEVICE_CONFIG:-ikev2-manager}"
device_schema_version='2'

# Legacy policy names this schema replaces. Kept only for migration and cleanup.
device_legacy_fullroute_prefix='VPN Full Route: '
device_legacy_exclude_prefix='VPN Exclude: '

device_valid_ifname() {
	[ -n "${1:-}" ] && printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.:@-]+$'
}

# The device of a logical network: its layer-3 device while it is up,
# otherwise the one it is configured with.
device_network_device() {
	local interface="$1" status device
	status="$(ubus call "network.interface.$interface" status 2>/dev/null || true)"
	device="$(printf '%s' "$status" | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] || device="$(printf '%s' "$status" | jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] || device="$(uci -q get "network.$interface.device" 2>/dev/null || true)"
	device_valid_ifname "$device" && printf '%s\n' "$device"
}

# The devices whose traffic follows the destination lists, one per line:
# every protected network and, while the server is on and included, the
# inbound link. Policy routing and Discord voice both route these.
device_source_devices() {
	local interface device
	for interface in $(uci -q get "$device_config.globals.source_interface" 2>/dev/null || true); do
		device="$(device_network_device "$interface")" || {
			printf "Protected network '%s' has no usable device\n" "$interface" >&2
			return 1
		}
		printf '%s\n' "$device"
	done
	if [ "$(uci -q get "$device_config.server.enabled" 2>/dev/null || echo 0)" = 1 ] &&
	   [ "$(uci -q get "$device_config.globals.source_include_vpn" 2>/dev/null || echo 1)" = 1 ]; then
		printf 'ipsec-in\n'
	fi
}

device_sanitize() { printf '%s' "$1" | tr './:-' '____'; }
device_section() { printf 'device_%s' "$(device_sanitize "$1")"; }

device_valid_address() {
	[ -n "${1:-}" ] || return 1
	printf '%s' "$1" | grep -Eq '^[0-9.]+(/[0-9]{1,2})?$' || return 1
	case "$1" in
		*/*) ipcalc.sh "$1" >/dev/null 2>&1 ;;
		*) ipcalc.sh "$1/32" >/dev/null 2>&1 ;;
	esac
}

# `none` carries no routing policy of its own: it exists so a device can hold
# the opt-out flags below without also becoming a domain-routing source.
device_valid_mode() {
	case "${1:-}" in
		none | domain | fullroute | exclude) return 0 ;;
	esac
	return 1
}

# Per-device opt-outs. Each is stored as a boolean option on the section.
# respect_exclusions belongs to a full-route device: what is never to go
# through the tunnel goes to WAN for it too.
device_valid_flag() {
	case "${1:-}" in
		dns_passthrough | dpi_passthrough | respect_exclusions) return 0 ;;
	esac
	return 1
}

device_flag_enabled() {
	local address="$1" flag="$2" section
	device_valid_flag "$flag" || return 1
	section="$(device_section "$address")"
	[ "$(uci -q get "${device_config}.${section}.${flag}" 2>/dev/null || echo 0)" = 1 ]
}

# Addresses that opted out of one mechanism. Materialised rather than piped so
# a rejected entry cannot degrade into an empty, silently permissive list.
device_flag_addresses() {
	local flag="$1" section address value work result=0
	device_valid_flag "$flag" || return 1
	work="$(mktemp)" || return 1
	for section in $(device_sections); do
		value="$(uci -q get "${device_config}.${section}.${flag}" 2>/dev/null || echo 0)"
		[ "$value" = 1 ] || continue
		address="$(uci -q get "${device_config}.${section}.address" 2>/dev/null || true)"
		if ! device_valid_address "$address"; then
			printf "Device policy '%s' has an invalid address '%s'\n" \
				"$section" "$address" >&2
			result=1
			break
		fi
		printf '%s\n' "$address" >>"$work"
	done
	[ "$result" != 0 ] || sort -u "$work"
	rm -f "$work"
	[ "$result" = 0 ]
}

# Setting a flag on an unknown device creates it without a routing policy, so
# the opt-out never changes where that device's traffic goes.
device_set_flag() {
	local address="$1" flag="$2" value="$3" section
	device_valid_address "$address" || return 1
	device_valid_flag "$flag" || return 1
	case "$value" in 0 | 1) ;; *) return 1 ;; esac
	section="$(device_section "$address")"
	if [ -z "$(uci -q get "${device_config}.${section}.route_mode" 2>/dev/null || true)" ]; then
		device_set "$address" none || return 1
	fi
	if [ "$value" = 1 ]; then
		uci set "${device_config}.${section}.${flag}=1" || return 1
	else
		uci -q delete "${device_config}.${section}.${flag}" 2>/dev/null || true
		device_prune "$address"
	fi
}

# A device that carries neither a routing policy nor any flag is not a setting
# any more; keeping the empty section would leave stale entries in the UI.
device_prune() {
	local address="$1" section flag
	section="$(device_section "$address")"
	[ "$(uci -q get "${device_config}.${section}.route_mode" 2>/dev/null || true)" = none ] ||
		return 0
	for flag in dns_passthrough dpi_passthrough respect_exclusions; do
		[ "$(uci -q get "${device_config}.${section}.${flag}" 2>/dev/null || echo 0)" != 1 ] ||
			return 0
	done
	uci -q delete "${device_config}.${section}" 2>/dev/null || true
}

device_sections() {
	uci show "$device_config" 2>/dev/null |
		sed -n "s/^${device_config}\.\([^.=]*\)=device_policy\$/\1/p"
}

device_schema_ready() {
	[ "$(uci -q get "${device_config}.globals.device_schema" 2>/dev/null || echo 0)" \
		= "$device_schema_version" ]
}

# Emit "<address> <mode>" for every configured device. Before the one-time
# migration has run the legacy artefacts are read instead, so an upgraded
# package keeps behaving identically until the next apply.
device_list() {
	if device_schema_ready; then
		device_list_config
	else
		device_list_legacy
	fi
}

# A malformed entry is an error rather than something to skip: silently
# dropping one would move an excluded device back into the tunnel without any
# sign, which is exactly the failure this model exists to prevent.
device_list_config() {
	local section address mode
	for section in $(device_sections); do
		address="$(uci -q get "${device_config}.${section}.address" 2>/dev/null || true)"
		mode="$(uci -q get "${device_config}.${section}.route_mode" 2>/dev/null || true)"
		if ! device_valid_address "$address"; then
			printf "Device policy '%s' has an invalid address '%s'\n" \
				"$section" "$address" >&2
			return 1
		fi
		if ! device_valid_mode "$mode"; then
			printf "Device policy '%s' has an invalid routing mode '%s'\n" \
				"$section" "$mode" >&2
			return 1
		fi
		printf '%s %s\n' "$address" "$mode"
	done
}

device_list_legacy() {
	local address section name mode
	for address in $(uci -q get "${device_config}.domains.device_source" 2>/dev/null || true); do
		case "$address" in @*) continue ;; esac
		if ! device_valid_address "$address"; then
			printf "Saved device source '%s' is not a valid address\n" "$address" >&2
			return 1
		fi
		printf '%s domain\n' "$address"
	done
	for section in $(uci show pbr 2>/dev/null |
		sed -n 's/^pbr\.\([^.=]*\)=policy$/\1/p'); do
		name="$(uci -q get "pbr.${section}.name" 2>/dev/null || true)"
		case "$name" in
			"${device_legacy_fullroute_prefix}"*) mode='fullroute' ;;
			"${device_legacy_exclude_prefix}"*) mode='exclude' ;;
			*) continue ;;
		esac
		[ "$(uci -q get "pbr.${section}.enabled" 2>/dev/null || echo 1)" = 1 ] || continue
		for address in $(uci -q get "pbr.${section}.src_addr" 2>/dev/null || true); do
			case "$address" in @*) continue ;; esac
			if ! device_valid_address "$address"; then
				printf "Routing policy '%s' has an invalid source '%s'\n" \
					"$section" "$address" >&2
				return 1
			fi
			printf '%s %s\n' "$address" "$mode"
		done
	done
}

# Addresses in one mode, sorted and de-duplicated so callers can compare and
# hash the result without caring about section order. The listing is
# materialised because a pipeline would discard its exit status and turn a
# rejected configuration into an empty, silently permissive result.
device_addresses() {
	local mode="$1" work result=0
	work="$(mktemp)" || return 1
	device_list >"$work" || result=1
	[ "$result" != 0 ] ||
		awk -v mode="$mode" '$2 == mode { print $1 }' "$work" | sort -u
	rm -f "$work"
	[ "$result" = 0 ]
}

# The exits other than the first: each tunnel's, and with "s" the one that
# never moves to another tunnel (tunnel.sh).
device_other_exits='2s 2 3s 3 4s 4 5s 5 6s 6 7s 7 1s'

# The number of the routing mark of exit $1, and the TProxy port of the
# devices sent whole through it.
device_exit_mark() {
	case "$1" in
		1) echo 1 ;;
		*s) echo $((${1%s} + 8)) ;;
		*) echo $(($1 + 1)) ;;
	esac
}

device_exit_port() {
	case "$1" in
		*s) echo $((1620 + ${1%s})) ;;
		*) echo $((1610 + $1)) ;;
	esac
}

# A stored exit as it applies now: the first when it is not one or its tunnel
# is not configured, and with one tunnel there is nothing to be bound against.
device_exit_resolve() {
	local exit="$1" index
	case "$exit" in [1-7] | [1-7]s) ;; *) echo 1; return 0 ;; esac
	index="${exit%s}"
	if [ "$index" != 1 ] && ! uci -q get "${device_config}.tunnel_$index" >/dev/null 2>&1; then
		echo 1
		return 0
	fi
	case "$exit" in
		*s)
			uci -q show "$device_config" 2>/dev/null |
				grep -q "^${device_config}\.tunnel_[2-7]=tunnel\$" || exit="$index"
			;;
	esac
	echo "$exit"
}

# The exit of a device sent whole through a tunnel.
device_exit() {
	local address="$1" section
	section="$(device_section "$address")"
	device_exit_resolve "$(uci -q get "${device_config}.${section}.exit" 2>/dev/null || true)"
}

# Full-route devices as "address exit" lines.
device_fullroute_exits() {
	local list address
	list="$(device_addresses fullroute)" || return 1
	for address in $list; do
		printf '%s %s\n' "$address" "$(device_exit "$address")"
	done
}

# Send a device's full route through exit EXIT; 1, the first tunnel, is the
# default and stores nothing.
device_set_exit() {
	local address="$1" exit="$2" section
	device_valid_address "$address" || return 1
	case "$exit" in [1-7] | [1-7]s) ;; *) return 1 ;; esac
	section="$(device_section "$address")"
	[ -n "$(uci -q get "${device_config}.${section}.route_mode" 2>/dev/null || true)" ] || return 1
	if [ "$exit" = 1 ]; then
		uci -q delete "${device_config}.${section}.exit" 2>/dev/null || true
	else
		uci set "${device_config}.${section}.exit=$exit" || return 1
	fi
}

device_mode() {
	local address="$1" work result=0
	work="$(mktemp)" || return 1
	device_list >"$work" || result=1
	[ "$result" != 0 ] ||
		awk -v addr="$address" '$1 == addr { print $2; exit }' "$work"
	rm -f "$work"
	[ "$result" = 0 ]
}

# Legacy section names are retained for cleanup and old-state diagnostics.
device_pbr_fullroute_section() { printf 'pbr_dev_fr_%s' "$(device_sanitize "$1")"; }
device_pbr_exclude_section() { printf 'pbr_dev_ex_%s' "$(device_sanitize "$1")"; }
device_pbr_legacy_removed=0

# Drop every rendered policy, including ones whose cosmetic name was edited
# through the PBR package's own interface. Matching on the section prefix keeps
# those reachable; the name is no longer authoritative for anything.
device_pbr_clear() {
	local section name
	for section in $(uci show pbr 2>/dev/null |
		sed -n 's/^pbr\.\([^.=]*\)=policy$/\1/p'); do
		case "$section" in
			pbr_dev_fr_* | pbr_dev_ex_*)
				if uci -q delete "pbr.${section}" 2>/dev/null; then
					device_pbr_legacy_removed=1
				fi
				continue
				;;
		esac
		name="$(uci -q get "pbr.${section}.name" 2>/dev/null || true)"
		case "$name" in
			"${device_legacy_fullroute_prefix}"* | "${device_legacy_exclude_prefix}"*)
				if uci -q delete "pbr.${section}" 2>/dev/null; then
					device_pbr_legacy_removed=1
				fi
				;;
		esac
	done
}

# Routing overrides are enforced atomically by ikev2-device-routing before PBR.
# Clear the obsolete duplicate policies instead of making every device edit
# enlarge the next global PBR rebuild.
device_pbr_render() {
	device_pbr_clear
}

# 0-based position of the base policy among all named sections in pbr.
device_pbr_base_position() {
	uci show pbr 2>/dev/null |
		grep -E '^pbr\.[^.=]+=[a-z_]+$' |
		sed 's/^pbr\.\([^=]*\)=.*/\1/' |
		awk -v t="$1" '{ if ($0 == t) { print NR-1; exit } }'
}

device_set() {
	local address="$1" mode="$2" section
	device_valid_address "$address" || return 1
	device_valid_mode "$mode" || return 1
	section="$(device_section "$address")"
	uci set "${device_config}.${section}=device_policy" || return 1
	uci set "${device_config}.${section}.address=$address" || return 1
	uci set "${device_config}.${section}.route_mode=$mode" || return 1
}

# Drops the routing policy only. The opt-out flags are independent settings, so
# a device that still carries one keeps its section and simply stops being
# routed differently.
device_remove() {
	local address="$1" section
	device_valid_address "$address" || return 1
	section="$(device_section "$address")"
	[ -n "$(uci -q get "${device_config}.${section}" 2>/dev/null || true)" ] || return 0
	uci set "${device_config}.${section}.route_mode=none" || return 1
	device_prune "$address"
}

# Import the legacy representation once. Idempotent: the schema marker is only
# written after every entry has been stored, so an interrupted run repeats.
# The listing is materialised first because a `| while` loop would run the
# writes in a subshell, leaving the outcome dependent on how UCI stages them.
device_migrate() {
	local work address mode result=0
	device_schema_ready && return 0
	work="$(mktemp)" || return 1
	device_list_legacy >"$work" || result=1
	if [ "$result" = 0 ]; then
		while read -r address mode; do
			[ -n "$address" ] || continue
			device_set "$address" "$mode" || { result=1; break; }
		done <"$work"
	fi
	rm -f "$work"
	[ "$result" = 0 ] || return 1
	uci set "${device_config}.globals.device_schema=$device_schema_version" || return 1
}
