#!/bin/sh

# Outbound tunnels after the first, as the manager saves and renders them:
# each its own strongSwan connection on its own XFRM interface, its secret
# bound to its server as well as its user, a refused input changing nothing,
# and a deleted tunnel leaving nothing behind.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf 'tunnel manager: %s\n' "$*" >&2
	exit 1
}

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/etc/swanctl/conf.d" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/root/usr/share/ikev2-manager/ca" \
	"$tmp/bin"
cp "$root"/ikev2-manager-runtime/lib/*.sh "$tmp/root/usr/libexec/ikev2-manager.d/"
cp "$root/scripts/uci-stub.sh" "$tmp/bin/uci"
printf '#!/bin/sh\n[ "${1:-}" = strongswan-security ]\n' >"$tmp/bin/system-helper"
chmod 755 "$tmp/bin/uci" "$tmp/bin/system-helper"

cat >"$tmp/root/etc/config/ikev2-manager" <<'EOF'
globals=globals
globals.configured=1
client=client
client.enabled=1
client.remote_address=home.example.test
client.remote_id=home.example.test
client.username=office-user
EOF
printf 'office-user\t0sc2VjcmV0\n' >"$tmp/root/etc/ikev2-manager/client.secret"

conf="$tmp/root/etc/swanctl/conf.d/21-proxy-out-extra.conf"
secrets="$tmp/root/etc/swanctl/conf.d/92-proxy-out-extra-secret.conf"
first_secret="$tmp/root/etc/swanctl/conf.d/90-proxy-out-secret.conf"
db="$tmp/root/etc/ikev2-manager/tunnels.secret"

manager() {
	UCI_STUB_DIR="$tmp/root/etc/config" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_SYSTEM_HELPER="$tmp/bin/system-helper" \
	IKEV2_TUNNEL_INPUT="$tmp/tunnel.in" \
	IKEV2_CONFIG_LOCK="$tmp/config.lock" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	IKEV2_ACTION_STATUS="$tmp/latest.status" \
	IKEV2_ACTION_STATUS_DIR="$tmp/actions" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.lock.status" \
	PATH="$tmp/bin:$PATH" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" "$@"
}

# input ACTION INDEX NAME ENABLED REMOTE ID USER DPD MTU BACKUP PASSWORD
input() {
	printf '%s\n' "$@" >"$tmp/tunnel.in"
}

snapshot() {
	cat "$tmp/root/etc/config/ikev2-manager" "$conf" "$secrets" "$db" 2>/dev/null >"$tmp/$1"
}

# A new tunnel takes the first free index and its own names.
input save new 'Backup NL' 1 nl.example.test nl.example.test office-user 30 1400 1 's3cret pass'
manager tunnel-input >"$tmp/out" 2>"$tmp/err" || fail "a new tunnel was refused: $(cat "$tmp/err")"
grep -qx 'tunnel=2' "$tmp/out" || fail 'a new tunnel did not take index 2'
grep -qx "tunnel_2.name=Backup NL" "$tmp/root/etc/config/ikev2-manager" || fail 'the tunnel name was not stored'
grep -q 'proxy-out-2 {' "$conf" && grep -q 'proxy4-2 {' "$conf" ||
	fail 'the tunnel did not get its own connection and child'
[ "$(grep -c 'if_id_in = 52\|if_id_out = 52' "$conf")" = 2 ] || fail 'the tunnel is not on its own XFRM interface'
grep -q 'remote_addrs = nl.example.test' "$conf" || fail 'the tunnel server was not rendered'
! grep -q 's3cret' "$db" "$secrets" || fail 'a tunnel password was stored in plaintext'
grep -q 'id-user = "office-user"' "$secrets" && grep -q 'id-server = "nl.example.test"' "$secrets" ||
	fail 'the tunnel secret is not bound to its server'
grep -q 'id-server = "home.example.test"' "$first_secret" ||
	fail 'the first tunnel secret, with the same user, is not bound to its server'
[ -e "$tmp/actions" ] && grep -rq 'Queued' "$tmp/actions" || fail 'saving did not queue the apply'

manager tunnels-get >"$tmp/get"
grep -qx 'tunnel=2' "$tmp/get" && grep -qx 'password_set=1' "$tmp/get" && grep -qx 'backup=1' "$tmp/get" ||
	fail "tunnels-get does not describe the tunnel: $(cat "$tmp/get")"
! grep -q 's3cret' "$tmp/get" || fail 'tunnels-get printed the password'

# Saved again without a password: the stored one is kept, under the new user.
before="$(cut -f3 "$db")"
input save 2 'Backup NL' 1 nl.example.test nl.example.test backup-user 60 1380 0 ''
manager tunnel-input >/dev/null 2>"$tmp/err" || fail "an edit was refused: $(cat "$tmp/err")"
[ "$(cut -f2,3 "$db")" = "$(printf 'backup-user\t%s' "$before")" ] ||
	fail 'an edit without a password lost or kept the wrong secret'
grep -qx 'tunnel_2.backup=0' "$tmp/root/etc/config/ikev2-manager" || fail 'the backup flag was not stored'
grep -q 'dpd_delay = 60s' "$conf" || fail 'the edited DPD was not rendered'

# Refused input changes nothing.
snapshot before
for bad in \
	"save|new|bad/name|1|x.example.test|x.example.test|u|30|1400|1|p" \
	"save|new|Ok|1|x.example.test|x.example.test|u|30|9000|1|p" \
	"save|new|Ok|1|x.example.test|x.example.test|u|30|1400|1|" \
	"save|new|Ok|2|x.example.test|x.example.test|u|30|1400|1|p" \
	"save|5|Ok|1|x.example.test|x.example.test|u|30|1400|1|p" \
	"save|1|Ok|1|x.example.test|x.example.test|u|30|1400|1|p" \
	"delete|new|||||||||" \
	"rename|2|Ok|1|x.example.test|x.example.test|u|30|1400|1|p" \
	"save|new|Ok|1|x.example.test|x.example.test|u|30|1400|1|p|extra=1"; do
	printf '%s\n' "$bad" | tr '|' '\n' >"$tmp/tunnel.in"
	if manager tunnel-input >/dev/null 2>&1; then
		fail "an invalid input was accepted: $bad"
	fi
	snapshot after
	cmp -s "$tmp/before" "$tmp/after" || fail "a refused input changed the configuration: $bad"
done

# A disabled tunnel is configured but not rendered.
input save new 'Spare' 0 de.example.test de.example.test office-user 30 1400 1 'other'
manager tunnel-input >"$tmp/out" 2>"$tmp/err" || fail "a disabled tunnel was refused: $(cat "$tmp/err")"
grep -qx 'tunnel=3' "$tmp/out" || fail 'the second new tunnel did not take index 3'
! grep -q 'proxy-out-3' "$conf" "$secrets" || fail 'a disabled tunnel was rendered'

# Eight at most.
for name in A B C D E; do
	input save new "$name" 0 x.example.test x.example.test u 30 1400 1 p
	manager tunnel-input >/dev/null 2>&1 || fail "tunnel $name was refused below the limit"
done
input save new 'Ninth' 0 x.example.test x.example.test u 30 1400 1 p
manager tunnel-input >/dev/null 2>&1 && fail 'a ninth tunnel was accepted'

# Deleted: its section, secret and connection go; the first tunnel's secret
# names only its user again once no other tunnel is enabled.
input delete 2 '' '' '' '' '' '' '' '' ''
manager tunnel-input >/dev/null 2>"$tmp/err" || fail "a delete was refused: $(cat "$tmp/err")"
! grep -q '^tunnel_2' "$tmp/root/etc/config/ikev2-manager" || fail 'a deleted tunnel kept its section'
! grep -q '^2	' "$db" || fail 'a deleted tunnel kept its secret'
! grep -q 'proxy-out-2' "$conf" "$secrets" || fail 'a deleted tunnel kept its connection'
! grep -q 'id-server' "$first_secret" || fail 'the first tunnel secret still names its server with no other tunnel'

printf '%s\n' 'tunnel manager tests OK'
