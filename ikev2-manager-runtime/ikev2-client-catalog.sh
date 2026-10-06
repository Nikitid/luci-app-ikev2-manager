#!/bin/sh
# Refresh client-published catalog lists independently from packet admission.
set -u
umask 077
ulimit -c 0
if [ "$0" = /usr/libexec/ikev2-client-catalog ]; then
 PATH=/usr/sbin:/usr/bin:/sbin:/bin
 export PATH
 unset TMPDIR
 for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$ikev2_override"; done
fi
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
runtime_dir="${IKEV2_CLIENT_CATALOG_RUNTIME:-/var/run/ikev2-client-catalog}"
interval="${IKEV2_CLIENT_CATALOG_INTERVAL:-3600}"
retry="${IKEV2_CLIENT_CATALOG_RETRY:-60}"
case "$interval:$retry" in *[!0-9:]* | 0:* | *:0 | :* | *:) exit 2 ;; esac
. "$runtime_lib_dir/package-manager.sh"
. "$runtime_lib_dir/actions.sh"

catalog_sync() {
 local rc=0
 pkg_run_bounded 300 /usr/bin/ucode "$runtime_lib_dir/client-access-control.uc" refresh >"$runtime_dir/result.new" 2>/dev/null || rc=1
 if [ "$rc" = 0 ]; then
  { printf 'state=current\nupdated=%s\n' "$(date +%s)"; cat "$runtime_dir/result.new"; } >"$runtime_dir/status.new"
 else
  printf 'state=failed\nupdated=%s\n' "$(date +%s)" >"$runtime_dir/status.new"
 fi
 mv "$runtime_dir/status.new" "$runtime_dir/status" || rc=1
 rm -f "$runtime_dir/result.new"
 return "$rc"
}
case "${1:-}" in
 status) cat "$runtime_dir/status" 2>/dev/null; exit $? ;;
 sync | watch) ;;
 *) printf '%s\n' 'usage: ikev2-client-catalog sync|watch|status' >&2; exit 2 ;;
esac
mkdir -p "$runtime_dir" && chmod 700 "$runtime_dir" || exit 1
pid_lock_acquire "$runtime_dir/worker.lock" || exit 1
cleanup() { pid_lock_release "$runtime_dir/worker.lock"; }
trap 'cleanup; exit 1' HUP INT TERM
if [ "$1" = sync ]; then
 rc=0; catalog_sync || rc=$?; cleanup; exit "$rc"
fi
while :; do
 delay="$interval"
 catalog_sync || delay="$retry"
 sleep "$delay" &
 wait "$!" || :
done
