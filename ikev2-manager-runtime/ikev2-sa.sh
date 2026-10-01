#!/bin/sh
# ikev2-sa COMMAND IKE [CHILD]: one answer about the active strongSwan SAs,
# or conn-loaded NAME: whether a connection is loaded.
# The commands and exit statuses are those of sa.uc. The snapshot comes from
# swanmon, bounded: an unanswered VICI query used to stall its caller for as
# long as charon stayed wedged.

set -u

runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
swanmon_bin="${IKEV2_SWANMON:-/usr/sbin/swanmon}"
ucode_bin="${IKEV2_UCODE:-ucode}"
seconds="${IKEV2_SA_TIMEOUT:-3}"

. "$runtime_lib_dir/package-manager.sh"

# conn-loaded NAME: whether charon has connection NAME loaded. swanctl
# --list-conns had no bound, so a wedged charon stopped the watcher with it.
if [ "${1:-}" = conn-loaded ]; then
	[ -n "${2:-}" ] || exit 2
	conns="$(pkg_run_bounded "$seconds" "$swanmon_bin" get-conns 2>/dev/null)" || exit 2
	printf '%s' "$conns" | jsonfilter -e '@.data.conns[*]' 2>/dev/null | grep -Fxq -- "$2"
	exit
fi

snapshot="$(mktemp "${TMPDIR:-/tmp}/ikev2-sa.XXXXXX")" || exit 2
trap 'rm -f "$snapshot"' EXIT INT TERM
if [ -n "${IKEV2_SA_JSON:-}" ]; then
	cat "$IKEV2_SA_JSON" >"$snapshot" 2>/dev/null || exit 2
else
	pkg_run_bounded "$seconds" "$swanmon_bin" list-sas >"$snapshot" 2>/dev/null || exit 2
fi
rc=0
"$ucode_bin" "$runtime_lib_dir/sa.uc" "$@" <"$snapshot" || rc=$?
exit "$rc"
