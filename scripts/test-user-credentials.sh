#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/etc/swanctl/conf.d" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/bin"
cp "$root"/ikev2-manager-runtime/lib/*.sh "$tmp/root/usr/libexec/ikev2-manager.d/"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/swanctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/swanctl.log"
exit 0
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/swanctl"

cat >"$tmp/user.in" <<'EOF'
add
user.name@example
test password #1
EOF

PATH="$tmp/bin:$PATH" \
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_USER_INPUT="$tmp/user.in" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" user-secret-set

secrets="$tmp/root/etc/swanctl/conf.d/91-inbound-secrets.conf"
grep -q '^[[:space:]]*eap-1 {' "$secrets"
grep -q '^[[:space:]]*id = "user.name@example"$' "$secrets"
if grep -q 'eap-user.name@example' "$secrets"; then
	printf 'user-controlled EAP section name was generated\n' >&2
	exit 1
fi
grep -q '^--load-creds --clear --noprompt$' "$tmp/swanctl.log"

# A changed password and a deleted user end that user's sessions: reloading
# the credentials alone left them connected.
cat >"$tmp/bin/sa" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = 'session-ids ikev2-in user.name@example' ] && printf '41\n43\n'
exit 0
EOF
chmod 755 "$tmp/bin/sa"
manager() {
	PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_SA_HELPER="$tmp/bin/sa" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" "$@"
}
printf 'password\nuser.name@example\nnew password\n' >"$tmp/user.in"
: >"$tmp/swanctl.log"
IKEV2_USER_INPUT="$tmp/user.in" manager user-secret-set
for id in 41 43; do
	grep -q "^--terminate --ike-id $id " "$tmp/swanctl.log" ||
		{ printf 'a password change left session %s running\n' "$id" >&2; exit 1; }
done
: >"$tmp/swanctl.log"
manager user-delete user.name@example
for id in 41 43; do
	grep -q "^--terminate --ike-id $id " "$tmp/swanctl.log" ||
		{ printf 'a deleted user kept session %s\n' "$id" >&2; exit 1; }
done
grep -n -- '--load-creds' "$tmp/swanctl.log" | head -n1 | grep -q '^1:' ||
	{ printf 'sessions were ended before the credentials were removed\n' >&2; exit 1; }

printf 'user credential tests OK\n'
