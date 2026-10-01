#!/bin/sh

# A check that refused every version it did not know also refused ones that
# worked (podkop rejected sing-box 1.13.18 for being newer than 1.12.4). What
# must hold is a floor: older OpenWrt releases stay refused, newer ones install
# and report a warning, and a newer PBR is judged by what it does.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

. "$root/ikev2-manager-runtime/lib/package-manager.sh"
expect_support() {
	[ "$(openwrt_release_support "$1" "$2")" = "$3" ] ||
		fail "OpenWrt $1 with $2 was not $3: $(openwrt_release_support "$1" "$2")"
}
expect_support 24.10.4 opkg supported
expect_support 25.12.5 apk supported
expect_support 26.03.0 apk newer
expect_support 27.01.1 apk newer
expect_support 26.03.0 opkg unsupported
expect_support 25.12.5 opkg unsupported
expect_support 23.05.5 opkg unsupported
expect_support 24.10.4 apk unsupported
expect_support SNAPSHOT apk unsupported

# The feed check follows the release series instead of two fixed patterns.
pkg_manager_name() { printf 'apk\n'; }
pkg_feed_file_matches() { printf '%s\n' "$1" >"$tmp/pattern"; }
pkg_release_feed_ok 26.03.1
printf '%s\n' 'https://downloads.openwrt.org/releases/26.03.1/targets/x/packages.adb' |
	grep -Eq "$(cat "$tmp/pattern")" || fail 'a 26.03 release feed was not recognised'
printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.5/targets/x/packages.adb' |
	grep -Eq "$(cat "$tmp/pattern")" && fail 'another release series passed the 26.03 feed check'

# Both copies of the package preinst: the standalone script and the SDK one.
mkdir -p "$tmp/bin"
for command in apk opkg uci ubus fw4; do
	printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/$command"
	chmod +x "$tmp/bin/$command"
done
sed -n '/^define Package\/luci-app-ikev2-manager\/preinst$/,/^endef$/p' "$root/Makefile" |
	sed '1d;$d' | sed 's/\$\$/$/g' >"$tmp/preinst-sdk.sh"
cp "$root/scripts/package-preinst.sh" "$tmp/preinst-script.sh"
run_preinst() {
	local copy="$1" release="$2" feed="$3"
	printf "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='%s'\n" "$release" >"$tmp/openwrt_release"
	printf '%s\n' "$feed" >"$tmp/repositories"
	: >"$tmp/distfeeds.conf"
	sed -e "s|/etc/openwrt_release|$tmp/openwrt_release|g" \
		-e "s|/etc/apk/repositories.d/\*|$tmp/none|g" \
		-e "s|/etc/apk/repositories|$tmp/repositories|g" \
		-e "s|/etc/opkg/distfeeds.conf|$tmp/distfeeds.conf|g" \
		"$tmp/$copy" >"$tmp/run.sh"
	PATH="$tmp/bin:$PATH" sh "$tmp/run.sh" >"$tmp/out" 2>&1
}
for copy in preinst-script.sh preinst-sdk.sh; do
	run_preinst "$copy" 25.12.5 'https://downloads.openwrt.org/releases/25.12.5/packages/x' ||
		fail "$copy refused a supported release: $(cat "$tmp/out")"
	run_preinst "$copy" 26.03.0 'https://downloads.openwrt.org/releases/26.03.0/packages/x' ||
		fail "$copy refused a newer release: $(cat "$tmp/out")"
	grep -q 'newer than the releases this version was tested on' "$tmp/out" ||
		fail "$copy installed a newer release without a warning"
	run_preinst "$copy" 26.03.0 'https://example.net/snapshots/packages.adb' &&
		fail "$copy accepted a newer release without its official feed"
	run_preinst "$copy" 23.05.5 'https://downloads.openwrt.org/releases/23.05.5/packages/x' &&
		fail "$copy accepted an older release"
done

# A known inbound vulnerability without a fixed package in the feed is a
# warning, never a failed report; its text says whether a fix can be installed.
cat >"$tmp/bin/apk" <<'STUB'
#!/bin/sh
case "$1" in
	policy) printf 'strongswan policy:\n  6.0.3-r1:\n    lib/apk/db/installed\n  6.0.8-r1:\n    https://feed/packages.adb\n  6.0.3-r2:\n    https://feed/packages.adb\n' ;;
	version)
		[ "$3" = "$4" ] && { echo '='; exit 0; }
		first="$(printf '%s\n%s\n' "$3" "$4" | sort -V | head -n1)"
		[ "$first" = "$3" ] && echo '<' || echo '>'
		;;
esac
STUB
chmod +x "$tmp/bin/apk"
IKEV2_PACKAGE_MANAGER=apk PATH="$tmp/bin:$PATH" sh -c '
	. "$1/ikev2-manager-runtime/lib/package-manager.sh"
	[ "$(pkg_available_version strongswan)" = 6.0.8-r1 ] || exit 11
	pkg_version_string_at_least 6.0.8-r1 6.0.7 || exit 12
	pkg_version_string_at_least 6.0.3-r2 6.0.7 && exit 13
	exit 0' sh "$root" || fail "the feed version lookup failed"
security_block="$(sed -n '/strongswan_eap_server_security=ok/,/^	fi$/p' "$root/ikev2-manager-runtime/lib/system-doctor.sh")"
printf '%s\n' "$security_block" | grep -Eq '(^|[^_a-z])ok=0' &&
	fail 'a known vulnerability without a feed fix still fails the whole report'
printf '%s\n' "$security_block" | grep -q 'awaiting-feed' ||
	fail 'the missing feed fix is not reported'
grep -q "waiting for a fixed package in the feed" "$root/luci-ikev2-manager/setup.js" ||
	fail 'the overview does not explain the vulnerability warning'

printf '%s\n' 'version policy tests OK'
