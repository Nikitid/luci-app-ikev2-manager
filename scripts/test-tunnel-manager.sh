#!/bin/sh

# Outbound tunnels after the first, as the manager saves and renders them:
# each its own strongSwan connection on its own XFRM interface, its secret
# bound to its server as well as its user, a refused input changing nothing,
# and a deleted tunnel leaving nothing behind.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
# Queued actions run in the background and write into $tmp; let them finish
# before it goes, or the removal races them.
settle_actions() {
	local i=0
	while [ "$i" -lt 200 ] && grep -lqx 'state=running' "$tmp"/actions/*.status 2>/dev/null; do
		sleep 0.1
		i=$((i + 1))
	done
}
trap 'settle_actions; rm -rf "$tmp" 2>/dev/null || { sleep 1; rm -rf "$tmp"; }' EXIT INT TERM

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
# Queued actions start the helper again through setsid, which macOS lacks;
# the helper is not executable in the tree, only where it is installed.
printf '#!/bin/sh\ncase "$1" in *.sh) exec sh "$@" ;; esac\nexec "$@"\n' >"$tmp/bin/setsid"
chmod 755 "$tmp/bin/uci" "$tmp/bin/system-helper" "$tmp/bin/setsid"

cat >"$tmp/root/etc/config/ikev2-manager" <<'EOF'
globals=globals
globals.configured=1
client=client
client.enabled=1
client.remote_address=home.example.test
client.remote_id=home.example.test
client.username=tunnel-user
EOF
printf 'tunnel-user\t0sc2VjcmV0\n' >"$tmp/root/etc/ikev2-manager/client.secret"

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
	IKEV2_CLIENT_INPUT="$tmp/client.in" \
	IKEV2_CONFIG_LOCK="$tmp/config.lock" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	IKEV2_ACTION_STATUS="$tmp/latest.status" \
	IKEV2_ACTION_STATUS_DIR="$tmp/actions" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.lock.status" \
	IKEV2_SA_HELPER="$tmp/bin/sa" \
	IKEV2_ROUTING_HELPER="$tmp/bin/routing" \
	IKEV2_EXITS_FILE="$tmp/exits" \
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

# What the action queued in $tmp/out said when it finished. Connect and
# Disconnect save nothing, so neither may report that settings were saved.
outcome() {
	local id i=0
	id="$(sed -n 's/^action_id=//p' "$tmp/out")"
	while [ "$i" -lt 150 ]; do
		grep -Eq '^state=(ok|error)$' "$tmp/actions/$id.status" 2>/dev/null && break
		sleep 0.1
		i=$((i + 1))
	done
	grep -Eq '^state=(ok|error)$' "$tmp/actions/$id.status" 2>/dev/null ||
		fail "the action $id did not finish: $(cat "$tmp/actions/$id.status" 2>/dev/null)"
	sed -n 's/^message=//p' "$tmp/actions/$id.status"
}
no_save_claim() {
	local message
	message="$(outcome)"
	[ -n "$message" ] || fail "$1 left no outcome"
	case "$message" in
		*[Ss]aved*) fail "$1 reported a save it did not make: $message" ;;
	esac
}

# A new tunnel takes the first free index and its own names.
input save new 'Backup NL' 1 nl.example.test nl.example.test tunnel-user 30 1400 1 's3cret pass'
manager tunnel-input >"$tmp/out" 2>"$tmp/err" || fail "a new tunnel was refused: $(cat "$tmp/err")"
grep -qx 'tunnel=2' "$tmp/out" || fail 'a new tunnel did not take index 2'
grep -qx "tunnel_2.name=Backup NL" "$tmp/root/etc/config/ikev2-manager" || fail 'the tunnel name was not stored'
grep -q 'proxy-out-2 {' "$conf" && grep -q 'proxy4-2 {' "$conf" ||
	fail 'the tunnel did not get its own connection and child'
[ "$(grep -c 'if_id_in = 52\|if_id_out = 52' "$conf")" = 2 ] || fail 'the tunnel is not on its own XFRM interface'
grep -q 'remote_addrs = nl.example.test' "$conf" || fail 'the tunnel server was not rendered'
! grep -q 's3cret' "$db" "$secrets" || fail 'a tunnel password was stored in plaintext'
grep -q 'id-user = "tunnel-user"' "$secrets" && grep -q 'id-server = "nl.example.test"' "$secrets" ||
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

# A settings-only save preserves the connection switch and queues no apply.
input save-only 2 'Backup NL' 0 nl.example.test nl.example.test backup-user 60 1380 0 '' 30
manager tunnel-input >"$tmp/out" || fail 'settings-only save failed'
grep -qx 'tunnel=2' "$tmp/out" && ! grep -q '^action_id=' "$tmp/out" ||
	fail 'saving settings queued a connection action'
grep -qx 'tunnel_2.enabled=1' "$tmp/root/etc/config/ikev2-manager" ||
	fail 'saving settings changed the enabled flag'
grep -qx 'tunnel_2.reconnect_cooldown=30' "$tmp/root/etc/config/ikev2-manager" ||
	fail 'the reconnect cooldown was not saved'
input disconnect 2
manager tunnel-input >"$tmp/out" || fail 'disconnect was refused'
grep -q '^action_id=' "$tmp/out" && ! grep -q 'proxy-out-2 {' "$conf" ||
	fail 'disconnect did not queue an apply or left the connection in the profile'
no_save_claim 'Disconnect of an extra tunnel'
input connect 2
manager tunnel-input >"$tmp/out" || fail 'connect was refused'
grep -q '^action_id=' "$tmp/out" && grep -q 'proxy-out-2 {' "$conf" ||
	fail 'connect did not restore the saved profile and queue an apply'
no_save_claim 'Connect of an extra tunnel'

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
input save new 'Spare' 0 de.example.test de.example.test tunnel-user 30 1400 1 'other'
manager tunnel-input >"$tmp/out" 2>"$tmp/err" || fail "a disabled tunnel was refused: $(cat "$tmp/err")"
grep -qx 'tunnel=3' "$tmp/out" || fail 'the second new tunnel did not take index 3'
! grep -q 'proxy-out-3' "$conf" "$secrets" || fail 'a disabled tunnel was rendered'

# The status names each tunnel's state and the exits it carries now.
printf '#!/bin/sh\n[ "$1" = tunnels ] && printf "1\\t1\\t10.20.20.10\\n2\\t0\\t-\\n"\n' >"$tmp/bin/sa"
printf '#!/bin/sh\n[ "$1" = status ] && printf "tunnel=up\\nexit_1=ipsec-out\\nexit_2=ipsec-out\\nexit_3=none\\n"\n' >"$tmp/bin/routing"
chmod 755 "$tmp/bin/sa" "$tmp/bin/routing"
manager tunnels-status >"$tmp/status"
sed 's/ interface_present=.*//' "$tmp/status" >"$tmp/status-base"
grep -q 'interface_present=0 interface_bytes_in=0 interface_bytes_out=0$' "$tmp/status" ||
	fail 'tunnel status does not include the interface counters'
printf '%s\n' 'tunnel=1 up=1 address=10.20.20.10 carries=1,2' 'tunnel=2 up=0 address= carries=' \
	'tunnel=3 up=0 address= carries=' | cmp -s - "$tmp/status-base" ||
	fail "the tunnel status is wrong: $(cat "$tmp/status")"

# The first tunnel has the switch every other tunnel has in its block.
manager client-get | grep -qx 'backup=1' || fail 'the first tunnel does not stand in for the others by default'
manager client-backup 0 >/dev/null || fail 'the first tunnel could not be kept from standing in'
grep -qx 'client.backup=0' "$tmp/root/etc/config/ikev2-manager" || fail 'the setting of the first tunnel was not stored'
manager client-get | grep -qx 'backup=0' || fail 'the page is not told the setting of the first tunnel'
manager client-backup 2 >/dev/null 2>&1 && fail 'a setting that is neither on nor off was accepted'
manager client-backup 1 >/dev/null || fail 'the first tunnel could not stand in again'

# The first slot uses the same separate controls while keeping its UCI layout.
printf '%s\n' save-settings 0 home.example.test home.example.test tunnel-user 30 1400 '' 15 \
	google 'https://dns.google/dns-query' '8.8.8.8:53' Home 0 >"$tmp/client.in"
manager client-input >"$tmp/out" || fail 'settings-only save failed for the first slot'
[ ! -s "$tmp/out" ] && manager client-get | grep -qx 'name=Home' ||
	fail 'first-slot settings were not saved separately'
manager client-get | grep -qx 'enabled=1' || fail 'saving settings disabled the first slot'
input disconnect 1
manager tunnel-input >"$tmp/out" || fail 'the first slot did not accept Disconnect'
grep -q '^action_id=' "$tmp/out" && manager client-get | grep -qx 'enabled=0' ||
	fail 'Disconnect did not disable the first slot'
no_save_claim 'Disconnect of the first tunnel'
input connect 1
manager tunnel-input >"$tmp/out" || fail 'the first slot did not accept Connect'
grep -q '^action_id=' "$tmp/out" && manager client-get | grep -qx 'enabled=1' ||
	fail 'Connect did not enable the first slot'
no_save_claim 'Connect of the first tunnel'

# Seven at most: each has two exits, and there are fifteen marks.
for name in A B C D; do
	input save new "$name" 0 x.example.test x.example.test u 30 1400 1 p
	manager tunnel-input >/dev/null 2>&1 || fail "tunnel $name was refused below the limit"
done
input save new 'Eighth' 0 x.example.test x.example.test u 30 1400 1 p
manager tunnel-input >/dev/null 2>&1 && fail 'an eighth tunnel was accepted'
grep -q '^tunnel_7=' "$tmp/root/etc/config/ikev2-manager" || fail 'the seventh tunnel was not stored'
grep -q '^tunnel_8' "$tmp/root/etc/config/ikev2-manager" && fail 'an eighth tunnel was stored'

# A tunnel something is bound to without backup is not deleted from under it:
# what must not leave from another place would move to the first tunnel.
printf 'openai 2s\n' >"$tmp/exits"
input delete 2 '' '' '' '' '' '' '' '' ''
manager tunnel-input >/dev/null 2>"$tmp/err" && fail 'a tunnel with a service bound to it was deleted'
grep -q 'bound to this tunnel' "$tmp/err" || fail "the refusal does not say why: $(cat "$tmp/err")"
printf 'openai 2\n' >"$tmp/exits"

# Deleted: its section, secret and connection go; the first tunnel's secret
# names only its user again once no other tunnel is enabled.
input delete 2 '' '' '' '' '' '' '' '' ''
manager tunnel-input >/dev/null 2>"$tmp/err" || fail "a delete was refused: $(cat "$tmp/err")"
! grep -q '^tunnel_2' "$tmp/root/etc/config/ikev2-manager" || fail 'a deleted tunnel kept its section'
! grep -q '^2	' "$db" || fail 'a deleted tunnel kept its secret'
! grep -q 'proxy-out-2' "$conf" "$secrets" || fail 'a deleted tunnel kept its connection'
! grep -q 'id-server' "$first_secret" || fail 'the first tunnel secret still names its server with no other tunnel'

printf '%s\n' 'tunnel manager tests OK'
