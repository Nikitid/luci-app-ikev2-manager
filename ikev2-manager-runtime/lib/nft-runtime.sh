#!/bin/sh
# Helpers for the runtimes that own an nftables table of their own: device
# routing, inbound user policy and Discord voice. The caller sets $nft_bin and
# $table before using the table helpers.

runtime_exists() {
	"$nft_bin" list table inet "$table" >/dev/null 2>&1
}

# A table is ours only if it carries the ownership marker chain.
runtime_owned() {
	"$nft_bin" list table inet "$table" 2>/dev/null |
		grep -Fq 'chain ikev2_manager_owned'
}

# A hash of the table's program as the kernel holds it, stable across traffic;
# see nft-state.uc. Taken right after an install, it is what a later check
# compares against. The caller also sets $ucode_bin and $runtime_lib_dir, and
# may name sets whose elements others fill in $runtime_volatile_sets.
runtime_fingerprint() {
	local listing rc=0
	listing="$(mktemp "${TMPDIR:-/tmp}/ikev2-nft-state.XXXXXX")" || return 1
	"$nft_bin" -j list table inet "$table" >"$listing" 2>/dev/null &&
		"$ucode_bin" "$runtime_lib_dir/nft-state.uc" fingerprint ${runtime_volatile_sets:-} \
			<"$listing" >"${listing}.fp" || rc=1
	[ "$rc" = 0 ] && sha256sum <"${listing}.fp" | awk '{ print $1 }'
	rm -f "$listing" "${listing}.fp"
	return "$rc"
}

# Whether the table still holds what was installed: the fingerprint stored
# on the second line of STATE_FILE.
runtime_unchanged() {
	local stored live
	stored="$(sed -n '2p' "$1" 2>/dev/null)"
	[ -n "$stored" ] || return 1
	live="$(runtime_fingerprint)" || return 1
	[ "$live" = "$stored" ]
}

# Record SIGNATURE (what was asked for) and the fingerprint of what the
# kernel now holds in STATE_FILE.
record_runtime() {
	local file="$1" signature="$2" fingerprint
	fingerprint="$(runtime_fingerprint)" || return 1
	mkdir -p "${file%/*}"
	printf '%s\n%s\n' "$signature" "$fingerprint" >"${file}.new" || return 1
	mv "${file}.new" "$file"
}

# Print the fwmark/mask of the ip rule that selects PBR routing table TABLE.
pbr_mark_rule() {
	ip -4 rule show 2>/dev/null |
		awk -v table="$1" '
			$0 ~ ("lookup " table "([[:space:]]|$)") {
				for (i = 1; i <= NF; i++)
					if ($i == "fwmark") { print $(i + 1); exit }
			}
		'
}

# The fwmark/mask of policy routing (ikev2-routing) that sends a packet into
# the tunnel ("tunnel") or out of the WAN ("wan").
routing_mark_rule() {
	case "$1" in
		tunnel) printf '0x01000000/0x0f000000\n' ;;
		wan) printf '0x02000000/0x0f000000\n' ;;
		*) return 1 ;;
	esac
}

# Turn MARK/MASK into the "clear set" pair nftables needs to rewrite only the
# masked bits: the inverted mask, then the mark.
mark_values() {
	local rule="$1" mark mask mark_value mask_value clear_value
	case "$rule" in
		0x[0-9A-Fa-f]*/0x[0-9A-Fa-f]*) ;;
		*) return 1 ;;
	esac
	mark="${rule%%/*}"
	mask="${rule#*/}"
	mark_value=$((mark))
	mask_value=$((mask))
	clear_value=$((0xffffffff ^ mask_value))
	printf '%s %s\n' "$(printf '0x%08x' "$clear_value")" \
		"$(printf '0x%08x' "$mark_value")"
}

# Join the non-empty lines of FILE into an nftables element list.
set_elements() {
	local file="$1"
	[ -s "$file" ] || return 0
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "%s", $0; first=0 }' "$file"
}
