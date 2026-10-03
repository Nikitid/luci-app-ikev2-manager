#!/bin/sh
# Installs the package built by scripts/build-ipk.sh into a fresh OpenWrt rootfs
# container, the way a router gets it, then runs the scenarios - or, with the
# argument "failover", strongSwan as well and the two-tunnel test. /src is the
# repository, mounted read-only.

set -eu

mkdir -p /var/lock /var/run /tmp/run
ipk="$(ls /src/dist/*.ipk)"

if command -v opkg >/dev/null 2>&1; then
	# 24.10: the real package manager, maintainer scripts included. Only the
	# tools the runtime calls are installed; LuCI itself is not needed here.
	opkg update >/dev/null
	opkg install ip-full ucode-mod-fs socat sing-box openssl-util >/dev/null
	opkg install --force-depends "$ipk" >/tmp/install.log 2>&1 || {
		cat /tmp/install.log >&2
		exit 1
	}
else
	# 25.12 installs the SDK-built APK, which needs the release signing key;
	# the IPK carries the same files, unpacked here without its scripts.
	apk update >/dev/null
	apk add ip-full ucode-mod-fs socat sing-box openssl-util >/dev/null
	mkdir -p /tmp/ipk
	tar -xzf "$ipk" -C /tmp/ipk
	tar -xzf /tmp/ipk/data.tar.gz -C /
fi

if [ "${1:-}" = failover ]; then
	# strongSwan and the tools the tunnels use, as the dependency installer
	# lists them; kernel modules come from the host.
	packages="$(awk '/^runtime_packages\(\)/ { list = 1; next }
		list && /^EOF$/ { exit }
		list && /^(strongswan|swanmon$|openssl-util$|conntrack$)/' \
		/usr/libexec/ikev2-manager.d/system-deps.sh)"
	[ -n "$packages" ] || { printf '%s\n' 'openwrt: no strongSwan packages listed' >&2; exit 1; }
	# shellcheck disable=SC2086
	if command -v opkg >/dev/null 2>&1; then
		opkg install $packages >/dev/null
	else
		apk add $packages >/dev/null
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
