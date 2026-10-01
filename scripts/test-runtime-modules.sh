#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
# The LuCI backend's source is the script plus the libraries it sources.
manager_source="$tmp/manager-source.sh"
cat "$root/luci-ikev2-manager/ikev2-manager.sh" \
	"$root"/ikev2-manager-runtime/lib/manager-*.sh >"$manager_source"
# The system helper's source is the script plus the libraries it sources.
system_source="$tmp/system-source.sh"
cat "$root/ikev2-manager-runtime/ikev2-manager-system.sh" \
	"$root"/ikev2-manager-runtime/lib/system-*.sh >"$system_source"

action_status_file="$tmp/latest.status"
action_status_dir="$tmp/actions"
action_lock_dir="$tmp/action.lock"
action_lock_status="$tmp/action.lock.status"

# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/actions.sh"

grep -Fq 'date -r "$action_lock_dir" +%s' \
	"$root/ikev2-manager-runtime/lib/actions.sh"

action_status test-1 running 'Testing shared actions'
grep -q '^action_id=test-1$' "$action_status_file"
grep -q '^state=running$' "$action_status_file"
grep -q '^message=Testing shared actions$' "$action_status_file"
acquire_action_lock tests test-1
grep -q '^owner=tests$' "$action_lock_status"
if [ -r "/proc/$$/stat" ]; then
	grep -Eq '^pid_start=[0-9]+$' "$action_lock_status"
else
	grep -Fxq 'pid_start=' "$action_lock_status"
fi
rm -f "$action_lock_status"
rmdir "$action_lock_dir"

# A helper started inside a router action finds the lock held by an ancestor
# and goes ahead without waiting for it. Nothing else counts: rpcd passes a
# page's environment through, so the claim used to be an environment variable
# any LuCI session could set.
sleep 30 &
holder=$!
mkdir -p "$tmp/proc/$$" "$tmp/proc/4242"
printf '4242 (ikev2 helper) S %s 0 0\n' "$holder" >"$tmp/proc/4242/stat"
printf 'owner=tests\naction_id=test-2\npid=%s\npid_start=\n' "$holder" >"$action_lock_status"
IKEV2_PROC_ROOT="$tmp/proc"
export IKEV2_PROC_ROOT
printf '%s (sh) S 4242 0 0\n' "$$" >"$tmp/proc/$$/stat"
action_lock_held_by_ancestor || {
	echo 'a lock held by the grandparent was not recognised' >&2
	exit 1
}
printf '%s (sh) S 1 0 0\n' "$$" >"$tmp/proc/$$/stat"
if action_lock_held_by_ancestor; then
	echo 'a lock held outside the process tree was taken as held' >&2
	exit 1
fi
printf '%s (sh) S 4242 0 0\n' "$$" >"$tmp/proc/$$/stat"
kill "$holder"
wait "$holder" 2>/dev/null || :
if action_lock_held_by_ancestor; then
	echo 'a lock whose holder has exited was taken as held' >&2
	exit 1
fi
unset IKEV2_PROC_ROOT
rm -f "$action_lock_status"

# A free lock is taken without claiming to wait for anything.
announced=''
announce() { announced="$*"; }
acquire_action_lock_announced tests test-free announce
[ -z "$announced" ] || { echo "a free lock announced a wait: $announced" >&2; exit 1; }
rm -f "$action_lock_status"
rmdir "$action_lock_dir"

sleep 30 &
lock_holder=$!
mkdir "$action_lock_dir"
printf 'owner=busy\naction_id=busy-1\npid=%s\nupdated=%s\n' \
	"$lock_holder" "$(date +%s)" >"$action_lock_status"
started="$(date +%s)"
if IKEV2_ACTION_LOCK_WAIT_SECONDS=1 acquire_action_lock tests test-busy; then
	echo 'live action lock was acquired by a competing worker' >&2
	exit 1
fi
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -le 3 ] || {
	echo "busy action lock did not fail promptly: ${elapsed}s" >&2
	exit 1
}
IKEV2_ACTION_LOCK_WAIT_SECONDS=1 acquire_action_lock_announced tests test-busy announce || :
[ "$announced" = "running Waiting for other router actions..." ] || {
	echo "a held lock did not announce the wait: $announced" >&2
	exit 1
}

# Age is diagnostic metadata, not a lease expiry. A long-running package or
# network transaction must retain the lock for as long as its process identity
# still matches.
printf 'owner=busy\naction_id=busy-old\npid=%s\nupdated=1\n' \
	"$lock_holder" >"$action_lock_status"
if IKEV2_ACTION_LOCK_WAIT_SECONDS=1 acquire_action_lock tests test-aged-busy; then
	echo 'aged live action lock was stolen' >&2
	exit 1
fi
kill "$lock_holder"
wait "$lock_holder" 2>/dev/null || true
rm -f "$action_lock_status"
rmdir "$action_lock_dir"

mkdir "$action_lock_dir"
printf 'owner=dead\naction_id=dead-1\npid=999999\nupdated=%s\n' \
	"$(date +%s)" >"$action_lock_status"
if action_lock_busy; then
	echo 'dead global action lock still suppresses health reconciliation' >&2
	exit 1
fi
[ ! -d "$action_lock_dir" ] && [ ! -e "$action_lock_status" ]

mkdir "$action_lock_dir"
action_lock_busy || {
	echo 'fresh unpublished action lock was removed during its hand-off window' >&2
	exit 1
}
[ -d "$action_lock_dir" ]
rmdir "$action_lock_dir"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_IP_LOG"
case "$*" in
	"-4 route show table pbr_ikev2out")
		if [ "${MOCK_FAILCLOSED_MISSING:-0}" != 1 ]; then
			echo 'unreachable default metric 32767'
			[ "${MOCK_TUNNEL_ROUTE:-0}" != 1 ] || echo 'default dev ipsec-out metric 10'
		fi
		;;
	"-4 rule show")
		[ "${MOCK_FAILCLOSED_RULE_MISSING:-0}" = 1 ] ||
			echo '30000: from all fwmark 0x10000/0xff0000 lookup pbr_ikev2out'
		;;
	"-6 route show table pbr_ikev2out")
		[ "${MOCK_FAILCLOSED6_MISSING:-0}" = 1 ] || echo 'unreachable default metric 32767'
		;;
	"-6 rule show")
		[ "${MOCK_FAILCLOSED6_RULE_MISSING:-0}" = 1 ] ||
			echo '30000: from all fwmark 0x10000/0xff0000 lookup pbr_ikev2out'
		;;
	"-6 route get "*)
		echo 'RTNETLINK answers: Network is unreachable' >&2
		exit 2
		;;
	"-4 route get "*)
		if [ "${MOCK_TUNNEL_ROUTE:-0}" = 1 ]; then
			echo '203.0.113.77 dev ipsec-out src 10.20.20.14 mark 0x20000'
			exit 0
		fi
		echo 'RTNETLINK answers: Network is unreachable' >&2
		exit 2
		;;
	*) ;;
esac
EOF
cat >"$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
[ "${MOCK_DNS_READY:-0}" = 1 ] || exit 1
cat <<'ANSWER'
Name: openwrt.org
Address: 64.226.122.113
ANSWER
EOF
chmod 755 "$tmp/bin/ip" "$tmp/bin/nslookup"

PATH="$tmp/bin:$PATH"
TEST_IP_LOG="$tmp/ip.log"
export TEST_IP_LOG
export PATH
# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/routing.sh"
# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/package-manager.sh"

grep -Fq 'pkg_run_bounded "$seconds" apk update' \
	"$root/ikev2-manager-runtime/lib/package-manager.sh"

pkg_run_bounded 2 sh -c 'exit 0'
if pkg_run_bounded 2 sh -c 'exit 7'; then
	echo 'bounded command discarded a non-zero exit status' >&2
	exit 1
fi
started="$(date +%s)"
if pkg_run_bounded 1 sh -c 'sleep 30'; then
	echo 'bounded command did not stop at its deadline' >&2
	exit 1
fi
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -le 3 ] || {
	echo "bounded command exceeded its deadline: ${elapsed}s" >&2
	exit 1
}
if [ -r "/proc/$$/task/$$/children" ]; then
	rm -f "$tmp/leaked-child"
	if TEST_LEAK_MARKER="$tmp/leaked-child" pkg_run_bounded 1 sh -c \
		'(sleep 2; printf leaked >"$TEST_LEAK_MARKER") & wait'; then
		echo 'bounded command with a child ignored its deadline' >&2
		exit 1
	fi
	sleep 2
	[ ! -e "$tmp/leaked-child" ] || {
		echo 'bounded command left a child process running' >&2
		exit 1
	}
fi

pkg_install_plan() {
	printf '%s\n' "${TEST_PACKAGE_PLAN:-Installing new-package (1.0) on root}"
}
TEST_PACKAGE_PLAN='Installing new-package (1.0) on root'
pkg_install_plan_safe new-package >/dev/null
TEST_PACKAGE_PLAN='Upgrading libopenssl3 on root from 3.0.0 to 3.0.1'
if pkg_install_plan_safe new-package >/dev/null 2>&1; then
	echo 'unsafe dependency upgrade plan was accepted' >&2
	exit 1
fi
TEST_PACKAGE_PLAN='Removing package pbr from root'
if PKG_PLAN_ALLOW_DNSMASQ_SWAP=1 pkg_install_plan_safe dnsmasq-full >/dev/null 2>&1; then
	echo 'unrelated package removal was accepted as a dnsmasq provider swap' >&2
	exit 1
fi
TEST_PACKAGE_PLAN='Removing package dnsmasq from root'
PKG_PLAN_ALLOW_DNSMASQ_SWAP=1 pkg_install_plan_safe dnsmasq-full >/dev/null
unset TEST_PACKAGE_PLAN

MOCK_DNS_READY=1
export MOCK_DNS_READY
wait_for_router_dns 127.0.0.1 1 openwrt.org
MOCK_DNS_READY=0
if wait_for_router_dns 127.0.0.1 1 openwrt.org; then
	echo 'router DNS readiness check accepted a failed query' >&2
	exit 1
fi

failclosed_check
MOCK_TUNNEL_ROUTE=1 failclosed_check
if grep -Eq '(^| )(add|del|delete|flush|replace)( |$)' "$TEST_IP_LOG"; then
	echo 'failclosed_check modified routing state' >&2
	exit 1
fi
if MOCK_FAILCLOSED_MISSING=1 failclosed_check; then
	echo 'failclosed_check accepted a table without unreachable default' >&2
	exit 1
fi
if MOCK_FAILCLOSED_RULE_MISSING=1 failclosed_check; then
	echo 'failclosed_check accepted a table without a matching policy rule' >&2
	exit 1
fi
failclosed_ipv6_check
if MOCK_FAILCLOSED6_MISSING=1 failclosed_ipv6_check; then
	echo 'failclosed_ipv6_check accepted a table without unreachable default' >&2
	exit 1
fi
if MOCK_FAILCLOSED6_RULE_MISSING=1 failclosed_ipv6_check; then
	echo 'failclosed_ipv6_check accepted a table without a matching policy rule' >&2
	exit 1
fi
if grep -Eq '(^| )(add|del|delete|flush|replace)( |$)' "$TEST_IP_LOG"; then
	echo 'fail-closed validation modified routing state' >&2
	exit 1
fi

pkg_cache="$tmp/packages"
mkdir -p "$pkg_cache"
printf x >"$pkg_cache/dnsmasq_2.93-r1_all.ipk"
printf x >"$pkg_cache/dnsmasq-full_2.93-r1_all.ipk"
printf x >"$pkg_cache/dnsmasq-2.93-r1.apk"
printf x >"$pkg_cache/dnsmasq-full-2.93-r1.apk"
cat >"$tmp/bin/opkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${TEST_OPKG_LOG:-/dev/null}"
case "$1" in
	compare-versions)
		[ "$3" = ge ] || exit 1
		case "$2:$4" in
			6.0.7:6.0.3 | 6.0.7:6.0.7 | 6.0.3:6.0.3) exit 0 ;;
			*) exit 1 ;;
		esac
		;;
	status)
		case "$2" in
			strongswan | strongswan-*)
				printf 'Version: %s\n' "${TEST_STRONGSWAN_VERSION:-6.0.7}"
				;;
		esac
		;;
	remove | install) exit 0 ;;
	list-installed)
		# The real format: "name - version".
		version_of() {
			case "$1" in
				strongswan | strongswan-*) printf '%s' "${TEST_STRONGSWAN_VERSION:-6.0.7}" ;;
				*) printf '1' ;;
			esac
		}
		if [ -n "${2:-}" ]; then
			printf '%s - %s\n' "$2" "$(version_of "$2")"
		else
			for package in ${TEST_OPKG_INSTALLED:-strongswan}; do
				printf '%s - %s\n' "$package" "$(version_of "$package")"
			done
		fi
		exit 0
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/opkg"

IKEV2_PACKAGE_MANAGER=opkg
export IKEV2_PACKAGE_MANAGER
TEST_STRONGSWAN_VERSION=6.0.7
export TEST_STRONGSWAN_VERSION
pkg_version_at_least strongswan 6.0.3
TEST_STRONGSWAN_VERSION=6.0.3
if pkg_version_at_least strongswan 6.0.7; then
	echo 'opkg version comparison accepted an older strongSwan release' >&2
	exit 1
fi
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq-full)")" = dnsmasq-full_2.93-r1_all.ipk ] || {
	echo 'opkg package lookup did not select the .ipk file' >&2
	exit 1
}
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq)")" = dnsmasq_2.93-r1_all.ipk ] || {
	echo 'opkg package lookup did not select the base dnsmasq .ipk file' >&2
	exit 1
}
TEST_OPKG_LOG="$tmp/opkg.log"
export TEST_OPKG_LOG
: >"$TEST_OPKG_LOG"
pkg_switch_dnsmasq_full "$pkg_cache" dnsmasq
pkg_restore_dnsmasq "$pkg_cache" dnsmasq
grep -qx 'remove --force-depends dnsmasq' "$TEST_OPKG_LOG"
grep -qx "install $pkg_cache/dnsmasq-full_2.93-r1_all.ipk" "$TEST_OPKG_LOG"
grep -qx "install $pkg_cache/dnsmasq_2.93-r1_all.ipk" "$TEST_OPKG_LOG"
grep -qx 'remove --force-depends dnsmasq-full' "$TEST_OPKG_LOG"

cat >"$tmp/bin/apk" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${TEST_APK_LOG:-/dev/null}"
installed="${TEST_APK_INSTALLED:-}"
[ -z "${TEST_APK_STATE:-}" ] || installed="$(cat "$TEST_APK_STATE" 2>/dev/null || true)"
case "$1 $2 $3 $4" in
	"list --installed --manifest ")
		for package in $installed; do
			case "$package" in
				strongswan) printf '%s %s\n' "$package" "${TEST_STRONGSWAN_VERSION:-6.0.7}" ;;
				strongswan-*) printf '%s %s\n' "$package" \
					"${TEST_STRONGSWAN_PLUGIN_VERSION:-${TEST_STRONGSWAN_VERSION:-6.0.7}}" ;;
				*) printf '%s 1\n' "$package" ;;
			esac
		done
		;;
	"list --installed --manifest pbr") echo 'pbr 1.2.2-r18' ;;
	"list --installed --manifest strongswan")
		echo "strongswan ${TEST_STRONGSWAN_VERSION:-6.0.7}"
		;;
	"list --installed --manifest strongswan-"*)
		package="$4"
		echo "$package ${TEST_STRONGSWAN_PLUGIN_VERSION:-${TEST_STRONGSWAN_VERSION:-6.0.7}}"
		;;
	"info -e "*) case " $installed " in *" $3 "*) exit 0;; *) exit 1;; esac ;;
	"add dnsmasq-full  ")
		[ -z "${TEST_APK_STATE:-}" ] || printf '%s\n' 'dnsmasq-full' >"$TEST_APK_STATE"
		exit 0
		;;
	"add dnsmasq  ")
		[ -z "${TEST_APK_STATE:-}" ] || printf '%s\n' 'dnsmasq dnsmasq-full' >"$TEST_APK_STATE"
		exit 0
		;;
	"version -t 6.0.7 6.0.3") echo '>' ;;
	"version -t 6.0.3 6.0.7") echo '<' ;;
	"del dnsmasq-full  ")
		[ -z "${TEST_APK_STATE:-}" ] || printf '%s\n' 'dnsmasq' >"$TEST_APK_STATE"
		exit 0
		;;
	"del pbr strongswan ") exit 0 ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/dnsmasq" <<'EOF'
#!/bin/sh
printf 'Compile time options: IPv6 UBus %s no-DNSSEC\n' "${TEST_DNSMASQ_OPTION:-no-nftset}"
EOF
chmod 755 "$tmp/bin/apk" "$tmp/bin/dnsmasq"

IKEV2_PACKAGE_MANAGER=apk
TEST_STRONGSWAN_VERSION=6.0.7
pkg_version_at_least strongswan 6.0.3
TEST_STRONGSWAN_VERSION=6.0.3
if pkg_version_at_least strongswan 6.0.7; then
	echo 'apk version comparison accepted an older strongSwan release' >&2
	exit 1
fi

# Dependency repair keeps all strongSwan components on the installed build.
# A mixed daemon/plugin state is rejected before the package solver runs.
eval "$(sed -n \
	-e '/^runtime_packages() {/,/^}/p' \
	-e '/^strongswan_cohort_version() {/,/^}/p' \
	-e '/^runtime_install_arguments() {/,/^}/p' \
	"$system_source")"
TEST_APK_INSTALLED='strongswan strongswan-charon'
TEST_STRONGSWAN_VERSION=6.0.3
TEST_STRONGSWAN_PLUGIN_VERSION=6.0.3
export TEST_APK_INSTALLED TEST_STRONGSWAN_PLUGIN_VERSION
[ "$(runtime_install_arguments strongswan-mod-vici pbr)" = \
"strongswan-mod-vici=6.0.3
pbr" ] || {
	echo 'strongSwan repair arguments are not pinned to the installed cohort' >&2
	exit 1
}
TEST_STRONGSWAN_PLUGIN_VERSION=6.0.7
if runtime_install_arguments strongswan-mod-vici >/dev/null 2>&1; then
	echo 'mixed strongSwan package cohort was accepted' >&2
	exit 1
fi
TEST_APK_INSTALLED='strongswan-charon'
TEST_STRONGSWAN_PLUGIN_VERSION=6.0.3
if runtime_install_arguments strongswan >/dev/null 2>&1; then
	echo 'strongSwan plugin cohort without its base package was accepted' >&2
	exit 1
fi
IKEV2_PACKAGE_MANAGER=opkg
TEST_APK_INSTALLED='strongswan strongswan-charon'
[ "$(runtime_install_arguments strongswan-charon pbr)" = pbr ] || {
	echo 'opkg repair would reinstall an existing strongSwan cohort member' >&2
	exit 1
}
# One report answers every package question from one listing, then forgets it,
# so an installer that runs afterwards asks the package manager again.
IKEV2_PACKAGE_MANAGER=apk
TEST_APK_INSTALLED='strongswan strongswan-charon pbr'
TEST_STRONGSWAN_VERSION=6.0.3
TEST_STRONGSWAN_PLUGIN_VERSION=6.0.3
TEST_APK_LOG="$tmp/apk-cache.log"
export TEST_APK_INSTALLED TEST_STRONGSWAN_VERSION TEST_STRONGSWAN_PLUGIN_VERSION TEST_APK_LOG
: >"$TEST_APK_LOG"
pkg_cache_versions
[ "$(strongswan_cohort_version)" = 6.0.3 ] && [ "$(pkg_version pbr)" = 1 ] &&
	pkg_installed strongswan-charon && ! pkg_installed dnsmasq || {
	echo 'cached package answers are wrong' >&2
	exit 1
}
[ "$(wc -l <"$TEST_APK_LOG" | tr -d ' ')" = 1 ] || {
	echo "a cached report still queried apk $(wc -l <"$TEST_APK_LOG") times" >&2
	exit 1
}
pkg_cache_clear
pkg_version strongswan >/dev/null
[ "$(wc -l <"$TEST_APK_LOG" | tr -d ' ')" = 2 ] || {
	echo 'pkg_cache_clear did not return to live package queries' >&2
	exit 1
}
unset TEST_APK_LOG

IKEV2_PACKAGE_MANAGER=apk
TEST_STRONGSWAN_PLUGIN_VERSION=6.0.3
TEST_APK_INSTALLED=pbr
export TEST_APK_INSTALLED
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq-full)")" = dnsmasq-full-2.93-r1.apk ] || {
	echo 'apk package lookup did not select the .apk file' >&2
	exit 1
}
[ "$(basename "$(pkg_package_file "$pkg_cache" dnsmasq)")" = dnsmasq-2.93-r1.apk ] || {
	echo 'apk package lookup did not select the base dnsmasq .apk file' >&2
	exit 1
}
[ "$(pkg_version pbr)" = 1.2.2-r18 ] || {
	echo 'apk package version parsing failed' >&2
	exit 1
}
pkg_installed pbr || {
	echo 'apk installed-package check failed' >&2
	exit 1
}
TEST_APK_INSTALLED=dnsmasq
export TEST_APK_INSTALLED
[ "$(pkg_dnsmasq_provider)" = dnsmasq ] || {
	echo 'apk dnsmasq provider detection failed' >&2
	exit 1
}
TEST_APK_LOG="$tmp/apk.log"
export TEST_APK_LOG
: >"$TEST_APK_LOG"
pkg_switch_dnsmasq_full "$pkg_cache" dnsmasq
grep -qx 'add dnsmasq-full' "$TEST_APK_LOG"
TEST_APK_STATE="$tmp/apk.state"
export TEST_APK_STATE
printf '%s\n' dnsmasq-full >"$TEST_APK_STATE"
pkg_restore_dnsmasq "$pkg_cache" dnsmasq
grep -qx 'add dnsmasq' "$TEST_APK_LOG"
grep -qx 'del dnsmasq-full' "$TEST_APK_LOG"
[ "$(cat "$TEST_APK_STATE")" = dnsmasq ]
unset TEST_APK_STATE
TEST_APK_INSTALLED='pbr strongswan'
: >"$TEST_APK_LOG"
pkg_remove_runtime pbr missing strongswan
grep -qx 'del pbr strongswan' "$TEST_APK_LOG"
TEST_DNSMASQ_OPTION=nftset pkg_dnsmasq_has_nftset || {
	echo 'dnsmasq nftset capability was not detected' >&2
	exit 1
}
if TEST_DNSMASQ_OPTION=no-nftset pkg_dnsmasq_has_nftset; then
	echo 'dnsmasq no-nftset was accepted as nftset support' >&2
	exit 1
fi

grep -Fq '[ "$(uci -q get ikev2-manager.globals.configured)" = 1 ] || return 1' \
	"$root/ikev2-manager-runtime/ikev2-xfrm.init"
grep -Fq 'if base_config_matches; then' \
	"$system_source"
grep -Fq '"$routing_check_helper" --check' \
	"$system_source"
grep -Fq '"$restart_helper" --check' \
	"$root/luci-ikev2-domains/community-domains.sh"
stop_body="$(sed -n '/^stop() {/,/^}/p' \
	"$root/ikev2-manager-runtime/ikev2-xfrm.init")"
printf '%s\n' "$stop_body" | grep -Fq 'ip link set ipsec-in down'
if grep -Fq 'ip link del' "$root/ikev2-manager-runtime/ikev2-xfrm.init"; then
	echo 'XFRM lifecycle still deletes live interfaces' >&2
	exit 1
fi
sed -n '/run_remove_deps()/,/^}/p' \
	"$system_source" |
	grep -Fq '/etc/init.d/ikev2-xfrm stop'
if grep -Fq 'ikev2-xfrm purge' "$system_source" \
	"$root/scripts/package-prerm.sh" "$root/Makefile"; then
	echo 'package cleanup still attempts unsafe XFRM deletion' >&2
	exit 1
fi
remove_managed_body="$(sed -n '/^remove_managed() {/,/^}/p' \
	"$system_source")"
health_stop_line="$(printf '%s\n' "$remove_managed_body" | grep -n 'ikev2-health stop' | head -1 | cut -d: -f1)"
user_policy_stop_line="$(printf '%s\n' "$remove_managed_body" | grep -n 'user_policy_helper.*stop' | head -1 | cut -d: -f1)"
[ -n "$health_stop_line" ] && [ -n "$user_policy_stop_line" ] &&
	[ "$health_stop_line" -lt "$user_policy_stop_line" ] || {
	echo 'managed cleanup can race the health reconciler while removing runtime' >&2
	exit 1
}
fw_reload_line="$(printf '%s\n' "$remove_managed_body" | grep -n 'fw4 -q reload' | head -1 | cut -d: -f1)"
xfrm_stop_line="$(printf '%s\n' "$remove_managed_body" | grep -n 'ikev2-xfrm stop' | head -1 | cut -d: -f1)"
[ -n "$fw_reload_line" ] && [ -n "$xfrm_stop_line" ] &&
	[ "$fw_reload_line" -lt "$xfrm_stop_line" ] || {
	echo 'managed cleanup still stops XFRM before removing firewall references' >&2
	exit 1
}
[ -n "$user_policy_stop_line" ] && [ "$user_policy_stop_line" -gt "$xfrm_stop_line" ] || {
	echo 'managed cleanup removes the inbound access guard while XFRM is live' >&2
	exit 1
}
device_stop_line="$(printf '%s\n' "$remove_managed_body" | grep -n 'device_runtime_helper.*stop' | head -1 | cut -d: -f1)"
[ -n "$device_stop_line" ] && [ "$device_stop_line" -gt "$xfrm_stop_line" ] || {
	echo 'managed cleanup removes the atomic device policy before risky teardown completes' >&2
	exit 1
}
grep -Fq 'dependencies_ok=' "$system_source"
grep -Fq 'dependenciesReady(doctor)' "$root/luci-ikev2-manager/setup.js"
grep -Fq "enabled.disabled = value.configured !== '1' && !ready" \
	"$root/luci-ikev2-manager/setup.js"
printf '%s\n' "$remove_managed_body" | grep -Fq 'release_pbr_config || return 1'
sed -n '/^release_pbr_config() {/,/^}/p' "$system_source" | grep -Fq 'device_pbr_clear'
disabled_check="$(sed -n '/^disabled_runtime_absent() {/,/^}/p' \
	"$system_source")"
printf '%s\n' "$disabled_check" | grep -Fq 'pbr_dev_(fr|ex)_'
for table in ikev2_device_policy ikev2_user_policy ikev2_discord_voice ikev2_domain_router; do
	printf '%s\n' "$disabled_check" | grep -Fq "table inet $table"
done
if grep -Fq 'strongswan-security server' \
	"$root/ikev2-manager-runtime/ikev2-xfrm.init"; then
	echo 'inbound XFRM is still blocked by the strongSwan advisory' >&2
	exit 1
fi
grep -Fq 'START=88' "$root/ikev2-manager-runtime/ikev2-user-policy.init"
grep -Fq 'STOP=90' "$root/ikev2-manager-runtime/ikev2-user-policy.init"
grep -Fq 'ikev2-user-policy.init' "$root/Makefile"
grep -Fq 'sync_inbound_user_policy || die' \
	"$system_source"
grep -Fq '[ "$(uci -q get ikev2-manager.globals.configured)" = 1 ] || return 0' \
	"$root/ikev2-manager-runtime/pbr.user.ikev2out"
grep -Fq 'ensure_failclosed_default 4' \
	"$root/ikev2-manager-runtime/pbr.user.ikev2out"
if grep -Fq 'reconnect-client' "$root/ikev2-manager-runtime/ikev2-health.sh"; then
	echo 'health watcher still reconnects an installed SA after public probe failures' >&2
	exit 1
fi
if sed -n '/run_remove_deps()/,/^}/p' \
	"$system_source" | grep -Fq '/etc/init.d/pbr stop'; then
	echo 'dependency removal still stops restored user PBR state' >&2
	exit 1
fi
grep -Fq 'fail "cleanup helper is missing; package removal stopped before changing files"' \
	"$root/Makefile"
grep -Fq 'fail "unable to restore managed router state; package removal stopped before changing files"' \
	"$root/Makefile"
if grep -Fq 'route flush table' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"; then
	echo 'FakeIP cleanup still flushes an entire routing table' >&2
	exit 1
fi
grep -Fq "tproxy_table='51820'" "$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq "tproxy_priority='11000'" "$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'ip -4 rule add iif "$device" to "$fakeip_range"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'ip -4 rule add iif lo fwmark "$tproxy_mark/$tproxy_mask"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
# Upgrades must recognize the exact rule installed by the preceding release
# before nft_stop can replace it; an unrelated rule at the slot still blocks.
(
	eval "$(sed -n '/^routing_slot_available() {/,/^}/p' \
		"$root/ikev2-manager-runtime/ikev2-domain-router.sh")"
	tproxy_priority=11000 router_tproxy_priority=10999 tproxy_table=51820
	fakeip_range=198.18.0.0/15 tproxy_mark=0x400000 tproxy_mask=0xff0000
	ip() {
		case "$*" in
			'-4 rule show') printf '%s\n' "$test_rule" ;;
			'-4 route show table 51820') echo 'local default dev lo scope host' ;;
			*) return 1 ;;
		esac
	}
	test_rule='11000: from all fwmark 0x400000/0xff0000 lookup 51820'
	routing_slot_available
	test_rule='11000: from all to 198.18.0.0/15 lookup 51820'
	routing_slot_available
	test_rule='11000: from all to 198.18.0.0/15 iif br-lan lookup 51820'
	routing_slot_available
	test_rule='10999: from all to 198.18.0.0/15 fwmark 0x400000/0xff0000 iif lo lookup 51820'
	routing_slot_available
	test_rule='11000: from all to 203.0.113.0/24 lookup 51820'
	if routing_slot_available; then
		echo 'Foreign TProxy routing rule was accepted' >&2
		exit 1
	fi
	eval "$(sed -n '/^tproxy_rules_ready() {/,/^}/p' \
		"$root/ikev2-manager-runtime/ikev2-domain-router.sh")"
	local_devices() { echo br-lan; }
	defaultv() { echo 1; }
	test_rule="$(printf '%s\n' \
		'10999: from all to 198.18.0.0/15 fwmark 0x400000/0xff0000 iif lo lookup 51820' \
		'11000: from all to 198.18.0.0/15 iif br-lan lookup 51820')"
	tproxy_rules_ready
	test_rule='11000: from all to 198.18.0.0/15 iif br-lan lookup 51820'
	if tproxy_rules_ready; then
		echo 'Router-originated FakeIP rule was not required' >&2
		exit 1
	fi
	test_rule='10999: from all to 198.18.0.0/15 fwmark 0x400000/0xff0000 iif lo lookup 51820'
	if tproxy_rules_ready; then
		echo 'LAN FakeIP rule was not required' >&2
		exit 1
	fi
)
if grep -Fq 'ip -4 rule add fwmark "$tproxy_mark/$tproxy_mask"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"; then
	echo 'FakeIP local delivery still selects its table by fwmark' >&2
	exit 1
fi
grep -Fq "tag: 'tproxy-direct-in'" \
	"$root/ikev2-manager-runtime/lib/singbox-config.uc"
grep -Fq "tag: 'tproxy-router-in'" \
	"$root/ikev2-manager-runtime/lib/singbox-config.uc"
grep -Fq 'meta mark == $direct_tproxy_mark return' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'meta mark == $router_tproxy_mark meta l4proto tcp tproxy ip to $tproxy_address:$router_tproxy_port' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
if grep -Fq '"routing_mark"' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"; then
	echo 'FakeIP config still contains a hard-coded PBR routing mark' >&2
	exit 1
fi
grep -Fq 'strongswan_eap_server_security=warn:%s-cve-2026-47895' \
	"$system_source"
grep -Fq 'strongswan_cohort=invalid:mixed-or-missing-version' \
	"$system_source"
grep -Fq 'runtime_install_arguments $missing' \
	"$system_source"
grep -Fq 'pbr_restart_checked()' \
	"$system_source"
# Site Link is gone; nothing may keep shared state alive for it.
if grep -n -i 'site_link\|ikev2-site-link' "$system_source"; then
	echo 'the manager still carries Site Link ownership rules' >&2
	exit 1
fi
grep -Fq 'sing_box_fakeip=invalid:' \
	"$system_source"
grep -Fq 'pkg_version_at_least sing-box 1.13.19' \
	"$system_source"
if grep -Fq 'Inbound server is blocked: installed strongSwan is unsafe for EAP-MSCHAPv2.' \
	"$manager_source"; then
	echo 'inbound profile rendering is still blocked by the strongSwan advisory' >&2
	exit 1
fi
grep -Fq 'Outbound client is blocked: installed strongSwan is unsafe for EAP-MSCHAPv2.' \
	"$manager_source"
if grep -Fq 'Inbound custom configuration is blocked by the installed strongSwan version' \
	"$manager_source"; then
	echo 'inbound custom profiles are still blocked by the strongSwan advisory' >&2
	exit 1
fi
grep -Fq 'Outbound custom configuration is blocked by the installed strongSwan version' \
	"$manager_source"
if grep -Fq '/usr/libexec/ikev2-manager-system strongswan-security server' \
	"$root/ikev2-manager-runtime/ikev2-health.sh"; then
	echo 'inbound health recovery is still blocked by the strongSwan advisory' >&2
	exit 1
fi

printf 'runtime module tests OK\n'
