#!/bin/sh
# Narrow LuCI administration bridge; no device HTTP writer or request in argv.
set -u
umask 077
ulimit -c 0
if [ "$0" = /usr/libexec/ikev2-client-admin ]; then
 PATH=/usr/sbin:/usr/bin:/sbin:/bin
 export PATH
 unset TMPDIR
 for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$ikev2_override"; done
fi
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
admin_dir=/var/run/ikev2-client-admin
inbox="$admin_dir/inputs"
action_status_dir="$admin_dir/actions"
action_status_file="$admin_dir/action.status"
. "$runtime_lib_dir/package-manager.sh"
. "$runtime_lib_dir/actions.sh"
die() { [ -z "${staged_request:-}" ] || rm -f "$staged_request"; printf '%s\n' 'Client administration request refused.' >&2; exit 1; }
valid_token() {
 case "$1" in '' | *[!a-z0-9-]* | -*) return 1 ;; esac
 [ "${#1}" -le 64 ]
}
valid_job() {
 printf '%s\n' "$1" | grep -Eq '^[0-9]+-[0-9]+$' && [ "${#1}" -le 64 ]
}
run_action() {
 local id="$1" kind="$2" token="${3:-}" rc=0
 valid_job "$id" || die
 case "$kind" in update | invite) valid_token "$token" || die ;; refresh) ;; *) die ;; esac
 if ! pid_lock_acquire "$admin_dir/worker.lock"; then
  [ "$kind" = refresh ] || rm -f "$inbox/$token.in"
  action_status "$id" error 'Another client administration action is running.'
  return 1
 fi
 trap 'pid_lock_release "$admin_dir/worker.lock"; exit 1' HUP INT TERM
 if [ "$kind" = invite ]; then action_status "$id" running 'Creating invitation...'
 else action_status "$id" running 'Updating client configuration...'; fi
 if [ "$kind" = invite ]; then
  pkg_run_bounded 300 /bin/sh -c 'exec /usr/bin/ucode "$1/client-access-invitation-control.uc" issue-job "$3" <"$2"' sh "$runtime_lib_dir" "$inbox/$token.in" "$id" >/dev/null 2>/dev/null || rc=1
  rm -f "$inbox/$token.in"
 elif [ "$kind" = update ]; then
  pkg_run_bounded 300 /bin/sh -c 'exec /usr/bin/ucode "$1/client-access-control.uc" update <"$2"' sh "$runtime_lib_dir" "$inbox/$token.in" >"$admin_dir/result" 2>/dev/null || rc=1
  rm -f "$inbox/$token.in"
 else
  pkg_run_bounded 300 /usr/bin/ucode "$runtime_lib_dir/client-access-control.uc" refresh >"$admin_dir/result" 2>/dev/null || rc=1
 fi
 if [ "$rc" = 0 ] && [ "$kind" = invite ]; then action_status "$id" ok 'Invitation created.'
 elif [ "$rc" = 0 ]; then action_status "$id" ok 'Client configuration saved.'
 else action_status "$id" error 'Client configuration could not be saved. Refresh the page and try again.'; fi
 rm -f "$admin_dir/result"
 pid_lock_release "$admin_dir/worker.lock"
 return "$rc"
}
case "${1:-}" in
 client-admin-show)
  [ "$#" = 1 ] || die
  exec /usr/bin/ucode "$runtime_lib_dir/client-access-control.uc" inspect
  ;;
 client-admin-status)
  [ "$#" = 2 ] && valid_job "$2" || die
  cat "$action_status_dir/$2.status" 2>/dev/null || printf 'state=idle\n'
  ;;
 client-admin-take-invitation)
  [ "$#" = 2 ] && valid_job "$2" || die
  exec /usr/bin/ucode "$runtime_lib_dir/client-access-invitation-control.uc" take "$2"
  ;;
 client-admin-update | client-admin-invite | client-admin-refresh | _action-run) ;;
 *) die ;;
esac
mkdir -p "$inbox" "$action_status_dir" && chmod 700 "$admin_dir" "$inbox" "$action_status_dir" || die
case "$1" in
 client-admin-update | client-admin-invite)
  [ "$#" = 2 ] && valid_token "$2" || die
  /usr/bin/ucode "$runtime_lib_dir/client-access-input.uc" "$2" "$inbox" 2>/dev/null || die
  staged_request="$inbox/$2.in"
  if [ "$1" = client-admin-invite ]; then start_action invite "$2"; else start_action update "$2"; fi
  ;;
 client-admin-refresh)
  [ "$#" = 1 ] || die
  start_action refresh
  ;;
 _action-run)
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] || die
  shift; run_action "$@"
  ;;
esac
