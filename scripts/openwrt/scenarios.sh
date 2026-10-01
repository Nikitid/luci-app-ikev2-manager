#!/bin/sh
# Runs inside an OpenWrt rootfs container (see scripts/test-openwrt.sh), with
# the package installed, against the real BusyBox, uci, jsonfilter, ucode, nft
# and ip. The unit tests replace these tools with stubs that print what their
# author expected; every scenario here exists because a stub hid a failure the
# router showed.

set -eu

fail() {
	printf 'openwrt: %s\n' "$*" >&2
	exit 1
}
step() { printf '  %s\n' "$*"; }

release="$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'$/\1/p" /etc/openwrt_release)"
printf 'OpenWrt %s\n' "$release"

# --- the installed package -------------------------------------------------

step 'every page the menu opens is installed'
menu=/usr/share/luci/menu.d/luci-app-ikev2-manager.json
[ -r "$menu" ] || fail "the menu is not installed: $menu"
for path in $(sed -n 's/.*"path": "\(ikev2-[a-z-]*\/[a-z0-9-]*\)".*/\1/p' "$menu"); do
	[ -r "/www/luci-static/resources/view/$path.js" ] ||
		fail "the menu opens a page that is not installed: $path"
done
for view in /www/luci-static/resources/view/ikev2-manager/*.js \
	/www/luci-static/resources/view/ikev2-domains/*.js \
	/www/luci-static/resources/view/status/include/06_ikev2-manager.js; do
	shared="$(sed -n "s/^'require ikev2-manager\.\(shared-v[0-9]*\) as common';$/\1/p" "$view")"
	[ -z "$shared" ] || [ -r "/www/luci-static/resources/ikev2-manager/$shared.js" ] ||
		fail "$view requires $shared, which is not installed"
done

step 'every helper the pages may call is installed'
acl=/usr/share/rpcd/acl.d/luci-app-ikev2-manager.json
[ -r "$acl" ] || fail "the ACL is not installed: $acl"
sed -n 's/^[[:space:]]*"\(\/[^" ]*\)[^"]*": \[ *"exec" *\].*/\1/p' "$acl" | sort -u |
	while IFS= read -r command; do
		case "$command" in
			/usr/libexec/ikev2-* | /usr/share/pbr/* | /etc/init.d/ikev2-*)
				[ -x "$command" ] || fail "the pages may call $command, which is not installed"
				;;
		esac
	done

step 'every installed shell script parses under BusyBox ash'
for script in /usr/libexec/ikev2-* /usr/libexec/ikev2-manager.d/*.sh /etc/init.d/ikev2-* \
	/usr/share/pbr/pbr.user.ikev2out /etc/hotplug.d/iface/90-ikev2-manager; do
	[ -f "$script" ] || continue
	head -c 64 "$script" | grep -q '^#!/bin/sh' || continue
	sh -n "$script" || fail "$script does not parse under BusyBox ash"
done

step 'installed helpers ignore test overrides a page session could send'
# rpcd passes a caller's environment through; the overrides are for the tests.
mkdir -p /tmp/evil-lib /tmp/evil-bin
for lib in /usr/libexec/ikev2-manager.d/*.sh; do
	printf ': >/tmp/evil-sourced\nexit 0\n' >"/tmp/evil-lib/${lib##*/}"
done
for tool in env sed; do
	printf '#!/bin/sh\n: >/tmp/evil-path\nexit 1\n' >"/tmp/evil-bin/$tool"
	chmod 755 "/tmp/evil-bin/$tool"
done
run_with_overrides() {
	rm -f /tmp/evil-sourced /tmp/evil-path
	PATH="/tmp/evil-bin:$PATH" IKEV2_RUNTIME_LIB_DIR=/tmp/evil-lib \
		"/usr/libexec/$1" status >/dev/null 2>&1 || :
}
for helper in ikev2-manager ikev2-manager-system ikev2-domain-router \
	ikev2-device-routing ikev2-tunnel-quality ikev2-devices ikev2-domains-community; do
	run_with_overrides "$helper"
	[ ! -e /tmp/evil-sourced ] || fail "$helper sourced a library its environment named"
	[ ! -e /tmp/evil-path ] || fail "$helper ran a tool from the search path it was given"
done
# Without the installed package the same run must honour them, or the check
# above sees nothing.
mv /usr/share/ikev2-manager/version /tmp/ikev2-version
run_with_overrides ikev2-manager-system
mv /tmp/ikev2-version /usr/share/ikev2-manager/version
[ -e /tmp/evil-sourced ] || fail 'the override check cannot see a sourced library'
rm -rf /tmp/evil-lib /tmp/evil-bin /tmp/evil-sourced /tmp/evil-path

step 'a read the pages poll leaves the configuration file alone'
# uci rewrites a file on every commit, changed or not, and the pages poll
# these reads every few seconds.
/usr/libexec/ikev2-manager server-get >/dev/null
before="$(date -r /etc/config/ikev2-manager +%s)"
sleep 1
for read in server-get client-get users-show widget-status; do
	/usr/libexec/ikev2-manager "$read" >/dev/null 2>&1 || :
done
[ "$(date -r /etc/config/ikev2-manager +%s)" = "$before" ] ||
	fail 'a read rewrote /etc/config/ikev2-manager'

step 'the ucode scripts load'
for script in /usr/libexec/ikev2-manager.d/*.uc; do
	# Run without input: a usage error is fine, a compile error is 255.
	rc=0
	printf '' | ucode "$script" >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 255 ] || fail "$script does not compile"
done

# --- a router to route on -------------------------------------------------

# netifd does not run in the container; the helpers fall back to UCI for the
# LAN device, and the device is created by hand.
ip link add br-lan type dummy 2>/dev/null || :
ip addr add 192.168.1.1/24 dev br-lan 2>/dev/null || :
ip link set br-lan up
touch /etc/config/network
uci -q batch <<'EOF'
set network.lan=interface
set network.lan.device='br-lan'
set ikev2-manager.globals.configured='1'
set ikev2-manager.globals.routing_backend='native'
set ikev2-manager.globals.device_schema='2'
set ikev2-manager.domains=domains
set ikev2-manager.domains.engine='nftset'
commit
EOF
printf '203.0.113.0/24\n198.51.100.7\n' >/etc/pbr-ikev2-service-cidrs.txt

routing=/usr/libexec/ikev2-routing
rules4() { ip -4 rule show | grep -E '^2800[0-2]:' || :; }

# --- the application's own policy routing ----------------------------------

step 'policy routing installs with real ip and nft'
"$routing" sync || fail 'policy routing did not install'
rules4 | grep -q '^28000:.*lookup main suppress_prefixlength 1' || fail 'the local-routes rule is missing'
rules4 | grep -q '^28001:.*fwmark 0x1000000/0xf000000 lookup 1601' || fail 'the tunnel rule is missing'
rules4 | grep -q '^28002:.*fwmark 0x2000000/0xf000000 lookup 1602' || fail 'the WAN rule is missing'
ip -6 rule show | grep -q '^28001:' || fail 'the IPv6 rule is missing'
ip -4 route show table 1601 | grep -q '^unreachable default' || fail 'the tunnel table is open'
ip -6 route show table 1601 | grep -q '^unreachable default' || fail 'the IPv6 tunnel table is open'
nft list set inet ikev2_routing service4 | grep -q '203.0.113.0/24' || fail 'the service networks were not loaded'
"$routing" check || fail 'a fresh installation failed its check'

step 'an unchanged runtime is left alone'
before="$(nft -j list table inet ikev2_routing | md5sum)"
"$routing" sync
[ "$(nft -j list table inet ikev2_routing | md5sum)" = "$before" ] || fail 'an unchanged runtime was reinstalled'

step 'a sync with nothing to change writes no route'
# Every route write is announced to whatever watches the tables (Tailscale
# logged each one), and the watcher syncs on every pass.
ip monitor route >/tmp/route-events 2>&1 &
monitor=$!
sleep 1
"$routing" sync
sleep 1
kill "$monitor" 2>/dev/null || :
wait "$monitor" 2>/dev/null || :
[ ! -s /tmp/route-events ] || fail "an unchanged sync rewrote routes: $(head -n 3 /tmp/route-events)"
rm -f /tmp/route-events

step 'traffic counters do not read as a changed table'
nft add element inet ikev2_routing dst4 '{ 192.0.2.9 }'
"$routing" check || fail 'a learned destination read as a changed table'

step 'a changed table is noticed and repaired'
nft add chain inet ikev2_routing probe
"$routing" check && fail 'an added chain passed the check'
"$routing" sync
"$routing" check || fail 'the repaired runtime failed its check'
nft list set inet ikev2_routing dst4 | grep -q 192.0.2.9 || fail 'a repair emptied what dnsmasq learned'

step 'learned destinations expire, and a set without a timeout is replaced'
nft list set inet ikev2_routing dst4 | grep -q 'timeout 7d' || fail 'the destination set has no timeout'
"$routing" dump
"$routing" stop
nft -f - <<'EOF'
table inet ikev2_routing {
	chain ikev2_manager_owned { comment "IKEv2 Manager policy routing"; }
	set dst4 { type ipv4_addr; flags interval; auto-merge; elements = { 192.0.2.9 } }
}
EOF
"$routing" sync || fail 'a destination set from an earlier release stopped the install'
nft list set inet ikev2_routing dst4 | grep -q 'timeout 7d' || fail 'the old destination set was kept'
nft list set inet ikev2_routing dst4 | grep -q '192.0.2.9' ||
	fail 'what dnsmasq had learned was lost with the old set'

step 'recognising by name keeps no destination addresses'
uci set ikev2-manager.domains.engine='fakeip'
"$routing" sync
nft list set inet ikev2_routing dst4 | grep -q '192.0.2.9' &&
	fail 'FakeIP kept addresses learned by address'
nft list chain inet ikev2_routing prerouting | grep -q '@dst4' &&
	fail 'FakeIP still routes by destination address'
"$routing" persist
[ ! -e /var/run/ikev2-routing-dst4.dump ] && [ ! -e /etc/ikev2-manager/routing-dst4.dump ] ||
	fail 'FakeIP kept a copy of the destination addresses'
"$routing" check || fail 'the FakeIP runtime failed its check'
uci set ikev2-manager.domains.engine='nftset'
"$routing" sync
nft list chain inet ikev2_routing prerouting | grep -q '@dst4' ||
	fail 'matching by address did not route destination addresses again'

step 'a rule another package deletes by pattern is noticed and restored'
# Stopping PBR deletes every "lookup main suppress_prefixlength" rule.
while ip -4 rule del priority 28000 2>/dev/null; do :; done
"$routing" check && fail 'a deleted local-routes rule passed the check'
"$routing" sync
rules4 | grep -q '^28000:' || fail 'the local-routes rule was not restored'

step 'a protected network without a device stops the install'
uci delete network.lan.device
if "$routing" sync 2>/dev/null; then
	fail 'policy routing installed without a device for a protected network'
fi
uci set network.lan.device='br-lan'
"$routing" sync || fail 'policy routing did not recover once the device was back'

step 'a routed packet takes the tunnel table, an unmarked one does not'
ip -4 route get 203.0.113.5 from 192.168.1.50 iif br-lan mark 0x1000000 2>&1 |
	grep -q 'unreachable' || fail 'a marked packet did not meet the closed tunnel table'
ip -4 route get 192.168.1.20 from 192.168.1.50 iif br-lan mark 0x1000000 2>&1 |
	grep -q 'dev br-lan' || fail 'a marked packet to the LAN left the LAN'

# --- Discord voice, with nothing of PBR left ----------------------------------

step 'Discord voice routing takes its sources from the application, not PBR'
printf 'discord\n' >/etc/pbr-ikev2-community-selected.txt
/usr/libexec/ikev2-discord-voice sync || fail 'Discord voice routing did not install without PBR'
nft list set inet ikev2_discord_voice source_ifaces | grep -q '"br-lan"' ||
	fail 'Discord voice routing did not protect the LAN'

step 'a runtime that fails does not keep policy routing from being installed'
/usr/libexec/ikev2-discord-voice stop
"$routing" stop
nft add table inet ikev2_discord_voice
if /usr/share/pbr/pbr.user.ikev2out; then
	fail 'a failed Discord voice sync was reported as success'
fi
rules4 | grep -q '^28001:' || fail 'policy routing was skipped after Discord voice failed'
nft delete table inet ikev2_discord_voice
: >/etc/pbr-ikev2-community-selected.txt
/usr/libexec/ikev2-discord-voice sync || fail 'Discord voice routing did not stop when unselected'

# --- a router that routed through PBR ---------------------------------------

step 'an upgrade from a release that routed through PBR routes on its own and leaves PBR alone'
# What such a release left: our policies, include and interface in PBR, the
# operator's own PBR settings saved, and no routing of our own.
"$routing" stop
cat >/etc/config/pbr <<'EOF'
config pbr 'config'
	option enabled '1'
	option ipv6_enabled '1'
	option resolver_set 'dnsmasq.nftset'
	option strict_enforcement '1'
	list supported_interface 'ikev2out'

config policy 'ikev2pbr_domains'
	option name 'IKEv2 PBR domains'
	option interface 'ikev2out'
	option src_addr '@br-lan'
	option dest_addr 'file:///etc/pbr-ikev2-domains.txt'
	option enabled '1'

config policy 'ikev2pbr_service_cidrs'
	option name 'IKEv2 PBR service networks'
	option interface 'ikev2out'
	option src_addr '@br-lan'
	option dest_addr 'file:///etc/pbr-ikev2-service-cidrs.txt'
	option enabled '1'

config include 'ikev2pbr_include'
	option path '/usr/share/pbr/pbr.user.ikev2out'
	option enabled '1'

config policy 'operator_own'
	option name 'Operator policy'
	option interface 'wan'
	option enabled '0'
EOF
cp /etc/config/pbr /tmp/pbr.before
uci -q batch <<'EOF'
delete ikev2-manager.globals.routing_backend
set ikev2-manager.globals.runtime_schema='3'
set ikev2-manager.globals.pbr_saved='1'
set ikev2-manager.globals.pbr_prev_enabled='0'
set ikev2-manager.globals.pbr_prev_ipv6='0'
commit ikev2-manager
EOF
/usr/libexec/ikev2-manager-system _upgrade-reconcile || fail 'the upgrade reconcile failed'
rules4 | grep -q '^28001:' || fail 'the upgrade did not install policy routing'
cmp -s /etc/config/pbr /tmp/pbr.before || fail 'the upgrade changed PBR instead of leaving it to the next Apply'
/usr/libexec/ikev2-manager-system doctor 2>/dev/null | grep -qx 'pbr_policies=notice:retired-at-next-apply' ||
	fail 'doctor does not say that PBR still holds our policies'
# PBR sources the include on every reload until the Apply retires it.
/usr/share/pbr/pbr.user.ikev2out || fail 'the include PBR still runs failed'

step 'the next Apply takes our policies out of PBR and gives the operator theirs back'
/usr/libexec/ikev2-manager-system _sync-pbr || fail 'the PBR policies could not be retired'
for section in ikev2pbr_domains ikev2pbr_service_cidrs ikev2pbr_include; do
	uci -q get "pbr.$section" >/dev/null && fail "PBR kept $section"
done
uci -q get pbr.operator_own >/dev/null || fail "the operator's own PBR policy was removed"
[ "$(uci -q get pbr.config.enabled)" = 0 ] || fail "the operator's PBR switch was not restored"
uci -q get pbr.config.supported_interface | grep -q ikev2out && fail 'our interface stayed in PBR'
uci -q get ikev2-manager.globals.pbr_saved >/dev/null && fail 'the saved PBR settings were kept after use'
rules4 | grep -q '^28001:' || fail 'policy routing was lost when PBR was retired'
/usr/libexec/ikev2-manager-system doctor 2>/dev/null | grep -q '^pbr_policies=' &&
	fail 'doctor still reports PBR policies after they were retired'
rm -f /etc/config/pbr /tmp/pbr.before

step 'device settings change on a router that never had PBR'
# The rootfs has no conntrack, which every router has; answer as it does when
# nothing matched.
if ! command -v conntrack >/dev/null 2>&1; then
	printf '#!/bin/sh\necho "conntrack v1.4.8 (conntrack-tools): 0 flow entries have been deleted." >&2\nexit 1\n' \
		>/usr/sbin/conntrack
	chmod 755 /usr/sbin/conntrack
fi
out="$(/usr/libexec/ikev2-devices set-exclusions 192.168.1.61 1 0 0 2>&1)" ||
	fail "a device setting could not be changed without /etc/config/pbr: $out"
[ "$(uci -q get ikev2-manager.device_192_168_1_61.route_mode)" = exclude ] ||
	fail 'the device setting was not saved'
/usr/libexec/ikev2-devices clear-policy 192.168.1.61 >/dev/null 2>&1 || fail 'the device setting could not be cleared'

# --- a change that fails is rolled back -----------------------------------

step 'a protected network whose apply fails is taken back out'
# The container lacks strongSwan and the rest, so a managed apply fails here.
# The network change used to stay committed while the page said the
# previous state was restored.
ip link add br-guest type dummy 2>/dev/null || :
ip link set br-guest up
uci -q batch <<'EOF'
set network.guest=interface
set network.guest.device='br-guest'
add firewall zone
set firewall.@zone[-1].name='guest'
set firewall.@zone[-1].network='guest'
commit
EOF
before="$(uci -q get ikev2-manager.globals.source_interface)"
if out="$(/usr/libexec/ikev2-manager-system coverage-add guest 2>&1)"; then
	fail 'a managed apply without strongSwan succeeded; the scenario proves nothing'
fi
# Without procd the services cannot be restarted here, so the rollback may
# rightly report itself incomplete; what matters is whose rollback ran.
printf '%s\n' "$out" | tail -n 1 | grep -q '^Unable to add protected network' ||
	fail "the network change did not roll itself back: $(printf '%s\n' "$out" | tail -n 1)"
[ "$(uci -q get ikev2-manager.globals.source_interface)" = "$before" ] ||
	fail 'the protected network stayed added after its apply failed'
rules4 | grep -q '^28001:' || fail 'policy routing was lost in the rollback'

# --- device routing, where nft prints rules back differently --------------

step 'device routing verifies what nft printed, not what it wrote'
uci -q batch <<'EOF'
set ikev2-manager.device_192_168_1_40=device_policy
set ikev2-manager.device_192_168_1_40.address='192.168.1.40'
set ikev2-manager.device_192_168_1_40.route_mode='fullroute'
set ikev2-manager.device_192_168_1_41=device_policy
set ikev2-manager.device_192_168_1_41.address='192.168.1.41'
set ikev2-manager.device_192_168_1_41.route_mode='exclude'
commit ikev2-manager
EOF
/usr/libexec/ikev2-device-routing sync || fail 'device routing did not install'
/usr/libexec/ikev2-device-routing check || fail 'installed device routing failed its check'
before="$(nft -j list table inet ikev2_device_policy | md5sum)"
/usr/libexec/ikev2-device-routing sync
[ "$(nft -j list table inet ikev2_device_policy | md5sum)" = "$before" ] ||
	fail 'unchanged device routing was reinstalled'
nft list table inet ikev2_device_policy | grep -q '0x01000000' || fail 'full-route devices do not use the tunnel mark'

# --- the inbound users' firewall ------------------------------------------

step 'the inbound user policy installs and fingerprints its table'
uci -q batch <<'EOF'
set ikev2-manager.server=server
set ikev2-manager.server.enabled='1'
set ikev2-manager.server.pool4='10.20.30.10-10.20.30.100'
set ikev2-manager.server.gateway4='10.20.30.1/24'
commit ikev2-manager
EOF
mkdir -p /etc/ikev2-manager
printf 'alice\tsecret\n' >/etc/ikev2-manager/users.db
printf 'alice\t10.20.30.15\n' >/tmp/sessions
IKEV2_SESSIONS_FILE=/tmp/sessions /usr/libexec/ikev2-user-policy sync >/dev/null ||
	fail 'the inbound user policy did not install'
nft list set inet ikev2_user_policy internet_allowed | grep -q 10.20.30.15 ||
	fail 'the connected user was not admitted'
[ "$(sed -n '2p' /var/run/ikev2-user-policy.signature)" != '' ] ||
	fail 'the inbound table fingerprint was not recorded'
IKEV2_SESSIONS_FILE=/tmp/sessions /usr/libexec/ikev2-user-policy check ||
	fail 'the installed inbound table failed its check'
nft add chain inet ikev2_user_policy probe
IKEV2_SESSIONS_FILE=/tmp/sessions /usr/libexec/ikev2-user-policy check &&
	fail 'a changed inbound table passed its check'
nft delete chain inet ikev2_user_policy probe

# --- downloaded lists, filtered with BusyBox awk ---------------------------

step 'public suffixes are refused by the BusyBox tools'
suffixes=/usr/share/ikev2-domains/public-suffixes
[ -s "$suffixes" ] || fail 'the public suffix list is not installed'
sed -n '/^normalize_domains() {/,/^}/p; /^normalize_remote_domains() {/,/^}/p' \
	/usr/libexec/ikev2-domains-community >/tmp/filter.sh
(
	public_suffix_file="$suffixes"
	. /tmp/filter.sh
	printf 'Shop.co.uk\nwww.ck\ncity.kawasaki.jp\n' >/tmp/good.lst
	[ "$(normalize_remote_domains /tmp/good.lst | tr '\n' ' ')" = 'city.kawasaki.jp shop.co.uk www.ck ' ] ||
		fail 'names registered under public suffixes were refused'
	for name in co.uk foo.kawasaki.jp anything.ck com; do
		printf 'safe.example\n%s\n' "$name" >/tmp/bad.lst
		if normalize_remote_domains /tmp/bad.lst >/dev/null 2>&1; then
			fail "the public suffix $name was accepted"
		fi
	done
)

# --- a pause refuses what reaches the tunnel ------------------------------

step 'a pause closes the tunnel and resume opens it, with real nft'
uci set ikev2-manager.domains.paused='1'
uci commit ikev2-manager
/usr/libexec/ikev2-manager-system _pause-sync || fail 'the pause block did not install'
[ "$(nft list table inet ikev2_pause | grep -c 'oifname "ipsec-out".* reject')" = 2 ] ||
	fail 'the pause does not refuse both forwarded and router traffic to the tunnel'
nft list chain inet ikev2_pause output | grep -q 'l4proto != { icmp, ipv6-icmp }' ||
	fail 'the pause stops the tunnel quality pings too'
nft delete table inet ikev2_pause
/usr/libexec/ikev2-manager-system _pause-sync || fail 'a dropped pause block was not restored'
nft list table inet ikev2_pause >/dev/null 2>&1 || fail 'a dropped pause block was not restored'
uci set ikev2-manager.domains.paused='0'
uci commit ikev2-manager
/usr/libexec/ikev2-manager-system _pause-sync || fail 'the pause block was not removed'
nft list table inet ikev2_pause >/dev/null 2>&1 && fail 'resume left the tunnel closed'

# --- a segment can fall back to the provider's resolvers -------------------

step 'a segment that asks for the provider resolvers gets them after its own'
uci -q batch <<'EOF2'
set ikev2-manager.dns=dns
set ikev2-manager.dns.managed='1'
set ikev2-manager.dnsseg_withwan=dns_segment
set ikev2-manager.dnsseg_withwan.enabled='1'
set ikev2-manager.dnsseg_withwan.domains='ru'
set ikev2-manager.dnsseg_withwan.upstream='udp://77.88.8.8:53'
set ikev2-manager.dnsseg_withwan.fallback='https://dns.google/dns-query'
set ikev2-manager.dnsseg_withwan.port='5550'
set ikev2-manager.dnsseg_withwan.wan_fallback='1'
set ikev2-manager.dnsseg_nowan=dns_segment
set ikev2-manager.dnsseg_nowan.enabled='1'
set ikev2-manager.dnsseg_nowan.domains='by'
set ikev2-manager.dnsseg_nowan.upstream='udp://77.88.8.1:53'
set ikev2-manager.dnsseg_nowan.fallback='https://dns.google/dns-query'
set ikev2-manager.dnsseg_nowan.port='5551'
commit ikev2-manager
EOF2
mkdir -p /tmp/segbin /var/run
printf '#!/bin/sh\n' >/tmp/segbin/dnsproxy
chmod 755 /tmp/segbin/dnsproxy
: >/tmp/segments.cmd
(
	PATH="/tmp/segbin:$PATH"
	# netifd is not running here; this is what it reports for the WAN.
	ubus() { printf '%s\n' '{"dns-server":["10.0.0.53","127.0.0.1"]}'; }
	procd_open_instance() { printf '== %s\n' "$1" >>/tmp/segments.cmd; }
	procd_set_param() { printf '%s\n' "$*" >>/tmp/segments.cmd; }
	procd_append_param() { printf '%s\n' "$*" >>/tmp/segments.cmd; }
	procd_close_instance() { :; }
	# OpenWrt's shell library reads unset variables.
	set +u
	. /lib/functions.sh
	. /etc/init.d/ikev2-dns-segments
	start_service
)
sed -n '/^== dnsseg_withwan$/,/^== /p' /tmp/segments.cmd | grep -Fxq 'command -f udp://10.0.0.53:53' ||
	fail 'a segment that asks for the provider resolvers did not get them'
sed -n '/^== dnsseg_nowan$/,$p' /tmp/segments.cmd | grep -Fq '10.0.0.53' &&
	fail 'a segment that did not ask for the provider resolvers got them'
grep -Fq 'udp://127.0.0.1' /tmp/segments.cmd && fail 'a loopback resolver from the lease was used'
[ "$(cat /var/run/ikev2-dns-segments.wan)" = 'udp://10.0.0.53:53' ] ||
	fail 'the provider resolvers the segments started with were not recorded'
uci -q delete ikev2-manager.dnsseg_withwan
uci -q delete ikev2-manager.dnsseg_nowan
uci commit ikev2-manager

# --- the inbound link, as a disabled server leaves it ----------------------

step 'a disabled server passes with its link left in place but down'
sed -n '/^inbound_link_up() {/,/^}/p' /usr/libexec/ikev2-manager >/tmp/inbound-link.sh
grep -q 'inbound_link_up' /tmp/inbound-link.sh || fail 'the inbound link check is not installed'
(
	. /tmp/inbound-link.sh
	ip link add ipsec-in type dummy
	ip link set ipsec-in down
	inbound_link_up && fail 'a link that is down read as up'
	ip link set ipsec-in up
	inbound_link_up || fail 'a link that is up read as down'
	ip link del ipsec-in
	inbound_link_up && fail 'a missing link read as up'
	:
)

# --- teardown ---------------------------------------------------------------

step 'stopping removes everything the routing installed'
"$routing" stop
rules4 | grep -q . && fail 'rules survived the stop'
nft list table inet ikev2_routing >/dev/null 2>&1 && fail 'the table survived the stop'
ip -4 route show table 1601 | grep -q . && fail 'the tunnel table survived the stop'

printf 'OpenWrt %s scenarios OK\n' "$release"
