#!/bin/sh

# Which tunnel each exit uses: the first one up in its chain, a lost one
# replaced at once, a preferred one taken back only after it has stayed up,
# and never the WAN.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf 'tunnel select: %s\n' "$*" >&2
	exit 1
}

IKEV2_TUNNEL_STATE="$tmp/state"
tunnel_return_hold=120
. "$root/ikev2-manager-runtime/lib/tunnel.sh"

settings() {
	tunnel_settings_parse
	rm -f "$tmp/state"
}

# select NOW UP: the changes, one "exit:tunnel" word each.
select_at() {
	tunnel_select "$1" "$2" >"$tmp/printed"
	[ ! -s "$tmp/printed" ] || fail 'the selection printed something'
	printf '%s\n' "$tunnel_changes"
}

expect() {
	[ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"
}

# Names follow the index; tunnel 1 keeps the names it always had.
tunnel_names 1
expect 'tunnel 1 names' "$tunnel_conn $tunnel_child $tunnel_link $tunnel_if_id $tunnel_fwmark $tunnel_table_id $tunnel_rule" \
	'proxy-out proxy4 ipsec-out 42 0x01000000 1601 28001'
tunnel_names 3
expect 'tunnel 3 names' "$tunnel_section $tunnel_conn $tunnel_child $tunnel_link $tunnel_if_id $tunnel_fwmark $tunnel_table_id $tunnel_rule" \
	'tunnel_3 proxy-out-3 proxy4-3 ipsec-out3 53 0x04000000 1604 28004'
expect 'connection index' "$(tunnel_index_of_conn proxy-out-3) $(tunnel_index_of_conn proxy-out)" '3 1'
tunnel_index_of_conn proxy-out-x >/dev/null && fail 'a foreign connection was taken for a tunnel'

# One tunnel: exactly what there was before.
settings <<'EOF'
ikev2-manager.client=client
ikev2-manager.client.enabled='1'
EOF
expect 'one tunnel list' "$tunnel_list|$tunnel_on|$tunnel_spare" '1|1|1'
tunnel_several && fail 'one tunnel counted as several'
expect 'one tunnel down' "$(select_at 1000 '')" ''
expect 'one tunnel up' "$(select_at 1010 '1')" '1:1'
expect 'one tunnel steady' "$(select_at 1020 '1')" ''
expect 'one tunnel lost' "$(select_at 1030 '')" '1:0'

# Two tunnels backing each other up.
settings <<'EOF'
ikev2-manager.client=client
ikev2-manager.client.enabled='1'
ikev2-manager.tunnel_2=tunnel
ikev2-manager.tunnel_2.enabled='1'
EOF
expect 'two tunnels list' "$tunnel_list|$tunnel_on|$tunnel_spare" '1 2|1 2|1 2'
tunnel_several || fail 'two tunnels not counted as several'
tunnel_exit_chain 2
expect 'chain of exit 2' "$tunnel_chain" '2 1'
expect 'both come up' "$(select_at 1000 '1 2')" '1:1 2:2'
expect 'tunnel 1 fails over at once' "$(select_at 1010 '2')" '1:2'
expect 'tunnel 1 back, held' "$(select_at 1020 '1 2')" ''
expect 'still held' "$(select_at 1139 '1 2')" ''
expect 'taken back after the hold' "$(select_at 1140 '1 2')" '1:1'
expect 'a flap restarts the hold' "$(select_at 1150 '2')" '1:2'
expect 'up again, held again' "$(select_at 1160 '1 2')" ''
expect 'both down: unreachable, not WAN' "$(select_at 1170 '')" '1:0 2:0'
expect 'the first one up is taken at once' "$(select_at 1180 '2')" '1:2 2:2'
grep -q '^exit 1 2$' "$tmp/state" || fail 'the state file does not record the choice'
expect 'selected read back' "$(tunnel_exit_selected 1)" '2'

# A tunnel that does not back the others up is used by its own exit only, and
# a disabled one by none.
settings <<'EOF'
ikev2-manager.client=client
ikev2-manager.client.enabled='1'
ikev2-manager.tunnel_2=tunnel
ikev2-manager.tunnel_2.enabled='1'
ikev2-manager.tunnel_2.backup='0'
ikev2-manager.tunnel_3=tunnel
ikev2-manager.tunnel_3.enabled='0'
EOF
expect 'spare list' "$tunnel_list|$tunnel_on|$tunnel_spare" '1 2 3|1 2|1'
expect 'own exit only' "$(select_at 1000 '2')" '2:2'
tunnel_exit_chain 3
expect 'exit of a disabled tunnel' "$tunnel_chain" '1'
expect 'disabled tunnel exit uses the backups' "$(select_at 1010 '1 2')" '1:1 3:1'

printf '%s\n' 'tunnel select tests OK'
