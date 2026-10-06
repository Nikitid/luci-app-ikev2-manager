#!/bin/sh
# Real flock/UCI/strongSwan behavior, inside the credential fixture rootfs.
set -eu
umask 077
daemon="$1"
work="$(mktemp -d)"
manager=/usr/libexec/ikev2-manager
worker=''
cleanup() {
	kill -CONT "$daemon" 2>/dev/null || :
	[ -z "$worker" ] || { kill "$worker" 2>/dev/null || :; wait "$worker" 2>/dev/null || :; }
	rm -rf "$work"
}
trap cleanup EXIT INT TERM
guard=/var/run/ikev2-manager-users.guard
db=/etc/ikev2-manager/users.db
before="$(sha256sum "$db")"
exec 7>>"$guard"
flock -n 7
token="users-lock-$$"
input="/var/run/ikev2-manager-user-$token.in"
printf 'password\nunrelated\nblocked-password\n' >"$input"
if "$manager" user-secret-set "$token" >"$work/result" 2>&1; then
	printf '%s\n' 'users-lock: ordinary mutation bypassed guard' >&2
	exit 1
fi
[ -f "$input" ]
if "$manager" user-delete unrelated >"$work/result" 2>&1; then exit 1; fi
if "$manager" user-owned-input "$token" >"$work/result" 2>&1; then exit 1; fi
if "$manager" reload >"$work/result" 2>&1; then exit 1; fi
[ -f "$input" ]
[ "$(sha256sum "$db")" = "$before" ]
# Read-only polling stays available with a nonempty database.
"$manager" users-show >"$work/result" 2>&1
mv "$db" "$work/users.db"
if "$manager" users-show >"$work/result" 2>&1; then exit 1; fi
[ ! -e "$db" ]
mv "$work/users.db" "$db"
flock -u 7
rm -f "$input"

# Ownership is checked inside the manager, not just by the caller before exec.
for action in provision remove; do
	printf '%s\nunrelated\nffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n' "$action" >"$input"
	if "$manager" user-owned-input "$token" >"$work/result" 2>&1; then
		printf '%s\n' 'users-lock: manager accepted a conflicting owner' >&2
		exit 1
	fi
	[ "$(sha256sum "$db")" = "$before" ]
done

# Stop the real VICI daemon so a mutation reaches credential reload and waits.
# Its child must retain the kernel lock if the original manager is killed.
kill -STOP "$daemon"
printf 'password\nunrelated\ninherited-lock-fixture-password\n' >"$input"
"$manager" user-secret-set "$token" >"$work/worker.log" 2>&1 &
worker=$!
child=''
i=0
while [ -z "$child" ]; do
	for candidate in $(cat "/proc/$worker/task/$worker/children" 2>/dev/null || :); do
		[ "$(cat "/proc/$candidate/comm" 2>/dev/null || :)" != swanctl ] || child="$candidate"
	done
	i=$((i + 1)); [ "$i" -lt 15 ] || exit 1
	[ -n "$child" ] || sleep 1
done
[ "$(readlink "/proc/$child/fd/8")" = /tmp/run/ikev2-manager-users.guard ] ||
	[ "$(readlink "/proc/$child/fd/8")" = "$guard" ]
if "$manager" user-delete unrelated >"$work/result" 2>&1; then exit 1; fi
kill -KILL "$worker"
wait "$worker" 2>/dev/null || :
worker=''
if "$manager" user-delete unrelated >"$work/result" 2>&1; then
	printf '%s\n' 'users-lock: live child lost lock after parent death' >&2
	exit 1
fi
kill -CONT "$daemon"
i=0
until flock -n 7; do
	i=$((i + 1)); [ "$i" -lt 15 ] || exit 1
	sleep 1
done
flock -u 7
# A completed reload permits subsequent changes; another identity is retained.
printf 'password\nunrelated\nrecovered-lock-fixture-password\n' >"$input"
"$manager" user-secret-set "$token" >"$work/result" 2>&1
grep -q '^laptop[[:space:]]' "$db"
printf '%s\n' 'client-users-lock: shared mutation/init guard, atomic ownership and child lifetime PASS'
