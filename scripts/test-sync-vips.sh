#!/bin/sh
#
# The outbound VIP sync must claim only this application's own virtual IP.
# A router can run a second, unrelated IKEv2 client (a site link, for example);
# adopting its VIP installs a foreign address on ipsec-out and silently breaks
# every route that points at the outbound tunnel.

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
script="$root/ikev2-manager-runtime/ikev2-sync-vips.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf 'test-sync-vips: %s\n' "$*" >&2
	exit 1
}

bin="$tmp/bin"
mkdir -p "$bin"

cat >"$bin/uci" <<STUB
#!/bin/sh
case "\$*" in
	*show*) cat "$tmp/uci-show" ;;
	*) printf '1\\n' ;;
esac
STUB
cat >"$tmp/uci-show" <<'EOF'
ikev2-manager.client=client
ikev2-manager.client.enabled='1'
EOF

# Two IKEv2 clients are up. proxy-out is this application's; site-link belongs
# to another package and is listed after it, so an unfiltered scrape that keeps
# the last match would take the wrong address.
cat >"$tmp/sa.json" <<'JSON'
{"errors":[],"data":[{"proxy-out":{"state":"ESTABLISHED","local-vips":["10.20.20.10"]}},{"site-link":{"state":"ESTABLISHED","local-vips":["10.253.44.2"]}}]}
JSON
IKEV2_SA_HELPER="$root/ikev2-manager-runtime/ikev2-sa.sh"
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib"
IKEV2_SA_JSON="$tmp/sa.json"
export IKEV2_SA_HELPER IKEV2_RUNTIME_LIB_DIR IKEV2_SA_JSON

cat >"$bin/ip" <<STUB
#!/bin/sh
case "\$*" in
	*"addr show dev ipsec-out2"*) : ;;
	*"addr show dev ipsec-out"*) printf '9: ipsec-out    inet 10.253.44.2/32 scope global ipsec-out\n' ;;
	*"link show ipsec-out"*) : ;;
	*) printf '%s\n' "\$*" >>"$tmp/ip-calls" ;;
esac
STUB

chmod 755 "$bin/uci" "$bin/ip"

# The helper records the result under /var/run; relocate it so the test never
# touches machine state.
sed "s#/var/run/ikev2-vip4#$tmp/ikev2-vip4#g" "$script" >"$tmp/sync-vips"
chmod 755 "$tmp/sync-vips"

: >"$tmp/ip-calls"
PATH="$bin:$PATH" "$tmp/sync-vips" || fail 'sync helper exited non-zero'

recorded="$(cat "$tmp/ikev2-vip4")"
[ "$recorded" = '10.20.20.10' ] ||
	fail "adopted the wrong virtual IP: $recorded"

grep -Fq 'addr add 10.20.20.10/32 dev ipsec-out' "$tmp/ip-calls" ||
	fail 'the owning virtual IP was not installed on ipsec-out'
if grep -Fq '10.253.44.2' "$tmp/ip-calls"; then
	fail 'a foreign virtual IP was installed on ipsec-out'
fi

# A second tunnel gets its own address on its own link, and the first keeps
# its own.
cat >>"$tmp/uci-show" <<'EOF'
ikev2-manager.tunnel_2=tunnel
ikev2-manager.tunnel_2.enabled='1'
ikev2-manager.tunnel_3=tunnel
ikev2-manager.tunnel_3.enabled='0'
EOF
cat >"$tmp/sa.json" <<'JSON'
{"errors":[],"data":[{"proxy-out-2":{"state":"ESTABLISHED","local-vips":["10.30.0.7"]}},{"proxy-out-3":{"state":"ESTABLISHED","local-vips":["10.40.0.9"]}},{"proxy-out":{"state":"ESTABLISHED","local-vips":["10.20.20.10"]}},{"site-link":{"state":"ESTABLISHED","local-vips":["10.253.44.2"]}}]}
JSON
: >"$tmp/ip-calls"
PATH="$bin:$PATH" "$tmp/sync-vips" || fail 'sync helper exited non-zero with two tunnels'
[ "$(cat "$tmp/ikev2-vip4-2")" = '10.30.0.7' ] || fail 'the second tunnel address was not recorded'
grep -Fq 'addr add 10.30.0.7/32 dev ipsec-out2' "$tmp/ip-calls" ||
	fail 'the second tunnel address was not installed on its own link'
[ ! -e "$tmp/ikev2-vip4-3" ] && ! grep -Fq '10.40.0.9' "$tmp/ip-calls" ||
	fail 'a disabled tunnel got an address'
grep -Fq 'addr add 10.20.20.10/32 dev ipsec-out' "$tmp/ip-calls" ||
	fail 'the first tunnel lost its address to the second'

# With the first tunnel down, the status is still the first tunnel's.
cat >"$tmp/sa.json" <<'JSON'
{"errors":[],"data":[{"proxy-out-2":{"state":"ESTABLISHED","local-vips":["10.30.0.7"]}}]}
JSON
PATH="$bin:$PATH" "$tmp/sync-vips" && fail 'the first tunnel without an address was reported synced'

printf 'sync vips tests OK\n'
