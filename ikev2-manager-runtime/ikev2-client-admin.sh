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
# The state first, then the listener and its firewall rule, then the service.
# A failure at any step puts back what this setup changed and nothing else: the
# subnet is fixed for good once devices hold it, so a first activation that did
# not work must leave it free to choose again.
clients_dir=/etc/ikev2-manager/clients
setup_failure=''
setup_get() { uci -q get "ikev2-manager.client_access.$1" 2>/dev/null || :; }
setup_put_back() {
 if [ -n "$2" ]; then uci set "ikev2-manager.client_access.$1=$2"; else uci -q delete "ikev2-manager.client_access.$1" 2>/dev/null || :; fi
}
# What a first activation created. Entries that were there before stay.
setup_forget_new() {
 local name
 [ -d "$clients_dir" ] || return 0
 for name in $(ls -A "$clients_dir" 2>/dev/null); do
  case " $setup_before " in *" $name "*) ;; *) rm -rf "${clients_dir:?}/$name" || return 1 ;; esac
 done
 [ -n "$setup_before" ] || rmdir "$clients_dir" 2>/dev/null || :
}
setup_undo() {
 local undone=0 now
 if [ "$setup_was_ready" = 0 ]; then
  setup_forget_new || undone=1
 else
  now="$(/usr/bin/ucode "$runtime_lib_dir/client-access-setup.uc" show 2>/dev/null | jsonfilter -e '@.exit' 2>/dev/null)"
  if [ -n "$setup_old_exit" ] && [ "$now" != "$setup_old_exit" ]; then
   printf '{"version":1,"enabled":false,"port":8443,"virtual_subnet":"%s","exit":"%s"}\n' "$setup_old_subnet" "$setup_old_exit" |
    /usr/bin/ucode "$runtime_lib_dir/client-access-setup.uc" apply >/dev/null 2>&1 || undone=1
  fi
 fi
 if [ "$setup_had_section" = 1 ]; then
  setup_put_back enabled "$setup_old_enabled"
  setup_put_back port "$setup_old_port"
  setup_put_back approve "$setup_old_approve"
 else
  uci -q delete ikev2-manager.client_access 2>/dev/null || :
 fi
 uci commit ikev2-manager || undone=1
 # The rule follows the restored settings; the step that failed may fail again
 # after it has written them, which is why its own result is not the answer.
 pkg_run_bounded 120 /usr/libexec/ikev2-manager-system client-api-apply >/dev/null 2>&1 || :
 [ "$setup_was_enabled" = 1 ] || /etc/init.d/ikev2-client-access disable >/dev/null 2>&1 || :
 if [ "$undone" = 0 ]; then
  setup_failure='Remote client settings could not be applied: the firewall or the service refused them. Nothing was changed.'
 else
  setup_failure='Remote client settings could not be applied, and the previous ones could not be fully restored. Check them before trying again.'
 fi
 return 1
}
setup_refused() {
 case "$(cat "$1" 2>/dev/null)" in
  *'virtual subnet is in use'*) setup_failure='The virtual subnet is already used on this router. Choose another one. Nothing was changed.' ;;
  *'virtual subnet cannot change'*) setup_failure='The virtual subnet is fixed once set. Nothing was changed.' ;;
  *'exit tunnel is not enabled'*) setup_failure='The chosen exit tunnel is not enabled. Nothing was changed.' ;;
  *'inbound server'*) setup_failure='Enable the inbound server with a DNS name first: remote clients register and connect through it.' ;;
  *) setup_failure='Remote client settings were refused. Nothing was changed.' ;;
 esac
 [ "$setup_was_ready" = 1 ] || setup_forget_new || :
 return 1
}
apply_setup() {
 local settings enabled port approve shown refusal="$admin_dir/setup.refusal"
 setup_was_ready=0
 [ ! -e "$clients_dir/initialized" ] || setup_was_ready=1
 setup_before="$(ls -A "$clients_dir" 2>/dev/null | tr '\n' ' ')"
 setup_had_section=0
 uci -q get ikev2-manager.client_access >/dev/null 2>&1 && setup_had_section=1
 setup_old_enabled="$(setup_get enabled)"
 setup_old_port="$(setup_get port)"
 setup_old_approve="$(setup_get approve)"
 setup_was_enabled=0
 /etc/init.d/ikev2-client-access enabled 2>/dev/null && setup_was_enabled=1
 setup_old_exit=''
 setup_old_subnet=''
 if [ "$setup_was_ready" = 1 ]; then
  shown="$(/usr/bin/ucode "$runtime_lib_dir/client-access-setup.uc" show 2>/dev/null)"
  setup_old_exit="$(printf '%s' "$shown" | jsonfilter -e '@.exit' 2>/dev/null)"
  setup_old_subnet="$(printf '%s' "$shown" | jsonfilter -e '@.virtual_subnet' 2>/dev/null)"
 fi
 settings="$(pkg_run_bounded 60 /bin/sh -c 'exec /usr/bin/ucode "$1/client-access-setup.uc" apply <"$2" 2>"$3"' sh "$runtime_lib_dir" "$1" "$refusal")" || { setup_refused "$refusal"; rm -f "$refusal"; return 1; }
 rm -f "$refusal"
 enabled="$(printf '%s\n' "$settings" | sed -n 's/^enabled=\([01]\)$/\1/p')"
 port="$(printf '%s\n' "$settings" | sed -n 's/^port=\([0-9]\{4,5\}\)$/\1/p')"
 [ -n "$enabled" ] && [ -n "$port" ] || setup_undo || return 1
 uci -q get ikev2-manager.client_access >/dev/null || uci set ikev2-manager.client_access=client_access || setup_undo || return 1
 approve="$(printf '%s\n' "$settings" | sed -n 's/^approve=\([01]\)$/\1/p')"
 { uci set "ikev2-manager.client_access.approve=${approve:-0}" &&
  uci set "ikev2-manager.client_access.enabled=$enabled" && uci set "ikev2-manager.client_access.port=$port" &&
  uci commit ikev2-manager; } || setup_undo || return 1
 pkg_run_bounded 120 /usr/libexec/ikev2-manager-system client-api-apply >/dev/null 2>&1 || setup_undo || return 1
 # The inbound server gains its connection for managed devices on first setup.
 # Best effort here: a server that cannot be brought up now is retried by the
 # health watcher, and the settings above are already in force.
 pkg_run_bounded 120 /usr/libexec/ikev2-manager server-ensure >/dev/null 2>&1 || :
 /etc/init.d/ikev2-client-access enable >/dev/null 2>&1 || setup_undo || return 1
 pkg_run_bounded 60 /etc/init.d/ikev2-client-access reload >/dev/null 2>&1 || setup_undo
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
 if [ "$rc" != 0 ] && [ "$kind" = invite ]; then action_status "$id" error 'The link was not created. The identifier may have been used before, or a device is registering right now; try another identifier or wait a minute.'
 elif [ "$rc" = 0 ] && [ "$kind" = mail-save ] && [ ! -x /usr/bin/msmtp ]; then
  # The mail program comes with the first saved settings.
  /usr/libexec/ikev2-manager-system _deps-reconcile >/dev/null 2>&1 || :
  action_status "$id" ok 'Mail settings saved. The mail program is being installed; sending works in a minute or two.'
 elif [ "$rc" = 0 ] && [ "$kind" = mail-save ]; then action_status "$id" ok 'Mail settings saved.'
 elif [ "$kind" = mail-save ]; then action_status "$id" error 'Mail settings were refused. Check the server, the port and the sender address.'
 elif [ "$rc" = 0 ] && [ "$kind" = mail-send ]; then action_status "$id" ok 'Mail sent.'
 elif [ "$kind" = mail-send ]; then action_status "$id" error 'Mail was not sent. Check the mail settings, the password and that msmtp is installed.'
 elif [ "$rc" = 0 ] && [ "$kind" = invite ]; then action_status "$id" ok 'Invitation created.'
 elif [ "$rc" = 0 ] && [ "$kind" = setup ]; then action_status "$id" ok 'Remote client settings applied.'
 elif [ "$kind" = setup ]; then action_status "$id" error "$setup_failure"
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
 client-admin-link)
  [ "$#" = 2 ] && valid_token "$2" || die
  exec /usr/bin/ucode "$runtime_lib_dir/client-access-control.uc" link "$2"
  ;;
 client-admin-report-request)
  [ "$#" = 2 ] && valid_token "$2" || die
  exec /usr/bin/ucode "$runtime_lib_dir/client-access-control.uc" report-request "$2"
  ;;
 client-admin-report)
  [ "$#" = 2 ] && valid_token "$2" || die
  exec /usr/bin/ucode "$runtime_lib_dir/client-access-control.uc" report "$2"
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
