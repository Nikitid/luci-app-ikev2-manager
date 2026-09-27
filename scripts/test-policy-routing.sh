#!/bin/sh

# The application's own policy routing, which replaces the pbr package. It
# must fail closed, leave every decision the router already made alone, keep
# what dnsmasq learned across its own repairs, and stay out of the way until
# it is selected.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-routing.sh"
tmp="$(mktemp -d)"
finished=0
trap 'rm -rf "$tmp"; [ "$finished" = 1 ] || exit 1' EXIT
trap 'exit 1' INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

S="$tmp/state"
mkdir -p "$S" "$tmp/bin"
export S

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = -q ] && shift
case "$*" in
	'get ikev2-manager.globals.configured') echo 1 ;;
	'get ikev2-manager.globals.routing_backend') cat "$S/backend" 2>/dev/null || exit 1 ;;
	'get ikev2-manager.domains.paused') cat "$S/paused" 2>/dev/null || echo 0 ;;
	'get ikev2-manager.globals.source_interface') echo lan ;;
	'get ikev2-manager.globals.wan_interface') echo wan ;;
	'get ikev2-manager.server.enabled') echo 1 ;;
	'get ikev2-manager.globals.source_include_vpn') echo 1 ;;
	'get ikev2-manager.globals.device_schema') echo 2 ;;
	'show ikev2-manager') : ;;
	'get ikev2-manager.domains.engine') cat "$S/engine" 2>/dev/null || echo nftset ;;
	'-X show dhcp') printf 'dhcp.cfg01411c=dnsmasq\n' ;;
	'get pbr.ikev2pbr_domains.enabled') cat "$S/pbr-domains-policy" 2>/dev/null || exit 1 ;;
	'get dhcp.cfg01411c.confdir') printf '%s\n' "$S/dnsmasq.d" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/dnsmasq-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$S/dnsmasq.log"
EOF

cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
case "$2" in
	network.interface.lan) printf 'l3_device=br-lan\n' ;;
	network.interface.wan) [ -e "$S/wan-down" ] || printf 'l3_device=eth1\nnexthop=192.0.2.1\n' ;;
esac
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
case "$2" in
	'@.l3_device') sed -n 's/^l3_device=//p' ;;
	*nexthop) sed -n 's/^nexthop=//p' ;;
	*) : ;;
esac
EOF

# Routing state kept in files: rules as "PRIO:\tfrom all SELECTOR" lines,
# routes per family and table.
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
family=4
case "$1" in -4) shift ;; -6) family=6; shift ;; esac
rules="$S/rules$family"
touch "$rules"
case "$1 $2" in
	'rule show')
		[ "$family" = 4 ] && printf '29999:\tfrom all fwmark 0x20000/0xff0000 lookup pbr_ikev2out\n'
		cat "$rules"
		;;
	'rule add')
		shift 2
		[ "$1" = priority ] || exit 1
		prio="$2"; shift 2
		printf '%s:\tfrom all %s\n' "$prio" "$*" >>"$rules"
		sort -n "$rules" -o "$rules"
		;;
	'rule del')
		grep -q "^$4:" "$rules" || exit 2
		awk -v p="$4:" 'done || $1 != p { print; next } { done = 1 }' "$rules" >"$rules.new"
		mv "$rules.new" "$rules"
		;;
	'route replace')
		shift 2
		args="$*"
		table="${args##* table }"
		route="${args% table *}"
		file="$S/route$family-$table"
		touch "$file"
		key="$(printf '%s' "$route" | awk '{ print $1 }')"
		grep -v "^$key " "$file" >"$file.new" || :
		[ "$key" != default ] || grep -v '^default dev ipsec-out' "$file" | grep -v '^default via' >"$file.new" || :
		printf '%s\n' "$route" >>"$file.new"
		mv "$file.new" "$file"
		;;
	'route show')
		case "$3" in
			table) cat "$S/route$family-$4" 2>/dev/null || : ;;
			dev) [ "$4" = br-lan ] && printf '192.168.2.0/24 proto kernel scope link src 192.168.2.1\n' ;;
		esac
		;;
	'route del')
		shift 2
		args="$*"
		table="${args##* table }"
		file="$S/route$family-$table"
		grep -v "^${args% table *}\$" "$file" >"$file.new" || :
		mv "$file.new" "$file"
		;;
	'route flush') rm -f "$S/route$family-$4" ;;
	'link show') [ -e "$S/tunnel-down" ] || printf '9: ipsec-out: <NOARP,UP,LOWER_UP> mtu 1400\n' ;;
	'addr show') printf '    inet 10.20.20.10/32 scope global ipsec-out\n' ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/sa" <<'EOF'
#!/bin/sh
[ ! -e "$S/tunnel-down" ]
EOF
cat >"$tmp/bin/system" <<'EOF'
#!/bin/sh
[ "$1" = gateway-network ] && printf '10.20.30.0/24\n'
EOF

# nftables: the applied table is the last file given to -f, listed back as
# JSON with the handles and counters that change on every listing.
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list table inet ikev2_routing_test')
		[ -s "$S/nft.rules" ] || exit 1
		if grep -q ikev2_manager_owned "$S/nft.rules"; then
			printf 'table inet ikev2_routing_test {\n\tchain ikev2_manager_owned {\n\t}\n}\n'
		else
			printf 'table inet ikev2_routing_test {\n}\n'
		fi
		;;
	'-j list table inet ikev2_routing_test')
		[ -s "$S/nft.rules" ] || exit 1
		awk -v seed="$$" '
			BEGIN { srand(seed); printf "{\"nftables\": [{\"metainfo\": {}}, {\"table\": {\"name\": \"t\", \"handle\": %d}}", int(rand() * 999) }
			/^add element .* dst[46] / { next }
			NF { line = $0; gsub(/"/, "\\\"", line); printf ", {\"rule\": {\"handle\": %d, \"text\": \"%s\"}}", int(rand() * 999), line }
			END { print "]}" }
		' "$S/nft.rules"
		;;
	'list table inet fw4')
		printf '\tset pbr_ikev2out_4_dst_ip_ikev2pbr_domains {\n\tset pbr_ikev2out_4_dst_ip_user {\n'
		;;
	'list set inet fw4 pbr_ikev2out_4_dst_ip_ikev2pbr_domains')
		printf 'set x {\n\t\telements = { 203.0.113.5, 203.0.113.9 }\n\t}\n'
		;;
	'list set inet fw4 '*) : ;;
	'add element inet ikev2_routing_test dst'[46]' '*)
		printf '%s\n' "$*" >>"$S/nft.added"
		printf '%s\n' "$*" | sed 's/.*{//; s/}.*//' | tr ',' '\n' | tr -d ' ' | grep . >>"$S/$5"
		;;
	'list set inet ikev2_routing_test dst'[46])
		[ -s "$S/$5" ] || { printf 'set %s {\n}\n' "$5"; exit 0; }
		printf 'set %s {\n\t\telements = { %s }\n\t}\n' "$5" "$(sort -u "$S/$5" | paste -sd, - | sed 's/,/, /g')"
		;;
	'delete table inet ikev2_routing_test') rm -f "$S/nft.rules" ;;
	'-c -f '*) [ ! -e "$S/nft-reject" ] ;;
	'-f '*)
		if [ -s "$S/nft.rules" ] && grep -q '^flush chain' "$2"; then
			cat "$2" >"$S/nft.rules"
		else
			cp "$2" "$S/nft.rules"
		fi
		printf 'apply\n' >>"$S/nft.log"
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/"*

printf '# services\n203.0.113.0/24\n198.51.100.7\n\n' >"$tmp/services"
: >"$S/nft.log"
export PATH="$tmp/bin:$PATH"
export IKEV2_NFT="$tmp/bin/nft" IKEV2_IP="$tmp/bin/ip" IKEV2_SA_HELPER="$tmp/bin/sa"
export IKEV2_ROUTING_TABLE=ikev2_routing_test IKEV2_ROUTING_STATE="$S/routing.state"
export IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib"
export IKEV2_SERVICE_CIDRS="$tmp/services" IKEV2_VIP_FILE="$tmp/vip4"
export IKEV2_SYSTEM_HELPER="$tmp/bin/system"
export IKEV2_DNSMASQ_INIT="$tmp/bin/dnsmasq-init" IKEV2_DOMAIN_LIST="$tmp/domains"
export IKEV2_ROUTING_DUMP_DIR="$S/run" IKEV2_ROUTING_PERSIST_DIR="$S/flash"
mkdir -p "$S/run"
printf '# selected\nExample.COM\nvideo.example.net\nbad..name\n' >"$tmp/domains"
restarts() { grep -c restart "$S/dnsmasq.log" 2>/dev/null || echo 0; }
printf '10.20.20.10\n' >"$tmp/vip4"
applies() { wc -l <"$S/nft.log" | tr -d ' '; }

# Not selected: nothing is installed, and that is healthy.
"$helper" sync || fail 'sync failed while not selected'
[ ! -s "$S/rules4" ] && [ ! -e "$S/nft.rules" ] || fail 'routing was installed while not selected'
"$helper" check || fail 'an unselected, absent runtime reported unhealthy'

printf 'overlay\n' >"$S/backend"
"$helper" check && fail 'a selected runtime that is not installed passed the check'
"$helper" sync || fail 'the overlay did not install'

# Rules on bits of its own, ahead of PBR.
grep -qx '28000:	from all lookup main suppress_prefixlength 1' "$S/rules4" || fail 'local routes are not kept ahead of the marks'
grep -qx '28001:	from all fwmark 0x1000000/0xf000000 lookup 1601' "$S/rules4" || fail 'the tunnel rule is missing'
grep -qx '28002:	from all fwmark 0x2000000/0xf000000 lookup 1602' "$S/rules4" || fail 'the WAN rule is missing'
grep -qx '28001:	from all fwmark 0x1000000/0xf000000 lookup 1601' "$S/rules6" || fail 'IPv6 is not failed closed'

# Fail closed: the unreachable default is there whatever the tunnel does.
grep -qx 'unreachable default metric 32767' "$S/route4-1601" || fail 'the tunnel table has no unreachable default'
grep -qx 'unreachable default metric 32767' "$S/route6-1601" || fail 'the IPv6 table has no unreachable default'
grep -qx 'default dev ipsec-out metric 10' "$S/route4-1601" || fail 'the tunnel default is missing'
grep -qx '192.168.2.0/24 dev br-lan' "$S/route4-1601" || fail 'replies to the LAN would enter the tunnel'
grep -qx '10.20.30.0/24 dev ipsec-in' "$S/route4-1601" || fail 'replies to inbound clients would enter the tunnel'
grep -qx 'default via 192.0.2.1 dev eth1' "$S/route4-1602" || fail 'the WAN table has no default'

# The marks: after the other deciders, never over their decisions.
rules="$S/nft.rules"
grep -Fq 'priority mangle + 2' "$rules" || fail 'the chain runs before the inbound WAN exclusion'
grep -Fq 'prerouting meta mark & 0x0f000000 != 0 return' "$rules" || fail 'its own marks are not final'
grep -Fq 'meta mark & 0x00ff0000 != 0 meta mark & 0x00ff0000 != 0x00020000 return' "$rules" ||
	fail "another component's decision could be overridden"
grep -Fq 'iifname @src_ifaces ip daddr @dst4 counter meta mark set meta mark & 0xf0ffffff | 0x01000000' "$rules" ||
	fail 'selected destinations are not marked for the tunnel'
grep -Fq 'iifname @src_ifaces ip6 daddr @dst6' "$rules" || fail 'IPv6 destinations are not marked'
grep -Fq 'add element inet ikev2_routing_test src_ifaces { "br-lan", "ipsec-in" }' "$rules" ||
	fail 'the protected networks are not the sources'
grep -Fq 'add element inet ikev2_routing_test service4 { 198.51.100.7, 203.0.113.0/24 }' "$rules" ||
	fail 'the service networks were not loaded'
grep -q '^flush set inet ikev2_routing_test dst4' "$rules" && fail 'a sync would empty what dnsmasq learned'
grep -Fq 'add element inet ikev2_routing_test dst4 { 203.0.113.5,203.0.113.9 }' "$S/nft.added" ||
	fail "the overlay did not copy PBR's domain set"

# Current, and a no-op to sync again.
"$helper" check || fail 'a fresh runtime failed the check'
"$helper" sync
[ "$(applies)" = 1 ] || fail 'an unchanged runtime was reinstalled'

# Drift of each kind is found and repaired.
sed 's/0x01000000$/0x03000000/' "$rules" >"$rules.x" && mv "$rules.x" "$rules"
"$helper" check && fail 'a changed rule passed the check'
"$helper" sync
[ "$(applies)" = 2 ] || fail 'a changed rule was not repaired'
"$tmp/bin/ip" -4 rule del priority 28001
"$helper" check && fail 'a missing ip rule passed the check'
"$helper" sync
# Stopping PBR deletes every rule of this shape, ours included.
"$tmp/bin/ip" -6 rule del priority 28000
"$helper" check && fail 'a missing local-routes rule passed the check'
"$tmp/bin/ip" -4 rule del priority 28002
"$helper" check && fail 'a missing WAN rule passed the check'
"$helper" sync
"$tmp/bin/ip" -4 rule del priority 28001
"$helper" sync
grep -q '^28001:' "$S/rules4" || fail 'a missing ip rule was not restored'
"$helper" check || fail 'the repaired runtime failed the check'
[ "$(grep -c '^28001:' "$S/rules4")" = 1 ] || fail 'a rule was duplicated'
# A stale rule at the same priority is replaced, not joined.
"$tmp/bin/ip" -4 rule del priority 28001
"$tmp/bin/ip" -4 rule add priority 28001 fwmark 0x5000000/0xf000000 lookup 1601
"$helper" sync
[ "$(grep -c '^28001:' "$S/rules4")" = 1 ] || fail 'a stale rule was left beside the new one'
grep -qx '28001:	from all fwmark 0x1000000/0xf000000 lookup 1601' "$S/rules4" || fail 'a stale rule was kept'

# A tunnel that goes down keeps the table closed.
: >"$S/tunnel-down"
"$helper" sync
grep -q '^default dev ipsec-out' "$S/route4-1601" && fail 'the tunnel default outlived the tunnel'
grep -qx 'unreachable default metric 32767' "$S/route4-1601" || fail 'the table opened when the tunnel went down'
rm -f "$S/tunnel-down"
"$helper" sync
grep -qx 'default dev ipsec-out metric 10' "$S/route4-1601" || fail 'the tunnel default did not return'

# A WAN without a default keeps the last one.
: >"$S/wan-down"
"$helper" sync
grep -qx 'default via 192.0.2.1 dev eth1' "$S/route4-1602" || fail 'a WAN outage emptied the WAN table'
rm -f "$S/wan-down"

# A rejected ruleset changes nothing.
: >"$S/nft-reject"
cp "$rules" "$tmp/before"
printf '# services\n203.0.113.0/24\n' >"$tmp/services"
"$helper" sync 2>/dev/null && fail 'a rejected ruleset was reported installed'
cmp -s "$rules" "$tmp/before" || fail 'a rejected ruleset replaced the installed one'
rm -f "$S/nft-reject"

# A pause keeps policy routing: what it sends to the tunnel is refused there,
# so nothing selected leaves through WAN meanwhile.
printf '1\n' >"$S/paused"
"$helper" sync
[ -s "$S/rules4" ] && [ -e "$rules" ] || fail 'a pause removed policy routing'
[ -e "$S/route4-1601" ] || fail 'a pause removed the tunnel table'
"$helper" check || fail 'a paused runtime reported unhealthy'
rm -f "$S/paused"
"$helper" sync
# Deselection removes everything it owns.
printf 'pbr\n' >"$S/backend"
"$helper" sync
[ ! -s "$S/rules4" ] && [ ! -e "$rules" ] || fail 'switching back to PBR left this installed'

# Native: dnsmasq fills the domain sets through a file of ours.
printf 'native\n' >"$S/backend"
"$helper" sync || fail 'native mode did not install'
nftset="$S/dnsmasq.d/ikev2-routing"
grep -qx 'nftset=/example.com/4#inet#ikev2_routing_test#dst4,6#inet#ikev2_routing_test#dst6' "$nftset" ||
	fail 'selected names do not fill the domain sets'
grep -q 'video.example.net' "$nftset" || fail 'a selected name is missing from dnsmasq'
grep -q 'bad' "$nftset" && fail 'an invalid name reached dnsmasq'
[ "$(restarts)" = 1 ] || fail 'dnsmasq was not restarted to read its new sets'
"$helper" check || fail 'a fresh native runtime failed the check'
"$helper" sync
[ "$(restarts)" = 1 ] || fail 'dnsmasq was restarted without a change'
printf 'other.example\n' >>"$tmp/domains"
"$helper" check && fail 'a changed destination list passed the check'
"$helper" sync
[ "$(restarts)" = 2 ] && grep -q other.example "$nftset" || fail 'a changed list did not reach dnsmasq'

# Before an Apply retires PBR's domain policy, dnsmasq keeps filling PBR's
# sets, copied from there; a second nftset line for the same names is not
# written.
echo 1 >"$S/pbr-domains-policy"
"$helper" sync
[ ! -e "$nftset" ] || fail "our dnsmasq sets were written beside PBR's"
rm -f "$S/pbr-domains-policy"
"$helper" sync
[ -e "$nftset" ] || fail 'our dnsmasq sets did not follow the retired PBR policy'

# Reliable mode answers those names itself: no file, and dnsmasq told.
printf 'fakeip\n' >"$S/engine"
"$helper" sync
[ ! -e "$nftset" ] || fail 'reliable mode kept the dnsmasq sets'
[ "$(restarts)" = 5 ] || fail 'dnsmasq kept sets that were removed'
rm -f "$S/engine"
"$helper" sync

# What dnsmasq taught survives in the dumps, and returns to empty sets.
printf '198.51.100.20\n' >>"$S/dst4"
"$helper" dump
grep -qx 198.51.100.20 "$S/run/ikev2-routing-dst4.dump" || fail 'the domain set was not dumped'
"$helper" persist
grep -qx 198.51.100.20 "$S/flash/routing-dst4.dump" || fail 'the domain set was not saved for the next boot'
rm -f "$S/dst4" "$S/run/ikev2-routing-dst4.dump"
"$helper" sync
grep -qx 198.51.100.20 "$S/dst4" || fail 'an empty domain set was not refilled from the saved copy'

# The rest of the application routes with these marks.
(
	. "$root/ikev2-manager-runtime/lib/nft-runtime.sh"
	[ "$(routing_mark_rule tunnel)" = 0x01000000/0x0f000000 ] || fail 'the tunnel mark is not ours in native mode'
	[ "$(routing_mark_rule wan)" = 0x02000000/0x0f000000 ] || fail 'the WAN mark is not ours in native mode'
	[ "$(mark_values "$(routing_mark_rule wan)")" = '0xf0ffffff 0x02000000' ] || fail 'the WAN mark does not clear our bits'
	printf 'pbr\n' >"$S/backend"
	[ "$(routing_mark_rule tunnel)" = 0x20000/0xff0000 ] || fail "PBR's mark is not used without native routing"
	. "$root/ikev2-manager-runtime/lib/routing.sh"
	[ "$(routing_tunnel_table)" = pbr_ikev2out ] || fail "PBR's table is not checked without native routing"
	printf 'native\n' >"$S/backend"
	[ "$(routing_tunnel_table)" = 1601 ] || fail 'the fail-closed check does not follow native routing'
)

# Stopping removes the dnsmasq file too.
printf 'pbr\n' >"$S/backend"
"$helper" sync
[ ! -e "$nftset" ] || fail 'the dnsmasq sets outlived native routing'

# Apply with native routing: PBR loses everything of ours and gets the
# operator's own settings back, restarts once, and a PBR that only this
# application installed and used is removed at the end.
(
	for name in routing_native release_pbr_config pbr_holds_ours retire_pbr_policies \
		remove_unused_pbr pbr_restart_checked; do
		awk -v name="$name" 'index($0, name "() {") == 1 { body = 1 } body { print } body && $0 == "}" { exit }' \
			"$root/ikev2-manager-runtime/ikev2-manager-system.sh"
	done >"$tmp/apply.sh"
	for name in routing_native release_pbr_config pbr_holds_ours retire_pbr_policies remove_unused_pbr; do
		grep -q "^$name() {" "$tmp/apply.sh" || fail "the Apply function $name is missing"
	done
	config=ikev2-manager
	uci_config_dir="$tmp/uci"
	export UCI_STUB_DIR="$tmp/uci"
	mkdir -p "$UCI_STUB_DIR"
	cp "$root/scripts/uci-stub.sh" "$tmp/apply-bin-uci"
	chmod 755 "$tmp/apply-bin-uci"
	uci() { "$tmp/apply-bin-uci" "$@"; }
	defaultv() { cat "$S/backend"; }
	device_pbr_clear() { :; }
	logger() { printf '%s\n' "$*" >>"$S/apply.log"; }
	pkg_installed() { [ -e "$S/pbr-installed" ]; }
	pkg_required_by() { cat "$S/pbr-required-by" 2>/dev/null || :; }
	pkg_remove_runtime() { rm -f "$S/pbr-installed"; printf 'remove %s\n' "$*" >>"$S/apply.log"; }
	deps_state_has() { grep -qx "$2" "$S/owned"; }
	deps_state_forget_owned() { grep -vx "$1" "$S/owned" >"$S/owned.new" || :; mv "$S/owned.new" "$S/owned"; }
	mkdir -p "$tmp/initd"
	pbr_init_log="$S/pbr-init.log"
	routing_runtime_helper="$tmp/bin/routing-resync"
	printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"%s/resync.log"\n' "$S" >"$routing_runtime_helper"
	chmod 755 "$routing_runtime_helper"
	. "$tmp/apply.sh"
	# /etc/init.d/pbr is the router's; the calls are recorded instead.
	eval "$(sed "s#/etc/init.d/pbr#$tmp/initd/pbr#g" "$tmp/apply.sh")"
	printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"%s"\n[ "$1" != running ]\n' "$pbr_init_log" >"$tmp/initd/pbr"
	chmod 755 "$tmp/initd/pbr"

	cat >"$UCI_STUB_DIR/pbr" <<'EOF'
config=pbr
config.enabled=1
config.ipv6_enabled=1
config.resolver_set=dnsmasq.nftset
ikev2pbr_domains=policy
ikev2pbr_domains.enabled=1
ikev2pbr_service_cidrs=policy
ikev2pbr_service_cidrs.enabled=1
ikev2pbr_include=include
ikev2pbr_include.enabled=1
sample=policy
sample.enabled=0
EOF
	cat >"$UCI_STUB_DIR/ikev2-manager" <<'EOF'
globals=globals
globals.pbr_saved=1
globals.pbr_prev_enabled=0
globals.pbr_prev_ipv6=0
EOF
	printf 'native\n' >"$S/backend"
	retire_pbr_policies || fail 'the PBR configuration could not be released'
	for section in ikev2pbr_domains ikev2pbr_service_cidrs ikev2pbr_include; do
		grep -q "^$section" "$UCI_STUB_DIR/pbr" && fail "PBR kept $section"
	done
	grep -qx 'config.enabled=0' "$UCI_STUB_DIR/pbr" || fail "the operator's PBR switch was not restored"
	grep -q '^config.resolver_set' "$UCI_STUB_DIR/pbr" && fail 'our resolver setting stayed in PBR'
	grep -q pbr_saved "$UCI_STUB_DIR/ikev2-manager" && fail 'the saved PBR settings were kept after use'
	[ "$pbr_restart_needed" = 1 ] || fail 'PBR would keep our rules until its next restart'
	pbr_restart_checked || fail 'restarting a PBR the operator had off failed'
	grep -qx stop "$pbr_init_log" || fail 'a PBR the operator had off was left running'
	retire_pbr_policies
	[ "$pbr_restart_needed" = 0 ] || fail 'PBR would be rebuilt with nothing of ours to drop'

	# Removed only when this application installed it and nothing uses it.
	: >"$S/pbr-installed"
	: >"$S/owned"
	remove_unused_pbr
	[ -e "$S/pbr-installed" ] || fail "a PBR the operator installed was removed"
	printf 'pbr\n' >"$S/owned"
	printf 'luci-app-pbr\n' >"$S/pbr-required-by"
	remove_unused_pbr
	[ -e "$S/pbr-installed" ] || fail 'a PBR another package needs was removed'
	rm -f "$S/pbr-required-by"
	printf 'sample.enabled=1\n' >>"$UCI_STUB_DIR/pbr"
	remove_unused_pbr
	[ -e "$S/pbr-installed" ] || fail 'a PBR with an enabled policy of its own was removed'
	sed -i.bak '/^sample.enabled=1$/d' "$UCI_STUB_DIR/pbr"
	printf 'pbr\n' >"$S/backend"
	remove_unused_pbr
	[ -e "$S/pbr-installed" ] || fail 'PBR was removed while it still routes'
	printf 'native\n' >"$S/backend"
	remove_unused_pbr
	[ ! -e "$S/pbr-installed" ] || fail 'an unused PBR this application installed was kept'
	grep -qx pbr "$S/owned" && fail 'a removed PBR stayed in the dependency record'
	grep -qx disable "$pbr_init_log" || fail 'PBR was removed without being disabled first'
	grep -qx sync "$S/resync.log" || fail 'the rules PBR took with it were not restored'
	exit 0
)

# Without PBR installed the include that the watcher runs every pass still
# maintains this routing; with PBR selected it needs PBR's table.
cat >"$tmp/bin/routing-probe" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$S/include.log"
EOF
chmod 755 "$tmp/bin/routing-probe"
if [ ! -e /etc/iproute2/rt_tables ] || ! grep -q pbr_ikev2out /etc/iproute2/rt_tables; then
	printf 'native\n' >"$S/backend"
	IKEV2_ROUTING_HELPER="$tmp/bin/routing-probe" sh "$root/ikev2-manager-runtime/pbr.user.ikev2out" ||
		fail 'the watcher include failed without PBR installed'
	grep -qx sync "$S/include.log" || fail 'the watcher include skipped the routing without PBR'
	printf 'pbr\n' >"$S/backend"
	IKEV2_ROUTING_HELPER="$tmp/bin/routing-probe" sh "$root/ikev2-manager-runtime/pbr.user.ikev2out" &&
		fail 'the include accepted PBR routing without a PBR table'
fi

# A table of the same name that is not ours is never taken over.
printf 'overlay\n' >"$S/backend"
printf 'table inet ikev2_routing_test { }\n' >"$rules"
"$helper" sync 2>/dev/null && fail 'a foreign table was taken over'
grep -q ikev2_manager_owned "$rules" && fail 'a foreign table was replaced'

finished=1
printf '%s\n' 'policy routing tests OK'
