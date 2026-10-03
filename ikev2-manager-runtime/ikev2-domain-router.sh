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
domain_file="${IKEV2_DOMAIN_FILE:-/etc/pbr-ikev2-domains.txt}"
config_file="${IKEV2_DOMAIN_CONFIG:-/etc/ikev2-manager/domain-router.json}"
ruleset_file="${IKEV2_DOMAIN_RULESET:-/etc/ikev2-manager/domain-router-rules.json}"
# Domains never to go through the tunnel, and the rule-set sing-box reads
# them from; it exists only while the list has something in it.
bypass_domain_file="${IKEV2_BYPASS_DOMAINS:-/etc/pbr-ikev2-domains.bypass.txt}"
bypass_ruleset_file="${IKEV2_BYPASS_RULESET:-/etc/ikev2-manager/domain-router-bypass.json}"
work_dir="${IKEV2_DOMAIN_WORK_DIR:-/etc/ikev2-manager/domain-router}"
state_file="${IKEV2_DOMAIN_STATE:-/var/run/ikev2-domain-router.status}"
tunnel_dns_state="${IKEV2_TUNNEL_DNS_STATE:-/var/run/ikev2-tunnel-dns.state}"
data_plane_state="${IKEV2_DATA_PLANE_STATE:-/var/run/ikev2-data-plane.state}"
log_file="${IKEV2_DOMAIN_LOG:-/tmp/ikev2-domain-router.log}"
lock_dir="${IKEV2_DOMAIN_LOCK:-/var/run/ikev2-domain-router.lock}"
# Outside /etc/ikev2-manager, which dnsmasq's account cannot enter, and kept
# across upgrades: dnsmasq reads it at boot, before this service starts.
dnsmasq_servers_file="${IKEV2_DNSMASQ_SERVERS:-/etc/ikev2-dnsmasq.servers}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
dns_address='127.0.0.42'
dns_port='53'
tproxy_address='127.0.0.1'
tproxy_port='1602'
direct_tproxy_port='1603'
router_tproxy_port='1604'
fakeip_range='198.18.0.0/15'
tproxy_mark='0x400000'
tproxy_mask='0xff0000'
direct_tproxy_mark='0x00400001'
router_tproxy_mark='0x00400002'
tproxy_table='51820'
tproxy_priority='11000'
router_tproxy_priority='10999'
data_plane_canary_urls='https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204'
nft_table='ikev2_domain_router'

. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/devices.sh"
. "$runtime_lib_dir/controller.sh"
. "$runtime_lib_dir/tunnel.sh"
. "$runtime_lib_dir/routing.sh"
ucode_bin="${IKEV2_UCODE:-ucode}"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

getv() {
	uci -q get "$config.$1.$2" 2>/dev/null || true
}

defaultv() {
	value="$(getv "$1" "$2")"
	[ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$3"
}

write_status() {
	{
		[ -z "${ACTION_ID:-}" ] || printf 'action_id=%s\n' "$ACTION_ID"
		printf 'state=%s\n' "$1"
		printf 'updated=%s\n' "$(date +%s)"
		[ -z "${2:-}" ] || printf 'message=%s\n' "$2"
	} >"${state_file}.new"
	mv "${state_file}.new" "$state_file"
}

init_config() {
	uci -q get "$config.domains" >/dev/null 2>&1 || {
		uci set "$config.domains=domains"
		uci set "$config.domains.engine=nftset"
		uci set "$config.domains.fakeip_ttl=60"
		uci set "$config.domains.cache_capacity=8192"
		uci set "$config.domains.cache_path=/etc/ikev2-manager/domain-router-cache.db"
		uci set "$config.domains.log_level=warn"
		uci set "$config.domains.route_router_traffic=0"
		uci commit "$config"
	}
}

with_lock() {
	action="$1"
	shift
	lock_wait="${IKEV2_DOMAIN_LOCK_WAIT_SECONDS:-5}"
	case "$lock_wait" in '' | *[!0-9]*) lock_wait=5 ;; esac
	lock_tries=0
	while ! pid_lock_acquire "$lock_dir"; do
		# Periodic health work normally owns this lock for well under a second.
		# A bounded wait serializes a user transaction that starts in that narrow
		# window without hiding a genuinely stuck domain-router operation.
		[ "$lock_tries" -lt "$lock_wait" ] || {
			write_status error 'Another domain-routing action is already running'
			return 1
		}
		lock_tries=$((lock_tries + 1))
		sleep 1
	done
	trap 'pid_lock_release "$lock_dir"' EXIT INT TERM
	"$action" "$@"
	result=$?
	trap - EXIT INT TERM
	pid_lock_release "$lock_dir"
	return "$result"
}

json_array_file() {
	awk '
		BEGIN { printf "["; first = 1 }
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 == "" || substr($0, 1, 1) == "#")
				next
				if (!first)
					printf ","
				gsub(/\\/, "\\\\")
				gsub(/\"/, "\\\"")
				printf "\"%s\"", $0
			first = 0
		}
		END { printf "]" }
	' "$1"
}

validate_domain_file() {
	local file="$1" bytes count
	bytes="$(wc -c <"$file" | tr -d ' ')"
	count="$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$file")"
	[ "$bytes" -le 8388608 ] && [ "$count" -le 200000 ] || return 1
	awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			line = tolower($0)
			if (line == "" || substr(line, 1, 1) == "#") next
			if (length(line) > 253 || line !~ /^[a-z0-9._-]+$/ ||
			    line ~ /^\./ || line ~ /\.$/ || line ~ /\.\./) exit 1
			labels_count = split(line, labels, ".")
			for (i = 1; i <= labels_count; i++)
				if (length(labels[i]) < 1 || length(labels[i]) > 63 ||
				    labels[i] ~ /^-/ || labels[i] ~ /-$/) exit 1
		}
	' "$file"
}

json_array_words() {
	printf '%s\n' "$@" | awk '
		BEGIN { printf "["; first = 1 }
		NF {
			if (!first)
				printf ","
			printf "\"%s\"", $0
			first = 0
		}
		END { printf "]" }
	'
}

# Enabled DNS segments; their workers run only under managed DNS.
enabled_dns_segments() {
	local section
	[ "$(defaultv dns managed 0)" = 1 ] || return 0
	for section in $(uci show "$config" 2>/dev/null |
		sed -n "s/^${config}\.\([^.=]*\)=dns_segment\$/\1/p"); do
		[ "$(defaultv "$section" enabled 1)" = 1 ] && printf '%s\n' "$section"
	done
}

# Compatibility answers HTTPS queries itself, so it applies only to a segment
# whose queries pass through sing-box; a direct segment never reaches it.
dns_segment_https_suffixes() {
	local section suffix
	for section in $(enabled_dns_segments); do
		{ [ "$(defaultv "$section" via_singbox 0)" = 1 ] || foreign_servers_file; } &&
			[ "$(defaultv "$section" https_compat 1)" = 1 ] || continue
		for suffix in $(getv "$section" domains); do
			suffix="${suffix#.}"
			[ -n "$suffix" ] && printf '%s\n' "$suffix"
		done
	done | sort -u
}

# One "segment TAG PORT SUFFIX..." input line per enabled DNS segment, in UCI
# order: the generator adds its resolver and its routing rule.
dns_segment_inputs() {
	local section port domains suffix
	for section in $(enabled_dns_segments); do
		port="$(getv "$section" port)"
		case "$port" in '' | *[!0-9]*) die "Invalid DNS segment port: $section" ;; esac
		[ "$port" -ge 5550 ] && [ "$port" -le 5599 ] ||
			die "DNS segment port is outside the reserved range: $section"
		domains=''
		for suffix in $(getv "$section" domains); do
			suffix="${suffix#.}"
			[ -n "$suffix" ] || continue
			domains="$domains	$suffix"
		done
		[ -n "$domains" ] || die "DNS segment has no suffixes: $section"
		printf 'segment\tsegment-%s\t%s%s\n' "${section#dnsseg_}" "$port" "$domains"
	done
}

network_cidrs() {
	interface="$1"
	device="$(ubus call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(ubus call "network.interface.$interface" status 2>/dev/null |
			jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] || return 1
	ip -4 route show dev "$device" scope link 2>/dev/null |
		awk '$1 ~ /^[0-9.]+\/[0-9]+$/ { print $1 }' | sort -u
}

covered_sources() {
	local addresses address
	found=0
	for interface in $(uci -q get "$config.globals.source_interface" 2>/dev/null); do
		cidrs="$(network_cidrs "$interface")"
		[ -n "$cidrs" ] || {
			printf 'Protected network has no usable IPv4 subnet: %s\n' "$interface" >&2
			return 1
		}
		printf '%s\n' "$cidrs"
		found=1
	done
	if [ "$(defaultv globals source_include_vpn 1)" = 1 ] &&
	   [ "$(defaultv server enabled 0)" = 1 ]; then
		vpn_cidr="$(/usr/libexec/ikev2-manager-system gateway-network 2>/dev/null || true)"
		[ -n "$vpn_cidr" ] || {
			printf 'Inbound VPN source has no usable IPv4 subnet\n' >&2
			return 1
		}
		printf '%s\n' "$vpn_cidr"
		found=1
	fi
	# Devices routed by domain outside the covered networks, as policy routing
	# routes them. They used to be read from PBR's domain policy, which the
	# built-in routing removes, and were then answered by FakeIP but sent out
	# through the WAN.
	addresses="$(device_addresses domain)" || return 1
	for address in $addresses; do
		printf '%s\n' "$address"
		found=1
	done
	[ "$found" = 1 ]
}

excluded_sources() {
	device_addresses exclude
}

upstream_dns() {
	if [ "$(defaultv domains dns_saved 0)" = 1 ]; then
		servers="$(uci -q get "$config.domains.prev_server" 2>/dev/null || true)"
		noresolv="$(defaultv domains prev_noresolv 0)"
	else
		servers="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)"
		noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo 0)"
	fi
	for server in $servers; do
		case "$server" in
			/* | 127.0.0.1 | 127.0.0.1#53 | "$dns_address" | "$dns_address#$dns_port")
				continue
				;;
		esac
		host="${server%%#*}"
		port="${server#*#}"
		[ "$port" != "$server" ] || port=53
		if printf '%s\n' "$host" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' &&
		   printf '%s\n' "$port" | grep -Eq '^[0-9]+$'; then
			printf '%s %s\n' "$host" "$port"
			return 0
		fi
	done
	if [ "$noresolv" != 1 ]; then
		host="$(awk '$1 == "nameserver" && $2 ~ /^[0-9]+\./ { print $2; exit }' \
			/tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)"
		case "$host" in
			'' | 127.0.0.1 | "$dns_address") ;;
			*) printf '%s 53\n' "$host"; return 0 ;;
		esac
	fi
	die 'Unable to determine the DNS upstream used before FakeIP'
}

valid_dns_name() {
	awk -v value="$1" 'BEGIN {
		if (value == "" || length(value) > 253 || value !~ /^[A-Za-z0-9.-]+$/ ||
		    value ~ /^[0-9.]+$/) exit 1
		count = split(value, labels, ".")
		for (i = 1; i <= count; i++)
			if (labels[i] == "" || length(labels[i]) > 63 ||
			    labels[i] !~ /^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$/ &&
			    labels[i] !~ /^[A-Za-z0-9]$/) exit 1
	}'
}

parse_tunnel_doh() {
	local value="$1" authority host port path
	case "$value" in https://*/*) ;; *) return 1 ;; esac
	[ "${#value}" -le 2048 ] || return 1
	authority="${value#https://}"
	authority="${authority%%/*}"
	path="/${value#https://*/}"
	host="${authority%%:*}"
	port="${authority#*:}"
	[ "$port" != "$authority" ] || port=443
	valid_dns_name "$host" || return 1
	case "$port" in '' | *[!0-9]*) return 1 ;; esac
	[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
	printf '%s' "$path" | grep -Eq '^/[A-Za-z0-9._~:/?%+=,&;@-]+$' || return 1
	printf '%s\t%s\t%s\n' "$host" "$port" "$path"
}

tunnel_dns_endpoints() {
	defaultv client tunnel_dns_upstream \
		'https://dns.google/dns-query https://dns.cloudflare.com/dns-query'
}

tunnel_dns_bootstrap() {
	defaultv client tunnel_dns_bootstrap \
		'8.8.8.8:53 8.8.4.4:53 1.1.1.1:53 1.0.0.1:53'
}

validate_tunnel_dns() {
	local endpoint bootstrap host port count=0
	for endpoint in $(tunnel_dns_endpoints); do
		parse_tunnel_doh "$endpoint" >/dev/null || die "Invalid tunnel DNS endpoint: $endpoint"
		count=$((count + 1))
		[ "$count" -le 4 ] || die 'Too many tunnel DNS endpoints'
	done
	[ "$count" -gt 0 ] || die 'No tunnel DNS endpoints configured'
	count=0
	for bootstrap in $(tunnel_dns_bootstrap); do
		host="${bootstrap%:*}"
		port="${bootstrap##*:}"
		printf '%s' "$host" | awk -F. 'NF == 4 { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1; exit 0 } { exit 1 }' ||
			die "Invalid tunnel DNS bootstrap address: $bootstrap"
		[ "$port" = 53 ] || die 'Tunnel DNS bootstrap currently supports port 53 only'
		count=$((count + 1))
		[ "$count" -le 4 ] || die 'Too many tunnel DNS bootstrap servers'
	done
	[ "$count" -gt 0 ] || die 'No tunnel DNS bootstrap servers configured'
}

selected_tunnel_dns() {
	local selected endpoint configured
	selected="$(sed -n 's/^selected=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	configured="$(sed -n 's/^configured=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	[ "$configured" = "$(tunnel_dns_endpoints)" ] || selected=''
	for endpoint in $(tunnel_dns_endpoints); do
		[ -n "$selected" ] && [ "$endpoint" = "$selected" ] && {
			printf '%s\n' "$selected"
			return 0
		}
	done
	set -- $(tunnel_dns_endpoints)
	[ "$#" -gt 0 ] || return 1
	printf '%s\n' "$1"
}

selected_tunnel_bootstrap() {
	local selected configured bootstrap
	selected="$(sed -n 's/^bootstrap=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	configured="$(sed -n 's/^configured_bootstrap=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	[ "$configured" = "$(tunnel_dns_bootstrap)" ] || selected=''
	for bootstrap in $(tunnel_dns_bootstrap); do
		[ -n "$selected" ] && [ "$bootstrap" = "$selected" ] && {
			printf '%s\n' "$selected"
			return 0
		}
	done
	set -- $(tunnel_dns_bootstrap)
	[ "$#" -gt 0 ] || return 1
	printf '%s\n' "$1"
}

save_tunnel_dns_state() {
	local bootstrap="${3:-}" candidate="${4:-0}" switched_at="${5:-}" previous="${6:-}"
	[ -n "$bootstrap" ] || bootstrap="$(selected_tunnel_bootstrap)"
	[ -n "$switched_at" ] ||
		switched_at="$(sed -n 's/^switched_at=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	[ -n "$previous" ] ||
		previous="$(sed -n 's/^previous=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	{
		printf 'selected=%s\n' "$1"
		printf 'failures=%s\n' "$2"
		printf 'bootstrap=%s\n' "$bootstrap"
		printf 'candidate=%s\n' "$candidate"
		printf 'switched_at=%s\n' "${switched_at:-0}"
		printf 'previous=%s\n' "$previous"
		printf 'configured=%s\n' "$(tunnel_dns_endpoints)"
		printf 'configured_bootstrap=%s\n' "$(tunnel_dns_bootstrap)"
		printf 'updated=%s\n' "$(date +%s)"
	} >"${tunnel_dns_state}.new"
	mv "${tunnel_dns_state}.new" "$tunnel_dns_state"
}

local_devices() {
	ubus call network.interface dump 2>/dev/null |
		jsonfilter -e '@.interface[*].interface' 2>/dev/null |
		while IFS= read -r interface; do
			case "$interface" in
				'' | loopback | lo | wan | wan6 | ikev2out) continue ;;
			esac
			device="$(ubus call "network.interface.$interface" status 2>/dev/null |
				jsonfilter -e '@.l3_device' 2>/dev/null || true)"
			[ -n "$device" ] ||
				device="$(ubus call "network.interface.$interface" status 2>/dev/null |
					jsonfilter -e '@.device' 2>/dev/null || true)"
			[ -n "$device" ] && printf '%s\n' "$device"
		done
	[ "$(defaultv server enabled 0)" = 1 ] && printf 'ipsec-in\n'
}

# The names of exit $1 after the first, beside the first exit's list.
exit_domain_file() {
	printf '%s.exit-%s.txt\n' "${domain_file%.txt}" "$1"
}

# The rule set of exit $2 built from the first exit's rule set path $1.
exit_ruleset() {
	printf '%s.exit-%s.json\n' "${1%.json}" "$2"
}

# The TProxy port of the devices sent whole through exit $1 after the first:
# 1612 to 1617 for the tunnels, 1621 to 1627 for their exits without backup.
exit_tproxy_port() {
	case "$1" in
		*s) printf '%s\n' $((1620 + ${1%s})) ;;
		*) printf '%s\n' $((1610 + $1)) ;;
	esac
}

# The exits after the first with names of their own: one with a list, in the
# order they take precedence. Expects tunnel_settings_load.
named_exits() {
	local exit
	for exit in $tunnel_exit_order; do
		case " $tunnel_exits " in *" $exit "*) ;; *) continue ;; esac
		[ -e "$(exit_domain_file "$exit")" ] || continue
		printf '%s\n' "$exit"
	done
}

render_ruleset() {
	local exit list
	[ -f "$domain_file" ] || die 'Active domain list is missing'
	validate_domain_file "$domain_file" ||
		die 'Active domain list is invalid or exceeds resource limits'
	mkdir -p "${ruleset_file%/*}"
	domains="$(json_array_file "$domain_file")"
	printf '{"version":3,"rules":[{"domain_suffix":%s}]}\n' "$domains" \
		>"${ruleset_file}.new"
	chmod 600 "${ruleset_file}.new"
	mv "${ruleset_file}.new" "$ruleset_file"
	if bypass_listed; then
		validate_domain_file "$bypass_domain_file" ||
			die 'The list of domains never to route is invalid or exceeds resource limits'
		printf '{"version":3,"rules":[{"domain_suffix":%s}]}\n' \
			"$(json_array_file "$bypass_domain_file")" >"${bypass_ruleset_file}.new"
		chmod 600 "${bypass_ruleset_file}.new"
		mv "${bypass_ruleset_file}.new" "$bypass_ruleset_file"
	else
		rm -f "$bypass_ruleset_file"
	fi
	tunnel_settings_load
	for exit in $tunnel_exit_order; do
		list="$(exit_domain_file "$exit")"
		case " $(named_exits | tr '\n' ' ') " in
			*" $exit "*) ;;
			*) rm -f "$(exit_ruleset "$ruleset_file" "$exit")"; continue ;;
		esac
		validate_domain_file "$list" ||
			die "The domain list of tunnel $exit is invalid or exceeds resource limits"
		printf '{"version":3,"rules":[{"domain_suffix":%s}]}\n' "$(json_array_file "$list")" \
			>"$(exit_ruleset "$ruleset_file" "$exit").new"
		chmod 600 "$(exit_ruleset "$ruleset_file" "$exit").new"
		mv "$(exit_ruleset "$ruleset_file" "$exit").new" "$(exit_ruleset "$ruleset_file" "$exit")"
	done
}

# Whether any domain is never to go through the tunnel.
bypass_listed() {
	grep -q '^[[:space:]]*[^#[:space:]]' "$bypass_domain_file" 2>/dev/null
}

# The enabled tunnels for the generator and, with more than one, the tunnels
# each exit may use. Expects tunnel_settings_load.
tunnel_inputs() {
	local index exit
	for index in $tunnel_on; do
		tunnel_names "$index"
		printf 'tunnel\t%s\t%s\n' "$index" "$tunnel_link"
	done
	for exit in $tunnel_exits; do
		tunnel_exit_chain "$exit"
		[ -n "$tunnel_chain" ] || continue
		printf 'exit\t%s\t%s\n' "$exit" "$(printf '%s' "$tunnel_chain" | tr ' ' '\t')"
	done
	for exit in $(named_exits); do
		printf 'exit_rules\t%s\t%s\n' "$exit" "$(exit_ruleset "${ruleset_ref:-$ruleset_file}" "$exit")"
	done
	# Every configured exit has its devices' inbound, so a device moved
	# between exits changes nftables only.
	for exit in $tunnel_exits; do
		[ "$exit" != 1 ] || continue
		printf 'exit_port\t%s\t%s\n' "$exit" "$(exit_tproxy_port "$exit")"
	done
}

# The link the first exit routes into now: the tunnel the watcher chose, or
# with no choice yet the first one its chain prefers; ipsec-out when no tunnel
# is enabled.
first_exit_link() {
	local chosen
	tunnel_settings_load
	chosen="$(tunnel_exit_selected 1 2>/dev/null || echo 0)"
	if [ "$chosen" = 0 ]; then
		tunnel_exit_chain 1
		chosen="${tunnel_chain%% *}"
	fi
	tunnel_names "${chosen:-1}"
	printf '%s\n' "$tunnel_link"
}

# The outbound a page fetch through the first exit is asked of: its selector
# when there is one, the single tunnel outbound otherwise.
first_exit_outbound() {
	if [ "$(jsonfilter -i "$config_file" -e '@.outbounds[@.tag="exit-1"].type' 2>/dev/null)" = selector ]; then
		printf 'exit-1\n'
	else
		printf 'ikev2-out\n'
	fi
}

# Put every exit selector of the running resolver on the tunnel the watcher
# chose for it. An exit with no tunnel up keeps its selector where it is: the
# routing table refuses that exit's traffic, and the selector's tunnel has no
# SA to carry it. Fails when the controller did not take a choice, so the
# watcher tries again.
exits_apply() (
	local work kind exit chosen rc=0
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	[ -s "$config_file" ] || return 0
	tunnel_settings_load
	work="$(mktemp -d)" || return 1
	trap 'rm -rf "$work"' EXIT
	trap 'exit 1' INT TERM
	for exit in $tunnel_list; do
		[ "$(jsonfilter -i "$config_file" -e "@.outbounds[@.tag=\"exit-$exit\"].type" 2>/dev/null)" = selector ] ||
			continue
		chosen="$(tunnel_exit_selected "$exit" 2>/dev/null || echo 0)"
		[ "$chosen" != 0 ] || continue
		[ -s "$work/curl.conf" ] || controller_curl_config "$work" || return 1
		tunnel_names "$chosen"
		kind="ikev2-out"
		[ "$chosen" = 1 ] || kind="ikev2-out-$chosen"
		curl -4fsS --noproxy '*' --connect-timeout 2 --max-time 5 \
			--config "$work/curl.conf" -X PUT -H 'Content-Type: application/json' \
			--data "{\"name\":\"$kind\"}" \
			"http://$controller_address/proxies/exit-$exit" >/dev/null 2>&1 || rc=1
	done
	return "$rc"
)

render_config() {
	render_ruleset
	mkdir -p "$work_dir"
	ttl="$(defaultv domains fakeip_ttl 60)"
	cache_capacity="$(defaultv domains cache_capacity 8192)"
	case "$cache_capacity" in '' | *[!0-9]*) die 'Invalid DNS cache capacity' ;; esac
	[ "$cache_capacity" -ge 1024 ] && [ "$cache_capacity" -le 65536 ] ||
		die 'DNS cache capacity must be between 1024 and 65536 entries'
	log_level="$(defaultv domains log_level warn)"
	case "$log_level" in trace | debug | info | warn | error | fatal | panic) ;;
		*) die 'Invalid FakeIP log level' ;;
	esac
	cache_path="$(defaultv domains cache_path /etc/ikev2-manager/domain-router-cache.db)"
	upstream="$(upstream_dns)" || return 1
	set -- $upstream
	upstream_host="$1"
	upstream_port="$2"
	validate_tunnel_dns
	tunnel_dns="$(selected_tunnel_dns)" || die 'Unable to select tunnel DNS endpoint'
	IFS="$(printf '\t')" read -r tunnel_dns_host tunnel_dns_port tunnel_dns_path <<EOF
$(parse_tunnel_doh "$tunnel_dns")
EOF
	tunnel_bootstrap="$(selected_tunnel_bootstrap)" || die 'Unable to select tunnel DNS bootstrap'
	tunnel_bootstrap_host="${tunnel_bootstrap%:*}"
	tunnel_bootstrap_port="${tunnel_bootstrap##*:}"
	covered_file="$(mktemp)"
	excluded_file="$(mktemp)"
	if ! covered_sources >"$covered_file"; then
		rm -f "$covered_file" "$excluded_file"
		return 1
	fi
	# A rejected device configuration must not degrade into an empty exclusion
	# list: that would quietly pull an excluded device back into the tunnel.
	if ! excluded_sources >"$excluded_file"; then
		rm -f "$covered_file" "$excluded_file"
		return 1
	fi
	# Ordinary names are resolved over WAN, where per-protocol DNS filtering is
	# applied. Sending them through the tunnel-bound resolver instead removes
	# that exposure, but couples every lookup to tunnel health: while the tunnel
	# is down no name resolves at all. It is therefore opt-in, and only honoured
	# while the outbound client is actually enabled.
	tunnel_settings_load
	final_server=upstream
	if [ "$(defaultv dns tunnel_resolve 0)" = 1 ] && [ -n "$tunnel_on" ]; then
		final_server=ikev2-upstream
	fi

	# The loopback controller closes only the selected device's existing proxy
	# sessions. Keep its credential stable across resolver refreshes.
	local controller_secret input
	controller_secret="$(jsonfilter -i "$config_file" -e '@.experimental.clash_api.secret' 2>/dev/null || true)"
	printf '%s' "$controller_secret" | grep -Eq '^[0-9a-f]{64}$' ||
		controller_secret="$(openssl rand -hex 32)" || return 1
	input="$(mktemp)" || return 1
	{
		printf '%s\t%s\n' \
			log_level "$log_level" \
			ttl "$ttl" \
			cache_capacity "$cache_capacity" \
			cache_path "$cache_path" \
			upstream_host "$upstream_host" \
			upstream_port "$upstream_port" \
			bootstrap_host "$tunnel_bootstrap_host" \
			bootstrap_port "$tunnel_bootstrap_port" \
			doh_host "$tunnel_dns_host" \
			doh_port "$tunnel_dns_port" \
			doh_path "$tunnel_dns_path" \
			fakeip_range "$fakeip_range" \
			final_server "$final_server" \
			dns_address "$dns_address" \
			dns_port "$dns_port" \
			tproxy_address "$tproxy_address" \
			tproxy_port "$tproxy_port" \
			direct_tproxy_port "$direct_tproxy_port" \
			router_tproxy_port "$router_tproxy_port" \
			controller_address "$controller_address" \
			controller_secret "$controller_secret" \
			ruleset_path "${ruleset_ref:-$ruleset_file}"
		! bypass_listed ||
			printf 'bypass_ruleset_path\t%s\n' "${bypass_ruleset_ref:-$bypass_ruleset_file}"
		sort -u "$covered_file" | awk 'NF { printf "covered\t%s\n", $1 }'
		dns_segment_https_suffixes | awk 'NF { printf "https_suffix\t%s\n", $1 }'
		dns_segment_inputs
		tunnel_inputs
		# The same answer for every ordinary name, when they pass through here.
		{ ordinary_via_singbox || foreign_servers_file; } &&
			[ "$(defaultv dns https_compat 0)" = 1 ] && printf 'https_all\t1\n'
		:
	} >"$input" || {
		rm -f "$input" "$covered_file" "$excluded_file"
		return 1
	}
	rm -f "$covered_file" "$excluded_file"
	grep -q '^covered	' "$input" || {
		rm -f "$input"
		die 'No source networks are enabled for domain routing'
	}
	if ! "$ucode_bin" "$runtime_lib_dir/singbox-config.uc" render <"$input" >"${config_file}.new"; then
		rm -f "$input" "${config_file}.new"
		die 'Unable to generate the FakeIP configuration'
	fi
	rm -f "$input"
	chmod 600 "${config_file}.new"
	mv "${config_file}.new" "$config_file"
}

check_config() {
	command -v sing-box >/dev/null 2>&1 || die 'sing-box is not installed'
	# A configuration that could not be written must not pass on the strength
	# of the one already there, which sing-box accepts.
	render_config || return 1
	sing-box check -c "$config_file"
}

backup_generated() {
	backup_dir="$1"
	mkdir -p "$backup_dir"
	[ -s "$config_file" ] && cp "$config_file" "$backup_dir/config.json"
	[ -s "$ruleset_file" ] && cp "$ruleset_file" "$backup_dir/rules.json"
	[ ! -s "$bypass_ruleset_file" ] || cp "$bypass_ruleset_file" "$backup_dir/bypass.json"
	# The rule sets of the other exits, which the configuration names: one put
	# back without its file would keep sing-box from starting.
	local exit
	for exit in $tunnel_exit_order; do
		[ ! -s "$(exit_ruleset "$ruleset_file" "$exit")" ] ||
			cp "$(exit_ruleset "$ruleset_file" "$exit")" "$backup_dir/rules.exit-$exit.json"
	done
}

restore_generated() {
	backup_dir="$1"
	if [ -s "$backup_dir/config.json" ]; then
		cp "$backup_dir/config.json" "${config_file}.restore"
		mv "${config_file}.restore" "$config_file"
	fi
	if [ -s "$backup_dir/rules.json" ]; then
		cp "$backup_dir/rules.json" "${ruleset_file}.restore"
		mv "${ruleset_file}.restore" "$ruleset_file"
	fi
	if [ -s "$backup_dir/bypass.json" ]; then
		cp "$backup_dir/bypass.json" "${bypass_ruleset_file}.restore"
		mv "${bypass_ruleset_file}.restore" "$bypass_ruleset_file"
	fi
	local exit list
	for exit in $tunnel_exit_order; do
		[ -s "$backup_dir/rules.exit-$exit.json" ] || continue
		list="$(exit_ruleset "$ruleset_file" "$exit")"
		cp "$backup_dir/rules.exit-$exit.json" "$list.restore"
		mv "$list.restore" "$list"
	done
}

snapshot_generated() {
	local destination="$1"
	case "$destination" in
		/tmp/ikev2-manager-dns-rollback-*/domain-router | /tmp/ikev2-manager-dns-disable-rollback-*/domain-router) ;;
		*) return 1 ;;
	esac
	[ ! -L "$destination" ] || return 1
	rm -rf "$destination"
	sing-box check -c "$config_file" >/dev/null 2>&1 || return 1
	backup_generated "$destination"
	[ -s "$destination/config.json" ] && [ -s "$destination/rules.json" ] || return 1
	cp "$destination/config.json" "$destination/config.verified" || return 1
	cp "$destination/rules.json" "$destination/rules.verified" || return 1
}

restore_generated_snapshot() {
	local source="$1"
	case "$source" in
		/tmp/ikev2-manager-dns-rollback-*/domain-router | /tmp/ikev2-manager-dns-disable-rollback-*/domain-router) ;;
		*) return 1 ;;
	esac
	[ -d "$source" ] && [ ! -L "$source" ] || return 1
	[ -s "$source/config.json" ] && [ -s "$source/rules.json" ] &&
		[ -s "$source/config.verified" ] && [ -s "$source/rules.verified" ] || return 1
	cmp -s "$source/config.json" "$source/config.verified" || return 1
	cmp -s "$source/rules.json" "$source/rules.verified" || return 1
	restore_generated "$source"
	/etc/init.d/ikev2-domain-router restart >/dev/null 2>&1 || return 1
	wait_for_dns && validate_dns_server "$dns_address" &&
		sync_dnsmasq reload && wait_for_query 127.0.0.1 && runtime_healthy
}

routing_slot_available() {
	local foreign routes
	foreign="$(ip -4 rule show 2>/dev/null | awk \
		-v priority="${tproxy_priority}:" \
		-v router_priority="${router_tproxy_priority}:" \
		-v destination="to $fakeip_range" \
		-v legacy_mark="fwmark $tproxy_mark/$tproxy_mask" \
		-v table="$tproxy_table" '
		$1 == priority || $1 == router_priority || index($0, "lookup " table) {
			owned = $1 == priority && index($0, "lookup " table) &&
				(index($0, destination) || index($0, legacy_mark))
			router_owned = $1 == router_priority &&
				index($0, destination) && index($0, legacy_mark) &&
				index($0, "iif lo") && index($0, "lookup " table)
			if (!owned && !router_owned) print
		}')"
	[ -z "$foreign" ] || return 1
	routes="$(ip -4 route show table "$tproxy_table" 2>/dev/null || true)"
	printf '%s\n' "$routes" | awk '
		NF && !($1 == "local" && ($2 == "default" || $2 == "0.0.0.0/0") &&
		        $3 == "dev" && $4 == "lo") { bad = 1 }
		END { exit bad }
	'
}

nft_slot_available() {
	local state
	state="$(nft list table inet "$nft_table" 2>/dev/null || true)"
	[ -n "$state" ] || return 0
	printf '%s\n' "$state" | grep -Fq 'set local_devices' || return 1
	printf '%s\n' "$state" | grep -Fq "$fakeip_range" || return 1
	printf '%s\n' "$state" | grep -Fq ":$tproxy_port" || return 1
}

delete_local_tproxy_route() {
	local table="$1"
	while ip -4 route del local 0.0.0.0/0 dev lo table "$table" \
		2>/dev/null; do :; done
	while ip -4 route del local default dev lo table "$table" \
		2>/dev/null; do :; done
}

nft_stop() {
	nft delete table inet "$nft_table" >/dev/null 2>&1 || true
	while ip -4 rule del iif lo fwmark "$tproxy_mark/$tproxy_mask" \
		to "$fakeip_range" table "$tproxy_table" \
		priority "$router_tproxy_priority" 2>/dev/null; do :; done
	while ip -4 rule del to "$fakeip_range" \
		table "$tproxy_table" priority "$tproxy_priority" 2>/dev/null; do :; done
	# Remove the fwmark selector used by earlier releases. Tailscale 1.98 enables
	# src_valid_mark globally, which makes reverse-path validation reuse this
	# otherwise unrelated table and silently reject LAN sources.
	while ip -4 rule del fwmark "$tproxy_mark/$tproxy_mask" \
		table "$tproxy_table" priority "$tproxy_priority" 2>/dev/null; do :; done
	delete_local_tproxy_route "$tproxy_table"
	# Remove the exact route/rule used by releases before 1.1. No table flush is
	# used, so unrelated routes in the legacy numeric table remain untouched.
	while ip -4 rule del fwmark "$tproxy_mark/$tproxy_mask" \
		table 100 priority 100 2>/dev/null; do :; done
	delete_local_tproxy_route 100
}

listener_ready() {
	netstat -ln 2>/dev/null | grep -Fq "$1:$2"
}

# All four resolver and TProxy listeners, from one socket listing. The status
# page, the widget and doctor each ask for health; four netstat runs per ask
# were a measurable part of the overview page's wait.
# sing-box listens on everything its configuration gives it: the resolver,
# the three inbounds every configuration has, and the inbound of each exit the
# file on disk holds. Read from that file and not from the settings: a tunnel
# saved but not applied has no inbound in it, a restart brings up only what
# the file declares, and the watcher, missing the listener the settings asked
# for, restarted the resolver on every pass and cut every routed connection
# each time.
listeners_ready() {
	local sockets listener port ports=''
	sockets="$(netstat -ln 2>/dev/null)" || return 1
	for port in $(jsonfilter -i "$config_file" -e '@.inbounds[*].listen_port' 2>/dev/null); do
		case "$port" in
			"$dns_port" | "$tproxy_port" | "$direct_tproxy_port" | "$router_tproxy_port") ;;
			*[!0-9]*) ;;
			*) ports="$ports $tproxy_address:$port" ;;
		esac
	done
	for listener in "$dns_address:$dns_port" "$tproxy_address:$tproxy_port" \
		"$tproxy_address:$direct_tproxy_port" "$tproxy_address:$router_tproxy_port" $ports; do
		case "$sockets" in *"$listener"*) ;; *) return 1 ;; esac
	done
}

tproxy_rules_ready() {
	local rules device
	rules="$(ip -4 rule show)"
	for device in $(local_devices | sort -u); do
		printf '%s\n' "$rules" |
			grep -Fq "to $fakeip_range iif $device lookup $tproxy_table" || return 1
	done
	if [ "$(defaultv domains route_router_traffic 0)" = 1 ]; then
		printf '%s\n' "$rules" |
			grep -Fq "to $fakeip_range fwmark $tproxy_mark/$tproxy_mask iif lo lookup $tproxy_table" || return 1
	fi
}

nft_runtime_ready() {
	local prerouting output
	# Read each chain once and test the listing, not one nft run per property.
	prerouting="$(nft list chain inet "$nft_table" prerouting 2>/dev/null)" || return 1
	output="$(nft list chain inet "$nft_table" output 2>/dev/null)" || output=''
	case "$prerouting" in *"$fakeip_range"*) ;; *) return 1 ;; esac
	case "$prerouting" in *"$direct_tproxy_mark"*) ;; *) return 1 ;; esac
	if [ "$(defaultv domains route_router_traffic 0)" = 1 ]; then
		case "$prerouting" in *":$router_tproxy_port"*) ;; *) return 1 ;; esac
		case "$output" in *"$router_tproxy_mark"*) ;; *) return 1 ;; esac
	else
		case "$output" in *"$fakeip_range"*) return 1 ;; esac
	fi
	tproxy_rules_ready || return 1
	ip -4 route show table "$tproxy_table" 2>/dev/null |
		grep -Eq '^local (default|0\.0\.0\.0/0) dev lo( |$)'
}

nft_start() {
	devices="$(local_devices | sort -u)"
	[ -n "$devices" ] || die 'No local interfaces found for FakeIP interception'
	routing_slot_available || die "TProxy routing table $tproxy_table or priority $tproxy_priority is already in use"
	nft_slot_available || die "nft table '$nft_table' exists but is not owned by IKEv2 Manager"
	nft_stop
	device_set="$(json_array_words $devices | tr '[]' '{}')"
	output_rules=''
	if [ "$(defaultv domains route_router_traffic 0)" = 1 ]; then
		output_rules="
    ip daddr $fakeip_range meta l4proto tcp meta mark set $router_tproxy_mark counter
    ip daddr $fakeip_range meta l4proto udp meta mark set $router_tproxy_mark counter"
	fi

	if ! nft -f - <<EOF
table inet $nft_table {
  set local_devices {
    type ifname
    elements = $device_set
  }

  chain prerouting {
    type filter hook prerouting priority -151; policy accept;
    meta mark == $direct_tproxy_mark return
    meta mark == $router_tproxy_mark meta l4proto tcp tproxy ip to $tproxy_address:$router_tproxy_port counter accept
    meta mark == $router_tproxy_mark meta l4proto udp tproxy ip to $tproxy_address:$router_tproxy_port counter accept
    meta mark & $tproxy_mask == $tproxy_mark meta l4proto tcp tproxy ip to $tproxy_address:$tproxy_port counter accept
    meta mark & $tproxy_mask == $tproxy_mark meta l4proto udp tproxy ip to $tproxy_address:$tproxy_port counter accept
    iifname @local_devices ip daddr $fakeip_range meta l4proto tcp meta mark set $tproxy_mark tproxy ip to $tproxy_address:$tproxy_port counter accept
    iifname @local_devices ip daddr $fakeip_range meta l4proto udp meta mark set $tproxy_mark tproxy ip to $tproxy_address:$tproxy_port counter accept
  }

  chain output {
    type route hook output priority -151; policy accept;
$output_rules
  }
}
EOF
	then
		nft_stop
		return 1
	fi
	if ! ip -4 route replace local 0.0.0.0/0 dev lo table "$tproxy_table"; then
		nft_stop
		return 1
	fi
	for device in $devices; do
		if ! ip -4 rule add iif "$device" to "$fakeip_range" \
			table "$tproxy_table" priority "$tproxy_priority"; then
			nft_stop
			return 1
		fi
	done
	if [ "$(defaultv domains route_router_traffic 0)" = 1 ] &&
	   ! ip -4 rule add iif lo fwmark "$tproxy_mark/$tproxy_mask" \
		to "$fakeip_range" table "$tproxy_table" \
		priority "$router_tproxy_priority"; then
		nft_stop
		return 1
	fi
	if ! nft_runtime_ready; then
		nft_stop
		return 1
	fi
}

# Opt-in: resolve ordinary names through the tunnel-bound resolver instead of
# the WAN one. The change is validated the same way the router-traffic policy
# is, and rolled back when the refreshed runtime does not resolve, because a bad
# value here takes DNS away from every client at once.
set_tunnel_resolve() {
	value="${1:-}"
	case "$value" in 0 | 1) ;; *) die 'Expected tunnel resolve value: 0 or 1' ;; esac
	old="$(defaultv dns tunnel_resolve 0)"
	[ "$old" = "$value" ] && return 0
	[ "$value" = 0 ] || [ "$(defaultv client enabled 0)" = 1 ] ||
		die 'Enable the outbound tunnel before resolving ordinary names through it'
	uci set "$config.dns.tunnel_resolve=$value" &&
		uci commit "$config" || die 'Unable to save the tunnel resolution policy'
	if [ "$(defaultv domains engine nftset)" = fakeip ] &&
	   { ! refresh || ! runtime_healthy || ! wait_for_dns; }; then
		restored=1
		uci set "$config.dns.tunnel_resolve=$old" &&
			uci commit "$config" || restored=0
		[ "$restored" = 0 ] || refresh >/dev/null 2>&1 || restored=0
		[ "$restored" = 1 ] ||
			die 'Tunnel resolution failed and automatic rollback was incomplete'
		die 'Unable to apply tunnel resolution; previous setting restored'
	fi
}

set_router_traffic() {
	value="${1:-}"
	case "$value" in 0 | 1) ;; *) die 'Expected router traffic value: 0 or 1' ;; esac
	old="$(defaultv domains route_router_traffic 0)"
	[ "$old" = "$value" ] && return 0
	uci set "$config.domains.route_router_traffic=$value" &&
		uci commit "$config" || die 'Unable to save router-originated traffic policy'
	if [ "$(defaultv domains engine nftset)" = fakeip ] &&
	   { ! nft_start || ! runtime_healthy; }; then
		restored=1
		uci set "$config.domains.route_router_traffic=$old" &&
			uci commit "$config" || restored=0
		[ "$restored" = 0 ] || nft_start >/dev/null 2>&1 || restored=0
		[ "$restored" = 1 ] ||
			die 'Router-originated traffic policy failed and automatic rollback was incomplete'
		die 'Unable to apply router-originated traffic policy; previous setting restored'
	fi
}

set_log_level() {
	value="${1:-}"
	case "$value" in trace | debug | info | warn | error) ;;
		*) die 'Expected log level: trace, debug, info, warn or error' ;;
	esac
	old="$(defaultv domains log_level warn)"
	[ "$old" = "$value" ] && return 0
	uci set "$config.domains.log_level=$value" &&
		uci commit "$config" || die 'Unable to save FakeIP log level'
	if [ "$(defaultv domains engine nftset)" = fakeip ] && ! refresh; then
		restored=1
		uci set "$config.domains.log_level=$old" &&
			uci commit "$config" || restored=0
		[ "$restored" = 0 ] || refresh >/dev/null 2>&1 || restored=0
		[ "$restored" = 1 ] ||
			die 'FakeIP log level failed and automatic rollback was incomplete'
		die 'Unable to apply FakeIP log level; previous setting restored'
	fi
}

resolver_diagnostic_inner() {
	duration="$1"
	old="$(defaultv domains log_level warn)"
	restored=0
	restore_level() {
		[ "$restored" = 0 ] || return 0
		uci set "$config.domains.log_level=$old" || return 1
		uci commit "$config" || return 1
		refresh >/dev/null 2>&1 || return 1
		restored=1
	}
	trap 'restore_level >/dev/null 2>&1 || true' EXIT INT TERM HUP
	uci set "$config.domains.log_level=debug" || return 1
	uci commit "$config" || return 1
	if ! refresh; then
		restore_level >/dev/null 2>&1 || true
		return 1
	fi
	write_status running "FakeIP debug logging is active for $duration seconds"
	sleep "$duration"
	if ! restore_level; then
		write_status error 'Diagnostic ended, but the normal FakeIP log level could not be restored'
		return 1
	fi
	trap - EXIT INT TERM HUP
	write_status active "FakeIP diagnostic completed; log level restored to $old"
}

resolver_diagnostic() {
	duration="${1:-60}"
	case "$duration" in '' | *[!0-9]*) die 'Invalid diagnostic duration' ;; esac
	[ "$duration" -ge 30 ] && [ "$duration" -le 300 ] ||
		die 'Diagnostic duration must be 30-300 seconds'
	[ "$(defaultv domains engine nftset)" = fakeip ] ||
		die 'FakeIP diagnostics require Reliable mode'
	# Keep the restoration trap inside a subshell so it cannot replace the
	# outer action-lock trap maintained by with_lock().
	( resolver_diagnostic_inner "$duration" )
}

save_dnsmasq() {
	[ "$(defaultv domains dns_saved 0)" = 1 ] && return 0
	uci set "$config.domains.dns_saved=1"
	uci set "$config.domains.prev_noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo 0)"
	uci set "$config.domains.prev_cachesize=$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || echo 150)"
	uci -q delete "$config.domains.prev_server" || true
	for server in $(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null); do
		uci add_list "$config.domains.prev_server=$server"
	done
	uci commit "$config"
}

clear_dnsmasq_snapshot() {
	for option in dns_saved prev_noresolv prev_cachesize prev_server; do
		uci -q delete "$config.domains.$option" || true
	done
	uci commit "$config"
}

# Resolving ordinary names through the tunnel happens in sing-box, so it
# implies the sing-box path for them.
ordinary_via_singbox() {
	[ "$(defaultv dns via_singbox 0)" = 1 ] && return 0
	[ "$(defaultv dns tunnel_resolve 0)" = 1 ] &&
		[ "$(defaultv client enabled 0)" = 1 ]
}

# dnsmasq reads a single servers file. Another package's (an ad blocker's,
# say) is left in place, and every name then goes through sing-box, which is
# the only way left to reach FakeIP for the selected domains.
foreign_servers_file() {
	local current
	current="$(uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null || true)"
	[ -n "$current" ] && [ "$current" != "$dnsmasq_servers_file" ]
}

# How dnsmasq resolves in Reliable mode, as "server ENTRY" lines in order and
# then "noresolv" and "cachesize". Selected domains reach sing-box through the
# servers file. Ordinary names go straight to the resolver dnsmasq had before,
# with its cache, so a sing-box fault no longer takes every name with it; and
# each segment goes straight to its worker. Either can be sent through sing-box
# instead, which then holds the only cache.
dnsmasq_wanted() {
	local server section target decorated suffix
	if foreign_servers_file; then
		printf 'server %s\nnoresolv 1\ncachesize 0\n' "$dns_address"
		return 0
	fi
	if ordinary_via_singbox; then
		printf 'server %s\n' "$dns_address"
	else
		for server in $(uci -q get "$config.domains.prev_server" 2>/dev/null); do
			case "$server" in
				# Segment entries are built from the segments below.
				/*/127.0.0.1#55[5-9][0-9] | "$dns_address" | "$dns_address#$dns_port" | */"$dns_address")
					continue
					;;
			esac
			printf 'server %s\n' "$server"
		done
	fi
	for section in $(enabled_dns_segments); do
		target="127.0.0.1#$(getv "$section" port)"
		[ "$(defaultv "$section" via_singbox 0)" != 1 ] || target="$dns_address"
		decorated=''
		for suffix in $(getv "$section" domains); do
			decorated="$decorated/${suffix#.}"
		done
		[ -z "$decorated" ] || printf 'server %s/%s\n' "$decorated" "$target"
	done
	if ordinary_via_singbox; then
		printf 'noresolv 1\ncachesize 0\n'
	else
		printf 'noresolv %s\ncachesize %s\n' "$(defaultv domains prev_noresolv 0)" \
			"$(defaultv domains prev_cachesize 150)"
	fi
}

wanted_value() {
	printf '%s\n' "$1" | sed -n "s/^$2 //p"
}

# The selected domains, each answered by sing-box. Firefox's canary name is
# answered here, so Firefox keeps the router resolver, and with it FakeIP,
# instead of its own DoH even while sing-box is down.
render_dnsmasq_servers() {
	local exit
	printf 'server=/use-application-dns.net/\n'
	# The names of every exit get their FakeIP addresses from sing-box.
	tunnel_settings_load
	for exit in 1 $(named_exits); do
		awk -v target="$dns_address" '
			{ gsub(/\r/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
			$0 == "" || substr($0, 1, 1) == "#" { next }
			{ printf "server=/%s/%s\n", tolower($0), target }
		' "$([ "$exit" = 1 ] && printf '%s' "$domain_file" || exit_domain_file "$exit")"
	done
	# A domain never to go through the tunnel goes to dnsmasq's own
	# resolvers, "#", even inside a selected one: the longest name wins.
	[ ! -r "$bypass_domain_file" ] || awk '
		{ gsub(/\r/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
		$0 == "" || substr($0, 1, 1) == "#" { next }
		{ printf "server=/%s/#\n", tolower($0) }
	' "$bypass_domain_file"
}

# The file is bind-mounted into dnsmasq's jail, so it is rewritten in place: a
# file moved over it leaves dnsmasq reading the one it replaced.
write_dnsmasq_servers() {
	local candidate
	servers_changed=0
	validate_domain_file "$domain_file" || return 1
	candidate="$(mktemp)" || return 1
	if ! render_dnsmasq_servers >"$candidate"; then
		rm -f "$candidate"
		return 1
	fi
	if ! cmp -s "$candidate" "$dnsmasq_servers_file" 2>/dev/null; then
		if ! cat "$candidate" >"$dnsmasq_servers_file"; then
			rm -f "$candidate"
			return 1
		fi
		servers_changed=1
	fi
	rm -f "$candidate"
	chmod 644 "$dnsmasq_servers_file"
}

# Whether dnsmasq is configured the way dnsmasq_wanted says.
dnsmasq_matches() {
	local wanted current
	wanted="$(dnsmasq_wanted)" || return 1
	if foreign_servers_file; then :
	else
		[ -s "$dnsmasq_servers_file" ] &&
			[ "$(uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null)" = "$dnsmasq_servers_file" ] ||
			return 1
	fi
	current="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | tr ' ' '\n')"
	[ "$current" = "$(wanted_value "$wanted" server)" ] || return 1
	current="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)"
	[ "${current:-0}" = "$(wanted_value "$wanted" noresolv)" ] || return 1
	current="$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null)"
	[ "${current:-150}" = "$(wanted_value "$wanted" cachesize)" ]
}

# Bring dnsmasq to what dnsmasq_wanted says and have it read it; "reload"
# makes it read even when nothing changed, which a rollback needs after it put
# the DHCP file back under a running dnsmasq. A changed configuration restarts
# dnsmasq. A reload restarts it too when procd finds the generated
# configuration changed, and then also sends HUP, which reached the new jail
# before it could take it; otherwise the HUP alone rereads the servers file
# and empties the cache.
sync_dnsmasq() {
	local wanted server reload="${1:-}" restart=0
	save_dnsmasq
	if ! foreign_servers_file; then
		write_dnsmasq_servers || return 1
		[ "$servers_changed" = 0 ] || reload=reload
	fi
	if ! dnsmasq_matches; then
		wanted="$(dnsmasq_wanted)" || return 1
		uci -q delete dhcp.@dnsmasq[0].server || true
		for server in $(wanted_value "$wanted" server); do
			uci add_list "dhcp.@dnsmasq[0].server=$server" || return 1
		done
		uci set "dhcp.@dnsmasq[0].noresolv=$(wanted_value "$wanted" noresolv)" &&
			uci set "dhcp.@dnsmasq[0].cachesize=$(wanted_value "$wanted" cachesize)" ||
			return 1
		foreign_servers_file ||
			uci set "dhcp.@dnsmasq[0].serversfile=$dnsmasq_servers_file" || return 1
		uci commit dhcp || return 1
		restart=1
	fi
	if [ "$restart" = 1 ] || ! /etc/init.d/dnsmasq running >/dev/null 2>&1; then
		/etc/init.d/dnsmasq restart
	elif [ "$reload" = reload ]; then
		/etc/init.d/dnsmasq reload
	fi
}

use_fakeip_dns() {
	sync_dnsmasq reload
}

restore_dnsmasq() {
	local own=0
	[ "$(uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null)" != "$dnsmasq_servers_file" ] || own=1
	if [ "$(defaultv domains dns_saved 0)" != 1 ]; then
		if [ "$own" = 1 ]; then
			uci -q delete dhcp.@dnsmasq[0].serversfile || true
			uci commit dhcp
			/etc/init.d/dnsmasq restart
		fi
		rm -f "$dnsmasq_servers_file"
		return 0
	fi
	uci set "dhcp.@dnsmasq[0].noresolv=$(defaultv domains prev_noresolv 0)"
	uci set "dhcp.@dnsmasq[0].cachesize=$(defaultv domains prev_cachesize 150)"
	uci -q delete dhcp.@dnsmasq[0].server || true
	for server in $(uci -q get "$config.domains.prev_server" 2>/dev/null); do
		uci add_list "dhcp.@dnsmasq[0].server=$server"
	done
	[ "$own" = 0 ] || uci -q delete dhcp.@dnsmasq[0].serversfile || true
	uci commit dhcp
	/etc/init.d/dnsmasq restart
	clear_dnsmasq_snapshot
	# Only once dnsmasq no longer reads it.
	rm -f "$dnsmasq_servers_file"
}

is_fakeip() {
	printf '%s\n' "$1" | grep -Eq '^198\.(18|19)\.'
}

lookup_address() {
	bounded_nslookup "$1" "$2" |
		sed -n 's/^Address[^:]*:[[:space:]]*//p' |
		grep -E '^[0-9]+\.' | tail -n1
}

selected_test_domain() {
	sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; { s/[[:space:]]//g; p; q; }' \
		"$domain_file"
}

wait_for_dns() {
	tries=0
	while [ "$tries" -lt 15 ]; do
		if listener_ready "$dns_address" "$dns_port"; then
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

# Callers test the result and roll back on failure, so this reports and returns
# instead of exiting: an exit here skipped every rollback that followed it.
validate_dns_server() {
	local server="${1:-$dns_address}" selected selected_ip control control_ip tries
	selected="$(selected_test_domain)"
	if [ -n "$selected" ]; then
		# A resolver that has just started can answer before it has loaded the
		# selected domains: switching back from matching by address failed on
		# the first try with a real address and passed on the second. It gets
		# a few seconds to settle before the switch is refused.
		tries=0
		while :; do
			selected_ip="$(lookup_address "$selected" "$server")"
			is_fakeip "$selected_ip" && break
			tries=$((tries + 1))
			[ "$tries" -lt 5 ] || break
			sleep 1
		done
		is_fakeip "$selected_ip" || {
			printf 'Selected domain did not receive FakeIP: %s -> %s\n' \
				"$selected" "${selected_ip:-none}" >&2
			return 1
		}
	fi
	# Any probe name outside the list proves ordinary names still resolve for
	# real; one unreachable name no longer fails the whole resolver.
	for control in $dns_probe_names; do
		grep -qx "$control" "$domain_file" 2>/dev/null && continue
		control_ip="$(lookup_address "$control" "$server")"
		[ -n "$control_ip" ] && ! is_fakeip "$control_ip" && return 0
	done
	printf 'No control domain received a real address from %s\n' "$server" >&2
	return 1
}

# Print one domain the current rule-set adds over the rule-set file OLD.
# A domain the rule set NEW has and OLD, which may be absent, has not.
added_rule_domain() (
	local old="$1" new="${2:-$ruleset_file}" work
	work="$(mktemp -d)" || return 1
	trap 'rm -rf "$work"' EXIT
	: >"$work/old"
	[ ! -e "$old" ] ||
		jsonfilter -i "$old" -e '@.rules[*].domain_suffix[*]' >"$work/old" 2>/dev/null || :
	jsonfilter -i "$new" -e '@.rules[*].domain_suffix[*]' >"$work/new" 2>/dev/null ||
		return 1
	# Not "grep -vxFf": with OLD absent the pattern file is empty, which
	# BusyBox grep takes to match every line, so nothing was ever new.
	awk -v old="$work/old" '
		BEGIN { while ((getline line <old) > 0) seen[line] = 1 }
		!($0 in seen) { print; exit }
	' "$work/new"
)

# The rule set file of exit $1: the first exit's, or one beside it.
exit_rules_file() {
	if [ "$1" = 1 ]; then
		printf '%s\n' "$ruleset_file"
	else
		exit_ruleset "$ruleset_file" "$1"
	fi
}

runtime_healthy() {
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 1
	/etc/init.d/ikev2-domain-router running >/dev/null 2>&1 || return 1
	listeners_ready || return 1
	dnsmasq_matches || return 1
	nft_runtime_ready
}

wait_for_query() {
	wait_for_router_dns "$1" 15
}

repair_runtime() {
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	if ! /etc/init.d/ikev2-domain-router running >/dev/null 2>&1 ||
	   ! listeners_ready; then
		/etc/init.d/ikev2-domain-router restart
		wait_for_dns || return 1
	fi
	validate_dns_server "$dns_address" || return 1
	if ! nft_runtime_ready; then
		nft_start || return 1
	fi
	if ! dnsmasq_matches; then
		# A cutover that does not answer is undone: dnsmasq goes back to the
		# resolver it had. The chosen mode is never changed from here; switching
		# is the operator's decision alone.
		if ! use_fakeip_dns ||
		   ! wait_for_query 127.0.0.1 ||
		   ! validate_dns_server 127.0.0.1; then
			if ! internet_dns_reachable; then
				write_status error 'The Internet is unreachable; reliable mode is kept and checked again'
				return 1
			fi
			restore_dnsmasq || :
			write_status error 'The FakeIP resolver does not answer; DNS was left on the previous resolver and selected domains are not routed until it is fixed'
			return 1
		fi
	fi
	runtime_healthy || return 1
	write_status active 'FakeIP runtime repaired'
}

ensure_runtime() {
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	runtime_healthy && return 0
	pid_lock_busy "$lock_dir" && return 0
	with_lock repair_runtime
}

bounded_nslookup() {
	local query_pid watchdog_pid sleeper_pid='' rc=0

	# OpenWrt's BusyBox build does not necessarily include the timeout applet.
	# Keep the health loop bounded without adding another runtime dependency.
	nslookup "$@" 2>/dev/null &
	query_pid=$!
	(
		trap '[ -z "$sleeper_pid" ] || kill "$sleeper_pid" 2>/dev/null; exit 0' TERM INT
		sleep 2 &
		sleeper_pid=$!
		wait "$sleeper_pid" 2>/dev/null || exit 0
		kill "$query_pid" 2>/dev/null || :
	) >/dev/null 2>&1 &
	watchdog_pid=$!
	wait "$query_pid" 2>/dev/null || rc=$?
	kill "$watchdog_pid" 2>/dev/null || :
	wait "$watchdog_pid" 2>/dev/null || :
	return "$rc"
}

# Run the same DNS transport as the live resolver, without its cache or routing
# listeners. This proves a DNS answer, not merely a successful TLS exchange.
tunnel_dns_query() (
	local endpoint="$1" bootstrap="$2" link="${3:-ipsec-out}" host port path parsed work worker='' attempt=0
	local address="${IKEV2_DNS_PROBE_ADDRESS:-127.0.0.44}"
	parsed="$(parse_tunnel_doh "$endpoint")" || return 1
	IFS="$(printf '\t')" read -r host port path <<EOF
$parsed
EOF
	listener_ready "$address" 53 && return 1
	work="$(mktemp -d)" || return 1
	cleanup_dns_probe() {
		if [ -n "$worker" ]; then
			kill "$worker" 2>/dev/null || true
			# A stuck worker must not hold the DNS action lock indefinitely.
			(sleep 2; kill -KILL "$worker" 2>/dev/null) &
			local reaper=$!
			wait "$worker" 2>/dev/null || true
			kill "$reaper" 2>/dev/null || true
			wait "$reaper" 2>/dev/null || true
		fi
		rm -rf "$work"
	}
	trap cleanup_dns_probe EXIT
	trap 'exit 1' INT TERM
	printf '%s\t%s\n' \
		bootstrap_host "${bootstrap%:*}" bootstrap_port "${bootstrap##*:}" \
		doh_host "$host" doh_port "$port" doh_path "$path" dns_address "$address" \
		link "$link" |
		"$ucode_bin" "$runtime_lib_dir/singbox-config.uc" probe >"$work/config.json" || return 1
	chmod 600 "$work/config.json"
	"${IKEV2_SING_BOX:-/usr/bin/sing-box}" run -c "$work/config.json" -D "$work" >"$work/log" 2>&1 &
	worker=$!
	while ! listener_ready "$address" 53; do
		kill -0 "$worker" 2>/dev/null || return 1
		[ "$attempt" -lt 3 ] || return 1
		attempt=$((attempt + 1))
		sleep 1
	done
	kill -0 "$worker" 2>/dev/null || return 1
	dns_probe_answers "$address"
)

probe_tunnel_dns() {
	local endpoint="$1" bootstrap preferred attempted_bootstraps='' link
	probe_bootstrap=''
	link="$(first_exit_link)"
	preferred="$(selected_tunnel_bootstrap)"
	# First prove the bootstrap that the running configuration actually uses.
	for bootstrap in "$preferred" $(tunnel_dns_bootstrap); do
		[ -n "$bootstrap" ] || continue
		case " $attempted_bootstraps " in *" $bootstrap "*) continue ;; esac
		attempted_bootstraps="${attempted_bootstraps:+$attempted_bootstraps }$bootstrap"
		if tunnel_dns_query "$endpoint" "$bootstrap" "$link"; then
			probe_bootstrap="$bootstrap"
			return 0
		fi
	done
	return 1
}

probe_tunnel_data_plane() {
	# An alternate resolver can answer during a generally unstable tunnel.  A
	# provider switch is disruptive because sing-box must reload, so first prove
	# that unrelated HTTPS traffic also crosses the tunnel successfully.
	tunnel_https_reachable 2 3 "$(first_exit_link)"
}

rendered_tunnel_dns() {
	local field value line='' tab suffix=''
	tab="$(printf '\t')"
	[ -s "$config_file" ] || return 1
	# Every tunnel resolver uses the same endpoint; with the first tunnel
	# disabled its pair is absent and the next one's is read.
	for suffix in '' -2 -3 -4 -5 -6 -7 -8; do
		jsonfilter -i "$config_file" -e "@.dns.servers[@.tag=\"ikev2-upstream$suffix\"].server" >/dev/null 2>&1 &&
			break
	done
	# Print endpoint host, port, path, then bootstrap host and port, tab-separated.
	for field in "ikev2-upstream$suffix.server" "ikev2-upstream$suffix.server_port" \
		"ikev2-upstream$suffix.path" "ikev2-bootstrap$suffix.server" "ikev2-bootstrap$suffix.server_port"; do
		value="$(jsonfilter -i "$config_file" \
			-e "@.dns.servers[@.tag=\"${field%%.*}\"].${field#*.}")" || return 1
		line="${line:+$line$tab}$value"
	done
	printf '%s\n' "$line"
}

tunnel_dns_check() {
	local selected failures endpoint old_state rendered rendered_endpoint state_selected state_configured parsed candidate index bootstrap attempted
	local switched_at previous now switch_threshold switch_target_snapshot switch_previous_snapshot switch_failures_snapshot switch_bootstrap_snapshot
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	tunnel_settings_load
	[ -n "$tunnel_on" ] || return 0
	ip link show "$(first_exit_link)" >/dev/null 2>&1 || return 0
	validate_tunnel_dns
	selected="$(selected_tunnel_dns)" || return 1
	state_selected="$(sed -n 's/^selected=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	state_configured="$(sed -n 's/^configured=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	failures=0
	if [ "$state_selected" = "$selected" ] &&
	   [ "$state_configured" = "$(tunnel_dns_endpoints)" ]; then
		failures="$(sed -n 's/^failures=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	fi
	case "$failures" in '' | *[!0-9]*) failures=0 ;; esac
	if probe_tunnel_dns "$selected"; then
		# The active bootstrap was tried first. Change it only after a real DNS
		# failure there and a successful query through another configured one.
		rendered="$(rendered_tunnel_dns 2>/dev/null || true)"
		rendered_endpoint="$(printf '%s\n' "$rendered" | awk -F '\t' 'NF >= 3 { print $1 "\t" $2 "\t" $3 }')"
		parsed="$(parse_tunnel_doh "$selected")"
		bootstrap="$(printf '%s\n' "$rendered" | awk -F '\t' 'NF >= 5 { print $4 ":" $5 }')"
		old_state="$(cat "$tunnel_dns_state" 2>/dev/null || true)"
		save_tunnel_dns_state "$selected" 0 "$probe_bootstrap" 0
		if [ "$rendered_endpoint" != "$parsed" ] || [ "$bootstrap" != "$probe_bootstrap" ]; then
			if ! refresh; then
				printf '%s\n' "$old_state" >"$tunnel_dns_state"
				return 1
			fi
		fi
		return 0
	fi
	failures=$((failures + 1))
	bootstrap="$(selected_tunnel_bootstrap)"
	candidate="$(sed -n 's/^candidate=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	case "$candidate" in '' | *[!0-9]*) candidate=0 ;; esac
	switched_at="$(sed -n 's/^switched_at=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	case "$switched_at" in '' | *[!0-9]*) switched_at=0 ;; esac
	previous="$(sed -n 's/^previous=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
	save_tunnel_dns_state "$selected" "$failures" "$bootstrap" "$candidate"
	[ "$failures" -ge 2 ] || return 0
	index=0
	attempted=0
	for endpoint in $(tunnel_dns_endpoints); do
		[ "$endpoint" = "$selected" ] && continue
		[ "$index" -ge "$candidate" ] || { index=$((index + 1)); continue; }
		switch_threshold=2
		now="$(date +%s)"
		if [ "$endpoint" = "$previous" ] && [ $((now - switched_at)) -lt 600 ]; then
			switch_threshold=4
		fi
		[ "$failures" -ge "$switch_threshold" ] || return 0
		attempted=1
		if ! probe_tunnel_dns "$endpoint"; then
			save_tunnel_dns_state "$selected" "$failures" "$bootstrap" "$((index + 1))"
			return 1
		fi
		probe_tunnel_data_plane || return 1
		old_state="$(cat "$tunnel_dns_state" 2>/dev/null || true)"
		switch_target_snapshot="$endpoint"
		switch_previous_snapshot="$selected"
		switch_failures_snapshot="$failures"
		switch_bootstrap_snapshot="$probe_bootstrap"
		save_tunnel_dns_state "$switch_target_snapshot" 0 \
			"$switch_bootstrap_snapshot" 0 "$now" "$switch_previous_snapshot"
		if refresh; then
			logger -t ikev2-domain-router "tunnel DNS switched endpoint=$switch_target_snapshot previous=$switch_previous_snapshot failures=$switch_failures_snapshot" 2>/dev/null || true
			quality_mark event dns-switch auto "$switch_target_snapshot"
			write_status active "Tunnel DNS switched to $switch_target_snapshot"
			return 0
		fi
		printf '%s\n' "$old_state" >"$tunnel_dns_state"
		return 1
	done
	# Try only one alternate endpoint per health iteration. Persist the cursor so
	# later entries are still reached without turning the watcher into a long
	# blocking scan when several providers are unavailable.
	[ "$attempted" = 1 ] || candidate=0
	save_tunnel_dns_state "$selected" "$failures" "$bootstrap" "$candidate"
	return 1
}

state_number() {
	local value
	value="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1)"
	case "$value" in '' | *[!0-9]*) value=0 ;; esac
	printf '%s\n' "$value"
}

# Ask the running sing-box to fetch a page through the tunnel outbound. Its
# listeners and configuration can all look healthy while the instance no longer
# carries traffic: after a long tunnel outage it kept failing the DoH bootstrap
# lookup until it was restarted. One delay test exercises the live tunnel
# resolver and the ipsec-out binding together.
data_plane_canary() (
	local work url rc
	work="$(mktemp -d)" || return 1
	trap 'rm -rf "$work"' EXIT
	trap 'exit 1' INT TERM
	controller_curl_config "$work" || return 1
	for url in $data_plane_canary_urls; do
		rc=0
		curl -4fsS --noproxy '*' --connect-timeout 2 --max-time 8 \
			--config "$work/curl.conf" \
			"http://$controller_address/proxies/$(first_exit_outbound)/delay?timeout=5000&url=$url" \
			>"$work/delay" 2>/dev/null || rc=$?
		case "$rc" in
			0)
				jsonfilter -i "$work/delay" -e '@.delay' 2>/dev/null |
					grep -Eq '^[0-9]+$' && return 0
				;;
			# The controller itself did not answer; the next target cannot help.
			7 | 28) return 1 ;;
		esac
	done
	return 1
)

save_data_plane_state() {
	{
		printf 'state=%s\n' "$1"
		printf 'checked=%s\n' "$(date +%s)"
		printf 'failures=%s\n' "$2"
		printf 'restarts=%s\n' "$3"
		printf 'restarted_at=%s\n' "$4"
	} >"${data_plane_state}.new"
	mv "${data_plane_state}.new" "$data_plane_state"
}

# The listener binds before sing-box can answer: its first upstream query still
# has to complete, so a single probe right after a start fails on a cold cache.
resolver_answers() {
	local tries=0
	while ! validate_dns_server "$dns_address"; do
		tries=$((tries + 1))
		[ "$tries" -lt 10 ] || return 1
		sleep 2
	done
}

restart_resolver() {
	/etc/init.d/ikev2-domain-router restart &&
		wait_for_dns &&
		resolver_answers &&
		{ nft_runtime_ready || nft_start; }
}

# Restart the resolver only when the fault is provably its own: the tunnel
# carries traffic on its own, the independent tunnel DNS probe answers, and the
# live instance still fails twice in a row. The wait between restarts doubles
# from two minutes to an hour, so a fault a restart cannot cure costs one
# restart an hour. The check runs once a minute, every 20 seconds while it
# fails, and at once when the caller passes "now" after the tunnel returns.
data_plane_check() {
	local now failures restarts restarted_at backoff interval
	init_config
	tunnel_settings_load
	if [ "$(defaultv domains engine nftset)" != fakeip ] || [ -z "$tunnel_on" ]; then
		rm -f "$data_plane_state"
		return 0
	fi
	now="$(date +%s)"
	if [ "${1:-}" != now ]; then
		interval=60
		[ "$(sed -n 's/^state=//p' "$data_plane_state" 2>/dev/null | tail -n1)" = ok ] ||
			interval=20
		[ $((now - $(state_number "$data_plane_state" checked))) -ge "$interval" ] ||
			return 0
	fi
	# Listener and nftables faults belong to ensure_runtime.
	runtime_healthy || return 0
	failures="$(state_number "$data_plane_state" failures)"
	restarts="$(state_number "$data_plane_state" restarts)"
	restarted_at="$(state_number "$data_plane_state" restarted_at)"
	if data_plane_canary; then
		if [ "$failures" != 0 ]; then
			logger -t ikev2-domain-router "data plane recovered failures=$failures restarts=$restarts" 2>/dev/null || true
			# Replace a restart report that is now stale. The status file also
			# carries LuCI action progress, so write it only under the lock.
			pid_lock_busy "$lock_dir" || with_lock write_status active 'FakeIP data plane recovered'
		fi
		# Forget restarts only after an hour without one, or a fault that a
		# restart cures for a minute would restart the resolver every minute.
		[ $((now - restarted_at)) -lt 3600 ] || restarts=0
		save_data_plane_state ok 0 "$restarts" "$restarted_at"
		return 0
	fi
	if ! ip link show "$(first_exit_link)" >/dev/null 2>&1 || ! probe_tunnel_data_plane; then
		save_data_plane_state tunnel-down 0 "$restarts" "$restarted_at"
		return 0
	fi
	# A failing tunnel DNS provider is switched by tunnel_dns_check; restarting
	# the resolver would not bring that provider back.
	if [ "$(state_number "$tunnel_dns_state" failures)" -gt 0 ]; then
		save_data_plane_state tunnel-dns-down 0 "$restarts" "$restarted_at"
		return 0
	fi
	failures=$((failures + 1))
	backoff=3600
	[ "$restarts" -ge 6 ] || backoff=$((60 << restarts))
	if [ "$failures" -lt 2 ] || [ $((now - restarted_at)) -lt "$backoff" ]; then
		save_data_plane_state degraded "$failures" "$restarts" "$restarted_at"
		return 0
	fi
	pid_lock_busy "$lock_dir" && return 0
	restarts=$((restarts + 1))
	save_data_plane_state restarting "$failures" "$restarts" "$now"
	logger -t ikev2-domain-router "restarting resolver: tunnel carries traffic but the FakeIP outbound does not failures=$failures restart=$restarts" 2>/dev/null || true
	if with_lock restart_resolver; then
		quality_mark event resolver-restart auto
		write_status active 'FakeIP resolver restarted after its tunnel path stopped answering'
	else
		quality_mark event resolver-restart auto failed
		write_status error 'FakeIP resolver restart after a tunnel path failure did not complete'
	fi
	save_data_plane_state restarted "$failures" "$restarts" "$now"
}

# Manual recovery from the overview page: the FakeIP resolver is restarted
# the same verified way the watcher does it.
recover_reliable_mode() {
	init_config
	if [ "$(defaultv domains engine nftset)" = fakeip ]; then
		logger -t ikev2-domain-router 'restarting resolver on operator request' 2>/dev/null || true
		if restart_resolver && runtime_healthy; then
			write_status active 'FakeIP resolver restarted on request'
			return 0
		fi
		write_status error 'FakeIP resolver did not come back after the restart'
		return 1
	fi
	write_status error 'Reliable mode is not enabled'
	return 1
}

# Start what was last rendered and validated. Every change renders and checks
# the configuration before it restarts the service - refresh, activate, resume,
# the DNS transaction - so rendering again here only undid a rollback: a
# restored previous configuration was replaced, on the restart meant to load
# it, by the one that had just failed. A missing or invalid file is rendered.
prepare() {
	init_config
	if [ ! -s "$config_file" ] || [ ! -s "$ruleset_file" ] ||
	   ! sing-box check -c "$config_file" >/dev/null 2>&1; then
		check_config || return 1
	fi
	nft_start
}

refresh() {
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	backup="$(mktemp -d /tmp/ikev2-domain-router-refresh.XXXXXX)" || return 1
	backup_generated "$backup"
	# Validation dies on bad input; the subshell keeps the restore below reachable.
	if ! ( check_config ); then
		restore_generated "$backup"
		rm -rf "$backup"
		write_status error 'New domain rules failed validation; previous rules remain active'
		return 1
	fi
	if ! /etc/init.d/ikev2-domain-router restart ||
	   ! wait_for_dns ||
	   ! validate_dns_server "$dns_address"; then
		restore_generated "$backup"
		/etc/init.d/ikev2-domain-router restart >/dev/null 2>&1 || true
		rm -rf "$backup"
		write_status error 'New domain rules failed at runtime; previous rules restored'
		return 1
	fi
	failed=''
	nft_start || failed='New domain TProxy runtime failed; previous rules restored'
	# The settings may have moved a segment or the ordinary names between
	# dnsmasq and sing-box, and a rollback may have put the DHCP file back under
	# the running dnsmasq: it always reads its configuration again here.
	if [ -z "$failed" ] &&
	   { ! sync_dnsmasq reload ||
	     ! wait_for_query 127.0.0.1 ||
	     ! validate_dns_server 127.0.0.1; }; then
		failed='dnsmasq did not resolve with the new DNS settings; previous rules restored'
	fi
	[ -n "$failed" ] || runtime_healthy ||
		failed='New domain TProxy runtime failed; previous rules restored'
	if [ -n "$failed" ]; then
		restore_generated "$backup"
		/etc/init.d/ikev2-domain-router restart >/dev/null 2>&1 || true
		wait_for_dns >/dev/null 2>&1 || true
		nft_start >/dev/null 2>&1 || true
		sync_dnsmasq reload >/dev/null 2>&1 || true
		rm -rf "$backup"
		write_status error "$failed"
		return 1
	fi
	rm -rf "$backup"
	write_status active 'FakeIP domain rules refreshed'
}

# Whether the running configuration is what the current settings render.
# The candidate is rendered into scratch files, pointing at the real rule-set
# path, so nothing live is touched by asking.
config_matches_rendered() (
	local current="$config_file" work
	[ -s "$current" ] || exit 1
	work="$(mktemp -d)" || exit 1
	trap 'rm -rf "$work"' EXIT
	cp "$current" "$work/candidate.json" || exit 1
	ruleset_ref="$ruleset_file"
	ruleset_file="$work/rules.json"
	bypass_ruleset_ref="$bypass_ruleset_file"
	bypass_ruleset_file="$work/bypass.json"
	config_file="$work/candidate.json"
	render_config >/dev/null 2>&1 || exit 1
	"$ucode_bin" "$runtime_lib_dir/singbox-config.uc" equal "$current" "$work/candidate.json"
)

refresh_rules() {
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	# Local rule-sets are watched and reloaded by sing-box. A service/domain-list
	# edit therefore does not need to restart the resolver, discard its in-memory
	# cache or pause DNS. Configuration changes still use the full refresh path.
	if ! runtime_healthy; then
		refresh
		return $?
	fi
	# The same edit can change the configuration as well: a device routed by
	# domain is a covered source written into it. A service start no longer
	# re-renders, so that case has to be caught here.
	if ! config_matches_rendered; then
		refresh
		return $?
	fi
	# Every exit's rule set as it is now; one that is absent stays absent.
	backup="$(mktemp -d /tmp/ikev2-domain-rules.XXXXXX)" || return 1
	for exit in 1 $tunnel_exit_order; do
		file="$(exit_rules_file "$exit")"
		[ ! -e "$file" ] || cp "$file" "$backup/$exit.json" || {
			rm -rf "$backup"
			return 1
		}
	done
	bypass_before="$(cat "$bypass_ruleset_file" 2>/dev/null)"
	if ! ( render_ruleset ); then
		rm -rf "$backup"
		write_status error 'New domain rules failed validation; previous rules remain active'
		return 1
	fi
	changed=0 added=''
	for exit in 1 $tunnel_exit_order; do
		file="$(exit_rules_file "$exit")"
		if [ -e "$backup/$exit.json" ] && [ -e "$file" ] && cmp -s "$backup/$exit.json" "$file"; then
			continue
		fi
		[ -e "$backup/$exit.json" ] || [ -e "$file" ] || continue
		changed=1
		[ -n "$added" ] || [ ! -e "$file" ] ||
			added="$(added_rule_domain "$backup/$exit.json" "$file")"
	done
	if [ "$changed" = 0 ]; then
		rm -rf "$backup"
		# Only the domains never to route changed, or nothing did: sing-box
		# reloads its rule-set by itself, dnsmasq is told by HUP.
		if [ "$bypass_before" != "$(cat "$bypass_ruleset_file" 2>/dev/null)" ] &&
		   ! foreign_servers_file; then
			write_dnsmasq_servers &&
				{ [ "$servers_changed" = 0 ] || /etc/init.d/dnsmasq reload; } || {
				write_status error 'dnsmasq did not take the domains never to route'
				return 1
			}
			write_status active 'Domains never to route reloaded without restarting DNS'
			return 0
		fi
		write_status active 'FakeIP domain rules are unchanged'
		return 0
	fi
	# sing-box reloads the files asynchronously. Wait, boundedly, until a domain
	# this change added resolves to FakeIP, which proves the reload rather than
	# assuming it; then confirm the resolver still applies the whole policy.
	attempt=0
	while [ "$attempt" -lt 6 ]; do
		if { [ -z "$added" ] ||
		     is_fakeip "$(lookup_address "$added" "$dns_address")"; } &&
		   validate_dns_server "$dns_address"; then
			# dnsmasq learns the new names only now: told earlier, it would
			# have cached the real addresses sing-box gave before its reload.
			# HUP rereads the servers file and empties the cache, and does
			# not interrupt resolution.
			if foreign_servers_file ||
			   { write_dnsmasq_servers &&
			     { [ "$servers_changed" = 0 ] || /etc/init.d/dnsmasq reload; } &&
			     { [ -z "$added" ] ||
			       is_fakeip "$(lookup_address "$added" 127.0.0.1)"; }; }; then
				rm -rf "$backup"
				write_status active 'FakeIP domain rules reloaded without restarting DNS'
				return 0
			fi
			break
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	for exit in 1 $tunnel_exit_order; do
		file="$(exit_rules_file "$exit")"
		if [ -e "$backup/$exit.json" ]; then
			cp "$backup/$exit.json" "$file.restore" && mv "$file.restore" "$file"
		else
			rm -f "$file"
		fi || {
			rm -f "$file.restore"
			rm -rf "$backup"
			write_status error 'New domain rules failed and the previous rules could not be restored'
			return 1
		}
	done
	rm -rf "$backup"
	# Fall back to the existing transactional restart. It backs up the restored
	# ruleset first, so a failed runtime validation still returns to the exact
	# policy that was active before this update.
	refresh
}

adopt_upstream() {
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	rollback="$(mktemp /tmp/ikev2-domain-router-upstream.XXXXXX)" || return 1
	uci export "$config" >"$rollback"
	clear_dnsmasq_snapshot
	save_dnsmasq
	if ! refresh ||
	   ! use_fakeip_dns ||
	   ! wait_for_query 127.0.0.1 ||
	   ! validate_dns_server 127.0.0.1; then
		uci import "$config" <"$rollback"
		uci commit "$config"
		refresh >/dev/null 2>&1 || true
		use_fakeip_dns >/dev/null 2>&1 || true
		rm -f "$rollback"
		write_status error 'DNS upstream update failed; previous FakeIP resolver restored'
		return 1
	fi
	rm -f "$rollback"
	write_status active 'FakeIP DNS upstream updated'
}

activate() {
	init_config
	check_config
	uci set "$config.domains.engine=fakeip"
	uci commit "$config"
	if ! /etc/init.d/ikev2-domain-router enable >/dev/null 2>&1 ||
	   ! /etc/init.d/ikev2-domain-router restart; then
		uci set "$config.domains.engine=nftset"
		uci commit "$config"
		/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || true
		/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || true
		write_status error 'FakeIP service could not be enabled; standard routing was restored'
		return 1
	fi
	if ! wait_for_dns || ! validate_dns_server "$dns_address"; then
		uci set "$config.domains.engine=nftset"
		uci commit "$config"
		/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || true
		/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || true
		write_status error 'FakeIP resolver validation failed; existing DNS was not changed'
		return 1
	fi

	if ! nft_start; then
		uci set "$config.domains.engine=nftset"
		uci commit "$config"
		/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || true
		/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || true
		nft_stop
		write_status error 'TProxy setup failed; existing DNS was not changed'
		return 1
	fi

	if ! use_fakeip_dns ||
	   ! wait_for_query 127.0.0.1 ||
	   ! validate_dns_server 127.0.0.1; then
		restored=1
		restore_dnsmasq || restored=0
		nft_stop
		uci set "$config.domains.engine=nftset"
		uci commit "$config"
		/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || true
		/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || true
		if [ "$restored" = 1 ]; then
			write_status error 'DNS cutover failed; previous resolver restored'
		else
			write_status error 'DNS cutover failed and resolver rollback was incomplete'
		fi
		return 1
	fi
	write_status active 'FakeIP domain routing is active'
}

deactivate() {
	restore_dnsmasq || {
		write_status error 'Unable to restore DNS before disabling FakeIP routing'
		return 1
	}
	nft_stop
	uci set "$config.domains.engine=nftset"
	uci commit "$config"
	/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || return 1
	/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || return 1
	write_status disabled 'Address-based domain routing is active'
}

# Managed mode turned off: stop interception and give dnsmasq its resolver
# back, but keep the engine the operator chose. Deactivating here rewrote it to
# nftset, so turning managed mode back on came back matching by address.
shutdown() {
	restore_dnsmasq || {
		write_status error 'Unable to restore DNS before stopping FakeIP routing'
		return 1
	}
	nft_stop
	/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || return 1
	/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || return 1
	write_status disabled 'FakeIP routing is stopped while the app does not manage the router'
}

run_async() {
	action="$1"
	ACTION_ID="${2:-}"
	shift 2
	exec >>"$log_file" 2>&1
	write_status running "Domain-routing action: $action"
	if with_lock "$action" "$@"; then
		return 0
	fi
	write_status error "Domain-routing action failed: $action"
	return 1
}

schedule() {
	action="$1"
	shift
	ACTION_ID="$(date +%s)-$$"
	write_status running "Starting domain-routing action: $action"
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _run "$action" "$ACTION_ID" "$@"; then
			write_status error "Unable to start domain-routing action: $action"
			return 1
		fi
	else
		setsid "$0" _run "$action" "$ACTION_ID" "$@" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$ACTION_ID"
}

status() {
	init_config
	printf 'engine=%s\n' "$(defaultv domains engine nftset)"
	printf 'route_router_traffic=%s\n' "$(defaultv domains route_router_traffic 0)"
	printf 'log_level=%s\n' "$(defaultv domains log_level warn)"
	printf 'system_log_size=%s\n' "$(uci -q get 'system.@system[0].log_size' 2>/dev/null || echo 0)"
	printf 'service=%s\n' "$(
		/etc/init.d/ikev2-domain-router running >/dev/null 2>&1 &&
			echo running || echo stopped
	)"
	printf 'dnsmasq_upstream=%s\n' "$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)"
	printf 'dnsmasq_cache=%s\n' "$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || true)"
	printf 'dnsmasq_resolver=%s\n' "$(dnsmasq_matches && echo ok || echo mismatch)"
	printf 'ordinary_dns=%s\n' "$(
		if foreign_servers_file; then echo singbox-servers-file
		elif ordinary_via_singbox; then echo singbox
		else echo direct
		fi
	)"
	printf 'nft=%s\n' "$(nft list table inet "$nft_table" >/dev/null 2>&1 && echo active || echo missing)"
	printf 'rule=%s\n' "$(tproxy_rules_ready &&
		echo active || echo missing)"
	printf 'healthy=%s\n' "$(runtime_healthy && echo yes || echo no)"
	printf 'data_plane=%s\n' "$(
		sed -n 's/^state=//p' "$data_plane_state" 2>/dev/null | tail -n1 | grep . ||
			echo unchecked
	)"
	printf 'data_plane_restarts=%s\n' "$(state_number "$data_plane_state" restarts)"
	printf 'data_plane_restarted_at=%s\n' "$(state_number "$data_plane_state" restarted_at)"
	cat "$state_file" 2>/dev/null || true
}

case "${1:-}" in
	render) init_config; render_config ;;
	check) init_config; check_config ;;
	prepare) prepare ;;
	refresh) with_lock refresh >>"$log_file" 2>&1 ;;
	refresh-rules) with_lock refresh_rules >>"$log_file" 2>&1 ;;
	snapshot) with_lock snapshot_generated "${2:-}" >>"$log_file" 2>&1 ;;
	restore-snapshot) with_lock restore_generated_snapshot "${2:-}" >>"$log_file" 2>&1 ;;
	adopt-upstream) with_lock adopt_upstream >>"$log_file" 2>&1 ;;
	activate) with_lock activate >>"$log_file" 2>&1 ;;
	deactivate) with_lock deactivate >>"$log_file" 2>&1 ;;
	shutdown) with_lock shutdown >>"$log_file" 2>&1 ;;
	activate-async) schedule activate ;;
	deactivate-async) schedule deactivate ;;
	refresh-async) schedule refresh ;;
	diagnostic-start)
		case "${2:-60}" in '' | *[!0-9]*) die 'Invalid diagnostic duration' ;; esac
		[ "${2:-60}" -ge 30 ] && [ "${2:-60}" -le 300 ] ||
			die 'Diagnostic duration must be 30-300 seconds'
		schedule resolver_diagnostic "${2:-60}"
		;;
	_run)
		shift
		run_async "$@"
		;;
	ensure) ensure_runtime >>"$log_file" 2>&1 ;;
	tunnel-dns-check) with_lock tunnel_dns_check >>"$log_file" 2>&1 ;;
	data-plane-check) data_plane_check "${2:-}" >>"$log_file" 2>&1 ;;
	exits-apply) exits_apply ;;
	recover) with_lock recover_reliable_mode >>"$log_file" 2>&1 ;;
	data-plane-state)
		# The last recorded result only; no health probe, for reports.
		sed -n 's/^state=//p' "$data_plane_state" 2>/dev/null | tail -n1 | grep . || echo unchecked
		;;
	nft-start) nft_start ;;
	nft-stop) nft_stop ;;
	status) status ;;
	router-traffic) init_config; with_lock set_router_traffic "${2:-}" ;;
	tunnel-resolve) init_config; with_lock set_tunnel_resolve "${2:-}" ;;
	log-level) init_config; with_lock set_log_level "${2:-}" ;;
	*)
		die 'Usage: ikev2-domain-router {render|check|prepare|refresh|refresh-rules|snapshot DIR|restore-snapshot DIR|adopt-upstream|activate|deactivate|shutdown|activate-async|deactivate-async|refresh-async|diagnostic-start 30..300|ensure|tunnel-dns-check|data-plane-check [now]|data-plane-state|recover|nft-start|nft-stop|status|router-traffic 0|1|tunnel-resolve 0|1|log-level LEVEL}'
		;;
esac
