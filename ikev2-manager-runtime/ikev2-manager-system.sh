#!/bin/sh
# IKEv2 Manager for OpenWrt compatibility and runtime controller.

set -eu

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

uci_config_dir="${IKEV2_UCI_CONFIG_DIR:-/etc/config}"
uci_binary="${IKEV2_UCI_BIN:-/sbin/uci}"

uci() {
	"$uci_binary" -c "$uci_config_dir" "$@"
}

config='ikev2-manager'
dns_input_file="${IKEV2_DNS_INPUT:-}"
user_policy_helper="${IKEV2_USER_POLICY_HELPER:-/usr/libexec/ikev2-user-policy}"
user_policy_init="${IKEV2_USER_POLICY_INIT:-/etc/init.d/ikev2-user-policy}"
domain_router_helper="${IKEV2_DOMAIN_ROUTER_HELPER:-/usr/libexec/ikev2-domain-router}"
device_runtime_helper="${IKEV2_DEVICE_RUNTIME_HELPER:-/usr/libexec/ikev2-device-routing}"
routing_runtime_helper="${IKEV2_ROUTING_RUNTIME_HELPER:-/usr/libexec/ikev2-routing}"
xfrm_init="${IKEV2_XFRM_INIT:-/etc/init.d/ikev2-xfrm}"
nft_binary="${IKEV2_NFT:-/usr/sbin/nft}"
dns_segments_status_file="${IKEV2_DNS_SEGMENTS_STATUS:-/var/run/ikev2-dns-segments.status}"
doctor_ui_cache_file="${IKEV2_DOCTOR_UI_CACHE:-/var/run/ikev2-manager-doctor-ui.cache}"
doctor_ui_refresh_lock="${IKEV2_DOCTOR_UI_REFRESH_LOCK:-/var/run/ikev2-manager-doctor-ui.refresh.lock}"
ubus_binary="${IKEV2_UBUS_BIN:-ubus}"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

input_file_for() {
	token="$1"
	case "$token" in
		'' | *[!A-Za-z0-9-]* ) die 'Invalid input token' ;;
	esac
	[ "${#token}" -ge 8 ] && [ "${#token}" -le 64 ] || die 'Invalid input token'
	printf '/tmp/ikev2-manager-dns-%s.in\n' "$token"
}

getv() {
	uci -q get "$config.$1.$2" 2>/dev/null || true
}

get_list() {
	uci -q get "$config.$1.$2" 2>/dev/null || true
}

list_without() {
	local candidates="$1" excluded="$2" item seen duplicate result=''
	for item in $candidates; do
		duplicate=0
		for seen in $excluded $result; do
			[ "$seen" != "$item" ] || { duplicate=1; break; }
		done
		[ "$duplicate" = 0 ] || continue
		result="${result:+$result }$item"
	done
	printf '%s\n' "$result"
}

defaultv() {
	value="$(getv "$1" "$2")"
	printf '%s\n' "${value:-$3}"
}

valid_name_list() {
	local value count item
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	count=0
	for item in $value; do
		count=$((count + 1))
		[ "$count" -le 32 ] || return 1
		valid_name "$item" || return 1
	done
}

set_list() {
	local section option value item
	section="$1"
	option="$2"
	value="$(normalize_list "$3")"
	uci -q delete "$config.$section.$option" || true
	for item in $value; do
		uci add_list "$config.$section.$option=$item"
	done
}

add_list_unique() {
	local package section option value current item
	package="$1"
	section="$2"
	option="$3"
	value="$4"
	current="$(uci -q get "$package.$section.$option" 2>/dev/null || true)"
	for item in $current; do
		[ "$item" = "$value" ] && return 0
	done
	uci add_list "$package.$section.$option=$value"
}

delete_prefixed_sections() {
	local package prefix section
	package="$1"
	prefix="$2"
	uci show "$package" 2>/dev/null |
		sed -n "s/^${package}\.\(${prefix}[A-Za-z0-9_]*\)=.*/\1/p" |
		sort -u |
		while IFS= read -r section; do
			[ -n "$section" ] && uci -q delete "$package.$section"
		done
}

delete_sections() {
	local package section
	package="$1"
	shift
	for section in "$@"; do
		uci -q delete "$package.$section" || true
	done
}

# fw4 can return success while dropping a section with invalid options. Treat
# that diagnostic as a failed validation so an apparently successful apply can
# never leave DNS enforcement or another managed rule absent.
firewall_check_strict() {
	local log="${TMPDIR:-/tmp}/ikev2-fw4-check.$$"
	if ! fw4 check >"$log" 2>&1; then
		cat "$log" >&2
		rm -f "$log"
		return 1
	fi
	if grep -Eq "must not be a list|skipped due to invalid options|Section .* skipped" "$log"; then
		cat "$log" >&2
		rm -f "$log"
		return 1
	fi
	rm -f "$log"
}

sync_device_runtime() {
	[ ! -x "$device_runtime_helper" ] || "$device_runtime_helper" sync
}

# Package upgrades must repair the DNS policy without restarting PBR, WAN,
# strongSwan or the fw4 table. Managed DNS changes are applied through the same
# validated transaction as LuCI: resolver processes may restart briefly, while
# failure restores their previous configuration and process state. Install the
# owned nftables table before retiring old generated UCI sections.
reconcile_upgrade_runtime() {
	local changed=0 section dns_reconciled=0 runtime_schema=5
	[ "$(getv globals configured)" = 1 ] || return 0
	# The automatic switch to the other mode and its retries are gone; a
	# pending retry left by an older release means nothing now.
	if [ -n "$(getv domains fakeip_retry)" ]; then
		uci -q delete "$config.domains.fakeip_retry"
		uci commit "$config"
	fi
	rm -f /var/run/ikev2-fakeip-retry.state
	# A package release may contain only LuCI or documentation changes. Rebuild
	# active resolver/routing state only when the generated runtime contract was
	# explicitly advanced, not on every APK replacement.
	[ "$(defaultv globals runtime_schema 0)" != "$runtime_schema" ] || return 0
	# Runtime flags and per-segment process ownership live outside package files,
	# so merely replacing the init script is insufficient. Re-apply saved DNS to
	# disable duplicate optimistic caches, refresh segment fallback groups and
	# activate the current sing-box DNS rules immediately after an upgrade.
	if [ "$(defaultv dns managed 0)" = 1 ]; then
		apply_saved_dns || return 1
		dns_reconciled=1
	fi
	# The package replaces the renderer, not the already generated sing-box
	# configuration. Refresh an active Reliable-mode runtime transactionally so
	# a DNS-policy hotfix takes effect immediately after upgrade. The helper
	# validates the new configuration before cutover and restores the previous
	# generated files and process if the replacement fails.
	if [ "$dns_reconciled" = 0 ] && [ "$(getv domains engine)" = fakeip ] &&
	   [ -x "$domain_router_helper" ]; then
		"$domain_router_helper" refresh || return 1
	fi
	# A release that routed through PBR is moved off it here. PBR is not
	# rebuilt now: until the next Apply retires our policies there, both route
	# the same destinations, ours first, and the domain sets are copied from
	# PBR's. The device and inbound runtimes below then take the new marks.
	[ ! -x "$routing_runtime_helper" ] || "$routing_runtime_helper" sync || return 1
	sync_device_runtime || return 1
	sync_inbound_user_policy || return 1
	for section in $(uci show firewall 2>/dev/null |
		sed -n \
			-e 's/^firewall\.\(ikev2pbr_dns_[A-Za-z0-9_]*\)=.*/\1/p' \
			-e 's/^firewall\.\(ikev2pbr_dot_[A-Za-z0-9_]*\)=.*/\1/p' |
		sort -u); do
		uci -q delete "firewall.$section" || return 1
		changed=1
	done
	[ "$changed" = 0 ] || uci commit firewall
	uci set "$config.globals.runtime_schema=$runtime_schema" || return 1
	uci commit "$config"
}

sanitize() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
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
	[ -n "$device" ] && printf '%s\n' "$device"
}

gateway_network() {
	gateway="$(getv server gateway4)"
	[ -n "$gateway" ] || return 0
	ipcalc.sh "$gateway" 2>/dev/null |
		awk -F= '/^NETWORK=/{network=$2}/^PREFIX=/{prefix=$2}END{if(network!=""&&prefix!="")print network "/" prefix}'
}

zone_exists() {
	local zone
	zone="$1"
	uci show firewall 2>/dev/null |
		grep -Fq ".name='$zone'"
}

zone_name_count() {
	local wanted index count name
	wanted="$1"
	index=0
	count=0
	while uci -q get "firewall.@zone[$index]" >/dev/null 2>&1; do
		name="$(uci -q get "firewall.@zone[$index].name" 2>/dev/null || true)"
		[ "$name" != "$wanted" ] || count=$((count + 1))
		index=$((index + 1))
	done
	printf '%s\n' "$count"
}

managed_zone_name_available() {
	local name owner count owner_type owner_name
	name="$1"
	owner="$2"
	count="$(zone_name_count "$name")"
	owner_type="$(uci -q get "firewall.$owner" 2>/dev/null || true)"
	owner_name="$(uci -q get "firewall.$owner.name" 2>/dev/null || true)"
	if [ "$owner_type" = zone ] && [ "$owner_name" = "$name" ]; then
		[ "$count" -eq 1 ]
	else
		[ "$count" -eq 0 ]
	fi
}

validate_server_zone_names() {
	[ "$#" -eq 2 ] || die 'Expected inbound and outbound firewall zone names'
	inbound_zone="$1"
	outbound_zone="$2"
	valid_name "$inbound_zone" || die 'Invalid inbound firewall zone name'
	valid_name "$outbound_zone" || die 'Invalid outbound firewall zone name'
	[ "$inbound_zone" != "$outbound_zone" ] ||
		die 'Inbound and outbound firewall zones must be different'
	managed_zone_name_available "$inbound_zone" ikev2pbr_in ||
		die "Inbound firewall zone name '$inbound_zone' is already in use"
	managed_zone_name_available "$outbound_zone" ikev2pbr_out ||
		die "Outbound firewall zone name '$outbound_zone' is already in use"
}

port_range_contains() {
	local range port
	range="$1"
	port="$2"
	case "$range" in
		*-*) start="${range%%-*}"; end="${range#*-}" ;;
		*:*) start="${range%%:*}"; end="${range#*:}" ;;
		*) start="$range"; end="$range" ;;
	esac
	case "$start:$end:$port" in
		*[!0-9:]* | ::*) return 1 ;;
	esac
	[ "$port" -ge "$start" ] && [ "$port" -le "$end" ]
}

upnp_port_action() {
	wanted="$1"
	index=0
	while uci -q get "upnpd.@perm_rule[$index]" >/dev/null 2>&1; do
		action="$(uci -q get "upnpd.@perm_rule[$index].action" 2>/dev/null || echo deny)"
		ranges="$(uci -q get "upnpd.@perm_rule[$index].ext_ports" 2>/dev/null || true)"
		for range in $ranges; do
			if port_range_contains "$range" "$wanted"; then
				printf '%s\n' "$action"
				return 0
			fi
		done
		index=$((index + 1))
	done
	printf 'deny\n'
}

upnp_ikev2_check() {
	if [ "$(uci -q get upnpd.config.enabled 2>/dev/null || echo 0)" != 1 ]; then
		printf 'upnp_ikev2_ports=ok:not-enabled\n'
		return 0
	fi
	upnp_rules="$(nft list chain inet fw4 upnp_prerouting 2>/dev/null || true)"
	if printf '%s\n' "$upnp_rules" | grep 'udp dport' |
		grep -Eq '(^|[^0-9])(500|4500)([^0-9]|$)'; then
		printf 'upnp_ikev2_ports=conflict:active-UDP-500-or-4500-mapping\n'
		return 1
	fi
	available=''
	for port in 500 4500; do
		[ "$(upnp_port_action "$port")" != allow ] ||
			available="${available}${available:+,}$port"
	done
	if [ -n "$available" ]; then
		printf 'upnp_ikev2_ports=warn:UDP-%s-available-to-UPnP\n' "$available"
	else
		printf 'upnp_ikev2_ports=ok:UDP-500-and-4500-reserved\n'
	fi
}

compatibility_checks() {
	release_id='unknown'
	release='unknown'
	target='unknown'
	arch='unknown'
	if [ -r /etc/openwrt_release ]; then
		. /etc/openwrt_release
		release_id="${DISTRIB_ID:-unknown}"
		release="${DISTRIB_RELEASE:-unknown}"
		target="${DISTRIB_TARGET:-unknown}"
		arch="${DISTRIB_ARCH:-unknown}"
	fi

	board_json="$(ubus call system board 2>/dev/null || true)"
	board_model="$(printf '%s' "$board_json" | jsonfilter -e '@.model' 2>/dev/null || true)"
	board_name="$(printf '%s' "$board_json" | jsonfilter -e '@.board_name' 2>/dev/null || true)"
	printf 'board_model=ok:%s\n' "${board_model:-unknown}"
	printf 'board_name=ok:%s\n' "${board_name:-unknown}"
	printf 'target=ok:%s\n' "$target"
	printf 'architecture=ok:%s\n' "$arch"
	printf 'kernel=ok:%s\n' "$(uname -r 2>/dev/null || echo unknown)"

	if [ "$release_id" = OpenWrt ]; then
		printf 'firmware_source=ok:official\n'
	else
		printf 'firmware_source=unsupported:%s\n' "$release_id"
		ok=0
		dependencies_ok=0
	fi
	package_manager="$(pkg_manager_name)"
	release_support="$(openwrt_release_support "$release" "$package_manager")"
	case "$release_support" in
		supported) printf 'openwrt=ok:%s\n' "$release" ;;
		newer) printf 'openwrt=warn:%s-untested\n' "$release" ;;
		*)
			printf 'openwrt=unsupported:%s\n' "$release"
			ok=0
			dependencies_ok=0
			;;
	esac
	case "$package_manager:$release_support" in
		missing:*)
			printf 'package_manager=missing\n'
			ok=0
			dependencies_ok=0
			;;
		*:supported | *:newer)
			printf 'package_manager=ok:%s\n' "$package_manager"
			;;
		*)
			printf 'package_manager=unsupported:%s-for-%s\n' "$package_manager" "$release"
			ok=0
			dependencies_ok=0
			;;
	esac
	if pkg_release_feed_ok "$release"; then
		printf 'package_feeds=ok:official\n'
	else
		printf 'package_feeds=unsupported:non-release-or-vendor\n'
		ok=0
		dependencies_ok=0
	fi

	install_space_needed=0
	if ! pkg_dnsmasq_has_nftset 2>/dev/null; then
		install_space_needed=1
	else
		for package in $(runtime_packages); do
			pkg_installed "$package" || { install_space_needed=1; break; }
		done
	fi
	overlay_required=12288
	tmp_required=16384
	if [ "$install_space_needed" = 1 ]; then
		overlay_required=65536
		tmp_required=65536
	fi

	overlay_free="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')"
	[ -n "$overlay_free" ] ||
		overlay_free="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')"
	case "${overlay_free:-0}" in *[!0-9]*) overlay_free=0 ;; esac
	if [ "$overlay_free" -ge "$overlay_required" ]; then
		printf 'storage_free=ok:%sKiB\n' "$overlay_free"
	else
		printf 'storage_free=low:%sKiB-required-%sKiB\n' \
			"$overlay_free" "$overlay_required"
		ok=0
		dependencies_ok=0
	fi

	tmp_free="$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 { print $4 }')"
	case "${tmp_free:-0}" in *[!0-9]*) tmp_free=0 ;; esac
	if [ "$tmp_free" -ge "$tmp_required" ]; then
		printf 'tmp_free=ok:%sKiB\n' "$tmp_free"
	else
		printf 'tmp_free=low:%sKiB-required-%sKiB\n' \
			"$tmp_free" "$tmp_required"
		ok=0
		dependencies_ok=0
	fi

	mem_available="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	case "${mem_available:-0}" in *[!0-9]*) mem_available=0 ;; esac
	if [ "$mem_available" -ge 32768 ]; then
		printf 'memory_available=ok:%sKiB\n' "$mem_available"
	else
		printf 'memory_available=low:%sKiB\n' "$mem_available"
		ok=0
		dependencies_ok=0
	fi

	year="$(date +%Y 2>/dev/null || echo 0)"
	case "$year" in *[!0-9]*) year=0 ;; esac
	if [ "$year" -ge 2024 ]; then
		printf 'system_clock=ok:%s\n' "$(date -Iseconds 2>/dev/null || date)"
	else
		printf 'system_clock=invalid:%s\n' "$year"
		ok=0
		dependencies_ok=0
	fi

	if grep -Eq '^Features[[:space:]]*:.*(^|[[:space:]])aes([[:space:]]|$)' \
		/proc/cpuinfo 2>/dev/null ||
		lsmod 2>/dev/null | grep -q '^crypto_safexcel '; then
		printf 'crypto_acceleration=ok:detected\n'
	else
		printf 'crypto_acceleration=notice:not-detected\n'
	fi

	flow_sw="$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null || echo 0)"
	flow_hw="$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || echo 0)"
	if [ "$flow_hw" = 1 ]; then
		printf 'flow_offloading=notice:hardware-enabled\n'
	elif [ "$flow_sw" = 1 ]; then
		printf 'flow_offloading=notice:software-enabled\n'
	else
		printf 'flow_offloading=ok:disabled\n'
	fi

	resource_conflicts=''
	if [ "$(getv globals configured)" != 1 ]; then
		uci -q get network.ikev2out >/dev/null 2>&1 &&
			resource_conflicts="${resource_conflicts}network.ikev2out,"
		uci show firewall 2>/dev/null | grep -q '^firewall\.ikev2pbr_' &&
			resource_conflicts="${resource_conflicts}firewall.ikev2pbr_*,"
		uci show pbr 2>/dev/null | grep -q '^pbr\.ikev2pbr_' &&
			resource_conflicts="${resource_conflicts}pbr.ikev2pbr_*,"
	fi
	if [ -n "$resource_conflicts" ]; then
		printf 'resource_conflict=%s\n' "${resource_conflicts%,}"
		ok=0
	else
		printf 'resource_conflict=none\n'
	fi
}

preflight() {
	ok=1
	dependencies_ok=1
	compatibility_checks
	printf 'preflight_ok=%s\n' "$ok"
	[ "$ok" -eq 1 ]
}

sing_box_fakeip_safe() {
	pkg_version_at_least sing-box 1.13.19
}

validate_runtime_config() {
	wan_interface="$(getv globals wan_interface)"
	wan_zone="$(getv globals wan_zone)"
	source_interfaces="$(get_list globals source_interface)"
	[ -n "$source_interfaces" ] || die 'At least one protected network is required'
	uci -q get "network.$wan_interface" >/dev/null 2>&1 ||
		die "WAN network '$wan_interface' does not exist"
	zone_exists "$wan_zone" ||
		die "WAN firewall zone '$wan_zone' does not exist"
	validate_server_zone_names \
		"$(defaultv server firewall_zone ikev2in)" \
		"$(defaultv server outbound_zone ikev2out)"

	for interface in $source_interfaces; do
		[ "$interface" != "$wan_interface" ] ||
			die "WAN network '$wan_interface' cannot be a protected network"
		uci -q get "network.$interface" >/dev/null 2>&1 ||
			die "Protected network '$interface' does not exist"
		network_device "$interface" >/dev/null ||
			die "Protected network '$interface' has no device"
		[ "$(zone_for_network "$interface")" != "$wan_zone" ] ||
			die "Protected network '$interface' belongs to the WAN firewall zone '$wan_zone'"
	done
	for zone in $(get_list globals source_zone); do
		zone_exists "$zone" ||
			die "Firewall zone '$zone' does not exist"
	done
	if [ "$(getv server enabled)" = 1 ] && [ "$(defaultv server allow_lan 1)" = 1 ]; then
		for zone in $(get_list server lan_zone); do
			zone_exists "$zone" ||
				die "Inbound LAN firewall zone '$zone' does not exist"
		done
	fi
	if [ "$(defaultv domains engine nftset)" = fakeip ]; then
		sing_box_fakeip_safe ||
			die 'Reliable mode requires sing-box 1.13.19 or later'
	fi
}

deps_status_file='/tmp/ikev2-manager-deps.status'
default_app_config="${IKEV2_DEFAULT_APP_CONFIG:-/usr/share/ikev2-manager/defaults/ikev2-manager}"
routing_check_helper="${IKEV2_ROUTING_CHECK_HELPER:-/usr/libexec/ikev2-domains-restart}"
action_status_file="${IKEV2_SYSTEM_ACTION_STATUS:-/var/run/ikev2-system-action.status}"
action_status_dir="${IKEV2_SYSTEM_ACTION_STATUS_DIR:-/var/run/ikev2-system-actions}"
action_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/package-manager.sh"
. "$runtime_lib_dir/dependency-state.sh"
. "$runtime_lib_dir/routing.sh"
. "$runtime_lib_dir/devices.sh"
. "$runtime_lib_dir/tunnel.sh"
. "$runtime_lib_dir/validate.sh"
. "$runtime_lib_dir/system-deps.sh"
. "$runtime_lib_dir/system-dns.sh"
. "$runtime_lib_dir/system-doctor.sh"
. "$runtime_lib_dir/system-diagnostics.sh"
. "$runtime_lib_dir/system-backup.sh"

sync_network() {
	uci -q delete network.ikev2out || true
	uci set network.ikev2out=interface
	uci set network.ikev2out.proto='none'
	uci set network.ikev2out.device='ipsec-out'
	uci set network.ikev2out.auto='1'
	uci commit network
}

sync_firewall() {
	wan_zone="$(getv globals wan_zone)"
	server_enabled="$(getv server enabled)"
	[ "$server_enabled" = 1 ] || server_enabled=0
	inbound_zone="$(defaultv server firewall_zone ikev2in)"
	outbound_zone="$(defaultv server outbound_zone ikev2out)"
	source_zones="$(get_list globals source_zone)"
	validate_server_zone_names "$inbound_zone" "$outbound_zone"

	delete_prefixed_sections firewall ikev2pbr_

	uci set firewall.ikev2pbr_out=zone
	uci set "firewall.ikev2pbr_out.name=$outbound_zone"
	# Every outbound tunnel link is in the zone: the first always, the others
	# while their tunnel is enabled.
	uci add_list firewall.ikev2pbr_out.device='ipsec-out'
	for index in 2 3 4 5 6 7; do
		[ "$(getv "tunnel_$index" enabled)" = 1 ] || continue
		uci add_list "firewall.ikev2pbr_out.device=ipsec-out$index"
	done
	uci set firewall.ikev2pbr_out.input='REJECT'
	uci set firewall.ikev2pbr_out.output='ACCEPT'
	uci set firewall.ikev2pbr_out.forward='REJECT'
	uci set firewall.ikev2pbr_out.masq='1'
	uci set firewall.ikev2pbr_out.mtu_fix='1'

	uci set firewall.ikev2pbr_in=zone
	uci set "firewall.ikev2pbr_in.name=$inbound_zone"
	uci set firewall.ikev2pbr_in.device='ipsec-in'
	uci set firewall.ikev2pbr_in.input='REJECT'
	uci set firewall.ikev2pbr_in.output='ACCEPT'
	uci set firewall.ikev2pbr_in.forward='REJECT'
	uci set firewall.ikev2pbr_in.mtu_fix='1'

	for zone in $source_zones; do
		key="$(sanitize "$zone")"
		section="ikev2pbr_${key}_out"
		uci set "firewall.$section=forwarding"
		uci set "firewall.$section.src=$zone"
		uci set "firewall.$section.dest=$outbound_zone"

	done

	uci set firewall.ikev2pbr_server=rule
	uci set firewall.ikev2pbr_server.name='IKEv2 PBR inbound server'
	uci set "firewall.ikev2pbr_server.src=$wan_zone"
	uci set firewall.ikev2pbr_server.proto='udp'
	uci set firewall.ikev2pbr_server.dest_port='500 4500'
	uci set firewall.ikev2pbr_server.target='ACCEPT'
	uci set "firewall.ikev2pbr_server.enabled=$server_enabled"

	uci set firewall.ikev2pbr_server_esp=rule
	uci set firewall.ikev2pbr_server_esp.name='IKEv2 PBR inbound ESP'
	uci set "firewall.ikev2pbr_server_esp.src=$wan_zone"
	uci set firewall.ikev2pbr_server_esp.proto='esp'
	uci set firewall.ikev2pbr_server_esp.target='ACCEPT'
	uci set "firewall.ikev2pbr_server_esp.enabled=$server_enabled"

	uci set firewall.ikev2pbr_in_dns=rule
	uci set firewall.ikev2pbr_in_dns.name='IKEv2 PBR inbound DNS'
	uci set "firewall.ikev2pbr_in_dns.src=$inbound_zone"
	uci set firewall.ikev2pbr_in_dns.proto='tcp udp'
	uci set firewall.ikev2pbr_in_dns.dest_port='53'
	uci set firewall.ikev2pbr_in_dns.target='ACCEPT'
	uci set "firewall.ikev2pbr_in_dns.enabled=$server_enabled"

	sync_client_api_rule
	uci commit firewall
	sync_inbound_access
}

# The registration listener for managed desktop clients: reachable from WAN
# only while both the inbound server and client access are enabled.
sync_client_api_rule() {
	local port enabled=0
	port="$(defaultv client_access port 8443)"
	case "$port" in *[!0-9]* | '') port=8443 ;; esac
	[ "$(getv server enabled)" = 1 ] && [ "$(getv client_access enabled)" = 1 ] && enabled=1
	wan_zone="$(getv globals wan_zone)"
	[ -n "$wan_zone" ] || wan_zone='wan'
	uci set firewall.ikev2pbr_client_api=rule
	uci set firewall.ikev2pbr_client_api.name='IKEv2 PBR client registration'
	uci set "firewall.ikev2pbr_client_api.src=$wan_zone"
	uci set firewall.ikev2pbr_client_api.proto='tcp'
	uci set "firewall.ikev2pbr_client_api.dest_port=$port"
	uci set firewall.ikev2pbr_client_api.target='ACCEPT'
	uci set "firewall.ikev2pbr_client_api.enabled=$enabled"
}

sync_inbound_access() {
	server_enabled="$(getv server enabled)"
	[ "$server_enabled" = 1 ] || server_enabled=0
	inbound_zone="$(defaultv server firewall_zone ikev2in)"
	outbound_zone="$(defaultv server outbound_zone ikev2out)"
	wan_zone="$(getv globals wan_zone)"
	[ -n "$wan_zone" ] || wan_zone='wan'
	allow_internet="$(defaultv server allow_internet 1)"
	allow_lan="$(defaultv server allow_lan 1)"
	allow_router="$(defaultv server allow_router 0)"
	router_ports="$(normalize_list "$(getv server router_ports)")"
	public_ports=''
	effective_internet="$allow_internet"
	effective_lan="$allow_lan"
	effective_router="$allow_router"
	for policy in $(uci show "$config" 2>/dev/null |
		sed -n "s/^${config}\.\([^.=]*\)=user_policy$/\1/p"); do
		[ -n "$(uci -q get "$config.$policy.username" 2>/dev/null || true)" ] || continue
		policy_public_ports="$(normalize_list \
			"$(uci -q get "$config.$policy.public_ports" 2>/dev/null || true)")"
		valid_port_list "$policy_public_ports" ||
			die "Invalid public router ports in VPN user policy '$policy'"
		for port in $policy_public_ports; do
			case " $public_ports " in
				*" $port "*) ;;
				*) public_ports="${public_ports:+$public_ports }$port" ;;
			esac
		done
		[ "$(uci -q get "$config.$policy.internet_access" 2>/dev/null || true)" = allow ] &&
			effective_internet=1
		case "$(uci -q get "$config.$policy.lan_access" 2>/dev/null || true)" in
			all | limited) effective_lan=1 ;;
		esac
		[ "$(uci -q get "$config.$policy.router_access" 2>/dev/null || true)" = allow ] &&
			effective_router=1
	done

	delete_prefixed_sections firewall ikev2access_
	if [ "$server_enabled" != 1 ]; then
		uci commit firewall
		return 0
	fi

	if [ "$effective_internet" = 1 ]; then
		uci set firewall.ikev2access_in_wan=forwarding
		uci set "firewall.ikev2access_in_wan.src=$inbound_zone"
		uci set "firewall.ikev2access_in_wan.dest=$wan_zone"

		if zone_exists "$outbound_zone"; then
			uci set firewall.ikev2access_in_out=forwarding
			uci set "firewall.ikev2access_in_out.src=$inbound_zone"
			uci set "firewall.ikev2access_in_out.dest=$outbound_zone"
		fi
	fi

	if [ "$effective_lan" = 1 ]; then
		for zone in $(get_list server lan_zone); do
			key="$(sanitize "$zone")"
			section="ikev2access_in_${key}"
			uci set "firewall.$section=forwarding"
			uci set "firewall.$section.src=$inbound_zone"
			uci set "firewall.$section.dest=$zone"
		done
	fi

	if [ "$effective_router" = 1 ]; then
		uci set firewall.ikev2access_router=rule
		uci set firewall.ikev2access_router.name='IKEv2 inbound access to router'
		uci set "firewall.ikev2access_router.src=$inbound_zone"
		uci set firewall.ikev2access_router.target='ACCEPT'
		if [ -n "$router_ports" ]; then
			uci set firewall.ikev2access_router.proto='tcp udp'
			uci set "firewall.ikev2access_router.dest_port=$router_ports"
		else
			uci set firewall.ikev2access_router.proto='all'
		fi
	fi

	if [ -n "$public_ports" ]; then
		uci set firewall.ikev2access_public=rule
		uci set firewall.ikev2access_public.name='IKEv2 inbound selected router services'
		uci set "firewall.ikev2access_public.src=$inbound_zone"
		uci set firewall.ikev2access_public.proto='tcp udp'
		uci set "firewall.ikev2access_public.dest_port=$public_ports"
		uci set firewall.ikev2access_public.target='ACCEPT'
	fi

	uci commit firewall
}

sync_inbound_user_policy() {
	[ -x "$user_policy_helper" ] || return 0
	policy_active=0
	if [ "$(getv globals configured)" = 1 ] &&
	   [ "$(getv server enabled)" = 1 ] &&
	   [ "$(defaultv server custom_config 0)" != 1 ]; then
		policy_active=1
	fi
	if [ "$policy_active" != 1 ]; then
		if [ -x "$user_policy_init" ]; then
			if "$user_policy_init" running >/dev/null 2>&1; then
				"$user_policy_init" stop >/dev/null 2>&1 || return 1
			fi
			"$user_policy_init" disable >/dev/null 2>&1 || return 1
		fi
		"$user_policy_helper" stop >/dev/null 2>&1
		return $?
	fi
	if [ "$(defaultv domains engine nftset)" = fakeip ] &&
	   [ -x "$domain_router_helper" ]; then
		"$domain_router_helper" ensure >/dev/null 2>&1 || return 1
	fi
	# Install the fail-closed table before starting the event watcher. Starting
	# first would race its initial sync against this one on the same nft table.
	"$user_policy_helper" sync >/dev/null || return 1
	if [ -x "$user_policy_init" ]; then
		"$user_policy_init" enable >/dev/null 2>&1 || return 1
		"$user_policy_init" running >/dev/null 2>&1 ||
			"$user_policy_init" start >/dev/null 2>&1 || return 1
	fi
}


# Takes this application's policies, include and interface out of PBR and
# puts back the pbr.config options it changed on first use, as the operator
# had them.
release_pbr_config() {
	local v k
	[ -f "$uci_config_dir/pbr" ] || return 0
	uci -q delete pbr.ikev2pbr_domains || true
	uci -q delete pbr.ikev2pbr_service_cidrs || true
	uci -q delete pbr.ikev2pbr_include || true
	device_pbr_clear || return 1
	uci -q del_list pbr.config.supported_interface='ikev2out' || true
	if [ "$(uci -q get "$config.globals.pbr_saved" 2>/dev/null)" = 1 ]; then
		uci set pbr.config.enabled="$(uci -q get "$config.globals.pbr_prev_enabled" 2>/dev/null || echo 0)"
		uci set pbr.config.ipv6_enabled="$(uci -q get "$config.globals.pbr_prev_ipv6" 2>/dev/null || echo 0)"
		v="$(uci -q get "$config.globals.pbr_prev_resolver" 2>/dev/null || true)"
		[ -n "$v" ] && uci set pbr.config.resolver_set="$v" || uci -q delete pbr.config.resolver_set
		v="$(uci -q get "$config.globals.pbr_prev_strict" 2>/dev/null || true)"
		[ -n "$v" ] && uci set pbr.config.strict_enforcement="$v" || uci -q delete pbr.config.strict_enforcement
		for k in pbr_saved pbr_prev_enabled pbr_prev_ipv6 pbr_prev_resolver pbr_prev_strict; do
			uci -q delete "$config.globals.$k"
		done
		uci commit "$config" || return 1
	fi
	uci commit pbr
}

# Whether PBR still holds anything of this application's.
pbr_holds_ours() {
	[ -f "$uci_config_dir/pbr" ] || return 1
	uci -q get pbr.ikev2pbr_domains >/dev/null 2>&1 ||
		uci -q get pbr.ikev2pbr_service_cidrs >/dev/null 2>&1 ||
		uci -q get pbr.ikev2pbr_include >/dev/null 2>&1 ||
		[ "$(uci -q get "$config.globals.pbr_saved" 2>/dev/null)" = 1 ]
}

# With the application's own routing selected PBR keeps nothing of ours: the
# first Apply after the switch releases our configuration there and restarts
# PBR once to drop it. The operator's own policies stay.
retire_pbr_policies() {
	pbr_restart_needed=0
	pbr_holds_ours || return 0
	release_pbr_config || return 1
	rm -f /etc/ikev2-manager/pbr-set4.dump /etc/ikev2-manager/pbr-set6.dump \
		/var/run/pbr-ikev2-set4.dump /var/run/pbr-ikev2-set6.dump
	pbr_restart_needed=1
}

# PBR that this application's installer added and that nothing else uses is
# removed once routing no longer needs it. One the operator installed, or one
# with an enabled policy or a package depending on it, stays.
remove_unused_pbr() {
	local policies
	pkg_installed pbr || return 0
	deps_state_has owned-packages pbr || return 0
	policies="$(uci -q show pbr 2>/dev/null |
		sed -n "s/^pbr\.\([^.]*\)\.enabled='\{0,1\}1'\{0,1\}$/\1/p" | grep -v '^config$' || true)"
	[ -z "$policies" ] || return 0
	[ -z "$(pkg_required_by pbr)" ] || return 0
	/etc/init.d/pbr stop >/dev/null 2>&1 || :
	/etc/init.d/pbr disable >/dev/null 2>&1 || :
	if ! pkg_remove_runtime pbr >/dev/null 2>&1; then
		logger -t ikev2-manager 'PBR is no longer used but could not be removed' 2>/dev/null || true
		return 0
	fi
	deps_state_forget_owned pbr || :
	logger -t ikev2-manager 'removed PBR, which only this application used' 2>/dev/null || true
	# Stopping PBR deletes every "lookup main suppress_prefixlength" rule,
	# this application's included.
	"$routing_runtime_helper" sync >/dev/null 2>&1 ||
		logger -t ikev2-manager 'policy routing could not be restored after removing PBR' 2>/dev/null || true
}

# The application routes on its own (ikev2-routing). What a release that
# routed through PBR left there is released first: our policies, include and
# interface leave PBR, and pbr.config gets back the options it had; PBR is
# restarted once without them by pbr_restart_checked.
sync_pbr() {
	retire_pbr_policies || die 'Unable to release the PBR configuration'
	"$routing_runtime_helper" sync || die 'Policy routing failed to load'
}

backup_root="${IKEV2_BACKUP_ROOT:-/etc/ikev2-manager/backups}"
backup_labels='apply coverage-add coverage-remove disable disable-managed enable-managed server-runtime'

# A transaction removes its own backup when it ends. One that was killed first
# left a full copy of network, dhcp and firewall - with whatever credentials they
# hold - on flash for good. Remove those after a week; a backup under any other
# name was made by hand and is not this application's to delete.
prune_stale_backups() {
	local label
	[ -d "$backup_root" ] || return 0
	for label in $backup_labels; do
		find "$backup_root" -maxdepth 1 -type d -mtime +7 \
			-name "[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*-$label" \
			-exec rm -rf {} + 2>/dev/null || :
		find "$backup_root" -maxdepth 1 -type d -mtime +7 \
			-name "[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-$label" \
			-exec rm -rf {} + 2>/dev/null || :
	done
}

backup_uci_state() {
	label="$1"
	prune_stale_backups
	stamp="$(date +%Y%m%d-%H%M%S)"
	dir="$backup_root/${stamp}-$$-${label}"
	tmp="${dir}.new"
	rm -rf "$tmp"
	mkdir -p "$tmp" || return 1
	for package in ikev2-manager firewall pbr network dhcp dnsproxy; do
		if [ -f "$uci_config_dir/$package" ]; then
			cp -p "$uci_config_dir/$package" "$tmp/$package.config" || {
				rm -rf "$tmp"
				return 1
			}
		else
			: >"$tmp/$package.absent"
		fi
	done
	for service in ikev2-xfrm dnsproxy dnsmasq ikev2-dns-segments ikev2-domain-router pbr ikev2-health ikev2-user-policy; do
		[ -x "/etc/init.d/$service" ] || continue
		if "/etc/init.d/$service" enabled >/dev/null 2>&1; then
			enabled=1
		else
			enabled=0
		fi
		if "/etc/init.d/$service" running >/dev/null 2>&1; then
			running=1
		else
			running=0
		fi
		printf '%s\t%s\t%s\n' "$service" "$enabled" "$running"
	done >"$tmp/services.state"
	mv "$tmp" "$dir" || return 1
	printf '%s\n' "$dir"
}

restore_uci_state() {
	dir="$1"
	restored=1
	for package in ikev2-manager firewall pbr network dhcp dnsproxy; do
		destination="$uci_config_dir/$package"
		uci -q revert "$package" >/dev/null 2>&1 || true
		if [ -f "$dir/$package.config" ]; then
			cp -p "$dir/$package.config" "${destination}.restore.$$" &&
				mv "${destination}.restore.$$" "$destination" || restored=0
		elif [ -f "$dir/$package.absent" ]; then
			rm -f "$destination" || restored=0
		else
			restored=0
		fi
	done
	# Rollback must be able to restore a pre-upgrade configuration even when it
	# contains a warning that the new apply path would repair and reject.
	fw4 -q check >/dev/null 2>&1 && fw4 -q reload >/dev/null 2>&1 || restored=0
	while IFS="$(printf '\t')" read -r service enabled running; do
		[ -n "$service" ] || continue
		case "$service" in
			pbr | ikev2-xfrm | ikev2-dns-segments | ikev2-domain-router | dnsproxy | dnsmasq | ikev2-health | ikev2-user-policy) ;;
			*) restored=0; continue ;;
		esac
		[ -x "/etc/init.d/$service" ] || { restored=0; continue; }
		if [ "$enabled" = 1 ]; then
			/etc/init.d/"$service" enable >/dev/null 2>&1 || restored=0
		else
			/etc/init.d/"$service" disable >/dev/null 2>&1 || restored=0
		fi
		if [ "$running" = 1 ]; then
			if [ "$service" = pbr ]; then
				pbr_restart_checked >/dev/null 2>&1 || restored=0
			else
				/etc/init.d/"$service" restart >/dev/null 2>&1 || restored=0
			fi
		else
			/etc/init.d/"$service" stop >/dev/null 2>&1 || restored=0
		fi
	done <"$dir/services.state"
	reconcile_runtimes >/dev/null 2>&1 || restored=0
	# A rollback that leaves the tunnel table open has not restored anything.
	if [ "$(getv globals configured)" = 1 ]; then
		failclosed_check >/dev/null 2>&1 || restored=0
	fi
	[ "$restored" -eq 1 ]
}

# Bring every runtime the application installs in line with the current UCI
# configuration, the same way whichever path changed it: a rollback is the
# old configuration put back and then this. Each step is idempotent and runs
# even when one before it failed. The XFRM links come up first, since a route
# into a link that is down fails; policy routing comes before the runtimes
# that mark packets for it.
reconcile_runtimes() {
	local failed=0
	if [ "$(getv globals configured)" = 1 ]; then
		"$xfrm_init" start >/dev/null 2>&1 || failed=1
	fi
	if [ -x "$routing_runtime_helper" ]; then
		"$routing_runtime_helper" sync-all >/dev/null 2>&1 || failed=1
	fi
	sync_inbound_user_policy >/dev/null 2>&1 || failed=1
	pause_block_sync >/dev/null 2>&1 || failed=1
	if [ "$(getv globals configured)" = 1 ] && [ "$(getv domains engine)" = fakeip ] &&
	   [ -x "$domain_router_helper" ]; then
		"$domain_router_helper" refresh >/dev/null 2>&1 || failed=1
	fi
	return "$failed"
}

# Run FUNCTION (with its arguments) as one router transaction: snapshot the
# configuration under LABEL, run the function in a subshell so that its die()
# cannot skip the rollback, and on failure put the snapshot back and reconcile
# the runtimes with it. FAILURE names what failed; the message says whether
# the rollback completed. A transaction started inside another one takes no
# snapshot of its own and leaves the rollback to the outer one: Save used to
# restore twice, restarting every service each time, and a nested apply's
# die() skipped the outer rollback altogether.
with_transaction() {
	local label="$1" failure="$2" backup
	shift 2
	if [ "${ikev2_transaction_open:-0}" = 1 ]; then
		( "$@" )
		return
	fi
	backup="$(backup_uci_state "$label")" ||
		die "Unable to back up router state; nothing was changed"
	if ( ikev2_transaction_open=1; "$@" ); then
		rm -rf "$backup"
		return 0
	fi
	if restore_uci_state "$backup"; then
		rm -rf "$backup"
		die "$failure; previous router state was restored"
	fi
	rm -rf "$backup"
	die "$failure and automatic rollback was incomplete"
}

pbr_restart_checked() {
	local tries=0
	# Nothing of ours is left in PBR to rebuild, unless it was just retired;
	# then PBR restarts without it, or stops if the operator had it off.
	[ "${pbr_restart_needed:-0}" = 1 ] && [ -x /etc/init.d/pbr ] || return 0
	if [ "$(uci -q get pbr.config.enabled 2>/dev/null || echo 0)" != 1 ]; then
		/etc/init.d/pbr stop >/dev/null 2>&1 || :
		return 0
	fi
	logger -t ikev2-pbr-action "begin owner=manager action=restart pid=$$" 2>/dev/null || true
	/etc/init.d/pbr restart >/dev/null 2>&1 || true
	while [ "$tries" -lt 30 ]; do
		if /etc/init.d/pbr running >/dev/null 2>&1 &&
		   nft list chain inet fw4 pbr_prerouting >/dev/null 2>&1 &&
		   ensure_forward_chain; then
			logger -t ikev2-pbr-action "end owner=manager action=restart pid=$$" 2>/dev/null || true
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	logger -t ikev2-pbr-action "error owner=manager action=restart pid=$$" 2>/dev/null || true
	return 1
}

# Manual PBR restart from the overview page. PBR rebuilds the firewall and stops
# forwarding while it does, which is why the watcher never does this on its own.
# Afterwards verify what Apply verifies, so a restart cannot leave the router
# silently open: forwarding, device and inbound policy, and both fail-closed
# routes.
pbr_restart_manual() {
	[ "$(getv globals configured)" = 1 ] || die 'Managed mode is not configured'
	# There is nothing to rebuild in PBR: the routing runtime is reinstalled
	# from scratch instead and checked as Apply checks it. Forwarding does not
	# stop.
	logger -t ikev2-manager 'manual policy routing rebuild requested' 2>/dev/null || true
	"$routing_runtime_helper" stop >/dev/null 2>&1 || die 'Policy routing could not be stopped for the rebuild'
	"$routing_runtime_helper" sync >/dev/null 2>&1 || die 'Policy routing did not come back after the rebuild'
	sync_device_runtime || die 'Device policy failed to load after the rebuild'
	sync_inbound_user_policy || die 'Inbound user policy failed to load after the rebuild'
	failclosed_check >/dev/null || die 'Fail-closed route validation failed after the rebuild'
	failclosed_ipv6_check >/dev/null ||
		die 'IPv6 fail-closed route validation failed after the rebuild'
}

routing_paused() {
	[ "$(defaultv domains paused 0)" = 1 ]
}

# Pause stops using the tunnel without letting anything that would enter it
# leave through WAN: a separate table refuses whatever reaches a tunnel link, so
# selected destinations and full-tunnel devices lose access until resume, as
# they would with the tunnel down. Nothing else changes - routing, FakeIP, DNS
# and the device policy keep running as configured - so resume is immediate
# and devices have no address cached from a different path. The router's own
# pings still pass, so the tunnel quality keeps being measured.
pause_table=ikev2_pause

pause_block_install() {
	nft -f - <<EOF
table inet $pause_table
delete table inet $pause_table
table inet $pause_table {
	chain ikev2_manager_owned {
		comment "IKEv2 Manager tunnel pause"
	}
	chain forward {
		type filter hook forward priority filter - 5; policy accept;
		oifname "ipsec-out*" counter reject with icmpx admin-prohibited
	}
	chain output {
		type filter hook output priority filter - 5; policy accept;
		oifname "ipsec-out*" meta l4proto != { icmp, ipv6-icmp } counter reject with icmpx admin-prohibited
	}
}
EOF
}

pause_block_present() {
	[ "$(nft list table inet "$pause_table" 2>/dev/null |
		grep -c 'oifname "ipsec-out\*".* reject')" = 2 ]
}

pause_block_remove() {
	nft delete table inet "$pause_table" 2>/dev/null || true
	! nft list table inet "$pause_table" >/dev/null 2>&1
}

# The block follows the setting: the health watcher calls this every pass, so
# a reboot, or a firewall tool that dropped the table, does not end a pause.
pause_block_sync() {
	if [ "$(getv globals configured)" = 1 ] && routing_paused; then
		pause_block_present || pause_block_install
		pause_block_present
	else
		nft list table inet "$pause_table" >/dev/null 2>&1 || return 0
		pause_block_remove
	fi
}

pause_routing_impl() {
	[ "$(getv globals configured)" = 1 ] || die 'Managed mode is not configured'
	uci set "$config.domains.paused=1"
	uci commit "$config"
	if ! pause_block_install || ! pause_block_present; then
		pause_block_remove >/dev/null 2>&1 || true
		uci set "$config.domains.paused=0"
		uci commit "$config"
		die 'The tunnel could not be closed; routing was not paused'
	fi
}

resume_routing_impl() {
	[ "$(getv globals configured)" = 1 ] || die 'Managed mode is not configured'
	uci set "$config.domains.paused=0"
	uci commit "$config"
	pause_block_remove || die 'The tunnel block could not be removed'
}

remove_managed() {
	# Stop the reconciler before removing any runtime it owns.  Leaving it alive
	# until the end lets a health cycle recreate the inbound, device or FakeIP
	# tables between teardown and disabled_runtime_absent(), making disable fail
	# nondeterministically.  The outer transaction restores the previous service
	# state if any later cleanup step fails.
	if [ -x /etc/init.d/ikev2-health ]; then
		/etc/init.d/ikev2-health stop >/dev/null 2>&1 || return 1
		/etc/init.d/ikev2-health disable >/dev/null 2>&1 || return 1
	fi
	if [ -x /usr/libexec/ikev2-discord-voice ]; then
		/usr/libexec/ikev2-discord-voice stop >/dev/null 2>&1 || return 1
	fi
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router shutdown >/dev/null 2>&1 || return 1
	fi
	if [ -x /etc/init.d/ikev2-dns-segments ]; then
		/etc/init.d/ikev2-dns-segments stop >/dev/null 2>&1 || return 1
		/etc/init.d/ikev2-dns-segments disable >/dev/null 2>&1 || return 1
	fi
	delete_prefixed_sections firewall ikev2pbr_
	delete_prefixed_sections firewall ikev2access_
	uci commit firewall || return 1
	uci -q delete network.ikev2out || true
	uci commit network || return 1
	release_pbr_config || return 1
	rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
	rm -f /var/run/ikev2-vip4
	# Without a tunnel to protect a pause has nothing to refuse.
	pause_block_remove || return 1
	# Drop the IPv6 fail-fast route only if we added it (no real v6 default).
	ip -6 route show default 2>/dev/null | grep -q 'unreachable' &&
		ip -6 route del unreachable default metric 2147483647 2>/dev/null || true
	# Remove live firewall and PBR references before stopping the XFRM links.
	# OpenWrt 25 can otherwise block forever inside `ip link del ipsec-in`.
	firewall_check_strict >/dev/null 2>&1 || return 1
	fw4 -q reload >/dev/null 2>&1 || return 1
	if [ ! -x /etc/init.d/pbr ]; then
		:
	elif [ "$(uci -q get pbr.config.enabled 2>/dev/null || echo 0)" = 1 ]; then
		pbr_restart_checked || return 1
		/etc/init.d/pbr running >/dev/null 2>&1 || return 1
	else
		/etc/init.d/pbr stop >/dev/null 2>&1 || return 1
	fi
	if [ -x /etc/init.d/ikev2-xfrm ]; then
		/etc/init.d/ikev2-xfrm stop >/dev/null 2>&1 || return 1
		/etc/init.d/ikev2-xfrm disable >/dev/null 2>&1 || return 1
	fi
	# The per-user table is the fail-closed guard in front of the deliberately
	# broad fw4 zone forwarding. Keep it until those rules are reloaded and XFRM
	# is down; deleting it earlier creates a transient access-policy bypass.
	if [ -x "$user_policy_init" ]; then
		"$user_policy_init" stop >/dev/null 2>&1 || return 1
		"$user_policy_init" disable >/dev/null 2>&1 || return 1
	elif [ -x "$user_policy_helper" ]; then
		"$user_policy_helper" stop >/dev/null 2>&1 || return 1
	fi
	# Keep the independent atomic device table until every risky service and
	# firewall transition has succeeded. A failed disable can then restore UCI
	# without leaving configured mode missing its live DNS/device policy.
	if [ -x "$device_runtime_helper" ]; then
		"$device_runtime_helper" stop >/dev/null 2>&1 || return 1
	fi
	if [ -x "$routing_runtime_helper" ]; then
		"$routing_runtime_helper" stop >/dev/null 2>&1 || return 1
	fi
	disabled_runtime_absent
}

apply_system_inner() {
	[ "$(getv globals configured)" = 1 ] ||
		die 'Base setup is not enabled'
	validate_runtime_config
	# Regenerate managed firewall sections before doctor so an upgrade can
	# repair stale sections that an older release rendered in an invalid form.
	# The outer transaction restores the original UCI state on any later error.
	sync_firewall
	IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR=1 \
		doctor >/tmp/ikev2-manager-doctor.last 2>&1 ||
		die 'Dependency check failed; run ikev2-manager-system doctor'
	sync_network
	# Fail-closed behavior has two native layers: an unreachable PBR default and
	# XFRM policy drop when no matching SA exists. The XFRM interfaces come up
	# first: the tunnel table routes through ipsec-out, and after managed mode
	# was turned off the interface is down, so installing the table first
	# failed with "Device for nexthop is not up" and managed mode never came
	# back. An interface with no route into it carries nothing.
	rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
	/etc/init.d/ikev2-xfrm enable || die 'Failed to enable ikev2-xfrm'
	/etc/init.d/ikev2-health enable || die 'Failed to enable ikev2-health'
	/etc/init.d/ikev2-xfrm start || die 'Failed to start ikev2-xfrm'
	sync_pbr
	firewall_check_strict || die 'firewall4 validation failed'
	pbr_restart_checked ||
		die 'PBR did not come back after the application left it; check logread'
	fw4 -q reload || die 'firewall4 reload failed'
	sync_device_runtime || die 'Device policy failed to load'
	sync_inbound_user_policy || die 'Inbound user policy failed to load'
	ensure_forward_chain ||
		die 'fw4 forward chain has no zone forwarding after apply (LAN->WAN would be dropped); rolled back'
	failclosed_check >/dev/null ||
		die 'Fail-closed route validation failed'
	failclosed_ipv6_check >/dev/null ||
		die 'IPv6 fail-closed route validation failed'
	ensure_ipv6_failfast
	/etc/init.d/ikev2-health start >/dev/null 2>&1 || true
	# Turning managed mode off stops the segment resolvers and the FakeIP
	# service; turning it on brings them back, not only the routing.
	if [ "$(defaultv dns managed 0)" = 1 ] && [ -x /etc/init.d/ikev2-dns-segments ]; then
		/etc/init.d/ikev2-dns-segments enable >/dev/null 2>&1 &&
			/etc/init.d/ikev2-dns-segments restart >/dev/null 2>&1 ||
			die 'DNS segments failed to start'
	fi
	if [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		if ! /etc/init.d/ikev2-domain-router enabled 2>/dev/null; then
			# Stopped with managed mode: resume starts it, points dnsmasq at
			# it again and restores interception. A refresh only restarted
			# the service and left dnsmasq on its previous resolver.
			/usr/libexec/ikev2-domain-router resume ||
				die 'FakeIP domain router failed to start'
		else
			/usr/libexec/ikev2-domain-router refresh ||
				die 'FakeIP domain router refresh failed'
		fi
	fi
	# A pause survives an apply: the block follows the setting.
	pause_block_sync || die 'The tunnel pause could not be restored'
	remove_unused_pbr
}

apply_system() {
	with_transaction apply 'Managed apply failed' "$0" _apply-system-inner
}

disable_managed() {
	with_transaction disable 'Managed mode could not be disabled' "$0" _disable-managed-inner
}

# Narrow runtime apply for Inbound Server saves. Most server edits only need a
# firewall reload and a strongSwan reload (performed by the manager worker).
# PBR itself is restarted only when enabling/disabling the server changes
# whether @ipsec-in participates in the domain policy.
apply_server_runtime() {
	needs_pbr="${1:-0}"
	[ "$(getv globals configured)" = 1 ] ||
		die 'Base setup is not enabled'
	[ "$needs_pbr" = 0 ] || [ "$needs_pbr" = 1 ] ||
		die 'Invalid server routing-change flag'
	validate_runtime_config
	sync_firewall
	# The interfaces first: enabling the server routes its pool through
	# ipsec-in, which is down while the server is off, and installing the
	# routes before it came up failed with "Device for nexthop is not up".
	/etc/init.d/ikev2-xfrm start || die 'Failed to update inbound XFRM interface'
	if [ "$needs_pbr" = 1 ]; then
		sync_pbr
	fi
	firewall_check_strict || die 'firewall4 validation failed'
	if [ "$needs_pbr" = 1 ]; then
		pbr_restart_checked || die 'PBR did not come back after the application left it; check logread'
		failclosed_ipv6_check >/dev/null ||
			die 'IPv6 fail-closed route validation failed after the server change'
	fi
	fw4 -q reload || die 'firewall4 reload failed'
	sync_device_runtime || die 'Device policy failed to load'
	ensure_forward_chain ||
		die 'fw4 forward chain has no zone forwarding after server apply'
	sync_inbound_user_policy ||
		die 'Inbound user policy failed to load'
	ensure_ipv6_failfast
	/etc/init.d/ikev2-health start >/dev/null 2>&1 || true
	if [ "$needs_pbr" = 1 ] &&
	   [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router refresh ||
			die 'FakeIP domain router refresh failed'
	fi
}

apply_server_runtime_transaction() {
	with_transaction server-runtime 'Inbound server runtime apply failed' \
		"$0" _server-apply-inner "${1:-0}"
}

show_config() {
	domain_status=''
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		domain_status="$(/usr/libexec/ikev2-domain-router status 2>/dev/null || true)"
	fi
	printf 'configured=%s\n' "$(getv globals configured)"
	printf 'routing_backend=native\n'
	printf 'routing_paused=%s\n' "$(defaultv domains paused 0)"
	printf 'version=%s\n' \
		"$(cat /usr/share/ikev2-manager/version 2>/dev/null || echo unknown)"
	printf 'wan_interface=%s\n' "$(getv globals wan_interface)"
	printf 'wan_zone=%s\n' "$(getv globals wan_zone)"
	printf 'source_interfaces=%s\n' "$(get_list globals source_interface)"
	printf 'source_zones=%s\n' "$(get_list globals source_zone)"
	printf 'dns_enforce=%s\n' "$(getv globals dns_enforce)"
	printf 'block_dot=%s\n' "$(getv globals block_dot)"
	printf 'source_include_vpn=%s\n' "$(defaultv globals source_include_vpn 1)"
	printf 'server_enabled=%s\n' "$(getv server enabled)"
	for field in engine service dnsmasq_upstream dnsmasq_cache dnsmasq_resolver nft rule healthy data_plane data_plane_restarts data_plane_restarted_at state message; do
		if [ "$field" = engine ]; then
			value="$(getv domains engine)"
		else
			value="$(printf '%s\n' "$domain_status" | sed -n "s/^$field=//p" | tail -n1)"
		fi
		printf 'domain_%s=%s\n' "$field" "$value"
	done
	if failclosed_ipv6_check >/dev/null 2>&1; then
		printf 'ipv6_failfast=active\n'
	elif ip -6 route show default 2>/dev/null | grep -q .; then
		printf 'ipv6_failfast=missing\n'
	else
		printf 'ipv6_failfast=off\n'
	fi
}

persist_base_config() {
	uci set "$config.globals.configured=$enabled" || return 1
	uci set "$config.globals.wan_interface=$wan_interface" || return 1
	uci set "$config.globals.wan_zone=$wan_zone" || return 1
	set_list globals source_interface "$source_interfaces" || return 1
	set_list globals source_zone "$source_zones" || return 1
	uci set "$config.globals.dns_enforce=$dns_enforce" || return 1
	uci set "$config.globals.block_dot=$block_dot" || return 1
	uci set "$config.globals.source_include_vpn=$include_vpn" || return 1
	uci commit "$config" || return 1
	[ "$(getv globals configured)" = "$enabled" ] || return 1
	[ "$(getv globals wan_interface)" = "$wan_interface" ] || return 1
	[ "$(getv globals wan_zone)" = "$wan_zone" ] || return 1
	[ "$(normalize_list "$(get_list globals source_interface)")" = "$source_interfaces" ] || return 1
	[ "$(normalize_list "$(get_list globals source_zone)")" = "$source_zones" ] || return 1
	[ "$(getv globals dns_enforce)" = "$dns_enforce" ] || return 1
	[ "$(getv globals block_dot)" = "$block_dot" ] || return 1
	[ "$(getv globals source_include_vpn)" = "$include_vpn" ]
}

base_config_matches() {
	[ "$(getv globals configured)" = "$enabled" ] &&
	[ "$(getv globals wan_interface)" = "$wan_interface" ] &&
	[ "$(getv globals wan_zone)" = "$wan_zone" ] &&
	[ "$(normalize_list "$(get_list globals source_interface)")" = "$source_interfaces" ] &&
	[ "$(normalize_list "$(get_list globals source_zone)")" = "$source_zones" ] &&
	[ "$(getv globals dns_enforce)" = "$dns_enforce" ] &&
	[ "$(getv globals block_dot)" = "$block_dot" ] &&
	[ "$(getv globals source_include_vpn)" = "$include_vpn" ]
}

disabled_runtime_absent() {
	! uci -q get network.ikev2out >/dev/null 2>&1 &&
	! uci show firewall 2>/dev/null | grep -q '^firewall\.ikev2pbr_' &&
	! uci show pbr 2>/dev/null | grep -Eq '^pbr\.(ikev2pbr_|pbr_dev_(fr|ex)_)' &&
	! "$nft_binary" list table inet ikev2_device_policy >/dev/null 2>&1 &&
	! "$nft_binary" list table inet ikev2_user_policy >/dev/null 2>&1 &&
	! "$nft_binary" list table inet ikev2_discord_voice >/dev/null 2>&1 &&
	! "$nft_binary" list table inet ikev2_domain_router >/dev/null 2>&1 &&
	! ip -4 rule show 2>/dev/null | grep -q 'lookup 51820' &&
	[ ! -e /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft ]
}

set_config() {
	[ "$#" -eq 5 ] || [ "$#" -eq 6 ] ||
		die 'Expected: configured wan_interface source_interfaces dns_enforce block_dot [source_include_vpn]'
	enabled="$1"
	wan_interface="$2"
	source_interfaces="$3"
	dns_enforce="$4"
	block_dot="$5"
	# Optional 6th arg keeps older callers working; absent -> preserve current.
	include_vpn="${6:-$(defaultv globals source_include_vpn 1)}"

	[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
	valid_name "$wan_interface" || die 'Invalid WAN network interface'
	valid_name_list "$source_interfaces" || die 'Invalid protected networks'
	[ "$dns_enforce" = 0 ] || [ "$dns_enforce" = 1 ] || die 'Invalid DNS enforcement value'
	[ "$block_dot" = 0 ] || [ "$block_dot" = 1 ] || die 'Invalid DoT block value'
	[ "$include_vpn" = 0 ] || [ "$include_vpn" = 1 ] || die 'Invalid VPN-server inclusion value'
	source_interfaces="$(normalize_list "$source_interfaces")"
	uci -q get "network.$wan_interface" >/dev/null 2>&1 ||
		die "WAN network '$wan_interface' does not exist"

	# Firewall zones are derived from the chosen networks (no separate UI fields).
	wan_zone="$(zone_for_network "$wan_interface")"
	zone_exists "$wan_zone" || die "WAN firewall zone '$wan_zone' does not exist"
	source_zones=""
	unique_sources=""
	for _n in $source_interfaces; do
		[ "$_n" != "$wan_interface" ] ||
			die "WAN network '$wan_interface' cannot be a protected network"
		uci -q get "network.$_n" >/dev/null 2>&1 ||
			die "Protected network '$_n' does not exist"
		network_device "$_n" >/dev/null || die "Protected network '$_n' has no device"
		_z="$(zone_for_network "$_n")"
		zone_exists "$_z" || die "Firewall zone '$_z' does not exist"
		[ "$_z" != "$wan_zone" ] ||
			die "Protected network '$_n' belongs to the WAN firewall zone '$wan_zone'"
		case " $unique_sources " in *" $_n "*) ;; *) unique_sources="${unique_sources:+$unique_sources }$_n" ;; esac
		case " $source_zones " in *" $_z "*) ;; *) source_zones="${source_zones:+$source_zones }$_z" ;; esac
	done
	source_interfaces="$unique_sources"

	# Saving identical settings should not rebuild firewall and PBR for 10-20
	# seconds. Skip the transaction only after proving that the corresponding
	# runtime is already healthy (or fully absent for disabled mode). Any drift
	# still falls through to the normal transactional apply/repair path. What
	# a release that routed through PBR left there is such a drift: an Apply
	# is what releases it, and skipped here it stayed for good while the
	# readiness report went on promising "at the next Apply".
	if base_config_matches; then
		if [ "$enabled" = 1 ] && ! pbr_holds_ours && [ -x "$routing_check_helper" ] &&
		   "$routing_check_helper" --check; then
			return 0
		fi
		if [ "$enabled" = 0 ] && disabled_runtime_absent; then
			return 0
		fi
	fi

	if [ "$enabled" = 1 ]; then
		with_transaction enable-managed 'Managed mode failed' enable_managed_steps
	else
		with_transaction disable-managed 'Managed mode could not be disabled' disable_managed_steps
	fi
}

enable_managed_steps() {
	persist_base_config || die 'Unable to save managed settings'
	apply_system
}

disable_managed_steps() {
	persist_base_config || die 'Unable to save managed settings'
	"$0" _remove-managed-inner
}

zone_for_network() {
	local n zname nets net i
	n="$1"; i=0
	while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
		zname="$(uci -q get "firewall.@zone[$i].name" 2>/dev/null || true)"
		nets="$(uci -q get "firewall.@zone[$i].network" 2>/dev/null || true)"
		for net in $nets; do
			[ "$net" = "$n" ] && { printf '%s' "${zname:-$n}"; return 0; }
		done
		i=$((i + 1))
	done
	printf '%s' "$n"
}

coverage_add() {
	name="$1"
	valid_name "$name" || die 'Invalid network name'
	uci -q get "network.$name" >/dev/null 2>&1 ||
		die "Network '$name' does not exist"
	network_device "$name" >/dev/null || die "Network '$name' has no device"
	zone="$(zone_for_network "$name")"
	zone_exists "$zone" || die "Firewall zone '$zone' does not exist"
	wan_interface="$(getv globals wan_interface)"
	wan_zone="$(getv globals wan_zone)"
	[ -z "$wan_interface" ] || [ "$name" != "$wan_interface" ] ||
		die "WAN network '$name' cannot be a protected network"
	[ -z "$wan_zone" ] || [ "$zone" != "$wan_zone" ] ||
		die "Network '$name' belongs to the WAN firewall zone '$wan_zone'"
	with_transaction coverage-add 'Unable to add protected network' coverage_add_steps "$name" "$zone"
}

coverage_add_steps() {
	add_list_unique "$config" globals source_interface "$1" &&
		add_list_unique "$config" globals source_zone "$2" &&
		uci commit "$config" &&
		printf ' %s ' "$(get_list globals source_interface)" | grep -Fq " $1 " &&
		printf ' %s ' "$(get_list globals source_zone)" | grep -Fq " $2 " ||
		die 'Unable to save the protected networks'
	[ "$(getv globals configured)" != 1 ] || apply_system
}

coverage_remove() {
	name="$1"
	valid_name "$name" || die 'Invalid network name'
	new=''
	for i in $(get_list globals source_interface); do
		[ "$i" = "$name" ] || new="${new:+$new }$i"
	done
	[ -n "$new" ] || die 'At least one protected network must remain'
	zone="$(zone_for_network "$name")"
	keep=0
	for i in $new; do
		[ "$(zone_for_network "$i")" = "$zone" ] && keep=1
	done
	zn="$(get_list globals source_zone)"
	if [ "$keep" = 0 ]; then
		zn=''
		for z in $(get_list globals source_zone); do
			[ "$z" = "$zone" ] || zn="${zn:+$zn }$z"
		done
	fi
	with_transaction coverage-remove 'Unable to remove protected network' coverage_remove_steps "$new" "$zn"
}

coverage_remove_steps() {
	set_list globals source_interface "$1" &&
		set_list globals source_zone "$2" &&
		uci commit "$config" &&
		[ "$(normalize_list "$(get_list globals source_interface)")" = "$1" ] &&
		[ "$(normalize_list "$(get_list globals source_zone)")" = "$2" ] ||
		die 'Unable to save the protected networks'
	[ "$(getv globals configured)" != 1 ] || apply_system
}

# The last line a failed step wrote to stderr, which names what happened and
# whether its rollback completed. A fixed message claimed that the previous
# state was restored even when the step itself reported that it was not.
action_error_message() {
	local file="$1" fallback="$2" message
	cat "$file" >&2 2>/dev/null || true
	message="$(tr -d '\r' <"$file" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n1)"
	rm -f "$file"
	printf '%s\n' "${message:-$fallback}"
}

run_action() {
	id="$1"
	kind="$2"
	shift 2
	step_error="/tmp/ikev2-system-action-$id.error"
	exec >>/tmp/ikev2-system-action.log 2>&1
	printf '\n=== %s action=%s id=%s ===\n' "$(date)" "$kind" "$id"
	if ! acquire_action_lock_announced system "$id" action_status "$id"; then
		action_status "$id" error 'Another router action is still running.'
		return 1
	fi
	quality_action_begin "$kind"
	trap 'quality_action_end; rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	# Actions that name their own step below must not first claim to be
	# applying the configuration: the page shows every step it is told.
	case "$kind" in
		set | coverage-add | coverage-remove | dns-segment)
			action_status "$id" running 'Applying router configuration...'
			;;
	esac

	case "$kind" in
		set)
			if ( set_config "$@" ) 2>"$step_error"; then
				rm -f "$step_error"
				action_status "$id" ok 'Router configuration applied.'
			else
				action_status "$id" error "$(action_error_message "$step_error" \
					'Router apply failed; see /tmp/ikev2-system-action.log.')"
			fi
			;;
		coverage-add)
			if ( coverage_add "$1" ) 2>"$step_error"; then
				rm -f "$step_error"
				action_status "$id" ok 'Network added to policy routing.'
			else
				action_status "$id" error "$(action_error_message "$step_error" \
					'Unable to add the network; see /tmp/ikev2-system-action.log.')"
			fi
			;;
		coverage-remove)
			if ( coverage_remove "$1" ) 2>"$step_error"; then
				rm -f "$step_error"
				action_status "$id" ok 'Network removed from policy routing.'
			else
				action_status "$id" error "$(action_error_message "$step_error" \
					'Unable to remove the network; see /tmp/ikev2-system-action.log.')"
			fi
			;;
		device)
			action_status "$id" running 'Applying and verifying device routing...'
			if /usr/libexec/ikev2-devices "$@" 2>"$step_error"; then
				rm -f "$step_error"
				action_status "$id" ok 'Device routing updated.'
			else
				action_status "$id" error "$(action_error_message "$step_error" \
					'Device routing failed; the previous device settings were restored.')"
			fi
			;;
		routing-pause)
			action_status "$id" running 'Pausing tunnel routing...'
			if ( pause_routing_impl ); then
				action_status "$id" ok 'Tunnel routing paused; selected traffic is blocked until you resume.'
			else
				action_status "$id" error 'Could not pause tunnel routing; see /tmp/ikev2-system-action.log.'
			fi
			;;
		routing-resume)
			action_status "$id" running 'Resuming tunnel routing...'
			if ( resume_routing_impl ); then
				action_status "$id" ok 'Tunnel routing resumed.'
			else
				action_status "$id" error 'Could not resume tunnel routing; see /tmp/ikev2-system-action.log.'
			fi
			;;
		recover-reliable)
			action_status "$id" running 'Restarting reliable mode...'
			if /usr/libexec/ikev2-domain-router recover; then
				action_status "$id" ok 'Reliable mode restarted.'
			else
				# The domain router records why; the page translates that message.
				recover_message="$(/usr/libexec/ikev2-domain-router status 2>/dev/null |
					sed -n 's/^message=//p' | tail -n1)"
				action_status "$id" error \
					"${recover_message:-Could not restart reliable mode; see /tmp/ikev2-domain-router.log.}"
			fi
			;;
		pbr-restart)
			action_status "$id" running 'Restarting policy routing...'
			if ( pbr_restart_manual ); then
				action_status "$id" ok 'Policy routing restarted; fail-closed routing verified.'
			else
				action_status "$id" error 'Policy routing restart failed; see /tmp/ikev2-system-action.log.'
			fi
			;;
		dns-set)
			dns_error_file="/tmp/ikev2-dns-action-$id.error"
			rm -f "$dns_error_file"
			action_status "$id" running 'Applying and testing DNS settings...'
			if "$0" _dns-apply-inner "$@" 2>"$dns_error_file"; then
				action_status "$id" ok 'DNS settings applied.'
			else
				cat "$dns_error_file" >&2 2>/dev/null || true
				dns_error="$(tr -d '\r' <"$dns_error_file" 2>/dev/null | tail -n1)"
				[ -n "$dns_error" ] ||
					dns_error='DNS apply failed; check /tmp/ikev2-system-action.log.'
				action_status "$id" error "$dns_error"
			fi
			rm -f "$dns_error_file"
			;;
		backup-import)
			action_status "$id" running 'Importing the settings...'
			if ( backup_import "$1" ) 2>"$step_error"; then
				rm -f "$step_error"
				action_status "$id" ok 'Settings imported.'
			else
				action_status "$id" error "$(action_error_message "$step_error" \
					'The import failed; see /tmp/ikev2-system-action.log.')"
			fi
			;;
		dns-segment)
			segment_file="$1"
			if [ ! -f "$segment_file" ] || [ -L "$segment_file" ] || ! {
				IFS= read -r segment_action
				IFS= read -r segment_id
				IFS= read -r segment_name
				IFS= read -r segment_enabled
				IFS= read -r segment_domains
				IFS= read -r segment_protocol
				IFS= read -r segment_mode
				IFS= read -r segment_upstream
				IFS= read -r segment_bootstrap
			} <"$segment_file"; then
				rm -f "$segment_file"
				action_status "$id" error 'Destination DNS segment input is incomplete.'
				return 1
			fi
			segment_fallback="$(sed -n '10p' "$segment_file")"
			segment_https_compat="$(sed -n '11p' "$segment_file")"
			[ -n "$segment_https_compat" ] || segment_https_compat=1
			segment_wan_fallback="$(sed -n '12p' "$segment_file")"
			[ -n "$segment_wan_fallback" ] || segment_wan_fallback=0
			# Empty from a page that predates the setting: the stored one stays.
			segment_via="$(sed -n '13p' "$segment_file")"
			segment_extra="$(sed -n '14p' "$segment_file")"
			rm -f "$segment_file"
			if [ -n "$segment_extra" ]; then
				action_status "$id" error 'Destination DNS segment input has extra fields.'
				return 1
			fi
			if ( dns_segment_update "$segment_action" "$segment_id" "$segment_name" \
				"$segment_enabled" "$segment_domains" "$segment_protocol" \
				"$segment_mode" "$segment_upstream" "$segment_bootstrap" \
				"$segment_fallback" "$segment_https_compat" "$segment_wan_fallback" \
				"$segment_via" ) 2>"$step_error"; then
				rm -f "$step_error"
				action_status "$id" ok 'Destination DNS segment applied.'
			else
				action_status "$id" error "$(action_error_message "$step_error" \
					'Destination DNS segment failed; previous resolver preserved.')"
			fi
			;;
		*)
			action_status "$id" error 'Unknown router action.'
			;;
	esac
}

case "${1:-}" in
	preflight)
		preflight
		;;
	deps-plan)
		verify_install_plan
		printf 'install_plan=ok\n'
		;;
	doctor)
		doctor
		;;
	doctor-ui)
		# LuCI's fs.exec rejects a non-zero process and discards its stdout.  The
		# fast report is structured diagnostic data even when one runtime check is
		# degraded, so return it successfully and reserve command failure for an
		# RPC that could not execute at all.
		doctor_ui_report
		;;
	_doctor-ui-refresh)
		pid_lock_acquire "$doctor_ui_refresh_lock" || exit 0
		doctor_ui_write_cache
		pid_lock_release "$doctor_ui_refresh_lock"
		;;
	failclosed-check)
		failclosed_check
		failclosed_ipv6_check
		printf 'failclosed_route=ok\n'
		;;
	install-deps)
		install_deps
		;;
	_install-deps-run)
		doctor_ui_cache_invalidate
		run_install_deps "${2:-}"
		;;
	remove-deps)
		remove_deps
		;;
	_remove-deps-run)
		doctor_ui_cache_invalidate
		run_remove_deps "${2:-}"
		;;
	deps-status)
		cat "$deps_status_file" 2>/dev/null || true
		;;
	get)
		show_config
		;;
	dns-get)
		dns_show
		;;
	dns-segments-get)
		dns_segments_show
		;;
	dns-segments-check)
		dns_segments_check
		;;
	dns-buffer-status)
		"$device_runtime_helper" dns-malformed-stats
		# Filtered by logread itself: piping the whole buffer cost seconds.
		errors="$(logread -e 'dns: buffer size too small' 2>/dev/null |
			grep -Fc 'dns: buffer size too small' 2>/dev/null || true)"
		printf 'singbox_errors=%s\n' "${errors:-0}"
		;;
	_doctor-dns-segments-status)
		doctor_dns_segments_status
		;;
	dns-segment-input)
		[ "$#" -eq 2 ] || die 'Expected DNS segment input token'
		dns_segment_input "$2"
		;;
	routing-pause-async)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		start_action routing-pause
		;;
	routing-resume-async)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		start_action routing-resume
		;;
	recover-reliable-async)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		start_action recover-reliable
		;;
	pbr-restart-async)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		start_action pbr-restart
		;;
	dns-set-async)
		[ -n "$dns_input_file" ] || dns_input_file="$(input_file_for "${2:-}")"
		dns_set_async
		;;
	_dns-apply-inner)
		shift
		dns_apply "$@"
		;;
	diagnostics)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		diagnostics_report
		;;
	backup-export)
		[ "$#" -eq 2 ] || die 'Expected a backup input token'
		backup_export "$2"
		;;
	backup-import-async)
		[ "$#" -eq 2 ] || die 'Expected a backup input token'
		backup_input_file "$2" in >/dev/null
		start_action backup-import "$2"
		;;
	_validate-dns-endpoint)
		[ "$#" -eq 3 ] || die 'Expected: protocol endpoint'
		valid_dns_endpoint "$2" "$3"
		;;
	_firewall-check)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		firewall_check_strict
		;;
	_upgrade-reconcile)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		# The previous watcher keeps running through an upgrade. Holding the
		# router action lock keeps its repairs, and any page action, out of
		# the runtimes while they are rebuilt.
		IKEV2_ACTION_LOCK_WAIT_SECONDS="${IKEV2_ACTION_LOCK_WAIT_SECONDS:-60}"
		acquire_action_lock upgrade upgrade-reconcile ||
			die 'Another router action is still running'
		trap 'release_action_lock' EXIT INT TERM
		doctor_ui_cache_invalidate
		reconcile_upgrade_runtime
		;;
	_validate-dns-segments)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		validate_dns_segments
		;;
	_dns-segment-update)
		{ [ "$#" -ge 11 ] && [ "$#" -le 14 ]; } ||
			die 'Expected DNS segment update arguments'
		shift
		dns_segment_update "$@"
		;;
	_dns-combined-upstreams)
		[ "$#" -eq 2 ] || die 'Expected a base DNS upstream'
		dns_combined_upstreams "$2"
		;;
	_dns-runtime-timeout)
		[ "$#" -eq 2 ] || die 'Expected fallback state'
		dns_runtime_timeout "$2"
		;;
	_wan-dns-fallbacks)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		wan_dns_fallbacks
		;;
	_pause-sync)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		pause_block_sync
		;;
	_dns-wan-refresh)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		refresh_status=0
		dns_wan_fallback_refresh || refresh_status=$?
		dns_segments_wan_refresh || true
		exit "$refresh_status"
		;;
	_dnsmasq-combined-servers)
		[ "$#" -eq 2 ] || die 'Expected a base dnsmasq server'
		dnsmasq_combined_servers "$2"
		;;
	set)
		shift
		set_config "$@"
		;;
	set-async)
		shift
		start_action set "$@"
		;;
	apply)
		apply_system
		;;
	_apply-system-inner)
		apply_system_inner
		;;
	_remove-managed-inner)
		remove_managed
		;;
	_disable-managed-inner)
		uci set "$config.globals.configured=0"
		uci commit "$config"
		remove_managed
		;;
	_sync-pbr)
		sync_pbr
		;;
	_sync-firewall)
		# Drop legacy UCI redirects and refresh the dedicated atomic nftables
		# runtime that owns DNS interception and per-device bypasses.
		sync_firewall
		firewall_check_strict || die 'Firewall validation failed'
		fw4 -q reload || die 'Unable to reload the firewall'
		sync_device_runtime || die 'Device DNS policy failed to load'
		;;
	server-apply)
		apply_server_runtime_transaction "${2:-0}"
		;;
	_server-apply-inner)
		apply_server_runtime "${2:-0}"
		;;
	validate-server-zones)
		[ "$#" -eq 3 ] || die 'Expected: validate-server-zones inbound outbound'
		validate_server_zone_names "$2" "$3"
		;;
	strongswan-security)
		[ "$#" -eq 2 ] || die 'Expected: strongswan-security client|server'
		strongswan_security_check "$2"
		;;
	_upnp-check)
		upnp_ikev2_check
		;;
	client-api-apply)
		[ "$#" -eq 1 ] || die 'Expected: client-api-apply'
		sync_client_api_rule
		uci commit firewall
		firewall_check_strict
		fw4 -q reload
		;;
	access-apply)
		zone="$(defaultv server firewall_zone ikev2in)"
		zone_exists "$zone" ||
			die "Inbound firewall zone '$zone' does not exist"
		sync_inbound_access
		firewall_check_strict
		fw4 -q reload
		sync_device_runtime || die 'Device policy failed to load'
		sync_inbound_user_policy ||
			die 'Inbound user policy failed to load'
		;;
	disable)
		disable_managed ||
			die 'Unable to disable managed mode; previous state was preserved or restored'
		;;
	gateway-network)
		gateway_network
		;;
	coverage-add)
		coverage_add "${2:-}"
		;;
	coverage-remove)
		coverage_remove "${2:-}"
		;;
	coverage-async)
		[ "$#" -eq 3 ] || die 'Expected: coverage-async add|remove network'
		case "$2" in
			add) start_action coverage-add "$3" ;;
			remove) start_action coverage-remove "$3" ;;
			*) die 'Expected coverage action: add or remove' ;;
		esac
		;;
	device-async)
		shift
		case "${1:-}" in
			add-subnet | remove-subnet | remove-override | set-unmanaged | clear-policy)
				[ "$#" -eq 2 ] || die 'Expected device action and address'
				;;
			set-included)
				{ [ "$#" -eq 2 ] || [ "$#" -eq 3 ]; } ||
					die 'Expected set-included address [respect]'
				;;
			add-override)
				[ "$#" -eq 3 ] || die 'Expected add-override address mode'
				;;
			set-flag)
				[ "$#" -eq 4 ] || die 'Expected set-flag address flag value'
				;;
			set-exit)
				[ "$#" -eq 3 ] || die 'Expected set-exit address tunnel'
				;;
			set-exclusions)
				[ "$#" -eq 5 ] ||
					die 'Expected set-exclusions address pbr dns zapret'
				;;
			*) die 'Unsupported device action' ;;
		esac
		start_action device "$@"
		;;
	_action-run)
		shift
		doctor_ui_cache_invalidate
		if run_action "$@"; then
			doctor_ui_cache_invalidate
		else
			rc=$?
			doctor_ui_cache_invalidate
			exit "$rc"
		fi
		;;
	action-status)
		if [ -n "${2:-}" ]; then
			# The page passes the id back; anything but an id is not one.
			case "$2" in *[!0-9-]*) die 'Invalid action id' ;; esac
			cat "$action_status_dir/$2.status" 2>/dev/null || printf 'state=idle\n'
		else
			cat "$action_status_file" 2>/dev/null || printf 'state=idle\n'
		fi
		;;
	*)
		die 'Usage: ikev2-manager-system {preflight|deps-plan|doctor|doctor-ui|diagnostics|backup-export|backup-import-async|failclosed-check|install-deps|remove-deps|deps-status|get|dns-get|dns-buffer-status|routing-pause-async|routing-resume-async|recover-reliable-async|pbr-restart-async|dns-set-async|set|set-async|apply|server-apply|validate-server-zones|strongswan-security|access-apply|disable|gateway-network|coverage-add|coverage-remove|coverage-async|device-async|action-status}'
		;;
esac
