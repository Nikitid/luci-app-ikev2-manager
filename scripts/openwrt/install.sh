#!/bin/sh
# Installs the package built by scripts/build-ipk.sh into a fresh OpenWrt rootfs
# container, the way a router gets it, then runs the scenarios - or, with the
# argument "failover", strongSwan as well and the two-tunnel test. /src is the
# repository, mounted read-only.

set -eu

mkdir -p /var/lock /var/run /tmp/run

# Packages are signed, so a mirror serves as well as the origin. The origin
# sometimes cuts large downloads short; when its index or a package cannot be
# fetched, the feeds are pointed at a mirror and the step is tried again.
with_mirrors() {
	"$@" && return 0
	for mirror in https://ftp.halifax.rwth-aachen.de/openwrt https://mirrors.tuna.tsinghua.edu.cn/openwrt; do
		for list in /etc/apk/repositories.d/*.list /etc/opkg/distfeeds.conf; do
			[ -f "$list" ] && sed -i "s#https://[^ ]*/releases/#$mirror/releases/#" "$list"
		done
		if command -v opkg >/dev/null 2>&1; then opkg update >/dev/null 2>&1 || continue; else apk update >/dev/null 2>&1 || continue; fi
		"$@" && return 0
	done
	return 1
}
ipk="$(ls /src/dist/*.ipk)"

if command -v opkg >/dev/null 2>&1; then
	# 24.10: the real package manager, maintainer scripts included. Only the
	# tools the runtime calls are installed; LuCI itself is not needed here.
	with_mirrors opkg update >/dev/null
	with_mirrors opkg install ip-full ucode-mod-fs ucode-mod-digest socat sing-box openssl-util >/dev/null
	opkg install --force-depends "$ipk" >/tmp/install.log 2>&1 || {
		cat /tmp/install.log >&2
		exit 1
	}
else
	# 25.12 installs the SDK-built APK, which needs the release signing key;
	# the IPK carries the same files, unpacked here without its scripts.
	with_mirrors apk update >/dev/null
	with_mirrors apk add ip-full ucode-mod-fs ucode-mod-digest socat sing-box openssl-util >/dev/null
	mkdir -p /tmp/ipk
	tar -xzf "$ipk" -C /tmp/ipk
	tar -xzf /tmp/ipk/data.tar.gz -C /
fi

if [ "${1:-}" = client-api ]; then
	if command -v opkg >/dev/null 2>&1; then
		with_mirrors opkg install uhttpd uhttpd-mod-ucode ucode-mod-digest curl >/dev/null
	else
		with_mirrors apk add uhttpd uhttpd-mod-ucode ucode-mod-digest curl >/dev/null
	fi
	exec sh /src/scripts/openwrt/client-api.sh
fi

if [ "${1:-}" = client-access ]; then
	# Container kernels must provide XFRM themselves; OpenWrt kmods cannot be
	# loaded into a differently versioned host kernel.
	if ! ip link add binding-probe type xfrm dev lo if_id 99 2>/dev/null; then
		if [ "${IKEV2_REQUIRE_XFRM:-0}" = 1 ]; then
			printf '%s\n' 'client SA binding: required XFRM interfaces unavailable' >&2
			exit 1
		fi
		printf '%s\n' 'client SA binding: skipped, this kernel has no XFRM interfaces'
		exit 0
	fi
	ip link del binding-probe
	exec sh /src/scripts/openwrt/client-access.sh
fi


if [ "${1:-}" = failover ] || [ "${1:-}" = client-ike ] || [ "${1:-}" = client-credentials ] || [ "${1:-}" = client-native ] || [ "${1:-}" = client-desktop ] || [ "${1:-}" = client-managed ]; then
	# strongSwan and the tools the tunnels use, as the dependency installer
	# lists them; kernel modules come from the host.
	packages="$(awk '/^runtime_packages\(\)/ { list = 1; next }
		list && /^EOF$/ { exit }
		list && /^(strongswan|swanmon$|openssl-util$|conntrack$)/' \
		/usr/libexec/ikev2-manager.d/system-deps.sh)"
	[ "${1:-}" != client-ike ] || packages="$packages strongswan-mod-des dnsmasq"
	[ "${1:-}" != client-native ] || packages="$packages strongswan-mod-des"
	[ "${1:-}" != client-desktop ] || packages="$packages strongswan-mod-des dnsmasq"
	[ "${1:-}" != client-managed ] || packages="$packages strongswan-mod-des"
	[ -n "$packages" ] || { printf '%s\n' 'openwrt: no strongSwan packages listed' >&2; exit 1; }
	# shellcheck disable=SC2086
	if command -v opkg >/dev/null 2>&1; then
		with_mirrors opkg install $packages >/dev/null
	else
		with_mirrors apk add $packages >/dev/null
	fi
	if [ "$1" = client-credentials ] || [ "$1" = client-native ] || [ "$1" = client-desktop ]; then
		if command -v opkg >/dev/null 2>&1; then
			with_mirrors opkg install uhttpd uhttpd-mod-ucode curl >/dev/null
		else
			with_mirrors apk add uhttpd uhttpd-mod-ucode curl >/dev/null
		fi
		[ "$1" != client-native ] || exec sh /src/scripts/openwrt/client-native.sh
		[ "$1" != client-desktop ] || exec sh /src/scripts/openwrt/client-desktop.sh
		exec sh /src/scripts/openwrt/client-credentials.sh
	fi
	if [ "$1" = client-managed ]; then
		if ! ip link add managed-probe type xfrm dev lo if_id 99 2>/dev/null; then
			[ "${IKEV2_REQUIRE_XFRM:-0}" != 1 ] || exit 1
			printf '%s\n' 'client-managed: skipped, this kernel has no XFRM interfaces'
			exit 0
		fi
		ip link del managed-probe
		exec sh /src/scripts/openwrt/client-managed.sh
	fi
	if [ "$1" = client-ike ]; then
		if ! ip link add auth-probe type xfrm dev lo if_id 99 2>/dev/null; then
			[ "${IKEV2_REQUIRE_XFRM:-0}" != 1 ] || exit 1
			printf '%s\n' 'client-ike: skipped, this kernel has no XFRM interfaces'
			exit 0
		fi
		ip link del auth-probe
		exec env CLIENT_ACCESS_TEST_PATH=1 CLIENT_ACCESS_RUNTIME_FIXTURE=/src/scripts/openwrt/client-runtime-state.uc sh /src/scripts/openwrt/client-ike.sh
	fi
	exec sh /src/scripts/openwrt/failover.sh
fi

# A command a scenario lacks prints "not found" and the shell carries on, so
# the step passes without testing what it names. That fails the run too.
rc=0
sh /src/scripts/openwrt/scenarios.sh 2>/tmp/scenarios.err || rc=$?
cat /tmp/scenarios.err >&2
[ "$rc" = 0 ] || exit "$rc"
if grep -q ': not found$' /tmp/scenarios.err; then
	printf '%s\n' 'openwrt: a scenario called a command that does not exist' >&2
	exit 1
fi
