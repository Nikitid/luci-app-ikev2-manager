#!/bin/sh

# The diagnostics report is meant to be attached to a public bug report. What
# identifies the router, its owner or its users must not survive in it, and
# what the routing cannot be read without must.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf 'diagnostics: %s\n' "$*" >&2
	[ ! -s "$tmp/out" ] || sed 's/^/  report: /' "$tmp/out" >&2
	exit 1
}

printf 'bob\t0sYm9i\ncarol\t0sY2Fyb2w=\n' >"$tmp/users.db"
# The third tunnel's user is named only by the tunnels' credential store.
printf '2\tdave.tunnel\t0sZGF2ZQ==\n3\terin.tunnel\t0sZXJpbg==\n' >"$tmp/tunnels.secret"

# The settings the report reads, as a file: the report runs under set -e,
# which a check inside a condition would switch off, so one run of it is a
# process of its own.
cat >"$tmp/env.sh" <<'EOF'
config=ikev2-manager
IKEV2_USERS_DB="$tmp/users.db"
IKEV2_TUNNELS_SECRET_DB="$tmp/tunnels.secret"
IKEV2_DIAGNOSTICS_CERT="$tmp/none.pem"
die() { printf '%s\n' "$*" >&2; exit 1; }
uci() {
	[ "$1" = -q ] && shift
	case "$1 $2" in
		'get ikev2-manager.client.remote_address') echo 185.12.34.56 ;;
		'get ikev2-manager.client.remote_id') echo exit.vpn-provider.test ;;
		'get ikev2-manager.client.username') echo alice.tunnel ;;
		'get ikev2-manager.server.identity') echo home.example.org ;;
		'get ikev2-manager.user_1.username') echo bob ;;
		'get ikev2-manager.user_2.username') echo carol ;;
		'get ikev2-manager.tunnel_2.remote_address') echo 91.200.1.2 ;;
		'get ikev2-manager.tunnel_2.remote_id') echo nl.vpn-provider.test ;;
		'get ikev2-manager.tunnel_2.username') echo dave.tunnel ;;
		'get ikev2-manager.tunnel_3.remote_address') echo de.vpn-provider.test ;;
		'get system.@system[0].hostname') echo MyRouter ;;
		'show ikev2-manager') printf '%s\n' 'ikev2-manager.user_1=user' 'ikev2-manager.user_2=user' \
			'ikev2-manager.tunnel_2=tunnel' 'ikev2-manager.tunnel_3=tunnel' ;;
		*) return 1 ;;
	esac
}
EOF

(
	. "$tmp/env.sh"
	. "$root/ikev2-manager-runtime/lib/system-diagnostics.sh"
	diagnostics_identities >"$tmp/identities"
	cat >"$tmp/report" <<'EOF'
ikev2-manager.client.password='hunter2 with spaces'
ikev2-manager.client.remote_address='185.12.34.56'
client.secret=0123456789abcdef
token=abc
remote 'exit.vpn-provider.test' @ 185.12.34.56[4500], identity alice.tunnel.
sending packet: from 77.37.10.20[4500] to 185.12.34.56[4500]
again from 77.37.10.20 and 45.67.89.10
lan 192.168.1.1/24 vpn 10.20.30.1 cgnat 100.64.0.1 fakeip 198.18.0.5/15 loop 127.0.0.42#53
resolvers 1.1.1.1 8.8.8.8 77.88.8.8 netmask 255.255.255.0
user bob connected; bobby is someone else, carol left.
server home.example.org and api.home.example.org, router MyRouter
device aa:bb:cc:dd:ee:ff
ikev2-manager.tunnel_2.remote_address='91.200.1.2'
remote 'nl.vpn-provider.test' @ 91.200.1.2[4500], identity dave.tunnel.
tunnel 3 de.vpn-provider.test as erin.tunnel
v6 2a02:6b8:a::a and 2001:db8:1:2:3:4:5:6 local fe80::1 ula fd00::5 at 23:59:01
		elements = { 93.184.216.34, 1.2.3.4,
			 5.6.7.8 }
		elements = { 10.0.0.1 }
EOF
	# Spelled out here, the markers would read as key material to the
	# public-tree check.
	printf -- '-----%s PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----%s PRIVATE KEY-----\nafter the key\n' \
		BEGIN END >>"$tmp/report"
	diagnostics_collapse_sets <"$tmp/report" | diagnostics_redact "$tmp/identities" >"$tmp/out"
	# An empty identities file must not swallow the report as identities.
	: >"$tmp/empty"
	printf 'line from 45.67.89.10\n' | diagnostics_redact "$tmp/empty" >"$tmp/empty.out"
)

# With one tunnel there is no tunnels' credential store.
sh -ec '
	tmp="$1"
	. "$tmp/env.sh"
	IKEV2_TUNNELS_SECRET_DB="$tmp/missing"
	. "$2/ikev2-manager-runtime/lib/system-diagnostics.sh"
	diagnostics_identities >/dev/null' sh "$tmp" "$root" 2>/dev/null ||
	fail 'the identities failed without the tunnels credential store'

out="$tmp/out"
for secret in hunter2 0123456789abcdef 'token=abc' 185.12.34.56 exit.vpn-provider.test \
	alice.tunnel 77.37.10.20 45.67.89.10 home.example.org MyRouter MIIEvQ \
	aa:bb:cc:dd:ee:ff 2a02:6b8 2001:db8 93.184.216.34 1.2.3.4 'bob ' 'carol' \
	91.200.1.2 nl.vpn-provider.test dave.tunnel de.vpn-provider.test erin.tunnel; do
	! grep -Fq -- "$secret" "$out" || fail "the report still contains $secret"
done
grep -Fq 'ikev2-manager.client.password=<redacted>' "$out" || fail 'a password setting lost its name'
grep -Fq 'to <tunnel-server>[4500]' "$out" || fail 'the tunnel server is not named by its placeholder'
grep -Fq 'identity <tunnel-user>.' "$out" || fail 'the tunnel user at the end of a sentence was not replaced'
grep -Fq "remote '<tunnel-2-server-id>' @ <tunnel-2-server>[4500], identity <tunnel-2-user>." "$out" &&
	grep -Fq 'tunnel 3 <tunnel-3-server> as <tunnel-3-user>' "$out" ||
	fail "another tunnel's server or user is not named by its own placeholder"
grep -Fq 'from <ip-1>[4500]' "$out" && grep -Fq 'again from <ip-1> and <ip-2>' "$out" ||
	fail 'one public address does not keep one placeholder'
grep -Fq 'lan 192.168.1.1/24 vpn 10.20.30.1 cgnat 100.64.0.1 fakeip 198.18.0.5/15 loop 127.0.0.42#53' "$out" ||
	fail 'private, FakeIP or loopback addresses were removed'
grep -Fq 'resolvers 1.1.1.1 8.8.8.8 77.88.8.8 netmask 255.255.255.0' "$out" ||
	fail 'well-known resolvers or a netmask were removed'
grep -Fq 'user <user-1> connected; bobby is someone else, <user-2> left.' "$out" ||
	fail 'user names are not replaced as whole words'
grep -Fq 'server <server-name> and api.<server-name>, router <router-name>' "$out" ||
	fail 'the server or router name survived, or a subdomain kept it'
grep -Fxq '<pem block removed>' "$out" && grep -Fxq 'after the key' "$out" ||
	fail 'a PEM block was not replaced, or what follows it went with it'
grep -Fq 'device <mac-1>' "$out" || fail 'a MAC address was not replaced'
grep -Fq 'local fe80::1 ula fd00::5 at 23:59:01' "$out" ||
	fail 'a link-local or unique local address, or a time of day, was taken for a public address'
grep -Fq 'elements = { 3 entries }' "$out" && grep -Fq 'elements = { 1 entries }' "$out" ||
	fail 'set elements are listed instead of counted'
grep -Fxq 'line from <ip-1>' "$tmp/empty.out" || fail 'with no identities the report was not filtered'

printf '%s\n' 'diagnostics report tests OK'
