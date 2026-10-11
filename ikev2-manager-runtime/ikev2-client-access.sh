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
	for granted in allow_tcp allow_udp names_tcp names_udp names_clients; do
		printf 'flush set inet %s %s\n' "$table" "$granted"
	done >"$work/close.nft" || return 1
	pkg_run_bounded 3 "$nft_bin" -f "$work/close.nft" >/dev/null 2>&1
}

# Installs the compiled table. A table without a single grant holds nothing
# that expires, so one that is still exactly what was installed last time -
# the same program asked for, the same program in the kernel - is left as it
# is: replacing it every two seconds was most of what this watcher cost the
# router while no device was connected. Grants are always installed afresh,
# which is what renews their lease.
install_plan() {
	local wanted='' live
	[ "$(jsonfilter -i "$work/plan.json" -t '@.nft' 2>/dev/null)" = string ] || return 1
	jsonfilter -i "$work/plan.json" -e '@.nft' >"$work/guard.nft" || return 1
	if [ "$(jsonfilter -i "$work/plan.json" -e '@.grants' 2>/dev/null || echo 0)" = 0 ]; then
		wanted="$(sha256sum <"$work/guard.nft" | cut -d' ' -f1)"
		if [ -s "$runtime_dir/access-installed" ]; then
			live="$("$nft_bin" -s list table inet "$table" 2>/dev/null | sha256sum | cut -d' ' -f1)"
			[ "$(cat "$runtime_dir/access-installed" 2>/dev/null)" != "$wanted $live" ] || return 0
		fi
	fi
	rm -f "$runtime_dir/access-installed"
	: >"$work/transaction.nft"
	if runtime_exists; then
		runtime_owned || return 1
		printf 'delete table inet %s\n' "$table" >>"$work/transaction.nft"
	fi
	cat "$work/guard.nft" >>"$work/transaction.nft" || return 1
	pkg_run_bounded 3 "$nft_bin" -c -f "$work/transaction.nft" >/dev/null 2>&1 &&
		pkg_run_bounded 3 "$nft_bin" -f "$work/transaction.nft" >/dev/null 2>&1 && runtime_owned || return 1
	[ -n "$wanted" ] || return 0
	live="$("$nft_bin" -s list table inet "$table" 2>/dev/null | sha256sum | cut -d' ' -f1)" &&
		printf '%s %s\n' "$wanted" "$live" >"$runtime_dir/access-installed" || :
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
	# Already shown in this round by the path itself.
	[ "${path_verified:-0}" = 1 ] && return 0
	path_fingerprint="$(table=ikev2_client_path; runtime_owned && runtime_fingerprint)" || return 1
	"$ucode_bin" "$runtime_lib_dir/client-access-ready.uc" "$runtime_dir" "$work/plan.json" "$path_fingerprint" >/dev/null 2>&1
}

sync_access() {
	local listing
	path_verified=0
	# A missing table first receives an empty guard, before reading VICI.
	if ! listing="$("$nft_bin" list table inet "$table" 2>/dev/null)"; then
		close_access || { failed; return 1; }
	else
		case "$listing" in *'chain ikev2_manager_owned'*) ;; *) failed; return 1 ;; esac
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
	eval "$(jsonfilter -i "$work/plan.json" -e 'generation=@.generation' -e 'grants=@.grants' -e 'mode=@.mode')" || { failed; return 1; }
	case "$generation:$grants:$mode" in [0-9]*:[0-9]*:ready | [0-9]*:[0-9]*:closed) ;; *) failed; return 1 ;; esac
	# With no device yet there is nobody to answer for: the path stands ready
	# and closed, which is a healthy state and not a failure.
	if [ "$require_path" = 1 ] && [ "$mode" = ready ]; then
		"$ucode_bin" "$runtime_lib_dir/client-access-device-stamp.uc" "$runtime_dir" "$state_dir" "$work/plan.json" "$path_fingerprint" >/dev/null 2>&1 || { failed; return 1; }
	else
		rm -f "$runtime_dir/device-ready.json"
	fi
	status_write "$mode" "$generation" "$grants"
}

# Everything this controller put on the router, for when managed mode is
# turned off or the package is removed: the proxy, both owned tables, the
# local route and its rule. Only after the service has stopped - the lock
# refuses while the watcher runs. Stopping alone keeps the denial; this does
# not, because nothing remains that a device could reach.
teardown_runtime() {
	local rc=0 subnet=''
	close_grants || rc=1
	client_path_stop || rc=1
	subnet="$(sed -n 's/.*"subnet"[[:space:]]*:[[:space:]]*"\([0-9./]*\)".*/\1/p' "$runtime_dir/route-owner.json" 2>/dev/null)"
	[ -n "$subnet" ] || subnet="$("$ucode_bin" "$runtime_lib_dir/client-access-runtime.uc" subnet "$state_dir" '' '' 2>/dev/null)" || subnet=''
	case "$subnet" in *[!0-9./]*) subnet='' ;; esac
	if [ -n "$subnet" ]; then
		while ip -4 rule show 2>/dev/null | grep -Eq "^10998:[[:space:]]+from all to $subnet iif ipsec-in lookup 1506"; do
			ip -4 rule del priority 10998 iif ipsec-in to "$subnet" lookup 1506 2>/dev/null || { rc=1; break; }
		done
		ip -4 route show table 1506 2>/dev/null | grep -q "^local $subnet dev lo" &&
			{ ip -4 route del local "$subnet" dev lo table 1506 2>/dev/null || rc=1; }
	fi
	for owned in ikev2_client_path ikev2_client_access; do
		table="$owned"
		runtime_exists || continue
		if runtime_owned; then
			pkg_run_bounded 3 "$nft_bin" delete table inet "$owned" >/dev/null 2>&1 || rc=1
		fi
	done
	table=ikev2_client_access
	# The API's rate table goes with its server; a killed server leaves it.
	for cmdline in /proc/[0-9]*/cmdline; do tr '\0' ' ' 2>/dev/null <"$cmdline"; echo; done |
		grep -q '^/bin/sh /usr/libexec/ikev2-client-api serve $' ||
		"$nft_bin" delete table inet ikev2_client_api >/dev/null 2>&1 || :
	rm -f "$runtime_dir/route-owner.json" "$runtime_dir/device-ready.json" "$runtime_dir/path-ready.json" "$runtime_dir/access-installed" \
		"$runtime_dir/proxy.json" "$runtime_dir"/src-*.json
	status_write stopped || :
	return "$rc"
}

case "${1:-}" in
	status) cat "$runtime_dir/status" 2>/dev/null; exit $? ;;
	sync | close | watch | teardown) ;;
	*) printf '%s\n' 'usage: ikev2-client-access sync|close|watch|teardown|status' >&2; exit 2 ;;
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
	teardown) rc=0; teardown_runtime || rc=1; finish; exit "$rc" ;;
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
