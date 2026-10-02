#!/bin/sh
# Installs the package built by scripts/build-ipk.sh into a fresh OpenWrt rootfs
# container, the way a router gets it, then runs the scenarios. /src is the
# repository, mounted read-only.

set -eu

mkdir -p /var/lock /var/run /tmp/run
ipk="$(ls /src/dist/*.ipk)"

if command -v opkg >/dev/null 2>&1; then
	# 24.10: the real package manager, maintainer scripts included. Only the
	# tools the runtime calls are installed; LuCI itself is not needed here.
	opkg update >/dev/null
	opkg install ip-full ucode-mod-fs socat >/dev/null
	opkg install --force-depends "$ipk" >/tmp/install.log 2>&1 || {
		cat /tmp/install.log >&2
		exit 1
	}
else
	# 25.12 installs the SDK-built APK, which needs the release signing key;
	# the IPK carries the same files, unpacked here without its scripts.
	apk update >/dev/null
	apk add ip-full ucode-mod-fs socat >/dev/null
	mkdir -p /tmp/ipk
	tar -xzf "$ipk" -C /tmp/ipk
	tar -xzf /tmp/ipk/data.tar.gz -C /
fi

exec sh /src/scripts/openwrt/scenarios.sh
