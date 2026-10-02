#!/bin/sh

set -eu

runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
vip_file="${IKEV2_VIP_FILE:-/var/run/ikev2-vip4}"
. "$runtime_lib_dir/tunnel.sh"

tunnel_settings_load
[ -n "$tunnel_on" ] || exit 1
[ "$(uci -q get ikev2-manager.globals.configured)" = 1 ] ||
	ip link show ipsec-out >/dev/null 2>&1 || exit 1

# Outbound tunnels are IPv4-only (clients have no provider IPv6). Sync just
# the v4 VIP of each onto its own link.
#
# The SA list must be scoped to this application's own connections. An
# unfiltered list also reports the virtual IPs of any other IKEv2 client on the
# router, and adopting one of those installs a foreign address on a tunnel
# link, which silently breaks every route that points at it.
tunnels="$("${IKEV2_SA_HELPER:-/usr/libexec/ikev2-sa}" tunnels 2>/dev/null || :)"

# sync_tunnel INDEX: put the tunnel's address on its link. Fails when the
# tunnel has none.
sync_tunnel() {
	local index="$1" line_index installed vip4='' current4 file
	while IFS="$(printf '\t')" read -r line_index installed address; do
		[ "$line_index" = "$index" ] || continue
		[ "$address" = - ] || vip4="$address"
	done <<EOF
$tunnels
EOF
	[ -n "$vip4" ] || return 1
	tunnel_names "$index"
	file="$vip_file"
	[ "$index" = 1 ] || file="$vip_file-$index"

	current4="$(
		ip -4 -o addr show dev "$tunnel_link" scope global |
			awk 'NR == 1 { split($4, address, "/"); print address[1] }'
	)"

	if [ "$current4" != "$vip4" ]; then
		ip -4 addr flush dev "$tunnel_link" scope global
		ip addr add "$vip4/32" dev "$tunnel_link"

		# Masqueraded flows retain the old VIP in conntrack after a rekey.
		# Remove only those stale NAT mappings so clients reconnect immediately.
		if [ -n "$current4" ] && command -v conntrack >/dev/null 2>&1; then
			conntrack -D --reply-dst "$current4" >/dev/null 2>&1 || :
		fi
	fi

	printf '%s\n' "$vip4" >"$file"
}

# The exit status is the first tunnel's when it is enabled, as callers that
# bring it up rely on; otherwise whether any tunnel has its address.
rc=1
synced=0
for index in $tunnel_on; do
	if sync_tunnel "$index"; then
		synced=1
		[ "$index" != 1 ] || rc=0
	fi
done
case " $tunnel_on " in *' 1 '*) ;; *) [ "$synced" = 0 ] || rc=0 ;; esac
exit "$rc"
