#!/bin/sh

set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0
[ -r /etc/openwrt_release ] || exit 0

# Upgrades must not tear down live routing. On explicit package removal,
# disable only the managed runtime state while preserving user configuration,
# credentials, certificates and custom destination lists.
[ "${PKG_UPGRADE:-0}" = 1 ] && exit 0
case "${1:-}" in
	upgrade) exit 0 ;;
esac

fail() {
	printf 'IKEv2 Manager for OpenWrt: %s\n' "$*" >&2
	exit 1
}

[ -x /usr/libexec/ikev2-manager-system ] ||
	fail 'cleanup helper is missing; package removal stopped before changing files'
/usr/libexec/ikev2-manager-system disable >/dev/null 2>&1 ||
	fail 'unable to restore managed router state; package removal stopped before changing files'

swanctl --terminate --ike proxy-out --timeout 3 >/dev/null 2>&1 || true
for index in 2 3 4 5 6 7; do
	swanctl --terminate --ike "proxy-out-$index" --timeout 3 >/dev/null 2>&1 || true
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

for service in ikev2-health ikev2-xfrm ikev2-user-policy ikev2-dns-segments ikev2-domain-router; do
	[ -x "/etc/init.d/$service" ] || continue
	"/etc/init.d/$service" stop >/dev/null 2>&1 || true
	"/etc/init.d/$service" disable >/dev/null 2>&1 || true
done

rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
rm -f /tmp/ikev2-manager-action.log /tmp/ikev2-system-action.log
rm -f /tmp/ikev2-manager-deps.log /tmp/ikev2-manager-deps.status
rm -f /tmp/ikev2-manager-doctor.last /tmp/ikev2-manager-preflight.last \
	/var/run/ikev2-widget-status.cache \
	/var/run/ikev2-pbr-policy.signature \
	/var/run/ikev2-pbr-policy.signature.new \
	/var/run/ikev2-pbr-policy.signature.input.*
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
rm -f /var/run/ikev2-user-policy.signature /var/run/ikev2-user-policy.sessions
rm -f /var/run/ikev2-user-policy.lock/pid
rmdir /var/run/ikev2-user-policy.lock 2>/dev/null || true
rm -rf /var/run/ikev2-manager-actions /var/run/ikev2-system-actions
rm -rf /var/run/ikev2-quality
rm -f /var/run/ikev2-quality-sample.state
rm -rf /var/run/ikev2-domains-community-actions /var/run/ikev2-domains-community.pending.d
for lock in /var/run/ikev2-action.lock /var/run/ikev2-manager-config.lock \
	/var/run/ikev2-domain-router.lock /var/run/ikev2-domains-community.lock \
	/var/run/ikev2-domains-pbr-restart.lock /var/run/ikev2-auto-connect.lock; do
	rmdir "$lock" 2>/dev/null || true
done

fw4 -q reload >/dev/null 2>&1 || true

exit 0
