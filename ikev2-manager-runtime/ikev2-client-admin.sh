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
# The state first, then the listener and its firewall rule, then the service:
# a failure at any step leaves the listener as it was or closed, never open
# over a state that was refused.
apply_setup() {
 local settings enabled port approve
 settings="$(pkg_run_bounded 60 /bin/sh -c 'exec /usr/bin/ucode "$1/client-access-setup.uc" apply <"$2"' sh "$runtime_lib_dir" "$1" 2>/dev/null)" || return 1
 enabled="$(printf '%s\n' "$settings" | sed -n 's/^enabled=\([01]\)$/\1/p')"
 port="$(printf '%s\n' "$settings" | sed -n 's/^port=\([0-9]\{4,5\}\)$/\1/p')"
 [ -n "$enabled" ] && [ -n "$port" ] || return 1
 uci -q get ikev2-manager.client_access >/dev/null || uci set ikev2-manager.client_access=client_access || return 1
 approve="$(printf '%s\n' "$settings" | sed -n 's/^approve=\([01]\)$/\1/p')"
 uci set "ikev2-manager.client_access.approve=${approve:-0}" &&
 uci set "ikev2-manager.client_access.enabled=$enabled" && uci set "ikev2-manager.client_access.port=$port" &&
  uci commit ikev2-manager || return 1
 pkg_run_bounded 120 /usr/libexec/ikev2-manager-system client-api-apply >/dev/null 2>&1 || return 1
 # The inbound server gains its connection for managed devices on first setup.
 # Best effort here: a server that cannot be brought up now is retried by the
 # health watcher, and the settings above are already in force.
 pkg_run_bounded 120 /usr/libexec/ikev2-manager server-ensure >/dev/null 2>&1 || :
 /etc/init.d/ikev2-client-access enable >/dev/null 2>&1 || return 1
 pkg_run_bounded 60 /etc/init.d/ikev2-client-access reload >/dev/null 2>&1
}

run_action() {
 local id="$1" kind="$2" token="${3:-}" rc=0
 valid_job "$id" || die
 case "$kind" in update | invite | setup | mail-save | mail-send) valid_token "$token" || die ;; refresh) ;; *) die ;; esac
 if ! pid_lock_acquire "$admin_dir/worker.lock"; then
  [ "$kind" = refresh ] || rm -f "$inbox/$token.in"
  action_status "$id" error 'Another client administration action is running.'
  return 1
 fi
 trap 'pid_lock_release "$admin_dir/worker.lock"; exit 1' HUP INT TERM
 if [ "$kind" = mail-save ]; then action_status "$id" running 'Saving mail settings...'
 elif [ "$kind" = mail-send ]; then action_status "$id" running 'Sending mail...'
 elif [ "$kind" = invite ]; then action_status "$id" running 'Creating invitation...'
 elif [ "$kind" = setup ]; then action_status "$id" running 'Applying remote client settings...'
 else action_status "$id" running 'Updating client configuration...'; fi
 if [ "$kind" = invite ]; then
  pkg_run_bounded 300 /bin/sh -c 'exec /usr/bin/ucode "$1/client-access-invitation-control.uc" issue-job "$3" <"$2"' sh "$runtime_lib_dir" "$inbox/$token.in" "$id" >/dev/null 2>/dev/null || rc=1
  rm -f "$inbox/$token.in"
 elif [ "$kind" = setup ]; then
  apply_setup "$inbox/$token.in" || rc=1
  rm -f "$inbox/$token.in"
 elif [ "$kind" = mail-save ]; then
  pkg_run_bounded 30 /bin/sh -c 'exec /usr/bin/ucode "$1/client-access-mail.uc" save <"$2"' sh "$runtime_lib_dir" "$inbox/$token.in" >/dev/null 2>&1 || rc=1
  rm -f "$inbox/$token.in"
 elif [ "$kind" = mail-send ]; then
  pkg_run_bounded 60 /bin/sh -c 'exec /usr/bin/ucode "$1/client-access-mail.uc" send "$3" <"$2"' sh "$runtime_lib_dir" "$inbox/$token.in" "$id" >/dev/null 2>&1 || rc=1
  rm -f "$inbox/$token.in"
 elif [ "$kind" = update ]; then
  pkg_run_bounded 300 /bin/sh -c 'exec /usr/bin/ucode "$1/client-access-control.uc" update <"$2"' sh "$runtime_lib_dir" "$inbox/$token.in" >"$admin_dir/result" 2>/dev/null || rc=1
  rm -f "$inbox/$token.in"
 else
  pkg_run_bounded 300 /usr/bin/ucode "$runtime_lib_dir/client-access-control.uc" refresh >"$admin_dir/result" 2>/dev/null || rc=1
 fi
 if [ "$rc" = 0 ] && [ "$kind" = mail-save ]; then action_status "$id" ok 'Mail settings saved.'
 elif [ "$kind" = mail-save ]; then action_status "$id" error 'Mail settings were refused. Check the server, the port and the sender address.'
 elif [ "$rc" = 0 ] && [ "$kind" = mail-send ]; then action_status "$id" ok 'Mail sent.'
 elif [ "$kind" = mail-send ]; then action_status "$id" error 'Mail was not sent. Check the mail settings, the password and that msmtp is installed.'
 elif [ "$rc" = 0 ] && [ "$kind" = invite ]; then action_status "$id" ok 'Invitation created.'
 elif [ "$rc" = 0 ] && [ "$kind" = setup ]; then action_status "$id" ok 'Remote client settings applied.'
 elif [ "$kind" = setup ]; then action_status "$id" error 'Remote client settings could not be applied. Check the inbound server, the exit tunnel and the subnet.'
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
 client-admin-settings)
  [ "$#" = 1 ] || die
  exec /usr/bin/ucode "$runtime_lib_dir/client-access-setup.uc" show
  ;;
 client-admin-mail)
  [ "$#" = 1 ] || die
  exec /usr/bin/ucode "$runtime_lib_dir/client-access-mail.uc" show
  ;;
 client-admin-update | client-admin-invite | client-admin-setup | client-admin-refresh | client-admin-mail-save | client-admin-mail-send | _action-run) ;;
 *) die ;;
esac
mkdir -p "$inbox" "$action_status_dir" && chmod 700 "$admin_dir" "$inbox" "$action_status_dir" || die
case "$1" in
 client-admin-update | client-admin-invite | client-admin-setup | client-admin-mail-save | client-admin-mail-send)
  [ "$#" = 2 ] && valid_token "$2" || die
  /usr/bin/ucode "$runtime_lib_dir/client-access-input.uc" "$2" "$inbox" 2>/dev/null || die
  staged_request="$inbox/$2.in"
  case "$1" in
   client-admin-invite) start_action invite "$2" ;;
   client-admin-setup) start_action setup "$2" ;;
   client-admin-mail-save) start_action mail-save "$2" ;;
   client-admin-mail-send) start_action mail-send "$2" ;;
   *) start_action update "$2" ;;
  esac
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
