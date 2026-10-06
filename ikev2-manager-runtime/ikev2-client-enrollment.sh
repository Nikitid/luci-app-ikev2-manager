#!/bin/sh
# Bounded enrollment work is independent of HTTP and packet admission.
set -u
umask 077
ulimit -c 0
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset TMPDIR
for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$ikev2_override"; done
runtime_lib_dir=/usr/libexec/ikev2-manager.d
runtime_dir=/var/run/ikev2-client-enrollment
. "$runtime_lib_dir/package-manager.sh"
. "$runtime_lib_dir/actions.sh"
case "${1:-}" in
	status) cat "$runtime_dir/status" 2>/dev/null; exit $? ;;
	sync | watch) ;;
	*) exit 2 ;;
esac
mkdir -p "$runtime_dir" && chmod 700 "$runtime_dir" || exit 1
pid_lock_acquire "$runtime_dir/worker.lock" || exit 1
cleanup() { pid_lock_release "$runtime_dir/worker.lock"; }
trap 'cleanup; exit 1' HUP INT TERM
enrollment_sync() {
	local rc=0
	pkg_run_bounded 120 /usr/bin/ucode "$runtime_lib_dir/client-access-enrollment-worker.uc" >"$runtime_dir/status.new" 2>/dev/null || rc=1
	[ "$rc" = 0 ] || printf 'state=retry\n' >"$runtime_dir/status.new"
	mv "$runtime_dir/status.new" "$runtime_dir/status" || rc=1
	return "$rc"
}
if [ "$1" = sync ]; then
	rc=0; enrollment_sync || rc=$?; cleanup; exit "$rc"
fi
while :; do
	enrollment_sync || :
	sleep 5 &
	wait "$!" || :
done
