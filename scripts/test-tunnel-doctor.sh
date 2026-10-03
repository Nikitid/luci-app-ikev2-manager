#!/bin/sh

# With more than one tunnel the readiness report names a tunnel that cannot
# connect or carry traffic, and an exit whose traffic is refused because no
# tunnel is left for it. With one tunnel it says nothing new.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf 'tunnel doctor: %s\n' "$*" >&2
	exit 1
}

mkdir -p "$tmp/bin" "$tmp/uci"
cp "$root/scripts/uci-stub.sh" "$tmp/bin/uci"
# The links that exist are listed in a file.
cat >"$tmp/bin/ip" <<'STUB'
#!/bin/sh
[ "$1 $2 $3" = 'link show dev' ] || exit 1
grep -qx "$4" "$TEST_LINKS"
STUB
# The SA reader answers from a file, or fails when there is none.
cat >"$tmp/bin/sa" <<'STUB'
#!/bin/sh
[ "$1" = tunnels ] && [ -r "$TEST_SA" ] && cat "$TEST_SA"
STUB
chmod 755 "$tmp/bin/uci" "$tmp/bin/ip" "$tmp/bin/sa"

report() {
	UCI_STUB_DIR="$tmp/uci" TEST_LINKS="$tmp/links" TEST_SA="$tmp/sa" \
	IKEV2_SA_HELPER="$tmp/bin/sa" IKEV2_TUNNELS_SECRET_DB="$tmp/tunnels.secret" \
	IKEV2_EXITS_FILE="$tmp/exits" PATH="$tmp/bin:$PATH" sh -ec '
		. "$1/ikev2-manager-runtime/lib/package-manager.sh"
		. "$1/ikev2-manager-runtime/lib/tunnel.sh"
		. "$1/ikev2-manager-runtime/lib/system-doctor.sh"
		defaultv() { value="$(uci -q get "ikev2-manager.$1.$2")"; printf "%s\n" "${value:-$3}"; }
		test_dir="$2"
		device_fullroute_exits() { cat "$test_dir/devices" 2>/dev/null; }
		doctor_tunnels' sh "$root" "$tmp"
}

expect() {
	actual="$(report)"
	[ "$actual" = "$2" ] || fail "$1: expected '$2', got '$actual'"
}

# Tunnel 2 is down, tunnel 3 has no password, and nothing backs anything up,
# so the device sent through the disabled tunnel 4 has no tunnel at all.
printf '%s\n' 'client=client' 'client.enabled=1' 'client.backup=0' \
	'tunnel_2=tunnel' 'tunnel_2.enabled=1' 'tunnel_2.backup=0' \
	'tunnel_3=tunnel' 'tunnel_3.enabled=1' 'tunnel_3.backup=0' \
	'tunnel_4=tunnel' 'domains=domains' >"$tmp/uci/ikev2-manager"
printf '2\tuser2\t0sMg==\n3\tuser3\t\n' >"$tmp/tunnels.secret"
printf '%s\n' ipsec-out ipsec-out2 >"$tmp/links"
printf '1\t1\t10.0.0.2\n2\t0\t-\n' >"$tmp/sa"
printf 'openai 2\n@domains 3\n' >"$tmp/exits"
printf '192.168.1.40 4\n' >"$tmp/devices"
expect 'a broken setup' 'tunnels=warn:2-down,3-no-password,exit-4-no-tunnel'

# Devices count without a service sent elsewhere, which leaves no exits file.
mv "$tmp/exits" "$tmp/exits.off"
expect 'devices only' 'tunnels=warn:2-down,3-no-password,exit-4-no-tunnel'
mv "$tmp/exits.off" "$tmp/exits"

# A pause closes the tunnels on purpose.
printf '%s\n' 'domains.paused=1' >>"$tmp/uci/ikev2-manager"
expect 'a paused router' 'tunnels=warn:3-no-password,exit-4-no-tunnel'
sed -i.bak '/paused/d' "$tmp/uci/ikev2-manager"

# Without an answer from charon nothing is said about being up.
mv "$tmp/sa" "$tmp/sa.off"
expect 'charon not answering' 'tunnels=warn:3-no-password,exit-4-no-tunnel'
mv "$tmp/sa.off" "$tmp/sa"

# A password without its link.
printf '2\tuser2\t0sMg==\n3\tuser3\t0sMw==\n' >"$tmp/tunnels.secret"
expect 'a missing link' 'tunnels=warn:2-down,3-no-link,exit-4-no-tunnel'

# Everything up, and the first tunnel backs the others up.
printf '%s\n' ipsec-out3 >>"$tmp/links"
printf '1\t1\t10.0.0.2\n2\t1\t10.0.1.2\n3\t1\t10.0.2.2\n' >"$tmp/sa"
sed -i.bak "/client.backup/d" "$tmp/uci/ikev2-manager"
expect 'a working setup' 'tunnels=ok'

# Bound to a tunnel that is switched off: with backup its traffic would move
# to another tunnel, without backup it is refused, and that is said.
sed -i.bak 's/^tunnel_2.enabled=1$/tunnel_2.enabled=0/' "$tmp/uci/ikev2-manager"
printf 'openai 2\n@domains 3\n' >"$tmp/exits"
expect 'a disabled tunnel that others stand in for' 'tunnels=ok'
printf 'openai 2s\n@domains 3\n' >"$tmp/exits"
expect 'bound to a disabled tunnel' 'tunnels=warn:exit-2s-no-tunnel'
sed -i.bak 's/^tunnel_2.enabled=0$/tunnel_2.enabled=1/' "$tmp/uci/ikev2-manager"
expect 'bound to a tunnel that is on' 'tunnels=ok'
printf 'openai 2\n@domains 3\n' >"$tmp/exits"

# An exit of a tunnel that is not configured leaves by the first one.
printf '192.168.1.40 5\n' >"$tmp/devices"
printf '%s\n' 'client.backup=0' 'tunnel_2.backup=0' >>"$tmp/uci/ikev2-manager"
expect 'an exit of a removed tunnel' 'tunnels=ok'

# One tunnel: nothing new in the report.
printf '%s\n' 'client=client' 'client.enabled=1' 'domains=domains' >"$tmp/uci/ikev2-manager"
expect 'one tunnel' ''

printf '%s\n' 'tunnel doctor tests OK'
