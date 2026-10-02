include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ikev2-manager
# Source of truth for package identity is ../release.env, consumed by the
# canonical build (scripts/build-ipk.sh). These SDK literals are kept in sync
# manually because OpenWrt's relative include path is unreliable;
# scripts/check-version-sync.sh fails the canonical build if they drift (B3).
PKG_VERSION:=2.0.0
PKG_RELEASE:=
PKG_LICENSE:=MIT
PKG_MAINTAINER:=nikitid
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-ikev2-manager
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=IKEv2 Manager for OpenWrt
  URL:=https://github.com/nikitid/ikev2-openwrt
  DEPENDS:= \
	+luci-base \
	+rpcd-mod-file \
	+jsonfilter \
	+ucode \
	+ucode-mod-fs \
	+socat
endef

define Package/luci-app-ikev2-manager/description
 LuCI application and runtime for an IPv4 IKEv2 client, an optional
 road-warrior IKEv2 server, domain-based policy routing, device overrides and
 fail-closed routing on OpenWrt 24.10 and 25.12.
endef

define Package/luci-app-ikev2-manager/conffiles
/etc/config/ikev2-manager
/etc/pbr-ikev2-domains.txt
/etc/pbr-ikev2-domains.manual.txt
/etc/pbr-ikev2-addresses.manual.txt
/etc/pbr-ikev2-community-selected.txt
endef

define Build/Compile
endef

define Package/luci-app-ikev2-manager/preinst
#!/bin/sh
set -eu
fail() {
	echo "IKEv2 Manager for OpenWrt: $$*" >&2
	exit 1
}
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
[ -r /etc/openwrt_release ] || fail "OpenWrt is required"
. /etc/openwrt_release
[ "$${DISTRIB_ID:-}" = OpenWrt ] ||
	fail "official OpenWrt is required; found $${DISTRIB_ID:-unknown vendor firmware}"
# A release newer than 25.12 installs with a warning: what must hold is a
# floor, and refusing every unknown version also refused ones that work.
series_major="$${DISTRIB_RELEASE%%.*}"
series_rest="$${DISTRIB_RELEASE#*.}"
series_minor="$${series_rest%%.*}"
case "$${DISTRIB_RELEASE:-}" in
	24.10.*) package_manager=opkg ;;
	25.12.*) package_manager=apk ;;
	*)
		case "$$series_major:$$series_minor" in
			*[!0-9:]* | :* | *:) series_major=0; series_minor=0 ;;
		esac
		if [ "$$series_major" -gt 25 ] || { [ "$$series_major" -eq 25 ] && [ "$$series_minor" -gt 12 ]; }; then
			package_manager=apk
			printf '%s\n' "IKEv2 Manager for OpenWrt: OpenWrt $${DISTRIB_RELEASE} is newer than the releases this version was tested on" >&2
		else
			fail "OpenWrt 24.10.x, or 25.12.x or newer, is required; found $${DISTRIB_RELEASE:-unknown}"
		fi
		;;
esac
for command in "$$package_manager" uci ubus fw4; do
	command -v "$$command" >/dev/null 2>&1 ||
		fail "required base command is missing: $$command"
done
feed_file_matches() {
	pattern="$$1"
	shift
	for file in "$$@"; do
		[ -r "$$file" ] || continue
		grep -qE "$$pattern" "$$file" && return 0
	done
	return 1
}
case "$$package_manager:$${DISTRIB_RELEASE:-}" in
	opkg:24.10.*)
		feed_file_matches 'downloads\.openwrt\.org/releases/24\.10\.' \
			/etc/opkg/distfeeds.conf ||
			fail "official OpenWrt 24.10 release package feeds are required"
		;;
	apk:*)
		feed_file_matches \
			"downloads\\.openwrt\\.org/releases/($$series_major\\.$$series_minor\\.|packages-$$series_major\\.$$series_minor)" \
			/etc/apk/repositories /etc/apk/repositories.d/* ||
			fail "official OpenWrt $$series_major.$$series_minor release package feeds are required"
		;;
	*)
		fail "unsupported package manager $$package_manager for OpenWrt $${DISTRIB_RELEASE:-unknown}"
		;;
esac
	free_kib="$$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 { print $$4 }')"
[ -n "$$free_kib" ] || free_kib="$$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $$4 }')"
case "$${free_kib:-0}" in *[!0-9]*) free_kib=0 ;; esac
[ "$$free_kib" -ge 1024 ] ||
	fail "insufficient persistent storage to install the bootstrap package ($$free_kib KiB free)"
exit 0
endef

define Package/luci-app-ikev2-manager/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./openwrt/files/etc/config/ikev2-manager $(1)/etc/config/ikev2-manager

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-xfrm.init $(1)/etc/init.d/ikev2-xfrm
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-health.init $(1)/etc/init.d/ikev2-health
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-user-policy.init $(1)/etc/init.d/ikev2-user-policy
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-domain-router.init $(1)/etc/init.d/ikev2-domain-router
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-dns-segments.init $(1)/etc/init.d/ikev2-dns-segments

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface $(1)/etc/hotplug.d/acme
	$(INSTALL_BIN) ./ikev2-manager-runtime/90-ikev2-wan $(1)/etc/hotplug.d/iface/90-ikev2-manager
	$(INSTALL_BIN) ./ikev2-manager-runtime/90-ikev2-acme $(1)/etc/hotplug.d/acme/90-ikev2-manager

	$(INSTALL_DIR) $(1)/etc/strongswan.d
	$(INSTALL_CONF) ./ikev2-manager-runtime/strongswan-ikev2-manager.conf $(1)/etc/strongswan.d/ikev2-manager.conf

	$(INSTALL_DIR) $(1)/etc/ikev2-manager $(1)/etc/ikev2-manager/services.d
	$(INSTALL_DATA) ./openwrt/files/etc/ikev2-manager/README $(1)/etc/ikev2-manager/README
	$(INSTALL_DIR) $(1)/usr/share/ikev2-manager/defaults
	$(INSTALL_CONF) ./openwrt/files/etc/config/ikev2-manager $(1)/usr/share/ikev2-manager/defaults/ikev2-manager
	$(INSTALL_CONF) ./openwrt/files/etc/pbr-ikev2-domains.manual.txt $(1)/etc/pbr-ikev2-domains.manual.txt
	$(INSTALL_CONF) ./openwrt/files/etc/pbr-ikev2-addresses.manual.txt $(1)/etc/pbr-ikev2-addresses.manual.txt
	touch $(1)/etc/pbr-ikev2-domains.txt
	touch $(1)/etc/pbr-ikev2-community-selected.txt
	chmod 600 $(1)/etc/pbr-ikev2-domains.txt
	chmod 600 $(1)/etc/pbr-ikev2-community-selected.txt

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./openwrt/files/lib/upgrade/keep.d/ikev2-manager $(1)/lib/upgrade/keep.d/ikev2-manager

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./luci-ikev2-manager/ikev2-manager.sh $(1)/usr/libexec/ikev2-manager
	$(INSTALL_DIR) $(1)/www/cgi-bin
	$(INSTALL_BIN) ./luci-ikev2-manager/ikev2-profile.cgi $(1)/www/cgi-bin/ikev2-profile
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-manager-system.sh $(1)/usr/libexec/ikev2-manager-system
	$(INSTALL_DIR) $(1)/usr/libexec/ikev2-manager.d
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/actions.sh $(1)/usr/libexec/ikev2-manager.d/actions.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/package-manager.sh $(1)/usr/libexec/ikev2-manager.d/package-manager.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/dependency-state.sh $(1)/usr/libexec/ikev2-manager.d/dependency-state.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/routing.sh $(1)/usr/libexec/ikev2-manager.d/routing.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/devices.sh $(1)/usr/libexec/ikev2-manager.d/devices.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/controller.sh $(1)/usr/libexec/ikev2-manager.d/controller.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/tunnel.sh $(1)/usr/libexec/ikev2-manager.d/tunnel.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/sa.uc $(1)/usr/libexec/ikev2-manager.d/sa.uc
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/singbox-config.uc $(1)/usr/libexec/ikev2-manager.d/singbox-config.uc
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/nft-state.uc $(1)/usr/libexec/ikev2-manager.d/nft-state.uc
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/validate.sh $(1)/usr/libexec/ikev2-manager.d/validate.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/nft-runtime.sh $(1)/usr/libexec/ikev2-manager.d/nft-runtime.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/system-deps.sh $(1)/usr/libexec/ikev2-manager.d/system-deps.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/system-dns.sh $(1)/usr/libexec/ikev2-manager.d/system-dns.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/system-doctor.sh $(1)/usr/libexec/ikev2-manager.d/system-doctor.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/system-diagnostics.sh $(1)/usr/libexec/ikev2-manager.d/system-diagnostics.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/system-backup.sh $(1)/usr/libexec/ikev2-manager.d/system-backup.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/manager-users.sh $(1)/usr/libexec/ikev2-manager.d/manager-users.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/manager-server.sh $(1)/usr/libexec/ikev2-manager.d/manager-server.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/manager-acme.sh $(1)/usr/libexec/ikev2-manager.d/manager-acme.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/manager-profiles.sh $(1)/usr/libexec/ikev2-manager.d/manager-profiles.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/manager-tunnels.sh $(1)/usr/libexec/ikev2-manager.d/manager-tunnels.sh
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-health.sh $(1)/usr/libexec/ikev2-health
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-sync-vips.sh $(1)/usr/libexec/ikev2-sync-vips
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-sa.sh $(1)/usr/libexec/ikev2-sa
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-routing.sh $(1)/usr/libexec/ikev2-routing
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-domain-router.sh $(1)/usr/libexec/ikev2-domain-router
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-discord-voice.sh $(1)/usr/libexec/ikev2-discord-voice
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-tunnel-quality.sh $(1)/usr/libexec/ikev2-tunnel-quality
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-device-routing.sh $(1)/usr/libexec/ikev2-device-routing
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-user-policy.sh $(1)/usr/libexec/ikev2-user-policy
	$(INSTALL_BIN) ./luci-ikev2-domains/community-domains.sh $(1)/usr/libexec/ikev2-domains-community
	$(INSTALL_BIN) ./luci-ikev2-domains/restart-pbr.sh $(1)/usr/libexec/ikev2-domains-restart
	$(INSTALL_BIN) ./luci-ikev2-domains/ikev2-devices.sh $(1)/usr/libexec/ikev2-devices

	$(INSTALL_DIR) $(1)/usr/share/pbr
	$(INSTALL_BIN) ./ikev2-manager-runtime/pbr.user.ikev2out $(1)/usr/share/pbr/pbr.user.ikev2out

	$(INSTALL_DIR) $(1)/usr/share/ikev2-manager
	echo "$(PKG_VERSION)" >$(1)/usr/share/ikev2-manager/version
	chmod 644 $(1)/usr/share/ikev2-manager/version
	$(INSTALL_DIR) $(1)/usr/share/ikev2-manager/ca
	$(INSTALL_DATA) ./ikev2-manager-runtime/ca/isrg-root-x1.pem $(1)/usr/share/ikev2-manager/ca/isrg-root-x1.pem
	$(INSTALL_DATA) ./ikev2-manager-runtime/ca/isrg-root-x2.pem $(1)/usr/share/ikev2-manager/ca/isrg-root-x2.pem

	$(INSTALL_DIR) $(1)/usr/share/licenses/luci-app-ikev2-manager
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/luci-app-ikev2-manager/LICENSE
	$(INSTALL_DATA) ./NOTICE $(1)/usr/share/licenses/luci-app-ikev2-manager/NOTICE

	$(INSTALL_DIR) $(1)/usr/share/ikev2-domains/local-services
	$(INSTALL_DATA) ./luci-ikev2-domains/community-services.txt $(1)/usr/share/ikev2-domains/community-services
	$(INSTALL_DATA) ./luci-ikev2-domains/public-suffixes.txt $(1)/usr/share/ikev2-domains/public-suffixes
	$(INSTALL_DATA) ./luci-ikev2-domains/local-services/*.lst $(1)/usr/share/ikev2-domains/local-services/
	$(INSTALL_DATA) ./luci-ikev2-domains/local-services/*.cidrs $(1)/usr/share/ikev2-domains/local-services/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./luci-ikev2-manager/menu.json $(1)/usr/share/luci/menu.d/luci-app-ikev2-manager.json
	$(INSTALL_DATA) ./luci-ikev2-manager/acl.json $(1)/usr/share/rpcd/acl.d/luci-app-ikev2-manager.json

	# LuCI serves translations from compiled catalogs; po2lmo.py matches its own
	# compiler without needing the LuCI feed in the SDK.
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	python3 ./scripts/po2lmo.py ./po/ru/ikev2-manager.po $(1)/usr/lib/lua/luci/i18n/ikev2-manager.ru.lmo

	$(INSTALL_DIR) $(1)/www/luci-static/resources/ikev2-manager
	$(INSTALL_DATA) ./luci-ikev2-manager/shared.js $(1)/www/luci-static/resources/ikev2-manager/shared-v12.js
	$(INSTALL_BIN) ./windows-profile-installer/bin/Nikitid-IKEv2-Setup.exe $(1)/www/luci-static/resources/ikev2-manager/Nikitid-IKEv2-Setup.exe

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status/include
	$(INSTALL_DATA) ./luci-ikev2-manager/status-widget.js $(1)/www/luci-static/resources/view/status/include/06_ikev2-manager.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ikev2-manager
	$(INSTALL_DATA) ./luci-ikev2-manager/setup.js $(1)/www/luci-static/resources/view/ikev2-manager/setup-v9.js
	$(INSTALL_DATA) ./luci-ikev2-manager/users.js $(1)/www/luci-static/resources/view/ikev2-manager/users-v13.js
	$(INSTALL_DATA) ./luci-ikev2-manager/settings.js $(1)/www/luci-static/resources/view/ikev2-manager/settings-v8.js
	$(INSTALL_DATA) ./luci-ikev2-manager/client.js $(1)/www/luci-static/resources/view/ikev2-manager/client-v9.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ikev2-domains
	$(INSTALL_DATA) ./luci-ikev2-domains/editor.js $(1)/www/luci-static/resources/view/ikev2-domains/editor-v10.js
endef

define Package/luci-app-ikev2-manager/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
# Every -vN rename leaves the superseded resource behind; the router had eight
# such orphans before this ran. Only names this package no longer ships are
# removed, so nothing else in these directories is touched.
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
	/www/luci-static/resources/view/ikev2-manager/settings-v7.js
# Refresh rpcd's ACL registry without restarting the daemon or invalidating
# active LuCI sessions. New file/exec permissions otherwise remain unavailable
# until rpcd is reloaded manually or the router is rebooted.
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
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
ikev2_feed_dir="$${IKEV2_FEED_DIR:-/etc/apk/repositories.d}"
ikev2_feed_old="$$ikev2_feed_dir/ikev2-manager.list"
ikev2_feed_new="$$ikev2_feed_dir/nikitid-openwrt.list"
ikev2_feed_url=https://raw.githubusercontent.com/Nikitid/openwrt-feed/feed/packages.adb
ikev2_feed_stale=0
if [ -f "$$ikev2_feed_old" ]; then
	case "$$(cat "$$ikev2_feed_old")" in
		https://raw.githubusercontent.com/Nikitid/ikev2-manager-openwrt/apk-feed/packages.adb) ikev2_feed_stale=1 ;;
		https://raw.githubusercontent.com/Nikitid/ikev2-openwrt/apk-feed/packages.adb) ikev2_feed_stale=1 ;;
	esac
fi
if [ "$$ikev2_feed_stale" = 1 ] && [ -e "$$ikev2_feed_new" ]; then
	rm -f "$$ikev2_feed_old"
	echo "Retired the previous per-application APK feed list."
elif [ "$$ikev2_feed_stale" = 1 ]; then
	if printf '%s\n' "$$ikev2_feed_url" >"$$ikev2_feed_new.tmp" && chmod 0644 "$$ikev2_feed_new.tmp" && mv "$$ikev2_feed_new.tmp" "$$ikev2_feed_new"; then
		rm -f "$$ikev2_feed_old"
		echo "APK feed migrated to the shared Nikitid OpenWrt feed."
	else
		rm -f "$$ikev2_feed_new.tmp"
		echo "Unable to migrate the APK feed; re-run the shared feed installer." >&2
	fi
fi
# feed-migration end
# runtime-reconcile begin
# Install newly introduced owned nftables rules without restarting the network,
# strongSwan, dnsmasq or fw4. The helper removes obsolete generated UCI
# DNS/DoT sections only after the replacement runtime validates and loads.
if [ "$$(uci -q get ikev2-manager.globals.configured)" = 1 ]; then
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
ikev2_health_init="$${IKEV2_HEALTH_INIT:-/etc/init.d/ikev2-health}"
ikev2_health_running=0
ikev2_health_enabled=0
ikev2_health_start_link=0
ikev2_health_stop_link=0
ikev2_rc_dir="$${IKEV2_RC_DIR:-/etc/rc.d}"
if [ -x "$$ikev2_health_init" ]; then
	"$$ikev2_health_init" running >/dev/null 2>&1 && ikev2_health_running=1
	for ikev2_rc_link in "$$ikev2_rc_dir"/S*ikev2-health; do
		[ -L "$$ikev2_rc_link" ] && ikev2_health_start_link=1
	done
	for ikev2_rc_link in "$$ikev2_rc_dir"/K*ikev2-health; do
		[ -L "$$ikev2_rc_link" ] && ikev2_health_stop_link=1
	done
	if [ "$$ikev2_health_start_link" = 1 ] && [ "$$ikev2_health_stop_link" = 1 ]; then
		ikev2_health_enabled=1
	fi
	# Refresh the links because rc.common does not remove an older K-number
	# when STOP changes during an upgrade.
	if [ "$$ikev2_health_enabled" = 1 ]; then
		if "$$ikev2_health_init" disable >/dev/null 2>&1 &&
		   "$$ikev2_health_init" enable >/dev/null 2>&1; then
			echo "Updated the health watcher shutdown order."
		else
			echo "Could not refresh the health watcher rc links; run '$$ikev2_health_init disable && $$ikev2_health_init enable'." >&2
		fi
	fi
fi
if [ "$$ikev2_health_running" = 1 ]; then
	if "$$ikev2_health_init" restart >/dev/null 2>&1; then
		echo "Restarted the health watcher so it runs the installed version."
	else
		echo "Could not restart the health watcher; run '$$ikev2_health_init restart'." >&2
	fi
fi
# health-restart end
# inbound-policy-watcher begin
# Keep inbound admission independent from the slower general health loop. A
# HUP makes an existing watcher exec the newly installed script without
# removing its fail-closed nftables table or interrupting active clients.
ikev2_policy_init="$${IKEV2_USER_POLICY_INIT:-/etc/init.d/ikev2-user-policy}"
ikev2_policy_active=0
if [ "$$(uci -q get ikev2-manager.globals.configured)" = 1 ] && \
   [ "$$(uci -q get ikev2-manager.server.enabled)" = 1 ] && \
   [ "$$(uci -q get ikev2-manager.server.custom_config)" != 1 ]; then
	ikev2_policy_active=1
fi
if [ "$$ikev2_policy_active" = 1 ] && [ -x "$$ikev2_policy_init" ]; then
	"$$ikev2_policy_init" disable >/dev/null 2>&1 || true
	"$$ikev2_policy_init" enable >/dev/null 2>&1 || true
	if "$$ikev2_policy_init" running >/dev/null 2>&1; then
		"$$ikev2_policy_init" reload >/dev/null 2>&1 || \
			echo "Could not reload the inbound policy watcher." >&2
	else
		"$$ikev2_policy_init" start >/dev/null 2>&1 || \
			echo "Could not start the inbound policy watcher." >&2
	fi
elif [ -x "$$ikev2_policy_init" ]; then
	"$$ikev2_policy_init" running >/dev/null 2>&1 && \
		"$$ikev2_policy_init" stop >/dev/null 2>&1 || true
	"$$ikev2_policy_init" disable >/dev/null 2>&1 || true
fi
# inbound-policy-watcher end
if [ "$$(uci -q get ikev2-manager.globals.configured)" = 1 ] || \
   [ "$$(uci -q get ikev2-manager.client.enabled)" = 1 ] || \
   [ "$$(uci -q get ikev2-manager.server.enabled)" = 1 ]; then
	echo "Existing configuration detected; runtime was not started automatically."
fi
echo "IKEv2 Manager for OpenWrt installed."
echo "Open LuCI -> Services -> IKEv2 Manager."
exit 0
endef

define Package/luci-app-ikev2-manager/prerm
#!/bin/sh
set -eu
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0
case "$${1:-}" in
	upgrade) exit 0 ;;
esac
fail() {
	echo "IKEv2 Manager for OpenWrt: $$*" >&2
	exit 1
}
[ -x /usr/libexec/ikev2-manager-system ] ||
	fail "cleanup helper is missing; package removal stopped before changing files"
/usr/libexec/ikev2-manager-system disable >/dev/null 2>&1 ||
	fail "unable to restore managed router state; package removal stopped before changing files"
swanctl --terminate --ike proxy-out --timeout 3 >/dev/null 2>&1 || true
for index in 2 3 4 5 6 7 8; do
	swanctl --terminate --ike "proxy-out-$$index" --timeout 3 >/dev/null 2>&1 || true
done
swanctl --terminate --ike ikev2-in --timeout 3 >/dev/null 2>&1 || true
swanctl --unload-conn proxy-out >/dev/null 2>&1 || true
swanctl --unload-conn ikev2-in >/dev/null 2>&1 || true
rm -f /etc/swanctl/conf.d/20-proxy-out.conf
rm -f /etc/swanctl/conf.d/21-proxy-out-extra.conf
rm -f /etc/swanctl/conf.d/30-inbound.conf
rm -f /etc/swanctl/conf.d/90-proxy-out-secret.conf
rm -f /etc/swanctl/conf.d/91-inbound-secrets.conf
rm -f /etc/swanctl/conf.d/92-proxy-out-extra-secret.conf
rm -f /etc/swanctl/x509/ikev2.pem
rm -f /etc/swanctl/private/ikev2.key
rm -f /etc/swanctl/x509ca/ikev2-le-isrg-root-*.pem
rm -f /etc/swanctl/x509ca/ikev2-server-chain-*.pem
for service in ikev2-health ikev2-xfrm ikev2-dns-segments ikev2-domain-router; do
	[ -x "/etc/init.d/$$service" ] || continue
	"/etc/init.d/$$service" stop >/dev/null 2>&1 || true
	"/etc/init.d/$$service" disable >/dev/null 2>&1 || true
done
rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
rm -f /tmp/ikev2-manager-action.log /tmp/ikev2-system-action.log
rm -f /tmp/ikev2-manager-deps.log /tmp/ikev2-manager-deps.status
rm -f /tmp/ikev2-manager-doctor.last /tmp/ikev2-manager-preflight.last
rm -f /tmp/ikev2-manager-dhcp.before-deps
rm -rf /tmp/ikev2-manager-dns-packages
rm -f /tmp/ikev2-domains-community.log /tmp/ikev2-domains-pbr-restart.log
rm -f /tmp/ikev2-acme.log /tmp/ikev2-acme-*.in
rm -f /tmp/ikev2-manager-dns-*.in /tmp/ikev2-dns-action-*.error
rm -f /tmp/ikev2-domains-input-*.domains /tmp/ikev2-domains-input-*.cidrs
rm -f /tmp/ikev2-domains-input-*.services /tmp/ikev2-domain-router.log
rm -f /tmp/ikev2-auto-connect.log /tmp/ikev2-manager-deps-backup-*.tar.gz
rm -f /var/run/ikev2-manager-user-*.in /var/run/ikev2-manager-client-*.in
rm -f /var/run/ikev2-manager-server-*.in /var/run/ikev2-manager-profile-*.in
rm -f /var/run/ikev2-vip4
rm -f /var/run/ikev2-manager-action.status /var/run/ikev2-system-action.status
rm -f /var/run/ikev2-action.lock.status /var/run/ikev2-domain-router.status
rm -f /var/run/ikev2-health.status /var/run/ikev2-health-probe.state
rm -f /var/run/ikev2-health-recovery.last /var/run/ikev2-auto-connect.attempt
rm -rf /var/run/ikev2-manager-actions /var/run/ikev2-system-actions
rm -rf /var/run/ikev2-quality
rm -f /var/run/ikev2-quality-sample.state
rm -rf /var/run/ikev2-domains-community-actions /var/run/ikev2-domains-community.pending.d
for lock in /var/run/ikev2-action.lock /var/run/ikev2-manager-config.lock \
	/var/run/ikev2-domain-router.lock /var/run/ikev2-domains-community.lock \
	/var/run/ikev2-domains-pbr-restart.lock /var/run/ikev2-auto-connect.lock; do
	rmdir "$$lock" 2>/dev/null || true
done
fw4 -q reload >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,luci-app-ikev2-manager))
