#!/bin/sh

set -u

config='ikev2-manager'
selected_file="${IKEV2_SELECTED_SERVICES:-/etc/pbr-ikev2-community-selected.txt}"
# Voice leaves by the exit chosen for the Discord service; see the community
# helper.
exits_file="${IKEV2_EXITS_FILE:-/etc/pbr-ikev2-exits.txt}"
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
table="${IKEV2_DISCORD_TABLE:-ikev2_discord_voice}"
signature_file="${IKEV2_DISCORD_SIGNATURE:-/var/run/ikev2-discord-voice.signature}"
endpoint_timeout='6h'
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/devices.sh"
. "$runtime_lib_dir/nft-runtime.sh"

die() {
	printf '%s\n' "$*" >&2
	return 1
}

discord_selected() {
	[ -r "$selected_file" ] && grep -qx 'discord' "$selected_file"
}

stop_runtime() {
	if runtime_exists; then
		runtime_owned || {
			die "nft table '$table' exists but is not owned by IKEv2 Manager"
			return 1
		}
		"$nft_bin" delete table inet "$table" >/dev/null 2>&1 || return 1
	fi
	rm -f "$signature_file"
}

collect_sources() {
	ifaces="$1"
	addresses="$2"
	excluded="$3"
	: >"$ifaces"
	: >"$addresses"
	: >"$excluded"

	# The sources policy routing uses. They used to be read back from PBR's
	# domain policy, which the built-in routing removes, so Discord voice
	# failed and took the rest of the routing sync down with it.
	device_source_devices >"$ifaces" || return 1
	device_addresses domain >"$addresses" || return 1
	device_addresses exclude >"$excluded" || return 1

	for file in "$ifaces" "$addresses" "$excluded"; do
		sort -u "$file" >"${file}.sorted" || return 1
		mv "${file}.sorted" "$file" || return 1
	done
	[ -s "$ifaces" ] || [ -s "$addresses" ]
}

ifname_elements() {
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "\"%s\"", $0; first=0 }' "$1"
}

address_elements() {
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "%s", $0; first=0 }' "$1"
}

set_elements_line() {
	file="$1"
	type="$2"
	[ -s "$file" ] || return 0
	printf '    elements = { '
	case "$type" in
		ifname) ifname_elements "$file" ;;
		ipv4) address_elements "$file" ;;
	esac
	printf ' }\n'
}

sync_runtime() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ] &&
		discord_selected || {
			stop_runtime
			return $?
		}

	rule="$(routing_mark_rule tunnel)"
	case "$rule" in
		0x[0-9A-Fa-f]*/0x[0-9A-Fa-f]*) ;;
		*) die 'Unable to derive the active tunnel routing mark'; return 1 ;;
	esac
	mark="${rule%%/*}"
	mask="${rule#*/}"
	mark_value=$((mark))
	exit="$(awk '$1 == "discord" { print $2; exit }' "$exits_file" 2>/dev/null)"
	case "$exit" in
		[2-8])
			# The mark of another exit, when its tunnel is configured (tunnel.sh).
			! uci -q get "$config.tunnel_$exit" >/dev/null 2>&1 ||
				mark_value=$(((exit + 1) << 24))
			;;
	esac
	mask_value=$((mask))
	clear_value=$((0xffffffff ^ mask_value))
	mark_hex="$(printf '0x%08x' "$mark_value")"
	clear_hex="$(printf '0x%08x' "$clear_value")"

	work="${TMPDIR:-/tmp}/ikev2-discord-voice.$$"
	mkdir -p "$work" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	ifaces="$work/ifaces"
	addresses="$work/addresses"
	excluded="$work/excluded"
	collect_sources "$ifaces" "$addresses" "$excluded" || {
		die 'Unable to derive protected sources for Discord voice routing'
		return 1
	}

	signature="$({
		printf 'mark=%s\nclear=%s\nifaces\n' "$mark_hex" "$clear_hex"
		cat "$ifaces"
		printf 'addresses\n'
		cat "$addresses"
		printf 'excluded\n'
		cat "$excluded"
	} | sha256sum | awk '{ print $1 }')"
	if runtime_owned && [ "$(cat "$signature_file" 2>/dev/null || true)" = "$signature" ]; then
		rm -rf "$work"
		trap - EXIT INT TERM
		return 0
	fi
	if runtime_exists && ! runtime_owned; then
		die "nft table '$table' exists but is not owned by IKEv2 Manager"
		return 1
	fi

	rules="$work/rules.nft"
	{
		runtime_exists && printf 'delete table inet %s\n' "$table"
		printf 'table inet %s {\n' "$table"
		cat <<'EOF'
  chain ikev2_manager_owned {
    comment "IKEv2 Manager Discord voice classifier"
  }

  set source_ifaces {
    type ifname
EOF
		set_elements_line "$ifaces" ifname
		cat <<'EOF'
  }

  set source_ipv4 {
    type ipv4_addr
    flags interval
EOF
		set_elements_line "$addresses" ipv4
		cat <<'EOF'
  }

  set excluded_ipv4 {
    type ipv4_addr
    flags interval
EOF
		set_elements_line "$excluded" ipv4
		cat <<EOF
  }

  set voice_endpoints {
    type ipv4_addr . inet_service
    flags timeout
    timeout $endpoint_timeout
  }

  chain classify {
    ip daddr . udp dport @voice_endpoints update @voice_endpoints { ip daddr . udp dport timeout $endpoint_timeout } meta mark set meta mark & $clear_hex | $mark_hex counter accept
    udp length 82 @th,64,32 0x00010046 @th,128,128 0x00000000000000000000000000000000 @th,256,128 0x00000000000000000000000000000000 @th,384,128 0x00000000000000000000000000000000 @th,512,128 0x00000000000000000000000000000000 update @voice_endpoints { ip daddr . udp dport timeout $endpoint_timeout } meta mark set meta mark & $clear_hex | $mark_hex counter accept
  }

  chain prerouting {
    type filter hook prerouting priority -151; policy accept;
    ip saddr @excluded_ipv4 return
    iifname @source_ifaces goto classify
    ip saddr @source_ipv4 goto classify
  }
}
EOF
	} >"$rules"

	"$nft_bin" -c -f "$rules" >/dev/null 2>&1 || {
		die 'Discord voice nftables validation failed'
		return 1
	}
	"$nft_bin" -f "$rules" >/dev/null 2>&1 || {
		die 'Unable to install Discord voice nftables rules'
		return 1
	}
	mkdir -p "${signature_file%/*}"
	printf '%s\n' "$signature" >"${signature_file}.new"
	mv "${signature_file}.new" "$signature_file"
	rm -rf "$work"
	trap - EXIT INT TERM
}

check_runtime() {
	if [ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" != 1 ] ||
	   ! discord_selected; then
		! runtime_exists
		return
	fi
	runtime_owned || return 1
	"$nft_bin" list chain inet "$table" prerouting 2>/dev/null |
		grep -Fq 'chain prerouting'
}

status_runtime() {
	if discord_selected; then
		printf 'selected=yes\n'
	else
		printf 'selected=no\n'
	fi
	if check_runtime; then
		printf 'healthy=yes\n'
	else
		printf 'healthy=no\n'
	fi
}

case "${1:-sync}" in
	sync) sync_runtime ;;
	stop) stop_runtime ;;
	check) check_runtime ;;
	status) status_runtime ;;
	*) printf 'usage: %s [sync|stop|check|status]\n' "$0" >&2; exit 2 ;;
esac
