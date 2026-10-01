#!/bin/sh
# The application's own policy routing, replacing the pbr package:
#
#   ikev2-routing sync     install or repair; a no-op when nothing changed
#   ikev2-routing sync-all this, device routing and Discord voice, each one
#                          even when one before it fails
#   ikev2-routing check    whether the installed runtime is current
#   ikev2-routing stop     remove everything this owns
#   ikev2-routing status   key=value lines for reports
#   ikev2-routing dump     save the domain sets to /var/run
#   ikev2-routing persist  save them to flash, for the next boot
#
# Selected destinations are marked in an nftables table of their own and
# routed by ip rules on bits no other part of the router uses:
#
#   mark 0x01000000/0x0f000000  table 1601  the tunnel, unreachable without it
#   mark 0x02000000/0x0f000000  table 1602  the WAN, for exclusions
#
# IPv6 destinations of a selected name are marked too, into an IPv6 table
# holding only an unreachable default: the tunnel is IPv4-only, so they fail
# closed and clients fall back to IPv4.
#
# This is the only routing the application does. When matching by address,
# dnsmasq fills the domain sets through an nftset file of ours. A router that
# routed through PBR before keeps PBR's copy of our policies until its next
# Apply retires them; until then both route the same destinations, ours ahead
# of PBR's, and the domain sets are copied from PBR's.

set -u

config='ikev2-manager'
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
ip_bin="${IKEV2_IP:-ip}"
ucode_bin="${IKEV2_UCODE:-ucode}"
table="${IKEV2_ROUTING_TABLE:-ikev2_routing}"
state_file="${IKEV2_ROUTING_STATE:-/var/run/ikev2-routing.state}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
service_file="${IKEV2_SERVICE_CIDRS:-/etc/pbr-ikev2-service-cidrs.txt}"
sa_helper="${IKEV2_SA_HELPER:-/usr/libexec/ikev2-sa}"
system_helper="${IKEV2_SYSTEM_HELPER:-/usr/libexec/ikev2-manager-system}"
vip_file="${IKEV2_VIP_FILE:-/var/run/ikev2-vip4}"
domain_file="${IKEV2_DOMAIN_LIST:-/etc/pbr-ikev2-domains.txt}"
dump_dir="${IKEV2_ROUTING_DUMP_DIR:-/var/run}"
persist_dir="${IKEV2_ROUTING_PERSIST_DIR:-/etc/ikev2-manager}"
dnsmasq_file_name='ikev2-routing'
dnsmasq_init="${IKEV2_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
device_routing_helper="${IKEV2_DEVICE_ROUTING_HELPER:-/usr/libexec/ikev2-device-routing}"
discord_voice_helper="${IKEV2_DISCORD_VOICE_HELPER:-/usr/libexec/ikev2-discord-voice}"

mark_mask=0x0f000000
tunnel_mark=0x01000000
# ip prints marks without leading zeros.
rule_mask=0xf000000
rule_tunnel_mark=0x1000000
# The WAN mark, 0x02000000, is for the exclusions moved here next.
rule_wan_mark=0x2000000
tunnel_table=1601
wan_table=1602
# Ahead of PBR (29997-30000), after FakeIP delivery (11000) and every rule the
# system and other VPNs install below 11000.
rule_main=28000
rule_tunnel=28001
rule_wan=28002
# The domain sets are filled by dnsmasq when matching by address, or copied
# from PBR in overlay mode. With FakeIP sing-box routes by name and they stay
# empty.
runtime_volatile_sets='dst4 dst6'
# An address dnsmasq answered with stays this long after its last answer: a
# client may keep using it from its own cache, and the kernel moves the
# expiry on whenever dnsmasq adds it again. Sets without a timeout kept every
# address for good, including addresses a CDN had since given to other sites.
dst_timeout=7d

. "$runtime_lib_dir/nft-runtime.sh"
. "$runtime_lib_dir/devices.sh"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

# Selected domains are recognised by name (FakeIP) or by address.
fakeip_engine() {
	[ "$(uci -q get "$config.domains.engine" 2>/dev/null || echo nftset)" = fakeip ]
}


active() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ]
}

# A pause keeps these rules: what they send to the tunnel is refused there
# (ikev2_pause, installed by the system helper), so nothing selected leaves
# through WAN while the tunnel is not used.

valid_ifname() {
	[ -n "${1:-}" ] && printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.:@-]+$'
}

# IPv4 networks and addresses of FILE, one per line, comments dropped.
address_lines() {
	[ -r "$1" ] || return 0
	awk '
		{ sub(/#.*/, ""); gsub(/[ \t\r]/, "") }
		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ { print }
	' "$1"
}

elements() {
	awk 'BEGIN { first = 1 } NF { if (!first) printf ", "; printf "%s", $0; first = 0 }' "$1"
}

quoted_elements() {
	awk 'BEGIN { first = 1 } NF { if (!first) printf ", "; printf "\"%s\"", $0; first = 0 }' "$1"
}

# The WAN's IPv4 default, as "via GATEWAY dev DEVICE" or "dev DEVICE".
wan_default() {
	local interface status device gateway
	interface="$(uci -q get "$config.globals.wan_interface" 2>/dev/null || echo wan)"
	status="$(ubus call "network.interface.$interface" status 2>/dev/null || true)"
	device="$(printf '%s' "$status" | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	valid_ifname "$device" || return 1
	gateway="$(printf '%s' "$status" |
		jsonfilter -e '@.route[@.target="0.0.0.0" && @.mask=0].nexthop' 2>/dev/null | head -n1)"
	case "$gateway" in
		'' | 0.0.0.0) printf 'dev %s\n' "$device" ;;
		*.*.*.*) printf 'via %s dev %s\n' "$gateway" "$device" ;;
		*) return 1 ;;
	esac
}

tunnel_ready() {
	[ -s "$vip_file" ] || return 1
	"$ip_bin" link show ipsec-out 2>/dev/null | grep -q 'UP' || return 1
	"$sa_helper" installed proxy-out proxy4 || return 1
	"$ip_bin" -4 addr show dev ipsec-out 2>/dev/null | grep -Fq "$(cat "$vip_file")/"
}

ensure_rule() {
	local family="$1" priority="$2" selector="$3"
	"$ip_bin" -"$family" rule show 2>/dev/null |
		grep -Eq "^$priority:[[:space:]]+from all $selector\$" && return 0
	while "$ip_bin" -"$family" rule del priority "$priority" 2>/dev/null; do :; done
	# shellcheck disable=SC2086
	"$ip_bin" -"$family" rule add priority "$priority" $selector
}

delete_rules() {
	local family priority
	for family in 4 6; do
		for priority in "$rule_main" "$rule_tunnel" "$rule_wan"; do
			while "$ip_bin" -"$family" rule del priority "$priority" 2>/dev/null; do :; done
		done
	done
}

# Whether a route listing has a line that begins with the given words.
route_listed() {
	printf '%s\n' "$1" | awk -v want="$2" 'index($0 " ", want " ") == 1 { found = 1 } END { exit !found }'
}

# Routes first: a rule pointing at a table without its unreachable default
# would let marked traffic fall through to the WAN. A route already in place
# is not written again: every write is announced to whatever watches the
# routing tables, and the watcher syncs on every pass.
sync_routes() {
	local lan subnet inbound wan routes4 routes6
	routes4="$("$ip_bin" -4 route show table "$tunnel_table" 2>/dev/null || true)"
	routes6="$("$ip_bin" -6 route show table "$tunnel_table" 2>/dev/null || true)"
	printf '%s\n' "$routes4" | grep -Eq '^unreachable default .*metric 32767( |$)' ||
		"$ip_bin" -4 route replace unreachable default metric 32767 table "$tunnel_table" || return 1
	printf '%s\n' "$routes6" | grep -Eq '^unreachable default .*metric 32767( |$)' ||
		"$ip_bin" -6 route replace unreachable default metric 32767 table "$tunnel_table" 2>/dev/null || :
	# Replies to local and inbound clients stay local whatever is marked.
	while IFS= read -r lan; do
		subnet="$("$ip_bin" -4 route show dev "$lan" scope link 2>/dev/null |
			awk '$1 ~ /^[0-9.]+\/[0-9]+$/ { print $1; exit }')"
		[ -n "$subnet" ] || continue
		route_listed "$routes4" "$subnet dev $lan" ||
			"$ip_bin" -4 route replace "$subnet" dev "$lan" table "$tunnel_table" || return 1
	done <"$work/sources"
	if [ "$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)" = 1 ]; then
		inbound="$("$system_helper" gateway-network 2>/dev/null || true)"
		[ -z "$inbound" ] || route_listed "$routes4" "$inbound dev ipsec-in" ||
			"$ip_bin" -4 route replace "$inbound" dev ipsec-in table "$tunnel_table" || return 1
	fi
	if tunnel_ready; then
		printf '%s\n' "$routes4" | grep -Eq '^default dev ipsec-out( .*)? metric 10( |$)' ||
			"$ip_bin" -4 route replace default dev ipsec-out metric 10 table "$tunnel_table" || return 1
	elif printf '%s\n' "$routes4" | grep -q '^default dev ipsec-out'; then
		"$ip_bin" -4 route del default dev ipsec-out metric 10 table "$tunnel_table" || return 1
	fi
	if wan="$(wan_default)"; then
		route_listed "$("$ip_bin" -4 route show table "$wan_table" 2>/dev/null || true)" "default $wan" ||
			# shellcheck disable=SC2086
			"$ip_bin" -4 route replace default $wan table "$wan_table" || return 1
	fi
	# A WAN without a default keeps the last one: exclusions then resume the
	# moment it returns instead of taking whatever else routes by default.
}

# Every rule this installs, exactly. Other software deletes rules by pattern:
# stopping PBR removes each "lookup main suppress_prefixlength" rule.
rules_present() {
	local rules4 rules6
	rules4="$("$ip_bin" -4 rule show 2>/dev/null)"
	rules6="$("$ip_bin" -6 rule show 2>/dev/null)"
	printf '%s\n' "$rules4" | grep -Eq "^$rule_main:[[:space:]]+from all lookup main suppress_prefixlength 1\$" &&
		printf '%s\n' "$rules4" | grep -Eq "^$rule_tunnel:[[:space:]]+from all fwmark $rule_tunnel_mark/$rule_mask lookup $tunnel_table\$" &&
		printf '%s\n' "$rules4" | grep -Eq "^$rule_wan:[[:space:]]+from all fwmark $rule_wan_mark/$rule_mask lookup $wan_table\$" &&
		printf '%s\n' "$rules6" | grep -Eq "^$rule_main:[[:space:]]+from all lookup main suppress_prefixlength 1\$" &&
		printf '%s\n' "$rules6" | grep -Eq "^$rule_tunnel:[[:space:]]+from all fwmark $rule_tunnel_mark/$rule_mask lookup $tunnel_table\$"
}

sync_rules() {
	ensure_rule 4 "$rule_main" 'lookup main suppress_prefixlength 1' &&
		ensure_rule 4 "$rule_tunnel" "fwmark $rule_tunnel_mark/$rule_mask lookup $tunnel_table" &&
		ensure_rule 4 "$rule_wan" "fwmark $rule_wan_mark/$rule_mask lookup $wan_table" &&
		ensure_rule 6 "$rule_main" 'lookup main suppress_prefixlength 1' &&
		ensure_rule 6 "$rule_tunnel" "fwmark $rule_tunnel_mark/$rule_mask lookup $tunnel_table"
}

# The table is changed in place, never recreated: the domain sets hold what
# dnsmasq learned, and a new table would start them empty.
write_ruleset() {
	local set_mark="counter meta mark set meta mark & 0xf0ffffff | $tunnel_mark" family
	printf 'add table inet %s\n' "$table"
	printf 'add chain inet %s ikev2_manager_owned { comment "IKEv2 Manager policy routing"; }\n' "$table"
	# After every hook that decides a packet's path: the device table (-152),
	# PBR and fw4 (-150) and the inbound users' WAN exclusion (-149).
	printf 'add chain inet %s prerouting { type filter hook prerouting priority mangle + 2; policy accept; }\n' "$table"
	printf 'flush chain inet %s prerouting\n' "$table"
	# nft cannot give an existing set a timeout. A set from an earlier release
	# is recreated, which drops what it held; restore_sets refills it.
	for family in 4 6; do
		dst_set_outdated "$family" || continue
		printf 'delete set inet %s dst%s\n' "$table" "$family"
	done
	printf 'add set inet %s src_ifaces { type ifname; }\n' "$table"
	printf 'add set inet %s src4 { type ipv4_addr; flags interval; auto-merge; }\n' "$table"
	printf 'add set inet %s service4 { type ipv4_addr; flags interval; auto-merge; }\n' "$table"
	# The keyword is an argument so that no line reads as a call of BusyBox's
	# optional timeout applet to scripts/check-busybox-compat.sh.
	for family in 4 6; do
		printf 'add set inet %s dst%s { type ipv%s_addr; flags interval, timeout; %s %s; auto-merge; }\n' \
			"$table" "$family" "$family" timeout "$dst_timeout"
	done
	for name in src_ifaces src4 service4; do
		printf 'flush set inet %s %s\n' "$table" "$name"
	done
	# Whatever an address engine or PBR left there would be routed by address
	# for good, with nothing to correct it.
	if fakeip_engine; then
		printf 'flush set inet %s dst4\nflush set inet %s dst6\n' "$table" "$table"
	fi
	[ ! -s "$work/sources" ] ||
		printf 'add element inet %s src_ifaces { %s }\n' "$table" "$(quoted_elements "$work/sources")"
	[ ! -s "$work/src4" ] ||
		printf 'add element inet %s src4 { %s }\n' "$table" "$(elements "$work/src4")"
	[ ! -s "$work/service4" ] ||
		printf 'add element inet %s service4 { %s }\n' "$table" "$(elements "$work/service4")"
	# A mark of ours is final. So is any other in the bits the rest of the
	# router uses - a WAN exclusion, FakeIP delivery, another VPN - except
	# PBR's own tunnel mark, which only says the same thing as ours.
	printf 'add rule inet %s prerouting meta mark & %s != 0 return\n' "$table" "$mark_mask"
	if [ -n "$pbr_tunnel" ]; then
		printf 'add rule inet %s prerouting meta mark & 0x00ff0000 != 0 meta mark & 0x00ff0000 != %s return\n' \
			"$table" "$pbr_tunnel"
	else
		printf 'add rule inet %s prerouting meta mark & 0x00ff0000 != 0 return\n' "$table"
	fi
	for match in 'iifname @src_ifaces' 'ip saddr @src4'; do
		fakeip_engine ||
			printf 'add rule inet %s prerouting %s ip daddr @dst4 %s\n' "$table" "$match" "$set_mark"
		printf 'add rule inet %s prerouting %s ip daddr @service4 %s\n' "$table" "$match" "$set_mark"
	done
	fakeip_engine ||
		printf 'add rule inet %s prerouting iifname @src_ifaces ip6 daddr @dst6 %s\n' "$table" "$set_mark"
}

# Whether destination set dst4 or dst6 predates the timeout it now carries.
dst_set_outdated() {
	local listing
	listing="$("$nft_bin" list set inet "$table" "dst$1" 2>/dev/null)" || return 1
	! printf '%s\n' "$listing" | grep -Eq "^[[:space:]]*timeout $dst_timeout\$"
}

# In overlay mode the domain sets follow PBR's, which dnsmasq fills.
copy_pbr_sets() {
	local family set elements
	! fakeip_engine || return 0
	for family in 4 6; do
		set="$("$nft_bin" list table inet fw4 2>/dev/null |
			sed -n "s/^[[:space:]]*set \(pbr_ikev2out_${family}_dst_ip_[^[:space:]]*\) {.*/\1/p" |
			grep -v '_user$' | head -n1)"
		[ -n "$set" ] || continue
		elements="$("$nft_bin" list set inet fw4 "$set" 2>/dev/null |
			sed -n '/elements = {/,/}/p' | tr -d '\n\t' |
			sed 's/.*{//; s/}.*//; s/ //g')"
		[ -z "$elements" ] ||
			"$nft_bin" add element inet "$table" "dst$family" "{ $elements }" 2>/dev/null || :
	done
}

# One confdir per dnsmasq instance, where the init script points it.
dnsmasq_confdirs() {
	local section confdir
	for section in $(uci -X show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p'); do
		confdir="$(uci -q get "dhcp.$section.confdir" 2>/dev/null || echo "/tmp/dnsmasq.$section.d")"
		confdir="${confdir%%,*}"
		case "$confdir" in /*) printf '%s\n' "$confdir" ;; esac
	done
}

# dnsmasq adds every address it answers for a selected name to the domain
# sets. Only Standard mode needs it: in reliable mode sing-box answers those
# names itself.
render_nftset() {
	! fakeip_engine || return 0
	# Until an Apply retires it, PBR's domain policy still has dnsmasq fill
	# its sets, which are copied here; two nftset lines for one name would
	# leave which set dnsmasq fills to its parser.
	[ "$(uci -q get pbr.ikev2pbr_domains.enabled 2>/dev/null || echo 0)" != 1 ] || return 0
	[ -r "$domain_file" ] || return 0
	awk -v table="$table" '
		{ sub(/#.*/, ""); gsub(/[ \t\r]/, ""); $0 = tolower($0) }
		/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/ && !/\.\./ {
			printf "nftset=/%s/4#inet#%s#dst4,6#inet#%s#dst6\n", $0, table, table
		}
	' "$domain_file"
}

# Writes or removes the nftset file in each instance's confdir; dnsmasq reads
# it only on start, so a change restarts it.
sync_dnsmasq() {
	local content dir file changed=0
	content="$work/nftset.conf"
	render_nftset >"$content" || return 1
	for dir in $(dnsmasq_confdirs); do
		file="$dir/$dnsmasq_file_name"
		if [ -s "$content" ]; then
			cmp -s "$content" "$file" && continue
			mkdir -p "$dir" && cp "$content" "$file.new" && mv "$file.new" "$file" || return 1
			changed=1
		elif [ -e "$file" ]; then
			rm -f "$file"
			changed=1
		fi
	done
	[ "$changed" = 0 ] || "$dnsmasq_init" restart >/dev/null 2>&1
}

remove_dnsmasq() {
	local dir changed=0
	for dir in $(dnsmasq_confdirs); do
		[ -e "$dir/$dnsmasq_file_name" ] || continue
		rm -f "$dir/$dnsmasq_file_name"
		changed=1
	done
	[ "$changed" = 0 ] || "$dnsmasq_init" restart >/dev/null 2>&1 || :
}

# One element per line, without the timeout and expiry nft prints after each.
set_elements() {
	"$nft_bin" list set inet "$table" "$1" 2>/dev/null |
		sed -n '/elements = {/,/}/p' | tr -d '\n\t' |
		sed -E 's/.*\{//; s/\}.*//; s/ (timeout|expires) [0-9a-z.]+//g' |
		tr ',' '\n' | tr -d ' ' | grep -v '^$'
}

# Copies of the destination sets mean nothing when sing-box routes by name.
drop_set_dumps() {
	rm -f "$dump_dir/ikev2-routing-dst4.dump" "$dump_dir/ikev2-routing-dst6.dump" \
		"$persist_dir/routing-dst4.dump" "$persist_dir/routing-dst6.dump"
}

# What dnsmasq taught the sets survives a firewall reload and, from the
# copy saved on shutdown, a reboot: clients with a warm DNS cache would
# otherwise reach selected names directly until they ask again.
dump_sets() {
	local family
	if fakeip_engine; then
		drop_set_dumps
		return 0
	fi
	runtime_owned || return 0
	for family in 4 6; do
		set_elements "dst$family" >"$dump_dir/ikev2-routing-dst$family.dump.new" || :
		if [ -s "$dump_dir/ikev2-routing-dst$family.dump.new" ]; then
			mv "$dump_dir/ikev2-routing-dst$family.dump.new" "$dump_dir/ikev2-routing-dst$family.dump"
		else
			rm -f "$dump_dir/ikev2-routing-dst$family.dump.new"
		fi
	done
}

persist_sets() {
	local family
	dump_sets
	! fakeip_engine || return 0
	mkdir -p "$persist_dir"
	for family in 4 6; do
		[ -s "$dump_dir/ikev2-routing-dst$family.dump" ] || continue
		cp "$dump_dir/ikev2-routing-dst$family.dump" "$persist_dir/routing-dst$family.dump.new" &&
			chmod 600 "$persist_dir/routing-dst$family.dump.new" &&
			mv "$persist_dir/routing-dst$family.dump.new" "$persist_dir/routing-dst$family.dump"
	done
}

restore_sets() {
	local family dump elements
	if fakeip_engine; then
		drop_set_dumps
		return 0
	fi
	for family in 4 6; do
		[ -z "$(set_elements "dst$family" | head -n1)" ] || continue
		dump="$dump_dir/ikev2-routing-dst$family.dump"
		[ -s "$dump" ] || dump="$persist_dir/routing-dst$family.dump"
		[ -s "$dump" ] || continue
		elements="$(tr '\n' ',' <"$dump" | sed 's/,$//')"
		[ -z "$elements" ] ||
			"$nft_bin" add element inet "$table" "dst$family" "{ $elements }" 2>/dev/null || :
	done
}

desired_state() {
	# Materialised first: in a pipeline the failure to resolve a protected
	# network was lost to sort's status, and routing went in with no sources,
	# every selected packet from that network leaving past the tunnel.
	device_source_devices >"$work/sources.raw" || return 1
	sort -u "$work/sources.raw" >"$work/sources" || return 1
	device_addresses domain >"$work/src4" || die 'Device routing configuration is not valid'
	address_lines "$service_file" | sort -u >"$work/service4"
	pbr_tunnel=''
	local values
	if values="$(mark_values "$(pbr_mark_rule pbr_ikev2out)")"; then
		pbr_tunnel="$(printf '0x%08x' "$(( ${values#* } & 0x00ff0000 ))")"
	fi
	signature="$({
		printf 'pbr=%s\nfakeip=%s\nsources\n' "$pbr_tunnel" \
			"$(fakeip_engine && echo 1 || echo 0)"
		cat "$work/sources"
		printf 'src4\n'
		cat "$work/src4"
		printf 'service4\n'
		cat "$work/service4"
	} | sha256sum | awk '{ print $1 }')"
}

sync_runtime() {
	if ! active; then
		# Called every watcher pass: nothing to stop costs one rule listing.
		[ -e "$state_file" ] || "$ip_bin" -4 rule show 2>/dev/null | grep -q "^$rule_tunnel:" ||
			runtime_exists || return 0
		stop_runtime
		return
	fi
	if runtime_exists && ! runtime_owned; then
		die "nft table '$table' is not owned by IKEv2 Manager"
	fi
	work="$(mktemp -d "${TMPDIR:-/tmp}/ikev2-routing.XXXXXX")" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	desired_state || return 1
	sync_routes || die 'Unable to install the policy routing tables'
	sync_rules || die 'Unable to install the policy routing rules'
	if ! runtime_owned || [ "$(sed -n '1p' "$state_file" 2>/dev/null)" != "$signature" ] ||
	   ! runtime_unchanged "$state_file"; then
		write_ruleset >"$work/rules.nft"
		"$nft_bin" -c -f "$work/rules.nft" >"$work/check.log" 2>&1 || {
			cat "$work/check.log" >&2
			die 'Policy routing nftables validation failed'
		}
		"$nft_bin" -f "$work/rules.nft" >/dev/null 2>&1 ||
			die 'Unable to install the policy routing nftables rules'
		record_runtime "$state_file" "$signature" ||
			die 'Unable to read back the installed policy routing rules'
	fi
	restore_sets
	# The switch from PBR keeps what its sets learned; in overlay mode they
	# are the only source.
	copy_pbr_sets
	sync_dnsmasq || die 'Unable to update the dnsmasq destination sets'
	rm -rf "$work"
	trap - EXIT INT TERM
}

check_runtime() {
	local dir
	active || {
		! runtime_exists && ! "$ip_bin" -4 rule show 2>/dev/null | grep -q "^$rule_tunnel:"
		return
	}
	runtime_owned || return 1
	work="$(mktemp -d "${TMPDIR:-/tmp}/ikev2-routing-check.XXXXXX")" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	desired_state 2>/dev/null || return 1
	[ "$(sed -n '1p' "$state_file" 2>/dev/null)" = "$signature" ] || return 1
	runtime_unchanged "$state_file" || return 1
	render_nftset >"$work/nftset.conf" || return 1
	for dir in $(dnsmasq_confdirs); do
		if [ -s "$work/nftset.conf" ]; then
			cmp -s "$work/nftset.conf" "$dir/$dnsmasq_file_name" || return 1
		else
			[ ! -e "$dir/$dnsmasq_file_name" ] || return 1
		fi
	done
	rules_present || return 1
	"$ip_bin" -4 route show table "$tunnel_table" 2>/dev/null |
		grep -Eq '^unreachable default .*metric 32767' || return 1
	rm -rf "$work"
	trap - EXIT INT TERM
}

stop_runtime() {
	remove_dnsmasq
	delete_rules
	if runtime_exists; then
		runtime_owned || die "nft table '$table' is not owned by IKEv2 Manager"
		"$nft_bin" delete table inet "$table" >/dev/null 2>&1 || return 1
	fi
	"$ip_bin" -4 route flush table "$tunnel_table" 2>/dev/null || :
	"$ip_bin" -6 route flush table "$tunnel_table" 2>/dev/null || :
	"$ip_bin" -4 route flush table "$wan_table" 2>/dev/null || :
	rm -f "$state_file"
}

status_runtime() {
	printf 'backend=native\n'
	if runtime_owned; then printf 'runtime=installed\n'; else printf 'runtime=absent\n'; fi
	if tunnel_ready; then printf 'tunnel=up\n'; else printf 'tunnel=down\n'; fi
}

# Everything that routes by the marks: policy routing first, so the rules
# exist before device routing and Discord voice mark packets for them. One
# that fails does not keep the others from being synced; a failing Discord
# voice sync once left policy routing uninstalled after every boot.
sync_all() {
	local failed=0
	( sync_runtime ) || failed=1
	[ ! -x "$device_routing_helper" ] || "$device_routing_helper" sync >/dev/null 2>&1 || failed=1
	[ ! -x "$discord_voice_helper" ] || "$discord_voice_helper" sync >/dev/null 2>&1 || failed=1
	return "$failed"
}

case "${1:-}" in
	sync) sync_runtime ;;
	sync-all) sync_all ;;
	check) check_runtime ;;
	stop) stop_runtime ;;
	status) status_runtime ;;
	dump) dump_sets ;;
	persist) persist_sets ;;
	*)
		printf '%s\n' 'usage: ikev2-routing {sync|sync-all|check|stop|status|dump|persist}' >&2
		exit 2
		;;
esac
