#!/bin/sh

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

config='ikev2-manager'
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
table="${IKEV2_DEVICE_TABLE:-ikev2_device_policy}"
signature_file="${IKEV2_DEVICE_SIGNATURE:-/var/run/ikev2-device-routing.signature}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
ucode_bin="${IKEV2_UCODE:-ucode}"

. "$runtime_lib_dir/devices.sh"
. "$runtime_lib_dir/nft-runtime.sh"

stop_runtime() {
	if runtime_exists; then
		runtime_owned || {
			printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
			return 1
		}
		"$nft_bin" delete table inet "$table" >/dev/null 2>&1 || return 1
	fi
	rm -f "$signature_file"
}

collect_sources() {
	full="$1"
	excluded="$2"
	dpi="$3"
	dns="$4"
	device_addresses fullroute >"$full" || return 1
	device_addresses exclude >"$excluded" || return 1
	device_flag_addresses dpi_passthrough >"$dpi" || return 1
	device_flag_addresses dns_passthrough >"$dns" || return 1
}

valid_ifname() {
	[ -n "${1:-}" ] && printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.:@-]+$'
}

normalized_address() {
	local value="$1" calculated network prefix
	case "$value" in
		*/*)
			calculated="$(ipcalc.sh "$value" 2>/dev/null)" || return 1
			network="$(printf '%s\n' "$calculated" | sed -n 's/^NETWORK=//p' | head -n1)"
			prefix="$(printf '%s\n' "$calculated" | sed -n 's/^PREFIX=//p' | head -n1)"
			[ -n "$network" ] && [ -n "$prefix" ] || return 1
			[ "$prefix" = 32 ] && printf '%s\n' "$network" ||
				printf '%s/%s\n' "$network" "$prefix"
			;;
		*) printf '%s\n' "$value" ;;
	esac
}

network_device() {
	local interface="$1" device
	device="$(ubus call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(ubus call "network.interface.$interface" status 2>/dev/null |
			jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(uci -q get "network.$interface.device" 2>/dev/null || true)"
	valid_ifname "$device" && printf '%s\n' "$device"
}

default_route_devices() {
	# The configured logical WAN can become stale after changing the physical
	# uplink in LuCI or the vendor UI.  DoT enforcement must follow every active
	# IPv4 default egress instead of silently retaining an obsolete interface.
	ip -4 route show table main default 2>/dev/null |
		awk '
			{
				for (i = 1; i <= NF; i++)
					if ($i == "dev" && (i + 1) <= NF) print $(i + 1)
			}
		' |
		while IFS= read -r device; do
			valid_ifname "$device" && printf '%s\n' "$device"
		done
}

collect_policy_ifaces() {
	local sources="$1" wan="$2" dns_enforce block_dot interface device
	: >"$sources"
	: >"$wan"
	dns_enforce="$(uci -q get "$config.globals.dns_enforce" 2>/dev/null || echo 0)"
	block_dot="$(uci -q get "$config.globals.block_dot" 2>/dev/null || echo 0)"
	[ "$dns_enforce" = 1 ] || [ "$block_dot" = 1 ] || return 0
	for interface in $(uci -q get "$config.globals.source_interface" 2>/dev/null || true); do
		device="$(network_device "$interface" || true)"
		[ -n "$device" ] || {
			printf "Protected network '%s' has no usable device\n" "$interface" >&2
			return 1
		}
		printf '%s\n' "$device" >>"$sources"
	done
	if [ "$(uci -q get "$config.globals.source_include_vpn" 2>/dev/null || echo 1)" = 1 ] &&
	   [ "$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)" = 1 ]; then
		printf '%s\n' 'ipsec-in' >>"$sources"
	fi
	sort -u "$sources" >"${sources}.sorted" || return 1
	mv "${sources}.sorted" "$sources" || return 1
	[ -s "$sources" ] || {
		printf '%s\n' 'DNS policy has no protected network devices' >&2
		return 1
	}
	[ "$block_dot" = 1 ] || return 0
	interface="$(uci -q get "$config.globals.wan_interface" 2>/dev/null || echo wan)"
	device="$(network_device "$interface" || true)"
	[ -z "$device" ] || printf '%s\n' "$device" >>"$wan"
	default_route_devices >>"$wan"
	if [ -s "$wan" ]; then
		sort -u "$wan" >"${wan}.sorted" || return 1
		mv "${wan}.sorted" "$wan" || return 1
		return 0
	fi
	# A WAN outage may remove both the logical runtime device and the active
	# default route. Preserve the last atomically installed set only in that
	# case. As soon as another default route appears, the health watcher replaces
	# stale interface names with the currently usable egress devices.
	if runtime_owned; then
		"$nft_bin" list set inet "$table" wan_ifaces 2>/dev/null |
			awk -F'"' '{ for (i = 2; i <= NF; i += 2) print $i }' |
			while IFS= read -r existing; do
				valid_ifname "$existing" && printf '%s\n' "$existing"
			done >"$wan"
		[ -s "$wan" ] && return 0
	fi
	[ -n "$device" ] || {
		printf "WAN network '%s' has no usable device\n" "$interface" >&2
		return 1
	}
}

valid_desync_mark() {
	local value
	value="$1"
	printf '%s\n' "$value" | grep -Eq '^0x[0-9A-Fa-f]{1,8}$' || return 1
	[ "$((value))" -ne 0 ]
}

zapret_desync_config() {
	value="$(uci -q get zapret2.main.desync_mark 2>/dev/null || true)"
	if [ "$(uci -q get zapret2.main.enabled 2>/dev/null || echo 0)" = 1 ] &&
	   valid_desync_mark "$value"; then
		printf 'zapret2 %s\n' "$(printf '%s' "$value" | tr 'A-F' 'a-f')"
		return 0
	fi
	value="$(uci -q get zapret.config.DESYNC_MARK 2>/dev/null || true)"
	valid_desync_mark "$value" || return 1
	printf 'zapret1 %s\n' "$(printf '%s' "$value" | tr 'A-F' 'a-f')"
}

write_set() {
	name="$1"
	file="$2"
	printf '  set %s {\n    type ipv4_addr\n    flags interval\n' "$name"
	if [ -s "$file" ]; then
		printf '    elements = { '
		set_elements "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

ifname_elements() {
	file="$1"
	[ -s "$file" ] || return 0
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "\"%s\"", $0; first=0 }' "$file"
}

write_ifname_set() {
	name="$1"
	file="$2"
	printf '  set %s {\n    type ifname\n' "$name"
	if [ -s "$file" ]; then
		printf '    elements = { '
		ifname_elements "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

write_dpi_rules() {
	file="$1"
	mark="$2"
	backend="$3"
	if [ "$backend" = zapret2 ]; then
		printf '    ct original ip saddr @dpi_bypass_ipv4 ct mark & %s != 0 meta mark set meta mark | %s counter comment "ikev2-device:dpi-restore"\n' \
			"$mark" "$mark"
	fi
	while IFS= read -r address; do
		[ -n "$address" ] || continue
		if [ "$backend" = zapret2 ]; then
			printf '    ip saddr %s ct mark set ct mark | %s meta mark set meta mark | %s counter comment "ikev2-device:dpi:%s"\n' \
				"$address" "$mark" "$mark" "$address"
		else
			printf '    ip saddr %s meta mark set meta mark | %s counter comment "ikev2-device:dpi:%s"\n' \
				"$address" "$mark" "$address"
		fi
	done <"$file"
}

write_route_rules() {
	file="$1"
	kind="$2"
	clear="$3"
	mark="$4"
	while IFS= read -r address; do
		[ -n "$address" ] || continue
		printf '    ip saddr %s meta mark set meta mark & %s | %s counter accept comment "ikev2-device:%s:%s"\n' \
			"$address" "$clear" "$mark" "$kind" "$address"
	done <"$file"
}

fakeip_policy_enabled() {
	[ "$(uci -q get "$config.domains.engine" 2>/dev/null || true)" = fakeip ]
}

write_fakeip_rules() {
	local kind mark port proto
	printf '  chain fakeip_policy {\n'
	for kind in exclude full_route; do
		case "$kind" in
			exclude) mark=0x00400001; port=1603 ;;
			# The existing router inbound always selects the tunnel, independent
			# of covered source subnets. Full-route devices need that same path.
			full_route) mark=0x00400002; port=1604 ;;
		esac
		for proto in tcp udp; do
			printf '    iifname @source_ifaces ip saddr @%s_ipv4 ip daddr 198.18.0.0/15 meta l4proto %s meta mark set %s tproxy ip to 127.0.0.1:%s counter accept\n' \
				"$kind" "$proto" "$mark" "$port"
		done
	done
	printf '  }\n\n'
}

# Everything the configuration asks for, collected into WORK, with its
# signature. Sets ike_clear ike_mark wan_clear wan_mark dpi_mark dpi_backend
# dns_enforce block_dot signature.
desired_state() {
	local work="$1" dpi_config
	ike_values="$(mark_values "$(routing_mark_rule tunnel)")" || {
		printf '%s\n' 'Unable to derive the tunnel routing mark' >&2
		return 1
	}
	wan_values="$(mark_values "$(routing_mark_rule wan)")" || {
		printf '%s\n' 'Unable to derive the WAN routing mark' >&2
		return 1
	}
	ike_clear="${ike_values%% *}"
	ike_mark="${ike_values#* }"
	wan_clear="${wan_values%% *}"
	wan_mark="${wan_values#* }"
	collect_sources "$work/full" "$work/excluded" "$work/dpi" "$work/dns" || return 1
	collect_policy_ifaces "$work/sources" "$work/wan" || return 1
	dns_enforce="$(uci -q get "$config.globals.dns_enforce" 2>/dev/null || echo 0)"
	block_dot="$(uci -q get "$config.globals.block_dot" 2>/dev/null || echo 0)"
	dpi_mark=''
	dpi_backend=''
	if [ -s "$work/dpi" ]; then
		dpi_config="$(zapret_desync_config)" || {
			printf '%s\n' 'DPI passthrough requires an enabled Zapret2 mark or a valid Zapret1 mark' >&2
			return 1
		}
		dpi_backend="${dpi_config%% *}"
		dpi_mark="${dpi_config#* }"
	fi
	signature="$({
		printf 'fakeip=%s\n' "$(fakeip_policy_enabled && echo 1 || echo 0)"
		printf 'ike=%s/%s\nwan=%s/%s\nfull\n' "$ike_clear" "$ike_mark" "$wan_clear" "$wan_mark"
		cat "$work/full"
		printf 'excluded\n'
		cat "$work/excluded"
		printf 'dpi=%s/%s\n' "$dpi_backend" "$dpi_mark"
		cat "$work/dpi"
		printf 'dns=%s\n' "$dns_enforce"
		cat "$work/dns"
		printf 'dot=%s\nsources\n' "$block_dot"
		cat "$work/sources"
		printf 'wan\n'
		cat "$work/wan"
	} | sha256sum | awk '{ print $1 }')"
}

sync_runtime() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ] || {
		stop_runtime
		return $?
	}
	work="${TMPDIR:-/tmp}/ikev2-device-routing.$$"
	mkdir -p "$work" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	desired_state "$work" || return 1
	full="$work/full"
	excluded="$work/excluded"
	dpi="$work/dpi"
	dns="$work/dns"
	sources="$work/sources"
	wan="$work/wan"
	if runtime_owned && [ "$(sed -n '1p' "$signature_file" 2>/dev/null)" = "$signature" ] &&
	   runtime_unchanged "$signature_file"; then
		rm -rf "$work"
		trap - EXIT INT TERM
		return 0
	fi
	if runtime_exists && ! runtime_owned; then
		printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
		return 1
	fi

	rules="$work/rules.nft"
	{
		runtime_exists && printf 'delete table inet %s\n' "$table"
		printf 'table inet %s {\n' "$table"
		cat <<'EOF'
  chain ikev2_manager_owned {
    comment "IKEv2 Manager device routing"
  }

EOF
		write_set full_route_ipv4 "$full"
		write_set exclude_ipv4 "$excluded"
		write_set dpi_bypass_ipv4 "$dpi"
		write_set dns_bypass_ipv4 "$dns"
		write_ifname_set source_ifaces "$sources"
		write_ifname_set wan_ifaces "$wan"
		fakeip_policy_enabled && write_fakeip_rules
		cat <<EOF
  chain prerouting {
    type filter hook prerouting priority -152; policy accept;
EOF
		[ -s "$dpi" ] && write_dpi_rules "$dpi" "$dpi_mark" "$dpi_backend"
		# Preserve admission decisions made by the earlier inbound-user chain.
		printf '    meta mark & 0x00ff0000 == 0x00400000 return\n'
		fakeip_policy_enabled && printf '    jump fakeip_policy\n'
		write_route_rules "$excluded" exclude "$wan_clear" "$wan_mark"
		write_route_rules "$full" fullroute "$ike_clear" "$ike_mark"
		printf '  }\n\n'
		if [ "$dns_enforce" = 1 ]; then
			cat <<'EOF'
  set dns_malformed_ipv4 {
    type ipv4_addr
    flags dynamic,timeout
    timeout 1h
    size 256
    counter
  }

  chain dns_guard {
    type filter hook prerouting priority -103; policy accept;
    iifname @source_ifaces ip saddr != @dns_bypass_ipv4 udp dport 53 udp length < 20 update @dns_malformed_ipv4 { ip saddr timeout 1h } comment "ikev2-device:dns-malformed-source"
    iifname @source_ifaces ip saddr != @dns_bypass_ipv4 udp dport 53 udp length < 20 counter drop comment "ikev2-device:dns-malformed"
  }

  chain dns_prerouting {
    type nat hook prerouting priority -102; policy accept;
    iifname @source_ifaces ip saddr != @dns_bypass_ipv4 meta l4proto { tcp, udp } th dport 53 counter redirect to :53 comment "ikev2-device:dns-enforce"
  }

EOF
		fi
		if [ "$block_dot" = 1 ]; then
			cat <<'EOF'
  chain dot_forward {
    type filter hook forward priority -2; policy accept;
    iifname @source_ifaces oifname @wan_ifaces ip saddr != @dns_bypass_ipv4 meta l4proto { tcp, udp } th dport 853 counter reject comment "ikev2-device:dot-block"
  }

EOF
		fi
		cat <<'EOF'
}
EOF
	} >"$rules"
	"$nft_bin" -c -f "$rules" >"$work/nft-check.log" 2>&1 || {
		printf '%s\n' 'Device-routing nftables validation failed' >&2
		cat "$work/nft-check.log" >&2
		return 1
	}
	"$nft_bin" -f "$rules" >/dev/null 2>&1 || {
		printf '%s\n' 'Unable to install device-routing nftables rules' >&2
		return 1
	}
	# What the kernel now holds is what later checks compare against, in its
	# own rendering of the rules.
	record_runtime "$signature_file" "$signature" || {
		printf '%s\n' 'Unable to read back the installed device-routing rules' >&2
		return 1
	}
	rm -rf "$work"
	trap - EXIT INT TERM
}

check_runtime() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ] || {
		! runtime_exists
		return
	}
	runtime_owned || return 1
	work="${TMPDIR:-/tmp}/ikev2-device-check.$$"
	mkdir -p "$work" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	# Current when the configuration asks for what was installed last and the
	# kernel still holds it.
	desired_state "$work" 2>/dev/null &&
		[ "$(sed -n '1p' "$signature_file" 2>/dev/null)" = "$signature" ] &&
		runtime_unchanged "$signature_file"
	status=$?
	rm -rf "$work"
	trap - EXIT INT TERM
	return "$status"
}

stats_runtime() {
	runtime_owned || return 0
	"$nft_bin" list chain inet "$table" prerouting 2>/dev/null |
	while IFS= read -r line; do
		case "$line" in
			*'comment "ikev2-device:'*) ;;
			*) continue ;;
		esac
		identifier="$(printf '%s\n' "$line" |
			sed -n 's/.*comment "ikev2-device:\([^"]*\)".*/\1/p')"
		packets="$(printf '%s\n' "$line" |
			sed -n 's/.*counter packets \([0-9][0-9]*\) bytes.*/\1/p')"
		bytes="$(printf '%s\n' "$line" |
			sed -n 's/.*counter packets [0-9][0-9]* bytes \([0-9][0-9]*\).*/\1/p')"
		kind="${identifier%%:*}"
		address="${identifier#*:}"
		[ -n "$kind" ] && [ "$address" != "$identifier" ] || continue
		printf 'addr=%s kind=%s packets=%s bytes=%s\n' \
			"$address" "$kind" "${packets:-0}" "${bytes:-0}"
	done
}

dns_malformed_stats() {
	runtime_owned || {
		printf 'state=inactive\n'
		return 0
	}
	if ! "$nft_bin" list set inet "$table" dns_malformed_ipv4 >/dev/null 2>&1; then
		printf 'state=disabled\n'
		return 0
	fi
	line="$("$nft_bin" list chain inet "$table" dns_guard 2>/dev/null |
		sed -n '/comment "ikev2-device:dns-malformed"/p' | head -n1)"
	packets="$(printf '%s\n' "$line" |
		sed -n 's/.*counter packets \([0-9][0-9]*\) bytes.*/\1/p')"
	bytes="$(printf '%s\n' "$line" |
		sed -n 's/.*counter packets [0-9][0-9]* bytes \([0-9][0-9]*\).*/\1/p')"
	printf 'state=active\npackets=%s\nbytes=%s\n' \
		"${packets:-0}" "${bytes:-0}"
	"$nft_bin" list set inet "$table" dns_malformed_ipv4 2>/dev/null |
		sed -n '/elements = {/,/}/p' |
		sed -e 's/.*elements = {//' -e 's/}.*//' |
		tr ',' '\n' |
	while IFS= read -r entry; do
		address="$(printf '%s\n' "$entry" |
			sed -n 's/^[[:space:]]*\([0-9][0-9.]*\).*/\1/p')"
		[ -n "$address" ] || continue
		source_packets="$(printf '%s\n' "$entry" |
			sed -n 's/.*counter packets \([0-9][0-9]*\) bytes.*/\1/p')"
		source_bytes="$(printf '%s\n' "$entry" |
			sed -n 's/.*counter packets [0-9][0-9]* bytes \([0-9][0-9]*\).*/\1/p')"
		printf 'source=%s packets=%s bytes=%s\n' "$address" \
			"${source_packets:-0}" "${source_bytes:-0}"
	done
}

case "${1:-sync}" in
	sync) sync_runtime ;;
	stop) stop_runtime ;;
	check) check_runtime ;;
	stats) stats_runtime ;;
	dns-malformed-stats) dns_malformed_stats ;;
	*) printf 'usage: %s [sync|stop|check|stats|dns-malformed-stats]\n' "$0" >&2; exit 2 ;;
esac
