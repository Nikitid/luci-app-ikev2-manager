#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-device-routing.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get ikev2-manager.globals.configured') echo 1 ;;
	'-q get ikev2-manager.domains.paused') [ "${TEST_PAUSED:-0}" = 1 ] && echo 1 || exit 1 ;;
	'show pbr')
		echo 'pbr.pbr_dev_fr_192_168_50_4=policy'
		echo 'pbr.pbr_dev_ex_192_168_50_9=policy'
		;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.name') echo 'VPN Full Route: 192.168.50.4' ;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.enabled') echo 1 ;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.src_addr') echo '192.168.50.4' ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.name') echo 'VPN Exclude: 192.168.50.9' ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.enabled') echo 1 ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.src_addr') echo '192.168.50.9' ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	'-4 rule show')
		echo '30000: from all fwmark 0x10000/0xff0000 lookup pbr_wan'
		echo '29999: from all fwmark 0x20000/0xff0000 lookup pbr_ikev2out'
		;;
	'-4 route show table main default')
		[ "${TEST_DEFAULT_ROUTE_DOWN:-0}" = 1 ] ||
			echo "default via 192.0.2.1 dev ${TEST_DEFAULT_DEVICE:-eth0}"
		;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in 192.168.50.4/32 | 192.168.50.9/32) exit 0 ;; *) exit 1 ;; esac
EOF

cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'-j list table inet ikev2_device_policy_test')
		# The installed program as JSON, with the handles and counter values
		# that change on every listing.
		[ -s "$TEST_NFT_STATE" ] || exit 1
		awk -v seed="$$" '
			BEGIN { srand(seed); printf "{\"nftables\": [{\"metainfo\": {\"version\": \"stub\"}}, {\"table\": {\"family\": \"inet\", \"name\": \"t\", \"handle\": %d}}", int(rand() * 1000) }
			NF {
				line = $0
				gsub(/\\/, "\\\\", line)
				gsub(/"/, "\\\"", line)
				printf ", {\"rule\": {\"handle\": %d, \"text\": \"%s\", \"expr\": [{\"counter\": {\"packets\": %d, \"bytes\": %d}}]}}", int(rand() * 1000), line, int(rand() * 1000), int(rand() * 100000)
			}
			END { print "]}" }
		' "$TEST_NFT_RULESET"
		;;
	'list table inet ikev2_device_policy_test')
		[ -s "$TEST_NFT_STATE" ] || exit 1
		cat "$TEST_NFT_RULESET"
		;;
	'list set inet ikev2_device_policy_test '*)
		[ -s "$TEST_NFT_STATE" ] || exit 1
		set_name="${5:-}"
		if [ "$set_name" = dns_malformed_ipv4 ] &&
		   [ -n "${TEST_DNS_MALFORMED_SET:-}" ]; then
			cat "$TEST_DNS_MALFORMED_SET"
			exit 0
		fi
		awk -v wanted="$set_name" '
			$0 ~ ("set " wanted " ") { active=1 }
			active { print }
			active && /^  }/ { exit }
		' "$TEST_NFT_RULESET"
		;;
	'list chain inet ikev2_device_policy_test '*)
		[ -s "$TEST_NFT_STATE" ] || exit 1
		chain="${5:-}"
		grep -Fq "chain $chain" "$TEST_NFT_RULESET" || exit 1
		awk -v wanted="$chain" '
			$0 ~ ("chain " wanted " ") { active=1 }
			active { print }
			active && /^  }/ { exit }
		' "$TEST_NFT_RULESET"
		;;
	'delete table inet ikev2_device_policy_test') rm -f "$TEST_NFT_STATE" ;;
	'-c -f '*) exit 0 ;;
	'-f '*)
		if [ -n "${TEST_NFT_CANONICAL:-}" ]; then
			# The kernel keeps a mark bit in the AND mask when the OR sets it.
			sed -e 's/0xf0ffffff | 0x02000000/0xf2ffffff | 0x02000000/g' \
				-e 's/0xf0ffffff | 0x01000000/0xf1ffffff | 0x01000000/g' "$2" >"$TEST_NFT_RULESET"
		else
			cp "$2" "$TEST_NFT_RULESET"
		fi
		printf x >"$TEST_NFT_STATE"
		printf 'apply\n' >>"$TEST_NFT_LOG"
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/ip" "$tmp/bin/ipcalc.sh" "$tmp/bin/nft"
cp "$tmp/bin/uci" "$tmp/uci.baseline"

: >"$tmp/nft.log"
export PATH="$tmp/bin:$PATH"
export TEST_NFT_STATE="$tmp/nft.state"
export TEST_NFT_RULESET="$tmp/rules.nft"
export TEST_NFT_LOG="$tmp/nft.log"
export IKEV2_NFT="$tmp/bin/nft"
export IKEV2_DEVICE_TABLE='ikev2_device_policy_test'
export IKEV2_DEVICE_SIGNATURE="$tmp/signature"
export IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib"

# The stub exposes only the previous representation, so this run also covers
# the compatibility path taken between a package upgrade and the first apply.
"$helper" sync
grep -Fq 'chain ikev2_manager_owned' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.50.4 }' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.50.9 }' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.50.9 meta mark set meta mark & 0xf0ffffff | 0x02000000 counter accept comment "ikev2-device:exclude:192.168.50.9"' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.50.4 meta mark set meta mark & 0xf0ffffff | 0x01000000 counter accept comment "ikev2-device:fullroute:192.168.50.4"' "$tmp/rules.nft"
"$helper" check
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 1 ]

# Second phase: the migrated schema is authoritative and the previous
# representation is absent. Different addresses prove the rules were rewritten
# rather than served from the unchanged-signature shortcut.
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get ikev2-manager.globals.configured') echo 1 ;;
	'-q get ikev2-manager.domains.engine') echo fakeip ;;
	'-q get ikev2-manager.globals.device_schema') echo 2 ;;
	'-q get ikev2-manager.globals.dns_enforce') echo 1 ;;
	'-q get ikev2-manager.globals.block_dot') echo 1 ;;
	'-q get ikev2-manager.globals.source_interface') echo lan ;;
	'-q get ikev2-manager.globals.source_include_vpn') echo 1 ;;
	'-q get ikev2-manager.globals.wan_interface') echo "${TEST_MANAGER_WAN:-wan}" ;;
	'-q get ikev2-manager.server.enabled') echo 1 ;;
	'-q get network.lan.device') echo br-lan ;;
	'-q get network.wan.device') [ "${TEST_WAN_DOWN:-0}" != 1 ] && echo eth0 ;;
	'show ikev2-manager')
		echo 'ikev2-manager.device_192_168_60_5=device_policy'
		echo 'ikev2-manager.device_192_168_60_9=device_policy'
		;;
	'-q get ikev2-manager.device_192_168_60_5.address') echo '192.168.60.5' ;;
	'-q get ikev2-manager.device_192_168_60_5.route_mode') echo 'fullroute' ;;
	'-q get ikev2-manager.device_192_168_60_5.dns_passthrough') echo 1 ;;
	'-q get ikev2-manager.device_192_168_60_5.exit') [ -n "${TEST_DEVICE_EXIT:-}" ] && echo "$TEST_DEVICE_EXIT" ;;
	'-q get ikev2-manager.tunnel_2') [ -n "${TEST_TUNNEL_2:-}" ] && echo tunnel ;;
	'-q show ikev2-manager') [ -n "${TEST_TUNNEL_2:-}" ] && echo 'ikev2-manager.tunnel_2=tunnel' ;;
	'-q get ikev2-manager.device_192_168_60_9.address') echo '192.168.60.9' ;;
	'-q get ikev2-manager.device_192_168_60_9.route_mode') echo 'exclude' ;;
	'-q get ikev2-manager.device_192_168_60_9.dns_passthrough') echo 1 ;;
	'-q get ikev2-manager.device_192_168_60_9.dpi_passthrough') echo 1 ;;
	'-q get zapret2.main.enabled') echo 1 ;;
	'-q get zapret2.main.desync_mark') echo '0x40000000' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in
	192.168.50.4/32 | 192.168.50.9/32 | 192.168.60.5/32 | 192.168.60.9/32) exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/ipcalc.sh"

"$helper" sync
grep -Fq 'elements = { 192.168.60.5 }' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.60.9 }' "$tmp/rules.nft"
grep -Fq 'ct original ip saddr @dpi_bypass_ipv4 ct mark & 0x40000000 != 0 meta mark set meta mark | 0x40000000 counter comment "ikev2-device:dpi-restore"' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.60.9 ct mark set ct mark | 0x40000000 meta mark set meta mark | 0x40000000 counter comment "ikev2-device:dpi:192.168.60.9"' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.60.9 meta mark set meta mark & 0xf0ffffff | 0x02000000 counter accept comment "ikev2-device:exclude:192.168.60.9"' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.60.5 meta mark set meta mark & 0xf0ffffff | 0x01000000 counter accept comment "ikev2-device:fullroute:192.168.60.5"' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.60.5, 192.168.60.9 }' "$tmp/rules.nft"
grep -Fq 'elements = { "br-lan", "ipsec-in" }' "$tmp/rules.nft"
grep -Fq 'elements = { "eth0" }' "$tmp/rules.nft"
grep -Fq 'redirect to :53 comment "ikev2-device:dns-enforce"' "$tmp/rules.nft"
grep -Fq 'set dns_malformed_ipv4 {' "$tmp/rules.nft"
grep -Fq 'flags dynamic,timeout' "$tmp/rules.nft"
grep -Fq 'update @dns_malformed_ipv4 { ip saddr timeout 1h } comment "ikev2-device:dns-malformed-source"' "$tmp/rules.nft"
grep -Fq 'udp length < 20 counter drop comment "ikev2-device:dns-malformed"' "$tmp/rules.nft"
grep -Fq 'reject comment "ikev2-device:dot-block"' "$tmp/rules.nft"
"$helper" check

cat >"$tmp/dns-malformed.set" <<'EOF'
table inet ikev2_device_policy_test {
  set dns_malformed_ipv4 {
    type ipv4_addr
    flags dynamic,timeout
    timeout 1h
    size 256
    counter
    elements = { 192.168.60.20 timeout 1h expires 59m counter packets 3 bytes 48,
                 192.168.60.21 timeout 1h expires 58m counter packets 2 bytes 32 }
  }
}
EOF
TEST_DNS_MALFORMED_SET="$tmp/dns-malformed.set"
export TEST_DNS_MALFORMED_SET
dns_stats="$("$helper" dns-malformed-stats)"
printf '%s\n' "$dns_stats" | grep -Fxq 'state=active'
printf '%s\n' "$dns_stats" | grep -Fxq 'source=192.168.60.20 packets=3 bytes=48'
printf '%s\n' "$dns_stats" | grep -Fxq 'source=192.168.60.21 packets=2 bytes=32'
unset TEST_DNS_MALFORMED_SET

# Real nftables retains a mark bit in the AND mask when the following OR sets
# that same bit. The check compares with what the kernel printed right after
# the install, so its rendering of a rule is never read as a missing rule.
TEST_NFT_CANONICAL=1
export TEST_NFT_CANONICAL
rm -f "$IKEV2_DEVICE_SIGNATURE"
"$helper" sync
grep -Fq '0xf1ffffff | 0x01000000' "$tmp/rules.nft"
"$helper" check || { printf '%s\n' "the kernel's rendering of a rule failed the check" >&2; exit 1; }
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 3 ] ||
	{ printf '%s\n' "the kernel's rendering of a rule was reinstalled" >&2; exit 1; }
unset TEST_NFT_CANONICAL
rm -f "$IKEV2_DEVICE_SIGNATURE"
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 4 ]

# Device FakeIP overrides choose a live inbound for both transports; stale
# sing-box source exclusions must not participate in this decision.
for proto in tcp udp; do
	grep -Fq "ip saddr @exclude_ipv4 ip daddr 198.18.0.0/15 meta l4proto $proto meta mark set 0x00400001 tproxy ip to 127.0.0.1:1603" "$tmp/rules.nft"
	grep -Fq "ip saddr @full_route_ipv4 ip daddr 198.18.0.0/15 meta l4proto $proto meta mark set 0x00400002 tproxy ip to 127.0.0.1:1604" "$tmp/rules.nft"
done
cp "$tmp/rules.nft" "$tmp/rules.healthy"
sed 's/:1603/:1699/g' "$tmp/rules.healthy" >"$tmp/rules.nft"
if "$helper" check; then
	printf '%s\n' 'incorrect FakeIP ingress was accepted' >&2
	exit 1
fi
mv "$tmp/rules.healthy" "$tmp/rules.nft"
"$helper" check


# A removed logical WAN must not leave DoT enforcement bound to its obsolete
# physical interface. The active default route is the authoritative fallback
# and is picked up without changing the saved manager configuration.
TEST_MANAGER_WAN=removed_wwan
TEST_DEFAULT_DEVICE=eth1
export TEST_MANAGER_WAN TEST_DEFAULT_DEVICE
# Until then the installed rules no longer match what the router needs.
if "$helper" check; then
	printf '%s\n' 'a changed egress device passed the check before a sync' >&2
	exit 1
fi
"$helper" sync
grep -Fq 'elements = { "eth1" }' "$tmp/rules.nft"
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 5 ]
unset TEST_MANAGER_WAN TEST_DEFAULT_DEVICE
"$helper" sync
grep -Fq 'elements = { "eth0" }' "$tmp/rules.nft"
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 6 ]

# A total WAN outage has neither a runtime l3_device nor a default route.
# Preserve the last validated device set instead of declaring the runtime bad.
TEST_WAN_DOWN=1
TEST_DEFAULT_ROUTE_DOWN=1
export TEST_WAN_DOWN TEST_DEFAULT_ROUTE_DOWN
"$helper" check
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 6 ]
unset TEST_WAN_DOWN TEST_DEFAULT_ROUTE_DOWN

# A matching signature is not enough: runtime health must notice externally
# removed rules and sync must reconstruct them.
sed '/ikev2-device:fullroute:192.168.60.5/d' "$tmp/rules.nft" >"$tmp/rules.corrupt"
mv "$tmp/rules.corrupt" "$tmp/rules.nft"
if "$helper" check >/dev/null 2>&1; then
	printf '%s\n' 'corrupted device-routing runtime passed health check' >&2
	exit 1
fi
"$helper" sync
grep -Fq 'comment "ikev2-device:fullroute:192.168.60.5"' "$tmp/rules.nft"
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 7 ]
sed 's/0x01000000 counter accept comment "ikev2-device:fullroute:192.168.60.5"/0x03000000 counter accept comment "ikev2-device:fullroute:192.168.60.5"/' \
	"$tmp/rules.nft" >"$tmp/rules.wrong-mark"
mv "$tmp/rules.wrong-mark" "$tmp/rules.nft"
if "$helper" check >/dev/null 2>&1; then
	printf '%s\n' 'device-routing rule with a wrong mark passed health check' >&2
	exit 1
fi
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 8 ]

sed '/ikev2-device:dns-enforce/d' "$tmp/rules.nft" >"$tmp/rules.no-dns"
mv "$tmp/rules.no-dns" "$tmp/rules.nft"
if "$helper" check >/dev/null 2>&1; then
	printf '%s\n' 'missing DNS interception rule passed health check' >&2
	exit 1
fi
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 9 ]

# A configured DPI bypass without Zapret's published mark must fail closed and
# leave the already installed rules untouched.
cp "$tmp/bin/uci" "$tmp/bin/uci.zapret2"
sed '/zapret2.main.enabled/d; /zapret2.main.desync_mark/d' \
	"$tmp/bin/uci" >"$tmp/bin/uci.no-mark"
mv "$tmp/bin/uci.no-mark" "$tmp/bin/uci"
chmod 755 "$tmp/bin/uci"
before_rules="$(cat "$tmp/rules.nft")"
if "$helper" sync 2>/dev/null; then
	printf '%s\n' 'DPI passthrough was accepted without a Zapret mark' >&2
	exit 1
fi
[ "$(cat "$tmp/rules.nft")" = "$before_rules" ]

# The legacy Zapret1 integration remains supported without adding conntrack
# restoration rules that its nftables hook does not consume.
sed "s/'-q get zapret2.main.enabled') echo 1 ;;/'-q get zapret.config.DESYNC_MARK') echo '0x40000000' ;;/; /zapret2.main.desync_mark/d" \
	"$tmp/bin/uci.zapret2" >"$tmp/bin/uci"
chmod 755 "$tmp/bin/uci"
"$helper" sync
grep -Fq 'ip saddr 192.168.60.9 meta mark set meta mark | 0x40000000 counter comment "ikev2-device:dpi:192.168.60.9"' "$tmp/rules.nft"
if grep -Fq 'ikev2-device:dpi-restore' "$tmp/rules.nft"; then
	printf '%s\n' 'Zapret1 DPI passthrough unexpectedly installed Zapret2 reply restoration' >&2
	exit 1
fi

# A malformed entry must fail the sync instead of quietly producing an empty
# set, which would pull an excluded device back into the tunnel.
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get ikev2-manager.globals.configured') echo 1 ;;
	'-q get ikev2-manager.globals.device_schema') echo 2 ;;
	'show ikev2-manager') echo 'ikev2-manager.device_bad=device_policy' ;;
	'-q get ikev2-manager.device_bad.address') echo 'not-an-address' ;;
	'-q get ikev2-manager.device_bad.route_mode') echo 'exclude' ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci"
if "$helper" sync 2>/dev/null; then
	printf '%s\n' 'malformed device policy was accepted' >&2
	exit 1
fi

# nftables lists "!= 0" back as "!= 0x00000000". Verifying the installed rules
# by searching that listing for the written form made an installed DPI-restore
# rule unverifiable, and the doctor reported the device policy missing while it
# worked. The runtime is verified by the kernel's own listing now, never text.
if awk '/^(sync_runtime|check_runtime|desired_state)\(\) \{/,/^}/' \
	"$root/ikev2-manager-runtime/ikev2-device-routing.sh" | grep -n 'list chain\|list set'; then
	printf '%s\n' 'device routing still verifies its rules by searching the nft listing' >&2
	exit 1
fi

cp "$tmp/uci.baseline" "$tmp/bin/uci"
# A pause keeps the device policy: full-tunnel devices are refused at the
# tunnel (ikev2_pause), and a sync during a pause leaves the policy in place.
"$helper" sync
[ -s "$TEST_NFT_STATE" ] || { printf '%s\n' 'device policy was not installed before the pause' >&2; exit 1; }
TEST_PAUSED=1 "$helper" sync
[ -s "$TEST_NFT_STATE" ] || { printf '%s\n' 'a sync during a pause removed the device policy' >&2; exit 1; }
TEST_PAUSED=1 "$helper" check || { printf '%s\n' 'the device policy reported unhealthy during a pause' >&2; exit 1; }

# A full-route device sent through the second tunnel: that exit's mark and
# FakeIP inbound, and nothing of the first exit's; with the tunnel removed it
# is the first exit's again.
cp "$tmp/bin/uci.zapret2" "$tmp/bin/uci"
"$helper" sync
TEST_DEVICE_EXIT=2 TEST_TUNNEL_2=1
export TEST_DEVICE_EXIT TEST_TUNNEL_2
"$helper" check && { printf '%s\n' 'a device moved to another exit passed the check' >&2; exit 1; }
"$helper" sync
grep -Fq 'ip saddr 192.168.60.5 meta mark set meta mark & 0xf0ffffff | 0x03000000 counter accept comment "ikev2-device:fullroute-x2:192.168.60.5"' "$tmp/rules.nft" ||
	{ printf '%s\n' 'a device of the second exit does not get its mark' >&2; exit 1; }
for proto in tcp udp; do
	grep -Fq "ip saddr @full_route_x2_ipv4 ip daddr 198.18.0.0/15 meta l4proto $proto meta mark set 0x00400002 tproxy ip to 127.0.0.1:1612" "$tmp/rules.nft" ||
		{ printf '%s\n' 'a device of the second exit does not reach its FakeIP inbound' >&2; exit 1; }
done
! grep -Fq 'comment "ikev2-device:fullroute:192.168.60.5"' "$tmp/rules.nft" ||
	{ printf '%s\n' 'a device of the second exit kept the first exit mark' >&2; exit 1; }
# Bound to the second tunnel, without backup: the mark and the inbound of that
# exit, which never moves to another tunnel.
TEST_DEVICE_EXIT=2s
"$helper" check && { printf '%s\n' 'a device bound to its tunnel passed the check unchanged' >&2; exit 1; }
"$helper" sync
grep -Fq 'ip saddr 192.168.60.5 meta mark set meta mark & 0xf0ffffff | 0x0a000000 counter accept comment "ikev2-device:fullroute-x2s:192.168.60.5"' "$tmp/rules.nft" ||
	{ printf '%s\n' 'a device bound to the second tunnel does not get the mark of that exit' >&2; exit 1; }
for proto in tcp udp; do
	grep -Fq "ip saddr @full_route_x2s_ipv4 ip daddr 198.18.0.0/15 meta l4proto $proto meta mark set 0x00400002 tproxy ip to 127.0.0.1:1622" "$tmp/rules.nft" ||
		{ printf '%s\n' 'a device bound to the second tunnel does not reach its FakeIP inbound' >&2; exit 1; }
done
! grep -Fq 'fullroute-x2:' "$tmp/rules.nft" && ! grep -Fq 'full_route_x2_ipv4' "$tmp/rules.nft" ||
	{ printf '%s\n' 'a device bound to its tunnel is also where it may move' >&2; exit 1; }
unset TEST_TUNNEL_2
"$helper" sync
grep -Fq 'comment "ikev2-device:fullroute:192.168.60.5"' "$tmp/rules.nft" && ! grep -Fq full_route_x2 "$tmp/rules.nft" ||
	{ printf '%s\n' 'a device of a removed tunnel did not return to the first exit' >&2; exit 1; }
unset TEST_DEVICE_EXIT
"$helper" sync

printf '%s\n' 'device routing checks OK'
