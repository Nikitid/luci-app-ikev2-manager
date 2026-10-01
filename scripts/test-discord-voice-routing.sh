#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-discord-voice.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin"

# The protected sources come from the application's own configuration, as
# policy routing reads them. They used to be read from PBR's domain policy,
# which the built-in routing deletes: the sync then failed and stopped the
# routing sync that came after it.
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get ikev2-manager.globals.configured') echo 1 ;;
	'-q get ikev2-manager.globals.device_schema') echo 2 ;;
	'-q get ikev2-manager.globals.source_interface') echo lan ;;
	'-q get network.lan.device') echo br-lan ;;
	'-q get ikev2-manager.server.enabled') echo 0 ;;
	'show ikev2-manager')
		echo 'ikev2-manager.device_192_168_50_4=device_policy'
		echo 'ikev2-manager.device_192_168_50_9=device_policy'
		;;
	'-q get ikev2-manager.device_192_168_50_4.address') echo 192.168.50.4 ;;
	'-q get ikev2-manager.device_192_168_50_4.route_mode') echo domain ;;
	'-q get ikev2-manager.device_192_168_50_9.address') echo 192.168.50.9 ;;
	'-q get ikev2-manager.device_192_168_50_9.route_mode') echo exclude ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
exit 1
EOF

cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
[ "$*" = '-4 rule show' ] || exit 1
echo '30000: from all fwmark 0x20000/0xff0000 lookup pbr_ikev2out'
EOF

cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in
	192.168.50.4/32 | 192.168.50.9/32) exit 0 ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list table inet ikev2_discord_voice_test')
		[ -s "$TEST_NFT_STATE" ] || exit 1
		cat "$TEST_NFT_RULESET"
		;;
	'list chain inet ikev2_discord_voice_test prerouting')
		[ -s "$TEST_NFT_STATE" ] || exit 1
		cat "$TEST_NFT_RULESET"
		;;
	'delete table inet ikev2_discord_voice_test')
		rm -f "$TEST_NFT_STATE"
		;;
	'-c -f '*) exit 0 ;;
	'-f '*)
		cp "$2" "$TEST_NFT_RULESET"
		printf x >"$TEST_NFT_STATE"
		printf 'apply\n' >>"$TEST_NFT_LOG"
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/ubus" "$tmp/bin/ip" "$tmp/bin/ipcalc.sh" "$tmp/bin/nft"

printf 'discord\n' >"$tmp/selected"
: >"$tmp/nft.log"
export PATH="$tmp/bin:$PATH"
export TEST_NFT_STATE="$tmp/nft.state"
export TEST_NFT_RULESET="$tmp/rules.nft"
export TEST_NFT_LOG="$tmp/nft.log"
export IKEV2_SELECTED_SERVICES="$tmp/selected"
export IKEV2_NFT="$tmp/bin/nft"
export IKEV2_DISCORD_TABLE='ikev2_discord_voice_test'
export IKEV2_DISCORD_SIGNATURE="$tmp/signature"
export IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib"

"$helper" sync
grep -Fq 'chain ikev2_manager_owned' "$tmp/rules.nft"
grep -Fq 'elements = { "br-lan" }' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.50.4 }' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.50.9 }' "$tmp/rules.nft"
grep -Fq 'type ipv4_addr . inet_service' "$tmp/rules.nft"
grep -Fq 'udp length 82 @th,64,32 0x00010046' "$tmp/rules.nft"
grep -Fq 'ip daddr . udp dport @voice_endpoints update @voice_endpoints' "$tmp/rules.nft"
grep -Fq 'update @voice_endpoints { ip daddr . udp dport timeout 6h }' "$tmp/rules.nft"
grep -Fq 'meta mark & 0xff00ffff | 0x00020000' "$tmp/rules.nft"
if grep -Eq '104\.25\.158\.178|104\.16\.0\.0|162\.159\.0\.0' "$tmp/rules.nft"; then
	echo 'Discord voice routing contains a static Cloudflare address' >&2
	exit 1
fi
"$helper" check

"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 1 ] || {
	echo 'unchanged Discord voice policy was reinstalled' >&2
	exit 1
}

: >"$tmp/selected"
"$helper" sync
[ ! -e "$tmp/nft.state" ]
[ ! -e "$tmp/signature" ]

printf '%s\n' 'Discord voice routing checks OK'
