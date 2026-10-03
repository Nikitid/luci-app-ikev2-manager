#!/bin/sh

set -eu

[ "$#" -eq 1 ] || {
	printf 'Usage: %s STAGING_DIRECTORY\n' "$0" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
stage="$1"

# Package identity comes from release.env (single source of truth; B3).
. "$root/release.env"

rm -rf "$stage"
mkdir -p "$stage/CONTROL"

install_file() {
	mode="$1"
	source="$2"
	target="$stage$3"
	mkdir -p "${target%/*}"
	install -m "$mode" "$root/$source" "$target"
}

install_file 600 openwrt/files/etc/config/ikev2-manager /etc/config/ikev2-manager
install_file 755 ikev2-manager-runtime/ikev2-xfrm.init /etc/init.d/ikev2-xfrm
install_file 755 ikev2-manager-runtime/ikev2-health.init /etc/init.d/ikev2-health
install_file 755 ikev2-manager-runtime/ikev2-user-policy.init /etc/init.d/ikev2-user-policy
install_file 755 ikev2-manager-runtime/ikev2-domain-router.init /etc/init.d/ikev2-domain-router
install_file 755 ikev2-manager-runtime/ikev2-dns-segments.init /etc/init.d/ikev2-dns-segments
install_file 755 ikev2-manager-runtime/90-ikev2-wan /etc/hotplug.d/iface/90-ikev2-manager
install_file 755 ikev2-manager-runtime/90-ikev2-acme /etc/hotplug.d/acme/90-ikev2-manager
install_file 600 ikev2-manager-runtime/strongswan-ikev2-manager.conf /etc/strongswan.d/ikev2-manager.conf
install_file 644 openwrt/files/etc/ikev2-manager/README /etc/ikev2-manager/README
mkdir -p "$stage/etc/ikev2-manager/services.d"
install_file 600 openwrt/files/etc/config/ikev2-manager /usr/share/ikev2-manager/defaults/ikev2-manager
install_file 600 openwrt/files/etc/pbr-ikev2-domains.manual.txt /etc/pbr-ikev2-domains.manual.txt
install_file 600 openwrt/files/etc/pbr-ikev2-addresses.manual.txt /etc/pbr-ikev2-addresses.manual.txt
install_file 644 openwrt/files/lib/upgrade/keep.d/ikev2-manager /lib/upgrade/keep.d/ikev2-manager

install_file 755 luci-ikev2-manager/ikev2-manager.sh /usr/libexec/ikev2-manager
install_file 755 luci-ikev2-manager/ikev2-profile.cgi /www/cgi-bin/ikev2-profile
install_file 755 ikev2-manager-runtime/ikev2-manager-system.sh /usr/libexec/ikev2-manager-system
install_file 644 ikev2-manager-runtime/lib/actions.sh /usr/libexec/ikev2-manager.d/actions.sh
install_file 644 ikev2-manager-runtime/lib/package-manager.sh /usr/libexec/ikev2-manager.d/package-manager.sh
install_file 644 ikev2-manager-runtime/lib/dependency-state.sh /usr/libexec/ikev2-manager.d/dependency-state.sh
install_file 644 ikev2-manager-runtime/lib/routing.sh /usr/libexec/ikev2-manager.d/routing.sh
install_file 644 ikev2-manager-runtime/lib/devices.sh /usr/libexec/ikev2-manager.d/devices.sh
install_file 644 ikev2-manager-runtime/lib/controller.sh /usr/libexec/ikev2-manager.d/controller.sh
install_file 644 ikev2-manager-runtime/lib/tunnel.sh /usr/libexec/ikev2-manager.d/tunnel.sh
install_file 644 ikev2-manager-runtime/lib/sa.uc /usr/libexec/ikev2-manager.d/sa.uc
install_file 644 ikev2-manager-runtime/lib/singbox-config.uc /usr/libexec/ikev2-manager.d/singbox-config.uc
install_file 644 ikev2-manager-runtime/lib/nft-state.uc /usr/libexec/ikev2-manager.d/nft-state.uc
install_file 644 ikev2-manager-runtime/lib/validate.sh /usr/libexec/ikev2-manager.d/validate.sh
install_file 644 ikev2-manager-runtime/lib/nft-runtime.sh /usr/libexec/ikev2-manager.d/nft-runtime.sh
install_file 644 ikev2-manager-runtime/lib/system-deps.sh /usr/libexec/ikev2-manager.d/system-deps.sh
install_file 644 ikev2-manager-runtime/lib/system-dns.sh /usr/libexec/ikev2-manager.d/system-dns.sh
install_file 644 ikev2-manager-runtime/lib/system-doctor.sh /usr/libexec/ikev2-manager.d/system-doctor.sh
install_file 644 ikev2-manager-runtime/lib/system-diagnostics.sh /usr/libexec/ikev2-manager.d/system-diagnostics.sh
install_file 644 ikev2-manager-runtime/lib/system-backup.sh /usr/libexec/ikev2-manager.d/system-backup.sh
install_file 644 ikev2-manager-runtime/lib/manager-users.sh /usr/libexec/ikev2-manager.d/manager-users.sh
install_file 644 ikev2-manager-runtime/lib/manager-server.sh /usr/libexec/ikev2-manager.d/manager-server.sh
install_file 644 ikev2-manager-runtime/lib/manager-acme.sh /usr/libexec/ikev2-manager.d/manager-acme.sh
install_file 644 ikev2-manager-runtime/lib/manager-profiles.sh /usr/libexec/ikev2-manager.d/manager-profiles.sh
install_file 644 ikev2-manager-runtime/lib/manager-tunnels.sh /usr/libexec/ikev2-manager.d/manager-tunnels.sh
install_file 755 ikev2-manager-runtime/ikev2-health.sh /usr/libexec/ikev2-health
install_file 755 ikev2-manager-runtime/ikev2-sync-vips.sh /usr/libexec/ikev2-sync-vips
install_file 755 ikev2-manager-runtime/ikev2-sa.sh /usr/libexec/ikev2-sa
install_file 755 ikev2-manager-runtime/ikev2-routing.sh /usr/libexec/ikev2-routing
install_file 755 ikev2-manager-runtime/ikev2-domain-router.sh /usr/libexec/ikev2-domain-router
install_file 755 ikev2-manager-runtime/ikev2-discord-voice.sh /usr/libexec/ikev2-discord-voice
install_file 755 ikev2-manager-runtime/ikev2-tunnel-quality.sh /usr/libexec/ikev2-tunnel-quality
install_file 755 ikev2-manager-runtime/ikev2-device-routing.sh /usr/libexec/ikev2-device-routing
install_file 755 ikev2-manager-runtime/ikev2-user-policy.sh /usr/libexec/ikev2-user-policy
install_file 755 luci-ikev2-domains/community-domains.sh /usr/libexec/ikev2-domains-community
install_file 755 luci-ikev2-domains/restart-pbr.sh /usr/libexec/ikev2-domains-restart
install_file 755 luci-ikev2-domains/ikev2-devices.sh /usr/libexec/ikev2-devices
install_file 755 ikev2-manager-runtime/pbr.user.ikev2out /usr/share/pbr/pbr.user.ikev2out

install_file 644 ikev2-manager-runtime/ca/isrg-root-x1.pem /usr/share/ikev2-manager/ca/isrg-root-x1.pem
install_file 644 ikev2-manager-runtime/ca/isrg-root-x2.pem /usr/share/ikev2-manager/ca/isrg-root-x2.pem
install_file 755 windows-profile-installer/bin/Nikitid-IKEv2-Setup.exe \
	/www/luci-static/resources/ikev2-manager/Nikitid-IKEv2-Setup.exe

install_file 644 LICENSE /usr/share/licenses/luci-app-ikev2-manager/LICENSE
install_file 644 NOTICE /usr/share/licenses/luci-app-ikev2-manager/NOTICE

install_file 644 luci-ikev2-domains/community-services.txt /usr/share/ikev2-domains/community-services
install_file 644 luci-ikev2-domains/public-suffixes.txt /usr/share/ikev2-domains/public-suffixes
for source in "$root"/luci-ikev2-domains/local-services/*.lst; do
	install_file 644 "${source#"$root/"}" "/usr/share/ikev2-domains/local-services/${source##*/}"
done
for source in "$root"/luci-ikev2-domains/local-services/*.cidrs; do
	install_file 644 "${source#"$root/"}" "/usr/share/ikev2-domains/local-services/${source##*/}"
done

install_file 644 luci-ikev2-manager/menu.json /usr/share/luci/menu.d/luci-app-ikev2-manager.json
install_file 644 luci-ikev2-manager/acl.json /usr/share/rpcd/acl.d/luci-app-ikev2-manager.json
mkdir -p "$stage/usr/lib/lua/luci/i18n"
python3 "$root/scripts/po2lmo.py" "$root/po/ru/ikev2-manager.po" \
	"$stage/usr/lib/lua/luci/i18n/ikev2-manager.ru.lmo"
chmod 644 "$stage/usr/lib/lua/luci/i18n/ikev2-manager.ru.lmo"
install_file 644 luci-ikev2-manager/shared.js /www/luci-static/resources/ikev2-manager/shared-v14.js
install_file 644 luci-ikev2-manager/status-widget.js \
	/www/luci-static/resources/view/status/include/06_ikev2-manager.js
# LuCI asks for a view resource with its own version in the query string, which
# does not move when this package is upgraded. A resource whose name never
# changes is therefore served from the browser cache across an upgrade, which is
# what the -vN suffixes are for.
install_file 644 luci-ikev2-manager/settings.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v10.js
install_file 644 luci-ikev2-manager/client.js \
	/www/luci-static/resources/view/ikev2-manager/client-v11.js
install_file 644 luci-ikev2-manager/setup.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v12.js
install_file 644 luci-ikev2-manager/users.js \
	/www/luci-static/resources/view/ikev2-manager/users-v15.js
install_file 644 luci-ikev2-domains/editor.js /www/luci-static/resources/view/ikev2-domains/editor-v12.js

# The pages show which build is installed. Stamping it here keeps status cheap:
# no package-manager query on every poll.
mkdir -p "$stage/usr/share/ikev2-manager"
printf '%s\n' "$PKG_VERSION" >"$stage/usr/share/ikev2-manager/version"
chmod 644 "$stage/usr/share/ikev2-manager/version"

install -m 600 /dev/null "$stage/etc/pbr-ikev2-domains.txt"
install -m 600 /dev/null "$stage/etc/pbr-ikev2-community-selected.txt"

# Canonical release control file (built by scripts/build-ipk.sh via pack-ipk.py).
# Package name and Version come from release.env (single source of truth; B3);
# field order is preserved so the artifact stays byte-stable across rebuilds.
# scripts/check-version-sync.sh asserts the SDK Makefile literals still match
# (including Architecture, kept literal below as it is invariant for this pkg).
# Filesystem block allocation differs between macOS and Linux, so `du -sk`
# makes otherwise identical packages produce different control archives.
# Installed-Size is the rounded sum of payload file bytes instead.
installed_size="$(python3 - "$stage" <<'PY'
import os
import sys

total = 0
for directory, directories, files in os.walk(sys.argv[1]):
    directories[:] = [name for name in directories if name != "CONTROL"]
    for name in files:
        total += os.lstat(os.path.join(directory, name)).st_size
print((total + 1023) // 1024)
PY
)"
{
	printf 'Package: %s\n' "$PKG_NAME"
	if [ -n "$PKG_RELEASE" ]; then
		printf 'Version: %s-r%s\n' "$PKG_VERSION" "$PKG_RELEASE"
	else
		printf 'Version: %s\n' "$PKG_VERSION"
	fi
	cat <<'EOF'
Depends: luci-base, rpcd-mod-file, jsonfilter, socat, ucode, ucode-mod-fs
Section: luci
Architecture: all
Maintainer: nikitid
Homepage: https://github.com/nikitid/ikev2-openwrt
Source: https://github.com/nikitid/ikev2-openwrt
EOF
	printf 'Installed-Size: %s\n' "$installed_size"
	cat <<'EOF'
Description: IKEv2 Manager for OpenWrt
 LuCI application and runtime for an IPv4 IKEv2 client, an optional
 road-warrior IKEv2 server, domain-based policy routing, device overrides
 and fail-closed routing on OpenWrt 24.10 and 25.12.
EOF
} >"$stage/CONTROL/control"

cat >"$stage/CONTROL/conffiles" <<'EOF'
/etc/config/ikev2-manager
/etc/pbr-ikev2-domains.txt
/etc/pbr-ikev2-domains.manual.txt
/etc/pbr-ikev2-addresses.manual.txt
/etc/pbr-ikev2-community-selected.txt
EOF

install -m 755 "$root/scripts/package-preinst.sh" "$stage/CONTROL/preinst"

cat >"$stage/CONTROL/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
# Refresh rpcd's ACL registry without restarting the daemon or invalidating
# active LuCI sessions. New file/exec permissions otherwise remain unavailable
# until rpcd is reloaded manually or the router is rebooted.
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
# Every -vN rename leaves the superseded resource behind. Only names this
# package no longer ships are removed, so nothing else in these directories is
# touched. The list matches the SDK Makefile's postinst.
rm -f /www/luci-static/resources/ikev2-manager/shared.js \
	/www/luci-static/resources/ikev2-manager/shared-v2.js \
	/www/luci-static/resources/ikev2-manager/shared-v3.js \
	/www/luci-static/resources/ikev2-manager/shared-v4.js \
	/www/luci-static/resources/ikev2-manager/shared-v5.js \
	/www/luci-static/resources/ikev2-manager/shared-v6.js \
	/www/luci-static/resources/ikev2-manager/shared-v7.js \
	/www/luci-static/resources/view/ikev2-manager/client.js \
	/www/luci-static/resources/view/ikev2-manager/settings.js \
	/www/luci-static/resources/view/ikev2-manager/setup.js \
	/www/luci-static/resources/view/ikev2-manager/users-v2.js \
	/www/luci-static/resources/view/ikev2-manager/users-v3.js \
	/www/luci-static/resources/view/ikev2-manager/users-v4.js \
	/www/luci-static/resources/view/ikev2-manager/users-v5.js \
	/www/luci-static/resources/view/ikev2-manager/users-v6.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v2.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v2.js \
	/www/luci-static/resources/view/ikev2-manager/client-v2.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v3.js \
	/www/luci-static/resources/view/ikev2-manager/users-v7.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v3.js \
	/www/luci-static/resources/view/ikev2-manager/client-v3.js \
	/www/luci-static/resources/view/ikev2-domains/editor.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v2.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v3.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v4.js \
	/www/luci-static/resources/ikev2-manager/shared-v8.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v4.js \
	/www/luci-static/resources/view/ikev2-manager/users-v8.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v4.js \
	/www/luci-static/resources/view/ikev2-manager/client-v4.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v5.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v5.js \
	/www/luci-static/resources/view/ikev2-manager/client-v5.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v6.js \
	/www/luci-static/resources/ikev2-manager/shared-v9.js \
	/www/luci-static/resources/view/ikev2-manager/users-v9.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v5.js \
	/www/luci-static/resources/ikev2-manager/shared-v10.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v6.js \
	/www/luci-static/resources/view/ikev2-manager/client-v6.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v6.js \
	/www/luci-static/resources/view/ikev2-manager/users-v10.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v7.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v7.js \
	/www/luci-static/resources/view/ikev2-manager/users-v11.js \
	/www/luci-static/resources/view/ikev2-manager/client-v7.js \
	/www/luci-static/resources/view/ikev2-manager/client-v8.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v8.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v9.js \
	/www/luci-static/resources/ikev2-manager/shared-v11.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v8.js \
	/www/luci-static/resources/view/ikev2-manager/users-v12.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v7.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v9.js \
	/www/luci-static/resources/ikev2-manager/shared-v12.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v10.js \
	/www/luci-static/resources/view/ikev2-manager/users-v13.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v8.js \
	/www/luci-static/resources/view/ikev2-manager/client-v9.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v10.js \
	/www/luci-static/resources/ikev2-manager/shared-v13.js \
	/www/luci-static/resources/view/ikev2-manager/setup-v11.js \
	/www/luci-static/resources/view/ikev2-manager/users-v14.js \
	/www/luci-static/resources/view/ikev2-manager/settings-v9.js \
	/www/luci-static/resources/view/ikev2-manager/client-v10.js \
	/www/luci-static/resources/view/ikev2-domains/editor-v11.js
# Releases before 1.13 shipped the charon settings under strongswan.d/charon/,
# which strongswan.conf includes inside charon.plugins, so none of them applied.
rm -f /etc/strongswan.d/charon/20-ikev2-manager.conf
# The feed moved out of this repository into Nikitid/openwrt-feed, so that
# renaming or retiring this application no longer moves a URL recorded in
# /etc/apk/repositories.d on every router. Move an installation that still holds
# one of this project's own previous URLs; a list pointing anywhere else, and a
# shared list that already exists, are left alone. Trusted keys are not touched:
# the material is identical under either file name.
# feed-migration begin
ikev2_feed_dir="${IKEV2_FEED_DIR:-/etc/apk/repositories.d}"
ikev2_feed_old="$ikev2_feed_dir/ikev2-manager.list"
ikev2_feed_new="$ikev2_feed_dir/nikitid-openwrt.list"
ikev2_feed_url=https://raw.githubusercontent.com/Nikitid/openwrt-feed/feed/packages.adb
ikev2_feed_stale=0
if [ -f "$ikev2_feed_old" ]; then
	case "$(cat "$ikev2_feed_old")" in
		https://raw.githubusercontent.com/Nikitid/ikev2-manager-openwrt/apk-feed/packages.adb) ikev2_feed_stale=1 ;;
		https://raw.githubusercontent.com/Nikitid/ikev2-openwrt/apk-feed/packages.adb) ikev2_feed_stale=1 ;;
	esac
fi
if [ "$ikev2_feed_stale" = 1 ] && [ -e "$ikev2_feed_new" ]; then
	rm -f "$ikev2_feed_old"
	echo "Retired the previous per-application APK feed list."
elif [ "$ikev2_feed_stale" = 1 ]; then
	if printf '%s\n' "$ikev2_feed_url" >"$ikev2_feed_new.tmp" && chmod 0644 "$ikev2_feed_new.tmp" && mv "$ikev2_feed_new.tmp" "$ikev2_feed_new"; then
		rm -f "$ikev2_feed_old"
		echo "APK feed migrated to the shared Nikitid OpenWrt feed."
	else
		rm -f "$ikev2_feed_new.tmp"
		echo "Unable to migrate the APK feed; re-run the shared feed installer." >&2
	fi
fi
# feed-migration end
# runtime-reconcile begin
# Install newly introduced owned nftables rules without restarting the network,
# PBR, strongSwan, dnsmasq or fw4. The helper removes obsolete generated UCI
# DNS/DoT sections only after the replacement runtime validates and loads.
if [ "$(uci -q get ikev2-manager.globals.configured)" = 1 ]; then
	if /usr/libexec/ikev2-manager-system _upgrade-reconcile >/dev/null 2>&1 &&
	   /usr/libexec/ikev2-manager _upgrade-server-profile >/dev/null 2>&1; then
		echo "Reconciled the active IKEv2 runtime and generated server profile."
	else
		echo "Could not reconcile the active IKEv2 policy; open LuCI and apply the configuration." >&2
	fi
fi
# runtime-reconcile end
# health-restart begin
# The watcher is a shell script, and the running instance keeps executing the
# copy it already read: after an upgrade it goes on behaving like the previous
# version until something restarts it. Upgrading 1.1.x to 1.2.x that way left
# the inbound user policy never created at all, because the old watcher has no
# such step. Restart it only when it was already running, so an installation
# that deliberately keeps the runtime stopped is not started here.
ikev2_health_init="${IKEV2_HEALTH_INIT:-/etc/init.d/ikev2-health}"
ikev2_health_running=0
ikev2_health_enabled=0
ikev2_health_start_link=0
ikev2_health_stop_link=0
ikev2_rc_dir="${IKEV2_RC_DIR:-/etc/rc.d}"
if [ -x "$ikev2_health_init" ]; then
	"$ikev2_health_init" running >/dev/null 2>&1 && ikev2_health_running=1
	for ikev2_rc_link in "$ikev2_rc_dir"/S*ikev2-health; do
		[ -L "$ikev2_rc_link" ] && ikev2_health_start_link=1
	done
	for ikev2_rc_link in "$ikev2_rc_dir"/K*ikev2-health; do
		[ -L "$ikev2_rc_link" ] && ikev2_health_stop_link=1
	done
	if [ "$ikev2_health_start_link" = 1 ] && [ "$ikev2_health_stop_link" = 1 ]; then
		ikev2_health_enabled=1
	fi
	# Refresh the links because rc.common does not remove an older K-number
	# when STOP changes during an upgrade.
	if [ "$ikev2_health_enabled" = 1 ]; then
		if "$ikev2_health_init" disable >/dev/null 2>&1 &&
		   "$ikev2_health_init" enable >/dev/null 2>&1; then
			echo "Updated the health watcher shutdown order."
		else
			echo "Could not refresh the health watcher rc links; run '$ikev2_health_init disable && $ikev2_health_init enable'." >&2
		fi
	fi
fi
if [ "$ikev2_health_running" = 1 ]; then
	if "$ikev2_health_init" restart >/dev/null 2>&1; then
		echo "Restarted the health watcher so it runs the installed version."
	else
		echo "Could not restart the health watcher; run '$ikev2_health_init restart'." >&2
	fi
fi
# health-restart end
# inbound-policy-watcher begin
# Keep inbound admission independent from the slower general health loop. A
# HUP makes an existing watcher exec the newly installed script without
# removing its fail-closed nftables table or interrupting active clients.
ikev2_policy_init="${IKEV2_USER_POLICY_INIT:-/etc/init.d/ikev2-user-policy}"
ikev2_policy_active=0
if [ "$(uci -q get ikev2-manager.globals.configured)" = 1 ] && \
   [ "$(uci -q get ikev2-manager.server.enabled)" = 1 ] && \
   [ "$(uci -q get ikev2-manager.server.custom_config)" != 1 ]; then
	ikev2_policy_active=1
fi
if [ "$ikev2_policy_active" = 1 ] && [ -x "$ikev2_policy_init" ]; then
	"$ikev2_policy_init" disable >/dev/null 2>&1 || true
	"$ikev2_policy_init" enable >/dev/null 2>&1 || true
	if "$ikev2_policy_init" running >/dev/null 2>&1; then
		"$ikev2_policy_init" reload >/dev/null 2>&1 || \
			echo "Could not reload the inbound policy watcher." >&2
	else
		"$ikev2_policy_init" start >/dev/null 2>&1 || \
			echo "Could not start the inbound policy watcher." >&2
	fi
elif [ -x "$ikev2_policy_init" ]; then
	"$ikev2_policy_init" running >/dev/null 2>&1 && \
		"$ikev2_policy_init" stop >/dev/null 2>&1 || true
	"$ikev2_policy_init" disable >/dev/null 2>&1 || true
fi
# inbound-policy-watcher end
if [ "$(uci -q get ikev2-manager.globals.configured)" = 1 ] || \
   [ "$(uci -q get ikev2-manager.client.enabled)" = 1 ] || \
   [ "$(uci -q get ikev2-manager.server.enabled)" = 1 ]; then
	echo "Existing configuration detected; runtime was not started automatically."
fi
echo "IKEv2 Manager for OpenWrt installed."
echo "Open LuCI -> Services -> IKEv2 Manager."
exit 0
EOF

install -m 755 "$root/scripts/package-prerm.sh" "$stage/CONTROL/prerm"

chmod 755 "$stage/CONTROL/preinst" "$stage/CONTROL/postinst" "$stage/CONTROL/prerm"
