#!/bin/sh
# Managed DNS for the system helper: validation of resolver endpoints and
# destination segments, the snapshot/rollback transaction around every change,
# and the WAN fallback refresh. Sourced by ikev2-manager-system, whose
# configuration helpers and globals it uses.

dns_original_dir='/etc/ikev2-manager/dns-original'
ensure_dns_section() {
	uci -q get "$config.dns" >/dev/null 2>&1 && return 0
	uci set "$config.dns=dns"
	uci set "$config.dns.managed=0"
	uci set "$config.dns.protocol=doh"
	uci set "$config.dns.provider=cloudflare"
	uci set "$config.dns.upstream_mode=load_balance"
	uci set "$config.dns.upstream=https://dns.cloudflare.com/dns-query"
	uci set "$config.dns.bootstrap=1.1.1.1:53 1.0.0.1:53"
	uci set "$config.dns.fallback="
	uci set "$config.dns.wan_fallback=0"
	uci set "$config.dns.timeout=4s"
	uci commit "$config"
}

wan_dns_fallbacks() {
	local interface address result=''
	interface="$(defaultv globals wan_interface wan)"
	for address in $("$ubus_binary" call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@["dns-server"][*]' 2>/dev/null || true); do
		valid_dns_ipv4 "$address" || continue
		case "$address" in
			0.* | 127.* | 169.254.* | 22[4-9].* | 23[0-9].* | 24[0-9].* | 25[0-5].*) continue ;;
		esac
		result="${result:+$result }udp://$address:53"
	done
	printf '%s\n' "$result"
}

dns_wan_reachable_fallbacks() {
	local endpoints="$1" endpoint authority address port output rc result=''
	output="$(mktemp /tmp/ikev2-manager-wan-dns-probe.XXXXXX)" || return 1
	for endpoint in $endpoints; do
		case "$endpoint" in udp://*) authority="${endpoint#udp://}" ;; *) continue ;; esac
		address="${authority%:*}"
		port="${authority##*:}"
		valid_dns_ipv4 "$address" || continue
		# WAN resolvers come from netifd/DHCP and are plain DNS on port 53.
		# BusyBox nslookup on OpenWrt does not implement the GNU/BIND-style
		# -port option, so reject any unexpected authority instead of running a
		# probe that means something different on the router than in CI.
		[ "$port" = 53 ] || continue
		if dns_probe_answers "$address"; then
			result="${result:+$result }$endpoint"
		fi
	done
	rm -f "$output"
	printf '%s\n' "$result"
}

# Transient worker used to prove that a resolver group can answer on its own.
# It binds an application-owned loopback address on port 53 rather than a high
# port: BusyBox nslookup selects a server address but has no port option, so a
# port-based probe passes on GNU test doubles and fails on the router.
dns_probe_address='127.0.0.43'

# The ordinary health query cannot verify a fallback group, because the primary
# group answers it. A fallback that has been dead for months therefore looks
# healthy until the exact moment it is needed. Run the group by itself and ask
# it one question.
dns_group_answers() {
	local endpoints="$1" bootstrap="$2" binary log output pid rc waited=0 endpoint
	[ -n "$endpoints" ] || return 0
	binary="$(command -v dnsproxy 2>/dev/null)" || return 1
	log="$(mktemp /tmp/ikev2-manager-dns-group-probe.XXXXXX)" || return 1
	output="$(mktemp /tmp/ikev2-manager-dns-group-answer.XXXXXX)" || { rm -f "$log"; return 1; }
	set -- "$binary" -l "$dns_probe_address" -p 53 \
		--upstream-mode parallel --timeout 3s
	for endpoint in $endpoints; do
		set -- "$@" -u "$endpoint"
	done
	for endpoint in $bootstrap; do
		set -- "$@" -b "$endpoint"
	done
	"$@" >"$log" 2>&1 &
	pid=$!
	while [ "$waited" -lt 5 ]; do
		if netstat -lnu 2>/dev/null | awk -v endpoint="$dns_probe_address:53" \
			'$4 == endpoint { found = 1 } END { exit found ? 0 : 1 }'; then
			break
		fi
		waited=$((waited + 1))
		sleep 1
	done
	rc=1
	dns_probe_answers "$dns_probe_address" && rc=0
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	rm -f "$log" "$output"
	return "$rc"
}

dns_runtime_timeout() {
	# dnsproxy applies the timeout once to the primary group and again to the
	# fallback group.  Keep their combined budget below sing-box's 10-second
	# DNS deadline in Reliable mode, and avoid making Standard-mode clients wait
	# twenty seconds when a configured primary resolver becomes unreachable.
	local fallback="$1" value seconds limit
	value="$(defaultv dns timeout 4s)"
	case "$value" in
		*[!0-9s]* | *s*s | s | '') seconds=4 ;;
		*s) seconds="${value%s}" ;;
		*) seconds="$value" ;;
	esac
	case "$seconds" in '' | *[!0-9]*) seconds=4 ;; esac
	[ "$seconds" -ge 1 ] 2>/dev/null || seconds=4
	limit=8
	[ -z "$fallback" ] || limit=4
	[ "$seconds" -le "$limit" ] || seconds="$limit"
	printf '%ss\n' "$seconds"
}

dns_protocol_for_upstream() {
	case "$1" in
		udp://*) printf 'udp\n' ;;
		tcp://*) printf 'tcp\n' ;;
		tls://*) printf 'dot\n' ;;
		https://*) printf 'doh\n' ;;
		h3://*) printf 'h3\n' ;;
		quic://*) printf 'doq\n' ;;
		sdns://*) printf 'dnscrypt\n' ;;
		*) printf 'unknown\n' ;;
	esac
}

valid_dns_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++)
				if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
					exit 1
		}
	'
}

valid_dns_hostname() {
	awk -v value="$1" 'BEGIN {
		if (value == "" || length(value) > 253 || value !~ /^[A-Za-z0-9.-]+$/ ||
		    value ~ /^[0-9.]+$/)
			exit 1
		count = split(value, labels, ".")
		for (i = 1; i <= count; i++) {
			label = labels[i]
			if (label == "" || length(label) > 63 ||
			    label !~ /^[A-Za-z0-9]/ || label !~ /[A-Za-z0-9]$/ ||
			    label !~ /^[A-Za-z0-9-]+$/)
				exit 1
		}
	}'
}

valid_dns_authority() {
	local authority host port
	authority="$1"
	case "$authority" in
		'' | *'/'* | *'?'* | *'#'* | *'@'* | *'['* | *']'*) return 1 ;;
	esac
	case "$authority" in
		*:*)
			host="${authority%:*}"
			port="${authority##*:}"
			[ "$host" = "${host%:*}" ] || return 1
			printf '%s' "$port" | grep -Eq '^[0-9]+$' || return 1
			[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
			;;
		*) host="$authority" ;;
	esac
	valid_dns_ipv4 "$host" || valid_dns_hostname "$host"
}

valid_dns_endpoint() {
	local protocol endpoint
	protocol="$1"
	endpoint="$2"
	[ -n "$endpoint" ] && [ "${#endpoint}" -le 2048 ] || return 1
	case "$protocol" in
		udp) prefix='udp://' ;;
		tcp) prefix='tcp://' ;;
		dot) prefix='tls://' ;;
		doh | doh3) prefix='https://' ;;
		h3) prefix='h3://' ;;
		doq) prefix='quic://' ;;
		dnscrypt)
			case "$endpoint" in sdns://*) stamp="${endpoint#sdns://}" ;; *) return 1 ;; esac
			[ "${#stamp}" -ge 8 ] &&
				printf '%s' "$stamp" | grep -Eq '^[A-Za-z0-9_-]+$'
			return
			;;
		*) return 1 ;;
	esac
	case "$endpoint" in "$prefix"*) remainder="${endpoint#"$prefix"}" ;; *) return 1 ;; esac
	case "$protocol" in
		doh | doh3 | h3)
			case "$remainder" in */*) authority="${remainder%%/*}"; path="/${remainder#*/}" ;; *) return 1 ;; esac
			valid_dns_authority "$authority" || return 1
			[ "$path" != / ] &&
				printf '%s' "$path" | grep -Eq '^/[A-Za-z0-9._~:/?%+=,&;@-]+$'
			;;
		*)
			valid_dns_authority "$remainder"
			;;
	esac
}

valid_dns_endpoint_any() {
	local endpoint protocol
	endpoint="$1"
	protocol="$(dns_protocol_for_upstream "$endpoint")"
	[ "$protocol" != unknown ] && valid_dns_endpoint "$protocol" "$endpoint"
}

valid_dns_endpoint_list_any() {
	local value endpoint
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for endpoint in $value; do
		valid_dns_endpoint_any "$endpoint" || return 1
	done
}

valid_dns_bootstrap_endpoint() {
	printf '%s\n' "$1" | awk -F: '
		NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 1 || $2 > 65535 { exit 1 }
		{
			split($1, octet, ".")
			if (length(octet) != 4) exit 1
			for (i = 1; i <= 4; i++)
				if (octet[i] !~ /^[0-9]+$/ || octet[i] < 0 || octet[i] > 255)
					exit 1
		}
	'
}

# An encrypted bootstrap entry must not need a resolver of its own, so only a
# literal IPv4 authority qualifies. Without this the whole ladder rests on
# plaintext UDP/53 to a handful of public resolvers: when those are dropped, no
# group can resolve its own endpoint names and every tier fails together.
valid_dns_bootstrap_literal() {
	local endpoint
	endpoint="$1"
	case "$endpoint" in
		https://*) remainder="${endpoint#https://}" ;;
		tls://*) remainder="${endpoint#tls://}" ;;
		quic://*) remainder="${endpoint#quic://}" ;;
		*) return 1 ;;
	esac
	case "$remainder" in
		*/*) authority="${remainder%%/*}" ;;
		*) authority="$remainder" ;;
	esac
	case "$authority" in
		*:*) host="${authority%:*}"; port="${authority##*:}" ;;
		*) host="$authority"; port=443 ;;
	esac
	case "$port" in '' | *[!0-9]*) return 1 ;; esac
	[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
	valid_dns_ipv4 "$host" || return 1
	# The remaining path, when present, is validated by the endpoint validator
	# that dnsproxy will also parse.
	valid_dns_endpoint_any "$endpoint"
}

valid_dns_bootstrap_list() {
	local value endpoint
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for endpoint in $value; do
		valid_dns_bootstrap_endpoint "$endpoint" ||
			valid_dns_bootstrap_literal "$endpoint" || return 1
	done
}

dns_segment_sections() {
	uci show "$config" 2>/dev/null |
		sed -n "s/^${config}\.\([^.=]*\)=dns_segment\$/\1/p"
}

valid_dns_suffix_list() {
	local value count suffix
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	count=0
	for suffix in $value; do
		count=$((count + 1))
		[ "$count" -le 256 ] || return 1
		case "$suffix" in .*) suffix="${suffix#.}" ;; esac
		valid_dns_hostname "$suffix" || return 1
	done
}

normalize_dns_suffix_list() {
	local value normalized suffix
	# BusyBox tr does not consistently expand POSIX character classes here and
	# can translate the letters in "ru" to "rl". DNS suffixes are validated as
	# ASCII hostnames, so an explicit ASCII range is both sufficient and stable.
	value="$(normalize_list "$1" | tr 'A-Z' 'a-z')"
	normalized=''
	for suffix in $value; do
		case "$suffix" in .*) suffix="${suffix#.}" ;; esac
		normalized="${normalized:+$normalized }$suffix"
	done
	printf '%s\n' "$normalized"
}

dns_suffixes_overlap() {
	local left right
	left="${1#.}"
	right="${2#.}"
	[ "$left" = "$right" ] && return 0
	case "$left" in *."$right") return 0 ;; esac
	case "$right" in *."$left") return 0 ;; esac
	return 1
}

validate_dns_segments() {
	local section enabled protocol mode domains upstream bootstrap fallback port suffix existing https_compat
	local ports='' suffixes='' enabled_count=0
	for section in $(dns_segment_sections); do
		enabled="$(defaultv "$section" enabled 1)"
		[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || return 1
		[ "$enabled" = 1 ] || continue
		https_compat="$(defaultv "$section" https_compat 1)"
		[ "$https_compat" = 0 ] || [ "$https_compat" = 1 ] || return 1
		case "$(defaultv "$section" wan_fallback 0)" in 0 | 1) ;; *) return 1 ;; esac
		case "$(defaultv "$section" via_singbox 0)" in 0 | 1) ;; *) return 1 ;; esac
		enabled_count=$((enabled_count + 1))
		[ "$enabled_count" -le 8 ] || return 1
		protocol="$(getv "$section" protocol)"
		mode="$(defaultv "$section" upstream_mode load_balance)"
		domains="$(getv "$section" domains)"
		upstream="$(getv "$section" upstream)"
		bootstrap="$(getv "$section" bootstrap)"
		fallback="$(getv "$section" fallback)"
		port="$(getv "$section" port)"
		case "$mode" in load_balance | parallel | fastest_addr) ;; *) return 1 ;; esac
		case "$port" in '' | *[!0-9]*) return 1 ;; esac
		[ "$port" -ge 5550 ] && [ "$port" -le 5599 ] || return 1
		case " $ports " in *" $port "*) return 1 ;; esac
		ports="${ports:+$ports }$port"
		valid_dns_suffix_list "$domains" || return 1
		for suffix in $(normalize_dns_suffix_list "$domains"); do
			for existing in $suffixes; do
				dns_suffixes_overlap "$suffix" "$existing" && return 1
			done
			suffixes="${suffixes:+$suffixes }$suffix"
		done
		# A segment group may mix transports for the same reason the router
		# group may: blocking is applied per protocol per provider, and
		# dnsproxy parses each upstream by its own scheme. The stored protocol
		# summarises the group; it does not constrain it.
		valid_dns_endpoint_list_any "$upstream" || return 1
		valid_dns_bootstrap_list "$bootstrap" || return 1
		[ -z "$fallback" ] || valid_dns_endpoint_list_any "$fallback" || return 1
	done
}

dns_combined_upstreams() {
	local base="$1"
	printf '%s\n' "$base"
	# Destination segments never sit behind this resolver. Reliable mode sends
	# them directly from sing-box; Standard mode lets dnsmasq select the worker.
	# Keeping this helper makes upgrades overwrite legacy dnsproxy decorations.
}

dnsmasq_combined_servers() {
	local base="$1" section enabled domains port suffix decorated=''
	printf '%s\n' "$base"
	for section in $(dns_segment_sections); do
		enabled="$(defaultv "$section" enabled 1)"
		[ "$enabled" = 1 ] || continue
		domains="$(normalize_list "$(getv "$section" domains)")"
		port="$(getv "$section" port)"
		decorated=''
		for suffix in $domains; do
			suffix="${suffix#.}"
			decorated="$decorated/$suffix"
		done
		printf '%s/127.0.0.1#%s\n' "$decorated" "$port"
	done
}

set_uci_list() {
	local package section option value item
	package="$1"
	section="$2"
	option="$3"
	value="$(normalize_list "$4")"
	uci -q delete "$package.$section.$option" || true
	for item in $value; do
		uci add_list "$package.$section.$option=$item"
	done
}

dns_service_state() {
	{
		if /etc/init.d/dnsproxy enabled 2>/dev/null; then
			printf 'enabled=1\n'
		else
			printf 'enabled=0\n'
		fi
		if /etc/init.d/dnsproxy running 2>/dev/null; then
			printf 'running=1\n'
		else
			printf 'running=0\n'
		fi
		if /etc/init.d/ikev2-dns-segments enabled 2>/dev/null; then
			printf 'segments_enabled=1\n'
		else
			printf 'segments_enabled=0\n'
		fi
		if /etc/init.d/ikev2-dns-segments running 2>/dev/null; then
			printf 'segments_running=1\n'
		else
			printf 'segments_running=0\n'
		fi
	}
}

restore_dns_segment_service_state() {
	local state="$1" enabled running
	[ -x /etc/init.d/ikev2-dns-segments ] || return 0
	enabled="$(sed -n 's/^segments_enabled=//p' "$state" 2>/dev/null | tail -1)"
	running="$(sed -n 's/^segments_running=//p' "$state" 2>/dev/null | tail -1)"
	case "$enabled:$running" in
		1:1)
			/etc/init.d/ikev2-dns-segments enable >/dev/null 2>&1 &&
				/etc/init.d/ikev2-dns-segments restart >/dev/null 2>&1
			;;
		1:0)
			/etc/init.d/ikev2-dns-segments enable >/dev/null 2>&1 &&
				/etc/init.d/ikev2-dns-segments stop >/dev/null 2>&1
			;;
		0:1)
			# Running and enabled are independent procd states. Preserve a
			# deliberately one-shot service instead of declaring DNS rollback
			# incomplete merely because it is not registered for autostart.
			/etc/init.d/ikev2-dns-segments disable >/dev/null 2>&1 &&
				/etc/init.d/ikev2-dns-segments restart >/dev/null 2>&1
			;;
		0:0)
			/etc/init.d/ikev2-dns-segments stop >/dev/null 2>&1 &&
				/etc/init.d/ikev2-dns-segments disable >/dev/null 2>&1
			;;
		*) return 1 ;;
	esac
}

save_dns_state() {
	local dir="$1" tmp package source
	tmp="${dir}.new.$$"
	rm -rf "$tmp"
	mkdir -p "${dir%/*}" "$tmp" || return 1
	for package in dnsproxy dhcp; do
		source="$uci_config_dir/$package"
		if [ -f "$source" ]; then
			cp "$source" "$tmp/$package.config" || { rm -rf "$tmp"; return 1; }
		else
			: >"$tmp/$package.absent"
		fi
	done
	if [ -f "$tmp/dhcp.config" ]; then
		dhcp_resolver_options_save "$tmp/dnsmasq.options" || { rm -rf "$tmp"; return 1; }
	fi
	dns_service_state >"$tmp/service.state" || { rm -rf "$tmp"; return 1; }
	rm -rf "$dir"
	mv "$tmp" "$dir"
}

repair_dns_original_snapshot() {
	local dir="$dns_original_dir" work servers server uses_fakeip
	local restored_servers restored_noresolv restored_cachesize
	local saved_running listen_addr listen_port destination
	[ -f "$dir/dhcp.config" ] || return 0

	work="${dir}.repair.$$"
	rm -rf "$work"
	mkdir -p "$work" || return 1
	cp "$dir/dhcp.config" "$work/dhcp" || { rm -rf "$work"; return 1; }
	servers="$("$uci_binary" -c "$work" -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null || true)"
	uses_fakeip=0
	for server in $servers; do
		case "$server" in
			127.0.0.42 | 127.0.0.42#53) uses_fakeip=1 ;;
		esac
	done
	if [ "$uses_fakeip" = 0 ]; then
		rm -rf "$work"
		return 0
	fi

	if [ "$(defaultv domains dns_saved 0)" = 1 ]; then
		restored_servers="$(get_list domains prev_server)"
		restored_noresolv="$(defaultv domains prev_noresolv 0)"
		restored_cachesize="$(defaultv domains prev_cachesize 150)"
	else
		saved_running="$(sed -n 's/^running=//p' "$dir/service.state" 2>/dev/null | tail -1)"
		[ "$saved_running" = 1 ] && [ -f "$dir/dnsproxy.config" ] || {
			rm -rf "$work"
			return 1
		}
		cp "$dir/dnsproxy.config" "$work/dnsproxy" || { rm -rf "$work"; return 1; }
		listen_addr="$("$uci_binary" -c "$work" -q get dnsproxy.global.listen_addr 2>/dev/null || true)"
		listen_port="$("$uci_binary" -c "$work" -q get dnsproxy.global.listen_port 2>/dev/null || true)"
		set -- $listen_addr
		[ "$#" -eq 1 ] && [ "$1" = 127.0.0.1 ] || { rm -rf "$work"; return 1; }
		set -- $listen_port
		[ "$#" -eq 1 ] || { rm -rf "$work"; return 1; }
		case "$1" in
			'' | *[!0-9]*) rm -rf "$work"; return 1 ;;
		esac
		[ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { rm -rf "$work"; return 1; }
		restored_servers="127.0.0.1#$1"
		restored_noresolv=1
		restored_cachesize="$(uci -q get 'dhcp.@dnsmasq[0].cachesize' 2>/dev/null || true)"
		case "$restored_cachesize" in
			'' | *[!0-9]*) restored_cachesize=150 ;;
		esac
	fi

	case "$restored_noresolv" in 0 | 1) ;; *) rm -rf "$work"; return 1 ;; esac
	case "$restored_cachesize" in '' | *[!0-9]*) rm -rf "$work"; return 1 ;; esac
	"$uci_binary" -c "$work" -q delete 'dhcp.@dnsmasq[0].server' || true
	for server in $restored_servers; do
		"$uci_binary" -c "$work" add_list "dhcp.@dnsmasq[0].server=$server" || {
			rm -rf "$work"
			return 1
		}
	done
	"$uci_binary" -c "$work" set "dhcp.@dnsmasq[0].noresolv=$restored_noresolv" || {
		rm -rf "$work"
		return 1
	}
	"$uci_binary" -c "$work" set "dhcp.@dnsmasq[0].cachesize=$restored_cachesize" || {
		rm -rf "$work"
		return 1
	}
	"$uci_binary" -c "$work" commit dhcp || { rm -rf "$work"; return 1; }
	destination="$dir/dhcp.config.repair.$$"
	cp "$work/dhcp" "$destination" || { rm -rf "$work"; return 1; }
	chmod 600 "$destination" || { rm -f "$destination"; rm -rf "$work"; return 1; }
	mv "$destination" "$dir/dhcp.config" || { rm -f "$destination"; rm -rf "$work"; return 1; }
	rm -rf "$work"
	# The recorded options are what a scoped restore applies; keep them in step
	# with the repaired snapshot.
	{
		printf 'server=%s\n' "$restored_servers"
		printf 'noresolv=%s\n' "$restored_noresolv"
		printf 'cachesize=%s\n' "$restored_cachesize"
	} >"$dir/dnsmasq.options.new" && mv "$dir/dnsmasq.options.new" "$dir/dnsmasq.options"
}

# SCOPE "file" puts both files back whole: right for a rollback within one
# transaction, where nothing else changed meanwhile. SCOPE "options" is for the
# snapshot taken when managed DNS was first enabled, possibly months ago: the
# DHCP file then keeps everything added since and only the resolver options
# the application changed return.
restore_dns_state() {
	local dir="$1" restart_dnsmasq="${2:-1}" scope="${3:-file}" package destination enabled running options
	[ -d "$dir" ] || return 0
	for package in dnsproxy dhcp; do
		destination="$uci_config_dir/$package"
		uci -q revert "$package" >/dev/null 2>&1 || true
		if [ "$package" = dhcp ] && [ "$scope" = options ]; then
			options="$dir/dnsmasq.options"
			if [ ! -s "$options" ] && [ -f "$dir/dhcp.config" ]; then
				options="$dir/dnsmasq.options.legacy"
				dhcp_resolver_options_from_file "$dir/dhcp.config" "$options" || return 1
			fi
			# An absent DHCP file before the application is not a reason to
			# delete the one the router has now.
			[ ! -s "$options" ] || dhcp_resolver_options_restore "$options" || return 1
			continue
		fi
		if [ -f "$dir/$package.config" ]; then
			cp "$dir/$package.config" "${destination}.restore.$$" || return 1
			mv "${destination}.restore.$$" "$destination" || return 1
		elif [ -f "$dir/$package.absent" ]; then
			rm -f "$destination"
		elif [ -s "$dir/$package.uci" ]; then
			uci import "$package" <"$dir/$package.uci" || return 1
			uci commit "$package" || return 1
		else
			return 1
		fi
	done
	enabled="$(sed -n 's/^enabled=//p' "$dir/service.state" 2>/dev/null | tail -1)"
	running="$(sed -n 's/^running=//p' "$dir/service.state" 2>/dev/null | tail -1)"
	if [ "$enabled" = 1 ]; then
		/etc/init.d/dnsproxy enable >/dev/null 2>&1 || return 1
	else
		/etc/init.d/dnsproxy disable >/dev/null 2>&1 || return 1
	fi
	if [ "$running" = 1 ]; then
		/etc/init.d/dnsproxy restart >/dev/null 2>&1 || return 1
	else
		/etc/init.d/dnsproxy stop >/dev/null 2>&1 || return 1
	fi
	if [ "$restart_dnsmasq" = 1 ]; then
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
	fi
}

ensure_dns_original() {
	if [ "$(defaultv dns saved 0)" = 1 ] &&
	   [ -s "$dns_original_dir/service.state" ] &&
	   { [ -f "$dns_original_dir/dhcp.config" ] || [ -f "$dns_original_dir/dhcp.absent" ]; } &&
	   { [ -f "$dns_original_dir/dnsproxy.config" ] || [ -f "$dns_original_dir/dnsproxy.absent" ]; }; then
		repair_dns_original_snapshot
		return
	fi
	rm -rf "$dns_original_dir"
	save_dns_state "$dns_original_dir" || return 1
	repair_dns_original_snapshot || { rm -rf "$dns_original_dir"; return 1; }
	uci set "$config.dns.saved=1"
	uci commit "$config"
}

rollback_dns_transaction() {
	trap - EXIT INT TERM HUP
	[ "${dns_rollback_active:-0}" = 1 ] || return 0
	dns_rollback_active=0
	rollback_ok=1
	# Restore the application model first. FakeIP and segment renderers consume
	# it, so starting them against the rejected candidate can make an otherwise
	# valid resolver snapshot impossible to bring back.
	uci -q revert "$config" >/dev/null 2>&1 || true
	if [ -s "$rollback/$config.uci" ]; then
		uci import "$config" <"$rollback/$config.uci" &&
			uci commit "$config" || rollback_ok=0
	else
		rollback_ok=0
	fi
	# Restore files and the main proxy without exposing dnsmasq to a half-built
	# chain. Segment listeners must be available before sing-box is rendered.
	restore_dns_state "$rollback" 0 || rollback_ok=0
	restore_dns_segment_service_state "$rollback/service.state" || rollback_ok=0
	if [ "${fakeip_active:-0}" = 1 ] && [ -x /usr/libexec/ikev2-domain-router ]; then
		if ! /usr/libexec/ikev2-domain-router refresh >/dev/null 2>&1; then
			/usr/libexec/ikev2-domain-router restore-snapshot \
				"$rollback/domain-router" >/dev/null 2>&1 || rollback_ok=0
		fi
	else
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || rollback_ok=0
	fi
	dns_query_ok >/dev/null 2>&1 || rollback_ok=0
	rm -rf "$rollback"
	[ "$rollback_ok" -eq 1 ]
}

abort_dns_transaction() {
	if rollback_dns_transaction; then
		printf '%s\n' 'DNS apply aborted; previous resolver configuration was restored' >&2
	else
		printf '%s\n' 'DNS apply aborted and automatic resolver rollback was incomplete' >&2
	fi
}

dns_query_ok() {
	wait_for_router_dns 127.0.0.1 8
}

dns_wan_restart_segments() {
	/etc/init.d/ikev2-dns-segments restart >/dev/null 2>&1
}

dns_wan_restart_proxy() {
	/etc/init.d/dnsproxy restart >/dev/null 2>&1
}

# Segments that fall back to the provider's resolvers took the ones the WAN
# lease had when they started. A new lease with different resolvers restarts
# them; a user action in progress has priority and the next pass retries.
dns_segments_wan_file=/var/run/ikev2-dns-segments.wan

dns_segments_wan_refresh() {
	local section used=0 current recorded
	[ "$(defaultv dns managed 0)" = 1 ] || return 0
	for section in $(dns_segment_sections); do
		[ "$(defaultv "$section" enabled 1)" = 1 ] || continue
		[ "$(defaultv "$section" wan_fallback 0)" = 1 ] && used=1
	done
	[ "$used" = 1 ] || return 0
	/etc/init.d/ikev2-dns-segments running 2>/dev/null || return 0
	current="$(wan_dns_fallbacks)"
	# During an interface transition netifd can briefly publish none.
	[ -n "$current" ] || return 0
	recorded="$(cat "$dns_segments_wan_file" 2>/dev/null || true)"
	[ "$(normalize_list "$current")" != "$(normalize_list "$recorded")" ] || return 0
	action_lock_busy && return 0
	if dns_wan_restart_segments; then
		logger -t ikev2-manager "DNS segments took the provider's new resolvers endpoints=$current" 2>/dev/null || true
	else
		logger -t ikev2-manager 'DNS segments failed to restart with the provider resolvers' 2>/dev/null || true
	fi
}

dns_wan_fallback_refresh() {
	local provider_raw provider verified_provider configured desired current backup rollback_ok
	[ "$(defaultv dns managed 0)" = 1 ] || return 0
	[ "$(defaultv dns wan_fallback 0)" = 1 ] || return 0
	provider_raw="$(wan_dns_fallbacks)"
	# During an interface transition netifd can briefly publish no resolvers.
	# Keep the last validated runtime group until the new lease is complete.
	[ -n "$provider_raw" ] || return 0
	configured="$(getv dns fallback)"
	desired="$(list_without "$configured $provider_raw" "$(getv dns upstream)")"
	current="$(normalize_list "$(uci -q get dnsproxy.servers.fallback 2>/dev/null || true)")"
	[ "$desired" != "$current" ] || return 0
	# A syntactically valid DHCP resolver is not necessarily reachable. Admit
	# only endpoints that answer a direct query; retain the previous validated
	# group when the new lease is incomplete or captive.
	verified_provider="$(dns_wan_reachable_fallbacks "$provider_raw")"
	if [ -z "$verified_provider" ]; then
		logger -t ikev2-manager "WAN DNS fallback candidate did not answer; previous resolver group retained endpoints=$provider_raw" 2>/dev/null || true
		return 0
	fi
	desired="$(list_without "$configured $verified_provider" "$(getv dns upstream)")"
	[ "$desired" != "$current" ] || return 0
	action_lock_busy && return 0
	if ! acquire_action_lock wan-dns "wan-dns-$$"; then
		# A user transaction has priority. The periodic health pass retries after
		# it releases the shared lock.
		return 0
	fi
	trap 'release_action_lock' EXIT INT TERM HUP
	provider="$(wan_dns_fallbacks)"
	# Do not commit a candidate derived from a superseded netifd snapshot. The
	# next health pass will preflight the new lease before taking the lock.
	[ "$provider" = "$provider_raw" ] || return 0
	current="$(normalize_list "$(uci -q get dnsproxy.servers.fallback 2>/dev/null || true)")"
	[ "$desired" != "$current" ] || return 0
	backup="$(mktemp -d /tmp/ikev2-manager-wan-dns-rollback.XXXXXX)" || return 1
	save_dns_state "$backup" || { rm -rf "$backup"; return 1; }
	set_uci_list dnsproxy servers fallback "$desired"
	uci commit dnsproxy || {
		restore_dns_state "$backup" 0 >/dev/null 2>&1 || true
		rm -rf "$backup"
		return 1
	}
	if dns_wan_restart_segments && dns_wan_restart_proxy && dns_query_ok &&
	   dns_segments_check; then
		rm -rf "$backup"
		logger -t ikev2-manager "WAN DNS fallback refreshed endpoints=$verified_provider" 2>/dev/null || true
		return 0
	fi
	rollback_ok=1
	restore_dns_state "$backup" 0 >/dev/null 2>&1 || rollback_ok=0
	restore_dns_segment_service_state "$backup/service.state" >/dev/null 2>&1 || rollback_ok=0
	dns_query_ok >/dev/null 2>&1 || rollback_ok=0
	dns_segments_check >/dev/null 2>&1 || rollback_ok=0
	rm -rf "$backup"
	if [ "$rollback_ok" = 1 ]; then
		logger -t ikev2-manager 'WAN DNS fallback refresh failed; previous resolver group restored and verified' 2>/dev/null || true
	else
		logger -t ikev2-manager 'WAN DNS fallback refresh failed and rollback validation is degraded' 2>/dev/null || true
	fi
	return 1
}

dns_segments_check() {
	local section enabled domains port suffix probe output now rc=0 total=0 failed=0
	local probe_count=0 segment_failed=0 failure_ids=''
	local direct_failed=0 path_failed=0 direct_failure_ids='' path_failure_ids=''
	now="$(date +%s)"
	output="$(mktemp /tmp/ikev2-manager-dns-segment-check.XXXXXX)" || return 1
	for section in $(dns_segment_sections); do
		enabled="$(defaultv "$section" enabled 1)"
		[ "$enabled" = 1 ] || continue
		domains="$(normalize_dns_suffix_list "$(getv "$section" domains)")"
		port="$(getv "$section" port)"
		[ -n "$domains" ] || continue
		total=$((total + 1))
		segment_failed=0
		# Every suffix in a segment reaches the same loopback worker and the same
		# dnsmasq rule path. Verify that the worker owns its configured UDP socket,
		# then probe one representative suffix through dnsmasq. BusyBox nslookup
		# cannot address a non-standard port, so pretending to query the worker
		# directly made the router check fail while GNU-like test doubles passed.
		suffix="${domains%% *}"
		probe_count=$((probe_count + 1))
		probe="ikev2-health-${now}-${probe_count}.${suffix}"
		if ! netstat -lnu 2>/dev/null | awk -v endpoint="127.0.0.1:$port" \
			'$4 == endpoint { found = 1 } END { exit found ? 0 : 1 }'; then
			segment_failed=1
			direct_failed=1
		else
			rc=0
			pkg_run_bounded 3 nslookup "$probe" 127.0.0.1 >"$output" 2>&1 || rc=$?
			# A random child normally returns NXDOMAIN. That is a healthy recursive
			# response; only timeout, REFUSED and SERVFAIL mean the suffix path failed.
			if grep -Eqi 'SERVFAIL|REFUSED|timed out|no servers could be reached' "$output" ||
			   { [ "$rc" -ne 0 ] && ! grep -Eqi 'NXDOMAIN|name error' "$output"; }; then
				segment_failed=1
				path_failed=1
			fi
		fi
		rc=0
		if [ "$segment_failed" -eq 1 ]; then
			failed=$((failed + 1))
			failure_ids="${failure_ids}${failure_ids:+,}${section#dnsseg_}"
		fi
		if [ "$direct_failed" -eq 1 ]; then
			direct_failure_ids="${direct_failure_ids}${direct_failure_ids:+,}${section#dnsseg_}"
		fi
		if [ "$path_failed" -eq 1 ]; then
			path_failure_ids="${path_failure_ids}${path_failure_ids:+,}${section#dnsseg_}"
		fi
		direct_failed=0
		path_failed=0
		rc=0
	done
	rm -f "$output"
	mkdir -p "${dns_segments_status_file%/*}"
	{
		if [ "$total" -eq 0 ]; then
			printf 'state=disabled\n'
		elif [ "$failed" -eq 0 ]; then
			printf 'state=up\n'
		else
			printf 'state=degraded\n'
		fi
		printf 'checked=%s\n' "$now"
		printf 'segments=%s\n' "$total"
		printf 'failed=%s\n' "$failed"
		printf 'failure_ids=%s\n' "$failure_ids"
		printf 'direct_failure_ids=%s\n' "$direct_failure_ids"
		printf 'path_failure_ids=%s\n' "$path_failure_ids"
	} >"${dns_segments_status_file}.new"
	mv "${dns_segments_status_file}.new" "$dns_segments_status_file"
	[ "$failed" -eq 0 ]
}

dns_show() {
	ensure_dns_section
	managed="$(defaultv dns managed 0)"
	protocol="$(defaultv dns protocol doh)"
	provider="$(defaultv dns provider cloudflare)"
	upstream_mode="$(defaultv dns upstream_mode load_balance)"
	upstream="$(getv dns upstream)"
	bootstrap="$(getv dns bootstrap)"
	fallback="$(getv dns fallback)"
	wan_fallback="$(defaultv dns wan_fallback 0)"
	wan_fallback_current="$(wan_dns_fallbacks)"
	current_upstream="$(uci -q get dnsproxy.servers.upstream 2>/dev/null || true)"
	current_bootstrap="$(uci -q get dnsproxy.servers.bootstrap 2>/dev/null || true)"
	current_fallback="$(uci -q get dnsproxy.servers.fallback 2>/dev/null || true)"
	current_upstream_mode="$(uci -q get dnsproxy.global.upstream_mode 2>/dev/null || true)"
	[ -n "$current_upstream_mode" ] || current_upstream_mode=load_balance
	current_protocol='unknown'
	for endpoint in $current_upstream; do
		current_protocol="$(dns_protocol_for_upstream "$endpoint")"
		break
	done
	printf 'managed=%s\n' "$managed"
	printf 'protocol=%s\n' "$protocol"
	printf 'provider=%s\n' "$provider"
	printf 'upstream_mode=%s\n' "$upstream_mode"
	printf 'upstream=%s\n' "$upstream"
	printf 'bootstrap=%s\n' "$bootstrap"
	printf 'fallback=%s\n' "$fallback"
	printf 'wan_fallback=%s\n' "$wan_fallback"
	printf 'wan_fallback_current=%s\n' "$wan_fallback_current"
	printf 'current_protocol=%s\n' "$current_protocol"
	printf 'current_upstream=%s\n' "$current_upstream"
	printf 'current_bootstrap=%s\n' "$current_bootstrap"
	printf 'current_fallback=%s\n' "$current_fallback"
	printf 'current_upstream_mode=%s\n' "$current_upstream_mode"
	# The stored timeout is a request; dnsproxy is given a value bounded by
	# sing-box's own deadline. Reporting only the stored one made the interface
	# show a number that never applied.
	printf 'timeout=%s\n' "$(defaultv dns timeout 4s)"
	printf 'timeout_effective=%s\n' "$(dns_runtime_timeout "$current_fallback")"
	printf 'fallback_verified=%s\n' "$(getv dns fallback_verified)"
	printf 'tunnel_resolve=%s\n' "$(defaultv dns tunnel_resolve 0)"
	printf 'via_singbox=%s\n' "$(defaultv dns via_singbox 0)"
	printf 'https_compat=%s\n' "$(defaultv dns https_compat 0)"
	printf 'engine=%s\n' "$(defaultv domains engine nftset)"
	printf 'segment_health=%s\n' \
		"$(sed -n 's/^state=//p' "$dns_segments_status_file" 2>/dev/null | tail -n1)"
	printf 'segment_failures=%s\n' \
		"$(sed -n 's/^failure_ids=//p' "$dns_segments_status_file" 2>/dev/null | tail -n1)"
	printf 'segment_direct_failures=%s\n' \
		"$(sed -n 's/^direct_failure_ids=//p' "$dns_segments_status_file" 2>/dev/null | tail -n1)"
	printf 'segment_path_failures=%s\n' \
		"$(sed -n 's/^path_failure_ids=//p' "$dns_segments_status_file" 2>/dev/null | tail -n1)"
	if /etc/init.d/dnsproxy running 2>/dev/null; then
		printf 'running=1\n'
	else
		printf 'running=0\n'
	fi
}

# What a segment actually falls back to. An empty segment fallback inherits the
# global fallback group and then the global primary group, minus anything the
# segment already uses. Reporting only the stored value made an empty field read
# as "no fallback" when it is in fact the widest one available - including, when
# the WAN fallback is on, the provider's plaintext resolver.
dns_segment_effective_fallback() {
	local section="$1" configured inherited endpoint seen duplicate upstream result=''
	configured="$(normalize_list "$(getv "$section" fallback)")"
	upstream="$(normalize_list "$(getv "$section" upstream)")"
	if [ -n "$configured" ]; then
		inherited="$configured"
	else
		inherited="$(uci -q get dnsproxy.servers.fallback 2>/dev/null || true) $(getv dns upstream)"
	fi
	# The provider's resolvers, last, when the segment asks for them.
	[ "$(defaultv "$section" wan_fallback 0)" != 1 ] ||
		inherited="$inherited $(wan_dns_fallbacks)"
	for endpoint in $inherited; do
		duplicate=0
		for seen in $upstream $result; do
			[ "$seen" != "$endpoint" ] || { duplicate=1; break; }
		done
		[ "$duplicate" = 0 ] || continue
		result="${result:+$result }$endpoint"
	done
	printf '%s\n' "$result"
}

dns_segments_show() {
	local section
	for section in $(dns_segment_sections); do
		printf 'id=%s\tname=%s\tenabled=%s\tdomains=%s\tprotocol=%s\tmode=%s\tupstream=%s\tbootstrap=%s\tfallback=%s\tfallback_effective=%s\tinherits_fallback=%s\thttps_compat=%s\twan_fallback=%s\tvia_singbox=%s\tport=%s\n' \
			"${section#dnsseg_}" "$(getv "$section" name)" \
			"$(defaultv "$section" enabled 1)" "$(getv "$section" domains)" \
			"$(getv "$section" protocol)" "$(defaultv "$section" upstream_mode load_balance)" \
			"$(getv "$section" upstream)" "$(getv "$section" bootstrap)" \
			"$(getv "$section" fallback)" \
			"$(dns_segment_effective_fallback "$section")" \
			"$([ -n "$(normalize_list "$(getv "$section" fallback)")" ] && echo 0 || echo 1)" \
			"$(defaultv "$section" https_compat 1)" \
			"$(defaultv "$section" wan_fallback 0)" \
			"$(defaultv "$section" via_singbox 0)" \
			"$(getv "$section" port)"
	done
}

next_dns_segment_port() {
	local port used section
	port=5550
	while [ "$port" -le 5599 ]; do
		used=0
		for section in $(dns_segment_sections); do
			[ "$(getv "$section" port)" != "$port" ] || used=1
		done
		[ "$used" = 1 ] || { printf '%s\n' "$port"; return 0; }
		port=$((port + 1))
	done
	return 1
}

# The path ordinary names take in Reliable mode while the router keeps its own
# DNS. Only the resolver changes; when it does not answer, the previous path
# comes back.
dns_path_apply() {
	local via="$1" compat="$2" old_via old_compat
	old_via="$(defaultv dns via_singbox 0)"
	old_compat="$(defaultv dns https_compat 0)"
	[ "$via:$compat" != "$old_via:$old_compat" ] || return 0
	uci set "$config.dns.via_singbox=$via" &&
		uci set "$config.dns.https_compat=$compat" &&
		uci commit "$config" || die 'Unable to save the DNS resolution path'
	/usr/libexec/ikev2-domain-router refresh && dns_query_ok && return 0
	uci set "$config.dns.via_singbox=$old_via" &&
		uci set "$config.dns.https_compat=$old_compat" &&
		uci commit "$config" &&
		/usr/libexec/ikev2-domain-router refresh &&
		die 'DNS did not resolve on the new path; the previous path was restored'
	die 'DNS did not resolve on the new path, and the previous path could not be restored'
}

apply_saved_dns() {
	dns_apply "$(defaultv dns managed 0)" "$(defaultv dns protocol doh)" \
		"$(defaultv dns provider custom)" "$(defaultv dns upstream_mode load_balance)" \
		"$(getv dns upstream)" "$(getv dns bootstrap)" "$(getv dns fallback)" \
		"$(defaultv dns wan_fallback 0)" "$(defaultv dns via_singbox 0)" \
		"$(defaultv dns https_compat 0)"
}

dns_segment_update() {
	local action="$1" id="$2" name="$3" enabled="$4" domains="$5"
	local protocol="$6" mode="$7" upstream="$8" bootstrap="$9" fallback="${10:-}" https_compat="${11:-1}"
	local wan_fallback="${12:-0}" via_singbox="${13:-}"
	local section backup port current_port restored=0 mutation_ok=1
	case "$id" in '' | *[!A-Za-z0-9_]* ) die 'Invalid DNS segment identifier' ;; esac
	[ "${#id}" -le 40 ] || die 'DNS segment identifier is too long'
	section="dnsseg_$id"
	backup="$(mktemp)" || die 'Unable to snapshot DNS segments'
	uci export "$config" >"$backup" || { rm -f "$backup"; die 'Unable to snapshot DNS segments'; }
	case "$action" in
		delete)
			uci -q delete "$config.$section" || true
			;;
		set)
			valid_name "$name" || { rm -f "$backup"; die 'Invalid DNS segment name'; }
			[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || { rm -f "$backup"; die 'Invalid DNS segment state'; }
			[ "$https_compat" = 0 ] || [ "$https_compat" = 1 ] || {
				rm -f "$backup"; die 'Invalid DNS segment browser compatibility mode'; }
			[ "$wan_fallback" = 0 ] || [ "$wan_fallback" = 1 ] || {
				rm -f "$backup"; die 'Invalid DNS segment provider fallback setting'; }
			# A page that predates the setting does not send it.
			[ -n "$via_singbox" ] || via_singbox="$(defaultv "$section" via_singbox 0)"
			[ "$via_singbox" = 0 ] || [ "$via_singbox" = 1 ] || {
				rm -f "$backup"; die 'Invalid DNS segment resolution path'; }
			valid_dns_suffix_list "$domains" || { rm -f "$backup"; die 'Invalid DNS suffix list'; }
			case "$mode" in load_balance | parallel | fastest_addr) ;;
				*) rm -f "$backup"; die 'Invalid DNS segment query strategy' ;;
			esac
			valid_dns_endpoint_list_any "$upstream" || {
				rm -f "$backup"; die 'Invalid DNS segment upstream'; }
			valid_dns_bootstrap_list "$bootstrap" || {
				rm -f "$backup"; die 'Invalid DNS segment bootstrap'; }
			[ -z "$fallback" ] || valid_dns_endpoint_list_any "$fallback" || {
				rm -f "$backup"; die 'Invalid DNS segment fallback'; }
			current_port="$(getv "$section" port)"
			case "$current_port" in '' | *[!0-9]*) port="$(next_dns_segment_port)" || {
				rm -f "$backup"; die 'No DNS segment listener ports remain'; } ;;
			*) port="$current_port" ;;
			esac
			domains="$(normalize_dns_suffix_list "$domains")"
			uci set "$config.$section=dns_segment" &&
				uci set "$config.$section.name=$name" &&
				uci set "$config.$section.enabled=$enabled" &&
				uci set "$config.$section.domains=$domains" &&
				uci set "$config.$section.protocol=$protocol" &&
				uci set "$config.$section.upstream_mode=$mode" &&
				uci set "$config.$section.upstream=$(normalize_list "$upstream")" &&
				uci set "$config.$section.bootstrap=$(normalize_list "$bootstrap")" &&
				uci set "$config.$section.fallback=$(normalize_list "$fallback")" &&
				uci set "$config.$section.https_compat=$https_compat" &&
				uci set "$config.$section.wan_fallback=$wan_fallback" &&
				uci set "$config.$section.via_singbox=$via_singbox" &&
				uci set "$config.$section.port=$port" || mutation_ok=0
			;;
		*) rm -f "$backup"; die 'Expected DNS segment action: set or delete' ;;
	esac
	if [ "$mutation_ok" != 1 ] || ! validate_dns_segments || ! uci commit "$config"; then
		uci -q revert "$config" >/dev/null 2>&1 || true
		if uci import "$config" <"$backup" && uci commit "$config"; then
			rm -f "$backup"
			die 'Invalid DNS segment; previous configuration restored'
		fi
		rm -f "$backup"
		die 'DNS segment update failed and automatic rollback was incomplete'
	fi
	if [ "$(defaultv dns managed 0)" = 1 ] && ! ( apply_saved_dns ); then
		uci import "$config" <"$backup" && uci commit "$config" && restored=1
		[ "$restored" = 0 ] || ( apply_saved_dns ) >/dev/null 2>&1 || restored=0
		rm -f "$backup"
		[ "$restored" = 1 ] && die 'DNS segment failed validation; previous configuration restored'
		die 'DNS segment failed and automatic rollback was incomplete'
	fi
	rm -f "$backup"
}

dns_segment_input() {
	local token file bytes
	token="$1"
	file="/tmp/ikev2-manager-dns-segment-$token.in"
	case "$token" in '' | *[!A-Za-z0-9-]*) die 'Invalid DNS segment input token' ;; esac
	[ -f "$file" ] && [ ! -L "$file" ] || die 'DNS segment input is missing'
	bytes="$(wc -c <"$file" | tr -d ' ')"
	case "$bytes" in '' | *[!0-9]*) rm -f "$file"; die 'Invalid DNS segment input size' ;; esac
	[ "$bytes" -le 16384 ] || { rm -f "$file"; die 'DNS segment input is too large'; }
	chmod 600 "$file" || die 'Unable to protect DNS segment input'
	start_action dns-segment "$file"
}

dns_apply() {
	ensure_dns_section
	managed="$1"
	protocol="$2"
	selected_protocol="$protocol"
	provider="$3"
	upstream_mode="$4"
	upstream="$(normalize_list "$5")"
	bootstrap="$(normalize_list "$6")"
	fallback="$(normalize_list "$7")"
	wan_fallback="${8:-0}"
	via_singbox="${9:-$(defaultv dns via_singbox 0)}"
	https_compat="${10:-$(defaultv dns https_compat 0)}"
	[ "$managed" = 0 ] || [ "$managed" = 1 ] || die 'Invalid DNS management mode'
	[ "$wan_fallback" = 0 ] || [ "$wan_fallback" = 1 ] ||
		die 'Invalid WAN DNS fallback state'
	[ "$via_singbox" = 0 ] || [ "$via_singbox" = 1 ] ||
		die 'Invalid DNS resolution path'
	[ "$https_compat" = 0 ] || [ "$https_compat" = 1 ] ||
		die 'Invalid DNS browser compatibility mode'
	[ "$managed" = 0 ] || valid_name "$provider" || die 'Invalid DNS provider'
	fakeip_active=0
	if [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		fakeip_active=1
	fi

	if [ "$managed" = 0 ]; then
		if [ -x /etc/init.d/ikev2-dns-segments ]; then
			/etc/init.d/ikev2-dns-segments stop >/dev/null 2>&1 || true
			/etc/init.d/ikev2-dns-segments disable >/dev/null 2>&1 || true
		fi
		if [ "$(defaultv dns saved 0)" = 1 ] && [ -d "$dns_original_dir" ]; then
			repair_dns_original_snapshot ||
				die 'Saved original DNS state is incomplete; managed DNS remains configured'
			rollback="$(mktemp -d /tmp/ikev2-manager-dns-disable-rollback-XXXXXX)" ||
				die 'Unable to create a DNS rollback snapshot'
			save_dns_state "$rollback" || {
				rm -rf "$rollback"
				die 'Unable to snapshot the current DNS configuration'
			}
			uci export "$config" >"$rollback/$config.uci" || {
				rm -rf "$rollback"
				die 'Unable to snapshot application DNS settings'
			}
			if [ "$fakeip_active" = 1 ] &&
			   ! /usr/libexec/ikev2-domain-router snapshot "$rollback/domain-router"; then
				rm -rf "$rollback"
				die 'Unable to snapshot the active FakeIP resolver runtime'
			fi
			dns_rollback_active=1
			trap abort_dns_transaction EXIT INT TERM HUP
			# The resolver is rendered from these settings, so they go first:
			# rendered while still managed, it kept routing segment names to
			# the workers stopped above. A failure imports the snapshot.
			uci set "$config.dns.managed=0" &&
				uci set "$config.dns.via_singbox=$via_singbox" &&
				uci set "$config.dns.https_compat=$https_compat" &&
				uci commit "$config" || die 'Unable to save the DNS settings'
			if ! restore_dns_state "$dns_original_dir" "$([ "$fakeip_active" = 1 ] && echo 0 || echo 1)" options ||
			   { [ "$fakeip_active" = 1 ] && ! /usr/libexec/ikev2-domain-router adopt-upstream; } ||
			   ! dns_query_ok; then
				if rollback_dns_transaction; then
					die 'Original DNS could not be restored safely; managed DNS remains configured'
				fi
				die 'Original DNS restore failed and automatic rollback was incomplete'
			fi
		elif [ "$fakeip_active" = 1 ]; then
			dns_path_apply "$via_singbox" "$https_compat"
		fi
		uci set "$config.dns.managed=0"
		uci set "$config.dns.saved=0"
		uci set "$config.dns.via_singbox=$via_singbox"
		uci set "$config.dns.https_compat=$https_compat"
		uci commit "$config"
		dns_query_ok || die 'Restored DNS configuration is not resolving'
		if [ "${dns_rollback_active:-0}" = 1 ]; then
			dns_rollback_active=0
			trap - EXIT INT TERM HUP
			rm -rf "$rollback"
		fi
		rm -rf "$dns_original_dir"
		return 0
	fi

	case "$selected_protocol" in
		udp | tcp | dot | doh | doh3 | h3 | doq | dnscrypt) ;;
		*) die 'Unsupported DNS protocol' ;;
	esac
	case "$upstream_mode" in
		load_balance | parallel | fastest_addr) ;;
		*) die 'Unsupported DNS upstream mode' ;;
	esac
	# The primary group may mix transports, exactly as the fallback group already
	# does. Blocking is applied per protocol per provider, so a group combining
	# DoH, DoQ and DNSCrypt survives what a single-protocol group cannot.
	# dnsproxy parses each upstream by its own scheme; the protocol field now
	# selects the interface preset and the HTTP/3 flag, not the whole group.
	valid_dns_endpoint_list_any "$upstream" ||
		die 'Invalid DNS upstream'
	valid_dns_bootstrap_list "$bootstrap" ||
		die 'Bootstrap DNS must contain IPv4:port entries or DoH/DoT/DoQ endpoints with a literal IPv4 address'
	if [ -n "$fallback" ]; then
		valid_dns_endpoint_list_any "$fallback" ||
			die 'Invalid fallback DNS endpoint'
	fi
	# Retrying the same endpoint as both primary and fallback doubles the outage
	# delay without adding a recovery path. Preserve only independent fallbacks.
	fallback="$(list_without "$fallback" "$upstream")"
	wan_fallback_endpoints=''
	if [ "$wan_fallback" = 1 ]; then
		wan_fallback_candidates="$(wan_dns_fallbacks)"
		[ -n "$wan_fallback_candidates" ] ||
			die 'WAN did not provide a usable IPv4 DNS server'
		wan_fallback_endpoints="$(dns_wan_reachable_fallbacks "$wan_fallback_candidates")"
		[ -n "$wan_fallback_endpoints" ] ||
			die 'WAN DNS servers did not answer the validation query'
	fi
	effective_fallback="$(list_without "$fallback $wan_fallback_endpoints" '')"
	effective_fallback="$(list_without "$effective_fallback" "$upstream")"
	command -v dnsproxy >/dev/null 2>&1 || die 'dnsproxy is not installed'
	validate_dns_segments || die 'A destination DNS segment is invalid or reuses a listener port'
	# Prove the recovery path before committing to it. Applying a configuration
	# whose fallback group cannot answer installs a ladder with no bottom rung.
	if [ -n "$effective_fallback" ]; then
		if dns_group_answers "$effective_fallback" "$bootstrap"; then
			fallback_verified="$(date +%s)"
		else
			die 'The fallback resolver group did not answer; it cannot recover a failed primary group'
		fi
	else
		fallback_verified=''
	fi

	ensure_dns_original || die 'Unable to save the original DNS configuration'
	rollback="$(mktemp -d /tmp/ikev2-manager-dns-rollback-XXXXXX)" ||
		die 'Unable to create a DNS rollback snapshot'
	save_dns_state "$rollback" || {
		rm -rf "$rollback"
		die 'Unable to snapshot the current DNS configuration'
	}
	uci export "$config" >"$rollback/$config.uci" || {
		rm -rf "$rollback"
		die 'Unable to snapshot application DNS settings'
	}
	if [ "$fakeip_active" = 1 ] &&
	   ! /usr/libexec/ikev2-domain-router snapshot "$rollback/domain-router"; then
		rm -rf "$rollback"
		die 'Unable to snapshot the active FakeIP resolver runtime'
	fi
	dns_rollback_active=1
	trap abort_dns_transaction EXIT INT TERM HUP

	uci -q get dnsproxy.global >/dev/null 2>&1 ||
		uci set dnsproxy.global=dnsproxy
	uci -q get dnsproxy.servers >/dev/null 2>&1 ||
		uci set dnsproxy.servers=dnsproxy
	uci -q get dnsproxy.cache >/dev/null 2>&1 ||
		uci set dnsproxy.cache=cache
	uci set dnsproxy.global.enabled='1'
	uci set dnsproxy.global.http3="$([ "$selected_protocol" = doh3 ] && echo 1 || echo 0)"
	uci set dnsproxy.global.insecure='0'
	runtime_timeout="$(dns_runtime_timeout "$effective_fallback")"
	uci set dnsproxy.global.timeout="$runtime_timeout"
	uci set dnsproxy.global.upstream_mode="$upstream_mode"
	set_uci_list dnsproxy global listen_addr '127.0.0.1'
	set_uci_list dnsproxy global listen_port '5453'
	combined_upstream="$(dns_combined_upstreams "$upstream")"
	set_uci_list dnsproxy servers upstream "$combined_upstream"
	set_uci_list dnsproxy servers bootstrap "$bootstrap"
	set_uci_list dnsproxy servers fallback "$effective_fallback"
	# dnsmasq owns the cache in standard mode and sing-box owns it in Reliable
	# mode.  A second optimistic cache here can retain a transient SERVFAIL and
	# amplify it through every client, especially through a destination segment.
	uci set dnsproxy.cache.enabled='0'
	uci set dnsproxy.cache.cache_optimistic='0'
	uci set dnsproxy.cache.size='65535'
	uci commit dnsproxy

	if [ "$fakeip_active" = 1 ]; then
		uci set "$config.domains.prev_noresolv=1"
		uci -q delete "$config.domains.prev_server" || true
		uci add_list "$config.domains.prev_server=127.0.0.1#5453"
	else
		uci set dhcp.@dnsmasq[0].noresolv='1'
		dnsmasq_upstream="$(dnsmasq_combined_servers '127.0.0.1#5453')"
		set_uci_list dhcp '@dnsmasq[0]' server "$dnsmasq_upstream"
		uci commit dhcp
	fi

	uci set "$config.dns.managed=1"
	uci set "$config.dns.protocol=$selected_protocol"
	uci set "$config.dns.provider=$provider"
	uci set "$config.dns.upstream_mode=$upstream_mode"
	uci set "$config.dns.upstream=$upstream"
	uci set "$config.dns.bootstrap=$bootstrap"
	uci set "$config.dns.fallback=$fallback"
	uci set "$config.dns.wan_fallback=$wan_fallback"
	uci set "$config.dns.via_singbox=$via_singbox"
	uci set "$config.dns.https_compat=$https_compat"
	# When the recovery path was last proven to answer, so the interface can
	# show evidence instead of an assumption.
	uci set "$config.dns.fallback_verified=$fallback_verified"
	uci commit "$config"

	if ! /etc/init.d/ikev2-dns-segments enable >/dev/null 2>&1 ||
	   ! /etc/init.d/ikev2-dns-segments restart >/dev/null 2>&1 ||
	   ! /etc/init.d/dnsproxy enable >/dev/null 2>&1 ||
	   ! /etc/init.d/dnsproxy restart >/dev/null 2>&1 ||
		{ [ "$fakeip_active" = 1 ] &&
			! /usr/libexec/ikev2-domain-router refresh; } ||
		{ [ "$fakeip_active" != 1 ] &&
			! /etc/init.d/dnsmasq restart >/dev/null 2>&1; } ||
		! dns_query_ok || ! dns_segments_check; then
		if rollback_dns_transaction; then
			die 'DNS validation failed; previous resolver configuration was restored'
		fi
		die 'DNS validation failed and automatic resolver rollback was incomplete'
	fi
	dns_rollback_active=0
	trap - EXIT INT TERM HUP
	rm -rf "$rollback"
}

dns_set_async() {
	[ -f "$dns_input_file" ] || die 'DNS settings input is missing'
	[ ! -L "$dns_input_file" ] || {
		rm -f "$dns_input_file"
		die 'DNS settings input must not be a symbolic link'
	}
	input_bytes="$(wc -c <"$dns_input_file" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) rm -f "$dns_input_file"; die 'Invalid DNS input size' ;; esac
	[ "$input_bytes" -le 16384 ] || {
		rm -f "$dns_input_file"
		die 'DNS settings input is too large'
	}
	chmod 600 "$dns_input_file" || die 'Unable to protect DNS settings input'
	[ -z "$(sed -n '11p' "$dns_input_file")" ] || {
		rm -f "$dns_input_file"
		die 'DNS settings input has unexpected extra fields'
	}
	{
		IFS= read -r managed
		IFS= read -r protocol
		IFS= read -r provider
		IFS= read -r upstream_mode
		IFS= read -r upstream
		IFS= read -r bootstrap
		IFS= read -r fallback || true
		IFS= read -r wan_fallback || true
		IFS= read -r via_singbox || true
		IFS= read -r https_compat || true
	} <"$dns_input_file"
	rm -f "$dns_input_file"
	# A page that predates the resolution path does not send it.
	start_action dns-set "$managed" "$protocol" "$provider" "$upstream_mode" \
		"$upstream" "$bootstrap" "$fallback" "${wan_fallback:-0}" \
		"${via_singbox:-$(defaultv dns via_singbox 0)}" \
		"${https_compat:-$(defaultv dns https_compat 0)}"
}
