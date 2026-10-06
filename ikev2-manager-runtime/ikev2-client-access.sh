#!/bin/sh
# Maintain SA-bound remote-service admission without changing management routes.
set -u
umask 077
ulimit -c 0

if [ "$0" = /usr/libexec/ikev2-client-access ]; then
	PATH=/usr/sbin:/usr/bin:/sbin:/bin
	export PATH
	unset TMPDIR
	for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$ikev2_override"
	done
fi
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
state_dir="${IKEV2_CLIENT_STATE_DIR:-/etc/ikev2-manager/clients}"
runtime_dir="${IKEV2_CLIENT_RUNTIME_DIR:-/var/run/ikev2-client-access}"
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
swanmon_bin="${IKEV2_SWANMON:-/usr/sbin/swanmon}"
ucode_bin="${IKEV2_UCODE:-/usr/bin/ucode}"
uci_bin="${IKEV2_UCI_BIN:-/sbin/uci}"
require_path="${IKEV2_CLIENT_REQUIRE_PATH:-1}"
auto_path="${IKEV2_CLIENT_AUTO_PATH:-1}"
table=ikev2_client_access
. "$runtime_lib_dir/package-manager.sh"
. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/nft-runtime.sh"
. "$runtime_lib_dir/tunnel.sh"
. "$runtime_lib_dir/client-path-runtime.sh"

status_write() {
	printf 'state=%s\ngeneration=%s\ngrants=%s\nupdated=%s\n' "$1" "${2:-0}" "${3:-0}" "$(date +%s)" >"$runtime_dir/status.new" &&
		mv "$runtime_dir/status.new" "$runtime_dir/status"
}

close_grants() {
	rm -f "$runtime_dir/device-ready.json"
	runtime_exists || return 0
	runtime_owned || return 1
	printf 'flush set inet %s allow_tcp\nflush set inet %s allow_udp\n' "$table" "$table" >"$work/close.nft" || return 1
	pkg_run_bounded 3 "$nft_bin" -f "$work/close.nft" >/dev/null 2>&1
}

install_plan() {
	"$ucode_bin" -e 'import {readfile} from "fs"; let p=json(readfile(ARGV[0])); if(type(p.nft)!="string") die("Invalid plan"); print(p.nft);' "$work/plan.json" >"$work/guard.nft" || return 1
	: >"$work/transaction.nft"
	if runtime_exists; then
		runtime_owned || return 1
		printf 'delete table inet %s\n' "$table" >>"$work/transaction.nft"
	fi
	cat "$work/guard.nft" >>"$work/transaction.nft" || return 1
	pkg_run_bounded 3 "$nft_bin" -c -f "$work/transaction.nft" >/dev/null 2>&1 &&
		pkg_run_bounded 3 "$nft_bin" -f "$work/transaction.nft" >/dev/null 2>&1 && runtime_owned
}

close_access() {
	close_grants || return 1
	"$ucode_bin" "$runtime_lib_dir/client-access-runtime.uc" close "$state_dir" '' '' >"$work/plan.json" 2>/dev/null &&
		install_plan
}

failed() {
	close_grants || :
	status_write failed || :
	return 1
}

path_current() {
	[ "$require_path" = 0 ] && return 0
	path_fingerprint="$(table=ikev2_client_path; runtime_owned && runtime_fingerprint)" || return 1
	"$ucode_bin" "$runtime_lib_dir/client-access-ready.uc" "$runtime_dir" "$work/plan.json" "$path_fingerprint" >/dev/null 2>&1
}

sync_access() {
	# A missing table first receives an empty guard, before reading VICI.
	if ! runtime_exists; then
		close_access || { failed; return 1; }
	else
		runtime_owned || { failed; return 1; }
	fi
	if [ "$("$uci_bin" -q get ikev2-manager.server.enabled 2>/dev/null)" != 1 ]; then
		close_access || { failed; return 1; }
		status_write closed
		return
	fi
	pool="$("$uci_bin" -q get ikev2-manager.server.pool4 2>/dev/null)" || { failed; return 1; }
	if ! pkg_run_bounded 3 "$swanmon_bin" list-sas >"$work/sessions.json" 2>/dev/null; then
		failed
		return 1
	fi
	if ! "$ucode_bin" "$runtime_lib_dir/client-access-runtime.uc" live "$state_dir" "$pool" "$work/sessions.json" >"$work/plan.json" 2>/dev/null || ! client_path_sync || ! path_current || ! install_plan; then
		failed
		return 1
	fi
	if [ "$require_path" = 1 ]; then
		"$ucode_bin" "$runtime_lib_dir/client-access-device-stamp.uc" "$runtime_dir" "$state_dir" "$work/plan.json" "$path_fingerprint" >/dev/null 2>&1 || { failed; return 1; }
	fi
	generation="$(jsonfilter -i "$work/plan.json" -e '@.generation')"
	grants="$(jsonfilter -i "$work/plan.json" -e '@.grants')"
	mode="$(jsonfilter -i "$work/plan.json" -e '@.mode')"
	status_write "$mode" "$generation" "$grants"
}

case "${1:-}" in
	status) cat "$runtime_dir/status" 2>/dev/null; exit $? ;;
	sync | close | watch) ;;
	*) printf '%s\n' 'usage: ikev2-client-access sync|close|watch|status' >&2; exit 2 ;;
esac
mkdir -p "$runtime_dir" || exit 1
chmod 700 "$runtime_dir" || exit 1
pid_lock_acquire "$runtime_dir/worker.lock" || exit 1
work="$(mktemp -d "$runtime_dir/job.XXXXXX")" || { pid_lock_release "$runtime_dir/worker.lock"; exit 1; }
cleanup() {
	close_grants || :
	[ "$require_path" = 1 ] && [ "$auto_path" = 1 ] && client_path_stop
	if close_grants; then status_write closed || :; else status_write failed || :; fi
	rm -rf "$work"
	pid_lock_release "$runtime_dir/worker.lock"
}
# One-shot sync leaves its short-lived grants for the watcher/next sync.
finish() {
	rm -rf "$work"
	pid_lock_release "$runtime_dir/worker.lock"
}
trap 'cleanup; exit 1' HUP INT TERM
case "$1" in
	sync) rc=0; sync_access || rc=$?; finish; exit "$rc" ;;
	close) rc=0; close_grants || rc=1; [ "$require_path" = 1 ] && [ "$auto_path" = 1 ] && client_path_stop; if close_access; then status_write closed; else rc=1; failed || :; fi; finish; exit "$rc" ;;
	watch)
		close_access || { failed; finish; exit 1; }
		while :; do
			sync_access || :
			sleep 2 &
			wait "$!" || :
		done
		;;
esac
